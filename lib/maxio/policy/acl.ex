defmodule Maxio.Policy.ACL do
  @moduledoc """
  Canned ACL ↔ 等价策略 statement 折叠（铁律 2：ACL 与 policy 共用同一个 Evaluator，不另起评估路径）
  + AccessControlPolicy XML 出入站（委托 view / request parser）。

  官方核验（§RESEARCH bake-in）映射：
    AllUsers 组          → principal "*"（匿名+认证均匹配）
    AuthenticatedUsers 组 → 任意认证 principal（本系统：principal "*" 但要求 authenticated?；
                            MVP 用内部条件键 "maxio:Authenticated"=="true" 表达，由 Authz 构造 ctx 时填）
  ACL permission → S3 action（对象/桶分别）：
    READ(对象)  → s3:GetObject(+Version)        READ(桶)  → s3:ListBucket(+Versions,+MultipartUploads)
    WRITE(桶)   → s3:PutObject                  READ_ACP  → s3:Get{Bucket,Object}Acl
    WRITE_ACP   → s3:Put{Bucket,Object}Acl
  Owner FULL_CONTROL 隐含——本系统 owner 由 Evaluator owner? 短路处理，故 canned 只产生“公共/组”授权 statement。

  支持 canned：private / public-read / public-read-write / authenticated-read。
  其余 canned（bucket-owner-*/aws-exec-read/log-delivery-write）→ 存名不产生公共 statement（按 private 评估，文档化）。
  """
  alias Maxio.Policy.{Arn, Statement}

  @public_canned ~w(public-read public-read-write authenticated-read)
  @all_users "http://acs.amazonaws.com/groups/global/AllUsers"
  @auth_users "http://acs.amazonaws.com/groups/global/AuthenticatedUsers"
  @log_delivery "http://acs.amazonaws.com/groups/s3/LogDelivery"
  @public_group_uris [@all_users, @auth_users]
  @valid_group_uris [@all_users, @auth_users, @log_delivery]
  @valid_permissions ~w(READ WRITE READ_ACP WRITE_ACP FULL_CONTROL)
  @max_grants 100
  @empty_grants_doc %{"grants" => []}
  @grant_headers %{
    "x-amz-grant-read" => "READ",
    "x-amz-grant-write" => "WRITE",
    "x-amz-grant-read-acp" => "READ_ACP",
    "x-amz-grant-write-acp" => "WRITE_ACP",
    "x-amz-grant-full-control" => "FULL_CONTROL"
  }

  @doc "已知/受支持的 canned 名（用于校验 x-amz-acl）。"
  @spec known?(String.t()) :: boolean()
  def known?(canned) do
    canned in ~w(private public-read public-read-write authenticated-read
                 bucket-owner-read bucket-owner-full-control aws-exec-read log-delivery-write)
  end

  @doc "空显式 grant 文档。jsonb 里用 object envelope，避免 Ecto :map 写入裸数组。"
  @spec empty_grants_doc() :: map()
  def empty_grants_doc, do: @empty_grants_doc

  @doc "把规范化 grant 列表包成持久化文档。"
  @spec grants_doc([map()]) :: map()
  def grants_doc(grants) when is_list(grants), do: %{"grants" => grants}

  @doc "从持久化文档或兼容裸列表中取规范 grant 列表。"
  @spec grants_from_doc(term()) :: [map()]
  def grants_from_doc(%{"grants" => grants}) when is_list(grants), do: grants
  def grants_from_doc(%{grants: grants}) when is_list(grants), do: grants
  def grants_from_doc(grants) when is_list(grants), do: grants
  def grants_from_doc(_), do: []

  @doc "请求头中是否包含任一 x-amz-grant-* 显式 ACL 头。"
  @spec grant_headers?(list()) :: boolean()
  def grant_headers?(headers) when is_list(headers) do
    Enum.any?(headers, fn {k, _v} -> Map.has_key?(@grant_headers, String.downcase(k)) end)
  end

  @doc """
  解析 `x-amz-grant-*` 头为规范 grant 列表。

  支持 AWS REST 形态 `id=canonical`, `id="canonical"`, `uri="group-uri"`；email grantee
  在本系统仍显式拒绝，避免区域依赖解析与隐式账户查找。
  """
  @spec parse_grant_headers(list()) ::
          {:ok, [map()]} | {:error, :unsupported_email | :invalid_grant | :too_many_grants}
  def parse_grant_headers(headers) when is_list(headers) do
    headers
    |> Enum.reduce_while({:ok, []}, fn {name, value}, {:ok, acc} ->
      case Map.get(@grant_headers, String.downcase(name)) do
        nil ->
          {:cont, {:ok, acc}}

        permission ->
          case parse_grant_header_value(permission, value) do
            {:ok, grants} -> {:cont, {:ok, acc ++ grants}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, grants} -> normalize_grants(grants)
      {:error, _} = err -> err
    end
  end

  @doc "规范化 XML/request parser 产生的 grant 列表。"
  @spec normalize_grants([map()]) ::
          {:ok, [map()]} | {:error, :unsupported_email | :invalid_grant | :too_many_grants}
  def normalize_grants(grants) when is_list(grants) do
    if length(grants) > @max_grants do
      {:error, :too_many_grants}
    else
      grants
      |> Enum.reduce_while({:ok, []}, fn grant, {:ok, acc} ->
        case normalize_grant(grant) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
        {:error, _} = err -> err
      end
    end
  end

  def normalize_grants(_), do: {:error, :invalid_grant}

  @doc "去掉资源 owner 的显式 grant；owner FULL_CONTROL 由 GetAcl 渲染与 Authz owner? 短路统一表达。"
  @spec drop_owner_grants([map()], String.t()) :: [map()]
  def drop_owner_grants(grants, owner_id) when is_binary(owner_id) do
    Enum.reject(grants, fn
      %{"grantee" => %{"type" => "CanonicalUser", "id" => ^owner_id}} -> true
      _ -> false
    end)
  end

  @doc "显式 grant 列表能精确表达的 canned 标签；无法精确折叠则返回 custom。"
  @spec classify_grants([map()]) :: String.t()
  def classify_grants([]), do: "private"

  def classify_grants(grants) when is_list(grants) do
    group_perms =
      grants
      |> Enum.map(fn
        %{"grantee" => %{"type" => "Group", "uri" => uri}, "permission" => p} -> {uri, p}
        _ -> :non_group
      end)
      |> MapSet.new()

    cond do
      MapSet.member?(group_perms, :non_group) ->
        "custom"

      group_perms == MapSet.new([{@all_users, "READ"}, {@all_users, "WRITE"}]) ->
        "public-read-write"

      group_perms == MapSet.new([{@all_users, "READ"}]) ->
        "public-read"

      group_perms == MapSet.new([{@auth_users, "READ"}]) ->
        "authenticated-read"

      true ->
        "custom"
    end
  end

  @doc """
  ACL 是否向 AllUsers 或 AuthenticatedUsers 暴露权限。

  显式 grant 文档存在时以 grant 为准；否则按 canned ACL 判断。这与 to_statements/5 的
  授权折叠优先级一致，避免 PublicAccessBlock 与真实授权语义分叉。
  """
  @spec public_acl?(String.t(), term()) :: boolean()
  def public_acl?(canned, grants_doc) do
    case grants_from_doc(grants_doc) do
      [] -> canned in @public_canned
      grants -> Enum.any?(grants, &public_grant?/1)
    end
  end

  @doc "移除公共 ACL 授权，供 IgnorePublicAcls 计算有效权限使用；不修改持久化元数据。"
  @spec without_public_access(String.t(), term()) :: {String.t(), map()}
  def without_public_access(canned, grants_doc) do
    grants = grants_from_doc(grants_doc)

    cond do
      grants == [] and canned in @public_canned ->
        {"private", empty_grants_doc()}

      grants == [] ->
        {canned || "private", grants_doc_or_empty(grants_doc)}

      true ->
        private_grants = Enum.reject(grants, &public_grant?/1)
        {classify_grants(private_grants), grants_doc(private_grants)}
    end
  end

  @doc """
  ACL 元数据 → 等价 [Statement]。

  新显式 grant 文档非空时以 grant 为准；旧数据或 canned-only 写入保持原 canned 折叠语义。
  """
  @spec to_statements(String.t(), term(), :bucket | :object, String.t(), String.t() | nil) ::
          [Statement.t()]
  def to_statements(canned, grants_doc, level, bucket, key) do
    case grants_from_doc(grants_doc) do
      [] -> canned_to_statements(canned, level, bucket, key)
      grants -> grants_to_statements(grants, level, bucket, key)
    end
  end

  @doc "显式 grant 列表 → 等价 [Statement]。"
  @spec grants_to_statements([map()], :bucket | :object, String.t(), String.t() | nil) ::
          [Statement.t()]
  def grants_to_statements(grants, level, bucket, key) do
    grants
    |> Enum.flat_map(fn grant ->
      with {:ok, selector} <- grantee_selector(grant),
           {actions, resources} <- permission_targets(grant["permission"], level, bucket, key),
           true <- actions != [] and resources != [] do
        [allow_stmt(selector, actions, resources)]
      else
        _ -> []
      end
    end)
  end

  @doc """
  canned ACL → 等价 [Statement]（折叠进 Evaluator）。
  level=:bucket → resource=桶 ARN；level=:object → resource=对象 ARN（key 必给）。
  private 与未支持 canned → []（仅 owner 短路，无公共授权）。
  """
  @spec canned_to_statements(String.t(), :bucket | :object, String.t(), String.t() | nil) ::
          [Statement.t()]
  def canned_to_statements(canned, _level, _bucket, _key) when canned not in @public_canned,
    do: []

  def canned_to_statements("public-read", :object, bucket, key) do
    [allow_stmt(:any, ["s3:GetObject", "s3:GetObjectVersion"], [Arn.object_arn(bucket, key)])]
  end

  def canned_to_statements("public-read", :bucket, bucket, _key) do
    [allow_stmt(:any, bucket_read_actions(), [Arn.bucket_arn(bucket)])]
  end

  def canned_to_statements("public-read-write", :object, bucket, key) do
    [
      allow_stmt(:any, ["s3:GetObject", "s3:GetObjectVersion"], [Arn.object_arn(bucket, key)]),
      allow_stmt(:any, ["s3:PutObject"], [Arn.object_arn(bucket, key)])
    ]
  end

  def canned_to_statements("public-read-write", :bucket, bucket, _key) do
    [
      allow_stmt(:any, bucket_read_actions(), [Arn.bucket_arn(bucket)]),
      allow_stmt(:any, ["s3:PutObject"], [Arn.bucket_arn(bucket) <> "/*"])
    ]
  end

  # authenticated-read：仅认证 principal。用内部条件键 "maxio:Authenticated"=="true" 表达，
  # Authz 构造 ctx 时把 authenticated? 写入该键；匿名缺键 → 条件不成立 → 不命中（详见 M3-8 注释）。
  def canned_to_statements("authenticated-read", :object, bucket, key) do
    [
      allow_stmt(:authenticated, ["s3:GetObject", "s3:GetObjectVersion"], [
        Arn.object_arn(bucket, key)
      ])
    ]
  end

  def canned_to_statements("authenticated-read", :bucket, bucket, _key) do
    [allow_stmt(:authenticated, bucket_read_actions(), [Arn.bucket_arn(bucket)])]
  end

  defp bucket_read_actions,
    do: ["s3:ListBucket", "s3:ListBucketVersions", "s3:ListBucketMultipartUploads"]

  defp parse_grant_header_value(permission, value) do
    tokens =
      value
      |> to_string()
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if tokens == [] do
      {:error, :invalid_grant}
    else
      tokens
      |> Enum.reduce_while({:ok, []}, fn token, {:ok, acc} ->
        case parse_grantee_token(token, permission) do
          {:ok, grant} -> {:cont, {:ok, [grant | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, grants} -> {:ok, Enum.reverse(grants)}
        {:error, _} = err -> err
      end
    end
  end

  defp parse_grantee_token(token, permission) do
    case String.split(token, "=", parts: 2) do
      [type, raw_value] ->
        value = raw_value |> String.trim() |> strip_quotes()

        case String.trim(type) do
          "id" -> {:ok, canonical_grant(value, nil, permission)}
          "uri" -> {:ok, group_grant_map(value, permission)}
          "emailAddress" -> {:error, :unsupported_email}
          _ -> {:error, :invalid_grant}
        end

      _ ->
        {:error, :invalid_grant}
    end
  end

  defp strip_quotes(<<"\"", rest::binary>>) do
    if String.ends_with?(rest, "\""), do: binary_part(rest, 0, byte_size(rest) - 1), else: rest
  end

  defp strip_quotes(value), do: value

  defp canonical_grant(id, display_name, permission) do
    grantee =
      %{"type" => "CanonicalUser", "id" => id}
      |> maybe_put("display_name", display_name)

    %{"grantee" => grantee, "permission" => permission}
  end

  defp group_grant_map(uri, permission) do
    %{"grantee" => %{"type" => "Group", "uri" => uri}, "permission" => permission}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_grant(%{"grantee" => grantee, "permission" => permission}) do
    normalize_grant(grantee, permission)
  end

  defp normalize_grant(%{grantee: grantee, permission: permission}) do
    normalize_grant(grantee, permission)
  end

  defp normalize_grant(_), do: {:error, :invalid_grant}

  defp normalize_grant(grantee, permission) do
    permission = permission |> to_string() |> String.trim() |> String.upcase()

    with true <- permission in @valid_permissions,
         {:ok, normalized_grantee} <- normalize_grantee(grantee) do
      {:ok, %{"grantee" => normalized_grantee, "permission" => permission}}
    else
      false -> {:error, :invalid_grant}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_grantee(%{"type" => type} = grantee) do
    case normalize_grantee_type(type) do
      "CanonicalUser" ->
        id = grantee["id"] || grantee["ID"]
        display_name = grantee["display_name"] || grantee["DisplayName"]

        if present?(id),
          do: {:ok, canonical_grant(id, display_name, "READ")["grantee"]},
          else: {:error, :invalid_grant}

      "Group" ->
        uri = grantee["uri"] || grantee["URI"]

        if uri in @valid_group_uris,
          do: {:ok, %{"type" => "Group", "uri" => uri}},
          else: {:error, :invalid_grant}

      "AmazonCustomerByEmail" ->
        {:error, :unsupported_email}

      _ ->
        {:error, :invalid_grant}
    end
  end

  defp normalize_grantee(%{type: type} = grantee) do
    normalize_grantee(%{
      "type" => type,
      "id" => Map.get(grantee, :id),
      "display_name" => Map.get(grantee, :display_name),
      "uri" => Map.get(grantee, :uri)
    })
  end

  defp normalize_grantee(_), do: {:error, :invalid_grant}

  defp normalize_grantee_type(type) do
    type
    |> to_string()
    |> String.replace(" ", "")
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp public_grant?(%{"grantee" => %{"type" => "Group", "uri" => uri}}),
    do: uri in @public_group_uris

  defp public_grant?(_grant), do: false

  defp grants_doc_or_empty(%{"grants" => grants}) when is_list(grants), do: %{"grants" => grants}
  defp grants_doc_or_empty(%{grants: grants}) when is_list(grants), do: %{"grants" => grants}
  defp grants_doc_or_empty(_), do: empty_grants_doc()

  defp grantee_selector(%{"grantee" => %{"type" => "Group", "uri" => @all_users}}),
    do: {:ok, :any}

  defp grantee_selector(%{"grantee" => %{"type" => "Group", "uri" => @auth_users}}),
    do: {:ok, :authenticated}

  defp grantee_selector(%{"grantee" => %{"type" => "CanonicalUser", "id" => id}})
       when is_binary(id),
       do: {:ok, {:aws, [id]}}

  defp grantee_selector(_), do: :ignore

  defp permission_targets(permission, :bucket, bucket, _key) do
    case permission do
      "READ" -> {bucket_read_actions(), [Arn.bucket_arn(bucket)]}
      "WRITE" -> {["s3:PutObject"], [Arn.bucket_arn(bucket) <> "/*"]}
      "READ_ACP" -> {["s3:GetBucketAcl"], [Arn.bucket_arn(bucket)]}
      "WRITE_ACP" -> {["s3:PutBucketAcl"], [Arn.bucket_arn(bucket)]}
      "FULL_CONTROL" -> full_control_targets(:bucket, bucket, nil)
      _ -> {[], []}
    end
  end

  defp permission_targets(permission, :object, bucket, key) do
    object_arn = Arn.object_arn(bucket, key)

    case permission do
      "READ" -> {["s3:GetObject", "s3:GetObjectVersion"], [object_arn]}
      "READ_ACP" -> {["s3:GetObjectAcl", "s3:GetObjectVersionAcl"], [object_arn]}
      "WRITE_ACP" -> {["s3:PutObjectAcl", "s3:PutObjectVersionAcl"], [object_arn]}
      "FULL_CONTROL" -> full_control_targets(:object, bucket, key)
      _ -> {[], []}
    end
  end

  defp full_control_targets(:bucket, bucket, key) do
    ["READ", "WRITE", "READ_ACP", "WRITE_ACP"]
    |> Enum.map(&permission_targets(&1, :bucket, bucket, key))
    |> merge_targets()
  end

  defp full_control_targets(:object, bucket, key) do
    ["READ", "READ_ACP", "WRITE_ACP"]
    |> Enum.map(&permission_targets(&1, :object, bucket, key))
    |> merge_targets()
  end

  defp merge_targets(targets) do
    actions = targets |> Enum.flat_map(fn {a, _r} -> a end) |> Enum.uniq()
    resources = targets |> Enum.flat_map(fn {_a, r} -> r end) |> Enum.uniq()
    {actions, resources}
  end

  # principal=:authenticated → principals=:any + 内部条件键 "maxio:Authenticated"=="true"。
  defp allow_stmt(:authenticated, actions, resources) do
    %Statement{
      effect: :allow,
      actions: actions,
      resources: resources,
      principals: :any,
      conditions: %{"StringEquals" => %{"maxio:Authenticated" => "true"}}
    }
  end

  defp allow_stmt(:any, actions, resources) do
    %Statement{
      effect: :allow,
      actions: actions,
      resources: resources,
      principals: :any,
      conditions: %{}
    }
  end

  defp allow_stmt({:aws, ids}, actions, resources) do
    %Statement{
      effect: :allow,
      actions: actions,
      resources: resources,
      principals: {:aws, ids},
      conditions: %{}
    }
  end
end
