defmodule Maxio.S3.AclTest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.{ObjectAclSidecar, ObjectMeta}
  alias Maxio.Objects
  alias Maxio.Auth.CredentialStore
  alias Maxio.Policy.{ACL, Store}
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_acl_test")
  @alice_ak "AKIAACLALICE000001"
  @alice_secret "aliceaclsecretaliceaclsecret12"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
  @all_users "http://acs.amazonaws.com/groups/global/AllUsers"

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    prev_authority = Application.get_env(:maxio, :authoritative_source, read: :pg)

    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      Application.put_env(:maxio, :authoritative_source, prev_authority)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp alice(method, path, opts \\ []) do
    SigV4Request.signed_conn(
      method,
      path,
      Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    )
  end

  test "PutObject x-amz-acl=public-read → GetObjectAcl 展开 AllUsers READ" do
    SigV4Request.signed_conn(:put, "/abk") |> call()

    SigV4Request.signed_conn(:put, "/abk/pub.txt",
      body: "hi",
      headers: [{"x-amz-acl", "public-read"}]
    )
    |> call()

    acl = SigV4Request.signed_conn(:get, "/abk/pub.txt", query: %{"acl" => ""}) |> call()
    assert acl.status == 200
    assert acl.resp_body =~ ~s(xsi:type="Group")
    assert acl.resp_body =~ "AllUsers"
    assert acl.resp_body =~ "<Permission>READ</Permission>"
    assert acl.resp_body =~ ~s(xmlns="http://s3.amazonaws.com/doc/2006-03-01/")
  end

  test "GetBucketAcl 默认 private → 仅 owner FULL_CONTROL" do
    SigV4Request.signed_conn(:put, "/abk2") |> call()
    acl = SigV4Request.signed_conn(:get, "/abk2", query: %{"acl" => ""}) |> call()
    assert acl.status == 200
    assert acl.resp_body =~ "<Permission>FULL_CONTROL</Permission>"
    refute acl.resp_body =~ "AllUsers"
  end

  test "PutBucketAcl x-amz-acl=public-read → GetBucketAcl 展开" do
    SigV4Request.signed_conn(:put, "/abk3") |> call()

    put =
      SigV4Request.signed_conn(:put, "/abk3",
        query: %{"acl" => ""},
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert put.status == 200

    acl = SigV4Request.signed_conn(:get, "/abk3", query: %{"acl" => ""}) |> call()
    assert acl.resp_body =~ "AllUsers"
  end

  test "PutBucketAcl x-amz-grant-read=AllUsers → 匿名 ListBucket allow" do
    SigV4Request.signed_conn(:put, "/abkgra") |> call()

    put =
      SigV4Request.signed_conn(:put, "/abkgra",
        query: %{"acl" => ""},
        headers: [{"x-amz-grant-read", ~s(uri="#{@all_users}")}]
      )
      |> call()

    assert put.status == 200

    acl = SigV4Request.signed_conn(:get, "/abkgra", query: %{"acl" => ""}) |> call()
    assert acl.resp_body =~ "AllUsers"
    assert acl.resp_body =~ "<Permission>READ</Permission>"

    list = SigV4Request.anon_conn(:get, "/abkgra", query: %{"list-type" => "2"}) |> call()
    assert list.status == 200
  end

  test "PutObjectAcl XML body → GetObjectAcl 展开（round-trip）" do
    SigV4Request.signed_conn(:put, "/abk4") |> call()
    SigV4Request.signed_conn(:put, "/abk4/x.txt", body: "hi") |> call()

    xml =
      ~s(<AccessControlPolicy><AccessControlList>) <>
        ~s(<Grant><Grantee xsi:type="Group"><URI>http://acs.amazonaws.com/groups/global/AllUsers</URI></Grantee><Permission>READ</Permission></Grant>) <>
        ~s(</AccessControlList></AccessControlPolicy>)

    put =
      SigV4Request.signed_conn(:put, "/abk4/x.txt", query: %{"acl" => ""}, body: xml)
      |> call()

    assert put.status == 200

    acl = SigV4Request.signed_conn(:get, "/abk4/x.txt", query: %{"acl" => ""}) |> call()
    assert acl.resp_body =~ "AllUsers"
    assert acl.resp_body =~ "<Permission>READ</Permission>"
  end

  test "PutObject x-amz-grant-read=AllUsers stores explicit grant and allows anonymous read" do
    SigV4Request.signed_conn(:put, "/abkgrant") |> call()

    put =
      SigV4Request.signed_conn(:put, "/abkgrant/pub.txt",
        body: "hi",
        headers: [{"x-amz-grant-read", ~s(uri="#{@all_users}")}]
      )
      |> call()

    assert put.status == 200

    {:ok, obj} = Objects.get_metadata("abkgrant", "pub.txt")
    assert obj.acl_canned == "public-read"
    assert [%{"permission" => "READ"}] = obj.acl_grants["grants"]

    acl = SigV4Request.signed_conn(:get, "/abkgrant/pub.txt", query: %{"acl" => ""}) |> call()
    assert acl.resp_body =~ "AllUsers"
    assert acl.resp_body =~ "<Permission>READ</Permission>"

    anon = SigV4Request.anon_conn(:get, "/abkgrant/pub.txt") |> call()
    assert anon.status == 200
    assert anon.resp_body == "hi"
  end

  test "PutObjectAcl XML canonical READ grants named principal object read" do
    SigV4Request.signed_conn(:put, "/abkcanon") |> call()
    SigV4Request.signed_conn(:put, "/abkcanon/private.txt", body: "secret") |> call()

    denied = alice(:get, "/abkcanon/private.txt") |> call()
    assert denied.status == 403

    xml =
      ~s(<AccessControlPolicy><AccessControlList>) <>
        ~s(<Grant><Grantee xsi:type="CanonicalUser"><ID>#{@alice_arn}</ID><DisplayName>Alice</DisplayName></Grantee><Permission>READ</Permission></Grant>) <>
        ~s(</AccessControlList></AccessControlPolicy>)

    put =
      SigV4Request.signed_conn(:put, "/abkcanon/private.txt", query: %{"acl" => ""}, body: xml)
      |> call()

    assert put.status == 200

    acl = SigV4Request.signed_conn(:get, "/abkcanon/private.txt", query: %{"acl" => ""}) |> call()
    assert acl.resp_body =~ ~s(xsi:type="CanonicalUser")
    assert acl.resp_body =~ @alice_arn
    assert acl.resp_body =~ "<Permission>READ</Permission>"

    allowed = alice(:get, "/abkcanon/private.txt") |> call()
    assert allowed.status == 200
    assert allowed.resp_body == "secret"
  end

  test "PutObjectAcl email grantee → 400 InvalidArgument" do
    SigV4Request.signed_conn(:put, "/abk5") |> call()
    SigV4Request.signed_conn(:put, "/abk5/y.txt", body: "hi") |> call()

    xml =
      ~s(<AccessControlPolicy><AccessControlList>) <>
        ~s(<Grant><Grantee xsi:type="AmazonCustomerByEmail"><EmailAddress>nobody@example.com</EmailAddress></Grantee><Permission>READ</Permission></Grant>) <>
        ~s(</AccessControlList></AccessControlPolicy>)

    resp =
      SigV4Request.signed_conn(:put, "/abk5/y.txt", query: %{"acl" => ""}, body: xml)
      |> call()

    assert resp.status == 400
    assert resp.resp_body =~ "InvalidArgument"
  end

  test "PutObjectAcl x-amz-grant email grantee → 400 InvalidArgument" do
    SigV4Request.signed_conn(:put, "/abkemailhdr") |> call()
    SigV4Request.signed_conn(:put, "/abkemailhdr/y.txt", body: "hi") |> call()

    resp =
      SigV4Request.signed_conn(:put, "/abkemailhdr/y.txt",
        query: %{"acl" => ""},
        headers: [{"x-amz-grant-read", ~s(emailAddress="nobody@example.com")}]
      )
      |> call()

    assert resp.status == 400
    assert resp.resp_body =~ "InvalidArgument"
  end

  test "PutObject rejects mixed x-amz-acl and x-amz-grant headers before commit" do
    SigV4Request.signed_conn(:put, "/abkmix") |> call()

    resp =
      SigV4Request.signed_conn(:put, "/abkmix/bad.txt",
        body: "bad",
        headers: [
          {"x-amz-acl", "public-read"},
          {"x-amz-grant-read", ~s(uri="#{@all_users}")}
        ]
      )
      |> call()

    assert resp.status == 400
    assert resp.resp_body =~ "InvalidRequest"
    assert {:error, :not_found} = Objects.get_metadata("abkmix", "bad.txt")
  end

  test "CopyObject 默认不继承源 ACL，显式 x-amz-acl 应用到目标" do
    SigV4Request.signed_conn(:put, "/abk6") |> call()

    SigV4Request.signed_conn(:put, "/abk6/src.txt",
      body: "hi",
      headers: [{"x-amz-acl", "public-read"}]
    )
    |> call()

    default_copy =
      SigV4Request.signed_conn(:put, "/abk6/default.txt",
        headers: [{"x-amz-copy-source", "/abk6/src.txt"}]
      )
      |> call()

    assert default_copy.status == 200

    default_acl =
      SigV4Request.signed_conn(:get, "/abk6/default.txt", query: %{"acl" => ""}) |> call()

    assert default_acl.status == 200
    refute default_acl.resp_body =~ "AllUsers"

    public_copy =
      SigV4Request.signed_conn(:put, "/abk6/public.txt",
        headers: [{"x-amz-copy-source", "/abk6/src.txt"}, {"x-amz-acl", "public-read"}]
      )
      |> call()

    assert public_copy.status == 200

    public_acl =
      SigV4Request.signed_conn(:get, "/abk6/public.txt", query: %{"acl" => ""}) |> call()

    assert public_acl.status == 200
    assert public_acl.resp_body =~ "AllUsers"
    assert public_acl.resp_body =~ "<Permission>READ</Permission>"

    :ok = Objects.delete_metadata("abk6", "public.txt")

    sidecar_obj =
      ObjectMeta.get("abk6", "public.txt", nil, authoritative_source: [read: :sidecar])

    assert sidecar_obj.acl_canned == "public-read"
  end

  test "CopyObject invalid x-amz-acl → 400 before target commit" do
    SigV4Request.signed_conn(:put, "/abk7") |> call()
    SigV4Request.signed_conn(:put, "/abk7/src.txt", body: "hi") |> call()

    resp =
      SigV4Request.signed_conn(:put, "/abk7/dst.txt",
        headers: [{"x-amz-copy-source", "/abk7/src.txt"}, {"x-amz-acl", "not-real"}]
      )
      |> call()

    assert resp.status == 400
    assert resp.resp_body =~ "InvalidArgument"
    assert {:error, :not_found} = Objects.get_metadata("abk7", "dst.txt")
  end

  test "CopyObject self-copy with explicit x-amz-acl updates ACL and is not rejected" do
    SigV4Request.signed_conn(:put, "/abk8") |> call()
    SigV4Request.signed_conn(:put, "/abk8/self.txt", body: "hi") |> call()

    copy =
      SigV4Request.signed_conn(:put, "/abk8/self.txt",
        headers: [{"x-amz-copy-source", "/abk8/self.txt"}, {"x-amz-acl", "public-read"}]
      )
      |> call()

    assert copy.status == 200

    {:ok, obj} = Objects.get_metadata("abk8", "self.txt")
    assert obj.acl_canned == "public-read"

    :ok = Objects.delete_metadata("abk8", "self.txt")

    sidecar_obj =
      ObjectMeta.get("abk8", "self.txt", nil, authoritative_source: [read: :sidecar])

    assert sidecar_obj.acl_canned == "public-read"
  end

  test "PutObjectAcl updates sidecar generation and scanner does not revert explicit grant" do
    SigV4Request.signed_conn(:put, "/abksidecar") |> call()
    SigV4Request.signed_conn(:put, "/abksidecar/private.txt", body: "secret") |> call()

    put =
      SigV4Request.signed_conn(:put, "/abksidecar/private.txt",
        query: %{"acl" => ""},
        headers: [{"x-amz-grant-read", ~s(uri="#{@all_users}")}]
      )
      |> call()

    assert put.status == 200

    sidecar_obj =
      ObjectMeta.get("abksidecar", "private.txt", nil, authoritative_source: [read: :sidecar])

    assert sidecar_obj.acl_canned == "public-read"
    assert [%{"permission" => "READ"}] = sidecar_obj.acl_grants["grants"]

    Application.put_env(:maxio, :authoritative_source, read: :pg, list: :pg, write: :sidecar)
    assert {:ok, %{status: :ok}} = Maxio.Storage.Scanner.run_once(bucket: "abksidecar")

    {:ok, obj} = Objects.get_metadata("abksidecar", "private.txt")
    assert obj.acl_canned == "public-read"
    assert [%{"permission" => "READ"}] = obj.acl_grants["grants"]
  end

  test "PutObjectAcl remains committed in PG authority when sidecar mirror is unavailable" do
    SigV4Request.signed_conn(:put, "/abkpgacl") |> call()
    SigV4Request.signed_conn(:put, "/abkpgacl/private.txt", body: "secret") |> call()
    File.rm_rf!(@data_dir)

    put =
      SigV4Request.signed_conn(:put, "/abkpgacl/private.txt",
        query: %{"acl" => ""},
        headers: [{"x-amz-grant-read", ~s(uri="#{@all_users}")}]
      )
      |> call()

    assert put.status == 200
    {:ok, obj} = Objects.get_metadata("abkpgacl", "private.txt")
    assert obj.acl_canned == "public-read"
    assert [%{"permission" => "READ"}] = obj.acl_grants["grants"]
  end

  test "ObjectAclSidecar update uses atomic meta-only commit" do
    SigV4Request.signed_conn(:put, "/abkatomic") |> call()
    SigV4Request.signed_conn(:put, "/abkatomic/private.txt", body: "secret") |> call()

    assert {:error, :write_quorum} =
             ObjectAclSidecar.update(
               "abkatomic",
               "private.txt",
               "null",
               "public-read",
               ACL.empty_grants_doc(),
               rename_fun: fn _src, _dst -> {:error, :ebusy} end
             )

    sidecar_obj =
      ObjectMeta.get("abkatomic", "private.txt", nil, authoritative_source: [read: :sidecar])

    assert sidecar_obj.acl_canned == "private"
  end

  test "sidecar read authority uses sidecar ACLs for authorization instead of stale PG ACLs" do
    SigV4Request.signed_conn(:put, "/abksideauth") |> call()
    SigV4Request.signed_conn(:put, "/abksideauth/private.txt", body: "secret") |> call()

    put =
      SigV4Request.signed_conn(:put, "/abksideauth/private.txt",
        query: %{"acl" => ""},
        headers: [{"x-amz-grant-read", ~s(uri="#{@all_users}")}]
      )
      |> call()

    assert put.status == 200

    assert :ok =
             Objects.put_acl_version(
               "abksideauth",
               "private.txt",
               nil,
               "private",
               ACL.empty_grants_doc()
             )

    Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :pg, write: :pg)

    allowed = SigV4Request.anon_conn(:get, "/abksideauth/private.txt") |> call()
    assert allowed.status == 200
    assert allowed.resp_body == "secret"
  end

  test "Object ACL versionId targets and authorizes the requested version" do
    bucket = "abkvidacl"
    key = "doc.txt"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    versioning_xml =
      ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    assert 200 =
             SigV4Request.signed_conn(:put, "/#{bucket}",
               query: %{"versioning" => ""},
               body: versioning_xml
             )
             |> call()
             |> Map.fetch!(:status)

    v1_put = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "old") |> call()
    assert [vid1] = get_resp_header(v1_put, "x-amz-version-id")

    v2_put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: "new",
        headers: [{"x-amz-grant-read-acp", ~s(uri="#{@all_users}")}]
      )
      |> call()

    assert [vid2] = get_resp_header(v2_put, "x-amz-version-id")
    assert vid1 != vid2

    denied_old_acl =
      SigV4Request.anon_conn(:get, "/#{bucket}/#{key}",
        query: %{"acl" => "", "versionId" => vid1}
      )
      |> call()

    assert denied_old_acl.status == 403

    old_acl =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        query: %{"acl" => "", "versionId" => vid1}
      )
      |> call()

    assert old_acl.status == 200
    refute old_acl.resp_body =~ "AllUsers"

    put_old_acl =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"acl" => "", "versionId" => vid1},
        headers: [{"x-amz-grant-read", ~s(uri="#{@all_users}")}]
      )
      |> call()

    assert put_old_acl.status == 200

    anon_old =
      SigV4Request.anon_conn(:get, "/#{bucket}/#{key}", query: %{"versionId" => vid1})
      |> call()

    assert anon_old.status == 200
    assert anon_old.resp_body == "old"

    anon_latest = SigV4Request.anon_conn(:get, "/#{bucket}/#{key}") |> call()
    assert anon_latest.status == 403
  end

  test "versionId ACL APIs require version-specific IAM actions" do
    bucket = "abkvidaction"
    key = "doc.txt"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    versioning_xml =
      ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    assert 200 =
             SigV4Request.signed_conn(:put, "/#{bucket}",
               query: %{"versioning" => ""},
               body: versioning_xml
             )
             |> call()
             |> Map.fetch!(:status)

    v1_put = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "old") |> call()
    assert [vid1] = get_resp_header(v1_put, "x-amz-version-id")
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "new") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":["s3:GetObjectAcl","s3:PutObjectAcl"],"Resource":"arn:aws:s3:::#{bucket}/*"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "non-version-acl-only", policy)

    current_get = alice(:get, "/#{bucket}/#{key}", query: %{"acl" => ""}) |> call()
    assert current_get.status == 200

    version_get =
      alice(:get, "/#{bucket}/#{key}", query: %{"acl" => "", "versionId" => vid1})
      |> call()

    assert version_get.status == 403

    version_put =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"acl" => "", "versionId" => vid1},
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert version_put.status == 403

    malformed_get =
      alice(:get, "/#{bucket}/#{key}", query: %{"acl" => "", "versionId" => "not-a-version"})
      |> call()

    assert malformed_get.status == 403

    version_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":["s3:GetObjectVersionAcl","s3:PutObjectVersionAcl"],"Resource":"arn:aws:s3:::#{bucket}/*"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "version-acl", version_policy)

    invalid_get =
      alice(:get, "/#{bucket}/#{key}", query: %{"acl" => "", "versionId" => "not-a-version"})
      |> call()

    assert invalid_get.status == 400
    assert invalid_get.resp_body =~ "InvalidArgument"

    invalid_put =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"acl" => "", "versionId" => "not-a-version"},
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert invalid_put.status == 400
    assert invalid_put.resp_body =~ "InvalidArgument"
  end

  test "Bucket WRITE grants authorize object writes from PutBucketAcl and CreateBucket headers" do
    SigV4Request.signed_conn(:put, "/abkwriteput") |> call()

    grant =
      SigV4Request.signed_conn(:put, "/abkwriteput",
        query: %{"acl" => ""},
        headers: [{"x-amz-grant-write", ~s(id="#{@alice_arn}")}]
      )
      |> call()

    assert grant.status == 200
    assert (alice(:put, "/abkwriteput/alice.txt", body: "alice") |> call()).status == 200

    created =
      SigV4Request.signed_conn(:put, "/abkwritecreate",
        headers: [{"x-amz-grant-write", ~s(id="#{@alice_arn}")}]
      )
      |> call()

    assert created.status == 200
    assert (alice(:put, "/abkwritecreate/alice.txt", body: "alice") |> call()).status == 200
  end

  test "object write ACL headers require s3:PutObjectAcl in addition to PutObject" do
    SigV4Request.signed_conn(:put, "/abkaclperm") |> call()

    grant =
      SigV4Request.signed_conn(:put, "/abkaclperm",
        query: %{"acl" => ""},
        headers: [{"x-amz-grant-write", ~s(id="#{@alice_arn}")}]
      )
      |> call()

    assert grant.status == 200

    normal_put = alice(:put, "/abkaclperm/plain.txt", body: "alice") |> call()
    assert normal_put.status == 200

    denied_put =
      alice(:put, "/abkaclperm/public.txt",
        body: "alice",
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert denied_put.status == 403
    assert {:error, :not_found} = Objects.get_metadata("abkaclperm", "public.txt")

    denied_mpu =
      alice(:post, "/abkaclperm/mpu.txt",
        query: %{"uploads" => ""},
        headers: [{"x-amz-grant-read", ~s(uri="#{@all_users}")}]
      )
      |> call()

    assert denied_mpu.status == 403

    SigV4Request.signed_conn(:put, "/abkaclperm/src.txt",
      body: "src",
      headers: [{"x-amz-acl", "public-read"}]
    )
    |> call()

    denied_copy =
      alice(:put, "/abkaclperm/copy.txt",
        headers: [
          {"x-amz-copy-source", "/abkaclperm/src.txt"},
          {"x-amz-acl", "public-read"}
        ]
      )
      |> call()

    assert denied_copy.status == 403

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutObjectAcl","Resource":"arn:aws:s3:::abkaclperm/*"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "allow-put-object-acl", policy)

    allowed_put =
      alice(:put, "/abkaclperm/public.txt",
        body: "alice",
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert allowed_put.status == 200
  end
end
