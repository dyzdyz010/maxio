defmodule Maxio.Cluster.NotifyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Maxio.Cluster.{CacheInvalidator, Notify}

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

  test "checked broadcast publishes the two-tuple config batch event" do
    # Catches the event type/facade rejecting the subsystem-level event while callers migrate away
    # from the legacy per-key tuple.
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())

    event = {:config_changed, :listing}
    assert :ok = Notify.broadcast_checked(event)
    assert_receive ^event
  end

  test "cache invalidator recognizes both config event generations as owned no-ops" do
    # Catches the two-tuple event being mislabeled as unknown operational noise while Store owns the
    # actual reload. Legacy recognition remains frozen for the migration window.
    previous_level = Logger.level()

    log =
      try do
        Logger.configure(level: :debug)

        capture_log([level: :debug], fn ->
          assert {:noreply, %{}} =
                   CacheInvalidator.handle_info({:config_changed, :listing}, %{})

          assert {:noreply, %{}} =
                   CacheInvalidator.handle_info(
                     {:config_changed, :listing, :sql_hard_limit},
                     %{}
                   )
        end)
      after
        Logger.configure(level: previous_level)
      end

    refute log =~ "ignored unknown metadata event"
    refute log =~ "ignored cache invalidator message"
  end

  test "cache invalidator delegates IAM changes to the credential store" do
    Application.put_env(:maxio, :credential_store, ProbeCredentialStore)
    Application.put_env(:maxio, :credential_invalidation_probe, self())

    assert is_pid(Process.whereis(Maxio.Cluster.CacheInvalidator))

    assert :ok = Notify.broadcast({:iam_changed, "AKIANOTIFY"})

    assert_receive {:invalidated, {:access_key, "AKIANOTIFY"}}
  end
end
