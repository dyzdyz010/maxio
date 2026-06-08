defmodule MaxioWeb.ObjectLiveIndexTest do
  use MaxioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("obj-bucket", "arn:aws:iam:::root")
    {:ok, conn: log_in_console(conn)}
  end

  test "挂载列表与上传/文件夹表单", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse")
    assert has_element?(view, "#objects")
    assert has_element?(view, "#upload-form")
    assert has_element?(view, "#create-folder-form")
    assert has_element?(view, "#objects-empty")
  end

  test "不存在的桶重定向到 /buckets", %{conn: conn} do
    # mount/3 用 push_navigate/2 离开缺失资源 → LiveView 产生 :live_redirect（非 :redirect），
    # flash 携带「桶不存在」错误（不静默）。断言准确的框架输出形态与重定向目标 + flash。
    assert {:error, {:live_redirect, %{to: "/buckets", flash: %{"error" => "桶 no-such 不存在"}}}} =
             live(conn, ~p"/buckets/no-such/browse")
  end

  test "已有对象渲染在列表中", %{conn: conn} do
    {:ok, _o} =
      Maxio.Objects.put_version_with_id("obj-bucket", "hello.txt", "null", %{size: 5, etag: "e"})

    {:ok, view, html} = live(conn, ~p"/buckets/obj-bucket/browse")
    assert html =~ "hello.txt"
    refute has_element?(view, "#objects-empty[style]")
  end

  test "前缀导航展示文件夹", %{conn: conn} do
    {:ok, _o} =
      Maxio.Objects.put_version_with_id("obj-bucket", "docs/a.txt", "null", %{size: 1, etag: "e"})

    {:ok, _view, html} = live(conn, ~p"/buckets/obj-bucket/browse")
    assert html =~ "docs"
    # 进入文件夹后看到对象
    {:ok, _v2, html2} = live(conn, ~p"/buckets/obj-bucket/browse?prefix=docs/")
    assert html2 =~ "a.txt"
  end

  test "创建文件夹写零字节占位对象", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse")
    view |> form("#create-folder-form", folder: %{folder: "reports"}) |> render_submit()
    assert {:ok, _obj} = Maxio.Objects.get_metadata("obj-bucket", "reports/")
  end

  test "删除对象移除行（unversioned）", %{conn: conn} do
    {:ok, _o} =
      Maxio.Objects.put_version_with_id("obj-bucket", "del.txt", "null", %{size: 1, etag: "e"})

    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse")
    view |> element(~s([phx-value-key="del.txt"])) |> render_click()
    assert {:error, :not_found} = Maxio.Objects.get_metadata("obj-bucket", "del.txt")
  end
end
