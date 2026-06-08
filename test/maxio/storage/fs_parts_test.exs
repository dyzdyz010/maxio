defmodule Maxio.Storage.FSPartsTest do
  use ExUnit.Case, async: true

  alias Maxio.Storage.FS

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_fs_parts_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp opts(dir), do: [data_dir: dir]

  test "put_part 流式写入并返回 size/etag(MD5 hex 无引号)/md5_raw(16字节)", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, r} = FS.put_part("b", "k", "uid1", 1, ["hel", "lo"], opts(dir))
    assert r.size == 5
    assert r.etag == (:crypto.hash(:md5, "hello") |> Base.encode16(case: :lower))
    assert r.md5_raw == :crypto.hash(:md5, "hello")
    assert byte_size(r.md5_raw) == 16
    refute String.contains?(r.etag, "\"")
  end

  test "get_part_stream 读回 part 字节", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put_part("b", "k", "uid1", 2, ["world"], opts(dir))
    {:ok, stream} = FS.get_part_stream("b", "k", "uid1", 2, opts(dir))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == "world"
  end

  test "assemble 按 part number 升序拼接成最终对象", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put_part("b", "big", "uid2", 2, ["DEF"], opts(dir))
    {:ok, _} = FS.put_part("b", "big", "uid2", 1, ["ABC"], opts(dir))
    {:ok, %{size: 6}} = FS.assemble("b", "big", "uid2", [1, 2], opts(dir))
    {:ok, stream} = FS.get("b", "big", "null", nil, opts(dir))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == "ABCDEF"
  end

  test "abort_upload 删除该 upload 所有 part 字节（幂等）", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put_part("b", "k", "uid3", 1, ["x"], opts(dir))
    assert :ok = FS.abort_upload("b", "k", "uid3", opts(dir))
    assert {:error, :enoent} = FS.get_part_stream("b", "k", "uid3", 1, opts(dir))
    assert :ok = FS.abort_upload("b", "k", "uid3", opts(dir))
  end
end
