defmodule Maxio.Cluster.ListDirTest do
  use ExUnit.Case, async: true
  alias Maxio.Cluster.ShardServer

  setup do
    root = Path.join(System.tmp_dir!(), "ld_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp mkobj(root, rel) do
    dir = Path.join(root, rel)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "meta.json"), "{}")
  end

  defp mkdir(root, rel), do: File.mkdir_p!(Path.join(root, rel))

  test "list_dir 标记含 meta.json 的子目录为 object?，纯前缀目录非 object", %{root: root} do
    mkobj(root, "b/a.txt")
    mkobj(root, "b/c.txt")
    # 纯前缀（无 meta.json）
    mkdir(root, "b/photos")
    # photos 下的对象
    mkobj(root, "b/photos/x.png")
    {:ok, entries} = ShardServer.list_dir(Path.join(root, "b"), [])
    map = Map.new(entries, fn e -> {e.name, e.object?} end)
    assert map["a.txt"] == true
    assert map["c.txt"] == true
    assert map["photos"] == false
    # meta.json 文件本身不作为条目返回
    refute Map.has_key?(map, "meta.json")
  end

  test "list_dir 跳过内部前缀 .versions/.uploads/.tmp", %{root: root} do
    mkobj(root, "b/k.txt")
    mkdir(root, "b/.versions")
    mkdir(root, "b/.uploads")
    mkdir(root, "b/.tmp")
    {:ok, entries} = ShardServer.list_dir(Path.join(root, "b"), [])
    names = Enum.map(entries, & &1.name)
    assert "k.txt" in names
    refute ".versions" in names
    refute ".uploads" in names
    refute ".tmp" in names
  end

  test "list_dir 不存在的目录 -> {:ok, []}", %{root: root} do
    assert {:ok, []} = ShardServer.list_dir(Path.join(root, "nope"), [])
  end

  test "list_dir 返回 name 升序", %{root: root} do
    mkobj(root, "b/z")
    mkobj(root, "b/a")
    mkobj(root, "b/m")
    {:ok, entries} = ShardServer.list_dir(Path.join(root, "b"), [])
    assert Enum.map(entries, & &1.name) == ["a", "m", "z"]
  end

  test "list_dir can opt into layout file visibility for scanner evidence", %{root: root} do
    mkobj(root, "b/k.txt")
    File.write!(Path.join([root, "b", "part.0"]), "orphan")
    File.write!(Path.join([root, "b", "meta.json"]), "{}")

    {:ok, default_entries} = ShardServer.list_dir(Path.join(root, "b"), [])
    refute Enum.any?(default_entries, &(&1.name == "part.0"))
    refute Enum.any?(default_entries, &(&1.name == "meta.json"))

    {:ok, entries} = ShardServer.list_dir(Path.join(root, "b"), include_layout_files: true)
    by_name = Map.new(entries, fn entry -> {entry.name, entry} end)

    assert by_name["k.txt"].type == :dir
    assert by_name["part.0"].type == :file
    assert by_name["meta.json"].type == :file
  end
end
