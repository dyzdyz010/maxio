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
  alias Maxio.IAM.{AccessKey, MFADevice, MFASecret, Role, TOTP}
  alias Maxio.Policy.Store

  @root_principal_arn "arn:aws:iam:::root"
  @default_mfa_device_name "root-account-mfa-device"
  @managed_policy_name_pattern ~r/\A[A-Za-z0-9+=,.@_-]+\z/
  @managed_policy_path_segment_pattern ~r/\A[A-Za-z0-9.,+@=_-]+\z/

  @doc "从 config :maxio, :s3 的 root_user/root_password 幂等引导 root（boot 调用）。"
  @spec bootstrap_root() :: :ok
  def bootstrap_root do
    s3 = Application.fetch_env!(:maxio, :s3)
    ak = Keyword.fetch!(s3, :root_user)
    sk = Keyword.fetch!(s3, :root_password)

    %AccessKey{}
    |> AccessKey.changeset(%{
      access_key_id: ak,
      secret_key: sk,
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

  @doc "创建 access key。opts: :access_key_id（默认随机）、:secret_key（默认随机）、:type（默认 iam_user）。"
  @spec create_access_key(keyword()) :: {:ok, map()} | {:error, term()}
  def create_access_key(opts \\ []) do
    ak = Keyword.get(opts, :access_key_id) || gen_access_key_id()
    sk = Keyword.get(opts, :secret_key) || gen_secret_key()
    type = Keyword.get(opts, :type, "iam_user")
    tags = opts |> Keyword.get(:tags, %{}) |> normalize_tags()
    arn = if type == "root", do: @root_principal_arn, else: "arn:aws:iam:::user/#{ak}"

    case %AccessKey{}
         |> AccessKey.changeset(%{
           access_key_id: ak,
           secret_key: sk,
           principal_arn: arn,
           type: type,
           status: "active",
           tags: tags
         })
         |> Repo.insert() do
      {:ok, row} ->
        Notify.broadcast({:iam_changed, row.access_key_id})

        {:ok,
         %{
           access_key_id: row.access_key_id,
           secret_key: sk,
           principal_arn: arn,
           type: type,
           tags: tags
         }}

      {:error, cs} ->
        {:error, cs}
    end
  end

  @doc "列出全部 access key（不回 secret）。"
  @spec list_access_keys() :: [map()]
  def list_access_keys do
    Repo.all(from a in AccessKey, order_by: [asc: a.inserted_at])
    |> Enum.map(fn a ->
      %{
        access_key_id: a.access_key_id,
        principal_arn: a.principal_arn,
        type: a.type,
        status: a.status,
        tags: a.tags || %{}
      }
    end)
  end

  @doc "删除 access key（幂等）。拒绝删除最后一个 root（避免锁死，铁律 3 不静默放行也不让系统不可用）。"
  @spec delete_access_key(String.t()) :: :ok | {:error, :cannot_delete_last_root}
  def delete_access_key(access_key_id) do
    case Repo.get_by(AccessKey, access_key_id: access_key_id) do
      nil ->
        Notify.broadcast({:iam_changed, access_key_id})
        :ok

      %AccessKey{type: "root"} = row ->
        root_count = Repo.aggregate(from(a in AccessKey, where: a.type == "root"), :count, :id)

        if root_count <= 1 do
          {:error, :cannot_delete_last_root}
        else
          Repo.delete!(row)
          Notify.broadcast({:iam_changed, access_key_id})
          :ok
        end

      %AccessKey{} = row ->
        Repo.delete!(row)
        Notify.broadcast({:iam_changed, access_key_id})
        :ok
    end
  end

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

  The policy can be referenced by STS AssumeRole `PolicyArns`. Attaching
  managed policies to users/groups/roles as identity policy is intentionally a
  separate future IAM feature.
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
      {:ok, Map.put(metadata, :document, document)}
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

    if validate_managed_policy_path(path_prefix) == :ok do
      Store.list_managed_session_policies()
      |> Enum.flat_map(&managed_policy_listing/1)
      |> Enum.filter(&String.starts_with?(&1.path, path_prefix))
    else
      []
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

  @doc "Attaches a local managed policy to a role as role identity policy."
  @spec attach_role_policy(String.t(), String.t()) :: :ok | {:error, term()}
  def attach_role_policy(role_arn, policy_arn)
      when is_binary(role_arn) and is_binary(policy_arn) do
    with {:ok, _role} <- get_role_by_arn(role_arn),
         :ok <- validate_managed_policy_arn(policy_arn),
         {:ok, _policy} <- get_managed_policy(policy_arn) do
      Store.attach_role_managed_policy(role_arn, policy_arn)
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
      Store.detach_role_managed_policy(role_arn, policy_arn)
    end
  end

  def detach_role_policy(_role_arn, _policy_arn), do: {:error, :malformed}

  @doc "Returns the single-account root principal ARN used by maxio IAM."
  @spec root_principal_arn() :: String.t()
  def root_principal_arn, do: @root_principal_arn

  @doc "Returns the local single-account IAM role ARN for a role name."
  @spec role_arn(String.t()) :: String.t()
  def role_arn(role_name), do: "arn:aws:iam:::role/#{role_name}"

  @doc "Creates an IAM role with an attached trust policy."
  @spec create_role(keyword()) :: {:ok, map()} | {:error, term()}
  def create_role(opts \\ []) do
    role_name = opts |> Keyword.get(:role_name, Keyword.get(opts, :name)) |> normalize_iam_text()
    role_arn = opts |> Keyword.get(:role_arn, default_role_arn(role_name)) |> normalize_iam_text()

    with {:ok, trust_policy} <-
           normalize_trust_policy(
             Keyword.get(opts, :trust_policy, Keyword.get(opts, :trust_policy_document))
           ) do
      attrs = %{
        role_name: role_name,
        role_arn: role_arn,
        trust_policy: trust_policy,
        max_session_duration_seconds: Keyword.get(opts, :max_session_duration_seconds, 3600),
        tags: opts |> Keyword.get(:tags, %{}) |> normalize_tags()
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

  @doc "Activates a pending TOTP device by verifying and consuming its first code."
  @spec activate_mfa_device(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def activate_mfa_device(serial, code, opts \\ []) do
    with {:ok, device} <- fetch_mfa_device(serial),
         :ok <- require_status(device, "pending", :mfa_device_not_pending),
         {:ok, secret_base32} <- MFASecret.unwrap(device.secret_envelope, device.serial),
         {:ok, matched_step, _offset} <- TOTP.match(secret_base32, code, totp_opts(device, opts)),
         {:ok, updated} <- activate_mfa_device_step(device, matched_step) do
      {:ok, public_mfa_device(updated)}
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
         {:ok, device} <- fetch_mfa_device(serial),
         :ok <- require_status(device, "active", :mfa_device_not_active),
         :ok <- require_principal_match(device, principal_arn),
         {:ok, secret_base32} <- MFASecret.unwrap(device.secret_envelope, device.serial),
         {:ok, matched_step, _offset} <- TOTP.match(secret_base32, code, totp_opts(device, opts)) do
      if Keyword.get(opts, :consume, true) do
        consume_mfa_step(device, matched_step)
      else
        :ok
      end
    end
  end

  @doc "Disables an MFA device while preserving the row for audit."
  @spec disable_mfa_device(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def disable_mfa_device(serial, opts \\ []) do
    with {:ok, device} <- fetch_mfa_device(serial),
         :ok <- authorize_mfa_disable(device, opts),
         {:ok, updated} <- disable_mfa_device_row(device) do
      {:ok, public_mfa_device(updated)}
    end
  end

  @doc "Physically deletes an MFA device row. Active devices require `force: true`."
  @spec delete_mfa_device(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_mfa_device(serial, opts \\ []) do
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
  end

  defp gen_access_key_id,
    do: "AKIA" <> (:crypto.strong_rand_bytes(8) |> Base.encode32(padding: false))

  defp gen_secret_key, do: :crypto.strong_rand_bytes(30) |> Base.encode64() |> binary_part(0, 40)

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
        [Map.merge(policy, metadata)]

      {:error, _reason} ->
        []
    end
  end

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

  defp normalize_trust_policy(%{} = policy) when map_size(policy) > 0, do: {:ok, policy}

  defp normalize_trust_policy(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = policy} -> {:ok, policy}
      _other -> {:error, :malformed_trust_policy}
    end
  end

  defp normalize_trust_policy(_policy), do: {:error, :malformed_trust_policy}

  defp public_role(%Role{} = role) do
    %{
      id: role.id,
      role_name: role.role_name,
      role_arn: role.role_arn,
      trust_policy: role.trust_policy,
      max_session_duration_seconds: role.max_session_duration_seconds,
      tags: role.tags || %{},
      inserted_at: role.inserted_at,
      updated_at: role.updated_at
    }
  end

  defp normalize_tags(tags) when is_map(tags) do
    Map.new(tags, fn {key, value} -> {to_string(key), tag_value(value)} end)
  end

  defp normalize_tags(_tags), do: %{}

  defp tag_value(nil), do: ""
  defp tag_value(value), do: to_string(value)

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
