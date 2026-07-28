defmodule Maxio.IAM.OIDCProviderRefresh.Scheduler do
  @moduledoc """
  Config-gated scheduler for persisted IAM OIDC provider JWKS refresh.

  The scheduler is disabled by default. When enabled, scheduled and manual
  scheduler runs remain dry-runs unless `confirm_refresh: true` is set, so
  operators can observe discovery/JWKS health before allowing background writes.
  """

  use GenServer

  alias Maxio.IAM.OIDCProviderRefresh
  alias Maxio.S3.Log

  @default_interval_ms 3_600_000
  @default_initial_delay_ms 60_000
  @default_limit 100
  @default_refresh_after_seconds 86_400

  @option_keys [
    :discoverer,
    :discovery_opts,
    :include_disabled,
    :limit,
    :now,
    :refresh_after_seconds
  ]

  @type run_result :: {:ok, OIDCProviderRefresh.report()} | {:error, OIDCProviderRefresh.report()}

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
      Log.info("iam oidc provider jwks refresh scheduler enabled",
        action: :iam_oidc_provider_jwks_refresh,
        reason:
          "initial_delay_ms=#{cfg[:initial_delay_ms]} interval_ms=#{cfg[:interval_ms]} " <>
            "confirm_refresh=#{cfg[:confirm_refresh]}"
      )

      {:ok, schedule(state, cfg[:initial_delay_ms])}
    else
      Log.info("iam oidc provider jwks refresh scheduler disabled",
        action: :iam_oidc_provider_jwks_refresh,
        reason: "enable via config :maxio, :iam_oidc_provider_jwks_refresh, enabled: true"
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
  def handle_info(
        {:refresh_oidc_provider_jwks, token},
        %{enabled: true, timer_token: token} = state
      )
      when is_reference(token) do
    cancel_timer(state.timer_ref)
    {result, state} = run_cycle(%{state | timer_ref: nil, timer_token: nil}, [], :scheduled)
    {:noreply, schedule(%{state | last_result: result}, state.interval_ms)}
  end

  def handle_info({:refresh_oidc_provider_jwks, _stale_token}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)
    :ok
  end

  defp run_cycle(state, opts, trigger) do
    cfg = config(Keyword.merge(state.base_opts, opts))
    result = safe_refresh(cfg, trigger)
    {result, %{state | last_result: result}}
  end

  defp safe_refresh(cfg, trigger) do
    refresh_opts =
      cfg[:run_opts]
      |> Keyword.put_new(:limit, cfg[:limit])
      |> Keyword.put_new(:refresh_after_seconds, cfg[:refresh_after_seconds])
      |> Keyword.put(:dry_run, not cfg[:confirm_refresh])
      |> Keyword.put_new(:trigger, trigger)

    case cfg[:runner].(refresh_opts) do
      {:ok, report} = result when is_map(report) ->
        log_report(report, trigger)
        result

      {:error, report} = result when is_map(report) ->
        log_report(report, trigger)
        result

      other ->
        Log.warn("iam oidc provider jwks refresh scheduler returned unexpected result",
          action: :iam_oidc_provider_jwks_refresh,
          reason: inspect({trigger, other})
        )

        {:error, %{status: :bad_refresh_result, errors: [other]}}
    end
  rescue
    error ->
      reason = Exception.message(error)

      Log.error("iam oidc provider jwks refresh scheduler crashed",
        action: :iam_oidc_provider_jwks_refresh,
        reason: inspect({trigger, reason})
      )

      {:error, %{status: :crashed, errors: [reason]}}
  catch
    kind, reason ->
      Log.error("iam oidc provider jwks refresh scheduler caught",
        action: :iam_oidc_provider_jwks_refresh,
        reason: inspect({trigger, kind, reason})
      )

      {:error, %{status: :caught, errors: [{kind, reason}]}}
  end

  defp log_report(report, trigger) do
    Log.info("iam oidc provider jwks refresh scheduler pass complete",
      action: :iam_oidc_provider_jwks_refresh,
      reason:
        "trigger=#{trigger} status=#{Map.get(report, :status)} dry_run=#{Map.get(report, :dry_run)} " <>
          "scanned=#{Map.get(report, :scanned, 0)} candidates=#{Map.get(report, :candidates, 0)} " <>
          "refreshed=#{Map.get(report, :refreshed, 0)} failed=#{Map.get(report, :failed, 0)}"
    )
  end

  defp schedule(state, delay_ms) do
    cancel_timer(state.timer_ref)
    token = make_ref()

    %{
      state
      | timer_ref:
          Process.send_after(self(), {:refresh_oidc_provider_jwks, token}, max(delay_ms, 0)),
        timer_token: token
    }
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: _ = Process.cancel_timer(ref)

  defp config(opts) do
    app_cfg = Application.get_env(:maxio, :iam_oidc_provider_jwks_refresh, [])

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
      confirm_refresh:
        truthy?(
          Keyword.get(opts, :confirm_refresh, Keyword.get(app_cfg, :confirm_refresh, false))
        ),
      limit:
        positive_int(
          Keyword.get(opts, :limit, Keyword.get(app_cfg, :limit, @default_limit)),
          @default_limit
        ),
      refresh_after_seconds:
        positive_int(
          Keyword.get(
            opts,
            :refresh_after_seconds,
            Keyword.get(app_cfg, :refresh_after_seconds, @default_refresh_after_seconds)
          ),
          @default_refresh_after_seconds
        ),
      runner: Keyword.get(opts, :runner, &OIDCProviderRefresh.refresh_all/1),
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
