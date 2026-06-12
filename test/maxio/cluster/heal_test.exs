defmodule Maxio.Cluster.HealTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias Maxio.Storage.Distributed
  alias Maxio.Cluster.{Heal, Paths, Topology, Transport.InProcess}

  setup do
    InProcess.setup!()
    base = Path.join(System.tmp_dir!(), "maxio_chheal_#{System.unique_integer([:positive])}")
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
  defp part_path(ddir), do: Path.join([ddir, "b", "k", "part.0"])

  test "heal 重建被删整列分片的端点（模拟节点替换）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    # 删端点 0 的整个对象目录（整列分片 + sidecar 缺失，模拟空盘/被替换节点）。
    {_, d0} = Enum.at(ctx.endpoints, 0)
    File.rm_rf!(Path.join([d0, "b", "k"]))
    refute File.exists?(part_path(d0))

    assert {:ok, %{healed: healed}} = Heal.heal_object("b", "k", "null", o)
    assert healed >= 1
    assert File.exists?(part_path(d0))

    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "heal 修复被篡改的端点分片（bitrot）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    {_, d1} = Enum.at(ctx.endpoints, 1)
    p = part_path(d1)
    <<first, rest::binary>> = File.read!(p)
    File.write!(p, <<bxor(first, 0xFF), rest::binary>>)

    assert {:ok, %{healed: healed}} = Heal.heal_object("b", "k", "null", o)
    assert healed >= 1
    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "损 M+1 个端点 -> heal :unrecoverable（不伪造数据）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    for i <- 0..2 do
      {_, d} = Enum.at(ctx.endpoints, i)
      File.rm_rf!(Path.join([d, "b", "k"]))
    end

    assert {:error, :unrecoverable} = Heal.heal_object("b", "k", "null", o)
  end

  test "无任何 sidecar -> {:error, :enoent}", ctx do
    o = opts(ctx)
    assert {:error, :enoent} = Heal.heal_object("b", "missing", "null", o)
  end

  test "heal restores delete-marker sidecars without fabricating part.0", ctx do
    o = opts(ctx)
    version_id = "dm-001"
    assert :ok = Distributed.put_delete_marker("b", "marker", version_id, [], o)

    {_, d0} = Enum.at(ctx.endpoints, 0)
    {:ok, rel} = Paths.object_rel("b", "marker", version_id)
    object_dir = Path.join(d0, rel)
    File.rm_rf!(object_dir)

    assert {:ok, %{healed: healed}} = Heal.heal_object("b", "marker", version_id, o)
    assert healed >= 1
    assert File.exists?(Path.join(object_dir, "meta.json"))
    refute File.exists?(Path.join(object_dir, "part.0"))
  end
end
