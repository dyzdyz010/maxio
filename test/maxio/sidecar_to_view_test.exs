defmodule Maxio.SidecarToViewTest do
  use ExUnit.Case, async: true
  alias Maxio.Sidecar

  @entry %{
    "version_id" => "v-abc",
    "type" => "object",
    "is_latest" => true,
    "modtime" => 1_700_000_000_000_000_000,
    "generation" => 3,
    "size" => 11,
    "etag" => "\"d41d8cd98f00b204e9800998ecf8427e\"",
    "content_type" => "text/plain",
    "user_metadata" => %{"x-amz-meta-a" => "1"},
    "tags" => %{"k" => "v"},
    "sse" => %{"algo" => "AES256", "envelope" => %{"iv" => "..."}},
    "acl_canned" => "private",
    "storage_class" => "STANDARD"
  }

  test "to_view/3 产出读路径可比视图（键与 Object 字段对齐）" do
    v = Sidecar.to_view("b", "k", @entry)
    assert v.version_id == "v-abc"
    assert v.size == 11
    assert v.etag == "\"d41d8cd98f00b204e9800998ecf8427e\""
    assert v.content_type == "text/plain"
    assert v.metadata == %{"x-amz-meta-a" => "1"}
    assert v.tags == %{"k" => "v"}
    assert v.storage_class == "STANDARD"
    assert v.acl_canned == "private"
    assert v.is_latest == true
    assert v.is_delete_marker == false
    assert v.sse_algorithm == "AES256"
  end

  test "delete_marker entry -> is_delete_marker true" do
    dm = %{"version_id" => "v-dm", "type" => "delete_marker", "modtime" => 1, "generation" => 0}
    v = Sidecar.to_view("b", "k", dm)
    assert v.is_delete_marker == true
    assert v.version_id == "v-dm"
  end
end
