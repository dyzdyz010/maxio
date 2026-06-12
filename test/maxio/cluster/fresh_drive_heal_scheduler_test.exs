defmodule Maxio.Cluster.FreshDriveHeal.SchedulerTest do
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.{DriveHealth, Lock, Paths, Topology, Transport.InProcess}
  alias Maxio.Cluster.FreshDriveHeal.Scheduler
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
  end

  test "scheduled run records a result and reschedules" do
    parent = self()

    pid =
      start_scheduler!(
        enabled: true,
        initial_delay_ms: 0,
        interval_ms: 60_000,
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

  defp fake_report(status), do: %{status: status}

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
end
