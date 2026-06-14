defmodule Mix.Tasks.Maxio.Iam.RolePolicyTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Maxio.Iam.{AttachRolePolicy, DetachRolePolicy, ListAttachedRolePolicies}

  @tasks [
    "maxio.iam.attach_role_policy",
    "maxio.iam.list_attached_role_policies",
    "maxio.iam.detach_role_policy"
  ]

  setup do
    Enum.each(@tasks, &Mix.Task.reenable/1)

    on_exit(fn ->
      Enum.each(@tasks, &Mix.Task.reenable/1)
    end)
  end

  test "attach, list, and detach role managed policies" do
    role_arn = create_role!("cli-role")
    policy_name = unique_name("cli-attached")
    policy_arn = create_managed_policy!(policy_name, "/cli/")

    attach_output =
      capture_io(fn ->
        AttachRolePolicy.run(["--role-arn", role_arn, "--policy-arn", policy_arn, "--json"])
      end)

    assert %{"status" => "attached", "role_arn" => ^role_arn, "policy_arn" => ^policy_arn} =
             Jason.decode!(attach_output)

    list_output =
      capture_io(fn ->
        ListAttachedRolePolicies.run([
          "--role-arn",
          role_arn,
          "--path-prefix",
          "/cli/",
          "--json"
        ])
      end)

    assert %{
             "status" => "ok",
             "role_arn" => ^role_arn,
             "policies" => [
               %{
                 "policy_arn" => ^policy_arn,
                 "policy_name" => ^policy_name,
                 "path" => "/cli/"
               }
             ]
           } = Jason.decode!(list_output)

    detach_output =
      capture_io(fn ->
        DetachRolePolicy.run(["--role-arn", role_arn, "--policy-arn", policy_arn])
      end)

    assert detach_output =~ "[maxio iam.detach_role_policy] status=detached"

    empty_output =
      capture_io(fn ->
        ListAttachedRolePolicies.run(["--role-arn", role_arn, "--json"])
      end)

    assert %{"policies" => []} = Jason.decode!(empty_output)
  end

  test "attach validates role and policy" do
    policy_arn = create_managed_policy!(unique_name("missing-role"), "/")

    assert_raise Mix.Error, ~r/attach_role_policy failed: :not_found/, fn ->
      AttachRolePolicy.run([
        "--role-arn",
        "arn:aws:iam:::role/missing",
        "--policy-arn",
        policy_arn
      ])
    end

    role_arn = create_role!("missing-policy")

    assert_raise Mix.Error, ~r/attach_role_policy failed: :not_found/, fn ->
      AttachRolePolicy.run([
        "--role-arn",
        role_arn,
        "--policy-arn",
        Maxio.IAM.managed_policy_arn(unique_name("missing-policy"))
      ])
    end
  end

  defp create_role!(name_prefix) do
    role_name = unique_name(name_prefix)

    trust_policy = %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Principal" => %{"AWS" => Maxio.IAM.root_principal_arn()},
        "Action" => "sts:AssumeRole"
      }
    }

    assert {:ok, role} = Maxio.IAM.create_role(role_name: role_name, trust_policy: trust_policy)
    role.role_arn
  end

  defp create_managed_policy!(policy_name, path) do
    policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Action" => "s3:GetObject",
          "Resource" => "arn:aws:s3:::bucket/*"
        }
      })

    assert {:ok, managed_policy} =
             Maxio.IAM.create_managed_policy(name: policy_name, path: path, policy: policy)

    managed_policy.policy_arn
  end

  defp unique_name(name), do: "#{name}-#{System.unique_integer([:positive])}"
end
