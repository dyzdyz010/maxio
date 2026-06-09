defmodule Maxio.SidecarTest do
  use ExUnit.Case, async: true
  alias Maxio.Sidecar

  @v1 %{
    "ec" => %{"k" => 4, "m" => 2, "block_size" => 1024, "algo" => "blake3-256"},
    "size" => 10,
    "etag" => "abc",
    "sha256" => "def",
    "parts" => [%{"part" => 0, "size" => 10}],
    "shards" => [%{"drive" => 0, "shard_file_size" => 4, "block_hashes" => ["aa"]}]
  }

  describe "migrate_v1/2" do
    test "wraps v1 meta into maxio/2 versions array, preserving ec/shards" do
      v2 = Sidecar.migrate_v1(@v1, version_id: "null", modtime: 1, content_type: "text/plain")
      assert v2["format"] == "maxio/2"
      assert v2["ec"] == @v1["ec"]
      assert v2["shards"] == @v1["shards"]
      [ver] = v2["versions"]
      assert ver["version_id"] == "null"
      assert ver["type"] == "object"
      assert ver["is_latest"] == true
      assert ver["etag"] == "abc"
      assert ver["content_type"] == "text/plain"
    end

    test "preserves the full set of durable v1 fields verbatim (ec/shards/size/etag/sha256/parts)" do
      v2 = Sidecar.migrate_v1(@v1, version_id: "null", modtime: 1)
      assert v2["ec"] == @v1["ec"]
      assert v2["shards"] == @v1["shards"]
      assert v2["size"] == @v1["size"]
      assert v2["etag"] == @v1["etag"]
      assert v2["sha256"] == @v1["sha256"]
      assert v2["parts"] == @v1["parts"]
    end

    test "idempotent on already-v2 meta" do
      v2 = Sidecar.migrate_v1(@v1, version_id: "null", modtime: 1)
      assert Sidecar.migrate_v1(v2, version_id: "null", modtime: 99) == v2
    end

    test "defaults version_id to \"null\", type object, latest true, standard class" do
      v2 = Sidecar.migrate_v1(@v1, modtime: 7)
      [ver] = v2["versions"]
      assert ver["version_id"] == "null"
      assert ver["type"] == "object"
      assert ver["is_latest"] == true
      assert ver["storage_class"] == "STANDARD"
      assert ver["acl_canned"] == "private"
      assert ver["content_type"] == "binary/octet-stream"
    end
  end

  describe "encode/decode round-trip" do
    test "encode -> decode preserves a v2 sidecar exactly" do
      v2 =
        @v1
        |> Sidecar.migrate_v1(version_id: "v1", modtime: 5, content_type: "text/plain")
        |> Sidecar.put_version_entry(%{
          "version_id" => "v2",
          "type" => "object",
          "modtime" => 9,
          "size" => 20,
          "etag" => "ghi",
          "content_type" => "application/json"
        })

      bin = Sidecar.encode(v2)
      assert is_binary(bin)
      assert Sidecar.decode!(bin) == v2
    end
  end

  describe "latest/find_version" do
    test "latest picks max-modtime; find_version by id" do
      v2 = Sidecar.migrate_v1(@v1, version_id: "v1", modtime: 5)

      v2 =
        Sidecar.put_version_entry(v2, %{
          "version_id" => "v2",
          "type" => "delete_marker",
          "modtime" => 9,
          "size" => 0,
          "etag" => ""
        })

      assert Sidecar.latest(v2)["version_id"] == "v2"
      assert Sidecar.find_version(v2, "v1")["type"] == "object"
      assert Sidecar.find_version(v2, "missing") == nil
    end

    test "latest skips delete markers when an object version exists at lower modtime" do
      v2 = Sidecar.migrate_v1(@v1, version_id: "obj", modtime: 5)

      v2 =
        Sidecar.put_version_entry(v2, %{
          "version_id" => "dm",
          "type" => "delete_marker",
          "modtime" => 9,
          "size" => 0,
          "etag" => ""
        })

      # latest_version: newest by modtime regardless of type (S3 head returns 404 on DM)
      assert Sidecar.latest(v2)["version_id"] == "dm"
      # latest_object: newest non-delete-marker (max modtime object version)
      assert Sidecar.latest_object(v2)["version_id"] == "obj"
    end

    test "latest_object returns nil when only delete markers exist" do
      v2 =
        %{"format" => "maxio/2", "versions" => []}
        |> Sidecar.put_version_entry(%{
          "version_id" => "dm",
          "type" => "delete_marker",
          "modtime" => 3,
          "size" => 0,
          "etag" => ""
        })

      assert Sidecar.latest_object(v2) == nil
      assert Sidecar.latest(v2)["version_id"] == "dm"
    end

    test "latest is nil on empty sidecar" do
      assert Sidecar.latest(%{"format" => "maxio/2", "versions" => []}) == nil
      assert Sidecar.latest(%{}) == nil
    end

    test "put_version_entry overwrites same version_id and recomputes is_latest" do
      v2 = Sidecar.migrate_v1(@v1, version_id: "v1", modtime: 5)

      v2 =
        Sidecar.put_version_entry(v2, %{
          "version_id" => "v2",
          "type" => "object",
          "modtime" => 9,
          "size" => 1,
          "etag" => "y"
        })

      # overwrite v1 with a newer modtime -> v1 becomes latest
      v2 =
        Sidecar.put_version_entry(v2, %{
          "version_id" => "v1",
          "type" => "object",
          "modtime" => 20,
          "size" => 2,
          "etag" => "z"
        })

      assert length(v2["versions"]) == 2
      assert Sidecar.latest(v2)["version_id"] == "v1"
      assert Sidecar.find_version(v2, "v1")["etag"] == "z"
      assert Sidecar.find_version(v2, "v1")["is_latest"] == true
      assert Sidecar.find_version(v2, "v2")["is_latest"] == false
    end
  end

  describe "signature/1" do
    test "stable for identical bodies, differs on change" do
      e1 = %{"version_id" => "v", "modtime" => 1, "generation" => 0, "etag" => "a"}
      e2 = %{"version_id" => "v", "modtime" => 1, "generation" => 0, "etag" => "a"}
      e3 = Map.put(e1, "generation", 1)
      assert Sidecar.signature(e1) == Sidecar.signature(e2)
      assert Sidecar.signature(e1) != Sidecar.signature(e3)
    end

    test "ignores non-canonical fields (is_latest is a derived cache, not part of identity)" do
      e1 = %{"version_id" => "v", "modtime" => 1, "generation" => 0, "etag" => "a"}
      e2 = Map.put(e1, "is_latest", true)
      assert Sidecar.signature(e1) == Sidecar.signature(e2)
    end

    test "differs on etag change" do
      e1 = %{"version_id" => "v", "modtime" => 1, "generation" => 0, "etag" => "a"}
      e2 = Map.put(e1, "etag", "b")
      assert Sidecar.signature(e1) != Sidecar.signature(e2)
    end
  end

  describe "to_object_attrs/3" do
    test "maps a version entry to Maxio.Objects index attrs" do
      v2 = Sidecar.migrate_v1(@v1, version_id: "v1", modtime: 5, content_type: "text/plain")
      [entry] = v2["versions"]
      attrs = Sidecar.to_object_attrs("b", "k", entry)
      assert attrs.size == 10
      assert attrs.etag == "abc"
      assert attrs.content_type == "text/plain"
      assert attrs.storage_class == "STANDARD"
      assert attrs.acl_canned == "private"
      assert attrs.version_id == "v1"
      assert attrs.is_latest == true
      assert attrs.is_delete_marker == false
    end

    test "delete marker entry maps is_delete_marker true" do
      attrs =
        Sidecar.to_object_attrs("b", "k", %{
          "version_id" => "dm",
          "type" => "delete_marker",
          "modtime" => 9,
          "etag" => ""
        })

      assert attrs.is_delete_marker == true
      assert attrs.version_id == "dm"
    end
  end
end
