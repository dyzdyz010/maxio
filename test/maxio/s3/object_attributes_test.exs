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

  setup do
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

  test "GetObjectAttributes returns requested object metadata" do
    SigV4Request.signed_conn(:put, "/attrs") |> call()

    put =
      SigV4Request.signed_conn(:put, "/attrs/object.bin",
        body: "attribute body",
        headers: [{"x-amz-storage-class", "STANDARD_IA"}]
      )
      |> call()

    assert put.status == 200
    [etag] = get_resp_header(put, "etag")

    attrs =
      SigV4Request.signed_conn(:get, "/attrs/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "ETag,ObjectSize,StorageClass"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<GetObjectAttributesResponse"
    assert attrs.resp_body =~ "<ETag>#{etag}</ETag>"
    assert attrs.resp_body =~ "<ObjectSize>14</ObjectSize>"
    assert attrs.resp_body =~ "<StorageClass>STANDARD_IA</StorageClass>"
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

  test "GetObjectAttributes fails closed for unsupported durable attributes" do
    SigV4Request.signed_conn(:put, "/attrunsupported") |> call()
    SigV4Request.signed_conn(:put, "/attrunsupported/object.bin", body: "body") |> call()

    attrs =
      SigV4Request.signed_conn(:get, "/attrunsupported/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 501
    assert attrs.resp_body =~ "<Code>NotImplemented</Code>"
  end

  test "GetObjectAttributes fail-closed attributes are rejected before condition responses" do
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
          {"x-amz-object-attributes", "Checksum"},
          {"if-none-match", etag}
        ]
      )
      |> call()

    assert attrs.status == 501
    assert attrs.resp_body =~ "<Code>NotImplemented</Code>"
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
end
