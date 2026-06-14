defmodule Maxio.S3.ChecksumE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_checksum_e2e")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "PutObject validates x-amz-checksum-sha256 and echoes the checksum header" do
    SigV4Request.signed_conn(:put, "/cksum") |> call()
    body = "checksum payload"
    checksum = hash_b64(:sha256, body)

    put =
      SigV4Request.signed_conn(:put, "/cksum/ok.txt",
        body: body,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum}
        ]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-sha256") == [checksum]

    get = SigV4Request.signed_conn(:get, "/cksum/ok.txt") |> call()
    assert get.status == 200
    assert get.resp_body == body
  end

  test "PutObject bad Content-MD5 returns BadDigest and does not leave an object" do
    SigV4Request.signed_conn(:put, "/ckmd5") |> call()

    bad =
      SigV4Request.signed_conn(:put, "/ckmd5/bad.txt",
        body: "real bytes",
        headers: [{"content-md5", hash_b64(:md5, "different bytes")}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "<Code>BadDigest</Code>"

    get = SigV4Request.signed_conn(:get, "/ckmd5/bad.txt") |> call()
    assert get.status == 404
  end

  test "PutObject valid-length checksum mismatches return BadDigest" do
    SigV4Request.signed_conn(:put, "/ckmismatch") |> call()

    bad_sha256 =
      SigV4Request.signed_conn(:put, "/ckmismatch/bad-sha256.txt",
        body: "real bytes",
        headers: [{"x-amz-checksum-sha256", hash_b64(:sha256, "different bytes")}]
      )
      |> call()

    assert bad_sha256.status == 400
    assert bad_sha256.resp_body =~ "<Code>BadDigest</Code>"

    bad_crc32 =
      SigV4Request.signed_conn(:put, "/ckmismatch/bad-crc32.txt",
        body: "real bytes",
        headers: [{"x-amz-checksum-crc32", crc32_b64("different bytes")}]
      )
      |> call()

    assert bad_crc32.status == 400
    assert bad_crc32.resp_body =~ "<Code>BadDigest</Code>"

    sha_get = SigV4Request.signed_conn(:get, "/ckmismatch/bad-sha256.txt") |> call()
    crc_get = SigV4Request.signed_conn(:get, "/ckmismatch/bad-crc32.txt") |> call()

    assert sha_get.status == 404
    assert crc_get.status == 404
  end

  test "PutObject validates x-amz-checksum-md5 without echoing Content-MD5" do
    SigV4Request.signed_conn(:put, "/ckmd5ok") |> call()
    body = "md5 payload"
    content_md5 = hash_b64(:md5, body)
    checksum_md5 = hash_b64(:md5, body)

    put =
      SigV4Request.signed_conn(:put, "/ckmd5ok/ok.txt",
        body: body,
        headers: [
          {"content-md5", content_md5},
          {"x-amz-sdk-checksum-algorithm", "MD5"},
          {"x-amz-checksum-md5", checksum_md5}
        ]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "content-md5") == []
    assert get_resp_header(put, "x-amz-checksum-md5") == [checksum_md5]
  end

  test "PutObject validates x-amz-checksum-crc32" do
    SigV4Request.signed_conn(:put, "/ckcrc") |> call()
    body = "crc payload"
    checksum = crc32_b64(body)

    put =
      SigV4Request.signed_conn(:put, "/ckcrc/ok.txt",
        body: body,
        headers: [{"x-amz-checksum-crc32", checksum}]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-crc32") == [checksum]
  end

  test "unsupported checksum algorithms fail closed" do
    SigV4Request.signed_conn(:put, "/ckunsupported") |> call()

    put =
      SigV4Request.signed_conn(:put, "/ckunsupported/object.txt",
        body: "bytes",
        headers: [{"x-amz-checksum-crc32c", "AAAAAA=="}]
      )
      |> call()

    assert put.status == 501
    assert put.resp_body =~ "<Code>NotImplemented</Code>"
  end

  test "x-amz-sdk-checksum-algorithm fails closed without a matching checksum value" do
    SigV4Request.signed_conn(:put, "/cksdk") |> call()

    missing =
      SigV4Request.signed_conn(:put, "/cksdk/missing.txt",
        body: "bytes",
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}]
      )
      |> call()

    assert missing.status == 400
    assert missing.resp_body =~ "<Code>InvalidRequest</Code>"

    mismatch =
      SigV4Request.signed_conn(:put, "/cksdk/mismatch.txt",
        body: "bytes",
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-crc32", crc32_b64("bytes")}
        ]
      )
      |> call()

    assert mismatch.status == 400
    assert mismatch.resp_body =~ "<Code>BadDigest</Code>"
  end

  test "UploadPart validates x-amz-checksum-sha256 and echoes the checksum header" do
    SigV4Request.signed_conn(:put, "/ckmp") |> call()
    body = "part bytes"
    checksum = hash_b64(:sha256, body)

    init =
      SigV4Request.signed_conn(:post, "/ckmp/object.bin", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    part =
      SigV4Request.signed_conn(:put, "/ckmp/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: body,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum}
        ]
      )
      |> call()

    assert part.status == 200
    assert get_resp_header(part, "x-amz-checksum-sha256") == [checksum]
    [etag] = get_resp_header(part, "etag")

    complete = complete_multipart_upload("ckmp", "object.bin", upload_id, [etag])
    assert complete.status == 200

    get = SigV4Request.signed_conn(:get, "/ckmp/object.bin") |> call()
    assert get.status == 200
    assert get.resp_body == body
  end

  test "UploadPart BadDigest does not overwrite an existing part" do
    SigV4Request.signed_conn(:put, "/ckmprollback") |> call()

    init =
      SigV4Request.signed_conn(:post, "/ckmprollback/object.bin", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    old =
      SigV4Request.signed_conn(:put, "/ckmprollback/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: "OLD"
      )
      |> call()

    assert old.status == 200
    [old_etag] = get_resp_header(old, "etag")

    bad =
      SigV4Request.signed_conn(:put, "/ckmprollback/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: "NEW",
        headers: [{"x-amz-checksum-sha256", hash_b64(:sha256, "different")}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "<Code>BadDigest</Code>"

    complete = complete_multipart_upload("ckmprollback", "object.bin", upload_id, [old_etag])
    assert complete.status == 200

    get = SigV4Request.signed_conn(:get, "/ckmprollback/object.bin") |> call()
    assert get.status == 200
    assert get.resp_body == "OLD"
  end

  test "UploadPartCopy checksum headers fail closed before copying source bytes" do
    SigV4Request.signed_conn(:put, "/ckmpcopy") |> call()
    SigV4Request.signed_conn(:put, "/ckmpcopy/src.txt", body: "source bytes") |> call()

    init =
      SigV4Request.signed_conn(:post, "/ckmpcopy/object.bin", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    part =
      SigV4Request.signed_conn(:put, "/ckmpcopy/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [
          {"x-amz-copy-source", "/ckmpcopy/src.txt"},
          {"x-amz-checksum-sha256", hash_b64(:sha256, "source bytes")}
        ]
      )
      |> call()

    assert part.status == 501
    assert part.resp_body =~ "<Code>NotImplemented</Code>"

    list =
      SigV4Request.signed_conn(:get, "/ckmpcopy/object.bin", query: %{"uploadId" => upload_id})
      |> call()

    assert list.status == 200
    refute list.resp_body =~ "<PartNumber>1</PartNumber>"
  end

  defp complete_multipart_upload(bucket, key, upload_id, etags) do
    parts =
      etags
      |> Enum.with_index(1)
      |> Enum.map(fn {etag, part_number} ->
        "<Part><PartNumber>#{part_number}</PartNumber><ETag>#{etag}</ETag></Part>"
      end)

    body = IO.iodata_to_binary(["<CompleteMultipartUpload>", parts, "</CompleteMultipartUpload>"])

    SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
      query: %{"uploadId" => upload_id},
      body: body
    )
    |> call()
  end

  defp upload_id(xml) do
    [_, rest] = String.split(xml, "<UploadId>")
    [id, _] = String.split(rest, "</UploadId>")
    id
  end

  defp hash_b64(algorithm, body), do: :crypto.hash(algorithm, body) |> Base.encode64()

  defp crc32_b64(body), do: <<:erlang.crc32(body)::32>> |> Base.encode64()
end
