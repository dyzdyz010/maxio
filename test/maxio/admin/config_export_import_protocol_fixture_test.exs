defmodule Maxio.Admin.ConfigExportImportProtocolFixtureTest do
  use ExUnit.Case, async: true

  @fixture_dir Path.expand("../../fixtures/minio_admin_config_export_import_s7", __DIR__)
  @project_root Path.expand("../../..", __DIR__)
  @s7_design_file "docs/superpowers/specs/2026-08-29-minio-admin-config-export-import-s7-design.md"
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
  @allowed_decision_evidence [
    "source_verified",
    "live_verified",
    "existing_contract_verified",
    "local_design_expected"
  ]
  @upstream_compatibility_evidence ["source_verified", "live_verified"]
  @local_contract_evidence ["existing_contract_verified", "local_design_expected"]
  @task6_wire_decision_roots [
    "/routes",
    "/caller_secret_sio",
    "/request_builder",
    "/http_framing",
    "/server_ciphertext_gate",
    "/authentication_and_authorization",
    "/error_map_contract/precedence",
    "/error_map_contract/precedence_assertion",
    "/error_map_contract/conditions",
    "/error_map_contract/contract_sources/reuse_rule",
    "/error_map_contract/postcommit_outcome_contract",
    "/fresh_archive"
  ]
  @task6_decision_documents %{
    "minio_config_archive_wire.json" => @task6_wire_decision_roots,
    "madmin_config_archive_limits.json" => ["/"]
  }
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
      "message" => "The provided 'x-amz-content-sha256' header does not match what was computed.",
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
      "message" => "unknown sub-system absent",
      "representative_input" => "absent value=REDACTED"
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

    assert Map.take(vectors[261_975], [
             "chunk_count",
             "ciphertext_bytes",
             "madmin_local",
             "minio_server"
           ]) == %{
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
             "PASS_PROVENANCE_COMPLETE_FOR_TASK_6_RED"

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

  test "Task 6 decision roots recursively reject missing unknown and unresolved provenance", %{
    fixtures: fixtures
  } do
    records =
      Enum.flat_map(@task6_decision_documents, fn {file, roots} ->
        Enum.flat_map(roots, fn root ->
          fixtures[file]
          |> json_pointer!(root)
          |> decision_leaf_records(file <> "#" <> root, nil)
        end)
      end)

    assert records != []

    assert Enum.filter(records, &is_nil(&1.evidence_class)) == []

    assert Enum.filter(
             records,
             &(&1.evidence_class not in @allowed_decision_evidence)
           ) == []

    assert Enum.filter(records, fn record ->
             is_binary(record.value) and String.contains?(record.value, "VERIFY-AT-IMPL")
           end) == []

    local_boundaries =
      @task6_decision_documents
      |> Enum.flat_map(fn {file, roots} ->
        Enum.flat_map(roots, fn root ->
          fixtures[file]
          |> json_pointer!(root)
          |> explicit_evidence_boundaries(file <> "#" <> root)
        end)
      end)
      |> Enum.filter(&(&1.evidence_class in @local_contract_evidence))

    all_boundaries =
      Enum.flat_map(@task6_decision_documents, fn {file, roots} ->
        Enum.flat_map(roots, fn root ->
          fixtures[file]
          |> json_pointer!(root)
          |> explicit_evidence_boundaries(file <> "#" <> root)
        end)
      end)

    assert Enum.filter(
             all_boundaries,
             &(&1.evidence_class not in @allowed_decision_evidence)
           ) == []

    assert Enum.filter(local_boundaries, fn boundary ->
             contract_reference_error(
               boundary.value["contract_reference"],
               boundary.evidence_class
             ) != nil
           end) == []
  end

  test "Task 6 covers precedence assertion and ErrorMap reuse as referenced decision boundaries",
       %{
         fixtures: fixtures
       } do
    wire = fixtures["minio_config_archive_wire.json"]

    for {pointer, evidence_class} <- [
          {"/error_map_contract/precedence_assertion", "local_design_expected"},
          {"/error_map_contract/contract_sources/reuse_rule", "existing_contract_verified"}
        ] do
      boundary = json_pointer!(wire, pointer)

      assert is_map(boundary), "#{pointer} must be an explicit evidence boundary"
      assert boundary["evidence_class"] == evidence_class, pointer

      assert contract_reference_error(boundary["contract_reference"], evidence_class) == nil,
             pointer
    end
  end

  test "Task 6 evidence taxonomy distinguishes upstream live existing and local claims", %{
    fixtures: fixtures
  } do
    taxonomy = fixtures["minio_config_archive_wire.json"]["evidence_taxonomy"]

    assert taxonomy |> Map.keys() |> Enum.sort() == Enum.sort(@allowed_decision_evidence)

    assert taxonomy["source_verified"] == %{
             "claim_scope" => "upstream compatibility fact",
             "required_evidence" => "pinned official source plus raw_sha256 raw/excerpt hashes"
           }

    assert taxonomy["live_verified"] == %{
             "claim_scope" => "observed pre-implementation live fact",
             "required_evidence" =>
               "pinned binary or server identity, OS and command, redacted artifact hash, and observed result",
             "claimed_in_this_fixture" => false
           }

    assert taxonomy["existing_contract_verified"] == %{
             "claim_scope" => "reviewed pre-S7 Maxio behavior only; never upstream parity",
             "required_evidence" =>
               "named pre-existing fixture, test, error symbol or immutable closeout reference plus Task 6 RED lock",
             "reviewed_baseline" =>
               "S5 implementation HEAD 17278b93ad9d0af2c51b018ca5397a9fba3378ff; STATUS records independent Lane C and Lane D approval"
           }

    assert taxonomy["local_design_expected"] == %{
             "claim_scope" => "new S7 Maxio choice or repair only; never upstream or live fact",
             "required_evidence" =>
               "named S7 design reference plus Task 6 RED lock and independent RED review before Task 7"
           }
  end

  test "claimed_in_this_fixture false means no live_verified Task 6 boundary exists", %{
    fixtures: fixtures
  } do
    taxonomy = fixtures["minio_config_archive_wire.json"]["evidence_taxonomy"]

    if taxonomy["live_verified"]["claimed_in_this_fixture"] == false do
      live_boundaries = task6_boundaries(fixtures, "live_verified")
      assert length(live_boundaries) == 0, inspect(Enum.map(live_boundaries, & &1.path))
    end
  end

  test "Task 6 local transport decisions are explicit and must be locked by RED before Task 7", %{
    fixtures: fixtures
  } do
    wire = fixtures["minio_config_archive_wire.json"]
    gate = wire["task6_entry_gate"]

    assert gate["gate_result"] == "PASS_PROVENANCE_COMPLETE_FOR_TASK_6_RED"

    assert gate["claim_scope"] ==
             "fixture provenance completeness only; not live behavior or endpoint PASS"

    assert gate["allowed_evidence_classes"] == @allowed_decision_evidence
    assert gate["upstream_compatibility_classes"] == @upstream_compatibility_evidence
    assert gate["local_contract_classes"] == @local_contract_evidence
    assert gate["decision_documents"] == @task6_decision_documents

    assert is_map(gate["source_claims"])

    assert gate["unresolved"] == []
    assert gate["w5_effect"] == "none; W5 blocks Task 8 only"

    assert gate["inheritance_rule"] ==
             "each decision leaf inherits the nearest ancestor evidence_class; list members without an inherited class must declare their own"

    assert gate["task6_red_lock_rule"] ==
             "Task 6 RED must table-lock every precedence priority, every condition id, and every named local transport decision"

    assert gate["task7_entry_rule"] ==
             "Task 7 remains blocked until independent review confirms the Task 6 RED locks every required decision"
  end

  test "source claims bind every source_verified JSON boundary to immutable claim and source ids",
       %{
         fixtures: fixtures
       } do
    bindings = fixtures["minio_config_archive_wire.json"]["task6_entry_gate"]["source_claims"]
    boundaries = task6_boundaries(fixtures, "source_verified")

    missing = Enum.reject(boundaries, &Map.has_key?(bindings, &1.path))
    assert Enum.map(missing, & &1.path) == []

    invalid =
      for boundary <- boundaries,
          errors = source_binding_errors(bindings[boundary.path], fixtures["raw_sha256.json"]),
          errors != [],
          do: %{path: boundary.path, errors: errors}

    assert invalid == []
  end

  test "W1 server boundary vectors cite their MinIO server sources", %{fixtures: fixtures} do
    required = MapSet.new(["minio_config_archive_handlers", "minio_ciphertext_limit"])

    for index <- 0..2 do
      source_ids =
        boundary_source_ids(
          fixtures,
          "madmin_config_archive_limits.json#/boundary_vectors/#{index}"
        )

      assert MapSet.subset?(required, MapSet.new(source_ids)),
             "W1 boundary_vectors/#{index} omits MinIO handler/limit provenance"
    end
  end

  test "effective native round-trip maximum binds the W1 formula and W2 server gate", %{
    fixtures: fixtures
  } do
    file = "madmin_config_archive_limits.json"
    pointer = "/effective_native_round_trip_plaintext_maximum"
    limits = fixtures[file]

    assert json_pointer!(limits, pointer) == 261_975

    boundary_path = nearest_evidence_boundary_path(limits, file, pointer, "source_verified")
    assert boundary_path == "madmin_config_archive_limits.json#/"

    binding =
      fixtures["minio_config_archive_wire.json"]["task6_entry_gate"]["source_claims"][
        boundary_path
      ] || %{"claim_ids" => [], "source_ids" => []}

    required_claim_ids =
      MapSet.new([
        "W1_madmin_limits_and_sio_formula",
        "W2_route_auth_errors_and_framing"
      ])

    required_source_ids =
      MapSet.new(["minio_config_archive_handlers", "minio_ciphertext_limit"])

    missing = %{
      claim_ids: MapSet.difference(required_claim_ids, MapSet.new(binding["claim_ids"])),
      source_ids: MapSet.difference(required_source_ids, MapSet.new(binding["source_ids"]))
    }

    assert missing == %{claim_ids: MapSet.new(), source_ids: MapSet.new()}
  end

  test "W2 caller-secret SIO boundary cites madmin and sio-go sources", %{fixtures: fixtures} do
    required =
      MapSet.new([
        "madmin_config_methods",
        "madmin_encrypt_decrypt",
        "sio_go_constants",
        "sio_go_default_stream"
      ])

    source_ids =
      boundary_source_ids(fixtures, "minio_config_archive_wire.json#/caller_secret_sio")

    assert MapSet.subset?(required, MapSet.new(source_ids)),
           "W2 caller_secret_sio omits madmin/sio-go provenance"
  end

  test "all 23 conditions and 12 precedence rows resolve structured contract references", %{
    fixtures: fixtures
  } do
    contract = fixtures["minio_config_archive_wire.json"]["error_map_contract"]
    rows = contract["conditions"] ++ contract["precedence"]

    assert length(contract["conditions"]) == 23
    assert length(contract["precedence"]) == 12

    invalid =
      for row <- rows,
          error = contract_reference_error(row["contract_reference"], row["evidence_class"]),
          error != nil,
          do: %{id: row["id"] || row["priority"], error: error}

    assert invalid == []
  end

  test "contract reference resolver accepts real anchors and rejects bogus ones" do
    baseline = %{
      "kind" => "baseline",
      "file" => "test/maxio/admin/error_map_test.exs",
      "test_id" => "maps every S2b input error to its exact public code, status, and message"
    }

    design = %{
      "kind" => "design",
      "file" => @s7_design_file,
      "section" => "10.1 管线顺序"
    }

    assert contract_reference_error(baseline, "existing_contract_verified") == nil
    assert contract_reference_error(design, "local_design_expected") == nil

    refute contract_reference_error(
             %{baseline | "test_id" => "bogus test id that does not exist"},
             "existing_contract_verified"
           ) == nil

    refute contract_reference_error(
             %{design | "section" => "99.99 bogus section"},
             "local_design_expected"
           ) == nil

    refute contract_reference_error(
             %{baseline | "file" => "test/maxio/admin/not_a_real_baseline.exs"},
             "existing_contract_verified"
           ) == nil
  end

  test "anonymous response reuse and S7 auth-before-body order are separate class boundaries", %{
    fixtures: fixtures
  } do
    concealment =
      fixtures["minio_config_archive_wire.json"]["authentication_and_authorization"][
        "maxio_anonymous_concealment"
      ]

    boundaries = explicit_evidence_boundaries(concealment, "anonymous")

    existing_response =
      Enum.find(boundaries, fn boundary ->
        boundary.evidence_class == "existing_contract_verified" and
          Map.take(boundary.value, ["status", "code", "message"]) == %{
            "status" => 403,
            "code" => "AccessDenied",
            "message" => "Access Denied"
          }
      end)

    local_order =
      Enum.find(boundaries, fn boundary ->
        boundary.evidence_class == "local_design_expected" and
          contains_text?(boundary.value, "before entity length")
      end)

    assert existing_response != nil
    assert local_order != nil
    refute existing_response.path == local_order.path
    assert Map.take(local_order.value, ["status", "code", "message"]) == %{}
  end

  test "existing no-transform policy and S7 exact response framing are separate class boundaries",
       %{
         fixtures: fixtures
       } do
    repair =
      fixtures["minio_config_archive_wire.json"]["http_framing"][
        "upstream_admin_gzip_middleware"
      ]["maxio_transport_repair"]

    boundaries = explicit_evidence_boundaries(repair, "no-transform")

    existing_policy =
      Enum.find(boundaries, fn boundary ->
        boundary.evidence_class == "existing_contract_verified" and
          contains_text?(boundary.value, "no-transform")
      end)

    local_framing =
      Enum.find(boundaries, fn boundary ->
        boundary.evidence_class == "local_design_expected" and
          boundary.value["content_length"] == "exact_random_ciphertext_length" and
          boundary.value["transfer_encoding"] == "absent" and
          boundary.value["content_encoding"] == "absent"
      end)

    assert existing_policy != nil
    assert local_framing != nil
    refute existing_policy.path == local_framing.path
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

    assert Enum.map(contract["precedence"], &Map.take(&1, ["priority", "stage"])) ==
             @error_precedence

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

    assert normalized["unknown_subsystem"]["representative_input"] ==
             "absent value=REDACTED"

    assert normalized["unknown_subsystem"]["message"] == "unknown sub-system absent"
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

  test "unknown subsystem public fields never repeat the scalar token", %{
    fixtures: fixtures
  } do
    unknown = unknown_subsystem_condition(fixtures)

    protected =
      Map.take(unknown, [
        "message",
        "representative_input",
        "public_response",
        "log_contract"
      ])

    scalar_echoes =
      protected
      |> flatten()
      |> Enum.filter(fn {_path, value} ->
        is_binary(value) and Regex.match?(~r/(?<![[:alnum:]_])1(?![[:alnum:]_])/, value)
      end)

    assert scalar_echoes == []
  end

  test "unknown subsystem fixture explicitly locks its public response and safe log contract", %{
    fixtures: fixtures
  } do
    unknown = unknown_subsystem_condition(fixtures)

    assert is_map(unknown["public_response"])
    assert is_map(unknown["log_contract"])
  end

  test "priority twelve records committed postcommit attention without false rollback or HTTP failure",
       %{
         fixtures: fixtures
       } do
    contract = fixtures["minio_config_archive_wire.json"]["error_map_contract"]

    {reference, outcome} = Map.pop(contract["postcommit_outcome_contract"], "contract_reference")

    assert outcome == %{
             "priority" => 12,
             "stage" => "postcommit_reload_and_broadcast",
             "evidence_class" => "local_design_expected",
             "error_map_failure" => false,
             "transaction_state" => "already_committed",
             "reload_or_broadcast_failure" => "must_not_roll_back_committed_rows_or_audits",
             "http_outcome" => %{
               "status" => 200,
               "body_bytes" => 0,
               "applied_header" => "absent"
             },
             "must_not_report" => ["InternalError", "transaction_not_committed"],
             "observability" =>
               "record structured attention without plaintext, ciphertext, value or caller secret"
           }

    assert contract_reference_error(reference, "local_design_expected") == nil
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

  defp json_pointer!(document, pointer) do
    pointer
    |> String.split("/", trim: true)
    |> Enum.reduce(document, fn segment, value -> Map.fetch!(value, segment) end)
  end

  defp nearest_evidence_boundary_path(document, file, pointer, evidence_class) do
    segments = String.split(pointer, "/", trim: true)

    segments
    |> Enum.drop(-1)
    |> then(fn parent_segments ->
      Enum.map(length(parent_segments)..0//-1, &Enum.take(parent_segments, &1))
    end)
    |> Enum.find_value(fn boundary_segments ->
      boundary_pointer =
        case boundary_segments do
          [] -> "/"
          segments -> "/" <> Enum.join(segments, "/")
        end

      case json_pointer!(document, boundary_pointer) do
        %{"evidence_class" => ^evidence_class} -> file <> "#" <> boundary_pointer
        _other -> nil
      end
    end)
  end

  defp task6_boundaries(fixtures, evidence_class) do
    @task6_decision_documents
    |> Enum.flat_map(fn {file, roots} ->
      Enum.flat_map(roots, fn root ->
        fixtures[file]
        |> json_pointer!(root)
        |> explicit_evidence_boundaries(file <> "#" <> root)
      end)
    end)
    |> Enum.filter(&(&1.evidence_class == evidence_class))
    |> Enum.uniq_by(& &1.path)
  end

  defp decision_leaf_records(map, path, inherited_class) when is_map(map) do
    evidence_class = Map.get(map, "evidence_class", inherited_class)

    map
    |> Enum.reject(fn {key, _value} -> key == "evidence_class" end)
    |> Enum.flat_map(fn {key, value} ->
      decision_leaf_records(value, append_json_pointer(path, key), evidence_class)
    end)
  end

  defp decision_leaf_records(list, path, inherited_class) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      decision_leaf_records(value, append_json_pointer(path, index), inherited_class)
    end)
  end

  defp decision_leaf_records(value, path, evidence_class) do
    [%{path: path, value: value, evidence_class: evidence_class}]
  end

  defp explicit_evidence_boundaries(term, path),
    do: explicit_evidence_boundaries(term, path, [])

  defp explicit_evidence_boundaries(map, path, acc) when is_map(map) do
    acc =
      case map do
        %{"evidence_class" => evidence_class} ->
          [%{path: path, evidence_class: evidence_class, value: map} | acc]

        _other ->
          acc
      end

    Enum.reduce(map, acc, fn {key, value}, nested_acc ->
      explicit_evidence_boundaries(value, append_json_pointer(path, key), nested_acc)
    end)
  end

  defp explicit_evidence_boundaries(list, path, acc) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {value, index}, nested_acc ->
      explicit_evidence_boundaries(
        value,
        append_json_pointer(path, index),
        nested_acc
      )
    end)
  end

  defp explicit_evidence_boundaries(_term, _path, acc), do: acc

  defp append_json_pointer(path, segment) do
    separator = if String.ends_with?(path, "#/"), do: "", else: "/"
    path <> separator <> to_string(segment)
  end

  defp source_binding_errors(binding, integrity) when is_map(binding) do
    claim_ids = binding["claim_ids"]
    source_ids = binding["source_ids"]
    claims = integrity["claim_sources"]
    sources = integrity["sources"]

    []
    |> add_error(not non_empty_string_list?(claim_ids), :claim_ids)
    |> add_error(not non_empty_string_list?(source_ids), :source_ids)
    |> add_error(
      non_empty_string_list?(claim_ids) and
        Enum.any?(claim_ids, &(not Map.has_key?(claims, &1))),
      :unknown_claim_id
    )
    |> add_error(
      non_empty_string_list?(source_ids) and
        Enum.any?(source_ids, &(not Map.has_key?(sources, &1))),
      :unknown_source_id
    )
    |> add_error(
      source_ids_outside_claims?(claim_ids, source_ids, claims),
      :source_id_not_bound_by_claim_id
    )
    |> add_error(
      non_empty_string_list?(source_ids) and
        Enum.any?(source_ids, fn source_id ->
          source = sources[source_id]
          is_map(source) and not immutable_source_record?(source, integrity["repositories"])
        end),
      :mutable_or_incomplete_source_record
    )
  end

  defp source_binding_errors(_binding, _integrity), do: [:binding_must_be_a_map]

  defp source_ids_outside_claims?(claim_ids, source_ids, claims) do
    if non_empty_string_list?(claim_ids) and non_empty_string_list?(source_ids) and
         Enum.all?(claim_ids, &Map.has_key?(claims, &1)) do
      claimed_source_ids =
        claim_ids
        |> Enum.flat_map(&claims[&1])
        |> MapSet.new()

      not MapSet.subset?(MapSet.new(source_ids), claimed_source_ids)
    else
      false
    end
  end

  defp add_error(errors, true, error), do: [error | errors]
  defp add_error(errors, false, _error), do: errors

  defp non_empty_string_list?(values),
    do: is_list(values) and values != [] and Enum.all?(values, &(is_binary(&1) and &1 != ""))

  defp immutable_source_record?(source, repositories) do
    with repository when is_map(repository) <- repositories[source["repository"]],
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, source["raw_source_sha256"] || ""),
         true <- excerpt_records(source) != [],
         true <-
           Enum.all?(excerpt_records(source), fn excerpt ->
             Regex.match?(~r/\A[0-9a-f]{64}\z/, excerpt["excerpt_sha256"] || "")
           end) do
      source["url"] == immutable_raw_url(repository, source["file"])
    else
      _other -> false
    end
  end

  defp boundary_source_ids(fixtures, boundary_path) do
    bindings = fixtures["minio_config_archive_wire.json"]["task6_entry_gate"]["source_claims"]

    case bindings[boundary_path] do
      %{"source_ids" => source_ids} when is_list(source_ids) ->
        source_ids

      _other ->
        [file | _rest] = String.split(boundary_path, "#", parts: 2)

        case bindings[file] do
          claim_id when is_binary(claim_id) ->
            fixtures["raw_sha256.json"]["claim_sources"][claim_id] || []

          _missing ->
            []
        end
    end
  end

  defp contract_reference_error(reference, evidence_class) when is_map(reference) do
    kind = reference["kind"]

    cond do
      evidence_class == "existing_contract_verified" and kind != "baseline" ->
        :existing_contract_requires_baseline

      evidence_class == "local_design_expected" and kind != "design" ->
        :local_design_requires_design_section

      kind == "baseline" ->
        validate_baseline_reference(reference)

      kind == "design" ->
        validate_design_reference(reference)

      true ->
        :unknown_reference_kind
    end
  end

  defp contract_reference_error(_reference, _evidence_class),
    do: :contract_reference_must_be_a_structured_map

  defp validate_baseline_reference(reference) do
    with {:ok, path} <- project_file(reference["file"]),
         {:ok, contents} <- File.read(path),
         true <- baseline_anchor_exists?(contents, reference) do
      nil
    else
      _other -> :baseline_file_or_anchor_not_found
    end
  end

  defp validate_design_reference(reference) do
    with {:ok, path} <- project_file(reference["file"]),
         {:ok, contents} <- File.read(path),
         section when is_binary(section) and section != "" <- reference["section"],
         true <- design_section_exists?(contents, section) do
      nil
    else
      _other -> :design_file_or_section_not_found
    end
  end

  defp project_file(file) when is_binary(file) and file != "" do
    path = Path.expand(file, @project_root)
    relative = Path.relative_to(path, @project_root)
    inside_project? = List.first(Path.split(relative)) != ".."

    if inside_project? and File.regular?(path),
      do: {:ok, path},
      else: :error
  end

  defp project_file(_file), do: :error

  defp baseline_anchor_exists?(contents, %{"test_id" => test_id})
       when is_binary(test_id) and test_id != "",
       do: String.contains?(contents, ~s(test "#{test_id}"))

  defp baseline_anchor_exists?(contents, %{"symbol" => symbol})
       when is_binary(symbol) and symbol != "",
       do: String.contains?(contents, symbol)

  defp baseline_anchor_exists?(_contents, _reference), do: false

  defp design_section_exists?(contents, section) do
    Enum.any?(String.split(contents, ~r/\R/), fn line ->
      Regex.match?(~r/^\#{1,6}\s+#{Regex.escape(section)}\s*$/, line)
    end)
  end

  defp contains_text?(term, needle) do
    term
    |> flatten()
    |> Enum.any?(fn {_path, value} ->
      is_binary(value) and String.contains?(String.downcase(value), String.downcase(needle))
    end)
  end

  defp unknown_subsystem_condition(fixtures) do
    Enum.find(
      fixtures["minio_config_archive_wire.json"]["error_map_contract"]["conditions"],
      &(&1["id"] == "unknown_subsystem")
    )
  end

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
      "representative_input" => Map.get(condition, "representative_input", condition["inputs"])
    }
  end

  defp sio_length(plaintext_bytes, frame) when plaintext_bytes >= 1 do
    chunks =
      div(plaintext_bytes + frame["chunk_plaintext_bytes"] - 1, frame["chunk_plaintext_bytes"])

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
