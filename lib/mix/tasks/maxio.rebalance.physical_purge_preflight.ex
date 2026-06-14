defmodule Mix.Tasks.Maxio.Rebalance.PhysicalPurgePreflight do
  @shortdoc "Check whether a quarantined layout can be hard-deleted"
  @moduledoc """
  Read-only preflight for retention-gated quarantine hard delete.

      mix maxio.rebalance.physical_purge_preflight --job-id <uuid>
      mix maxio.rebalance.physical_purge_preflight <uuid> --retention-hours 168 --json

  This command does not delete files. It validates the stored physical removal
  manifest, endpoint quarantine markers, and retention window.
  """
  use Mix.Task

  alias Maxio.Cluster.Rebalance.PhysicalPurge

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          job_id: :string,
          retention_hours: :integer,
          json: :boolean
        ]
      )

    job_id = Keyword.get(opts, :job_id) || List.first(rest)
    extra = if job_id && rest == [job_id], do: [], else: rest

    if is_nil(job_id) or extra != [] or invalid != [] do
      unexpected = extra ++ Enum.map(invalid, &elem(&1, 0))
      Mix.raise("#{usage()} (unexpected: #{inspect(unexpected)})")
    end

    Mix.Task.run("app.start")

    purge_opts = retention_opts(opts)

    case PhysicalPurge.preflight(job_id, purge_opts) do
      {:ok, report} -> print_or_json(opts, report)
      {:error, reason} -> Mix.raise("physical purge preflight failed: #{inspect(reason)}")
    end
  end

  defp usage do
    "usage: mix maxio.rebalance.physical_purge_preflight " <>
      "[JOB_ID|--job-id <uuid>] [--retention-hours N] [--json]"
  end

  defp retention_opts(opts) do
    case Keyword.fetch(opts, :retention_hours) do
      {:ok, hours} when is_integer(hours) and hours >= 0 -> [retention_hours: hours]
      {:ok, _hours} -> Mix.raise("--retention-hours must be a non-negative integer")
      :error -> []
    end
  end

  defp print_or_json(opts, report) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(json_ready(report)))
    else
      IO.puts(
        "[maxio rebalance.physical_purge_preflight] job_id=#{report.job_id} " <>
          "status=#{report.status} quarantine_id=#{report.quarantine_id} " <>
          "retention_seconds=#{report.retention_seconds} " <>
          "retention_elapsed?=#{report.retention_elapsed?} blockers=#{inspect(report.blockers)} " <>
          "purge=false"
      )
    end
  end

  defp json_ready(nil), do: nil
  defp json_ready(value) when is_boolean(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_ready()
  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)

  defp json_ready(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_ready(%{} = value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)

  defp json_ready(value), do: value
end
