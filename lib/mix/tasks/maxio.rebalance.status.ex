defmodule Mix.Tasks.Maxio.Rebalance.Status do
  @shortdoc "Print rebalance/decommission job status"
  @moduledoc """
  Print persistent rebalance/decommission job status.

      mix maxio.rebalance.status
      mix maxio.rebalance.status --job-id <uuid>
      mix maxio.rebalance.status --all
      mix maxio.rebalance.status --json
  """
  use Mix.Task

  alias Maxio.Cluster.Rebalance.Jobs

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          job_id: :string,
          all: :boolean,
          decommission_set: :integer,
          json: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.rebalance.status [--job-id <uuid>] [--all] " <>
          "[--decommission-set <id>] [--json] (unexpected: #{inspect(unexpected)})"
      )
    end

    Mix.Task.run("app.start")

    cond do
      Keyword.get(opts, :all, false) ->
        jobs = Jobs.list(target_set_id: Keyword.get(opts, :decommission_set), limit: 100)
        print_or_json(opts, jobs)

      job_id = Keyword.get(opts, :job_id) ->
        case Jobs.get(job_id) do
          {:ok, job} -> print_or_json(opts, job)
          {:error, :not_found} -> Mix.raise("rebalance job not found: #{job_id}")
        end

      true ->
        case Jobs.latest(target_set_id: Keyword.get(opts, :decommission_set)) do
          nil -> print_not_started(opts)
          job -> print_or_json(opts, job)
        end
    end
  end

  defp print_or_json(opts, jobs) when is_list(jobs) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(Enum.map(jobs, &Jobs.to_view/1)))
    else
      Enum.each(jobs, &print_job/1)
    end
  end

  defp print_or_json(opts, job) do
    if Keyword.get(opts, :json, false),
      do: IO.puts(Jason.encode!(Jobs.to_view(job))),
      else: print_job(job)
  end

  defp print_not_started(opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(%{status: "not_started", jobs: []}))
    else
      IO.puts("[maxio rebalance.status] status=not_started jobs=0")
    end
  end

  defp print_job(job) do
    view = Jobs.to_view(job)

    IO.puts(
      "[maxio rebalance.status] job_id=#{job.id} kind=#{job.kind} status=#{job.status} " <>
        "data_movement=#{view.data_movement} data_movement_status=#{job.data_movement_status} " <>
        "target_set_id=#{format_value(job.target_set_id)} " <>
        "destination_set_id=#{format_value(job.destination_set_id)} " <>
        "plan_status=#{job.plan_status} scanned=#{job.plan_scanned} bytes=#{job.plan_bytes} " <>
        "placement_fallbacks=#{job.plan_placement_fallbacks} progress_scanned=#{job.progress_scanned} " <>
        "progress_moved=#{job.progress_moved} progress_errors=#{job.progress_errors} " <>
        "source_cleanup_status=#{job.source_cleanup_status} " <>
        "rebalance_closure_status=#{job.rebalance_closure_status} " <>
        "rebalance_closure_topology_hash=#{format_value(job.rebalance_closure_topology_hash)} " <>
        "rebalance_closure_blockers=#{inspect(job.rebalance_closure_blockers)} " <>
        "topology_removal_status=#{job.topology_removal_status} " <>
        "topology_removal_scope=#{job.topology_removal_scope} " <>
        "target_endpoint_manifest=#{target_endpoint_count(job.topology_removal_target_endpoints)} " <>
        "removed_pool_ids=#{inspect(job.topology_removal_removed_pool_ids)} " <>
        "physical_removal_status=#{job.physical_removal_status} " <>
        "physical_removal_scope=#{job.physical_removal_scope} " <>
        "physical_removal_quarantine_id=#{format_value(job.physical_removal_quarantine_id)} " <>
        "physical_removal_roots_quarantined=#{job.physical_removal_roots_quarantined} " <>
        "physical_removal_errors=#{job.physical_removal_errors} " <>
        "physical_removal_purge_status=#{job.physical_removal_purge_status} " <>
        "physical_removal_purge_scope=#{job.physical_removal_purge_scope} " <>
        "physical_removal_purge_roots_deleted=#{job.physical_removal_purge_roots_deleted} " <>
        "physical_removal_purge_bytes_deleted=#{job.physical_removal_purge_bytes_deleted} " <>
        "physical_removal_purge_errors=#{job.physical_removal_purge_errors}"
    )
  end

  defp format_value(nil), do: "nil"
  defp format_value(value), do: to_string(value)

  defp target_endpoint_count(%{} = manifest) do
    manifest
    |> Map.get("endpoints", Map.get(manifest, :endpoints, []))
    |> List.wrap()
    |> length()
  end

  defp target_endpoint_count(_manifest), do: 0
end
