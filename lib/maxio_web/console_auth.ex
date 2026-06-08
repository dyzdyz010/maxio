defmodule MaxioWeb.ConsoleAuth do
  @moduledoc """
  Console 会话鉴权：复用 S3 数据面同一套 `Maxio.Auth.CredentialStore` 验证
  access_key + secret_key（常数时间比对，绝不静默放行，铁律 3）。
  登录成功只把 access_key 落进签名 session（secret 绝不入 session）；
  LiveView mount 时凭 access_key 重新查 principal。
  """
  alias Maxio.Auth.CredentialStore

  @session_key "console_access_key"

  @doc """
  校验 access_key/secret_key。成功返回 `{:ok, principal}`，失败返回 `:error`。
  常数时间比对避免计时侧信道（铁律 3/5）。
  """
  @spec verify_credentials(String.t(), String.t()) :: {:ok, map()} | :error
  def verify_credentials(access_key, secret_key)
      when is_binary(access_key) and is_binary(secret_key) do
    case CredentialStore.get_secret(access_key) do
      {:ok, %{secret_key: stored, principal: principal}} ->
        if Plug.Crypto.secure_compare(stored, secret_key) do
          {:ok, principal}
        else
          :error
        end

      :error ->
        # 即便 access_key 不存在也做一次假比对，抹平计时差（避免枚举 access_key）。
        _ = Plug.Crypto.secure_compare(secret_key, secret_key)
        :error
    end
  end

  def verify_credentials(_, _), do: :error

  @doc "登录后写 session（只存 access_key，renew 防 session fixation）。在 controller 里用。"
  @spec log_in(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def log_in(conn, access_key) do
    conn
    |> Plug.Conn.put_session(@session_key, access_key)
    |> Plug.Conn.configure_session(renew: true)
  end

  @doc "登出：清 session。"
  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(conn), do: Plug.Conn.configure_session(conn, drop: true)

  @doc "从 session 的 access_key 还原 principal（LiveView on_mount / plug 用）。无/失效 → nil。"
  @spec fetch_principal(map()) :: map() | nil
  def fetch_principal(%{} = session) do
    case Map.get(session, @session_key) do
      ak when is_binary(ak) ->
        case CredentialStore.get_secret(ak) do
          {:ok, %{principal: principal}} -> principal
          :error -> nil
        end

      _ ->
        nil
    end
  end

  def fetch_principal(_), do: nil

  @doc "session key 名（测试/插件复用）。"
  @spec session_key() :: String.t()
  def session_key, do: @session_key
end
