defmodule MaxioWeb.OpsReplacementLiveTest do
  use MaxioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maxio.Cluster.{SchedulerRun, SchedulerRunRollup, SchedulerRuns, SchedulerState}
  alias Maxio.Repo

  @env_keys [:fresh_drive_heal_scheduler, :rebalance_scheduler, :scheduler_ledger]

  setup %{conn: conn} do
    previous = Map.new(@env_keys, &{&1, Application.get_env(:maxio, &1, :__unset__)})
    Repo.delete_all(SchedulerState)
    Repo.delete_all(SchedulerRun)
    Repo.delete_all(SchedulerRunRollup)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :__unset__} -> Application.delete_env(:maxio, key)
        {key, value} -> Application.put_env(:maxio, key, value)
      end)
    end)

    {:ok, conn: log_in_console(conn)}
  end

  test "renders default blocked replacement shell as read-only evidence", %{conn: conn} do
    Application.put_env(:maxio, :fresh_drive_heal_scheduler, enabled: false)
    Application.put_env(:maxio, :rebalance_scheduler, enabled: false)
    Application.put_env(:maxio, :scheduler_ledger, enabled: true)

    {:ok, view, _html} = live(conn, ~p"/ops/replacement")

    assert has_element?(view, "#ops-replacement")
    assert has_element?(view, "#nav-ops-replacement")
    assert has_element?(view, "#ops-replacement-readonly-boundary", "read-only")
    assert has_element?(view, "#ops-replacement-profile")
    assert has_element?(view, "#ops-replacement-fresh-drive-heal")
    assert has_element?(view, "#ops-replacement-rebalance")
    assert has_element?(view, "#ops-replacement-scheduler-evidence")
    assert has_element?(view, "#ops-replacement-blockers")
    assert has_element?(view, "#ops-replacement-warnings")
    assert has_element?(view, "#ops-replacement-scheduler-states")
    assert has_element?(view, "#ops-replacement-recent-runs")
    assert has_element?(view, "#ops-replacement-cross-links")
    assert has_element?(view, "#ops-replacement-scheduler-states-empty")
    assert has_element?(view, "#ops-replacement-recent-runs-empty")
    assert has_element?(view, "#ops-replacement-blockers", "scheduler_not_healthy")
    refute has_element?(view, "#ops-replacement button")
    refute has_element?(view, "#ops-replacement form")
  end

  test "renders ready profile with scheduler state and recent run evidence", %{conn: conn} do
    put_ready_env()
    seed_ok_scheduled(:fresh_drive_heal)
    seed_ok_scheduled(:rebalance)

    {:ok, view, _html} = live(conn, ~p"/ops/replacement")

    assert has_element?(view, "#ops-replacement-status", "ready")
    assert has_element?(view, "#ops-replacement-scheduler-states-table")
    assert has_element?(view, "#ops-replacement-recent-runs-table")
    assert has_element?(view, "#ops-replacement-scheduler-evidence-table")
    assert has_element?(view, "#ops-replacement-scheduler-states", "fresh_drive_heal")
    assert has_element?(view, "#ops-replacement-scheduler-states", "rebalance")
    assert has_element?(view, "#ops-replacement-recent-runs", "scheduled")
    assert has_element?(view, "#ops-replacement-link-scan")
    assert has_element?(view, "#ops-replacement-link-rebalance")
    assert has_element?(view, "#ops-replacement-link-gate")
    refute has_element?(view, "#ops-replacement button")
    refute has_element?(view, "#ops-replacement form")
  end

  test "renders detailed scheduler evidence warnings in operator panels", %{conn: conn} do
    put_ready_env()
    seed_ok_scheduled(:fresh_drive_heal)
    seed_blocked_then_ok_scheduled(:rebalance)

    {:ok, view, _html} = live(conn, ~p"/ops/replacement")

    assert has_element?(view, "#ops-replacement-warnings", "blocked_runs_seen")
    refute has_element?(view, "#ops-replacement button")
    refute has_element?(view, "#ops-replacement form")
  end

  defp seed_ok_scheduled(scheduler) do
    now = DateTime.utc_now()
    started_at = DateTime.add(now, -1, :second)

    SchedulerRuns.record(
      scheduler,
      :scheduled,
      started_at,
      now,
      {:ok, %{status: :ok, phase: scheduler, job_id: "#{scheduler}-job"}},
      node: Node.self()
    )
  end

  defp seed_blocked_then_ok_scheduled(scheduler) do
    now = DateTime.utc_now()

    {:ok, _blocked} =
      SchedulerRuns.record(
        scheduler,
        :scheduled,
        DateTime.add(now, -4, :second),
        DateTime.add(now, -3, :second),
        {:ok, %{status: :blocked, phase: scheduler, job_id: "#{scheduler}-blocked"}},
        node: Node.self()
      )

    {:ok, _ok} =
      SchedulerRuns.record(
        scheduler,
        :scheduled,
        DateTime.add(now, -2, :second),
        DateTime.add(now, -1, :second),
        {:ok, %{status: :ok, phase: scheduler, job_id: "#{scheduler}-ok"}},
        node: Node.self()
      )
  end

  defp put_ready_env do
    Application.put_env(:maxio, :fresh_drive_heal_scheduler,
      enabled: true,
      probe_drive_health: true,
      auto_rebalance_after_heal: true,
      run_opts: []
    )

    Application.put_env(:maxio, :rebalance_scheduler,
      enabled: true,
      auto_source_cleanup: true,
      auto_rebalance_closure: true,
      run_opts: []
    )

    Application.put_env(:maxio, :scheduler_ledger, enabled: true)
  end
end
