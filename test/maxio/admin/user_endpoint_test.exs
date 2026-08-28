defmodule Maxio.Admin.UserEndpointTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maxio.Admin.Envelope
  alias Maxio.Auth.CredentialStore
  alias Maxio.Auth.CredentialStore.EctoStore
  alias Maxio.Auth.SigningSecret
  alias Maxio.IAM
  alias Maxio.Policy.{Statement, Store}
  alias Maxio.S3.Endpoint
  alias Maxio.STS
  alias Maxio.Test.SigV4Request

  @base "/minio/admin/v3"
  @path "#{@base}/user-info"
  @root_access_key "AKIAIOSFODNN7EXAMPLE"
  @root_secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

  test "root atomically adds a user and the persisted credential authenticates" do
    use_ecto_credentials!()
    access_key = unique_access_name("ADDROOT")
    new_secret = "new-root-created-secret"
    body = add_user_body(@root_secret, new_secret)

    conn = signed_body(:put, "#{@base}/add-user", body, query: %{"accessKey" => access_key})

    assert conn.status == 200
    assert conn.resp_body == ""
    assert {:ok, %{user_name: ^access_key}} = IAM.get_user(access_key)
    assert {:ok, %{secret_key: ^new_secret}} = EctoStore.get_secret(access_key)

    authenticated =
      signed(:get, @path,
        query: %{"accessKey" => access_key},
        access_key: access_key,
        secret: new_secret,
        region: ""
      )

    assert_admin_error(authenticated, 403, "AccessDenied")
  end

  test "root lists an encrypted exact UserInfo map that only its signing secret opens" do
    enabled = unique_access_name("LISTROOT")
    disabled = unique_access_name("LISTOFF")

    assert {:ok, %{user: enabled_user}} =
             IAM.create_minio_user_strict(enabled, "list-root-secret", "active")

    assert {:ok, disabled_user} = IAM.create_user(name: disabled, status: "inactive")

    conn = signed(:get, "#{@base}/list-users", region: "")

    assert conn.status == 200
    assert content_type(conn) =~ "application/json"
    refute String.starts_with?(conn.resp_body, "{")

    assert {:ok, plaintext} =
             Envelope.decrypt(SigningSecret.new(@root_secret), conn.resp_body)

    assert Jason.decode!(plaintext) == %{
             disabled => %{
               "status" => "disabled",
               "updatedAt" => DateTime.to_iso8601(disabled_user.updated_at)
             },
             enabled => %{
               "status" => "enabled",
               "updatedAt" => DateTime.to_iso8601(enabled_user.updated_at)
             }
           }

    assert {:error, :not_authentic} =
             Envelope.decrypt(SigningSecret.new("wrong-root-secret"), conn.resp_body)
  end

  test "a real STS signature binds the U2 envelope capability to the session secret" do
    use_ecto_credentials!()
    session_key = unique_access_name("LISTSTS")
    session_secret = "sts-envelope-session-secret"
    session_token = "sts-envelope-session-token"

    assert {:ok, session} =
             STS.issue_session(
               issuer_access_key_id: @root_access_key,
               session_access_key_id: session_key,
               secret_key: session_secret,
               session_token: session_token,
               duration_seconds: 900
             )

    conn =
      signed(:get, "#{@base}/list-users",
        access_key: session.access_key_id,
        secret: session_secret,
        session_token: session_token,
        region: ""
      )

    assert conn.status == 200
    assert {:ok, "{}"} = Envelope.decrypt(SigningSecret.new(session_secret), conn.resp_body)

    assert {:error, :not_authentic} =
             Envelope.decrypt(SigningSecret.new(@root_secret), conn.resp_body)

    assert {:error, :not_authentic} =
             Envelope.decrypt(SigningSecret.new("unrelated-secret"), conn.resp_body)
  end

  test "U1 and U2 require their exact identity actions" do
    for action <- ["admin:CreateUser", "admin:ListUsers"] do
      {access_key, secret, _arn} = put_action_key(action)
      allowed = action_request(action, access_key, secret, "allowed")
      assert allowed.status == 200

      wrong_action =
        if action == "admin:CreateUser", do: "admin:ListUsers", else: "admin:CreateUser"

      {wrong_key, wrong_secret, _arn} = put_action_key(wrong_action)

      assert_admin_error(
        action_request(action, wrong_key, wrong_secret, "wrong"),
        403,
        "AccessDenied"
      )
    end
  end

  test "explicit deny, STS policy boundary, and bucket policy cannot grant U1 or U2" do
    for action <- ["admin:CreateUser", "admin:ListUsers"] do
      {deny_key, deny_secret, _arn} =
        put_action_key([
          %{"Effect" => "Allow", "Action" => action},
          %{"Effect" => "Deny", "Action" => action}
        ])

      assert_admin_error(
        action_request(action, deny_key, deny_secret, "deny"),
        403,
        "AccessDenied"
      )

      {:ok, boundary} =
        Statement.parse_identity_policy(
          Jason.encode!(%{
            "Version" => "2012-10-17",
            "Statement" => %{
              "Effect" => "Allow",
              "Action" => "s3:GetObject",
              "Resource" => "arn:aws:s3:::session-boundary/*"
            }
          })
        )

      {session_key, session_secret, _arn} =
        put_action_key(action, principal_extra: %{session_policy_statements: boundary})

      assert_admin_error(
        action_request(action, session_key, session_secret, "session"),
        403,
        "AccessDenied"
      )

      {bucket_key, bucket_secret, bucket_arn} = put_action_key(nil)

      :ok =
        Store.put_bucket_policy(
          unique_name("admin-user-bucket"),
          Jason.encode!(%{
            "Version" => "2012-10-17",
            "Statement" => %{
              "Effect" => "Allow",
              "Principal" => %{"AWS" => bucket_arn},
              "Action" => action,
              "Resource" => "arn:aws:s3:::*"
            }
          })
        )

      assert_admin_error(
        action_request(action, bucket_key, bucket_secret, "bucket"),
        403,
        "AccessDenied"
      )
    end
  end

  test "ciphertext hash mismatch wins before decrypt and IAM mutation" do
    access_key = unique_access_name("HASHFAIL")
    new_secret = "hash-failure-new-secret"
    body = add_user_body(@root_secret, new_secret)

    conn =
      signed_body(:put, "#{@base}/add-user", body,
        query: %{"accessKey" => access_key},
        content_sha256_override: Maxio.Auth.SigV4.Signer.hex_sha256("different-ciphertext")
      )

    assert_admin_error(conn, 400, "XAmzContentSHA256Mismatch")
    assert :error = IAM.get_user(access_key)
    assert :error = EctoStore.get_secret(access_key)

    invalid_body = <<0>>

    invalid =
      signed_body(:put, "#{@base}/add-user", invalid_body,
        query: %{"accessKey" => unique_access_name("HASHFIRST")},
        content_sha256_override: Maxio.Auth.SigV4.Signer.hex_sha256("different-ciphertext")
      )

    assert_admin_error(invalid, 400, "XAmzContentSHA256Mismatch")
  end

  test "duplicate U1 leaves the original credential unchanged and redacts all evidence" do
    access_key = unique_access_name("DUPUSER")
    original_secret = "original-user-secret"
    replacement_secret = "replacement-user-secret"
    original_body = add_user_body(@root_secret, original_secret)
    replacement_body = add_user_body(@root_secret, replacement_secret)

    replacement_plaintext =
      Jason.encode!(%{"secretKey" => replacement_secret, "status" => "enabled"})

    owner = self()

    assert signed_body(:put, "#{@base}/add-user", original_body,
             query: %{"accessKey" => access_key}
           ).status == 200

    log =
      capture_log(fn ->
        conn =
          signed_body(:put, "#{@base}/add-user", replacement_body,
            query: %{"accessKey" => access_key}
          )

        send(owner, {:duplicate_response, conn})
      end)

    assert_receive {:duplicate_response, duplicate}
    assert_admin_error(duplicate, 400, "XMaxioAdminUserAlreadyExists")
    assert {:ok, %{secret_key: ^original_secret}} = EctoStore.get_secret(access_key)

    for forbidden <- [
          @root_secret,
          original_secret,
          replacement_secret,
          replacement_plaintext,
          binary_part(replacement_body, 0, 16),
          Base.encode16(binary_part(replacement_body, 0, 16))
        ] do
      refute duplicate.resp_body =~ forbidden
      refute log =~ forbidden
    end

    refute log =~ "bucket=minio"
  end

  test "root receives strict plaintext UserInfo with exact UTC and omit discipline" do
    name = unique_name("root-info")
    assert {:ok, user} = IAM.create_user(name: name, status: "active")

    conn = signed(:get, @path, query: %{"accessKey" => name}, region: "")

    assert conn.status == 200
    assert content_type(conn) =~ "application/json"

    assert %{
             "status" => "enabled",
             "updatedAt" => updated_at
           } = body = Jason.decode!(conn.resp_body)

    assert updated_at == DateTime.to_iso8601(user.updated_at)
    assert String.ends_with?(updated_at, "Z")
    assert Map.keys(body) |> Enum.sort() == ["status", "updatedAt"]
    refute Map.has_key?(body, "secretKey")
    refute Map.has_key?(body, "userAuthInfo")
    refute conn.resp_body =~ "<Error>"
  end

  test "only the exact admin:GetUser identity action authorizes a non-root caller" do
    target = create_user!("exact-target")
    {access_key, secret, _arn} = put_action_key("admin:GetUser")

    allowed =
      signed(:get, @path,
        query: %{"accessKey" => target.user_name},
        access_key: access_key,
        secret: secret,
        region: ""
      )

    assert allowed.status == 200

    denied_other_route =
      signed(:get, "#{@base}/list-canned-policies",
        access_key: access_key,
        secret: secret,
        region: ""
      )

    assert_admin_error(denied_other_route, 403, "AccessDenied")
  end

  test "implicit deny, explicit deny, and STS session boundary all remain fail-closed" do
    target = create_user!("deny-target")
    {implicit_key, implicit_secret, _arn} = put_action_key(nil)

    implicit =
      signed(:get, @path,
        query: %{"accessKey" => target.user_name},
        access_key: implicit_key,
        secret: implicit_secret,
        region: ""
      )

    assert_admin_error(implicit, 403, "AccessDenied")

    {deny_key, deny_secret, _arn} =
      put_action_key([
        %{"Effect" => "Allow", "Action" => "admin:GetUser"},
        %{"Effect" => "Deny", "Action" => "admin:GetUser"}
      ])

    explicit =
      signed(:get, @path,
        query: %{"accessKey" => target.user_name},
        access_key: deny_key,
        secret: deny_secret,
        region: ""
      )

    assert_admin_error(explicit, 403, "AccessDenied")

    {:ok, session_statements} =
      Statement.parse_identity_policy(
        Jason.encode!(%{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Action" => "s3:GetObject",
            "Resource" => "arn:aws:s3:::session-boundary/*"
          }
        })
      )

    {session_key, session_secret, _arn} =
      put_action_key("admin:GetUser",
        principal_extra: %{session_policy_statements: session_statements}
      )

    bounded =
      signed(:get, @path,
        query: %{"accessKey" => target.user_name},
        access_key: session_key,
        secret: session_secret,
        region: ""
      )

    assert_admin_error(bounded, 403, "AccessDenied")
  end

  test "bucket policy alone cannot grant the cluster admin action" do
    target = create_user!("bucket-target")
    {access_key, secret, arn} = put_action_key(nil)

    :ok =
      Store.put_bucket_policy(
        "admin-user-policy-bucket",
        Jason.encode!(%{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => arn},
            "Action" => "admin:GetUser",
            "Resource" => "arn:aws:s3:::*"
          }
        })
      )

    conn =
      signed(:get, @path,
        query: %{"accessKey" => target.user_name},
        access_key: access_key,
        secret: secret,
        region: ""
      )

    assert_admin_error(conn, 403, "AccessDenied")
  end

  test "self-read still needs a full identity allow under V-B17" do
    {access_key, secret, arn} = put_action_key(nil)
    assert {:ok, _user} = IAM.create_user(name: access_key)

    denied =
      signed(:get, @path,
        query: %{"accessKey" => access_key},
        access_key: access_key,
        secret: secret,
        region: ""
      )

    assert_admin_error(denied, 403, "AccessDenied")

    assert :ok =
             Store.put_principal_policy(
               arn,
               unique_name("self-read"),
               identity_policy("admin:GetUser")
             )

    allowed =
      signed(:get, @path,
        query: %{"accessKey" => access_key},
        access_key: access_key,
        secret: secret,
        region: ""
      )

    assert allowed.status == 200
    assert Jason.decode!(allowed.resp_body)["status"] == "enabled"
  end

  test "invalid names fail before lookup and valid absence has the exact user error" do
    for query <- [%{}, %{"accessKey" => ""}, %{"accessKey" => "team/alice"}] do
      conn = signed(:get, @path, query: query, region: "")
      assert_admin_error(conn, 400, "XMinioAdminInvalidArgument")
    end

    for name <- ["\u00A0alice", "alice\u3000", "ali,ce"] do
      conn = signed(:get, @path, query: %{"accessKey" => name}, region: "")
      assert_admin_error(conn, 400, "XMinioInvalidResource")
    end

    missing = signed(:get, @path, query: %{"accessKey" => unique_name("absent")}, region: "")
    assert_admin_error(missing, 404, "XMinioAdminNoSuchUser")
    assert Jason.decode!(missing.resp_body)["Message"] == "The specified user does not exist."
  end

  test "partial UserInfo logs only safe source counts and omission reasons" do
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)

    owner = self()
    user_name = unique_access_name("LOGUSER")
    assert {:ok, user} = IAM.create_user(name: user_name)
    secret = "endpoint-log-secret-long-enough"

    assert {:ok, _key} =
             IAM.create_access_key(
               access_key_id: user_name,
               secret_key: secret,
               user_name: user_name
             )

    direct_name = unique_name("log-direct")
    comma_name = unique_name("log-comma") <> ",omitted"
    inline_name = unique_name("log-inline")
    group_name = unique_name("log-group")
    group_inline_name = unique_name("log-group-inline")
    group_managed_name = unique_name("log-group-managed")
    role_managed_name = unique_name("log-role-managed")

    direct_arn = create_managed_policy!(direct_name)
    comma_arn = create_managed_policy!(comma_name)
    group_managed_arn = create_managed_policy!(group_managed_name)
    role_managed_arn = create_managed_policy!(role_managed_name)

    assert :ok = IAM.attach_user_policy(user_name, direct_arn)
    assert :ok = IAM.attach_user_policy(user_name, comma_arn)
    assert :ok = IAM.put_principal_policy(user.user_arn, inline_name, source_policy())
    assert {:ok, _group} = IAM.create_group(name: group_name)
    assert :ok = IAM.add_user_to_group(user_name, group_name)

    assert :ok =
             IAM.put_group_policy(group_name, group_inline_name, source_policy())

    assert :ok = IAM.attach_group_policy(group_name, group_managed_arn)
    assert {:ok, _role} = create_evidence_role(user.user_arn)
    assert :ok = Store.attach_role_managed_policy(user.user_arn, role_managed_arn)

    log =
      capture_log([level: :info], fn ->
        conn = signed(:get, @path, query: %{"accessKey" => user_name}, region: "")
        send(owner, {:logged_user_info, conn})
      end)

    assert_receive {:logged_user_info, conn}
    assert conn.status == 200
    assert log =~ "admin user info projected"
    assert log =~ "target_user=#{user_name}"
    assert log =~ "credential_bearing=true"
    assert log =~ "managed_policies=2"
    assert log =~ "inline_policies=1"
    assert log =~ "group_inherited=2"
    assert log =~ "role_attached=1"
    assert log =~ "minio_view_partial=true"

    for reason <- [
          "ambiguous_direct_managed_policy_name",
          "direct_inline_policy",
          "group_inline_policy",
          "group_managed_policy",
          "role_managed_policy"
        ] do
      assert log =~ reason
    end

    assert log =~ "ambiguous direct managed policy omitted from MinIO UserInfo"
    refute log =~ secret
    refute log =~ "Statement"
    refute log =~ "s3:GetObject"
  end

  test "anonymous U3 is denied before endpoint disclosure" do
    conn =
      :get
      |> SigV4Request.anon_conn(@path <> "?accessKey=alice")
      |> Endpoint.call(Endpoint.init([]))

    assert_admin_error(conn, 403, "AccessDenied")
  end

  test "add-user bucket variants authorize before JSON 501 without decrypting or mutating IAM" do
    for bucket <- ["", "bucket-a"] do
      target = unique_access_name("BUCKETROOT")

      root =
        signed_body(:put, "#{@base}/add-user", <<0>>,
          query: %{"accessKey" => target, "bucket" => bucket}
        )

      assert_admin_error(root, 501, "NotImplemented")
      assert :error = IAM.get_user(target)
      assert :error = EctoStore.get_secret(target)
    end

    {allowed_key, allowed_secret, _arn} = put_action_key("admin:CreateUser")
    allowed_target = unique_access_name("BUCKETALLOW")

    allowed =
      signed_body(:put, "#{@base}/add-user", <<0>>,
        query: %{"accessKey" => allowed_target, "bucket" => "bucket-b"},
        access_key: allowed_key,
        secret: allowed_secret
      )

    assert_admin_error(allowed, 501, "NotImplemented")
    assert :error = IAM.get_user(allowed_target)
    assert :error = EctoStore.get_secret(allowed_target)

    {denied_key, denied_secret, _arn} = put_action_key(nil)
    denied_target = unique_access_name("BUCKETDENY")

    denied =
      signed_body(:put, "#{@base}/add-user", <<0>>,
        query: %{"accessKey" => denied_target, "bucket" => "bucket-c"},
        access_key: denied_key,
        secret: denied_secret
      )

    assert_admin_error(denied, 403, "AccessDenied")
    assert :error = IAM.get_user(denied_target)
    assert :error = EctoStore.get_secret(denied_target)
  end

  test "list bucket variant authorizes first while U4 U5 and wrong routes remain JSON 501" do
    for {method, path, query} <- [
          {:get, "#{@base}/list-users", %{"bucket" => ""}},
          {:delete, "#{@base}/remove-user", %{"accessKey" => "alice"}},
          {:put, "#{@base}/set-user-status", %{"accessKey" => "alice", "status" => "enabled"}},
          {:post, "#{@base}/add-user", %{"accessKey" => "alice"}},
          {:get, "#{@base}/unknown-user-route", %{}}
        ] do
      conn = signed(method, path, query: query, region: "")
      assert_admin_error(conn, 501, "NotImplemented")
      assert content_type(conn) =~ "application/json"
    end

    {access_key, secret, _arn} = put_action_key(nil)

    denied =
      signed(:get, "#{@base}/list-users",
        query: %{"bucket" => "bucket-a"},
        access_key: access_key,
        secret: secret,
        region: ""
      )

    assert_admin_error(denied, 403, "AccessDenied")
  end

  defp signed(method, path, opts) do
    method
    |> SigV4Request.signed_conn(path, opts)
    |> Endpoint.call(Endpoint.init([]))
  end

  defp signed_body(method, path, body, opts) do
    headers =
      [{"content-length", Integer.to_string(byte_size(body))} | Keyword.get(opts, :headers, [])]

    signed(method, path, Keyword.merge(opts, body: body, headers: headers, region: ""))
  end

  defp add_user_body(signing_secret, new_secret) do
    plaintext = Jason.encode!(%{"secretKey" => new_secret, "status" => "enabled"})

    assert {:ok, body} =
             Envelope.encrypt(SigningSecret.new(signing_secret), plaintext,
               algorithm_id: 2,
               salt: :crypto.strong_rand_bytes(32),
               nonce: :crypto.strong_rand_bytes(8)
             )

    body
  end

  defp action_request("admin:CreateUser", access_key, secret, suffix) do
    target = unique_access_name("ACT#{suffix}")
    body = add_user_body(secret, "action-new-user-secret")

    signed_body(:put, "#{@base}/add-user", body,
      query: %{"accessKey" => target},
      access_key: access_key,
      secret: secret
    )
  end

  defp action_request("admin:ListUsers", access_key, secret, _suffix) do
    signed(:get, "#{@base}/list-users",
      access_key: access_key,
      secret: secret,
      region: ""
    )
  end

  defp use_ecto_credentials! do
    previous = Application.fetch_env!(:maxio, :credential_store)
    Application.put_env(:maxio, :credential_store, EctoStore)
    on_exit(fn -> Application.put_env(:maxio, :credential_store, previous) end)

    assert {:ok, _root} =
             IAM.create_access_key(
               access_key_id: @root_access_key,
               secret_key: @root_secret,
               type: "root",
               principal_arn: IAM.root_principal_arn()
             )

    :ok
  end

  defp put_action_key(action_or_statements, opts \\ []) do
    suffix = System.unique_integer([:positive, :monotonic])
    access_key = String.pad_trailing("AKIAADMINUSR#{suffix}", 20, "X")
    secret = "admin-user-secret-#{suffix}-long-enough"
    arn = IAM.user_arn(access_key)
    principal_extra = Keyword.get(opts, :principal_extra, %{})

    principal =
      Map.merge(%{type: :iam_user, access_key: access_key, arn: arn}, principal_extra)

    :ok =
      CredentialStore.put_access_key(%{
        access_key: access_key,
        secret_key: secret,
        principal: principal
      })

    if action_or_statements != nil do
      statements =
        case action_or_statements do
          action when is_binary(action) -> [%{"Effect" => "Allow", "Action" => action}]
          statements when is_list(statements) -> statements
        end

      :ok =
        Store.put_principal_policy(
          arn,
          unique_name("admin-user-action"),
          Jason.encode!(%{"Version" => "2012-10-17", "Statement" => statements})
        )
    end

    {access_key, secret, arn}
  end

  defp create_user!(prefix) do
    name = unique_name(prefix)
    assert {:ok, user} = IAM.create_user(name: name)
    user
  end

  defp identity_policy(action) do
    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => %{"Effect" => "Allow", "Action" => action}
    })
  end

  defp create_managed_policy!(name) do
    arn = IAM.managed_policy_arn(name, "/")

    assert {:ok, %{policy_arn: ^arn}} =
             IAM.create_managed_policy_strict(
               name: name,
               path: "/",
               document: source_policy()
             )

    arn
  end

  defp create_evidence_role(role_arn) do
    Maxio.Repo.insert(%Maxio.IAM.Role{
      role_name: unique_name("evidence-role"),
      role_arn: role_arn,
      trust_policy: %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Action" => "sts:AssumeRole",
          "Principal" => %{"AWS" => IAM.root_principal_arn()}
        }
      }
    })
  end

  defp source_policy do
    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Action" => "s3:GetObject",
        "Resource" => "arn:aws:s3:::admin-user-log/*"
      }
    })
  end

  defp assert_admin_error(conn, status, code) do
    assert conn.status == status
    assert Jason.decode!(conn.resp_body)["Code"] == code
  end

  defp content_type(conn) do
    conn |> Plug.Conn.get_resp_header("content-type") |> List.first() || ""
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp unique_access_name(prefix) do
    suffix = System.unique_integer([:positive, :monotonic])
    String.pad_trailing("AKIA#{prefix}#{suffix}", 20, "X")
  end
end
