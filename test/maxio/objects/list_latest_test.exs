defmodule Maxio.Objects.ListLatestTest do
  use Maxio.DataCase, async: true
  alias Maxio.{Buckets, Objects}

  setup do
    {:ok, _} = Buckets.create("latb", "arn:aws:iam:::root")
    :ok
  end

  test "ListObjectsV2 只返回 latest 非 delete-marker" do
    # 两版本同 key（Enabled 语义模拟）：旧版本 is_latest=false，新版本 latest。
    {:ok, _} = Objects.put_version_with_id("latb", "k.txt", "01OLD", %{size: 2, etag: "a"})
    {:ok, _} = Objects.put_version_with_id("latb", "k.txt", "02NEW", %{size: 3, etag: "b"})
    # delete marker 当前的另一 key
    {:ok, _} = Objects.put_version_with_id("latb", "d.txt", "01D", %{size: 1, etag: "c"})
    {:ok, _} = Objects.insert_delete_marker("latb", "d.txt", "Enabled")

    res = Objects.list_objects_v2("latb", %{})
    keys = Enum.map(res.objects, & &1.key)
    assert keys == ["k.txt"]
    assert res.key_count == 1
  end
end
