defmodule MaxioWeb.OpsClusterLiveTest do
  use MaxioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maxio.Cluster.{DriveDeviceIO, DriveIO, PressureAggregator, Topology, TopologyRevision}
  alias Maxio.Cluster.TopologyStore
  alias Maxio.Repo
  alias Maxio.S3.InFlight

  @topology_key {Maxio.Cluster.Topology, :topology}

  setup %{conn: conn} do
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)

    Repo.delete_all(TopologyRevision)
    :persistent_term.erase(@topology_key)
    :ok = InFlight.reset()
    :ok = DriveIO.reset()
    :ok = PressureAggregator.reset()
    :ok = DriveDeviceIO.reset()

    on_exit(fn ->
      restore_topology(previous_topology)
      :ok = InFlight.reset()
      :ok = DriveIO.reset()
      :ok = PressureAggregator.reset()
      :ok = DriveDeviceIO.reset()
    end)

    {:ok, conn: log_in_console(conn)}
  end

  test "renders empty read-only cluster shell without action controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ops/cluster")

    assert has_element?(view, "#ops-cluster")
    assert has_element?(view, "#nav-ops-cluster")
    assert has_element?(view, "#ops-cluster-readonly-boundary", "read-only")
    assert has_element?(view, "#ops-cluster-summary")
    assert has_element?(view, "#ops-cluster-nodes")
    assert has_element?(view, "#ops-cluster-runtime-topology")
    assert has_element?(view, "#ops-cluster-persisted-topology")
    assert has_element?(view, "#ops-cluster-topology-drift")
    assert has_element?(view, "#ops-cluster-locks")
    assert has_element?(view, "#ops-cluster-cache-invalidation")
    assert has_element?(view, "#ops-cluster-pressure")
    assert has_element?(view, "#ops-cluster-pressure-peers-empty")
    assert has_element?(view, "#ops-cluster-pressure-device-samples-empty")
    assert has_element?(view, "#ops-cluster-cross-links")
    assert has_element?(view, "#ops-cluster-link-scan")
    assert has_element?(view, "#ops-cluster-link-rebalance")
    assert has_element?(view, "#ops-cluster-link-replacement")
    assert has_element?(view, "#ops-cluster-link-gate")
    refute has_element?(view, "#ops-cluster button")
    refute has_element?(view, "#ops-cluster form")
  end

  test "renders persisted topology drift evidence when runtime topology is absent", %{conn: conn} do
    topology = topology("persisted-only")

    assert {:ok, _revision} =
             TopologyStore.activate_topology(topology,
               expected_topology_hash: Topology.fingerprint(topology),
               source: "operator"
             )

    {:ok, view, _html} = live(conn, ~p"/ops/cluster")

    assert has_element?(view, "#ops-cluster-persisted-topology", "active")
    assert has_element?(view, "#ops-cluster-persisted-topology", Topology.fingerprint(topology))
    assert has_element?(view, "#ops-cluster-topology-drift", "persisted_topology_without_runtime")
    assert has_element?(view, "#ops-cluster-drift-status", "attention")
    refute has_element?(view, "#ops-cluster button")
    refute has_element?(view, "#ops-cluster form")
  end

  defp topology(prefix) do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_ops_cluster_live_#{prefix}_#{System.unique_integer([:positive])}"
      )

    Topology.parse_and_validate!(
      data_shards: 1,
      parity_shards: 1,
      block_size: 1024,
      allow_colocated_endpoints: true,
      pools: [
        %{
          id: 0,
          sets: [
            %{
              id: 0,
              endpoints: [
                {Node.self(), Path.join(base, "d0")},
                {Node.self(), Path.join(base, "d1")}
              ]
            }
          ]
        }
      ]
    )
  end

  defp restore_topology(:__maxio_no_topology__), do: :persistent_term.erase(@topology_key)
  defp restore_topology(topology), do: :persistent_term.put(@topology_key, topology)
end
