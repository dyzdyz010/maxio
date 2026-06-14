defmodule Mix.Tasks.MaxioRebalanceApplyRemovalClusterTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Buckets
  alias Maxio.Cluster.{Placement, Rebalance.Jobs, Topology}
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.Distributed
  alias Mix.Tasks.Maxio.Rebalance.ApplyRemovalCluster

  @owner "arn:aws:iam:::root"
  @task "maxio.rebalance.apply_removal_cluster"
  @topology_key {Maxio.Cluster.Topology, :topology}

  setup do
    InProcess.setup!()
    previous_backend = Application.get_env(:maxio, :storage_backend)
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)
    Application.put_env(:maxio, :storage_backend, Distributed)
    Mix.Task.reenable(@task)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous_backend)
      restore_topology(previous_topology)
      Mix.Task.reenable(@task)
    end)

    :ok
  end

  test "requires explicit confirmation before mutating cluster runtime topology" do
    assert_raise Mix.Error, ~r/requires --yes/, fn ->
      ApplyRemovalCluster.run(["--job-id", "job-id"])
    end
  end

  test "prints cluster runtime removal apply report and records convergence audit" do
    {topology, base} = topology()
    on_exit(fn -> File.rm_rf(base) end)
    :persistent_term.put(@topology_key, topology)
    complete = completed_empty_decommission!("apply-removal-cluster-cli-ready", topology)
    expected_hash = Placement.topology_hash(topology)

    output =
      capture_io(fn ->
        ApplyRemovalCluster.run([
          "--job-id",
          complete.id,
          "--expected-current-topology-hash",
          expected_hash,
          "--yes"
        ])
      end)

    assert output =~ "[maxio rebalance.apply_removal_cluster]"
    assert output =~ "status=applied"
    assert output =~ "apply_scope=cluster_runtime"
    assert output =~ "topology_mutation=cluster_runtime"
    assert output =~ "deployment_config_mutation=false"
    assert Topology.all_set_ids() == [1]

    assert {:ok, updated} = Jobs.get(complete.id)
    assert updated.topology_removal_status == "runtime_local_applied"
    assert updated.topology_removal_cluster_status == "runtime_converged"
    assert updated.topology_removal_cluster_hash
    assert updated.topology_removal_cluster_nodes == [Atom.to_string(Node.self())]
  end

  test "json output includes node results and cluster audit view" do
    {topology, base} = topology()
    on_exit(fn -> File.rm_rf(base) end)
    :persistent_term.put(@topology_key, topology)
    complete = completed_empty_decommission!("apply-removal-cluster-cli-json", topology)

    output =
      capture_io(fn ->
        ApplyRemovalCluster.run(["--job-id", complete.id, "--yes", "--json"])
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "applied"
    assert decoded["apply_scope"] == "cluster_runtime"
    assert decoded["topology_mutation"] == "cluster_runtime"
    assert decoded["deployment_config_mutation"] == false
    assert decoded["proposed_set_ids"] == [1]
    assert [%{"node" => node, "status" => "applied"}] = decoded["node_results"]
    assert node == Atom.to_string(Node.self())
    assert decoded["job"]["topology_removal_cluster_status"] == "runtime_converged"
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

  defp topology do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_apply_removal_cluster_cli_#{System.unique_integer([:positive])}"
      )

    endpoints0 = for i <- 0..1, do: {Node.self(), Path.join(base, "s0d#{i}")}
    endpoints1 = for i <- 0..1, do: {Node.self(), Path.join(base, "s1d#{i}")}

    topology =
      Topology.parse_and_validate!(
        data_shards: 1,
        parity_shards: 1,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [
          %{id: 0, sets: [%{id: 0, endpoints: endpoints0}, %{id: 1, endpoints: endpoints1}]}
        ]
      )

    {topology, base}
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
end
