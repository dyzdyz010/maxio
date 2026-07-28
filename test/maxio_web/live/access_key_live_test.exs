defmodule MaxioWeb.AccessKeyLiveTest do
  use MaxioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @identity_policy ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:ListAllMyBuckets","Resource":"*"}})
  @updated_identity_policy ~s({"Version":"2012-10-17","Statement":{"Effect":"Deny","Action":"s3:DeleteObject","Resource":"arn:aws:s3:::blocked/*"}})
  @list_buckets_suffix Base.encode16("list-buckets", case: :lower)
  @dotted_policy_suffix Base.encode16("s3.readonly", case: :lower)
  @dashed_policy_suffix Base.encode16("s3-readonly", case: :lower)

  setup %{conn: conn} do
    {:ok, conn: log_in_console(conn)}
  end

  test "挂载列表与创建表单", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/access-keys")
    assert has_element?(view, "#access-keys")
    assert has_element?(view, "#create-key-form")
    assert has_element?(view, "#create-key-submit")
  end

  test "空态显示占位行", %{conn: conn} do
    # test sandbox 下 access_keys 表初始为空（MemoryStore 凭据后端不向 DB 引导 root）。
    assert Maxio.IAM.list_access_keys() == []
    {:ok, view, _html} = live(conn, ~p"/access-keys")
    assert has_element?(view, "#access-keys-empty")
  end

  test "创建密钥显示一次性 secret 并入列表", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/access-keys")
    html = view |> element("#create-key-form") |> render_submit()
    assert html =~ "new-secret-banner"
    assert html =~ "Secret Key:"
    # 创建的 access key 行随之进入 stream（at: 0）。
    [%{access_key_id: ak}] = Maxio.IAM.list_access_keys()
    assert has_element?(view, "#delete-key-#{ak}")
  end

  test "刷新页面后 secret banner 不再出现（仅一次性）", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/access-keys")
    html = view |> element("#create-key-form") |> render_submit()
    assert html =~ "new-secret-banner"

    # 重新挂载（模拟刷新）→ secret 绝不持久化展示。
    {:ok, view2, html2} = live(conn, ~p"/access-keys")
    refute html2 =~ "new-secret-banner"
    refute has_element?(view2, "#new-secret-banner")
  end

  test "secret 绝不出现在列表行中", %{conn: conn} do
    {:ok, %{access_key_id: ak, secret_key: sk}} = Maxio.IAM.create_access_key()
    {:ok, _view, html} = live(conn, ~p"/access-keys")
    assert html =~ ak
    refute html =~ sk
  end

  test "iam_user 行显示 badge-ghost，root 行显示 badge-primary", %{conn: conn} do
    {:ok, %{access_key_id: user_ak}} = Maxio.IAM.create_access_key()
    {:ok, %{access_key_id: root_ak}} = Maxio.IAM.create_access_key(type: "root")

    {:ok, view, _html} = live(conn, ~p"/access-keys")
    assert has_element?(view, "#keys-#{user_ak} .badge-ghost")
    assert has_element?(view, "#keys-#{root_ak} .badge-primary")
  end

  test "删除非 root 密钥移除行", %{conn: conn} do
    {:ok, %{access_key_id: ak}} = Maxio.IAM.create_access_key()
    {:ok, view, _html} = live(conn, ~p"/access-keys")
    assert has_element?(view, "#delete-key-#{ak}")
    view |> element("#delete-key-#{ak}") |> render_click()
    refute has_element?(view, "#delete-key-#{ak}")
  end

  test "删除最后一个 root 被拒", %{conn: conn} do
    {:ok, %{access_key_id: root_ak}} = Maxio.IAM.create_access_key(type: "root")
    {:ok, view, _html} = live(conn, ~p"/access-keys")
    # 系统此时只有这一个 root（sandbox 内）→ 删除被拒。
    html = view |> element("#delete-key-#{root_ak}") |> render_click()
    assert html =~ "最后一个 root"
    # 行仍在（删除被拒，未移除）。
    assert has_element?(view, "#delete-key-#{root_ak}")
  end

  test "root access keys do not expose identity policy management", %{conn: conn} do
    {:ok, %{access_key_id: root_ak}} = Maxio.IAM.create_access_key(type: "root")

    {:ok, view, _html} = live(conn, ~p"/access-keys")
    refute has_element?(view, "#manage-policies-#{root_ak}")

    render_click(view, "select_policy_key", %{"ak" => root_ak})
    refute has_element?(view, "#identity-policy-panel")
  end

  test "access key identity policy panel stores edits and deletes inline policies", %{conn: conn} do
    {:ok, %{access_key_id: ak, principal_arn: arn}} = Maxio.IAM.create_access_key()
    {:ok, view, _html} = live(conn, ~p"/access-keys")

    view |> element("#manage-policies-#{ak}") |> render_click()
    assert has_element?(view, "#identity-policy-panel")
    assert has_element?(view, "#identity-policy-empty")
    assert has_element?(view, "#identity-policy-form")

    view
    |> form("#identity-policy-form",
      policy: %{name: "list-buckets", json: @identity_policy}
    )
    |> render_submit()

    assert has_element?(view, "#policy-#{@list_buckets_suffix}")

    assert [%{policy_name: "list-buckets", principal_arn: ^arn}] =
             Maxio.IAM.list_principal_policies(arn)

    html = view |> element("#edit-policy-#{@list_buckets_suffix}") |> render_click()
    assert html =~ "s3:ListAllMyBuckets"

    view
    |> form("#identity-policy-form",
      policy: %{name: "list-buckets", json: @updated_identity_policy}
    )
    |> render_submit()

    assert [%{document: %{"Statement" => %{"Effect" => "Deny"}}}] =
             Maxio.IAM.list_principal_policies(arn)

    view |> element("#delete-policy-#{@list_buckets_suffix}") |> render_click()
    assert has_element?(view, "#identity-policy-empty")
    assert Maxio.IAM.list_principal_policies(arn) == []
  end

  test "identity policy DOM ids do not collide for AWS policy-name punctuation", %{conn: conn} do
    {:ok, %{access_key_id: ak, principal_arn: arn}} = Maxio.IAM.create_access_key()
    :ok = Maxio.IAM.put_principal_policy(arn, "s3.readonly", @identity_policy)
    :ok = Maxio.IAM.put_principal_policy(arn, "s3-readonly", @identity_policy)

    {:ok, view, _html} = live(conn, ~p"/access-keys")
    view |> element("#manage-policies-#{ak}") |> render_click()

    assert has_element?(view, "#policy-#{@dotted_policy_suffix}")
    assert has_element?(view, "#policy-#{@dashed_policy_suffix}")
    assert has_element?(view, "#edit-policy-#{@dotted_policy_suffix}")
    assert has_element?(view, "#edit-policy-#{@dashed_policy_suffix}")
  end

  test "invalid identity policy does not overwrite existing principal policy", %{conn: conn} do
    {:ok, %{access_key_id: ak, principal_arn: arn}} = Maxio.IAM.create_access_key()
    :ok = Maxio.IAM.put_principal_policy(arn, "list-buckets", @identity_policy)

    {:ok, view, _html} = live(conn, ~p"/access-keys")
    view |> element("#manage-policies-#{ak}") |> render_click()

    view
    |> form("#identity-policy-form",
      policy: %{name: "list-buckets", json: ~s({"Statement":{"Principal":"*"}})}
    )
    |> render_submit()

    assert [%{document: %{"Statement" => %{"Effect" => "Allow"}}}] =
             Maxio.IAM.list_principal_policies(arn)
  end

  test "deleting selected access key clears identity policy panel", %{conn: conn} do
    {:ok, %{access_key_id: ak}} = Maxio.IAM.create_access_key()
    {:ok, view, _html} = live(conn, ~p"/access-keys")

    view |> element("#manage-policies-#{ak}") |> render_click()
    assert has_element?(view, "#identity-policy-panel")

    view |> element("#delete-key-#{ak}") |> render_click()
    refute has_element?(view, "#identity-policy-panel")
  end

  test "stale identity policy actions after panel clear do not crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/access-keys")

    html = render_click(view, "edit_policy", %{"name" => "stale"})
    assert html =~ "Select an access key"

    html = render_click(view, "delete_policy", %{"name" => "stale"})
    assert html =~ "Select an access key"

    html =
      render_submit(view, "save_policy", %{
        "policy" => %{"name" => "stale", "json" => @identity_policy}
      })

    assert html =~ "Select an access key"
  end
end
