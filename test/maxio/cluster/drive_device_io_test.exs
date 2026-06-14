defmodule Maxio.Cluster.DriveDeviceIOTest do
  use ExUnit.Case, async: false

  alias Maxio.Cluster.{DriveDeviceIO, IOPressure, Topology}

  setup do
    previous_env = Application.get_env(:maxio, :drive_device_io)
    DriveDeviceIO.reset()

    on_exit(fn ->
      restore_env(previous_env)
      DriveDeviceIO.reset()
    end)

    :ok
  end

  test "sample_local_drive normalizes provider metrics and caches pressure" do
    drive = Path.join(System.tmp_dir!(), "maxio_device_io_d0")

    provider = fn ^drive ->
      {:ok,
       %{
         mount_root: "test-mount",
         device_id: "8:1",
         device_name: "sda1",
         queue_depth: 3,
         busy_percent_x100: 4_500,
         read_bytes_per_sec: 1_000,
         write_bytes_per_sec: 2_000,
         ops_per_sec: 7,
         avg_latency_us: 1_500,
         source: :test
       }}
    end

    summary = DriveDeviceIO.sample_local_drive(drive, provider: provider, now_ms: 100)

    assert summary.status == :ok
    assert summary.pressure == 5
    assert summary.max_queue_depth == 3
    assert summary.max_busy_percent_x100 == 4_500
    assert summary.read_bytes_per_sec == 1_000
    assert summary.write_bytes_per_sec == 2_000
    assert [sample] = summary.samples
    assert sample.device_id == "8:1"
    assert sample.device_name == "sda1"

    assert DriveDeviceIO.pressure_count(now_ms: 100) == 5
    assert IOPressure.count(:drive_device_io, now_ms: 100) == 5
    assert DriveDeviceIO.pressure_count(now_ms: 5_101) == 0
  end

  test "provider errors and crashes fail open to zero pressure" do
    drive = Path.join(System.tmp_dir!(), "maxio_device_io_error")

    error_summary =
      DriveDeviceIO.sample_local_drive(drive,
        provider: fn ^drive -> {:error, :unsupported} end,
        now_ms: 10
      )

    assert error_summary.status == :partial
    assert error_summary.pressure == 0
    assert [%{status: :error, reason: :unsupported}] = error_summary.samples

    crash_summary =
      DriveDeviceIO.sample_local_drive(drive,
        provider: fn ^drive -> raise "device probe failed" end,
        now_ms: 11
      )

    assert crash_summary.status == :partial
    assert crash_summary.pressure == 0

    assert [%{status: :error, reason: {:exception, "device probe failed"}}] =
             crash_summary.samples
  end

  test "raw disk counter deltas compute throughput and busy pressure" do
    drive = Path.join(System.tmp_dir!(), "maxio_device_io_raw")
    parent = self()

    provider = fn ^drive ->
      receive do
        {:raw_device_io, stats} -> {:ok, stats}
      after
        100 -> send(parent, :missing_raw_sample)
      end
    end

    send(
      self(),
      {:raw_device_io, raw_stats(sectors_read: 10, sectors_written: 5, io_time_ms: 100)}
    )

    first = DriveDeviceIO.sample_local_drive(drive, provider: provider, now_ms: 0)
    assert first.read_bytes_per_sec == 0

    send(
      self(),
      {:raw_device_io,
       raw_stats(
         reads_completed: 3,
         writes_completed: 2,
         sectors_read: 14,
         sectors_written: 9,
         io_time_ms: 300
       )}
    )

    second = DriveDeviceIO.sample_local_drive(drive, provider: provider, now_ms: 1_000)

    assert second.read_bytes_per_sec == 2_048
    assert second.write_bytes_per_sec == 2_048
    assert second.ops_per_sec == 3
    assert second.max_busy_percent_x100 == 2_000
    assert second.pressure == 2
    refute_received :missing_raw_sample
  end

  test "sample_topology only probes local endpoints and caches max device pressure" do
    base = Path.join(System.tmp_dir!(), "maxio_device_io_topology")
    local_drive = Path.join(base, "local-d0")
    remote_drive = Path.join(base, "remote-d0")

    topology =
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
                  {Node.self(), local_drive},
                  {:maxio@remote, remote_drive}
                ]
              }
            ]
          }
        ]
      )

    provider = fn ^local_drive ->
      {:ok,
       %{
         mount_root: "local-mount",
         device_id: "local-dev",
         queue_depth: 1,
         busy_percent_x100: 8_000,
         source: :test
       }}
    end

    summary = DriveDeviceIO.sample_topology(topology: topology, provider: provider, now_ms: 200)

    assert summary.status == :ok
    assert summary.topology_sets == 1
    assert summary.endpoints == 1
    assert summary.pressure == 8
    assert DriveDeviceIO.pressure_count(now_ms: 200) == 8
  end

  test "disabled pressure source returns zero without clearing cached telemetry" do
    drive = Path.join(System.tmp_dir!(), "maxio_device_io_disabled")

    _ =
      DriveDeviceIO.sample_local_drive(drive,
        provider: fn ^drive -> {:ok, %{device_id: "dev", queue_depth: 2}} end,
        now_ms: 0
      )

    assert DriveDeviceIO.pressure_count(now_ms: 0) == 2
    assert DriveDeviceIO.pressure_count(enabled: false, now_ms: 0) == 0
  end

  defp raw_stats(overrides) do
    %{
      device_id: "8:1",
      device_name: "sda1",
      mount_root: "raw-mount",
      reads_completed: Keyword.get(overrides, :reads_completed, 1),
      writes_completed: Keyword.get(overrides, :writes_completed, 1),
      sectors_read: Keyword.fetch!(overrides, :sectors_read),
      sectors_written: Keyword.fetch!(overrides, :sectors_written),
      read_time_ms: Keyword.get(overrides, :read_time_ms, 10),
      write_time_ms: Keyword.get(overrides, :write_time_ms, 20),
      io_time_ms: Keyword.fetch!(overrides, :io_time_ms),
      queue_depth: Keyword.get(overrides, :queue_depth, 0),
      sector_size: 512,
      source: :test_raw
    }
  end

  defp restore_env(nil), do: Application.delete_env(:maxio, :drive_device_io)
  defp restore_env(value), do: Application.put_env(:maxio, :drive_device_io, value)
end
