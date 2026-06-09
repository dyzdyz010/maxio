defmodule Maxio.Listing do
  @moduledoc """
  ROUTE B P3 —— 跨端点 drive-walk LIST（shadow，不翻权威）。

  对桶下每个 erasure set 的每个端点递归走盘（`Maxio.Cluster.Transport.list_dir`），把「含
  meta.json 的目录」的相对路径作为对象 key 收集（同 key 在 N 端点/跨 set 去重），按 key 升序
  排序后惰性折叠 prefix/delimiter/start-after/max-keys，输出与 `Maxio.Objects.list_objects_v2/2`
  **逐字段一致**的 list_result（`objects, common_prefixes, is_truncated, next_continuation_token,
  key_count`）+ walk-position 续点（绝不 offset）。

  铁律 4：输出经 max_keys + 续点有界、绝无 SQL 那种无 LIMIT 全量物化 + DoS。

  MVP 已知边界（B3 范围，正确性优先于极致惰性，真·流式惰性走盘留后续优化）：
    * 候选 key 集大小 = 桶内对象数——走盘先把全部候选 key 收进 `MapSet` 去重再排序折叠；`max_keys`
      + 续点只把**输出**有界，候选集仍可能大。这是 MVP 已知边界（端点游标 + 堆归并按需产出留后续）。
    * shadow 阶段不强制 quorum 门：某 key 在任一端点命中（含 meta.json）即收为候选，避免与 PG
      误报分歧；quorum 确认（每对象须 read_quorum 个端点确认存在）留 B4 翻 list 权威时收紧。
    * 走盘只到 key 级——list_result 的 `objects` 元素仅含 `:key`（无 LastModified/ETag/Size）；
      B3-3 shadow 比对只比 key 集 + common_prefixes，不比对象元数据。翻权威时再读 sidecar 富集（P4）。

  续点语义：`next_continuation_token` = base64 包裹「本页最后纳入 objects/common_prefixes 的那条
  原始遍历 key」（walk-position）。下次以 `start_after = 该 key` 续走（严格大于），保证可分页遍历
  不重不漏（升序 + 严格大于游标）。
  """

  alias Maxio.Cluster.{Topology, Transport}

  defmodule Continuation do
    @moduledoc "walk-position 续点 token（base64 包裹最后产出的 key；绝非 offset）。"

    @spec encode(String.t()) :: String.t()
    def encode(last_key) when is_binary(last_key), do: Base.url_encode64(last_key, padding: false)

    @spec decode(String.t()) :: {:ok, String.t()} | :error
    def decode(token) when is_binary(token) do
      case Base.url_decode64(token, padding: false) do
        {:ok, key} -> {:ok, key}
        :error -> :error
      end
    end

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

  # 收集桶下所有对象 key（跨 set 全端点递归走盘，去重）。
  defp collect_keys(bucket, opts) do
    transport = Transport.impl(opts)
    topo = Keyword.get(opts, :topology)
    set_ids = if topo, do: Topology.all_set_ids_from(topo), else: Topology.all_set_ids()

    set_ids
    |> Enum.flat_map(fn set_id ->
      endpoints =
        if topo, do: Topology.endpoints_from(topo, set_id), else: Topology.endpoints(set_id)

      Enum.flat_map(endpoints, fn {node, drive} ->
        walk(transport, node, Path.join(drive, bucket), "")
      end)
    end)
    |> Enum.uniq()
  end

  # 递归 DFS：dir = 端点下当前目录绝对路径；rel = 相对 bucket 根的 key 前缀。
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
