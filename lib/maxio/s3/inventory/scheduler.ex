defmodule Maxio.S3.Inventory.Scheduler do
  @moduledoc """
  Config-gated scheduler for S3 Inventory report generation.

  The scheduler is disabled by default. When enabled it periodically calls
  `Maxio.S3.Inventory.Runner.run_due/1`, which uses the persistent report-run
  ledger to keep each `{bucket, inventory_id, report_date}` idempotent.
  """

  use GenServer

  alias Maxio.Cluster.Lock
  alias Maxio.S3.Inventory.Runner
  alias Maxio.S3.Log

  @default_interval_ms 3_600_000
  @default_initial_delay_ms 60_000
  @default_lease_ms 3_600_000
  @lock_resource {:s3_inventory_scheduler, :run_due}

  @run_option_keys [
    :bucket,
    :id,
    :now,
    :report_date,
    :lease_ms,
    :dry_run,
    :max_keys,
    :tmp_dir,
    :storage_opts
  ]

  @type run_result :: {:ok, map()} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Run one due Inventory schedule pass through the default scheduler."
  @spec run_now(keyword()) :: run_result()
  def run_now(opts \\ []), do: run_now(__MODULE__, opts)

  @doc "Run one due Inventory schedule pass through `server`."
  @spec run_now(GenServer.server(), keyword()) :: run_result()
  def run_now(server, opts) when is_list(opts),
    do: GenServer.call(server, {:run_now, opts}, :infinity)

  @doc "Return scheduler runtime status and latest result."
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
      running?: false,
      run_ref: nil,
      run_pid: nil,
      run_monitor: nil,
      pending: nil,
      last_result: nil
    }

    if cfg[:enabled] do
      Log.info("inventory report scheduler enabled",
        action: :inventory_report_scheduler,
        reason: "initial_delay_ms=#{cfg[:initial_delay_ms]} interval_ms=#{cfg[:interval_ms]}"
      )

      {:ok, schedule(state, cfg[:initial_delay_ms])}
    else
      Log.info("inventory report scheduler disabled",
        action: :inventory_report_scheduler,
        reason: "enable via config :maxio, :inventory_report_scheduler, enabled: true"
      )

      {:ok, state}
    end
  end

  @impl true
  def handle_call({:run_now, opts}, from, state) do
    case start_run(state, opts, :manual, {:reply, from}) do
      {:ok, state} -> {:noreply, state}
      {:error, result, state} -> {:reply, result, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled: state.enabled,
       interval_ms: state.interval_ms,
       scheduled?: not is_nil(state.timer_ref),
       running?: state.running?,
       last_result: state.last_result
     }, state}
  end

  @impl true
  def handle_info({:run_due, token}, %{enabled: true, timer_token: token} = state)
      when is_reference(token) do
    cancel_timer(state.timer_ref)
    state = %{state | timer_ref: nil, timer_token: nil}

    case start_run(state, [], :scheduled, :reschedule) do
      {:ok, state} ->
        {:noreply, state}

      {:error, result, state} ->
        {:noreply, schedule(%{state | last_result: result}, state.interval_ms)}
    end
  end

  def handle_info({:run_finished, ref, result}, %{run_ref: ref} = state) do
    demonitor_run(state.run_monitor)
    {:noreply, finish_run(state, result)}
  end

  def handle_info({:run_finished, _stale_ref, _result}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{run_monitor: monitor, run_pid: pid} = state
      ) do
    {:noreply, finish_run(state, {:error, {:worker_down, reason}})}
  end

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:run_due, _stale_token}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)
    stop_run(state.run_pid)
    :ok
  end

  defp start_run(%{running?: true} = state, _opts, trigger, _pending) do
    result = {:error, {:already_running, trigger}}
    {:error, result, %{state | last_result: result}}
  end

  defp start_run(state, opts, trigger, pending) do
    cfg = config(Keyword.merge(state.base_opts, opts))
    ref = make_ref()
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:run_finished, ref, safe_run(cfg, trigger)})
      end)

    monitor = Process.monitor(pid)

    {:ok,
     %{
       state
       | running?: true,
         run_ref: ref,
         run_pid: pid,
         run_monitor: monitor,
         pending: pending
     }}
  end

  defp safe_run(cfg, trigger) do
    run_opts =
      cfg[:run_opts]
      |> Keyword.merge(Keyword.take(cfg[:raw_opts], @run_option_keys))
      |> Keyword.put_new(:lease_ms, cfg[:lease_ms])
      |> Keyword.put(:trigger, trigger)

    result =
      if cfg[:singleton?] do
        locked_run(cfg, run_opts)
      else
        {:ok, cfg[:runner].(run_opts)}
      end

    case result do
      {:ok, summary} when is_map(summary) ->
        log_summary(summary, trigger)
        {:ok, summary}

      {:error, reason} = error ->
        Log.warn("inventory report scheduler failed",
          action: :inventory_report_scheduler,
          reason: inspect({trigger, reason})
        )

        error

      other ->
        Log.warn("inventory report scheduler returned unexpected result",
          action: :inventory_report_scheduler,
          reason: inspect({trigger, other})
        )

        {:error, {:bad_runner_result, other}}
    end
  rescue
    error ->
      reason = Exception.message(error)

      Log.error("inventory report scheduler crashed",
        action: :inventory_report_scheduler,
        reason: inspect({trigger, reason})
      )

      {:error, {:crashed, reason}}
  catch
    kind, reason ->
      Log.error("inventory report scheduler caught",
        action: :inventory_report_scheduler,
        reason: inspect({trigger, kind, reason})
      )

      {:error, {:caught, kind, reason}}
  end

  defp locked_run(cfg, run_opts) do
    case Lock.quorum_with_lock(@lock_resource, fn -> cfg[:runner].(run_opts) end, cfg[:lock_opts]) do
      {:ok, summary} ->
        {:ok, summary}

      {:error, :no_quorum} ->
        Log.warn("inventory report scheduler skipped because singleton lock is held",
          action: :inventory_report_scheduler,
          reason: "resource=#{inspect(@lock_resource)}"
        )

        {:error, :lock_unavailable}
    end
  end

  defp log_summary(summary, trigger) do
    Log.info("inventory report scheduler pass complete",
      action: :inventory_report_scheduler,
      reason:
        "trigger=#{trigger} buckets=#{Map.get(summary, :buckets_scanned, 0)} " <>
          "due=#{Map.get(summary, :configs_due, 0)} claims=#{Map.get(summary, :claims_created, 0)} " <>
          "completed_skips=#{Map.get(summary, :claims_skipped_completed, 0)} " <>
          "running_skips=#{Map.get(summary, :claims_skipped_running, 0)} " <>
          "written=#{Map.get(summary, :reports_written, 0)} " <>
          "rows=#{Map.get(summary, :rows_written, 0)} errors=#{length(Map.get(summary, :errors, []))}"
    )
  end

  defp schedule(state, delay_ms) do
    cancel_timer(state.timer_ref)
    token = make_ref()

    %{
      state
      | timer_ref: Process.send_after(self(), {:run_due, token}, max(delay_ms, 0)),
        timer_token: token
    }
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: _ = Process.cancel_timer(ref)

  defp stop_run(nil), do: :ok

  defp stop_run(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown), else: :ok
  end

  defp demonitor_run(nil), do: :ok
  defp demonitor_run(ref), do: Process.demonitor(ref, [:flush])

  defp finish_run(state, result) do
    pending = state.pending

    if match?({:reply, _from}, pending) do
      {:reply, from} = pending
      GenServer.reply(from, result)
    end

    state = %{
      state
      | running?: false,
        run_ref: nil,
        run_pid: nil,
        run_monitor: nil,
        pending: nil,
        last_result: result
    }

    if pending == :reschedule and state.enabled do
      schedule(state, state.interval_ms)
    else
      state
    end
  end

  defp config(opts) do
    app_cfg = Application.get_env(:maxio, :inventory_report_scheduler, [])

    raw_opts = Keyword.merge(app_cfg, opts)

    [
      raw_opts: raw_opts,
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
          Keyword.get(
            opts,
            :initial_delay_ms,
            Keyword.get(app_cfg, :initial_delay_ms, @default_initial_delay_ms)
          ),
          @default_initial_delay_ms
        ),
      lease_ms:
        positive_int(
          Keyword.get(opts, :lease_ms, Keyword.get(app_cfg, :lease_ms, @default_lease_ms)),
          @default_lease_ms
        ),
      singleton?: Keyword.get(opts, :singleton?, Keyword.get(app_cfg, :singleton?, true)),
      lock_opts: Keyword.get(opts, :lock_opts, Keyword.get(app_cfg, :lock_opts, [])),
      run_opts:
        app_cfg
        |> Keyword.get(:run_opts, [])
        |> Keyword.merge(Keyword.get(opts, :run_opts, [])),
      runner: Keyword.get(opts, :runner, &Runner.run_due/1)
    ]
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value, default), do: default
end
