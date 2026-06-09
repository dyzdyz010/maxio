defmodule Maxio.ObjectMeta do
  @moduledoc """
  ROUTE B P2 —— 对象元数据门面（dual-read SHADOW）。

  读路径：PG 仍权威（`authoritative_source(:read)` 默认 `:pg`），同时跨 N 端点读 sidecar 并
  `Maxio.MetaReconcile` 仲裁，逐字段比对 PG 与 sidecar 视图，**返回 PG 结果**（不翻权威），
  分歧 -> 结构化 `Log.warn`（铁律 3 绝不静默）。reconcile 出的 divergent 端点 -> 记 heal 钩子
  （本阶段仅日志；实际 heal 回写落 P4）。

  P4 之后把 `authoritative_source(:read)` 切 `:sidecar` 即翻转读权威（届时 reconcile 错误直接成
  read-quorum 5xx）。本阶段 reconcile 错误**不影响响应**（PG 权威），仅记日志。
  """

  alias Maxio.{Objects, Sidecar, MetaReconcile}
  alias Maxio.Cluster.{Router, Topology, Paths}
  alias Maxio.Storage.Erasure.Config
  alias Maxio.S3.Log

  @doc "读/列/写的元数据权威来源（读 config，可经 opts 覆盖 for tests）。"
  @spec authoritative_source(:read | :list | :write) :: :pg | :sidecar
  def authoritative_source(kind) do
    Application.get_env(:maxio, :authoritative_source, read: :pg)
    |> Keyword.get(kind, :pg)
  end

  @doc """
  读对象元数据。SHADOW 模式：返回 PG 权威 `%Object{}`（或 `{:error,:not_found}`），
  并 best-effort 跨端点 sidecar reconcile + 分歧日志（不影响返回值、不抛错）。
  version_id=nil 读 latest；否则读指定版本。
  """
  @spec get(String.t(), String.t(), String.t() | nil, keyword()) ::
          Objects.Object.t() | {:error, :not_found}
  def get(bucket, key, version_id \\ nil, opts \\ []) do
    pg = pg_read(bucket, key, version_id)
    shadow_check(bucket, key, version_id, pg, opts)
    pg
  end

  # PG 权威读：get_metadata/get_version 均返回 {:ok, %Object{}} | {:error, :not_found}，
  # 解包成裸 %Object{}（命中）或 {:error, :not_found}，供 handler/shadow 统一消费。
  defp pg_read(bucket, key, nil) do
    case Objects.get_metadata(bucket, key) do
      {:ok, obj} -> obj
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp pg_read(bucket, key, vid) do
    case Objects.get_version(bucket, key, vid) do
      {:ok, obj} -> obj
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  best-effort shadow 比对：读全 N 端点 sidecar -> reconcile -> 比对 PG。任何异常都被吞并记日志
  （shadow 绝不破坏读路径）。返回 :ok。

  门控（铁律 4：结构化日志须有用、非每请求错误噪声）：仅当**确有 sidecar-backed 分布式拓扑**
  （`Topology.configured?/0` 真，或 test 经 `opts[:topology]` 显式注入）时才执行；单机 FS / dev / test
  默认无拓扑 -> 直接短路 :ok（shadow 在 FS 上零有用工作，绝不靠 rescue 吞一个必然的 ArgumentError）。

  版本定位（修复 versioned-latest 假分歧）：sidecar 文件随**解析后的 PG 对象版本**落盘
  （`Storage.get` 用 `object.version_id`，方案 B 每版本独立目录）。故 latest 读（请求 version_id=nil）
  须用 PG 行的 `version_id`（一个 ULID）定位 sidecar 路径与 reconcile target，绝不用请求级 nil
  退化成 "null" 版本路径（那是空的，会系统性误报 read_quorum / sidecar-missing 分歧）。
  """
  @spec shadow_check(String.t(), String.t(), String.t() | nil, term(), keyword()) :: :ok
  def shadow_check(bucket, key, version_id, pg, opts) do
    if shadow_enabled?(opts) do
      # 路径与 target 都基于「有效版本」：请求显式带 version_id 用之；否则（latest 读）取解析后的
      # PG 行 version_id；无 PG 行（PG 缺对象）回退请求级 version_id || "null"（与历史一致）。
      eff_vid = effective_version_id(version_id, pg)
      target = if eff_vid == "null", do: :latest, else: {:version, eff_vid}

      try do
        do_shadow(bucket, key, version_id, eff_vid, target, pg, opts)
      rescue
        e -> Log.warn("metadata shadow error", bucket: bucket, key: key, reason: inspect(e))
      catch
        kind, reason ->
          Log.warn("metadata shadow caught",
            bucket: bucket,
            key: key,
            reason: inspect({kind, reason})
          )
      end
    end

    :ok
  end

  # shadow 仅在确有分布式拓扑时有意义：test 显式注入 opts[:topology] 优先；否则读 Topology 是否已配置。
  defp shadow_enabled?(opts) do
    case Keyword.get(opts, :topology) do
      nil -> Topology.configured?()
      _t -> true
    end
  end

  # 有效版本：请求显式版本优先；latest 读取解析后 PG 行版本；无 PG 行回退 "null"（历史行为）。
  defp effective_version_id(version_id, _pg) when is_binary(version_id), do: version_id
  defp effective_version_id(nil, %Objects.Object{version_id: vid}) when is_binary(vid), do: vid
  defp effective_version_id(_version_id, _pg), do: "null"

  defp do_shadow(bucket, key, version_id, eff_vid, target, pg, opts) do
    copies = read_endpoint_sidecars(bucket, key, eff_vid, opts)
    rq = read_quorum(opts)

    case MetaReconcile.reconcile(copies, rq, target) do
      {:ok, entry, divergent} ->
        if divergent != [],
          do:
            Log.warn("sidecar divergence (heal pending)",
              bucket: bucket,
              key: key,
              version_id: version_id,
              divergent: inspect(divergent)
            )

        compare(bucket, key, version_id, pg, Sidecar.to_view(bucket, key, entry))

      {:error, :read_quorum} ->
        # PG 有对象但 sidecar 不足 quorum -> 记分歧（P4 翻权威后此为 5xx，本阶段仅日志）
        case pg do
          %Objects.Object{} ->
            Log.warn("metadata divergence: sidecar read_quorum unmet while PG has object",
              bucket: bucket,
              key: key,
              version_id: version_id
            )

          _ ->
            :ok
        end
    end
  end

  # 逐字段比对 PG %Object{} 与 sidecar 视图；不一致 -> 日志（返回 :ok）
  defp compare(bucket, key, version_id, %Objects.Object{} = pg, view) do
    diffs =
      [
        field_diff(:etag, pg.etag, view.etag),
        field_diff(:size, pg.size, view.size),
        field_diff(:content_type, pg.content_type, view.content_type),
        field_diff(:is_delete_marker, pg.is_delete_marker, view.is_delete_marker),
        field_diff(:storage_class, pg.storage_class, view.storage_class)
      ]
      |> Enum.reject(&is_nil/1)

    if diffs != [],
      do:
        Log.warn("metadata divergence: PG vs sidecar",
          bucket: bucket,
          key: key,
          version_id: version_id,
          diffs: inspect(diffs)
        )

    :ok
  end

  defp compare(bucket, key, version_id, _pg_nil_or_error, _view) do
    # sidecar 有 quorum 但 PG 无 -> 分歧（PG 落后或漏写）
    Log.warn("metadata divergence: sidecar has object while PG does not",
      bucket: bucket,
      key: key,
      version_id: version_id
    )

    :ok
  end

  defp field_diff(_field, same, same), do: nil
  defp field_diff(field, pg_v, sc_v), do: {field, pg: pg_v, sidecar: sc_v}

  @doc """
  ROUTE B P3 —— ListObjectsV2 的 drive-walk shadow（best-effort，不翻 list 权威）。

  比对 PG SQL 结果（`opts[:pg]`）与 `Maxio.Listing` 跨端点走盘结果的 **key 集 + common_prefixes**
  （走盘只到 key 级，无对象元数据，故不比 ETag/Size/LastModified——见 Maxio.Listing 边界说明），
  任一侧多出 key 或 common_prefix 即 `Log.warn` 结构化分歧（铁律 3 绝不静默）。

  任何异常 / throw / exit 都被自吞并降级为一条 warn（shadow 绝不破坏列举路径，同 read shadow）。
  恒返回 `:ok`。`opts` 同时透传给 `Maxio.Listing.list_objects_v2/3`（`:transport` / `:topology`）。

  ## 门控：仅 Unversioned 桶（保真安全网）

  drive-walk 对 delete marker 的判定依赖当前版本在盘上确有 sidecar（`build_meta` 现恒带
  `is_delete_marker`）；但纯 PG delete marker（`Objects.insert_delete_marker` 当前不落盘）在盘上
  无痕迹——Enabled 桶 delete marker latest 的 key 会被 drive-walk 误判为 live（盘上仅旧版本），
  Suspended 桶被删 null 对象的陈旧 `<bucket>/<key>/meta.json` 同样残留。两者都会让 versioned/
  suspended 桶上的 shadow 产生**保证性伪分歧**（与权威 is_latest/is_delete_marker 过滤系统性不符），
  淹没铁律 3 分歧日志。故 list shadow **门控到 Unversioned 桶**：versioned/suspended 桶直接短路
  :ok（不跑 drive-walk、不比对）。版本树枚举（Maxio.Listing）本身已正确，门控解除待 delete marker
  落盘 sidecar 模型补齐（P4/B4 翻 list 权威时）。

  桶 versioning 状态：`opts[:bucket_versioning]` 显式覆盖（test）优先；否则查 `Buckets.lookup/1`
  （缺省/查不到 -> "Unversioned"，与 handler `bucket_versioning/1` 同语义）。
  """
  @spec list_shadow(String.t(), map(), keyword()) :: :ok
  def list_shadow(bucket, list_opts, opts) do
    if list_shadow_enabled?(bucket, opts) do
      pg = Keyword.get(opts, :pg)

      try do
        walk = Maxio.Listing.list_objects_v2(bucket, list_opts, opts)
        compare_list(bucket, pg, walk)
      rescue
        e -> Log.warn("list shadow error", bucket: bucket, reason: inspect(e))
      catch
        kind, reason ->
          Log.warn("list shadow caught", bucket: bucket, reason: inspect({kind, reason}))
      end
    end

    :ok
  end

  # list shadow 门控：仅 Unversioned 桶（见 @doc）。test 经 opts[:bucket_versioning] 注入覆盖。
  defp list_shadow_enabled?(bucket, opts) do
    versioning_of(bucket, opts) == "Unversioned"
  end

  # 桶 versioning：opts[:bucket_versioning]（handler 透传，prod 主路径）优先；否则查 DB 兜底
  # （直接调用者/单测）。DB 不可用/无 sandbox/桶不存在 -> "Unversioned"（shadow 绝不因取 versioning
  # 失败而破坏列举路径，与本模块自吞哲学一致）。
  defp versioning_of(bucket, opts) do
    case Keyword.get(opts, :bucket_versioning) do
      v when is_binary(v) ->
        v

      _ ->
        try do
          case Maxio.Buckets.lookup(bucket) do
            {:ok, %{versioning: v}} when is_binary(v) -> v
            _ -> "Unversioned"
          end
        rescue
          _ -> "Unversioned"
        catch
          _, _ -> "Unversioned"
        end
    end
  end

  # 比对 PG 与 drive-walk 的 key 集 + common_prefixes；任一侧独有项 -> 结构化分歧日志（返回 :ok）。
  # objects 元素：PG 为 %Object{}、walk 为 %{key: ...}，两者均有 .key，故 & &1.key 统一取键。
  defp compare_list(bucket, %{} = pg, %{} = walk) do
    pg_keys = MapSet.new(Map.get(pg, :objects, []), & &1.key)
    walk_keys = MapSet.new(Map.get(walk, :objects, []), & &1.key)
    pg_cps = MapSet.new(Map.get(pg, :common_prefixes, []))
    walk_cps = MapSet.new(Map.get(walk, :common_prefixes, []))

    only_pg = MapSet.difference(pg_keys, walk_keys)
    only_walk = MapSet.difference(walk_keys, pg_keys)
    cp_only_pg = MapSet.difference(pg_cps, walk_cps)
    cp_only_walk = MapSet.difference(walk_cps, pg_cps)

    if MapSet.size(only_pg) > 0 or MapSet.size(only_walk) > 0 or
         MapSet.size(cp_only_pg) > 0 or MapSet.size(cp_only_walk) > 0 do
      Log.warn("list divergence: PG vs drive-walk",
        bucket: bucket,
        reason:
          inspect(
            only_pg: Enum.take(MapSet.to_list(only_pg), 20),
            only_walk: Enum.take(MapSet.to_list(only_walk), 20),
            cp_only_pg: MapSet.to_list(cp_only_pg),
            cp_only_walk: MapSet.to_list(cp_only_walk)
          )
      )
    end

    :ok
  end

  defp compare_list(_bucket, _pg, _walk), do: :ok

  # 读全 N 端点 sidecar -> [%{node, drive, meta} | :missing]。eff_vid 已是落盘版本（"null" 或 ULID），
  # 与 Storage.get(bucket, key, object.version_id, ...) 的字节/sidecar 落点一致（方案 B 每版本独立目录）。
  defp read_endpoint_sidecars(bucket, key, eff_vid, opts) do
    transport = Keyword.get(opts, :transport, Maxio.Cluster.Transport.impl(opts))
    endpoints = endpoints_for(bucket, key, opts)

    case Paths.object_rel(bucket, key, eff_vid) do
      {:ok, rel} ->
        Enum.map(endpoints, fn {node, drive} ->
          dir = Path.join(drive, rel)

          case transport.get_sidecar(node, dir) do
            {:ok, meta} -> %{node: node, drive: drive, meta: meta}
            {:error, _} -> :missing
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp endpoints_for(bucket, key, opts) do
    case Keyword.get(opts, :topology) do
      nil ->
        set_id = Router.set_for(bucket, key)
        Topology.endpoints(set_id)

      t ->
        set_id = Router.set_for(bucket, key, t)
        Topology.endpoints_from(t, set_id)
    end
  end

  defp read_quorum(opts) do
    cfg = Config.load!(Keyword.take(opts, [:drives, :data_shards, :parity_shards, :block_size]))
    cfg.read_quorum
  rescue
    _ -> Keyword.get(opts, :read_quorum, 1)
  end
end
