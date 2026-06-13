defmodule Maxio.Cluster.RebalanceWriteRoutingTest do
  use Maxio.DataCase, async: false

  import Ecto.Query

  alias Maxio.Cluster.{
    Placement,
    Rebalance.Job,
    Rebalance.WriteRouting,
    Router,
    Topology,
    Transport.InProcess
  }

  alias Maxio.{BucketConfigs, Buckets, Multipart, Objects, Repo, Storage}
  alias Maxio.Cluster.Paths
  alias Maxio.Objects.Object
  alias Maxio.Storage.Distributed

  @owner "arn:aws:iam:::root"
  @now ~U[2026-06-11 00:00:00Z]
  @old DateTime.add(@now, -3 * 86_400, :second)

  setup do
    InProcess.setup!()
    previous_backend = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Distributed)

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_write_routing_#{System.unique_integer([:positive])}"
      )

    topology = topology(base, 3)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous_backend)
      File.rm_rf(base)
    end)

    {:ok, topology: topology}
  end

  test "active_routes includes only decommission states that should freeze writes" do
    insert_route!(0, 1, status: "running", data_movement_status: "moving")
    insert_route!(2, 1, status: "complete", data_movement_status: "complete")

    insert_route!(3, 1,
      status: "failed",
      data_movement_status: "complete",
      source_cleanup_status: "failed"
    )

    insert_route!(4, 1,
      status: "complete",
      data_movement_status: "complete",
      source_cleanup_status: "skipped"
    )

    insert_route!(5, 1, status: "canceled", data_movement_status: "complete")
    insert_route!(6, 1, status: "failed", data_movement_status: "failed")

    assert {:ok, routes} = WriteRouting.active_routes()
    assert routes[0] == 1
    assert routes[2] == 1
    assert routes[3] == 1
    refute Map.has_key?(routes, 4)
    refute Map.has_key?(routes, 5)
    refute Map.has_key?(routes, 6)
  end

  test "paused data movement keeps target excluded" do
    insert_route!(0, 1, status: "running", data_movement_status: "paused")

    assert {:ok, routes} = WriteRouting.active_routes()
    assert routes[0] == 1
  end

  test "Distributed.put reroutes ordinary writes while explicit placement remains authoritative",
       %{
         topology: topology
       } do
    insert_route!(0, 1, status: "running", data_movement_status: "moving")

    bucket = bucket_name("write-freeze")
    key = key_for_set(bucket, topology, 0, "ordinary")
    body = "new-write-after-decommission"
    opts = dist_opts(topology)

    assert {:ok, result} = Distributed.put(bucket, key, "null", [body], opts)
    assert result.placement_set_id == 1

    assert {:ok, destination_stream} =
             Distributed.get(bucket, key, "null", nil, Keyword.put(opts, :placement_set_id, 1))

    assert IO.iodata_to_binary(Enum.to_list(destination_stream)) == body

    assert {:error, :enoent} =
             Distributed.get(bucket, key, "null", nil, Keyword.put(opts, :placement_set_id, 0))

    override_key = key_for_set(bucket, topology, 0, "override")

    assert {:ok, override_result} =
             Distributed.put(
               bucket,
               override_key,
               "null",
               ["explicit-source-write"],
               Keyword.put(opts, :placement_set_id, 0)
             )

    assert override_result.placement_set_id == 0
  end

  test "MPU persists temporary part placement and writes final object by object key", %{
    topology: topology
  } do
    insert_route!(0, 1, status: "running", data_movement_status: "moving")

    bucket = bucket_name("write-freeze-mpu")
    key = key_for_set(bucket, topology, 2, "final")
    opts = dist_opts(topology)
    upload = upload_for_raw_set(bucket, key, topology, 0, opts)
    body = "multipart part body"

    assert upload.placement_set_id == 1

    assert {:ok, part_result} =
             Storage.put_part(
               bucket,
               key,
               upload.upload_id,
               1,
               [body],
               opts ++ Placement.upload_storage_opts(upload)
             )

    assert {:ok, _part} =
             Multipart.put_part(upload, 1, %{etag: part_result.etag, size: part_result.size})

    assert {:ok, part_stream} =
             Distributed.get_part_stream(
               bucket,
               key,
               upload.upload_id,
               1,
               opts ++ Placement.upload_storage_opts(upload)
             )

    assert IO.iodata_to_binary(Enum.to_list(part_stream)) == body

    assert {:ok, complete} =
             Multipart.complete(
               upload,
               [%{part_number: 1, etag: part_result.etag}],
               [min_part_size: 1] ++ opts
             )

    assert complete.placement_set_id == 2

    assert {:ok, object_stream} =
             Distributed.get(
               bucket,
               key,
               complete.version_id,
               nil,
               Keyword.put(opts, :placement_set_id, 2)
             )

    assert IO.iodata_to_binary(Enum.to_list(object_stream)) == body

    assert {:error, :enoent} =
             Distributed.get(
               bucket,
               key,
               complete.version_id,
               nil,
               Keyword.put(opts, :placement_set_id, 1)
             )

    assert :ok = Multipart.abort(upload, opts)

    assert {:error, :enoent} =
             Distributed.get_part_stream(
               bucket,
               key,
               upload.upload_id,
               1,
               opts ++ Placement.upload_storage_opts(upload)
             )
  end

  test "lifecycle expiration writes delete marker with injected write-routing opts", %{
    topology: topology
  } do
    insert_route!(0, 1, status: "running", data_movement_status: "moving")

    bucket = bucket_name("write-freeze-lifecycle")
    key = key_for_set(bucket, topology, 0, "expire")
    opts = dist_opts(topology)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Buckets.put_versioning(bucket, "Enabled", nil)
    :ok = Distributed.put_bucket(bucket, opts)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "v1", %{
        size: 1,
        etag: "e1",
        placement_set_id: 0
      })

    touch_object(bucket, key, "v1", @old)

    :ok =
      BucketConfigs.put(bucket, :lifecycle, [
        rule(%{"filter_prefix" => "", "expiration_days" => 1})
      ])

    summary = Maxio.Lifecycle.run([now: @now] ++ opts)

    assert summary.objects_expired == 1
    assert summary.errors == []

    {:ok, marker} = Objects.get_metadata(bucket, key)
    assert marker.is_delete_marker
    assert marker.placement_set_id == 1
    assert delete_marker_sidecar?(topology, key, bucket, marker.version_id, 1)
    refute delete_marker_sidecar?(topology, key, bucket, marker.version_id, 0)
  end

  test "lifecycle aborts incomplete MPU with injected upload placement opts", %{
    topology: topology
  } do
    insert_route!(0, 1, status: "running", data_movement_status: "moving")

    bucket = bucket_name("write-freeze-lifecycle-mpu")
    key = key_for_set(bucket, topology, 2, "mpu")
    opts = dist_opts(topology)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    upload = upload_for_raw_set(bucket, key, topology, 0, opts)
    touch_upload(upload.upload_id, @old)

    assert {:ok, part_result} =
             Storage.put_part(
               bucket,
               key,
               upload.upload_id,
               1,
               ["old multipart bytes"],
               opts ++ Placement.upload_storage_opts(upload)
             )

    assert {:ok, _part} =
             Multipart.put_part(upload, 1, %{etag: part_result.etag, size: part_result.size})

    :ok =
      BucketConfigs.put(bucket, :lifecycle, [
        rule(%{"filter_prefix" => "mpu", "abort_days_after_initiation" => 1})
      ])

    summary = Maxio.Lifecycle.run([now: @now] ++ opts)

    assert summary.multipart_uploads_aborted == 1
    assert summary.errors == []
    assert {:error, :not_found} = Multipart.get_upload(bucket, key, upload.upload_id)

    assert {:error, :enoent} =
             Distributed.get_part_stream(
               bucket,
               key,
               upload.upload_id,
               1,
               opts ++ Placement.upload_storage_opts(upload)
             )
  end

  defp insert_route!(target, destination, attrs) do
    base = %{
      kind: "decommission",
      status: Keyword.fetch!(attrs, :status),
      data_movement_status: Keyword.fetch!(attrs, :data_movement_status),
      target_set_id: target,
      destination_set_id: destination,
      source_cleanup_status: Keyword.get(attrs, :source_cleanup_status, "not_started"),
      current_only: false,
      include_drive_stats: false,
      page_size: 500,
      plan_status: "ok",
      plan: %{},
      plan_scanned: 0,
      plan_bytes: 0,
      plan_placement_fallbacks: 0,
      progress_scanned: 0,
      progress_moved: 0,
      progress_skipped: 0,
      progress_errors: 0,
      source_cleanup_scanned: 0,
      source_cleanup_deleted: 0,
      source_cleanup_skipped: 0,
      source_cleanup_errors: 0,
      started_at: DateTime.utc_now()
    }

    %Job{} |> Job.changeset(base) |> Repo.insert!()
  end

  defp topology(base, set_count) do
    sets =
      for set_id <- 0..(set_count - 1) do
        endpoints =
          for drive <- 0..1 do
            {:"wr#{set_id}_#{drive}", Path.join(base, "s#{set_id}d#{drive}")}
          end

        %{id: set_id, endpoints: endpoints}
      end

    Topology.parse_and_validate!(
      data_shards: 1,
      parity_shards: 1,
      block_size: 1024,
      allow_colocated_endpoints: true,
      pools: [%{id: 0, sets: sets}]
    )
  end

  defp upload_for_raw_set(bucket, key, topology, set_id, opts) do
    Enum.find_value(1..100, fn _attempt ->
      {:ok, upload} = Multipart.initiate(bucket, key, %{}, opts)
      raw_set = Router.set_for(bucket, ".uploads/" <> upload.upload_id, topology)

      if raw_set == set_id, do: upload
    end) || flunk("could not create upload routed to set #{inspect(set_id)}")
  end

  defp dist_opts(topology), do: [topology: topology, transport: InProcess]

  defp rule(overrides), do: Map.merge(%{"id" => "rule", "status" => "Enabled"}, overrides)

  defp touch_object(bucket, key, version_id, at) do
    Repo.update_all(
      from(o in Object,
        where: o.bucket_name == ^bucket and o.key == ^key and o.version_id == ^version_id
      ),
      set: [inserted_at: at, updated_at: at]
    )
  end

  defp touch_upload(upload_id, at) do
    Repo.update_all(
      from(u in Maxio.Multipart.Upload, where: u.upload_id == ^upload_id),
      set: [inserted_at: at, updated_at: at]
    )
  end

  defp delete_marker_sidecar?(topology, key, bucket, version_id, set_id) do
    {:ok, rel} = Paths.object_rel(bucket, key, version_id)
    {node, drive} = topology |> Topology.endpoints_from(set_id) |> hd()

    case InProcess.get_sidecar(node, Path.join(drive, rel)) do
      {:ok, %{"versions" => [%{"type" => "delete_marker", "version_id" => ^version_id}]}} ->
        true

      _ ->
        false
    end
  end

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
end
