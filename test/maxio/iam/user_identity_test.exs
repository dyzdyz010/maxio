defmodule Maxio.IAM.UserIdentityTest do
  use Maxio.DataCase, async: false

  alias Maxio.IAM
  alias Maxio.IAM.{MFADevice, STSSession, UserIdentity}
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

  defp unique_access_key(prefix),
    do: "ASIA#{prefix}#{System.unique_integer([:positive, :monotonic])}"

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
      status: "active",
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
