defmodule Maxio.Cluster.M8IntegrationTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.{Lock, Notify, Paths, Scrubber, Topology, Transport.InProcess}
  alias Maxio.Cluster.Scrubber.Usage
  alias Maxio.{Buckets, Objects}
  alias Maxio.Storage.Distributed

  @owner "arn:aws:iam:::root"

  setup do
    InProcess.setup!()
    Usage.clear()

    base =
      Path.join(System.tmp_dir!(), "maxio_m8_integration_#{System.unique_integer([:positive])}")

    endpoints = for i <- 0..5, do: {Node.self(), Path.join(base, "d#{i}")}

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    on_exit(fn ->
      Usage.clear()
      File.rm_rf(base)
    end)

    {:ok, base: base, endpoints: endpoints, topology: topology}
  end

  test "supervised scrubber scan_now heals distributed shards while notify remains live", ctx do
    bucket = bucket_name("m8-live")
    key = "healed.bin"
    body = :crypto.strong_rand_bytes(4096)
    opts = dist_opts(ctx)

    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    assert_receive {:bucket_metadata_changed, ^bucket}

    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, %{size: size, etag: etag}} = Distributed.put(bucket, key, "null", [body], opts)
    put_index!(bucket, key, size, etag)

    assert :ok = Objects.put_tags(bucket, key, [{"m8", "integration"}])
    assert_receive {:object_metadata_changed, ^bucket, ^key, "null"}

    missing_part = remove_first_shard!(ctx, bucket, key)
    refute File.exists?(missing_part)

    assert {:ok, summary} =
             Scrubber.scan_now(
               bucket: bucket,
               backend: Distributed,
               topology: ctx.topology,
               transport: InProcess,
               no_throttle: true
             )

    assert summary.buckets == 1
    assert summary.scanned == 1
    assert summary.damaged == 1
    assert summary.healed == 1
    assert summary.unrecoverable == 0
    assert summary.skipped == 0
    assert File.exists?(missing_part)

    assert %{object_count: 1, total_size: ^size} = Usage.get(bucket)
    {:ok, stream} = Distributed.get(bucket, key, "null", nil, opts)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  test "distributed scrubber honors the erasure-set quorum lock before healing", ctx do
    bucket = bucket_name("m8-lock")
    key = "locked.bin"
    body = :crypto.strong_rand_bytes(2048)
    opts = dist_opts(ctx)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, %{size: size, etag: etag}} = Distributed.put(bucket, key, "null", [body], opts)
    put_index!(bucket, key, size, etag)

    missing_part = remove_first_shard!(ctx, bucket, key)
    resource = {:scrubber_set, {:distributed, 0}}
    {:ok, lease} = Lock.acquire(resource, nodes: [Node.self()], refresh: false)

    try do
      assert {:ok, skipped} =
               Scrubber.scan_now(
                 bucket: bucket,
                 backend: Distributed,
                 topology: ctx.topology,
                 transport: InProcess,
                 no_throttle: true
               )

      assert skipped.scanned == 0
      assert skipped.skipped == 1
      assert skipped.healed == 0
      refute File.exists?(missing_part)
    after
      :ok = Lock.release(lease)
    end

    assert {:ok, healed} =
             Scrubber.scan_now(
               bucket: bucket,
               backend: Distributed,
               topology: ctx.topology,
               transport: InProcess,
               no_throttle: true
             )

    assert healed.scanned == 1
    assert healed.healed == 1
    assert File.exists?(missing_part)
  end

  defp dist_opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  defp remove_first_shard!(ctx, bucket, key) do
    {:ok, rel} = Paths.object_rel(bucket, key, "null")
    {_node, first_drive} = hd(ctx.endpoints)
    object_dir = Path.join(first_drive, rel)
    part = Path.join(object_dir, "part.0")
    File.rm_rf!(object_dir)
    part
  end

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
end
