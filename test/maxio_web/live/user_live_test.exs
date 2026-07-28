defmodule MaxioWeb.UserLiveTest do
  use MaxioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @managed_policy ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::bucket/*"}})

  setup %{conn: conn} do
    {:ok, conn: log_in_console(conn)}
  end

  test "mounts user list and create form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users")

    assert has_element?(view, "#users")
    assert has_element?(view, "#users-empty")
    assert has_element?(view, "#create-user-form")
    assert has_element?(view, "#create-user-submit")
  end

  test "creates and deletes an IAM user", %{conn: conn} do
    user_name = unique_name("console-user")
    suffix = dom_suffix(user_name)

    {:ok, view, _html} = live(conn, ~p"/users")

    view
    |> form("#create-user-form", user: %{name: user_name, status: "active"})
    |> render_submit()

    assert has_element?(view, "#users-#{suffix}")
    assert {:ok, %{user_name: ^user_name}} = Maxio.IAM.get_user(user_name)

    view |> element("#delete-user-#{suffix}") |> render_click()

    refute has_element?(view, "#users-#{suffix}")
    assert :error = Maxio.IAM.get_user(user_name)
  end

  test "selected user can join and leave groups", %{conn: conn} do
    user_name = unique_name("console-member")
    group_name = unique_name("console-group")
    user_suffix = dom_suffix(user_name)
    group_suffix = dom_suffix(group_name)

    {:ok, _user} = Maxio.IAM.create_user(name: user_name)
    {:ok, _group} = Maxio.IAM.create_group(name: group_name)

    {:ok, view, _html} = live(conn, ~p"/users")

    view |> element("#select-user-#{user_suffix}") |> render_click()
    assert has_element?(view, "#user-detail-panel")
    assert has_element?(view, "#user-groups-empty")

    view
    |> form("#user-add-group-form", membership: %{group: group_name})
    |> render_submit()

    assert has_element?(view, "#user-group-#{group_suffix}")
    assert [%{group_name: ^group_name}] = Maxio.IAM.list_groups_for_user(user_name)

    view |> element("#remove-user-group-#{group_suffix}") |> render_click()

    assert has_element?(view, "#user-groups-empty")
    assert [] = Maxio.IAM.list_groups_for_user(user_name)
  end

  test "selected active user can create bound access key and shows secret once", %{conn: conn} do
    user_name = unique_name("console-key")
    user_suffix = dom_suffix(user_name)
    {:ok, user} = Maxio.IAM.create_user(name: user_name)

    {:ok, view, _html} = live(conn, ~p"/users")
    view |> element("#select-user-#{user_suffix}") |> render_click()

    html = view |> element("#create-user-key-#{user_suffix}") |> render_click()

    assert html =~ "user-new-secret-banner"
    assert html =~ "Secret Key:"

    [%{access_key_id: access_key_id, principal_arn: principal_arn}] =
      Maxio.IAM.list_access_keys()

    assert principal_arn == user.user_arn
    assert has_element?(view, "#user-access-key-#{access_key_id}")
  end

  test "deleting a user clears one-time access key secret banner", %{conn: conn} do
    user_name = unique_name("console-secret-clear")
    user_suffix = dom_suffix(user_name)
    {:ok, _user} = Maxio.IAM.create_user(name: user_name)

    {:ok, view, _html} = live(conn, ~p"/users")

    html = view |> element("#create-user-key-#{user_suffix}") |> render_click()

    assert html =~ "user-new-secret-banner"
    assert has_element?(view, "#user-new-secret-banner")

    view |> element("#delete-user-#{user_suffix}") |> render_click()

    refute has_element?(view, "#user-new-secret-banner")
  end

  test "selected user can attach and detach managed policies", %{conn: conn} do
    user_name = unique_name("console-user-policy")
    user_suffix = dom_suffix(user_name)
    policy_name = unique_name("console-user-managed")
    {:ok, user} = Maxio.IAM.create_user(name: user_name)

    {:ok, policy} =
      Maxio.IAM.create_managed_policy(
        name: policy_name,
        path: "/console/users/",
        policy: @managed_policy
      )

    policy_suffix = dom_suffix(policy.policy_arn)

    {:ok, view, _html} = live(conn, ~p"/users")
    view |> element("#select-user-#{user_suffix}") |> render_click()

    assert has_element?(view, "#user-managed-policies-panel")
    assert has_element?(view, "#user-managed-policy-empty")

    view
    |> form("#user-attach-policy-form", attachment: %{policy_arn: policy.policy_arn})
    |> render_submit()

    assert has_element?(view, "#user-managed-policy-#{policy_suffix}")

    assert [%{user_arn: user_arn, policy_arn: policy_arn}] =
             Maxio.IAM.list_attached_user_policies(user_name)

    assert user_arn == user.user_arn
    assert policy_arn == policy.policy_arn

    html = render_click(view, "detach_user_policy", %{"policy-arn" => "not-an-arn"})

    assert html =~ "Detach managed policy failed"
    assert [%{policy_arn: ^policy_arn}] = Maxio.IAM.list_attached_user_policies(user_name)

    view |> element("#detach-user-policy-#{policy_suffix}") |> render_click()

    assert has_element?(view, "#user-managed-policy-empty")
    assert [] = Maxio.IAM.list_attached_user_policies(user_name)
  end

  test "deleting selected user clears detail panel", %{conn: conn} do
    user_name = unique_name("console-clear")
    suffix = dom_suffix(user_name)
    {:ok, _user} = Maxio.IAM.create_user(name: user_name)

    {:ok, view, _html} = live(conn, ~p"/users")
    view |> element("#select-user-#{suffix}") |> render_click()
    assert has_element?(view, "#user-detail-panel")

    view |> element("#delete-user-#{suffix}") |> render_click()
    refute has_element?(view, "#user-detail-panel")
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp dom_suffix(value), do: Base.encode16(to_string(value), case: :lower)
end
