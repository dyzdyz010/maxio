defmodule Mix.Tasks.Maxio.ScanTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Maxio.Scan
  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.Scrubber.Usage

  @owner "arn:aws:iam:::root"

  setup do
    Usage.clear()

    on_exit(fn ->
      Usage.clear()
      Mix.Task.reenable("maxio.scan")
    end)
  end

  test "prints a one-shot scan summary" do
    bucket = bucket_name()
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, "cli.txt", "null", %{
        size: 7,
        etag: "etag-cli",
        content_type: "text/plain"
      })

    Mix.Task.reenable("maxio.scan")

    output =
      capture_io(fn ->
        Scan.run(["--bucket", bucket, "--no-throttle"])
      end)

    assert output =~ "[maxio scan] status=ok"
    assert output =~ "buckets=1"
    assert output =~ "scanned=1"
    assert output =~ "sampled_out=0"
    assert output =~ "index_status=not_run"
    assert output =~ "index_upserted=0"
    assert output =~ "index_orphan_shards=0"
    assert output =~ "index_orphan_bytes=0"
    assert output =~ "index_orphan_cleaned=0"
    assert output =~ "index_orphan_cleaned_bytes=0"
    assert output =~ "objects=1"
    assert output =~ "bytes=7"
  end

  test "reports reconcile pre-pass refusal without forcing disk authority" do
    bucket = bucket_name()
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, "pg.txt", "null", %{
        size: 3,
        etag: "etag-pg",
        content_type: "text/plain"
      })

    Mix.Task.reenable("maxio.scan")

    output =
      capture_io(fn ->
        Scan.run(["--bucket", bucket, "--no-throttle", "--reconcile-index"])
      end)

    assert output =~ "[maxio scan] status=ok"
    assert output =~ "scanned=1"
    assert output =~ "index_status=authority_mismatch"
    assert output =~ "index_upserted=0"
    assert output =~ "index_orphan_shards=0"
    assert output =~ "index_orphan_cleaned=0"
    assert output =~ "objects=1"
  end

  test "accepts token-bucket throttle flags" do
    bucket = bucket_name()
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, "rate.txt", "null", %{
        size: 5,
        etag: "etag-rate",
        content_type: "text/plain"
      })

    Mix.Task.reenable("maxio.scan")

    output =
      capture_io(fn ->
        Scan.run([
          "--bucket",
          bucket,
          "--max-objects-per-sec",
          "10",
          "--object-burst",
          "3",
          "--sleep-between-batches-ms",
          "0"
        ])
      end)

    assert output =~ "[maxio scan] status=ok"
    assert output =~ "buckets=1"
    assert output =~ "scanned=1"
    assert output =~ "objects=1"
    assert output =~ "bytes=5"
  end

  test "prints orphan shard evidence from reconcile pre-pass" do
    bucket = bucket_name()
    dir = Path.join(System.tmp_dir!(), "maxio_scan_orphan_#{System.unique_integer([:positive])}")
    File.rm_rf(dir)
    File.mkdir_p!(dir)

    prev_backend = Application.get_env(:maxio, :storage_backend)
    prev_s3 = Application.get_env(:maxio, :s3)
    topo_key = {Maxio.Cluster.Topology, :topology}
    prev_topo = :persistent_term.get(topo_key, :__maxio_no_topology__)

    Application.put_env(:maxio, :storage_backend, Maxio.Storage.FS)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, dir))
    :persistent_term.erase(topo_key)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, prev_backend)
      Application.put_env(:maxio, :s3, prev_s3)
      restore_topology(prev_topo)
      File.rm_rf(dir)
    end)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Maxio.Storage.FS.put_bucket(bucket, data_dir: dir)
    orphan = write_orphan_part!(dir, bucket, "scan-orphan.txt", "scan-stale")

    Mix.Task.reenable("maxio.scan")

    output =
      capture_io(fn ->
        Scan.run([
          "--bucket",
          bucket,
          "--no-throttle",
          "--reconcile-index",
          "--force-reconcile-index"
        ])
      end)

    assert output =~ "index_status=ok"
    assert output =~ "index_orphan_shards=1"
    assert output =~ "index_orphan_bytes=#{byte_size("scan-stale")}"
    assert output =~ "index_orphan_cleaned=0"
    assert output =~ "index_orphan_cleaned_bytes=0"
    assert File.read!(orphan) == "scan-stale"
  end

  test "passes orphan cleanup flags through reconcile pre-pass" do
    bucket = bucket_name()
    dir = Path.join(System.tmp_dir!(), "maxio_scan_cleanup_#{System.unique_integer([:positive])}")
    File.rm_rf(dir)
    File.mkdir_p!(dir)

    prev_backend = Application.get_env(:maxio, :storage_backend)
    prev_s3 = Application.get_env(:maxio, :s3)
    prev_auth = Application.get_env(:maxio, :authoritative_source)
    topo_key = {Maxio.Cluster.Topology, :topology}
    prev_topo = :persistent_term.get(topo_key, :__maxio_no_topology__)

    Application.put_env(:maxio, :storage_backend, Maxio.Storage.FS)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, dir))
    Application.put_env(:maxio, :authoritative_source, read: :pg, list: :pg, write: :sidecar)
    :persistent_term.erase(topo_key)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, prev_backend)
      Application.put_env(:maxio, :s3, prev_s3)
      Application.put_env(:maxio, :authoritative_source, prev_auth)
      restore_topology(prev_topo)
      File.rm_rf(dir)
    end)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Maxio.Storage.FS.put_bucket(bucket, data_dir: dir)
    orphan = write_orphan_part!(dir, bucket, "scan-cleanup.txt", "scan-cleanup")

    Mix.Task.reenable("maxio.scan")

    output =
      capture_io(fn ->
        Scan.run([
          "--bucket",
          bucket,
          "--no-throttle",
          "--reconcile-index",
          "--cleanup-orphan-shards",
          "--orphan-cleanup-min-age-ms",
          "0"
        ])
      end)

    assert output =~ "index_status=ok"
    assert output =~ "index_orphan_shards=1"
    assert output =~ "index_orphan_bytes=#{byte_size("scan-cleanup")}"
    assert output =~ "index_orphan_cleaned=1"
    assert output =~ "index_orphan_cleaned_bytes=#{byte_size("scan-cleanup")}"
    refute File.exists?(orphan)
  end

  defp bucket_name do
    "scan-cli-#{System.unique_integer([:positive])}"
  end

  defp write_orphan_part!(dir, bucket, key, body) do
    {:ok, rel} = Maxio.Cluster.Paths.object_rel(bucket, key, "null")
    obj_dir = Path.join(dir, rel)
    File.mkdir_p!(obj_dir)
    part = Path.join(obj_dir, "part.0")
    File.write!(part, body)
    part
  end

  defp restore_topology(:__maxio_no_topology__),
    do: :persistent_term.erase({Maxio.Cluster.Topology, :topology})

  defp restore_topology(topo),
    do: :persistent_term.put({Maxio.Cluster.Topology, :topology}, topo)
end
