defmodule Maxio.ObjectsTest do
  use Maxio.DataCase, async: true

  alias Maxio.{Buckets, Objects}

  setup do
    {:ok, _} = Buckets.create("lb-test", "arn:aws:iam:::root")
    :ok
  end

  defp put(key),
    do: Objects.put_metadata("lb-test", key, %{size: 1, etag: "e", content_type: "text/plain"})

  test "put/get/delete 元数据往返" do
    {:ok, obj} = put("a.txt")
    assert obj.key == "a.txt"
    assert {:ok, fetched} = Objects.get_metadata("lb-test", "a.txt")
    assert fetched.etag == "e"
    assert :ok = Objects.delete_metadata("lb-test", "a.txt")
    assert {:error, :not_found} = Objects.get_metadata("lb-test", "a.txt")
  end

  test "同 key 再 put 覆盖（upsert）" do
    {:ok, _} = put("k")

    {:ok, _} =
      Objects.put_metadata("lb-test", "k", %{size: 99, etag: "e2", content_type: "text/plain"})

    {:ok, obj} = Objects.get_metadata("lb-test", "k")
    assert obj.size == 99
    assert obj.etag == "e2"
  end

  test "put 到不存在桶报 no_such_bucket" do
    assert {:error, :no_such_bucket} = Objects.put_metadata("nope", "k", %{size: 1, etag: "e"})
  end

  test "list_objects_v2 基础：返回全部对象，未截断" do
    for k <- ~w(a b c), do: put(k)
    res = Objects.list_objects_v2("lb-test", %{})
    assert Enum.map(res.objects, & &1.key) == ["a", "b", "c"]
    assert res.is_truncated == false
    assert res.next_continuation_token == nil
    assert res.key_count == 3
  end

  test "list_objects_v2 prefix 过滤" do
    for k <- ~w(photos/1 photos/2 docs/1), do: put(k)
    res = Objects.list_objects_v2("lb-test", %{prefix: "photos/"})
    assert Enum.map(res.objects, & &1.key) == ["photos/1", "photos/2"]
  end

  test "list_objects_v2 delimiter 折叠为 CommonPrefixes" do
    for k <- ~w(photos/2006/a photos/2006/b photos/2007/c top.txt), do: put(k)
    res = Objects.list_objects_v2("lb-test", %{prefix: "photos/", delimiter: "/"})
    assert res.objects == []
    assert Enum.sort(res.common_prefixes) == ["photos/2006/", "photos/2007/"]
    assert res.key_count == 2
  end

  test "list_objects_v2 max_keys 截断 + continuation_token 续接" do
    for k <- ~w(a b c d e), do: put(k)
    res1 = Objects.list_objects_v2("lb-test", %{max_keys: 2})
    assert Enum.map(res1.objects, & &1.key) == ["a", "b"]
    assert res1.is_truncated == true
    assert res1.next_continuation_token == "b"

    res2 =
      Objects.list_objects_v2("lb-test", %{
        max_keys: 2,
        continuation_token: res1.next_continuation_token
      })

    assert Enum.map(res2.objects, & &1.key) == ["c", "d"]
    assert res2.is_truncated == true

    res3 =
      Objects.list_objects_v2("lb-test", %{
        max_keys: 2,
        continuation_token: res2.next_continuation_token
      })

    assert Enum.map(res3.objects, & &1.key) == ["e"]
    assert res3.is_truncated == false
  end

  test "list_objects_v2 start_after 跳过游标之前的 key" do
    for k <- ~w(a b c d), do: put(k)
    res = Objects.list_objects_v2("lb-test", %{start_after: "b"})
    assert Enum.map(res.objects, & &1.key) == ["c", "d"]
  end
end
