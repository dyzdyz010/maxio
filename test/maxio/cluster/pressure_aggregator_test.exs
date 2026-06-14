defmodule Maxio.Cluster.PressureAggregatorTest do
  use ExUnit.Case, async: false

  alias Maxio.Cluster.{DriveIO, IOPressure, PressureAggregator}
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.S3.InFlight

  setup do
    InProcess.setup!()
    InFlight.reset()
    DriveIO.reset()
    PressureAggregator.reset()

    on_exit(fn ->
      InProcess.setup!()
      InFlight.reset()
      DriveIO.reset()
      PressureAggregator.reset()
    end)
  end

  test "refreshes cached peer pressure snapshots and exposes cluster source counts" do
    InProcess.set_pressure_snapshot(:maxio@n1, %{
      s3_in_flight: 2,
      storage_ops: 3,
      drive_device_io: 4
    })

    assert {:ok, %{:maxio@n1 => %{s3_in_flight: 2, storage_ops: 3, combined: 5}}} =
             PressureAggregator.refresh_once(
               nodes: [:maxio@n1],
               transport: InProcess,
               now_ms: 100
             )

    assert IOPressure.count(:cluster_s3_in_flight, now_ms: 100) == 2
    assert IOPressure.count(:cluster_storage_ops, now_ms: 100) == 3
    assert IOPressure.count(:cluster_combined, now_ms: 100) == 5
    assert IOPressure.count(:cluster_drive_device_io, now_ms: 100) == 4
  end

  test "cluster counts add node-local pressure to fresh peer cache" do
    InProcess.set_pressure_snapshot(:maxio@n1, %{combined: 5})

    assert {:ok, _snapshots} =
             PressureAggregator.refresh_once(
               nodes: [:maxio@n1],
               transport: InProcess,
               now_ms: 200
             )

    parent = self()

    pid =
      start_supervised!({
        Task,
        fn ->
          DriveIO.track(:read, fn ->
            send(parent, {:drive_io_active, self()})

            receive do
              :release_drive_io -> :ok
            end
          end)
        end
      })

    assert_receive {:drive_io_active, worker}
    assert IOPressure.count(:cluster_combined, now_ms: 200) == 6

    ref = Process.monitor(pid)
    send(worker, :release_drive_io)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "unavailable peers are removed from the cache" do
    InProcess.set_pressure_snapshot(:maxio@n1, %{combined: 5})

    assert {:ok, %{:maxio@n1 => %{combined: 5}}} =
             PressureAggregator.refresh_once(
               nodes: [:maxio@n1],
               transport: InProcess,
               now_ms: 300
             )

    InProcess.set_down(:maxio@n1)

    assert {:ok, %{}} =
             PressureAggregator.refresh_once(
               nodes: [:maxio@n1],
               transport: InProcess,
               now_ms: 301
             )

    assert IOPressure.count(:cluster_combined, now_ms: 301) == 0
  end

  test "stale peer snapshots age out fail-open" do
    InProcess.set_pressure_snapshot(:maxio@n1, %{combined: 5})

    assert {:ok, %{:maxio@n1 => %{combined: 5}}} =
             PressureAggregator.refresh_once(
               nodes: [:maxio@n1],
               transport: InProcess,
               now_ms: 0
             )

    assert IOPressure.count(:cluster_combined, now_ms: 5_000) == 5
    assert IOPressure.count(:cluster_combined, now_ms: 5_001) == 0
  end

  test "cluster source normalization keeps local base source available" do
    assert IOPressure.normalize_source("cluster-s3-in-flight") == :cluster_s3_in_flight
    assert IOPressure.normalize_source("cluster-storage-ops") == :cluster_storage_ops
    assert IOPressure.normalize_source("cluster-combined") == :cluster_combined
    assert IOPressure.normalize_source("drive-device-io") == :drive_device_io
    assert IOPressure.normalize_source("cluster-drive-device-io") == :cluster_drive_device_io

    assert IOPressure.normalize_local_source(:cluster_s3_in_flight) == :s3_in_flight
    assert IOPressure.normalize_local_source(:cluster_storage_ops) == :storage_ops
    assert IOPressure.normalize_local_source(:cluster_combined) == :combined
    assert IOPressure.normalize_local_source(:cluster_drive_device_io) == :drive_device_io
  end

  test "missing device pressure fields default to zero for mixed-version peers" do
    InProcess.set_pressure_snapshot(:maxio@n1, %{combined: 5})

    assert {:ok, %{:maxio@n1 => %{drive_device_io: 0}}} =
             PressureAggregator.refresh_once(
               nodes: [:maxio@n1],
               transport: InProcess,
               now_ms: 400
             )

    assert IOPressure.count(:cluster_drive_device_io, now_ms: 400) == 0
  end
end
