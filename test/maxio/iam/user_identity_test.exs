defmodule Maxio.IAM.UserIdentityTest do
  use Maxio.DataCase, async: false

  alias Maxio.IAM
  alias Maxio.IAM.{AccessKey, MFADevice, STSSession, UserIdentity}
  alias Maxio.Policy.{PrincipalPolicy, Store}
  alias Maxio.STS

  @policy ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::identity/*"}})

  test "final STS persistence rejects an issuer deleted after the optimistic read" do
    user_name = unique_name("stale-issuer")
    session_access_key = "ASIASTALE#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, _user} = IAM.create_user(name: user_name)
    assert {:ok, issuer} = IAM.create_access_key_strict(user_name)

    assert {:error, :issuer_access_key_not_found} =
             STS.issue_session(
               issuer_access_key_id: issuer.access_key_id,
               session_access_key_id: session_access_key,
               secret_key: "stale-session-secret",
               session_token: "stale-session-token",
               duration_seconds: 900,
               pre_issue: fn -> IAM.delete_user(user_name) end
             )

    refute Repo.get_by(STSSession, access_key_id: session_access_key)
  end

  test "user-owned policy cannot be attached without a concrete user generation" do
    user_name = unique_name("missing-policy-owner")
    user_arn = IAM.user_arn(user_name)

    assert {:error, :user_not_found} = IAM.put_principal_policy(user_arn, "read", @policy)
    refute Repo.get_by(Maxio.Policy.PrincipalPolicy, principal_arn: user_arn)
  end

  test "user-owned MFA cannot be attached without a concrete user generation" do
    user_name = unique_name("missing-mfa-owner")
    user_arn = IAM.user_arn(user_name)
    serial = "arn:aws:iam:::mfa/#{user_name}"

    assert {:error, :user_not_found} =
             IAM.create_mfa_device(
               principal_arn: user_arn,
               device_name: "missing-owner",
               serial: serial
             )

    refute Repo.get_by(MFADevice, serial: serial)
  end

  test "a snapshot cannot mutate a same-name replacement generation" do
    user_name = unique_name("generation")
    assert {:ok, original} = IAM.create_user(name: user_name)
    assert {:existing, original.id} == UserIdentity.snapshot(Repo, user_name)
    snapshot = {:existing, original.id}

    assert :ok = IAM.delete_user(user_name)
    assert {:ok, replacement} = IAM.create_user(name: user_name)
    refute replacement.id == original.id

    assert {:error, :identity_changed} =
             Repo.transaction(fn -> UserIdentity.lock_snapshot(Repo, user_name, snapshot) end)
             |> elem(1)
  end

  test "descendant traversal includes direct and chained sessions but excludes web identity" do
    user_name = unique_name("descendants")
    assert {:ok, user} = IAM.create_user(name: user_name)

    assert {:ok, key} =
             IAM.create_access_key(
               access_key_id: unique_access_key("OWNER"),
               secret_key: "owner-secret",
               user_name: user.user_name
             )

    direct = insert_session!(unique_access_key("DIRECT"), key.access_key_id, user.user_arn)

    chained =
      insert_session!(unique_access_key("CHAIN"), direct.access_key_id, "arn:aws:iam:::role/r")

    web =
      insert_session!(unique_access_key("WEB"), nil, "arn:aws:iam:::role/web",
        web_identity_provider_arn: "arn:aws:iam:::oidc-provider/id.example",
        web_identity_subject_sha256: String.duplicate("a", 64)
      )

    web_child =
      insert_session!(
        unique_access_key("WEBCHILD"),
        web.access_key_id,
        "arn:aws:iam:::role/web-child"
      )

    persisted_user = Repo.get_by!(Maxio.IAM.User, user_name: user.user_name)
    descendants = UserIdentity.descendant_credential_ids(Repo, persisted_user)

    assert descendants.long_term == [key.access_key_id]

    assert Enum.sort(descendants.sessions) ==
             Enum.sort([direct.access_key_id, chained.access_key_id])

    refute web.access_key_id in descendants.sessions
    refute web_child.access_key_id in descendants.sessions

    assert {:ok, %Maxio.IAM.User{id: user_id}} =
             Repo.transaction(fn ->
               UserIdentity.lock_and_validate_issuer(
                 Repo,
                 chained.access_key_id,
                 DateTime.utc_now()
               )
             end)
             |> elem(1)

    assert user_id == user.id

    assert {:ok, :web_identity} =
             Repo.transaction(fn ->
               UserIdentity.lock_and_validate_issuer(
                 Repo,
                 web_child.access_key_id,
                 DateTime.utc_now()
               )
             end)
             |> elem(1)
  end

  test "same-name public create blocks on the shared identity advisory lock" do
    user_name = unique_name("identity-lock")
    test_pid = self()

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(u in Maxio.IAM.User, where: u.user_name == ^user_name))
      end)
    end)

    holder =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            assert {:ok, :missing} = UserIdentity.lock_snapshot(Repo, user_name, :missing)
            send(test_pid, {:identity_lock_held, self()})

            receive do
              :release_identity_lock -> :ok
            after
              5_000 -> raise "identity lock holder timed out"
            end
          end)
        end)
      end)

    assert_receive {:identity_lock_held, holder_pid}, 5_000

    waiter =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend_pid]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()")
          send(test_pid, {:identity_waiter_backend, backend_pid})
          IAM.create_user(name: user_name)
        end)
      end)

    assert_receive {:identity_waiter_backend, backend_pid}, 5_000
    assert_backend_waits_on_lock!(backend_pid)
    send(holder_pid, :release_identity_lock)

    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:ok, %{user_name: ^user_name}} = Task.await(waiter, 10_000)
  end

  test "root disable/delete linearize with final STS persistence on the exact credential lock" do
    for mutation <- [:disable, :delete] do
      root_access_key = unique_access_key("ROOTISSUER#{mutation}")
      second_root_access_key = unique_access_key("ROOTSPARE#{mutation}")
      session_access_key = unique_access_key("ROOTRACE#{mutation}")
      cleanup_ids = [root_access_key, second_root_access_key, session_access_key]
      owner = self()
      barrier_ref = make_ref()
      handler_id = {__MODULE__, barrier_ref}
      barrier_once = :atomics.new(1, signed: false)

      on_exit(fn -> cleanup_unboxed_credentials!(cleanup_ids) end)

      try do
        assert {:ok, _root} =
                 unboxed(fn ->
                   IAM.create_access_key(
                     access_key_id: root_access_key,
                     secret_key: "root-race-issuer-secret",
                     type: "root",
                     principal_arn: IAM.root_principal_arn()
                   )
                 end)

        assert {:ok, _second_root} =
                 unboxed(fn ->
                   IAM.create_access_key(
                     access_key_id: second_root_access_key,
                     secret_key: "root-race-spare-secret",
                     type: "root",
                     principal_arn: IAM.root_principal_arn()
                   )
                 end)

        on_exit(fn -> :telemetry.detach(handler_id) end)

        :ok =
          :telemetry.attach(
            handler_id,
            [:maxio, :iam, :credential_namespace, :lock_wait],
            fn _event, _measurements, metadata, {test_pid, ref, expected_access_key, once} ->
              if metadata.access_key_id == expected_access_key and
                   :atomics.compare_exchange(once, 1, 0, 1) == :ok do
                send(test_pid, {:root_namespace_wait, ref, self()})

                receive do
                  {:release_root_namespace, ^ref} -> :ok
                after
                  5_000 -> raise "root namespace barrier timed out"
                end
              end
            end,
            {owner, barrier_ref, root_access_key, barrier_once}
          )

        session_task =
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              STS.issue_session(
                issuer_access_key_id: root_access_key,
                session_access_key_id: session_access_key,
                secret_key: "root-race-session-secret",
                session_token: "root-race-session-token",
                duration_seconds: 900
              )
            end)
          end)

        assert_receive {:root_namespace_wait, ^barrier_ref, session_pid}, 5_000

        mutation_result =
          unboxed(fn ->
            case mutation do
              :disable -> IAM.update_access_key_strict(root_access_key, "inactive")
              :delete -> IAM.delete_access_key_strict(root_access_key)
            end
          end)

        assert {:ok, _root} = mutation_result
        send(session_pid, {:release_root_namespace, barrier_ref})

        assert {:error, :issuer_access_key_not_found} = Task.await(session_task, 10_000)
        refute unboxed(fn -> Repo.get_by(STSSession, access_key_id: session_access_key) end)

        :telemetry.detach(handler_id)
      after
        :telemetry.detach(handler_id)
        cleanup_unboxed_credentials!(cleanup_ids)
      end

      assert unboxed(fn ->
               Repo.aggregate(
                 from(s in STSSession,
                   where:
                     s.access_key_id in ^cleanup_ids or s.issuer_access_key_id in ^cleanup_ids
                 ),
                 :count
               )
             end) == 0

      assert unboxed(fn ->
               Repo.aggregate(
                 from(a in AccessKey, where: a.access_key_id in ^cleanup_ids),
                 :count
               )
             end) == 0
    end
  end

  test "root race cleanup removes active and revoked STS descendants by exact issuer graph" do
    root_access_key = unique_access_key("ROOTCLEANUP")
    active_session_access_key = unique_access_key("ROOTCLEANUPACTIVE")
    revoked_session_access_key = unique_access_key("ROOTCLEANUPREVOKED")

    cleanup_ids = [
      root_access_key,
      active_session_access_key,
      revoked_session_access_key
    ]

    on_exit(fn -> cleanup_unboxed_credentials!(cleanup_ids) end)

    assert {:ok, _root} =
             unboxed(fn ->
               IAM.create_access_key(
                 access_key_id: root_access_key,
                 secret_key: "root-cleanup-secret",
                 type: "root",
                 principal_arn: IAM.root_principal_arn()
               )
             end)

    unboxed(fn ->
      insert_session!(
        active_session_access_key,
        root_access_key,
        IAM.root_principal_arn()
      )

      insert_session!(
        revoked_session_access_key,
        active_session_access_key,
        IAM.root_principal_arn(),
        status: "revoked"
      )
    end)

    cleanup_unboxed_credentials!([root_access_key])

    assert unboxed(fn ->
             Repo.aggregate(
               from(s in STSSession, where: s.access_key_id in ^cleanup_ids),
               :count
             )
           end) == 0

    assert unboxed(fn ->
             Repo.aggregate(
               from(a in AccessKey, where: a.access_key_id in ^cleanup_ids),
               :count
             )
           end) == 0
  end

  test "strict identity policy events are emitted only after committed rows are visible" do
    user_name = unique_name("policy-event-boundary")
    policy_name = "read"
    owner = self()

    assert {:ok, user} = unboxed(fn -> IAM.create_user(name: user_name) end)

    previous_transport = Application.get_env(:maxio, :cluster_notify_transport)
    Application.put_env(:maxio, :blocking_notify_test_owner, owner)
    Application.put_env(:maxio, :cluster_notify_transport, Maxio.Test.BlockingNotifyTransport)

    on_exit(fn ->
      if previous_transport do
        Application.put_env(:maxio, :cluster_notify_transport, previous_transport)
      else
        Application.delete_env(:maxio, :cluster_notify_transport)
      end

      Application.delete_env(:maxio, :blocking_notify_test_owner)

      unboxed(fn ->
        Repo.delete_all(from(p in PrincipalPolicy, where: p.principal_arn == ^user.user_arn))
        Repo.delete_all(from(u in Maxio.IAM.User, where: u.id == ^user.id))
      end)
    end)

    put_task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          IAM.put_user_policy_strict(user_name, policy_name, @policy)
        end)
      end)

    event = {:principal_policy_changed, user.user_arn}
    assert_receive {:blocking_notify_attempt, ^event, put_pid}, 5_000

    assert unboxed(fn ->
             Repo.get_by(PrincipalPolicy,
               principal_arn: user.user_arn,
               policy_name: policy_name
             )
           end)

    send(put_pid, {:release_blocking_notify, event})
    assert :ok = Task.await(put_task, 10_000)

    delete_task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          IAM.delete_user_policy_strict(user_name, policy_name)
        end)
      end)

    assert_receive {:blocking_notify_attempt, ^event, delete_pid}, 5_000

    refute unboxed(fn ->
             Repo.get_by(PrincipalPolicy,
               principal_arn: user.user_arn,
               policy_name: policy_name
             )
           end)

    send(delete_pid, {:release_blocking_notify, event})
    assert :ok = Task.await(delete_task, 10_000)
  end

  test "no-notify identity policy backend operations emit nothing when an outer transaction rolls back" do
    user_name = unique_name("policy-event-rollback")
    assert {:ok, user} = IAM.create_user(name: user_name)
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Maxio.Cluster.Notify.topic())

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert :ok =
                        Store.put_principal_policy_without_notify(
                          user.user_arn,
                          "read",
                          @policy
                        )

               Repo.rollback(:forced_rollback)
             end)

    refute Repo.get_by(PrincipalPolicy, principal_arn: user.user_arn, policy_name: "read")
    refute_receive {:principal_policy_changed, _principal_arn}

    assert :ok = Store.put_principal_policy(user.user_arn, "read", @policy)
    assert_receive {:principal_policy_changed, principal_arn}
    assert principal_arn == user.user_arn

    assert {:error, :forced_delete_rollback} =
             Repo.transaction(fn ->
               assert :ok =
                        Store.delete_principal_policy_without_notify(user.user_arn, "read")

               Repo.rollback(:forced_delete_rollback)
             end)

    assert Repo.get_by(PrincipalPolicy,
             principal_arn: user.user_arn,
             policy_name: "read"
           )

    refute_receive {:principal_policy_changed, _principal_arn}
  end

  defp unique_access_key(prefix),
    do: "ASIA#{prefix}#{System.unique_integer([:positive, :monotonic])}"

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  defp cleanup_unboxed_credentials!(access_key_ids) do
    unboxed(fn ->
      session_ids = session_descendant_ids(MapSet.new(access_key_ids)) |> MapSet.to_list()
      Repo.delete_all(from(s in STSSession, where: s.access_key_id in ^session_ids))
      Repo.delete_all(from(a in AccessKey, where: a.access_key_id in ^access_key_ids))
    end)
  end

  defp session_descendant_ids(access_key_ids) do
    child_ids =
      Repo.all(
        from(s in STSSession,
          where: s.issuer_access_key_id in ^MapSet.to_list(access_key_ids),
          select: s.access_key_id
        )
      )
      |> MapSet.new()

    expanded = MapSet.union(access_key_ids, child_ids)

    if MapSet.equal?(expanded, access_key_ids) do
      expanded
    else
      session_descendant_ids(expanded)
    end
  end

  defp insert_session!(access_key_id, issuer_access_key_id, principal_arn, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%STSSession{
      access_key_id: access_key_id,
      secret_key: "fixture-secret",
      session_token_sha256: String.duplicate("b", 64),
      issuer_access_key_id: issuer_access_key_id,
      principal_arn: principal_arn,
      principal_type: "assumed_role",
      session_name: "fixture",
      status: Keyword.get(opts, :status, "active"),
      issued_at: now,
      expires_at: DateTime.add(now, 900, :second),
      tags: %{},
      web_identity_provider_arn: Keyword.get(opts, :web_identity_provider_arn),
      web_identity_subject_sha256: Keyword.get(opts, :web_identity_subject_sha256),
      web_identity_audience: Keyword.get(opts, :web_identity_audience)
    })
  end

  defp assert_backend_waits_on_lock!(backend_pid) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    poll_backend_lock!(backend_pid, deadline, nil)
  end

  defp poll_backend_lock!(backend_pid, deadline, last_observed) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT wait_event_type, wait_event, state FROM pg_stat_activity WHERE pid = $1",
        [backend_pid]
      )

    observed = List.first(rows)

    cond do
      match?(["Lock", _wait_event, _state], observed) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "backend #{backend_pid} did not wait on identity lock; observed=#{inspect(observed || last_observed)}"
        )

      true ->
        :erlang.yield()
        poll_backend_lock!(backend_pid, deadline, observed || last_observed)
    end
  end

  defp unique_name(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
