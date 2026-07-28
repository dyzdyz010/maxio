defmodule Maxio.S3.ReplicationDelivery.Scheduler do
  @moduledoc """
  Config-gated retry scheduler for the durable S3 bucket replication outbox.

  This process is only an orchestration wrapper around
  `Maxio.S3.ReplicationDelivery.drain/1`. It does not scan buckets, synthesize
  replication events, or implement a second delivery path.
  """

  use GenServer

  alias Maxio.S3.{Log, ReplicationDelivery}

  @default_interval_ms 60_000
  @default_drain_limit 100

  @drain_option_keys [
    :repo,
    :now,
    :limit,
    :lease_ms,
    :failure_backoff_ms,
    :authoritative_source,
    :topology,
    :transport,
    :fsync,
    :rename_fun,
    :drives,
    :data_shards,
    :parity_shards,
    :block_size,
    :placement_set_id,
    :placement_pool_id,
    :placement_topology_hash
  ]

  @type run_result :: {:ok, map()} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Drain due replication outbox rows once through the scheduler process."
  @spec run_now(keyword()) :: run_result()
  def run_now(opts \\ []), do: run_now(__MODULE__, opts)

  @doc "Drain due replication outbox rows once through `server`."
  @spec run_now(GenServer.server(), keyword()) :: run_result()
  def run_now(server, opts) when is_list(opts),
    do: GenServer.call(server, {:run_now, opts}, :infinity)

  @doc "Return scheduler runtime status and the most recent drain result."
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
      timer_token: nil,
      last_result: nil,
      inflight: %{}
    }

    if cfg[:enabled] do
      Log.info("bucket replication outbox scheduler enabled",
        action: :bucket_replication_delivery,
        reason: "initial_delay_ms=#{cfg[:initial_delay_ms]} interval_ms=#{cfg[:interval_ms]}"
      )

      {:ok, schedule(state, cfg[:initial_delay_ms])}
    else
      Log.info("bucket replication outbox scheduler disabled",
        action: :bucket_replication_delivery,
        reason: "enable via config :maxio, :replication_delivery_scheduler, enabled: true"
      )

      {:ok, state}
    end
  end

  @impl true
  def handle_call({:run_now, opts}, from, state) do
    {run_ref, drain} = start_drain(state, opts, :manual, from)
    {:noreply, put_inflight(state, run_ref, drain)}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled: state.enabled,
       interval_ms: state.interval_ms,
       scheduled?: not is_nil(state.timer_ref),
       draining?: map_size(state.inflight) > 0,
       last_result: state.last_result
     }, state}
  end

  @impl true
  def handle_info({:drain, token}, %{enabled: true, timer_token: token} = state)
      when is_reference(token) do
    cancel_timer(state.timer_ref)
    state = %{state | timer_ref: nil, timer_token: nil}

    if scheduled_inflight?(state) do
      {:noreply, state}
    else
      {run_ref, drain} = start_drain(state, [], :scheduled, nil)
      {:noreply, put_inflight(state, run_ref, drain)}
    end
  end

  def handle_info({:drain, _stale_token}, state), do: {:noreply, state}

  def handle_info({__MODULE__, :drain_done, run_ref, result}, state) do
    case pop_inflight(state, run_ref) do
      {nil, state} ->
        {:noreply, state}

      {drain, state} ->
        Process.demonitor(drain.monitor_ref, [:flush])
        {:noreply, finish_drain(state, drain, result)}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case pop_inflight_by_monitor(state, monitor_ref) do
      {nil, state} ->
        {:noreply, state}

      {drain, state} ->
        result = {:error, {:drain_worker_down, reason}}

        Log.error("bucket replication outbox scheduler worker exited",
          action: :bucket_replication_delivery,
          reason: inspect(reason)
        )

        {:noreply, finish_drain(state, drain, result)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)
    Enum.each(state.inflight, fn {_run_ref, drain} -> stop_drain(drain) end)
    :ok
  end

  defp start_drain(state, opts, trigger, reply_to) do
    cfg = config(Keyword.merge(state.base_opts, opts))
    run_ref = make_ref()
    parent = self()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result = safe_drain(cfg, trigger)
        send(parent, {__MODULE__, :drain_done, run_ref, result})
      end)

    {run_ref,
     %{
       pid: pid,
       monitor_ref: monitor_ref,
       trigger: trigger,
       reply_to: reply_to
     }}
  end

  defp put_inflight(state, run_ref, drain) do
    %{state | inflight: Map.put(state.inflight, run_ref, drain)}
  end

  defp pop_inflight(state, run_ref) do
    {drain, inflight} = Map.pop(state.inflight, run_ref)
    {drain, %{state | inflight: inflight}}
  end

  defp pop_inflight_by_monitor(state, monitor_ref) do
    case Enum.find(state.inflight, fn {_run_ref, drain} -> drain.monitor_ref == monitor_ref end) do
      nil -> {nil, state}
      {run_ref, _drain} -> pop_inflight(state, run_ref)
    end
  end

  defp scheduled_inflight?(state) do
    Enum.any?(state.inflight, fn {_run_ref, drain} -> drain.trigger == :scheduled end)
  end

  defp finish_drain(state, drain, result) do
    if drain.reply_to do
      GenServer.reply(drain.reply_to, result)
    end

    state = %{state | last_result: result}

    if drain.trigger == :scheduled and state.enabled do
      schedule(state, state.interval_ms)
    else
      state
    end
  end

  defp stop_drain(%{monitor_ref: monitor_ref, pid: pid}) do
    Process.demonitor(monitor_ref, [:flush])
    Process.exit(pid, :shutdown)
  end

  defp safe_drain(cfg, trigger) do
    drain_opts =
      cfg[:run_opts]
      |> Keyword.put_new(:limit, cfg[:drain_limit])

    case ReplicationDelivery.drain(drain_opts) do
      {:ok, summary} = result when is_map(summary) ->
        log_drain_summary(summary, trigger)
        result

      {:error, reason} = result ->
        Log.warn("bucket replication outbox scheduler drain failed",
          action: :bucket_replication_delivery,
          reason: inspect({trigger, reason})
        )

        result

      other ->
        Log.warn("bucket replication outbox scheduler returned unexpected result",
          action: :bucket_replication_delivery,
          reason: inspect({trigger, other})
        )

        {:error, {:bad_drain_result, other}}
    end
  rescue
    error ->
      reason = Exception.message(error)

      Log.error("bucket replication outbox scheduler crashed",
        action: :bucket_replication_delivery,
        reason: inspect({trigger, reason})
      )

      {:error, {:crashed, reason}}
  catch
    kind, reason ->
      Log.error("bucket replication outbox scheduler caught",
        action: :bucket_replication_delivery,
        reason: inspect({trigger, kind, reason})
      )

      {:error, {:caught, kind, reason}}
  end

  defp log_drain_summary(summary, trigger) do
    Log.info("bucket replication outbox scheduler drain complete",
      action: :bucket_replication_delivery,
      reason:
        "trigger=#{trigger} claimed=#{Map.get(summary, :claimed, 0)} " <>
          "completed=#{Map.get(summary, :completed, 0)} failed=#{Map.get(summary, :failed, 0)}"
    )
  end

  defp schedule(state, delay_ms) do
    cancel_timer(state.timer_ref)
    token = make_ref()

    %{
      state
      | timer_ref: Process.send_after(self(), {:drain, token}, max(delay_ms, 0)),
        timer_token: token
    }
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: _ = Process.cancel_timer(ref)

  defp config(opts) do
    app_cfg = Application.get_env(:maxio, :replication_delivery_scheduler, [])

    [
      enabled: Keyword.get(opts, :enabled, Keyword.get(app_cfg, :enabled, false)),
      interval_ms:
        positive_int(
          Keyword.get(
            opts,
            :interval_ms,
            Keyword.get(app_cfg, :interval_ms, @default_interval_ms)
          ),
          @default_interval_ms
        ),
      initial_delay_ms:
        non_negative_int(
          Keyword.get(opts, :initial_delay_ms, Keyword.get(app_cfg, :initial_delay_ms, 60_000)),
          60_000
        ),
      drain_limit:
        positive_int(
          Keyword.get(
            opts,
            :drain_limit,
            Keyword.get(app_cfg, :drain_limit, @default_drain_limit)
          ),
          @default_drain_limit
        ),
      run_opts: run_opts(opts, app_cfg)
    ]
  end

  defp run_opts(opts, app_cfg) do
    app_cfg
    |> Keyword.get(:run_opts, [])
    |> Keyword.merge(Keyword.get(opts, :run_opts, []))
    |> Keyword.merge(Keyword.take(opts, @drain_option_keys))
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value, default), do: default
end
