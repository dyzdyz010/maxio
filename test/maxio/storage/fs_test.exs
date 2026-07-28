defmodule Maxio.Storage.FSTest do
  use ExUnit.Case, async: true

  alias Maxio.Storage.FS

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_fs_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp opts(dir), do: [data_dir: dir]

  # .tmp 残留断言用 File.ls 判空（B2 审查项 1 / B7 收口）：Windows 下 System.tmp_dir!()
  # 的反斜杠会被 :filelib.wildcard 当转义符，Path.wildcard 恒返回 []——假覆盖。
  defp tmp_entries(dir) do
    case File.ls(Path.join(dir, ".tmp")) do
      {:ok, entries} -> entries
      {:error, :enoent} -> []
    end
  end

  test "put 流式写入并返回 size 与 MD5 hex etag（无引号）", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    body = "Welcome to Amazon S3."
    chunks = ["Welcome ", "to Amazon ", "S3."]

    {:ok, %{size: size, etag: etag}} = FS.put("b", "k.txt", "null", chunks, opts(dir))

    assert size == byte_size(body)
    expected = :crypto.hash(:md5, body) |> Base.encode16(case: :lower)
    assert etag == expected
    refute String.contains?(etag, "\"")
  end

  test "get 全量返回完整内容", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put("b", "k", "null", ["hello ", "world"], opts(dir))

    {:ok, stream} = FS.get("b", "k", "null", nil, opts(dir))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == "hello world"
  end

  test "around object commit keeps staged bytes invisible until publish", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    assert {:ok, _old} = FS.put("b", "k", "null", ["old"], opts(dir))

    around = fn prepared, publish ->
      assert prepared.size == 3
      assert {:ok, old_stream} = FS.get("b", "k", "null", nil, opts(dir))
      assert IO.iodata_to_binary(Enum.to_list(old_stream)) == "old"

      publish.(version_id: "null", object_meta: %{content_type: "text/plain"})
    end

    put_opts = Keyword.put(opts(dir), :around_object_commit, around)

    assert {:ok, %{version_id: "null"}} =
             FS.put("b", "k", "staging-placeholder", ["new"], put_opts)

    assert {:ok, new_stream} = FS.get("b", "k", "null", nil, opts(dir))
    assert IO.iodata_to_binary(Enum.to_list(new_stream)) == "new"
    assert {:error, :enoent} = FS.get("b", "k", "staging-placeholder", nil, opts(dir))
  end

  test "around object commit abort cleans only staging and preserves old final", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    assert {:ok, _old} = FS.put("b", "k", "null", ["old"], opts(dir))

    put_opts =
      Keyword.put(opts(dir), :around_object_commit, fn _prepared, _publish ->
        {:error, :condition_failed}
      end)

    assert {:error, :condition_failed} = FS.put("b", "k", "null", ["new"], put_opts)
    assert {:ok, old_stream} = FS.get("b", "k", "null", nil, opts(dir))
    assert IO.iodata_to_binary(Enum.to_list(old_stream)) == "old"
    assert tmp_entries(dir) == []
  end

  test "metadata callback exception restores replaced bytes and sidecar", %{dir: dir} do
    o = opts(dir)
    :ok = FS.put_bucket("b", o)

    old_opts = Keyword.put(o, :object_meta, %{content_type: "text/old"})
    assert {:ok, _old} = FS.put("b", "k", "null", ["old"], old_opts)

    final_dir = Path.join([dir, "b", "k"])
    old_part = File.read!(Path.join(final_dir, "part.0"))
    old_meta = File.read!(Path.join(final_dir, "meta.json"))

    failing_opts =
      Keyword.put(o, :around_object_commit, fn _prepared, publish ->
        assert {:ok, %{version_id: "null"}} =
                 publish.(version_id: "null", object_meta: %{content_type: "text/new"})

        assert {:ok, current_stream} = FS.get("b", "k", "null", nil, o)
        assert IO.iodata_to_binary(Enum.to_list(current_stream)) == "new"
        raise "metadata commit failed"
      end)

    assert_raise RuntimeError, "metadata commit failed", fn ->
      FS.put("b", "k", "null", ["new"], failing_opts)
    end

    assert {:ok, restored_stream} = FS.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(restored_stream)) == "old"

    restored_meta =
      dir
      |> Path.join("b")
      |> Path.join("k")
      |> Path.join("meta.json")
      |> File.read!()
      |> Maxio.Sidecar.decode!()

    assert [%{"content_type" => "text/old"}] = restored_meta["versions"]
    assert File.read!(Path.join(final_dir, "part.0")) == old_part
    assert File.read!(Path.join(final_dir, "meta.json")) == old_meta
    assert tmp_entries(dir) == []
  end

  test "get Range 返回含端点的字节区间", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put("b", "k", "null", ["0123456789"], opts(dir))

    {:ok, stream} = FS.get("b", "k", "null", {0, 4}, opts(dir))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == "01234"

    {:ok, stream2} = FS.get("b", "k", "null", {2, 5}, opts(dir))
    assert IO.iodata_to_binary(Enum.to_list(stream2)) == "2345"
  end

  test "stat 返回 size，不存在返回 :enoent", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put("b", "k", "null", ["abc"], opts(dir))
    assert {:ok, %{size: 3}} = FS.stat("b", "k", "null", opts(dir))
    assert {:error, :enoent} = FS.stat("b", "missing", "null", opts(dir))
  end

  test "delete 删除对象，重复 get 报 :enoent", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put("b", "k", "null", ["abc"], opts(dir))
    assert :ok = FS.delete("b", "k", "null", opts(dir))
    assert {:error, :enoent} = FS.get("b", "k", "null", nil, opts(dir))
  end

  test "key 含斜杠落成子目录", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put("b", "a/b/c.txt", "null", ["deep"], opts(dir))
    assert {:ok, %{size: 4}} = FS.stat("b", "a/b/c.txt", "null", opts(dir))
    assert File.exists?(Path.join([dir, "b", "a", "b", "c.txt"]))
  end

  test "路径穿越被拒（key 含 ../）", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    assert {:error, :invalid_key} = FS.put("b", "../escape", "null", ["x"], opts(dir))
    assert {:error, :invalid_key} = FS.get("b", "../../etc/passwd", "null", nil, opts(dir))
  end

  test "put_bucket 建目录，delete_bucket 删空目录", %{dir: dir} do
    assert :ok = FS.put_bucket("nb", opts(dir))
    assert File.dir?(Path.join(dir, "nb"))
    assert :ok = FS.delete_bucket("nb", opts(dir))
    refute File.exists?(Path.join(dir, "nb"))
  end
end
