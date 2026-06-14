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
    assert output =~ "pool_retired=false"

    decoded = run_workflow(["--job-id", job.id, "--json"]) |> Jason.decode!()
    assert decoded["job_id"] == job.id
    assert decoded["phase"] == "copy_pass"
    assert decoded["status"] == "in_progress"
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
    assert output =~ "phase=rebalance_closure"
    assert output =~ "active_job_exists"
    assert output =~ "next_action=\"mix maxio.rebalance.workflow --job-id #{active.id} --json\""

    decoded = run_workflow(["--job-id", job.id, "--json"]) |> Jason.decode!()
    assert decoded["status"] == "blocked"
    assert decoded["phase"] == "rebalance_closure"
    assert decoded["next_action"] == "mix maxio.rebalance.workflow --job-id #{active.id} --json"
    assert decoded["destructive_next_action?"] == false
    assert "active_job_exists" in decoded["blockers"]
  end

  test "reports not_started when no job exists" do
    assert run_workflow([]) =~ "status=not_started"

    decoded = run_workflow(["--json"]) |> Jason.decode!()
    assert decoded["status"] == "not_started"
    assert decoded["jobs"] == []
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
