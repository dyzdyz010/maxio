defmodule Maxio.S3.IdentityPolicyAuthzTest do
  use Maxio.DataCase, async: false

  alias Maxio.Auth.CredentialStore
  alias Maxio.IAM
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_identity_policy_authz")
  @alice_ak "AKIAIDENTITYPOLICY01"
  @alice_secret "identityidentityidentityid12"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    IAM.bootstrap_root()

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

  defp alice(method, path, opts \\ []) do
    SigV4Request.signed_conn(
      method,
      path,
      Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    )
  end

  defp root_iam(extra_query) do
    SigV4Request.signed_conn(:get, "/",
      query: Map.merge(%{"Action" => "ListMFADevices", "Version" => "2010-05-08"}, extra_query),
      service: "iam"
    )
  end

  test "identity policy grants non-owner object read without bucket policy" do
    SigV4Request.signed_conn(:put, "/idpb1") |> call()
    SigV4Request.signed_conn(:put, "/idpb1/docs/read.txt", body: "identity") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::idpb1/docs/*"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "read-docs", policy)

    allowed = alice(:get, "/idpb1/docs/read.txt") |> call()
    assert allowed.status == 200
    assert allowed.resp_body == "identity"

    denied = alice(:get, "/idpb1/other.txt") |> call()
    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
  end

  test "identity policy resource variables scope object access by aws:username" do
    SigV4Request.signed_conn(:put, "/idpvars") |> call()
    SigV4Request.signed_conn(:put, "/idpvars/home/#{@alice_ak}/read.txt", body: "mine") |> call()
    SigV4Request.signed_conn(:put, "/idpvars/home/other/read.txt", body: "theirs") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::idpvars/home/${aws:username}/*"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "home-scope", policy)

    allowed = alice(:get, "/idpvars/home/#{@alice_ak}/read.txt") |> call()
    assert allowed.status == 200
    assert allowed.resp_body == "mine"

    denied = alice(:get, "/idpvars/home/other/read.txt") |> call()
    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
  end

  test "identity policy variables expose userid principal type and defaults" do
    SigV4Request.signed_conn(:put, "/idpvarctx") |> call()

    SigV4Request.signed_conn(:put, "/idpvarctx/userid/#{@alice_ak}/read.txt", body: "userid")
    |> call()

    SigV4Request.signed_conn(:put, "/idpvarctx/type/User/read.txt", body: "type") |> call()
    SigV4Request.signed_conn(:put, "/idpvarctx/default/public.txt", body: "default") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":["arn:aws:s3:::idpvarctx/userid/${aws:userid}/*","arn:aws:s3:::idpvarctx/type/${aws:PrincipalType}/*","arn:aws:s3:::idpvarctx/default/${aws:missing, 'public.txt'}"]}})

    assert :ok = Store.put_principal_policy(@alice_arn, "context-vars", policy)

    by_userid = alice(:get, "/idpvarctx/userid/#{@alice_ak}/read.txt") |> call()
    assert by_userid.status == 200
    assert by_userid.resp_body == "userid"

    by_type = alice(:get, "/idpvarctx/type/User/read.txt") |> call()
    assert by_type.status == 200
    assert by_type.resp_body == "type"

    by_default = alice(:get, "/idpvarctx/default/public.txt") |> call()
    assert by_default.status == 200
    assert by_default.resp_body == "default"
  end

  test "unresolved identity policy resource variables fail closed through endpoint" do
    SigV4Request.signed_conn(:put, "/idpunresolved") |> call()

    SigV4Request.signed_conn(:put, "/idpunresolved/home/#{@alice_ak}/read.txt", body: "mine")
    |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::idpunresolved/home/${aws:PrincipalTag/team}/*"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "missing-var", policy)

    denied = alice(:get, "/idpunresolved/home/#{@alice_ak}/read.txt") |> call()
    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
  end

  test "unresolved NotResource variables do not broaden endpoint Deny statements" do
    SigV4Request.signed_conn(:put, "/idpnotresvar") |> call()
    SigV4Request.signed_conn(:put, "/idpnotresvar/private/read.txt", body: "private") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::idpnotresvar/*"},{"Effect":"Deny","Action":"s3:GetObject","NotResource":"arn:aws:s3:::idpnotresvar/home/${aws:PrincipalTag/team}/*"}]})

    assert :ok = Store.put_principal_policy(@alice_arn, "notresource-missing-var", policy)

    allowed = alice(:get, "/idpnotresvar/private/read.txt") |> call()
    assert allowed.status == 200
    assert allowed.resp_body == "private"
  end

  test "special policy variable literals do not become endpoint resource wildcards" do
    SigV4Request.signed_conn(:put, "/idplitvar") |> call()
    SigV4Request.signed_conn(:put, "/idplitvar/file%2A.txt", body: "literal") |> call()
    SigV4Request.signed_conn(:put, "/idplitvar/fileabc.txt", body: "other") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::idplitvar/file${*}.txt"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "literal-star", policy)

    literal = alice(:get, "/idplitvar/file%2A.txt") |> call()
    assert literal.status == 200
    assert literal.resp_body == "literal"

    denied = alice(:get, "/idplitvar/fileabc.txt") |> call()
    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
  end

  test "identity policy grants account-level ListBuckets" do
    SigV4Request.signed_conn(:put, "/idplist") |> call()

    denied = alice(:get, "/") |> call()
    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:ListAllMyBuckets","Resource":"*"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "list-buckets", policy)

    allowed = alice(:get, "/") |> call()
    assert allowed.status == 200
    assert allowed.resp_body =~ "<ListAllMyBucketsResult"
    assert allowed.resp_body =~ "<Name>idplist</Name>"
  end

  test "identity policy explicit deny overrides bucket policy allow" do
    SigV4Request.signed_conn(:put, "/idpb2") |> call()
    SigV4Request.signed_conn(:put, "/idpb2/secret.txt", body: "secret") |> call()

    bucket_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::idpb2/*"}})

    SigV4Request.signed_conn(:put, "/idpb2",
      query: %{"policy" => ""},
      body: bucket_policy,
      headers: [{"content-type", "application/json"}]
    )
    |> call()

    deny_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Deny","Action":"s3:GetObject","Resource":"arn:aws:s3:::idpb2/secret.txt"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "deny-secret", deny_policy)

    denied = alice(:get, "/idpb2/secret.txt") |> call()
    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
  end

  test "IAM group policy is inherited by explicit user access keys" do
    SigV4Request.signed_conn(:put, "/idpgroup") |> call()
    SigV4Request.signed_conn(:put, "/idpgroup/docs/read.txt", body: "group") |> call()

    user_name = "alice-group-#{System.unique_integer([:positive])}"
    group_name = "readers-#{System.unique_integer([:positive])}"
    access_key = "AKIAGROUPPOLICY01"
    secret = "group-policy-secret-123456789"

    assert {:ok, user} = IAM.create_user(name: user_name)
    assert {:ok, _group} = IAM.create_group(name: group_name)

    assert :ok =
             CredentialStore.put_access_key(%{
               access_key: access_key,
               secret_key: secret,
               principal: %{type: :iam_user, access_key: access_key, arn: user.user_arn}
             })

    assert :ok = IAM.add_user_to_group(user_name, group_name)

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::idpgroup/docs/*"}})

    put_policy =
      root_iam(%{
        "Action" => "PutGroupPolicy",
        "GroupName" => group_name,
        "PolicyName" => "read-docs",
        "PolicyDocument" => policy
      })
      |> call()

    assert put_policy.status == 200
    assert put_policy.resp_body =~ "<PutGroupPolicyResponse"

    allowed =
      SigV4Request.signed_conn(:get, "/idpgroup/docs/read.txt",
        access_key: access_key,
        secret: secret
      )
      |> call()

    assert allowed.status == 200
    assert allowed.resp_body == "group"

    assert :ok = IAM.remove_user_from_group(user_name, group_name)

    denied =
      SigV4Request.signed_conn(:get, "/idpgroup/docs/read.txt",
        access_key: access_key,
        secret: secret
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
  end

  test "IAM group explicit deny overrides user identity policy allow" do
    SigV4Request.signed_conn(:put, "/idpgroupdeny") |> call()
    SigV4Request.signed_conn(:put, "/idpgroupdeny/public.txt", body: "public") |> call()
    SigV4Request.signed_conn(:put, "/idpgroupdeny/secret.txt", body: "secret") |> call()

    user_name = "alice-deny-#{System.unique_integer([:positive])}"
    group_name = "deny-#{System.unique_integer([:positive])}"
    access_key = "AKIAGROUPDENY01"
    secret = "group-deny-secret-1234567890"

    assert {:ok, user} = IAM.create_user(name: user_name)
    assert {:ok, _group} = IAM.create_group(name: group_name)

    assert :ok =
             CredentialStore.put_access_key(%{
               access_key: access_key,
               secret_key: secret,
               principal: %{type: :iam_user, access_key: access_key, arn: user.user_arn}
             })

    assert :ok = IAM.add_user_to_group(user_name, group_name)

    allow =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::idpgroupdeny/*"}})

    deny =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Deny","Action":"s3:GetObject","Resource":"arn:aws:s3:::idpgroupdeny/secret.txt"}})

    assert :ok = Store.put_principal_policy(user.user_arn, "allow-all", allow)
    assert :ok = IAM.put_group_policy(group_name, "deny-secret", deny)

    allowed =
      SigV4Request.signed_conn(:get, "/idpgroupdeny/public.txt",
        access_key: access_key,
        secret: secret
      )
      |> call()

    assert allowed.status == 200
    assert allowed.resp_body == "public"

    denied =
      SigV4Request.signed_conn(:get, "/idpgroupdeny/secret.txt",
        access_key: access_key,
        secret: secret
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
  end

  test "user and group managed policy attachments affect endpoint authorization" do
    SigV4Request.signed_conn(:put, "/idpmanaged") |> call()
    SigV4Request.signed_conn(:put, "/idpmanaged/public.txt", body: "public") |> call()
    SigV4Request.signed_conn(:put, "/idpmanaged/secret.txt", body: "secret") |> call()

    user_name = "alice-managed-#{System.unique_integer([:positive])}"
    group_name = "deny-managed-#{System.unique_integer([:positive])}"
    access_key = "AKIAMANAGEDPOL01"
    secret = "managed-policy-secret-123456"
    allow_policy_name = "managed-allow-#{System.unique_integer([:positive])}"
    deny_policy_name = "managed-deny-#{System.unique_integer([:positive])}"

    assert {:ok, user} = IAM.create_user(name: user_name)
    assert {:ok, _group} = IAM.create_group(name: group_name)

    assert :ok =
             CredentialStore.put_access_key(%{
               access_key: access_key,
               secret_key: secret,
               principal: %{type: :iam_user, access_key: access_key, arn: user.user_arn}
             })

    assert :ok = IAM.add_user_to_group(user_name, group_name)

    allow =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::idpmanaged/*"}})

    deny =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Deny","Action":"s3:GetObject","Resource":"arn:aws:s3:::idpmanaged/secret.txt"}})

    assert {:ok, allow_policy} =
             IAM.create_managed_policy(
               name: allow_policy_name,
               path: "/authz/",
               policy: allow
             )

    assert {:ok, deny_policy} =
             IAM.create_managed_policy(name: deny_policy_name, path: "/authz/", policy: deny)

    assert :ok = IAM.attach_user_policy(user_name, allow_policy.policy_arn)
    assert :ok = IAM.attach_group_policy(group_name, deny_policy.policy_arn)

    allowed =
      SigV4Request.signed_conn(:get, "/idpmanaged/public.txt",
        access_key: access_key,
        secret: secret
      )
      |> call()

    assert allowed.status == 200
    assert allowed.resp_body == "public"

    denied =
      SigV4Request.signed_conn(:get, "/idpmanaged/secret.txt",
        access_key: access_key,
        secret: secret
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"

    assert :ok = IAM.detach_group_policy(group_name, deny_policy.policy_arn)

    allowed_after_detach =
      SigV4Request.signed_conn(:get, "/idpmanaged/secret.txt",
        access_key: access_key,
        secret: secret
      )
      |> call()

    assert allowed_after_detach.status == 200
    assert allowed_after_detach.resp_body == "secret"
  end

  test "user permissions boundary limits identity policy without blocking direct resource grants" do
    SigV4Request.signed_conn(:put, "/idpboundary") |> call()
    SigV4Request.signed_conn(:put, "/idpboundary/docs/read.txt", body: "docs") |> call()
    SigV4Request.signed_conn(:put, "/idpboundary/private.txt", body: "private") |> call()
    SigV4Request.signed_conn(:put, "/idpboundary/resource-only.txt", body: "resource") |> call()

    user_name = "alice-boundary-#{System.unique_integer([:positive])}"
    access_key = "AKIABOUNDARYPOL1"
    secret = "boundary-policy-secret-123456"

    assert {:ok, user} = IAM.create_user(name: user_name)

    assert :ok =
             CredentialStore.put_access_key(%{
               access_key: access_key,
               secret_key: secret,
               principal: %{type: :iam_user, access_key: access_key, arn: user.user_arn}
             })

    allow_all =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::idpboundary/*"}})

    boundary_docs =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::idpboundary/docs/*"}})

    boundary_explicit_deny =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Deny","Action":"s3:GetObject","Resource":"arn:aws:s3:::idpboundary/resource-only.txt"}})

    bucket_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{user.user_arn}"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::idpboundary/resource-only.txt"}})

    assert :ok = Store.put_principal_policy(user.user_arn, "allow-all", allow_all)

    assert {:ok, boundary_policy} =
             IAM.create_managed_policy(
               name: "boundary-docs-#{System.unique_integer([:positive])}",
               path: "/authz/",
               policy: boundary_docs
             )

    assert {:ok, deny_boundary_policy} =
             IAM.create_managed_policy(
               name: "boundary-deny-#{System.unique_integer([:positive])}",
               path: "/authz/",
               policy: boundary_explicit_deny
             )

    assert {:ok, _user} =
             IAM.put_user_permissions_boundary_strict(user.user_name, boundary_policy.policy_arn)

    allowed =
      SigV4Request.signed_conn(:get, "/idpboundary/docs/read.txt",
        access_key: access_key,
        secret: secret
      )
      |> call()

    assert allowed.status == 200
    assert allowed.resp_body == "docs"

    denied_by_boundary =
      SigV4Request.signed_conn(:get, "/idpboundary/private.txt",
        access_key: access_key,
        secret: secret
      )
      |> call()

    assert denied_by_boundary.status == 403
    assert denied_by_boundary.resp_body =~ "AccessDenied"

    SigV4Request.signed_conn(:put, "/idpboundary",
      query: %{"policy" => ""},
      body: bucket_policy,
      headers: [{"content-type", "application/json"}]
    )
    |> call()

    resource_grant =
      SigV4Request.signed_conn(:get, "/idpboundary/resource-only.txt",
        access_key: access_key,
        secret: secret
      )
      |> call()

    assert resource_grant.status == 200
    assert resource_grant.resp_body == "resource"

    assert {:ok, _user} =
             IAM.put_user_permissions_boundary_strict(
               user.user_name,
               deny_boundary_policy.policy_arn
             )

    denied_by_explicit_boundary =
      SigV4Request.signed_conn(:get, "/idpboundary/resource-only.txt",
        access_key: access_key,
        secret: secret
      )
      |> call()

    assert denied_by_explicit_boundary.status == 403
    assert denied_by_explicit_boundary.resp_body =~ "AccessDenied"
  end

  test "user permissions boundary explicit deny overrides owner shortcut" do
    user_name = "alice-owner-boundary-#{System.unique_integer([:positive])}"
    access_key = "AKIAOWNERBOUND01"
    secret = "owner-boundary-secret-123456"
    bucket = "idpownerboundary"

    assert {:ok, user} = IAM.create_user(name: user_name)

    assert :ok =
             CredentialStore.put_access_key(%{
               access_key: access_key,
               secret_key: secret,
               principal: %{type: :iam_user, access_key: access_key, arn: user.user_arn}
             })

    identity_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:*","Resource":["arn:aws:s3:::#{bucket}","arn:aws:s3:::#{bucket}/*"]}})

    boundary_policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:CreateBucket","s3:PutObject"],"Resource":["arn:aws:s3:::#{bucket}","arn:aws:s3:::#{bucket}/*"]},{"Effect":"Deny","Action":"s3:GetObject","Resource":"arn:aws:s3:::#{bucket}/*"}]})

    assert :ok = Store.put_principal_policy(user.user_arn, "allow-bucket-owner", identity_policy)

    assert {:ok, boundary} =
             IAM.create_managed_policy(
               name: "owner-boundary-#{System.unique_integer([:positive])}",
               path: "/authz/",
               policy: boundary_policy
             )

    assert {:ok, _user} =
             IAM.put_user_permissions_boundary_strict(user.user_name, boundary.policy_arn)

    create_bucket =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        access_key: access_key,
        secret: secret
      )
      |> call()

    assert create_bucket.status == 200

    put_object =
      SigV4Request.signed_conn(:put, "/#{bucket}/owned.txt",
        access_key: access_key,
        secret: secret,
        body: "owned"
      )
      |> call()

    assert put_object.status == 200

    denied_owner_get =
      SigV4Request.signed_conn(:get, "/#{bucket}/owned.txt",
        access_key: access_key,
        secret: secret
      )
      |> call()

    assert denied_owner_get.status == 403
    assert denied_owner_get.resp_body =~ "AccessDenied"
  end
end
