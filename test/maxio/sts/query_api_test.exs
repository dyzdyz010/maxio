defmodule Maxio.STS.QueryAPITest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore.EctoStore
  alias Maxio.Auth.SigV4.Signer
  alias Maxio.IAM
  alias Maxio.IAM.{STSSession, TOTP}
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @account_id "000000000000"

  setup do
    previous_store = Application.fetch_env!(:maxio, :credential_store)
    Application.put_env(:maxio, :credential_store, EctoStore)
    on_exit(fn -> Application.put_env(:maxio, :credential_store, previous_store) end)

    IAM.bootstrap_root()
    :ok
  end

  test "signed GetSessionToken returns temporary credentials usable by S3" do
    response =
      signed_sts_conn(%{"DurationSeconds" => "900"})
      |> call()

    assert response.status == 200
    assert response.resp_body =~ "<GetSessionTokenResponse"
    assert response.resp_body =~ "<Credentials>"

    credentials = credentials_from(response.resp_body)

    assert String.starts_with?(credentials.access_key, "ASIA")
    assert credentials.secret_key != ""
    assert credentials.session_token != ""

    bucket = unique_bucket("stsapi")

    put_bucket =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert put_bucket.status == 200
  end

  test "POST form GetSessionToken returns temporary credentials usable by S3" do
    response =
      signed_sts_form_conn(%{"DurationSeconds" => "900"})
      |> call()

    assert response.status == 200
    assert response.resp_body =~ "<GetSessionTokenResponse"

    credentials = credentials_from(response.resp_body)
    bucket = unique_bucket("stspost")

    put_bucket =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert put_bucket.status == 200
  end

  test "anonymous GetSessionToken is denied with STS error envelope" do
    response =
      SigV4Request.anon_conn(:get, "/", query: base_query())
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<ErrorResponse"
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    refute response.resp_body =~ "<ListAllMyBucketsResult"
  end

  test "anonymous GetCallerIdentity is denied with STS error envelope" do
    response =
      SigV4Request.anon_conn(:get, "/", query: base_query(%{"Action" => "GetCallerIdentity"}))
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<ErrorResponse"
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    refute response.resp_body =~ "<ListAllMyBucketsResult"
  end

  test "unsupported STS action does not fall through to S3 ListBuckets" do
    response =
      signed_sts_conn(%{"Action" => "GetAccessKeyInfo"})
      |> call()

    assert response.status == 400
    assert response.resp_body =~ "<Code>InvalidAction</Code>"
    refute response.resp_body =~ "<ListAllMyBucketsResult"
  end

  test "unsupported POST form action does not fall through to S3 ListBuckets" do
    response =
      signed_sts_form_conn(%{"Action" => "GetAccessKeyInfo"})
      |> call()

    assert response.status == 400
    assert response.resp_body =~ "<Code>InvalidAction</Code>"
    refute response.resp_body =~ "<ListAllMyBucketsResult"
  end

  test "signed GetCallerIdentity returns the root caller identity" do
    response =
      signed_sts_conn(%{"Action" => "GetCallerIdentity"})
      |> call()

    assert response.status == 200
    assert response.resp_body =~ "<GetCallerIdentityResponse"
    assert xml_value(response.resp_body, "UserId") == SigV4Request.access_key()
    assert xml_value(response.resp_body, "Account") == @account_id
    assert xml_value(response.resp_body, "Arn") == IAM.root_principal_arn()
    refute response.resp_body =~ "<ListAllMyBucketsResult"
  end

  test "POST form GetCallerIdentity returns the caller identity" do
    response =
      signed_sts_form_conn(%{"Action" => "GetCallerIdentity"})
      |> call()

    assert response.status == 200
    assert response.resp_body =~ "<GetCallerIdentityResponse"
    assert xml_value(response.resp_body, "UserId") == SigV4Request.access_key()
    assert xml_value(response.resp_body, "Account") == @account_id
    assert xml_value(response.resp_body, "Arn") == IAM.root_principal_arn()
  end

  test "GetCallerIdentity returns IAM user identity" do
    access_key = "AKIAGETCALLER#{System.unique_integer([:positive])}"
    secret_key = "get-caller-secret"

    assert {:ok, key} =
             IAM.create_access_key(access_key_id: access_key, secret_key: secret_key)

    response =
      signed_sts_conn(%{"Action" => "GetCallerIdentity"},
        access_key: key.access_key_id,
        secret: secret_key
      )
      |> call()

    assert response.status == 200
    assert xml_value(response.resp_body, "UserId") == key.access_key_id
    assert xml_value(response.resp_body, "Account") == @account_id
    assert xml_value(response.resp_body, "Arn") == key.principal_arn
  end

  test "GetCallerIdentity accepts GetSessionToken temporary credentials" do
    credentials =
      signed_sts_conn(%{"DurationSeconds" => "900"})
      |> call()
      |> then(&credentials_from(&1.resp_body))

    response =
      signed_sts_conn(%{"Action" => "GetCallerIdentity"},
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert response.status == 200
    assert xml_value(response.resp_body, "UserId") == SigV4Request.access_key()
    assert xml_value(response.resp_body, "Account") == @account_id
    assert xml_value(response.resp_body, "Arn") == IAM.root_principal_arn()
  end

  test "GetSessionToken MFA context is exposed to later S3 authorization" do
    bucket = unique_bucket("gst-mfa")
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    access_key = "AKIAGSTMFA#{System.unique_integer([:positive])}"
    secret_key = "get-session-token-mfa-secret"
    assert {:ok, key} = IAM.create_access_key(access_key_id: access_key, secret_key: secret_key)

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::#{bucket}/open/*"},{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::#{bucket}/protected/*","Condition":{"Bool":{"aws:MultiFactorAuthPresent":"true"}}},{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::#{bucket}/deny-false/*"},{"Effect":"Deny","Action":"s3:PutObject","Resource":"arn:aws:s3:::#{bucket}/deny-false/*","Condition":{"Bool":{"aws:MultiFactorAuthPresent":"false"}}}]})

    assert :ok = IAM.put_principal_policy(key.principal_arn, "mfa-put", policy)

    without_mfa =
      signed_sts_conn(%{"DurationSeconds" => "900"},
        access_key: key.access_key_id,
        secret: secret_key
      )
      |> call()
      |> then(&credentials_from(&1.resp_body))

    denied =
      SigV4Request.signed_conn(:put, "/#{bucket}/protected/denied.txt",
        body: "denied",
        access_key: without_mfa.access_key,
        secret: without_mfa.secret_key,
        session_token: without_mfa.session_token
      )
      |> call()

    assert denied.status == 403

    explicit_deny =
      SigV4Request.signed_conn(:put, "/#{bucket}/deny-false/no-mfa.txt",
        body: "denied",
        access_key: without_mfa.access_key,
        secret: without_mfa.secret_key,
        session_token: without_mfa.session_token
      )
      |> call()

    assert explicit_deny.status == 403

    {serial, token_code} = active_mfa_code("gst", key.principal_arn)

    with_mfa =
      signed_sts_conn(
        %{"DurationSeconds" => "900", "SerialNumber" => serial, "TokenCode" => token_code},
        access_key: key.access_key_id,
        secret: secret_key
      )
      |> call()
      |> then(&credentials_from(&1.resp_body))

    persisted = Repo.get_by!(STSSession, access_key_id: with_mfa.access_key)
    assert persisted.mfa_authenticated == true
    assert is_binary(persisted.mfa_serial_hash)

    allowed =
      SigV4Request.signed_conn(:put, "/#{bucket}/protected/allowed.txt",
        body: "allowed",
        access_key: with_mfa.access_key,
        secret: with_mfa.secret_key,
        session_token: with_mfa.session_token
      )
      |> call()

    assert allowed.status == 200

    explicit_deny_bypassed =
      SigV4Request.signed_conn(:put, "/#{bucket}/deny-false/with-mfa.txt",
        body: "allowed",
        access_key: with_mfa.access_key,
        secret: with_mfa.secret_key,
        session_token: with_mfa.session_token
      )
      |> call()

    assert explicit_deny_bypassed.status == 200

    open =
      SigV4Request.signed_conn(:put, "/#{bucket}/open/allowed.txt",
        body: "open",
        access_key: with_mfa.access_key,
        secret: with_mfa.secret_key,
        session_token: with_mfa.session_token
      )
      |> call()

    assert open.status == 200

    before_replay = Repo.aggregate(STSSession, :count)

    replay =
      signed_sts_conn(
        %{"DurationSeconds" => "900", "SerialNumber" => serial, "TokenCode" => token_code},
        access_key: key.access_key_id,
        secret: secret_key
      )
      |> call()

    assert replay.status == 403
    assert replay.resp_body =~ "<Code>AccessDenied</Code>"
    assert Repo.aggregate(STSSession, :count) == before_replay
  end

  test "GetSessionToken rejects invalid MFA parameters before issuing credentials" do
    before_count = Repo.aggregate(STSSession, :count)

    cases = [
      {%{"SerialNumber" => "arn:aws:iam:::mfa/root"}, "TokenCode"},
      {%{"TokenCode" => "123456"}, "SerialNumber"},
      {%{"SerialNumber" => "arn:aws:iam:::mfa/root", "TokenCode" => "abcdef"}, "TokenCode"}
    ]

    for {params, expected_message} <- cases do
      response =
        signed_sts_conn(params)
        |> call()

      assert response.status == 400
      assert response.resp_body =~ "<Code>InvalidParameterValue</Code>"
      assert response.resp_body =~ expected_message
    end

    assert Repo.aggregate(STSSession, :count) == before_count
  end

  test "GetCallerIdentity still requires STS credential scope" do
    response =
      SigV4Request.signed_conn(:get, "/",
        query: base_query(%{"Action" => "GetCallerIdentity"}),
        service: "s3"
      )
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    assert response.resp_body =~ "Credential scope service must be sts"
  end

  test "invalid duration is rejected before issuing credentials" do
    response =
      signed_sts_conn(%{"DurationSeconds" => "899"})
      |> call()

    assert response.status == 400
    assert response.resp_body =~ "<Code>InvalidParameterValue</Code>"
    refute response.resp_body =~ "<Credentials>"

    root_over_cap =
      signed_sts_conn(%{"DurationSeconds" => "3601"})
      |> call()

    assert root_over_cap.status == 400
    assert root_over_cap.resp_body =~ "<Code>InvalidParameterValue</Code>"
  end

  test "temporary credentials cannot recursively call GetSessionToken" do
    credentials =
      signed_sts_conn(%{"DurationSeconds" => "900"})
      |> call()
      |> then(&credentials_from(&1.resp_body))

    assert Repo.aggregate(STSSession, :count) == 1

    response =
      signed_sts_conn(%{"DurationSeconds" => "900"},
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    assert response.resp_body =~ "temporary credentials"
    assert Repo.aggregate(STSSession, :count) == 1
  end

  test "STS requests must be signed with sts credential scope service" do
    response =
      SigV4Request.signed_conn(:get, "/",
        query: base_query(%{"DurationSeconds" => "900"}),
        service: "s3"
      )
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    assert response.resp_body =~ "Credential scope service must be sts"
  end

  test "POST form requests must be signed with sts credential scope service" do
    response =
      SigV4Request.signed_conn(:post, "/",
        body: form_body(%{"DurationSeconds" => "900"}),
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        service: "s3"
      )
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    assert response.resp_body =~ "Credential scope service must be sts"
  end

  test "POST form body must match signed payload hash" do
    before_count = Repo.aggregate(STSSession, :count)
    signed_body = form_body(%{"DurationSeconds" => "900"})
    tampered_body = form_body(%{"DurationSeconds" => "901"})

    response =
      SigV4Request.signed_conn(:post, "/",
        body: tampered_body,
        content_sha256_override: Signer.hex_sha256(signed_body),
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        service: "sts"
      )
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    assert response.resp_body =~ "payload hash"
    assert Repo.aggregate(STSSession, :count) == before_count
  end

  test "signed AssumeRole returns role credentials usable by S3 role policy" do
    bucket = unique_bucket("assumerole")
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    {:ok, role} = create_trusted_role("writer")

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":["s3:PutObject","s3:GetObject"],"Resource":"arn:aws:s3:::#{bucket}/*"}})

    assert :ok = IAM.put_principal_policy(role.role_arn, "object-rw", policy)

    response =
      signed_assume_role_conn(role, "writer-session", %{"DurationSeconds" => "900"})
      |> call()

    assert response.status == 200
    assert response.resp_body =~ "<AssumeRoleResponse"
    assert response.resp_body =~ "<AssumedRoleUser>"

    credentials = credentials_from(response.resp_body)
    assert xml_value(response.resp_body, "Arn") == assumed_role_arn(role, "writer-session")

    put_object =
      SigV4Request.signed_conn(:put, "/#{bucket}/role.txt",
        body: "from-role",
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert put_object.status == 200

    get_object =
      SigV4Request.signed_conn(:get, "/#{bucket}/role.txt",
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert get_object.status == 200
    assert get_object.resp_body == "from-role"
  end

  test "AssumeRole inline session policy intersects role policy and is persisted" do
    bucket = unique_bucket("session-policy")
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/allowed.txt", body: "allowed") |> call()

    {:ok, role} = create_trusted_role("session-boundary")

    role_policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Action" => ["s3:GetObject", "s3:PutObject"],
          "Resource" => "arn:aws:s3:::#{bucket}/*"
        }
      })

    session_policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => [
          %{
            "Effect" => "Allow",
            "Action" => "s3:GetObject",
            "Resource" => "arn:aws:s3:::#{bucket}/*"
          },
          %{
            "Effect" => "Deny",
            "Action" => "s3:PutObject",
            "Resource" => "arn:aws:s3:::#{bucket}/*"
          }
        ]
      })

    assert :ok = IAM.put_principal_policy(role.role_arn, "object-rw", role_policy)

    response =
      signed_assume_role_conn(role, "session-boundary", %{
        "DurationSeconds" => "900",
        "Policy" => session_policy
      })
      |> call()

    assert response.status == 200
    credentials = credentials_from(response.resp_body)

    persisted = Repo.get_by!(STSSession, access_key_id: credentials.access_key)
    assert persisted.session_policy["Version"] == "2012-10-17"
    assert length(persisted.session_policy["Statement"]) == 2

    allowed_get =
      SigV4Request.signed_conn(:get, "/#{bucket}/allowed.txt",
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert allowed_get.status == 200
    assert allowed_get.resp_body == "allowed"

    denied_put =
      SigV4Request.signed_conn(:put, "/#{bucket}/denied.txt",
        body: "denied",
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert denied_put.status == 403
  end

  test "AssumeRole inline session policy cannot grant permissions missing from role policy" do
    bucket = unique_bucket("session-no-grant")
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    {:ok, role} = create_trusted_role("session-no-grant")

    role_policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Action" => "s3:GetObject",
          "Resource" => "arn:aws:s3:::#{bucket}/*"
        }
      })

    session_policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Action" => "s3:PutObject",
          "Resource" => "arn:aws:s3:::#{bucket}/*"
        }
      })

    assert :ok = IAM.put_principal_policy(role.role_arn, "object-readonly", role_policy)

    response =
      signed_assume_role_conn(role, "session-no-grant", %{
        "DurationSeconds" => "900",
        "Policy" => session_policy
      })
      |> call()

    assert response.status == 200
    credentials = credentials_from(response.resp_body)

    denied_put =
      SigV4Request.signed_conn(:put, "/#{bucket}/denied.txt",
        body: "denied",
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert denied_put.status == 403
  end

  test "AssumeRole PolicyArns managed session policies intersect role policy" do
    bucket = unique_bucket("managed-session")
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/allowed.txt", body: "allowed") |> call()

    {:ok, role} = create_trusted_role("managed-session")

    role_policy =
      policy_doc(
        allow_statement(
          ["s3:GetObject", "s3:PutObject"],
          "arn:aws:s3:::#{bucket}/*"
        )
      )

    managed_policy =
      policy_doc([
        allow_statement("s3:GetObject", "arn:aws:s3:::#{bucket}/*"),
        %{
          "Effect" => "Deny",
          "Action" => "s3:PutObject",
          "Resource" => "arn:aws:s3:::#{bucket}/*"
        }
      ])

    policy_arn = managed_policy_arn("session-readonly")
    assert :ok = IAM.put_principal_policy(role.role_arn, "object-rw", role_policy)
    assert :ok = Maxio.Policy.Store.put_managed_session_policy(policy_arn, managed_policy)

    response =
      signed_assume_role_conn(role, "managed-session", %{
        "DurationSeconds" => "900",
        "PolicyArns.member.1.arn" => policy_arn
      })
      |> call()

    assert response.status == 200
    credentials = credentials_from(response.resp_body)

    persisted = Repo.get_by!(STSSession, access_key_id: credentials.access_key)
    assert length(persisted.session_policy["Statement"]) == 2

    assert signed_s3(:get, "/#{bucket}/allowed.txt", credentials).status == 200

    denied_put =
      signed_s3(:put, "/#{bucket}/denied.txt", credentials, body: "denied")

    assert denied_put.status == 403
  end

  test "AssumeRole PolicyArns cannot grant permissions missing from role policy" do
    bucket = unique_bucket("managed-no-grant")
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    {:ok, role} = create_trusted_role("managed-no-grant")

    role_policy =
      policy_doc(allow_statement("s3:GetObject", "arn:aws:s3:::#{bucket}/*"))

    managed_policy =
      policy_doc(allow_statement("s3:PutObject", "arn:aws:s3:::#{bucket}/*"))

    policy_arn = managed_policy_arn("session-put")
    assert :ok = IAM.put_principal_policy(role.role_arn, "object-readonly", role_policy)
    assert :ok = Maxio.Policy.Store.put_managed_session_policy(policy_arn, managed_policy)

    credentials =
      assume_role_credentials(role, "managed-no-grant", %{
        "DurationSeconds" => "900",
        "PolicyArns.member.1.arn" => policy_arn
      })

    assert signed_s3(:put, "/#{bucket}/denied.txt", credentials, body: "denied").status == 403
  end

  test "AssumeRole PolicyArns accepts IAM managed policy ARN path and name boundary" do
    bucket = unique_bucket("managed-boundary")
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/allowed.txt", body: "allowed") |> call()

    {:ok, role} = create_trusted_role("managed-boundary")

    role_policy =
      policy_doc(allow_statement("s3:GetObject", "arn:aws:s3:::#{bucket}/*"))

    managed_policy =
      policy_doc(allow_statement("s3:GetObject", "arn:aws:s3:::#{bucket}/*"))

    path = "/" <> String.duplicate("a", 510) <> "/"
    policy_name = String.duplicate("b", 128)
    policy_arn = IAM.managed_policy_arn(policy_name, path)

    assert :ok = IAM.put_principal_policy(role.role_arn, "object-readonly", role_policy)

    assert {:ok, %{policy_arn: ^policy_arn, path: ^path, policy_name: ^policy_name}} =
             IAM.create_managed_policy(name: policy_name, path: path, policy: managed_policy)

    credentials =
      assume_role_credentials(role, "managed-boundary", %{
        "DurationSeconds" => "900",
        "PolicyArns.member.1.arn" => policy_arn
      })

    assert signed_s3(:get, "/#{bucket}/allowed.txt", credentials).status == 200
  end

  test "AssumeRole uses managed policies attached to the target role" do
    bucket = unique_bucket("attached-role-policy")
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/allowed.txt", body: "allowed") |> call()

    {:ok, role} = create_trusted_role("attached-role-policy")

    managed_policy =
      policy_doc(allow_statement("s3:GetObject", "arn:aws:s3:::#{bucket}/*"))

    unattached_policy =
      policy_doc(allow_statement("s3:PutObject", "arn:aws:s3:::#{bucket}/*"))

    read_policy_arn = managed_policy_arn("attached-role-read")
    write_policy_arn = managed_policy_arn("unattached-role-write")

    assert :ok = IAM.put_managed_policy(policy_arn: read_policy_arn, policy: managed_policy)
    assert :ok = IAM.put_managed_policy(policy_arn: write_policy_arn, policy: unattached_policy)

    no_policy_credentials =
      assume_role_credentials(role, "attached-role-before", %{"DurationSeconds" => "900"})

    assert signed_s3(:get, "/#{bucket}/allowed.txt", no_policy_credentials).status == 403

    assert :ok = IAM.attach_role_policy(role.role_arn, read_policy_arn)

    attached_credentials =
      assume_role_credentials(role, "attached-role-after", %{"DurationSeconds" => "900"})

    assert signed_s3(:get, "/#{bucket}/allowed.txt", attached_credentials).status == 200

    assert signed_s3(:put, "/#{bucket}/denied.txt", attached_credentials, body: "denied").status ==
             403

    assert :ok = IAM.detach_role_policy(role.role_arn, read_policy_arn)

    detached_credentials =
      assume_role_credentials(role, "attached-role-detached", %{"DurationSeconds" => "900"})

    assert signed_s3(:get, "/#{bucket}/allowed.txt", detached_credentials).status == 403
  end

  test "AssumeRole snapshots PolicyArns into the issued session policy" do
    bucket = unique_bucket("managed-snapshot")
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/allowed.txt", body: "allowed") |> call()

    {:ok, role} = create_trusted_role("managed-snapshot")

    role_policy =
      policy_doc(
        allow_statement(
          ["s3:GetObject", "s3:PutObject"],
          "arn:aws:s3:::#{bucket}/*"
        )
      )

    readonly_policy = policy_doc(allow_statement("s3:GetObject", "arn:aws:s3:::#{bucket}/*"))
    write_policy = policy_doc(allow_statement("s3:PutObject", "arn:aws:s3:::#{bucket}/*"))
    policy_arn = managed_policy_arn("snapshot-boundary")

    assert :ok = IAM.put_principal_policy(role.role_arn, "object-rw", role_policy)
    assert :ok = Maxio.Policy.Store.put_managed_session_policy(policy_arn, readonly_policy)

    credentials =
      assume_role_credentials(role, "managed-snapshot", %{
        "DurationSeconds" => "900",
        "PolicyArns.member.1.arn" => policy_arn
      })

    assert :ok = Maxio.Policy.Store.put_managed_session_policy(policy_arn, write_policy)

    assert signed_s3(:get, "/#{bucket}/allowed.txt", credentials).status == 200

    assert signed_s3(:put, "/#{bucket}/still-denied.txt", credentials, body: "denied").status ==
             403
  end

  test "POST AssumeRole inline session policy applies to owner shortcut paths" do
    bucket = unique_bucket("session-owner")
    {:ok, role} = create_trusted_role("session-owner")

    role_policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => [
          %{
            "Effect" => "Allow",
            "Action" => "s3:CreateBucket",
            "Resource" => "arn:aws:s3:::#{bucket}"
          },
          %{
            "Effect" => "Allow",
            "Action" => "s3:PutObject",
            "Resource" => "arn:aws:s3:::#{bucket}/*"
          }
        ]
      })

    session_policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Action" => "s3:CreateBucket",
          "Resource" => "arn:aws:s3:::#{bucket}"
        }
      })

    assert :ok = IAM.put_principal_policy(role.role_arn, "create-and-put", role_policy)

    response =
      signed_assume_role_form_conn(role, "session-owner", %{
        "DurationSeconds" => "900",
        "Policy" => session_policy
      })
      |> call()

    assert response.status == 200
    credentials = credentials_from(response.resp_body)

    create_bucket =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert create_bucket.status == 200

    owner_put_denied =
      SigV4Request.signed_conn(:put, "/#{bucket}/denied.txt",
        body: "denied",
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert owner_put_denied.status == 403
  end

  test "AssumeRole session policy cannot override role explicit deny on owned bucket" do
    bucket = unique_bucket("session-deny")
    {:ok, role} = create_trusted_role("session-deny")

    role_policy =
      policy_doc([
        allow_statement("s3:CreateBucket", "arn:aws:s3:::#{bucket}"),
        %{
          "Effect" => "Deny",
          "Action" => "s3:PutObject",
          "Resource" => "arn:aws:s3:::#{bucket}/*"
        }
      ])

    session_policy =
      policy_doc(
        allow_statement(
          ["s3:CreateBucket", "s3:PutObject"],
          ["arn:aws:s3:::#{bucket}", "arn:aws:s3:::#{bucket}/*"]
        )
      )

    assert :ok = IAM.put_principal_policy(role.role_arn, "create-deny-put", role_policy)

    credentials =
      assume_role_credentials(role, "session-deny", %{
        "DurationSeconds" => "900",
        "Policy" => session_policy
      })

    create_bucket =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert create_bucket.status == 200

    denied_put =
      SigV4Request.signed_conn(:put, "/#{bucket}/denied.txt",
        body: "denied",
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert denied_put.status == 403
  end

  test "AssumeRole session policy cannot grant ACL header secondary permission" do
    bucket = unique_bucket("session-acl")
    {:ok, role} = create_trusted_role("session-acl")

    role_policy =
      policy_doc([
        allow_statement("s3:CreateBucket", "arn:aws:s3:::#{bucket}"),
        allow_statement("s3:PutBucketOwnershipControls", "arn:aws:s3:::#{bucket}"),
        allow_statement("s3:PutObject", "arn:aws:s3:::#{bucket}/*")
      ])

    session_policy =
      policy_doc(
        allow_statement(
          [
            "s3:CreateBucket",
            "s3:PutBucketOwnershipControls",
            "s3:PutObject",
            "s3:PutObjectAcl"
          ],
          ["arn:aws:s3:::#{bucket}", "arn:aws:s3:::#{bucket}/*"]
        )
      )

    assert :ok = IAM.put_principal_policy(role.role_arn, "create-put-no-acl", role_policy)

    credentials =
      assume_role_credentials(role, "session-acl", %{
        "DurationSeconds" => "900",
        "Policy" => session_policy
      })

    assert signed_s3(:put, "/#{bucket}", credentials,
             headers: [{"x-amz-object-ownership", "ObjectWriter"}]
           ).status == 200

    denied_acl_put =
      signed_s3(:put, "/#{bucket}/public.txt", credentials,
        body: "public",
        headers: [{"x-amz-acl", "public-read"}]
      )

    assert denied_acl_put.status == 403
  end

  test "AssumeRole session policy cannot grant CopyObject source read" do
    bucket = unique_bucket("session-copy")
    {:ok, role} = create_trusted_role("session-copy")

    role_policy =
      policy_doc([
        allow_statement("s3:CreateBucket", "arn:aws:s3:::#{bucket}"),
        allow_statement("s3:PutObject", "arn:aws:s3:::#{bucket}/*")
      ])

    session_policy =
      policy_doc(
        allow_statement(
          ["s3:CreateBucket", "s3:PutObject", "s3:GetObject"],
          ["arn:aws:s3:::#{bucket}", "arn:aws:s3:::#{bucket}/*"]
        )
      )

    assert :ok = IAM.put_principal_policy(role.role_arn, "put-no-get", role_policy)

    credentials =
      assume_role_credentials(role, "session-copy", %{
        "DurationSeconds" => "900",
        "Policy" => session_policy
      })

    assert signed_s3(:put, "/#{bucket}", credentials).status == 200
    assert signed_s3(:put, "/#{bucket}/src.txt", credentials, body: "source").status == 200

    denied_copy =
      signed_s3(:put, "/#{bucket}/dst.txt", credentials,
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"}]
      )

    assert denied_copy.status == 403
  end

  test "AssumeRole session policy cannot grant DeleteObjects owner branch" do
    bucket = unique_bucket("session-del")
    {:ok, role} = create_trusted_role("session-del")

    role_policy =
      policy_doc([
        allow_statement("s3:CreateBucket", "arn:aws:s3:::#{bucket}"),
        allow_statement("s3:PutObject", "arn:aws:s3:::#{bucket}/*")
      ])

    session_policy =
      policy_doc(
        allow_statement(
          ["s3:CreateBucket", "s3:PutObject", "s3:DeleteObject"],
          ["arn:aws:s3:::#{bucket}", "arn:aws:s3:::#{bucket}/*"]
        )
      )

    assert :ok = IAM.put_principal_policy(role.role_arn, "put-no-delete", role_policy)

    credentials =
      assume_role_credentials(role, "session-del", %{
        "DurationSeconds" => "900",
        "Policy" => session_policy
      })

    assert signed_s3(:put, "/#{bucket}", credentials).status == 200
    assert signed_s3(:put, "/#{bucket}/keep.txt", credentials, body: "keep").status == 200

    delete_body = ~s(<Delete><Object><Key>keep.txt</Key></Object></Delete>)

    denied_delete =
      signed_s3(:post, "/#{bucket}", credentials,
        query: %{"delete" => ""},
        body: delete_body
      )

    assert denied_delete.status == 200
    assert denied_delete.resp_body =~ "AccessDenied"

    still_there = SigV4Request.signed_conn(:get, "/#{bucket}/keep.txt") |> call()
    assert still_there.status == 200
    assert still_there.resp_body == "keep"
  end

  test "GetCallerIdentity returns assumed-role identity for role session credentials" do
    {:ok, role} = create_trusted_role("identity-role")

    credentials =
      signed_assume_role_conn(role, "identity-session", %{"DurationSeconds" => "900"})
      |> call()
      |> then(&credentials_from(&1.resp_body))

    response =
      signed_sts_conn(%{"Action" => "GetCallerIdentity"},
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert response.status == 200
    assert xml_value(response.resp_body, "UserId") == "#{role.id}:identity-session"
    assert xml_value(response.resp_body, "Account") == @account_id
    assert xml_value(response.resp_body, "Arn") == assumed_role_arn(role, "identity-session")
  end

  test "AssumeRole account-principal trust requires caller identity policy" do
    {:ok, caller} =
      IAM.create_access_key(
        access_key_id: unique_access_key("ACCOUNTTRUST"),
        secret_key: "issuer-secret"
      )

    {:ok, account_role} =
      create_role("account-principal-role", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => IAM.root_principal_arn()},
          "Action" => "sts:AssumeRole"
        }
      })

    denied =
      signed_assume_role_conn(account_role, "account-principal", %{"DurationSeconds" => "900"},
        access_key: caller.access_key_id,
        secret: caller.secret_key
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "Caller is not authorized to assume"

    assume_policy =
      policy_doc(allow_statement("sts:AssumeRole", account_role.role_arn))

    assert :ok =
             IAM.put_principal_policy(caller.principal_arn, "assume-account-role", assume_policy)

    allowed =
      signed_assume_role_conn(account_role, "account-principal", %{"DurationSeconds" => "900"},
        access_key: caller.access_key_id,
        secret: caller.secret_key
      )
      |> call()

    assert allowed.status == 200
    assert allowed.resp_body =~ "<AssumeRoleResponse"
  end

  test "AssumeRole direct same-account principal trust does not require caller identity policy" do
    {:ok, caller} =
      IAM.create_access_key(
        access_key_id: unique_access_key("DIRECTTRUST"),
        secret_key: "issuer-secret"
      )

    {:ok, role} =
      create_role("direct-principal-role", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => caller.principal_arn},
          "Action" => "sts:AssumeRole"
        }
      })

    response =
      signed_assume_role_conn(role, "direct-principal", %{"DurationSeconds" => "900"},
        access_key: caller.access_key_id,
        secret: caller.secret_key
      )
      |> call()

    assert response.status == 200
    assert response.resp_body =~ "<AssumeRoleResponse"
  end

  test "AssumeRole session tags require caller TagSession identity policy" do
    {:ok, caller} =
      IAM.create_access_key(
        access_key_id: unique_access_key("TAGCALLER"),
        secret_key: "issuer-secret"
      )

    {:ok, role} =
      create_role("caller-tag-session-role", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => IAM.root_principal_arn()},
          "Action" => ["sts:AssumeRole", "sts:TagSession"]
        }
      })

    assume_policy = policy_doc(allow_statement("sts:AssumeRole", role.role_arn))
    assert :ok = IAM.put_principal_policy(caller.principal_arn, "assume-role", assume_policy)

    denied =
      signed_assume_role_conn(
        role,
        "caller-tag-session",
        %{
          "DurationSeconds" => "900",
          "Tags.member.1.Key" => "team",
          "Tags.member.1.Value" => "platform"
        },
        access_key: caller.access_key_id,
        secret: caller.secret_key
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "Caller is not authorized to tag"

    tag_policy = policy_doc(allow_statement("sts:TagSession", role.role_arn))
    assert :ok = IAM.put_principal_policy(caller.principal_arn, "tag-session", tag_policy)

    allowed =
      signed_assume_role_conn(
        role,
        "caller-tag-session",
        %{
          "DurationSeconds" => "900",
          "Tags.member.1.Key" => "team",
          "Tags.member.1.Value" => "platform"
        },
        access_key: caller.access_key_id,
        secret: caller.secret_key
      )
      |> call()

    assert allowed.status == 200
    credentials = credentials_from(allowed.resp_body)
    persisted = Repo.get_by!(STSSession, access_key_id: credentials.access_key)
    assert persisted.tags["team"] == "platform"
  end

  test "POST form AssumeRole returns role credentials" do
    {:ok, role} = create_trusted_role("post-role")

    response =
      signed_assume_role_form_conn(role, "post-session")
      |> call()

    assert response.status == 200
    assert response.resp_body =~ "<AssumeRoleResponse"
    assert credentials_from(response.resp_body).session_token != ""
  end

  test "AssumeRole trust policy deny does not issue credentials" do
    {:ok, role} =
      create_role("denied-role", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => "arn:aws:iam:::user/not-root"},
          "Action" => "sts:AssumeRole"
        }
      })

    before_count = Repo.aggregate(STSSession, :count)

    response =
      signed_assume_role_conn(role, "denied-session")
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    assert Repo.aggregate(STSSession, :count) == before_count
  end

  test "AssumeRole evaluates RoleSessionName trust condition" do
    {:ok, role} =
      create_role("condition-role", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => IAM.root_principal_arn()},
          "Action" => "sts:AssumeRole",
          "Condition" => %{"StringEquals" => %{"sts:RoleSessionName" => "allowed"}}
        }
      })

    denied =
      signed_assume_role_conn(role, "blocked")
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    allowed =
      signed_assume_role_conn(role, "allowed")
      |> call()

    assert allowed.status == 200
    assert allowed.resp_body =~ "<AssumeRoleResponse"
  end

  test "AssumeRole evaluates ExternalId trust condition" do
    {:ok, role} =
      create_role("external-role", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => IAM.root_principal_arn()},
          "Action" => "sts:AssumeRole",
          "Condition" => %{"StringEquals" => %{"sts:ExternalId" => "tenant-123"}}
        }
      })

    denied =
      signed_assume_role_conn(role, "external-session", %{"ExternalId" => "tenant-456"})
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    allowed =
      signed_assume_role_conn(role, "external-session", %{"ExternalId" => "tenant-123"})
      |> call()

    assert allowed.status == 200
    assert allowed.resp_body =~ "<AssumeRoleResponse"
  end

  test "AssumeRole evaluates SourceIdentity trust condition and returns it" do
    {:ok, role} =
      create_role("source-role", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => IAM.root_principal_arn()},
          "Action" => ["sts:AssumeRole", "sts:SetSourceIdentity"],
          "Condition" => %{"StringEquals" => %{"sts:SourceIdentity" => "build-user"}}
        }
      })

    denied =
      signed_assume_role_conn(role, "source-session", %{"SourceIdentity" => "other-user"})
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    allowed =
      signed_assume_role_conn(role, "source-session", %{"SourceIdentity" => "build-user"})
      |> call()

    assert allowed.status == 200
    assert allowed.resp_body =~ "<SourceIdentity>build-user</SourceIdentity>"
  end

  test "AssumeRole requires sts SetSourceIdentity trust action when SourceIdentity is set" do
    {:ok, role} =
      create_role("source-action-role", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => IAM.root_principal_arn()},
          "Action" => "sts:AssumeRole",
          "Condition" => %{"StringEquals" => %{"sts:SourceIdentity" => "build-user"}}
        }
      })

    before_count = Repo.aggregate(STSSession, :count)

    response =
      signed_assume_role_conn(role, "source-action-session", %{
        "SourceIdentity" => "build-user"
      })
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    assert response.resp_body =~ "Cannot set SourceIdentity"
    assert Repo.aggregate(STSSession, :count) == before_count
  end

  test "AssumeRole requires sts TagSession trust action when session tags are set" do
    {:ok, role} =
      create_role("tag-action-role", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => IAM.root_principal_arn()},
          "Action" => "sts:AssumeRole"
        }
      })

    before_count = Repo.aggregate(STSSession, :count)

    response =
      signed_assume_role_conn(role, "tag-action-session", %{
        "Tags.member.1.Key" => "team",
        "Tags.member.1.Value" => "platform"
      })
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    assert response.resp_body =~ "Cannot tag the requested role session"
    assert Repo.aggregate(STSSession, :count) == before_count
  end

  test "AssumeRole session tags override role tags and reach S3 PrincipalTag authorization" do
    bucket = unique_bucket("session-tags")
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("session-tag-role"),
        tags: %{"team" => "role-team", "project" => "storage"},
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => IAM.root_principal_arn()},
            "Action" => ["sts:AssumeRole", "sts:TagSession"],
            "Condition" => %{
              "StringEquals" => %{
                "aws:RequestTag/team" => "platform",
                "aws:ResourceTag/project" => "storage"
              },
              "ForAllValues:StringEquals" => %{"aws:TagKeys" => ["team"]}
            }
          }
        }
      )

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::#{bucket}/*","Condition":{"StringEquals":{"aws:PrincipalTag/team":"platform","aws:PrincipalTag/project":"storage"}}}})

    assert :ok = IAM.put_principal_policy(role.role_arn, "tagged-put", policy)

    response =
      signed_assume_role_conn(role, "tagged-session", %{
        "Tags.member.1.Key" => "team",
        "Tags.member.1.Value" => "platform"
      })
      |> call()

    assert response.status == 200
    credentials = credentials_from(response.resp_body)

    persisted = Repo.get_by!(STSSession, access_key_id: credentials.access_key)
    assert persisted.tags == %{"project" => "storage", "team" => "platform"}

    allowed =
      SigV4Request.signed_conn(:put, "/#{bucket}/allowed.txt",
        body: "tagged",
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert allowed.status == 200
  end

  test "AssumeRole transitive session tags persist through role chaining and S3 authorization" do
    bucket = unique_bucket("transitive-tags")
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    {:ok, source_role} =
      IAM.create_role(
        role_name: unique_role("transitive-source"),
        tags: %{"role-only" => "source-role-tag"},
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => IAM.root_principal_arn()},
            "Action" => ["sts:AssumeRole", "sts:TagSession"],
            "Condition" => %{
              "StringEquals" => %{
                "aws:RequestTag/team" => "platform",
                "sts:TransitiveTagKeys" => "team"
              },
              "ForAllValues:StringEquals" => %{"aws:TagKeys" => ["team"]}
            }
          }
        }
      )

    {:ok, target_role} =
      IAM.create_role(
        role_name: unique_role("transitive-target"),
        tags: %{"team" => "target-role-tag"},
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => source_role.role_arn},
            "Action" => ["sts:AssumeRole", "sts:TagSession"],
            "Condition" => %{
              "StringEquals" => %{
                "aws:PrincipalTag/team" => "platform",
                "sts:TransitiveTagKeys" => "team"
              }
            }
          }
        }
      )

    target_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::#{bucket}/*","Condition":{"StringEquals":{"aws:PrincipalTag/team":"platform"}}}})

    assert :ok = IAM.put_principal_policy(target_role.role_arn, "transitive-put", target_policy)

    assert :ok =
             IAM.put_principal_policy(
               source_role.role_arn,
               "tag-target-session",
               policy_doc(allow_statement("sts:TagSession", target_role.role_arn))
             )

    source_response =
      signed_assume_role_conn(source_role, "source-transitive", %{
        "DurationSeconds" => "900",
        "Tags.member.1.Key" => "team",
        "Tags.member.1.Value" => "platform",
        "TransitiveTagKeys.member.1" => "team"
      })
      |> call()

    assert source_response.status == 200
    source_credentials = credentials_from(source_response.resp_body)
    source_session = Repo.get_by!(STSSession, access_key_id: source_credentials.access_key)
    assert source_session.tags["team"] == "platform"
    assert source_session.tags["role-only"] == "source-role-tag"
    assert source_session.transitive_tag_keys == ["team"]

    chained_response =
      signed_assume_role_conn(target_role, "target-transitive", %{"DurationSeconds" => "900"},
        access_key: source_credentials.access_key,
        secret: source_credentials.secret_key,
        session_token: source_credentials.session_token
      )
      |> call()

    assert chained_response.status == 200
    chained_credentials = credentials_from(chained_response.resp_body)
    chained_session = Repo.get_by!(STSSession, access_key_id: chained_credentials.access_key)
    assert chained_session.tags["team"] == "platform"
    refute Map.has_key?(chained_session.tags, "role-only")
    assert chained_session.transitive_tag_keys == ["team"]

    allowed =
      SigV4Request.signed_conn(:put, "/#{bucket}/allowed.txt",
        body: "transitive",
        access_key: chained_credentials.access_key,
        secret: chained_credentials.secret_key,
        session_token: chained_credentials.session_token
      )
      |> call()

    assert allowed.status == 200

    before_collision = Repo.aggregate(STSSession, :count)

    collision =
      signed_assume_role_conn(
        target_role,
        "target-conflict",
        %{
          "DurationSeconds" => "900",
          "Tags.member.1.Key" => "team",
          "Tags.member.1.Value" => "security"
        },
        access_key: source_credentials.access_key,
        secret: source_credentials.secret_key,
        session_token: source_credentials.session_token
      )
      |> call()

    assert collision.status == 400
    assert collision.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert collision.resp_body =~ "inherited transitive"
    assert Repo.aggregate(STSSession, :count) == before_collision
  end

  test "assumed role S3 authorization can use aws SourceIdentity" do
    bucket = unique_bucket("sourceid")
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    {:ok, role} =
      create_role("sourceid-role", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => IAM.root_principal_arn()},
          "Action" => ["sts:AssumeRole", "sts:SetSourceIdentity"]
        }
      })

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::#{bucket}/*","Condition":{"StringEquals":{"aws:SourceIdentity":"pipeline"}}}})

    assert :ok = IAM.put_principal_policy(role.role_arn, "sourceid-put", policy)

    without_source =
      signed_assume_role_conn(role, "without-source")
      |> call()
      |> then(&credentials_from(&1.resp_body))

    denied =
      SigV4Request.signed_conn(:put, "/#{bucket}/denied.txt",
        body: "denied",
        access_key: without_source.access_key,
        secret: without_source.secret_key,
        session_token: without_source.session_token
      )
      |> call()

    assert denied.status == 403

    with_source =
      signed_assume_role_conn(role, "with-source", %{"SourceIdentity" => "pipeline"})
      |> call()
      |> then(&credentials_from(&1.resp_body))

    allowed =
      SigV4Request.signed_conn(:put, "/#{bucket}/allowed.txt",
        body: "allowed",
        access_key: with_source.access_key,
        secret: with_source.secret_key,
        session_token: with_source.session_token
      )
      |> call()

    assert allowed.status == 200
  end

  test "AssumeRole evaluates MFA trust condition and consumes TOTP code" do
    {:ok, role} =
      create_role("mfa-role", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => IAM.root_principal_arn()},
          "Action" => "sts:AssumeRole",
          "Condition" => %{"Bool" => %{"aws:MultiFactorAuthPresent" => "true"}}
        }
      })

    denied =
      signed_assume_role_conn(role, "mfa-session")
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    {serial, token_code} = active_mfa_code("assume")

    allowed =
      signed_assume_role_conn(role, "mfa-session", %{
        "SerialNumber" => serial,
        "TokenCode" => token_code
      })
      |> call()

    assert allowed.status == 200
    assert allowed.resp_body =~ "<AssumeRoleResponse"

    before_replay = Repo.aggregate(STSSession, :count)

    replay =
      signed_assume_role_conn(role, "mfa-replay", %{
        "SerialNumber" => serial,
        "TokenCode" => token_code
      })
      |> call()

    assert replay.status == 403
    assert replay.resp_body =~ "<Code>AccessDenied</Code>"
    assert Repo.aggregate(STSSession, :count) == before_replay
  end

  test "AssumeRole MFA context is not exposed to later S3 authorization" do
    bucket = unique_bucket("mfaauthz")
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    {:ok, role} = create_trusted_role("mfaauthz-role")

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::#{bucket}/open/*"},{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::#{bucket}/protected/*","Condition":{"Bool":{"aws:MultiFactorAuthPresent":"true"}}}]})

    assert :ok = IAM.put_principal_policy(role.role_arn, "mfa-put", policy)

    without_mfa =
      signed_assume_role_conn(role, "without-mfa")
      |> call()
      |> then(&credentials_from(&1.resp_body))

    denied =
      SigV4Request.signed_conn(:put, "/#{bucket}/denied.txt",
        body: "denied",
        access_key: without_mfa.access_key,
        secret: without_mfa.secret_key,
        session_token: without_mfa.session_token
      )
      |> call()

    assert denied.status == 403

    {serial, token_code} = active_mfa_code("authz")

    with_mfa =
      signed_assume_role_conn(role, "with-mfa", %{
        "SerialNumber" => serial,
        "TokenCode" => token_code
      })
      |> call()
      |> then(&credentials_from(&1.resp_body))

    persisted = Repo.get_by!(STSSession, access_key_id: with_mfa.access_key)
    assert persisted.mfa_authenticated == true
    assert is_binary(persisted.mfa_serial_hash)

    still_denied =
      SigV4Request.signed_conn(:put, "/#{bucket}/protected/still-denied.txt",
        body: "still-denied",
        access_key: with_mfa.access_key,
        secret: with_mfa.secret_key,
        session_token: with_mfa.session_token
      )
      |> call()

    assert still_denied.status == 403

    allowed =
      SigV4Request.signed_conn(:put, "/#{bucket}/open/allowed.txt",
        body: "allowed",
        access_key: with_mfa.access_key,
        secret: with_mfa.secret_key,
        session_token: with_mfa.session_token
      )
      |> call()

    assert allowed.status == 200
  end

  test "AssumeRole trust policy accepts STS action wildcards" do
    {:ok, role} =
      create_role("wildcard-role", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => IAM.root_principal_arn()},
          "Action" => "sts:*"
        }
      })

    response =
      signed_assume_role_conn(role, "wildcard-session")
      |> call()

    assert response.status == 200
    assert response.resp_body =~ "<AssumeRoleResponse"
  end

  test "AssumeRole rejects deferred high-risk parameters before issuing credentials" do
    {:ok, role} = create_trusted_role("deferred-role")

    for deferred <- [
          "PolicyArns",
          "Tags",
          "Tags.member.1.Bad",
          "TransitiveTagKeys",
          "ProvidedContexts",
          "ProvidedContexts.member.1.ProviderArn",
          "UnexpectedParameter"
        ] do
      before_count = Repo.aggregate(STSSession, :count)

      response =
        signed_assume_role_conn(role, "deferred", %{deferred => "{}"})
        |> call()

      assert response.status == 400
      assert response.resp_body =~ "<Code>InvalidParameterValue</Code>"
      assert response.resp_body =~ "not implemented for AssumeRole"
      assert Repo.aggregate(STSSession, :count) == before_count
    end
  end

  test "AssumeRole rejects invalid or missing PolicyArns without issuing credentials" do
    {:ok, role} = create_trusted_role("bad-policy-arns")

    invalid_params = [
      %{"PolicyArns.member.0.arn" => managed_policy_arn("bad-index")},
      %{"PolicyArns.member.1.arn" => "arn:aws:s3:::not-iam-policy"},
      %{"PolicyArns.member.1.arn" => "arn:aws:iam::123456789012:policy/cross-account"},
      %{"PolicyArns.member.1.arn" => managed_policy_arn("missing")}
    ]

    for params <- invalid_params do
      before_count = Repo.aggregate(STSSession, :count)

      response =
        signed_assume_role_conn(role, "bad-policy-arns", params)
        |> call()

      assert response.status == 400
      assert response.resp_body =~ "<Code>"
      assert Repo.aggregate(STSSession, :count) == before_count
    end
  end

  test "AssumeRole rejects more than ten PolicyArns without issuing credentials" do
    {:ok, role} = create_trusted_role("too-many-policy-arns")

    managed_policy =
      policy_doc(allow_statement("s3:GetObject", "arn:aws:s3:::too-many/*"))

    params =
      Map.new(1..11, fn index ->
        policy_arn = managed_policy_arn("too-many-#{index}")
        assert :ok = Maxio.Policy.Store.put_managed_session_policy(policy_arn, managed_policy)
        {"PolicyArns.member.#{index}.arn", policy_arn}
      end)

    before_count = Repo.aggregate(STSSession, :count)

    response =
      signed_assume_role_conn(role, "too-many-policy-arns", params)
      |> call()

    assert response.status == 400
    assert response.resp_body =~ "<Code>MalformedPolicyDocument</Code>"
    assert Repo.aggregate(STSSession, :count) == before_count
  end

  test "AssumeRole rejects malformed inline session policies without issuing credentials" do
    {:ok, role} = create_trusted_role("malformed-session-policy")

    malformed_policies = [
      "{",
      Jason.encode!(%{"Version" => "2012-10-17", "Statement" => []}),
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => "*",
          "Action" => "s3:GetObject",
          "Resource" => "*"
        }
      }),
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Action" => "s3:GetObject"
        }
      }),
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Sid" => String.duplicate("A", 2_050),
          "Effect" => "Allow",
          "Action" => "s3:GetObject",
          "Resource" => "*"
        }
      })
    ]

    for policy <- malformed_policies do
      before_count = Repo.aggregate(STSSession, :count)

      response =
        signed_assume_role_conn(role, "malformed-session-policy", %{"Policy" => policy})
        |> call()

      assert response.status == 400
      assert response.resp_body =~ "<Code>MalformedPolicyDocument</Code>"
      assert Repo.aggregate(STSSession, :count) == before_count
    end
  end

  test "AssumeRole rejects invalid ExternalId SourceIdentity and partial MFA parameters" do
    {:ok, role} = create_trusted_role("invalid-context-role")

    for {param, message} <- [
          {%{"ExternalId" => "x"}, "ExternalId"},
          {%{"SourceIdentity" => "aws:reserved"}, "SourceIdentity"},
          {%{"TransitiveTagKeys.member.1" => "team"}, "TransitiveTagKeys"},
          {%{"TransitiveTagKeys.member.0" => "team"}, "TransitiveTagKeys"},
          {%{
             "Tags.member.1.Key" => "team",
             "Tags.member.1.Value" => "platform",
             "TransitiveTagKeys.member.1" => "project"
           }, "TransitiveTagKeys"},
          {%{"SerialNumber" => "arn:aws:iam:::mfa/root"}, "TokenCode"},
          {%{"TokenCode" => "123456"}, "SerialNumber"},
          {%{"SerialNumber" => "arn:aws:iam:::mfa/root", "TokenCode" => "abcdef"}, "TokenCode"}
        ] do
      before_count = Repo.aggregate(STSSession, :count)

      response =
        signed_assume_role_conn(role, "invalid-context", param)
        |> call()

      assert response.status == 400
      assert response.resp_body =~ "<Code>InvalidParameterValue</Code>"
      assert response.resp_body =~ message
      assert Repo.aggregate(STSSession, :count) == before_count
    end
  end

  test "GetSessionToken temporary credentials can call AssumeRole" do
    credentials =
      signed_sts_conn(%{"DurationSeconds" => "900"})
      |> call()
      |> then(&credentials_from(&1.resp_body))

    {:ok, role} = create_trusted_role("chain-role")

    response =
      signed_assume_role_conn(role, "chain-session", %{},
        access_key: credentials.access_key,
        secret: credentials.secret_key,
        session_token: credentials.session_token
      )
      |> call()

    assert response.status == 200
    assert response.resp_body =~ "<AssumeRoleResponse"
    assert credentials_from(response.resp_body).session_token != ""
    assert Repo.aggregate(STSSession, :count) == 2
  end

  test "AssumeRole role chaining inherits SourceIdentity and caps duration at one hour" do
    bucket = unique_bucket("chain-policy")
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    {:ok, source_role} =
      create_role("chain-source", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => IAM.root_principal_arn()},
          "Action" => ["sts:AssumeRole", "sts:SetSourceIdentity"]
        }
      })

    {:ok, target_role} =
      create_role("chain-target", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => source_role.role_arn},
          "Action" => ["sts:AssumeRole", "sts:SetSourceIdentity"],
          "Condition" => %{"StringEquals" => %{"sts:SourceIdentity" => "pipeline"}}
        }
      })

    source_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::#{bucket}/source-only/*"}})

    target_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::#{bucket}/target-only/*"}})

    assert :ok = IAM.put_principal_policy(source_role.role_arn, "source-only", source_policy)
    assert :ok = IAM.put_principal_policy(target_role.role_arn, "target-only", target_policy)

    source_credentials =
      signed_assume_role_conn(source_role, "source-session", %{
        "DurationSeconds" => "900",
        "SourceIdentity" => "pipeline"
      })
      |> call()
      |> then(&credentials_from(&1.resp_body))

    before_chained = Repo.aggregate(STSSession, :count)

    denied_chained =
      signed_assume_role_conn(target_role, "target-session", %{"DurationSeconds" => "900"},
        access_key: source_credentials.access_key,
        secret: source_credentials.secret_key,
        session_token: source_credentials.session_token
      )
      |> call()

    assert denied_chained.status == 403
    assert denied_chained.resp_body =~ "Caller is not authorized to set SourceIdentity"
    assert Repo.aggregate(STSSession, :count) == before_chained

    set_source_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"sts:SetSourceIdentity","Resource":"#{target_role.role_arn}"}})

    assert :ok =
             IAM.put_principal_policy(
               source_role.role_arn,
               "set-source-target",
               set_source_policy
             )

    chained =
      signed_assume_role_conn(target_role, "target-session", %{"DurationSeconds" => "900"},
        access_key: source_credentials.access_key,
        secret: source_credentials.secret_key,
        session_token: source_credentials.session_token
      )
      |> call()

    assert chained.status == 200
    assert chained.resp_body =~ "<SourceIdentity>pipeline</SourceIdentity>"

    chained_credentials = credentials_from(chained.resp_body)
    persisted = Repo.get_by!(STSSession, access_key_id: chained_credentials.access_key)
    assert persisted.issuer_access_key_id == source_credentials.access_key
    assert persisted.source_identity == "pipeline"
    assert persisted.principal_arn == target_role.role_arn

    source_only_denied =
      SigV4Request.signed_conn(:put, "/#{bucket}/source-only/denied.txt",
        body: "denied",
        access_key: chained_credentials.access_key,
        secret: chained_credentials.secret_key,
        session_token: chained_credentials.session_token
      )
      |> call()

    assert source_only_denied.status == 403

    target_only_allowed =
      SigV4Request.signed_conn(:put, "/#{bucket}/target-only/allowed.txt",
        body: "allowed",
        access_key: chained_credentials.access_key,
        secret: chained_credentials.secret_key,
        session_token: chained_credentials.session_token
      )
      |> call()

    assert target_only_allowed.status == 200

    before_rejected = Repo.aggregate(STSSession, :count)

    too_long =
      signed_assume_role_conn(target_role, "too-long", %{"DurationSeconds" => "3601"},
        access_key: source_credentials.access_key,
        secret: source_credentials.secret_key,
        session_token: source_credentials.session_token
      )
      |> call()

    assert too_long.status == 400
    assert too_long.resp_body =~ "<Code>InvalidParameterValue</Code>"

    changed_source =
      signed_assume_role_conn(target_role, "changed-source", %{"SourceIdentity" => "other"},
        access_key: source_credentials.access_key,
        secret: source_credentials.secret_key,
        session_token: source_credentials.session_token
      )
      |> call()

    assert changed_source.status == 400
    assert changed_source.resp_body =~ "SourceIdentity cannot be changed"
    assert Repo.aggregate(STSSession, :count) == before_rejected
  end

  test "AssumeRole role chaining requires SetSourceIdentity when identity is inherited" do
    {:ok, source_role} =
      create_role("chain-source-no-set-target", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => IAM.root_principal_arn()},
          "Action" => ["sts:AssumeRole", "sts:SetSourceIdentity"]
        }
      })

    {:ok, target_role} =
      create_role("chain-target-no-set", %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => source_role.role_arn},
          "Action" => "sts:AssumeRole",
          "Condition" => %{"StringEquals" => %{"sts:SourceIdentity" => "pipeline"}}
        }
      })

    source_credentials =
      signed_assume_role_conn(source_role, "source-session", %{
        "DurationSeconds" => "900",
        "SourceIdentity" => "pipeline"
      })
      |> call()
      |> then(&credentials_from(&1.resp_body))

    before_count = Repo.aggregate(STSSession, :count)

    response =
      signed_assume_role_conn(target_role, "target-session", %{"DurationSeconds" => "900"},
        access_key: source_credentials.access_key,
        secret: source_credentials.secret_key,
        session_token: source_credentials.session_token
      )
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    assert response.resp_body =~ "Cannot set SourceIdentity"
    assert Repo.aggregate(STSSession, :count) == before_count
  end

  test "STS-scoped GET without action returns STS error instead of S3 fallback" do
    response =
      SigV4Request.signed_conn(:get, "/", service: "sts")
      |> call()

    assert response.status == 400
    assert response.resp_body =~ "<Code>InvalidAction</Code>"
    refute response.resp_body =~ "<ListAllMyBucketsResult"
  end

  test "POST form rejects unsigned payload mode" do
    before_count = Repo.aggregate(STSSession, :count)

    response =
      SigV4Request.signed_conn(:post, "/",
        body: form_body(%{"DurationSeconds" => "900"}),
        content_sha256_override: "UNSIGNED-PAYLOAD",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        service: "sts"
      )
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    assert response.resp_body =~ "exact payload hash"
    assert Repo.aggregate(STSSession, :count) == before_count
  end

  test "presigned POST form is rejected" do
    before_count = Repo.aggregate(STSSession, :count)

    response =
      SigV4Request.presigned_conn(:post, "/", service: "sts")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    assert response.resp_body =~ "header SigV4"
    assert Repo.aggregate(STSSession, :count) == before_count
  end

  test "POST form content-type is required for sts scoped requests" do
    before_count = Repo.aggregate(STSSession, :count)

    missing =
      SigV4Request.signed_conn(:post, "/",
        body: form_body(%{"DurationSeconds" => "900"}),
        service: "sts"
      )
      |> call()

    assert missing.status == 400
    assert missing.resp_body =~ "<ErrorResponse"
    assert missing.resp_body =~ "<Code>InvalidRequest</Code>"

    wrong =
      SigV4Request.signed_conn(:post, "/",
        body: form_body(%{"DurationSeconds" => "900"}),
        headers: [{"content-type", "application/json"}],
        service: "sts"
      )
      |> call()

    assert wrong.status == 400
    assert wrong.resp_body =~ "<ErrorResponse"
    assert wrong.resp_body =~ "<Code>InvalidRequest</Code>"
    assert Repo.aggregate(STSSession, :count) == before_count
  end

  test "oversized POST form body is rejected before issuing credentials" do
    before_count = Repo.aggregate(STSSession, :count)
    large_body = "Action=GetSessionToken&Version=2011-06-15&Pad=" <> String.duplicate("a", 65_536)

    response =
      SigV4Request.signed_conn(:post, "/",
        body: large_body,
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        service: "sts"
      )
      |> call()

    assert response.status == 400
    assert response.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert response.resp_body =~ "too large"
    assert Repo.aggregate(STSSession, :count) == before_count
  end

  test "missing POST form action returns STS error instead of S3 fallback" do
    response =
      SigV4Request.signed_conn(:post, "/",
        body: URI.encode_query(%{"Version" => "2011-06-15"}),
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        service: "sts"
      )
      |> call()

    assert response.status == 400
    assert response.resp_body =~ "<Code>InvalidAction</Code>"
    refute response.resp_body =~ "<Code>MethodNotAllowed</Code>"
  end

  test "POST form repeated parameters are rejected before issuing credentials" do
    before_count = Repo.aggregate(STSSession, :count)

    response =
      SigV4Request.signed_conn(:post, "/",
        body: "Action=GetSessionToken&Action=AssumeRole&Version=2011-06-15",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        service: "sts"
      )
      |> call()

    assert response.status == 400
    assert response.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert response.resp_body =~ "must not be repeated"
    assert Repo.aggregate(STSSession, :count) == before_count
  end

  defp signed_sts_conn(extra_query, opts \\ []) do
    sign_opts =
      opts
      |> Keyword.put(:query, base_query(extra_query))
      |> Keyword.put(:service, "sts")

    SigV4Request.signed_conn(:get, "/", sign_opts)
  end

  defp signed_sts_form_conn(extra_form, opts \\ []) do
    sign_opts =
      opts
      |> Keyword.put(:body, form_body(extra_form))
      |> Keyword.put(:headers, [
        {"content-type", "application/x-www-form-urlencoded; charset=utf-8"}
      ])
      |> Keyword.put(:service, "sts")

    SigV4Request.signed_conn(:post, "/", sign_opts)
  end

  defp signed_assume_role_conn(role, session_name, extra_query \\ %{}, opts \\ []) do
    sign_opts =
      opts
      |> Keyword.put(:query, assume_role_query(role, session_name, extra_query))
      |> Keyword.put(:service, "sts")

    SigV4Request.signed_conn(:get, "/", sign_opts)
  end

  defp signed_assume_role_form_conn(role, session_name, extra_form \\ %{}, opts \\ []) do
    sign_opts =
      opts
      |> Keyword.put(
        :body,
        assume_role_query(role, session_name, extra_form) |> URI.encode_query()
      )
      |> Keyword.put(:headers, [
        {"content-type", "application/x-www-form-urlencoded; charset=utf-8"}
      ])
      |> Keyword.put(:service, "sts")

    SigV4Request.signed_conn(:post, "/", sign_opts)
  end

  defp base_query(extra \\ %{}) do
    Map.merge(%{"Action" => "GetSessionToken", "Version" => "2011-06-15"}, extra)
  end

  defp form_body(extra), do: base_query(extra) |> URI.encode_query()

  defp assume_role_query(role, session_name, extra) do
    Map.merge(
      %{
        "Action" => "AssumeRole",
        "Version" => "2011-06-15",
        "RoleArn" => role.role_arn,
        "RoleSessionName" => session_name
      },
      extra
    )
  end

  defp create_trusted_role(prefix) do
    create_role(prefix, %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Principal" => %{"AWS" => IAM.root_principal_arn()},
        "Action" => "sts:AssumeRole"
      }
    })
  end

  defp create_role(prefix, trust_policy) do
    IAM.create_role(
      role_name: unique_role(prefix),
      trust_policy: trust_policy
    )
  end

  defp active_mfa_code(prefix, principal_arn \\ IAM.root_principal_arn()) do
    serial = "arn:aws:iam:::mfa/#{unique_role(prefix)}"
    device_name = unique_role("#{prefix}-device")

    assert {:ok, enrolled} =
             IAM.create_mfa_device(
               device_name: device_name,
               serial: serial,
               principal_arn: principal_arn
             )

    activation_time = DateTime.add(DateTime.utc_now(), -120, :second)
    assert {:ok, activation_code} = TOTP.code(enrolled.secret_base32, time: activation_time)

    assert {:ok, _device} =
             IAM.activate_mfa_device(serial, activation_code, time: activation_time)

    assert {:ok, token_code} = TOTP.code(enrolled.secret_base32, time: DateTime.utc_now())
    {serial, token_code}
  end

  defp assumed_role_arn(role, session_name) do
    "arn:aws:sts:::assumed-role/#{role.role_name}/#{session_name}"
  end

  defp managed_policy_arn(name), do: "arn:aws:iam:::policy/#{unique_role(name)}"

  defp assume_role_credentials(role, session_name, extra_query) do
    response =
      signed_assume_role_conn(role, session_name, extra_query)
      |> call()

    assert response.status == 200
    credentials_from(response.resp_body)
  end

  defp signed_s3(method, path, credentials, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:access_key, credentials.access_key)
      |> Keyword.put(:secret, credentials.secret_key)
      |> Keyword.put(:session_token, credentials.session_token)

    method
    |> SigV4Request.signed_conn(path, opts)
    |> call()
  end

  defp policy_doc(statement_or_statements) do
    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => statement_or_statements
    })
  end

  defp allow_statement(actions, resources) do
    %{
      "Effect" => "Allow",
      "Action" => actions,
      "Resource" => resources
    }
  end

  defp credentials_from(xml) do
    %{
      access_key: xml_value(xml, "AccessKeyId"),
      secret_key: xml_value(xml, "SecretAccessKey"),
      session_token: xml_value(xml, "SessionToken")
    }
  end

  defp xml_value(xml, tag) do
    regex = ~r/<#{tag}>([^<]+)<\/#{tag}>/
    [_, value] = Regex.run(regex, xml)
    value
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp unique_bucket(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp unique_access_key(prefix), do: "AKIA#{prefix}#{System.unique_integer([:positive])}"
  defp unique_role(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
