defmodule Maxio.Auth.CredentialStoreTest do
  use ExUnit.Case, async: false

  alias Maxio.Auth.CredentialStore

  @backend Maxio.Test.UnloadedCredentialStore

  setup do
    previous_backend = Application.fetch_env!(:maxio, :credential_store)
    previous_probe = Application.get_env(:maxio, :unloaded_credential_store_test_pid)

    Application.put_env(:maxio, :credential_store, @backend)
    Application.put_env(:maxio, :unloaded_credential_store_test_pid, self())

    on_exit(fn ->
      Application.put_env(:maxio, :credential_store, previous_backend)

      if previous_probe do
        Application.put_env(:maxio, :unloaded_credential_store_test_pid, previous_probe)
      else
        Application.delete_env(:maxio, :unloaded_credential_store_test_pid)
      end

      assert Code.ensure_loaded?(@backend)
    end)

    :ok
  end

  test "first optional get_secret callback loads the configured backend before probing exports" do
    unload_backend!()

    assert {:ok,
            %{
              secret_key: "loaded-secret",
              principal: %{
                access_key: "AKUNLOADED",
                callback: :get_secret_2,
                opts: [session_token: "session-token"]
              }
            }} =
             CredentialStore.get_secret("AKUNLOADED", session_token: "session-token")
  end

  test "first optional invalidate callback loads the configured backend before probing exports" do
    unload_backend!()

    assert :ok = CredentialStore.invalidate({:access_key, "AKUNLOADED"})

    assert_receive {:unloaded_credential_store_invalidated, {:access_key, "AKUNLOADED"}}
  end

  defp unload_backend! do
    _purged? = :code.purge(@backend)
    _deleted? = :code.delete(@backend)
    refute Code.loaded?(@backend)
  end
end
