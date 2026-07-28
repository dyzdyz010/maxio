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

    assert output =~ "[maxio scheduler.status.summary] gate_status=ok"
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
    assert decoded["gate_status"] == "blocked"
    assert [%{"reason" => "scheduler_state_alert"}] = decoded["blockers"]
  end

  test "fail-on-blocked emits scheduler status evidence before failing" do
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

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/scheduler status blocked/, fn ->
          Status.run([
            "--scheduler",
            "fresh_drive_heal",
            "--runs",
            "1",
            "--json",
            "--fail-on-blocked"
          ])
        end
      end)

    decoded = Jason.decode!(output)
    assert decoded["gate_status"] == "blocked"
    assert [%{"scope" => "state", "reason" => "scheduler_state_alert"}] = decoded["blockers"]
  end

  test "fail-on-attention emits recovered problem evidence before failing" do
    {:ok, _blocked} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        @t0,
        @t0,
        {:ok, %{status: :blocked, phase: :rebalance_closure, job_id: "job-recovered"}},
        failure_threshold: 3
      )

    {:ok, _recovered} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        DateTime.add(@t0, 1, :second),
        DateTime.add(@t0, 1, :second),
        {:ok, %{status: :ok, phase: :copy, job_id: "job-recovered"}}
      )

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/scheduler status attention/, fn ->
          Status.run(["--scheduler", "rebalance", "--runs", "2", "--json", "--fail-on-attention"])
        end
      end)

    decoded = Jason.decode!(output)
    assert decoded["gate_status"] == "attention"
    assert decoded["blockers"] == []
    assert [%{"scope" => "run", "reason" => "recent_problem_run"}] = decoded["warnings"]
  end

  test "state-only omits run rows and invalid flags fail closed" do
    {:ok, _recorded} =
      SchedulerRuns.record(:rebalance, :manual, @t0, @t0, {:error, :no_runnable_job})

    decoded =
      run_status(["--state-only", "--json"])
      |> Jason.decode!()

    assert [_state] = decoded["states"]
    assert decoded["runs"] == []
    assert decoded["gate_status"] == "ok"

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

    assert decoded["gate_status"] == "blocked"

    assert [%{"scope" => "cadence", "reason" => "scheduler_cadence_not_healthy"}] =
             decoded["blockers"]
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
    assert output =~ "[maxio scheduler.status.summary] gate_status=blocked"
    assert output =~ "[maxio scheduler.status.blocker]"
    assert output =~ "reason=scheduler_cadence_not_healthy"
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

    assert decoded["gate_status"] == "ok"

    assert_raise Mix.Error, ~r/--trigger must be manual or scheduled/, fn ->
      run_status(["--trigger", "bad", "--rollups"])
    end

    assert_raise Mix.Error, ~r/--rollup-limit must be a positive integer/, fn ->
      run_status(["--rollups", "--rollup-limit", "0"])
    end
  end

  test "no-start status command starts Repo dependencies but not application schedulers" do
    code = """
    Mix.Task.run("maxio.scheduler.status", [
      "--scheduler", "rebalance",
      "--cadence",
      "--since-minutes", "1",
      "--expected-interval-ms", "60000",
      "--stale-after-ms", "120000",
      "--json"
    ])

    IO.puts("FRESH_SCHEDULER=\#{inspect(Process.whereis(Maxio.Cluster.FreshDriveHeal.Scheduler))}")
    IO.puts("REBALANCE_SCHEDULER=\#{inspect(Process.whereis(Maxio.Cluster.Rebalance.Scheduler))}")
    IO.puts("LIFECYCLE_SCHEDULER=\#{inspect(Process.whereis(Maxio.Lifecycle.Scheduler))}")
    IO.puts("MAXIO_APP_STARTED=\#{inspect(Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} -> app == :maxio end))}")
    """

    script_path =
      Path.join(
        "tmp",
        "maxio_scheduler_status_no_start_#{System.unique_integer([:positive])}.exs"
      )

    File.mkdir_p!(Path.dirname(script_path))
    File.write!(script_path, code)
    on_exit(fn -> File.rm(script_path) end)

    {cmd, args} = mix_run_no_start_script(script_path)
    {output, status} = System.cmd(cmd, args, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

    assert status == 0, output
    assert %{"gate_status" => "blocked"} = output |> json_output_line!() |> Jason.decode!()
    assert output =~ "FRESH_SCHEDULER=nil"
    assert output =~ "REBALANCE_SCHEDULER=nil"
    assert output =~ "LIFECYCLE_SCHEDULER=nil"
    assert output =~ "MAXIO_APP_STARTED=false"
  end

  defp run_status(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> Status.run(args) end)
  end

  defp mix_run_no_start_script(script_path) do
    case :os.type() do
      {:win32, _} -> {"cmd", ["/c", "mix", "run", "--no-start", script_path]}
      _other -> {System.find_executable("mix") || "mix", ["run", "--no-start", script_path]}
    end
  end

  defp json_output_line!(output) do
    output
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.find(fn line -> String.starts_with?(line, "{") end)
  end
end
