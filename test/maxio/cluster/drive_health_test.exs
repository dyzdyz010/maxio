defmodule Maxio.Cluster.DriveHealthTest do
  use ExUnit.Case, async: false

  alias Maxio.Cluster.{DriveHealth, Topology, Transport.InProcess}

  setup do
    :ok = DriveHealth.reset()
    :ok = InProcess.setup!()

    base =
      Path.join(System.tmp_dir!(), "maxio_drive_health_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :ok = DriveHealth.reset()
      File.rm_rf(base)
    end)

    {:ok, base: base}
  end

  test "a single failed probe marks a drive suspect, not offline", %{base: base} do
    drive = Path.join(base, "d0")

    status =
      DriveHealth.record_probe(
        {:maxio@n0, drive},
        {:error, :unavailable},
        now_ms: 0,
        offline_after_ms: 1_000,
        set_write_available?: true
      )

    assert status.status == :suspect
    assert status.failure_count == 1
    refute Map.fetch!(status, :heal_required?)
    refute DriveHealth.offline?({:maxio@n0, drive})
  end

  test "failed probes past the long window mark the drive offline", %{base: base} do
    drive = Path.join(base, "d1")

    _ =
      DriveHealth.record_probe(
        {:maxio@n1, drive},
        {:error, :unavailable},
        now_ms: 10,
        offline_after_ms: 1_000,
        set_write_available?: true
      )

    status =
      DriveHealth.record_probe(
        {:maxio@n1, drive},
        {:error, :unavailable},
        now_ms: 1_010,
        offline_after_ms: 1_000,
        set_write_available?: true
      )

    assert status.status == :offline
    assert status.failure_count == 2
    assert DriveHealth.offline?({:maxio@n1, drive})
  end

  test "recovery after long writable-set outage keeps heal_required until cleared", %{base: base} do
    drive = Path.join(base, "d2")
    endpoint = {:maxio@n2, drive}

    _ =
      DriveHealth.record_probe(endpoint, {:error, :unavailable},
        now_ms: 0,
        offline_after_ms: 1_000,
        set_write_available?: true
      )

    _ =
      DriveHealth.record_probe(endpoint, {:error, :unavailable},
        now_ms: 1_500,
        offline_after_ms: 1_000,
        set_write_available?: true
      )

    recovered =
      DriveHealth.record_probe(endpoint, {:ok, []}, now_ms: 2_000, offline_after_ms: 1_000)

    assert recovered.status == :online
    assert Map.fetch!(recovered, :heal_required?)
    assert DriveHealth.heal_required?(endpoint)

    cleared = DriveHealth.clear_heal_required(endpoint)
    refute Map.fetch!(cleared, :heal_required?)
  end

  test "recovery after a set-unavailable outage does not request fresh-drive healing", %{
    base: base
  } do
    drive = Path.join(base, "d3")
    endpoint = {:maxio@n3, drive}

    _ =
      DriveHealth.record_probe(endpoint, {:error, :unavailable},
        now_ms: 0,
        offline_after_ms: 1_000,
        set_write_available?: false
      )

    _ =
      DriveHealth.record_probe(endpoint, {:error, :unavailable},
        now_ms: 1_500,
        offline_after_ms: 1_000,
        set_write_available?: false
      )

    recovered =
      DriveHealth.record_probe(endpoint, {:ok, []}, now_ms: 2_000, offline_after_ms: 1_000)

    assert recovered.status == :online
    refute Map.fetch!(recovered, :heal_required?)
  end

  test "topology probe records per-drive status and heal requirement", %{base: base} do
    endpoints = for i <- 0..5, do: {Node.self(), Path.join(base, "d#{i}")}
    Enum.each(endpoints, fn {_node, drive} -> File.mkdir_p!(drive) end)

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 1_024,
        allow_colocated_endpoints: true,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    {node, failed_drive} = hd(endpoints)
    InProcess.set_drive_down(node, failed_drive)

    assert %{
             sets: 1,
             endpoints: 6,
             online: 5,
             suspect: 0,
             offline: 1,
             heal_required: 0
           } =
             DriveHealth.probe_topology(
               topology: topology,
               transport: InProcess,
               offline_after_ms: 0,
               now_ms: 0
             )

    InProcess.set_drive_up(node, failed_drive)

    assert %{
             online: 6,
             suspect: 0,
             offline: 0,
             heal_required: 1
           } =
             DriveHealth.probe_topology(
               topology: topology,
               transport: InProcess,
               offline_after_ms: 0,
               now_ms: 1
             )
  end

  test "topology probe treats a missing configured drive root as unavailable", %{base: base} do
    endpoints = for i <- 0..2, do: {Node.self(), Path.join(base, "missing-d#{i}")}
    [_missing | present] = Enum.map(endpoints, &elem(&1, 1))
    Enum.each(present, &File.mkdir_p!/1)

    topology =
      Topology.parse_and_validate!(
        data_shards: 2,
        parity_shards: 1,
        block_size: 1_024,
        allow_colocated_endpoints: true,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    assert %{
             sets: 1,
             endpoints: 3,
             online: 2,
             suspect: 0,
             offline: 1,
             heal_required: 0
           } =
             DriveHealth.probe_topology(
               topology: topology,
               transport: Maxio.Cluster.Transport.Erpc,
               offline_after_ms: 0,
               now_ms: 0
             )
  end
end
