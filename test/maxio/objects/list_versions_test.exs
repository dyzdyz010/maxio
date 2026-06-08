defmodule Maxio.Objects.ListVersionsTest do
  use Maxio.DataCase, async: true
  alias Maxio.{Buckets, Objects}

  setup do
    {:ok, _} = Buckets.create("vlb", "arn:aws:iam:::root")
    :ok
  end

  test "key 升序 + key 内 newest-first（version_id 降序），delete marker 交错" do
    {:ok, _} = Objects.put_version_with_id("vlb", "a.txt", "01", %{size: 1, etag: "x"})
    {:ok, _} = Objects.put_version_with_id("vlb", "a.txt", "02", %{size: 1, etag: "y"})
    {:ok, _} = Objects.put_version_with_id("vlb", "b.txt", "01", %{size: 1, etag: "z"})
    # b.txt 新增 delete marker（version_id 由 ULID 生成，>"01"）
    {:ok, _} = Objects.insert_delete_marker("vlb", "b.txt", "Enabled")

    res = Objects.list_object_versions("vlb", %{})
    seq = Enum.map(res.versions, fn o -> {o.key, o.version_id, o.is_delete_marker} end)

    # a.txt：02（latest）在 01 之前；b.txt：delete marker（latest, version_id 较大）在 01 之前。
    assert [{"a.txt", "02", false}, {"a.txt", "01", false} | rest] = seq
    assert [{"b.txt", dm_vid, true}, {"b.txt", "01", false}] = rest
    assert dm_vid > "01"
  end

  test "max-keys 截断 → 二维 next marker" do
    {:ok, _} = Objects.put_version_with_id("vlb", "a.txt", "02", %{size: 1, etag: "x"})
    {:ok, _} = Objects.put_version_with_id("vlb", "a.txt", "01", %{size: 1, etag: "y"})
    {:ok, _} = Objects.put_version_with_id("vlb", "b.txt", "01", %{size: 1, etag: "z"})

    res = Objects.list_object_versions("vlb", %{max_keys: 2})
    assert res.is_truncated
    assert res.next_key_marker == "a.txt"
    assert res.next_version_id_marker == "01"

    # 续页
    res2 =
      Objects.list_object_versions("vlb", %{
        max_keys: 2,
        key_marker: "a.txt",
        version_id_marker: "01"
      })

    keys = Enum.map(res2.versions, & &1.key)
    assert keys == ["b.txt"]
    refute res2.is_truncated
  end
end
