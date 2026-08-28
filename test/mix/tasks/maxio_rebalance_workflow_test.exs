defmodule Mix.Tasks.MaxioRebalanceWorkflowTest do
  use Maxio.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Maxio.Buckets
  alias Maxio.Cluster.{Rebalance.Job, Rebalance.Jobs, Topology}
  alias Maxio.Repo
  alias Mix.Tasks.Maxio.Rebalance.Workflow

  @owner "arn:aws:iam:::root"
  @task "maxio.rebalance.workflow"
  @topology_key {Maxio.Cluster.Topology, :topology}

  setup do
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)
    previous_deployment_topology = Application.get_env(:maxio, Topology, :__maxio_no_topology__)
    previous_topology_source = Application.get_env(:maxio, :topology_source, :__maxio_no_source__)
    Mix.Task.reenable(@task)

    topology = topology()
    :persistent_term.put(@topology_key, topology)
    Application.put_env(:maxio, Topology, Topology.to_config(topology))
    Application.put_env(:maxio, :topology_source, :config)

    on_exit(fn ->
      restore_topology(previous_topology)
      restore_deployment_topology(previous_deployment_topology)
      restore_topology_source(previous_topology_source)
      Mix.Task.reenable(@task)
    end)

    {:ok, topology: topology}
  end

  test "prints latest workflow phase and JSON", ctx do
    {:ok, job} = seed_decommission_job(ctx.topology)
    Application.put_env(:maxio, :topology_source, "config")

    output = run_workflow([])
    assert output =~ "[maxio rebalance.workflow]"
    assert output =~ "job_id=#{job.id}"
    assert output =~ "kind=decommission"
    assert output =~ "phase=copy_pass"
    assert output =~ "gate_status=attention"
    assert output =~ "[maxio rebalance.workflow.warning] reason=workflow_next_action_required"
    assert output =~ "pool_retired=false"

    decoded = run_workflow(["--job-id", job.id, "--json"]) |> Jason.decode!()
    assert decoded["job_id"] == job.id
    assert decoded["phase"] == "copy_pass"
    assert decoded["status"] == "in_progress"
    assert decoded["gate_status"] == "attention"
    assert decoded["warnings"] == ["workflow_next_action_required"]
    assert decoded["destructive_next_action?"] == false
    assert decoded["next_action"] =~ "mix maxio.rebalance.run"
    assert decoded["runtime_topology"]["pool_ids"] == [0]
  end

  test "prints rebalance workflow phase and JSON", ctx do
    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    output = run_workflow(["--job-id", job.id])
    assert output =~ "[maxio rebalance.workflow]"
    assert output =~ "job_id=#{job.id}"
    assert output =~ "kind=rebalance"
    assert output =~ "phase=copy_pass"
    assert output =~ "gate_status=attention"
    assert output =~ "rebalance_complete=false"
    assert output =~ "rebalance_audit_status=not_checked"
    assert output =~ "rebalance_audit_reason=rebalance_not_at_closure"
    refute output =~ "routing_mismatches=0"
    refute output =~ "unsupported"

    decoded = run_workflow(["--job-id", job.id, "--json"]) |> Jason.decode!()
    assert decoded["job_id"] == job.id
    assert decoded["job_kind"] == "rebalance"
    assert decoded["phase"] == "copy_pass"
    assert decoded["status"] == "in_progress"
    assert decoded["gate_status"] == "attention"
    assert decoded["warnings"] == ["workflow_next_action_required"]
    assert decoded["rebalance_complete?"] == false
    assert decoded["rebalance_audit"]["status"] == "not_checked"
    assert decoded["next_action"] =~ "mix maxio.rebalance.run"
  end

  test "prints blocked rebalance closure next action in text and JSON", ctx do
    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    assert {1, _rows} =
             Repo.update_all(
               from(j in Job, where: j.id == ^job.id),
               set: [
                 status: "complete",
                 data_movement_status: "complete",
                 source_cleanup_status: "complete"
               ]
             )

    {:ok, active} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    output = run_workflow(["--job-id", job.id])
    assert output =~ "status=blocked"
    assert output =~ "gate_status=blocked"
    assert output =~ "phase=rebalance_closure"
    assert output =~ "active_job_exists"
    assert output =~ "next_action=\"mix maxio.rebalance.workflow --job-id #{active.id} --json\""

    decoded = run_workflow(["--job-id", job.id, "--json"]) |> Jason.decode!()
    assert decoded["status"] == "blocked"
    assert decoded["gate_status"] == "blocked"
    assert decoded["phase"] == "rebalance_closure"
    assert decoded["next_action"] == "mix maxio.rebalance.workflow --job-id #{active.id} --json"
    assert decoded["destructive_next_action?"] == false
    assert "active_job_exists" in decoded["blockers"]
  end

  test "reports not_started when no job exists" do
    output = run_workflow([])
    assert output =~ "status=not_started"
    assert output =~ "gate_status=ok"

    decoded = run_workflow(["--json"]) |> Jason.decode!()
    assert decoded["status"] == "not_started"
    assert decoded["gate_status"] == "ok"
    assert decoded["blockers"] == []
    assert decoded["warnings"] == []
    assert decoded["jobs"] == []
  end

  test "fail-on-attention prints JSON before returning a non-zero gate", ctx do
    {:ok, job} = seed_decommission_job(ctx.topology)

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/rebalance workflow attention/, fn ->
          Workflow.run(["--job-id", job.id, "--json", "--fail-on-attention"])
        end
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "in_progress"
    assert decoded["gate_status"] == "attention"
    assert decoded["warnings"] == ["workflow_next_action_required"]
  end

  test "fail-on-blocked prints JSON before returning a non-zero gate", ctx do
    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    assert {1, _rows} =
             Repo.update_all(
               from(j in Job, where: j.id == ^job.id),
               set: [
                 status: "complete",
                 data_movement_status: "complete",
                 source_cleanup_status: "complete"
               ]
             )

    {:ok, active} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/rebalance workflow blocked/, fn ->
          Workflow.run(["--job-id", job.id, "--json", "--fail-on-blocked"])
        end
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "blocked"
    assert decoded["gate_status"] == "blocked"
    assert decoded["next_action"] == "mix maxio.rebalance.workflow --job-id #{active.id} --json"
    assert "active_job_exists" in decoded["blockers"]
  end

  test "fail-on-attention also fails blocked gates after printing evidence", ctx do
    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    assert {1, _rows} =
             Repo.update_all(
               from(j in Job, where: j.id == ^job.id),
               set: [
                 status: "complete",
                 data_movement_status: "complete",
                 source_cleanup_status: "complete"
               ]
             )

    _active = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/rebalance workflow blocked/, fn ->
          Workflow.run(["--job-id", job.id, "--json", "--fail-on-attention"])
        end
      end)

    decoded = Jason.decode!(output)
    assert decoded["gate_status"] == "blocked"
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
    Mix.Task.run("maxio.rebalance.workflow", ["--json"])
    IO.puts("FRESH_SCHEDULER=\#{inspect(Process.whereis(Maxio.Cluster.FreshDriveHeal.Scheduler))}")
    IO.puts("REBALANCE_SCHEDULER=\#{inspect(Process.whereis(Maxio.Cluster.Rebalance.Scheduler))}")
    IO.puts("LIFECYCLE_SCHEDULER=\#{inspect(Process.whereis(Maxio.Lifecycle.Scheduler))}")
    """

    File.mkdir_p!("tmp")

    script_path =
      Path.join(
        "tmp",
        "maxio_rebalance_workflow_probe_#{System.unique_integer([:positive])}.exs"
      )

    File.write!(script_path, code)
    on_exit(fn -> File.rm(script_path) end)

    {cmd, args} = mix_run_no_start_script(script_path)

    {output, status} =
      System.cmd(cmd, args, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "FRESH_SCHEDULER=nil"
    assert output =~ "REBALANCE_SCHEDULER=nil"
    assert output =~ "LIFECYCLE_SCHEDULER=nil"
  end

  defp seed_decommission_job(topology) do
    bucket = bucket_name("workflow-cli")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
  end

  defp run_workflow(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> Workflow.run(args) end)
  end

  defp mix_run_no_start_script(script_path) do
    case :os.type() do
      {:win32, _} -> {"cmd", ["/c", "mix", "run", "--no-start", script_path]}
      _other -> {System.find_executable("mix") || "mix", ["run", "--no-start", script_path]}
    end
  end

  defp topology do
    base = Path.join(System.tmp_dir!(), "maxio_rebalance_workflow_cli")
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

  defp bucket_name(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.replace("-", "")

    "#{prefix}-#{suffix}"
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
end
