defmodule Maxio.S3.MultipartCrossMatrix01DTest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_multipart_cross_matrix_01d")
  @unset {__MODULE__, :unset}
  @owner "000000000000"
  @alice_ak "AKIAMPUCROSS0001"
  @alice_secret "mpucrossmpucross123456"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
  @requester """
  <RequestPaymentConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Payer>Requester</Payer>
  </RequestPaymentConfiguration>
  """

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)

    prev_s3 = Application.get_env(:maxio, :s3)
    prev_min_part_size = Application.get_env(:maxio, :multipart_min_part_size, @unset)

    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, @data_dir))
    Application.put_env(:maxio, :multipart_min_part_size, 1)

    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      restore_env(:multipart_min_part_size, prev_min_part_size)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp alice(method, path, opts) do
    SigV4Request.signed_conn(
      method,
      path,
      Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    )
  end

  defp create_bucket(bucket) do
    conn = SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert conn.status == 200
    conn
  end

  defp put_request_payment(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"requestPayment" => ""},
      body: @requester,
      headers: [{"content-md5", content_md5(@requester)}]
    )
    |> call()
  end

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  defp checksum_sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode64()

  defp allow_alice_data_plane(bucket, object_actions) do
    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":#{Jason.encode!(object_actions)},"Resource":"arn:aws:s3:::#{bucket}/*"},{"Effect":"Allow","Action":["s3:ListBucket","s3:ListBucketVersions","s3:ListBucketMultipartUploads"],"Resource":"arn:aws:s3:::#{bucket}"}]})

    Store.put_principal_policy(@alice_arn, "mpu-cross-#{bucket}", policy)
  end

  defp requester_headers(extra \\ []) do
    [
      {"x-amz-request-payer", "requester"},
      {"x-amz-expected-bucket-owner", @owner}
      | extra
    ]
  end

  defp upload_id(body) do
    [_, upload_id] = Regex.run(~r/<UploadId>([^<]+)<\/UploadId>/, body)
    upload_id
  end

  defp copy_part_etag(body) do
    [_, etag] = Regex.run(~r/<ETag>([^<]+)<\/ETag>/, body)
    etag
  end

  defp complete_xml(parts) do
    parts =
      Enum.map(parts, fn {part_number, etag} ->
        "<Part><PartNumber>#{part_number}</PartNumber><ETag>#{etag}</ETag></Part>"
      end)

    IO.iodata_to_binary(["<CompleteMultipartUpload>", parts, "</CompleteMultipartUpload>"])
  end

  defp complete_as_alice(bucket, key, upload_id, parts, headers) do
    alice(:post, "/#{bucket}/#{key}",
      query: %{"uploadId" => upload_id},
      body: complete_xml(parts),
      headers: headers
    )
    |> call()
  end

  defp assert_charged(conn),
    do: assert(get_resp_header(conn, "x-amz-request-charged") == ["requester"])

  defp assert_s3_error(conn, status, code) do
    assert conn.status == status
    assert conn.resp_body =~ "<Code>#{code}</Code>"
  end

  defp restore_env(_key, @unset), do: Application.delete_env(:maxio, :multipart_min_part_size)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)

  test "Requester Pays MPU mixes UploadPart and ranged UploadPartCopy with checksum and SSE-KMS" do
    src_bucket = "mpxsrc"
    dst_bucket = "mpxdst"
    dst_key = "target.bin"

    create_bucket(src_bucket)
    create_bucket(dst_bucket)

    prefix = String.duplicate("a", 5_242_880)
    copied_body = "COPIED-RANGE"
    source_body = prefix <> copied_body <> "tail"

    assert (SigV4Request.signed_conn(:put, "/#{src_bucket}/source.bin", body: source_body)
            |> call()).status == 200

    assert put_request_payment(src_bucket).status == 200
    assert put_request_payment(dst_bucket).status == 200
    assert :ok = allow_alice_data_plane(src_bucket, ["s3:GetObject"])

    assert :ok =
             allow_alice_data_plane(dst_bucket, [
               "s3:PutObject",
               "s3:GetObject",
               "s3:ListMultipartUploadParts"
             ])

    kms_key_id = "arn:aws:kms:us-east-1:000000000000:key/mpu-cross"

    init =
      alice(:post, "/#{dst_bucket}/#{dst_key}",
        query: %{"uploads" => ""},
        headers:
          requester_headers([
            {"x-amz-checksum-algorithm", "SHA256"},
            {"x-amz-server-side-encryption", "aws:kms"},
            {"x-amz-server-side-encryption-aws-kms-key-id", kms_key_id}
          ])
      )
      |> call()

    assert init.status == 200
    assert_charged(init)
    assert get_resp_header(init, "x-amz-checksum-algorithm") == ["SHA256"]
    assert get_resp_header(init, "x-amz-checksum-type") == ["COMPOSITE"]
    assert get_resp_header(init, "x-amz-server-side-encryption") == ["aws:kms"]
    assert get_resp_header(init, "x-amz-server-side-encryption-aws-kms-key-id") == [kms_key_id]
    upload_id = upload_id(init.resp_body)

    uploaded_body = "UPLOADED-"
    uploaded_checksum = checksum_sha256(uploaded_body)

    uploaded =
      alice(:put, "/#{dst_bucket}/#{dst_key}",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: uploaded_body,
        headers: requester_headers([{"x-amz-checksum-sha256", uploaded_checksum}])
      )
      |> call()

    assert uploaded.status == 200
    assert_charged(uploaded)
    assert get_resp_header(uploaded, "x-amz-checksum-sha256") == [uploaded_checksum]
    [etag1] = get_resp_header(uploaded, "etag")

    first = byte_size(prefix)
    last = first + byte_size(copied_body) - 1
    copied_checksum = checksum_sha256(copied_body)

    copied =
      alice(:put, "/#{dst_bucket}/#{dst_key}",
        query: %{"partNumber" => "2", "uploadId" => upload_id},
        headers:
          requester_headers([
            {"x-amz-copy-source", "/#{src_bucket}/source.bin"},
            {"x-amz-copy-source-range", "bytes=#{first}-#{last}"},
            {"x-amz-source-expected-bucket-owner", @owner}
          ])
      )
      |> call()

    assert copied.status == 200
    assert_charged(copied)
    assert copied.resp_body =~ "<ChecksumSHA256>#{copied_checksum}</ChecksumSHA256>"
    assert get_resp_header(copied, "x-amz-server-side-encryption") == ["aws:kms"]
    assert get_resp_header(copied, "x-amz-server-side-encryption-aws-kms-key-id") == [kms_key_id]
    etag2 = copy_part_etag(copied.resp_body)

    listed =
      alice(:get, "/#{dst_bucket}/#{dst_key}",
        query: %{"uploadId" => upload_id},
        headers: requester_headers()
      )
      |> call()

    assert listed.status == 200
    assert_charged(listed)
    assert listed.resp_body =~ "<PartNumber>1</PartNumber>"
    assert listed.resp_body =~ "<ChecksumSHA256>#{uploaded_checksum}</ChecksumSHA256>"
    assert listed.resp_body =~ "<PartNumber>2</PartNumber>"
    assert listed.resp_body =~ "<ChecksumSHA256>#{copied_checksum}</ChecksumSHA256>"

    complete =
      complete_as_alice(
        dst_bucket,
        dst_key,
        upload_id,
        [{1, etag1}, {2, etag2}],
        requester_headers()
      )

    assert complete.status == 200
    assert_charged(complete)
    assert complete.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"
    assert complete.resp_body =~ "<ChecksumSHA256>"
    assert get_resp_header(complete, "x-amz-server-side-encryption") == ["aws:kms"]

    assert get_resp_header(complete, "x-amz-server-side-encryption-aws-kms-key-id") == [
             kms_key_id
           ]

    range_start = byte_size(uploaded_body)
    range_end = range_start + byte_size(copied_body) - 1

    ranged =
      alice(:get, "/#{dst_bucket}/#{dst_key}",
        headers: requester_headers([{"range", "bytes=#{range_start}-#{range_end}"}])
      )
      |> call()

    assert ranged.status == 206
    assert_charged(ranged)
    assert ranged.resp_body == copied_body

    assert get_resp_header(ranged, "content-range") == [
             "bytes #{range_start}-#{range_end}/#{byte_size(uploaded_body <> copied_body)}"
           ]

    assert get_resp_header(ranged, "x-amz-server-side-encryption") == ["aws:kms"]
  end

  test "Requester Pays UploadPart BadDigest keeps prior part retryable through CompleteMultipartUpload" do
    bucket = "mpxrollback"
    key = "object.bin"

    create_bucket(bucket)
    assert put_request_payment(bucket).status == 200

    assert :ok =
             allow_alice_data_plane(bucket, [
               "s3:PutObject",
               "s3:GetObject",
               "s3:ListMultipartUploadParts"
             ])

    init =
      alice(:post, "/#{bucket}/#{key}",
        query: %{"uploads" => ""},
        headers: requester_headers([{"x-amz-checksum-algorithm", "SHA256"}])
      )
      |> call()

    assert init.status == 200
    assert_charged(init)
    upload_id = upload_id(init.resp_body)

    old_body = "OLD"
    old_checksum = checksum_sha256(old_body)

    old =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: old_body,
        headers: requester_headers()
      )
      |> call()

    assert old.status == 200
    assert_charged(old)
    assert get_resp_header(old, "x-amz-checksum-sha256") == [old_checksum]
    [old_etag] = get_resp_header(old, "etag")

    bad =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: "NEW",
        headers: requester_headers([{"x-amz-checksum-sha256", checksum_sha256("different")}])
      )
      |> call()

    assert_s3_error(bad, 400, "BadDigest")

    listed =
      alice(:get, "/#{bucket}/#{key}",
        query: %{"uploadId" => upload_id},
        headers: requester_headers()
      )
      |> call()

    assert listed.status == 200
    assert_charged(listed)
    assert listed.resp_body =~ "<PartNumber>1</PartNumber>"
    assert listed.resp_body =~ "<ChecksumSHA256>#{old_checksum}</ChecksumSHA256>"

    complete = complete_as_alice(bucket, key, upload_id, [{1, old_etag}], requester_headers())

    assert complete.status == 200
    assert_charged(complete)
    assert complete.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"

    get =
      alice(:get, "/#{bucket}/#{key}", headers: requester_headers())
      |> call()

    assert get.status == 200
    assert_charged(get)
    assert get.resp_body == old_body
  end
end
