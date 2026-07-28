defmodule Maxio.S3.OwnershipControlsTest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.{BucketConfigs, Objects}
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_ownership_controls_test")
  @all_users "http://acs.amazonaws.com/groups/global/AllUsers"

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

  defp checksum_b64(algorithm, body), do: :crypto.hash(algorithm, body) |> Base.encode64()

  defp create_acl_bucket(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      headers: [{"x-amz-object-ownership", "ObjectWriter"}]
    )
    |> call()
  end

  defp ownership_xml(value) do
    """
    <OwnershipControls xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Rule>
        <ObjectOwnership>#{value}</ObjectOwnership>
      </Rule>
    </OwnershipControls>
    """
  end

  defp put_ownership(bucket, value) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"ownershipControls" => ""},
      body: ownership_xml(value)
    )
    |> call()
  end

  test "CreateBucket defaults to BucketOwnerEnforced and explicit ObjectWriter enables ACLs" do
    create = SigV4Request.signed_conn(:put, "/owndefault") |> call()
    assert create.status == 200

    assert {:ok, %{"ObjectOwnership" => "BucketOwnerEnforced"}} =
             BucketConfigs.get("owndefault", :ownership_controls)

    get =
      SigV4Request.signed_conn(:get, "/owndefault", query: %{"ownershipControls" => ""})
      |> call()

    assert get.status == 200
    assert get.resp_body =~ "<ObjectOwnership>BucketOwnerEnforced</ObjectOwnership>"

    acl_create = create_acl_bucket("ownwriter")
    assert acl_create.status == 200

    assert {:ok, %{"ObjectOwnership" => "ObjectWriter"}} =
             BucketConfigs.get("ownwriter", :ownership_controls)

    put_acl =
      SigV4Request.signed_conn(:put, "/ownwriter",
        query: %{"acl" => ""},
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert put_acl.status == 200
  end

  test "CreateBucket rejects ACL grants with default BucketOwnerEnforced" do
    public =
      SigV4Request.signed_conn(:put, "/owncreatepublic", headers: [{"x-amz-acl", "public-read"}])
      |> call()

    assert public.status == 400
    assert public.resp_body =~ "InvalidBucketAclWithObjectOwnership"
    assert :none = BucketConfigs.get("owncreatepublic", :ownership_controls)

    grant =
      SigV4Request.signed_conn(:put, "/owncreategrant",
        headers: [{"x-amz-grant-read", ~s(uri="#{@all_users}")}]
      )
      |> call()

    assert grant.status == 400
    assert grant.resp_body =~ "InvalidBucketAclWithObjectOwnership"
    assert :none = BucketConfigs.get("owncreategrant", :ownership_controls)
  end

  test "Put/Get/DeleteBucketOwnershipControls round-trips config" do
    SigV4Request.signed_conn(:put, "/ownrt") |> call()

    put = put_ownership("ownrt", "BucketOwnerPreferred")
    assert put.status == 200
    assert put.resp_body == ""

    assert {:ok, %{"ObjectOwnership" => "BucketOwnerPreferred"}} =
             BucketConfigs.get("ownrt", :ownership_controls)

    get =
      SigV4Request.signed_conn(:get, "/ownrt", query: %{"ownershipControls" => ""})
      |> call()

    assert get.status == 200
    assert get_resp_header(get, "content-type") |> hd() =~ "application/xml"
    assert get.resp_body =~ "<OwnershipControls"
    assert get.resp_body =~ "<ObjectOwnership>BucketOwnerPreferred</ObjectOwnership>"

    del =
      SigV4Request.signed_conn(:delete, "/ownrt", query: %{"ownershipControls" => ""})
      |> call()

    assert del.status == 204
    assert :none = BucketConfigs.get("ownrt", :ownership_controls)

    get2 =
      SigV4Request.signed_conn(:get, "/ownrt", query: %{"ownershipControls" => ""})
      |> call()

    assert get2.status == 404
    assert get2.resp_body =~ "OwnershipControlsNotFoundError"
  end

  test "Put/Get/DeleteBucketOwnershipControls validate checksums, trailers, and expected owner" do
    bucket = "ownchecksum"
    preferred_xml = ownership_xml("BucketOwnerPreferred")
    writer_xml = ownership_xml("ObjectWriter")

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    missing_integrity =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"ownershipControls" => ""},
        body: preferred_xml,
        auto_content_md5: false
      )
      |> call()

    assert missing_integrity.status == 400
    assert missing_integrity.resp_body =~ "<Code>MissingSecurityHeader</Code>"

    assert {:ok, %{"ObjectOwnership" => "BucketOwnerEnforced"}} =
             BucketConfigs.get(bucket, :ownership_controls)

    good_header =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"ownershipControls" => ""},
        body: preferred_xml,
        auto_content_md5: false,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum_b64(:sha256, preferred_xml)}
        ]
      )
      |> call()

    assert good_header.status == 200

    assert {:ok, %{"ObjectOwnership" => "BucketOwnerPreferred"}} =
             BucketConfigs.get(bucket, :ownership_controls)

    bad_header =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"ownershipControls" => ""},
        body: writer_xml,
        auto_content_md5: false,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum_b64(:sha256, "different")}
        ]
      )
      |> call()

    assert bad_header.status == 400
    assert bad_header.resp_body =~ "<Code>BadDigest</Code>"

    assert {:ok, %{"ObjectOwnership" => "BucketOwnerPreferred"}} =
             BucketConfigs.get(bucket, :ownership_controls)

    plain_trailer =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"ownershipControls" => ""},
        body: writer_xml,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )
      |> call()

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "<Code>InvalidRequest</Code>"

    assert {:ok, %{"ObjectOwnership" => "BucketOwnerPreferred"}} =
             BucketConfigs.get(bucket, :ownership_controls)

    ok_trailer =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}", writer_xml,
        query: %{"ownershipControls" => ""},
        auto_content_md5: false,
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", checksum_b64(:sha256, writer_xml)}]
      )
      |> call()

    assert ok_trailer.status == 200

    assert {:ok, %{"ObjectOwnership" => "ObjectWriter"}} =
             BucketConfigs.get(bucket, :ownership_controls)

    wrong_put =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"ownershipControls" => ""},
        body: preferred_xml,
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_put.status == 403

    assert {:ok, %{"ObjectOwnership" => "ObjectWriter"}} =
             BucketConfigs.get(bucket, :ownership_controls)

    wrong_get =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"ownershipControls" => ""},
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_get.status == 403

    wrong_delete =
      SigV4Request.signed_conn(:delete, "/#{bucket}",
        query: %{"ownershipControls" => ""},
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_delete.status == 403

    assert {:ok, %{"ObjectOwnership" => "ObjectWriter"}} =
             BucketConfigs.get(bucket, :ownership_controls)
  end

  test "PutBucketOwnershipControls validates XML and bucket existence" do
    missing = put_ownership("missing-own", "BucketOwnerEnforced")
    assert missing.status == 404
    assert missing.resp_body =~ "NoSuchBucket"

    SigV4Request.signed_conn(:put, "/ownbad") |> call()

    bad =
      SigV4Request.signed_conn(:put, "/ownbad",
        query: %{"ownershipControls" => ""},
        body: ownership_xml("ACLsEnabled")
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "MalformedXML"

    assert {:ok, %{"ObjectOwnership" => "BucketOwnerEnforced"}} =
             BucketConfigs.get("ownbad", :ownership_controls)

    assert put_ownership("ownbad", "ObjectWriter").status == 200

    malformed =
      SigV4Request.signed_conn(:put, "/ownbad",
        query: %{"ownershipControls" => ""},
        body:
          ~s(<OwnershipControls><Rule><ObjectOwnership>BucketOwnerEnforced</ObjectOwnership><ObjectOwnership>ObjectWriter</ObjectOwnership></Rule></OwnershipControls>)
      )
      |> call()

    assert malformed.status == 400
    assert malformed.resp_body =~ "MalformedXML"

    unknown =
      SigV4Request.signed_conn(:put, "/ownbad",
        query: %{"ownershipControls" => ""},
        body:
          ~s(<OwnershipControls><Rule><Unknown>BucketOwnerEnforced</Unknown></Rule></OwnershipControls>)
      )
      |> call()

    assert unknown.status == 400
    assert unknown.resp_body =~ "MalformedXML"

    assert {:ok, %{"ObjectOwnership" => "ObjectWriter"}} =
             BucketConfigs.get("ownbad", :ownership_controls)
  end

  test "BucketOwnerEnforced cannot be enabled while bucket ACL grants non-owner access" do
    create_acl_bucket("ownbadacl")

    put_acl =
      SigV4Request.signed_conn(:put, "/ownbadacl",
        query: %{"acl" => ""},
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert put_acl.status == 200

    rejected = put_ownership("ownbadacl", "BucketOwnerEnforced")
    assert rejected.status == 400
    assert rejected.resp_body =~ "InvalidBucketAclWithObjectOwnership"

    assert {:ok, %{"ObjectOwnership" => "ObjectWriter"}} =
             BucketConfigs.get("ownbadacl", :ownership_controls)
  end

  test "BucketOwnerEnforced rejects ACL update APIs while GetAcl remains readable" do
    SigV4Request.signed_conn(:put, "/ownacl") |> call()
    assert put_ownership("ownacl", "BucketOwnerEnforced").status == 200

    get_bucket_acl =
      SigV4Request.signed_conn(:get, "/ownacl", query: %{"acl" => ""})
      |> call()

    assert get_bucket_acl.status == 200
    assert get_bucket_acl.resp_body =~ "<AccessControlPolicy"
    refute get_bucket_acl.resp_body =~ "AllUsers"

    put_bucket_acl =
      SigV4Request.signed_conn(:put, "/ownacl",
        query: %{"acl" => ""},
        headers: [{"x-amz-acl", "private"}]
      )
      |> call()

    assert put_bucket_acl.status == 400
    assert put_bucket_acl.resp_body =~ "AccessControlListNotSupported"

    put = SigV4Request.signed_conn(:put, "/ownacl/object.txt", body: "private") |> call()
    assert put.status == 200

    put_object_acl =
      SigV4Request.signed_conn(:put, "/ownacl/object.txt",
        query: %{"acl" => ""},
        headers: [{"x-amz-acl", "private"}]
      )
      |> call()

    assert put_object_acl.status == 400
    assert put_object_acl.resp_body =~ "AccessControlListNotSupported"

    get_object_acl =
      SigV4Request.signed_conn(:get, "/ownacl/object.txt", query: %{"acl" => ""})
      |> call()

    assert get_object_acl.status == 200
    refute get_object_acl.resp_body =~ "AllUsers"
  end

  test "BucketOwnerEnforced suppresses stored object ACLs in authz and GetObjectAcl" do
    create_acl_bucket("ownpublic")

    public_put =
      SigV4Request.signed_conn(:put, "/ownpublic/public.txt",
        body: "public",
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert public_put.status == 200
    assert (SigV4Request.anon_conn(:get, "/ownpublic/public.txt") |> call()).status == 200

    assert put_ownership("ownpublic", "BucketOwnerEnforced").status == 200

    {:ok, obj} = Objects.get_metadata("ownpublic", "public.txt")
    assert obj.acl_canned == "public-read"

    anon_after = SigV4Request.anon_conn(:get, "/ownpublic/public.txt") |> call()
    assert anon_after.status == 403

    acl =
      SigV4Request.signed_conn(:get, "/ownpublic/public.txt", query: %{"acl" => ""})
      |> call()

    assert acl.status == 200
    refute acl.resp_body =~ "AllUsers"
    assert acl.resp_body =~ "<Permission>FULL_CONTROL</Permission>"
  end

  test "BucketOwnerEnforced rejects object writes with ACLs except bucket-owner-full-control" do
    SigV4Request.signed_conn(:put, "/ownput") |> call()
    assert put_ownership("ownput", "BucketOwnerEnforced").status == 200

    public_put =
      SigV4Request.signed_conn(:put, "/ownput/public.txt",
        body: "public",
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert public_put.status == 400
    assert public_put.resp_body =~ "AccessControlListNotSupported"
    assert {:error, :not_found} = Objects.get_metadata("ownput", "public.txt")

    grant_put =
      SigV4Request.signed_conn(:put, "/ownput/grant.txt",
        body: "grant",
        headers: [{"x-amz-grant-read", ~s(uri="#{@all_users}")}]
      )
      |> call()

    assert grant_put.status == 400
    assert grant_put.resp_body =~ "AccessControlListNotSupported"
    assert {:error, :not_found} = Objects.get_metadata("ownput", "grant.txt")

    ok_default = SigV4Request.signed_conn(:put, "/ownput/default.txt", body: "ok") |> call()
    assert ok_default.status == 200

    ok_owner =
      SigV4Request.signed_conn(:put, "/ownput/owner.txt",
        body: "ok",
        headers: [{"x-amz-acl", "bucket-owner-full-control"}]
      )
      |> call()

    assert ok_owner.status == 200
  end

  test "BucketOwnerEnforced applies to CopyObject and CreateMultipartUpload ACL headers" do
    SigV4Request.signed_conn(:put, "/owncopy") |> call()
    assert put_ownership("owncopy", "BucketOwnerEnforced").status == 200

    assert (SigV4Request.signed_conn(:put, "/owncopy/src.txt", body: "src") |> call()).status ==
             200

    copy_rejected =
      SigV4Request.signed_conn(:put, "/owncopy/copy.txt",
        headers: [
          {"x-amz-copy-source", "/owncopy/src.txt"},
          {"x-amz-acl", "public-read"}
        ]
      )
      |> call()

    assert copy_rejected.status == 400
    assert copy_rejected.resp_body =~ "AccessControlListNotSupported"
    assert {:error, :not_found} = Objects.get_metadata("owncopy", "copy.txt")

    copy_allowed =
      SigV4Request.signed_conn(:put, "/owncopy/copy-ok.txt",
        headers: [
          {"x-amz-copy-source", "/owncopy/src.txt"},
          {"x-amz-acl", "bucket-owner-full-control"}
        ]
      )
      |> call()

    assert copy_allowed.status == 200

    mpu_rejected =
      SigV4Request.signed_conn(:post, "/owncopy/mpu.txt",
        query: %{"uploads" => ""},
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert mpu_rejected.status == 400
    assert mpu_rejected.resp_body =~ "AccessControlListNotSupported"

    mpu_allowed =
      SigV4Request.signed_conn(:post, "/owncopy/mpu-ok.txt",
        query: %{"uploads" => ""},
        headers: [{"x-amz-acl", "bucket-owner-full-control"}]
      )
      |> call()

    assert mpu_allowed.status == 200
    assert mpu_allowed.resp_body =~ "<UploadId>"
  end
end
