defmodule Mix.Tasks.Maxio.Scheduler.Retention do
  @shortdoc "Apply scheduler run ledger retention after verified rollups"
  @moduledoc """
  Plan or apply default-off scheduler run ledger retention.

      mix maxio.scheduler.retention --scheduler rebalance --trigger scheduled --retain-days 30 --dry-run --json
      mix maxio.scheduler.retention --scheduler rebalance --trigger scheduled --retain-days 30 --window-minutes 60 --dry-run

  Real pruning is an explicit operator action. It requires:

      --enable-retention --confirm-retention
      --confirm-scheduler <same> --confirm-trigger <same>
      --confirm-retain-days <same> --confirm-window-minutes <same>
      --confirm-cutoff <cutoff from dry-run>

  This task never creates rollups and never changes scheduler state. It delegates
  deletion to the verified scheduler prune path. `--now` is accepted only with
  `--dry-run` for deterministic planning and tests.
  """

  use Mix.Task

  alias Maxio.Cluster.SchedulerRuns

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          scheduler: :string,
          trigger: :string,
          retain_days: :integer,
          window_minutes: :integer,
          now: :string,
          enable_retention: :boolean,
          confirm_retention: :boolean,
          confirm_scheduler: :string,
          confirm_trigger: :string,
          confirm_retain_days: :integer,
          confirm_window_minutes: :integer,
          confirm_cutoff: :string,
          dry_run: :boolean,
          json: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.scheduler.retention --scheduler fresh_drive_heal|rebalance " <>
          "--trigger manual|scheduled --retain-days N [--window-minutes N] [--dry-run] " <>
          "[--now <iso8601>] " <>
          "[--enable-retention --confirm-retention --confirm-scheduler <scheduler> " <>
          "--confirm-trigger <trigger> --confirm-retain-days N --confirm-window-minutes N " <>
          "--confirm-cutoff <iso8601>] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    scheduler = required_scheduler!(Keyword.get(opts, :scheduler))
    trigger = required_trigger!(Keyword.get(opts, :trigger))
    retain_days = required_retain_days!(Keyword.get(opts, :retain_days))
    window_minutes = Keyword.get(opts, :window_minutes, 60)
    validate_window_minutes!(window_minutes)

    Mix.Task.run("app.start")

    now = parse_now(Keyword.get(opts, :now))

    retention_opts = [
      scheduler: scheduler,
      trigger: trigger,
      retain_days: retain_days,
      window_ms: window_minutes * 60 * 1_000,
      now: now,
      enabled: Keyword.get(opts, :enable_retention, false)
    ]

    result =
      if Keyword.get(opts, :dry_run, false) do
        SchedulerRuns.retention_plan(retention_opts)
      else
        validate_no_custom_now_for_prune!(opts)
        validate_confirmations!(opts, scheduler, trigger, retain_days, window_minutes)

        with {:ok, plan} <- SchedulerRuns.retention_plan(retention_opts) do
          validate_confirm_cutoff!(opts, plan.cutoff)
          SchedulerRuns.retention_prune(Keyword.put(retention_opts, :confirm?, true))
        end
      end

    case result do
      {:ok, report} ->
        report
        |> SchedulerRuns.retention_to_view()
        |> print_or_json(opts)

      {:error, reason} ->
        Mix.raise("scheduler retention failed: #{inspect(reason)}")
    end
  end

  defp print_or_json(report, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(report))
    else
      IO.puts(
        "[maxio scheduler.retention] status=#{report.status} dry_run?=#{report.dry_run?} " <>
          "enabled?=#{report.enabled?} ready?=#{report.ready?} scheduler=#{report.scheduler} " <>
          "trigger=#{report.trigger} retain_days=#{report.retain_days} cutoff=#{report.cutoff} " <>
          "from=#{report.from} until=#{report.until} window_ms=#{report.window_ms} " <>
          "windows=#{report.windows} candidate_runs=#{report.candidate_runs} " <>
          "pruned_runs=#{report.pruned_runs} blockers=#{length(Map.get(report, :blockers, []))} " <>
          "missing_rollups=#{length(Map.get(report, :missing_rollups, []))}"
      )

      Enum.each(Map.get(report, :missing_rollups, []), fn missing ->
        IO.puts(
          "[maxio scheduler.retention.missing_rollup] scheduler=#{missing.scheduler} " <>
            "trigger=#{missing.trigger} window_started_at=#{missing.window_started_at} " <>
            "window_finished_at=#{missing.window_finished_at} window_ms=#{missing.window_ms}"
        )
      end)

      Enum.each(Map.get(report, :blockers, []), fn blocker ->
        IO.puts("[maxio scheduler.retention.blocker] reason=#{inspect(blocker.reason)}")
      end)

      Enum.each(Map.get(report, :prunes, []), fn prune ->
        IO.puts(
          "[maxio scheduler.retention.prune_window] status=#{prune.status} " <>
            "scheduler=#{prune.scheduler} trigger=#{prune.trigger} " <>
            "window_started_at=#{prune.window_started_at} " <>
            "window_finished_at=#{prune.window_finished_at} runs=#{prune.run_count} " <>
            "candidate=#{prune.pruned_run_count} rollup_id=#{prune.rollup_id}"
        )
      end)
    end
  end

  defp required_scheduler!(nil), do: Mix.raise("--scheduler is required for retention")
  defp required_scheduler!("fresh_drive_heal"), do: "fresh_drive_heal"
  defp required_scheduler!("rebalance"), do: "rebalance"

  defp required_scheduler!(scheduler) do
    Mix.raise("--scheduler must be fresh_drive_heal or rebalance, got #{inspect(scheduler)}")
  end

  defp required_trigger!(nil), do: Mix.raise("--trigger is required for retention")
  defp required_trigger!("manual"), do: "manual"
  defp required_trigger!("scheduled"), do: "scheduled"

  defp required_trigger!(trigger) do
    Mix.raise("--trigger must be manual or scheduled, got #{inspect(trigger)}")
  end

  defp required_retain_days!(nil), do: Mix.raise("--retain-days is required for retention")
  defp required_retain_days!(value) when is_integer(value) and value > 0, do: value

  defp required_retain_days!(value) do
    Mix.raise("--retain-days must be a positive integer, got #{inspect(value)}")
  end

  defp validate_window_minutes!(value) when is_integer(value) and value > 0, do: :ok

  defp validate_window_minutes!(value) do
    Mix.raise("--window-minutes must be a positive integer, got #{inspect(value)}")
  end

  defp validate_confirmations!(opts, scheduler, trigger, retain_days, window_minutes) do
    unless Keyword.get(opts, :enable_retention, false) do
      Mix.raise("--enable-retention is required unless --dry-run is set")
    end

    unless Keyword.get(opts, :confirm_retention, false) do
      Mix.raise("--confirm-retention is required unless --dry-run is set")
    end

    unless Keyword.get(opts, :confirm_scheduler) == scheduler do
      Mix.raise("--confirm-scheduler must match --scheduler")
    end

    unless Keyword.get(opts, :confirm_trigger) == trigger do
      Mix.raise("--confirm-trigger must match --trigger")
    end

    unless Keyword.get(opts, :confirm_retain_days) == retain_days do
      Mix.raise("--confirm-retain-days must match --retain-days")
    end

    unless Keyword.get(opts, :confirm_window_minutes) == window_minutes do
      Mix.raise("--confirm-window-minutes must match --window-minutes")
    end
  end

  defp validate_no_custom_now_for_prune!(opts) do
    if Keyword.has_key?(opts, :now) do
      Mix.raise("--now is only allowed with --dry-run")
    end
  end

  defp validate_confirm_cutoff!(opts, cutoff) do
    confirm_cutoff = parse_datetime!(Keyword.get(opts, :confirm_cutoff), "--confirm-cutoff")

    unless DateTime.compare(confirm_cutoff, cutoff) == :eq do
      Mix.raise("--confirm-cutoff must match the computed retention cutoff")
    end
  end

  defp parse_now(nil), do: DateTime.utc_now()
  defp parse_now(value), do: parse_datetime!(value, "--now")

  defp parse_datetime!(nil, flag), do: Mix.raise("#{flag} is required")

  defp parse_datetime!(value, flag) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, 0} -> dt
      {:ok, _dt, _offset} -> Mix.raise("#{flag} must be UTC ISO8601 with Z offset")
      {:error, reason} -> Mix.raise("#{flag} must be ISO8601 datetime: #{inspect(reason)}")
    end
  end
end
