defmodule Maxio.Admin.ConfigKVHelpProtocolFixtureTest do
  use ExUnit.Case, async: true

  @fixture_dir Path.expand("../../fixtures/minio_admin_config_help_s6", __DIR__)
  @s5_dir Path.expand("../../fixtures/minio_admin_config_kv_s5", __DIR__)

  @pinned %{
    "minio_help_route.json" => "7aac2a2c5b7c882e68c1ce017d8256be2feea27f",
    "madmin_help_wire.json" => "4b504b82db633e978a57d49443b2be75824244c3",
    "mc_help_dispatch.json" => "77f82e18b5401a65958f1619df6ebb994634bd88"
  }

  @source_hashes %{
    "minio_help_route.json" => %{
      "route" =>
        {"4f33d9984e39f08f31274ee818856db432ac85e5ffd2fda0b154e7eb34c595a9",
         "d0e0c6fdc035ff267ec1cbe4d7f8116be1ae1001e0214eea31cdf6139933b97a"},
      "handler" =>
        {"b2741a0e9a8bf29c951b7b6adbc398655fd43683f993af16539caf1f3cbb78d0",
         "01cd3549e4bf1753a9d7c81b65eb53d022410cb80246edef6e2e41daf46dd0da"},
      "help_shape_and_empty" =>
        {"87292bfc635e315827db852ae07f6d5e8952cb07bbf1db785bff3ab5fe0d9a7f",
         "5df2bc1e697eac9d1d0499c9fa359efe079c3b3d9618c55dcf5e3f16c571cc00"},
      "help_projection" =>
        {"87292bfc635e315827db852ae07f6d5e8952cb07bbf1db785bff3ab5fe0d9a7f",
         "61194c7d7d7a3e1b4a0e2bc733a98b8812341745da74426b41e9c27c63e74e1f"},
      "server_help_kv" =>
        {"989124ca75f5b6a19c829acf8fe0dec5c1d56945a20085c848f2b6b23c5e3c24",
         "613cb080d450021257d8f94d79bb0dabf29a42f1f47848f23a35afc425408d73"}
    },
    "madmin_help_wire.json" => %{
      "madmin_structs" =>
        {"1119bc4c5cca1861a78f28c092d1c5635cbd845a6635a5f8734f276ff0e689bd",
         "d912d6e8a884228fdb03cecd45b02b40412b33f89d80f0381ec54499a595ab85"},
      "madmin_help_method" =>
        {"1119bc4c5cca1861a78f28c092d1c5635cbd845a6635a5f8734f276ff0e689bd",
         "307fe965c5aab8ac0c5977ac3dbb0c04d9dbd1f979bda6a327724aeff5165497"},
      "admin_url_prefix" =>
        {"932edaeb340bfdc9343db8f31124ea749cfc4836ab86b7196c5b2a876a9bea4e",
         "e1358a9e949987f80f358497bf8a7c37015fdc9abb4e4b658d46214bdc666918"},
      "request_and_target_url" =>
        {"932edaeb340bfdc9343db8f31124ea749cfc4836ab86b7196c5b2a876a9bea4e",
         "2d28aa3e9dd794553922b4ea56c01a28e44d56017854157339a3d00800b6f489"},
      "admin_v3" =>
        {"106fdc467376f57a7b3ab11aaddd3f03fc180d9b78f2c1f665eefd23df3b2680",
         "8c2d7c958280facd35526270368d1fbc14c0c3388740885823e7c1648f54acb2"},
      "minio_server_help_kv" =>
        {"989124ca75f5b6a19c829acf8fe0dec5c1d56945a20085c848f2b6b23c5e3c24",
         "613cb080d450021257d8f94d79bb0dabf29a42f1f47848f23a35afc425408d73"},
      "minio_plaintext_encoder" =>
        {"b2741a0e9a8bf29c951b7b6adbc398655fd43683f993af16539caf1f3cbb78d0",
         "01cd3549e4bf1753a9d7c81b65eb53d022410cb80246edef6e2e41daf46dd0da"}
    },
    "mc_help_dispatch.json" => %{
      "get_branch" =>
        {"651d9d79f8546e55ab6fe4cad7b6113c8469bf70ba08aa766815e1d80dea51a3",
         "84bf6bdd1c99fbc08407513db8f533f940089eba155bbd1ef411f961c401617f"},
      "reset_branch" =>
        {"2713ebb31a413dd1150e328698f38dea04d9f4010d7cb86d9ee58bd87da1a1d9",
         "90528c82516b1e4aa588eda99a38c003879fc38d4f3a846991d748aa2da2c596"},
      "set_branch" =>
        {"babb2a3b100dac1f65ab9eba809a4f5d582618ce9d1afa8453335b5280df0201",
         "d3d98a58fdcef10b058dfb6b14fac7dba6046289b8de4d52933b9e1cfb8cd675"},
      "renderer" =>
        {"0c46fe275e62a8ba8ee20639cf12c8c1a783160cdea8a9f8ae6ff184e0b9db08",
         "7f9b8b17eed5e16e436c1f74d9947c3accc959ae87ed66734f82250233d37461"},
      "print_message" =>
        {"2797d5a0be76b4f5e06421f09069421df36883f7feee425bbb7c93d46bb2cccb",
         "994ae6150ee7955784061721c091e869d20f05eeb1aeedffe1049a8468416425"},
      "non_tty_json" =>
        {"9f0e7bdc05a3143e46a40420c1f0c901103c4e647c83fbb729810497894ec114",
         "dc95e484791540962f1bf2034ca54108ff161f6019255c04cf7f84601401b218"}
    }
  }

  @s5_hashes %{
    "README.md" => "70335d160e2b6258fb38af218a6df12627099c1c574619c3afe21e830970f278",
    "madmin_config_kv_wire.json" =>
      "089e6a78cb21b79850ad4d4423ce7ba692471164d7d448cfeddcca3fb0b79bcd",
    "mc_config_human.json" => "b07525ba8ea769ae0aa7f24c0eeebad543ced272123c1ff53e6861ffd04da14e",
    "mc_config_json.json" => "5caa68bbdebeea6d444905555930c929e0445b201d5748f02eaceb9b4f25209b",
    "minio_routes_and_errors.json" =>
      "598d7d36e0f2e21eb40678a076eb039397f3c58c765f04f409e0c57a8ccee081"
  }

  test "pinned identities, source hashes, and claim provenance are complete" do
    for {file, commit} <- @pinned do
      fixture = fixture(file)
      assert fixture["classification"] == "source_derived"
      assert fixture["pinned_commit"] == commit
      assert map_size(fixture["sources"]) > 0

      actual_hashes =
        Map.new(fixture["sources"], fn {source_id, source} ->
          {source_id, {source["raw_source_sha256"], source["excerpt_sha256"]}}
        end)

      assert actual_hashes == Map.fetch!(@source_hashes, file)

      source_ids = fixture["sources"] |> Map.keys() |> MapSet.new()

      file
      |> claim_source_lists(fixture)
      |> Enum.each(fn ids ->
        assert ids != []
        assert MapSet.subset?(MapSet.new(ids), source_ids)
      end)
    end
  end

  test "madmin request and response wire contract remains exact" do
    wire = fixture("madmin_help_wire.json")

    assert wire["method"] == "GET"
    assert wire["path"] == "/minio/admin/v3/help-config-kv"
    assert wire["required_query"] == ["subSys", "key"]
    assert wire["optional_presence_query"] == "env"

    assert wire["request_query_behavior"] == %{
             "subSys" => "always_set_even_when_empty",
             "key" => "always_set_even_when_empty",
             "env" => "set_to_empty_string_only_when_envOnly_is_true"
           }

    empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    assert wire["payload_sha256"] == empty_hash
    assert wire["request_header_contract"]["X-Amz-Content-Sha256"] == empty_hash
    assert wire["request_header_contract"]["Authorization"] =~ "SigV4"
    assert wire["required_headers"] == ["X-Amz-Content-Sha256", "Authorization"]

    assert wire["request_absent"] == [
             "Content-Length",
             "Transfer-Encoding",
             "Content-Type",
             "body",
             "SIO"
           ]

    assert wire["request_entity_evidence"]["content_bytes_length"] == 0
    assert wire["request_entity_evidence"]["sio"] == false
    assert wire["response_transport"] == "plaintext_json_one_lf"
    assert wire["unknown_fields"] == "rejected"

    assert wire["help_fields"] == ["subSys", "description", "multipleTargets", "keysHelp"]

    assert wire["minio_server_raw_key_fields"] == [
             "key",
             "type",
             "description",
             "optional",
             "multipleTargets"
           ]

    assert wire["madmin_client_key_fields"] == [
             "key",
             "description",
             "optional",
             "type",
             "multipleTargets"
           ]

    refute wire["minio_server_raw_key_fields"] == wire["madmin_client_key_fields"]
  end

  test "MinIO route and mc help dispatch matrix are exact and source-derived only" do
    route = fixture("minio_help_route.json")
    dispatch = fixture("mc_help_dispatch.json")

    assert route["claims"]["route"] == %{
             "method" => "GET",
             "path" => "/minio/admin/v3/help-config-kv",
             "required_query" => ["subSys", "key"],
             "empty_values_match" => true,
             "enabled_when_config_ops_disabled" => true,
             "source_ids" => ["route"]
           }

    assert route["claims"]["authorization"]["action"] == "admin:ConfigUpdate"
    assert route["claims"]["handler"]["success_transport"] == "plaintext_json_one_lf"
    assert route["claims"]["handler"]["sio_envelope"] == false

    assert Map.take(dispatch, [
             "get_alias_only",
             "reset_alias_only",
             "set_subsystem_without_equals",
             "set_key_without_equals"
           ]) == %{
             "get_alias_only" => ["help-config-kv", "subSys=", "key="],
             "reset_alias_only" => ["help-config-kv", "subSys=", "key="],
             "set_subsystem_without_equals" => ["help-config-kv", "subSys=s3", "key="],
             "set_key_without_equals" => ["help-config-kv", "subSys=s3", "key=clock_skew_ms"]
           }

    assert dispatch["dispatch_claims"]["get_alias_only"]["mutation_call"] == false
    assert dispatch["dispatch_claims"]["reset_alias_only"]["delete_call"] == false

    for {_name, transcript} <- dispatch["expected_transcripts"] do
      assert transcript["classification"] == "source_derived_expected_not_live"
      stdout = transcript["stdout_utf8"]
      assert String.ends_with?(stdout, "\n")
      refute String.ends_with?(stdout, "\n\n")
      assert byte_size(stdout) == transcript["byte_length"]
      assert sha256(stdout) == transcript["sha256"]
    end
  end

  test "the historical S5 fixture bytes remain unchanged" do
    assert @s5_hashes ==
             Map.new(@s5_hashes, fn {file, expected_hash} ->
               assert sha256(File.read!(Path.join(@s5_dir, file))) == expected_hash
               {file, expected_hash}
             end)
  end

  defp fixture(file), do: @fixture_dir |> Path.join(file) |> File.read!() |> Jason.decode!()

  defp claim_source_lists("minio_help_route.json", fixture) do
    fixture["claims"] |> Map.values() |> Enum.flat_map(&find_source_lists/1)
  end

  defp claim_source_lists("madmin_help_wire.json", fixture) do
    fixture["claim_sources"] |> Map.values()
  end

  defp claim_source_lists("mc_help_dispatch.json", fixture) do
    find_source_lists(fixture["dispatch_claims"]) ++
      find_source_lists(fixture["rendering_claims"])
  end

  defp find_source_lists(value) when is_map(value) do
    Enum.flat_map(value, fn
      {"source_ids", ids} -> [ids]
      {_key, nested} -> find_source_lists(nested)
    end)
  end

  defp find_source_lists(value) when is_list(value),
    do: Enum.flat_map(value, &find_source_lists/1)

  defp find_source_lists(_value), do: []

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
