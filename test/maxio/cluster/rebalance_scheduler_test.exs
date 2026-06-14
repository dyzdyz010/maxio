defmodule Maxio.Cluster.RebalanceSchedulerTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maxio.{Buckets, Objects}

  alias Maxio.Cluster.{
    Lock,
    Placement,
    Rebalance.Jobs,
    Rebalance.Scheduler,
    Rebalance.TopologyMutation,
    Router,
    SchedulerRuns,
    Topology,
    TopologyStore
  }

  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.Distributed

  @owner "arn:aws:iam:::root"
  @scheduler_lock {:rebalance_scheduler, :run}
  @topology_key {Topology, :topology}

  setup do
    InProcess.setup!()
    previous_backend = Application.get_env(:maxio, :storage_backend)
    previous_topology_source = Application.get_env(:maxio, :topology_source, :__maxio_no_source__)
    previous_runtime_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)
    Application.put_env(:maxio, :storage_backend, Distributed)

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_scheduler_#{System.unique_integer([:positive])}"
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
      restore_topology_source(previous_topology_source)
      restore_topology(previous_runtime_topology)
      File.rm_rf(base)
    end)

    {:ok, topology: topology}
  end

  test "disabled scheduler starts without a timer" do
    pid = start_scheduler!(enabled: false)

    assert %{
             enabled: false,
             scheduled?: false,
             last_result: nil,
             last_skip_reason: nil
           } = Scheduler.status(pid)
  end

  test "run_now reports no runnable decommission job" do
    pid = start_scheduler!(enabled: false)

    assert {:error, :no_runnable_job} = Scheduler.run_now(pid, [])
    assert %{last_skip_reason: :no_runnable_job} = Scheduler.status(pid)

    assert %{status: "idle", consecutive_failures: 0, last_error_reason: "\"no_runnable_job\""} =
             SchedulerRuns.state(:rebalance)
  end

  test "run_steps requires a pinned ordinary rebalance job", ctx do
    {:ok, decommission} =
      Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:error, {:missing_pinned_rebalance_job_id, nil}} = Scheduler.run_steps([])

    assert {:error, {:unsupported_rebalance_drain_job, details}} =
             Scheduler.run_steps(job_id: decommission.id)

    assert details.job_id == decommission.id
    assert details.kind == "decommission"
    assert details.target_set_id == 0
  end

  test "missing destination fails closed and is logged", ctx do
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    pid = start_scheduler!(enabled: false, topology: ctx.topology, auto_destination: false)

    log =
      capture_log(fn ->
        assert {:error, :missing_destination_set_id} = Scheduler.run_now(pid, [])
      end)

    assert log =~ "rebalance scheduler pass skipped"
    assert log =~ "missing_destination_set_id"

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.status == "planned"
    assert unchanged.data_movement_status == "not_started"
    assert is_nil(unchanged.destination_set_id)
    assert unchanged.progress_scanned == 0
  end

  test "run_now selects a planned decommission job and injects mapped destination", ctx do
    parent = self()
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    job_id = job.id

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        destination_sets: %{0 => 1},
        copy_runner: fn job_id, opts ->
          send(parent, {:copy_runner, job_id, opts})
          {:ok, %{status: :partial, job_id: job_id}}
        end
      )

    assert {:ok, %{phase: :copy, scheduler: true, status: :partial}} = Scheduler.run_now(pid, [])
    assert_receive {:copy_runner, ^job_id, opts}
    assert Keyword.fetch!(opts, :destination_set_id) == 1
    assert Keyword.fetch!(opts, :topology) == ctx.topology
  end

  test "run_now asks runner for auto destination when no explicit mapping exists", ctx do
    parent = self()
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    job_id = job.id

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        copy_runner: fn job_id, opts ->
          send(parent, {:copy_runner, job_id, opts})
          {:ok, %{status: :partial, job_id: job_id}}
        end
      )

    assert {:ok, %{phase: :copy, scheduler: true, status: :partial}} = Scheduler.run_now(pid, [])
    assert_receive {:copy_runner, ^job_id, opts}
    assert Keyword.fetch!(opts, :auto_destination)
    assert Keyword.fetch!(opts, :topology) == ctx.topology
  end

  test "run_now selects a planned rebalance job without destination opts", ctx do
    parent = self()
    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)
    job_id = job.id

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        destination_set_id: 1,
        destination_sets: %{0 => 1},
        auto_destination: true,
        copy_runner: fn job_id, opts ->
          send(parent, {:copy_runner, job_id, opts})
          {:ok, %{status: :partial, job_id: job_id, job_kind: "rebalance"}}
        end
      )

    assert {:ok, %{phase: :copy, scheduler: true, status: :partial}} = Scheduler.run_now(pid, [])
    assert_receive {:copy_runner, ^job_id, opts}
    refute Keyword.has_key?(opts, :destination_set_id)
    refute Keyword.has_key?(opts, :destination_sets)
    refute Keyword.has_key?(opts, :auto_destination)
    assert Keyword.fetch!(opts, :topology) == ctx.topology
  end

  test "later failure clears last successful result", ctx do
    {:ok, _job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        destination_set_id: 1,
        copy_runner: fn job_id, _opts -> {:ok, %{status: :partial, job_id: job_id}} end
      )

    assert {:ok, %{phase: :copy}} = Scheduler.run_now(pid, [])
    assert %{last_result: %{phase: :copy}, last_skip_reason: nil} = Scheduler.status(pid)

    assert {:error, :boom} = Scheduler.run_now(pid, job_selector: fn _opts -> {:error, :boom} end)
    assert %{last_result: nil, last_skip_reason: :boom} = Scheduler.status(pid)
  end

  test "enabled scheduler runs once and reschedules", ctx do
    parent = self()
    {:ok, _job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    pid =
      start_scheduler!(
        enabled: true,
        initial_delay_ms: 0,
        interval_ms: 60_000,
        topology: ctx.topology,
        destination_set_id: 1,
        copy_runner: fn job_id, opts ->
          send(parent, {:scheduled_copy_runner, job_id, opts})
          {:ok, %{status: :partial, job_id: job_id}}
        end
      )

    assert_receive {:scheduled_copy_runner, _job_id, opts}, 1_000
    assert Keyword.fetch!(opts, :destination_set_id) == 1
    _ = :sys.get_state(pid)

    assert %{scheduled?: true, last_result: %{phase: :copy, status: :partial}} =
             Scheduler.status(pid)
  end

  test "held singleton lock skips scheduler run before invoking runner", ctx do
    parent = self()
    {:ok, _job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        destination_set_id: 1,
        copy_runner: fn _job_id, _opts ->
          send(parent, :runner_called)
          {:ok, %{status: :ok}}
        end
      )

    {:ok, lease} = Lock.acquire(@scheduler_lock, nodes: [Node.self()], refresh: false)

    try do
      assert {:error, :lock_unavailable} = Scheduler.run_now(pid, [])
      refute_receive :runner_called, 20
      assert %{last_skip_reason: :lock_unavailable} = Scheduler.status(pid)
    after
      Lock.release(lease)
    end
  end

  test "scheduler advances active rebalance instead of starting blocked cleanup", ctx do
    parent = self()

    {:ok, decommission} =
      Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    {:ok, _running} = Jobs.begin_data_movement(decommission.id, 1)
    {:ok, _complete} = Jobs.complete_data_movement(decommission.id)
    {:ok, rebalance} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)
    rebalance_id = rebalance.id

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        transport: InProcess,
        auto_destination: false,
        destination_sets: %{0 => 1},
        copy_runner: fn job_id, opts ->
          send(parent, {:copy_runner, job_id, opts})
          {:ok, %{status: :partial, job_id: job_id, job_kind: "rebalance"}}
        end,
        cleanup_runner: fn _job_id, _opts ->
          send(parent, :cleanup_runner_called)
          {:error, :unexpected_cleanup}
        end
      )

    assert {:ok, %{phase: :copy, job_id: ^rebalance_id}} = Scheduler.run_now(pid, [])
    assert_receive {:copy_runner, ^rebalance_id, opts}
    refute Keyword.has_key?(opts, :destination_set_id)
    refute_receive :cleanup_runner_called, 20

    assert {:ok, unchanged} = Jobs.get(decommission.id)
    assert unchanged.source_cleanup_status == "not_started"
  end

  test "auto_source_cleanup false does not start cleanup", ctx do
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, _complete} = Jobs.complete_data_movement(job.id)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        transport: InProcess,
        auto_source_cleanup: false,
        auto_destination: false,
        destination_sets: %{0 => 1}
      )

    assert {:error, :source_cleanup_disabled} = Scheduler.run_now(pid, [])
    assert %{last_result: nil, last_skip_reason: :source_cleanup_disabled} = Scheduler.status(pid)

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.status == "complete"
    assert unchanged.source_cleanup_status == "not_started"
    assert unchanged.source_cleanup_scanned == 0
  end

  test "scheduler advances real decommission copy and then source cleanup", ctx do
    bucket = bucket_name("rebalance-scheduler")
    key = key_for_set(bucket, ctx.topology, 0)
    body = "scheduler-copy-cleanup"
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    destination_opts = Keyword.put(opts, :placement_set_id, 1)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", body, source_opts)
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        transport: InProcess
      )

    assert {:ok, copy} = Scheduler.run_now(pid, [])
    assert copy.phase == :copy
    assert copy.status == :ok
    assert copy.moved == 1

    assert {:ok, copied_job} = Jobs.get(job.id)
    assert copied_job.status == "complete"
    assert copied_job.data_movement_status == "complete"
    assert copied_job.source_cleanup_status == "not_started"

    assert {:ok, source_stream} = Distributed.get(bucket, key, "v1", nil, source_opts)
    assert IO.iodata_to_binary(Enum.to_list(source_stream)) == body

    assert {:ok, cleanup} = Scheduler.run_now(pid, [])
    assert cleanup.phase == :source_cleanup
    assert cleanup.status == :ok
    assert cleanup.deleted == 1
    assert cleanup.source_cleanup_status == "complete"

    assert {:ok, destination_stream} = Distributed.get(bucket, key, "v1", nil, destination_opts)
    assert IO.iodata_to_binary(Enum.to_list(destination_stream)) == body
    assert {:error, :enoent} = Distributed.get(bucket, key, "v1", nil, source_opts)

    assert {:ok, finished} = Jobs.get(job.id)
    assert finished.status == "complete"
    assert finished.data_movement_status == "complete"
    assert finished.source_cleanup_status == "complete"
  end

  test "scheduler advances real rebalance copy and cleanup but leaves closure idle by default",
       ctx do
    bucket = bucket_name("rebalance-scheduler-dynamic")
    key = key_for_set(bucket, ctx.topology, 1, "rebalance")
    body = "scheduler-rebalance-copy"
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    destination_opts = Keyword.put(opts, :placement_set_id, 1)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", body, source_opts)
    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        transport: InProcess,
        destination_set_id: 1,
        destination_sets: %{0 => 1},
        auto_destination: true
      )

    assert {:ok, copy} = Scheduler.run_now(pid, [])
    assert copy.phase == :copy
    assert copy.status == :ok
    assert copy.job_kind == "rebalance"
    assert is_nil(copy.destination_set_id)
    assert copy.moved == 1
    assert copy.skipped == 0

    assert {:ok, moved} = Objects.get_version(bucket, key, "v1")
    assert moved.placement_set_id == 1

    assert {:ok, destination_stream} = Distributed.get(bucket, key, "v1", nil, destination_opts)
    assert IO.iodata_to_binary(Enum.to_list(destination_stream)) == body

    assert {:ok, source_stream} = Distributed.get(bucket, key, "v1", nil, source_opts)
    assert IO.iodata_to_binary(Enum.to_list(source_stream)) == body

    assert {:ok, finished} = Jobs.get(job.id)
    assert finished.status == "complete"
    assert finished.data_movement_status == "complete"
    assert finished.source_cleanup_status == "not_started"
    assert is_nil(finished.destination_set_id)

    assert {:ok, cleanup} = Scheduler.run_now(pid, [])
    assert cleanup.phase == :source_cleanup
    assert cleanup.status == :ok
    assert cleanup.job_kind == "rebalance"
    assert cleanup.deleted == 1

    assert {:error, :enoent} = Distributed.get(bucket, key, "v1", nil, source_opts)

    assert {:ok, cleaned} = Jobs.get(job.id)
    assert cleaned.source_cleanup_status == "complete"
    assert cleaned.rebalance_closure_status == "not_started"

    assert {:error, :no_runnable_job} = Scheduler.run_now(pid, [])
  end

  test "auto rebalance closure records verified audit evidence", ctx do
    :persistent_term.put(@topology_key, ctx.topology)

    bucket = bucket_name("rebalance-scheduler-closure")
    key = key_for_set(bucket, ctx.topology, 1, "closure")
    body = "scheduler-rebalance-closure"
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", body, source_opts)
    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        transport: InProcess,
        auto_rebalance_closure: true
      )

    assert {:ok, %{phase: :copy, status: :ok, moved: 1}} = Scheduler.run_now(pid, [])
    assert {:ok, %{phase: :source_cleanup, status: :ok, deleted: 1}} = Scheduler.run_now(pid, [])

    assert {:ok, closure} = Scheduler.run_now(pid, [])
    assert closure.scheduler
    assert closure.phase == :rebalance_closure
    assert closure.status == :verified
    assert closure.topology_mutation == false
    assert closure.physical_removal == false
    assert closure.rebalance_complete?
    assert closure.next_action == "none"
    assert closure.versions_scanned == 1
    assert closure.routing_mismatches == 0

    assert {:ok, verified} = Jobs.get(job.id)
    assert verified.rebalance_closure_status == "verified"
    assert verified.rebalance_closure_verified_at
    assert verified.rebalance_closure_topology_hash == Placement.topology_hash(ctx.topology)
    assert verified.rebalance_closure_blockers == []
    assert verified.rebalance_closure_results["workflow_status"] == "complete"
    assert verified.rebalance_closure_results["rebalance_complete?"] == true

    assert {:error, :no_runnable_job} = Scheduler.run_now(pid, [])
  end

  test "blocked closure next action is recorded in scheduler ledger summary", ctx do
    :persistent_term.put(@topology_key, ctx.topology)

    bucket = bucket_name("rebalance-scheduler-closure-blocked")
    key = key_for_set(bucket, ctx.topology, 1, "closure-blocked")
    body = "scheduler-rebalance-closure-blocked"
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", body, source_opts)
    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)
    next_action = "mix maxio.rebalance.verify_closure --job-id #{job.id} --json"

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        transport: InProcess,
        auto_rebalance_closure: true,
        closure_verifier: fn job_id, _opts ->
          {:ok,
           %{
             status: :blocked,
             job_id: job_id,
             phase: :rebalance_closure,
             blockers: [:routing_mismatch],
             next_action: next_action
           }}
        end
      )

    assert {:ok, %{phase: :copy, status: :ok, moved: 1}} = Scheduler.run_now(pid, [])
    assert {:ok, %{phase: :source_cleanup, status: :ok, deleted: 1}} = Scheduler.run_now(pid, [])

    assert {:ok, closure} = Scheduler.run_now(pid, [])
    assert closure.phase == :rebalance_closure
    assert closure.status == :blocked
    assert closure.next_action == next_action

    [run | _] = SchedulerRuns.list_runs(scheduler: :rebalance, limit: 5)
    assert run.status == "blocked"
    assert run.phase == "rebalance_closure"
    assert run.summary["next_action"] == next_action
  end

  test "run_steps honors max step cap for a pinned rebalance job", ctx do
    parent = self()
    {:ok, decommission} = complete_empty_decommission(ctx)

    bucket = bucket_name("rebalance-drain-max-steps")
    key = key_for_set(bucket, ctx.topology, 1, "drain")
    body = "drain-max-steps"
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", body, source_opts)
    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    assert {:ok, report} =
             Scheduler.run_steps(
               job_id: job.id,
               topology: ctx.topology,
               transport: InProcess,
               max_steps: 1,
               job_selector: fn _opts ->
                 send(parent, {:custom_job_selector_called, decommission.id})
                 {:ok, decommission}
               end
             )

    refute_receive {:custom_job_selector_called, _job_id}, 20
    assert report.status == :partial
    assert report.reason == :max_steps
    assert report.steps == 1
    assert report.phases == [:copy]

    assert {:ok, moved} = Objects.get_version(bucket, key, "v1")
    assert moved.placement_set_id == 1

    assert {:ok, copied_job} = Jobs.get(job.id)
    assert copied_job.data_movement_status == "complete"
    assert copied_job.source_cleanup_status == "not_started"
  end

  test "run_steps can drain copy cleanup and optional rebalance closure", ctx do
    :persistent_term.put(@topology_key, ctx.topology)

    bucket = bucket_name("rebalance-drain-closure")
    key = key_for_set(bucket, ctx.topology, 1, "drain")
    body = "drain-to-closure"
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", body, source_opts)
    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    assert {:ok, report} =
             Scheduler.run_steps(
               job_id: job.id,
               topology: ctx.topology,
               transport: InProcess,
               max_steps: 3,
               auto_rebalance_closure: true
             )

    assert report.status == :complete
    assert report.steps == 3
    assert report.phases == [:copy, :source_cleanup, :rebalance_closure]

    assert [%{phase: :copy}, %{phase: :source_cleanup}, %{phase: :rebalance_closure}] =
             report.reports

    assert {:ok, verified} = Jobs.get(job.id)
    assert verified.data_movement_status == "complete"
    assert verified.source_cleanup_status == "complete"
    assert verified.rebalance_closure_status == "verified"
    assert verified.rebalance_closure_results["rebalance_complete?"] == true

    assert {:ok, destination_stream} =
             Distributed.get(bucket, key, "v1", nil, Keyword.put(opts, :placement_set_id, 1))

    assert IO.iodata_to_binary(Enum.to_list(destination_stream)) == body
    assert {:error, :enoent} = Distributed.get(bucket, key, "v1", nil, source_opts)
  end

  test "run_steps reports blocked closure as blocked with blocker evidence", ctx do
    :persistent_term.put(@topology_key, ctx.topology)

    bucket = bucket_name("rebalance-drain-blocked")
    key = key_for_set(bucket, ctx.topology, 1, "drain")
    body = "drain-blocked-closure"
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", body, source_opts)
    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)
    job_id = job.id

    assert {:ok, report} =
             Scheduler.run_steps(
               job_id: job_id,
               topology: ctx.topology,
               transport: InProcess,
               max_steps: 3,
               auto_rebalance_closure: true,
               closure_verifier: fn ^job_id, _opts ->
                 {:ok,
                  %{
                    status: :blocked,
                    job_id: job_id,
                    phase: :rebalance_closure,
                    blockers: [:routing_mismatch]
                  }}
               end
             )

    assert report.status == :blocked
    assert report.steps == 3
    assert report.terminal_phase == :rebalance_closure
    assert report.blockers == [:routing_mismatch]
    assert report.phases == [:copy, :source_cleanup, :rebalance_closure]
  end

  test "auto runtime topology disabled leaves cleaned decommission idle", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    :persistent_term.put(@topology_key, ctx.topology)
    Application.put_env(:maxio, :topology_source, :db)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        auto_runtime_topology: false,
        auto_deployment_topology: true
      )

    assert {:error, :no_runnable_job} = Scheduler.run_now(pid, [])
    assert Topology.all_set_ids() == [0, 1]

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.topology_removal_status == "not_started"
    assert unchanged.topology_removal_cluster_status == "not_started"
  end

  test "auto runtime topology requires paired deployment finalization", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    :persistent_term.put(@topology_key, ctx.topology)
    Application.put_env(:maxio, :topology_source, :db)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        auto_runtime_topology: true,
        auto_deployment_topology: false
      )

    assert {:error, :runtime_topology_requires_auto_deployment_topology} =
             Scheduler.run_now(pid, [])

    assert Topology.all_set_ids() == [0, 1]

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.topology_removal_cluster_status == "not_started"
  end

  test "auto runtime topology requires DB topology source", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    :persistent_term.put(@topology_key, ctx.topology)
    Application.put_env(:maxio, :topology_source, :config)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        auto_runtime_topology: true,
        auto_deployment_topology: true
      )

    assert {:error, :runtime_topology_requires_db_source} = Scheduler.run_now(pid, [])
    assert Topology.all_set_ids() == [0, 1]

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.topology_removal_cluster_status == "not_started"
  end

  test "auto runtime topology strips low-level topology overrides", ctx do
    parent = self()
    {:ok, job} = complete_empty_decommission(ctx)
    :persistent_term.put(@topology_key, ctx.topology)
    Application.put_env(:maxio, :topology_source, :db)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        auto_runtime_topology: true,
        auto_deployment_topology: true,
        run_opts: [
          topology: ctx.topology,
          expected_current_topology_hash: "stale",
          runtime_topology: ctx.topology,
          deployment_topology: ctx.topology,
          node_apply_fun: fn _node, _topology, _expected -> {:error, :stale} end,
          node_snapshot_fun: fn _node -> {:error, :stale} end,
          after_topology_removal_audit: fn -> flunk("scheduler kept audit hook") end,
          nodes: [:"stale@127.0.0.1"],
          lock_opts: [nodes: []],
          transport: InProcess
        ],
        runtime_applier: fn job_id, opts ->
          send(parent, {:runtime_opts, job_id, opts})
          {:ok, %{status: :applied, job_id: job_id}}
        end
      )

    assert {:ok, %{phase: :runtime_topology}} = Scheduler.run_now(pid, [])

    assert_receive {:runtime_opts, job_id, opts}
    assert job_id == job.id
    refute Keyword.has_key?(opts, :topology)
    refute Keyword.has_key?(opts, :expected_current_topology_hash)
    refute Keyword.has_key?(opts, :runtime_topology)
    refute Keyword.has_key?(opts, :deployment_topology)
    refute Keyword.has_key?(opts, :node_apply_fun)
    refute Keyword.has_key?(opts, :node_snapshot_fun)
    refute Keyword.has_key?(opts, :after_topology_removal_audit)
    refute Keyword.has_key?(opts, :nodes)
    assert Keyword.fetch!(opts, :transport) == InProcess
    assert Keyword.fetch!(Keyword.fetch!(opts, :lock_opts), :nodes) == [Node.self()]
  end

  test "auto runtime topology applies cluster runtime then deployment topology finalizes", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    :persistent_term.put(@topology_key, ctx.topology)
    current_hash = Placement.topology_hash(ctx.topology)
    Application.put_env(:maxio, :topology_source, :db)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        transport: InProcess,
        auto_runtime_topology: true,
        auto_deployment_topology: true
      )

    assert {:ok, runtime_report} = Scheduler.run_now(pid, [])
    assert runtime_report.scheduler
    assert runtime_report.phase == :runtime_topology
    assert runtime_report.status == :applied
    assert runtime_report.apply_scope == :cluster_runtime
    assert runtime_report.current_topology_hash == current_hash
    assert runtime_report.proposed_topology_hash != current_hash
    assert Topology.all_set_ids() == [1]

    assert {:ok, converged} = Jobs.get(job.id)
    assert converged.topology_removal_status == "runtime_local_applied"
    assert converged.topology_removal_cluster_status == "runtime_converged"
    assert converged.topology_removal_cluster_hash == runtime_report.proposed_topology_hash

    assert {:ok, deployment_report} = Scheduler.run_now(pid, [])
    assert deployment_report.scheduler
    assert deployment_report.phase == :deployment_topology
    assert deployment_report.status == :verified
    assert deployment_report.deployment_topology_hash == runtime_report.proposed_topology_hash
    assert deployment_report.write_routing_retired

    assert {:ok, active_topology} = TopologyStore.active_topology()
    assert Placement.topology_hash(active_topology) == runtime_report.proposed_topology_hash

    assert {:ok, verified} = Jobs.get(job.id)
    assert verified.topology_removal_deployment_status == "verified"
  end

  test "auto runtime topology preserves preflight guards before runtime install", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    :persistent_term.put(@topology_key, ctx.topology)
    Application.put_env(:maxio, :topology_source, :db)

    bucket = bucket_name("rebalance-scheduler-runtime-stale-placement")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, "stale-target.txt", "v1", %{
        size: 1,
        etag: "stale-etag",
        placement_set_id: job.target_set_id,
        placement_pool_id: 0,
        placement_topology_hash: Placement.topology_hash(ctx.topology)
      })

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        transport: InProcess,
        auto_runtime_topology: true,
        auto_deployment_topology: true
      )

    assert {:error, {:preflight_blocked, blocked}} = Scheduler.run_now(pid, [])
    assert :pg_placements_remaining in blocked.blockers
    assert Topology.all_set_ids() == [0, 1]

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.topology_removal_cluster_status == "not_started"
    assert {:error, :no_active_topology_revision} = TopologyStore.active_revision()
  end

  test "auto deployment topology disabled leaves finalized decommission idle", ctx do
    {_job, _apply_report} = applied_empty_removal(ctx)
    Application.put_env(:maxio, :topology_source, :db)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        auto_deployment_topology: false
      )

    assert {:error, :no_runnable_job} = Scheduler.run_now(pid, [])
    assert {:error, :no_active_topology_revision} = TopologyStore.active_revision()
  end

  test "auto deployment topology requires DB topology source", ctx do
    {_job, _apply_report} = applied_empty_removal(ctx)
    Application.put_env(:maxio, :topology_source, :config)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        auto_deployment_topology: true
      )

    assert {:error, :deployment_topology_requires_db_source} = Scheduler.run_now(pid, [])
    assert {:error, :no_active_topology_revision} = TopologyStore.active_revision()
  end

  test "auto deployment topology strips low-level topology overrides", ctx do
    parent = self()
    {_job, apply_report} = applied_empty_removal(ctx)
    Application.put_env(:maxio, :topology_source, :db)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        auto_deployment_topology: true,
        run_opts: [
          runtime_topology: ctx.topology,
          deployment_topology: ctx.topology,
          expected_proposed_topology_hash: "stale",
          node_snapshot_fun: fn _node -> {:error, :stale} end,
          lock_opts: [nodes: []]
        ],
        deployment_finalizer: fn job_id, opts ->
          send(parent, {:finalize_opts, job_id, opts})

          {:ok,
           %{
             status: :verified,
             job_id: job_id,
             deployment_topology_hash: apply_report.proposed_topology_hash,
             expected_proposed_hash: apply_report.proposed_topology_hash,
             revision_id: "fake-revision",
             write_routing_retired: true
           }}
        end
      )

    assert {:ok, %{phase: :deployment_topology}} = Scheduler.run_now(pid, [])

    assert_receive {:finalize_opts, job_id, persist_opts}
    assert job_id == apply_report.job_id

    assert Keyword.fetch!(persist_opts, :expected_proposed_topology_hash) ==
             apply_report.proposed_topology_hash

    refute Keyword.has_key?(persist_opts, :runtime_topology)
    refute Keyword.has_key?(persist_opts, :deployment_topology)
    refute Keyword.has_key?(persist_opts, :node_snapshot_fun)
    assert Keyword.fetch!(Keyword.fetch!(persist_opts, :lock_opts), :nodes) == [Node.self()]
  end

  test "auto deployment topology persists DB revision and verifies deployment", ctx do
    {_job, apply_report} = applied_empty_removal(ctx)
    Application.put_env(:maxio, :topology_source, :db)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        auto_deployment_topology: true
      )

    assert {:ok, report} = Scheduler.run_now(pid, [])
    assert report.scheduler
    assert report.phase == :deployment_topology
    assert report.status == :verified
    assert report.job_id == apply_report.job_id
    assert report.deployment_topology_hash == apply_report.proposed_topology_hash
    assert report.expected_proposed_hash == apply_report.proposed_topology_hash
    assert report.revision_id
    assert report.write_routing_retired

    assert %{last_result: %{phase: :deployment_topology}, last_skip_reason: nil} =
             Scheduler.status(pid)

    assert {:ok, active_topology} = TopologyStore.active_topology()
    assert Placement.topology_hash(active_topology) == apply_report.proposed_topology_hash

    assert {:ok, updated} = Jobs.get(apply_report.job_id)
    assert updated.topology_removal_deployment_status == "verified"
    assert updated.topology_removal_deployment_hash == apply_report.proposed_topology_hash
    assert updated.topology_removal_deployment_verified_at

    assert {:error, :no_runnable_job} = Scheduler.run_now(pid, [])
  end

  test "auto deployment topology preserves guards when target placement reappears", ctx do
    {_job, apply_report} = applied_empty_removal(ctx)
    Application.put_env(:maxio, :topology_source, :db)

    bucket = bucket_name("rebalance-scheduler-stale-placement")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, "stale-target.txt", "v1", %{
        size: 1,
        etag: "stale-etag",
        placement_set_id: apply_report.target_set_id,
        placement_pool_id: apply_report.removed_pool_id,
        placement_topology_hash: apply_report.current_topology_hash
      })

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        auto_deployment_topology: true
      )

    assert {:error, {:deployment_persistence_blocked, blocked}} = Scheduler.run_now(pid, [])
    assert :pg_placements_remaining in blocked.blockers
    assert {:error, :no_active_topology_revision} = TopologyStore.active_revision()

    assert {:ok, unchanged} = Jobs.get(apply_report.job_id)
    assert unchanged.topology_removal_deployment_status == "not_started"
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

  defp complete_empty_decommission(ctx) do
    bucket = bucket_name("rebalance-scheduler-empty")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, dist_opts(ctx))
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, complete} = Jobs.complete_data_movement(job.id)
    {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)
    Jobs.complete_source_cleanup(cleaning.id)
  end

  defp start_scheduler!(opts) do
    start_supervised!({Scheduler, Keyword.merge([name: nil, lock_nodes: [Node.self()]], opts)})
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

  defp key_for_set(bucket, topology, set_id, prefix \\ "obj") do
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

  defp restore_topology_source(:__maxio_no_source__),
    do: Application.delete_env(:maxio, :topology_source)

  defp restore_topology_source(source),
    do: Application.put_env(:maxio, :topology_source, source)
end
