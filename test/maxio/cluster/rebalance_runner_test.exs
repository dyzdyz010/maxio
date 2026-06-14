defmodule Maxio.Cluster.RebalanceRunnerTest do
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.{Lock, Paths, Placement, Rebalance.Jobs, Rebalance.Runner, Router, Topology}
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.Distributed

  @owner "arn:aws:iam:::root"

  setup do
    InProcess.setup!()
    previous_backend = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Distributed)

    base =
      Path.join(System.tmp_dir!(), "maxio_rebalance_runner_#{System.unique_integer([:positive])}")

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

  test "run_once copies object versions and delete markers to destination set", ctx do
    bucket = bucket_name("rebalance-runner")
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    destination_opts = Keyword.put(opts, :placement_set_id, 1)
    key = key_for_set(bucket, ctx.topology, 0)
    marker_key = key_for_set(bucket, ctx.topology, 0, "deleted")
    body = "copy-pass-body"

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    assert {:ok, write_result} =
             Distributed.put(bucket, key, "v1", [body],
               object_meta: %{content_type: "text/plain", user_metadata: %{"m" => "v"}},
               topology: ctx.topology,
               transport: InProcess,
               placement_set_id: 0
             )

    {:ok, object} =
      Objects.put_version_with_id(
        bucket,
        key,
        "v1",
        %{
          size: byte_size(body),
          etag: write_result.etag,
          content_type: "text/plain",
          metadata: %{"m" => "v"},
          placement_set_id: 0
        }
        |> Map.merge(Placement.attrs_from_result(write_result))
      )

    assert :ok = Distributed.put_delete_marker(bucket, marker_key, "dm1", [], source_opts)
    marker_attrs = Placement.attrs_for_write(bucket, marker_key, source_opts)

    {:ok, _marker} =
      Objects.insert_delete_marker_with_id(
        bucket,
        marker_key,
        "dm1",
        marker_attrs
      )

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:ok, report} =
             Runner.run_once(job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               transport: InProcess,
               page_size: 1
             )

    assert report.status == :ok
    assert report.target_set_id == 0
    assert report.destination_set_id == 1
    assert report.scanned == 2
    assert report.moved == 2
    assert report.source_cleanup == false
    assert report.topology_mutation == false

    assert {:ok, moved_object} = Objects.get_version(bucket, key, "v1")
    assert moved_object.placement_set_id == 1
    assert moved_object.updated_at == object.updated_at

    assert {:ok, stream} = Distributed.get(bucket, key, "v1", nil, destination_opts)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body

    assert {:ok, source_stream} = Distributed.get(bucket, key, "v1", nil, source_opts)
    assert IO.iodata_to_binary(Enum.to_list(source_stream)) == body

    assert {:ok, moved_marker} = Objects.get_version(bucket, marker_key, "dm1")
    assert moved_marker.placement_set_id == 1
    assert delete_marker_sidecar?(ctx.topology, marker_key, bucket, "dm1", 1)
    assert delete_marker_sidecar?(ctx.topology, marker_key, bucket, "dm1", 0)

    assert {:ok, complete} = Jobs.get(job.id)
    assert complete.status == "complete"
    assert complete.data_movement_status == "complete"
    assert complete.destination_set_id == 1
    assert complete.source_cleanup_status == "not_started"
  end

  test "run_once rebalances mismatched object versions and delete markers to router set", ctx do
    bucket = bucket_name("rebalance-runner-dynamic")
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    destination_opts = Keyword.put(opts, :placement_set_id, 1)
    key = key_for_set(bucket, ctx.topology, 1, "rebalance")
    marker_key = key_for_set(bucket, ctx.topology, 1, "rebalance-deleted")
    body = "rebalance-copy-pass-body"

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    assert {:ok, write_result} =
             Distributed.put(bucket, key, "v1", [body],
               object_meta: %{content_type: "text/plain", user_metadata: %{"m" => "v"}},
               topology: ctx.topology,
               transport: InProcess,
               placement_set_id: 0
             )

    {:ok, object} =
      Objects.put_version_with_id(
        bucket,
        key,
        "v1",
        %{
          size: byte_size(body),
          etag: write_result.etag,
          content_type: "text/plain",
          metadata: %{"m" => "v"}
        }
        |> Map.merge(Placement.attrs_from_result(write_result))
      )

    assert :ok = Distributed.put_delete_marker(bucket, marker_key, "dm1", [], source_opts)
    marker_attrs = Placement.attrs_for_write(bucket, marker_key, source_opts)

    {:ok, _marker} =
      Objects.insert_delete_marker_with_id(
        bucket,
        marker_key,
        "dm1",
        marker_attrs
      )

    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    assert {:ok, report} =
             Runner.run_once(job.id,
               topology: ctx.topology,
               transport: InProcess,
               page_size: 1
             )

    assert report.status == :ok
    assert report.job_kind == "rebalance"
    assert is_nil(report.target_set_id)
    assert is_nil(report.destination_set_id)
    assert report.scanned == 2
    assert report.moved == 2
    assert report.skipped == 0
    assert report.source_cleanup == false
    assert report.topology_mutation == false

    assert {:ok, moved_object} = Objects.get_version(bucket, key, "v1")
    assert moved_object.placement_set_id == 1
    assert moved_object.updated_at == object.updated_at

    assert {:ok, destination_stream} = Distributed.get(bucket, key, "v1", nil, destination_opts)
    assert IO.iodata_to_binary(Enum.to_list(destination_stream)) == body

    assert {:ok, source_stream} = Distributed.get(bucket, key, "v1", nil, source_opts)
    assert IO.iodata_to_binary(Enum.to_list(source_stream)) == body

    assert {:ok, moved_marker} = Objects.get_version(bucket, marker_key, "dm1")
    assert moved_marker.placement_set_id == 1
    assert delete_marker_sidecar?(ctx.topology, marker_key, bucket, "dm1", 1)
    assert delete_marker_sidecar?(ctx.topology, marker_key, bucket, "dm1", 0)

    assert {:ok, complete} = Jobs.get(job.id)
    assert complete.status == "complete"
    assert complete.data_movement_status == "complete"
    assert complete.source_cleanup_status == "not_started"
    assert is_nil(complete.destination_set_id)
  end

  test "max_versions leaves job running and next pass resumes from cursor", ctx do
    bucket = bucket_name("rebalance-partial")
    opts = dist_opts(ctx)
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    for i <- 1..2 do
      key = key_for_set(bucket, ctx.topology, 0, "partial-#{i}")
      body = "body-#{i}"
      source_opts = Keyword.put(opts, :placement_set_id, 0)
      {:ok, write_result} = Distributed.put(bucket, key, "v#{i}", [body], source_opts)

      {:ok, _object} =
        Objects.put_version_with_id(
          bucket,
          key,
          "v#{i}",
          %{size: byte_size(body), etag: write_result.etag}
          |> Map.merge(Placement.attrs_from_result(write_result))
        )
    end

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:ok, partial} =
             Runner.run_once(job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               transport: InProcess,
               max_versions: 1
             )

    assert partial.status == :partial
    assert partial.scanned == 1
    assert partial.moved == 1

    assert {:ok, running} = Jobs.get(job.id)
    assert running.status == "running"
    assert running.cursor_bucket == bucket

    assert {:ok, complete} =
             Runner.run_once(job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               transport: InProcess
             )

    assert complete.status == :ok
    assert complete.scanned == 2
    assert complete.moved == 2
    assert {:ok, finished} = Jobs.get(job.id)
    assert finished.status == "complete"
    assert is_nil(finished.cursor_bucket)
  end

  test "rebalance max_versions advances cursor across already-correct rows", ctx do
    bucket = bucket_name("rebalance-resume-skips")
    opts = dist_opts(ctx)
    set0_opts = Keyword.put(opts, :placement_set_id, 0)
    key_skip = key_for_set(bucket, ctx.topology, 0, "a-skip")
    key_move = key_for_set(bucket, ctx.topology, 1, "z-move")

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _skip} = put_object_version!(bucket, key_skip, "v1", "already-correct", set0_opts)
    {:ok, _move} = put_object_version!(bucket, key_move, "v1", "needs-rebalance", set0_opts)

    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    assert {:ok, partial} =
             Runner.run_once(job.id,
               topology: ctx.topology,
               transport: InProcess,
               max_versions: 1
             )

    assert partial.status == :partial
    assert partial.scanned == 1
    assert partial.moved == 0
    assert partial.skipped == 1

    assert {:ok, running} = Jobs.get(job.id)
    assert running.status == "running"
    assert running.cursor_bucket == bucket
    assert running.cursor_key_marker == key_skip

    assert {:ok, complete} =
             Runner.run_once(job.id, topology: ctx.topology, transport: InProcess)

    assert complete.status == :ok
    assert complete.scanned == 2
    assert complete.moved == 1
    assert complete.skipped == 1

    assert {:ok, moved} = Objects.get_version(bucket, key_move, "v1")
    assert moved.placement_set_id == 1

    assert {:ok, finished} = Jobs.get(job.id)
    assert finished.status == "complete"
    assert is_nil(finished.cursor_bucket)
  end

  test "auto_destination chooses healthy set by DriveStats free space", ctx do
    bucket = bucket_name("rebalance-auto-destination")
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    destination_opts = Keyword.put(opts, :placement_set_id, 1)
    key = key_for_set(bucket, ctx.topology, 0)
    body = "auto-destination-body"

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", body, source_opts)
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:ok, report} =
             Runner.run_once(job.id,
               topology: ctx.topology,
               transport: InProcess,
               auto_destination: true,
               provider: free_space_provider(%{"s0" => 2_000, "s1" => 8_000})
             )

    assert report.status == :ok
    assert report.destination_set_id == 1
    assert report.free_space_placement
    assert report.moved == 1

    assert {:ok, moved} = Objects.get_version(bucket, key, "v1")
    assert moved.placement_set_id == 1

    assert {:ok, stream} = Distributed.get(bucket, key, "v1", nil, destination_opts)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  test "runner refuses sidecar read or list authority", ctx do
    bucket = bucket_name("rebalance-authority")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, ctx.topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "v1", %{
        size: 1,
        etag: "e1",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:error, {:unsupported_authoritative_source, :read, :sidecar}} =
             Runner.run_once(job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               authoritative_source: [read: :sidecar, list: :pg]
             )

    assert {:error, {:unsupported_authoritative_source, :list, :sidecar}} =
             Runner.run_once(job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               authoritative_source: [read: :pg, list: :sidecar]
             )
  end

  test "rebalance runner refuses sidecar read authority", ctx do
    bucket = bucket_name("rebalance-authority")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, ctx.topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "v1", %{
        size: 1,
        etag: "e1",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    assert {:error, {:unsupported_authoritative_source, :read, :sidecar}} =
             Runner.run_once(job.id,
               topology: ctx.topology,
               authoritative_source: [read: :sidecar, list: :pg]
             )
  end

  test "rebalance fails closed when a row lacks persisted placement", ctx do
    bucket = bucket_name("rebalance-missing-placement")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)
    key = key_for_set(bucket, ctx.topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "v1", %{
        size: 1,
        etag: "e1"
      })

    assert {:ok, report} =
             Runner.run_once(job.id, topology: ctx.topology, transport: InProcess)

    assert report.status == :failed
    assert report.errors == 1

    assert {:ok, failed} = Jobs.get(job.id)
    assert failed.status == "failed"
    assert failed.data_movement_status == "failed"
    assert failed.error_reason =~ "rebalance_run_failed"
  end

  test "source cleanup waits for completed rebalance data movement", ctx do
    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    assert {:error, {:data_movement_not_complete, "not_started"}} =
             Jobs.begin_source_cleanup(job.id)
  end

  test "runner validates destination set boundaries before copying", ctx do
    bucket = bucket_name("rebalance-destination")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, ctx.topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "v1", %{
        size: 1,
        etag: "e1",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:error, :destination_matches_target} =
             Runner.run_once(job.id, destination_set_id: 0, topology: ctx.topology)

    assert {:error, {:unknown_destination_set_id, 99, [0, 1]}} =
             Runner.run_once(job.id, destination_set_id: 99, topology: ctx.topology)

    assert {:ok, _running} = Jobs.begin_data_movement(job.id, 1)

    assert {:error, {:destination_mismatch, 1, 0}} =
             Runner.run_once(job.id, destination_set_id: 0, topology: ctx.topology)
  end

  test "runner refuses to start when the job-level runner lock is held", ctx do
    bucket = bucket_name("rebalance-runner-lock")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, ctx.topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "v1", %{
        size: 1,
        etag: "e1",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    resource = {:rebalance_job_runner, job.id}
    lock_holder = hold_lock(resource)

    try do
      assert {:error, :runner_locked} =
               Runner.run_once(job.id,
                 destination_set_id: 1,
                 topology: ctx.topology,
                 transport: InProcess,
                 runner_lock_opts: [nodes: [Node.self()], refresh: false]
               )

      assert {:ok, unchanged} = Jobs.get(job.id)
      assert unchanged.status == "planned"
      assert unchanged.progress_scanned == 0
      assert is_nil(unchanged.destination_set_id)
    after
      release_lock(lock_holder)
    end
  end

  test "dry-run bypasses held job-level runner lock and does not mutate job", ctx do
    bucket = bucket_name("rebalance-dry-run-lock")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, ctx.topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "v1", %{
        size: 1,
        etag: "e1",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    lock_holder = hold_lock({:rebalance_job_runner, job.id})

    try do
      assert {:ok, report} =
               Runner.run_once(job.id,
                 destination_set_id: 1,
                 topology: ctx.topology,
                 transport: InProcess,
                 dry_run: true
               )

      assert report.status == :dry_run
      assert report.scanned == 1
      assert report.moved == 1

      assert {:ok, unchanged} = Jobs.get(job.id)
      assert unchanged.status == "planned"
      assert unchanged.progress_scanned == 0
      assert is_nil(unchanged.destination_set_id)
    after
      release_lock(lock_holder)
    end
  end

  defp dist_opts(ctx), do: [topology: ctx.topology, transport: InProcess]

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

  defp free_space_provider(prefix_free_bytes) do
    fn drive ->
      normalized = String.replace(drive, "\\", "/")

      free_bytes =
        Enum.find_value(prefix_free_bytes, 1_000, fn {fragment, free} ->
          if String.contains?(normalized, fragment), do: free
        end)

      {:ok,
       %{
         mount_root: drive,
         capacity_bytes: 10_000,
         free_bytes: free_bytes,
         source: :test,
         precision: :exact
       }}
    end
  end

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
