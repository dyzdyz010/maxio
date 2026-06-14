defmodule Mix.Tasks.Maxio.Scheduler.Prune do
  @shortdoc "Prune scheduler run rows after verified durable rollups"
  @moduledoc """
  Prune raw scheduler run ledger rows only after matching durable rollups exist.

      mix maxio.scheduler.prune --from 2026-06-14T00:00:00Z --until 2026-06-14T02:00:00Z
      mix maxio.scheduler.prune --scheduler rebalance --trigger scheduled --window-minutes 60 --dry-run --json

  This task never creates rollups and never changes scheduler state. Each
  window must have a durable rollup whose count, source digest, and max source
  update timestamp match the current raw rows before anything is deleted.
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
          from: :string,
          until: :string,
          window_minutes: :integer,
          confirm_prune: :boolean,
          confirm_scheduler: :string,
          confirm_trigger: :string,
          confirm_from: :string,
          confirm_until: :string,
          confirm_window_minutes: :integer,
          dry_run: :boolean,
          json: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.scheduler.prune --from <iso8601> --until <iso8601> " <>
          "[--scheduler fresh_drive_heal|rebalance] [--trigger manual|scheduled] " <>
          "--window-minutes N [--dry-run] " <>
          "[--confirm-prune --confirm-scheduler <scheduler> --confirm-trigger <trigger> " <>
          "--confirm-from <iso8601> --confirm-until <iso8601> --confirm-window-minutes N] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    scheduler = required_scheduler!(Keyword.get(opts, :scheduler))
    trigger = required_trigger!(Keyword.get(opts, :trigger))
    validate_window_minutes!(Keyword.get(opts, :window_minutes))

    from = parse_datetime!(Keyword.get(opts, :from), "--from")
    until = parse_datetime!(Keyword.get(opts, :until), "--until")
    window_minutes = Keyword.fetch!(opts, :window_minutes)
    window_ms = window_minutes * 60 * 1_000

    validate_confirmations!(opts, scheduler, trigger, from, until, window_minutes)

    Mix.Task.run("app.start")

    prune_opts =
      [
        from: from,
        until: until,
        window_ms: window_ms,
        scheduler: scheduler,
        trigger: trigger
      ]

    result =
      if Keyword.get(opts, :dry_run, false) do
        SchedulerRuns.prune_preflight(prune_opts)
      else
        SchedulerRuns.prune(Keyword.put(prune_opts, :confirm?, true))
      end

    case result do
      {:ok, report} ->
        view = SchedulerRuns.prune_to_view(report)
        print_or_json(view, opts)

      {:error, reason} ->
        Mix.raise("scheduler prune failed: #{inspect(reason)}")
    end
  end

  defp print_or_json(report, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(report))
    else
      IO.puts(
        "[maxio scheduler.prune] status=#{report.status} dry_run?=#{report.dry_run?} " <>
          "from=#{report.from} until=#{report.until} window_ms=#{report.window_ms} " <>
          "windows=#{report.windows} candidate_runs=#{report.candidate_runs} " <>
          "pruned_runs=#{report.pruned_runs} " <>
          "prunes=#{length(report.prunes)}"
      )

      Enum.each(report.prunes, fn prune ->
        IO.puts(
          "[maxio scheduler.prune.window] status=#{prune.status} scheduler=#{prune.scheduler} " <>
            "trigger=#{prune.trigger} window_started_at=#{prune.window_started_at} " <>
            "window_finished_at=#{prune.window_finished_at} runs=#{prune.run_count} " <>
            "candidate=#{prune.pruned_run_count} rollup_id=#{prune.rollup_id}"
        )
      end)
    end
  end

  defp parse_datetime!(nil, flag), do: Mix.raise("#{flag} is required")

  defp parse_datetime!(value, flag) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, 0} -> dt
      {:ok, _dt, _offset} -> Mix.raise("#{flag} must be UTC ISO8601 with Z offset")
      {:error, reason} -> Mix.raise("#{flag} must be ISO8601 datetime: #{inspect(reason)}")
    end
  end

  defp required_scheduler!(nil), do: Mix.raise("--scheduler is required for prune")
  defp required_scheduler!("fresh_drive_heal"), do: "fresh_drive_heal"
  defp required_scheduler!("rebalance"), do: "rebalance"

  defp required_scheduler!(scheduler) do
    Mix.raise("--scheduler must be fresh_drive_heal or rebalance, got #{inspect(scheduler)}")
  end

  defp required_trigger!(nil), do: Mix.raise("--trigger is required for prune")
  defp required_trigger!("manual"), do: "manual"
  defp required_trigger!("scheduled"), do: "scheduled"

  defp required_trigger!(trigger) do
    Mix.raise("--trigger must be manual or scheduled, got #{inspect(trigger)}")
  end

  defp validate_window_minutes!(nil), do: Mix.raise("--window-minutes is required for prune")
  defp validate_window_minutes!(value) when is_integer(value) and value > 0, do: :ok

  defp validate_window_minutes!(value) do
    Mix.raise("--window-minutes must be a positive integer, got #{inspect(value)}")
  end

  defp validate_confirmations!(opts, scheduler, trigger, from, until, window_minutes) do
    if Keyword.get(opts, :dry_run, false) do
      :ok
    else
      unless Keyword.get(opts, :confirm_prune, false) do
        Mix.raise("--confirm-prune is required unless --dry-run is set")
      end

      unless Keyword.get(opts, :confirm_scheduler) == scheduler do
        Mix.raise("--confirm-scheduler must match --scheduler")
      end

      unless Keyword.get(opts, :confirm_trigger) == trigger do
        Mix.raise("--confirm-trigger must match --trigger")
      end

      confirm_from = parse_datetime!(Keyword.get(opts, :confirm_from), "--confirm-from")

      unless DateTime.compare(confirm_from, from) == :eq do
        Mix.raise("--confirm-from must match --from")
      end

      confirm_until = parse_datetime!(Keyword.get(opts, :confirm_until), "--confirm-until")

      unless DateTime.compare(confirm_until, until) == :eq do
        Mix.raise("--confirm-until must match --until")
      end

      unless Keyword.get(opts, :confirm_window_minutes) == window_minutes do
        Mix.raise("--confirm-window-minutes must match --window-minutes")
      end
    end
  end
end
