defmodule Maxio.Cluster.ShardServerIOTest do
  use ExUnit.Case, async: false

  alias Maxio.Cluster.{DriveIO, ShardServer}

  setup do
    DriveIO.reset()

    dir = Path.join(System.tmp_dir!(), "maxio_shardsrv_io_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      DriveIO.reset()
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  test "ShardServer filesystem operations contribute storage pressure counters", %{dir: dir} do
    obj = Path.join(dir, "bucket/key")
    shard = :crypto.strong_rand_bytes(128)
    meta = %{"size" => 128, "etag" => "etag-io"}

    :ok = ShardServer.put_shard(obj, 0, shard, 128)
    :ok = ShardServer.put_sidecar(obj, meta)
    assert ShardServer.get_shard(obj, 0, 128) == shard
    assert {:ok, %{"etag" => "etag-io"}} = ShardServer.get_sidecar(obj)
    assert {:ok, 128} = ShardServer.stat_shard(obj)
    assert {:ok, [%{name: "bucket", object?: false}]} = ShardServer.list_dir(dir)
    assert :ok = ShardServer.probe_drive(dir)
    assert {:ok, %{drive_uuid: drive_uuid}} = ShardServer.probe_drive_identity(dir)
    assert drive_uuid =~ ~r/\A[0-9a-f]{32}\z/
    assert :ok = ShardServer.delete_part_file(obj)
    assert :ok = ShardServer.delete_shard(obj)

    snapshot = DriveIO.snapshot()

    assert snapshot.active_ops == 0
    assert snapshot.write_ops >= 2
    assert snapshot.read_ops >= 2
    assert snapshot.metadata_ops >= 3
    assert snapshot.delete_ops >= 2
    assert snapshot.bytes_written > 0
    assert snapshot.bytes_read >= byte_size(shard)
  end
end
