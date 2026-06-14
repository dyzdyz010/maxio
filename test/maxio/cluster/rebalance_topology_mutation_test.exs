defmodule Maxio.Cluster.RebalanceTopologyMutationTest do
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Multipart, Objects, Repo}

  alias Maxio.Cluster.{
    Lock,
    Placement,
    Rebalance.Job,
    Rebalance.Jobs,
    Rebalance.Runner,
    Rebalance.SourceCleanup,
    Rebalance.TopologyMutation,
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
    Application.put_env(:maxio, :storage_backend, Distributed)
    previous_deployment_topology = Application.get_env(:maxio, Topology, :__maxio_no_topology__)
    previous_topology_source = Application.get_env(:maxio, :topology_source, :__maxio_no_source__)
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_topology_mutation_#{System.unique_integer([:positive])}"
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

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous_backend)
      restore_deployment_topology(previous_deployment_topology)
      restore_topology_source(previous_topology_source)
      restore_topology(previous_topology)
      File.rm_rf(base)
    end)

    {:ok, topology: topology}
  end

  test "removal_preflight is ready after decommission copy and source cleanup", ctx do
    bucket = bucket_name("topology-ready")
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    key = key_for_set(bucket, ctx.topology, 0)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", "ready-body", source_opts)
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:ok, %{status: :ok}} =
             Runner.run_once(job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               transport: InProcess
             )

    assert {:ok, %{status: :ok}} =
             SourceCleanup.cleanup_once(job.id, topology: ctx.topology, transport: InProcess)

    assert {:ok, report} =
             TopologyMutation.removal_preflight(job.id,
               topology: ctx.topology,
               transport: InProcess
             )

    assert report.status == :ready
    assert report.removable
    assert report.blockers == []
    assert report.topology_mutation == false
    assert report.pg_placements_remaining == 0
    assert report.missing_placements == 0
    assert report.unknown_placements == 0
    assert report.active_multipart_uploads == 0
    assert report.physical_residuals == 0
    assert report.endpoint_errors == 0
    assert report.bucket_markers > 0
  end

  test "removal_plan emits proposed topology artifact after ready preflight", ctx do
    {:ok, job} = complete_empty_decommission(ctx)

    assert {:ok, plan} =
             TopologyMutation.removal_plan(job.id,
               topology: ctx.topology,
               transport: InProcess
             )

    assert plan.status == :ready
    assert plan.topology_mutation == false
    assert plan.removed_set_id == 0
    assert plan.removed_pool_id == 0
    assert plan.removed_pool_ids == []
    assert plan.current_set_ids == [0, 1]
    assert plan.proposed_set_ids == [1]
    assert plan.current_pool_ids == [0]
    assert plan.proposed_pool_ids == [0]
    assert plan.current_topology_nodes == [Node.self()]
    assert plan.proposed_topology_nodes == [Node.self()]
    assert plan.current_topology_hash != plan.proposed_topology_hash
    assert Topology.all_set_ids_from(plan.proposed_topology) == [1]
    assert [%{id: 0, sets: [%{id: 1}]}] = plan.proposed_config[:pools]
    assert plan.preflight.removable
  end

  test "removal_plan refuses blocked preflight and returns blockers", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    drive = target_drive(ctx)
    write_layout_residual!(drive, ["orphan-bucket", "stale-object"])

    assert {:error, {:preflight_blocked, report}} =
             TopologyMutation.removal_plan(job.id,
               topology: ctx.topology,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :physical_residuals_present in report.blockers
  end

  test "removal_plan fails closed if removal would leave zero sets" do
    {topology, base} = one_set_topology()
    on_exit(fn -> File.rm_rf(base) end)

    bucket = bucket_name("topology-last-set")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, dist_opts(%{topology: topology}))
    {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, complete} = Jobs.complete_data_movement(job.id)
    {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)
    {:ok, complete} = Jobs.complete_source_cleanup(cleaning.id)

    assert {:error, :would_remove_last_set} =
             TopologyMutation.removal_plan(complete.id,
               topology: topology,
               transport: InProcess
             )
  end

  test "apply_removal installs proposed topology into local runtime and records audit", ctx do
    :persistent_term.put(@topology_key, ctx.topology)
    {:ok, job} = complete_empty_decommission(ctx)
    expected_hash = Placement.topology_hash(ctx.topology)

    assert {:ok, report} =
             TopologyMutation.apply_removal(job.id,
               topology: ctx.topology,
               transport: InProcess,
               expected_current_topology_hash: expected_hash,
               lock_opts: [nodes: [Node.self()]]
             )

    assert report.status == :applied
    assert report.apply_scope == :runtime_local
    assert report.topology_mutation == :runtime_local
    assert report.deployment_config_mutation == false
    assert report.applied_nodes == [Node.self()]
    assert report.current_topology_hash == expected_hash
    assert report.proposed_topology_hash != expected_hash
    assert report.proposed_set_ids == [1]
    assert Topology.all_set_ids() == [1]

    assert {:ok, updated} = Jobs.get(job.id)
    assert updated.topology_removal_status == "runtime_local_applied"
    assert updated.topology_removal_scope == "runtime_local"
    assert updated.topology_removal_current_hash == report.current_topology_hash
    assert updated.topology_removal_proposed_hash == report.proposed_topology_hash
    assert updated.topology_removal_applied_at
  end

  test "apply_removal_cluster installs proposed topology into runtime and records cluster audit",
       ctx do
    :persistent_term.put(@topology_key, ctx.topology)
    {:ok, job} = complete_empty_decommission(ctx)
    expected_hash = Placement.topology_hash(ctx.topology)

    assert {:ok, report} =
             TopologyMutation.apply_removal_cluster(job.id,
               topology: ctx.topology,
               transport: InProcess,
               expected_current_topology_hash: expected_hash,
               lock_opts: [nodes: [Node.self()]]
             )

    assert report.status == :applied
    assert report.apply_scope == :cluster_runtime
    assert report.topology_mutation == :cluster_runtime
    assert report.deployment_config_mutation == false
    assert report.applied_nodes == [Node.self()]
    assert [%{node: node, status: :applied}] = report.node_results
    assert node == Node.self()
    assert Topology.all_set_ids() == [1]

    assert {:ok, updated} = Jobs.get(job.id)
    assert updated.topology_removal_status == "runtime_local_applied"
    assert updated.topology_removal_cluster_status == "runtime_converged"
    assert updated.topology_removal_cluster_hash == report.proposed_topology_hash
    assert updated.topology_removal_cluster_nodes == [Atom.to_string(Node.self())]
    assert updated.topology_removal_cluster_verified_at
    assert updated.topology_removal_removed_pool_ids == []
    assert updated.topology_removal_target_endpoints == report.target_endpoints

    assert %{
             "target_set_id" => 0,
             "target_pool_id" => 0,
             "endpoints" => target_endpoints
           } = updated.topology_removal_target_endpoints

    assert length(target_endpoints) == 2
    assert Enum.all?(target_endpoints, &(&1["node"] == Atom.to_string(Node.self())))
  end

  test "apply_removal_cluster fails closed on remote mismatch before local runtime install",
       ctx do
    :persistent_term.put(@topology_key, ctx.topology)
    {:ok, job} = complete_empty_decommission(ctx)
    expected_hash = Placement.topology_hash(ctx.topology)

    assert {:error, {:cluster_topology_apply_failed, report}} =
             TopologyMutation.apply_removal_cluster(job.id,
               topology: ctx.topology,
               transport: InProcess,
               nodes: [:stale_remote, Node.self()],
               expected_current_topology_hash: expected_hash,
               lock_opts: [nodes: [Node.self()]],
               node_apply_fun: fn
                 :stale_remote, _topology, _expected ->
                   {:error, {:runtime_topology_hash_mismatch, expected_hash, "stale"}}

                 node, topology, expected ->
                   Topology.install_runtime_if_hash(topology, expected)
                   |> case do
                     {:ok, snapshot} -> {:ok, Map.put(snapshot, :node, node)}
                     other -> other
                   end
               end
             )

    assert report.status == :blocked
    assert report.failed_nodes == [:stale_remote]
    assert Enum.any?(report.node_results, &(&1.node == :stale_remote and &1.status == :error))
    assert Topology.all_set_ids() == [0, 1]

    assert {:ok, audited} = Jobs.get(job.id)
    assert audited.topology_removal_status == "runtime_local_applied"
    assert audited.topology_removal_cluster_status == "not_started"
  end

  test "apply_removal_cluster requires removed-set-only topology nodes by default",
       ctx do
    {topology, removed_node, base} = removed_set_only_topology()
    on_exit(fn -> File.rm_rf(base) end)
    :persistent_term.put(@topology_key, topology)
    {:ok, job} = complete_empty_decommission(Map.put(ctx, :topology, topology))
    expected_hash = Placement.topology_hash(topology)

    assert {:ok, plan} =
             TopologyMutation.removal_plan(job.id,
               topology: topology,
               transport: InProcess
             )

    assert removed_node in plan.current_topology_nodes
    refute removed_node in plan.proposed_topology_nodes

    assert {:error, {:cluster_topology_apply_failed, report}} =
             TopologyMutation.apply_removal_cluster(job.id,
               topology: topology,
               transport: InProcess,
               expected_current_topology_hash: expected_hash,
               lock_opts: [nodes: [Node.self()]]
             )

    assert removed_node in report.required_nodes
    assert report.failed_nodes == [removed_node]

    assert Enum.any?(report.node_results, fn result ->
             result.node == removed_node and result.status == :error
           end)

    assert Topology.all_set_ids() == [0, 1]
  end

  test "apply_removal refuses stale expected topology hash before runtime mutation", ctx do
    :persistent_term.put(@topology_key, ctx.topology)
    {:ok, job} = complete_empty_decommission(ctx)

    assert {:error, {:current_topology_hash_mismatch, "stale", _actual}} =
             TopologyMutation.apply_removal(job.id,
               topology: ctx.topology,
               transport: InProcess,
               expected_current_topology_hash: "stale",
               lock_opts: [nodes: [Node.self()]]
             )

    assert Topology.all_set_ids() == [0, 1]
    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.topology_removal_status == "not_started"
    assert unchanged.topology_removal_scope == "none"
  end

  test "apply_removal is serialized by one runtime topology mutation lock", ctx do
    :persistent_term.put(@topology_key, ctx.topology)
    {:ok, job} = complete_empty_decommission(ctx)

    {:ok, lease} =
      Lock.acquire(Topology.runtime_mutation_lock_resource(),
        nodes: [Node.self()],
        refresh: false
      )

    try do
      task =
        Task.async(fn ->
          TopologyMutation.apply_removal(job.id,
            topology: ctx.topology,
            transport: InProcess,
            lock_opts: [nodes: [Node.self()], refresh: false]
          )
        end)

      assert {:error, :topology_apply_locked} = Task.await(task)
      assert Topology.all_set_ids() == [0, 1]

      assert {:ok, unchanged} = Jobs.get(job.id)
      assert unchanged.topology_removal_status == "not_started"
      assert unchanged.topology_removal_scope == "none"
    after
      Lock.release(lease)
    end
  end

  test "job creation shares the runtime topology mutation lock", ctx do
    {:ok, lease} =
      Lock.acquire(Topology.runtime_mutation_lock_resource(),
        nodes: [Node.self()],
        refresh: false
      )

    try do
      task =
        Task.async(fn ->
          Jobs.start_decommission(0,
            topology: ctx.topology,
            include_drive_stats: false,
            topology_lock_opts: [nodes: [Node.self()], refresh: false]
          )
        end)

      assert {:error, :topology_mutation_locked} = Task.await(task)
      assert [] = Jobs.list()
    after
      Lock.release(lease)
    end
  end

  test "source cleanup activation shares the runtime topology mutation lock", ctx do
    bucket = bucket_name("topology-cleanup-lock")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, dist_opts(ctx))
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, complete} = Jobs.complete_data_movement(job.id)

    {:ok, lease} =
      Lock.acquire(Topology.runtime_mutation_lock_resource(),
        nodes: [Node.self()],
        refresh: false
      )

    try do
      task =
        Task.async(fn ->
          SourceCleanup.cleanup_once(complete.id,
            topology: ctx.topology,
            transport: InProcess,
            runner_lock_opts: [nodes: [Node.self()], refresh: false],
            topology_lock_opts: [nodes: [Node.self()], refresh: false]
          )
        end)

      assert {:error, :topology_mutation_locked} = Task.await(task)

      assert {:ok, unchanged} = Jobs.get(complete.id)
      assert unchanged.status == "complete"
      assert unchanged.source_cleanup_status == "not_started"
    after
      Lock.release(lease)
    end
  end

  test "apply_removal refuses mismatched already-applied audit before runtime mutation", ctx do
    :persistent_term.put(@topology_key, ctx.topology)
    {:ok, job} = complete_empty_decommission(ctx)

    {:ok, plan} =
      TopologyMutation.removal_plan(job.id,
        topology: ctx.topology,
        transport: InProcess
      )

    assert {:ok, _job} =
             Jobs.mark_topology_removal_applied(job.id, %{
               current_topology_hash: plan.current_topology_hash,
               proposed_topology_hash: "different-proposed-hash"
             })

    assert {:error, :topology_removal_already_applied} =
             TopologyMutation.apply_removal(job.id,
               topology: ctx.topology,
               transport: InProcess,
               expected_current_topology_hash: plan.current_topology_hash,
               lock_opts: [nodes: [Node.self()]]
             )

    assert Topology.all_set_ids() == [0, 1]

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.topology_removal_status == "runtime_local_applied"
    assert unchanged.topology_removal_current_hash == plan.current_topology_hash
    assert unchanged.topology_removal_proposed_hash == "different-proposed-hash"
  end

  test "apply_removal can recover when lock is lost after audit before runtime install", ctx do
    :persistent_term.put(@topology_key, ctx.topology)
    {:ok, job} = complete_empty_decommission(ctx)
    parent = self()

    task =
      Task.async(fn ->
        TopologyMutation.apply_removal(job.id,
          topology: ctx.topology,
          transport: InProcess,
          lock_opts: [nodes: [Node.self()], ttl_ms: 1_000, heartbeat_ms: 10],
          after_topology_removal_audit: fn ->
            send(parent, :topology_removal_audit_recorded)

            receive do
              :continue -> :ok
            end
          end
        )
      end)

    assert_receive :topology_removal_audit_recorded
    assert Topology.all_set_ids() == [0, 1]

    assert {:ok, audited} = Jobs.get(job.id)
    assert audited.topology_removal_status == "runtime_local_applied"
    assert audited.topology_removal_scope == "runtime_local"

    assert :ok =
             Lock.force_unlock(Topology.runtime_mutation_lock_resource(), nodes: [Node.self()])

    assert {:error, :topology_apply_locked} = Task.await(task, 3_000)
    assert Topology.all_set_ids() == [0, 1]

    assert {:ok, recovered} =
             TopologyMutation.apply_removal(job.id,
               topology: ctx.topology,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert recovered.status == :applied
    assert recovered.job.topology_removal_status == "runtime_local_applied"
    assert Topology.all_set_ids() == [1]
  end

  test "verify_removal_deployment records deployment audit after config matches apply artifact",
       ctx do
    {_job, apply_report} = applied_empty_removal(ctx)
    Application.put_env(:maxio, Topology, apply_report.proposed_config)

    assert {:ok, report} =
             TopologyMutation.verify_removal_deployment(apply_report.job_id)

    assert report.status == :verified
    assert report.topology_mutation == false
    assert report.deployment_config_mutation == false
    assert report.write_routing_retired
    assert report.target_set_configured == false
    assert report.deployment_set_ids == [1]
    assert report.deployment_pool_ids == [0]
    assert report.expected_proposed_hash == apply_report.proposed_topology_hash
    assert report.deployment_topology_hash == apply_report.proposed_topology_hash
    assert report.cluster_runtime.status == :converged
    assert report.blockers == []

    assert {:ok, updated} = Jobs.get(apply_report.job_id)
    assert updated.topology_removal_deployment_status == "verified"
    assert updated.topology_removal_deployment_hash == apply_report.proposed_topology_hash
    assert updated.topology_removal_deployment_verified_at
  end

  test "persist_removal_deployment writes active DB revision and verify consumes it",
       ctx do
    {_job, apply_report} = applied_empty_removal(ctx)
    Application.delete_env(:maxio, Topology)

    assert {:ok, persist_report} =
             TopologyMutation.persist_removal_deployment(apply_report.job_id,
               expected_proposed_topology_hash: apply_report.proposed_topology_hash
             )

    assert persist_report.status == :persisted
    assert persist_report.topology_mutation == false
    assert persist_report.deployment_config_mutation == :db_active_revision
    assert persist_report.expected_proposed_hash == apply_report.proposed_topology_hash
    assert persist_report.deployment_topology_hash == apply_report.proposed_topology_hash
    assert persist_report.deployment_set_ids == [1]
    assert persist_report.deployment_pool_ids == [0]
    assert persist_report.revision_id

    assert {:ok, active_topology} = TopologyStore.active_topology()
    assert Placement.topology_hash(active_topology) == apply_report.proposed_topology_hash

    Application.put_env(:maxio, :topology_source, :db)

    assert {:ok, verify_report} =
             TopologyMutation.verify_removal_deployment(apply_report.job_id)

    assert verify_report.status == :verified
    assert verify_report.deployment_topology_hash == apply_report.proposed_topology_hash
    assert verify_report.write_routing_retired
  end

  test "finalize_removal_deployment persists and verifies under one final gate",
       ctx do
    {_job, apply_report} = applied_empty_removal(ctx)
    Application.delete_env(:maxio, Topology)
    Application.put_env(:maxio, :topology_source, :db)

    assert {:ok, report} =
             TopologyMutation.finalize_removal_deployment(apply_report.job_id,
               expected_proposed_topology_hash: apply_report.proposed_topology_hash
             )

    assert report.status == :verified
    assert report.topology_mutation == false
    assert report.deployment_config_mutation == :db_active_revision
    assert report.expected_proposed_hash == apply_report.proposed_topology_hash
    assert report.deployment_topology_hash == apply_report.proposed_topology_hash
    assert report.revision_id == report.persistence.revision_id
    assert report.write_routing_retired
    assert report.verification.write_routing_retired
    assert report.job.topology_removal_deployment_status == "verified"

    assert {:ok, active_topology} = TopologyStore.active_topology()
    assert Placement.topology_hash(active_topology) == apply_report.proposed_topology_hash
  end

  test "physical_removal_preflight is ready after deployment verification using stored endpoints",
       ctx do
    {_job, apply_report} = applied_empty_removal(ctx)
    Application.delete_env(:maxio, Topology)
    Application.put_env(:maxio, :topology_source, :db)

    assert {:ok, _finalized} =
             TopologyMutation.finalize_removal_deployment(apply_report.job_id,
               expected_proposed_topology_hash: apply_report.proposed_topology_hash
             )

    assert {:ok, report} =
             TopologyMutation.physical_removal_preflight(apply_report.job_id,
               transport: InProcess
             )

    assert report.status == :ready
    assert report.removable
    assert report.blockers == []
    assert report.topology_mutation == false
    assert report.deployment_config_mutation == false
    assert report.physical_removal == false
    assert report.target_endpoints == apply_report.target_endpoints
    assert report.removed_pool_ids == []
    assert report.endpoints == 2
    assert report.endpoint_errors == 0
    assert report.physical_residuals == 0
    assert report.bucket_markers > 0
  end

  test "physical_removal_preflight attaches sanitized drive hardware evidence", ctx do
    {_job, apply_report} = applied_empty_removal(ctx)
    finalize_applied_removal!(apply_report)

    provider = fn drive ->
      {:ok,
       %{
         mount_root: Path.expand(drive),
         mount_source: "/dev/#{Path.basename(drive)}",
         major_minor: "8:1",
         block_device: Path.basename(drive),
         serial: "SERIAL-#{Path.basename(drive)}",
         wwid: "WWID-#{Path.basename(drive)}",
         source: :test_sysfs
       }}
    end

    assert {:ok, report} =
             TopologyMutation.physical_removal_preflight(apply_report.job_id,
               transport: InProcess,
               drive_hardware_evidence: true,
               hardware_evidence_provider: provider,
               hardware_evidence_now_ms: 444
             )

    assert report.status == :ready
    assert report.removable
    assert report.drive_hardware_evidence_status == :ok
    assert report.drive_hardware_evidence_errors == 0
    assert report.drive_hardware_evidence_gate == false
    assert report.drive_hardware_evidence.endpoints == 2
    assert report.drive_hardware_evidence.ok == 2
    assert Map.fetch!(report.drive_hardware_evidence, :destructive_gate?) == false

    [first | _] = report.drive_hardware_evidence.samples
    assert first.set_id == 0
    assert first.endpoint_index == 0
    assert first.observed_at_ms == 444
    assert first.serial_hash == sha256("SERIAL-#{Path.basename(first.drive)}")
    refute inspect(report.drive_hardware_evidence) =~ "SERIAL-"
    refute inspect(report.drive_hardware_evidence) =~ "WWID-"
  end

  test "physical_removal_preflight keeps hardware evidence errors out of blockers", ctx do
    {_job, apply_report} = applied_empty_removal(ctx)
    finalize_applied_removal!(apply_report)

    provider = fn _drive -> {:error, {:probe_failed, "SERIAL-SECRET"}} end

    assert {:ok, report} =
             TopologyMutation.physical_removal_preflight(apply_report.job_id,
               transport: InProcess,
               drive_hardware_evidence: true,
               hardware_evidence_provider: provider
             )

    assert report.status == :ready
    assert report.removable
    assert report.blockers == []
    assert report.endpoint_errors == 0
    assert report.drive_hardware_evidence_status == :partial
    assert report.drive_hardware_evidence_errors == 2
    assert Enum.all?(report.drive_hardware_evidence.samples, &(&1.status == :error))
    refute inspect(report.drive_hardware_evidence) =~ "SERIAL-SECRET"
  end

  test "physical_removal_preflight blocks before deployment verification", ctx do
    {_job, apply_report} = applied_empty_removal(ctx)

    assert {:ok, report} =
             TopologyMutation.physical_removal_preflight(apply_report.job_id,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :deployment_not_verified in report.blockers
    refute report.removable
  end

  test "physical_removal_preflight blocks legacy jobs without endpoint manifest", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    proposed_hash = "proposed-without-manifest"

    {:ok, applied} =
      Jobs.mark_topology_removal_applied(job.id, %{
        current_topology_hash: Placement.topology_hash(ctx.topology),
        proposed_topology_hash: proposed_hash
      })

    {:ok, converged} =
      Jobs.mark_topology_removal_cluster_converged(applied, %{
        cluster_topology_hash: proposed_hash,
        cluster_nodes: [Node.self()]
      })

    {:ok, _verified} =
      Jobs.mark_topology_removal_deployment_verified(converged, %{
        deployment_topology_hash: proposed_hash
      })

    assert {:ok, report} =
             TopologyMutation.physical_removal_preflight(job.id,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :missing_physical_removal_manifest in report.blockers
    assert report.physical_residuals == 0
  end

  test "physical_removal_preflight blocks malformed manifest entries without partial probing",
       ctx do
    {_job, apply_report} = applied_empty_removal(ctx)
    finalize_applied_removal!(apply_report)

    [first_endpoint, second_endpoint | _] = apply_report.target_endpoints["endpoints"]

    malformed_manifest = %{
      apply_report.target_endpoints
      | "endpoints" => [first_endpoint, Map.delete(second_endpoint, "drive")]
    }

    replace_topology_removal_manifest!(apply_report.job_id, malformed_manifest)

    assert {:ok, report} =
             TopologyMutation.physical_removal_preflight(apply_report.job_id,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :invalid_physical_removal_manifest in report.blockers
    assert report.endpoints == 0
    assert report.endpoint_errors == 1
    refute report.removable
  end

  test "physical_removal_preflight blocks manifest target-set mismatch", ctx do
    {_job, apply_report} = applied_empty_removal(ctx)
    finalize_applied_removal!(apply_report)

    wrong_set_manifest = %{apply_report.target_endpoints | "target_set_id" => 1}
    replace_topology_removal_manifest!(apply_report.job_id, wrong_set_manifest)

    assert {:ok, report} =
             TopologyMutation.physical_removal_preflight(apply_report.job_id,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :invalid_physical_removal_manifest in report.blockers
    assert report.endpoints == 0
    refute report.removable
  end

  test "physical_removal_preflight blocks unknown-node manifest without creating atoms", ctx do
    {_job, apply_report} = applied_empty_removal(ctx)
    finalize_applied_removal!(apply_report)

    unknown_node_manifest =
      update_in(apply_report.target_endpoints, ["endpoints"], fn [first_endpoint | rest] ->
        [%{first_endpoint | "node" => "unknown-physical-node@maxio-invalid"} | rest]
      end)

    replace_topology_removal_manifest!(apply_report.job_id, unknown_node_manifest)

    assert {:ok, report} =
             TopologyMutation.physical_removal_preflight(apply_report.job_id,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :invalid_physical_removal_manifest in report.blockers
    assert report.endpoints == 0

    assert Enum.any?(report.examples, fn example ->
             String.contains?(example.reason, "unknown_physical_removal_node")
           end)
  end

  test "physical_removal_preflight blocks endpoint failures and physical residuals", ctx do
    {_job, apply_report} = applied_empty_removal(ctx)
    Application.delete_env(:maxio, Topology)
    Application.put_env(:maxio, :topology_source, :db)

    assert {:ok, _finalized} =
             TopologyMutation.finalize_removal_deployment(apply_report.job_id,
               expected_proposed_topology_hash: apply_report.proposed_topology_hash
             )

    [{node, drive} | _] = Topology.endpoints_from(ctx.topology, 0)
    write_layout_residual!(drive, [".uploads", "orphan-bucket", "orphan-upload", "1"])

    assert {:ok, residual_report} =
             TopologyMutation.physical_removal_preflight(apply_report.job_id,
               transport: InProcess
             )

    assert residual_report.status == :blocked
    assert :physical_residuals_present in residual_report.blockers
    assert residual_report.physical_residuals > 0
    assert Enum.any?(residual_report.examples, &(&1.layout == :uploads))

    assert File.exists?(
             Path.join([drive, ".uploads", "orphan-bucket", "orphan-upload", "1", "part.0"])
           )

    InProcess.set_drive_down(node, drive)

    assert {:ok, down_report} =
             TopologyMutation.physical_removal_preflight(apply_report.job_id,
               transport: InProcess
             )

    assert down_report.status == :blocked
    assert :target_endpoints_unreachable in down_report.blockers
    assert down_report.endpoint_errors > 0
  end

  test "finalize_removal_deployment refuses active jobs before persistence",
       ctx do
    {_job, apply_report} = applied_empty_removal(ctx)
    Application.delete_env(:maxio, Topology)
    Application.put_env(:maxio, :topology_source, :db)

    assert {:ok, active} =
             Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    assert {:error, {:active_job_exists, active_view}} =
             TopologyMutation.finalize_removal_deployment(apply_report.job_id,
               expected_proposed_topology_hash: apply_report.proposed_topology_hash
             )

    assert active_view.id == active.id
    assert {:error, :no_active_topology_revision} = TopologyStore.active_revision()

    assert {:ok, unchanged} = Jobs.get(apply_report.job_id)
    assert unchanged.topology_removal_deployment_status == "not_started"
  end

  test "persist_removal_deployment refuses stale expected proposed hash",
       ctx do
    {_job, apply_report} = applied_empty_removal(ctx)

    assert {:error, {:proposed_topology_hash_mismatch, proposed_hash, "stale"}} =
             TopologyMutation.persist_removal_deployment(apply_report.job_id,
               expected_proposed_topology_hash: "stale"
             )

    assert proposed_hash == apply_report.proposed_topology_hash
    assert {:error, :no_active_topology_revision} = TopologyStore.active_revision()
  end

  test "verify_removal_deployment does not trust DB revision while topology source is config",
       ctx do
    {_job, apply_report} = applied_empty_removal(ctx)
    Application.delete_env(:maxio, Topology)
    Application.put_env(:maxio, :topology_source, :config)

    assert {:ok, _persist_report} =
             TopologyMutation.persist_removal_deployment(apply_report.job_id,
               expected_proposed_topology_hash: apply_report.proposed_topology_hash
             )

    assert {:error, :no_deployment_topology} =
             TopologyMutation.verify_removal_deployment(apply_report.job_id)
  end

  test "verify_removal_deployment refuses deployment config that still contains target set",
       ctx do
    {job, _apply_report} = applied_empty_removal(ctx)
    Application.put_env(:maxio, Topology, Topology.to_config(ctx.topology))

    assert {:error, {:target_set_still_configured, 0, [0, 1]}} =
             TopologyMutation.verify_removal_deployment(job.id)

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.topology_removal_deployment_status == "not_started"
  end

  test "verify_removal_deployment refuses deployment config hash mismatch", ctx do
    {job, apply_report} = applied_empty_removal(ctx)
    mismatched_config = Keyword.put(apply_report.proposed_config, :block_size, 2048)
    Application.put_env(:maxio, Topology, mismatched_config)

    assert {:error, {:deployment_topology_hash_mismatch, expected_proposed_hash, actual_hash}} =
             TopologyMutation.verify_removal_deployment(job.id)

    assert expected_proposed_hash == apply_report.proposed_topology_hash
    assert actual_hash != expected_proposed_hash

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.topology_removal_deployment_status == "not_started"
  end

  test "verify_removal_deployment refuses stale runtime on any selected cluster node",
       ctx do
    {job, apply_report} = applied_empty_removal(ctx)
    Application.put_env(:maxio, Topology, apply_report.proposed_config)

    assert {:error, {:cluster_runtime_topology_not_converged, report}} =
             TopologyMutation.verify_removal_deployment(job.id,
               nodes: [:stale_remote, Node.self()],
               node_snapshot_fun: fn
                 :stale_remote ->
                   {:ok,
                    %{
                      node: :stale_remote,
                      runtime_status: :configured,
                      topology_hash: apply_report.current_topology_hash,
                      set_ids: [0, 1],
                      pool_ids: [0]
                    }}

                 _node ->
                   {:ok, Topology.runtime_snapshot()}
               end
             )

    assert report.status == :blocked
    assert report.expected_topology_hash == apply_report.proposed_topology_hash
    assert report.failed_nodes == [:stale_remote]

    assert Enum.any?(report.node_results, fn result ->
             result.node == :stale_remote and result.status == :hash_mismatch
           end)

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.topology_removal_deployment_status == "not_started"
  end

  test "verify_removal_deployment refuses missing nodes from cluster convergence audit",
       ctx do
    {topology, removed_node, base} = removed_set_only_topology()
    on_exit(fn -> File.rm_rf(base) end)
    :persistent_term.put(@topology_key, topology)
    {:ok, job} = complete_empty_decommission(Map.put(ctx, :topology, topology))

    {:ok, plan} =
      TopologyMutation.removal_plan(job.id,
        topology: topology,
        transport: InProcess
      )

    {:ok, audited} =
      Jobs.mark_topology_removal_applied(job.id, %{
        current_topology_hash: plan.current_topology_hash,
        proposed_topology_hash: plan.proposed_topology_hash
      })

    Topology.install_runtime!(plan.proposed_topology)

    {:ok, _clustered} =
      Jobs.mark_topology_removal_cluster_converged(audited, %{
        cluster_topology_hash: plan.proposed_topology_hash,
        cluster_nodes: [removed_node, Node.self()]
      })

    Application.put_env(:maxio, Topology, plan.proposed_config)

    assert {:error, {:cluster_runtime_topology_not_converged, report}} =
             TopologyMutation.verify_removal_deployment(job.id,
               nodes: [Node.self()],
               lock_opts: [nodes: [Node.self()]]
             )

    removed_node_name = Atom.to_string(removed_node)
    assert report.missing_expected_nodes == [removed_node_name]
    assert report.failed_nodes == [removed_node_name]

    assert Enum.any?(report.node_results, fn result ->
             result.node == removed_node_name and result.status == :missing_expected_node
           end)

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.topology_removal_deployment_status == "not_started"
  end

  test "verify_removal_deployment blocks stale PG and MPU placement metadata", ctx do
    {job, apply_report} = applied_empty_removal(ctx)
    Application.put_env(:maxio, Topology, apply_report.proposed_config)
    bucket = bucket_name("topology-deployment-block")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, "late-target.txt", "v1", %{
        size: 1,
        etag: "e1",
        placement_set_id: 0
      })

    {:ok, upload} =
      Multipart.initiate(
        bucket,
        "active-target.bin",
        %{},
        Keyword.put(dist_opts(ctx), :placement_set_id, 0)
      )

    assert upload.placement_set_id == 0

    assert {:error, {:deployment_verification_blocked, report}} =
             TopologyMutation.verify_removal_deployment(job.id)

    assert report.status == :blocked
    assert :pg_placements_remaining in report.blockers
    assert :active_multipart_uploads in report.blockers
    assert report.pg_placements_remaining == 1
    assert report.active_multipart_uploads == 1

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.topology_removal_deployment_status == "not_started"
  end

  test "verify_removal_deployment requires runtime apply audit first", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    Application.put_env(:maxio, Topology, Topology.to_config(ctx.topology))

    assert {:error, :topology_removal_not_applied} =
             TopologyMutation.verify_removal_deployment(job.id)
  end

  test "verify_removal_deployment refuses audit-only job when runtime topology is still old",
       ctx do
    :persistent_term.put(@topology_key, ctx.topology)
    {:ok, job} = complete_empty_decommission(ctx)

    {:ok, plan} =
      TopologyMutation.removal_plan(job.id,
        topology: ctx.topology,
        transport: InProcess
      )

    assert {:ok, audited} =
             Jobs.mark_topology_removal_applied(job.id, %{
               current_topology_hash: plan.current_topology_hash,
               proposed_topology_hash: plan.proposed_topology_hash
             })

    assert {:ok, _clustered} =
             Jobs.mark_topology_removal_cluster_converged(audited, %{
               cluster_topology_hash: plan.proposed_topology_hash,
               cluster_nodes: [Node.self()]
             })

    Application.put_env(:maxio, Topology, plan.proposed_config)

    assert {:error, {:cluster_runtime_topology_not_converged, report}} =
             TopologyMutation.verify_removal_deployment(job.id,
               lock_opts: [nodes: [Node.self()]]
             )

    assert report.expected_topology_hash == plan.proposed_topology_hash
    assert report.failed_nodes == [Node.self()]

    assert Enum.any?(report.node_results, fn result ->
             result.node == Node.self() and result.status == :hash_mismatch and
               result.actual_topology_hash == plan.current_topology_hash
           end)

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.topology_removal_deployment_status == "not_started"
  end

  test "verify_removal_deployment is serialized with audit-before-runtime-install apply window",
       ctx do
    :persistent_term.put(@topology_key, ctx.topology)
    {:ok, job} = complete_empty_decommission(ctx)

    {:ok, plan} =
      TopologyMutation.removal_plan(job.id,
        topology: ctx.topology,
        transport: InProcess
      )

    Application.put_env(:maxio, Topology, plan.proposed_config)
    parent = self()

    task =
      Task.async(fn ->
        TopologyMutation.apply_removal(job.id,
          topology: ctx.topology,
          transport: InProcess,
          lock_opts: [nodes: [Node.self()], refresh: false],
          after_topology_removal_audit: fn ->
            send(parent, {:topology_removal_audit_recorded_for_verify, self()})

            receive do
              :continue_verify_serialization -> :ok
            end
          end
        )
      end)

    assert_receive {:topology_removal_audit_recorded_for_verify, apply_worker}

    assert {:error, :topology_verify_locked} =
             TopologyMutation.verify_removal_deployment(job.id,
               lock_opts: [nodes: [Node.self()], refresh: false]
             )

    assert {:ok, audited} = Jobs.get(job.id)
    assert audited.topology_removal_status == "runtime_local_applied"
    assert audited.topology_removal_deployment_status == "not_started"
    assert Topology.all_set_ids() == [0, 1]

    send(apply_worker, :continue_verify_serialization)
    assert {:ok, applied} = Task.await(task, 3_000)
    assert applied.status == :applied
    assert Topology.all_set_ids() == [1]
  end

  test "removal_preflight blocks before source cleanup removes source shards", ctx do
    bucket = bucket_name("topology-block-residual")
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    key = key_for_set(bucket, ctx.topology, 0)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", "residual-body", source_opts)
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:ok, %{status: :ok}} =
             Runner.run_once(job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               transport: InProcess
             )

    assert {:ok, report} =
             TopologyMutation.removal_preflight(job.id,
               topology: ctx.topology,
               transport: InProcess
             )

    assert report.status == :blocked
    refute report.removable
    assert :source_cleanup_not_complete in report.blockers
    assert :physical_residuals_present in report.blockers
    assert report.pg_placements_remaining == 0
    assert report.physical_residuals > 0
    assert Enum.any?(report.examples, &(&1.type == :physical_residual))
  end

  test "removal_preflight blocks when PG placement still points at target set", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    bucket = bucket_name("topology-block-pg")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, "late.txt", "v1", %{
        size: 1,
        etag: "e1",
        placement_set_id: 0
      })

    assert {:ok, report} =
             TopologyMutation.removal_preflight(job.id,
               topology: ctx.topology,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :pg_placements_remaining in report.blockers
    assert report.pg_placements_remaining == 1
  end

  test "removal_preflight blocks when object placement rows are missing or unknown", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    bucket = bucket_name("topology-block-placement")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, _missing} =
      Objects.put_version_with_id(bucket, "missing.txt", "v1", %{
        size: 1,
        etag: "e1"
      })

    {:ok, _unknown} =
      Objects.put_version_with_id(bucket, "unknown.txt", "v1", %{
        size: 1,
        etag: "e2",
        placement_set_id: 99
      })

    assert {:ok, report} =
             TopologyMutation.removal_preflight(job.id,
               topology: ctx.topology,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :missing_persisted_placement in report.blockers
    assert :unknown_placement_set in report.blockers
    assert report.missing_placements == 1
    assert report.unknown_placements == 1
  end

  test "removal_preflight blocks physical residuals under unindexed bucket roots", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    drive = target_drive(ctx)
    write_layout_residual!(drive, ["orphan-bucket", "stale-object"])

    assert {:ok, report} =
             TopologyMutation.removal_preflight(job.id,
               topology: ctx.topology,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :physical_residuals_present in report.blockers
    assert report.physical_residuals > 0

    assert Enum.any?(report.examples, fn example ->
             example.type == :physical_residual and example.bucket == "orphan-bucket"
           end)
  end

  test "removal_preflight treats bucket marker part bytes as residual data", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    drive = target_drive(ctx)
    marker_dir = Path.join([drive, "marker-orphan-bucket", ".keep"])
    File.mkdir_p!(marker_dir)
    File.write!(Path.join(marker_dir, "part.0"), "not-a-marker")

    assert {:ok, report} =
             TopologyMutation.removal_preflight(job.id,
               topology: ctx.topology,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :physical_residuals_present in report.blockers

    assert Enum.any?(report.examples, fn example ->
             example.type == :physical_residual and example.rel == ".keep"
           end)
  end

  test "removal_preflight blocks version-only orphan roots", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    drive = target_drive(ctx)
    write_layout_residual!(drive, [".versions", "version-orphan-bucket", "stale-object", "v1"])

    assert {:ok, report} =
             TopologyMutation.removal_preflight(job.id,
               topology: ctx.topology,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :physical_residuals_present in report.blockers
    assert report.physical_version_roots > 0

    assert Enum.any?(report.examples, fn example ->
             example.type == :physical_residual and example.bucket == "version-orphan-bucket"
           end)
  end

  test "removal_preflight blocks active multipart uploads on the target set", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    bucket = bucket_name("topology-block-mpu")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, upload} =
      Multipart.initiate(
        bucket,
        "active.bin",
        %{},
        Keyword.put(dist_opts(ctx), :placement_set_id, 0)
      )

    assert upload.placement_set_id == 0

    assert {:ok, report} =
             TopologyMutation.removal_preflight(job.id,
               topology: ctx.topology,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :active_multipart_uploads in report.blockers
    assert report.active_multipart_uploads == 1
  end

  test "removal_preflight blocks physical multipart upload residuals", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    drive = target_drive(ctx)
    write_layout_residual!(drive, [".uploads", "orphan-bucket", "orphan-upload", "1"])

    assert {:ok, report} =
             TopologyMutation.removal_preflight(job.id,
               topology: ctx.topology,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :physical_residuals_present in report.blockers
    assert report.physical_residuals > 0

    assert Enum.any?(report.examples, fn example ->
             example.type == :physical_residual and example.layout == :uploads
           end)
  end

  test "removal_preflight blocks when a target-set endpoint is unreachable", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    [{node, drive} | _] = Topology.endpoints_from(ctx.topology, 0)
    InProcess.set_drive_down(node, drive)

    assert {:ok, report} =
             TopologyMutation.removal_preflight(job.id,
               topology: ctx.topology,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :target_set_unreachable in report.blockers
    assert report.endpoint_errors == 1
    assert Enum.any?(report.examples, &(&1.type == :endpoint_error))
  end

  test "removal_preflight rejects non-decommission jobs", ctx do
    bucket = bucket_name("topology-reject-kind")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    assert {:error, {:unsupported_job_kind, "rebalance"}} =
             TopologyMutation.removal_preflight(job.id,
               topology: ctx.topology,
               transport: InProcess
             )
  end

  defp complete_empty_decommission(ctx) do
    bucket = bucket_name("topology-empty")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, dist_opts(ctx))
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, complete} = Jobs.complete_data_movement(job.id)
    {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)
    Jobs.complete_source_cleanup(cleaning.id)
  end

  defp applied_empty_removal(ctx) do
    :persistent_term.put(@topology_key, ctx.topology)
    {:ok, job} = complete_empty_decommission(ctx)

    {:ok, apply_report} =
      TopologyMutation.apply_removal_cluster(job.id,
        topology: ctx.topology,
        transport: InProcess,
        expected_current_topology_hash: Placement.topology_hash(ctx.topology),
        lock_opts: [nodes: [Node.self()]]
      )

    {job, apply_report}
  end

  defp finalize_applied_removal!(apply_report) do
    Application.delete_env(:maxio, Topology)
    Application.put_env(:maxio, :topology_source, :db)

    assert {:ok, _finalized} =
             TopologyMutation.finalize_removal_deployment(apply_report.job_id,
               expected_proposed_topology_hash: apply_report.proposed_topology_hash
             )
  end

  defp replace_topology_removal_manifest!(job_id, manifest) do
    {:ok, job} = Jobs.get(job_id)

    job
    |> Job.changeset(%{topology_removal_target_endpoints: manifest})
    |> Repo.update!()
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

  defp dist_opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  defp one_set_topology do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_topology_mutation_one_set_#{System.unique_integer([:positive])}"
      )

    endpoints0 = for i <- 0..1, do: {Node.self(), Path.join(base, "s0d#{i}")}

    topology =
      Topology.parse_and_validate!(
        data_shards: 1,
        parity_shards: 1,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints0}]}]
      )

    {topology, base}
  end

  defp removed_set_only_topology do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_topology_removed_only_#{System.unique_integer([:positive])}"
      )

    removed_node = :maxio_removed_set_only_node
    endpoints0 = for i <- 0..1, do: {removed_node, Path.join(base, "s0d#{i}")}
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

    {topology, removed_node, base}
  end

  defp target_drive(ctx) do
    [{_node, drive} | _] = Topology.endpoints_from(ctx.topology, 0)
    drive
  end

  defp write_layout_residual!(drive, rel) do
    dir = Path.join([drive | rel])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "meta.json"), "{}")
    File.write!(Path.join(dir, "part.0"), "residual")
  end

  defp key_for_set(bucket, topology, set_id) do
    Enum.find_value(0..10_000, fn i ->
      key = "mutation-#{set_id}-#{i}.txt"
      if Router.set_for(bucket, key, topology) == set_id, do: key
    end) || flunk("could not find key for set #{inspect(set_id)}")
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

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
