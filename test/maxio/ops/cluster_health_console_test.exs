defmodule Maxio.Ops.ClusterHealthConsoleTest do
  use ExUnit.Case, async: true

  alias Maxio.Cluster.Topology
  alias Maxio.Ops.ClusterHealthConsole

  @now ~U[2026-07-05 00:00:00.000000Z]

  test "normalizes matching runtime and persisted topology with pressure evidence" do
    topology = sample_topology()
    hash = Topology.fingerprint(topology)

    result =
      ClusterHealthConsole.load(
        runtime_topology_fun: fn ->
          %{
            node: :maxio@n0,
            runtime_status: :configured,
            topology_hash: hash,
            set_ids: [0],
            pool_ids: [0]
          }
        end,
        persisted_topology_fun: fn opts ->
          assert opts == []

          {:ok,
           %{
             revision: %{
               id: "revision-1",
               status: "active",
               topology_hash: hash,
               source: "operator",
               activated_at: @now
             },
             topology: topology
           }}
        end,
        nodes_fun: fn -> [:maxio@n0, :maxio@n1] end,
        alive_fun: fn _node -> true end,
        local_pressure_fun: fn ->
          %{s3_in_flight: 1, storage_ops: 2, combined: 3, drive_device_io: 4}
        end,
        peer_pressure_fun: fn _opts ->
          %{:maxio@n1 => %{s3_in_flight: 1, storage_ops: 2, combined: 3, drive_device_io: 4}}
        end,
        device_io_fun: fn _opts ->
          %{
            status: :ok,
            topology_sets: 1,
            endpoints: 1,
            ok: 1,
            errors: 0,
            pressure: 4,
            observed_at_ms: 100,
            samples: [
              %{
                status: :ok,
                endpoint: {:maxio@n0, "/data/d0"},
                set_id: 0,
                drive: "/data/d0",
                pressure: 4,
                queue_depth: 2,
                busy_percent_x100: 100
              }
            ]
          }
        end,
        process_lookup_fun: process_lookup_fun()
      )

    assert result.status == "ok"
    assert result.runtime_topology.status == "ok"
    assert result.persisted_topology.status == "ok"
    assert result.topology_drift.status == "ok"
    assert result.topology_drift.reason == "runtime_persisted_topology_match"
    assert result.pressure.status == "ok"
    assert [%{node: "maxio@n1", combined: "3"}] = result.pressure.peers.rows

    assert [%{endpoint: "{:maxio@n0, \"/data/d0\"}", pressure: "4"}] =
             result.pressure.device.samples
  end

  test "marks runtime and persisted topology hash mismatch as blocked" do
    topology = sample_topology()

    result =
      ClusterHealthConsole.load(
        runtime_topology_fun: fn ->
          %{runtime_status: :configured, topology_hash: "runtime", set_ids: [0], pool_ids: [0]}
        end,
        persisted_topology_fun: fn _opts ->
          {:ok, %{revision: %{topology_hash: "persisted", status: "active"}, topology: topology}}
        end,
        nodes_fun: fn -> [Node.self()] end,
        alive_fun: fn _node -> true end,
        local_pressure_fun: fn ->
          %{s3_in_flight: 0, storage_ops: 0, combined: 0, drive_device_io: 0}
        end,
        peer_pressure_fun: fn _opts -> %{} end,
        device_io_fun: fn _opts -> %{status: :no_topology, samples: []} end,
        process_lookup_fun: process_lookup_fun()
      )

    assert result.status == "blocked"
    assert result.topology_drift.status == "blocked"
    assert result.topology_drift.reason == "runtime_persisted_topology_hash_mismatch"
  end

  test "missing runtime topology status is blocked, not matched with empty persisted topology" do
    result =
      ClusterHealthConsole.load(
        runtime_topology_fun: fn ->
          %{node: Node.self(), topology_hash: nil, set_ids: [], pool_ids: []}
        end,
        persisted_topology_fun: fn _opts -> {:error, :no_active_topology_revision} end,
        nodes_fun: fn -> [Node.self()] end,
        alive_fun: fn _node -> true end,
        local_pressure_fun: fn ->
          %{s3_in_flight: 0, storage_ops: 0, combined: 0, drive_device_io: 0}
        end,
        peer_pressure_fun: fn _opts -> %{} end,
        device_io_fun: fn _opts -> %{status: :no_topology, samples: []} end,
        process_lookup_fun: process_lookup_fun()
      )

    assert result.status == "blocked"
    assert result.runtime_topology.status == "blocked"
    assert result.runtime_topology.raw_status == "missing"
    assert result.topology_drift.status == "blocked"
    assert result.topology_drift.reason == "topology_evidence_unavailable"
  end

  test "empty runtime and persisted topology are explicit, not healthy" do
    result =
      ClusterHealthConsole.load(
        runtime_topology_fun: fn ->
          %{
            node: Node.self(),
            runtime_status: :no_topology,
            topology_hash: nil,
            set_ids: [],
            pool_ids: []
          }
        end,
        persisted_topology_fun: fn _opts -> {:error, :no_active_topology_revision} end,
        nodes_fun: fn -> [Node.self()] end,
        alive_fun: fn _node -> true end,
        local_pressure_fun: fn ->
          %{s3_in_flight: 0, storage_ops: 0, combined: 0, drive_device_io: 0}
        end,
        peer_pressure_fun: fn _opts -> %{} end,
        device_io_fun: fn _opts -> %{status: :no_topology, samples: []} end,
        process_lookup_fun: fn _name -> nil end
      )

    assert result.status == "attention"
    assert result.runtime_topology.status == "empty"
    assert result.persisted_topology.status == "empty"
    assert result.topology_drift.status == "empty"
    assert result.pressure.peers.status == "empty"
    assert result.pressure.device.status == "empty"
    assert result.locks.status == "attention"
  end

  test "summary status mirrors page rollup when lock and cache evidence need attention" do
    topology = sample_topology()
    hash = Topology.fingerprint(topology)

    result =
      ClusterHealthConsole.load(
        runtime_topology_fun: fn ->
          %{runtime_status: :configured, topology_hash: hash, set_ids: [0], pool_ids: [0]}
        end,
        persisted_topology_fun: fn _opts ->
          {:ok, %{revision: %{topology_hash: hash, status: "active"}, topology: topology}}
        end,
        nodes_fun: fn -> [Node.self()] end,
        alive_fun: fn _node -> true end,
        local_pressure_fun: fn ->
          %{s3_in_flight: 0, storage_ops: 0, combined: 0, drive_device_io: 0}
        end,
        peer_pressure_fun: fn _opts ->
          %{:maxio@peer => %{s3_in_flight: 0, storage_ops: 0, combined: 0, drive_device_io: 0}}
        end,
        device_io_fun: fn _opts -> %{status: :ok, samples: []} end,
        process_lookup_fun: fn _name -> nil end
      )

    assert result.status == "attention"
    assert field(result.summary_rows, "summary-status").value == "attention"
    assert field(result.summary_rows, "summary-locks").value == "attention"
    assert field(result.summary_rows, "summary-cache-invalidation").value == "attention"
  end

  test "persisted topology decode or hash errors fail closed" do
    result =
      ClusterHealthConsole.load(
        runtime_topology_fun: fn ->
          %{runtime_status: :configured, topology_hash: "runtime", set_ids: [0], pool_ids: [0]}
        end,
        persisted_topology_fun: fn _opts ->
          {:error, {:topology_revision_hash_mismatch, "stored", "actual"}}
        end,
        nodes_fun: fn -> [Node.self()] end,
        alive_fun: fn _node -> true end,
        local_pressure_fun: fn ->
          %{s3_in_flight: 0, storage_ops: 0, combined: 0, drive_device_io: 0}
        end,
        peer_pressure_fun: fn _opts -> %{} end,
        device_io_fun: fn _opts -> %{status: :no_topology, samples: []} end,
        process_lookup_fun: process_lookup_fun()
      )

    assert result.status == "blocked"
    assert result.persisted_topology.status == "blocked"

    assert field(result.persisted_topology.rows, "persisted-topology-reason").value =~
             "topology_revision_hash_mismatch"
  end

  test "persisted topology fingerprint fallback errors fail closed" do
    result =
      ClusterHealthConsole.load(
        runtime_topology_fun: fn ->
          %{runtime_status: :configured, topology_hash: "runtime", set_ids: [0], pool_ids: [0]}
        end,
        persisted_topology_fun: fn _opts ->
          {:ok, %{revision: %{status: "active"}, topology: %{set_ids: [0]}}}
        end,
        nodes_fun: fn -> [Node.self()] end,
        alive_fun: fn _node -> true end,
        local_pressure_fun: fn ->
          %{s3_in_flight: 0, storage_ops: 0, combined: 0, drive_device_io: 0}
        end,
        peer_pressure_fun: fn _opts -> %{} end,
        device_io_fun: fn _opts -> %{status: :no_topology, samples: []} end,
        process_lookup_fun: process_lookup_fun()
      )

    assert result.status == "blocked"
    assert result.persisted_topology.status == "blocked"

    assert field(result.persisted_topology.rows, "persisted-topology-reason").value =~
             "topology_fingerprint_failed"
  end

  defp sample_topology do
    Topology.parse_and_validate!(
      data_shards: 1,
      parity_shards: 1,
      block_size: 1_048_576,
      allow_colocated_endpoints: true,
      pools: [
        %{
          id: 0,
          sets: [
            %{
              id: 0,
              endpoints: [{:maxio@n0, "/data/d0"}, {:maxio@n1, "/data/d1"}]
            }
          ]
        }
      ]
    )
  end

  defp process_lookup_fun do
    fn
      Maxio.Cluster.LockServer -> self()
      Maxio.Cluster.CacheInvalidator -> self()
      Maxio.PubSub -> self()
      _name -> nil
    end
  end

  defp field(rows, id), do: Enum.find(rows, &(&1.id == id))
end
