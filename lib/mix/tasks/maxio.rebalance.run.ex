defmodule Mix.Tasks.Maxio.Rebalance.Run do
  @shortdoc "Run a foreground rebalance/decommission copy pass"
  @moduledoc """
  Run a restricted foreground rebalance/decommission copy pass.

      mix maxio.rebalance.run --job-id <uuid> --destination-set 1
      mix maxio.rebalance.run <uuid> --destination-set 1 --max-versions 500
      mix maxio.rebalance.run --auto-destination
      mix maxio.rebalance.run --job-id <rebalance-uuid>
      mix maxio.rebalance.run --destination-set 1 --dry-run --json

  Decommission jobs copy versions/delete markers from the job's target set to
  the explicit or free-space selected destination set, then switch PG placement.
  Rebalance jobs copy versions/delete markers whose persisted placement differs
  from current topology routing. The command does not delete source shards,
  mutate topology, or remove pools.
  """
  use Mix.Task

  alias Maxio.Cluster.Rebalance.{Jobs, Runner}

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          job_id: :string,
          destination_set: :integer,
          auto_destination: :boolean,
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
        "usage: mix maxio.rebalance.run [JOB_ID|--job-id <uuid>] " <>
          "[--destination-set <id>] " <>
          "[--auto-destination] [--max-versions <n>] [--page-size <n>] [--dry-run] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_positive!(opts, :max_versions, "--max-versions")
    validate_positive!(opts, :page_size, "--page-size")
    Mix.Task.run("app.start")

    with {:ok, job_id} <- resolve_job_id(job_id),
         {:ok, report} <- Runner.run_once(job_id, run_opts(opts)) do
      print_or_json(opts, report)
    else
      {:error, reason} -> Mix.raise(error_message(reason))
    end
  end

  defp run_opts(opts) do
    [
      destination_set_id: Keyword.get(opts, :destination_set),
      auto_destination: Keyword.get(opts, :auto_destination, false),
      max_versions: Keyword.get(opts, :max_versions),
      page_size: Keyword.get(opts, :page_size),
      dry_run: Keyword.get(opts, :dry_run, false)
    ]
  end

  defp resolve_job_id(job_id) when is_binary(job_id), do: {:ok, job_id}

  defp resolve_job_id(nil) do
    case Jobs.active_job() do
      nil -> {:error, :not_found}
      job -> {:ok, job.id}
    end
  end

  defp print_or_json(opts, report) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(json_ready(report)))
    else
      IO.puts(
        "[maxio rebalance.run] job_id=#{report.job_id} status=#{report.status} " <>
          "kind=#{report.job_kind} target_set_id=#{report.target_set_id} " <>
          "destination_set_id=#{report.destination_set_id} " <>
          "dry_run=#{report.dry_run} scanned=#{report.scanned} moved=#{report.moved} " <>
          "skipped=#{report.skipped} errors=#{report.errors} truncated=#{report.truncated} " <>
          "source_cleanup=false free_space_placement=#{report.free_space_placement} " <>
          "topology_mutation=false"
      )
    end
  end

  defp error_message(:not_found), do: "no active rebalance/decommission job found"

  defp error_message(:missing_destination_set_id),
    do: "missing required --destination-set <id> or --auto-destination"

  defp error_message(:rebalance_uses_dynamic_destinations),
    do:
      "rebalance jobs choose per-object destinations; omit --destination-set and --auto-destination"

  defp error_message(:destination_matches_target),
    do: "--destination-set must differ from the decommission target set"

  defp error_message(:no_topology),
    do: "cannot run rebalance/decommission copy-pass without configured topology"

  defp error_message(:canceled), do: "rebalance/decommission job is canceled"

  defp error_message(:runner_locked),
    do: "rebalance/decommission job runner is already active for this job"

  defp error_message({:not_runnable, status}),
    do: "rebalance/decommission job is not runnable from status=#{status}"

  defp error_message({:unsupported_job_kind, kind}),
    do: "rebalance.run only supports rebalance/decommission jobs, got kind=#{inspect(kind)}"

  defp error_message({:unsupported_authoritative_source, kind, source}) do
    "rebalance.run requires authoritative_source(:#{kind}) == :pg, got #{inspect(source)}"
  end

  defp error_message({:unknown_destination_set_id, set_id, set_ids}) do
    "unknown --destination-set #{inspect(set_id)}; configured set ids: #{inspect(set_ids)}"
  end

  defp error_message({:unknown_target_set_id, set_id, set_ids}) do
    "job target_set_id=#{inspect(set_id)} is not in configured set ids: #{inspect(set_ids)}"
  end

  defp error_message({:destination_mismatch, existing, requested}) do
    "job destination_set_id=#{inspect(existing)} does not match requested --destination-set #{inspect(requested)}"
  end

  defp error_message({:no_healthy_destination_set, target, _bytes, candidates}) do
    "no healthy destination set available for decommission target #{inspect(target)}; candidates=#{inspect(candidates)}"
  end

  defp error_message({:insufficient_destination_free_space, target, bytes, candidates}) do
    "no destination set has enough free space for target #{inspect(target)} bytes=#{bytes}; candidates=#{inspect(candidates)}"
  end

  defp error_message(reason), do: "rebalance run failed: #{inspect(reason)}"

  defp validate_positive!(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> Mix.raise("#{flag} must be a positive integer, got #{inspect(value)}")
    end
  end

  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)

  defp json_ready(%{} = value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)

  defp json_ready(value), do: value
end
