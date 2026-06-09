defmodule Maxio.MetaReconcile do
  @moduledoc """
  ROUTE B P2 —— 跨端点 sidecar 副本的 quorum 仲裁（纯函数，无副作用、无 IO）。

  对齐 MinIO xl.meta 读路径（pickValidFileInfo / findFileInfoInQuorum / commonTime）：
  读全 N 端点 sidecar，按目标版本的内容签名（`Maxio.Sidecar.signature/1`）分组，要求某组
  >= read_quorum(=K) 一致才接受；无任何组达 quorum -> `{:error, :read_quorum}`
  （**绝不在分歧中挑一个、绝不服务猜测副本**，铁律 3）。
  少数派（缺失 / 签名不一致 / 无此版本）记为 `divergent`（端点索引），供 P4 heal 回写。

  ## 权威组选择：modtime-first quorum（对齐 MinIO，铁律 5）

  MinIO 先经 `commonTime` 按 quorum 确立权威 ModTime（最新且持有 quorum 者胜），再
  `findFileInfoInQuorum` 只在 modtime/etag 匹配该候选的副本里做结构哈希聚合。选择是
  **确定性、modtime 驱动**的：持有 quorum 的最新数据胜出；当更新的 modtime 集合也持有
  quorum 时，绝不偏向陈旧（更旧 modtime）副本；绝不依赖 hash-map 迭代顺序。

  本实现据此：**在所有达 read_quorum 的组中，按 sort_key（modtime, generation, version_id）
  降序选权威组**（而非按组基数 + 隐式 map 迭代顺序）。这保证：
  (1) 结果确定可复现；(2) 永不在更新副本同样达 quorum 时服务陈旧副本。同签名即同版本体
  （modtime/generation/version_id 是 signature 身份字段），故组内任一 entry 即为 canonical，
  此处取 sort_key 最大者（等价，确定性）。
  """

  alias Maxio.Sidecar

  @type copy :: %{node: term(), drive: String.t(), meta: map()} | :missing
  @type target :: :latest | {:version, String.t()}

  @doc """
  reconcile(copies, read_quorum, target)。
  copies 顺序即端点索引顺序（0-based）。返回 `{:ok, canonical_entry, divergent_indices}`
  或 `{:error, :read_quorum}`。
  """
  @spec reconcile([copy()], pos_integer(), target()) ::
          {:ok, map(), [non_neg_integer()]} | {:error, :read_quorum}
  def reconcile(copies, read_quorum, target)
      when is_list(copies) and is_integer(read_quorum) and read_quorum > 0 do
    # 每端点取出 target 对应 entry（取不到 -> nil）
    indexed =
      copies
      |> Enum.with_index()
      |> Enum.map(fn {c, idx} -> {idx, entry_for(c, target)} end)

    # 按签名分组（仅对取到 entry 的端点）
    present = Enum.filter(indexed, fn {_idx, e} -> not is_nil(e) end)

    groups =
      present
      |> Enum.group_by(fn {_idx, e} -> Sidecar.signature(e) end)

    # 只保留达 read_quorum 的组；在其中按 sort_key（modtime, generation, version_id）降序
    # 选权威组（modtime-first，对齐 MinIO commonTime；绝不用组基数 + 隐式 map 顺序）。
    # 任一组内 entry 同签名即同版本体，取其代表 entry 的 sort_key 作为组的比较键。
    quorum_groups =
      groups
      |> Map.values()
      |> Enum.filter(fn members -> length(members) >= read_quorum end)

    case Enum.max_by(quorum_groups, &group_sort_key/1, fn -> nil end) do
      nil ->
        {:error, :read_quorum}

      members ->
        canonical =
          members
          |> Enum.map(fn {_idx, e} -> e end)
          |> Enum.max_by(&sort_key/1)

        quorum_indices = MapSet.new(members, fn {idx, _e} -> idx end)

        divergent =
          indexed
          |> Enum.map(fn {idx, _e} -> idx end)
          |> Enum.reject(&MapSet.member?(quorum_indices, &1))

        {:ok, canonical, divergent}
    end
  end

  defp entry_for(:missing, _target), do: nil
  defp entry_for(%{meta: meta}, :latest), do: Sidecar.latest(meta)
  defp entry_for(%{meta: meta}, {:version, vid}), do: Sidecar.find_version(meta, vid)

  defp sort_key(e), do: {e["modtime"] || 0, e["generation"] || 0, e["version_id"] || ""}

  # 组的比较键 = 组内代表 entry 的 sort_key（同签名即同 modtime/generation/version_id）。
  # 取组内 sort_key 最大者，对「同签名但 modtime 表示有差异」的边界亦确定（不依赖 map 顺序）。
  defp group_sort_key(members) do
    members
    |> Enum.map(fn {_idx, e} -> sort_key(e) end)
    |> Enum.max()
  end
end
