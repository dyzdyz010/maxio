defmodule Mix.Tasks.Maxio.IamUserGroupTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Auth.CredentialStore.EctoStore
  alias Mix.Tasks.Maxio.Iam

  @tasks [
    "maxio.iam.create_user",
    "maxio.iam.list_users",
    "maxio.iam.delete_user",
    "maxio.iam.create_group",
    "maxio.iam.list_groups",
    "maxio.iam.delete_group",
    "maxio.iam.add_user_to_group",
    "maxio.iam.remove_user_from_group",
    "maxio.iam.list_group_users",
    "maxio.iam.list_user_groups",
    "maxio.iam.put_group_policy",
    "maxio.iam.list_policies",
    "maxio.iam.create_key",
    "maxio.iam.attach_user_policy",
    "maxio.iam.list_attached_user_policies",
    "maxio.iam.detach_user_policy",
    "maxio.iam.attach_group_policy",
    "maxio.iam.list_attached_group_policies",
    "maxio.iam.detach_group_policy"
  ]

  setup do
    Enum.each(@tasks, &Mix.Task.reenable/1)

    on_exit(fn ->
      Enum.each(@tasks, &Mix.Task.reenable/1)
    end)
  end

  test "CLI manages users, groups, membership, group policy and user-bound access keys" do
    user_name = unique_name("cli-user")
    group_name = unique_name("cli-group")
    access_key = "AKIACLIUSERGROUP#{System.unique_integer([:positive])}"
    secret = "cli-user-group-secret"
    policy = policy_doc("s3:GetObject")

    create_user_output =
      capture_io(fn ->
        Iam.CreateUser.run(["--name", user_name])
      end)

    assert create_user_output =~ "[maxio iam.create_user] status=created"
    assert create_user_output =~ Maxio.IAM.user_arn(user_name)

    create_group_output =
      capture_io(fn ->
        Iam.CreateGroup.run(["--name", group_name])
      end)

    assert create_group_output =~ "[maxio iam.create_group] status=created"
    assert create_group_output =~ Maxio.IAM.group_arn(group_name)

    add_output =
      capture_io(fn ->
        Iam.AddUserToGroup.run(["--user", user_name, "--group", group_name])
      end)

    assert add_output =~ "status=attached"

    list_group_users_output =
      capture_io(fn ->
        Iam.ListGroupUsers.run(["--group", group_name])
      end)

    assert list_group_users_output =~ "count=1"
    assert list_group_users_output =~ user_name

    list_user_groups_output =
      capture_io(fn ->
        Iam.ListUserGroups.run(["--user", user_name])
      end)

    assert list_user_groups_output =~ "count=1"
    assert list_user_groups_output =~ group_name

    put_policy_output =
      capture_io(fn ->
        Iam.PutGroupPolicy.run(["--group", group_name, "--name", "read", "--policy", policy])
      end)

    assert put_policy_output =~ "[maxio iam.put_group_policy] status=stored"

    list_policy_output =
      capture_io(fn ->
        Iam.ListPolicies.run(["--principal", Maxio.IAM.group_arn(group_name)])
      end)

    assert list_policy_output =~ "[maxio iam.list_policies] status=ok"
    assert list_policy_output =~ "read"

    user_policy_arn = create_managed_policy!(unique_name("cli-user-managed"), "/cli/user/")
    group_policy_arn = create_managed_policy!(unique_name("cli-group-managed"), "/cli/group/")

    attach_user_policy_output =
      capture_io(fn ->
        Iam.AttachUserPolicy.run([
          "--user",
          user_name,
          "--policy-arn",
          user_policy_arn,
          "--json"
        ])
      end)

    assert %{
             "status" => "attached",
             "user" => ^user_name,
             "policy_arn" => ^user_policy_arn
           } = Jason.decode!(attach_user_policy_output)

    list_user_policy_output =
      capture_io(fn ->
        Iam.ListAttachedUserPolicies.run([
          "--user",
          user_name,
          "--path-prefix",
          "/cli/user/",
          "--json"
        ])
      end)

    assert %{
             "status" => "ok",
             "policies" => [%{"policy_arn" => ^user_policy_arn, "path" => "/cli/user/"}]
           } = Jason.decode!(list_user_policy_output)

    attach_group_policy_output =
      capture_io(fn ->
        Iam.AttachGroupPolicy.run([
          "--group",
          group_name,
          "--policy-arn",
          group_policy_arn,
          "--json"
        ])
      end)

    assert %{
             "status" => "attached",
             "group" => ^group_name,
             "policy_arn" => ^group_policy_arn
           } = Jason.decode!(attach_group_policy_output)

    list_group_policy_output =
      capture_io(fn ->
        Iam.ListAttachedGroupPolicies.run([
          "--group",
          group_name,
          "--path-prefix",
          "/cli/group/",
          "--json"
        ])
      end)

    assert %{
             "status" => "ok",
             "policies" => [%{"policy_arn" => ^group_policy_arn, "path" => "/cli/group/"}]
           } = Jason.decode!(list_group_policy_output)

    detach_user_policy_output =
      capture_io(fn ->
        Iam.DetachUserPolicy.run(["--user", user_name, "--policy-arn", user_policy_arn])
      end)

    assert detach_user_policy_output =~ "status=detached"
    assert [] = Maxio.IAM.list_attached_user_policies(user_name)

    detach_group_policy_output =
      capture_io(fn ->
        Iam.DetachGroupPolicy.run(["--group", group_name, "--policy-arn", group_policy_arn])
      end)

    assert detach_group_policy_output =~ "status=detached"
    assert [] = Maxio.IAM.list_attached_group_policies(group_name)

    create_key_output =
      capture_io(fn ->
        Iam.CreateKey.run([
          "--access-key",
          access_key,
          "--secret",
          secret,
          "--user",
          user_name
        ])
      end)

    assert create_key_output =~ "PrincipalArn: #{Maxio.IAM.user_arn(user_name)}"
    assert {:ok, %{principal: %{arn: user_arn}}} = EctoStore.get_secret(access_key)
    assert user_arn == Maxio.IAM.user_arn(user_name)

    remove_output =
      capture_io(fn ->
        Iam.RemoveUserFromGroup.run(["--user", user_name, "--group", group_name])
      end)

    assert remove_output =~ "status=detached"

    list_after_remove =
      capture_io(fn ->
        Iam.ListGroupUsers.run(["--group", group_name])
      end)

    assert list_after_remove =~ "count=0"

    delete_user_output =
      capture_io(fn ->
        Iam.DeleteUser.run(["--name", user_name])
      end)

    assert delete_user_output =~ "status=deleted"
    assert :error = EctoStore.get_secret(access_key)

    delete_group_output =
      capture_io(fn ->
        Iam.DeleteGroup.run(["--name", group_name])
      end)

    assert delete_group_output =~ "status=deleted"
  end

  test "CLI rejects unknown switches instead of silently using defaults" do
    user_name = unique_name("bad-switch-user")
    access_key = "AKIABADSWITCH#{System.unique_integer([:positive])}"

    assert_raise Mix.Error, ~r/usage: mix maxio\.iam\.create_user/, fn ->
      Iam.CreateUser.run(["--name", user_name, "--stauts", "inactive"])
    end

    assert :error = Maxio.IAM.get_user(user_name)

    assert_raise Mix.Error, ~r/usage: mix maxio\.iam\.create_key/, fn ->
      Iam.CreateKey.run(["--access-key", access_key, "--secret", "secret", "--usre", user_name])
    end

    assert :error = EctoStore.get_secret(access_key)

    assert_raise Mix.Error, ~r/--user and --principal-arn are mutually exclusive/, fn ->
      Iam.CreateKey.run([
        "--access-key",
        access_key,
        "--secret",
        "secret",
        "--user",
        user_name,
        "--principal-arn",
        Maxio.IAM.user_arn("#{user_name}-other")
      ])
    end

    assert :error = EctoStore.get_secret(access_key)

    group_name = unique_name("bad-policy-input")
    capture_io(fn -> Iam.CreateGroup.run(["--name", group_name]) end)

    assert_raise Mix.Error, ~r/--policy and --file are mutually exclusive/, fn ->
      Iam.PutGroupPolicy.run([
        "--group",
        group_name,
        "--name",
        "read",
        "--policy",
        policy_doc("s3:GetObject"),
        "--file",
        "unused.json"
      ])
    end

    policy_arn = create_managed_policy!(unique_name("bad-switch-policy"), "/")

    assert_raise Mix.Error, ~r/usage: mix maxio\.iam\.attach_user_policy/, fn ->
      Iam.AttachUserPolicy.run([
        "--user",
        user_name,
        "--policy-arn",
        policy_arn,
        "--polciy-arn",
        policy_arn
      ])
    end
  end

  defp policy_doc(action) do
    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Action" => action,
        "Resource" => "arn:aws:s3:::bucket/*"
      }
    })
  end

  defp create_managed_policy!(policy_name, path) do
    assert {:ok, policy} =
             Maxio.IAM.create_managed_policy(
               name: policy_name,
               path: path,
               policy: policy_doc("s3:GetObject")
             )

    policy.policy_arn
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
