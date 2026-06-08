defmodule Maxio.Buckets do
  @moduledoc """
  桶元数据上下文：创建/查询/列举/删除桶 + S3 桶名校验。
  桶名规则以官方 S3 bucket naming rules 为准（3-63、字符集、首尾、相邻点、IPv4、保留前后缀）。
  """
  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.Buckets.Bucket
  alias Maxio.Objects.Object

  @reserved_prefixes ~w(xn-- sthree- amzn-s3-demo-)
  @reserved_suffixes ~w(-s3alias --ol-s3 .mrap --x-s3 --table-s3)

  @doc "校验 S3 桶名；合法 :ok，否则 {:error, :invalid_bucket_name}。"
  @spec validate_name(String.t()) :: :ok | {:error, :invalid_bucket_name}
  def validate_name(name) when is_binary(name) do
    cond do
      String.length(name) < 3 or String.length(name) > 63 -> err()
      not Regex.match?(~r/^[a-z0-9.\-]+$/, name) -> err()
      not Regex.match?(~r/^[a-z0-9]/, name) -> err()
      not Regex.match?(~r/[a-z0-9]$/, name) -> err()
      String.contains?(name, "..") -> err()
      ipv4?(name) -> err()
      Enum.any?(@reserved_prefixes, &String.starts_with?(name, &1)) -> err()
      Enum.any?(@reserved_suffixes, &String.ends_with?(name, &1)) -> err()
      true -> :ok
    end
  end

  def validate_name(_), do: err()

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

    with :ok <- validate_name(name) do
      attrs = %{name: name, owner: owner, region: region, acl_canned: acl}

      case %Bucket{} |> Bucket.changeset(attrs) |> Repo.insert() do
        {:ok, bucket} ->
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

  @doc "更新桶的 canned ACL（PutBucketAcl）。桶不存在 → :not_found。"
  @spec put_acl(String.t(), String.t()) :: :ok | {:error, :not_found}
  def put_acl(name, canned) do
    case lookup(name) do
      {:ok, bucket} ->
        bucket |> Bucket.changeset(%{acl_canned: canned}) |> Repo.update!()
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
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  设置桶版本化状态（PutBucketVersioning）。status 为 nil（空 body）→ 不改 versioning；
  显式 "Enabled"/"Suspended" → 更新。mfa 非 nil → 更新 mfa_delete。桶不存在 → :not_found。
  """
  @spec put_versioning(String.t(), String.t() | nil, String.t() | nil) :: :ok | {:error, :not_found}
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
        :ok
      end
    end
  end

  defp default_region do
    Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:region)
  end
end
