defmodule Maxio.Buckets do
  @moduledoc """
  桶元数据上下文：创建/查询/列举/删除桶 + S3 桶名校验。
  桶名规则以官方 S3 bucket naming rules 为准（3-63、字符集、首尾、相邻点、IPv4、保留前后缀）。
  """
  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.Buckets.Bucket
  alias Maxio.Cluster.Notify
  alias Maxio.Objects.Object

  @reserved_prefixes ~w(xn-- sthree- amzn-s3-demo-)
  @reserved_suffixes ~w(-s3alias --ol-s3 .mrap --x-s3 --table-s3)

  @doc """
  **建桶准入**校验（CreateBucket 专用）：语法合法 **且** 名字允许被注册。

  比 `validate_addressable_name/1` 多三类"注册期"限制——它们回答的是"允许不允许起这个
  新名字"，而不是"这个名字本身能不能被解释"：

    * MinIO 保留桶名（`minio`）：path-style 下 `/minio/health/*`、`/minio/admin/*`、
      metrics 已被保留面认领，同名桶的对应 key 在该寻址方式下不可达（设计 D8、铁律 3）。
      名单由 `Maxio.S3.ReservedNamespace` 单一持有；精确整名匹配，`minio-data` /
      `myminio` 仍合法。
    * AWS 保留前后缀（`xn--` / `sthree-` / `-s3alias` …）。
    * IPv4 形状：会与 virtual-host 寻址产生歧义。

  **绝不能**把本函数用在写路径/校验既有对象上：存量桶可能早于这些规则被建出来，用注册期
  规则去卡它们，等于把合法数据静默降级成只读（详见 `validate_addressable_name/1`）。
  """
  @spec validate_creatable_name(String.t()) :: :ok | {:error, :invalid_bucket_name}
  def validate_creatable_name(name) when is_binary(name) do
    cond do
      validate_addressable_name(name) != :ok -> err()
      name in Maxio.S3.ReservedNamespace.reserved_bucket_names() -> err()
      ipv4?(name) -> err()
      Enum.any?(@reserved_prefixes, &String.starts_with?(name, &1)) -> err()
      Enum.any?(@reserved_suffixes, &String.ends_with?(name, &1)) -> err()
      true -> :ok
    end
  end

  def validate_creatable_name(_), do: err()

  @doc """
  **桶名语法**校验：这个名字本身能否被当作一个合法 S3 桶名解释（长度 / 字符集 / 首尾字符 /
  相邻点）。用于写路径、`Maxio.ObjectMutation.Journal` 的 changeset、
  `Maxio.Storage.ObjectEpoch` 的 target 构造等**面向既有桶**的场景。

  为什么它必须与建桶准入分家（铁律 3）：保留名单是会**增长**的（`minio` 就是新加的），
  而桶可能在保留之前就已经建好并写满数据。若写路径继续走建桶准入，新增一个保留名就会让
  一批存量桶的每一次 PutObject/CopyObject 在 journal changeset 上失败——对客户端表现为
  500 InternalError，即"静默把合法数据降级成只读"。写路径只需要知道名字是否可解释（决定
  它能否安全地进路径段 / fencing token），不需要知道今天还允不允许注册这个名字。
  """
  @spec validate_addressable_name(String.t()) :: :ok | {:error, :invalid_bucket_name}
  def validate_addressable_name(name) when is_binary(name) do
    cond do
      String.length(name) < 3 or String.length(name) > 63 -> err()
      not Regex.match?(~r/^[a-z0-9.\-]+$/, name) -> err()
      not Regex.match?(~r/^[a-z0-9]/, name) -> err()
      not Regex.match?(~r/[a-z0-9]$/, name) -> err()
      String.contains?(name, "..") -> err()
      true -> :ok
    end
  end

  def validate_addressable_name(_), do: err()

  defp err, do: {:error, :invalid_bucket_name}

  defp ipv4?(name) do
    case String.split(name, ".") do
      [_, _, _, _] = parts ->
        Enum.all?(parts, fn p ->
          case Integer.parse(p) do
            {n, ""} -> n >= 0 and n <= 255
            _ -> false
          end
        end)

      _ ->
        false
    end
  end

  @doc """
  创建桶。先校验名；命中已存在同名 → {:error, :already_owned}（M1 单租户，等价 BucketAlreadyOwnedByYou）。
  其余 changeset 校验失败原样返回 changeset（绝不静默掩盖根因，铁律 3）。
  """
  @spec create(String.t(), String.t(), keyword()) ::
          {:ok, Bucket.t()} | {:error, :invalid_bucket_name | :already_owned | Ecto.Changeset.t()}
  def create(name, owner, opts \\ []) do
    region = Keyword.get(opts, :region, default_region())
    acl = Keyword.get(opts, :acl_canned, "private")
    acl_grants = Keyword.get(opts, :acl_grants, %{"grants" => []})

    with :ok <- validate_creatable_name(name) do
      attrs = %{
        name: name,
        owner: owner,
        region: region,
        acl_canned: acl,
        acl_grants: acl_grants
      }

      case %Bucket{} |> Bucket.changeset(attrs) |> Repo.insert() do
        {:ok, bucket} ->
          Notify.broadcast({:bucket_metadata_changed, bucket.name})
          {:ok, bucket}

        {:error, %Ecto.Changeset{errors: errors} = changeset} ->
          if Keyword.has_key?(errors, :name) do
            {:error, :already_owned}
          else
            {:error, changeset}
          end
      end
    end
  end

  @doc "按名查桶。"
  @spec lookup(String.t()) :: {:ok, Bucket.t()} | {:error, :not_found}
  def lookup(name) do
    case Repo.get_by(Bucket, name: name) do
      nil -> {:error, :not_found}
      bucket -> {:ok, bucket}
    end
  end

  @doc "更新桶 ACL（PutBucketAcl）。桶不存在 → :not_found。"
  @spec put_acl(String.t(), String.t(), map()) :: :ok | {:error, :not_found}
  def put_acl(name, canned, grants_doc \\ %{"grants" => []}) do
    case lookup(name) do
      {:ok, bucket} ->
        bucket
        |> Bucket.changeset(%{acl_canned: canned, acl_grants: grants_doc})
        |> Repo.update!()

        Notify.broadcast({:bucket_metadata_changed, name})
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "读桶 tag。返回 [{Key,Value}]。桶不存在 → {:error, :not_found}。"
  @spec get_tags(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, :not_found}
  def get_tags(name) do
    case lookup(name) do
      {:ok, b} -> {:ok, Maxio.Tags.map_to_list(b.tags || %{})}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "写桶 tag（覆盖整集）。桶不存在 → {:error, :not_found}。"
  @spec put_tags(String.t(), [{String.t(), String.t()}]) :: :ok | {:error, :not_found}
  def put_tags(name, tags) do
    case lookup(name) do
      {:ok, b} ->
        b |> Bucket.changeset(%{tags: Maxio.Tags.list_to_map(tags)}) |> Repo.update!()
        Notify.broadcast({:bucket_metadata_changed, name})
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  设置桶版本化状态（PutBucketVersioning）。status 为 nil（空 body）→ 不改 versioning；
  显式 "Enabled"/"Suspended" → 更新。mfa 非 nil → 更新 mfa_delete。桶不存在 → :not_found。
  """
  @spec put_versioning(String.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, :not_found}
  def put_versioning(name, status, mfa) do
    case lookup(name) do
      {:ok, bucket} ->
        changes =
          %{}
          |> then(fn m -> if status, do: Map.put(m, :versioning, status), else: m end)
          |> then(fn m -> if mfa, do: Map.put(m, :mfa_delete, mfa), else: m end)

        if changes == %{} do
          :ok
        else
          bucket |> Bucket.changeset(changes) |> Repo.update!()
          Notify.broadcast({:bucket_metadata_changed, name})
          :ok
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "列出全部桶，按名升序（ListBuckets 用）。"
  @spec list() :: [Bucket.t()]
  def list, do: Repo.all(from b in Bucket, order_by: [asc: b.name])

  @doc "删除桶。桶不存在 → :not_found；桶内仍有对象 → :not_empty。"
  @spec delete(String.t()) :: :ok | {:error, :not_found | :not_empty}
  def delete(name) do
    with {:ok, bucket} <- lookup(name) do
      count = Repo.aggregate(from(o in Object, where: o.bucket_id == ^bucket.id), :count, :id)

      if count > 0 do
        {:error, :not_empty}
      else
        Repo.delete!(bucket)
        Notify.broadcast({:bucket_metadata_changed, name})
        :ok
      end
    end
  end

  defp default_region do
    Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:region)
  end
end
