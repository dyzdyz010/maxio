defmodule MaxioWeb.BucketLiveSettingsTest do
  use MaxioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("cfg-bucket", "arn:aws:iam:::root")
    {:ok, conn: log_in_console(conn)}
  end

  test "挂载 tabs 与默认版本化表单", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings")
    assert has_element?(view, "#settings-tabs")
    assert has_element?(view, "#versioning-form")
    assert has_element?(view, "#tab-policy")
  end

  test "7 个 tab 链接全部存在", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings")
    assert has_element?(view, "#tab-versioning")
    assert has_element?(view, "#tab-policy")
    assert has_element?(view, "#tab-acl")
    assert has_element?(view, "#tab-tags")
    assert has_element?(view, "#tab-cors")
    assert has_element?(view, "#tab-lifecycle")
    assert has_element?(view, "#tab-encryption")
  end

  test "无效 tab 回退 versioning", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=bogus")
    assert has_element?(view, "#versioning-form")
    refute has_element?(view, "#policy-form")
  end

  test "不存在的桶重定向回 /buckets", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/buckets", flash: %{"error" => "桶不存在"}}}} =
             live(conn, ~p"/buckets/no-such/settings")
  end

  test "启用版本化", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings")
    view |> form("#versioning-form", versioning: %{status: "Enabled"}) |> render_submit()
    {:ok, b} = Maxio.Buckets.lookup("cfg-bucket")
    assert b.versioning == "Enabled"
  end

  test "Unversioned 映射为 Suspended", %{conn: conn} do
    :ok = Maxio.Buckets.put_versioning("cfg-bucket", "Enabled", nil)
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings")
    view |> form("#versioning-form", versioning: %{status: "Unversioned"}) |> render_submit()
    {:ok, b} = Maxio.Buckets.lookup("cfg-bucket")
    assert b.versioning == "Suspended"
  end

  test "policy tab 保存合法 JSON", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=policy")

    json =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::cfg-bucket/*"}]})

    view |> form("#policy-form", policy: %{json: json}) |> render_submit()
    assert {:ok, _stored} = Maxio.Policy.Store.get_bucket_policy("cfg-bucket")
  end

  test "policy tab 空 = 删除策略", %{conn: conn} do
    :ok =
      Maxio.Policy.Store.put_bucket_policy(
        "cfg-bucket",
        ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::cfg-bucket/*"}]})
      )

    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=policy")
    view |> form("#policy-form", policy: %{json: "   "}) |> render_submit()
    assert :none = Maxio.Policy.Store.get_bucket_policy("cfg-bucket")
  end

  test "policy tab 非法 JSON 报 MalformedPolicy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=policy")
    html = view |> form("#policy-form", policy: %{json: "{not json"}) |> render_submit()
    assert html =~ "MalformedPolicy"
  end

  test "acl tab 设 public-read", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=acl")
    view |> form("#acl-form", acl: %{canned: "public-read"}) |> render_submit()
    {:ok, b} = Maxio.Buckets.lookup("cfg-bucket")
    assert b.acl_canned == "public-read"
  end

  test "tags tab 保存合法标签", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=tags")
    view |> form("#bucket-tags-form", tags: %{raw: "env=prod\nteam=platform"}) |> render_submit()
    assert {:ok, tags} = Maxio.Buckets.get_tags("cfg-bucket")
    assert {"env", "prod"} in tags
    assert {"team", "platform"} in tags
  end

  test "tags tab aws: 前缀被拒", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=tags")
    html = view |> form("#bucket-tags-form", tags: %{raw: "aws:foo=bar"}) |> render_submit()
    assert html =~ "标签非法"
    assert {:ok, []} = Maxio.Buckets.get_tags("cfg-bucket")
  end

  test "cors tab 保存合法 JSON", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=cors")
    json = ~s([{"allowed_origins":["*"],"allowed_methods":["GET"]}])
    view |> form("#cors-form", cors: %{json: json}) |> render_submit()
    assert {:ok, [%{"allowed_origins" => ["*"]}]} = Maxio.BucketConfigs.get("cfg-bucket", :cors)
  end

  test "cors tab 空 = 删除", %{conn: conn} do
    :ok = Maxio.BucketConfigs.put("cfg-bucket", :cors, [%{"allowed_origins" => ["*"]}])
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=cors")
    view |> form("#cors-form", cors: %{json: ""}) |> render_submit()
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :cors)
  end

  test "cors tab 非法 JSON 报错", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=cors")
    html = view |> form("#cors-form", cors: %{json: "[not json"}) |> render_submit()
    assert html =~ "JSON 非法"
  end

  test "lifecycle tab 显式 defer 告警 + 保存 JSON", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=lifecycle")
    assert has_element?(view, "#lifecycle-defer-alert")
    assert html =~ "后台过期/转储执行尚未实现"
    json = ~s([{"id":"expire-30","status":"Enabled"}])
    view |> form("#lifecycle-form", lifecycle: %{json: json}) |> render_submit()
    assert {:ok, [%{"id" => "expire-30"}]} = Maxio.BucketConfigs.get("cfg-bucket", :lifecycle)
  end

  test "encryption tab 设 AES256，KMS 被拒", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=encryption")
    view |> form("#encryption-form", encryption: %{algorithm: "AES256"}) |> render_submit()
    assert {:ok, %{"algorithm" => "AES256"}} = Maxio.BucketConfigs.get("cfg-bucket", :encryption)

    html =
      view |> form("#encryption-form", encryption: %{algorithm: "aws:kms"}) |> render_submit()

    assert html =~ "尚未实现"
    # KMS 拒绝绝不静默当 AES256：仍保留前次 AES256，未被 KMS 覆写。
    assert {:ok, %{"algorithm" => "AES256"}} = Maxio.BucketConfigs.get("cfg-bucket", :encryption)
  end

  test "encryption tab none = 关闭加密", %{conn: conn} do
    :ok = Maxio.BucketConfigs.put("cfg-bucket", :encryption, %{"algorithm" => "AES256"})
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=encryption")
    view |> form("#encryption-form", encryption: %{algorithm: "none"}) |> render_submit()
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :encryption)
  end
end
