defmodule Maxio.MultipartDistributedPlacementTest do
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Multipart}
  alias Maxio.Cluster.{Placement, Router, Topology, Transport.InProcess}
  alias Maxio.Storage

  setup do
    InProcess.setup!()

    previous_backend = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_multipart_dist_placement_#{System.unique_integer([:positive])}"
      )

    set0 = for i <- 0..1, do: {:"mpdp_s0_d#{i}", Path.join([base, "s0", "d#{i}"])}
    set1 = for i <- 0..1, do: {:"mpdp_s1_d#{i}", Path.join([base, "s1", "d#{i}"])}

    topology =
      Topology.parse_and_validate!(
        data_shards: 1,
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

    on_exit(fn ->
      if previous_backend do
        Application.put_env(:maxio, :storage_backend, previous_backend)
      else
        Application.delete_env(:maxio, :storage_backend)
      end

      File.rm_rf(base)
    end)

    {:ok, topology: topology}
  end

  test "complete callback receives final object placement, not upload part placement", %{
    topology: topology
  } do
    bucket = "mp-placement"
    key = key_for_set(bucket, topology, 0)
    opts = [topology: topology, transport: InProcess]

    assert :ok = Maxio.Storage.Distributed.put_bucket(bucket, opts)
    {:ok, _bucket} = Buckets.create(bucket, "arn:aws:iam:::root")

    {:ok, upload} =
      Multipart.initiate(
        bucket,
        key,
        %{owner: "arn:aws:iam:::root"},
        Keyword.put(opts, :placement_set_id, 1)
      )

    assert upload.placement_set_id == 1

    part_opts = Keyword.merge(opts, Placement.upload_storage_opts(upload))
    {:ok, part} = Storage.put_part(bucket, key, upload.upload_id, 1, ["mpu-bytes"], part_opts)
    {:ok, _part} = Multipart.put_part(upload, 1, %{etag: part.etag, size: part.size})

    parent = self()

    requested = [%{part_number: 1, etag: ~s("#{part.etag}")}]

    assert {:ok, result} =
             Multipart.complete(
               upload,
               requested,
               Keyword.merge(opts,
                 min_part_size: 1,
                 object_meta_extra: fn info ->
                   send(parent, {:complete_object_meta_extra_info, info})
                   %{object_meta: %{notification_outbox: []}}
                 end
               )
             )

    assert result.placement_set_id == 0

    assert_receive {:complete_object_meta_extra_info, info}
    assert info.placement_set_id == 0
    refute info.placement_set_id == upload.placement_set_id
  end

  defp key_for_set(bucket, topology, set_id) do
    Enum.find_value(0..10_000, fn i ->
      key = "obj-#{i}"
      if Router.set_for(bucket, key, topology) == set_id, do: key
    end) || flunk("could not find key for set #{inspect(set_id)}")
  end
end
