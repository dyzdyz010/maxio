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
