defmodule Mix.Tasks.MaxioReplacementWorkflowTest do
  use Maxio.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Maxio.Cluster.DriveHealth
  alias Maxio.Cluster.{Rebalance.Job, Rebalance.Jobs, Topology}
  alias Maxio.Repo
  alias Mix.Tasks.Maxio.Replacement.Workflow

  @task "maxio.replacement.workflow"
  @topology_key {Maxio.Cluster.Topology, :topology}

  setup do
    DriveHealth.reset()
    Mix.Task.reenable(@task)

    on_exit(fn ->
      DriveHealth.reset()
      Mix.Task.reenable(@task)
    end)
  end

  test "default command prints read-only audit evidence" do
    endpoint = {Node.self(), Path.join(System.tmp_dir!(), "replacement-workflow-cli")}

    _ =
      DriveHealth.record_probe(endpoint, {:error, :unavailable},
        now_ms: 0,
        offline_after_ms: 0,
        set_id: 0,
        set_write_available?: true
      )

    _ = DriveHealth.record_probe(endpoint, :ok, now_ms: 1, offline_after_ms: 0, set_id: 0)

    output = capture_io(fn -> Workflow.run([]) end)

    assert output =~ "[maxio replacement.workflow] status=audit"
    assert output =~ "gate_status=blocked"
    assert output =~ "phase=audit"
    assert output =~ "mutating=false"
    assert output =~ "drive_heal_required=1"
    assert output =~ "heal_status=not_requested"
    assert output =~ "rebalance_enqueue_status=not_requested"
    assert output =~ "automation_status=blocked"
    assert output =~ "[maxio replacement.workflow.blocker]"
    assert output =~ "next_action=\"mix maxio.replacement.workflow --heal --rebalance-if-needed\""
    assert DriveHealth.heal_required?(endpoint)
  end

  test "json command emits machine-readable audit report" do
    decoded =
      capture_io(fn -> Workflow.run(["--json"]) end)
      |> Jason.decode!()

    assert decoded["status"] == "audit"
    assert decoded["phase"] == "audit"
    assert decoded["gate_status"] in ["ok", "attention", "blocked"]
    assert is_list(decoded["blockers"])
    assert is_list(decoded["warnings"])
    assert is_list(decoded["workflow_blockers"])
    assert decoded["mutating?"] == false
    assert decoded["probe"]["status"] == "not_requested"
    assert decoded["heal"]["status"] == "not_requested"
    assert decoded["rebalance_enqueue"]["status"] == "not_requested"
    assert decoded["rebalance_advance"]["status"] == "not_requested"
  end

  test "rehearsal-ready workflow injects local ready automation and marks the report" do
    decoded =
      capture_io(fn -> Workflow.run(["--json", "--rehearsal-ready"]) end)
      |> Jason.decode!()

    assert decoded["status"] == "audit"
    assert decoded["phase"] == "audit"
    assert decoded["gate_status"] == "ok"
    assert decoded["rehearsal_ready?"] == true
    assert decoded["blockers"] == []
    assert decoded["warnings"] == []
    assert decoded["automation_profile"]["status"] == "ready"
    assert decoded["automation_profile"]["blockers"] == []
    assert decoded["automation_profile"]["warnings"] == []
    assert decoded["next_action"] == "none"
    assert decoded["mutating?"] == false
  end

  test "fail-on-blocked prints JSON before returning a non-zero gate" do
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)
    previous_deployment_topology = Application.get_env(:maxio, Topology, :__maxio_no_topology__)
    previous_topology_source = Application.get_env(:maxio, :topology_source, :__maxio_no_source__)
    topology = topology()

    try do
      :persistent_term.put(@topology_key, topology)
      Application.put_env(:maxio, Topology, Topology.to_config(topology))
      Application.put_env(:maxio, :topology_source, :config)

      {:ok, job} = Jobs.start_rebalance(topology: topology, include_drive_stats: false)

      assert {1, _rows} =
               Repo.update_all(
                 from(j in Job, where: j.id == ^job.id),
                 set: [
                   status: "complete",
                   data_movement_status: "complete",
                   source_cleanup_status: "complete"
                 ]
               )

      {:ok, active} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)

      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/replacement workflow blocked/, fn ->
            Workflow.run(["--json", "--fail-on-blocked"])
          end
        end)

      decoded = Jason.decode!(output)
      assert decoded["status"] == "blocked"
      assert decoded["gate_status"] == "blocked"
      assert decoded["phase"] == "audit"
      assert decoded["rebalance_workflow"]["phase"] == "rebalance_closure"
      assert decoded["next_action"] == "mix maxio.rebalance.workflow --job-id #{active.id} --json"
      assert "active_job_exists" in decoded["blockers"]
    after
      restore_topology(previous_topology)
      restore_deployment_topology(previous_deployment_topology)
      restore_topology_source(previous_topology_source)
    end
  end

  test "fail-on-attention prints JSON before returning a non-zero gate" do
    with_automation_config(attention_fresh_scheduler(), ready_rebalance_scheduler(), fn ->
      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/replacement workflow attention/, fn ->
            Workflow.run(["--json", "--fail-on-attention"])
          end
        end)

      decoded = Jason.decode!(output)
      assert decoded["status"] == "audit"
      assert decoded["gate_status"] == "attention"
      assert decoded["blockers"] == []
      assert "fresh_drive_heal_inline_advance_closure_disabled" in decoded["warnings"]
    end)
  end

  test "fail-on-attention also fails blocked gates after printing evidence" do
    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/replacement workflow blocked/, fn ->
          Workflow.run(["--json", "--fail-on-attention"])
        end
      end)

    decoded = Jason.decode!(output)
    assert decoded["gate_status"] == "blocked"
    assert "fresh_drive_heal_scheduler_disabled" in decoded["blockers"]
  end

  test "unsafe advance flags fail closed unless heal is explicit" do
    assert_raise Mix.Error, ~r/--advance-steps must be a positive integer/, fn ->
      Workflow.run(["--heal", "--advance-steps", "0"])
    end

    assert_raise Mix.Error, ~r/--advance-steps and --verify-closure require --heal/, fn ->
      Workflow.run(["--advance-steps", "1"])
    end

    assert_raise Mix.Error, ~r/--rebalance-if-needed requires --heal/, fn ->
      Workflow.run(["--rebalance-if-needed"])
    end
  end

  # 同 `maxio_scheduler_evidence_test.exs`：耗时由外部 `mix run --no-start` 子进程主导
  # （热启约 4s、冷启 30s+），ExUnit 默认 60s 预算按进程内用例定，全量跑会被撑爆。显式声明
  # 真实时间预算，不削断言。
  @tag timeout: 300_000
  test "default audit starts minimal runtime without full app schedulers" do
    code = """
    Application.put_env(:maxio, :fresh_drive_heal_scheduler, enabled: true, initial_delay_ms: 0, interval_ms: 1)
    Application.put_env(:maxio, :rebalance_scheduler, enabled: true, initial_delay_ms: 0, interval_ms: 1)
    Application.put_env(:maxio, :lifecycle_scheduler, enabled: true, initial_delay_ms: 0, interval_ms: 1)
    Mix.Task.run("maxio.replacement.workflow", ["--json"])
    IO.puts("FRESH_SCHEDULER=\#{inspect(Process.whereis(Maxio.Cluster.FreshDriveHeal.Scheduler))}")
    IO.puts("REBALANCE_SCHEDULER=\#{inspect(Process.whereis(Maxio.Cluster.Rebalance.Scheduler))}")
    IO.puts("LIFECYCLE_SCHEDULER=\#{inspect(Process.whereis(Maxio.Lifecycle.Scheduler))}")
    """

    File.mkdir_p!("tmp")

    script_path =
      Path.join(
        "tmp",
        "maxio_replacement_workflow_probe_#{System.unique_integer([:positive])}.exs"
      )

    File.write!(script_path, code)
    on_exit(fn -> File.rm(script_path) end)

    {cmd, args} = mix_run_no_start_script(script_path)

    {output, status} =
      System.cmd(cmd, args, env: mix_test_env(), stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "FRESH_SCHEDULER=nil"
    assert output =~ "REBALANCE_SCHEDULER=nil"
    assert output =~ "LIFECYCLE_SCHEDULER=nil"
  end

  defp topology do
    base = Path.join(System.tmp_dir!(), "maxio_replacement_workflow_cli")
    endpoints0 = for i <- 0..1, do: {Node.self(), Path.join(base, "s0d#{i}")}
    endpoints1 = for i <- 0..1, do: {Node.self(), Path.join(base, "s1d#{i}")}

    Topology.parse_and_validate!(
      data_shards: 1,
      parity_shards: 1,
      block_size: 1024,
      allow_colocated_endpoints: true,
      pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints0}, %{id: 1, endpoints: endpoints1}]}]
    )
  end

  defp mix_run_no_start_script(script_path) do
    case :os.type() do
      {:win32, _} -> {"cmd", ["/c", "mix", "run", "--no-start", script_path]}
      _other -> {System.find_executable("mix") || "mix", ["run", "--no-start", script_path]}
    end
  end

  defp mix_test_env do
    [{"MIX_ENV", "test"}] ++ inherited_elixir_erl_options()
  end

  defp inherited_elixir_erl_options do
    case System.get_env("ELIXIR_ERL_OPTIONS") do
      nil -> []
      value -> [{"ELIXIR_ERL_OPTIONS", value}]
    end
  end

  defp restore_topology(:__maxio_no_topology__), do: :persistent_term.erase(@topology_key)
  defp restore_topology(topology), do: :persistent_term.put(@topology_key, topology)

  defp restore_deployment_topology(:__maxio_no_topology__),
    do: Application.delete_env(:maxio, Topology)

  defp restore_deployment_topology(topology),
    do: Application.put_env(:maxio, Topology, topology)

  defp restore_topology_source(:__maxio_no_source__),
    do: Application.delete_env(:maxio, :topology_source)

  defp restore_topology_source(source),
    do: Application.put_env(:maxio, :topology_source, source)

  defp with_automation_config(fresh_scheduler, rebalance_scheduler, fun) do
    previous_fresh = Application.get_env(:maxio, :fresh_drive_heal_scheduler, :__maxio_no_env__)
    previous_rebalance = Application.get_env(:maxio, :rebalance_scheduler, :__maxio_no_env__)
    previous_ledger = Application.get_env(:maxio, :scheduler_ledger, :__maxio_no_env__)

    try do
      Application.put_env(:maxio, :fresh_drive_heal_scheduler, fresh_scheduler)
      Application.put_env(:maxio, :rebalance_scheduler, rebalance_scheduler)
      Application.put_env(:maxio, :scheduler_ledger, enabled: true)
      fun.()
    after
      restore_env(:fresh_drive_heal_scheduler, previous_fresh)
      restore_env(:rebalance_scheduler, previous_rebalance)
      restore_env(:scheduler_ledger, previous_ledger)
    end
  end

  defp ready_fresh_scheduler do
    [
      enabled: true,
      probe_drive_health: true,
      auto_rebalance_after_heal: true,
      auto_advance_rebalance_after_heal: false,
      run_opts: [],
      scheduler_ledger: [enabled: true]
    ]
  end

  defp attention_fresh_scheduler do
    ready_fresh_scheduler()
    |> Keyword.put(:auto_advance_rebalance_after_heal, true)
    |> Keyword.put(:rebalance_advance_opts, auto_rebalance_closure: false)
  end

  defp ready_rebalance_scheduler do
    [
      enabled: true,
      auto_source_cleanup: true,
      auto_rebalance_closure: true,
      run_opts: [],
      scheduler_ledger: [enabled: true]
    ]
  end

  defp restore_env(key, :__maxio_no_env__), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
