defmodule Maxio.S3.DispatcherTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.Dispatcher

  defp keys(list), do: MapSet.new(list)

  test "service GET → list_buckets" do
    assert {:ok, :list_buckets} = Dispatcher.resolve(:service, "GET", keys([]))
  end

  test "bucket PUT → create_bucket" do
    assert {:ok, :create_bucket} = Dispatcher.resolve(:bucket, "PUT", keys([]))
  end

  test "bucket DELETE → delete_bucket" do
    assert {:ok, :delete_bucket} = Dispatcher.resolve(:bucket, "DELETE", keys([]))
  end

  test "bucket HEAD → head_bucket" do
    assert {:ok, :head_bucket} = Dispatcher.resolve(:bucket, "HEAD", keys([]))
  end

  test "bucket GET list-type=2 → list_objects_v2" do
    assert {:ok, :list_objects_v2} =
             Dispatcher.resolve(:bucket, "GET", %{"list-type" => "2"})
  end

  test "bucket GET list-type other than 2 defaults to list_objects" do
    assert {:ok, :list_objects} =
             Dispatcher.resolve(:bucket, "GET", %{"list-type" => "1"})
  end

  test "bucket GET 无 list-type 默认 → list_objects" do
    assert {:ok, :list_objects} = Dispatcher.resolve(:bucket, "GET", keys([]))
  end

  test "bucket GET ?location → get_bucket_location" do
    assert {:ok, :get_bucket_location} = Dispatcher.resolve(:bucket, "GET", keys(["location"]))
  end

  test "object PUT → put_object" do
    assert {:ok, :put_object} = Dispatcher.resolve(:object, "PUT", keys([]))
  end

  test "object GET → get_object" do
    assert {:ok, :get_object} = Dispatcher.resolve(:object, "GET", keys([]))
  end

  test "object GET ?attributes → get_object_attributes" do
    assert {:ok, :get_object_attributes} =
             Dispatcher.resolve(:object, "GET", keys(["attributes"]))

    assert {:error, :method_not_allowed} =
             Dispatcher.resolve(:bucket, "GET", keys(["attributes"]))
  end

  test "object HEAD → head_object" do
    assert {:ok, :head_object} = Dispatcher.resolve(:object, "HEAD", keys([]))
  end

  test "object DELETE → delete_object" do
    assert {:ok, :delete_object} = Dispatcher.resolve(:object, "DELETE", keys([]))
  end

  test "multipart 子资源 → 具体动作（M2-5 升级，原 not_implemented）" do
    assert {:ok, :create_multipart_upload} =
             Dispatcher.resolve(:object, "POST", keys(["uploads"]))

    assert {:ok, :complete_multipart_upload} =
             Dispatcher.resolve(:object, "POST", keys(["uploadid"]))

    assert {:ok, :upload_part} =
             Dispatcher.resolve(:object, "PUT", keys(["uploadid", "partnumber"]))

    assert {:ok, :abort_multipart_upload} =
             Dispatcher.resolve(:object, "DELETE", keys(["uploadid"]))

    assert {:ok, :list_parts} = Dispatcher.resolve(:object, "GET", keys(["uploadid"]))

    assert {:ok, :list_multipart_uploads} =
             Dispatcher.resolve(:bucket, "GET", keys(["uploads"]))
  end

  test "DeleteObjects 子资源 → delete_objects（M2-6 实现）" do
    assert {:ok, :delete_objects} = Dispatcher.resolve(:bucket, "POST", keys(["delete"]))
  end

  test "PublicAccessBlock 子资源 → bucket-level actions" do
    assert {:ok, :put_public_access_block} =
             Dispatcher.resolve(:bucket, "PUT", keys(["publicaccessblock"]))

    assert {:ok, :get_public_access_block} =
             Dispatcher.resolve(:bucket, "GET", keys(["publicaccessblock"]))

    assert {:ok, :delete_public_access_block} =
             Dispatcher.resolve(:bucket, "DELETE", keys(["publicaccessblock"]))

    assert {:error, :method_not_allowed} =
             Dispatcher.resolve(:object, "GET", keys(["publicaccessblock"]))
  end

  test "OwnershipControls 子资源 → bucket-level actions" do
    assert {:ok, :put_bucket_ownership_controls} =
             Dispatcher.resolve(:bucket, "PUT", keys(["ownershipcontrols"]))

    assert {:ok, :get_bucket_ownership_controls} =
             Dispatcher.resolve(:bucket, "GET", keys(["ownershipcontrols"]))

    assert {:ok, :delete_bucket_ownership_controls} =
             Dispatcher.resolve(:bucket, "DELETE", keys(["ownershipcontrols"]))

    assert {:error, :method_not_allowed} =
             Dispatcher.resolve(:object, "GET", keys(["ownershipcontrols"]))
  end

  test "无匹配方法 → method_not_allowed" do
    assert {:error, :method_not_allowed} = Dispatcher.resolve(:service, "POST", keys([]))
    assert {:error, :method_not_allowed} = Dispatcher.resolve(:object, "POST", keys([]))
  end
end
