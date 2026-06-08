defmodule Maxio.Auth.CredentialStore.MemoryStore do
  @moduledoc """
  内存凭据后端（ETS）。root 凭据从 config :maxio, :s3 的 root_user/root_password 引导。
  惰性建表：首次访问若表不存在则建表并注入 root。principal 形如
  %{type: :root, access_key: ..., arn: "arn:aws:iam:::root"}。
  """
  @behaviour Maxio.Auth.CredentialStore

  @table :maxio_credentials

  @impl true
  def get_secret(access_key) do
    ensure_table()

    case :ets.lookup(@table, access_key) do
      [{^access_key, secret_key, principal}] ->
        {:ok, %{secret_key: secret_key, principal: principal}}

      [] ->
        # 并发惰性建表竞态：另一进程已建表但尚未注入 root 时，本进程可能读到空。
        # 仅当查询的是 root key 且表中确无该行时，幂等补一次 bootstrap 再重查（绝不静默丢失 root）。
        maybe_bootstrap_root_for(access_key)
    end
  end

  # 表已存在但 root 行尚未可见（建表进程的 bootstrap_root 与本进程 lookup 交错）时，
  # 幂等补注入 root 并重查；非 root key 仍正常返回 :error。
  defp maybe_bootstrap_root_for(access_key) do
    if access_key == root_access_key() do
      bootstrap_root()

      case :ets.lookup(@table, access_key) do
        [{^access_key, secret_key, principal}] ->
          {:ok, %{secret_key: secret_key, principal: principal}}

        [] ->
          :error
      end
    else
      :error
    end
  end

  @impl true
  def put_access_key(%{access_key: ak, secret_key: sk} = attrs) do
    ensure_table()

    principal =
      Map.get(attrs, :principal, %{type: :iam_user, access_key: ak, arn: "arn:aws:iam:::user/#{ak}"})

    :ets.insert(@table, {ak, sk, principal})
    :ok
  end

  def put_access_key(_), do: {:error, :invalid_attrs}

  @impl true
  def list_keys do
    ensure_table()

    :ets.tab2list(@table)
    |> Enum.map(fn {ak, _sk, principal} -> %{access_key: ak, principal: principal} end)
  end

  # 惰性建表 + 注入 root（幂等）。并发安全：用 :public named table，已存在则忽略。
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        bootstrap_root()

      _ref ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp bootstrap_root do
    s3 = Application.fetch_env!(:maxio, :s3)
    ak = Keyword.fetch!(s3, :root_user)
    sk = Keyword.fetch!(s3, :root_password)
    principal = %{type: :root, access_key: ak, arn: "arn:aws:iam:::root"}
    :ets.insert(@table, {ak, sk, principal})
  end

  defp root_access_key do
    :maxio
    |> Application.fetch_env!(:s3)
    |> Keyword.fetch!(:root_user)
  end
end
