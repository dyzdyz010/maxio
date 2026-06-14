defmodule Mix.Tasks.MaxioRebalanceVerifyClosureTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Cluster.{Rebalance.Jobs, Topology}
  alias Mix.Tasks.Maxio.Rebalance.VerifyClosure

  @task "maxio.rebalance.verify_closure"
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

  test "verifies closure and prints JSON", ctx do
    {:ok, job} = completed_empty_rebalance(ctx.topology)

    decoded =
      run_verify_closure(["--job-id", job.id, "--json", "--audit-page-size", "1"])
      |> Jason.decode!()

    assert decoded["job_id"] == job.id
    assert decoded["status"] == "verified"
    assert decoded["phase"] == "rebalance_closure"
    assert decoded["topology_mutation"] == false
    assert decoded["physical_removal"] == false
    assert decoded["rebalance_complete?"] == true
    assert decoded["versions_scanned"] == 0

    assert {:ok, verified} = Jobs.get(job.id)
    assert verified.rebalance_closure_status == "verified"
    assert verified.rebalance_closure_verified_at
    assert verified.rebalance_closure_results["workflow_status"] == "complete"
  end

  test "requires an explicit job id" do
    assert_raise Mix.Error, ~r/requires JOB_ID/, fn ->
      run_verify_closure([])
    end
  end

  defp completed_empty_rebalance(topology) do
    {:ok, job} = Jobs.start_rebalance(topology: topology, include_drive_stats: false)
    {:ok, running} = Jobs.begin_rebalance_data_movement(job.id)
    {:ok, moved} = Jobs.complete_data_movement(running.id)
    {:ok, cleaning} = Jobs.begin_source_cleanup(moved.id)
    Jobs.complete_source_cleanup(cleaning.id)
  end

  defp run_verify_closure(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> VerifyClosure.run(args) end)
  end

  defp topology do
    base = Path.join(System.tmp_dir!(), "maxio_rebalance_verify_closure_cli")
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
