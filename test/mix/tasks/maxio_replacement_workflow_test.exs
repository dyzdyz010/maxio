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
    assert output =~ "phase=audit"
    assert output =~ "mutating=false"
    assert output =~ "drive_heal_required=1"
    assert output =~ "heal_status=not_requested"
    assert output =~ "rebalance_enqueue_status=not_requested"
    assert output =~ "automation_status=blocked"
    assert output =~ "next_action=\"mix maxio.replacement.workflow --heal --rebalance-if-needed\""
    assert DriveHealth.heal_required?(endpoint)
  end

  test "json command emits machine-readable audit report" do
    decoded =
      capture_io(fn -> Workflow.run(["--json"]) end)
      |> Jason.decode!()

    assert decoded["status"] == "audit"
    assert decoded["phase"] == "audit"
    assert decoded["mutating?"] == false
    assert decoded["probe"]["status"] == "not_requested"
    assert decoded["heal"]["status"] == "not_requested"
    assert decoded["rebalance_enqueue"]["status"] == "not_requested"
    assert decoded["rebalance_advance"]["status"] == "not_requested"
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

    script_path =
      Path.join(
        System.tmp_dir!(),
        "maxio_replacement_workflow_probe_#{System.unique_integer([:positive])}.exs"
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
