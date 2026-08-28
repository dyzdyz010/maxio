defmodule Maxio.S3.BucketListingGuardMatrixTest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.BucketConfigs
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_bucket_listing_guard_matrix")
  @owner "000000000000"
  @other_owner "999999999999"
  @alice_ak "AKIABUCKETLISTGUARD"
  @alice_secret "bucketlistingguardsecret123"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak

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

  test "expected bucket owner guards bucket discovery list and multipart list surfaces" do
    bucket = "guardownerlist"
    key = "alpha.txt"
    upload_key = "uploads/object.bin"

    create_bucket(bucket)
    assert enable_versioning(bucket).status == 200
    assert put_object(bucket, key, "versioned body").status == 200
    upload_id = create_upload(bucket, upload_key)
    assert upload_part(bucket, upload_key, upload_id, 1, "part-one").status == 200

    missing_head =
      SigV4Request.signed_conn(:head, "/missingownerlist",
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert missing_head.status == 404

    missing_location =
      SigV4Request.signed_conn(:get, "/missingownerlist",
        query: %{"location" => ""},
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert_xml_error(missing_location, 404, "NoSuchBucket")

    wrong_head =
      SigV4Request.signed_conn(:head, "/#{bucket}",
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert wrong_head.status == 403

    correct_head =
      SigV4Request.signed_conn(:head, "/#{bucket}",
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call()

    assert correct_head.status == 200
    assert get_resp_header(correct_head, "x-amz-bucket-region") == ["us-east-1"]

    wrong_location =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"location" => ""},
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert_xml_error(wrong_location, 403, "AccessDenied")

    assert_success(
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"location" => ""},
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call()
    )

    wrong_v1 =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert_xml_error(wrong_v1, 403, "AccessDenied")
    refute wrong_v1.resp_body =~ "ListBucketResult"

    assert_list_ok(
      SigV4Request.signed_conn(:get, "/#{bucket}",
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call(),
      key
    )

    wrong_v2 =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"list-type" => "2"},
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert_xml_error(wrong_v2, 403, "AccessDenied")
    refute wrong_v2.resp_body =~ "ListBucketResult"

    assert_list_ok(
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"list-type" => "2"},
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call(),
      key
    )

    wrong_versions =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"versions" => ""},
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert_xml_error(wrong_versions, 403, "AccessDenied")
    refute wrong_versions.resp_body =~ "ListVersionsResult"

    assert_list_ok(
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"versions" => ""},
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call(),
      key
    )

    wrong_uploads =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"uploads" => ""},
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert_xml_error(wrong_uploads, 403, "AccessDenied")
    refute wrong_uploads.resp_body =~ "ListMultipartUploadsResult"

    assert_list_ok(
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"uploads" => ""},
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call(),
      upload_key
    )

    wrong_parts =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{upload_key}",
        query: %{"uploadId" => upload_id},
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert_xml_error(wrong_parts, 403, "AccessDenied")
    refute wrong_parts.resp_body =~ "ListPartsResult"

    parts =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{upload_key}",
        query: %{"uploadId" => upload_id},
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call()

    assert parts.status == 200
    assert parts.resp_body =~ "<PartNumber>1</PartNumber>"
  end

  test "Requester Pays charges non-owner bucket list APIs and rejects bad acknowledgements" do
    bucket = "guardpayerlist"
    key = "listed.txt"

    create_bucket(bucket)
    assert enable_versioning(bucket).status == 200
    assert put_object(bucket, key, "listed body").status == 200
    assert :ok = put_requester_pays(bucket)
    assert :ok = allow_alice_listing(bucket)

    missing_v1 = alice(:get, "/#{bucket}") |> call()
    assert_xml_error(missing_v1, 403, "AccessDenied")
    refute_charged(missing_v1)

    signed_v1 =
      alice(:get, "/#{bucket}", headers: [{"x-amz-request-payer", "requester"}])
      |> call()

    assert_list_ok(signed_v1, key)
    assert_charged(signed_v1)

    query_v2 =
      alice(:get, "/#{bucket}",
        query: %{"list-type" => "2", "x-amz-request-payer" => "requester"}
      )
      |> call()

    assert_list_ok(query_v2, key)
    assert_charged(query_v2)

    signed_versions =
      alice(:get, "/#{bucket}",
        query: %{"versions" => ""},
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert_list_ok(signed_versions, key)
    assert_charged(signed_versions)

    invalid_versions =
      alice(:get, "/#{bucket}",
        query: %{"versions" => ""},
        headers: [{"x-amz-request-payer", "owner"}]
      )
      |> call()

    assert_xml_error(invalid_versions, 403, "AccessDenied")
    refute_charged(invalid_versions)

    unsigned_v2 =
      alice(:get, "/#{bucket}", query: %{"list-type" => "2"})
      |> put_req_header("x-amz-request-payer", "requester")
      |> call()

    assert_xml_error(unsigned_v2, 403, "AccessDenied")
    refute_charged(unsigned_v2)

    owner_v1 = SigV4Request.signed_conn(:get, "/#{bucket}") |> call()
    assert_list_ok(owner_v1, key)
    refute_charged(owner_v1)

    owner_versions =
      SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"versions" => ""}) |> call()

    assert_list_ok(owner_versions, key)
    refute_charged(owner_versions)
  end

  test "Requester Pays charges non-owner multipart list APIs and preserves owner bypass" do
    bucket = "guardpayermpu"
    key = "multipart/object.bin"

    create_bucket(bucket)
    assert :ok = put_requester_pays(bucket)
    upload_id = create_upload(bucket, key)
    assert upload_part(bucket, key, upload_id, 1, "part-one").status == 200
    assert :ok = allow_alice_listing(bucket)

    missing_uploads =
      alice(:get, "/#{bucket}", query: %{"uploads" => ""})
      |> call()

    assert_xml_error(missing_uploads, 403, "AccessDenied")
    refute_charged(missing_uploads)

    query_uploads =
      alice(:get, "/#{bucket}", query: %{"uploads" => "", "x-amz-request-payer" => "requester"})
      |> call()

    assert_list_ok(query_uploads, key)
    assert_charged(query_uploads)

    signed_parts =
      alice(:get, "/#{bucket}/#{key}",
        query: %{"uploadId" => upload_id},
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert signed_parts.status == 200
    assert signed_parts.resp_body =~ "<PartNumber>1</PartNumber>"
    assert_charged(signed_parts)

    invalid_parts =
      alice(:get, "/#{bucket}/#{key}",
        query: %{"uploadId" => upload_id},
        headers: [{"x-amz-request-payer", "owner"}]
      )
      |> call()

    assert_xml_error(invalid_parts, 403, "AccessDenied")
    refute_charged(invalid_parts)

    unsigned_parts =
      alice(:get, "/#{bucket}/#{key}", query: %{"uploadId" => upload_id})
      |> put_req_header("x-amz-request-payer", "requester")
      |> call()

    assert_xml_error(unsigned_parts, 403, "AccessDenied")
    refute_charged(unsigned_parts)

    owner_uploads =
      SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"uploads" => ""})
      |> call()

    assert_list_ok(owner_uploads, key)
    refute_charged(owner_uploads)

    owner_parts =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"uploadId" => upload_id})
      |> call()

    assert owner_parts.status == 200
    assert owner_parts.resp_body =~ "<PartNumber>1</PartNumber>"
    refute_charged(owner_parts)
  end

  defp create_bucket(bucket) do
    conn = SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert conn.status == 200
    conn
  end

  defp put_object(bucket, key, body) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body) |> call()
  end

  defp enable_versioning(bucket) do
    body = "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>"

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp create_upload(bucket, key) do
    conn =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}", query: %{"uploads" => ""}) |> call()

    assert conn.status == 200
    upload_id(conn.resp_body)
  end

  defp upload_part(bucket, key, upload_id, part_number, body) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
      query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
      body: body
    )
    |> call()
  end

  defp put_requester_pays(bucket) do
    BucketConfigs.put(bucket, :request_payment, %{"Payer" => "Requester"})
  end

  defp allow_alice_listing(bucket) do
    policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => [
          %{
            "Effect" => "Allow",
            "Action" => [
              "s3:GetBucketLocation",
              "s3:ListBucket",
              "s3:ListBucketVersions",
              "s3:ListBucketMultipartUploads"
            ],
            "Resource" => "arn:aws:s3:::#{bucket}"
          },
          %{
            "Effect" => "Allow",
            "Action" => ["s3:ListMultipartUploadParts"],
            "Resource" => "arn:aws:s3:::#{bucket}/*"
          }
        ]
      })

    Store.put_principal_policy(@alice_arn, "bucket-list-guards-#{bucket}", policy)
  end

  defp alice(method, path, opts \\ []) do
    SigV4Request.signed_conn(
      method,
      path,
      Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    )
  end

  defp upload_id(xml) do
    [_, id] = Regex.run(~r/<UploadId>([^<]+)<\/UploadId>/, xml)
    id
  end

  defp assert_success(conn), do: assert(conn.status == 200)

  defp assert_list_ok(conn, key) do
    assert conn.status == 200
    assert conn.resp_body =~ "<Key>#{key}</Key>"
  end

  defp assert_xml_error(conn, status, code) do
    assert conn.status == status
    assert conn.resp_body =~ "<Code>#{code}</Code>"
  end

  defp assert_charged(conn),
    do: assert(get_resp_header(conn, "x-amz-request-charged") == ["requester"])

  defp refute_charged(conn), do: assert(get_resp_header(conn, "x-amz-request-charged") == [])
end
