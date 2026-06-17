defmodule Maxio.Lifecycle.Scheduler do
  @moduledoc """
  Periodic S3 lifecycle scheduler.

  The scheduler is disabled by default and shares the same deterministic executor as
  `mix maxio.lifecycle.run`: `Maxio.Lifecycle.run/1`. Transition actions remain explicit
  no-ops in the executor until tiering backends exist.
  """
  use GenServer

  alias Maxio.S3.Log

  @default_interval_ms 86_400_000

  @type run_result :: {:ok, Maxio.Lifecycle.summary()} | {:error, String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Run one lifecycle sweep through the scheduler process."
  @spec run_now(GenServer.server()) :: run_result()
  def run_now(server \\ __MODULE__), do: GenServer.call(server, :run_now, :infinity)

  @impl true
  def init(opts) do
    cfg = config(opts)

    state = %{
      enabled: cfg[:enabled],
      interval_ms: cfg[:interval_ms],
      run_opts: cfg[:run_opts],
      runner: cfg[:runner],
      timer_ref: nil,
      last_result: nil
    }

    if state.enabled do
      Log.info(
        "lifecycle scheduler enabled: periodic sweeps scheduled " <>
          "(initial_delay_ms=#{cfg[:initial_delay_ms]} interval_ms=#{state.interval_ms})",
        action: :lifecycle
      )

      {:ok, schedule_after(state, cfg[:initial_delay_ms])}
    else
      Log.info(
        "lifecycle scheduler disabled: periodic sweeps NOT scheduled " <>
          "(enable via config :maxio, :lifecycle_scheduler, enabled: true)",
        action: :lifecycle
      )

      {:ok, state}
    end
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    result = safe_run(state.runner, state.run_opts)
    {:reply, result, %{state | last_result: result}}
  end

  @impl true
  def handle_info(:sweep, %{enabled: true} = state) do
    result = safe_run(state.runner, state.run_opts)

    state =
      state
      |> Map.put(:last_result, result)
      |> schedule_after(state.interval_ms)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)
    :ok
  end

  defp safe_run(runner, run_opts) do
    summary = runner.(run_opts)
    log_summary(summary)
    {:ok, summary}
  rescue
    error ->
      reason = Exception.message(error)
      Log.error("lifecycle scheduled sweep crashed", action: :lifecycle, reason: reason)
      {:error, reason}
  catch
    kind, reason ->
      formatted = inspect({kind, reason})
      Log.error("lifecycle scheduled sweep caught", action: :lifecycle, reason: formatted)
      {:error, formatted}
  end

  defp log_summary(%{} = summary) do
    Log.info(
      "lifecycle scheduled sweep complete: buckets=#{Map.get(summary, :buckets_scanned, 0)} " <>
        "objects=#{Map.get(summary, :objects_expired, 0)} " <>
        "noncurrent=#{Map.get(summary, :noncurrent_versions_expired, 0)} " <>
        "markers=#{Map.get(summary, :delete_markers_removed, 0)} " <>
        "multipart=#{Map.get(summary, :multipart_uploads_aborted, 0)} " <>
        "mfa_skipped=#{Map.get(summary, :mfa_delete_protected_actions_skipped, 0)} " <>
        "object_lock_skipped=#{Map.get(summary, :object_lock_protected_actions_skipped, 0)} " <>
        "unsupported=#{Map.get(summary, :unsupported_rules, 0)} " <>
        "errors=#{length(Map.get(summary, :errors, []))}",
      action: :lifecycle
    )
  end

  defp log_summary(other) do
    Log.warn("lifecycle scheduled sweep returned unexpected result",
      action: :lifecycle,
      reason: inspect(other)
    )
  end

  defp schedule_after(state, delay_ms) do
    cancel_timer(state.timer_ref)
    %{state | timer_ref: Process.send_after(self(), :sweep, delay_ms)}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: _ = Process.cancel_timer(ref)

  defp config(opts) do
    app_cfg = Application.get_env(:maxio, :lifecycle_scheduler, [])

    interval_ms =
      opts
      |> Keyword.get(:interval_ms, Keyword.get(app_cfg, :interval_ms, @default_interval_ms))
      |> positive_integer(@default_interval_ms)

    [
      enabled: Keyword.get(opts, :enabled, Keyword.get(app_cfg, :enabled, false)),
      interval_ms: interval_ms,
      initial_delay_ms:
        opts
        |> Keyword.get(:initial_delay_ms, Keyword.get(app_cfg, :initial_delay_ms, interval_ms))
        |> positive_integer(interval_ms),
      run_opts:
        app_cfg
        |> Keyword.get(:run_opts, [])
        |> Keyword.merge(Keyword.get(opts, :run_opts, [])),
      runner: Keyword.get(opts, :runner, &Maxio.Lifecycle.run/1)
    ]
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
