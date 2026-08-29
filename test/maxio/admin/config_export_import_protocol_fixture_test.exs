defmodule Maxio.Admin.ConfigExportImportProtocolFixtureTest do
  use ExUnit.Case, async: true

  @fixture_dir Path.expand("../../fixtures/minio_admin_config_export_import_s7", __DIR__)
  @fixture_files [
    "minio_config_archive_wire.json",
    "madmin_config_archive_limits.json",
    "mc_config_archive_dispatch.json",
    "raw_sha256.json"
  ]
  @schemas %{
    "minio_config_archive_wire.json" => "maxio.minio_config_archive_wire.v1",
    "madmin_config_archive_limits.json" => "maxio.madmin_config_archive_limits.v1",
    "mc_config_archive_dispatch.json" => "maxio.mc_config_archive_dispatch.v1",
    "raw_sha256.json" => "maxio.raw_sha256.v1"
  }
  @pins %{
    "minio" => "7aac2a2c5b7c882e68c1ce017d8256be2feea27f",
    "madmin_go" => "4b504b82db633e978a57d49443b2be75824244c3",
    "mc" => "77f82e18b5401a65958f1619df6ebb994634bd88",
    "sio_go" => "a455d2cd8fcacdfe18557d117db15c0629fb7e2c"
  }
  @allowed_decision_evidence ["source_verified", "live_verified", "local_design_expected"]
  @archive_sha "c8fe86493cce0083169223b68b59e69612ceeaff7ff45721b45eb85e7eff4141"
  @error_precedence [
    %{"priority" => 1, "stage" => "authentication"},
    %{"priority" => 2, "stage" => "admin_ConfigUpdate_authorization"},
    %{"priority" => 3, "stage" => "Content-Length_and_Transfer-Encoding_framing"},
    %{"priority" => 4, "stage" => "actual_ciphertext_read_length"},
    %{"priority" => 5, "stage" => "SigV4_payload_hash"},
    %{"priority" => 6, "stage" => "SIO_decrypt"},
    %{"priority" => 7, "stage" => "UTF-8_and_plaintext_size"},
    %{"priority" => 8, "stage" => "document_lexical_and_syntax_parse"},
    %{"priority" => 9, "stage" => "target_unknown_hidden_forbidden_exposure"},
    %{"priority" => 10, "stage" => "scalar_and_cross_field_validation"},
    %{"priority" => 11, "stage" => "database_transaction_and_store"},
    %{"priority" => 12, "stage" => "postcommit_reload_and_broadcast"}
  ]
  @error_conditions [
    %{
      "id" => "anonymous_or_concealed_admin_authentication",
      "priority" => 1,
      "evidence_class" => "existing_contract_verified",
      "status" => 403,
      "code" => "AccessDenied",
      "message" => "Access Denied",
      "representative_input" => nil
    },
    %{
      "id" => "invalid_access_key_authentication",
      "priority" => 1,
      "evidence_class" => "existing_contract_verified",
      "status" => 403,
      "code" => "InvalidAccessKeyId",
      "message" => "The AWS access key ID that you provided does not exist in our records.",
      "representative_input" => nil
    },
    %{
      "id" => "signature_mismatch_authentication",
      "priority" => 1,
      "evidence_class" => "existing_contract_verified",
      "status" => 403,
      "code" => "SignatureDoesNotMatch",
      "message" =>
        "The request signature that the server calculated does not match the signature that you provided. Check your AWS secret access key and signing method.",
      "representative_input" => nil
    },
    %{
      "id" => "valid_identity_denied_ConfigUpdate",
      "priority" => 2,
      "evidence_class" => "source_verified",
      "status" => 403,
      "code" => "AccessDenied",
      "message" => "Access Denied",
      "representative_input" => nil
    },
    %{
      "id" => "missing_Content-Length",
      "priority" => 3,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XMinioAdminConfigTooLarge",
      "message" => "Configuration data provided exceeds the allowed maximum of 262272 bytes",
      "representative_input" => nil
    },
    %{
      "id" => "duplicate_Content-Length",
      "priority" => 3,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XMinioAdminConfigTooLarge",
      "message" => "Configuration data provided exceeds the allowed maximum of 262272 bytes",
      "representative_input" => nil
    },
    %{
      "id" => "malformed_Content-Length",
      "priority" => 3,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XMinioAdminConfigTooLarge",
      "message" => "Configuration data provided exceeds the allowed maximum of 262272 bytes",
      "representative_input" => ["-1", "+1", "1.0", "non_decimal", "262273_or_more"]
    },
    %{
      "id" => "any_Transfer-Encoding",
      "priority" => 3,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XMinioAdminConfigTooLarge",
      "message" => "Configuration data provided exceeds the allowed maximum of 262272 bytes",
      "representative_input" => nil
    },
    %{
      "id" => "actual_ciphertext_length_mismatch",
      "priority" => 4,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XMinioAdminConfigBadJSON",
      "message" => "JSON configuration provided is of incorrect format",
      "representative_input" => nil
    },
    %{
      "id" => "SigV4_payload_hash_mismatch",
      "priority" => 5,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XAmzContentSHA256Mismatch",
      "message" =>
        "The provided 'x-amz-content-sha256' header does not match what was computed.",
      "representative_input" => nil
    },
    %{
      "id" => "malformed_SIO_envelope_or_wrong_caller_secret",
      "priority" => 6,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XMinioAdminConfigBadJSON",
      "message" => "JSON configuration provided is of incorrect format",
      "representative_input" => nil
    },
    %{
      "id" => "invalid_UTF-8_plaintext",
      "priority" => 7,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XMinioAdminConfigBadJSON",
      "message" => "JSON configuration provided is of incorrect format",
      "representative_input" => nil
    },
    %{
      "id" => "plaintext_over_262144",
      "priority" => 7,
      "evidence_class" => "source_verified",
      "status" => 400,
      "code" => "XMinioAdminConfigTooLarge",
      "message" => "Configuration data provided exceeds the allowed maximum of 262272 bytes",
      "representative_input" => nil
    },
    %{
      "id" => "generic_plaintext_guard_if_called_outside_valid_PUT_SIO_path",
      "priority" => 7,
      "evidence_class" => "local_design_expected",
      "status" => 400,
      "code" => "XMinioAdminConfigTooLarge",
      "message" => "Configuration data provided exceeds the allowed maximum of 262272 bytes",
      "representative_input" => nil
    },
    %{
      "id" => "document_lexical_or_syntax_parse",
      "priority" => 8,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XMinioAdminConfigBadJSON",
      "message" => "JSON configuration provided is of incorrect format",
      "representative_input" => nil
    },
    %{
      "id" => "unknown_subsystem",
      "priority" => 9,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XMinioConfigError",
      "message" => "unknown sub-system absent value=1",
      "representative_input" => "absent value=1"
    },
    %{
      "id" => "unknown_key",
      "priority" => 9,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XMinioConfigError",
      "message" => "sub-system 's3' cannot have empty keys",
      "representative_input" => "s3 absent=1"
    },
    %{
      "id" => "unknown_prefix",
      "priority" => 9,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XMinioAdminConfigBadJSON",
      "message" => "JSON configuration provided is of incorrect format",
      "representative_input" => "s3 absent=1 clock_skew_ms=1000"
    },
    %{
      "id" => "named_target",
      "priority" => 9,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XMinioAdminInvalidArgument",
      "message" => "Invalid arguments specified.",
      "representative_input" => "s3:secondary clock_skew_ms=1000"
    },
    %{
      "id" => "wire_hidden_path",
      "priority" => 9,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XMinioConfigError",
      "message" => "Configuration specified is invalid",
      "representative_input" => "cluster deployment_id=replacement"
    },
    %{
      "id" => "forbidden_or_sensitive_path",
      "priority" => 9,
      "evidence_class" => "existing_contract_verified",
      "status" => 403,
      "code" => "AccessDenied",
      "message" => "Access Denied",
      "representative_input" => "s3 root_password=redacted"
    },
    %{
      "id" => "scalar_or_cross_field_validation",
      "priority" => 10,
      "evidence_class" => "existing_contract_verified",
      "status" => 400,
      "code" => "XMinioAdminConfigBadJSON",
      "message" => "JSON configuration provided is of incorrect format",
      "representative_input" => nil
    },
    %{
      "id" => "database_or_store_failure_before_commit",
      "priority" => 11,
      "evidence_class" => "existing_contract_verified",
      "status" => 500,
      "code" => "InternalError",
      "message" => "An internal error occurred. Try again.",
      "representative_input" => nil
    }
  ]

  setup_all do
    fixtures = Map.new(@fixture_files, &{&1, fixture(&1)})
    {:ok, fixtures: fixtures}
  end

  test "all four fixtures keep their schemas, source pins, and immutable source URLs", %{
    fixtures: fixtures
  } do
    assert Map.new(fixtures, fn {file, document} -> {file, document["schema"]} end) == @schemas

    wire = fixtures["minio_config_archive_wire.json"]
    limits = fixtures["madmin_config_archive_limits.json"]
    dispatch = fixtures["mc_config_archive_dispatch.json"]
    integrity = fixtures["raw_sha256.json"]

    assert wire["pins"]["minio"] == @pins["minio"]
    assert wire["pins"]["madmin_go"] == @pins["madmin_go"]
    assert wire["pins"]["mc"] == @pins["mc"]
    assert wire["pins"]["sio_go"]["commit"] == @pins["sio_go"]
    assert limits["pins"]["madmin_go"] == @pins["madmin_go"]
    assert limits["pins"]["sio_go_commit"] == @pins["sio_go"]
    assert dispatch["pin"]["commit"] == @pins["mc"]

    assert Map.new(integrity["repositories"], fn {id, source} ->
             {id, source["commit"]}
           end) == @pins

    missing_or_mutable_urls =
      integrity["sources"]
      |> Enum.flat_map(fn {source_id, source} ->
        repository = integrity["repositories"][source["repository"]]
        expected_url = immutable_raw_url(repository, source["file"])

        case source["url"] do
          ^expected_url -> []
          actual -> [{source_id, actual, expected_url}]
        end
      end)

    assert missing_or_mutable_urls == []

    for url <- collect_url_values(fixtures) do
      refute Regex.match?(~r{/(?:master|main|latest|HEAD)/}i, url)
    end
  end

  test "fresh archive decodes to exactly 89 bytes with three LF and no CR", %{fixtures: fixtures} do
    archive = fixtures["minio_config_archive_wire.json"]["fresh_archive"]
    payload = Base.decode64!(archive["bytes_base64"])

    assert archive["evidence_class"] == "local_design_expected"
    assert archive["upstream_minio_default_export_claim"] == false
    assert payload ==
             "s3 clock_skew_ms=900000 \n" <>
               "listing sql_hard_limit=100000 \n" <>
               "prometheus_metrics public=false \n"

    assert byte_size(payload) == archive["byte_length"]
    assert byte_size(payload) == 89
    assert count_byte(payload, ?\n) == 3
    assert count_byte(payload, ?\r) == 0
    assert sha256(payload) == archive["sha256"]
    assert sha256(payload) == @archive_sha
  end

  test "W1 recomputes SIO boundaries and separates the client and server caps", %{
    fixtures: fixtures
  } do
    limits = fixtures["madmin_config_archive_limits.json"]
    wire = fixtures["minio_config_archive_wire.json"]
    frame = limits["sio_frame"]
    vectors = Map.new(limits["boundary_vectors"], &{&1["plaintext_bytes"], &1})

    assert limits["verification_item"]["id"] == "W1"
    assert frame["positive_plaintext_formula"] == "41+n+16*ceil(n/16384)"
    assert frame["prefix_bytes"] == 41
    assert frame["prefix_parts"] == %{"salt" => 32, "algorithm_id" => 1, "nonce" => 8}
    assert frame["chunk_plaintext_bytes"] == 16_384
    assert frame["aead_tag_bytes_per_chunk"] == 16

    assert sio_length(261_975, frame) == 262_272
    assert sio_length(261_976, frame) == 262_273
    assert sio_length(262_144, frame) == 262_441

    assert Map.take(vectors[261_975], ["chunk_count", "ciphertext_bytes", "madmin_local", "minio_server"]) == %{
             "chunk_count" => 16,
             "ciphertext_bytes" => 262_272,
             "madmin_local" => "PASS",
             "minio_server" => "PASS_at_ciphertext_limit"
           }

    assert vectors[261_976]["ciphertext_bytes"] == 262_273
    assert vectors[261_976]["minio_server"] == "XMinioAdminConfigTooLarge"
    assert vectors[262_144]["ciphertext_bytes"] == 262_441
    assert vectors[262_144]["minio_server"] == "XMinioAdminConfigTooLarge"
    assert vectors[262_145]["ciphertext_bytes"] == nil
    assert vectors[262_145]["madmin_local"] == "bytes.ErrTooLarge_zero_request"

    assert limits["plaintext_reader"]["maximum_bytes"] == 262_144
    assert limits["plaintext_reader"]["empty"]["http_request_count"] == 0
    assert limits["plaintext_reader"]["maximum_plus_one_or_more"]["http_request_count"] == 0
    assert limits["effective_native_round_trip_plaintext_maximum"] == 261_975
    assert wire["server_ciphertext_gate"]["maximum_bytes"] == 262_272

    conditions = Map.new(wire["error_map_contract"]["conditions"], &{&1["id"], &1})
    unreachable = conditions["plaintext_over_262144"]

    assert unreachable["evidence_class"] == "source_verified"
    assert unreachable["reachability"] == "not_reachable_after_ciphertext_gate_for_valid_SIO"
    assert unreachable["effective_valid_SIO_plaintext_maximum"] == 261_975
    assert unreachable["pre_decrypt_status"] == 400
    assert unreachable["pre_decrypt_code"] == "XMinioAdminConfigTooLarge"

    guard = conditions["generic_plaintext_guard_if_called_outside_valid_PUT_SIO_path"]
    assert guard["evidence_class"] == "local_design_expected"
    assert guard["status"] == 400
    assert guard["code"] == "XMinioAdminConfigTooLarge"
  end

  test "W1 through W5 have explicit decision gates and unresolved decisions block production", %{
    fixtures: fixtures
  } do
    limits = fixtures["madmin_config_archive_limits.json"]
    wire = fixtures["minio_config_archive_wire.json"]
    dispatch = fixtures["mc_config_archive_dispatch.json"]

    assert [
             limits["verification_item"]["id"],
             wire["verification_item"]["id"],
             wire["export_codec"]["verification_item"],
             wire["import_semantics"]["verification_item"],
             dispatch["verification_item"]["id"]
           ] == ["W1", "W2", "W3", "W4", "W5"]

    assert limits["verification_item"]["implementation_gate"] == "PASS_SOURCE_VERIFIED"

    assert wire["verification_item"]["implementation_gate"] ==
             "PASS_SOURCE_AND_EXISTING_CONTRACT_VERIFIED"

    assert wire["verification_item"]["blocking_unresolved"] == []

    assert wire["export_codec"]["implementation_gate"] ==
             "PASS_SOURCE_VERIFIED_WITH_LOCAL_DESIGN_PAYLOAD"

    assert wire["import_semantics"]["implementation_gate"] ==
             "PASS_SOURCE_VERIFIED_WITH_EXPLICIT_MAXIO_DEVIATIONS"

    for fields <- collect_named_maps(fixtures, "implementation_decision_fields") do
      evidence_classes =
        fields
        |> Enum.filter(fn {key, _value} ->
          key == "status" or String.ends_with?(key, "_evidence_class")
        end)
        |> Enum.map(&elem(&1, 1))

      assert evidence_classes != []
      assert Enum.all?(evidence_classes, &(&1 in @allowed_decision_evidence))

      if fields["unresolved"] != [] do
        assert String.starts_with?(fields["gate"], "BLOCKED_BEFORE_")
      end
    end

    assert wire["implementation_decision_fields"]["unresolved"] == []

    if dispatch["verification_item"]["status"] == "VERIFY-AT-IMPL" do
      assert dispatch["verification_item"]["implementation_gate"] == "BLOCKED_BEFORE_TASK_8"
      assert dispatch["verification_item"]["must_not_wait_until"] == "Task_11"
      assert dispatch["live_observation"]["task_gate"] == "Task_8_blocked_until_closed"
      assert dispatch["live_observation"]["task_11_role"] == "reverify_only_not_first_decision"
      assert production_w5_consumers() == []
    end
  end

  test "authorization denial remains distinct from authentication failures", %{fixtures: fixtures} do
    contract =
      fixtures["minio_config_archive_wire.json"]["authentication_and_authorization"]

    assert contract["valid_authenticated_identity_without_ConfigUpdate"] == %{
             "status" => 403,
             "code" => "AccessDenied"
           }

    authentication = contract["authentication_failure"]
    assert authentication["must_not_collapse_to_AccessDenied"] == true
    assert authentication["behavior"] =~ "preserve the exact non-AccessDenied error"
    assert authentication["examples"] == [
             "InvalidAccessKeyId",
             "SignatureDoesNotMatch",
             "ExpiredToken"
           ]

    refute "AccessDenied" in authentication["examples"]
  end

  test "ErrorMap condition matrix and twelve-stage precedence remain exact", %{fixtures: fixtures} do
    contract = fixtures["minio_config_archive_wire.json"]["error_map_contract"]
    conditions = contract["conditions"]
    ids = Enum.map(conditions, & &1["id"])

    assert contract["precedence"] == @error_precedence
    assert Enum.map(contract["precedence"], & &1["priority"]) == Enum.to_list(1..12)
    assert length(conditions) == 23
    assert length(Enum.uniq(ids)) == length(ids)
    assert Enum.map(conditions, &condition_matrix_entry/1) == @error_conditions

    condition_priorities = conditions |> Enum.map(& &1["priority"]) |> MapSet.new()
    assert condition_priorities == MapSet.new(1..11)
    assert Enum.any?(conditions, &(&1["priority"] == 8))
    assert Enum.any?(conditions, &(&1["priority"] == 10))
    refute Enum.any?(conditions, &(&1["priority"] == 12))

    normalized = Map.new(@error_conditions, &{&1["id"], &1})

    assert normalized["unknown_prefix"] == %{
             "id" => "unknown_prefix",
             "priority" => 9,
             "evidence_class" => "existing_contract_verified",
             "status" => 400,
             "code" => "XMinioAdminConfigBadJSON",
             "message" => "JSON configuration provided is of incorrect format",
             "representative_input" => "s3 absent=1 clock_skew_ms=1000"
           }

    assert normalized["unknown_subsystem"]["representative_input"] == "absent value=1"
    assert normalized["unknown_subsystem"]["code"] == "XMinioConfigError"
    refute normalized["unknown_subsystem"] == normalized["unknown_prefix"]

    assert contract["unresolved"] == []

    for condition <- @error_conditions do
      assert condition["evidence_class"] != "VERIFY-AT-IMPL"
      assert is_integer(condition["status"])
      assert is_binary(condition["code"])
      assert is_binary(condition["message"])
    end
  end

  test "priority twelve records committed postcommit attention without false rollback or HTTP failure", %{
    fixtures: fixtures
  } do
    contract = fixtures["minio_config_archive_wire.json"]["error_map_contract"]

    assert contract["postcommit_outcome_contract"] == %{
             "priority" => 12,
             "stage" => "postcommit_reload_and_broadcast",
             "evidence_class" => "local_design_expected",
             "error_map_failure" => false,
             "transaction_state" => "already_committed",
             "reload_or_broadcast_failure" =>
               "must_not_roll_back_committed_rows_or_audits",
             "http_outcome" => %{
               "status" => 200,
               "body_bytes" => 0,
               "applied_header" => "absent"
             },
             "must_not_report" => ["InternalError", "transaction_not_committed"],
             "observability" =>
               "record structured attention without plaintext, ciphertext, value or caller secret",
             "contract_reference" =>
               "S7 commit-first postcommit safety design; intentionally separate from ErrorMap conditions"
           }
  end

  test "random SIO evidence never freezes ciphertext bytes or a ciphertext digest", %{
    fixtures: fixtures
  } do
    wire = fixtures["minio_config_archive_wire.json"]
    limits = fixtures["madmin_config_archive_limits.json"]

    assert wire["caller_secret_sio"]["ciphertext_bytes_or_sha_stored"] == false
    assert wire["caller_secret_sio"]["reason"] == "salt and nonce are random"
    assert wire["request_builder"]["put_payload_sha256"] ==
             "sha256_of_each_random_sio_ciphertext"

    assert limits["sio_frame"]["fixed_ciphertext_bytes_or_sha_forbidden"] == true

    fixed_ciphertext_digests =
      fixtures
      |> flatten()
      |> Enum.filter(fn {path, value} ->
        leaf = path |> String.split(".") |> List.last() |> String.downcase()

        String.contains?(leaf, "ciphertext") and
          Regex.match?(~r/(?:sha|hash|digest)/, leaf) and
          is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
      end)

    assert fixed_ciphertext_digests == []

    forbidden_ciphertext_payload_fields =
      fixtures
      |> flatten()
      |> Enum.filter(fn {path, value} ->
        Regex.match?(~r/(?:ciphertext_(?:hex|base64|bytes_value)|fixed_ciphertext_sha)/i, path) and
          value not in [false, nil]
      end)

    assert forbidden_ciphertext_payload_fields == []
  end

  test "raw and excerpt evidence records ranges, hashes, pinned sources, and immutable URLs", %{
    fixtures: fixtures
  } do
    integrity = fixtures["raw_sha256.json"]
    repositories = integrity["repositories"]

    assert integrity["integrity_contract"]["mutable_branch_url_allowed"] == false
    assert integrity["integrity_contract"]["checkout_bytes_authoritative"] == false

    for {source_id, source} <- integrity["sources"] do
      repository = Map.fetch!(repositories, source["repository"])
      assert Regex.match?(~r/\A[0-9a-f]{40}\z/, repository["commit"]), source_id
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, source["raw_source_sha256"]), source_id
      assert source["file"] not in [nil, ""], source_id
      assert source["url"] == immutable_raw_url(repository, source["file"]), source_id

      excerpt_records = excerpt_records(source)
      assert excerpt_records != [], source_id

      for excerpt <- excerpt_records do
        assert Regex.match?(~r/\A[1-9]\d*-[1-9]\d*\z/, excerpt["lines"]), source_id
        assert Regex.match?(~r/\A[0-9a-f]{64}\z/, excerpt["excerpt_sha256"]), source_id
      end
    end

    source_ids = integrity["sources"] |> Map.keys() |> MapSet.new()

    for {_claim, ids} <- integrity["claim_sources"] do
      assert ids != []
      assert MapSet.subset?(MapSet.new(ids), source_ids)
    end
  end

  test "mc transcript payloads retain exact stdout lengths and hashes", %{fixtures: fixtures} do
    outputs = fixtures["mc_config_archive_dispatch.json"]["expected_stdout"]

    export_human = output_bytes(outputs["fresh_export_human"])
    assert export_human == Base.decode64!(outputs["fresh_export_human"]["bytes_base64"])
    assert export_human |> byte_size() == 89
    assert sha256(export_human) == @archive_sha

    for {name, transcript} <- outputs do
      bytes = output_bytes(transcript)
      assert byte_size(bytes) == transcript["byte_length"], name
      assert sha256(bytes) == transcript["sha256"], name
    end

    export_json = output_bytes(outputs["fresh_export_json_non_tty"])
    decoded_json = Jason.decode!(export_json)
    assert decoded_json["status"] == "success"
    assert Base.decode64!(decoded_json["value"]) == export_human
  end

  test "fixtures contain no credential, real secret, Authorization, or ciphertext material", %{
    fixtures: fixtures
  } do
    wire = fixtures["minio_config_archive_wire.json"]
    dispatch = fixtures["mc_config_archive_dispatch.json"]

    assert wire["request_builder"]["authorization_or_signature_value_stored"] == false
    assert wire["maxio_bounded_deviations"]["secret_or_backend_binding"] ==
             "unsupported and never exported"

    assert dispatch["security"]["fixture_contains_real_secret_or_ciphertext"] == false

    forbidden_material_fields =
      fixtures
      |> flatten()
      |> Enum.filter(fn {path, value} ->
        Regex.match?(
          ~r/(?:access_key_value|secret_access_key|caller_secret_value|session_token_value|authorization_value|sigv4_signature_value|ciphertext_(?:hex|base64|value))$/i,
          path
        ) and value not in [false, nil]
      end)

    assert forbidden_material_fields == []
  end

  defp fixture(file) do
    @fixture_dir
    |> Path.join(file)
    |> File.read!()
    |> Jason.decode!()
  end

  defp immutable_raw_url(repository, file) do
    repository["url"]
    |> String.replace_prefix("https://github.com/", "https://raw.githubusercontent.com/")
    |> Kernel.<>("/#{repository["commit"]}/#{file}")
  end

  defp collect_url_values(term) do
    term
    |> flatten()
    |> Enum.filter(fn {path, value} -> String.ends_with?(path, ".url") and is_binary(value) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp collect_named_maps(term, key), do: collect_named_maps(term, key, [])

  defp collect_named_maps(map, key, acc) when is_map(map) do
    Enum.reduce(map, acc, fn
      {^key, value}, nested_acc when is_map(value) ->
        collect_named_maps(value, key, [value | nested_acc])

      {_nested_key, value}, nested_acc ->
        collect_named_maps(value, key, nested_acc)
    end)
  end

  defp collect_named_maps(list, key, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_named_maps(&1, key, &2))

  defp collect_named_maps(_term, _key, acc), do: acc

  defp production_w5_consumers do
    root = Path.expand("../../..", __DIR__)
    this_file = Path.expand(__ENV__.file)

    (Path.wildcard(Path.join(root, "lib/**/*.ex")) ++
       Path.wildcard(Path.join(root, "test/**/*.exs")))
    |> Enum.reject(&(Path.expand(&1) == this_file))
    |> Enum.filter(fn file ->
      contents = File.read!(file)
      String.contains?(contents, "mc_config_archive_dispatch.json")
    end)
    |> Enum.map(&Path.relative_to(&1, root))
  end

  defp excerpt_records(%{"excerpt_parts" => parts}), do: parts

  defp excerpt_records(%{"lines" => lines, "excerpt_sha256" => hash}),
    do: [%{"lines" => lines, "excerpt_sha256" => hash}]

  defp excerpt_records(_source), do: []

  defp output_bytes(%{"bytes_base64" => encoded}), do: Base.decode64!(encoded)

  defp output_bytes(%{"utf8_escaped" => escaped}),
    do: String.replace(escaped, "\\n", "\n")

  defp condition_matrix_entry(condition) do
    %{
      "id" => condition["id"],
      "priority" => condition["priority"],
      "evidence_class" => condition["evidence_class"],
      "status" => Map.get(condition, "status", condition["pre_decrypt_status"]),
      "code" => Map.get(condition, "code", condition["pre_decrypt_code"]),
      "message" => Map.get(condition, "message", condition["pre_decrypt_message"]),
      "representative_input" =>
        Map.get(condition, "representative_input", condition["inputs"])
    }
  end

  defp sio_length(plaintext_bytes, frame) when plaintext_bytes >= 1 do
    chunks = div(plaintext_bytes + frame["chunk_plaintext_bytes"] - 1, frame["chunk_plaintext_bytes"])
    frame["prefix_bytes"] + plaintext_bytes + chunks * frame["aead_tag_bytes_per_chunk"]
  end

  defp count_byte(binary, byte) do
    binary
    |> :binary.bin_to_list()
    |> Enum.count(&(&1 == byte))
  end

  defp flatten(term), do: flatten(term, [])

  defp flatten(map, path) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> flatten(value, path ++ [to_string(key)]) end)
  end

  defp flatten(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> flatten(value, path ++ [Integer.to_string(index)]) end)
  end

  defp flatten(value, path), do: [{Enum.join(path, "."), value}]

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
