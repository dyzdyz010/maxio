defmodule Mix.Tasks.Maxio.Scheduler.Rollup do
  @shortdoc "Build durable scheduler run ledger rollups"
  @moduledoc """
  Build closed-window rollups for the scheduler run ledger.

      mix maxio.scheduler.rollup --from 2026-06-14T00:00:00Z --until 2026-06-14T02:00:00Z
      mix maxio.scheduler.rollup --scheduler rebalance --trigger scheduled --window-minutes 60 --dry-run --json

  This task only writes `cluster_scheduler_run_rollups`. It never deletes
  `cluster_scheduler_runs`, never changes scheduler state, and never affects
  scheduler execution, backoff, or cadence health.
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
          dry_run: :boolean,
          json: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.scheduler.rollup --from <iso8601> --until <iso8601> " <>
          "[--scheduler fresh_drive_heal|rebalance] [--trigger manual|scheduled] " <>
          "[--window-minutes N] [--dry-run] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_scheduler!(Keyword.get(opts, :scheduler))
    validate_trigger!(Keyword.get(opts, :trigger))
    validate_window_minutes!(Keyword.get(opts, :window_minutes))

    from = parse_datetime!(Keyword.get(opts, :from), "--from")
    until = parse_datetime!(Keyword.get(opts, :until), "--until")
    window_ms = Keyword.get(opts, :window_minutes, 60) * 60 * 1_000

    Mix.Task.run("app.start")

    rollup_opts =
      [
        from: from,
        until: until,
        window_ms: window_ms,
        dry_run: Keyword.get(opts, :dry_run, false)
      ]
      |> maybe_put(:scheduler, Keyword.get(opts, :scheduler))
      |> maybe_put(:trigger, Keyword.get(opts, :trigger))

    case SchedulerRuns.rollup(rollup_opts) do
      {:ok, report} ->
        view = report_to_view(report)
        print_or_json(view, opts)

      {:error, reason} ->
        Mix.raise("scheduler rollup failed: #{inspect(reason)}")
    end
  end

  defp print_or_json(report, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(report))
    else
      IO.puts(
        "[maxio scheduler.rollup] status=#{report.status} dry_run?=#{report.dry_run?} " <>
          "from=#{report.from} until=#{report.until} window_ms=#{report.window_ms} " <>
          "windows=#{report.windows} rollups=#{length(report.rollups)}"
      )

      Enum.each(report.rollups, fn rollup ->
        IO.puts(
          "[maxio scheduler.rollup.window] scheduler=#{rollup.scheduler} " <>
            "trigger=#{rollup.trigger} window_started_at=#{rollup.window_started_at} " <>
            "window_finished_at=#{rollup.window_finished_at} runs=#{rollup.run_count} " <>
            "effective=#{rollup.effective_count} healthy=#{rollup.healthy_count} " <>
            "failed=#{rollup.failed_count} last_status=#{format_value(rollup.last_status)}"
        )
      end)
    end
  end

  defp report_to_view(report) do
    %{
      status: report.status,
      dry_run?: report.dry_run?,
      from: DateTime.to_iso8601(report.from),
      until: DateTime.to_iso8601(report.until),
      window_ms: report.window_ms,
      windows: report.windows,
      rollups: Enum.map(report.rollups, &SchedulerRuns.rollup_to_view/1)
    }
  end

  defp parse_datetime!(nil, flag), do: Mix.raise("#{flag} is required")

  defp parse_datetime!(value, flag) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, 0} -> dt
      {:ok, _dt, _offset} -> Mix.raise("#{flag} must be UTC ISO8601 with Z offset")
      {:error, reason} -> Mix.raise("#{flag} must be ISO8601 datetime: #{inspect(reason)}")
    end
  end

  defp validate_scheduler!(nil), do: :ok
  defp validate_scheduler!("fresh_drive_heal"), do: :ok
  defp validate_scheduler!("rebalance"), do: :ok

  defp validate_scheduler!(scheduler) do
    Mix.raise("--scheduler must be fresh_drive_heal or rebalance, got #{inspect(scheduler)}")
  end

  defp validate_trigger!(nil), do: :ok
  defp validate_trigger!("manual"), do: :ok
  defp validate_trigger!("scheduled"), do: :ok

  defp validate_trigger!(trigger) do
    Mix.raise("--trigger must be manual or scheduled, got #{inspect(trigger)}")
  end

  defp validate_window_minutes!(nil), do: :ok
  defp validate_window_minutes!(value) when is_integer(value) and value > 0, do: :ok

  defp validate_window_minutes!(value) do
    Mix.raise("--window-minutes must be a positive integer, got #{inspect(value)}")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_value(nil), do: "nil"
  defp format_value(value), do: to_string(value)
end
