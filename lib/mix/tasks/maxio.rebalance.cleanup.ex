defmodule Mix.Tasks.Maxio.Rebalance.Cleanup do
  @shortdoc "Clean old source-set replicas for a rebalance/decommission job"
  @moduledoc """
  Run a guarded foreground source cleanup pass for a rebalance/decommission job.

      mix maxio.rebalance.cleanup --job-id <uuid>
      mix maxio.rebalance.cleanup <uuid> --max-versions 500
      mix maxio.rebalance.cleanup --dry-run --json

  The command only deletes old source-set copies for versions whose PG placement
  already points at the authoritative set. Decommission jobs delete the old
  target-set copy after placement moves to the destination set; rebalance jobs
  delete configured non-authoritative set copies while keeping the PG placement
  set. Cleanup activation revalidates under the runtime-topology mutation lock.
  It does not delete object metadata, mutate topology, remove a pool, or choose
  destinations automatically.
  """
  use Mix.Task

  alias Maxio.Cluster.Rebalance.{Jobs, SourceCleanup}

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          job_id: :string,
          max_versions: :integer,
          page_size: :integer,
          dry_run: :boolean,
          json: :boolean
        ]
      )

    job_id = Keyword.get(opts, :job_id) || List.first(rest)
    extra = if job_id && rest == [job_id], do: [], else: rest

    if extra != [] or invalid != [] do
      unexpected = extra ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.rebalance.cleanup [JOB_ID|--job-id <uuid>] " <>
          "[--max-versions <n>] [--page-size <n>] [--dry-run] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_positive!(opts, :max_versions, "--max-versions")
    validate_positive!(opts, :page_size, "--page-size")
    Mix.Task.run("app.start")

    with {:ok, job_id} <- resolve_job_id(job_id),
         {:ok, report} <- SourceCleanup.cleanup_once(job_id, run_opts(opts)) do
      print_or_json(opts, report)
    else
      {:error, reason} -> Mix.raise(error_message(reason))
    end
  end

  defp run_opts(opts) do
    [
      max_versions: Keyword.get(opts, :max_versions),
      page_size: Keyword.get(opts, :page_size),
      dry_run: Keyword.get(opts, :dry_run, false)
    ]
  end

  defp resolve_job_id(job_id) when is_binary(job_id), do: {:ok, job_id}

  defp resolve_job_id(nil) do
    case Jobs.next_runnable_source_cleanup() do
      {:ok, job} -> {:ok, job.id}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp print_or_json(opts, report) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(json_ready(report)))
    else
      IO.puts(
        "[maxio rebalance.cleanup] job_id=#{report.job_id} status=#{report.status} " <>
          "kind=#{report.job_kind} " <>
          "source_cleanup_status=#{report.source_cleanup_status} " <>
          "target_set_id=#{report.target_set_id} destination_set_id=#{report.destination_set_id} " <>
          "dry_run=#{report.dry_run} scanned=#{report.scanned} deleted=#{report.deleted} " <>
          "skipped=#{report.skipped} errors=#{report.errors} truncated=#{report.truncated} " <>
          "source_cleanup=true topology_mutation=false"
      )
    end
  end

  defp error_message(:not_found),
    do: "no cleanup-ready rebalance/decommission job found"

  defp error_message(:missing_destination_set_id), do: "job has no destination_set_id"
  defp error_message(:missing_target_set_id), do: "job has no target_set_id"

  defp error_message(:destination_matches_target),
    do: "job destination_set_id must differ from target_set_id"

  defp error_message(:no_topology),
    do: "cannot run source cleanup without configured topology"

  defp error_message(:canceled), do: "rebalance/decommission job is canceled"

  defp error_message(:runner_locked),
    do: "rebalance/decommission job runner is already active for this job"

  defp error_message(:topology_mutation_locked),
    do: "source cleanup cannot start while runtime topology mutation is locked"

  defp error_message(:source_cleanup_complete),
    do: "source cleanup is already complete for this job"

  defp error_message(:source_cleanup_skipped),
    do: "source cleanup was marked skipped for this job"

  defp error_message({:data_movement_not_complete, status}),
    do: "source cleanup requires data_movement_status=complete, got #{inspect(status)}"

  defp error_message({:unsupported_job_kind, kind}),
    do: "rebalance.cleanup only supports rebalance/decommission jobs, got kind=#{inspect(kind)}"

  defp error_message({:unsupported_authoritative_source, kind, source}) do
    "rebalance.cleanup requires authoritative_source(:#{kind}) == :pg, got #{inspect(source)}"
  end

  defp error_message({:unknown_destination_set_id, set_id, set_ids}) do
    "job destination_set_id=#{inspect(set_id)} is not in configured set ids: #{inspect(set_ids)}"
  end

  defp error_message({:unknown_target_set_id, set_id, set_ids}) do
    "job target_set_id=#{inspect(set_id)} is not in configured set ids: #{inspect(set_ids)}"
  end

  defp error_message({:unknown_placement_set_id, set_ids}) do
    "one or more object versions point outside configured set ids: #{inspect(set_ids)}"
  end

  defp error_message(:missing_persisted_placement),
    do: "one or more object versions lack persisted placement"

  defp error_message({:active_job_exists, job}) do
    "cannot start source cleanup while another active job exists: #{job.id}"
  end

  defp error_message(reason), do: "rebalance cleanup failed: #{inspect(reason)}"

  defp validate_positive!(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> Mix.raise("#{flag} must be a positive integer, got #{inspect(value)}")
    end
  end

  defp json_ready(nil), do: nil
  defp json_ready(value) when is_boolean(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)

  defp json_ready(%{} = value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)

  defp json_ready(value), do: value
end
