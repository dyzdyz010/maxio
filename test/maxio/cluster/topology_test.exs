defmodule Maxio.Cluster.TopologyTest do
  use ExUnit.Case, async: true
  alias Maxio.Cluster.Topology

  defp cfg(endpoints_per_set, k, m) do
    n = k + m

    mk = fn id ->
      eps = for i <- 0..(n - 1), do: {:"maxio@10.0.0.#{rem(i, 3) + 1}", "/data/d#{id}_#{i}"}
      %{id: id, endpoints: eps}
    end

    [
      data_shards: k,
      parity_shards: m,
      block_size: 1024,
      pools: [%{id: 0, sets: Enum.map(0..(endpoints_per_set - 1), mk)}]
    ]
  end

  test "解析合法拓扑：set_ids 有序、endpoints 索引即分片索引、ec_params" do
    t = Topology.parse_and_validate!(cfg(2, 4, 2))
    assert t.set_ids == [0, 1]
    assert length(Topology.endpoints_from(t, 0)) == 6
    assert Topology.ec_params_from(t) == [data_shards: 4, parity_shards: 2, block_size: 1024]
  end

  test "endpoints 数 != K+M -> raise" do
    bad = put_in(cfg(1, 4, 2), [:pools], [%{id: 0, sets: [%{id: 0, endpoints: [{:n, "/d"}]}]}])
    assert_raise ArgumentError, ~r/endpoints/, fn -> Topology.parse_and_validate!(bad) end
  end

  test "M > N/2 -> raise（脑裂上界）" do
    assert_raise ArgumentError, ~r/N\/2/, fn -> Topology.parse_and_validate!(cfg(1, 2, 3)) end
  end

  test "重复 set id -> raise" do
    dup = %{id: 0, endpoints: for(i <- 0..5, do: {:maxio@n, "/d#{i}"})}

    bad =
      [
        data_shards: 4,
        parity_shards: 2,
        block_size: 1024,
        pools: [%{id: 0, sets: [dup, dup]}]
      ]

    assert_raise ArgumentError, ~r/重复 set id/, fn -> Topology.parse_and_validate!(bad) end
  end

  test "空 set（无 erasure set）-> raise" do
    bad = [data_shards: 4, parity_shards: 2, block_size: 1024, pools: [%{id: 0, sets: []}]]
    assert_raise ArgumentError, ~r/至少需一个/, fn -> Topology.parse_and_validate!(bad) end
  end

  test "local_drives_for_set 只返回 node == 给定节点 的 drive" do
    t = Topology.parse_and_validate!(cfg(1, 4, 2))
    eps = Topology.endpoints_from(t, 0)
    {node0, _} = hd(eps)
    locals = for {^node0, drive} <- eps, do: drive
    assert Topology.local_drives_from(t, 0, node0) == locals
  end
end
