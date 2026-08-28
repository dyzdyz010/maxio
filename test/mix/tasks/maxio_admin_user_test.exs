defmodule Mix.Tasks.Maxio.Admin.UserTest do
  use Maxio.DataCase, async: false

  alias Maxio.Admin.UserAdapter
  alias Maxio.IAM
  alias Maxio.Policy.Store

  @show_task "maxio.admin.user.show"
  @list_task "maxio.admin.user.list"
  @add_task "maxio.admin.user.add"
  @tasks [@show_task, @list_task, @add_task]

  setup do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Enum.each(@tasks, &Mix.Task.reenable/1)

    on_exit(fn ->
      Mix.shell(original_shell)
      Enum.each(@tasks, &Mix.Task.reenable/1)
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

    Mix.Task.run(@show_task, [user_name])
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

    Mix.Task.reenable(@show_task)
    Mix.Task.run(@show_task, [user_name, "--json"])
    assert_received {:mix_shell, :info, [json]}
    assert Jason.decode!(json) == Jason.decode!(Jason.encode!(expected))
    refute json =~ secret
    refute json =~ "s3:GetObject"
  end

  test "invalid invocation and absent users fail without internal evidence" do
    error = assert_raise Mix.Error, fn -> Mix.Task.run(@show_task, []) end
    assert error.message == "usage: mix maxio.admin.user.show NAME [--json]"

    Mix.Task.reenable(@show_task)
    missing = unique_name("missing")
    error = assert_raise Mix.Error, fn -> Mix.Task.run(@show_task, [missing]) end
    assert error.message == "admin user not found: #{missing}"
    refute error.message =~ "arn:"
  end

  test "list human and JSON modes use the exact safe adapter projection" do
    enabled = unique_access_name("LISTCLI")
    disabled = unique_access_name("LISTOFF")
    secret = "list-cli-secret-do-not-print"

    assert {:ok, _enabled} =
             UserAdapter.add(enabled, %{secret_key: secret, policy: "", status: "enabled"})

    assert {:ok, _disabled} = IAM.create_user(name: disabled, status: "inactive")
    policy_name = unique_name("list-direct")
    policy_arn = create_managed_policy!(policy_name)
    assert :ok = IAM.attach_user_policy(enabled, policy_arn)
    assert {:ok, expected} = UserAdapter.list()

    Mix.Task.run(@list_task, [])
    human = receive_shell_output()

    for value <- [
          "admin_action=admin_user_list",
          "required_action=admin:ListUsers",
          "user_count=2",
          "enabled_count=1",
          "disabled_count=1",
          "name=#{enabled}",
          "status=enabled",
          "policy_name=#{policy_name}",
          "name=#{disabled}",
          "status=disabled",
          "minio_view_partial=false"
        ] do
      assert human =~ value
    end

    refute human =~ secret
    refute human =~ "secretKey"
    refute human =~ "access_key_id"

    Mix.Task.reenable(@list_task)
    Mix.Task.run(@list_task, ["--json"])
    assert_received {:mix_shell, :info, [json]}
    assert Jason.decode!(json) == Jason.decode!(Jason.encode!(expected))
    refute json =~ secret
    refute json =~ "secretKey"
  end

  test "add reads only a named environment variable and rejects literal secret argv" do
    name = unique_access_name("ADDCLI")
    env_name = "MAXIO_TEST_ADMIN_SECRET_#{System.unique_integer([:positive, :monotonic])}"
    secret = "cli-add-secret-sentinel"
    restore_env(env_name)
    System.put_env(env_name, secret)

    Mix.Task.run(@add_task, [name, "--secret-env", env_name])
    output = receive_shell_output()

    assert output =~ "admin_action=admin_user_add"
    assert output =~ "required_action=admin:CreateUser"
    assert output =~ "target_user=#{name}"
    refute output =~ secret
    assert {:ok, %{user_name: ^name}} = IAM.get_user(name)

    Mix.Task.reenable(@add_task)

    literal_error =
      assert_raise Mix.Error, fn ->
        Mix.Task.run(@add_task, [unique_access_name("LITERAL"), secret])
      end

    assert literal_error.message ==
             "usage: mix maxio.admin.user.add NAME --secret-env ENV_NAME"

    refute literal_error.message =~ secret

    Mix.Task.reenable(@add_task)
    missing_env = env_name <> "_MISSING"
    restore_env(missing_env)

    missing_error =
      assert_raise Mix.Error, fn ->
        Mix.Task.run(@add_task, [unique_access_name("NOENV"), "--secret-env", missing_env])
      end

    assert missing_error.message == "admin user secret environment variable is not set"
    refute missing_error.message =~ env_name
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

  defp restore_env(name) do
    original = System.get_env(name)

    on_exit(fn ->
      case original do
        nil -> System.delete_env(name)
        value -> System.put_env(name, value)
      end
    end)
  end
end
