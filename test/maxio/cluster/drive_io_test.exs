defmodule Maxio.Cluster.DriveIOTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

  test "active gauges are released when a tracking process is killed" do
    parent = self()

    worker =
      spawn(fn ->
        DriveIO.track(:read, fn ->
          send(parent, {:kill_probe_active, self()})

          receive do
            :never_released -> :ok
          end
        end)
      end)

    ref = Process.monitor(worker)
    assert_receive {:kill_probe_active, ^worker}
    assert %{active_ops: 1, active_read_ops: 1} = DriveIO.snapshot()
    assert IOPressure.local_count(:storage_ops) == 1

    # A killed process never runs the `after` block of `track/3`; the gauge owner
    # must settle what it still holds, otherwise the pressure signal stays pinned
    # above zero for the lifetime of the node.
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}

    _ = :sys.get_state(DriveIO)

    assert %{active_ops: 0, active_read_ops: 0} = DriveIO.snapshot()
    assert IOPressure.local_count(:storage_ops) == 0
  end

  test "killing one tracking process leaves concurrent operations counted" do
    parent = self()

    survivor =
      Task.async(fn ->
        DriveIO.track(:read, fn ->
          send(parent, {:survivor_active, self()})

          receive do
            :release_survivor -> :ok
          end
        end)
      end)

    victim =
      spawn(fn ->
        DriveIO.track(:write, fn ->
          send(parent, {:victim_active, self()})

          receive do
            :never_released -> :ok
          end
        end)
      end)

    victim_ref = Process.monitor(victim)
    assert_receive {:survivor_active, survivor_worker}
    assert_receive {:victim_active, ^victim}
    assert %{active_ops: 2, active_read_ops: 1, active_write_ops: 1} = DriveIO.snapshot()

    Process.exit(victim, :kill)
    assert_receive {:DOWN, ^victim_ref, :process, ^victim, :killed}

    _ = :sys.get_state(DriveIO)

    assert %{active_ops: 1, active_read_ops: 1, active_write_ops: 0} = DriveIO.snapshot()

    send(survivor_worker, :release_survivor)
    assert :ok = Task.await(survivor)
    assert %{active_ops: 0, active_read_ops: 0} = DriveIO.snapshot()
  end

  test "snapshot surfaces the active gauge degradation counters" do
    # These are the only CLI-visible evidence that active gauges were counted
    # without owner-side settlement (`mix maxio.drive.io` prints them), so the
    # snapshot must carry them even when nothing has degraded.
    assert %{
             active_gauge_register_failures: register_failures,
             active_gauge_owner_absent: owner_absent
           } = DriveIO.snapshot()

    assert is_integer(register_failures) and register_failures >= 0
    assert is_integer(owner_absent) and owner_absent >= 0

    # White-box: they are cumulative `Maxio.ActiveGauge` bookkeeping rows in the
    # same table, so seeding one is a far cheaper wiring check than crashing the
    # supervised owner. Restored afterwards because `reset/0` never clears them.
    :ets.insert(:maxio_cluster_drive_io, {:active_gauge_owner_absent, 7})

    try do
      assert %{active_gauge_owner_absent: 7} = DriveIO.snapshot()
    after
      :ets.insert(:maxio_cluster_drive_io, {:active_gauge_owner_absent, owner_absent})
    end
  end

  test "the telemetry owner reports unexpected messages instead of dropping them" do
    # Adding a `:DOWN` clause replaces the `use GenServer` default `handle_info/2`,
    # which logs unknown messages. Losing that would make anything mis-routed to
    # this process invisible.
    log =
      capture_log(fn ->
        send(DriveIO, :maxio_drive_io_unexpected_probe)
        _ = :sys.get_state(DriveIO)
      end)

    assert log =~ "drive io telemetry owner received an unexpected message"
    assert log =~ "maxio_drive_io_unexpected_probe"
    assert Process.alive?(Process.whereis(DriveIO))
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
