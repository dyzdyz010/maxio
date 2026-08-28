defmodule Maxio.Policy.Store do
  @moduledoc """
  策略存储 behaviour（铁律 1）。bucket policy 持久化经此抽象；门面按
  config :maxio, :policy_store 派发。MVP 提供 EctoStore（Postgres jsonb）。
  IAM identity policy 通过 principal_arn + policy_name 持久化，授权时由 principal_policies/1
  解析为当前 principal 的隐式身份策略。
  """
  alias Maxio.Cluster.Notify
  alias Maxio.Policy.Statement

  @callback get_bucket_policy(bucket :: String.t()) :: {:ok, binary()} | :none
  @callback put_bucket_policy(bucket :: String.t(), json :: binary()) :: :ok | {:error, term()}
  @callback delete_bucket_policy(bucket :: String.t()) :: :ok
  @callback principal_policies(principal :: map() | :anonymous) :: [Statement.t()]
  @callback principal_permissions_boundary(principal :: map() | :anonymous) ::
              :none | {:ok, [Statement.t()]} | :invalid
  @callback put_principal_policy(
              principal_arn :: String.t(),
              name :: String.t(),
              json :: binary()
            ) ::
              :ok | {:error, term()}
  @callback get_principal_policy(principal_arn :: String.t(), name :: String.t()) ::
              {:ok, map()} | {:error, :not_found | :not_supported | term()}
  @callback delete_principal_policy(principal_arn :: String.t(), name :: String.t()) ::
              :ok | {:error, term()}
  @callback list_principal_policies(principal_arn :: String.t()) :: [map()]
  @callback put_managed_session_policy(policy_arn :: String.t(), json :: binary()) ::
              :ok | {:error, term()}
  @callback create_managed_session_policy(policy_arn :: String.t(), json :: binary()) ::
              :ok | {:error, term()}
  @callback create_managed_session_policy(
              policy_arn :: String.t(),
              json :: binary(),
              attrs :: map()
            ) ::
              :ok | {:error, term()}
  @callback managed_session_policy(policy_arn :: String.t()) ::
              {:ok, binary()} | {:error, :not_found | :malformed | :not_supported}
  @callback delete_managed_session_policy(policy_arn :: String.t()) :: :ok | {:error, term()}
  @callback list_managed_session_policies() :: [map()]
  @callback create_managed_session_policy_version(
              policy_arn :: String.t(),
              json :: binary(),
              set_as_default :: boolean()
            ) ::
              {:ok, map()} | {:error, term()}
  @callback get_managed_session_policy_version(
              policy_arn :: String.t(),
              version_id :: String.t()
            ) ::
              {:ok, map()} | {:error, term()}
  @callback list_managed_session_policy_versions(policy_arn :: String.t()) ::
              {:ok, [map()]} | {:error, term()}
  @callback set_default_managed_session_policy_version(
              policy_arn :: String.t(),
              version_id :: String.t()
            ) ::
              :ok | {:error, term()}
  @callback delete_managed_session_policy_version(
              policy_arn :: String.t(),
              version_id :: String.t()
            ) ::
              :ok | {:error, term()}
  @callback tag_managed_session_policy(policy_arn :: String.t(), tags :: map()) ::
              :ok | {:error, term()}
  @callback untag_managed_session_policy(policy_arn :: String.t(), tag_keys :: [String.t()]) ::
              :ok | {:error, term()}
  @callback list_managed_session_policy_entities(policy_arn :: String.t()) :: map()
  @callback list_managed_session_policy_permissions_boundary_entities(policy_arn :: String.t()) ::
              map()
  @callback attach_role_managed_policy(role_arn :: String.t(), policy_arn :: String.t()) ::
              :ok | {:error, term()}
  @callback detach_role_managed_policy(role_arn :: String.t(), policy_arn :: String.t()) :: :ok
  @callback list_attached_role_managed_policies(role_arn :: String.t()) :: [map()]
  @callback attach_user_managed_policy(user_arn :: String.t(), policy_arn :: String.t()) ::
              :ok | {:error, term()}
  @callback detach_user_managed_policy(user_arn :: String.t(), policy_arn :: String.t()) :: :ok
  @callback list_attached_user_managed_policies(user_arn :: String.t()) :: [map()]
  @callback attach_group_managed_policy(group_arn :: String.t(), policy_arn :: String.t()) ::
              :ok | {:error, term()}
  @callback detach_group_managed_policy(group_arn :: String.t(), policy_arn :: String.t()) :: :ok
  @callback list_attached_group_managed_policies(group_arn :: String.t()) :: [map()]
  @callback managed_session_policy_attached?(policy_arn :: String.t()) :: boolean()
  @callback managed_session_policy_attachment_count(policy_arn :: String.t()) :: non_neg_integer()
  @callback managed_session_policy_permissions_boundary_count(policy_arn :: String.t()) ::
              non_neg_integer()

  @optional_callbacks put_principal_policy: 3,
                      principal_permissions_boundary: 1,
                      get_principal_policy: 2,
                      delete_principal_policy: 2,
                      list_principal_policies: 1,
                      put_managed_session_policy: 2,
                      create_managed_session_policy: 2,
                      create_managed_session_policy: 3,
                      managed_session_policy: 1,
                      delete_managed_session_policy: 1,
                      list_managed_session_policies: 0,
                      create_managed_session_policy_version: 3,
                      get_managed_session_policy_version: 2,
                      list_managed_session_policy_versions: 1,
                      set_default_managed_session_policy_version: 2,
                      delete_managed_session_policy_version: 2,
                      tag_managed_session_policy: 2,
                      untag_managed_session_policy: 2,
                      list_managed_session_policy_entities: 1,
                      list_managed_session_policy_permissions_boundary_entities: 1,
                      attach_role_managed_policy: 2,
                      detach_role_managed_policy: 2,
                      list_attached_role_managed_policies: 1,
                      attach_user_managed_policy: 2,
                      detach_user_managed_policy: 2,
                      list_attached_user_managed_policies: 1,
                      attach_group_managed_policy: 2,
                      detach_group_managed_policy: 2,
                      list_attached_group_managed_policies: 1,
                      managed_session_policy_attached?: 1,
                      managed_session_policy_attachment_count: 1,
                      managed_session_policy_permissions_boundary_count: 1

  @doc "当前配置的策略后端模块。"
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:maxio, :policy_store)

  @spec get_bucket_policy(String.t()) :: {:ok, binary()} | :none
  def get_bucket_policy(bucket), do: impl().get_bucket_policy(bucket)

  @spec put_bucket_policy(String.t(), binary()) :: :ok | {:error, term()}
  def put_bucket_policy(bucket, json) do
    case impl().put_bucket_policy(bucket, json) do
      :ok ->
        Notify.broadcast({:bucket_policy_changed, bucket})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec delete_bucket_policy(String.t()) :: :ok
  def delete_bucket_policy(bucket) do
    :ok = impl().delete_bucket_policy(bucket)
    Notify.broadcast({:bucket_policy_changed, bucket})
    :ok
  end

  @spec principal_policies(map() | :anonymous) :: [Statement.t()]
  def principal_policies(principal), do: impl().principal_policies(principal)

  @spec principal_permissions_boundary(map() | :anonymous) ::
          :none | {:ok, [Statement.t()]} | :invalid
  def principal_permissions_boundary(principal) do
    backend = impl()

    if callback_exported?(backend, :principal_permissions_boundary, 1) do
      backend.principal_permissions_boundary(principal)
    else
      :none
    end
  end

  @spec put_principal_policy(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def put_principal_policy(principal_arn, name, json) do
    backend = impl()

    result =
      if callback_exported?(backend, :put_principal_policy, 3) do
        backend.put_principal_policy(principal_arn, name, json)
      else
        {:error, :not_supported}
      end

    case result do
      :ok ->
        Notify.broadcast({:principal_policy_changed, principal_arn})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_principal_policy(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :not_supported | term()}
  def get_principal_policy(principal_arn, name) do
    backend = impl()

    if callback_exported?(backend, :get_principal_policy, 2) do
      backend.get_principal_policy(principal_arn, name)
    else
      {:error, :not_supported}
    end
  end

  @spec delete_principal_policy(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_principal_policy(principal_arn, name) do
    backend = impl()

    result =
      if callback_exported?(backend, :delete_principal_policy, 2) do
        backend.delete_principal_policy(principal_arn, name)
      else
        :ok
      end

    case result do
      :ok ->
        Notify.broadcast({:principal_policy_changed, principal_arn})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec list_principal_policies(String.t()) :: [map()]
  def list_principal_policies(principal_arn) do
    backend = impl()

    if callback_exported?(backend, :list_principal_policies, 1) do
      backend.list_principal_policies(principal_arn)
    else
      []
    end
  end

  @spec put_managed_session_policy(String.t(), binary()) :: :ok | {:error, term()}
  def put_managed_session_policy(policy_arn, json) do
    backend = impl()

    result =
      if callback_exported?(backend, :put_managed_session_policy, 2) do
        backend.put_managed_session_policy(policy_arn, json)
      else
        {:error, :not_supported}
      end

    case result do
      :ok ->
        Notify.broadcast({:managed_session_policy_changed, policy_arn})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec create_managed_session_policy(String.t(), binary()) :: :ok | {:error, term()}
  def create_managed_session_policy(policy_arn, json),
    do: create_managed_session_policy(policy_arn, json, %{})

  @spec create_managed_session_policy(String.t(), binary(), map()) :: :ok | {:error, term()}
  def create_managed_session_policy(policy_arn, json, attrs) do
    backend = impl()

    result =
      cond do
        callback_exported?(backend, :create_managed_session_policy, 3) ->
          backend.create_managed_session_policy(policy_arn, json, attrs)

        callback_exported?(backend, :create_managed_session_policy, 2) ->
          backend.create_managed_session_policy(policy_arn, json)

        true ->
          {:error, :not_supported}
      end

    case result do
      :ok ->
        Notify.broadcast({:managed_session_policy_changed, policy_arn})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec managed_session_policy(String.t()) ::
          {:ok, binary()} | {:error, :not_found | :malformed | :not_supported}
  def managed_session_policy(policy_arn) do
    backend = impl()

    if callback_exported?(backend, :managed_session_policy, 1) do
      backend.managed_session_policy(policy_arn)
    else
      {:error, :not_supported}
    end
  end

  @spec delete_managed_session_policy(String.t()) :: :ok | {:error, term()}
  def delete_managed_session_policy(policy_arn) do
    backend = impl()

    result =
      if callback_exported?(backend, :delete_managed_session_policy, 1) do
        backend.delete_managed_session_policy(policy_arn)
      else
        :ok
      end

    case result do
      :ok ->
        Notify.broadcast({:managed_session_policy_changed, policy_arn})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec list_managed_session_policies() :: [map()]
  def list_managed_session_policies do
    backend = impl()

    if callback_exported?(backend, :list_managed_session_policies, 0) do
      backend.list_managed_session_policies()
    else
      []
    end
  end

  @spec create_managed_session_policy_version(String.t(), binary(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def create_managed_session_policy_version(policy_arn, json, set_as_default) do
    backend = impl()

    result =
      if callback_exported?(backend, :create_managed_session_policy_version, 3) do
        backend.create_managed_session_policy_version(policy_arn, json, set_as_default)
      else
        {:error, :not_supported}
      end

    case result do
      {:ok, version} ->
        Notify.broadcast({:managed_session_policy_changed, policy_arn})
        {:ok, version}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_managed_session_policy_version(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_managed_session_policy_version(policy_arn, version_id) do
    backend = impl()

    cond do
      callback_exported?(backend, :get_managed_session_policy_version, 2) ->
        backend.get_managed_session_policy_version(policy_arn, version_id)

      version_id == "v1" ->
        case managed_session_policy(policy_arn) do
          {:ok, json} ->
            with {:ok, document} <- Jason.decode(json) do
              {:ok,
               %{
                 policy_arn: policy_arn,
                 version_id: "v1",
                 is_default_version: true,
                 document: document
               }}
            else
              _ -> {:error, :malformed}
            end

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:error, :not_found}
    end
  end

  @spec list_managed_session_policy_versions(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_managed_session_policy_versions(policy_arn) do
    backend = impl()

    cond do
      callback_exported?(backend, :list_managed_session_policy_versions, 1) ->
        backend.list_managed_session_policy_versions(policy_arn)

      true ->
        case get_managed_session_policy_version(policy_arn, "v1") do
          {:ok, version} -> {:ok, [version]}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec set_default_managed_session_policy_version(String.t(), String.t()) ::
          :ok | {:error, term()}
  def set_default_managed_session_policy_version(policy_arn, version_id) do
    backend = impl()

    result =
      if callback_exported?(backend, :set_default_managed_session_policy_version, 2) do
        backend.set_default_managed_session_policy_version(policy_arn, version_id)
      else
        {:error, :not_supported}
      end

    case result do
      :ok ->
        Notify.broadcast({:managed_session_policy_changed, policy_arn})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec delete_managed_session_policy_version(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_managed_session_policy_version(policy_arn, version_id) do
    backend = impl()

    result =
      if callback_exported?(backend, :delete_managed_session_policy_version, 2) do
        backend.delete_managed_session_policy_version(policy_arn, version_id)
      else
        {:error, :not_supported}
      end

    case result do
      :ok ->
        Notify.broadcast({:managed_session_policy_changed, policy_arn})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec tag_managed_session_policy(String.t(), map()) :: :ok | {:error, term()}
  def tag_managed_session_policy(policy_arn, tags) do
    backend = impl()

    result =
      if callback_exported?(backend, :tag_managed_session_policy, 2) do
        backend.tag_managed_session_policy(policy_arn, tags)
      else
        {:error, :not_supported}
      end

    case result do
      :ok ->
        Notify.broadcast({:managed_session_policy_changed, policy_arn})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec untag_managed_session_policy(String.t(), [String.t()]) :: :ok | {:error, term()}
  def untag_managed_session_policy(policy_arn, tag_keys) do
    backend = impl()

    result =
      if callback_exported?(backend, :untag_managed_session_policy, 2) do
        backend.untag_managed_session_policy(policy_arn, tag_keys)
      else
        {:error, :not_supported}
      end

    case result do
      :ok ->
        Notify.broadcast({:managed_session_policy_changed, policy_arn})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec list_managed_session_policy_entities(String.t()) :: map()
  def list_managed_session_policy_entities(policy_arn) do
    backend = impl()

    if callback_exported?(backend, :list_managed_session_policy_entities, 1) do
      backend.list_managed_session_policy_entities(policy_arn)
    else
      %{users: [], groups: [], roles: []}
    end
  end

  @spec list_managed_session_policy_permissions_boundary_entities(String.t()) :: map()
  def list_managed_session_policy_permissions_boundary_entities(policy_arn) do
    backend = impl()

    if callback_exported?(backend, :list_managed_session_policy_permissions_boundary_entities, 1) do
      backend.list_managed_session_policy_permissions_boundary_entities(policy_arn)
    else
      %{users: [], groups: [], roles: []}
    end
  end

  @spec attach_role_managed_policy(String.t(), String.t()) :: :ok | {:error, term()}
  def attach_role_managed_policy(role_arn, policy_arn) do
    backend = impl()

    result =
      if callback_exported?(backend, :attach_role_managed_policy, 2) do
        backend.attach_role_managed_policy(role_arn, policy_arn)
      else
        {:error, :not_supported}
      end

    case result do
      :ok ->
        Notify.broadcast({:principal_policy_changed, role_arn})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec detach_role_managed_policy(String.t(), String.t()) :: :ok
  def detach_role_managed_policy(role_arn, policy_arn) do
    backend = impl()

    if callback_exported?(backend, :detach_role_managed_policy, 2) do
      :ok = backend.detach_role_managed_policy(role_arn, policy_arn)
    end

    Notify.broadcast({:principal_policy_changed, role_arn})
    :ok
  end

  @spec list_attached_role_managed_policies(String.t()) :: [map()]
  def list_attached_role_managed_policies(role_arn) do
    backend = impl()

    if callback_exported?(backend, :list_attached_role_managed_policies, 1) do
      backend.list_attached_role_managed_policies(role_arn)
    else
      []
    end
  end

  @spec attach_user_managed_policy(String.t(), String.t()) :: :ok | {:error, term()}
  def attach_user_managed_policy(user_arn, policy_arn) do
    backend = impl()

    result =
      if callback_exported?(backend, :attach_user_managed_policy, 2) do
        backend.attach_user_managed_policy(user_arn, policy_arn)
      else
        {:error, :not_supported}
      end

    case result do
      :ok ->
        Notify.broadcast({:principal_policy_changed, user_arn})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec detach_user_managed_policy(String.t(), String.t()) :: :ok
  def detach_user_managed_policy(user_arn, policy_arn) do
    backend = impl()

    if callback_exported?(backend, :detach_user_managed_policy, 2) do
      :ok = backend.detach_user_managed_policy(user_arn, policy_arn)
    end

    Notify.broadcast({:principal_policy_changed, user_arn})
    :ok
  end

  @spec list_attached_user_managed_policies(String.t()) :: [map()]
  def list_attached_user_managed_policies(user_arn) do
    backend = impl()

    if callback_exported?(backend, :list_attached_user_managed_policies, 1) do
      backend.list_attached_user_managed_policies(user_arn)
    else
      []
    end
  end

  @spec attach_group_managed_policy(String.t(), String.t()) :: :ok | {:error, term()}
  def attach_group_managed_policy(group_arn, policy_arn) do
    backend = impl()

    result =
      if callback_exported?(backend, :attach_group_managed_policy, 2) do
        backend.attach_group_managed_policy(group_arn, policy_arn)
      else
        {:error, :not_supported}
      end

    case result do
      :ok ->
        Notify.broadcast({:principal_policy_changed, group_arn})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec detach_group_managed_policy(String.t(), String.t()) :: :ok
  def detach_group_managed_policy(group_arn, policy_arn) do
    backend = impl()

    if callback_exported?(backend, :detach_group_managed_policy, 2) do
      :ok = backend.detach_group_managed_policy(group_arn, policy_arn)
    end

    Notify.broadcast({:principal_policy_changed, group_arn})
    :ok
  end

  @spec list_attached_group_managed_policies(String.t()) :: [map()]
  def list_attached_group_managed_policies(group_arn) do
    backend = impl()

    if callback_exported?(backend, :list_attached_group_managed_policies, 1) do
      backend.list_attached_group_managed_policies(group_arn)
    else
      []
    end
  end

  @spec managed_session_policy_attached?(String.t()) :: boolean()
  def managed_session_policy_attached?(policy_arn) do
    backend = impl()

    if callback_exported?(backend, :managed_session_policy_attached?, 1) do
      backend.managed_session_policy_attached?(policy_arn)
    else
      false
    end
  end

  @spec managed_session_policy_attachment_count(String.t()) :: non_neg_integer()
  def managed_session_policy_attachment_count(policy_arn) do
    backend = impl()

    cond do
      callback_exported?(backend, :managed_session_policy_attachment_count, 1) ->
        backend.managed_session_policy_attachment_count(policy_arn)

      managed_session_policy_attached?(policy_arn) ->
        1

      true ->
        0
    end
  end

  @spec managed_session_policy_permissions_boundary_count(String.t()) :: non_neg_integer()
  def managed_session_policy_permissions_boundary_count(policy_arn) do
    backend = impl()

    if callback_exported?(backend, :managed_session_policy_permissions_boundary_count, 1) do
      backend.managed_session_policy_permissions_boundary_count(policy_arn)
    else
      0
    end
  end

  defp callback_exported?(backend, function, arity) do
    Code.ensure_loaded?(backend) and function_exported?(backend, function, arity)
  end

  @doc """
  便捷：取桶策略并解析为 [Statement]。无 policy → []；解析失败（理论上不该发生，
  因 Put 时已校验）→ [] 且打 warning（绝不静默 crash 授权链）。
  """
  @spec statements_for_bucket(String.t()) :: [Statement.t()]
  def statements_for_bucket(bucket) do
    case get_bucket_policy(bucket) do
      {:ok, json} ->
        case Statement.parse_policy(json) do
          {:ok, stmts} ->
            stmts

          {:error, _} ->
            require Logger
            Logger.warning("stored bucket policy failed to parse", bucket: bucket)
            []
        end

      :none ->
        []
    end
  end
end
