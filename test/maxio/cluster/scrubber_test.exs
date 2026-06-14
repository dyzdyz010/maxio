defmodule Maxio.Cluster.ScrubberTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.{DriveDeviceIO, DriveIO, Lock, PressureAggregator, Scrubber}
  alias Maxio.Cluster.Scrubber.Usage
  alias Maxio.Cluster.Transport.InProcess
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

  test "token-bucket throttle consumes burst and refills deterministically" do
    throttle = Scrubber.Throttle.new([max_objects_per_sec: 2, object_burst: 2], 0)

    assert throttle.mode == :token_bucket
    assert throttle.tokens == 2.0

    {0, throttle} = Scrubber.Throttle.take(throttle, 0)
    assert throttle.tokens == 1.0

    {0, throttle} = Scrubber.Throttle.take(throttle, 0)
    assert throttle.tokens == 0.0

    {sleep_ms, throttle} = Scrubber.Throttle.take(throttle, 0)
    assert sleep_ms == 500
    assert throttle.last_ms == 500

    {0, throttle} = Scrubber.Throttle.take(throttle, 1000)
    assert throttle.tokens == 0.0
    assert throttle.last_ms == 1000
  end

  test "adaptive IO gate does not sleep below threshold and is disabled by no_throttle" do
    parent = self()

    below_threshold =
      Scrubber.Throttle.new(
        [
          max_objects_per_sec: 1,
          object_burst: 1,
          adaptive_io: true,
          max_live_requests: 1,
          io_load_fun: fn -> 1 end,
          throttle_now_fun: fn -> 0 end,
          throttle_sleep_fun: fn ms -> send(parent, {:adaptive_io_sleep, ms}) end
        ],
        0
      )

    _ = Scrubber.Throttle.maybe_wait(below_threshold)
    refute_receive {:adaptive_io_sleep, _}, 10

    no_throttle =
      Scrubber.Throttle.new(
        [
          no_throttle: true,
          adaptive_io: true,
          max_live_requests: 0,
          io_pause_ms: 10,
          io_max_pause_ms: 30,
          io_load_fun: fn -> 1 end,
          throttle_sleep_fun: fn ms -> send(parent, {:adaptive_io_sleep, ms}) end
        ],
        0
      )

    _ = Scrubber.Throttle.maybe_wait(no_throttle)
    refute_receive {:adaptive_io_sleep, _}, 10
  end

  test "adaptive IO gate can use storage operation pressure" do
    DriveIO.reset()
    parent = self()

    task =
      Task.async(fn ->
        DriveIO.track(:read, fn ->
          send(parent, {:storage_operation_active, self()})

          receive do
            :release_storage_operation -> :ok
          end
        end)
      end)

    assert_receive {:storage_operation_active, worker}
    assert DriveIO.active_count() == 1

    throttle =
      Scrubber.Throttle.new(
        [
          adaptive_io: true,
          io_load_source: :storage_ops,
          max_live_requests: 0,
          io_pause_ms: 10,
          io_max_pause_ms: 20,
          throttle_now_fun: fn -> 0 end,
          throttle_sleep_fun: fn ms -> send(parent, {:storage_io_sleep, ms}) end
        ],
        0
      )

    _ = Scrubber.Throttle.maybe_wait(throttle)
    assert_receive {:storage_io_sleep, 10}
    assert_receive {:storage_io_sleep, 10}

    send(worker, :release_storage_operation)
    assert Task.await(task) == :ok
  after
    DriveIO.reset()
  end

  test "adaptive IO gate can use cached device IO pressure" do
    DriveDeviceIO.reset()
    parent = self()
    drive = Path.join(System.tmp_dir!(), "maxio_scrub_device_io")

    _ =
      DriveDeviceIO.sample_local_drive(drive,
        provider: fn ^drive -> {:ok, %{device_id: "device-io", queue_depth: 1, source: :test}} end,
        now_ms: 0
      )

    throttle =
      Scrubber.Throttle.new(
        [
          adaptive_io: true,
          io_load_source: :drive_device_io,
          max_live_requests: 0,
          io_pause_ms: 10,
          io_max_pause_ms: 20,
          throttle_now_fun: fn -> 0 end,
          throttle_sleep_fun: fn ms -> send(parent, {:device_io_sleep, ms}) end
        ],
        0
      )

    _ = Scrubber.Throttle.maybe_wait(throttle)
    assert_receive {:device_io_sleep, 10}
    assert_receive {:device_io_sleep, 10}
  after
    DriveDeviceIO.reset()
  end

  test "scrubber adaptive IO gate can use cached cluster pressure" do
    InProcess.setup!()
    PressureAggregator.reset()

    bucket = bucket_name("scrub-cluster-io")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    put_index!(bucket, "remote-busy.txt", 10, "etag-remote-busy")

    InProcess.set_pressure_snapshot(:maxio@n1, %{combined: 1})

    assert {:ok, %{:maxio@n1 => %{combined: 1}}} =
             PressureAggregator.refresh_once(nodes: [:maxio@n1], transport: InProcess)

    parent = self()

    assert {:ok, summary} =
             Scrubber.run_once(
               bucket: bucket,
               backend: FS,
               adaptive_io: true,
               io_load_source: :cluster_combined,
               max_live_requests: 0,
               io_pause_ms: 10,
               io_max_pause_ms: 20,
               throttle_now_fun: fn -> 0 end,
               throttle_sleep_fun: fn ms -> send(parent, {:cluster_io_sleep, ms}) end
             )

    assert summary.scanned == 1
    assert summary.object_count == 1
    assert_receive {:cluster_io_sleep, 10}
    assert_receive {:cluster_io_sleep, 10}
  after
    PressureAggregator.reset()
    InProcess.setup!()
  end

  test "scrubber threads configured token bucket across buckets when caller passes nil overrides" do
    prev_scrubber = Application.get_env(:maxio, :scrubber, [])
    parent = self()

    try do
      Application.put_env(
        :maxio,
        :scrubber,
        Keyword.merge(prev_scrubber,
          max_objects_per_sec: 1,
          object_burst: 1,
          sleep_between_batches_ms: 0
        )
      )

      bucket_a = bucket_name("scrub-rate-a")
      bucket_b = bucket_name("scrub-rate-b")
      {:ok, _bucket} = Buckets.create(bucket_a, @owner)
      {:ok, _bucket} = Buckets.create(bucket_b, @owner)
      put_index!(bucket_a, "a.txt", 10, "etag-a")
      put_index!(bucket_b, "b.txt", 20, "etag-b")

      assert {:ok, summary} =
               Scrubber.run_once(
                 backend: FS,
                 max_objects_per_sec: nil,
                 object_burst: nil,
                 sleep_between_batches_ms: nil,
                 throttle_now_fun: fn -> 0 end,
                 throttle_sleep_fun: fn ms -> send(parent, {:throttle_sleep, ms}) end
               )

      assert summary.buckets == 2
      assert summary.scanned == 2
      assert summary.object_count == 2
      assert summary.total_size == 30
      assert_receive {:throttle_sleep, 1000}
    after
      Application.put_env(:maxio, :scrubber, prev_scrubber)
    end
  end

  test "scrubber pauses between objects while live S3 IO is above threshold" do
    bucket = bucket_name("scrub-live-io")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    put_index!(bucket, "busy.txt", 10, "etag-busy")
    parent = self()

    assert {:ok, summary} =
             Scrubber.run_once(
               bucket: bucket,
               backend: FS,
               adaptive_io: true,
               max_live_requests: 0,
               io_pause_ms: 10,
               io_max_pause_ms: 25,
               io_load_fun: fn -> 1 end,
               throttle_now_fun: fn -> 0 end,
               throttle_sleep_fun: fn ms -> send(parent, {:adaptive_io_sleep, ms}) end
             )

    assert summary.scanned == 1
    assert summary.object_count == 1
    assert_receive {:adaptive_io_sleep, 10}
    assert_receive {:adaptive_io_sleep, 10}
    assert_receive {:adaptive_io_sleep, 5}
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
