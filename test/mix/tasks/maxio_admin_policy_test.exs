defmodule Mix.Tasks.Maxio.Admin.PolicyTest do
  use Maxio.DataCase, async: false

  alias Maxio.IAM

  @tasks ["maxio.admin.policy.list", "maxio.admin.policy.show"]

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

  test "list reports both visible and omitted non-root policies" do
    root_name = unique_name("root-visible")
    hidden_name = unique_name("team-hidden")

    assert {:ok, _} =
             IAM.create_managed_policy_strict(
               name: root_name,
               path: "/",
               document: policy_json()
             )

    assert {:ok, _} =
             IAM.create_managed_policy_strict(
               name: hidden_name,
               path: "/team/",
               document: policy_json()
             )

    Mix.Task.run("maxio.admin.policy.list", ["--json"])
    assert_received {:mix_shell, :info, [json]}

    output = Jason.decode!(json)
    assert is_map(output["policies"][root_name])

    assert [
             %{
               "policy_name" => ^hidden_name,
               "path" => "/team/",
               "reason" => "non_root_path"
             }
           ] = output["omitted"]
  end

  test "show emits the same four PolicyInfo keys as madmin v2" do
    name = unique_name("show")

    assert {:ok, _} =
             IAM.create_managed_policy_strict(
               name: name,
               path: "/",
               document: policy_json()
             )

    Mix.Task.run("maxio.admin.policy.show", [name, "--json"])
    assert_received {:mix_shell, :info, [json]}

    output = Jason.decode!(json)

    assert Map.keys(output) |> Enum.sort() ==
             ["CreateDate", "Policy", "PolicyName", "UpdateDate"]

    assert output["PolicyName"] == name
  end

  test "human list output is stable and does not print policy documents" do
    visible = unique_name("human-visible")
    hidden = unique_name("human-hidden")

    assert {:ok, _} =
             IAM.create_managed_policy_strict(
               name: visible,
               path: "/",
               document: policy_json()
             )

    assert {:ok, _} =
             IAM.create_managed_policy_strict(
               name: hidden,
               path: "/team/",
               document: policy_json()
             )

    Mix.Task.run("maxio.admin.policy.list", [])

    visible_line = "[maxio admin.policy.visible] name=#{visible} path=/"

    hidden_line =
      "[maxio admin.policy.omitted] name=#{hidden} path=/team/ reason=non_root_path"

    assert_received {:mix_shell, :info, [^visible_line]}
    assert_received {:mix_shell, :info, [^hidden_line]}

    refute_received {:mix_shell, :info, _message}
  end

  test "show rejects missing names and reports unknown policies without internal paths" do
    missing = unique_name("missing")

    missing_name =
      assert_raise Mix.Error, fn ->
        Mix.Task.run("maxio.admin.policy.show", ["--json"])
      end

    assert missing_name.message == "usage: mix maxio.admin.policy.show NAME [--json]"
    refute missing_name.message =~ "/"

    Mix.Task.reenable("maxio.admin.policy.show")

    unknown =
      assert_raise Mix.Error, fn ->
        Mix.Task.run("maxio.admin.policy.show", [missing, "--json"])
      end

    assert unknown.message == "admin policy not found: #{missing}"
    refute unknown.message =~ "/team/"
    refute unknown.message =~ "arn:"
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp policy_json do
    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Action" => "s3:GetObject",
        "Resource" => "arn:aws:s3:::admin-cli-test/*"
      }
    })
  end
end
