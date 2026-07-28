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
    assert has_element?(view, "#nav-users")
    assert has_element?(view, "#nav-groups")
    assert has_element?(view, "#nav-roles")
    assert has_element?(view, "#nav-sts-sessions")
    assert has_element?(view, "#nav-ops-cluster")
    assert has_element?(view, "#nav-ops-compat")
    assert has_element?(view, "#nav-ops-gate")
    assert has_element?(view, "#nav-ops-observability")
    assert has_element?(view, "#nav-ops-rebalance")
    assert has_element?(view, "#nav-ops-recovery")
    assert has_element?(view, "#nav-ops-replacement")
    assert has_element?(view, "#nav-ops-scan")
    assert has_element?(view, "#nav-ops-upgrade")
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

    {:ok, users_view, _} = live(conn, ~p"/users")
    assert has_element?(users_view, "#console-sidebar")

    {:ok, groups_view, _} = live(conn, ~p"/groups")
    assert has_element?(groups_view, "#console-sidebar")

    {:ok, roles_view, _} = live(conn, ~p"/roles")
    assert has_element?(roles_view, "#console-sidebar")

    {:ok, sts_sessions_view, _} = live(conn, ~p"/sts-sessions")
    assert has_element?(sts_sessions_view, "#console-sidebar")

    {:ok, ops_cluster_view, _} = live(conn, ~p"/ops/cluster")
    assert has_element?(ops_cluster_view, "#console-sidebar")

    {:ok, ops_compat_view, _} = live(conn, ~p"/ops/compat")
    assert has_element?(ops_compat_view, "#console-sidebar")

    {:ok, ops_gate_view, _} = live(conn, ~p"/ops/gate")
    assert has_element?(ops_gate_view, "#console-sidebar")

    {:ok, ops_observability_view, _} = live(conn, ~p"/ops/observability")
    assert has_element?(ops_observability_view, "#console-sidebar")

    {:ok, ops_rebalance_view, _} = live(conn, ~p"/ops/rebalance")
    assert has_element?(ops_rebalance_view, "#console-sidebar")

    {:ok, ops_recovery_view, _} = live(conn, ~p"/ops/recovery")
    assert has_element?(ops_recovery_view, "#console-sidebar")

    {:ok, ops_replacement_view, _} = live(conn, ~p"/ops/replacement")
    assert has_element?(ops_replacement_view, "#console-sidebar")

    {:ok, ops_scan_view, _} = live(conn, ~p"/ops/scan")
    assert has_element?(ops_scan_view, "#console-sidebar")

    {:ok, ops_upgrade_view, _} = live(conn, ~p"/ops/upgrade")
    assert has_element?(ops_upgrade_view, "#console-sidebar")
  end
end
