defmodule Mix.Tasks.Maxio.Drive.Io do
  @shortdoc "Print node-local storage IO telemetry counters"
  @moduledoc """
  Print node-local storage operation telemetry collected by `Maxio.Cluster.DriveIO`.

      mix maxio.drive.io
      mix maxio.drive.io --reset

  The counters are application-level ShardServer observations: active operation
  counts, completed operation count, bytes, latency, and byte throughput since
  the last reset. This is not OS/device queue-depth or hardware telemetry.

  `active_gauge_register_failures` / `active_gauge_owner_absent` report how many
  tracked operations were counted *without* owner-side settlement (see
  `Maxio.ActiveGauge`): while either is climbing, the active gauges above can
  over-report, because a killed caller's units have nothing to return them.
  Both are cumulative and are not cleared by `--reset`.
  """
  use Mix.Task

  alias Maxio.Cluster.DriveIO

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          reset: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))
      Mix.raise("usage: mix maxio.drive.io [--reset] (unexpected: #{inspect(unexpected)})")
    end

    Mix.Task.run("app.start")

    status =
      if Keyword.get(opts, :reset, false) do
        :ok = DriveIO.reset()
        :reset
      else
        :ok
      end

    print_snapshot(status, DriveIO.snapshot())
  end

  defp print_snapshot(status, snapshot) do
    IO.puts(
      "[maxio drive.io] status=#{status} " <>
        "active_ops=#{snapshot.active_ops} active_read_ops=#{snapshot.active_read_ops} " <>
        "active_write_ops=#{snapshot.active_write_ops} " <>
        "active_metadata_ops=#{snapshot.active_metadata_ops} " <>
        "read_ops=#{snapshot.read_ops} write_ops=#{snapshot.write_ops} " <>
        "metadata_ops=#{snapshot.metadata_ops} delete_ops=#{snapshot.delete_ops} " <>
        "completed_ops=#{snapshot.completed_ops} errors=#{snapshot.errors} " <>
        "bytes_read=#{snapshot.bytes_read} bytes_written=#{snapshot.bytes_written} " <>
        "sample_age_ms=#{snapshot.sample_age_ms} " <>
        "throughput_bytes_per_sec=#{snapshot.throughput_bytes_per_sec} " <>
        "read_throughput_bytes_per_sec=#{snapshot.read_throughput_bytes_per_sec} " <>
        "write_throughput_bytes_per_sec=#{snapshot.write_throughput_bytes_per_sec} " <>
        "avg_latency_us=#{snapshot.avg_latency_us} max_latency_us=#{snapshot.max_latency_us} " <>
        "total_latency_us=#{snapshot.total_latency_us} " <>
        "active_gauge_register_failures=#{snapshot.active_gauge_register_failures} " <>
        "active_gauge_owner_absent=#{snapshot.active_gauge_owner_absent}"
    )
  end
end
