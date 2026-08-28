defmodule Maxio.Admin.ErrorMapTest do
  use ExUnit.Case, async: true

  alias Maxio.Admin.ErrorMap

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
    quota = ErrorMap.from_reason(:policy_version_limit_exceeded)

    assert quota.code == "XMinioAdminInvalidArgument"
    assert quota.http_status == 400
    assert quota.message =~ "5"
    assert quota.message =~ "non-default"

    unknown = ErrorMap.from_reason({:unexpected, "credential=do-not-leak"})
    assert unknown.code == "InternalError"
    assert unknown.http_status == 500
    refute unknown.message =~ "credential"
    refute unknown.message =~ "do-not-leak"
  end
end
