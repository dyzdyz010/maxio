defmodule Maxio.S3.IdentityPolicyAuthzTest do
  use Maxio.DataCase, async: false

  alias Maxio.Auth.CredentialStore
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
end
