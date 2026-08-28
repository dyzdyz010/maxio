defmodule Maxio.IAM.AdminGroupLifecycleConcurrencyTest do
  use Maxio.DataCase, async: false

  import Ecto.Query

  alias Maxio.IAM
  alias Maxio.IAM.{Group, GroupMembership, User}

  test "all singular membership writers share group-user-membership lock order" do
    for {function, seed_membership?} <- [
          {:add_user_to_group, false},
          {:add_user_to_group_strict, false},
          {:remove_user_from_group, true},
          {:remove_user_from_group_strict, true}
        ] do
      suffix = System.unique_integer([:positive, :monotonic])
      group_name = "singular-group-#{suffix}"
      user_name = "singular-user-#{suffix}"
      assert {:ok, user} = IAM.create_user(name: user_name)
      assert {:ok, group} = IAM.create_group(name: group_name)

      if seed_membership? do
        Repo.insert!(%GroupMembership{user_arn: user.user_arn, group_arn: group.group_arn})
      end

      owner = self()
      handler_id = {__MODULE__, function, make_ref()}

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:maxio, :iam, :group_identity, :lock_wait],
            [:maxio, :iam, :user_identity, :lock_wait],
            [:maxio, :iam, :group_membership, :before_mutation]
          ],
          fn event, _measurements, metadata, test_pid ->
            send(test_pid, {:singular_lock_event, event, metadata})
          end,
          owner
        )

      assert :ok = apply(IAM, function, [String.upcase(user_name), String.upcase(group_name)])
      :ok = :telemetry.detach(handler_id)

      assert_receive {:singular_lock_event, [:maxio, :iam, :group_identity, :lock_wait], _}
      assert_receive {:singular_lock_event, [:maxio, :iam, :user_identity, :lock_wait], _}

      assert_receive {:singular_lock_event, [:maxio, :iam, :group_membership, :before_mutation],
                      _}
    end
  end

  test "reversed batches expose group identity before case-fold sorted user identities" do
    suffix = System.unique_integer([:positive, :monotonic])
    group_name = "order-group-#{suffix}"
    user_names = ["order-B-#{suffix}", "order-a-#{suffix}"]

    Enum.each(user_names, fn name -> assert {:ok, _user} = IAM.create_user(name: name) end)
    owner = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:maxio, :iam, :group_identity, :lock_wait],
          [:maxio, :iam, :user_identity, :lock_wait],
          [:maxio, :iam, :group_membership, :before_mutation]
        ],
        fn event, _measurements, metadata, test_pid ->
          send(test_pid, {:lock_event, List.last(Enum.drop(event, -2)), event, metadata})
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _result} =
             IAM.update_minio_group_members_strict(
               group_name,
               Enum.reverse(user_names),
               false,
               ""
             )

    events = collect_lock_events([])
    assert Enum.at(events, 0) |> elem(1) == [:maxio, :iam, :group_identity, :lock_wait]

    locked_users =
      for {_kind, [:maxio, :iam, :user_identity, :lock_wait], metadata} <- events,
          do: metadata.case_folded_user_name

    assert locked_users == user_names |> Enum.map(&String.downcase/1) |> Enum.sort()
    assert List.last(events) |> elem(1) == [:maxio, :iam, :group_membership, :before_mutation]
  end

  test "a request snapshot cannot mutate a same-name group replacement" do
    suffix = System.unique_integer([:positive, :monotonic])
    group_name = "generation-group-#{suffix}"
    user_name = "generation-user-#{suffix}"

    {original, user} =
      unboxed(fn ->
        {:ok, user} = IAM.create_user(name: user_name)
        {:ok, original} = IAM.create_group(name: group_name)
        {original, user}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(
          from(m in GroupMembership,
            where: m.group_arn == ^IAM.group_arn(group_name) or m.user_arn == ^user.user_arn
          )
        )

        Repo.delete_all(from(g in Group, where: g.group_name == ^group_name))
        Repo.delete_all(from(u in User, where: u.user_name == ^user_name))
      end)
    end)

    barrier = Maxio.Test.IAMIdentityBarrier.attach(:group, group_name)

    task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          IAM.update_minio_group_members_strict(group_name, [user_name], false, "")
        end)
      end)

    assert_receive {:iam_identity_wait, ^barrier, task_pid}, 5_000
    Maxio.Test.IAMIdentityBarrier.detach(barrier)

    replacement =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        :ok = IAM.delete_group(group_name)
        {:ok, replacement} = IAM.create_group(name: group_name)
        replacement
      end)

    send(task_pid, {:release_iam_identity, barrier})

    assert {:error, :identity_changed} = Task.await(task, 10_000)
    refute original.id == replacement.id
    assert unboxed(fn -> IAM.list_users_in_group(group_name) end) == []
  end

  defp collect_lock_events(events) do
    receive do
      {:lock_event, _kind, _event, _metadata} = event ->
        {_tag, kind, full_event, metadata} = event
        collect_lock_events(events ++ [{kind, full_event, metadata}])
    after
      0 -> events
    end
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
