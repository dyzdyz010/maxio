defmodule Maxio.Cluster.TopologyRuntimeTest do
  use ExUnit.Case, async: false

  alias Maxio.Cluster.{Placement, Topology}

  @topology_key {Maxio.Cluster.Topology, :topology}

  setup do
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)

    on_exit(fn -> restore_topology(previous_topology) end)

    :ok
  end

  test "runtime_snapshot and runtime_hash are read-only runtime topology evidence" do
    topology = topology(2)
    :persistent_term.put(@topology_key, topology)

    expected_hash = Placement.topology_hash(topology)

    assert {:ok, ^expected_hash} = Topology.runtime_hash()

    assert %{
             node: node,
             runtime_status: :configured,
             topology_hash: ^expected_hash,
             set_ids: [0, 1],
             pool_ids: [0]
           } = Topology.runtime_snapshot()

    assert node == Node.self()
  end

  test "install_runtime_if_hash installs only from expected current hash and is idempotent" do
    current = topology(2)
    {:ok, proposed} = Topology.remove_set_from(current, 0)
    current_hash = Placement.topology_hash(current)
    proposed_hash = Placement.topology_hash(proposed)
    :persistent_term.put(@topology_key, current)

    assert {:ok, %{apply_status: :applied, topology_hash: ^proposed_hash}} =
             Topology.install_runtime_if_hash(proposed, current_hash)

    assert Topology.all_set_ids() == [1]

    assert {:ok, %{apply_status: :already_applied, topology_hash: ^proposed_hash}} =
             Topology.install_runtime_if_hash(proposed, current_hash)

    :persistent_term.put(@topology_key, current)

    assert {:error, {:runtime_topology_hash_mismatch, "stale", ^current_hash}} =
             Topology.install_runtime_if_hash(proposed, "stale")

    assert Topology.all_set_ids() == [0, 1]
  end

  test "runtime hash includes endpoint node and drive material" do
    current = topology(2, "/data/current")
    endpoint_changed = topology(2, "/data/endpoint-changed")
    current_hash = Placement.topology_hash(current)
    endpoint_changed_hash = Placement.topology_hash(endpoint_changed)
    :persistent_term.put(@topology_key, current)

    assert Topology.all_set_ids_from(current) == Topology.all_set_ids_from(endpoint_changed)
    assert Topology.pool_ids_from(current) == Topology.pool_ids_from(endpoint_changed)
    refute current_hash == endpoint_changed_hash

    assert {:error, {:runtime_topology_hash_mismatch, "stale", ^current_hash}} =
             Topology.install_runtime_if_hash(endpoint_changed, "stale")

    assert Topology.all_set_ids() == [0, 1]
  end

  test "runtime_hash reports missing topology without raising" do
    :persistent_term.erase(@topology_key)

    assert {:error, :no_topology} = Topology.runtime_hash()
    assert %{runtime_status: :no_topology, topology_hash: nil} = Topology.runtime_snapshot()
  end

  defp topology(set_count, prefix \\ "/data") do
    sets =
      for set_id <- 0..(set_count - 1) do
        endpoints = for i <- 0..1, do: {Node.self(), "#{prefix}/s#{set_id}d#{i}"}
        %{id: set_id, endpoints: endpoints}
      end

    Topology.parse_and_validate!(
      data_shards: 1,
      parity_shards: 1,
      block_size: 1024,
      allow_colocated_endpoints: true,
      pools: [%{id: 0, sets: sets}]
    )
  end

  defp restore_topology(:__maxio_no_topology__), do: :persistent_term.erase(@topology_key)
  defp restore_topology(topology), do: :persistent_term.put(@topology_key, topology)
end
