defmodule Maxio.Policy.Store do
  @moduledoc """
  策略存储 behaviour（铁律 1）。bucket policy 持久化经此抽象；门面按
  config :maxio, :policy_store 派发。MVP 提供 EctoStore（Postgres jsonb）。
  principal_policies/1（IAM identity policy）MVP 恒 []（defer，见计划）。
  """
  alias Maxio.Policy.Statement

  @callback get_bucket_policy(bucket :: String.t()) :: {:ok, binary()} | :none
  @callback put_bucket_policy(bucket :: String.t(), json :: binary()) :: :ok | {:error, term()}
  @callback delete_bucket_policy(bucket :: String.t()) :: :ok
  @callback principal_policies(principal :: map() | :anonymous) :: [Statement.t()]

  @doc "当前配置的策略后端模块。"
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:maxio, :policy_store)

  @spec get_bucket_policy(String.t()) :: {:ok, binary()} | :none
  def get_bucket_policy(bucket), do: impl().get_bucket_policy(bucket)

  @spec put_bucket_policy(String.t(), binary()) :: :ok | {:error, term()}
  def put_bucket_policy(bucket, json), do: impl().put_bucket_policy(bucket, json)

  @spec delete_bucket_policy(String.t()) :: :ok
  def delete_bucket_policy(bucket), do: impl().delete_bucket_policy(bucket)

  @spec principal_policies(map() | :anonymous) :: [Statement.t()]
  def principal_policies(principal), do: impl().principal_policies(principal)

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
