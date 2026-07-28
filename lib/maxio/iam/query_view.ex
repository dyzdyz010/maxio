defmodule Maxio.IAM.QueryView do
  @moduledoc "AWS IAM Query API XML response rendering."

  import Saxy.XML

  alias Maxio.IAM.QueryError
  alias Maxio.S3.XML
  alias Maxio.Tags

  @namespace "https://iam.amazonaws.com/doc/2010-05-08/"

  @spec create_user_response(map(), String.t() | nil) :: iodata()
  def create_user_response(user, request_id) when is_map(user) do
    root =
      element("CreateUserResponse", [{"xmlns", @namespace}], [
        element("CreateUserResult", [], [
          element("User", [], user_detail_children(user))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_user_response(map(), String.t() | nil) :: iodata()
  def get_user_response(user, request_id) when is_map(user) do
    root =
      element("GetUserResponse", [{"xmlns", @namespace}], [
        element("GetUserResult", [], [
          element("User", [], user_detail_children(user))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec update_user_response(map(), String.t() | nil) :: iodata()
  def update_user_response(user, request_id) when is_map(user) do
    root =
      element("UpdateUserResponse", [{"xmlns", @namespace}], [
        element("UpdateUserResult", [], [
          element("User", [], user_detail_children(user))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_users_response(map(), String.t() | nil) :: iodata()
  def list_users_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListUsersResponse", [{"xmlns", @namespace}], [
        element(
          "ListUsersResult",
          [],
          [
            element("IsTruncated", [], characters(to_string(is_truncated))),
            element("Users", [], Enum.map(Map.get(result, :users, []), &user_member/1))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec create_access_key_response(map(), String.t() | nil) :: iodata()
  def create_access_key_response(access_key, request_id) when is_map(access_key) do
    root =
      element("CreateAccessKeyResponse", [{"xmlns", @namespace}], [
        element("CreateAccessKeyResult", [], [
          element("AccessKey", [], access_key_children(access_key, include_secret: true))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_access_keys_response(map(), String.t() | nil) :: iodata()
  def list_access_keys_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListAccessKeysResponse", [{"xmlns", @namespace}], [
        element(
          "ListAccessKeysResult",
          [],
          [
            element(
              "AccessKeyMetadata",
              [],
              Enum.map(Map.get(result, :access_keys, []), &access_key_member/1)
            ),
            element("IsTruncated", [], characters(to_string(is_truncated)))
          ] ++ list_access_keys_user_name(result) ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec upload_signing_certificate_response(map(), String.t() | nil) :: iodata()
  def upload_signing_certificate_response(certificate, request_id) when is_map(certificate) do
    root =
      element("UploadSigningCertificateResponse", [{"xmlns", @namespace}], [
        element("UploadSigningCertificateResult", [], [
          element("Certificate", [], signing_certificate_children(certificate))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_signing_certificates_response(map(), String.t() | nil) :: iodata()
  def list_signing_certificates_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListSigningCertificatesResponse", [{"xmlns", @namespace}], [
        element(
          "ListSigningCertificatesResult",
          [],
          [
            element(
              "Certificates",
              [],
              Enum.map(Map.get(result, :certificates, []), &signing_certificate_member/1)
            ),
            element("IsTruncated", [], characters(to_string(is_truncated)))
          ] ++ list_signing_certificates_user_name(result) ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec upload_ssh_public_key_response(map(), String.t() | nil) :: iodata()
  def upload_ssh_public_key_response(ssh_public_key, request_id) when is_map(ssh_public_key) do
    root =
      element("UploadSSHPublicKeyResponse", [{"xmlns", @namespace}], [
        element("UploadSSHPublicKeyResult", [], [
          element("SSHPublicKey", [], ssh_public_key_children(ssh_public_key, "SSH"))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_ssh_public_key_response(map(), String.t(), String.t() | nil) :: iodata()
  def get_ssh_public_key_response(ssh_public_key, encoding, request_id)
      when is_map(ssh_public_key) do
    root =
      element("GetSSHPublicKeyResponse", [{"xmlns", @namespace}], [
        element("GetSSHPublicKeyResult", [], [
          element("SSHPublicKey", [], ssh_public_key_children(ssh_public_key, encoding))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_ssh_public_keys_response(map(), String.t() | nil) :: iodata()
  def list_ssh_public_keys_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListSSHPublicKeysResponse", [{"xmlns", @namespace}], [
        element(
          "ListSSHPublicKeysResult",
          [],
          [
            element(
              "SSHPublicKeys",
              [],
              Enum.map(Map.get(result, :ssh_public_keys, []), &ssh_public_key_metadata_member/1)
            ),
            element("IsTruncated", [], characters(to_string(is_truncated))),
            element("UserName", [], characters(Map.get(result, :user_name, "")))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_access_key_last_used_response(map(), String.t() | nil) :: iodata()
  def get_access_key_last_used_response(last_used, request_id) when is_map(last_used) do
    root =
      element("GetAccessKeyLastUsedResponse", [{"xmlns", @namespace}], [
        element("GetAccessKeyLastUsedResult", [], [
          element("UserName", [], characters(last_used.user_name)),
          element("AccessKeyLastUsed", [], access_key_last_used_children(last_used))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_account_summary_response(map(), String.t() | nil) :: iodata()
  def get_account_summary_response(summary, request_id) when is_map(summary) do
    root =
      element("GetAccountSummaryResponse", [{"xmlns", @namespace}], [
        element("GetAccountSummaryResult", [], [
          element("SummaryMap", [], summary_map_entries(summary))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_account_aliases_response(map(), String.t() | nil) :: iodata()
  def list_account_aliases_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListAccountAliasesResponse", [{"xmlns", @namespace}], [
        element(
          "ListAccountAliasesResult",
          [],
          [
            element(
              "AccountAliases",
              [],
              Enum.map(Map.get(result, :account_aliases, []), &member/1)
            ),
            element("IsTruncated", [], characters(to_string(is_truncated)))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_account_password_policy_response(map(), String.t() | nil) :: iodata()
  def get_account_password_policy_response(policy, request_id) when is_map(policy) do
    root =
      element("GetAccountPasswordPolicyResponse", [{"xmlns", @namespace}], [
        element("GetAccountPasswordPolicyResult", [], [
          element("PasswordPolicy", [], password_policy_children(policy))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec create_group_response(map(), String.t() | nil) :: iodata()
  def create_group_response(group, request_id) when is_map(group) do
    root =
      element("CreateGroupResponse", [{"xmlns", @namespace}], [
        element("CreateGroupResult", [], [
          element("Group", [], group_member_children(group))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_group_response(map(), String.t() | nil) :: iodata()
  def get_group_response(result, request_id) when is_map(result) do
    group = Map.fetch!(result, :group)
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("GetGroupResponse", [{"xmlns", @namespace}], [
        element(
          "GetGroupResult",
          [],
          [
            element("Group", [], group_member_children(group)),
            element("Users", [], Enum.map(Map.get(result, :users, []), &user_member/1)),
            element("IsTruncated", [], characters(to_string(is_truncated)))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_groups_response(map(), String.t() | nil) :: iodata()
  def list_groups_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListGroupsResponse", [{"xmlns", @namespace}], [
        element(
          "ListGroupsResult",
          [],
          [
            element("IsTruncated", [], characters(to_string(is_truncated))),
            element("Groups", [], Enum.map(Map.get(result, :groups, []), &group_member/1))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec create_role_response(map(), String.t() | nil) :: iodata()
  def create_role_response(role, request_id) when is_map(role) do
    root =
      element("CreateRoleResponse", [{"xmlns", @namespace}], [
        element("CreateRoleResult", [], [
          element("Role", [], role_detail_children(role))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_role_response(map(), String.t() | nil) :: iodata()
  def get_role_response(role, request_id) when is_map(role) do
    root =
      element("GetRoleResponse", [{"xmlns", @namespace}], [
        element("GetRoleResult", [], [
          element("Role", [], role_detail_children(role))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_roles_response(map(), String.t() | nil) :: iodata()
  def list_roles_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListRolesResponse", [{"xmlns", @namespace}], [
        element(
          "ListRolesResult",
          [],
          [
            element("IsTruncated", [], characters(to_string(is_truncated))),
            element("Roles", [], Enum.map(Map.get(result, :roles, []), &role_member/1))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec create_instance_profile_response(map(), String.t() | nil) :: iodata()
  def create_instance_profile_response(instance_profile, request_id)
      when is_map(instance_profile) do
    root =
      element("CreateInstanceProfileResponse", [{"xmlns", @namespace}], [
        element("CreateInstanceProfileResult", [], [
          element("InstanceProfile", [], instance_profile_detail_children(instance_profile))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_instance_profile_response(map(), String.t() | nil) :: iodata()
  def get_instance_profile_response(instance_profile, request_id) when is_map(instance_profile) do
    root =
      element("GetInstanceProfileResponse", [{"xmlns", @namespace}], [
        element("GetInstanceProfileResult", [], [
          element("InstanceProfile", [], instance_profile_detail_children(instance_profile))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_instance_profiles_response(map(), String.t() | nil) :: iodata()
  def list_instance_profiles_response(result, request_id) when is_map(result) do
    instance_profiles_response("ListInstanceProfiles", result, request_id)
  end

  @spec list_instance_profiles_for_role_response(map(), String.t() | nil) :: iodata()
  def list_instance_profiles_for_role_response(result, request_id) when is_map(result) do
    instance_profiles_response("ListInstanceProfilesForRole", result, request_id)
  end

  @spec upload_server_certificate_response(map(), String.t() | nil) :: iodata()
  def upload_server_certificate_response(server_certificate, request_id)
      when is_map(server_certificate) do
    root =
      element("UploadServerCertificateResponse", [{"xmlns", @namespace}], [
        element("UploadServerCertificateResult", [], [
          element(
            "ServerCertificateMetadata",
            [],
            server_certificate_metadata_children(server_certificate)
          )
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_server_certificate_response(map(), String.t() | nil) :: iodata()
  def get_server_certificate_response(server_certificate, request_id)
      when is_map(server_certificate) do
    root =
      element("GetServerCertificateResponse", [{"xmlns", @namespace}], [
        element("GetServerCertificateResult", [], [
          element("ServerCertificate", [], server_certificate_detail_children(server_certificate))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_server_certificates_response(map(), String.t() | nil) :: iodata()
  def list_server_certificates_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListServerCertificatesResponse", [{"xmlns", @namespace}], [
        element(
          "ListServerCertificatesResult",
          [],
          [
            element(
              "ServerCertificateMetadataList",
              [],
              Enum.map(
                Map.get(result, :server_certificates, []),
                &server_certificate_metadata_member/1
              )
            ),
            element("IsTruncated", [], characters(to_string(is_truncated)))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_groups_for_user_response(map(), String.t() | nil) :: iodata()
  def list_groups_for_user_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListGroupsForUserResponse", [{"xmlns", @namespace}], [
        element(
          "ListGroupsForUserResult",
          [],
          [
            element("IsTruncated", [], characters(to_string(is_truncated))),
            element("Groups", [], Enum.map(Map.get(result, :groups, []), &group_member/1))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_user_policy_response(map(), String.t() | nil) :: iodata()
  def get_user_policy_response(policy, request_id) when is_map(policy) do
    root =
      element("GetUserPolicyResponse", [{"xmlns", @namespace}], [
        element("GetUserPolicyResult", [], [
          element("UserName", [], characters(policy.user_name)),
          element("PolicyName", [], characters(policy.policy_name)),
          element("PolicyDocument", [], characters(encoded_policy_document(policy)))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_group_policy_response(map(), String.t() | nil) :: iodata()
  def get_group_policy_response(policy, request_id) when is_map(policy) do
    root =
      element("GetGroupPolicyResponse", [{"xmlns", @namespace}], [
        element("GetGroupPolicyResult", [], [
          element("GroupName", [], characters(policy.group_name)),
          element("PolicyName", [], characters(policy.policy_name)),
          element("PolicyDocument", [], characters(encoded_policy_document(policy)))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_role_policy_response(map(), String.t() | nil) :: iodata()
  def get_role_policy_response(policy, request_id) when is_map(policy) do
    root =
      element("GetRolePolicyResponse", [{"xmlns", @namespace}], [
        element("GetRolePolicyResult", [], [
          element("RoleName", [], characters(policy.role_name)),
          element("PolicyName", [], characters(policy.policy_name)),
          element("PolicyDocument", [], characters(encoded_policy_document(policy)))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_user_policies_response(map(), String.t() | nil) :: iodata()
  def list_user_policies_response(result, request_id) when is_map(result) do
    policy_names_response("ListUserPolicies", result, request_id)
  end

  @spec list_group_policies_response(map(), String.t() | nil) :: iodata()
  def list_group_policies_response(result, request_id) when is_map(result) do
    policy_names_response("ListGroupPolicies", result, request_id)
  end

  @spec list_role_policies_response(map(), String.t() | nil) :: iodata()
  def list_role_policies_response(result, request_id) when is_map(result) do
    policy_names_response("ListRolePolicies", result, request_id)
  end

  @spec list_attached_user_policies_response(map(), String.t() | nil) :: iodata()
  def list_attached_user_policies_response(result, request_id) when is_map(result) do
    attached_policies_response("ListAttachedUserPolicies", result, request_id)
  end

  @spec list_attached_group_policies_response(map(), String.t() | nil) :: iodata()
  def list_attached_group_policies_response(result, request_id) when is_map(result) do
    attached_policies_response("ListAttachedGroupPolicies", result, request_id)
  end

  @spec list_attached_role_policies_response(map(), String.t() | nil) :: iodata()
  def list_attached_role_policies_response(result, request_id) when is_map(result) do
    attached_policies_response("ListAttachedRolePolicies", result, request_id)
  end

  @spec create_policy_response(map(), String.t() | nil) :: iodata()
  def create_policy_response(policy, request_id) when is_map(policy) do
    root =
      element("CreatePolicyResponse", [{"xmlns", @namespace}], [
        element("CreatePolicyResult", [], [
          element("Policy", [], policy_detail_children(policy, include_tags: true))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_policy_response(map(), String.t() | nil) :: iodata()
  def get_policy_response(policy, request_id) when is_map(policy) do
    root =
      element("GetPolicyResponse", [{"xmlns", @namespace}], [
        element("GetPolicyResult", [], [
          element("Policy", [], policy_detail_children(policy, include_tags: true))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_policies_response(map(), String.t() | nil) :: iodata()
  def list_policies_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListPoliciesResponse", [{"xmlns", @namespace}], [
        element(
          "ListPoliciesResult",
          [],
          [
            element(
              "Policies",
              [],
              Enum.map(Map.get(result, :policies, []), &policy_member/1)
            ),
            element("IsTruncated", [], characters(to_string(is_truncated)))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec create_policy_version_response(map(), String.t() | nil) :: iodata()
  def create_policy_version_response(version, request_id) when is_map(version) do
    root =
      element("CreatePolicyVersionResponse", [{"xmlns", @namespace}], [
        element("CreatePolicyVersionResult", [], [
          element("PolicyVersion", [], policy_version_children(version, false))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_policy_version_response(map(), String.t() | nil) :: iodata()
  def get_policy_version_response(version, request_id) when is_map(version) do
    root =
      element("GetPolicyVersionResponse", [{"xmlns", @namespace}], [
        element("GetPolicyVersionResult", [], [
          element("PolicyVersion", [], policy_version_children(version, true))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_policy_versions_response(map(), String.t() | nil) :: iodata()
  def list_policy_versions_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListPolicyVersionsResponse", [{"xmlns", @namespace}], [
        element(
          "ListPolicyVersionsResult",
          [],
          [
            element(
              "Versions",
              [],
              Enum.map(Map.get(result, :versions, []), fn version ->
                element("member", [], policy_version_children(version, false))
              end)
            ),
            element("IsTruncated", [], characters(to_string(is_truncated)))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_policy_tags_response(map(), String.t() | nil) :: iodata()
  def list_policy_tags_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListPolicyTagsResponse", [{"xmlns", @namespace}], [
        element(
          "ListPolicyTagsResult",
          [],
          [
            element("IsTruncated", [], characters(to_string(is_truncated))),
            element("Tags", [], tag_members(Map.get(result, :tags, %{})))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_entities_for_policy_response(map(), String.t() | nil) :: iodata()
  def list_entities_for_policy_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListEntitiesForPolicyResponse", [{"xmlns", @namespace}], [
        element(
          "ListEntitiesForPolicyResult",
          [],
          [
            element("IsTruncated", [], characters(to_string(is_truncated))),
            element(
              "PolicyGroups",
              [],
              Enum.map(Map.get(result, :groups, []), &policy_group_member/1)
            ),
            element(
              "PolicyUsers",
              [],
              Enum.map(Map.get(result, :users, []), &policy_user_member/1)
            ),
            element(
              "PolicyRoles",
              [],
              Enum.map(Map.get(result, :roles, []), &policy_role_member/1)
            )
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_user_tags_response(map(), String.t() | nil) :: iodata()
  def list_user_tags_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListUserTagsResponse", [{"xmlns", @namespace}], [
        element(
          "ListUserTagsResult",
          [],
          [
            element("IsTruncated", [], characters(to_string(is_truncated))),
            element("Tags", [], tag_members(Map.get(result, :tags, %{})))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_role_tags_response(map(), String.t() | nil) :: iodata()
  def list_role_tags_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListRoleTagsResponse", [{"xmlns", @namespace}], [
        element(
          "ListRoleTagsResult",
          [],
          [
            element("IsTruncated", [], characters(to_string(is_truncated))),
            element("Tags", [], tag_members(Map.get(result, :tags, %{})))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_instance_profile_tags_response(map(), String.t() | nil) :: iodata()
  def list_instance_profile_tags_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListInstanceProfileTagsResponse", [{"xmlns", @namespace}], [
        element(
          "ListInstanceProfileTagsResult",
          [],
          [
            element("IsTruncated", [], characters(to_string(is_truncated))),
            element("Tags", [], tag_members(Map.get(result, :tags, %{})))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_server_certificate_tags_response(map(), String.t() | nil) :: iodata()
  def list_server_certificate_tags_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListServerCertificateTagsResponse", [{"xmlns", @namespace}], [
        element(
          "ListServerCertificateTagsResult",
          [],
          [
            element("IsTruncated", [], characters(to_string(is_truncated))),
            element("Tags", [], tag_members(Map.get(result, :tags, %{})))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec create_virtual_mfa_device_response(map(), String.t() | nil) :: iodata()
  def create_virtual_mfa_device_response(enrolled, request_id) when is_map(enrolled) do
    device = Map.fetch!(enrolled, :device)
    secret = Map.fetch!(enrolled, :secret_base32)

    root =
      element("CreateVirtualMFADeviceResponse", [{"xmlns", @namespace}], [
        element("CreateVirtualMFADeviceResult", [], [
          element("VirtualMFADevice", [], [
            element("SerialNumber", [], characters(device.serial)),
            element("Base32StringSeed", [], characters(secret)),
            element("QRCodePNG", [], characters(qr_code_png_hex(enrolled)))
          ])
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_mfa_devices_response([map()], String.t() | nil) :: iodata()
  def list_mfa_devices_response(devices, request_id) when is_list(devices) do
    root =
      element("ListMFADevicesResponse", [{"xmlns", @namespace}], [
        element("ListMFADevicesResult", [], [
          element("IsTruncated", [], characters("false")),
          element("MFADevices", [], Enum.map(devices, &mfa_device_member/1))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec create_open_id_connect_provider_response(map(), String.t() | nil) :: iodata()
  def create_open_id_connect_provider_response(provider, request_id) when is_map(provider) do
    root =
      element("CreateOpenIDConnectProviderResponse", [{"xmlns", @namespace}], [
        element("CreateOpenIDConnectProviderResult", [], [
          element("OpenIDConnectProviderArn", [], characters(provider.provider_arn)),
          element("Tags", [], tag_members(provider.tags || %{}))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_open_id_connect_provider_response(map(), String.t() | nil) :: iodata()
  def get_open_id_connect_provider_response(provider, request_id) when is_map(provider) do
    root =
      element("GetOpenIDConnectProviderResponse", [{"xmlns", @namespace}], [
        element(
          "GetOpenIDConnectProviderResult",
          [],
          [
            element("Url", [], characters(provider.issuer_url)),
            element("ClientIDList", [], Enum.map(provider.client_ids || [], &member/1)),
            element("ThumbprintList", [], Enum.map(provider.thumbprints || [], &member/1)),
            element("Tags", [], tag_members(provider.tags || %{}))
          ] ++ create_date(provider)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_open_id_connect_provider_tags_response(map(), String.t() | nil) :: iodata()
  def list_open_id_connect_provider_tags_response(result, request_id) when is_map(result) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("ListOpenIDConnectProviderTagsResponse", [{"xmlns", @namespace}], [
        element(
          "ListOpenIDConnectProviderTagsResult",
          [],
          [
            element("IsTruncated", [], characters(to_string(is_truncated))),
            element("Tags", [], tag_members(Map.get(result, :tags, %{})))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec list_open_id_connect_providers_response([map()], String.t() | nil) :: iodata()
  def list_open_id_connect_providers_response(providers, request_id) when is_list(providers) do
    root =
      element("ListOpenIDConnectProvidersResponse", [{"xmlns", @namespace}], [
        element("ListOpenIDConnectProvidersResult", [], [
          element(
            "OpenIDConnectProviderList",
            [],
            Enum.map(providers, &open_id_connect_provider_member/1)
          )
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec empty_response(String.t(), String.t() | nil) :: iodata()
  def empty_response(action, request_id) when is_binary(action) do
    root =
      element("#{action}Response", [{"xmlns", @namespace}], [
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec error_response(QueryError.t()) :: {pos_integer(), iodata()}
  def error_response(%QueryError{} = error) do
    root =
      element("ErrorResponse", [{"xmlns", @namespace}], [
        element("Error", [], [
          element("Type", [], characters(error.type)),
          element("Code", [], characters(error.code)),
          element("Message", [], characters(error.message))
        ]),
        element("RequestId", [], characters(to_string(error.request_id || "")))
      ])

    {error.http_status, XML.encode(root)}
  end

  defp mfa_device_member(device) do
    children =
      [
        element("UserName", [], characters(user_name(device.principal_arn))),
        element("SerialNumber", [], characters(device.serial))
      ] ++ enable_date(device)

    element("member", [], children)
  end

  defp enable_date(%{confirmed_at: %DateTime{} = confirmed_at}) do
    [element("EnableDate", [], characters(XML.iso8601(confirmed_at)))]
  end

  defp enable_date(_device), do: []

  defp create_date(%{inserted_at: %DateTime{} = inserted_at}) do
    [element("CreateDate", [], characters(XML.iso8601(inserted_at)))]
  end

  defp create_date(_provider), do: []

  defp update_date(%{updated_at: %DateTime{} = updated_at}) do
    [element("UpdateDate", [], characters(XML.iso8601(updated_at)))]
  end

  defp update_date(_policy), do: []

  defp marker(%{is_truncated: true, marker: marker}) when is_binary(marker) and marker != "" do
    [element("Marker", [], characters(marker))]
  end

  defp marker(_result), do: []

  defp member(value), do: element("member", [], characters(to_string(value)))

  defp summary_map_entries(summary) do
    summary
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} ->
      element("entry", [], [
        element("key", [], characters(to_string(key))),
        element("value", [], characters(to_string(value)))
      ])
    end)
  end

  defp password_policy_children(policy) do
    [
      element(
        "AllowUsersToChangePassword",
        [],
        characters(boolean_text(Map.get(policy, :allow_users_to_change_password, false)))
      ),
      element(
        "ExpirePasswords",
        [],
        characters(boolean_text(Map.get(policy, :expire_passwords, false)))
      ),
      element("HardExpiry", [], characters(boolean_text(Map.get(policy, :hard_expiry, false)))),
      element(
        "MinimumPasswordLength",
        [],
        characters(to_string(Map.get(policy, :minimum_password_length, 6)))
      ),
      element(
        "RequireLowercaseCharacters",
        [],
        characters(boolean_text(Map.get(policy, :require_lowercase_characters, false)))
      ),
      element(
        "RequireNumbers",
        [],
        characters(boolean_text(Map.get(policy, :require_numbers, false)))
      ),
      element(
        "RequireSymbols",
        [],
        characters(boolean_text(Map.get(policy, :require_symbols, false)))
      ),
      element(
        "RequireUppercaseCharacters",
        [],
        characters(boolean_text(Map.get(policy, :require_uppercase_characters, false)))
      )
    ] ++
      optional_password_policy_integer("MaxPasswordAge", Map.get(policy, :max_password_age)) ++
      optional_password_policy_integer(
        "PasswordReusePrevention",
        Map.get(policy, :password_reuse_prevention)
      )
  end

  defp boolean_text(true), do: "true"
  defp boolean_text(false), do: "false"

  defp optional_password_policy_integer(_name, nil), do: []

  defp optional_password_policy_integer(name, value) when is_integer(value) do
    [element(name, [], characters(to_string(value)))]
  end

  defp policy_names_response(action, result, request_id) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("#{action}Response", [{"xmlns", @namespace}], [
        element(
          "#{action}Result",
          [],
          [
            element("PolicyNames", [], Enum.map(Map.get(result, :policy_names, []), &member/1)),
            element("IsTruncated", [], characters(to_string(is_truncated)))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  defp attached_policies_response(action, result, request_id) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("#{action}Response", [{"xmlns", @namespace}], [
        element(
          "#{action}Result",
          [],
          [
            element(
              "AttachedPolicies",
              [],
              Enum.map(Map.get(result, :policies, []), &attached_policy_member/1)
            ),
            element("IsTruncated", [], characters(to_string(is_truncated)))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  defp instance_profiles_response(action, result, request_id) do
    is_truncated = Map.get(result, :is_truncated, false)

    root =
      element("#{action}Response", [{"xmlns", @namespace}], [
        element(
          "#{action}Result",
          [],
          [
            element(
              "InstanceProfiles",
              [],
              Enum.map(Map.get(result, :instance_profiles, []), &instance_profile_member/1)
            ),
            element("IsTruncated", [], characters(to_string(is_truncated)))
          ] ++ marker(result)
        ),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  defp attached_policy_member(policy) do
    element("member", [], [
      element("PolicyName", [], characters(policy.policy_name)),
      element("PolicyArn", [], characters(policy.policy_arn))
    ])
  end

  defp policy_group_member(group) do
    element("member", [], [
      element("GroupName", [], characters(group.group_name)),
      element("GroupId", [], characters(group_id(group)))
    ])
  end

  defp policy_user_member(user) do
    element("member", [], [
      element("UserName", [], characters(user.user_name)),
      element("UserId", [], characters(user_id(user)))
    ])
  end

  defp policy_role_member(role) do
    element("member", [], [
      element("RoleName", [], characters(role.role_name)),
      element("RoleId", [], characters(role_id(role)))
    ])
  end

  defp policy_member(policy) do
    element("member", [], policy_detail_children(policy, include_tags: false))
  end

  defp policy_detail_children(policy, opts) do
    include_tags = Keyword.get(opts, :include_tags, false)

    children =
      [
        element("Path", [], characters(policy.path)),
        element("PolicyName", [], characters(policy.policy_name)),
        element("PolicyId", [], characters(policy_id(policy))),
        element("Arn", [], characters(policy.policy_arn)),
        element("DefaultVersionId", [], characters(Map.get(policy, :default_version_id, "v1"))),
        element(
          "AttachmentCount",
          [],
          characters(to_string(Map.get(policy, :attachment_count, 0)))
        ),
        element(
          "PermissionsBoundaryUsageCount",
          [],
          characters(to_string(Map.get(policy, :permissions_boundary_usage_count, 0)))
        ),
        element("IsAttachable", [], characters(to_string(Map.get(policy, :is_attachable, true))))
      ] ++ description(policy) ++ create_date(policy) ++ update_date(policy)

    if include_tags do
      children ++ [element("Tags", [], tag_members(policy.tags || %{}))]
    else
      children
    end
  end

  defp policy_version_children(version, include_document) do
    document =
      if include_document do
        [element("Document", [], characters(encoded_policy_document(version)))]
      else
        []
      end

    document ++
      [
        element("VersionId", [], characters(version.version_id)),
        element("IsDefaultVersion", [], characters(to_string(version.is_default_version)))
      ] ++ create_date(version)
  end

  defp policy_id(%{policy_arn: policy_arn}) do
    digest =
      :crypto.hash(:sha256, policy_arn)
      |> Base.encode32(case: :upper, padding: false)
      |> binary_part(0, 16)

    "ANPA" <> digest
  end

  defp description(%{description: description})
       when is_binary(description) and description != "" do
    [element("Description", [], characters(description))]
  end

  defp description(_policy), do: []

  defp encoded_policy_document(%{document: document}) when is_map(document) do
    document
    |> Jason.encode!()
    |> URI.encode(&URI.char_unreserved?/1)
  end

  defp encoded_trust_policy_document(%{trust_policy: document}) when is_map(document) do
    document
    |> Jason.encode!()
    |> URI.encode(&URI.char_unreserved?/1)
  end

  defp user_member(user) do
    element("member", [], user_member_children(user))
  end

  defp user_member_children(user) do
    [
      element("Path", [], characters("/")),
      element("UserName", [], characters(user.user_name)),
      element("UserId", [], characters(user_id(user))),
      element("Arn", [], characters(user.user_arn))
    ] ++
      create_date(user) ++
      permissions_boundary(user)
  end

  defp user_detail_children(user) do
    user_member_children(user) ++ [element("Tags", [], tag_members(user.tags || %{}))]
  end

  defp access_key_member(access_key) do
    element("member", [], access_key_children(access_key, include_secret: false))
  end

  defp access_key_children(access_key, opts) do
    children =
      [
        element("UserName", [], characters(access_key.user_name)),
        element("AccessKeyId", [], characters(access_key.access_key_id)),
        element("Status", [], characters(access_key_status(access_key.status)))
      ] ++ create_date(access_key)

    if Keyword.get(opts, :include_secret, false) do
      children ++ [element("SecretAccessKey", [], characters(access_key.secret_key))]
    else
      children
    end
  end

  defp access_key_status("active"), do: "Active"
  defp access_key_status("inactive"), do: "Inactive"
  defp access_key_status("expired"), do: "Expired"
  defp access_key_status(status), do: to_string(status)

  defp access_key_last_used_children(last_used) do
    last_used_date(last_used) ++
      [
        element("ServiceName", [], characters(last_used.service_name || "N/A")),
        element("Region", [], characters(last_used.region || "N/A"))
      ]
  end

  defp last_used_date(%{last_used_at: %DateTime{} = last_used_at}) do
    [element("LastUsedDate", [], characters(XML.iso8601(last_used_at)))]
  end

  defp last_used_date(_last_used), do: []

  defp list_access_keys_user_name(%{user_name: user_name})
       when is_binary(user_name) and user_name != "" do
    [element("UserName", [], characters(user_name))]
  end

  defp list_access_keys_user_name(_result), do: []

  defp signing_certificate_member(certificate) do
    element("member", [], signing_certificate_children(certificate))
  end

  defp signing_certificate_children(certificate) do
    [
      element("UserName", [], characters(certificate.user_name)),
      element("CertificateId", [], characters(certificate.certificate_id)),
      element("CertificateBody", [], characters(certificate.certificate_body)),
      element("Status", [], characters(certificate.status))
    ] ++ upload_date(certificate)
  end

  defp upload_date(%{inserted_at: %DateTime{} = inserted_at}) do
    [element("UploadDate", [], characters(XML.iso8601(inserted_at)))]
  end

  defp upload_date(_certificate), do: []

  defp list_signing_certificates_user_name(%{user_name: user_name})
       when is_binary(user_name) and user_name != "" do
    [element("UserName", [], characters(user_name))]
  end

  defp list_signing_certificates_user_name(_result), do: []

  defp ssh_public_key_metadata_member(ssh_public_key) do
    element("member", [], ssh_public_key_metadata_children(ssh_public_key))
  end

  defp ssh_public_key_metadata_children(ssh_public_key) do
    [
      element("UserName", [], characters(ssh_public_key.user_name)),
      element("SSHPublicKeyId", [], characters(ssh_public_key.ssh_public_key_id)),
      element("Status", [], characters(ssh_public_key.status))
    ] ++ upload_date(ssh_public_key)
  end

  defp ssh_public_key_children(ssh_public_key, encoding) do
    ssh_public_key_metadata_children(ssh_public_key) ++
      [
        element(
          "SSHPublicKeyBody",
          [],
          characters(ssh_public_key_body_for_encoding(ssh_public_key, encoding))
        ),
        element("Fingerprint", [], characters(ssh_public_key.fingerprint))
      ]
  end

  defp ssh_public_key_body_for_encoding(ssh_public_key, "PEM"),
    do: ssh_public_key.ssh_public_key_body_pem

  defp ssh_public_key_body_for_encoding(ssh_public_key, _encoding),
    do: ssh_public_key.ssh_public_key_body_ssh

  defp group_member(group) do
    element("member", [], group_member_children(group))
  end

  defp group_member_children(group) do
    [
      element("Path", [], characters("/")),
      element("GroupName", [], characters(group.group_name)),
      element("GroupId", [], characters(group_id(group))),
      element("Arn", [], characters(group.group_arn))
    ] ++ create_date(group)
  end

  defp role_member(role) do
    element("member", [], role_member_children(role))
  end

  defp role_member_children(role) do
    [
      element("Path", [], characters("/")),
      element("RoleName", [], characters(role.role_name)),
      element("RoleId", [], characters(role_id(role))),
      element("Arn", [], characters(role.role_arn))
    ] ++
      description(role) ++
      create_date(role) ++
      [
        element(
          "AssumeRolePolicyDocument",
          [],
          characters(encoded_trust_policy_document(role))
        ),
        element(
          "MaxSessionDuration",
          [],
          characters(to_string(Map.get(role, :max_session_duration_seconds, 3600)))
        )
      ] ++
      permissions_boundary(role)
  end

  defp role_detail_children(role) do
    role_member_children(role) ++ [element("Tags", [], tag_members(role.tags || %{}))]
  end

  defp instance_profile_member(instance_profile) do
    element("member", [], instance_profile_member_children(instance_profile))
  end

  defp instance_profile_member_children(instance_profile) do
    [
      element("Path", [], characters(Map.get(instance_profile, :path, "/"))),
      element("InstanceProfileName", [], characters(instance_profile.instance_profile_name)),
      element("InstanceProfileId", [], characters(instance_profile_id(instance_profile))),
      element("Arn", [], characters(instance_profile.instance_profile_arn))
    ] ++
      create_date(instance_profile) ++
      [
        element(
          "Roles",
          [],
          Enum.map(Map.get(instance_profile, :roles, []), &role_member/1)
        )
      ]
  end

  defp instance_profile_detail_children(instance_profile) do
    instance_profile_member_children(instance_profile) ++
      [element("Tags", [], tag_members(instance_profile.tags || %{}))]
  end

  defp server_certificate_metadata_member(server_certificate) do
    element("member", [], server_certificate_metadata_children(server_certificate))
  end

  defp server_certificate_metadata_children(server_certificate) do
    [
      element("Path", [], characters(Map.get(server_certificate, :path, "/"))),
      element(
        "ServerCertificateName",
        [],
        characters(server_certificate.server_certificate_name)
      ),
      element(
        "ServerCertificateId",
        [],
        characters(server_certificate_id(server_certificate))
      ),
      element("Arn", [], characters(server_certificate.server_certificate_arn))
    ] ++ create_date(server_certificate) ++ expiration(server_certificate)
  end

  defp server_certificate_detail_children(server_certificate) do
    [
      element(
        "ServerCertificateMetadata",
        [],
        server_certificate_metadata_children(server_certificate)
      ),
      element("CertificateBody", [], characters(server_certificate.certificate_body))
    ] ++ certificate_chain(server_certificate)
  end

  defp permissions_boundary(%{permissions_boundary_policy_arn: policy_arn})
       when is_binary(policy_arn) and policy_arn != "" do
    [
      element("PermissionsBoundary", [], [
        element("PermissionsBoundaryType", [], characters("PermissionsBoundaryPolicy")),
        element("PermissionsBoundaryArn", [], characters(policy_arn))
      ])
    ]
  end

  defp permissions_boundary(_entity), do: []

  defp user_id(%{id: id}) when is_binary(id) do
    digest =
      :crypto.hash(:sha256, id)
      |> Base.encode32(case: :upper, padding: false)
      |> binary_part(0, 16)

    "AIDA" <> digest
  end

  defp user_id(user), do: user_id(%{id: to_string(user.user_arn)})

  defp group_id(%{id: id}) when is_binary(id) do
    digest =
      :crypto.hash(:sha256, id)
      |> Base.encode32(case: :upper, padding: false)
      |> binary_part(0, 16)

    "AGPA" <> digest
  end

  defp group_id(group), do: group_id(%{id: to_string(group.group_arn)})

  defp role_id(%{id: id}) when is_binary(id) do
    digest =
      :crypto.hash(:sha256, id)
      |> Base.encode32(case: :upper, padding: false)
      |> binary_part(0, 16)

    "AROA" <> digest
  end

  defp role_id(role), do: role_id(%{id: to_string(role.role_arn)})

  defp instance_profile_id(%{id: id}) when is_binary(id) do
    digest =
      :crypto.hash(:sha256, id)
      |> Base.encode32(case: :upper, padding: false)
      |> binary_part(0, 16)

    "AIPA" <> digest
  end

  defp instance_profile_id(instance_profile),
    do: instance_profile_id(%{id: to_string(instance_profile.instance_profile_arn)})

  defp server_certificate_id(%{id: id}) when is_binary(id) do
    digest =
      :crypto.hash(:sha256, id)
      |> Base.encode32(case: :upper, padding: false)
      |> binary_part(0, 16)

    "ASCA" <> digest
  end

  defp server_certificate_id(server_certificate),
    do: server_certificate_id(%{id: to_string(server_certificate.server_certificate_arn)})

  defp expiration(%{expiration: %DateTime{} = expiration}) do
    [element("Expiration", [], characters(DateTime.to_iso8601(expiration)))]
  end

  defp expiration(_server_certificate), do: []

  defp certificate_chain(%{certificate_chain: chain}) when is_binary(chain) and chain != "" do
    [element("CertificateChain", [], characters(chain))]
  end

  defp certificate_chain(_server_certificate), do: []

  defp tag_members(tags) when is_map(tags) do
    tags
    |> Tags.map_to_list()
    |> Enum.map(&tag_member/1)
  end

  defp tag_member({key, value}) do
    element("member", [], [
      element("Key", [], characters(to_string(key))),
      element("Value", [], characters(to_string(value)))
    ])
  end

  defp open_id_connect_provider_member(provider) do
    element("member", [], [
      element("Arn", [], characters(provider.provider_arn))
    ])
  end

  defp response_metadata(nil), do: element("ResponseMetadata", [], [])
  defp response_metadata(""), do: element("ResponseMetadata", [], [])

  defp response_metadata(request_id) do
    element("ResponseMetadata", [], [
      element("RequestId", [], characters(request_id))
    ])
  end

  defp qr_code_png_hex(%{otpauth_uri: uri}) do
    uri
    |> EQRCode.encode()
    |> EQRCode.png(width: 256)
    |> Base.encode16(case: :upper)
  end

  defp user_name("arn:aws:iam:::user/" <> user_name), do: user_name
  defp user_name("arn:aws:iam:::root"), do: "root"
  defp user_name(principal_arn), do: to_string(principal_arn)
end
