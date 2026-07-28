defmodule MaxioWeb.OpsRecoveryLiveTest do
  use MaxioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, conn: log_in_console(conn)}
  end

  test "renders read-only recovery shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ops/recovery")

    assert has_element?(view, "#ops-recovery")
    assert has_element?(view, "#nav-ops-recovery")
    assert has_element?(view, "#ops-recovery-readonly-boundary", "read-only")
    assert has_element?(view, "#ops-recovery-summary")
    assert has_element?(view, "#ops-recovery-axes")
    assert has_element?(view, "#ops-recovery-artifacts")
    assert has_element?(view, "#ops-recovery-operational-evidence")
    assert has_element?(view, "#ops-recovery-blockers")
    assert has_element?(view, "#ops-recovery-warnings")
    assert has_element?(view, "#ops-recovery-cross-links")
    assert has_element?(view, "#ops-recovery-link-gate")
    assert has_element?(view, "#ops-recovery-link-cluster")
    assert has_element?(view, "#ops-recovery-link-scan")
    assert has_element?(view, "#ops-recovery-link-replacement")
    assert has_element?(view, "#ops-recovery-link-rebalance")
    assert has_element?(view, "#ops-recovery-link-upgrade")
    assert has_element?(view, "#ops-recovery-link-observability")
    refute has_element?(view, "#ops-recovery button")
    refute has_element?(view, "#ops-recovery form")
  end
end
