defmodule MaxioWeb.GroupLiveTest do
  use MaxioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @group_policy ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:ListAllMyBuckets","Resource":"*"}})
  @updated_group_policy ~s({"Version":"2012-10-17","Statement":{"Effect":"Deny","Action":"s3:DeleteObject","Resource":"arn:aws:s3:::blocked/*"}})
  @managed_policy ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::bucket/*"}})

  setup %{conn: conn} do
    {:ok, conn: log_in_console(conn)}
  end

  test "mounts group list and create form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/groups")

    assert has_element?(view, "#groups")
    assert has_element?(view, "#groups-empty")
    assert has_element?(view, "#create-group-form")
    assert has_element?(view, "#create-group-submit")
  end

  test "creates and deletes an IAM group", %{conn: conn} do
    group_name = unique_name("console-group")
    suffix = dom_suffix(group_name)

    {:ok, view, _html} = live(conn, ~p"/groups")

    view
    |> form("#create-group-form", group: %{name: group_name, status: "active"})
    |> render_submit()

    assert has_element?(view, "#groups-#{suffix}")
    assert {:ok, %{group_name: ^group_name}} = Maxio.IAM.get_group(group_name)

    view |> element("#delete-group-#{suffix}") |> render_click()

    refute has_element?(view, "#groups-#{suffix}")
    assert :error = Maxio.IAM.get_group(group_name)
  end

  test "selected group can add and remove members", %{conn: conn} do
    user_name = unique_name("console-user")
    group_name = unique_name("console-members")
    user_suffix = dom_suffix(user_name)
    group_suffix = dom_suffix(group_name)

    {:ok, _user} = Maxio.IAM.create_user(name: user_name)
    {:ok, _group} = Maxio.IAM.create_group(name: group_name)

    {:ok, view, _html} = live(conn, ~p"/groups")

    view |> element("#select-group-#{group_suffix}") |> render_click()
    assert has_element?(view, "#group-detail-panel")
    assert has_element?(view, "#group-members-empty")

    view
    |> form("#group-add-member-form", member: %{user: user_name})
    |> render_submit()

    assert has_element?(view, "#group-member-#{user_suffix}")
    assert [%{user_name: ^user_name}] = Maxio.IAM.list_users_in_group(group_name)

    view |> element("#remove-group-member-#{user_suffix}") |> render_click()

    assert has_element?(view, "#group-members-empty")
    assert [] = Maxio.IAM.list_users_in_group(group_name)
  end

  test "group policy panel stores edits and deletes policies", %{conn: conn} do
    group_name = unique_name("console-policy")
    group_suffix = dom_suffix(group_name)
    policy_suffix = dom_suffix("list-buckets")
    {:ok, group} = Maxio.IAM.create_group(name: group_name)

    {:ok, view, _html} = live(conn, ~p"/groups")
    view |> element("#select-group-#{group_suffix}") |> render_click()

    assert has_element?(view, "#group-policy-panel")
    assert has_element?(view, "#group-policy-empty")

    view
    |> form("#group-policy-form", policy: %{name: "list-buckets", json: @group_policy})
    |> render_submit()

    assert has_element?(view, "#group-policy-#{policy_suffix}")

    assert [%{policy_name: "list-buckets", principal_arn: principal_arn}] =
             Maxio.IAM.list_group_policies(group_name)

    assert principal_arn == group.group_arn

    html = view |> element("#edit-group-policy-#{policy_suffix}") |> render_click()
    assert html =~ "s3:ListAllMyBuckets"

    view
    |> form("#group-policy-form", policy: %{name: "list-buckets", json: @updated_group_policy})
    |> render_submit()

    assert [%{document: %{"Statement" => %{"Effect" => "Deny"}}}] =
             Maxio.IAM.list_group_policies(group_name)

    view |> element("#delete-group-policy-#{policy_suffix}") |> render_click()
    assert has_element?(view, "#group-policy-empty")
    assert [] = Maxio.IAM.list_group_policies(group_name)
  end

  test "invalid group policy does not overwrite existing policy", %{conn: conn} do
    group_name = unique_name("console-invalid-policy")
    group_suffix = dom_suffix(group_name)
    {:ok, _group} = Maxio.IAM.create_group(name: group_name)
    :ok = Maxio.IAM.put_group_policy(group_name, "list-buckets", @group_policy)

    {:ok, view, _html} = live(conn, ~p"/groups")
    view |> element("#select-group-#{group_suffix}") |> render_click()

    view
    |> form("#group-policy-form",
      policy: %{name: "list-buckets", json: ~s({"Statement":{"Principal":"*"}})}
    )
    |> render_submit()

    assert [%{document: %{"Statement" => %{"Effect" => "Allow"}}}] =
             Maxio.IAM.list_group_policies(group_name)
  end

  test "selected group can attach and detach managed policies", %{conn: conn} do
    group_name = unique_name("console-group-policy")
    group_suffix = dom_suffix(group_name)
    policy_name = unique_name("console-group-managed")
    {:ok, group} = Maxio.IAM.create_group(name: group_name)

    {:ok, policy} =
      Maxio.IAM.create_managed_policy(
        name: policy_name,
        path: "/console/groups/",
        policy: @managed_policy
      )

    policy_suffix = dom_suffix(policy.policy_arn)

    {:ok, view, _html} = live(conn, ~p"/groups")
    view |> element("#select-group-#{group_suffix}") |> render_click()

    assert has_element?(view, "#group-managed-policy-list")
    assert has_element?(view, "#group-managed-policy-empty")

    view
    |> form("#group-attach-policy-form", attachment: %{policy_arn: policy.policy_arn})
    |> render_submit()

    assert has_element?(view, "#group-managed-policy-#{policy_suffix}")

    assert [%{group_arn: group_arn, policy_arn: policy_arn}] =
             Maxio.IAM.list_attached_group_policies(group_name)

    assert group_arn == group.group_arn
    assert policy_arn == policy.policy_arn

    html = render_click(view, "detach_group_policy", %{"policy-arn" => "not-an-arn"})

    assert html =~ "Detach managed policy failed"
    assert [%{policy_arn: ^policy_arn}] = Maxio.IAM.list_attached_group_policies(group_name)

    view |> element("#detach-group-policy-#{policy_suffix}") |> render_click()

    assert has_element?(view, "#group-managed-policy-empty")
    assert [] = Maxio.IAM.list_attached_group_policies(group_name)
  end

  test "deleting selected group clears detail panel", %{conn: conn} do
    group_name = unique_name("console-clear")
    suffix = dom_suffix(group_name)
    {:ok, _group} = Maxio.IAM.create_group(name: group_name)

    {:ok, view, _html} = live(conn, ~p"/groups")
    view |> element("#select-group-#{suffix}") |> render_click()
    assert has_element?(view, "#group-detail-panel")

    view |> element("#delete-group-#{suffix}") |> render_click()
    refute has_element?(view, "#group-detail-panel")
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp dom_suffix(value), do: Base.encode16(to_string(value), case: :lower)
end
