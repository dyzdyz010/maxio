defmodule Maxio.IAM.CredentialInvalidationTest do
  use ExUnit.Case, async: false

  alias Maxio.Cluster.Notify
  alias Maxio.IAM.CredentialInvalidation

  defmodule RecordingStore do
    @behaviour Maxio.Auth.CredentialStore

    def get_secret(_access_key), do: :error
    def put_access_key(_attrs), do: :ok
    def list_keys, do: []

    def invalidate({:access_key, access_key_id} = scope) do
      send(
        Application.fetch_env!(:maxio, :credential_invalidation_probe),
        {:local, self(), scope}
      )

      case access_key_id do
        "FAIL" -> {:error, :forced_failure}
        "EXIT" -> exit(:forced_exit)
        _other -> :ok
      end
    end
  end

  defmodule FailingTransport do
    def broadcast(_pubsub, _topic, event) do
      send(Application.fetch_env!(:maxio, :credential_invalidation_probe), {:transport, event})

      case event do
        {:iam_credentials_changed, _ids} -> {:error, :forced_typed_failure}
        _other -> :ok
      end
    end
  end

  defmodule ExitTransport do
    def broadcast(_pubsub, _topic, _event), do: exit(:forced_transport_exit)
  end

  setup do
    previous_store = Application.fetch_env!(:maxio, :credential_store)
    previous_probe = Application.get_env(:maxio, :credential_invalidation_probe)
    previous_transport = Application.get_env(:maxio, :cluster_notify_transport)
    Application.put_env(:maxio, :credential_store, RecordingStore)
    Application.put_env(:maxio, :credential_invalidation_probe, self())
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())

    on_exit(fn ->
      Application.put_env(:maxio, :credential_store, previous_store)

      if previous_probe do
        Application.put_env(:maxio, :credential_invalidation_probe, previous_probe)
      else
        Application.delete_env(:maxio, :credential_invalidation_probe)
      end

      if previous_transport do
        Application.put_env(:maxio, :cluster_notify_transport, previous_transport)
      else
        Application.delete_env(:maxio, :cluster_notify_transport)
      end
    end)

    :ok
  end

  test "local failures do not skip later ids, typed batch, or legacy events" do
    principal_arn = "arn:aws:iam:::user/redacted-owner"
    caller = self()

    result =
      CredentialInvalidation.after_commit(
        ["FAIL", "OK", "EXIT", "OK"],
        [{:principal_policy_changed, principal_arn}]
      )

    assert_receive {:local, ^caller, {:access_key, "FAIL"}}
    assert_receive {:local, ^caller, {:access_key, "OK"}}
    assert_receive {:local, ^caller, {:access_key, "EXIT"}}
    refute_receive {:local, ^caller, {:access_key, "OK"}}

    assert_receive {:iam_credentials_changed, ["FAIL", "OK", "EXIT"]}
    assert_receive {:iam_changed, "FAIL"}
    assert_receive {:iam_changed, "OK"}
    assert_receive {:iam_changed, "EXIT"}
    assert_receive {:principal_policy_changed, ^principal_arn}

    assert result.attempted == %{local_ids: 3, typed_batches: 1, legacy_events: 4}
    assert Enum.map(result.failures, & &1.stage) == [:local_invalidation, :local_invalidation]

    evidence = inspect(result.failures)
    refute evidence =~ "FAIL"
    refute evidence =~ "EXIT"
    refute evidence =~ principal_arn
  end

  test "checked notify exposes unavailable PubSub without changing legacy compatibility" do
    pubsub = Process.whereis(Maxio.PubSub)
    assert is_pid(pubsub)
    assert :ok = Notify.broadcast_checked({:iam_changed, "AKIACHECKED"})
    assert_receive {:iam_changed, "AKIACHECKED"}
  end

  test "typed transport failure does not skip every legacy event" do
    Application.put_env(:maxio, :cluster_notify_transport, FailingTransport)

    result = CredentialInvalidation.after_commit(["ONE", "TWO"])

    assert_receive {:transport, {:iam_credentials_changed, ["ONE", "TWO"]}}
    assert_receive {:transport, {:iam_changed, "ONE"}}
    assert_receive {:transport, {:iam_changed, "TWO"}}
    assert [%{stage: :typed_broadcast, category: :returned_error}] = result.failures
    assert result.attempted.legacy_events == 2
  end

  test "checked notify reports transport exits while legacy broadcast stays best effort" do
    Application.put_env(:maxio, :cluster_notify_transport, ExitTransport)

    assert {:error, {:transport_exit, :forced_transport_exit}} =
             Notify.broadcast_checked({:iam_changed, "AKIAEXIT"})

    assert :ok = Notify.broadcast({:iam_changed, "AKIAEXIT"})
  end
end
