defmodule Maxio.IAM.MinioAdminPolicyConcurrencyTest do
  use Maxio.DataCase, async: false

  alias Maxio.IAM
  alias Maxio.IAM.UserManagedPolicyAttachment
  alias Maxio.Policy.ManagedPolicy

  @document %{
    "Version" => "2012-10-17",
    "Statement" => [
      %{"Effect" => "Allow", "Action" => "s3:ListAllMyBuckets", "Resource" => "*"}
    ]
  }

  test "batch and singular user attachments serialize on one principal quota lock" do
    suffix = random_suffix()
    user_name = "quota-user-#{suffix}"
    policy_names = Enum.map(1..11, &"quota-policy-#{suffix}-#{&1}")
    policy_arns = Enum.map(policy_names, &policy_arn/1)

    user =
      unboxed(fn ->
        assert {:ok, user} = IAM.create_user(name: user_name)
        Enum.each(policy_arns, &insert_policy!/1)

        policy_arns
        |> Enum.take(9)
        |> Enum.each(&insert_user_attachment!(user.user_arn, &1))

        user
      end)

    on_exit(fn -> cleanup_user_fixture(user_name, policy_arns) end)
    attach_principal_quota_barrier(user.user_arn)
    attach_identity_observer(:user, user_name)

    batch_task =
      Task.async(fn ->
        unboxed(fn ->
          IAM.update_managed_policy_associations_strict(
            :attach,
            {:user, user_name},
            [Enum.at(policy_names, 9)]
          )
        end)
      end)

    assert_receive {:observed_identity_lock_wait, batch_pid}
    assert_receive {:principal_quota_lock_wait, ^batch_pid}
    assert_receive {:principal_quota_locked, ^batch_pid}

    owner = self()

    singular_task =
      Task.async(fn ->
        send(owner, :singular_quota_case_started)
        unboxed(fn -> IAM.attach_user_policy_strict(user_name, Enum.at(policy_arns, 10)) end)
      end)

    assert_receive :singular_quota_case_started
    assert_receive {:observed_identity_lock_wait, singular_pid}, 1_000
    refute_receive {:principal_quota_lock_wait, ^singular_pid}, 100

    send(batch_pid, :release_principal_quota)
    assert {:ok, %{changed_policy_arns: [_]}} = Task.await(batch_task)

    assert_receive {:principal_quota_lock_wait, ^singular_pid}
    assert_receive {:principal_quota_locked, ^singular_pid}
    send(singular_pid, :release_principal_quota)

    assert {:error, :managed_policy_attachment_limit_exceeded} = Task.await(singular_task)

    assert 10 ==
             unboxed(fn ->
               Maxio.Policy.Store.list_attached_user_managed_policies(user.user_arn)
               |> length()
             end)
  end

  test "reversed batches acquire managed policy locks in the same stable order" do
    suffix = random_suffix()
    user_names = ["lock-order-a-#{suffix}", "lock-order-b-#{suffix}"]
    policy_names = ["lock-order-a-#{suffix}", "lock-order-b-#{suffix}"]
    policy_arns = Enum.map(policy_names, &policy_arn/1)
    [first_policy_arn, _second_policy_arn] = Enum.sort(policy_arns)

    unboxed(fn ->
      Enum.each(user_names, fn name -> assert {:ok, _user} = IAM.create_user(name: name) end)
      Enum.each(policy_arns, &insert_policy!/1)
    end)

    on_exit(fn ->
      Enum.each(user_names, &cleanup_user_fixture(&1, []))
      cleanup_policies(policy_arns)
    end)

    attach_managed_policy_lock_barrier(first_policy_arn)

    first_task =
      Task.async(fn ->
        unboxed(fn ->
          IAM.update_managed_policy_associations_strict(
            :attach,
            {:user, Enum.at(user_names, 0)},
            Enum.reverse(policy_names)
          )
        end)
      end)

    assert_receive {:managed_policy_lock_wait, first_pid, ^first_policy_arn}
    assert_receive {:managed_policy_locked, ^first_pid, ^first_policy_arn}

    second_task =
      Task.async(fn ->
        unboxed(fn ->
          IAM.update_managed_policy_associations_strict(
            :attach,
            {:user, Enum.at(user_names, 1)},
            policy_names
          )
        end)
      end)

    assert_receive {:managed_policy_lock_wait, second_pid, ^first_policy_arn}
    refute_receive {:managed_policy_locked, ^second_pid, ^first_policy_arn}, 100

    send(first_pid, :release_managed_policy)
    assert {:ok, %{changed_policy_arns: changed}} = Task.await(first_task)
    assert changed == Enum.sort(policy_arns)

    assert_receive {:managed_policy_locked, ^second_pid, ^first_policy_arn}
    send(second_pid, :release_managed_policy)
    assert {:ok, %{changed_policy_arns: changed}} = Task.await(second_task)
    assert changed == Enum.sort(policy_arns)
  end

  test "a user batch cannot cross a same-name delete and recreate generation" do
    suffix = random_suffix()
    user_name = "generation-user-#{suffix}"
    policy_name = "generation-policy-#{suffix}"
    policy_arn = policy_arn(policy_name)

    original =
      unboxed(fn ->
        assert {:ok, user} = IAM.create_user(name: user_name)
        insert_policy!(policy_arn)
        user
      end)

    on_exit(fn -> cleanup_user_fixture(user_name, [policy_arn]) end)

    handler_id = attach_identity_wait_barrier(:user, String.downcase(user_name))

    task =
      Task.async(fn ->
        unboxed(fn ->
          IAM.update_managed_policy_associations_strict(:attach, {:user, user_name}, [policy_name])
        end)
      end)

    assert_receive {:identity_lock_wait, batch_pid}
    :ok = :telemetry.detach(handler_id)

    replacement =
      unboxed(fn ->
        :ok = IAM.delete_user(user_name)
        assert {:ok, replacement} = IAM.create_user(name: user_name)
        replacement
      end)

    send(batch_pid, :release_identity_lock)

    assert {:error, :identity_changed} = Task.await(task)
    assert original.id != replacement.id

    assert [] ==
             unboxed(fn ->
               Maxio.Policy.Store.list_attached_user_managed_policies(replacement.user_arn)
             end)
  end

  test "a group batch cannot cross a same-name delete and recreate generation" do
    suffix = random_suffix()
    group_name = "generation-group-#{suffix}"
    policy_name = "generation-group-policy-#{suffix}"
    policy_arn = policy_arn(policy_name)

    original =
      unboxed(fn ->
        assert {:ok, group} = IAM.create_group(name: group_name)
        insert_policy!(policy_arn)
        group
      end)

    on_exit(fn -> cleanup_group_fixture(group_name, [policy_arn]) end)

    handler_id = attach_identity_wait_barrier(:group, String.downcase(group_name))

    task =
      Task.async(fn ->
        unboxed(fn ->
          IAM.update_managed_policy_associations_strict(
            :attach,
            {:group, group_name},
            [policy_name]
          )
        end)
      end)

    assert_receive {:identity_lock_wait, batch_pid}
    :ok = :telemetry.detach(handler_id)

    replacement =
      unboxed(fn ->
        :ok = IAM.delete_group(group_name)
        assert {:ok, replacement} = IAM.create_group(name: group_name)
        replacement
      end)

    send(batch_pid, :release_identity_lock)

    assert {:error, :identity_changed} = Task.await(task)
    assert original.id != replacement.id

    assert [] ==
             unboxed(fn ->
               Maxio.Policy.Store.list_attached_group_managed_policies(replacement.group_arn)
             end)
  end

  test "user batch and singular writers acquire identity before principal quota" do
    run_reverse_lock_order_case(:user)
  end

  test "group batch and singular writers acquire identity before principal quota" do
    run_reverse_lock_order_case(:group)
  end

  test "strict group deletion serializes with a batch attachment and rechecks blockers" do
    suffix = random_suffix()
    group_name = "delete-race-group-#{suffix}"
    policy_name = "delete-race-policy-#{suffix}"
    policy_arn = policy_arn(policy_name)

    group =
      unboxed(fn ->
        assert {:ok, group} = IAM.create_group(name: group_name)
        insert_policy!(policy_arn)
        group
      end)

    on_exit(fn -> cleanup_group_fixture(group_name, [policy_arn]) end)

    attach_pre_quota_order_barrier(:group, group_name, group.group_arn)

    batch_task =
      Task.async(fn ->
        unboxed(fn ->
          IAM.update_managed_policy_associations_strict(
            :attach,
            {:group, group_name},
            [policy_name]
          )
        end)
      end)

    assert_receive {:ordered_identity_wait, batch_pid}
    assert_receive {:ordered_quota_wait, ^batch_pid}

    owner = self()

    delete_task =
      Task.async(fn ->
        send(owner, :delete_group_started)
        unboxed(fn -> IAM.delete_group_strict(group_name) end)
      end)

    assert_receive :delete_group_started

    delete_identity_wait? =
      receive do
        {:ordered_identity_wait, delete_pid} when delete_pid != batch_pid -> true
      after
        250 -> false
      end

    send(batch_pid, {:release_ordered_quota, batch_pid})
    assert {:ok, %{changed_policy_arns: [^policy_arn]}} = Task.await(batch_task)

    delete_result = Task.await(delete_task)
    assert delete_identity_wait?
    assert {:error, {:group_delete_conflict, blockers}} = delete_result
    assert :managed_policy_attachments in blockers
    assert {:ok, _group} = unboxed(fn -> IAM.get_group(group_name) end)
  end

  test "group rename shares the identity boundary with batch attachments" do
    suffix = random_suffix()
    group_name = "rename-race-group-#{suffix}"
    renamed_group_name = "rename-race-target-#{suffix}"
    policy_name = "rename-race-policy-#{suffix}"
    policy_arn = policy_arn(policy_name)

    group =
      unboxed(fn ->
        assert {:ok, group} = IAM.create_group(name: group_name)
        insert_policy!(policy_arn)
        group
      end)

    on_exit(fn ->
      cleanup_group_fixture(group_name, [])
      cleanup_group_fixture(renamed_group_name, [policy_arn])
    end)

    attach_pre_quota_order_barrier(:group, group_name, group.group_arn)

    batch_task =
      Task.async(fn ->
        unboxed(fn ->
          IAM.update_managed_policy_associations_strict(
            :attach,
            {:group, group_name},
            [policy_name]
          )
        end)
      end)

    assert_receive {:ordered_identity_wait, batch_pid}
    assert_receive {:ordered_quota_wait, ^batch_pid}

    rename_task =
      Task.async(fn ->
        unboxed(fn -> IAM.update_group_name_strict(group_name, renamed_group_name) end)
      end)

    rename_identity_wait? =
      receive do
        {:ordered_identity_wait, rename_pid} when rename_pid != batch_pid -> true
      after
        250 -> false
      end

    send(batch_pid, {:release_ordered_quota, batch_pid})
    assert {:ok, %{changed_policy_arns: [^policy_arn]}} = Task.await(batch_task)
    assert {:ok, renamed_group} = Task.await(rename_task)
    assert rename_identity_wait?
    assert renamed_group.group_name == renamed_group_name

    assert [%{policy_arn: ^policy_arn}] =
             unboxed(fn ->
               Maxio.Policy.Store.list_attached_group_managed_policies(renamed_group.group_arn)
             end)
  end

  test "a unique conflict from a legacy writer becomes a typed no-effect result" do
    suffix = random_suffix()
    user_name = "unique-conflict-user-#{suffix}"
    policy_name = "unique-conflict-policy-#{suffix}"
    policy_arn = policy_arn(policy_name)

    user =
      unboxed(fn ->
        assert {:ok, user} = IAM.create_user(name: user_name)
        insert_policy!(policy_arn)
        user
      end)

    on_exit(fn -> cleanup_user_fixture(user_name, [policy_arn]) end)
    owner = self()
    handler_id = {__MODULE__, :unique_conflict, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:maxio, :policy, :managed_policy_attachment, :before_insert],
        fn _event, _measurements, metadata, test_pid ->
          if metadata.principal_arn == user.user_arn and metadata.policy_arns == [policy_arn] do
            insert_user_attachment!(user.user_arn, policy_arn)
            send(test_pid, :legacy_attachment_inserted)
          end
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :policy_change_already_applied} =
             unboxed(fn ->
               IAM.update_managed_policy_associations_strict(
                 :attach,
                 {:user, user_name},
                 [policy_name]
               )
             end)

    assert_receive :legacy_attachment_inserted

    # The injected legacy row shares this transaction, so the typed no-effect rollback removes it.
    # A genuinely external conflicting row would remain committed; in both cases no unique error leaks.
    assert [] ==
             unboxed(fn ->
               Maxio.Policy.Store.list_attached_user_managed_policies(user.user_arn)
             end)
  end

  defp attach_principal_quota_barrier(principal_arn) do
    owner = self()
    handler_id = {__MODULE__, :principal_quota, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:maxio, :policy, :principal_quota, :lock_wait],
          [:maxio, :policy, :principal_quota, :locked]
        ],
        fn event, _measurements, metadata, test_pid ->
          if metadata.principal_arn == principal_arn do
            case List.last(event) do
              :lock_wait ->
                send(test_pid, {:principal_quota_lock_wait, self()})

              :locked ->
                send(test_pid, {:principal_quota_locked, self()})

                receive do
                  :release_principal_quota -> :ok
                end
            end
          end
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp attach_identity_observer(kind, principal_name) do
    owner = self()
    handler_id = {__MODULE__, :identity_observer, kind, make_ref()}
    event = [:maxio, :iam, kind_identity_event(kind), :lock_wait]
    metadata_key = if kind == :user, do: :case_folded_user_name, else: :case_folded_group_name
    case_folded_name = String.downcase(principal_name)

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, test_pid ->
          if Map.fetch!(metadata, metadata_key) == case_folded_name do
            send(test_pid, {:observed_identity_lock_wait, self()})
          end
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp run_reverse_lock_order_case(kind) do
    suffix = random_suffix()
    principal_name = "reverse-#{kind}-#{suffix}"
    policy_names = ["reverse-#{kind}-a-#{suffix}", "reverse-#{kind}-b-#{suffix}"]
    policy_arns = Enum.map(policy_names, &policy_arn/1)

    principal =
      unboxed(fn ->
        {:ok, principal} = create_principal(kind, principal_name)
        Enum.each(policy_arns, &insert_policy!/1)
        principal
      end)

    principal_arn = principal_arn(kind, principal)

    on_exit(fn -> cleanup_principal_fixture(kind, principal_name, policy_arns) end)
    attach_pre_quota_order_barrier(kind, principal_name, principal_arn)

    batch_task =
      Task.async(fn ->
        unboxed(fn ->
          IAM.update_managed_policy_associations_strict(
            :attach,
            {kind, principal_name},
            [Enum.at(policy_names, 0)]
          )
        end)
      end)

    assert_receive {:ordered_identity_wait, batch_pid}
    assert_receive {:ordered_quota_wait, ^batch_pid}

    singular_task =
      Task.async(fn ->
        unboxed(fn ->
          attach_principal_policy_strict(
            kind,
            principal_name,
            Enum.at(policy_arns, 1)
          )
        end)
      end)

    observed =
      receive do
        {:ordered_identity_wait, singular_pid} when singular_pid != batch_pid ->
          {:identity, singular_pid}

        {:ordered_quota_wait, singular_pid} when singular_pid != batch_pid ->
          {:quota, singular_pid}
      after
        1_000 -> :missing
      end

    send(batch_pid, {:release_ordered_quota, batch_pid})
    assert {:ok, %{changed_policy_arns: [_]}} = Task.await(batch_task)

    singular_pid =
      case observed do
        {:identity, singular_pid} ->
          assert_receive {:ordered_quota_wait, ^singular_pid}
          singular_pid

        {:quota, singular_pid} ->
          singular_pid

        :missing ->
          flunk("singular writer reached neither identity nor quota lock")
      end

    send(singular_pid, {:release_ordered_quota, singular_pid})
    assert :ok = Task.await(singular_task)
    assert {:identity, ^singular_pid} = observed

    assert 2 ==
             unboxed(fn ->
               list_principal_attachments(kind, principal_arn)
               |> length()
             end)
  end

  defp attach_pre_quota_order_barrier(kind, principal_name, principal_arn) do
    owner = self()
    handler_id = {__MODULE__, :ordered_writers, kind, make_ref()}
    identity_event = [:maxio, :iam, kind_identity_event(kind), :lock_wait]
    quota_event = [:maxio, :policy, :principal_quota, :lock_wait]
    metadata_key = if kind == :user, do: :case_folded_user_name, else: :case_folded_group_name
    case_folded_name = String.downcase(principal_name)

    :ok =
      :telemetry.attach_many(
        handler_id,
        [identity_event, quota_event],
        fn event, _measurements, metadata, test_pid ->
          cond do
            event == identity_event and Map.fetch!(metadata, metadata_key) == case_folded_name ->
              send(test_pid, {:ordered_identity_wait, self()})

            event == quota_event and metadata.principal_arn == principal_arn ->
              send(test_pid, {:ordered_quota_wait, self()})

              receive do
                {:release_ordered_quota, pid} when pid == self() -> :ok
              end

            true ->
              :ok
          end
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp create_principal(:user, name), do: IAM.create_user(name: name)
  defp create_principal(:group, name), do: IAM.create_group(name: name)
  defp principal_arn(:user, principal), do: principal.user_arn
  defp principal_arn(:group, principal), do: principal.group_arn

  defp attach_principal_policy_strict(:user, name, policy_arn),
    do: IAM.attach_user_policy_strict(name, policy_arn)

  defp attach_principal_policy_strict(:group, name, policy_arn),
    do: IAM.attach_group_policy_strict(name, policy_arn)

  defp list_principal_attachments(:user, arn),
    do: Maxio.Policy.Store.list_attached_user_managed_policies(arn)

  defp list_principal_attachments(:group, arn),
    do: Maxio.Policy.Store.list_attached_group_managed_policies(arn)

  defp cleanup_principal_fixture(:user, name, policy_arns),
    do: cleanup_user_fixture(name, policy_arns)

  defp cleanup_principal_fixture(:group, name, policy_arns),
    do: cleanup_group_fixture(name, policy_arns)

  defp attach_managed_policy_lock_barrier(policy_arn) do
    owner = self()
    handler_id = {__MODULE__, :managed_policy, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:maxio, :policy, :managed_policy, :lock_wait],
          [:maxio, :policy, :managed_policy, :locked]
        ],
        fn event, _measurements, metadata, test_pid ->
          if metadata.policy_arn == policy_arn do
            case List.last(event) do
              :lock_wait ->
                send(test_pid, {:managed_policy_lock_wait, self(), policy_arn})

              :locked ->
                send(test_pid, {:managed_policy_locked, self(), policy_arn})

                receive do
                  :release_managed_policy -> :ok
                end
            end
          end
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp attach_identity_wait_barrier(kind, case_folded_name) do
    owner = self()
    handler_id = {__MODULE__, kind, :identity, make_ref()}
    event = [:maxio, :iam, kind_identity_event(kind), :lock_wait]
    metadata_key = if kind == :user, do: :case_folded_user_name, else: :case_folded_group_name

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, test_pid ->
          if Map.fetch!(metadata, metadata_key) == case_folded_name do
            send(test_pid, {:identity_lock_wait, self()})

            receive do
              :release_identity_lock -> :ok
            end
          end
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp kind_identity_event(:user), do: :user_identity
  defp kind_identity_event(:group), do: :group_identity

  defp insert_policy!(policy_arn) do
    %ManagedPolicy{}
    |> ManagedPolicy.changeset(%{policy_arn: policy_arn, document: @document})
    |> Repo.insert!()
  end

  defp insert_user_attachment!(user_arn, policy_arn) do
    Repo.insert!(%UserManagedPolicyAttachment{user_arn: user_arn, policy_arn: policy_arn})
  end

  defp cleanup_user_fixture(user_name, policy_arns) do
    unboxed(fn ->
      :ok = IAM.delete_user(user_name)
      Repo.delete_all(from p in ManagedPolicy, where: p.policy_arn in ^policy_arns)
    end)
  end

  defp cleanup_policies(policy_arns) do
    unboxed(fn ->
      Repo.delete_all(from p in ManagedPolicy, where: p.policy_arn in ^policy_arns)
    end)
  end

  defp cleanup_group_fixture(group_name, policy_arns) do
    unboxed(fn ->
      :ok = IAM.delete_group(group_name)
      Repo.delete_all(from p in ManagedPolicy, where: p.policy_arn in ^policy_arns)
    end)
  end

  defp policy_arn(name), do: "arn:aws:iam:::policy/#{name}"
  defp random_suffix, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
