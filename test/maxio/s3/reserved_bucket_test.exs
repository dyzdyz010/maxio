defmodule Maxio.S3.ReservedBucketTest do
  @moduledoc """
  `minio` 保留桶名 + 存量同名桶的启动期影子化审计（设计 D8）。

  `/minio/...` 一旦被 health / admin / metrics plug 认领，path-style 下同名桶的对应 key
  就永久不可达。因此：新建必须硬拒；存量必须在启动时结构化告警并**逐 key 列出丢了什么**
  （只报告、不删除、不阻止启动——铁律 3 绝不静默）。
  """
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maxio.Buckets
  alias Maxio.Buckets.Bucket
  alias Maxio.Objects
  alias Maxio.Repo
  alias Maxio.S3.Endpoint
  alias Maxio.S3.ReservedBucketAudit
  alias Maxio.Test.SigV4Request

  @owner "arn:aws:iam:::root"
  @data_dir Path.join(System.tmp_dir!(), "maxio_reserved_bucket")

  defp signed(method, path, opts \\ []), do: SigV4Request.signed_conn(method, path, opts)
  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "minio is a reserved bucket name" do
    assert Buckets.validate_creatable_name("minio") == {:error, :invalid_bucket_name}
    assert Buckets.create("minio", @owner) == {:error, :invalid_bucket_name}
    # 只保留精确名，绝不吞掉合法的相邻名字
    assert Buckets.validate_creatable_name("minio-data") == :ok
    assert Buckets.validate_creatable_name("myminio") == :ok
  end

  test "CreateBucket on the reserved name returns InvalidBucketName" do
    conn =
      :put
      |> SigV4Request.signed_conn("/minio")
      |> Endpoint.call(Endpoint.init([]))

    assert conn.status == 400
    assert conn.resp_body =~ "<Code>InvalidBucketName</Code>"
  end

  describe "startup audit for a pre-existing minio bucket" do
    setup do
      {:ok, bucket} =
        %Bucket{}
        |> Bucket.changeset(%{name: "minio", owner: @owner})
        |> Repo.insert()

      for key <- [
            "admin/v3/info",
            "health/live",
            "health/ready",
            "v2/metrics/cluster",
            "metrics/v3/cluster",
            "docs/readme.txt"
          ] do
        {:ok, _} =
          Objects.put_version_with_id("minio", key, "null", %{size: 1, etag: "etag-#{key}"})
      end

      %{bucket: bucket}
    end

    test "shadowed keys are reported per key, reachable keys are not" do
      keys = ReservedBucketAudit.shadowed_keys()

      assert {"minio", "admin/v3/info"} in keys
      assert {"minio", "health/live"} in keys
      assert {"minio", "health/ready"} in keys
      assert {"minio", "v2/metrics/cluster"} in keys
      assert {"minio", "metrics/v3/cluster"} in keys
      refute {"minio", "docs/readme.txt"} in keys

      assert ReservedBucketAudit.shadowed_key_counts() == %{
               total: 5,
               by_bucket: %{"minio" => 5}
             }
    end

    test "the report never truncates silently: the total is exact and the cap is spelled out" do
      # 逐 key 列举必须有界（日志行不是数据导出通道），但"被截断"这件事本身绝不能被藏起来
      # ——一个以诚实披露为唯一目的的审计出现静默截断是自相矛盾（I1）。
      log = capture_log(fn -> assert ReservedBucketAudit.audit(report_limit: 2) == :ok end)

      assert log =~ "shadow 5 object key(s)"
      assert log =~ "+3 more not listed here"
      assert log =~ "the count above is exact"
      assert log =~ "mix maxio.reserved_bucket.purge"
    end

    test "audit logs a structured error naming the shadowed keys and does not delete anything" do
      log = capture_log(fn -> assert ReservedBucketAudit.audit() == :ok end)

      assert log =~ "minio"
      assert log =~ "admin/v3/info"
      assert log =~ "metrics/v3/cluster"
      refute log =~ "docs/readme.txt"

      assert {:ok, _} = Buckets.lookup("minio")
      assert {:ok, _} = Objects.get_metadata("minio", "admin/v3/info")
    end
  end

  describe "a pre-existing minio bucket stays a fully writable S3 bucket" do
    setup do
      File.rm_rf(@data_dir)
      File.mkdir_p!(@data_dir)
      prev = Application.get_env(:maxio, :s3)
      Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

      on_exit(fn ->
        Application.put_env(:maxio, :s3, prev)
        File.rm_rf(@data_dir)
      end)

      {:ok, bucket} =
        %Bucket{}
        |> Bucket.changeset(%{name: "minio", owner: @owner})
        |> Repo.insert()

      %{bucket: bucket}
    end

    test "PutObject on a non-claimed key goes through the real handler/journal path" do
      # 走真实写路径（handler → ObjectMutation.Journal → ObjectEpoch）；绝不用
      # Objects.put_version_with_id 直插元数据——那正好绕开本用例要守的 journal 校验。
      put = call(signed(:put, "/minio/docs/new2.txt", body: "hello reserved bucket"))

      assert put.status == 200, "PutObject returned #{put.status}: #{put.resp_body}"

      get = call(signed(:get, "/minio/docs/new2.txt"))
      assert get.status == 200
      assert get.resp_body == "hello reserved bucket"
    end

    test "CopyObject inside the pre-existing reserved bucket also works" do
      assert call(signed(:put, "/minio/docs/src.txt", body: "copy me")).status == 200

      copy =
        call(
          signed(:put, "/minio/docs/dst.txt",
            headers: [{"x-amz-copy-source", "/minio/docs/src.txt"}]
          )
        )

      assert copy.status == 200, "CopyObject returned #{copy.status}: #{copy.resp_body}"
      assert call(signed(:get, "/minio/docs/dst.txt")).resp_body == "copy me"
    end

    test "claimed keys can be purged so the pre-existing bucket can finally be deleted" do
      # 影子化的 key 在 path-style 下既读不到也删不掉（DELETE 被保留面吃掉），
      # 于是 DeleteBucket 永远 BucketNotEmpty。运维必须有一条不改 DNS 的清理通路。
      assert call(signed(:put, "/minio/docs/keep.txt", body: "keep")).status == 200

      {:ok, _} =
        Objects.put_version_with_id("minio", "admin/v3/info", "null", %{size: 1, etag: "e1"})

      assert {:ok, summary} = ReservedBucketAudit.purge(confirm_delete: true)
      assert summary.deleted == 1
      assert ReservedBucketAudit.shadowed_keys() == []

      # 未被认领的普通 key 绝不能被顺手删掉
      assert call(signed(:get, "/minio/docs/keep.txt")).status == 200

      assert call(signed(:delete, "/minio/docs/keep.txt")).status == 204
      assert call(signed(:delete, "/minio")).status == 204
    end

    test "purge without an explicit confirmation is a dry run that deletes nothing" do
      {:ok, _} =
        Objects.put_version_with_id("minio", "health/live", "null", %{size: 1, etag: "e1"})

      assert {:ok, summary} = ReservedBucketAudit.purge([])
      assert summary.dry_run
      assert summary.matched == 1
      assert summary.deleted == 0
      assert ReservedBucketAudit.shadowed_keys() == [{"minio", "health/live"}]
    end

    test "the CLI is the operator-facing exit: dry run lists, nothing is deleted" do
      {:ok, _} =
        Objects.put_version_with_id("minio", "health/live", "null", %{size: 1, etag: "e1"})

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Maxio.ReservedBucket.Purge.run(["--dry-run"])
        end)

      assert out =~ "dry_run=true"
      assert out =~ "shadowed bucket=minio key=health/live"
      assert out =~ "--confirm-delete"
      assert ReservedBucketAudit.shadowed_keys() == [{"minio", "health/live"}]
    end

    test "the CLI refuses to guess whether the operator meant to delete" do
      assert_raise Mix.Error, ~r/--dry-run or --confirm-delete is required/, fn ->
        Mix.Tasks.Maxio.ReservedBucket.Purge.run([])
      end

      assert_raise Mix.Error, ~r/mutually exclusive/, fn ->
        Mix.Tasks.Maxio.ReservedBucket.Purge.run(["--dry-run", "--confirm-delete"])
      end
    end
  end

  test "audit stays silent when no reserved bucket exists" do
    assert ReservedBucketAudit.shadowed_keys() == []
    log = capture_log(fn -> assert ReservedBucketAudit.audit() == :ok end)
    refute log =~ "reserved bucket"
  end
end
