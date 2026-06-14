defmodule Maxio.Cluster.FreshDriveHealTest do
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects}

  alias Maxio.Cluster.{
    DriveHealth,
    DriveIdentity,
    FreshDriveHeal,
    Paths,
    Placement,
    Router,
    Topology,
    Transport.InProcess
  }

  alias Maxio.Storage.Distributed

  @owner "arn:aws:iam:::root"

  setup do
    InProcess.setup!()
    DriveHealth.reset()

    base =
      Path.join(System.tmp_dir!(), "maxio_fresh_drive_heal_#{System.unique_integer([:positive])}")

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

  test "recovered drive has missing object shard restored before marker clears", ctx do
    bucket = bucket_name("fresh-object")
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
    assert {:ok, first_identity} = DriveIdentity.status({node, drive})

    File.rm!(DriveIdentity.marker_path(drive))
    assert %{heal_required: 1, identity_heal_required: 1} = probe(ctx, 2)
    assert {:ok, replacement_identity} = DriveIdentity.status({node, drive})
    assert replacement_identity.previous_drive_uuid == first_identity.drive_uuid
    assert replacement_identity.identity_heal_required?

    assert {:ok, report} =
             FreshDriveHeal.run_once(
               topology: ctx.topology,
               transport: InProcess,
               page_size: 2
             )

    assert report.status == :ok
    assert report.drives_considered == 1
    assert report.drives_selected == 1
    assert report.drives_cleared == 1
    assert report.scanned == 1
    assert report.healed_objects == 1
    assert report.healed_shards > 0
    assert File.exists?(missing_part)
    refute DriveHealth.heal_required?({node, drive})
    refute DriveHealth.status({node, drive}).identity_heal_required?
    refute DriveHealth.status({node, drive}).identity_replacement_detected?
    assert {:ok, cleared_identity} = DriveIdentity.status({node, drive})
    refute cleared_identity.identity_heal_required?

    {:ok, stream} = Distributed.get(bucket, key, "null", nil, opts)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  test "fresh-drive heal uses persisted placement instead of current router" do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_fresh_drive_placement_#{System.unique_integer([:positive])}"
      )

    endpoints0 = for i <- 0..3, do: {Node.self(), Path.join(base, "s0d#{i}")}
    endpoints1 = for i <- 0..3, do: {Node.self(), Path.join(base, "s1d#{i}")}
    Enum.each(endpoints0 ++ endpoints1, fn {_node, drive} -> File.mkdir_p!(drive) end)

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

    try do
      bucket = bucket_name("fresh-placement")
      key = key_for_set(bucket, topology, 1, "routes-to-one")
      body = :crypto.strong_rand_bytes(1536)
      opts = [topology: topology, transport: InProcess]
      source_opts = Keyword.put(opts, :placement_set_id, 0)
      {node, drive} = hd(endpoints0)

      {:ok, _bucket} = Buckets.create(bucket, @owner)
      :ok = Distributed.put_bucket(bucket, opts)

      InProcess.set_drive_down(node, drive)
      assert %{offline: 1} = probe(%{topology: topology}, 0)

      {:ok, write_result} = Distributed.put(bucket, key, "null", [body], source_opts)

      put_index!(
        bucket,
        key,
        "null",
        write_result.size,
        write_result.etag,
        Placement.attrs_from_result(write_result)
      )

      missing_part = part_path(drive, bucket, key, "null")
      refute File.exists?(missing_part)

      InProcess.set_drive_up(node, drive)
      assert %{heal_required: 1} = probe(%{topology: topology}, 1)

      assert {:ok, report} =
               FreshDriveHeal.run_once(topology: topology, transport: InProcess)

      assert report.status == :ok
      assert report.scanned == 1
      assert report.drives_cleared == 1
      assert File.exists?(missing_part)
      refute DriveHealth.heal_required?({node, drive})

      {:ok, stream} = Distributed.get(bucket, key, "null", nil, source_opts)
      assert IO.iodata_to_binary(Enum.to_list(stream)) == body
    after
      DriveHealth.reset()
      File.rm_rf(base)
    end
  end

  test "dry-run reports targets without healing or clearing", ctx do
    {node, drive} = mark_one_drive_required!(ctx)

    assert {:ok, report} =
             FreshDriveHeal.run_once(
               topology: ctx.topology,
               transport: InProcess,
               dry_run: true
             )

    assert report.status == :dry_run
    assert report.drives_considered == 1
    assert report.drives_selected == 1
    assert report.drives_cleared == 0
    assert report.scanned == 0
    assert DriveHealth.heal_required?({node, drive})
  end

  test "current-only pass is partial scope and does not clear marker", ctx do
    {node, drive} = mark_one_drive_required!(ctx)

    assert {:ok, report} =
             FreshDriveHeal.run_once(
               topology: ctx.topology,
               transport: InProcess,
               scan_versions: false
             )

    assert report.status == :partial_scope
    assert report.drives_cleared == 0
    assert DriveHealth.heal_required?({node, drive})
  end

  test "max_objects partial pass heals but does not clear marker", ctx do
    bucket = bucket_name("fresh-partial")
    opts = dist_opts(ctx)
    {node, drive} = hd(ctx.endpoints)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    InProcess.set_drive_down(node, drive)
    assert %{offline: 1} = probe(ctx, 0)

    for key <- ["a.bin", "b.bin"] do
      body = :crypto.strong_rand_bytes(1536)
      {:ok, %{size: size, etag: etag}} = Distributed.put(bucket, key, "null", [body], opts)
      put_index!(bucket, key, "null", size, etag)
    end

    InProcess.set_drive_up(node, drive)
    assert %{heal_required: 1} = probe(ctx, 1)

    assert {:ok, report} =
             FreshDriveHeal.run_once(
               topology: ctx.topology,
               transport: InProcess,
               max_objects: 1
             )

    assert report.status == :partial
    assert report.truncated
    assert report.scanned == 1
    assert report.drives_cleared == 0
    assert DriveHealth.heal_required?({node, drive})
  end

  test "fresh-drive heal paces target objects with token bucket", ctx do
    parent = self()
    {node, drive} = seed_missing_objects!(ctx, "fresh-paced", ["a.bin", "b.bin"])

    assert {:ok, report} =
             FreshDriveHeal.run_once(
               topology: ctx.topology,
               transport: InProcess,
               max_objects_per_sec: 1,
               object_burst: 1,
               adaptive_io: false,
               throttle_now_fun: fn -> 0 end,
               throttle_sleep_fun: fn ms -> send(parent, {:fresh_drive_sleep, ms}) end
             )

    assert report.status == :ok
    assert report.scanned == 2
    assert report.drives_cleared == 1
    assert_receive {:fresh_drive_sleep, 1000}
    refute DriveHealth.heal_required?({node, drive})
  end

  test "no_throttle disables fresh-drive heal pacing", ctx do
    parent = self()
    {_node, _drive} = seed_missing_objects!(ctx, "fresh-no-throttle", ["a.bin", "b.bin"])

    assert {:ok, report} =
             FreshDriveHeal.run_once(
               topology: ctx.topology,
               transport: InProcess,
               no_throttle: true,
               max_objects_per_sec: 1,
               object_burst: 1,
               throttle_now_fun: fn -> 0 end,
               throttle_sleep_fun: fn ms -> send(parent, {:fresh_drive_sleep, ms}) end
             )

    assert report.status == :ok
    assert report.scanned == 2
    refute_receive {:fresh_drive_sleep, _}, 20
  end

  test "target shard write failure is verified before marker clear", ctx do
    bucket = bucket_name("fresh-shard-fail")
    key = "object.bin"
    opts = dist_opts(ctx)
    {node, drive} = hd(ctx.endpoints)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    InProcess.set_drive_down(node, drive)
    assert %{offline: 1} = probe(ctx, 0)

    body = :crypto.strong_rand_bytes(2048)
    {:ok, %{size: size, etag: etag}} = Distributed.put(bucket, key, "null", [body], opts)
    put_index!(bucket, key, "null", size, etag)
    missing_part = part_path(drive, bucket, key, "null")
    refute File.exists?(missing_part)

    InProcess.set_drive_up(node, drive)
    assert %{heal_required: 1} = probe(ctx, 1)
    InProcess.set_heal_shard_down(node, drive)

    assert {:ok, report} =
             FreshDriveHeal.run_once(topology: ctx.topology, transport: InProcess)

    assert report.status == :incomplete
    assert report.errors == 1
    assert report.drives_cleared == 0
    refute File.exists?(missing_part)
    assert DriveHealth.heal_required?({node, drive})
  end

  test "delete-marker sidecar write failure keeps marker set", ctx do
    bucket = bucket_name("fresh-marker-put-fail")
    key = "deleted.txt"
    version_id = "dm-put-fail"
    opts = dist_opts(ctx)
    {node, drive} = hd(ctx.endpoints)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    InProcess.set_drive_down(node, drive)
    assert %{offline: 1} = probe(ctx, 0)
    assert :ok = Distributed.put_delete_marker(bucket, key, version_id, [], opts)
    {:ok, _} = Objects.insert_delete_marker_with_id(bucket, key, version_id)

    marker_dir = object_dir(drive, bucket, key, version_id)
    refute File.exists?(Path.join(marker_dir, "meta.json"))

    InProcess.set_drive_up(node, drive)
    assert %{heal_required: 1} = probe(ctx, 1)
    InProcess.set_put_sidecar_down(node, drive)

    assert {:ok, report} =
             FreshDriveHeal.run_once(topology: ctx.topology, transport: InProcess)

    assert report.status == :incomplete
    assert report.errors == 1
    assert report.drives_cleared == 0
    refute File.exists?(Path.join(marker_dir, "meta.json"))
    assert DriveHealth.heal_required?({node, drive})
  end

  test "delete-marker part cleanup failure keeps marker set", ctx do
    bucket = bucket_name("fresh-marker-cleanup-fail")
    key = "deleted.txt"
    version_id = "dm-cleanup-fail"
    opts = dist_opts(ctx)
    {node, drive} = hd(ctx.endpoints)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    InProcess.set_drive_down(node, drive)
    assert %{offline: 1} = probe(ctx, 0)
    assert :ok = Distributed.put_delete_marker(bucket, key, version_id, [], opts)
    {:ok, _} = Objects.insert_delete_marker_with_id(bucket, key, version_id)

    marker_dir = object_dir(drive, bucket, key, version_id)
    File.mkdir_p!(marker_dir)
    File.write!(Path.join(marker_dir, "part.0"), "orphan")

    InProcess.set_drive_up(node, drive)
    assert %{heal_required: 1} = probe(ctx, 1)
    InProcess.set_delete_part_file_down(node, drive)

    assert {:ok, report} =
             FreshDriveHeal.run_once(topology: ctx.topology, transport: InProcess)

    assert report.status == :incomplete
    assert report.errors == 1
    assert report.drives_cleared == 0
    assert File.exists?(Path.join(marker_dir, "meta.json"))
    assert File.exists?(Path.join(marker_dir, "part.0"))
    assert DriveHealth.heal_required?({node, drive})
  end

  test "one marked drive per erasure set is processed per pass", ctx do
    [first, second | _] = ctx.endpoints
    Enum.each([first, second], fn {node, drive} -> InProcess.set_drive_down(node, drive) end)
    assert %{offline: 2, heal_required: 0} = probe(ctx, 0)
    Enum.each([first, second], fn {node, drive} -> InProcess.set_drive_up(node, drive) end)
    assert %{online: 6, heal_required: 2} = probe(ctx, 1)

    assert {:ok, report} =
             FreshDriveHeal.run_once(topology: ctx.topology, transport: InProcess)

    assert report.status == :ok
    assert report.drives_considered == 2
    assert report.drives_selected == 1
    assert report.drives_skipped_same_set == 1
    assert report.drives_cleared == 1
    assert Enum.count(DriveHealth.snapshot(), &Map.fetch!(&1, :heal_required?)) == 1
  end

  test "delete-marker sidecar is restored without creating part.0", ctx do
    bucket = bucket_name("fresh-marker")
    key = "deleted.txt"
    version_id = "dm-fresh-001"
    opts = dist_opts(ctx)
    {node, drive} = hd(ctx.endpoints)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    InProcess.set_drive_down(node, drive)
    assert %{offline: 1} = probe(ctx, 0)
    assert :ok = Distributed.put_delete_marker(bucket, key, version_id, [], opts)
    {:ok, _} = Objects.insert_delete_marker_with_id(bucket, key, version_id)

    marker_dir = object_dir(drive, bucket, key, version_id)
    refute File.exists?(Path.join(marker_dir, "meta.json"))

    InProcess.set_drive_up(node, drive)
    assert %{heal_required: 1} = probe(ctx, 1)

    assert {:ok, report} =
             FreshDriveHeal.run_once(topology: ctx.topology, transport: InProcess)

    assert report.status == :ok
    assert report.scanned == 1
    assert report.healed_objects == 1
    assert File.exists?(Path.join(marker_dir, "meta.json"))
    refute File.exists?(Path.join(marker_dir, "part.0"))
  end

  defp mark_one_drive_required!(ctx) do
    {node, drive} = hd(ctx.endpoints)
    InProcess.set_drive_down(node, drive)
    assert %{offline: 1, heal_required: 0} = probe(ctx, 0)
    InProcess.set_drive_up(node, drive)
    assert %{online: 6, heal_required: 1} = probe(ctx, 1)
    {node, drive}
  end

  defp seed_missing_objects!(ctx, prefix, keys) do
    bucket = bucket_name(prefix)
    opts = dist_opts(ctx)
    {node, drive} = hd(ctx.endpoints)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    InProcess.set_drive_down(node, drive)
    assert %{offline: 1, heal_required: 0} = probe(ctx, 0)

    Enum.each(keys, fn key ->
      body = :crypto.strong_rand_bytes(1536)
      {:ok, %{size: size, etag: etag}} = Distributed.put(bucket, key, "null", [body], opts)
      put_index!(bucket, key, "null", size, etag)
    end)

    InProcess.set_drive_up(node, drive)
    assert %{heal_required: 1} = probe(ctx, 1)
    {node, drive}
  end

  defp probe(ctx, now_ms) do
    DriveHealth.probe_topology(
      topology: ctx.topology,
      transport: InProcess,
      offline_after_ms: 0,
      now_ms: now_ms
    )
  end

  defp dist_opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  defp put_index!(bucket, key, version_id, size, etag, attrs \\ %{}) do
    {:ok, object} =
      Objects.put_version_with_id(
        bucket,
        key,
        version_id,
        %{
          size: size,
          etag: etag,
          content_type: "application/octet-stream"
        }
        |> Map.merge(attrs)
      )

    object
  end

  defp key_for_set(bucket, topology, set_id, prefix) do
    Enum.find_value(0..10_000, fn i ->
      key = "#{prefix}-#{set_id}-#{i}.bin"
      if Router.set_for(bucket, key, topology) == set_id, do: key
    end) || flunk("could not find key for set #{inspect(set_id)}")
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
