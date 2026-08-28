defmodule Maxio.Auth.CredentialStore do
  @moduledoc """
  凭据存储 behaviour（铁律 1）。MVP 实现 MemoryStore（root 从 env/config 引导，ETS）；
  后续 EctoStore 换实现不动鉴权逻辑。门面按 config :maxio, :credential_store 派发。
  """
  @callback get_secret(access_key :: String.t()) ::
              {:ok, %{secret_key: String.t(), principal: map()}} | :error
  @callback get_secret(access_key :: String.t(), opts :: keyword()) ::
              {:ok, %{secret_key: String.t(), principal: map()}}
              | :error
              | {:error, :missing_session_token | :invalid_token | :expired_token}
  @callback put_access_key(map()) :: :ok | {:error, term()}
  @callback list_keys() :: [map()]
  @callback invalidate(scope :: term()) :: :ok | {:error, term()}

  @optional_callbacks invalidate: 1, get_secret: 2

  @doc "当前配置的凭据后端模块。"
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:maxio, :credential_store)

  @spec get_secret(String.t()) :: {:ok, map()} | :error | {:error, term()}
  def get_secret(access_key), do: get_secret(access_key, [])

  @spec get_secret(String.t(), keyword()) :: {:ok, map()} | :error | {:error, term()}
  def get_secret(access_key, opts) do
    backend = impl()

    cond do
      callback_exported?(backend, :get_secret, 2) ->
        backend.get_secret(access_key, opts)

      session_token?(Keyword.get(opts, :session_token)) ->
        {:error, :invalid_token}

      true ->
        backend.get_secret(access_key)
    end
  end

  @spec put_access_key(map()) :: :ok | {:error, term()}
  def put_access_key(attrs), do: impl().put_access_key(attrs)

  @spec list_keys() :: [map()]
  def list_keys, do: impl().list_keys()

  @spec invalidate(term()) :: :ok | {:error, term()}
  def invalidate(scope) do
    backend = impl()

    if callback_exported?(backend, :invalidate, 1) do
      backend.invalidate(scope)
    else
      :ok
    end
  end

  # 可选回调探测必须先确保后端模块已加载：`function_exported?/3` 对"存在但尚未被加载"
  # 的模块返回 false，而交互式代码加载（`mix run` / `iex -S mix` / `mix maxio.*` /
  # `mix test`）下这正是新起节点的常态。否则第一次带 session token 的请求会走
  # `{:error, :invalid_token}` 误拒合法 STS 凭据，`invalidate/1` 也会静默跳过缓存失效，
  # 让轮换/删除后的旧密钥继续可用（AGENTS.md §3 绝不静默失败）。与
  # `Maxio.Policy.Store.callback_exported?/3` 同一约定。
  defp callback_exported?(backend, function, arity) do
    Code.ensure_loaded?(backend) and function_exported?(backend, function, arity)
  end

  defp session_token?(nil), do: false
  defp session_token?(""), do: false
  defp session_token?(_token), do: true
end
