defmodule Mix.Tasks.Maxio.ReconcileIndexTest do
  @moduledoc """
  ROUTE B B6-2 —— CLI wrapper coverage for FS local-topology reconcile.

  The scanner unit tests cover `Scanner.run_once/1` directly; this test locks the
  user-facing `mix maxio.reconcile_index --dry-run` path so option parsing and
  Mix task startup still reach FS local topology instead of reporting no topology.
  """
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Maxio.ReconcileIndex
  alias Maxio.{Buckets, Objects}

  @bucket "mixb62fs"
  @owner "arn:aws:iam:::root"

  test "FS backend with no global topology runs dry-run through local_topology instead of no_topology" do
    dir =
      Path.join(System.tmp_dir!(), "maxio_mix_reconcile_#{System.unique_integer([:positive])}")

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
      Mix.Task.reenable("maxio.reconcile_index")
      File.rm_rf(dir)
    end)

    {:ok, _bucket} = Buckets.create(@bucket, @owner)
    :ok = Maxio.Storage.FS.put_bucket(@bucket, data_dir: dir)
    _etag = fs_put_missing_row!(dir, "cli-missing", "cli dry-run body")
    assert {:error, :not_found} = Objects.get_version(@bucket, "cli-missing", "null")

    Mix.Task.reenable("maxio.reconcile_index")

    output =
      capture_io(fn ->
        ReconcileIndex.run(["--dry-run", "--bucket", @bucket])
      end)

    assert output =~ "status=ok"
    assert output =~ "dry_run=true"
    assert output =~ "buckets=1"
    assert output =~ "scanned=1"
    assert output =~ "upserted=1"
    assert output =~ "notification_replayed=0"
    assert output =~ "notification_replay_failed=0"
    assert output =~ "orphan_shards=0"
    assert output =~ "orphan_bytes=0"
    assert output =~ "orphan_cleaned=0"
    assert output =~ "orphan_cleaned_bytes=0"
    refute output =~ "status=no_topology"
    refute output =~ "no distributed topology configured"

    # Dry-run reports what would be reconciled but must not write the derived index row.
    assert {:error, :not_found} = Objects.get_version(@bucket, "cli-missing", "null")
  end

  test "prints nonzero orphan shard evidence without deleting bytes" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_mix_reconcile_orphan_#{System.unique_integer([:positive])}"
      )

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
      Mix.Task.reenable("maxio.reconcile_index")
      File.rm_rf(dir)
    end)

    {:ok, _bucket} = Buckets.create(@bucket, @owner)
    :ok = Maxio.Storage.FS.put_bucket(@bucket, data_dir: dir)
    orphan = write_orphan_part!(dir, "cli-orphan", "stale-cli")

    Mix.Task.reenable("maxio.reconcile_index")

    output =
      capture_io(fn ->
        ReconcileIndex.run(["--dry-run", "--bucket", @bucket])
      end)

    assert output =~ "status=ok"
    assert output =~ "orphan_shards=1"
    assert output =~ "orphan_bytes=#{byte_size("stale-cli")}"
    assert output =~ "orphan_cleaned=0"
    assert output =~ "orphan_cleaned_bytes=0"
    assert File.read!(orphan) == "stale-cli"
  end

  test "json output exposes machine-readable attention evidence for dry-run drift" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_mix_reconcile_json_#{System.unique_integer([:positive])}"
      )

    setup_fs_reconcile_env!(dir)

    {:ok, _bucket} = Buckets.create(@bucket, @owner)
    :ok = Maxio.Storage.FS.put_bucket(@bucket, data_dir: dir)
    _etag = fs_put_missing_row!(dir, "cli-json-missing", "cli json dry-run body")
    assert {:error, :not_found} = Objects.get_version(@bucket, "cli-json-missing", "null")

    Mix.Task.reenable("maxio.reconcile_index")

    output =
      capture_io(fn ->
        ReconcileIndex.run(["--dry-run", "--bucket", @bucket, "--json"])
      end)

    report = Jason.decode!(String.trim(output))

    assert report["status"] == "ok"
    assert report["gate_status"] == "attention"
    assert report["dry_run"] == true
    assert report["buckets"] == 1
    assert report["scanned"] == 1
    assert report["upserted"] == 1
    assert report["blockers"] == []
    assert "dry_run_would_reconcile" in report["warnings"]
    assert "derived_index_reconciled" in report["warnings"]

    assert {:error, :not_found} = Objects.get_version(@bucket, "cli-json-missing", "null")
  end

  test "fail-on-attention raises after emitting json evidence" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_mix_reconcile_json_attention_#{System.unique_integer([:positive])}"
      )

    setup_fs_reconcile_env!(dir)

    {:ok, _bucket} = Buckets.create(@bucket, @owner)
    :ok = Maxio.Storage.FS.put_bucket(@bucket, data_dir: dir)
    _etag = fs_put_missing_row!(dir, "cli-attention-missing", "attention body")

    Mix.Task.reenable("maxio.reconcile_index")

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/reconcile_index attention/, fn ->
          ReconcileIndex.run([
            "--dry-run",
            "--bucket",
            @bucket,
            "--json",
            "--fail-on-attention"
          ])
        end
      end)

    report = Jason.decode!(String.trim(output))

    assert report["status"] == "ok"
    assert report["gate_status"] == "attention"
    assert report["blockers"] == []
    assert "dry_run_would_reconcile" in report["warnings"]
  end

  test "fail-on-blocked raises after emitting authority mismatch json evidence" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_mix_reconcile_json_blocked_#{System.unique_integer([:positive])}"
      )

    setup_fs_reconcile_env!(dir, :pg)

    Mix.Task.reenable("maxio.reconcile_index")

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/reconcile_index blocked/, fn ->
          ReconcileIndex.run(["--json", "--fail-on-blocked"])
        end
      end)

    report = Jason.decode!(String.trim(output))

    assert report["status"] == "authority_mismatch"
    assert report["gate_status"] == "blocked"
    assert report["blockers"] == ["authority_mismatch"]
    assert report["warnings"] == []
    assert report["scanned"] == 0
    assert report["upserted"] == 0
    assert report["gc"] == 0
  end

  test "fail-on-attention also raises for blocked authority mismatch" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_mix_reconcile_json_blocked_attention_#{System.unique_integer([:positive])}"
      )

    setup_fs_reconcile_env!(dir, :pg)

    Mix.Task.reenable("maxio.reconcile_index")

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/reconcile_index blocked/, fn ->
          ReconcileIndex.run(["--json", "--fail-on-attention"])
        end
      end)

    report = Jason.decode!(String.trim(output))

    assert report["status"] == "authority_mismatch"
    assert report["gate_status"] == "blocked"
    assert report["blockers"] == ["authority_mismatch"]
    assert report["warnings"] == []
  end

  test "cleanup flag deletes an eligible orphan part.0 through the CLI" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_mix_reconcile_cleanup_#{System.unique_integer([:positive])}"
      )

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
      Mix.Task.reenable("maxio.reconcile_index")
      File.rm_rf(dir)
    end)

    {:ok, _bucket} = Buckets.create(@bucket, @owner)
    :ok = Maxio.Storage.FS.put_bucket(@bucket, data_dir: dir)
    orphan = write_orphan_part!(dir, "cli-cleanup-orphan", "cleanup-cli")

    Mix.Task.reenable("maxio.reconcile_index")

    output =
      capture_io(fn ->
        ReconcileIndex.run([
          "--bucket",
          @bucket,
          "--cleanup-orphan-shards",
          "--orphan-cleanup-min-age-ms",
          "0"
        ])
      end)

    assert output =~ "status=ok"
    assert output =~ "orphan_shards=1"
    assert output =~ "orphan_bytes=#{byte_size("cleanup-cli")}"
    assert output =~ "orphan_cleaned=1"
    assert output =~ "orphan_cleaned_bytes=#{byte_size("cleanup-cli")}"
    refute File.exists?(orphan)
  end

  defp setup_fs_reconcile_env!(dir, write_authority \\ :sidecar) do
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
      Mix.Task.reenable("maxio.reconcile_index")
      File.rm_rf(dir)
    end)
  end

  defp fs_put_missing_row!(dir, key, body) do
    om = %{
      content_type: "text/plain",
      tags: %{},
      sse: nil,
      acl_canned: "private",
      storage_class: "STANDARD",
      user_metadata: %{"source" => "mix-task"}
    }

    {:ok, %{etag: etag}} =
      Maxio.Storage.FS.put(@bucket, key, "null", [body],
        data_dir: dir,
        object_meta: om
      )

    etag
  end

  defp write_orphan_part!(dir, key, body) do
    {:ok, rel} = Maxio.Cluster.Paths.object_rel(@bucket, key, "null")
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
