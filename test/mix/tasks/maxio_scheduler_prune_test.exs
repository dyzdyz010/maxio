defmodule Mix.Tasks.MaxioSchedulerPruneTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Cluster.{SchedulerRun, SchedulerRuns}
  alias Maxio.Repo
  alias Mix.Tasks.Maxio.Scheduler.Prune

  @task "maxio.scheduler.prune"
  @t0 ~U[2026-06-14 00:00:00.000000Z]
  @from "2026-06-14T00:00:00Z"
  @until "2026-06-14T00:01:00Z"

  setup do
    Mix.Task.reenable(@task)

    on_exit(fn ->
      Mix.Task.reenable(@task)
    end)
  end

  test "dry-run json preflights verified rollup without deleting rows" do
    {:ok, %{run: old_run}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 5, :second),
        {:ok, %{status: :ok, phase: :copy, job_id: "job-prune-cli"}}
      )

    {:ok, _newer} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 120, :second),
        DateTime.add(@t0, 121, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _rollup} =
      SchedulerRuns.rollup(
        scheduler: :rebalance,
        trigger: :scheduled,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        now: DateTime.add(@t0, 180, :second)
      )

    decoded =
      run_prune([
        "--scheduler",
        "rebalance",
        "--trigger",
        "scheduled",
        "--from",
        @from,
        "--until",
        @until,
        "--window-minutes",
        "1",
        "--dry-run",
        "--json"
      ])
      |> Jason.decode!()

    assert decoded["status"] == "preflight"
    assert decoded["dry_run?"] == true
    assert decoded["candidate_runs"] == 1
    assert decoded["pruned_runs"] == 0
    assert [%{"status" => "preflight", "scheduler" => "rebalance"}] = decoded["prunes"]
    assert Repo.get(SchedulerRun, old_run.id)
  end

  test "confirmed prune deletes exact verified rows and marks rollup" do
    {:ok, %{run: old_run}} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :manual,
        @t0,
        DateTime.add(@t0, 5, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _newer} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :manual,
        DateTime.add(@t0, 120, :second),
        DateTime.add(@t0, 121, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _rollup} =
      SchedulerRuns.rollup(
        scheduler: :fresh_drive_heal,
        trigger: :manual,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        now: DateTime.add(@t0, 180, :second)
      )

    output =
      run_prune([
        "--scheduler",
        "fresh_drive_heal",
        "--trigger",
        "manual",
        "--from",
        @from,
        "--until",
        @until,
        "--window-minutes",
        "1",
        "--confirm-prune",
        "--confirm-scheduler",
        "fresh_drive_heal",
        "--confirm-trigger",
        "manual",
        "--confirm-from",
        @from,
        "--confirm-until",
        @until,
        "--confirm-window-minutes",
        "1"
      ])

    assert output =~ "[maxio scheduler.prune] status=ok dry_run?=false"
    assert output =~ "candidate_runs=1"
    assert output =~ "pruned_runs=1"
    refute Repo.get(SchedulerRun, old_run.id)

    assert [rollup] = SchedulerRuns.list_rollups(scheduler: :fresh_drive_heal, trigger: :manual)
    assert rollup.pruned_run_count == 1
    assert rollup.pruned_source_digest == rollup.source_digest
  end

  test "invalid or missing confirmations fail closed" do
    assert_raise Mix.Error, ~r/--trigger is required for prune/, fn ->
      Prune.run([
        "--scheduler",
        "rebalance",
        "--from",
        @from,
        "--until",
        @until,
        "--window-minutes",
        "1",
        "--dry-run"
      ])
    end

    assert_raise Mix.Error, ~r/--confirm-prune is required/, fn ->
      Prune.run([
        "--scheduler",
        "rebalance",
        "--trigger",
        "scheduled",
        "--from",
        @from,
        "--until",
        @until,
        "--window-minutes",
        "1"
      ])
    end

    assert_raise Mix.Error, ~r/--confirm-scheduler must match --scheduler/, fn ->
      Prune.run([
        "--scheduler",
        "rebalance",
        "--trigger",
        "scheduled",
        "--from",
        @from,
        "--until",
        @until,
        "--window-minutes",
        "1",
        "--confirm-prune",
        "--confirm-scheduler",
        "fresh_drive_heal",
        "--confirm-trigger",
        "scheduled",
        "--confirm-from",
        @from,
        "--confirm-until",
        @until,
        "--confirm-window-minutes",
        "1"
      ])
    end

    assert_raise Mix.Error, ~r/--confirm-from must match --from/, fn ->
      Prune.run([
        "--scheduler",
        "rebalance",
        "--trigger",
        "scheduled",
        "--from",
        @from,
        "--until",
        @until,
        "--window-minutes",
        "1",
        "--confirm-prune",
        "--confirm-scheduler",
        "rebalance",
        "--confirm-trigger",
        "scheduled",
        "--confirm-from",
        "2026-06-14T00:01:00Z",
        "--confirm-until",
        @until,
        "--confirm-window-minutes",
        "1"
      ])
    end
  end

  defp run_prune(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> Prune.run(args) end)
  end
end
