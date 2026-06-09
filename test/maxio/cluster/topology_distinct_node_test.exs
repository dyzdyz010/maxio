defmodule Maxio.Cluster.TopologyDistinctNodeTest do
  @moduledoc """
  ROUTE B B1-3 distinct-node failure-domain 校验回归。

  一个 erasure set 的 N 端点必须落在 distinct 节点（failure domain），否则同一节点宕机会一次性带走
  >1 个分片，把真实容错降到 M 以下（write/read quorum 成谎言）。错配置启动期 raise（铁律 3 绝不带病
  启动）；单机部署/测试经 `allow_colocated_endpoints: true` 显式放行。
  """
  use ExUnit.Case, async: true
  alias Maxio.Cluster.Topology

  test "parse_and_validate! rejects a set whose endpoints are not on distinct nodes" do
    cfg = [
      data_shards: 2,
      parity_shards: 1,
      block_size: 16,
      pools: [
        %{
          id: 0,
          sets: [
            %{id: 0, endpoints: [{:"a@h", "/d0"}, {:"a@h", "/d1"}, {:"b@h", "/d2"}]}
          ]
        }
      ]
    ]

    assert_raise ArgumentError, ~r/distinct|failure domain|同一节点/, fn ->
      Topology.parse_and_validate!(cfg)
    end
  end

  test "allow_colocated_endpoints true permits colocated set (single-node degraded)" do
    cfg = [
      data_shards: 2,
      parity_shards: 1,
      block_size: 16,
      allow_colocated_endpoints: true,
      pools: [
        %{
          id: 0,
          sets: [
            %{id: 0, endpoints: [{:"a@h", "/d0"}, {:"a@h", "/d1"}, {:"a@h", "/d2"}]}
          ]
        }
      ]
    ]

    assert %{set_ids: [0]} = Topology.parse_and_validate!(cfg)
  end

  test "全 distinct 节点的合法拓扑无需 allow_colocated 即通过" do
    cfg = [
      data_shards: 2,
      parity_shards: 1,
      block_size: 16,
      pools: [
        %{
          id: 0,
          sets: [
            %{id: 0, endpoints: [{:"a@h", "/d0"}, {:"b@h", "/d1"}, {:"c@h", "/d2"}]}
          ]
        }
      ]
    ]

    assert %{set_ids: [0]} = Topology.parse_and_validate!(cfg)
  end

  test "多 set：任一 set 端点非 distinct 即 raise（逐 set 校验）" do
    cfg = [
      data_shards: 2,
      parity_shards: 1,
      block_size: 16,
      pools: [
        %{
          id: 0,
          sets: [
            %{id: 0, endpoints: [{:"a@h", "/d0"}, {:"b@h", "/d1"}, {:"c@h", "/d2"}]},
            %{id: 1, endpoints: [{:"d@h", "/d0"}, {:"d@h", "/d1"}, {:"e@h", "/d2"}]}
          ]
        }
      ]
    ]

    assert_raise ArgumentError, ~r/set 1|distinct|failure domain|同一节点/, fn ->
      Topology.parse_and_validate!(cfg)
    end
  end
end
