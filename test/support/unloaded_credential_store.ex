defmodule Maxio.Test.UnloadedCredentialStore do
  @moduledoc false

  @behaviour Maxio.Auth.CredentialStore

  @impl true
  def get_secret(_access_key), do: :error

  @impl true
  def get_secret(access_key, opts) do
    {:ok,
     %{
       secret_key: "loaded-secret",
       principal: %{access_key: access_key, opts: opts, callback: :get_secret_2}
     }}
  end

  @impl true
  def put_access_key(_attrs), do: :ok

  @impl true
  def list_keys, do: []

  @impl true
  def invalidate(scope) do
    send(Application.fetch_env!(:maxio, :unloaded_credential_store_test_pid), {
      :unloaded_credential_store_invalidated,
      scope
    })

    :ok
  end
end
