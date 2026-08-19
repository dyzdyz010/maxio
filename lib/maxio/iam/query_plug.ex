defmodule Maxio.IAM.QueryPlug do
  @moduledoc """
  Minimal AWS IAM Query API plug for local IAM management actions.

  The plug runs after SigV4 authentication and before STS/S3 dispatch. It is
  intentionally narrower than `Maxio.STS.QueryPlug`: POST forms are claimed only
  when the credential scope service is `iam`, so STS POST forms continue to be
  handled by the STS plug.
  """

  import Plug.Conn

  alias Ecto.Changeset
  alias Maxio.Auth.SigV4.Signer
  alias Maxio.IAM
  alias Maxio.IAM.{QueryError, QueryView}
  alias Maxio.S3.Log
  alias Maxio.Tags

  @behaviour Plug

  @version "2010-05-08"
  @form_limit 3_145_728
  @supported_actions ~w(
    AddClientIDToOpenIDConnectProvider
    AddRoleToInstanceProfile
    AddUserToGroup
    CreateAccountAlias
    AttachGroupPolicy
    AttachRolePolicy
    AttachUserPolicy
    CreateAccessKey
    CreateGroup
    CreateInstanceProfile
    CreateRole
    CreateUser
    CreateOpenIDConnectProvider
    CreatePolicy
    CreatePolicyVersion
    CreateVirtualMFADevice
    DeletePolicy
    DeletePolicyVersion
    DeleteRole
    DeleteRolePermissionsBoundary
    DeleteServerCertificate
    DeleteSigningCertificate
    DeleteSSHPublicKey
    DetachGroupPolicy
    DetachRolePolicy
    DetachUserPolicy
    DeleteAccountAlias
    DeleteGroup
    DeleteGroupPolicy
    DeleteInstanceProfile
    DeleteRolePolicy
    DeleteUser
    DeleteUserPermissionsBoundary
    DeleteUserPolicy
    DeleteOpenIDConnectProvider
    DeleteAccessKey
    DeleteAccountPasswordPolicy
    EnableMFADevice
    GetAccessKeyLastUsed
    GetAccountSummary
    GetAccountPasswordPolicy
    GetGroup
    GetGroupPolicy
    GetInstanceProfile
    GetPolicy
    GetPolicyVersion
    GetRole
    GetRolePolicy
    GetServerCertificate
    GetSSHPublicKey
    GetUser
    GetUserPolicy
    GetOpenIDConnectProvider
    ListGroups
    ListGroupsForUser
    ListAccountAliases
    ListAccessKeys
    ListAttachedGroupPolicies
    ListAttachedRolePolicies
    ListAttachedUserPolicies
    ListEntitiesForPolicy
    ListGroupPolicies
    ListInstanceProfiles
    ListInstanceProfilesForRole
    ListInstanceProfileTags
    ListOpenIDConnectProviderTags
    ListOpenIDConnectProviders
    ListMFADevices
    ListPolicies
    ListPolicyTags
    ListPolicyVersions
    ListRoleTags
    ListRolePolicies
    ListRoles
    ListServerCertificates
    ListServerCertificateTags
    ListSigningCertificates
    ListSSHPublicKeys
    ListUserPolicies
    ListUserTags
    ListUsers
    DeactivateMFADevice
    DeleteVirtualMFADevice
    PutGroupPolicy
    PutRolePermissionsBoundary
    PutRolePolicy
    PutUserPermissionsBoundary
    PutUserPolicy
    RemoveClientIDFromOpenIDConnectProvider
    RemoveRoleFromInstanceProfile
    RemoveUserFromGroup
    ResyncMFADevice
    SetDefaultPolicyVersion
    TagServerCertificate
    TagRole
    TagUser
    TagOpenIDConnectProvider
    TagInstanceProfile
    TagPolicy
    UpdateAccessKey
    UpdateAccountPasswordPolicy
    UpdateAssumeRolePolicy
    UpdateGroup
    UpdateRole
    UpdateServerCertificate
    UpdateSigningCertificate
    UpdateSSHPublicKey
    UpdateUser
    UploadSigningCertificate
    UploadServerCertificate
    UploadSSHPublicKey
    UntagUser
    UntagRole
    UntagInstanceProfile
    UntagPolicy
    UntagServerCertificate
    UpdateOpenIDConnectProviderThumbprint
    UntagOpenIDConnectProvider
  )
  @post_only_actions ~w(
    UploadServerCertificate
  )
  @virtual_mfa_device_name_pattern ~r/\A[A-Za-z0-9+=,.@_-]{1,128}\z/
  @account_alias_pattern ~r/\A[a-z0-9](?:[a-z0-9]|-(?!-)){1,61}[a-z0-9]\z/
  @access_key_id_pattern ~r/\A[A-Za-z0-9_+=,.@-]{1,128}\z/
  @strict_access_key_id_pattern ~r/\A[A-Za-z0-9_]{16,128}\z/
  @signing_certificate_id_pattern ~r/\ATA[A-Za-z0-9_]{22,126}\z/
  @ssh_public_key_id_pattern ~r/\AAPKA[A-Z2-7]{16}\z/
  @user_name_pattern ~r/\A[A-Za-z0-9+=,.@_-]{1,64}\z/
  @group_name_pattern ~r/\A[A-Za-z0-9+=,.@_-]{1,128}\z/
  @role_name_pattern ~r/\A[A-Za-z0-9+=,.@_-]{1,64}\z/
  @instance_profile_name_pattern ~r/\A[A-Za-z0-9+=,.@_-]{1,128}\z/
  @server_certificate_name_pattern ~r/\A[A-Za-z0-9+=,.@_-]{1,128}\z/
  @policy_name_pattern ~r/\A[A-Za-z0-9_+=,.@-]{1,128}\z/
  @managed_policy_path_segment_pattern ~r/\A[A-Za-z0-9.,+@=_-]+\z/
  @policy_version_id_pattern ~r/\Av[1-9]\d*(?:\.[A-Za-z0-9-]*)?\z/
  @mfa_serial_pattern ~r/\Aarn:aws:iam:::[A-Za-z0-9+=,.@_\/-]{1,512}\z/
  @auth_code_pattern ~r/\A\d{6}\z/
  @path_pattern ~r{\A(?:/|/[!-~]+/)\z}
  @path_prefix_pattern ~r|\A/[!-~]*\z|
  @trust_policy_document_max_chars 131_072
  @role_description_max_chars 1000
  @sigv4_query_param_pattern ~r/\AX-Amz-(?:Algorithm|Credential|Date|Expires|SignedHeaders|Signature|Security-Token|Content-Sha256)\z/
  @oidc_provider_arn_pattern ~r|\Aarn:aws:iam:::oidc-provider/.{1,480}\z|
  @client_id_member_pattern ~r/\AClientIDList\.member\.[1-9]\d*\z/
  @thumbprint_member_pattern ~r/\AThumbprintList\.member\.[1-9]\d*\z/
  @tag_member_pattern ~r/\ATags\.member\.[1-9]\d*\.(?:Key|Value)\z/
  @tag_key_member_pattern ~r/\ATagKeys\.member\.[1-9]\d*\z/
  @thumbprint_pattern ~r/\A[0-9A-Fa-f]{40}\z/

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    if iam_query?(conn) do
      handle_iam_query(conn)
    else
      conn
    end
  end

  @doc "Returns true when this request is addressed to the IAM Query API."
  @spec iam_query?(Plug.Conn.t()) :: boolean()
  def iam_query?(conn) do
    conn.assigns[:s3_level] == :service and
      (signed_iam_scope?(conn) or known_iam_action?(conn.query_params || %{}) or
         Map.get(conn.query_params || %{}, "Version") == @version)
  end

  defp handle_iam_query(conn) do
    try do
      case conn.method do
        "GET" ->
          case verify_get_query_params(conn) do
            :ok -> dispatch_action(conn)
            {:error, %QueryError{} = error} -> reject(conn, error)
          end

        "POST" ->
          case load_post_form(conn) do
            {:ok, conn} -> dispatch_action(conn)
            {:error, %QueryError{} = error} -> reject(conn, error)
          end

        _other ->
          reject(conn, QueryError.new(:invalid_action))
      end
    rescue
      err in QueryError ->
        reject(conn, err)

      other ->
        Log.error("unhandled exception in iam query api",
          action: action(conn),
          reason: Exception.message(other)
        )

        reject(conn, QueryError.new(:service_failure))
    end
  end

  defp dispatch_action(conn) do
    case action(conn) do
      "AddClientIDToOpenIDConnectProvider" ->
        add_client_id_to_open_id_connect_provider(conn)

      "AddRoleToInstanceProfile" ->
        add_role_to_instance_profile(conn)

      "AddUserToGroup" ->
        add_user_to_group(conn)

      "AttachGroupPolicy" ->
        attach_group_policy(conn)

      "AttachRolePolicy" ->
        attach_role_policy(conn)

      "AttachUserPolicy" ->
        attach_user_policy(conn)

      "CreateAccessKey" ->
        create_access_key(conn)

      "CreateAccountAlias" ->
        create_account_alias(conn)

      "CreateGroup" ->
        create_group(conn)

      "CreateInstanceProfile" ->
        create_instance_profile(conn)

      "CreateRole" ->
        create_role(conn)

      "CreateUser" ->
        create_user(conn)

      "CreateOpenIDConnectProvider" ->
        create_open_id_connect_provider(conn)

      "CreatePolicy" ->
        create_policy(conn)

      "CreatePolicyVersion" ->
        create_policy_version(conn)

      "CreateVirtualMFADevice" ->
        create_virtual_mfa_device(conn)

      "DeletePolicy" ->
        delete_policy(conn)

      "DeletePolicyVersion" ->
        delete_policy_version(conn)

      "DeleteRole" ->
        delete_role(conn)

      "DeleteRolePermissionsBoundary" ->
        delete_role_permissions_boundary(conn)

      "DeleteServerCertificate" ->
        delete_server_certificate(conn)

      "DeleteSigningCertificate" ->
        delete_signing_certificate(conn)

      "DeleteSSHPublicKey" ->
        delete_ssh_public_key(conn)

      "DetachGroupPolicy" ->
        detach_group_policy(conn)

      "DetachRolePolicy" ->
        detach_role_policy(conn)

      "DetachUserPolicy" ->
        detach_user_policy(conn)

      "DeleteAccountAlias" ->
        delete_account_alias(conn)

      "DeleteUser" ->
        delete_user(conn)

      "DeleteUserPermissionsBoundary" ->
        delete_user_permissions_boundary(conn)

      "DeleteUserPolicy" ->
        delete_user_policy(conn)

      "DeleteGroup" ->
        delete_group(conn)

      "DeleteGroupPolicy" ->
        delete_group_policy(conn)

      "DeleteInstanceProfile" ->
        delete_instance_profile(conn)

      "DeleteRolePolicy" ->
        delete_role_policy(conn)

      "DeleteOpenIDConnectProvider" ->
        delete_open_id_connect_provider(conn)

      "DeleteAccessKey" ->
        delete_access_key(conn)

      "DeleteAccountPasswordPolicy" ->
        delete_account_password_policy(conn)

      "EnableMFADevice" ->
        enable_mfa_device(conn)

      "GetAccessKeyLastUsed" ->
        get_access_key_last_used(conn)

      "GetAccountSummary" ->
        get_account_summary(conn)

      "GetAccountPasswordPolicy" ->
        get_account_password_policy(conn)

      "GetUser" ->
        get_user(conn)

      "GetUserPolicy" ->
        get_user_policy(conn)

      "GetGroup" ->
        get_group(conn)

      "GetGroupPolicy" ->
        get_group_policy(conn)

      "GetInstanceProfile" ->
        get_instance_profile(conn)

      "GetRole" ->
        get_role(conn)

      "GetRolePolicy" ->
        get_role_policy(conn)

      "GetServerCertificate" ->
        get_server_certificate(conn)

      "GetSSHPublicKey" ->
        get_ssh_public_key(conn)

      "GetPolicy" ->
        get_policy(conn)

      "GetPolicyVersion" ->
        get_policy_version(conn)

      "GetOpenIDConnectProvider" ->
        get_open_id_connect_provider(conn)

      "ListGroups" ->
        list_groups(conn)

      "ListGroupsForUser" ->
        list_groups_for_user(conn)

      "ListAccountAliases" ->
        list_account_aliases(conn)

      "ListAccessKeys" ->
        list_access_keys(conn)

      "ListAttachedGroupPolicies" ->
        list_attached_group_policies(conn)

      "ListAttachedRolePolicies" ->
        list_attached_role_policies(conn)

      "ListAttachedUserPolicies" ->
        list_attached_user_policies(conn)

      "ListEntitiesForPolicy" ->
        list_entities_for_policy(conn)

      "ListGroupPolicies" ->
        list_group_policies(conn)

      "ListInstanceProfiles" ->
        list_instance_profiles(conn)

      "ListInstanceProfilesForRole" ->
        list_instance_profiles_for_role(conn)

      "ListInstanceProfileTags" ->
        list_instance_profile_tags(conn)

      "ListOpenIDConnectProviders" ->
        list_open_id_connect_providers(conn)

      "ListOpenIDConnectProviderTags" ->
        list_open_id_connect_provider_tags(conn)

      "ListMFADevices" ->
        list_mfa_devices(conn)

      "ListPolicies" ->
        list_policies(conn)

      "ListPolicyTags" ->
        list_policy_tags(conn)

      "ListPolicyVersions" ->
        list_policy_versions(conn)

      "ListRoleTags" ->
        list_role_tags(conn)

      "ListRolePolicies" ->
        list_role_policies(conn)

      "ListRoles" ->
        list_roles(conn)

      "ListServerCertificates" ->
        list_server_certificates(conn)

      "ListServerCertificateTags" ->
        list_server_certificate_tags(conn)

      "ListSigningCertificates" ->
        list_signing_certificates(conn)

      "ListSSHPublicKeys" ->
        list_ssh_public_keys(conn)

      "ListUserPolicies" ->
        list_user_policies(conn)

      "ListUserTags" ->
        list_user_tags(conn)

      "ListUsers" ->
        list_users(conn)

      "DeactivateMFADevice" ->
        deactivate_mfa_device(conn)

      "DeleteVirtualMFADevice" ->
        delete_virtual_mfa_device(conn)

      "PutUserPolicy" ->
        put_user_policy(conn)

      "PutGroupPolicy" ->
        put_group_policy(conn)

      "PutRolePermissionsBoundary" ->
        put_role_permissions_boundary(conn)

      "PutRolePolicy" ->
        put_role_policy(conn)

      "PutUserPermissionsBoundary" ->
        put_user_permissions_boundary(conn)

      "RemoveClientIDFromOpenIDConnectProvider" ->
        remove_client_id_from_open_id_connect_provider(conn)

      "RemoveRoleFromInstanceProfile" ->
        remove_role_from_instance_profile(conn)

      "RemoveUserFromGroup" ->
        remove_user_from_group(conn)

      "ResyncMFADevice" ->
        resync_mfa_device(conn)

      "SetDefaultPolicyVersion" ->
        set_default_policy_version(conn)

      "TagServerCertificate" ->
        tag_server_certificate(conn)

      "TagRole" ->
        tag_role(conn)

      "TagUser" ->
        tag_user(conn)

      "TagOpenIDConnectProvider" ->
        tag_open_id_connect_provider(conn)

      "TagInstanceProfile" ->
        tag_instance_profile(conn)

      "TagPolicy" ->
        tag_policy(conn)

      "UpdateAccessKey" ->
        update_access_key(conn)

      "UpdateAccountPasswordPolicy" ->
        update_account_password_policy(conn)

      "UpdateAssumeRolePolicy" ->
        update_assume_role_policy(conn)

      "UpdateGroup" ->
        update_group(conn)

      "UpdateRole" ->
        update_role(conn)

      "UpdateServerCertificate" ->
        update_server_certificate(conn)

      "UpdateSigningCertificate" ->
        update_signing_certificate(conn)

      "UpdateSSHPublicKey" ->
        update_ssh_public_key(conn)

      "UpdateUser" ->
        update_user(conn)

      "UploadSigningCertificate" ->
        upload_signing_certificate(conn)

      "UploadServerCertificate" ->
        upload_server_certificate(conn)

      "UploadSSHPublicKey" ->
        upload_ssh_public_key(conn)

      "UntagUser" ->
        untag_user(conn)

      "UntagRole" ->
        untag_role(conn)

      "UntagInstanceProfile" ->
        untag_instance_profile(conn)

      "UntagPolicy" ->
        untag_policy(conn)

      "UntagServerCertificate" ->
        untag_server_certificate(conn)

      "UpdateOpenIDConnectProviderThumbprint" ->
        update_open_id_connect_provider_thumbprint(conn)

      "UntagOpenIDConnectProvider" ->
        untag_open_id_connect_provider(conn)

      _other ->
        reject(conn, QueryError.new(:invalid_action))
    end
  end

  defp create_account_alias(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version AccountAlias)),
         {:ok, account_alias} <- account_alias(conn),
         {:ok, created_alias} <- IAM.create_account_alias(account_alias) do
      Log.info("iam create-account-alias created",
        action: :create_account_alias,
        principal_arn: conn.assigns.principal[:arn],
        account_alias: created_alias
      )

      empty_success(conn, "CreateAccountAlias")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_account_aliases(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version MaxItems Marker)),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn) do
      page =
        IAM.list_account_aliases()
        |> account_alias_page(max_items, marker_offset)

      Log.info("iam list-account-aliases returned",
        action: :list_account_aliases,
        principal_arn: conn.assigns.principal[:arn],
        alias_count: page.alias_count,
        returned_alias_count: length(page.account_aliases),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_account_aliases_response(page, request_id(conn)))
      |> halt()
    else
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_account_alias(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version AccountAlias)),
         {:ok, account_alias} <- account_alias(conn),
         :ok <- IAM.delete_account_alias(account_alias) do
      Log.info("iam delete-account-alias deleted",
        action: :delete_account_alias,
        principal_arn: conn.assigns.principal[:arn],
        account_alias: account_alias
      )

      empty_success(conn, "DeleteAccountAlias")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_account_password_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version)),
         {:ok, policy} <- IAM.get_account_password_policy() do
      Log.info("iam get-account-password-policy returned",
        action: :get_account_password_policy,
        principal_arn: conn.assigns.principal[:arn],
        expire_passwords: policy.expire_passwords
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.get_account_password_policy_response(policy, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp update_account_password_policy(conn) do
    allowed = ~w(
      Action
      Version
      AllowUsersToChangePassword
      HardExpiry
      MaxPasswordAge
      MinimumPasswordLength
      PasswordReusePrevention
      RequireLowercaseCharacters
      RequireNumbers
      RequireSymbols
      RequireUppercaseCharacters
    )

    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, allowed),
         {:ok, attrs} <- account_password_policy_attrs(conn),
         {:ok, policy} <- IAM.update_account_password_policy(attrs) do
      Log.info("iam update-account-password-policy updated",
        action: :update_account_password_policy,
        principal_arn: conn.assigns.principal[:arn],
        minimum_password_length: policy.minimum_password_length,
        expire_passwords: policy.expire_passwords
      )

      empty_success(conn, "UpdateAccountPasswordPolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_account_password_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version)),
         :ok <- IAM.delete_account_password_policy() do
      Log.info("iam delete-account-password-policy deleted",
        action: :delete_account_password_policy,
        principal_arn: conn.assigns.principal[:arn]
      )

      empty_success(conn, "DeleteAccountPasswordPolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp create_user(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version Path UserName PermissionsBoundary),
             [@tag_member_pattern]
           ),
         {:ok, user_name} <- user_name(conn),
         {:ok, path} <- root_user_path(conn),
         {:ok, permissions_boundary_policy_arn} <- optional_permissions_boundary_policy_arn(conn),
         {:ok, tags} <- optional_indexed_tags(conn, "Tags"),
         {:ok, user} <-
           IAM.create_user(
             user_name: user_name,
             tags: tags,
             permissions_boundary_policy_arn: permissions_boundary_policy_arn
           ) do
      Log.info("iam create-user created",
        action: :create_user,
        principal_arn: conn.assigns.principal[:arn],
        user_arn: user.user_arn,
        path: path,
        permissions_boundary_policy_arn: permissions_boundary_policy_arn,
        tag_count: map_size(user.tags)
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.create_user_response(user, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp create_access_key(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName)),
         {:ok, user_name} <- optional_user_name(conn),
         {:ok, access_key} <- IAM.create_access_key_strict(user_name) do
      Log.info("iam create-access-key created",
        action: :create_access_key,
        principal_arn: conn.assigns.principal[:arn],
        user_name: access_key.user_name,
        access_key_id: access_key.access_key_id,
        target_principal_arn: access_key.principal_arn
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.create_access_key_response(access_key, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_user(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName)),
         {:ok, user_name} <- user_name(conn),
         {:ok, user} <- IAM.get_user(user_name) do
      Log.info("iam get-user returned",
        action: :get_user,
        principal_arn: conn.assigns.principal[:arn],
        user_arn: user.user_arn
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.get_user_response(user, request_id(conn)))
      |> halt()
    else
      :error -> reject(conn, QueryError.new(:no_such_entity))
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp update_user(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName NewUserName NewPath)),
         {:ok, user_name} <- user_name(conn),
         {:ok, new_user_name} <- new_user_name(conn),
         {:ok, new_path} <- root_new_user_path(conn),
         {:ok, user} <- IAM.update_user_name_strict(user_name, new_user_name) do
      Log.info("iam update-user updated",
        action: :update_user,
        principal_arn: conn.assigns.principal[:arn],
        old_user_name: user_name,
        new_user_name: user.user_name,
        user_arn: user.user_arn,
        path: new_path
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.update_user_response(user, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_users(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version PathPrefix MaxItems Marker)),
         {:ok, path_prefix} <- root_user_path_prefix(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn) do
      page =
        IAM.list_users()
        |> user_page(path_prefix, max_items, marker_offset)

      Log.info("iam list-users returned",
        action: :list_users,
        principal_arn: conn.assigns.principal[:arn],
        path_prefix: path_prefix,
        user_count: page.user_count,
        returned_user_count: length(page.users),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_users_response(page, request_id(conn)))
      |> halt()
    else
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_user(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName)),
         {:ok, user_name} <- user_name(conn),
         {:ok, user} <- IAM.delete_user_strict(user_name) do
      Log.info("iam delete-user deleted",
        action: :delete_user,
        principal_arn: conn.assigns.principal[:arn],
        user_arn: user.user_arn
      )

      empty_success(conn, "DeleteUser")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_access_keys(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName MaxItems Marker)),
         {:ok, user_name} <- optional_user_name(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, access_keys} <- IAM.list_access_keys_strict(user_name) do
      page = access_key_page(access_keys, user_name, max_items, marker_offset)

      Log.info("iam list-access-keys returned",
        action: :list_access_keys,
        principal_arn: conn.assigns.principal[:arn],
        user_name: page.user_name,
        access_key_count: page.access_key_count,
        returned_access_key_count: length(page.access_keys),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_access_keys_response(page, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_access_key_last_used(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version AccessKeyId)),
         {:ok, access_key_id} <- strict_access_key_id(conn),
         {:ok, last_used} <- IAM.get_access_key_last_used_strict(access_key_id) do
      Log.info("iam get-access-key-last-used returned",
        action: :get_access_key_last_used,
        principal_arn: conn.assigns.principal[:arn],
        access_key_id: access_key_id,
        last_used_service: last_used.service_name,
        last_used_region: last_used.region
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.get_access_key_last_used_response(last_used, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_account_summary(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version)) do
      summary = IAM.account_summary()

      Log.info("iam get-account-summary returned",
        action: :get_account_summary,
        principal_arn: conn.assigns.principal[:arn],
        summary_key_count: map_size(summary)
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.get_account_summary_response(summary, request_id(conn)))
      |> halt()
    else
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp update_access_key(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName AccessKeyId Status)),
         {:ok, user_name} <- optional_user_name(conn),
         {:ok, access_key_id} <- access_key_id(conn),
         {:ok, status} <- access_key_status(conn),
         {:ok, access_key} <- IAM.update_access_key_strict(access_key_id, status, user_name) do
      Log.info("iam update-access-key updated",
        action: :update_access_key,
        principal_arn: conn.assigns.principal[:arn],
        user_name: access_key.user_name,
        access_key_id: access_key.access_key_id,
        status: access_key.status
      )

      empty_success(conn, "UpdateAccessKey")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_access_key(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName AccessKeyId)),
         {:ok, user_name} <- optional_user_name(conn),
         {:ok, access_key_id} <- access_key_id(conn),
         {:ok, access_key} <- IAM.delete_access_key_strict(access_key_id, user_name) do
      Log.info("iam delete-access-key deleted",
        action: :delete_access_key,
        principal_arn: conn.assigns.principal[:arn],
        user_name: access_key.user_name,
        access_key_id: access_key.access_key_id
      )

      empty_success(conn, "DeleteAccessKey")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp upload_signing_certificate(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName CertificateBody)),
         {:ok, user_name} <- optional_user_name(conn),
         {:ok, certificate_body} <- certificate_body(conn),
         {:ok, certificate} <-
           IAM.upload_signing_certificate(
             user_name: user_name,
             certificate_body: certificate_body
           ) do
      Log.info("iam upload-signing-certificate created",
        action: :upload_signing_certificate,
        principal_arn: conn.assigns.principal[:arn],
        user_name: certificate.user_name,
        certificate_id: certificate.certificate_id,
        target_user_arn: certificate.user_arn,
        principal_type: certificate.principal_type
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(
        200,
        QueryView.upload_signing_certificate_response(certificate, request_id(conn))
      )
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_signing_certificates(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName MaxItems Marker)),
         {:ok, user_name} <- optional_user_name(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, certificates} <- IAM.list_signing_certificates_strict(user_name) do
      page = signing_certificate_page(certificates, user_name, max_items, marker_offset)

      Log.info("iam list-signing-certificates returned",
        action: :list_signing_certificates,
        principal_arn: conn.assigns.principal[:arn],
        user_name: page.user_name,
        signing_certificate_count: page.signing_certificate_count,
        returned_signing_certificate_count: length(page.certificates),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_signing_certificates_response(page, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp update_signing_certificate(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName CertificateId Status)),
         {:ok, user_name} <- optional_user_name(conn),
         {:ok, certificate_id} <- signing_certificate_id(conn),
         {:ok, status} <- signing_certificate_status(conn),
         {:ok, certificate} <-
           IAM.update_signing_certificate_strict(certificate_id, status, user_name) do
      Log.info("iam update-signing-certificate updated",
        action: :update_signing_certificate,
        principal_arn: conn.assigns.principal[:arn],
        user_name: certificate.user_name,
        certificate_id: certificate.certificate_id,
        status: certificate.status
      )

      empty_success(conn, "UpdateSigningCertificate")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_signing_certificate(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName CertificateId)),
         {:ok, user_name} <- optional_user_name(conn),
         {:ok, certificate_id} <- signing_certificate_id(conn),
         {:ok, certificate} <- IAM.delete_signing_certificate_strict(certificate_id, user_name) do
      Log.info("iam delete-signing-certificate deleted",
        action: :delete_signing_certificate,
        principal_arn: conn.assigns.principal[:arn],
        user_name: certificate.user_name,
        certificate_id: certificate.certificate_id
      )

      empty_success(conn, "DeleteSigningCertificate")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp upload_ssh_public_key(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName SSHPublicKeyBody)),
         {:ok, user_name} <- user_name(conn),
         {:ok, ssh_public_key_body} <- ssh_public_key_body(conn),
         {:ok, ssh_public_key} <-
           IAM.upload_ssh_public_key(
             user_name: user_name,
             ssh_public_key_body: ssh_public_key_body
           ) do
      Log.info("iam upload-ssh-public-key created",
        action: :upload_ssh_public_key,
        principal_arn: conn.assigns.principal[:arn],
        user_name: ssh_public_key.user_name,
        ssh_public_key_id: ssh_public_key.ssh_public_key_id
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(
        200,
        QueryView.upload_ssh_public_key_response(ssh_public_key, request_id(conn))
      )
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_ssh_public_keys(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName MaxItems Marker)),
         {:ok, user_name} <- user_name(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, ssh_public_keys} <- IAM.list_ssh_public_keys_strict(user_name) do
      page = ssh_public_key_page(ssh_public_keys, user_name, max_items, marker_offset)

      Log.info("iam list-ssh-public-keys returned",
        action: :list_ssh_public_keys,
        principal_arn: conn.assigns.principal[:arn],
        user_name: page.user_name,
        ssh_public_key_count: page.ssh_public_key_count,
        returned_ssh_public_key_count: length(page.ssh_public_keys),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_ssh_public_keys_response(page, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_ssh_public_key(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version UserName SSHPublicKeyId Encoding)),
         {:ok, user_name} <- user_name(conn),
         {:ok, ssh_public_key_id} <- ssh_public_key_id(conn),
         {:ok, encoding} <- ssh_public_key_encoding(conn),
         {:ok, ssh_public_key} <- IAM.get_ssh_public_key_strict(user_name, ssh_public_key_id) do
      Log.info("iam get-ssh-public-key returned",
        action: :get_ssh_public_key,
        principal_arn: conn.assigns.principal[:arn],
        user_name: ssh_public_key.user_name,
        ssh_public_key_id: ssh_public_key.ssh_public_key_id,
        encoding: encoding
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(
        200,
        QueryView.get_ssh_public_key_response(ssh_public_key, encoding, request_id(conn))
      )
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp update_ssh_public_key(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName SSHPublicKeyId Status)),
         {:ok, user_name} <- user_name(conn),
         {:ok, ssh_public_key_id} <- ssh_public_key_id(conn),
         {:ok, status} <- ssh_public_key_status(conn),
         {:ok, ssh_public_key} <-
           IAM.update_ssh_public_key_strict(user_name, ssh_public_key_id, status) do
      Log.info("iam update-ssh-public-key updated",
        action: :update_ssh_public_key,
        principal_arn: conn.assigns.principal[:arn],
        user_name: ssh_public_key.user_name,
        ssh_public_key_id: ssh_public_key.ssh_public_key_id,
        status: ssh_public_key.status
      )

      empty_success(conn, "UpdateSSHPublicKey")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_ssh_public_key(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName SSHPublicKeyId)),
         {:ok, user_name} <- user_name(conn),
         {:ok, ssh_public_key_id} <- ssh_public_key_id(conn),
         {:ok, ssh_public_key} <- IAM.delete_ssh_public_key_strict(user_name, ssh_public_key_id) do
      Log.info("iam delete-ssh-public-key deleted",
        action: :delete_ssh_public_key,
        principal_arn: conn.assigns.principal[:arn],
        user_name: ssh_public_key.user_name,
        ssh_public_key_id: ssh_public_key.ssh_public_key_id
      )

      empty_success(conn, "DeleteSSHPublicKey")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp put_user_permissions_boundary(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName PermissionsBoundary)),
         {:ok, user_name} <- user_name(conn),
         {:ok, policy_arn} <- permissions_boundary_policy_arn(conn),
         {:ok, user} <- IAM.put_user_permissions_boundary_strict(user_name, policy_arn) do
      Log.info("iam put-user-permissions-boundary updated",
        action: :put_user_permissions_boundary,
        principal_arn: conn.assigns.principal[:arn],
        user_arn: user.user_arn,
        policy_arn: policy_arn
      )

      empty_success(conn, "PutUserPermissionsBoundary")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_user_permissions_boundary(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName)),
         {:ok, user_name} <- user_name(conn),
         {:ok, user} <- IAM.delete_user_permissions_boundary_strict(user_name) do
      Log.info("iam delete-user-permissions-boundary deleted",
        action: :delete_user_permissions_boundary,
        principal_arn: conn.assigns.principal[:arn],
        user_arn: user.user_arn
      )

      empty_success(conn, "DeleteUserPermissionsBoundary")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp put_user_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version UserName PolicyName PolicyDocument)),
         {:ok, user_name} <- user_name(conn),
         {:ok, policy_name} <- policy_name(conn),
         {:ok, policy_document} <- policy_document(conn),
         :ok <- IAM.put_user_policy_strict(user_name, policy_name, policy_document) do
      Log.info("iam put-user-policy updated",
        action: :put_user_policy,
        principal_arn: conn.assigns.principal[:arn],
        user_name: user_name,
        policy_name: policy_name
      )

      empty_success(conn, "PutUserPolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_user_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName PolicyName)),
         {:ok, user_name} <- user_name(conn),
         {:ok, policy_name} <- policy_name(conn),
         {:ok, policy} <- IAM.get_user_policy_strict(user_name, policy_name) do
      Log.info("iam get-user-policy returned",
        action: :get_user_policy,
        principal_arn: conn.assigns.principal[:arn],
        user_arn: policy.user_arn,
        policy_name: policy.policy_name
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.get_user_policy_response(policy, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_user_policies(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName MaxItems Marker)),
         {:ok, user_name} <- user_name(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, policies} <- IAM.list_user_policies_strict(user_name) do
      page = policy_page(policies, max_items, marker_offset)

      Log.info("iam list-user-policies returned",
        action: :list_user_policies,
        principal_arn: conn.assigns.principal[:arn],
        user_name: user_name,
        policy_count: page.policy_count,
        returned_policy_count: length(page.policy_names),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_user_policies_response(page, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_user_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName PolicyName)),
         {:ok, user_name} <- user_name(conn),
         {:ok, policy_name} <- policy_name(conn),
         :ok <- IAM.delete_user_policy_strict(user_name, policy_name) do
      Log.info("iam delete-user-policy deleted",
        action: :delete_user_policy,
        principal_arn: conn.assigns.principal[:arn],
        user_name: user_name,
        policy_name: policy_name
      )

      empty_success(conn, "DeleteUserPolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp attach_user_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName PolicyArn)),
         {:ok, user_name} <- user_name(conn),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         :ok <- IAM.attach_user_policy_strict(user_name, policy_arn) do
      Log.info("iam attach-user-policy updated",
        action: :attach_user_policy,
        principal_arn: conn.assigns.principal[:arn],
        user_name: user_name,
        policy_arn: policy_arn
      )

      empty_success(conn, "AttachUserPolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_attached_user_policies(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version UserName PathPrefix MaxItems Marker)),
         {:ok, user_name} <- user_name(conn),
         {:ok, path_prefix} <- managed_policy_path_prefix(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, policies} <-
           IAM.list_attached_user_policies_strict(user_name, path_prefix: path_prefix) do
      page = attached_policy_page(policies, max_items, marker_offset)

      Log.info("iam list-attached-user-policies returned",
        action: :list_attached_user_policies,
        principal_arn: conn.assigns.principal[:arn],
        user_name: user_name,
        path_prefix: path_prefix,
        policy_count: page.policy_count,
        returned_policy_count: length(page.policies),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_attached_user_policies_response(page, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp detach_user_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName PolicyArn)),
         {:ok, user_name} <- user_name(conn),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         :ok <- IAM.detach_user_policy_strict(user_name, policy_arn) do
      Log.info("iam detach-user-policy updated",
        action: :detach_user_policy,
        principal_arn: conn.assigns.principal[:arn],
        user_name: user_name,
        policy_arn: policy_arn
      )

      empty_success(conn, "DetachUserPolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp create_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version PolicyName Path PolicyDocument Description),
             [@tag_member_pattern]
           ),
         {:ok, policy_name} <- policy_name(conn),
         {:ok, path} <- managed_policy_path(conn),
         {:ok, policy_document} <- policy_document(conn),
         {:ok, description} <- policy_description(conn),
         {:ok, tags} <- optional_case_sensitive_indexed_tags(conn, "Tags"),
         {:ok, policy} <-
           IAM.create_managed_policy_strict(
             name: policy_name,
             path: path,
             policy: policy_document,
             description: description,
             tags: tags
           ) do
      Log.info("iam create-policy created",
        action: :create_policy,
        principal_arn: conn.assigns.principal[:arn],
        policy_arn: policy.policy_arn,
        tag_count: map_size(policy.tags || %{})
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.create_policy_response(policy, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version PolicyArn)),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         {:ok, policy} <- IAM.get_managed_policy(policy_arn) do
      Log.info("iam get-policy returned",
        action: :get_policy,
        principal_arn: conn.assigns.principal[:arn],
        policy_arn: policy.policy_arn
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.get_policy_response(policy, request_id(conn)))
      |> halt()
    else
      :error -> reject(conn, QueryError.new(:no_such_entity))
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp create_policy_version(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version PolicyArn PolicyDocument SetAsDefault)
           ),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         {:ok, policy_document} <- policy_document(conn),
         {:ok, set_as_default} <- set_as_default(conn),
         {:ok, version} <-
           IAM.create_managed_policy_version_strict(policy_arn, policy_document, set_as_default) do
      Log.info("iam create-policy-version created",
        action: :create_policy_version,
        principal_arn: conn.assigns.principal[:arn],
        policy_arn: policy_arn,
        version_id: version.version_id,
        set_as_default: set_as_default
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.create_policy_version_response(version, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_policy_version(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version PolicyArn VersionId)),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         {:ok, version_id} <- policy_version_id(conn),
         {:ok, version} <- IAM.get_managed_policy_version_strict(policy_arn, version_id) do
      Log.info("iam get-policy-version returned",
        action: :get_policy_version,
        principal_arn: conn.assigns.principal[:arn],
        policy_arn: policy_arn,
        version_id: version_id
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.get_policy_version_response(version, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_policy_versions(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version PolicyArn MaxItems Marker)),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, versions} <- IAM.list_managed_policy_versions_strict(policy_arn) do
      page = policy_version_page(policy_arn, versions, max_items, marker_offset)

      Log.info("iam list-policy-versions returned",
        action: :list_policy_versions,
        principal_arn: conn.assigns.principal[:arn],
        policy_arn: policy_arn,
        returned_version_count: length(page.versions),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_policy_versions_response(page, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp set_default_policy_version(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version PolicyArn VersionId)),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         {:ok, version_id} <- policy_version_id(conn),
         :ok <- IAM.set_default_managed_policy_version_strict(policy_arn, version_id) do
      Log.info("iam set-default-policy-version updated",
        action: :set_default_policy_version,
        principal_arn: conn.assigns.principal[:arn],
        policy_arn: policy_arn,
        version_id: version_id
      )

      empty_success(conn, "SetDefaultPolicyVersion")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_policy_version(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version PolicyArn VersionId)),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         {:ok, version_id} <- policy_version_id(conn),
         :ok <- IAM.delete_managed_policy_version_strict(policy_arn, version_id) do
      Log.info("iam delete-policy-version deleted",
        action: :delete_policy_version,
        principal_arn: conn.assigns.principal[:arn],
        policy_arn: policy_arn,
        version_id: version_id
      )

      empty_success(conn, "DeletePolicyVersion")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_policy_tags(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version PolicyArn MaxItems Marker)),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, policy} <- IAM.list_managed_policy_tags_strict(policy_arn) do
      page =
        policy.tags
        |> tag_page(max_items, marker_offset)
        |> Map.put(:policy_arn, policy.policy_arn)

      Log.info("iam list-policy-tags returned",
        action: :list_policy_tags,
        principal_arn: conn.assigns.principal[:arn],
        policy_arn: policy.policy_arn,
        tag_count: page.tag_count,
        returned_tag_count: map_size(page.tags),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_policy_tags_response(page, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp tag_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version PolicyArn), [@tag_member_pattern]),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         {:ok, tags} <- case_sensitive_indexed_tags(conn, "Tags"),
         {:ok, policy} <- IAM.tag_managed_policy_strict(policy_arn, tags) do
      Log.info("iam tag-policy updated",
        action: :tag_policy,
        principal_arn: conn.assigns.principal[:arn],
        policy_arn: policy.policy_arn,
        tag_count: map_size(policy.tags || %{})
      )

      empty_success(conn, "TagPolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp untag_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version PolicyArn), [@tag_key_member_pattern]),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         {:ok, tag_keys} <- indexed_case_sensitive_tag_keys(conn),
         {:ok, policy} <- IAM.untag_managed_policy_strict(policy_arn, tag_keys) do
      Log.info("iam untag-policy updated",
        action: :untag_policy,
        principal_arn: conn.assigns.principal[:arn],
        policy_arn: policy.policy_arn,
        tag_count: map_size(policy.tags || %{})
      )

      empty_success(conn, "UntagPolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_entities_for_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version PolicyArn EntityFilter PathPrefix PolicyUsageFilter MaxItems Marker)
           ),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         {:ok, entity_filter} <- policy_entity_filter(conn),
         {:ok, path_prefix} <- policy_entity_path_prefix(conn),
         {:ok, policy_usage_filter} <- policy_usage_filter(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, entities} <-
           IAM.list_managed_policy_entities_strict(policy_arn,
             entity_filter: entity_filter,
             path_prefix: path_prefix,
             policy_usage_filter: policy_usage_filter
           ) do
      page = policy_entities_page(entities, max_items, marker_offset)

      Log.info("iam list-entities-for-policy returned",
        action: :list_entities_for_policy,
        principal_arn: conn.assigns.principal[:arn],
        policy_arn: policy_arn,
        entity_filter: entity_filter,
        path_prefix: path_prefix,
        policy_usage_filter: policy_usage_filter,
        entity_count: page.entity_count,
        returned_entity_count: length(page.users) + length(page.groups) + length(page.roles),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_entities_for_policy_response(page, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_policies(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version Scope OnlyAttached PathPrefix PolicyUsageFilter MaxItems Marker)
           ),
         {:ok, scope} <- list_policy_scope(conn),
         {:ok, only_attached} <- only_attached(conn),
         {:ok, path_prefix} <- managed_policy_path_prefix(conn),
         {:ok, policy_usage_filter} <- policy_usage_filter(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn) do
      page =
        IAM.list_managed_policies(
          scope: scope,
          only_attached: only_attached,
          path_prefix: path_prefix,
          policy_usage_filter: policy_usage_filter
        )
        |> managed_policy_page(max_items, marker_offset)

      Log.info("iam list-policies returned",
        action: :list_policies,
        principal_arn: conn.assigns.principal[:arn],
        scope: scope,
        only_attached: only_attached,
        path_prefix: path_prefix,
        policy_usage_filter: policy_usage_filter,
        policy_count: page.policy_count,
        returned_policy_count: length(page.policies),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_policies_response(page, request_id(conn)))
      |> halt()
    else
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version PolicyArn)),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         :ok <- IAM.delete_managed_policy_strict(policy_arn) do
      Log.info("iam delete-policy deleted",
        action: :delete_policy,
        principal_arn: conn.assigns.principal[:arn],
        policy_arn: policy_arn
      )

      empty_success(conn, "DeletePolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp create_group(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version Path GroupName)),
         {:ok, group_name} <- group_name(conn),
         {:ok, path} <- root_group_path(conn),
         {:ok, group} <- IAM.create_group(group_name: group_name) do
      Log.info("iam create-group created",
        action: :create_group,
        principal_arn: conn.assigns.principal[:arn],
        group_arn: group.group_arn,
        path: path
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.create_group_response(group, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_group(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version GroupName MaxItems Marker)),
         {:ok, group_name} <- group_name(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, group} <- IAM.get_group(group_name) do
      page =
        group_name
        |> IAM.list_users_in_group()
        |> user_page("/", max_items, marker_offset)
        |> Map.put(:group, group)

      Log.info("iam get-group returned",
        action: :get_group,
        principal_arn: conn.assigns.principal[:arn],
        group_arn: group.group_arn,
        user_count: page.user_count,
        returned_user_count: length(page.users),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.get_group_response(page, request_id(conn)))
      |> halt()
    else
      :error -> reject(conn, QueryError.new(:no_such_entity))
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp update_group(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version GroupName NewGroupName NewPath)),
         {:ok, group_name} <- group_name(conn),
         {:ok, new_group_name} <- new_group_name(conn),
         {:ok, new_path} <- root_new_group_path(conn),
         {:ok, group} <- IAM.update_group_name_strict(group_name, new_group_name) do
      Log.info("iam update-group updated",
        action: :update_group,
        principal_arn: conn.assigns.principal[:arn],
        old_group_name: group_name,
        new_group_name: group.group_name,
        group_arn: group.group_arn,
        path: new_path
      )

      empty_success(conn, "UpdateGroup")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_groups(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version PathPrefix MaxItems Marker)),
         {:ok, path_prefix} <- root_group_path_prefix(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn) do
      page =
        IAM.list_groups()
        |> group_page(path_prefix, max_items, marker_offset)

      Log.info("iam list-groups returned",
        action: :list_groups,
        principal_arn: conn.assigns.principal[:arn],
        path_prefix: path_prefix,
        group_count: page.group_count,
        returned_group_count: length(page.groups),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_groups_response(page, request_id(conn)))
      |> halt()
    else
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_group(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version GroupName)),
         {:ok, group_name} <- group_name(conn),
         {:ok, group} <- IAM.delete_group_strict(group_name) do
      Log.info("iam delete-group deleted",
        action: :delete_group,
        principal_arn: conn.assigns.principal[:arn],
        group_arn: group.group_arn
      )

      empty_success(conn, "DeleteGroup")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp put_group_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version GroupName PolicyName PolicyDocument)),
         {:ok, group_name} <- group_name(conn),
         {:ok, policy_name} <- policy_name(conn),
         {:ok, policy_document} <- policy_document(conn),
         :ok <- IAM.put_group_policy_strict(group_name, policy_name, policy_document) do
      Log.info("iam put-group-policy updated",
        action: :put_group_policy,
        principal_arn: conn.assigns.principal[:arn],
        group_name: group_name,
        policy_name: policy_name
      )

      empty_success(conn, "PutGroupPolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_group_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version GroupName PolicyName)),
         {:ok, group_name} <- group_name(conn),
         {:ok, policy_name} <- policy_name(conn),
         {:ok, policy} <- IAM.get_group_policy_strict(group_name, policy_name) do
      Log.info("iam get-group-policy returned",
        action: :get_group_policy,
        principal_arn: conn.assigns.principal[:arn],
        group_arn: policy.group_arn,
        policy_name: policy.policy_name
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.get_group_policy_response(policy, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_group_policies(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version GroupName MaxItems Marker)),
         {:ok, group_name} <- group_name(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, policies} <- IAM.list_group_policies_strict(group_name) do
      page = policy_page(policies, max_items, marker_offset)

      Log.info("iam list-group-policies returned",
        action: :list_group_policies,
        principal_arn: conn.assigns.principal[:arn],
        group_name: group_name,
        policy_count: page.policy_count,
        returned_policy_count: length(page.policy_names),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_group_policies_response(page, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_group_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version GroupName PolicyName)),
         {:ok, group_name} <- group_name(conn),
         {:ok, policy_name} <- policy_name(conn),
         :ok <- IAM.delete_group_policy_strict(group_name, policy_name) do
      Log.info("iam delete-group-policy deleted",
        action: :delete_group_policy,
        principal_arn: conn.assigns.principal[:arn],
        group_name: group_name,
        policy_name: policy_name
      )

      empty_success(conn, "DeleteGroupPolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp create_role(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version Path RoleName AssumeRolePolicyDocument Description MaxSessionDuration PermissionsBoundary),
             [@tag_member_pattern]
           ),
         {:ok, role_name} <- role_name(conn),
         {:ok, path} <- root_role_path(conn),
         {:ok, trust_policy_document} <- assume_role_policy_document(conn),
         {:ok, description} <- role_description(conn),
         {:ok, max_session_duration_seconds} <- max_session_duration(conn),
         {:ok, permissions_boundary_policy_arn} <- optional_permissions_boundary_policy_arn(conn),
         {:ok, tags} <- optional_indexed_tags(conn, "Tags"),
         {:ok, role} <-
           IAM.create_role(
             role_name: role_name,
             description: description,
             trust_policy_document: trust_policy_document,
             max_session_duration_seconds: max_session_duration_seconds,
             permissions_boundary_policy_arn: permissions_boundary_policy_arn,
             tags: tags
           ) do
      Log.info("iam create-role created",
        action: :create_role,
        principal_arn: conn.assigns.principal[:arn],
        role_arn: role.role_arn,
        description_present?: role.description != "",
        path: path,
        max_session_duration_seconds: role.max_session_duration_seconds,
        permissions_boundary_policy_arn: permissions_boundary_policy_arn,
        tag_count: map_size(role.tags)
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.create_role_response(role, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_role(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version RoleName)),
         {:ok, role_name} <- role_name(conn),
         {:ok, role} <- IAM.get_role(role_name) do
      Log.info("iam get-role returned",
        action: :get_role,
        principal_arn: conn.assigns.principal[:arn],
        role_arn: role.role_arn
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.get_role_response(role, request_id(conn)))
      |> halt()
    else
      :error -> reject(conn, QueryError.new(:no_such_entity))
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp update_assume_role_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version RoleName PolicyDocument)),
         {:ok, role_name} <- role_name(conn),
         {:ok, policy_document} <- trust_policy_document(conn),
         {:ok, role} <- IAM.update_assume_role_policy_strict(role_name, policy_document) do
      Log.info("iam update-assume-role-policy updated",
        action: :update_assume_role_policy,
        principal_arn: conn.assigns.principal[:arn],
        role_arn: role.role_arn
      )

      empty_success(conn, "UpdateAssumeRolePolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp update_role(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version RoleName Description MaxSessionDuration)
           ),
         {:ok, role_name} <- role_name(conn),
         {:ok, description} <- optional_role_description(conn),
         {:ok, max_session_duration_seconds} <- optional_max_session_duration(conn),
         {:ok, role} <-
           IAM.update_role_strict(role_name,
             description: description,
             max_session_duration_seconds: max_session_duration_seconds
           ) do
      Log.info("iam update-role updated",
        action: :update_role,
        principal_arn: conn.assigns.principal[:arn],
        role_arn: role.role_arn,
        description_present?: role.description != "",
        max_session_duration_seconds: role.max_session_duration_seconds
      )

      empty_success(conn, "UpdateRole")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_roles(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version PathPrefix MaxItems Marker)),
         {:ok, path_prefix} <- root_role_path_prefix(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn) do
      page =
        IAM.list_roles()
        |> role_page(path_prefix, max_items, marker_offset)

      Log.info("iam list-roles returned",
        action: :list_roles,
        principal_arn: conn.assigns.principal[:arn],
        path_prefix: path_prefix,
        role_count: page.role_count,
        returned_role_count: length(page.roles),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_roles_response(page, request_id(conn)))
      |> halt()
    else
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_role(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version RoleName)),
         {:ok, role_name} <- role_name(conn),
         {:ok, role} <- IAM.delete_role_strict(role_name) do
      Log.info("iam delete-role deleted",
        action: :delete_role,
        principal_arn: conn.assigns.principal[:arn],
        role_arn: role.role_arn
      )

      empty_success(conn, "DeleteRole")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp put_role_permissions_boundary(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version RoleName PermissionsBoundary)),
         {:ok, role_name} <- role_name(conn),
         {:ok, policy_arn} <- permissions_boundary_policy_arn(conn),
         {:ok, role} <- IAM.put_role_permissions_boundary_strict(role_name, policy_arn) do
      Log.info("iam put-role-permissions-boundary updated",
        action: :put_role_permissions_boundary,
        principal_arn: conn.assigns.principal[:arn],
        role_arn: role.role_arn,
        policy_arn: policy_arn
      )

      empty_success(conn, "PutRolePermissionsBoundary")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_role_permissions_boundary(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version RoleName)),
         {:ok, role_name} <- role_name(conn),
         {:ok, role} <- IAM.delete_role_permissions_boundary_strict(role_name) do
      Log.info("iam delete-role-permissions-boundary deleted",
        action: :delete_role_permissions_boundary,
        principal_arn: conn.assigns.principal[:arn],
        role_arn: role.role_arn
      )

      empty_success(conn, "DeleteRolePermissionsBoundary")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_role_tags(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version RoleName MaxItems Marker)),
         {:ok, role_name} <- role_name(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, role} <- IAM.list_role_tags_strict(role_name) do
      tag_page =
        role.tags
        |> tag_page(max_items, marker_offset)
        |> Map.put(:role_name, role.role_name)

      Log.info("iam list-role-tags returned",
        action: :list_role_tags,
        principal_arn: conn.assigns.principal[:arn],
        role_arn: role.role_arn,
        tag_count: tag_page.tag_count,
        returned_tag_count: map_size(tag_page.tags || %{}),
        is_truncated: tag_page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_role_tags_response(tag_page, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp tag_role(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <-
           require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version RoleName), [@tag_member_pattern]),
         {:ok, role_name} <- role_name(conn),
         {:ok, tags} <- indexed_tags(conn, "Tags"),
         {:ok, role} <- IAM.tag_role(role_name, tags) do
      Log.info("iam tag-role updated",
        action: :tag_role,
        principal_arn: conn.assigns.principal[:arn],
        role_arn: role.role_arn,
        tag_count: map_size(role.tags)
      )

      empty_success(conn, "TagRole")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp untag_role(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version RoleName), [@tag_key_member_pattern]),
         {:ok, role_name} <- role_name(conn),
         {:ok, tag_keys} <- indexed_tag_keys(conn),
         {:ok, role} <- IAM.untag_role(role_name, tag_keys) do
      Log.info("iam untag-role updated",
        action: :untag_role,
        principal_arn: conn.assigns.principal[:arn],
        role_arn: role.role_arn,
        tag_count: map_size(role.tags)
      )

      empty_success(conn, "UntagRole")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp create_instance_profile(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version Path InstanceProfileName),
             [@tag_member_pattern]
           ),
         {:ok, instance_profile_name} <- instance_profile_name(conn),
         {:ok, path} <- instance_profile_path(conn),
         {:ok, tags} <- optional_case_sensitive_indexed_tags(conn, "Tags"),
         {:ok, instance_profile} <-
           IAM.create_instance_profile(
             instance_profile_name: instance_profile_name,
             path: path,
             tags: tags
           ) do
      Log.info("iam create-instance-profile created",
        action: :create_instance_profile,
        principal_arn: conn.assigns.principal[:arn],
        instance_profile_arn: instance_profile.instance_profile_arn,
        path: path,
        tag_count: map_size(instance_profile.tags)
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(
        200,
        QueryView.create_instance_profile_response(instance_profile, request_id(conn))
      )
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_instance_profile(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version InstanceProfileName)),
         {:ok, instance_profile_name} <- instance_profile_name(conn),
         {:ok, instance_profile} <- IAM.get_instance_profile(instance_profile_name) do
      Log.info("iam get-instance-profile returned",
        action: :get_instance_profile,
        principal_arn: conn.assigns.principal[:arn],
        instance_profile_arn: instance_profile.instance_profile_arn
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(
        200,
        QueryView.get_instance_profile_response(instance_profile, request_id(conn))
      )
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_instance_profiles(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version PathPrefix MaxItems Marker)),
         {:ok, path_prefix} <- instance_profile_path_prefix(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn) do
      page =
        IAM.list_instance_profiles()
        |> instance_profile_page(path_prefix, max_items, marker_offset)

      Log.info("iam list-instance-profiles returned",
        action: :list_instance_profiles,
        principal_arn: conn.assigns.principal[:arn],
        path_prefix: path_prefix,
        instance_profile_count: page.instance_profile_count,
        returned_instance_profile_count: length(page.instance_profiles),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_instance_profiles_response(page, request_id(conn)))
      |> halt()
    else
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_instance_profile(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version InstanceProfileName)),
         {:ok, instance_profile_name} <- instance_profile_name(conn),
         {:ok, instance_profile} <- IAM.delete_instance_profile_strict(instance_profile_name) do
      Log.info("iam delete-instance-profile deleted",
        action: :delete_instance_profile,
        principal_arn: conn.assigns.principal[:arn],
        instance_profile_arn: instance_profile.instance_profile_arn
      )

      empty_success(conn, "DeleteInstanceProfile")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp add_role_to_instance_profile(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version InstanceProfileName RoleName)),
         {:ok, instance_profile_name} <- instance_profile_name(conn),
         {:ok, role_name} <- role_name(conn),
         {:ok, instance_profile} <-
           IAM.add_role_to_instance_profile_strict(instance_profile_name, role_name) do
      Log.info("iam add-role-to-instance-profile updated",
        action: :add_role_to_instance_profile,
        principal_arn: conn.assigns.principal[:arn],
        instance_profile_arn: instance_profile.instance_profile_arn,
        role_name: role_name
      )

      empty_success(conn, "AddRoleToInstanceProfile")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp remove_role_from_instance_profile(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version InstanceProfileName RoleName)),
         {:ok, instance_profile_name} <- instance_profile_name(conn),
         {:ok, role_name} <- role_name(conn),
         {:ok, instance_profile} <-
           IAM.remove_role_from_instance_profile_strict(instance_profile_name, role_name) do
      Log.info("iam remove-role-from-instance-profile updated",
        action: :remove_role_from_instance_profile,
        principal_arn: conn.assigns.principal[:arn],
        instance_profile_arn: instance_profile.instance_profile_arn,
        role_name: role_name
      )

      empty_success(conn, "RemoveRoleFromInstanceProfile")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_instance_profiles_for_role(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version RoleName MaxItems Marker)),
         {:ok, role_name} <- role_name(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, instance_profiles} <- IAM.list_instance_profiles_for_role_strict(role_name) do
      page = instance_profile_page(instance_profiles, "/", max_items, marker_offset)

      Log.info("iam list-instance-profiles-for-role returned",
        action: :list_instance_profiles_for_role,
        principal_arn: conn.assigns.principal[:arn],
        role_name: role_name,
        instance_profile_count: page.instance_profile_count,
        returned_instance_profile_count: length(page.instance_profiles),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(
        200,
        QueryView.list_instance_profiles_for_role_response(page, request_id(conn))
      )
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_instance_profile_tags(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version InstanceProfileName MaxItems Marker)),
         {:ok, instance_profile_name} <- instance_profile_name(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, instance_profile} <- IAM.list_instance_profile_tags_strict(instance_profile_name) do
      tag_page =
        instance_profile.tags
        |> tag_page(max_items, marker_offset)
        |> Map.put(:instance_profile_name, instance_profile.instance_profile_name)

      Log.info("iam list-instance-profile-tags returned",
        action: :list_instance_profile_tags,
        principal_arn: conn.assigns.principal[:arn],
        instance_profile_arn: instance_profile.instance_profile_arn,
        tag_count: tag_page.tag_count,
        returned_tag_count: map_size(tag_page.tags || %{}),
        is_truncated: tag_page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_instance_profile_tags_response(tag_page, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp tag_instance_profile(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version InstanceProfileName),
             [@tag_member_pattern]
           ),
         {:ok, instance_profile_name} <- instance_profile_name(conn),
         {:ok, tags} <- case_sensitive_indexed_tags(conn, "Tags"),
         {:ok, instance_profile} <- IAM.tag_instance_profile(instance_profile_name, tags) do
      Log.info("iam tag-instance-profile updated",
        action: :tag_instance_profile,
        principal_arn: conn.assigns.principal[:arn],
        instance_profile_arn: instance_profile.instance_profile_arn,
        tag_count: map_size(instance_profile.tags)
      )

      empty_success(conn, "TagInstanceProfile")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp untag_instance_profile(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version InstanceProfileName),
             [@tag_key_member_pattern]
           ),
         {:ok, instance_profile_name} <- instance_profile_name(conn),
         {:ok, tag_keys} <- indexed_case_sensitive_tag_keys(conn),
         {:ok, instance_profile} <- IAM.untag_instance_profile(instance_profile_name, tag_keys) do
      Log.info("iam untag-instance-profile updated",
        action: :untag_instance_profile,
        principal_arn: conn.assigns.principal[:arn],
        instance_profile_arn: instance_profile.instance_profile_arn,
        tag_count: map_size(instance_profile.tags)
      )

      empty_success(conn, "UntagInstanceProfile")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp upload_server_certificate(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version Path ServerCertificateName CertificateBody PrivateKey CertificateChain),
             [@tag_member_pattern]
           ),
         {:ok, server_certificate_name} <- server_certificate_name(conn),
         {:ok, path} <- server_certificate_path(conn),
         {:ok, certificate_body} <- certificate_body(conn),
         {:ok, private_key} <- private_key(conn),
         {:ok, certificate_chain} <- certificate_chain(conn),
         {:ok, tags} <- optional_case_sensitive_indexed_tags(conn, "Tags"),
         {:ok, server_certificate} <-
           IAM.upload_server_certificate(
             server_certificate_name: server_certificate_name,
             path: path,
             certificate_body: certificate_body,
             private_key: private_key,
             certificate_chain: certificate_chain,
             tags: tags
           ) do
      Log.info("iam upload-server-certificate created",
        action: :upload_server_certificate,
        principal_arn: conn.assigns.principal[:arn],
        server_certificate_arn: server_certificate.server_certificate_arn,
        path: path,
        tag_count: map_size(server_certificate.tags)
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(
        200,
        QueryView.upload_server_certificate_response(server_certificate, request_id(conn))
      )
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_server_certificate(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version ServerCertificateName)),
         {:ok, server_certificate_name} <- server_certificate_name(conn),
         {:ok, server_certificate} <- IAM.get_server_certificate(server_certificate_name) do
      Log.info("iam get-server-certificate returned",
        action: :get_server_certificate,
        principal_arn: conn.assigns.principal[:arn],
        server_certificate_arn: server_certificate.server_certificate_arn
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(
        200,
        QueryView.get_server_certificate_response(server_certificate, request_id(conn))
      )
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_server_certificates(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version PathPrefix MaxItems Marker)),
         {:ok, path_prefix} <- server_certificate_path_prefix(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn) do
      page =
        IAM.list_server_certificates()
        |> server_certificate_page(path_prefix, max_items, marker_offset)

      Log.info("iam list-server-certificates returned",
        action: :list_server_certificates,
        principal_arn: conn.assigns.principal[:arn],
        path_prefix: path_prefix,
        server_certificate_count: page.server_certificate_count,
        returned_server_certificate_count: length(page.server_certificates),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_server_certificates_response(page, request_id(conn)))
      |> halt()
    else
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp update_server_certificate(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version ServerCertificateName NewServerCertificateName NewPath)
           ),
         {:ok, server_certificate_name} <- server_certificate_name(conn),
         {:ok, new_name} <- new_server_certificate_name(conn),
         {:ok, new_path} <- server_certificate_new_path(conn),
         {:ok, server_certificate} <-
           IAM.update_server_certificate_strict(
             server_certificate_name,
             server_certificate_update_params(new_name, new_path)
           ) do
      Log.info("iam update-server-certificate updated",
        action: :update_server_certificate,
        principal_arn: conn.assigns.principal[:arn],
        server_certificate_arn: server_certificate.server_certificate_arn,
        new_server_certificate_name: new_name,
        new_path: new_path
      )

      empty_success(conn, "UpdateServerCertificate")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_server_certificate(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version ServerCertificateName)),
         {:ok, server_certificate_name} <- server_certificate_name(conn),
         {:ok, server_certificate} <-
           IAM.delete_server_certificate_strict(server_certificate_name) do
      Log.info("iam delete-server-certificate deleted",
        action: :delete_server_certificate,
        principal_arn: conn.assigns.principal[:arn],
        server_certificate_arn: server_certificate.server_certificate_arn
      )

      empty_success(conn, "DeleteServerCertificate")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_server_certificate_tags(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version ServerCertificateName MaxItems Marker)
           ),
         {:ok, server_certificate_name} <- server_certificate_name(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, server_certificate} <-
           IAM.list_server_certificate_tags_strict(server_certificate_name) do
      tag_page =
        server_certificate.tags
        |> tag_page(max_items, marker_offset)
        |> Map.put(:server_certificate_name, server_certificate.server_certificate_name)

      Log.info("iam list-server-certificate-tags returned",
        action: :list_server_certificate_tags,
        principal_arn: conn.assigns.principal[:arn],
        server_certificate_arn: server_certificate.server_certificate_arn,
        tag_count: tag_page.tag_count,
        returned_tag_count: map_size(tag_page.tags || %{}),
        is_truncated: tag_page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(
        200,
        QueryView.list_server_certificate_tags_response(tag_page, request_id(conn))
      )
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp tag_server_certificate(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version ServerCertificateName),
             [@tag_member_pattern]
           ),
         {:ok, server_certificate_name} <- server_certificate_name(conn),
         {:ok, tags} <- case_sensitive_indexed_tags(conn, "Tags"),
         {:ok, server_certificate} <- IAM.tag_server_certificate(server_certificate_name, tags) do
      Log.info("iam tag-server-certificate updated",
        action: :tag_server_certificate,
        principal_arn: conn.assigns.principal[:arn],
        server_certificate_arn: server_certificate.server_certificate_arn,
        tag_count: map_size(server_certificate.tags)
      )

      empty_success(conn, "TagServerCertificate")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp untag_server_certificate(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version ServerCertificateName),
             [@tag_key_member_pattern]
           ),
         {:ok, server_certificate_name} <- server_certificate_name(conn),
         {:ok, tag_keys} <- indexed_case_sensitive_tag_keys(conn),
         {:ok, server_certificate} <-
           IAM.untag_server_certificate(server_certificate_name, tag_keys) do
      Log.info("iam untag-server-certificate updated",
        action: :untag_server_certificate,
        principal_arn: conn.assigns.principal[:arn],
        server_certificate_arn: server_certificate.server_certificate_arn,
        tag_count: map_size(server_certificate.tags)
      )

      empty_success(conn, "UntagServerCertificate")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp put_role_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version RoleName PolicyName PolicyDocument)),
         {:ok, role_name} <- role_name(conn),
         {:ok, policy_name} <- policy_name(conn),
         {:ok, policy_document} <- policy_document(conn),
         :ok <- IAM.put_role_policy_strict(role_name, policy_name, policy_document) do
      Log.info("iam put-role-policy updated",
        action: :put_role_policy,
        principal_arn: conn.assigns.principal[:arn],
        role_name: role_name,
        policy_name: policy_name
      )

      empty_success(conn, "PutRolePolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_role_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version RoleName PolicyName)),
         {:ok, role_name} <- role_name(conn),
         {:ok, policy_name} <- policy_name(conn),
         {:ok, policy} <- IAM.get_role_policy_strict(role_name, policy_name) do
      Log.info("iam get-role-policy returned",
        action: :get_role_policy,
        principal_arn: conn.assigns.principal[:arn],
        role_arn: policy.role_arn,
        policy_name: policy.policy_name
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.get_role_policy_response(policy, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_role_policies(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version RoleName MaxItems Marker)),
         {:ok, role_name} <- role_name(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, policies} <- IAM.list_role_policies_strict(role_name) do
      page = policy_page(policies, max_items, marker_offset)

      Log.info("iam list-role-policies returned",
        action: :list_role_policies,
        principal_arn: conn.assigns.principal[:arn],
        role_name: role_name,
        policy_count: page.policy_count,
        returned_policy_count: length(page.policy_names),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_role_policies_response(page, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_role_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version RoleName PolicyName)),
         {:ok, role_name} <- role_name(conn),
         {:ok, policy_name} <- policy_name(conn),
         :ok <- IAM.delete_role_policy_strict(role_name, policy_name) do
      Log.info("iam delete-role-policy deleted",
        action: :delete_role_policy,
        principal_arn: conn.assigns.principal[:arn],
        role_name: role_name,
        policy_name: policy_name
      )

      empty_success(conn, "DeleteRolePolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp attach_group_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version GroupName PolicyArn)),
         {:ok, group_name} <- group_name(conn),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         :ok <- IAM.attach_group_policy_strict(group_name, policy_arn) do
      Log.info("iam attach-group-policy updated",
        action: :attach_group_policy,
        principal_arn: conn.assigns.principal[:arn],
        group_name: group_name,
        policy_arn: policy_arn
      )

      empty_success(conn, "AttachGroupPolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_attached_group_policies(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version GroupName PathPrefix MaxItems Marker)
           ),
         {:ok, group_name} <- group_name(conn),
         {:ok, path_prefix} <- managed_policy_path_prefix(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, policies} <-
           IAM.list_attached_group_policies_strict(group_name, path_prefix: path_prefix) do
      page = attached_policy_page(policies, max_items, marker_offset)

      Log.info("iam list-attached-group-policies returned",
        action: :list_attached_group_policies,
        principal_arn: conn.assigns.principal[:arn],
        group_name: group_name,
        path_prefix: path_prefix,
        policy_count: page.policy_count,
        returned_policy_count: length(page.policies),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_attached_group_policies_response(page, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp detach_group_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version GroupName PolicyArn)),
         {:ok, group_name} <- group_name(conn),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         :ok <- IAM.detach_group_policy_strict(group_name, policy_arn) do
      Log.info("iam detach-group-policy updated",
        action: :detach_group_policy,
        principal_arn: conn.assigns.principal[:arn],
        group_name: group_name,
        policy_arn: policy_arn
      )

      empty_success(conn, "DetachGroupPolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp attach_role_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version RoleName PolicyArn)),
         {:ok, role_name} <- role_name(conn),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         :ok <- IAM.attach_role_policy_strict(role_name, policy_arn) do
      Log.info("iam attach-role-policy updated",
        action: :attach_role_policy,
        principal_arn: conn.assigns.principal[:arn],
        role_name: role_name,
        policy_arn: policy_arn
      )

      empty_success(conn, "AttachRolePolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_attached_role_policies(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version RoleName PathPrefix MaxItems Marker)),
         {:ok, role_name} <- role_name(conn),
         {:ok, path_prefix} <- managed_policy_path_prefix(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, policies} <-
           IAM.list_attached_role_policies_strict(role_name, path_prefix: path_prefix) do
      page = attached_policy_page(policies, max_items, marker_offset)

      Log.info("iam list-attached-role-policies returned",
        action: :list_attached_role_policies,
        principal_arn: conn.assigns.principal[:arn],
        role_name: role_name,
        path_prefix: path_prefix,
        policy_count: page.policy_count,
        returned_policy_count: length(page.policies),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_attached_role_policies_response(page, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp detach_role_policy(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version RoleName PolicyArn)),
         {:ok, role_name} <- role_name(conn),
         {:ok, policy_arn} <- managed_policy_arn(conn),
         :ok <- IAM.detach_role_policy_strict(role_name, policy_arn) do
      Log.info("iam detach-role-policy updated",
        action: :detach_role_policy,
        principal_arn: conn.assigns.principal[:arn],
        role_name: role_name,
        policy_arn: policy_arn
      )

      empty_success(conn, "DetachRolePolicy")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp add_user_to_group(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version GroupName UserName)),
         {:ok, group_name} <- group_name(conn),
         {:ok, user_name} <- user_name(conn),
         :ok <- IAM.add_user_to_group_strict(user_name, group_name) do
      Log.info("iam add-user-to-group updated",
        action: :add_user_to_group,
        principal_arn: conn.assigns.principal[:arn],
        user_name: user_name,
        group_name: group_name
      )

      empty_success(conn, "AddUserToGroup")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp remove_user_from_group(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version GroupName UserName)),
         {:ok, group_name} <- group_name(conn),
         {:ok, user_name} <- user_name(conn),
         :ok <- IAM.remove_user_from_group_strict(user_name, group_name) do
      Log.info("iam remove-user-from-group updated",
        action: :remove_user_from_group,
        principal_arn: conn.assigns.principal[:arn],
        user_name: user_name,
        group_name: group_name
      )

      empty_success(conn, "RemoveUserFromGroup")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_groups_for_user(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName MaxItems Marker)),
         {:ok, user_name} <- user_name(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, user} <- IAM.get_user(user_name) do
      page =
        user_name
        |> IAM.list_groups_for_user()
        |> group_page("/", max_items, marker_offset)

      Log.info("iam list-groups-for-user returned",
        action: :list_groups_for_user,
        principal_arn: conn.assigns.principal[:arn],
        user_arn: user.user_arn,
        group_count: page.group_count,
        returned_group_count: length(page.groups),
        is_truncated: page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_groups_for_user_response(page, request_id(conn)))
      |> halt()
    else
      :error -> reject(conn, QueryError.new(:no_such_entity))
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_user_tags(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName MaxItems Marker)),
         {:ok, user_name} <- user_name(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, user} <- IAM.get_user(user_name) do
      tag_page = tag_page(user.tags, max_items, marker_offset)

      Log.info("iam list-user-tags returned",
        action: :list_user_tags,
        principal_arn: conn.assigns.principal[:arn],
        user_arn: user.user_arn,
        tag_count: tag_page.tag_count,
        returned_tag_count: map_size(tag_page.tags),
        is_truncated: tag_page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_user_tags_response(tag_page, request_id(conn)))
      |> halt()
    else
      :error -> reject(conn, QueryError.new(:no_such_entity))
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp tag_user(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version UserName), [@tag_member_pattern]),
         {:ok, user_name} <- user_name(conn),
         {:ok, tags} <- indexed_tags(conn, "Tags"),
         {:ok, user} <- IAM.tag_user(user_name, tags) do
      Log.info("iam tag-user updated",
        action: :tag_user,
        principal_arn: conn.assigns.principal[:arn],
        user_arn: user.user_arn,
        tag_count: map_size(user.tags)
      )

      empty_success(conn, "TagUser")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp untag_user(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version UserName), [@tag_key_member_pattern]),
         {:ok, user_name} <- user_name(conn),
         {:ok, tag_keys} <- indexed_tag_keys(conn),
         {:ok, user} <- IAM.untag_user(user_name, tag_keys) do
      Log.info("iam untag-user updated",
        action: :untag_user,
        principal_arn: conn.assigns.principal[:arn],
        user_arn: user.user_arn,
        tag_count: map_size(user.tags)
      )

      empty_success(conn, "UntagUser")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp create_virtual_mfa_device(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version Path VirtualMFADeviceName)),
         {:ok, name} <- virtual_mfa_device_name(conn),
         {:ok, path} <- path(conn),
         {:ok, owner_arn} <- caller_owned_mfa_principal(conn),
         {:ok, enrolled} <-
           IAM.create_mfa_device(
             principal_arn: owner_arn,
             device_name: mfa_device_label(path, name),
             serial: virtual_mfa_serial(path, name)
           ) do
      request_id = request_id(conn)

      Log.info("iam create-virtual-mfa-device created",
        action: :create_virtual_mfa_device,
        principal_arn: conn.assigns.principal[:arn],
        mfa_serial_hash: sha256_hex(enrolled.serial)
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.create_virtual_mfa_device_response(enrolled, request_id))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp enable_mfa_device(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version UserName SerialNumber AuthenticationCode1 AuthenticationCode2)
           ),
         {:ok, target_arn} <- required_user_principal_arn(conn),
         {:ok, serial} <- serial_number(conn),
         {:ok, code1} <- authentication_code(conn, "AuthenticationCode1"),
         {:ok, code2} <- authentication_code(conn, "AuthenticationCode2"),
         {:ok, _device} <-
           IAM.enable_mfa_device(target_arn, serial, code1, code2,
             allow_reassign: root_principal?(conn.assigns.principal),
             time: current_time(conn)
           ) do
      Log.info("iam enable-mfa-device enabled",
        action: :enable_mfa_device,
        principal_arn: conn.assigns.principal[:arn],
        target_principal_arn: target_arn,
        mfa_serial_hash: sha256_hex(serial)
      )

      empty_success(conn, "EnableMFADevice")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_mfa_devices(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName MaxItems Marker)),
         {:ok, target_arn} <- optional_user_principal_arn(conn) do
      devices =
        target_arn
        |> IAM.list_mfa_devices()
        |> Enum.filter(&(&1.status == "active"))

      Log.info("iam list-mfa-devices returned",
        action: :list_mfa_devices,
        principal_arn: conn.assigns.principal[:arn],
        target_principal_arn: target_arn,
        count: length(devices)
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QueryView.list_mfa_devices_response(devices, request_id(conn)))
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
    end
  end

  defp deactivate_mfa_device(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version UserName SerialNumber)),
         {:ok, target_arn} <- required_user_principal_arn(conn),
         {:ok, serial} <- serial_number(conn),
         {:ok, device} <- fetch_owned_mfa_device(serial, target_arn),
         {:ok, _device} <- IAM.disable_mfa_device(device.serial, force: true) do
      Log.info("iam deactivate-mfa-device deactivated",
        action: :deactivate_mfa_device,
        principal_arn: conn.assigns.principal[:arn],
        target_principal_arn: target_arn,
        mfa_serial_hash: sha256_hex(serial)
      )

      empty_success(conn, "DeactivateMFADevice")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_virtual_mfa_device(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version SerialNumber)),
         {:ok, serial} <- serial_number(conn),
         {:ok, device} <- fetch_manageable_mfa_device(conn, serial),
         :ok <- IAM.delete_mfa_device(device.serial) do
      Log.info("iam delete-virtual-mfa-device deleted",
        action: :delete_virtual_mfa_device,
        principal_arn: conn.assigns.principal[:arn],
        mfa_serial_hash: sha256_hex(serial)
      )

      empty_success(conn, "DeleteVirtualMFADevice")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp resync_mfa_device(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version UserName SerialNumber AuthenticationCode1 AuthenticationCode2)
           ),
         {:ok, target_arn} <- required_user_principal_arn(conn),
         {:ok, serial} <- serial_number(conn),
         {:ok, code1} <- authentication_code(conn, "AuthenticationCode1"),
         {:ok, code2} <- authentication_code(conn, "AuthenticationCode2"),
         {:ok, _device} <-
           IAM.resync_mfa_device(target_arn, serial, code1, code2, time: current_time(conn)) do
      Log.info("iam resync-mfa-device resynced",
        action: :resync_mfa_device,
        principal_arn: conn.assigns.principal[:arn],
        target_principal_arn: target_arn,
        mfa_serial_hash: sha256_hex(serial)
      )

      empty_success(conn, "ResyncMFADevice")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp create_open_id_connect_provider(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version Url),
             [@client_id_member_pattern, @thumbprint_member_pattern, @tag_member_pattern]
           ),
         {:ok, url} <- open_id_connect_provider_url(conn),
         {:ok, client_ids} <- indexed_param_values(conn, "ClientIDList", "ClientIDList"),
         {:ok, thumbprints} <-
           optional_indexed_param_values(conn, "ThumbprintList", "ThumbprintList"),
         {:ok, tags} <- optional_indexed_tags(conn, "Tags"),
         {:ok, provider} <-
           IAM.create_oidc_provider(
             url: url,
             client_ids: client_ids,
             thumbprints: thumbprints,
             tags: tags
           ) do
      Log.info("iam create-open-id-connect-provider created",
        action: :create_open_id_connect_provider,
        principal_arn: conn.assigns.principal[:arn],
        provider_arn: provider.provider_arn,
        issuer_host_path: provider.issuer_host_path,
        client_id_count: length(provider.client_ids)
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(
        200,
        QueryView.create_open_id_connect_provider_response(provider, request_id(conn))
      )
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp delete_open_id_connect_provider(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version OpenIDConnectProviderArn)),
         {:ok, provider_arn} <- open_id_connect_provider_arn(conn),
         :ok <- IAM.delete_oidc_provider(provider_arn) do
      Log.info("iam delete-open-id-connect-provider deleted",
        action: :delete_open_id_connect_provider,
        principal_arn: conn.assigns.principal[:arn],
        provider_arn: provider_arn
      )

      empty_success(conn, "DeleteOpenIDConnectProvider")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp get_open_id_connect_provider(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version OpenIDConnectProviderArn)),
         {:ok, provider_arn} <- open_id_connect_provider_arn(conn),
         {:ok, provider} <- IAM.get_oidc_provider(provider_arn) do
      Log.info("iam get-open-id-connect-provider returned",
        action: :get_open_id_connect_provider,
        principal_arn: conn.assigns.principal[:arn],
        provider_arn: provider.provider_arn
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(
        200,
        QueryView.get_open_id_connect_provider_response(provider, request_id(conn))
      )
      |> halt()
    else
      :error -> reject(conn, QueryError.new(:no_such_entity))
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp list_open_id_connect_providers(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <- reject_unsupported_params(conn, ~w(Action Version)) do
      providers = IAM.list_oidc_providers()

      Log.info("iam list-open-id-connect-providers returned",
        action: :list_open_id_connect_providers,
        principal_arn: conn.assigns.principal[:arn],
        count: length(providers)
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(
        200,
        QueryView.list_open_id_connect_providers_response(providers, request_id(conn))
      )
      |> halt()
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
    end
  end

  defp list_open_id_connect_provider_tags(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version OpenIDConnectProviderArn MaxItems Marker)
           ),
         {:ok, provider_arn} <- open_id_connect_provider_arn(conn),
         {:ok, max_items} <- max_items(conn),
         {:ok, marker_offset} <- marker_offset(conn),
         {:ok, provider} <- IAM.get_oidc_provider(provider_arn) do
      tag_page = oidc_provider_tag_page(provider, max_items, marker_offset)

      Log.info("iam list-open-id-connect-provider-tags returned",
        action: :list_open_id_connect_provider_tags,
        principal_arn: conn.assigns.principal[:arn],
        provider_arn: provider.provider_arn,
        tag_count: tag_page.tag_count,
        returned_tag_count: map_size(tag_page.tags),
        is_truncated: tag_page.is_truncated
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(
        200,
        QueryView.list_open_id_connect_provider_tags_response(tag_page, request_id(conn))
      )
      |> halt()
    else
      :error -> reject(conn, QueryError.new(:no_such_entity))
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp add_client_id_to_open_id_connect_provider(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version OpenIDConnectProviderArn ClientID)),
         {:ok, provider_arn} <- open_id_connect_provider_arn(conn),
         {:ok, client_id} <- client_id(conn),
         {:ok, provider} <- IAM.add_oidc_provider_client_id(provider_arn, client_id) do
      Log.info("iam add-client-id-to-open-id-connect-provider updated",
        action: :add_client_id_to_open_id_connect_provider,
        principal_arn: conn.assigns.principal[:arn],
        provider_arn: provider.provider_arn,
        client_id_count: length(provider.client_ids)
      )

      empty_success(conn, "AddClientIDToOpenIDConnectProvider")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp remove_client_id_from_open_id_connect_provider(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(conn, ~w(Action Version OpenIDConnectProviderArn ClientID)),
         {:ok, provider_arn} <- open_id_connect_provider_arn(conn),
         {:ok, client_id} <- client_id(conn),
         {:ok, provider} <- IAM.remove_oidc_provider_client_id(provider_arn, client_id) do
      Log.info("iam remove-client-id-from-open-id-connect-provider updated",
        action: :remove_client_id_from_open_id_connect_provider,
        principal_arn: conn.assigns.principal[:arn],
        provider_arn: provider.provider_arn,
        client_id_count: length(provider.client_ids)
      )

      empty_success(conn, "RemoveClientIDFromOpenIDConnectProvider")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp update_open_id_connect_provider_thumbprint(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version OpenIDConnectProviderArn),
             [@thumbprint_member_pattern]
           ),
         {:ok, provider_arn} <- open_id_connect_provider_arn(conn),
         {:ok, thumbprints} <- indexed_param_values(conn, "ThumbprintList", "ThumbprintList"),
         {:ok, provider} <- IAM.update_oidc_provider_thumbprints(provider_arn, thumbprints) do
      Log.info("iam update-open-id-connect-provider-thumbprint updated",
        action: :update_open_id_connect_provider_thumbprint,
        principal_arn: conn.assigns.principal[:arn],
        provider_arn: provider.provider_arn,
        thumbprint_count: length(provider.thumbprints)
      )

      empty_success(conn, "UpdateOpenIDConnectProviderThumbprint")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp tag_open_id_connect_provider(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version OpenIDConnectProviderArn),
             [@tag_member_pattern]
           ),
         {:ok, provider_arn} <- open_id_connect_provider_arn(conn),
         {:ok, tags} <- indexed_tags(conn, "Tags"),
         {:ok, provider} <- IAM.tag_oidc_provider(provider_arn, tags) do
      Log.info("iam tag-open-id-connect-provider updated",
        action: :tag_open_id_connect_provider,
        principal_arn: conn.assigns.principal[:arn],
        provider_arn: provider.provider_arn,
        tag_count: map_size(provider.tags)
      )

      empty_success(conn, "TagOpenIDConnectProvider")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp untag_open_id_connect_provider(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_root_principal(conn),
         :ok <- require_iam_signature_scope(conn),
         :ok <-
           reject_unsupported_params(
             conn,
             ~w(Action Version OpenIDConnectProviderArn),
             [@tag_key_member_pattern]
           ),
         {:ok, provider_arn} <- open_id_connect_provider_arn(conn),
         {:ok, tag_keys} <- indexed_tag_keys(conn),
         {:ok, provider} <- IAM.untag_oidc_provider(provider_arn, tag_keys) do
      Log.info("iam untag-open-id-connect-provider updated",
        action: :untag_open_id_connect_provider,
        principal_arn: conn.assigns.principal[:arn],
        provider_arn: provider.provider_arn,
        tag_count: map_size(provider.tags)
      )

      empty_success(conn, "UntagOpenIDConnectProvider")
    else
      {:error, %QueryError{} = error} -> reject(conn, error)
      {:error, reason} -> reject(conn, error_from_reason(reason))
    end
  end

  defp require_version(conn) do
    case Map.get(params(conn), "Version") do
      @version ->
        :ok

      nil ->
        {:error, QueryError.new(:invalid_parameter_value, message: "Version is required.")}

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value, message: "Version must be #{@version}.")}
    end
  end

  defp require_authenticated_principal(conn) do
    case conn.assigns[:principal] do
      :anonymous ->
        {:error, QueryError.new(:access_denied, message: "IAM requests must be signed.")}

      %{access_key: access_key} when is_binary(access_key) and access_key != "" ->
        :ok

      _other ->
        {:error, QueryError.new(:access_denied)}
    end
  end

  defp require_iam_signature_scope(conn) do
    case conn.assigns[:sigv4_signed_request] do
      %{service: "iam"} ->
        :ok

      %{service: _other} ->
        {:error,
         QueryError.new(:access_denied,
           message: "Credential scope service must be iam for IAM requests."
         )}

      _other ->
        {:error, QueryError.new(:access_denied, message: "IAM requests must be signed.")}
    end
  end

  defp require_root_principal(conn) do
    if root_principal?(conn.assigns.principal) do
      :ok
    else
      {:error,
       QueryError.new(:access_denied,
         message: "Only the root principal can manage IAM resources."
       )}
    end
  end

  defp reject_unsupported_params(conn, allowed, allowed_patterns \\ []) do
    allowed_patterns = [@sigv4_query_param_pattern | allowed_patterns]

    unsupported =
      params(conn)
      |> Map.keys()
      |> Enum.find(fn key ->
        key not in allowed and not Enum.any?(allowed_patterns, &Regex.match?(&1, key))
      end)

    if unsupported do
      {:error,
       QueryError.new(:invalid_parameter_value,
         message: "#{unsupported} is not implemented for #{action(conn)}."
       )}
    else
      :ok
    end
  end

  defp virtual_mfa_device_name(conn) do
    case Map.get(params(conn), "VirtualMFADeviceName") do
      value when is_binary(value) ->
        if Regex.match?(@virtual_mfa_device_name_pattern, value) do
          {:ok, value}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "VirtualMFADeviceName must be 1 to 128 allowed characters."
           )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value, message: "VirtualMFADeviceName is required.")}
    end
  end

  defp account_alias(conn) do
    case Map.get(params(conn), "AccountAlias") do
      value when is_binary(value) ->
        if Regex.match?(@account_alias_pattern, value) do
          {:ok, value}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "AccountAlias must be 3 to 63 lowercase letters, digits, or single dashes."
           )}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "AccountAlias is required.")}
    end
  end

  defp account_password_policy_attrs(conn) do
    with {:ok, allow_change} <-
           optional_boolean(conn, "AllowUsersToChangePassword", :allow_users_to_change_password),
         {:ok, hard_expiry} <- optional_boolean(conn, "HardExpiry", :hard_expiry),
         {:ok, require_lowercase} <-
           optional_boolean(
             conn,
             "RequireLowercaseCharacters",
             :require_lowercase_characters
           ),
         {:ok, require_numbers} <- optional_boolean(conn, "RequireNumbers", :require_numbers),
         {:ok, require_symbols} <- optional_boolean(conn, "RequireSymbols", :require_symbols),
         {:ok, require_uppercase} <-
           optional_boolean(
             conn,
             "RequireUppercaseCharacters",
             :require_uppercase_characters
           ),
         {:ok, minimum_length} <-
           optional_integer(conn, "MinimumPasswordLength", :minimum_password_length, 6, 128),
         {:ok, max_age} <- optional_integer(conn, "MaxPasswordAge", :max_password_age, 1, 1095),
         {:ok, reuse_prevention} <-
           optional_integer(
             conn,
             "PasswordReusePrevention",
             :password_reuse_prevention,
             1,
             24
           ) do
      attrs =
        %{}
        |> Map.merge(allow_change)
        |> Map.merge(hard_expiry)
        |> Map.merge(require_lowercase)
        |> Map.merge(require_numbers)
        |> Map.merge(require_symbols)
        |> Map.merge(require_uppercase)
        |> Map.merge(minimum_length)
        |> Map.merge(max_age)
        |> Map.merge(reuse_prevention)

      {:ok, attrs}
    end
  end

  defp optional_boolean(conn, param, key) do
    case Map.get(params(conn), param) do
      nil ->
        {:ok, %{}}

      "true" ->
        {:ok, %{key => true}}

      "false" ->
        {:ok, %{key => false}}

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "#{param} must be true or false."
         )}
    end
  end

  defp optional_integer(conn, param, key, min, max) do
    case Map.get(params(conn), param) do
      nil ->
        {:ok, %{}}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer >= min and integer <= max ->
            {:ok, %{key => integer}}

          _other ->
            {:error,
             QueryError.new(:invalid_parameter_value,
               message: "#{param} must be an integer from #{min} to #{max}."
             )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "#{param} must be an integer from #{min} to #{max}."
         )}
    end
  end

  defp path(conn) do
    path = Map.get(params(conn), "Path", "/")

    cond do
      is_binary(path) and byte_size(path) <= 512 and Regex.match?(@path_pattern, path) ->
        {:ok, path}

      true ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "Path must start and end with / and contain only IAM path characters."
         )}
    end
  end

  defp serial_number(conn) do
    case Map.get(params(conn), "SerialNumber") do
      value when is_binary(value) ->
        if Regex.match?(@mfa_serial_pattern, value) do
          {:ok, value}
        else
          {:error, QueryError.new(:invalid_parameter_value, message: "SerialNumber is invalid.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "SerialNumber is required.")}
    end
  end

  defp authentication_code(conn, param) do
    case Map.get(params(conn), param) do
      value when is_binary(value) ->
        if Regex.match?(@auth_code_pattern, value) do
          {:ok, value}
        else
          {:error,
           QueryError.new(:invalid_parameter_value, message: "#{param} must be a six digit code.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "#{param} is required.")}
    end
  end

  defp open_id_connect_provider_url(conn) do
    case Map.get(params(conn), "Url") do
      value when is_binary(value) ->
        value = String.trim(value)

        if value != "" do
          {:ok, value}
        else
          {:error, QueryError.new(:invalid_parameter_value, message: "Url is required.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "Url is required.")}
    end
  end

  defp open_id_connect_provider_arn(conn) do
    case Map.get(params(conn), "OpenIDConnectProviderArn") do
      value when is_binary(value) ->
        value = String.trim(value)

        if Regex.match?(@oidc_provider_arn_pattern, value) do
          {:ok, value}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "OpenIDConnectProviderArn is invalid."
           )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "OpenIDConnectProviderArn is required."
         )}
    end
  end

  defp user_name(conn) do
    case Map.get(params(conn), "UserName") do
      value when is_binary(value) ->
        if Regex.match?(@user_name_pattern, value) do
          {:ok, value}
        else
          {:error, QueryError.new(:invalid_parameter_value, message: "UserName is invalid.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "UserName is required.")}
    end
  end

  defp optional_user_name(conn) do
    case Map.get(params(conn), "UserName") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if Regex.match?(@user_name_pattern, value) do
          {:ok, value}
        else
          {:error, QueryError.new(:invalid_parameter_value, message: "UserName is invalid.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "UserName is invalid.")}
    end
  end

  defp new_user_name(conn) do
    case Map.get(params(conn), "NewUserName") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if Regex.match?(@user_name_pattern, value) do
          {:ok, value}
        else
          {:error, QueryError.new(:invalid_parameter_value, message: "NewUserName is invalid.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "NewUserName is invalid.")}
    end
  end

  defp access_key_id(conn) do
    case Map.get(params(conn), "AccessKeyId") do
      value when is_binary(value) ->
        if Regex.match?(@access_key_id_pattern, value) do
          {:ok, value}
        else
          {:error, QueryError.new(:invalid_parameter_value, message: "AccessKeyId is invalid.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "AccessKeyId is required.")}
    end
  end

  defp strict_access_key_id(conn) do
    case Map.get(params(conn), "AccessKeyId") do
      value when is_binary(value) ->
        if Regex.match?(@strict_access_key_id_pattern, value) or
             configured_root_access_key?(value) do
          {:ok, value}
        else
          {:error, QueryError.new(:invalid_parameter_value, message: "AccessKeyId is invalid.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "AccessKeyId is required.")}
    end
  end

  defp configured_root_access_key?(value) do
    case Application.get_env(:maxio, :s3, []) |> Keyword.get(:root_user) do
      root_access_key when is_binary(root_access_key) -> root_access_key == value
      _other -> false
    end
  end

  defp signing_certificate_id(conn) do
    case Map.get(params(conn), "CertificateId") do
      value when is_binary(value) ->
        if Regex.match?(@signing_certificate_id_pattern, value) do
          {:ok, value}
        else
          {:error, QueryError.new(:invalid_parameter_value, message: "CertificateId is invalid.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "CertificateId is required.")}
    end
  end

  defp ssh_public_key_id(conn) do
    case Map.get(params(conn), "SSHPublicKeyId") do
      value when is_binary(value) ->
        if Regex.match?(@ssh_public_key_id_pattern, value) do
          {:ok, value}
        else
          {:error,
           QueryError.new(:invalid_parameter_value, message: "SSHPublicKeyId is invalid.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "SSHPublicKeyId is required.")}
    end
  end

  defp access_key_status(conn) do
    case Map.get(params(conn), "Status") do
      "Active" -> {:ok, "active"}
      "Inactive" -> {:ok, "inactive"}
      "Expired" -> {:ok, "expired"}
      _other -> {:error, QueryError.new(:invalid_parameter_value, message: "Status is invalid.")}
    end
  end

  defp signing_certificate_status(conn) do
    case Map.get(params(conn), "Status") do
      status when status in ~w(Active Inactive Expired) ->
        {:ok, status}

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "Status is invalid.")}
    end
  end

  defp ssh_public_key_status(conn) do
    case Map.get(params(conn), "Status") do
      status when status in ~w(Active Inactive) ->
        {:ok, status}

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "Status is invalid.")}
    end
  end

  defp ssh_public_key_encoding(conn) do
    case Map.fetch(params(conn), "Encoding") do
      {:ok, encoding} when encoding in ~w(SSH PEM) ->
        {:ok, encoding}

      {:ok, _other} ->
        {:error, QueryError.new(:unrecognized_public_key_encoding)}

      :error ->
        {:error, QueryError.new(:invalid_parameter_value, message: "Encoding is required.")}
    end
  end

  defp group_name(conn) do
    case Map.get(params(conn), "GroupName") do
      value when is_binary(value) ->
        if Regex.match?(@group_name_pattern, value) do
          {:ok, value}
        else
          {:error, QueryError.new(:invalid_parameter_value, message: "GroupName is invalid.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "GroupName is required.")}
    end
  end

  defp new_group_name(conn) do
    case Map.get(params(conn), "NewGroupName") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if Regex.match?(@group_name_pattern, value) do
          {:ok, value}
        else
          {:error, QueryError.new(:invalid_parameter_value, message: "NewGroupName is invalid.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "NewGroupName is invalid.")}
    end
  end

  defp role_name(conn) do
    case Map.get(params(conn), "RoleName") do
      value when is_binary(value) ->
        if Regex.match?(@role_name_pattern, value) do
          {:ok, value}
        else
          {:error, QueryError.new(:invalid_parameter_value, message: "RoleName is invalid.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "RoleName is required.")}
    end
  end

  defp instance_profile_name(conn) do
    case Map.get(params(conn), "InstanceProfileName") do
      value when is_binary(value) ->
        if Regex.match?(@instance_profile_name_pattern, value) do
          {:ok, value}
        else
          {:error,
           QueryError.new(:invalid_parameter_value, message: "InstanceProfileName is invalid.")}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value, message: "InstanceProfileName is required.")}
    end
  end

  defp server_certificate_name(conn) do
    case Map.get(params(conn), "ServerCertificateName") do
      value when is_binary(value) ->
        if Regex.match?(@server_certificate_name_pattern, value) do
          {:ok, value}
        else
          {:error,
           QueryError.new(:invalid_parameter_value, message: "ServerCertificateName is invalid.")}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "ServerCertificateName is required."
         )}
    end
  end

  defp new_server_certificate_name(conn) do
    case Map.get(params(conn), "NewServerCertificateName") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if Regex.match?(@server_certificate_name_pattern, value) do
          {:ok, value}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "NewServerCertificateName is invalid."
           )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "NewServerCertificateName is invalid."
         )}
    end
  end

  defp policy_name(conn) do
    case Map.get(params(conn), "PolicyName") do
      value when is_binary(value) ->
        if Regex.match?(@policy_name_pattern, value) do
          {:ok, value}
        else
          {:error, QueryError.new(:invalid_parameter_value, message: "PolicyName is invalid.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "PolicyName is required.")}
    end
  end

  defp policy_document(conn) do
    case Map.fetch(params(conn), "PolicyDocument") do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "PolicyDocument is required.")}
    end
  end

  defp certificate_body(conn) do
    required_binary_param(conn, "CertificateBody")
  end

  defp ssh_public_key_body(conn) do
    required_binary_param(conn, "SSHPublicKeyBody")
  end

  defp private_key(conn) do
    required_binary_param(conn, "PrivateKey")
  end

  defp certificate_chain(conn) do
    case Map.get(params(conn), "CertificateChain") do
      nil ->
        {:ok, nil}

      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value, message: "CertificateChain is invalid.")}
    end
  end

  defp required_binary_param(conn, param) do
    case Map.fetch(params(conn), param) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "#{param} is required.")}
    end
  end

  defp trust_policy_document(conn) do
    case Map.fetch(params(conn), "PolicyDocument") do
      {:ok, value} when is_binary(value) ->
        validate_trust_policy_document("PolicyDocument", value)

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "PolicyDocument is required.")}
    end
  end

  defp assume_role_policy_document(conn) do
    case Map.fetch(params(conn), "AssumeRolePolicyDocument") do
      {:ok, value} when is_binary(value) ->
        validate_trust_policy_document("AssumeRolePolicyDocument", value)

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "AssumeRolePolicyDocument is required."
         )}
    end
  end

  defp validate_trust_policy_document(param, value) do
    cond do
      String.length(value) < 1 or String.length(value) > @trust_policy_document_max_chars ->
        {:error,
         QueryError.new(:malformed_policy_document,
           message: "#{param} must be 1 to #{@trust_policy_document_max_chars} characters."
         )}

      not iam_policy_document_chars?(value) ->
        {:error,
         QueryError.new(:malformed_policy_document,
           message: "#{param} contains characters outside the IAM policy document range."
         )}

      true ->
        {:ok, value}
    end
  end

  defp role_description(conn) do
    case optional_role_description(conn) do
      {:ok, nil} -> {:ok, ""}
      result -> result
    end
  end

  defp optional_role_description(conn) do
    case Map.get(params(conn), "Description") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        validate_role_description(value)

      _other ->
        invalid_role_description()
    end
  end

  defp validate_role_description(value) do
    cond do
      String.length(value) > @role_description_max_chars ->
        invalid_role_description()

      not role_description_chars?(value) ->
        invalid_role_description()

      true ->
        {:ok, value}
    end
  end

  defp invalid_role_description do
    {:error,
     QueryError.new(:invalid_parameter_value,
       message:
         "Description must be 0 to #{@role_description_max_chars} IAM description characters."
     )}
  end

  defp iam_policy_document_chars?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(fn char ->
      char in [0x09, 0x0A, 0x0D] or (char >= 0x20 and char <= 0xFF)
    end)
  end

  defp role_description_chars?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(fn char ->
      char in [0x09, 0x0A, 0x0D] or
        (char >= 0x20 and char <= 0x7E) or
        (char >= 0xA1 and char <= 0xFF)
    end)
  end

  defp max_session_duration(conn) do
    case Map.get(params(conn), "MaxSessionDuration") do
      nil ->
        {:ok, 3600}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {duration, ""} when duration >= 3600 and duration <= 43_200 ->
            {:ok, duration}

          _other ->
            {:error,
             QueryError.new(:invalid_parameter_value,
               message: "MaxSessionDuration must be an integer from 3600 to 43200."
             )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "MaxSessionDuration must be an integer from 3600 to 43200."
         )}
    end
  end

  defp optional_max_session_duration(conn) do
    case Map.get(params(conn), "MaxSessionDuration") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        parse_max_session_duration(value)

      _other ->
        invalid_max_session_duration()
    end
  end

  defp parse_max_session_duration(value) do
    case Integer.parse(value) do
      {duration, ""} when duration >= 3600 and duration <= 43_200 ->
        {:ok, duration}

      _other ->
        invalid_max_session_duration()
    end
  end

  defp invalid_max_session_duration do
    {:error,
     QueryError.new(:invalid_parameter_value,
       message: "MaxSessionDuration must be an integer from 3600 to 43200."
     )}
  end

  defp managed_policy_arn(conn) do
    case Map.get(params(conn), "PolicyArn") do
      value when is_binary(value) ->
        case IAM.validate_managed_policy_arn(value) do
          :ok ->
            {:ok, value}

          {:error, _reason} ->
            {:error, QueryError.new(:invalid_parameter_value, message: "PolicyArn is invalid.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "PolicyArn is required.")}
    end
  end

  defp optional_permissions_boundary_policy_arn(conn) do
    case Map.get(params(conn), "PermissionsBoundary") do
      nil -> {:ok, nil}
      _value -> permissions_boundary_policy_arn(conn)
    end
  end

  defp permissions_boundary_policy_arn(conn) do
    case Map.get(params(conn), "PermissionsBoundary") do
      value when is_binary(value) ->
        case IAM.validate_managed_policy_arn(value) do
          :ok ->
            {:ok, value}

          {:error, _reason} ->
            {:error,
             QueryError.new(:invalid_parameter_value, message: "PermissionsBoundary is invalid.")}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value, message: "PermissionsBoundary is required.")}
    end
  end

  defp managed_policy_path(conn) do
    path = Map.get(params(conn), "Path", "/")

    if valid_managed_policy_path?(path) do
      {:ok, path}
    else
      {:error,
       QueryError.new(:invalid_parameter_value,
         message:
           "Path must start and end with / and contain only managed policy path characters."
       )}
    end
  end

  defp policy_description(conn) do
    case Map.get(params(conn), "Description", "") do
      value when is_binary(value) ->
        if String.length(value) <= 1000 do
          {:ok, value}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "Description must be a string of at most 1000 characters."
           )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "Description must be a string of at most 1000 characters."
         )}
    end
  end

  defp policy_version_id(conn) do
    case Map.get(params(conn), "VersionId") do
      value when is_binary(value) ->
        if Regex.match?(@policy_version_id_pattern, value) do
          {:ok, value}
        else
          {:error, QueryError.new(:invalid_parameter_value, message: "VersionId is invalid.")}
        end

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "VersionId is required.")}
    end
  end

  defp set_as_default(conn) do
    case Map.get(params(conn), "SetAsDefault", "false") do
      "true" ->
        {:ok, true}

      "false" ->
        {:ok, false}

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "SetAsDefault is invalid.")}
    end
  end

  defp list_policy_scope(conn) do
    case Map.get(params(conn), "Scope", "All") do
      value when value in ["All", "AWS", "Local"] ->
        {:ok, value}

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "Scope is invalid.")}
    end
  end

  defp only_attached(conn) do
    case Map.get(params(conn), "OnlyAttached", "false") do
      "true" ->
        {:ok, true}

      "false" ->
        {:ok, false}

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "OnlyAttached is invalid.")}
    end
  end

  defp policy_usage_filter(conn) do
    case Map.get(params(conn), "PolicyUsageFilter", "PermissionsPolicy") do
      value when value in ["PermissionsPolicy", "PermissionsBoundary"] ->
        {:ok, value}

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value, message: "PolicyUsageFilter is invalid.")}
    end
  end

  defp policy_entity_filter(conn) do
    case Map.get(params(conn), "EntityFilter", "All") do
      value
      when value in ["All", "User", "Role", "Group", "LocalManagedPolicy", "AWSManagedPolicy"] ->
        {:ok, value}

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "EntityFilter is invalid.")}
    end
  end

  defp root_user_path(conn) do
    case Map.get(params(conn), "Path", "/") do
      path when is_binary(path) and path == "/" ->
        {:ok, path}

      path when is_binary(path) ->
        if valid_iam_path?(path) do
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "Only the root IAM user path / is supported."
           )}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "Path must start and end with / and contain only IAM path characters."
           )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "Path must start and end with / and contain only IAM path characters."
         )}
    end
  end

  defp root_group_path(conn) do
    case Map.get(params(conn), "Path", "/") do
      path when is_binary(path) and path == "/" ->
        {:ok, path}

      path when is_binary(path) ->
        if valid_iam_path?(path) do
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "Only the root IAM group path / is supported."
           )}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "Path must start and end with / and contain only IAM path characters."
           )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "Path must start and end with / and contain only IAM path characters."
         )}
    end
  end

  defp root_new_user_path(conn) do
    root_new_path(conn, "user")
  end

  defp root_new_group_path(conn) do
    root_new_path(conn, "group")
  end

  defp root_new_path(conn, kind) do
    case Map.get(params(conn), "NewPath", "/") do
      path when is_binary(path) and path == "/" ->
        {:ok, path}

      path when is_binary(path) ->
        if valid_iam_path?(path) do
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "Only the root IAM #{kind} path / is supported."
           )}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "NewPath must start and end with / and contain only IAM path characters."
           )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "NewPath must start and end with / and contain only IAM path characters."
         )}
    end
  end

  defp root_role_path(conn) do
    case Map.get(params(conn), "Path", "/") do
      path when is_binary(path) and path == "/" ->
        {:ok, path}

      path when is_binary(path) ->
        if valid_iam_path?(path) do
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "Only the root IAM role path / is supported."
           )}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "Path must start and end with / and contain only IAM path characters."
           )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "Path must start and end with / and contain only IAM path characters."
         )}
    end
  end

  defp instance_profile_path(conn) do
    case Map.get(params(conn), "Path", "/") do
      path when is_binary(path) ->
        if valid_iam_path?(path) do
          {:ok, path}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "Path must start and end with / and contain only IAM path characters."
           )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "Path must start and end with / and contain only IAM path characters."
         )}
    end
  end

  defp server_certificate_path(conn), do: instance_profile_path(conn)

  defp server_certificate_new_path(conn) do
    case Map.get(params(conn), "NewPath") do
      nil ->
        {:ok, nil}

      path when is_binary(path) ->
        if valid_iam_path?(path) do
          {:ok, path}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "NewPath must start and end with / and contain only IAM path characters."
           )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "NewPath must start and end with / and contain only IAM path characters."
         )}
    end
  end

  defp root_user_path_prefix(conn) do
    case Map.get(params(conn), "PathPrefix", "/") do
      path_prefix when is_binary(path_prefix) and path_prefix == "/" ->
        {:ok, path_prefix}

      path_prefix when is_binary(path_prefix) ->
        if valid_iam_path?(path_prefix) do
          {:ok, path_prefix}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "PathPrefix must start and end with / and contain only IAM path characters."
           )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "PathPrefix must start and end with / and contain only IAM path characters."
         )}
    end
  end

  defp root_group_path_prefix(conn) do
    case Map.get(params(conn), "PathPrefix", "/") do
      path_prefix when is_binary(path_prefix) and path_prefix == "/" ->
        {:ok, path_prefix}

      path_prefix when is_binary(path_prefix) ->
        if valid_iam_path?(path_prefix) do
          {:ok, path_prefix}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "PathPrefix must start and end with / and contain only IAM path characters."
           )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "PathPrefix must start and end with / and contain only IAM path characters."
         )}
    end
  end

  defp root_role_path_prefix(conn) do
    case Map.get(params(conn), "PathPrefix", "/") do
      path_prefix when is_binary(path_prefix) and path_prefix == "/" ->
        {:ok, path_prefix}

      path_prefix when is_binary(path_prefix) ->
        if valid_iam_path?(path_prefix) do
          {:ok, path_prefix}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "PathPrefix must start and end with / and contain only IAM path characters."
           )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "PathPrefix must start and end with / and contain only IAM path characters."
         )}
    end
  end

  defp instance_profile_path_prefix(conn) do
    case Map.get(params(conn), "PathPrefix", "/") do
      path_prefix when is_binary(path_prefix) ->
        if valid_iam_path_prefix?(path_prefix) do
          {:ok, path_prefix}
        else
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "PathPrefix must start and end with / and contain only IAM path characters."
           )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "PathPrefix must start and end with / and contain only IAM path characters."
         )}
    end
  end

  defp server_certificate_path_prefix(conn), do: instance_profile_path_prefix(conn)

  defp managed_policy_path_prefix(conn) do
    path_prefix = Map.get(params(conn), "PathPrefix", "/")

    if valid_managed_policy_path?(path_prefix) do
      {:ok, path_prefix}
    else
      {:error,
       QueryError.new(:invalid_parameter_value,
         message:
           "PathPrefix must start and end with / and contain only managed policy path characters."
       )}
    end
  end

  defp valid_iam_path?(path) when is_binary(path) do
    byte_size(path) <= 512 and Regex.match?(@path_pattern, path)
  end

  defp valid_iam_path_prefix?(path_prefix) when is_binary(path_prefix) do
    byte_size(path_prefix) <= 512 and Regex.match?(@path_prefix_pattern, path_prefix)
  end

  defp valid_managed_policy_path?("/"), do: true

  defp valid_managed_policy_path?(path) when is_binary(path) do
    byte_size(path) <= 512 and
      String.starts_with?(path, "/") and
      String.ends_with?(path, "/") and
      not String.contains?(path, "//") and
      path
      |> String.split("/", trim: true)
      |> Enum.all?(&Regex.match?(@managed_policy_path_segment_pattern, &1))
  end

  defp valid_managed_policy_path?(_path), do: false

  defp policy_entity_path_prefix(conn) do
    path_prefix = Map.get(params(conn), "PathPrefix", "/")

    if valid_iam_entity_path_prefix?(path_prefix) do
      {:ok, path_prefix}
    else
      {:error,
       QueryError.new(:invalid_parameter_value,
         message:
           "PathPrefix must start and end with / and contain only IAM entity path characters."
       )}
    end
  end

  defp valid_iam_entity_path_prefix?(path_prefix) when is_binary(path_prefix) do
    byte_size(path_prefix) <= 512 and
      String.starts_with?(path_prefix, "/") and
      String.ends_with?(path_prefix, "/") and
      path_prefix
      |> String.to_charlist()
      |> Enum.all?(fn char -> char >= 0x21 and char <= 0x7E end)
  end

  defp valid_iam_entity_path_prefix?(_path_prefix), do: false

  defp client_id(conn) do
    case Map.get(params(conn), "ClientID") do
      value when is_binary(value) ->
        validate_client_id(String.trim(value), "ClientID")

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "ClientID is required.")}
    end
  end

  defp max_items(conn) do
    case Map.get(params(conn), "MaxItems") do
      nil ->
        {:ok, 100}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {max_items, ""} when max_items >= 1 and max_items <= 1000 ->
            {:ok, max_items}

          _other ->
            {:error,
             QueryError.new(:invalid_parameter_value,
               message: "MaxItems must be an integer from 1 to 1000."
             )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "MaxItems must be an integer from 1 to 1000."
         )}
    end
  end

  defp marker_offset(conn) do
    case Map.get(params(conn), "Marker") do
      nil ->
        {:ok, 0}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {offset, ""} when offset >= 0 ->
            {:ok, offset}

          _other ->
            {:error,
             QueryError.new(:invalid_parameter_value,
               message: "Marker is invalid for this IAM listing."
             )}
        end

      _other ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "Marker is invalid for this IAM listing."
         )}
    end
  end

  defp oidc_provider_tag_page(provider, max_items, marker_offset) do
    tag_page(provider.tags || %{}, max_items, marker_offset)
    |> Map.put(:provider_arn, provider.provider_arn)
  end

  defp account_alias_page(account_aliases, max_items, marker_offset) do
    page = Enum.slice(account_aliases, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(account_aliases)

    %{
      account_aliases: page,
      alias_count: length(account_aliases),
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp server_certificate_update_params(new_name, new_path) do
    %{}
    |> maybe_put_param(:server_certificate_name, new_name)
    |> maybe_put_param(:path, new_path)
  end

  defp maybe_put_param(acc, _key, nil), do: acc
  defp maybe_put_param(acc, key, value), do: Map.put(acc, key, value)

  defp tag_page(tags, max_items, marker_offset) do
    tags = Tags.map_to_list(tags || %{})
    page = Enum.slice(tags, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(tags)

    %{
      tags: Tags.list_to_map(page),
      tag_count: length(tags),
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp access_key_page(access_keys, requested_user_name, max_items, marker_offset) do
    access_keys =
      Enum.sort_by(access_keys, &{&1.inserted_at || DateTime.from_unix!(0), &1.access_key_id})

    page = Enum.slice(access_keys, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(access_keys)

    %{
      access_keys: page,
      access_key_count: length(access_keys),
      user_name: access_key_page_user_name(requested_user_name, access_keys, page),
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp access_key_page_user_name(user_name, _access_keys, _page)
       when is_binary(user_name) and user_name != "",
       do: user_name

  defp access_key_page_user_name(_user_name, [key | _rest], _page), do: key.user_name
  defp access_key_page_user_name(_user_name, [], [key | _rest]), do: key.user_name
  defp access_key_page_user_name(_user_name, [], []), do: nil

  defp signing_certificate_page(certificates, requested_user_name, max_items, marker_offset) do
    certificates =
      Enum.sort_by(certificates, &{&1.inserted_at || DateTime.from_unix!(0), &1.certificate_id})

    page = Enum.slice(certificates, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(certificates)

    %{
      certificates: page,
      signing_certificate_count: length(certificates),
      user_name: signing_certificate_page_user_name(requested_user_name, certificates, page),
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp signing_certificate_page_user_name(user_name, _certificates, _page)
       when is_binary(user_name) and user_name != "",
       do: user_name

  defp signing_certificate_page_user_name(_user_name, [certificate | _rest], _page),
    do: certificate.user_name

  defp signing_certificate_page_user_name(_user_name, [], [certificate | _rest]),
    do: certificate.user_name

  defp signing_certificate_page_user_name(_user_name, [], []), do: nil

  defp ssh_public_key_page(ssh_public_keys, requested_user_name, max_items, marker_offset) do
    ssh_public_keys =
      Enum.sort_by(
        ssh_public_keys,
        &{&1.inserted_at || DateTime.from_unix!(0), &1.ssh_public_key_id}
      )

    page = Enum.slice(ssh_public_keys, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(ssh_public_keys)

    %{
      ssh_public_keys: page,
      ssh_public_key_count: length(ssh_public_keys),
      user_name: requested_user_name,
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp user_page(users, "/", max_items, marker_offset) do
    users = Enum.sort_by(users, & &1.user_name)
    page = Enum.slice(users, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(users)

    %{
      users: page,
      user_count: length(users),
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp user_page(_users, _path_prefix, _max_items, _marker_offset) do
    %{users: [], user_count: 0, is_truncated: false, marker: nil}
  end

  defp group_page(groups, "/", max_items, marker_offset) do
    groups = Enum.sort_by(groups, & &1.group_name)
    page = Enum.slice(groups, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(groups)

    %{
      groups: page,
      group_count: length(groups),
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp group_page(_groups, _path_prefix, _max_items, _marker_offset) do
    %{groups: [], group_count: 0, is_truncated: false, marker: nil}
  end

  defp role_page(roles, "/", max_items, marker_offset) do
    roles = Enum.sort_by(roles, & &1.role_name)
    page = Enum.slice(roles, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(roles)

    %{
      roles: page,
      role_count: length(roles),
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp role_page(_roles, _path_prefix, _max_items, _marker_offset) do
    %{roles: [], role_count: 0, is_truncated: false, marker: nil}
  end

  defp instance_profile_page(instance_profiles, path_prefix, max_items, marker_offset) do
    instance_profiles =
      instance_profiles
      |> Enum.filter(fn profile ->
        profile
        |> Map.get(:path, "/")
        |> Kernel.||("/")
        |> String.starts_with?(path_prefix)
      end)
      |> Enum.sort_by(fn profile ->
        {Map.get(profile, :path, "/") || "/", Map.get(profile, :instance_profile_name, "")}
      end)

    page = Enum.slice(instance_profiles, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(instance_profiles)

    %{
      instance_profiles: page,
      instance_profile_count: length(instance_profiles),
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp server_certificate_page(server_certificates, path_prefix, max_items, marker_offset) do
    server_certificates =
      server_certificates
      |> Enum.filter(fn certificate ->
        certificate
        |> Map.get(:path, "/")
        |> Kernel.||("/")
        |> String.starts_with?(path_prefix)
      end)
      |> Enum.sort_by(fn certificate ->
        {
          Map.get(certificate, :path, "/") || "/",
          Map.get(certificate, :server_certificate_name, "")
        }
      end)

    page = Enum.slice(server_certificates, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(server_certificates)

    %{
      server_certificates: page,
      server_certificate_count: length(server_certificates),
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp policy_page(policies, max_items, marker_offset) do
    policy_names =
      policies
      |> Enum.map(fn policy ->
        Map.get(policy, :policy_name) || Map.get(policy, "policy_name")
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.sort()

    page = Enum.slice(policy_names, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(policy_names)

    %{
      policy_names: page,
      policy_count: length(policy_names),
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp attached_policy_page(policies, max_items, marker_offset) do
    policies = Enum.sort_by(policies, &{&1.policy_name, &1.policy_arn})
    page = Enum.slice(policies, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(policies)

    %{
      policies: page,
      policy_count: length(policies),
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp managed_policy_page(policies, max_items, marker_offset) do
    policies = Enum.sort_by(policies, &{&1.path, &1.policy_name, &1.policy_arn})
    page = Enum.slice(policies, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(policies)

    %{
      policies: page,
      policy_count: length(policies),
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp policy_version_page(policy_arn, versions, max_items, marker_offset) do
    versions = Enum.sort_by(versions, &policy_version_sort_key/1)

    page = Enum.slice(versions, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(versions)

    %{
      policy_arn: policy_arn,
      versions: page,
      version_count: length(versions),
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp policy_version_sort_key(%{version_id: "v" <> number}) do
    case Integer.parse(number) do
      {parsed, _suffix} -> parsed
      :error -> 0
    end
  end

  defp policy_version_sort_key(_version), do: 0

  defp policy_entities_page(entities, max_items, marker_offset) do
    entries =
      Enum.map(Map.get(entities, :groups, []), &{:group, &1}) ++
        Enum.map(Map.get(entities, :users, []), &{:user, &1}) ++
        Enum.map(Map.get(entities, :roles, []), &{:role, &1})

    page = Enum.slice(entries, marker_offset, max_items)
    next_offset = marker_offset + length(page)
    is_truncated = next_offset < length(entries)

    %{
      groups: for({:group, group} <- page, do: group),
      users: for({:user, user} <- page, do: user),
      roles: for({:role, role} <- page, do: role),
      entity_count: length(entries),
      is_truncated: is_truncated,
      marker: if(is_truncated, do: Integer.to_string(next_offset), else: nil)
    }
  end

  defp indexed_param_values(conn, prefix, label) do
    entries =
      params(conn)
      |> Enum.flat_map(fn {key, value} ->
        case Regex.run(~r/\A#{Regex.escape(prefix)}\.member\.([1-9]\d*)\z/, key) do
          [_full, index] -> [{String.to_integer(index), value}]
          _other -> []
        end
      end)
      |> Enum.sort_by(&elem(&1, 0))

    cond do
      entries == [] ->
        {:error,
         QueryError.new(:invalid_parameter_value, message: "#{label}.member.1 is required.")}

      Enum.map(entries, &elem(&1, 0)) != Enum.to_list(1..length(entries)) ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "#{label} members must be indexed contiguously from 1."
         )}

      true ->
        values = Enum.map(entries, &elem(&1, 1))
        validate_indexed_values(values, label)
    end
  end

  defp optional_indexed_param_values(conn, prefix, label) do
    case indexed_param_values(conn, prefix, label) do
      {:ok, values} ->
        {:ok, values}

      {:error, %QueryError{message: message} = error} ->
        if message == "#{label}.member.1 is required." do
          {:ok, []}
        else
          {:error, error}
        end
    end
  end

  defp indexed_tags(conn, prefix) do
    entries =
      params(conn)
      |> Enum.flat_map(fn {key, value} ->
        case Regex.run(~r/\A#{Regex.escape(prefix)}\.member\.([1-9]\d*)\.(Key|Value)\z/, key) do
          [_full, index, field] -> [{String.to_integer(index), field, value}]
          _other -> []
        end
      end)

    tag_indexes = entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

    cond do
      tag_indexes == [] ->
        {:error,
         QueryError.new(:invalid_parameter_value, message: "#{prefix}.member.1 is required.")}

      tag_indexes != Enum.to_list(1..length(tag_indexes)) ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "#{prefix} members must be indexed contiguously from 1."
         )}

      true ->
        entries
        |> Enum.reduce(%{}, fn {index, field, value}, acc ->
          update_in(acc[index], fn tag -> Map.put(tag || %{}, field, value) end)
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))
        |> validate_tags(prefix)
    end
  end

  defp optional_indexed_tags(conn, prefix) do
    case indexed_tags(conn, prefix) do
      {:ok, tags} ->
        {:ok, tags}

      {:error, %QueryError{message: message} = error} ->
        if message == "#{prefix}.member.1 is required." do
          {:ok, %{}}
        else
          {:error, error}
        end
    end
  end

  defp optional_case_sensitive_indexed_tags(conn, prefix) do
    case case_sensitive_indexed_tags(conn, prefix) do
      {:ok, tags} ->
        {:ok, tags}

      {:error, %QueryError{message: message} = error} ->
        if message == "#{prefix}.member.1 is required." do
          {:ok, %{}}
        else
          {:error, error}
        end
    end
  end

  defp case_sensitive_indexed_tags(conn, prefix) do
    entries =
      params(conn)
      |> Enum.flat_map(fn {key, value} ->
        case Regex.run(~r/\A#{Regex.escape(prefix)}\.member\.([1-9]\d*)\.(Key|Value)\z/, key) do
          [_full, index, field] -> [{String.to_integer(index), field, value}]
          _other -> []
        end
      end)

    tag_indexes = entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

    cond do
      tag_indexes == [] ->
        {:error,
         QueryError.new(:invalid_parameter_value, message: "#{prefix}.member.1 is required.")}

      tag_indexes != Enum.to_list(1..length(tag_indexes)) ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "#{prefix} members must be indexed contiguously from 1."
         )}

      true ->
        entries
        |> Enum.reduce(%{}, fn {index, field, value}, acc ->
          update_in(acc[index], fn tag -> Map.put(tag || %{}, field, value) end)
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))
        |> validate_case_sensitive_tags(prefix)
    end
  end

  defp indexed_tag_keys(conn) do
    case indexed_param_values(conn, "TagKeys", "TagKeys") do
      {:ok, values} -> validate_tag_keys(values, "TagKeys")
      {:error, error} -> {:error, error}
    end
  end

  defp indexed_case_sensitive_tag_keys(conn) do
    case indexed_param_values(conn, "TagKeys", "TagKeys") do
      {:ok, values} -> validate_case_sensitive_tag_keys(values, "TagKeys")
      {:error, error} -> {:error, error}
    end
  end

  defp validate_indexed_values(values, "ClientIDList") do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> then(fn client_ids ->
      cond do
        length(client_ids) > 100 ->
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "ClientIDList can contain at most 100 values."
           )}

        length(Enum.uniq(client_ids)) != length(client_ids) ->
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "ClientIDList must not contain duplicate values."
           )}

        true ->
          Enum.reduce_while(client_ids, {:ok, client_ids}, fn client_id, acc ->
            case validate_client_id(client_id, "ClientIDList") do
              {:ok, _client_id} -> {:cont, acc}
              {:error, error} -> {:halt, {:error, error}}
            end
          end)
      end
    end)
  end

  defp validate_indexed_values(values, "ThumbprintList") do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> then(fn thumbprints ->
      cond do
        length(thumbprints) > 5 ->
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "ThumbprintList can contain at most 5 values."
           )}

        length(Enum.uniq(Enum.map(thumbprints, &String.downcase/1))) != length(thumbprints) ->
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "ThumbprintList must not contain duplicate values."
           )}

        true ->
          Enum.reduce_while(thumbprints, {:ok, thumbprints}, fn thumbprint, acc ->
            case validate_thumbprint(thumbprint) do
              :ok -> {:cont, acc}
              {:error, error} -> {:halt, {:error, error}}
            end
          end)
      end
    end)
  end

  defp validate_indexed_values(values, "TagKeys"), do: {:ok, values}

  defp validate_tags(tags, label) do
    cond do
      length(tags) > 50 ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "#{label} can contain at most 50 values."
         )}

      true ->
        case Enum.reduce_while(tags, {:ok, []}, fn tag, {:ok, acc} ->
               with {:ok, key} <- tag_member(tag, "Key", label),
                    {:ok, value} <- tag_member(tag, "Value", label) do
                 {:cont, {:ok, [{key, value} | acc]}}
               else
                 {:error, error} -> {:halt, {:error, error}}
               end
             end) do
          {:ok, tag_pairs} ->
            tag_pairs = Enum.reverse(tag_pairs)

            cond do
              case_insensitive_duplicate_tag_keys?(tag_pairs) ->
                {:error,
                 QueryError.new(:invalid_parameter_value,
                   message: "#{label} must not contain duplicate tag keys."
                 )}

              Tags.validate(tag_pairs, :bucket) == :ok ->
                {:ok, Tags.list_to_map(tag_pairs)}

              true ->
                {:error,
                 QueryError.new(:invalid_parameter_value,
                   message: "#{label} must contain valid tag keys and values."
                 )}
            end

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp validate_case_sensitive_tags(tags, label) do
    cond do
      length(tags) > 50 ->
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "#{label} can contain at most 50 values."
         )}

      true ->
        case Enum.reduce_while(tags, {:ok, []}, fn tag, {:ok, acc} ->
               with {:ok, key} <- tag_member(tag, "Key", label),
                    {:ok, value} <- tag_member(tag, "Value", label) do
                 {:cont, {:ok, [{key, value} | acc]}}
               else
                 {:error, error} -> {:halt, {:error, error}}
               end
             end) do
          {:ok, tag_pairs} ->
            tag_pairs = Enum.reverse(tag_pairs)

            if Tags.validate(tag_pairs, :bucket) == :ok do
              {:ok, Tags.list_to_map(tag_pairs)}
            else
              {:error,
               QueryError.new(:invalid_parameter_value,
                 message: "#{label} must contain valid tag keys and values."
               )}
            end

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp validate_tag_keys(values, label) do
    values
    |> Enum.map(&to_string/1)
    |> then(fn tag_keys ->
      cond do
        length(tag_keys) > 50 ->
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "#{label} can contain at most 50 values."
           )}

        true ->
          tag_pairs = Enum.map(tag_keys, &{&1, ""})

          cond do
            case_insensitive_duplicate_tag_keys?(tag_pairs) ->
              {:error,
               QueryError.new(:invalid_parameter_value,
                 message: "#{label} must not contain duplicate tag keys."
               )}

            Tags.validate(tag_pairs, :bucket) == :ok ->
              {:ok, tag_keys}

            true ->
              {:error,
               QueryError.new(:invalid_parameter_value,
                 message: "#{label} must contain valid tag keys."
               )}
          end
      end
    end)
  end

  defp validate_case_sensitive_tag_keys(values, label) do
    values
    |> Enum.map(&to_string/1)
    |> then(fn tag_keys ->
      cond do
        length(tag_keys) > 50 ->
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "#{label} can contain at most 50 values."
           )}

        true ->
          tag_pairs = Enum.map(tag_keys, &{&1, ""})

          if Tags.validate(tag_pairs, :bucket) == :ok do
            {:ok, tag_keys}
          else
            {:error,
             QueryError.new(:invalid_parameter_value,
               message: "#{label} must contain valid tag keys."
             )}
          end
      end
    end)
  end

  defp tag_member(%{"Key" => key}, "Key", _label), do: {:ok, to_string(key)}
  defp tag_member(%{"Value" => value}, "Value", _label), do: {:ok, to_string(value)}

  defp tag_member(_tag, field, label) do
    {:error,
     QueryError.new(:invalid_parameter_value, message: "#{label}.member.N.#{field} is required.")}
  end

  defp case_insensitive_duplicate_tag_keys?(tag_pairs) do
    keys = Enum.map(tag_pairs, fn {key, _value} -> String.downcase(key) end)
    length(Enum.uniq(keys)) != length(keys)
  end

  defp validate_client_id(value, label) do
    if is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= 255 do
      {:ok, value}
    else
      {:error,
       QueryError.new(:invalid_parameter_value,
         message: "#{label} must be a non-empty string of at most 255 bytes."
       )}
    end
  end

  defp validate_thumbprint(value) do
    if is_binary(value) and Regex.match?(@thumbprint_pattern, value) do
      :ok
    else
      {:error,
       QueryError.new(:invalid_parameter_value,
         message: "ThumbprintList values must be 40-character SHA1 hex strings."
       )}
    end
  end

  defp caller_owned_mfa_principal(conn) do
    principal = conn.assigns.principal

    cond do
      root_principal?(principal) ->
        {:ok, IAM.root_principal_arn()}

      iam_user_principal?(principal) ->
        {:ok, principal.arn}

      true ->
        {:error,
         QueryError.new(:access_denied, message: "IAM principal cannot manage MFA devices.")}
    end
  end

  defp required_user_principal_arn(conn) do
    case Map.get(params(conn), "UserName") do
      value when is_binary(value) and value != "" ->
        user_principal_arn(conn, value)

      _other ->
        {:error, QueryError.new(:invalid_parameter_value, message: "UserName is required.")}
    end
  end

  defp optional_user_principal_arn(conn) do
    case Map.get(params(conn), "UserName") do
      nil -> caller_owned_mfa_principal(conn)
      "" -> {:error, QueryError.new(:invalid_parameter_value, message: "UserName is invalid.")}
      value -> user_principal_arn(conn, value)
    end
  end

  defp user_principal_arn(conn, "root") do
    if root_principal?(conn.assigns.principal) do
      {:ok, IAM.root_principal_arn()}
    else
      {:error, QueryError.new(:access_denied, message: "Caller cannot manage another principal.")}
    end
  end

  defp user_principal_arn(conn, user_name) when is_binary(user_name) do
    principal = conn.assigns.principal

    cond do
      not valid_user_name?(user_name) ->
        {:error, QueryError.new(:invalid_parameter_value, message: "UserName is invalid.")}

      root_principal?(principal) ->
        case IAM.get_user(user_name) do
          {:ok, user} -> {:ok, user.user_arn}
          :error -> {:error, QueryError.new(:no_such_entity, message: "UserName does not exist.")}
        end

      iam_user_principal?(principal) and user_matches_principal?(user_name, principal.arn) ->
        {:ok, principal.arn}

      true ->
        {:error,
         QueryError.new(:access_denied, message: "Caller cannot manage another principal.")}
    end
  end

  defp fetch_owned_mfa_device(serial, target_arn) do
    case IAM.get_mfa_device(serial) do
      {:ok, %{principal_arn: ^target_arn} = device} ->
        {:ok, device}

      {:ok, _device} ->
        {:error,
         QueryError.new(:no_such_entity, message: "MFA device is not assigned to UserName.")}

      :error ->
        {:error, QueryError.new(:no_such_entity, message: "MFA device does not exist.")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_manageable_mfa_device(conn, serial) do
    case IAM.get_mfa_device(serial) do
      {:ok, device} ->
        if root_principal?(conn.assigns.principal) or
             (iam_user_principal?(conn.assigns.principal) and
                device.principal_arn == conn.assigns.principal.arn) do
          {:ok, device}
        else
          {:error,
           QueryError.new(:access_denied, message: "Caller cannot manage another principal.")}
        end

      :error ->
        {:error, QueryError.new(:no_such_entity, message: "MFA device does not exist.")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_post_form(conn) do
    with :ok <- require_header_auth(conn),
         :ok <- verify_form_content_type(conn),
         {:ok, conn, body} <- read_form_body(conn),
         :ok <- verify_payload_hash(conn, body),
         {:ok, form_params} <- decode_form_params(body) do
      {:ok, assign(conn, :iam_params, form_params)}
    end
  end

  defp verify_get_query_params(conn) do
    try do
      pairs = URI.query_decoder(conn.query_string || "") |> Enum.to_list()

      cond do
        duplicate_keys?(pairs) ->
          {:error,
           QueryError.new(:invalid_parameter_value,
             message: "IAM query parameters must not be repeated."
           )}

        action(conn) in @post_only_actions ->
          {:error,
           QueryError.new(:invalid_request,
             message: "#{action(conn)} requires a signed POST form request."
           )}

        true ->
          :ok
      end
    rescue
      ArgumentError ->
        {:error, QueryError.new(:invalid_parameter_value, message: "Invalid query encoding.")}
    end
  end

  defp require_header_auth(conn) do
    case conn.assigns[:sigv4_signed_request] do
      %{auth_type: :header, payload_mode: :single, service: "iam"} ->
        :ok

      %{auth_type: :header, service: "iam"} ->
        {:error,
         QueryError.new(:access_denied,
           message: "IAM POST form requests must sign the exact payload hash."
         )}

      %{service: _other} ->
        {:error,
         QueryError.new(:access_denied,
           message: "Credential scope service must be iam for IAM requests."
         )}

      _other ->
        {:error,
         QueryError.new(:access_denied,
           message: "IAM POST form requests require header SigV4 authentication."
         )}
    end
  end

  defp verify_form_content_type(conn) do
    if form_content_type?(conn) do
      :ok
    else
      {:error,
       QueryError.new(:invalid_request,
         message: "IAM POST form requests require application/x-www-form-urlencoded."
       )}
    end
  end

  defp read_form_body(conn) do
    case read_body(conn, length: @form_limit, read_length: @form_limit) do
      {:ok, body, conn} ->
        {:ok, conn, body}

      {:more, _partial, conn} ->
        {:error,
         %{
           QueryError.new(:invalid_parameter_value, message: "IAM form body too large.")
           | request_id: request_id(conn)
         }}

      {:error, _reason} ->
        {:error, QueryError.new(:invalid_request, message: "Unable to read IAM form body.")}
    end
  end

  defp verify_payload_hash(conn, body) do
    signed_hash = header(conn, "x-amz-content-sha256")
    actual_hash = Signer.hex_sha256(body)

    normalized_hash =
      if is_binary(signed_hash), do: String.downcase(signed_hash), else: signed_hash

    cond do
      signed_hash in [nil, ""] ->
        {:error,
         QueryError.new(:access_denied,
           message: "IAM POST form requests require x-amz-content-sha256."
         )}

      signed_hash == "UNSIGNED-PAYLOAD" or String.starts_with?(signed_hash, "STREAMING-") ->
        {:error,
         QueryError.new(:access_denied,
           message: "IAM POST form requests must sign the exact payload hash."
         )}

      not payload_hash?(normalized_hash) ->
        {:error,
         QueryError.new(:access_denied,
           message: "IAM POST form requests require a SHA256 payload hash."
         )}

      Signer.secure_compare(normalized_hash, actual_hash) ->
        :ok

      true ->
        {:error,
         QueryError.new(:access_denied,
           message: "Request payload hash does not match x-amz-content-sha256."
         )}
    end
  end

  defp decode_form_params(body) do
    try do
      pairs = URI.query_decoder(body) |> Enum.to_list()

      if duplicate_keys?(pairs) do
        {:error,
         QueryError.new(:invalid_parameter_value,
           message: "IAM form parameters must not be repeated."
         )}
      else
        {:ok, Map.new(pairs)}
      end
    rescue
      ArgumentError ->
        {:error, QueryError.new(:invalid_parameter_value, message: "Invalid form encoding.")}
    end
  end

  defp empty_success(conn, action_name) do
    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(200, QueryView.empty_response(action_name, request_id(conn)))
    |> halt()
  end

  defp reject(conn, %QueryError{} = error) do
    error = %{error | request_id: error.request_id || request_id(conn)}
    {status, body} = QueryView.error_response(error)

    Log.warn("iam error response", iam_error_metadata(conn, error, status))

    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(status, body)
    |> halt()
  end

  defp iam_error_metadata(conn, %QueryError{} = error, status) do
    []
    |> maybe_put_metadata(:action, action(conn))
    |> maybe_put_metadata(:principal_arn, caller_principal_arn(conn))
    |> maybe_put_metadata(:user_name, audit_user_name(conn))
    |> maybe_put_metadata(:access_key_id, audit_access_key_id(conn))
    |> maybe_put_metadata(:target_principal_arn, audit_target_principal_arn(conn))
    |> maybe_put_metadata(:code, error.code)
    |> maybe_put_metadata(:status, status)
  end

  defp caller_principal_arn(conn) do
    case conn.assigns[:principal] do
      %{arn: arn} when is_binary(arn) -> arn
      _other -> nil
    end
  end

  defp audit_user_name(conn) do
    case Map.get(params(conn), "UserName") do
      value when is_binary(value) ->
        if Regex.match?(@user_name_pattern, value), do: value

      _other ->
        nil
    end
  end

  defp audit_access_key_id(conn) do
    case Map.get(params(conn), "AccessKeyId") do
      value when is_binary(value) ->
        if Regex.match?(@access_key_id_pattern, value) or configured_root_access_key?(value),
          do: value

      _other ->
        nil
    end
  end

  defp audit_target_principal_arn(conn) do
    if access_key_lifecycle_action?(action(conn)) do
      case Map.get(params(conn), "UserName") do
        nil ->
          IAM.root_principal_arn()

        value when is_binary(value) ->
          if Regex.match?(@user_name_pattern, value), do: IAM.user_arn(value)

        _other ->
          nil
      end
    end
  end

  defp access_key_lifecycle_action?(action)
       when action in ["CreateAccessKey", "ListAccessKeys", "UpdateAccessKey", "DeleteAccessKey"],
       do: true

  defp access_key_lifecycle_action?(_action), do: false

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Keyword.put(metadata, key, value)

  # Already-structured IAM Query errors pass through unchanged, so every `with/else`
  # branch can funnel through a single mapping point without losing the original code.
  defp error_from_reason(%QueryError{} = error), do: error

  defp error_from_reason(%Changeset{} = changeset) do
    cond do
      unique_constraint_error?(changeset) ->
        QueryError.new(:entity_already_exists)

      Keyword.has_key?(changeset.errors, :trust_policy) ->
        QueryError.new(:malformed_policy_document,
          message: "The assume role policy document is malformed."
        )

      true ->
        QueryError.new(:invalid_input, message: "IAM parameters are invalid.")
    end
  end

  defp error_from_reason(:not_found), do: QueryError.new(:no_such_entity)

  defp error_from_reason(:user_already_exists), do: QueryError.new(:entity_already_exists)

  defp error_from_reason(:group_already_exists), do: QueryError.new(:entity_already_exists)

  defp error_from_reason(:role_already_exists), do: QueryError.new(:entity_already_exists)

  defp error_from_reason(:instance_profile_already_exists),
    do: QueryError.new(:entity_already_exists)

  defp error_from_reason(:server_certificate_already_exists),
    do: QueryError.new(:entity_already_exists)

  defp error_from_reason(:duplicate_certificate), do: QueryError.new(:duplicate_certificate)

  defp error_from_reason(:duplicate_ssh_public_key), do: QueryError.new(:duplicate_ssh_public_key)

  defp error_from_reason(:invalid_public_key), do: QueryError.new(:invalid_public_key)

  defp error_from_reason(:already_exists), do: QueryError.new(:entity_already_exists)

  defp error_from_reason(:limit_exceeded), do: QueryError.new(:limit_exceeded)

  defp error_from_reason(:server_certificate_limit_exceeded), do: QueryError.new(:limit_exceeded)

  defp error_from_reason(:signing_certificate_limit_exceeded),
    do:
      QueryError.new(:limit_exceeded,
        message: "Cannot exceed quota for signing certificates per principal."
      )

  defp error_from_reason(:ssh_public_key_limit_exceeded),
    do:
      QueryError.new(:limit_exceeded,
        message: "Cannot exceed quota for SSH public keys per user."
      )

  defp error_from_reason(:server_certificate_update_empty),
    do:
      QueryError.new(:invalid_parameter_value,
        message: "NewServerCertificateName or NewPath is required."
      )

  defp error_from_reason(:user_inactive),
    do: QueryError.new(:no_such_entity, message: "The specified user is inactive.")

  defp error_from_reason(:access_key_limit_exceeded),
    do:
      QueryError.new(:limit_exceeded,
        message: "Cannot exceed quota for access keys per principal."
      )

  defp error_from_reason(:cannot_delete_last_root),
    do:
      QueryError.new(:delete_conflict,
        message: "Cannot delete the last root access key."
      )

  defp error_from_reason(:cannot_deactivate_last_root),
    do:
      QueryError.new(:delete_conflict,
        message: "Cannot deactivate the last active root access key."
      )

  defp error_from_reason(:invalid_tag),
    do:
      QueryError.new(:invalid_parameter_value,
        message: "Tags must contain valid tag keys and values."
      )

  defp error_from_reason({:delete_conflict, _blockers}),
    do:
      QueryError.new(:delete_conflict,
        message: "Cannot delete the user because it has subordinate IAM resources."
      )

  defp error_from_reason({:group_delete_conflict, _blockers}),
    do:
      QueryError.new(:delete_conflict,
        message: "Cannot delete the group because it has subordinate IAM resources."
      )

  defp error_from_reason({:role_delete_conflict, _blockers}),
    do:
      QueryError.new(:delete_conflict,
        message: "Cannot delete the role because it has subordinate IAM resources."
      )

  defp error_from_reason({:instance_profile_delete_conflict, _blockers}),
    do:
      QueryError.new(:delete_conflict,
        message: "Cannot delete the instance profile while it contains a role."
      )

  defp error_from_reason(:instance_profile_role_limit_exceeded),
    do:
      QueryError.new(:limit_exceeded,
        message: "Cannot exceed quota for roles per instance profile."
      )

  defp error_from_reason(:policy_attached),
    do:
      QueryError.new(:delete_conflict,
        message: "Cannot delete the policy because it is attached to one or more IAM identities."
      )

  defp error_from_reason(:policy_has_non_default_versions),
    do:
      QueryError.new(:delete_conflict,
        message: "Cannot delete the policy because it has non-default policy versions."
      )

  defp error_from_reason(:default_policy_version),
    do:
      QueryError.new(:delete_conflict,
        message: "Cannot delete the default policy version."
      )

  defp error_from_reason(:malformed),
    do: QueryError.new(:invalid_input, message: "IAM parameters are malformed.")

  defp error_from_reason(:malformed_certificate), do: QueryError.new(:malformed_certificate)

  defp error_from_reason(:key_pair_mismatch), do: QueryError.new(:key_pair_mismatch)

  defp error_from_reason(:malformed_policy_document),
    do: QueryError.new(:malformed_policy_document)

  defp error_from_reason(:malformed_trust_policy),
    do:
      QueryError.new(:malformed_policy_document,
        message: "The assume role policy document is malformed."
      )

  defp error_from_reason(:policy_limit_exceeded), do: QueryError.new(:limit_exceeded)

  defp error_from_reason(:policy_version_limit_exceeded), do: QueryError.new(:limit_exceeded)

  defp error_from_reason(:invalid_provider_issuer),
    do: QueryError.new(:invalid_input, message: "OpenID Connect provider Url is invalid.")

  defp error_from_reason(:identity_provider_keys_missing),
    do: QueryError.new(:invalid_input, message: "OpenID Connect provider JWKS is missing.")

  defp error_from_reason(:identity_provider_keys_malformed),
    do: QueryError.new(:invalid_input, message: "OpenID Connect provider JWKS is malformed.")

  defp error_from_reason(:invalid_oidc_discovery_provider),
    do: QueryError.new(:service_failure, message: "OpenID Connect discovery is not configured.")

  defp error_from_reason(:oidc_discovery_http_error),
    do: QueryError.new(:open_id_idp_communication_error)

  defp error_from_reason(:oidc_discovery_response_too_large),
    do: QueryError.new(:invalid_input, message: "OpenID Connect discovery response is too large.")

  defp error_from_reason(:oidc_discovery_malformed_json),
    do: QueryError.new(:invalid_input, message: "OpenID Connect discovery response is malformed.")

  defp error_from_reason(:oidc_discovery_issuer_mismatch),
    do:
      QueryError.new(:invalid_input,
        message: "OpenID Connect discovery issuer does not match Url."
      )

  defp error_from_reason(:oidc_discovery_invalid_jwks_uri),
    do: QueryError.new(:invalid_input, message: "OpenID Connect discovery jwks_uri is invalid.")

  defp error_from_reason(:oidc_discovery_tls_thumbprint_failed),
    do:
      QueryError.new(:invalid_input,
        message: "OpenID Connect provider TLS thumbprint discovery failed."
      )

  defp error_from_reason(:oidc_discovery_thumbprint_mismatch),
    do:
      QueryError.new(:invalid_input,
        message: "OpenID Connect provider TLS thumbprints do not match ThumbprintList."
      )

  defp error_from_reason(:mfa_device_not_found),
    do: QueryError.new(:no_such_entity, message: "MFA device does not exist.")

  defp error_from_reason(:mfa_device_not_pending),
    do: QueryError.new(:invalid_parameter_value, message: "MFA device is not pending.")

  defp error_from_reason(:mfa_device_not_active),
    do: QueryError.new(:invalid_parameter_value, message: "MFA device is not active.")

  defp error_from_reason(:mfa_principal_mismatch),
    do: QueryError.new(:access_denied, message: "MFA device is assigned to another principal.")

  defp error_from_reason(:active_mfa_device_requires_force), do: QueryError.new(:delete_conflict)

  defp error_from_reason(reason)
       when reason in [
              :invalid_totp_secret,
              :invalid_totp_code,
              :unsupported_totp_algorithm,
              :totp_code_mismatch,
              :mfa_code_replayed,
              :mfa_consecutive_codes_required
            ],
       do: QueryError.new(:invalid_authentication_code)

  defp error_from_reason(reason) do
    Log.warn("iam query api local error",
      action: nil,
      reason: inspect(reason)
    )

    QueryError.new(:service_failure)
  end

  defp params(conn), do: conn.assigns[:iam_params] || conn.query_params || %{}

  defp action(conn), do: Map.get(params(conn), "Action")

  defp known_iam_action?(params), do: Map.get(params, "Action") in @supported_actions

  defp signed_iam_scope?(conn), do: match?(%{service: "iam"}, conn.assigns[:sigv4_signed_request])

  defp form_content_type?(conn) do
    case header(conn, "content-type") do
      nil ->
        false

      content_type ->
        content_type
        |> String.split(";", parts: 2)
        |> List.first()
        |> String.trim()
        |> String.downcase()
        |> Kernel.==("application/x-www-form-urlencoded")
    end
  end

  defp duplicate_keys?(pairs) do
    keys = Enum.map(pairs, fn {key, _value} -> key end)
    Enum.uniq(keys) != keys
  end

  defp payload_hash?(value) when is_binary(value), do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  defp payload_hash?(_value), do: false

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp current_time(conn), do: conn.private[:maxio_now] || DateTime.utc_now()

  defp request_id(conn) do
    get_resp_header(conn, "x-request-id") |> List.first() ||
      get_req_header(conn, "x-request-id") |> List.first()
  end

  defp virtual_mfa_serial(path, name), do: "arn:aws:iam:::mfa/#{mfa_device_label(path, name)}"

  defp mfa_device_label("/", name), do: name
  defp mfa_device_label(path, name), do: String.trim(path, "/") <> "/" <> name

  defp valid_user_name?(user_name), do: Regex.match?(@virtual_mfa_device_name_pattern, user_name)

  defp user_matches_principal?(user_name, "arn:aws:iam:::user/" <> principal_name),
    do: user_name == principal_name

  defp user_matches_principal?(_user_name, _principal_arn), do: false

  defp root_principal?(%{type: :root, arn: arn}), do: arn == IAM.root_principal_arn()
  defp root_principal?(_principal), do: false

  defp iam_user_principal?(%{type: :iam_user, arn: "arn:aws:iam:::user/" <> resource}),
    do: resource != ""

  defp iam_user_principal?(_principal), do: false

  defp unique_constraint_error?(%Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint] == :unique
    end)
  end

  defp sha256_hex(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
