defmodule Mix.Tasks.MaxioSchedulerStatusTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Cluster.SchedulerRuns
  alias Mix.Tasks.Maxio.Scheduler.Status

  @task "maxio.scheduler.status"
  @t0 ~U[2026-06-14 00:00:00.000000Z]

  setup do
    Mix.Task.reenable(@task)

    on_exit(fn ->
      Mix.Task.reenable(@task)
    end)
  end

  test "prints scheduler state and recent run evidence" do
    {:ok, %{run: run}} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        @t0,
        DateTime.add(@t0, 5, :millisecond),
        {:ok, %{status: :ok, phase: :copy, job_id: "job-1"}}
      )

    output = run_status(["--scheduler", "rebalance", "--runs", "1"])

    assert output =~ "[maxio scheduler.status] scheduler=rebalance status=ok"
    assert output =~ "consecutive_failures=0"
    assert output =~ "[maxio scheduler.run] id=#{run.id}"
    assert output =~ "phase=copy"
    assert output =~ "job_id=job-1"
  end

  test "json output is machine-readable" do
    {:ok, _recorded} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        @t0,
        @t0,
        {:error, :boom},
        failure_threshold: 1,
        backoff_ms: 60_000
      )

    decoded =
      run_status(["--scheduler", "fresh_drive_heal", "--runs", "1", "--json"])
      |> Jason.decode!()

    assert [%{"scheduler" => "fresh_drive_heal", "alert_status" => "alert"}] =
             decoded["states"]

    assert [%{"scheduler" => "fresh_drive_heal", "status" => "failed"}] = decoded["runs"]
  end

  test "state-only omits run rows and invalid flags fail closed" do
    {:ok, _recorded} =
      SchedulerRuns.record(:rebalance, :manual, @t0, @t0, {:error, :no_runnable_job})

    decoded =
      run_status(["--state-only", "--json"])
      |> Jason.decode!()

    assert [_state] = decoded["states"]
    assert decoded["runs"] == []

    assert_raise Mix.Error, ~r/--scheduler must be fresh_drive_heal or rebalance/, fn ->
      run_status(["--scheduler", "bad"])
    end

    assert_raise Mix.Error, ~r/--runs must be a positive integer/, fn ->
      run_status(["--runs", "0"])
    end

    assert_raise Mix.Error, ~r/--since-minutes must be a positive integer/, fn ->
      run_status(["--cadence", "--since-minutes", "0"])
    end
  end

  test "cadence json reports scheduled-only health" do
    {:ok, _recorded} =
      SchedulerRuns.record(:rebalance, :manual, @t0, @t0, {:ok, %{status: :ok}})

    decoded =
      run_status([
        "--scheduler",
        "rebalance",
        "--cadence",
        "--since-minutes",
        "1",
        "--expected-interval-ms",
        "10000",
        "--stale-after-ms",
        "20000",
        "--json"
      ])
      |> Jason.decode!()

    assert [%{"scheduler" => "rebalance", "status" => "ok"}] = decoded["states"]

    assert [%{"scheduler" => "rebalance", "health" => "not_started", "healthy?" => false}] =
             decoded["cadence"]["reports"]
  end

  test "cadence json and text report scheduler node participation" do
    now = DateTime.utc_now()

    {:ok, _ok} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        now,
        now,
        {:ok, %{status: :ok}},
        node: :node_a
      )

    {:ok, _skipped} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(now, -1, :second),
        DateTime.add(now, -1, :second),
        {:error, :lock_unavailable},
        node: :node_b
      )

    json =
      run_status([
        "--scheduler",
        "rebalance",
        "--cadence",
        "--since-minutes",
        "1",
        "--expected-interval-ms",
        "10000",
        "--stale-after-ms",
        "20000",
        "--json"
      ])
      |> Jason.decode!()

    assert [cadence] = json["cadence"]["reports"]
    assert cadence["scheduled_nodes"] == ["node_a", "node_b"]
    assert cadence["effective_scheduled_nodes"] == ["node_a"]
    assert cadence["healthy_scheduled_nodes"] == ["node_a"]
    assert cadence["skipped_scheduled_nodes"] == ["node_b"]
    assert cadence["lock_loser_nodes"] == ["node_b"]
    assert cadence["lock_loser_count"] == 1
    assert cadence["last_effective_scheduled_node"] == "node_a"

    text =
      run_status([
        "--scheduler",
        "rebalance",
        "--cadence",
        "--since-minutes",
        "1",
        "--expected-interval-ms",
        "10000",
        "--stale-after-ms",
        "20000"
      ])

    assert text =~ "nodes=node_a,node_b"
    assert text =~ "effective_nodes=node_a"
    assert text =~ "healthy_nodes=node_a"
    assert text =~ "skipped_nodes=node_b"
    assert text =~ "lock_losers=node_b"
    assert text =~ "lock_loser_count=1"
  end

  test "cadence text shows skipped scheduled runs without marking healthy" do
    now = DateTime.utc_now()

    {:ok, _recorded} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        now,
        now,
        {:error, :lock_unavailable}
      )

    output =
      run_status([
        "--scheduler",
        "fresh_drive_heal",
        "--cadence",
        "--since-minutes",
        "1",
        "--expected-interval-ms",
        "10000",
        "--stale-after-ms",
        "20000"
      ])

    assert output =~ "[maxio scheduler.cadence] scheduler=fresh_drive_heal health=stale"
    assert output =~ "reason=no_effective_scheduled_run"
    assert output =~ "[maxio scheduler.cadence.window] scheduler=fresh_drive_heal"
    assert output =~ "scheduled=1"
    assert output =~ "effective=0"
    assert output =~ "skipped=1"
  end

  test "rollups flag prints persisted rollup windows without writing new ones" do
    {:ok, _recorded} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 5, :second),
        {:ok, %{status: :ok, phase: :copy, job_id: "job-rollup-status"}}
      )

    {:ok, _rollup_report} =
      SchedulerRuns.rollup(
        scheduler: :rebalance,
        trigger: :scheduled,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        now: DateTime.add(@t0, 120, :second)
      )

    output = run_status(["--scheduler", "rebalance", "--trigger", "scheduled", "--rollups"])

    assert output =~ "[maxio scheduler.rollup] scheduler=rebalance trigger=scheduled"
    assert output =~ "runs=1"
    assert output =~ "healthy=1"

    decoded =
      run_status([
        "--scheduler",
        "rebalance",
        "--trigger",
        "scheduled",
        "--rollups",
        "--json"
      ])
      |> Jason.decode!()

    assert [%{"scheduler" => "rebalance", "trigger" => "scheduled", "run_count" => 1}] =
             decoded["rollups"]

    assert_raise Mix.Error, ~r/--trigger must be manual or scheduled/, fn ->
      run_status(["--trigger", "bad", "--rollups"])
    end

    assert_raise Mix.Error, ~r/--rollup-limit must be a positive integer/, fn ->
      run_status(["--rollups", "--rollup-limit", "0"])
    end
  end

  defp run_status(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> Status.run(args) end)
  end
end
