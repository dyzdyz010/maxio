defmodule Maxio.Storage.DistributedTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias Maxio.Storage.Distributed
  alias Maxio.Cluster.{Topology, Transport.InProcess}
  alias Maxio.Storage.Erasure.InsufficientShardsError

  setup do
    InProcess.setup!()
    base = Path.join(System.tmp_dir!(), "maxio_dist_#{System.unique_integer([:positive])}")

    # N=6 端点，每端点独立 node 名（便于 set_down 单端点）。K=4 M=2 -> read_quorum=4, write_quorum=4。
    endpoints = for i <- 0..5, do: {:"maxio@d#{i}", Path.join(base, "d#{i}")}

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 1024,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, topology: topology, endpoints: endpoints}
  end

  defp opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  test "端点 0+2 宕机 -> GET 仍正确（K=4 存活，M=2 容错）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    InProcess.set_down(:"maxio@d0")
    InProcess.set_down(:"maxio@d2")

    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "M+1=3 个端点宕机 -> GET raise InsufficientShardsError（绝不静默返回错数据）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    InProcess.set_down(:"maxio@d0")
    InProcess.set_down(:"maxio@d2")
    InProcess.set_down(:"maxio@d4")

    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert_raise InsufficientShardsError, fn -> Enum.to_list(s) end
  end

  test "PUT 时 3 端点宕机 -> 成功端点 < write_quorum=4 -> {:error,:write_quorum}", ctx do
    o = opts(ctx)
    InProcess.set_down(:"maxio@d0")
    InProcess.set_down(:"maxio@d1")
    InProcess.set_down(:"maxio@d2")

    assert {:error, :write_quorum} = Distributed.put("b", "k", "null", ["hello world"], o)
  end

  test "篡改一端点分片 -> BLAKE3 失配 -> 重建仍正确", ctx do
    o = opts(ctx)
    {dnode, ddir} = Enum.at(ctx.endpoints, 1)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    # 篡改端点 1 的 part.0 首字节（绕过 transport，直接动盘）。
    part = Path.join([ddir, "b", "k", "part.0"])
    <<first, rest::binary>> = File.read!(part)
    File.write!(part, <<bxor(first, 0xFF), rest::binary>>)
    _ = dnode

    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "确定性路由：同 key 全版本同 set（put null + put 版本 落同 set 端点）", ctx do
    o = opts(ctx)
    {:ok, _} = Distributed.put("b", "k", "null", ["A"], o)
    {:ok, _} = Distributed.put("b", "k", "01XYZ", ["B"], o)
    {:ok, s0} = Distributed.get("b", "k", "null", nil, o)
    {:ok, s1} = Distributed.get("b", "k", "01XYZ", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s0)) == "A"
    assert IO.iodata_to_binary(Enum.to_list(s1)) == "B"
  end
end
