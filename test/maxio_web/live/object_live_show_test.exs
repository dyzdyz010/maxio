defmodule MaxioWeb.ObjectLiveShowTest do
  use MaxioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("show-bucket", "arn:aws:iam:::root")
    {:ok, _o} = Maxio.Objects.put_version_with_id("show-bucket", "doc.txt", "null", %{size: 9, etag: "e9"})
    {:ok, conn: log_in_console(conn)}
  end

  test "挂载详情、tags 表单、版本表", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")
    assert has_element?(view, "#object-detail")
    assert has_element?(view, "#tags-form")
    assert has_element?(view, "#versions")
    assert html =~ "doc.txt"
    assert html =~ "e9"
  end

  test "详情展示元数据字段", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")
    assert html =~ "ETag"
    assert html =~ "Content-Type"
    assert html =~ "Storage Class"
    assert html =~ "Version ID"
    # storage_class 默认 STANDARD，version_id 默认 null
    assert html =~ "STANDARD"
    assert html =~ "null"
  end

  test "版本表行带 delete marker badge（Enabled 桶 DELETE 产生 marker）", %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("ver-bucket", "arn:aws:iam:::root")
    :ok = Maxio.Buckets.put_versioning("ver-bucket", "Enabled", nil)
    {:ok, _o} = Maxio.Objects.put_version("ver-bucket", "v.txt", "Enabled", %{size: 3, etag: "v1"})
    {:ok, _dm} = Maxio.Objects.insert_delete_marker("ver-bucket", "v.txt", "Enabled")

    {:ok, _view, html} = live(conn, ~p"/buckets/ver-bucket/object/v.txt")
    assert html =~ "delete marker"
  end

  test "不存在对象重定向到 browse", %{conn: conn} do
    # mount/3 用 push_navigate/2 离开缺失资源 → LiveView 产生 :live_redirect（非 :redirect），
    # flash 携带「对象不存在」错误（不静默）。断言准确的框架输出形态。
    assert {:error, {:live_redirect, %{to: "/buckets/show-bucket/browse", flash: %{"error" => "对象不存在"}}}} =
             live(conn, ~p"/buckets/show-bucket/object/nope.txt")
  end

  test "保存合法标签", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")
    view |> form("#tags-form", tags: %{raw: "env=prod\nteam=storage"}) |> render_submit()
    assert {:ok, tags} = Maxio.Objects.get_tags("show-bucket", "doc.txt")
    assert {"env", "prod"} in tags
    assert {"team", "storage"} in tags
  end

  test "非法标签（aws: 前缀）报错", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")
    html = view |> form("#tags-form", tags: %{raw: "aws:foo=bar"}) |> render_submit()
    assert html =~ "标签非法"
    # 校验拒绝后未写入
    assert {:ok, tags} = Maxio.Objects.get_tags("show-bucket", "doc.txt")
    refute {"aws:foo", "bar"} in tags
  end

  test "删除版本后 stream 重取（Enabled 桶）", %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("del-bucket", "arn:aws:iam:::root")
    :ok = Maxio.Buckets.put_versioning("del-bucket", "Enabled", nil)
    {:ok, v1} = Maxio.Objects.put_version("del-bucket", "k.txt", "Enabled", %{size: 1, etag: "a"})
    {:ok, _v2} = Maxio.Objects.put_version("del-bucket", "k.txt", "Enabled", %{size: 2, etag: "b"})

    {:ok, view, _html} = live(conn, ~p"/buckets/del-bucket/object/k.txt")

    view
    |> element(~s([phx-value-vid="#{v1.version_id}"]))
    |> render_click()

    assert {:error, :not_found} =
             Maxio.Objects.get_version("del-bucket", "k.txt", v1.version_id)
  end
end
