defmodule Maxio.Admin.ConfigKVProtocolFixtureTest do
  use ExUnit.Case, async: true

  @fixture_dir Path.expand("../../fixtures/minio_admin_config_kv_s5", __DIR__)

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
             "madmin_set_config_kv_wire" =>
               "115e8d856da915da1a3539dc3932e3068c676dc95a1364de7a4aa4a5f86229ec",
             "mc_config_get_rendering" =>
               "48e2f3cad229a128306ba2dd0b0f2ed9edd06ebeabee7c69b4dfa8024f3f844f",
             "mc_config_reset_rendering" =>
               "dd7590ee93ea4c1662462b6803dfeb1d4ea7adc307534491930405559fd94016",
             "mc_config_set_rendering" =>
               "d4ded1439ba1303de5198c525123fdc8586e8546ac3a22558c40f6bd4bc6839c",
             "mc_print_non_tty_compaction" =>
               "96338ddfe75ded06aeeecaa0572d236edf5904480a72492f5619382f291f4aa3",
             "minio_del_config_kv_action_and_decrypt" =>
               "7c7fd960f0e2f88fad3809b1e4900d101ec139c0e9595ea36821dea3add20307",
             "minio_get_config_kv_action" =>
               "c4183540d0a0395e62932d2dac4e8276790149e4c04b4775cd0eda422cd81fc3",
             "minio_router_config_kv_routes" =>
               "cd7845d7e2019e47e63f5a5906c465bb160f4a9903211f0a219a705833117050",
             "minio_set_config_kv_action_and_decrypt" =>
               "80f8af1c1a2e2dc3518e86249a9a439e546f995479be29c9f2e4d1566617acb1",
             "minio_subsys_info_write_to" =>
               "3e0c076b97d4150a5d40d17279b35c8f7e18fe0e65f7915d29f7b09c9f9cf04b"
           }

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

    assert routes["query_branches"]["missing_key_authenticated"] == %{
             "code" => "XMinioAdminVersionMismatch",
             "description_template" => "This 'admin' API is not supported by server in '<mode>'",
             "matches_handler" => false,
             "status" => 426
           }

    assert routes["query_branches"]["empty_key_authorized"] == %{
             "code" => "XMinioConfigError",
             "description" => "unknown subsystem: ",
             "matches_handler" => true,
             "status" => 400
           }

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

    assert errors["generic"]["code"] == "XMinioConfigError"
    assert errors["generic"]["status"] == 400

    assert errors["not_found"] == %{
             "code" => "XMinioConfigNotFoundError",
             "description" => "key absent doesn't exist",
             "only" => "reset of ordinary unknown key in exposed subsystem",
             "status" => 404
           }

    assert errors["bad_json"] == %{
             "causes" => [
               "invalid SIO envelope",
               "actual read length mismatch",
               "typed validator failure"
             ],
             "code" => "XMinioAdminConfigBadJSON",
             "description" => "JSON configuration provided is of incorrect format",
             "status" => 400
           }
  end

  test "fixture freezes entity framing and applied-header restart branches", fixtures do
    wire = fixtures["madmin_config_kv_wire"]
    sample = Base.decode16!(wire["ciphertext_hex"], case: :lower)

    assert byte_size(sample) == wire["ciphertext_utf8_length"]

    assert Enum.map(wire["entity_matrix"], fn entity ->
             {entity["id"], entity["content_length"], entity["transfer_encoding"],
              entity["content_type"], entity["body_length"]}
           end) == [
             {"get_request", "absent", "absent", "absent", 0},
             {"set_request", "58", "absent", "absent", 58},
             {"reset_request", "58", "absent", "absent", 58},
             {"get_response", "58", "absent", "application/json", 58},
             {"set_response", "0", "absent", "absent", 0},
             {"reset_response", "0", "absent", "absent", 0}
           ]

    assert wire["applied_header"] == %{
             "missing_branch" => %{"restart" => true, "value" => "absent"},
             "name" => "x-minio-config-applied",
             "other_value_branch" => %{"restart" => true, "value" => "not_true"},
             "true_branch" => %{"restart" => false, "value" => "true"}
           }
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

    refute "target" in routes["unsupported_catalog_claims"]
    assert "subsystem_target" in routes["unsupported_catalog_claims"]
    assert "api" in routes["unsupported_catalog_claims"]
    assert "site" in routes["unsupported_catalog_claims"]
    assert "service_restart" in routes["unsupported_catalog_claims"]
  end

  test "fixture preserves every human stdout byte including trailing space and LF", fixtures do
    human = fixtures["mc_config_human"]

    assert human["capture"] == %{
             "MC_CONFIG_DIR" => "isolated",
             "color" => "disabled",
             "encoding" => "utf-8",
             "stdout" => "non_tty"
           }

    assert human["stdout"]["get"]["utf8"] == "s3 clock_skew_ms=900000 \n"

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

    assert json["stdout"]["get"]["utf8"] ==
             "{\"status\":\"success\",\"config\":[{\"subSystem\":\"s3\",\"kv\":[{\"key\":\"clock_skew_ms\",\"value\":\"900000\"}]}]}\n"

    for {_id, output} <- json["stdout"] do
      assert byte_size(output["utf8"]) == output["utf8_length"]
      assert Base.encode16(output["utf8"], case: :lower) == output["hex"]
      assert String.ends_with?(output["utf8"], "\n")
      refute String.contains?(String.trim_trailing(output["utf8"], "\n"), "\n")
      assert {:ok, _decoded} = Jason.decode(output["utf8"])
    end
  end
end
