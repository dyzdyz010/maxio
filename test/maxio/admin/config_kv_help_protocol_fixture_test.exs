defmodule Maxio.Admin.ConfigKVHelpProtocolFixtureTest do
  use ExUnit.Case, async: true

  @fixture_dir Path.expand("../../fixtures/minio_admin_config_help_s6", __DIR__)
  @s5_dir Path.expand("../../fixtures/minio_admin_config_kv_s5", __DIR__)

  @pinned %{
    "minio_help_route.json" => "7aac2a2c5b7c882e68c1ce017d8256be2feea27f",
    "madmin_help_wire.json" => "4b504b82db633e978a57d49443b2be75824244c3",
    "mc_help_dispatch.json" => "77f82e18b5401a65958f1619df6ebb994634bd88"
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

      for {_id, source} <- fixture["sources"] do
        assert source["raw_source_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
        assert source["excerpt_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      end

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
