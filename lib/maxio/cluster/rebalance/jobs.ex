defmodule Maxio.Cluster.Rebalance.Jobs do
  @moduledoc """
  Persistent control plane for future rebalance/decommission data movement.

  This module creates and tracks operator jobs, but does not move shards yet.
  A start call stores a point-in-time `Maxio.Cluster.Rebalance.plan/1` snapshot
  and leaves `data_movement_status` as `not_started` so operators can see the
  exact boundary.
  """

  import Ecto.Query

  alias Maxio.Cluster.{Lock, Rebalance, Topology}
  alias Maxio.Cluster.Rebalance.Job
  alias Maxio.Repo
  alias Maxio.S3.Log

  @active_statuses ~w(planned running cancel_requested)
  @default_page_size 500

  @type start_opts :: keyword()

  @doc """
  Start a rebalance or decommission control-plane job.

  Passing `:decommission_set` or `:target_set_id` starts a decommission job.
  Otherwise this starts a rebalance job.
  """
  @spec start(start_opts()) :: {:ok, Job.t()} | {:error, term()}
  def start(opts \\ []) do
    case Keyword.get(opts, :decommission_set, Keyword.get(opts, :target_set_id)) do
      nil -> start_rebalance(opts)
      set_id when is_integer(set_id) -> start_decommission(set_id, opts)
      set_id -> {:error, {:invalid_target_set_id, set_id}}
    end
  end

  @doc "Start a rebalance control-plane job."
  @spec start_rebalance(start_opts()) :: {:ok, Job.t()} | {:error, term()}
  def start_rebalance(opts \\ []), do: create("rebalance", opts)

  @doc """
  Start a rebalance job only when persisted placement differs from current routing.

  This is for config-gated automation after fresh-drive replacement heal. It
  reuses the same topology lock, active-job singleton, plan snapshot, and
  placement-fallback refusal as `start_rebalance/1`, but skips durable job
  creation when the plan has no routing mismatches to move.
  """
  @spec start_rebalance_if_needed(start_opts()) ::
          {:ok, {:created, Job.t()} | :not_needed} | {:error, term()}
  def start_rebalance_if_needed(opts \\ []) do
    case create("rebalance", Keyword.put(opts, :only_if_needed, true)) do
      {:ok, %Job{} = job} -> {:ok, {:created, job}}
      {:error, :rebalance_not_needed} -> {:ok, :not_needed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Start a decommission control-plane job for one erasure set."
  @spec start_decommission(integer(), start_opts()) :: {:ok, Job.t()} | {:error, term()}
  def start_decommission(set_id, opts \\ []) when is_integer(set_id),
    do: create("decommission", Keyword.put(opts, :target_set_id, set_id))

  @doc "List jobs, newest first. Filters: `:kind`, `:status`, `:target_set_id`, `:limit`."
  @spec list(keyword()) :: [Job.t()]
  def list(opts \\ []) do
    Job
    |> maybe_where(:kind, Keyword.get(opts, :kind))
    |> maybe_where(:status, Keyword.get(opts, :status))
    |> maybe_where(:target_set_id, Keyword.get(opts, :target_set_id))
    |> order_by([j], desc: j.inserted_at)
    |> limit(^positive_int(Keyword.get(opts, :limit), 20))
    |> Repo.all()
  end

  @doc "Return the latest job for optional filters."
  @spec latest(keyword()) :: Job.t() | nil
  def latest(opts \\ []), do: opts |> Keyword.put(:limit, 1) |> list() |> List.first()

  @doc "Fetch a job by UUID."
  @spec get(String.t()) :: {:ok, Job.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case Repo.get(Job, id) do
      nil -> {:error, :not_found}
      %Job{} = job -> {:ok, job}
    end
  end

  @doc "Cancel a planned/running job by UUID."
  @spec cancel(String.t(), keyword()) :: {:ok, Job.t()} | {:error, term()}
  def cancel(id, opts \\ []) when is_binary(id) do
    with {:ok, job} <- get(id) do
      cancel_job(job, opts)
    end
  end

  @doc "Cancel the latest active job matching optional filters."
  @spec cancel_latest(keyword()) :: {:ok, Job.t()} | {:error, term()}
  def cancel_latest(opts \\ []) do
    opts
    |> active_job()
    |> case do
      nil -> {:error, :not_found}
      %Job{} = job -> cancel_job(job, opts)
    end
  end

  @doc "Return the latest active job matching optional filters."
  @spec active_job(keyword()) :: Job.t() | nil
  def active_job(opts \\ []) do
    Job
    |> where([j], j.status in ^@active_statuses)
    |> maybe_where(:kind, Keyword.get(opts, :kind))
    |> maybe_where(:target_set_id, Keyword.get(opts, :target_set_id))
    |> order_by([j], desc: j.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Return the next rebalance/decommission job a background worker may safely advance.

  Data movement jobs are selected first while they are planned/running. Once a
  decommission or rebalance copy phase has completed, the same job becomes
  selectable for guarded source cleanup unless another active job is already
  running.
  """
  @spec next_runnable(keyword()) :: {:ok, Job.t()} | {:error, :not_found}
  def next_runnable(opts \\ []) do
    case Keyword.get(opts, :job_id) do
      id when is_binary(id) ->
        get(id)

      _other ->
        case next_copy_job() || next_source_cleanup_job_if_unblocked() do
          %Job{} = job -> {:ok, job}
          nil -> {:error, :not_found}
        end
    end
  end

  @doc """
  Return the next decommission-only job a background worker may safely advance.

  Kept for tests/operators that intentionally scope a worker to decommission
  copy/cleanup and do not want it to consume rebalance jobs.
  """
  @spec next_runnable_decommission(keyword()) :: {:ok, Job.t()} | {:error, :not_found}
  def next_runnable_decommission(opts \\ []) do
    case Keyword.get(opts, :job_id) do
      id when is_binary(id) ->
        get(id)

      _other ->
        case next_decommission_copy_job() || next_decommission_cleanup_job_if_unblocked() do
          %Job{} = job -> {:ok, job}
          nil -> {:error, :not_found}
        end
    end
  end

  @doc """
  Return the next source cleanup job a worker/CLI may safely advance.

  This selector intentionally skips ordinary latest-job ordering. A no-arg
  cleanup invocation must not pick a newer completed job whose cleanup is
  already complete while an older copy-complete job is still waiting for source
  cleanup.
  """
  @spec next_runnable_source_cleanup(keyword()) :: {:ok, Job.t()} | {:error, :not_found}
  def next_runnable_source_cleanup(opts \\ []) do
    case Keyword.get(opts, :job_id) do
      id when is_binary(id) ->
        get(id)

      _other ->
        case next_source_cleanup_job_if_unblocked() do
          %Job{} = job -> {:ok, job}
          nil -> {:error, :not_found}
        end
    end
  end

  @doc """
  Return the next completed rebalance job whose placement closure audit may be recorded.

  This selector only returns jobs that already finished data movement and
  guarded source cleanup. It does not run the audit itself; callers must still
  use `Workflow.summary/2` and record the result through
  `begin_rebalance_closure/2` and one of the terminal recording functions.
  """
  @spec next_runnable_rebalance_closure(keyword()) :: {:ok, Job.t()} | {:error, :not_found}
  def next_runnable_rebalance_closure(opts \\ []) do
    case Keyword.get(opts, :job_id) do
      id when is_binary(id) ->
        with {:ok, job} <- get(id),
             true <- rebalance_closure_job_runnable?(job),
             true <- is_nil(active_job()) do
          {:ok, job}
        else
          false -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        case next_rebalance_closure_job_if_unblocked() do
          %Job{} = job -> {:ok, job}
          nil -> {:error, :not_found}
        end
    end
  end

  @doc """
  Return the next completed decommission job whose deployment topology may be
  finalized by an operator or a config-gated scheduler.

  This selector only returns jobs that already have runtime-local removal and
  cluster convergence audit evidence. It does not verify live topology or write
  the deployment revision; callers must still use `TopologyMutation`.
  """
  @spec next_runnable_deployment_topology(keyword()) :: {:ok, Job.t()} | {:error, :not_found}
  def next_runnable_deployment_topology(opts \\ []) do
    case Keyword.get(opts, :job_id) do
      id when is_binary(id) ->
        with {:ok, job} <- get(id),
             true <- deployment_topology_job_runnable?(job),
             true <- is_nil(active_job()) do
          {:ok, job}
        else
          false -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        case next_deployment_topology_job_if_unblocked() do
          %Job{} = job -> {:ok, job}
          nil -> {:error, :not_found}
        end
    end
  end

  @doc """
  Return the next completed decommission job whose runtime topology removal may
  be applied by an operator or a config-gated scheduler.

  This selector only returns jobs that already finished data movement and
  guarded source cleanup and have not recorded cluster runtime convergence. It
  does not run preflight or mutate topology; callers must still use
  `TopologyMutation`.
  """
  @spec next_runnable_runtime_topology(keyword()) :: {:ok, Job.t()} | {:error, :not_found}
  def next_runnable_runtime_topology(opts \\ []) do
    case Keyword.get(opts, :job_id) do
      id when is_binary(id) ->
        with {:ok, job} <- get(id),
             true <- runtime_topology_job_runnable?(job),
             true <- is_nil(active_job()) do
          {:ok, job}
        else
          false -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        case next_runtime_topology_job_if_unblocked() do
          %Job{} = job -> {:ok, job}
          nil -> {:error, :not_found}
        end
    end
  end

  @doc "Machine-friendly map for CLI JSON output and tests."
  @spec to_view(Job.t()) :: map()
  def to_view(%Job{} = job) do
    %{
      id: job.id,
      kind: job.kind,
      status: job.status,
      data_movement_status: job.data_movement_status,
      data_movement: data_movement?(job),
      target_set_id: job.target_set_id,
      destination_set_id: job.destination_set_id,
      source_cleanup_status: job.source_cleanup_status,
      source_cleanup_cursor_bucket: job.source_cleanup_cursor_bucket,
      source_cleanup_cursor_key_marker: job.source_cleanup_cursor_key_marker,
      source_cleanup_cursor_version_id_marker: job.source_cleanup_cursor_version_id_marker,
      source_cleanup_scanned: job.source_cleanup_scanned,
      source_cleanup_deleted: job.source_cleanup_deleted,
      source_cleanup_skipped: job.source_cleanup_skipped,
      source_cleanup_errors: job.source_cleanup_errors,
      rebalance_closure_status: job.rebalance_closure_status,
      rebalance_closure_checked_at: iso8601(job.rebalance_closure_checked_at),
      rebalance_closure_verified_at: iso8601(job.rebalance_closure_verified_at),
      rebalance_closure_topology_hash: job.rebalance_closure_topology_hash,
      rebalance_closure_results: job.rebalance_closure_results,
      rebalance_closure_blockers: job.rebalance_closure_blockers,
      rebalance_closure_error_reason: job.rebalance_closure_error_reason,
      topology_removal_status: job.topology_removal_status,
      topology_removal_scope: job.topology_removal_scope,
      topology_removal_current_hash: job.topology_removal_current_hash,
      topology_removal_proposed_hash: job.topology_removal_proposed_hash,
      topology_removal_target_endpoints: job.topology_removal_target_endpoints,
      topology_removal_removed_pool_ids: job.topology_removal_removed_pool_ids,
      topology_removal_applied_at: iso8601(job.topology_removal_applied_at),
      topology_removal_cluster_status: job.topology_removal_cluster_status,
      topology_removal_cluster_hash: job.topology_removal_cluster_hash,
      topology_removal_cluster_nodes: job.topology_removal_cluster_nodes,
      topology_removal_cluster_verified_at: iso8601(job.topology_removal_cluster_verified_at),
      topology_removal_deployment_status: job.topology_removal_deployment_status,
      topology_removal_deployment_hash: job.topology_removal_deployment_hash,
      topology_removal_deployment_verified_at:
        iso8601(job.topology_removal_deployment_verified_at),
      physical_removal_status: job.physical_removal_status,
      physical_removal_scope: job.physical_removal_scope,
      physical_removal_quarantine_id: job.physical_removal_quarantine_id,
      physical_removal_manifest_hash: job.physical_removal_manifest_hash,
      physical_removal_preflight_verified_at: iso8601(job.physical_removal_preflight_verified_at),
      physical_removal_started_at: iso8601(job.physical_removal_started_at),
      physical_removal_completed_at: iso8601(job.physical_removal_completed_at),
      physical_removal_results: sanitize_physical_removal_results(job.physical_removal_results),
      physical_removal_roots_quarantined: job.physical_removal_roots_quarantined,
      physical_removal_markers_written: job.physical_removal_markers_written,
      physical_removal_errors: job.physical_removal_errors,
      physical_removal_error_reason: job.physical_removal_error_reason,
      physical_removal_purge_status: job.physical_removal_purge_status,
      physical_removal_purge_scope: job.physical_removal_purge_scope,
      physical_removal_purge_quarantine_id: job.physical_removal_purge_quarantine_id,
      physical_removal_purge_manifest_hash: job.physical_removal_purge_manifest_hash,
      physical_removal_purge_retention_seconds: job.physical_removal_purge_retention_seconds,
      physical_removal_purge_retention_until: iso8601(job.physical_removal_purge_retention_until),
      physical_removal_purge_preflight_verified_at:
        iso8601(job.physical_removal_purge_preflight_verified_at),
      physical_removal_purge_started_at: iso8601(job.physical_removal_purge_started_at),
      physical_removal_purge_completed_at: iso8601(job.physical_removal_purge_completed_at),
      physical_removal_purge_results: job.physical_removal_purge_results,
      physical_removal_purge_roots_deleted: job.physical_removal_purge_roots_deleted,
      physical_removal_purge_files_deleted: job.physical_removal_purge_files_deleted,
      physical_removal_purge_dirs_deleted: job.physical_removal_purge_dirs_deleted,
      physical_removal_purge_bytes_deleted: job.physical_removal_purge_bytes_deleted,
      physical_removal_purge_markers_written: job.physical_removal_purge_markers_written,
      physical_removal_purge_errors: job.physical_removal_purge_errors,
      physical_removal_purge_error_reason: job.physical_removal_purge_error_reason,
      current_only: job.current_only,
      include_drive_stats: job.include_drive_stats,
      page_size: job.page_size,
      plan_status: job.plan_status,
      plan_scanned: job.plan_scanned,
      plan_bytes: job.plan_bytes,
      plan_placement_fallbacks: job.plan_placement_fallbacks,
      cursor_bucket: job.cursor_bucket,
      cursor_key_marker: job.cursor_key_marker,
      cursor_version_id_marker: job.cursor_version_id_marker,
      progress_scanned: job.progress_scanned,
      progress_moved: job.progress_moved,
      progress_skipped: job.progress_skipped,
      progress_errors: job.progress_errors,
      cancel_requested_at: iso8601(job.cancel_requested_at),
      started_at: iso8601(job.started_at),
      finished_at: iso8601(job.finished_at),
      requested_by: job.requested_by,
      error_reason: job.error_reason,
      inserted_at: iso8601(job.inserted_at),
      updated_at: iso8601(job.updated_at)
    }
  end

  @doc "Mark a decommission job as running and bind its destination set."
  @spec begin_data_movement(Job.t() | String.t(), non_neg_integer(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def begin_data_movement(job_or_id, destination_set_id, opts \\ [])

  def begin_data_movement(job_or_id, destination_set_id, opts)
      when is_integer(destination_set_id) do
    with {:ok, job} <- fetch_job(job_or_id),
         :ok <- ensure_destination_compatible(job, destination_set_id) do
      attrs = %{
        status: "running",
        data_movement_status: "moving",
        destination_set_id: destination_set_id,
        source_cleanup_status: "not_started",
        error_reason: nil
      }

      attrs = if job.started_at, do: attrs, else: Map.put(attrs, :started_at, now(opts))

      guarded_begin_data_movement(job, attrs, destination_set_id)
    end
  end

  def begin_data_movement(_job_or_id, destination_set_id, _opts),
    do: {:error, {:invalid_destination_set_id, destination_set_id}}

  @doc "Mark a rebalance job as running without binding a single destination set."
  @spec begin_rebalance_data_movement(Job.t() | String.t(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def begin_rebalance_data_movement(job_or_id, opts \\ []) do
    with {:ok, job} <- fetch_job(job_or_id),
         :ok <- ensure_rebalance_movement_compatible(job) do
      attrs = %{
        status: "running",
        data_movement_status: "moving",
        destination_set_id: nil,
        source_cleanup_status: "not_started",
        error_reason: nil
      }

      attrs = if job.started_at, do: attrs, else: Map.put(attrs, :started_at, now(opts))

      guarded_begin_rebalance_data_movement(job, attrs)
    end
  end

  @doc "Persist foreground runner counters and resume cursor."
  @spec record_progress(Job.t() | String.t(), map(), map()) :: {:ok, Job.t()} | {:error, term()}
  def record_progress(job_or_id, counters, cursor_attrs \\ %{}) do
    with {:ok, job} <- fetch_job(job_or_id) do
      attrs =
        %{
          progress_scanned: Map.get(counters, :scanned, job.progress_scanned),
          progress_moved: Map.get(counters, :moved, job.progress_moved),
          progress_skipped: Map.get(counters, :skipped, job.progress_skipped),
          progress_errors: Map.get(counters, :errors, job.progress_errors)
        }
        |> Map.merge(
          Map.take(cursor_attrs, [:cursor_bucket, :cursor_key_marker, :cursor_version_id_marker])
        )

      monotonic_progress_update(job, attrs)
    end
  end

  @doc "Finish a runner pass successfully and clear resume cursor."
  @spec complete_data_movement(Job.t() | String.t(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def complete_data_movement(job_or_id, opts \\ []) do
    with {:ok, job} <- fetch_job(job_or_id) do
      guarded_update_job(
        job,
        %{
          status: "complete",
          data_movement_status: "complete",
          cursor_bucket: nil,
          cursor_key_marker: nil,
          cursor_version_id_marker: nil,
          finished_at: now(opts)
        },
        ["running"]
      )
    end
  end

  @doc "Mark a runner pass failed with a structured reason summary."
  @spec fail_data_movement(Job.t() | String.t(), term(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def fail_data_movement(job_or_id, reason, opts \\ []) do
    with {:ok, job} <- fetch_job(job_or_id) do
      guarded_update_job(
        job,
        %{
          status: "failed",
          data_movement_status: "failed",
          error_reason: inspect(reason),
          finished_at: now(opts)
        },
        ["running"]
      )
    end
  end

  @doc "Enter or resume the guarded source-shard cleanup phase for a decommission/rebalance job."
  @spec begin_source_cleanup(Job.t() | String.t(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def begin_source_cleanup(job_or_id, opts \\ []) do
    if Keyword.get(opts, :topology_lock_held, false) do
      begin_source_cleanup_locked(job_or_id, opts)
    else
      with_topology_lock(
        :rebalance_source_cleanup_begin,
        "job=#{inspect_job_ref(job_or_id)}",
        opts,
        fn -> begin_source_cleanup_locked(job_or_id, opts) end
      )
    end
  end

  defp begin_source_cleanup_locked(job_or_id, opts) do
    with {:ok, job} <- fetch_job(job_or_id),
         :ok <- ensure_source_cleanup_ready(job),
         :ok <- ensure_no_other_active_job(job) do
      guarded_begin_source_cleanup(job, opts)
    end
  end

  @doc "Persist source cleanup counters and resume cursor."
  @spec record_source_cleanup_progress(Job.t() | String.t(), map(), map()) ::
          {:ok, Job.t()} | {:error, term()}
  def record_source_cleanup_progress(job_or_id, counters, cursor_attrs \\ %{}) do
    with {:ok, job} <- fetch_job(job_or_id) do
      attrs =
        %{
          source_cleanup_scanned: Map.get(counters, :scanned, job.source_cleanup_scanned),
          source_cleanup_deleted: Map.get(counters, :deleted, job.source_cleanup_deleted),
          source_cleanup_skipped: Map.get(counters, :skipped, job.source_cleanup_skipped),
          source_cleanup_errors: Map.get(counters, :errors, job.source_cleanup_errors)
        }
        |> Map.merge(
          Map.take(cursor_attrs, [
            :source_cleanup_cursor_bucket,
            :source_cleanup_cursor_key_marker,
            :source_cleanup_cursor_version_id_marker
          ])
        )

      monotonic_source_cleanup_update(job, attrs)
    end
  end

  @doc "Mark source cleanup complete and clear its resume cursor."
  @spec complete_source_cleanup(Job.t() | String.t(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def complete_source_cleanup(job_or_id, opts \\ []) do
    with {:ok, job} <- fetch_job(job_or_id) do
      guarded_finish_source_cleanup(
        job,
        %{
          status: "complete",
          source_cleanup_status: "complete",
          source_cleanup_cursor_bucket: nil,
          source_cleanup_cursor_key_marker: nil,
          source_cleanup_cursor_version_id_marker: nil,
          finished_at: now(opts)
        }
      )
    end
  end

  @doc "Mark source cleanup failed with a structured reason summary."
  @spec fail_source_cleanup(Job.t() | String.t(), term(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def fail_source_cleanup(job_or_id, reason, opts \\ []) do
    with {:ok, job} <- fetch_job(job_or_id) do
      guarded_finish_source_cleanup(
        job,
        %{
          status: "failed",
          source_cleanup_status: "failed",
          error_reason: inspect(reason),
          finished_at: now(opts)
        }
      )
    end
  end

  @doc "Enter or resume the read-only rebalance placement closure audit phase."
  @spec begin_rebalance_closure(Job.t() | String.t(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def begin_rebalance_closure(job_or_id, opts \\ []) do
    with {:ok, job} <- fetch_job(job_or_id),
         :ok <- ensure_rebalance_closure_ready(job) do
      guarded_begin_rebalance_closure(job, opts)
    end
  end

  @doc "Mark a rebalance placement closure audit verified."
  @spec mark_rebalance_closure_verified(Job.t() | String.t(), map(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def mark_rebalance_closure_verified(job_or_id, report, opts \\ [])

  def mark_rebalance_closure_verified(
        job_or_id,
        %{job_kind: "rebalance", phase: "rebalance_closure"} = report,
        opts
      ) do
    with {:ok, job} <- fetch_job(job_or_id),
         :ok <- ensure_rebalance_closure_ready(job) do
      attrs = rebalance_closure_attrs(report, "verified", opts)
      guarded_finish_rebalance_closure(job, attrs)
    end
  end

  def mark_rebalance_closure_verified(_job_or_id, report, _opts),
    do: {:error, {:invalid_rebalance_closure_report, report}}

  @doc "Mark a rebalance placement closure audit blocked but retryable."
  @spec mark_rebalance_closure_blocked(Job.t() | String.t(), map(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def mark_rebalance_closure_blocked(job_or_id, report, opts \\ [])

  def mark_rebalance_closure_blocked(
        job_or_id,
        %{job_kind: "rebalance", phase: "rebalance_closure"} = report,
        opts
      ) do
    with {:ok, job} <- fetch_job(job_or_id),
         :ok <- ensure_rebalance_closure_ready(job) do
      attrs = rebalance_closure_attrs(report, "blocked", opts)
      guarded_finish_rebalance_closure(job, attrs)
    end
  end

  def mark_rebalance_closure_blocked(_job_or_id, report, _opts),
    do: {:error, {:invalid_rebalance_closure_report, report}}

  @doc "Mark a rebalance placement closure audit failed with a structured reason."
  @spec fail_rebalance_closure(Job.t() | String.t(), term(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def fail_rebalance_closure(job_or_id, reason, opts \\ []) do
    with {:ok, job} <- fetch_job(job_or_id),
         :ok <- ensure_rebalance_closure_ready(job) do
      attrs = %{
        rebalance_closure_status: "failed",
        rebalance_closure_checked_at: now(opts),
        rebalance_closure_verified_at: nil,
        rebalance_closure_topology_hash: nil,
        rebalance_closure_results: %{},
        rebalance_closure_blockers: [],
        rebalance_closure_error_reason: inspect(reason)
      }

      guarded_finish_rebalance_closure(job, attrs)
    end
  end

  @doc """
  Record an operator-confirmed runtime topology removal apply.

  This is an audit marker only. It does not write deployment config and does not
  make the completed job active again.
  """
  @spec mark_topology_removal_applied(Job.t() | String.t(), map(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def mark_topology_removal_applied(job_or_id, attrs, opts \\ []) do
    current_hash = Map.fetch!(attrs, :current_topology_hash)
    proposed_hash = Map.fetch!(attrs, :proposed_topology_hash)
    raw_target_endpoints = Map.get(attrs, :target_endpoints, %{})
    removed_pool_ids = normalize_integer_list(Map.get(attrs, :removed_pool_ids, []))

    with {:ok, job} <- fetch_job(job_or_id),
         {:ok, target_endpoints} <-
           normalize_recordable_target_endpoints(raw_target_endpoints, job, current_hash, opts),
         :ok <- ensure_topology_removal_recordable(job, current_hash, proposed_hash),
         :ok <- ensure_manifest_recordable(job, target_endpoints, removed_pool_ids) do
      if topology_removal_already_recorded?(job, current_hash, proposed_hash) do
        maybe_record_topology_removal_manifest(job, target_endpoints, removed_pool_ids)
      else
        record_topology_removal_applied(
          job,
          current_hash,
          proposed_hash,
          target_endpoints,
          removed_pool_ids,
          opts
        )
      end
    end
  end

  defp record_topology_removal_applied(
         job,
         current_hash,
         proposed_hash,
         target_endpoints,
         removed_pool_ids,
         opts
       ) do
    attrs =
      %{
        topology_removal_status: "runtime_local_applied",
        topology_removal_scope: "runtime_local",
        topology_removal_current_hash: current_hash,
        topology_removal_proposed_hash: proposed_hash,
        topology_removal_target_endpoints: target_endpoints,
        topology_removal_removed_pool_ids: removed_pool_ids,
        topology_removal_applied_at: now(opts),
        error_reason: nil
      }

    job
    |> Job.changeset(attrs)
    |> Repo.update()
  end

  defp maybe_record_topology_removal_manifest(job, target_endpoints, removed_pool_ids) do
    cond do
      empty_manifest?(target_endpoints) and removed_pool_ids == [] ->
        {:ok, job}

      manifest_matches?(job, target_endpoints, removed_pool_ids) ->
        {:ok, job}

      empty_manifest?(job.topology_removal_target_endpoints) and
          job.topology_removal_removed_pool_ids == [] ->
        job
        |> Job.changeset(%{
          topology_removal_target_endpoints: target_endpoints,
          topology_removal_removed_pool_ids: removed_pool_ids,
          error_reason: nil
        })
        |> Repo.update()

      true ->
        {:error, :topology_removal_manifest_mismatch}
    end
  end

  @doc """
  Record that all participating runtime nodes converged to the proposed topology.

  This is an audit marker only. It does not write deployment config and does not
  by itself retire decommission write-routing; deployment verification remains a
  separate operator step.
  """
  @spec mark_topology_removal_cluster_converged(Job.t() | String.t(), map(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def mark_topology_removal_cluster_converged(job_or_id, attrs, opts \\ []) do
    topology_hash = Map.fetch!(attrs, :cluster_topology_hash)
    nodes = attrs |> Map.get(:cluster_nodes, []) |> normalize_cluster_nodes()

    with {:ok, job} <- fetch_job(job_or_id),
         :ok <- ensure_topology_removal_cluster_recordable(job, topology_hash) do
      record_topology_removal_cluster_converged(job, topology_hash, nodes, opts)
    end
  end

  defp record_topology_removal_cluster_converged(job, topology_hash, nodes, opts) do
    attrs =
      %{
        topology_removal_cluster_status: "runtime_converged",
        topology_removal_cluster_hash: topology_hash,
        topology_removal_cluster_nodes: nodes,
        topology_removal_cluster_verified_at: now(opts),
        error_reason: nil
      }

    job
    |> Job.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Record that deployment config has been verified against a runtime removal.

  This is an audit marker only. It proves the configured deployment topology now
  matches the proposed removal hash, which is the point where decommission
  write-routing can be retired.
  """
  @spec mark_topology_removal_deployment_verified(Job.t() | String.t(), map(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def mark_topology_removal_deployment_verified(job_or_id, attrs, opts \\ []) do
    deployment_hash = Map.fetch!(attrs, :deployment_topology_hash)

    with {:ok, job} <- fetch_job(job_or_id),
         :ok <- ensure_topology_removal_deployment_recordable(job, deployment_hash) do
      if topology_removal_deployment_already_recorded?(job, deployment_hash) do
        {:ok, job}
      else
        record_topology_removal_deployment_verified(job, deployment_hash, opts)
      end
    end
  end

  defp record_topology_removal_deployment_verified(job, deployment_hash, opts) do
    attrs =
      %{
        topology_removal_deployment_status: "verified",
        topology_removal_deployment_hash: deployment_hash,
        topology_removal_deployment_verified_at: now(opts),
        error_reason: nil
      }

    job
    |> Job.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Enter or resume the operator-gated physical layout quarantine phase.

  This records audit state only. It does not make the completed decommission job
  active again and does not perform filesystem IO.
  """
  @spec begin_physical_removal(Job.t() | String.t(), map(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def begin_physical_removal(job_or_id, attrs, opts \\ []) do
    quarantine_id = Map.fetch!(attrs, :quarantine_id)
    manifest_hash = Map.fetch!(attrs, :manifest_hash)
    preflight_verified_at = Map.fetch!(attrs, :preflight_verified_at)
    results = Map.get(attrs, :results, %{})

    with {:ok, job} <- fetch_job(job_or_id),
         :ok <- ensure_physical_removal_recordable(job, manifest_hash, quarantine_id) do
      if physical_removal_already_complete?(job, manifest_hash) do
        {:ok, job}
      else
        record_physical_removal_begin(
          job,
          quarantine_id,
          manifest_hash,
          preflight_verified_at,
          results,
          opts
        )
      end
    end
  end

  @doc "Refresh stored physical layout quarantine results without changing quarantine status."
  @spec update_physical_removal_results(Job.t() | String.t(), map(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def update_physical_removal_results(job_or_id, attrs, opts \\ []) do
    manifest_hash = Map.fetch!(attrs, :manifest_hash)
    results = Map.fetch!(attrs, :results)

    with {:ok, job} <- fetch_job(job_or_id),
         :ok <- ensure_physical_removal_completable(job, manifest_hash) do
      record_physical_removal_results(job, manifest_hash, results, opts)
    end
  end

  @doc "Mark physical layout quarantine complete and persist endpoint results."
  @spec complete_physical_removal(Job.t() | String.t(), map(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def complete_physical_removal(job_or_id, attrs, opts \\ []) do
    manifest_hash = Map.fetch!(attrs, :manifest_hash)
    results = Map.fetch!(attrs, :results)

    with {:ok, job} <- fetch_job(job_or_id),
         :ok <- ensure_physical_removal_completable(job, manifest_hash) do
      record_physical_removal_complete(job, manifest_hash, results, opts)
    end
  end

  @doc "Mark physical layout quarantine failed with structured endpoint results."
  @spec fail_physical_removal(Job.t() | String.t(), term(), map(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def fail_physical_removal(job_or_id, reason, results \\ %{}, opts \\ []) do
    with {:ok, job} <- fetch_job(job_or_id) do
      record_physical_removal_failed(job, reason, results, opts)
    end
  end

  @doc """
  Enter or resume retention-gated hard delete of a quarantined layout root.

  This records audit state only. It does not make the completed decommission job
  active again and does not perform filesystem IO.
  """
  @spec begin_physical_removal_purge(Job.t() | String.t(), map(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def begin_physical_removal_purge(job_or_id, attrs, opts \\ []) do
    quarantine_id = Map.fetch!(attrs, :quarantine_id)
    manifest_hash = Map.fetch!(attrs, :manifest_hash)
    retention_seconds = Map.fetch!(attrs, :retention_seconds)
    retention_until = Map.fetch!(attrs, :retention_until)
    preflight_verified_at = Map.fetch!(attrs, :preflight_verified_at)
    results = Map.get(attrs, :results, %{})

    with {:ok, job} <- fetch_job(job_or_id),
         :ok <- ensure_physical_purge_recordable(job, manifest_hash, quarantine_id) do
      if physical_purge_already_complete?(job, manifest_hash, quarantine_id) do
        {:ok, job}
      else
        record_physical_purge_begin(
          job,
          quarantine_id,
          manifest_hash,
          retention_seconds,
          retention_until,
          preflight_verified_at,
          results,
          opts
        )
      end
    end
  end

  @doc "Mark quarantine hard delete complete and persist endpoint results."
  @spec complete_physical_removal_purge(Job.t() | String.t(), map(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def complete_physical_removal_purge(job_or_id, attrs, opts \\ []) do
    manifest_hash = Map.fetch!(attrs, :manifest_hash)
    quarantine_id = Map.fetch!(attrs, :quarantine_id)
    results = Map.fetch!(attrs, :results)

    with {:ok, job} <- fetch_job(job_or_id),
         :ok <- ensure_physical_purge_completable(job, manifest_hash, quarantine_id) do
      record_physical_purge_complete(job, manifest_hash, quarantine_id, results, opts)
    end
  end

  @doc "Mark quarantine hard delete failed with structured endpoint results."
  @spec fail_physical_removal_purge(Job.t() | String.t(), term(), map(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def fail_physical_removal_purge(job_or_id, reason, results \\ %{}, opts \\ []) do
    with {:ok, job} <- fetch_job(job_or_id) do
      record_physical_purge_failed(job, reason, results, opts)
    end
  end

  defp record_physical_removal_begin(
         job,
         quarantine_id,
         manifest_hash,
         preflight_verified_at,
         results,
         opts
       ) do
    results = sanitize_physical_removal_results(results)

    attrs = %{
      physical_removal_status: "quarantining",
      physical_removal_scope: "layout_quarantine",
      physical_removal_quarantine_id: quarantine_id,
      physical_removal_manifest_hash: manifest_hash,
      physical_removal_preflight_verified_at: preflight_verified_at,
      physical_removal_started_at: job.physical_removal_started_at || now(opts),
      physical_removal_results: results,
      physical_removal_roots_quarantined: 0,
      physical_removal_markers_written: 0,
      physical_removal_errors: 0,
      physical_removal_error_reason: nil,
      error_reason: nil
    }

    job
    |> Job.changeset(attrs)
    |> Repo.update()
  end

  defp record_physical_removal_results(job, _manifest_hash, results, _opts) do
    results = sanitize_physical_removal_results(results)
    summary = physical_results_summary(results)

    attrs = %{
      physical_removal_results: results,
      physical_removal_roots_quarantined: summary.roots_quarantined,
      physical_removal_markers_written: summary.markers_written,
      physical_removal_errors: summary.errors,
      physical_removal_error_reason: nil,
      error_reason: nil
    }

    job
    |> Job.changeset(attrs)
    |> Repo.update()
  end

  defp record_physical_removal_complete(job, manifest_hash, results, opts) do
    results = sanitize_physical_removal_results(results)
    summary = physical_results_summary(results)

    attrs = %{
      physical_removal_status: "quarantined",
      physical_removal_scope: "layout_quarantine",
      physical_removal_manifest_hash: manifest_hash,
      physical_removal_completed_at: now(opts),
      physical_removal_results: results,
      physical_removal_roots_quarantined: summary.roots_quarantined,
      physical_removal_markers_written: summary.markers_written,
      physical_removal_errors: summary.errors,
      physical_removal_error_reason: nil,
      error_reason: nil
    }

    job
    |> Job.changeset(attrs)
    |> Repo.update()
  end

  defp record_physical_removal_failed(job, reason, results, _opts) do
    results = sanitize_physical_removal_results(results)
    summary = physical_results_summary(results)

    attrs = %{
      physical_removal_status: "failed",
      physical_removal_scope: "layout_quarantine",
      physical_removal_results: results,
      physical_removal_roots_quarantined: summary.roots_quarantined,
      physical_removal_markers_written: summary.markers_written,
      physical_removal_errors: max(summary.errors, 1),
      physical_removal_error_reason: inspect(reason),
      error_reason: nil
    }

    job
    |> Job.changeset(attrs)
    |> Repo.update()
  end

  defp record_physical_purge_begin(
         job,
         quarantine_id,
         manifest_hash,
         retention_seconds,
         retention_until,
         preflight_verified_at,
         results,
         opts
       ) do
    attrs = %{
      physical_removal_purge_status: "purging",
      physical_removal_purge_scope: "quarantine_hard_delete",
      physical_removal_purge_quarantine_id: quarantine_id,
      physical_removal_purge_manifest_hash: manifest_hash,
      physical_removal_purge_retention_seconds: retention_seconds,
      physical_removal_purge_retention_until: retention_until,
      physical_removal_purge_preflight_verified_at: preflight_verified_at,
      physical_removal_purge_started_at: job.physical_removal_purge_started_at || now(opts),
      physical_removal_purge_results: results,
      physical_removal_purge_roots_deleted: 0,
      physical_removal_purge_files_deleted: 0,
      physical_removal_purge_dirs_deleted: 0,
      physical_removal_purge_bytes_deleted: 0,
      physical_removal_purge_markers_written: 0,
      physical_removal_purge_errors: 0,
      physical_removal_purge_error_reason: nil,
      error_reason: nil
    }

    job
    |> Job.changeset(attrs)
    |> Repo.update()
  end

  defp record_physical_purge_complete(job, manifest_hash, quarantine_id, results, opts) do
    summary = physical_purge_results_summary(results)

    attrs = %{
      physical_removal_purge_status: "purged",
      physical_removal_purge_scope: "quarantine_hard_delete",
      physical_removal_purge_quarantine_id: quarantine_id,
      physical_removal_purge_manifest_hash: manifest_hash,
      physical_removal_purge_completed_at: now(opts),
      physical_removal_purge_results: results,
      physical_removal_purge_roots_deleted: summary.roots_deleted,
      physical_removal_purge_files_deleted: summary.files_deleted,
      physical_removal_purge_dirs_deleted: summary.dirs_deleted,
      physical_removal_purge_bytes_deleted: summary.bytes_deleted,
      physical_removal_purge_markers_written: summary.markers_written,
      physical_removal_purge_errors: summary.errors,
      physical_removal_purge_error_reason: nil,
      error_reason: nil
    }

    job
    |> Job.changeset(attrs)
    |> Repo.update()
  end

  defp record_physical_purge_failed(job, reason, results, _opts) do
    summary = physical_purge_results_summary(results)

    attrs = %{
      physical_removal_purge_status: "failed",
      physical_removal_purge_scope: "quarantine_hard_delete",
      physical_removal_purge_results: results,
      physical_removal_purge_roots_deleted: summary.roots_deleted,
      physical_removal_purge_files_deleted: summary.files_deleted,
      physical_removal_purge_dirs_deleted: summary.dirs_deleted,
      physical_removal_purge_bytes_deleted: summary.bytes_deleted,
      physical_removal_purge_markers_written: summary.markers_written,
      physical_removal_purge_errors: max(summary.errors, 1),
      physical_removal_purge_error_reason: inspect(reason),
      error_reason: nil
    }

    job
    |> Job.changeset(attrs)
    |> Repo.update()
  end

  defp create(kind, opts) do
    with_topology_lock(:rebalance_job_start, "kind=#{kind}", opts, fn ->
      create_locked(kind, opts)
    end)
  end

  defp create_locked(kind, opts) do
    with :ok <- validate_kind(kind),
         :ok <- validate_scope(kind, opts),
         :ok <- ensure_no_active_job(),
         {:ok, report} <- build_plan(kind, opts),
         :ok <- ensure_topology(report),
         :ok <- ensure_safe_placement(kind, report),
         :ok <- ensure_rebalance_needed(kind, report, opts) do
      attrs = attrs_from_report(kind, report, opts)

      %Job{}
      |> Job.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, job} ->
          Log.info("rebalance job created",
            action: :rebalance_job_start,
            reason:
              "id=#{job.id} kind=#{job.kind} status=#{job.status} " <>
                "target_set_id=#{inspect(job.target_set_id)} scanned=#{job.plan_scanned} " <>
                "bytes=#{job.plan_bytes} data_movement_status=#{job.data_movement_status}"
          )

          {:ok, job}

        {:error, changeset} ->
          if active_singleton_conflict?(changeset) do
            {:error, {:active_job_exists, active_job()}}
          else
            {:error, changeset}
          end
      end
    end
  end

  defp topology_lock_opts(opts),
    do: Keyword.get(opts, :topology_lock_opts, Keyword.get(opts, :lock_opts, []))

  defp with_topology_lock(action, reason, opts, fun) do
    resource = Topology.runtime_mutation_lock_resource()

    case Lock.quorum_with_lock(resource, fun, topology_lock_opts(opts)) do
      {:ok, result} ->
        result

      {:error, :no_quorum} ->
        Log.error("rebalance topology mutation lock unavailable",
          action: action,
          reason: "#{reason} resource=#{inspect(resource)}"
        )

        {:error, :topology_mutation_locked}
    end
  end

  defp inspect_job_ref(%Job{id: id}), do: id
  defp inspect_job_ref(job_id) when is_binary(job_id), do: job_id
  defp inspect_job_ref(value), do: inspect(value)

  defp validate_kind(kind) when kind in ["rebalance", "decommission"], do: :ok
  defp validate_kind(kind), do: {:error, {:invalid_kind, kind}}

  defp validate_scope("decommission", opts) do
    if Keyword.get(opts, :current_only, false) do
      {:error, :decommission_requires_versions}
    else
      :ok
    end
  end

  defp validate_scope("rebalance", _opts), do: :ok

  defp ensure_no_active_job do
    case active_job() do
      nil -> :ok
      %Job{} = job -> {:error, {:active_job_exists, job}}
    end
  end

  defp next_copy_job do
    Job
    |> where([j], j.kind in ^["decommission", "rebalance"])
    |> where([j], j.status in ^["planned", "running"])
    |> where([j], j.data_movement_status in ^["not_started", "moving"])
    |> order_by([j], asc: j.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp next_decommission_copy_job do
    Job
    |> where([j], j.kind == "decommission")
    |> where([j], j.status in ^["planned", "running"])
    |> where([j], j.data_movement_status in ^["not_started", "moving"])
    |> order_by([j], asc: j.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp next_decommission_cleanup_job_if_unblocked do
    case active_job() do
      nil ->
        next_decommission_cleanup_job()

      %Job{
        kind: "decommission",
        data_movement_status: "complete",
        source_cleanup_status: status
      } = job
      when status in ["not_started", "moving", "failed"] ->
        job

      %Job{} ->
        nil
    end
  end

  defp next_source_cleanup_job_if_unblocked do
    case active_job() do
      nil ->
        next_source_cleanup_job()

      %Job{data_movement_status: "complete", source_cleanup_status: status} = job
      when status in ["not_started", "moving", "failed"] ->
        job

      %Job{kind: "rebalance", data_movement_status: "complete", source_cleanup_status: "skipped"} =
          job ->
        job

      %Job{} ->
        nil
    end
  end

  defp next_rebalance_closure_job_if_unblocked do
    case active_job() do
      nil -> next_rebalance_closure_job()
      %Job{} -> nil
    end
  end

  defp next_decommission_cleanup_job do
    Job
    |> where([j], j.kind == "decommission")
    |> where([j], j.data_movement_status == "complete")
    |> where([j], j.status in ^["complete", "running", "failed"])
    |> where([j], j.source_cleanup_status in ^["not_started", "moving", "failed"])
    |> order_by([j], asc: j.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp next_source_cleanup_job do
    Job
    |> where([j], j.kind in ^["decommission", "rebalance"])
    |> where([j], j.data_movement_status == "complete")
    |> where([j], j.status in ^["complete", "running", "failed"])
    |> where(
      [j],
      j.source_cleanup_status in ^["not_started", "moving", "failed"] or
        (j.kind == "rebalance" and j.source_cleanup_status == "skipped")
    )
    |> order_by([j], asc: j.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp next_rebalance_closure_job do
    Job
    |> where([j], j.kind == "rebalance")
    |> where([j], j.status == "complete")
    |> where([j], j.data_movement_status == "complete")
    |> where([j], j.source_cleanup_status == "complete")
    |> where([j], j.rebalance_closure_status in ^["not_started", "checking", "blocked", "failed"])
    |> order_by([j], asc: j.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp next_deployment_topology_job_if_unblocked do
    case active_job() do
      nil -> next_deployment_topology_job()
      %Job{} -> nil
    end
  end

  defp next_runtime_topology_job_if_unblocked do
    case active_job() do
      nil -> next_runtime_topology_job()
      %Job{} -> nil
    end
  end

  defp next_runtime_topology_job do
    Job
    |> where([j], j.kind == "decommission")
    |> where([j], j.status == "complete")
    |> where([j], j.data_movement_status == "complete")
    |> where([j], j.source_cleanup_status == "complete")
    |> where([j], not is_nil(j.destination_set_id))
    |> where([j], j.topology_removal_cluster_status != "runtime_converged")
    |> where([j], j.topology_removal_deployment_status != "verified")
    |> order_by([j], asc: j.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp next_deployment_topology_job do
    Job
    |> where([j], j.kind == "decommission")
    |> where([j], j.status == "complete")
    |> where([j], j.data_movement_status == "complete")
    |> where([j], j.source_cleanup_status == "complete")
    |> where([j], j.topology_removal_status == "runtime_local_applied")
    |> where([j], j.topology_removal_scope == "runtime_local")
    |> where([j], not is_nil(j.topology_removal_proposed_hash))
    |> where([j], j.topology_removal_cluster_status == "runtime_converged")
    |> where([j], not is_nil(j.topology_removal_cluster_hash))
    |> where([j], j.topology_removal_cluster_hash == j.topology_removal_proposed_hash)
    |> where([j], j.topology_removal_cluster_nodes != ^[])
    |> where([j], j.topology_removal_deployment_status != "verified")
    |> order_by([j], asc: j.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp deployment_topology_job_runnable?(%Job{} = job) do
    job.kind == "decommission" and
      job.status == "complete" and
      job.data_movement_status == "complete" and
      job.source_cleanup_status == "complete" and
      job.topology_removal_status == "runtime_local_applied" and
      job.topology_removal_scope == "runtime_local" and
      is_binary(job.topology_removal_proposed_hash) and
      byte_size(job.topology_removal_proposed_hash) > 0 and
      job.topology_removal_cluster_status == "runtime_converged" and
      is_binary(job.topology_removal_cluster_hash) and
      job.topology_removal_cluster_hash == job.topology_removal_proposed_hash and
      is_list(job.topology_removal_cluster_nodes) and
      job.topology_removal_cluster_nodes != [] and
      job.topology_removal_deployment_status != "verified"
  end

  defp rebalance_closure_job_runnable?(%Job{} = job) do
    job.kind == "rebalance" and
      job.status == "complete" and
      job.data_movement_status == "complete" and
      job.source_cleanup_status == "complete" and
      job.rebalance_closure_status in ["not_started", "checking", "blocked", "failed"]
  end

  defp runtime_topology_job_runnable?(%Job{} = job) do
    job.kind == "decommission" and
      job.status == "complete" and
      job.data_movement_status == "complete" and
      job.source_cleanup_status == "complete" and
      is_integer(job.destination_set_id) and
      job.topology_removal_cluster_status != "runtime_converged" and
      job.topology_removal_deployment_status != "verified"
  end

  defp build_plan("rebalance", opts), do: Rebalance.plan(plan_opts(opts))

  defp build_plan("decommission", opts) do
    case Keyword.fetch(opts, :target_set_id) do
      {:ok, set_id} when is_integer(set_id) ->
        Rebalance.decommission_impact(set_id, plan_opts(opts))

      {:ok, set_id} ->
        {:error, {:invalid_target_set_id, set_id}}

      :error ->
        {:error, :missing_target_set_id}
    end
  end

  defp ensure_topology(%{status: :no_topology}), do: {:error, :no_topology}
  defp ensure_topology(_report), do: :ok

  defp ensure_safe_placement("decommission", report) do
    case report.decommission.placement_fallbacks do
      0 -> :ok
      count -> {:error, {:placement_fallbacks, count}}
    end
  end

  defp ensure_safe_placement("rebalance", report) do
    case report.placement_fallbacks do
      0 -> :ok
      count -> {:error, {:placement_fallbacks, count}}
    end
  end

  defp ensure_rebalance_needed("rebalance", report, opts) do
    if Keyword.get(opts, :only_if_needed, false) and
         Map.get(report, :routing_mismatches, 0) == 0 do
      {:error, :rebalance_not_needed}
    else
      :ok
    end
  end

  defp ensure_rebalance_needed(_kind, _report, _opts), do: :ok

  defp plan_opts(opts) do
    [
      current_only: Keyword.get(opts, :current_only, false),
      page_size: positive_int(Keyword.get(opts, :page_size), @default_page_size),
      include_drive_stats: Keyword.get(opts, :include_drive_stats, true)
    ]
    |> maybe_put(:topology, Keyword.get(opts, :topology))
    |> maybe_put(:drive_stats_fun, Keyword.get(opts, :drive_stats_fun))
  end

  defp attrs_from_report(kind, report, opts) do
    %{
      kind: kind,
      status: "planned",
      data_movement_status: "not_started",
      target_set_id: target_set_id(kind, opts),
      current_only: report.current_only,
      include_drive_stats: Keyword.get(opts, :include_drive_stats, true),
      page_size: positive_int(Keyword.get(opts, :page_size), @default_page_size),
      plan_status: Atom.to_string(report.status),
      plan: json_ready(report),
      plan_scanned: plan_scanned(kind, report),
      plan_bytes: plan_bytes(kind, report),
      plan_placement_fallbacks: plan_placement_fallbacks(kind, report),
      progress_scanned: 0,
      progress_moved: 0,
      progress_skipped: 0,
      progress_errors: 0,
      source_cleanup_scanned: 0,
      source_cleanup_deleted: 0,
      source_cleanup_skipped: 0,
      source_cleanup_errors: 0,
      started_at: now(opts),
      requested_by: Keyword.get(opts, :requested_by, "mix")
    }
  end

  defp target_set_id("decommission", opts), do: Keyword.fetch!(opts, :target_set_id)
  defp target_set_id("rebalance", _opts), do: nil

  defp plan_scanned("decommission", report), do: report.decommission.versions
  defp plan_scanned("rebalance", report), do: report.scanned

  defp plan_bytes("decommission", report), do: report.decommission.bytes
  defp plan_bytes("rebalance", report), do: report.bytes

  defp plan_placement_fallbacks("decommission", report),
    do: report.decommission.placement_fallbacks

  defp plan_placement_fallbacks("rebalance", report), do: report.placement_fallbacks

  defp cancel_job(%Job{status: status} = job, opts) when status in @active_statuses do
    finished_at = now(opts)

    job_result =
      guarded_update_job(
        job,
        cancel_attrs(job, finished_at),
        @active_statuses
      )

    case job_result do
      {:ok, job} ->
        Log.info("rebalance job canceled",
          action: :rebalance_job_cancel,
          reason: "id=#{job.id} kind=#{job.kind} status=#{job.status}"
        )

        {:ok, job}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cancel_job(%Job{} = job, _opts), do: {:error, {:not_cancelable, job.status}}

  defp cancel_attrs(
         %Job{
           data_movement_status: "complete",
           source_cleanup_status: "moving"
         },
         finished_at
       ) do
    %{
      status: "canceled",
      data_movement_status: "complete",
      source_cleanup_status: "skipped",
      cancel_requested_at: finished_at,
      finished_at: finished_at
    }
  end

  defp cancel_attrs(_job, finished_at) do
    %{
      status: "canceled",
      data_movement_status: "canceled",
      cancel_requested_at: finished_at,
      finished_at: finished_at
    }
  end

  defp ensure_destination_compatible(
         %Job{kind: "decommission", target_set_id: target},
         destination
       )
       when target == destination,
       do: {:error, :destination_matches_target}

  defp ensure_destination_compatible(
         %Job{kind: "decommission", destination_set_id: nil},
         _destination
       ),
       do: :ok

  defp ensure_destination_compatible(
         %Job{kind: "decommission", destination_set_id: destination},
         destination
       ),
       do: :ok

  defp ensure_destination_compatible(
         %Job{kind: "decommission", destination_set_id: existing},
         destination
       ),
       do: {:error, {:destination_mismatch, existing, destination}}

  defp ensure_destination_compatible(%Job{kind: kind}, _destination),
    do: {:error, {:unsupported_job_kind, kind}}

  defp ensure_rebalance_movement_compatible(%Job{
         kind: "rebalance",
         status: status,
         data_movement_status: movement,
         target_set_id: nil,
         destination_set_id: nil
       })
       when status in ["planned", "running"] and movement in ["not_started", "moving"],
       do: :ok

  defp ensure_rebalance_movement_compatible(%Job{kind: "rebalance", status: status})
       when status not in ["planned", "running"],
       do: {:error, {:not_runnable, status}}

  defp ensure_rebalance_movement_compatible(%Job{
         kind: "rebalance",
         data_movement_status: movement
       })
       when movement not in ["not_started", "moving"],
       do: {:error, {:data_movement_not_runnable, movement}}

  defp ensure_rebalance_movement_compatible(%Job{kind: "rebalance"}), do: {:error, :stale_job}

  defp ensure_rebalance_movement_compatible(%Job{kind: kind}),
    do: {:error, {:unsupported_job_kind, kind}}

  defp ensure_source_cleanup_ready(%Job{kind: kind})
       when kind not in ["decommission", "rebalance"],
       do: {:error, {:unsupported_job_kind, kind}}

  defp ensure_source_cleanup_ready(%Job{data_movement_status: status})
       when status != "complete",
       do: {:error, {:data_movement_not_complete, status}}

  defp ensure_source_cleanup_ready(%Job{status: "canceled"}), do: {:error, :canceled}

  defp ensure_source_cleanup_ready(%Job{source_cleanup_status: "complete"}),
    do: {:error, :source_cleanup_complete}

  defp ensure_source_cleanup_ready(%Job{
         kind: "rebalance",
         target_set_id: nil,
         destination_set_id: nil,
         source_cleanup_status: status
       })
       when status in ["not_started", "moving", "failed", "skipped"],
       do: :ok

  defp ensure_source_cleanup_ready(%Job{kind: "rebalance"}), do: {:error, :stale_job}

  defp ensure_source_cleanup_ready(%Job{source_cleanup_status: "skipped"}),
    do: {:error, :source_cleanup_skipped}

  defp ensure_source_cleanup_ready(%Job{target_set_id: target, destination_set_id: destination})
       when is_integer(target) and is_integer(destination) and target != destination,
       do: :ok

  defp ensure_source_cleanup_ready(%Job{target_set_id: target, destination_set_id: destination})
       when target == destination,
       do: {:error, :destination_matches_target}

  defp ensure_source_cleanup_ready(%Job{destination_set_id: nil}),
    do: {:error, :missing_destination_set_id}

  defp ensure_source_cleanup_ready(%Job{target_set_id: nil}),
    do: {:error, :missing_target_set_id}

  defp ensure_rebalance_closure_ready(%Job{kind: kind}) when kind != "rebalance",
    do: {:error, {:unsupported_job_kind, kind}}

  defp ensure_rebalance_closure_ready(%Job{status: status}) when status != "complete",
    do: {:error, {:not_complete, status}}

  defp ensure_rebalance_closure_ready(%Job{data_movement_status: status})
       when status != "complete",
       do: {:error, {:data_movement_not_complete, status}}

  defp ensure_rebalance_closure_ready(%Job{source_cleanup_status: status})
       when status != "complete",
       do: {:error, {:source_cleanup_not_complete, status}}

  defp ensure_rebalance_closure_ready(%Job{target_set_id: target})
       when not is_nil(target),
       do: {:error, {:invalid_rebalance_target_set_id, target}}

  defp ensure_rebalance_closure_ready(%Job{destination_set_id: destination})
       when not is_nil(destination),
       do: {:error, {:invalid_rebalance_destination_set_id, destination}}

  defp ensure_rebalance_closure_ready(%Job{rebalance_closure_status: "verified"}),
    do: {:error, :rebalance_closure_already_verified}

  defp ensure_rebalance_closure_ready(%Job{rebalance_closure_status: status})
       when status in ["not_started", "checking", "blocked", "failed"],
       do: :ok

  defp ensure_rebalance_closure_ready(%Job{rebalance_closure_status: status}),
    do: {:error, {:invalid_rebalance_closure_status, status}}

  defp ensure_topology_removal_recordable(%Job{kind: kind}, _current_hash, _proposed_hash)
       when kind != "decommission",
       do: {:error, {:unsupported_job_kind, kind}}

  defp ensure_topology_removal_recordable(%Job{status: status}, _current_hash, _proposed_hash)
       when status != "complete",
       do: {:error, {:not_complete, status}}

  defp ensure_topology_removal_recordable(
         %Job{data_movement_status: status},
         _current_hash,
         _proposed_hash
       )
       when status != "complete",
       do: {:error, {:data_movement_not_complete, status}}

  defp ensure_topology_removal_recordable(
         %Job{source_cleanup_status: status},
         _current_hash,
         _proposed_hash
       )
       when status != "complete",
       do: {:error, {:source_cleanup_not_complete, status}}

  defp ensure_topology_removal_recordable(
         %Job{topology_removal_status: "runtime_local_applied"} = job,
         current_hash,
         proposed_hash
       ) do
    if topology_removal_already_recorded?(job, current_hash, proposed_hash) do
      :ok
    else
      {:error, :topology_removal_already_applied}
    end
  end

  defp ensure_topology_removal_recordable(%Job{}, _current_hash, _proposed_hash), do: :ok

  defp topology_removal_already_recorded?(
         %Job{
           topology_removal_status: "runtime_local_applied",
           topology_removal_scope: "runtime_local",
           topology_removal_current_hash: current_hash,
           topology_removal_proposed_hash: proposed_hash
         },
         current_hash,
         proposed_hash
       ),
       do: true

  defp topology_removal_already_recorded?(_job, _current_hash, _proposed_hash), do: false

  defp ensure_topology_removal_cluster_recordable(%Job{kind: kind}, _topology_hash)
       when kind != "decommission",
       do: {:error, {:unsupported_job_kind, kind}}

  defp ensure_topology_removal_cluster_recordable(%Job{status: status}, _topology_hash)
       when status != "complete",
       do: {:error, {:not_complete, status}}

  defp ensure_topology_removal_cluster_recordable(
         %Job{data_movement_status: status},
         _topology_hash
       )
       when status != "complete",
       do: {:error, {:data_movement_not_complete, status}}

  defp ensure_topology_removal_cluster_recordable(
         %Job{source_cleanup_status: status},
         _topology_hash
       )
       when status != "complete",
       do: {:error, {:source_cleanup_not_complete, status}}

  defp ensure_topology_removal_cluster_recordable(
         %Job{topology_removal_status: status, topology_removal_scope: scope},
         _topology_hash
       )
       when status != "runtime_local_applied" or scope != "runtime_local",
       do: {:error, :topology_removal_not_applied}

  defp ensure_topology_removal_cluster_recordable(
         %Job{topology_removal_proposed_hash: nil},
         _topology_hash
       ),
       do: {:error, :missing_proposed_topology_hash}

  defp ensure_topology_removal_cluster_recordable(
         %Job{topology_removal_proposed_hash: expected},
         topology_hash
       )
       when expected != topology_hash,
       do: {:error, {:cluster_topology_hash_mismatch, expected, topology_hash}}

  defp ensure_topology_removal_cluster_recordable(%Job{}, _topology_hash), do: :ok

  defp ensure_topology_removal_deployment_recordable(%Job{kind: kind}, _deployment_hash)
       when kind != "decommission",
       do: {:error, {:unsupported_job_kind, kind}}

  defp ensure_topology_removal_deployment_recordable(%Job{status: status}, _deployment_hash)
       when status != "complete",
       do: {:error, {:not_complete, status}}

  defp ensure_topology_removal_deployment_recordable(
         %Job{data_movement_status: status},
         _deployment_hash
       )
       when status != "complete",
       do: {:error, {:data_movement_not_complete, status}}

  defp ensure_topology_removal_deployment_recordable(
         %Job{source_cleanup_status: status},
         _deployment_hash
       )
       when status != "complete",
       do: {:error, {:source_cleanup_not_complete, status}}

  defp ensure_topology_removal_deployment_recordable(
         %Job{topology_removal_status: status, topology_removal_scope: scope},
         _deployment_hash
       )
       when status != "runtime_local_applied" or scope != "runtime_local",
       do: {:error, :topology_removal_not_applied}

  defp ensure_topology_removal_deployment_recordable(
         %Job{topology_removal_proposed_hash: nil},
         _deployment_hash
       ),
       do: {:error, :missing_proposed_topology_hash}

  defp ensure_topology_removal_deployment_recordable(
         %Job{topology_removal_deployment_status: "verified"} = job,
         deployment_hash
       ) do
    if topology_removal_deployment_already_recorded?(job, deployment_hash) do
      :ok
    else
      {:error, :topology_removal_deployment_already_verified}
    end
  end

  defp ensure_topology_removal_deployment_recordable(
         %Job{topology_removal_proposed_hash: expected},
         deployment_hash
       )
       when expected != deployment_hash,
       do: {:error, {:deployment_topology_hash_mismatch, expected, deployment_hash}}

  defp ensure_topology_removal_deployment_recordable(%Job{}, _deployment_hash), do: :ok

  defp topology_removal_deployment_already_recorded?(
         %Job{
           topology_removal_deployment_status: "verified",
           topology_removal_deployment_hash: deployment_hash
         },
         deployment_hash
       ),
       do: true

  defp topology_removal_deployment_already_recorded?(_job, _deployment_hash), do: false

  defp ensure_physical_removal_recordable(%Job{kind: kind}, _manifest_hash, _quarantine_id)
       when kind != "decommission",
       do: {:error, {:unsupported_job_kind, kind}}

  defp ensure_physical_removal_recordable(%Job{status: status}, _manifest_hash, _quarantine_id)
       when status != "complete",
       do: {:error, {:not_complete, status}}

  defp ensure_physical_removal_recordable(
         %Job{data_movement_status: status},
         _manifest_hash,
         _quarantine_id
       )
       when status != "complete",
       do: {:error, {:data_movement_not_complete, status}}

  defp ensure_physical_removal_recordable(
         %Job{source_cleanup_status: status},
         _manifest_hash,
         _quarantine_id
       )
       when status != "complete",
       do: {:error, {:source_cleanup_not_complete, status}}

  defp ensure_physical_removal_recordable(
         %Job{topology_removal_status: status, topology_removal_scope: scope},
         _manifest_hash,
         _quarantine_id
       )
       when status != "runtime_local_applied" or scope != "runtime_local",
       do: {:error, :topology_removal_not_applied}

  defp ensure_physical_removal_recordable(
         %Job{topology_removal_cluster_status: status},
         _manifest_hash,
         _quarantine_id
       )
       when status != "runtime_converged",
       do: {:error, :topology_removal_cluster_not_converged}

  defp ensure_physical_removal_recordable(
         %Job{topology_removal_deployment_status: status},
         _manifest_hash,
         _quarantine_id
       )
       when status != "verified",
       do: {:error, :topology_removal_deployment_not_verified}

  defp ensure_physical_removal_recordable(
         %Job{
           topology_removal_proposed_hash: proposed_hash,
           topology_removal_cluster_hash: cluster_hash
         },
         _manifest_hash,
         _quarantine_id
       )
       when is_binary(proposed_hash) and proposed_hash != cluster_hash,
       do: {:error, {:cluster_topology_hash_mismatch, proposed_hash, cluster_hash}}

  defp ensure_physical_removal_recordable(
         %Job{
           topology_removal_proposed_hash: proposed_hash,
           topology_removal_deployment_hash: deployment_hash
         },
         _manifest_hash,
         _quarantine_id
       )
       when is_binary(proposed_hash) and proposed_hash != deployment_hash,
       do: {:error, {:deployment_topology_hash_mismatch, proposed_hash, deployment_hash}}

  defp ensure_physical_removal_recordable(
         %Job{physical_removal_manifest_hash: existing},
         manifest_hash,
         _quarantine_id
       )
       when is_binary(existing) and existing != manifest_hash,
       do: {:error, :physical_removal_manifest_mismatch}

  defp ensure_physical_removal_recordable(
         %Job{physical_removal_quarantine_id: existing},
         _manifest_hash,
         quarantine_id
       )
       when is_binary(existing) and existing != quarantine_id,
       do: {:error, :physical_removal_quarantine_mismatch}

  defp ensure_physical_removal_recordable(
         %Job{physical_removal_status: "quarantined"},
         _manifest_hash,
         _quarantine_id
       ),
       do: :ok

  defp ensure_physical_removal_recordable(
         %Job{physical_removal_status: status},
         _manifest_hash,
         _quarantine_id
       )
       when status in ["not_started", "quarantining", "failed"],
       do: :ok

  defp ensure_physical_removal_recordable(
         %Job{physical_removal_status: status},
         _manifest_hash,
         _quarantine_id
       ),
       do: {:error, {:invalid_physical_removal_status, status}}

  defp ensure_physical_removal_completable(
         %Job{physical_removal_manifest_hash: existing},
         manifest_hash
       )
       when is_binary(existing) and existing != manifest_hash,
       do: {:error, :physical_removal_manifest_mismatch}

  defp ensure_physical_removal_completable(
         %Job{physical_removal_status: status},
         _manifest_hash
       )
       when status in ["quarantining", "quarantined"],
       do: :ok

  defp ensure_physical_removal_completable(
         %Job{physical_removal_status: status},
         _manifest_hash
       ),
       do: {:error, {:invalid_physical_removal_status, status}}

  defp physical_removal_already_complete?(
         %Job{
           physical_removal_status: "quarantined",
           physical_removal_manifest_hash: manifest_hash
         },
         manifest_hash
       ),
       do: true

  defp physical_removal_already_complete?(_job, _manifest_hash), do: false

  defp ensure_physical_purge_recordable(%Job{kind: kind}, _manifest_hash, _quarantine_id)
       when kind != "decommission",
       do: {:error, {:unsupported_job_kind, kind}}

  defp ensure_physical_purge_recordable(
         %Job{physical_removal_status: status},
         _manifest_hash,
         _quarantine_id
       )
       when status != "quarantined",
       do: {:error, {:physical_removal_not_quarantined, status}}

  defp ensure_physical_purge_recordable(
         %Job{physical_removal_manifest_hash: expected},
         manifest_hash,
         _quarantine_id
       )
       when is_binary(expected) and expected != manifest_hash,
       do: {:error, :physical_removal_manifest_mismatch}

  defp ensure_physical_purge_recordable(
         %Job{physical_removal_manifest_hash: nil},
         _manifest_hash,
         _quarantine_id
       ),
       do: {:error, :missing_physical_removal_manifest_hash}

  defp ensure_physical_purge_recordable(
         %Job{physical_removal_quarantine_id: expected},
         _manifest_hash,
         quarantine_id
       )
       when is_binary(expected) and expected != quarantine_id,
       do: {:error, :physical_removal_quarantine_mismatch}

  defp ensure_physical_purge_recordable(
         %Job{physical_removal_quarantine_id: nil},
         _manifest_hash,
         _quarantine_id
       ),
       do: {:error, :missing_physical_removal_quarantine_id}

  defp ensure_physical_purge_recordable(
         %Job{physical_removal_purge_manifest_hash: existing},
         manifest_hash,
         _quarantine_id
       )
       when is_binary(existing) and existing != manifest_hash,
       do: {:error, :physical_removal_purge_manifest_mismatch}

  defp ensure_physical_purge_recordable(
         %Job{physical_removal_purge_quarantine_id: existing},
         _manifest_hash,
         quarantine_id
       )
       when is_binary(existing) and existing != quarantine_id,
       do: {:error, :physical_removal_purge_quarantine_mismatch}

  defp ensure_physical_purge_recordable(
         %Job{physical_removal_purge_status: "purged"} = job,
         manifest_hash,
         quarantine_id
       ) do
    if physical_purge_already_complete?(job, manifest_hash, quarantine_id) do
      :ok
    else
      {:error, :physical_removal_purge_already_purged}
    end
  end

  defp ensure_physical_purge_recordable(
         %Job{physical_removal_purge_status: status},
         _manifest_hash,
         _quarantine_id
       )
       when status in ["not_started", "purging", "failed"],
       do: :ok

  defp ensure_physical_purge_recordable(
         %Job{physical_removal_purge_status: status},
         _manifest_hash,
         _quarantine_id
       ),
       do: {:error, {:invalid_physical_removal_purge_status, status}}

  defp ensure_physical_purge_completable(
         %Job{physical_removal_purge_manifest_hash: existing},
         manifest_hash,
         _quarantine_id
       )
       when is_binary(existing) and existing != manifest_hash,
       do: {:error, :physical_removal_purge_manifest_mismatch}

  defp ensure_physical_purge_completable(
         %Job{physical_removal_purge_quarantine_id: existing},
         _manifest_hash,
         quarantine_id
       )
       when is_binary(existing) and existing != quarantine_id,
       do: {:error, :physical_removal_purge_quarantine_mismatch}

  defp ensure_physical_purge_completable(
         %Job{physical_removal_purge_status: status},
         _manifest_hash,
         _quarantine_id
       )
       when status in ["purging", "purged"],
       do: :ok

  defp ensure_physical_purge_completable(
         %Job{physical_removal_purge_status: status},
         _manifest_hash,
         _quarantine_id
       ),
       do: {:error, {:invalid_physical_removal_purge_status, status}}

  defp physical_purge_already_complete?(
         %Job{
           physical_removal_purge_status: "purged",
           physical_removal_purge_manifest_hash: manifest_hash,
           physical_removal_purge_quarantine_id: quarantine_id
         },
         manifest_hash,
         quarantine_id
       ),
       do: true

  defp physical_purge_already_complete?(_job, _manifest_hash, _quarantine_id), do: false

  defp physical_results_summary(results) when is_map(results) do
    endpoints = Map.get(results, "endpoints") || Map.get(results, :endpoints) || []

    Enum.reduce(endpoints, %{roots_quarantined: 0, markers_written: 0, errors: 0}, fn endpoint,
                                                                                      acc ->
      roots = Map.get(endpoint, "roots") || Map.get(endpoint, :roots) || []
      roots = if is_list(roots), do: roots, else: []
      marker_written? = Map.get(endpoint, "marker_written") || Map.get(endpoint, :marker_written)
      status = Map.get(endpoint, "status") || Map.get(endpoint, :status)

      %{
        roots_quarantined: acc.roots_quarantined + length(roots),
        markers_written: acc.markers_written + if(marker_written?, do: 1, else: 0),
        errors: acc.errors + if(status in ["error", :error], do: 1, else: 0)
      }
    end)
  end

  defp physical_results_summary(_results),
    do: %{roots_quarantined: 0, markers_written: 0, errors: 0}

  defp sanitize_physical_removal_results(%{} = results) do
    results
    |> Enum.reject(fn {key, _value} -> raw_hardware_key?(key) end)
    |> Map.new(fn {key, value} ->
      key = to_string(key)
      {key, sanitize_physical_removal_result_value(key, value)}
    end)
  end

  defp sanitize_physical_removal_results(values) when is_list(values),
    do: Enum.map(values, &sanitize_physical_removal_results/1)

  defp sanitize_physical_removal_results(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> sanitize_physical_removal_results()

  defp sanitize_physical_removal_results(value) when is_boolean(value) or is_nil(value),
    do: value

  defp sanitize_physical_removal_results(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_physical_removal_results(value), do: value

  defp sanitize_physical_removal_result_value(key, value)
       when key in ["serial_hash", "wwid_hash"],
       do: safe_hardware_hash(value)

  defp sanitize_physical_removal_result_value(_key, value),
    do: sanitize_physical_removal_results(value)

  defp raw_hardware_key?(key) when key in [:serial, :wwid, "serial", "wwid"], do: true
  defp raw_hardware_key?(_key), do: false

  defp safe_hardware_hash(value) when is_binary(value) and value != "" do
    normalized = String.downcase(value)

    if String.match?(normalized, ~r/\A[0-9a-f]{64}\z/) do
      normalized
    else
      :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
    end
  end

  defp safe_hardware_hash(value), do: sanitize_physical_removal_results(value)

  defp physical_purge_results_summary(results) when is_map(results) do
    endpoints = Map.get(results, "endpoints") || Map.get(results, :endpoints) || []

    Enum.reduce(
      endpoints,
      %{
        roots_deleted: 0,
        files_deleted: 0,
        dirs_deleted: 0,
        bytes_deleted: 0,
        markers_written: 0,
        errors: 0
      },
      fn endpoint, acc ->
        marker_written? =
          Map.get(endpoint, "marker_written") || Map.get(endpoint, :marker_written)

        status = Map.get(endpoint, "status") || Map.get(endpoint, :status)

        %{
          roots_deleted: acc.roots_deleted + integer_value(endpoint, "roots_deleted"),
          files_deleted: acc.files_deleted + integer_value(endpoint, "files_deleted"),
          dirs_deleted: acc.dirs_deleted + integer_value(endpoint, "dirs_deleted"),
          bytes_deleted: acc.bytes_deleted + integer_value(endpoint, "bytes_deleted"),
          markers_written: acc.markers_written + if(marker_written?, do: 1, else: 0),
          errors: acc.errors + if(status in ["error", :error], do: 1, else: 0)
        }
      end
    )
  end

  defp physical_purge_results_summary(_results),
    do: %{
      roots_deleted: 0,
      files_deleted: 0,
      dirs_deleted: 0,
      bytes_deleted: 0,
      markers_written: 0,
      errors: 0
    }

  defp integer_value(%{} = map, key) do
    value = Map.get(map, key, Map.get(map, atom_counter_key(key), 0))
    if is_integer(value), do: value, else: 0
  end

  defp atom_counter_key("roots_deleted"), do: :roots_deleted
  defp atom_counter_key("files_deleted"), do: :files_deleted
  defp atom_counter_key("dirs_deleted"), do: :dirs_deleted
  defp atom_counter_key("bytes_deleted"), do: :bytes_deleted
  defp atom_counter_key(_key), do: nil

  defp ensure_manifest_recordable(%Job{} = job, target_endpoints, removed_pool_ids) do
    existing_endpoints = normalize_target_endpoints(job.topology_removal_target_endpoints)
    existing_pool_ids = normalize_integer_list(job.topology_removal_removed_pool_ids)

    cond do
      empty_manifest?(existing_endpoints) and existing_pool_ids == [] -> :ok
      empty_manifest?(target_endpoints) and removed_pool_ids == [] -> :ok
      existing_endpoints == target_endpoints and existing_pool_ids == removed_pool_ids -> :ok
      true -> {:error, :topology_removal_manifest_mismatch}
    end
  end

  defp manifest_matches?(%Job{} = job, target_endpoints, removed_pool_ids) do
    normalize_target_endpoints(job.topology_removal_target_endpoints) == target_endpoints and
      normalize_integer_list(job.topology_removal_removed_pool_ids) == removed_pool_ids
  end

  defp normalize_recordable_target_endpoints(nil, _job, _current_hash, _opts), do: {:ok, %{}}

  defp normalize_recordable_target_endpoints(%{} = manifest, %Job{} = job, current_hash, opts) do
    normalized = normalize_target_endpoints(manifest)

    with :ok <- ensure_no_dropped_manifest_entries(manifest, normalized) do
      if empty_manifest?(normalized) do
        {:ok, normalized}
      else
        with :ok <- ensure_manifest_targets_job(normalized, job),
             :ok <- ensure_manifest_matches_topology(normalized, job, current_hash, opts) do
          {:ok, normalized}
        end
      end
    end
  end

  defp normalize_recordable_target_endpoints(_manifest, _job, _current_hash, _opts),
    do: {:error, :invalid_topology_removal_manifest}

  defp ensure_no_dropped_manifest_entries(%{} = manifest, %{} = normalized) do
    raw_entries = fetch_map_value(manifest, :endpoints)
    normalized_entries = Map.get(normalized, "endpoints", [])

    cond do
      is_nil(raw_entries) and normalized_entries == [] -> :ok
      not is_list(raw_entries) -> {:error, :invalid_topology_removal_manifest}
      length(raw_entries) == length(normalized_entries) -> :ok
      true -> {:error, :invalid_topology_removal_manifest}
    end
  end

  defp ensure_manifest_targets_job(%{} = manifest, %Job{} = job) do
    target_set_id = Map.get(manifest, "target_set_id")
    target_pool_id = Map.get(manifest, "target_pool_id")
    endpoints = Map.get(manifest, "endpoints", [])

    cond do
      target_set_id != job.target_set_id ->
        {:error, :invalid_topology_removal_manifest}

      not is_integer(target_pool_id) ->
        {:error, :invalid_topology_removal_manifest}

      Enum.any?(endpoints, &invalid_manifest_endpoint?(&1, target_set_id, target_pool_id)) ->
        {:error, :invalid_topology_removal_manifest}

      true ->
        :ok
    end
  end

  defp invalid_manifest_endpoint?(%{} = endpoint, target_set_id, target_pool_id) do
    Map.get(endpoint, "set_id") != target_set_id or
      Map.get(endpoint, "pool_id") != target_pool_id or
      not is_binary(Map.get(endpoint, "node")) or
      Map.get(endpoint, "node") == "" or
      not is_binary(Map.get(endpoint, "drive")) or
      Map.get(endpoint, "drive") == ""
  end

  defp invalid_manifest_endpoint?(_endpoint, _target_set_id, _target_pool_id), do: true

  defp ensure_manifest_matches_topology(%{} = manifest, %Job{} = job, current_hash, opts) do
    with {:ok, topology} <- topology_for_manifest_validation(opts),
         :ok <- ensure_manifest_topology_hash(topology, current_hash),
         {:ok, expected_manifest} <-
           target_endpoint_manifest_from_topology(topology, job.target_set_id) do
      if manifest == expected_manifest do
        :ok
      else
        {:error, :invalid_topology_removal_manifest}
      end
    else
      {:error, _reason} -> {:error, :invalid_topology_removal_manifest}
    end
  end

  defp topology_for_manifest_validation(opts) do
    case Keyword.get(opts, :topology) do
      nil -> Topology.current()
      %{} = topology -> {:ok, topology}
      _other -> {:error, :invalid_topology_removal_manifest}
    end
  end

  defp ensure_manifest_topology_hash(topology, current_hash) do
    if Topology.fingerprint(topology) == current_hash do
      :ok
    else
      {:error, :invalid_topology_removal_manifest}
    end
  end

  defp target_endpoint_manifest_from_topology(topology, set_id) do
    if set_id in Topology.all_set_ids_from(topology) do
      pool_id = Topology.pool_id_for_set_from(topology, set_id)

      {:ok,
       %{
         "target_set_id" => set_id,
         "target_pool_id" => pool_id,
         "endpoints" =>
           topology
           |> Topology.endpoints_from(set_id)
           |> Enum.map(fn {node, drive} ->
             %{
               "node" => Atom.to_string(node),
               "drive" => drive,
               "set_id" => set_id,
               "pool_id" => pool_id
             }
           end)
       }}
    else
      {:error, :invalid_topology_removal_manifest}
    end
  end

  defp empty_manifest?(nil), do: true
  defp empty_manifest?(manifest) when map_size(manifest) == 0, do: true

  defp empty_manifest?(%{} = manifest) do
    endpoints = Map.get(manifest, "endpoints") || Map.get(manifest, :endpoints) || []
    endpoints == []
  end

  defp normalize_target_endpoints(%{} = manifest) do
    endpoints =
      manifest
      |> fetch_map_value(:endpoints)
      |> List.wrap()
      |> Enum.map(&normalize_endpoint_entry/1)
      |> Enum.reject(&is_nil/1)

    %{}
    |> maybe_put_string_key(
      "target_set_id",
      normalize_int(fetch_map_value(manifest, :target_set_id))
    )
    |> maybe_put_string_key(
      "target_pool_id",
      normalize_int(fetch_map_value(manifest, :target_pool_id))
    )
    |> Map.put("endpoints", endpoints)
  end

  defp normalize_target_endpoints(_manifest), do: %{}

  defp normalize_endpoint_entry(%{} = entry) do
    with node when is_binary(node) <- normalize_node_name(fetch_map_value(entry, :node)),
         drive when is_binary(drive) <- normalize_drive(fetch_map_value(entry, :drive)) do
      %{"node" => node, "drive" => drive}
      |> maybe_put_string_key("set_id", normalize_int(fetch_map_value(entry, :set_id)))
      |> maybe_put_string_key("pool_id", normalize_int(fetch_map_value(entry, :pool_id)))
    else
      _ -> nil
    end
  end

  defp normalize_endpoint_entry(_entry), do: nil

  defp normalize_node_name(node) when is_atom(node), do: Atom.to_string(node)
  defp normalize_node_name(node) when is_binary(node), do: node
  defp normalize_node_name(_node), do: nil

  defp normalize_drive(drive) when is_binary(drive), do: drive
  defp normalize_drive(_drive), do: nil

  defp fetch_map_value(%{} = map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp maybe_put_string_key(map, _key, nil), do: map
  defp maybe_put_string_key(map, key, value), do: Map.put(map, key, value)

  defp normalize_integer_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_int/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_integer_list(_values), do: []

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_string_list(_values), do: []

  defp normalize_int(value) when is_integer(value), do: value

  defp normalize_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_int(_value), do: nil

  defp normalize_cluster_nodes(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(fn
      node when is_atom(node) -> Atom.to_string(node)
      node when is_binary(node) -> node
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_cluster_nodes(_nodes), do: []

  defp ensure_no_other_active_job(%Job{id: id}) do
    case active_job() do
      nil -> :ok
      %Job{id: ^id} -> :ok
      %Job{} = job -> {:error, {:active_job_exists, job}}
    end
  end

  defp fetch_job(%Job{} = job), do: {:ok, job}
  defp fetch_job(id) when is_binary(id), do: get(id)
  defp fetch_job(value), do: {:error, {:invalid_job, value}}

  defp guarded_update_job(%Job{} = job, attrs, allowed_statuses) do
    changeset = Job.changeset(job, attrs)

    if changeset.valid? do
      changes =
        changeset.changes
        |> Map.put(:updated_at, DateTime.utc_now())
        |> Enum.into([])

      case Repo.update_all(
             from(j in Job, where: j.id == ^job.id and j.status in ^allowed_statuses),
             set: changes
           ) do
        {1, _rows} ->
          get(job.id)

        {0, _rows} ->
          case get(job.id) do
            {:ok, %Job{} = stale} -> {:error, {:stale_job_status, stale.status}}
            {:error, reason} -> {:error, reason}
          end
      end
    else
      {:error, changeset}
    end
  end

  defp monotonic_progress_update(%Job{} = job, attrs) do
    changeset = Job.changeset(job, attrs)

    if changeset.valid? do
      scanned = Ecto.Changeset.get_field(changeset, :progress_scanned)
      moved = Ecto.Changeset.get_field(changeset, :progress_moved)
      skipped = Ecto.Changeset.get_field(changeset, :progress_skipped)
      errors = Ecto.Changeset.get_field(changeset, :progress_errors)
      cursor_bucket = Ecto.Changeset.get_field(changeset, :cursor_bucket)
      cursor_key_marker = Ecto.Changeset.get_field(changeset, :cursor_key_marker)
      cursor_version_id_marker = Ecto.Changeset.get_field(changeset, :cursor_version_id_marker)

      now = DateTime.utc_now()

      query =
        from(j in Job,
          where: j.id == ^job.id and j.status == "running",
          update: [
            set: [
              progress_scanned: fragment("GREATEST(?, ?)", j.progress_scanned, ^scanned),
              progress_moved: fragment("GREATEST(?, ?)", j.progress_moved, ^moved),
              progress_skipped: fragment("GREATEST(?, ?)", j.progress_skipped, ^skipped),
              progress_errors: fragment("GREATEST(?, ?)", j.progress_errors, ^errors),
              cursor_bucket:
                fragment(
                  "CASE WHEN ? > ? THEN ? ELSE ? END",
                  ^scanned,
                  j.progress_scanned,
                  ^cursor_bucket,
                  j.cursor_bucket
                ),
              cursor_key_marker:
                fragment(
                  "CASE WHEN ? > ? THEN ? ELSE ? END",
                  ^scanned,
                  j.progress_scanned,
                  ^cursor_key_marker,
                  j.cursor_key_marker
                ),
              cursor_version_id_marker:
                fragment(
                  "CASE WHEN ? > ? THEN ? ELSE ? END",
                  ^scanned,
                  j.progress_scanned,
                  ^cursor_version_id_marker,
                  j.cursor_version_id_marker
                ),
              updated_at: ^now
            ]
          ]
        )

      case Repo.update_all(query, []) do
        {1, _rows} ->
          get(job.id)

        {0, _rows} ->
          case get(job.id) do
            {:ok, %Job{} = stale} -> {:error, {:stale_job_status, stale.status}}
            {:error, reason} -> {:error, reason}
          end
      end
    else
      {:error, changeset}
    end
  end

  defp monotonic_source_cleanup_update(%Job{} = job, attrs) do
    changeset = Job.changeset(job, attrs)

    if changeset.valid? do
      scanned = Ecto.Changeset.get_field(changeset, :source_cleanup_scanned)
      deleted = Ecto.Changeset.get_field(changeset, :source_cleanup_deleted)
      skipped = Ecto.Changeset.get_field(changeset, :source_cleanup_skipped)
      errors = Ecto.Changeset.get_field(changeset, :source_cleanup_errors)

      cursor_bucket =
        Ecto.Changeset.get_field(changeset, :source_cleanup_cursor_bucket)

      cursor_key_marker =
        Ecto.Changeset.get_field(changeset, :source_cleanup_cursor_key_marker)

      cursor_version_id_marker =
        Ecto.Changeset.get_field(changeset, :source_cleanup_cursor_version_id_marker)

      now = DateTime.utc_now()

      query =
        from(j in Job,
          where:
            j.id == ^job.id and j.status == "running" and
              j.source_cleanup_status == "moving",
          update: [
            set: [
              source_cleanup_scanned:
                fragment("GREATEST(?, ?)", j.source_cleanup_scanned, ^scanned),
              source_cleanup_deleted:
                fragment("GREATEST(?, ?)", j.source_cleanup_deleted, ^deleted),
              source_cleanup_skipped:
                fragment("GREATEST(?, ?)", j.source_cleanup_skipped, ^skipped),
              source_cleanup_errors: fragment("GREATEST(?, ?)", j.source_cleanup_errors, ^errors),
              source_cleanup_cursor_bucket:
                fragment(
                  "CASE WHEN ? > ? THEN ? ELSE ? END",
                  ^scanned,
                  j.source_cleanup_scanned,
                  ^cursor_bucket,
                  j.source_cleanup_cursor_bucket
                ),
              source_cleanup_cursor_key_marker:
                fragment(
                  "CASE WHEN ? > ? THEN ? ELSE ? END",
                  ^scanned,
                  j.source_cleanup_scanned,
                  ^cursor_key_marker,
                  j.source_cleanup_cursor_key_marker
                ),
              source_cleanup_cursor_version_id_marker:
                fragment(
                  "CASE WHEN ? > ? THEN ? ELSE ? END",
                  ^scanned,
                  j.source_cleanup_scanned,
                  ^cursor_version_id_marker,
                  j.source_cleanup_cursor_version_id_marker
                ),
              updated_at: ^now
            ]
          ]
        )

      case Repo.update_all(query, []) do
        {1, _rows} ->
          get(job.id)

        {0, _rows} ->
          case get(job.id) do
            {:ok, %Job{} = stale} -> {:error, {:stale_job_status, stale.status}}
            {:error, reason} -> {:error, reason}
          end
      end
    else
      {:error, changeset}
    end
  end

  defp guarded_begin_data_movement(%Job{} = job, attrs, destination_set_id) do
    changeset = Job.changeset(job, attrs)

    if changeset.valid? do
      changes =
        changeset.changes
        |> Map.put(:updated_at, DateTime.utc_now())
        |> Enum.into([])

      query =
        from(j in Job,
          where:
            j.id == ^job.id and j.kind == "decommission" and
              j.status in ^["planned", "running"] and
              j.target_set_id != ^destination_set_id and
              (is_nil(j.destination_set_id) or j.destination_set_id == ^destination_set_id)
        )

      case Repo.update_all(query, set: changes) do
        {1, _rows} ->
          get(job.id)

        {0, _rows} ->
          explain_begin_conflict(job.id, destination_set_id)
      end
    else
      {:error, changeset}
    end
  end

  defp guarded_begin_rebalance_data_movement(%Job{} = job, attrs) do
    changeset = Job.changeset(job, attrs)

    if changeset.valid? do
      changes =
        changeset.changes
        |> Map.put(:updated_at, DateTime.utc_now())
        |> Enum.into([])

      query =
        from(j in Job,
          where:
            j.id == ^job.id and j.kind == "rebalance" and
              j.status in ^["planned", "running"] and
              j.data_movement_status in ^["not_started", "moving"] and
              is_nil(j.target_set_id) and is_nil(j.destination_set_id)
        )

      case Repo.update_all(query, set: changes) do
        {1, _rows} -> get(job.id)
        {0, _rows} -> explain_rebalance_begin_conflict(job.id)
      end
    else
      {:error, changeset}
    end
  end

  defp explain_rebalance_begin_conflict(job_id) do
    case get(job_id) do
      {:ok, %Job{} = current} -> ensure_rebalance_movement_compatible(current)
      {:error, reason} -> {:error, reason}
    end
  end

  defp explain_begin_conflict(job_id, destination_set_id) do
    case get(job_id) do
      {:ok, %Job{} = current} ->
        case ensure_destination_compatible(current, destination_set_id) do
          :ok ->
            if current.status in ["planned", "running"],
              do: {:error, :stale_job},
              else: {:error, {:stale_job_status, current.status}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp guarded_begin_source_cleanup(%Job{} = job, opts) do
    attrs = %{
      status: "running",
      source_cleanup_status: "moving",
      error_reason: nil,
      finished_at: nil
    }

    attrs = if job.started_at, do: attrs, else: Map.put(attrs, :started_at, now(opts))
    changeset = Job.changeset(job, attrs)

    if changeset.valid? do
      changes =
        changeset.changes
        |> Map.put(:updated_at, DateTime.utc_now())
        |> Enum.into([])

      query = guarded_begin_source_cleanup_query(job)

      case Repo.update_all(query, set: changes) do
        {1, _rows} -> get(job.id)
        {0, _rows} -> explain_source_cleanup_conflict(job.id)
      end
    else
      {:error, changeset}
    end
  end

  defp guarded_finish_source_cleanup(%Job{} = job, attrs) do
    changeset = Job.changeset(job, attrs)

    if changeset.valid? do
      changes =
        changeset.changes
        |> Map.put(:updated_at, DateTime.utc_now())
        |> Enum.into([])

      query =
        from(j in Job,
          where:
            j.id == ^job.id and j.kind in ^["decommission", "rebalance"] and
              j.status == "running" and j.data_movement_status == "complete" and
              j.source_cleanup_status == "moving"
        )

      case Repo.update_all(query, set: changes) do
        {1, _rows} -> get(job.id)
        {0, _rows} -> explain_source_cleanup_conflict(job.id)
      end
    else
      {:error, changeset}
    end
  end

  defp rebalance_closure_attrs(%{} = report, status, opts) do
    audit = Map.get(report, :rebalance_audit, %{})
    blockers = report |> Map.get(:blockers, []) |> normalize_string_list()

    %{
      rebalance_closure_status: status,
      rebalance_closure_checked_at: now(opts),
      rebalance_closure_verified_at: rebalance_closure_verified_at(status, opts),
      rebalance_closure_topology_hash: Map.get(audit, :topology_hash),
      rebalance_closure_results: rebalance_closure_results(report, audit, blockers),
      rebalance_closure_blockers: blockers,
      rebalance_closure_error_reason: rebalance_closure_error_reason(report, status)
    }
  end

  defp rebalance_closure_verified_at("verified", opts), do: now(opts)
  defp rebalance_closure_verified_at(_status, _opts), do: nil

  defp rebalance_closure_results(report, audit, blockers) do
    %{
      workflow_status: Map.get(report, :status),
      rebalance_complete?: Map.get(report, :rebalance_complete?, false),
      audit: audit,
      blockers: blockers
    }
    |> json_ready()
  end

  defp rebalance_closure_error_reason(_report, "verified"), do: nil

  defp rebalance_closure_error_reason(%{rebalance_audit: %{reason: reason}}, _status)
       when is_binary(reason) and byte_size(reason) > 0,
       do: reason

  defp rebalance_closure_error_reason(%{blockers: blockers}, "blocked") when is_list(blockers),
    do: "blockers=#{Enum.join(normalize_string_list(blockers), ",")}"

  defp rebalance_closure_error_reason(report, _status), do: inspect(Map.get(report, :status))

  defp guarded_begin_rebalance_closure(%Job{} = job, opts) do
    attrs = %{
      rebalance_closure_status: "checking",
      rebalance_closure_checked_at: now(opts),
      rebalance_closure_verified_at: nil,
      rebalance_closure_topology_hash: nil,
      rebalance_closure_results: %{},
      rebalance_closure_blockers: [],
      rebalance_closure_error_reason: nil
    }

    guarded_update_rebalance_closure(job, attrs, ["not_started", "checking", "blocked", "failed"])
  end

  defp guarded_finish_rebalance_closure(%Job{} = job, attrs) do
    guarded_update_rebalance_closure(job, attrs, ["checking", "blocked", "failed"])
  end

  defp guarded_update_rebalance_closure(%Job{} = job, attrs, allowed_closure_statuses) do
    changeset = Job.changeset(job, attrs)

    if changeset.valid? do
      changes =
        changeset.changes
        |> Map.put(:updated_at, DateTime.utc_now())
        |> Enum.into([])

      query =
        from(j in Job,
          where:
            j.id == ^job.id and j.kind == "rebalance" and j.status == "complete" and
              j.data_movement_status == "complete" and j.source_cleanup_status == "complete" and
              j.rebalance_closure_status in ^allowed_closure_statuses
        )

      case Repo.update_all(query, set: changes) do
        {1, _rows} -> get(job.id)
        {0, _rows} -> explain_rebalance_closure_conflict(job.id)
      end
    else
      {:error, changeset}
    end
  end

  defp explain_rebalance_closure_conflict(job_id) do
    case get(job_id) do
      {:ok, %Job{} = current} -> ensure_rebalance_closure_ready(current)
      {:error, reason} -> {:error, reason}
    end
  end

  defp guarded_begin_source_cleanup_query(%Job{kind: "decommission"} = job) do
    from(j in Job,
      where:
        j.id == ^job.id and j.kind == "decommission" and
          j.data_movement_status == "complete" and
          j.status in ^["complete", "running", "failed"] and
          j.source_cleanup_status in ^["not_started", "moving", "failed"] and
          not is_nil(j.target_set_id) and not is_nil(j.destination_set_id) and
          j.target_set_id != j.destination_set_id
    )
  end

  defp guarded_begin_source_cleanup_query(%Job{kind: "rebalance"} = job) do
    from(j in Job,
      where:
        j.id == ^job.id and j.kind == "rebalance" and
          j.data_movement_status == "complete" and
          j.status in ^["complete", "running", "failed"] and
          j.source_cleanup_status in ^["not_started", "moving", "failed", "skipped"] and
          is_nil(j.target_set_id) and is_nil(j.destination_set_id)
    )
  end

  defp explain_source_cleanup_conflict(job_id) do
    case get(job_id) do
      {:ok, %Job{} = current} ->
        case ensure_source_cleanup_ready(current) do
          :ok -> {:error, :stale_job}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp data_movement?(%Job{} = job) do
    job.data_movement_status in ["moving", "complete", "failed"] or
      not is_nil(job.destination_set_id) or
      (job.progress_scanned || 0) > 0 or
      (job.progress_moved || 0) > 0
  end

  defp maybe_where(query, _field, nil), do: query

  defp maybe_where(query, field, value) do
    where(query, [j], field(j, ^field) == ^value)
  end

  defp active_singleton_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:status, {_message, opts}} ->
        Keyword.get(opts, :constraint_name) == "cluster_rebalance_jobs_active_singleton_index"

      _error ->
        false
    end)
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp json_ready(nil), do: nil
  defp json_ready(value) when is_boolean(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)

  defp json_ready(%{} = value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)
  end

  defp json_ready(value), do: value

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
