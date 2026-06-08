defmodule Maxio.ClusterTest do
  use ExUnit.Case, async: true

  test "this_node 返回本节点名" do
    assert Maxio.Cluster.this_node() == Node.self()
  end

  test "nodes 含本机且已排序" do
    ns = Maxio.Cluster.nodes()
    assert Node.self() in ns
    assert ns == Enum.sort(ns)
  end

  test "alive? 对本机 true、对未知节点 false" do
    assert Maxio.Cluster.alive?(Node.self())
    refute Maxio.Cluster.alive?(:"nope@127.0.0.1")
  end
end
