defmodule Maxio.Cluster.Rebalance.Scheduler do
  @moduledoc """
  Config-gated background runner for decommission jobs.

  The scheduler only orchestrates existing, bounded primitives:

    * `Maxio.Cluster.Rebalance.Runner.run_once/2` for the copy pass.
    * `Maxio.Cluster.Rebalance.SourceCleanup.cleanup_once/2` for old source copies.

  It does not mutate topology or remove pools from the deployment. When no
  explicit destination is configured, it can ask the runner to choose one from
  DriveStats free-space telemetry.
  """

  use GenServer

  alias Maxio.Cluster.{Lock, Topology}
  alias Maxio.Cluster.Rebalance.{Job, Jobs, Runner, SourceCleanup}
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
    :now_ms,
    :now_fun,
    :authoritative_source,
    :runner_lock_opts
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
    {result, state} = run_cycle(state, opts)
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
    {_result, state} = run_cycle(%{state | timer_ref: nil}, [])
    {:noreply, schedule(state, state.interval_ms)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)
    :ok
  end

  defp run_cycle(state, opts) do
    cfg = config(Keyword.merge(state.base_opts, opts))
    result = locked_run(cfg)
    log_non_idle_error(result)
    {result, record_result(state, result)}
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

  defp do_run(cfg) do
    with {:ok, job} <- cfg[:job_selector].(cfg[:run_opts]),
         {:ok, phase} <- phase(job, cfg) do
      run_phase(phase, job, cfg)
    end
  end

  defp phase(%Job{kind: kind}, _cfg) when kind != "decommission",
    do: {:error, {:unsupported_job_kind, kind}}

  defp phase(%Job{status: status}, _cfg) when status in ["canceled", "cancel_requested"],
    do: {:error, :canceled}

  defp phase(%Job{data_movement_status: "complete", source_cleanup_status: status}, cfg)
       when status in ["not_started", "moving", "failed"] do
    if cfg[:auto_source_cleanup] do
      {:ok, :source_cleanup}
    else
      {:error, :source_cleanup_disabled}
    end
  end

  defp phase(%Job{status: status, data_movement_status: movement}, _cfg)
       when status in ["planned", "running"] and movement in ["not_started", "moving"] do
    {:ok, :copy}
  end

  defp phase(%Job{} = job, _cfg) do
    {:error,
     {:job_not_runnable, job.id, job.status, job.data_movement_status, job.source_cleanup_status}}
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
      run_opts: run_opts,
      job_selector: job_selector(opts, cfg),
      copy_runner: copy_runner(opts, cfg),
      cleanup_runner: cleanup_runner(opts, cfg)
    ]
  end

  defp run_opts(opts, cfg) do
    cfg
    |> Keyword.get(:run_opts, [])
    |> Keyword.merge(Keyword.get(opts, :run_opts, []))
    |> Keyword.merge(Keyword.take(opts, @run_keys))
  end

  defp job_selector(opts, cfg) do
    case Keyword.get(opts, :job_selector, Keyword.get(cfg, :job_selector)) do
      fun when is_function(fun, 1) -> fun
      _ -> &Jobs.next_runnable_decommission/1
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

  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n
  defp positive_int(_n, default), do: default

  defp non_negative_int(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_negative_int(_n, default), do: default
end
