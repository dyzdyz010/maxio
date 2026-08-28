defmodule Maxio.IAM do
  @moduledoc """
  访问密钥生命周期 context（铁律 4：CLI 可观测）。root 从 config 引导（boot 幂等 upsert）；
  create/list/delete access key。底层走 EctoStore（持久化）。principal map 形态与 MemoryStore 对齐：
    root     → %{type: :root, access_key: ak, arn: "arn:aws:iam:::root"}
    iam_user → %{type: :iam_user, access_key: ak, arn: "arn:aws:iam:::user/<ak>"}
  """
  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.Cluster.Notify

  alias Maxio.IAM.{
    AccountAlias,
    AccountPasswordPolicy,
    AccessKey,
    AccessKeySecret,
    CredentialNamespace,
    Group,
    GroupManagedPolicyAttachment,
    GroupMembership,
    InstanceProfile,
    MFADevice,
    MFASecret,
    MinioAccessKey,
    OIDCProvider,
    OIDCProviderRefresh,
    Role,
    RoleManagedPolicyAttachment,
    ServerCertificate,
    SSHPublicKey,
    SigningCertificate,
    STSSession,
    SigningSecretRotation,
    SigningSecretRewriter,
    TOTP,
    User,
    UserIdentity,
    UserManagedPolicyAttachment
  }

  alias Maxio.Policy.{ManagedPolicyVersion, PrincipalPolicy}
  alias Maxio.Policy.{Statement, Store}
  alias Maxio.Tags

  @root_principal_arn "arn:aws:iam:::root"
  @default_mfa_device_name "root-account-mfa-device"
  @managed_policy_name_pattern ~r/\A[A-Za-z0-9+=,.@_-]+\z/
  @managed_policy_path_segment_pattern ~r/\A[A-Za-z0-9.,+@=_-]+\z/
  @local_user_arn_pattern ~r/\Aarn:aws:iam:::user\/[A-Za-z0-9+=,.@_-]+\z/
  @inline_policy_document_max_chars 131_072
  @managed_policy_document_max_chars 131_072
  @managed_policy_document_quota_chars 6_144
  @managed_policy_account_quota 1_500
  @managed_policy_default_version_id "v1"
  @managed_policy_version_id_pattern ~r/\Av[1-9]\d*(?:\.[A-Za-z0-9-]*)?\z/
  @user_inline_policy_quota_chars 2_048
  @group_inline_policy_quota_chars 5_120
  @role_inline_policy_quota_chars 10_240
  @user_managed_policy_attachment_quota 10
  @group_managed_policy_attachment_quota 10
  @role_managed_policy_attachment_quota 10
  @access_key_quota_per_principal 2
  @signing_certificates_quota_per_principal 2
  @ssh_public_keys_quota_per_user 5
  @users_quota 5_000
  @groups_quota 300
  @roles_quota 1_000
  @instance_profiles_quota 1_000
  @server_certificates_quota 20
  @groups_per_user_quota 10
  @versions_per_policy_quota 5
  @policy_versions_in_use_quota @managed_policy_account_quota * @versions_per_policy_quota
  @assume_role_policy_size_quota_chars 2_048
  @global_endpoint_token_version 2
  @policy_entity_filters ~w(All User Role Group LocalManagedPolicy AWSManagedPolicy)
  @policy_usage_filters ~w(PermissionsPolicy PermissionsBoundary)

  @doc "从 config :maxio, :s3 的 root_user/root_password 幂等引导 root（boot 调用）。"
  @spec bootstrap_root() :: :ok
  def bootstrap_root do
    s3 = Application.fetch_env!(:maxio, :s3)
    ak = Keyword.fetch!(s3, :root_user)
    sk = Keyword.fetch!(s3, :root_password)

    stored_secret =
      case AccessKeySecret.wrap(sk, ak) do
        {:ok, stored_secret} ->
          stored_secret

        {:error, reason} ->
          raise ArgumentError, "invalid root access-key secret configuration: #{inspect(reason)}"
      end

    %AccessKey{}
    |> AccessKey.changeset(%{
      access_key_id: ak,
      secret_key: stored_secret,
      principal_arn: @root_principal_arn,
      type: "root",
      status: "active",
      tags: %{}
    })
    |> Repo.insert(
      on_conflict: {:replace, [:secret_key, :principal_arn, :type, :status, :tags, :updated_at]},
      conflict_target: :access_key_id
    )

    :ok
  end

  @doc """
  Returns AWS IAM Query `GetAccountSummary` usage and quota metadata.

  Unsupported IAM entity families return zero usage and zero quota so callers
  can distinguish them from implemented local IAM surfaces.
  """
  @spec account_summary() :: %{String.t() => non_neg_integer()}
  def account_summary do
    policies = length(Store.list_managed_session_policies())
    policy_versions = max(Repo.aggregate(ManagedPolicyVersion, :count, :id), policies)

    %{
      "AccessKeysPerUserQuota" => @access_key_quota_per_principal,
      "AccountAccessKeysPresent" => flag(root_access_keys_present?()),
      "AccountMFAEnabled" => flag(root_mfa_enabled?()),
      "AccountPasswordPresent" => flag(root_password_configured?()),
      "AccountSigningCertificatesPresent" => flag(root_signing_certificates_present?()),
      "AssumeRolePolicySizeQuota" => @assume_role_policy_size_quota_chars,
      "AttachedPoliciesPerGroupQuota" => @group_managed_policy_attachment_quota,
      "AttachedPoliciesPerRoleQuota" => @role_managed_policy_attachment_quota,
      "AttachedPoliciesPerUserQuota" => @user_managed_policy_attachment_quota,
      "GlobalEndpointTokenVersion" => @global_endpoint_token_version,
      "GroupPolicySizeQuota" => @group_inline_policy_quota_chars,
      "Groups" => Repo.aggregate(Group, :count, :id),
      "GroupsPerUserQuota" => @groups_per_user_quota,
      "GroupsQuota" => @groups_quota,
      "InstanceProfiles" => Repo.aggregate(InstanceProfile, :count, :id),
      "InstanceProfilesQuota" => @instance_profiles_quota,
      "MFADevices" => Repo.aggregate(MFADevice, :count, :id),
      "MFADevicesInUse" =>
        Repo.aggregate(from(m in MFADevice, where: m.status == "active"), :count, :id),
      "Policies" => policies,
      "PoliciesQuota" => @managed_policy_account_quota,
      "PolicySizeQuota" => @managed_policy_document_quota_chars,
      "PolicyVersionsInUse" => policy_versions,
      "PolicyVersionsInUseQuota" => @policy_versions_in_use_quota,
      "Providers" => Repo.aggregate(OIDCProvider, :count, :id),
      "RolePolicySizeQuota" => @role_inline_policy_quota_chars,
      "Roles" => Repo.aggregate(Role, :count, :id),
      "RolesQuota" => @roles_quota,
      "ServerCertificates" => Repo.aggregate(ServerCertificate, :count, :id),
      "ServerCertificatesQuota" => @server_certificates_quota,
      "SigningCertificatesPerUserQuota" => @signing_certificates_quota_per_principal,
      "UserPolicySizeQuota" => @user_inline_policy_quota_chars,
      "Users" => Repo.aggregate(User, :count, :id),
      "UsersQuota" => @users_quota,
      "VersionsPerPolicyQuota" => @versions_per_policy_quota
    }
  end

  @doc "Creates the single local IAM account alias."
  @spec create_account_alias(String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_account_alias(account_alias) when is_binary(account_alias) do
    cond do
      not account_alias_valid?(account_alias) ->
        {:error, :malformed}

      Repo.exists?(from(a in AccountAlias, where: a.account_alias == ^account_alias)) ->
        {:error, :already_exists}

      Repo.exists?(AccountAlias) ->
        {:error, :limit_exceeded}

      true ->
        %AccountAlias{}
        |> AccountAlias.changeset(%{account_alias: account_alias})
        |> Repo.insert()
        |> case do
          {:ok, row} ->
            Notify.broadcast({:iam_changed, :account_alias})
            {:ok, row.account_alias}

          {:error, changeset} ->
            {:error, account_alias_insert_error(changeset)}
        end
    end
  end

  def create_account_alias(_account_alias), do: {:error, :malformed}

  @doc "Lists the local IAM account aliases. AWS permits at most one alias."
  @spec list_account_aliases() :: [String.t()]
  def list_account_aliases do
    AccountAlias
    |> order_by([a], asc: a.account_alias)
    |> Repo.all()
    |> Enum.map(& &1.account_alias)
  end

  @doc "Deletes the named local IAM account alias."
  @spec delete_account_alias(String.t()) :: :ok | {:error, term()}
  def delete_account_alias(account_alias) when is_binary(account_alias) do
    if account_alias_valid?(account_alias) do
      case Repo.get_by(AccountAlias, account_alias: account_alias) do
        %AccountAlias{} = row ->
          Repo.delete!(row)
          Notify.broadcast({:iam_changed, :account_alias})
          :ok

        nil ->
          {:error, :not_found}
      end
    else
      {:error, :malformed}
    end
  end

  def delete_account_alias(_account_alias), do: {:error, :malformed}

  defp account_alias_valid?(account_alias) when is_binary(account_alias) do
    %AccountAlias{}
    |> AccountAlias.changeset(%{account_alias: account_alias})
    |> Map.get(:valid?)
  end

  defp account_alias_insert_error(%Ecto.Changeset{} = changeset) do
    cond do
      changeset_has_unique_error?(changeset, :account_alias) -> :already_exists
      changeset_has_unique_error?(changeset, :singleton_key) -> :limit_exceeded
      true -> :malformed
    end
  end

  defp changeset_has_unique_error?(%Ecto.Changeset{} = changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _other -> false
    end)
  end

  @doc "Fetches the local IAM account password policy."
  @spec get_account_password_policy() :: {:ok, map()} | {:error, :not_found}
  def get_account_password_policy do
    case Repo.get_by(AccountPasswordPolicy, singleton_key: 1) do
      %AccountPasswordPolicy{} = row -> {:ok, account_password_policy_map(row)}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Replaces the local IAM account password policy.

  AWS `UpdateAccountPasswordPolicy` is not partial: omitted fields return to
  their documented defaults.
  """
  @spec update_account_password_policy(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def update_account_password_policy(attrs) when is_map(attrs) or is_list(attrs) do
    attrs =
      AccountPasswordPolicy.defaults()
      |> Map.merge(Map.new(attrs))
      |> Map.put(:singleton_key, 1)

    replace_fields = [
      :minimum_password_length,
      :require_symbols,
      :require_numbers,
      :require_uppercase_characters,
      :require_lowercase_characters,
      :allow_users_to_change_password,
      :hard_expiry,
      :max_password_age,
      :password_reuse_prevention,
      :updated_at
    ]

    %AccountPasswordPolicy{}
    |> AccountPasswordPolicy.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, replace_fields},
      conflict_target: :singleton_key,
      returning: true
    )
    |> case do
      {:ok, row} ->
        Notify.broadcast({:iam_changed, :account_password_policy})
        {:ok, account_password_policy_map(row)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Deletes the local IAM account password policy."
  @spec delete_account_password_policy() :: :ok | {:error, :not_found}
  def delete_account_password_policy do
    case Repo.get_by(AccountPasswordPolicy, singleton_key: 1) do
      %AccountPasswordPolicy{} = row ->
        Repo.delete!(row)
        Notify.broadcast({:iam_changed, :account_password_policy})
        :ok

      nil ->
        {:error, :not_found}
    end
  end

  defp account_password_policy_map(%AccountPasswordPolicy{} = row) do
    %{
      minimum_password_length: row.minimum_password_length,
      require_symbols: row.require_symbols,
      require_numbers: row.require_numbers,
      require_uppercase_characters: row.require_uppercase_characters,
      require_lowercase_characters: row.require_lowercase_characters,
      allow_users_to_change_password: row.allow_users_to_change_password,
      hard_expiry: row.hard_expiry,
      max_password_age: row.max_password_age,
      password_reuse_prevention: row.password_reuse_prevention,
      expire_passwords: is_integer(row.max_password_age) and row.max_password_age > 0
    }
  end

  defp root_access_keys_present? do
    Repo.exists?(
      from(a in AccessKey, where: a.type == "root" and a.principal_arn == @root_principal_arn)
    )
  end

  defp root_signing_certificates_present? do
    Repo.exists?(
      from(c in SigningCertificate, where: c.principal_type == "root" and is_nil(c.user_arn))
    )
  end

  defp root_mfa_enabled? do
    Repo.exists?(
      from(m in MFADevice,
        where: m.principal_arn == @root_principal_arn and m.status == "active"
      )
    )
  end

  defp root_password_configured? do
    case Application.get_env(:maxio, :s3, []) |> Keyword.get(:root_password) do
      value when is_binary(value) -> value != ""
      _other -> false
    end
  end

  defp flag(true), do: 1
  defp flag(false), do: 0

  @doc """
  Creates an access key for the local root or an IAM user.

  Options: `:access_key_id`, `:secret_key`, `:type`, `:user_name`,
  `:principal_arn`, `:status`, and `:tags`.
  """
  @spec create_access_key(keyword()) :: {:ok, map()} | {:error, term()}
  def create_access_key(opts \\ []) do
    ak = Keyword.get(opts, :access_key_id) || gen_access_key_id()
    sk = Keyword.get(opts, :secret_key) || gen_secret_key()
    type = opts |> Keyword.get(:type, "iam_user") |> normalize_iam_text()
    tags = opts |> Keyword.get(:tags, %{}) |> normalize_tags()
    status = opts |> Keyword.get(:status, "active") |> normalize_iam_text()

    with {:ok, arn} <- access_key_principal_arn(type, ak, opts),
         {:ok, stored_secret} <- AccessKeySecret.wrap(sk, ak) do
      identity = credential_identity_snapshot(arn)

      Repo.transaction(fn ->
        with :ok <- lock_credential_identity(identity, allow_missing: true),
             :ok <- CredentialNamespace.reserve_exact(Repo, ak),
             {:ok, row} <-
               %AccessKey{}
               |> AccessKey.changeset(%{
                 access_key_id: ak,
                 secret_key: stored_secret,
                 principal_arn: arn,
                 type: type,
                 status: status,
                 tags: tags
               })
               |> Repo.insert() do
          row
        else
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> case do
        {:ok, row} ->
          Notify.broadcast({:iam_changed, row.access_key_id})

          {:ok,
           %{
             access_key_id: row.access_key_id,
             secret_key: sk,
             principal_arn: arn,
             type: type,
             status: status,
             tags: tags
           }}

        {:error, {:error, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "列出全部 access key（不回 secret）。"
  @spec list_access_keys() :: [map()]
  def list_access_keys do
    Repo.all(from a in AccessKey, order_by: [asc: a.inserted_at])
    |> Enum.map(&public_access_key/1)
  end

  @doc """
  Fetches an active long-term access-key principal for Console/IAM workflows.

  This mirrors the SigV4 credential-store fail-closed checks for local root and
  IAM-user principals, including inactive explicit IAM users, but intentionally
  does not return secret material.
  """
  @spec get_active_access_key_principal(String.t()) :: {:ok, map()} | :error
  def get_active_access_key_principal(access_key_id) when is_binary(access_key_id) do
    case Repo.get_by(AccessKey, access_key_id: access_key_id, status: "active") do
      %AccessKey{} = access_key -> public_active_access_key_principal(access_key)
      nil -> :error
    end
  end

  def get_active_access_key_principal(_access_key_id), do: :error

  @doc """
  Rewrites selected IAM signing-secret rows to the current envelope key.

  Runs in dry-run mode by default. Pass `dry_run: false` only after reviewing
  the report with every historical key still present in the configured key ring.
  """
  @spec rewrap_signing_secrets(keyword()) :: {:ok, map()} | {:error, map()}
  def rewrap_signing_secrets(opts \\ []), do: SigningSecretRewriter.run(opts)

  @doc """
  Rotates the current IAM signing-secret envelope key through a writable keyring.

  Dry-run is the default. A confirmed rotation writes the local keyring file,
  updates this node's runtime keyring config, and rewraps existing IAM signing
  secrets unless `rewrap: false` is provided.
  """
  @spec rotate_signing_secret_key(keyword()) :: {:ok, map()} | {:error, map()}
  def rotate_signing_secret_key(opts \\ []), do: SigningSecretRotation.rotate(opts)

  @doc "Runs IAM signing-secret rotation only when the current key is older than the configured threshold."
  @spec rotate_signing_secret_key_if_due(keyword()) :: {:ok, map()} | {:error, map()}
  def rotate_signing_secret_key_if_due(opts \\ []), do: SigningSecretRotation.rotate_if_due(opts)

  @doc "删除 access key（幂等）。拒绝删除最后一个 root（避免锁死，铁律 3 不静默放行也不让系统不可用）。"
  @spec delete_access_key(String.t()) :: :ok | {:error, :cannot_delete_last_root}
  def delete_access_key(access_key_id) do
    initial = Repo.get_by(AccessKey, access_key_id: access_key_id)

    identity =
      if initial, do: credential_identity_snapshot(initial.principal_arn), else: :not_local_user

    Repo.transaction(fn ->
      with :ok <- lock_credential_identity(identity, require_active: false, allow_missing: true),
           :ok <- CredentialNamespace.lock_exact(Repo, access_key_id) do
        case Repo.get_by(AccessKey, access_key_id: access_key_id) do
          nil ->
            :ok

          %AccessKey{type: "root"} = row ->
            root_count =
              Repo.aggregate(from(a in AccessKey, where: a.type == "root"), :count, :id)

            if root_count <= 1 do
              Repo.rollback({:error, :cannot_delete_last_root})
            else
              Repo.delete!(row)
              :ok
            end

          %AccessKey{} = row ->
            Repo.delete!(row)
            :ok
        end
      else
        {:error, reason} -> Repo.rollback({:error, reason})
      end
    end)
    |> case do
      {:ok, :ok} ->
        Notify.broadcast({:iam_changed, access_key_id})
        :ok

      {:error, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates an access key using AWS IAM Query semantics.

  `nil` user name targets the local root principal. A non-nil user name must
  reference an active explicit IAM user. The returned map contains
  `:secret_key`; callers must render it once and never persist it outside the
  encrypted `access_keys.secret_key` envelope.
  """
  @spec create_access_key_strict(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def create_access_key_strict(user_name \\ nil) do
    with {:ok, scope} <- create_access_key_scope(user_name) do
      access_key_id = gen_access_key_id()
      secret_key = gen_secret_key()
      identity = credential_identity_snapshot(scope.principal_arn)

      with {:ok, stored_secret} <- AccessKeySecret.wrap(secret_key, access_key_id) do
        Repo.transaction(fn ->
          with :ok <- lock_credential_identity(identity, require_active: true),
               :ok <- lock_access_key_principal!(scope.principal_arn),
               :ok <- access_key_quota_available?(scope.principal_arn),
               :ok <- CredentialNamespace.reserve_exact(Repo, access_key_id),
               {:ok, row} <-
                 %AccessKey{}
                 |> AccessKey.changeset(%{
                   access_key_id: access_key_id,
                   secret_key: stored_secret,
                   principal_arn: scope.principal_arn,
                   type: scope.type,
                   status: "active",
                   tags: %{}
                 })
                 |> Repo.insert() do
            public_access_key(row, secret_key: secret_key)
          else
            {:error, reason} -> Repo.rollback({:error, reason})
          end
        end)
        |> case do
          {:ok, access_key} ->
            Notify.broadcast({:iam_changed, access_key.access_key_id})
            {:ok, access_key}

          {:error, {:error, reason}} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  @doc "Lists access keys for root (`nil`) or for a specific IAM user."
  @spec list_access_keys_strict(String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def list_access_keys_strict(user_name \\ nil) do
    with {:ok, scope} <- access_key_scope(user_name) do
      keys =
        Repo.all(
          from a in AccessKey,
            where: a.principal_arn == ^scope.principal_arn,
            order_by: [asc: a.inserted_at, asc: a.access_key_id]
        )
        |> Enum.map(&public_access_key/1)

      {:ok, keys}
    end
  end

  @doc "Updates an access key status using AWS IAM Query semantics."
  @spec update_access_key_strict(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def update_access_key_strict(access_key_id, status, user_name \\ nil)

  def update_access_key_strict(access_key_id, status, user_name)
      when is_binary(access_key_id) and is_binary(status) do
    with {:ok, scope} <- access_key_scope(user_name) do
      identity = credential_identity_snapshot(scope.principal_arn)

      Repo.transaction(fn ->
        with :ok <- lock_credential_identity(identity, require_active: false),
             :ok <- lock_access_key_principal!(scope.principal_arn),
             :ok <- CredentialNamespace.lock_exact(Repo, access_key_id),
             {:ok, row} <- scoped_access_key(access_key_id, scope),
             :ok <- ensure_root_status_update_safe(row, status) do
          case row |> AccessKey.changeset(%{status: status}) |> Repo.update() do
            {:ok, updated} ->
              public_access_key(updated)

            {:error, changeset} ->
              Repo.rollback({:error, changeset})
          end
        else
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> access_key_transaction_result()
      |> notify_access_key_result()
    end
  end

  def update_access_key_strict(_access_key_id, _status, _user_name), do: {:error, :malformed}

  @doc "Deletes an access key using AWS IAM Query semantics."
  @spec delete_access_key_strict(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def delete_access_key_strict(access_key_id, user_name \\ nil)

  def delete_access_key_strict(access_key_id, user_name) when is_binary(access_key_id) do
    with {:ok, scope} <- access_key_scope(user_name) do
      identity = credential_identity_snapshot(scope.principal_arn)

      Repo.transaction(fn ->
        with :ok <- lock_credential_identity(identity, require_active: false),
             :ok <- lock_access_key_principal!(scope.principal_arn),
             :ok <- CredentialNamespace.lock_exact(Repo, access_key_id),
             {:ok, row} <- scoped_access_key(access_key_id, scope),
             :ok <- ensure_root_delete_safe(row) do
          deleted = public_access_key(row)
          Repo.delete!(row)
          deleted
        else
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> access_key_transaction_result()
      |> notify_access_key_result()
    end
  end

  def delete_access_key_strict(_access_key_id, _user_name), do: {:error, :malformed}

  @doc """
  Uploads an IAM signing certificate for the local root or an IAM user.

  `nil` user name targets the local root principal. A non-nil user name must
  reference an active explicit IAM user.
  """
  @spec upload_signing_certificate(keyword()) :: {:ok, map()} | {:error, term()}
  def upload_signing_certificate(opts \\ []) do
    user_name = opts |> Keyword.get(:user_name) |> normalize_iam_text()
    certificate_body = Keyword.get(opts, :certificate_body)

    with {:ok, scope} <- signing_certificate_upload_scope(user_name) do
      Repo.transaction(fn ->
        lock_signing_certificate_principal!(scope.principal_key)

        with {:ok, changeset} <- signing_certificate_upload_changeset(scope, certificate_body),
             :ok <- reject_duplicate_signing_certificate(changeset),
             :ok <- signing_certificate_quota_available?(scope),
             {:ok, certificate} <- insert_signing_certificate(changeset) do
          public_signing_certificate(certificate)
        else
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> signing_certificate_transaction_result()
    end
  end

  @doc "Lists signing certificates for root (`nil`) or for a specific IAM user."
  @spec list_signing_certificates_strict(String.t() | nil) ::
          {:ok, [map()]} | {:error, term()}
  def list_signing_certificates_strict(user_name \\ nil) do
    with {:ok, scope} <- signing_certificate_scope(user_name) do
      certificates =
        scope
        |> signing_certificate_query()
        |> order_by([c], asc: c.inserted_at, asc: c.certificate_id)
        |> Repo.all()
        |> Enum.map(&public_signing_certificate/1)

      {:ok, certificates}
    end
  end

  @doc "Updates an IAM signing certificate status."
  @spec update_signing_certificate_strict(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def update_signing_certificate_strict(certificate_id, status, user_name \\ nil)

  def update_signing_certificate_strict(certificate_id, status, user_name)
      when is_binary(certificate_id) and is_binary(status) do
    with {:ok, scope} <- signing_certificate_scope(user_name) do
      Repo.transaction(fn ->
        lock_signing_certificate_principal!(scope.principal_key)

        with {:ok, row} <- scoped_signing_certificate(certificate_id, scope),
             {:ok, updated} <-
               row |> SigningCertificate.status_changeset(%{status: status}) |> Repo.update() do
          Notify.broadcast({:iam_changed, signing_certificate_principal_arn(updated)})
          public_signing_certificate(updated)
        else
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> signing_certificate_transaction_result()
    end
  end

  def update_signing_certificate_strict(_certificate_id, _status, _user_name),
    do: {:error, :malformed}

  @doc "Deletes an IAM signing certificate."
  @spec delete_signing_certificate_strict(String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def delete_signing_certificate_strict(certificate_id, user_name \\ nil)

  def delete_signing_certificate_strict(certificate_id, user_name)
      when is_binary(certificate_id) do
    with {:ok, scope} <- signing_certificate_scope(user_name) do
      Repo.transaction(fn ->
        lock_signing_certificate_principal!(scope.principal_key)

        with {:ok, row} <- scoped_signing_certificate(certificate_id, scope),
             {:ok, deleted} <- Repo.delete(row) do
          Notify.broadcast({:iam_changed, signing_certificate_principal_arn(deleted)})
          public_signing_certificate(deleted)
        else
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> signing_certificate_transaction_result()
    end
  end

  def delete_signing_certificate_strict(_certificate_id, _user_name), do: {:error, :malformed}

  @doc "Uploads an IAM SSH public key for an active explicit IAM user."
  @spec upload_ssh_public_key(keyword()) :: {:ok, map()} | {:error, term()}
  def upload_ssh_public_key(opts \\ []) do
    user_name = opts |> Keyword.get(:user_name) |> normalize_iam_text()
    ssh_public_key_body = Keyword.get(opts, :ssh_public_key_body)

    with {:ok, scope} <- ssh_public_key_upload_scope(user_name) do
      Repo.transaction(fn ->
        lock_ssh_public_key_user!(scope.user_arn)

        with {:ok, changeset} <- ssh_public_key_upload_changeset(scope, ssh_public_key_body),
             :ok <- reject_duplicate_ssh_public_key(changeset, scope),
             :ok <- ssh_public_key_quota_available?(scope),
             {:ok, ssh_public_key} <- insert_ssh_public_key(changeset) do
          public_ssh_public_key(ssh_public_key)
        else
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> ssh_public_key_transaction_result()
    end
  end

  @doc "Lists IAM SSH public keys for an explicit IAM user."
  @spec list_ssh_public_keys_strict(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_ssh_public_keys_strict(user_name) when is_binary(user_name) do
    with {:ok, scope} <- ssh_public_key_scope(user_name) do
      keys =
        scope
        |> ssh_public_key_query()
        |> order_by([k], asc: k.inserted_at, asc: k.ssh_public_key_id)
        |> Repo.all()
        |> Enum.map(&public_ssh_public_key/1)

      {:ok, keys}
    end
  end

  def list_ssh_public_keys_strict(_user_name), do: {:error, :malformed}

  @doc "Gets an IAM SSH public key for an explicit IAM user."
  @spec get_ssh_public_key_strict(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_ssh_public_key_strict(user_name, ssh_public_key_id)
      when is_binary(user_name) and is_binary(ssh_public_key_id) do
    with {:ok, scope} <- ssh_public_key_scope(user_name),
         {:ok, row} <- scoped_ssh_public_key(ssh_public_key_id, scope) do
      {:ok, public_ssh_public_key(row)}
    end
  end

  def get_ssh_public_key_strict(_user_name, _ssh_public_key_id), do: {:error, :malformed}

  @doc "Updates an IAM SSH public key status."
  @spec update_ssh_public_key_strict(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def update_ssh_public_key_strict(user_name, ssh_public_key_id, status)
      when is_binary(user_name) and is_binary(ssh_public_key_id) and is_binary(status) do
    with {:ok, scope} <- ssh_public_key_scope(user_name) do
      Repo.transaction(fn ->
        lock_ssh_public_key_user!(scope.user_arn)

        with {:ok, row} <- scoped_ssh_public_key(ssh_public_key_id, scope),
             {:ok, updated} <-
               row |> SSHPublicKey.status_changeset(%{status: status}) |> Repo.update() do
          Notify.broadcast({:iam_changed, scope.user_arn})
          public_ssh_public_key(updated)
        else
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> ssh_public_key_transaction_result()
    end
  end

  def update_ssh_public_key_strict(_user_name, _ssh_public_key_id, _status),
    do: {:error, :malformed}

  @doc "Deletes an IAM SSH public key."
  @spec delete_ssh_public_key_strict(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_ssh_public_key_strict(user_name, ssh_public_key_id)
      when is_binary(user_name) and is_binary(ssh_public_key_id) do
    with {:ok, scope} <- ssh_public_key_scope(user_name) do
      Repo.transaction(fn ->
        lock_ssh_public_key_user!(scope.user_arn)

        with {:ok, row} <- scoped_ssh_public_key(ssh_public_key_id, scope),
             {:ok, deleted} <- Repo.delete(row) do
          Notify.broadcast({:iam_changed, scope.user_arn})
          public_ssh_public_key(deleted)
        else
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> ssh_public_key_transaction_result()
    end
  end

  def delete_ssh_public_key_strict(_user_name, _ssh_public_key_id), do: {:error, :malformed}

  @doc """
  Returns AWS IAM Query `GetAccessKeyLastUsed` metadata for a long-term access key.

  The lookup intentionally includes inactive and expired rows: the API reports
  usage metadata for an access key id and must not imply current credential
  usability.
  """
  @spec get_access_key_last_used_strict(String.t()) :: {:ok, map()} | {:error, term()}
  def get_access_key_last_used_strict(access_key_id)
      when is_binary(access_key_id) and access_key_id != "" do
    case Repo.get_by(AccessKey, access_key_id: access_key_id) do
      %AccessKey{} = access_key -> {:ok, public_access_key_last_used(access_key)}
      nil -> {:error, :not_found}
    end
  end

  def get_access_key_last_used_strict(_access_key_id), do: {:error, :malformed}

  @doc """
  Records a successful SigV4 use of a long-term access key.

  Temporary STS session credentials are stored separately and deliberately do
  not update their issuer's long-term last-used metadata.
  """
  @spec record_access_key_last_used(String.t(), String.t(), String.t(), DateTime.t()) ::
          :ok | {:error, term()}
  def record_access_key_last_used(access_key_id, service, region, used_at \\ DateTime.utc_now())

  def record_access_key_last_used(access_key_id, service, region, %DateTime{} = used_at)
      when is_binary(access_key_id) and access_key_id != "" and is_binary(service) and
             service != "" and is_binary(region) and region != "" do
    {updated_count, _rows} =
      Repo.update_all(
        from(a in AccessKey, where: a.access_key_id == ^access_key_id),
        set: [
          last_used_at: used_at,
          last_used_service: service,
          last_used_region: region
        ]
      )

    if updated_count == 1, do: :ok, else: {:error, :not_found}
  end

  def record_access_key_last_used(_access_key_id, _service, _region, _used_at),
    do: {:error, :malformed}

  @doc "Returns the local single-account IAM user ARN for a user name."
  @spec user_arn(String.t()) :: String.t()
  def user_arn(user_name), do: "arn:aws:iam:::user/#{user_name}"

  @doc false
  @spec validate_minio_access_key(term()) :: :ok | {:error, :invalid_access_key}
  def validate_minio_access_key(access_key), do: MinioAccessKey.validate(access_key)

  @doc """
  Returns whether an IAM-user principal ARN may authenticate.

  Explicit IAM users must still exist and be active. Legacy access keys created
  before explicit users used their own access key id as the user ARN suffix; that
  self-ARN shape remains readable when no `iam_users` row exists.
  """
  @spec iam_user_principal_usable?(String.t(), String.t() | nil) :: boolean()
  def iam_user_principal_usable?(principal_arn, access_key_id \\ nil) do
    if local_user_arn?(principal_arn) do
      case Repo.get_by(User, user_arn: principal_arn) do
        %User{status: "active"} -> true
        %User{} -> false
        nil -> legacy_self_user_principal_arn?(principal_arn, access_key_id)
      end
    else
      false
    end
  end

  @doc "Returns the local single-account IAM group ARN for a group name."
  @spec group_arn(String.t()) :: String.t()
  def group_arn(group_name), do: "arn:aws:iam:::group/#{group_name}"

  @doc "Atomically creates a new MinIO admin user and its same-name long-term credential."
  @spec create_minio_user_strict(String.t(), String.t(), String.t()) ::
          {:ok, %{user: map(), access_key: map()}} | {:error, term()}
  def create_minio_user_strict(access_key_id, secret_key, "active")
      when is_binary(access_key_id) and access_key_id != "" and is_binary(secret_key) and
             secret_key != "" do
    user_arn = user_arn(access_key_id)
    identity_snapshot = UserIdentity.snapshot(Repo, access_key_id)

    with {:ok, stored_secret} <- AccessKeySecret.wrap(secret_key, access_key_id) do
      user_changeset =
        User.minio_admin_changeset(%User{}, %{
          user_name: access_key_id,
          user_arn: user_arn,
          status: "active",
          tags: %{}
        })

      access_key_changeset =
        AccessKey.minio_admin_changeset(%AccessKey{}, %{
          access_key_id: access_key_id,
          secret_key: stored_secret,
          principal_arn: user_arn,
          type: "iam_user",
          status: "active",
          tags: %{}
        })

      Ecto.Multi.new()
      |> Ecto.Multi.run(:locks, fn repo, _changes ->
        with {:ok, :missing} <-
               UserIdentity.lock_snapshot(repo, access_key_id, identity_snapshot),
             :ok <- CredentialNamespace.reserve_exact(repo, access_key_id) do
          {:ok, :locked}
        else
          {:ok, %User{}} -> {:error, :user_already_exists}
          {:error, :access_key_id_conflict} -> {:error, :user_already_exists}
          {:error, _identity_reason} -> {:error, :user_already_exists}
        end
      end)
      |> Ecto.Multi.insert(:user, user_changeset)
      |> Ecto.Multi.insert(:access_key, access_key_changeset)
      |> Repo.transaction()
      |> minio_user_transaction_result(access_key_id)
    end
  end

  def create_minio_user_strict(_access_key_id, _secret_key, _status),
    do: {:error, :invalid_argument}

  @doc "Creates an explicit IAM user. Access keys may later bind to this user ARN."
  @spec create_user(keyword()) :: {:ok, map()} | {:error, term()}
  def create_user(opts \\ []) do
    user_name = opts |> Keyword.get(:user_name, Keyword.get(opts, :name)) |> normalize_iam_text()
    user_arn = opts |> Keyword.get(:user_arn, default_user_arn(user_name)) |> normalize_iam_text()

    attrs = %{
      user_name: user_name,
      user_arn: user_arn,
      status: opts |> Keyword.get(:status, "active") |> normalize_iam_text(),
      tags: opts |> Keyword.get(:tags, %{}) |> normalize_tags(),
      permissions_boundary_policy_arn: permissions_boundary_policy_arn_from_opts(opts)
    }

    identity_snapshot = UserIdentity.snapshot(Repo, user_name)

    with :ok <- ensure_permissions_boundary_policy(attrs.permissions_boundary_policy_arn) do
      Repo.transaction(fn ->
        with {:ok, :missing} <- UserIdentity.lock_snapshot(Repo, user_name, identity_snapshot),
             {:ok, user} <- %User{} |> User.changeset(attrs) |> Repo.insert() do
          legacy_ids =
            access_keys_for_principal(user.user_arn) ++
              session_access_keys_for_principal(user.user_arn)

          {user, legacy_ids}
        else
          {:ok, %User{}} -> Repo.rollback({:error, :user_already_exists})
          {:error, :identity_changed} -> Repo.rollback({:error, :user_already_exists})
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> case do
        {:ok, {%User{} = user, legacy_ids}} ->
          Enum.each(Enum.uniq(legacy_ids), &Notify.broadcast({:iam_changed, &1}))
          Notify.broadcast({:principal_policy_changed, user.user_arn})
          {:ok, public_user(user)}

        {:error, {:error, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Fetches an IAM user by user name or ARN."
  @spec get_user(String.t()) :: {:ok, map()} | :error
  def get_user(user_name_or_arn) when is_binary(user_name_or_arn) do
    case fetch_user_record(user_name_or_arn) do
      %User{} = user -> {:ok, public_user(user)}
      nil -> :error
    end
  end

  def get_user(_user_name_or_arn), do: :error

  @doc "Renames an IAM user and preserves all ARN-keyed local references."
  @spec update_user_name_strict(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def update_user_name_strict(current_user_name, new_user_name)
      when is_binary(current_user_name) and (is_binary(new_user_name) or is_nil(new_user_name)) do
    new_user_name = normalize_iam_text(new_user_name || current_user_name)

    case fetch_user_record(current_user_name) do
      %User{} = user ->
        old_snapshot = {:existing, user.id}
        new_snapshot = UserIdentity.snapshot(Repo, new_user_name)
        old_arn = user.user_arn
        new_arn = default_user_arn(new_user_name)

        Repo.transaction(fn ->
          with {:ok, [locked_user, new_identity]} <-
                 UserIdentity.lock_snapshots(Repo, [
                   {user.user_name, old_snapshot},
                   {new_user_name, new_snapshot}
                 ]),
               :ok <- ensure_rename_target(locked_user, new_identity),
               {:ok, updated} <-
                 locked_user
                 |> User.changeset(%{user_name: new_user_name, user_arn: new_arn})
                 |> Repo.update() do
            access_key_ids =
              access_keys_for_principal(old_arn) ++ session_access_keys_for_principal(old_arn)

            update_user_principal_references(old_arn, new_arn)
            {updated, access_key_ids}
          else
            {:error, reason} -> Repo.rollback({:error, reason})
          end
        end)
        |> case do
          {:ok, {updated, access_key_ids}} ->
            broadcast_principal_rename(old_arn, new_arn, access_key_ids)
            {:ok, public_user(updated)}

          {:error, {:error, reason}} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        {:error, :not_found}
    end
  end

  def update_user_name_strict(_current_user_name, _new_user_name), do: {:error, :malformed}

  @doc "Adds or replaces a managed policy permissions boundary on an IAM user."
  @spec put_user_permissions_boundary_strict(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def put_user_permissions_boundary_strict(user_name_or_arn, policy_arn)
      when is_binary(user_name_or_arn) and is_binary(policy_arn) do
    with :ok <- ensure_permissions_boundary_policy(policy_arn) do
      update_user(user_name_or_arn, fn user ->
        User.changeset(user, %{permissions_boundary_policy_arn: policy_arn})
      end)
    end
  end

  def put_user_permissions_boundary_strict(_user_name_or_arn, _policy_arn),
    do: {:error, :malformed}

  @doc "Removes the managed policy permissions boundary from an IAM user."
  @spec delete_user_permissions_boundary_strict(String.t()) :: {:ok, map()} | {:error, term()}
  def delete_user_permissions_boundary_strict(user_name_or_arn)
      when is_binary(user_name_or_arn) do
    update_user(user_name_or_arn, fn user ->
      User.changeset(user, %{permissions_boundary_policy_arn: nil})
    end)
  end

  def delete_user_permissions_boundary_strict(_user_name_or_arn), do: {:error, :malformed}

  @doc "Lists explicit IAM users."
  @spec list_users() :: [map()]
  def list_users do
    User
    |> order_by([u], asc: u.user_name)
    |> Repo.all()
    |> Enum.map(&public_user/1)
  end

  @doc """
  Deletes an IAM user and cascades local subordinate credentials/policies.

  This is the local cleanup helper used by the console and maintenance tasks.
  AWS IAM Query `DeleteUser` uses `delete_user_strict/1`, which rejects deletion
  until subordinate IAM resources are removed explicitly.
  """
  @spec delete_user(String.t()) :: :ok | {:error, term()}
  def delete_user(user_name_or_arn) when is_binary(user_name_or_arn) do
    case fetch_user_record(user_name_or_arn) do
      nil ->
        :ok

      %User{} = initial ->
        snapshot = {:existing, initial.id}

        Repo.transaction(fn ->
          with {:ok, %User{} = user} <-
                 UserIdentity.lock_snapshot(Repo, initial.user_name, snapshot) do
            credential_ids = UserIdentity.descendant_credential_ids(Repo, user)
            session_access_key_ids = revoke_user_sessions(user.user_arn, credential_ids.long_term)

            Repo.delete_all(from p in PrincipalPolicy, where: p.principal_arn == ^user.user_arn)
            Repo.delete_all(from m in MFADevice, where: m.principal_arn == ^user.user_arn)
            Repo.delete_all(from a in AccessKey, where: a.principal_arn == ^user.user_arn)
            Repo.delete_all(from c in SigningCertificate, where: c.user_arn == ^user.user_arn)
            Repo.delete_all(from k in SSHPublicKey, where: k.user_arn == ^user.user_arn)
            Repo.delete!(user)

            {user.user_arn,
             Enum.uniq(
               credential_ids.long_term ++ credential_ids.sessions ++ session_access_key_ids
             )}
          else
            {:error, :user_not_found} -> Repo.rollback(:already_missing)
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
        |> case do
          {:ok, {user_arn, credential_ids}} ->
            Notify.broadcast({:principal_policy_changed, user_arn})
            Enum.each(credential_ids, &Notify.broadcast({:iam_changed, &1}))
            :ok

          {:error, :already_missing} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def delete_user(_user_name_or_arn), do: {:error, :malformed}

  @doc "Deletes an IAM user only when no subordinate IAM resources remain."
  @spec delete_user_strict(String.t()) :: {:ok, map()} | {:error, term()}
  def delete_user_strict(user_name_or_arn) when is_binary(user_name_or_arn) do
    case fetch_user_record(user_name_or_arn) do
      %User{} = initial ->
        Repo.transaction(fn ->
          with {:ok, %User{} = user} <-
                 UserIdentity.lock_snapshot(
                   Repo,
                   initial.user_name,
                   {:existing, initial.id}
                 ) do
            case user_delete_blockers(user) do
              [] ->
                Repo.delete!(user)
                user

              blockers ->
                Repo.rollback({:error, {:delete_conflict, blockers}})
            end
          else
            {:error, reason} -> Repo.rollback({:error, reason})
          end
        end)
        |> case do
          {:ok, user} ->
            Notify.broadcast({:principal_policy_changed, user.user_arn})
            {:ok, public_user(user)}

          {:error, {:error, :user_not_found}} ->
            {:error, :not_found}

          {:error, {:error, reason}} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        {:error, :not_found}
    end
  end

  def delete_user_strict(_user_name_or_arn), do: {:error, :malformed}

  @doc "Adds or replaces tags on an IAM user."
  @spec tag_user(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def tag_user(user_name_or_arn, tags) when is_binary(user_name_or_arn) and is_map(tags) do
    tags = normalize_tags(tags)

    update_user(user_name_or_arn, fn user ->
      User.changeset(user, %{tags: merge_user_tags(user.tags || %{}, tags)})
    end)
  end

  def tag_user(_user_name_or_arn, _tags), do: {:error, :malformed}

  @doc "Removes tags from an IAM user. Missing keys are ignored."
  @spec untag_user(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def untag_user(user_name_or_arn, tag_keys)
      when is_binary(user_name_or_arn) and is_list(tag_keys) do
    tag_keys = Enum.map(tag_keys, &to_string/1)

    update_user(user_name_or_arn, fn user ->
      User.changeset(user, %{tags: drop_user_tags(user.tags || %{}, tag_keys)})
    end)
  end

  def untag_user(_user_name_or_arn, _tag_keys), do: {:error, :malformed}

  @doc "Adds or replaces an inline identity policy on an IAM user using AWS Query strict semantics."
  @spec put_user_policy_strict(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def put_user_policy_strict(user_name_or_arn, name, json)
      when is_binary(user_name_or_arn) and is_binary(name) and is_binary(json) do
    with %User{} = user <- fetch_user_record(user_name_or_arn),
         :ok <-
           put_inline_policy_strict(
             user.user_arn,
             name,
             json,
             @user_inline_policy_quota_chars
           ) do
      :ok
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def put_user_policy_strict(_user_name_or_arn, _name, _json), do: {:error, :malformed}

  @doc "Fetches an IAM user inline identity policy using AWS Query strict semantics."
  @spec get_user_policy_strict(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_user_policy_strict(user_name_or_arn, name)
      when is_binary(user_name_or_arn) and is_binary(name) do
    with %User{} = user <- fetch_user_record(user_name_or_arn),
         {:ok, policy} <- Store.get_principal_policy(user.user_arn, name) do
      {:ok,
       policy
       |> Map.put(:user_name, user.user_name)
       |> Map.put(:user_arn, user.user_arn)}
    else
      nil -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_user_policy_strict(_user_name_or_arn, _name), do: {:error, :malformed}

  @doc "Lists IAM user inline identity policies using AWS Query strict semantics."
  @spec list_user_policies_strict(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_user_policies_strict(user_name_or_arn) when is_binary(user_name_or_arn) do
    case fetch_user_record(user_name_or_arn) do
      %User{} = user -> {:ok, list_principal_policies(user.user_arn)}
      nil -> {:error, :not_found}
    end
  end

  def list_user_policies_strict(_user_name_or_arn), do: {:error, :malformed}

  @doc "Deletes an IAM user inline identity policy using AWS Query strict semantics."
  @spec delete_user_policy_strict(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_user_policy_strict(user_name_or_arn, name)
      when is_binary(user_name_or_arn) and is_binary(name) do
    with %User{} = user <- fetch_user_record(user_name_or_arn),
         {:ok, _policy} <- Store.get_principal_policy(user.user_arn, name) do
      delete_principal_policy(user.user_arn, name)
    else
      nil -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_user_policy_strict(_user_name_or_arn, _name), do: {:error, :malformed}

  @doc "Creates an IAM group. Policies bound to the group ARN are inherited by members."
  @spec create_group(keyword()) :: {:ok, map()} | {:error, term()}
  def create_group(opts \\ []) do
    group_name =
      opts
      |> Keyword.get(:group_name, Keyword.get(opts, :name))
      |> normalize_iam_text()

    group_arn =
      opts
      |> Keyword.get(:group_arn, default_group_arn(group_name))
      |> normalize_iam_text()

    attrs = %{
      group_name: group_name,
      group_arn: group_arn,
      status: opts |> Keyword.get(:status, "active") |> normalize_iam_text(),
      tags: opts |> Keyword.get(:tags, %{}) |> normalize_tags()
    }

    with :ok <- reject_group_name_case_insensitive_duplicate(group_name) do
      case %Group{} |> Group.changeset(attrs) |> Repo.insert() do
        {:ok, group} ->
          Notify.broadcast({:iam_changed, group.group_arn})
          {:ok, public_group(group)}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc "Fetches an IAM group by group name or ARN."
  @spec get_group(String.t()) :: {:ok, map()} | :error
  def get_group(group_name_or_arn) when is_binary(group_name_or_arn) do
    case fetch_group_record(group_name_or_arn) do
      %Group{} = group -> {:ok, public_group(group)}
      nil -> :error
    end
  end

  def get_group(_group_name_or_arn), do: :error

  @doc "Renames an IAM group and preserves all ARN-keyed local references."
  @spec update_group_name_strict(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def update_group_name_strict(current_group_name, new_group_name)
      when is_binary(current_group_name) and (is_binary(new_group_name) or is_nil(new_group_name)) do
    new_group_name = normalize_iam_text(new_group_name || current_group_name)

    with %Group{} = group <- fetch_group_record(current_group_name),
         :ok <- reject_group_name_update_duplicate(group, new_group_name) do
      old_arn = group.group_arn
      new_arn = default_group_arn(new_group_name)

      if group.group_name == new_group_name and old_arn == new_arn do
        {:ok, public_group(group)}
      else
        update_group_name_transaction(group, new_group_name, new_arn)
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_group_name_strict(_current_group_name, _new_group_name),
    do: {:error, :malformed}

  @doc "Lists IAM groups."
  @spec list_groups() :: [map()]
  def list_groups do
    Group
    |> order_by([g], asc: g.group_name)
    |> Repo.all()
    |> Enum.map(&public_group/1)
  end

  @doc "Deletes an IAM group, its memberships, and policies bound to the group ARN."
  @spec delete_group(String.t()) :: :ok
  def delete_group(group_name_or_arn) when is_binary(group_name_or_arn) do
    case get_group(group_name_or_arn) do
      {:ok, group} ->
        Repo.transaction(fn ->
          Repo.delete_all(from p in PrincipalPolicy, where: p.principal_arn == ^group.group_arn)
          Repo.delete_all(from g in Group, where: g.group_arn == ^group.group_arn)
        end)

        Notify.broadcast({:principal_policy_changed, group.group_arn})
        Notify.broadcast({:iam_changed, group.group_arn})
        :ok

      :error ->
        :ok
    end
  end

  def delete_group(_group_name_or_arn), do: :ok

  @doc "Deletes an IAM group only when no subordinate IAM resources remain."
  @spec delete_group_strict(String.t()) :: {:ok, map()} | {:error, term()}
  def delete_group_strict(group_name_or_arn) when is_binary(group_name_or_arn) do
    case fetch_group_record(group_name_or_arn) do
      %Group{} = group ->
        case group_delete_blockers(group) do
          [] ->
            Repo.delete!(group)
            Notify.broadcast({:iam_changed, group.group_arn})
            {:ok, public_group(group)}

          blockers ->
            {:error, {:group_delete_conflict, blockers}}
        end

      nil ->
        {:error, :not_found}
    end
  end

  def delete_group_strict(_group_name_or_arn), do: {:error, :malformed}

  @doc "Adds an IAM user to an IAM group. The operation is idempotent."
  @spec add_user_to_group(String.t(), String.t()) :: :ok | {:error, term()}
  def add_user_to_group(user_name_or_arn, group_name_or_arn)
      when is_binary(user_name_or_arn) and is_binary(group_name_or_arn) do
    with {:ok, user} <- get_user(user_name_or_arn),
         {:ok, group} <- get_group(group_name_or_arn) do
      %GroupMembership{}
      |> GroupMembership.changeset(%{user_arn: user.user_arn, group_arn: group.group_arn})
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_arn, :group_arn])
      |> case do
        {:ok, _membership} ->
          Notify.broadcast({:principal_policy_changed, user.user_arn})
          :ok

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      # `get_user/1` 与 `get_group/1` 的契约都是 `{:ok, map()} | :error`（见各自实现：
      # `fetch_*_record/1` 返回 nil 时归一成裸 `:error`），从不返回 `{:error, _}`。
      # 原来那条 `{:error, reason} -> {:error, reason}` 是恒等映射且恒不可达，删除后
      # 唯一可达的失败仍然是结构化的 `{:error, :not_found}`。
      :error -> {:error, :not_found}
    end
  end

  def add_user_to_group(_user_name_or_arn, _group_name_or_arn), do: {:error, :malformed}

  @doc "Adds an IAM user to an IAM group after strictly resolving both resources."
  @spec add_user_to_group_strict(String.t(), String.t()) :: :ok | {:error, term()}
  def add_user_to_group_strict(user_name_or_arn, group_name_or_arn)
      when is_binary(user_name_or_arn) and is_binary(group_name_or_arn) do
    with %User{} = user <- fetch_user_record(user_name_or_arn),
         %Group{} = group <- fetch_group_record(group_name_or_arn) do
      %GroupMembership{}
      |> GroupMembership.changeset(%{user_arn: user.user_arn, group_arn: group.group_arn})
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_arn, :group_arn])
      |> case do
        {:ok, _membership} ->
          Notify.broadcast({:principal_policy_changed, user.user_arn})
          :ok

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def add_user_to_group_strict(_user_name_or_arn, _group_name_or_arn),
    do: {:error, :malformed}

  @doc "Removes an IAM user from an IAM group. The operation is idempotent."
  @spec remove_user_from_group(String.t(), String.t()) :: :ok
  def remove_user_from_group(user_name_or_arn, group_name_or_arn)
      when is_binary(user_name_or_arn) and is_binary(group_name_or_arn) do
    user_arn = resolve_user_arn(user_name_or_arn)
    group_arn = resolve_group_arn(group_name_or_arn)

    Repo.delete_all(
      from m in GroupMembership,
        where: m.user_arn == ^user_arn and m.group_arn == ^group_arn
    )

    Notify.broadcast({:principal_policy_changed, user_arn})
    :ok
  end

  def remove_user_from_group(_user_name_or_arn, _group_name_or_arn), do: :ok

  @doc "Removes an IAM user from an IAM group only when both resources and membership exist."
  @spec remove_user_from_group_strict(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_user_from_group_strict(user_name_or_arn, group_name_or_arn)
      when is_binary(user_name_or_arn) and is_binary(group_name_or_arn) do
    with %User{} = user <- fetch_user_record(user_name_or_arn),
         %Group{} = group <- fetch_group_record(group_name_or_arn),
         %GroupMembership{} = membership <-
           Repo.get_by(GroupMembership, user_arn: user.user_arn, group_arn: group.group_arn) do
      Repo.delete!(membership)
      Notify.broadcast({:principal_policy_changed, user.user_arn})
      :ok
    else
      nil -> {:error, :not_found}
    end
  end

  def remove_user_from_group_strict(_user_name_or_arn, _group_name_or_arn),
    do: {:error, :malformed}

  @doc "Lists users that are members of an IAM group."
  @spec list_users_in_group(String.t()) :: [map()]
  def list_users_in_group(group_name_or_arn) when is_binary(group_name_or_arn) do
    case fetch_group_record(group_name_or_arn) do
      %Group{} = group ->
        from(m in GroupMembership,
          join: u in User,
          on: u.user_arn == m.user_arn,
          where: m.group_arn == ^group.group_arn,
          order_by: [asc: u.user_name],
          select: u
        )
        |> Repo.all()
        |> Enum.map(&public_user/1)

      nil ->
        []
    end
  end

  def list_users_in_group(_group_name_or_arn), do: []

  @doc "Lists groups for an IAM user."
  @spec list_groups_for_user(String.t()) :: [map()]
  def list_groups_for_user(user_name_or_arn) when is_binary(user_name_or_arn) do
    case fetch_user_record(user_name_or_arn) do
      %User{} = user ->
        from(m in GroupMembership,
          join: g in Group,
          on: g.group_arn == m.group_arn,
          where: m.user_arn == ^user.user_arn,
          order_by: [asc: g.group_name],
          select: g
        )
        |> Repo.all()
        |> Enum.map(&public_group/1)

      nil ->
        []
    end
  end

  def list_groups_for_user(_user_name_or_arn), do: []

  @doc "Adds or replaces an inline identity policy on an IAM group using AWS Query strict semantics."
  @spec put_group_policy_strict(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def put_group_policy_strict(group_name_or_arn, name, json)
      when is_binary(group_name_or_arn) and is_binary(name) and is_binary(json) do
    with %Group{} = group <- fetch_group_record(group_name_or_arn),
         :ok <-
           put_inline_policy_strict(
             group.group_arn,
             name,
             json,
             @group_inline_policy_quota_chars
           ) do
      :ok
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def put_group_policy_strict(_group_name_or_arn, _name, _json), do: {:error, :malformed}

  @doc "Fetches an IAM group inline identity policy using AWS Query strict semantics."
  @spec get_group_policy_strict(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_group_policy_strict(group_name_or_arn, name)
      when is_binary(group_name_or_arn) and is_binary(name) do
    with %Group{} = group <- fetch_group_record(group_name_or_arn),
         {:ok, policy} <- Store.get_principal_policy(group.group_arn, name) do
      {:ok,
       policy
       |> Map.put(:group_name, group.group_name)
       |> Map.put(:group_arn, group.group_arn)}
    else
      nil -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_group_policy_strict(_group_name_or_arn, _name), do: {:error, :malformed}

  @doc "Lists IAM group inline identity policies using AWS Query strict semantics."
  @spec list_group_policies_strict(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_group_policies_strict(group_name_or_arn) when is_binary(group_name_or_arn) do
    case fetch_group_record(group_name_or_arn) do
      %Group{} = group -> {:ok, list_principal_policies(group.group_arn)}
      nil -> {:error, :not_found}
    end
  end

  def list_group_policies_strict(_group_name_or_arn), do: {:error, :malformed}

  @doc "Deletes an IAM group inline identity policy using AWS Query strict semantics."
  @spec delete_group_policy_strict(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_group_policy_strict(group_name_or_arn, name)
      when is_binary(group_name_or_arn) and is_binary(name) do
    with %Group{} = group <- fetch_group_record(group_name_or_arn),
         {:ok, _policy} <- Store.get_principal_policy(group.group_arn, name) do
      delete_principal_policy(group.group_arn, name)
    else
      nil -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_group_policy_strict(_group_name_or_arn, _name), do: {:error, :malformed}

  @doc "Adds or replaces an inline identity policy on an IAM role using AWS Query strict semantics."
  @spec put_role_policy_strict(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def put_role_policy_strict(role_name_or_arn, name, json)
      when is_binary(role_name_or_arn) and is_binary(name) and is_binary(json) do
    with %Role{} = role <- fetch_role_record(role_name_or_arn),
         :ok <-
           put_inline_policy_strict(
             role.role_arn,
             name,
             json,
             @role_inline_policy_quota_chars
           ) do
      :ok
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def put_role_policy_strict(_role_name_or_arn, _name, _json), do: {:error, :malformed}

  @doc "Fetches an IAM role inline identity policy using AWS Query strict semantics."
  @spec get_role_policy_strict(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_role_policy_strict(role_name_or_arn, name)
      when is_binary(role_name_or_arn) and is_binary(name) do
    with %Role{} = role <- fetch_role_record(role_name_or_arn),
         {:ok, policy} <- Store.get_principal_policy(role.role_arn, name) do
      {:ok,
       policy
       |> Map.put(:role_name, role.role_name)
       |> Map.put(:role_arn, role.role_arn)}
    else
      nil -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_role_policy_strict(_role_name_or_arn, _name), do: {:error, :malformed}

  @doc "Lists IAM role inline identity policies using AWS Query strict semantics."
  @spec list_role_policies_strict(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_role_policies_strict(role_name_or_arn) when is_binary(role_name_or_arn) do
    case fetch_role_record(role_name_or_arn) do
      %Role{} = role -> {:ok, list_principal_policies(role.role_arn)}
      nil -> {:error, :not_found}
    end
  end

  def list_role_policies_strict(_role_name_or_arn), do: {:error, :malformed}

  @doc "Deletes an IAM role inline identity policy using AWS Query strict semantics."
  @spec delete_role_policy_strict(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_role_policy_strict(role_name_or_arn, name)
      when is_binary(role_name_or_arn) and is_binary(name) do
    with %Role{} = role <- fetch_role_record(role_name_or_arn),
         {:ok, _policy} <- Store.get_principal_policy(role.role_arn, name) do
      delete_principal_policy(role.role_arn, name)
    else
      nil -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_role_policy_strict(_role_name_or_arn, _name), do: {:error, :malformed}

  @doc "Binds or replaces an identity policy on an IAM group."
  @spec put_group_policy(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def put_group_policy(group_name_or_arn, name, json)
      when is_binary(group_name_or_arn) and is_binary(name) and is_binary(json) do
    with {:ok, group} <- get_group(group_name_or_arn) do
      put_principal_policy(group.group_arn, name, json)
    else
      :error -> {:error, :not_found}
    end
  end

  def put_group_policy(_group_name_or_arn, _name, _json), do: {:error, :malformed}

  @doc "Lists identity policies directly bound to an IAM group."
  @spec list_group_policies(String.t()) :: [map()]
  def list_group_policies(group_name_or_arn) when is_binary(group_name_or_arn) do
    case get_group(group_name_or_arn) do
      {:ok, group} -> list_principal_policies(group.group_arn)
      :error -> []
    end
  end

  def list_group_policies(_group_name_or_arn), do: []

  @doc "Deletes an identity policy bound to an IAM group."
  @spec delete_group_policy(String.t(), String.t()) :: :ok
  def delete_group_policy(group_name_or_arn, name)
      when is_binary(group_name_or_arn) and is_binary(name) do
    case get_group(group_name_or_arn) do
      {:ok, group} -> delete_principal_policy(group.group_arn, name)
      :error -> :ok
    end
  end

  def delete_group_policy(_group_name_or_arn, _name), do: :ok

  @doc """
  绑定或覆盖一个 principal identity policy。

  identity policy 不允许显式 Principal；principal 由绑定的 principal ARN 隐式提供。
  """
  @spec put_principal_policy(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def put_principal_policy(principal_arn, name, json)
      when is_binary(principal_arn) and is_binary(name) and is_binary(json),
      do: Store.put_principal_policy(principal_arn, name, json)

  def put_principal_policy(_principal_arn, _name, _json), do: {:error, :malformed}

  @doc "列出某 principal 绑定的 identity policies（不解析为 Statement，用于 CLI/Console 展示）。"
  @spec list_principal_policies(String.t()) :: [map()]
  def list_principal_policies(principal_arn) when is_binary(principal_arn),
    do: Store.list_principal_policies(principal_arn)

  def list_principal_policies(_principal_arn), do: []

  @doc "删除某 principal 的一个 identity policy（幂等）。"
  @spec delete_principal_policy(String.t(), String.t()) :: :ok
  def delete_principal_policy(principal_arn, name)
      when is_binary(principal_arn) and is_binary(name),
      do: Store.delete_principal_policy(principal_arn, name)

  def delete_principal_policy(_principal_arn, _name), do: :ok

  @doc "Returns the local single-account managed policy ARN for a policy name and IAM path."
  @spec managed_policy_arn(String.t(), String.t()) :: String.t()
  def managed_policy_arn(policy_name, path \\ "/") do
    policy_name = normalize_iam_text(policy_name)
    path = normalize_iam_text(path || "/")
    resource_path = managed_policy_resource_path(policy_name, path)

    "arn:aws:iam:::policy/#{resource_path}"
  end

  @doc "Validates a local single-account managed policy ARN."
  @spec validate_managed_policy_arn(String.t()) :: :ok | {:error, term()}
  def validate_managed_policy_arn(policy_arn) do
    case parse_managed_policy_arn(policy_arn) do
      {:ok, _metadata} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a local managed policy document without replacing an existing ARN.

  The policy can be referenced by STS AssumeRole `PolicyArns` and attached to
  local users/groups/roles as identity policy.
  """
  @spec create_managed_policy(keyword()) :: {:ok, map()} | {:error, term()}
  def create_managed_policy(opts) when is_list(opts) do
    document = Keyword.get(opts, :document, Keyword.get(opts, :policy))

    with {:ok, %{policy_arn: policy_arn}} <- managed_policy_target(opts),
         {:ok, json} <- normalize_policy_document(document),
         :ok <- Store.create_managed_session_policy(policy_arn, json),
         {:ok, policy} <- get_managed_policy(policy_arn) do
      {:ok, policy}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :malformed}
    end
  end

  def create_managed_policy(_opts), do: {:error, :malformed}

  @doc """
  Creates a local managed policy using AWS Query API semantics.

  Unlike `create_managed_policy/1`, this entrypoint validates the managed
  policy document quota before insert and returns strict duplicate/quota errors.
  """
  @spec create_managed_policy_strict(keyword()) :: {:ok, map()} | {:error, term()}
  def create_managed_policy_strict(opts) when is_list(opts) do
    document = Keyword.get(opts, :document, Keyword.get(opts, :policy))
    description = managed_policy_description(opts)
    tags = opts |> Keyword.get(:tags, %{}) |> normalize_tags()

    with {:ok, %{policy_arn: policy_arn}} <- managed_policy_target(opts),
         :ok <- validate_managed_policy_description(description),
         :ok <- validate_managed_policy_tags(tags),
         {:ok, json} <- normalize_policy_document(document),
         {:ok, _document, _policy_chars} <- validate_managed_policy_document(json),
         :ok <-
           create_managed_policy_row_strict(policy_arn, json, %{
             description: description,
             tags: tags
           }),
         {:ok, policy} <- get_managed_policy(policy_arn) do
      {:ok, policy}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :malformed}
    end
  end

  def create_managed_policy_strict(_opts), do: {:error, :malformed}

  @doc """
  Creates or replaces a local managed policy document.

  This upsert-style helper is kept for tests, seeding and STS fixtures. The
  IAM management surface should use `create_managed_policy/1`.
  """
  @spec put_managed_policy(keyword()) :: :ok | {:error, term()}
  def put_managed_policy(opts) when is_list(opts) do
    document = Keyword.get(opts, :document, Keyword.get(opts, :policy))

    with {:ok, %{policy_arn: policy_arn}} <- managed_policy_target(opts),
         {:ok, json} <- normalize_policy_document(document) do
      Store.put_managed_session_policy(policy_arn, json)
    else
      _ -> {:error, :malformed}
    end
  end

  def put_managed_policy(_opts), do: {:error, :malformed}

  @doc "Fetches a local managed policy document by ARN."
  @spec get_managed_policy(String.t()) :: {:ok, map()} | :error | {:error, term()}
  def get_managed_policy(policy_arn) when is_binary(policy_arn) do
    with {:ok, metadata} <- parse_managed_policy_arn(policy_arn),
         {:ok, json} <- Store.managed_session_policy(policy_arn),
         {:ok, document} <- Jason.decode(json) do
      policy =
        metadata
        |> Map.merge(managed_policy_store_metadata(policy_arn))
        |> Map.put(:document, document)
        |> put_managed_policy_runtime_metadata()

      {:ok, policy}
    else
      {:error, :not_found} -> :error
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  def get_managed_policy(_policy_arn), do: {:error, :malformed}

  @doc "Lists local managed policies without expanding them into any principal identity policy."
  @spec list_managed_policies(keyword()) :: [map()]
  def list_managed_policies(opts \\ []) do
    path_prefix =
      opts
      |> Keyword.get(:path_prefix, "/")
      |> normalize_iam_text()

    scope = opts |> Keyword.get(:scope, "Local") |> normalize_iam_text()

    policy_usage_filter =
      opts |> Keyword.get(:policy_usage_filter, "PermissionsPolicy") |> normalize_iam_text()

    only_attached = managed_policy_only_attached?(Keyword.get(opts, :only_attached, false))

    cond do
      validate_managed_policy_path(path_prefix) != :ok ->
        []

      scope == "AWS" ->
        []

      true ->
        Store.list_managed_session_policies()
        |> Enum.flat_map(&managed_policy_listing/1)
        |> Enum.filter(&String.starts_with?(&1.path, path_prefix))
        |> Enum.filter(
          &managed_policy_matches_usage_filter?(&1, policy_usage_filter, only_attached)
        )
    end
  end

  @doc "Deletes a local managed policy by ARN. Existing STS sessions keep their policy snapshot."
  @spec delete_managed_policy(String.t()) :: :ok | {:error, term()}
  def delete_managed_policy(policy_arn) when is_binary(policy_arn) do
    with :ok <- validate_managed_policy_arn(policy_arn) do
      Store.delete_managed_session_policy(policy_arn)
    end
  end

  def delete_managed_policy(_policy_arn), do: {:error, :malformed}

  @doc "Deletes a local managed policy using AWS Query API strict missing/attached semantics."
  @spec delete_managed_policy_strict(String.t()) :: :ok | {:error, term()}
  def delete_managed_policy_strict(policy_arn) when is_binary(policy_arn) do
    with :ok <- validate_managed_policy_arn(policy_arn) do
      delete_managed_policy_row_strict(policy_arn)
    end
  end

  def delete_managed_policy_strict(_policy_arn), do: {:error, :malformed}

  @doc "Creates a new local managed policy version using AWS Query API semantics."
  @spec create_managed_policy_version_strict(String.t(), term(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def create_managed_policy_version_strict(policy_arn, document, set_as_default)
      when is_binary(policy_arn) and is_boolean(set_as_default) do
    with :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, json} <- normalize_policy_document(document) do
      with {:ok, _document, _policy_chars} <- validate_managed_policy_document(json),
           {:ok, version} <-
             Store.create_managed_session_policy_version(policy_arn, json, set_as_default) do
        {:ok, version}
      else
        # 两条被删的子句都恒不可达：
        # * `:error ->` —— `Store.create_managed_session_policy_version/3` 用
        #   `Repo.rollback({:error, :not_found})` 表达"策略不存在"，返回的是
        #   `{:error, :not_found}` 而不是裸 `:error`；这条 not_found 已由下面的透传原样带出。
        # * `_other ->` —— `Maxio.Policy.Store` 自己就用 `case result do {:ok, _} | {:error, _} end`
        #   把可插拔后端的返回值收窄成这两种形状（后端跑偏会在 Store 那一层炸掉，
        #   而不是把畸形值漏到这里），`validate_managed_policy_document/1` 同理。
        {:error, reason} when reason in [:malformed, :malformed_policy_document] ->
          {:error, :malformed_policy_document}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def create_managed_policy_version_strict(_policy_arn, _document, _set_as_default),
    do: {:error, :malformed}

  @doc "Fetches one local managed policy version using AWS Query API strict semantics."
  @spec get_managed_policy_version_strict(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_managed_policy_version_strict(policy_arn, version_id)
      when is_binary(policy_arn) and is_binary(version_id) do
    with :ok <- validate_managed_policy_arn(policy_arn),
         :ok <- validate_managed_policy_version_id(version_id),
         {:ok, version} <- Store.get_managed_session_policy_version(policy_arn, version_id) do
      {:ok, version}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_managed_policy_version_strict(_policy_arn, _version_id), do: {:error, :malformed}

  @doc "Lists local managed policy versions using AWS Query API strict semantics."
  @spec list_managed_policy_versions_strict(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_managed_policy_versions_strict(policy_arn) when is_binary(policy_arn) do
    with :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, versions} <- Store.list_managed_session_policy_versions(policy_arn) do
      {:ok, versions}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_managed_policy_versions_strict(_policy_arn), do: {:error, :malformed}

  @doc "Changes the default local managed policy version."
  @spec set_default_managed_policy_version_strict(String.t(), String.t()) ::
          :ok | {:error, term()}
  def set_default_managed_policy_version_strict(policy_arn, version_id)
      when is_binary(policy_arn) and is_binary(version_id) do
    with :ok <- validate_managed_policy_arn(policy_arn),
         :ok <- validate_managed_policy_version_id(version_id) do
      Store.set_default_managed_session_policy_version(policy_arn, version_id)
    end
  end

  def set_default_managed_policy_version_strict(_policy_arn, _version_id),
    do: {:error, :malformed}

  @doc "Deletes a non-default local managed policy version."
  @spec delete_managed_policy_version_strict(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_managed_policy_version_strict(policy_arn, version_id)
      when is_binary(policy_arn) and is_binary(version_id) do
    with :ok <- validate_managed_policy_arn(policy_arn),
         :ok <- validate_managed_policy_version_id(version_id) do
      Store.delete_managed_session_policy_version(policy_arn, version_id)
    end
  end

  def delete_managed_policy_version_strict(_policy_arn, _version_id),
    do: {:error, :malformed}

  @doc "Adds or replaces tags on a local managed policy using AWS Query API semantics."
  @spec tag_managed_policy_strict(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def tag_managed_policy_strict(policy_arn, tags) when is_binary(policy_arn) and is_map(tags) do
    tags = normalize_tags(tags)

    with :ok <- validate_managed_policy_arn(policy_arn),
         :ok <- validate_managed_policy_tags(tags),
         :ok <- tag_managed_policy_row_strict(policy_arn, tags),
         {:ok, policy} <- get_managed_policy(policy_arn) do
      {:ok, policy}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def tag_managed_policy_strict(_policy_arn, _tags), do: {:error, :malformed}

  @doc "Removes tags from a local managed policy using AWS Query API semantics."
  @spec untag_managed_policy_strict(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def untag_managed_policy_strict(policy_arn, tag_keys)
      when is_binary(policy_arn) and is_list(tag_keys) do
    tag_keys = Enum.map(tag_keys, &to_string/1)

    with :ok <- validate_managed_policy_arn(policy_arn),
         :ok <- validate_managed_policy_tag_keys(tag_keys),
         :ok <- untag_managed_policy_row_strict(policy_arn, tag_keys),
         {:ok, policy} <- get_managed_policy(policy_arn) do
      {:ok, policy}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def untag_managed_policy_strict(_policy_arn, _tag_keys), do: {:error, :malformed}

  @doc "Lists local managed-policy tags using AWS Query API strict missing semantics."
  @spec list_managed_policy_tags_strict(String.t()) :: {:ok, map()} | {:error, term()}
  def list_managed_policy_tags_strict(policy_arn) when is_binary(policy_arn) do
    with :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, policy} <- get_managed_policy(policy_arn) do
      {:ok, policy}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_managed_policy_tags_strict(_policy_arn), do: {:error, :malformed}

  @doc "Lists IAM entities attached to a local managed policy."
  @spec list_managed_policy_entities_strict(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def list_managed_policy_entities_strict(policy_arn, opts \\ [])

  def list_managed_policy_entities_strict(policy_arn, opts)
      when is_binary(policy_arn) and is_list(opts) do
    entity_filter = opts |> Keyword.get(:entity_filter, "All") |> normalize_iam_text()

    path_prefix =
      opts
      |> Keyword.get(:path_prefix, "/")
      |> normalize_iam_text()

    policy_usage_filter =
      opts |> Keyword.get(:policy_usage_filter, "PermissionsPolicy") |> normalize_iam_text()

    with :ok <- validate_managed_policy_arn(policy_arn),
         :ok <- validate_policy_entity_filter(entity_filter),
         :ok <- validate_policy_usage_filter(policy_usage_filter),
         :ok <- validate_iam_entity_path_prefix(path_prefix),
         :ok <- require_existing_managed_policy(policy_arn) do
      entities =
        policy_arn
        |> managed_policy_entities_for_usage(policy_usage_filter)
        |> filter_managed_policy_entities(entity_filter, path_prefix)

      {:ok, entities}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def list_managed_policy_entities_strict(_policy_arn, _opts), do: {:error, :malformed}

  @doc "Attaches a local managed policy to a user using AWS Query strict semantics."
  @spec attach_user_policy_strict(String.t(), String.t()) :: :ok | {:error, term()}
  def attach_user_policy_strict(user_name_or_arn, policy_arn)
      when is_binary(user_name_or_arn) and is_binary(policy_arn) do
    with %User{} = user <- fetch_user_record(user_name_or_arn),
         :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, _policy} <- get_managed_policy(policy_arn) do
      attach_user_managed_policy_with_quota(user.user_arn, policy_arn)
    else
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def attach_user_policy_strict(_user_name_or_arn, _policy_arn), do: {:error, :malformed}

  @doc "Lists managed policies directly attached to a user using AWS Query strict semantics."
  @spec list_attached_user_policies_strict(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_attached_user_policies_strict(user_name_or_arn, opts \\ [])

  def list_attached_user_policies_strict(user_name_or_arn, opts)
      when is_binary(user_name_or_arn) and is_list(opts) do
    path_prefix =
      opts
      |> Keyword.get(:path_prefix, "/")
      |> normalize_iam_text()

    with :ok <- validate_managed_policy_path(path_prefix),
         %User{} = user <- fetch_user_record(user_name_or_arn) do
      policies =
        user.user_arn
        |> Store.list_attached_user_managed_policies()
        |> Enum.flat_map(&attached_user_policy_listing/1)
        |> Enum.filter(&String.starts_with?(&1.path, path_prefix))

      {:ok, policies}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_attached_user_policies_strict(_user_name_or_arn, _opts), do: {:error, :malformed}

  @doc "Detaches a managed policy from a user using AWS Query strict semantics."
  @spec detach_user_policy_strict(String.t(), String.t()) :: :ok | {:error, term()}
  def detach_user_policy_strict(user_name_or_arn, policy_arn)
      when is_binary(user_name_or_arn) and is_binary(policy_arn) do
    with %User{} = user <- fetch_user_record(user_name_or_arn),
         :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, _policy} <- get_managed_policy(policy_arn) do
      detach_managed_policy_with_policy_lock(
        user.user_arn,
        policy_arn,
        &Store.detach_user_managed_policy/2,
        require_policy: true
      )
    else
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def detach_user_policy_strict(_user_name_or_arn, _policy_arn), do: {:error, :malformed}

  @doc "Attaches a local managed policy to a user as direct user identity policy."
  @spec attach_user_policy(String.t(), String.t()) :: :ok | {:error, term()}
  def attach_user_policy(user_name_or_arn, policy_arn)
      when is_binary(user_name_or_arn) and is_binary(policy_arn) do
    with {:ok, user} <- get_user(user_name_or_arn),
         :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, _policy} <- get_managed_policy(policy_arn) do
      attach_user_managed_policy_with_quota(user.user_arn, policy_arn)
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def attach_user_policy(_user_name_or_arn, _policy_arn), do: {:error, :malformed}

  @doc "Lists managed policies directly attached to a user."
  @spec list_attached_user_policies(String.t(), keyword()) :: [map()]
  def list_attached_user_policies(user_name_or_arn, opts \\ [])

  def list_attached_user_policies(user_name_or_arn, opts) when is_binary(user_name_or_arn) do
    path_prefix =
      opts
      |> Keyword.get(:path_prefix, "/")
      |> normalize_iam_text()

    with :ok <- validate_managed_policy_path(path_prefix),
         {:ok, user} <- get_user(user_name_or_arn) do
      user.user_arn
      |> Store.list_attached_user_managed_policies()
      |> Enum.flat_map(&attached_user_policy_listing/1)
      |> Enum.filter(&String.starts_with?(&1.path, path_prefix))
    else
      _ -> []
    end
  end

  def list_attached_user_policies(_user_name_or_arn, _opts), do: []

  @doc "Detaches a managed policy from a user. The operation is idempotent."
  @spec detach_user_policy(String.t(), String.t()) :: :ok | {:error, term()}
  def detach_user_policy(user_name_or_arn, policy_arn)
      when is_binary(user_name_or_arn) and is_binary(policy_arn) do
    with :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, user} <- get_user(user_name_or_arn) do
      detach_managed_policy_with_policy_lock(
        user.user_arn,
        policy_arn,
        &Store.detach_user_managed_policy/2
      )
    else
      :error -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def detach_user_policy(_user_name_or_arn, _policy_arn), do: {:error, :malformed}

  @doc "Attaches a local managed policy to a group using AWS Query strict semantics."
  @spec attach_group_policy_strict(String.t(), String.t()) :: :ok | {:error, term()}
  def attach_group_policy_strict(group_name_or_arn, policy_arn)
      when is_binary(group_name_or_arn) and is_binary(policy_arn) do
    with %Group{} = group <- fetch_group_record(group_name_or_arn),
         :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, _policy} <- get_managed_policy(policy_arn) do
      attach_group_managed_policy_with_quota(group.group_arn, policy_arn)
    else
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def attach_group_policy_strict(_group_name_or_arn, _policy_arn), do: {:error, :malformed}

  @doc "Lists managed policies directly attached to a group using AWS Query strict semantics."
  @spec list_attached_group_policies_strict(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_attached_group_policies_strict(group_name_or_arn, opts \\ [])

  def list_attached_group_policies_strict(group_name_or_arn, opts)
      when is_binary(group_name_or_arn) and is_list(opts) do
    path_prefix =
      opts
      |> Keyword.get(:path_prefix, "/")
      |> normalize_iam_text()

    with :ok <- validate_managed_policy_path(path_prefix),
         %Group{} = group <- fetch_group_record(group_name_or_arn) do
      policies =
        group.group_arn
        |> Store.list_attached_group_managed_policies()
        |> Enum.flat_map(&attached_group_policy_listing/1)
        |> Enum.filter(&String.starts_with?(&1.path, path_prefix))

      {:ok, policies}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_attached_group_policies_strict(_group_name_or_arn, _opts), do: {:error, :malformed}

  @doc "Detaches a managed policy from a group using AWS Query strict semantics."
  @spec detach_group_policy_strict(String.t(), String.t()) :: :ok | {:error, term()}
  def detach_group_policy_strict(group_name_or_arn, policy_arn)
      when is_binary(group_name_or_arn) and is_binary(policy_arn) do
    with %Group{} = group <- fetch_group_record(group_name_or_arn),
         :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, _policy} <- get_managed_policy(policy_arn) do
      detach_managed_policy_with_policy_lock(
        group.group_arn,
        policy_arn,
        &Store.detach_group_managed_policy/2,
        require_policy: true
      )
    else
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def detach_group_policy_strict(_group_name_or_arn, _policy_arn), do: {:error, :malformed}

  @doc "Attaches a local managed policy to a role using AWS Query strict semantics."
  @spec attach_role_policy_strict(String.t(), String.t()) :: :ok | {:error, term()}
  def attach_role_policy_strict(role_name_or_arn, policy_arn)
      when is_binary(role_name_or_arn) and is_binary(policy_arn) do
    with %Role{} = role <- fetch_role_record(role_name_or_arn),
         :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, _policy} <- get_managed_policy(policy_arn) do
      attach_role_managed_policy_with_quota(role.role_arn, policy_arn)
    else
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def attach_role_policy_strict(_role_name_or_arn, _policy_arn), do: {:error, :malformed}

  @doc "Lists managed policies directly attached to a role using AWS Query strict semantics."
  @spec list_attached_role_policies_strict(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_attached_role_policies_strict(role_name_or_arn, opts \\ [])

  def list_attached_role_policies_strict(role_name_or_arn, opts)
      when is_binary(role_name_or_arn) and is_list(opts) do
    path_prefix =
      opts
      |> Keyword.get(:path_prefix, "/")
      |> normalize_iam_text()

    with :ok <- validate_managed_policy_path(path_prefix),
         %Role{} = role <- fetch_role_record(role_name_or_arn) do
      policies =
        role.role_arn
        |> Store.list_attached_role_managed_policies()
        |> Enum.flat_map(&attached_role_policy_listing/1)
        |> Enum.filter(&String.starts_with?(&1.path, path_prefix))

      {:ok, policies}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_attached_role_policies_strict(_role_name_or_arn, _opts), do: {:error, :malformed}

  @doc "Detaches a managed policy from a role using AWS Query strict semantics."
  @spec detach_role_policy_strict(String.t(), String.t()) :: :ok | {:error, term()}
  def detach_role_policy_strict(role_name_or_arn, policy_arn)
      when is_binary(role_name_or_arn) and is_binary(policy_arn) do
    with %Role{} = role <- fetch_role_record(role_name_or_arn),
         :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, _policy} <- get_managed_policy(policy_arn) do
      detach_managed_policy_with_policy_lock(
        role.role_arn,
        policy_arn,
        &Store.detach_role_managed_policy/2,
        require_policy: true
      )
    else
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def detach_role_policy_strict(_role_name_or_arn, _policy_arn), do: {:error, :malformed}

  @doc "Attaches a local managed policy to a group so active members inherit it."
  @spec attach_group_policy(String.t(), String.t()) :: :ok | {:error, term()}
  def attach_group_policy(group_name_or_arn, policy_arn)
      when is_binary(group_name_or_arn) and is_binary(policy_arn) do
    with {:ok, group} <- get_group(group_name_or_arn),
         :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, _policy} <- get_managed_policy(policy_arn) do
      attach_group_managed_policy_with_quota(group.group_arn, policy_arn)
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def attach_group_policy(_group_name_or_arn, _policy_arn), do: {:error, :malformed}

  @doc "Lists managed policies directly attached to a group."
  @spec list_attached_group_policies(String.t(), keyword()) :: [map()]
  def list_attached_group_policies(group_name_or_arn, opts \\ [])

  def list_attached_group_policies(group_name_or_arn, opts) when is_binary(group_name_or_arn) do
    path_prefix =
      opts
      |> Keyword.get(:path_prefix, "/")
      |> normalize_iam_text()

    with :ok <- validate_managed_policy_path(path_prefix),
         {:ok, group} <- get_group(group_name_or_arn) do
      group.group_arn
      |> Store.list_attached_group_managed_policies()
      |> Enum.flat_map(&attached_group_policy_listing/1)
      |> Enum.filter(&String.starts_with?(&1.path, path_prefix))
    else
      _ -> []
    end
  end

  def list_attached_group_policies(_group_name_or_arn, _opts), do: []

  @doc "Detaches a managed policy from a group. The operation is idempotent."
  @spec detach_group_policy(String.t(), String.t()) :: :ok | {:error, term()}
  def detach_group_policy(group_name_or_arn, policy_arn)
      when is_binary(group_name_or_arn) and is_binary(policy_arn) do
    with :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, group} <- get_group(group_name_or_arn) do
      detach_managed_policy_with_policy_lock(
        group.group_arn,
        policy_arn,
        &Store.detach_group_managed_policy/2
      )
    else
      :error -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def detach_group_policy(_group_name_or_arn, _policy_arn), do: {:error, :malformed}

  @doc "Attaches a local managed policy to a role as role identity policy."
  @spec attach_role_policy(String.t(), String.t()) :: :ok | {:error, term()}
  def attach_role_policy(role_arn, policy_arn)
      when is_binary(role_arn) and is_binary(policy_arn) do
    with {:ok, _role} <- get_role_by_arn(role_arn),
         :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, _policy} <- get_managed_policy(policy_arn) do
      attach_role_managed_policy_with_quota(role_arn, policy_arn)
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def attach_role_policy(_role_arn, _policy_arn), do: {:error, :malformed}

  @doc "Lists managed policies attached to a role."
  @spec list_attached_role_policies(String.t(), keyword()) :: [map()]
  def list_attached_role_policies(role_arn, opts \\ [])

  def list_attached_role_policies(role_arn, opts) when is_binary(role_arn) do
    path_prefix =
      opts
      |> Keyword.get(:path_prefix, "/")
      |> normalize_iam_text()

    if validate_managed_policy_path(path_prefix) == :ok do
      role_arn
      |> Store.list_attached_role_managed_policies()
      |> Enum.flat_map(&attached_role_policy_listing/1)
      |> Enum.filter(&String.starts_with?(&1.path, path_prefix))
    else
      []
    end
  end

  def list_attached_role_policies(_role_arn, _opts), do: []

  @doc "Detaches a managed policy from a role. The operation is idempotent."
  @spec detach_role_policy(String.t(), String.t()) :: :ok | {:error, term()}
  def detach_role_policy(role_arn, policy_arn)
      when is_binary(role_arn) and is_binary(policy_arn) do
    with :ok <- validate_managed_policy_arn(policy_arn) do
      detach_managed_policy_with_policy_lock(
        role_arn,
        policy_arn,
        &Store.detach_role_managed_policy/2
      )
    end
  end

  def detach_role_policy(_role_arn, _policy_arn), do: {:error, :malformed}

  @doc "Returns the single-account root principal ARN used by maxio IAM."
  @spec root_principal_arn() :: String.t()
  def root_principal_arn, do: @root_principal_arn

  @doc "Returns the local single-account IAM role ARN for a role name."
  @spec role_arn(String.t()) :: String.t()
  def role_arn(role_name), do: "arn:aws:iam:::role/#{role_name}"

  @doc "Returns the local single-account IAM instance profile ARN for a root-path profile name."
  @spec instance_profile_arn(String.t()) :: String.t()
  def instance_profile_arn(instance_profile_name),
    do: instance_profile_arn("/", instance_profile_name)

  @doc "Returns the local single-account IAM instance profile ARN for a path and profile name."
  @spec instance_profile_arn(String.t(), String.t()) :: String.t()
  def instance_profile_arn(path, instance_profile_name),
    do:
      "arn:aws:iam:::instance-profile/#{instance_profile_resource_path(path, instance_profile_name)}"

  @doc "Returns the local single-account IAM server certificate ARN for a root-path certificate name."
  @spec server_certificate_arn(String.t()) :: String.t()
  def server_certificate_arn(server_certificate_name),
    do: server_certificate_arn("/", server_certificate_name)

  @doc "Returns the local single-account IAM server certificate ARN for a path and certificate name."
  @spec server_certificate_arn(String.t(), String.t()) :: String.t()
  def server_certificate_arn(path, server_certificate_name),
    do:
      "arn:aws:iam:::server-certificate/#{server_certificate_resource_path(path, server_certificate_name)}"

  @doc "Creates an IAM role with an attached trust policy."
  @spec create_role(keyword()) :: {:ok, map()} | {:error, term()}
  def create_role(opts \\ []) do
    role_name = opts |> Keyword.get(:role_name, Keyword.get(opts, :name)) |> normalize_iam_text()
    role_arn = opts |> Keyword.get(:role_arn, default_role_arn(role_name)) |> normalize_iam_text()

    with :ok <- reject_role_name_case_insensitive_duplicate(role_name),
         {:ok, trust_policy} <-
           normalize_trust_policy(
             Keyword.get(opts, :trust_policy, Keyword.get(opts, :trust_policy_document))
           ),
         permissions_boundary_policy_arn = permissions_boundary_policy_arn_from_opts(opts),
         :ok <- ensure_permissions_boundary_policy(permissions_boundary_policy_arn) do
      attrs = %{
        role_name: role_name,
        role_arn: role_arn,
        description: normalize_role_description(Keyword.get(opts, :description, "")),
        trust_policy: trust_policy,
        max_session_duration_seconds: Keyword.get(opts, :max_session_duration_seconds, 3600),
        tags: opts |> Keyword.get(:tags, %{}) |> normalize_tags(),
        permissions_boundary_policy_arn: permissions_boundary_policy_arn
      }

      case %Role{} |> Role.changeset(attrs) |> Repo.insert() do
        {:ok, role} ->
          Notify.broadcast({:iam_changed, role.role_arn})
          {:ok, public_role(role)}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc "Fetches an IAM role by ARN."
  @spec get_role_by_arn(String.t()) :: {:ok, map()} | :error
  def get_role_by_arn(role_arn) when is_binary(role_arn) do
    case Repo.get_by(Role, role_arn: role_arn) do
      %Role{} = role -> {:ok, public_role(role)}
      nil -> :error
    end
  end

  def get_role_by_arn(_role_arn), do: :error

  @doc "Fetches an IAM role by role name or ARN."
  @spec get_role(String.t()) :: {:ok, map()} | :error
  def get_role(role_name_or_arn) when is_binary(role_name_or_arn) do
    case fetch_role_record(role_name_or_arn) do
      %Role{} = role -> {:ok, public_role(role)}
      nil -> :error
    end
  end

  def get_role(_role_name_or_arn), do: :error

  @doc "Updates an IAM role trust policy using strict Query API semantics."
  @spec update_assume_role_policy_strict(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def update_assume_role_policy_strict(role_name_or_arn, policy_document)
      when is_binary(role_name_or_arn) do
    with {:ok, trust_policy} <- normalize_trust_policy(policy_document) do
      update_role(role_name_or_arn, fn role ->
        Role.changeset(role, %{trust_policy: trust_policy})
      end)
    end
  end

  def update_assume_role_policy_strict(_role_name_or_arn, _policy_document),
    do: {:error, :malformed}

  @doc "Updates IAM role metadata using strict Query API semantics."
  @spec update_role_strict(String.t(), integer() | nil | map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_role_strict(role_name_or_arn, max_session_duration_seconds)
      when is_integer(max_session_duration_seconds) or is_nil(max_session_duration_seconds) do
    update_role_strict(role_name_or_arn, %{
      max_session_duration_seconds: max_session_duration_seconds
    })
  end

  def update_role_strict(role_name_or_arn, attrs)
      when is_binary(role_name_or_arn) and (is_map(attrs) or is_list(attrs)) do
    attrs =
      attrs
      |> Map.new()
      |> role_update_attrs()

    if attrs == %{} do
      case fetch_role_record(role_name_or_arn) do
        %Role{} = role -> {:ok, public_role(role)}
        nil -> {:error, :not_found}
      end
    else
      update_role(role_name_or_arn, fn role ->
        Role.changeset(role, attrs)
      end)
    end
  end

  def update_role_strict(_role_name_or_arn, _attrs), do: {:error, :malformed}

  @doc "Adds or replaces a managed policy permissions boundary on an IAM role."
  @spec put_role_permissions_boundary_strict(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def put_role_permissions_boundary_strict(role_name_or_arn, policy_arn)
      when is_binary(role_name_or_arn) and is_binary(policy_arn) do
    with :ok <- ensure_permissions_boundary_policy(policy_arn),
         %Role{} = role <- fetch_role_record(role_name_or_arn),
         {:ok, updated} <-
           role
           |> Role.changeset(%{permissions_boundary_policy_arn: policy_arn})
           |> Repo.update() do
      broadcast_permissions_boundary_change(updated.role_arn)
      {:ok, public_role(updated)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def put_role_permissions_boundary_strict(_role_name_or_arn, _policy_arn),
    do: {:error, :malformed}

  @doc "Removes the managed policy permissions boundary from an IAM role."
  @spec delete_role_permissions_boundary_strict(String.t()) :: {:ok, map()} | {:error, term()}
  def delete_role_permissions_boundary_strict(role_name_or_arn)
      when is_binary(role_name_or_arn) do
    case fetch_role_record(role_name_or_arn) do
      %Role{} = role ->
        case role
             |> Role.changeset(%{permissions_boundary_policy_arn: nil})
             |> Repo.update() do
          {:ok, updated} ->
            broadcast_permissions_boundary_change(updated.role_arn)
            {:ok, public_role(updated)}

          {:error, changeset} ->
            {:error, changeset}
        end

      nil ->
        {:error, :not_found}
    end
  end

  def delete_role_permissions_boundary_strict(_role_name_or_arn), do: {:error, :malformed}

  @doc "Lists IAM roles without expanding attached identity policies."
  @spec list_roles() :: [map()]
  def list_roles do
    Role
    |> order_by([r], asc: r.role_name)
    |> Repo.all()
    |> Enum.map(&public_role/1)
  end

  @doc "Deletes an IAM role. Attached principal policies are left untouched."
  @spec delete_role(String.t()) :: :ok
  def delete_role(role_arn) when is_binary(role_arn) do
    Repo.delete_all(from r in Role, where: r.role_arn == ^role_arn)
    Notify.broadcast({:iam_changed, role_arn})
    :ok
  end

  def delete_role(_role_arn), do: :ok

  @doc "Deletes an IAM role only when no subordinate IAM resources remain."
  @spec delete_role_strict(String.t()) :: {:ok, map()} | {:error, term()}
  def delete_role_strict(role_name_or_arn) when is_binary(role_name_or_arn) do
    case fetch_role_record(role_name_or_arn) do
      %Role{} = role ->
        case role_delete_blockers(role) do
          [] ->
            Repo.delete!(role)
            Notify.broadcast({:iam_changed, role.role_arn})
            {:ok, public_role(role)}

          blockers ->
            {:error, {:role_delete_conflict, blockers}}
        end

      nil ->
        {:error, :not_found}
    end
  end

  def delete_role_strict(_role_name_or_arn), do: {:error, :malformed}

  @doc "Adds or replaces tags on an IAM role."
  @spec tag_role(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def tag_role(role_name_or_arn, tags) when is_binary(role_name_or_arn) and is_map(tags) do
    tags = normalize_tags(tags)

    update_role(role_name_or_arn, fn role ->
      Role.changeset(role, %{tags: merge_case_insensitive_tags(role.tags || %{}, tags)})
    end)
  end

  def tag_role(_role_name_or_arn, _tags), do: {:error, :malformed}

  @doc "Removes tags from an IAM role. Missing keys are ignored."
  @spec untag_role(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def untag_role(role_name_or_arn, tag_keys)
      when is_binary(role_name_or_arn) and is_list(tag_keys) do
    tag_keys = Enum.map(tag_keys, &to_string/1)

    update_role(role_name_or_arn, fn role ->
      Role.changeset(role, %{tags: drop_case_insensitive_tags(role.tags || %{}, tag_keys)})
    end)
  end

  def untag_role(_role_name_or_arn, _tag_keys), do: {:error, :malformed}

  @doc "Fetches an IAM role for Query API tag listing semantics."
  @spec list_role_tags_strict(String.t()) :: {:ok, map()} | {:error, term()}
  def list_role_tags_strict(role_name_or_arn) when is_binary(role_name_or_arn) do
    case fetch_role_record(role_name_or_arn) do
      %Role{} = role -> {:ok, public_role(role)}
      nil -> {:error, :not_found}
    end
  end

  def list_role_tags_strict(_role_name_or_arn), do: {:error, :malformed}

  @doc "Creates a local IAM instance profile."
  @spec create_instance_profile(keyword()) :: {:ok, map()} | {:error, term()}
  def create_instance_profile(opts \\ []) do
    name =
      opts
      |> Keyword.get(:instance_profile_name, Keyword.get(opts, :name))
      |> normalize_iam_text()

    path = opts |> Keyword.get(:path, "/") |> normalize_iam_text()
    arn = opts |> Keyword.get(:instance_profile_arn, default_instance_profile_arn(path, name))

    with :ok <- reject_instance_profile_name_case_insensitive_duplicate(name),
         :ok <- ensure_instance_profile_quota() do
      attrs = %{
        instance_profile_name: name,
        instance_profile_arn: normalize_iam_text(arn),
        path: path,
        tags: opts |> Keyword.get(:tags, %{}) |> normalize_tags()
      }

      case %InstanceProfile{} |> InstanceProfile.changeset(attrs) |> Repo.insert() do
        {:ok, profile} ->
          Notify.broadcast({:iam_changed, profile.instance_profile_arn})
          {:ok, public_instance_profile(profile)}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc "Fetches an IAM instance profile by name or ARN."
  @spec get_instance_profile(String.t()) :: {:ok, map()} | {:error, term()}
  def get_instance_profile(instance_profile_name_or_arn)
      when is_binary(instance_profile_name_or_arn) do
    case fetch_instance_profile_record(instance_profile_name_or_arn) do
      %InstanceProfile{} = profile -> {:ok, public_instance_profile(profile)}
      nil -> {:error, :not_found}
    end
  end

  def get_instance_profile(_instance_profile_name_or_arn), do: {:error, :malformed}

  @doc "Lists IAM instance profiles without filtering."
  @spec list_instance_profiles() :: [map()]
  def list_instance_profiles do
    InstanceProfile
    |> order_by([p], asc: p.instance_profile_name)
    |> Repo.all()
    |> Enum.map(&public_instance_profile/1)
  end

  @doc "Deletes an IAM instance profile only when no role remains attached."
  @spec delete_instance_profile_strict(String.t()) :: {:ok, map()} | {:error, term()}
  def delete_instance_profile_strict(instance_profile_name_or_arn)
      when is_binary(instance_profile_name_or_arn) do
    Repo.transaction(fn ->
      case fetch_instance_profile_record_for_update(instance_profile_name_or_arn) do
        %InstanceProfile{role_arn: role_arn} when is_binary(role_arn) and role_arn != "" ->
          Repo.rollback({:instance_profile_delete_conflict, [:role]})

        %InstanceProfile{} = profile ->
          case Repo.delete(profile) do
            {:ok, deleted} -> deleted
            {:error, reason} -> Repo.rollback(reason)
          end

        nil ->
          Repo.rollback(:not_found)
      end
    end)
    |> instance_profile_transaction_result()
  end

  def delete_instance_profile_strict(_instance_profile_name_or_arn), do: {:error, :malformed}

  @doc "Adds a role to an IAM instance profile. Each profile can hold at most one role."
  @spec add_role_to_instance_profile_strict(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def add_role_to_instance_profile_strict(instance_profile_name_or_arn, role_name_or_arn)
      when is_binary(instance_profile_name_or_arn) and is_binary(role_name_or_arn) do
    Repo.transaction(fn ->
      with %InstanceProfile{} = profile <-
             fetch_instance_profile_record_for_update(instance_profile_name_or_arn),
           %Role{} = role <- fetch_role_record(role_name_or_arn),
           :ok <- ensure_instance_profile_role_slot(profile, role.role_arn),
           {:ok, updated} <-
             profile
             |> InstanceProfile.changeset(%{role_arn: role.role_arn})
             |> Repo.update() do
        updated
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> instance_profile_transaction_result()
  end

  def add_role_to_instance_profile_strict(_instance_profile_name_or_arn, _role_name_or_arn),
    do: {:error, :malformed}

  @doc "Removes a role from an IAM instance profile."
  @spec remove_role_from_instance_profile_strict(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def remove_role_from_instance_profile_strict(instance_profile_name_or_arn, role_name_or_arn)
      when is_binary(instance_profile_name_or_arn) and is_binary(role_name_or_arn) do
    Repo.transaction(fn ->
      with %InstanceProfile{} = profile <-
             fetch_instance_profile_record_for_update(instance_profile_name_or_arn),
           %Role{} = role <- fetch_role_record(role_name_or_arn),
           true <- profile.role_arn == role.role_arn,
           {:ok, updated} <-
             profile
             |> InstanceProfile.changeset(%{role_arn: nil})
             |> Repo.update() do
        updated
      else
        nil -> Repo.rollback(:not_found)
        false -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> instance_profile_transaction_result()
  end

  def remove_role_from_instance_profile_strict(_instance_profile_name_or_arn, _role_name_or_arn),
    do: {:error, :malformed}

  @doc "Lists IAM instance profiles associated with a role."
  @spec list_instance_profiles_for_role_strict(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_instance_profiles_for_role_strict(role_name_or_arn) when is_binary(role_name_or_arn) do
    case fetch_role_record(role_name_or_arn) do
      %Role{} = role ->
        profiles =
          InstanceProfile
          |> where([p], p.role_arn == ^role.role_arn)
          |> order_by([p], asc: p.instance_profile_name)
          |> Repo.all()
          |> Enum.map(&public_instance_profile/1)

        {:ok, profiles}

      nil ->
        {:error, :not_found}
    end
  end

  def list_instance_profiles_for_role_strict(_role_name_or_arn), do: {:error, :malformed}

  @doc "Adds or replaces tags on an IAM instance profile."
  @spec tag_instance_profile(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def tag_instance_profile(instance_profile_name_or_arn, tags)
      when is_binary(instance_profile_name_or_arn) and is_map(tags) do
    tags = normalize_tags(tags)

    update_instance_profile(instance_profile_name_or_arn, fn profile ->
      InstanceProfile.changeset(profile, %{
        tags: merge_case_sensitive_tags(profile.tags || %{}, tags)
      })
    end)
  end

  def tag_instance_profile(_instance_profile_name_or_arn, _tags), do: {:error, :malformed}

  @doc "Removes tags from an IAM instance profile. Missing keys are ignored."
  @spec untag_instance_profile(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def untag_instance_profile(instance_profile_name_or_arn, tag_keys)
      when is_binary(instance_profile_name_or_arn) and is_list(tag_keys) do
    tag_keys = Enum.map(tag_keys, &to_string/1)

    update_instance_profile(instance_profile_name_or_arn, fn profile ->
      InstanceProfile.changeset(profile, %{
        tags: drop_case_sensitive_tags(profile.tags || %{}, tag_keys)
      })
    end)
  end

  def untag_instance_profile(_instance_profile_name_or_arn, _tag_keys),
    do: {:error, :malformed}

  @doc "Fetches an IAM instance profile for Query API tag listing semantics."
  @spec list_instance_profile_tags_strict(String.t()) :: {:ok, map()} | {:error, term()}
  def list_instance_profile_tags_strict(instance_profile_name_or_arn)
      when is_binary(instance_profile_name_or_arn) do
    case fetch_instance_profile_record(instance_profile_name_or_arn) do
      %InstanceProfile{} = profile -> {:ok, public_instance_profile(profile)}
      nil -> {:error, :not_found}
    end
  end

  def list_instance_profile_tags_strict(_instance_profile_name_or_arn),
    do: {:error, :malformed}

  @doc "Uploads a local IAM server certificate after validating the certificate/private-key pair."
  @spec upload_server_certificate(keyword()) :: {:ok, map()} | {:error, term()}
  def upload_server_certificate(opts \\ []) do
    name =
      opts
      |> Keyword.get(:server_certificate_name, Keyword.get(opts, :name))
      |> normalize_iam_text()

    path = opts |> Keyword.get(:path, "/") |> normalize_iam_text()
    arn = opts |> Keyword.get(:server_certificate_arn, default_server_certificate_arn(path, name))

    with :ok <- reject_server_certificate_name_case_insensitive_duplicate(name),
         :ok <- ensure_server_certificate_quota() do
      attrs = %{
        server_certificate_name: name,
        server_certificate_arn: normalize_iam_text(arn),
        path: path,
        certificate_body: Keyword.get(opts, :certificate_body),
        private_key: Keyword.get(opts, :private_key),
        certificate_chain: Keyword.get(opts, :certificate_chain),
        tags: opts |> Keyword.get(:tags, %{}) |> normalize_tags()
      }

      case %ServerCertificate{} |> ServerCertificate.upload_changeset(attrs) |> Repo.insert() do
        {:ok, certificate} ->
          Notify.broadcast({:iam_changed, certificate.server_certificate_arn})
          {:ok, public_server_certificate(certificate)}

        {:error, changeset} ->
          {:error, server_certificate_changeset_error(changeset)}
      end
    end
  end

  @doc "Fetches an IAM server certificate by name or ARN."
  @spec get_server_certificate(String.t()) :: {:ok, map()} | {:error, term()}
  def get_server_certificate(server_certificate_name_or_arn)
      when is_binary(server_certificate_name_or_arn) do
    case fetch_server_certificate_record(server_certificate_name_or_arn) do
      %ServerCertificate{} = certificate -> {:ok, public_server_certificate(certificate)}
      nil -> {:error, :not_found}
    end
  end

  def get_server_certificate(_server_certificate_name_or_arn), do: {:error, :malformed}

  @doc "Lists IAM server certificates without filtering."
  @spec list_server_certificates() :: [map()]
  def list_server_certificates do
    ServerCertificate
    |> order_by([c], asc: c.path, asc: c.server_certificate_name)
    |> Repo.all()
    |> Enum.map(&public_server_certificate/1)
  end

  @doc "Deletes an IAM server certificate."
  @spec delete_server_certificate_strict(String.t()) :: {:ok, map()} | {:error, term()}
  def delete_server_certificate_strict(server_certificate_name_or_arn)
      when is_binary(server_certificate_name_or_arn) do
    Repo.transaction(fn ->
      case fetch_server_certificate_record_for_update(server_certificate_name_or_arn) do
        %ServerCertificate{} = certificate ->
          case Repo.delete(certificate) do
            {:ok, deleted} -> deleted
            {:error, reason} -> Repo.rollback(reason)
          end

        nil ->
          Repo.rollback(:not_found)
      end
    end)
    |> server_certificate_transaction_result()
  end

  def delete_server_certificate_strict(_server_certificate_name_or_arn),
    do: {:error, :malformed}

  @doc "Updates IAM server certificate name and/or path."
  @spec update_server_certificate_strict(String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_server_certificate_strict(server_certificate_name_or_arn, attrs)
      when is_binary(server_certificate_name_or_arn) and (is_map(attrs) or is_list(attrs)) do
    attrs = attrs |> Map.new() |> server_certificate_update_attrs()

    if map_size(attrs) == 0 do
      {:error, :server_certificate_update_empty}
    else
      Repo.transaction(fn ->
        case fetch_server_certificate_record_for_update(server_certificate_name_or_arn) do
          %ServerCertificate{} = certificate ->
            name = Map.get(attrs, :server_certificate_name, certificate.server_certificate_name)
            path = Map.get(attrs, :path, certificate.path || "/")

            with :ok <- reject_server_certificate_name_update_duplicate(certificate, name),
                 {:ok, updated} <-
                   certificate
                   |> ServerCertificate.metadata_changeset(
                     Map.merge(attrs, %{
                       server_certificate_arn: server_certificate_arn(path, name)
                     })
                   )
                   |> Repo.update() do
              updated
            else
              {:error, reason} -> Repo.rollback(reason)
            end

          nil ->
            Repo.rollback(:not_found)
        end
      end)
      |> server_certificate_transaction_result()
    end
  end

  def update_server_certificate_strict(_server_certificate_name_or_arn, _attrs),
    do: {:error, :malformed}

  @doc "Adds or replaces tags on an IAM server certificate."
  @spec tag_server_certificate(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def tag_server_certificate(server_certificate_name_or_arn, tags)
      when is_binary(server_certificate_name_or_arn) and is_map(tags) do
    tags = normalize_tags(tags)

    update_server_certificate(server_certificate_name_or_arn, fn certificate ->
      ServerCertificate.metadata_changeset(certificate, %{
        tags: merge_case_sensitive_tags(certificate.tags || %{}, tags)
      })
    end)
  end

  def tag_server_certificate(_server_certificate_name_or_arn, _tags),
    do: {:error, :malformed}

  @doc "Removes tags from an IAM server certificate. Missing keys are ignored."
  @spec untag_server_certificate(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def untag_server_certificate(server_certificate_name_or_arn, tag_keys)
      when is_binary(server_certificate_name_or_arn) and is_list(tag_keys) do
    tag_keys = Enum.map(tag_keys, &to_string/1)

    update_server_certificate(server_certificate_name_or_arn, fn certificate ->
      ServerCertificate.metadata_changeset(certificate, %{
        tags: drop_case_sensitive_tags(certificate.tags || %{}, tag_keys)
      })
    end)
  end

  def untag_server_certificate(_server_certificate_name_or_arn, _tag_keys),
    do: {:error, :malformed}

  @doc "Fetches an IAM server certificate for Query API tag listing semantics."
  @spec list_server_certificate_tags_strict(String.t()) :: {:ok, map()} | {:error, term()}
  def list_server_certificate_tags_strict(server_certificate_name_or_arn)
      when is_binary(server_certificate_name_or_arn) do
    case fetch_server_certificate_record(server_certificate_name_or_arn) do
      %ServerCertificate{} = certificate -> {:ok, public_server_certificate(certificate)}
      nil -> {:error, :not_found}
    end
  end

  def list_server_certificate_tags_strict(_server_certificate_name_or_arn),
    do: {:error, :malformed}

  @doc "Returns the local single-account OIDC provider ARN derived from a HTTPS issuer URL."
  @spec oidc_provider_arn(String.t()) :: {:ok, String.t()} | {:error, term()}
  def oidc_provider_arn(issuer_url) when is_binary(issuer_url) do
    issuer_url
    |> normalize_oidc_issuer_url()
    |> Maxio.STS.WebIdentity.oidc_provider_arn()
  end

  def oidc_provider_arn(_issuer_url), do: {:error, :invalid_provider_issuer}

  @doc """
  Creates a local IAM OIDC provider.

  Query API creation performs bounded discovery and persists the discovered JWKS
  snapshot. Internal callers may pass `:jwks` directly for deterministic tests or
  offline bootstrap.
  """
  @spec create_oidc_provider(keyword()) :: {:ok, map()} | {:error, term()}
  def create_oidc_provider(opts \\ []) do
    issuer_url =
      opts
      |> Keyword.get(:issuer_url, Keyword.get(opts, :url))
      |> normalize_iam_text()
      |> normalize_oidc_issuer_url()

    client_ids = normalize_oidc_string_list(Keyword.get(opts, :client_ids, []))
    thumbprints = normalize_oidc_string_list(Keyword.get(opts, :thumbprints, []))

    with {:ok, discovery} <- oidc_provider_discovery(issuer_url, opts),
         {:ok, thumbprints} <- effective_oidc_thumbprints(thumbprints, discovery) do
      attrs = %{
        issuer_url: issuer_url,
        client_ids: client_ids,
        thumbprints: thumbprints,
        jwks: discovery.jwks,
        jwks_fetched_at: discovery.jwks_fetched_at,
        discovery_document: discovery.discovery_document,
        status: Keyword.get(opts, :status, "active"),
        tags: normalize_tags(Keyword.get(opts, :tags, %{}))
      }

      %OIDCProvider{}
      |> OIDCProvider.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, provider} ->
          Notify.broadcast({:iam_changed, provider.provider_arn})
          {:ok, public_oidc_provider(provider)}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc "Fetches a local IAM OIDC provider by ARN or issuer URL."
  @spec get_oidc_provider(String.t()) :: {:ok, map()} | :error | {:error, term()}
  def get_oidc_provider(provider_arn_or_url) when is_binary(provider_arn_or_url) do
    case fetch_oidc_provider(provider_arn_or_url) do
      {:ok, provider} -> {:ok, public_oidc_provider(provider)}
      :error -> :error
      {:error, reason} -> {:error, reason}
    end
  end

  def get_oidc_provider(_provider_arn_or_url), do: {:error, :malformed}

  @doc "Lists local IAM OIDC providers."
  @spec list_oidc_providers(keyword()) :: [map()]
  def list_oidc_providers(_opts \\ []) do
    OIDCProvider
    |> order_by([p], asc: p.issuer_host_path)
    |> Repo.all()
    |> Enum.map(&public_oidc_provider/1)
  end

  @doc "Deletes a local IAM OIDC provider."
  @spec delete_oidc_provider(String.t()) :: :ok | {:error, term()}
  def delete_oidc_provider(provider_arn_or_url) when is_binary(provider_arn_or_url) do
    case fetch_oidc_provider(provider_arn_or_url) do
      {:ok, provider} ->
        Repo.delete!(provider)
        Notify.broadcast({:iam_changed, provider.provider_arn})
        :ok

      :error ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def delete_oidc_provider(_provider_arn_or_url), do: {:error, :malformed}

  @doc "Adds a client id/audience to an OIDC provider. Existing values are kept idempotently."
  @spec add_oidc_provider_client_id(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def add_oidc_provider_client_id(provider_arn_or_url, client_id)
      when is_binary(provider_arn_or_url) and is_binary(client_id) do
    update_oidc_provider(provider_arn_or_url, fn provider ->
      client_ids =
        provider.client_ids
        |> List.wrap()
        |> Kernel.++([String.trim(client_id)])
        |> Enum.uniq()

      OIDCProvider.changeset(provider, %{client_ids: client_ids})
    end)
  end

  def add_oidc_provider_client_id(_provider_arn_or_url, _client_id), do: {:error, :malformed}

  @doc "Removes a client id/audience from an OIDC provider. Removing the last id is rejected."
  @spec remove_oidc_provider_client_id(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def remove_oidc_provider_client_id(provider_arn_or_url, client_id)
      when is_binary(provider_arn_or_url) and is_binary(client_id) do
    update_oidc_provider(provider_arn_or_url, fn provider ->
      client_ids =
        provider.client_ids
        |> List.wrap()
        |> Enum.reject(&(&1 == String.trim(client_id)))

      OIDCProvider.changeset(provider, %{client_ids: client_ids})
    end)
  end

  def remove_oidc_provider_client_id(_provider_arn_or_url, _client_id), do: {:error, :malformed}

  @doc "Replaces an OIDC provider thumbprint list."
  @spec update_oidc_provider_thumbprints(String.t(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def update_oidc_provider_thumbprints(provider_arn_or_url, thumbprints)
      when is_binary(provider_arn_or_url) do
    thumbprints = normalize_oidc_string_list(thumbprints)

    update_oidc_provider(provider_arn_or_url, fn provider ->
      OIDCProvider.changeset(provider, %{thumbprints: thumbprints})
    end)
  end

  def update_oidc_provider_thumbprints(_provider_arn_or_url, _thumbprints),
    do: {:error, :malformed}

  @doc "Adds or replaces tags on an OIDC provider."
  @spec tag_oidc_provider(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def tag_oidc_provider(provider_arn_or_url, tags)
      when is_binary(provider_arn_or_url) and is_map(tags) do
    tags = normalize_tags(tags)

    update_oidc_provider(provider_arn_or_url, fn provider ->
      existing_tags = normalize_tags(provider.tags || %{})
      OIDCProvider.changeset(provider, %{tags: Map.merge(existing_tags, tags)})
    end)
  end

  def tag_oidc_provider(_provider_arn_or_url, _tags), do: {:error, :malformed}

  @doc "Removes tags from an OIDC provider. Missing keys are ignored."
  @spec untag_oidc_provider(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def untag_oidc_provider(provider_arn_or_url, tag_keys)
      when is_binary(provider_arn_or_url) and is_list(tag_keys) do
    tag_keys =
      tag_keys
      |> Enum.map(&to_string/1)

    update_oidc_provider(provider_arn_or_url, fn provider ->
      tags =
        provider.tags
        |> normalize_tags()
        |> Map.drop(tag_keys)

      OIDCProvider.changeset(provider, %{tags: tags})
    end)
  end

  def untag_oidc_provider(_provider_arn_or_url, _tag_keys), do: {:error, :malformed}

  @doc "Updates an OIDC provider status."
  @spec update_oidc_provider_status(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_oidc_provider_status(provider_arn_or_url, status)
      when is_binary(provider_arn_or_url) and is_binary(status) do
    status = normalize_iam_text(status)

    update_oidc_provider(provider_arn_or_url, fn provider ->
      OIDCProvider.changeset(provider, %{status: status})
    end)
  end

  def update_oidc_provider_status(_provider_arn_or_url, _status), do: {:error, :malformed}

  @doc "Replaces the persisted JWKS snapshot for an OIDC provider."
  @spec set_oidc_provider_jwks(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def set_oidc_provider_jwks(provider_arn_or_url, jwks, opts \\ [])

  def set_oidc_provider_jwks(provider_arn_or_url, %{} = jwks, opts)
      when is_binary(provider_arn_or_url) do
    update_oidc_provider(provider_arn_or_url, fn provider ->
      OIDCProvider.changeset(provider, %{
        jwks: jwks,
        jwks_fetched_at: Keyword.get(opts, :jwks_fetched_at, utc_now())
      })
    end)
  end

  def set_oidc_provider_jwks(_provider_arn_or_url, _jwks, _opts), do: {:error, :malformed}

  @doc """
  Refreshes a single persisted IAM OIDC provider JWKS snapshot through discovery.

  Runs as a dry-run by default. Pass `dry_run: false` only from an explicit
  operator-confirmed path.
  """
  @spec refresh_oidc_provider_jwks(String.t(), keyword()) ::
          {:ok, OIDCProviderRefresh.report()} | {:error, OIDCProviderRefresh.report()}
  def refresh_oidc_provider_jwks(provider_arn_or_url, opts \\ []),
    do: OIDCProviderRefresh.refresh(provider_arn_or_url, opts)

  @doc """
  Refreshes due persisted IAM OIDC provider JWKS snapshots through discovery.

  Scheduled runs use this same path and remain dry-runs unless their scheduler
  config explicitly enables confirmed writes.
  """
  @spec refresh_oidc_provider_jwks_if_due(keyword()) ::
          {:ok, OIDCProviderRefresh.report()} | {:error, OIDCProviderRefresh.report()}
  def refresh_oidc_provider_jwks_if_due(opts \\ []), do: OIDCProviderRefresh.refresh_all(opts)

  @doc false
  @spec web_identity_providers_for_issuer(String.t()) :: [map()]
  def web_identity_providers_for_issuer(issuer_url) when is_binary(issuer_url) do
    case web_identity_provider_lookup_for_issuer(issuer_url) do
      {:ok, providers} -> providers
      _other -> []
    end
  end

  def web_identity_providers_for_issuer(_issuer_url), do: []

  @doc false
  @spec web_identity_provider_lookup_for_issuer(String.t()) ::
          {:ok, [map()]} | {:error, :identity_provider_disabled} | :error
  def web_identity_provider_lookup_for_issuer(issuer_url) when is_binary(issuer_url) do
    issuer_url = normalize_oidc_issuer_url(issuer_url)

    case Maxio.STS.WebIdentity.issuer_host_path(issuer_url) do
      {:ok, issuer_host_path} ->
        providers =
          OIDCProvider
          |> where([p], p.issuer_host_path == ^issuer_host_path)
          |> Repo.all()

        active_providers = Enum.filter(providers, &(&1.status == "active"))

        cond do
          active_providers != [] ->
            {:ok, Enum.map(active_providers, &web_identity_provider_projection/1)}

          providers != [] ->
            {:error, :identity_provider_disabled}

          true ->
            :error
        end

      {:error, _reason} ->
        :error
    end
  end

  def web_identity_provider_lookup_for_issuer(_issuer_url), do: :error

  @doc """
  Enrolls a pending local TOTP MFA device.

  The returned `secret_base32` and `otpauth_uri` are intentionally returned only
  by this creation call. List and verify paths never expose the TOTP seed.
  """
  @spec create_mfa_device(keyword()) :: {:ok, map()} | {:error, term()}
  def create_mfa_device(opts \\ []) do
    principal_arn =
      opts
      |> Keyword.get(:principal_arn, @root_principal_arn)
      |> normalize_mfa_text()

    device_name =
      opts
      |> Keyword.get(:device_name, Keyword.get(opts, :name, @default_mfa_device_name))
      |> normalize_mfa_text()

    serial =
      opts
      |> Keyword.get(:serial, default_mfa_serial(device_name))
      |> normalize_mfa_text()

    secret_base32 =
      opts
      |> Keyword.get(:secret_base32, TOTP.generate_secret())
      |> normalize_mfa_text()

    with {:ok, secret_envelope} <- MFASecret.wrap(secret_base32, serial) do
      attrs = %{
        principal_arn: principal_arn,
        principal_type: principal_type_for(principal_arn),
        serial: serial,
        device_name: device_name,
        kind: "totp",
        status: "pending",
        secret_envelope: secret_envelope,
        algorithm: "sha1",
        digits: 6,
        period_seconds: 30,
        drift_steps: 1
      }

      with_mfa_user_identities([principal_arn], fn ->
        case %MFADevice{} |> MFADevice.changeset(attrs) |> Repo.insert() do
          {:ok, device} ->
            {:ok,
             %{
               device: public_mfa_device(device),
               serial: device.serial,
               secret_base32: secret_base32,
               otpauth_uri:
                 TOTP.verification_uri(secret_base32,
                   issuer: "maxio",
                   label: device.device_name,
                   algorithm: device.algorithm,
                   digits: device.digits,
                   period_seconds: device.period_seconds
                 )
             }}

          {:error, changeset} ->
            {:error, changeset}
        end
      end)
    end
  end

  @doc "Lists local MFA devices without exposing encrypted or plaintext seeds."
  @spec list_mfa_devices(String.t() | nil) :: [map()]
  def list_mfa_devices(principal_arn \\ nil) do
    MFADevice
    |> maybe_filter_principal(principal_arn)
    |> order_by([d], asc: d.inserted_at, asc: d.device_name)
    |> Repo.all()
    |> Enum.map(&public_mfa_device/1)
  end

  @doc "Fetches one local MFA device without exposing encrypted or plaintext seeds."
  @spec get_mfa_device(String.t()) :: {:ok, map()} | :error
  def get_mfa_device(serial) when is_binary(serial) do
    # `fetch_mfa_device/1` 只有两种返回：`{:ok, %MFADevice{}}` 与
    # `{:error, :mfa_device_not_found}`（`Repo.get_by/2` 的 nil 已在那里归一）。
    # 原来的 `{:error, reason} -> {:error, reason}` 是恒不可达的恒等映射，删除。
    case fetch_mfa_device(serial) do
      {:ok, device} -> {:ok, public_mfa_device(device)}
      {:error, :mfa_device_not_found} -> :error
    end
  end

  def get_mfa_device(_serial), do: :error

  @doc "Activates a pending TOTP device by verifying and consuming its first code."
  @spec activate_mfa_device(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def activate_mfa_device(serial, code, opts \\ []) do
    with {:ok, initial} <- fetch_mfa_device(serial) do
      with_mfa_user_identities([initial.principal_arn], fn ->
        with {:ok, device} <- fetch_mfa_device(serial),
             :ok <- require_status(device, "pending", :mfa_device_not_pending),
             {:ok, secret_base32} <- MFASecret.unwrap(device.secret_envelope, device.serial),
             {:ok, matched_step, _offset} <-
               TOTP.match(secret_base32, code, totp_opts(device, opts)),
             {:ok, updated} <- activate_mfa_device_step(device, matched_step) do
          {:ok, public_mfa_device(updated)}
        end
      end)
    end
  end

  @doc """
  Enables a pending TOTP MFA device with two consecutive authentication codes.

  This is the AWS IAM `EnableMFADevice` shape. The legacy
  `activate_mfa_device/3` helper remains for local CLI/operator flows.
  """
  @spec enable_mfa_device(map() | String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def enable_mfa_device(principal, serial, code1, code2, opts \\ []) do
    with {:ok, principal_arn} <- principal_arn(principal),
         {:ok, initial} <- fetch_mfa_device(serial) do
      with_mfa_user_identities([initial.principal_arn, principal_arn], fn ->
        with {:ok, device} <- fetch_mfa_device(serial),
             :ok <- require_status(device, "pending", :mfa_device_not_pending),
             :ok <- authorize_mfa_enable_principal(device, principal_arn, opts),
             {:ok, step1, step2} <- match_consecutive_mfa_codes(device, code1, code2, opts),
             {:ok, updated} <- enable_mfa_device_steps(device, principal_arn, step1, step2) do
          {:ok, public_mfa_device(updated)}
        end
      end)
    end
  end

  @doc "Resynchronizes an active TOTP MFA device using two consecutive authentication codes."
  @spec resync_mfa_device(map() | String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resync_mfa_device(principal, serial, code1, code2, opts \\ []) do
    with {:ok, principal_arn} <- principal_arn(principal),
         {:ok, initial} <- fetch_mfa_device(serial) do
      with_mfa_user_identities([initial.principal_arn, principal_arn], fn ->
        with {:ok, device} <- fetch_mfa_device(serial),
             :ok <- require_status(device, "active", :mfa_device_not_active),
             :ok <- require_principal_match(device, principal_arn),
             {:ok, step1, step2} <- match_consecutive_mfa_codes(device, code1, code2, opts),
             {:ok, updated} <- resync_mfa_device_steps(device, step1, step2) do
          {:ok, public_mfa_device(updated)}
        end
      end)
    end
  end

  @doc """
  Verifies a local MFA device for a principal.

  Verification consumes the matched TOTP step by default. Pass `consume: false`
  for read-only CLI diagnostics.
  """
  @spec verify_mfa_device(map() | String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def verify_mfa_device(principal, serial, code, opts \\ []) do
    with {:ok, principal_arn} <- principal_arn(principal),
         {:ok, initial} <- fetch_mfa_device(serial) do
      verify = fn ->
        with {:ok, device} <- fetch_mfa_device(serial),
             :ok <- require_status(device, "active", :mfa_device_not_active),
             :ok <- require_principal_match(device, principal_arn),
             {:ok, secret_base32} <- MFASecret.unwrap(device.secret_envelope, device.serial),
             {:ok, matched_step, _offset} <-
               TOTP.match(secret_base32, code, totp_opts(device, opts)) do
          if Keyword.get(opts, :consume, true) do
            consume_mfa_step(device, matched_step)
          else
            :ok
          end
        end
      end

      if Keyword.get(opts, :consume, true) do
        with_mfa_user_identities([initial.principal_arn, principal_arn], verify)
      else
        verify.()
      end
    end
  end

  @doc "Disables an MFA device while preserving the row for audit."
  @spec disable_mfa_device(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def disable_mfa_device(serial, opts \\ []) do
    with {:ok, initial} <- fetch_mfa_device(serial) do
      with_mfa_user_identities([initial.principal_arn], fn ->
        with {:ok, device} <- fetch_mfa_device(serial),
             :ok <- authorize_mfa_disable(device, opts),
             {:ok, updated} <- disable_mfa_device_row(device) do
          {:ok, public_mfa_device(updated)}
        end
      end)
    end
  end

  @doc "Physically deletes an MFA device row. Active devices require `force: true`."
  @spec delete_mfa_device(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_mfa_device(serial, opts \\ []) do
    case Repo.get_by(MFADevice, serial: serial) do
      nil ->
        :ok

      %MFADevice{} = initial ->
        with_mfa_user_identities([initial.principal_arn], fn ->
          case Repo.get_by(MFADevice, serial: serial) do
            nil ->
              :ok

            %MFADevice{status: "active"} = device ->
              if Keyword.get(opts, :force, false) do
                Repo.delete!(device)
                :ok
              else
                {:error, :active_mfa_device_requires_force}
              end

            %MFADevice{} = device ->
              Repo.delete!(device)
              :ok
          end
        end)
    end
  end

  defp gen_access_key_id,
    do: "AKIA" <> (:crypto.strong_rand_bytes(8) |> Base.encode32(padding: false))

  defp gen_signing_certificate_id do
    suffix =
      :crypto.strong_rand_bytes(18)
      |> Base.encode32(case: :upper, padding: false)
      |> binary_part(0, 22)

    "TA" <> suffix
  end

  defp gen_ssh_public_key_id do
    suffix =
      :crypto.strong_rand_bytes(10)
      |> Base.encode32(case: :upper, padding: false)
      |> binary_part(0, 16)

    "APKA" <> suffix
  end

  defp gen_secret_key, do: :crypto.strong_rand_bytes(30) |> Base.encode64() |> binary_part(0, 40)

  defp create_access_key_scope(nil) do
    {:ok, %{type: "root", principal_arn: @root_principal_arn, user_name: nil}}
  end

  defp create_access_key_scope(user_name) when is_binary(user_name) do
    case fetch_user_record(user_name) do
      %User{status: "active"} = user ->
        {:ok, %{type: "iam_user", principal_arn: user.user_arn, user_name: user.user_name}}

      %User{} ->
        {:error, :user_inactive}

      nil ->
        {:error, :not_found}
    end
  end

  defp create_access_key_scope(_user_name), do: {:error, :malformed}

  defp access_key_scope(nil) do
    {:ok, %{type: "root", principal_arn: @root_principal_arn, user_name: nil}}
  end

  defp access_key_scope(user_name) when is_binary(user_name) do
    case fetch_user_record(user_name) do
      %User{} = user ->
        {:ok, %{type: "iam_user", principal_arn: user.user_arn, user_name: user.user_name}}

      nil ->
        {:error, :not_found}
    end
  end

  defp access_key_scope(_user_name), do: {:error, :malformed}

  defp signing_certificate_upload_scope(user_name) do
    case signing_certificate_scope(user_name) do
      {:ok, %{principal_type: "iam_user", user: %User{status: "active"}} = scope} ->
        {:ok, scope}

      {:ok, %{principal_type: "iam_user"}} ->
        {:error, :user_inactive}

      {:ok, scope} ->
        {:ok, scope}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp signing_certificate_scope(nil) do
    {:ok,
     %{
       principal_type: "root",
       user_arn: nil,
       user_name: "root",
       principal_key: @root_principal_arn
     }}
  end

  defp signing_certificate_scope(user_name) when is_binary(user_name) do
    case fetch_user_record(user_name) do
      %User{} = user ->
        {:ok,
         %{
           principal_type: "iam_user",
           user_arn: user.user_arn,
           user_name: user.user_name,
           user: user,
           principal_key: user.user_arn
         }}

      nil ->
        {:error, :not_found}
    end
  end

  defp signing_certificate_scope(_user_name), do: {:error, :malformed}

  defp signing_certificate_query(%{principal_type: "root"}) do
    from c in SigningCertificate, where: c.principal_type == "root" and is_nil(c.user_arn)
  end

  defp signing_certificate_query(%{principal_type: "iam_user", user_arn: user_arn})
       when is_binary(user_arn) do
    from c in SigningCertificate,
      where: c.principal_type == "iam_user" and c.user_arn == ^user_arn
  end

  defp ssh_public_key_upload_scope(user_name) do
    case ssh_public_key_scope(user_name) do
      {:ok, %{user: %User{status: "active"}} = scope} -> {:ok, scope}
      {:ok, _scope} -> {:error, :user_inactive}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ssh_public_key_scope(user_name) when is_binary(user_name) do
    case fetch_user_record(user_name) do
      %User{} = user ->
        {:ok, %{user_arn: user.user_arn, user_name: user.user_name, user: user}}

      nil ->
        {:error, :not_found}
    end
  end

  defp ssh_public_key_scope(_user_name), do: {:error, :malformed}

  defp ssh_public_key_query(%{user_arn: user_arn}) when is_binary(user_arn) do
    from k in SSHPublicKey, where: k.user_arn == ^user_arn
  end

  defp access_key_quota_available?(principal_arn) do
    count =
      Repo.aggregate(
        from(a in AccessKey, where: a.principal_arn == ^principal_arn),
        :count,
        :id
      )

    if count < @access_key_quota_per_principal,
      do: :ok,
      else: {:error, :access_key_limit_exceeded}
  end

  defp scoped_access_key(access_key_id, scope) do
    case Repo.get_by(AccessKey, access_key_id: access_key_id) do
      %AccessKey{principal_arn: principal_arn, type: type} = row
      when principal_arn == scope.principal_arn and type == scope.type ->
        {:ok, row}

      %AccessKey{} ->
        {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  defp signing_certificate_quota_available?(scope) do
    count =
      scope
      |> signing_certificate_query()
      |> Repo.aggregate(:count, :id)

    if count < @signing_certificates_quota_per_principal,
      do: :ok,
      else: {:error, :signing_certificate_limit_exceeded}
  end

  defp signing_certificate_upload_changeset(scope, certificate_body) do
    attrs = %{
      certificate_id: gen_signing_certificate_id(),
      principal_type: scope.principal_type,
      user_arn: scope.user_arn,
      certificate_body: certificate_body,
      status: "Active"
    }

    changeset = SigningCertificate.upload_changeset(%SigningCertificate{}, attrs)

    if changeset.valid? do
      {:ok, changeset}
    else
      {:error, signing_certificate_changeset_error(changeset)}
    end
  end

  defp reject_duplicate_signing_certificate(%Ecto.Changeset{} = changeset) do
    fingerprint = Ecto.Changeset.get_field(changeset, :certificate_fingerprint_sha256)

    if is_binary(fingerprint) and
         Repo.exists?(
           from c in SigningCertificate, where: c.certificate_fingerprint_sha256 == ^fingerprint
         ) do
      {:error, :duplicate_certificate}
    else
      :ok
    end
  end

  defp insert_signing_certificate(%Ecto.Changeset{} = changeset) do
    case Repo.insert(changeset) do
      {:ok, certificate} ->
        Notify.broadcast({:iam_changed, signing_certificate_principal_arn(certificate)})
        {:ok, certificate}

      {:error, changeset} ->
        {:error, signing_certificate_changeset_error(changeset)}
    end
  end

  defp scoped_signing_certificate(certificate_id, scope) do
    query =
      scope
      |> signing_certificate_query()
      |> where([c], c.certificate_id == ^certificate_id)
      |> lock("FOR UPDATE")

    case Repo.one(query) do
      %SigningCertificate{} = certificate -> {:ok, certificate}
      nil -> {:error, :not_found}
    end
  end

  defp ssh_public_key_quota_available?(scope) do
    count =
      scope
      |> ssh_public_key_query()
      |> Repo.aggregate(:count, :id)

    if count < @ssh_public_keys_quota_per_user,
      do: :ok,
      else: {:error, :ssh_public_key_limit_exceeded}
  end

  defp ssh_public_key_upload_changeset(scope, ssh_public_key_body) do
    attrs = %{
      ssh_public_key_id: gen_ssh_public_key_id(),
      user_arn: scope.user_arn,
      ssh_public_key_body: ssh_public_key_body,
      status: "Active"
    }

    changeset = SSHPublicKey.upload_changeset(%SSHPublicKey{}, attrs)

    if changeset.valid? do
      {:ok, changeset}
    else
      {:error, ssh_public_key_changeset_error(changeset)}
    end
  end

  defp reject_duplicate_ssh_public_key(%Ecto.Changeset{} = changeset, scope) do
    fingerprint = Ecto.Changeset.get_field(changeset, :fingerprint_md5)

    if is_binary(fingerprint) and
         Repo.exists?(
           from k in SSHPublicKey,
             where: k.user_arn == ^scope.user_arn and k.fingerprint_md5 == ^fingerprint
         ) do
      {:error, :duplicate_ssh_public_key}
    else
      :ok
    end
  end

  defp insert_ssh_public_key(%Ecto.Changeset{} = changeset) do
    case Repo.insert(changeset) do
      {:ok, ssh_public_key} ->
        Notify.broadcast({:iam_changed, ssh_public_key.user_arn})
        {:ok, ssh_public_key}

      {:error, changeset} ->
        {:error, ssh_public_key_changeset_error(changeset)}
    end
  end

  defp scoped_ssh_public_key(ssh_public_key_id, scope) do
    query =
      scope
      |> ssh_public_key_query()
      |> where([k], k.ssh_public_key_id == ^ssh_public_key_id)
      |> lock("FOR UPDATE")

    case Repo.one(query) do
      %SSHPublicKey{} = ssh_public_key -> {:ok, ssh_public_key}
      nil -> {:error, :not_found}
    end
  end

  defp ensure_root_delete_safe(%AccessKey{
         type: "root",
         status: "active",
         access_key_id: access_key_id
       }) do
    active_root_count =
      Repo.aggregate(
        from(a in AccessKey,
          where: a.type == "root" and a.status == "active" and a.access_key_id != ^access_key_id
        ),
        :count,
        :id
      )

    if active_root_count < 1, do: {:error, :cannot_delete_last_root}, else: :ok
  end

  defp ensure_root_delete_safe(%AccessKey{}), do: :ok

  defp ensure_root_status_update_safe(%AccessKey{type: "root", status: "active"}, new_status)
       when new_status != "active" do
    active_root_count =
      Repo.aggregate(
        from(a in AccessKey, where: a.type == "root" and a.status == "active"),
        :count,
        :id
      )

    if active_root_count <= 1, do: {:error, :cannot_deactivate_last_root}, else: :ok
  end

  defp ensure_root_status_update_safe(%AccessKey{}, _new_status), do: :ok

  defp public_access_key(%AccessKey{} = access_key, opts \\ []) do
    base = %{
      access_key_id: access_key.access_key_id,
      principal_arn: access_key.principal_arn,
      user_name: access_key_user_name(access_key.principal_arn),
      type: access_key.type,
      status: access_key.status,
      tags: access_key.tags || %{},
      last_used_at: access_key.last_used_at,
      last_used_service: access_key.last_used_service,
      last_used_region: access_key.last_used_region,
      inserted_at: access_key.inserted_at,
      updated_at: access_key.updated_at
    }

    case Keyword.get(opts, :secret_key) do
      secret_key when is_binary(secret_key) -> Map.put(base, :secret_key, secret_key)
      _other -> base
    end
  end

  defp access_key_user_name(@root_principal_arn), do: "root"
  defp access_key_user_name("arn:aws:iam:::user/" <> user_name), do: user_name
  defp access_key_user_name(principal_arn), do: to_string(principal_arn)

  defp public_access_key_last_used(%AccessKey{} = access_key) do
    %{
      access_key_id: access_key.access_key_id,
      user_name: access_key_user_name(access_key.principal_arn),
      last_used_at: access_key.last_used_at,
      service_name: access_key.last_used_service || "N/A",
      region: access_key.last_used_region || "N/A"
    }
  end

  defp public_signing_certificate(%SigningCertificate{} = certificate) do
    %{
      certificate_id: certificate.certificate_id,
      principal_type: certificate.principal_type,
      user_arn: certificate.user_arn,
      user_name: signing_certificate_user_name(certificate),
      certificate_body: certificate.certificate_body,
      status: certificate.status,
      expiration: certificate.expiration,
      inserted_at: certificate.inserted_at,
      updated_at: certificate.updated_at
    }
  end

  defp signing_certificate_user_name(%SigningCertificate{principal_type: "root"}), do: "root"

  defp signing_certificate_user_name(%SigningCertificate{
         principal_type: "iam_user",
         user_arn: "arn:aws:iam:::user/" <> user_name
       }),
       do: user_name

  defp signing_certificate_user_name(%SigningCertificate{user_arn: user_arn}),
    do: to_string(user_arn)

  defp signing_certificate_principal_arn(%SigningCertificate{principal_type: "root"}),
    do: @root_principal_arn

  defp signing_certificate_principal_arn(%SigningCertificate{user_arn: user_arn})
       when is_binary(user_arn),
       do: user_arn

  defp public_ssh_public_key(%SSHPublicKey{} = ssh_public_key) do
    %{
      ssh_public_key_id: ssh_public_key.ssh_public_key_id,
      user_arn: ssh_public_key.user_arn,
      user_name: ssh_public_key_user_name(ssh_public_key),
      ssh_public_key_body: ssh_public_key.ssh_public_key_body,
      ssh_public_key_body_ssh: ssh_public_key.ssh_public_key_body_ssh,
      ssh_public_key_body_pem: ssh_public_key.ssh_public_key_body_pem,
      fingerprint: ssh_public_key.fingerprint_md5,
      status: ssh_public_key.status,
      inserted_at: ssh_public_key.inserted_at,
      updated_at: ssh_public_key.updated_at
    }
  end

  defp ssh_public_key_user_name(%SSHPublicKey{user_arn: "arn:aws:iam:::user/" <> user_name}),
    do: user_name

  defp ssh_public_key_user_name(%SSHPublicKey{user_arn: user_arn}), do: to_string(user_arn)

  defp access_key_principal_arn("root", _access_key_id, _opts), do: {:ok, @root_principal_arn}

  defp access_key_principal_arn("iam_user", access_key_id, opts) do
    explicit_arn = opts |> Keyword.get(:principal_arn) |> normalize_iam_text()
    user_name = opts |> Keyword.get(:user_name, Keyword.get(opts, :user)) |> normalize_iam_text()

    cond do
      is_binary(explicit_arn) and explicit_arn != "" ->
        validate_access_key_user_arn(explicit_arn, access_key_id)

      is_binary(user_name) and user_name != "" ->
        case get_user(user_name) do
          {:ok, %{status: "active", user_arn: arn}} -> {:ok, arn}
          {:ok, _inactive_user} -> {:error, :user_inactive}
          :error -> {:error, :user_not_found}
        end

      true ->
        {:ok, user_arn(access_key_id)}
    end
  end

  defp access_key_principal_arn(_type, _access_key_id, _opts), do: {:error, :malformed}

  # 原先是「`when is_binary` 子句 + 非二进制兜底子句」，两支对非法输入产出同一个
  # `{:error, :invalid_principal_arn}`，而调用方已把 arn 收窄成二进制，兜底永远不可达。
  # 合并成一个总函数：判定逐字保留（二进制且匹配本地 user ARN 形态才继续），
  # 其余一切仍被同一个结构化错误拒绝，且这条分支现在真正可达。
  defp validate_access_key_user_arn(user_arn, access_key_id) do
    if local_user_arn?(user_arn) do
      validate_existing_access_key_user_arn(user_arn, access_key_id)
    else
      {:error, :invalid_principal_arn}
    end
  end

  defp validate_existing_access_key_user_arn(user_arn, access_key_id) do
    case Repo.get_by(User, user_arn: user_arn) do
      %User{status: "inactive"} ->
        {:error, :user_inactive}

      %User{} ->
        {:ok, user_arn}

      nil ->
        if legacy_self_user_principal_arn?(user_arn, access_key_id),
          do: {:ok, user_arn},
          else: {:error, :user_not_found}
    end
  end

  defp public_active_access_key_principal(
         %AccessKey{
           type: "root",
           principal_arn: @root_principal_arn
         } = access_key
       ) do
    {:ok,
     %{
       type: :root,
       access_key: access_key.access_key_id,
       arn: access_key.principal_arn,
       tags: access_key.tags || %{}
     }}
  end

  defp public_active_access_key_principal(
         %AccessKey{
           type: "iam_user",
           principal_arn: principal_arn
         } = access_key
       ) do
    if iam_user_principal_usable?(principal_arn, access_key.access_key_id) do
      {:ok,
       %{
         type: :iam_user,
         access_key: access_key.access_key_id,
         arn: principal_arn,
         tags: access_key.tags || %{}
       }}
    else
      :error
    end
  end

  defp public_active_access_key_principal(%AccessKey{}), do: :error

  defp local_user_arn?("arn:aws:iam:::user/" <> user_name = principal_arn) do
    Regex.match?(@local_user_arn_pattern, principal_arn) or
      MinioAccessKey.validate(user_name) == :ok
  end

  defp local_user_arn?(_principal_arn), do: false

  defp legacy_self_user_principal_arn?("arn:aws:iam:::user/" <> resource, access_key_id)
       when is_binary(access_key_id),
       do: resource == access_key_id

  defp legacy_self_user_principal_arn?(_principal_arn, _access_key_id), do: false

  defp default_user_arn(user_name) when is_binary(user_name) and user_name != "",
    do: user_arn(user_name)

  defp default_user_arn(_user_name), do: nil

  defp default_group_arn(group_name) when is_binary(group_name) and group_name != "",
    do: group_arn(group_name)

  defp default_group_arn(_group_name), do: nil

  defp resolve_user_arn(value) do
    value = normalize_iam_text(value)

    if String.starts_with?(value, "arn:aws:iam:::user/") do
      value
    else
      user_arn(value)
    end
  end

  defp resolve_group_arn(value) do
    value = normalize_iam_text(value)

    if String.starts_with?(value, "arn:aws:iam:::group/") do
      value
    else
      group_arn(value)
    end
  end

  defp access_keys_for_principal(principal_arn) do
    Repo.all(
      from a in AccessKey,
        where: a.principal_arn == ^principal_arn,
        select: a.access_key_id
    )
  end

  defp session_access_keys_for_principal(principal_arn) do
    Repo.all(
      from s in STSSession,
        where: s.principal_arn == ^principal_arn,
        select: s.access_key_id
    )
  end

  defp update_user_principal_references(old_arn, new_arn) do
    now = utc_now()
    update_principal_policy_arns(old_arn, new_arn, now)

    Repo.update_all(
      from(a in AccessKey, where: a.principal_arn == ^old_arn),
      set: [principal_arn: new_arn, updated_at: now]
    )

    Repo.update_all(
      from(d in MFADevice, where: d.principal_arn == ^old_arn),
      set: [principal_arn: new_arn, updated_at: now]
    )

    Repo.update_all(
      from(s in STSSession, where: s.principal_arn == ^old_arn),
      set: [principal_arn: new_arn, updated_at: now]
    )
  end

  defp update_group_principal_references(old_arn, new_arn) do
    update_principal_policy_arns(old_arn, new_arn, utc_now())
  end

  defp update_principal_policy_arns(old_arn, new_arn, now) do
    Repo.update_all(
      from(p in PrincipalPolicy, where: p.principal_arn == ^old_arn),
      set: [principal_arn: new_arn, updated_at: now]
    )
  end

  defp broadcast_principal_rename(old_arn, new_arn, access_key_ids) do
    Notify.broadcast({:principal_policy_changed, old_arn})
    Notify.broadcast({:principal_policy_changed, new_arn})

    access_key_ids
    |> Enum.uniq()
    |> Enum.each(&Notify.broadcast({:iam_changed, &1}))
  end

  defp revoke_user_sessions(user_arn, access_key_ids) do
    now = utc_now()
    revoke_user_sessions(user_arn, MapSet.new(access_key_ids), MapSet.new(), now)
  end

  defp revoke_user_sessions(user_arn, issuer_ids, revoked_ids, now) do
    issuer_list = MapSet.to_list(issuer_ids)

    newly_revoked =
      Repo.all(
        from s in STSSession,
          where:
            s.status == "active" and
              (s.principal_arn == ^user_arn or s.issuer_access_key_id in ^issuer_list),
          select: s.access_key_id
      )
      |> Enum.reject(&MapSet.member?(revoked_ids, &1))

    case newly_revoked do
      [] ->
        MapSet.to_list(revoked_ids)

      access_key_ids ->
        Repo.update_all(
          from(s in STSSession, where: s.access_key_id in ^access_key_ids),
          set: [status: "revoked", revoked_at: now, updated_at: now]
        )

        revoke_user_sessions(
          user_arn,
          MapSet.union(issuer_ids, MapSet.new(access_key_ids)),
          MapSet.union(revoked_ids, MapSet.new(access_key_ids)),
          now
        )
    end
  end

  defp default_role_arn(role_name) when is_binary(role_name) and role_name != "",
    do: role_arn(role_name)

  defp default_role_arn(_role_name), do: nil

  defp managed_policy_target(opts) do
    policy_arn =
      opts
      |> Keyword.get(:policy_arn, Keyword.get(opts, :arn))
      |> normalize_iam_text()

    if is_binary(policy_arn) and policy_arn != "" do
      parse_managed_policy_arn(policy_arn)
    else
      managed_policy_target_from_name(opts)
    end
  end

  defp managed_policy_target_from_name(opts) do
    policy_name =
      opts
      |> Keyword.get(:policy_name, Keyword.get(opts, :name))
      |> normalize_iam_text()

    path =
      opts
      |> Keyword.get(:path, "/")
      |> normalize_iam_text()

    with :ok <- validate_managed_policy_name(policy_name),
         :ok <- validate_managed_policy_path(path) do
      parse_managed_policy_arn(managed_policy_arn(policy_name, path))
    end
  end

  defp managed_policy_description(opts) do
    case Keyword.get(opts, :description, "") do
      nil -> ""
      value -> normalize_iam_text(value)
    end
  end

  defp parse_managed_policy_arn("arn:aws:iam:::policy/" <> resource_path)
       when resource_path != "" do
    case split_managed_policy_resource_path(resource_path) do
      {:ok, path, policy_name} ->
        with :ok <- validate_managed_policy_path(path),
             :ok <- validate_managed_policy_name(policy_name) do
          {:ok,
           %{
             policy_arn: "arn:aws:iam:::policy/#{resource_path}",
             path: path,
             policy_name: policy_name
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_managed_policy_arn(_policy_arn), do: {:error, :malformed}

  defp split_managed_policy_resource_path(resource_path) do
    case String.split(resource_path, "/") do
      [_empty_or_name] when resource_path == "" ->
        {:error, :malformed}

      [policy_name] ->
        {:ok, "/", policy_name}

      segments ->
        policy_name = List.last(segments)
        path_segments = Enum.slice(segments, 0..-2//1)

        if policy_name in [nil, ""] or Enum.any?(path_segments, &(&1 == "")) do
          {:error, :malformed}
        else
          {:ok, "/" <> Enum.join(path_segments, "/") <> "/", policy_name}
        end
    end
  end

  defp validate_managed_policy_name(name)
       when is_binary(name) and byte_size(name) >= 1 and byte_size(name) <= 128 do
    if Regex.match?(@managed_policy_name_pattern, name) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp validate_managed_policy_name(_name), do: {:error, :malformed}

  defp validate_managed_policy_path(path) when is_binary(path) do
    cond do
      path == "/" ->
        :ok

      byte_size(path) > 512 ->
        {:error, :malformed}

      not String.starts_with?(path, "/") or not String.ends_with?(path, "/") ->
        {:error, :malformed}

      String.contains?(path, "//") ->
        {:error, :malformed}

      true ->
        path
        |> String.split("/", trim: true)
        |> Enum.all?(&Regex.match?(@managed_policy_path_segment_pattern, &1))
        |> case do
          true -> :ok
          false -> {:error, :malformed}
        end
    end
  end

  defp validate_managed_policy_path(_path), do: {:error, :malformed}

  # 同 `validate_access_key_user_arn/2`：两支子句对非法输入产出同一个 `{:error, :malformed}`，
  # 调用方已把 version_id 收窄成二进制使兜底不可达。合并成一个总函数，判定与错误码逐字不变。
  defp validate_managed_policy_version_id(version_id) do
    if is_binary(version_id) and Regex.match?(@managed_policy_version_id_pattern, version_id) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp managed_policy_resource_path(policy_name, "/"), do: policy_name

  defp managed_policy_resource_path(policy_name, path) do
    String.trim_leading(path, "/") <> policy_name
  end

  defp normalize_policy_document(document) when is_binary(document), do: {:ok, document}

  defp normalize_policy_document(%{} = document) do
    {:ok, Jason.encode!(document)}
  rescue
    _error -> {:error, :malformed}
  end

  defp normalize_policy_document(_document), do: {:error, :malformed}

  defp managed_policy_listing(%{policy_arn: policy_arn} = policy) do
    case parse_managed_policy_arn(policy_arn) do
      {:ok, metadata} ->
        [
          metadata
          |> Map.merge(policy)
          |> put_managed_policy_runtime_metadata()
        ]

      {:error, _reason} ->
        []
    end
  end

  defp managed_policy_store_metadata(policy_arn) do
    Store.list_managed_session_policies()
    |> Enum.find(&(&1.policy_arn == policy_arn))
    |> case do
      nil ->
        %{}

      policy ->
        %{
          description: Map.get(policy, :description, ""),
          tags: Map.get(policy, :tags, %{}),
          default_version_id:
            Map.get(policy, :default_version_id, @managed_policy_default_version_id),
          inserted_at: Map.get(policy, :inserted_at),
          updated_at: Map.get(policy, :updated_at)
        }
    end
  end

  defp put_managed_policy_runtime_metadata(%{policy_arn: policy_arn} = policy) do
    policy
    |> Map.put_new(:description, "")
    |> Map.put_new(:tags, %{})
    |> Map.put_new(:default_version_id, @managed_policy_default_version_id)
    |> Map.put(:attachment_count, Store.managed_session_policy_attachment_count(policy_arn))
    |> Map.put(:is_attachable, true)
    |> Map.put(
      :permissions_boundary_usage_count,
      Store.managed_session_policy_permissions_boundary_count(policy_arn)
    )
  end

  defp managed_policy_matches_usage_filter?(policy, "PermissionsBoundary", _only_attached) do
    Map.get(policy, :permissions_boundary_usage_count, 0) > 0
  end

  defp managed_policy_matches_usage_filter?(policy, _policy_usage_filter, only_attached) do
    not only_attached or Map.get(policy, :attachment_count, 0) > 0
  end

  defp managed_policy_entities_for_usage(policy_arn, "PermissionsBoundary") do
    Store.list_managed_session_policy_permissions_boundary_entities(policy_arn)
  end

  defp managed_policy_entities_for_usage(policy_arn, _policy_usage_filter) do
    Store.list_managed_session_policy_entities(policy_arn)
  end

  defp permissions_boundary_policy_arn_from_opts(opts) do
    opts
    |> Keyword.get(
      :permissions_boundary_policy_arn,
      Keyword.get(opts, :permissions_boundary)
    )
    |> normalize_iam_text()
  end

  defp ensure_permissions_boundary_policy(nil), do: :ok

  defp ensure_permissions_boundary_policy(policy_arn) when is_binary(policy_arn) do
    with :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, _policy} <- get_managed_policy(policy_arn) do
      :ok
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_permissions_boundary_policy(_policy_arn), do: {:error, :malformed}

  defp broadcast_permissions_boundary_change(principal_arn) do
    Notify.broadcast({:principal_policy_changed, principal_arn})
  end

  defp managed_policy_only_attached?(value) when value in [true, "true", "True", "TRUE"], do: true
  defp managed_policy_only_attached?(_value), do: false

  defp attached_role_policy_listing(%{policy_arn: policy_arn, role_arn: role_arn} = attachment) do
    case parse_managed_policy_arn(policy_arn) do
      {:ok, metadata} ->
        [
          attachment
          |> Map.merge(metadata)
          |> Map.put(:role_arn, role_arn)
        ]

      {:error, _reason} ->
        []
    end
  end

  defp attached_user_policy_listing(%{policy_arn: policy_arn, user_arn: user_arn} = attachment) do
    case parse_managed_policy_arn(policy_arn) do
      {:ok, metadata} ->
        [
          attachment
          |> Map.merge(metadata)
          |> Map.put(:user_arn, user_arn)
        ]

      {:error, _reason} ->
        []
    end
  end

  defp attached_group_policy_listing(%{policy_arn: policy_arn, group_arn: group_arn} = attachment) do
    case parse_managed_policy_arn(policy_arn) do
      {:ok, metadata} ->
        [
          attachment
          |> Map.merge(metadata)
          |> Map.put(:group_arn, group_arn)
        ]

      {:error, _reason} ->
        []
    end
  end

  defp normalize_trust_policy(%{} = policy) when map_size(policy) > 0, do: {:ok, policy}

  defp normalize_trust_policy(json) when is_binary(json) do
    case decode_json_object_no_duplicate_keys(json) do
      {:ok, %{} = policy} -> {:ok, policy}
      _other -> {:error, :malformed_trust_policy}
    end
  end

  defp normalize_trust_policy(_policy), do: {:error, :malformed_trust_policy}

  defp normalize_role_description(nil), do: ""
  defp normalize_role_description(description) when is_binary(description), do: description
  defp normalize_role_description(description), do: to_string(description)

  defp public_role(%Role{} = role) do
    %{
      id: role.id,
      role_name: role.role_name,
      role_arn: role.role_arn,
      description: role.description || "",
      trust_policy: role.trust_policy,
      max_session_duration_seconds: role.max_session_duration_seconds,
      tags: role.tags || %{},
      permissions_boundary_policy_arn: role.permissions_boundary_policy_arn,
      inserted_at: role.inserted_at,
      updated_at: role.updated_at
    }
  end

  defp public_instance_profile(%InstanceProfile{} = profile) do
    %{
      id: profile.id,
      instance_profile_name: profile.instance_profile_name,
      instance_profile_arn: profile.instance_profile_arn,
      path: profile.path || "/",
      role_arn: profile.role_arn,
      roles: instance_profile_roles(profile),
      tags: profile.tags || %{},
      inserted_at: profile.inserted_at,
      updated_at: profile.updated_at
    }
  end

  defp instance_profile_roles(%InstanceProfile{role_arn: role_arn})
       when is_binary(role_arn) and role_arn != "" do
    case fetch_role_record(role_arn) do
      %Role{} = role -> [public_role(role)]
      nil -> []
    end
  end

  defp instance_profile_roles(%InstanceProfile{}), do: []

  defp public_server_certificate(%ServerCertificate{} = certificate) do
    %{
      id: certificate.id,
      server_certificate_name: certificate.server_certificate_name,
      server_certificate_arn: certificate.server_certificate_arn,
      path: certificate.path || "/",
      certificate_body: certificate.certificate_body,
      certificate_chain: certificate.certificate_chain,
      expiration: certificate.expiration,
      tags: certificate.tags || %{},
      inserted_at: certificate.inserted_at,
      updated_at: certificate.updated_at
    }
  end

  defp role_update_attrs(attrs) do
    %{}
    |> maybe_put_update_attr(:max_session_duration_seconds, attrs)
    |> maybe_put_update_attr(:description, attrs)
  end

  defp server_certificate_update_attrs(attrs) do
    %{}
    |> maybe_put_update_attr(:server_certificate_name, attrs)
    |> maybe_put_update_attr(:path, attrs)
  end

  defp maybe_put_update_attr(acc, key, attrs) do
    if Map.has_key?(attrs, key) and not is_nil(Map.get(attrs, key)) do
      Map.put(acc, key, Map.get(attrs, key))
    else
      acc
    end
  end

  defp decode_json_object_no_duplicate_keys(json) do
    case Jason.decode(json, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = object} -> ordered_json_object_to_map(object)
      _other -> {:error, :malformed}
    end
  end

  defp ordered_json_object_to_map(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))

    if length(keys) == length(Enum.uniq(keys)) do
      Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case ordered_json_to_term(value) do
          {:ok, converted} -> {:cont, {:ok, Map.put(acc, key, converted)}}
          {:error, :malformed} -> {:halt, {:error, :malformed}}
        end
      end)
    else
      {:error, :malformed}
    end
  end

  defp ordered_json_to_term(%Jason.OrderedObject{} = object),
    do: ordered_json_object_to_map(object)

  defp ordered_json_to_term(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case ordered_json_to_term(value) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        {:error, :malformed} -> {:halt, {:error, :malformed}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp ordered_json_to_term(value), do: {:ok, value}

  defp public_user(%User{} = user) do
    %{
      id: user.id,
      user_name: user.user_name,
      user_arn: user.user_arn,
      status: user.status,
      tags: user.tags || %{},
      permissions_boundary_policy_arn: user.permissions_boundary_policy_arn,
      inserted_at: user.inserted_at,
      updated_at: user.updated_at
    }
  end

  defp ensure_rename_target(%User{id: id}, %User{id: id}), do: :ok
  defp ensure_rename_target(%User{}, :missing), do: :ok
  defp ensure_rename_target(%User{}, %User{}), do: {:error, :user_already_exists}

  defp fetch_user_record(user_name_or_arn) do
    value = normalize_iam_text(user_name_or_arn)

    cond do
      not is_binary(value) or value == "" ->
        nil

      String.starts_with?(value, "arn:aws:iam:::user/") ->
        Repo.get_by(User, user_arn: value)

      true ->
        Repo.get_by(User, user_name: value) || fetch_user_by_case_insensitive_name(value)
    end
  end

  defp fetch_user_by_case_insensitive_name(user_name) do
    normalized = String.downcase(user_name)

    Repo.one(
      from u in User,
        where: fragment("lower(?)", u.user_name) == ^normalized,
        order_by: [asc: u.inserted_at],
        limit: 1
    )
  end

  defp reject_group_name_case_insensitive_duplicate(group_name)
       when is_binary(group_name) and group_name != "" do
    if fetch_group_by_case_insensitive_name(group_name) do
      {:error, :group_already_exists}
    else
      :ok
    end
  end

  defp reject_group_name_case_insensitive_duplicate(_group_name), do: :ok

  defp fetch_group_record(group_name_or_arn) do
    value = normalize_iam_text(group_name_or_arn)

    cond do
      not is_binary(value) or value == "" ->
        nil

      String.starts_with?(value, "arn:aws:iam:::group/") ->
        Repo.get_by(Group, group_arn: value)

      true ->
        Repo.get_by(Group, group_name: value) || fetch_group_by_case_insensitive_name(value)
    end
  end

  defp fetch_group_by_case_insensitive_name(group_name) do
    normalized = String.downcase(group_name)

    Repo.one(
      from g in Group,
        where: fragment("lower(?)", g.group_name) == ^normalized,
        order_by: [asc: g.inserted_at],
        limit: 1
    )
  end

  defp update_group_name_transaction(%Group{} = group, new_group_name, new_arn) do
    old_arn = group.group_arn

    transaction_result =
      Repo.transaction(fn ->
        case group
             |> Group.changeset(%{group_name: new_group_name, group_arn: new_arn})
             |> Repo.update() do
          {:ok, updated} ->
            update_group_principal_references(old_arn, new_arn)
            updated

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    case transaction_result do
      {:ok, updated} ->
        broadcast_principal_rename(old_arn, new_arn, [])
        {:ok, public_group(updated)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reject_group_name_update_duplicate(%Group{} = group, new_group_name)
       when is_binary(new_group_name) and new_group_name != "" do
    case fetch_group_by_case_insensitive_name(new_group_name) do
      nil -> :ok
      %Group{id: id} when id == group.id -> :ok
      %Group{} -> {:error, :group_already_exists}
    end
  end

  defp reject_group_name_update_duplicate(_group, _new_group_name), do: :ok

  defp reject_role_name_case_insensitive_duplicate(role_name)
       when is_binary(role_name) and role_name != "" do
    if fetch_role_by_case_insensitive_name(role_name) do
      {:error, :role_already_exists}
    else
      :ok
    end
  end

  defp reject_role_name_case_insensitive_duplicate(_role_name), do: :ok

  defp reject_instance_profile_name_case_insensitive_duplicate(instance_profile_name)
       when is_binary(instance_profile_name) and instance_profile_name != "" do
    if fetch_instance_profile_by_case_insensitive_name(instance_profile_name) do
      {:error, :instance_profile_already_exists}
    else
      :ok
    end
  end

  defp reject_instance_profile_name_case_insensitive_duplicate(_instance_profile_name), do: :ok

  defp reject_server_certificate_name_case_insensitive_duplicate(server_certificate_name)
       when is_binary(server_certificate_name) and server_certificate_name != "" do
    if fetch_server_certificate_by_case_insensitive_name(server_certificate_name) do
      {:error, :server_certificate_already_exists}
    else
      :ok
    end
  end

  defp reject_server_certificate_name_case_insensitive_duplicate(_server_certificate_name),
    do: :ok

  defp reject_server_certificate_name_update_duplicate(
         %ServerCertificate{} = certificate,
         new_name
       )
       when is_binary(new_name) and new_name != "" do
    case fetch_server_certificate_by_case_insensitive_name(new_name) do
      nil -> :ok
      %ServerCertificate{id: id} when id == certificate.id -> :ok
      %ServerCertificate{} -> {:error, :server_certificate_already_exists}
    end
  end

  defp reject_server_certificate_name_update_duplicate(_certificate, _new_name), do: :ok

  defp fetch_role_record(role_name_or_arn) do
    value = normalize_iam_text(role_name_or_arn)

    cond do
      not is_binary(value) or value == "" ->
        nil

      String.starts_with?(value, "arn:aws:iam:::role/") ->
        Repo.get_by(Role, role_arn: value)

      true ->
        Repo.get_by(Role, role_name: value) || fetch_role_by_case_insensitive_name(value)
    end
  end

  defp fetch_role_by_case_insensitive_name(role_name) do
    normalized = String.downcase(role_name)

    Repo.one(
      from r in Role,
        where: fragment("lower(?)", r.role_name) == ^normalized,
        order_by: [asc: r.inserted_at],
        limit: 1
    )
  end

  defp fetch_instance_profile_record(instance_profile_name_or_arn) do
    value = normalize_iam_text(instance_profile_name_or_arn)

    cond do
      not is_binary(value) or value == "" ->
        nil

      String.starts_with?(value, "arn:aws:iam:::instance-profile/") ->
        Repo.get_by(InstanceProfile, instance_profile_arn: value)

      true ->
        Repo.get_by(InstanceProfile, instance_profile_name: value) ||
          fetch_instance_profile_by_case_insensitive_name(value)
    end
  end

  defp fetch_instance_profile_record_for_update(instance_profile_name_or_arn) do
    value = normalize_iam_text(instance_profile_name_or_arn)

    cond do
      not is_binary(value) or value == "" ->
        nil

      String.starts_with?(value, "arn:aws:iam:::instance-profile/") ->
        Repo.one(
          from p in InstanceProfile,
            where: p.instance_profile_arn == ^value,
            lock: "FOR UPDATE",
            limit: 1
        )

      true ->
        Repo.one(
          from p in InstanceProfile,
            where: p.instance_profile_name == ^value,
            lock: "FOR UPDATE",
            limit: 1
        ) || fetch_instance_profile_by_case_insensitive_name_for_update(value)
    end
  end

  defp fetch_instance_profile_by_case_insensitive_name(instance_profile_name) do
    normalized = String.downcase(instance_profile_name)

    Repo.one(
      from p in InstanceProfile,
        where: fragment("lower(?)", p.instance_profile_name) == ^normalized,
        order_by: [asc: p.inserted_at],
        limit: 1
    )
  end

  defp fetch_instance_profile_by_case_insensitive_name_for_update(instance_profile_name) do
    normalized = String.downcase(instance_profile_name)

    Repo.one(
      from p in InstanceProfile,
        where: fragment("lower(?)", p.instance_profile_name) == ^normalized,
        order_by: [asc: p.inserted_at],
        lock: "FOR UPDATE",
        limit: 1
    )
  end

  defp fetch_server_certificate_record(server_certificate_name_or_arn) do
    value = normalize_iam_text(server_certificate_name_or_arn)

    cond do
      not is_binary(value) or value == "" ->
        nil

      String.starts_with?(value, "arn:aws:iam:::server-certificate/") ->
        Repo.get_by(ServerCertificate, server_certificate_arn: value)

      true ->
        Repo.get_by(ServerCertificate, server_certificate_name: value) ||
          fetch_server_certificate_by_case_insensitive_name(value)
    end
  end

  defp fetch_server_certificate_record_for_update(server_certificate_name_or_arn) do
    value = normalize_iam_text(server_certificate_name_or_arn)

    cond do
      not is_binary(value) or value == "" ->
        nil

      String.starts_with?(value, "arn:aws:iam:::server-certificate/") ->
        Repo.one(
          from c in ServerCertificate,
            where: c.server_certificate_arn == ^value,
            lock: "FOR UPDATE",
            limit: 1
        )

      true ->
        Repo.one(
          from c in ServerCertificate,
            where: c.server_certificate_name == ^value,
            lock: "FOR UPDATE",
            limit: 1
        ) || fetch_server_certificate_by_case_insensitive_name_for_update(value)
    end
  end

  defp fetch_server_certificate_by_case_insensitive_name(server_certificate_name) do
    normalized = String.downcase(server_certificate_name)

    Repo.one(
      from c in ServerCertificate,
        where: fragment("lower(?)", c.server_certificate_name) == ^normalized,
        order_by: [asc: c.inserted_at],
        limit: 1
    )
  end

  defp fetch_server_certificate_by_case_insensitive_name_for_update(server_certificate_name) do
    normalized = String.downcase(server_certificate_name)

    Repo.one(
      from c in ServerCertificate,
        where: fragment("lower(?)", c.server_certificate_name) == ^normalized,
        order_by: [asc: c.inserted_at],
        lock: "FOR UPDATE",
        limit: 1
    )
  end

  defp update_user(user_name_or_arn, fun) when is_function(fun, 1) do
    case fetch_user_record(user_name_or_arn) do
      %User{} = initial ->
        Repo.transaction(fn ->
          with {:ok, %User{} = user} <-
                 UserIdentity.lock_snapshot(
                   Repo,
                   initial.user_name,
                   {:existing, initial.id}
                 ),
               {:ok, updated} <- user |> fun.() |> Repo.update() do
            credential_ids = UserIdentity.descendant_credential_ids(Repo, updated)
            {updated, credential_ids.long_term ++ credential_ids.sessions}
          else
            {:error, reason} -> Repo.rollback({:error, reason})
          end
        end)
        |> case do
          {:ok, {updated, credential_ids}} ->
            Notify.broadcast({:principal_policy_changed, updated.user_arn})
            Enum.each(Enum.uniq(credential_ids), &Notify.broadcast({:iam_changed, &1}))
            {:ok, public_user(updated)}

          {:error, {:error, :user_not_found}} ->
            {:error, :not_found}

          {:error, {:error, reason}} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp update_role(role_name_or_arn, fun) when is_function(fun, 1) do
    case fetch_role_record(role_name_or_arn) do
      %Role{} = role ->
        with {:ok, updated} <- role |> fun.() |> Repo.update() do
          Notify.broadcast({:iam_changed, updated.role_arn})
          {:ok, public_role(updated)}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp update_instance_profile(instance_profile_name_or_arn, fun) when is_function(fun, 1) do
    case fetch_instance_profile_record(instance_profile_name_or_arn) do
      %InstanceProfile{} = profile ->
        with {:ok, updated} <- profile |> fun.() |> Repo.update() do
          Notify.broadcast({:iam_changed, updated.instance_profile_arn})
          {:ok, public_instance_profile(updated)}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp instance_profile_transaction_result({:ok, %InstanceProfile{} = updated}) do
    Notify.broadcast({:iam_changed, updated.instance_profile_arn})
    {:ok, public_instance_profile(updated)}
  end

  defp instance_profile_transaction_result({:error, reason}), do: {:error, reason}

  defp update_server_certificate(server_certificate_name_or_arn, fun) when is_function(fun, 1) do
    case fetch_server_certificate_record(server_certificate_name_or_arn) do
      %ServerCertificate{} = certificate ->
        with {:ok, updated} <- certificate |> fun.() |> Repo.update() do
          Notify.broadcast({:iam_changed, updated.server_certificate_arn})
          {:ok, public_server_certificate(updated)}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp server_certificate_transaction_result({:ok, %ServerCertificate{} = updated}) do
    Notify.broadcast({:iam_changed, updated.server_certificate_arn})
    {:ok, public_server_certificate(updated)}
  end

  defp server_certificate_transaction_result({:error, reason}), do: {:error, reason}

  defp user_delete_blockers(%User{} = user) do
    [
      access_keys: Repo.exists?(from a in AccessKey, where: a.principal_arn == ^user.user_arn),
      group_memberships:
        Repo.exists?(from m in GroupMembership, where: m.user_arn == ^user.user_arn),
      inline_policies:
        Repo.exists?(from p in PrincipalPolicy, where: p.principal_arn == ^user.user_arn),
      managed_policy_attachments:
        Repo.exists?(from a in UserManagedPolicyAttachment, where: a.user_arn == ^user.user_arn),
      mfa_devices: Repo.exists?(from d in MFADevice, where: d.principal_arn == ^user.user_arn),
      signing_certificates:
        Repo.exists?(from c in SigningCertificate, where: c.user_arn == ^user.user_arn),
      ssh_public_keys: Repo.exists?(from k in SSHPublicKey, where: k.user_arn == ^user.user_arn)
    ]
    |> Enum.flat_map(fn
      {name, true} -> [name]
      {_name, false} -> []
    end)
  end

  defp group_delete_blockers(%Group{} = group) do
    [
      group_memberships:
        Repo.exists?(from m in GroupMembership, where: m.group_arn == ^group.group_arn),
      inline_policies:
        Repo.exists?(from p in PrincipalPolicy, where: p.principal_arn == ^group.group_arn),
      managed_policy_attachments:
        Repo.exists?(
          from a in GroupManagedPolicyAttachment, where: a.group_arn == ^group.group_arn
        )
    ]
    |> Enum.flat_map(fn
      {name, true} -> [name]
      {_name, false} -> []
    end)
  end

  defp role_delete_blockers(%Role{} = role) do
    now = DateTime.utc_now()

    [
      inline_policies:
        Repo.exists?(from p in PrincipalPolicy, where: p.principal_arn == ^role.role_arn),
      managed_policy_attachments:
        Repo.exists?(from a in RoleManagedPolicyAttachment, where: a.role_arn == ^role.role_arn),
      instance_profiles:
        Repo.exists?(from p in InstanceProfile, where: p.role_arn == ^role.role_arn),
      active_sts_sessions:
        Repo.exists?(
          from s in STSSession,
            where:
              s.principal_arn == ^role.role_arn and s.status == "active" and
                s.expires_at > ^now
        )
    ]
    |> Enum.flat_map(fn
      {name, true} -> [name]
      {_name, false} -> []
    end)
  end

  defp ensure_instance_profile_quota do
    if Repo.aggregate(InstanceProfile, :count, :id) < @instance_profiles_quota do
      :ok
    else
      {:error, :limit_exceeded}
    end
  end

  defp ensure_server_certificate_quota do
    if Repo.aggregate(ServerCertificate, :count, :id) < @server_certificates_quota do
      :ok
    else
      {:error, :server_certificate_limit_exceeded}
    end
  end

  defp ensure_instance_profile_role_slot(%InstanceProfile{role_arn: nil}, _role_arn), do: :ok
  defp ensure_instance_profile_role_slot(%InstanceProfile{role_arn: ""}, _role_arn), do: :ok

  defp ensure_instance_profile_role_slot(%InstanceProfile{role_arn: role_arn}, role_arn),
    do: {:error, :already_exists}

  defp ensure_instance_profile_role_slot(%InstanceProfile{}, _role_arn),
    do: {:error, :instance_profile_role_limit_exceeded}

  defp default_instance_profile_arn(path, instance_profile_name)
       when is_binary(path) and path != "" and is_binary(instance_profile_name) and
              instance_profile_name != "",
       do: instance_profile_arn(path, instance_profile_name)

  defp default_instance_profile_arn(_path, _instance_profile_name), do: nil

  defp instance_profile_resource_path("/", instance_profile_name), do: instance_profile_name

  defp instance_profile_resource_path("/" <> path_body, instance_profile_name),
    do: path_body <> instance_profile_name

  defp default_server_certificate_arn(path, server_certificate_name)
       when is_binary(path) and path != "" and is_binary(server_certificate_name) and
              server_certificate_name != "",
       do: server_certificate_arn(path, server_certificate_name)

  defp default_server_certificate_arn(_path, _server_certificate_name), do: nil

  defp server_certificate_resource_path("/", server_certificate_name), do: server_certificate_name

  defp server_certificate_resource_path("/" <> path_body, server_certificate_name),
    do: path_body <> server_certificate_name

  defp server_certificate_changeset_error(%Ecto.Changeset{} = changeset) do
    cond do
      changeset_has_validation?(changeset, :private_key, :key_pair_mismatch) ->
        :key_pair_mismatch

      changeset_has_validation?(changeset, :certificate_body, :malformed_certificate) ->
        :malformed_certificate

      changeset_has_unique_error?(changeset, :server_certificate_name) ->
        :server_certificate_already_exists

      changeset_has_unique_error?(changeset, :server_certificate_arn) ->
        :server_certificate_already_exists

      true ->
        changeset
    end
  end

  defp signing_certificate_changeset_error(%Ecto.Changeset{} = changeset) do
    cond do
      changeset_has_validation?(changeset, :certificate_body, :malformed_certificate) ->
        :malformed_certificate

      changeset_has_unique_error?(changeset, :certificate_fingerprint_sha256) ->
        :duplicate_certificate

      changeset_has_unique_error?(changeset, :certificate_id) ->
        :already_exists

      true ->
        changeset
    end
  end

  defp ssh_public_key_changeset_error(%Ecto.Changeset{} = changeset) do
    cond do
      changeset_has_validation?(changeset, :ssh_public_key_body, :invalid_public_key) ->
        :invalid_public_key

      changeset_has_unique_error?(changeset, :fingerprint_md5) ->
        :duplicate_ssh_public_key

      changeset_has_unique_error?(changeset, :ssh_public_key_id) ->
        :already_exists

      true ->
        changeset
    end
  end

  defp changeset_has_validation?(%Ecto.Changeset{} = changeset, field, validation) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :validation) == validation
      _other -> false
    end)
  end

  defp attach_user_managed_policy_with_quota(user_arn, policy_arn) do
    attach_managed_policy_with_quota(
      user_arn,
      policy_arn,
      @user_managed_policy_attachment_quota,
      &Store.list_attached_user_managed_policies/1,
      &Store.attach_user_managed_policy/2
    )
  end

  defp attach_group_managed_policy_with_quota(group_arn, policy_arn) do
    attach_managed_policy_with_quota(
      group_arn,
      policy_arn,
      @group_managed_policy_attachment_quota,
      &Store.list_attached_group_managed_policies/1,
      &Store.attach_group_managed_policy/2
    )
  end

  defp attach_role_managed_policy_with_quota(role_arn, policy_arn) do
    attach_managed_policy_with_quota(
      role_arn,
      policy_arn,
      @role_managed_policy_attachment_quota,
      &Store.list_attached_role_managed_policies/1,
      &Store.attach_role_managed_policy/2
    )
  end

  defp attach_managed_policy_with_quota(
         principal_arn,
         policy_arn,
         quota,
         list_attached_fun,
         attach_fun
       ) do
    Repo.transaction(fn ->
      lock_principal_policy_quota!(principal_arn)
      lock_managed_policy!(policy_arn)

      with :ok <- require_existing_managed_policy(policy_arn) do
        attached_policy_arns =
          list_attached_fun.(principal_arn)
          |> Enum.map(& &1.policy_arn)
          |> MapSet.new()

        cond do
          MapSet.member?(attached_policy_arns, policy_arn) ->
            attach_fun.(principal_arn, policy_arn)

          MapSet.size(attached_policy_arns) < quota ->
            attach_fun.(principal_arn, policy_arn)

          true ->
            Repo.rollback({:error, :policy_limit_exceeded})
        end
        |> case do
          :ok -> :ok
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      else
        {:error, reason} -> Repo.rollback({:error, reason})
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp detach_managed_policy_with_policy_lock(principal_arn, policy_arn, detach_fun, opts \\ [])

  defp detach_managed_policy_with_policy_lock(principal_arn, policy_arn, detach_fun, opts)
       when is_function(detach_fun, 2) do
    Repo.transaction(fn ->
      lock_managed_policy!(policy_arn)

      with :ok <- maybe_require_existing_managed_policy(policy_arn, opts) do
        detach_fun.(principal_arn, policy_arn)
      else
        {:error, reason} -> Repo.rollback({:error, reason})
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_require_existing_managed_policy(policy_arn, opts) do
    if Keyword.get(opts, :require_policy, false) do
      require_existing_managed_policy(policy_arn)
    else
      :ok
    end
  end

  defp delete_managed_policy_row_strict(policy_arn) do
    Repo.transaction(fn ->
      lock_managed_policy!(policy_arn)

      with :ok <- require_existing_managed_policy(policy_arn),
           :ok <- Store.delete_managed_session_policy(policy_arn) do
        :ok
      else
        {:error, reason} -> Repo.rollback({:error, reason})
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tag_managed_policy_row_strict(policy_arn, tags) do
    Repo.transaction(fn ->
      lock_managed_policy!(policy_arn)

      with :ok <- require_existing_managed_policy(policy_arn),
           :ok <- Store.tag_managed_session_policy(policy_arn, tags) do
        :ok
      else
        {:error, reason} -> Repo.rollback({:error, reason})
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp untag_managed_policy_row_strict(policy_arn, tag_keys) do
    Repo.transaction(fn ->
      lock_managed_policy!(policy_arn)

      with :ok <- require_existing_managed_policy(policy_arn),
           :ok <- Store.untag_managed_session_policy(policy_arn, tag_keys) do
        :ok
      else
        {:error, reason} -> Repo.rollback({:error, reason})
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_existing_managed_policy(policy_arn) do
    case Store.managed_session_policy(policy_arn) do
      {:ok, _json} -> :ok
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_managed_policy_row_strict(policy_arn, json, attrs) do
    Repo.transaction(fn ->
      lock_managed_policy_quota!()

      with :ok <- reject_existing_managed_policy(policy_arn),
           :ok <- validate_managed_policy_account_quota(),
           :ok <- Store.create_managed_session_policy(policy_arn, json, attrs) do
        :ok
      else
        {:error, reason} -> Repo.rollback({:error, reason})
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_existing_managed_policy(policy_arn) do
    case Store.managed_session_policy(policy_arn) do
      {:ok, _json} -> {:error, :already_exists}
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_managed_policy_account_quota do
    if length(Store.list_managed_session_policies()) < @managed_policy_account_quota do
      :ok
    else
      {:error, :policy_limit_exceeded}
    end
  end

  defp validate_managed_policy_description(description) when is_binary(description) do
    if String.length(description) <= 1000 do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp validate_managed_policy_description(_description), do: {:error, :malformed}

  defp validate_managed_policy_tags(tags) when is_map(tags) do
    tags
    |> Tags.map_to_list()
    |> Tags.validate(:bucket)
  end

  defp validate_managed_policy_tags(_tags), do: {:error, :invalid_tag}

  defp validate_managed_policy_tag_keys(tag_keys) when is_list(tag_keys) do
    tag_keys
    |> Enum.map(&{to_string(&1), ""})
    |> Tags.validate(:bucket)
  end

  defp validate_managed_policy_tag_keys(_tag_keys), do: {:error, :invalid_tag}

  defp validate_policy_entity_filter(filter) when filter in @policy_entity_filters, do: :ok
  defp validate_policy_entity_filter(_filter), do: {:error, :malformed}

  defp validate_policy_usage_filter(filter) when filter in @policy_usage_filters, do: :ok
  defp validate_policy_usage_filter(_filter), do: {:error, :malformed}

  defp validate_iam_entity_path_prefix(path_prefix) when is_binary(path_prefix) do
    cond do
      byte_size(path_prefix) > 512 ->
        {:error, :malformed}

      not String.starts_with?(path_prefix, "/") or not String.ends_with?(path_prefix, "/") ->
        {:error, :malformed}

      not iam_entity_path_chars?(path_prefix) ->
        {:error, :malformed}

      true ->
        :ok
    end
  end

  defp validate_iam_entity_path_prefix(_path_prefix), do: {:error, :malformed}

  defp iam_entity_path_chars?(path) do
    path
    |> String.to_charlist()
    |> Enum.all?(fn char -> char >= 0x21 and char <= 0x7E end)
  end

  defp filter_managed_policy_entities(entities, entity_filter, path_prefix) do
    empty = %{users: [], groups: [], roles: []}

    if path_prefix != "/" do
      empty
    else
      %{
        users:
          entities
          |> Map.get(:users, [])
          |> maybe_policy_entities(entity_filter in ["All", "User"]),
        groups:
          entities
          |> Map.get(:groups, [])
          |> maybe_policy_entities(entity_filter in ["All", "Group"]),
        roles:
          entities
          |> Map.get(:roles, [])
          |> maybe_policy_entities(entity_filter in ["All", "Role"])
      }
    end
  end

  defp maybe_policy_entities(entities, true), do: entities
  defp maybe_policy_entities(_entities, false), do: []

  defp validate_managed_policy_document(json) when is_binary(json) do
    cond do
      String.length(json) < 1 or String.length(json) > @managed_policy_document_max_chars ->
        {:error, :malformed_policy_document}

      not inline_policy_document_chars?(json) ->
        {:error, :malformed_policy_document}

      true ->
        with {:ok, statements} <- Statement.parse_identity_policy(json),
             true <- statements != [],
             {:ok, %{} = document} <- Jason.decode(json),
             policy_chars = inline_policy_document_size(document),
             true <- policy_chars <= @managed_policy_document_quota_chars do
          {:ok, document, policy_chars}
        else
          false -> {:error, :policy_limit_exceeded}
          _other -> {:error, :malformed_policy_document}
        end
    end
  end

  defp validate_managed_policy_document(_json), do: {:error, :malformed_policy_document}

  defp lock_managed_policy_quota! do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      ["maxio.managed_policies", "account"]
    )

    :ok
  end

  defp put_inline_policy_strict(principal_arn, name, json, quota_chars) do
    with {:ok, _document, policy_chars} <- validate_inline_policy_document(json) do
      Repo.transaction(fn ->
        lock_principal_policy_quota!(principal_arn)

        with :ok <- validate_inline_policy_quota(principal_arn, name, policy_chars, quota_chars),
             :ok <- put_principal_policy(principal_arn, name, json) do
          :ok
        else
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, {:error, :malformed}} -> {:error, :malformed_policy_document}
        {:error, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    else
      # `validate_inline_policy_document/1` 唯一的失败原因就是 `:malformed`
      # （三个分支——超长、非法字符、解析失败——都返回它），因此下面那条
      # `{:error, reason} -> {:error, reason}` 恒不可达且只是恒等映射，删除。
      {:error, :malformed} -> {:error, :malformed_policy_document}
    end
  end

  defp lock_principal_policy_quota!(principal_arn) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      ["maxio.principal_policies", principal_arn]
    )

    :ok
  end

  defp access_key_transaction_result({:ok, access_key}), do: {:ok, access_key}
  defp access_key_transaction_result({:error, {:error, reason}}), do: {:error, reason}
  defp access_key_transaction_result({:error, reason}), do: {:error, reason}

  defp notify_access_key_result({:ok, %{access_key_id: access_key_id}} = result) do
    Notify.broadcast({:iam_changed, access_key_id})
    result
  end

  defp notify_access_key_result({:error, _reason} = error), do: error

  defp minio_user_transaction_result(
         {:ok, %{user: %User{} = user, access_key: %AccessKey{} = access_key}},
         access_key_id
       ) do
    Notify.broadcast({:iam_changed, access_key_id})
    {:ok, %{user: public_user(user), access_key: public_access_key(access_key)}}
  end

  defp minio_user_transaction_result(
         {:error, :identity, :user_already_exists, _changes},
         _access_key_id
       ),
       do: {:error, :user_already_exists}

  defp minio_user_transaction_result(
         {:error, :locks, :user_already_exists, _changes},
         _access_key_id
       ),
       do: {:error, :user_already_exists}

  defp minio_user_transaction_result(
         {:error, operation, %Ecto.Changeset{} = changeset, _changes},
         _access_key_id
       )
       when operation in [:user, :access_key] do
    if unique_constraint_error?(changeset) do
      {:error, :user_already_exists}
    else
      {:error, changeset}
    end
  end

  defp minio_user_transaction_result({:error, _operation, reason, _changes}, _access_key_id),
    do: {:error, reason}

  defp unique_constraint_error?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      Keyword.get(metadata, :constraint) == :unique
    end)
  end

  defp signing_certificate_transaction_result({:ok, certificate}), do: {:ok, certificate}
  defp signing_certificate_transaction_result({:error, {:error, reason}}), do: {:error, reason}
  defp signing_certificate_transaction_result({:error, reason}), do: {:error, reason}

  defp ssh_public_key_transaction_result({:ok, ssh_public_key}), do: {:ok, ssh_public_key}
  defp ssh_public_key_transaction_result({:error, {:error, reason}}), do: {:error, reason}
  defp ssh_public_key_transaction_result({:error, reason}), do: {:error, reason}

  defp lock_access_key_principal!(principal_arn) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      ["maxio.access_keys", principal_arn]
    )

    :ok
  end

  defp credential_identity_snapshot(principal_arn) do
    case UserIdentity.local_user_name(principal_arn) do
      {:ok, user_name} ->
        {user_name, principal_arn, UserIdentity.snapshot(Repo, user_name)}

      :not_local_user ->
        :not_local_user
    end
  end

  defp lock_credential_identity(:not_local_user, _opts), do: :ok

  defp lock_credential_identity({user_name, principal_arn, snapshot}, opts) do
    case UserIdentity.lock_snapshot(Repo, user_name, snapshot) do
      {:ok, %User{user_arn: ^principal_arn, status: "active"}} ->
        :ok

      {:ok, %User{user_arn: ^principal_arn}} ->
        if Keyword.get(opts, :require_active, false), do: {:error, :user_inactive}, else: :ok

      {:ok, %User{}} ->
        {:error, :identity_changed}

      {:ok, :missing} ->
        if Keyword.get(opts, :allow_missing, false),
          do: :ok,
          else: {:error, :user_not_found}

      {:error, :user_not_found} ->
        {:error, :user_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_signing_certificate_principal!(principal_key) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      ["maxio.signing_certificates", principal_key]
    )

    :ok
  end

  defp lock_ssh_public_key_user!(user_arn) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      ["maxio.ssh_public_keys", user_arn]
    )

    :ok
  end

  defp lock_managed_policy!(policy_arn) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      ["maxio.managed_policy", policy_arn]
    )

    :ok
  end

  defp validate_inline_policy_document(json) when is_binary(json) do
    cond do
      String.length(json) < 1 or String.length(json) > @inline_policy_document_max_chars ->
        {:error, :malformed}

      not inline_policy_document_chars?(json) ->
        {:error, :malformed}

      true ->
        with {:ok, statements} <- Statement.parse_identity_policy(json),
             true <- statements != [],
             {:ok, %{} = document} <- Jason.decode(json) do
          {:ok, document, inline_policy_document_size(document)}
        else
          _ -> {:error, :malformed}
        end
    end
  end

  defp validate_inline_policy_document(_json), do: {:error, :malformed}

  defp inline_policy_document_chars?(json) do
    json
    |> String.to_charlist()
    |> Enum.all?(fn
      char when char in [?\t, ?\n, ?\r] -> true
      char when char >= 0x20 and char <= 0xFF -> true
      _char -> false
    end)
  end

  defp validate_inline_policy_quota(principal_arn, name, policy_chars, quota_chars) do
    total =
      principal_arn
      |> list_principal_policies()
      |> Enum.reject(&(&1.policy_name == name))
      |> Enum.map(&inline_policy_document_size(&1.document))
      |> Enum.sum()
      |> Kernel.+(policy_chars)

    if total <= quota_chars do
      :ok
    else
      {:error, :policy_limit_exceeded}
    end
  end

  defp inline_policy_document_size(%{} = document) do
    document
    |> Jason.encode!()
    |> String.length()
  end

  defp merge_user_tags(existing_tags, new_tags) do
    merge_case_insensitive_tags(existing_tags, new_tags)
  end

  defp merge_case_insensitive_tags(existing_tags, new_tags) do
    new_tags = normalize_tags(new_tags)
    new_keys = new_tags |> Map.keys() |> Enum.map(&String.downcase/1) |> MapSet.new()

    existing_tags
    |> normalize_tags()
    |> Enum.reject(fn {key, _value} -> MapSet.member?(new_keys, String.downcase(key)) end)
    |> Map.new()
    |> Map.merge(new_tags)
  end

  defp merge_case_sensitive_tags(existing_tags, new_tags) do
    existing_tags
    |> normalize_tags()
    |> Map.merge(normalize_tags(new_tags))
  end

  defp drop_user_tags(existing_tags, tag_keys) do
    drop_case_insensitive_tags(existing_tags, tag_keys)
  end

  defp drop_case_insensitive_tags(existing_tags, tag_keys) do
    drop_keys =
      tag_keys
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    existing_tags
    |> normalize_tags()
    |> Enum.reject(fn {key, _value} -> MapSet.member?(drop_keys, String.downcase(key)) end)
    |> Map.new()
  end

  defp drop_case_sensitive_tags(existing_tags, tag_keys) do
    existing_tags
    |> normalize_tags()
    |> Map.drop(Enum.map(tag_keys, &to_string/1))
  end

  defp public_group(%Group{} = group) do
    %{
      id: group.id,
      group_name: group.group_name,
      group_arn: group.group_arn,
      status: group.status,
      tags: group.tags || %{},
      inserted_at: group.inserted_at,
      updated_at: group.updated_at
    }
  end

  defp normalize_oidc_issuer_url(nil), do: nil

  defp normalize_oidc_issuer_url(issuer_url) when is_binary(issuer_url),
    do: issuer_url |> String.trim() |> String.trim_trailing("/")

  defp normalize_oidc_issuer_url(issuer_url),
    do: issuer_url |> to_string() |> normalize_oidc_issuer_url()

  defp normalize_oidc_string_list(nil), do: []

  defp normalize_oidc_string_list(values) when is_list(values) do
    Enum.map(values, fn
      value when is_binary(value) -> String.trim(value)
      value -> to_string(value)
    end)
  end

  defp normalize_oidc_string_list(value) when is_binary(value), do: [String.trim(value)]
  defp normalize_oidc_string_list(value), do: [to_string(value)]

  defp oidc_provider_discovery(issuer_url, opts) do
    case Keyword.get(opts, :jwks) do
      %{} = jwks ->
        {:ok,
         %{
           jwks: jwks,
           jwks_fetched_at: Keyword.get(opts, :jwks_fetched_at, utc_now()),
           discovery_document: Keyword.get(opts, :discovery_document, %{})
         }}

      nil ->
        discover_oidc_provider(issuer_url, opts)

      _other ->
        {:error, :identity_provider_keys_malformed}
    end
  end

  defp effective_oidc_thumbprints(configured_thumbprints, discovery) do
    discovered_thumbprints = oidc_discovery_thumbprints(discovery)

    cond do
      configured_thumbprints == [] and discovered_thumbprints != [] ->
        {:ok, discovered_thumbprints}

      configured_thumbprints == [] ->
        {:ok, configured_thumbprints}

      oidc_thumbprints_cover?(configured_thumbprints, discovered_thumbprints) ->
        {:ok, configured_thumbprints}

      true ->
        {:error, :oidc_discovery_thumbprint_mismatch}
    end
  end

  defp oidc_discovery_thumbprints(discovery) when is_map(discovery) do
    discovery
    |> map_get(:thumbprints)
    |> normalize_oidc_string_list()
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp oidc_discovery_thumbprints(_discovery), do: []

  defp oidc_thumbprints_cover?(_configured_thumbprints, []), do: true

  defp oidc_thumbprints_cover?(configured_thumbprints, discovered_thumbprints) do
    configured =
      configured_thumbprints
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    Enum.all?(discovered_thumbprints, &MapSet.member?(configured, String.downcase(&1)))
  end

  defp discover_oidc_provider(issuer_url, opts) do
    discoverer =
      Keyword.get(
        opts,
        :discoverer,
        Application.get_env(:maxio, :oidc_discovery, Maxio.IAM.OIDCDiscovery.HTTP)
      )

    discovery_opts =
      opts
      |> Keyword.get(:discovery_opts, [])
      |> put_discovery_thumbprints(Keyword.get(opts, :thumbprints, []))

    with true <- is_atom(discoverer),
         {:module, ^discoverer} <- Code.ensure_loaded(discoverer),
         true <- function_exported?(discoverer, :discover, 2) do
      discoverer.discover(issuer_url, discovery_opts)
    else
      _other -> {:error, :invalid_oidc_discovery_provider}
    end
  end

  defp put_discovery_thumbprints(discovery_opts, thumbprints) do
    case normalize_oidc_string_list(thumbprints) do
      [] -> discovery_opts
      normalized -> Keyword.put(discovery_opts, :thumbprints, normalized)
    end
  end

  defp fetch_oidc_provider("arn:aws:iam:::oidc-provider/" <> _resource = provider_arn) do
    case Repo.get_by(OIDCProvider, provider_arn: provider_arn) do
      %OIDCProvider{} = provider -> {:ok, provider}
      nil -> :error
    end
  end

  defp fetch_oidc_provider(issuer_url) when is_binary(issuer_url) do
    issuer_url = normalize_oidc_issuer_url(issuer_url)

    case Maxio.STS.WebIdentity.issuer_host_path(issuer_url) do
      {:ok, issuer_host_path} ->
        case Repo.get_by(OIDCProvider, issuer_host_path: issuer_host_path) do
          %OIDCProvider{} = provider -> {:ok, provider}
          nil -> :error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_oidc_provider(provider_arn_or_url, fun) when is_function(fun, 1) do
    with {:ok, %OIDCProvider{} = provider} <- fetch_oidc_provider(provider_arn_or_url),
         {:ok, updated} <- provider |> fun.() |> Repo.update() do
      Notify.broadcast({:iam_changed, updated.provider_arn})
      {:ok, public_oidc_provider(updated)}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp public_oidc_provider(%OIDCProvider{} = provider) do
    %{
      id: provider.id,
      provider_arn: provider.provider_arn,
      issuer_url: provider.issuer_url,
      issuer_host_path: provider.issuer_host_path,
      client_ids: provider.client_ids || [],
      thumbprints: provider.thumbprints || [],
      jwks: OIDCProvider.public_jwks(provider.jwks || %{}),
      jwks_fetched_at: provider.jwks_fetched_at,
      discovery_document: provider.discovery_document || %{},
      status: provider.status,
      tags: provider.tags || %{},
      inserted_at: provider.inserted_at,
      updated_at: provider.updated_at
    }
  end

  defp web_identity_provider_projection(%OIDCProvider{} = provider) do
    %{
      issuer: provider.issuer_url,
      client_ids: provider.client_ids || [],
      jwks: OIDCProvider.public_jwks(provider.jwks || %{}),
      provider: provider.issuer_url
    }
  end

  defp normalize_tags(tags) when is_map(tags) do
    Map.new(tags, fn {key, value} -> {to_string(key), tag_value(value)} end)
  end

  defp normalize_tags(_tags), do: %{}

  defp tag_value(nil), do: ""
  defp tag_value(value), do: to_string(value)

  # 两支子句合并成一个总函数：非 map 仍然回落到 nil（逐字不变），但这条分支不再因为
  # 调用方已收窄成 map 而变成死代码。
  defp map_get(map, key) do
    if is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_iam_text(nil), do: nil
  defp normalize_iam_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_iam_text(value), do: to_string(value)

  defp default_mfa_serial(device_name) do
    safe_name = device_name |> to_string() |> String.trim() |> String.replace(~r/\s+/, "-")
    "arn:aws:iam:::mfa/#{safe_name}"
  end

  defp normalize_mfa_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_mfa_text(value), do: to_string(value)

  defp principal_type_for(@root_principal_arn), do: "root"
  defp principal_type_for(_principal_arn), do: "iam_user"

  defp maybe_filter_principal(query, nil), do: query

  defp maybe_filter_principal(query, principal_arn),
    do: where(query, [d], d.principal_arn == ^principal_arn)

  defp fetch_mfa_device(serial) when is_binary(serial) do
    case Repo.get_by(MFADevice, serial: serial) do
      nil -> {:error, :mfa_device_not_found}
      device -> {:ok, device}
    end
  end

  defp fetch_mfa_device(_serial), do: {:error, :mfa_device_not_found}

  defp require_status(%MFADevice{status: status}, status, _reason), do: :ok
  defp require_status(%MFADevice{}, _status, reason), do: {:error, reason}

  defp require_principal_match(%MFADevice{principal_arn: principal_arn}, principal_arn), do: :ok

  defp require_principal_match(%MFADevice{}, _principal_arn),
    do: {:error, :mfa_principal_mismatch}

  defp principal_arn(%{arn: arn}) when is_binary(arn), do: {:ok, arn}
  defp principal_arn(%{"arn" => arn}) when is_binary(arn), do: {:ok, arn}
  defp principal_arn(arn) when is_binary(arn), do: {:ok, arn}
  defp principal_arn(_principal), do: {:error, :invalid_mfa_principal}

  defp totp_opts(%MFADevice{} = device, opts) do
    [
      algorithm: device.algorithm,
      digits: device.digits,
      period_seconds: device.period_seconds,
      drift_steps: device.drift_steps
    ]
    |> maybe_put_time(opts)
  end

  defp maybe_put_time(totp_opts, opts) do
    case Keyword.fetch(opts, :time) do
      {:ok, time} -> Keyword.put(totp_opts, :time, time)
      :error -> totp_opts
    end
  end

  defp authorize_mfa_enable_principal(
         %MFADevice{principal_arn: principal_arn},
         principal_arn,
         _opts
       ),
       do: :ok

  defp authorize_mfa_enable_principal(%MFADevice{}, _principal_arn, opts) do
    if Keyword.get(opts, :allow_reassign, false) do
      :ok
    else
      {:error, :mfa_principal_mismatch}
    end
  end

  defp match_consecutive_mfa_codes(%MFADevice{} = device, code1, code2, opts) do
    with {:ok, secret_base32} <- MFASecret.unwrap(device.secret_envelope, device.serial),
         {:ok, step1, _offset1} <- TOTP.match(secret_base32, code1, totp_opts(device, opts)),
         {:ok, step2, _offset2} <- TOTP.match(secret_base32, code2, totp_opts(device, opts)) do
      if fresh_mfa_pair?(device, step1) and step2 == step1 + 1 do
        {:ok, step1, step2}
      else
        {:error, :mfa_consecutive_codes_required}
      end
    end
  end

  defp with_mfa_user_identities(principal_arns, fun) when is_function(fun, 0) do
    identities =
      principal_arns
      |> Enum.uniq()
      |> Enum.flat_map(fn principal_arn ->
        case UserIdentity.local_user_name(principal_arn) do
          {:ok, user_name} ->
            [{user_name, principal_arn, UserIdentity.snapshot(Repo, user_name)}]

          :not_local_user ->
            []
        end
      end)

    if Enum.any?(identities, fn {_name, _arn, snapshot} -> snapshot == :missing end) do
      {:error, :user_not_found}
    else
      run_mfa_identity_transaction(identities, fun)
    end
  end

  defp run_mfa_identity_transaction([], fun), do: fun.()

  defp run_mfa_identity_transaction(identities, fun) do
    transaction_fun = fn ->
      named_snapshots = Enum.map(identities, fn {name, _arn, snapshot} -> {name, snapshot} end)

      with {:ok, rows} <- UserIdentity.lock_snapshots(Repo, named_snapshots),
           true <-
             Enum.zip(identities, rows)
             |> Enum.all?(fn {{_name, principal_arn, _snapshot}, row} ->
               match?(%User{user_arn: ^principal_arn}, row)
             end) do
        case fun.() do
          {:error, reason} -> Repo.rollback({:operation_error, reason})
          result -> result
        end
      else
        false -> Repo.rollback({:identity_error, :identity_changed})
        {:error, reason} -> Repo.rollback({:identity_error, reason})
      end
    end

    if Repo.in_transaction?() do
      transaction_fun.()
    else
      case Repo.transaction(transaction_fun) do
        {:ok, result} -> result
        {:error, {:operation_error, reason}} -> {:error, reason}
        {:error, {:identity_error, :user_not_found}} -> {:error, :user_not_found}
        {:error, {:identity_error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fresh_mfa_pair?(%MFADevice{last_accepted_step: nil}, _step1), do: true
  defp fresh_mfa_pair?(%MFADevice{last_accepted_step: last_step}, step1), do: last_step < step1

  defp activate_mfa_device_step(%MFADevice{} = device, matched_step) do
    now = utc_now()

    {count, _rows} =
      from(d in MFADevice,
        where:
          d.id == ^device.id and d.status == "pending" and
            (is_nil(d.last_accepted_step) or d.last_accepted_step < ^matched_step)
      )
      |> Repo.update_all(
        set: [
          status: "active",
          confirmed_at: now,
          last_used_at: now,
          last_accepted_step: matched_step,
          updated_at: now
        ]
      )

    case count do
      1 -> {:ok, Repo.get!(MFADevice, device.id)}
      _other -> {:error, :mfa_code_replayed}
    end
  end

  defp enable_mfa_device_steps(%MFADevice{} = device, principal_arn, first_step, matched_step) do
    now = utc_now()

    {count, _rows} =
      from(d in MFADevice,
        where:
          d.id == ^device.id and d.status == "pending" and
            (is_nil(d.last_accepted_step) or d.last_accepted_step < ^first_step)
      )
      |> Repo.update_all(
        set: [
          principal_arn: principal_arn,
          principal_type: principal_type_for(principal_arn),
          status: "active",
          confirmed_at: now,
          last_used_at: now,
          last_accepted_step: matched_step,
          updated_at: now
        ]
      )

    case count do
      1 -> {:ok, Repo.get!(MFADevice, device.id)}
      _other -> {:error, :mfa_code_replayed}
    end
  end

  defp resync_mfa_device_steps(%MFADevice{} = device, first_step, matched_step) do
    now = utc_now()

    {count, _rows} =
      from(d in MFADevice,
        where:
          d.id == ^device.id and d.status == "active" and
            (is_nil(d.last_accepted_step) or d.last_accepted_step < ^first_step)
      )
      |> Repo.update_all(
        set: [last_accepted_step: matched_step, last_used_at: now, updated_at: now]
      )

    case count do
      1 -> {:ok, Repo.get!(MFADevice, device.id)}
      _other -> {:error, :mfa_code_replayed}
    end
  end

  defp consume_mfa_step(%MFADevice{} = device, matched_step) do
    now = utc_now()

    {count, _rows} =
      from(d in MFADevice,
        where:
          d.id == ^device.id and d.status == "active" and
            (is_nil(d.last_accepted_step) or d.last_accepted_step < ^matched_step)
      )
      |> Repo.update_all(
        set: [last_accepted_step: matched_step, last_used_at: now, updated_at: now]
      )

    case count do
      1 -> :ok
      _other -> {:error, :mfa_code_replayed}
    end
  end

  defp authorize_mfa_disable(%MFADevice{status: "pending"}, _opts), do: :ok
  defp authorize_mfa_disable(%MFADevice{status: "disabled"}, _opts), do: :ok

  defp authorize_mfa_disable(%MFADevice{} = device, opts) do
    cond do
      Keyword.get(opts, :force, false) ->
        :ok

      is_binary(Keyword.get(opts, :code)) ->
        verify_mfa_device(device.principal_arn, device.serial, Keyword.fetch!(opts, :code),
          consume: true,
          time: Keyword.get(opts, :time, DateTime.utc_now())
        )

      true ->
        {:error, :mfa_code_required}
    end
  end

  defp disable_mfa_device_row(%MFADevice{} = device) do
    now = utc_now()

    device
    |> Ecto.Changeset.change(status: "disabled", disabled_at: now)
    |> Repo.update()
  end

  defp public_mfa_device(%MFADevice{} = device) do
    %{
      id: device.id,
      principal_arn: device.principal_arn,
      principal_type: device.principal_type,
      serial: device.serial,
      device_name: device.device_name,
      kind: device.kind,
      status: device.status,
      algorithm: device.algorithm,
      digits: device.digits,
      period_seconds: device.period_seconds,
      drift_steps: device.drift_steps,
      confirmed_at: device.confirmed_at,
      last_used_at: device.last_used_at,
      disabled_at: device.disabled_at,
      inserted_at: device.inserted_at,
      updated_at: device.updated_at
    }
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
