defmodule Maxio.Admin.PolicyEntitiesRequestTest do
  use ExUnit.Case, async: true

  alias Maxio.Admin.PolicyEntitiesRequest

  @fixture_path Path.expand(
                  "../../fixtures/minio_admin_policy_s3/minio_p7_policy_entities.json",
                  __DIR__
                )

  @mc_fixture_path Path.expand(
                     "../../fixtures/minio_admin_policy_s3/mc_policy_lifecycle.json",
                     __DIR__
                   )

  setup_all do
    fixture = @fixture_path |> File.read!() |> Jason.decode!()
    mc_fixture = @mc_fixture_path |> File.read!() |> Jason.decode!()
    {:ok, fixture: fixture, mc_fixture: mc_fixture}
  end

  test "fixture freezes P7 route, OR authorization and repeated filters", %{fixture: fixture} do
    contract = fixture["frozen_contract"]

    assert fixture["provenance"]["minio_commit"] ==
             "7aac2a2c5b7c882e68c1ce017d8256be2feea27f"

    assert fixture["provenance"]["madmin_go_commit"] ==
             "6897865311e2be91d814ea0ef4814a730d87d1cd"

    assert contract["route"] == %{
             "method" => "GET",
             "path" => "/minio/admin/v3/idp/builtin/policy-entities"
           }

    assert contract["authorization"] == %{
             "semantics" => "OR",
             "ordered_actions" => [
               "admin:ListGroups",
               "admin:ListUsers",
               "admin:ListUserPolicies"
             ]
           }

    assert contract["query"]["repeatable_keys"] == ["user", "group", "policy"]

    assert contract["query"]["percent_encoded_values"]["decoded"] == %{
             "users" => ["alice+ops"],
             "groups" => ["data science"],
             "policies" => ["read/only"]
           }

    assert contract["query"]["malformed_percent_encoding"] == "VERIFY-AT-IMPL"
  end

  test "fixture freezes empty, unknown, top-level omission and inner-null cases", %{
    fixture: fixture
  } do
    cases = fixture["exact_plaintext_cases"]

    assert cases["empty_query_no_mappings"]["json"] == %{
             "timestamp" => "2026-08-28T01:02:03Z"
           }

    assert cases["unknown_values_omitted"]["json"] == %{
             "timestamp" => "2026-08-28T01:02:03Z"
           }

    inner_null = cases["inner_nil_slices_are_null"]["json"]
    assert get_in(inner_null, ["userMappings", Access.at(0), "policies"]) == nil
    assert get_in(inner_null, ["policyMappings", Access.at(0), "users"]) == nil
    assert get_in(inner_null, ["policyMappings", Access.at(1), "groups"]) == nil

    refute Map.has_key?(cases["empty_query_no_mappings"]["json"], "userMappings")
    refute Map.has_key?(cases["empty_query_no_mappings"]["json"], "groupMappings")
    refute Map.has_key?(cases["empty_query_no_mappings"]["json"], "policyMappings")
  end

  test "fixture freezes stable sorting and the named STS model-scope deviation", %{
    fixture: fixture
  } do
    mixed = fixture["exact_plaintext_cases"]["repeated_mixed_filters_sorted"]

    assert mixed["normalized"] == %{
             "users" => ["alice", "zoe"],
             "groups" => ["auditors", "writers"],
             "policies" => ["a-policy", "z-policy"],
             "requested_dimensions" => ["group", "policy", "user"]
           }

    assert Enum.map(mixed["json"]["userMappings"], & &1["user"]) == ["alice", "zoe"]

    assert Enum.map(mixed["json"]["groupMappings"], & &1["group"]) == [
             "auditors",
             "writers"
           ]

    assert Enum.map(mixed["json"]["policyMappings"], & &1["policy"]) == [
             "a-policy",
             "z-policy"
           ]

    assert fixture["upstream_persisted_sts_projection"]["included"]

    assert [deviation] = fixture["maxio_model_scope_deviations"]
    assert deviation["id"] == "p7-persisted-sts-user-policy-mapping"
    assert deviation["classification"] == "model_scope_deviation"
    assert deviation["wire_visible"]
    assert deviation["parity_claim"] == "not full upstream parity"
  end

  test "mc fixture freezes argv, no-effect synthesis and exact human/JSON output", %{
    mc_fixture: fixture
  } do
    assert fixture["provenance"]["mc_commit"] ==
             "77f82e18b5401a65958f1619df6ebb994634bd88"

    assert fixture["argv_contract"]["attach_human"] == [
             "admin",
             "policy",
             "attach",
             "ALIAS",
             "z-policy",
             "a-policy",
             "z-policy",
             "--user",
             "alice"
           ]

    assert fixture["no_effect_synthesis"]["preserves_order"]
    assert fixture["no_effect_synthesis"]["preserves_duplicates"]

    assert fixture["association_success_outputs"]["attach_user_human_stdout"] ==
             "Attached Policies: [a-policy z-policy]\nTo User: alice\n"

    assert fixture["association_success_outputs"]["attach_user_json_stdout"] ==
             "{\n \"status\": \"success\",\n \"policiesAttached\": [\n  \"a-policy\",\n  \"z-policy\"\n ],\n \"user\": \"alice\"\n}\n"

    assert fixture["no_effect_synthesis"]["attach_human_stdout"] ==
             "Attached Policies: [z-policy a-policy z-policy]\nTo User: alice\n"

    assert fixture["entities_outputs"]["human_stdout"] ==
             "Query time: 2026-08-28T01:02:03Z\nPolicy -> Entity Mappings:\n  Policy: a-policy\n    User Mappings:\n      alice\n"

    assert String.ends_with?(fixture["entities_outputs"]["json_stdout"], "}\n")
    refute String.ends_with?(fixture["entities_outputs"]["json_stdout"], "}\n\n")
  end

  test "repeated mixed filters reach the not-yet-implemented P7 request parser" do
    query =
      "user=zoe&user=alice&user=zoe&group=writers&group=auditors&policy=z-policy&policy=a-policy"

    assert %{
             users: ["alice", "zoe"],
             groups: ["auditors", "writers"],
             policies: ["a-policy", "z-policy"],
             requested_dimensions: dimensions
           } = PolicyEntitiesRequest.parse!(query)

    assert dimensions == MapSet.new([:group, :policy, :user])
  end

  test "parser preserves requested dimensions while deduplicating decoded values" do
    assert %{
             users: ["", "alice+ops"],
             groups: ["data science"],
             policies: ["read/only"],
             requested_dimensions: requested
           } =
             PolicyEntitiesRequest.parse!(
               "user=alice%2Bops&user=alice%2Bops&user&group=data+science&policy=read%2Fonly&x=y"
             )

    assert requested == MapSet.new([:user, :group, :policy])
  end

  test "empty and unrelated queries retain empty-filter policy projection semantics" do
    for query <- ["", "unrelated=value"] do
      assert %{
               users: [],
               groups: [],
               policies: [],
               requested_dimensions: requested
             } = PolicyEntitiesRequest.parse!(query)

      assert requested == MapSet.new()
    end
  end

  test "malformed percent encoding is a named Maxio structured-400 defense deviation" do
    error =
      assert_raise Maxio.S3.Error, fn ->
        PolicyEntitiesRequest.parse!("user=broken%ZZ")
      end

    assert error.code == "XMinioAdminInvalidArgument"
    assert error.http_status == 400
  end
end
