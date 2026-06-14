defmodule Maxio.Auth.CredentialStore.MemoryStore do
  @moduledoc """
  ETS credential backend used by tests and local development.

  Long-term credentials are stored as `{access_key, secret_key, principal}`.
  Temporary session credentials are stored as
  `{access_key, secret_key, principal, session_meta}` and require a matching
  session token on lookup.
  """
  @behaviour Maxio.Auth.CredentialStore

  alias Maxio.Auth.SessionToken

  @table :maxio_credentials

  @impl true
  def get_secret(access_key), do: get_secret(access_key, [])

  @impl true
  def get_secret(access_key, opts) do
    ensure_table()

    case :ets.lookup(@table, access_key) do
      [{^access_key, secret_key, principal}] ->
        if session_token?(Keyword.get(opts, :session_token)) do
          {:error, :invalid_token}
        else
          {:ok, %{secret_key: secret_key, principal: principal}}
        end

      [{^access_key, secret_key, principal, meta}] ->
        session_secret(secret_key, principal, meta, opts)

      [] ->
        maybe_bootstrap_root_for(access_key, opts)
    end
  end

  @impl true
  def put_access_key(%{access_key: ak, secret_key: sk, session_token: token} = attrs) do
    ensure_table()

    case Map.get(attrs, :expires_at) do
      %DateTime{} = expires_at ->
        principal =
          attrs
          |> default_principal(ak)
          |> Map.put(:credential_type, :session)
          |> Map.put_new(:session_access_key, ak)
          |> Map.put_new(:session_expires_at, expires_at)

        meta = %{
          session_token_sha256: SessionToken.hash(token),
          expires_at: expires_at,
          status: Map.get(attrs, :status, :active)
        }

        :ets.insert(@table, {ak, sk, principal, meta})
        :ok

      _other ->
        {:error, :invalid_attrs}
    end
  end

  def put_access_key(%{access_key: ak, secret_key: sk} = attrs) do
    ensure_table()
    :ets.insert(@table, {ak, sk, default_principal(attrs, ak)})
    :ok
  end

  def put_access_key(_), do: {:error, :invalid_attrs}

  @impl true
  def list_keys do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {ak, _sk, principal} -> [%{access_key: ak, principal: principal}]
      {_ak, _sk, _principal, _meta} -> []
    end)
  end

  @impl true
  def invalidate({:access_key, access_key}) when is_binary(access_key) do
    ensure_table()
    :ets.delete(@table, access_key)
    :ok
  end

  def invalidate(:all) do
    ensure_table()
    :ets.delete_all_objects(@table)
    bootstrap_root()
    :ok
  end

  def invalidate(_scope), do: :ok

  defp maybe_bootstrap_root_for(access_key, opts) do
    if access_key == root_access_key() do
      bootstrap_root()

      case :ets.lookup(@table, access_key) do
        [{^access_key, secret_key, principal}] ->
          if session_token?(Keyword.get(opts, :session_token)) do
            {:error, :invalid_token}
          else
            {:ok, %{secret_key: secret_key, principal: principal}}
          end

        [] ->
          :error
      end
    else
      :error
    end
  end

  defp session_secret(secret_key, principal, meta, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    token = Keyword.get(opts, :session_token)

    cond do
      Map.get(meta, :status) != :active ->
        {:error, :invalid_token}

      DateTime.compare(Map.fetch!(meta, :expires_at), now) != :gt ->
        {:error, :expired_token}

      not session_token?(token) ->
        {:error, :missing_session_token}

      not SessionToken.verify(token, Map.fetch!(meta, :session_token_sha256)) ->
        {:error, :invalid_token}

      true ->
        {:ok, %{secret_key: secret_key, principal: principal}}
    end
  end

  defp default_principal(attrs, access_key) do
    Map.get(attrs, :principal, %{
      type: :iam_user,
      access_key: access_key,
      arn: "arn:aws:iam:::user/#{access_key}"
    })
  end

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

  defp session_token?(nil), do: false
  defp session_token?(""), do: false
  defp session_token?(_token), do: true
end
