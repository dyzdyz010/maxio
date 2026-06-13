defmodule Maxio.Storage.DistributedPlacementTest do
  use ExUnit.Case, async: false

  alias Maxio.Cluster.{Router, Topology, Transport.InProcess}
  alias Maxio.Storage.Distributed

  setup do
    InProcess.setup!()

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_distributed_placement_#{System.unique_integer([:positive])}"
      )

    endpoints0 = for i <- 0..1, do: {:"dp0_#{i}", Path.join(base, "s0d#{i}")}
    endpoints1 = for i <- 0..1, do: {:"dp1_#{i}", Path.join(base, "s1d#{i}")}

    topology =
      Topology.parse_and_validate!(
        data_shards: 1,
        parity_shards: 1,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [
          %{id: 0, sets: [%{id: 0, endpoints: endpoints0}, %{id: 1, endpoints: endpoints1}]}
        ]
      )

    on_exit(fn -> File.rm_rf(base) end)
    {:ok, topology: topology}
  end

  test "get/stat/delete honor explicit placement_set_id override", %{topology: topology} do
    bucket = "distributed-placement"
    key = key_for_set(bucket, topology, 0)
    body = "placed away from hash"
    opts = [topology: topology, transport: InProcess, placement_set_id: 1]

    assert {:ok, result} = Distributed.put(bucket, key, "null", [body], opts)
    assert result.placement_set_id == 1
    assert result.placement_pool_id == 0

    assert {:error, :enoent} =
             Distributed.get(bucket, key, "null", nil, topology: topology, transport: InProcess)

    assert {:ok, stream} = Distributed.get(bucket, key, "null", nil, opts)
    assert Enum.join(stream) == body

    expected_size = byte_size(body)
    assert {:ok, %{size: ^expected_size}} = Distributed.stat(bucket, key, "null", opts)
    assert :ok = Distributed.delete(bucket, key, "null", opts)
    assert {:error, :enoent} = Distributed.stat(bucket, key, "null", opts)
  end

  test "unknown placement_set_id returns a structured error", %{topology: topology} do
    opts = [topology: topology, transport: InProcess, placement_set_id: 9]

    assert {:error, {:unknown_set_id, 9, [0, 1]}} =
             Distributed.stat("distributed-placement", "obj", "null", opts)

    assert {:error, {:unknown_set_id, 9, [0, 1]}} =
             Distributed.delete("distributed-placement", "obj", "null", opts)
  end

  defp key_for_set(bucket, topology, set_id) do
    Enum.find_value(0..10_000, fn i ->
      key = "obj-#{i}"
      if Router.set_for(bucket, key, topology) == set_id, do: key
    end) || flunk("could not find key for set #{inspect(set_id)}")
  end
end
