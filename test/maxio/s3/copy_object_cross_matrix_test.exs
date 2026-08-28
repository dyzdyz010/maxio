defmodule Maxio.S3.CopyObjectCrossMatrixTest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_copy_object_cross_matrix")
  @owner "000000000000"
  @other_owner "999999999999"
  @alice_ak "AKIACOPYCROSS0001"
  @alice_secret "copycrosscopycross123456"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
  @requester """
  <RequestPaymentConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Payer>Requester</Payer>
  </RequestPaymentConfiguration>
  """

  setup do
    %{user_arn: @alice_arn} =
      create_user_with_access_key!(
        user_name: @alice_ak,
        access_key_id: @alice_ak,
        secret_key: @alice_secret
      )

    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
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

  defp put_request_payment(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"requestPayment" => ""},
      body: @requester,
      headers: [{"content-md5", content_md5(@requester)}]
    )
    |> call()
  end

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  defp enable_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp allow_alice_data_plane(bucket, object_actions) do
    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":#{Jason.encode!(object_actions)},"Resource":"arn:aws:s3:::#{bucket}/*"},{"Effect":"Allow","Action":["s3:ListBucket","s3:ListBucketVersions","s3:ListBucketMultipartUploads"],"Resource":"arn:aws:s3:::#{bucket}"}]})

    Store.put_principal_policy(@alice_arn, "copy-cross-#{bucket}", policy)
  end

  defp upload_id(body) do
    [_, upload_id] = Regex.run(~r/<UploadId>([^<]+)<\/UploadId>/, body)
    upload_id
  end

  defp copy_part_etag(body) do
    [_, etag] = Regex.run(~r/<ETag>([^<]+)<\/ETag>/, body)
    etag
  end

  defp complete_multipart_as_alice(bucket, key, upload_id, etag, headers) do
    body = """
    <CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>#{etag}</ETag></Part></CompleteMultipartUpload>
    """

    alice(:post, "/#{bucket}/#{key}",
      query: %{"uploadId" => upload_id},
      body: body,
      headers: headers
    )
    |> call()
  end

  defp assert_s3_error(conn, status, code) do
    assert conn.status == status
    assert conn.resp_body =~ "<Code>#{code}</Code>"
  end

  defp assert_charged(conn),
    do: assert(get_resp_header(conn, "x-amz-request-charged") == ["requester"])

  defp refute_charged(conn), do: assert(get_resp_header(conn, "x-amz-request-charged") == [])

  defp assert_no_object(bucket, key) do
    assert (SigV4Request.signed_conn(:head, "/#{bucket}/#{key}") |> call()).status == 404
  end

  defp assert_no_parts_as_alice(bucket, key, upload_id) do
    parts =
      alice(:get, "/#{bucket}/#{key}",
        query: %{"uploadId" => upload_id},
        headers: [
          {"x-amz-request-payer", "requester"},
          {"x-amz-expected-bucket-owner", @owner}
        ]
      )
      |> call()

    assert parts.status == 200
    assert_charged(parts)
    refute parts.resp_body =~ "<Part>"
  end

  test "CopyObject combines requester pays expected owners and source versions without target side effects" do
    src_bucket = "cpcrosssrc"
    dst_bucket = "cpcrossdst"

    assert (SigV4Request.signed_conn(:put, "/#{src_bucket}") |> call()).status == 200
    assert (SigV4Request.signed_conn(:put, "/#{dst_bucket}") |> call()).status == 200
    assert enable_versioning(src_bucket).status == 200
    assert enable_versioning(dst_bucket).status == 200

    old =
      SigV4Request.signed_conn(:put, "/#{src_bucket}/source.txt", body: "old-version") |> call()

    assert [old_version_id] = get_resp_header(old, "x-amz-version-id")

    assert (SigV4Request.signed_conn(:put, "/#{src_bucket}/source.txt", body: "new-version")
            |> call()).status == 200

    assert put_request_payment(src_bucket).status == 200
    assert put_request_payment(dst_bucket).status == 200
    assert :ok = allow_alice_data_plane(src_bucket, ["s3:GetObject", "s3:GetObjectVersion"])
    assert :ok = allow_alice_data_plane(dst_bucket, ["s3:PutObject"])

    source = "/#{src_bucket}/source.txt?versionId=#{old_version_id}"

    missing_payer =
      alice(:put, "/#{dst_bucket}/target.txt",
        headers: [
          {"x-amz-copy-source", source},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @owner}
        ]
      )
      |> call()

    assert_s3_error(missing_payer, 403, "AccessDenied")
    refute_charged(missing_payer)
    assert_no_object(dst_bucket, "target.txt")

    wrong_destination_owner =
      alice(:put, "/#{dst_bucket}/target.txt",
        headers: [
          {"x-amz-copy-source", source},
          {"x-amz-request-payer", "requester"},
          {"x-amz-expected-bucket-owner", @other_owner},
          {"x-amz-source-expected-bucket-owner", @owner}
        ]
      )
      |> call()

    assert_s3_error(wrong_destination_owner, 403, "AccessDenied")
    refute_charged(wrong_destination_owner)
    assert_no_object(dst_bucket, "target.txt")

    wrong_source_owner =
      alice(:put, "/#{dst_bucket}/target.txt",
        headers: [
          {"x-amz-copy-source", source},
          {"x-amz-request-payer", "requester"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @other_owner}
        ]
      )
      |> call()

    assert_s3_error(wrong_source_owner, 403, "AccessDenied")
    refute_charged(wrong_source_owner)
    assert_no_object(dst_bucket, "target.txt")

    copied =
      alice(:put, "/#{dst_bucket}/target.txt",
        headers: [
          {"x-amz-copy-source", source},
          {"x-amz-request-payer", "requester"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @owner},
          {"x-amz-metadata-directive", "REPLACE"},
          {"x-amz-meta-copy-cross", "yes"}
        ]
      )
      |> call()

    assert copied.status == 200
    assert copied.resp_body =~ "<CopyObjectResult"
    assert get_resp_header(copied, "x-amz-copy-source-version-id") == [old_version_id]
    assert [_dest_version_id] = get_resp_header(copied, "x-amz-version-id")
    assert_charged(copied)

    get = SigV4Request.signed_conn(:get, "/#{dst_bucket}/target.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "old-version"
    assert get_resp_header(get, "x-amz-meta-copy-cross") == ["yes"]
  end

  test "UploadPartCopy applies requester pays and expected owner gates before storing parts" do
    src_bucket = "upccrosssrc"
    dst_bucket = "upccrossdst"

    assert (SigV4Request.signed_conn(:put, "/#{src_bucket}") |> call()).status == 200
    assert (SigV4Request.signed_conn(:put, "/#{dst_bucket}") |> call()).status == 200
    assert enable_versioning(src_bucket).status == 200

    old = SigV4Request.signed_conn(:put, "/#{src_bucket}/source.txt", body: "old-part") |> call()
    assert [old_version_id] = get_resp_header(old, "x-amz-version-id")

    assert (SigV4Request.signed_conn(:put, "/#{src_bucket}/source.txt", body: "new-part")
            |> call()).status == 200

    assert put_request_payment(src_bucket).status == 200
    assert put_request_payment(dst_bucket).status == 200

    assert :ok = allow_alice_data_plane(src_bucket, ["s3:GetObject", "s3:GetObjectVersion"])

    assert :ok =
             allow_alice_data_plane(dst_bucket, [
               "s3:PutObject",
               "s3:ListMultipartUploadParts"
             ])

    init =
      alice(:post, "/#{dst_bucket}/target.bin",
        query: %{"uploads" => ""},
        headers: [
          {"x-amz-request-payer", "requester"},
          {"x-amz-expected-bucket-owner", @owner}
        ]
      )
      |> call()

    assert init.status == 200
    assert_charged(init)
    upload_id = upload_id(init.resp_body)

    source = "/#{src_bucket}/source.txt?versionId=#{old_version_id}"

    missing_payer =
      alice(:put, "/#{dst_bucket}/target.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [
          {"x-amz-copy-source", source},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @owner}
        ]
      )
      |> call()

    assert_s3_error(missing_payer, 403, "AccessDenied")
    refute_charged(missing_payer)
    assert_no_parts_as_alice(dst_bucket, "target.bin", upload_id)

    wrong_destination_owner =
      alice(:put, "/#{dst_bucket}/target.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [
          {"x-amz-copy-source", source},
          {"x-amz-request-payer", "requester"},
          {"x-amz-expected-bucket-owner", @other_owner},
          {"x-amz-source-expected-bucket-owner", @owner}
        ]
      )
      |> call()

    assert_s3_error(wrong_destination_owner, 403, "AccessDenied")
    refute_charged(wrong_destination_owner)
    assert_no_parts_as_alice(dst_bucket, "target.bin", upload_id)

    wrong_source_owner =
      alice(:put, "/#{dst_bucket}/target.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [
          {"x-amz-copy-source", source},
          {"x-amz-request-payer", "requester"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @other_owner}
        ]
      )
      |> call()

    assert_s3_error(wrong_source_owner, 403, "AccessDenied")
    refute_charged(wrong_source_owner)
    assert_no_parts_as_alice(dst_bucket, "target.bin", upload_id)

    copied =
      alice(:put, "/#{dst_bucket}/target.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [
          {"x-amz-copy-source", source},
          {"x-amz-request-payer", "requester"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @owner}
        ]
      )
      |> call()

    assert copied.status == 200
    assert copied.resp_body =~ "<CopyPartResult"
    assert get_resp_header(copied, "x-amz-copy-source-version-id") == [old_version_id]
    assert_charged(copied)

    etag = copy_part_etag(copied.resp_body)

    complete =
      complete_multipart_as_alice(dst_bucket, "target.bin", upload_id, etag, [
        {"x-amz-request-payer", "requester"},
        {"x-amz-expected-bucket-owner", @owner}
      ])

    assert complete.status == 200
    assert_charged(complete)

    get = SigV4Request.signed_conn(:get, "/#{dst_bucket}/target.bin") |> call()
    assert get.status == 200
    assert get.resp_body == "old-part"
  end

  test "CopyObject and UploadPartCopy reject source delete markers without committing targets" do
    bucket = "upcdmcross"

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200
    assert enable_versioning(bucket).status == 200

    assert (SigV4Request.signed_conn(:put, "/#{bucket}/source.txt", body: "before-delete")
            |> call()).status == 200

    delete_marker = SigV4Request.signed_conn(:delete, "/#{bucket}/source.txt") |> call()
    assert delete_marker.status == 204
    assert get_resp_header(delete_marker, "x-amz-delete-marker") == ["true"]
    assert [delete_marker_version_id] = get_resp_header(delete_marker, "x-amz-version-id")

    copy_latest =
      SigV4Request.signed_conn(:put, "/#{bucket}/copy-latest.txt",
        headers: [
          {"x-amz-copy-source", "/#{bucket}/source.txt"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @owner}
        ]
      )
      |> call()

    assert_s3_error(copy_latest, 404, "NoSuchKey")
    assert_no_object(bucket, "copy-latest.txt")

    copy_marker_version =
      SigV4Request.signed_conn(:put, "/#{bucket}/copy-marker.txt",
        headers: [
          {"x-amz-copy-source", "/#{bucket}/source.txt?versionId=#{delete_marker_version_id}"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @owner}
        ]
      )
      |> call()

    assert_s3_error(copy_marker_version, 400, "InvalidArgument")
    assert_no_object(bucket, "copy-marker.txt")

    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/target.bin", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    part_copy_latest =
      SigV4Request.signed_conn(:put, "/#{bucket}/target.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [
          {"x-amz-copy-source", "/#{bucket}/source.txt"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @owner}
        ]
      )
      |> call()

    assert_s3_error(part_copy_latest, 404, "NoSuchKey")

    part_copy_marker_version =
      SigV4Request.signed_conn(:put, "/#{bucket}/target.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [
          {"x-amz-copy-source", "/#{bucket}/source.txt?versionId=#{delete_marker_version_id}"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @owner}
        ]
      )
      |> call()

    assert_s3_error(part_copy_marker_version, 400, "InvalidArgument")

    parts =
      SigV4Request.signed_conn(:get, "/#{bucket}/target.bin",
        query: %{"uploadId" => upload_id},
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call()

    assert parts.status == 200
    refute parts.resp_body =~ "<Part>"
  end
end
