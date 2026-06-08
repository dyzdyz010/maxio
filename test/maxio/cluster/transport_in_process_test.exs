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
end
