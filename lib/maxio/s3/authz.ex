defmodule Maxio.S3.Authz do
  @moduledoc """
  授权关卡（铁律 3：绝不静默放行；拒绝 → AccessDenied 403 + 结构化日志）。
  在 Dispatch 解析出 action 之后、调用 handler 之前调用：
    1. 用 ActionMap 把 action → {s3:Action, 资源层级}；未映射的 action → 放行（无授权语义）。
    2. 构造资源 ARN（桶/对象/账户）+ 抽取条件键（aws:SecureTransport/SourceIp/CurrentTime/s3:prefix...）。
    3. 合并 statement 来源（顺序无关，Deny 优先由 Evaluator 保证）：
         bucket policy statements（Store.statements_for_bucket）
         ++ 该资源 canned ACL 派生 statements（桶 ACL 与/或对象 ACL）
         ++ principal_policies（MVP []）
    4. 构造 RequestContext（含 owner?/authenticated?）→ Evaluator.evaluate。
       :allow → :ok；{:deny, _} → raise AccessDenied(403)。
  owner? 判定（单租户）：principal.type == :root，或 principal 的 arn == 资源所属桶 owner。

  绝不缓冲对象 body（铁律 4）：本关卡只读 conn 元信息（assigns/headers/query），不 read_body。
  CopyObject（:put_object 且带 x-amz-copy-source）：额外对源对象做一次 s3:GetObject 授权。
  """
  import Plug.Conn
  alias Maxio.{Buckets, Objects}
  alias Maxio.Policy.{ACL, ActionMap, Arn, Evaluator, RequestContext, Store}
  alias Maxio.S3.{Error, Log}

  @spec authorize(Plug.Conn.t(), atom()) :: :ok
  def authorize(conn, action) do
    case ActionMap.for_action(action) do
      nil ->
        # 未映射动作（无明确 S3 授权语义）→ 放行（不静默掩盖：这些都是已显式列出的管理动作之外的）。
        :ok

      {required_action, level} ->
        do_authorize(conn, action, required_action, level)
    end
  end

  defp do_authorize(conn, action, required_action, level) do
    bucket = conn.assigns[:s3_bucket]
    key = conn.assigns[:s3_key]
    principal = conn.assigns[:principal]
    authenticated? = principal != :anonymous

    resource = resource_arn(level, bucket, key)
    conditions = extract_conditions(conn, authenticated?)

    statements = gather_statements(level, bucket, key, principal)

    ctx = %RequestContext{
      principal: principal,
      authenticated?: authenticated?,
      owner?: owner?(principal, bucket),
      action: required_action,
      resource: resource,
      conditions: conditions
    }

    case Evaluator.evaluate(ctx, statements) do
      :allow ->
        # CopyObject 二次检查：源对象 s3:GetObject（铁律 5，对齐官方 CopyObject 双检查）。
        maybe_authorize_copy_source(conn, action, principal, authenticated?, conditions)
        :ok

      {:deny, reason} ->
        deny(conn, action, required_action, resource, reason)
    end
  end

  @doc """
  供批量 handler（如 DeleteObjects 逐 key）复用：抽取请求条件键（与单请求授权同源）。
  与 do_authorize/4 内调用同一私有实现，绝不重复授权逻辑（铁律 2/4.1）。
  """
  @spec conditions_for(Plug.Conn.t(), boolean()) :: map()
  def conditions_for(conn, authenticated?), do: extract_conditions(conn, authenticated?)

  @doc """
  供批量 handler（如 DeleteObjects 逐 key）复用：合并某对象的 bucket policy + 对象 ACL 派生 +
  identity statements（与单请求对象级授权同源）。
  """
  @spec object_statements(String.t(), String.t(), map() | :anonymous) :: [
          Maxio.Policy.Statement.t()
        ]
  def object_statements(bucket, key, principal),
    do: gather_statements(:object, bucket, key, principal)

  # ── owner 短路判定（单租户）──
  @doc "principal 是否为该桶 owner 或 root（短路放行）。供批量 handler 复用，语义同单请求授权。"
  @spec owner?(map() | :anonymous, String.t() | nil) :: boolean()
  def owner?(:anonymous, _bucket), do: false
  def owner?(%{type: :root}, _bucket), do: true

  def owner?(%{arn: arn}, bucket) when is_binary(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, %{owner: ^arn}} -> true
      _ -> false
    end
  end

  def owner?(_principal, _bucket), do: false

  # ── 资源 ARN ──
  defp resource_arn(:account, _bucket, _key), do: Arn.account_arn()
  defp resource_arn(:bucket, bucket, _key), do: Arn.bucket_arn(bucket)
  defp resource_arn(:object, bucket, key), do: Arn.object_arn(bucket, key)

  # ── statement 合并：bucket policy + canned ACL 派生 + identity policy（按真实 principal）──
  defp gather_statements(:account, _bucket, _key, _principal), do: []

  defp gather_statements(level, bucket, key, principal) when is_binary(bucket) do
    policy_stmts = Store.statements_for_bucket(bucket)
    acl_stmts = acl_statements(level, bucket, key)
    policy_stmts ++ acl_stmts ++ Store.principal_policies(principal)
  end

  defp gather_statements(_level, _bucket, _key, _principal), do: []

  # 桶级动作看桶 ACL；对象级动作看对象 ACL（对象不存在则空——put 路径对象尚未建，靠 policy/owner）。
  defp acl_statements(:bucket, bucket, _key) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> ACL.canned_to_statements(b.acl_canned, :bucket, bucket, nil)
      _ -> []
    end
  end

  defp acl_statements(:object, bucket, key) do
    case Objects.get_metadata(bucket, key) do
      {:ok, obj} -> ACL.canned_to_statements(obj.acl_canned, :object, bucket, key)
      _ -> []
    end
  end

  # ── 条件键抽取（铁律 5：SecureTransport/SourceIp/CurrentTime 务必填，否则相关 Deny 失效）──
  defp extract_conditions(conn, authenticated?) do
    %{
      "aws:SecureTransport" => conn.scheme == :https,
      "aws:SourceIp" => source_ip(conn),
      "aws:CurrentTime" => now(conn),
      # ACL authenticated-read 折叠用的内部键（见 Policy.ACL）。
      "maxio:Authenticated" => if(authenticated?, do: "true", else: "false")
    }
    |> put_list_conditions(conn)
  end

  # ListObjects* 的 s3:prefix / s3:delimiter（来自 query）。
  defp put_list_conditions(conds, conn) do
    qp = conn.query_params || %{}

    conds
    |> maybe_put("s3:prefix", Map.get(qp, "prefix"))
    |> maybe_put("s3:delimiter", Map.get(qp, "delimiter"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp source_ip(conn) do
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      _ -> nil
    end
  end

  defp now(conn), do: conn.private[:maxio_now] || DateTime.utc_now()

  # ── CopyObject 源对象二次检查 ──
  defp maybe_authorize_copy_source(conn, :put_object, principal, authenticated?, conditions) do
    case conn |> get_req_header("x-amz-copy-source") |> List.first() do
      nil ->
        :ok

      raw ->
        {src_bucket, src_key} = parse_copy_source(raw)
        resource = Arn.object_arn(src_bucket, src_key)
        statements = gather_statements(:object, src_bucket, src_key, principal)

        ctx = %RequestContext{
          principal: principal,
          authenticated?: authenticated?,
          owner?: owner?(principal, src_bucket),
          action: "s3:GetObject",
          resource: resource,
          conditions: conditions
        }

        case Evaluator.evaluate(ctx, statements) do
          :allow -> :ok
          {:deny, reason} -> deny(conn, :copy_object_source, "s3:GetObject", resource, reason)
        end
    end
  end

  defp maybe_authorize_copy_source(_conn, _action, _p, _a, _c), do: :ok

  defp parse_copy_source(raw) do
    decoded = URI.decode(raw)
    trimmed = String.replace_prefix(decoded, "/", "")
    [path | _] = String.split(trimmed, "?", parts: 2)

    case String.split(path, "/", parts: 2) do
      [b, k] when k != "" -> {b, k}
      _ -> {"", ""}
    end
  end

  # ── 拒绝（绝不静默，铁律 3）──
  defp deny(conn, action, required_action, resource, reason) do
    Log.warn("authz denied",
      action: action,
      reason: reason,
      bucket: conn.assigns[:s3_bucket],
      key: conn.assigns[:s3_key],
      code: "AccessDenied",
      status: 403
    )

    _ = required_action
    raise Error.new(:access_denied, resource: resource)
  end
end
