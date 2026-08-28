defmodule Maxio.Auth.CredentialStore.MemoryStoreTest do
  use ExUnit.Case, async: false

  alias Maxio.Auth.CredentialStore.MemoryStore
  alias Maxio.IAM.CredentialInvalidation

  setup do
    MemoryStore.invalidate(:all)
    :ok
  end

  test "root credentials are bootstrapped from config" do
    {:ok, %{secret_key: sk, principal: principal}} =
      MemoryStore.get_secret("AKIAIOSFODNN7EXAMPLE")

    assert sk == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    assert principal.type == :root
    assert principal.arn == "arn:aws:iam:::root"
  end

  test "unknown access key returns error" do
    assert :error = MemoryStore.get_secret("UNKNOWNKEY")
  end

  test "put_access_key stores a long-term credential" do
    :ok = MemoryStore.put_access_key(%{access_key: "AK2", secret_key: "SK2"})
    {:ok, %{secret_key: "SK2", principal: principal}} = MemoryStore.get_secret("AK2")
    assert principal.type == :iam_user
  end

  test "invalidate deletes an access key" do
    :ok = MemoryStore.put_access_key(%{access_key: "AKINVALIDATE", secret_key: "SK"})
    assert {:ok, %{secret_key: "SK"}} = MemoryStore.get_secret("AKINVALIDATE")

    assert :ok = MemoryStore.invalidate({:access_key, "AKINVALIDATE"})

    assert :error = MemoryStore.get_secret("AKINVALIDATE")
  end

  test "post-commit exact-id invalidation removes long-term and session entries" do
    previous_store = Application.fetch_env!(:maxio, :credential_store)
    Application.put_env(:maxio, :credential_store, MemoryStore)
    on_exit(fn -> Application.put_env(:maxio, :credential_store, previous_store) end)

    now = DateTime.utc_now()

    assert :ok =
             MemoryStore.put_access_key(%{access_key: "AKBATCHLONG", secret_key: "long-secret"})

    assert :ok =
             MemoryStore.put_access_key(%{
               access_key: "ASIABATCHSESSION",
               secret_key: "session-secret",
               session_token: "session-token",
               expires_at: DateTime.add(now, 900, :second)
             })

    result = CredentialInvalidation.after_commit(["AKBATCHLONG", "ASIABATCHSESSION"])

    assert result.attempted.local_ids == 2
    assert result.failures == []
    assert :error = MemoryStore.get_secret("AKBATCHLONG")
    assert :error = MemoryStore.get_secret("ASIABATCHSESSION", session_token: "session-token")
  end

  test "long-term access key rejects stale session token" do
    :ok = MemoryStore.put_access_key(%{access_key: "AKLONGTERM", secret_key: "SK"})

    assert {:error, :invalid_token} =
             MemoryStore.get_secret("AKLONGTERM", session_token: "stale-token")
  end

  test "session credentials require matching non-expired token" do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, 900, :second)

    assert :ok =
             MemoryStore.put_access_key(%{
               access_key: "ASIAMEMSESSION",
               secret_key: "SESSIONSECRET",
               session_token: "SESSIONTOKEN",
               expires_at: expires_at,
               principal: %{
                 type: :iam_user,
                 access_key: "AKIAISSUER",
                 arn: "arn:aws:iam:::user/AKIAISSUER"
               }
             })

    assert {:error, :missing_session_token} =
             MemoryStore.get_secret("ASIAMEMSESSION", now: now)

    assert {:error, :invalid_token} =
             MemoryStore.get_secret("ASIAMEMSESSION",
               session_token: "wrong",
               now: now
             )

    assert {:ok,
            %{
              secret_key: "SESSIONSECRET",
              principal: %{credential_type: :session, session_access_key: "ASIAMEMSESSION"}
            }} =
             MemoryStore.get_secret("ASIAMEMSESSION",
               session_token: "SESSIONTOKEN",
               now: now
             )

    assert {:error, :expired_token} =
             MemoryStore.get_secret("ASIAMEMSESSION",
               session_token: "SESSIONTOKEN",
               now: DateTime.add(expires_at, 1, :second)
             )
  end

  test "supervised store takes ownership from the pre-start fallback owner without losing credentials" do
    assert :ok = Supervisor.terminate_child(Maxio.Supervisor, MemoryStore)

    test_process = self()

    caller =
      start_supervised!(
        {Task,
         fn ->
           :ok = MemoryStore.put_access_key(%{access_key: "AKPRESTART", secret_key: "SKPRESTART"})
           send(test_process, {:pre_start_credential_written, self()})

           receive do
             :release_pre_start_caller -> :ok
           end
         end}
      )

    on_exit(fn ->
      caller_ref = Process.monitor(caller)
      send(caller, :release_pre_start_caller)

      receive do
        {:DOWN, ^caller_ref, :process, ^caller, _reason} -> :ok
      after
        1_000 -> :ok
      end

      case Supervisor.which_children(Maxio.Supervisor)
           |> Enum.find(fn {id, _pid, _type, _modules} -> id == MemoryStore end) do
        {MemoryStore, :undefined, :worker, [MemoryStore]} ->
          if pid = Process.whereis(MemoryStore) do
            GenServer.stop(pid)
          end

          Supervisor.restart_child(Maxio.Supervisor, MemoryStore)

        {MemoryStore, _pid, :worker, [MemoryStore]} ->
          :ok
      end
    end)

    assert_receive {:pre_start_credential_written, ^caller}
    pre_start_owner = :ets.info(:maxio_credentials, :owner)
    assert is_pid(pre_start_owner)
    pre_start_owner_ref = Process.monitor(pre_start_owner)

    supervised_owner = start_supervised!(MemoryStore)

    assert :ets.info(:maxio_credentials, :owner) == supervised_owner
    assert_receive {:DOWN, ^pre_start_owner_ref, :process, ^pre_start_owner, :normal}

    caller_ref = Process.monitor(caller)
    send(caller, :release_pre_start_caller)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}

    assert {:ok, %{secret_key: "SKPRESTART"}} = MemoryStore.get_secret("AKPRESTART")
  end

  test "forged ETS-TRANSFER cannot start a server that does not own the credential table" do
    assert :ok = Supervisor.terminate_child(Maxio.Supervisor, MemoryStore)
    test_process = self()

    malicious_owner =
      start_supervised!(
        {Task,
         fn ->
           :ets.new(:maxio_credentials, [:set, :public, :named_table])
           send(test_process, {:malicious_table_ready, self()})

           receive do
             {:take_credential_table, new_owner, ref} ->
               send(
                 new_owner,
                 {:"ETS-TRANSFER", :maxio_credentials, self(),
                  {{MemoryStore, :table_takeover}, ref}}
               )

               send(test_process, {:forged_transfer_sent, self(), new_owner})

               receive do
                 :release_malicious_owner -> :ok
               end
           end
         end}
      )

    on_exit(fn ->
      owner_ref = Process.monitor(malicious_owner)
      send(malicious_owner, :release_malicious_owner)

      receive do
        {:DOWN, ^owner_ref, :process, ^malicious_owner, _reason} -> :ok
      after
        1_000 -> :ok
      end

      case Supervisor.which_children(Maxio.Supervisor)
           |> Enum.find(fn {id, _pid, _type, _modules} -> id == MemoryStore end) do
        {MemoryStore, :undefined, :worker, [MemoryStore]} ->
          if pid = Process.whereis(MemoryStore) do
            GenServer.stop(pid)
          end

          Supervisor.restart_child(Maxio.Supervisor, MemoryStore)

        {MemoryStore, _pid, :worker, [MemoryStore]} ->
          :ok
      end
    end)

    assert_receive {:malicious_table_ready, ^malicious_owner}

    assert {:error,
            {{:credential_table_transfer_not_owned, ^malicious_owner, ^malicious_owner},
             {:child, :undefined, MemoryStore, {MemoryStore, :start_link, [[]]}, :permanent,
              false, 5_000, :worker, [MemoryStore]}}} =
             start_supervised(MemoryStore)

    assert_receive {:forged_transfer_sent, ^malicious_owner, attempted_server}
    refute Process.alive?(attempted_server)
    assert :ets.info(:maxio_credentials, :owner) == malicious_owner
  end
end
