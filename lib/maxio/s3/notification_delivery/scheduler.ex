defmodule Maxio.S3.NotificationDelivery.Scheduler do
  @moduledoc """
  Config-gated retry scheduler for the durable S3 bucket notification outbox.

  This process is only an orchestration wrapper around
  `Maxio.S3.NotificationDelivery.drain/1`. It does not construct notification
  events, inspect object bytes, or mutate S3 objects.
  """

  use GenServer

  alias Maxio.S3.{Log, NotificationDelivery}

  @default_interval_ms 60_000
  @default_drain_limit 100

  @drain_option_keys [
    :deliverer,
    :repo,
    :now,
    :limit,
    :lease_ms,
    :failure_backoff_ms
  ]

  @type run_result :: {:ok, map()} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Drain due notification outbox rows once through the scheduler process."
  @spec run_now(keyword()) :: run_result()
  def run_now(opts \\ []), do: run_now(__MODULE__, opts)

  @doc "Drain due notification outbox rows once through `server`."
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
      last_result: nil
    }

    if cfg[:enabled] do
      Log.info("bucket notification outbox scheduler enabled",
        action: :bucket_notification_delivery,
        reason: "initial_delay_ms=#{cfg[:initial_delay_ms]} interval_ms=#{cfg[:interval_ms]}"
      )

      {:ok, schedule(state, cfg[:initial_delay_ms])}
    else
      Log.info("bucket notification outbox scheduler disabled",
        action: :bucket_notification_delivery,
        reason: "enable via config :maxio, :notification_delivery_scheduler, enabled: true"
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
       last_result: state.last_result
     }, state}
  end

  @impl true
  def handle_info(:drain, %{enabled: true} = state) do
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
    result = safe_drain(cfg, trigger)
    {result, %{state | last_result: result}}
  end

  defp safe_drain(cfg, trigger) do
    drain_opts =
      cfg[:run_opts]
      |> Keyword.put_new(:limit, cfg[:drain_limit])

    case NotificationDelivery.drain(drain_opts) do
      {:ok, summary} = result when is_map(summary) ->
        log_drain_summary(summary, trigger)
        result

      {:error, reason} = result ->
        Log.warn("bucket notification outbox scheduler drain failed",
          action: :bucket_notification_delivery,
          reason: inspect({trigger, reason})
        )

        result

      other ->
        Log.warn("bucket notification outbox scheduler returned unexpected result",
          action: :bucket_notification_delivery,
          reason: inspect({trigger, other})
        )

        {:error, {:bad_drain_result, other}}
    end
  rescue
    error ->
      reason = Exception.message(error)

      Log.error("bucket notification outbox scheduler crashed",
        action: :bucket_notification_delivery,
        reason: inspect({trigger, reason})
      )

      {:error, {:crashed, reason}}
  catch
    kind, reason ->
      Log.error("bucket notification outbox scheduler caught",
        action: :bucket_notification_delivery,
        reason: inspect({trigger, kind, reason})
      )

      {:error, {:caught, kind, reason}}
  end

  defp log_drain_summary(summary, trigger) do
    Log.info("bucket notification outbox scheduler drain complete",
      action: :bucket_notification_delivery,
      reason:
        "trigger=#{trigger} claimed=#{Map.get(summary, :claimed, 0)} " <>
          "delivered=#{Map.get(summary, :delivered, 0)} failed=#{Map.get(summary, :failed, 0)}"
    )
  end

  defp schedule(state, delay_ms) do
    cancel_timer(state.timer_ref)
    %{state | timer_ref: Process.send_after(self(), :drain, max(delay_ms, 0))}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: _ = Process.cancel_timer(ref)

  defp config(opts) do
    app_cfg = Application.get_env(:maxio, :notification_delivery_scheduler, [])

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
