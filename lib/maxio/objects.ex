defmodule Maxio.Objects do
  @moduledoc """
  对象元数据上下文：写/读/删元数据 + ListObjectsV2 查询（prefix/delimiter/max-keys/
  continuation-token/start-after，含 CommonPrefixes 折叠与分页 token）。
  字节读写不在此（走 Maxio.Storage），本上下文只管元数据与列举逻辑。
  """
  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.Buckets
  alias Maxio.Cluster.Notify
  alias Maxio.Objects.Object
  alias Maxio.S3.Log
  alias Maxio.S3.SystemHeaders
  alias Maxio.Sidecar
  alias Maxio.Versioning.VersionId

  @max_keys_limit 1000

  # ROUTE B B5-1 —— reconcile upsert 的 on_conflict 全字段替换集：scanner 以盘上 sidecar 为权威
  # 收敛 PG 行，**所有读可见字段**都必须被替换（含 tags/sse/metadata——与写路径 upsert 的最小替换集
  # 不同：写路径各字段由请求显式给出，reconcile 则须整行向 sidecar 收敛），外加同步追踪列。
  @reconcile_replace [
    :size,
    :etag,
    :content_type,
    :content_encoding,
    :content_disposition,
    :cache_control,
    :expires,
    :metadata,
    :storage_class,
    :acl_canned,
    :acl_grants,
    :tags,
    :sse_algorithm,
    :sse_envelope,
    :is_latest,
    :is_delete_marker,
    :synced_at,
    :index_generation,
    :updated_at
  ]

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
  size、etag；可含 content_type、metadata、storage_class、SSE 字段与可控系统头。桶不存在 → {:error, :no_such_bucket}。
  CopyObject / Multipart Complete 走此路径（字节落 null 路径，对象当 null 版本）。
  """
  @spec put_metadata(String.t(), String.t(), map()) ::
          {:ok, Object.t()} | {:error, :no_such_bucket | Ecto.Changeset.t()}
  def put_metadata(bucket_name, key, attrs) do
    with {:ok, bucket} <- bucket_or_error(bucket_name) do
      base =
        %{
          bucket_id: bucket.id,
          bucket_name: bucket_name,
          key: key,
          size: Map.fetch!(attrs, :size),
          etag: Map.fetch!(attrs, :etag),
          content_type: Map.get(attrs, :content_type, "binary/octet-stream"),
          metadata: Map.get(attrs, :metadata, %{}),
          storage_class: Map.get(attrs, :storage_class, "STANDARD"),
          acl_canned: Map.get(attrs, :acl_canned, "private"),
          acl_grants: Map.get(attrs, :acl_grants, %{"grants" => []}),
          sse_algorithm: Map.get(attrs, :sse_algorithm),
          sse_envelope: Map.get(attrs, :sse_envelope),
          version_id: "null",
          is_latest: true,
          is_delete_marker: false,
          # ROUTE B B5-1：写穿即视作与盘上 sidecar 同步（写路径盘先 PG 后，提交时盘上已权威落盘）；
          # generation 来自 attrs（MPU complete 当前恒缺省 0），B5-2 scanner 据此判 stale。
          synced_at: DateTime.utc_now(),
          index_generation: Map.get(attrs, :generation, 0)
        }
        |> Map.merge(SystemHeaders.take(attrs))
        |> Map.merge(placement_attrs(attrs))

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
                 :content_encoding,
                 :content_disposition,
                 :cache_control,
                 :expires,
                 :metadata,
                 :storage_class,
                 :acl_canned,
                 :acl_grants,
                 :sse_algorithm,
                 :sse_envelope,
                 :placement_set_id,
                 :placement_pool_id,
                 :placement_topology_hash,
                 :is_latest,
                 :is_delete_marker,
                 :synced_at,
                 :index_generation,
                 :inserted_at,
                 :updated_at
               ]},
            conflict_target: [:bucket_id, :key, :version_id]
          )

        obj
      end)
    end
  end

  @doc """
  ROUTE B B5-1 —— best-effort 索引写（与 put_metadata/3 同参数/同语义，但捕获异常返回
  `{:error, term}` 而非抛出，成功归一为 `:ok`）。

  用于 `authoritative_source(:write) == :sidecar` 的 CompleteMultipartUpload：盘上 assemble 已写出
  权威 maxio/2 sidecar（达 write_quorum），PG 仅作派生索引，故 PG 写失败**非致命**——调用方据
  `:ok | {:error, reason}` 记 Log.error 而非让 Complete 失败（去 PG 写路径 SPOF，铁律 3 绝不静默）。
  `:pg` 默认权威仍走 put_metadata/3 的致命语义。与 put_version_index/4、insert_delete_marker_index/3
  同一 `*_index` best-effort 包装契约。
  """
  @spec put_metadata_index(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put_metadata_index(bucket_name, key, attrs) do
    case put_metadata(bucket_name, key, attrs) do
      {:ok, _obj} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc "更新当前对象版本 ACL（PutObjectAcl）。对象不存在 → :not_found。"
  @spec put_acl(String.t(), String.t(), String.t(), map()) :: :ok | {:error, :not_found}
  def put_acl(bucket_name, key, canned, grants_doc \\ %{"grants" => []}) do
    put_acl_version(bucket_name, key, nil, canned, grants_doc)
  end

  @doc "更新对象指定版本 ACL。version_id=nil 表示当前版本。对象不存在 → :not_found。"
  @spec put_acl_version(
          String.t(),
          String.t(),
          String.t() | nil,
          String.t(),
          map(),
          integer() | nil
        ) ::
          :ok | {:error, :not_found}
  def put_acl_version(bucket_name, key, version_id, canned, grants_doc, generation \\ nil) do
    fetch =
      if version_id,
        do: get_version(bucket_name, key, version_id),
        else: get_metadata(bucket_name, key)

    case fetch do
      {:ok, obj} ->
        attrs =
          %{acl_canned: canned, acl_grants: grants_doc}
          |> maybe_synced_generation(generation)

        obj |> Object.changeset(attrs) |> Repo.update!()
        Notify.broadcast({:object_metadata_changed, bucket_name, key, obj.version_id})
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp maybe_synced_generation(attrs, generation) when is_integer(generation) do
    attrs
    |> Map.put(:synced_at, DateTime.utc_now())
    |> Map.put(:index_generation, generation)
  end

  defp maybe_synced_generation(attrs, _generation), do: attrs

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
        Notify.broadcast({:object_metadata_changed, bucket_name, key, obj.version_id})
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
  attrs 至少含 size、etag；可含 content_type/metadata/storage_class/acl_canned/tags/sse_algorithm
  与可控系统头。
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
          :content_encoding,
          :content_disposition,
          :cache_control,
          :expires,
          :metadata,
          :storage_class,
          :acl_canned,
          :acl_grants,
          :tags,
          :sse_algorithm,
          :sse_envelope,
          :placement_set_id,
          :placement_pool_id,
          :placement_topology_hash
        ])
        |> Map.merge(%{
          bucket_id: bucket.id,
          bucket_name: bucket_name,
          key: key,
          size: Map.fetch!(attrs, :size),
          etag: Map.fetch!(attrs, :etag),
          version_id: version_id,
          is_latest: true,
          is_delete_marker: false,
          # ROUTE B B5-1：写穿即视作与盘上 sidecar 同步（写路径盘先 PG 后，提交时盘上已权威落盘）；
          # generation 来自 attrs（PUT/Copy 路径当前恒缺省 0），B5-2 scanner 据此判 stale。
          synced_at: DateTime.utc_now(),
          index_generation: Map.get(attrs, :generation, 0)
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
                    :content_encoding,
                    :content_disposition,
                    :cache_control,
                    :expires,
                    :metadata,
                    :storage_class,
                    :acl_canned,
                    :acl_grants,
                    :sse_algorithm,
                    :sse_envelope,
                    :placement_set_id,
                    :placement_pool_id,
                    :placement_topology_hash,
                    :is_latest,
                    :is_delete_marker,
                    :synced_at,
                    :index_generation,
                    :inserted_at,
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
  @spec insert_delete_marker_with_id(String.t(), String.t(), String.t(), map()) ::
          {:ok, %{version_id: String.t()}} | {:error, :no_such_bucket}
  def insert_delete_marker_with_id(bucket_name, key, version_id, attrs \\ %{}) do
    with {:ok, bucket} <- bucket_or_error(bucket_name) do
      base =
        %{
          bucket_id: bucket.id,
          bucket_name: bucket_name,
          key: key,
          size: 0,
          etag: "",
          version_id: version_id,
          is_latest: true,
          is_delete_marker: true,
          # ROUTE B B5-1：写穿即视作同步；delete marker sidecar entry generation 恒 0（B5-0 既定）。
          synced_at: DateTime.utc_now(),
          index_generation: 0
        }
        |> Map.merge(placement_attrs(attrs))

      Repo.transaction(fn ->
        unset_latest(bucket.id, key)

        {:ok, _} =
          %Object{}
          |> Object.changeset(base)
          |> Repo.insert(
            on_conflict:
              {:replace,
               [
                 :size,
                 :etag,
                 :placement_set_id,
                 :placement_pool_id,
                 :placement_topology_hash,
                 :is_latest,
                 :is_delete_marker,
                 :synced_at,
                 :index_generation,
                 :inserted_at,
                 :updated_at
               ]},
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
  @spec insert_delete_marker_index(String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def insert_delete_marker_index(bucket_name, key, version_id, attrs \\ %{}) do
    case insert_delete_marker_with_id(bucket_name, key, version_id, attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  ROUTE B B5-1 —— 标记某 PG 索引行已与盘上 sidecar 权威确认同步（B5-2 Scanner 契约函数）。
  更新 synced_at=now、index_generation=generation；**不**触碰 updated_at（同步确认不是对象内容变更，
  绝不漂移 Last-Modified 语义）。行不存在 → {:error, :not_found}。
  """
  @spec mark_synced(String.t(), String.t(), String.t(), integer()) :: :ok | {:error, :not_found}
  def mark_synced(bucket_name, key, version_id, generation) when is_integer(generation) do
    {count, _} =
      from(o in Object,
        where: o.bucket_name == ^bucket_name and o.key == ^key and o.version_id == ^version_id
      )
      |> Repo.update_all(set: [synced_at: DateTime.utc_now(), index_generation: generation])

    if count > 0, do: :ok, else: {:error, :not_found}
  end

  @doc """
  ROUTE B B5-1 —— 以盘上 sidecar 权威版本 entry 收敛 PG 派生索引行（B5-2 Scanner 契约函数）。

  `Sidecar.to_object_attrs/3` 把 entry 翻成行 attrs 后按 (bucket_id,key,version_id) upsert
  **全读可见字段**（`@reconcile_replace`，含 tags/sse/metadata/is_latest/is_delete_marker——
  reconcile 必须整行向盘收敛，与写路径请求驱动的最小替换集不同），并在**同一 upsert 内**置
  synced_at=now、index_generation=entry generation（mark_synced 语义原子融合，免二次往返/部分更新窗口）。
  entry is_latest=true 时先 unset 该 key 其余 latest 行（与写路径同事务语义）；is_latest=false
  （历史版本 reconcile）不触碰其他行。

  **ROUTE B B5-3 R1 —— `updated_at` 忠于对象写入时刻**：`updated_at` 是客户端可见 Last-Modified /
  `<LastModified>` 的来源，S3 语义下它随对象写入固定、绝不随扫描漂移。故从 canonical entry 的
  `modtime`（int64 纳秒，`Sidecar.entry_modtime_datetime/1`，与读路径同源）导出 `updated_at`；
  modtime 缺失（异常 sidecar）→ 既有行保留其 updated_at（`:updated_at` 剔出 replace 集）、
  新插行回落 timestamps now + divergent 日志（铁律 3 不静默）。`synced_at` 仍用 now——它就是
  「同步确认时刻」。

  best-effort 契约（scanner 逐版本调用，单行失败绝不炸整轮）：成功 `:ok`；桶缺失
  `{:error, :no_such_bucket}`；changeset/DB 异常 → `{:error, term}`（绝不抛，铁律 3 由调用方记日志）。
  """
  @spec reconcile_from_sidecar(String.t(), String.t(), Sidecar.version_entry()) ::
          :ok | {:error, term()}
  def reconcile_from_sidecar(bucket_name, key, %{} = entry) do
    with {:ok, bucket} <- bucket_or_error(bucket_name) do
      attrs = Sidecar.to_object_attrs(bucket_name, key, entry)

      base =
        Map.merge(attrs, %{
          bucket_id: bucket.id,
          bucket_name: bucket_name,
          key: key,
          synced_at: DateTime.utc_now(),
          index_generation: entry_generation(entry)
        })

      {updated_at, replace_fields} =
        case Sidecar.entry_modtime_datetime(entry) do
          {:ok, dt} ->
            {dt, @reconcile_replace}

          :error ->
            Log.warn(
              "reconcile: sidecar entry missing modtime, preserving existing updated_at",
              bucket: bucket_name,
              key: key,
              reason: "version_id=#{entry["version_id"]} modtime=#{inspect(entry["modtime"])}"
            )

            {nil, @reconcile_replace -- [:updated_at]}
        end

      result =
        Repo.transaction(fn ->
          if base[:is_latest], do: unset_latest(bucket.id, key)

          changeset = Object.changeset(%Object{}, base)

          changeset =
            if updated_at,
              do: Ecto.Changeset.put_change(changeset, :updated_at, updated_at),
              else: changeset

          case Repo.insert(changeset,
                 on_conflict: {:replace, replace_fields},
                 conflict_target: [:bucket_id, :key, :version_id]
               ) do
            {:ok, _obj} -> :ok
            {:error, cs} -> Repo.rollback(cs)
          end
        end)

      case result do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  ROUTE B B5-1 —— PG 索引行相对盘上 sidecar 权威 entry 是否过期（B5-2 Scanner 契约函数）。

  比对 generation（row.index_generation vs entry generation）+ 读可见字段集（etag/size/content_type/
  可控系统头/metadata/tags/storage_class/acl_canned/sse/is_latest/is_delete_marker——Sidecar.signature/1 身份
  字段的 PG 可表达超集；modtime 无 PG 列不比，version_id 即查找键不比）。任一不一致 → true（stale，
  scanner 走 reconcile_from_sidecar/3 收敛）。
  """
  @spec stale?(Object.t(), Sidecar.version_entry()) :: boolean()
  def stale?(%Object{} = row, %{} = entry) do
    attrs = Sidecar.to_object_attrs(row.bucket_name, row.key, entry)

    # attrs 侧 to_object_attrs 已对 metadata/tags 兜底 %{}（绝不 nil）；row 侧列可空，须 || %{} 归一。
    row.index_generation != entry_generation(entry) or
      row.etag != attrs.etag or
      row.size != attrs.size or
      row.content_type != attrs.content_type or
      row.content_encoding != attrs.content_encoding or
      row.content_disposition != attrs.content_disposition or
      row.cache_control != attrs.cache_control or
      row.expires != attrs.expires or
      (row.metadata || %{}) != attrs.metadata or
      (row.tags || %{}) != attrs.tags or
      row.storage_class != attrs.storage_class or
      row.acl_canned != attrs.acl_canned or
      (row.acl_grants || %{"grants" => []}) != attrs.acl_grants or
      row.sse_algorithm != attrs.sse_algorithm or
      row.sse_envelope != attrs.sse_envelope or
      row.is_latest != attrs.is_latest or
      row.is_delete_marker != attrs.is_delete_marker
  end

  # sidecar 版本 entry 的 generation（缺失/非整数 → 0，与 Sidecar 排序键同兜底）。
  defp entry_generation(%{"generation" => g}) when is_integer(g), do: g
  defp entry_generation(_entry), do: 0

  defp placement_attrs(attrs) do
    Map.take(attrs, [:placement_set_id, :placement_pool_id, :placement_topology_hash])
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

  @doc """
  ROUTE B fidelity —— best-effort 版本删除索引维护（与 delete_version/3 同语义，但行不存在与成功
  都归一 `:ok`，异常捕获返回 `{:error, term}` 而非抛出）。

  用于 `authoritative_source(:write) == :sidecar` 的 DELETE ?versionId：盘上版本目录的 quorum 删除
  （`Maxio.Storage.delete_version/4`）才是权威提交，PG 行删除仅派生索引维护，故 PG 失败**非致命**——
  调用方据 `:ok | {:error, reason}` 记 Log.error 而非让 DELETE 失败（漂移留待 scanner reverse-GC
  收敛：盘上已全端点显式 missing 的行会被下一轮 GC）。`:pg` 默认权威仍走 delete_version/3 的
  权威语义。与 put_version_index/4、insert_delete_marker_index/3 同一 `*_index` best-effort 契约。
  """
  @spec delete_version_index(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_version_index(bucket_name, key, version_id) do
    case delete_version(bucket_name, key, version_id) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
    end
  rescue
    e -> {:error, e}
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
    max_keys = normalize_max_keys(Map.get(opts, :max_keys, @max_keys_limit))
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
    max_keys = normalize_max_keys(Map.get(opts, :max_keys, @max_keys_limit))
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

  defp normalize_max_keys(n) when is_integer(n) and n > 0, do: min(n, @max_keys_limit)
  defp normalize_max_keys(_), do: @max_keys_limit

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
