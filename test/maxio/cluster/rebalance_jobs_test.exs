defmodule Maxio.Cluster.RebalanceJobsTest do
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.{Lock, Placement, Rebalance.Jobs, Router, Topology}

  @owner "arn:aws:iam:::root"

  test "start_rebalance persists a planned job with a serializable plan snapshot" do
    topology = topology()
    bucket = bucket_name("rebalance-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 11,
        etag: "e11",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    assert {:ok, job} =
             Jobs.start_rebalance(
               topology: topology,
               include_drive_stats: false,
               requested_by: "test"
             )

    assert job.kind == "rebalance"
    assert job.status == "planned"
    assert job.data_movement_status == "not_started"
    assert job.target_set_id == nil
    assert job.plan_status == "ok"
    assert job.plan_scanned == 1
    assert job.plan_bytes == 11
    assert job.plan_placement_fallbacks == 0
    assert job.progress_scanned == 0
    assert job.plan["per_set"] |> is_list()
  end

  test "start_rebalance_if_needed creates a job only for routing mismatches" do
    topology = topology()
    topology_hash = Placement.topology_hash(topology)
    bucket = bucket_name("rebalance-needed-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 1)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 11,
        etag: "e11",
        placement_set_id: 0,
        placement_topology_hash: topology_hash
      })

    assert {:ok, {:created, job}} =
             Jobs.start_rebalance_if_needed(
               topology: topology,
               include_drive_stats: false,
               requested_by: "test"
             )

    assert job.kind == "rebalance"
    assert job.status == "planned"
    assert job.plan["routing_mismatches"] == 1
    assert job.requested_by == "test"
  end

  test "start_rebalance_if_needed skips durable job creation when placement is aligned" do
    topology = topology()
    topology_hash = Placement.topology_hash(topology)
    bucket = bucket_name("rebalance-not-needed-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 7,
        etag: "e7",
        placement_set_id: 0,
        placement_topology_hash: topology_hash
      })

    assert {:ok, :not_needed} =
             Jobs.start_rebalance_if_needed(topology: topology, include_drive_stats: false)

    assert [] = Jobs.list()
  end

  test "start_rebalance_if_needed preserves placement fallback refusal" do
    topology = topology()
    bucket = bucket_name("rebalance-needed-fallback-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)
    {:ok, _object} = Objects.put_version_with_id(bucket, key, "null", %{size: 5, etag: "e5"})

    assert {:error, {:placement_fallbacks, 1}} =
             Jobs.start_rebalance_if_needed(topology: topology, include_drive_stats: false)

    assert [] = Jobs.list()
  end

  test "start_decommission records target set and refuses a concurrent active job" do
    topology = topology()
    bucket = bucket_name("decommission-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 1)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 7,
        etag: "e7",
        placement_set_id: 1,
        placement_topology_hash: "topo-a"
      })

    other_key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, other_key, "null", %{
        size: 13,
        etag: "e13",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    assert {:ok, job} =
             Jobs.start_decommission(1, topology: topology, include_drive_stats: false)

    assert job.kind == "decommission"
    assert job.target_set_id == 1
    assert job.plan_scanned == 1
    assert job.plan_bytes == 7

    assert {:error, {:active_job_exists, active}} =
             Jobs.start_rebalance(topology: topology, include_drive_stats: false)

    assert active.id == job.id
  end

  test "start aborts and inserts no job when topology lock is lost during planning" do
    topology = topology()
    parent = self()

    drive_stats_fun = fn _opts ->
      send(parent, :planning_under_topology_lock)

      receive do
        :continue -> %{status: :ok, samples: []}
      end
    end

    task =
      Task.async(fn ->
        Jobs.start_decommission(0,
          topology: topology,
          include_drive_stats: true,
          drive_stats_fun: drive_stats_fun,
          topology_lock_opts: [nodes: [Node.self()], ttl_ms: 1_000, heartbeat_ms: 10]
        )
      end)

    assert_receive :planning_under_topology_lock

    assert :ok =
             Lock.force_unlock(Topology.runtime_mutation_lock_resource(), nodes: [Node.self()])

    assert {:error, :topology_mutation_locked} = Task.await(task, 3_000)
    assert [] = Jobs.list()
  end

  test "cancel transitions active job to canceled and frees singleton guard" do
    topology = topology()
    bucket = bucket_name("cancel-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 3,
        etag: "e3",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    assert {:ok, job} = Jobs.start_rebalance(topology: topology, include_drive_stats: false)
    assert {:ok, canceled} = Jobs.cancel(job.id)
    assert canceled.status == "canceled"
    assert canceled.data_movement_status == "canceled"
    assert %DateTime{} = canceled.finished_at

    assert {:ok, next_job} = Jobs.start_rebalance(topology: topology, include_drive_stats: false)
    refute next_job.id == job.id
  end

  test "movement state transitions do not overwrite canceled or terminal jobs" do
    topology = topology()
    bucket = bucket_name("movement-guard-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 3,
        etag: "e3",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    assert {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
    assert Jobs.to_view(job).data_movement == false

    assert {:ok, running} = Jobs.begin_data_movement(job.id, 1)
    assert running.status == "running"
    assert Jobs.to_view(running).data_movement == true

    assert {:ok, canceled} = Jobs.cancel(running.id)
    assert canceled.status == "canceled"

    assert {:error, {:stale_job_status, "canceled"}} =
             Jobs.record_progress(canceled.id, %{scanned: 1, moved: 1, skipped: 0, errors: 0})

    assert {:error, {:stale_job_status, "canceled"}} =
             Jobs.complete_data_movement(canceled.id)

    assert {:error, {:stale_job_status, "canceled"}} =
             Jobs.fail_data_movement(canceled.id, :late_error)

    assert {:ok, unchanged} = Jobs.get(canceled.id)
    assert unchanged.status == "canceled"
    assert unchanged.progress_scanned == 0
    refute is_nil(unchanged.finished_at)

    assert {:ok, terminal_job} =
             Jobs.start_decommission(0, topology: topology, include_drive_stats: false)

    assert {:ok, terminal_running} = Jobs.begin_data_movement(terminal_job.id, 1)
    assert {:ok, complete} = Jobs.complete_data_movement(terminal_running.id)
    assert complete.status == "complete"

    assert {:error, {:stale_job_status, "complete"}} =
             Jobs.begin_data_movement(complete.id, 1)

    assert {:ok, still_complete} = Jobs.get(complete.id)
    assert still_complete.status == "complete"
  end

  test "begin_data_movement cannot rebind destination from a stale job snapshot" do
    topology = topology()
    bucket = bucket_name("movement-destination-guard-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 3,
        etag: "e3",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    assert {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
    stale_snapshot = job

    assert {:ok, running} = Jobs.begin_data_movement(job, 1)
    assert running.destination_set_id == 1

    assert {:error, {:destination_mismatch, 1, 2}} =
             Jobs.begin_data_movement(stale_snapshot, 2)

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.status == "running"
    assert unchanged.destination_set_id == 1
  end

  test "record_progress is monotonic and does not move cursor backward" do
    topology = topology()
    bucket = bucket_name("movement-progress-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 3,
        etag: "e3",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    assert {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
    assert {:ok, running} = Jobs.begin_data_movement(job.id, 1)

    assert {:ok, progressed} =
             Jobs.record_progress(
               running.id,
               %{scanned: 5, moved: 4, skipped: 1, errors: 0},
               %{
                 cursor_bucket: bucket,
                 cursor_key_marker: "k-5",
                 cursor_version_id_marker: "v5"
               }
             )

    assert progressed.progress_scanned == 5
    assert progressed.progress_moved == 4
    assert progressed.cursor_key_marker == "k-5"

    assert {:ok, stale} =
             Jobs.record_progress(
               running.id,
               %{scanned: 3, moved: 2, skipped: 0, errors: 0},
               %{
                 cursor_bucket: bucket,
                 cursor_key_marker: "k-3",
                 cursor_version_id_marker: "v3"
               }
             )

    assert stale.progress_scanned == 5
    assert stale.progress_moved == 4
    assert stale.progress_skipped == 1
    assert stale.cursor_key_marker == "k-5"
    assert stale.cursor_version_id_marker == "v5"

    assert {:ok, equal_counter_stale_cursor} =
             Jobs.record_progress(
               running.id,
               %{scanned: 5, moved: 4, skipped: 1, errors: 0},
               %{
                 cursor_bucket: bucket,
                 cursor_key_marker: "k-equal",
                 cursor_version_id_marker: "v-equal"
               }
             )

    assert equal_counter_stale_cursor.progress_scanned == 5
    assert equal_counter_stale_cursor.cursor_key_marker == "k-5"
    assert equal_counter_stale_cursor.cursor_version_id_marker == "v5"

    assert {:ok, advanced} =
             Jobs.record_progress(
               running.id,
               %{scanned: 6, moved: 4, skipped: 2, errors: 1},
               %{
                 cursor_bucket: bucket,
                 cursor_key_marker: "k-6",
                 cursor_version_id_marker: "v6"
               }
             )

    assert advanced.progress_scanned == 6
    assert advanced.progress_moved == 4
    assert advanced.progress_skipped == 2
    assert advanced.progress_errors == 1
    assert advanced.cursor_key_marker == "k-6"
  end

  test "source cleanup progress is monotonic and active job guard blocks reentry" do
    topology = topology()
    bucket = bucket_name("cleanup-progress-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    assert {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
    assert {:ok, running} = Jobs.begin_data_movement(job.id, 1)
    assert {:ok, complete} = Jobs.complete_data_movement(running.id)
    assert complete.status == "complete"
    assert complete.data_movement_status == "complete"

    assert {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)
    assert cleaning.status == "running"
    assert cleaning.source_cleanup_status == "moving"

    assert {:ok, progressed} =
             Jobs.record_source_cleanup_progress(
               cleaning.id,
               %{scanned: 5, deleted: 4, skipped: 1, errors: 0},
               %{
                 source_cleanup_cursor_bucket: bucket,
                 source_cleanup_cursor_key_marker: "k-5",
                 source_cleanup_cursor_version_id_marker: "v5"
               }
             )

    assert progressed.source_cleanup_scanned == 5
    assert progressed.source_cleanup_deleted == 4
    assert progressed.source_cleanup_cursor_key_marker == "k-5"

    assert {:ok, stale} =
             Jobs.record_source_cleanup_progress(
               cleaning.id,
               %{scanned: 3, deleted: 2, skipped: 0, errors: 0},
               %{
                 source_cleanup_cursor_bucket: bucket,
                 source_cleanup_cursor_key_marker: "k-3",
                 source_cleanup_cursor_version_id_marker: "v3"
               }
             )

    assert stale.source_cleanup_scanned == 5
    assert stale.source_cleanup_deleted == 4
    assert stale.source_cleanup_skipped == 1
    assert stale.source_cleanup_cursor_key_marker == "k-5"
    assert stale.source_cleanup_cursor_version_id_marker == "v5"

    assert {:ok, cleaned} = Jobs.complete_source_cleanup(cleaning.id)
    assert cleaned.status == "complete"
    assert cleaned.source_cleanup_status == "complete"

    assert {:ok, pending} =
             Jobs.start_decommission(0, topology: topology, include_drive_stats: false)

    assert {:ok, pending_running} = Jobs.begin_data_movement(pending.id, 1)
    assert {:ok, pending_complete} = Jobs.complete_data_movement(pending_running.id)
    assert {:ok, active} = Jobs.start_rebalance(topology: topology, include_drive_stats: false)

    assert {:error, {:active_job_exists, blocker}} =
             Jobs.begin_source_cleanup(pending_complete.id)

    assert blocker.id == active.id
  end

  test "next_runnable prefers active copy jobs before unblocked cleanup" do
    topology = topology()
    bucket = bucket_name("selector-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    assert {:ok, decommission} =
             Jobs.start_decommission(0, topology: topology, include_drive_stats: false)

    assert {:ok, running} = Jobs.begin_data_movement(decommission.id, 1)
    assert {:ok, complete} = Jobs.complete_data_movement(running.id)
    assert complete.source_cleanup_status == "not_started"

    assert {:ok, rebalance} = Jobs.start_rebalance(topology: topology, include_drive_stats: false)

    assert {:ok, next} = Jobs.next_runnable()
    assert next.id == rebalance.id
    assert next.kind == "rebalance"

    assert {:error, :not_found} = Jobs.next_runnable_decommission()

    assert {:ok, _canceled} = Jobs.cancel(rebalance.id)
    assert {:ok, cleanup_next} = Jobs.next_runnable()
    assert cleanup_next.id == complete.id
    assert cleanup_next.kind == "decommission"
    assert cleanup_next.data_movement_status == "complete"
    assert cleanup_next.source_cleanup_status == "not_started"

    assert {:ok, decommission_next} = Jobs.next_runnable_decommission()
    assert decommission_next.id == complete.id
  end

  test "next_runnable_deployment_topology selects only converged unverified decommission jobs" do
    topology = topology()
    bucket = bucket_name("deployment-topology-selector")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    assert {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
    assert {:ok, running} = Jobs.begin_data_movement(job.id, 1)
    assert {:ok, complete} = Jobs.complete_data_movement(running.id)
    assert {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)
    assert {:ok, cleaned} = Jobs.complete_source_cleanup(cleaning.id)

    assert {:error, :not_found} = Jobs.next_runnable_deployment_topology()
    assert {:error, :not_found} = Jobs.next_runnable_deployment_topology(job_id: cleaned.id)

    {:ok, proposed_topology} = Topology.remove_set_from(topology, 0)
    current_hash = Placement.topology_hash(topology)
    proposed_hash = Placement.topology_hash(proposed_topology)

    assert {:ok, applied} =
             Jobs.mark_topology_removal_applied(cleaned.id, %{
               current_topology_hash: current_hash,
               proposed_topology_hash: proposed_hash
             })

    assert {:error, :not_found} = Jobs.next_runnable_deployment_topology()
    assert {:error, :not_found} = Jobs.next_runnable_deployment_topology(job_id: applied.id)

    assert {:ok, converged} =
             Jobs.mark_topology_removal_cluster_converged(applied, %{
               cluster_topology_hash: proposed_hash,
               cluster_nodes: [Node.self()]
             })

    assert {:ok, active} = Jobs.start_rebalance(topology: topology, include_drive_stats: false)
    assert {:error, :not_found} = Jobs.next_runnable_deployment_topology()
    assert {:error, :not_found} = Jobs.next_runnable_deployment_topology(job_id: converged.id)
    assert {:error, :not_found} = Jobs.next_runnable_deployment_topology(job_id: active.id)
    assert {:ok, _canceled} = Jobs.cancel(active.id)

    assert {:ok, selected} = Jobs.next_runnable_deployment_topology()
    assert selected.id == converged.id
    assert selected.topology_removal_proposed_hash == proposed_hash

    assert {:ok, explicit_selected} = Jobs.next_runnable_deployment_topology(job_id: converged.id)
    assert explicit_selected.id == converged.id

    assert {:ok, _verified} =
             Jobs.mark_topology_removal_deployment_verified(converged, %{
               deployment_topology_hash: proposed_hash
             })

    assert {:error, :not_found} = Jobs.next_runnable_deployment_topology()
    assert {:error, :not_found} = Jobs.next_runnable_deployment_topology(job_id: converged.id)
  end

  test "next_runnable_runtime_topology selects cleaned decommission jobs before convergence" do
    topology = topology()
    bucket = bucket_name("runtime-topology-selector")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    assert {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
    assert {:ok, running} = Jobs.begin_data_movement(job.id, 1)
    assert {:ok, complete} = Jobs.complete_data_movement(running.id)

    assert {:error, :not_found} = Jobs.next_runnable_runtime_topology()
    assert {:error, :not_found} = Jobs.next_runnable_runtime_topology(job_id: complete.id)

    assert {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)
    assert {:ok, cleaned} = Jobs.complete_source_cleanup(cleaning.id)

    assert {:ok, selected} = Jobs.next_runnable_runtime_topology()
    assert selected.id == cleaned.id

    assert {:ok, explicit_selected} = Jobs.next_runnable_runtime_topology(job_id: cleaned.id)
    assert explicit_selected.id == cleaned.id

    assert {:ok, active} = Jobs.start_rebalance(topology: topology, include_drive_stats: false)
    assert {:error, :not_found} = Jobs.next_runnable_runtime_topology()
    assert {:error, :not_found} = Jobs.next_runnable_runtime_topology(job_id: cleaned.id)
    assert {:error, :not_found} = Jobs.next_runnable_runtime_topology(job_id: active.id)
    assert {:ok, _canceled} = Jobs.cancel(active.id)

    {:ok, proposed_topology} = Topology.remove_set_from(topology, 0)
    current_hash = Placement.topology_hash(topology)
    proposed_hash = Placement.topology_hash(proposed_topology)

    assert {:ok, applied} =
             Jobs.mark_topology_removal_applied(cleaned.id, %{
               current_topology_hash: current_hash,
               proposed_topology_hash: proposed_hash
             })

    assert {:ok, converged} =
             Jobs.mark_topology_removal_cluster_converged(applied, %{
               cluster_topology_hash: proposed_hash,
               cluster_nodes: [Node.self()]
             })

    assert {:error, :not_found} = Jobs.next_runnable_runtime_topology()
    assert {:error, :not_found} = Jobs.next_runnable_runtime_topology(job_id: converged.id)
  end

  test "mark_topology_removal_applied records physical removal manifest idempotently" do
    topology = topology()
    bucket = bucket_name("manifest-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    assert {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
    assert {:ok, running} = Jobs.begin_data_movement(job.id, 1)
    assert {:ok, complete} = Jobs.complete_data_movement(running.id)
    assert {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)
    assert {:ok, cleaned} = Jobs.complete_source_cleanup(cleaning.id)

    {:ok, proposed_topology} = Topology.remove_set_from(topology, 0)
    current_hash = Placement.topology_hash(topology)
    proposed_hash = Placement.topology_hash(proposed_topology)

    manifest = target_endpoint_manifest(topology, 0)

    wrong_set_manifest = %{manifest | "target_set_id" => 1}

    assert {:error, :invalid_topology_removal_manifest} =
             Jobs.mark_topology_removal_applied(cleaned.id, %{
               current_topology_hash: current_hash,
               proposed_topology_hash: proposed_hash,
               target_endpoints: wrong_set_manifest,
               removed_pool_ids: []
             })

    malformed_manifest = %{
      manifest
      | "endpoints" => [
          hd(manifest["endpoints"]),
          %{"node" => Atom.to_string(Node.self()), "set_id" => 0, "pool_id" => 0}
        ]
    }

    assert {:error, :invalid_topology_removal_manifest} =
             Jobs.mark_topology_removal_applied(cleaned.id, %{
               current_topology_hash: current_hash,
               proposed_topology_hash: proposed_hash,
               target_endpoints: malformed_manifest,
               removed_pool_ids: []
             })

    all_malformed_manifest = %{
      manifest
      | "endpoints" => [
          %{"node" => 123, "drive" => "/tmp/wrong-a", "set_id" => 0, "pool_id" => 0},
          %{"node" => Atom.to_string(Node.self()), "set_id" => 0, "pool_id" => 0}
        ]
    }

    assert {:error, :invalid_topology_removal_manifest} =
             Jobs.mark_topology_removal_applied(cleaned.id, %{
               current_topology_hash: current_hash,
               proposed_topology_hash: proposed_hash,
               target_endpoints: all_malformed_manifest,
               removed_pool_ids: []
             })

    wrong_drive_manifest =
      put_in(manifest, ["endpoints", Access.at(0), "drive"], "/tmp/wrong-drive")

    assert {:error, :invalid_topology_removal_manifest} =
             Jobs.mark_topology_removal_applied(
               cleaned.id,
               %{
                 current_topology_hash: current_hash,
                 proposed_topology_hash: proposed_hash,
                 target_endpoints: wrong_drive_manifest,
                 removed_pool_ids: []
               },
               topology: topology
             )

    assert {:ok, applied} =
             Jobs.mark_topology_removal_applied(
               cleaned.id,
               %{
                 current_topology_hash: current_hash,
                 proposed_topology_hash: proposed_hash,
                 target_endpoints: manifest,
                 removed_pool_ids: [3, 2, 3]
               },
               topology: topology
             )

    assert applied.topology_removal_target_endpoints == manifest
    assert applied.topology_removal_removed_pool_ids == [2, 3]
    assert Jobs.to_view(applied).topology_removal_target_endpoints == manifest

    assert {:ok, same} =
             Jobs.mark_topology_removal_applied(
               applied.id,
               %{
                 current_topology_hash: current_hash,
                 proposed_topology_hash: proposed_hash,
                 target_endpoints: manifest,
                 removed_pool_ids: [2, 3]
               },
               topology: topology
             )

    assert same.topology_removal_target_endpoints == manifest

    different_manifest = put_in(manifest, ["endpoints", Access.at(0), "drive"], "/tmp/other")

    assert {:error, :invalid_topology_removal_manifest} =
             Jobs.mark_topology_removal_applied(
               applied.id,
               %{
                 current_topology_hash: current_hash,
                 proposed_topology_hash: proposed_hash,
                 target_endpoints: different_manifest,
                 removed_pool_ids: [2, 3]
               },
               topology: topology
             )
  end

  test "cancel during source cleanup preserves completed data movement state" do
    topology = topology()
    bucket = bucket_name("cleanup-cancel-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    assert {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
    assert {:ok, running} = Jobs.begin_data_movement(job.id, 1)
    assert {:ok, complete} = Jobs.complete_data_movement(running.id)
    assert {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)

    assert {:ok, canceled} = Jobs.cancel(cleaning.id)
    assert canceled.status == "canceled"
    assert canceled.data_movement_status == "complete"
    assert canceled.source_cleanup_status == "skipped"
    assert %DateTime{} = canceled.finished_at

    assert {:error, :canceled} = Jobs.begin_source_cleanup(canceled.id)
  end

  test "cancel during rebalance source cleanup preserves completed data movement state" do
    topology = topology()
    bucket = bucket_name("rebalance-cleanup-cancel-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    assert {:ok, job} = Jobs.start_rebalance(topology: topology, include_drive_stats: false)
    assert {:ok, running} = Jobs.begin_rebalance_data_movement(job.id)
    assert {:ok, complete} = Jobs.complete_data_movement(running.id)
    assert {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)

    assert {:ok, canceled} = Jobs.cancel(cleaning.id)
    assert canceled.status == "canceled"
    assert canceled.data_movement_status == "complete"
    assert canceled.source_cleanup_status == "skipped"
    assert %DateTime{} = canceled.finished_at

    assert {:error, :canceled} = Jobs.begin_source_cleanup(canceled.id)
  end

  test "start fails loudly when plan has placement fallbacks" do
    topology = topology()
    bucket = bucket_name("fallback-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)
    {:ok, _object} = Objects.put_version_with_id(bucket, key, "null", %{size: 5, etag: "e5"})

    assert {:error, {:placement_fallbacks, 1}} =
             Jobs.start_rebalance(topology: topology, include_drive_stats: false)

    assert [] = Jobs.list()
  end

  test "decommission refuses current-only scope" do
    assert {:error, :decommission_requires_versions} =
             Jobs.start_decommission(1,
               topology: topology(),
               include_drive_stats: false,
               current_only: true
             )

    assert [] = Jobs.list()
  end

  test "decommission fails loudly when target set has placement fallbacks" do
    topology = topology()
    bucket = bucket_name("decommission-fallback-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 1)
    {:ok, _object} = Objects.put_version_with_id(bucket, key, "null", %{size: 5, etag: "e5"})

    assert {:error, {:placement_fallbacks, 1}} =
             Jobs.start_decommission(1, topology: topology, include_drive_stats: false)

    assert [] = Jobs.list()
  end

  test "decommission validates target set through planner" do
    topology = topology()

    assert {:error, {:unknown_set_id, 99, [0, 1]}} =
             Jobs.start_decommission(99, topology: topology, include_drive_stats: false)
  end

  test "start requires a configured or injected topology" do
    assert {:error, :no_topology} = Jobs.start_rebalance(include_drive_stats: false)
  end

  defp topology do
    base = Path.join(System.tmp_dir!(), "maxio_rebalance_jobs_test")

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

  defp key_for_set(bucket, topology, set_id) do
    Enum.find_value(0..10_000, fn i ->
      key = "job-#{set_id}-#{i}.txt"
      if Router.set_for(bucket, key, topology) == set_id, do: key
    end) || flunk("could not find key for set #{inspect(set_id)}")
  end

  defp target_endpoint_manifest(topology, set_id) do
    pool_id = Topology.pool_id_for_set_from(topology, set_id)

    %{
      "target_set_id" => set_id,
      "target_pool_id" => pool_id,
      "endpoints" =>
        topology
        |> Topology.endpoints_from(set_id)
        |> Enum.map(fn {node, drive} ->
          %{
            "node" => Atom.to_string(node),
            "drive" => drive,
            "set_id" => set_id,
            "pool_id" => pool_id
          }
        end)
    }
  end

  defp bucket_name(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.replace("-", "")

    "#{prefix}-#{suffix}"
  end
end
