defmodule Maxio.Storage.Erasure.HealTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias Maxio.Storage.ErasureCoded
  alias Maxio.Storage.Erasure.Heal

  setup do
    base = Path.join(System.tmp_dir!(), "maxio_heal_#{System.unique_integer([:positive])}")
    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, drives: drives}
  end

  defp opts(drives), do: [drives: drives, data_shards: 4, parity_shards: 2, block_size: 1024]

  defp part_path(drive, bucket, key), do: Path.join([drive, bucket, key, "part.0"])

  test "heal 重建被删除的 1 个分片文件（整列缺失）", %{drives: drives} do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], o)

    # 删掉盘 0 的对象目录（整列分片 + sidecar 缺失）
    File.rm_rf!(Path.join([Enum.at(drives, 0), "b", "k"]))
    refute File.exists?(part_path(Enum.at(drives, 0), "b", "k"))

    assert {:ok, %{healed: healed}} = Heal.heal_object("b", "k", "null", o)
    assert healed >= 1
    # 盘 0 分片文件 + sidecar 已回写
    assert File.exists?(part_path(Enum.at(drives, 0), "b", "k"))
    assert File.exists?(Path.join([Enum.at(drives, 0), "b", "k", "meta.json"]))

    # heal 后 GET 仍正确
    {:ok, stream} = ErasureCoded.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  test "heal 修复被篡改的分片（bitrot）", %{drives: drives} do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], o)

    # 篡改盘 1 的 part.0 首字节
    p = part_path(Enum.at(drives, 1), "b", "k")
    <<first, rest::binary>> = File.read!(p)
    File.write!(p, <<bxor(first, 0xFF), rest::binary>>)

    assert {:ok, %{healed: healed}} = Heal.heal_object("b", "k", "null", o)
    assert healed >= 1
    # 篡改已被修正（重算校验和匹配）
    {:ok, stream} = ErasureCoded.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  test "损坏 M+1 个分片 -> heal 返回 :unrecoverable（不伪造数据）", %{drives: drives} do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)
    body = :crypto.strong_rand_bytes(1000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], o)

    # 删 3 个盘（M=2，存活 3 < K=4）
    Enum.each([0, 1, 2], fn i -> File.rm_rf!(Path.join([Enum.at(drives, i), "b", "k"])) end)

    assert {:error, :unrecoverable} = Heal.heal_object("b", "k", "null", o)
  end

  test "无损对象 heal 为 no-op（healed=0）", %{drives: drives} do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [:crypto.strong_rand_bytes(2000)], o)
    assert {:ok, %{healed: 0}} = Heal.heal_object("b", "k", "null", o)
  end

  test "scrub_bucket 扫描并 heal 桶内全部对象", %{drives: drives} do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)
    {:ok, _} = ErasureCoded.put("b", "k1", "null", [:crypto.strong_rand_bytes(2000)], o)
    {:ok, _} = ErasureCoded.put("b", "a/k2", "null", [:crypto.strong_rand_bytes(2000)], o)
    File.rm_rf!(Path.join([Enum.at(drives, 0), "b", "k1"]))

    assert {:ok, %{scanned: scanned, healed_objects: healed}} = Heal.scrub_bucket("b", o)
    assert scanned >= 2
    assert healed >= 1
  end
end
