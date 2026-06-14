defmodule Maxio.Cluster.RebalanceDecommissionWorkflowTest do
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects}

  alias Maxio.Cluster.{
    Paths,
    Placement,
    Rebalance.Jobs,
    Rebalance.PhysicalPurge,
    Rebalance.PhysicalRemoval,
    Rebalance.Runner,
    Rebalance.SourceCleanup,
    Rebalance.TopologyMutation,
    Rebalance.Workflow,
    Rebalance.WriteRouting,
    Router,
    Topology,
    TopologyStore
  }

  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.Distributed

  @owner "arn:aws:iam:::root"
  @topology_key {Maxio.Cluster.Topology, :topology}

  setup do
    InProcess.setup!()
    previous_backend = Application.get_env(:maxio, :storage_backend)
    previous_deployment_topology = Application.get_env(:maxio, Topology, :__maxio_no_topology__)
    previous_topology_source = Application.get_env(:maxio, :topology_source, :__maxio_no_source__)
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)
    Application.put_env(:maxio, :storage_backend, Distributed)

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_decommission_workflow_#{System.unique_integer([:positive])}"
      )

    endpoints0 = for i <- 0..1, do: {Node.self(), Path.join(base, "pool0s0d#{i}")}
    endpoints1 = for i <- 0..1, do: {Node.self(), Path.join(base, "pool1s1d#{i}")}

    topology =
      Topology.parse_and_validate!(
        data_shards: 1,
        parity_shards: 1,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [
          %{id: 0, sets: [%{id: 0, endpoints: endpoints0}]},
          %{id: 1, sets: [%{id: 1, endpoints: endpoints1}]}
        ]
      )

    :persistent_term.put(@topology_key, topology)
    Application.put_env(:maxio, Topology, Topology.to_config(topology))
    Application.put_env(:maxio, :topology_source, :config)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous_backend)
      restore_deployment_topology(previous_deployment_topology)
      restore_topology_source(previous_topology_source)
      restore_topology(previous_topology)
      File.rm_rf(base)
    end)

    {:ok, topology: topology}
  end

  test "non-empty decommission reaches pool-retired workflow closure", ctx do
    bucket = bucket_name("decommission-workflow")
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    destination_opts = Keyword.put(opts, :placement_set_id, 1)
    key = key_for_set(bucket, ctx.topology, 0, "versioned")
    marker_key = key_for_set(bucket, ctx.topology, 0, "deleted")

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    {:ok, _v1} = put_object_version!(bucket, key, "v1", "workflow-body-v1", source_opts)
    {:ok, _v2} = put_object_version!(bucket, key, "v2", "workflow-body-v2", source_opts)
    :ok = Distributed.put_delete_marker(bucket, marker_key, "dm1", [], source_opts)

    {:ok, _marker} =
      Objects.insert_delete_marker_with_id(
        bucket,
        marker_key,
        "dm1",
        Placement.attrs_for_write(bucket, marker_key, source_opts)
      )

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    assert {:ok, %{phase: "copy_pass", status: "in_progress"}} = Workflow.summary(job.id)

    assert {:ok, move} =
             Runner.run_once(job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               transport: InProcess
             )

    assert move.status == :ok
    assert move.scanned == 3
    assert move.moved == 3
    assert {:ok, %{phase: "source_cleanup"}} = Workflow.summary(job.id)

    assert {:ok, routes} = WriteRouting.active_routes()
    assert routes == %{0 => 1}

    assert {:ok, cleanup} =
             SourceCleanup.cleanup_once(job.id, topology: ctx.topology, transport: InProcess)

    assert cleanup.status == :ok
    assert cleanup.deleted == 3
    assert {:ok, %{phase: "runtime_topology"}} = Workflow.summary(job.id)

    assert {:ok, v1_stream} = Distributed.get(bucket, key, "v1", nil, destination_opts)
    assert IO.iodata_to_binary(Enum.to_list(v1_stream)) == "workflow-body-v1"
    assert {:ok, v2_stream} = Distributed.get(bucket, key, "v2", nil, destination_opts)
    assert IO.iodata_to_binary(Enum.to_list(v2_stream)) == "workflow-body-v2"
    assert {:error, :enoent} = Distributed.get(bucket, key, "v1", nil, source_opts)
    assert delete_marker_sidecar?(ctx.topology, marker_key, bucket, "dm1", 1)
    refute delete_marker_sidecar?(ctx.topology, marker_key, bucket, "dm1", 0)

    assert {:ok, apply_report} =
             TopologyMutation.apply_removal_cluster(job.id,
               topology: ctx.topology,
               transport: InProcess,
               expected_current_topology_hash: Placement.topology_hash(ctx.topology),
               lock_opts: [nodes: [Node.self()]]
             )

    assert apply_report.proposed_set_ids == [1]
    assert apply_report.current_pool_ids == [0, 1]
    assert apply_report.proposed_pool_ids == [1]
    assert apply_report.removed_pool_ids == [0]
    assert Topology.all_set_ids() == [1]
    assert Topology.pool_ids() == [1]
    assert {:ok, deployment_workflow} = Workflow.summary(job.id)
    assert deployment_workflow.phase == "deployment_topology"
    assert deployment_workflow.pool_retired? == false
    assert deployment_workflow.next_action =~ "persist_removal_deployment"
    assert deployment_workflow.next_action =~ "verify_removal_deployment"
    assert deployment_workflow.next_action =~ apply_report.proposed_topology_hash

    Application.delete_env(:maxio, Topology)
    Application.put_env(:maxio, :topology_source, :db)

    assert {:ok, finalized} =
             TopologyMutation.finalize_removal_deployment(job.id,
               expected_proposed_topology_hash: apply_report.proposed_topology_hash
             )

    assert finalized.write_routing_retired
    assert {:ok, active_topology} = TopologyStore.active_topology()
    assert Topology.pool_ids_from(active_topology) == [1]
    assert {:ok, routes_after_verify} = WriteRouting.active_routes()
    assert routes_after_verify == %{}
    assert {:ok, %{phase: "physical_removal"}} = Workflow.summary(job.id)

    assert {:ok, quarantine} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert quarantine.status == :quarantined

    assert {:ok, %{phase: "physical_purge", destructive_next_action?: true}} =
             Workflow.summary(job.id)

    assert {:ok, purged} =
             PhysicalPurge.apply(job.id,
               confirm_job_id: job.id,
               confirm_quarantine_id: quarantine.quarantine_id,
               retention_seconds: 0,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert purged.status == :purged

    assert {:ok, final} = Workflow.summary(job.id)
    assert final.status == "complete"
    assert final.phase == "retired"
    assert final.next_action == "none"
    assert final.set_retired? == true
    assert final.pool_retired? == true
    assert final.removed_pool_ids == [0]
    assert final.runtime_topology.pool_ids == [1]
    assert final.deployment_topology.pool_ids == [1]
    assert final.blockers == []

    Application.put_env(:maxio, :topology_source, "db")
    assert {:ok, string_source_final} = Workflow.summary(job.id)
    assert string_source_final.status == "complete"
    assert string_source_final.pool_retired? == true

    for {_node, drive} <- Topology.endpoints_from(ctx.topology, 0) do
      refute File.exists?(
               Path.join([drive, ".maxio-removal-quarantine", quarantine.quarantine_id])
             )

      assert File.exists?(Path.join(drive, ".maxio-physical-removal.json"))
      assert File.exists?(Path.join(drive, ".maxio-physical-purge.json"))
      refute File.exists?(Path.join(drive, bucket))
    end
  end

  defp put_object_version!(bucket, key, version_id, body, opts) do
    {:ok, write_result} = Distributed.put(bucket, key, version_id, [body], opts)

    Objects.put_version_with_id(
      bucket,
      key,
      version_id,
      %{size: byte_size(body), etag: write_result.etag}
      |> Map.merge(Placement.attrs_from_result(write_result))
    )
  end

  defp delete_marker_sidecar?(topology, key, bucket, version_id, set_id) do
    {:ok, rel} = Paths.object_rel(bucket, key, version_id)
    {node, drive} = topology |> Topology.endpoints_from(set_id) |> hd()

    case InProcess.get_sidecar(node, Path.join(drive, rel)) do
      {:ok, %{"versions" => [%{"type" => "delete_marker", "version_id" => ^version_id}]}} -> true
      _other -> false
    end
  end

  defp dist_opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  defp key_for_set(bucket, topology, set_id, prefix) do
    Enum.find_value(0..10_000, fn i ->
      key = "#{prefix}-#{set_id}-#{i}.txt"
      if Router.set_for(bucket, key, topology) == set_id, do: key
    end) || flunk("could not find key for set #{inspect(set_id)}")
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
