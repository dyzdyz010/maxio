defmodule Maxio.Admin.ConfigKVProtocolFixtureTest do
  use ExUnit.Case, async: true

  @fixture_dir Path.expand("../../fixtures/minio_admin_config_kv_s5", __DIR__)
  @ciphertext_hex "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f002021222324252627f68319b27606c7ea0e993fbbdbb3982b04"
  @entity_matrix [
    %{
      "id" => "get_request",
      "method" => "GET",
      "status" => nil,
      "content_length" => "absent",
      "transfer_encoding" => "absent",
      "content_type" => "absent",
      "body_hex" => "",
      "body_length" => 0
    },
    %{
      "id" => "set_request",
      "method" => "PUT",
      "status" => nil,
      "content_length" => "58",
      "transfer_encoding" => "absent",
      "content_type" => "absent",
      "body_hex" => @ciphertext_hex,
      "body_length" => 58
    },
    %{
      "id" => "reset_request",
      "method" => "DELETE",
      "status" => nil,
      "content_length" => "58",
      "transfer_encoding" => "absent",
      "content_type" => "absent",
      "body_hex" => @ciphertext_hex,
      "body_length" => 58
    },
    %{
      "id" => "get_response",
      "method" => "GET",
      "status" => 200,
      "content_length" => "58",
      "transfer_encoding" => "absent",
      "content_type" => "application/json",
      "body_hex" => @ciphertext_hex,
      "body_length" => 58
    },
    %{
      "id" => "set_response",
      "method" => "PUT",
      "status" => 200,
      "content_length" => "0",
      "transfer_encoding" => "absent",
      "content_type" => "absent",
      "body_hex" => "",
      "body_length" => 0
    },
    %{
      "id" => "reset_response",
      "method" => "DELETE",
      "status" => 200,
      "content_length" => "0",
      "transfer_encoding" => "absent",
      "content_type" => "absent",
      "body_hex" => "",
      "body_length" => 0
    }
  ]
  @query_branches %{
    "missing_key_authenticated" => %{
      "matches_handler" => false,
      "status" => 426,
      "code" => "XMinioAdminVersionMismatch",
      "description_template" => "This 'admin' API is not supported by server in '<mode>'"
    },
    "empty_key_authorized" => %{
      "matches_handler" => true,
      "status" => 400,
      "code" => "XMinioConfigError",
      "description" => "unknown subsystem: "
    },
    "unauthenticated_admin_surface" => %{
      "status" => 403,
      "code" => "AccessDenied",
      "precedence" => "before_route_detail"
    }
  }
  @errors %{
    "generic" => %{
      "status" => 400,
      "code" => "XMinioConfigError",
      "examples" => [
        "unknown subsystem: ",
        "unknown sub-system bad value",
        "sub-system 's3' cannot have empty keys"
      ]
    },
    "not_found" => %{
      "status" => 404,
      "code" => "XMinioConfigNotFoundError",
      "description" => "key absent doesn't exist",
      "only" => "reset of ordinary unknown key in exposed subsystem"
    },
    "bad_json" => %{
      "status" => 400,
      "code" => "XMinioAdminConfigBadJSON",
      "description" => "JSON configuration provided is of incorrect format",
      "causes" => [
        "invalid SIO envelope",
        "actual read length mismatch",
        "typed validator failure"
      ]
    },
    "too_large" => %{"status" => 400, "code" => "XMinioAdminConfigTooLarge"},
    "payload_hash" => %{"status" => 400, "code" => "XAmzContentSHA256Mismatch"}
  }
  @human_stdout %{
    "get" => %{
      "utf8" => "s3 clock_skew_ms=900000 \n",
      "utf8_length" => 25,
      "hex" => "733320636c6f636b5f736b65775f6d733d393030303030200a"
    },
    "set_applied" => %{
      "utf8" => "Successfully applied new settings.\n",
      "utf8_length" => 35,
      "hex" => "5375636365737366756c6c79206170706c696564206e65772073657474696e67732e0a"
    },
    "set_restart" => %{
      "utf8" =>
        "Successfully applied new settings.\nPlease restart your server 'mc admin service restart ALIAS'.\n",
      "utf8_length" => 96,
      "hex" =>
        "5375636365737366756c6c79206170706c696564206e65772073657474696e67732e0a506c65617365207265737461727420796f75722073657276657220276d632061646d696e2073657276696365207265737461727420414c494153272e0a"
    },
    "reset_applied" => %{
      "utf8" => "'s3 clock_skew_ms' is successfully reset.\n",
      "utf8_length" => 42,
      "hex" =>
        "27733320636c6f636b5f736b65775f6d7327206973207375636365737366756c6c792072657365742e0a"
    },
    "reset_restart" => %{
      "utf8" =>
        "'s3 clock_skew_ms' is successfully reset.\nPlease restart your server with `mc admin service restart ALIAS`.\n",
      "utf8_length" => 108,
      "hex" =>
        "27733320636c6f636b5f736b65775f6d7327206973207375636365737366756c6c792072657365742e0a506c65617365207265737461727420796f757220736572766572207769746820606d632061646d696e2073657276696365207265737461727420414c494153602e0a"
    }
  }
  @json_stdout %{
    "get" => %{
      "utf8" =>
        "{\"status\":\"success\",\"config\":[{\"subSystem\":\"s3\",\"kv\":[{\"key\":\"clock_skew_ms\",\"value\":\"900000\"}]}]}\n",
      "utf8_length" => 99,
      "hex" =>
        "7b22737461747573223a2273756363657373222c22636f6e666967223a5b7b2273756253797374656d223a227333222c226b76223a5b7b226b6579223a22636c6f636b5f736b65775f6d73222c2276616c7565223a22393030303030227d5d7d5d7d0a"
    },
    "set" => %{
      "utf8" => "{\"status\":\"success\"}\n",
      "utf8_length" => 21,
      "hex" => "7b22737461747573223a2273756363657373227d0a"
    },
    "reset" => %{
      "utf8" => "{\"status\":\"success\"}\n",
      "utf8_length" => 21,
      "hex" => "7b22737461747573223a2273756363657373227d0a"
    }
  }
  @unsupported_catalog_claims [
    "help-config-kv",
    "config_export_import",
    "config_history",
    "subsystem_target",
    "api",
    "site",
    "notify_*",
    "logger_*",
    "identity_*",
    "service_restart"
  ]
  @value_sanitization %{
    "escape_parsing" => false,
    "mixed_quote_input" => "\"'900000'\"",
    "operation_order" => [
      "trim_space",
      "trim_one_double_quote_layer",
      "trim_one_single_quote_layer"
    ],
    "result" => "900000"
  }
  @dynamic_error_descriptions %{
    "construction" => "fmt.Sprintf(format, vals...)",
    "reset_missing_key" => %{
      "description" => "key ABSENT doesn't exist",
      "format" => "key %s doesn't exist",
      "safe_identifier" => "ABSENT"
    },
    "unknown_subsystem" => %{
      "description" => "unknown subsystem: S3",
      "format" => "unknown subsystem: %s",
      "safe_identifier" => "S3"
    }
  }
  @unsupported_config_history_routes [
    %{
      "method" => "GET",
      "path" => "/minio/admin/v3/list-config-history-kv",
      "required_query" => %{"count" => "10"}
    },
    %{
      "method" => "DELETE",
      "path" => "/minio/admin/v3/clear-config-history-kv",
      "required_query" => %{"restoreId" => "fixture-restore-id"}
    },
    %{
      "method" => "PUT",
      "path" => "/minio/admin/v3/restore-config-history-kv",
      "required_query" => %{"restoreId" => "fixture-restore-id"}
    }
  ]
  @field_source_map %{
    "madmin_config_kv_wire.json.ciphertext_*,entity_matrix,applied_header,request_builder" => [
      "madmin_del_config_kv_wire",
      "madmin_set_config_kv_wire",
      "madmin_get_config_kv_wire",
      "madmin_new_request_entity_headers"
    ],
    "madmin_config_kv_wire.json.value_sanitization" => ["madmin_sanitize_value"],
    "mc_config_human.json.stdout,argv,local_help_or_rejection" => [
      "mc_config_get_rendering",
      "mc_config_set_rendering",
      "mc_config_reset_rendering",
      "mc_config_get_help_branch",
      "mc_config_set_help_branch",
      "mc_config_reset_help_branch",
      "mc_print_non_tty_compaction",
      "minio_subsys_info_write_to"
    ],
    "mc_config_json.json.stdout,mode,argv" => [
      "mc_config_get_rendering",
      "mc_config_set_rendering",
      "mc_config_reset_rendering",
      "mc_print_non_tty_compaction",
      "minio_subsys_info_write_to"
    ],
    "minio_routes_and_errors.json.errors,dynamic_error_descriptions" => [
      "minio_config_error_construction",
      "minio_get_unknown_subsystem_error",
      "minio_reset_missing_key_error"
    ],
    "minio_routes_and_errors.json.routes,query_branches,error_precedence,same_body_reset,deliberate_deviations,unsupported_catalog_claims" =>
      [
        "minio_router_config_kv_routes",
        "minio_del_config_kv_action_and_decrypt",
        "minio_set_config_kv_action_and_decrypt",
        "minio_get_config_kv_action"
      ],
    "minio_routes_and_errors.json.unsupported_config_history_routes" => [
      "minio_router_config_history_kv_routes"
    ]
  }

  setup_all do
    fixtures =
      for name <- [
            "minio_routes_and_errors",
            "madmin_config_kv_wire",
            "mc_config_human",
            "mc_config_json"
          ],
          into: %{} do
        {name, @fixture_dir |> Path.join(name <> ".json") |> File.read!() |> Jason.decode!()}
      end

    {:ok, fixtures}
  end

  test "fixture pins and copied-source excerpt digests catch protocol evidence drift", fixtures do
    routes = fixtures["minio_routes_and_errors"]

    assert routes["pins"] == %{
             "madmin_go" => "4b504b82db633e978a57d49443b2be75824244c3",
             "mc" => "77f82e18b5401a65958f1619df6ebb994634bd88",
             "minio" => "7aac2a2c5b7c882e68c1ce017d8256be2feea27f"
           }

    assert Map.new(routes["source_excerpts"], fn {id, excerpt} ->
             {id, excerpt["excerpt_sha256"]}
           end) == %{
             "madmin_del_config_kv_wire" =>
               "e5eeb324cd5281b797e0925644f4abbdec8a0153daf6750a58cf96c492afb02d",
             "madmin_get_config_kv_wire" =>
               "53d5df7f4c3a488e8df181a576c70756a64f07c6cdcb2d1fd2a2fc6f31ca1c11",
             "madmin_new_request_entity_headers" =>
               "004ac16858b362fd7705774d5881af72e2d0e4a9ed9fb7f9462b34a3eff071e0",
             "madmin_sanitize_value" =>
               "86a1b945b0d68b8bfd90ebc314344b5e68d2475a8d4d5511a6956f3be01a01ca",
             "madmin_set_config_kv_wire" =>
               "115e8d856da915da1a3539dc3932e3068c676dc95a1364de7a4aa4a5f86229ec",
             "mc_config_get_rendering" =>
               "48e2f3cad229a128306ba2dd0b0f2ed9edd06ebeabee7c69b4dfa8024f3f844f",
             "mc_config_get_help_branch" =>
               "a4797b0e56f8a74668fcd746bb34cf56de54eb9160998a06833fd3a13aaefba3",
             "mc_config_reset_rendering" =>
               "dd7590ee93ea4c1662462b6803dfeb1d4ea7adc307534491930405559fd94016",
             "mc_config_reset_help_branch" =>
               "1cec7998d65c252a6e100b46e8854b3d0460db8dbf5dc9143efc9e9665af72e6",
             "mc_config_set_rendering" =>
               "d4ded1439ba1303de5198c525123fdc8586e8546ac3a22558c40f6bd4bc6839c",
             "mc_config_set_help_branch" =>
               "a9e49de1465f0fef984c67c06a88b0e815136c63acea9b3809453da19a22ae03",
             "mc_print_non_tty_compaction" =>
               "96338ddfe75ded06aeeecaa0572d236edf5904480a72492f5619382f291f4aa3",
             "minio_del_config_kv_action_and_decrypt" =>
               "7c7fd960f0e2f88fad3809b1e4900d101ec139c0e9595ea36821dea3add20307",
             "minio_get_config_kv_action" =>
               "c4183540d0a0395e62932d2dac4e8276790149e4c04b4775cd0eda422cd81fc3",
             "minio_config_error_construction" =>
               "b2092fcdaafdd0bb7fb46837a23c6b09283d7952df69fcdfb8cda105784d2e18",
             "minio_get_unknown_subsystem_error" =>
               "d99057ebd1bee50d52fb7a25799124a0dae58dc73559f7f41dc90576ce3797c8",
             "minio_reset_missing_key_error" =>
               "e8d634def8735d6d061820c1cc11e3cdb450370577b13b6cc666afdb95ee0252",
             "minio_router_config_kv_routes" =>
               "cd7845d7e2019e47e63f5a5906c465bb160f4a9903211f0a219a705833117050",
             "minio_router_config_history_kv_routes" =>
               "48a2d65181d5a6f98148047d10c1fd34b1a3a4a04e1620271b0f75af4187be91",
             "minio_set_config_kv_action_and_decrypt" =>
               "80f8af1c1a2e2dc3518e86249a9a439e546f995479be29c9f2e4d1566617acb1",
             "minio_subsys_info_write_to" =>
               "3e0c076b97d4150a5d40d17279b35c8f7e18fe0e65f7915d29f7b09c9f9cf04b"
           }

    assert Map.new(routes["source_excerpts"], fn {id, excerpt} ->
             {id, excerpt["raw_file_sha256"]}
           end) == %{
             "madmin_del_config_kv_wire" =>
               "4b590f9aed14fee7a5f2a3a20f062047fd15d7128de2d45cae3a0d43e156f1b0",
             "madmin_get_config_kv_wire" =>
               "4b590f9aed14fee7a5f2a3a20f062047fd15d7128de2d45cae3a0d43e156f1b0",
             "madmin_new_request_entity_headers" =>
               "932edaeb340bfdc9343db8f31124ea749cfc4836ab86b7196c5b2a876a9bea4e",
             "madmin_sanitize_value" =>
               "ea19fd427661619df7e8bdf878743186950eeeb7c94ea989481dcfcc11cf8d79",
             "madmin_set_config_kv_wire" =>
               "4b590f9aed14fee7a5f2a3a20f062047fd15d7128de2d45cae3a0d43e156f1b0",
             "mc_config_get_help_branch" =>
               "651d9d79f8546e55ab6fe4cad7b6113c8469bf70ba08aa766815e1d80dea51a3",
             "mc_config_get_rendering" =>
               "651d9d79f8546e55ab6fe4cad7b6113c8469bf70ba08aa766815e1d80dea51a3",
             "mc_config_reset_help_branch" =>
               "2713ebb31a413dd1150e328698f38dea04d9f4010d7cb86d9ee58bd87da1a1d9",
             "mc_config_reset_rendering" =>
               "2713ebb31a413dd1150e328698f38dea04d9f4010d7cb86d9ee58bd87da1a1d9",
             "mc_config_set_help_branch" =>
               "babb2a3b100dac1f65ab9eba809a4f5d582618ce9d1afa8453335b5280df0201",
             "mc_config_set_rendering" =>
               "babb2a3b100dac1f65ab9eba809a4f5d582618ce9d1afa8453335b5280df0201",
             "mc_print_non_tty_compaction" =>
               "2797d5a0be76b4f5e06421f09069421df36883f7feee425bbb7c93d46bb2cccb",
             "minio_config_error_construction" =>
               "902a8372c78a7fa976a8faae1aee06fedc2081d8315103ddf2801541ef0ffdb3",
             "minio_del_config_kv_action_and_decrypt" =>
               "b2741a0e9a8bf29c951b7b6adbc398655fd43683f993af16539caf1f3cbb78d0",
             "minio_get_config_kv_action" =>
               "b2741a0e9a8bf29c951b7b6adbc398655fd43683f993af16539caf1f3cbb78d0",
             "minio_get_unknown_subsystem_error" =>
               "902a8372c78a7fa976a8faae1aee06fedc2081d8315103ddf2801541ef0ffdb3",
             "minio_reset_missing_key_error" =>
               "902a8372c78a7fa976a8faae1aee06fedc2081d8315103ddf2801541ef0ffdb3",
             "minio_router_config_history_kv_routes" =>
               "4f33d9984e39f08f31274ee818856db432ac85e5ffd2fda0b154e7eb34c595a9",
             "minio_router_config_kv_routes" =>
               "4f33d9984e39f08f31274ee818856db432ac85e5ffd2fda0b154e7eb34c595a9",
             "minio_set_config_kv_action_and_decrypt" =>
               "b2741a0e9a8bf29c951b7b6adbc398655fd43683f993af16539caf1f3cbb78d0",
             "minio_subsys_info_write_to" =>
               "902a8372c78a7fa976a8faae1aee06fedc2081d8315103ddf2801541ef0ffdb3"
           }

    assert routes["field_source_map"] == @field_source_map

    assert Enum.all?(routes["provenance"], fn %{"url" => url} ->
             String.starts_with?(url, "https://raw.githubusercontent.com/") and
               not String.contains?(url, "/master/") and not String.contains?(url, "/main/")
           end)
  end

  test "fixture freezes all ConfigUpdate routes plus missing-versus-empty key behavior",
       fixtures do
    routes = fixtures["minio_routes_and_errors"]

    assert Enum.map(routes["routes"], fn route ->
             {route["id"], route["method"], route["path"], route["action"]}
           end) == [
             {"KV1", "GET", "/minio/admin/v3/get-config-kv", "admin:ConfigUpdate"},
             {"KV2", "PUT", "/minio/admin/v3/set-config-kv", "admin:ConfigUpdate"},
             {"KV3", "DELETE", "/minio/admin/v3/del-config-kv", "admin:ConfigUpdate"}
           ]

    assert routes["query_branches"] == @query_branches

    assert routes["error_precedence"] == [
             "authentication",
             "route_and_admin_ConfigUpdate_authorization",
             "query_or_mutation_framing",
             "actual_read_length",
             "SigV4_payload_hash",
             "SIO_decrypt",
             "KVS_syntax",
             "exposure_boundary",
             "scalar_validation",
             "transactional_apply",
             "postcommit"
           ]
  end

  test "fixture separates generic not-found and BadJSON public errors", fixtures do
    errors = fixtures["minio_routes_and_errors"]["errors"]

    assert errors == @errors
  end

  test "fixture freezes entity framing and applied-header restart branches", fixtures do
    wire = fixtures["madmin_config_kv_wire"]
    sample = Base.decode16!(@ciphertext_hex, case: :lower)

    assert wire["ciphertext_hex"] == @ciphertext_hex
    assert byte_size(sample) == wire["ciphertext_byte_length"]
    assert wire["entity_matrix"] == @entity_matrix

    assert wire["applied_header"] == %{
             "missing_branch" => %{"restart" => true, "value" => "absent"},
             "name" => "x-minio-config-applied",
             "other_value_branch" => %{"restart" => true, "value" => "not_true"},
             "true_branch" => %{"restart" => false, "value" => "true"}
           }

    assert wire["value_sanitization"] == @value_sanitization
  end

  test "fixture freezes exact dynamic descriptions and the real deferred history routes",
       fixtures do
    routes = fixtures["minio_routes_and_errors"]

    assert routes["dynamic_error_descriptions"] == @dynamic_error_descriptions
    assert routes["unsupported_config_history_routes"] == @unsupported_config_history_routes
  end

  test "fixture keeps the duplicate-reset deviation and unsupported catalog from becoming parity claims",
       fixtures do
    routes = fixtures["minio_routes_and_errors"]

    assert routes["same_body_reset"] == %{
             "body_utf8" => "s3\ns3\n",
             "independent_retry" => %{
               "meaning" => "successful_noop_zero_version_zero_audit_zero_postcommit",
               "normally_status" => 200
             },
             "maxio" => %{"meaning" => "full_subsystem_reset_once", "status" => 200},
             "upstream" => %{"status" => 400}
           }

    assert Enum.map(routes["deliberate_deviations"], & &1["id"]) == [
             "maxio-unauthenticated-admin-route-concealment",
             "maxio-exact-content-length-framing",
             "maxio-hidden-reset-generic-error",
             "maxio-duplicate-full-reset-noop",
             "maxio-runtime-audit-atomicity"
           ]

    assert routes["unsupported_catalog_claims"] == @unsupported_catalog_claims
  end

  test "fixture preserves every human stdout byte including trailing space and LF", fixtures do
    human = fixtures["mc_config_human"]

    assert human["capture"] == %{
             "MC_CONFIG_DIR" => "isolated",
             "color" => "disabled",
             "encoding" => "utf-8",
             "stdout" => "non_tty"
           }

    assert human["stdout"] == @human_stdout

    for {_id, output} <- human["stdout"] do
      assert byte_size(output["utf8"]) == output["utf8_length"]
      assert Base.encode16(output["utf8"], case: :lower) == output["hex"]
      assert String.ends_with?(output["utf8"], "\n")
      refute String.ends_with?(output["utf8"], "\n\n")
    end

    assert human["local_help_or_rejection"] == %{
             "get_alias_only" => "help-config-kv_no_get_http",
             "reset_alias_only" => "help-config-kv_no_delete_http",
             "reset_tail_contains_equals" => "local_error_no_http",
             "set_without_equals" => "help-config-kv_no_set_http"
           }
  end

  test "fixture requires compact one-line non-TTY JSON with exactly one LF", fixtures do
    json = fixtures["mc_config_json"]

    assert json["mode"] == %{
             "argv_requires" => "--json",
             "encoding" => "compact_json",
             "pretty_output_forbidden" => true,
             "stdout" => "non_tty",
             "trailing_lf_count" => 1
           }

    assert json["stdout"] == @json_stdout

    for {_id, output} <- json["stdout"] do
      assert byte_size(output["utf8"]) == output["utf8_length"]
      assert Base.encode16(output["utf8"], case: :lower) == output["hex"]
      assert String.ends_with?(output["utf8"], "\n")
      refute String.contains?(String.trim_trailing(output["utf8"], "\n"), "\n")
      assert {:ok, _decoded} = Jason.decode(output["utf8"])
    end
  end
end
