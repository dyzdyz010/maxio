defmodule Maxio.S3.ObjectAttributesTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Auth.CredentialStore
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_object_attributes_test")
  @alice_ak "AKIAOBJECTATTR0001"
  @alice_secret "objectattributessecret0000001"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
  @owner "000000000000"
  @other_owner "999999999999"
  @requester """
  <RequestPaymentConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Payer>Requester</Payer>
  </RequestPaymentConfiguration>
  """

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    prev_min_part_size = Application.get_env(:maxio, :multipart_min_part_size)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    Application.put_env(:maxio, :multipart_min_part_size, 1)

    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)

      if prev_min_part_size,
        do: Application.put_env(:maxio, :multipart_min_part_size, prev_min_part_size),
        else: Application.delete_env(:maxio, :multipart_min_part_size)

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

  test "GetObjectAttributes returns requested object metadata" do
    SigV4Request.signed_conn(:put, "/attrs") |> call()

    body = "attribute body"
    checksum = hash_b64(:sha256, body)

    put =
      SigV4Request.signed_conn(:put, "/attrs/object.bin",
        body: body,
        headers: [
          {"x-amz-storage-class", "STANDARD_IA"},
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum}
        ]
      )
      |> call()

    assert put.status == 200
    [etag] = get_resp_header(put, "etag")

    attrs =
      SigV4Request.signed_conn(:get, "/attrs/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "ETag,ObjectSize,StorageClass,Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<GetObjectAttributesResponse"
    assert attrs.resp_body =~ "<ETag>#{etag}</ETag>"
    assert attrs.resp_body =~ "<ObjectSize>14</ObjectSize>"
    assert attrs.resp_body =~ "<StorageClass>STANDARD_IA</StorageClass>"
    assert attrs.resp_body =~ "<Checksum>"
    assert attrs.resp_body =~ "<ChecksumSHA256>#{checksum}</ChecksumSHA256>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
    assert [_last_modified] = get_resp_header(attrs, "last-modified")
  end

  test "GetObjectAttributes requires x-amz-object-attributes header" do
    SigV4Request.signed_conn(:put, "/attrmissing") |> call()
    SigV4Request.signed_conn(:put, "/attrmissing/object.bin", body: "body") |> call()

    attrs =
      SigV4Request.signed_conn(:get, "/attrmissing/object.bin", query: %{"attributes" => ""})
      |> call()

    assert attrs.status == 400
    assert attrs.resp_body =~ "<Code>InvalidRequest</Code>"
  end

  test "GetObjectAttributes rejects invalid attribute and paging headers" do
    SigV4Request.signed_conn(:put, "/attrinvalid") |> call()
    SigV4Request.signed_conn(:put, "/attrinvalid/object.bin", body: "body") |> call()

    invalid_attribute =
      SigV4Request.signed_conn(:get, "/attrinvalid/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "ObjectSize,UnknownAttribute"}]
      )
      |> call()

    assert invalid_attribute.status == 400
    assert invalid_attribute.resp_body =~ "<Code>InvalidArgument</Code>"

    invalid_max_parts =
      SigV4Request.signed_conn(:get, "/attrinvalid/object.bin",
        query: %{"attributes" => ""},
        headers: [
          {"x-amz-object-attributes", "ObjectParts"},
          {"x-amz-max-parts", "0"}
        ]
      )
      |> call()

    assert invalid_max_parts.status == 400
    assert invalid_max_parts.resp_body =~ "<Code>InvalidArgument</Code>"

    invalid_marker =
      SigV4Request.signed_conn(:get, "/attrinvalid/object.bin",
        query: %{"attributes" => ""},
        headers: [
          {"x-amz-object-attributes", "ObjectParts"},
          {"x-amz-part-number-marker", "-1"}
        ]
      )
      |> call()

    assert invalid_marker.status == 400
    assert invalid_marker.resp_body =~ "<Code>InvalidArgument</Code>"
  end

  test "GetObjectAttributes validates SSE-C customer key before attributes and conditions" do
    bucket = "attrssec"
    key = "secret.bin"
    body = "sse-c object attributes"
    customer_key = :crypto.strong_rand_bytes(32)
    headers = sse_c_headers(customer_key)

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: body,
        headers: headers
      )
      |> call()

    assert put.status == 200
    [etag] = get_resp_header(put, "etag")

    missing_key =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "ObjectSize"}]
      )
      |> call()

    assert missing_key.status == 400
    assert missing_key.resp_body =~ "<Code>InvalidArgument</Code>"

    partial_headers =
      [
        {"x-amz-object-attributes", "ObjectSize"},
        {"x-amz-server-side-encryption-customer-algorithm", "AES256"},
        {"x-amz-server-side-encryption-customer-key", Base.encode64(customer_key)}
      ]

    partial_key =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        query: %{"attributes" => ""},
        headers: partial_headers
      )
      |> call()

    assert partial_key.status == 400
    assert partial_key.resp_body =~ "<Code>InvalidArgument</Code>"

    wrong_key =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        query: %{"attributes" => ""},
        headers: [
          {"x-amz-object-attributes", "ObjectSize"} | sse_c_headers(:crypto.strong_rand_bytes(32))
        ]
      )
      |> call()

    assert wrong_key.status == 400
    assert wrong_key.resp_body =~ "<Code>InvalidArgument</Code>"

    conditional_missing_key =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        query: %{"attributes" => ""},
        headers: [
          {"x-amz-object-attributes", "ObjectSize"},
          {"if-none-match", etag}
        ]
      )
      |> call()

    assert conditional_missing_key.status == 400
    assert conditional_missing_key.resp_body =~ "<Code>InvalidArgument</Code>"

    ok =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "ObjectSize"} | headers]
      )
      |> call()

    assert ok.status == 200
    assert ok.resp_body =~ "<ObjectSize>#{byte_size(body)}</ObjectSize>"

    conditional_ok =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        query: %{"attributes" => ""},
        headers: [
          {"x-amz-object-attributes", "ObjectSize"},
          {"if-none-match", etag}
          | headers
        ]
      )
      |> call()

    assert conditional_ok.status == 304
    assert conditional_ok.resp_body == ""
  end

  test "GetObjectAttributes rejects encryption write headers on managed SSE reads" do
    for {bucket, algorithm} <- [
          {"attrsseaesreadheaders", "AES256"},
          {"attrkmsreadheaders", "aws:kms"},
          {"attrdssereadheaders", "aws:kms:dsse"}
        ] do
      key = "object.bin"

      SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

      put =
        SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
          body: "#{algorithm} object attributes",
          headers: [{"x-amz-server-side-encryption", algorithm}]
        )
        |> call()

      assert put.status == 200

      attrs =
        SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
          query: %{"attributes" => ""},
          headers: [
            {"x-amz-object-attributes", "ObjectSize"},
            {"x-amz-server-side-encryption", algorithm}
          ]
        )
        |> call()

      assert attrs.status == 400
      assert attrs.resp_body =~ "<Code>InvalidRequest</Code>"
    end
  end

  test "GetObjectAttributes returns default CRC64NVME checksum when no modeled checksum is supplied" do
    SigV4Request.signed_conn(:put, "/attrnochecksum") |> call()
    checksum = crc64nvme_b64("body")
    put = SigV4Request.signed_conn(:put, "/attrnochecksum/object.bin", body: "body") |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-crc64nvme") == [checksum]

    attrs =
      SigV4Request.signed_conn(:get, "/attrnochecksum/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum,ObjectSize"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ObjectSize>4</ObjectSize>"
    assert attrs.resp_body =~ "<Checksum>"
    assert attrs.resp_body =~ "<ChecksumCRC64NVME>#{checksum}</ChecksumCRC64NVME>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
  end

  test "GetObjectAttributes returns completed multipart ObjectParts with pagination" do
    SigV4Request.signed_conn(:put, "/attrparts") |> call()
    checksums = [hash_b64(:sha256, "first part"), hash_b64(:sha256, "second part")]

    complete_multipart_object!("attrparts", "object.bin", [
      {"first part", [{"x-amz-checksum-sha256", Enum.at(checksums, 0)}]},
      {"second part", [{"x-amz-checksum-sha256", Enum.at(checksums, 1)}]}
    ])

    first_page =
      SigV4Request.signed_conn(:get, "/attrparts/object.bin",
        query: %{"attributes" => ""},
        headers: [
          {"x-amz-object-attributes", "ObjectParts,ObjectSize"},
          {"x-amz-max-parts", "1"}
        ]
      )
      |> call()

    assert first_page.status == 200
    assert first_page.resp_body =~ "<ObjectSize>21</ObjectSize>"
    assert first_page.resp_body =~ "<ObjectParts>"
    assert first_page.resp_body =~ "<IsTruncated>true</IsTruncated>"
    assert first_page.resp_body =~ "<MaxParts>1</MaxParts>"
    assert first_page.resp_body =~ "<NextPartNumberMarker>1</NextPartNumberMarker>"
    assert first_page.resp_body =~ "<PartNumberMarker>0</PartNumberMarker>"
    assert first_page.resp_body =~ "<PartsCount>2</PartsCount>"
    assert first_page.resp_body =~ "<PartNumber>1</PartNumber>"
    assert first_page.resp_body =~ "<Size>10</Size>"
    assert first_page.resp_body =~ "<ChecksumSHA256>#{Enum.at(checksums, 0)}</ChecksumSHA256>"
    refute first_page.resp_body =~ "<PartNumber>2</PartNumber>"

    second_page =
      SigV4Request.signed_conn(:get, "/attrparts/object.bin",
        query: %{"attributes" => ""},
        headers: [
          {"x-amz-object-attributes", "ObjectParts"},
          {"x-amz-max-parts", "1"},
          {"x-amz-part-number-marker", "1"}
        ]
      )
      |> call()

    assert second_page.status == 200
    assert second_page.resp_body =~ "<IsTruncated>false</IsTruncated>"
    refute second_page.resp_body =~ "<NextPartNumberMarker>"
    assert second_page.resp_body =~ "<PartNumberMarker>1</PartNumberMarker>"
    assert second_page.resp_body =~ "<PartNumber>2</PartNumber>"
    assert second_page.resp_body =~ "<Size>11</Size>"
    assert second_page.resp_body =~ "<ChecksumSHA256>#{Enum.at(checksums, 1)}</ChecksumSHA256>"
  end

  test "GetObjectAttributes ObjectParts reads completed part metadata from sidecar authority" do
    SigV4Request.signed_conn(:put, "/attrpartsauth") |> call()

    complete_multipart_object!("attrpartsauth", "object.bin", [{"part one", []}, {"part two", []}])

    prev_auth = Application.get_env(:maxio, :authoritative_source)
    Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :pg, write: :pg)

    try do
      attrs =
        SigV4Request.signed_conn(:get, "/attrpartsauth/object.bin",
          query: %{"attributes" => ""},
          headers: [{"x-amz-object-attributes", "ObjectParts"}]
        )
        |> call()

      assert attrs.status == 200
      assert attrs.resp_body =~ "<PartsCount>2</PartsCount>"
      assert attrs.resp_body =~ "<PartNumber>1</PartNumber>"
      assert attrs.resp_body =~ "<Size>8</Size>"
      assert attrs.resp_body =~ "<PartNumber>2</PartNumber>"
    after
      if prev_auth,
        do: Application.put_env(:maxio, :authoritative_source, prev_auth),
        else: Application.delete_env(:maxio, :authoritative_source)
    end
  end

  test "GetObjectAttributes ObjectParts on non-multipart object obeys conditions" do
    SigV4Request.signed_conn(:put, "/attrcondition") |> call()

    put =
      SigV4Request.signed_conn(:put, "/attrcondition/object.bin", body: "body")
      |> call()

    assert put.status == 200
    [etag] = get_resp_header(put, "etag")

    attrs =
      SigV4Request.signed_conn(:get, "/attrcondition/object.bin",
        query: %{"attributes" => ""},
        headers: [
          {"x-amz-object-attributes", "ObjectParts"},
          {"if-none-match", etag}
        ]
      )
      |> call()

    assert attrs.status == 304
    assert attrs.resp_body == ""

    ok =
      SigV4Request.signed_conn(:get, "/attrcondition/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "ObjectParts,ObjectSize"}]
      )
      |> call()

    assert ok.status == 200
    assert ok.resp_body =~ "<ObjectSize>4</ObjectSize>"
    refute ok.resp_body =~ "<ObjectParts>"
  end

  test "GetObjectAttributes omits StorageClass for STANDARD objects" do
    SigV4Request.signed_conn(:put, "/attrstandard") |> call()
    SigV4Request.signed_conn(:put, "/attrstandard/object.bin", body: "body") |> call()

    attrs =
      SigV4Request.signed_conn(:get, "/attrstandard/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "StorageClass,ObjectSize"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ObjectSize>4</ObjectSize>"
    refute attrs.resp_body =~ "<StorageClass>"
  end

  test "GetObjectAttributes enforces Requester Pays for non-owner and charges acknowledged requests" do
    bucket = "attrrequesterpays"
    key = "object.bin"

    assert create_bucket(bucket).status == 200
    assert put_object(bucket, key, "body").status == 200
    assert put_request_payment(bucket).status == 200
    assert :ok = allow_alice_object_attributes(bucket, key)

    missing = alice_attributes(bucket, key)

    assert_xml_error(missing, 403, "AccessDenied")
    refute_charged(missing)

    signed_header =
      alice_attributes(bucket, key, headers: [{"x-amz-request-payer", "requester"}])

    assert_attributes_ok(signed_header, "<ObjectSize>4</ObjectSize>")
    assert_charged(signed_header)

    query_payer =
      alice_attributes(bucket, key, query: %{"x-amz-request-payer" => "requester"})

    assert_attributes_ok(query_payer, "<ObjectSize>4</ObjectSize>")
    assert_charged(query_payer)

    invalid_signed =
      alice_attributes(bucket, key, headers: [{"x-amz-request-payer", "owner"}])

    assert_xml_error(invalid_signed, 403, "AccessDenied")
    refute_charged(invalid_signed)

    unsigned_header =
      bucket
      |> signed_attributes_conn(key, access_key: @alice_ak, secret: @alice_secret)
      |> put_req_header("x-amz-request-payer", "requester")
      |> call()

    assert_xml_error(unsigned_header, 403, "AccessDenied")
    refute_charged(unsigned_header)
  end

  test "GetObjectAttributes Requester Pays does not charge bucket owner" do
    bucket = "attrownerrequester"
    key = "object.bin"

    assert create_bucket(bucket).status == 200
    assert put_object(bucket, key, "owner").status == 200
    assert put_request_payment(bucket).status == 200

    attrs = object_attributes(bucket, key)

    assert_attributes_ok(attrs, "<ObjectSize>5</ObjectSize>")
    refute_charged(attrs)
  end

  test "GetObjectAttributes enforces expected bucket owner before attributes response" do
    bucket = "attrexpectedowner"
    key = "object.bin"

    assert create_bucket(bucket).status == 200
    assert put_object(bucket, key, "body").status == 200

    wrong_owner =
      object_attributes(bucket, key, headers: [{"x-amz-expected-bucket-owner", @other_owner}])

    assert_xml_error(wrong_owner, 403, "AccessDenied")

    correct_owner =
      object_attributes(bucket, key, headers: [{"x-amz-expected-bucket-owner", @owner}])

    assert_attributes_ok(correct_owner, "<ObjectSize>4</ObjectSize>")
  end

  test "GetObjectAttributes conditional 304 preserves charged and object identity headers" do
    bucket = "attrrequester304"
    key = "object.bin"

    assert create_bucket(bucket).status == 200
    assert enable_versioning(bucket).status == 200

    put = put_object(bucket, key, "conditional")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")
    [etag] = get_resp_header(put, "etag")

    assert put_request_payment(bucket).status == 200
    assert :ok = allow_alice_object_attributes(bucket, key, version: true)

    not_modified =
      alice_attributes(bucket, key,
        query: %{"versionId" => version_id},
        headers: [
          {"x-amz-request-payer", "requester"},
          {"if-none-match", etag}
        ]
      )

    assert not_modified.status == 304
    assert not_modified.resp_body == ""
    assert get_resp_header(not_modified, "x-amz-request-charged") == ["requester"]
    assert get_resp_header(not_modified, "x-amz-version-id") == [version_id]
    assert get_resp_header(not_modified, "etag") == [etag]
    assert [_last_modified] = get_resp_header(not_modified, "last-modified")
  end

  test "GetObjectAttributes requires attribute and object read permissions for non-owners" do
    SigV4Request.signed_conn(:put, "/attrauth") |> call()
    SigV4Request.signed_conn(:put, "/attrauth/object.bin", body: "authorized") |> call()

    attributes_only =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObjectAttributes","Resource":"arn:aws:s3:::attrauth/object.bin"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "object-attributes", attributes_only)

    denied =
      alice(:get, "/attrauth/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "ObjectSize"}]
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    attributes_and_read =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":["s3:GetObjectAttributes","s3:GetObject"],"Resource":"arn:aws:s3:::attrauth/object.bin"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "object-attributes", attributes_and_read)

    allowed =
      alice(:get, "/attrauth/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "ObjectSize"}]
      )
      |> call()

    assert allowed.status == 200
    assert allowed.resp_body =~ "<ObjectSize>10</ObjectSize>"
  end

  test "GetObjectAttributes with versionId requires version attribute and version read permissions" do
    SigV4Request.signed_conn(:put, "/attrversionauth") |> call()

    versioning_xml =
      ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/attrversionauth",
      query: %{"versioning" => ""},
      body: versioning_xml
    )
    |> call()

    put =
      SigV4Request.signed_conn(:put, "/attrversionauth/object.bin", body: "versioned")
      |> call()

    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    non_version_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":["s3:GetObjectAttributes","s3:GetObject"],"Resource":"arn:aws:s3:::attrversionauth/object.bin"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "version-attributes", non_version_policy)

    denied =
      alice(:get, "/attrversionauth/object.bin",
        query: %{"attributes" => "", "versionId" => version_id},
        headers: [{"x-amz-object-attributes", "ObjectSize"}]
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    version_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":["s3:GetObjectVersionAttributes","s3:GetObjectVersion"],"Resource":"arn:aws:s3:::attrversionauth/object.bin"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "version-attributes", version_policy)

    allowed =
      alice(:get, "/attrversionauth/object.bin",
        query: %{"attributes" => "", "versionId" => version_id},
        headers: [{"x-amz-object-attributes", "ObjectSize"}]
      )
      |> call()

    assert allowed.status == 200
    assert get_resp_header(allowed, "x-amz-version-id") == [version_id]
    assert allowed.resp_body =~ "<ObjectSize>9</ObjectSize>"
  end

  test "GetObjectAttributes supports explicit versionId" do
    SigV4Request.signed_conn(:put, "/attrversions") |> call()

    versioning_xml =
      ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/attrversions",
      query: %{"versioning" => ""},
      body: versioning_xml
    )
    |> call()

    first =
      SigV4Request.signed_conn(:put, "/attrversions/object.bin", body: "first")
      |> call()

    assert first.status == 200
    [first_version] = get_resp_header(first, "x-amz-version-id")

    second =
      SigV4Request.signed_conn(:put, "/attrversions/object.bin", body: "second body")
      |> call()

    assert second.status == 200

    attrs =
      SigV4Request.signed_conn(:get, "/attrversions/object.bin",
        query: %{"attributes" => "", "versionId" => first_version},
        headers: [{"x-amz-object-attributes", "ObjectSize"}]
      )
      |> call()

    assert attrs.status == 200
    assert get_resp_header(attrs, "x-amz-version-id") == [first_version]
    assert attrs.resp_body =~ "<ObjectSize>5</ObjectSize>"
    refute attrs.resp_body =~ "<ETag>"
  end

  test "GetObjectAttributes preserves delete marker semantics" do
    SigV4Request.signed_conn(:put, "/attrdm") |> call()

    versioning_xml =
      ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/attrdm", query: %{"versioning" => ""}, body: versioning_xml)
    |> call()

    SigV4Request.signed_conn(:put, "/attrdm/object.bin", body: "body") |> call()

    delete = SigV4Request.signed_conn(:delete, "/attrdm/object.bin") |> call()
    assert delete.status == 204
    [delete_marker_version] = get_resp_header(delete, "x-amz-version-id")

    latest =
      SigV4Request.signed_conn(:get, "/attrdm/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "ObjectSize"}]
      )
      |> call()

    assert latest.status == 404
    assert get_resp_header(latest, "x-amz-delete-marker") == ["true"]

    explicit =
      SigV4Request.signed_conn(:get, "/attrdm/object.bin",
        query: %{"attributes" => "", "versionId" => delete_marker_version},
        headers: [{"x-amz-object-attributes", "ObjectSize"}]
      )
      |> call()

    assert explicit.status == 405
    assert get_resp_header(explicit, "x-amz-delete-marker") == ["true"]
  end

  defp create_bucket(bucket), do: SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

  defp put_object(bucket, key, body, headers \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
      body: body,
      headers: headers
    )
    |> call()
  end

  defp enable_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"versioning" => ""},
      body: body
    )
    |> call()
  end

  defp put_request_payment(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"requestPayment" => ""},
      body: @requester,
      headers: [{"content-md5", content_md5(@requester)}]
    )
    |> call()
  end

  defp allow_alice_object_attributes(bucket, key, opts \\ []) do
    actions =
      if Keyword.get(opts, :version, false) do
        ["s3:GetObjectVersionAttributes", "s3:GetObjectVersion"]
      else
        ["s3:GetObjectAttributes", "s3:GetObject"]
      end

    policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Action" => actions,
          "Resource" => "arn:aws:s3:::#{bucket}/#{key}"
        }
      })

    Store.put_principal_policy(@alice_arn, "object-attributes-#{bucket}-#{key}", policy)
  end

  defp alice_attributes(bucket, key, opts \\ []) do
    opts = Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    object_attributes(bucket, key, opts)
  end

  defp object_attributes(bucket, key, opts \\ []) do
    bucket
    |> signed_attributes_conn(key, opts)
    |> call()
  end

  defp signed_attributes_conn(bucket, key, opts) do
    query = Map.merge(%{"attributes" => ""}, Keyword.get(opts, :query, %{}))
    attribute_header = Keyword.get(opts, :attributes, "ObjectSize")
    headers = [{"x-amz-object-attributes", attribute_header} | Keyword.get(opts, :headers, [])]

    signed_opts =
      [query: query, headers: headers]
      |> Keyword.merge(Keyword.take(opts, [:access_key, :secret, :session_token]))

    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", signed_opts)
  end

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  defp assert_attributes_ok(resp, expected_fragment) do
    assert resp.status == 200
    assert get_resp_header(resp, "content-type") |> Enum.join(";") =~ "application/xml"
    assert resp.resp_body =~ "<GetObjectAttributesResponse"
    assert resp.resp_body =~ expected_fragment
  end

  defp assert_xml_error(resp, status, code) do
    assert resp.status == status
    assert get_resp_header(resp, "content-type") |> Enum.join(";") =~ "application/xml"
    assert resp.resp_body =~ "<Code>#{code}</Code>"
    refute resp.resp_body =~ "<GetObjectAttributesResponse"
  end

  defp assert_charged(resp),
    do: assert(get_resp_header(resp, "x-amz-request-charged") == ["requester"])

  defp refute_charged(resp), do: assert(get_resp_header(resp, "x-amz-request-charged") == [])

  defp hash_b64(algorithm, body), do: :crypto.hash(algorithm, body) |> Base.encode64()

  defp sse_c_headers(customer_key) do
    [
      {"x-amz-server-side-encryption-customer-algorithm", "AES256"},
      {"x-amz-server-side-encryption-customer-key", Base.encode64(customer_key)},
      {"x-amz-server-side-encryption-customer-key-md5",
       :crypto.hash(:md5, customer_key) |> Base.encode64()}
    ]
  end

  defp crc64nvme_b64(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> crc64nvme_raw()
    |> Base.encode64()
  end

  defp crc64nvme_raw(iodata) do
    data = IO.iodata_to_binary(iodata)

    table =
      0..255
      |> Enum.map(fn byte ->
        Enum.reduce(1..8, byte, fn _bit, crc ->
          if Bitwise.band(crc, 1) == 1 do
            Bitwise.bxor(Bitwise.bsr(crc, 1), 0x9A6C9329AC4BC9B5)
          else
            Bitwise.bsr(crc, 1)
          end
        end)
      end)
      |> List.to_tuple()

    crc =
      for <<byte <- data>>, reduce: Bitwise.bxor(0, 0xFFFFFFFFFFFFFFFF) do
        crc ->
          table_index = Bitwise.band(Bitwise.bxor(crc, byte), 0xFF)
          table_value = elem(table, table_index)
          Bitwise.bxor(Bitwise.bsr(crc, 8), table_value)
      end

    <<Bitwise.band(Bitwise.bxor(crc, 0xFFFFFFFFFFFFFFFF), 0xFFFFFFFFFFFFFFFF)::64>>
  end

  defp complete_multipart_object!(bucket, key, parts) do
    init_headers =
      parts
      |> Enum.flat_map(fn {_body, headers} -> headers end)
      |> Enum.find_value(fn
        {"x-amz-checksum-sha256", _value} -> [{"x-amz-checksum-algorithm", "SHA256"}]
        {"x-amz-checksum-sha512", _value} -> [{"x-amz-checksum-algorithm", "SHA512"}]
        {"x-amz-checksum-crc32", _value} -> [{"x-amz-checksum-algorithm", "CRC32"}]
        {"x-amz-checksum-crc32c", _value} -> [{"x-amz-checksum-algorithm", "CRC32C"}]
        _header -> nil
      end) || []

    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploads" => ""},
        headers: init_headers
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    etags =
      parts
      |> Enum.with_index(1)
      |> Enum.map(fn {{body, headers}, part_number} ->
        upload =
          SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
            query: %{"uploadId" => upload_id, "partNumber" => Integer.to_string(part_number)},
            body: body,
            headers: headers
          )
          |> call()

        assert upload.status == 200
        [etag] = get_resp_header(upload, "etag")
        etag
      end)

    complete_xml =
      etags
      |> Enum.with_index(1)
      |> Enum.map(fn {etag, part_number} ->
        "<Part><PartNumber>#{part_number}</PartNumber><ETag>#{etag}</ETag></Part>"
      end)
      |> then(&["<CompleteMultipartUpload>", &1, "</CompleteMultipartUpload>"])
      |> IO.iodata_to_binary()

    complete =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploadId" => upload_id},
        body: complete_xml
      )
      |> call()

    assert complete.status == 200
    complete
  end

  defp upload_id(xml) do
    [_, rest] = String.split(xml, "<UploadId>")
    [id, _] = String.split(rest, "</UploadId>")
    id
  end
end
