defmodule Maxio.BucketsTest do
  use Maxio.DataCase, async: true

  alias Maxio.Buckets

  describe "validate_name/1" do
    test "合法名通过" do
      assert :ok = Buckets.validate_name("my-bucket")
      assert :ok = Buckets.validate_name("a.b.c")
      assert :ok = Buckets.validate_name("abc")
      assert :ok = Buckets.validate_name(String.duplicate("a", 63))
    end

    test "长度越界被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("ab")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name(String.duplicate("a", 64))
    end

    test "非法字符被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("MyBucket")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("under_score")
    end

    test "首尾非字母数字被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("-abc")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("abc-")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name(".abc")
    end

    test "相邻点被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("a..b")
    end

    test "IPv4 形态被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("192.168.5.4")
    end

    test "保留前缀/后缀被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("xn--abc")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("sthree-abc")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("amzn-s3-demo-x")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("abc-s3alias")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("abc--x-s3")
    end
  end

  describe "create/2 + lookup/1 + list/0 + delete/1" do
    test "创建并查到桶" do
      assert {:ok, bucket} = Buckets.create("good-bucket", "arn:aws:iam:::root")
      assert bucket.name == "good-bucket"
      assert bucket.region == "us-east-1"
      assert {:ok, fetched} = Buckets.lookup("good-bucket")
      assert fetched.id == bucket.id
    end

    test "重复创建同名桶返回 already_owned" do
      {:ok, _} = Buckets.create("dup-bucket", "arn:aws:iam:::root")
      assert {:error, :already_owned} = Buckets.create("dup-bucket", "arn:aws:iam:::root")
    end

    test "非法桶名创建被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.create("Bad_Name", "arn:aws:iam:::root")
    end

    test "lookup 不存在返回 :not_found" do
      assert {:error, :not_found} = Buckets.lookup("nope")
    end

    test "list 列出所有桶（按名排序）" do
      {:ok, _} = Buckets.create("bucket-b", "arn:aws:iam:::root")
      {:ok, _} = Buckets.create("bucket-a", "arn:aws:iam:::root")
      names = Buckets.list() |> Enum.map(& &1.name)
      assert names == ["bucket-a", "bucket-b"]
    end

    test "delete 删空桶；非空桶报 not_empty" do
      {:ok, _bucket} = Buckets.create("del-bucket", "arn:aws:iam:::root")
      assert :ok = Buckets.delete("del-bucket")
      assert {:error, :not_found} = Buckets.lookup("del-bucket")

      {:ok, _} = Buckets.create("ne-bucket", "arn:aws:iam:::root")

      {:ok, _} =
        Maxio.Objects.put_metadata("ne-bucket", "k", %{
          size: 1,
          etag: "x",
          content_type: "text/plain"
        })

      assert {:error, :not_empty} = Buckets.delete("ne-bucket")
    end
  end
end
