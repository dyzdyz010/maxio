defmodule Maxio.Admin.PolicyEndpointTest do
  use Maxio.DataCase, async: false

  alias Maxio.Admin.PolicyAdapter
  alias Maxio.Auth.CredentialStore
  alias Maxio.IAM
  alias Maxio.Policy.Store, as: PolicyStore
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @base "/minio/admin/v3"

  test "root completes create/list/v2-info/legacy-info/remove with strict 200 responses" do
    name = unique_name("mc-policy")
    body = policy_json("s3:GetObject")

    created =
      signed(:put, "#{@base}/add-canned-policy",
        query: %{"name" => name},
        body: body,
        headers: [{"content-length", Integer.to_string(byte_size(body))}],
        region: ""
      )

    assert Plug.Conn.get_req_header(created, "content-type") == []
    assert created.status == 200
    assert created.resp_body == ""

    listed = signed(:get, "#{@base}/list-canned-policies", region: "")
    assert listed.status == 200
    assert is_map(Jason.decode!(listed.resp_body)[name])

    v2 =
      signed(:get, "#{@base}/info-canned-policy",
        query: %{"name" => name, "v" => "2"},
        region: ""
      )

    assert v2.status == 200

    assert %{
             "PolicyName" => ^name,
             "Policy" => %{},
             "CreateDate" => _,
             "UpdateDate" => _
           } = Jason.decode!(v2.resp_body)

    legacy =
      signed(:get, "#{@base}/info-canned-policy",
        query: %{"name" => name},
        region: ""
      )

    assert legacy.status == 200
    legacy_body = Jason.decode!(legacy.resp_body)
    refute Map.has_key?(legacy_body, "PolicyName")
    assert get_in(legacy_body, ["Statement", "Action"]) == "s3:GetObject"

    removed =
      signed(:delete, "#{@base}/remove-canned-policy",
        query: %{"name" => name},
        region: ""
      )

    assert removed.status == 200
    assert removed.resp_body == ""
  end

  test "list and info preserve the exact madmin JSON shapes" do
    name = unique_name("wire-shape")
    body = policy_json("s3:GetObject")
    assert {:ok, _policy} = PolicyAdapter.create(name, body)

    listed = signed(:get, "#{@base}/list-canned-policies", region: "")
    listed_body = Jason.decode!(listed.resp_body)
    assert is_map(listed_body[name])
    refute is_binary(listed_body[name])

    v2 =
      signed(:get, "#{@base}/info-canned-policy",
        query: %{"name" => name, "v" => "2"},
        region: ""
      )

    v2_body = Jason.decode!(v2.resp_body)

    assert Map.keys(v2_body) |> Enum.sort() ==
             ["CreateDate", "Policy", "PolicyName", "UpdateDate"]

    assert v2_body["PolicyName"] == name
    assert is_map(v2_body["Policy"])

    for query <- [%{"name" => name}, %{"name" => name, "v" => ""}] do
      legacy = signed(:get, "#{@base}/info-canned-policy", query: query, region: "")
      assert legacy.status == 200
      assert Jason.decode!(legacy.resp_body) == Jason.decode!(body)
    end
  end

  test "unsupported info versions fail explicitly instead of falling back to legacy" do
    name = unique_name("bad-version")
    assert {:ok, _policy} = PolicyAdapter.create(name, policy_json("s3:GetObject"))

    for version <- ["1", "3", "abc"] do
      conn =
        signed(:get, "#{@base}/info-canned-policy",
          query: %{"name" => name, "v" => version},
          region: ""
        )

      assert_admin_error(conn, 400, "XMinioAdminInvalidArgument")
    end
  end

  test "missing and empty names are invalid arguments" do
    body = policy_json("s3:GetObject")

    for query <- [%{}, %{"name" => ""}] do
      create =
        signed(:put, "#{@base}/add-canned-policy",
          query: query,
          body: body,
          headers: [{"content-length", Integer.to_string(byte_size(body))}],
          region: ""
        )

      assert_admin_error(create, 400, "XMinioAdminInvalidArgument")

      info = signed(:get, "#{@base}/info-canned-policy", query: query, region: "")
      assert_admin_error(info, 400, "XMinioAdminInvalidArgument")

      remove = signed(:delete, "#{@base}/remove-canned-policy", query: query, region: "")
      assert_admin_error(remove, 400, "XMinioAdminInvalidArgument")
    end
  end

  test "unsafe policy names are rejected before IAM lookup" do
    # SigV4Request intentionally preserves raw '+' query semantics, so use
    # percent-encoded whitespace variants here; the adapter unit test covers
    # literal leading/trailing ASCII spaces as well.
    for name <- ["\tpolicy", "policy\t", "\u00A0policy", "a,b", "a/b", "a\\b", ".", ".."] do
      conn =
        signed(:get, "#{@base}/info-canned-policy",
          query: %{"name" => name, "v" => "2"},
          region: ""
        )

      assert_admin_error(conn, 400, "XMinioInvalidResource")
    end
  end

  test "unknown policies return the admin no-such-policy contract" do
    name = unique_name("missing")

    info = signed(:get, "#{@base}/info-canned-policy", query: %{"name" => name}, region: "")
    assert_admin_error(info, 404, "XMinioAdminNoSuchPolicy")

    remove =
      signed(:delete, "#{@base}/remove-canned-policy", query: %{"name" => name}, region: "")

    assert_admin_error(remove, 404, "XMinioAdminNoSuchPolicy")
  end

  test "malformed policy JSON returns MalformedPolicy" do
    body = "{"

    conn =
      signed(:put, "#{@base}/add-canned-policy",
        query: %{"name" => unique_name("malformed")},
        body: body,
        headers: [{"content-length", Integer.to_string(byte_size(body))}],
        region: ""
      )

    assert_admin_error(conn, 400, "MalformedPolicy")
  end

  test "managed policy document quota returns 400 and persists nothing below the wire limit" do
    name = unique_name("document-quota")

    body =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Action" => "s3:GetObject",
          "Resource" => for(index <- 1..220, do: "arn:aws:s3:::policy-quota-#{index}/*")
        }
      })

    assert String.length(body) > 6_144
    assert byte_size(body) < 20_480

    conn =
      signed(:put, "#{@base}/add-canned-policy",
        query: %{"name" => name},
        body: body,
        headers: [{"content-length", Integer.to_string(byte_size(body))}],
        region: ""
      )

    assert_admin_error(conn, 400, "XMinioAdminInvalidArgument")
    assert :error = IAM.get_managed_policy(IAM.managed_policy_arn(name, "/"))
  end

  test "create requires one positive Content-Length and rejects transfer encoding" do
    name = unique_name("framing")

    missing =
      signed(:put, "#{@base}/add-canned-policy",
        query: %{"name" => name},
        body: "{}",
        region: ""
      )

    assert_admin_error(missing, 411, "MissingContentLength")

    zero =
      signed(:put, "#{@base}/add-canned-policy",
        query: %{"name" => name},
        headers: [{"content-length", "0"}],
        region: ""
      )

    assert_admin_error(zero, 411, "MissingContentLength")

    chunked =
      signed(:put, "#{@base}/add-canned-policy",
        query: %{"name" => name},
        body: "{}",
        headers: [{"content-length", "2"}, {"transfer-encoding", "chunked"}],
        region: ""
      )

    assert_admin_error(chunked, 411, "MissingContentLength")
  end

  test "anonymous policy route is 403 before route disclosure" do
    conn =
      :get
      |> SigV4Request.anon_conn("#{@base}/list-canned-policies")
      |> Endpoint.call(Endpoint.init([]))

    assert_admin_error(conn, 403, "AccessDenied")
  end

  test "authenticated bucket variant remains explicit 501" do
    conn =
      signed(:get, "#{@base}/list-canned-policies",
        query: %{"bucket" => ""},
        region: ""
      )

    assert_admin_error(conn, 501, "NotImplemented")
  end

  test "authorization denial occurs before create body reading" do
    {access_key, secret, _arn} = put_action_key("admin:GetPolicy")
    body = policy_json("s3:GetObject")

    conn =
      SigV4Request.signed_conn(:put, "#{@base}/add-canned-policy",
        query: %{"name" => unique_name("deny-no-read")},
        body: body,
        headers: [{"content-length", Integer.to_string(byte_size(body))}],
        access_key: access_key,
        secret: secret,
        region: ""
      )

    {_adapter, state} = conn.adapter
    conn = %{conn | adapter: {Maxio.Test.BodyReadProbeAdapter, {self(), state}}}
    conn = Endpoint.call(conn, Endpoint.init([]))

    assert_admin_error(conn, 403, "AccessDenied")
    refute_received :body_reader_called
  end

  for {label, action, method, endpoint} <- [
        {"create", "admin:CreatePolicy", :put, "add-canned-policy"},
        {"list", "admin:ListUserPolicies", :get, "list-canned-policies"},
        {"info", "admin:GetPolicy", :get, "info-canned-policy"},
        {"remove", "admin:DeletePolicy", :delete, "remove-canned-policy"}
      ] do
    @label label
    @action action
    @method method
    @endpoint endpoint

    test "#{label} accepts its exact admin action and denies another S1 route" do
      name = unique_name("exact-#{@label}")
      body = policy_json("s3:GetObject")
      {access_key, secret, _arn} = put_action_key(@action)

      if @label in ["info", "remove"] do
        assert {:ok, _policy} = PolicyAdapter.create(name, body)
      end

      opts = action_request_opts(@label, name, body, access_key, secret)
      allowed = signed(@method, "#{@base}/#{@endpoint}", opts)
      assert allowed.status == 200

      denied =
        if @label == "list" do
          signed(:get, "#{@base}/info-canned-policy",
            query: %{"name" => name},
            access_key: access_key,
            secret: secret,
            region: ""
          )
        else
          signed(:get, "#{@base}/list-canned-policies",
            access_key: access_key,
            secret: secret,
            region: ""
          )
        end

      assert_admin_error(denied, 403, "AccessDenied")
    end
  end

  defp signed(method, path, opts) do
    method
    |> SigV4Request.signed_conn(path, opts)
    |> Endpoint.call(Endpoint.init([]))
  end

  defp action_request_opts("create", name, body, access_key, secret) do
    [
      query: %{"name" => name},
      body: body,
      headers: [{"content-length", Integer.to_string(byte_size(body))}],
      access_key: access_key,
      secret: secret,
      region: ""
    ]
  end

  defp action_request_opts("list", _name, _body, access_key, secret) do
    [access_key: access_key, secret: secret, region: ""]
  end

  defp action_request_opts(label, name, _body, access_key, secret)
       when label in ["info", "remove"] do
    [query: %{"name" => name}, access_key: access_key, secret: secret, region: ""]
  end

  defp put_action_key(action) do
    suffix = System.unique_integer([:positive, :monotonic])
    access_key = "AKIAADMINPOL#{suffix}"
    secret = "admin-policy-secret-#{suffix}-long-enough"
    arn = "arn:aws:iam:::user/#{access_key}"

    assert {:ok, _created} = IAM.create_minio_user_strict(access_key, secret, "active")
    _ = :sys.get_state(Maxio.Cluster.CacheInvalidator)

    :ok =
      CredentialStore.put_access_key(%{
        access_key: access_key,
        secret_key: secret,
        principal: %{type: :iam_user, access_key: access_key, arn: arn}
      })

    :ok =
      PolicyStore.put_principal_policy(
        arn,
        unique_name("action-policy"),
        Jason.encode!(%{
          "Version" => "2012-10-17",
          "Statement" => [%{"Effect" => "Allow", "Action" => action}]
        })
      )

    {access_key, secret, arn}
  end

  defp assert_admin_error(conn, status, code) do
    assert conn.status == status
    assert Jason.decode!(conn.resp_body)["Code"] == code
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp policy_json(action) do
    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Action" => action,
        "Resource" => "arn:aws:s3:::policy-endpoint-test/*"
      }
    })
  end
end
