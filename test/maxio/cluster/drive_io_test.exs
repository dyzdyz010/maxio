defmodule Maxio.Cluster.DriveIOTest do
  use ExUnit.Case, async: false

  alias Maxio.Cluster.{DriveIO, IOPressure}

  setup do
    DriveIO.reset()

    on_exit(fn -> DriveIO.reset() end)
  end

  test "tracks active read operations and records bytes without changing the result" do
    parent = self()

    task =
      Task.async(fn ->
        DriveIO.track(
          :read,
          fn ->
            send(parent, {:inside_drive_io, self()})

            receive do
              :release_drive_io -> "abc"
            end
          end,
          bytes: fn result -> byte_size(result) end
        )
      end)

    assert_receive {:inside_drive_io, worker}
    assert DriveIO.active_count() == 1
    assert IOPressure.count(:storage_ops) == 1
    assert IOPressure.count(:combined) >= 1

    send(worker, :release_drive_io)

    assert Task.await(task) == "abc"

    assert %{
             active_ops: 0,
             active_read_ops: 0,
             read_ops: 1,
             bytes_read: 3,
             completed_ops: 1,
             total_latency_us: total_latency_us,
             max_latency_us: max_latency_us,
             avg_latency_us: avg_latency_us,
             sample_age_ms: sample_age_ms,
             throughput_bytes_per_sec: throughput_bytes_per_sec,
             read_throughput_bytes_per_sec: read_throughput,
             write_throughput_bytes_per_sec: write_throughput,
             errors: 0
           } = DriveIO.snapshot()

    assert total_latency_us >= 0
    assert max_latency_us >= 0
    assert avg_latency_us >= 0
    assert sample_age_ms >= 0
    assert throughput_bytes_per_sec >= 0
    assert read_throughput >= 0
    assert write_throughput == 0
  end

  test "releases active counters and increments errors when storage code raises" do
    assert_raise RuntimeError, "boom", fn ->
      DriveIO.track(:write, fn -> raise "boom" end)
    end

    assert %{
             active_ops: 0,
             active_write_ops: 0,
             write_ops: 1,
             completed_ops: 1,
             errors: 1
           } = DriveIO.snapshot()
  end

  test "byte accounting is fail-open and never changes storage results" do
    assert DriveIO.track(:read, fn -> "abc" end, bytes: fn _result -> raise "bad byte fun" end) ==
             "abc"

    assert %{active_ops: 0, read_ops: 1, bytes_read: 0, errors: 0} = DriveIO.snapshot()
  end

  test "reset clears cumulative telemetry counters" do
    DriveIO.track(:write, fn -> :ok end, bytes: 5)

    assert %{write_ops: 1, completed_ops: 1, bytes_written: 5} = DriveIO.snapshot()

    assert :ok = DriveIO.reset()

    assert %{
             write_ops: 0,
             completed_ops: 0,
             bytes_written: 0,
             avg_latency_us: 0,
             throughput_bytes_per_sec: 0,
             read_throughput_bytes_per_sec: 0,
             write_throughput_bytes_per_sec: 0
           } = DriveIO.snapshot()
  end

  test "reset preserves active pressure gauges for in-flight operations" do
    parent = self()

    task =
      Task.async(fn ->
        DriveIO.track(
          :read,
          fn ->
            send(parent, {:reset_probe_active, self()})

            receive do
              :release_reset_probe -> "abc"
            end
          end,
          bytes: fn result -> byte_size(result) end
        )
      end)

    assert_receive {:reset_probe_active, worker}
    assert %{active_ops: 1, active_read_ops: 1, read_ops: 1} = DriveIO.snapshot()
    assert IOPressure.local_count(:storage_ops) == 1

    try do
      assert :ok = DriveIO.reset()

      assert %{
               active_ops: 1,
               active_read_ops: 1,
               read_ops: 0,
               completed_ops: 0,
               bytes_read: 0
             } = DriveIO.snapshot()

      assert IOPressure.local_count(:storage_ops) == 1
    after
      send(worker, :release_reset_probe)
    end

    assert Task.await(task) == "abc"
    assert %{active_ops: 0, active_read_ops: 0} = DriveIO.snapshot()
    assert IOPressure.local_count(:storage_ops) == 0
  end

  test "normalizes pressure source names" do
    assert IOPressure.normalize_source("s3-in-flight") == :s3_in_flight
    assert IOPressure.normalize_source("storage-ops") == :storage_ops
    assert IOPressure.normalize_source("combined") == :combined
    assert IOPressure.normalize_source("cluster-s3-in-flight") == :cluster_s3_in_flight
    assert IOPressure.normalize_source("cluster-storage-ops") == :cluster_storage_ops
    assert IOPressure.normalize_source("cluster-combined") == :cluster_combined
    assert IOPressure.normalize_local_source(:cluster_combined) == :combined
    assert IOPressure.normalize_source("unknown") == :combined
  end
end
