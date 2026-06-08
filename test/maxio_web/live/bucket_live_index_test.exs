defmodule MaxioWeb.BucketLiveIndexTest do
  use MaxioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, conn: log_in_console(conn)}
  end

  test "挂载列表与创建表单", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets")
    assert has_element?(view, "#buckets")
    assert has_element?(view, "#create-bucket-form")
    assert has_element?(view, "#buckets-empty")
  end

  test "提交合法桶名后出现在列表中", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets")

    html =
      view
      |> form("#create-bucket-form", bucket: %{name: "test-bucket"})
      |> render_submit()

    assert html =~ "test-bucket"
    assert has_element?(view, "#delete-bucket-test-bucket")
  end

  test "非法桶名报错误 flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets")

    html =
      view
      |> form("#create-bucket-form", bucket: %{name: "X"})
      |> render_submit()

    assert html =~ "命名规则"
  end

  test "重名桶报已存在", %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("dup-bucket", "arn:aws:iam:::root")
    {:ok, view, _html} = live(conn, ~p"/buckets")

    html =
      view
      |> form("#create-bucket-form", bucket: %{name: "dup-bucket"})
      |> render_submit()

    assert html =~ "已存在"
  end

  test "删除空桶移除行", %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("doomed-bucket", "arn:aws:iam:::root")
    {:ok, view, _html} = live(conn, ~p"/buckets")
    assert has_element?(view, "#delete-bucket-doomed-bucket")

    view |> element("#delete-bucket-doomed-bucket") |> render_click()
    refute has_element?(view, "#delete-bucket-doomed-bucket")
  end

  test "删除非空桶报错误，行保留", %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("full-bucket", "arn:aws:iam:::root")
    {:ok, _o} = Maxio.Objects.put_version_with_id("full-bucket", "k.txt", "null", %{size: 1, etag: "e"})
    {:ok, view, _html} = live(conn, ~p"/buckets")

    html = view |> element("#delete-bucket-full-bucket") |> render_click()
    assert html =~ "非空"
    assert has_element?(view, "#delete-bucket-full-bucket")
  end
end
