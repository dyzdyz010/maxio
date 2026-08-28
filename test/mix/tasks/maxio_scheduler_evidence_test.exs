defmodule Mix.Tasks.MaxioSchedulerEvidenceTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Cluster.SchedulerRuns
  alias Mix.Tasks.Maxio.Scheduler.Evidence

  @task "maxio.scheduler.evidence"
  @t0 ~U[2026-06-14 00:00:00.000000Z]
  @from "2026-06-14T00:00:00Z"
  @until "2026-06-14T00:01:00Z"

  setup do
    Mix.Task.reenable(@task)

    on_exit(fn ->
      Mix.Task.reenable(@task)
    end)
  end

  test "json output reports passing scheduler evidence" do
    seed_passing_rebalance_evidence()

    decoded =
      run_evidence([
        "--scheduler",
        "rebalance",
        "--from",
        @from,
        "--until",
        @until,
        "--window-minutes",
        "1",
        "--expected-interval-ms",
        "60000",
        "--stale-after-ms",
        "120000",
        "--expected-nodes",
        "node_a,node_b",
        "--min-effective-nodes",
        "1",
        "--require-lock-loser",
        "--json"
      ])
      |> Jason.decode!()

    assert decoded["status"] == "ok"
    assert decoded["blockers"] == []
    assert [scheduler] = decoded["schedulers"]
    assert scheduler["scheduler"] == "rebalance"
    assert scheduler["effective_scheduled_nodes"] == ["node_a"]
    assert scheduler["lock_loser_nodes"] == ["node_b"]
  end

  test "text output reports node and lock-loser evidence" do
    seed_passing_rebalance_evidence()

    output =
      run_evidence([
        "--scheduler",
        "rebalance",
        "--from",
        @from,
        "--until",
        @until,
        "--window-minutes",
        "1",
        "--expected-interval-ms",
        "60000",
        "--stale-after-ms",
        "120000",
        "--expected-nodes",
        "node_a,node_b",
        "--min-effective-nodes",
        "1",
        "--require-lock-loser"
      ])

    assert output =~ "[maxio scheduler.evidence] status=ok"
    assert output =~ "[maxio scheduler.evidence.scheduler] scheduler=rebalance"
    assert output =~ "effective_nodes=node_a"
    assert output =~ "lock_losers=node_b"
  end

  test "blocked json is printed before task fails closed" do
    {:ok, _ok} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 1, :second),
        {:ok, %{status: :ok}},
        node: :node_a
      )

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/scheduler evidence blocked/, fn ->
          Evidence.run([
            "--scheduler",
            "rebalance",
            "--from",
            @from,
            "--until",
            @until,
            "--expected-interval-ms",
            "60000",
            "--stale-after-ms",
            "120000",
            "--expected-nodes",
            "node_a,node_b",
            "--min-effective-nodes",
            "1",
            "--json"
          ])
        end
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "blocked"
    assert [%{"reason" => "missing_expected_nodes"}] = decoded["blockers"]
  end

  test "require-rollups fails closed when scheduled rollups are missing" do
    seed_passing_rebalance_evidence()

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/scheduler evidence blocked/, fn ->
          Evidence.run([
            "--scheduler",
            "rebalance",
            "--from",
            @from,
            "--until",
            @until,
            "--window-minutes",
            "1",
            "--expected-interval-ms",
            "60000",
            "--stale-after-ms",
            "120000",
            "--expected-nodes",
            "node_a,node_b",
            "--min-effective-nodes",
            "1",
            "--require-lock-loser",
            "--require-rollups",
            "--json"
          ])
        end
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "blocked"
    assert [%{"reason" => "scheduled_rollups_missing"}] = decoded["blockers"]
  end

  test "fail-on-attention turns warnings into a non-zero gate after output" do
    seed_attention_rebalance_evidence()

    attention =
      run_evidence([
        "--scheduler",
        "rebalance",
        "--from",
        @from,
        "--until",
        @until,
        "--expected-interval-ms",
        "60000",
        "--stale-after-ms",
        "120000",
        "--expected-nodes",
        "node_a",
        "--min-effective-nodes",
        "1",
        "--json"
      ])
      |> Jason.decode!()

    assert attention["status"] == "attention"
    assert [%{"reason" => "blocked_runs_seen"}] = attention["warnings"]

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/scheduler evidence attention/, fn ->
          Evidence.run([
            "--scheduler",
            "rebalance",
            "--from",
            @from,
            "--until",
            @until,
            "--expected-interval-ms",
            "60000",
            "--stale-after-ms",
            "120000",
            "--expected-nodes",
            "node_a",
            "--min-effective-nodes",
            "1",
            "--fail-on-attention",
            "--json"
          ])
        end
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "attention"
    assert [%{"reason" => "blocked_runs_seen"}] = decoded["warnings"]
  end

  test "invalid args fail closed" do
    assert_raise Mix.Error, ~r/--scheduler must be fresh_drive_heal or rebalance/, fn ->
      run_evidence(["--scheduler", "bad"])
    end

    assert_raise Mix.Error, ~r/--min-effective-nodes must be a positive integer/, fn ->
      run_evidence(["--min-effective-nodes", "0"])
    end

    assert_raise Mix.Error, ~r/--expected-nodes must contain at least one node/, fn ->
      run_evidence(["--expected-nodes", ""])
    end

    assert_raise Mix.Error, ~r/--from and --since-minutes cannot be used together/, fn ->
      run_evidence(["--from", @from, "--since-minutes", "10"])
    end
  end

  # 本用例的耗时由**外部进程**主导：它 spawn 一个完整的 `mix run --no-start` 子进程，用真实
  # CLI 启动路径证明 evidence 命令不会拉起 scheduler。本机实测这个子进程热启约 4s、冷启
  # 30s+（Windows 上还要叠加杀软扫描 erl.exe）。ExUnit 默认 60s 预算是按"进程内用例"定的，
  # 全量跑时会被外部冷启撑爆（实测 seed=60221408 在此超时）。这里显式声明真实的时间预算，
  # 既不削断言也不改成进程内假跑；真挂死仍会在 5 分钟内失败。
  @tag timeout: 300_000
  test "no-start evidence command starts Repo dependencies but not application schedulers" do
    code = """
    try do
      Mix.Task.run("maxio.scheduler.evidence", [
        "--scheduler", "rebalance",
        "--since-minutes", "1",
        "--expected-interval-ms", "60000",
        "--stale-after-ms", "120000",
        "--json"
      ])
    rescue
      e in Mix.Error -> IO.puts("MIX_ERROR=\#{Exception.message(e)}")
    end

    IO.puts("FRESH_SCHEDULER=\#{inspect(Process.whereis(Maxio.Cluster.FreshDriveHeal.Scheduler))}")
    IO.puts("REBALANCE_SCHEDULER=\#{inspect(Process.whereis(Maxio.Cluster.Rebalance.Scheduler))}")
    IO.puts("LIFECYCLE_SCHEDULER=\#{inspect(Process.whereis(Maxio.Lifecycle.Scheduler))}")
    """

    script_path =
      Path.join(
        System.tmp_dir!(),
        "maxio_scheduler_evidence_no_start_#{System.unique_integer([:positive])}.exs"
      )

    File.write!(script_path, code)
    on_exit(fn -> File.rm(script_path) end)

    {cmd, args} = mix_run_no_start_script(script_path)
    {output, status} = System.cmd(cmd, args, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "MIX_ERROR=scheduler evidence blocked"
    assert output =~ "FRESH_SCHEDULER=nil"
    assert output =~ "REBALANCE_SCHEDULER=nil"
    assert output =~ "LIFECYCLE_SCHEDULER=nil"
  end

  defp seed_passing_rebalance_evidence do
    {:ok, _ok} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 1, :second),
        {:ok, %{status: :ok}},
        node: :node_a
      )

    {:ok, _skipped} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 2, :second),
        DateTime.add(@t0, 3, :second),
        {:error, :lock_unavailable},
        node: :node_b
      )
  end

  defp seed_attention_rebalance_evidence do
    {:ok, _blocked} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 1, :second),
        {:ok, %{status: :blocked, phase: :rebalance_closure, job_id: "job-attention"}},
        node: :node_a
      )

    {:ok, _ok} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 10, :second),
        DateTime.add(@t0, 11, :second),
        {:ok, %{status: :ok, phase: :copy, job_id: "job-attention"}},
        node: :node_a
      )
  end

  defp run_evidence(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> Evidence.run(args) end)
  end

  defp mix_run_no_start_script(script_path) do
    case :os.type() do
      {:win32, _} -> {"cmd", ["/c", "mix", "run", "--no-start", script_path]}
      _other -> {System.find_executable("mix") || "mix", ["run", "--no-start", script_path]}
    end
  end
end
