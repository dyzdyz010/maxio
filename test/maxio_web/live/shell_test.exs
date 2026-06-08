defmodule MaxioWeb.ShellTest do
  use MaxioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, conn: log_in_console(conn)}
  end

  test "Dashboard 挂载侧边栏与身份", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#console-sidebar")
    assert has_element?(view, "#nav-dashboard")
    assert has_element?(view, "#nav-buckets")
    assert has_element?(view, "#nav-access-keys")
    assert has_element?(view, "#current-identity")
    assert has_element?(view, "#logout-link")
  end

  test "登出链接 method=delete 指向 ~p\"/logout\"", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, ~s{#logout-link[href="/logout"][data-method="delete"]})
  end

  test "侧边栏导航目标路由可挂载 shell（占位）", %{conn: conn} do
    {:ok, buckets_view, _} = live(conn, ~p"/buckets")
    assert has_element?(buckets_view, "#console-sidebar")

    {:ok, keys_view, _} = live(conn, ~p"/access-keys")
    assert has_element?(keys_view, "#console-sidebar")
  end
end
