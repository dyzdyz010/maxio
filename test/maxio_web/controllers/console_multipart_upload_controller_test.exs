defmodule MaxioWeb.ConsoleMultipartUploadControllerTest do
  use MaxioWeb.ConnCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.Console.DirectMultipartUpload
  alias Maxio.Multipart
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  setup %{conn: conn} do
    {:ok, _bucket} = Maxio.Buckets.create("direct-bucket", "arn:aws:iam:::root")
    :ok = Maxio.Storage.put_bucket("direct-bucket")
    put_console_s3_public_url("http://localhost:9900")
    configure_min_part_size!(1)

    {:ok, conn: log_in_console(conn)}
  end

  test "direct multipart API presigns S3 create, parts, complete and writes object bytes", %{
    conn: conn
  } do
    init =
      conn
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/direct.bin", %{
        "size" => "8",
        "part_size" => "3",
        "content_type" => "text/plain",
        "expires_in" => "600",
        "file_name" => "direct.bin",
        "file_last_modified" => "1710000000000"
      })
      |> json_response(200)

    assert init["part_size"] == 3
    assert init["create"]["method"] == "POST"
    assert header_map(init["create"])["content-type"] == "text/plain"

    create_query =
      init["create"]["url"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert create_query["x-maxio-console-direct-multipart"] == "1"
    assert create_query["x-maxio-console-registry"] == "1"
    assert create_query["x-maxio-console-file-name"] == "direct.bin"
    assert create_query["x-maxio-console-file-size"] == "8"
    assert create_query["x-maxio-console-file-last-modified"] == "1710000000000"
    assert create_query["x-maxio-console-part-size"] == "3"

    create = s3_request(init["create"], "")
    assert create.status == 200
    upload_id = upload_id_from_xml(create.resp_body)

    lookup =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/lookup/docs/direct.bin", %{
        "size" => "8",
        "file_last_modified" => "1710000000000"
      })
      |> json_response(200)

    assert lookup["session"]["upload_id"] == upload_id
    assert lookup["session"]["part_size"] == 3
    assert lookup["session"]["file_name"] == "direct.bin"
    assert lookup["session"]["uploaded_parts"] == []

    sign =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/sign-parts/docs/direct.bin", %{
        "upload_id" => upload_id,
        "part_numbers" => [1, 2, 3],
        "expires_in" => "600"
      })
      |> json_response(200)

    etags =
      [{"AAA", 1}, {"BBB", 2}, {"CC", 3}]
      |> Enum.map(fn {body, part_number} ->
        request = Enum.find(sign["parts"], &(&1["part_number"] == part_number))
        put = s3_request(request, body)
        assert put.status == 200
        [etag] = get_resp_header(put, "etag")
        %{"part_number" => part_number, "etag" => etag}
      end)

    first_page =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/list-parts/docs/direct.bin", %{
        "upload_id" => upload_id,
        "max_parts" => 2,
        "part_number_marker" => 0,
        "expires_in" => "600"
      })
      |> json_response(200)

    assert first_page["list_parts"]["method"] == "GET"

    list_query =
      first_page["list_parts"]["url"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert list_query["uploadId"] == upload_id
    assert list_query["max-parts"] == "2"
    assert list_query["part-number-marker"] == "0"
    assert list_query["x-maxio-console-direct-multipart"] == "1"

    listed = s3_request(first_page["list_parts"], "")
    assert listed.status == 200
    assert listed.resp_body =~ "<PartNumber>1</PartNumber>"
    assert listed.resp_body =~ "<PartNumber>2</PartNumber>"
    refute listed.resp_body =~ "<PartNumber>3</PartNumber>"
    assert listed.resp_body =~ "<IsTruncated>true</IsTruncated>"
    assert listed.resp_body =~ "<NextPartNumberMarker>2</NextPartNumberMarker>"

    tampered_list =
      Map.update!(first_page["list_parts"], "headers", fn headers ->
        [%{"name" => "x-amz-request-payer", "value" => "requester"} | headers]
      end)

    denied = s3_request(tampered_list, "")
    assert denied.status == 400
    assert denied.resp_body =~ "AccessDenied"

    second_page =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/list-parts/docs/direct.bin", %{
        "upload_id" => upload_id,
        "max_parts" => 2,
        "part_number_marker" => 2,
        "expires_in" => "600"
      })
      |> json_response(200)

    listed = s3_request(second_page["list_parts"], "")
    assert listed.status == 200
    assert listed.resp_body =~ "<PartNumber>3</PartNumber>"
    assert listed.resp_body =~ "<IsTruncated>false</IsTruncated>"

    complete =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/complete/docs/direct.bin", %{
        "upload_id" => upload_id,
        "parts" => etags,
        "expires_in" => "600"
      })
      |> json_response(200)

    assert complete["complete"]["body"] =~ "<CompleteMultipartUpload>"

    assert URI.decode_query(URI.parse(complete["complete"]["url"]).query)[
             "x-maxio-console-direct-multipart"
           ] == "1"

    assert header_map(complete["complete"])["content-md5"] ==
             :crypto.hash(:md5, complete["complete"]["body"]) |> Base.encode64()

    assert [] = DirectMultipartUpload.list_history("direct-bucket", "docs/", "arn:aws:iam:::root")

    done = s3_request(complete["complete"], complete["complete"]["body"])
    assert done.status == 200

    assert {:error, :not_found} =
             DirectMultipartUpload.lookup_for_file(
               "direct-bucket",
               "docs/direct.bin",
               "arn:aws:iam:::root",
               8,
               1_710_000_000_000
             )

    [history] = DirectMultipartUpload.list_history("direct-bucket", "docs/", "arn:aws:iam:::root")
    assert history.terminal_state == "completed"
    assert history.upload_id == upload_id
    assert history.key == "docs/direct.bin"
    assert history.file_name == "direct.bin"
    assert history.file_size == 8
    assert history.part_count == 3
    assert history.uploaded_size == 8
    assert history.content_type == "text/plain"
    assert history.etag =~ "-"
    refute inspect(history) =~ "X-Amz-Signature"

    get = SigV4Request.signed_conn(:get, "/direct-bucket/docs/direct.bin") |> s3_call()
    assert get.status == 200
    assert get.resp_body == "AAABBBCC"
    assert get_resp_header(get, "content-type") == ["text/plain"]
  end

  test "signed CreateMultipartUpload content-type must be sent unchanged", %{conn: conn} do
    init =
      conn
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/header.bin", %{
        "size" => "3",
        "part_size" => "3",
        "content_type" => "text/plain",
        "expires_in" => "600",
        "file_name" => "header.bin",
        "file_last_modified" => "1710000000000"
      })
      |> json_response(200)

    tampered = Map.put(init["create"], "headers", [])
    denied = s3_request(tampered, "")
    assert denied.status == 403
    assert denied.resp_body =~ "SignatureDoesNotMatch"

    ok = s3_request(init["create"], "")
    assert ok.status == 200
  end

  test "direct multipart advanced headers are signed and requester pays is replayed", %{
    conn: conn
  } do
    init =
      conn
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/advanced.bin", %{
        "size" => "4",
        "part_size" => "4",
        "content_type" => "application/custom",
        "expires_in" => "600",
        "file_name" => "advanced.bin",
        "file_last_modified" => "1710000000000",
        "storage_class" => "STANDARD_IA",
        "cache_control" => "max-age=3600",
        "content_disposition" => "attachment; filename=\"advanced.bin\"",
        "content_encoding" => "identity",
        "expires" => "Wed, 21 Oct 2037 07:28:00 GMT",
        "metadata" => "origin=console\nteam=storage",
        "tagging" => "env=prod\nteam=storage",
        "sse_algorithm" => "aws:kms",
        "sse_kms_key_id" => "alias/maxio-local",
        "sse_context" => Base.encode64(~s({"tenant":"console"})),
        "sse_bucket_key" => true,
        "request_payer" => true,
        "checksum_algorithm" => "CRC32C",
        "checksum_type" => "COMPOSITE"
      })
      |> json_response(200)

    create_headers = header_map(init["create"])
    assert create_headers["content-type"] == "application/custom"
    assert create_headers["x-amz-storage-class"] == "STANDARD_IA"
    assert create_headers["cache-control"] == "max-age=3600"
    assert create_headers["content-disposition"] == "attachment; filename=\"advanced.bin\""
    assert create_headers["content-encoding"] == "identity"
    assert create_headers["expires"] == "Wed, 21 Oct 2037 07:28:00 GMT"
    assert create_headers["x-amz-meta-origin"] == "console"
    assert create_headers["x-amz-meta-team"] == "storage"
    assert create_headers["x-amz-tagging"] == "env=prod&team=storage"
    assert create_headers["x-amz-server-side-encryption"] == "aws:kms"
    assert create_headers["x-amz-server-side-encryption-aws-kms-key-id"] == "alias/maxio-local"
    assert create_headers["x-amz-server-side-encryption-bucket-key-enabled"] == "true"
    assert create_headers["x-amz-checksum-algorithm"] == "CRC32C"
    assert create_headers["x-amz-checksum-type"] == "COMPOSITE"
    assert create_headers["x-amz-request-payer"] == "requester"
    assert init["request_payer"] == true

    create_query =
      init["create"]["url"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert create_query["x-maxio-console-request-payer"] == "1"

    create = s3_request(init["create"], "")
    assert create.status == 200
    upload_id = upload_id_from_xml(create.resp_body)

    tampered_register =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/register/docs/advanced.bin", %{
        "upload_id" => upload_id,
        "size" => "4",
        "part_size" => "4",
        "file_name" => "advanced.bin",
        "file_last_modified" => "1710000000000",
        "request_payer" => false
      })
      |> json_response(200)

    assert tampered_register["session"]["request_payer"] == true

    sign =
      conn
      |> recycle()
      |> log_in_console()
      |> post(
        "/console/api/buckets/direct-bucket/direct-multipart/sign-parts/docs/advanced.bin",
        %{
          "upload_id" => upload_id,
          "part_numbers" => [1],
          "expires_in" => "600"
        }
      )
      |> json_response(200)

    [part] = sign["parts"]
    assert header_map(part)["x-amz-request-payer"] == "requester"

    complete =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/complete/docs/advanced.bin", %{
        "upload_id" => upload_id,
        "parts" => [%{"part_number" => 1, "etag" => "0123456789abcdef0123456789abcdef"}],
        "expires_in" => "600"
      })
      |> json_response(200)

    complete_headers = header_map(complete["complete"])
    assert complete_headers["x-amz-request-payer"] == "requester"
    assert complete_headers["x-amz-mp-object-size"] == "4"

    abort =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/abort/docs/advanced.bin", %{
        "upload_id" => upload_id,
        "expires_in" => "600"
      })
      |> json_response(200)

    assert header_map(abort["abort"])["x-amz-request-payer"] == "requester"
  end

  test "direct multipart SSE-C signs transient customer headers without persisting raw key", %{
    conn: conn
  } do
    customer_key = :binary.copy(<<42>>, 32)
    customer_key_b64 = Base.encode64(customer_key)
    key_md5_b64 = :crypto.hash(:md5, customer_key) |> Base.encode64()
    wrong_key_b64 = Base.encode64(:binary.copy(<<43>>, 32))

    init =
      conn
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/sse-c.bin", %{
        "size" => "6",
        "part_size" => "3",
        "content_type" => "application/octet-stream",
        "expires_in" => "600",
        "file_name" => "sse-c.bin",
        "file_last_modified" => "1710000000001",
        "sse_customer_key" => customer_key_b64
      })
      |> json_response(200)

    create_headers = header_map(init["create"])
    assert init["sse_customer_key_required"] == true
    assert create_headers["x-amz-server-side-encryption-customer-algorithm"] == "AES256"
    assert create_headers["x-amz-server-side-encryption-customer-key"] == customer_key_b64
    assert create_headers["x-amz-server-side-encryption-customer-key-md5"] == key_md5_b64
    refute init["create"]["url"] =~ customer_key_b64
    refute init["create"]["url"] =~ URI.encode_www_form(customer_key_b64)

    create = s3_request(init["create"], "")
    assert create.status == 200

    assert get_resp_header(create, "x-amz-server-side-encryption-customer-algorithm") == [
             "AES256"
           ]

    assert get_resp_header(create, "x-amz-server-side-encryption-customer-key-md5") == [
             key_md5_b64
           ]

    upload_id = upload_id_from_xml(create.resp_body)

    assert {:ok, upload} = Multipart.get_upload("direct-bucket", "docs/sse-c.bin", upload_id)
    assert upload.sse_algorithm == "SSE-C"
    refute inspect(upload.sse_envelope) =~ customer_key_b64

    lookup =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/lookup/docs/sse-c.bin", %{
        "size" => "6",
        "file_last_modified" => "1710000000001"
      })
      |> json_response(200)

    assert lookup["session"]["sse_customer_key_required"] == true
    refute inspect(lookup["session"]) =~ customer_key_b64

    missing_key =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/sign-parts/docs/sse-c.bin", %{
        "upload_id" => upload_id,
        "part_numbers" => [1],
        "expires_in" => "600"
      })

    assert json_response(missing_key, 400)["error"] == "sse_customer_key_required"

    wrong_key =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/sign-parts/docs/sse-c.bin", %{
        "upload_id" => upload_id,
        "part_numbers" => [1],
        "expires_in" => "600",
        "sse_customer_key" => wrong_key_b64
      })

    assert json_response(wrong_key, 400)["error"] == "invalid_sse"

    sign =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/sign-parts/docs/sse-c.bin", %{
        "upload_id" => upload_id,
        "part_numbers" => [1, 2],
        "expires_in" => "600",
        "sse_customer_key" => customer_key_b64
      })
      |> json_response(200)

    for part <- sign["parts"] do
      part_headers = header_map(part)
      assert part_headers["x-amz-server-side-encryption-customer-algorithm"] == "AES256"
      assert part_headers["x-amz-server-side-encryption-customer-key"] == customer_key_b64
      assert part_headers["x-amz-server-side-encryption-customer-key-md5"] == key_md5_b64
    end

    abort =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/abort/docs/sse-c.bin", %{
        "upload_id" => upload_id,
        "expires_in" => "600",
        "sse_customer_key" => customer_key_b64
      })
      |> json_response(200)

    refute Map.has_key?(header_map(abort["abort"]), "x-amz-server-side-encryption-customer-key")

    etags =
      [{"AAA", 1}, {"BBB", 2}]
      |> Enum.map(fn {body, part_number} ->
        request = Enum.find(sign["parts"], &(&1["part_number"] == part_number))
        put = s3_request(request, body)
        assert put.status == 200

        [etag] = get_resp_header(put, "etag")
        %{"part_number" => part_number, "etag" => etag}
      end)

    list =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/list-parts/docs/sse-c.bin", %{
        "upload_id" => upload_id,
        "max_parts" => 100,
        "expires_in" => "600",
        "sse_customer_key" => customer_key_b64
      })
      |> json_response(200)

    refute Map.has_key?(
             header_map(list["list_parts"]),
             "x-amz-server-side-encryption-customer-key"
           )

    listed = s3_request(list["list_parts"], "")
    assert listed.status == 200
    assert listed.resp_body =~ "<PartNumber>1</PartNumber>"

    missing_complete_key =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/complete/docs/sse-c.bin", %{
        "upload_id" => upload_id,
        "parts" => etags,
        "expires_in" => "600"
      })

    assert json_response(missing_complete_key, 400)["error"] == "sse_customer_key_required"

    complete =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/complete/docs/sse-c.bin", %{
        "upload_id" => upload_id,
        "parts" => etags,
        "expires_in" => "600",
        "sse_customer_key" => customer_key_b64
      })
      |> json_response(200)

    complete_headers = header_map(complete["complete"])
    assert complete_headers["x-amz-server-side-encryption-customer-algorithm"] == "AES256"
    assert complete_headers["x-amz-server-side-encryption-customer-key"] == customer_key_b64
    assert complete_headers["x-amz-server-side-encryption-customer-key-md5"] == key_md5_b64

    done = s3_request(complete["complete"], complete["complete"]["body"])
    assert done.status == 200
    assert get_resp_header(done, "x-amz-server-side-encryption-customer-algorithm") == ["AES256"]
    assert get_resp_header(done, "x-amz-server-side-encryption-customer-key-md5") == [key_md5_b64]

    assert {:ok, object} = Maxio.Objects.get_metadata("direct-bucket", "docs/sse-c.bin")
    assert object.sse_algorithm == "SSE-C"
    refute inspect(object.sse_envelope) =~ customer_key_b64

    denied_get = SigV4Request.signed_conn(:get, "/direct-bucket/docs/sse-c.bin") |> s3_call()
    assert denied_get.status == 400
    assert denied_get.resp_body =~ "InvalidArgument"

    get =
      SigV4Request.signed_conn(:get, "/direct-bucket/docs/sse-c.bin",
        headers: sse_c_headers(customer_key)
      )
      |> s3_call()

    assert get.status == 200
    assert get.resp_body == "AAABBB"

    assert get_resp_header(get, "x-amz-server-side-encryption-customer-key-md5") == [
             key_md5_b64
           ]
  end

  test "direct multipart rejects SSE-C request headers for non-SSE-C uploads", %{conn: conn} do
    customer_key_b64 = Base.encode64(:binary.copy(<<44>>, 32))

    init =
      conn
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/plain.bin", %{
        "size" => "3",
        "part_size" => "3",
        "content_type" => "application/octet-stream",
        "expires_in" => "600",
        "file_name" => "plain.bin",
        "file_last_modified" => "1710000000002"
      })
      |> json_response(200)

    assert init["sse_customer_key_required"] == false
    create = s3_request(init["create"], "")
    assert create.status == 200
    upload_id = upload_id_from_xml(create.resp_body)

    sign =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/sign-parts/docs/plain.bin", %{
        "upload_id" => upload_id,
        "part_numbers" => [1],
        "expires_in" => "600",
        "sse_customer_key" => customer_key_b64
      })

    assert json_response(sign, 400)["error"] == "invalid_sse"

    complete =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/complete/docs/plain.bin", %{
        "upload_id" => upload_id,
        "parts" => [%{"part_number" => 1, "etag" => "0123456789abcdef0123456789abcdef"}],
        "expires_in" => "600",
        "sse_customer_key" => customer_key_b64
      })

    assert json_response(complete, 400)["error"] == "invalid_sse"
  end

  test "Console direct CreateMultipartUpload fails closed without valid registry intent" do
    missing_intent =
      SigV4Request.presigned_conn(:post, "/direct-bucket/docs/missing-intent.bin",
        query: DirectMultipartUpload.marker_query(%{"uploads" => ""})
      )
      |> s3_call()

    assert missing_intent.status == 400
    assert missing_intent.resp_body =~ "InvalidArgument"

    invalid_part_size =
      SigV4Request.presigned_conn(:post, "/direct-bucket/docs/invalid-intent.bin",
        query:
          DirectMultipartUpload.marker_query(%{
            "uploads" => "",
            "x-maxio-console-registry" => "1",
            "x-maxio-console-file-name" => "invalid-intent.bin",
            "x-maxio-console-file-size" => "8",
            "x-maxio-console-file-last-modified" => "1710000000000",
            "x-maxio-console-part-size" => "0"
          })
      )
      |> s3_call()

    assert invalid_part_size.status == 400
    assert invalid_part_size.resp_body =~ "InvalidArgument"

    assert %{uploads: []} = Multipart.list_uploads("direct-bucket", %{prefix: "docs/missing"})
    assert %{uploads: []} = Multipart.list_uploads("direct-bucket", %{prefix: "docs/invalid"})
  end

  test "direct multipart marker rejects unsigned semantic x-amz headers", %{conn: conn} do
    init =
      conn
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/unsigned.bin", %{
        "size" => "3",
        "part_size" => "3",
        "content_type" => "application/octet-stream",
        "expires_in" => "600",
        "file_name" => "unsigned.bin",
        "file_last_modified" => "1710000000000"
      })
      |> json_response(200)

    create = s3_request(init["create"], "")
    assert create.status == 200
    upload_id = upload_id_from_xml(create.resp_body)

    sign =
      conn
      |> recycle()
      |> log_in_console()
      |> post(
        "/console/api/buckets/direct-bucket/direct-multipart/sign-parts/docs/unsigned.bin",
        %{
          "upload_id" => upload_id,
          "part_numbers" => [1],
          "expires_in" => "600"
        }
      )
      |> json_response(200)

    [part] = sign["parts"]

    tampered =
      Map.update!(part, "headers", fn headers ->
        [%{"name" => "x-amz-copy-source", "value" => "/direct-bucket/source.bin"} | headers]
      end)

    denied = s3_request(tampered, "")
    assert denied.status == 400
    assert denied.resp_body =~ "AccessDenied"
  end

  test "direct multipart marker rejects unsigned object metadata headers", %{conn: conn} do
    init =
      conn
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/cache.bin", %{
        "size" => "3",
        "part_size" => "3",
        "content_type" => "application/octet-stream",
        "expires_in" => "600",
        "file_name" => "cache.bin",
        "file_last_modified" => "1710000000000"
      })
      |> json_response(200)

    tampered =
      Map.update!(init["create"], "headers", fn headers ->
        [%{"name" => "cache-control", "value" => "no-store"} | headers]
      end)

    denied = s3_request(tampered, "")
    assert denied.status == 400
    assert denied.resp_body =~ "AccessDenied"
  end

  test "part presigned URL query parameters are tamper resistant", %{conn: conn} do
    init =
      conn
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/tamper.bin", %{
        "size" => "3",
        "part_size" => "3",
        "content_type" => "application/octet-stream",
        "expires_in" => "600",
        "file_name" => "tamper.bin",
        "file_last_modified" => "1710000000000"
      })
      |> json_response(200)

    create = s3_request(init["create"], "")
    assert create.status == 200
    upload_id = upload_id_from_xml(create.resp_body)

    sign =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/sign-parts/docs/tamper.bin", %{
        "upload_id" => upload_id,
        "part_numbers" => [1],
        "expires_in" => "600"
      })
      |> json_response(200)

    [part] = sign["parts"]
    tampered = Map.update!(part, "url", &String.replace(&1, "partNumber=1", "partNumber=2"))
    denied = s3_request(tampered, "ABC")

    assert denied.status == 403
    assert denied.resp_body =~ "SignatureDoesNotMatch"
  end

  test "complete multipart body is bound by signed Content-MD5", %{conn: conn} do
    init =
      conn
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/md5.bin", %{
        "size" => "3",
        "part_size" => "3",
        "content_type" => "application/octet-stream",
        "expires_in" => "600",
        "file_name" => "md5.bin",
        "file_last_modified" => "1710000000000"
      })
      |> json_response(200)

    create = s3_request(init["create"], "")
    assert create.status == 200
    upload_id = upload_id_from_xml(create.resp_body)

    sign =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/sign-parts/docs/md5.bin", %{
        "upload_id" => upload_id,
        "part_numbers" => [1],
        "expires_in" => "600"
      })
      |> json_response(200)

    [part] = sign["parts"]
    put = s3_request(part, "ABC")
    assert put.status == 200
    [etag] = get_resp_header(put, "etag")

    complete =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/complete/docs/md5.bin", %{
        "upload_id" => upload_id,
        "parts" => [%{"part_number" => 1, "etag" => etag}],
        "expires_in" => "600"
      })
      |> json_response(200)

    tampered_body =
      String.replace(complete["complete"]["body"], etag, "\"deadbeefdeadbeefdeadbeefdeadbeef\"")

    denied = s3_request(complete["complete"], tampered_body)

    assert denied.status == 400
    assert denied.resp_body =~ "BadDigest"
  end

  test "abort presign removes the in-flight multipart upload", %{conn: conn} do
    init =
      conn
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/abort.bin", %{
        "size" => "3",
        "part_size" => "3",
        "content_type" => "application/octet-stream",
        "expires_in" => "600",
        "file_name" => "abort.bin",
        "file_last_modified" => "1710000000000"
      })
      |> json_response(200)

    create = s3_request(init["create"], "")
    assert create.status == 200
    upload_id = upload_id_from_xml(create.resp_body)

    _register =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/register/docs/abort.bin", %{
        "upload_id" => upload_id,
        "size" => "3",
        "part_size" => "3",
        "file_name" => "abort.bin",
        "file_last_modified" => "1710000000000"
      })
      |> json_response(200)

    abort =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/abort/docs/abort.bin", %{
        "upload_id" => upload_id,
        "expires_in" => "600"
      })
      |> json_response(200)

    deleted = s3_request(abort["abort"], "")
    assert deleted.status == 204

    [history] = DirectMultipartUpload.list_history("direct-bucket", "docs/", "arn:aws:iam:::root")
    assert history.terminal_state == "aborted"
    assert history.upload_id == upload_id
    assert history.key == "docs/abort.bin"
    assert history.file_name == "abort.bin"
    assert history.etag == nil
    assert history.version_id == nil

    assert {:error, :not_found} =
             DirectMultipartUpload.lookup_for_file(
               "direct-bucket",
               "docs/abort.bin",
               "arn:aws:iam:::root",
               3,
               1_710_000_000_000
             )

    missing =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/sign-parts/docs/abort.bin", %{
        "upload_id" => upload_id,
        "part_numbers" => [1],
        "expires_in" => "600"
      })

    assert json_response(missing, 404)["error"] == "no_such_upload"

    missing_list =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/list-parts/docs/abort.bin", %{
        "upload_id" => upload_id
      })

    assert json_response(missing_list, 404)["error"] == "no_such_upload"
  end

  test "S3 abort failure does not record aborted terminal history", %{conn: conn} do
    init =
      conn
      |> post(
        "/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/abort-fail.bin",
        %{
          "size" => "3",
          "part_size" => "3",
          "content_type" => "application/octet-stream",
          "expires_in" => "600",
          "file_name" => "abort-fail.bin",
          "file_last_modified" => "1710000000000"
        }
      )
      |> json_response(200)

    create = s3_request(init["create"], "")
    assert create.status == 200
    upload_id = upload_id_from_xml(create.resp_body)

    sign =
      conn
      |> recycle()
      |> log_in_console()
      |> post(
        "/console/api/buckets/direct-bucket/direct-multipart/sign-parts/docs/abort-fail.bin",
        %{
          "upload_id" => upload_id,
          "part_numbers" => [1],
          "expires_in" => "600"
        }
      )
      |> json_response(200)

    [part] = sign["parts"]
    put = s3_request(part, "ABC")
    assert put.status == 200

    abort =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/abort/docs/abort-fail.bin", %{
        "upload_id" => upload_id,
        "expires_in" => "600"
      })
      |> json_response(200)

    previous = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Test.StorageAbortFailBackend)

    try do
      failed = s3_request(abort["abort"], "")
      assert failed.status == 500
      assert failed.resp_body =~ "InternalError"
    after
      Application.put_env(:maxio, :storage_backend, previous)
    end

    assert [] = DirectMultipartUpload.list_history("direct-bucket", "docs/", "arn:aws:iam:::root")

    assert {:ok, _upload} =
             Multipart.get_upload("direct-bucket", "docs/abort-fail.bin", upload_id)
  end

  test "S3 abort storage error returns SlowDownWrite and preserves active upload", %{conn: conn} do
    init =
      conn
      |> post(
        "/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/abort-error.bin",
        %{
          "size" => "3",
          "part_size" => "3",
          "content_type" => "application/octet-stream",
          "expires_in" => "600",
          "file_name" => "abort-error.bin",
          "file_last_modified" => "1710000000000"
        }
      )
      |> json_response(200)

    create = s3_request(init["create"], "")
    assert create.status == 200
    upload_id = upload_id_from_xml(create.resp_body)

    abort =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/abort/docs/abort-error.bin", %{
        "upload_id" => upload_id,
        "expires_in" => "600"
      })
      |> json_response(200)

    previous = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Test.StorageAbortErrorBackend)

    try do
      failed = s3_request(abort["abort"], "")
      assert failed.status == 503
      assert failed.resp_body =~ "SlowDownWrite"
    after
      Application.put_env(:maxio, :storage_backend, previous)
    end

    assert [] = DirectMultipartUpload.list_history("direct-bucket", "docs/", "arn:aws:iam:::root")

    assert {:ok, _upload} =
             Multipart.get_upload("direct-bucket", "docs/abort-error.bin", upload_id)
  end

  test "complete success removes active registry when terminal cleanup returns an error", %{
    conn: conn
  } do
    init =
      conn
      |> post(
        "/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/complete-cleanup.bin",
        %{
          "size" => "3",
          "part_size" => "3",
          "content_type" => "application/octet-stream",
          "expires_in" => "600",
          "file_name" => "complete-cleanup.bin",
          "file_last_modified" => "1710000000000"
        }
      )
      |> json_response(200)

    create = s3_request(init["create"], "")
    assert create.status == 200
    upload_id = upload_id_from_xml(create.resp_body)

    sign =
      conn
      |> recycle()
      |> log_in_console()
      |> post(
        "/console/api/buckets/direct-bucket/direct-multipart/sign-parts/docs/complete-cleanup.bin",
        %{
          "upload_id" => upload_id,
          "part_numbers" => [1],
          "expires_in" => "600"
        }
      )
      |> json_response(200)

    [part] = sign["parts"]
    put = s3_request(part, "ABC")
    assert put.status == 200
    [etag] = get_resp_header(put, "etag")

    complete =
      conn
      |> recycle()
      |> log_in_console()
      |> post(
        "/console/api/buckets/direct-bucket/direct-multipart/complete/docs/complete-cleanup.bin",
        %{
          "upload_id" => upload_id,
          "parts" => [%{"part_number" => 1, "etag" => etag}],
          "expires_in" => "600",
          "size" => "3"
        }
      )
      |> json_response(200)

    previous = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Test.StorageAbortErrorBackend)

    try do
      completed = s3_request(complete["complete"], complete["complete"]["body"])
      assert completed.status == 200
      assert completed.resp_body =~ "<CompleteMultipartUploadResult"
    after
      Application.put_env(:maxio, :storage_backend, previous)
    end

    assert {:error, :not_found} =
             Multipart.get_upload("direct-bucket", "docs/complete-cleanup.bin", upload_id)

    assert [] = DirectMultipartUpload.list_active("direct-bucket", "docs/", "arn:aws:iam:::root")

    [history] = DirectMultipartUpload.list_history("direct-bucket", "docs/", "arn:aws:iam:::root")
    assert history.terminal_state == "completed"
    assert history.upload_id == upload_id
  end

  test "invalid direct multipart API input fails closed", %{conn: conn} do
    too_small_part =
      conn
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/bad.bin", %{
        "size" => "8",
        "part_size" => "0",
        "content_type" => "text/plain",
        "file_name" => "bad.bin",
        "file_last_modified" => "1710000000000"
      })

    assert json_response(too_small_part, 400)["error"] == "invalid_part_size"

    bad_complete =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/complete/docs/bad.bin", %{
        "upload_id" => "missing",
        "parts" => [%{"part_number" => 2, "etag" => "0"}]
      })

    assert json_response(bad_complete, 404)["error"] == "no_such_upload"

    too_long_expires =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/bad.bin", %{
        "size" => "8",
        "part_size" => "3",
        "content_type" => "text/plain",
        "expires_in" => "901",
        "file_name" => "bad.bin",
        "file_last_modified" => "1710000000000"
      })

    assert json_response(too_long_expires, 400)["error"] == "invalid_expires"

    init =
      conn
      |> recycle()
      |> log_in_console()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/list-bad.bin", %{
        "size" => "3",
        "part_size" => "3",
        "content_type" => "application/octet-stream",
        "file_name" => "list-bad.bin",
        "file_last_modified" => "1710000000000"
      })
      |> json_response(200)

    create = s3_request(init["create"], "")
    assert create.status == 200
    upload_id = upload_id_from_xml(create.resp_body)

    bad_marker =
      conn
      |> recycle()
      |> log_in_console()
      |> post(
        "/console/api/buckets/direct-bucket/direct-multipart/list-parts/docs/list-bad.bin",
        %{
          "upload_id" => upload_id,
          "part_number_marker" => "-1"
        }
      )

    assert json_response(bad_marker, 400)["error"] == "invalid_part_number_marker"

    bad_max_parts =
      conn
      |> recycle()
      |> log_in_console()
      |> post(
        "/console/api/buckets/direct-bucket/direct-multipart/list-parts/docs/list-bad.bin",
        %{
          "upload_id" => upload_id,
          "max_parts" => "1001"
        }
      )

    assert json_response(bad_max_parts, 400)["error"] == "invalid_max_parts"
  end

  test "direct multipart advanced JSON fields reject non-string values", %{conn: conn} do
    base_params = %{
      "size" => "3",
      "part_size" => "3",
      "content_type" => "application/octet-stream",
      "file_name" => "bad-json.bin",
      "file_last_modified" => "1710000000000"
    }

    cases = [
      {"cache_control", %{}, "invalid_field"},
      {"storage_class", %{}, "invalid_storage_class"},
      {"metadata", ["team=storage"], "invalid_metadata"},
      {"tagging", %{"team" => "storage"}, "invalid_tag"},
      {"sse_algorithm", [], "invalid_sse"},
      {"sse_bucket_key", %{}, "invalid_sse"},
      {"checksum_algorithm", %{}, "invalid_checksum"},
      {"request_payer", %{}, "invalid_request_payer"}
    ]

    for {field, value, error} <- cases do
      response =
        conn
        |> recycle()
        |> log_in_console()
        |> put_req_header("content-type", "application/json")
        |> post(
          "/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/#{field}.bin",
          Jason.encode!(Map.put(base_params, field, value))
        )

      assert json_response(response, 400)["error"] == error
    end
  end

  test "direct multipart registry and signing are owner scoped", %{conn: conn} do
    :ok =
      CredentialStore.put_access_key(%{
        access_key: "OTHERDIRECT",
        secret_key: "other-secret",
        principal: %{
          type: :iam_user,
          access_key: "OTHERDIRECT",
          arn: "arn:aws:iam:::user/other-direct"
        }
      })

    on_exit(fn -> CredentialStore.invalidate({:access_key, "OTHERDIRECT"}) end)

    init =
      conn
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/owner.bin", %{
        "size" => "3",
        "part_size" => "3",
        "content_type" => "application/octet-stream",
        "file_name" => "owner.bin",
        "file_last_modified" => "1710000000000"
      })
      |> json_response(200)

    create = s3_request(init["create"], "")
    assert create.status == 200
    upload_id = upload_id_from_xml(create.resp_body)

    denied =
      conn
      |> recycle()
      |> log_in_console("OTHERDIRECT")
      |> post("/console/api/buckets/direct-bucket/direct-multipart/sign-parts/docs/owner.bin", %{
        "upload_id" => upload_id,
        "part_numbers" => [1]
      })

    assert json_response(denied, 403)["error"] == "access_denied"

    denied_register =
      conn
      |> recycle()
      |> log_in_console("OTHERDIRECT")
      |> post("/console/api/buckets/direct-bucket/direct-multipart/register/docs/owner.bin", %{
        "upload_id" => upload_id,
        "size" => "3",
        "part_size" => "3",
        "file_name" => "owner.bin",
        "file_last_modified" => "1710000000000"
      })

    assert json_response(denied_register, 403)["error"] == "access_denied"
  end

  test "initiate raises part size to keep uploads within S3 part count limit", %{conn: conn} do
    init =
      conn
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/large.bin", %{
        "size" => Integer.to_string(10_000 * 3 + 1),
        "part_size" => "3",
        "content_type" => "application/octet-stream",
        "file_name" => "large.bin",
        "file_last_modified" => "1710000000000"
      })
      |> json_response(200)

    assert init["part_size"] == 4
  end

  test "direct multipart API requires Console session", %{conn: conn} do
    response =
      conn
      |> recycle()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/initiate/docs/auth.bin", %{
        "size" => "3",
        "part_size" => "3",
        "file_name" => "auth.bin",
        "file_last_modified" => "1710000000000"
      })

    assert response.status == 302
    assert get_resp_header(response, "location") == ["/login"]

    response =
      conn
      |> recycle()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/list-parts/docs/auth.bin", %{
        "upload_id" => "missing"
      })

    assert response.status == 302
    assert get_resp_header(response, "location") == ["/login"]

    response =
      conn
      |> recycle()
      |> post("/console/api/buckets/direct-bucket/direct-multipart/register/docs/auth.bin", %{
        "upload_id" => "missing"
      })

    assert response.status == 302
    assert get_resp_header(response, "location") == ["/login"]
  end

  defp s3_request(%{"method" => method, "url" => url, "headers" => headers}, body) do
    uri = URI.parse(url)
    path = uri.path <> if(uri.query, do: "?" <> uri.query, else: "")

    method
    |> Plug.Test.conn(path, body)
    |> Map.put(:host, uri.host)
    |> Map.put(:port, uri.port || default_port(uri.scheme))
    |> put_headers(headers)
    |> s3_call()
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers || [], conn, fn %{"name" => name, "value" => value}, acc ->
      put_req_header(acc, String.downcase(name), value)
    end)
  end

  defp header_map(%{"headers" => headers}) do
    Map.new(headers, fn %{"name" => name, "value" => value} -> {String.downcase(name), value} end)
  end

  defp upload_id_from_xml(xml) do
    [_, upload_id] = Regex.run(~r/<UploadId>([^<]+)<\/UploadId>/, xml)
    upload_id
  end

  defp sse_c_headers(customer_key) do
    [
      {"x-amz-server-side-encryption-customer-algorithm", "AES256"},
      {"x-amz-server-side-encryption-customer-key", Base.encode64(customer_key)},
      {"x-amz-server-side-encryption-customer-key-md5",
       :crypto.hash(:md5, customer_key) |> Base.encode64()}
    ]
  end

  defp s3_call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 80

  defp put_console_s3_public_url(url) do
    previous = Application.get_env(:maxio, :console, :__unset__)
    Application.put_env(:maxio, :console, s3_public_url: url)

    on_exit(fn -> restore_env(:console, previous) end)
  end

  defp configure_min_part_size!(size) do
    previous = Application.get_env(:maxio, :multipart_min_part_size, :__unset__)
    Application.put_env(:maxio, :multipart_min_part_size, size)

    on_exit(fn -> restore_env(:multipart_min_part_size, previous) end)
  end

  defp restore_env(key, :__unset__), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
