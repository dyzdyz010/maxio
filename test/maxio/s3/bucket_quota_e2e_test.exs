defmodule Maxio.S3.BucketQuotaE2ETest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Maxio.BucketQuota
  alias Maxio.S3.Endpoint
  alias Maxio.Storage
  alias Maxio.Test.SigV4Request

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "PutObject over hard quota returns MinIO quota error and leaves no object" do
    bucket = "quota-put"
    create_bucket!(bucket)
    assert :ok = BucketQuota.put_hard(bucket, 5)

    ok = SigV4Request.signed_conn(:put, "/#{bucket}/a.txt", body: "1234") |> call()
    assert ok.status == 200

    rejected = SigV4Request.signed_conn(:put, "/#{bucket}/b.txt", body: "12") |> call()
    assert rejected.status == 400
    assert rejected.resp_body =~ "XMinioAdminBucketQuotaExceeded"

    assert_missing(bucket, "b.txt")
  end

  test "PutObject quota failure remains fail-closed under sidecar write authority" do
    with_sidecar_write_authority(fn ->
      bucket = "quota-sidecar"
      create_bucket!(bucket)
      assert :ok = BucketQuota.put_hard(bucket, 3)

      rejected =
        SigV4Request.signed_conn(:put, "/#{bucket}/too-large.txt", body: "1234") |> call()

      assert rejected.status == 400
      assert rejected.resp_body =~ "XMinioAdminBucketQuotaExceeded"

      assert_missing(bucket, "too-large.txt")
      assert_storage_missing(bucket, "too-large.txt")
    end)
  end

  test "PutObject quota preflight rejects before legacy delete cleanup is needed" do
    with_storage_backend(Maxio.Test.StorageDeleteErrorBackend, fn ->
      bucket = "quota-put-delete-fail"
      create_bucket!(bucket)
      assert :ok = BucketQuota.put_hard(bucket, 3)

      log =
        capture_log([level: :error], fn ->
          rejected =
            SigV4Request.signed_conn(:put, "/#{bucket}/too-large.txt", body: "1234") |> call()

          send(self(), {:quota_response, rejected})
        end)

      assert_receive {:quota_response, rejected}
      assert rejected.status == 400
      assert rejected.resp_body =~ "XMinioAdminBucketQuotaExceeded"
      refute log =~ "put object orphan bytes cleanup failed after metadata rollback"
      refute log =~ "injected_delete_failure"
      assert_storage_missing(bucket, "too-large.txt")
    end)
  end

  test "CopyObject over hard quota is rejected before destination metadata exists" do
    bucket = "quota-copy"
    create_bucket!(bucket)
    assert :ok = BucketQuota.put_hard(bucket, 5)

    put = SigV4Request.signed_conn(:put, "/#{bucket}/src.txt", body: "1234") |> call()
    assert put.status == 200

    rejected =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"}]
      )
      |> call()

    assert rejected.status == 400
    assert rejected.resp_body =~ "XMinioAdminBucketQuotaExceeded"
    assert_missing(bucket, "dst.txt")
  end

  test "CopyObject quota failure remains fail-closed under sidecar write authority" do
    with_sidecar_write_authority(fn ->
      bucket = "quota-sidecar-copy"
      create_bucket!(bucket)
      assert :ok = BucketQuota.put_hard(bucket, 5)

      put = SigV4Request.signed_conn(:put, "/#{bucket}/src.txt", body: "1234") |> call()
      assert put.status == 200

      rejected =
        SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
          headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"}]
        )
        |> call()

      assert rejected.status == 400
      assert rejected.resp_body =~ "XMinioAdminBucketQuotaExceeded"
      assert_missing(bucket, "dst.txt")
      assert_storage_missing(bucket, "dst.txt")
    end)
  end

  test "CompleteMultipartUpload over hard quota is rejected and leaves upload retryable" do
    bucket = "quota-mpu"
    create_bucket!(bucket)
    assert :ok = BucketQuota.put_hard(bucket, 5)

    put = SigV4Request.signed_conn(:put, "/#{bucket}/existing.txt", body: "1234") |> call()
    assert put.status == 200

    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/large.txt", query: %{"uploads" => ""}) |> call()

    assert init.status == 200
    upload_id = text_between(init.resp_body, "<UploadId>", "</UploadId>")

    part =
      SigV4Request.signed_conn(:put, "/#{bucket}/large.txt",
        query: %{"uploadId" => upload_id, "partNumber" => "1"},
        body: "12"
      )
      |> call()

    assert part.status == 200
    [etag] = get_resp_header(part, "etag")

    body =
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>#{etag}</ETag></Part></CompleteMultipartUpload>"

    rejected =
      SigV4Request.signed_conn(:post, "/#{bucket}/large.txt",
        query: %{"uploadId" => upload_id},
        body: body
      )
      |> call()

    assert rejected.status == 400
    assert rejected.resp_body =~ "XMinioAdminBucketQuotaExceeded"
    assert_missing(bucket, "large.txt")

    list_parts =
      SigV4Request.signed_conn(:get, "/#{bucket}/large.txt", query: %{"uploadId" => upload_id})
      |> call()

    assert list_parts.status == 200
    assert list_parts.resp_body =~ "<PartNumber>1</PartNumber>"
  end

  test "CompleteMultipartUpload quota failure remains fail-closed under sidecar write authority" do
    with_sidecar_write_authority(fn ->
      bucket = "quota-sidecar-mpu"
      create_bucket!(bucket)
      assert :ok = BucketQuota.put_hard(bucket, 5)

      put = SigV4Request.signed_conn(:put, "/#{bucket}/existing.txt", body: "1234") |> call()
      assert put.status == 200

      init =
        SigV4Request.signed_conn(:post, "/#{bucket}/large.txt", query: %{"uploads" => ""})
        |> call()

      assert init.status == 200
      upload_id = text_between(init.resp_body, "<UploadId>", "</UploadId>")

      part =
        SigV4Request.signed_conn(:put, "/#{bucket}/large.txt",
          query: %{"uploadId" => upload_id, "partNumber" => "1"},
          body: "12"
        )
        |> call()

      assert part.status == 200
      [etag] = get_resp_header(part, "etag")

      body =
        "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>#{etag}</ETag></Part></CompleteMultipartUpload>"

      rejected =
        SigV4Request.signed_conn(:post, "/#{bucket}/large.txt",
          query: %{"uploadId" => upload_id},
          body: body
        )
        |> call()

      assert rejected.status == 400
      assert rejected.resp_body =~ "XMinioAdminBucketQuotaExceeded"
      assert_missing(bucket, "large.txt")
      assert_storage_missing(bucket, "large.txt")

      list_parts =
        SigV4Request.signed_conn(:get, "/#{bucket}/large.txt", query: %{"uploadId" => upload_id})
        |> call()

      assert list_parts.status == 200
      assert list_parts.resp_body =~ "<PartNumber>1</PartNumber>"
    end)
  end

  defp create_bucket!(bucket) do
    conn = SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert conn.status == 200
  end

  defp assert_missing(bucket, key) do
    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 404
    assert get.resp_body =~ "NoSuchKey"
  end

  defp assert_storage_missing(bucket, key) do
    assert {:error, :enoent} = Storage.get(bucket, key, "null", nil)
  end

  defp with_sidecar_write_authority(fun) do
    previous = Application.get_env(:maxio, :authoritative_source)

    Application.put_env(
      :maxio,
      :authoritative_source,
      Keyword.put(previous || [], :write, :sidecar)
    )

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:maxio, :authoritative_source, previous),
        else: Application.delete_env(:maxio, :authoritative_source)
    end
  end

  defp with_storage_backend(backend, fun) do
    previous = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, backend)

    try do
      fun.()
    after
      Application.put_env(:maxio, :storage_backend, previous)
    end
  end

  defp text_between(text, left, right) do
    [_prefix, rest] = String.split(text, left, parts: 2)
    [value, _suffix] = String.split(rest, right, parts: 2)
    value
  end
end
