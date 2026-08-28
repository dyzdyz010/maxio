defmodule Maxio.Admin.PolicyAssociationRequestTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Maxio.Admin.PolicyAssociationRequest

  @fixture_path Path.expand(
                  "../../fixtures/minio_admin_policy_s3/minio_p6_policy_association.json",
                  __DIR__
                )

  setup_all do
    fixture = @fixture_path |> File.read!() |> Jason.decode!()
    {:ok, fixture: fixture}
  end

  test "fixture freezes provenance, route, transport and OR authorization", %{fixture: fixture} do
    assert fixture["provenance"] == %{
             "minio_commit" => "7aac2a2c5b7c882e68c1ce017d8256be2feea27f",
             "madmin_go_tag" => "v3.0.109",
             "madmin_go_commit" => "6897865311e2be91d814ea0ef4814a730d87d1cd",
             "minio_pkg_v3_tag" => "v3.1.3",
             "minio_pkg_v3_commit" => "63a2eac5884b50aede4df00b84d16060dfd6791d"
           }

    contract = fixture["frozen_contract"]

    assert contract["route"] == %{
             "method" => "POST",
             "path_template" => "/minio/admin/v3/idp/builtin/policy/{operation}",
             "accepted_operations" => ["attach", "detach"]
           }

    assert contract["authorization"] == %{
             "semantics" => "OR",
             "ordered_actions" => [
               "admin:UpdatePolicyAssociation",
               "admin:AttachUserOrGroupPolicy"
             ]
           }

    assert contract["transport"]["gate_order_after_authentication"] == [
             "content_length",
             "content_type",
             "operation",
             "decrypt"
           ]

    assert contract["transport"]["content_type_exact"] == "application/octet-stream"
    assert contract["transport"]["maximum_encrypted_content_length"] == 262_272
    assert contract["transport"]["known_operation_zero_length"]["reaches_decrypt"]
    refute contract["transport"]["unknown_operation"]["decrypts_body"]
  end

  test "fixture freezes request precedence, attach/detach asymmetry and combination errors", %{
    fixture: fixture
  } do
    contract = fixture["frozen_contract"]

    assert contract["validation_precedence"]["overall"] == [
             "request_is_valid",
             "target",
             "operation_specific_policy_or_no_effect"
           ]

    assert contract["validation_precedence"]["user_target"] == [
             "temporary_user_forbidden",
             "configured_root_forbidden",
             "user_exists"
           ]

    assert contract["validation_precedence"]["group_target"] == [
             "group_exists",
             "group_enabled"
           ]

    assert Enum.map(contract["request_plaintext"]["is_valid_error_order"], & &1["error"]) == [
             "no policy names were given",
             "an empty policy name was given",
             "no user or group association was given",
             "either a group or a user association must be given, not both"
           ]

    matrix = Map.new(contract["combination_error_matrix"], &{&1["case"], &1})

    assert matrix["invalid-request-beats-target-and-policy"]["expected_stage"] ==
             "request_is_valid"

    assert matrix["missing-user-beats-attach-missing-policy"]["code"] ==
             "XMinioAdminNoSuchUser"

    assert matrix["attach-missing-policy-beats-no-effect-and-writes-nothing"][
             "atomic_writes"
           ] == 0

    assert matrix["detach-ignores-unmapped-or-undefined-items-when-intersection-exists"][
             "policiesDetached"
           ] == ["attached-policy"]

    assert matrix["detach-empty-intersection-is-no-effect"]["code"] ==
             "XMinioAdminPolicyChangeAlreadyApplied"
  end

  test "fixture freezes actual-change success and server no-effect versus mc synthesis", %{
    fixture: fixture
  } do
    contract = fixture["frozen_contract"]

    assert Jason.decode!(fixture["exact_wire_samples"]["attach_success_plaintext"])[
             "policiesAttached"
           ] == ["a-policy", "z-policy"]

    assert contract["no_effect"] == %{
             "http_status" => 400,
             "code" => "XMinioAdminPolicyChangeAlreadyApplied",
             "description" => "The specified policy change is already in effect.",
             "cause" => "Specified policy update has no net effect",
             "message" =>
               "The specified policy change is already in effect. (Specified policy update has no net effect)",
             "writes" => 0,
             "notifications" => 0,
             "mc_behavior" =>
               "swallow error and synthesize success from the original requested policy slice, preserving order and duplicates"
           }
  end

  test "valid transport reaches the not-yet-implemented P6 request parser" do
    body = <<0>>

    conn =
      :post
      |> conn("/minio/admin/v3/idp/builtin/policy/attach", body)
      |> delete_req_header("content-length")
      |> put_req_header("content-length", "1")
      |> put_req_header("content-type", "application/octet-stream")

    assert 1 = PolicyAssociationRequest.validate_transport!(conn)
  end
end
