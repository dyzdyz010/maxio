defmodule Mix.Tasks.MaxioRebalanceVerifyRemovalDeploymentTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Buckets
  alias Maxio.Cluster.{Placement, Rebalance.Jobs, Rebalance.TopologyMutation, Topology}
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.Distributed
  alias Mix.Tasks.Maxio.Rebalance.VerifyRemovalDeployment

  @owner "arn:aws:iam:::root"
  @task "maxio.rebalance.verify_removal_deployment"
  @topology_key {Maxio.Cluster.Topology, :topology}

  setup do
    InProcess.setup!()
    previous_backend = Application.get_env(:maxio, :storage_backend)
    previous_deployment_topology = Application.get_env(:maxio, Topology, :__maxio_no_topology__)
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)
    Application.put_env(:maxio, :storage_backend, Distributed)
    Mix.Task.reenable(@task)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous_backend)
      restore_deployment_topology(previous_deployment_topology)
      restore_topology(previous_topology)
      Mix.Task.reenable(@task)
    end)

    :ok
  end

  test "prints deployment verification report and records audit" do
    {job, apply_report, _base} = applied_removal!("verify-removal-cli-ready")
    Application.put_env(:maxio, Topology, apply_report.proposed_config)

    output =
      capture_io(fn ->
        VerifyRemovalDeployment.run(["--job-id", job.id])
      end)

    assert output =~ "[maxio rebalance.verify_removal_deployment]"
    assert output =~ "status=verified"
    assert output =~ "target_set_id=0"
    assert output =~ "target_set_configured=false"
    assert output =~ "write_routing_retired=true"
    assert output =~ "topology_mutation=false"
    assert output =~ "deployment_config_mutation=false"

    assert {:ok, updated} = Jobs.get(job.id)
    assert updated.topology_removal_deployment_status == "verified"
    assert updated.topology_removal_deployment_hash == apply_report.proposed_topology_hash
    assert updated.topology_removal_deployment_verified_at
  end

  test "json output includes deployment hash and updated job view" do
    {job, apply_report, base} = applied_removal!("verify-removal-cli-json")
    Application.put_env(:maxio, Topology, apply_report.proposed_config)

    output =
      capture_io(fn ->
        VerifyRemovalDeployment.run(["--job-id", job.id, "--json"])
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "verified"
    assert decoded["deployment_config_mutation"] == false
    assert decoded["topology_mutation"] == false
    assert decoded["write_routing_retired"] == true
    assert decoded["target_set_configured"] == false
    assert decoded["deployment_set_ids"] == [1]
    assert decoded["deployment_pool_ids"] == [0]
    assert decoded["expected_proposed_hash"] == apply_report.proposed_topology_hash
    assert decoded["deployment_topology_hash"] == apply_report.proposed_topology_hash
    assert decoded["job"]["topology_removal_deployment_status"] == "verified"

    assert decoded["job"]["topology_removal_deployment_hash"] ==
             apply_report.proposed_topology_hash

    refute decoded["deployment_topology_hash"] ==
             Placement.topology_hash(topology(base))
  end

  test "fails when deployment config still contains removed target set" do
    {job, _apply_report, base} = applied_removal!("verify-removal-cli-target")
    Application.put_env(:maxio, Topology, Topology.to_config(topology(base)))

    assert_raise Mix.Error, ~r/deployment topology still contains target_set_id=0/, fn ->
      VerifyRemovalDeployment.run(["--job-id", job.id])
    end

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.topology_removal_deployment_status == "not_started"
  end

  defp applied_removal!(prefix) do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_verify_removal_deployment_cli_#{System.unique_integer([:positive])}"
      )

    topology = topology(base)
    :persistent_term.put(@topology_key, topology)
    job = completed_empty_decommission!(prefix, topology)

    {:ok, apply_report} =
      TopologyMutation.apply_removal_cluster(job.id,
        topology: topology,
        transport: InProcess,
        expected_current_topology_hash: Placement.topology_hash(topology),
        lock_opts: [nodes: [Node.self()]]
      )

    on_exit(fn -> File.rm_rf(base) end)
    {job, apply_report, base}
  end

  defp completed_empty_decommission!(prefix, topology) do
    bucket = bucket_name(prefix)
    opts = [topology: topology, transport: InProcess]
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, complete} = Jobs.complete_data_movement(job.id)
    {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)
    {:ok, complete} = Jobs.complete_source_cleanup(cleaning.id)
    complete
  end

  defp topology(base) do
    endpoints0 = for i <- 0..1, do: {Node.self(), Path.join(base, "s0d#{i}")}
    endpoints1 = for i <- 0..1, do: {Node.self(), Path.join(base, "s1d#{i}")}

    Topology.parse_and_validate!(
      data_shards: 1,
      parity_shards: 1,
      block_size: 1024,
      allow_colocated_endpoints: true,
      pools: [
        %{id: 0, sets: [%{id: 0, endpoints: endpoints0}, %{id: 1, endpoints: endpoints1}]}
      ]
    )
  end

  defp bucket_name(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.replace("-", "")

    "#{prefix}-#{suffix}"
  end

  defp restore_topology(:__maxio_no_topology__),
    do: :persistent_term.erase(@topology_key)

  defp restore_topology(topology),
    do: :persistent_term.put(@topology_key, topology)

  defp restore_deployment_topology(:__maxio_no_topology__),
    do: Application.delete_env(:maxio, Topology)

  defp restore_deployment_topology(topology),
    do: Application.put_env(:maxio, Topology, topology)
end
