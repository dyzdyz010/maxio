defmodule Maxio.IAM.QueryAPITest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Maxio.Auth.CredentialStore.EctoStore
  alias Maxio.Auth.SigV4.{Canonical, Signer}
  alias Maxio.IAM
  alias Maxio.IAM.TOTP
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @sigv4_host "localhost"
  @sigv4_region "us-east-1"
  @sigv4_secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

  setup do
    previous_store = Application.fetch_env!(:maxio, :credential_store)
    previous_discovery = Application.get_env(:maxio, :oidc_discovery, :__unset__)

    previous_discovery_fixtures =
      Application.get_env(:maxio, :oidc_discovery_fixtures, :__unset__)

    Application.put_env(:maxio, :credential_store, EctoStore)
    Application.put_env(:maxio, :oidc_discovery, Maxio.Test.OIDCDiscovery)
    Application.put_env(:maxio, :oidc_discovery_fixtures, %{})

    on_exit(fn ->
      Application.put_env(:maxio, :credential_store, previous_store)

      case previous_discovery do
        :__unset__ -> Application.delete_env(:maxio, :oidc_discovery)
        value -> Application.put_env(:maxio, :oidc_discovery, value)
      end

      case previous_discovery_fixtures do
        :__unset__ -> Application.delete_env(:maxio, :oidc_discovery_fixtures)
        value -> Application.put_env(:maxio, :oidc_discovery_fixtures, value)
      end
    end)

    IAM.bootstrap_root()
    :ok
  end

  test "root reads IAM account summary through Query XML" do
    user_name = unique_name("summary-user")
    group_name = unique_name("summary-group")
    role_name = unique_name("summary-role")
    policy_name = unique_name("SummaryPolicy")

    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, _group} = IAM.create_group(group_name: group_name)
    assert {:ok, _role} = IAM.create_role(role_name: role_name, trust_policy: root_trust_policy())

    assert {:ok, policy} =
             IAM.create_managed_policy(
               name: policy_name,
               policy: identity_policy("s3:GetObject", "arn:aws:s3:::summary/*")
             )

    {certificate_body, private_key, _certificate_chain} = server_certificate_pems()

    assert {:ok, _certificate} =
             IAM.upload_server_certificate(
               server_certificate_name: unique_name("summary-cert"),
               certificate_body: certificate_body,
               private_key: private_key
             )

    assert {:ok, _signing_certificate} =
             IAM.upload_signing_certificate(certificate_body: certificate_body)

    assert {:ok, _version} =
             IAM.create_managed_policy_version_strict(
               policy.policy_arn,
               identity_policy("s3:PutObject", "arn:aws:s3:::summary/*"),
               false
             )

    active_user_mfa("root")

    response =
      signed_iam_conn(%{"Action" => "GetAccountSummary"})
      |> call()

    assert response.status == 200
    assert response.resp_body =~ "<GetAccountSummaryResponse"

    summary = xml_summary_map(response.resp_body)

    assert summary["Users"] == 1
    assert summary["Groups"] == 1
    assert summary["Roles"] == 1
    assert summary["Policies"] == 1
    assert summary["PolicyVersionsInUse"] == 2
    assert summary["MFADevices"] == 1
    assert summary["MFADevicesInUse"] == 1
    assert summary["AccountMFAEnabled"] == 1
    assert summary["AccountAccessKeysPresent"] == 1
    assert summary["AccountPasswordPresent"] == 1
    assert summary["AccessKeysPerUserQuota"] == 2
    assert summary["AttachedPoliciesPerUserQuota"] == 10
    assert summary["AttachedPoliciesPerGroupQuota"] == 10
    assert summary["AttachedPoliciesPerRoleQuota"] == 10
    assert summary["VersionsPerPolicyQuota"] == 5
    assert summary["PoliciesQuota"] == 1500
    assert summary["PolicyVersionsInUseQuota"] == 7500
    assert summary["Providers"] == 0
    assert summary["ServerCertificates"] == 1
    assert summary["ServerCertificatesQuota"] == 20
    assert summary["AccountSigningCertificatesPresent"] == 1
    assert summary["SigningCertificatesPerUserQuota"] == 2
    assert summary["InstanceProfiles"] == 0

    unsupported =
      signed_iam_conn(%{"Action" => "GetAccountSummary", "Foo" => "bar"})
      |> call()

    assert unsupported.status == 400
    assert unsupported.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert unsupported.resp_body =~ "Foo is not implemented"

    assert {:ok, key} = IAM.create_access_key(user_name: user_name, secret_key: "summary-secret")

    denied =
      signed_iam_conn(%{"Action" => "GetAccountSummary"},
        access_key: key.access_key_id,
        secret: "summary-secret"
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"
  end

  test "root manages account aliases through IAM Query XML" do
    alias_name = "example-corp-#{System.unique_integer([:positive])}"

    empty_list =
      signed_iam_conn(%{"Action" => "ListAccountAliases"})
      |> call()

    assert empty_list.status == 200
    assert empty_list.resp_body =~ "<ListAccountAliasesResponse"
    assert xml_values(empty_list.resp_body, "member") == []
    assert xml_value(empty_list.resp_body, "IsTruncated") == "false"

    create =
      signed_iam_conn(%{"Action" => "CreateAccountAlias", "AccountAlias" => alias_name})
      |> call()

    assert create.status == 200
    assert create.resp_body =~ "<CreateAccountAliasResponse"
    assert IAM.list_account_aliases() == [alias_name]

    list =
      signed_iam_conn(%{"Action" => "ListAccountAliases", "MaxItems" => "1"})
      |> call()

    assert list.status == 200
    assert xml_values(list.resp_body, "member") == [alias_name]
    assert xml_value(list.resp_body, "IsTruncated") == "false"

    marker_after_last =
      signed_iam_conn(%{"Action" => "ListAccountAliases", "Marker" => "1"})
      |> call()

    assert marker_after_last.status == 200
    assert xml_values(marker_after_last.resp_body, "member") == []
    assert xml_value(marker_after_last.resp_body, "IsTruncated") == "false"

    duplicate =
      signed_iam_conn(%{"Action" => "CreateAccountAlias", "AccountAlias" => alias_name})
      |> call()

    assert duplicate.status == 409
    assert duplicate.resp_body =~ "<Code>EntityAlreadyExists</Code>"

    limit =
      signed_iam_conn(%{
        "Action" => "CreateAccountAlias",
        "AccountAlias" => "other-corp-#{System.unique_integer([:positive])}"
      })
      |> call()

    assert limit.status == 409
    assert limit.resp_body =~ "<Code>LimitExceeded</Code>"

    invalid =
      signed_iam_conn(%{"Action" => "CreateAccountAlias", "AccountAlias" => "BadAlias"})
      |> call()

    assert invalid.status == 400
    assert invalid.resp_body =~ "<Code>InvalidParameterValue</Code>"

    unsupported =
      signed_iam_conn(%{"Action" => "ListAccountAliases", "Foo" => "bar"})
      |> call()

    assert unsupported.status == 400
    assert unsupported.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert unsupported.resp_body =~ "Foo is not implemented"

    user_name = unique_name("alias-user")
    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, key} = IAM.create_access_key(user_name: user_name, secret_key: "alias-secret")

    denied =
      signed_iam_conn(%{"Action" => "ListAccountAliases"},
        access_key: key.access_key_id,
        secret: "alias-secret"
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    delete =
      signed_iam_conn(%{"Action" => "DeleteAccountAlias", "AccountAlias" => alias_name})
      |> call()

    assert delete.status == 200
    assert delete.resp_body =~ "<DeleteAccountAliasResponse"
    assert IAM.list_account_aliases() == []

    missing_delete =
      signed_iam_conn(%{"Action" => "DeleteAccountAlias", "AccountAlias" => alias_name})
      |> call()

    assert missing_delete.status == 404
    assert missing_delete.resp_body =~ "<Code>NoSuchEntity</Code>"
  end

  test "root manages account password policy through IAM Query XML" do
    missing =
      signed_iam_conn(%{"Action" => "GetAccountPasswordPolicy"})
      |> call()

    assert missing.status == 404
    assert missing.resp_body =~ "<Code>NoSuchEntity</Code>"

    default_update =
      signed_iam_conn(%{"Action" => "UpdateAccountPasswordPolicy"})
      |> call()

    assert default_update.status == 200
    assert default_update.resp_body =~ "<UpdateAccountPasswordPolicyResponse"

    default_get =
      signed_iam_conn(%{"Action" => "GetAccountPasswordPolicy"})
      |> call()

    assert default_get.status == 200
    assert xml_value(default_get.resp_body, "MinimumPasswordLength") == "6"
    assert xml_value(default_get.resp_body, "AllowUsersToChangePassword") == "false"
    assert xml_value(default_get.resp_body, "ExpirePasswords") == "false"
    assert xml_value(default_get.resp_body, "HardExpiry") == "false"
    assert xml_value(default_get.resp_body, "RequireLowercaseCharacters") == "false"
    assert xml_value(default_get.resp_body, "RequireNumbers") == "false"
    assert xml_value(default_get.resp_body, "RequireSymbols") == "false"
    assert xml_value(default_get.resp_body, "RequireUppercaseCharacters") == "false"
    refute default_get.resp_body =~ "<MaxPasswordAge>"
    refute default_get.resp_body =~ "<PasswordReusePrevention>"

    update =
      signed_iam_conn(%{
        "Action" => "UpdateAccountPasswordPolicy",
        "AllowUsersToChangePassword" => "true",
        "HardExpiry" => "true",
        "MaxPasswordAge" => "90",
        "MinimumPasswordLength" => "12",
        "PasswordReusePrevention" => "12",
        "RequireLowercaseCharacters" => "true",
        "RequireNumbers" => "true",
        "RequireSymbols" => "true",
        "RequireUppercaseCharacters" => "true"
      })
      |> call()

    assert update.status == 200

    get =
      signed_iam_conn(%{"Action" => "GetAccountPasswordPolicy"})
      |> call()

    assert get.status == 200
    assert get.resp_body =~ "<GetAccountPasswordPolicyResponse"
    assert xml_value(get.resp_body, "MinimumPasswordLength") == "12"
    assert xml_value(get.resp_body, "AllowUsersToChangePassword") == "true"
    assert xml_value(get.resp_body, "ExpirePasswords") == "true"
    assert xml_value(get.resp_body, "HardExpiry") == "true"
    assert xml_value(get.resp_body, "MaxPasswordAge") == "90"
    assert xml_value(get.resp_body, "PasswordReusePrevention") == "12"
    assert xml_value(get.resp_body, "RequireLowercaseCharacters") == "true"
    assert xml_value(get.resp_body, "RequireNumbers") == "true"
    assert xml_value(get.resp_body, "RequireSymbols") == "true"
    assert xml_value(get.resp_body, "RequireUppercaseCharacters") == "true"

    invalid_range =
      signed_iam_conn(%{
        "Action" => "UpdateAccountPasswordPolicy",
        "MinimumPasswordLength" => "5"
      })
      |> call()

    assert invalid_range.status == 400
    assert invalid_range.resp_body =~ "<Code>InvalidParameterValue</Code>"

    invalid_boolean =
      signed_iam_conn(%{"Action" => "UpdateAccountPasswordPolicy", "RequireNumbers" => "yes"})
      |> call()

    assert invalid_boolean.status == 400
    assert invalid_boolean.resp_body =~ "<Code>InvalidParameterValue</Code>"

    unsupported =
      signed_iam_conn(%{"Action" => "GetAccountPasswordPolicy", "Foo" => "bar"})
      |> call()

    assert unsupported.status == 400
    assert unsupported.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert unsupported.resp_body =~ "Foo is not implemented"

    user_name = unique_name("password-policy-user")
    assert {:ok, _user} = IAM.create_user(user_name: user_name)

    assert {:ok, key} =
             IAM.create_access_key(user_name: user_name, secret_key: "password-policy-secret")

    denied =
      signed_iam_conn(%{"Action" => "GetAccountPasswordPolicy"},
        access_key: key.access_key_id,
        secret: "password-policy-secret"
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    delete =
      signed_iam_conn(%{"Action" => "DeleteAccountPasswordPolicy"})
      |> call()

    assert delete.status == 200
    assert delete.resp_body =~ "<DeleteAccountPasswordPolicyResponse"

    deleted_get =
      signed_iam_conn(%{"Action" => "GetAccountPasswordPolicy"})
      |> call()

    assert deleted_get.status == 404
    assert deleted_get.resp_body =~ "<Code>NoSuchEntity</Code>"
  end

  test "root manages IAM users and user tags through IAM Query XML" do
    first_name = unique_name("a-query-user")
    second_name = unique_name("z-query-user")
    boundary_policy_name = unique_name("UserBoundaryPolicy")

    assert {:ok, boundary_policy} =
             IAM.create_managed_policy(
               name: boundary_policy_name,
               policy: identity_policy("s3:GetObject", "arn:aws:s3:::user-boundary/*")
             )

    create =
      signed_iam_conn(%{
        "Action" => "CreateUser",
        "Path" => "/",
        "UserName" => first_name,
        "PermissionsBoundary" => boundary_policy.policy_arn,
        "Tags.member.1.Key" => "team",
        "Tags.member.1.Value" => "core",
        "Tags.member.2.Key" => "env",
        "Tags.member.2.Value" => "dev"
      })
      |> call()

    assert create.status == 200
    assert create.resp_body =~ "<CreateUserResponse"
    assert xml_value(create.resp_body, "Path") == "/"
    assert xml_value(create.resp_body, "UserName") == first_name
    assert xml_value(create.resp_body, "Arn") == "arn:aws:iam:::user/#{first_name}"
    assert xml_value(create.resp_body, "UserId") =~ ~r/\AAIDA[A-Z2-7]{16}\z/
    assert xml_value(create.resp_body, "PermissionsBoundaryType") == "PermissionsBoundaryPolicy"
    assert xml_value(create.resp_body, "PermissionsBoundaryArn") == boundary_policy.policy_arn
    assert xml_tag_pairs(create.resp_body) == [{"env", "dev"}, {"team", "core"}]
    assert {:ok, user} = IAM.get_user(first_name)
    assert user.tags == %{"env" => "dev", "team" => "core"}
    assert user.permissions_boundary_policy_arn == boundary_policy.policy_arn

    second_create =
      signed_iam_conn(%{
        "Action" => "CreateUser",
        "UserName" => second_name
      })
      |> call()

    assert second_create.status == 200

    get =
      signed_iam_conn(%{
        "Action" => "GetUser",
        "UserName" => first_name
      })
      |> call()

    assert get.status == 200
    assert get.resp_body =~ "<GetUserResponse"
    assert xml_value(get.resp_body, "UserName") == first_name
    assert xml_value(get.resp_body, "PermissionsBoundaryArn") == boundary_policy.policy_arn
    assert xml_tag_pairs(get.resp_body) == [{"env", "dev"}, {"team", "core"}]

    list =
      signed_iam_conn(%{
        "Action" => "ListUsers",
        "MaxItems" => "1"
      })
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<ListUsersResponse"
    assert xml_value(list.resp_body, "IsTruncated") == "true"
    assert xml_values(list.resp_body, "UserName") == [first_name]
    assert xml_tag_pairs(list.resp_body) == []
    marker = xml_value(list.resp_body, "Marker")

    list_next =
      signed_iam_conn(%{
        "Action" => "ListUsers",
        "MaxItems" => "1",
        "Marker" => marker
      })
      |> call()

    assert list_next.status == 200
    assert xml_value(list_next.resp_body, "IsTruncated") == "false"
    assert xml_values(list_next.resp_body, "UserName") == [second_name]

    list_other_path =
      signed_iam_conn(%{
        "Action" => "ListUsers",
        "PathPrefix" => "/engineering/"
      })
      |> call()

    assert list_other_path.status == 200
    assert xml_value(list_other_path.resp_body, "IsTruncated") == "false"
    assert xml_values(list_other_path.resp_body, "UserName") == []

    list_tags =
      signed_iam_conn(%{
        "Action" => "ListUserTags",
        "UserName" => first_name
      })
      |> call()

    assert list_tags.status == 200
    assert list_tags.resp_body =~ "<ListUserTagsResponse"
    assert xml_value(list_tags.resp_body, "IsTruncated") == "false"
    assert xml_tag_pairs(list_tags.resp_body) == [{"env", "dev"}, {"team", "core"}]

    first_tag_page =
      signed_iam_conn(%{
        "Action" => "ListUserTags",
        "UserName" => first_name,
        "MaxItems" => "1"
      })
      |> call()

    assert first_tag_page.status == 200
    assert xml_value(first_tag_page.resp_body, "IsTruncated") == "true"
    assert xml_tag_pairs(first_tag_page.resp_body) == [{"env", "dev"}]
    tag_marker = xml_value(first_tag_page.resp_body, "Marker")

    second_tag_page =
      signed_iam_conn(%{
        "Action" => "ListUserTags",
        "UserName" => first_name,
        "MaxItems" => "1",
        "Marker" => tag_marker
      })
      |> call()

    assert second_tag_page.status == 200
    assert xml_value(second_tag_page.resp_body, "IsTruncated") == "false"
    assert xml_tag_pairs(second_tag_page.resp_body) == [{"team", "core"}]

    tag_update =
      signed_iam_conn(%{
        "Action" => "TagUser",
        "UserName" => first_name,
        "Tags.member.1.Key" => "ENV",
        "Tags.member.1.Value" => "prod",
        "Tags.member.2.Key" => "stage",
        "Tags.member.2.Value" => ""
      })
      |> call()

    assert tag_update.status == 200
    assert tag_update.resp_body =~ "<TagUserResponse"
    assert {:ok, user} = IAM.get_user(first_name)
    assert user.tags == %{"ENV" => "prod", "stage" => "", "team" => "core"}

    untag =
      signed_iam_conn(%{
        "Action" => "UntagUser",
        "UserName" => first_name,
        "TagKeys.member.1" => "env",
        "TagKeys.member.2" => "TEAM"
      })
      |> call()

    assert untag.status == 200
    assert untag.resp_body =~ "<UntagUserResponse"
    assert {:ok, user} = IAM.get_user(first_name)
    assert user.tags == %{"stage" => ""}

    delete =
      signed_iam_conn(%{
        "Action" => "DeleteUser",
        "UserName" => first_name
      })
      |> call()

    assert delete.status == 200
    assert delete.resp_body =~ "<DeleteUserResponse"

    missing =
      signed_iam_conn(%{
        "Action" => "GetUser",
        "UserName" => first_name
      })
      |> call()

    assert missing.status == 404
    assert missing.resp_body =~ "<Code>NoSuchEntity</Code>"
  end

  test "root renames IAM users through IAM Query XML" do
    old_name = unique_name("query-rename-user")
    new_name = unique_name("query-renamed-user")
    duplicate_name = unique_name("query-rename-user-dupe")

    assert {:ok, _user} = IAM.create_user(user_name: old_name)
    assert {:ok, _duplicate} = IAM.create_user(user_name: duplicate_name)

    assert {:ok, %{access_key_id: access_key_id, secret_key: secret}} =
             IAM.create_access_key_strict(old_name)

    duplicate =
      signed_iam_conn(%{
        "Action" => "UpdateUser",
        "UserName" => old_name,
        "NewUserName" => String.upcase(duplicate_name)
      })
      |> call()

    assert duplicate.status == 409
    assert duplicate.resp_body =~ "<Code>EntityAlreadyExists</Code>"

    invalid_path =
      signed_iam_conn(%{
        "Action" => "UpdateUser",
        "UserName" => old_name,
        "NewPath" => "/engineering/"
      })
      |> call()

    assert invalid_path.status == 400
    assert invalid_path.resp_body =~ "<Code>InvalidParameterValue</Code>"

    update =
      signed_iam_conn(%{
        "Action" => "UpdateUser",
        "UserName" => old_name,
        "NewUserName" => new_name,
        "NewPath" => "/"
      })
      |> call()

    assert update.status == 200
    assert update.resp_body =~ "<UpdateUserResponse"
    assert xml_value(update.resp_body, "Path") == "/"
    assert xml_value(update.resp_body, "UserName") == new_name
    assert xml_value(update.resp_body, "Arn") == "arn:aws:iam:::user/#{new_name}"

    missing_old =
      signed_iam_conn(%{"Action" => "GetUser", "UserName" => old_name})
      |> call()

    assert missing_old.status == 404

    get_new =
      signed_iam_conn(%{"Action" => "GetUser", "UserName" => new_name})
      |> call()

    assert get_new.status == 200
    assert xml_value(get_new.resp_body, "UserName") == new_name

    assert {:ok, %{principal: %{arn: "arn:aws:iam:::user/" <> ^new_name}}} =
             EctoStore.get_secret(access_key_id)

    denied =
      signed_iam_conn(
        %{"Action" => "UpdateUser", "UserName" => new_name, "NewUserName" => old_name},
        access_key: access_key_id,
        secret: secret
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"
  end

  test "root manages IAM user access keys through IAM Query XML" do
    user_name = unique_name("query-key-user")
    other_user_name = unique_name("query-key-other")

    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, _other_user} = IAM.create_user(user_name: other_user_name)

    create =
      signed_iam_conn(%{
        "Action" => "CreateAccessKey",
        "UserName" => user_name
      })
      |> call()

    assert create.status == 200
    assert create.resp_body =~ "<CreateAccessKeyResponse"
    assert xml_value(create.resp_body, "UserName") == user_name
    access_key_id = xml_value(create.resp_body, "AccessKeyId")
    secret = xml_value(create.resp_body, "SecretAccessKey")
    assert access_key_id =~ ~r/\AAKIA[A-Z2-7]+\z/
    assert byte_size(secret) == 40
    assert xml_value(create.resp_body, "Status") == "Active"

    assert {:ok, %{secret_key: ^secret, principal: %{arn: principal_arn}}} =
             EctoStore.get_secret(access_key_id)

    assert principal_arn == IAM.user_arn(user_name)

    unused =
      signed_iam_conn(%{
        "Action" => "GetAccessKeyLastUsed",
        "AccessKeyId" => access_key_id
      })
      |> call()

    assert unused.status == 200
    assert unused.resp_body =~ "<GetAccessKeyLastUsedResponse"
    assert xml_value(unused.resp_body, "UserName") == user_name
    assert xml_value(unused.resp_body, "ServiceName") == "N/A"
    assert xml_value(unused.resp_body, "Region") == "N/A"
    refute unused.resp_body =~ "<LastUsedDate>"

    denied_user_query =
      signed_iam_conn(%{"Action" => "ListUsers"}, access_key: access_key_id, secret: secret)
      |> call()

    assert denied_user_query.status == 403
    assert denied_user_query.resp_body =~ "<Code>AccessDenied</Code>"

    used =
      signed_iam_conn(%{
        "Action" => "GetAccessKeyLastUsed",
        "AccessKeyId" => access_key_id
      })
      |> call()

    assert used.status == 200
    assert xml_value(used.resp_body, "ServiceName") == "iam"
    assert xml_value(used.resp_body, "Region") == @sigv4_region
    assert xml_value(used.resp_body, "LastUsedDate") =~ ~r/\A\d{4}-\d{2}-\d{2}T/

    second_create =
      signed_iam_form_conn(%{
        "Action" => "CreateAccessKey",
        "UserName" => user_name
      })
      |> call()

    assert second_create.status == 200
    second_access_key_id = xml_value(second_create.resp_body, "AccessKeyId")
    assert second_access_key_id != access_key_id

    over_quota =
      signed_iam_conn(%{
        "Action" => "CreateAccessKey",
        "UserName" => user_name
      })
      |> call()

    assert over_quota.status == 409
    assert over_quota.resp_body =~ "<Code>LimitExceeded</Code>"

    first_page =
      signed_iam_conn(%{
        "Action" => "ListAccessKeys",
        "UserName" => user_name,
        "MaxItems" => "1"
      })
      |> call()

    assert first_page.status == 200
    assert first_page.resp_body =~ "<ListAccessKeysResponse"
    assert first_page.resp_body =~ "<UserName>#{user_name}</UserName>"
    assert xml_values(first_page.resp_body, "AccessKeyId") == [access_key_id]
    assert xml_values(first_page.resp_body, "Status") == ["Active"]
    refute first_page.resp_body =~ "SecretAccessKey"
    marker = xml_value(first_page.resp_body, "Marker")

    second_page =
      signed_iam_conn(%{
        "Action" => "ListAccessKeys",
        "UserName" => user_name,
        "MaxItems" => "1",
        "Marker" => marker
      })
      |> call()

    assert second_page.status == 200
    assert xml_value(second_page.resp_body, "IsTruncated") == "false"
    assert xml_values(second_page.resp_body, "AccessKeyId") == [second_access_key_id]
    refute second_page.resp_body =~ "SecretAccessKey"

    update =
      signed_iam_conn(%{
        "Action" => "UpdateAccessKey",
        "UserName" => user_name,
        "AccessKeyId" => access_key_id,
        "Status" => "Inactive"
      })
      |> call()

    assert update.status == 200
    assert update.resp_body =~ "<UpdateAccessKeyResponse"
    assert :error = EctoStore.get_secret(access_key_id)

    list_inactive =
      signed_iam_conn(%{
        "Action" => "ListAccessKeys",
        "UserName" => user_name
      })
      |> call()

    assert list_inactive.status == 200
    assert xml_values(list_inactive.resp_body, "Status") == ["Inactive", "Active"]

    expire =
      signed_iam_conn(%{
        "Action" => "UpdateAccessKey",
        "UserName" => user_name,
        "AccessKeyId" => second_access_key_id,
        "Status" => "Expired"
      })
      |> call()

    assert expire.status == 200
    assert :error = EctoStore.get_secret(second_access_key_id)

    list_expired =
      signed_iam_conn(%{
        "Action" => "ListAccessKeys",
        "UserName" => user_name
      })
      |> call()

    assert list_expired.status == 200
    assert xml_values(list_expired.resp_body, "Status") == ["Inactive", "Expired"]

    bad_scope_delete =
      signed_iam_conn(%{
        "Action" => "DeleteAccessKey",
        "UserName" => other_user_name,
        "AccessKeyId" => access_key_id
      })
      |> call()

    assert bad_scope_delete.status == 404
    assert bad_scope_delete.resp_body =~ "<Code>NoSuchEntity</Code>"

    delete =
      signed_iam_conn(%{
        "Action" => "DeleteAccessKey",
        "UserName" => user_name,
        "AccessKeyId" => access_key_id
      })
      |> call()

    assert delete.status == 200
    assert delete.resp_body =~ "<DeleteAccessKeyResponse"

    delete_second =
      signed_iam_form_conn(%{
        "Action" => "DeleteAccessKey",
        "UserName" => user_name,
        "AccessKeyId" => second_access_key_id
      })
      |> call()

    assert delete_second.status == 200
    assert {:ok, []} = IAM.list_access_keys_strict(user_name)

    empty_existing_user =
      signed_iam_conn(%{
        "Action" => "ListAccessKeys",
        "UserName" => user_name
      })
      |> call()

    assert empty_existing_user.status == 200
    assert empty_existing_user.resp_body =~ "<UserName>#{user_name}</UserName>"
    assert xml_values(empty_existing_user.resp_body, "AccessKeyId") == []

    missing_user =
      signed_iam_conn(%{
        "Action" => "ListAccessKeys",
        "UserName" => unique_name("missing-key-user")
      })
      |> call()

    assert missing_user.status == 404
    assert missing_user.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_access_key_id =
      signed_iam_conn(%{"Action" => "GetAccessKeyLastUsed"})
      |> call()

    assert missing_access_key_id.status == 400
    assert missing_access_key_id.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert missing_access_key_id.resp_body =~ "AccessKeyId is required"

    invalid_access_key_id =
      signed_iam_conn(%{
        "Action" => "GetAccessKeyLastUsed",
        "AccessKeyId" => "AKIAINVALID-KEY123"
      })
      |> call()

    assert invalid_access_key_id.status == 400
    assert invalid_access_key_id.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_access_key_id.resp_body =~ "AccessKeyId is invalid"

    unknown_access_key_id =
      signed_iam_conn(%{
        "Action" => "GetAccessKeyLastUsed",
        "AccessKeyId" => "AKIANOTEXIST1234"
      })
      |> call()

    assert unknown_access_key_id.status == 404
    assert unknown_access_key_id.resp_body =~ "<Code>NoSuchEntity</Code>"
  end

  test "access key lifecycle Query API emits audit metadata without leaking secrets" do
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)

    parent = self()
    user_name = unique_name("query-key-audit")
    user_arn = IAM.user_arn(user_name)
    assert {:ok, _user} = IAM.create_user(user_name: user_name)

    create_log =
      capture_log([level: :info], fn ->
        response =
          signed_iam_conn(%{
            "Action" => "CreateAccessKey",
            "UserName" => user_name
          })
          |> call()

        send(parent, {:create_access_key_response, response})
      end)

    assert_receive {:create_access_key_response, create}
    assert create.status == 200
    access_key_id = xml_value(create.resp_body, "AccessKeyId")
    secret = xml_value(create.resp_body, "SecretAccessKey")

    assert create_log =~ "iam create-access-key created"
    assert create_log =~ "action=create_access_key"
    assert create_log =~ "user_name=#{user_name}"
    assert create_log =~ "access_key_id=#{access_key_id}"
    assert create_log =~ "target_principal_arn=#{user_arn}"
    refute create_log =~ secret

    update_log =
      capture_log([level: :info], fn ->
        response =
          signed_iam_conn(%{
            "Action" => "UpdateAccessKey",
            "UserName" => user_name,
            "AccessKeyId" => access_key_id,
            "Status" => "Inactive"
          })
          |> call()

        send(parent, {:update_access_key_response, response})
      end)

    assert_receive {:update_access_key_response, update}
    assert update.status == 200
    assert update_log =~ "iam update-access-key updated"
    assert update_log =~ "action=update_access_key"
    assert update_log =~ "user_name=#{user_name}"
    assert update_log =~ "access_key_id=#{access_key_id}"
    assert update_log =~ "status=inactive"
    refute update_log =~ secret

    delete_log =
      capture_log([level: :info], fn ->
        response =
          signed_iam_conn(%{
            "Action" => "DeleteAccessKey",
            "UserName" => user_name,
            "AccessKeyId" => access_key_id
          })
          |> call()

        send(parent, {:delete_access_key_response, response})
      end)

    assert_receive {:delete_access_key_response, delete}
    assert delete.status == 200
    assert delete_log =~ "iam delete-access-key deleted"
    assert delete_log =~ "action=delete_access_key"
    assert delete_log =~ "user_name=#{user_name}"
    assert delete_log =~ "access_key_id=#{access_key_id}"
    refute delete_log =~ secret
  end

  test "access key lifecycle Query API failure audit includes target metadata without leaking secrets" do
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)

    parent = self()
    root_access_key = Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)
    root_arn = IAM.root_principal_arn()

    root_protection_log =
      capture_log([level: :warning], fn ->
        response =
          signed_iam_conn(%{
            "Action" => "UpdateAccessKey",
            "AccessKeyId" => root_access_key,
            "Status" => "Inactive"
          })
          |> call()

        send(parent, {:root_protection_response, response})
      end)

    assert_receive {:root_protection_response, root_protection}
    assert root_protection.status == 409
    assert root_protection.resp_body =~ "<Code>DeleteConflict</Code>"
    assert root_protection_log =~ "iam error response"
    assert root_protection_log =~ "action=UpdateAccessKey"
    assert root_protection_log =~ "code=DeleteConflict"
    assert root_protection_log =~ "status=409"
    assert root_protection_log =~ "principal_arn=#{root_arn}"
    assert root_protection_log =~ "target_principal_arn=#{root_arn}"
    assert root_protection_log =~ "access_key_id=#{root_access_key}"

    user_name = unique_name("query-key-failure-audit")
    other_user_name = unique_name("query-key-failure-other")
    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, _other_user} = IAM.create_user(user_name: other_user_name)
    assert {:ok, key} = IAM.create_access_key_strict(user_name)

    wrong_scope_log =
      capture_log([level: :warning], fn ->
        response =
          signed_iam_conn(%{
            "Action" => "UpdateAccessKey",
            "UserName" => other_user_name,
            "AccessKeyId" => key.access_key_id,
            "Status" => "Inactive"
          })
          |> call()

        send(parent, {:wrong_scope_response, response})
      end)

    assert_receive {:wrong_scope_response, wrong_scope}
    assert wrong_scope.status == 404
    assert wrong_scope.resp_body =~ "<Code>NoSuchEntity</Code>"
    assert wrong_scope_log =~ "iam error response"
    assert wrong_scope_log =~ "action=UpdateAccessKey"
    assert wrong_scope_log =~ "code=NoSuchEntity"
    assert wrong_scope_log =~ "status=404"
    assert wrong_scope_log =~ "user_name=#{other_user_name}"
    assert wrong_scope_log =~ "target_principal_arn=#{IAM.user_arn(other_user_name)}"
    assert wrong_scope_log =~ "access_key_id=#{key.access_key_id}"
    refute wrong_scope_log =~ key.secret_key
  end

  test "GetAccessKeyLastUsed accepts the configured local root access key exception" do
    original_s3 = Application.fetch_env!(:maxio, :s3)

    Application.put_env(
      :maxio,
      :s3,
      Keyword.merge(original_s3, root_user: "minioadmin", root_password: "minioadmin")
    )

    on_exit(fn -> Application.put_env(:maxio, :s3, original_s3) end)
    IAM.bootstrap_root()

    response =
      signed_iam_conn(
        %{
          "Action" => "GetAccessKeyLastUsed",
          "AccessKeyId" => "minioadmin"
        },
        access_key: "minioadmin",
        secret: "minioadmin"
      )
      |> call()

    assert response.status == 200
    assert response.resp_body =~ "<GetAccessKeyLastUsedResponse"
    assert xml_value(response.resp_body, "UserName") == "root"
    assert xml_value(response.resp_body, "ServiceName") == "iam"
    assert xml_value(response.resp_body, "Region") == @sigv4_region
    assert xml_value(response.resp_body, "LastUsedDate") =~ ~r/\A\d{4}-\d{2}-\d{2}T/
  end

  test "root manages IAM signing certificates through IAM Query XML" do
    user_name = unique_name("query-signing-user")
    other_user_name = unique_name("query-signing-other")

    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, _other_user} = IAM.create_user(user_name: other_user_name)

    {root_certificate_body, _private_key, _chain} = server_certificate_pems()
    {second_root_certificate_body, _private_key, _chain} = server_certificate_pems()
    {third_root_certificate_body, _private_key, _chain} = server_certificate_pems()
    {user_certificate_body, _private_key, _chain} = server_certificate_pems()
    {unsupported_certificate_body, _private_key, _chain} = server_certificate_pems()

    upload_root =
      signed_iam_form_conn(%{
        "Action" => "UploadSigningCertificate",
        "CertificateBody" => root_certificate_body
      })
      |> call()

    assert upload_root.status == 200
    assert upload_root.resp_body =~ "<UploadSigningCertificateResponse"
    assert xml_value(upload_root.resp_body, "UserName") == "root"
    assert xml_value(upload_root.resp_body, "Status") == "Active"

    assert xml_value(upload_root.resp_body, "CertificateBody") ==
             String.trim(root_certificate_body) <> "\n"

    assert xml_value(upload_root.resp_body, "UploadDate") =~ ~r/\A\d{4}-\d{2}-\d{2}T/
    root_certificate_id = xml_value(upload_root.resp_body, "CertificateId")
    assert root_certificate_id =~ ~r/\ATA[A-Z2-7]{22}\z/

    list_root =
      signed_iam_conn(%{
        "Action" => "ListSigningCertificates",
        "MaxItems" => "1"
      })
      |> call()

    assert list_root.status == 200
    assert list_root.resp_body =~ "<ListSigningCertificatesResponse"
    assert list_root.resp_body =~ "<Certificates>"
    assert list_root.resp_body =~ "<UserName>root</UserName>"
    assert xml_values(list_root.resp_body, "CertificateId") == [root_certificate_id]
    assert xml_values(list_root.resp_body, "Status") == ["Active"]
    assert xml_value(list_root.resp_body, "IsTruncated") == "false"

    duplicate =
      signed_iam_form_conn(%{
        "Action" => "UploadSigningCertificate",
        "CertificateBody" => root_certificate_body
      })
      |> call()

    assert duplicate.status == 409
    assert duplicate.resp_body =~ "<Code>DuplicateCertificate</Code>"

    second_upload =
      signed_iam_form_conn(%{
        "Action" => "UploadSigningCertificate",
        "CertificateBody" => second_root_certificate_body
      })
      |> call()

    assert second_upload.status == 200

    duplicate_at_quota =
      signed_iam_form_conn(%{
        "Action" => "UploadSigningCertificate",
        "CertificateBody" => root_certificate_body
      })
      |> call()

    assert duplicate_at_quota.status == 409
    assert duplicate_at_quota.resp_body =~ "<Code>DuplicateCertificate</Code>"

    over_quota =
      signed_iam_form_conn(%{
        "Action" => "UploadSigningCertificate",
        "CertificateBody" => third_root_certificate_body
      })
      |> call()

    assert over_quota.status == 409
    assert over_quota.resp_body =~ "<Code>LimitExceeded</Code>"

    upload_user =
      signed_iam_form_conn(%{
        "Action" => "UploadSigningCertificate",
        "UserName" => user_name,
        "CertificateBody" => user_certificate_body
      })
      |> call()

    assert upload_user.status == 200
    assert xml_value(upload_user.resp_body, "UserName") == user_name
    user_certificate_id = xml_value(upload_user.resp_body, "CertificateId")
    assert user_certificate_id != root_certificate_id

    list_user =
      signed_iam_conn(%{
        "Action" => "ListSigningCertificates",
        "UserName" => user_name
      })
      |> call()

    assert list_user.status == 200
    assert list_user.resp_body =~ "<UserName>#{user_name}</UserName>"
    assert xml_values(list_user.resp_body, "CertificateId") == [user_certificate_id]

    assert xml_values(list_user.resp_body, "CertificateBody") == [
             String.trim(user_certificate_body) <> "\n"
           ]

    bad_scope_update =
      signed_iam_conn(%{
        "Action" => "UpdateSigningCertificate",
        "UserName" => other_user_name,
        "CertificateId" => user_certificate_id,
        "Status" => "Inactive"
      })
      |> call()

    assert bad_scope_update.status == 404
    assert bad_scope_update.resp_body =~ "<Code>NoSuchEntity</Code>"

    update =
      signed_iam_conn(%{
        "Action" => "UpdateSigningCertificate",
        "UserName" => user_name,
        "CertificateId" => user_certificate_id,
        "Status" => "Inactive"
      })
      |> call()

    assert update.status == 200
    assert update.resp_body =~ "<UpdateSigningCertificateResponse"

    list_inactive =
      signed_iam_conn(%{
        "Action" => "ListSigningCertificates",
        "UserName" => user_name
      })
      |> call()

    assert list_inactive.status == 200
    assert xml_values(list_inactive.resp_body, "Status") == ["Inactive"]

    blocked_user_delete =
      signed_iam_conn(%{
        "Action" => "DeleteUser",
        "UserName" => user_name
      })
      |> call()

    assert blocked_user_delete.status == 409
    assert blocked_user_delete.resp_body =~ "<Code>DeleteConflict</Code>"

    delete =
      signed_iam_conn(%{
        "Action" => "DeleteSigningCertificate",
        "UserName" => user_name,
        "CertificateId" => user_certificate_id
      })
      |> call()

    assert delete.status == 200
    assert delete.resp_body =~ "<DeleteSigningCertificateResponse"

    empty_user =
      signed_iam_conn(%{
        "Action" => "ListSigningCertificates",
        "UserName" => user_name
      })
      |> call()

    assert empty_user.status == 200
    assert empty_user.resp_body =~ "<UserName>#{user_name}</UserName>"
    assert xml_values(empty_user.resp_body, "CertificateId") == []

    unsupported =
      signed_iam_form_conn(%{
        "Action" => "UploadSigningCertificate",
        "CertificateBody" => unsupported_certificate_body,
        "PrivateKey" => "not accepted"
      })
      |> call()

    assert unsupported.status == 400
    assert unsupported.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert unsupported.resp_body =~ "PrivateKey is not implemented"

    malformed =
      signed_iam_conn(%{
        "Action" => "UploadSigningCertificate",
        "UserName" => other_user_name,
        "CertificateBody" => "not-a-certificate"
      })
      |> call()

    assert malformed.status == 400
    assert malformed.resp_body =~ "<Code>MalformedCertificate</Code>"
  end

  test "root manages IAM SSH public keys through IAM Query XML" do
    user_name = unique_name("query-ssh-user")
    other_user_name = unique_name("query-ssh-other")

    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, _other_user} = IAM.create_user(user_name: other_user_name)

    key_body = ssh_public_key_body(1, "primary")

    upload =
      signed_iam_form_conn(%{
        "Action" => "UploadSSHPublicKey",
        "UserName" => user_name,
        "SSHPublicKeyBody" => key_body
      })
      |> call()

    assert upload.status == 200
    assert upload.resp_body =~ "<UploadSSHPublicKeyResponse"
    assert xml_value(upload.resp_body, "UserName") == user_name
    assert xml_value(upload.resp_body, "Status") == "Active"
    assert xml_value(upload.resp_body, "SSHPublicKeyBody") =~ ~r/\Assh-rsa /
    assert xml_value(upload.resp_body, "Fingerprint") =~ ~r/\A[0-9a-f]{2}(?::[0-9a-f]{2}){15}\z/
    ssh_public_key_id = xml_value(upload.resp_body, "SSHPublicKeyId")
    assert ssh_public_key_id =~ ~r/\AAPKA[A-Z2-7]{16}\z/

    duplicate =
      signed_iam_form_conn(%{
        "Action" => "UploadSSHPublicKey",
        "UserName" => user_name,
        "SSHPublicKeyBody" => key_body
      })
      |> call()

    assert duplicate.status == 400
    assert duplicate.resp_body =~ "<Code>DuplicateSSHPublicKey</Code>"

    list =
      signed_iam_conn(%{
        "Action" => "ListSSHPublicKeys",
        "UserName" => user_name
      })
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<ListSSHPublicKeysResponse"
    assert xml_values(list.resp_body, "SSHPublicKeyId") == [ssh_public_key_id]
    assert xml_values(list.resp_body, "Status") == ["Active"]
    assert xml_value(list.resp_body, "IsTruncated") == "false"

    get_pem =
      signed_iam_conn(%{
        "Action" => "GetSSHPublicKey",
        "UserName" => user_name,
        "SSHPublicKeyId" => ssh_public_key_id,
        "Encoding" => "PEM"
      })
      |> call()

    assert get_pem.status == 200
    assert get_pem.resp_body =~ "<GetSSHPublicKeyResponse"
    assert xml_value(get_pem.resp_body, "SSHPublicKeyBody") =~ "BEGIN PUBLIC KEY"

    missing_encoding =
      signed_iam_conn(%{
        "Action" => "GetSSHPublicKey",
        "UserName" => user_name,
        "SSHPublicKeyId" => ssh_public_key_id
      })
      |> call()

    assert missing_encoding.status == 400
    assert missing_encoding.resp_body =~ "<Code>InvalidParameterValue</Code>"

    invalid_encoding =
      signed_iam_conn(%{
        "Action" => "GetSSHPublicKey",
        "UserName" => user_name,
        "SSHPublicKeyId" => ssh_public_key_id,
        "Encoding" => "DER"
      })
      |> call()

    assert invalid_encoding.status == 400
    assert invalid_encoding.resp_body =~ "<Code>UnrecognizedPublicKeyEncoding</Code>"

    wrong_scope_update =
      signed_iam_conn(%{
        "Action" => "UpdateSSHPublicKey",
        "UserName" => other_user_name,
        "SSHPublicKeyId" => ssh_public_key_id,
        "Status" => "Inactive"
      })
      |> call()

    assert wrong_scope_update.status == 404
    assert wrong_scope_update.resp_body =~ "<Code>NoSuchEntity</Code>"

    update =
      signed_iam_conn(%{
        "Action" => "UpdateSSHPublicKey",
        "UserName" => user_name,
        "SSHPublicKeyId" => ssh_public_key_id,
        "Status" => "Inactive"
      })
      |> call()

    assert update.status == 200
    assert update.resp_body =~ "<UpdateSSHPublicKeyResponse"

    list_inactive =
      signed_iam_conn(%{
        "Action" => "ListSSHPublicKeys",
        "UserName" => user_name
      })
      |> call()

    assert list_inactive.status == 200
    assert xml_values(list_inactive.resp_body, "Status") == ["Inactive"]

    blocked_user_delete =
      signed_iam_conn(%{
        "Action" => "DeleteUser",
        "UserName" => user_name
      })
      |> call()

    assert blocked_user_delete.status == 409
    assert blocked_user_delete.resp_body =~ "<Code>DeleteConflict</Code>"

    delete =
      signed_iam_conn(%{
        "Action" => "DeleteSSHPublicKey",
        "UserName" => user_name,
        "SSHPublicKeyId" => ssh_public_key_id
      })
      |> call()

    assert delete.status == 200
    assert delete.resp_body =~ "<DeleteSSHPublicKeyResponse"

    empty =
      signed_iam_conn(%{
        "Action" => "ListSSHPublicKeys",
        "UserName" => user_name
      })
      |> call()

    assert empty.status == 200
    assert xml_values(empty.resp_body, "SSHPublicKeyId") == []

    malformed =
      signed_iam_form_conn(%{
        "Action" => "UploadSSHPublicKey",
        "UserName" => user_name,
        "SSHPublicKeyBody" => "ssh-ed25519 AAAAinvalid"
      })
      |> call()

    assert malformed.status == 400
    assert malformed.resp_body =~ "<Code>InvalidPublicKey</Code>"
  end

  test "root enforces IAM SSH public key quota through IAM Query XML" do
    user_name = unique_name("query-ssh-quota-user")
    assert {:ok, _user} = IAM.create_user(user_name: user_name)

    for index <- 1..5 do
      response =
        signed_iam_form_conn(%{
          "Action" => "UploadSSHPublicKey",
          "UserName" => user_name,
          "SSHPublicKeyBody" => ssh_public_key_body(index, "quota-#{index}")
        })
        |> call()

      assert response.status == 200
    end

    over_quota =
      signed_iam_form_conn(%{
        "Action" => "UploadSSHPublicKey",
        "UserName" => user_name,
        "SSHPublicKeyBody" => ssh_public_key_body(6, "quota-6")
      })
      |> call()

    assert over_quota.status == 409
    assert over_quota.resp_body =~ "<Code>LimitExceeded</Code>"

    first_page =
      signed_iam_conn(%{
        "Action" => "ListSSHPublicKeys",
        "UserName" => user_name,
        "MaxItems" => "2"
      })
      |> call()

    assert first_page.status == 200
    assert xml_value(first_page.resp_body, "IsTruncated") == "true"
    assert length(xml_values(first_page.resp_body, "SSHPublicKeyId")) == 2
    marker = xml_value(first_page.resp_body, "Marker")

    second_page =
      signed_iam_conn(%{
        "Action" => "ListSSHPublicKeys",
        "UserName" => user_name,
        "MaxItems" => "4",
        "Marker" => marker
      })
      |> call()

    assert second_page.status == 200
    assert xml_value(second_page.resp_body, "IsTruncated") == "false"
    assert length(xml_values(second_page.resp_body, "SSHPublicKeyId")) == 3
  end

  test "root accepts PEM SSH public keys and rejects malformed RSA SSH mpints" do
    user_name = unique_name("query-ssh-pem-user")
    assert {:ok, _user} = IAM.create_user(user_name: user_name)

    pem_upload =
      signed_iam_form_conn(%{
        "Action" => "UploadSSHPublicKey",
        "UserName" => user_name,
        "SSHPublicKeyBody" => rsa_public_key_pem_body(17)
      })
      |> call()

    assert pem_upload.status == 200
    ssh_public_key_id = xml_value(pem_upload.resp_body, "SSHPublicKeyId")
    assert xml_value(pem_upload.resp_body, "SSHPublicKeyBody") == ssh_public_key_body(17, "")
    pem_fingerprint = xml_value(pem_upload.resp_body, "Fingerprint")

    equivalent_ssh =
      signed_iam_form_conn(%{
        "Action" => "UploadSSHPublicKey",
        "UserName" => user_name,
        "SSHPublicKeyBody" => ssh_public_key_body(17, "equivalent")
      })
      |> call()

    assert equivalent_ssh.status == 400
    assert equivalent_ssh.resp_body =~ "<Code>DuplicateSSHPublicKey</Code>"

    get_ssh =
      signed_iam_conn(%{
        "Action" => "GetSSHPublicKey",
        "UserName" => user_name,
        "SSHPublicKeyId" => ssh_public_key_id,
        "Encoding" => "SSH"
      })
      |> call()

    assert get_ssh.status == 200
    assert xml_value(get_ssh.resp_body, "SSHPublicKeyBody") == ssh_public_key_body(17, "")
    assert xml_value(get_ssh.resp_body, "Fingerprint") == pem_fingerprint

    get_pem =
      signed_iam_conn(%{
        "Action" => "GetSSHPublicKey",
        "UserName" => user_name,
        "SSHPublicKeyId" => ssh_public_key_id,
        "Encoding" => "PEM"
      })
      |> call()

    assert get_pem.status == 200
    assert xml_value(get_pem.resp_body, "SSHPublicKeyBody") =~ "BEGIN PUBLIC KEY"

    n = ssh_public_key_modulus(29)

    invalid_bodies = [
      ssh_public_key_body_from_mpints(ssh_mpint(2), ssh_mpint(n), "even-exponent"),
      ssh_public_key_body_from_mpints(ssh_string(<<0, 1, 0, 1>>), ssh_mpint(n), "extra-zero"),
      ssh_public_key_body_from_mpints(
        ssh_mpint(65_537),
        ssh_string(:binary.encode_unsigned(n)),
        "negative-modulus"
      )
    ]

    for invalid_body <- invalid_bodies do
      invalid =
        signed_iam_form_conn(%{
          "Action" => "UploadSSHPublicKey",
          "UserName" => user_name,
          "SSHPublicKeyBody" => invalid_body
        })
        |> call()

      assert invalid.status == 400
      assert invalid.resp_body =~ "<Code>InvalidPublicKey</Code>"
    end
  end

  test "root manages IAM groups and memberships through IAM Query XML" do
    first_group = unique_name("a-query-group")
    second_group = unique_name("z-query-group")
    first_user = unique_name("a-query-member")
    second_user = unique_name("z-query-member")

    assert {:ok, _first_user} = IAM.create_user(user_name: first_user)
    assert {:ok, _second_user} = IAM.create_user(user_name: second_user)

    create =
      signed_iam_conn(%{
        "Action" => "CreateGroup",
        "Path" => "/",
        "GroupName" => first_group
      })
      |> call()

    assert create.status == 200
    assert create.resp_body =~ "<CreateGroupResponse"
    assert xml_value(create.resp_body, "Path") == "/"
    assert xml_value(create.resp_body, "GroupName") == first_group
    assert xml_value(create.resp_body, "Arn") == "arn:aws:iam:::group/#{first_group}"
    assert xml_value(create.resp_body, "GroupId") =~ ~r/\AAGPA[A-Z2-7]{16}\z/

    second_create =
      signed_iam_conn(%{
        "Action" => "CreateGroup",
        "GroupName" => second_group
      })
      |> call()

    assert second_create.status == 200

    list =
      signed_iam_conn(%{
        "Action" => "ListGroups",
        "MaxItems" => "1"
      })
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<ListGroupsResponse"
    assert xml_value(list.resp_body, "IsTruncated") == "true"
    assert xml_values(list.resp_body, "GroupName") == [first_group]
    marker = xml_value(list.resp_body, "Marker")

    list_next =
      signed_iam_conn(%{
        "Action" => "ListGroups",
        "MaxItems" => "1",
        "Marker" => marker
      })
      |> call()

    assert list_next.status == 200
    assert xml_value(list_next.resp_body, "IsTruncated") == "false"
    assert xml_values(list_next.resp_body, "GroupName") == [second_group]

    list_other_path =
      signed_iam_conn(%{
        "Action" => "ListGroups",
        "PathPrefix" => "/engineering/"
      })
      |> call()

    assert list_other_path.status == 200
    assert xml_value(list_other_path.resp_body, "IsTruncated") == "false"
    assert xml_values(list_other_path.resp_body, "GroupName") == []

    add_first =
      signed_iam_conn(%{
        "Action" => "AddUserToGroup",
        "GroupName" => first_group,
        "UserName" => first_user
      })
      |> call()

    assert add_first.status == 200
    assert add_first.resp_body =~ "<AddUserToGroupResponse"

    add_second =
      signed_iam_conn(%{
        "Action" => "AddUserToGroup",
        "GroupName" => first_group,
        "UserName" => second_user
      })
      |> call()

    assert add_second.status == 200

    duplicate_add =
      signed_iam_conn(%{
        "Action" => "AddUserToGroup",
        "GroupName" => first_group,
        "UserName" => first_user
      })
      |> call()

    assert duplicate_add.status == 200

    assert Enum.map(IAM.list_users_in_group(first_group), & &1.user_name) == [
             first_user,
             second_user
           ]

    get =
      signed_iam_conn(%{
        "Action" => "GetGroup",
        "GroupName" => first_group,
        "MaxItems" => "1"
      })
      |> call()

    assert get.status == 200
    assert get.resp_body =~ "<GetGroupResponse"
    assert xml_value(get.resp_body, "GroupName") == first_group
    assert xml_values(get.resp_body, "UserName") == [first_user]
    assert xml_value(get.resp_body, "IsTruncated") == "true"
    user_marker = xml_value(get.resp_body, "Marker")

    get_next =
      signed_iam_conn(%{
        "Action" => "GetGroup",
        "GroupName" => first_group,
        "MaxItems" => "1",
        "Marker" => user_marker
      })
      |> call()

    assert get_next.status == 200
    assert xml_value(get_next.resp_body, "IsTruncated") == "false"
    assert xml_values(get_next.resp_body, "UserName") == [second_user]

    add_second_group =
      signed_iam_conn(%{
        "Action" => "AddUserToGroup",
        "GroupName" => second_group,
        "UserName" => first_user
      })
      |> call()

    assert add_second_group.status == 200

    groups_for_user =
      signed_iam_conn(%{
        "Action" => "ListGroupsForUser",
        "UserName" => first_user,
        "MaxItems" => "1"
      })
      |> call()

    assert groups_for_user.status == 200
    assert groups_for_user.resp_body =~ "<ListGroupsForUserResponse"
    assert xml_value(groups_for_user.resp_body, "IsTruncated") == "true"
    assert xml_values(groups_for_user.resp_body, "GroupName") == [first_group]
    group_marker = xml_value(groups_for_user.resp_body, "Marker")

    groups_for_user_next =
      signed_iam_conn(%{
        "Action" => "ListGroupsForUser",
        "UserName" => first_user,
        "MaxItems" => "1",
        "Marker" => group_marker
      })
      |> call()

    assert groups_for_user_next.status == 200
    assert xml_value(groups_for_user_next.resp_body, "IsTruncated") == "false"
    assert xml_values(groups_for_user_next.resp_body, "GroupName") == [second_group]

    remove_first =
      signed_iam_conn(%{
        "Action" => "RemoveUserFromGroup",
        "GroupName" => first_group,
        "UserName" => first_user
      })
      |> call()

    assert remove_first.status == 200
    assert remove_first.resp_body =~ "<RemoveUserFromGroupResponse"

    delete_conflict =
      signed_iam_conn(%{
        "Action" => "DeleteGroup",
        "GroupName" => first_group
      })
      |> call()

    assert delete_conflict.status == 409
    assert delete_conflict.resp_body =~ "<Code>DeleteConflict</Code>"

    remove_second =
      signed_iam_conn(%{
        "Action" => "RemoveUserFromGroup",
        "GroupName" => first_group,
        "UserName" => second_user
      })
      |> call()

    assert remove_second.status == 200

    delete =
      signed_iam_conn(%{
        "Action" => "DeleteGroup",
        "GroupName" => first_group
      })
      |> call()

    assert delete.status == 200
    assert delete.resp_body =~ "<DeleteGroupResponse"

    missing =
      signed_iam_conn(%{
        "Action" => "GetGroup",
        "GroupName" => first_group
      })
      |> call()

    assert missing.status == 404
    assert missing.resp_body =~ "<Code>NoSuchEntity</Code>"
  end

  test "root renames IAM groups through IAM Query XML" do
    old_group = unique_name("query-rename-group")
    new_group = unique_name("query-renamed-group")
    duplicate_group = unique_name("query-rename-group-dupe")
    user_name = unique_name("query-rename-member")

    assert {:ok, _group} = IAM.create_group(group_name: old_group)
    assert {:ok, _duplicate} = IAM.create_group(group_name: duplicate_group)
    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert :ok = IAM.add_user_to_group(user_name, old_group)

    duplicate =
      signed_iam_conn(%{
        "Action" => "UpdateGroup",
        "GroupName" => old_group,
        "NewGroupName" => String.upcase(duplicate_group)
      })
      |> call()

    assert duplicate.status == 409
    assert duplicate.resp_body =~ "<Code>EntityAlreadyExists</Code>"

    invalid_path =
      signed_iam_conn(%{
        "Action" => "UpdateGroup",
        "GroupName" => old_group,
        "NewPath" => "/engineering/"
      })
      |> call()

    assert invalid_path.status == 400
    assert invalid_path.resp_body =~ "<Code>InvalidParameterValue</Code>"

    update =
      signed_iam_conn(%{
        "Action" => "UpdateGroup",
        "GroupName" => old_group,
        "NewGroupName" => new_group,
        "NewPath" => "/"
      })
      |> call()

    assert update.status == 200
    assert update.resp_body =~ "<UpdateGroupResponse"

    missing_old =
      signed_iam_conn(%{"Action" => "GetGroup", "GroupName" => old_group})
      |> call()

    assert missing_old.status == 404

    get_new =
      signed_iam_conn(%{"Action" => "GetGroup", "GroupName" => new_group})
      |> call()

    assert get_new.status == 200
    assert xml_value(get_new.resp_body, "GroupName") == new_group

    groups_for_user =
      signed_iam_conn(%{"Action" => "ListGroupsForUser", "UserName" => user_name})
      |> call()

    assert groups_for_user.status == 200
    assert xml_values(groups_for_user.resp_body, "GroupName") == [new_group]
  end

  test "root manages IAM roles and role tags through IAM Query XML" do
    first_role = unique_name("a-query-role")
    second_role = unique_name("z-query-role")
    boundary_policy_name = unique_name("RoleBoundaryPolicy")
    trust_policy_document = Jason.encode!(root_trust_policy())

    assert {:ok, boundary_policy} =
             IAM.create_managed_policy(
               name: boundary_policy_name,
               policy: identity_policy("s3:GetObject", "arn:aws:s3:::role-boundary/*")
             )

    create =
      signed_iam_conn(%{
        "Action" => "CreateRole",
        "Path" => "/",
        "RoleName" => first_role,
        "AssumeRolePolicyDocument" => trust_policy_document,
        "Description" => "initial-role",
        "MaxSessionDuration" => "7200",
        "PermissionsBoundary" => boundary_policy.policy_arn,
        "Tags.member.1.Key" => "team",
        "Tags.member.1.Value" => "core",
        "Tags.member.2.Key" => "env",
        "Tags.member.2.Value" => "dev"
      })
      |> call()

    assert create.status == 200
    assert create.resp_body =~ "<CreateRoleResponse"
    assert xml_value(create.resp_body, "Path") == "/"
    assert xml_value(create.resp_body, "RoleName") == first_role
    assert xml_value(create.resp_body, "Arn") == "arn:aws:iam:::role/#{first_role}"
    assert xml_value(create.resp_body, "RoleId") =~ ~r/\AAROA[A-Z2-7]{16}\z/
    assert xml_value(create.resp_body, "Description") == "initial-role"
    assert xml_value(create.resp_body, "MaxSessionDuration") == "7200"
    assert xml_value(create.resp_body, "PermissionsBoundaryType") == "PermissionsBoundaryPolicy"
    assert xml_value(create.resp_body, "PermissionsBoundaryArn") == boundary_policy.policy_arn

    assert xml_value(create.resp_body, "AssumeRolePolicyDocument")
           |> URI.decode()
           |> Jason.decode!() == root_trust_policy()

    assert xml_tag_pairs(create.resp_body) == [{"env", "dev"}, {"team", "core"}]
    assert {:ok, role} = IAM.get_role(first_role)
    assert role.description == "initial-role"
    assert role.tags == %{"env" => "dev", "team" => "core"}
    assert role.max_session_duration_seconds == 7200
    assert role.permissions_boundary_policy_arn == boundary_policy.policy_arn

    second_create =
      signed_iam_conn(%{
        "Action" => "CreateRole",
        "RoleName" => second_role,
        "AssumeRolePolicyDocument" => trust_policy_document
      })
      |> call()

    assert second_create.status == 200

    get =
      signed_iam_conn(%{
        "Action" => "GetRole",
        "RoleName" => first_role
      })
      |> call()

    assert get.status == 200
    assert get.resp_body =~ "<GetRoleResponse"
    assert xml_value(get.resp_body, "RoleName") == first_role
    assert xml_value(get.resp_body, "Description") == "initial-role"
    assert xml_value(get.resp_body, "MaxSessionDuration") == "7200"
    assert xml_value(get.resp_body, "PermissionsBoundaryArn") == boundary_policy.policy_arn
    assert xml_tag_pairs(get.resp_body) == [{"env", "dev"}, {"team", "core"}]

    update_role =
      signed_iam_conn(%{
        "Action" => "UpdateRole",
        "RoleName" => first_role,
        "Description" => "updated-role",
        "MaxSessionDuration" => "3600"
      })
      |> call()

    assert update_role.status == 200
    assert update_role.resp_body =~ "<UpdateRoleResponse"

    get_after_duration =
      signed_iam_conn(%{
        "Action" => "GetRole",
        "RoleName" => first_role
      })
      |> call()

    assert get_after_duration.status == 200
    assert xml_value(get_after_duration.resp_body, "Description") == "updated-role"
    assert xml_value(get_after_duration.resp_body, "MaxSessionDuration") == "3600"

    invalid_update_description =
      signed_iam_conn(%{
        "Action" => "UpdateRole",
        "RoleName" => first_role,
        "Description" => String.duplicate("d", 1001)
      })
      |> call()

    assert invalid_update_description.status == 400
    assert invalid_update_description.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_update_description.resp_body =~ "Description"

    alternate_trust_policy =
      trust_policy_for_principal(IAM.user_arn(unique_name("trusted-role-principal")))

    update_trust =
      signed_iam_conn(%{
        "Action" => "UpdateAssumeRolePolicy",
        "RoleName" => first_role,
        "PolicyDocument" => Jason.encode!(alternate_trust_policy)
      })
      |> call()

    assert update_trust.status == 200
    assert update_trust.resp_body =~ "<UpdateAssumeRolePolicyResponse"

    get_after_trust =
      signed_iam_conn(%{
        "Action" => "GetRole",
        "RoleName" => first_role
      })
      |> call()

    assert get_after_trust.status == 200

    assert xml_value(get_after_trust.resp_body, "AssumeRolePolicyDocument")
           |> URI.decode()
           |> Jason.decode!() == alternate_trust_policy

    invalid_update_duration =
      signed_iam_conn(%{
        "Action" => "UpdateRole",
        "RoleName" => first_role,
        "MaxSessionDuration" => "899"
      })
      |> call()

    assert invalid_update_duration.status == 400
    assert invalid_update_duration.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_update_duration.resp_body =~ "MaxSessionDuration"

    malformed_update_trust =
      signed_iam_conn(%{
        "Action" => "UpdateAssumeRolePolicy",
        "RoleName" => first_role,
        "PolicyDocument" => ~s({"Statement":)
      })
      |> call()

    assert malformed_update_trust.status == 400
    assert malformed_update_trust.resp_body =~ "<Code>MalformedPolicyDocument</Code>"

    duplicate_key_update_trust =
      signed_iam_conn(%{
        "Action" => "UpdateAssumeRolePolicy",
        "RoleName" => first_role,
        "PolicyDocument" =>
          ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"sts:AssumeRole","Action":"sts:TagSession"}})
      })
      |> call()

    assert duplicate_key_update_trust.status == 400
    assert duplicate_key_update_trust.resp_body =~ "<Code>MalformedPolicyDocument</Code>"

    invalid_update_trust =
      signed_iam_conn(%{
        "Action" => "UpdateAssumeRolePolicy",
        "RoleName" => first_role,
        "PolicyDocument" =>
          ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject"}})
      })
      |> call()

    assert invalid_update_trust.status == 400
    assert invalid_update_trust.resp_body =~ "<Code>MalformedPolicyDocument</Code>"

    get_after_rejected_trust =
      signed_iam_conn(%{
        "Action" => "GetRole",
        "RoleName" => first_role
      })
      |> call()

    assert get_after_rejected_trust.status == 200
    assert xml_value(get_after_rejected_trust.resp_body, "Description") == "updated-role"

    assert xml_value(get_after_rejected_trust.resp_body, "AssumeRolePolicyDocument")
           |> URI.decode()
           |> Jason.decode!() == alternate_trust_policy

    list =
      signed_iam_conn(%{
        "Action" => "ListRoles",
        "MaxItems" => "1"
      })
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<ListRolesResponse"
    assert xml_value(list.resp_body, "IsTruncated") == "true"
    assert xml_values(list.resp_body, "RoleName") == [first_role]
    assert xml_tag_pairs(list.resp_body) == []
    marker = xml_value(list.resp_body, "Marker")

    list_next =
      signed_iam_conn(%{
        "Action" => "ListRoles",
        "MaxItems" => "1",
        "Marker" => marker
      })
      |> call()

    assert list_next.status == 200
    assert xml_value(list_next.resp_body, "IsTruncated") == "false"
    assert xml_values(list_next.resp_body, "RoleName") == [second_role]

    list_other_path =
      signed_iam_conn(%{
        "Action" => "ListRoles",
        "PathPrefix" => "/engineering/"
      })
      |> call()

    assert list_other_path.status == 200
    assert xml_value(list_other_path.resp_body, "IsTruncated") == "false"
    assert xml_values(list_other_path.resp_body, "RoleName") == []

    list_tags =
      signed_iam_conn(%{
        "Action" => "ListRoleTags",
        "RoleName" => first_role
      })
      |> call()

    assert list_tags.status == 200
    assert list_tags.resp_body =~ "<ListRoleTagsResponse"
    assert xml_value(list_tags.resp_body, "IsTruncated") == "false"
    assert xml_tag_pairs(list_tags.resp_body) == [{"env", "dev"}, {"team", "core"}]

    first_tag_page =
      signed_iam_conn(%{
        "Action" => "ListRoleTags",
        "RoleName" => first_role,
        "MaxItems" => "1"
      })
      |> call()

    assert first_tag_page.status == 200
    assert xml_value(first_tag_page.resp_body, "IsTruncated") == "true"
    assert xml_tag_pairs(first_tag_page.resp_body) == [{"env", "dev"}]
    tag_marker = xml_value(first_tag_page.resp_body, "Marker")

    second_tag_page =
      signed_iam_conn(%{
        "Action" => "ListRoleTags",
        "RoleName" => first_role,
        "MaxItems" => "1",
        "Marker" => tag_marker
      })
      |> call()

    assert second_tag_page.status == 200
    assert xml_value(second_tag_page.resp_body, "IsTruncated") == "false"
    assert xml_tag_pairs(second_tag_page.resp_body) == [{"team", "core"}]

    tag_update =
      signed_iam_conn(%{
        "Action" => "TagRole",
        "RoleName" => first_role,
        "Tags.member.1.Key" => "ENV",
        "Tags.member.1.Value" => "prod",
        "Tags.member.2.Key" => "stage",
        "Tags.member.2.Value" => ""
      })
      |> call()

    assert tag_update.status == 200
    assert tag_update.resp_body =~ "<TagRoleResponse"
    assert {:ok, role} = IAM.get_role(first_role)
    assert role.tags == %{"ENV" => "prod", "stage" => "", "team" => "core"}

    untag =
      signed_iam_conn(%{
        "Action" => "UntagRole",
        "RoleName" => first_role,
        "TagKeys.member.1" => "env",
        "TagKeys.member.2" => "TEAM"
      })
      |> call()

    assert untag.status == 200
    assert untag.resp_body =~ "<UntagRoleResponse"
    assert {:ok, role} = IAM.get_role(first_role)
    assert role.tags == %{"stage" => ""}

    assert :ok =
             IAM.put_role_policy_strict(
               first_role,
               "delete-blocker",
               identity_policy("s3:GetObject", "arn:aws:s3:::delete-blocker/*")
             )

    delete_conflict =
      signed_iam_conn(%{
        "Action" => "DeleteRole",
        "RoleName" => first_role
      })
      |> call()

    assert delete_conflict.status == 409
    assert delete_conflict.resp_body =~ "<Code>DeleteConflict</Code>"

    assert :ok = IAM.delete_role_policy_strict(first_role, "delete-blocker")

    delete =
      signed_iam_conn(%{
        "Action" => "DeleteRole",
        "RoleName" => first_role
      })
      |> call()

    assert delete.status == 200
    assert delete.resp_body =~ "<DeleteRoleResponse"

    missing =
      signed_iam_conn(%{
        "Action" => "GetRole",
        "RoleName" => first_role
      })
      |> call()

    assert missing.status == 404
    assert missing.resp_body =~ "<Code>NoSuchEntity</Code>"
  end

  test "root manages IAM instance profiles and role membership through IAM Query XML" do
    first_profile = unique_name("a-query-profile")
    second_profile = unique_name("z-query-profile")
    role_name = unique_name("profile-role")
    other_role_name = unique_name("profile-other-role")

    assert {:ok, _role} = IAM.create_role(role_name: role_name, trust_policy: root_trust_policy())

    create =
      signed_iam_conn(%{
        "Action" => "CreateInstanceProfile",
        "Path" => "/",
        "InstanceProfileName" => first_profile,
        "Tags.member.1.Key" => "CostCenter",
        "Tags.member.1.Value" => "42",
        "Tags.member.2.Key" => "costcenter",
        "Tags.member.2.Value" => "43"
      })
      |> call()

    assert create.status == 200
    assert create.resp_body =~ "<CreateInstanceProfileResponse"
    assert xml_value(create.resp_body, "Path") == "/"
    assert xml_value(create.resp_body, "InstanceProfileName") == first_profile
    assert xml_value(create.resp_body, "Arn") == "arn:aws:iam:::instance-profile/#{first_profile}"
    assert xml_value(create.resp_body, "InstanceProfileId") =~ ~r/\AAIPA[A-Z2-7]{16}\z/
    assert xml_tag_pairs(create.resp_body) == [{"CostCenter", "42"}, {"costcenter", "43"}]
    assert xml_values(create.resp_body, "RoleName") == []

    assert {:ok, profile} = IAM.get_instance_profile(first_profile)
    assert profile.instance_profile_name == first_profile
    assert profile.tags == %{"CostCenter" => "42", "costcenter" => "43"}
    assert profile.roles == []

    second_create =
      signed_iam_conn(%{
        "Action" => "CreateInstanceProfile",
        "InstanceProfileName" => second_profile
      })
      |> call()

    assert second_create.status == 200

    duplicate =
      signed_iam_conn(%{
        "Action" => "CreateInstanceProfile",
        "InstanceProfileName" => first_profile
      })
      |> call()

    assert duplicate.status == 409
    assert duplicate.resp_body =~ "<Code>EntityAlreadyExists</Code>"

    summary =
      signed_iam_conn(%{"Action" => "GetAccountSummary"})
      |> call()

    assert summary.status == 200
    summary_map = xml_summary_map(summary.resp_body)
    assert summary_map["InstanceProfiles"] == 2
    assert summary_map["InstanceProfilesQuota"] == 1000

    add_role =
      signed_iam_conn(%{
        "Action" => "AddRoleToInstanceProfile",
        "InstanceProfileName" => first_profile,
        "RoleName" => role_name
      })
      |> call()

    assert add_role.status == 200
    assert add_role.resp_body =~ "<AddRoleToInstanceProfileResponse"

    add_same_role =
      signed_iam_conn(%{
        "Action" => "AddRoleToInstanceProfile",
        "InstanceProfileName" => first_profile,
        "RoleName" => role_name
      })
      |> call()

    assert add_same_role.status == 409
    assert add_same_role.resp_body =~ "<Code>EntityAlreadyExists</Code>"

    get =
      signed_iam_conn(%{
        "Action" => "GetInstanceProfile",
        "InstanceProfileName" => first_profile
      })
      |> call()

    assert get.status == 200
    assert get.resp_body =~ "<GetInstanceProfileResponse"
    assert xml_value(get.resp_body, "InstanceProfileName") == first_profile
    assert xml_values(get.resp_body, "RoleName") == [role_name]
    assert xml_value(get.resp_body, "RoleId") =~ ~r/\AAROA[A-Z2-7]{16}\z/
    assert xml_tag_pairs(get.resp_body) == [{"CostCenter", "42"}, {"costcenter", "43"}]

    list =
      signed_iam_conn(%{
        "Action" => "ListInstanceProfiles",
        "MaxItems" => "1"
      })
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<ListInstanceProfilesResponse"
    assert xml_value(list.resp_body, "IsTruncated") == "true"
    assert xml_values(list.resp_body, "InstanceProfileName") == [first_profile]
    marker = xml_value(list.resp_body, "Marker")

    list_next =
      signed_iam_conn(%{
        "Action" => "ListInstanceProfiles",
        "MaxItems" => "1",
        "Marker" => marker
      })
      |> call()

    assert list_next.status == 200
    assert xml_value(list_next.resp_body, "IsTruncated") == "false"
    assert xml_values(list_next.resp_body, "InstanceProfileName") == [second_profile]

    list_other_path =
      signed_iam_conn(%{
        "Action" => "ListInstanceProfiles",
        "PathPrefix" => "/engineering/"
      })
      |> call()

    assert list_other_path.status == 200
    assert xml_values(list_other_path.resp_body, "InstanceProfileName") == []

    path_profile = unique_name("path-profile")

    path_create =
      signed_iam_conn(%{
        "Action" => "CreateInstanceProfile",
        "Path" => "/application_abc/team!prod/",
        "InstanceProfileName" => path_profile
      })
      |> call()

    assert path_create.status == 200
    assert xml_value(path_create.resp_body, "Path") == "/application_abc/team!prod/"

    assert xml_value(path_create.resp_body, "Arn") ==
             "arn:aws:iam:::instance-profile/application_abc/team!prod/#{path_profile}"

    list_path =
      signed_iam_conn(%{
        "Action" => "ListInstanceProfiles",
        "PathPrefix" => "/application_abc"
      })
      |> call()

    assert list_path.status == 200
    assert xml_values(list_path.resp_body, "InstanceProfileName") == [path_profile]

    list_missing_path =
      signed_iam_conn(%{
        "Action" => "ListInstanceProfiles",
        "PathPrefix" => "/missing/"
      })
      |> call()

    assert list_missing_path.status == 200
    assert xml_values(list_missing_path.resp_body, "InstanceProfileName") == []

    repeated_slash_profile = unique_name("slash-profile")

    repeated_slash_create =
      signed_iam_conn(%{
        "Action" => "CreateInstanceProfile",
        "Path" => "/application_abc//",
        "InstanceProfileName" => repeated_slash_profile
      })
      |> call()

    assert repeated_slash_create.status == 200
    assert xml_value(repeated_slash_create.resp_body, "Path") == "/application_abc//"

    assert xml_value(repeated_slash_create.resp_body, "Arn") ==
             "arn:aws:iam:::instance-profile/application_abc//#{repeated_slash_profile}"

    for_role =
      signed_iam_conn(%{
        "Action" => "ListInstanceProfilesForRole",
        "RoleName" => role_name
      })
      |> call()

    assert for_role.status == 200
    assert for_role.resp_body =~ "<ListInstanceProfilesForRoleResponse"
    assert xml_values(for_role.resp_body, "InstanceProfileName") == [first_profile]

    list_tags =
      signed_iam_conn(%{
        "Action" => "ListInstanceProfileTags",
        "InstanceProfileName" => first_profile
      })
      |> call()

    assert list_tags.status == 200
    assert list_tags.resp_body =~ "<ListInstanceProfileTagsResponse"
    assert xml_tag_pairs(list_tags.resp_body) == [{"CostCenter", "42"}, {"costcenter", "43"}]

    tag_update =
      signed_iam_conn(%{
        "Action" => "TagInstanceProfile",
        "InstanceProfileName" => first_profile,
        "Tags.member.1.Key" => "ENV",
        "Tags.member.1.Value" => "prod",
        "Tags.member.2.Key" => "env",
        "Tags.member.2.Value" => "dev",
        "Tags.member.3.Key" => "stage",
        "Tags.member.3.Value" => ""
      })
      |> call()

    assert tag_update.status == 200
    assert tag_update.resp_body =~ "<TagInstanceProfileResponse"
    assert {:ok, profile} = IAM.get_instance_profile(first_profile)

    assert profile.tags == %{
             "CostCenter" => "42",
             "ENV" => "prod",
             "costcenter" => "43",
             "env" => "dev",
             "stage" => ""
           }

    untag =
      signed_iam_conn(%{
        "Action" => "UntagInstanceProfile",
        "InstanceProfileName" => first_profile,
        "TagKeys.member.1" => "env",
        "TagKeys.member.2" => "CostCenter"
      })
      |> call()

    assert untag.status == 200
    assert untag.resp_body =~ "<UntagInstanceProfileResponse"
    assert {:ok, profile} = IAM.get_instance_profile(first_profile)
    assert profile.tags == %{"ENV" => "prod", "costcenter" => "43", "stage" => ""}

    delete_role_conflict =
      signed_iam_conn(%{
        "Action" => "DeleteRole",
        "RoleName" => role_name
      })
      |> call()

    assert delete_role_conflict.status == 409
    assert delete_role_conflict.resp_body =~ "<Code>DeleteConflict</Code>"

    delete_profile_conflict =
      signed_iam_conn(%{
        "Action" => "DeleteInstanceProfile",
        "InstanceProfileName" => first_profile
      })
      |> call()

    assert delete_profile_conflict.status == 409
    assert delete_profile_conflict.resp_body =~ "<Code>DeleteConflict</Code>"

    assert {:ok, _other_role} =
             IAM.create_role(role_name: other_role_name, trust_policy: root_trust_policy())

    add_second_role =
      signed_iam_conn(%{
        "Action" => "AddRoleToInstanceProfile",
        "InstanceProfileName" => first_profile,
        "RoleName" => other_role_name
      })
      |> call()

    assert add_second_role.status == 409
    assert add_second_role.resp_body =~ "<Code>LimitExceeded</Code>"

    remove_role =
      signed_iam_conn(%{
        "Action" => "RemoveRoleFromInstanceProfile",
        "InstanceProfileName" => first_profile,
        "RoleName" => role_name
      })
      |> call()

    assert remove_role.status == 200
    assert remove_role.resp_body =~ "<RemoveRoleFromInstanceProfileResponse"

    remove_missing =
      signed_iam_conn(%{
        "Action" => "RemoveRoleFromInstanceProfile",
        "InstanceProfileName" => first_profile,
        "RoleName" => role_name
      })
      |> call()

    assert remove_missing.status == 404
    assert remove_missing.resp_body =~ "<Code>NoSuchEntity</Code>"

    delete =
      signed_iam_conn(%{
        "Action" => "DeleteInstanceProfile",
        "InstanceProfileName" => first_profile
      })
      |> call()

    assert delete.status == 200
    assert delete.resp_body =~ "<DeleteInstanceProfileResponse"

    missing =
      signed_iam_conn(%{
        "Action" => "GetInstanceProfile",
        "InstanceProfileName" => first_profile
      })
      |> call()

    assert missing.status == 404
    assert missing.resp_body =~ "<Code>NoSuchEntity</Code>"

    unsupported =
      signed_iam_conn(%{"Action" => "ListInstanceProfiles", "Foo" => "bar"})
      |> call()

    assert unsupported.status == 400
    assert unsupported.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert unsupported.resp_body =~ "Foo is not implemented"

    user_name = unique_name("profile-query-denied")
    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, key} = IAM.create_access_key(user_name: user_name, secret_key: "profile-secret")

    denied =
      signed_iam_conn(%{"Action" => "ListInstanceProfiles"},
        access_key: key.access_key_id,
        secret: "profile-secret"
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"
  end

  test "AddRoleToInstanceProfile is atomic under concurrent Query requests" do
    profile_name = unique_name("race-profile")
    first_role = unique_name("race-profile-role-a")
    second_role = unique_name("race-profile-role-b")

    assert {:ok, _profile} = IAM.create_instance_profile(instance_profile_name: profile_name)

    assert {:ok, _role} =
             IAM.create_role(role_name: first_role, trust_policy: root_trust_policy())

    assert {:ok, _role} =
             IAM.create_role(role_name: second_role, trust_policy: root_trust_policy())

    results =
      [first_role, second_role]
      |> Task.async_stream(
        fn role_name ->
          response =
            signed_iam_conn(%{
              "Action" => "AddRoleToInstanceProfile",
              "InstanceProfileName" => profile_name,
              "RoleName" => role_name
            })
            |> call()

          {response.status, response.resp_body}
        end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, fn {status, _body} -> status == 200 end) == 1

    assert [{409, rejected_body}] =
             Enum.filter(results, fn {status, _body} -> status == 409 end)

    assert rejected_body =~ "<Code>LimitExceeded</Code>"

    get =
      signed_iam_conn(%{
        "Action" => "GetInstanceProfile",
        "InstanceProfileName" => profile_name
      })
      |> call()

    assert get.status == 200
    assert [attached_role] = xml_values(get.resp_body, "RoleName")
    assert attached_role in [first_role, second_role]
  end

  test "AddRoleToInstanceProfile and DeleteInstanceProfile serialize role membership" do
    profile_name = unique_name("delete-race-profile")
    role_name = unique_name("delete-race-profile-role")

    assert {:ok, _profile} = IAM.create_instance_profile(instance_profile_name: profile_name)
    assert {:ok, _role} = IAM.create_role(role_name: role_name, trust_policy: root_trust_policy())

    results =
      [
        fn ->
          response =
            signed_iam_conn(%{
              "Action" => "AddRoleToInstanceProfile",
              "InstanceProfileName" => profile_name,
              "RoleName" => role_name
            })
            |> call()

          {:add_role, response.status, response.resp_body}
        end,
        fn ->
          response =
            signed_iam_conn(%{
              "Action" => "DeleteInstanceProfile",
              "InstanceProfileName" => profile_name
            })
            |> call()

          {:delete_profile, response.status, response.resp_body}
        end
      ]
      |> Task.async_stream(fn fun -> fun.() end, max_concurrency: 2, timeout: :infinity)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, fn {_action, status, _body} -> status == 200 end) == 1

    add_result = Enum.find(results, fn {action, _status, _body} -> action == :add_role end)

    delete_result =
      Enum.find(results, fn {action, _status, _body} -> action == :delete_profile end)

    case {add_result, delete_result} do
      {{:add_role, 200, _}, {:delete_profile, 409, delete_body}} ->
        assert delete_body =~ "<Code>DeleteConflict</Code>"

        get =
          signed_iam_conn(%{
            "Action" => "GetInstanceProfile",
            "InstanceProfileName" => profile_name
          })
          |> call()

        assert get.status == 200
        assert xml_values(get.resp_body, "RoleName") == [role_name]

      {{:add_role, 404, add_body}, {:delete_profile, 200, _}} ->
        assert add_body =~ "<Code>NoSuchEntity</Code>"

        get =
          signed_iam_conn(%{
            "Action" => "GetInstanceProfile",
            "InstanceProfileName" => profile_name
          })
          |> call()

        assert get.status == 404
        assert get.resp_body =~ "<Code>NoSuchEntity</Code>"

      other ->
        flunk("unexpected add/delete race result: #{inspect(other)}")
    end
  end

  test "root manages IAM user, group, and role inline policies through IAM Query XML" do
    user_name = unique_name("inline-user")
    group_name = unique_name("inline-group")
    role_name = unique_name("inline-role")
    first_policy = "AInlinePolicy"
    second_policy = "ZInlinePolicy"

    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, _group} = IAM.create_group(group_name: group_name)
    assert {:ok, _role} = IAM.create_role(role_name: role_name, trust_policy: root_trust_policy())

    put_user =
      signed_iam_conn(%{
        "Action" => "PutUserPolicy",
        "UserName" => user_name,
        "PolicyName" => first_policy,
        "PolicyDocument" => identity_policy("s3:GetObject", "arn:aws:s3:::inline-user/*")
      })
      |> call()

    assert put_user.status == 200
    assert put_user.resp_body =~ "<PutUserPolicyResponse"

    get_user =
      signed_iam_conn(%{
        "Action" => "GetUserPolicy",
        "UserName" => user_name,
        "PolicyName" => first_policy
      })
      |> call()

    assert get_user.status == 200
    assert xml_value(get_user.resp_body, "UserName") == user_name
    assert xml_value(get_user.resp_body, "PolicyName") == first_policy
    assert xml_value(get_user.resp_body, "PolicyDocument") =~ "%7B"

    assert get_in(decoded_policy_document(get_user.resp_body), ["Statement", "Action"]) ==
             "s3:GetObject"

    replace_user =
      signed_iam_conn(%{
        "Action" => "PutUserPolicy",
        "UserName" => user_name,
        "PolicyName" => first_policy,
        "PolicyDocument" => identity_policy("s3:PutObject", "arn:aws:s3:::inline-user/*")
      })
      |> call()

    assert replace_user.status == 200

    get_replaced_user =
      signed_iam_conn(%{
        "Action" => "GetUserPolicy",
        "UserName" => user_name,
        "PolicyName" => first_policy
      })
      |> call()

    assert get_replaced_user.status == 200

    assert get_in(decoded_policy_document(get_replaced_user.resp_body), ["Statement", "Action"]) ==
             "s3:PutObject"

    put_second_user =
      signed_iam_conn(%{
        "Action" => "PutUserPolicy",
        "UserName" => user_name,
        "PolicyName" => second_policy,
        "PolicyDocument" => identity_policy("s3:ListBucket", "arn:aws:s3:::inline-user")
      })
      |> call()

    assert put_second_user.status == 200

    list_user =
      signed_iam_conn(%{
        "Action" => "ListUserPolicies",
        "UserName" => user_name,
        "MaxItems" => "1"
      })
      |> call()

    assert list_user.status == 200
    assert list_user.resp_body =~ "<ListUserPoliciesResponse"
    assert xml_value(list_user.resp_body, "IsTruncated") == "true"
    assert xml_values(list_user.resp_body, "member") == [first_policy]
    user_marker = xml_value(list_user.resp_body, "Marker")

    list_user_next =
      signed_iam_conn(%{
        "Action" => "ListUserPolicies",
        "UserName" => user_name,
        "MaxItems" => "1",
        "Marker" => user_marker
      })
      |> call()

    assert list_user_next.status == 200
    assert xml_value(list_user_next.resp_body, "IsTruncated") == "false"
    assert xml_values(list_user_next.resp_body, "member") == [second_policy]

    put_group =
      signed_iam_conn(%{
        "Action" => "PutGroupPolicy",
        "GroupName" => group_name,
        "PolicyName" => first_policy,
        "PolicyDocument" => identity_policy("s3:GetObject", "arn:aws:s3:::inline-group/*")
      })
      |> call()

    assert put_group.status == 200
    assert put_group.resp_body =~ "<PutGroupPolicyResponse"

    put_second_group =
      signed_iam_conn(%{
        "Action" => "PutGroupPolicy",
        "GroupName" => group_name,
        "PolicyName" => second_policy,
        "PolicyDocument" => identity_policy("s3:DeleteObject", "arn:aws:s3:::inline-group/*")
      })
      |> call()

    assert put_second_group.status == 200

    get_group =
      signed_iam_conn(%{
        "Action" => "GetGroupPolicy",
        "GroupName" => group_name,
        "PolicyName" => first_policy
      })
      |> call()

    assert get_group.status == 200
    assert xml_value(get_group.resp_body, "GroupName") == group_name
    assert xml_value(get_group.resp_body, "PolicyName") == first_policy

    assert get_in(decoded_policy_document(get_group.resp_body), ["Statement", "Action"]) ==
             "s3:GetObject"

    list_group =
      signed_iam_conn(%{
        "Action" => "ListGroupPolicies",
        "GroupName" => group_name,
        "MaxItems" => "1"
      })
      |> call()

    assert list_group.status == 200
    assert list_group.resp_body =~ "<ListGroupPoliciesResponse"
    assert xml_value(list_group.resp_body, "IsTruncated") == "true"
    assert xml_values(list_group.resp_body, "member") == [first_policy]
    group_marker = xml_value(list_group.resp_body, "Marker")

    list_group_next =
      signed_iam_conn(%{
        "Action" => "ListGroupPolicies",
        "GroupName" => group_name,
        "MaxItems" => "1",
        "Marker" => group_marker
      })
      |> call()

    assert list_group_next.status == 200
    assert xml_value(list_group_next.resp_body, "IsTruncated") == "false"
    assert xml_values(list_group_next.resp_body, "member") == [second_policy]

    put_role =
      signed_iam_conn(%{
        "Action" => "PutRolePolicy",
        "RoleName" => role_name,
        "PolicyName" => first_policy,
        "PolicyDocument" => identity_policy("s3:GetObject", "arn:aws:s3:::inline-role/*")
      })
      |> call()

    assert put_role.status == 200
    assert put_role.resp_body =~ "<PutRolePolicyResponse"

    replace_role =
      signed_iam_conn(%{
        "Action" => "PutRolePolicy",
        "RoleName" => role_name,
        "PolicyName" => first_policy,
        "PolicyDocument" => identity_policy("s3:PutObject", "arn:aws:s3:::inline-role/*")
      })
      |> call()

    assert replace_role.status == 200

    put_second_role =
      signed_iam_conn(%{
        "Action" => "PutRolePolicy",
        "RoleName" => role_name,
        "PolicyName" => second_policy,
        "PolicyDocument" => identity_policy("s3:ListBucket", "arn:aws:s3:::inline-role")
      })
      |> call()

    assert put_second_role.status == 200

    get_role =
      signed_iam_conn(%{
        "Action" => "GetRolePolicy",
        "RoleName" => role_name,
        "PolicyName" => first_policy
      })
      |> call()

    assert get_role.status == 200
    assert xml_value(get_role.resp_body, "RoleName") == role_name
    assert xml_value(get_role.resp_body, "PolicyName") == first_policy

    assert get_in(decoded_policy_document(get_role.resp_body), ["Statement", "Action"]) ==
             "s3:PutObject"

    list_role =
      signed_iam_conn(%{
        "Action" => "ListRolePolicies",
        "RoleName" => role_name,
        "MaxItems" => "1"
      })
      |> call()

    assert list_role.status == 200
    assert list_role.resp_body =~ "<ListRolePoliciesResponse"
    assert xml_value(list_role.resp_body, "IsTruncated") == "true"
    assert xml_values(list_role.resp_body, "member") == [first_policy]
    role_marker = xml_value(list_role.resp_body, "Marker")

    list_role_next =
      signed_iam_conn(%{
        "Action" => "ListRolePolicies",
        "RoleName" => role_name,
        "MaxItems" => "1",
        "Marker" => role_marker
      })
      |> call()

    assert list_role_next.status == 200
    assert xml_value(list_role_next.resp_body, "IsTruncated") == "false"
    assert xml_values(list_role_next.resp_body, "member") == [second_policy]

    delete_user =
      signed_iam_conn(%{
        "Action" => "DeleteUserPolicy",
        "UserName" => user_name,
        "PolicyName" => first_policy
      })
      |> call()

    assert delete_user.status == 200
    assert delete_user.resp_body =~ "<DeleteUserPolicyResponse"

    deleted_user_get =
      signed_iam_conn(%{
        "Action" => "GetUserPolicy",
        "UserName" => user_name,
        "PolicyName" => first_policy
      })
      |> call()

    assert deleted_user_get.status == 404
    assert deleted_user_get.resp_body =~ "<Code>NoSuchEntity</Code>"

    delete_group =
      signed_iam_conn(%{
        "Action" => "DeleteGroupPolicy",
        "GroupName" => group_name,
        "PolicyName" => first_policy
      })
      |> call()

    assert delete_group.status == 200
    assert delete_group.resp_body =~ "<DeleteGroupPolicyResponse"

    deleted_group_get =
      signed_iam_conn(%{
        "Action" => "GetGroupPolicy",
        "GroupName" => group_name,
        "PolicyName" => first_policy
      })
      |> call()

    assert deleted_group_get.status == 404
    assert deleted_group_get.resp_body =~ "<Code>NoSuchEntity</Code>"

    delete_role =
      signed_iam_conn(%{
        "Action" => "DeleteRolePolicy",
        "RoleName" => role_name,
        "PolicyName" => first_policy
      })
      |> call()

    assert delete_role.status == 200
    assert delete_role.resp_body =~ "<DeleteRolePolicyResponse"

    deleted_role_get =
      signed_iam_conn(%{
        "Action" => "GetRolePolicy",
        "RoleName" => role_name,
        "PolicyName" => first_policy
      })
      |> call()

    assert deleted_role_get.status == 404
    assert deleted_role_get.resp_body =~ "<Code>NoSuchEntity</Code>"
  end

  test "IAM inline policy Query API accepts signed POST forms" do
    user_name = unique_name("post-policy-user")
    group_name = unique_name("post-policy-group")
    role_name = unique_name("post-policy-role")
    policy_name = "PostInlinePolicy"

    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, _group} = IAM.create_group(group_name: group_name)
    assert {:ok, _role} = IAM.create_role(role_name: role_name, trust_policy: root_trust_policy())

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "PutUserPolicy",
               "UserName" => user_name,
               "PolicyName" => policy_name,
               "PolicyDocument" => identity_policy("s3:GetObject", "arn:aws:s3:::post-user/*")
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "GetUserPolicy",
               "UserName" => user_name,
               "PolicyName" => policy_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "ListUserPolicies",
               "UserName" => user_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "DeleteUserPolicy",
               "UserName" => user_name,
               "PolicyName" => policy_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "PutGroupPolicy",
               "GroupName" => group_name,
               "PolicyName" => policy_name,
               "PolicyDocument" => identity_policy("s3:GetObject", "arn:aws:s3:::post-group/*")
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "GetGroupPolicy",
               "GroupName" => group_name,
               "PolicyName" => policy_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "ListGroupPolicies",
               "GroupName" => group_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "DeleteGroupPolicy",
               "GroupName" => group_name,
               "PolicyName" => policy_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "PutRolePolicy",
               "RoleName" => role_name,
               "PolicyName" => policy_name,
               "PolicyDocument" => identity_policy("s3:GetObject", "arn:aws:s3:::post-role/*")
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "GetRolePolicy",
               "RoleName" => role_name,
               "PolicyName" => policy_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "ListRolePolicies",
               "RoleName" => role_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "DeleteRolePolicy",
               "RoleName" => role_name,
               "PolicyName" => policy_name
             })
             |> call()
             |> Map.fetch!(:status)
  end

  test "root manages user, group, and role managed policy attachments through IAM Query XML" do
    user_name = unique_name("attached-user")
    group_name = unique_name("attached-group")
    role_name = unique_name("attached-role")

    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, _group} = IAM.create_group(group_name: group_name)
    assert {:ok, _role} = IAM.create_role(role_name: role_name, trust_policy: root_trust_policy())

    assert {:ok, first_policy} =
             IAM.create_managed_policy(
               name: unique_name("AAttachedPolicy"),
               path: "/attached/a/",
               policy: identity_policy("s3:GetObject", "arn:aws:s3:::attached-a/*")
             )

    assert {:ok, second_policy} =
             IAM.create_managed_policy(
               name: unique_name("ZAttachedPolicy"),
               path: "/attached/z/",
               policy: identity_policy("s3:PutObject", "arn:aws:s3:::attached-z/*")
             )

    attach_user_first =
      signed_iam_conn(%{
        "Action" => "AttachUserPolicy",
        "UserName" => user_name,
        "PolicyArn" => first_policy.policy_arn
      })
      |> call()

    assert attach_user_first.status == 200
    assert attach_user_first.resp_body =~ "<AttachUserPolicyResponse"

    duplicate_attach_user =
      signed_iam_conn(%{
        "Action" => "AttachUserPolicy",
        "UserName" => user_name,
        "PolicyArn" => first_policy.policy_arn
      })
      |> call()

    assert duplicate_attach_user.status == 200

    attach_user_second =
      signed_iam_conn(%{
        "Action" => "AttachUserPolicy",
        "UserName" => user_name,
        "PolicyArn" => second_policy.policy_arn
      })
      |> call()

    assert attach_user_second.status == 200

    list_user =
      signed_iam_conn(%{
        "Action" => "ListAttachedUserPolicies",
        "UserName" => user_name,
        "MaxItems" => "1"
      })
      |> call()

    assert list_user.status == 200
    assert list_user.resp_body =~ "<ListAttachedUserPoliciesResponse"
    assert xml_value(list_user.resp_body, "IsTruncated") == "true"
    assert xml_values(list_user.resp_body, "PolicyName") == [first_policy.policy_name]
    assert xml_values(list_user.resp_body, "PolicyArn") == [first_policy.policy_arn]
    user_marker = xml_value(list_user.resp_body, "Marker")

    list_user_next =
      signed_iam_conn(%{
        "Action" => "ListAttachedUserPolicies",
        "UserName" => user_name,
        "MaxItems" => "1",
        "Marker" => user_marker
      })
      |> call()

    assert list_user_next.status == 200
    assert xml_value(list_user_next.resp_body, "IsTruncated") == "false"
    assert xml_values(list_user_next.resp_body, "PolicyName") == [second_policy.policy_name]

    presigned_list_user =
      SigV4Request.presigned_conn(:get, "/",
        service: "iam",
        query:
          base_query(%{
            "Action" => "ListAttachedUserPolicies",
            "UserName" => user_name,
            "PathPrefix" => "/attached/a/"
          })
      )
      |> call()

    assert presigned_list_user.status == 200
    assert xml_values(presigned_list_user.resp_body, "PolicyArn") == [first_policy.policy_arn]

    filtered_user =
      signed_iam_conn(%{
        "Action" => "ListAttachedUserPolicies",
        "UserName" => user_name,
        "PathPrefix" => "/attached/a/"
      })
      |> call()

    assert filtered_user.status == 200
    assert xml_value(filtered_user.resp_body, "IsTruncated") == "false"
    assert xml_values(filtered_user.resp_body, "PolicyArn") == [first_policy.policy_arn]

    detach_user =
      signed_iam_conn(%{
        "Action" => "DetachUserPolicy",
        "UserName" => user_name,
        "PolicyArn" => first_policy.policy_arn
      })
      |> call()

    assert detach_user.status == 200
    assert detach_user.resp_body =~ "<DetachUserPolicyResponse"

    list_user_after_detach =
      signed_iam_conn(%{
        "Action" => "ListAttachedUserPolicies",
        "UserName" => user_name
      })
      |> call()

    assert list_user_after_detach.status == 200
    assert xml_values(list_user_after_detach.resp_body, "PolicyArn") == [second_policy.policy_arn]

    attach_group_first =
      signed_iam_conn(%{
        "Action" => "AttachGroupPolicy",
        "GroupName" => group_name,
        "PolicyArn" => first_policy.policy_arn
      })
      |> call()

    assert attach_group_first.status == 200
    assert attach_group_first.resp_body =~ "<AttachGroupPolicyResponse"

    attach_group_second =
      signed_iam_conn(%{
        "Action" => "AttachGroupPolicy",
        "GroupName" => group_name,
        "PolicyArn" => second_policy.policy_arn
      })
      |> call()

    assert attach_group_second.status == 200

    list_group =
      signed_iam_conn(%{
        "Action" => "ListAttachedGroupPolicies",
        "GroupName" => group_name,
        "MaxItems" => "1"
      })
      |> call()

    assert list_group.status == 200
    assert list_group.resp_body =~ "<ListAttachedGroupPoliciesResponse"
    assert xml_value(list_group.resp_body, "IsTruncated") == "true"
    assert xml_values(list_group.resp_body, "PolicyName") == [first_policy.policy_name]
    assert xml_values(list_group.resp_body, "PolicyArn") == [first_policy.policy_arn]
    group_marker = xml_value(list_group.resp_body, "Marker")

    list_group_next =
      signed_iam_conn(%{
        "Action" => "ListAttachedGroupPolicies",
        "GroupName" => group_name,
        "MaxItems" => "1",
        "Marker" => group_marker
      })
      |> call()

    assert list_group_next.status == 200
    assert xml_value(list_group_next.resp_body, "IsTruncated") == "false"
    assert xml_values(list_group_next.resp_body, "PolicyName") == [second_policy.policy_name]

    filtered_group =
      signed_iam_conn(%{
        "Action" => "ListAttachedGroupPolicies",
        "GroupName" => group_name,
        "PathPrefix" => "/attached/z/"
      })
      |> call()

    assert filtered_group.status == 200
    assert xml_values(filtered_group.resp_body, "PolicyArn") == [second_policy.policy_arn]

    detach_group =
      signed_iam_conn(%{
        "Action" => "DetachGroupPolicy",
        "GroupName" => group_name,
        "PolicyArn" => first_policy.policy_arn
      })
      |> call()

    assert detach_group.status == 200
    assert detach_group.resp_body =~ "<DetachGroupPolicyResponse"

    list_group_after_detach =
      signed_iam_conn(%{
        "Action" => "ListAttachedGroupPolicies",
        "GroupName" => group_name
      })
      |> call()

    assert list_group_after_detach.status == 200

    assert xml_values(list_group_after_detach.resp_body, "PolicyArn") == [
             second_policy.policy_arn
           ]

    attach_role_first =
      signed_iam_conn(%{
        "Action" => "AttachRolePolicy",
        "RoleName" => role_name,
        "PolicyArn" => first_policy.policy_arn
      })
      |> call()

    assert attach_role_first.status == 200
    assert attach_role_first.resp_body =~ "<AttachRolePolicyResponse"

    duplicate_attach_role =
      signed_iam_conn(%{
        "Action" => "AttachRolePolicy",
        "RoleName" => role_name,
        "PolicyArn" => first_policy.policy_arn
      })
      |> call()

    assert duplicate_attach_role.status == 200

    attach_role_second =
      signed_iam_conn(%{
        "Action" => "AttachRolePolicy",
        "RoleName" => role_name,
        "PolicyArn" => second_policy.policy_arn
      })
      |> call()

    assert attach_role_second.status == 200

    list_role =
      signed_iam_conn(%{
        "Action" => "ListAttachedRolePolicies",
        "RoleName" => role_name,
        "MaxItems" => "1"
      })
      |> call()

    assert list_role.status == 200
    assert list_role.resp_body =~ "<ListAttachedRolePoliciesResponse"
    assert xml_value(list_role.resp_body, "IsTruncated") == "true"
    assert xml_values(list_role.resp_body, "PolicyName") == [first_policy.policy_name]
    assert xml_values(list_role.resp_body, "PolicyArn") == [first_policy.policy_arn]
    role_marker = xml_value(list_role.resp_body, "Marker")

    list_role_next =
      signed_iam_conn(%{
        "Action" => "ListAttachedRolePolicies",
        "RoleName" => role_name,
        "MaxItems" => "1",
        "Marker" => role_marker
      })
      |> call()

    assert list_role_next.status == 200
    assert xml_value(list_role_next.resp_body, "IsTruncated") == "false"
    assert xml_values(list_role_next.resp_body, "PolicyName") == [second_policy.policy_name]

    filtered_role =
      signed_iam_conn(%{
        "Action" => "ListAttachedRolePolicies",
        "RoleName" => role_name,
        "PathPrefix" => "/attached/z/"
      })
      |> call()

    assert filtered_role.status == 200
    assert xml_values(filtered_role.resp_body, "PolicyArn") == [second_policy.policy_arn]

    detach_role =
      signed_iam_conn(%{
        "Action" => "DetachRolePolicy",
        "RoleName" => role_name,
        "PolicyArn" => first_policy.policy_arn
      })
      |> call()

    assert detach_role.status == 200
    assert detach_role.resp_body =~ "<DetachRolePolicyResponse"

    list_role_after_detach =
      signed_iam_conn(%{
        "Action" => "ListAttachedRolePolicies",
        "RoleName" => role_name
      })
      |> call()

    assert list_role_after_detach.status == 200

    assert xml_values(list_role_after_detach.resp_body, "PolicyArn") == [
             second_policy.policy_arn
           ]
  end

  test "IAM managed policy attachment Query API accepts signed POST forms" do
    user_name = unique_name("post-attached-user")
    group_name = unique_name("post-attached-group")
    role_name = unique_name("post-attached-role")

    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, _group} = IAM.create_group(group_name: group_name)
    assert {:ok, _role} = IAM.create_role(role_name: role_name, trust_policy: root_trust_policy())

    assert {:ok, policy} =
             IAM.create_managed_policy(
               name: unique_name("PostAttachedPolicy"),
               path: "/post/",
               policy: identity_policy("s3:GetObject", "arn:aws:s3:::post-attached/*")
             )

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "AttachUserPolicy",
               "UserName" => user_name,
               "PolicyArn" => policy.policy_arn
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "ListAttachedUserPolicies",
               "UserName" => user_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "DetachUserPolicy",
               "UserName" => user_name,
               "PolicyArn" => policy.policy_arn
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "AttachGroupPolicy",
               "GroupName" => group_name,
               "PolicyArn" => policy.policy_arn
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "ListAttachedGroupPolicies",
               "GroupName" => group_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "DetachGroupPolicy",
               "GroupName" => group_name,
               "PolicyArn" => policy.policy_arn
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "AttachRolePolicy",
               "RoleName" => role_name,
               "PolicyArn" => policy.policy_arn
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "ListAttachedRolePolicies",
               "RoleName" => role_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "DetachRolePolicy",
               "RoleName" => role_name,
               "PolicyArn" => policy.policy_arn
             })
             |> call()
             |> Map.fetch!(:status)
  end

  test "root manages managed policy lifecycle through IAM Query XML" do
    user_name = unique_name("managed-life-user")
    group_name = unique_name("managed-life-group")
    role_name = unique_name("managed-life-role")
    role_arn = IAM.role_arn(role_name)
    first_name = unique_name("AQueryLifecyclePolicy")
    second_name = unique_name("ZQueryLifecyclePolicy")
    path = "/query/lifecycle/"
    policy_arn = IAM.managed_policy_arn(first_name, path)

    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, _group} = IAM.create_group(group_name: group_name)

    assert {:ok, _role} =
             IAM.create_role(
               role_name: role_name,
               trust_policy: %{
                 "Version" => "2012-10-17",
                 "Statement" => %{
                   "Effect" => "Allow",
                   "Principal" => %{"AWS" => IAM.root_principal_arn()},
                   "Action" => "sts:AssumeRole"
                 }
               }
             )

    create =
      signed_iam_conn(%{
        "Action" => "CreatePolicy",
        "PolicyName" => first_name,
        "Path" => path,
        "Description" => "read-access",
        "PolicyDocument" => identity_policy("s3:GetObject", "arn:aws:s3:::lifecycle/*"),
        "Tags.member.1.Key" => "CostCenter",
        "Tags.member.1.Value" => "42",
        "Tags.member.2.Key" => "costcenter",
        "Tags.member.2.Value" => "43"
      })
      |> call()

    assert create.status == 200
    assert create.resp_body =~ "<CreatePolicyResponse"
    assert xml_value(create.resp_body, "Path") == path
    assert xml_value(create.resp_body, "PolicyName") == first_name
    assert xml_value(create.resp_body, "PolicyId") =~ ~r/\AANPA[A-Z2-7]{16}\z/
    assert xml_value(create.resp_body, "Arn") == policy_arn
    assert xml_value(create.resp_body, "DefaultVersionId") == "v1"
    assert xml_value(create.resp_body, "AttachmentCount") == "0"
    assert xml_value(create.resp_body, "PermissionsBoundaryUsageCount") == "0"
    assert xml_value(create.resp_body, "IsAttachable") == "true"
    assert xml_value(create.resp_body, "Description") == "read-access"
    assert xml_tag_pairs(create.resp_body) == [{"CostCenter", "42"}, {"costcenter", "43"}]

    assert {:ok, stored} = IAM.get_managed_policy(policy_arn)
    assert stored.description == "read-access"
    assert stored.tags == %{"CostCenter" => "42", "costcenter" => "43"}

    assert 200 =
             signed_iam_conn(%{
               "Action" => "CreatePolicy",
               "PolicyName" => second_name,
               "Path" => path,
               "PolicyDocument" => identity_policy("s3:PutObject", "arn:aws:s3:::lifecycle/*")
             })
             |> call()
             |> Map.fetch!(:status)

    get =
      signed_iam_conn(%{
        "Action" => "GetPolicy",
        "PolicyArn" => policy_arn
      })
      |> call()

    assert get.status == 200
    assert get.resp_body =~ "<GetPolicyResponse"
    assert xml_value(get.resp_body, "PolicyName") == first_name
    assert xml_tag_pairs(get.resp_body) == [{"CostCenter", "42"}, {"costcenter", "43"}]

    tag_policy =
      signed_iam_conn(%{
        "Action" => "TagPolicy",
        "PolicyArn" => policy_arn,
        "Tags.member.1.Key" => "CostCenter",
        "Tags.member.1.Value" => "84",
        "Tags.member.2.Key" => "owner",
        "Tags.member.2.Value" => "storage"
      })
      |> call()

    assert tag_policy.status == 200
    assert tag_policy.resp_body =~ "<TagPolicyResponse"

    list_tags =
      signed_iam_conn(%{
        "Action" => "ListPolicyTags",
        "PolicyArn" => policy_arn
      })
      |> call()

    assert list_tags.status == 200
    assert list_tags.resp_body =~ "<ListPolicyTagsResponse"

    assert xml_tag_pairs(list_tags.resp_body) == [
             {"CostCenter", "84"},
             {"costcenter", "43"},
             {"owner", "storage"}
           ]

    untag_policy =
      signed_iam_conn(%{
        "Action" => "UntagPolicy",
        "PolicyArn" => policy_arn,
        "TagKeys.member.1" => "CostCenter",
        "TagKeys.member.2" => "missing"
      })
      |> call()

    assert untag_policy.status == 200
    assert untag_policy.resp_body =~ "<UntagPolicyResponse"

    assert {:ok, tagged_policy} = IAM.get_managed_policy(policy_arn)
    assert tagged_policy.tags == %{"costcenter" => "43", "owner" => "storage"}

    get_version =
      signed_iam_conn(%{
        "Action" => "GetPolicyVersion",
        "PolicyArn" => policy_arn,
        "VersionId" => "v1"
      })
      |> call()

    assert get_version.status == 200
    assert xml_value(get_version.resp_body, "VersionId") == "v1"
    assert xml_value(get_version.resp_body, "IsDefaultVersion") == "true"

    assert get_version.resp_body
           |> xml_value("Document")
           |> URI.decode()
           |> Jason.decode!()
           |> get_in(["Statement", "Action"]) == "s3:GetObject"

    create_version =
      signed_iam_conn(%{
        "Action" => "CreatePolicyVersion",
        "PolicyArn" => policy_arn,
        "PolicyDocument" => identity_policy("s3:PutObject", "arn:aws:s3:::lifecycle/*")
      })
      |> call()

    assert create_version.status == 200
    assert create_version.resp_body =~ "<CreatePolicyVersionResponse"
    assert xml_value(create_version.resp_body, "VersionId") == "v2"
    assert xml_value(create_version.resp_body, "IsDefaultVersion") == "false"
    refute create_version.resp_body =~ "<Document>"

    get_version_v2 =
      signed_iam_conn(%{
        "Action" => "GetPolicyVersion",
        "PolicyArn" => policy_arn,
        "VersionId" => "v2"
      })
      |> call()

    assert get_version_v2.status == 200
    assert xml_value(get_version_v2.resp_body, "VersionId") == "v2"
    assert xml_value(get_version_v2.resp_body, "IsDefaultVersion") == "false"

    assert get_version_v2.resp_body
           |> xml_value("Document")
           |> URI.decode()
           |> Jason.decode!()
           |> get_in(["Statement", "Action"]) == "s3:PutObject"

    list_versions =
      signed_iam_conn(%{
        "Action" => "ListPolicyVersions",
        "PolicyArn" => policy_arn
      })
      |> call()

    assert list_versions.status == 200
    assert xml_values(list_versions.resp_body, "VersionId") == ["v1", "v2"]
    assert xml_values(list_versions.resp_body, "IsDefaultVersion") == ["true", "false"]
    refute list_versions.resp_body =~ "<Document>"

    non_default_delete_policy =
      signed_iam_conn(%{
        "Action" => "DeletePolicy",
        "PolicyArn" => policy_arn
      })
      |> call()

    assert non_default_delete_policy.status == 409
    assert non_default_delete_policy.resp_body =~ "<Code>DeleteConflict</Code>"

    set_default =
      signed_iam_conn(%{
        "Action" => "SetDefaultPolicyVersion",
        "PolicyArn" => policy_arn,
        "VersionId" => "v2"
      })
      |> call()

    assert set_default.status == 200
    assert set_default.resp_body =~ "<SetDefaultPolicyVersionResponse"

    get_after_default =
      signed_iam_conn(%{
        "Action" => "GetPolicy",
        "PolicyArn" => policy_arn
      })
      |> call()

    assert get_after_default.status == 200
    assert xml_value(get_after_default.resp_body, "DefaultVersionId") == "v2"

    get_version_v2_default =
      signed_iam_conn(%{
        "Action" => "GetPolicyVersion",
        "PolicyArn" => policy_arn,
        "VersionId" => "v2"
      })
      |> call()

    assert get_version_v2_default.status == 200
    assert xml_value(get_version_v2_default.resp_body, "IsDefaultVersion") == "true"

    delete_old_version =
      signed_iam_conn(%{
        "Action" => "DeletePolicyVersion",
        "PolicyArn" => policy_arn,
        "VersionId" => "v1"
      })
      |> call()

    assert delete_old_version.status == 200
    assert delete_old_version.resp_body =~ "<DeletePolicyVersionResponse"

    list_versions_after_delete =
      signed_iam_conn(%{
        "Action" => "ListPolicyVersions",
        "PolicyArn" => policy_arn
      })
      |> call()

    assert list_versions_after_delete.status == 200
    assert xml_values(list_versions_after_delete.resp_body, "VersionId") == ["v2"]

    list =
      signed_iam_conn(%{
        "Action" => "ListPolicies",
        "Scope" => "Local",
        "PathPrefix" => path,
        "MaxItems" => "1"
      })
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<ListPoliciesResponse"
    assert xml_value(list.resp_body, "IsTruncated") == "true"
    assert xml_values(list.resp_body, "PolicyName") == [first_name]
    assert xml_values(list.resp_body, "Arn") == [policy_arn]
    assert xml_tag_pairs(list.resp_body) == []
    marker = xml_value(list.resp_body, "Marker")

    list_next =
      signed_iam_conn(%{
        "Action" => "ListPolicies",
        "Scope" => "All",
        "PathPrefix" => path,
        "MaxItems" => "1",
        "Marker" => marker
      })
      |> call()

    assert list_next.status == 200
    assert xml_value(list_next.resp_body, "IsTruncated") == "false"
    assert xml_values(list_next.resp_body, "PolicyName") == [second_name]

    aws_scope =
      signed_iam_conn(%{
        "Action" => "ListPolicies",
        "Scope" => "AWS",
        "PathPrefix" => path
      })
      |> call()

    assert aws_scope.status == 200
    assert xml_values(aws_scope.resp_body, "PolicyName") == []

    put_user_boundary =
      signed_iam_conn(%{
        "Action" => "PutUserPermissionsBoundary",
        "UserName" => user_name,
        "PermissionsBoundary" => policy_arn
      })
      |> call()

    assert put_user_boundary.status == 200
    assert put_user_boundary.resp_body =~ "<PutUserPermissionsBoundaryResponse"

    put_role_boundary =
      signed_iam_conn(%{
        "Action" => "PutRolePermissionsBoundary",
        "RoleName" => role_name,
        "PermissionsBoundary" => policy_arn
      })
      |> call()

    assert put_role_boundary.status == 200
    assert put_role_boundary.resp_body =~ "<PutRolePermissionsBoundaryResponse"

    get_user_boundary =
      signed_iam_conn(%{
        "Action" => "GetUser",
        "UserName" => user_name
      })
      |> call()

    assert get_user_boundary.status == 200

    assert xml_value(get_user_boundary.resp_body, "PermissionsBoundaryType") ==
             "PermissionsBoundaryPolicy"

    assert xml_value(get_user_boundary.resp_body, "PermissionsBoundaryArn") == policy_arn

    get_role_boundary =
      signed_iam_conn(%{
        "Action" => "GetRole",
        "RoleName" => role_name
      })
      |> call()

    assert get_role_boundary.status == 200

    assert xml_value(get_role_boundary.resp_body, "PermissionsBoundaryType") ==
             "PermissionsBoundaryPolicy"

    assert xml_value(get_role_boundary.resp_body, "PermissionsBoundaryArn") == policy_arn

    permissions_boundary =
      signed_iam_conn(%{
        "Action" => "ListPolicies",
        "PolicyUsageFilter" => "PermissionsBoundary",
        "PathPrefix" => path
      })
      |> call()

    assert permissions_boundary.status == 200
    assert xml_values(permissions_boundary.resp_body, "PolicyName") == [first_name]
    assert xml_values(permissions_boundary.resp_body, "PermissionsBoundaryUsageCount") == ["2"]

    only_attached_before =
      signed_iam_conn(%{
        "Action" => "ListPolicies",
        "OnlyAttached" => "true",
        "PathPrefix" => path
      })
      |> call()

    assert only_attached_before.status == 200
    assert xml_values(only_attached_before.resp_body, "PolicyName") == []

    attach =
      signed_iam_conn(%{
        "Action" => "AttachUserPolicy",
        "UserName" => user_name,
        "PolicyArn" => policy_arn
      })
      |> call()

    assert attach.status == 200

    assert :ok = IAM.attach_group_policy(group_name, policy_arn)
    assert :ok = IAM.attach_role_policy(role_arn, policy_arn)

    only_attached_after =
      signed_iam_conn(%{
        "Action" => "ListPolicies",
        "OnlyAttached" => "true",
        "PathPrefix" => path
      })
      |> call()

    assert only_attached_after.status == 200
    assert xml_values(only_attached_after.resp_body, "PolicyName") == [first_name]
    assert xml_values(only_attached_after.resp_body, "AttachmentCount") == ["3"]

    entities =
      signed_iam_conn(%{
        "Action" => "ListEntitiesForPolicy",
        "PolicyArn" => policy_arn
      })
      |> call()

    assert entities.status == 200
    assert entities.resp_body =~ "<ListEntitiesForPolicyResponse"
    assert xml_values(entities.resp_body, "GroupName") == [group_name]
    assert xml_values(entities.resp_body, "UserName") == [user_name]
    assert xml_values(entities.resp_body, "RoleName") == [role_name]
    assert xml_value(entities.resp_body, "GroupId") =~ ~r/\AAGPA[A-Z2-7]{16}\z/
    assert xml_value(entities.resp_body, "UserId") =~ ~r/\AAIDA[A-Z2-7]{16}\z/
    assert xml_value(entities.resp_body, "RoleId") =~ ~r/\AAROA[A-Z2-7]{16}\z/

    only_users =
      signed_iam_conn(%{
        "Action" => "ListEntitiesForPolicy",
        "PolicyArn" => policy_arn,
        "EntityFilter" => "User"
      })
      |> call()

    assert only_users.status == 200
    assert xml_values(only_users.resp_body, "UserName") == [user_name]
    assert xml_values(only_users.resp_body, "GroupName") == []
    assert xml_values(only_users.resp_body, "RoleName") == []

    boundary_entities =
      signed_iam_conn(%{
        "Action" => "ListEntitiesForPolicy",
        "PolicyArn" => policy_arn,
        "PolicyUsageFilter" => "PermissionsBoundary"
      })
      |> call()

    assert boundary_entities.status == 200
    assert xml_values(boundary_entities.resp_body, "UserName") == [user_name]
    assert xml_values(boundary_entities.resp_body, "GroupName") == []
    assert xml_values(boundary_entities.resp_body, "RoleName") == [role_name]

    other_path_entities =
      signed_iam_conn(%{
        "Action" => "ListEntitiesForPolicy",
        "PolicyArn" => policy_arn,
        "PathPrefix" => "/other/"
      })
      |> call()

    assert other_path_entities.status == 200
    assert xml_values(other_path_entities.resp_body, "UserName") == []
    assert xml_values(other_path_entities.resp_body, "GroupName") == []
    assert xml_values(other_path_entities.resp_body, "RoleName") == []

    attached_delete =
      signed_iam_conn(%{
        "Action" => "DeletePolicy",
        "PolicyArn" => policy_arn
      })
      |> call()

    assert attached_delete.status == 409
    assert attached_delete.resp_body =~ "<Code>DeleteConflict</Code>"

    assert 200 =
             signed_iam_conn(%{
               "Action" => "DetachUserPolicy",
               "UserName" => user_name,
               "PolicyArn" => policy_arn
             })
             |> call()
             |> Map.fetch!(:status)

    assert :ok = IAM.detach_group_policy(group_name, policy_arn)
    assert :ok = IAM.detach_role_policy(role_arn, policy_arn)

    boundary_delete_conflict =
      signed_iam_conn(%{
        "Action" => "DeletePolicy",
        "PolicyArn" => policy_arn
      })
      |> call()

    assert boundary_delete_conflict.status == 409
    assert boundary_delete_conflict.resp_body =~ "<Code>DeleteConflict</Code>"

    delete_user_boundary =
      signed_iam_conn(%{
        "Action" => "DeleteUserPermissionsBoundary",
        "UserName" => user_name
      })
      |> call()

    assert delete_user_boundary.status == 200
    assert delete_user_boundary.resp_body =~ "<DeleteUserPermissionsBoundaryResponse"

    delete_role_boundary =
      signed_iam_conn(%{
        "Action" => "DeleteRolePermissionsBoundary",
        "RoleName" => role_name
      })
      |> call()

    assert delete_role_boundary.status == 200
    assert delete_role_boundary.resp_body =~ "<DeleteRolePermissionsBoundaryResponse"

    delete =
      signed_iam_conn(%{
        "Action" => "DeletePolicy",
        "PolicyArn" => policy_arn
      })
      |> call()

    assert delete.status == 200
    assert delete.resp_body =~ "<DeletePolicyResponse"

    missing_get =
      signed_iam_conn(%{
        "Action" => "GetPolicy",
        "PolicyArn" => policy_arn
      })
      |> call()

    assert missing_get.status == 404
    assert missing_get.resp_body =~ "<Code>NoSuchEntity</Code>"
  end

  test "IAM managed policy lifecycle Query API accepts signed POST forms" do
    policy_name = unique_name("PostManagedLifecyclePolicy")
    policy_arn = IAM.managed_policy_arn(policy_name, "/post/lifecycle/")

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "CreatePolicy",
               "PolicyName" => policy_name,
               "Path" => "/post/lifecycle/",
               "PolicyDocument" => identity_policy("s3:GetObject", "arn:aws:s3:::post-life/*")
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "GetPolicy",
               "PolicyArn" => policy_arn
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "GetPolicyVersion",
               "PolicyArn" => policy_arn,
               "VersionId" => "v1"
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "ListPolicyVersions",
               "PolicyArn" => policy_arn
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "CreatePolicyVersion",
               "PolicyArn" => policy_arn,
               "PolicyDocument" => identity_policy("s3:PutObject", "arn:aws:s3:::post-life/*"),
               "SetAsDefault" => "true"
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "SetDefaultPolicyVersion",
               "PolicyArn" => policy_arn,
               "VersionId" => "v2"
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "DeletePolicyVersion",
               "PolicyArn" => policy_arn,
               "VersionId" => "v1"
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "ListPolicies",
               "PathPrefix" => "/post/lifecycle/"
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "TagPolicy",
               "PolicyArn" => policy_arn,
               "Tags.member.1.Key" => "team",
               "Tags.member.1.Value" => "post"
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "ListPolicyTags",
               "PolicyArn" => policy_arn
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "ListEntitiesForPolicy",
               "PolicyArn" => policy_arn
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "UntagPolicy",
               "PolicyArn" => policy_arn,
               "TagKeys.member.1" => "team"
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "DeletePolicy",
               "PolicyArn" => policy_arn
             })
             |> call()
             |> Map.fetch!(:status)
  end

  test "IAM managed policy lifecycle parameters and documents fail closed" do
    valid_name = unique_name("ManagedPolicyFail")
    valid_arn = IAM.managed_policy_arn(valid_name, "/fail/lifecycle/")

    invalid_name =
      signed_iam_conn(%{
        "Action" => "CreatePolicy",
        "PolicyName" => "bad*policy",
        "PolicyDocument" => identity_policy("s3:GetObject")
      })
      |> call()

    assert invalid_name.status == 400
    assert invalid_name.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_name.resp_body =~ "PolicyName"

    invalid_path =
      signed_iam_conn(%{
        "Action" => "CreatePolicy",
        "PolicyName" => unique_name("BadPathPolicy"),
        "Path" => "/bad//path/",
        "PolicyDocument" => identity_policy("s3:GetObject")
      })
      |> call()

    assert invalid_path.status == 400
    assert invalid_path.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_path.resp_body =~ "Path"

    long_description =
      signed_iam_conn(%{
        "Action" => "CreatePolicy",
        "PolicyName" => unique_name("LongDescriptionPolicy"),
        "Description" => String.duplicate("d", 1001),
        "PolicyDocument" => identity_policy("s3:GetObject")
      })
      |> call()

    assert long_description.status == 400
    assert long_description.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert long_description.resp_body =~ "Description"

    reserved_tag =
      signed_iam_conn(%{
        "Action" => "CreatePolicy",
        "PolicyName" => unique_name("ReservedTagPolicy"),
        "PolicyDocument" => identity_policy("s3:GetObject"),
        "Tags.member.1.Key" => "aws:team",
        "Tags.member.1.Value" => "core"
      })
      |> call()

    assert reserved_tag.status == 400
    assert reserved_tag.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert reserved_tag.resp_body =~ "valid tag keys and values"

    malformed_json =
      signed_iam_conn(%{
        "Action" => "CreatePolicy",
        "PolicyName" => unique_name("MalformedJsonPolicy"),
        "PolicyDocument" => ~s({"Statement":)
      })
      |> call()

    assert malformed_json.status == 400
    assert malformed_json.resp_body =~ "<Code>MalformedPolicyDocument</Code>"

    explicit_principal =
      signed_iam_conn(%{
        "Action" => "CreatePolicy",
        "PolicyName" => unique_name("ExplicitPrincipalPolicy"),
        "PolicyDocument" =>
          ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::bad/*"}})
      })
      |> call()

    assert explicit_principal.status == 400
    assert explicit_principal.resp_body =~ "<Code>MalformedPolicyDocument</Code>"

    too_large =
      signed_iam_conn(%{
        "Action" => "CreatePolicy",
        "PolicyName" => unique_name("LargePolicy"),
        "PolicyDocument" =>
          identity_policy("s3:GetObject", "arn:aws:s3:::#{String.duplicate("a", 6500)}/*")
      })
      |> call()

    assert too_large.status == 409
    assert too_large.resp_body =~ "<Code>LimitExceeded</Code>"

    assert 200 =
             signed_iam_conn(%{
               "Action" => "CreatePolicy",
               "PolicyName" => valid_name,
               "Path" => "/fail/lifecycle/",
               "PolicyDocument" => identity_policy("s3:GetObject", "arn:aws:s3:::fail/*")
             })
             |> call()
             |> Map.fetch!(:status)

    tag_quota_name = unique_name("TagQuotaPolicy")
    tag_quota_arn = IAM.managed_policy_arn(tag_quota_name, "/fail/lifecycle/")

    tag_quota_create_params =
      %{
        "Action" => "CreatePolicy",
        "PolicyName" => tag_quota_name,
        "Path" => "/fail/lifecycle/",
        "PolicyDocument" => identity_policy("s3:GetObject", "arn:aws:s3:::tag-quota/*")
      }
      |> Map.merge(indexed_tag_params("Tags", Enum.map(1..49, &{"k#{&1}", "v#{&1}"})))

    assert 200 =
             tag_quota_create_params
             |> signed_iam_conn()
             |> call()
             |> Map.fetch!(:status)

    tag_quota_overflow =
      signed_iam_conn(%{
        "Action" => "TagPolicy",
        "PolicyArn" => tag_quota_arn,
        "Tags.member.1.Key" => "k50",
        "Tags.member.1.Value" => "v50",
        "Tags.member.2.Key" => "k51",
        "Tags.member.2.Value" => "v51"
      })
      |> call()

    assert tag_quota_overflow.status == 400
    assert tag_quota_overflow.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert {:ok, tag_quota_policy} = IAM.get_managed_policy(tag_quota_arn)
    assert map_size(tag_quota_policy.tags) == 49
    refute Map.has_key?(tag_quota_policy.tags, "k50")
    refute Map.has_key?(tag_quota_policy.tags, "k51")

    invalid_policy_tag =
      signed_iam_conn(%{
        "Action" => "TagPolicy",
        "PolicyArn" => valid_arn,
        "Tags.member.1.Key" => "aws:team",
        "Tags.member.1.Value" => "core"
      })
      |> call()

    assert invalid_policy_tag.status == 400
    assert invalid_policy_tag.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_policy_tag.resp_body =~ "valid tag keys and values"

    duplicate_policy_tag =
      signed_iam_conn(%{
        "Action" => "TagPolicy",
        "PolicyArn" => valid_arn,
        "Tags.member.1.Key" => "team",
        "Tags.member.1.Value" => "core",
        "Tags.member.2.Key" => "team",
        "Tags.member.2.Value" => "ops"
      })
      |> call()

    assert duplicate_policy_tag.status == 400
    assert duplicate_policy_tag.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert duplicate_policy_tag.resp_body =~ "valid tag keys and values"

    missing_policy_tags =
      signed_iam_conn(%{
        "Action" => "ListPolicyTags",
        "PolicyArn" => IAM.managed_policy_arn(unique_name("MissingTagListPolicy"))
      })
      |> call()

    assert missing_policy_tags.status == 404
    assert missing_policy_tags.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_tag_policy =
      signed_iam_conn(%{
        "Action" => "TagPolicy",
        "PolicyArn" => IAM.managed_policy_arn(unique_name("MissingTagPolicy")),
        "Tags.member.1.Key" => "team",
        "Tags.member.1.Value" => "core"
      })
      |> call()

    assert missing_tag_policy.status == 404
    assert missing_tag_policy.resp_body =~ "<Code>NoSuchEntity</Code>"

    invalid_entity_filter =
      signed_iam_conn(%{
        "Action" => "ListEntitiesForPolicy",
        "PolicyArn" => valid_arn,
        "EntityFilter" => "Policy"
      })
      |> call()

    assert invalid_entity_filter.status == 400
    assert invalid_entity_filter.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_entity_filter.resp_body =~ "EntityFilter"

    invalid_entity_path =
      signed_iam_conn(%{
        "Action" => "ListEntitiesForPolicy",
        "PolicyArn" => valid_arn,
        "PathPrefix" => "missing-slash/"
      })
      |> call()

    assert invalid_entity_path.status == 400
    assert invalid_entity_path.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_entity_path.resp_body =~ "PathPrefix"

    missing_entities_policy =
      signed_iam_conn(%{
        "Action" => "ListEntitiesForPolicy",
        "PolicyArn" => IAM.managed_policy_arn(unique_name("MissingEntityPolicy"))
      })
      |> call()

    assert missing_entities_policy.status == 404
    assert missing_entities_policy.resp_body =~ "<Code>NoSuchEntity</Code>"

    duplicate =
      signed_iam_conn(%{
        "Action" => "CreatePolicy",
        "PolicyName" => valid_name,
        "Path" => "/fail/lifecycle/",
        "PolicyDocument" => identity_policy("s3:PutObject", "arn:aws:s3:::fail/*")
      })
      |> call()

    assert duplicate.status == 409
    assert duplicate.resp_body =~ "<Code>EntityAlreadyExists</Code>"

    invalid_version =
      signed_iam_conn(%{
        "Action" => "GetPolicyVersion",
        "PolicyArn" => valid_arn,
        "VersionId" => "latest"
      })
      |> call()

    assert invalid_version.status == 400
    assert invalid_version.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_version.resp_body =~ "VersionId"

    missing_version =
      signed_iam_conn(%{
        "Action" => "GetPolicyVersion",
        "PolicyArn" => valid_arn,
        "VersionId" => "v2"
      })
      |> call()

    assert missing_version.status == 404
    assert missing_version.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_dotted_version =
      signed_iam_conn(%{
        "Action" => "GetPolicyVersion",
        "PolicyArn" => valid_arn,
        "VersionId" => "v2.test"
      })
      |> call()

    assert missing_dotted_version.status == 404
    assert missing_dotted_version.resp_body =~ "<Code>NoSuchEntity</Code>"

    invalid_set_as_default =
      signed_iam_conn(%{
        "Action" => "CreatePolicyVersion",
        "PolicyArn" => valid_arn,
        "PolicyDocument" => identity_policy("s3:PutObject", "arn:aws:s3:::fail/*"),
        "SetAsDefault" => "yes"
      })
      |> call()

    assert invalid_set_as_default.status == 400
    assert invalid_set_as_default.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_set_as_default.resp_body =~ "SetAsDefault"

    malformed_version_document =
      signed_iam_conn(%{
        "Action" => "CreatePolicyVersion",
        "PolicyArn" => valid_arn,
        "PolicyDocument" => ~s({"Statement":)
      })
      |> call()

    assert malformed_version_document.status == 400
    assert malformed_version_document.resp_body =~ "<Code>MalformedPolicyDocument</Code>"

    delete_default_version =
      signed_iam_conn(%{
        "Action" => "DeletePolicyVersion",
        "PolicyArn" => valid_arn,
        "VersionId" => "v1"
      })
      |> call()

    assert delete_default_version.status == 409
    assert delete_default_version.resp_body =~ "<Code>DeleteConflict</Code>"

    missing_set_default =
      signed_iam_conn(%{
        "Action" => "SetDefaultPolicyVersion",
        "PolicyArn" => valid_arn,
        "VersionId" => "v99"
      })
      |> call()

    assert missing_set_default.status == 404
    assert missing_set_default.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_delete_version =
      signed_iam_conn(%{
        "Action" => "DeletePolicyVersion",
        "PolicyArn" => valid_arn,
        "VersionId" => "v99"
      })
      |> call()

    assert missing_delete_version.status == 404
    assert missing_delete_version.resp_body =~ "<Code>NoSuchEntity</Code>"

    for action <- ["s3:PutObject", "s3:DeleteObject", "s3:GetObjectAcl", "s3:PutObjectAcl"] do
      assert 200 =
               signed_iam_conn(%{
                 "Action" => "CreatePolicyVersion",
                 "PolicyArn" => valid_arn,
                 "PolicyDocument" => identity_policy(action, "arn:aws:s3:::fail/*")
               })
               |> call()
               |> Map.fetch!(:status)
    end

    version_limit =
      signed_iam_conn(%{
        "Action" => "CreatePolicyVersion",
        "PolicyArn" => valid_arn,
        "PolicyDocument" => identity_policy("s3:GetObjectVersion", "arn:aws:s3:::fail/*")
      })
      |> call()

    assert version_limit.status == 409
    assert version_limit.resp_body =~ "<Code>LimitExceeded</Code>"

    non_default_delete =
      signed_iam_conn(%{
        "Action" => "DeletePolicy",
        "PolicyArn" => valid_arn
      })
      |> call()

    assert non_default_delete.status == 409
    assert non_default_delete.resp_body =~ "<Code>DeleteConflict</Code>"

    missing_delete =
      signed_iam_conn(%{
        "Action" => "DeletePolicy",
        "PolicyArn" => IAM.managed_policy_arn(unique_name("MissingDeletePolicy"))
      })
      |> call()

    assert missing_delete.status == 404
    assert missing_delete.resp_body =~ "<Code>NoSuchEntity</Code>"

    invalid_scope =
      signed_iam_conn(%{
        "Action" => "ListPolicies",
        "Scope" => "Service"
      })
      |> call()

    assert invalid_scope.status == 400
    assert invalid_scope.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_scope.resp_body =~ "Scope"

    invalid_only_attached =
      signed_iam_conn(%{
        "Action" => "ListPolicies",
        "OnlyAttached" => "yes"
      })
      |> call()

    assert invalid_only_attached.status == 400
    assert invalid_only_attached.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_only_attached.resp_body =~ "OnlyAttached"

    invalid_usage =
      signed_iam_conn(%{
        "Action" => "ListPolicies",
        "PolicyUsageFilter" => "Boundary"
      })
      |> call()

    assert invalid_usage.status == 400
    assert invalid_usage.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_usage.resp_body =~ "PolicyUsageFilter"
  end

  test "IAM inline policy Query parameters and documents fail closed" do
    user_name = unique_name("policy-fail-user")
    group_name = unique_name("policy-fail-group")
    role_name = unique_name("policy-fail-role")
    policy_name = "KeepPolicy"

    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, _group} = IAM.create_group(group_name: group_name)
    assert {:ok, _role} = IAM.create_role(role_name: role_name, trust_policy: root_trust_policy())

    invalid_name =
      signed_iam_conn(%{
        "Action" => "PutUserPolicy",
        "UserName" => user_name,
        "PolicyName" => "bad*policy",
        "PolicyDocument" => identity_policy("s3:GetObject")
      })
      |> call()

    assert invalid_name.status == 400
    assert invalid_name.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_name.resp_body =~ "PolicyName"

    whitespace_policy_name =
      [
        {"Action", "PutUserPolicy"},
        {"Version", "2010-05-08"},
        {"UserName", user_name},
        {"PolicyName", " #{policy_name} "},
        {"PolicyDocument", identity_policy("s3:GetObject")}
      ]
      |> raw_iam_query()
      |> signed_raw_iam_conn()
      |> call()

    assert whitespace_policy_name.status == 400
    assert whitespace_policy_name.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert whitespace_policy_name.resp_body =~ "PolicyName"

    whitespace_user_name =
      [
        {"Action", "GetUserPolicy"},
        {"Version", "2010-05-08"},
        {"UserName", " #{user_name} "},
        {"PolicyName", policy_name}
      ]
      |> raw_iam_query()
      |> signed_raw_iam_conn()
      |> call()

    assert whitespace_user_name.status == 400
    assert whitespace_user_name.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert whitespace_user_name.resp_body =~ "UserName"

    whitespace_group_name =
      [
        {"Action", "GetGroupPolicy"},
        {"Version", "2010-05-08"},
        {"GroupName", " #{group_name} "},
        {"PolicyName", policy_name}
      ]
      |> raw_iam_query()
      |> signed_raw_iam_conn()
      |> call()

    assert whitespace_group_name.status == 400
    assert whitespace_group_name.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert whitespace_group_name.resp_body =~ "GroupName"

    whitespace_role_name =
      [
        {"Action", "GetRolePolicy"},
        {"Version", "2010-05-08"},
        {"RoleName", " #{role_name} "},
        {"PolicyName", policy_name}
      ]
      |> raw_iam_query()
      |> signed_raw_iam_conn()
      |> call()

    assert whitespace_role_name.status == 400
    assert whitespace_role_name.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert whitespace_role_name.resp_body =~ "RoleName"

    invalid_role_name =
      signed_iam_conn(%{
        "Action" => "PutRolePolicy",
        "RoleName" => "bad*role",
        "PolicyName" => policy_name,
        "PolicyDocument" => identity_policy("s3:GetObject")
      })
      |> call()

    assert invalid_role_name.status == 400
    assert invalid_role_name.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_role_name.resp_body =~ "RoleName"

    missing_user =
      signed_iam_conn(%{
        "Action" => "GetUserPolicy",
        "UserName" => "missing-inline-user",
        "PolicyName" => policy_name
      })
      |> call()

    assert missing_user.status == 404
    assert missing_user.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_role =
      signed_iam_conn(%{
        "Action" => "GetRolePolicy",
        "RoleName" => "missing-inline-role",
        "PolicyName" => policy_name
      })
      |> call()

    assert missing_role.status == 404
    assert missing_role.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_policy =
      signed_iam_conn(%{
        "Action" => "DeleteGroupPolicy",
        "GroupName" => group_name,
        "PolicyName" => "MissingPolicy"
      })
      |> call()

    assert missing_policy.status == 404
    assert missing_policy.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_role_policy =
      signed_iam_conn(%{
        "Action" => "DeleteRolePolicy",
        "RoleName" => role_name,
        "PolicyName" => "MissingPolicy"
      })
      |> call()

    assert missing_role_policy.status == 404
    assert missing_role_policy.resp_body =~ "<Code>NoSuchEntity</Code>"

    malformed_json =
      signed_iam_conn(%{
        "Action" => "PutUserPolicy",
        "UserName" => user_name,
        "PolicyName" => policy_name,
        "PolicyDocument" => ~s({"Statement":)
      })
      |> call()

    assert malformed_json.status == 400
    assert malformed_json.resp_body =~ "<Code>MalformedPolicyDocument</Code>"

    explicit_principal =
      signed_iam_conn(%{
        "Action" => "PutUserPolicy",
        "UserName" => user_name,
        "PolicyName" => policy_name,
        "PolicyDocument" =>
          ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::bad/*"}})
      })
      |> call()

    assert explicit_principal.status == 400
    assert explicit_principal.resp_body =~ "<Code>MalformedPolicyDocument</Code>"

    duplicate_key =
      signed_iam_conn(%{
        "Action" => "PutGroupPolicy",
        "GroupName" => group_name,
        "PolicyName" => policy_name,
        "PolicyDocument" =>
          ~s({"Statement":{"Effect":"Allow","Action":"s3:GetObject","Action":"s3:PutObject","Resource":"arn:aws:s3:::dup/*"}})
      })
      |> call()

    assert duplicate_key.status == 400
    assert duplicate_key.resp_body =~ "<Code>MalformedPolicyDocument</Code>"

    assert 200 =
             signed_iam_conn(%{
               "Action" => "PutUserPolicy",
               "UserName" => user_name,
               "PolicyName" => policy_name,
               "PolicyDocument" => identity_policy("s3:GetObject", "arn:aws:s3:::stable/*")
             })
             |> call()
             |> Map.fetch!(:status)

    invalid_replacement =
      signed_iam_conn(%{
        "Action" => "PutUserPolicy",
        "UserName" => user_name,
        "PolicyName" => policy_name,
        "PolicyDocument" =>
          ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:PutObject","Resource":"arn:aws:s3:::stable/*"}})
      })
      |> call()

    assert invalid_replacement.status == 400
    assert invalid_replacement.resp_body =~ "<Code>MalformedPolicyDocument</Code>"

    get_after_invalid_replace =
      signed_iam_conn(%{
        "Action" => "GetUserPolicy",
        "UserName" => user_name,
        "PolicyName" => policy_name
      })
      |> call()

    assert get_after_invalid_replace.status == 200

    assert get_in(decoded_policy_document(get_after_invalid_replace.resp_body), [
             "Statement",
             "Action"
           ]) == "s3:GetObject"

    over_quota =
      signed_iam_conn(%{
        "Action" => "PutUserPolicy",
        "UserName" => user_name,
        "PolicyName" => "TooLargePolicy",
        "PolicyDocument" =>
          identity_policy(
            "s3:GetObject",
            "arn:aws:s3:::#{String.duplicate("a", 2_200)}/*"
          )
      })
      |> call()

    assert over_quota.status == 409
    assert over_quota.resp_body =~ "<Code>LimitExceeded</Code>"

    role_over_quota =
      signed_iam_conn(%{
        "Action" => "PutRolePolicy",
        "RoleName" => role_name,
        "PolicyName" => "TooLargeRolePolicy",
        "PolicyDocument" =>
          identity_policy(
            "s3:GetObject",
            "arn:aws:s3:::#{String.duplicate("r", 10_500)}/*"
          )
      })
      |> call()

    assert role_over_quota.status == 409
    assert role_over_quota.resp_body =~ "<Code>LimitExceeded</Code>"

    invalid_pagination =
      signed_iam_conn(%{
        "Action" => "ListUserPolicies",
        "UserName" => user_name,
        "MaxItems" => "0"
      })
      |> call()

    assert invalid_pagination.status == 400
    assert invalid_pagination.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_pagination.resp_body =~ "MaxItems"

    duplicate_get =
      [
        {"Action", "ListUserPolicies"},
        {"Action", "ListGroupPolicies"},
        {"Version", "2010-05-08"}
      ]
      |> raw_iam_query()
      |> signed_raw_iam_conn()
      |> call()

    assert duplicate_get.status == 400
    assert duplicate_get.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert duplicate_get.resp_body =~ "must not be repeated"
  end

  test "IAM inline policy quota is enforced atomically under concurrent Query puts" do
    user_name = unique_name("policy-race-user")

    policy_document =
      identity_policy("s3:GetObject", "arn:aws:s3:::#{String.duplicate("a", 1_200)}/*")

    compact_size = policy_document |> Jason.decode!() |> Jason.encode!() |> String.length()

    assert compact_size <= 2_048
    assert compact_size * 2 > 2_048
    assert {:ok, _user} = IAM.create_user(user_name: user_name)

    results =
      1..3
      |> Task.async_stream(
        fn index ->
          response =
            signed_iam_conn(%{
              "Action" => "PutUserPolicy",
              "UserName" => user_name,
              "PolicyName" => "ConcurrentPolicy#{index}",
              "PolicyDocument" => policy_document
            })
            |> call()

          {response.status, response.resp_body}
        end,
        max_concurrency: 3,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, fn {status, _body} -> status == 200 end) == 1

    limit_exceeded = Enum.filter(results, fn {status, _body} -> status == 409 end)
    assert length(limit_exceeded) == 2

    assert Enum.all?(limit_exceeded, fn {_status, body} ->
             body =~ "<Code>LimitExceeded</Code>"
           end)

    assert {:ok, [_policy]} = IAM.list_user_policies_strict(user_name)
  end

  test "IAM managed policy attachment Query parameters and resource state fail closed" do
    user_name = unique_name("attached-fail-user")
    group_name = unique_name("attached-fail-group")
    role_name = unique_name("attached-fail-role")

    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, _group} = IAM.create_group(group_name: group_name)
    assert {:ok, _role} = IAM.create_role(role_name: role_name, trust_policy: root_trust_policy())

    assert {:ok, policy} =
             IAM.create_managed_policy(
               name: unique_name("AttachedFailPolicy"),
               path: "/attached/fail/",
               policy: identity_policy("s3:GetObject", "arn:aws:s3:::attached-fail/*")
             )

    invalid_policy_arn =
      signed_iam_conn(%{
        "Action" => "AttachUserPolicy",
        "UserName" => user_name,
        "PolicyArn" => "arn:aws:iam:::policy/bad*policy"
      })
      |> call()

    assert invalid_policy_arn.status == 400
    assert invalid_policy_arn.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_policy_arn.resp_body =~ "PolicyArn"

    whitespace_policy_arn =
      [
        {"Action", "AttachUserPolicy"},
        {"Version", "2010-05-08"},
        {"UserName", user_name},
        {"PolicyArn", " #{policy.policy_arn} "}
      ]
      |> raw_iam_query()
      |> signed_raw_iam_conn()
      |> call()

    assert whitespace_policy_arn.status == 400
    assert whitespace_policy_arn.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert whitespace_policy_arn.resp_body =~ "PolicyArn"

    missing_policy =
      signed_iam_conn(%{
        "Action" => "AttachUserPolicy",
        "UserName" => user_name,
        "PolicyArn" => IAM.managed_policy_arn(unique_name("MissingAttachedPolicy"))
      })
      |> call()

    assert missing_policy.status == 404
    assert missing_policy.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_user =
      signed_iam_conn(%{
        "Action" => "AttachUserPolicy",
        "UserName" => "missing-attached-user",
        "PolicyArn" => policy.policy_arn
      })
      |> call()

    assert missing_user.status == 404
    assert missing_user.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_group_list =
      signed_iam_conn(%{
        "Action" => "ListAttachedGroupPolicies",
        "GroupName" => "missing-attached-group"
      })
      |> call()

    assert missing_group_list.status == 404
    assert missing_group_list.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_group_detach =
      signed_iam_conn(%{
        "Action" => "DetachGroupPolicy",
        "GroupName" => "missing-attached-group",
        "PolicyArn" => policy.policy_arn
      })
      |> call()

    assert missing_group_detach.status == 404
    assert missing_group_detach.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_role_list =
      signed_iam_conn(%{
        "Action" => "ListAttachedRolePolicies",
        "RoleName" => "missing-attached-role"
      })
      |> call()

    assert missing_role_list.status == 404
    assert missing_role_list.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_role_detach =
      signed_iam_conn(%{
        "Action" => "DetachRolePolicy",
        "RoleName" => "missing-attached-role",
        "PolicyArn" => policy.policy_arn
      })
      |> call()

    assert missing_role_detach.status == 404
    assert missing_role_detach.resp_body =~ "<Code>NoSuchEntity</Code>"

    invalid_role_name =
      signed_iam_conn(%{
        "Action" => "AttachRolePolicy",
        "RoleName" => "bad*role",
        "PolicyArn" => policy.policy_arn
      })
      |> call()

    assert invalid_role_name.status == 400
    assert invalid_role_name.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_role_name.resp_body =~ "RoleName"

    invalid_path_prefix =
      signed_iam_conn(%{
        "Action" => "ListAttachedUserPolicies",
        "UserName" => user_name,
        "PathPrefix" => "/bad//path/"
      })
      |> call()

    assert invalid_path_prefix.status == 400
    assert invalid_path_prefix.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_path_prefix.resp_body =~ "PathPrefix"

    unsupported_permissions_boundary =
      signed_iam_conn(%{
        "Action" => "AttachGroupPolicy",
        "GroupName" => group_name,
        "PolicyArn" => policy.policy_arn,
        "PermissionsBoundary" => policy.policy_arn
      })
      |> call()

    assert unsupported_permissions_boundary.status == 400
    assert unsupported_permissions_boundary.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert unsupported_permissions_boundary.resp_body =~ "PermissionsBoundary is not implemented"

    unsupported_role_permissions_boundary =
      signed_iam_conn(%{
        "Action" => "AttachRolePolicy",
        "RoleName" => role_name,
        "PolicyArn" => policy.policy_arn,
        "PermissionsBoundary" => policy.policy_arn
      })
      |> call()

    assert unsupported_role_permissions_boundary.status == 400
    assert unsupported_role_permissions_boundary.resp_body =~ "<Code>InvalidParameterValue</Code>"

    assert unsupported_role_permissions_boundary.resp_body =~
             "PermissionsBoundary is not implemented"

    quota_user = unique_name("attached-quota-user")
    quota_group = unique_name("attached-quota-group")
    quota_role = unique_name("attached-quota-role")
    assert {:ok, _quota_user} = IAM.create_user(user_name: quota_user)
    assert {:ok, _quota_group} = IAM.create_group(group_name: quota_group)

    assert {:ok, _quota_role} =
             IAM.create_role(role_name: quota_role, trust_policy: root_trust_policy())

    quota_policies =
      for index <- 1..11 do
        assert {:ok, quota_policy} =
                 IAM.create_managed_policy(
                   name: unique_name("QuotaAttachedPolicy#{index}"),
                   path: "/attached/quota/",
                   policy: identity_policy("s3:GetObject", "arn:aws:s3:::attached-quota/*")
                 )

        quota_policy
      end

    quota_policies
    |> Enum.take(10)
    |> Enum.each(fn quota_policy ->
      assert 200 =
               signed_iam_conn(%{
                 "Action" => "AttachUserPolicy",
                 "UserName" => quota_user,
                 "PolicyArn" => quota_policy.policy_arn
               })
               |> call()
               |> Map.fetch!(:status)

      assert 200 =
               signed_iam_conn(%{
                 "Action" => "AttachGroupPolicy",
                 "GroupName" => quota_group,
                 "PolicyArn" => quota_policy.policy_arn
               })
               |> call()
               |> Map.fetch!(:status)

      assert 200 =
               signed_iam_conn(%{
                 "Action" => "AttachRolePolicy",
                 "RoleName" => quota_role,
                 "PolicyArn" => quota_policy.policy_arn
               })
               |> call()
               |> Map.fetch!(:status)
    end)

    quota_policy = List.last(quota_policies)

    user_quota_exceeded =
      signed_iam_conn(%{
        "Action" => "AttachUserPolicy",
        "UserName" => quota_user,
        "PolicyArn" => quota_policy.policy_arn
      })
      |> call()

    assert user_quota_exceeded.status == 409
    assert user_quota_exceeded.resp_body =~ "<Code>LimitExceeded</Code>"

    group_quota_exceeded =
      signed_iam_conn(%{
        "Action" => "AttachGroupPolicy",
        "GroupName" => quota_group,
        "PolicyArn" => quota_policy.policy_arn
      })
      |> call()

    assert group_quota_exceeded.status == 409
    assert group_quota_exceeded.resp_body =~ "<Code>LimitExceeded</Code>"

    role_quota_exceeded =
      signed_iam_conn(%{
        "Action" => "AttachRolePolicy",
        "RoleName" => quota_role,
        "PolicyArn" => quota_policy.policy_arn
      })
      |> call()

    assert role_quota_exceeded.status == 409
    assert role_quota_exceeded.resp_body =~ "<Code>LimitExceeded</Code>"

    duplicate_get =
      [
        {"Action", "ListAttachedUserPolicies"},
        {"Action", "ListAttachedGroupPolicies"},
        {"Version", "2010-05-08"}
      ]
      |> raw_iam_query()
      |> signed_raw_iam_conn()
      |> call()

    assert duplicate_get.status == 400
    assert duplicate_get.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert duplicate_get.resp_body =~ "must not be repeated"
  end

  test "IAM group Query API accepts signed POST forms for group actions" do
    group_name = unique_name("post-query-group")
    user_name = unique_name("post-query-user")

    assert {:ok, _user} = IAM.create_user(user_name: user_name)

    assert 200 =
             signed_iam_form_conn(%{"Action" => "CreateGroup", "GroupName" => group_name})
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{"Action" => "GetGroup", "GroupName" => group_name})
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{"Action" => "ListGroups"})
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "AddUserToGroup",
               "GroupName" => group_name,
               "UserName" => user_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "ListGroupsForUser",
               "UserName" => user_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "RemoveUserFromGroup",
               "GroupName" => group_name,
               "UserName" => user_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{"Action" => "DeleteGroup", "GroupName" => group_name})
             |> call()
             |> Map.fetch!(:status)
  end

  test "IAM role Query API accepts signed POST forms for role actions" do
    role_name = unique_name("post-query-role")

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "CreateRole",
               "RoleName" => role_name,
               "AssumeRolePolicyDocument" => Jason.encode!(root_trust_policy()),
               "Tags.member.1.Key" => "team",
               "Tags.member.1.Value" => "core"
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{"Action" => "GetRole", "RoleName" => role_name})
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{"Action" => "ListRoles"})
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{"Action" => "ListRoleTags", "RoleName" => role_name})
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "TagRole",
               "RoleName" => role_name,
               "Tags.member.1.Key" => "env",
               "Tags.member.1.Value" => "dev"
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "UntagRole",
               "RoleName" => role_name,
               "TagKeys.member.1" => "env"
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{"Action" => "DeleteRole", "RoleName" => role_name})
             |> call()
             |> Map.fetch!(:status)
  end

  test "IAM instance profile Query API accepts signed POST forms" do
    role_name = unique_name("post-profile-role")
    profile_name = unique_name("post-query-profile")

    assert {:ok, _role} = IAM.create_role(role_name: role_name, trust_policy: root_trust_policy())

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "CreateInstanceProfile",
               "InstanceProfileName" => profile_name,
               "Tags.member.1.Key" => "team",
               "Tags.member.1.Value" => "core"
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "AddRoleToInstanceProfile",
               "InstanceProfileName" => profile_name,
               "RoleName" => role_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "GetInstanceProfile",
               "InstanceProfileName" => profile_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{"Action" => "ListInstanceProfiles"})
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "ListInstanceProfilesForRole",
               "RoleName" => role_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "ListInstanceProfileTags",
               "InstanceProfileName" => profile_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "TagInstanceProfile",
               "InstanceProfileName" => profile_name,
               "Tags.member.1.Key" => "env",
               "Tags.member.1.Value" => "dev"
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "UntagInstanceProfile",
               "InstanceProfileName" => profile_name,
               "TagKeys.member.1" => "env"
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "RemoveRoleFromInstanceProfile",
               "InstanceProfileName" => profile_name,
               "RoleName" => role_name
             })
             |> call()
             |> Map.fetch!(:status)

    assert 200 =
             signed_iam_form_conn(%{
               "Action" => "DeleteInstanceProfile",
               "InstanceProfileName" => profile_name
             })
             |> call()
             |> Map.fetch!(:status)
  end

  test "IAM server certificate Query API manages certificate lifecycle" do
    cert_name = unique_name("query-cert")
    renamed = unique_name("query-cert-renamed")
    {certificate_body, private_key, certificate_chain} = server_certificate_pems()

    upload =
      signed_iam_form_conn(%{
        "Action" => "UploadServerCertificate",
        "ServerCertificateName" => cert_name,
        "Path" => "/service/",
        "CertificateBody" => certificate_body,
        "PrivateKey" => private_key,
        "CertificateChain" => certificate_chain,
        "Tags.member.1.Key" => "Env",
        "Tags.member.1.Value" => "prod"
      })
      |> call()

    assert upload.status == 200
    assert upload.resp_body =~ "<UploadServerCertificateResponse"
    assert upload.resp_body =~ "<ServerCertificateName>#{cert_name}</ServerCertificateName>"
    assert upload.resp_body =~ "<Path>/service/</Path>"
    assert upload.resp_body =~ "<Arn>arn:aws:iam:::server-certificate/service/#{cert_name}</Arn>"
    assert upload.resp_body =~ "<Expiration>"
    refute upload.resp_body =~ "PRIVATE KEY"

    get =
      signed_iam_conn(%{
        "Action" => "GetServerCertificate",
        "ServerCertificateName" => cert_name
      })
      |> call()

    assert get.status == 200
    assert get.resp_body =~ "<GetServerCertificateResponse"
    assert get.resp_body =~ "<CertificateBody>"
    assert get.resp_body =~ "BEGIN CERTIFICATE"
    assert get.resp_body =~ "<CertificateChain>"
    refute get.resp_body =~ "PRIVATE KEY"

    list =
      signed_iam_conn(%{
        "Action" => "ListServerCertificates",
        "PathPrefix" => "/service/",
        "MaxItems" => "1"
      })
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<ListServerCertificatesResponse"
    assert list.resp_body =~ "<ServerCertificateMetadataList>"
    assert list.resp_body =~ "<ServerCertificateName>#{cert_name}</ServerCertificateName>"
    refute list.resp_body =~ "<CertificateBody>"

    assert 200 =
             signed_iam_conn(%{
               "Action" => "TagServerCertificate",
               "ServerCertificateName" => cert_name,
               "Tags.member.1.Key" => "env",
               "Tags.member.1.Value" => "dev"
             })
             |> call()
             |> Map.fetch!(:status)

    list_tags =
      signed_iam_conn(%{
        "Action" => "ListServerCertificateTags",
        "ServerCertificateName" => cert_name
      })
      |> call()

    assert list_tags.status == 200
    assert Enum.sort(xml_tag_pairs(list_tags.resp_body)) == [{"Env", "prod"}, {"env", "dev"}]

    assert 200 =
             signed_iam_conn(%{
               "Action" => "UntagServerCertificate",
               "ServerCertificateName" => cert_name,
               "TagKeys.member.1" => "env"
             })
             |> call()
             |> Map.fetch!(:status)

    list_tags_after_untag =
      signed_iam_conn(%{
        "Action" => "ListServerCertificateTags",
        "ServerCertificateName" => cert_name
      })
      |> call()

    assert xml_tag_pairs(list_tags_after_untag.resp_body) == [{"Env", "prod"}]

    update =
      signed_iam_conn(%{
        "Action" => "UpdateServerCertificate",
        "ServerCertificateName" => cert_name,
        "NewServerCertificateName" => renamed,
        "NewPath" => "/service/renamed/"
      })
      |> call()

    assert update.status == 200
    assert update.resp_body =~ "<UpdateServerCertificateResponse"

    missing_old =
      signed_iam_conn(%{
        "Action" => "GetServerCertificate",
        "ServerCertificateName" => cert_name
      })
      |> call()

    assert missing_old.status == 404
    assert missing_old.resp_body =~ "<Code>NoSuchEntity</Code>"

    renamed_get =
      signed_iam_conn(%{
        "Action" => "GetServerCertificate",
        "ServerCertificateName" => renamed
      })
      |> call()

    assert renamed_get.status == 200
    assert renamed_get.resp_body =~ "<Path>/service/renamed/</Path>"

    assert renamed_get.resp_body =~
             "<Arn>arn:aws:iam:::server-certificate/service/renamed/#{renamed}</Arn>"

    assert 200 =
             signed_iam_conn(%{
               "Action" => "DeleteServerCertificate",
               "ServerCertificateName" => renamed
             })
             |> call()
             |> Map.fetch!(:status)

    missing_after_delete =
      signed_iam_conn(%{
        "Action" => "GetServerCertificate",
        "ServerCertificateName" => renamed
      })
      |> call()

    assert missing_after_delete.status == 404
  end

  test "IAM server certificate upload rejects key mismatch and unsupported params" do
    cert_name = unique_name("bad-cert")
    {certificate_body, _private_key, _certificate_chain} = server_certificate_pems()
    {_other_certificate_body, mismatched_private_key, _other_chain} = server_certificate_pems()

    mismatch =
      signed_iam_form_conn(%{
        "Action" => "UploadServerCertificate",
        "ServerCertificateName" => cert_name,
        "CertificateBody" => certificate_body,
        "PrivateKey" => mismatched_private_key
      })
      |> call()

    assert mismatch.status == 400
    assert mismatch.resp_body =~ "<Code>KeyPairMismatch</Code>"

    assert {:error, :not_found} = IAM.get_server_certificate(cert_name)

    unsupported =
      signed_iam_form_conn(%{
        "Action" => "UploadServerCertificate",
        "ServerCertificateName" => unique_name("unsupported-cert"),
        "CertificateBody" => certificate_body,
        "PrivateKey" => mismatched_private_key,
        "Usage" => "CloudFront"
      })
      |> call()

    assert unsupported.status == 400
    assert unsupported.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert unsupported.resp_body =~ "Usage is not implemented"
  end

  test "IAM server certificate Query API rejects GET upload and empty update" do
    cert_name = unique_name("secure-cert")
    {certificate_body, private_key, _certificate_chain} = server_certificate_pems()

    get_upload =
      signed_iam_conn(%{
        "Action" => "UploadServerCertificate",
        "ServerCertificateName" => unique_name("get-cert"),
        "CertificateBody" => "not-a-certificate",
        "PrivateKey" => "should-not-be-accepted-in-url"
      })
      |> call()

    assert get_upload.status == 400
    assert get_upload.resp_body =~ "<Code>InvalidRequest</Code>"
    assert get_upload.resp_body =~ "requires a signed POST form request"

    assert {:ok, _certificate} =
             IAM.upload_server_certificate(
               server_certificate_name: cert_name,
               certificate_body: certificate_body,
               private_key: private_key
             )

    empty_update =
      signed_iam_conn(%{
        "Action" => "UpdateServerCertificate",
        "ServerCertificateName" => cert_name
      })
      |> call()

    assert empty_update.status == 400
    assert empty_update.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert empty_update.resp_body =~ "NewServerCertificateName or NewPath is required"

    assert {:error, :server_certificate_update_empty} =
             IAM.update_server_certificate_strict(cert_name, %{})
  end

  test "IAM user Query API requires root principal" do
    assert {:ok, user} = IAM.create_user(user_name: unique_name("user-query-denied"))

    assert {:ok, key} =
             IAM.create_access_key(user_name: user.user_name, secret_key: "alice-secret")

    response =
      signed_iam_conn(%{"Action" => "ListUsers"},
        access_key: key.access_key_id,
        secret: "alice-secret"
      )
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    assert response.resp_body =~ "Only the root principal"
  end

  test "IAM user Query parameters fail closed" do
    non_root_path =
      signed_iam_conn(%{
        "Action" => "CreateUser",
        "Path" => "/engineering/",
        "UserName" => unique_name("path-user")
      })
      |> call()

    assert non_root_path.status == 400
    assert non_root_path.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert non_root_path.resp_body =~ "Only the root IAM user path"

    missing_boundary_policy =
      signed_iam_conn(%{
        "Action" => "CreateUser",
        "UserName" => unique_name("boundary-user"),
        "PermissionsBoundary" => "arn:aws:iam:::policy/boundary"
      })
      |> call()

    assert missing_boundary_policy.status == 404
    assert missing_boundary_policy.resp_body =~ "<Code>NoSuchEntity</Code>"

    duplicate_name =
      signed_iam_conn(%{
        "Action" => "CreateUser",
        "UserName" => "CaseFoldUser"
      })
      |> call()

    assert duplicate_name.status == 200

    duplicate_name_case =
      signed_iam_conn(%{
        "Action" => "CreateUser",
        "UserName" => "casefolduser"
      })
      |> call()

    assert duplicate_name_case.status == 409
    assert duplicate_name_case.resp_body =~ "<Code>EntityAlreadyExists</Code>"

    delete_conflict_name = unique_name("delete-conflict-user")
    assert {:ok, conflict_user} = IAM.create_user(user_name: delete_conflict_name)
    assert {:ok, _key} = IAM.create_access_key(user_name: conflict_user.user_name)

    delete_conflict =
      signed_iam_conn(%{
        "Action" => "DeleteUser",
        "UserName" => delete_conflict_name
      })
      |> call()

    assert delete_conflict.status == 409
    assert delete_conflict.resp_body =~ "<Code>DeleteConflict</Code>"

    reserved_key =
      signed_iam_conn(%{
        "Action" => "TagUser",
        "UserName" => "missing-user",
        "Tags.member.1.Key" => "aws:team",
        "Tags.member.1.Value" => "core"
      })
      |> call()

    assert reserved_key.status == 400
    assert reserved_key.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert reserved_key.resp_body =~ "valid tag keys and values"

    duplicate_tag_key =
      signed_iam_conn(%{
        "Action" => "TagUser",
        "UserName" => "missing-user",
        "Tags.member.1.Key" => "team",
        "Tags.member.1.Value" => "core",
        "Tags.member.2.Key" => "TEAM",
        "Tags.member.2.Value" => "ops"
      })
      |> call()

    assert duplicate_tag_key.status == 400
    assert duplicate_tag_key.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert duplicate_tag_key.resp_body =~ "duplicate tag keys"

    invalid_pagination =
      signed_iam_conn(%{
        "Action" => "ListUsers",
        "MaxItems" => "0"
      })
      |> call()

    assert invalid_pagination.status == 400
    assert invalid_pagination.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_pagination.resp_body =~ "MaxItems"
  end

  test "IAM group Query parameters and resource state fail closed" do
    non_root_path =
      signed_iam_conn(%{
        "Action" => "CreateGroup",
        "Path" => "/engineering/",
        "GroupName" => unique_name("path-group")
      })
      |> call()

    assert non_root_path.status == 400
    assert non_root_path.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert non_root_path.resp_body =~ "Only the root IAM group path"

    unsupported_tags =
      signed_iam_conn(%{
        "Action" => "CreateGroup",
        "GroupName" => unique_name("unsupported-group"),
        "Tags.member.1.Key" => "team",
        "Tags.member.1.Value" => "core"
      })
      |> call()

    assert unsupported_tags.status == 400
    assert unsupported_tags.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert unsupported_tags.resp_body =~ "Tags.member.1.Key is not implemented"

    duplicate_name = unique_name("CaseFoldGroup")

    assert 200 =
             signed_iam_conn(%{
               "Action" => "CreateGroup",
               "GroupName" => duplicate_name
             })
             |> call()
             |> Map.fetch!(:status)

    duplicate_name_case =
      signed_iam_conn(%{
        "Action" => "CreateGroup",
        "GroupName" => String.downcase(duplicate_name)
      })
      |> call()

    assert duplicate_name_case.status == 409
    assert duplicate_name_case.resp_body =~ "<Code>EntityAlreadyExists</Code>"

    case_group = unique_name("CaseLookupGroup")
    case_user = unique_name("CaseLookupUser")
    assert {:ok, _case_group} = IAM.create_group(group_name: case_group)
    assert {:ok, _case_user} = IAM.create_user(user_name: case_user)
    assert :ok = IAM.add_user_to_group(case_user, case_group)

    lowercase_get_group =
      signed_iam_conn(%{
        "Action" => "GetGroup",
        "GroupName" => String.downcase(case_group)
      })
      |> call()

    assert lowercase_get_group.status == 200
    assert xml_value(lowercase_get_group.resp_body, "GroupName") == case_group
    assert xml_values(lowercase_get_group.resp_body, "UserName") == [case_user]

    lowercase_groups_for_user =
      signed_iam_conn(%{
        "Action" => "ListGroupsForUser",
        "UserName" => String.downcase(case_user)
      })
      |> call()

    assert lowercase_groups_for_user.status == 200
    assert xml_values(lowercase_groups_for_user.resp_body, "GroupName") == [case_group]

    valid_group = unique_name("valid-group")
    valid_user = unique_name("valid-user")
    assert {:ok, _group} = IAM.create_group(group_name: valid_group)
    assert {:ok, _user} = IAM.create_user(user_name: valid_user)

    missing_user =
      signed_iam_conn(%{
        "Action" => "AddUserToGroup",
        "GroupName" => valid_group,
        "UserName" => "missing-user"
      })
      |> call()

    assert missing_user.status == 404
    assert missing_user.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_group =
      signed_iam_conn(%{
        "Action" => "AddUserToGroup",
        "GroupName" => "missing-group",
        "UserName" => valid_user
      })
      |> call()

    assert missing_group.status == 404
    assert missing_group.resp_body =~ "<Code>NoSuchEntity</Code>"

    non_member_remove =
      signed_iam_conn(%{
        "Action" => "RemoveUserFromGroup",
        "GroupName" => valid_group,
        "UserName" => valid_user
      })
      |> call()

    assert non_member_remove.status == 404
    assert non_member_remove.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_groups_for_user =
      signed_iam_conn(%{
        "Action" => "ListGroupsForUser",
        "UserName" => "missing-user"
      })
      |> call()

    assert missing_groups_for_user.status == 404
    assert missing_groups_for_user.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_get =
      signed_iam_conn(%{
        "Action" => "GetGroup",
        "GroupName" => "missing-group"
      })
      |> call()

    assert missing_get.status == 404
    assert missing_get.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_delete =
      signed_iam_conn(%{
        "Action" => "DeleteGroup",
        "GroupName" => "missing-group"
      })
      |> call()

    assert missing_delete.status == 404
    assert missing_delete.resp_body =~ "<Code>NoSuchEntity</Code>"

    invalid_pagination =
      signed_iam_conn(%{
        "Action" => "ListGroups",
        "MaxItems" => "0"
      })
      |> call()

    assert invalid_pagination.status == 400
    assert invalid_pagination.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_pagination.resp_body =~ "MaxItems"

    inline_conflict = unique_name("inline-conflict-group")
    policy_conflict = unique_name("managed-conflict-group")
    policy_name = unique_name("managed-conflict-policy")
    policy_arn = IAM.managed_policy_arn(policy_name, "/query/groups/")

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::bucket/*"}})

    assert {:ok, _inline_group} = IAM.create_group(group_name: inline_conflict)
    assert :ok = IAM.put_group_policy(inline_conflict, "inline", policy)

    inline_delete =
      signed_iam_conn(%{
        "Action" => "DeleteGroup",
        "GroupName" => inline_conflict
      })
      |> call()

    assert inline_delete.status == 409
    assert inline_delete.resp_body =~ "<Code>DeleteConflict</Code>"
    assert inline_delete.resp_body =~ "Cannot delete the group"

    assert {:ok, _policy_group} = IAM.create_group(group_name: policy_conflict)

    assert {:ok, _policy} =
             IAM.create_managed_policy(name: policy_name, path: "/query/groups/", policy: policy)

    assert :ok = IAM.attach_group_policy(policy_conflict, policy_arn)

    managed_policy_delete =
      signed_iam_conn(%{
        "Action" => "DeleteGroup",
        "GroupName" => policy_conflict
      })
      |> call()

    assert managed_policy_delete.status == 409
    assert managed_policy_delete.resp_body =~ "<Code>DeleteConflict</Code>"
  end

  test "IAM role Query parameters and resource state fail closed" do
    trust_policy_document = Jason.encode!(root_trust_policy())

    non_root_path =
      signed_iam_conn(%{
        "Action" => "CreateRole",
        "Path" => "/engineering/",
        "RoleName" => unique_name("path-role"),
        "AssumeRolePolicyDocument" => trust_policy_document
      })
      |> call()

    assert non_root_path.status == 400
    assert non_root_path.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert non_root_path.resp_body =~ "Only the root IAM role path"

    missing_trust_policy =
      signed_iam_conn(%{
        "Action" => "CreateRole",
        "RoleName" => unique_name("missing-trust-role")
      })
      |> call()

    assert missing_trust_policy.status == 400
    assert missing_trust_policy.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert missing_trust_policy.resp_body =~ "AssumeRolePolicyDocument"

    invalid_role_name =
      signed_iam_conn(%{
        "Action" => "CreateRole",
        "RoleName" => "bad*role",
        "AssumeRolePolicyDocument" => trust_policy_document
      })
      |> call()

    assert invalid_role_name.status == 400
    assert invalid_role_name.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_role_name.resp_body =~ "RoleName"

    malformed_trust_policy =
      signed_iam_conn(%{
        "Action" => "CreateRole",
        "RoleName" => unique_name("malformed-trust-role"),
        "AssumeRolePolicyDocument" => ~s({"Statement":)
      })
      |> call()

    assert malformed_trust_policy.status == 400
    assert malformed_trust_policy.resp_body =~ "<Code>MalformedPolicyDocument</Code>"

    invalid_trust_policy =
      signed_iam_conn(%{
        "Action" => "CreateRole",
        "RoleName" => unique_name("invalid-trust-role"),
        "AssumeRolePolicyDocument" =>
          ~s({"Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"*"}})
      })
      |> call()

    assert invalid_trust_policy.status == 400
    assert invalid_trust_policy.resp_body =~ "<Code>MalformedPolicyDocument</Code>"

    invalid_duration =
      signed_iam_conn(%{
        "Action" => "CreateRole",
        "RoleName" => unique_name("duration-role"),
        "AssumeRolePolicyDocument" => trust_policy_document,
        "MaxSessionDuration" => "899"
      })
      |> call()

    assert invalid_duration.status == 400
    assert invalid_duration.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_duration.resp_body =~ "MaxSessionDuration"

    missing_boundary_policy =
      signed_iam_conn(%{
        "Action" => "CreateRole",
        "RoleName" => unique_name("boundary-role"),
        "AssumeRolePolicyDocument" => trust_policy_document,
        "PermissionsBoundary" => "arn:aws:iam:::policy/boundary"
      })
      |> call()

    assert missing_boundary_policy.status == 404
    assert missing_boundary_policy.resp_body =~ "<Code>NoSuchEntity</Code>"

    invalid_description =
      signed_iam_conn(%{
        "Action" => "CreateRole",
        "RoleName" => unique_name("description-role"),
        "AssumeRolePolicyDocument" => trust_policy_document,
        "Description" => String.duplicate("d", 1001)
      })
      |> call()

    assert invalid_description.status == 400
    assert invalid_description.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_description.resp_body =~ "Description"

    duplicate_name = unique_name("CaseFoldRole")

    assert 200 =
             signed_iam_conn(%{
               "Action" => "CreateRole",
               "RoleName" => duplicate_name,
               "AssumeRolePolicyDocument" => trust_policy_document
             })
             |> call()
             |> Map.fetch!(:status)

    duplicate_name_case =
      signed_iam_conn(%{
        "Action" => "CreateRole",
        "RoleName" => String.downcase(duplicate_name),
        "AssumeRolePolicyDocument" => trust_policy_document
      })
      |> call()

    assert duplicate_name_case.status == 409
    assert duplicate_name_case.resp_body =~ "<Code>EntityAlreadyExists</Code>"

    lowercase_get =
      signed_iam_conn(%{
        "Action" => "GetRole",
        "RoleName" => String.downcase(duplicate_name)
      })
      |> call()

    assert lowercase_get.status == 200
    assert xml_value(lowercase_get.resp_body, "RoleName") == duplicate_name

    reserved_key =
      signed_iam_conn(%{
        "Action" => "TagRole",
        "RoleName" => duplicate_name,
        "Tags.member.1.Key" => "aws:team",
        "Tags.member.1.Value" => "core"
      })
      |> call()

    assert reserved_key.status == 400
    assert reserved_key.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert reserved_key.resp_body =~ "valid tag keys and values"

    duplicate_tag_key =
      signed_iam_conn(%{
        "Action" => "TagRole",
        "RoleName" => duplicate_name,
        "Tags.member.1.Key" => "team",
        "Tags.member.1.Value" => "core",
        "Tags.member.2.Key" => "TEAM",
        "Tags.member.2.Value" => "ops"
      })
      |> call()

    assert duplicate_tag_key.status == 400
    assert duplicate_tag_key.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert duplicate_tag_key.resp_body =~ "duplicate tag keys"

    missing_get =
      signed_iam_conn(%{
        "Action" => "GetRole",
        "RoleName" => "missing-role"
      })
      |> call()

    assert missing_get.status == 404
    assert missing_get.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_tags =
      signed_iam_conn(%{
        "Action" => "ListRoleTags",
        "RoleName" => "missing-role"
      })
      |> call()

    assert missing_tags.status == 404
    assert missing_tags.resp_body =~ "<Code>NoSuchEntity</Code>"

    missing_delete =
      signed_iam_conn(%{
        "Action" => "DeleteRole",
        "RoleName" => "missing-role"
      })
      |> call()

    assert missing_delete.status == 404
    assert missing_delete.resp_body =~ "<Code>NoSuchEntity</Code>"

    invalid_path_prefix =
      signed_iam_conn(%{
        "Action" => "ListRoles",
        "PathPrefix" => "missing-slash/"
      })
      |> call()

    assert invalid_path_prefix.status == 400
    assert invalid_path_prefix.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_path_prefix.resp_body =~ "PathPrefix"

    invalid_pagination =
      signed_iam_conn(%{
        "Action" => "ListRoleTags",
        "RoleName" => duplicate_name,
        "MaxItems" => "0"
      })
      |> call()

    assert invalid_pagination.status == 400
    assert invalid_pagination.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_pagination.resp_body =~ "MaxItems"

    policy_conflict = unique_name("managed-conflict-role")
    policy_name = unique_name("managed-conflict-role-policy")
    policy_arn = IAM.managed_policy_arn(policy_name, "/query/roles/")

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::bucket/*"}})

    assert {:ok, _role} =
             IAM.create_role(role_name: policy_conflict, trust_policy: root_trust_policy())

    assert {:ok, _policy} =
             IAM.create_managed_policy(name: policy_name, path: "/query/roles/", policy: policy)

    assert :ok = IAM.attach_role_policy_strict(policy_conflict, policy_arn)

    managed_policy_delete =
      signed_iam_conn(%{
        "Action" => "DeleteRole",
        "RoleName" => policy_conflict
      })
      |> call()

    assert managed_policy_delete.status == 409
    assert managed_policy_delete.resp_body =~ "<Code>DeleteConflict</Code>"

    duplicate_get =
      [
        {"Action", "ListRoles"},
        {"Action", "GetRole"},
        {"Version", "2010-05-08"}
      ]
      |> raw_iam_query()
      |> signed_raw_iam_conn()
      |> call()

    assert duplicate_get.status == 400
    assert duplicate_get.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert duplicate_get.resp_body =~ "must not be repeated"
  end

  test "root virtual MFA lifecycle uses IAM Query XML and two consecutive activation codes" do
    name = unique_name("root-mfa")

    create =
      signed_iam_conn(%{
        "Action" => "CreateVirtualMFADevice",
        "VirtualMFADeviceName" => name
      })
      |> call()

    assert create.status == 200
    assert create.resp_body =~ "<CreateVirtualMFADeviceResponse"

    serial = xml_value(create.resp_body, "SerialNumber")
    seed = xml_value(create.resp_body, "Base32StringSeed")
    qrcode_png = Base.decode16!(xml_value(create.resp_body, "QRCodePNG"), case: :mixed)

    assert serial == "arn:aws:iam:::mfa/#{name}"
    assert seed =~ ~r/^[A-Z2-7]+$/
    assert <<137, 80, 78, 71, _rest::binary>> = qrcode_png

    enable_time = DateTime.utc_now()
    {code1, code2} = consecutive_codes(seed, enable_time)

    enable =
      signed_iam_conn(%{
        "Action" => "EnableMFADevice",
        "UserName" => "root",
        "SerialNumber" => serial,
        "AuthenticationCode1" => code1,
        "AuthenticationCode2" => code2
      })
      |> put_private(:maxio_now, enable_time)
      |> call()

    assert enable.status == 200
    assert enable.resp_body =~ "<EnableMFADeviceResponse"

    list =
      signed_iam_conn(%{"Action" => "ListMFADevices", "UserName" => "root"})
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<ListMFADevicesResponse"
    assert xml_value(list.resp_body, "SerialNumber") == serial
    assert xml_value(list.resp_body, "UserName") == "root"

    active_delete =
      signed_iam_conn(%{"Action" => "DeleteVirtualMFADevice", "SerialNumber" => serial})
      |> call()

    assert active_delete.status == 409
    assert active_delete.resp_body =~ "<Code>DeleteConflict</Code>"

    replay_time = DateTime.add(enable_time, 30, :second)
    {replayed_code1, replayed_code2} = consecutive_codes(seed, replay_time)

    replayed_resync =
      signed_iam_conn(%{
        "Action" => "ResyncMFADevice",
        "UserName" => "root",
        "SerialNumber" => serial,
        "AuthenticationCode1" => replayed_code1,
        "AuthenticationCode2" => replayed_code2
      })
      |> put_private(:maxio_now, replay_time)
      |> call()

    assert replayed_resync.status == 403
    assert replayed_resync.resp_body =~ "<Code>InvalidAuthenticationCode</Code>"

    resync_time = DateTime.add(enable_time, 60, :second)
    {resync_code1, resync_code2} = consecutive_codes(seed, resync_time)

    resync =
      signed_iam_conn(%{
        "Action" => "ResyncMFADevice",
        "UserName" => "root",
        "SerialNumber" => serial,
        "AuthenticationCode1" => resync_code1,
        "AuthenticationCode2" => resync_code2
      })
      |> put_private(:maxio_now, resync_time)
      |> call()

    assert resync.status == 200
    assert resync.resp_body =~ "<ResyncMFADeviceResponse"

    deactivate =
      signed_iam_conn(%{
        "Action" => "DeactivateMFADevice",
        "UserName" => "root",
        "SerialNumber" => serial
      })
      |> call()

    assert deactivate.status == 200
    assert deactivate.resp_body =~ "<DeactivateMFADeviceResponse"

    delete =
      signed_iam_conn(%{"Action" => "DeleteVirtualMFADevice", "SerialNumber" => serial})
      |> call()

    assert delete.status == 200
    assert delete.resp_body =~ "<DeleteVirtualMFADeviceResponse"
    assert IAM.get_mfa_device(serial) == :error

    # `IAM.get_mfa_device/1` 用裸 `:error` 表示"设备不存在"，
    # `fetch_manageable_mfa_device/2` 必须把它翻成 404 NoSuchEntity 的 `%QueryError{}`。
    missing_delete =
      signed_iam_conn(%{"Action" => "DeleteVirtualMFADevice", "SerialNumber" => serial})
      |> call()

    assert missing_delete.status == 404
    assert missing_delete.resp_body =~ "<Code>NoSuchEntity</Code>"
  end

  test "root can create a pending virtual MFA device and enable it for an IAM user" do
    assert {:ok, user} = IAM.create_user(user_name: unique_name("alice"))

    assert {:ok, key} =
             IAM.create_access_key(user_name: user.user_name, secret_key: "alice-secret")

    create =
      signed_iam_conn(%{
        "Action" => "CreateVirtualMFADevice",
        "VirtualMFADeviceName" => unique_name("alice-mfa")
      })
      |> call()

    assert create.status == 200
    serial = xml_value(create.resp_body, "SerialNumber")
    seed = xml_value(create.resp_body, "Base32StringSeed")

    enable_time = DateTime.utc_now()
    {code1, code2} = consecutive_codes(seed, enable_time)

    enable =
      signed_iam_conn(%{
        "Action" => "EnableMFADevice",
        "UserName" => user.user_name,
        "SerialNumber" => serial,
        "AuthenticationCode1" => code1,
        "AuthenticationCode2" => code2
      })
      |> put_private(:maxio_now, enable_time)
      |> call()

    assert enable.status == 200
    assert {:ok, %{principal_arn: principal_arn}} = IAM.get_mfa_device(serial)
    assert principal_arn == user.user_arn

    user_list =
      signed_iam_conn(%{"Action" => "ListMFADevices"},
        access_key: key.access_key_id,
        secret: "alice-secret"
      )
      |> call()

    assert user_list.status == 200
    assert xml_value(user_list.resp_body, "SerialNumber") == serial
    assert xml_value(user_list.resp_body, "UserName") == user.user_name
  end

  test "IAM user cannot manage another user's virtual MFA device" do
    assert {:ok, alice} = IAM.create_user(user_name: unique_name("alice-deny"))
    assert {:ok, bob} = IAM.create_user(user_name: unique_name("bob-deny"))

    assert {:ok, alice_key} =
             IAM.create_access_key(user_name: alice.user_name, secret_key: "alice-secret")

    {serial, _seed} = active_user_mfa(bob.user_name)

    response =
      signed_iam_conn(
        %{
          "Action" => "DeactivateMFADevice",
          "UserName" => bob.user_name,
          "SerialNumber" => serial
        },
        access_key: alice_key.access_key_id,
        secret: "alice-secret"
      )
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
  end

  test "IAM Query plug is isolated from STS and normal S3 dispatch" do
    sts =
      SigV4Request.signed_conn(:get, "/",
        query: %{"Action" => "GetCallerIdentity", "Version" => "2011-06-15"},
        service: "sts"
      )
      |> call()

    assert sts.status == 200
    assert sts.resp_body =~ "<GetCallerIdentityResponse"

    s3 =
      SigV4Request.signed_conn(:get, "/")
      |> call()

    assert s3.status == 200
    assert s3.resp_body =~ "<ListAllMyBucketsResult"

    wrong_scope =
      SigV4Request.signed_conn(:get, "/",
        query:
          base_query(%{
            "Action" => "CreateVirtualMFADevice",
            "VirtualMFADeviceName" => unique_name("wrong-scope")
          }),
        service: "sts"
      )
      |> call()

    assert wrong_scope.status == 403
    assert wrong_scope.resp_body =~ "<Code>AccessDenied</Code>"
    assert wrong_scope.resp_body =~ "Credential scope service must be iam"
  end

  test "POST IAM forms require exact payload hash and reject duplicate form parameters" do
    ok =
      signed_iam_form_conn(%{
        "Action" => "CreateVirtualMFADevice",
        "VirtualMFADeviceName" => unique_name("post-mfa")
      })
      |> call()

    assert ok.status == 200
    assert ok.resp_body =~ "<CreateVirtualMFADeviceResponse"

    duplicate_body = "Action=ListMFADevices&Action=ListMFADevices&Version=2010-05-08"

    duplicate =
      signed_iam_form_body(duplicate_body)
      |> call()

    assert duplicate.status == 400
    assert duplicate.resp_body =~ "IAM form parameters must not be repeated"

    unsigned_payload =
      signed_iam_form_conn(%{"Action" => "ListMFADevices"},
        content_sha256_override: "UNSIGNED-PAYLOAD"
      )
      |> call()

    assert unsigned_payload.status == 403
    assert unsigned_payload.resp_body =~ "must sign the exact payload hash"
  end

  test "root manages OpenID Connect providers through IAM Query XML" do
    issuer = unique_issuer("query")
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    thumbprint = sha1_hex("root-ca")
    put_oidc_discovery_fixture(issuer, public_jwks(jwk), thumbprints: [thumbprint])

    create =
      signed_iam_conn(%{
        "Action" => "CreateOpenIDConnectProvider",
        "Url" => issuer,
        "ClientIDList.member.1" => "sts.amazonaws.com",
        "ClientIDList.member.2" => "console.maxio.test",
        "Tags.member.1.Key" => "team",
        "Tags.member.1.Value" => "core",
        "Tags.member.2.Key" => "env",
        "Tags.member.2.Value" => "dev"
      })
      |> call()

    assert create.status == 200
    assert create.resp_body =~ "<CreateOpenIDConnectProviderResponse"
    assert xml_tag_pairs(create.resp_body) == [{"env", "dev"}, {"team", "core"}]
    provider_arn = xml_value(create.resp_body, "OpenIDConnectProviderArn")

    list =
      signed_iam_conn(%{"Action" => "ListOpenIDConnectProviders"})
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<ListOpenIDConnectProvidersResponse"
    assert list.resp_body =~ "<Arn>#{provider_arn}</Arn>"

    get =
      signed_iam_conn(%{
        "Action" => "GetOpenIDConnectProvider",
        "OpenIDConnectProviderArn" => provider_arn
      })
      |> call()

    assert get.status == 200
    assert xml_value(get.resp_body, "Url") == issuer
    assert get.resp_body =~ "<member>sts.amazonaws.com</member>"
    assert get.resp_body =~ "<member>console.maxio.test</member>"
    assert get.resp_body =~ "<member>#{thumbprint}</member>"
    assert xml_tag_pairs(get.resp_body) == [{"env", "dev"}, {"team", "core"}]

    list_tags =
      signed_iam_conn(%{
        "Action" => "ListOpenIDConnectProviderTags",
        "OpenIDConnectProviderArn" => provider_arn
      })
      |> call()

    assert list_tags.status == 200
    assert list_tags.resp_body =~ "<ListOpenIDConnectProviderTagsResponse"
    assert xml_value(list_tags.resp_body, "IsTruncated") == "false"
    assert xml_tag_pairs(list_tags.resp_body) == [{"env", "dev"}, {"team", "core"}]

    first_tag_page =
      signed_iam_conn(%{
        "Action" => "ListOpenIDConnectProviderTags",
        "OpenIDConnectProviderArn" => provider_arn,
        "MaxItems" => "1"
      })
      |> call()

    assert first_tag_page.status == 200
    assert xml_value(first_tag_page.resp_body, "IsTruncated") == "true"
    assert xml_tag_pairs(first_tag_page.resp_body) == [{"env", "dev"}]
    tag_marker = xml_value(first_tag_page.resp_body, "Marker")

    second_tag_page =
      signed_iam_conn(%{
        "Action" => "ListOpenIDConnectProviderTags",
        "OpenIDConnectProviderArn" => provider_arn,
        "MaxItems" => "1",
        "Marker" => tag_marker
      })
      |> call()

    assert second_tag_page.status == 200
    assert xml_value(second_tag_page.resp_body, "IsTruncated") == "false"
    assert xml_tag_pairs(second_tag_page.resp_body) == [{"team", "core"}]

    tag_update =
      signed_iam_conn(%{
        "Action" => "TagOpenIDConnectProvider",
        "OpenIDConnectProviderArn" => provider_arn,
        "Tags.member.1.Key" => "env",
        "Tags.member.1.Value" => "prod",
        "Tags.member.2.Key" => "stage",
        "Tags.member.2.Value" => ""
      })
      |> call()

    assert tag_update.status == 200
    assert tag_update.resp_body =~ "<TagOpenIDConnectProviderResponse"
    assert {:ok, provider} = IAM.get_oidc_provider(provider_arn)
    assert provider.tags == %{"env" => "prod", "stage" => "", "team" => "core"}

    untag =
      signed_iam_conn(%{
        "Action" => "UntagOpenIDConnectProvider",
        "OpenIDConnectProviderArn" => provider_arn,
        "TagKeys.member.1" => "team"
      })
      |> call()

    assert untag.status == 200
    assert untag.resp_body =~ "<UntagOpenIDConnectProviderResponse"
    assert {:ok, provider} = IAM.get_oidc_provider(provider_arn)
    assert provider.tags == %{"env" => "prod", "stage" => ""}

    add_client =
      signed_iam_conn(%{
        "Action" => "AddClientIDToOpenIDConnectProvider",
        "OpenIDConnectProviderArn" => provider_arn,
        "ClientID" => "backup.maxio.test"
      })
      |> call()

    assert add_client.status == 200
    assert add_client.resp_body =~ "<AddClientIDToOpenIDConnectProviderResponse"
    assert {:ok, provider} = IAM.get_oidc_provider(provider_arn)
    assert "backup.maxio.test" in provider.client_ids

    replacement_thumbprint = sha1_hex("replacement-ca")

    update_thumbprint =
      signed_iam_conn(%{
        "Action" => "UpdateOpenIDConnectProviderThumbprint",
        "OpenIDConnectProviderArn" => provider_arn,
        "ThumbprintList.member.1" => replacement_thumbprint
      })
      |> call()

    assert update_thumbprint.status == 200
    assert {:ok, provider} = IAM.get_oidc_provider(provider_arn)
    assert provider.thumbprints == [replacement_thumbprint]

    remove_client =
      signed_iam_conn(%{
        "Action" => "RemoveClientIDFromOpenIDConnectProvider",
        "OpenIDConnectProviderArn" => provider_arn,
        "ClientID" => "backup.maxio.test"
      })
      |> call()

    assert remove_client.status == 200
    assert {:ok, provider} = IAM.get_oidc_provider(provider_arn)
    refute "backup.maxio.test" in provider.client_ids

    delete =
      signed_iam_conn(%{
        "Action" => "DeleteOpenIDConnectProvider",
        "OpenIDConnectProviderArn" => provider_arn
      })
      |> call()

    assert delete.status == 200
    assert delete.resp_body =~ "<DeleteOpenIDConnectProviderResponse"

    missing =
      signed_iam_conn(%{
        "Action" => "GetOpenIDConnectProvider",
        "OpenIDConnectProviderArn" => provider_arn
      })
      |> call()

    assert missing.status == 404
    assert missing.resp_body =~ "<Code>NoSuchEntity</Code>"
  end

  test "OpenID Connect provider management requires root principal" do
    assert {:ok, user} = IAM.create_user(user_name: unique_name("oidc-denied"))

    assert {:ok, key} =
             IAM.create_access_key(user_name: user.user_name, secret_key: "alice-secret")

    response =
      signed_iam_conn(%{"Action" => "ListOpenIDConnectProviders"},
        access_key: key.access_key_id,
        secret: "alice-secret"
      )
      |> call()

    assert response.status == 403
    assert response.resp_body =~ "<Code>AccessDenied</Code>"
    assert response.resp_body =~ "Only the root principal"
  end

  test "OpenID Connect provider list parameters must be contiguous" do
    response =
      signed_iam_conn(%{
        "Action" => "CreateOpenIDConnectProvider",
        "Url" => unique_issuer("gap"),
        "ClientIDList.member.2" => "sts.amazonaws.com",
        "ThumbprintList.member.1" => sha1_hex("root-ca")
      })
      |> call()

    assert response.status == 400
    assert response.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert response.resp_body =~ "indexed contiguously"
  end

  test "OpenID Connect provider tag parameters fail closed" do
    tag_gap =
      signed_iam_conn(%{
        "Action" => "CreateOpenIDConnectProvider",
        "Url" => unique_issuer("tag-gap"),
        "ClientIDList.member.1" => "sts.amazonaws.com",
        "Tags.member.2.Key" => "team",
        "Tags.member.2.Value" => "core"
      })
      |> call()

    assert tag_gap.status == 400
    assert tag_gap.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert tag_gap.resp_body =~ "indexed contiguously"

    reserved_key =
      signed_iam_conn(%{
        "Action" => "TagOpenIDConnectProvider",
        "OpenIDConnectProviderArn" => "arn:aws:iam:::oidc-provider/example.com",
        "Tags.member.1.Key" => "aws:team",
        "Tags.member.1.Value" => "core"
      })
      |> call()

    assert reserved_key.status == 400
    assert reserved_key.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert reserved_key.resp_body =~ "valid tag keys and values"

    duplicate_untag =
      signed_iam_conn(%{
        "Action" => "UntagOpenIDConnectProvider",
        "OpenIDConnectProviderArn" => "arn:aws:iam:::oidc-provider/example.com",
        "TagKeys.member.1" => "team",
        "TagKeys.member.2" => "team"
      })
      |> call()

    assert duplicate_untag.status == 400
    assert duplicate_untag.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert duplicate_untag.resp_body =~ "duplicate tag keys"

    invalid_pagination =
      signed_iam_conn(%{
        "Action" => "ListOpenIDConnectProviderTags",
        "OpenIDConnectProviderArn" => "arn:aws:iam:::oidc-provider/example.com",
        "MaxItems" => "0"
      })
      |> call()

    assert invalid_pagination.status == 400
    assert invalid_pagination.resp_body =~ "<Code>InvalidParameterValue</Code>"
    assert invalid_pagination.resp_body =~ "MaxItems"
  end

  test "OpenID Connect provider communication failures use AWS Query error code" do
    issuer = unique_issuer("query-comm-fail")
    put_oidc_discovery_error(issuer, :oidc_discovery_http_error)

    response =
      signed_iam_conn(%{
        "Action" => "CreateOpenIDConnectProvider",
        "Url" => issuer,
        "ClientIDList.member.1" => "sts.amazonaws.com"
      })
      |> call()

    assert response.status == 400
    assert response.resp_body =~ "<Code>OpenIdIdpCommunicationError</Code>"
  end

  defp active_user_mfa(user_name) do
    create =
      signed_iam_conn(%{
        "Action" => "CreateVirtualMFADevice",
        "VirtualMFADeviceName" => unique_name("#{user_name}-mfa")
      })
      |> call()

    assert create.status == 200
    serial = xml_value(create.resp_body, "SerialNumber")
    seed = xml_value(create.resp_body, "Base32StringSeed")
    enable_time = DateTime.utc_now()
    {code1, code2} = consecutive_codes(seed, enable_time)

    enable =
      signed_iam_conn(%{
        "Action" => "EnableMFADevice",
        "UserName" => user_name,
        "SerialNumber" => serial,
        "AuthenticationCode1" => code1,
        "AuthenticationCode2" => code2
      })
      |> put_private(:maxio_now, enable_time)
      |> call()

    assert enable.status == 200
    {serial, seed}
  end

  defp signed_raw_iam_conn(raw_query) do
    now = DateTime.utc_now()
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    scope_date = Calendar.strftime(now, "%Y%m%d")
    scope = "#{scope_date}/#{@sigv4_region}/iam/aws4_request"
    payload_hash = Signer.hex_sha256("")

    base_headers = [
      {"host", @sigv4_host},
      {"x-amz-content-sha256", payload_hash},
      {"x-amz-date", amz_date}
    ]

    canonical_req = %{
      method: "GET",
      path: "/",
      query: raw_query,
      headers: base_headers,
      payload_hash: payload_hash
    }

    canonical = Canonical.canonical_request(canonical_req)
    sts = Signer.string_to_sign(amz_date, scope, canonical, "AWS4-HMAC-SHA256")
    key = Signer.derive_signing_key(@sigv4_secret, scope_date, @sigv4_region, "iam")
    signature = Signer.signature(key, sts)
    signed_headers = Canonical.signed_headers(base_headers)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{SigV4Request.access_key()}/#{scope}," <>
        "SignedHeaders=#{signed_headers},Signature=#{signature}"

    Plug.Test.conn(:get, "/?" <> raw_query, "")
    |> Map.put(:host, @sigv4_host)
    |> put_private(:maxio_now, now)
    |> put_req_header("x-amz-content-sha256", payload_hash)
    |> put_req_header("x-amz-date", amz_date)
    |> put_req_header("authorization", auth)
  end

  defp raw_iam_query(params) when is_list(params) do
    params
    |> Enum.map(fn {key, value} ->
      Canonical.uri_encode(to_string(key), :query) <>
        "=" <> Canonical.uri_encode(to_string(value), :query)
    end)
    |> Enum.join("&")
  end

  defp signed_iam_conn(extra_query, opts \\ []) do
    sign_opts =
      opts
      |> Keyword.put(:query, base_query(extra_query))
      |> Keyword.put(:service, "iam")

    SigV4Request.signed_conn(:get, "/", sign_opts)
  end

  defp signed_iam_form_conn(extra_form, opts \\ []) do
    signed_iam_form_body(form_body(extra_form), opts)
  end

  defp signed_iam_form_body(body, opts \\ []) do
    sign_opts =
      opts
      |> Keyword.put(:body, body)
      |> Keyword.put(:headers, [
        {"content-type", "application/x-www-form-urlencoded; charset=utf-8"}
      ])
      |> Keyword.put(:service, "iam")

    SigV4Request.signed_conn(:post, "/", sign_opts)
  end

  defp base_query(extra) do
    Map.merge(%{"Action" => "ListMFADevices", "Version" => "2010-05-08"}, extra)
  end

  defp form_body(extra), do: base_query(extra) |> URI.encode_query()

  defp indexed_tag_params(prefix, tag_pairs) do
    tag_pairs
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {{key, value}, index} ->
      [
        {"#{prefix}.member.#{index}.Key", key},
        {"#{prefix}.member.#{index}.Value", value}
      ]
    end)
    |> Map.new()
  end

  defp server_certificate_pems do
    Application.ensure_all_started(:public_key)

    chain =
      :public_key.pkix_test_data(
        Map.new([
          {:root, [key: {:rsa, 1024, 65_537}]},
          {:peer, [key: {:rsa, 1024, 65_537}]}
        ])
      )

    cert_pem =
      :public_key.pem_encode([{:Certificate, Keyword.fetch!(chain, :cert), :not_encrypted}])

    {key_type, key_der} = Keyword.fetch!(chain, :key)
    key_pem = :public_key.pem_encode([{key_type, key_der, :not_encrypted}])

    chain_pem =
      chain
      |> Keyword.fetch!(:cacerts)
      |> Enum.map(fn cert -> {:Certificate, cert, :not_encrypted} end)
      |> :public_key.pem_encode()

    {cert_pem, key_pem, chain_pem}
  end

  defp ssh_public_key_body(seed, comment) do
    n = ssh_public_key_modulus(seed)
    e = 65_537
    blob = ssh_string("ssh-rsa") <> ssh_mpint(e) <> ssh_mpint(n)

    ["ssh-rsa", Base.encode64(blob), comment]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp ssh_public_key_body_from_mpints(e_mpint, n_mpint, comment) do
    blob = ssh_string("ssh-rsa") <> e_mpint <> n_mpint
    "ssh-rsa #{Base.encode64(blob)} #{comment}"
  end

  defp rsa_public_key_pem_body(seed) do
    der =
      der_sequence(
        rsa_encryption_algorithm_identifier() <>
          der_bit_string(rsa_public_key_der(ssh_public_key_modulus(seed), 65_537))
      )

    pem_body("PUBLIC KEY", der)
  end

  defp ssh_public_key_modulus(seed) do
    :binary.decode_unsigned(<<0x80, 0::size(2040)>>) + seed
  end

  defp ssh_string(value), do: <<byte_size(value)::32, value::binary>>

  defp ssh_mpint(value) when is_integer(value) and value > 0 do
    encoded = :binary.encode_unsigned(value)

    if :binary.first(encoded) >= 128,
      do: ssh_string(<<0, encoded::binary>>),
      else: ssh_string(encoded)
  end

  defp rsa_public_key_der(n, e), do: der_sequence(der_integer(n) <> der_integer(e))

  defp rsa_encryption_algorithm_identifier do
    der_sequence(
      <<0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01>> <>
        <<0x05, 0x00>>
    )
  end

  defp der_bit_string(content) do
    value = <<0, content::binary>>
    <<0x03, der_length(value)::binary, value::binary>>
  end

  defp der_sequence(content), do: <<0x30, der_length(content)::binary, content::binary>>

  defp der_integer(value) when is_integer(value) and value > 0 do
    encoded = :binary.encode_unsigned(value)
    encoded = if :binary.first(encoded) >= 128, do: <<0, encoded::binary>>, else: encoded
    <<0x02, der_length(encoded)::binary, encoded::binary>>
  end

  defp der_length(content), do: der_length_bytes(byte_size(content))

  defp der_length_bytes(length) when length < 128, do: <<length>>

  defp der_length_bytes(length) do
    encoded = :binary.encode_unsigned(length)
    <<0x80 + byte_size(encoded), encoded::binary>>
  end

  defp pem_body(label, der) do
    encoded =
      der
      |> Base.encode64()
      |> String.graphemes()
      |> Enum.chunk_every(64)
      |> Enum.map_join("\n", &Enum.join/1)

    "-----BEGIN #{label}-----\n" <> encoded <> "\n-----END #{label}-----"
  end

  defp root_trust_policy do
    %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Principal" => %{"AWS" => IAM.root_principal_arn()},
        "Action" => "sts:AssumeRole"
      }
    }
  end

  defp trust_policy_for_principal(principal_arn) do
    %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Principal" => %{"AWS" => principal_arn},
        "Action" => "sts:AssumeRole"
      }
    }
  end

  defp consecutive_codes(seed, time) do
    assert {:ok, code1} = TOTP.code(seed, time: time)
    assert {:ok, code2} = TOTP.code(seed, time: DateTime.add(time, 30, :second))
    {code1, code2}
  end

  defp put_oidc_discovery_fixture(issuer, jwks, opts) do
    fixture = %{
      discovery_document: %{
        "issuer" => issuer,
        "jwks_uri" => issuer <> "/keys"
      },
      jwks: jwks,
      jwks_fetched_at: DateTime.utc_now(),
      thumbprints: Keyword.get(opts, :thumbprints, [])
    }

    fixtures = Application.get_env(:maxio, :oidc_discovery_fixtures, %{})
    Application.put_env(:maxio, :oidc_discovery_fixtures, Map.put(fixtures, issuer, fixture))
  end

  defp put_oidc_discovery_error(issuer, reason) do
    fixtures = Application.get_env(:maxio, :oidc_discovery_fixtures, %{})

    Application.put_env(
      :maxio,
      :oidc_discovery_fixtures,
      Map.put(fixtures, issuer, {:error, reason})
    )
  end

  defp public_jwks(jwk) do
    {_metadata, public_jwk} = JOSE.JWK.to_public_map(jwk)
    %{"keys" => [Map.put(public_jwk, "kid", "maxio-test")]}
  end

  defp sha1_hex(value), do: :crypto.hash(:sha, value) |> Base.encode16(case: :lower)

  defp xml_value(xml, tag) do
    regex = ~r/<#{tag}>([^<]+)<\/#{tag}>/
    [_, value] = Regex.run(regex, xml)
    value
  end

  defp xml_values(xml, tag) do
    ~r/<#{tag}>([^<]+)<\/#{tag}>/
    |> Regex.scan(xml)
    |> Enum.map(fn [_full, value] -> value end)
  end

  defp xml_tag_pairs(xml) do
    ~r/<member><Key>([^<]+)<\/Key>(?:<Value>([^<]*)<\/Value>|<Value\/>)<\/member>/
    |> Regex.scan(xml)
    |> Enum.map(fn
      [_full, key, value] -> {key, value}
      [_full, key] -> {key, ""}
    end)
  end

  defp xml_summary_map(xml) do
    ~r/<entry><key>([^<]+)<\/key><value>(\d+)<\/value><\/entry>/
    |> Regex.scan(xml)
    |> Map.new(fn [_full, key, value] -> {key, String.to_integer(value)} end)
  end

  defp decoded_policy_document(xml) do
    xml
    |> xml_value("PolicyDocument")
    |> URI.decode()
    |> Jason.decode!()
  end

  defp identity_policy(action, resource \\ "arn:aws:s3:::inline-default/*") do
    %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Action" => action,
        "Resource" => resource
      }
    }
    |> Jason.encode!()
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp unique_issuer(prefix) do
    "https://#{prefix}-#{System.unique_integer([:positive])}.oidc.example.test/tenant"
  end
end
