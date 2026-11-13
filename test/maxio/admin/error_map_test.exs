defmodule Maxio.Admin.ErrorMapTest do
  use ExUnit.Case, async: true

  alias Maxio.Admin.ErrorMap

  test "maps frozen group lifecycle errors exactly" do
    assert %{code: "XMinioAdminNoSuchGroup", http_status: 404, message: message} =
             ErrorMap.from_reason(:group_not_found)

    assert message == "The specified group does not exist."

    assert %{
             code: "XMinioAdminGroupNotEmpty",
             http_status: 400,
             message: "The specified group is not empty - cannot remove it."
           } = ErrorMap.from_reason(:group_not_empty)

    assert %{
             code: "XMinioInvalidGroupName",
             http_status: 400,
             message: "The group name is invalid."
           } = ErrorMap.from_reason(:invalid_group_name)
  end

  test "maps MinIO group handler causes instead of static catalog messages" do
    assert %{
             code: "XMinioAdminNoSuchUser",
             http_status: 404,
             message: "The specified user does not exist. (Specified user does not exist)"
           } = ErrorMap.from_reason(:minio_user_not_found)

    assert %{
             code: "XMinioAdminNoSuchGroup",
             http_status: 404,
             message: "The specified group does not exist. (Specified group does not exist)"
           } = ErrorMap.from_reason(:minio_group_not_found)

    assert %{
             code: "XMinioAdminGroupNotEmpty",
             http_status: 400,
             message:
               "The specified group is not empty - cannot remove it. " <>
                 "(Specified group is not empty - cannot remove it)"
           } = ErrorMap.from_reason(:minio_group_not_empty)

    assert %{
             code: "XMinioAdminInvalidArgument",
             http_status: 400,
             message: "Invalid arguments specified. (Invalid arguments specified)"
           } = ErrorMap.from_reason(:minio_invalid_argument)
  end

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

  test "maps Config KVS route and adapter reasons to the three frozen public contracts" do
    assert %{
             code: "XMinioAdminVersionMismatch",
             http_status: 426,
             message: "This 'admin' API is not supported by server in 'maxio'"
           } = ErrorMap.from_reason(:admin_version_mismatch)

    assert %{
             code: "XMinioConfigError",
             http_status: 400,
             message: "Configuration specified is invalid"
           } = ErrorMap.from_reason(:config_generic)

    assert %{
             code: "XMinioConfigNotFoundError",
             http_status: 404,
             message: "Configuration key/value not found"
           } = ErrorMap.from_reason(:config_not_found)
  end

  test "Config KVS tuple mappings preserve only pinned safe descriptions" do
    for {reason, status, code, message} <- [
          {{:config_generic, "unknown subsystem: "}, 400, "XMinioConfigError",
           "unknown subsystem: "},
          {{:config_generic, "unknown subsystem: absent"}, 400, "XMinioConfigError",
           "unknown subsystem: absent"},
          {{:config_generic, "unknown sub-system absent value=1"}, 400, "XMinioConfigError",
           "unknown sub-system absent value=1"},
          {{:config_generic, "sub-system 's3' cannot have empty keys"}, 400, "XMinioConfigError",
           "sub-system 's3' cannot have empty keys"},
          {{:config_not_found, "key absent doesn't exist"}, 404, "XMinioConfigNotFoundError",
           "key absent doesn't exist"}
        ] do
      assert %{http_status: ^status, code: ^code, message: ^message} =
               ErrorMap.from_reason(reason)
    end

    secret = "caller_secret=CONFIG-KV-DO-NOT-DISCLOSE"
    unsafe = ErrorMap.from_reason({:config_generic, secret})
    assert unsafe.code == "XMinioConfigError"
    assert unsafe.http_status == 400
    assert unsafe.message == "Configuration specified is invalid"
    refute unsafe.message =~ secret
  end

  test "config archive unknown subsystem uses the fixture generic message without scalar input" do
    error = ErrorMap.from_reason({:config_unknown_subsystem, "absent"})

    assert error.http_status == 400
    assert error.code == "XMinioConfigError"
    assert error.message == "unknown sub-system absent"

    for unsafe_subsystem <- [
          "root_password",
          "SECRET-CONFIG-ARCHIVE-SENTINEL",
          "bad/control"
        ] do
      unsafe = ErrorMap.from_reason({:config_unknown_subsystem, unsafe_subsystem})
      assert unsafe.http_status == 400
      assert unsafe.code == "XMinioConfigError"
      assert unsafe.message == "Configuration specified is invalid"
      refute inspect(unsafe) =~ unsafe_subsystem
    end

    refute error.code =~ "XMaxio"
  end

  test "uppercase Config identifiers remain exact while unsafe dynamic descriptions fall back" do
    generic_exact = ErrorMap.from_reason({:config_generic, "unknown subsystem: S3"})
    not_found_exact = ErrorMap.from_reason({:config_not_found, "key ABSENT doesn't exist"})

    unsafe_identifiers = [
      "SECRETCONFIGKVSENTINEL",
      "CONTROL\u0001MARK",
      String.duplicate("A", 129)
    ]

    unsafe_errors =
      Enum.flat_map(unsafe_identifiers, fn identifier ->
        [
          {identifier,
           ErrorMap.from_reason({:config_generic, "unknown subsystem: #{identifier}"})},
          {identifier,
           ErrorMap.from_reason({:config_not_found, "key #{identifier} doesn't exist"})}
        ]
      end)

    assert %{http_status: 400, code: "XMinioConfigError", message: "unknown subsystem: S3"} =
             generic_exact

    assert %{
             http_status: 404,
             code: "XMinioConfigNotFoundError",
             message: "key ABSENT doesn't exist"
           } = not_found_exact

    for {identifier, error} <- unsafe_errors do
      assert error.message in [
               "Configuration specified is invalid",
               "Configuration key/value not found"
             ]

      refute inspect(error) =~ identifier
    end
  end

  test "Config help preserves only safe unknown-key descriptions with a separately safe subsystem" do
    safe =
      ErrorMap.from_reason({:config_generic, "unknown key clock_skew_ms for sub-system s3"})

    assert safe.code == "XMinioConfigError"
    assert safe.http_status == 400
    assert safe.message == "unknown key clock_skew_ms for sub-system s3"

    unsafe_descriptions = [
      "unknown key root_password for sub-system s3",
      "unknown key clock_skew_ms for sub-system credential_store",
      "unknown key credential for sub-system s3",
      "unknown key clock_skew_ms for sub-system SECRETCONFIGKVSENTINEL",
      "unknown key bad/control for sub-system s3",
      "unknown key clock_skew_ms for sub-system bad/control"
    ]

    for description <- unsafe_descriptions do
      error = ErrorMap.from_reason({:config_generic, description})
      assert error.code == "XMinioConfigError"
      assert error.http_status == 400
      assert error.message == "Configuration specified is invalid"
      refute error.message =~ description
    end
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
