defmodule Maxio.Admin.ConfigKVEndpointTest do
  use Maxio.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Plug.Conn

  alias Maxio.Admin.Envelope
  alias Maxio.Auth.{CredentialStore, SigningSecret}
  alias Maxio.Config.{RuntimeConfig, RuntimeConfigAudit}
  alias Maxio.Config.Store, as: ConfigStore
  alias Maxio.IAM
  alias Maxio.Policy.Statement
  alias Maxio.Policy.Store, as: PolicyStore
  alias Maxio.S3.Endpoint

  alias Maxio.Test.{
    ConfigBatchFailureRepo,
    ConfigKVApplyModeSchema,
    ConfigPostcommitNotify,
    ConfigPostcommitStore,
    SigV4Request
  }

  @base "/minio/admin/v3"
  @get_path "#{@base}/get-config-kv"
  @set_path "#{@base}/set-config-kv"
  @reset_path "#{@base}/del-config-kv"
  @help_path "#{@base}/help-config-kv"
  @root_secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

  @access_denied "Access Denied."
  @bad_json "JSON configuration provided is of incorrect format"
  @too_large "Configuration data provided exceeds the allowed maximum of 262272 bytes"
  @hash_mismatch "The provided 'x-amz-content-sha256' header does not match what was computed."

  @submitted_value "741852"
  @raw_command "listing sql_hard_limit=#{@submitted_value}"
  @caller_secret_sentinel "CONFIG-KV-CALLER-SECRET-SENTINEL"
  @recorder_reason_sentinel "CONFIG-KV-RECORDER-REASON-SENTINEL"

  setup do
    ConfigBatchFailureRepo.clear!()
    ConfigStore.reset_local!()

    on_exit(fn ->
      ConfigBatchFailureRepo.clear!()
      ConfigStore.reset_local!()
    end)

    :ok
  end

  test "the three exact signed routes expose the frozen request and response entity matrix" do
    # Catches a wrong method/path dispatch, JSON-helper mutation body, response chunking/default
    # content type, or a GET encrypted with anything other than the authenticated caller secret.
    {get_request, get_response} =
      signed_pair(:get, @get_path,
        query: %{"key" => "s3"},
        headers: [{"x-request-id", "req-config-get-entity"}],
        region: ""
      )

    assert_request_entity(get_request, nil, nil, "")
    assert get_response.status == 200

    assert_response_entity(
      get_response,
      Integer.to_string(byte_size(get_response.resp_body)),
      "application/json"
    )

    assert {:ok, "s3 clock_skew_ms=900000 \n"} = decrypt(get_response, @root_secret)

    set_body = encrypted!(@root_secret, "listing sql_hard_limit=424242")

    {set_request, set_response} =
      signed_pair(:put, @set_path,
        body: set_body,
        headers: [
          {"content-length", Integer.to_string(byte_size(set_body))},
          {"x-request-id", "req-config-set-entity"}
        ],
        region: ""
      )

    assert_request_entity(set_request, Integer.to_string(byte_size(set_body)), nil, set_body)
    assert_mutation_success(set_response, true)

    assert Repo.one(
             from row in RuntimeConfig,
               where: row.subsystem == "listing" and row.key == "sql_hard_limit",
               select: row.value
           ) == %{"v" => 424_242}

    reset_body = encrypted!(@root_secret, "listing sql_hard_limit")

    {reset_request, reset_response} =
      signed_pair(:delete, @reset_path,
        body: reset_body,
        headers: [
          {"content-length", Integer.to_string(byte_size(reset_body))},
          {"x-request-id", "req-config-reset-entity"}
        ],
        region: ""
      )

    assert_request_entity(
      reset_request,
      Integer.to_string(byte_size(reset_body)),
      nil,
      reset_body
    )

    assert_mutation_success(reset_response, true)

    assert Repo.aggregate(
             from(row in RuntimeConfig,
               where: row.subsystem == "listing" and row.key == "sql_hard_limit"
             ),
             :count
           ) == 0
  end

  test "mixed quote sanitization crosses the encrypted endpoint into a typed mutation" do
    # Catches a parser that removes only the outer double quotes and then rejects the remaining
    # single-quoted integer at the typed Config boundary.
    response = mutation(:put, @set_path, ~s(s3 clock_skew_ms="'900000'"))

    assert_mutation_success(response, true)

    assert Repo.one(
             from row in RuntimeConfig,
               where: row.subsystem == "s3" and row.key == "clock_skew_ms",
               select: row.value
           ) == %{"v" => 900_000}
  end

  test "encrypted overquoted integers are exact BadJSON without mutation" do
    # Catches encrypted HTTP input reaching trim-all sanitization and persisting a typed integer.
    # Both requests run before assertions so repeated double and single quote layers are covered.
    cases = [
      {~s(s3 clock_skew_ms=""900000""), "req-config-overquoted-double"},
      {"s3 clock_skew_ms=''900000''", "req-config-overquoted-single"}
    ]

    responses =
      Enum.map(cases, fn {plaintext, request_id} ->
        {request_id,
         mutation(:put, @set_path, plaintext,
           request_id: request_id,
           config_kv_test_opts: [repo: ConfigBatchFailureRepo]
         )}
      end)

    for {request_id, response} <- responses do
      assert_admin_error(
        response,
        400,
        "XMinioAdminConfigBadJSON",
        @bad_json,
        @set_path,
        request_id
      )
    end

    assert ConfigBatchFailureRepo.observations() == %{
             transactions: 0,
             query_calls: 0,
             advisory_locks: 0
           }

    assert Repo.aggregate(RuntimeConfig, :count) == 0
    assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
  end

  test "wrong methods, v4, adjacent, export and history paths remain authenticated 501" do
    # Catches an over-broad prefix dispatch that accidentally claims a neighboring or explicitly
    # deferred Admin API while wiring the three exact triples.
    cases = [
      {:post, @get_path, %{}},
      {:get, @set_path, %{}},
      {:put, @reset_path, %{}},
      {:get, "/minio/admin/v4/get-config-kv", %{}},
      {:get, @get_path <> "/extra", %{}},
      {:post, @help_path, %{"subSys" => "", "key" => ""}},
      {:get, @help_path <> "/extra", %{"subSys" => "", "key" => ""}},
      {:get, "/minio/admin/v4/help-config-kv", %{"subSys" => "", "key" => ""}},
      {:get, "#{@base}/config", %{}},
      {:put, "#{@base}/config", %{}},
      {:get, "#{@base}/list-config-history-kv", %{"count" => "10"}},
      {:delete, "#{@base}/clear-config-history-kv", %{"restoreId" => "fixture-restore-id"}},
      {:put, "#{@base}/restore-config-history-kv", %{"restoreId" => "fixture-restore-id"}}
    ]

    for {{method, path, query}, index} <- Enum.with_index(cases, 1) do
      request_id = "req-config-fallback-#{index}"

      conn =
        signed(method, path,
          query: query,
          headers: [{"x-request-id", request_id}],
          region: ""
        )

      assert_admin_error(
        conn,
        501,
        "NotImplemented",
        "The MinIO admin API endpoint #{path} is not implemented by maxio.",
        path,
        request_id
      )
    end
  end

  test "help exact route returns plaintext ordered JSON and never reads or mutates state" do
    before_rows = Repo.aggregate(RuntimeConfig, :count)
    before_audits = Repo.aggregate(RuntimeConfigAudit, :count)

    request =
      :get
      |> SigV4Request.signed_conn(@help_path,
        query: %{"subSys" => "", "key" => ""},
        headers: [{"x-request-id", "req-config-help-entity"}],
        region: ""
      )
      |> attach_body_read_probe()

    assert get_req_header(request, "content-length") == []
    assert get_req_header(request, "transfer-encoding") == []
    assert get_req_header(request, "content-type") == []

    response = Endpoint.call(request, Endpoint.init([]))
    refute_received :body_reader_called

    expected =
      ~s({"subSys":"","description":"","multipleTargets":false,"keysHelp":[{"key":"s3","description":"Maxio extension: configure s3.clock_skew_ms.","optional":false,"type":"","multipleTargets":false},{"key":"listing","description":"Maxio extension: configure listing.sql_hard_limit.","optional":false,"type":"","multipleTargets":false},{"key":"prometheus_metrics","description":"Maxio extension: configure prometheus_metrics.public.","optional":false,"type":"","multipleTargets":false}]}) <>
        "\n"

    assert response.status == 200
    assert response.resp_body == expected
    assert get_resp_header(response, "content-type") == ["application/json"]
    assert get_resp_header(response, "content-length") == [Integer.to_string(byte_size(expected))]
    assert get_resp_header(response, "transfer-encoding") == []
    assert get_resp_header(response, "content-encoding") == []
    assert get_resp_header(response, "x-minio-config-applied") == []
    refute response.resp_body =~ @root_secret
    refute response.resp_body =~ @caller_secret_sentinel
    assert Repo.aggregate(RuntimeConfig, :count) == before_rows
    assert Repo.aggregate(RuntimeConfigAudit, :count) == before_audits
  end

  test "real Bandit keeps Admin help success and errors plaintext when gzip is accepted" do
    # Catches the transport adapter rewriting the explicit Admin framing after the Plug has
    # produced it. Status and content type are asserted before Content-Encoding so a RED here
    # proves startup, routing, authentication and signing all reached the intended handlers.
    bandit =
      start_supervised!(
        {Bandit, plug: Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    success =
      :get
      |> SigV4Request.signed_conn(@help_path,
        query: %{"subSys" => "", "key" => ""},
        headers: [
          {"accept-encoding", "gzip"},
          {"x-request-id", "req-config-help-bandit-root"}
        ],
        region: ""
      )
      |> raw_bandit_request(port)

    denied =
      :get
      |> SigV4Request.anon_conn(@help_path,
        query: %{"subSys" => "", "key" => ""},
        headers: [
          {"accept-encoding", "gzip"},
          {"x-request-id", "req-config-help-bandit-anonymous"}
        ]
      )
      |> raw_bandit_request(port)

    expected_success =
      ~s({"subSys":"","description":"","multipleTargets":false,"keysHelp":[{"key":"s3","description":"Maxio extension: configure s3.clock_skew_ms.","optional":false,"type":"","multipleTargets":false},{"key":"listing","description":"Maxio extension: configure listing.sql_hard_limit.","optional":false,"type":"","multipleTargets":false},{"key":"prometheus_metrics","description":"Maxio extension: configure prometheus_metrics.public.","optional":false,"type":"","multipleTargets":false}]}) <>
        "\n"

    expected_denied =
      ~s({"Code":"AccessDenied","HostId":"","Message":"Access Denied","RequestId":"req-config-help-bandit-anonymous","Resource":"/minio/admin/v3/help-config-kv"})

    assert success.status == 200
    assert denied.status == 403
    assert success.headers["content-type"] == ["application/json"]
    assert denied.headers["content-type"] == ["application/json; charset=utf-8"]

    assert {success.headers["content-encoding"], denied.headers["content-encoding"]} ==
             {nil, nil}

    assert {success.headers["transfer-encoding"], denied.headers["transfer-encoding"]} ==
             {nil, nil}

    assert success.headers["content-length"] == [Integer.to_string(byte_size(expected_success))]
    assert denied.headers["content-length"] == [Integer.to_string(byte_size(expected_denied))]
    assert success.body == expected_success
    assert denied.body == expected_denied
    refute String.ends_with?(denied.body, "\n")
  end

  test "help preserves missing-versus-empty query precedence before authorization" do
    {access_key, secret, _arn} = put_action_key(nil)

    for {query, suffix} <- [
          {%{}, "both"},
          {%{"subSys" => ""}, "key"},
          {%{"key" => ""}, "subsystem"}
        ] do
      request_id = "req-config-help-missing-#{suffix}"

      response =
        signed(:get, @help_path,
          query: query,
          access_key: access_key,
          secret: secret,
          headers: [{"x-request-id", request_id}],
          region: ""
        )

      assert_admin_error(
        response,
        426,
        "XMinioAdminVersionMismatch",
        "This 'admin' API is not supported by server in 'maxio'",
        @help_path,
        request_id
      )

      assert_help_error_framing(response)
    end

    denied =
      signed(:get, @help_path,
        query: %{"subSys" => "s3:target", "key" => ""},
        access_key: access_key,
        secret: secret,
        headers: [{"x-request-id", "req-config-help-denied-before-target"}],
        region: ""
      )

    assert_admin_error(
      denied,
      403,
      "AccessDenied",
      @access_denied,
      @help_path,
      "req-config-help-denied-before-target"
    )

    assert_help_error_framing(denied)
  end

  test "help uses ConfigUpdate identity authorization and keeps STS and bucket-policy grants closed" do
    {allowed_key, allowed_secret, _arn} = put_action_key("admin:ConfigUpdate")

    allowed =
      signed(:get, @help_path,
        query: %{"subSys" => "s3", "key" => "clock_skew_ms"},
        access_key: allowed_key,
        secret: allowed_secret,
        region: ""
      )

    assert allowed.status == 200
    assert allowed.resp_body =~ ~s("type":"integer in 0..3600000")

    {:ok, session_boundary} =
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

    {sts_key, sts_secret, _arn} =
      put_action_key("admin:ConfigUpdate",
        principal_extra: %{session_policy_statements: session_boundary}
      )

    sts =
      signed(:get, @help_path,
        query: %{"subSys" => "", "key" => ""},
        access_key: sts_key,
        secret: sts_secret,
        region: ""
      )

    assert_denied(sts)

    {bucket_key, bucket_secret, bucket_arn} = put_action_key(nil)

    :ok =
      PolicyStore.put_bucket_policy(
        unique_name("config-help-bucket"),
        Jason.encode!(%{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => bucket_arn},
            "Action" => "admin:ConfigUpdate",
            "Resource" => "*"
          }
        })
      )

    bucket =
      signed(:get, @help_path,
        query: %{"subSys" => "", "key" => ""},
        access_key: bucket_key,
        secret: bucket_secret,
        region: ""
      )

    assert_denied(bucket)
  end

  test "help target unknown forbidden hidden and env errors use exact public framing" do
    cases = [
      {%{"subSys" => "s3:target", "key" => ""}, 400, "XMinioAdminInvalidArgument",
       "Invalid arguments specified."},
      {%{"subSys" => "absent", "key" => ""}, 400, "XMinioConfigError",
       "unknown sub-system absent"},
      {%{"subSys" => "s3", "key" => "absent"}, 400, "XMinioConfigError",
       "unknown key absent for sub-system s3"},
      {%{"subSys" => "s3", "key" => "root_password"}, 403, "AccessDenied", @access_denied},
      {%{"subSys" => "cluster", "key" => "deployment_id"}, 400, "XMinioConfigError",
       "Configuration specified is invalid"},
      {%{"subSys" => "s3", "key" => "clock_skew_ms", "env" => ""}, 400, "XMinioConfigError",
       "unknown key clock_skew_ms for sub-system s3"}
    ]

    for {{query, status, code, message}, index} <- Enum.with_index(cases, 1) do
      request_id = "req-config-help-error-#{index}"

      response =
        signed(:get, @help_path,
          query: query,
          headers: [{"x-request-id", request_id}],
          region: ""
        )

      assert_admin_error(response, status, code, message, @help_path, request_id)
      assert_help_error_framing(response)

      refute response.resp_body =~ "root_password"
      refute response.resp_body =~ "deployment_id"
      refute response.resp_body =~ @root_secret
    end
  end

  test "help env is a presence flag and success logs contain only safe projection metadata" do
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)
    owner = self()

    log =
      capture_log([level: :info], fn ->
        response =
          signed(:get, @help_path,
            query: %{"subSys" => "s3", "key" => "", "env" => "false"},
            headers: [{"x-request-id", "req-config-help-env-log"}],
            region: ""
          )

        send(owner, {:help_env_response, response})
      end)

    assert_receive {:help_env_response, response}
    assert response.status == 200
    assert Jason.decode!(response.resp_body)["keysHelp"] == []

    for fragment <- [
          "action=admin_config_help",
          "admin_action=admin_config_help",
          "required_action=admin:ConfigUpdate",
          "config_subsystem=s3",
          "config_key_count=0",
          "config_changed_count=0",
          "request_id=req-config-help-env-log",
          "principal_arn=arn:aws:iam:::root",
          "auth_type=header"
        ] do
      assert log =~ fragment
    end

    for secret <- [@root_secret, @caller_secret_sentinel, "Authorization", "env=false"] do
      refute log =~ secret
    end
  end

  test "authenticated missing GET key is 426 while an authorized empty key reaches ConfigUpdate" do
    # Catches collapsing Gorilla's absent-vs-empty query branches or routing either branch to help.
    missing_id = "req-config-missing-key"

    missing =
      signed(:get, @get_path,
        headers: [{"x-request-id", missing_id}],
        region: ""
      )

    assert_admin_error(
      missing,
      426,
      "XMinioAdminVersionMismatch",
      "This 'admin' API is not supported by server in 'maxio'",
      @get_path,
      missing_id
    )

    empty_id = "req-config-empty-key"

    empty =
      signed(:get, @get_path,
        query: %{"key" => ""},
        headers: [{"x-request-id", empty_id}],
        region: ""
      )

    assert_admin_error(
      empty,
      400,
      "XMinioConfigError",
      "unknown subsystem: ",
      @get_path,
      empty_id
    )

    {access_key, secret, _arn} = put_action_key(nil)
    no_policy_missing_id = "req-config-missing-no-policy"

    no_policy_missing =
      signed(:get, @get_path,
        access_key: access_key,
        secret: secret,
        headers: [{"x-request-id", no_policy_missing_id}],
        region: ""
      )

    assert_admin_error(
      no_policy_missing,
      426,
      "XMinioAdminVersionMismatch",
      "This 'admin' API is not supported by server in 'maxio'",
      @get_path,
      no_policy_missing_id
    )

    denied_id = "req-config-empty-denied"

    denied =
      signed(:get, @get_path,
        query: %{"key" => ""},
        access_key: access_key,
        secret: secret,
        headers: [{"x-request-id", denied_id}],
        region: ""
      )

    assert_admin_error(
      denied,
      403,
      "AccessDenied",
      @access_denied,
      @get_path,
      denied_id
    )
  end

  test "each route requires the exact identity-policy ConfigUpdate action" do
    # Catches GET being wired as read-only, mutation-specific action drift, or envelope decryption
    # using the configured root password instead of the exact non-root signing credential.
    for operation <- [:get, :set, :reset] do
      {access_key, secret, _arn} = put_action_key("admin:ConfigUpdate")
      conn = route_request(operation, access_key, secret, "allow-#{operation}")

      assert conn.status == 200

      if operation == :get do
        assert {:ok, "s3 clock_skew_ms=900000 \n"} = decrypt(conn, secret)
        assert {:error, :not_authentic} = decrypt(conn, @root_secret)
      else
        assert_mutation_success(conn, true)
      end

      {wrong_key, wrong_secret, _arn} = put_action_key("admin:ServerInfo")
      denied = route_request(operation, wrong_key, wrong_secret, "wrong-#{operation}")
      assert denied.status == 403
      assert Jason.decode!(denied.resp_body)["Code"] == "AccessDenied"
    end
  end

  test "implicit deny, explicit deny, STS boundary and bucket policy stay closed for every route" do
    # Catches identity-only cluster authorization being diluted by an absent policy, a later allow,
    # an STS issuer policy, or a resource policy.
    {:ok, session_boundary} =
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

    for operation <- [:get, :set, :reset] do
      {implicit_key, implicit_secret, _arn} = put_action_key(nil)

      assert_denied(
        route_request(operation, implicit_key, implicit_secret, "implicit-#{operation}")
      )

      {deny_key, deny_secret, _arn} =
        put_action_key([
          %{"Effect" => "Allow", "Action" => "admin:ConfigUpdate"},
          %{"Effect" => "Deny", "Action" => "admin:ConfigUpdate"}
        ])

      assert_denied(route_request(operation, deny_key, deny_secret, "explicit-#{operation}"))

      {sts_key, sts_secret, _arn} =
        put_action_key("admin:ConfigUpdate",
          principal_extra: %{session_policy_statements: session_boundary}
        )

      assert_denied(route_request(operation, sts_key, sts_secret, "sts-#{operation}"))

      {bucket_key, bucket_secret, bucket_arn} = put_action_key(nil)

      :ok =
        PolicyStore.put_bucket_policy(
          unique_name("config-kv-bucket"),
          Jason.encode!(%{
            "Version" => "2012-10-17",
            "Statement" => %{
              "Effect" => "Allow",
              "Principal" => %{"AWS" => bucket_arn},
              "Action" => "admin:ConfigUpdate",
              "Resource" => "arn:aws:s3:::*"
            }
          })
        )

      assert_denied(route_request(operation, bucket_key, bucket_secret, "bucket-#{operation}"))
    end
  end

  test "denied PUT and DELETE never read a body byte" do
    # Catches authorization moving below framing, hashing, decryption, or parsing.
    {access_key, secret, _arn} = put_action_key(nil)

    for {method, path, plaintext} <- [
          {:put, @set_path, "listing sql_hard_limit=31337"},
          {:delete, @reset_path, "listing sql_hard_limit"}
        ] do
      body = encrypted!(secret, plaintext)

      conn =
        method
        |> SigV4Request.signed_conn(path,
          body: body,
          headers: [{"content-length", Integer.to_string(byte_size(body))}],
          access_key: access_key,
          secret: secret,
          region: ""
        )
        |> attach_body_read_probe()
        |> Endpoint.call(Endpoint.init([]))

      assert_denied(conn)
      refute_received :body_reader_called
    end
  end

  test "mutation framing requires one concrete length, ignores Content-Type, and preserves zero" do
    # Catches accepting ambiguous framing, rejecting madmin's absent Content-Type, or rewriting an
    # explicit zero before it reaches envelope decryption.
    ciphertext = encrypted!(@root_secret, "listing sql_hard_limit=515151")

    invalid_headers = [
      [],
      [
        {"content-length", "#{byte_size(ciphertext)}"},
        {"content-length", "#{byte_size(ciphertext)}"}
      ],
      [{"content-length", "-1"}],
      [{"content-length", "+1"}],
      [{"content-length", "1.0"}],
      [{"content-length", "262273"}],
      [{"content-length", "#{byte_size(ciphertext)}"}, {"transfer-encoding", "chunked"}]
    ]

    for {headers, index} <- Enum.with_index(invalid_headers, 1) do
      request_id = "req-config-framing-#{index}"

      conn =
        signed(:put, @set_path,
          body: ciphertext,
          headers: headers ++ [{"x-request-id", request_id}],
          region: ""
        )

      assert_admin_error(
        conn,
        400,
        "XMinioAdminConfigTooLarge",
        @too_large,
        @set_path,
        request_id
      )
    end

    zero_id = "req-config-framing-zero"

    zero =
      signed(:put, @set_path,
        headers: [{"content-length", "0"}, {"x-request-id", zero_id}],
        region: ""
      )

    assert_admin_error(zero, 400, "XMinioAdminConfigBadJSON", @bad_json, @set_path, zero_id)

    for {content_types, value} <- [
          {[], 515_152},
          {[{"content-type", "application/octet-stream; x=maxio"}], 515_153},
          {[{"content-type", "text/plain"}, {"content-type", "application/json"}], 515_154}
        ] do
      body = encrypted!(@root_secret, "listing sql_hard_limit=#{value}")

      conn =
        signed(:put, @set_path,
          body: body,
          headers: [{"content-length", Integer.to_string(byte_size(body))} | content_types],
          region: ""
        )

      assert_mutation_success(conn, true)
    end
  end

  test "a raw duplicate Content-Length request authenticates before Admin rejects its framing" do
    # Catches either the signing helper collapsing raw duplicates or SigV4 canonicalization
    # producing different client/server material before Admin can classify ambiguous framing.
    ciphertext = encrypted!(@root_secret, "listing sql_hard_limit=515159")
    length = Integer.to_string(byte_size(ciphertext))
    request_id = "req-config-framing-raw-duplicate"

    {request, response} =
      signed_pair(:put, @set_path,
        body: ciphertext,
        headers: [
          {"content-length", length},
          {"content-length", length},
          {"x-request-id", request_id}
        ],
        region: ""
      )

    assert get_req_header(request, "content-length") == [length, length]

    assert_admin_error(
      response,
      400,
      "XMinioAdminConfigTooLarge",
      @too_large,
      @set_path,
      request_id
    )
  end

  test "actual length, payload hash, decrypt and parser failures retain their fixed priority" do
    # Catches a lower stage overwriting a more causal error when the same signed request contains
    # multiple independent faults.
    length_id = "req-config-priority-length"

    length_error =
      signed(:put, @set_path,
        body: <<0>>,
        headers: [{"content-length", "2"}, {"x-request-id", length_id}],
        content_sha256_override: String.duplicate("0", 64),
        region: ""
      )

    assert_admin_error(
      length_error,
      400,
      "XMinioAdminConfigBadJSON",
      @bad_json,
      @set_path,
      length_id
    )

    hash_id = "req-config-priority-hash"

    hash_error =
      signed(:put, @set_path,
        body: <<0>>,
        headers: [{"content-length", "1"}, {"x-request-id", hash_id}],
        content_sha256_override: String.duplicate("0", 64),
        region: ""
      )

    assert_admin_error(
      hash_error,
      400,
      "XAmzContentSHA256Mismatch",
      @hash_mismatch,
      @set_path,
      hash_id
    )

    decrypt_id = "req-config-priority-decrypt"
    wrong_ciphertext = encrypted!("not-the-authenticated-caller-secret", "s3 absent=1")

    decrypt_error =
      signed(:put, @set_path,
        body: wrong_ciphertext,
        headers: [
          {"content-length", Integer.to_string(byte_size(wrong_ciphertext))},
          {"x-request-id", decrypt_id}
        ],
        region: ""
      )

    assert_admin_error(
      decrypt_error,
      400,
      "XMinioAdminConfigBadJSON",
      @bad_json,
      @set_path,
      decrypt_id
    )

    parser_id = "req-config-priority-parser"

    parser_error =
      mutation(:put, @set_path, "s3 clock_skew_ms=1000\nlisting sql_hard_limit=not-an-int",
        request_id: parser_id,
        config_kv_test_opts: [repo: ConfigBatchFailureRepo]
      )

    assert_admin_error(
      parser_error,
      400,
      "XMinioAdminConfigBadJSON",
      @bad_json,
      @set_path,
      parser_id
    )

    assert ConfigBatchFailureRepo.observations().transactions == 0
  end

  test "exposure precedes scalar validation and scalar validation precedes the database" do
    # Catches a forbidden secret path being disguised as a type error, or an invalid scalar opening
    # a transaction and being replaced by a storage error.
    ConfigBatchFailureRepo.arm!(:runtime_insert, :clock_skew_ms)

    exposure_id = "req-config-priority-exposure"

    exposure =
      mutation(
        :put,
        @set_path,
        "s3 root_password=forbidden-value clock_skew_ms=not-an-integer",
        request_id: exposure_id,
        config_kv_test_opts: [repo: ConfigBatchFailureRepo]
      )

    assert_admin_error(
      exposure,
      403,
      "AccessDenied",
      @access_denied,
      @set_path,
      exposure_id
    )

    scalar_id = "req-config-priority-scalar"

    scalar =
      mutation(:put, @set_path, "s3 clock_skew_ms=not-an-integer",
        request_id: scalar_id,
        config_kv_test_opts: [repo: ConfigBatchFailureRepo]
      )

    assert_admin_error(
      scalar,
      400,
      "XMinioAdminConfigBadJSON",
      @bad_json,
      @set_path,
      scalar_id
    )

    assert ConfigBatchFailureRepo.observations().transactions == 0

    database_id = "req-config-priority-database"

    database =
      mutation(:put, @set_path, "s3 clock_skew_ms=1234",
        request_id: database_id,
        config_kv_test_opts: [repo: ConfigBatchFailureRepo]
      )

    assert_admin_error(
      database,
      500,
      "InternalError",
      "An internal error occurred. Try again.",
      @set_path,
      database_id
    )

    assert ConfigBatchFailureRepo.observations().transactions == 1
    assert Repo.aggregate(RuntimeConfig, :count) == 0
    assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
  end

  test "cross-subsystem grammar precedes a forbidden token on a later line" do
    # Catches a plaintext-wide exposure scan that returns AccessDenied before Parser rejects a
    # command that cannot represent one atomic subsystem mutation.
    request_id = "req-config-priority-cross-subsystem"

    response =
      mutation(
        :put,
        @set_path,
        "listing sql_hard_limit=100000\ns3 clock_skew_ms=1000 root_password=forbidden-value",
        request_id: request_id,
        config_kv_test_opts: [repo: ConfigBatchFailureRepo]
      )

    assert_admin_error(
      response,
      400,
      "XMinioAdminConfigBadJSON",
      @bad_json,
      @set_path,
      request_id
    )

    assert ConfigBatchFailureRepo.observations() == %{
             transactions: 0,
             query_calls: 0,
             advisory_locks: 0
           }

    assert Repo.aggregate(RuntimeConfig, :count) == 0
    assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
  end

  test "a first-line target remains invalid when a later set or reset line is forbidden" do
    # Catches exposure preflight replacing the parser's first target rejection with AccessDenied.
    # Both requests are executed before assertions so both public precedence paths are exercised.
    set_id = "req-config-target-before-forbidden-set"
    reset_id = "req-config-target-before-forbidden-reset"

    set_response =
      mutation(
        :put,
        @set_path,
        "s3:secondary clock_skew_ms=1000\ns3 root_password=forbidden-value",
        request_id: set_id,
        config_kv_test_opts: [repo: ConfigBatchFailureRepo]
      )

    reset_response =
      mutation(:delete, @reset_path, "s3:secondary\nstorage_backend module",
        request_id: reset_id,
        config_kv_test_opts: [repo: ConfigBatchFailureRepo]
      )

    assert_admin_error(
      set_response,
      400,
      "XMinioAdminInvalidArgument",
      "Invalid arguments specified.",
      @set_path,
      set_id
    )

    assert_admin_error(
      reset_response,
      400,
      "XMinioAdminInvalidArgument",
      "Invalid arguments specified.",
      @reset_path,
      reset_id
    )

    assert ConfigBatchFailureRepo.observations() == %{
             transactions: 0,
             query_calls: 0,
             advisory_locks: 0
           }

    assert Repo.aggregate(RuntimeConfig, :count) == 0
    assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
  end

  test "multi-line reset reports its later unknown key without mutating an earlier valid key" do
    # Catches Plug reconstructing reset grammar from only the first line, or Adapter opening a
    # transaction for the valid prefix before discovering the later unknown key.
    assert {:ok, _result} =
             Maxio.Config.set(:s3, :clock_skew_ms, 2_468,
               source: "admin_api",
               request_id: "req-config-reset-seed"
             )

    Repo.delete_all(RuntimeConfigAudit)
    request_id = "req-config-reset-later-unknown"

    response =
      mutation(:delete, @reset_path, "s3 clock_skew_ms\ns3 absent",
        request_id: request_id,
        config_kv_test_opts: [repo: ConfigBatchFailureRepo]
      )

    assert_admin_error(
      response,
      404,
      "XMinioConfigNotFoundError",
      "key absent doesn't exist",
      @reset_path,
      request_id
    )

    assert ConfigBatchFailureRepo.observations() == %{
             transactions: 0,
             query_calls: 0,
             advisory_locks: 0
           }

    assert Repo.one(
             from row in RuntimeConfig,
               where: row.subsystem == "s3" and row.key == "clock_skew_ms",
               select: {row.value, row.version}
           ) == {%{"v" => 2_468}, 1}

    assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
  end

  test "generic, not-found, hidden, forbidden and target errors keep distinct public contracts" do
    # Catches flattening all Config errors into BadJSON or leaking hidden/forbidden schema details.
    cases = [
      {:get, "absent", 400, "XMinioConfigError", "unknown subsystem: absent"},
      {:set, "absent value=1", 400, "XMinioConfigError", "unknown sub-system absent value=1"},
      {:set, "s3 absent=1", 400, "XMinioConfigError", "sub-system 's3' cannot have empty keys"},
      {:reset, "s3 absent", 404, "XMinioConfigNotFoundError", "key absent doesn't exist"},
      {:reset, "absent", 400, "XMinioConfigError", "unknown sub-system absent"},
      {:reset, "cluster deployment_id", 400, "XMinioConfigError",
       "unknown sub-system cluster deployment_id"},
      {:reset, "s3 root_password", 403, "AccessDenied", @access_denied},
      {:get, "s3:secondary", 400, "XMinioAdminInvalidArgument", "Invalid arguments specified."}
    ]

    for {{operation, input, status, code, message}, index} <- Enum.with_index(cases, 1) do
      request_id = "req-config-public-error-#{index}"

      conn =
        case operation do
          :get ->
            signed(:get, @get_path,
              query: %{"key" => input},
              headers: [{"x-request-id", request_id}],
              region: ""
            )

          :set ->
            mutation(:put, @set_path, input, request_id: request_id)

          :reset ->
            mutation(:delete, @reset_path, input, request_id: request_id)
        end

      path =
        if operation == :get,
          do: @get_path,
          else: if(operation == :set, do: @set_path, else: @reset_path)

      assert_admin_error(conn, status, code, message, path, request_id)
    end
  end

  test "uppercase safe Config identifiers retain exact public descriptions" do
    get_id = "req-config-uppercase-get"
    reset_id = "req-config-uppercase-reset"

    get_response =
      signed(:get, @get_path,
        query: %{"key" => "S3"},
        headers: [{"x-request-id", get_id}],
        region: ""
      )

    reset_response =
      mutation(:delete, @reset_path, "s3 ABSENT", request_id: reset_id)

    assert_admin_error(
      get_response,
      400,
      "XMinioConfigError",
      "unknown subsystem: S3",
      @get_path,
      get_id
    )

    assert_admin_error(
      reset_response,
      404,
      "XMinioConfigNotFoundError",
      "key ABSENT doesn't exist",
      @reset_path,
      reset_id
    )
  end

  test "unsafe Config identifiers use catalog fallbacks without reflecting submitted bytes" do
    identifiers = [
      "SECRETCONFIGKVSENTINEL",
      "CONTROL\u0001MARK",
      String.duplicate("A", 129)
    ]

    responses =
      identifiers
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {identifier, index} ->
        get_id = "req-config-unsafe-get-#{index}"
        reset_id = "req-config-unsafe-reset-#{index}"

        [
          {identifier, "Configuration specified is invalid",
           signed(:get, @get_path,
             query: %{"key" => identifier},
             headers: [{"x-request-id", get_id}],
             region: ""
           )},
          {identifier, "Configuration key/value not found",
           mutation(:delete, @reset_path, "s3 #{identifier}", request_id: reset_id)}
        ]
      end)

    for {identifier, expected_message, response} <- responses do
      assert Jason.decode!(response.resp_body)["Message"] == expected_message
      refute response.resp_body =~ identifier
    end
  end

  test "changed, no-op, next-cycle and restart results tell the exact applied-header truth" do
    # Catches using changed_count alone, treating next-cycle as restart, or claiming a restart-mode
    # commit was dynamically applied.
    changed = mutation(:put, @set_path, "listing sql_hard_limit=616161")
    assert_mutation_success(changed, true)

    noop = mutation(:put, @set_path, "listing sql_hard_limit=616161")
    assert_mutation_success(noop, true)

    next_cycle =
      mutation(:put, @set_path, "listing sql_hard_limit=616162",
        config_kv_test_opts: [schema: ConfigKVApplyModeSchema]
      )

    assert_mutation_success(next_cycle, true)

    restart =
      mutation(:put, @set_path, "s3 clock_skew_ms=616163",
        config_kv_test_opts: [schema: ConfigKVApplyModeSchema]
      )

    assert_mutation_success(restart, false)
  end

  test "a full-subsystem reset retry is an exact success without new audit version or postcommit" do
    # Catches an HTTP retry being rejected, reporting a different entity/applied header, or
    # manufacturing a second reset audit/version/invalidation after the first request committed.
    start_supervised!({ConfigPostcommitStore, owner: self()})
    start_supervised!({ConfigPostcommitNotify, owner: self()})

    test_opts = [store: ConfigPostcommitStore, notify: ConfigPostcommitNotify]

    seeded =
      mutation(:put, @set_path, "s3 clock_skew_ms=1357",
        request_id: "req-config-full-reset-seed",
        config_kv_test_opts: test_opts
      )

    assert_mutation_success(seeded, true)
    ConfigPostcommitStore.reset_observations()
    ConfigPostcommitNotify.reset_observations()

    first =
      mutation(:delete, @reset_path, "s3",
        request_id: "req-config-full-reset-first",
        config_kv_test_opts: test_opts
      )

    assert_mutation_success(first, true)

    audit_after_first =
      Repo.all(
        from audit in RuntimeConfigAudit,
          where: audit.subsystem == "s3" and audit.key == "clock_skew_ms",
          order_by: [asc: audit.to_version],
          select: {
            audit.operation,
            audit.from_version,
            audit.to_version,
            audit.request_id
          }
      )

    assert audit_after_first == [
             {"set", nil, 1, "req-config-full-reset-seed"},
             {"reset", 1, 2, "req-config-full-reset-first"}
           ]

    assert length(ConfigPostcommitStore.observations().reload_calls) == 1
    assert length(ConfigPostcommitNotify.observations().checked_calls) == 1

    ConfigPostcommitStore.reset_observations()
    ConfigPostcommitNotify.reset_observations()

    retry =
      mutation(:delete, @reset_path, "s3",
        request_id: "req-config-full-reset-retry",
        config_kv_test_opts: test_opts
      )

    assert_mutation_success(retry, true)

    assert Repo.all(
             from audit in RuntimeConfigAudit,
               where: audit.subsystem == "s3" and audit.key == "clock_skew_ms",
               order_by: [asc: audit.to_version],
               select: {
                 audit.operation,
                 audit.from_version,
                 audit.to_version,
                 audit.request_id
               }
           ) == audit_after_first

    assert Repo.aggregate(
             from(row in RuntimeConfig,
               where: row.subsystem == "s3" and row.key == "clock_skew_ms"
             ),
             :count
           ) == 0

    assert ConfigPostcommitStore.observations().reload_calls == []
    assert ConfigPostcommitStore.observations().attention_calls == []
    assert ConfigPostcommitNotify.observations() == %{checked_calls: [], legacy_calls: []}
  end

  test "reload failure omits applied while broadcast failure keeps it after commit" do
    # Catches postcommit failure being turned into a false 5xx/rollback or broadcast failure being
    # misreported as a restart requirement.
    start_supervised!({ConfigPostcommitStore, owner: self()})
    start_supervised!({ConfigPostcommitNotify, owner: self()})

    ConfigPostcommitStore.configure(reload: {:raise, "private reload detail"}, attention: :ok)

    reload_failed =
      mutation(:put, @set_path, "listing sql_hard_limit=717171",
        config_kv_test_opts: [store: ConfigPostcommitStore, notify: ConfigPostcommitNotify]
      )

    assert_mutation_success(reload_failed, false)
    assert_runtime_value(:listing, :sql_hard_limit, 717_171)

    ConfigPostcommitStore.configure(reload: :ok, attention: :ok)

    ConfigPostcommitNotify.configure(
      checked: {:return, {:error, {:transport, "private broadcast detail"}}}
    )

    broadcast_failed =
      mutation(:put, @set_path, "listing sql_hard_limit=717172",
        config_kv_test_opts: [store: ConfigPostcommitStore, notify: ConfigPostcommitNotify]
      )

    assert_mutation_success(broadcast_failed, true)
    assert_runtime_value(:listing, :sql_hard_limit, 717_172)
  end

  test "a second attention-recorder raise exit or error cannot replace either committed response" do
    # Catches the recorder becoming a second failure channel after a committed reload/broadcast
    # problem. Each case proves the real row and audit survive exactly once.
    start_supervised!({ConfigPostcommitStore, owner: self()})
    start_supervised!({ConfigPostcommitNotify, owner: self()})

    cases = [
      {:reload, {:raise, @recorder_reason_sentinel}, :recorder_raised, false},
      {:reload, {:exit, {:private, @recorder_reason_sentinel}}, :recorder_exited, false},
      {:reload, {:return, {:error, :unavailable}}, :recorder_unavailable, false},
      {:broadcast, {:raise, @recorder_reason_sentinel}, :recorder_raised, true},
      {:broadcast, {:exit, {:private, @recorder_reason_sentinel}}, :recorder_exited, true},
      {:broadcast, {:return, {:error, {:transport, @recorder_reason_sentinel}}},
       :recorder_transport_failed, true}
    ]

    for {{trigger, recorder_outcome, expected_record, applied?}, index} <-
          Enum.with_index(cases, 1) do
      configure_postcommit_failure(trigger, recorder_outcome)
      value = 800_000 + index
      request_id = "req-config-recorder-#{trigger}-#{index}"
      owner = self()

      log =
        capture_log(fn ->
          conn =
            mutation(:put, @set_path, "listing sql_hard_limit=#{value}",
              request_id: request_id,
              config_kv_test_opts: [
                store: ConfigPostcommitStore,
                notify: ConfigPostcommitNotify
              ]
            )

          send(owner, {:recorder_response, index, conn})
        end)

      assert_receive {:recorder_response, ^index, conn}
      assert_mutation_success(conn, applied?)
      assert_runtime_value(:listing, :sql_hard_limit, value)
      assert log =~ "config_attention_record=#{expected_record}"
      assert log =~ "request_id=#{request_id}"
      refute log =~ @recorder_reason_sentinel
    end

    assert Repo.aggregate(RuntimeConfigAudit, :count) == length(cases)
  end

  test "success and failure logs contain only the frozen safe Config KVS metadata" do
    # Catches missing operational evidence or accidental serialization of the command, value,
    # envelope, old/new maps, recorder detail, or caller secret.
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)

    body = encrypted!(@root_secret, @raw_command)
    ciphertext_hex = Base.encode16(body, case: :lower)
    request_id = "req-config-safe-success"
    owner = self()

    success_log =
      capture_log([level: :info], fn ->
        conn =
          signed(:put, @set_path,
            body: body,
            headers: [
              {"content-length", Integer.to_string(byte_size(body))},
              {"x-request-id", request_id}
            ],
            region: ""
          )

        send(owner, {:safe_log_response, conn})
      end)

    assert_receive {:safe_log_response, success}
    assert_mutation_success(success, true)

    for fragment <- [
          "action=admin_config_set",
          "required_action=admin:ConfigUpdate",
          "config_subsystem=listing",
          "config_key_count=1",
          "config_changed_count=1",
          "config_apply_modes=hot",
          "config_local_reload=ok",
          "config_broadcast=ok",
          "config_attention=false",
          "request_id=#{request_id}",
          "principal_arn=arn:aws:iam:::root",
          "auth_type=header"
        ] do
      assert success_log =~ fragment
    end

    for secret <- [
          @raw_command,
          @submitted_value,
          body,
          inspect(body),
          ciphertext_hex,
          "%{\"v\" => #{@submitted_value}}",
          @root_secret,
          @caller_secret_sentinel,
          @recorder_reason_sentinel
        ] do
      refute success_log =~ secret
    end

    failure_id = "req-config-safe-failure"

    failure_log =
      capture_log(fn ->
        conn =
          mutation(:put, @set_path, "s3 clock_skew_ms=not-a-number", request_id: failure_id)

        send(owner, {:safe_failure_response, conn})
      end)

    assert_receive {:safe_failure_response, failure}

    assert_admin_error(
      failure,
      400,
      "XMinioAdminConfigBadJSON",
      @bad_json,
      @set_path,
      failure_id
    )

    assert failure_log =~ "action=admin_config_set"
    assert failure_log =~ "config_subsystem=s3"
    assert failure_log =~ "config_key_count=1"
    assert failure_log =~ "config_failure_stage=type"
    assert failure_log =~ "code=XMinioAdminConfigBadJSON"
    assert failure_log =~ "request_id=#{failure_id}"
    assert failure_log =~ "principal_arn=arn:aws:iam:::root"
    assert failure_log =~ "auth_type=header"
    refute failure_log =~ "not-a-number"
    refute failure_log =~ @root_secret
  end

  test "malformed UTF-8 is BadJSON and no plaintext rendering reaches logs" do
    # Catches String operations raising on decrypted bytes and the top-level rescue logging the
    # exception message, which can contain caller-controlled printable plaintext.
    sentinel = "CONFIG-KV-MALFORMED-UTF8-SENTINEL"
    plaintext = sentinel <> <<0xFF>> <> "-tail"
    body = encrypted!(@root_secret, plaintext)
    request_id = "req-config-malformed-utf8"
    owner = self()

    log =
      capture_log(fn ->
        response =
          signed(:put, @set_path,
            body: body,
            headers: [
              {"content-length", Integer.to_string(byte_size(body))},
              {"x-request-id", request_id}
            ],
            region: ""
          )

        send(owner, {:malformed_utf8_response, response})
      end)

    assert_receive {:malformed_utf8_response, response}

    assert_admin_error(
      response,
      400,
      "XMinioAdminConfigBadJSON",
      @bad_json,
      @set_path,
      request_id
    )

    refute log =~ sentinel
    refute log =~ inspect(plaintext)
    refute log =~ Base.encode16(plaintext, case: :lower)
  end

  defp signed(method, path, opts) do
    {_request, response} = signed_pair(method, path, opts)
    response
  end

  defp signed_pair(method, path, opts) do
    {test_opts, opts} = Keyword.pop(opts, :config_kv_test_opts, [])

    request =
      method
      |> SigV4Request.signed_conn(path, opts)
      |> maybe_put_test_opts(test_opts)

    {request, Endpoint.call(request, Endpoint.init([]))}
  end

  defp mutation(method, path, plaintext, opts \\ []) do
    secret = Keyword.get(opts, :secret, @root_secret)
    body = encrypted!(secret, plaintext)
    request_id = Keyword.get(opts, :request_id)

    headers =
      [{"content-length", Integer.to_string(byte_size(body))} | Keyword.get(opts, :headers, [])]
      |> maybe_add_request_id(request_id)

    request_opts =
      opts
      |> Keyword.drop([:request_id])
      |> Keyword.put(:body, body)
      |> Keyword.put(:headers, headers)
      |> Keyword.put_new(:region, "")

    signed(method, path, request_opts)
  end

  defp route_request(:get, access_key, secret, suffix) do
    signed(:get, @get_path,
      query: %{"key" => "s3"},
      access_key: access_key,
      secret: secret,
      headers: [{"x-request-id", "req-config-auth-#{suffix}"}],
      region: ""
    )
  end

  defp route_request(:set, access_key, secret, suffix) do
    value = 900_000 + rem(System.unique_integer([:positive, :monotonic]), 100_000)

    mutation(:put, @set_path, "listing sql_hard_limit=#{value}",
      access_key: access_key,
      secret: secret,
      request_id: "req-config-auth-#{suffix}"
    )
  end

  defp route_request(:reset, access_key, secret, suffix) do
    mutation(:delete, @reset_path, "listing sql_hard_limit",
      access_key: access_key,
      secret: secret,
      request_id: "req-config-auth-#{suffix}"
    )
  end

  defp encrypted!(secret, plaintext) do
    assert {:ok, ciphertext} = Envelope.encrypt(SigningSecret.new(secret), plaintext)
    ciphertext
  end

  defp decrypt(conn, secret) do
    Envelope.decrypt(SigningSecret.new(secret), conn.resp_body)
  end

  defp maybe_put_test_opts(conn, []), do: conn
  defp maybe_put_test_opts(conn, opts), do: put_private(conn, :maxio_config_kv_test_opts, opts)

  defp maybe_add_request_id(headers, nil), do: headers
  defp maybe_add_request_id(headers, request_id), do: headers ++ [{"x-request-id", request_id}]

  defp attach_body_read_probe(conn) do
    {_adapter, state} = conn.adapter
    %{conn | adapter: {Maxio.Test.BodyReadProbeAdapter, {self(), state}}}
  end

  defp put_action_key(action_or_statements, opts \\ []) do
    suffix = System.unique_integer([:positive, :monotonic])
    access_key = String.pad_trailing("AKIACONFIGKV#{suffix}", 20, "X")
    secret = "admin-config-kv-secret-#{suffix}-long-enough"
    arn = IAM.user_arn(access_key)
    principal_extra = Keyword.get(opts, :principal_extra, %{})
    principal = Map.merge(%{type: :iam_user, access_key: access_key, arn: arn}, principal_extra)

    assert {:ok, %{user_name: ^access_key}} = IAM.create_user(name: access_key)

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
        PolicyStore.put_principal_policy(
          arn,
          unique_name("config-kv-action"),
          Jason.encode!(%{"Version" => "2012-10-17", "Statement" => statements})
        )
    end

    {access_key, secret, arn}
  end

  defp configure_postcommit_failure(:reload, recorder_outcome) do
    ConfigPostcommitStore.configure(
      reload: {:return, {:error, {:transport, "private reload detail"}}},
      attention: recorder_outcome
    )

    ConfigPostcommitNotify.configure(checked: :ok)
  end

  defp configure_postcommit_failure(:broadcast, recorder_outcome) do
    ConfigPostcommitStore.configure(reload: :ok, attention: recorder_outcome)

    ConfigPostcommitNotify.configure(
      checked: {:return, {:error, {:transport, "private broadcast detail"}}}
    )
  end

  defp assert_runtime_value(subsystem, key, expected) do
    subsystem = Atom.to_string(subsystem)
    key = Atom.to_string(key)

    assert Repo.one(
             from row in RuntimeConfig,
               where: row.subsystem == ^subsystem and row.key == ^key,
               select: row.value
           ) == %{"v" => expected}
  end

  defp assert_request_entity(conn, content_length, content_type, expected_body) do
    assert get_req_header(conn, "content-length") == header_value(content_length)
    assert get_req_header(conn, "transfer-encoding") == []
    assert get_req_header(conn, "content-type") == header_value(content_type)
    assert {:ok, ^expected_body, _conn} = read_body(conn)
  end

  defp assert_response_entity(conn, content_length, content_type) do
    assert get_resp_header(conn, "content-length") == header_value(content_length)
    assert get_resp_header(conn, "transfer-encoding") == []
    assert get_resp_header(conn, "content-type") == header_value(content_type)
    assert byte_size(conn.resp_body) == String.to_integer(content_length)
  end

  defp assert_mutation_success(conn, applied?) do
    assert conn.status == 200
    assert conn.resp_body == ""
    assert get_resp_header(conn, "content-length") == ["0"]
    assert get_resp_header(conn, "transfer-encoding") == []
    assert get_resp_header(conn, "content-type") == []

    expected_applied = if applied?, do: ["true"], else: []
    assert get_resp_header(conn, "x-minio-config-applied") == expected_applied
  end

  defp assert_denied(conn) do
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["Code"] == "AccessDenied"
  end

  defp assert_admin_error(conn, status, code, message, resource, request_id) do
    assert conn.status == status

    assert Jason.decode!(conn.resp_body) == %{
             "Code" => code,
             "Message" => message,
             "Resource" => resource,
             "RequestId" => request_id,
             "HostId" => ""
           }
  end

  defp assert_help_error_framing(conn) do
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    assert get_resp_header(conn, "content-length") == [
             Integer.to_string(byte_size(conn.resp_body))
           ]

    assert get_resp_header(conn, "transfer-encoding") == []
    assert get_resp_header(conn, "content-encoding") == []
    assert get_resp_header(conn, "x-minio-config-applied") == []
    refute String.ends_with?(conn.resp_body, "\n")
  end

  defp raw_bandit_request(conn, port) do
    target =
      case conn.query_string do
        "" -> conn.request_path
        query -> conn.request_path <> "?" <> query
      end

    headers = [{"host", conn.host}, {"connection", "close"} | conn.req_headers]

    request =
      [
        conn.method,
        " ",
        target,
        " HTTP/1.1\r\n",
        Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
        "\r\n"
      ]
      |> IO.iodata_to_binary()

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

    :ok = :gen_tcp.send(socket, request)
    raw = recv_raw_response(socket, [])
    :ok = :gen_tcp.close(socket)

    parse_raw_response(raw)
  end

  defp recv_raw_response(socket, chunks) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> recv_raw_response(socket, [chunk | chunks])
      {:error, :closed} -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
      {:error, reason} -> flunk("raw Bandit response failed: #{inspect(reason)}")
    end
  end

  defp parse_raw_response(raw) do
    [head, body] = :binary.split(raw, "\r\n\r\n")
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/1.1", status | _reason] = String.split(status_line, " ")

    headers =
      Enum.reduce(header_lines, %{}, fn line, acc ->
        [name, value] = String.split(line, ":", parts: 2)
        Map.update(acc, String.downcase(name), [String.trim(value)], &[String.trim(value) | &1])
      end)

    %{status: String.to_integer(status), headers: headers, body: body}
  end

  defp header_value(nil), do: []
  defp header_value(value), do: [value]

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
