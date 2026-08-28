defmodule Maxio.IAM.MinioAdminUserTest do
  use Maxio.DataCase, async: false

  alias Maxio.Auth.CredentialStore.EctoStore
  alias Maxio.Cluster.Notify
  alias Maxio.IAM

  alias Maxio.IAM.{
    AccessKey,
    AccessKeySecret,
    CredentialNamespace,
    Group,
    GroupMembership,
    MFADevice,
    STSSession,
    User
  }

  alias Maxio.Policy.PrincipalPolicy
  alias Maxio.S3.Plugs.SigV4
  alias Maxio.STS
  alias Maxio.Test.SigV4Request

  setup do
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())
    flush_iam_events()
    :ok
  end

  test "atomically creates one explicit user and encrypted same-name credential" do
    access_key = unique_access_key("CREATE")
    secret = "new-user-secret-#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, %{user: user, access_key: key} = result} =
             IAM.create_minio_user_strict(access_key, secret, "active")

    assert user.user_name == access_key
    assert user.user_arn == IAM.user_arn(access_key)
    assert user.status == "active"
    assert key.access_key_id == access_key
    assert key.principal_arn == user.user_arn
    assert key.status == "active"
    refute Map.has_key?(key, :secret_key)
    refute inspect(result) =~ secret

    assert %AccessKey{secret_key: stored_secret} =
             Repo.get_by(AccessKey, access_key_id: access_key)

    assert AccessKeySecret.encrypted?(stored_secret)
    refute stored_secret == secret
    assert {:ok, %{secret_key: ^secret}} = EctoStore.get_secret(access_key)

    assert_receive {:iam_changed, ^access_key}
    refute_receive {:iam_changed, _other}
  end

  test "an exact access-key collision rolls back the attempted user and preserves the old key" do
    owner = unique_access_key("OWNER")
    colliding_key = unique_access_key("COLLIDE")
    old_secret = "old-credential-secret"
    new_secret = "new-credential-secret-do-not-leak"

    assert {:ok, _owner} = IAM.create_user(name: owner)

    assert {:ok, _key} =
             IAM.create_access_key(
               access_key_id: colliding_key,
               secret_key: old_secret,
               user_name: owner
             )

    old_row = Repo.get_by!(AccessKey, access_key_id: colliding_key)
    flush_iam_events()

    result = IAM.create_minio_user_strict(colliding_key, new_secret, "active")

    assert {:error, :user_already_exists} = result
    assert :error = IAM.get_user(colliding_key)
    assert Repo.get_by!(AccessKey, access_key_id: colliding_key).id == old_row.id
    assert {:ok, %{secret_key: ^old_secret}} = EctoStore.get_secret(colliding_key)
    refute inspect(result) =~ new_secret
    refute_receive {:iam_changed, _target}
  end

  test "an STS credential owns its exact id for its full persisted lifetime" do
    issuer_key = unique_access_key("ISSUER")
    session_key = unique_access_key("SESSION")
    session_secret = "existing-session-secret"
    session_token = "existing-session-token"

    assert {:ok, issuer} =
             IAM.create_access_key(
               access_key_id: issuer_key,
               secret_key: "session-issuer-secret"
             )

    assert {:ok, session} =
             STS.issue_session(
               issuer_access_key_id: issuer.access_key_id,
               session_access_key_id: session_key,
               secret_key: session_secret,
               session_token: session_token,
               duration_seconds: 900
             )

    flush_iam_events()
    before_users = Repo.aggregate(User, :count)
    before_keys = Repo.aggregate(AccessKey, :count)
    before_sessions = Repo.aggregate(STSSession, :count)

    assert {:error, :user_already_exists} =
             IAM.create_minio_user_strict(session_key, "must-not-shadow-session", "active")

    assert Repo.aggregate(User, :count) == before_users
    assert Repo.aggregate(AccessKey, :count) == before_keys
    assert Repo.aggregate(STSSession, :count) == before_sessions
    assert :error = IAM.get_user(session_key)

    assert {:ok, %{secret_key: ^session_secret}} =
             EctoStore.get_secret(session_key,
               session_token: session_token,
               now: DateTime.add(session.issued_at, 1, :second)
             )

    previous_store = Application.fetch_env!(:maxio, :credential_store)
    Application.put_env(:maxio, :credential_store, EctoStore)
    on_exit(fn -> Application.put_env(:maxio, :credential_store, previous_store) end)

    authenticated =
      :get
      |> SigV4Request.signed_conn("/sts-still-valid",
        access_key: session_key,
        secret: session_secret,
        session_token: session_token
      )
      |> SigV4.call(SigV4.init([]))

    refute authenticated.halted
    assert authenticated.assigns.principal.credential_type == :session
    assert authenticated.assigns.principal.session_access_key == session_key

    refute_receive {:iam_changed, _target}

    assert {:ok, _revoked} = STS.revoke_session(session_key)
    flush_iam_events()

    assert {:error, :user_already_exists} =
             IAM.create_minio_user_strict(session_key, "must-not-reuse-revoked-id", "active")

    assert Repo.aggregate(User, :count) == before_users
    assert Repo.aggregate(AccessKey, :count) == before_keys
    assert Repo.aggregate(STSSession, :count) == before_sessions
    assert Repo.get_by!(STSSession, access_key_id: session_key).status == "revoked"
    refute_receive {:iam_changed, _target}
  end

  test "U1 and STS serialize the same exact credential id without cross-table shadowing" do
    issuer_key = unique_access_key("RACEISSUER")
    access_key = unique_access_key("RACENAMESPACE")
    user_secret = "concurrent-user-secret"
    session_secret = "concurrent-session-secret"
    session_token = "concurrent-session-token"

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(s in STSSession, where: s.access_key_id == ^access_key))
        Repo.delete_all(from(a in AccessKey, where: a.access_key_id in ^[access_key, issuer_key]))
        Repo.delete_all(from(u in User, where: u.user_name == ^access_key))
      end)
    end)

    assert {:ok, issuer} =
             unboxed(fn ->
               IAM.create_access_key(
                 access_key_id: issuer_key,
                 secret_key: "concurrent-issuer-secret"
               )
             end)

    flush_iam_events()
    owner = self()
    barrier_ref = make_ref()
    handler_id = {__MODULE__, barrier_ref}
    query_handler_id = {__MODULE__, {:query, barrier_ref}}

    :ok =
      :telemetry.attach(
        handler_id,
        [:maxio, :iam, :credential_namespace, :lock_wait],
        fn _event, _measurements, metadata, {test_pid, ref, target_access_key} ->
          if metadata.access_key_id == target_access_key do
            send(test_pid, {:namespace_lock_wait, ref, self()})

            receive do
              {:release_namespace_lock, ^ref} -> :ok
            after
              5_000 -> raise "credential namespace barrier timed out"
            end
          end
        end,
        {owner, barrier_ref, access_key}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        query_handler_id,
        [:maxio, :repo, :query],
        fn _event, _measurements, metadata, {test_pid, ref, target_access_key} ->
          if String.contains?(metadata.query, "pg_advisory_xact_lock") and
               target_access_key in metadata.params do
            send(test_pid, {:namespace_lock_acquired, ref, self()})
          end
        end,
        {owner, barrier_ref, access_key}
      )

    on_exit(fn -> :telemetry.detach(query_handler_id) end)

    user_task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          {:user, IAM.create_minio_user_strict(access_key, user_secret, "active")}
        end)
      end)

    session_task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          {:session,
           STS.issue_session(
             issuer_access_key_id: issuer.access_key_id,
             session_access_key_id: access_key,
             secret_key: session_secret,
             session_token: session_token,
             duration_seconds: 900
           )}
        end)
      end)

    waiting_pids =
      for _task <- [user_task, session_task] do
        assert_receive {:namespace_lock_wait, ^barrier_ref, pid}, 5_000
        pid
      end

    Enum.each(waiting_pids, &send(&1, {:release_namespace_lock, barrier_ref}))

    results = [Task.await(user_task, 30_000), Task.await(session_task, 30_000)]
    user_result = Keyword.fetch!(results, :user)
    session_result = Keyword.fetch!(results, :session)

    lock_pids =
      for _task <- [user_task, session_task] do
        assert_receive {:namespace_lock_acquired, ^barrier_ref, pid}, 5_000
        pid
      end

    assert MapSet.size(MapSet.new(lock_pids)) == 2
    refute_receive {:namespace_lock_acquired, ^barrier_ref, _extra}

    access_key_count =
      Repo.aggregate(from(a in AccessKey, where: a.access_key_id == ^access_key), :count)

    session_count =
      Repo.aggregate(from(s in STSSession, where: s.access_key_id == ^access_key), :count)

    assert access_key_count + session_count == 1
    refute access_key_count == 1 and session_count == 1

    assert Repo.aggregate(from(u in User, where: u.user_name == ^access_key), :count) ==
             access_key_count

    case {user_result, session_result} do
      {{:ok, _user}, {:error, :access_key_id_conflict}} ->
        assert {:ok, %{secret_key: ^user_secret}} = EctoStore.get_secret(access_key)

      {{:error, :user_already_exists}, {:ok, session}} ->
        assert {:ok, %{secret_key: ^session_secret}} =
                 EctoStore.get_secret(access_key,
                   session_token: session_token,
                   now: DateTime.add(session.issued_at, 1, :second)
                 )

      other ->
        flunk("expected exactly one namespace winner, got: #{inspect(other)}")
    end

    assert_receive {:iam_changed, ^access_key}
    refute_receive {:iam_changed, _other}
  end

  test "U5 disable and enable are reversible for long-term and descendant STS credentials" do
    access_key = unique_access_key("STATUS")
    secret = "status-user-secret"
    session_key = unique_access_key("STATUSSESSION")
    session_secret = "status-session-secret"
    session_token = "status-session-token"

    assert {:ok, %{user: user}} =
             IAM.create_minio_user_strict(access_key, secret, "active")

    assert {:ok, session} =
             STS.issue_session(
               issuer_access_key_id: access_key,
               session_access_key_id: session_key,
               secret_key: session_secret,
               session_token: session_token,
               duration_seconds: 900
             )

    before_key = Repo.get_by!(AccessKey, access_key_id: access_key)
    before_session = Repo.get_by!(STSSession, access_key_id: session_key)
    now = DateTime.add(session.issued_at, 1, :second)
    assert {:ok, %{secret_key: ^secret}} = EctoStore.get_secret(access_key)

    assert {:ok, %{secret_key: ^session_secret}} =
             EctoStore.get_secret(session_key, session_token: session_token, now: now)

    assert {:ok, disabled} =
             IAM.update_minio_user_status_strict(user.user_name, "inactive", session_key)

    assert disabled.user.status == "inactive"
    assert disabled.affected.credentials == 2

    after_key = Repo.get_by!(AccessKey, access_key_id: access_key)
    after_session = Repo.get_by!(STSSession, access_key_id: session_key)

    assert Map.take(after_key, [:id, :secret_key, :status]) ==
             Map.take(before_key, [:id, :secret_key, :status])

    assert Map.take(after_session, [
             :id,
             :secret_key,
             :status,
             :expires_at,
             :revoked_at
           ]) ==
             Map.take(before_session, [
               :id,
               :secret_key,
               :status,
               :expires_at,
               :revoked_at
             ])

    assert :error = EctoStore.get_secret(access_key)

    assert {:error, :invalid_token} =
             EctoStore.get_secret(session_key, session_token: session_token, now: now)

    root_actor = Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)

    assert {:ok, enabled} =
             IAM.update_minio_user_status_strict(user.user_name, "active", root_actor)

    assert enabled.user.status == "active"
    assert {:ok, %{secret_key: ^secret}} = EctoStore.get_secret(access_key)

    assert {:ok, %{secret_key: ^session_secret}} =
             EctoStore.get_secret(session_key, session_token: session_token, now: now)
  end

  test "U5 classifies root, session, and subordinate-key targets before mutation" do
    access_key = unique_access_key("STATUSCLASS")
    secret = "status-class-secret"
    session_key = unique_access_key("STATUSCLASSSESSION")

    assert {:ok, %{user: user}} =
             IAM.create_minio_user_strict(access_key, secret, "active")

    assert {:ok, subordinate_key} = IAM.create_access_key_strict(user.user_name)

    assert {:ok, _session} =
             STS.issue_session(
               issuer_access_key_id: access_key,
               session_access_key_id: session_key,
               secret_key: "status-class-session-secret",
               session_token: "status-class-session-token",
               duration_seconds: 900
             )

    root_actor = Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)

    assert {:error, :invalid_status_self_target} =
             IAM.update_minio_user_status_strict(root_actor, "inactive", root_actor)

    assert {:error, :minio_user_not_found} =
             IAM.update_minio_user_status_strict(root_actor, "inactive", access_key)

    assert {:error, :minio_user_not_found} =
             IAM.update_minio_user_status_strict(session_key, "inactive", root_actor)

    assert {:error, :minio_action_not_allowed} =
             IAM.update_minio_user_status_strict(
               subordinate_key.access_key_id,
               "inactive",
               root_actor
             )

    assert Repo.get_by!(User, user_name: user.user_name).status == "active"
  end

  test "U5 exact signer self target is rejected and same-status writes advance updated_at" do
    access_key = unique_access_key("STATUSSELF")
    secret = "status-self-secret"
    assert {:ok, %{user: user}} = IAM.create_minio_user_strict(access_key, secret, "active")

    assert {:error, :invalid_status_self_target} =
             IAM.update_minio_user_status_strict(user.user_name, "inactive", access_key)

    before = Repo.get_by!(User, user_name: user.user_name)
    actor = Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)

    assert {:ok, %{user: %{status: "active"}}} =
             IAM.update_minio_user_status_strict(user.user_name, "active", actor)

    after_write = Repo.get_by!(User, user_name: user.user_name)
    assert DateTime.compare(after_write.updated_at, before.updated_at) == :gt
  end

  test "U4 atomically cascades user state and permanently revokes descendant sessions" do
    access_key = unique_access_key("REMOVE")
    direct_key = unique_access_key("REMOVEDIRECT")
    chained_key = unique_access_key("REMOVECHAIN")
    direct_token = "remove-direct-token"
    chained_token = "remove-chain-token"
    group_name = "remove-group-#{System.unique_integer([:positive, :monotonic])}"
    managed_policy_name = "remove-policy-#{System.unique_integer([:positive, :monotonic])}"

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::remove/*"}})

    assert {:ok, %{user: user}} =
             IAM.create_minio_user_strict(access_key, "remove-user-secret", "active")

    assert {:ok, subordinate} = IAM.create_access_key_strict(user.user_name)
    assert {:ok, group} = IAM.create_group(name: group_name)

    assert {:ok, managed_policy} =
             IAM.create_managed_policy(name: managed_policy_name, document: policy)

    assert :ok = IAM.add_user_to_group_strict(user.user_name, group.group_name)
    assert :ok = IAM.put_user_policy_strict(user.user_name, "remove-inline", policy)
    assert :ok = IAM.put_group_policy(group.group_name, "retained-inline", policy)
    assert :ok = IAM.attach_user_policy(user.user_name, managed_policy.policy_arn)

    assert {:ok, _mfa} =
             IAM.create_mfa_device(
               principal_arn: user.user_arn,
               device_name: "remove-device",
               serial: "arn:aws:iam:::mfa/#{user.user_name}"
             )

    assert {:ok, direct} =
             STS.issue_session(
               issuer_access_key_id: access_key,
               session_access_key_id: direct_key,
               secret_key: "remove-direct-secret",
               session_token: direct_token,
               duration_seconds: 900
             )

    chained =
      Repo.insert!(%STSSession{
        access_key_id: chained_key,
        secret_key: "fixture-encrypted-secret",
        session_token_sha256: :crypto.hash(:sha256, chained_token) |> Base.encode16(case: :lower),
        issuer_access_key_id: direct_key,
        principal_arn: "arn:aws:iam:::role/remove-chain",
        principal_type: "assumed_role",
        session_name: "remove-chain",
        status: "active",
        issued_at: direct.issued_at,
        expires_at: direct.expires_at,
        tags: %{}
      })

    assert {:ok, removed} = IAM.delete_minio_user_strict(user.user_name, direct_key)

    assert removed.user.user_name == user.user_name
    assert removed.affected.access_keys_deleted == 2
    assert removed.affected.sessions_revoked == 2
    assert removed.affected.principal_policies_deleted == 1
    assert removed.affected.memberships_deleted == 1
    assert removed.affected.managed_policy_attachments_deleted == 1
    assert removed.affected.mfa_devices_deleted == 1
    assert removed.invalidation.failures == []

    refute Repo.get_by(User, id: user.id)
    refute Repo.get_by(AccessKey, access_key_id: access_key)
    refute Repo.get_by(AccessKey, access_key_id: subordinate.access_key_id)
    refute Repo.get_by(PrincipalPolicy, principal_arn: user.user_arn)
    refute Repo.get_by(GroupMembership, user_arn: user.user_arn)
    refute Repo.get_by(MFADevice, principal_arn: user.user_arn)
    assert Repo.get_by!(Group, group_name: group_name).id == group.id
    assert {:ok, %{policy_arn: policy_arn}} = IAM.get_managed_policy(managed_policy.policy_arn)
    assert policy_arn == managed_policy.policy_arn

    assert [%{policy_name: "retained-inline"}] =
             IAM.list_principal_policies(group.group_arn)

    assert Repo.get_by!(STSSession, access_key_id: direct.access_key_id).status == "revoked"
    assert Repo.get_by!(STSSession, access_key_id: chained.access_key_id).status == "revoked"

    assert {:error, :access_key_id_conflict} =
             Repo.transaction(fn -> CredentialNamespace.reserve_exact(Repo, direct_key) end)
             |> elem(1)

    assert {:ok, %{user: replacement}} =
             IAM.create_minio_user_strict(access_key, "replacement-secret", "active")

    refute replacement.id == user.id

    now = DateTime.add(direct.issued_at, 1, :second)

    assert {:error, :invalid_token} =
             EctoStore.get_secret(direct_key, session_token: direct_token, now: now)

    assert {:error, :invalid_token} =
             EctoStore.get_secret(chained_key, session_token: chained_token, now: now)
  end

  test "U4 target classification and sequential removal are exact and mutation-free" do
    access_key = unique_access_key("REMOVECLASS")
    session_key = unique_access_key("REMOVECLASSSESSION")
    assert {:ok, %{user: user}} = IAM.create_minio_user_strict(access_key, "secret", "active")
    assert {:ok, subordinate} = IAM.create_access_key_strict(user.user_name)

    assert {:ok, _session} =
             STS.issue_session(
               issuer_access_key_id: access_key,
               session_access_key_id: session_key,
               secret_key: "remove-class-session-secret",
               session_token: "remove-class-session-token",
               duration_seconds: 900
             )

    root_actor = Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)

    assert {:error, :minio_user_not_found} =
             IAM.delete_minio_user_strict(root_actor, root_actor)

    assert {:error, :minio_action_not_allowed} =
             IAM.delete_minio_user_strict(user.user_name, access_key)

    assert {:error, :minio_action_not_allowed} =
             IAM.delete_minio_user_strict(session_key, root_actor)

    assert {:error, :minio_action_not_allowed} =
             IAM.delete_minio_user_strict(subordinate.access_key_id, root_actor)

    assert Repo.get_by!(User, id: user.id).status == "active"
    assert {:ok, _removed} = IAM.delete_minio_user_strict(user.user_name, root_actor)

    assert {:error, :minio_user_not_found} =
             IAM.delete_minio_user_strict(user.user_name, root_actor)
  end

  test "two concurrent U4 removals linearize to one success and one no-such-user" do
    access_key = unique_access_key("REMOVERACE")

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(a in AccessKey, where: a.access_key_id == ^access_key))
        Repo.delete_all(from(u in User, where: u.user_name == ^access_key))
      end)
    end)

    assert {:ok, %{user: user}} =
             unboxed(fn -> IAM.create_minio_user_strict(access_key, "secret", "active") end)

    parent = self()
    barrier_ref = make_ref()
    handler_id = {__MODULE__, barrier_ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:maxio, :iam, :user_identity, :lock_wait],
        fn _event, _measurements, metadata, {test_pid, ref, target} ->
          if metadata.case_folded_user_name == String.downcase(target) do
            send(test_pid, {:u4_lock_wait, ref, self()})

            receive do
              {:release_u4_lock, ^ref} -> :ok
            after
              5_000 -> raise "U4 lock barrier timed out"
            end
          end
        end,
        {parent, barrier_ref, user.user_name}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    root_actor = Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)

    tasks =
      for _attempt <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            IAM.delete_minio_user_strict(user.user_name, root_actor)
          end)
        end)
      end

    waiting =
      for _attempt <- 1..2 do
        assert_receive {:u4_lock_wait, ^barrier_ref, pid}, 5_000
        pid
      end

    Enum.each(waiting, &send(&1, {:release_u4_lock, barrier_ref}))
    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :minio_user_not_found})) == 1
    assert is_nil(unboxed(fn -> Repo.get_by(User, id: user.id) end))
  end

  test "two concurrent same-name creates commit exactly one pair and one notification" do
    access_key = unique_access_key("RACE")
    parent = self()

    tasks =
      for suffix <- ["one", "two"] do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)
          IAM.create_minio_user_strict(access_key, "race-secret-#{suffix}", "active")
        end)
      end

    ready_pids =
      for _task <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(ready_pids, &send(&1, :go))

    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :user_already_exists})) == 1
    assert Repo.aggregate(from(u in User, where: u.user_name == ^access_key), :count) == 1

    assert Repo.aggregate(
             from(a in AccessKey, where: a.access_key_id == ^access_key),
             :count
           ) == 1

    assert_receive {:iam_changed, ^access_key}
    refute_receive {:iam_changed, _other}
  end

  test "case-only duplicate users change no rows and emit no invalidation" do
    access_key = unique_access_key("CASE")
    assert {:ok, _created} = IAM.create_minio_user_strict(access_key, "case-secret-one", "active")
    flush_iam_events()

    before_users = Repo.aggregate(User, :count)
    before_keys = Repo.aggregate(AccessKey, :count)

    assert {:error, :user_already_exists} =
             IAM.create_minio_user_strict(
               String.downcase(access_key),
               "case-secret-two",
               "active"
             )

    assert Repo.aggregate(User, :count) == before_users
    assert Repo.aggregate(AccessKey, :count) == before_keys
    refute_receive {:iam_changed, _target}
  end

  defp flush_iam_events do
    receive do
      {:iam_changed, _target} -> flush_iam_events()
    after
      0 -> :ok
    end
  end

  defp unboxed(fun) do
    Task.async(fn -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun) end)
    |> Task.await(30_000)
  end

  defp unique_access_key(prefix) do
    suffix = System.unique_integer([:positive, :monotonic])
    String.pad_trailing("AKIA#{prefix}#{suffix}", 20, "X")
  end
end
