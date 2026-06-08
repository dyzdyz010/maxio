defmodule Maxio.Cluster.Router do
  @moduledoc """
  对象 -> erasure set 路由（M7）。最简稳定方案：phash2(bucket <> "/" <> key) mod 全局 set 数。
  铁律 5 对齐 MinIO：set 放置 = 对象名哈希取模。版本不入哈希（同对象全版本同 set，
  故版本化 GET/PUT 路由一致）。online set 扩缩（rebalance）= 显式 defer（需迁移既有对象，非 MVP）。

  稳定性铁律（绝不可变）：
    1. 哈希 `bucket <> "/" <> key` 字符串（不含 version_id）。
    2. 在「全局有序 set_id 列表」上取模 + index，绝不哈希到裸 node（节点增删，set 稳定）。
    3. :erlang.phash2/2 跨节点/跨 release 对同一 term 确定性，足够且零依赖。
  """
  alias Maxio.Cluster.Topology

  @doc "对象 (bucket,key) -> set_id。topology 缺省读 :persistent_term；test 传 parsed struct。"
  @spec set_for(String.t(), String.t(), Topology.t() | nil) :: Topology.set_id()
  def set_for(bucket, key, topology \\ nil)

  def set_for(bucket, key, nil) do
    ids = Topology.all_set_ids()
    pick(ids, bucket, key)
  end

  def set_for(bucket, key, %{} = topology) do
    ids = Topology.all_set_ids_from(topology)
    pick(ids, bucket, key)
  end

  defp pick(ids, bucket, key) do
    idx = :erlang.phash2(bucket <> "/" <> key, length(ids))
    Enum.at(ids, idx)
  end
end
