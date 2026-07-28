defmodule MaxioWeb.ConsoleE2ETest do
  @moduledoc "Console 端到端导航矩阵（无浏览器，纯 LiveViewTest）。"
  use MaxioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, conn: log_in_console(conn)}
  end

  test "全链路：建桶 → 浏览 → 详情 → 设置启用版本化 → access keys", %{conn: conn} do
    # 1. 建桶（streams 列表 + 创建表单 → 行出现）
    {:ok, buckets_view, _} = live(conn, ~p"/buckets")
    buckets_view |> form("#create-bucket-form", bucket: %{name: "e2e-bucket"}) |> render_submit()
    assert has_element?(buckets_view, "#delete-bucket-e2e-bucket")
    assert {:ok, _b} = Maxio.Buckets.lookup("e2e-bucket")

    # 2. 直接经 context 放入对象（上传走 allow_upload，单测在 M5-5 覆盖；此处验证浏览/详情链路）
    {:ok, _o} =
      Maxio.Objects.put_version_with_id("e2e-bucket", "report.txt", "null", %{size: 4, etag: "e4"})

    # 3. 浏览（对象列表 stream + 对象名可见）
    {:ok, browse_view, browse_html} = live(conn, ~p"/buckets/e2e-bucket/browse")
    assert has_element?(browse_view, "#objects")
    assert browse_html =~ "report.txt"

    # 4. 详情（元数据容器 + etag 可见）
    {:ok, show_view, show_html} = live(conn, ~p"/buckets/e2e-bucket/object/report.txt")
    assert has_element?(show_view, "#object-detail")
    assert show_html =~ "e4"

    # 5. 设置：启用版本化（versioning 表单提交 → context 落地）
    {:ok, settings_view, _} = live(conn, ~p"/buckets/e2e-bucket/settings")
    settings_view |> form("#versioning-form", versioning: %{status: "Enabled"}) |> render_submit()
    {:ok, b} = Maxio.Buckets.lookup("e2e-bucket")
    assert b.versioning == "Enabled"

    # 6. access keys（列表 stream 挂载）
    {:ok, keys_view, _} = live(conn, ~p"/access-keys")
    assert has_element?(keys_view, "#access-keys")

    # 7. ops gate（只读 artifact shell 挂载）
    {:ok, ops_gate_view, _} = live(conn, ~p"/ops/gate")
    assert has_element?(ops_gate_view, "#ops-gate")
  end

  test "未登录全程被门控（/ /buckets /access-keys /ops/gate 均 redirect /login）", %{conn: _conn} do
    fresh = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/login"}}} = live(fresh, ~p"/")
    assert {:error, {:redirect, %{to: "/login"}}} = live(fresh, ~p"/buckets")
    assert {:error, {:redirect, %{to: "/login"}}} = live(fresh, ~p"/access-keys")
    assert {:error, {:redirect, %{to: "/login"}}} = live(fresh, ~p"/ops/gate")
  end
end
