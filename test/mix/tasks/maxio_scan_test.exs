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
    assert output =~ "gate_status=ok"
    assert output =~ "buckets=1"
    assert output =~ "scanned=1"
    assert output =~ "sampled_out=0"
    assert output =~ "index_status=not_run"
    assert output =~ "index_upserted=0"
    assert output =~ "index_orphan_shards=0"
    assert output =~ "index_orphan_bytes=0"
    assert output =~ "index_orphan_cleaned=0"
    assert output =~ "index_orphan_cleaned_bytes=0"
    assert output =~ "drive_sets=0"
    assert output =~ "drive_offline=0"
    assert output =~ "drive_heal_required=0"
    assert output =~ "drive_identity_replacements=0"
    assert output =~ "drive_identity_heal_required=0"
    assert output =~ "drive_identity_errors=0"
    assert output =~ "objects=1"
    assert output =~ "bytes=7"
    assert output =~ "blockers=0"
    assert output =~ "warnings=0"
  end

  test "json output exposes machine-readable ok evidence" do
    bucket = bucket_name()
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, "json-ok.txt", "null", %{
        size: 11,
        etag: "etag-json-ok",
        content_type: "text/plain"
      })

    Mix.Task.reenable("maxio.scan")

    output =
      capture_io(fn ->
        Scan.run(["--bucket", bucket, "--no-throttle", "--json"])
      end)

    report = Jason.decode!(String.trim(output))

    assert report["status"] == "ok"
    assert report["gate_status"] == "ok"
    assert report["buckets"] == 1
    assert report["scanned"] == 1
    assert report["damaged"] == 0
    assert report["index_status"] == "not_run"
    assert report["drive_offline"] == 0
    assert report["object_count"] == 1
    assert report["total_size"] == 11
    assert report["blockers"] == []
    assert report["warnings"] == []
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
    assert output =~ "gate_status=blocked"
    assert output =~ "scanned=1"
    assert output =~ "index_status=authority_mismatch"
    assert output =~ "blockers=1"
    assert output =~ "[maxio scan.blocker] reason=index_authority_mismatch"
    assert output =~ "index_upserted=0"
    assert output =~ "index_orphan_shards=0"
    assert output =~ "index_orphan_cleaned=0"
    assert output =~ "objects=1"
  end

  test "fail-on-blocked raises after emitting authority mismatch json evidence" do
    bucket = bucket_name()
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, "blocked.txt", "null", %{
        size: 4,
        etag: "etag-blocked",
        content_type: "text/plain"
      })

    Mix.Task.reenable("maxio.scan")

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/scan blocked/, fn ->
          Scan.run([
            "--bucket",
            bucket,
            "--no-throttle",
            "--reconcile-index",
            "--json",
            "--fail-on-blocked"
          ])
        end
      end)

    report = Jason.decode!(String.trim(output))

    assert report["status"] == "ok"
    assert report["gate_status"] == "blocked"
    assert report["index_status"] == "authority_mismatch"
    assert report["blockers"] == ["index_authority_mismatch"]
    assert report["warnings"] == []
    assert report["scanned"] == 1
    assert report["object_count"] == 1
  end

  test "fail-on-attention also raises for blocked authority mismatch" do
    bucket = bucket_name()
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, "blocked-attention.txt", "null", %{
        size: 8,
        etag: "etag-blocked-attention",
        content_type: "text/plain"
      })

    Mix.Task.reenable("maxio.scan")

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/scan blocked/, fn ->
          Scan.run([
            "--bucket",
            bucket,
            "--no-throttle",
            "--reconcile-index",
            "--json",
            "--fail-on-attention"
          ])
        end
      end)

    report = Jason.decode!(String.trim(output))

    assert report["gate_status"] == "blocked"
    assert report["index_status"] == "authority_mismatch"
    assert report["blockers"] == ["index_authority_mismatch"]
    assert report["warnings"] == []
  end

  test "fail-on-blocked raises when scrubber reports a partial bucket scan" do
    bucket = bucket_name()
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, "partial-a.txt", "null", %{
        size: 4,
        etag: "etag-partial-a",
        content_type: "text/plain"
      })

    {:ok, _object} =
      Objects.put_version_with_id(bucket, "partial-b.txt", "null", %{
        size: 5,
        etag: "etag-partial-b",
        content_type: "text/plain"
      })

    prev_scrubber = Application.get_env(:maxio, :scrubber, [])

    Application.put_env(
      :maxio,
      :scrubber,
      Keyword.merge(prev_scrubber,
        max_objects_per_sec: 1,
        object_burst: 1,
        throttle_now_fun: fn -> 0 end,
        throttle_sleep_fun: fn _ms -> raise "injected maxio.scan throttle failure" end
      )
    )

    on_exit(fn ->
      Application.put_env(:maxio, :scrubber, prev_scrubber)
    end)

    Mix.Task.reenable("maxio.scan")

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/scan blocked/, fn ->
          Scan.run(["--bucket", bucket, "--json", "--fail-on-blocked"])
        end
      end)

    report = Jason.decode!(String.trim(output))

    assert report["status"] == "partial"
    assert report["gate_status"] == "blocked"
    assert report["blockers"] == ["scan_status_partial"]
    assert report["warnings"] == []
    assert report["object_count"] == 0
    assert report["total_size"] == 0
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
          "0",
          "--no-adaptive-io",
          "--io-load-source",
          "cluster-drive-device-io",
          "--max-live-requests",
          "2",
          "--io-pause-ms",
          "10",
          "--io-max-pause-ms",
          "25",
          "--drive-offline-after-ms",
          "0"
        ])
      end)

    assert output =~ "[maxio scan] status=ok"
    assert output =~ "buckets=1"
    assert output =~ "scanned=1"
    assert output =~ "drive_offline=0"
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
    assert output =~ "gate_status=attention"
    assert output =~ "index_orphan_shards=1"
    assert output =~ "[maxio scan.warning] reason=index_orphan_shards_detected"
    assert output =~ "index_orphan_bytes=#{byte_size("scan-stale")}"
    assert output =~ "index_orphan_cleaned=0"
    assert output =~ "index_orphan_cleaned_bytes=0"
    assert File.read!(orphan) == "scan-stale"
  end

  test "fail-on-attention raises after emitting orphan shard json evidence" do
    bucket = bucket_name()

    dir =
      Path.join(System.tmp_dir!(), "maxio_scan_attention_#{System.unique_integer([:positive])}")

    setup_fs_scan_env!(dir)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Maxio.Storage.FS.put_bucket(bucket, data_dir: dir)
    orphan = write_orphan_part!(dir, bucket, "scan-attention.txt", "attention-stale")

    Mix.Task.reenable("maxio.scan")

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/scan attention/, fn ->
          Scan.run([
            "--bucket",
            bucket,
            "--no-throttle",
            "--reconcile-index",
            "--force-reconcile-index",
            "--json",
            "--fail-on-attention"
          ])
        end
      end)

    report = Jason.decode!(String.trim(output))

    assert report["status"] == "ok"
    assert report["gate_status"] == "attention"
    assert report["index_status"] == "ok"
    assert report["index_orphan_shards"] == 1
    assert report["index_orphan_bytes"] == byte_size("attention-stale")
    assert report["blockers"] == []
    assert "index_orphan_shards_detected" in report["warnings"]
    assert File.read!(orphan) == "attention-stale"
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

  defp setup_fs_scan_env!(dir, write_authority \\ :sidecar) do
    File.rm_rf(dir)
    File.mkdir_p!(dir)

    prev_backend = Application.get_env(:maxio, :storage_backend)
    prev_s3 = Application.get_env(:maxio, :s3)
    prev_auth = Application.get_env(:maxio, :authoritative_source)
    topo_key = {Maxio.Cluster.Topology, :topology}
    prev_topo = :persistent_term.get(topo_key, :__maxio_no_topology__)

    Application.put_env(:maxio, :storage_backend, Maxio.Storage.FS)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, dir))

    Application.put_env(:maxio, :authoritative_source,
      read: :pg,
      list: :pg,
      write: write_authority
    )

    :persistent_term.erase(topo_key)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, prev_backend)
      Application.put_env(:maxio, :s3, prev_s3)
      Application.put_env(:maxio, :authoritative_source, prev_auth)
      restore_topology(prev_topo)
      File.rm_rf(dir)
    end)
  end

  defp restore_topology(:__maxio_no_topology__),
    do: :persistent_term.erase({Maxio.Cluster.Topology, :topology})

  defp restore_topology(topo),
    do: :persistent_term.put({Maxio.Cluster.Topology, :topology}, topo)
end
