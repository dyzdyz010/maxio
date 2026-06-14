defmodule Maxio.Cluster.FreshDriveHeal.SchedulerTest do
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.{DriveHealth, Lock, Paths, Topology, Transport.InProcess}
  alias Maxio.Cluster.FreshDriveHeal.Scheduler
  alias Maxio.Cluster.Placement
  alias Maxio.Cluster.Rebalance.Jobs
  alias Maxio.Cluster.Router
  alias Maxio.Cluster.SchedulerRuns
  alias Maxio.Storage.Distributed

  @owner "arn:aws:iam:::root"
  @scheduler_lock {:fresh_drive_heal_scheduler, :run}

  setup do
    InProcess.setup!()
    DriveHealth.reset()

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_fresh_drive_scheduler_#{System.unique_integer([:positive])}"
      )

    endpoints = for i <- 0..5, do: {Node.self(), Path.join(base, "d#{i}")}
    Enum.each(endpoints, fn {_node, drive} -> File.mkdir_p!(drive) end)

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    on_exit(fn ->
      DriveHealth.reset()
      File.rm_rf(base)
    end)

    {:ok, endpoints: endpoints, topology: topology}
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

  test "run_now invokes runner and records the result" do
    parent = self()

    pid =
      start_scheduler!(
        enabled: false,
        runner: fn opts ->
          send(parent, {:runner_opts, opts})
          {:ok, fake_report(:ok)}
        end
      )

    assert {:ok, %{status: :ok}} = Scheduler.run_now(pid, page_size: 17)
    assert_receive {:runner_opts, opts}
    assert Keyword.fetch!(opts, :scan_versions)
    assert Keyword.fetch!(opts, :page_size) == 17

    assert %{last_result: %{status: :ok}, last_skip_reason: nil} = Scheduler.status(pid)

    assert %{status: "ok", consecutive_failures: 0, last_summary: %{"status" => "ok"}} =
             SchedulerRuns.state(:fresh_drive_heal)
  end

  test "scheduled run respects persisted backoff and does not invoke runner" do
    now = ~U[2026-06-14 00:00:00.000000Z]
    backoff_now = DateTime.add(now, 1, :second)
    parent = self()

    {:ok, %{state: failed}} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        now,
        now,
        {:error, :boom},
        failure_threshold: 1,
        backoff_ms: 60_000
      )

    assert failed.backoff_until == DateTime.add(now, 60, :second)

    pid =
      start_scheduler!(
        enabled: true,
        initial_delay_ms: 60_000,
        interval_ms: 60_000,
        scheduler_ledger: [
          failure_threshold: 1,
          backoff_ms: 60_000,
          now_fun: fn -> backoff_now end
        ],
        runner: fn _opts ->
          send(parent, :runner_called)
          {:ok, fake_report(:ok)}
        end
      )

    send(pid, :run)
    _ = :sys.get_state(pid)

    refute_receive :runner_called, 20
    assert %{last_skip_reason: {:backoff_active, _until}} = Scheduler.status(pid)

    assert %{status: "failed", consecutive_failures: 1, alert_status: "alert"} =
             SchedulerRuns.state(:fresh_drive_heal)
  end

  test "scheduled run records a result and reschedules" do
    parent = self()

    pid =
      start_scheduler!(
        enabled: true,
        initial_delay_ms: 0,
        interval_ms: 60_000,
        scheduler_ledger: [enabled: false],
        runner: fn opts ->
          send(parent, {:scheduled_runner, opts})
          {:ok, fake_report(:ok)}
        end
      )

    assert_receive {:scheduled_runner, _opts}, 1_000
    _ = :sys.get_state(pid)
    assert %{scheduled?: true, last_result: %{status: :ok}} = Scheduler.status(pid)
  end

  test "runner crash is captured and scheduler remains callable" do
    pid =
      start_scheduler!(
        enabled: false,
        runner: fn _opts -> raise "scheduler-boom" end
      )

    assert {:error, {:crashed, "scheduler-boom"}} = Scheduler.run_now(pid, [])
    assert %{last_skip_reason: {:crashed, "scheduler-boom"}} = Scheduler.status(pid)
  end

  test "clean marker-clearing pass enqueues one rebalance job when routing mismatches exist" do
    parent = self()
    topology = two_set_topology("fresh-rebalance-enqueue")
    topology_hash = Placement.topology_hash(topology)
    bucket = bucket_name("fresh-rebalance-enqueue")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 1, "needs-rebalance")

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 11,
        etag: "e11",
        placement_set_id: 0,
        placement_topology_hash: topology_hash
      })

    pid =
      start_scheduler!(
        enabled: false,
        auto_rebalance_after_heal: true,
        runner: fn _opts -> {:ok, fake_report(:ok, drives_cleared: 1)} end,
        rebalance_advancer: fn _opts ->
          send(parent, :rebalance_advancer_called)
          {:ok, %{}}
        end,
        rebalance_start_opts: [topology: topology, include_drive_stats: false]
      )

    assert {:ok, report} = Scheduler.run_now(pid, [])
    assert report.rebalance_enqueue.status == :created
    assert report.rebalance_enqueue.plan_routing_mismatches == 1

    assert [%{id: job_id, kind: "rebalance", requested_by: "fresh_drive_heal_scheduler"}] =
             Jobs.list(kind: "rebalance")

    assert report.rebalance_enqueue.job_id == job_id
    refute Map.has_key?(report, :rebalance_advance)
    refute_receive :rebalance_advancer_called, 20

    assert {:ok, second} = Scheduler.run_now(pid, [])
    assert second.rebalance_enqueue.status == :skipped
    assert second.rebalance_enqueue.reason == :active_job_exists
    assert [_one_job] = Jobs.list(kind: "rebalance")
  end

  test "auto advance drains the rebalance job created by a clean marker-clearing pass" do
    previous_backend = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Distributed)
    on_exit(fn -> Application.put_env(:maxio, :storage_backend, previous_backend) end)

    topology = two_set_topology("fresh-rebalance-advance")
    bucket = bucket_name("fresh-rebalance-advance")
    key = key_for_set(bucket, topology, 1, "needs-rebalance")
    body = "fresh-rebalance-advance-body"
    opts = [topology: topology, transport: InProcess]
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    destination_opts = Keyword.put(opts, :placement_set_id, 1)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", body, source_opts)

    pid =
      start_scheduler!(
        enabled: false,
        auto_rebalance_after_heal: true,
        auto_advance_rebalance_after_heal: true,
        rebalance_advance_max_steps: 2,
        runner: fn _opts -> {:ok, fake_report(:ok, drives_cleared: 1)} end,
        topology: topology,
        transport: InProcess,
        rebalance_start_opts: [topology: topology, include_drive_stats: false]
      )

    assert {:ok, report} = Scheduler.run_now(pid, [])
    assert report.status == :ok
    assert report.rebalance_enqueue.status == :created
    assert report.rebalance_advance.status == :complete
    assert report.rebalance_advance.job_id == report.rebalance_enqueue.job_id
    assert report.rebalance_advance.steps == 2
    assert report.rebalance_advance.phases == [:copy, :source_cleanup]

    assert {:ok, job} = Jobs.get(report.rebalance_enqueue.job_id)
    assert job.kind == "rebalance"
    assert job.data_movement_status == "complete"
    assert job.source_cleanup_status == "complete"
    assert job.rebalance_closure_status == "not_started"

    assert {:ok, moved} = Objects.get_version(bucket, key, "v1")
    assert moved.placement_set_id == 1

    assert {:ok, destination_stream} = Distributed.get(bucket, key, "v1", nil, destination_opts)
    assert IO.iodata_to_binary(Enum.to_list(destination_stream)) == body
    assert {:error, :enoent} = Distributed.get(bucket, key, "v1", nil, source_opts)
  end

  test "auto rebalance enqueue skips non-clean or marker-free heal results" do
    parent = self()

    pid =
      start_scheduler!(
        enabled: false,
        auto_rebalance_after_heal: true,
        auto_advance_rebalance_after_heal: true,
        runner: fn _opts -> {:ok, fake_report(:partial, drives_cleared: 0)} end,
        rebalance_starter: fn _opts ->
          send(parent, :rebalance_starter_called)
          {:ok, :not_needed}
        end
      )

    assert {:ok, report} = Scheduler.run_now(pid, [])
    assert report.rebalance_enqueue.status == :not_eligible
    assert report.rebalance_enqueue.reason == :partial
    assert report.rebalance_advance.status == :not_eligible
    assert report.rebalance_advance.reason == {:rebalance_enqueue, :not_eligible}
    refute_receive :rebalance_starter_called, 20
  end

  test "auto rebalance enqueue reports not_needed without creating repeat jobs" do
    parent = self()
    topology = two_set_topology("fresh-rebalance-not-needed")
    topology_hash = Placement.topology_hash(topology)
    bucket = bucket_name("fresh-rebalance-not-needed")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0, "already-placed")

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 7,
        etag: "e7",
        placement_set_id: 0,
        placement_topology_hash: topology_hash
      })

    pid =
      start_scheduler!(
        enabled: false,
        auto_rebalance_after_heal: true,
        auto_advance_rebalance_after_heal: true,
        runner: fn _opts -> {:ok, fake_report(:ok, drives_cleared: 1)} end,
        rebalance_advancer: fn _opts ->
          send(parent, :rebalance_advancer_called)
          {:ok, %{}}
        end,
        rebalance_start_opts: [topology: topology, include_drive_stats: false]
      )

    assert {:ok, first} = Scheduler.run_now(pid, [])
    assert first.rebalance_enqueue.status == :not_needed
    assert first.rebalance_advance.status == :not_eligible
    assert first.rebalance_advance.reason == {:rebalance_enqueue, :not_needed}
    assert [] = Jobs.list(kind: "rebalance")

    assert {:ok, second} = Scheduler.run_now(pid, [])
    assert second.rebalance_enqueue.status == :not_needed
    assert second.rebalance_advance.status == :not_eligible
    assert [] = Jobs.list(kind: "rebalance")
    refute_receive :rebalance_advancer_called, 20
  end

  test "auto rebalance enqueue preserves placement fallback refusal as failed evidence" do
    parent = self()
    topology = two_set_topology("fresh-rebalance-fallback")
    bucket = bucket_name("fresh-rebalance-fallback")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0, "legacy")
    {:ok, _object} = Objects.put_version_with_id(bucket, key, "null", %{size: 5, etag: "e5"})

    pid =
      start_scheduler!(
        enabled: false,
        auto_rebalance_after_heal: true,
        auto_advance_rebalance_after_heal: true,
        runner: fn _opts -> {:ok, fake_report(:ok, drives_cleared: 1)} end,
        rebalance_advancer: fn _opts ->
          send(parent, :rebalance_advancer_called)
          {:ok, %{}}
        end,
        rebalance_start_opts: [topology: topology, include_drive_stats: false]
      )

    assert {:ok, report} = Scheduler.run_now(pid, [])
    assert report.rebalance_enqueue.status == :failed
    assert report.rebalance_enqueue.reason =~ "placement_fallbacks"
    assert report.rebalance_advance.status == :not_eligible
    assert report.rebalance_advance.reason == {:rebalance_enqueue, :failed}
    assert [] = Jobs.list(kind: "rebalance")
    refute_receive :rebalance_advancer_called, 20
  end

  test "auto advance records failure evidence without failing the heal result" do
    parent = self()
    topology = two_set_topology("fresh-rebalance-advance-fail")
    topology_hash = Placement.topology_hash(topology)
    bucket = bucket_name("fresh-rebalance-advance-fail")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 1, "needs-rebalance")

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 11,
        etag: "e11",
        placement_set_id: 0,
        placement_topology_hash: topology_hash
      })

    pid =
      start_scheduler!(
        enabled: false,
        auto_rebalance_after_heal: true,
        auto_advance_rebalance_after_heal: true,
        rebalance_advance_max_steps: 1,
        runner: fn _opts -> {:ok, fake_report(:ok, drives_cleared: 1)} end,
        rebalance_advancer: fn opts ->
          assert is_binary(Keyword.fetch!(opts, :job_id))
          send(parent, {:rebalance_advancer_opts, opts})
          {:error, :simulated_rebalance_advance_failure}
        end,
        rebalance_start_opts: [topology: topology, include_drive_stats: false],
        rebalance_advance_opts: [job_id: "wrong-job-id", max_steps: 99]
      )

    assert {:ok, report} = Scheduler.run_now(pid, [])
    assert report.status == :ok
    assert report.rebalance_enqueue.status == :created
    assert report.rebalance_advance.status == :failed
    assert report.rebalance_advance.job_id == report.rebalance_enqueue.job_id
    assert report.rebalance_advance.reason =~ "simulated_rebalance_advance_failure"
    assert_receive {:rebalance_advancer_opts, advance_opts}
    assert Keyword.fetch!(advance_opts, :job_id) == report.rebalance_enqueue.job_id
    assert Keyword.fetch!(advance_opts, :max_steps) == 1
  end

  test "auto advance preserves blocked closure evidence" do
    topology = two_set_topology("fresh-rebalance-advance-blocked")
    topology_hash = Placement.topology_hash(topology)
    bucket = bucket_name("fresh-rebalance-advance-blocked")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 1, "needs-rebalance")

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 11,
        etag: "e11",
        placement_set_id: 0,
        placement_topology_hash: topology_hash
      })

    pid =
      start_scheduler!(
        enabled: false,
        auto_rebalance_after_heal: true,
        auto_advance_rebalance_after_heal: true,
        runner: fn _opts -> {:ok, fake_report(:ok, drives_cleared: 1)} end,
        rebalance_advancer: fn opts ->
          {:ok,
           %{
             status: :blocked,
             job_id: Keyword.fetch!(opts, :job_id),
             steps: 3,
             phases: [:copy, :source_cleanup, :rebalance_closure],
             terminal_phase: :rebalance_closure,
             blockers: [:routing_mismatch]
           }}
        end,
        rebalance_start_opts: [topology: topology, include_drive_stats: false]
      )

    assert {:ok, report} = Scheduler.run_now(pid, [])
    assert report.status == :ok
    assert report.rebalance_enqueue.status == :created
    assert report.rebalance_advance.status == :blocked
    assert report.rebalance_advance.blockers == [:routing_mismatch]
    assert report.rebalance_advance.terminal_phase == :rebalance_closure
  end

  test "held singleton lock skips the scheduler run" do
    parent = self()

    pid =
      start_scheduler!(
        enabled: false,
        runner: fn _opts ->
          send(parent, :runner_called)
          {:ok, fake_report(:ok)}
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

  test "scheduler heals recovered drive and clears marker through existing workflow", ctx do
    bucket = bucket_name("fresh-scheduler")
    key = "object.bin"
    body = :crypto.strong_rand_bytes(2048)
    opts = dist_opts(ctx)
    {node, drive} = hd(ctx.endpoints)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    InProcess.set_drive_down(node, drive)
    assert %{offline: 1, heal_required: 0} = probe(ctx, 0)

    {:ok, %{size: size, etag: etag}} = Distributed.put(bucket, key, "null", [body], opts)
    put_index!(bucket, key, "null", size, etag)
    missing_part = part_path(drive, bucket, key, "null")
    refute File.exists?(missing_part)

    InProcess.set_drive_up(node, drive)
    assert %{online: 6, heal_required: 1} = probe(ctx, 1)
    assert DriveHealth.heal_required?({node, drive})

    pid =
      start_scheduler!(
        enabled: false,
        probe_drive_health: false,
        topology: ctx.topology,
        transport: InProcess,
        no_throttle: true
      )

    assert {:ok, report} = Scheduler.run_now(pid, [])
    assert report.status == :ok
    assert report.scanned == 1
    assert report.drives_cleared == 1
    assert File.exists?(missing_part)
    refute DriveHealth.heal_required?({node, drive})
  end

  defp start_scheduler!(opts) do
    start_supervised!({Scheduler, Keyword.merge([name: nil, lock_nodes: [Node.self()]], opts)})
  end

  defp fake_report(status, attrs \\ []), do: Map.merge(%{status: status}, Map.new(attrs))

  defp probe(ctx, now_ms) do
    DriveHealth.probe_topology(
      topology: ctx.topology,
      transport: InProcess,
      offline_after_ms: 0,
      now_ms: now_ms
    )
  end

  defp dist_opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  defp put_index!(bucket, key, version_id, size, etag) do
    {:ok, object} =
      Objects.put_version_with_id(bucket, key, version_id, %{
        size: size,
        etag: etag,
        content_type: "application/octet-stream"
      })

    object
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

  defp part_path(drive, bucket, key, version_id),
    do: Path.join(object_dir(drive, bucket, key, version_id), "part.0")

  defp object_dir(drive, bucket, key, version_id) do
    {:ok, rel} = Paths.object_rel(bucket, key, version_id)
    Path.join(drive, rel)
  end

  defp bucket_name(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.replace("-", "")

    "#{prefix}-#{suffix}"
  end

  defp two_set_topology(prefix) do
    base = Path.join(System.tmp_dir!(), "maxio_#{prefix}_#{System.unique_integer([:positive])}")
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

  defp key_for_set(bucket, topology, set_id, prefix) do
    Enum.find_value(0..10_000, fn i ->
      key = "#{prefix}-#{set_id}-#{i}.txt"
      if Router.set_for(bucket, key, topology) == set_id, do: key
    end) || flunk("could not find key for set #{inspect(set_id)}")
  end
end
