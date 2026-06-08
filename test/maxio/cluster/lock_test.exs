defmodule Maxio.Cluster.LockTest do
  use ExUnit.Case, async: false
  alias Maxio.Cluster.Lock

  test "with_lock 跑 fun 并返回 {:ok, result}" do
    assert {:ok, 42} = Lock.with_lock({"b", "k"}, fn -> 42 end)
  end

  test "嵌套不同资源不死锁" do
    assert {:ok, :inner} =
             Lock.with_lock({"b", "k1"}, fn ->
               {:ok, r} = Lock.with_lock({"b", "k2"}, fn -> :inner end)
               r
             end)
  end

  test "quorum_with_lock 单节点（quorum=1）获锁跑 fun" do
    assert {:ok, :done} = Lock.quorum_with_lock({"b", "k"}, fn -> :done end)
  end
end
