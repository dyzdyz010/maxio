defmodule Maxio.IAM.SigningSecretRotation.Scheduler do
  @moduledoc """
  Config-gated automatic IAM signing-secret key rotation.

  The scheduler is disabled by default. Even when enabled, actual mutation
  requires `confirm_rotation: true`; otherwise scheduled runs remain dry-runs
  and only report what would rotate.
  """

  use GenServer

  alias Maxio.IAM.SigningSecretRotation
  alias Maxio.S3.Log

  @default_interval_ms 3_600_000
  @default_initial_delay_ms 60_000
  @default_rotate_after_seconds 86_400 * 90

  # 轮换未落地的终态：任何一个都意味着密钥没换成，必须走 error 级日志。
  @failure_statuses [:blocked, :rewrap_blocked, :crashed, :caught, :bad_rotation_result]

  @option_keys [
    :keyring_file,
    :rotate_after_seconds,
    :key_id,
    :key_b64,
    :rewrap,
    :force,
    :now
  ]

  @type run_result ::
          {:ok, SigningSecretRotation.report()} | {:error, SigningSecretRotation.report()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec run_now(keyword()) :: run_result()
  def run_now(opts \\ []), do: run_now(__MODULE__, opts)

  @spec run_now(GenServer.server(), keyword()) :: run_result()
  def run_now(server, opts) when is_list(opts),
    do: GenServer.call(server, {:run_now, opts}, :infinity)

  @spec status() :: map()
  def status, do: status(__MODULE__)

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
      last_result: nil
    }

    if cfg[:enabled] do
      Log.info("iam signing secret rotation scheduler enabled",
        action: :iam_signing_secret_rotation,
        reason:
          "initial_delay_ms=#{cfg[:initial_delay_ms]} interval_ms=#{cfg[:interval_ms]} " <>
            "confirm_rotation=#{cfg[:confirm_rotation]}"
      )

      {:ok, schedule(state, cfg[:initial_delay_ms])}
    else
      Log.info("iam signing secret rotation scheduler disabled",
        action: :iam_signing_secret_rotation,
        reason: "enable via config :maxio, :iam_signing_secret_rotation, enabled: true"
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
  def handle_info({:rotate, token}, %{enabled: true, timer_token: token} = state)
      when is_reference(token) do
    cancel_timer(state.timer_ref)
    {result, state} = run_cycle(%{state | timer_ref: nil, timer_token: nil}, [], :scheduled)
    {:noreply, schedule(%{state | last_result: result}, state.interval_ms)}
  end

  def handle_info({:rotate, _stale_token}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)
    :ok
  end

  defp run_cycle(state, opts, trigger) do
    cfg = config(Keyword.merge(state.base_opts, opts))
    result = safe_rotate(cfg, trigger)
    {result, %{state | last_result: result}}
  end

  defp safe_rotate(cfg, trigger) do
    rotate_opts =
      cfg[:run_opts]
      |> Keyword.put_new(:rotate_after_seconds, cfg[:rotate_after_seconds])
      |> Keyword.put(:dry_run, not cfg[:confirm_rotation])
      |> Keyword.put_new(:rewrap, cfg[:rewrap])
      |> Keyword.put_new(:trigger, trigger)

    case cfg[:runner].(rotate_opts) do
      {:ok, report} = result ->
        log_report(report, trigger, :ok)
        result

      {:error, report} = result when is_map(report) ->
        log_report(report, trigger, :error)
        result

      other ->
        Log.warn("iam signing secret rotation scheduler returned unexpected result",
          action: :iam_signing_secret_rotation,
          reason: inspect({trigger, other})
        )

        {:error, %{status: :bad_rotation_result, errors: [other]}}
    end
  rescue
    error ->
      reason = Exception.message(error)

      Log.error("iam signing secret rotation scheduler crashed",
        action: :iam_signing_secret_rotation,
        reason: inspect({trigger, reason})
      )

      {:error, %{status: :crashed, errors: [reason]}}
  catch
    kind, reason ->
      Log.error("iam signing secret rotation scheduler caught",
        action: :iam_signing_secret_rotation,
        reason: inspect({trigger, kind, reason})
      )

      {:error, %{status: :caught, errors: [{kind, reason}]}}
  end

  # 调度器是生产环境唯一的自动轮换路径：失败（含磁盘写满 / 权限错误）必须以 error 级别
  # 连同**完整根因**出现在日志里，绝不能与成功报告一样降级成 info + 计数（AGENTS.md §3/§4.4）。
  defp log_report(report, trigger, outcome) do
    fields = [
      action: :iam_signing_secret_rotation,
      reason:
        "trigger=#{trigger} status=#{Map.get(report, :status)} dry_run=#{Map.get(report, :dry_run)} " <>
          "previous_key_id=#{inspect(Map.get(report, :previous_key_id))} " <>
          "next_key_id=#{inspect(Map.get(report, :next_key_id))} " <>
          "errors=#{inspect(Map.get(report, :errors, []))}"
    ]

    message = "iam signing secret rotation scheduler pass complete"

    if failed?(outcome, report) do
      Log.error(message, fields)
    else
      Log.info(message, fields)
    end
  end

  defp failed?(:error, _report), do: true

  defp failed?(_outcome, report),
    do: Map.get(report, :status) in @failure_statuses or Map.get(report, :errors, []) != []

  defp schedule(state, delay_ms) do
    cancel_timer(state.timer_ref)
    token = make_ref()

    %{
      state
      | timer_ref: Process.send_after(self(), {:rotate, token}, max(delay_ms, 0)),
        timer_token: token
    }
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: _ = Process.cancel_timer(ref)

  defp config(opts) do
    app_cfg = Application.get_env(:maxio, :iam_signing_secret_rotation, [])

    [
      enabled: truthy?(Keyword.get(opts, :enabled, Keyword.get(app_cfg, :enabled, false))),
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
      rotate_after_seconds:
        positive_int(
          Keyword.get(
            opts,
            :rotate_after_seconds,
            Keyword.get(app_cfg, :rotate_after_seconds, @default_rotate_after_seconds)
          ),
          @default_rotate_after_seconds
        ),
      confirm_rotation:
        truthy?(
          Keyword.get(opts, :confirm_rotation, Keyword.get(app_cfg, :confirm_rotation, false))
        ),
      rewrap: truthy?(Keyword.get(opts, :rewrap, Keyword.get(app_cfg, :rewrap, true))),
      runner: Keyword.get(opts, :runner, &SigningSecretRotation.rotate_if_due/1),
      run_opts: run_opts(opts, app_cfg)
    ]
  end

  defp run_opts(opts, app_cfg) do
    app_cfg
    |> Keyword.get(:run_opts, [])
    |> Keyword.merge(Keyword.get(opts, :run_opts, []))
    |> Keyword.merge(Keyword.take(opts, @option_keys))
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value, default), do: default

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false
end
