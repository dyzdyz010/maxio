defmodule Maxio.Console.DirectMultipartUpload.Scheduler do
  @moduledoc """
  Config-gated maintenance scheduler for Console browser-direct MPU registry rows.

  The scheduler is an orchestration wrapper around
  `Maxio.Console.DirectMultipartUpload.prune_active/1`. It does not read object
  bytes and it does not invent another abort path; actual mutation still goes
  through the S3 multipart abort authority.
  """

  use GenServer

  alias Maxio.Console.DirectMultipartUpload
  alias Maxio.S3.Log

  @default_interval_ms 3_600_000
  @default_initial_delay_ms 60_000
  @default_older_than_seconds 86_400
  @default_limit 100

  @prune_option_keys [
    :now,
    :bucket,
    :prefix,
    :scope,
    :query,
    :principal_arn,
    :access_key,
    :all_owners,
    :older_than_seconds,
    :min_file_size,
    :max_file_size,
    :limit,
    :dry_run,
    :confirm_abort
  ]

  @type run_result :: {:ok, DirectMultipartUpload.prune_summary()} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Run one direct MPU prune pass through the default scheduler."
  @spec run_now(keyword()) :: run_result()
  def run_now(opts \\ []), do: run_now(__MODULE__, opts)

  @doc "Run one direct MPU prune pass through `server`."
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
      last_result: nil
    }

    if cfg[:enabled] do
      Log.info("console direct multipart prune scheduler enabled",
        action: :console_direct_multipart_prune,
        reason:
          "initial_delay_ms=#{cfg[:initial_delay_ms]} interval_ms=#{cfg[:interval_ms]} " <>
            "dry_run=#{cfg[:dry_run]}"
      )

      {:ok, schedule(state, cfg[:initial_delay_ms])}
    else
      Log.info("console direct multipart prune scheduler disabled",
        action: :console_direct_multipart_prune,
        reason: "enable via config :maxio, :console_direct_multipart_pruner, enabled: true"
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
  def handle_info({:prune, token}, %{enabled: true, timer_token: token} = state)
      when is_reference(token) do
    cancel_timer(state.timer_ref)
    {result, state} = run_cycle(%{state | timer_ref: nil, timer_token: nil}, [], :scheduled)
    {:noreply, schedule(%{state | last_result: result}, state.interval_ms)}
  end

  def handle_info({:prune, _stale_token}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)
    :ok
  end

  defp run_cycle(state, opts, trigger) do
    cfg = config(Keyword.merge(state.base_opts, opts))
    result = safe_prune(cfg, trigger)
    {result, %{state | last_result: result}}
  end

  defp safe_prune(cfg, trigger) do
    prune_opts =
      cfg[:run_opts]
      |> Keyword.put_new(:older_than_seconds, cfg[:older_than_seconds])
      |> Keyword.put_new(:limit, cfg[:limit])
      |> Keyword.put_new(:dry_run, cfg[:dry_run])
      |> Keyword.put_new(:confirm_abort, cfg[:confirm_abort])
      |> put_default_all_owners(cfg[:all_owners])

    case DirectMultipartUpload.prune_active(prune_opts) do
      {:ok, summary} = result when is_map(summary) ->
        log_prune_summary(summary, trigger)
        result

      {:error, reason} = result ->
        Log.warn("console direct multipart prune scheduler failed",
          action: :console_direct_multipart_prune,
          reason: inspect({trigger, reason})
        )

        result

      other ->
        Log.warn("console direct multipart prune scheduler returned unexpected result",
          action: :console_direct_multipart_prune,
          reason: inspect({trigger, other})
        )

        {:error, {:bad_prune_result, other}}
    end
  rescue
    error ->
      reason = Exception.message(error)

      Log.error("console direct multipart prune scheduler crashed",
        action: :console_direct_multipart_prune,
        reason: inspect({trigger, reason})
      )

      {:error, {:crashed, reason}}
  catch
    kind, reason ->
      Log.error("console direct multipart prune scheduler caught",
        action: :console_direct_multipart_prune,
        reason: inspect({trigger, kind, reason})
      )

      {:error, {:caught, kind, reason}}
  end

  defp log_prune_summary(summary, trigger) do
    Log.info("console direct multipart prune scheduler pass complete",
      action: :console_direct_multipart_prune,
      reason:
        "trigger=#{trigger} dry_run=#{summary.dry_run} matched=#{summary.matched} " <>
          "selected=#{summary.selected} would_abort=#{summary.would_abort} " <>
          "aborted=#{summary.aborted} not_found=#{summary.not_found} " <>
          "failed=#{summary.failed} skipped=#{summary.skipped}"
    )
  end

  defp schedule(state, delay_ms) do
    cancel_timer(state.timer_ref)
    token = make_ref()

    %{
      state
      | timer_ref: Process.send_after(self(), {:prune, token}, max(delay_ms, 0)),
        timer_token: token
    }
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: _ = Process.cancel_timer(ref)

  defp put_default_all_owners(opts, all_owners) do
    if Keyword.has_key?(opts, :all_owners) or Keyword.has_key?(opts, :principal_arn) or
         Keyword.has_key?(opts, :access_key) do
      opts
    else
      Keyword.put(opts, :all_owners, all_owners)
    end
  end

  defp config(opts) do
    app_cfg = Application.get_env(:maxio, :console_direct_multipart_pruner, [])

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
          Keyword.get(
            opts,
            :initial_delay_ms,
            Keyword.get(app_cfg, :initial_delay_ms, @default_initial_delay_ms)
          ),
          @default_initial_delay_ms
        ),
      older_than_seconds:
        positive_int(
          Keyword.get(
            opts,
            :older_than_seconds,
            Keyword.get(app_cfg, :older_than_seconds, @default_older_than_seconds)
          ),
          @default_older_than_seconds
        ),
      limit:
        positive_int(
          Keyword.get(opts, :limit, Keyword.get(app_cfg, :limit, @default_limit)),
          @default_limit
        ),
      dry_run: truthy?(Keyword.get(opts, :dry_run, Keyword.get(app_cfg, :dry_run, true))),
      confirm_abort:
        truthy?(Keyword.get(opts, :confirm_abort, Keyword.get(app_cfg, :confirm_abort, false))),
      all_owners:
        truthy?(Keyword.get(opts, :all_owners, Keyword.get(app_cfg, :all_owners, true))),
      run_opts: run_opts(opts, app_cfg)
    ]
  end

  defp run_opts(opts, app_cfg) do
    app_cfg
    |> Keyword.get(:run_opts, [])
    |> Keyword.merge(Keyword.get(opts, :run_opts, []))
    |> Keyword.merge(Keyword.take(opts, @prune_option_keys))
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value, default), do: default

  defp truthy?(value) when value in [true, "true", "1", 1, true], do: true
  defp truthy?(_value), do: false
end
