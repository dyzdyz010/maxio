defmodule Maxio.Storage.ErasureCodedTest do
  use ExUnit.Case, async: true

  alias Maxio.Storage.ErasureCoded
  alias Maxio.Cluster.Paths

  setup do
    base = Path.join(System.tmp_dir!(), "maxio_ec_test_#{System.unique_integer([:positive])}")
    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, drives: drives}
  end

  defp opts(drives), do: [drives: drives, data_shards: 4, parity_shards: 2, block_size: 1024]

  defp body(backend, bucket, key, version_id, opts) do
    {:ok, stream} = backend.get(bucket, key, version_id, nil, opts)
    stream |> Enum.to_list() |> IO.iodata_to_binary()
  end

  defp temp_empty?(drive) do
    case File.ls(Path.join(drive, ".tmp")) do
      {:ok, []} -> true
      {:error, :enoent} -> true
      _ -> false
    end
  end

  defp sidecar(drives, bucket, key, version_id) do
    {:ok, rel} = Paths.object_rel(bucket, key, version_id)

    Enum.find_value(drives, fn drive ->
      path = Path.join([drive, rel, "meta.json"])
      if File.exists?(path), do: path |> File.read!() |> Maxio.Sidecar.decode!()
    end)
  end

  test "around_object_commit keeps bytes invisible and overrides version and metadata", %{
    drives: drives
  } do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)
    assert {:ok, _} = ErasureCoded.put("b", "k", "null", ["old"], o)

    checksum = %{"ChecksumSHA256" => "locked-checksum"}

    around_opts =
      Keyword.put(o, :around_object_commit, fn prepared, publish ->
        assert prepared.size == 3
        assert {:error, :enoent} = ErasureCoded.get("b", "k", "requested", nil, o)
        assert body(ErasureCoded, "b", "k", "null", o) == "old"
        publish.(version_id: "locked", object_meta: %{checksum: checksum})
      end)

    assert {:ok, %{version_id: "locked"}} =
             ErasureCoded.put("b", "k", "requested", ["new"], around_opts)

    assert body(ErasureCoded, "b", "k", "locked", o) == "new"
    assert body(ErasureCoded, "b", "k", "null", o) == "old"
    assert {:error, :enoent} = ErasureCoded.get("b", "k", "requested", nil, o)
    assert [%{"checksum" => ^checksum}] = sidecar(drives, "b", "k", "locked")["versions"]
  end

  test "around_object_commit abort discards only staging and preserves old final", %{
    drives: drives
  } do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)
    assert {:ok, _} = ErasureCoded.put("b", "k", "null", ["old"], o)

    abort_opts =
      Keyword.put(o, :around_object_commit, fn _prepared, _publish ->
        {:error, :denied}
      end)

    assert {:error, :denied} = ErasureCoded.put("b", "k", "null", ["new"], abort_opts)
    assert body(ErasureCoded, "b", "k", "null", o) == "old"
    assert Enum.all?(drives, &temp_empty?/1)
  end

  test "metadata callback exception restores replaced erasure bytes and sidecars", %{
    drives: drives
  } do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)

    old_opts = Keyword.put(o, :object_meta, %{content_type: "text/old"})
    assert {:ok, _old} = ErasureCoded.put("b", "k", "null", ["old"], old_opts)

    {:ok, rel} = Paths.object_rel("b", "k", "null")

    old_files =
      Map.new(drives, fn drive ->
        final_dir = Path.join(drive, rel)

        {drive,
         %{
           part: File.read!(Path.join(final_dir, "part.0")),
           meta: File.read!(Path.join(final_dir, "meta.json"))
         }}
      end)

    failing_opts =
      Keyword.put(o, :around_object_commit, fn _prepared, publish ->
        assert {:ok, %{version_id: "null"}} =
                 publish.(version_id: "null", object_meta: %{content_type: "text/new"})

        assert body(ErasureCoded, "b", "k", "null", o) == "new"
        raise "metadata commit failed"
      end)

    assert_raise RuntimeError, "metadata commit failed", fn ->
      ErasureCoded.put("b", "k", "null", ["new"], failing_opts)
    end

    assert body(ErasureCoded, "b", "k", "null", o) == "old"

    assert [%{"content_type" => "text/old"}] =
             sidecar(drives, "b", "k", "null")["versions"]

    Enum.each(drives, fn drive ->
      final_dir = Path.join(drive, rel)
      old = Map.fetch!(old_files, drive)
      assert File.read!(Path.join(final_dir, "part.0")) == old.part
      assert File.read!(Path.join(final_dir, "meta.json")) == old.meta
    end)

    assert Enum.all?(drives, &temp_empty?/1)
  end

  test "replacement quorum failure restores old final and removes staging", %{drives: drives} do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)
    assert {:ok, _} = ErasureCoded.put("b", "k", "null", ["old"], o)

    failed_opts = Keyword.put(o, :rename_fun, fn _src, _dst -> {:error, :eacces} end)

    assert {:error, :write_quorum} =
             ErasureCoded.put("b", "k", "null", ["new"], failed_opts)

    assert body(ErasureCoded, "b", "k", "null", o) == "old"
    assert Enum.all?(drives, &temp_empty?/1)
  end

  test "put persists precommit object_meta checksum into sidecar view", %{drives: drives} do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)
    body = "checksum body"

    checksum = %{
      "ChecksumSHA256" => Base.encode64(:crypto.hash(:sha256, body)),
      "ChecksumType" => "FULL_OBJECT"
    }

    hook_opts =
      Keyword.put(o, :before_object_commit, fn result ->
        assert result.size == byte_size(body)
        %{object_meta: %{checksum: checksum}}
      end)

    assert {:ok, _} = ErasureCoded.put("b", "checksum.txt", "null", [body], hook_opts)

    meta =
      Enum.find_value(drives, fn drive ->
        path = Path.join([drive, "b", "checksum.txt", "meta.json"])

        if File.exists?(path) do
          path |> File.read!() |> Maxio.Sidecar.decode!()
        end
      end)

    assert [%{"checksum" => ^checksum}] = meta["versions"]
  end

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
