defmodule Maxio.BucketsTest do
  use Maxio.DataCase, async: true

  alias Maxio.Buckets
  alias Maxio.Cluster.Notify

  describe "validate_creatable_name/1" do
    test "合法名通过" do
      assert :ok = Buckets.validate_creatable_name("my-bucket")
      assert :ok = Buckets.validate_creatable_name("a.b.c")
      assert :ok = Buckets.validate_creatable_name("abc")
      assert :ok = Buckets.validate_creatable_name(String.duplicate("a", 63))
    end

    test "长度越界被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_creatable_name("ab")

      assert {:error, :invalid_bucket_name} =
               Buckets.validate_creatable_name(String.duplicate("a", 64))
    end

    test "非法字符被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_creatable_name("MyBucket")
      assert {:error, :invalid_bucket_name} = Buckets.validate_creatable_name("under_score")
    end

    test "首尾非字母数字被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_creatable_name("-abc")
      assert {:error, :invalid_bucket_name} = Buckets.validate_creatable_name("abc-")
      assert {:error, :invalid_bucket_name} = Buckets.validate_creatable_name(".abc")
    end

    test "相邻点被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_creatable_name("a..b")
    end

    test "IPv4 形态被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_creatable_name("192.168.5.4")
    end

    test "保留前缀/后缀被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_creatable_name("xn--abc")
      assert {:error, :invalid_bucket_name} = Buckets.validate_creatable_name("sthree-abc")
      assert {:error, :invalid_bucket_name} = Buckets.validate_creatable_name("amzn-s3-demo-x")
      assert {:error, :invalid_bucket_name} = Buckets.validate_creatable_name("abc-s3alias")
      assert {:error, :invalid_bucket_name} = Buckets.validate_creatable_name("abc--x-s3")
    end
  end

  describe "validate_addressable_name/1（写路径用的**语法**校验，不继承注册期规则）" do
    test "语法非法的名字同样被拒" do
      for name <- [
            "ab",
            String.duplicate("a", 64),
            "MyBucket",
            "under_score",
            "-abc",
            "abc-",
            ".abc",
            "a..b",
            "",
            42
          ] do
        assert {:error, :invalid_bucket_name} = Buckets.validate_addressable_name(name)
      end
    end

    test "注册期才拒绝的名字在写路径上必须是合法的（存量桶不得被静默降级成只读）" do
      # 这批名字今天建不出来，但**可能早于规则就已经存在**并写满数据；写路径若继续用
      # 建桶准入校验，它们的每一次 PutObject 都会在 journal changeset 上失败（500）。
      for name <- ["minio", "192.168.5.4", "xn--abc", "sthree-abc", "abc-s3alias"] do
        assert Buckets.validate_addressable_name(name) == :ok
        assert Buckets.validate_creatable_name(name) == {:error, :invalid_bucket_name}
      end
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

    test "bucket metadata mutations broadcast invalidation" do
      :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())

      assert {:ok, _bucket} = Buckets.create("notify-bucket", "arn:aws:iam:::root")
      assert_receive {:bucket_metadata_changed, "notify-bucket"}

      assert :ok = Buckets.put_acl("notify-bucket", "private")
      assert_receive {:bucket_metadata_changed, "notify-bucket"}

      assert :ok = Buckets.put_tags("notify-bucket", [{"env", "test"}])
      assert_receive {:bucket_metadata_changed, "notify-bucket"}

      assert :ok = Buckets.put_versioning("notify-bucket", "Enabled", nil)
      assert_receive {:bucket_metadata_changed, "notify-bucket"}

      assert :ok = Buckets.delete("notify-bucket")
      assert_receive {:bucket_metadata_changed, "notify-bucket"}
    end
  end
end
