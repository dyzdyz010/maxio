defmodule Maxio.IAM.MinioAdminPolicyTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.Notify
  alias Maxio.IAM
  alias Maxio.IAM.Group
  alias Maxio.Policy.Store

  @document ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:ListAllMyBuckets","Resource":"*"}]})

  setup do
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())
    user_name = "admin-policy-user-#{System.unique_integer([:positive, :monotonic])}"
    group_name = "admin-policy-group-#{System.unique_integer([:positive, :monotonic])}"
    assert {:ok, user} = IAM.create_user(name: user_name)
    assert {:ok, group} = IAM.create_group(name: group_name)

    policies =
      for suffix <- ["a", "b", "c"] do
        name = "admin-policy-#{suffix}-#{System.unique_integer([:positive, :monotonic])}"
        assert {:ok, policy} = IAM.create_managed_policy_strict(name: name, document: @document)
        {name, policy.policy_arn}
      end

    drain_policy_notifications()

    {:ok, user: user, group: group, policies: policies}
  end

  test "multi-policy attach is atomic, sorted and reports only actual changes", %{
    user: user,
    policies: [{name_a, arn_a}, {name_b, arn_b}, {name_c, arn_c}]
  } do
    assert {:ok, %{changed_policy_arns: [^arn_a, ^arn_b], updated_at: %DateTime{}}} =
             IAM.update_managed_policy_associations_strict(
               :attach,
               {:user, user.user_name},
               [name_b, name_a, name_b]
             )

    assert_receive {:principal_policy_changed, user_arn}
    assert user_arn == user.user_arn
    refute_receive {:principal_policy_changed, _}

    assert {:ok, %{changed_policy_arns: [^arn_c]}} =
             IAM.update_managed_policy_associations_strict(
               :attach,
               {:user, user.user_name},
               [name_a, name_c]
             )

    assert Enum.map(Store.list_attached_user_managed_policies(user.user_arn), & &1.policy_arn) ==
             [arn_a, arn_b, arn_c]
  end

  test "attach missing policy rolls back the complete batch and no-effect does not notify", %{
    user: user,
    policies: [{name_a, arn_a}, {name_b, _arn_b}, {_name_c, _arn_c}]
  } do
    assert {:error, :policy_not_found} =
             IAM.update_managed_policy_associations_strict(
               :attach,
               {:user, user.user_name},
               [name_a, "missing-admin-policy"]
             )

    assert [] = Store.list_attached_user_managed_policies(user.user_arn)
    refute_receive {:principal_policy_changed, _}

    assert {:ok, %{changed_policy_arns: [^arn_a]}} =
             IAM.update_managed_policy_associations_strict(
               :attach,
               {:user, user.user_name},
               [name_a]
             )

    assert_receive {:principal_policy_changed, _}

    assert {:error, :policy_change_already_applied} =
             IAM.update_managed_policy_associations_strict(
               :attach,
               {:user, user.user_name},
               [name_a]
             )

    refute_receive {:principal_policy_changed, _}

    assert [^arn_a] =
             Enum.map(Store.list_attached_user_managed_policies(user.user_arn), & &1.policy_arn)

    assert {:error, :policy_not_found} =
             IAM.update_managed_policy_associations_strict(
               :attach,
               {:user, user.user_name},
               [name_b, "missing-again"]
             )
  end

  test "detach ignores undefined items when an attached intersection exists", %{
    user: user,
    policies: [{name_a, arn_a}, {_name_b, _arn_b}, {_name_c, _arn_c}]
  } do
    assert {:ok, _} =
             IAM.update_managed_policy_associations_strict(:attach, {:user, user.user_name}, [
               name_a
             ])

    assert_receive {:principal_policy_changed, _}

    assert {:ok, %{changed_policy_arns: [^arn_a]}} =
             IAM.update_managed_policy_associations_strict(
               :detach,
               {:user, user.user_name},
               ["undefined-policy", name_a]
             )

    assert [] = Store.list_attached_user_managed_policies(user.user_arn)

    assert {:error, :policy_change_already_applied} =
             IAM.update_managed_policy_associations_strict(
               :detach,
               {:user, user.user_name},
               ["undefined-policy"]
             )
  end

  test "target validation precedes policy validation and disabled groups are rejected", %{
    group: group,
    policies: [{name_a, _arn_a}, {_name_b, _arn_b}, {_name_c, _arn_c}]
  } do
    assert {:error, :user_not_found} =
             IAM.update_managed_policy_associations_strict(
               :attach,
               {:user, "missing-user"},
               ["missing-policy"]
             )

    assert {:error, :group_not_found} =
             IAM.update_managed_policy_associations_strict(
               :attach,
               {:group, "missing-group"},
               ["missing-policy"]
             )

    group_row = Repo.get_by!(Group, group_arn: group.group_arn)
    assert {:ok, _} = group_row |> Group.changeset(%{status: "inactive"}) |> Repo.update()

    assert {:error, :group_disabled} =
             IAM.update_managed_policy_associations_strict(
               :attach,
               {:group, group.group_name},
               [name_a]
             )
  end

  test "policy entities projects direct, membership, group and reverse mappings in one snapshot",
       %{
         user: user,
         group: group,
         policies: [{name_a, arn_a}, {name_b, arn_b}, {_name_c, _arn_c}]
       } do
    assert {:ok, _} =
             IAM.update_managed_policy_associations_strict(:attach, {:user, user.user_name}, [
               name_b
             ])

    assert {:ok, _} =
             IAM.update_managed_policy_associations_strict(
               :attach,
               {:group, group.group_name},
               [name_a]
             )

    assert :ok = IAM.add_user_to_group(user.user_name, group.group_name)

    assert {:ok,
            %{
              timestamp: %DateTime{},
              user_mappings: [
                %{
                  user: user_name,
                  policy_arns: [^arn_b],
                  member_of_mappings: [%{group: group_name, policy_arns: [^arn_a]}]
                }
              ],
              group_mappings: [%{group: group_name, policy_arns: [^arn_a]}],
              policy_mappings: [
                %{policy_arn: ^arn_a, users: [], groups: [group_name]},
                %{policy_arn: ^arn_b, users: [user_name], groups: []}
              ]
            }} =
             IAM.query_builtin_policy_entities(%{
               users: [user.user_name, "missing"],
               groups: [group.group_name, "missing"],
               policy_arns: [arn_b, arn_a, "arn:aws:iam:::policy/missing"],
               requested: MapSet.new([:user, :group, :policy])
             })

    assert user_name == user.user_name
    assert group_name == group.group_name
  end

  test "empty query activates all root policy mappings and empty or unknown mappings are omitted",
       %{
         user: user,
         policies: [{name_a, arn_a}, {_name_b, _arn_b}, {_name_c, _arn_c}]
       } do
    assert {:ok, %{timestamp: %DateTime{}} = empty} =
             IAM.query_builtin_policy_entities(%{
               users: [],
               groups: [],
               policy_arns: [],
               requested: MapSet.new()
             })

    assert empty.user_mappings == []
    assert empty.group_mappings == []
    assert empty.policy_mappings == []

    assert {:ok, _} =
             IAM.update_managed_policy_associations_strict(:attach, {:user, user.user_name}, [
               name_a
             ])

    assert {:ok, %{policy_mappings: [%{policy_arn: ^arn_a}]}} =
             IAM.query_builtin_policy_entities(%{
               users: [],
               groups: [],
               policy_arns: [],
               requested: MapSet.new()
             })

    assert {:ok, %{user_mappings: [], group_mappings: [], policy_mappings: []}} =
             IAM.query_builtin_policy_entities(%{
               users: ["missing"],
               groups: ["missing"],
               policy_arns: ["arn:aws:iam:::policy/missing"],
               requested: MapSet.new([:user, :group, :policy])
             })
  end

  defp drain_policy_notifications do
    receive do
      {:principal_policy_changed, _principal_arn} -> drain_policy_notifications()
      {:managed_session_policy_changed, _policy_arn} -> drain_policy_notifications()
      {:iam_changed, _principal_arn} -> drain_policy_notifications()
    after
      0 -> :ok
    end
  end
end
