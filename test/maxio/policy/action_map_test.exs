defmodule Maxio.Policy.ActionMapTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.ActionMap

  test "桶级动作 → :bucket" do
    assert ActionMap.for_action(:list_objects) == {"s3:ListBucket", :bucket}
    assert ActionMap.for_action(:list_objects_v2) == {"s3:ListBucket", :bucket}
    assert ActionMap.for_action(:head_bucket) == {"s3:ListBucket", :bucket}

    assert ActionMap.for_action(:list_multipart_uploads) ==
             {"s3:ListBucketMultipartUploads", :bucket}
  end

  test "对象级动作 → :object" do
    assert ActionMap.for_action(:get_object) == {"s3:GetObject", :object}
    assert ActionMap.for_action(:head_object) == {"s3:GetObject", :object}
    assert ActionMap.for_action(:get_object_attributes) == {"s3:GetObjectAttributes", :object}
    assert ActionMap.for_action(:upload_part) == {"s3:PutObject", :object}
    assert ActionMap.for_action(:list_parts) == {"s3:ListMultipartUploadParts", :object}
  end

  test "账户级 ListAllMyBuckets" do
    assert ActionMap.for_action(:list_buckets) == {"s3:ListAllMyBuckets", :account}
  end

  test "未知 action → nil" do
    assert ActionMap.for_action(:nonexistent) == nil
  end

  test "delete_objects 不再桶级粗门（授权移交 handler 逐 key）" do
    assert ActionMap.for_action(:delete_objects) == nil
  end
end
