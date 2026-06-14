defmodule Maxio.Cluster.ShardServerTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias Maxio.Cluster.ShardServer

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_shardsrv_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "put_shard/get_shard round-trip（block 偏移寻址）", %{dir: dir} do
    obj = Path.join(dir, "b/k")
    s0 = :crypto.strong_rand_bytes(256)
    s1 = :crypto.strong_rand_bytes(256)
    :ok = ShardServer.put_shard(obj, 0, s0, 256)
    :ok = ShardServer.put_shard(obj, 1, s1, 256)
    assert ShardServer.get_shard(obj, 0, 256) == s0
    assert ShardServer.get_shard(obj, 1, 256) == s1
  end

  test "缺文件 / 缺块 / 短读 -> nil", %{dir: dir} do
    obj = Path.join(dir, "b/missing")
    assert ShardServer.get_shard(obj, 0, 256) == nil
    :ok = ShardServer.put_shard(obj, 0, :crypto.strong_rand_bytes(256), 256)
    # 块 5 从未写 -> 该偏移读不到 256 字节 -> nil
    assert ShardServer.get_shard(obj, 5, 256) == nil
  end

  test "sidecar put/get + stat + delete", %{dir: dir} do
    obj = Path.join(dir, "b/k2")
    meta = %{"size" => 3, "etag" => "x"}
    :ok = ShardServer.put_sidecar(obj, meta)
    assert {:ok, %{"size" => 3}} = ShardServer.get_sidecar(obj)
    :ok = ShardServer.put_shard(obj, 0, <<0::2048>>, 256)
    assert {:ok, 256} = ShardServer.stat_shard(obj)
    :ok = ShardServer.delete_shard(obj)
    assert {:error, :enoent} = ShardServer.get_sidecar(obj)
    assert {:error, :enoent} = ShardServer.stat_shard(obj)
  end

  test "heal_shard 回写指定块 + 重写 sidecar", %{dir: dir} do
    obj = Path.join(dir, "b/k3")
    good0 = :crypto.strong_rand_bytes(256)
    good1 = :crypto.strong_rand_bytes(256)

    :ok =
      ShardServer.put_shard(
        obj,
        0,
        <<bxor(0, 0)::8, :crypto.strong_rand_bytes(255)::binary>>,
        256
      )

    {:ok, 2} = ShardServer.heal_shard(obj, %{0 => good0, 1 => good1}, 256, %{"size" => 512})
    assert ShardServer.get_shard(obj, 0, 256) == good0
    assert ShardServer.get_shard(obj, 1, 256) == good1
    assert {:ok, %{"size" => 512}} = ShardServer.get_sidecar(obj)
  end

  test "quarantine_layout_roots moves only known layout roots and writes marker", %{dir: dir} do
    bucket_root = Path.join(dir, "bucket-a")
    version_root = Path.join([dir, ".versions", "bucket-a"])
    upload_root = Path.join([dir, ".uploads", "bucket-a", "upload-1"])

    File.mkdir_p!(Path.join(bucket_root, ".keep"))
    File.write!(Path.join([bucket_root, ".keep", "meta.json"]), "{}")
    File.mkdir_p!(version_root)
    File.mkdir_p!(upload_root)
    File.write!(Path.join(dir, "operator-note.txt"), "leave me")

    assert {:ok, result} =
             ShardServer.quarantine_layout_roots(dir, ["bucket-a"], "q-1", %{
               "job_id" => "job-1"
             })

    quarantine = Path.join([dir, ".maxio-removal-quarantine", "q-1"])
    refute File.exists?(bucket_root)
    refute File.exists?(Path.join(dir, ".versions"))
    refute File.exists?(Path.join(dir, ".uploads"))
    assert File.dir?(Path.join([quarantine, "buckets", "bucket-a"]))
    assert File.dir?(Path.join([quarantine, ".versions"]))
    assert File.dir?(Path.join([quarantine, ".uploads"]))
    assert File.exists?(Path.join(dir, "operator-note.txt"))
    assert File.exists?(Path.join(dir, ".maxio-physical-removal.json"))
    assert result.marker_written == true
    assert length(result.roots) == 3
  end

  test "quarantine_layout_roots blocks unknown top-level directories", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "bucket-a"))
    File.mkdir_p!(Path.join(dir, "shared-data"))

    assert {:error, {:unknown_top_level_roots, ["shared-data"]}} =
             ShardServer.quarantine_layout_roots(dir, ["bucket-a"], "q-1", %{})

    assert File.dir?(Path.join(dir, "bucket-a"))
    assert File.dir?(Path.join(dir, "shared-data"))
    refute File.exists?(Path.join(dir, ".maxio-physical-removal.json"))
  end

  test "quarantine_layout_roots blocks unexpected files under known bucket roots", %{dir: dir} do
    bucket_root = Path.join(dir, "bucket-a")
    File.mkdir_p!(bucket_root)
    File.write!(Path.join(bucket_root, "operator-file.txt"), "not maxio layout")

    assert {:error, {:unsafe_layout_file, "bucket", "operator-file.txt"}} =
             ShardServer.quarantine_layout_roots(dir, ["bucket-a"], "q-1", %{})

    assert File.exists?(Path.join(bucket_root, "operator-file.txt"))
    refute File.exists?(Path.join(dir, ".maxio-physical-removal.json"))
  end

  test "quarantine_layout_roots blocks nested symlink quarantine destinations", %{dir: dir} do
    bucket_root = Path.join(dir, "bucket-a")

    outside =
      Path.join(
        System.tmp_dir!(),
        "maxio_quarantine_escape_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(outside) end)

    File.mkdir_p!(Path.join(bucket_root, ".keep"))
    File.write!(Path.join([bucket_root, ".keep", "meta.json"]), "{}")
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.join([dir, ".maxio-removal-quarantine", "q-escape"]))

    symlink = Path.join([dir, ".maxio-removal-quarantine", "q-escape", "buckets"])

    case File.ln_s(outside, symlink) do
      :ok ->
        assert {:error, {:symlink_layout_ancestor, "destination", rel}} =
                 ShardServer.quarantine_layout_roots(dir, ["bucket-a"], "q-escape", %{})

        assert rel == Path.join([".maxio-removal-quarantine", "q-escape", "buckets"])
        assert File.dir?(bucket_root)
        refute File.exists?(Path.join(outside, "bucket-a"))
        refute File.exists?(Path.join(dir, ".maxio-physical-removal.json"))

      {:error, reason} ->
        assert reason in [:eperm, :eacces, :enotsup, :einval]
    end
  end

  test "quarantine_layout_roots blocks final symlink quarantine destinations", %{dir: dir} do
    bucket_root = Path.join(dir, "bucket-a")

    outside =
      Path.join(
        System.tmp_dir!(),
        "maxio_quarantine_target_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(outside) end)

    File.mkdir_p!(Path.join(bucket_root, ".keep"))
    File.write!(Path.join([bucket_root, ".keep", "meta.json"]), "{}")
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.join([dir, ".maxio-removal-quarantine", "q-target", "buckets"]))

    symlink = Path.join([dir, ".maxio-removal-quarantine", "q-target", "buckets", "bucket-a"])

    case File.ln_s(outside, symlink) do
      :ok ->
        assert {:error, {:symlink_quarantine_destination, "bucket-a"}} =
                 ShardServer.quarantine_layout_roots(dir, ["bucket-a"], "q-target", %{})

        assert File.dir?(bucket_root)
        refute File.exists?(Path.join(outside, "bucket-a"))
        refute File.exists?(Path.join(dir, ".maxio-physical-removal.json"))

      {:error, reason} ->
        assert reason in [:eperm, :eacces, :enotsup, :einval]
    end
  end

  test "purge_quarantine_root deletes only the matching quarantine root", %{dir: dir} do
    bucket_root = Path.join(dir, "bucket-a")
    File.mkdir_p!(Path.join(bucket_root, ".keep"))
    File.write!(Path.join([bucket_root, ".keep", "meta.json"]), "{}")
    File.write!(Path.join(dir, "operator-note.txt"), "leave me")

    marker = %{"job_id" => "job-1", "manifest_hash" => "manifest-1"}

    assert {:ok, quarantine} =
             ShardServer.quarantine_layout_roots(dir, ["bucket-a"], "q-1", marker)

    assert File.dir?(quarantine.quarantine_root)

    assert {:ok, preflight} =
             ShardServer.preflight_quarantine_purge_root(dir, "q-1", marker)

    assert preflight.status == "ready"
    assert preflight.roots_deleted == 1
    assert preflight.files_deleted >= 1

    assert {:ok, purged} = ShardServer.purge_quarantine_root(dir, "q-1", marker)
    refute File.exists?(quarantine.quarantine_root)
    assert File.exists?(Path.join(dir, "operator-note.txt"))
    assert File.exists?(Path.join(dir, ".maxio-physical-removal.json"))
    assert File.exists?(Path.join(dir, ".maxio-physical-purge.json"))
    assert purged.status == "purged"
    assert purged.roots_deleted == 1
    assert purged.marker_written == true

    assert {:ok, already} = ShardServer.purge_quarantine_root(dir, "q-1", marker)
    assert already.status == "already_purged"
  end

  test "purge_quarantine_root blocks physical removal marker mismatch", %{dir: dir} do
    bucket_root = Path.join(dir, "bucket-a")
    File.mkdir_p!(Path.join(bucket_root, ".keep"))
    File.write!(Path.join([bucket_root, ".keep", "meta.json"]), "{}")

    assert {:ok, quarantine} =
             ShardServer.quarantine_layout_roots(dir, ["bucket-a"], "q-1", %{
               "job_id" => "job-1",
               "manifest_hash" => "manifest-1"
             })

    assert {:error,
            {:physical_removal_marker_mismatch,
             {:marker_field_mismatch, "job_id", "job-2", "job-1"}}} =
             ShardServer.purge_quarantine_root(dir, "q-1", %{
               "job_id" => "job-2",
               "manifest_hash" => "manifest-1"
             })

    assert File.dir?(quarantine.quarantine_root)
    refute File.exists?(Path.join(dir, ".maxio-physical-purge.json"))
  end

  test "purge_quarantine_root requires explicit job and manifest expectations", %{dir: dir} do
    bucket_root = Path.join(dir, "bucket-a")
    File.mkdir_p!(Path.join(bucket_root, ".keep"))
    File.write!(Path.join([bucket_root, ".keep", "meta.json"]), "{}")

    assert {:ok, quarantine} =
             ShardServer.quarantine_layout_roots(dir, ["bucket-a"], "q-1", %{
               "job_id" => "job-1",
               "manifest_hash" => "manifest-1"
             })

    assert {:error, :missing_expected_purge_job_id} =
             ShardServer.purge_quarantine_root(dir, "q-1", %{})

    assert File.dir?(quarantine.quarantine_root)
    refute File.exists?(Path.join(dir, ".maxio-physical-purge.json"))
  end

  test "purge_quarantine_root does not treat stale purging marker as already purged", %{dir: dir} do
    bucket_root = Path.join(dir, "bucket-a")
    File.mkdir_p!(Path.join(bucket_root, ".keep"))
    File.write!(Path.join([bucket_root, ".keep", "meta.json"]), "{}")

    marker = %{"job_id" => "job-1", "manifest_hash" => "manifest-1"}

    assert {:ok, quarantine} =
             ShardServer.quarantine_layout_roots(dir, ["bucket-a"], "q-1", marker)

    File.write!(
      Path.join(dir, ".maxio-physical-purge.json"),
      Jason.encode!(Map.merge(marker, %{"quarantine_id" => "q-1", "status" => "purging"}))
    )

    File.rm_rf!(quarantine.quarantine_root)

    assert {:error,
            {:physical_purge_marker_mismatch,
             {:marker_field_mismatch, "status", "purged", "purging"}}} =
             ShardServer.purge_quarantine_root(dir, "q-1", marker)
  end

  test "purge_quarantine_root blocks symlink inside quarantine tree", %{dir: dir} do
    bucket_root = Path.join(dir, "bucket-a")

    outside =
      Path.join(System.tmp_dir!(), "maxio_purge_escape_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(outside) end)

    File.mkdir_p!(Path.join(bucket_root, ".keep"))
    File.write!(Path.join([bucket_root, ".keep", "meta.json"]), "{}")
    File.mkdir_p!(outside)

    marker = %{"job_id" => "job-1", "manifest_hash" => "manifest-1"}

    assert {:ok, quarantine} =
             ShardServer.quarantine_layout_roots(dir, ["bucket-a"], "q-1", marker)

    symlink = Path.join([quarantine.quarantine_root, "buckets", "bucket-a", "escape"])

    case File.ln_s(outside, symlink) do
      :ok ->
        assert {:error, {:symlink_purge_path, rel}} =
                 ShardServer.purge_quarantine_root(dir, "q-1", marker)

        assert rel == Path.join(["buckets", "bucket-a", "escape"])
        assert File.dir?(quarantine.quarantine_root)
        assert File.dir?(outside)

      {:error, reason} ->
        assert reason in [:eperm, :eacces, :enotsup, :einval]
    end
  end

  test "ping", _ do
    assert ShardServer.ping() == :pong
  end
end
