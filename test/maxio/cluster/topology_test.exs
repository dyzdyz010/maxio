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
      # 同机模拟多节点（rem(i,3) 复用 node 名），显式放行 distinct-node 校验（B1-3）。
      allow_colocated_endpoints: true,
      pools: [%{id: 0, sets: Enum.map(0..(endpoints_per_set - 1), mk)}]
    ]
  end

  test "解析合法拓扑：set_ids 有序、endpoints 索引即分片索引、ec_params" do
    t = Topology.parse_and_validate!(cfg(2, 4, 2))
    assert t.set_ids == [0, 1]
    assert length(Topology.endpoints_from(t, 0)) == 6
    assert Topology.ec_params_from(t) == [data_shards: 4, parity_shards: 2, block_size: 1024]
  end

  test "保留 pool 元数据和部署顺序" do
    mk = fn id ->
      eps = for i <- 0..2, do: {:"maxio@n#{i}", "/data/s#{id}d#{i}"}
      %{id: id, endpoints: eps}
    end

    t =
      Topology.parse_and_validate!(
        data_shards: 2,
        parity_shards: 1,
        block_size: 1024,
        pools: [
          %{id: 7, sets: [mk.(10), mk.(2)]},
          %{id: 4, sets: [mk.(3)]}
        ]
      )

    assert Topology.pool_ids_from(t) == [7, 4]
    assert Topology.all_set_ids_from(t) == [10, 2, 3]
    assert Topology.set_ids_for_pool_from(t, 7) == [10, 2]
    assert Topology.set_ids_for_pool_from(t, 4) == [3]
    assert Topology.pool_id_for_set_from(t, 10) == 7
    assert Topology.pool_id_for_set_from(t, 3) == 4
  end

  test "legacy topology maps default to pool 0" do
    legacy = %{
      data_shards: 1,
      parity_shards: 0,
      block_size: 1024,
      sets: %{0 => %{id: 0, endpoints: [{Node.self(), "/data"}]}},
      set_ids: [0]
    }

    assert Topology.pool_ids_from(legacy) == [0]
    assert Topology.set_ids_for_pool_from(legacy, 0) == [0]
    assert Topology.pool_id_for_set_from(legacy, 0) == 0
  end

  test "partial pool metadata fails fast instead of using legacy fallback" do
    legacy = %{
      data_shards: 1,
      parity_shards: 0,
      block_size: 1024,
      sets: %{0 => %{id: 0, pool_id: 7, endpoints: [{Node.self(), "/data"}]}},
      set_ids: [0]
    }

    assert_raise ArgumentError, ~r/pool metadata incomplete/, fn ->
      Topology.pool_ids_from(legacy)
    end

    partial = Map.put(legacy, :pool_ids, [7])

    assert_raise ArgumentError, ~r/pool metadata incomplete/, fn ->
      Topology.set_ids_for_pool_from(partial, 7)
    end
  end

  test "remove_set_from removes a set and preserves surviving pool/set order" do
    mk = fn id ->
      eps = for i <- 0..2, do: {:"maxio@n#{i}", "/data/s#{id}d#{i}"}
      %{id: id, endpoints: eps}
    end

    topology =
      Topology.parse_and_validate!(
        data_shards: 2,
        parity_shards: 1,
        block_size: 1024,
        pools: [
          %{id: 3, sets: [mk.(10), mk.(11)]},
          %{id: 7, sets: [mk.(20)]}
        ]
      )

    assert {:ok, candidate} = Topology.remove_set_from(topology, 10)
    assert Topology.pool_ids_from(candidate) == [3, 7]
    assert Topology.all_set_ids_from(candidate) == [11, 20]
    assert Topology.set_ids_for_pool_from(candidate, 3) == [11]
    assert Topology.set_ids_for_pool_from(candidate, 7) == [20]
    refute Map.has_key?(candidate.sets, 10)
  end

  test "remove_set_from drops an empty pool" do
    mk = fn id ->
      eps = for i <- 0..2, do: {:"maxio@n#{i}", "/data/s#{id}d#{i}"}
      %{id: id, endpoints: eps}
    end

    topology =
      Topology.parse_and_validate!(
        data_shards: 2,
        parity_shards: 1,
        block_size: 1024,
        pools: [
          %{id: 3, sets: [mk.(10)]},
          %{id: 7, sets: [mk.(20), mk.(21)]}
        ]
      )

    assert {:ok, candidate} = Topology.remove_set_from(topology, 10)
    assert Topology.pool_ids_from(candidate) == [7]
    assert Topology.all_set_ids_from(candidate) == [20, 21]
    refute Map.has_key?(candidate.pools, 3)
  end

  test "remove_set_from fails closed for unknown set and last set removal" do
    topology = Topology.parse_and_validate!(cfg(1, 4, 2))

    assert {:error, {:unknown_set_id, 99, [0]}} = Topology.remove_set_from(topology, 99)
    assert {:error, :would_remove_last_set} = Topology.remove_set_from(topology, 0)
  end

  test "to_config returns operator-facing keyword topology" do
    topology = Topology.parse_and_validate!(cfg(2, 4, 2))
    config = Topology.to_config(topology)

    assert Keyword.fetch!(config, :data_shards) == 4
    assert Keyword.fetch!(config, :parity_shards) == 2
    assert Keyword.fetch!(config, :allow_colocated_endpoints) == true
    assert [%{id: 0, sets: sets}] = Keyword.fetch!(config, :pools)
    assert Enum.map(sets, & &1.id) == [0, 1]
    assert Topology.parse_and_validate!(config).set_ids == [0, 1]
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
        # dup 的 6 端点同 node（:maxio@n），放行 distinct-node 以让校验走到「重复 set id」分支。
        allow_colocated_endpoints: true,
        pools: [%{id: 0, sets: [dup, dup]}]
      ]

    assert_raise ArgumentError, ~r/重复 set id/, fn -> Topology.parse_and_validate!(bad) end
  end

  test "重复 pool id -> raise" do
    pool = %{id: 0, sets: []}
    bad = [data_shards: 4, parity_shards: 2, block_size: 1024, pools: [pool, pool]]

    assert_raise ArgumentError, ~r/重复 pool id/, fn -> Topology.parse_and_validate!(bad) end
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
