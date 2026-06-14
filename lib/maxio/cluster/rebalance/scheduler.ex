defmodule Maxio.Cluster.Rebalance.Scheduler do
  @moduledoc """
  Config-gated background runner for rebalance/decommission jobs.

  The scheduler only orchestrates existing, bounded primitives:

    * `Maxio.Cluster.Rebalance.Runner.run_once/2` for rebalance/decommission copy passes.
    * `Maxio.Cluster.Rebalance.SourceCleanup.cleanup_once/2` for decommission old source copies.
    * `Maxio.Cluster.Rebalance.TopologyMutation.apply_removal_cluster/2`, only when
      explicitly enabled and the topology source is DB-backed.
    * `Maxio.Cluster.Rebalance.TopologyMutation` deployment finalization, only when explicitly
      enabled and the deployment topology source is DB-backed.
    * `Maxio.Cluster.Rebalance.Closure.verify_once/2` for rebalance closure audit,
      only when explicitly enabled.

  It never removes physical pools.
  Decommission copy passes may use an explicit destination or ask the runner to
  choose one from DriveStats free-space telemetry. Rebalance copy passes choose
  a per-object destination from the current router/topology and never receive
  destination options from the scheduler.
  """

  use GenServer

  alias Maxio.Cluster.{Lock, SchedulerRuns, Topology}
  alias Maxio.Cluster.Rebalance.{Closure, Job, Jobs, Runner, SourceCleanup, TopologyMutation}
  alias Maxio.S3.Log

  @scheduler_lock {:rebalance_scheduler, :run}

  @run_keys [
    :job_id,
    :destination_set_id,
    :destination_sets,
    :auto_destination,
    :max_versions,
    :page_size,
    :topology,
    :transport,
    :provider,
    :drive_stats_fun,
    :nodes,
    :now,
    :now_ms,
    :now_fun,
    :authoritative_source,
    :audit_page_size,
    :runner_lock_opts
  ]

  @deployment_topology_override_keys [
    :expected_proposed_topology_hash,
    :runtime_topology,
    :runtime_config,
    :deployment_topology,
    :deployment_config,
    :node_snapshot_fun,
    :lock_opts
  ]

  @runtime_topology_override_keys [
    :topology,
    :expected_current_topology_hash,
    :runtime_topology,
    :runtime_config,
    :deployment_topology,
    :deployment_config,
    :nodes,
    :node_apply_fun,
    :node_snapshot_fun,
    :after_topology_removal_audit,
    :lock_opts
  ]

  @doc false
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Run one scheduler-controlled rebalance/decommission pass."
  @spec run_now(keyword()) :: {:ok, map()} | {:error, term()}
  def run_now(opts \\ []), do: run_now(__MODULE__, opts)

  @doc """
  Run one rebalance scheduler step without a GenServer.

  This reuses the same singleton lock, job selector, phase selection, runner,
  cleanup, and optional closure verifier as the background scheduler. It is
  intended for bounded operator workflows that need to advance a pinned job
  synchronously.
  """
  @spec run_step(keyword()) :: {:ok, map()} | {:error, term()}
  def run_step(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.put_new(:enabled, false)
    |> config()
    |> locked_run()
  end

  @doc """
  Run up to `:max_steps` scheduler steps for a single rebalance job.

  The job must be explicitly pinned through `:job_id`. Only ordinary
  `kind="rebalance"` jobs with no decommission source/destination set are
  eligible; topology mutation, deployment finalization, decommission, and
  physical-removal phases are deliberately outside this helper.
  """
  @spec run_steps(keyword()) :: {:ok, map()} | {:error, term()}
  def run_steps(opts \\ []) when is_list(opts) do
    max_steps = positive_int(Keyword.get(opts, :max_steps, 1), 1)

    with {:ok, job_id} <- fetch_pinned_job_id(opts),
         {:ok, job} <- Jobs.get(job_id),
         :ok <- ensure_rebalance_drain_job(job) do
      step_opts =
        opts
        |> Keyword.delete(:max_steps)
        |> Keyword.put(:job_id, job_id)
        |> Keyword.put(:job_selector, fn _opts -> Jobs.get(job_id) end)
        |> Keyword.put(:auto_runtime_topology, false)
        |> Keyword.put(:auto_deployment_topology, false)

      do_run_steps(job_id, step_opts, max_steps, [])
    end
  end

  @doc "Run one scheduler-controlled pass through `server`."
  @spec run_now(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_now(server, opts) when is_list(opts),
    do: GenServer.call(server, {:run_now, opts}, :infinity)

  @doc "Return scheduler runtime status and the most recent outcome."
  @spec status() :: map()
  def status, do: status(__MODULE__)

  @doc "Return scheduler runtime status for `server`."
  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    cfg = config(opts)

    state = %{
      enabled: cfg[:enabled],
      interval_ms: cfg[:interval_ms],
      base_opts: opts,
      timer_ref: nil,
      last_result: nil,
      last_skip_reason: nil
    }

    if cfg[:enabled] do
      Log.info("rebalance scheduler enabled",
        action: :rebalance_scheduler,
        reason: "interval_ms=#{cfg[:interval_ms]} initial_delay_ms=#{cfg[:initial_delay_ms]}"
      )

      {:ok, schedule(state, cfg[:initial_delay_ms])}
    else
      Log.info("rebalance scheduler disabled",
        action: :rebalance_scheduler,
        reason: "enable via config :maxio, :rebalance_scheduler, enabled: true"
      )

      {:ok, state}
    end
  end

  @impl true
  def handle_call({:run_now, opts}, _from, state) do
    {result, state} = run_cycle(state, opts, :manual)
    {:reply, result, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled: state.enabled,
       interval_ms: state.interval_ms,
       scheduled?: not is_nil(state.timer_ref),
       last_result: state.last_result,
       last_skip_reason: state.last_skip_reason
     }, state}
  end

  @impl true
  def handle_info(:run, %{enabled: true} = state) do
    {_result, state} = run_cycle(%{state | timer_ref: nil}, [], :scheduled)
    {:noreply, schedule(state, state.interval_ms)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)
    :ok
  end

  defp run_cycle(state, opts, trigger) do
    cfg = config(Keyword.merge(state.base_opts, opts))
    started_at = ledger_now(cfg)

    result =
      case maybe_skip_for_backoff(cfg, trigger, started_at) do
        :run -> locked_run(cfg)
        {:skip, reason} -> {:error, reason}
      end

    finished_at = ledger_now(cfg)
    record_scheduler_run(cfg, trigger, started_at, finished_at, result)
    log_non_idle_error(result)
    {result, record_result(state, result)}
  end

  defp maybe_skip_for_backoff(_cfg, :manual, _now), do: :run

  defp maybe_skip_for_backoff(cfg, :scheduled, now) do
    ledger_opts = cfg[:scheduler_ledger]

    if Keyword.get(ledger_opts, :enabled, true) do
      scheduler = Keyword.fetch!(ledger_opts, :scheduler)

      case SchedulerRuns.backoff_active?(scheduler, Keyword.put(ledger_opts, :now, now)) do
        {:ok, nil} ->
          :run

        {:ok, state} ->
          {:skip, {:backoff_active, DateTime.to_iso8601(state.backoff_until)}}

        {:error, reason} ->
          Log.warn("rebalance scheduler ledger backoff check failed",
            action: :rebalance_scheduler,
            reason: inspect(reason)
          )

          :run
      end
    else
      :run
    end
  end

  defp record_scheduler_run(cfg, trigger, started_at, finished_at, result) do
    ledger_opts = cfg[:scheduler_ledger]

    if Keyword.get(ledger_opts, :enabled, true) do
      scheduler = Keyword.fetch!(ledger_opts, :scheduler)

      case SchedulerRuns.record(scheduler, trigger, started_at, finished_at, result, ledger_opts) do
        {:ok, _recorded} ->
          :ok

        {:error, :scheduler_ledger_disabled} ->
          :ok

        {:error, reason} ->
          Log.warn("rebalance scheduler ledger record failed",
            action: :rebalance_scheduler,
            reason: inspect(reason)
          )
      end
    else
      :ok
    end
  end

  defp ledger_now(cfg) do
    case Keyword.get(cfg[:scheduler_ledger], :now_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> DateTime.utc_now()
    end
  rescue
    _ -> DateTime.utc_now()
  end

  defp locked_run(cfg) do
    case Lock.quorum_with_lock(@scheduler_lock, fn -> do_run(cfg) end, lock_opts(cfg)) do
      {:ok, {:ok, report}} ->
        {:ok, report}

      {:ok, {:error, :not_found}} ->
        {:error, :no_runnable_job}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, :no_quorum} ->
        Log.warn("rebalance scheduler skipped because singleton lock is held",
          action: :rebalance_scheduler,
          reason: "resource=#{inspect(@scheduler_lock)}"
        )

        {:error, :lock_unavailable}
    end
  rescue
    e ->
      Log.error("rebalance scheduler crashed",
        action: :rebalance_scheduler,
        reason: Exception.message(e)
      )

      {:error, {:crashed, Exception.message(e)}}
  catch
    kind, reason ->
      Log.error("rebalance scheduler caught",
        action: :rebalance_scheduler,
        reason: inspect({kind, reason})
      )

      {:error, {:caught, kind, reason}}
  end

  defp fetch_pinned_job_id(opts) do
    case Keyword.get(opts, :job_id) do
      id when is_binary(id) and byte_size(id) > 0 -> {:ok, id}
      other -> {:error, {:missing_pinned_rebalance_job_id, other}}
    end
  end

  defp ensure_rebalance_drain_job(%Job{
         kind: "rebalance",
         target_set_id: nil,
         destination_set_id: nil
       }),
       do: :ok

  defp ensure_rebalance_drain_job(%Job{} = job) do
    {:error,
     {:unsupported_rebalance_drain_job,
      %{
        job_id: job.id,
        kind: job.kind,
        target_set_id: job.target_set_id,
        destination_set_id: job.destination_set_id
      }}}
  end

  defp do_run_steps(job_id, opts, remaining, reports) when remaining > 0 do
    case run_step(opts) do
      {:ok, report} ->
        reports = [report | reports]

        case terminal_status(report, opts) do
          {:terminal, status} ->
            {:ok, rebalance_drain_report(job_id, status, reports, nil)}

          :continue when remaining == 1 ->
            {:ok, rebalance_drain_report(job_id, :partial, reports, :max_steps)}

          :continue ->
            do_run_steps(job_id, opts, remaining - 1, reports)
        end

      {:error, :no_runnable_job} ->
        {:ok, rebalance_drain_report(job_id, :idle, reports, :no_runnable_job)}

      {:error, reason} ->
        if reports == [] do
          {:error, reason}
        else
          {:ok, rebalance_drain_report(job_id, :partial, reports, reason)}
        end
    end
  end

  defp terminal_status(%{phase: :source_cleanup, status: :ok}, opts) do
    not Keyword.get(opts, :auto_rebalance_closure, false)
    |> case do
      true -> {:terminal, :complete}
      false -> :continue
    end
  end

  defp terminal_status(%{phase: :rebalance_closure, status: :verified}, _opts),
    do: {:terminal, :complete}

  defp terminal_status(%{phase: :rebalance_closure, status: :blocked}, _opts),
    do: {:terminal, :blocked}

  defp terminal_status(_report, _opts), do: :continue

  defp rebalance_drain_report(job_id, status, reports, reason) do
    ordered = Enum.reverse(reports)
    phases = Enum.map(ordered, &Map.get(&1, :phase))
    last_report = List.last(ordered) || %{}

    base =
      %{
        status: status,
        job_id: job_id,
        steps: length(ordered),
        phases: phases,
        terminal_phase: List.last(phases),
        reports: ordered
      }
      |> maybe_put_non_empty(:blockers, Map.get(last_report, :blockers, []))

    case reason do
      nil -> base
      reason -> Map.put(base, :reason, reason)
    end
  end

  defp maybe_put_non_empty(map, _key, value) when value in [nil, []], do: map
  defp maybe_put_non_empty(map, key, value), do: Map.put(map, key, value)

  defp do_run(cfg) do
    with {:ok, job} <- select_job(cfg),
         {:ok, phase} <- phase(job, cfg) do
      run_phase(phase, job, cfg)
    end
  end

  defp select_job(cfg) do
    custom_job_selector? = cfg[:custom_job_selector?]
    auto_runtime_topology? = cfg[:auto_runtime_topology]
    auto_deployment_topology? = cfg[:auto_deployment_topology]

    case cfg[:job_selector].(cfg[:run_opts]) do
      {:ok, %Job{} = job} ->
        {:ok, job}

      {:error, :not_found} when not custom_job_selector? ->
        select_default_followup_job(cfg, auto_runtime_topology?, auto_deployment_topology?)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:bad_job_selector_result, other}}
    end
  end

  defp select_default_followup_job(cfg, true, auto_deployment_topology?) do
    case Jobs.next_runnable_runtime_topology(cfg[:run_opts]) do
      {:ok, %Job{} = job} -> {:ok, job}
      {:error, :not_found} -> select_deployment_or_closure_job(cfg, auto_deployment_topology?)
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_default_followup_job(cfg, false, auto_deployment_topology?),
    do: select_deployment_or_closure_job(cfg, auto_deployment_topology?)

  defp select_deployment_or_closure_job(cfg, true) do
    case Jobs.next_runnable_deployment_topology(cfg[:run_opts]) do
      {:ok, %Job{} = job} -> {:ok, job}
      {:error, :not_found} -> select_rebalance_closure_job(cfg)
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_deployment_or_closure_job(cfg, false), do: select_rebalance_closure_job(cfg)

  defp select_rebalance_closure_job(cfg) do
    if cfg[:auto_rebalance_closure] do
      Jobs.next_runnable_rebalance_closure(cfg[:run_opts])
    else
      {:error, :not_found}
    end
  end

  defp phase(%Job{status: status}, _cfg) when status in ["canceled", "cancel_requested"],
    do: {:error, :canceled}

  defp phase(
         %Job{
           kind: kind,
           data_movement_status: "complete",
           source_cleanup_status: status
         },
         cfg
       )
       when kind in ["decommission", "rebalance"] and
              status in ["not_started", "moving", "failed"] do
    if cfg[:auto_source_cleanup] do
      {:ok, :source_cleanup}
    else
      {:error, :source_cleanup_disabled}
    end
  end

  defp phase(
         %Job{
           kind: "rebalance",
           data_movement_status: "complete",
           source_cleanup_status: "skipped"
         },
         cfg
       ) do
    if cfg[:auto_source_cleanup] do
      {:ok, :source_cleanup}
    else
      {:error, :source_cleanup_disabled}
    end
  end

  defp phase(%Job{kind: kind, status: status, data_movement_status: movement}, _cfg)
       when kind in ["decommission", "rebalance"] and
              status in ["planned", "running"] and movement in ["not_started", "moving"] do
    {:ok, :copy}
  end

  defp phase(
         %Job{
           kind: "decommission",
           status: "complete",
           data_movement_status: "complete",
           source_cleanup_status: "complete",
           topology_removal_cluster_status: cluster_status,
           topology_removal_deployment_status: deployment_status
         } = job,
         cfg
       )
       when cluster_status != "runtime_converged" and deployment_status != "verified" do
    with :ok <- ensure_auto_runtime_topology(cfg),
         :ok <- ensure_auto_deployment_topology_for_runtime(cfg),
         :ok <- ensure_db_topology_source(:runtime_topology),
         :ok <- ensure_no_active_job_for_runtime(job) do
      {:ok, :runtime_topology}
    end
  end

  defp phase(
         %Job{
           kind: "decommission",
           status: "complete",
           data_movement_status: "complete",
           source_cleanup_status: "complete",
           topology_removal_status: "runtime_local_applied",
           topology_removal_scope: "runtime_local",
           topology_removal_cluster_status: "runtime_converged",
           topology_removal_deployment_status: deployment_status
         } = job,
         cfg
       )
       when deployment_status != "verified" do
    with :ok <- ensure_auto_deployment_topology(cfg),
         :ok <- ensure_db_topology_source(:deployment_topology),
         :ok <- ensure_no_active_job_for_deployment(job),
         :ok <- ensure_deployment_job_hash(job) do
      {:ok, :deployment_topology}
    end
  end

  defp phase(
         %Job{
           kind: "rebalance",
           status: "complete",
           data_movement_status: "complete",
           source_cleanup_status: "complete",
           rebalance_closure_status: status
         },
         cfg
       )
       when status != "verified" do
    if cfg[:auto_rebalance_closure] do
      {:ok, :rebalance_closure}
    else
      {:error, :rebalance_closure_disabled}
    end
  end

  defp phase(%Job{kind: kind}, _cfg) when kind not in ["decommission", "rebalance"],
    do: {:error, {:unsupported_job_kind, kind}}

  defp phase(%Job{} = job, _cfg) do
    {:error,
     {:job_not_runnable, job.id, job.status, job.data_movement_status, job.source_cleanup_status}}
  end

  defp ensure_auto_deployment_topology(cfg) do
    if cfg[:auto_deployment_topology] do
      :ok
    else
      {:error, :deployment_topology_disabled}
    end
  end

  defp ensure_auto_runtime_topology(cfg) do
    if cfg[:auto_runtime_topology] do
      :ok
    else
      {:error, :runtime_topology_disabled}
    end
  end

  defp ensure_auto_deployment_topology_for_runtime(cfg) do
    if cfg[:auto_deployment_topology] do
      :ok
    else
      {:error, :runtime_topology_requires_auto_deployment_topology}
    end
  end

  defp ensure_db_topology_source(phase) do
    case topology_source() do
      :db -> :ok
      :config -> {:error, db_topology_source_error(phase)}
      other -> {:error, {:invalid_topology_source, other}}
    end
  end

  defp db_topology_source_error(:runtime_topology), do: :runtime_topology_requires_db_source
  defp db_topology_source_error(:deployment_topology), do: :deployment_topology_requires_db_source

  defp ensure_no_active_job_for_runtime(%Job{id: id}) do
    case Jobs.active_job() do
      nil -> :ok
      %Job{id: ^id} -> :ok
      %Job{} = active -> {:error, {:active_job_exists, Jobs.to_view(active)}}
    end
  end

  defp ensure_no_active_job_for_deployment(%Job{id: id}) do
    case Jobs.active_job() do
      nil -> :ok
      %Job{id: ^id} -> :ok
      %Job{} = active -> {:error, {:active_job_exists, Jobs.to_view(active)}}
    end
  end

  defp ensure_deployment_job_hash(%Job{topology_removal_proposed_hash: hash})
       when is_binary(hash) and byte_size(hash) > 0,
       do: :ok

  defp ensure_deployment_job_hash(%Job{}), do: {:error, :missing_proposed_topology_hash}

  defp run_phase(:runtime_topology, %Job{} = job, cfg) do
    opts = runtime_topology_opts(cfg)

    case cfg[:runtime_applier].(job.id, opts) do
      {:ok, report} when is_map(report) ->
        {:ok, Map.merge(report, %{scheduler: true, phase: :runtime_topology})}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:bad_runtime_applier_result, other}}
    end
  end

  defp run_phase(:copy, %Job{} = job, cfg) do
    opts =
      cfg[:run_opts]
      |> put_destination(job, cfg)
      |> put_runner_lock_opts(cfg)

    case cfg[:copy_runner].(job.id, opts) do
      {:ok, report} -> {:ok, Map.merge(report, %{scheduler: true, phase: :copy})}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_runner_result, other}}
    end
  end

  defp run_phase(:source_cleanup, %Job{} = job, cfg) do
    opts =
      cfg[:run_opts]
      |> put_runner_lock_opts(cfg)

    case cfg[:cleanup_runner].(job.id, opts) do
      {:ok, report} -> {:ok, Map.merge(report, %{scheduler: true, phase: :source_cleanup})}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_cleanup_result, other}}
    end
  end

  defp run_phase(:deployment_topology, %Job{} = job, cfg) do
    opts = deployment_topology_opts(job, cfg)

    case cfg[:deployment_finalizer].(job.id, opts) do
      {:ok, report} when is_map(report) ->
        {:ok, Map.merge(report, %{scheduler: true, phase: :deployment_topology})}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:bad_deployment_finalizer_result, other}}
    end
  end

  defp run_phase(:rebalance_closure, %Job{} = job, cfg) do
    opts = rebalance_closure_opts(cfg)

    case cfg[:closure_verifier].(job.id, opts) do
      {:ok, report} when is_map(report) ->
        {:ok, Map.merge(report, %{scheduler: true, phase: :rebalance_closure})}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:bad_closure_verifier_result, other}}
    end
  end

  defp deployment_topology_opts(job, cfg) do
    cfg[:run_opts]
    |> Keyword.drop(@deployment_topology_override_keys)
    |> put_topology_mutation_lock_opts(cfg)
    |> Keyword.put(:expected_proposed_topology_hash, job.topology_removal_proposed_hash)
  end

  defp runtime_topology_opts(cfg) do
    cfg[:run_opts]
    |> Keyword.drop(@runtime_topology_override_keys)
    |> put_topology_mutation_lock_opts(cfg)
  end

  defp rebalance_closure_opts(cfg) do
    cfg[:run_opts]
    |> Keyword.drop([:topology, :transport, :provider, :drive_stats_fun, :destination_set_id])
    |> put_runner_lock_opts(cfg)
    |> put_topology_read_lock_opts(cfg)
  end

  defp put_destination(opts, %Job{kind: "rebalance"}, _cfg),
    do: Keyword.drop(opts, [:destination_set_id, :destination_sets, :auto_destination])

  defp put_destination(opts, %Job{destination_set_id: set_id}, _cfg) when is_integer(set_id),
    do: Keyword.put_new(opts, :destination_set_id, set_id)

  defp put_destination(opts, %Job{} = job, cfg) do
    destination =
      cfg[:destination_set_id] ||
        destination_from_mapping(cfg[:destination_sets], job.target_set_id)

    cond do
      is_integer(destination) ->
        Keyword.put(opts, :destination_set_id, destination)

      cfg[:auto_destination] ->
        Keyword.put(opts, :auto_destination, true)

      true ->
        opts
    end
  end

  defp destination_from_mapping(nil, _target_set_id), do: nil

  defp destination_from_mapping(mapping, target_set_id) when is_map(mapping) do
    Map.get(mapping, target_set_id) || Map.get(mapping, to_string(target_set_id))
  end

  defp destination_from_mapping(mapping, target_set_id) when is_list(mapping) do
    Keyword.get(mapping, target_set_id) || Keyword.get(mapping, to_string(target_set_id))
  end

  defp destination_from_mapping(_mapping, _target_set_id), do: nil

  defp put_runner_lock_opts(opts, cfg) do
    Keyword.put_new(opts, :runner_lock_opts, lock_opts(cfg))
  end

  defp put_topology_mutation_lock_opts(opts, cfg) do
    Keyword.put_new(opts, :lock_opts, lock_opts(cfg))
  end

  defp put_topology_read_lock_opts(opts, cfg) do
    lock_opts =
      cfg
      |> lock_opts()
      |> Keyword.put(:mode, :read)

    Keyword.put_new(opts, :topology_lock_opts, lock_opts)
  end

  defp record_result(state, {:ok, report}) do
    %{state | last_result: report, last_skip_reason: nil}
  end

  defp record_result(state, {:error, reason}) do
    %{state | last_result: nil, last_skip_reason: reason}
  end

  defp log_non_idle_error({:error, :no_runnable_job}), do: :ok
  defp log_non_idle_error({:error, :lock_unavailable}), do: :ok
  defp log_non_idle_error({:error, {:crashed, _reason}}), do: :ok
  defp log_non_idle_error({:error, {:caught, _kind, _reason}}), do: :ok
  defp log_non_idle_error({:ok, _report}), do: :ok

  defp log_non_idle_error({:error, reason}) do
    Log.warn("rebalance scheduler pass skipped",
      action: :rebalance_scheduler,
      reason: inspect(reason)
    )
  end

  defp schedule(state, ms) do
    ref = Process.send_after(self(), :run, max(ms, 0))
    %{state | timer_ref: ref}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: _ = Process.cancel_timer(ref)

  defp config(opts) do
    cfg = Application.get_env(:maxio, :rebalance_scheduler, [])
    run_opts = run_opts(opts, cfg)
    {job_selector, custom_job_selector?} = job_selector(opts, cfg)

    [
      enabled: Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, false)),
      interval_ms:
        positive_int(
          Keyword.get(opts, :interval_ms, Keyword.get(cfg, :interval_ms, 300_000)),
          300_000
        ),
      initial_delay_ms:
        non_negative_int(
          Keyword.get(opts, :initial_delay_ms, Keyword.get(cfg, :initial_delay_ms, 60_000)),
          60_000
        ),
      auto_source_cleanup:
        Keyword.get(opts, :auto_source_cleanup, Keyword.get(cfg, :auto_source_cleanup, true)),
      auto_destination:
        Keyword.get(opts, :auto_destination, Keyword.get(cfg, :auto_destination, true)),
      destination_set_id:
        Keyword.get(opts, :destination_set_id, Keyword.get(cfg, :destination_set_id)),
      destination_sets: Keyword.get(opts, :destination_sets, Keyword.get(cfg, :destination_sets)),
      lock_nodes: Keyword.get(opts, :lock_nodes, Keyword.get(cfg, :lock_nodes)),
      lock_ttl_ms: Keyword.get(opts, :lock_ttl_ms, Keyword.get(cfg, :lock_ttl_ms, 60_000)),
      lock_timeout_ms:
        Keyword.get(opts, :lock_timeout_ms, Keyword.get(cfg, :lock_timeout_ms, 3_000)),
      lock_heartbeat_ms:
        Keyword.get(opts, :lock_heartbeat_ms, Keyword.get(cfg, :lock_heartbeat_ms)),
      auto_deployment_topology:
        Keyword.get(
          opts,
          :auto_deployment_topology,
          Keyword.get(cfg, :auto_deployment_topology, false)
        ),
      auto_runtime_topology:
        Keyword.get(
          opts,
          :auto_runtime_topology,
          Keyword.get(cfg, :auto_runtime_topology, false)
        ),
      auto_rebalance_closure:
        Keyword.get(
          opts,
          :auto_rebalance_closure,
          Keyword.get(cfg, :auto_rebalance_closure, false)
        ),
      run_opts: run_opts,
      job_selector: job_selector,
      custom_job_selector?: custom_job_selector?,
      copy_runner: copy_runner(opts, cfg),
      cleanup_runner: cleanup_runner(opts, cfg),
      runtime_applier: runtime_applier(opts, cfg),
      deployment_finalizer: deployment_finalizer(opts, cfg),
      closure_verifier: closure_verifier(opts, cfg),
      scheduler_ledger: scheduler_ledger_opts(opts, cfg, "rebalance")
    ]
  end

  defp scheduler_ledger_opts(opts, cfg, scheduler) do
    app_cfg = Application.get_env(:maxio, :scheduler_ledger, [])
    scheduler_cfg = Keyword.get(cfg, :scheduler_ledger, [])
    opts_cfg = Keyword.get(opts, :scheduler_ledger, [])

    enabled =
      Keyword.get(
        opts,
        :ledger_enabled,
        Keyword.get(
          opts_cfg,
          :enabled,
          Keyword.get(scheduler_cfg, :enabled, Keyword.get(app_cfg, :enabled, true))
        )
      )

    app_cfg
    |> Keyword.merge(scheduler_cfg)
    |> Keyword.merge(opts_cfg)
    |> Keyword.put(:scheduler, scheduler)
    |> Keyword.put(:enabled, enabled)
  end

  defp run_opts(opts, cfg) do
    cfg
    |> Keyword.get(:run_opts, [])
    |> Keyword.merge(Keyword.get(opts, :run_opts, []))
    |> Keyword.merge(Keyword.take(opts, @run_keys))
  end

  defp job_selector(opts, cfg) do
    case Keyword.get(opts, :job_selector, Keyword.get(cfg, :job_selector)) do
      fun when is_function(fun, 1) -> {fun, true}
      _ -> {&Jobs.next_runnable/1, false}
    end
  end

  defp copy_runner(opts, cfg) do
    case Keyword.get(opts, :copy_runner, Keyword.get(cfg, :copy_runner)) do
      fun when is_function(fun, 2) -> fun
      _ -> &Runner.run_once/2
    end
  end

  defp cleanup_runner(opts, cfg) do
    case Keyword.get(opts, :cleanup_runner, Keyword.get(cfg, :cleanup_runner)) do
      fun when is_function(fun, 2) -> fun
      _ -> &SourceCleanup.cleanup_once/2
    end
  end

  defp runtime_applier(opts, cfg) do
    case Keyword.get(opts, :runtime_applier, Keyword.get(cfg, :runtime_applier)) do
      fun when is_function(fun, 2) -> fun
      _ -> &TopologyMutation.apply_removal_cluster/2
    end
  end

  defp deployment_finalizer(opts, cfg) do
    case Keyword.get(opts, :deployment_finalizer, Keyword.get(cfg, :deployment_finalizer)) do
      fun when is_function(fun, 2) -> fun
      _ -> &TopologyMutation.finalize_removal_deployment/2
    end
  end

  defp closure_verifier(opts, cfg) do
    case Keyword.get(opts, :closure_verifier, Keyword.get(cfg, :closure_verifier)) do
      fun when is_function(fun, 2) -> fun
      _ -> &Closure.verify_once/2
    end
  end

  defp lock_opts(cfg) do
    [
      mode: :write,
      retries: 0,
      nodes: lock_nodes(cfg),
      ttl_ms: cfg[:lock_ttl_ms],
      timeout: cfg[:lock_timeout_ms],
      heartbeat_ms: cfg[:lock_heartbeat_ms]
    ]
    |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp lock_nodes(cfg) do
    case cfg[:lock_nodes] do
      nodes when is_list(nodes) and nodes != [] ->
        Enum.uniq(nodes)

      _ ->
        cfg[:run_opts]
        |> Keyword.get(:topology)
        |> topology_nodes()
        |> case do
          [] -> [Node.self()]
          nodes -> nodes
        end
    end
  end

  defp topology_nodes(nil) do
    if Topology.configured?() do
      Topology.all_set_ids()
      |> Enum.flat_map(fn set_id -> Topology.endpoints(set_id) end)
      |> Enum.map(fn {node, _drive} -> node end)
      |> Enum.uniq()
    else
      []
    end
  rescue
    _ -> []
  end

  defp topology_nodes(topology) do
    topology
    |> Topology.all_set_ids_from()
    |> Enum.flat_map(fn set_id -> Topology.endpoints_from(topology, set_id) end)
    |> Enum.map(fn {node, _drive} -> node end)
    |> Enum.uniq()
  end

  defp topology_source do
    case Application.get_env(:maxio, :topology_source, :config) do
      :config -> :config
      "config" -> :config
      :db -> :db
      "db" -> :db
      other -> other
    end
  end

  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n
  defp positive_int(_n, default), do: default

  defp non_negative_int(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_negative_int(_n, default), do: default
end
