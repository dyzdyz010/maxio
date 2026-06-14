defmodule Mix.Tasks.MaxioSchedulerRetentionTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Cluster.{SchedulerRun, SchedulerRuns}
  alias Maxio.Repo
  alias Mix.Tasks.Maxio.Scheduler.Retention

  @task "maxio.scheduler.retention"
  @t0 ~U[2026-06-14 00:00:00.000000Z]
  @now "2026-06-16T00:00:00Z"
  @retention_days 1
  @day_seconds 86_400
  @day_minutes 1_440
  @day_ms @day_seconds * 1_000

  setup do
    Mix.Task.reenable(@task)

    on_exit(fn ->
      Mix.Task.reenable(@task)
    end)
  end

  test "dry-run json reports missing rollups without deleting rows" do
    {:ok, %{run: old_run}} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        @t0,
        DateTime.add(@t0, 5, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _newer} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        DateTime.add(@t0, @day_seconds + 60, :second),
        DateTime.add(@t0, @day_seconds + 65, :second),
        {:ok, %{status: :ok}}
      )

    decoded =
      run_retention([
        "--scheduler",
        "rebalance",
        "--trigger",
        "manual",
        "--retain-days",
        "#{@retention_days}",
        "--window-minutes",
        "#{@day_minutes}",
        "--now",
        @now,
        "--dry-run",
        "--json"
      ])
      |> Jason.decode!()

    assert decoded["status"] == "blocked"
    assert decoded["ready?"] == false
    assert decoded["candidate_runs"] == 1

    assert [missing] = decoded["missing_rollups"]
    assert {:ok, missing_started_at, 0} = DateTime.from_iso8601(missing["window_started_at"])
    assert DateTime.compare(missing_started_at, @t0) == :eq

    assert Repo.get(SchedulerRun, old_run.id)
  end

  test "confirmed retention deletes exact verified rows" do
    current_day_started_at = current_window_started_at(DateTime.utc_now(), @day_ms)
    old_window_started_at = DateTime.add(current_day_started_at, -2 * @day_seconds, :second)
    old_window_finished_at = DateTime.add(old_window_started_at, @day_seconds, :second)
    newer_started_at = DateTime.add(current_day_started_at, 60, :second)

    {:ok, %{run: old_run}} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        old_window_started_at,
        DateTime.add(old_window_started_at, 5, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _newer} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        newer_started_at,
        DateTime.add(newer_started_at, 5, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _rollup} =
      SchedulerRuns.rollup(
        scheduler: :fresh_drive_heal,
        trigger: :scheduled,
        from: old_window_started_at,
        until: old_window_finished_at,
        window_ms: @day_ms,
        now: DateTime.utc_now()
      )

    {:ok, plan} =
      SchedulerRuns.retention_plan(
        scheduler: :fresh_drive_heal,
        trigger: :scheduled,
        retain_days: @retention_days,
        window_ms: @day_ms
      )

    output =
      run_retention([
        "--scheduler",
        "fresh_drive_heal",
        "--trigger",
        "scheduled",
        "--retain-days",
        "#{@retention_days}",
        "--window-minutes",
        "#{@day_minutes}",
        "--enable-retention",
        "--confirm-retention",
        "--confirm-scheduler",
        "fresh_drive_heal",
        "--confirm-trigger",
        "scheduled",
        "--confirm-retain-days",
        "#{@retention_days}",
        "--confirm-window-minutes",
        "#{@day_minutes}",
        "--confirm-cutoff",
        DateTime.to_iso8601(plan.cutoff)
      ])

    assert output =~ "[maxio scheduler.retention] status=ok dry_run?=false"
    assert output =~ "candidate_runs=1"
    assert output =~ "pruned_runs=1"
    refute Repo.get(SchedulerRun, old_run.id)
  end

  test "invalid confirmations fail closed" do
    assert_raise Mix.Error, ~r/--enable-retention is required/, fn ->
      Retention.run([
        "--scheduler",
        "rebalance",
        "--trigger",
        "scheduled",
        "--retain-days",
        "1"
      ])
    end

    assert_raise Mix.Error, ~r/--now is only allowed with --dry-run/, fn ->
      Retention.run([
        "--scheduler",
        "rebalance",
        "--trigger",
        "scheduled",
        "--retain-days",
        "1",
        "--now",
        @now,
        "--enable-retention",
        "--confirm-retention",
        "--confirm-scheduler",
        "rebalance",
        "--confirm-trigger",
        "scheduled",
        "--confirm-retain-days",
        "1",
        "--confirm-window-minutes",
        "60",
        "--confirm-cutoff",
        "2026-06-15T00:00:00Z"
      ])
    end

    assert_raise Mix.Error, ~r/--confirm-cutoff must match/, fn ->
      Retention.run([
        "--scheduler",
        "rebalance",
        "--trigger",
        "scheduled",
        "--retain-days",
        "1",
        "--window-minutes",
        "#{@day_minutes}",
        "--enable-retention",
        "--confirm-retention",
        "--confirm-scheduler",
        "rebalance",
        "--confirm-trigger",
        "scheduled",
        "--confirm-retain-days",
        "1",
        "--confirm-window-minutes",
        "#{@day_minutes}",
        "--confirm-cutoff",
        "2026-06-14T00:00:00Z"
      ])
    end
  end

  defp run_retention(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> Retention.run(args) end)
  end

  defp current_window_started_at(%DateTime{} = now, window_ms) do
    window_us = window_ms * 1_000
    started_us = div(DateTime.to_unix(now, :microsecond), window_us) * window_us
    DateTime.from_unix!(started_us, :microsecond)
  end
end
