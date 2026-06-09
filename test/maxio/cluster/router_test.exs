defmodule Maxio.Cluster.RouterTest do
  use ExUnit.Case, async: true
  alias Maxio.Cluster.{Router, Topology}

  defp topo(num_sets) do
    n = 6

    mk = fn id ->
      eps = for i <- 0..(n - 1), do: {:"maxio@n#{rem(i, 3)}", "/d#{id}_#{i}"}
      %{id: id, endpoints: eps}
    end

    Topology.parse_and_validate!(
      data_shards: 4,
      parity_shards: 2,
      block_size: 1024,
      # 同机模拟（rem(i,3) 复用 node 名），放行 distinct-node 校验（B1-3）。
      allow_colocated_endpoints: true,
      pools: [%{id: 0, sets: Enum.map(0..(num_sets - 1), mk)}]
    )
  end

  test "确定性：同 (bucket,key) 恒映射同一 set" do
    t = topo(4)
    a = Router.set_for("bucket", "path/to/obj", t)
    b = Router.set_for("bucket", "path/to/obj", t)
    assert a == b
    assert a in Topology.all_set_ids_from(t)
  end

  test "版本不入哈希：同对象不同 version_id 同 set（路由不取 version_id）" do
    t = topo(4)
    # Router.set_for/3 仅接受 bucket+key，版本天然不参与 —— 由签名保证。
    assert Router.set_for("b", "k", t) == Router.set_for("b", "k", t)
  end

  test "取模落在 [0, num_sets)" do
    t = topo(3)
    ids = Topology.all_set_ids_from(t)

    for key <- ~w(a b c d e f g aa bb cc obj/with/slash) do
      assert Router.set_for("bucket", key, t) in ids
    end
  end

  test "num_sets=1 恒映射唯一 set" do
    t = topo(1)
    assert Router.set_for("b", "anything", t) == 0
  end
end
