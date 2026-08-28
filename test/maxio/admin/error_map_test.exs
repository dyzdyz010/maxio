defmodule Maxio.Admin.ErrorMapTest do
  use ExUnit.Case, async: true

  alias Maxio.Admin.ErrorMap

  test "maps every S2b input error to its exact public code, status, and message" do
    assert_error(
      :config_too_large,
      "XMinioAdminConfigTooLarge",
      "Configuration data provided exceeds the allowed maximum of 262272 bytes"
    )

    assert_error(
      :config_bad_json,
      "XMinioAdminConfigBadJSON",
      "JSON configuration provided is of incorrect format"
    )

    assert_error(
      :invalid_access_key,
      "XMinioAdminInvalidAccessKey",
      "The access key is invalid."
    )

    assert_error(
      :invalid_secret_key,
      "XMinioAdminInvalidSecretKey",
      "The secret key is invalid."
    )

    duplicate = ErrorMap.from_reason(:user_already_exists)

    assert duplicate.code == "XMaxioAdminUserAlreadyExists"
    assert duplicate.http_status == 400
    assert duplicate.message == "The specified user already exists."
    refute duplicate.code in ["XMinioAdminNoSuchUser", "XMinioAdminInvalidArgument"]
    refute duplicate.http_status == 409

    payload = ErrorMap.from_reason(:payload_hash_mismatch)

    assert payload.code == "XAmzContentSHA256Mismatch"
    assert payload.http_status == 400

    assert payload.message ==
             "The provided 'x-amz-content-sha256' header does not match what was computed."
  end

  test "maps policy absence and invalid documents or names to exact MinIO admin errors" do
    assert %{code: "XMinioAdminNoSuchPolicy", http_status: 404} =
             ErrorMap.from_reason(:not_found)

    assert %{code: "XMinioAdminInvalidArgument", http_status: 400} =
             ErrorMap.from_reason(:invalid_argument)

    assert %{code: "XMinioInvalidResource", http_status: 400} =
             ErrorMap.from_reason(:invalid_resource_name)

    assert %{code: "MalformedPolicy", http_status: 400} =
             ErrorMap.from_reason(:malformed_policy_document)
  end

  test "maps user absence without changing the policy absence contract" do
    assert %{
             code: "XMinioAdminNoSuchUser",
             http_status: 404,
             message: "The specified user does not exist."
           } = ErrorMap.from_reason(:user_not_found)

    assert %{code: "XMinioAdminNoSuchPolicy", http_status: 404} =
             ErrorMap.from_reason(:not_found)
  end

  test "maps U4 and U5 target errors to exact dynamic MinIO admin contracts" do
    for reason <- [:minio_user_not_found] do
      assert %{
               code: "XMinioAdminNoSuchUser",
               http_status: 404,
               message: "The specified user does not exist. (Specified user does not exist)"
             } = ErrorMap.from_reason(reason)
    end

    assert %{
             code: "XMinioIAMActionNotAllowed",
             http_status: 403,
             message: "Specified IAM action is not allowed"
           } = ErrorMap.from_reason(:minio_action_not_allowed)

    for reason <- [:invalid_status_self_target, :invalid_status_argument] do
      assert %{
               code: "XMinioAdminInvalidArgument",
               http_status: 400,
               message: "Invalid arguments specified. (Invalid arguments specified)"
             } = ErrorMap.from_reason(reason)
    end

    assert ErrorMap.from_reason(:invalid_argument).message == "Invalid arguments specified."
  end

  test "delete blockers are actionable without embedding entity maps" do
    attached =
      ErrorMap.from_reason(
        {:policy_attached,
         %{
           users: [%{user_name: "zoe"}, %{user_name: "alice", secret: "do-not-log"}],
           groups: [%{group_name: "ops"}],
           roles: [%{role_name: "reader"}]
         }}
      )

    assert attached.code == "XMinioAdminInvalidArgument"
    assert attached.http_status == 400
    assert attached.message =~ "alice, zoe"
    assert attached.message =~ "ops"
    assert attached.message =~ "reader"
    assert attached.message =~ "detach"
    refute attached.message =~ "do-not-log"
    refute attached.message =~ "%{"

    versions = ErrorMap.from_reason({:policy_has_non_default_versions, 2})
    assert versions.code == "XMinioAdminInvalidArgument"
    assert versions.message =~ "2"
    assert versions.message =~ "DeletePolicyVersion"
  end

  test "version quota is actionable and unknown reasons are redacted" do
    document_quota = ErrorMap.from_reason(:policy_limit_exceeded)

    assert document_quota.code == "XMinioAdminInvalidArgument"
    assert document_quota.http_status == 400
    assert document_quota.message =~ "6,144"
    assert document_quota.message =~ "delete an unused managed policy"

    version_quota = ErrorMap.from_reason(:policy_version_limit_exceeded)

    assert version_quota.code == "XMinioAdminInvalidArgument"
    assert version_quota.http_status == 400
    assert version_quota.message =~ "5"
    assert version_quota.message =~ "non-default"
    refute document_quota.message == version_quota.message
    refute document_quota.message =~ "DeletePolicyVersion"

    attachment_quota = ErrorMap.from_reason(:managed_policy_attachment_limit_exceeded)
    assert attachment_quota.code == "XMinioAdminInvalidArgument"
    assert attachment_quota.http_status == 400
    assert attachment_quota.message =~ "10 managed policies"
    refute attachment_quota.message =~ "6,144"

    unknown = ErrorMap.from_reason({:unexpected, "credential=do-not-leak"})
    assert unknown.code == "InternalError"
    assert unknown.http_status == 500
    refute unknown.message =~ "credential"
    refute unknown.message =~ "do-not-leak"
  end

  test "maps P6 target, disabled-group and no-effect errors exactly" do
    assert %{code: "XMinioAdminNoSuchGroup", http_status: 404} =
             ErrorMap.from_reason(:group_not_found)

    assert %{
             code: "XMinioAdminInvalidArgument",
             http_status: 400,
             message:
               "The specified group is disabled and cannot receive policy association updates."
           } = ErrorMap.from_reason(:group_disabled)

    assert %{
             code: "XMinioAdminPolicyChangeAlreadyApplied",
             http_status: 400,
             message:
               "The specified policy change is already in effect. (Specified policy update has no net effect)"
           } = ErrorMap.from_reason(:policy_change_already_applied)
  end

  defp assert_error(reason, code, message) do
    error = ErrorMap.from_reason(reason)
    assert error.code == code
    assert error.http_status == 400
    assert error.message == message
  end
end
