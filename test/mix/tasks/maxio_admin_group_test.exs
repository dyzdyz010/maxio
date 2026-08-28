defmodule Mix.Tasks.Maxio.Admin.GroupTest do
  use Maxio.DataCase, async: false

  alias Maxio.Admin.GroupAdapter
  alias Maxio.IAM

  @list "maxio.admin.group.list"
  @show "maxio.admin.group.show"
  @update "maxio.admin.group.update"
  @status "maxio.admin.group.status"
  @tasks [@list, @show, @update, @status]

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

  test "list and show provide stable human and one safe JSON projection" do
    suffix = System.unique_integer([:positive, :monotonic])
    group = "cli-group-#{suffix}"
    user = "cli-user-#{suffix}"
    assert {:ok, _} = IAM.create_user(name: user)
    assert {:ok, _} = IAM.update_minio_group_members_strict(group, [user], false, "")
    assert :ok = IAM.put_group_policy(group, "hidden-inline", policy_json())

    Mix.Task.run(@list, [])
    human = shell_output()
    assert human =~ "admin_action=admin_group_list"
    assert human =~ "required_action=admin:ListGroups"
    assert human =~ group

    Mix.Task.reenable(@show)
    Mix.Task.run(@show, [group])
    shown = shell_output()
    assert shown =~ "name=#{group}"
    assert shown =~ "status=enabled"
    assert shown =~ "members=#{Jason.encode!([user])}"
    assert shown =~ "inline_policy_names=[\"hidden-inline\"]"
    refute shown =~ "s3:GetObject"

    assert {:ok, expected} = GroupAdapter.info(group)
    Mix.Task.reenable(@show)
    Mix.Task.run(@show, [group, "--json"])
    assert_received {:mix_shell, :info, [json]}
    assert Jason.decode!(json) == Jason.decode!(Jason.encode!(expected))
    refute json =~ "s3:GetObject"
  end

  test "update preserves repeated member argv and supports remove plus delete-empty" do
    suffix = System.unique_integer([:positive, :monotonic])
    group = "cli-update-#{suffix}"
    alice = "cli-alice-#{suffix}"
    bob = "cli-bob-#{suffix}"
    assert {:ok, _} = IAM.create_user(name: alice)
    assert {:ok, _} = IAM.create_user(name: bob)

    Mix.Task.run(@update, [group, "--member", bob, "--member", alice, "--member", bob])
    output = shell_output()
    assert output =~ "requested_member_count=3"
    assert output =~ "changed_member_count=2"
    assert {:ok, %{wire: %{"members" => members}}} = GroupAdapter.info(group)
    assert members == Enum.sort([alice, bob])

    Mix.Task.reenable(@update)
    Mix.Task.run(@update, [group, "--remove", "--member", alice, "--member", bob])
    assert shell_output() =~ "operation=remove"

    Mix.Task.reenable(@update)
    Mix.Task.run(@update, [group, "--delete-empty"])
    assert shell_output() =~ "operation=delete_empty"
    assert {:error, :group_not_found} = GroupAdapter.info(group)
  end

  test "duplicate add absent remove and same status expose fresh persisted timestamps" do
    suffix = System.unique_integer([:positive, :monotonic])
    group = "cli-noop-#{suffix}"
    user = "cli-noop-user-#{suffix}"
    absent = "cli-absent-user-#{suffix}"
    assert {:ok, _} = IAM.create_user(name: user)
    assert {:ok, _} = IAM.create_user(name: absent)

    Mix.Task.run(@update, [group, "--member", user, "--json"])
    assert_received {:mix_shell, :info, [first_json]}
    first = Jason.decode!(first_json)

    Mix.Task.reenable(@update)
    Mix.Task.run(@update, [group, "--member", user, "--json"])
    assert_received {:mix_shell, :info, [duplicate_json]}
    duplicate = Jason.decode!(duplicate_json)
    assert duplicate["changed_member_count"] == 0
    assert duplicate["updated_at"] > first["updated_at"]

    Mix.Task.reenable(@update)
    Mix.Task.run(@update, [group, "--remove", "--member", absent, "--json"])
    assert_received {:mix_shell, :info, [absent_json]}
    absent_remove = Jason.decode!(absent_json)
    assert absent_remove["changed_member_count"] == 0
    assert absent_remove["updated_at"] > duplicate["updated_at"]
  end

  test "status maps enabled and disabled and rejects unknown switches or values" do
    group = "cli-status-#{System.unique_integer([:positive, :monotonic])}"
    assert {:ok, _} = IAM.create_group(name: group)

    Mix.Task.run(@status, [group, "disabled", "--json"])
    assert_received {:mix_shell, :info, [json]}
    assert Jason.decode!(json)["actual_status"] == "inactive"

    Mix.Task.reenable(@status)
    assert_raise Mix.Error, ~r/usage:/, fn -> Mix.Task.run(@status, [group, "paused"]) end

    Mix.Task.reenable(@list)
    assert_raise Mix.Error, ~r/usage:/, fn -> Mix.Task.run(@list, ["--unknown"]) end
  end

  test "missing targets and nonempty delete fail with public safe messages" do
    missing = "cli-missing-#{System.unique_integer([:positive, :monotonic])}"

    assert_raise Mix.Error, "admin group not found: #{missing}", fn ->
      Mix.Task.run(@show, [missing])
    end

    Mix.Task.reenable(@update)
    user = "cli-blocker-#{System.unique_integer([:positive, :monotonic])}"
    group = "cli-blocked-#{System.unique_integer([:positive, :monotonic])}"
    assert {:ok, _} = IAM.create_user(name: user)
    assert {:ok, _} = IAM.update_minio_group_members_strict(group, [user], false, "")

    error = assert_raise Mix.Error, fn -> Mix.Task.run(@update, [group, "--delete-empty"]) end
    assert error.message == "admin group is not empty"
    refute error.message =~ "arn:"
  end

  defp shell_output(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> shell_output([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp policy_json do
    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Action" => "s3:GetObject",
        "Resource" => "arn:aws:s3:::cli/*"
      }
    })
  end
end
