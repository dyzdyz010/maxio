defmodule Maxio.Cluster.PathsTest do
  use ExUnit.Case, async: true
  alias Maxio.Cluster.Paths

  test "null 版本对象相对路径 = bucket/key" do
    assert {:ok, "b/k"} = Paths.object_rel("b", "k", "null")
    assert {:ok, "b/a/b/c"} = Paths.object_rel("b", "a/b/c", "null")
  end

  test "版本化对象相对路径 = .versions/bucket/key/version_id" do
    assert {:ok, ".versions/b/k/01ABC"} = Paths.object_rel("b", "k", "01ABC")
  end

  test "路径穿越/空 key 拒绝" do
    assert {:error, :invalid_key} = Paths.object_rel("b", "../x", "null")
    assert {:error, :invalid_key} = Paths.object_rel("b", "a/./b", "null")
    assert {:error, :invalid_key} = Paths.object_rel("b", "", "null")
  end

  test "part / upload 相对路径" do
    assert ".uploads/b/u1/2" = Paths.part_rel("b", "u1", 2)
    assert ".uploads/b/u1" = Paths.upload_rel("b", "u1")
  end
end
