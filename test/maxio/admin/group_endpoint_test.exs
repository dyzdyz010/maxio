defmodule Maxio.Admin.GroupEndpointTest do
  use Maxio.DataCase, async: false

  alias Maxio.Auth.CredentialStore
  alias Maxio.IAM
  alias Maxio.IAM.STSSession
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
    assert content_type(list) == "application/json"
    assert content_length(list) == byte_size(list.resp_body)
    assert group_name in Jason.decode!(list.resp_body)

    info = signed(:get, "#{@base}/group", query: %{"group" => group_name}, region: "")

    expected =
      ~s({"name":"#{group_name}","status":"enabled","members":["#{user_name}"],"policy":"","updatedAt":"#{DateTime.to_iso8601(created.updated_at)}"})

    assert info.status == 200
    assert content_type(info) == "application/json"
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

  test "authorization denial does not read any G3 body bytes" do
    {key, secret} = put_action_key(nil)
    body = ~s({"group":"never-read","members":[],"isRemove":false})

    conn =
      SigV4Request.signed_conn(:put, "#{@base}/update-group-members",
        body: body,
        headers: [{"content-length", Integer.to_string(byte_size(body))}],
        access_key: key,
        secret: secret,
        region: ""
      )

    {_adapter, state} = conn.adapter
    conn = %{conn | adapter: {Maxio.Test.BodyReadProbeAdapter, {self(), state}}}
    conn = Endpoint.call(conn, Endpoint.init([]))

    assert_admin_error(conn, 403, "AccessDenied")
    refute_received :body_reader_called
  end

  test "G3 treats a user ARN as an absent MinIO username without mutation" do
    suffix = System.unique_integer([:positive, :monotonic])
    group_name = "arn-member-#{suffix}"
    user_name = "arn-user-#{suffix}"
    assert {:ok, _user} = IAM.create_user(name: user_name)

    body =
      Jason.encode!(%{
        "group" => group_name,
        "members" => [IAM.user_arn(user_name)],
        "isRemove" => false
      })

    response = signed_body(:put, "#{@base}/update-group-members", body)
    assert_admin_error(response, 404, "XMinioAdminNoSuchUser")

    assert Jason.decode!(response.resp_body)["Message"] ==
             "The specified user does not exist. (Specified user does not exist)"

    assert :error = IAM.get_group(group_name)

    assert {:ok, original_group} = IAM.create_group(name: group_name)

    remove_body =
      Jason.encode!(%{
        "group" => group_name,
        "members" => [IAM.user_arn(user_name)],
        "isRemove" => true
      })

    remove_response = signed_body(:put, "#{@base}/update-group-members", remove_body)
    assert_admin_error(remove_response, 404, "XMinioAdminNoSuchUser")
    assert {:ok, same_group} = IAM.get_group(group_name)
    assert same_group.id == original_group.id
    assert IAM.list_users_in_group(group_name) == []
  end

  test "G3 ARN batches retain empty-group and forbidden-member precedence" do
    suffix = System.unique_integer([:positive, :monotonic])
    root = Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)
    temp_access_key = create_temporary_session!()
    user_name = "precedence-user-#{suffix}"
    assert {:ok, _user} = IAM.create_user(name: user_name)
    user_arn = IAM.user_arn(user_name)

    empty_remove =
      Jason.encode!(%{"group" => "", "members" => [user_arn], "isRemove" => true})

    assert_admin_error(
      signed_body(:put, "#{@base}/update-group-members", empty_remove),
      400,
      "XMinioAdminInvalidArgument"
    )

    for forbidden <- [root, temp_access_key],
        {remove?, order} <- [
          {false, [forbidden, user_arn]},
          {false, [user_arn, forbidden]},
          {true, [forbidden, user_arn]},
          {true, [user_arn, forbidden]}
        ] do
      group_name = "precedence-#{remove?}-#{forbidden}-#{suffix}"
      body = Jason.encode!(%{"group" => group_name, "members" => order, "isRemove" => remove?})
      response = signed_body(:put, "#{@base}/update-group-members", body)
      assert_admin_error(response, 403, "XMinioIAMActionNotAllowed")
      assert :error = IAM.get_group(group_name)
    end
  end

  test "a user delete-recreate generation race returns signed NoSuchUser" do
    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    group_name = "endpoint-user-generation-group-#{suffix}"
    user_name = "endpoint-user-generation-user-#{suffix}"

    on_exit(fn ->
      unboxed(fn ->
        :ok = IAM.delete_group(group_name)
        :ok = IAM.delete_user(user_name)
      end)
    end)

    unboxed(fn ->
      assert {:ok, _group} = IAM.create_group(name: group_name)
      assert {:ok, _user} = IAM.create_user(name: user_name)
    end)

    body =
      Jason.encode!(%{"group" => group_name, "members" => [user_name], "isRemove" => false})

    barrier = Maxio.Test.IAMIdentityBarrier.attach(:user, user_name)

    task =
      Task.async(fn ->
        unboxed(fn -> signed_body(:put, "#{@base}/update-group-members", body) end)
      end)

    assert_receive {:iam_identity_wait, ^barrier, task_pid}, 5_000
    Maxio.Test.IAMIdentityBarrier.detach(barrier)

    unboxed(fn ->
      assert {:ok, _deleted} = IAM.delete_user_strict(user_name)
      assert {:ok, _replacement} = IAM.create_user(name: user_name)
    end)

    send(task_pid, {:release_iam_identity, barrier})
    response = Task.await(task, 10_000)

    assert_admin_error(response, 404, "XMinioAdminNoSuchUser")

    assert Jason.decode!(response.resp_body)["Message"] ==
             "The specified user does not exist. (Specified user does not exist)"

    assert unboxed(fn -> IAM.list_users_in_group(group_name) end) == []
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
             "The specified group is not empty - cannot remove it. " <>
               "(Specified group is not empty - cannot remove it)"

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

    missing_group =
      signed(:get, "#{@base}/group", query: %{"group" => "missing#{suffix}"}, region: "")

    assert_admin_error(missing_group, 404, "XMinioAdminNoSuchGroup")

    assert Jason.decode!(missing_group.resp_body)["Message"] ==
             "The specified group does not exist. (Specified group does not exist)"
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

  defp create_temporary_session! do
    suffix = System.unique_integer([:positive, :monotonic])
    access_key_id = "temp-group-precedence-#{suffix}"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %STSSession{}
    |> STSSession.changeset(%{
      access_key_id: access_key_id,
      secret_key: "encrypted-test-secret",
      session_token_sha256: String.duplicate("0", 64),
      issuer_access_key_id: Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user),
      principal_arn: IAM.root_principal_arn(),
      principal_type: "root",
      session_name: "group-precedence-#{suffix}",
      issued_at: now,
      expires_at: DateTime.add(now, 3_600, :second)
    })
    |> Repo.insert!()

    access_key_id
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
