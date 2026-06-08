defmodule Maxio.Storage.ErasureCodedTest do
  use ExUnit.Case, async: true

  alias Maxio.Storage.ErasureCoded

  setup do
    base = Path.join(System.tmp_dir!(), "maxio_ec_test_#{System.unique_integer([:positive])}")
    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, drives: drives}
  end

  defp opts(drives), do: [drives: drives, data_shards: 4, parity_shards: 2, block_size: 1024]

  test "put 流式写入并返回 size/etag(明文 MD5)/sha256(明文)", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    body = :crypto.strong_rand_bytes(3000)
    chunks = for <<c::binary-500 <- body>>, do: c

    {:ok, %{size: size, etag: etag, sha256: sha256}} =
      ErasureCoded.put("b", "k.bin", "null", chunks, opts(drives))

    assert size == byte_size(body)
    assert etag == :crypto.hash(:md5, body) |> Base.encode16(case: :lower)
    assert sha256 == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    refute String.contains?(etag, "\"")
  end

  test "get 全量重建 == 原文（跨多块）", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], opts(drives))
    {:ok, stream} = ErasureCoded.get("b", "k", "null", nil, opts(drives))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  test "get 容忍 M 个分片缺失（删盘上 part.0）后仍重建", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], opts(drives))
    # 删除 2 个盘（M=2）的对象目录
    Enum.each([Enum.at(drives, 0), Enum.at(drives, 5)], fn d ->
      File.rm_rf!(Path.join([d, "b", "k"]))
    end)

    {:ok, stream} = ErasureCoded.get("b", "k", "null", nil, opts(drives))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  test "get Range 返回含端点字节区间", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    body = for(i <- 0..2999, do: rem(i, 256)) |> :erlang.list_to_binary()
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], opts(drives))

    {:ok, s1} = ErasureCoded.get("b", "k", "null", {0, 4}, opts(drives))
    assert IO.iodata_to_binary(Enum.to_list(s1)) == binary_part(body, 0, 5)

    {:ok, s2} = ErasureCoded.get("b", "k", "null", {1000, 1500}, opts(drives))
    assert IO.iodata_to_binary(Enum.to_list(s2)) == binary_part(body, 1000, 501)
  end

  test "空对象 round-trip", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    {:ok, %{size: 0, etag: etag}} = ErasureCoded.put("b", "empty", "null", [], opts(drives))
    assert etag == :crypto.hash(:md5, "") |> Base.encode16(case: :lower)
    {:ok, stream} = ErasureCoded.get("b", "empty", "null", nil, opts(drives))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == ""
  end

  test "stat 返回 size；不存在 :enoent", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    {:ok, _} = ErasureCoded.put("b", "k", "null", ["abc"], opts(drives))
    assert {:ok, %{size: 3}} = ErasureCoded.stat("b", "k", "null", opts(drives))
    assert {:error, :enoent} = ErasureCoded.stat("b", "missing", "null", opts(drives))
  end

  test "delete 跨盘删对象，重复 get :enoent；幂等", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    {:ok, _} = ErasureCoded.put("b", "k", "null", ["abc"], opts(drives))
    assert :ok = ErasureCoded.delete("b", "k", "null", opts(drives))
    assert {:error, :enoent} = ErasureCoded.get("b", "k", "null", nil, opts(drives))
    assert :ok = ErasureCoded.delete("b", "k", "null", opts(drives))
  end

  test "version_id 维度：不同版本物理隔离", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    {:ok, _} = ErasureCoded.put("b", "k", "null", ["v-null"], opts(drives))
    {:ok, _} = ErasureCoded.put("b", "k", "01ABC", ["v-one"], opts(drives))
    {:ok, s0} = ErasureCoded.get("b", "k", "null", nil, opts(drives))
    {:ok, s1} = ErasureCoded.get("b", "k", "01ABC", nil, opts(drives))
    assert IO.iodata_to_binary(Enum.to_list(s0)) == "v-null"
    assert IO.iodata_to_binary(Enum.to_list(s1)) == "v-one"
  end

  test "key 含 ../ 被拒", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))

    assert {:error, :invalid_key} =
             ErasureCoded.put("b", "../escape", "null", ["x"], opts(drives))
  end

  test "put_bucket 建各盘目录；delete_bucket 删各盘空目录", %{drives: drives} do
    assert :ok = ErasureCoded.put_bucket("nb", opts(drives))
    assert Enum.all?(drives, &File.dir?(Path.join(&1, "nb")))
    assert :ok = ErasureCoded.delete_bucket("nb", opts(drives))
    refute Enum.any?(drives, &File.exists?(Path.join(&1, "nb")))
  end
end
