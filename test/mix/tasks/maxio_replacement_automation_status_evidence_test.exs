defmodule Mix.Tasks.MaxioReplacementAutomationStatusEvidenceTest do
  use Maxio.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Maxio.Cluster.{SchedulerRun, SchedulerRunRollup, SchedulerRuns, SchedulerState}
  alias Maxio.Repo
  alias Mix.Tasks.Maxio.Replacement.AutomationStatus

  @task "maxio.replacement.automation_status"
  @env_keys [:fresh_drive_heal_scheduler, :rebalance_scheduler, :scheduler_ledger]

  setup do
    previous = Map.new(@env_keys, &{&1, Application.get_env(:maxio, &1, :__unset__)})
    Mix.Task.reenable(@task)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :__unset__} -> Application.delete_env(:maxio, key)
        {key, value} -> Application.put_env(:maxio, key, value)
      end)

      Mix.Task.reenable(@task)
    end)
  end

  test "require-scheduler-evidence keeps ready report ready with fresh and rebalance scheduled evidence" do
    put_ready_env()
    seed_ok_scheduled(:fresh_drive_heal)
    seed_ok_scheduled(:rebalance)

    decoded =
      run_status([
        "--json",
        "--require-scheduler-evidence",
        "--since-minutes",
        "5",
        "--expected-interval-ms",
        "60000",
        "--stale-after-ms",
        "300000",
        "--expected-nodes",
        node_name(),
        "--min-effective-nodes",
        "1"
      ])
      |> Jason.decode!()

    assert decoded["status"] == "ready"
    assert decoded["blockers"] == []
    assert decoded["checks"]["scheduler_evidence"]["required?"] == true
    assert decoded["checks"]["scheduler_evidence"]["status"] == "ok"

    schedulers = decoded["checks"]["scheduler_evidence"]["report"]["schedulers"]

    assert Enum.map(schedulers, & &1["scheduler"]) |> Enum.sort() == [
             "fresh_drive_heal",
             "rebalance"
           ]
  end

  test "require-scheduler-evidence blocks ready config when scheduled ledger is missing" do
    put_ready_env()

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/replacement automation blocked/, fn ->
          AutomationStatus.run([
            "--json",
            "--require-scheduler-evidence",
            "--fail-on-blocked",
            "--since-minutes",
            "5",
            "--expected-interval-ms",
            "60000",
            "--stale-after-ms",
            "300000",
            "--expected-nodes",
            node_name(),
            "--min-effective-nodes",
            "1"
          ])
        end
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "blocked"
    assert "scheduler_evidence_blocked" in decoded["blockers"]
    assert decoded["checks"]["scheduler_evidence"]["status"] == "blocked"
  end

  test "require-scheduler-evidence surfaces attention and fail-on-attention after JSON output" do
    put_ready_env()
    seed_ok_scheduled(:fresh_drive_heal)
    seed_attention_rebalance_scheduled()

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/replacement automation attention/, fn ->
          AutomationStatus.run([
            "--json",
            "--require-scheduler-evidence",
            "--fail-on-attention",
            "--since-minutes",
            "5",
            "--expected-interval-ms",
            "60000",
            "--stale-after-ms",
            "300000",
            "--expected-nodes",
            node_name(),
            "--min-effective-nodes",
            "1"
          ])
        end
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "attention"
    assert "scheduler_evidence_attention" in decoded["warnings"]
    assert decoded["checks"]["scheduler_evidence"]["status"] == "attention"
  end

  test "require-scheduler-evidence reads scheduler ledger without writing rows or state" do
    put_ready_env()
    seed_ok_scheduled(:fresh_drive_heal)
    seed_ok_scheduled(:rebalance)
    before = scheduler_ledger_snapshot()

    _output =
      run_status([
        "--json",
        "--require-scheduler-evidence",
        "--since-minutes",
        "5",
        "--expected-interval-ms",
        "60000",
        "--stale-after-ms",
        "300000",
        "--expected-nodes",
        node_name(),
        "--min-effective-nodes",
        "1"
      ])

    assert scheduler_ledger_snapshot() == before
  end

  test "scheduler evidence options require the explicit evidence gate" do
    assert_raise Mix.Error,
                 ~r/scheduler evidence options require --require-scheduler-evidence/,
                 fn ->
                   run_status(["--since-minutes", "5"])
                 end
  end

  # 同 `maxio_scheduler_evidence_test.exs`：耗时由外部 `mix run --no-start` 子进程主导
  # （热启约 4s、冷启 30s+），ExUnit 默认 60s 预算按进程内用例定，全量跑会被撑爆。显式声明
  # 真实时间预算，不削断言。
  @tag timeout: 300_000
  test "evidence mode starts Repo only and does not start application schedulers" do
    code = """
    Application.put_env(:maxio, :fresh_drive_heal_scheduler, enabled: true, auto_rebalance_after_heal: true)
    Application.put_env(:maxio, :rebalance_scheduler, enabled: true, auto_source_cleanup: true, auto_rebalance_closure: true)
    Application.put_env(:maxio, :scheduler_ledger, enabled: true)

    try do
      Mix.Task.run("maxio.replacement.automation_status", [
        "--json",
        "--require-scheduler-evidence",
        "--fail-on-blocked",
        "--since-minutes", "1",
        "--expected-interval-ms", "60000",
        "--stale-after-ms", "120000",
        "--expected-nodes", "definitely_missing_node",
        "--min-effective-nodes", "1"
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
        "maxio_replacement_automation_status_evidence_probe_#{System.unique_integer([:positive])}.exs"
      )

    File.write!(script_path, code)
    on_exit(fn -> File.rm(script_path) end)

    {cmd, args} = mix_run_no_start_script(script_path)
    {output, status} = System.cmd(cmd, args, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "MIX_ERROR=replacement automation blocked"
    assert output =~ "FRESH_SCHEDULER=nil"
    assert output =~ "REBALANCE_SCHEDULER=nil"
    assert output =~ "LIFECYCLE_SCHEDULER=nil"
  end

  defp seed_ok_scheduled(scheduler) do
    now = DateTime.utc_now()
    started_at = DateTime.add(now, -1, :second)

    SchedulerRuns.record(
      scheduler,
      :scheduled,
      started_at,
      now,
      {:ok, %{status: :ok}},
      node: Node.self()
    )
  end

  defp seed_attention_rebalance_scheduled do
    now = DateTime.utc_now()

    {:ok, _blocked} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(now, -4, :second),
        DateTime.add(now, -3, :second),
        {:ok, %{status: :blocked, phase: :rebalance_closure, job_id: "job-attention"}},
        node: Node.self()
      )

    {:ok, _ok} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(now, -2, :second),
        DateTime.add(now, -1, :second),
        {:ok, %{status: :ok, phase: :rebalance_closure, job_id: "job-attention"}},
        node: Node.self()
      )
  end

  defp put_ready_env do
    Application.put_env(:maxio, :fresh_drive_heal_scheduler,
      enabled: true,
      probe_drive_health: true,
      auto_rebalance_after_heal: true
    )

    Application.put_env(:maxio, :rebalance_scheduler,
      enabled: true,
      auto_source_cleanup: true,
      auto_rebalance_closure: true
    )

    Application.put_env(:maxio, :scheduler_ledger, enabled: true)
  end

  defp run_status(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> AutomationStatus.run(args) end)
  end

  defp scheduler_ledger_snapshot do
    %{
      runs:
        Repo.all(
          from r in SchedulerRun,
            order_by: r.id,
            select: {r.id, r.status, r.updated_at}
        ),
      states:
        Repo.all(
          from s in SchedulerState,
            order_by: s.id,
            select: {s.id, s.scheduler, s.status, s.last_run_id, s.updated_at}
        ),
      rollups:
        Repo.all(
          from r in SchedulerRunRollup,
            order_by: r.id,
            select: {r.id, r.scheduler, r.trigger, r.updated_at}
        )
    }
  end

  defp node_name, do: Node.self() |> Atom.to_string()

  defp mix_run_no_start_script(script_path) do
    case :os.type() do
      {:win32, _} -> {"cmd", ["/c", "mix", "run", "--no-start", script_path]}
      _other -> {System.find_executable("mix") || "mix", ["run", "--no-start", script_path]}
    end
  end
end
