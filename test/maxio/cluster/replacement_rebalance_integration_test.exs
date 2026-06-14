defmodule Maxio.Cluster.ReplacementRebalanceIntegrationTest do
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects}

  alias Maxio.Cluster.{
    DriveHealth,
    Paths,
    Placement,
    Rebalance.Jobs,
    Replacement.Workflow,
    Router,
    Topology
  }

  alias Maxio.Cluster.FreshDriveHeal.Scheduler, as: FreshScheduler
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.Distributed

  @owner "arn:aws:iam:::root"
  @topology_key {Topology, :topology}

  setup do
    InProcess.setup!()
    DriveHealth.reset()

    previous_backend = Application.get_env(:maxio, :storage_backend, :__maxio_no_backend__)
    previous_deployment_topology = Application.get_env(:maxio, Topology, :__maxio_no_topology__)
    previous_topology_source = Application.get_env(:maxio, :topology_source, :__maxio_no_source__)
    previous_runtime_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)

    Application.put_env(:maxio, :storage_backend, Distributed)

    {base, topology, endpoints0} = replacement_topology()

    :persistent_term.put(@topology_key, topology)
    Application.put_env(:maxio, Topology, Topology.to_config(topology))
    Application.put_env(:maxio, :topology_source, :config)

    on_exit(fn ->
      restore_app_env(:storage_backend, previous_backend)
      restore_app_env(Topology, previous_deployment_topology)
      restore_app_env(:topology_source, previous_topology_source)
      restore_runtime_topology(previous_runtime_topology)
      DriveHealth.reset()
      InProcess.setup!()
      File.rm_rf(base)
    end)

    {:ok, topology: topology, endpoints0: endpoints0}
  end

  test "replacement workflow heals fresh drive and drains rebalance to verified closure", ctx do
    fixture = seed_replacement_mismatch!(ctx, "replacement-real")
    fresh_scheduler = start_fresh_scheduler!()

    assert {:ok, report} =
             Workflow.run(
               heal: true,
               rebalance_if_needed: true,
               verify_closure: true,
               topology: ctx.topology,
               transport: InProcess,
               no_throttle: true,
               page_size: 1,
               audit_page_size: 1,
               lock_nodes: [Node.self()],
               fresh_scheduler: fn opts -> FreshScheduler.run_now(fresh_scheduler, opts) end
             )

    assert report.status == :ok
    assert report.phase == :rebalance_advanced
    assert report.blockers == []
    assert report.next_action == "none"

    assert report.heal.status == :ok
    assert report.heal.scanned == 1
    assert report.heal.drives_cleared == 1
    assert report.heal.healed_shards > 0

    assert report.rebalance_enqueue.status == :created
    assert report.rebalance_enqueue.kind == "rebalance"
    assert report.rebalance_enqueue.plan_routing_mismatches == 1

    assert report.rebalance_advance.status == :complete
    assert report.rebalance_advance.job_id == report.job_id
    assert report.rebalance_advance.steps == 3
    assert report.rebalance_advance.phases == [:copy, :source_cleanup, :rebalance_closure]
    assert report.rebalance_advance.terminal_phase == :rebalance_closure

    assert report.rebalance_workflow.status == "complete"
    assert report.rebalance_workflow.phase == "rebalance_closure"
    assert report.rebalance_workflow.rebalance_complete?

    refute DriveHealth.heal_required?({fixture.node, fixture.drive})

    assert {:ok, job} = Jobs.get(report.job_id)
    assert job.kind == "rebalance"
    assert job.status == "complete"
    assert job.data_movement_status == "complete"
    assert job.source_cleanup_status == "complete"
    assert job.rebalance_closure_status == "verified"
    assert job.rebalance_closure_results["rebalance_complete?"] == true
    assert job.topology_removal_cluster_status == "not_started"
    assert job.topology_removal_deployment_status == "not_started"
    assert job.physical_removal_status == "not_started"

    assert_read(fixture.bucket, fixture.key, fixture.body, fixture.destination_opts)

    assert {:error, :enoent} =
             Distributed.get(fixture.bucket, fixture.key, "v1", nil, fixture.source_opts)
  end

  test "replacement workflow with one advance step leaves explicit next action", ctx do
    fixture = seed_replacement_mismatch!(ctx, "replacement-partial")
    fresh_scheduler = start_fresh_scheduler!()

    assert {:ok, report} =
             Workflow.run(
               heal: true,
               rebalance_if_needed: true,
               advance_steps: 1,
               topology: ctx.topology,
               transport: InProcess,
               no_throttle: true,
               page_size: 1,
               audit_page_size: 1,
               lock_nodes: [Node.self()],
               fresh_scheduler: fn opts -> FreshScheduler.run_now(fresh_scheduler, opts) end
             )

    assert report.status == :ok
    assert report.phase == :rebalance_advanced
    assert report.blockers == []
    assert report.rebalance_advance.status == :partial
    assert report.rebalance_advance.reason == :max_steps
    assert report.rebalance_advance.steps == 1
    assert report.rebalance_advance.phases == [:copy]
    assert report.next_action =~ "mix maxio.rebalance.cleanup --job-id "

    assert {:ok, job} = Jobs.get(report.job_id)
    assert job.kind == "rebalance"
    assert job.status == "complete"
    assert job.data_movement_status == "complete"
    assert job.source_cleanup_status == "not_started"
    assert job.rebalance_closure_status == "not_started"

    refute DriveHealth.heal_required?({fixture.node, fixture.drive})
    assert_read(fixture.bucket, fixture.key, fixture.body, fixture.destination_opts)
    assert_read(fixture.bucket, fixture.key, fixture.body, fixture.source_opts)
  end

  defp seed_replacement_mismatch!(ctx, prefix) do
    bucket = bucket_name(prefix)
    key = key_for_set(bucket, ctx.topology, 1, prefix)
    body = :crypto.strong_rand_bytes(2048)
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    destination_opts = Keyword.put(opts, :placement_set_id, 1)
    {node, drive} = hd(ctx.endpoints0)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    InProcess.set_drive_down(node, drive)
    assert %{offline: 1, heal_required: 0} = probe(ctx, 0)

    {:ok, write_result} = Distributed.put(bucket, key, "v1", [body], source_opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", body, write_result)

    missing_part = part_path(drive, bucket, key, "v1")
    refute File.exists?(missing_part)

    InProcess.set_drive_up(node, drive)
    assert %{online: 8, heal_required: 1} = probe(ctx, 1)
    assert DriveHealth.heal_required?({node, drive})

    %{
      bucket: bucket,
      key: key,
      body: body,
      source_opts: source_opts,
      destination_opts: destination_opts,
      node: node,
      drive: drive
    }
  end

  defp start_fresh_scheduler! do
    start_supervised!(
      {FreshScheduler,
       [
         name: nil,
         enabled: false,
         scheduler_ledger: [enabled: false],
         lock_nodes: [Node.self()]
       ]}
    )
  end

  defp replacement_topology do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_replacement_rebalance_#{System.unique_integer([:positive])}"
      )

    endpoints0 = for i <- 0..3, do: {Node.self(), Path.join(base, "s0d#{i}")}
    endpoints1 = for i <- 0..3, do: {Node.self(), Path.join(base, "s1d#{i}")}

    topology =
      Topology.parse_and_validate!(
        data_shards: 2,
        parity_shards: 2,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [
          %{id: 0, sets: [%{id: 0, endpoints: endpoints0}, %{id: 1, endpoints: endpoints1}]}
        ]
      )

    {base, topology, endpoints0}
  end

  defp probe(ctx, now_ms) do
    DriveHealth.probe_topology(
      topology: ctx.topology,
      transport: InProcess,
      offline_after_ms: 0,
      now_ms: now_ms
    )
  end

  defp put_object_version!(bucket, key, version_id, body, write_result) do
    Objects.put_version_with_id(
      bucket,
      key,
      version_id,
      %{size: byte_size(body), etag: write_result.etag}
      |> Map.merge(Placement.attrs_from_result(write_result))
    )
  end

  defp assert_read(bucket, key, body, opts) do
    assert {:ok, stream} = Distributed.get(bucket, key, "v1", nil, opts)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  defp dist_opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  defp part_path(drive, bucket, key, version_id) do
    {:ok, rel} = Paths.object_rel(bucket, key, version_id)
    Path.join([drive, rel, "part.0"])
  end

  defp key_for_set(bucket, topology, set_id, prefix) do
    Enum.find_value(0..10_000, fn i ->
      key = "#{prefix}-#{set_id}-#{i}.bin"
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

  defp restore_app_env(key, :__maxio_no_topology__), do: Application.delete_env(:maxio, key)
  defp restore_app_env(key, :__maxio_no_source__), do: Application.delete_env(:maxio, key)
  defp restore_app_env(key, :__maxio_no_backend__), do: Application.delete_env(:maxio, key)
  defp restore_app_env(key, value), do: Application.put_env(:maxio, key, value)

  defp restore_runtime_topology(:__maxio_no_topology__), do: :persistent_term.erase(@topology_key)
  defp restore_runtime_topology(topology), do: :persistent_term.put(@topology_key, topology)
end
