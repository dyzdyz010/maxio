defmodule Maxio.Objects do
  @moduledoc """
  对象元数据上下文：写/读/删元数据 + ListObjectsV2 查询（prefix/delimiter/max-keys/
  continuation-token/start-after，含 CommonPrefixes 折叠与分页 token）。
  字节读写不在此（走 Maxio.Storage），本上下文只管元数据与列举逻辑。
  """
  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.Buckets
  alias Maxio.Objects.Object

  @type list_opts :: %{
          optional(:prefix) => String.t(),
          optional(:delimiter) => String.t(),
          optional(:max_keys) => pos_integer(),
          optional(:continuation_token) => String.t() | nil,
          optional(:start_after) => String.t() | nil
        }

  @type list_result :: %{
          objects: [Object.t()],
          common_prefixes: [String.t()],
          is_truncated: boolean(),
          next_continuation_token: String.t() | nil,
          key_count: non_neg_integer()
        }

  @doc """
  写入/覆盖对象元数据（按 (bucket, key) upsert）。`attrs` 至少含 size、etag；
  可含 content_type、metadata、storage_class。桶不存在 → {:error, :no_such_bucket}。
  """
  @spec put_metadata(String.t(), String.t(), map()) ::
          {:ok, Object.t()} | {:error, :no_such_bucket | Ecto.Changeset.t()}
  def put_metadata(bucket_name, key, attrs) do
    with {:ok, bucket} <- bucket_or_error(bucket_name) do
      base = %{
        bucket_id: bucket.id,
        bucket_name: bucket_name,
        key: key,
        size: Map.fetch!(attrs, :size),
        etag: Map.fetch!(attrs, :etag),
        content_type: Map.get(attrs, :content_type, "binary/octet-stream"),
        metadata: Map.get(attrs, :metadata, %{}),
        storage_class: Map.get(attrs, :storage_class, "STANDARD"),
        acl_canned: Map.get(attrs, :acl_canned, "private")
      }

      %Object{}
      |> Object.changeset(base)
      |> Repo.insert(
        on_conflict:
          {:replace,
           [:size, :etag, :content_type, :metadata, :storage_class, :acl_canned, :updated_at]},
        conflict_target: [:bucket_id, :key]
      )
    end
  end

  @doc "更新对象的 canned ACL（PutObjectAcl）。对象不存在 → :not_found。"
  @spec put_acl(String.t(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def put_acl(bucket_name, key, canned) do
    case get_metadata(bucket_name, key) do
      {:ok, obj} ->
        obj |> Object.changeset(%{acl_canned: canned}) |> Repo.update!()
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "按 (bucket, key) 取对象元数据。"
  @spec get_metadata(String.t(), String.t()) :: {:ok, Object.t()} | {:error, :not_found}
  def get_metadata(bucket_name, key) do
    case Repo.get_by(Object, bucket_name: bucket_name, key: key) do
      nil -> {:error, :not_found}
      object -> {:ok, object}
    end
  end

  @doc "删除对象元数据（幂等：不存在也返回 :ok）。"
  @spec delete_metadata(String.t(), String.t()) :: :ok
  def delete_metadata(bucket_name, key) do
    Repo.delete_all(from o in Object, where: o.bucket_name == ^bucket_name and o.key == ^key)
    :ok
  end

  @doc """
  ListObjectsV2 查询。返回 %{objects, common_prefixes, is_truncated,
  next_continuation_token, key_count}。语义对齐官方：
    * continuation_token 优先于 start_after 作为分页游标（两者都是 key 的"严格大于"起点）；
    * delimiter 折叠：prefix 之后到首个 delimiter 之间相同的串折叠成一个 CommonPrefixes 条目；
    * 每个 common prefix 与每个对象各计一个 key_count，key_count <= max_keys；
    * 多取一条判断是否截断；截断时 next_continuation_token = 最后返回项（对象 key 或公共前缀）。
  """
  @spec list_objects_v2(String.t(), list_opts()) :: list_result()
  def list_objects_v2(bucket_name, opts \\ %{}) do
    prefix = Map.get(opts, :prefix, "") || ""
    delimiter = Map.get(opts, :delimiter)
    max_keys = Map.get(opts, :max_keys, 1000)
    cursor = Map.get(opts, :continuation_token) || Map.get(opts, :start_after)

    # 拉取候选 key（升序），从游标之后开始，仅取该 prefix。多取以便折叠后仍能判断截断。
    base_query =
      from o in Object,
        where: o.bucket_name == ^bucket_name,
        order_by: [asc: o.key]

    base_query =
      if prefix != "" do
        where(base_query, [o], like(o.key, ^(escape_like(prefix) <> "%")))
      else
        base_query
      end

    base_query = if cursor, do: where(base_query, [o], o.key > ^cursor), else: base_query

    candidates = Repo.all(base_query)

    {objects, common_prefixes, truncated, next_token} =
      collapse(candidates, prefix, delimiter, max_keys)

    key_count = length(objects) + length(common_prefixes)

    %{
      objects: objects,
      common_prefixes: common_prefixes,
      is_truncated: truncated,
      next_continuation_token: if(truncated, do: next_token, else: nil),
      key_count: key_count
    }
  end

  # 折叠 delimiter 公共前缀 + 截断判断。逐条扫描升序候选，累计到 max_keys。
  defp collapse(candidates, prefix, delimiter, max_keys) do
    do_collapse(candidates, prefix, delimiter, max_keys, [], MapSet.new(), [], nil)
  end

  defp do_collapse([], _prefix, _delim, _max, objs, _seen_set, cps, _last) do
    {Enum.reverse(objs), Enum.reverse(cps), false, nil}
  end

  defp do_collapse([obj | rest], prefix, delimiter, max, objs, seen_set, cps, _last) do
    count = length(objs) + MapSet.size(seen_set)

    cond do
      count >= max ->
        # 已达上限且还有候选 → 截断；next token = 上一个返回项（对象 key 或公共前缀）
        last = previous_token(objs, cps)
        {Enum.reverse(objs), Enum.reverse(cps), true, last}

      true ->
        case common_prefix_of(obj.key, prefix, delimiter) do
          nil ->
            do_collapse(rest, prefix, delimiter, max, [obj | objs], seen_set, cps, obj.key)

          cp ->
            if MapSet.member?(seen_set, cp) do
              # 已折叠过的公共前缀，跳过该对象不计数
              do_collapse(rest, prefix, delimiter, max, objs, seen_set, cps, cp)
            else
              do_collapse(
                rest,
                prefix,
                delimiter,
                max,
                objs,
                MapSet.put(seen_set, cp),
                [cp | cps],
                cp
              )
            end
        end
    end
  end

  # 该 key 在 prefix 之后是否含 delimiter；含则返回 prefix..(含首个delimiter) 的公共前缀，否则 nil。
  defp common_prefix_of(_key, _prefix, nil), do: nil

  defp common_prefix_of(key, prefix, delimiter) do
    rest = String.replace_prefix(key, prefix, "")

    case :binary.match(rest, delimiter) do
      {pos, len} -> prefix <> binary_part(rest, 0, pos + len)
      :nomatch -> nil
    end
  end

  defp previous_token([obj | _], _cps), do: obj.key
  defp previous_token([], [cp | _]), do: cp
  defp previous_token([], []), do: nil

  # 转义 LIKE 通配（% 与 _ 与 \）。
  defp escape_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp bucket_or_error(bucket_name) do
    case Buckets.lookup(bucket_name) do
      {:ok, bucket} -> {:ok, bucket}
      {:error, :not_found} -> {:error, :no_such_bucket}
    end
  end
end
