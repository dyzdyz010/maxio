defmodule Maxio.Cluster.Rebalance.Closure do
  @moduledoc """
  Persisted rebalance placement closure verifier.

  This is a non-destructive automation boundary. It reuses the read-only
  `Workflow.summary/2` audit and records a point-in-time audit snapshot on the
  rebalance job after copy and source cleanup have completed.
  """

  alias Maxio.Cluster.{Lock, Topology}
  alias Maxio.Cluster.Rebalance.{Job, Jobs, Workflow}
  alias Maxio.S3.Log

  @type report :: map()

  @doc """
  Verify and persist rebalance closure audit evidence for one completed job.

  Options:

    * `:audit_page_size` / `:page_size` - Workflow audit page size.
    * `:authoritative_source` - test override; read/list must remain `:pg`.
    * `:runner_lock_opts` - lock options for the per-job runner singleton.
    * `:topology_lock_opts` / `:lock_opts` - options for the runtime topology
      read lock.
  """
  @spec verify_once(String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def verify_once(job_id, opts \\ []) when is_binary(job_id) do
    case Lock.quorum_with_lock(
           runner_lock_resource(job_id),
           fn -> locked_verify(job_id, opts) end,
           runner_lock_opts(opts)
         ) do
      {:ok, result} -> result
      {:error, :no_quorum} -> {:error, :runner_lock_unavailable}
    end
  end

  defp locked_verify(job_id, opts) do
    case Lock.quorum_with_lock(
           Topology.runtime_mutation_lock_resource(),
           fn -> do_verify_once(job_id, opts) end,
           topology_read_lock_opts(opts)
         ) do
      {:ok, result} ->
        result

      {:error, :no_quorum} ->
        Log.warn("rebalance closure skipped because topology mutation lock is held",
          action: :rebalance_closure,
          reason: "job_id=#{job_id}"
        )

        {:error, :topology_mutation_locked}
    end
  end

  defp do_verify_once(job_id, opts) do
    case Jobs.begin_rebalance_closure(job_id, opts) do
      {:ok, %Job{} = job} -> run_started(job, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_started(%Job{} = job, opts) do
    verify_started(job, opts)
  rescue
    e ->
      reason = {:crashed, Exception.message(e)}
      _ = Jobs.fail_rebalance_closure(job.id, reason, opts)
      {:error, reason}
  catch
    kind, reason ->
      caught = {:caught, kind, reason}
      _ = Jobs.fail_rebalance_closure(job.id, caught, opts)
      {:error, caught}
  end

  defp verify_started(%Job{} = job, opts) do
    case Workflow.summary(job.id, workflow_opts(opts)) do
      {:ok, %{status: "complete", rebalance_complete?: true} = workflow_report} ->
        with {:ok, updated} <- Jobs.mark_rebalance_closure_verified(job.id, workflow_report, opts) do
          {:ok, closure_report(:verified, updated, workflow_report)}
        end

      {:ok, %{status: "blocked"} = workflow_report} ->
        with {:ok, updated} <- Jobs.mark_rebalance_closure_blocked(job.id, workflow_report, opts) do
          {:ok, closure_report(:blocked, updated, workflow_report)}
        end

      {:ok, workflow_report} ->
        reason = {:unexpected_workflow_status, workflow_report.status, workflow_report.phase}

        with {:ok, _updated} <- Jobs.fail_rebalance_closure(job.id, reason, opts) do
          {:error, reason}
        end

      {:error, reason} ->
        with {:ok, _updated} <- Jobs.fail_rebalance_closure(job.id, reason, opts) do
          {:error, reason}
        end
    end
  end

  defp closure_report(status, %Job{} = job, workflow_report) do
    audit = Map.get(workflow_report, :rebalance_audit, %{})

    %{
      status: status,
      job_id: job.id,
      job_kind: job.kind,
      phase: :rebalance_closure,
      topology_mutation: false,
      physical_removal: false,
      rebalance_closure_status: job.rebalance_closure_status,
      rebalance_closure_checked_at: job.rebalance_closure_checked_at,
      rebalance_closure_verified_at: job.rebalance_closure_verified_at,
      rebalance_complete?: Map.get(workflow_report, :rebalance_complete?, false),
      workflow_status: Map.get(workflow_report, :status),
      blockers: Map.get(workflow_report, :blockers, []),
      next_action: Map.get(workflow_report, :next_action),
      topology_hash: Map.get(audit, :topology_hash),
      versions_scanned: Map.get(audit, :versions_scanned, 0),
      routing_mismatches: Map.get(audit, :routing_mismatches, 0),
      missing_placements: Map.get(audit, :missing_placements, 0),
      unknown_placements: Map.get(audit, :unknown_placements, 0),
      stale_topology_hashes: Map.get(audit, :stale_topology_hashes, 0),
      active_multipart_uploads: Map.get(audit, :active_multipart_uploads, 0),
      missing_multipart_upload_placements:
        Map.get(audit, :missing_multipart_upload_placements, 0),
      unknown_multipart_upload_placements:
        Map.get(audit, :unknown_multipart_upload_placements, 0),
      stale_multipart_upload_topology_hashes:
        Map.get(audit, :stale_multipart_upload_topology_hashes, 0)
    }
  end

  defp workflow_opts(opts) do
    Keyword.take(opts, [:audit_page_size, :page_size, :authoritative_source, :deployment_topology])
  end

  defp runner_lock_resource(job_id), do: {:rebalance_job_runner, job_id}
  defp runner_lock_opts(opts), do: Keyword.get(opts, :runner_lock_opts, [])

  defp topology_read_lock_opts(opts) do
    opts
    |> Keyword.get(:topology_lock_opts, Keyword.get(opts, :lock_opts, []))
    |> Keyword.put(:mode, :read)
  end
end
