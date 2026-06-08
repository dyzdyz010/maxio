defmodule MaxioWeb.DashboardLiveTest do
  use MaxioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, conn: log_in_console(conn)}
  end

  test "空状态挂载所有统计卡片", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#stat-buckets")
    assert has_element?(view, "#stat-objects")
    assert has_element?(view, "#stat-size")
    assert has_element?(view, "#stat-keys")
    assert has_element?(view, "#stat-multipart")
    assert has_element?(view, "#per-bucket-table")
  end

  test "有桶有对象时统计反映 per-bucket", %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("dash-bucket", "arn:aws:iam:::root")

    {:ok, _o} =
      Maxio.Objects.put_version_with_id("dash-bucket", "a.txt", "null", %{
        size: 100,
        etag: "abc"
      })

    {:ok, view, html} = live(conn, ~p"/")
    assert has_element?(view, "#per-bucket-table")
    assert html =~ "dash-bucket"
  end
end
