defmodule Maxio.Admin.UserEndpointTest do
  use Maxio.DataCase, async: false

  alias Maxio.Auth.CredentialStore
  alias Maxio.IAM
  alias Maxio.Policy.{Statement, Store}
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @base "/minio/admin/v3"
  @path "#{@base}/user-info"

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

  test "anonymous U3 is denied before endpoint disclosure" do
    conn =
      :get
      |> SigV4Request.anon_conn(@path <> "?accessKey=alice")
      |> Endpoint.call(Endpoint.init([]))

    assert_admin_error(conn, 403, "AccessDenied")
  end

  test "authenticated U1 U2 U4 and U5 remain explicit JSON 501" do
    for {method, path, query} <- [
          {:put, "#{@base}/add-user", %{"accessKey" => "alice"}},
          {:get, "#{@base}/list-users", %{}},
          {:get, "#{@base}/list-users", %{"bucket" => ""}},
          {:delete, "#{@base}/remove-user", %{"accessKey" => "alice"}},
          {:put, "#{@base}/set-user-status", %{"accessKey" => "alice", "status" => "enabled"}}
        ] do
      conn = signed(method, path, query: query, region: "")
      assert_admin_error(conn, 501, "NotImplemented")
      assert content_type(conn) =~ "application/json"
    end
  end

  defp signed(method, path, opts) do
    method
    |> SigV4Request.signed_conn(path, opts)
    |> Endpoint.call(Endpoint.init([]))
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

  defp assert_admin_error(conn, status, code) do
    assert conn.status == status
    assert Jason.decode!(conn.resp_body)["Code"] == code
  end

  defp content_type(conn) do
    conn |> Plug.Conn.get_resp_header("content-type") |> List.first() || ""
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
