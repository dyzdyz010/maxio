defmodule Maxio.Cluster.PlacementTest do
  use ExUnit.Case, async: true

  alias Maxio.Cluster.{Placement, Router, Topology}

  test "resolve_object prefers persisted set and exposes storage opts" do
    topology = topology()
    bucket = "placement-bucket"
    key = key_for_set(bucket, topology, 0)

    object = %Maxio.Objects.Object{
      bucket_name: bucket,
      key: key,
      version_id: "null",
      placement_set_id: 1,
      placement_topology_hash: "old"
    }

    assert {:ok, placement} = Placement.resolve_object(bucket, object, topology: topology)
    assert placement.set_id == 1
    assert placement.source == :persisted

    assert Placement.storage_opts(object) == [
             placement_set_id: 1,
             placement_topology_hash: "old"
           ]
  end

  test "resolve_object falls back to router when metadata has no persisted placement" do
    topology = topology()
    bucket = "placement-fallback"
    key = key_for_set(bucket, topology, 1)

    object = %Maxio.Objects.Object{bucket_name: bucket, key: key, version_id: "null"}

    assert {:ok, placement} = Placement.resolve_object(bucket, object, topology: topology)
    assert placement.set_id == 1
    assert placement.source == :router
    assert is_binary(placement.topology_hash)
  end

  test "unknown explicit placement fails loudly" do
    topology = topology()

    assert {:error, {:unknown_set_id, 9, [0, 1]}} =
             Placement.resolve("b", "k", topology: topology, placement_set_id: 9)
  end

  defp topology do
    base = Path.join(System.tmp_dir!(), "maxio_placement_test")

    endpoints0 = for i <- 0..1, do: {Node.self(), Path.join(base, "s0d#{i}")}
    endpoints1 = for i <- 0..1, do: {Node.self(), Path.join(base, "s1d#{i}")}

    Topology.parse_and_validate!(
      data_shards: 1,
      parity_shards: 1,
      block_size: 1024,
      allow_colocated_endpoints: true,
      pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints0}, %{id: 1, endpoints: endpoints1}]}]
    )
  end

  defp key_for_set(bucket, topology, set_id) do
    Enum.find_value(0..10_000, fn i ->
      key = "obj-#{i}"
      if Router.set_for(bucket, key, topology) == set_id, do: key
    end) || flunk("could not find key for set #{inspect(set_id)}")
  end
end
