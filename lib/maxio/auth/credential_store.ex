defmodule Maxio.Auth.CredentialStore do
  @moduledoc """
  凭据存储 behaviour（铁律 1）。MVP 实现 MemoryStore（root 从 env/config 引导，ETS）；
  后续 EctoStore 换实现不动鉴权逻辑。门面按 config :maxio, :credential_store 派发。
  """
  @callback get_secret(access_key :: String.t()) ::
              {:ok, %{secret_key: String.t(), principal: map()}} | :error
  @callback put_access_key(map()) :: :ok | {:error, term()}
  @callback list_keys() :: [map()]

  @doc "当前配置的凭据后端模块。"
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:maxio, :credential_store)

  @spec get_secret(String.t()) :: {:ok, map()} | :error
  def get_secret(access_key), do: impl().get_secret(access_key)

  @spec put_access_key(map()) :: :ok | {:error, term()}
  def put_access_key(attrs), do: impl().put_access_key(attrs)

  @spec list_keys() :: [map()]
  def list_keys, do: impl().list_keys()
end
