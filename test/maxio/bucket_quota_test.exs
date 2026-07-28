defmodule Maxio.BucketQuotaTest do
  use Maxio.DataCase, async: false

  alias Maxio.{BucketQuota, BucketConfigs, Buckets, Objects}
  alias Maxio.S3.Error

  setup do
    {:ok, _bucket} = Buckets.create("quota-bucket", "arn:aws:iam:::root")
    :ok
  end

  test "stores and deletes hard quota config" do
    assert :none = BucketQuota.get("quota-bucket")

    assert :ok = BucketQuota.put_hard("quota-bucket", 10)
    assert {:ok, %{"type" => "hard", "size_bytes" => 10}} = BucketQuota.get("quota-bucket")

    assert {:ok, %{"type" => "hard", "size_bytes" => 10}} =
             BucketConfigs.get("quota-bucket", :quota)

    assert :ok = BucketQuota.delete("quota-bucket")
    assert :none = BucketQuota.get("quota-bucket")
  end

  test "rejects invalid quota sizes" do
    assert {:error, :invalid_quota} = BucketQuota.put_hard("quota-bucket", 0)
    assert {:error, :invalid_quota} = BucketQuota.put_hard("quota-bucket", -1)
    assert {:error, :invalid_quota} = BucketQuota.validate_size("10")
  end

  test "enforces quota by projected non-delete-marker version bytes" do
    assert :ok = BucketQuota.put_hard("quota-bucket", 5)

    assert {:ok, _object} =
             Objects.put_version_with_id("quota-bucket", "a.txt", "null", %{
               size: 4,
               etag: "etag-a"
             })

    assert BucketQuota.usage("quota-bucket") == 4

    assert {:ok, _object} =
             Objects.put_version_with_id("quota-bucket", "a.txt", "null", %{
               size: 5,
               etag: "etag-a2"
             })

    assert BucketQuota.usage("quota-bucket") == 5

    assert_raise Error, ~r/Bucket quota exceeded/, fn ->
      Objects.put_version_with_id("quota-bucket", "a.txt", "v2", %{size: 1, etag: "etag-v2"})
    end

    assert BucketQuota.usage("quota-bucket") == 5
  end
end
