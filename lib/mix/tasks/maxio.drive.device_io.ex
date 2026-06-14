defmodule Mix.Tasks.Maxio.Drive.DeviceIo do
  @shortdoc "Print OS/device-level drive IO telemetry"
  @moduledoc """
  Print read-only OS/device-level drive IO telemetry.

      mix maxio.drive.device_io
      mix maxio.drive.device_io --summary-only
      mix maxio.drive.device_io --drive /data/drive0
      mix maxio.drive.device_io --cached
      mix maxio.drive.device_io --reset

  This is a fail-open operator signal for queue depth, busy time, throughput,
  and latency. It does not affect object placement, quorum, or request
  admission unless an operator explicitly selects `drive-device-io` as a
  background maintenance pacing source.
  """
  use Mix.Task

  alias Maxio.Cluster.DriveDeviceIO

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          summary_only: :boolean,
          drive: :string,
          cached: :boolean,
          reset: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.drive.device_io [--summary-only] [--drive <path>] [--cached] [--reset] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    Mix.Task.run("app.start")

    status =
      if Keyword.get(opts, :reset, false) do
        :ok = DriveDeviceIO.reset()
        :reset
      else
        :ok
      end

    summary = summary(opts)
    print_summary(status, summary, mode(opts))

    unless Keyword.get(opts, :summary_only, false) do
      Enum.each(summary.samples, &print_sample/1)
    end
  end

  defp summary(opts) do
    cond do
      Keyword.get(opts, :cached, false) ->
        DriveDeviceIO.snapshot()

      drive = Keyword.get(opts, :drive) ->
        DriveDeviceIO.sample_local_drive(drive)

      true ->
        {:ok, summary} = DriveDeviceIO.refresh_once()
        summary
    end
  end

  defp mode(opts) do
    cond do
      Keyword.get(opts, :cached, false) -> :cached
      Keyword.get(opts, :drive) -> :drive
      true -> :topology
    end
  end

  defp print_summary(status, summary, mode) do
    IO.puts(
      "[maxio drive.device_io] status=#{status} sample_status=#{summary.status} mode=#{mode} " <>
        "topology_sets=#{summary.topology_sets} endpoints=#{summary.endpoints} " <>
        "ok=#{summary.ok} errors=#{summary.errors} pressure=#{summary.pressure} " <>
        "max_queue_depth=#{summary.max_queue_depth} " <>
        "max_busy_percent_x100=#{summary.max_busy_percent_x100} " <>
        "read_bytes_per_sec=#{summary.read_bytes_per_sec} " <>
        "write_bytes_per_sec=#{summary.write_bytes_per_sec} " <>
        "ops_per_sec=#{summary.ops_per_sec} avg_latency_us=#{summary.avg_latency_us}"
    )
  end

  defp print_sample(%{status: :ok, endpoint: endpoint} = sample) do
    {node, drive} = endpoint || {nil, sample.drive}

    IO.puts(
      "[maxio drive.device_io.sample] status=ok node=#{inspect(node)} drive=#{inspect(drive)} " <>
        "set_id=#{format_value(sample.set_id)} " <>
        "endpoint_index=#{format_value(sample.endpoint_index)} " <>
        "mount_root=#{inspect(sample.mount_root)} device_id=#{inspect(sample.device_id)} " <>
        "device_name=#{inspect(sample.device_name)} queue_depth=#{sample.queue_depth} " <>
        "busy_percent_x100=#{sample.busy_percent_x100} pressure=#{sample.pressure} " <>
        "read_bytes_per_sec=#{sample.read_bytes_per_sec} " <>
        "write_bytes_per_sec=#{sample.write_bytes_per_sec} " <>
        "ops_per_sec=#{sample.ops_per_sec} avg_latency_us=#{sample.avg_latency_us} " <>
        "source=#{sample.source} observed_at_ms=#{sample.observed_at_ms}"
    )
  end

  defp print_sample(%{status: :error, endpoint: endpoint} = sample) do
    {node, drive} = endpoint || {Map.get(sample, :node), sample.drive}

    IO.puts(
      "[maxio drive.device_io.sample] status=error node=#{inspect(node)} drive=#{inspect(drive)} " <>
        "set_id=#{format_value(sample.set_id)} " <>
        "endpoint_index=#{format_value(sample.endpoint_index)} " <>
        "reason=#{inspect(sample.reason)} observed_at_ms=#{sample.observed_at_ms}"
    )
  end

  defp format_value(nil), do: "nil"
  defp format_value(value), do: to_string(value)
end
