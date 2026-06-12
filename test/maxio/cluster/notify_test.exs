defmodule Maxio.Cluster.NotifyTest do
  use ExUnit.Case, async: false

  alias Maxio.Cluster.Notify

  defmodule ProbeCredentialStore do
    @behaviour Maxio.Auth.CredentialStore

    def get_secret(_access_key), do: :error
    def put_access_key(_attrs), do: :ok
    def list_keys, do: []

    def invalidate(scope) do
      send(Application.fetch_env!(:maxio, :credential_invalidation_probe), {:invalidated, scope})
      :ok
    end
  end

  setup do
    previous_store = Application.fetch_env!(:maxio, :credential_store)
    previous_probe = Application.get_env(:maxio, :credential_invalidation_probe)

    on_exit(fn ->
      Application.put_env(:maxio, :credential_store, previous_store)

      if is_nil(previous_probe) do
        Application.delete_env(:maxio, :credential_invalidation_probe)
      else
        Application.put_env(:maxio, :credential_invalidation_probe, previous_probe)
      end
    end)

    :ok
  end

  test "broadcast publishes metadata events on the shared topic" do
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())

    event = {:bucket_policy_changed, "notify-bucket"}
    assert :ok = Notify.broadcast(event)

    assert_receive ^event
  end

  test "cache invalidator delegates IAM changes to the credential store" do
    Application.put_env(:maxio, :credential_store, ProbeCredentialStore)
    Application.put_env(:maxio, :credential_invalidation_probe, self())

    assert is_pid(Process.whereis(Maxio.Cluster.CacheInvalidator))

    assert :ok = Notify.broadcast({:iam_changed, "AKIANOTIFY"})

    assert_receive {:invalidated, {:access_key, "AKIANOTIFY"}}
  end
end
