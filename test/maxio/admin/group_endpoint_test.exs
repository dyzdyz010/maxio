defmodule Maxio.Admin.GroupEndpointTest do
  use Maxio.DataCase, async: false

  alias Maxio.Auth.CredentialStore
  alias Maxio.IAM
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @base "/minio/admin/v3"

  test "root exposes exact G1/G2 plaintext JSON framing" do
    suffix = System.unique_integer([:positive, :monotonic])
    group_name = "g#{suffix}"
    user_name = "member#{suffix}"
    assert {:ok, _} = IAM.create_user(name: user_name)

    assert {:ok, created} =
             IAM.update_minio_group_members_strict(group_name, [user_name], false, "")

    list = signed(:get, "#{@base}/groups", region: "")
    assert list.status == 200
    assert content_type(list) =~ "application/json"
    assert content_length(list) == byte_size(list.resp_body)
    assert group_name in Jason.decode!(list.resp_body)

    info = signed(:get, "#{@base}/group", query: %{"group" => group_name}, region: "")

    expected =
      ~s({"name":"#{group_name}","status":"enabled","members":["#{user_name}"],"policy":"","updatedAt":"#{DateTime.to_iso8601(created.updated_at)}"})

    assert info.status == 200
    assert content_type(info) =~ "application/json"
    assert content_length(info) == byte_size(expected)
    assert info.resp_body == expected
  end

  test "G3 creates/adds/removes/deletes atomically and G4 ignores its body" do
    suffix = System.unique_integer([:positive, :monotonic])
    group_name = "mutate#{suffix}"
    user_name = "member#{suffix}"
    assert {:ok, _} = IAM.create_user(name: user_name)

    add_body =
      Jason.encode!(%{
        "group" => group_name,
        "members" => [user_name],
        "groupStatus" => "ignored",
        "isRemove" => false
      })

    added = signed_body(:put, "#{@base}/update-group-members", add_body)
    assert added.status == 200
    assert added.resp_body == ""
    assert content_type(added) == ""

    disabled =
      signed_body(:put, "#{@base}/set-group-status", <<0, 1, 2>>,
        query: %{"group" => group_name, "status" => "disabled"}
      )

    assert disabled.status == 200
    assert disabled.resp_body == ""
    assert content_type(disabled) == ""
    assert {:ok, %{status: "inactive"}} = IAM.get_group(group_name)

    remove_body =
      Jason.encode!(%{
        "group" => group_name,
        "members" => [user_name],
        "groupStatus" => "",
        "isRemove" => true
      })

    assert signed_body(:put, "#{@base}/update-group-members", remove_body).status == 200

    delete_body =
      Jason.encode!(%{
        "group" => group_name,
        "members" => [],
        "groupStatus" => "",
        "isRemove" => true
      })

    assert signed_body(:put, "#{@base}/update-group-members", delete_body).status == 200
    assert :error = IAM.get_group(group_name)
  end

  test "four endpoints use exact actions, including remove and disable" do
    cases = [
      {"admin:ListGroups",
       fn key, secret, _suffix ->
         signed(:get, "#{@base}/groups", access_key: key, secret: secret, region: "")
       end},
      {"admin:GetGroup",
       fn key, secret, suffix ->
         group_name = "info#{suffix}"
         assert {:ok, _} = IAM.create_group(name: group_name)

         signed(:get, "#{@base}/group",
           query: %{"group" => group_name},
           access_key: key,
           secret: secret,
           region: ""
         )
       end},
      {"admin:AddUserToGroup",
       fn key, secret, suffix ->
         body =
           Jason.encode!(%{"group" => "missing#{suffix}", "members" => [], "isRemove" => true})

         signed_body(:put, "#{@base}/update-group-members", body, access_key: key, secret: secret)
       end},
      {"admin:EnableGroup",
       fn key, secret, suffix ->
         group_name = "status#{suffix}"
         assert {:ok, _} = IAM.create_group(name: group_name)

         signed(:put, "#{@base}/set-group-status",
           query: %{"group" => group_name, "status" => "disabled"},
           access_key: key,
           secret: secret,
           region: ""
         )
       end}
    ]

    for {action, request} <- cases do
      {key, secret} = put_action_key(action)
      assert request.(key, secret, System.unique_integer([:positive])).status in [200, 404]

      {wrong_key, wrong_secret} = put_action_key("admin:ServerInfo")

      assert_admin_error(
        request.(wrong_key, wrong_secret, System.unique_integer([:positive])),
        403,
        "AccessDenied"
      )
    end
  end

  test "authorization precedes query and body classification" do
    {key, secret} = put_action_key(nil)

    denied =
      signed_body(:put, "#{@base}/update-group-members", "not-json",
        access_key: key,
        secret: secret
      )

    assert_admin_error(denied, 403, "AccessDenied")

    authorized = signed_body(:put, "#{@base}/update-group-members", "not-json")
    assert_admin_error(authorized, 400, "XMinioAdminConfigBadJSON")

    missing = signed(:get, "#{@base}/group", region: "")
    assert_admin_error(missing, 400, "XMinioAdminInvalidArgument")
  end

  test "frozen group errors preserve status code message and precedence" do
    suffix = System.unique_integer([:positive, :monotonic])
    group_name = "nonempty#{suffix}"
    user_name = "member#{suffix}"
    assert {:ok, _} = IAM.create_user(name: user_name)
    assert {:ok, _} = IAM.update_minio_group_members_strict(group_name, [user_name], false, "")

    nonempty = Jason.encode!(%{"group" => group_name, "members" => [], "isRemove" => true})
    response = signed_body(:put, "#{@base}/update-group-members", nonempty)
    assert_admin_error(response, 400, "XMinioAdminGroupNotEmpty")

    assert Jason.decode!(response.resp_body)["Message"] ==
             "The specified group is not empty - cannot remove it."

    invalid_status =
      signed(:put, "#{@base}/set-group-status",
        query: %{"group" => "missing#{suffix}", "status" => "paused"},
        region: ""
      )

    assert_admin_error(invalid_status, 400, "XMinioAdminInvalidArgument")

    missing_user =
      Jason.encode!(%{
        "group" => "missing#{suffix}",
        "members" => ["absent#{suffix}"],
        "isRemove" => true
      })

    assert_admin_error(
      signed_body(:put, "#{@base}/update-group-members", missing_user),
      404,
      "XMinioAdminNoSuchUser"
    )
  end

  test "wrong methods versions and adjacent paths remain authenticated JSON 501" do
    paths = [
      {:post, "#{@base}/groups"},
      {:get, "/minio/admin/v4/groups"},
      {:get, "#{@base}/groups/extra"}
    ]

    for {method, path} <- paths do
      assert_admin_error(signed(method, path, region: ""), 501, "NotImplemented")
    end
  end

  defp signed(method, path, opts) do
    method
    |> SigV4Request.signed_conn(path, opts)
    |> Endpoint.call(Endpoint.init([]))
  end

  defp signed_body(method, path, body, opts \\ []) do
    headers = [
      {"content-length", Integer.to_string(byte_size(body))} | Keyword.get(opts, :headers, [])
    ]

    signed(method, path, Keyword.merge(opts, body: body, headers: headers, region: ""))
  end

  defp put_action_key(action) do
    suffix = System.unique_integer([:positive, :monotonic])
    key = String.pad_trailing("AKIAGR#{suffix}", 20, "X")
    secret = "admin-group-secret-#{suffix}-long-enough"
    arn = IAM.user_arn(key)
    assert {:ok, _} = IAM.create_user(name: key)

    :ok =
      CredentialStore.put_access_key(%{
        access_key: key,
        secret_key: secret,
        principal: %{type: :iam_user, access_key: key, arn: arn}
      })

    if action do
      :ok =
        Store.put_principal_policy(
          arn,
          "group-action-#{suffix}",
          Jason.encode!(%{
            "Version" => "2012-10-17",
            "Statement" => %{"Effect" => "Allow", "Action" => action}
          })
        )
    end

    {key, secret}
  end

  defp assert_admin_error(conn, status, code) do
    assert conn.status == status
    assert Jason.decode!(conn.resp_body)["Code"] == code
  end

  defp content_type(conn),
    do: conn |> Plug.Conn.get_resp_header("content-type") |> List.first() || ""

  defp content_length(conn) do
    conn |> Plug.Conn.get_resp_header("content-length") |> List.first() |> String.to_integer()
  end
end
