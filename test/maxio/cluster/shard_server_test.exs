defmodule Maxio.Cluster.ShardServerTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias Maxio.Cluster.ShardServer

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_shardsrv_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "put_shard/get_shard round-trip（block 偏移寻址）", %{dir: dir} do
    obj = Path.join(dir, "b/k")
    s0 = :crypto.strong_rand_bytes(256)
    s1 = :crypto.strong_rand_bytes(256)
    :ok = ShardServer.put_shard(obj, 0, s0, 256)
    :ok = ShardServer.put_shard(obj, 1, s1, 256)
    assert ShardServer.get_shard(obj, 0, 256) == s0
    assert ShardServer.get_shard(obj, 1, 256) == s1
  end

  test "缺文件 / 缺块 / 短读 -> nil", %{dir: dir} do
    obj = Path.join(dir, "b/missing")
    assert ShardServer.get_shard(obj, 0, 256) == nil
    :ok = ShardServer.put_shard(obj, 0, :crypto.strong_rand_bytes(256), 256)
    # 块 5 从未写 -> 该偏移读不到 256 字节 -> nil
    assert ShardServer.get_shard(obj, 5, 256) == nil
  end

  test "sidecar put/get + stat + delete", %{dir: dir} do
    obj = Path.join(dir, "b/k2")
    meta = %{"size" => 3, "etag" => "x"}
    :ok = ShardServer.put_sidecar(obj, meta)
    assert {:ok, %{"size" => 3}} = ShardServer.get_sidecar(obj)
    :ok = ShardServer.put_shard(obj, 0, <<0::2048>>, 256)
    assert {:ok, 256} = ShardServer.stat_shard(obj)
    :ok = ShardServer.delete_shard(obj)
    assert {:error, :enoent} = ShardServer.get_sidecar(obj)
    assert {:error, :enoent} = ShardServer.stat_shard(obj)
  end

  test "heal_shard 回写指定块 + 重写 sidecar", %{dir: dir} do
    obj = Path.join(dir, "b/k3")
    good0 = :crypto.strong_rand_bytes(256)
    good1 = :crypto.strong_rand_bytes(256)

    :ok =
      ShardServer.put_shard(obj, 0, <<bxor(0, 0)::8, :crypto.strong_rand_bytes(255)::binary>>, 256)

    {:ok, 2} = ShardServer.heal_shard(obj, %{0 => good0, 1 => good1}, 256, %{"size" => 512})
    assert ShardServer.get_shard(obj, 0, 256) == good0
    assert ShardServer.get_shard(obj, 1, 256) == good1
    assert {:ok, %{"size" => 512}} = ShardServer.get_sidecar(obj)
  end

  test "ping", _ do
    assert ShardServer.ping() == :pong
  end
end
