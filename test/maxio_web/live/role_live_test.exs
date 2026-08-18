defmodule MaxioWeb.RoleLiveTest do
  use MaxioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @managed_policy ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::bucket/*"}})

  setup %{conn: conn} do
    {:ok, conn: log_in_console(conn)}
  end

  test "mounts role and managed policy forms", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/roles")

    assert has_element?(view, "#roles")
    assert has_element?(view, "#roles-empty")
    assert has_element?(view, "#create-role-form")
    assert has_element?(view, "#create-role-submit")
    assert has_element?(view, "#managed-policies-panel")
    assert has_element?(view, "#create-managed-policy-form")
  end

  test "creates and deletes an IAM role", %{conn: conn} do
    role_name = unique_name("console-role")
    suffix = dom_suffix(role_name)
    role_arn = Maxio.IAM.role_arn(role_name)

    {:ok, view, _html} = live(conn, ~p"/roles")

    view
    |> form("#create-role-form",
      role: %{name: role_name, duration: "7200", trust_policy: trust_policy()}
    )
    |> render_submit()

    assert has_element?(view, "#roles-#{suffix}")

    assert {:ok, %{role_name: ^role_name, max_session_duration_seconds: 7200}} =
             Maxio.IAM.get_role_by_arn(role_arn)

    view |> element("#delete-role-#{suffix}") |> render_click()

    refute has_element?(view, "#roles-#{suffix}")
    assert :error = Maxio.IAM.get_role_by_arn(role_arn)
  end

  test "invalid trust policy does not create a role", %{conn: conn} do
    role_name = unique_name("console-bad-role")

    {:ok, view, _html} = live(conn, ~p"/roles")

    view
    |> form("#create-role-form",
      role: %{
        name: role_name,
        duration: "3600",
        trust_policy: ~s({"Statement":{"Action":"s3:GetObject"}})
      }
    )
    |> render_submit()

    refute has_element?(view, "#roles-#{dom_suffix(role_name)}")
    assert :error = Maxio.IAM.get_role_by_arn(Maxio.IAM.role_arn(role_name))
  end

  test "creates and deletes a managed policy", %{conn: conn} do
    policy_name = unique_name("console-policy")
    policy_arn = Maxio.IAM.managed_policy_arn(policy_name, "/console/")
    suffix = dom_suffix(policy_arn)

    {:ok, view, _html} = live(conn, ~p"/roles")

    view
    |> form("#create-managed-policy-form",
      managed_policy: %{name: policy_name, path: "/console/", json: @managed_policy}
    )
    |> render_submit()

    assert has_element?(view, "#managed-policy-#{suffix}")
    assert {:ok, %{policy_arn: ^policy_arn}} = Maxio.IAM.get_managed_policy(policy_arn)

    view |> element("#delete-managed-policy-#{suffix}") |> render_click()

    refute has_element?(view, "#managed-policy-#{suffix}")
    assert :error = Maxio.IAM.get_managed_policy(policy_arn)
  end

  test "deleting a managed policy that no longer exists refreshes the list without crashing", %{
    conn: conn
  } do
    policy_name = unique_name("console-ghost-policy")
    ghost_arn = Maxio.IAM.managed_policy_arn(policy_name, "/console/")

    kept_name = unique_name("console-kept-policy")

    {:ok, kept} =
      Maxio.IAM.create_managed_policy(
        name: kept_name,
        path: "/console/",
        policy: @managed_policy
      )

    {:ok, view, _html} = live(conn, ~p"/roles")

    html = render_click(view, "delete_managed_policy", %{"policy-arn" => ghost_arn})

    assert html =~ "Deleted managed policy"
    assert has_element?(view, "#managed-policy-#{dom_suffix(kept.policy_arn)}")
    assert :error = Maxio.IAM.get_managed_policy(ghost_arn)
  end

  test "selected role can attach and detach managed policies", %{conn: conn} do
    role_name = unique_name("console-attach-role")
    role_suffix = dom_suffix(role_name)
    {:ok, role} = Maxio.IAM.create_role(role_name: role_name, trust_policy: trust_policy())

    policy_name = unique_name("console-attach-policy")

    {:ok, policy} =
      Maxio.IAM.create_managed_policy(
        name: policy_name,
        path: "/console/",
        policy: @managed_policy
      )

    policy_suffix = dom_suffix(policy.policy_arn)

    {:ok, view, _html} = live(conn, ~p"/roles")

    view |> element("#select-role-#{role_suffix}") |> render_click()
    assert has_element?(view, "#role-detail-panel")
    assert has_element?(view, "#role-policy-empty")

    view
    |> form("#role-attach-policy-form", attachment: %{policy_arn: policy.policy_arn})
    |> render_submit()

    assert has_element?(view, "#role-policy-#{policy_suffix}")

    assert [%{policy_arn: policy_arn}] = Maxio.IAM.list_attached_role_policies(role.role_arn)
    assert policy_arn == policy.policy_arn

    view |> element("#detach-role-policy-#{policy_suffix}") |> render_click()

    assert has_element?(view, "#role-policy-empty")
    assert [] = Maxio.IAM.list_attached_role_policies(role.role_arn)
  end

  test "malformed detach event is rejected without crashing selected role", %{conn: conn} do
    role_name = unique_name("console-malformed-detach")
    role_suffix = dom_suffix(role_name)
    {:ok, role} = Maxio.IAM.create_role(role_name: role_name, trust_policy: trust_policy())

    policy_name = unique_name("console-malformed-policy")

    {:ok, policy} =
      Maxio.IAM.create_managed_policy(
        name: policy_name,
        path: "/console/",
        policy: @managed_policy
      )

    :ok = Maxio.IAM.attach_role_policy(role.role_arn, policy.policy_arn)

    {:ok, view, _html} = live(conn, ~p"/roles")
    view |> element("#select-role-#{role_suffix}") |> render_click()

    html = render_click(view, "detach_role_policy", %{"policy-arn" => "not-an-arn"})

    assert html =~ "Detach managed policy failed"
    assert has_element?(view, "#role-detail-panel")
    assert [%{policy_arn: policy_arn}] = Maxio.IAM.list_attached_role_policies(role.role_arn)
    assert policy_arn == policy.policy_arn

    html = render_click(view, "detach_role_policy", %{})

    assert html =~ "Detach managed policy failed"
    assert has_element?(view, "#role-detail-panel")
    assert [%{policy_arn: ^policy_arn}] = Maxio.IAM.list_attached_role_policies(role.role_arn)
  end

  test "attached managed policy cannot be deleted from console", %{conn: conn} do
    role_name = unique_name("console-protect-role")
    {:ok, role} = Maxio.IAM.create_role(role_name: role_name, trust_policy: trust_policy())

    policy_name = unique_name("console-protect-policy")

    {:ok, policy} =
      Maxio.IAM.create_managed_policy(
        name: policy_name,
        path: "/console/",
        policy: @managed_policy
      )

    :ok = Maxio.IAM.attach_role_policy(role.role_arn, policy.policy_arn)

    {:ok, view, _html} = live(conn, ~p"/roles")

    html =
      view |> element("#delete-managed-policy-#{dom_suffix(policy.policy_arn)}") |> render_click()

    assert html =~ "Detach this policy from users, groups, or roles before deleting it"

    assert {:ok, %{policy_arn: policy_arn}} = Maxio.IAM.get_managed_policy(policy.policy_arn)
    assert policy_arn == policy.policy_arn
    assert [%{policy_arn: ^policy_arn}] = Maxio.IAM.list_attached_role_policies(role.role_arn)
  end

  test "deleting selected role clears detail panel", %{conn: conn} do
    role_name = unique_name("console-clear-role")
    suffix = dom_suffix(role_name)
    {:ok, _role} = Maxio.IAM.create_role(role_name: role_name, trust_policy: trust_policy())

    {:ok, view, _html} = live(conn, ~p"/roles")
    view |> element("#select-role-#{suffix}") |> render_click()
    assert has_element?(view, "#role-detail-panel")

    view |> element("#delete-role-#{suffix}") |> render_click()
    refute has_element?(view, "#role-detail-panel")
  end

  defp trust_policy do
    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Principal" => %{"AWS" => Maxio.IAM.root_principal_arn()},
        "Action" => "sts:AssumeRole"
      }
    })
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp dom_suffix(value), do: Base.encode16(to_string(value), case: :lower)
end
