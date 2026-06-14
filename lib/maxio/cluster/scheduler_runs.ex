defmodule Maxio.Cluster.SchedulerRuns do
  @moduledoc """
  Persistent run ledger and restart-stable state for cluster schedulers.

  This module records evidence around existing scheduler passes. It does not
  execute heal, rebalance, topology, or physical-removal work.

  The ledger creates one run row per scheduler pass. Alert sink failures may
  annotate the just-created run summary, but skipped competitors still keep
  their own run evidence. State rows represent effective scheduler health, so
  neutral coordination skips such as lock losers and active backoff do not
  overwrite an existing effective ok/blocked/failed state.
  """

  import Ecto.Query

  alias Maxio.Cluster.{SchedulerRun, SchedulerRunRollup, SchedulerState}
  alias Maxio.Repo
  alias Maxio.S3.Log

  @default_failure_threshold 3
  @default_backoff_ms 300_000
  @default_max_summary_bytes 16_384
  @max_error_reason_chars 240
  @schedulers ~w(fresh_drive_heal rebalance)
  @triggers ~w(manual scheduled)
  @idle_errors [:no_runnable_job]
  @skipped_errors [
    :lock_unavailable,
    :source_cleanup_disabled,
    :runtime_topology_disabled,
    :runtime_topology_requires_auto_deployment_topology,
    :deployment_topology_disabled,
    :rebalance_closure_disabled,
    :canceled
  ]
  @summary_keys [
    :status,
    :phase,
    :job_id,
    :job_kind,
    :kind,
    :steps,
    :phases,
    :terminal_phase,
    :blockers,
    :next_action,
    :reason,
    :scanned,
    :healed,
    :unrecoverable,
    :errors,
    :drives_cleared,
    :rebalance_enqueue,
    :rebalance_advance,
    :moved,
    :deleted,
    :source_cleanup_status,
    :rebalance_complete?
  ]
  @neutral_skip_errors [:lock_unavailable]
  @non_effective_scheduled_statuses ["skipped"]
  @healthy_scheduled_statuses ["ok", "idle"]
  @default_since_minutes 60
  @default_stale_after_multiplier 2
  @default_rollup_window_ms 60 * 60 * 1_000
  @default_retention_max_windows 24 * 366
  @default_evidence_action_limit 8
  @rollup_version 1
  @sensitive_key_fragments [
    "secret",
    "password",
    "token",
    "credential",
    "authorization",
    "access_key",
    "raw",
    "serial",
    "wwid",
    "body",
    "data"
  ]
  @sensitive_text_patterns [
    ~r/(AWS4-HMAC-SHA256\s+Credential=)[^\s,]+/i,
    ~r/(authorization:?\s*)[^\s,]+/i,
    ~r/((?:--)?(?:secret|password|token|credential|access[-_]?key)(?:=|\s+))[^\s,;\]]+/i,
    ~r/(?<!-)(secret|password|token|credential)[^,\s\]]*/i
  ]

  @type scheduler :: :fresh_drive_heal | :rebalance | String.t()
  @type trigger :: :manual | :scheduled | String.t()

  @doc "Record one scheduler pass in the ledger and upsert current effective state."
  @spec record(scheduler(), trigger(), DateTime.t(), DateTime.t(), term(), keyword()) ::
          {:ok, %{run: SchedulerRun.t(), state: SchedulerState.t()}} | {:error, term()}
  def record(scheduler, trigger, started_at, finished_at, result, opts \\ []) do
    scheduler = scheduler_name(scheduler)
    trigger = trigger_name(trigger)
    repo = Keyword.get(opts, :repo, Repo)

    if enabled?(opts) do
      do_record(repo, scheduler, trigger, started_at, finished_at, result, opts)
    else
      {:error, :scheduler_ledger_disabled}
    end
  end

  @doc "Return the current state row if an automatic scheduler is still in backoff."
  @spec backoff_active?(scheduler(), keyword()) ::
          {:ok, SchedulerState.t() | nil} | {:error, term()}
  def backoff_active?(scheduler, opts \\ []) do
    scheduler = scheduler_name(scheduler)
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)

    case state(scheduler, repo: repo) do
      nil ->
        {:ok, nil}

      %SchedulerState{backoff_until: nil} ->
        {:ok, nil}

      %SchedulerState{backoff_until: backoff_until} = state ->
        if DateTime.compare(backoff_until, now) == :gt do
          {:ok, state}
        else
          {:ok, nil}
        end
    end
  rescue
    error -> {:error, {:scheduler_ledger_backoff_check_failed, Exception.message(error)}}
  end

  @doc "Fetch a scheduler state row."
  @spec state(scheduler(), keyword()) :: SchedulerState.t() | nil
  def state(scheduler, opts \\ []) do
    scheduler = scheduler_name(scheduler)
    repo = Keyword.get(opts, :repo, Repo)
    repo.get_by(SchedulerState, scheduler: scheduler)
  end

  @doc "List scheduler state rows."
  @spec list_states(keyword()) :: [SchedulerState.t()]
  def list_states(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    scheduler = Keyword.get(opts, :scheduler)

    SchedulerState
    |> maybe_filter_scheduler(scheduler)
    |> order_by([s], asc: s.scheduler)
    |> repo.all()
  end

  @doc "List recent scheduler run rows."
  @spec list_runs(keyword()) :: [SchedulerRun.t()]
  def list_runs(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    scheduler = Keyword.get(opts, :scheduler)
    limit = positive_int(Keyword.get(opts, :limit, 20), 20)

    SchedulerRun
    |> maybe_filter_scheduler(scheduler)
    |> order_by([r], desc: r.started_at)
    |> limit(^limit)
    |> repo.all()
  end

  @doc """
  Build durable closed-window rollups over scheduler run rows.

  This writes or dry-runs summary rows only. It never deletes
  `cluster_scheduler_runs`, never changes scheduler state, and never participates
  in scheduler execution, backoff, or cadence health.
  """
  @spec rollup(keyword()) :: {:ok, map()} | {:error, term()}
  def rollup(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    dry_run? = Keyword.get(opts, :dry_run, false)
    from = Keyword.fetch!(opts, :from)
    until = Keyword.fetch!(opts, :until)

    window_ms = Keyword.get(opts, :window_ms, @default_rollup_window_ms)
    schedulers = rollup_schedulers(Keyword.get(opts, :scheduler))
    triggers = rollup_triggers(Keyword.get(opts, :trigger))

    with :ok <- validate_rollup_scheduler_selection(schedulers),
         :ok <- validate_window_range(from, until, window_ms, opts) do
      windows = rollup_window_starts(from, until, window_ms)

      schedulers
      |> rollup_windows(triggers, windows, window_ms, opts |> Keyword.put(:repo, repo))
      |> case do
        {:ok, results} ->
          {:ok,
           %{
             status: if(dry_run?, do: :dry_run, else: :ok),
             dry_run?: dry_run?,
             from: from,
             until: until,
             window_ms: window_ms,
             windows: length(windows),
             rollups: results
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    error in KeyError -> {:error, {:missing_option, error.key}}
    error -> {:error, {:scheduler_rollup_failed, Exception.message(error)}}
  end

  @doc """
  Preflight raw scheduler run pruning against durable rollups.

  This never deletes rows. Prune requires an explicit single scheduler and
  trigger so manual and scheduled evidence cannot be mixed accidentally.
  """
  @spec prune_preflight(keyword()) :: {:ok, map()} | {:error, term()}
  def prune_preflight(opts \\ []), do: do_prune(opts, :preflight)

  @doc """
  Prune raw scheduler run rows only after their durable rollup is verified.

  This is an explicit operator action and requires `confirm?: true`. It never
  creates rollups, never changes scheduler state, and refuses to delete rows
  still needed by state/cadence reports.
  """
  @spec prune(keyword()) :: {:ok, map()} | {:error, term()}
  def prune(opts \\ []) do
    if Keyword.get(opts, :confirm?, false) do
      do_prune(opts, :prune)
    else
      {:error, :prune_confirmation_required}
    end
  end

  defp do_prune(opts, mode) when mode in [:preflight, :prune] do
    repo = Keyword.get(opts, :repo, Repo)
    from = Keyword.fetch!(opts, :from)
    until = Keyword.fetch!(opts, :until)

    window_ms = Keyword.get(opts, :window_ms, @default_rollup_window_ms)
    scheduler = required_prune_scheduler(opts)
    trigger = required_prune_trigger(opts)

    with :ok <- validate_rollup_scheduler(scheduler),
         :ok <- validate_trigger(trigger),
         :ok <- validate_prune_window_range(from, until, window_ms, opts) do
      windows = rollup_window_starts(from, until, window_ms)

      result =
        repo.transaction(fn ->
          lock_scheduler_trigger(repo, scheduler, trigger)

          case prune_windows(
                 [scheduler],
                 [trigger],
                 windows,
                 window_ms,
                 opts |> Keyword.put(:repo, repo) |> Keyword.put(:mode, mode)
               ) do
            {:ok, results} -> results
            {:error, reason} -> repo.rollback(reason)
          end
        end)

      case result do
        {:ok, results} ->
          prune_report(mode, from, until, window_ms, windows, results)

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    error in KeyError -> {:error, {:missing_option, error.key}}
    error -> {:error, {:scheduler_prune_failed, Exception.message(error)}}
  end

  @doc """
  Build a default-off scheduler ledger retention plan.

  The plan computes epoch-aligned closed windows older than the retention
  cutoff, then reuses prune preflight for verification. It never creates
  rollups and never deletes rows.
  """
  @spec retention_plan(keyword()) :: {:ok, map()} | {:error, term()}
  def retention_plan(opts \\ []), do: do_retention(opts, :preflight)

  @doc """
  Prune old raw scheduler run rows according to the retention policy.

  This is an explicit operator action. It requires retention to be enabled by
  config or opts plus `confirm?: true`, and it delegates deletion to verified
  prune so missing or stale rollups fail closed.
  """
  @spec retention_prune(keyword()) :: {:ok, map()} | {:error, term()}
  def retention_prune(opts \\ []) do
    opts = retention_opts(opts)

    cond do
      not retention_enabled?(opts) ->
        {:error, :scheduler_ledger_retention_disabled}

      not Keyword.get(opts, :confirm?, false) ->
        {:error, :retention_confirmation_required}

      true ->
        do_retention(opts, :prune)
    end
  end

  defp do_retention(opts, mode) when mode in [:preflight, :prune] do
    opts = retention_opts(opts)
    repo = Keyword.get(opts, :repo, Repo)
    scheduler = required_retention_scheduler(opts)
    trigger = required_retention_trigger(opts)
    now = Keyword.get_lazy(opts, :now, &now/0)
    retain_days = Keyword.get(opts, :retain_days)
    window_ms = retention_window_ms(opts)

    with :ok <- validate_rollup_scheduler(scheduler),
         :ok <- validate_trigger(trigger),
         :ok <- validate_retention_now(now),
         :ok <- validate_retention_days(retain_days),
         :ok <- validate_retention_window_ms(window_ms),
         {:ok, range} <-
           retention_range(repo, scheduler, trigger, now, retain_days, window_ms, opts) do
      retention_verify_or_prune(
        repo,
        scheduler,
        trigger,
        retain_days,
        range,
        window_ms,
        mode,
        opts
      )
    end
  rescue
    error in KeyError -> {:error, {:missing_option, error.key}}
    error -> {:error, {:scheduler_retention_failed, Exception.message(error)}}
  end

  @doc "Build one durable closed-window rollup for a scheduler/trigger/window."
  @spec rollup_window(scheduler(), String.t() | atom(), DateTime.t(), pos_integer(), keyword()) ::
          {:ok, SchedulerRunRollup.t() | map()} | {:error, term()}
  def rollup_window(scheduler, trigger, %DateTime{} = window_started_at, window_ms, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)
    scheduler = scheduler_name(scheduler)
    trigger = trigger_name(trigger)

    with :ok <- validate_rollup_scheduler(scheduler),
         :ok <- validate_trigger(trigger),
         :ok <- validate_aligned_window(window_started_at, window_ms),
         window_finished_at <- DateTime.add(window_started_at, window_ms, :millisecond),
         :ok <- validate_closed_window(window_finished_at, now) do
      if Keyword.get(opts, :dry_run, false) do
        runs =
          rollup_rows_for_window(repo, scheduler, trigger, window_started_at, window_finished_at)

        {:ok,
         rollup_attrs(
           scheduler,
           trigger,
           window_started_at,
           window_finished_at,
           window_ms,
           runs,
           opts
         )}
      else
        repo.transaction(fn ->
          lock_scheduler_trigger(repo, scheduler, trigger)

          runs =
            rollup_rows_for_window(
              repo,
              scheduler,
              trigger,
              window_started_at,
              window_finished_at
            )

          attrs =
            rollup_attrs(
              scheduler,
              trigger,
              window_started_at,
              window_finished_at,
              window_ms,
              runs,
              opts
            )

          case upsert_rollup_locked(repo, attrs) do
            {:ok, rollup} -> rollup
            {:error, reason} -> repo.rollback(reason)
          end
        end)
      end
    end
  rescue
    error -> {:error, {:scheduler_rollup_window_failed, Exception.message(error)}}
  end

  @doc "Prune one scheduler/trigger/window after verifying the durable rollup."
  @spec prune_window(scheduler(), String.t() | atom(), DateTime.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def prune_window(scheduler, trigger, %DateTime{} = window_started_at, window_ms, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)
    scheduler = scheduler_name(scheduler)
    trigger = trigger_name(trigger)

    with :ok <- validate_rollup_scheduler(scheduler),
         :ok <- validate_trigger(trigger),
         :ok <- validate_aligned_window(window_started_at, window_ms),
         window_finished_at <- DateTime.add(window_started_at, window_ms, :millisecond),
         :ok <- validate_closed_prune_window(window_finished_at, now, window_ms) do
      cond do
        Keyword.get(opts, :dry_run, false) ->
          repo.transaction(fn ->
            lock_scheduler_trigger(repo, scheduler, trigger)

            do_prune_window(
              repo,
              scheduler,
              trigger,
              window_started_at,
              window_finished_at,
              window_ms,
              Keyword.put(opts, :mode, :preflight)
            )
          end)

        Keyword.get(opts, :confirm?, false) ->
          repo.transaction(fn ->
            lock_scheduler_trigger(repo, scheduler, trigger)

            do_prune_window(
              repo,
              scheduler,
              trigger,
              window_started_at,
              window_finished_at,
              window_ms,
              Keyword.put(opts, :mode, :prune)
            )
          end)

        true ->
          {:error, :prune_confirmation_required}
      end
    end
  rescue
    error -> {:error, {:scheduler_prune_window_failed, Exception.message(error)}}
  end

  @doc "List durable scheduler run rollups."
  @spec list_rollups(keyword()) :: [SchedulerRunRollup.t()]
  def list_rollups(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    scheduler = Keyword.get(opts, :scheduler)
    trigger = Keyword.get(opts, :trigger)
    limit = positive_int(Keyword.get(opts, :limit, 20), 20)

    SchedulerRunRollup
    |> maybe_filter_scheduler(scheduler)
    |> maybe_filter_trigger(trigger)
    |> order_by([r], desc: r.window_finished_at, asc: r.scheduler, asc: r.trigger)
    |> limit(^limit)
    |> repo.all()
  end

  @doc """
  Build a read-only scheduler cadence health report from the run ledger.

  Cadence health only considers `trigger=scheduled` rows. Manual `run_now/1`
  evidence is useful for operator recovery, but it cannot prove that the
  background automation is alive. Skipped scheduled rows, such as lock losers or
  active backoff, are counted as evidence but never satisfy the effective
  scheduler heartbeat.
  """
  @spec cadence_report(keyword()) :: {:ok, map()} | {:error, term()}
  def cadence_report(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)
    schedulers = cadence_schedulers(Keyword.get(opts, :scheduler))

    reports =
      Enum.map(schedulers, fn scheduler ->
        cadence_report_for(repo, scheduler, now, opts)
      end)

    {:ok, %{generated_at: now, reports: reports}}
  rescue
    error -> {:error, {:scheduler_cadence_report_failed, Exception.message(error)}}
  end

  @doc """
  Build a read-only long-run evidence gate over scheduler ledger data.

  This report reuses scheduled-only cadence semantics and adds operator-facing
  gate checks for expected node participation, minimum effective nodes, and
  lock-loser evidence. It never starts schedulers, runs heal/rebalance work, or
  writes ledger rows.
  """
  @spec evidence_report(keyword()) :: {:ok, map()} | {:error, term()}
  def evidence_report(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    until = Keyword.get_lazy(opts, :until, fn -> Keyword.get_lazy(opts, :now, &now/0) end)
    from = evidence_from(opts, until)
    window_ms = Keyword.get(opts, :window_ms, @default_rollup_window_ms)
    expected_nodes = normalize_expected_nodes(Keyword.get(opts, :expected_nodes, []))
    min_effective_nodes = positive_int(Keyword.get(opts, :min_effective_nodes, 1), 1)
    require_lock_loser? = Keyword.get(opts, :require_lock_loser?, false) == true

    with :ok <- validate_evidence_range(from, until, window_ms),
         {:ok, cadence} <-
           opts
           |> Keyword.put(:repo, repo)
           |> Keyword.put(:now, until)
           |> Keyword.put(:since, from)
           |> Keyword.put(:until_exclusive?, true)
           |> cadence_report() do
      schedulers =
        Enum.map(cadence.reports, fn cadence_report ->
          scheduler_evidence(
            repo,
            cadence_report,
            from,
            until,
            window_ms,
            expected_nodes,
            min_effective_nodes,
            require_lock_loser?,
            opts
          )
        end)

      blockers = schedulers |> Enum.flat_map(& &1.blockers)
      warnings = schedulers |> Enum.flat_map(& &1.warnings)

      {:ok,
       %{
         status: evidence_status(blockers, warnings),
         generated_at: cadence.generated_at,
         from: from,
         until: until,
         window_ms: window_ms,
         expected_nodes: expected_nodes,
         min_effective_nodes: min_effective_nodes,
         require_lock_loser?: require_lock_loser?,
         schedulers: schedulers,
         blockers: blockers,
         warnings: warnings
       }}
    end
  rescue
    error -> {:error, {:scheduler_evidence_report_failed, Exception.message(error)}}
  end

  @doc "Render a schema struct into a JSON-safe map for CLIs."
  @spec to_view(SchedulerRun.t() | SchedulerState.t()) :: map()
  def to_view(%SchedulerRun{} = run) do
    %{
      id: run.id,
      scheduler: run.scheduler,
      trigger: run.trigger,
      node: run.node,
      status: run.status,
      result_kind: run.result_kind,
      phase: run.phase,
      job_id: run.job_id,
      started_at: iso8601(run.started_at),
      finished_at: iso8601(run.finished_at),
      duration_ms: run.duration_ms,
      consecutive_failures_after: run.consecutive_failures_after,
      backoff_until: iso8601(run.backoff_until),
      alert_status: run.alert_status,
      error_reason: run.error_reason,
      summary: run.summary
    }
  end

  def to_view(%SchedulerState{} = state) do
    %{
      id: state.id,
      scheduler: state.scheduler,
      node: state.node,
      status: state.status,
      consecutive_failures: state.consecutive_failures,
      last_run_id: state.last_run_id,
      last_started_at: iso8601(state.last_started_at),
      last_finished_at: iso8601(state.last_finished_at),
      backoff_until: iso8601(state.backoff_until),
      alert_status: state.alert_status,
      alerted_at: iso8601(state.alerted_at),
      last_error_reason: state.last_error_reason,
      last_summary: state.last_summary
    }
  end

  @doc "Render a scheduler rollup schema or attrs map into a JSON-safe map for CLIs."
  @spec rollup_to_view(SchedulerRunRollup.t() | map()) :: map()
  def rollup_to_view(%SchedulerRunRollup{} = rollup) do
    rollup
    |> Map.from_struct()
    |> Map.drop([:__meta__, :inserted_at, :updated_at])
    |> rollup_to_view()
  end

  def rollup_to_view(%{} = rollup) do
    %{
      id: Map.get(rollup, :id),
      scheduler: Map.get(rollup, :scheduler),
      trigger: Map.get(rollup, :trigger),
      window_started_at: iso8601(Map.get(rollup, :window_started_at)),
      window_finished_at: iso8601(Map.get(rollup, :window_finished_at)),
      window_ms: Map.get(rollup, :window_ms),
      run_count: Map.get(rollup, :run_count),
      ok_count: Map.get(rollup, :ok_count),
      idle_count: Map.get(rollup, :idle_count),
      skipped_count: Map.get(rollup, :skipped_count),
      blocked_count: Map.get(rollup, :blocked_count),
      failed_count: Map.get(rollup, :failed_count),
      effective_count: Map.get(rollup, :effective_count),
      healthy_count: Map.get(rollup, :healthy_count),
      result_ok_count: Map.get(rollup, :result_ok_count),
      result_error_count: Map.get(rollup, :result_error_count),
      duration_total_ms: Map.get(rollup, :duration_total_ms),
      duration_min_ms: Map.get(rollup, :duration_min_ms),
      duration_max_ms: Map.get(rollup, :duration_max_ms),
      first_run_id: Map.get(rollup, :first_run_id),
      last_run_id: Map.get(rollup, :last_run_id),
      last_status: Map.get(rollup, :last_status),
      last_result_kind: Map.get(rollup, :last_result_kind),
      last_phase: Map.get(rollup, :last_phase),
      last_job_id: Map.get(rollup, :last_job_id),
      last_finished_at: iso8601(Map.get(rollup, :last_finished_at)),
      last_effective_run_id: Map.get(rollup, :last_effective_run_id),
      last_effective_status: Map.get(rollup, :last_effective_status),
      last_effective_finished_at: iso8601(Map.get(rollup, :last_effective_finished_at)),
      last_healthy_run_id: Map.get(rollup, :last_healthy_run_id),
      last_healthy_status: Map.get(rollup, :last_healthy_status),
      last_healthy_finished_at: iso8601(Map.get(rollup, :last_healthy_finished_at)),
      last_error_reason: Map.get(rollup, :last_error_reason),
      last_summary: Map.get(rollup, :last_summary),
      source_max_updated_at: iso8601(Map.get(rollup, :source_max_updated_at)),
      source_digest: Map.get(rollup, :source_digest),
      rolled_up_at: iso8601(Map.get(rollup, :rolled_up_at)),
      rollup_version: Map.get(rollup, :rollup_version),
      pruned_at: iso8601(Map.get(rollup, :pruned_at)),
      pruned_run_count: Map.get(rollup, :pruned_run_count),
      pruned_source_digest: Map.get(rollup, :pruned_source_digest),
      pruned_by_node: Map.get(rollup, :pruned_by_node)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc "Render a scheduler prune report or one prune item into a JSON-safe map."
  @spec prune_to_view(map()) :: map()
  def prune_to_view(%{prunes: prunes} = report) do
    %{
      status: report.status,
      dry_run?: report.dry_run?,
      from: iso8601(report.from),
      until: iso8601(report.until),
      window_ms: report.window_ms,
      windows: report.windows,
      candidate_runs: report.candidate_runs,
      pruned_runs: report.pruned_runs,
      prunes: Enum.map(prunes, &prune_to_view/1)
    }
  end

  def prune_to_view(%{} = prune) do
    %{
      status: Map.get(prune, :status),
      scheduler: Map.get(prune, :scheduler),
      trigger: Map.get(prune, :trigger),
      rollup_id: Map.get(prune, :rollup_id),
      window_started_at: iso8601(Map.get(prune, :window_started_at)),
      window_finished_at: iso8601(Map.get(prune, :window_finished_at)),
      window_ms: Map.get(prune, :window_ms),
      run_count: Map.get(prune, :run_count),
      pruned_run_count: Map.get(prune, :pruned_run_count),
      source_digest: Map.get(prune, :source_digest),
      pruned_at: iso8601(Map.get(prune, :pruned_at)),
      pruned_source_digest: Map.get(prune, :pruned_source_digest),
      pruned_by_node: Map.get(prune, :pruned_by_node)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc "Render a scheduler retention report into a JSON-safe map."
  @spec retention_to_view(map()) :: map()
  def retention_to_view(%{} = report) do
    %{
      status: Map.get(report, :status),
      dry_run?: Map.get(report, :dry_run?),
      enabled?: Map.get(report, :enabled?),
      ready?: Map.get(report, :ready?),
      scheduler: Map.get(report, :scheduler),
      trigger: Map.get(report, :trigger),
      retain_days: Map.get(report, :retain_days),
      now: iso8601(Map.get(report, :now)),
      retention_cutoff_at: iso8601(Map.get(report, :retention_cutoff_at)),
      cutoff: iso8601(Map.get(report, :cutoff)),
      from: iso8601(Map.get(report, :from)),
      until: iso8601(Map.get(report, :until)),
      window_ms: Map.get(report, :window_ms),
      windows: Map.get(report, :windows),
      candidate_runs: Map.get(report, :candidate_runs),
      pruned_runs: Map.get(report, :pruned_runs),
      blockers: Enum.map(Map.get(report, :blockers, []), &retention_blocker_to_view/1),
      missing_rollups:
        Enum.map(Map.get(report, :missing_rollups, []), &retention_window_to_view/1),
      prunes: Enum.map(Map.get(report, :prunes, []), &prune_to_view/1)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
    |> Map.new()
  end

  defp retention_blocker_to_view(%{} = blocker) do
    blocker
    |> Enum.map(fn {key, value} -> {key, retention_value_to_view(value)} end)
    |> Map.new()
  end

  defp retention_window_to_view(%{} = window) do
    %{
      scheduler: Map.get(window, :scheduler),
      trigger: Map.get(window, :trigger),
      window_started_at: iso8601(Map.get(window, :window_started_at)),
      window_finished_at: iso8601(Map.get(window, :window_finished_at)),
      window_ms: Map.get(window, :window_ms)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp retention_value_to_view(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp retention_value_to_view(value) when is_atom(value), do: Atom.to_string(value)

  defp retention_value_to_view(values) when is_list(values),
    do: Enum.map(values, &retention_value_to_view/1)

  defp retention_value_to_view(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> retention_value_to_view()

  defp retention_value_to_view(%{} = value), do: retention_blocker_to_view(value)
  defp retention_value_to_view(value), do: value

  @doc "Render a cadence report into a JSON-safe map for CLIs."
  @spec cadence_to_view(map()) :: map()
  def cadence_to_view(%{generated_at: generated_at, reports: reports}) do
    %{
      generated_at: iso8601(generated_at),
      reports: Enum.map(reports, &cadence_to_view/1)
    }
  end

  def cadence_to_view(report) when is_map(report) do
    %{
      scheduler: report.scheduler,
      health: report.health,
      healthy?: report.healthy?,
      reason: report.reason,
      state_status: report.state_status,
      alert_status: report.alert_status,
      backoff_until: iso8601(report.backoff_until),
      expected_interval_ms: report.expected_interval_ms,
      stale_after_ms: report.stale_after_ms,
      since: iso8601(report.since),
      scheduled_runs: report.scheduled_runs,
      effective_scheduled_runs: report.effective_scheduled_runs,
      skipped_scheduled_runs: report.skipped_scheduled_runs,
      blocked_scheduled_runs: report.blocked_scheduled_runs,
      failed_scheduled_runs: report.failed_scheduled_runs,
      last_scheduled_run_id: report.last_scheduled_run_id,
      last_scheduled_status: report.last_scheduled_status,
      last_scheduled_finished_at: iso8601(report.last_scheduled_finished_at),
      last_effective_scheduled_run_id: report.last_effective_scheduled_run_id,
      last_effective_scheduled_status: report.last_effective_scheduled_status,
      last_effective_scheduled_node: report.last_effective_scheduled_node,
      last_effective_scheduled_finished_at: iso8601(report.last_effective_scheduled_finished_at),
      last_healthy_scheduled_run_id: report.last_healthy_scheduled_run_id,
      last_healthy_scheduled_status: report.last_healthy_scheduled_status,
      last_healthy_scheduled_finished_at: iso8601(report.last_healthy_scheduled_finished_at),
      scheduled_nodes: report.scheduled_nodes,
      effective_scheduled_nodes: report.effective_scheduled_nodes,
      healthy_scheduled_nodes: report.healthy_scheduled_nodes,
      skipped_scheduled_nodes: report.skipped_scheduled_nodes,
      lock_loser_nodes: report.lock_loser_nodes,
      lock_loser_count: report.lock_loser_count,
      effective_age_ms: report.effective_age_ms
    }
  end

  @doc "Render a scheduler evidence report into a JSON-safe map for CLIs."
  @spec evidence_to_view(map()) :: map()
  def evidence_to_view(%{} = report), do: evidence_value_to_view(report)

  defp do_record(repo, scheduler, trigger, started_at, finished_at, result, opts) do
    classification = classify(result, opts)
    duration_ms = duration_ms(started_at, finished_at)

    repo.transaction(fn ->
      lock_scheduler_trigger(repo, scheduler, trigger)

      previous =
        repo.one(from(s in SchedulerState, where: s.scheduler == ^scheduler, lock: "FOR UPDATE"))

      state_attrs =
        state_attrs(previous, scheduler, classification, started_at, finished_at, opts)

      run_attrs =
        Map.merge(classification.run_attrs, %{
          scheduler: scheduler,
          trigger: trigger,
          node: node_name(opts),
          started_at: started_at,
          finished_at: finished_at,
          duration_ms: duration_ms,
          consecutive_failures_after: state_attrs.consecutive_failures,
          backoff_until: state_attrs.backoff_until,
          alert_status: state_attrs.alert_status
        })

      with :ok <- ensure_run_window_not_pruned(repo, scheduler, trigger, finished_at),
           {:ok, run} <- repo.insert(SchedulerRun.changeset(%SchedulerRun{}, run_attrs)),
           {:ok, state} <-
             upsert_state(repo, previous, put_effective_last_run_id(state_attrs, run.id)) do
        %{run: run, state: state, previous_state: previous}
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %{run: run, state: state, previous_state: previous}} ->
        maybe_emit_alert(repo, run, state, previous, opts)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, {:scheduler_ledger_record_failed, Exception.message(error)}}
  end

  defp upsert_state(repo, nil, attrs) do
    repo.insert(SchedulerState.changeset(%SchedulerState{}, attrs))
  end

  defp upsert_state(repo, %SchedulerState{} = state, attrs) do
    repo.update(SchedulerState.changeset(state, attrs))
  end

  defp put_effective_last_run_id(attrs, run_id) do
    Map.put_new(attrs, :last_run_id, run_id)
  end

  defp state_attrs(previous, scheduler, classification, started_at, finished_at, opts) do
    preserve_state? = Map.get(classification, :preserve_state?, false)

    if preserve_state? and match?(%SchedulerState{}, previous) do
      preserved_state_attrs(previous)
    else
      effective_state_attrs(previous, scheduler, classification, started_at, finished_at, opts)
    end
  end

  defp preserved_state_attrs(%SchedulerState{} = previous) do
    %{
      scheduler: previous.scheduler,
      node: previous.node,
      status: previous.status,
      consecutive_failures: previous.consecutive_failures,
      last_started_at: previous.last_started_at,
      last_finished_at: previous.last_finished_at,
      backoff_until: previous.backoff_until,
      alert_status: previous.alert_status,
      alerted_at: previous.alerted_at,
      last_error_reason: previous.last_error_reason,
      last_summary: previous.last_summary,
      last_run_id: previous.last_run_id
    }
  end

  defp effective_state_attrs(previous, scheduler, classification, started_at, finished_at, opts) do
    preserve_state? = Map.get(classification, :preserve_state?, false)
    failure? = classification.status in ["blocked", "failed"]
    previous_failures = if previous, do: previous.consecutive_failures, else: 0
    consecutive = consecutive_failures_after(preserve_state?, failure?, previous_failures)
    threshold = positive_int(Keyword.get(opts, :failure_threshold), @default_failure_threshold)
    backoff_ms = non_negative_int(Keyword.get(opts, :backoff_ms), @default_backoff_ms)
    alert? = failure? and consecutive >= threshold
    alert_status = alert_status(previous, preserve_state?, failure?, alert?)
    backoff_until = backoff_until(previous, preserve_state?, alert?, finished_at, backoff_ms)
    alerted_at = alerted_at(previous, preserve_state?, alert?, finished_at)

    %{
      scheduler: scheduler,
      node: node_name(opts),
      status: classification.status,
      consecutive_failures: consecutive,
      last_started_at: started_at,
      last_finished_at: finished_at,
      backoff_until: backoff_until,
      alert_status: alert_status,
      alerted_at: alerted_at,
      last_error_reason: classification.run_attrs.error_reason,
      last_summary: classification.run_attrs.summary
    }
  end

  defp consecutive_failures_after(true, _failure?, previous_failures), do: previous_failures
  defp consecutive_failures_after(false, true, previous_failures), do: previous_failures + 1
  defp consecutive_failures_after(false, false, _previous_failures), do: 0

  defp backoff_until(
         %SchedulerState{backoff_until: backoff_until},
         true,
         _alert?,
         _finished_at,
         _ms
       ),
       do: backoff_until

  defp backoff_until(nil, true, _alert?, _finished_at, _ms), do: nil

  defp backoff_until(_previous, false, true, finished_at, backoff_ms) when backoff_ms > 0,
    do: DateTime.add(finished_at, backoff_ms, :millisecond)

  defp backoff_until(_previous, _preserve_state?, _alert?, _finished_at, _backoff_ms), do: nil

  defp alerted_at(%SchedulerState{alerted_at: alerted_at}, true, _alert?, _finished_at),
    do: alerted_at

  defp alerted_at(nil, true, _alert?, _finished_at), do: nil

  defp alerted_at(
         %SchedulerState{alert_status: "alert", alerted_at: alerted_at},
         false,
         true,
         _finished_at
       ),
       do: alerted_at

  defp alerted_at(_previous, false, true, finished_at), do: finished_at
  defp alerted_at(_previous, false, false, _finished_at), do: nil

  defp alert_status(%SchedulerState{alert_status: status}, true, _failure?, _alert?), do: status
  defp alert_status(nil, true, _failure?, _alert?), do: "ok"
  defp alert_status(_previous, false, _failure?, true), do: "alert"
  defp alert_status(_previous, false, true, false), do: "warning"
  defp alert_status(_previous, false, false, false), do: "ok"

  defp classify({:ok, report}, opts) when is_map(report) do
    status = ok_status(report)
    summary = encode_summary(summary_for(report), opts)

    %{
      status: status,
      preserve_state?: false,
      run_attrs: %{
        status: status,
        result_kind: "ok",
        phase: phase(report),
        job_id: job_id(report),
        summary: summary,
        error_reason: error_reason(status, report)
      }
    }
  end

  defp classify({:ok, report}, opts) do
    summary = encode_summary(%{result: inspect(report)}, opts)

    %{
      status: "ok",
      preserve_state?: false,
      run_attrs: %{
        status: "ok",
        result_kind: "ok",
        phase: nil,
        job_id: nil,
        summary: summary,
        error_reason: nil
      }
    }
  end

  defp classify({:error, reason}, opts) do
    status = error_status(reason)
    summary = encode_summary(%{error: reason}, opts)

    %{
      status: status,
      preserve_state?: preserve_state_skip?(reason),
      run_attrs: %{
        status: status,
        result_kind: "error",
        phase: nil,
        job_id: job_id_from_reason(reason),
        summary: summary,
        error_reason: reason_summary(reason)
      }
    }
  end

  defp classify(other, opts) do
    classify({:error, {:bad_scheduler_result, other}}, opts)
  end

  defp preserve_state_skip?(reason) when reason in @neutral_skip_errors, do: true
  defp preserve_state_skip?({:backoff_active, _until}), do: true
  defp preserve_state_skip?(_reason), do: false

  defp ok_status(report) do
    cond do
      nested_status(report, :rebalance_advance) in [:failed, "failed"] ->
        "failed"

      nested_status(report, :rebalance_enqueue) in [:failed, "failed"] ->
        "blocked"

      nested_status(report, :rebalance_advance) in [:blocked, "blocked"] ->
        "blocked"

      report_status(report) in [:failed, "failed"] ->
        "failed"

      report_status(report) in [:blocked, "blocked"] ->
        "blocked"

      blockers(report) != [] ->
        "blocked"

      report_status(report) in [:not_needed, "not_needed"] ->
        "idle"

      report_status(report) in [:skipped, "skipped", :not_eligible, "not_eligible"] ->
        "skipped"

      true ->
        "ok"
    end
  end

  defp error_status(reason) when reason in @idle_errors, do: "idle"
  defp error_status(reason) when reason in @skipped_errors, do: "skipped"
  defp error_status({:backoff_active, _until}), do: "skipped"
  defp error_status({:active_job_exists, _job}), do: "blocked"
  defp error_status({:preflight_blocked, _details}), do: "blocked"
  defp error_status({:deployment_persistence_blocked, _details}), do: "blocked"
  defp error_status({:unsupported_rebalance_drain_job, _details}), do: "blocked"
  defp error_status({:job_not_runnable, _id, _status, _movement, _cleanup}), do: "skipped"
  defp error_status(_reason), do: "failed"

  defp summary_for(report) do
    report
    |> Map.take(@summary_keys)
    |> Map.put_new(:status, report_status(report))
  end

  defp phase(report) do
    case Map.get(report, :phase) do
      nil -> nil
      phase -> to_string(phase)
    end
  end

  defp job_id(report) do
    cond do
      is_binary(Map.get(report, :job_id)) ->
        Map.get(report, :job_id)

      is_binary(get_in(report, [:rebalance_enqueue, :job_id])) ->
        get_in(report, [:rebalance_enqueue, :job_id])

      is_binary(get_in(report, [:rebalance_advance, :job_id])) ->
        get_in(report, [:rebalance_advance, :job_id])

      true ->
        nil
    end
  end

  defp job_id_from_reason({:active_job_exists, %{id: id}}) when is_binary(id), do: id
  defp job_id_from_reason({:active_job_exists, %{job_id: id}}) when is_binary(id), do: id
  defp job_id_from_reason(_reason), do: nil

  defp error_reason("ok", _report), do: nil
  defp error_reason("idle", _report), do: nil

  defp error_reason(_status, report) do
    cond do
      reason = Map.get(report, :reason) -> reason_summary(reason)
      blockers(report) != [] -> reason_summary(blockers(report))
      true -> nil
    end
  end

  defp reason_summary(reason) do
    reason
    |> json_ready()
    |> inspect(limit: 20, printable_limit: 200)
    |> truncate_reason()
  end

  defp truncate_reason(text) do
    if String.length(text) > @max_error_reason_chars do
      text
      |> String.slice(0, @max_error_reason_chars)
      |> Kernel.<>("...")
    else
      text
    end
  end

  defp nested_status(report, key) do
    case Map.get(report, key) do
      %{status: status} -> status
      _other -> nil
    end
  end

  defp report_status(report), do: Map.get(report, :status)

  defp blockers(report) do
    case Map.get(report, :blockers) do
      values when is_list(values) -> values
      _other -> []
    end
  end

  defp encode_summary(summary, opts) do
    max_bytes = positive_int(Keyword.get(opts, :max_summary_bytes), @default_max_summary_bytes)
    normalized = json_ready(summary)

    case Jason.encode(normalized) do
      {:ok, encoded} when byte_size(encoded) <= max_bytes ->
        normalized

      {:ok, encoded} ->
        %{
          "truncated" => true,
          "encoded_bytes" => byte_size(encoded),
          "max_summary_bytes" => max_bytes,
          "status" => Map.get(normalized, "status"),
          "phase" => Map.get(normalized, "phase"),
          "job_id" => Map.get(normalized, "job_id")
        }

      {:error, reason} ->
        %{"summary_error" => inspect(reason)}
    end
  end

  defp maybe_emit_alert(repo, run, state, previous, opts) do
    alert_transition? =
      state.alert_status == "alert" and
        (is_nil(previous) or previous.alert_status != "alert")

    if alert_transition? do
      case call_alert_sink(Keyword.get(opts, :alert_sink), run, state) do
        :ok ->
          {:ok, %{run: run, state: state}}

        {:error, reason} ->
          {:ok, run} = record_alert_emit_error(repo, run, reason)
          {:ok, %{run: run, state: state}}
      end
    else
      {:ok, %{run: run, state: state}}
    end
  end

  defp call_alert_sink(nil, _run, _state), do: :ok

  defp call_alert_sink(fun, run, state) when is_function(fun, 2) do
    case fun.(run, state) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_alert_sink_result, other}}
    end
  rescue
    error -> {:error, {:crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:caught, kind, reason}}
  end

  defp call_alert_sink(_sink, _run, _state), do: :ok

  defp record_alert_emit_error(repo, run, reason) do
    summary =
      run.summary
      |> Map.put("alert_emit_error", reason_summary(reason))

    repo.update(SchedulerRun.changeset(run, %{summary: summary}))
  rescue
    error ->
      Log.warn("scheduler alert sink failed and ledger update failed",
        action: :scheduler_ledger,
        reason: Exception.message(error)
      )

      {:ok, run}
  end

  defp ensure_run_window_not_pruned(repo, scheduler, trigger, %DateTime{} = finished_at) do
    rollups =
      SchedulerRunRollup
      |> where(
        [r],
        r.scheduler == ^scheduler and r.trigger == ^trigger and
          r.window_started_at <= ^finished_at and r.window_finished_at > ^finished_at
      )
      |> lock("FOR UPDATE")
      |> repo.all()

    case Enum.find(rollups, &match?(%DateTime{}, &1.pruned_at)) do
      nil ->
        :ok

      %SchedulerRunRollup{} = rollup ->
        {:error,
         {:scheduler_run_window_pruned, rollup.id, scheduler, trigger, rollup.window_started_at,
          rollup.window_ms}}
    end
  end

  defp lock_scheduler_trigger(repo, scheduler, trigger) do
    Ecto.Adapters.SQL.query!(
      repo,
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      ["maxio.scheduler_runs", "#{scheduler}:#{trigger}"]
    )

    :ok
  end

  defp upsert_rollup_locked(repo, attrs) do
    existing =
      repo.one(
        from(r in SchedulerRunRollup,
          where:
            r.scheduler == ^attrs.scheduler and r.trigger == ^attrs.trigger and
              r.window_started_at == ^attrs.window_started_at and
              r.window_ms == ^attrs.window_ms,
          lock: "FOR UPDATE"
        )
      )

    case existing do
      nil ->
        repo.insert(SchedulerRunRollup.changeset(%SchedulerRunRollup{}, attrs))

      %SchedulerRunRollup{pruned_at: %DateTime{}} = rollup ->
        {:error, {:rollup_window_already_pruned, rollup.id}}

      rollup ->
        repo.update(SchedulerRunRollup.changeset(rollup, attrs))
    end
  end

  defp prune_report(mode, from, until, window_ms, windows, results) do
    candidate_runs = Enum.reduce(results, 0, &(&1.pruned_run_count + &2))

    pruned_runs =
      Enum.reduce(results, 0, fn
        %{status: :pruned, pruned_run_count: count}, acc -> acc + count
        _result, acc -> acc
      end)

    {:ok,
     %{
       status: if(mode == :preflight, do: :preflight, else: :ok),
       dry_run?: mode == :preflight,
       from: from,
       until: until,
       window_ms: window_ms,
       windows: length(windows),
       candidate_runs: candidate_runs,
       pruned_runs: pruned_runs,
       prunes: results
     }}
  end

  defp retention_verify_or_prune(
         repo,
         scheduler,
         trigger,
         retain_days,
         range,
         window_ms,
         mode,
         opts
       ) do
    case range.window_starts do
      [] ->
        {:ok,
         retention_report(mode, scheduler, trigger, retain_days, range, window_ms, opts,
           status: if(mode == :preflight, do: :preflight, else: :ok),
           ready?: true,
           candidate_runs: 0,
           pruned_runs: 0,
           prunes: []
         )}

      window_starts ->
        missing_rollups =
          missing_retention_rollups(repo, scheduler, trigger, window_starts, window_ms)

        cond do
          missing_rollups != [] and mode == :preflight ->
            {:ok,
             retention_report(mode, scheduler, trigger, retain_days, range, window_ms, opts,
               status: :blocked,
               ready?: false,
               candidate_runs:
                 count_retention_candidate_runs(repo, scheduler, trigger, range.from, range.until),
               missing_rollups: missing_rollups,
               blockers: [%{reason: :missing_rollups, count: length(missing_rollups)}]
             )}

          missing_rollups != [] ->
            {:error, {:missing_retention_rollups, missing_rollups}}

          true ->
            prune_opts =
              opts
              |> Keyword.put(:repo, repo)
              |> Keyword.put(:scheduler, scheduler)
              |> Keyword.put(:trigger, trigger)
              |> Keyword.put(:from, range.from)
              |> Keyword.put(:until, range.until)
              |> Keyword.put(:window_ms, window_ms)
              |> Keyword.put(:now, range.now)
              |> Keyword.put(:pruned_at, range.now)

            result =
              if mode == :preflight do
                prune_preflight(prune_opts)
              else
                prune(Keyword.put(prune_opts, :confirm?, true))
              end

            retention_prune_result(
              result,
              mode,
              scheduler,
              trigger,
              retain_days,
              range,
              window_ms,
              Keyword.put(opts, :repo, repo)
            )
        end
    end
  end

  defp retention_prune_result(
         {:ok, prune_report},
         mode,
         scheduler,
         trigger,
         retain_days,
         range,
         window_ms,
         opts
       ) do
    {:ok,
     retention_report(mode, scheduler, trigger, retain_days, range, window_ms, opts,
       status: if(mode == :preflight, do: :preflight, else: :ok),
       ready?: true,
       candidate_runs: prune_report.candidate_runs,
       pruned_runs: prune_report.pruned_runs,
       prunes: prune_report.prunes
     )}
  end

  defp retention_prune_result(
         {:error, reason},
         :preflight,
         scheduler,
         trigger,
         retain_days,
         range,
         window_ms,
         opts
       ) do
    {:ok,
     retention_report(:preflight, scheduler, trigger, retain_days, range, window_ms, opts,
       status: :blocked,
       ready?: false,
       candidate_runs:
         count_retention_candidate_runs(
           Keyword.fetch!(opts, :repo),
           scheduler,
           trigger,
           range.from,
           range.until
         ),
       blockers: [%{reason: reason}]
     )}
  end

  defp retention_prune_result(
         {:error, reason},
         :prune,
         _scheduler,
         _trigger,
         _retain_days,
         _range,
         _window_ms,
         _opts
       ),
       do: {:error, reason}

  defp retention_report(mode, scheduler, trigger, retain_days, range, window_ms, opts, extra) do
    %{
      status: Keyword.fetch!(extra, :status),
      dry_run?: mode == :preflight,
      enabled?: retention_enabled?(opts),
      ready?: Keyword.get(extra, :ready?, false),
      scheduler: scheduler,
      trigger: trigger,
      retain_days: retain_days,
      now: range.now,
      retention_cutoff_at: range.retention_cutoff_at,
      cutoff: range.until,
      from: range.from,
      until: range.until,
      window_ms: window_ms,
      windows: length(range.window_starts),
      candidate_runs: Keyword.get(extra, :candidate_runs, 0),
      pruned_runs: Keyword.get(extra, :pruned_runs, 0),
      blockers: Keyword.get(extra, :blockers, []),
      missing_rollups: Keyword.get(extra, :missing_rollups, []),
      prunes: Keyword.get(extra, :prunes, [])
    }
  end

  defp do_prune_window(
         repo,
         scheduler,
         trigger,
         window_started_at,
         window_finished_at,
         window_ms,
         opts
       ) do
    mode = Keyword.fetch!(opts, :mode)

    rollup =
      repo.one(
        from(r in SchedulerRunRollup,
          where:
            r.scheduler == ^scheduler and r.trigger == ^trigger and
              r.window_started_at == ^window_started_at and
              r.window_ms == ^window_ms,
          lock: "FOR UPDATE"
        )
      )

    if is_nil(rollup) do
      repo.rollback({:missing_rollup, scheduler, trigger, window_started_at, window_ms})
    end

    runs = run_rows_for_window(repo, scheduler, trigger, window_started_at, window_finished_at)

    cond do
      already_pruned?(rollup, runs) ->
        prune_result(rollup, :already_pruned, 0)

      rollup.pruned_at ->
        repo.rollback({:pruned_window_has_late_runs, rollup.id, length(runs)})

      true ->
        current_attrs =
          rollup_attrs(
            scheduler,
            trigger,
            window_started_at,
            window_finished_at,
            window_ms,
            runs,
            opts
          )

        with :ok <- verify_rollup_before_prune(rollup, current_attrs),
             :ok <- verify_prune_protected_runs(repo, runs) do
          case {mode, length(runs)} do
            {_mode, 0} ->
              prune_result(rollup, :empty, 0)

            {:preflight, count} ->
              prune_result(rollup, :preflight, count)

            {:prune, count} ->
              prune_run_ids(repo, Enum.map(runs, & &1.id))

              {:ok, updated} =
                repo.update(
                  SchedulerRunRollup.changeset(rollup, %{
                    pruned_at: Keyword.get_lazy(opts, :pruned_at, &now/0),
                    pruned_run_count: count,
                    pruned_source_digest: rollup.source_digest,
                    pruned_by_node: node_name(opts)
                  })
                )

              prune_result(updated, :pruned, count)
          end
        else
          {:error, reason} -> repo.rollback(reason)
        end
    end
  end

  defp already_pruned?(%SchedulerRunRollup{pruned_at: %DateTime{}}, []), do: true
  defp already_pruned?(_rollup, _runs), do: false

  defp retention_range(repo, scheduler, trigger, now, retain_days, window_ms, opts) do
    retention_cutoff_at =
      DateTime.add(now, -retain_days * 24 * 60 * 60 * 1_000, :millisecond)

    until = current_window_started_at(retention_cutoff_at, window_ms)

    base = %{
      now: now,
      retention_cutoff_at: retention_cutoff_at,
      from: until,
      until: until,
      window_starts: []
    }

    case earliest_retention_finished_at(repo, scheduler, trigger, until) do
      nil ->
        {:ok, base}

      %DateTime{} = first_finished_at ->
        from = current_window_started_at(first_finished_at, window_ms)

        with :ok <-
               validate_prune_window_range(from, until, window_ms, Keyword.put(opts, :now, now)),
             :ok <- validate_retention_window_count(from, until, window_ms, opts) do
          {:ok, %{base | from: from, window_starts: rollup_window_starts(from, until, window_ms)}}
        end
    end
  end

  defp earliest_retention_finished_at(repo, scheduler, trigger, until) do
    SchedulerRun
    |> where(
      [r],
      r.scheduler == ^scheduler and r.trigger == ^trigger and r.finished_at < ^until
    )
    |> order_by([r], asc: r.finished_at)
    |> limit(1)
    |> select([r], r.finished_at)
    |> repo.one()
  end

  defp validate_retention_window_count(from, until, window_ms, opts) do
    max_windows = positive_int(Keyword.get(opts, :max_windows), @default_retention_max_windows)
    count = div(DateTime.diff(until, from, :millisecond), window_ms)

    if count <= max_windows do
      :ok
    else
      {:error, {:retention_window_limit_exceeded, count, max_windows}}
    end
  end

  defp missing_retention_rollups(repo, scheduler, trigger, window_starts, window_ms) do
    existing =
      SchedulerRunRollup
      |> where(
        [r],
        r.scheduler == ^scheduler and r.trigger == ^trigger and r.window_ms == ^window_ms and
          r.window_started_at in ^window_starts
      )
      |> select([r], r.window_started_at)
      |> repo.all()
      |> Enum.map(&DateTime.to_unix(&1, :microsecond))
      |> MapSet.new()

    window_starts
    |> Enum.reject(&MapSet.member?(existing, DateTime.to_unix(&1, :microsecond)))
    |> Enum.map(fn window_started_at ->
      %{
        scheduler: scheduler,
        trigger: trigger,
        window_started_at: window_started_at,
        window_finished_at: DateTime.add(window_started_at, window_ms, :millisecond),
        window_ms: window_ms
      }
    end)
  end

  defp count_retention_candidate_runs(repo, scheduler, trigger, from, until) do
    SchedulerRun
    |> where(
      [r],
      r.scheduler == ^scheduler and r.trigger == ^trigger and
        r.finished_at >= ^from and r.finished_at < ^until
    )
    |> select([r], count(r.id))
    |> repo.one()
  end

  defp run_rows_for_window(repo, scheduler, trigger, window_started_at, window_finished_at) do
    SchedulerRun
    |> where(
      [r],
      r.scheduler == ^scheduler and r.trigger == ^trigger and
        r.finished_at >= ^window_started_at and r.finished_at < ^window_finished_at
    )
    |> order_by([r], asc: r.finished_at, asc: r.started_at, asc: r.id)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  defp rollup_rows_for_window(repo, scheduler, trigger, window_started_at, window_finished_at) do
    SchedulerRun
    |> where(
      [r],
      r.scheduler == ^scheduler and r.trigger == ^trigger and
        r.finished_at >= ^window_started_at and r.finished_at < ^window_finished_at
    )
    |> order_by([r], asc: r.finished_at, asc: r.started_at, asc: r.id)
    |> repo.all()
  end

  defp verify_rollup_before_prune(%SchedulerRunRollup{} = rollup, current_attrs) do
    cond do
      rollup.rollup_version != @rollup_version ->
        {:error, {:unsupported_rollup_version, rollup.id, rollup.rollup_version}}

      rollup.run_count != current_attrs.run_count ->
        {:error,
         {:rollup_run_count_mismatch, rollup.id, rollup.run_count, current_attrs.run_count}}

      rollup.source_digest != current_attrs.source_digest ->
        {:error, {:rollup_source_digest_mismatch, rollup.id}}

      not same_datetime?(rollup.source_max_updated_at, current_attrs.source_max_updated_at) ->
        {:error, {:rollup_source_updated_at_mismatch, rollup.id}}

      true ->
        :ok
    end
  end

  defp verify_prune_protected_runs(repo, runs) do
    run_ids = MapSet.new(Enum.map(runs, & &1.id))

    protected =
      repo
      |> protected_run_ids()
      |> MapSet.intersection(run_ids)
      |> MapSet.to_list()

    case protected do
      [] -> :ok
      ids -> {:error, {:protected_scheduler_run, ids}}
    end
  end

  defp protected_run_ids(repo) do
    state_ids =
      SchedulerState
      |> where([s], not is_nil(s.last_run_id))
      |> select([s], s.last_run_id)
      |> repo.all()

    latest_trigger_ids =
      for scheduler <- @schedulers,
          trigger <- @triggers do
        latest_run_id(repo, scheduler, trigger)
      end

    latest_cadence_ids =
      for scheduler <- @schedulers,
          fun <- [
            &latest_scheduled_run_id/2,
            &latest_effective_scheduled_run_id/2,
            &latest_healthy_scheduled_run_id/2
          ] do
        fun.(repo, scheduler)
      end

    state_ids
    |> Kernel.++(latest_trigger_ids)
    |> Kernel.++(latest_cadence_ids)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp latest_run_id(repo, scheduler, trigger) do
    SchedulerRun
    |> where([r], r.scheduler == ^scheduler and r.trigger == ^trigger)
    |> latest_run_first()
    |> limit(1)
    |> select([r], r.id)
    |> repo.one()
  end

  defp latest_scheduled_run_id(repo, scheduler) do
    SchedulerRun
    |> where([r], r.scheduler == ^scheduler and r.trigger == "scheduled")
    |> latest_run_first()
    |> limit(1)
    |> select([r], r.id)
    |> repo.one()
  end

  defp latest_effective_scheduled_run_id(repo, scheduler) do
    SchedulerRun
    |> where(
      [r],
      r.scheduler == ^scheduler and r.trigger == "scheduled" and
        r.status not in ^@non_effective_scheduled_statuses
    )
    |> latest_run_first()
    |> limit(1)
    |> select([r], r.id)
    |> repo.one()
  end

  defp latest_healthy_scheduled_run_id(repo, scheduler) do
    SchedulerRun
    |> where(
      [r],
      r.scheduler == ^scheduler and r.trigger == "scheduled" and
        r.status in ^@healthy_scheduled_statuses
    )
    |> latest_run_first()
    |> limit(1)
    |> select([r], r.id)
    |> repo.one()
  end

  defp prune_run_ids(_repo, []), do: :ok

  defp prune_run_ids(repo, ids) do
    {count, _rows} =
      SchedulerRun
      |> where([r], r.id in ^ids)
      |> repo.delete_all()

    if count == length(ids) do
      :ok
    else
      repo.rollback({:scheduler_prune_delete_count_mismatch, length(ids), count})
    end
  end

  defp prune_result(%SchedulerRunRollup{} = rollup, status, pruned_run_count) do
    %{
      status: status,
      scheduler: rollup.scheduler,
      trigger: rollup.trigger,
      rollup_id: rollup.id,
      window_started_at: rollup.window_started_at,
      window_finished_at: rollup.window_finished_at,
      window_ms: rollup.window_ms,
      run_count: rollup.run_count,
      pruned_run_count: pruned_run_count,
      source_digest: rollup.source_digest,
      pruned_at: rollup.pruned_at,
      pruned_source_digest: rollup.pruned_source_digest,
      pruned_by_node: rollup.pruned_by_node
    }
  end

  defp same_datetime?(nil, nil), do: true

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp latest_run_first(query) do
    order_by(query, [r],
      desc: r.finished_at,
      desc: r.started_at,
      desc: r.inserted_at,
      desc: r.id
    )
  end

  defp prune_windows(schedulers, triggers, windows, window_ms, opts) do
    Enum.reduce_while(schedulers, {:ok, []}, fn scheduler, {:ok, acc} ->
      case prune_triggers_for_scheduler(scheduler, triggers, windows, window_ms, opts) do
        {:ok, results} -> {:cont, {:ok, acc ++ results}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp prune_triggers_for_scheduler(scheduler, triggers, windows, window_ms, opts) do
    Enum.reduce_while(triggers, {:ok, []}, fn trigger, {:ok, acc} ->
      case prune_windows_for_trigger(scheduler, trigger, windows, window_ms, opts) do
        {:ok, results} -> {:cont, {:ok, acc ++ results}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp prune_windows_for_trigger(scheduler, trigger, windows, window_ms, opts) do
    Enum.reduce_while(windows, {:ok, []}, fn window_started_at, {:ok, acc} ->
      window_finished_at = DateTime.add(window_started_at, window_ms, :millisecond)

      case do_prune_window(
             Keyword.fetch!(opts, :repo),
             scheduler,
             trigger,
             window_started_at,
             window_finished_at,
             window_ms,
             opts
           ) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        result when is_map(result) -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp rollup_windows(schedulers, triggers, windows, window_ms, opts) do
    Enum.reduce_while(schedulers, {:ok, []}, fn scheduler, {:ok, acc} ->
      case rollup_triggers_for_scheduler(scheduler, triggers, windows, window_ms, opts) do
        {:ok, results} -> {:cont, {:ok, acc ++ results}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rollup_triggers_for_scheduler(scheduler, triggers, windows, window_ms, opts) do
    Enum.reduce_while(triggers, {:ok, []}, fn trigger, {:ok, acc} ->
      case rollup_windows_for_trigger(scheduler, trigger, windows, window_ms, opts) do
        {:ok, results} -> {:cont, {:ok, acc ++ results}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rollup_windows_for_trigger(scheduler, trigger, windows, window_ms, opts) do
    Enum.reduce_while(windows, {:ok, []}, fn window_started_at, {:ok, acc} ->
      case rollup_window(scheduler, trigger, window_started_at, window_ms, opts) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp rollup_attrs(
         scheduler,
         trigger,
         window_started_at,
         window_finished_at,
         window_ms,
         runs,
         opts
       ) do
    first = List.first(runs)
    last = List.last(runs)
    last_effective = last_matching(runs, &(&1.status not in @non_effective_scheduled_statuses))
    last_healthy = last_matching(runs, &(&1.status in @healthy_scheduled_statuses))
    last_error = last_matching(runs, &present?(&1.error_reason))
    durations = Enum.map(runs, & &1.duration_ms)

    %{
      scheduler: scheduler,
      trigger: trigger,
      window_started_at: window_started_at,
      window_finished_at: window_finished_at,
      window_ms: window_ms,
      run_count: length(runs),
      ok_count: count_status(runs, "ok"),
      idle_count: count_status(runs, "idle"),
      skipped_count: count_status(runs, "skipped"),
      blocked_count: count_status(runs, "blocked"),
      failed_count: count_status(runs, "failed"),
      effective_count: Enum.count(runs, &(&1.status not in @non_effective_scheduled_statuses)),
      healthy_count: Enum.count(runs, &(&1.status in @healthy_scheduled_statuses)),
      result_ok_count: Enum.count(runs, &(&1.result_kind == "ok")),
      result_error_count: Enum.count(runs, &(&1.result_kind == "error")),
      duration_total_ms: Enum.sum(durations),
      duration_min_ms: min_or_nil(durations),
      duration_max_ms: max_or_nil(durations),
      first_run_id: first && first.id,
      last_run_id: last && last.id,
      last_status: last && last.status,
      last_result_kind: last && last.result_kind,
      last_phase: last && last.phase,
      last_job_id: last && last.job_id,
      last_finished_at: last && last.finished_at,
      last_effective_run_id: last_effective && last_effective.id,
      last_effective_status: last_effective && last_effective.status,
      last_effective_finished_at: last_effective && last_effective.finished_at,
      last_healthy_run_id: last_healthy && last_healthy.id,
      last_healthy_status: last_healthy && last_healthy.status,
      last_healthy_finished_at: last_healthy && last_healthy.finished_at,
      last_error_reason: last_error && last_error.error_reason,
      last_summary: last_summary(last, opts),
      source_max_updated_at: max_datetime(Enum.map(runs, & &1.updated_at)),
      source_digest: source_digest(runs),
      rolled_up_at: Keyword.get_lazy(opts, :rolled_up_at, &now/0),
      rollup_version: @rollup_version
    }
  end

  defp last_matching(runs, fun), do: runs |> Enum.reverse() |> Enum.find(fun)

  defp count_status(runs, status), do: Enum.count(runs, &(&1.status == status))

  defp min_or_nil([]), do: nil
  defp min_or_nil(values), do: Enum.min(values)

  defp max_or_nil([]), do: nil
  defp max_or_nil(values), do: Enum.max(values)

  defp max_datetime([]), do: nil
  defp max_datetime(values), do: Enum.max_by(values, &DateTime.to_unix(&1, :microsecond))

  defp present?(value), do: value not in [nil, ""]

  defp last_summary(nil, _opts), do: %{}

  defp last_summary(%SchedulerRun{summary: summary}, opts) when is_map(summary),
    do: encode_summary(summary, opts)

  defp last_summary(_run, _opts), do: %{}

  defp source_digest(runs) do
    rows =
      Enum.map(runs, fn run ->
        [
          run.id,
          iso8601(run.updated_at),
          run.scheduler,
          run.trigger,
          run.status,
          run.result_kind,
          run.phase,
          run.job_id,
          iso8601(run.started_at),
          iso8601(run.finished_at),
          run.duration_ms,
          run.consecutive_failures_after,
          iso8601(run.backoff_until),
          run.alert_status,
          run.error_reason,
          run.summary
        ]
      end)

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(rows))
    |> Base.encode16(case: :lower)
  end

  defp required_prune_scheduler(opts) do
    opts
    |> Keyword.fetch!(:scheduler)
    |> scheduler_name()
  end

  defp required_prune_trigger(opts) do
    opts
    |> Keyword.fetch!(:trigger)
    |> trigger_name()
  end

  defp required_retention_scheduler(opts) do
    opts
    |> Keyword.fetch!(:scheduler)
    |> scheduler_name()
  end

  defp required_retention_trigger(opts) do
    opts
    |> Keyword.fetch!(:trigger)
    |> trigger_name()
  end

  defp validate_retention_now(%DateTime{}), do: :ok
  defp validate_retention_now(value), do: {:error, {:invalid_retention_now, value}}

  defp validate_retention_days(value) when is_integer(value) and value > 0, do: :ok
  defp validate_retention_days(value), do: {:error, {:invalid_retention_days, value}}

  defp validate_retention_window_ms(value) when is_integer(value) and value > 0, do: :ok
  defp validate_retention_window_ms(value), do: {:error, {:invalid_retention_window_ms, value}}

  defp validate_prune_window_range(%DateTime{} = from, %DateTime{} = until, window_ms, opts) do
    with :ok <- validate_window_range(from, until, window_ms, opts) do
      now = Keyword.get_lazy(opts, :now, &now/0)
      validate_closed_prune_window(until, now, window_ms)
    end
  end

  defp validate_prune_window_range(from, until, window_ms, opts),
    do: validate_window_range(from, until, window_ms, opts)

  defp validate_window_range(%DateTime{} = from, %DateTime{} = until, window_ms, opts) do
    now = Keyword.get_lazy(opts, :now, &now/0)

    cond do
      not (is_integer(window_ms) and window_ms > 0) ->
        {:error, {:invalid_rollup_range, :invalid_window_ms}}

      DateTime.compare(from, until) != :lt ->
        {:error, {:invalid_rollup_range, :from_must_be_before_until}}

      not aligned?(from, window_ms) ->
        {:error, {:invalid_rollup_range, :from_not_aligned}}

      not aligned?(until, window_ms) ->
        {:error, {:invalid_rollup_range, :until_not_aligned}}

      DateTime.compare(until, now) == :gt ->
        {:error, {:open_rollup_window, until}}

      true ->
        :ok
    end
  end

  defp validate_window_range(_from, _until, _window_ms, _opts),
    do: {:error, {:invalid_rollup_range, :datetime_required}}

  defp validate_aligned_window(%DateTime{} = window_started_at, window_ms) do
    cond do
      not (is_integer(window_ms) and window_ms > 0) ->
        {:error, {:invalid_rollup_window_ms, window_ms}}

      aligned?(window_started_at, window_ms) ->
        :ok

      true ->
        {:error, {:unaligned_rollup_window, window_started_at, window_ms}}
    end
  end

  defp validate_closed_window(%DateTime{} = window_finished_at, %DateTime{} = now) do
    if DateTime.compare(window_finished_at, now) == :gt do
      {:error, {:open_rollup_window, window_finished_at}}
    else
      :ok
    end
  end

  defp validate_closed_prune_window(
         %DateTime{} = window_finished_at,
         %DateTime{} = now,
         window_ms
       ) do
    current_started_at = current_window_started_at(now, window_ms)

    if DateTime.compare(window_finished_at, current_started_at) == :gt do
      {:error, {:open_prune_window, window_finished_at, current_started_at}}
    else
      :ok
    end
  end

  defp validate_trigger(trigger) when trigger in @triggers, do: :ok
  defp validate_trigger(trigger), do: {:error, {:invalid_trigger, trigger}}

  defp validate_rollup_scheduler_selection(schedulers) do
    Enum.reduce_while(schedulers, :ok, fn scheduler, :ok ->
      case validate_rollup_scheduler(scheduler) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_rollup_scheduler(scheduler) when scheduler in @schedulers, do: :ok
  defp validate_rollup_scheduler(scheduler), do: {:error, {:invalid_scheduler, scheduler}}

  defp aligned?(%DateTime{} = time, window_ms) do
    rem(DateTime.to_unix(time, :microsecond), window_ms * 1_000) == 0
  end

  defp current_window_started_at(%DateTime{} = now, window_ms) do
    window_us = window_ms * 1_000
    started_us = div(DateTime.to_unix(now, :microsecond), window_us) * window_us
    DateTime.from_unix!(started_us, :microsecond)
  end

  defp rollup_window_starts(from, until, window_ms) do
    from_ms = DateTime.to_unix(from, :millisecond)
    until_ms = DateTime.to_unix(until, :millisecond)

    from_ms
    |> Stream.iterate(&(&1 + window_ms))
    |> Enum.take_while(&(&1 < until_ms))
    |> Enum.map(&DateTime.from_unix!(&1, :millisecond))
  end

  defp rollup_schedulers(nil), do: @schedulers
  defp rollup_schedulers(scheduler), do: [scheduler_name(scheduler)]

  defp rollup_triggers(nil), do: @triggers
  defp rollup_triggers(trigger), do: [trigger_name(trigger)]

  defp maybe_filter_scheduler(query, nil), do: query

  defp maybe_filter_scheduler(query, scheduler) do
    scheduler = scheduler_name(scheduler)
    from(row in query, where: row.scheduler == ^scheduler)
  end

  defp maybe_filter_trigger(query, nil), do: query

  defp maybe_filter_trigger(query, trigger) do
    trigger = trigger_name(trigger)
    from(row in query, where: row.trigger == ^trigger)
  end

  defp scheduler_evidence(
         repo,
         cadence,
         from,
         until,
         window_ms,
         expected_nodes,
         min_effective_nodes,
         require_lock_loser?,
         opts
       ) do
    missing_expected_nodes = missing_nodes(expected_nodes, cadence.scheduled_nodes)
    missing_effective_nodes = missing_nodes(expected_nodes, cadence.effective_scheduled_nodes)
    window = evidence_window(repo, cadence.scheduler, from, until, opts)
    rollups = evidence_rollup_coverage(repo, cadence.scheduler, from, until, window_ms)

    blockers =
      evidence_blockers(
        cadence,
        missing_expected_nodes,
        min_effective_nodes,
        require_lock_loser?
      )
      |> Kernel.++(rollup_blockers(cadence, rollups, opts))

    warnings = evidence_warnings(cadence, window)

    %{
      scheduler: cadence.scheduler,
      status: evidence_status(blockers, warnings),
      state: cadence.scheduler |> state(repo: repo) |> maybe_state_to_view(),
      cadence: cadence,
      expected_nodes: expected_nodes,
      scheduled_nodes: cadence.scheduled_nodes,
      effective_scheduled_nodes: cadence.effective_scheduled_nodes,
      healthy_scheduled_nodes: cadence.healthy_scheduled_nodes,
      skipped_scheduled_nodes: cadence.skipped_scheduled_nodes,
      missing_expected_nodes: missing_expected_nodes,
      missing_effective_nodes: missing_effective_nodes,
      min_effective_nodes: min_effective_nodes,
      min_effective_nodes_met?: length(cadence.effective_scheduled_nodes) >= min_effective_nodes,
      require_lock_loser?: require_lock_loser?,
      lock_loser_nodes: cadence.lock_loser_nodes,
      lock_loser_count: cadence.lock_loser_count,
      lock_loser_evidence_met?: not require_lock_loser? or cadence.lock_loser_count > 0,
      blocked_runs: window.blocked_runs,
      failed_runs: window.failed_runs,
      next_actions: window.next_actions,
      recent_problem_runs: window.recent_problem_runs,
      rollup_coverage: rollups,
      blockers: blockers,
      warnings: warnings
    }
  end

  defp maybe_state_to_view(nil), do: nil
  defp maybe_state_to_view(%SchedulerState{} = state), do: to_view(state)

  defp evidence_blockers(
         cadence,
         missing_expected_nodes,
         min_effective_nodes,
         require_lock_loser?
       ) do
    []
    |> maybe_block(
      cadence.health != "ok",
      %{
        scheduler: cadence.scheduler,
        reason: :scheduler_not_healthy,
        health: cadence.health,
        cadence_reason: cadence.reason
      }
    )
    |> maybe_block(
      missing_expected_nodes != [],
      %{
        scheduler: cadence.scheduler,
        reason: :missing_expected_nodes,
        missing_nodes: missing_expected_nodes
      }
    )
    |> maybe_block(
      length(cadence.effective_scheduled_nodes) < min_effective_nodes,
      %{
        scheduler: cadence.scheduler,
        reason: :min_effective_nodes_not_met,
        min_effective_nodes: min_effective_nodes,
        actual_effective_nodes: length(cadence.effective_scheduled_nodes),
        effective_nodes: cadence.effective_scheduled_nodes
      }
    )
    |> maybe_block(
      require_lock_loser? and cadence.lock_loser_count == 0,
      %{
        scheduler: cadence.scheduler,
        reason: :missing_lock_loser_evidence,
        lock_loser_count: cadence.lock_loser_count
      }
    )
    |> Enum.reverse()
  end

  defp rollup_blockers(cadence, rollups, opts) do
    if Keyword.get(opts, :require_rollups?, false) == true and not rollups.ready? do
      [
        %{
          scheduler: cadence.scheduler,
          reason: :scheduled_rollups_missing,
          missing_windows: rollups.missing_windows
        }
      ]
    else
      []
    end
  end

  defp evidence_warnings(cadence, window) do
    []
    |> maybe_block(
      window.blocked_runs > 0,
      %{scheduler: cadence.scheduler, reason: :blocked_runs_seen, count: window.blocked_runs}
    )
    |> maybe_block(
      window.failed_runs > 0,
      %{scheduler: cadence.scheduler, reason: :failed_runs_seen, count: window.failed_runs}
    )
    |> Enum.reverse()
  end

  defp maybe_block(items, true, item), do: [item | items]
  defp maybe_block(items, false, _item), do: items

  defp evidence_status([_ | _], _warnings), do: "blocked"
  defp evidence_status([], [_ | _]), do: "attention"
  defp evidence_status([], []), do: "ok"

  defp missing_nodes([], _observed), do: []

  defp missing_nodes(expected, observed) do
    observed = MapSet.new(observed)

    expected
    |> Enum.reject(&MapSet.member?(observed, &1))
    |> Enum.sort()
  end

  defp evidence_window(repo, scheduler, from, until, opts) do
    action_limit =
      positive_int(Keyword.get(opts, :next_action_limit), @default_evidence_action_limit)

    status_counts = scheduled_problem_counts(repo, scheduler, from, until)

    runs =
      SchedulerRun
      |> where(
        [r],
        r.scheduler == ^scheduler and r.trigger == "scheduled" and
          r.finished_at >= ^from and r.finished_at < ^until and
          r.status in ["blocked", "failed"]
      )
      |> latest_run_first()
      |> limit(^max(action_limit * 2, action_limit))
      |> repo.all()

    %{
      blocked_runs: Map.get(status_counts, "blocked", 0),
      failed_runs: Map.get(status_counts, "failed", 0),
      next_actions: evidence_next_actions(runs, action_limit),
      recent_problem_runs: Enum.map(runs, &problem_run_to_view/1)
    }
  end

  defp scheduled_problem_counts(repo, scheduler, from, until) do
    SchedulerRun
    |> where(
      [r],
      r.scheduler == ^scheduler and r.trigger == "scheduled" and
        r.finished_at >= ^from and r.finished_at < ^until and
        r.status in ["blocked", "failed"]
    )
    |> group_by([r], r.status)
    |> select([r], {r.status, count(r.id)})
    |> repo.all()
    |> Map.new()
  end

  defp evidence_next_actions(runs, limit) do
    runs
    |> Enum.flat_map(&run_next_action/1)
    |> Enum.uniq_by(&{&1.job_id, &1.phase, &1.action})
    |> Enum.take(limit)
  end

  defp run_next_action(%SchedulerRun{summary: summary} = run) when is_map(summary) do
    case Map.get(summary, "next_action") || Map.get(summary, :next_action) do
      action when is_binary(action) and action != "" ->
        [
          %{
            run_id: run.id,
            scheduler: run.scheduler,
            status: run.status,
            phase: run.phase,
            job_id: run.job_id,
            finished_at: run.finished_at,
            action: redact_text(action)
          }
        ]

      _other ->
        []
    end
  end

  defp run_next_action(_run), do: []

  defp problem_run_to_view(%SchedulerRun{} = run) do
    %{
      id: run.id,
      scheduler: run.scheduler,
      node: run.node,
      status: run.status,
      phase: run.phase,
      job_id: run.job_id,
      finished_at: run.finished_at,
      error_reason: run.error_reason
    }
  end

  defp evidence_rollup_coverage(repo, scheduler, from, until, window_ms) do
    cond do
      not aligned?(from, window_ms) or not aligned?(until, window_ms) ->
        %{
          ready?: false,
          status: "not_aligned",
          windows: 0,
          existing_windows: 0,
          missing_windows: []
        }

      true ->
        windows = rollup_window_starts(from, until, window_ms)

        existing =
          SchedulerRunRollup
          |> where(
            [r],
            r.scheduler == ^scheduler and r.trigger == "scheduled" and
              r.window_ms == ^window_ms and r.window_started_at in ^windows
          )
          |> select([r], r.window_started_at)
          |> repo.all()
          |> Enum.map(&DateTime.to_unix(&1, :microsecond))
          |> MapSet.new()

        missing =
          windows
          |> Enum.reject(&MapSet.member?(existing, DateTime.to_unix(&1, :microsecond)))
          |> Enum.map(fn window_started_at ->
            %{
              scheduler: scheduler,
              trigger: "scheduled",
              window_started_at: window_started_at,
              window_finished_at: DateTime.add(window_started_at, window_ms, :millisecond),
              window_ms: window_ms
            }
          end)

        %{
          ready?: missing == [],
          status: if(missing == [], do: "ready", else: "missing_rollups"),
          windows: length(windows),
          existing_windows: MapSet.size(existing),
          missing_windows: Enum.take(missing, @default_evidence_action_limit)
        }
    end
  end

  defp evidence_from(opts, until) do
    case Keyword.get(opts, :from) do
      nil -> cadence_since(until, positive_or_nil(Keyword.get(opts, :stale_after_ms)), opts)
      %DateTime{} = from -> from
      other -> other
    end
  end

  defp validate_evidence_range(%DateTime{} = from, %DateTime{} = until, window_ms) do
    cond do
      not (is_integer(window_ms) and window_ms > 0) ->
        {:error, {:invalid_scheduler_evidence_range, :invalid_window_ms}}

      DateTime.compare(from, until) != :lt ->
        {:error, {:invalid_scheduler_evidence_range, :from_must_be_before_until}}

      true ->
        :ok
    end
  end

  defp validate_evidence_range(_from, _until, _window_ms),
    do: {:error, {:invalid_scheduler_evidence_range, :datetime_required}}

  defp normalize_expected_nodes(nil), do: []

  defp normalize_expected_nodes(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(&normalize_expected_node/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_expected_nodes(node), do: normalize_expected_nodes([node])

  defp normalize_expected_node(node) when is_atom(node), do: Atom.to_string(node)
  defp normalize_expected_node(node) when is_binary(node), do: String.trim(node)
  defp normalize_expected_node(node), do: node |> to_string() |> String.trim()

  defp cadence_report_for(repo, scheduler, now, opts) do
    state = state(scheduler, repo: repo)
    expected_interval_ms = expected_interval_ms(scheduler, opts)
    stale_after_ms = stale_after_ms(expected_interval_ms, opts)
    since = cadence_since(now, stale_after_ms, opts)
    last_scheduled = last_scheduled_run(repo, scheduler, now, opts)
    last_effective = last_effective_scheduled_run(repo, scheduler, now, opts)
    last_healthy = last_healthy_scheduled_run(repo, scheduler, now, opts)
    counts = scheduled_window_counts(repo, scheduler, since, now, opts)
    nodes = scheduled_window_nodes(repo, scheduler, since, now, opts)
    healthy_age_ms = age_ms(now, finished_at(last_healthy))

    {health, reason} =
      cadence_health(
        state,
        last_scheduled,
        last_effective,
        last_healthy,
        healthy_age_ms,
        stale_after_ms,
        now
      )

    %{
      scheduler: scheduler,
      health: health,
      healthy?: health == "ok",
      reason: reason,
      state_status: state && state.status,
      alert_status: state && state.alert_status,
      backoff_until: state && state.backoff_until,
      expected_interval_ms: expected_interval_ms,
      stale_after_ms: stale_after_ms,
      since: since,
      scheduled_runs: Map.get(counts, "total", 0),
      effective_scheduled_runs: Map.get(counts, "effective", 0),
      skipped_scheduled_runs: Map.get(counts, "skipped", 0),
      blocked_scheduled_runs: Map.get(counts, "blocked", 0),
      failed_scheduled_runs: Map.get(counts, "failed", 0),
      last_scheduled_run_id: last_scheduled && last_scheduled.id,
      last_scheduled_status: last_scheduled && last_scheduled.status,
      last_scheduled_finished_at: finished_at(last_scheduled),
      last_effective_scheduled_run_id: last_effective && last_effective.id,
      last_effective_scheduled_status: last_effective && last_effective.status,
      last_effective_scheduled_node: last_effective && last_effective.node,
      last_effective_scheduled_finished_at: finished_at(last_effective),
      last_healthy_scheduled_run_id: last_healthy && last_healthy.id,
      last_healthy_scheduled_status: last_healthy && last_healthy.status,
      last_healthy_scheduled_finished_at: finished_at(last_healthy),
      scheduled_nodes: nodes.scheduled_nodes,
      effective_scheduled_nodes: nodes.effective_scheduled_nodes,
      healthy_scheduled_nodes: nodes.healthy_scheduled_nodes,
      skipped_scheduled_nodes: nodes.skipped_scheduled_nodes,
      lock_loser_nodes: nodes.lock_loser_nodes,
      lock_loser_count: nodes.lock_loser_count,
      effective_age_ms: healthy_age_ms
    }
  end

  defp cadence_health(
         _state,
         nil,
         _last_effective,
         _last_healthy,
         _age_ms,
         _stale_after_ms,
         _now
       ),
       do: {"not_started", "no_scheduled_runs"}

  defp cadence_health(
         %SchedulerState{alert_status: "alert"},
         _last_scheduled,
         _last_effective,
         _last_healthy,
         _age_ms,
         _stale_after_ms,
         _now
       ),
       do: {"alert", "scheduler_alert"}

  defp cadence_health(
         %SchedulerState{backoff_until: %DateTime{} = backoff_until},
         _last_scheduled,
         last_effective,
         last_healthy,
         age_ms,
         stale_after_ms,
         now
       ) do
    if DateTime.compare(backoff_until, now) == :gt do
      {"backoff", "scheduler_backoff_active"}
    else
      cadence_scheduled_health(last_effective, last_healthy, age_ms, stale_after_ms)
    end
  end

  defp cadence_health(
         %SchedulerState{status: "failed"},
         _last_scheduled,
         _last_effective,
         _last_healthy,
         _age_ms,
         _stale_after_ms,
         _now
       ),
       do: {"failed", "effective_state_failed"}

  defp cadence_health(
         %SchedulerState{status: "blocked"},
         _last_scheduled,
         _last_effective,
         _last_healthy,
         _age_ms,
         _stale_after_ms,
         _now
       ),
       do: {"blocked", "effective_state_blocked"}

  defp cadence_health(
         _state,
         _last_scheduled,
         last_effective,
         last_healthy,
         age_ms,
         stale_after_ms,
         _now
       ),
       do: cadence_scheduled_health(last_effective, last_healthy, age_ms, stale_after_ms)

  defp cadence_scheduled_health(nil, _last_healthy, _age_ms, _stale_after_ms),
    do: {"stale", "no_effective_scheduled_run"}

  defp cadence_scheduled_health(
         %SchedulerRun{status: "failed"},
         _last_healthy,
         _age_ms,
         _stale_after_ms
       ),
       do: {"failed", "latest_scheduled_failed"}

  defp cadence_scheduled_health(
         %SchedulerRun{status: "blocked"},
         _last_healthy,
         _age_ms,
         _stale_after_ms
       ),
       do: {"blocked", "latest_scheduled_blocked"}

  defp cadence_scheduled_health(_last_effective, nil, _age_ms, _stale_after_ms),
    do: {"stale", "no_healthy_scheduled_run"}

  defp cadence_scheduled_health(_last_effective, _last_healthy, _age_ms, nil),
    do: {"unknown", "unknown_expected_interval"}

  defp cadence_scheduled_health(_last_effective, _last_healthy, age_ms, stale_after_ms)
       when is_integer(age_ms) and age_ms > stale_after_ms,
       do: {"stale", "effective_scheduled_run_overdue"}

  defp cadence_scheduled_health(_last_effective, _last_healthy, _age_ms, _stale_after_ms),
    do: {"ok", "recent_effective_scheduled_run"}

  defp cadence_schedulers(nil), do: @schedulers
  defp cadence_schedulers(scheduler), do: [scheduler_name(scheduler)]

  defp expected_interval_ms(scheduler, opts) do
    case positive_or_nil(Keyword.get(opts, :expected_interval_ms)) do
      nil -> expected_interval_ms_by_scheduler(scheduler, opts)
      value -> value
    end
  end

  defp expected_interval_ms_by_scheduler(scheduler, opts) do
    by_scheduler = Keyword.get(opts, :expected_interval_ms_by_scheduler, %{})

    case Map.get(by_scheduler, scheduler) || Map.get(by_scheduler, scheduler_atom(scheduler)) do
      value when is_integer(value) and value > 0 -> value
      _other -> configured_interval_ms(scheduler)
    end
  end

  defp scheduler_atom("fresh_drive_heal"), do: :fresh_drive_heal
  defp scheduler_atom("rebalance"), do: :rebalance

  defp configured_interval_ms("fresh_drive_heal") do
    :maxio
    |> Application.get_env(:fresh_drive_heal_scheduler, [])
    |> Keyword.get(:interval_ms)
    |> positive_or_nil()
  end

  defp configured_interval_ms("rebalance") do
    :maxio
    |> Application.get_env(:rebalance_scheduler, [])
    |> Keyword.get(:interval_ms)
    |> positive_or_nil()
  end

  defp configured_interval_ms(_scheduler), do: nil

  defp stale_after_ms(expected_interval_ms, opts) do
    case positive_or_nil(Keyword.get(opts, :stale_after_ms)) do
      nil -> default_stale_after_ms(expected_interval_ms)
      value -> value
    end
  end

  defp default_stale_after_ms(expected_interval_ms)
       when is_integer(expected_interval_ms) and expected_interval_ms > 0,
       do: expected_interval_ms * @default_stale_after_multiplier

  defp default_stale_after_ms(_expected_interval_ms), do: nil

  defp cadence_since(now, stale_after_ms, opts) do
    case Keyword.get(opts, :since) do
      %DateTime{} = since ->
        since

      _other ->
        case positive_or_nil(Keyword.get(opts, :since_minutes)) do
          nil -> default_cadence_since(now, stale_after_ms)
          minutes -> DateTime.add(now, -minutes * 60, :second)
        end
    end
  end

  defp default_cadence_since(now, stale_after_ms)
       when is_integer(stale_after_ms) and stale_after_ms > 0,
       do: DateTime.add(now, -stale_after_ms, :millisecond)

  defp default_cadence_since(now, _stale_after_ms),
    do: DateTime.add(now, -@default_since_minutes * 60, :second)

  defp last_scheduled_run(repo, scheduler, now, opts) do
    SchedulerRun
    |> where(
      [r],
      r.scheduler == ^scheduler and r.trigger == "scheduled"
    )
    |> maybe_filter_until(now, opts)
    |> latest_run_first()
    |> limit(1)
    |> repo.one()
  end

  defp last_effective_scheduled_run(repo, scheduler, now, opts) do
    SchedulerRun
    |> where(
      [r],
      r.scheduler == ^scheduler and r.trigger == "scheduled" and
        r.status not in ^@non_effective_scheduled_statuses
    )
    |> maybe_filter_until(now, opts)
    |> latest_run_first()
    |> limit(1)
    |> repo.one()
  end

  defp last_healthy_scheduled_run(repo, scheduler, now, opts) do
    SchedulerRun
    |> where(
      [r],
      r.scheduler == ^scheduler and r.trigger == "scheduled" and
        r.status in ^@healthy_scheduled_statuses
    )
    |> maybe_filter_until(now, opts)
    |> latest_run_first()
    |> limit(1)
    |> repo.one()
  end

  defp scheduled_window_counts(repo, scheduler, since, now, opts) do
    rows =
      SchedulerRun
      |> where(
        [r],
        r.scheduler == ^scheduler and r.trigger == "scheduled" and r.finished_at >= ^since
      )
      |> maybe_filter_until(now, opts)
      |> group_by([r], r.status)
      |> select([r], {r.status, count(r.id)})
      |> repo.all()

    status_counts = Map.new(rows)
    total = Enum.reduce(status_counts, 0, fn {_status, count}, acc -> acc + count end)
    skipped = Map.get(status_counts, "skipped", 0)

    status_counts
    |> Map.put("total", total)
    |> Map.put("effective", total - skipped)
  end

  defp scheduled_window_nodes(repo, scheduler, since, now, opts) do
    runs =
      SchedulerRun
      |> where(
        [r],
        r.scheduler == ^scheduler and r.trigger == "scheduled" and r.finished_at >= ^since
      )
      |> maybe_filter_until(now, opts)
      |> select([r], %{node: r.node, status: r.status, error_reason: r.error_reason})
      |> repo.all()

    %{
      scheduled_nodes: nodes_matching(runs, fn _run -> true end),
      effective_scheduled_nodes:
        nodes_matching(runs, &(&1.status not in @non_effective_scheduled_statuses)),
      healthy_scheduled_nodes: nodes_matching(runs, &(&1.status in @healthy_scheduled_statuses)),
      skipped_scheduled_nodes: nodes_matching(runs, &(&1.status == "skipped")),
      lock_loser_nodes: nodes_matching(runs, &lock_loser_run?/1),
      lock_loser_count: Enum.count(runs, &lock_loser_run?/1)
    }
  end

  defp maybe_filter_until(query, %DateTime{} = until, opts) do
    if Keyword.get(opts, :until_exclusive?, false) do
      where(query, [r], r.finished_at < ^until)
    else
      where(query, [r], r.finished_at <= ^until)
    end
  end

  defp nodes_matching(runs, fun) do
    runs
    |> Enum.filter(fun)
    |> Enum.map(& &1.node)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp lock_loser_run?(%{status: "skipped", error_reason: reason}),
    do: reason == "\"lock_unavailable\"" or reason == "lock_unavailable"

  defp lock_loser_run?(_run), do: false

  defp finished_at(nil), do: nil
  defp finished_at(%SchedulerRun{finished_at: finished_at}), do: finished_at

  defp age_ms(_now, nil), do: nil

  defp age_ms(now, %DateTime{} = finished_at),
    do: max(DateTime.diff(now, finished_at, :millisecond), 0)

  defp positive_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_or_nil(_value), do: nil

  defp scheduler_name(scheduler) when is_atom(scheduler), do: Atom.to_string(scheduler)

  defp scheduler_name(scheduler) when is_binary(scheduler) and scheduler in @schedulers,
    do: scheduler

  defp scheduler_name(other), do: raise(ArgumentError, "invalid scheduler #{inspect(other)}")

  defp trigger_name(trigger) when is_atom(trigger), do: Atom.to_string(trigger)
  defp trigger_name(trigger) when is_binary(trigger), do: trigger

  defp node_name(opts) do
    opts
    |> Keyword.get(:node, Node.self())
    |> Atom.to_string()
  end

  defp enabled?(opts), do: Keyword.get(opts, :enabled, true) == true

  defp retention_opts(opts) do
    :maxio
    |> Application.get_env(:scheduler_ledger_retention, [])
    |> Keyword.merge(opts)
  end

  defp retention_enabled?(opts), do: Keyword.get(opts, :enabled, false) == true

  defp retention_window_ms(opts) do
    cond do
      Keyword.has_key?(opts, :window_ms) ->
        Keyword.get(opts, :window_ms)

      Keyword.has_key?(opts, :window_minutes) ->
        retention_minutes_to_ms(Keyword.get(opts, :window_minutes))

      true ->
        @default_rollup_window_ms
    end
  end

  defp retention_minutes_to_ms(minutes) when is_integer(minutes), do: minutes * 60 * 1_000
  defp retention_minutes_to_ms(value), do: value

  defp duration_ms(started_at, finished_at) do
    max(DateTime.diff(finished_at, started_at, :millisecond), 0)
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value, default), do: default

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp now, do: DateTime.utc_now()

  defp evidence_value_to_view(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp evidence_value_to_view(value) when is_atom(value), do: Atom.to_string(value)
  defp evidence_value_to_view(value) when is_binary(value), do: value
  defp evidence_value_to_view(value) when is_boolean(value) or is_nil(value), do: value
  defp evidence_value_to_view(value) when is_number(value), do: value

  defp evidence_value_to_view(values) when is_list(values),
    do: Enum.map(values, &evidence_value_to_view/1)

  defp evidence_value_to_view(%{} = value) do
    Map.new(value, fn {key, item} -> {key, evidence_value_to_view(item)} end)
  end

  defp evidence_value_to_view(value), do: value

  defp json_ready(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_ready(value) when is_boolean(value) or is_nil(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_binary(value), do: redact_text(value)
  defp json_ready(value) when is_number(value), do: value
  defp json_ready(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_ready()
  defp json_ready(values) when is_list(values), do: Enum.map(values, &json_ready/1)

  defp json_ready(%{} = value) do
    Map.new(value, fn {key, item} ->
      key = to_string(key)

      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, json_ready(item)}
      end
    end)
  end

  defp json_ready(value), do: value |> inspect(limit: 20, printable_limit: 200) |> redact_text()

  defp sensitive_key?(key) do
    downcased = String.downcase(key)
    Enum.any?(@sensitive_key_fragments, &String.contains?(downcased, &1))
  end

  defp redact_text(text) do
    Enum.reduce(@sensitive_text_patterns, text, fn pattern, acc ->
      Regex.replace(pattern, acc, "\\1[REDACTED]")
    end)
  end
end
