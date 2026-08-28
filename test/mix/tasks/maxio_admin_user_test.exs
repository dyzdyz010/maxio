defmodule Mix.Tasks.Maxio.Admin.UserTest do
  use Maxio.DataCase, async: false

  alias Maxio.Admin.UserAdapter
  alias Maxio.IAM
  alias Maxio.Policy.Store

  @task "maxio.admin.user.show"

  setup do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Mix.Task.reenable(@task)

    on_exit(fn ->
      Mix.shell(original_shell)
      Mix.Task.reenable(@task)
    end)

    :ok
  end

  test "human and JSON output expose the same safe adapter projection" do
    user_name = unique_access_name("ADMINUSER")
    assert {:ok, user} = IAM.create_user(name: user_name)

    secret = "admin-user-cli-secret-long-enough"

    assert {:ok, _key} =
             IAM.create_access_key(
               access_key_id: user_name,
               secret_key: secret,
               user_name: user_name
             )

    direct_name = unique_name("direct")
    comma_name = unique_name("comma") <> ",hidden"
    inline_name = unique_name("inline")
    group_name = unique_name("group")
    group_inline_name = unique_name("group-inline")
    group_managed_name = unique_name("group-managed")
    role_managed_name = unique_name("role-managed")

    direct_arn = create_managed_policy!(direct_name)
    comma_arn = create_managed_policy!(comma_name)
    group_managed_arn = create_managed_policy!(group_managed_name)
    role_managed_arn = create_managed_policy!(role_managed_name)

    assert :ok = IAM.attach_user_policy(user_name, direct_arn)
    assert :ok = IAM.attach_user_policy(user_name, comma_arn)
    assert :ok = IAM.put_principal_policy(user.user_arn, inline_name, policy_json())
    assert {:ok, _group} = IAM.create_group(name: group_name)
    assert :ok = IAM.add_user_to_group(user_name, group_name)
    assert :ok = IAM.put_group_policy(group_name, group_inline_name, policy_json())
    assert :ok = IAM.attach_group_policy(group_name, group_managed_arn)
    assert {:ok, _role} = create_evidence_role(user.user_arn)
    assert :ok = Store.attach_role_managed_policy(user.user_arn, role_managed_arn)

    assert {:ok, expected} = UserAdapter.info(user_name)

    Mix.Task.run(@task, [user_name])
    human = receive_shell_output()

    for value <- [
          "status=enabled",
          "credential_bearing=true",
          direct_name,
          direct_arn,
          comma_name,
          comma_arn,
          inline_name,
          group_inline_name,
          group_managed_name,
          group_managed_arn,
          role_managed_name,
          role_managed_arn
        ] do
      assert human =~ value
    end

    refute human =~ "s3:GetObject"
    refute human =~ "Statement"
    refute human =~ secret

    Mix.Task.reenable(@task)
    Mix.Task.run(@task, [user_name, "--json"])
    assert_received {:mix_shell, :info, [json]}
    assert Jason.decode!(json) == Jason.decode!(Jason.encode!(expected))
    refute json =~ secret
    refute json =~ "s3:GetObject"
  end

  test "invalid invocation and absent users fail without internal evidence" do
    error = assert_raise Mix.Error, fn -> Mix.Task.run(@task, []) end
    assert error.message == "usage: mix maxio.admin.user.show NAME [--json]"

    Mix.Task.reenable(@task)
    missing = unique_name("missing")
    error = assert_raise Mix.Error, fn -> Mix.Task.run(@task, [missing]) end
    assert error.message == "admin user not found: #{missing}"
    refute error.message =~ "arn:"
  end

  defp receive_shell_output(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> receive_shell_output([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp create_managed_policy!(name) do
    arn = IAM.managed_policy_arn(name, "/")

    assert {:ok, %{policy_arn: ^arn}} =
             IAM.create_managed_policy_strict(
               name: name,
               path: "/",
               document: policy_json()
             )

    arn
  end

  defp create_evidence_role(role_arn) do
    Maxio.Repo.insert(%Maxio.IAM.Role{
      role_name: unique_name("evidence-role"),
      role_arn: role_arn,
      trust_policy: %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Action" => "sts:AssumeRole",
          "Principal" => %{"AWS" => IAM.root_principal_arn()}
        }
      }
    })
  end

  defp policy_json do
    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Action" => "s3:GetObject",
        "Resource" => "arn:aws:s3:::admin-user-cli/*"
      }
    })
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp unique_access_name(prefix) do
    suffix = System.unique_integer([:positive, :monotonic])
    String.pad_trailing("AKIA#{prefix}#{suffix}", 20, "X")
  end
end
