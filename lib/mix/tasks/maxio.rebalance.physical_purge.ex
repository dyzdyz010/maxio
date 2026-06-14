defmodule Mix.Tasks.Maxio.Rebalance.PhysicalPurge do
  @shortdoc "Hard-delete a retained quarantine root for a verified decommission job"
  @moduledoc """
  Hard-delete `.maxio-removal-quarantine/<id>` after the retention gate.

      mix maxio.rebalance.physical_purge --job-id <uuid> \
        --confirm-job-id <uuid> --confirm-quarantine-id <id>

      mix maxio.rebalance.physical_purge <uuid> \
        --confirm-job-id <uuid> --confirm-quarantine-id <id> \
        --retention-hours 168 --json

  This command deletes only the quarantine root for the stored removed endpoint
  manifest. It does not delete drive roots, mutate topology, rewrite deployment
  config, remove hardware, or run automatically.
  """
  use Mix.Task

  alias Maxio.Cluster.Rebalance.PhysicalPurge

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          job_id: :string,
          confirm_job_id: :string,
          confirm_quarantine_id: :string,
          retention_hours: :integer,
          json: :boolean
        ]
      )

    job_id = Keyword.get(opts, :job_id) || List.first(rest)
    extra = if job_id && rest == [job_id], do: [], else: rest
    confirm_job_id = Keyword.get(opts, :confirm_job_id)
    confirm_quarantine_id = Keyword.get(opts, :confirm_quarantine_id)

    if is_nil(job_id) or confirm_job_id != job_id or is_nil(confirm_quarantine_id) or
         extra != [] or invalid != [] do
      unexpected = extra ++ Enum.map(invalid, &elem(&1, 0))
      Mix.raise("#{usage()} (unexpected: #{inspect(unexpected)})")
    end

    Mix.Task.run("app.start")

    purge_opts =
      [confirm_job_id: confirm_job_id, confirm_quarantine_id: confirm_quarantine_id] ++
        retention_opts(opts)

    case PhysicalPurge.apply(job_id, purge_opts) do
      {:ok, report} -> print_or_json(opts, report)
      {:error, reason} -> Mix.raise(error_message(reason))
    end
  end

  defp usage do
    "usage: mix maxio.rebalance.physical_purge " <>
      "[JOB_ID|--job-id <uuid>] --confirm-job-id <same uuid> " <>
      "--confirm-quarantine-id <id> [--retention-hours N] [--json]"
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
        "[maxio rebalance.physical_purge] job_id=#{report.job_id} " <>
          "status=#{report.status} quarantine_id=#{report.quarantine_id} " <>
          "roots_deleted=#{report.roots_deleted} files_deleted=#{report.files_deleted} " <>
          "dirs_deleted=#{report.dirs_deleted} bytes_deleted=#{report.bytes_deleted} " <>
          "markers_written=#{report.markers_written} errors=#{report.errors} " <>
          "physical_removal=quarantine_hard_delete topology_mutation=false " <>
          "deployment_config_mutation=false"
      )
    end
  end

  defp error_message(:physical_purge_job_confirmation_required), do: usage()
  defp error_message(:physical_purge_quarantine_confirmation_required), do: usage()

  defp error_message({:physical_purge_preflight_blocked, report}),
    do: "physical purge preflight blocked: #{inspect(report.blockers)}"

  defp error_message({:physical_purge_failed, report}),
    do: "physical purge failed: #{inspect(report.results)}"

  defp error_message(reason), do: "physical purge failed: #{inspect(reason)}"

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
