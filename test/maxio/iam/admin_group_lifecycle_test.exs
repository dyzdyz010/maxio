defmodule Maxio.IAM.AdminGroupLifecycleTest do
  use Maxio.DataCase, async: false

  import Ecto.Query

  alias Maxio.IAM
  alias Maxio.IAM.{AccessKey, Group, GroupManagedPolicyAttachment, GroupMembership}
  alias Maxio.Policy.{ManagedPolicy, PrincipalPolicy}

  @document %{
    "Version" => "2012-10-17",
    "Statement" => [
      %{"Effect" => "Allow", "Action" => "s3:ListAllMyBuckets", "Resource" => "*"}
    ]
  }

  test "create-or-add validates request order then persists Maxio sorted-unique membership" do
    alice = create_user!("Alice")
    bob = create_user!("bob")

    assert {:ok, result} =
             IAM.update_minio_group_members_strict(
               "devs",
               ["BOB", "alice", "bob"],
               false,
               "ignored-by-membership"
             )

    assert result.operation == :create_or_add
    assert result.group.status == "active"
    assert result.group_status_ignored?
    assert result.changed_member_arns == Enum.sort([alice.user_arn, bob.user_arn])
    assert member_names("devs") == ["Alice", "bob"]
    assert Repo.aggregate(GroupMembership, :count) == 2

    assert %Group{status: "active", updated_at: updated_at} = group!("devs")
    assert result.updated_at == updated_at
  end

  test "existing disabled group remains disabled across add and duplicate add refreshes timestamp" do
    user = create_user!("alice")
    assert {:ok, _group} = IAM.create_group(name: "devs", status: "inactive")

    assert {:ok, first} =
             IAM.update_minio_group_members_strict("DEVS", ["ALICE"], false, "enabled")

    assert first.group.status == "inactive"

    old = DateTime.add(first.updated_at, -60, :second)
    Repo.update_all(from(g in Group, where: g.group_name == "devs"), set: [updated_at: old])

    assert {:ok, duplicate} =
             IAM.update_minio_group_members_strict("devs", ["alice", "alice"], false, "")

    assert duplicate.changed_member_arns == []
    assert duplicate.affected_member_arns == [user.user_arn]
    assert DateTime.compare(duplicate.updated_at, old) == :gt
    assert group!("devs").updated_at == duplicate.updated_at
    assert member_names("devs") == ["alice"]
  end

  test "remove subset and already-absent remove persist a fresh timestamp" do
    alice = create_user!("alice")
    bob = create_user!("bob")

    assert {:ok, _result} =
             IAM.update_minio_group_members_strict("devs", ["alice", "bob"], false, "")

    assert {:ok, removed} =
             IAM.update_minio_group_members_strict("devs", ["alice"], true, "ignored")

    assert removed.operation == :remove_members
    assert removed.changed_member_arns == [alice.user_arn]
    assert removed.affected_member_arns == [alice.user_arn]
    assert member_names("devs") == ["bob"]

    old = DateTime.add(removed.updated_at, -60, :second)
    Repo.update_all(from(g in Group, where: g.group_name == "devs"), set: [updated_at: old])

    assert {:ok, absent} =
             IAM.update_minio_group_members_strict("devs", ["alice"], true, "")

    assert absent.changed_member_arns == []
    assert absent.affected_member_arns == [alice.user_arn]
    assert DateTime.compare(absent.updated_at, old) == :gt
    assert group!("devs").updated_at == absent.updated_at
    assert member_names("devs") == [bob.user_name]
  end

  test "delete-empty rejects membership then atomically removes group mappings but keeps policies" do
    create_user!("alice")
    assert {:ok, _result} = IAM.update_minio_group_members_strict("devs", ["alice"], false, "")
    group = group!("devs")

    assert :ok = IAM.put_group_policy("devs", "inline", Jason.encode!(@document))
    root = create_policy!("root-policy", "/")
    nested = create_policy!("nested-policy", "/team/")
    assert :ok = IAM.attach_group_policy("devs", root.policy_arn)
    assert :ok = IAM.attach_group_policy("devs", nested.policy_arn)

    assert {:error, :group_not_empty} =
             IAM.update_minio_group_members_strict("devs", [], true, "")

    assert {:ok, _removed} =
             IAM.update_minio_group_members_strict("devs", ["alice"], true, "")

    assert {:ok, deleted} = IAM.update_minio_group_members_strict("devs", [], true, "")
    assert deleted.operation == :delete_empty
    assert deleted.group == nil
    refute Repo.get_by(Group, id: group.id)
    refute Repo.get_by(PrincipalPolicy, principal_arn: group.group_arn)
    refute Repo.get_by(GroupManagedPolicyAttachment, group_arn: group.group_arn)
    assert Repo.get_by(ManagedPolicy, policy_arn: root.policy_arn)
    assert Repo.get_by(ManagedPolicy, policy_arn: nested.policy_arn)

    assert {:error, :group_not_found} =
             IAM.update_minio_group_members_strict("devs", [], true, "")
  end

  test "failure precedence and batches are atomic" do
    root = Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)
    create_user!("alice")

    assert {:error, :minio_action_not_allowed} =
             IAM.update_minio_group_members_strict("", [root], true, "")

    assert {:error, :invalid_argument} =
             IAM.update_minio_group_members_strict("", ["missing"], true, "")

    assert {:error, :user_not_found} =
             IAM.update_minio_group_members_strict("missing-group", ["missing"], true, "")

    assert {:error, :user_not_found} =
             IAM.update_minio_group_members_strict(
               "new-group",
               ["alice", "missing"],
               false,
               ""
             )

    refute Repo.get_by(Group, group_name: "new-group")
    assert Repo.aggregate(GroupMembership, :count) == 0
  end

  test "service-account and temporary credential ids cannot be group members" do
    parent = create_user!("parent")
    service_id = unique_name("service")

    assert {:ok, _access_key} =
             IAM.create_access_key(
               access_key_id: service_id,
               secret_key: "service-secret",
               user_name: parent.user_name
             )

    assert %AccessKey{principal_arn: principal_arn} =
             Repo.get_by!(AccessKey, access_key_id: service_id)

    assert principal_arn == parent.user_arn

    assert {:error, :minio_action_not_allowed} =
             IAM.update_minio_group_members_strict("devs", [service_id], false, "")

    refute Repo.get_by(Group, group_name: "devs")
  end

  test "status mutation is generation-locked, refreshes no-op timestamp and exposes members" do
    user = create_user!("alice")
    assert {:ok, created} = IAM.update_minio_group_members_strict("devs", ["alice"], false, "")

    old = DateTime.add(created.updated_at, -60, :second)
    Repo.update_all(from(g in Group, where: g.group_name == "devs"), set: [updated_at: old])

    assert {:ok, disabled} = IAM.update_minio_group_status_strict("DEVS", "inactive")
    assert disabled.group.status == "inactive"
    assert disabled.affected_member_arns == [user.user_arn]
    assert disabled.updated_at == group!("devs").updated_at
    assert DateTime.compare(disabled.updated_at, old) == :gt

    old = DateTime.add(disabled.updated_at, -60, :second)
    Repo.update_all(from(g in Group, where: g.group_name == "devs"), set: [updated_at: old])

    assert {:ok, no_op} = IAM.update_minio_group_status_strict("devs", "inactive")
    assert DateTime.compare(no_op.updated_at, old) == :gt

    assert {:error, :group_not_found} =
             IAM.update_minio_group_status_strict("missing", "active")

    assert {:error, :invalid_argument} =
             IAM.update_minio_group_status_strict("missing", "enabled")
  end

  defp create_user!(name) do
    assert {:ok, user} = IAM.create_user(name: name)
    user
  end

  defp create_policy!(name, path) do
    assert {:ok, policy} = IAM.create_managed_policy(name: name, path: path, document: @document)
    policy
  end

  defp group!(name), do: Repo.get_by!(Group, group_name: name)

  defp member_names(group_name) do
    IAM.list_users_in_group(group_name) |> Enum.map(& &1.user_name)
  end

  defp unique_name(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
