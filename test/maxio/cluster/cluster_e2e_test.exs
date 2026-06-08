defmodule Maxio.Cluster.ClusterE2ETest do
  use ExUnit.Case, async: false

  alias Maxio.Storage.Distributed
  alias Maxio.Cluster.{Heal, Topology, Transport.InProcess}
  alias Maxio.Storage.Erasure.InsufficientShardsError

  setup do
    InProcess.setup!()
    base = Path.join(System.tmp_dir!(), "maxio_e2e_#{System.unique_integer([:positive])}")
    # 3 node，每 node 2 drive = N=6 端点；K=4 M=2 -> 杀 1 node（2 端点）= M，仍可读/写 quorum=4。
    endpoints =
      for i <- 0..5 do
        {:"maxio@node#{div(i, 2)}", Path.join(base, "node#{div(i, 2)}_d#{rem(i, 2)}")}
      end

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 1024,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, topology: topology}
  end

  defp opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  test "一节点宕机仍可写（write quorum=4，宕 node2 的 2 端点 -> 4 成功）", ctx do
    o = opts(ctx)
    InProcess.set_down(:"maxio@node2")
    body = :crypto.strong_rand_bytes(3000)
    assert {:ok, %{size: 3000}} = Distributed.put("b", "k", "null", [body], o)
    InProcess.set_up(:"maxio@node2")
    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "一节点宕机仍可读（read quorum=4）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)
    InProcess.set_down(:"maxio@node1")
    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "节点返回后 heal 重建其分片", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    InProcess.set_down(:"maxio@node2")
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)
    # node2 返回（带空盘）—— 其端点目录从未写过 -> heal 重建。
    InProcess.set_up(:"maxio@node2")
    assert {:ok, %{healed: n}} = Heal.heal_object("b", "k", "null", o)
    assert n >= 1
    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "quorum-loss（2 节点宕 = 4 端点 < read quorum）-> GET raise", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)
    InProcess.set_down(:"maxio@node1")
    InProcess.set_down(:"maxio@node2")
    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert_raise InsufficientShardsError, fn -> Enum.to_list(s) end
  end
end
