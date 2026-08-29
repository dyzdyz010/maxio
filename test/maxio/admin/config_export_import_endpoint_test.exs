defmodule Maxio.Admin.ConfigExportImportEndpointTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Maxio.Admin.ConfigKV.{Archive, Request}
  alias Maxio.Admin.Envelope
  alias Maxio.Auth.{CredentialStore, SigningSecret}
  alias Maxio.IAM
  alias Maxio.Policy.Store, as: PolicyStore
  alias Maxio.S3.{Endpoint, Error}
  alias Maxio.Test.SigV4Request

  @path "/minio/admin/v3/config"
  @root_secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  @fresh_archive "s3 clock_skew_ms=900000 \n" <>
                   "listing sql_hard_limit=100000 \n" <>
                   "prometheus_metrics public=false \n"
  @fresh_snapshot %{
    {:s3, :clock_skew_ms} => %{value: 900_000, source: :fallback, version: nil},
    {:listing, :sql_hard_limit} => %{value: 100_000, source: :fallback, version: nil},
    {:prometheus_metrics, :public} => %{value: false, source: :fallback, version: nil}
  }
  @too_large "Configuration data provided exceeds the allowed maximum of 262272 bytes"
  @wire_fixture Path.expand(
                  "../../fixtures/minio_admin_config_export_import_s7/minio_config_archive_wire.json",
                  __DIR__
                )
  @wire_contract @wire_fixture |> File.read!() |> Jason.decode!()
  @fixture_conditions get_in(@wire_contract, ["error_map_contract", "conditions"])
  @fixture_precedence get_in(@wire_contract, ["error_map_contract", "precedence"])

  test "fixture condition keys resolve to executable production cases" do
    expected_ids = MapSet.new(@fixture_conditions, & &1["id"])
    executable_ids = MapSet.new(Map.keys(executable_condition_cases()))

    assert MapSet.size(expected_ids) == 23
    assert executable_ids == expected_ids
  end

  for condition <- @fixture_conditions do
    id = condition["id"]

    test "fixture condition #{id} executes its production boundary" do
      condition = unquote(Macro.escape(condition))
      runner = Map.fetch!(executable_condition_cases(), condition["id"])
      runner.()
    end
  end

  for precedence <- @fixture_precedence do
    priority = precedence["priority"]
    stage = precedence["stage"]

    test "fixture priority #{priority} #{stage} wins over multiple later faults" do
      precedence = unquote(Macro.escape(precedence))
      run_precedence_case(precedence)
    end
  end

  defp executable_condition_cases do
    Map.new(wire_conditions(), fn {id, condition} ->
      {id, condition_case(id, condition)}
    end)
  end

  defp condition_case("anonymous_or_concealed_admin_authentication", condition) do
    fn ->
      conn =
        :put
        |> SigV4Request.anon_conn(@path,
          body: <<0>>,
          headers: [{"content-length", "262273"}, {"transfer-encoding", "chunked"}]
        )
        |> put_archive_test_opts(mutation_response: flunk_response())
        |> attach_body_read_probe()

      response = call_endpoint(conn)
      assert_fixture_condition(response, condition, 1)
      refute_received :body_reader_called
      refute_received {:mutate_many, _groups, _opts}
    end
  end

  defp condition_case("invalid_access_key_authentication", condition) do
    fn ->
      conn =
        signed_put_conn(<<0>>, [{"content-length", "262273"}],
          access_key: "AKIAUNKNOWNCONFIGS7",
          secret: "unknown-config-secret-long-enough"
        )
        |> attach_body_read_probe()

      response = call_endpoint(conn)
      assert_fixture_condition(response, condition, 1)
      refute_received :body_reader_called
      refute_received {:mutate_many, _groups, _opts}
    end
  end

  defp condition_case("signature_mismatch_authentication", condition) do
    fn ->
      conn =
        signed_put_conn(<<0>>, [{"content-length", "262273"}],
          secret: "not-the-config-root-secret"
        )
        |> attach_body_read_probe()

      response = call_endpoint(conn)
      assert_fixture_condition(response, condition, 1)
      refute_received :body_reader_called
      refute_received {:mutate_many, _groups, _opts}
    end
  end

  defp condition_case("valid_identity_denied_ConfigUpdate", condition) do
    fn ->
      {access_key, secret, _arn} = put_action_key(nil)

      conn =
        signed_put_conn(<<0>>, [{"content-length", "262273"}, {"transfer-encoding", "chunked"}],
          access_key: access_key,
          secret: secret
        )
        |> attach_body_read_probe()

      response = call_endpoint(conn)
      assert_fixture_condition(response, condition, 2)
      refute_received :body_reader_called
      refute_received {:mutate_many, _groups, _opts}
    end
  end

  defp condition_case(id, condition)
       when id in [
              "missing_Content-Length",
              "duplicate_Content-Length",
              "malformed_Content-Length",
              "any_Transfer-Encoding"
            ] do
    fn ->
      body = encrypted!(@root_secret, @fresh_archive)

      headers =
        case id do
          "missing_Content-Length" -> []
          "duplicate_Content-Length" -> [{"content-length", "130"}, {"content-length", "130"}]
          "malformed_Content-Length" -> [{"content-length", "-1"}]
          "any_Transfer-Encoding" -> [{"content-length", "130"}, {"transfer-encoding", "chunked"}]
        end

      conn = signed_put_conn(body, headers) |> attach_body_read_probe()
      response = call_endpoint(conn)
      assert_fixture_condition(response, condition, 3)
      refute_received :body_reader_called
      refute_received {:mutate_many, _groups, _opts}
    end
  end

  defp condition_case("actual_ciphertext_length_mismatch", condition) do
    fn ->
      response =
        signed(:put, @path,
          body: <<0>>,
          headers: [{"content-length", "2"}],
          content_sha256_override: String.duplicate("0", 64),
          region: "",
          archive_test_opts: [mutation_response: flunk_response()]
        )

      assert_fixture_condition(response, condition, 4)
      refute_received {:mutate_many, _groups, _opts}
    end
  end

  defp condition_case("SigV4_payload_hash_mismatch", condition) do
    fn ->
      response =
        signed(:put, @path,
          body: <<0>>,
          headers: [{"content-length", "1"}],
          content_sha256_override: String.duplicate("0", 64),
          region: "",
          archive_test_opts: [mutation_response: flunk_response()]
        )

      assert_fixture_condition(response, condition, 5)
      refute_received {:mutate_many, _groups, _opts}
    end
  end

  defp condition_case("malformed_SIO_envelope_or_wrong_caller_secret", condition) do
    fn ->
      response =
        signed(:put, @path,
          body: <<0>>,
          headers: [{"content-length", "1"}],
          region: "",
          archive_test_opts: [mutation_response: flunk_response()]
        )

      assert_fixture_condition(response, condition, 6)
      refute_received {:mutate_many, _groups, _opts}
    end
  end

  defp condition_case("invalid_UTF-8_plaintext", condition) do
    fn ->
      response =
        archive_request(:put,
          plaintext: "fixture-invalid-utf8" <> <<0xFF>> <> "-sentinel",
          mutation_response: flunk_response()
        )

      assert_fixture_condition(response, condition, 7)
      refute_received {:mutate_many, _groups, _opts}
    end
  end

  defp condition_case("plaintext_over_262144", condition) do
    fn ->
      plaintext = :binary.copy(<<"#">>, 261_976)
      ciphertext = encrypted!(@root_secret, plaintext)
      assert byte_size(ciphertext) == expected_first_ciphertext_length(condition["proof"])

      conn =
        signed_put_conn(ciphertext, [{"content-length", Integer.to_string(byte_size(ciphertext))}])
        |> attach_body_read_probe()

      response = call_endpoint(conn)
      assert_fixture_condition(response, condition, 7)
      refute_received :body_reader_called
      refute_received {:mutate_many, _groups, _opts}
    end
  end

  defp condition_case("generic_plaintext_guard_if_called_outside_valid_PUT_SIO_path", condition) do
    fn ->
      error =
        assert_raise Error, fn ->
          Request.encrypt!(
            SigningSecret.new("fixture-server-export-preflight-secret"),
            :binary.copy(<<"#">>, 262_145)
          )
        end

      assert_error_condition(error, condition, 7)
    end
  end

  defp condition_case("document_lexical_or_syntax_parse", condition) do
    fn ->
      plaintext = syntax_before_forbidden_plaintext()

      {response, _log} =
        capture_archive_put_log(
          [plaintext: plaintext, mutation_response: flunk_response()],
          ["forbidden-priority-nine"]
        )

      assert_syntax_precedes_forbidden()
      assert_fixture_condition(response, condition, 8)
      refute_received {:mutate_many, _groups, _opts}
    end
  end

  defp condition_case(id, condition)
       when id in [
              "unknown_subsystem",
              "unknown_key",
              "unknown_prefix",
              "named_target",
              "wire_hidden_path",
              "forbidden_or_sensitive_path"
            ] do
    fn ->
      {plaintext, submitted_values} = exposure_plaintext(id)

      {response, log} =
        capture_archive_put_log(
          [
            plaintext: plaintext,
            mutation_response: flunk_response(),
            request_id: "req-config-archive-condition-#{id}"
          ],
          submitted_values
        )

      if id == "unknown_subsystem" do
        assert log =~ "action=config_import"
        assert log =~ "request_id=req-config-archive-condition-unknown_subsystem"
        assert log =~ "config_subsystem=absent"
      end

      assert_fixture_condition(response, condition, 9)
      refute_received {:mutate_many, _groups, _opts}
    end
  end

  defp condition_case("scalar_or_cross_field_validation", condition) do
    fn ->
      {response, _log} =
        capture_archive_put_log(
          [
            plaintext: "s3 clock_skew_ms=3600001",
            mutation_response: {:error, {:config_store_unavailable, :must_not_be_called}}
          ],
          ["3600001"]
        )

      assert_fixture_condition(response, condition, 10)
      refute_received {:mutate_many, _groups, _opts}
    end
  end

  defp condition_case("database_or_store_failure_before_commit", condition) do
    fn ->
      database_value = unique_clock_skew_sentinel(11)

      {response, _log} =
        capture_archive_put_log(
          [
            plaintext: "s3 clock_skew_ms=#{database_value}",
            mutation_response: {:error, {:config_store_unavailable, :forced}}
          ],
          [database_value]
        )

      assert_fixture_condition(response, condition, 11)
      assert_receive {:mutate_many, _groups, _opts}
      refute_received {:postcommit_attention, _result}
    end
  end

  defp expected_first_ciphertext_length(proof) do
    assert proof =~ "n=261976 yields 262273"
    262_273
  end

  defp run_precedence_case(%{"priority" => 1, "stage" => "authentication"}) do
    condition_case(
      "anonymous_or_concealed_admin_authentication",
      wire_condition!("anonymous_or_concealed_admin_authentication")
    ).()
  end

  defp run_precedence_case(%{
         "priority" => 2,
         "stage" => "admin_ConfigUpdate_authorization"
       }) do
    condition_case(
      "valid_identity_denied_ConfigUpdate",
      wire_condition!("valid_identity_denied_ConfigUpdate")
    ).()
  end

  defp run_precedence_case(%{
         "priority" => 3,
         "stage" => "Content-Length_and_Transfer-Encoding_framing"
       }) do
    body = encrypted!("wrong-priority-three-secret", syntax_before_forbidden_plaintext())

    conn =
      signed_put_conn(body, [
        {"content-length", Integer.to_string(byte_size(body))},
        {"transfer-encoding", "chunked"}
      ])
      |> attach_body_read_probe()

    response = call_endpoint(conn)
    assert_condition(response, "any_Transfer-Encoding")
    refute_received :body_reader_called
    refute_received {:mutate_many, _groups, _opts}
  end

  defp run_precedence_case(%{"priority" => 4, "stage" => "actual_ciphertext_read_length"}) do
    body = encrypted!(@root_secret, syntax_before_forbidden_plaintext())

    response =
      signed(:put, @path,
        body: body,
        headers: [{"content-length", Integer.to_string(byte_size(body) + 1)}],
        content_sha256_override: String.duplicate("0", 64),
        region: "",
        archive_test_opts: [mutation_response: flunk_response()]
      )

    assert_condition(response, "actual_ciphertext_length_mismatch")
    refute_received {:mutate_many, _groups, _opts}
  end

  defp run_precedence_case(%{"priority" => 5, "stage" => "SigV4_payload_hash"}) do
    body = encrypted!(@root_secret, "fixture-priority-five" <> <<0xFF>>)

    response =
      signed(:put, @path,
        body: body,
        headers: [{"content-length", Integer.to_string(byte_size(body))}],
        content_sha256_override: String.duplicate("0", 64),
        region: "",
        archive_test_opts: [mutation_response: flunk_response()]
      )

    assert_condition(response, "SigV4_payload_hash_mismatch")
    refute_received {:mutate_many, _groups, _opts}
  end

  defp run_precedence_case(%{"priority" => 6, "stage" => "SIO_decrypt"}) do
    body = encrypted!("wrong-priority-six-secret", syntax_before_forbidden_plaintext())

    response =
      signed(:put, @path,
        body: body,
        headers: [{"content-length", Integer.to_string(byte_size(body))}],
        region: "",
        archive_test_opts: [mutation_response: flunk_response()]
      )

    assert_condition(response, "malformed_SIO_envelope_or_wrong_caller_secret")
    refute_received {:mutate_many, _groups, _opts}
  end

  defp run_precedence_case(%{"priority" => 7, "stage" => "UTF-8_and_plaintext_size"}) do
    body =
      encrypted!(@root_secret, "fixture-priority-seven" <> <<0xFF>> <> " root_password=forbidden")

    response =
      signed(:put, @path,
        body: body,
        headers: [{"content-length", Integer.to_string(byte_size(body))}],
        region: "",
        archive_test_opts: [mutation_response: flunk_response()]
      )

    assert_condition(response, "invalid_UTF-8_plaintext")
    refute_received {:mutate_many, _groups, _opts}
  end

  defp run_precedence_case(%{
         "priority" => 8,
         "stage" => "document_lexical_and_syntax_parse"
       }) do
    assert_syntax_precedes_forbidden()

    response =
      archive_request(:put,
        plaintext: syntax_before_forbidden_plaintext(),
        mutation_response: flunk_response()
      )

    assert_condition(response, "document_lexical_or_syntax_parse")
    refute_received {:mutate_many, _groups, _opts}
  end

  defp run_precedence_case(%{
         "priority" => 9,
         "stage" => "target_unknown_hidden_forbidden_exposure"
       }) do
    response =
      archive_request(:put,
        plaintext: "s3 root_password=forbidden clock_skew_ms=3600001",
        mutation_response: {:error, {:config_store_unavailable, :must_not_be_called}}
      )

    assert_condition(response, "forbidden_or_sensitive_path")
    refute_received {:mutate_many, _groups, _opts}
  end

  defp run_precedence_case(%{
         "priority" => 10,
         "stage" => "scalar_and_cross_field_validation"
       }) do
    response =
      archive_request(:put,
        plaintext: "s3 clock_skew_ms=3600001",
        mutation_response: {:error, {:config_store_unavailable, :must_not_be_called}}
      )

    assert_condition(response, "scalar_or_cross_field_validation")
    refute_received {:mutate_many, _groups, _opts}
  end

  defp run_precedence_case(%{
         "priority" => 11,
         "stage" => "database_transaction_and_store"
       }) do
    response =
      archive_request(:put,
        plaintext: "s3 clock_skew_ms=2300011",
        mutation_response: {:error, {:config_store_unavailable, :forced}},
        postcommit_probe: :armed
      )

    assert_condition(response, "database_or_store_failure_before_commit")
    assert_receive {:mutate_many, _groups, opts}
    assert Keyword.fetch!(opts, :postcommit_probe) == :armed
    refute_received {:postcommit_attention, _result}
  end

  defp run_precedence_case(%{
         "priority" => 12,
         "stage" => "postcommit_reload_and_broadcast"
       }) do
    postcommit_value = unique_clock_skew_sentinel(12)

    {response, log} =
      capture_archive_put_log(
        [
          plaintext: "s3 clock_skew_ms=#{postcommit_value}",
          mutation_response: {:ok, attention_result()},
          postcommit_probe: :armed
        ],
        [postcommit_value]
      )

    outcome = get_in(@wire_contract, ["error_map_contract", "postcommit_outcome_contract"])
    assert log =~ "committed=true"
    assert log =~ "config_attention=true"
    assert response.status == outcome["http_outcome"]["status"]
    assert byte_size(response.resp_body) == outcome["http_outcome"]["body_bytes"]
    assert get_resp_header(response, "x-minio-config-applied") == []
    assert_receive {:postcommit_attention, result}
    assert result.local_reload == {:error, :reload_failed}
    assert result.broadcast == {:error, :broadcast_failed}
  end

  defp syntax_before_forbidden_plaintext do
    "s3 clock_skew_ms\ns3 root_password=forbidden-priority-nine"
  end

  defp exposure_plaintext(id) do
    scalar = "ARCHIVE-#{id}-#{System.unique_integer([:positive, :monotonic])}"

    plaintext =
      case id do
        "unknown_subsystem" -> "absent value=#{scalar}"
        "unknown_key" -> "s3 absent=#{scalar}"
        "unknown_prefix" -> "s3 absent=#{scalar} clock_skew_ms=1000"
        "named_target" -> "s3:secondary clock_skew_ms=#{scalar}"
        "wire_hidden_path" -> "cluster deployment_id=#{scalar}"
        "forbidden_or_sensitive_path" -> "s3 root_password=#{scalar}"
      end

    {plaintext, [scalar]}
  end

  defp capture_archive_put_log(opts, submitted_values) do
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)

    {request, body} = archive_put_conn(opts)
    {authorization, signature} = authorization_material(request)
    owner = self()
    reference = make_ref()

    log =
      capture_log([level: :info], fn ->
        send(owner, {reference, call_endpoint(request)})
      end)

    assert_receive {^reference, response}
    plaintext = Keyword.fetch!(opts, :plaintext)

    refute_wire_material(
      log <> response.resp_body,
      body,
      authorization,
      signature,
      [Keyword.get(opts, :secret, @root_secret)]
    )

    for protected <- [plaintext, inspect(plaintext)] ++ submitted_values do
      refute log =~ protected
      refute response.resp_body =~ protected
    end

    {response, log}
  end

  defp assert_syntax_precedes_forbidden do
    assert {:error, %{reason: :config_bad_json, stage: :parser}} =
             Archive.decode_and_plan(syntax_before_forbidden_plaintext())
  end

  defp unique_clock_skew_sentinel(offset) do
    value = 2_000_000 + rem(System.unique_integer([:positive, :monotonic]) + offset, 1_000_000)
    Integer.to_string(value)
  end

  test "only exact GET and PUT config routes are claimed; adjacent routes retain Admin fallback" do
    get = archive_request(:get, snapshot_response: {:ok, @fresh_snapshot})
    assert get.status == 200
    assert {:ok, @fresh_archive} = decrypt(get, @root_secret)
    assert_receive {:authoritative_snapshot, _paths, _opts}

    put =
      archive_request(:put,
        plaintext: @fresh_archive,
        mutation_response: {:ok, committed_result()}
      )

    assert put.status == 200
    assert_receive {:mutate_many, _groups, _opts}

    for {method, path} <- [
          {:post, @path},
          {:delete, @path},
          {:get, @path <> "/extra"},
          {:put, @path <> "/extra"},
          {:get, "/minio/admin/v4/config"},
          {:put, "/minio/admin/v4/config"},
          {:get, "/minio/admin/v3/config-history"}
        ] do
      response = signed(method, path, region: "")
      assert response.status == 501
      assert Jason.decode!(response.resp_body)["Code"] == "NotImplemented"
    end
  end

  test "anonymous invalid-key and denied imports fail before body read or Archive" do
    ciphertext = encrypted!(@root_secret, "s3 clock_skew_ms=not-an-integer")

    anonymous =
      :put
      |> SigV4Request.anon_conn(@path,
        body: ciphertext,
        headers: [
          {"content-length", "262273"},
          {"transfer-encoding", "chunked"},
          {"x-request-id", "req-config-archive-anonymous"}
        ]
      )
      |> put_archive_test_opts(mutation_response: flunk_response())
      |> attach_body_read_probe()
      |> Endpoint.call(Endpoint.init([]))

    assert_condition(anonymous, "anonymous_or_concealed_admin_authentication")
    refute_received :body_reader_called
    refute_received {:mutate_many, _groups, _opts}

    invalid_key_request =
      :put
      |> SigV4Request.signed_conn(@path,
        body: ciphertext,
        headers: [{"content-length", "262273"}],
        access_key: "AKIAUNKNOWNCONFIGS7",
        secret: "unknown-config-secret-long-enough",
        region: ""
      )
      |> put_archive_test_opts(mutation_response: flunk_response())
      |> attach_body_read_probe()

    invalid_key = Endpoint.call(invalid_key_request, Endpoint.init([]))
    assert_condition(invalid_key, "invalid_access_key_authentication")
    refute_received :body_reader_called
    refute_received {:mutate_many, _groups, _opts}

    signature_request =
      :put
      |> SigV4Request.signed_conn(@path,
        body: ciphertext,
        headers: [{"content-length", "262273"}],
        secret: "not-the-config-root-secret",
        region: ""
      )
      |> put_archive_test_opts(mutation_response: flunk_response())
      |> attach_body_read_probe()

    signature = Endpoint.call(signature_request, Endpoint.init([]))
    assert_condition(signature, "signature_mismatch_authentication")
    refute_received :body_reader_called
    refute_received {:mutate_many, _groups, _opts}

    {access_key, secret, _arn} = put_action_key(nil)

    denied_request =
      :put
      |> SigV4Request.signed_conn(@path,
        body: ciphertext,
        headers: [
          {"content-length", "262273"},
          {"transfer-encoding", "chunked"}
        ],
        access_key: access_key,
        secret: secret,
        region: ""
      )
      |> put_archive_test_opts(mutation_response: flunk_response())
      |> attach_body_read_probe()

    denied = Endpoint.call(denied_request, Endpoint.init([]))
    assert_condition(denied, "valid_identity_denied_ConfigUpdate")
    refute_received :body_reader_called
    refute_received {:mutate_many, _groups, _opts}
  end

  test "root and authorized identities use only admin:ConfigUpdate for both routes" do
    root_get = archive_request(:get, snapshot_response: {:ok, @fresh_snapshot})
    assert root_get.status == 200

    {access_key, secret, _arn} = put_action_key("admin:ConfigUpdate")

    allowed_get =
      archive_request(:get,
        access_key: access_key,
        secret: secret,
        snapshot_response: {:ok, @fresh_snapshot}
      )

    assert allowed_get.status == 200
    assert {:ok, @fresh_archive} = decrypt(allowed_get, secret)

    allowed_put =
      archive_request(:put,
        access_key: access_key,
        secret: secret,
        plaintext: @fresh_archive,
        mutation_response: {:ok, committed_result()}
      )

    assert allowed_put.status == 200

    {wrong_key, wrong_secret, _arn} = put_action_key("admin:GetConfig")

    for method <- [:get, :put] do
      response =
        archive_request(method,
          access_key: wrong_key,
          secret: wrong_secret,
          plaintext: @fresh_archive,
          snapshot_response: flunk_response(),
          mutation_response: flunk_response()
        )

      assert_condition(response, "valid_identity_denied_ConfigUpdate")
    end
  end

  test "caller A and B ciphertext is isolated from each other and the configured root secret" do
    {key_a, secret_a, _arn} = put_action_key("admin:ConfigUpdate")
    {_key_b, secret_b, _arn} = put_action_key("admin:ConfigUpdate")

    owner = self()

    get_conn =
      archive_get_conn(
        access_key: key_a,
        secret: secret_a,
        snapshot_response: {:ok, @fresh_snapshot}
      )

    {get_authorization, get_signature} = authorization_material(get_conn)

    get_log =
      capture_log(fn ->
        send(owner, {:caller_a_get, call_endpoint(get_conn)})
      end)

    assert_receive {:caller_a_get, get_a}

    refute_wire_material(
      get_log,
      get_a.resp_body,
      get_authorization,
      get_signature,
      [secret_a, secret_b, @root_secret]
    )

    assert {:ok, @fresh_archive} = decrypt(get_a, secret_a)
    assert {:error, :not_authentic} = decrypt(get_a, secret_b)
    assert {:error, :not_authentic} = decrypt(get_a, @root_secret)

    for {label, encryption_secret} <- [b: secret_b, root: @root_secret] do
      body = encrypted!(encryption_secret, @fresh_archive)

      request =
        signed_conn(:put, @path,
          body: body,
          headers: [{"content-length", Integer.to_string(byte_size(body))}],
          access_key: key_a,
          secret: secret_a,
          region: "",
          archive_test_opts: [mutation_response: flunk_response()]
        )

      {authorization, signature} = authorization_material(request)

      log =
        capture_log(fn ->
          send(owner, {:wrong_envelope_response, label, call_endpoint(request)})
        end)

      assert_receive {:wrong_envelope_response, ^label, response}

      refute_wire_material(
        log <> response.resp_body,
        body,
        authorization,
        signature,
        [secret_a, secret_b, @root_secret]
      )

      assert_condition(response, "malformed_SIO_envelope_or_wrong_caller_secret")
      refute_received {:mutate_many, _groups, _opts}, inspect(label)
    end
  end

  test "import framing requires one decimal Content-Length and rejects every Transfer-Encoding" do
    valid = encrypted!(@root_secret, @fresh_archive)

    invalid_headers = [
      {"missing_Content-Length", []},
      {"duplicate_Content-Length",
       [
         {"content-length", Integer.to_string(byte_size(valid))},
         {"content-length", Integer.to_string(byte_size(valid))}
       ]},
      {"malformed_Content-Length", [{"content-length", "-1"}]},
      {"malformed_Content-Length", [{"content-length", "+1"}]},
      {"malformed_Content-Length", [{"content-length", "1.0"}]},
      {"malformed_Content-Length", [{"content-length", "not-decimal"}]},
      {"malformed_Content-Length", [{"content-length", "262273"}]},
      {"any_Transfer-Encoding",
       [
         {"content-length", Integer.to_string(byte_size(valid))},
         {"transfer-encoding", "chunked"}
       ]},
      {"any_Transfer-Encoding",
       [
         {"content-length", Integer.to_string(byte_size(valid))},
         {"transfer-encoding", "identity"}
       ]},
      {"any_Transfer-Encoding",
       [
         {"content-length", Integer.to_string(byte_size(valid))},
         {"transfer-encoding", ""}
       ]}
    ]

    for {{condition_id, headers}, index} <- Enum.with_index(invalid_headers, 1) do
      request =
        :put
        |> SigV4Request.signed_conn(@path,
          body: valid,
          headers: headers ++ [{"x-request-id", "req-config-archive-framing-#{index}"}],
          region: ""
        )
        |> put_archive_test_opts(mutation_response: flunk_response())
        |> attach_body_read_probe()

      response = Endpoint.call(request, Endpoint.init([]))
      assert_condition(response, condition_id)
      refute_received :body_reader_called
      refute_received {:mutate_many, _groups, _opts}
    end
  end

  test "actual length hash decrypt UTF-8 and parse failures keep first-failure priority" do
    zero =
      signed(:put, @path,
        body: <<>>,
        headers: [{"content-length", "0"}],
        region: "",
        archive_test_opts: [mutation_response: flunk_response()]
      )

    assert_condition(zero, "malformed_SIO_envelope_or_wrong_caller_secret")

    length_mismatch =
      signed(:put, @path,
        body: <<0>>,
        headers: [{"content-length", "2"}],
        content_sha256_override: String.duplicate("0", 64),
        region: "",
        archive_test_opts: [mutation_response: flunk_response()]
      )

    assert_condition(length_mismatch, "actual_ciphertext_length_mismatch")

    hash_mismatch =
      signed(:put, @path,
        body: <<0>>,
        headers: [{"content-length", "1"}],
        content_sha256_override: String.duplicate("0", 64),
        region: "",
        archive_test_opts: [mutation_response: flunk_response()]
      )

    assert_condition(hash_mismatch, "SigV4_payload_hash_mismatch")

    malformed_sio =
      signed(:put, @path,
        body: <<0>>,
        headers: [{"content-length", "1"}],
        region: "",
        archive_test_opts: [mutation_response: flunk_response()]
      )

    assert_condition(malformed_sio, "malformed_SIO_envelope_or_wrong_caller_secret")

    invalid_utf8 = "UTF8-CONFIG-SENTINEL" <> <<0xFF>> <> " s3 root_password=forbidden"

    utf8_response =
      archive_request(:put,
        plaintext: invalid_utf8,
        mutation_response: flunk_response()
      )

    assert_condition(utf8_response, "invalid_UTF-8_plaintext")
    refute_received {:mutate_many, _groups, _opts}

    parse_before_exposure =
      archive_request(:put,
        plaintext: "s3:secondary\n s3 root_password=forbidden",
        mutation_response: flunk_response()
      )

    assert_condition(parse_before_exposure, "named_target")

    exposure_before_type =
      archive_request(:put,
        plaintext: "s3 root_password=forbidden clock_skew_ms=not-an-integer",
        mutation_response: flunk_response()
      )

    assert_condition(exposure_before_type, "forbidden_or_sensitive_path")

    type_before_database =
      archive_request(:put,
        plaintext: "s3 clock_skew_ms=not-an-integer",
        mutation_response: {:error, {:config_store_unavailable, :forced}}
      )

    assert_condition(type_before_database, "scalar_or_cross_field_validation")
    refute_received {:mutate_many, _groups, _opts}
  end

  test "ciphertext limit rejects 261976 and 262144 before decrypt while 261975 is reachable" do
    for {plaintext_size, ciphertext_size, expected} <- [
          {261_975, 262_272, :accepted},
          {261_976, 262_273, :too_large},
          {262_144, 262_441, :too_large}
        ] do
      plaintext = :binary.copy(<<"#">>, plaintext_size)
      ciphertext = encrypted!(@root_secret, plaintext)
      assert byte_size(ciphertext) == ciphertext_size

      response =
        signed(:put, @path,
          body: ciphertext,
          headers: [{"content-length", Integer.to_string(ciphertext_size)}],
          region: "",
          archive_test_opts: [mutation_response: {:ok, committed_result()}]
        )

      case expected do
        :accepted ->
          assert response.status == 200
          assert_receive {:mutate_many, _groups, _opts}

        :too_large ->
          assert_admin_error(response, 400, "XMinioAdminConfigTooLarge", @too_large)
          refute_received {:mutate_many, _groups, _opts}
      end
    end
  end

  test "GET decrypts to the exact archive and has randomized exact untransformed framing" do
    responses =
      for _attempt <- 1..2 do
        archive_request(:get, snapshot_response: {:ok, @fresh_snapshot})
      end

    [first, second] = responses
    refute first.resp_body == second.resp_body

    for response <- responses do
      assert response.status == 200
      assert {:ok, @fresh_archive} = decrypt(response, @root_secret)
      assert byte_size(response.resp_body) == 146
      assert get_resp_header(response, "content-length") == ["146"]
      assert get_resp_header(response, "content-type") == ["application/json"]
      assert get_resp_header(response, "transfer-encoding") == []
      assert get_resp_header(response, "content-encoding") == []

      assert response
             |> get_resp_header("cache-control")
             |> Enum.flat_map(&Plug.Conn.Utils.list/1)
             |> Enum.member?("no-transform")
    end
  end

  test "PUT returns empty 200 with no applied claim and exposes the committed postcommit result" do
    mutation = committed_result()

    response =
      archive_request(:put,
        plaintext: @fresh_archive,
        mutation_response: {:ok, mutation}
      )

    assert response.status == 200
    assert response.resp_body == ""
    assert get_resp_header(response, "content-length") == ["0"]
    assert get_resp_header(response, "transfer-encoding") == []
    assert get_resp_header(response, "content-encoding") == []
    assert get_resp_header(response, "content-type") == []
    assert get_resp_header(response, "x-minio-config-applied") == []

    assert_receive {:mutate_many, groups, opts}
    assert Keyword.fetch!(opts, :source) == "admin_api"
    assert is_binary(Keyword.fetch!(opts, :source))
    assert length(groups) == 3

    attention = %{
      mutation
      | local_reload: {:error, :reload_failed},
        broadcast: {:error, :broadcast_failed},
        attention?: true
    }

    attention_response =
      archive_request(:put,
        plaintext: @fresh_archive,
        mutation_response: {:ok, attention}
      )

    assert attention_response.status == 200
    assert attention_response.resp_body == ""
    assert get_resp_header(attention_response, "x-minio-config-applied") == []
    refute attention_response.resp_body =~ "InternalError"
  end

  # The test module itself is the injected Config facade. This keeps the fake at the Archive
  # boundary and avoids adding a production hook or a second module to this test file.
  def authoritative_snapshot(paths, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:authoritative_snapshot, paths, opts})
    Keyword.fetch!(opts, :snapshot_response)
  end

  def mutate_many(groups, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:mutate_many, groups, opts})
    response = Keyword.fetch!(opts, :mutation_response)

    case {Keyword.get(opts, :postcommit_probe), response} do
      {:armed, {:ok, %{attention?: true} = result}} ->
        send(Keyword.fetch!(opts, :test_pid), {:postcommit_attention, result})

      _other ->
        :ok
    end

    response
  end

  defp archive_request(:get, opts) do
    opts
    |> archive_get_conn()
    |> call_endpoint()
  end

  defp archive_request(:put, opts) do
    {conn, _ciphertext} = archive_put_conn(opts)
    call_endpoint(conn)
  end

  defp archive_get_conn(opts) do
    request_opts =
      [
        secret: Keyword.get(opts, :secret, @root_secret),
        region: "",
        archive_test_opts: [
          config: __MODULE__,
          test_pid: self(),
          snapshot_response: Keyword.fetch!(opts, :snapshot_response)
        ]
      ]
      |> maybe_put_access_key(opts)

    signed_conn(:get, @path, request_opts)
  end

  defp archive_put_conn(opts) do
    secret = Keyword.get(opts, :secret, @root_secret)
    plaintext = Keyword.fetch!(opts, :plaintext)
    ciphertext = encrypted!(secret, plaintext)

    headers =
      [{"content-length", Integer.to_string(byte_size(ciphertext))}]
      |> maybe_add_request_id(Keyword.get(opts, :request_id))

    request_opts =
      [
        body: ciphertext,
        headers: headers,
        secret: secret,
        region: "",
        archive_test_opts:
          [
            config: __MODULE__,
            test_pid: self(),
            mutation_response: Keyword.fetch!(opts, :mutation_response)
          ]
          |> maybe_put_postcommit_probe(opts)
      ]
      |> maybe_put_access_key(opts)

    {signed_conn(:put, @path, request_opts), ciphertext}
  end

  defp signed(method, path, opts) do
    method
    |> signed_conn(path, opts)
    |> call_endpoint()
  end

  defp signed_conn(method, path, opts) do
    {archive_opts, request_opts} = Keyword.pop(opts, :archive_test_opts, [])

    method
    |> SigV4Request.signed_conn(path, request_opts)
    |> put_archive_test_opts(archive_opts)
  end

  defp signed_put_conn(body, headers, opts \\ []) do
    request_opts =
      [
        body: body,
        headers: headers,
        region: "",
        archive_test_opts: [mutation_response: flunk_response()]
      ]
      |> Keyword.merge(opts)

    signed_conn(:put, @path, request_opts)
  end

  defp call_endpoint(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp authorization_material(conn) do
    [authorization] = get_req_header(conn, "authorization")
    [signature] = Regex.run(~r/Signature=([0-9a-f]{64})/, authorization, capture: :all_but_first)
    {authorization, signature}
  end

  defp refute_wire_material(haystack, body, authorization, signature, secrets) do
    protected =
      [
        body,
        inspect(body),
        Base.encode16(body, case: :lower),
        Base.encode16(body, case: :upper),
        Base.encode64(body),
        authorization,
        signature
      ] ++ secrets

    for material <- protected do
      refute haystack =~ material
    end
  end

  defp put_archive_test_opts(conn, opts),
    do: put_private(conn, :maxio_config_kv_test_opts, opts)

  defp attach_body_read_probe(conn) do
    {_adapter, state} = conn.adapter
    %{conn | adapter: {Maxio.Test.BodyReadProbeAdapter, {self(), state}}}
  end

  defp put_action_key(action) do
    suffix = System.unique_integer([:positive, :monotonic])
    access_key = String.pad_trailing("AKIACONFIGS7#{suffix}", 20, "X")
    secret = "admin-config-s7-secret-#{suffix}-long-enough"
    arn = IAM.user_arn(access_key)

    assert {:ok, %{user_name: ^access_key}} = IAM.create_user(name: access_key)

    :ok =
      CredentialStore.put_access_key(%{
        access_key: access_key,
        secret_key: secret,
        principal: %{type: :iam_user, access_key: access_key, arn: arn}
      })

    if action do
      :ok =
        PolicyStore.put_principal_policy(
          arn,
          "config-s7-#{suffix}",
          Jason.encode!(%{
            "Version" => "2012-10-17",
            "Statement" => [%{"Effect" => "Allow", "Action" => action}]
          })
        )
    end

    {access_key, secret, arn}
  end

  defp encrypted!(secret, plaintext) do
    assert {:ok, ciphertext} = Envelope.encrypt(SigningSecret.new(secret), plaintext)
    ciphertext
  end

  defp decrypt(response, secret),
    do: Envelope.decrypt(SigningSecret.new(secret), response.resp_body)

  defp committed_result do
    %{
      committed?: true,
      touched_subsystems: [:listing, :prometheus_metrics, :s3],
      changed_subsystems: [:listing, :prometheus_metrics, :s3],
      changed_count: 3,
      changed_paths: [
        {:listing, :sql_hard_limit},
        {:prometheus_metrics, :public},
        {:s3, :clock_skew_ms}
      ],
      outcomes: %{},
      local_reload: :ok,
      broadcast: :ok,
      attention?: false
    }
  end

  defp attention_result do
    %{
      committed_result()
      | local_reload: {:error, :reload_failed},
        broadcast: {:error, :broadcast_failed},
        attention?: true
    }
  end

  defp flunk_response, do: {:error, {:config_store_unavailable, :must_not_be_called}}

  defp maybe_add_request_id(headers, nil), do: headers
  defp maybe_add_request_id(headers, request_id), do: headers ++ [{"x-request-id", request_id}]

  defp maybe_put_postcommit_probe(archive_opts, opts) do
    case Keyword.fetch(opts, :postcommit_probe) do
      {:ok, probe} -> Keyword.put(archive_opts, :postcommit_probe, probe)
      :error -> archive_opts
    end
  end

  defp maybe_put_access_key(request_opts, opts) do
    case Keyword.fetch(opts, :access_key) do
      {:ok, access_key} -> Keyword.put(request_opts, :access_key, access_key)
      :error -> request_opts
    end
  end

  defp assert_admin_error(conn, status, code, message) do
    assert conn.status == status
    body = Jason.decode!(conn.resp_body)
    assert body["Code"] == code
    assert body["Message"] == message
  end

  defp assert_fixture_condition(conn, condition, priority) do
    assert condition["priority"] == priority
    assert_condition(conn, condition)
  end

  defp assert_error_condition(error, condition, priority) do
    assert condition["priority"] == priority
    assert error.http_status == Map.get(condition, "status", condition["pre_decrypt_status"])
    assert error.code == Map.get(condition, "code", condition["pre_decrypt_code"])
    assert error.message == Map.get(condition, "message", condition["pre_decrypt_message"])
  end

  defp assert_condition(conn, condition_id) when is_binary(condition_id) do
    assert_condition(conn, wire_condition!(condition_id))
  end

  defp assert_condition(conn, condition) when is_map(condition) do
    condition_id = condition["id"]
    expected_status = Map.get(condition, "status", condition["pre_decrypt_status"])
    expected_code = Map.get(condition, "code", condition["pre_decrypt_code"])
    expected_message = Map.get(condition, "message", condition["pre_decrypt_message"])

    assert conn.status == expected_status, condition_id

    case Jason.decode(conn.resp_body) do
      {:ok, body} ->
        assert body["Code"] == expected_code, condition_id
        assert body["Message"] == expected_message, condition_id

      {:error, _reason} ->
        assert conn.resp_body =~ "<Code>#{expected_code}</Code>", condition_id
        assert conn.resp_body =~ "<Message>#{expected_message}</Message>", condition_id
    end
  end

  defp wire_conditions do
    @fixture_conditions
    |> Map.new(&{&1["id"], &1})
  end

  defp wire_condition!(condition_id), do: Map.fetch!(wire_conditions(), condition_id)
end
