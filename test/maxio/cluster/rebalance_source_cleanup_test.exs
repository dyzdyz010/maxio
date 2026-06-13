defmodule Maxio.Cluster.RebalanceSourceCleanupTest do
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects}

  alias Maxio.Cluster.{
    Lock,
    Paths,
    Placement,
    Rebalance.Jobs,
    Rebalance.Runner,
    Rebalance.SourceCleanup,
    Router,
    Topology
  }

  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.Distributed

  @owner "arn:aws:iam:::root"

  setup do
    InProcess.setup!()
    previous_backend = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Distributed)

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_cleanup_#{System.unique_integer([:positive])}"
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
      File.rm_rf(base)
    end)

    {:ok, topology: topology}
  end

  test "cleanup_once deletes migrated source object and delete-marker copies only", ctx do
    bucket = bucket_name("rebalance-cleanup")
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    destination_opts = Keyword.put(opts, :placement_set_id, 1)
    key = key_for_set(bucket, ctx.topology, 0)
    marker_key = key_for_set(bucket, ctx.topology, 0, "deleted")
    body = "cleanup-copy-pass-body"

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    {:ok, _object} = put_object_version!(bucket, key, "v1", body, source_opts)
    :ok = Distributed.put_delete_marker(bucket, marker_key, "dm1", [], source_opts)

    {:ok, _marker} =
      Objects.insert_delete_marker_with_id(
        bucket,
        marker_key,
        "dm1",
        Placement.attrs_for_write(bucket, marker_key, source_opts)
      )

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:ok, move_report} =
             Runner.run_once(job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               transport: InProcess
             )

    assert move_report.status == :ok
    assert {:ok, source_stream} = Distributed.get(bucket, key, "v1", nil, source_opts)
    assert IO.iodata_to_binary(Enum.to_list(source_stream)) == body
    assert delete_marker_sidecar?(ctx.topology, marker_key, bucket, "dm1", 0)

    assert {:ok, cleanup} =
             SourceCleanup.cleanup_once(job.id, topology: ctx.topology, transport: InProcess)

    assert cleanup.status == :ok
    assert cleanup.source_cleanup_status == "complete"
    assert cleanup.source_cleanup == true
    assert cleanup.scanned == 2
    assert cleanup.deleted == 2
    assert cleanup.skipped == 0
    assert cleanup.errors == 0

    assert {:ok, destination_stream} = Distributed.get(bucket, key, "v1", nil, destination_opts)
    assert IO.iodata_to_binary(Enum.to_list(destination_stream)) == body
    assert {:error, :enoent} = Distributed.get(bucket, key, "v1", nil, source_opts)
    assert delete_marker_sidecar?(ctx.topology, marker_key, bucket, "dm1", 1)
    refute delete_marker_sidecar?(ctx.topology, marker_key, bucket, "dm1", 0)

    assert {:ok, finished} = Jobs.get(job.id)
    assert finished.status == "complete"
    assert finished.data_movement_status == "complete"
    assert finished.source_cleanup_status == "complete"
  end

  test "max_versions leaves cleanup moving and second pass resumes from cursor", ctx do
    bucket = bucket_name("rebalance-cleanup-resume")
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    for i <- 1..2 do
      key = key_for_set(bucket, ctx.topology, 0, "resume-#{i}")
      {:ok, _object} = put_object_version!(bucket, key, "v#{i}", "body-#{i}", source_opts)
    end

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:ok, %{status: :ok}} =
             Runner.run_once(job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               transport: InProcess
             )

    assert {:ok, partial} =
             SourceCleanup.cleanup_once(job.id,
               topology: ctx.topology,
               transport: InProcess,
               max_versions: 1
             )

    assert partial.status == :partial
    assert partial.scanned == 1
    assert partial.deleted == 1

    assert {:ok, running} = Jobs.get(job.id)
    assert running.status == "running"
    assert running.source_cleanup_status == "moving"
    assert running.source_cleanup_cursor_bucket == bucket

    assert {:ok, complete} =
             SourceCleanup.cleanup_once(job.id, topology: ctx.topology, transport: InProcess)

    assert complete.status == :ok
    assert complete.scanned == 2
    assert complete.deleted == 2

    assert {:ok, finished} = Jobs.get(job.id)
    assert finished.source_cleanup_status == "complete"
    assert is_nil(finished.source_cleanup_cursor_bucket)
  end

  test "cleanup fails closed when PG placement still points at source target", ctx do
    bucket = bucket_name("rebalance-cleanup-target")
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    key = key_for_set(bucket, ctx.topology, 0)
    body = "still-source"

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", body, source_opts)

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, _complete} = Jobs.complete_data_movement(job.id)

    assert {:ok, report} =
             SourceCleanup.cleanup_once(job.id, topology: ctx.topology, transport: InProcess)

    assert report.status == :failed
    assert report.deleted == 0
    assert report.errors == 1

    assert {:ok, source_stream} = Distributed.get(bucket, key, "v1", nil, source_opts)
    assert IO.iodata_to_binary(Enum.to_list(source_stream)) == body

    assert {:ok, failed} = Jobs.get(job.id)
    assert failed.status == "failed"
    assert failed.data_movement_status == "complete"
    assert failed.source_cleanup_status == "failed"
  end

  test "cleanup skips rows whose PG placement is neither source nor destination", ctx do
    bucket = bucket_name("rebalance-cleanup-skip")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, ctx.topology, 0)
    other_key = key_for_set(bucket, ctx.topology, 0, "other-placement")

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, _complete} = Jobs.complete_data_movement(job.id)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "v1", %{size: 1, etag: "e1"})

    {:ok, _other} =
      Objects.put_version_with_id(bucket, other_key, "v1", %{
        size: 1,
        etag: "e2",
        placement_set_id: 99
      })

    assert {:ok, report} =
             SourceCleanup.cleanup_once(job.id, topology: ctx.topology, transport: InProcess)

    assert report.status == :ok
    assert report.scanned == 2
    assert report.deleted == 0
    assert report.skipped == 2
    assert report.errors == 0
  end

  test "cleanup final guard fails if target placement appears after scan", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    bucket = bucket_name("rebalance-cleanup-final-guard")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    before_complete = fn ->
      {:ok, _late} =
        Objects.put_version_with_id(bucket, "late-target.txt", "v1", %{
          size: 1,
          etag: "e1",
          placement_set_id: 0
        })

      :ok
    end

    assert {:ok, report} =
             SourceCleanup.cleanup_once(job.id,
               topology: ctx.topology,
               transport: InProcess,
               before_complete: before_complete
             )

    assert report.status == :failed
    assert report.deleted == 0
    assert report.errors == 1

    assert {:ok, failed} = Jobs.get(job.id)
    assert failed.status == "failed"
    assert failed.data_movement_status == "complete"
    assert failed.source_cleanup_status == "failed"
  end

  test "cleanup lock contention fails before mutating the job", ctx do
    {:ok, job} = complete_empty_decommission(ctx)
    lock_holder = hold_lock({:rebalance_job_runner, job.id})

    try do
      assert {:error, :runner_locked} =
               SourceCleanup.cleanup_once(job.id,
                 topology: ctx.topology,
                 transport: InProcess,
                 runner_lock_opts: [nodes: [Node.self()], refresh: false]
               )

      assert {:ok, unchanged} = Jobs.get(job.id)
      assert unchanged.status == "complete"
      assert unchanged.source_cleanup_status == "not_started"
      assert unchanged.source_cleanup_scanned == 0
    after
      release_lock(lock_holder)
    end
  end

  test "delete_version quorum failure marks cleanup failed without touching destination", ctx do
    bucket = bucket_name("rebalance-cleanup-quorum")
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    destination_opts = Keyword.put(opts, :placement_set_id, 1)
    key = key_for_set(bucket, ctx.topology, 0)
    body = "cleanup-quorum"

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", body, source_opts)

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:ok, %{status: :ok}} =
             Runner.run_once(job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               transport: InProcess
             )

    [{node, drive} | _] = Topology.endpoints_from(ctx.topology, 0)
    InProcess.set_drive_down(node, drive)

    assert {:ok, report} =
             SourceCleanup.cleanup_once(job.id, topology: ctx.topology, transport: InProcess)

    assert report.status == :failed
    assert report.deleted == 0
    assert report.errors == 1

    assert {:ok, destination_stream} = Distributed.get(bucket, key, "v1", nil, destination_opts)
    assert IO.iodata_to_binary(Enum.to_list(destination_stream)) == body

    assert {:ok, failed} = Jobs.get(job.id)
    assert failed.source_cleanup_status == "failed"
  end

  defp complete_empty_decommission(ctx) do
    bucket = bucket_name("rebalance-cleanup-empty")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, complete} = Jobs.complete_data_movement(job.id)
    {:ok, complete}
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

  defp delete_marker_sidecar?(topology, key, bucket, version_id, set_id) do
    {:ok, rel} = Paths.object_rel(bucket, key, version_id)
    {node, drive} = topology |> Topology.endpoints_from(set_id) |> hd()

    case InProcess.get_sidecar(node, Path.join(drive, rel)) do
      {:ok, %{"versions" => [%{"type" => "delete_marker", "version_id" => ^version_id}]}} -> true
      _ -> false
    end
  end

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

  defp hold_lock(resource) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, lease} = Lock.acquire(resource, nodes: [Node.self()], refresh: false)
        send(parent, {:lock_held, self()})

        receive do
          :release_lock -> :ok = Lock.release(lease)
        end
      end)

    ref = Process.monitor(pid)
    assert_receive {:lock_held, ^pid}
    {pid, ref}
  end

  defp release_lock({pid, ref}) do
    send(pid, :release_lock)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
