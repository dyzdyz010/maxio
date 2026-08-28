defmodule Mix.Tasks.Maxio.Admin.UserMutationTest do
  use Maxio.DataCase, async: false

  alias Maxio.IAM

  @status_task "maxio.admin.user.status"
  @remove_task "maxio.admin.user.remove"

  setup do
    original_shell = Mix.shell()
    original_s3 = Application.fetch_env!(:maxio, :s3)
    Mix.shell(Mix.Shell.Process)
    Enum.each([@status_task, @remove_task], &Mix.Task.reenable/1)

    root_user = "AKIACLIROOTMUTATION"
    root_secret = "cli-root-secret-must-never-appear"

    Application.put_env(
      :maxio,
      :s3,
      original_s3
      |> Keyword.put(:root_user, root_user)
      |> Keyword.put(:root_password, root_secret)
    )

    on_exit(fn ->
      Mix.shell(original_shell)
      Application.put_env(:maxio, :s3, original_s3)
      Enum.each([@status_task, @remove_task], &Mix.Task.reenable/1)
    end)

    {:ok, root_user: root_user, root_secret: root_secret}
  end

  test "status uses only configured root ID and prints safe affected evidence", context do
    name = unique_access_name("CLISTATUS")
    assert {:ok, _user} = IAM.create_minio_user_strict(name, "cli-status-secret", "active")

    Mix.Task.run(@status_task, [name, "disabled"])
    output = receive_shell_output()

    assert output =~ "admin_action=admin_user_status"
    assert output =~ "required_action=admin:EnableUser"
    assert output =~ "target_user=#{name}"
    assert output =~ "requested_status=disabled"
    assert output =~ "affected_credentials=1"
    refute output =~ context.root_secret
    refute output =~ "cli-status-secret"
    assert {:ok, %{status: "inactive"}} = IAM.get_user(name)

    Mix.Task.reenable(@status_task)
    Mix.Task.run(@status_task, [name, "enabled"])
    assert receive_shell_output() =~ "requested_status=enabled"
    assert {:ok, %{status: "active"}} = IAM.get_user(name)
  end

  test "remove requires exact confirmation and never prints configured secret", context do
    name = unique_access_name("CLIREMOVE")
    assert {:ok, _user} = IAM.create_minio_user_strict(name, "cli-remove-secret", "active")

    error =
      assert_raise Mix.Error, fn ->
        Mix.Task.run(@remove_task, [name, "--confirm", name <> "-wrong"])
      end

    assert error.message == "remove confirmation must exactly match the target user name"
    assert {:ok, _user} = IAM.get_user(name)

    Mix.Task.reenable(@remove_task)
    Mix.Task.run(@remove_task, [name, "--confirm", name])
    output = receive_shell_output()

    assert output =~ "admin_action=admin_user_remove"
    assert output =~ "required_action=admin:DeleteUser"
    assert output =~ "target_user=#{name}"
    assert output =~ "access_keys_deleted=1"
    refute output =~ context.root_secret
    refute output =~ "cli-remove-secret"
    assert :error = IAM.get_user(name)
  end

  defp receive_shell_output(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> receive_shell_output([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp unique_access_name(prefix) do
    suffix = System.unique_integer([:positive, :monotonic])
    String.pad_trailing("AKIA#{prefix}#{suffix}", 20, "X")
  end
end
