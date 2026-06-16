defmodule Maxio.S3.Authz do
  @moduledoc """
  授权关卡（铁律 3：绝不静默放行；拒绝 → AccessDenied 403 + 结构化日志）。
  在 Dispatch 解析出 action 之后、调用 handler 之前调用：
    1. 用 ActionMap 把 action → {s3:Action, 资源层级}；未映射的 action → 放行（无授权语义）。
    2. 构造资源 ARN（桶/对象/账户）+ 抽取条件键（aws:SecureTransport/SourceIp/CurrentTime/
       aws:PrincipalArn/s3:prefix/s3:max-keys/常用 x-amz-* header）。
    3. 合并 statement 来源（顺序无关，Deny 优先由 Evaluator 保证）：
         bucket policy statements（Store.statements_for_bucket）
         ++ 该资源 canned ACL 派生 statements（桶 ACL 与/或对象 ACL）
         ++ principal_policies（绑定到真实 principal 的 identity policy）
    4. 构造 RequestContext（含 owner?/authenticated?）→ Evaluator.evaluate。
       :allow → :ok；{:deny, _} → raise AccessDenied(403)。
  owner? 判定（单租户）：principal.type == :root，或 principal 的 arn == 资源所属桶 owner。

  绝不缓冲对象 body（铁律 4）：本关卡只读 conn 元信息（assigns/headers/query），不 read_body。
  CopyObject/UploadPartCopy（带 x-amz-copy-source）：额外对源对象做一次 s3:GetObject 授权。
  """
  import Plug.Conn
  alias Maxio.{Buckets, ObjectMeta, Objects, Tags}
  alias Maxio.Policy.{ACL, ActionMap, Arn, Evaluator, RequestContext, Store}
  alias Maxio.S3.{CopySource, Error, Log, OwnershipControls, PublicAccessBlock}

  @max_keys_limit 1000

  @spec authorize(Plug.Conn.t(), atom()) :: :ok
  # PutObjectTagging 的 s3:RequestObjectTag* 条件键来自 bounded XML body。
  # 前置 Authz 不能读取 body；handler 解析/校验 XML 后、写入前调用 authorize_put_object_tagging/5。
  def authorize(_conn, :put_object_tagging), do: :ok
  def authorize(_conn, :put_bucket_inventory_configuration), do: :ok

  def authorize(conn, action) do
    case ActionMap.for_action(action) do
      nil ->
        # 未映射动作（无明确 S3 授权语义）→ 放行（不静默掩盖：这些都是已显式列出的管理动作之外的）。
        :ok

      {required_action, level} ->
        do_authorize(conn, action, required_action, level)
    end
  end

  @doc """
  PutObjectTagging 的 `s3:RequestObjectTag*` 条件键来自 XML body，前置 Authz 不能读取。
  Tagging handler 在 bounded read + XML/tag 校验后、写入前调用本函数做完整对象级授权。
  """
  @spec authorize_put_object_tagging(
          Plug.Conn.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          [{String.t(), String.t()}]
        ) :: :ok
  def authorize_put_object_tagging(conn, bucket, key, _version_id, tags) do
    principal = conn.assigns[:principal]
    authenticated? = principal != :anonymous
    required_action = "s3:PutObjectTagging"
    resource = resource_arn(:object, bucket, key)

    conditions =
      conn
      |> extract_conditions(authenticated?, :put_object_tagging)
      |> put_request_object_tag_conditions(tags)

    statements = gather_statements(:object, bucket, key, principal, conn, :put_object_tagging)

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
        authorize_session_policy!(conn, principal, required_action, resource, conditions)

      {:deny, reason} ->
        deny(conn, :put_object_tagging, required_action, resource, reason)
    end
  end

  @doc """
  PutBucketInventoryConfiguration 的 `s3:InventoryAccessibleOptionalFields` 条件键来自 XML body。
  前置 Authz 不能读取 body；handler 在 bounded read + XML 校验后、写入前调用本函数。
  """
  @spec authorize_put_bucket_inventory_configuration(Plug.Conn.t(), String.t(), [String.t()]) ::
          :ok
  def authorize_put_bucket_inventory_configuration(conn, bucket, optional_fields) do
    principal = conn.assigns[:principal]
    authenticated? = principal != :anonymous
    required_action = "s3:PutInventoryConfiguration"
    resource = resource_arn(:bucket, bucket, nil)

    conditions =
      conn
      |> extract_conditions(authenticated?, :put_bucket_inventory_configuration)
      |> put_inventory_optional_fields_condition(optional_fields)

    statements =
      gather_statements(
        :bucket,
        bucket,
        nil,
        principal,
        conn,
        :put_bucket_inventory_configuration
      )

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
        authorize_session_policy!(conn, principal, required_action, resource, conditions)

      {:deny, reason} ->
        deny(conn, :put_bucket_inventory_configuration, required_action, resource, reason)
    end
  end

  defp do_authorize(conn, action, required_action, level) do
    bucket = conn.assigns[:s3_bucket]
    key = conn.assigns[:s3_key]
    principal = conn.assigns[:principal]
    authenticated? = principal != :anonymous

    required_action = effective_required_action(action, required_action, conn)
    resource = resource_arn(level, bucket, key)
    conditions = extract_conditions(conn, authenticated?, action)

    statements = gather_statements(level, bucket, key, principal, conn, action)

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
        authorize_session_policy!(conn, principal, required_action, resource, conditions)

        maybe_authorize_create_bucket_headers(
          conn,
          action,
          bucket,
          principal,
          authenticated?,
          conditions
        )

        maybe_authorize_acl_headers(
          conn,
          action,
          level,
          bucket,
          key,
          principal,
          authenticated?,
          conditions
        )

        # CopyObject/UploadPartCopy 二次检查：源对象 s3:GetObject（铁律 5，对齐官方 copy source 双检查）。
        maybe_authorize_copy_source(conn, action, principal, authenticated?, conditions)

        maybe_authorize_get_object_attributes_read(
          conn,
          action,
          principal,
          authenticated?,
          conditions
        )

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
    do: gather_statements(:object, bucket, key, principal, nil, nil)

  @doc """
  Evaluates inline AssumeRole session policy as a permissions boundary.

  The normal S3 authorization path may include owner/resource-policy/ACL allows.
  When an assumed-role principal carries a session policy, AWS session
  permissions are still bounded by the role identity policy and the inline
  session policy. Both are evaluated here with owner shortcuts disabled so the
  boundary cannot grant permissions the role lacks.
  """
  @spec session_policy_allows?(
          map() | :anonymous,
          String.t(),
          String.t(),
          map()
        ) :: boolean()
  def session_policy_allows?(
        %{session_policy_statements: :invalid},
        _action,
        _resource,
        _conditions
      ),
      do: false

  def session_policy_allows?(
        %{session_policy_statements: statements} = principal,
        action,
        resource,
        conditions
      )
      when is_list(statements) do
    if statements == [] do
      true
    else
      identity_policy_allows?(principal, action, resource, conditions) and
        evaluates_to_allow?(statements, principal, action, resource, conditions)
    end
  end

  def session_policy_allows?(_principal, _action, _resource, _conditions), do: true

  defp identity_policy_allows?(principal, action, resource, conditions) do
    principal
    |> Store.principal_policies()
    |> evaluates_to_allow?(principal, action, resource, conditions)
  end

  defp evaluates_to_allow?(statements, principal, action, resource, conditions) do
    ctx = %RequestContext{
      principal: principal,
      authenticated?: principal != :anonymous,
      owner?: false,
      action: action,
      resource: resource,
      conditions: conditions
    }

    Evaluator.evaluate(ctx, statements) == :allow
  end

  defp authorize_session_policy!(conn, principal, action, resource, conditions) do
    if session_policy_allows?(principal, action, resource, conditions) do
      :ok
    else
      deny(conn, :session_policy, action, resource, :session_policy)
    end
  end

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
  defp gather_statements(:account, _bucket, _key, principal, _conn, _action),
    do: Store.principal_policies(principal)

  defp gather_statements(level, bucket, key, principal, conn, _action) when is_binary(bucket) do
    policy_stmts =
      PublicAccessBlock.effective_bucket_policy_statements(
        bucket,
        Store.statements_for_bucket(bucket)
      )

    acl_stmts = acl_statements(level, bucket, key, conn)
    policy_stmts ++ acl_stmts ++ Store.principal_policies(principal)
  end

  defp gather_statements(_level, _bucket, _key, _principal, _conn, _action), do: []

  # 桶级动作看桶 ACL；对象级动作看对象 ACL（对象不存在则空——put 路径对象尚未建，靠 policy/owner）。
  defp acl_statements(:bucket, bucket, _key, _conn) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> acl_to_statements(bucket, b.acl_canned, b.acl_grants, :bucket, nil)
      _ -> []
    end
  end

  defp acl_statements(:object, bucket, key, conn) do
    bucket_acl_object_statements(bucket) ++
      object_acl_statements(bucket, key, request_version_id(conn))
  end

  defp bucket_acl_object_statements(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> acl_to_statements(bucket, b.acl_canned, b.acl_grants, :bucket, nil)
      _ -> []
    end
  end

  defp object_acl_statements(_bucket, _key, :invalid_version_id), do: []

  defp object_acl_statements(bucket, key, version_id) do
    case ObjectMeta.get(bucket, key, version_id, []) do
      %Objects.Object{is_delete_marker: true} ->
        []

      %Objects.Object{} = obj ->
        acl_to_statements(bucket, obj.acl_canned, obj.acl_grants, :object, key)

      _ ->
        []
    end
  end

  defp acl_to_statements(bucket, canned, grants_doc, level, key) do
    {effective_canned, effective_grants_doc} =
      if OwnershipControls.bucket_owner_enforced?(bucket) do
        OwnershipControls.effective_acl(bucket, canned, grants_doc)
      else
        PublicAccessBlock.effective_acl(bucket, canned, grants_doc)
      end

    ACL.to_statements(effective_canned, effective_grants_doc, level, bucket, key)
  end

  defp effective_required_action(:get_object_acl, _required_action, conn) do
    if version_acl_request?(request_version_id(conn)),
      do: "s3:GetObjectVersionAcl",
      else: "s3:GetObjectAcl"
  end

  defp effective_required_action(:put_object_acl, _required_action, conn) do
    if version_acl_request?(request_version_id(conn)),
      do: "s3:PutObjectVersionAcl",
      else: "s3:PutObjectAcl"
  end

  defp effective_required_action(:delete_object, _required_action, conn) do
    if version_request?(request_version_id(conn)),
      do: "s3:DeleteObjectVersion",
      else: "s3:DeleteObject"
  end

  defp effective_required_action(:get_object_attributes, _required_action, conn) do
    if version_request?(request_version_id(conn)),
      do: "s3:GetObjectVersionAttributes",
      else: "s3:GetObjectAttributes"
  end

  defp effective_required_action(_action, required_action, _conn), do: required_action

  defp version_acl_request?(nil), do: false
  defp version_acl_request?(_version_id_or_invalid), do: true
  defp version_request?(nil), do: false
  defp version_request?(_version_id_or_invalid), do: true

  defp request_version_id(nil), do: nil

  defp request_version_id(conn) do
    case Map.fetch(conn.query_params || %{}, "versionId") do
      :error ->
        nil

      {:ok, raw_version_id} ->
        version_id = Maxio.Versioning.VersionId.normalize_param(raw_version_id)

        cond do
          is_nil(version_id) -> nil
          Maxio.Versioning.VersionId.valid?(version_id) -> version_id
          true -> :invalid_version_id
        end
    end
  end

  # ── 条件键抽取（铁律 5：SecureTransport/SourceIp/CurrentTime 务必填，否则相关 Deny 失效）──
  defp extract_conditions(conn, authenticated?, action \\ nil) do
    principal = conn.assigns[:principal]

    %{
      "aws:SecureTransport" => conn.scheme == :https,
      "aws:SourceIp" => source_ip(conn),
      "aws:CurrentTime" => now(conn),
      # ACL authenticated-read 折叠用的内部键（见 Policy.ACL）。
      "maxio:Authenticated" => if(authenticated?, do: "true", else: "false")
    }
    |> maybe_put("aws:PrincipalArn", principal_arn(principal))
    |> put_principal_context(principal)
    |> put_principal_tag_conditions(principal)
    |> put_session_context(principal)
    |> put_header_conditions(conn)
    |> put_list_conditions(conn, action)
    |> put_resource_tag_conditions(conn, action)
    |> put_request_tag_conditions(conn, action)
  end

  defp principal_arn(%{arn: arn}) when is_binary(arn), do: arn
  defp principal_arn(_principal), do: nil

  defp put_principal_context(conds, :anonymous),
    do: Map.put(conds, "aws:PrincipalType", "Anonymous")

  defp put_principal_context(conds, %{type: :root, access_key: access_key}) do
    conds
    |> Map.put("aws:PrincipalType", "Account")
    |> maybe_put("aws:userid", access_key)
  end

  defp put_principal_context(conds, %{type: :iam_user, access_key: access_key, arn: arn}) do
    conds
    |> Map.put("aws:PrincipalType", "User")
    |> maybe_put("aws:userid", access_key)
    |> maybe_put("aws:username", username_from_arn(arn))
  end

  defp put_principal_context(conds, %{type: type, access_key: access_key}) do
    conds
    |> Map.put("aws:PrincipalType", type |> to_string() |> Macro.camelize())
    |> maybe_put("aws:userid", access_key)
  end

  defp put_principal_context(conds, _principal), do: conds

  defp put_principal_tag_conditions(conds, %{tags: tags}),
    do: put_tag_conditions(conds, ["aws:PrincipalTag"], tags)

  defp put_principal_tag_conditions(conds, _principal), do: conds

  defp put_session_context(conds, principal) when is_map(principal) do
    conds
    |> maybe_put("aws:SourceIdentity", principal[:source_identity])
    |> put_mfa_context(principal)
  end

  defp put_session_context(conds, _principal), do: conds

  defp put_mfa_context(conds, %{type: :assumed_role}), do: conds

  defp put_mfa_context(conds, %{mfa_authenticated: value}) when is_boolean(value),
    do: Map.put(conds, "aws:MultiFactorAuthPresent", value)

  defp put_mfa_context(conds, _principal), do: conds

  defp username_from_arn("arn:aws:iam:::user/" <> path) do
    path
    |> String.split("/", trim: true)
    |> List.last()
  end

  defp username_from_arn(_arn), do: nil

  defp put_header_conditions(conds, conn) do
    conds
    |> maybe_put_header(conn, "s3:x-amz-acl", "x-amz-acl")
    |> maybe_put_header(conn, "s3:x-amz-grant-read", "x-amz-grant-read")
    |> maybe_put_header(conn, "s3:x-amz-grant-write", "x-amz-grant-write")
    |> maybe_put_header(conn, "s3:x-amz-grant-read-acp", "x-amz-grant-read-acp")
    |> maybe_put_header(conn, "s3:x-amz-grant-write-acp", "x-amz-grant-write-acp")
    |> maybe_put_header(conn, "s3:x-amz-grant-full-control", "x-amz-grant-full-control")
    |> maybe_put_header(
      conn,
      "s3:x-amz-server-side-encryption",
      "x-amz-server-side-encryption"
    )
    |> maybe_put_header(conn, "s3:x-amz-copy-source", "x-amz-copy-source")
  end

  defp put_inventory_optional_fields_condition(conds, []), do: conds

  defp put_inventory_optional_fields_condition(conds, optional_fields)
       when is_list(optional_fields) do
    Map.put(conds, "s3:InventoryAccessibleOptionalFields", optional_fields)
  end

  defp maybe_put_header(map, conn, condition_key, header_name),
    do: maybe_put(map, condition_key, conn |> get_req_header(header_name) |> List.first())

  # ListObjects* 的 s3:prefix / s3:delimiter / s3:max-keys（来自 query；max-keys 与 handler 同源归一化）。
  defp put_list_conditions(conds, conn, action)
       when action in [:list_objects, :list_objects_v2, :list_object_versions] do
    qp = conn.query_params || %{}

    conds
    |> maybe_put("s3:prefix", Map.get(qp, "prefix"))
    |> maybe_put("s3:delimiter", Map.get(qp, "delimiter"))
    |> Map.put("s3:max-keys", normalize_max_keys(Map.get(qp, "max-keys")))
  end

  defp put_list_conditions(conds, _conn, _action), do: conds

  defp put_resource_tag_conditions(conds, conn, action) do
    bucket = conn.assigns[:s3_bucket]
    key = conn.assigns[:s3_key]
    version_id = request_version_id(conn)

    conds
    |> put_bucket_tag_conditions(bucket, action)
    |> put_existing_object_tag_conditions(bucket, key, version_id, action)
  end

  defp put_bucket_tag_conditions(conds, bucket, action) when is_binary(bucket) do
    tags =
      case Buckets.lookup(bucket) do
        {:ok, b} -> b.tags || %{}
        _ -> %{}
      end

    conds
    |> put_tag_conditions(["s3:BucketTag"], tags)
    |> maybe_put_bucket_resource_tag_conditions(action, tags)
  end

  defp put_bucket_tag_conditions(conds, _bucket, _action), do: conds

  defp maybe_put_bucket_resource_tag_conditions(conds, action, tags) do
    if bucket_resource_tag_action?(action) do
      put_tag_conditions(conds, ["aws:ResourceTag"], tags)
    else
      conds
    end
  end

  defp bucket_resource_tag_action?(action)
       when action in [
              :delete_bucket,
              :head_bucket,
              :list_objects,
              :list_objects_v2,
              :list_object_versions,
              :get_bucket_location,
              :list_multipart_uploads,
              :put_bucket_policy,
              :get_bucket_policy,
              :delete_bucket_policy,
              :get_bucket_acl,
              :put_bucket_acl,
              :put_bucket_versioning,
              :get_bucket_versioning,
              :put_bucket_tagging,
              :get_bucket_tagging,
              :delete_bucket_tagging,
              :put_bucket_cors,
              :get_bucket_cors,
              :delete_bucket_cors,
              :put_bucket_lifecycle,
              :get_bucket_lifecycle,
              :delete_bucket_lifecycle,
              :put_bucket_encryption,
              :get_bucket_encryption,
              :delete_bucket_encryption,
              :put_public_access_block,
              :get_public_access_block,
              :delete_public_access_block,
              :put_bucket_ownership_controls,
              :get_bucket_ownership_controls,
              :delete_bucket_ownership_controls,
              :put_bucket_website,
              :get_bucket_website,
              :delete_bucket_website,
              :put_bucket_request_payment,
              :get_bucket_request_payment,
              :put_bucket_logging,
              :get_bucket_logging
            ],
       do: true

  defp bucket_resource_tag_action?(_action), do: false

  # AWS S3 does not support s3:ExistingObjectTag for ordinary PutObject/DeleteObject
  # authorization. Keep existing object tags scoped to reads and object subresource actions.
  defp put_existing_object_tag_conditions(conds, bucket, key, version_id, action)
       when is_binary(bucket) and is_binary(key) do
    if existing_object_tag_action?(action) do
      tags = existing_object_tags(bucket, key, version_id)

      conds
      |> put_tag_conditions(["s3:ExistingObjectTag"], tags)
      |> put_tag_conditions(["aws:ResourceTag"], tags)
    else
      conds
    end
  end

  defp put_existing_object_tag_conditions(conds, _bucket, _key, _version_id, _action), do: conds

  defp existing_object_tag_action?(action)
       when action in [
              :get_object,
              :head_object,
              :get_object_attributes,
              :get_object_tagging,
              :put_object_tagging,
              :delete_object_tagging,
              :get_object_acl,
              :put_object_acl
            ],
       do: true

  defp existing_object_tag_action?(_action), do: false

  defp existing_object_tags(_bucket, _key, :invalid_version_id), do: %{}

  defp existing_object_tags(bucket, key, version_id) do
    case ObjectMeta.get(bucket, key, version_id, []) do
      %Objects.Object{is_delete_marker: true} -> %{}
      %Objects.Object{tags: tags} when is_map(tags) -> tags
      _ -> %{}
    end
  end

  defp put_request_tag_conditions(conds, conn, :put_object) do
    request_tags =
      if copy_object_without_replace_tags?(conn) do
        []
      else
        request_tagging_header(conn)
      end

    conds
    |> put_request_object_tag_conditions(request_tags)
  end

  defp put_request_tag_conditions(conds, _conn, _action), do: conds

  defp copy_object_without_replace_tags?(conn) do
    copy_object? = get_req_header(conn, "x-amz-copy-source") != []

    tagging_directive =
      conn
      |> get_req_header("x-amz-tagging-directive")
      |> List.first()
      |> normalize_copy_directive()

    copy_object? and tagging_directive != "REPLACE"
  end

  defp normalize_copy_directive(nil), do: "COPY"
  defp normalize_copy_directive(value), do: value |> String.trim() |> String.upcase()

  defp request_tagging_header(conn) do
    case conn |> get_req_header("x-amz-tagging") |> List.first() do
      nil -> []
      "" -> []
      raw -> parse_request_tags(raw)
    end
  end

  defp parse_request_tags(raw) do
    with {:ok, tags} <- Tags.parse_header(raw),
         :ok <- Tags.validate(tags, :object) do
      tags
    else
      _ -> []
    end
  end

  defp put_request_object_tag_conditions(conds, tags) do
    conds
    |> put_tag_conditions(["s3:RequestObjectTag", "aws:RequestTag"], tags)
    |> put_request_tag_key_conditions(tags)
  end

  defp put_request_tag_key_conditions(conds, tags) do
    keys = tags |> tag_pairs() |> Enum.map(&elem(&1, 0))

    if keys == [] do
      conds
    else
      conds
      |> Map.put("s3:RequestObjectTagKeys", keys)
      |> Map.put("aws:TagKeys", keys)
    end
  end

  defp put_tag_conditions(conds, prefixes, tags) when is_list(prefixes) do
    tags
    |> tag_pairs()
    |> Enum.reduce(conds, fn {key, value}, acc ->
      Enum.reduce(prefixes, acc, fn prefix, inner_acc ->
        Map.put(inner_acc, "#{prefix}/#{key}", value)
      end)
    end)
  end

  defp tag_pairs(tags) when is_map(tags) do
    tags
    |> Enum.map(fn {key, value} -> {to_string(key), tag_value(value)} end)
    |> Enum.reject(fn {key, _value} -> key == "" end)
  end

  defp tag_pairs(tags) when is_list(tags) do
    tags
    |> Enum.filter(&match?({key, value} when is_binary(key) and is_binary(value), &1))
    |> Enum.reject(fn {key, _value} -> key == "" end)
  end

  defp tag_pairs(_tags), do: []

  defp tag_value(nil), do: ""
  defp tag_value(value), do: to_string(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp normalize_max_keys(nil), do: @max_keys_limit

  defp normalize_max_keys(raw) do
    case Integer.parse(to_string(raw)) do
      {n, ""} when n > 0 -> min(n, @max_keys_limit)
      _ -> @max_keys_limit
    end
  end

  defp source_ip(conn) do
    case :inet.ntoa(conn.remote_ip) do
      chars when is_list(chars) -> to_string(chars)
      _ -> nil
    end
  end

  defp now(conn), do: conn.private[:maxio_now] || DateTime.utc_now()

  defp maybe_authorize_create_bucket_headers(
         conn,
         :create_bucket,
         bucket,
         principal,
         authenticated?,
         conditions
       )
       when is_binary(bucket) do
    :ok =
      if get_req_header(conn, "x-amz-object-ownership") != [] do
        authorize_additional_action!(
          conn,
          :create_bucket_ownership_controls,
          "s3:PutBucketOwnershipControls",
          :bucket,
          bucket,
          nil,
          principal,
          authenticated?,
          conditions
        )
      else
        :ok
      end

    if acl_headers?(conn) do
      authorize_additional_action!(
        conn,
        :create_bucket_acl_header,
        "s3:PutBucketAcl",
        :bucket,
        bucket,
        nil,
        principal,
        authenticated?,
        conditions
      )
    else
      :ok
    end
  end

  defp maybe_authorize_create_bucket_headers(_conn, _action, _bucket, _p, _a, _c), do: :ok

  defp authorize_additional_action!(
         conn,
         denied_action,
         required_action,
         level,
         bucket,
         key,
         principal,
         authenticated?,
         conditions
       ) do
    resource = resource_arn(level, bucket, key)
    statements = gather_statements(level, bucket, key, principal, conn, denied_action)

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
        authorize_session_policy!(conn, principal, required_action, resource, conditions)

      {:deny, reason} ->
        deny(conn, denied_action, required_action, resource, reason)
    end
  end

  # Object writes that carry ACL-setting headers require the normal write permission and
  # s3:PutObjectAcl. Without this second check, bucket WRITE grants can mint public ACLs.
  defp maybe_authorize_acl_headers(
         conn,
         action,
         :object,
         bucket,
         key,
         principal,
         authenticated?,
         conditions
       )
       when action in [:put_object, :create_multipart_upload] and is_binary(bucket) and
              is_binary(key) do
    if acl_headers?(conn) and not OwnershipControls.bucket_owner_enforced?(bucket) do
      authorize_additional_action!(
        conn,
        :put_object_acl_header,
        "s3:PutObjectAcl",
        :object,
        bucket,
        key,
        principal,
        authenticated?,
        conditions
      )
    else
      :ok
    end
  end

  defp maybe_authorize_acl_headers(_conn, _action, _level, _bucket, _key, _p, _a, _c), do: :ok

  defp acl_headers?(conn) do
    get_req_header(conn, "x-amz-acl") != [] or
      Enum.any?(conn.req_headers, fn {name, _value} ->
        name |> String.downcase() |> String.starts_with?("x-amz-grant-")
      end)
  end

  # ── CopyObject / UploadPartCopy 源对象二次检查 ──
  defp maybe_authorize_copy_source(conn, action, principal, authenticated?, conditions)
       when action in [:put_object, :upload_part] do
    case conn |> get_req_header("x-amz-copy-source") |> List.first() do
      nil ->
        :ok

      raw ->
        %{bucket: src_bucket, key: src_key, version_id: src_version_id} = CopySource.parse!(raw)
        resource = Arn.object_arn(src_bucket, src_key)

        statements =
          gather_statements(
            :object,
            src_bucket,
            src_key,
            principal,
            copy_source_conn(src_version_id),
            nil
          )

        source_conditions =
          copy_source_conditions(conditions, src_bucket, src_key, src_version_id)

        ctx = %RequestContext{
          principal: principal,
          authenticated?: authenticated?,
          owner?: owner?(principal, src_bucket),
          action: copy_source_action(src_version_id),
          resource: resource,
          conditions: source_conditions
        }

        case Evaluator.evaluate(ctx, statements) do
          :allow ->
            authorize_session_policy!(
              conn,
              principal,
              copy_source_action(src_version_id),
              resource,
              source_conditions
            )

          {:deny, reason} ->
            deny(
              conn,
              copy_source_denied_action(action),
              copy_source_action(src_version_id),
              resource,
              reason
            )
        end
    end
  end

  defp maybe_authorize_copy_source(_conn, _action, _p, _a, _c), do: :ok

  defp maybe_authorize_get_object_attributes_read(
         conn,
         :get_object_attributes,
         principal,
         authenticated?,
         conditions
       ) do
    bucket = conn.assigns[:s3_bucket]
    key = conn.assigns[:s3_key]
    version_id = request_version_id(conn)
    resource = Arn.object_arn(bucket, key)
    statements = gather_statements(:object, bucket, key, principal, conn, :get_object_attributes)

    ctx = %RequestContext{
      principal: principal,
      authenticated?: authenticated?,
      owner?: owner?(principal, bucket),
      action: object_attributes_read_action(version_id),
      resource: resource,
      conditions: conditions
    }

    case Evaluator.evaluate(ctx, statements) do
      :allow ->
        authorize_session_policy!(
          conn,
          principal,
          object_attributes_read_action(version_id),
          resource,
          conditions
        )

      {:deny, reason} ->
        deny(
          conn,
          :get_object_attributes_read,
          object_attributes_read_action(version_id),
          resource,
          reason
        )
    end
  end

  defp maybe_authorize_get_object_attributes_read(_conn, _action, _p, _a, _c), do: :ok

  defp object_attributes_read_action(nil), do: "s3:GetObject"
  defp object_attributes_read_action(_version_id), do: "s3:GetObjectVersion"

  defp copy_source_action(nil), do: "s3:GetObject"
  defp copy_source_action(_version_id), do: "s3:GetObjectVersion"

  defp copy_source_denied_action(:upload_part), do: :upload_part_copy_source
  defp copy_source_denied_action(_action), do: :copy_object_source

  defp copy_source_conn(nil), do: nil
  defp copy_source_conn(version_id), do: %{query_params: %{"versionId" => version_id}}

  defp copy_source_conditions(conditions, bucket, key, version_id) do
    conditions
    |> strip_tag_condition_keys()
    |> put_bucket_tag_conditions(bucket, :get_object)
    |> put_existing_object_tag_conditions(bucket, key, version_id, :get_object)
  end

  defp strip_tag_condition_keys(conditions) do
    Map.reject(conditions, fn {key, _value} -> tag_condition_key?(key) end)
  end

  defp tag_condition_key?("aws:TagKeys"), do: true
  defp tag_condition_key?("s3:RequestObjectTagKeys"), do: true

  defp tag_condition_key?(key) when is_binary(key) do
    Enum.any?(
      [
        "s3:BucketTag/",
        "aws:ResourceTag/",
        "s3:ExistingObjectTag/",
        "s3:RequestObjectTag/",
        "aws:RequestTag/"
      ],
      &String.starts_with?(key, &1)
    )
  end

  defp tag_condition_key?(_key), do: false

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
