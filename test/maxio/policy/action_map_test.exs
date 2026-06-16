defmodule Maxio.Policy.ActionMapTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.ActionMap

  test "桶级动作 → :bucket" do
    assert ActionMap.for_action(:list_objects) == {"s3:ListBucket", :bucket}
    assert ActionMap.for_action(:list_objects_v2) == {"s3:ListBucket", :bucket}
    assert ActionMap.for_action(:head_bucket) == {"s3:ListBucket", :bucket}

    assert ActionMap.for_action(:list_multipart_uploads) ==
             {"s3:ListBucketMultipartUploads", :bucket}

    assert ActionMap.for_action(:put_bucket_ownership_controls) ==
             {"s3:PutBucketOwnershipControls", :bucket}

    assert ActionMap.for_action(:get_bucket_ownership_controls) ==
             {"s3:GetBucketOwnershipControls", :bucket}

    assert ActionMap.for_action(:delete_bucket_ownership_controls) ==
             {"s3:PutBucketOwnershipControls", :bucket}

    assert ActionMap.for_action(:put_bucket_website) == {"s3:PutBucketWebsite", :bucket}
    assert ActionMap.for_action(:get_bucket_website) == {"s3:GetBucketWebsite", :bucket}
    assert ActionMap.for_action(:delete_bucket_website) == {"s3:DeleteBucketWebsite", :bucket}

    assert ActionMap.for_action(:put_bucket_request_payment) ==
             {"s3:PutBucketRequestPayment", :bucket}

    assert ActionMap.for_action(:get_bucket_request_payment) ==
             {"s3:GetBucketRequestPayment", :bucket}

    assert ActionMap.for_action(:put_bucket_accelerate_configuration) ==
             {"s3:PutAccelerateConfiguration", :bucket}

    assert ActionMap.for_action(:get_bucket_accelerate_configuration) ==
             {"s3:GetAccelerateConfiguration", :bucket}

    assert ActionMap.for_action(:put_bucket_logging) == {"s3:PutBucketLogging", :bucket}
    assert ActionMap.for_action(:get_bucket_logging) == {"s3:GetBucketLogging", :bucket}
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
