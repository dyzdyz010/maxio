defmodule Mix.Tasks.Maxio.Drive.Stats do
  @shortdoc "Print node-local or topology drive filesystem capacity stats"
  @moduledoc """
  Print OS-backed filesystem capacity stats for configured drive endpoints.

      mix maxio.drive.stats
      mix maxio.drive.stats --summary-only
      mix maxio.drive.stats --drive /data/drive0

  This is read-only filesystem capacity/free-space telemetry. It does not report
  device queue depth, SMART data, hardware identity, or physical throughput, and
  it does not affect object placement or rebalance decisions.
  """
  use Mix.Task

  alias Maxio.Cluster.DriveStats

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          summary_only: :boolean,
          drive: :string
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.drive.stats [--summary-only] [--drive <path>] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    Mix.Task.run("app.start")

    summary =
      case Keyword.get(opts, :drive) do
        nil -> DriveStats.sample_topology()
        drive -> DriveStats.sample_local_drive(drive)
      end

    print_summary(summary, mode(opts))

    unless Keyword.get(opts, :summary_only, false) do
      Enum.each(summary.samples, &print_sample/1)
    end
  end

  defp mode(opts), do: if(Keyword.get(opts, :drive), do: :drive, else: :topology)

  defp print_summary(summary, mode) do
    IO.puts(
      "[maxio drive.stats] status=#{summary.status} mode=#{mode} " <>
        "topology_sets=#{summary.topology_sets} endpoints=#{summary.endpoints} " <>
        "ok=#{summary.ok} errors=#{summary.errors} " <>
        "capacity_bytes=#{summary.capacity_bytes} free_bytes=#{summary.free_bytes} " <>
        "used_bytes=#{summary.used_bytes} min_free_bytes=#{summary.min_free_bytes} " <>
        "min_free_percent_x100=#{summary.min_free_percent_x100}"
    )
  end

  defp print_sample(%{status: :ok, endpoint: endpoint} = sample) do
    {node, drive} = endpoint || {nil, sample.drive}

    IO.puts(
      "[maxio drive.stat] status=ok node=#{inspect(node)} drive=#{inspect(drive)} " <>
        "set_id=#{format_value(sample.set_id)} " <>
        "endpoint_index=#{format_value(sample.endpoint_index)} " <>
        "mount_root=#{inspect(sample.mount_root)} " <>
        "capacity_bytes=#{sample.capacity_bytes} free_bytes=#{sample.free_bytes} " <>
        "used_bytes=#{sample.used_bytes} used_percent_x100=#{sample.used_percent_x100} " <>
        "source=#{sample.source} precision=#{sample.precision} " <>
        "observed_at_ms=#{sample.observed_at_ms}"
    )
  end

  defp print_sample(%{status: :error, endpoint: endpoint} = sample) do
    {node, drive} = endpoint || {Map.get(sample, :node), sample.drive}

    IO.puts(
      "[maxio drive.stat] status=error node=#{inspect(node)} drive=#{inspect(drive)} " <>
        "set_id=#{format_value(sample.set_id)} " <>
        "endpoint_index=#{format_value(sample.endpoint_index)} " <>
        "reason=#{inspect(sample.reason)} observed_at_ms=#{sample.observed_at_ms}"
    )
  end

  defp format_value(nil), do: "nil"
  defp format_value(value), do: to_string(value)
end
