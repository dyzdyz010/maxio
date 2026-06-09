defmodule Maxio.MetaReconcile do
  @moduledoc """
  ROUTE B P2 —— 跨端点 sidecar 副本的 quorum 仲裁（纯函数，无副作用、无 IO）。

  对齐 MinIO xl.meta 读路径（reduceCommonVersions/pickValidInfo）：读全 N 端点 sidecar，
  按目标版本的内容签名（`Maxio.Sidecar.signature/1`）分组，要求 >= read_quorum(=K) 一致才接受；
  无任何组达 quorum -> `{:error, :read_quorum}`（**绝不在分歧中挑一个、绝不服务猜测副本**，铁律 3）。
  少数派（缺失 / 签名不一致 / 无此版本）记为 `divergent`（端点索引），供 P4 heal 回写。

  generation/modtime/version_id 是 signature 的组成身份字段，故同签名即同版本体；
  并列权威组内 canonical 取 sort_key（modtime, generation, version_id）最大者（等价，确定性）。
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

    case Enum.max_by(groups, fn {_sig, members} -> length(members) end, fn -> nil end) do
      nil ->
        {:error, :read_quorum}

      {_sig, members} ->
        if length(members) >= read_quorum do
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
        else
          {:error, :read_quorum}
        end
    end
  end

  defp entry_for(:missing, _target), do: nil
  defp entry_for(%{meta: meta}, :latest), do: Sidecar.latest(meta)
  defp entry_for(%{meta: meta}, {:version, vid}), do: Sidecar.find_version(meta, vid)

  defp sort_key(e), do: {e["modtime"] || 0, e["generation"] || 0, e["version_id"] || ""}
end
