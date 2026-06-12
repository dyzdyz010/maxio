defmodule Maxio.Cluster.FreshDriveHeal.Scheduler do
  @moduledoc """
  Config-gated scheduler for the fresh-drive heal operator workflow.

  The scheduler does not introduce a second healing path. It optionally refreshes
  drive-health observations, then runs `Maxio.Cluster.FreshDriveHeal.run_once/1`
  under a cluster singleton lease so only one node performs the expensive pass.
  """

  use GenServer

  alias Maxio.Cluster.{DriveHealth, FreshDriveHeal, Lock, Topology}
  alias Maxio.S3.Log

  @lock_resource {:fresh_drive_heal_scheduler, :run}

  @fresh_drive_run_keys [
    :bucket,
    :scan_versions,
    :max_objects,
    :dry_run,
    :page_size,
    :topology,
    :transport,
    :lock_nodes,
    :lock_ttl_ms,
    :lock_timeout_ms,
    :lock_heartbeat_ms,
    :max_objects_per_sec,
    :object_burst,
    :sleep_between_batches_ms,
    :adaptive_io,
    :max_live_requests,
    :io_pause_ms,
    :io_max_pause_ms,
    :io_load_source,
    :io_load_fun,
    :throttle_sleep_fun,
    :throttle_now_fun,
    :no_throttle,
    :drive_offline_after_ms,
    :drive_health_now_fun,
    :drive_health_now_ms
  ]

  @doc false
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Run one scheduler-controlled fresh-drive heal pass through the registered process."
  @spec run_now(keyword()) :: {:ok, FreshDriveHeal.report()} | {:error, term()}
  def run_now(opts \\ []), do: run_now(__MODULE__, opts)

  @doc "Run one scheduler-controlled fresh-drive heal pass through `server`."
  @spec run_now(GenServer.server(), keyword()) ::
          {:ok, FreshDriveHeal.report()} | {:error, term()}
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
      Log.info("fresh-drive heal scheduler enabled",
        action: :fresh_drive_heal_scheduler,
        reason: "interval_ms=#{cfg[:interval_ms]} initial_delay_ms=#{cfg[:initial_delay_ms]}"
      )

      {:ok, schedule(state, cfg[:initial_delay_ms])}
    else
      Log.info("fresh-drive heal scheduler disabled",
        action: :fresh_drive_heal_scheduler,
        reason: "enable via config :maxio, :fresh_drive_heal_scheduler, enabled: true"
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

  def handle_info(_msg, state), do: {:noreply, state}

  defp run_cycle(state, opts) do
    cfg = config(Keyword.merge(state.base_opts, opts))
    result = locked_run(cfg)
    {result, record_result(state, result)}
  end

  defp locked_run(cfg) do
    case Lock.quorum_with_lock(@lock_resource, fn -> do_run(cfg) end, lock_opts(cfg)) do
      {:ok, {:ok, report}} ->
        {:ok, report}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, :no_quorum} ->
        Log.warn("fresh-drive heal scheduler skipped because singleton lock is held",
          action: :fresh_drive_heal_scheduler,
          reason: "resource=#{inspect(@lock_resource)}"
        )

        {:error, :lock_unavailable}
    end
  rescue
    e ->
      Log.error("fresh-drive heal scheduler crashed",
        action: :fresh_drive_heal_scheduler,
        reason: Exception.message(e)
      )

      {:error, {:crashed, Exception.message(e)}}
  catch
    kind, reason ->
      Log.error("fresh-drive heal scheduler caught",
        action: :fresh_drive_heal_scheduler,
        reason: inspect({kind, reason})
      )

      {:error, {:caught, kind, reason}}
  end

  defp do_run(cfg) do
    if cfg[:probe_drive_health] do
      _ = cfg[:probe_fun].(drive_health_opts(cfg))
    end

    case cfg[:runner].(cfg[:run_opts]) do
      {:ok, report} -> {:ok, report}
      other -> {:error, {:bad_runner_result, other}}
    end
  end

  defp record_result(state, {:ok, report}) do
    %{state | last_result: report, last_skip_reason: nil}
  end

  defp record_result(state, {:error, reason}) do
    %{state | last_skip_reason: reason}
  end

  defp schedule(state, ms) do
    ref = Process.send_after(self(), :run, max(ms, 0))
    %{state | timer_ref: ref}
  end

  defp config(opts) do
    cfg = Application.get_env(:maxio, :fresh_drive_heal_scheduler, [])

    [
      enabled: Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, false)),
      interval_ms:
        positive_int(
          Keyword.get(opts, :interval_ms, Keyword.get(cfg, :interval_ms, 86_400_000)),
          86_400_000
        ),
      initial_delay_ms:
        non_negative_int(
          Keyword.get(opts, :initial_delay_ms, Keyword.get(cfg, :initial_delay_ms, 60_000)),
          60_000
        ),
      probe_drive_health:
        Keyword.get(opts, :probe_drive_health, Keyword.get(cfg, :probe_drive_health, true)),
      lock_nodes: Keyword.get(opts, :lock_nodes, Keyword.get(cfg, :lock_nodes)),
      lock_ttl_ms: Keyword.get(opts, :lock_ttl_ms, Keyword.get(cfg, :lock_ttl_ms, 60_000)),
      lock_timeout_ms:
        Keyword.get(opts, :lock_timeout_ms, Keyword.get(cfg, :lock_timeout_ms, 3_000)),
      lock_heartbeat_ms:
        Keyword.get(opts, :lock_heartbeat_ms, Keyword.get(cfg, :lock_heartbeat_ms)),
      run_opts: run_opts(opts, cfg),
      runner: runner(opts, cfg),
      probe_fun: probe_fun(opts, cfg)
    ]
  end

  defp run_opts(opts, cfg) do
    cfg
    |> Keyword.get(:run_opts, [])
    |> Keyword.merge(Keyword.get(opts, :run_opts, []))
    |> Keyword.merge(Keyword.take(opts, @fresh_drive_run_keys))
    |> Keyword.put_new(:scan_versions, true)
  end

  defp runner(opts, cfg) do
    case Keyword.get(opts, :runner, Keyword.get(cfg, :runner)) do
      fun when is_function(fun, 1) -> fun
      _ -> &FreshDriveHeal.run_once/1
    end
  end

  defp probe_fun(opts, cfg) do
    case Keyword.get(opts, :probe_fun, Keyword.get(cfg, :probe_fun)) do
      fun when is_function(fun, 1) -> fun
      _ -> &DriveHealth.probe_topology/1
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

  defp drive_health_opts(cfg) do
    run_opts = cfg[:run_opts]

    [
      topology: Keyword.get(run_opts, :topology),
      transport: Keyword.get(run_opts, :transport),
      offline_after_ms: Keyword.get(run_opts, :drive_offline_after_ms),
      now_fun: Keyword.get(run_opts, :drive_health_now_fun),
      now_ms: Keyword.get(run_opts, :drive_health_now_ms)
    ]
    |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n
  defp positive_int(_n, default), do: default

  defp non_negative_int(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_negative_int(_n, default), do: default
end
