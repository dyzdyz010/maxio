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
  @callback put_principal_policy(
              principal_arn :: String.t(),
              name :: String.t(),
              json :: binary()
            ) ::
              :ok | {:error, term()}
  @callback delete_principal_policy(principal_arn :: String.t(), name :: String.t()) :: :ok
  @callback list_principal_policies(principal_arn :: String.t()) :: [map()]

  @optional_callbacks put_principal_policy: 3,
                      delete_principal_policy: 2,
                      list_principal_policies: 1

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

  @spec put_principal_policy(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def put_principal_policy(principal_arn, name, json) do
    backend = impl()

    result =
      if function_exported?(backend, :put_principal_policy, 3) do
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

  @spec delete_principal_policy(String.t(), String.t()) :: :ok
  def delete_principal_policy(principal_arn, name) do
    backend = impl()

    if function_exported?(backend, :delete_principal_policy, 2) do
      :ok = backend.delete_principal_policy(principal_arn, name)
    end

    Notify.broadcast({:principal_policy_changed, principal_arn})
    :ok
  end

  @spec list_principal_policies(String.t()) :: [map()]
  def list_principal_policies(principal_arn) do
    backend = impl()

    if function_exported?(backend, :list_principal_policies, 1) do
      backend.list_principal_policies(principal_arn)
    else
      []
    end
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
