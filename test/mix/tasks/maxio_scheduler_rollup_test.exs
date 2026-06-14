defmodule Mix.Tasks.MaxioSchedulerRollupTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Cluster.SchedulerRuns
  alias Mix.Tasks.Maxio.Scheduler.Rollup

  @task "maxio.scheduler.rollup"
  @t0 ~U[2026-06-14 00:00:00.000000Z]
  @from "2026-06-14T00:00:00Z"
  @until "2026-06-14T00:01:00Z"

  setup do
    Mix.Task.reenable(@task)

    on_exit(fn ->
      Mix.Task.reenable(@task)
    end)
  end

  test "dry-run json reports rollup windows without writing rows" do
    {:ok, _recorded} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 5, :second),
        {:ok, %{status: :ok, phase: :copy, job_id: "job-rollup-cli"}}
      )

    decoded =
      run_rollup([
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

    assert decoded["status"] == "dry_run"
    assert decoded["dry_run?"] == true

    assert [%{"scheduler" => "rebalance", "trigger" => "scheduled", "run_count" => 1}] =
             decoded["rollups"]

    assert SchedulerRuns.list_rollups(scheduler: :rebalance, trigger: :scheduled) == []
  end

  test "writes durable rollup rows" do
    {:ok, _recorded} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :manual,
        @t0,
        DateTime.add(@t0, 3, :second),
        {:error, :no_runnable_job}
      )

    output =
      run_rollup([
        "--scheduler",
        "fresh_drive_heal",
        "--trigger",
        "manual",
        "--from",
        @from,
        "--until",
        @until,
        "--window-minutes",
        "1"
      ])

    assert output =~ "[maxio scheduler.rollup] status=ok dry_run?=false"
    assert output =~ "[maxio scheduler.rollup.window] scheduler=fresh_drive_heal trigger=manual"
    assert output =~ "runs=1"

    assert [rollup] = SchedulerRuns.list_rollups(scheduler: :fresh_drive_heal, trigger: :manual)
    assert rollup.run_count == 1
    assert rollup.idle_count == 1
    assert rollup.healthy_count == 1
  end

  test "invalid args fail closed" do
    assert_raise Mix.Error, ~r/--from is required/, fn ->
      Rollup.run(["--until", @until])
    end

    assert_raise Mix.Error, ~r/--scheduler must be fresh_drive_heal or rebalance/, fn ->
      Rollup.run(["--scheduler", "bad", "--from", @from, "--until", @until])
    end

    assert_raise Mix.Error, ~r/--window-minutes must be a positive integer/, fn ->
      Rollup.run(["--from", @from, "--until", @until, "--window-minutes", "0"])
    end
  end

  defp run_rollup(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> Rollup.run(args) end)
  end
end
