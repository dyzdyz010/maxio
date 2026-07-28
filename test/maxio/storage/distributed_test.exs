defmodule Maxio.Storage.DistributedTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias Maxio.Storage.Distributed
  alias Maxio.Cluster.{Topology, Transport.InProcess}
  alias Maxio.Cluster.Paths
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

  defp body(backend, bucket, key, version_id, opts) do
    {:ok, stream} = backend.get(bucket, key, version_id, nil, opts)
    stream |> Enum.to_list() |> IO.iodata_to_binary()
  end

  defp temp_empty?({_node, drive}) do
    case File.ls(Path.join(drive, ".tmp")) do
      {:ok, []} -> true
      {:error, :enoent} -> true
      _ -> false
    end
  end

  defp sidecar(endpoints, bucket, key, version_id) do
    {:ok, rel} = Paths.object_rel(bucket, key, version_id)

    Enum.find_value(endpoints, fn {_node, drive} ->
      path = Path.join([drive, rel, "meta.json"])
      if File.exists?(path), do: path |> File.read!() |> Maxio.Sidecar.decode!()
    end)
  end

  test "around_object_commit keeps distributed bytes invisible and overrides commit data", ctx do
    o = opts(ctx)
    assert {:ok, _} = Distributed.put("b", "k", "null", ["old"], o)
    checksum = %{"ChecksumSHA256" => "locked-checksum"}

    around_opts =
      Keyword.put(o, :around_object_commit, fn prepared, publish ->
        assert prepared.size == 3
        assert {:error, :enoent} = Distributed.get("b", "k", "requested", nil, o)
        assert body(Distributed, "b", "k", "null", o) == "old"
        publish.(version_id: "locked", object_meta: %{checksum: checksum})
      end)

    assert {:ok, %{version_id: "locked"}} =
             Distributed.put("b", "k", "requested", ["new"], around_opts)

    assert body(Distributed, "b", "k", "locked", o) == "new"
    assert body(Distributed, "b", "k", "null", o) == "old"
    assert {:error, :enoent} = Distributed.get("b", "k", "requested", nil, o)
    assert [%{"checksum" => ^checksum}] = sidecar(ctx.endpoints, "b", "k", "locked")["versions"]
  end

  test "around_object_commit abort preserves distributed old final and removes staging", ctx do
    o = opts(ctx)
    assert {:ok, _} = Distributed.put("b", "k", "null", ["old"], o)

    abort_opts =
      Keyword.put(o, :around_object_commit, fn _prepared, _publish ->
        {:error, :denied}
      end)

    assert {:error, :denied} = Distributed.put("b", "k", "null", ["new"], abort_opts)
    assert body(Distributed, "b", "k", "null", o) == "old"
    assert Enum.all?(ctx.endpoints, &temp_empty?/1)
  end

  test "metadata callback exception restores distributed bytes and sidecars", ctx do
    o = opts(ctx)
    old_opts = Keyword.put(o, :object_meta, %{content_type: "text/old"})
    assert {:ok, _old} = Distributed.put("b", "k", "null", ["old"], old_opts)

    failing_opts =
      Keyword.put(o, :around_object_commit, fn _prepared, publish ->
        assert {:ok, %{version_id: "null"}} =
                 publish.(version_id: "null", object_meta: %{content_type: "text/new"})

        assert body(Distributed, "b", "k", "null", o) == "new"
        raise "metadata commit failed"
      end)

    assert_raise RuntimeError, "metadata commit failed", fn ->
      Distributed.put("b", "k", "null", ["new"], failing_opts)
    end

    assert body(Distributed, "b", "k", "null", o) == "old"

    assert [%{"content_type" => "text/old"}] =
             sidecar(ctx.endpoints, "b", "k", "null")["versions"]

    assert Enum.all?(ctx.endpoints, &temp_empty?/1)
  end

  test "publish rejects a topology drift after staging and preserves old final", ctx do
    topology_key = {Maxio.Cluster.Topology, :topology}
    missing = make_ref()
    previous = :persistent_term.get(topology_key, missing)

    on_exit(fn ->
      if previous == missing,
        do: :persistent_term.erase(topology_key),
        else: :persistent_term.put(topology_key, previous)
    end)

    :persistent_term.put(topology_key, ctx.topology)
    runtime_opts = [transport: InProcess]
    assert {:ok, _old} = Distributed.put("b", "k", "null", ["old"], runtime_opts)

    drifted_topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 2048,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: ctx.endpoints}]}]
      )

    drifting_opts =
      Keyword.put(runtime_opts, :around_object_commit, fn _prepared, publish ->
        :persistent_term.put(topology_key, drifted_topology)
        publish.(version_id: "null", object_meta: %{})
      end)

    assert {:error, :placement_changed} =
             Distributed.put("b", "k", "null", ["new"], drifting_opts)

    :persistent_term.put(topology_key, ctx.topology)
    assert body(Distributed, "b", "k", "null", runtime_opts) == "old"
    assert Enum.all?(ctx.endpoints, &temp_empty?/1)
  end

  test "distributed replacement quorum failure restores old final and removes staging", ctx do
    o = opts(ctx)
    assert {:ok, _} = Distributed.put("b", "k", "null", ["old"], o)
    failed_opts = Keyword.put(o, :rename_fun, fn _src, _dst -> {:error, :eacces} end)

    assert {:error, :write_quorum} =
             Distributed.put("b", "k", "null", ["new"], failed_opts)

    assert body(Distributed, "b", "k", "null", o) == "old"
    assert Enum.all?(ctx.endpoints, &temp_empty?/1)
  end

  test "put persists precommit object_meta checksum into sidecar view", ctx do
    o = opts(ctx)
    body = "checksum body"

    checksum = %{
      "ChecksumSHA256" => Base.encode64(:crypto.hash(:sha256, body)),
      "ChecksumType" => "FULL_OBJECT"
    }

    hook_opts =
      Keyword.put(o, :before_object_commit, fn result ->
        assert result.size == byte_size(body)
        %{object_meta: %{checksum: checksum}}
      end)

    assert {:ok, _} = Distributed.put("b", "checksum.txt", "null", [body], hook_opts)

    meta =
      Enum.find_value(ctx.endpoints, fn {_node, dir} ->
        path = Path.join([dir, "b", "checksum.txt", "meta.json"])

        if File.exists?(path) do
          path |> File.read!() |> Maxio.Sidecar.decode!()
        end
      end)

    assert [%{"checksum" => ^checksum}] = meta["versions"]
  end

  test "端点 0+2 宕机 -> GET 仍正确（K=4 存活，M=2 容错）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    InProcess.set_down(:maxio@d0)
    InProcess.set_down(:maxio@d2)

    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "M+1=3 个端点宕机 -> GET raise InsufficientShardsError（绝不静默返回错数据）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    InProcess.set_down(:maxio@d0)
    InProcess.set_down(:maxio@d2)
    InProcess.set_down(:maxio@d4)

    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert_raise InsufficientShardsError, fn -> Enum.to_list(s) end
  end

  test "PUT 时 3 端点宕机 -> 成功端点 < write_quorum=4 -> {:error,:write_quorum}", ctx do
    o = opts(ctx)
    InProcess.set_down(:maxio@d0)
    InProcess.set_down(:maxio@d1)
    InProcess.set_down(:maxio@d2)

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
