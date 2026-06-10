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
  alias Maxio.Versioning.VersionId

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
  写入/覆盖对象元数据（按 (bucket, key) 的 "null" 版本行 upsert，并置 latest）。`attrs` 至少含
  size、etag；可含 content_type、metadata、storage_class。桶不存在 → {:error, :no_such_bucket}。
  CopyObject / Multipart Complete 走此路径（字节落 null 路径，对象当 null 版本）。
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
        acl_canned: Map.get(attrs, :acl_canned, "private"),
        version_id: "null",
        is_latest: true,
        is_delete_marker: false
      }

      Repo.transaction(fn ->
        unset_latest(bucket.id, key)

        {:ok, obj} =
          %Object{}
          |> Object.changeset(base)
          |> Repo.insert(
            on_conflict:
              {:replace,
               [
                 :size,
                 :etag,
                 :content_type,
                 :metadata,
                 :storage_class,
                 :acl_canned,
                 :is_latest,
                 :is_delete_marker,
                 :updated_at
               ]},
            conflict_target: [:bucket_id, :key, :version_id]
          )

        obj
      end)
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

  @doc "读对象 tag（current 或指定版本）。返回 [{Key,Value}]（空集 → []）。对象不存在 → {:error, :not_found}。"
  @spec get_tags(String.t(), String.t(), String.t() | nil) ::
          {:ok, [{String.t(), String.t()}]} | {:error, :not_found}
  def get_tags(bucket_name, key, version_id \\ nil) do
    fetch =
      if version_id,
        do: get_version(bucket_name, key, version_id),
        else: get_metadata(bucket_name, key)

    case fetch do
      {:ok, obj} -> {:ok, Maxio.Tags.map_to_list(obj.tags || %{})}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "写对象 tag（覆盖整集）。对象不存在 → {:error, :not_found}。"
  @spec put_tags(String.t(), String.t(), [{String.t(), String.t()}], String.t() | nil) ::
          :ok | {:error, :not_found}
  def put_tags(bucket_name, key, tags, version_id \\ nil) do
    fetch =
      if version_id,
        do: get_version(bucket_name, key, version_id),
        else: get_metadata(bucket_name, key)

    case fetch do
      {:ok, obj} ->
        obj |> Object.changeset(%{tags: Maxio.Tags.list_to_map(tags)}) |> Repo.update!()
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "按 (bucket, key) 取当前版本（is_latest=true）的对象元数据。delete marker 也会返回（调用方判 is_delete_marker）。"
  @spec get_metadata(String.t(), String.t()) :: {:ok, Object.t()} | {:error, :not_found}
  def get_metadata(bucket_name, key) do
    case Repo.get_by(Object, bucket_name: bucket_name, key: key, is_latest: true) do
      nil -> {:error, :not_found}
      object -> {:ok, object}
    end
  end

  @doc "按 (bucket, key, version_id) 取特定版本行。"
  @spec get_version(String.t(), String.t(), String.t()) ::
          {:ok, Object.t()} | {:error, :not_found}
  def get_version(bucket_name, key, version_id) do
    case Repo.get_by(Object, bucket_name: bucket_name, key: key, version_id: version_id) do
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
  按桶版本化状态写入一个对象版本（PutObject 的元数据落库）。
  versioning ∈ "Enabled" | "Suspended" | "Unversioned"：
    * Enabled → 生成新 ULID version_id，插入新行并置 latest（旧 latest 置 false）。
    * Suspended/Unversioned → version_id="null"，upsert 既有 null 行并置 latest（其余非 null 版本不动）。
  attrs 至少含 size、etag；可含 content_type/metadata/storage_class/acl_canned/tags/sse_algorithm。
  返回 {:ok, Object.t()}（含其 version_id）。
  """
  @spec put_version(String.t(), String.t(), String.t(), map()) ::
          {:ok, Object.t()} | {:error, :no_such_bucket | Ecto.Changeset.t()}
  def put_version(bucket_name, key, versioning, attrs) do
    version_id = if versioning == "Enabled", do: VersionId.generate(), else: "null"
    put_version_with_id(bucket_name, key, version_id, attrs)
  end

  @doc "用外部已生成的 version_id 写入版本行（PutObject 路径：字节已按此 version_id 落盘）。"
  @spec put_version_with_id(String.t(), String.t(), String.t(), map()) ::
          {:ok, Object.t()} | {:error, :no_such_bucket | Ecto.Changeset.t()}
  def put_version_with_id(bucket_name, key, version_id, attrs) do
    with {:ok, bucket} <- bucket_or_error(bucket_name) do
      base =
        attrs
        |> Map.take([
          :content_type,
          :metadata,
          :storage_class,
          :acl_canned,
          :tags,
          :sse_algorithm,
          :sse_envelope
        ])
        |> Map.merge(%{
          bucket_id: bucket.id,
          bucket_name: bucket_name,
          key: key,
          size: Map.fetch!(attrs, :size),
          etag: Map.fetch!(attrs, :etag),
          version_id: version_id,
          is_latest: true,
          is_delete_marker: false
        })

      Repo.transaction(fn ->
        unset_latest(bucket.id, key)

        case %Object{}
             |> Object.changeset(base)
             |> Repo.insert(
               on_conflict:
                 {:replace,
                  [
                    :size,
                    :etag,
                    :content_type,
                    :metadata,
                    :storage_class,
                    :acl_canned,
                    :is_latest,
                    :is_delete_marker,
                    :updated_at
                  ]},
               conflict_target: [:bucket_id, :key, :version_id]
             ) do
          {:ok, obj} -> obj
          {:error, cs} -> Repo.rollback(cs)
        end
      end)
    end
  end

  @doc """
  ROUTE B B4-2 —— best-effort 索引写（与 put_version_with_id/4 同参数/同语义，但捕获异常返回
  `{:error, term}` 而非抛出，且把成功结果归一为 `:ok`）。

  用于 `authoritative_source(:write) == :sidecar`：sidecar 才是写路径的权威载体（Storage.put 达
  write_quorum = 字节 + sidecar 已耐久落盘），PG 仅作派生索引，故 PG 写失败**非致命**——调用方据
  `:ok | {:error, reason}` 记结构化日志而非让对象 PUT 失败（去 PG 写路径 SPOF，铁律 3 绝不静默：
  失败必由调用方记 Log.error）。`:pg` 权威（默认）仍走 put_version_with_id/4 的致命 + 回滚语义。
  """
  @spec put_version_index(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put_version_index(bucket_name, key, version_id, attrs) do
    case put_version_with_id(bucket_name, key, version_id, attrs) do
      {:ok, _obj} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  插入删除标记（DELETE 无 versionId，桶 Enabled/Suspended）。
  Enabled → 新 ULID delete marker 置 latest；Suspended → "null" delete marker upsert 置 latest。
  返回 {:ok, %{version_id}}。

  注：version_id 在内部生成。**ROUTE B B5-0**：当 handler 需先把同一 version_id 的 delete marker
  落盘（sidecar 权威的删除完整性），改走 `insert_delete_marker_with_id/4`（外部已生成 version_id），
  使盘上 marker sidecar 与 PG 索引行 version_id 一致。本函数保留供 `:pg` 默认权威下的纯 PG 路径。
  """
  @spec insert_delete_marker(String.t(), String.t(), String.t()) ::
          {:ok, %{version_id: String.t()}} | {:error, :no_such_bucket}
  def insert_delete_marker(bucket_name, key, versioning) do
    version_id = if versioning == "Enabled", do: VersionId.generate(), else: "null"
    insert_delete_marker_with_id(bucket_name, key, version_id)
  end

  @doc """
  ROUTE B B5-0 —— 用外部已生成的 version_id 插入删除标记（marker 字节/sidecar 已按此 version_id
  落盘，PG 索引须用同 version_id 保持盘/PG 一致）。Enabled 传新 ULID，Suspended 传 "null"
  （null marker 替换既有 null 版本，AWS 语义）。返回 {:ok, %{version_id}}。
  """
  @spec insert_delete_marker_with_id(String.t(), String.t(), String.t()) ::
          {:ok, %{version_id: String.t()}} | {:error, :no_such_bucket}
  def insert_delete_marker_with_id(bucket_name, key, version_id) do
    with {:ok, bucket} <- bucket_or_error(bucket_name) do
      base = %{
        bucket_id: bucket.id,
        bucket_name: bucket_name,
        key: key,
        size: 0,
        etag: "",
        version_id: version_id,
        is_latest: true,
        is_delete_marker: true
      }

      Repo.transaction(fn ->
        unset_latest(bucket.id, key)

        {:ok, _} =
          %Object{}
          |> Object.changeset(base)
          |> Repo.insert(
            on_conflict: {:replace, [:size, :etag, :is_latest, :is_delete_marker, :updated_at]},
            conflict_target: [:bucket_id, :key, :version_id]
          )
      end)

      {:ok, %{version_id: version_id}}
    end
  end

  @doc """
  ROUTE B B5-0 —— best-effort 删除标记索引写（与 insert_delete_marker_with_id/3 同语义，但捕获异常
  返回 `{:error, term}` 而非抛出，成功归一为 `:ok`）。

  用于 `authoritative_source(:write) == :sidecar`：盘上 delete-marker sidecar 已达 write_quorum =
  删除已耐久落盘权威记录，PG 仅作派生索引，故 PG 写失败**非致命**——调用方据 `:ok | {:error,reason}`
  记 Log.error 而非让 DELETE 失败（去 PG 写路径 SPOF，铁律 3 绝不静默）。`:pg` 默认权威仍走
  insert_delete_marker_with_id/3 的致命语义。
  """
  @spec insert_delete_marker_index(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def insert_delete_marker_index(bucket_name, key, version_id) do
    case insert_delete_marker_with_id(bucket_name, key, version_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  永久删除某特定版本行（DELETE ?versionId）。删后若被删的是当时的 latest，则把该 key 余下
  version_id 最大者重新置 latest（delete marker 的删除会让更老版本重新浮现，对齐 AWS）。
  返回 {:ok, %{was_delete_marker: boolean()}} | {:error, :not_found}。
  """
  @spec delete_version(String.t(), String.t(), String.t()) ::
          {:ok, %{was_delete_marker: boolean()}} | {:error, :not_found}
  def delete_version(bucket_name, key, version_id) do
    case get_version(bucket_name, key, version_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, %Object{} = obj} ->
        Repo.transaction(fn ->
          Repo.delete!(obj)

          if obj.is_latest do
            promote_latest(obj.bucket_id, key)
          end
        end)

        {:ok, %{was_delete_marker: obj.is_delete_marker}}
    end
  end

  # 把该 (bucket,key) 现有 latest 行全部置 false（写新版本前调用，事务内）。
  defp unset_latest(bucket_id, key) do
    from(o in Object, where: o.bucket_id == ^bucket_id and o.key == ^key and o.is_latest == true)
    |> Repo.update_all(set: [is_latest: false])
  end

  # 删 latest 后，把余下 version_id 最大（最新）的行重新置 latest（无余下行则无操作）。
  defp promote_latest(bucket_id, key) do
    candidate =
      from(o in Object,
        where: o.bucket_id == ^bucket_id and o.key == ^key,
        order_by: [desc: o.version_id],
        limit: 1
      )
      |> Repo.one()

    if candidate do
      candidate |> Ecto.Changeset.change(is_latest: true) |> Repo.update!()
    end
  end

  @type versions_result :: %{
          versions: [Object.t()],
          common_prefixes: [String.t()],
          is_truncated: boolean(),
          next_key_marker: String.t() | nil,
          next_version_id_marker: String.t() | nil
        }

  @doc """
  ListObjectVersions 查询（?versions）。返回 %{versions, common_prefixes, is_truncated,
  next_key_marker, next_version_id_marker}。语义对齐官方：
    * 排序：key 升序，key 内 newest-first（version_id 降序——ULID 时间序）。delete marker 与
      version 交错在同一 key-then-newest 序列。
    * 二维游标：(key_marker, version_id_marker) 之后开始（先 key 严格大于，或 key 相等且 version_id 严格小于）。
    * delimiter 折叠：prefix 之后首个 delimiter 之间的串折叠成 CommonPrefixes（每个计一个结果）。
    * max-keys 默认/上限 1000；多取一条判截断；截断时 next_key_marker/next_version_id_marker = 最后返回项。
  versions 列表元素含 is_delete_marker，由 view 决定渲染 <Version> 还是 <DeleteMarker>。
  """
  @spec list_object_versions(String.t(), map()) :: versions_result()
  def list_object_versions(bucket_name, opts \\ %{}) do
    prefix = Map.get(opts, :prefix, "") || ""
    delimiter = Map.get(opts, :delimiter)
    max_keys = Map.get(opts, :max_keys, 1000)
    key_marker = Map.get(opts, :key_marker)
    version_id_marker = Map.get(opts, :version_id_marker)

    base =
      from o in Object,
        where: o.bucket_name == ^bucket_name,
        order_by: [asc: o.key, desc: o.version_id]

    base =
      if prefix != "",
        do: where(base, [o], like(o.key, ^(escape_like(prefix) <> "%"))),
        else: base

    # 二维游标：key > key_marker，或 (key == key_marker and version_id < version_id_marker)。
    base =
      cond do
        key_marker && version_id_marker ->
          where(
            base,
            [o],
            o.key > ^key_marker or (o.key == ^key_marker and o.version_id < ^version_id_marker)
          )

        key_marker ->
          where(base, [o], o.key > ^key_marker)

        true ->
          base
      end

    # ROUTE B B1-3 临时硬 LIMIT 闸（同 list_objects_v2）：有界 SQL 取数防大桶 DoS。
    # capped? 时候选被截断，须强制截断+续点（不能宣称完整）。
    fetch_limit = list_fetch_limit(max_keys)
    candidates = Repo.all(limit(base, ^fetch_limit))
    capped? = length(candidates) == fetch_limit

    {versions, common_prefixes, truncated, last_key, last_vid} =
      collapse_versions(candidates, prefix, delimiter, max_keys, capped?)

    %{
      versions: versions,
      common_prefixes: common_prefixes,
      is_truncated: truncated,
      next_key_marker: if(truncated, do: last_key, else: nil),
      next_version_id_marker: if(truncated, do: last_vid, else: nil)
    }
  end

  # 折叠 delimiter 公共前缀 + 截断判断（与 list_objects_v2 同构，但游标是二维 (key, version_id)）。
  # capped? = SQL 候选被 fetch_limit 截断；候选耗尽却未达 max_keys 时不能宣称完整。
  defp collapse_versions(candidates, prefix, delimiter, max_keys, capped?) do
    do_collapse_versions(
      candidates,
      prefix,
      delimiter,
      max_keys,
      [],
      MapSet.new(),
      [],
      nil,
      nil,
      capped?
    )
  end

  # 候选耗尽。capped? 为真说明 SQL LIMIT 可能在攒满 max_keys 前就截断了候选——无法证明完整，
  # 强制 is_truncated=true + 二维续点（最后已折叠项），否则才 false。
  defp do_collapse_versions([], _prefix, _delim, _max, vers, _seen, cps, lk, lv, capped?) do
    if capped? do
      {lk2, lv2} = if lk, do: {lk, lv}, else: previous_version_token(vers, cps)
      {Enum.reverse(vers), Enum.reverse(cps), true, lk2, lv2}
    else
      {Enum.reverse(vers), Enum.reverse(cps), false, lk, lv}
    end
  end

  defp do_collapse_versions(
         [obj | rest],
         prefix,
         delimiter,
         max,
         vers,
         seen,
         cps,
         _lk,
         _lv,
         capped?
       ) do
    count = length(vers) + MapSet.size(seen)

    cond do
      count >= max ->
        {last_key, last_vid} = previous_version_token(vers, cps)
        {Enum.reverse(vers), Enum.reverse(cps), true, last_key, last_vid}

      true ->
        case common_prefix_of(obj.key, prefix, delimiter) do
          nil ->
            do_collapse_versions(
              rest,
              prefix,
              delimiter,
              max,
              [obj | vers],
              seen,
              cps,
              obj.key,
              obj.version_id,
              capped?
            )

          cp ->
            if MapSet.member?(seen, cp) do
              do_collapse_versions(
                rest,
                prefix,
                delimiter,
                max,
                vers,
                seen,
                cps,
                cp,
                nil,
                capped?
              )
            else
              do_collapse_versions(
                rest,
                prefix,
                delimiter,
                max,
                vers,
                MapSet.put(seen, cp),
                [cp | cps],
                cp,
                nil,
                capped?
              )
            end
        end
    end
  end

  # 截断游标 = 已返回的最后一项（version 行 → 其 key/version_id；公共前缀 → key=cp, version_id=nil）。
  defp previous_version_token([obj | _], _cps), do: {obj.key, obj.version_id}
  defp previous_version_token([], [cp | _]), do: {cp, nil}
  defp previous_version_token([], []), do: {nil, nil}

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
    # 多版本模型：ListObjectsV2 只看当前版本（is_latest）且非删除标记（is_delete_marker=false）。
    base_query =
      from o in Object,
        where:
          o.bucket_name == ^bucket_name and o.is_latest == true and o.is_delete_marker == false,
        order_by: [asc: o.key]

    base_query =
      if prefix != "" do
        where(base_query, [o], like(o.key, ^(escape_like(prefix) <> "%")))
      else
        base_query
      end

    base_query = if cursor, do: where(base_query, [o], o.key > ^cursor), else: base_query

    # ROUTE B B1-3 临时硬 LIMIT 闸：PG 权威期无界 Repo.all 大桶 = DoS。给 SQL 加有界 limit，
    # 折叠 delimiter 时一个公共前缀可吃掉任意多行（无固定 max_keys 倍数能保证填满一页），
    # 上限 sql_hard_limit（默认 100_000）防 DoS。B3 drive-walk 上线后保留为兜底。
    fetch_limit = list_fetch_limit(max_keys)
    candidates = Repo.all(limit(base_query, ^fetch_limit))

    # 若候选数恰好等于 fetch_limit，SQL 可能在攒够 max_keys 个 distinct 结果前就被截断；
    # 此时无法证明列举完整，须强制 is_truncated=true + 续点（正确性优先于伪完整）。
    capped? = length(candidates) == fetch_limit

    {objects, common_prefixes, truncated, next_token} =
      collapse(candidates, prefix, delimiter, max_keys, capped?)

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
  # capped? = SQL 候选被 fetch_limit 截断；候选耗尽却未达 max_keys 时不能宣称完整。
  defp collapse(candidates, prefix, delimiter, max_keys, capped?) do
    do_collapse(candidates, prefix, delimiter, max_keys, [], MapSet.new(), [], nil, capped?)
  end

  # 候选耗尽。capped? 为真说明 SQL LIMIT 可能在攒满 max_keys 前就截断了候选流——无法证明
  # 列举完整，强制 is_truncated=true + 续点（last 已折叠的最后结果），让客户端再查；
  # 否则（确实扫到 keyspace 末尾）才是 is_truncated=false。
  defp do_collapse([], _prefix, _delim, _max, objs, _seen_set, cps, last, capped?) do
    if capped? do
      {Enum.reverse(objs), Enum.reverse(cps), true, last || previous_token(objs, cps)}
    else
      {Enum.reverse(objs), Enum.reverse(cps), false, nil}
    end
  end

  defp do_collapse([obj | rest], prefix, delimiter, max, objs, seen_set, cps, _last, capped?) do
    count = length(objs) + MapSet.size(seen_set)

    cond do
      count >= max ->
        # 已达上限且还有候选 → 截断；next token = 上一个返回项（对象 key 或公共前缀）
        last = previous_token(objs, cps)
        {Enum.reverse(objs), Enum.reverse(cps), true, last}

      true ->
        case common_prefix_of(obj.key, prefix, delimiter) do
          nil ->
            do_collapse(
              rest,
              prefix,
              delimiter,
              max,
              [obj | objs],
              seen_set,
              cps,
              obj.key,
              capped?
            )

          cp ->
            if MapSet.member?(seen_set, cp) do
              # 已折叠过的公共前缀，跳过该对象不计数
              do_collapse(rest, prefix, delimiter, max, objs, seen_set, cps, cp, capped?)
            else
              do_collapse(
                rest,
                prefix,
                delimiter,
                max,
                objs,
                MapSet.put(seen_set, cp),
                [cp | cps],
                cp,
                capped?
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

  # ROUTE B B1-3 SQL LIST 临时硬 LIMIT 闸：有界取数行数 = min(sql_hard_limit, max_keys*4+1000)。
  # 折叠 delimiter 余量取 *4+1000（一个公共前缀可吃掉很多行，max_keys+1 不够）；上限硬 LIMIT 防 DoS。
  defp list_fetch_limit(max_keys) do
    hard_limit = Application.get_env(:maxio, :listing, [])[:sql_hard_limit] || 100_000
    min(hard_limit, max_keys * 4 + 1000)
  end

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
