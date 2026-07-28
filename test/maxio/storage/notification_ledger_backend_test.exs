defmodule Maxio.Storage.NotificationLedgerBackendTest do
  use ExUnit.Case, async: false

  alias Maxio.Cluster.{Topology, Transport.InProcess}
  alias Maxio.Cluster.Paths
  alias Maxio.Storage.Erasure.Meta
  alias Maxio.Storage.{ErasureCoded, FS, NotificationLedger}
  alias Maxio.Storage.Distributed

  defp entry(bucket, key) do
    %{
      "id" => Ecto.UUID.generate(),
      "bucket" => bucket,
      "key" => key,
      "payload" => %{"event_name" => "s3:ObjectCreated:Put"},
      "commit_predicate" => %{"type" => "version_present", "version_id" => "null"}
    }
  end

  test "FS retained notification ledger round-trips outside object namespace" do
    dir = Path.join(System.tmp_dir!(), "maxio_fs_ledger_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    opts = [data_dir: dir]
    bucket = "b"
    key = "a/b/retained.txt"
    entry = entry(bucket, key)

    :ok = FS.put_bucket(bucket, opts)
    assert :ok = FS.put_notification_ledgers(bucket, key, [entry], opts)
    assert {:ok, [stored]} = FS.list_notification_ledgers(bucket, key, opts)
    assert stored["id"] == entry["id"]
    assert stored["payload"]["event_name"] == "s3:ObjectCreated:Put"

    assert {:ok, [stored_all]} = FS.list_notification_ledgers(bucket, :all, opts)
    assert stored_all["id"] == entry["id"]

    assert :ok = FS.delete_notification_ledgers(bucket, key, [entry["id"]], opts)
    assert {:ok, []} = FS.list_notification_ledgers(bucket, key, opts)
  end

  test "FS retained notification ledger rejects unsafe ids" do
    dir =
      Path.join(System.tmp_dir!(), "maxio_fs_ledger_bad_id_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    opts = [data_dir: dir]
    bucket = "b"
    key = "bad-id"
    entry = Map.put(entry(bucket, key), "id", "../escape")

    assert {:error, :invalid_notification_ledger_id} =
             FS.put_notification_ledgers(bucket, key, [entry], opts)

    assert {:error, :invalid_notification_ledger_id} =
             FS.delete_notification_ledgers(bucket, key, ["../escape"], opts)
  end

  test "FS retained notification ledger exposes corrupt metadata as invalid evidence" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_fs_ledger_corrupt_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    opts = [data_dir: dir]
    bucket = "b"
    key = "corrupt"
    entry = entry(bucket, key)

    assert :ok = FS.put_notification_ledgers(bucket, key, [entry], opts)
    rel = Paths.notification_ledger_entry_rel(bucket, key, entry["id"])
    File.write!(Path.join([dir, rel, "meta.json"]), "{not-json")

    assert {:ok, [invalid]} = FS.list_notification_ledgers(bucket, key, opts)
    assert invalid["id"] == entry["id"]
    assert invalid["invalid_retained_ledger"] == true
    assert invalid["reason"] == "invalid_meta"
  end

  test "FS retained notification ledger fails closed on invalid traversal root" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_fs_ledger_root_file_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    opts = [data_dir: dir]
    bucket = "b"
    key = "root-file"
    root = Path.join(dir, Paths.notification_ledger_key_rel(bucket, key))

    File.mkdir_p!(Path.dirname(root))
    File.write!(root, "not a directory")

    assert {:error, {:invalid_notification_ledger_root, ^root}} =
             FS.list_notification_ledgers(bucket, key, opts)
  end

  test "erasure-coded retained notification ledger round-trips with read quorum" do
    base = Path.join(System.tmp_dir!(), "maxio_ec_ledger_#{System.unique_integer([:positive])}")
    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)

    opts = [drives: drives, data_shards: 4, parity_shards: 2, block_size: 1024]
    bucket = "b"
    key = "a/b/retained.txt"
    entry = entry(bucket, key)

    :ok = ErasureCoded.put_bucket(bucket, opts)
    assert :ok = ErasureCoded.put_notification_ledgers(bucket, key, [entry], opts)
    assert {:ok, [stored]} = ErasureCoded.list_notification_ledgers(bucket, key, opts)
    assert stored["id"] == entry["id"]

    assert {:ok, [stored_all]} = ErasureCoded.list_notification_ledgers(bucket, :all, opts)
    assert stored_all["id"] == entry["id"]

    assert :ok = ErasureCoded.delete_notification_ledgers(bucket, key, [entry["id"]], opts)
    assert {:ok, []} = ErasureCoded.list_notification_ledgers(bucket, key, opts)
  end

  test "erasure-coded retained notification ledger fails closed below read quorum" do
    base =
      Path.join(System.tmp_dir!(), "maxio_ec_ledger_quorum_#{System.unique_integer([:positive])}")

    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)

    opts = [drives: drives, data_shards: 4, parity_shards: 2, block_size: 1024]
    bucket = "b"
    key = "below-quorum"
    entry = entry(bucket, key)

    assert :ok = ErasureCoded.put_notification_ledgers(bucket, key, [entry], opts)
    rel = Paths.notification_ledger_entry_rel(bucket, key, entry["id"])

    drives
    |> Enum.take(3)
    |> Enum.each(fn drive -> File.rm_rf!(Path.join(drive, rel)) end)

    assert {:ok, [invalid]} = ErasureCoded.list_notification_ledgers(bucket, key, opts)
    assert invalid["id"] == entry["id"]
    assert invalid["invalid_retained_ledger"] == true
    assert invalid["reason"] == "read_quorum_not_met"
    assert invalid["read_quorum"] == 4
  end

  test "erasure-coded retained notification ledger fails closed on divergent replicas" do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_ec_ledger_divergent_#{System.unique_integer([:positive])}"
      )

    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)

    opts = [drives: drives, data_shards: 4, parity_shards: 2, block_size: 1024]
    bucket = "b"
    key = "divergent"
    entry = entry(bucket, key)

    assert :ok = ErasureCoded.put_notification_ledgers(bucket, key, [entry], opts)

    rel = Paths.notification_ledger_entry_rel(bucket, key, entry["id"])

    divergent =
      entry
      |> put_in(["payload", "event_name"], "s3:ObjectRemoved:Delete")
      |> NotificationLedger.sidecar()
      |> Meta.encode()

    File.write!(Path.join([List.last(drives), rel, "meta.json"]), divergent)

    assert {:ok, [invalid]} = ErasureCoded.list_notification_ledgers(bucket, key, opts)
    assert invalid["id"] == entry["id"]
    assert invalid["invalid_retained_ledger"] == true
    assert invalid["reason"] == "divergent_replicas"
    assert invalid["read_quorum"] == 4
    assert invalid["replicas"] == 6
    assert invalid["signature_groups"] == 2
  end

  test "erasure-coded retained notification ledger returns error on meta read failure" do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_ec_ledger_read_fail_#{System.unique_integer([:positive])}"
      )

    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)

    opts = [drives: drives, data_shards: 4, parity_shards: 2, block_size: 1024]
    bucket = "b"
    key = "read-fail"
    entry = entry(bucket, key)

    assert :ok = ErasureCoded.put_notification_ledgers(bucket, key, [entry], opts)

    rel = Paths.notification_ledger_entry_rel(bucket, key, entry["id"])
    failed_path = Path.join([List.first(drives), rel, "meta.json"])

    read_fun = fn path ->
      if path == failed_path, do: {:error, :eacces}, else: File.read(path)
    end

    assert {:error, {:notification_ledger_read_failed, ^failed_path, :eacces}} =
             ErasureCoded.list_notification_ledgers(
               bucket,
               key,
               Keyword.put(opts, :notification_ledger_read_fun, read_fun)
             )
  end

  test "erasure-coded retained notification ledger fails closed on invalid traversal root" do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_ec_ledger_root_file_#{System.unique_integer([:positive])}"
      )

    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)

    opts = [drives: drives, data_shards: 4, parity_shards: 2, block_size: 1024]
    bucket = "b"
    key = "root-file"
    root = Path.join(List.first(drives), Paths.notification_ledger_key_rel(bucket, key))

    File.mkdir_p!(Path.dirname(root))
    File.write!(root, "not a directory")

    assert {:error, {:invalid_notification_ledger_root, ^root}} =
             ErasureCoded.list_notification_ledgers(bucket, key, opts)
  end

  test "distributed key lookup finds retained ledgers written on non-routed placement set" do
    InProcess.setup!()

    base = Path.join(System.tmp_dir!(), "maxio_dist_ledger_#{System.unique_integer([:positive])}")
    set0 = for i <- 0..2, do: {:"ledger_s0_d#{i}", Path.join([base, "s0", "d#{i}"])}
    set1 = for i <- 0..2, do: {:"ledger_s1_d#{i}", Path.join([base, "s1", "d#{i}"])}

    topology =
      Topology.parse_and_validate!(
        data_shards: 2,
        parity_shards: 1,
        block_size: 1024,
        pools: [
          %{
            id: 0,
            sets: [
              %{id: 0, endpoints: set0},
              %{id: 1, endpoints: set1}
            ]
          }
        ]
      )

    on_exit(fn -> File.rm_rf(base) end)

    opts = [topology: topology, transport: InProcess]
    bucket = "b"
    key = "retained-on-other-set"
    entry = entry(bucket, key)

    :ok = Distributed.put_bucket(bucket, opts)

    assert :ok =
             Distributed.put_notification_ledgers(
               bucket,
               key,
               [entry],
               Keyword.put(opts, :placement_set_id, 1)
             )

    assert {:ok, [stored]} = Distributed.list_notification_ledgers(bucket, key, opts)
    assert stored["id"] == entry["id"]

    assert :ok = Distributed.delete_notification_ledgers(bucket, key, [entry["id"]], opts)
    assert {:ok, []} = Distributed.list_notification_ledgers(bucket, key, opts)
  end

  test "distributed retained notification ledger returns error on sidecar read failure" do
    InProcess.setup!()

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_dist_ledger_read_fail_#{System.unique_integer([:positive])}"
      )

    set0 = for i <- 0..2, do: {:"ledger_read_s0_d#{i}", Path.join([base, "s0", "d#{i}"])}
    set1 = for i <- 0..2, do: {:"ledger_read_s1_d#{i}", Path.join([base, "s1", "d#{i}"])}

    topology =
      Topology.parse_and_validate!(
        data_shards: 2,
        parity_shards: 1,
        block_size: 1024,
        pools: [
          %{
            id: 0,
            sets: [
              %{id: 0, endpoints: set0},
              %{id: 1, endpoints: set1}
            ]
          }
        ]
      )

    on_exit(fn -> File.rm_rf(base) end)

    opts = [topology: topology, transport: InProcess]
    bucket = "b"
    key = "read-fail"
    entry = entry(bucket, key)
    {node, drive} = List.first(set0)

    :ok = Distributed.put_bucket(bucket, opts)

    assert :ok =
             Distributed.put_notification_ledgers(
               bucket,
               key,
               [entry],
               Keyword.put(opts, :placement_set_id, 0)
             )

    InProcess.set_get_sidecar_down(node, drive)

    failed_dir = Path.join(drive, Paths.notification_ledger_entry_rel(bucket, key, entry["id"]))

    assert {:error, {:notification_ledger_read_failed, ^node, ^failed_dir, :unavailable}} =
             Distributed.list_notification_ledgers(bucket, key, opts)
  end

  test "distributed retained notification ledger fails closed on list traversal errors" do
    InProcess.setup!()

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_dist_ledger_root_file_#{System.unique_integer([:positive])}"
      )

    set0 = for i <- 0..2, do: {:"ledger_root_s0_d#{i}", Path.join([base, "s0", "d#{i}"])}
    set1 = for i <- 0..2, do: {:"ledger_root_s1_d#{i}", Path.join([base, "s1", "d#{i}"])}

    topology =
      Topology.parse_and_validate!(
        data_shards: 2,
        parity_shards: 1,
        block_size: 1024,
        pools: [
          %{
            id: 0,
            sets: [
              %{id: 0, endpoints: set0},
              %{id: 1, endpoints: set1}
            ]
          }
        ]
      )

    Enum.each(set0 ++ set1, fn {_node, drive} -> File.mkdir_p!(drive) end)
    on_exit(fn -> File.rm_rf(base) end)

    opts = [topology: topology, transport: InProcess]
    bucket = "b"
    key = "root-file"
    {node, drive} = List.first(set0)
    root = Path.join(drive, Paths.notification_ledger_key_rel(bucket, key))

    File.mkdir_p!(Path.dirname(root))
    File.write!(root, "not a directory")

    assert {:error, {:notification_ledger_list_failed, ^node, ^root, reason}} =
             Distributed.list_notification_ledgers(bucket, key, opts)

    assert reason in [:enotdir, :eio]
  end
end
