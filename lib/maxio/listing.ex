defmodule Maxio.Listing do
  @moduledoc """
  ROUTE B P3 —— 跨端点 drive-walk LIST（shadow，不翻权威）。

  对桶下每个 erasure set 的每个端点递归走盘（`Maxio.Cluster.Transport.list_dir`），把「含
  meta.json 的目录」的相对路径作为对象 key 收集（同 key 在 N 端点/跨 set 去重），按 key 升序
  排序后惰性折叠 prefix/delimiter/start-after/max-keys，输出与 `Maxio.Objects.list_objects_v2/2`
  **逐字段一致**的 list_result（`objects, common_prefixes, is_truncated, next_continuation_token,
  key_count`）+ walk-position 续点（绝不 offset）。

  ## 版本树枚举（修复版本化对象 LIST 失明 —— 关键保真）

  对象布局（`Maxio.Cluster.Paths.object_rel/3`）：null 版本落 `<bucket>/<key>/meta.json`；任何
  ULID 版本落 `.versions/<bucket>/<key>/<version_id>/meta.json`。故 Enabled/Suspended 桶的「当前
  版本」可能只存在于 `.versions` 子树——若 drive-walk 只走 null 布局（曾经如此），会对**每个**版本化
  对象漏列（与权威 `Maxio.Objects.list_objects_v2/2` 的 is_latest 过滤产生系统性伪分歧，翻权威后更
  返回空/错列表）。对齐 MinIO 纠删后端（xl.meta 单目录承载一个 key 的全部版本）与 maxio 自身 heal
  层（`Maxio.Storage.Erasure.Heal.scan_versioned`：同时扫 `<bucket>/<key>/`(null) 与
  `.versions/<bucket>/<key>/<version_id>/`），本走盘把 `.versions` 树作为**对等对象源**枚举：

    * 递归 `.versions/<bucket>/` 收集每个含 meta.json 的叶目录 `{key, version_id}`
      （key = 叶路径去掉末段 `/<version_id>`，逐字对齐 `Heal.scan_versioned`）；
    * 同 key 的多个版本**收敛到当前版本**：ULID 字典序 = 时间序，max ULID = newest（null 版本作为
      对等参与，被任何更晚的 ULID 写覆盖；纯 null（无 ULID）则 null 即当前）；
    * **当前版本是 delete marker 的 key 直接剔除**（ListObjectsV2 不返回逻辑删除的 key，对齐 AWS：
      当前版本为 delete marker 时 GET 返回 404、ListObjectsV2 视同对象不存在）；当前版本的
      `is_delete_marker` 取自其落盘 sidecar meta（`build_meta` 现恒带该字段，缺省 false）；
    * 再与 null 布局 key UNION 去重，统一排序折叠。

  delete marker 可见性边界（诚实文档化）：当前实现里 delete marker 的判定**仅当其当前版本在盘上
  确有 meta.json**（即该版本真落了 sidecar）才生效；纯 PG delete marker（`insert_delete_marker`
  当前不落盘 sidecar/字节）在盘上无任何痕迹，drive-walk 无从感知。故 handler 把 list shadow
  **门控到 Unversioned 桶**（见 `Maxio.ObjectMeta.list_shadow` 门控），避免在 versioned/suspended
  桶上产生保证性噪声分歧；版本树枚举本身对「盘上确有版本目录」的场景已正确（直接调用 / 单测覆盖）。

  铁律 4：输出经 max_keys + 续点有界、绝无 SQL 那种无 LIMIT 全量物化 + DoS。

  MVP 已知边界（B3 范围，正确性优先于极致惰性，真·流式惰性走盘留后续优化）：
    * 候选 key 集大小 = 桶内对象数——走盘先把全部候选 key 收进 `MapSet` 去重再排序折叠；`max_keys`
      + 续点只把**输出**有界，候选集仍可能大。这是 MVP 已知边界（端点游标 + 堆归并按需产出留后续）。
    * shadow 阶段不强制 quorum 门：某 key 在任一端点命中（含 meta.json）即收为候选，避免与 PG
      误报分歧；quorum 确认（每对象须 read_quorum 个端点确认存在）留 B4 翻 list 权威时收紧。
    * 走盘只到 key 级——list_result 的 `objects` 元素仅含 `:key`（无 LastModified/ETag/Size）；
      B3-3 shadow 比对只比 key 集 + common_prefixes，不比对象元数据。翻权威时再读 sidecar 富集（P4）。

  续点语义（必须与权威路径 `Maxio.Objects.list_objects_v2/2` 逐字对齐——shadow 铁律）：
  `next_continuation_token` = 「本页最后纳入 objects/common_prefixes 的那条原始遍历 key」
  （walk-position）**的原文字符串**，绝不二次编码。下次客户端原样回传该 token，本端以
  `start_after = 该 key` 续走（严格大于），保证可分页遍历不重不漏（升序 + 严格大于游标）。

  为什么 token = 原始 key 而非 base64：权威路径（`objects.ex` `next_continuation_token` = 最后
  返回项的**裸** key）与本 shadow 由同一个 handler 喂同一份 client-echoed `list_opts`
  （`s3/handlers/bucket.ex` `list_objects_v2/1`）。若本 shadow 用 base64 包裹/解包，则客户端回传
  的「裸 PG key」会被本端当成 base64 解码成乱码游标（`"key1" -> <<145,236,181>>`）或解码失败
  （`"photos/2006/" -> :error`）回落 `start_after=nil` 走全桶，使第 2 页起 shadow 必报伪分歧并
  淹没铁律 3 分歧日志。故 token 编解码必须与权威路径同语义：原文 key 直通。
  """

  alias Maxio.Cluster.{Topology, Transport}

  @versions_prefix ".versions"

  defmodule Continuation do
    @moduledoc """
    walk-position 续点 token（= 最后产出的原始 key 字符串；绝非 offset，绝不二次编码）。

    与权威 `Maxio.Objects.list_objects_v2/2` 续点语义逐字对齐：token 即 key 原文。保留具名抽象
    （`encode/1` `decode/1`）以隔离「token 表示」决策、稳定 `decode :: {:ok, key} | :error` 契约，
    使调用点与续点演进解耦；当前实现为原文直通（identity）。
    """

    @spec encode(String.t()) :: String.t()
    def encode(last_key) when is_binary(last_key), do: last_key

    @spec decode(String.t()) :: {:ok, String.t()} | :error
    def decode(token) when is_binary(token), do: {:ok, token}
    def decode(_), do: :error
  end

  @spec list_objects_v2(String.t(), map(), keyword()) :: map()
  def list_objects_v2(bucket, list_opts, opts \\ []) do
    prefix = Map.get(list_opts, :prefix, "") || ""
    delimiter = Map.get(list_opts, :delimiter)
    max_keys = Map.get(list_opts, :max_keys, 1000) || 1000
    cursor = continuation_cursor(list_opts)

    keys =
      bucket
      |> collect_keys(opts)
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> apply_cursor(cursor)
      |> Enum.sort()

    {objects, common_prefixes, truncated, last} =
      fold(keys, prefix, delimiter, max_keys, [], MapSet.new(), [], nil)

    objects = Enum.reverse(objects)
    common_prefixes = Enum.reverse(common_prefixes)

    %{
      objects: objects,
      common_prefixes: common_prefixes,
      is_truncated: truncated,
      next_continuation_token: if(truncated, do: Continuation.encode(last), else: nil),
      key_count: length(objects) + length(common_prefixes)
    }
  end

  # continuation_token 优先于 start_after 作为分页游标（两者都是 key 的"严格大于"起点，对齐
  # Objects.list_objects_v2）。无法解码的 continuation_token 回落 start_after。
  defp continuation_cursor(list_opts) do
    case Map.get(list_opts, :continuation_token) do
      nil ->
        Map.get(list_opts, :start_after)

      tok ->
        case Continuation.decode(tok) do
          {:ok, k} -> k
          :error -> Map.get(list_opts, :start_after)
        end
    end
  end

  defp apply_cursor(keys, nil), do: keys
  defp apply_cursor(keys, cursor), do: Enum.filter(keys, &(&1 > cursor))

  # 收集桶下所有对象的【当前版本】key（跨 set 全端点递归走盘 + 版本树枚举，去重）：
  #   1. null 布局：<bucket>/<key>/meta.json -> key（当前版本 = null）；
  #   2. 版本树：.versions/<bucket>/<key>/<version_id>/meta.json -> {key, version_id}；
  # 两源合并后按 key 收敛到当前版本（max ULID，null 为对等），剔除当前版本为 delete marker 的 key。
  defp collect_keys(bucket, opts) do
    transport = Transport.impl(opts)
    topo = Keyword.get(opts, :topology)
    set_ids = if topo, do: Topology.all_set_ids_from(topo), else: Topology.all_set_ids()

    {null_keys, versioned} =
      set_ids
      |> Enum.flat_map(fn set_id ->
        endpoints =
          if topo, do: Topology.endpoints_from(topo, set_id), else: Topology.endpoints(set_id)

        Enum.flat_map(endpoints, fn {node, drive} ->
          null_layout = walk(transport, node, Path.join(drive, bucket), "")
          ver_layout = walk_versions(transport, node, versions_root(drive, bucket), "")
          Enum.map(null_layout, &{:null, &1}) ++ Enum.map(ver_layout, &{:versioned, &1})
        end)
      end)
      |> Enum.split_with(fn {kind, _} -> kind == :null end)

    null_set = MapSet.new(null_keys, fn {:null, key} -> key end)

    # 按 key 归集所有版本候选（null 源以 "null" 版本参与；版本树以各 ULID 参与），去重。
    by_key =
      versioned
      |> Enum.map(fn {:versioned, {key, vid}} -> {key, vid} end)
      |> Enum.concat(Enum.map(MapSet.to_list(null_set), &{&1, "null"}))
      |> Enum.group_by(fn {key, _vid} -> key end, fn {_key, vid} -> vid end)

    by_key
    |> Enum.map(fn {key, vids} -> {key, current_version(vids)} end)
    |> Enum.reject(fn {key, current_vid} ->
      delete_marker_current?(transport, opts, bucket, key, current_vid)
    end)
    |> Enum.map(fn {key, _vid} -> key end)
    |> Enum.uniq()
  end

  defp versions_root(drive, bucket), do: Path.join([drive, @versions_prefix, bucket])

  # 当前版本：ULID 字典序 = 时间序，max ULID = newest（null 作为对等参与）。
  # 仅 null（无任何 ULID）-> null 即当前；有 ULID -> 取字典序最大者（晚于 null 写的版本胜出）。
  defp current_version(vids) do
    case Enum.reject(vids, &(&1 == "null")) do
      [] -> "null"
      ulids -> Enum.max(ulids)
    end
  end

  # 当前版本是否为 delete marker：读其落盘 sidecar meta 的 is_delete_marker（缺省/缺失 -> false，
  # 即盘上无可判定信息时不剔除——见模块文档 delete marker 可见性边界 + handler 门控）。
  defp delete_marker_current?(transport, opts, bucket, key, current_vid) do
    case read_current_meta(transport, opts, bucket, key, current_vid) do
      {:ok, meta} -> Map.get(meta, "is_delete_marker", false) == true
      :error -> false
    end
  end

  # 从任一存活端点读该 key 当前版本的 sidecar（任一命中即可，shadow 阶段不强制 quorum）。
  defp read_current_meta(transport, opts, bucket, key, current_vid) do
    case Maxio.Cluster.Paths.object_rel(bucket, key, current_vid) do
      {:ok, rel} ->
        topo = Keyword.get(opts, :topology)
        set_ids = if topo, do: Topology.all_set_ids_from(topo), else: Topology.all_set_ids()

        Enum.find_value(set_ids, :error, fn set_id ->
          endpoints =
            if topo, do: Topology.endpoints_from(topo, set_id), else: Topology.endpoints(set_id)

          Enum.find_value(endpoints, fn {node, drive} ->
            case transport.get_sidecar(node, Path.join(drive, rel)) do
              {:ok, meta} -> {:ok, meta}
              {:error, _} -> nil
            end
          end)
        end)

      {:error, _} ->
        :error
    end
  end

  # 递归 DFS（null 布局）：dir = 端点下当前目录绝对路径；rel = 相对 bucket 根的 key 前缀。
  # 端点宕机/读失败（{:error, _}）-> 该子树跳过（铁律 3：结构化降级，绝不上抛炸列举路径）。
  defp walk(transport, node, dir, rel) do
    case transport.list_dir(node, dir, []) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn %{name: name, object?: obj?} ->
          child_rel = if rel == "", do: name, else: rel <> "/" <> name
          child_dir = Path.join(dir, name)
          here = if obj?, do: [child_rel], else: []
          here ++ walk(transport, node, child_dir, child_rel)
        end)

      {:error, _} ->
        []
    end
  end

  # 递归 DFS（版本树）：枚举 .versions/<bucket>/ 下每个含 meta.json 的叶目录，恢复 {key, version_id}。
  # 叶目录（object? = 含 meta.json）的 rel 形如 "<key...>/<version_id>"；拆末段为 version_id，
  # 其余为 key（逐字对齐 Heal.do_scan_versioned）。端点读失败 -> 该子树跳过（铁律 3）。
  defp walk_versions(transport, node, dir, rel) do
    case transport.list_dir(node, dir, []) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn %{name: name, object?: obj?} ->
          child_rel = if rel == "", do: name, else: rel <> "/" <> name
          child_dir = Path.join(dir, name)
          here = if obj?, do: split_version(child_rel), else: []
          here ++ walk_versions(transport, node, child_dir, child_rel)
        end)

      {:error, _} ->
        []
    end
  end

  # "<key...>/<version_id>" -> [{key, version_id}]；无 "/"（理论上不该出现）-> 丢弃（绝不误当 key）。
  defp split_version(rel) do
    case String.split(rel, "/") do
      [_single] ->
        []

      segs ->
        {key_segs, [vid]} = Enum.split(segs, length(segs) - 1)
        [{Enum.join(key_segs, "/"), vid}]
    end
  end

  # 惰性折叠：升序 key 流逐条扫描，累计到 max_keys（对象与公共前缀各计一个 key_count）。
  # last = 已纳入本页的最后一条原始遍历 key（续点 walk-position）；候选耗尽 -> 不截断。
  defp fold([], _prefix, _delim, _max, objs, _seen, cps, _last), do: {objs, cps, false, nil}

  defp fold([key | rest], prefix, delimiter, max, objs, seen, cps, last) do
    if length(objs) + MapSet.size(seen) >= max do
      # 已达上限且仍有候选 -> 截断；续点 = 上一条已纳入的 key（last）。
      {objs, cps, true, last}
    else
      case common_prefix(key, prefix, delimiter) do
        nil ->
          fold(rest, prefix, delimiter, max, [%{key: key} | objs], seen, cps, key)

        cp ->
          if MapSet.member?(seen, cp) do
            # 已折叠过的公共前缀，跳过该 key 不计数，但仍推进 walk-position。
            fold(rest, prefix, delimiter, max, objs, seen, cps, key)
          else
            fold(rest, prefix, delimiter, max, objs, MapSet.put(seen, cp), [cp | cps], key)
          end
      end
    end
  end

  # 该 key 去掉 prefix 后剩余若含 delimiter -> prefix <> 截到首个 delimiter（含）为公共前缀；
  # 否则 nil（对象 key）。逐字对齐 Maxio.Objects.common_prefix_of/3。
  defp common_prefix(_key, _prefix, nil), do: nil

  defp common_prefix(key, prefix, delimiter) do
    rest = String.replace_prefix(key, prefix, "")

    case :binary.match(rest, delimiter) do
      {pos, len} -> prefix <> binary_part(rest, 0, pos + len)
      :nomatch -> nil
    end
  end
end
