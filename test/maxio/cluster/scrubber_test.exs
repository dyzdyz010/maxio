defmodule Maxio.Cluster.ScrubberTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.{Lock, Scrubber}
  alias Maxio.Cluster.Scrubber.Usage
  alias Maxio.{Buckets, Objects}
  alias Maxio.Storage.{ErasureCoded, FS}

  @owner "arn:aws:iam:::root"

  setup do
    Usage.clear()

    base = Path.join(System.tmp_dir!(), "maxio_scrubber_#{System.unique_integer([:positive])}")
    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)

    on_exit(fn ->
      Usage.clear()
      File.rm_rf(base)
    end)

    {:ok, drives: drives, data_dir: Path.join(base, "fs")}
  end

  test "FS backend refreshes bucket usage without invoking heal" do
    bucket = bucket_name("scrub-fs")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    put_index!(bucket, "a.txt", 11, "etag-a")
    put_index!(bucket, "b.txt", 29, "etag-b")

    assert {:ok, summary} =
             Scrubber.run_once(
               bucket: bucket,
               backend: Maxio.Storage.FS,
               no_throttle: true
             )

    assert summary.buckets == 1
    assert summary.scanned == 2
    assert summary.healed == 0
    assert summary.damaged == 0
    assert summary.object_count == 2
    assert summary.total_size == 40

    assert %{object_count: 2, total_size: 40, scanned_at: %DateTime{}} = Usage.get(bucket)
  end

  test "EC backend enumerates PG rows and heals a missing shard directory", %{drives: drives} do
    bucket = bucket_name("scrub-ec")
    key = "object.bin"
    opts = ec_opts(drives)
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = ErasureCoded.put_bucket(bucket, opts)

    body = :crypto.strong_rand_bytes(3000)
    {:ok, %{size: size, etag: etag}} = ErasureCoded.put(bucket, key, "null", [body], opts)
    put_index!(bucket, key, size, etag)

    missing_dir = Path.join([Enum.at(drives, 0), bucket, key])
    File.rm_rf!(missing_dir)
    refute File.exists?(Path.join(missing_dir, "part.0"))

    assert {:ok, summary} =
             Scrubber.run_once(
               bucket: bucket,
               backend: ErasureCoded,
               no_throttle: true,
               drives: drives,
               data_shards: 4,
               parity_shards: 2,
               block_size: 1024
             )

    assert summary.scanned == 1
    assert summary.damaged == 1
    assert summary.healed == 1
    assert summary.unrecoverable == 0
    assert File.exists?(Path.join(missing_dir, "part.0"))

    {:ok, stream} = ErasureCoded.get(bucket, key, "null", nil, opts)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  test "EC backend counts unrecoverable objects without fabricating data", %{drives: drives} do
    bucket = bucket_name("scrub-unrec")
    key = "broken.bin"
    opts = ec_opts(drives)
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = ErasureCoded.put_bucket(bucket, opts)

    body = :crypto.strong_rand_bytes(2048)
    {:ok, %{size: size, etag: etag}} = ErasureCoded.put(bucket, key, "null", [body], opts)
    put_index!(bucket, key, size, etag)

    Enum.each([0, 1, 2], fn index ->
      File.rm_rf!(Path.join([Enum.at(drives, index), bucket, key]))
    end)

    assert {:ok, summary} =
             Scrubber.run_once(
               bucket: bucket,
               backend: ErasureCoded,
               no_throttle: true,
               drives: drives,
               data_shards: 4,
               parity_shards: 2,
               block_size: 1024
             )

    assert summary.scanned == 1
    assert summary.damaged == 1
    assert summary.healed == 0
    assert summary.unrecoverable == 1
  end

  test "held erasure set lock causes the scrubber to skip work", %{drives: drives} do
    bucket = bucket_name("scrub-lock")
    key = "locked.bin"
    opts = ec_opts(drives)
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = ErasureCoded.put_bucket(bucket, opts)

    {:ok, %{size: size, etag: etag}} =
      ErasureCoded.put(bucket, key, "null", ["locked body"], opts)

    put_index!(bucket, key, size, etag)

    resource = {:scrubber_set, {:erasure, :local}}
    parent = self()

    holder =
      spawn(fn ->
        {:ok, lease} = Lock.acquire(resource, nodes: [Node.self()], refresh: false)
        send(parent, {:scrubber_lock_held, lease})

        receive do
          :release_scrubber_lock -> Lock.release(lease)
        end
      end)

    try do
      assert_receive {:scrubber_lock_held, _lease}

      assert {:ok, summary} =
               Scrubber.run_once(
                 bucket: bucket,
                 backend: ErasureCoded,
                 no_throttle: true,
                 drives: drives,
                 data_shards: 4,
                 parity_shards: 2,
                 block_size: 1024
               )

      assert summary.scanned == 0
      assert summary.skipped == 1
      assert summary.healed == 0
    after
      send(holder, :release_scrubber_lock)
    end
  end

  test "explicit quorum lock nodes are honored instead of silently using only local node",
       %{drives: drives} do
    bucket = bucket_name("scrub-quorum")
    key = "quorum.bin"
    opts = ec_opts(drives)
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = ErasureCoded.put_bucket(bucket, opts)

    {:ok, %{size: size, etag: etag}} =
      ErasureCoded.put(bucket, key, "null", ["quorum body"], opts)

    put_index!(bucket, key, size, etag)

    assert {:ok, summary} =
             Scrubber.run_once(
               bucket: bucket,
               backend: ErasureCoded,
               no_throttle: true,
               lock_nodes: [Node.self(), :"missing_scrubber_lock@127.0.0.1"],
               lock_timeout_ms: 10,
               drives: drives,
               data_shards: 4,
               parity_shards: 2,
               block_size: 1024
             )

    assert summary.scanned == 0
    assert summary.skipped == 1
    assert summary.healed == 0
  end

  test "configured sampling deep-checks one deterministic partition while usage stays complete",
       %{drives: drives} do
    bucket = bucket_name("scrub-sample")
    keys = sampled_partition_keys(bucket, 2)
    opts = ec_opts(drives)
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = ErasureCoded.put_bucket(bucket, opts)

    Enum.each(keys, fn key ->
      body = "body-for-#{key}"
      {:ok, %{size: size, etag: etag}} = ErasureCoded.put(bucket, key, "null", [body], opts)
      put_index!(bucket, key, size, etag)
    end)

    base_opts = [
      bucket: bucket,
      backend: ErasureCoded,
      no_throttle: true,
      sample: :configured,
      sample_inverse: 2,
      drives: drives,
      data_shards: 4,
      parity_shards: 2,
      block_size: 1024
    ]

    assert {:ok, cycle0} = Scrubber.run_once(Keyword.put(base_opts, :sample_cycle, 0))
    assert {:ok, cycle1} = Scrubber.run_once(Keyword.put(base_opts, :sample_cycle, 1))

    assert cycle0.object_count == 2
    assert cycle1.object_count == 2
    assert cycle0.total_size == cycle1.total_size
    assert cycle0.scanned == 1
    assert cycle1.scanned == 1
    assert cycle0.sampled_out == 1
    assert cycle1.sampled_out == 1
  end

  test "optional index reconcile pre-pass refreshes PG inventory before usage scan", %{
    data_dir: data_dir
  } do
    bucket = bucket_name("scrub-reconcile")
    key = "disk-only.txt"
    body = "disk sidecar authority"
    previous_backend = Application.get_env(:maxio, :storage_backend)

    try do
      Application.put_env(:maxio, :storage_backend, FS)
      {:ok, _bucket} = Buckets.create(bucket, @owner)
      :ok = FS.put_bucket(bucket, data_dir: data_dir)

      assert {:ok, %{size: size, etag: etag}} =
               FS.put(bucket, key, "null", [body],
                 data_dir: data_dir,
                 object_meta: %{content_type: "text/plain"}
               )

      assert {:error, :not_found} = Objects.get_version(bucket, key, "null")

      assert {:ok, summary} =
               Scrubber.run_once(
                 bucket: bucket,
                 backend: FS,
                 data_dir: data_dir,
                 no_throttle: true,
                 reconcile_index: true,
                 authoritative_source: [write: :sidecar]
               )

      assert summary.index_status == :ok
      assert summary.index_scanned == 1
      assert summary.index_upserted == 1
      assert summary.index_gc == 0
      assert summary.scanned == 1
      assert summary.object_count == 1
      assert summary.total_size == size

      assert %{object_count: 1, total_size: ^size} = Usage.get(bucket)

      assert {:ok, row} = Objects.get_version(bucket, key, "null")
      assert row.etag == etag
      assert row.size == size
    after
      if previous_backend do
        Application.put_env(:maxio, :storage_backend, previous_backend)
      else
        Application.delete_env(:maxio, :storage_backend)
      end
    end
  end

  test "throttle helper computes object rate sleeps but can be disabled" do
    assert Scrubber.Throttle.sleep_ms(max_objects_per_sec: 200) == 5
    assert Scrubber.Throttle.sleep_ms(max_objects_per_sec: 3) == 334
    assert Scrubber.Throttle.sleep_ms(max_objects_per_sec: 3, no_throttle: true) == 0
  end

  defp ec_opts(drives), do: [drives: drives, data_shards: 4, parity_shards: 2, block_size: 1024]

  defp put_index!(bucket, key, size, etag) do
    {:ok, object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: size,
        etag: etag,
        content_type: "application/octet-stream"
      })

    object
  end

  defp bucket_name(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.replace("-", "")

    "#{prefix}-#{suffix}"
  end

  defp sampled_partition_keys(bucket, inverse) do
    0..1000
    |> Enum.reduce_while(%{}, fn n, acc ->
      key = "sample-#{n}.bin"
      partition = :erlang.phash2({bucket, key, "null"}, inverse)
      acc = Map.put_new(acc, partition, key)

      if map_size(acc) == inverse do
        {:halt, acc}
      else
        {:cont, acc}
      end
    end)
    |> then(fn partitions ->
      for partition <- 0..(inverse - 1), do: Map.fetch!(partitions, partition)
    end)
  end
end
