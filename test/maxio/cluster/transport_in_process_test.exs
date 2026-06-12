defmodule Maxio.Cluster.TransportInProcessTest do
  use ExUnit.Case, async: false
  alias Maxio.Cluster.Transport.InProcess

  setup do
    InProcess.setup!()
    base = Path.join(System.tmp_dir!(), "maxio_inproc_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  test "put/get round-trip 经端点映射", %{base: base} do
    dir = Path.join(base, "n0_d0/b/k")
    s = :crypto.strong_rand_bytes(256)
    assert :ok = InProcess.put_shard(:maxio@n0, dir, 0, s, 256)
    assert InProcess.get_shard(:maxio@n0, dir, 0, 256) == s
  end

  test "打掉端点 -> get nil、put {:error,:unavailable}", %{base: base} do
    dir = Path.join(base, "n1_d0/b/k")
    s = :crypto.strong_rand_bytes(256)
    assert :ok = InProcess.put_shard(:maxio@n1, dir, 0, s, 256)
    InProcess.set_down(:maxio@n1)
    assert InProcess.get_shard(:maxio@n1, dir, 0, 256) == nil
    assert {:error, :unavailable} = InProcess.put_shard(:maxio@n1, dir, 0, s, 256)
    InProcess.set_up(:maxio@n1)
    assert InProcess.get_shard(:maxio@n1, dir, 0, 256) == s
  end

  test "sidecar 在宕机端点回 :enoent", %{base: base} do
    dir = Path.join(base, "n2_d0/b/k")
    :ok = InProcess.put_sidecar(:maxio@n2, dir, %{"size" => 1})
    InProcess.set_down(:maxio@n2)
    assert {:error, :enoent} = InProcess.get_sidecar(:maxio@n2, dir)
  end

  test "drive-level outage leaves sibling drives on the same node reachable", %{base: base} do
    node = :maxio@n3
    drive0 = Path.join(base, "n3_d0")
    drive1 = Path.join(base, "n3_d1")
    dir0 = Path.join(drive0, "b/k0")
    dir1 = Path.join(drive1, "b/k1")
    shard = :crypto.strong_rand_bytes(128)

    File.mkdir_p!(drive0)
    File.mkdir_p!(drive1)
    assert :ok = InProcess.put_shard(node, dir0, 0, shard, 128)
    assert :ok = InProcess.put_shard(node, dir1, 0, shard, 128)

    InProcess.set_drive_down(node, drive0)

    assert {:error, :unavailable} = InProcess.list_dir(node, drive0, [])
    assert {:ok, _entries} = InProcess.list_dir(node, drive1, [])
    assert InProcess.get_shard(node, dir0, 0, 128) == nil
    assert InProcess.get_shard(node, dir1, 0, 128) == shard

    InProcess.set_drive_up(node, drive0)
    assert InProcess.get_shard(node, dir0, 0, 128) == shard
  end

  test "pressure snapshot injection follows node down state" do
    node = :maxio@n4

    InProcess.set_pressure_snapshot(node, %{s3_in_flight: 1, storage_ops: 2})

    assert {:ok, %{s3_in_flight: 1, storage_ops: 2, combined: 3}} =
             InProcess.pressure_snapshot(node)

    InProcess.set_down(node)

    assert {:error, :unavailable} = InProcess.pressure_snapshot(node)
  end
end
