defmodule Mix.Tasks.Maxio.Rebalance.Workflow do
  @shortdoc "Print read-only rebalance/decommission workflow status"
  @moduledoc """
  Print the read-only rebalance/decommission workflow phase.

      mix maxio.rebalance.workflow
      mix maxio.rebalance.workflow --job-id <uuid>
      mix maxio.rebalance.workflow <uuid> --json

  This task never advances a job and never runs destructive physical removal or
  purge phases. It only reports the next operator action and the current audit
  evidence.
  """
  use Mix.Task

  alias Maxio.Cluster.Rebalance.{Jobs, Workflow}

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          job_id: :string,
          decommission_set: :integer,
          json: :boolean
        ]
      )

    if invalid != [] or length(rest) > 1 do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.rebalance.workflow [JOB_ID|--job-id <uuid>] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    Mix.Task.run("app.start")

    job_id = Keyword.get(opts, :job_id) || List.first(rest)

    case load_report(job_id, opts) do
      {:ok, report} -> print_or_json(report, opts)
      {:error, :not_found} -> print_not_started(opts)
      {:error, reason} -> Mix.raise("rebalance workflow unavailable: #{inspect(reason)}")
    end
  end

  defp load_report(nil, opts) do
    case Jobs.latest(target_set_id: Keyword.get(opts, :decommission_set)) do
      nil -> {:error, :not_found}
      job -> {:ok, Workflow.summary(job, [])}
    end
  end

  defp load_report(job_id, _opts), do: Workflow.summary(job_id)

  defp print_or_json(report, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(report))
    else
      IO.puts(
        "[maxio rebalance.workflow] job_id=#{report.job_id} " <>
          "kind=#{report.job_kind} status=#{report.status} phase=#{report.phase} " <>
          "next_action=#{inspect(report.next_action)} " <>
          "destructive_next_action=#{report.destructive_next_action?} " <>
          "blockers=#{inspect(report.blockers)} " <>
          "runtime_pool_ids=#{inspect(report.runtime_topology.pool_ids)} " <>
          "deployment_pool_ids=#{inspect(report.deployment_topology.pool_ids)}" <>
          workflow_suffix(report)
      )
    end
  end

  defp workflow_suffix(%{job_kind: "rebalance", rebalance_audit: %{reason: nil} = audit} = report)
       when audit.status in ["ok", "blocked"] do
    " rebalance_complete=#{report.rebalance_complete?} " <>
      "rebalance_closure_status=#{report.rebalance_closure.status} " <>
      "rebalance_audit_status=#{audit.status} " <>
      "versions_scanned=#{audit.versions_scanned} " <>
      "routing_mismatches=#{audit.routing_mismatches} " <>
      "missing_placements=#{audit.missing_placements} " <>
      "unknown_placements=#{audit.unknown_placements} " <>
      "stale_topology_hashes=#{audit.stale_topology_hashes} " <>
      "active_multipart_uploads=#{audit.active_multipart_uploads}"
  end

  defp workflow_suffix(%{job_kind: "rebalance", rebalance_audit: audit} = report) do
    reason =
      case audit.reason do
        nil -> ""
        reason -> " rebalance_audit_reason=#{reason}"
      end

    " rebalance_complete=#{report.rebalance_complete?} " <>
      "rebalance_closure_status=#{report.rebalance_closure.status} " <>
      "rebalance_audit_status=#{audit.status}" <> reason
  end

  defp workflow_suffix(report) do
    " set_retired=#{report.set_retired?} pool_retired=#{report.pool_retired?} " <>
      "removed_pool_ids=#{inspect(report.removed_pool_ids)}"
  end

  defp print_not_started(opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(%{status: "not_started", jobs: []}))
    else
      IO.puts("[maxio rebalance.workflow] status=not_started jobs=0")
    end
  end
end
