defmodule Mix.Tasks.Maxio.Admin.PolicyAssociationTest do
  use Maxio.DataCase, async: false

  alias Maxio.IAM

  @tasks [
    "maxio.admin.policy.attach",
    "maxio.admin.policy.detach",
    "maxio.admin.policy.entities"
  ]

  @document ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:ListAllMyBuckets","Resource":"*"}]})

  setup do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Enum.each(@tasks, &Mix.Task.reenable/1)

    on_exit(fn ->
      Mix.shell(original_shell)
      Enum.each(@tasks, &Mix.Task.reenable/1)
    end)

    user_name = unique_name("cli-user")
    policy_name = unique_name("cli-policy")
    assert {:ok, _} = IAM.create_user(name: user_name)
    assert {:ok, _} = IAM.create_managed_policy_strict(name: policy_name, document: @document)
    {:ok, user_name: user_name, policy_name: policy_name}
  end

  test "attach and detach expose stable JSON through public IAM", %{
    user_name: user_name,
    policy_name: policy_name
  } do
    Mix.Task.run("maxio.admin.policy.attach", [policy_name, "--user", user_name, "--json"])
    assert_received {:mix_shell, :info, [attach_json]}
    attach = Jason.decode!(attach_json)
    assert attach["operation"] == "attach"
    assert attach["principalKind"] == "user"
    assert attach["principalName"] == user_name
    assert attach["changedPolicies"] == [policy_name]
    assert {:ok, _, 0} = DateTime.from_iso8601(attach["updatedAt"])

    Mix.Task.reenable("maxio.admin.policy.detach")
    Mix.Task.run("maxio.admin.policy.detach", [policy_name, "--user", user_name, "--json"])
    assert_received {:mix_shell, :info, [detach_json]}
    assert Jason.decode!(detach_json)["changedPolicies"] == [policy_name]
  end

  test "human output is stable and no-effect is a nonzero Mix error", %{
    user_name: user_name,
    policy_name: policy_name
  } do
    Mix.Task.run("maxio.admin.policy.attach", [policy_name, "--user", user_name])
    assert_received {:mix_shell, :info, [line]}
    assert line =~ "[maxio admin.policy.attach]"
    assert line =~ "principal=user:#{user_name}"
    assert line =~ "changed=#{policy_name}"
    refute line =~ @document

    Mix.Task.reenable("maxio.admin.policy.attach")

    error =
      assert_raise Mix.Error, fn ->
        Mix.Task.run("maxio.admin.policy.attach", [policy_name, "--user", user_name])
      end

    assert error.message == "policy association change is already applied"
  end

  test "association requires exactly one principal and one or more policies" do
    for {task, argv} <- [
          {"maxio.admin.policy.attach", []},
          {"maxio.admin.policy.attach", ["readwrite"]},
          {"maxio.admin.policy.detach", ["readwrite", "--user", "alice", "--group", "ops"]}
        ] do
      Mix.Task.reenable(task)
      assert_raise Mix.Error, ~r/usage:/, fn -> Mix.Task.run(task, argv) end
    end
  end

  test "entities accepts independently repeated filters and stable JSON", %{
    user_name: user_name,
    policy_name: policy_name
  } do
    assert {:ok, _} =
             IAM.update_managed_policy_associations_strict(
               :attach,
               {:user, user_name},
               [policy_name]
             )

    Mix.Task.run("maxio.admin.policy.entities", [
      "--user",
      "missing",
      "--user",
      user_name,
      "--policy",
      policy_name,
      "--json"
    ])

    assert_received {:mix_shell, :info, [json]}
    output = Jason.decode!(json)

    assert output["requested"] == %{
             "groups" => [],
             "policies" => [policy_name],
             "users" => Enum.sort(["missing", user_name])
           }

    assert [%{"user" => ^user_name}] = output["result"]["userMappings"]
    assert [%{"policy" => ^policy_name}] = output["result"]["policyMappings"]
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
