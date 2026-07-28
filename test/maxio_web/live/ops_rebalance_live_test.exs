defmodule MaxioWeb.OpsRebalanceLiveTest do
  use MaxioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maxio.Cluster.Rebalance.Job
  alias Maxio.Repo

  setup %{conn: conn} do
    {:ok, conn: log_in_console(conn)}
  end

  test "empty job set renders the read-only rebalance shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ops/rebalance")

    assert has_element?(view, "#ops-rebalance")
    assert has_element?(view, "#ops-rebalance-empty")
    assert has_element?(view, "#nav-ops-rebalance")
    refute has_element?(view, "#ops-rebalance button")
    refute has_element?(view, "#ops-rebalance form")
  end

  test "renders selected rebalance workflow evidence without actions", %{conn: conn} do
    job =
      insert_job!(%{
        "kind" => "rebalance",
        "status" => "planned",
        "data_movement_status" => "not_started",
        "plan_scanned" => 4,
        "progress_moved" => 2,
        "source_cleanup_deleted" => 1
      })

    {:ok, view, _html} = live(conn, ~p"/ops/rebalance")

    assert has_element?(view, "#ops-rebalance-summary")
    assert has_element?(view, "#ops-rebalance-job-id", job.id)
    assert has_element?(view, "#ops-rebalance-phase", "copy_pass")
    assert has_element?(view, "#ops-rebalance-next-action", "maxio.rebalance.run")
    assert has_element?(view, "#ops-rebalance-next-action", job.id)
    assert has_element?(view, "#ops-rebalance-runtime-topology")
    assert has_element?(view, "#ops-rebalance-deployment-topology")
    assert has_element?(view, "#ops-rebalance-audit")
    assert has_element?(view, "#ops-rebalance-closure")
    assert has_element?(view, "#ops-rebalance-jobs-table")
    assert has_element?(view, "#ops-rebalance-job-#{safe_id(job.id)}")
    refute has_element?(view, "#ops-rebalance button")
    refute has_element?(view, "#ops-rebalance form")
  end

  test "invalid job_id query warns and falls back to latest job", %{conn: conn} do
    job = insert_job!()

    {:ok, view, _html} = live(conn, ~p"/ops/rebalance?job_id=../bad")

    assert has_element?(view, "#ops-rebalance-selection-warning", "invalid_job_id")
    assert has_element?(view, "#ops-rebalance-selection-warning", job.id)
    assert has_element?(view, "#ops-rebalance-job-id", job.id)
  end

  test "destructive next action is rendered as a boundary warning only", %{conn: conn} do
    job =
      insert_job!(%{
        "kind" => "decommission",
        "target_set_id" => 2,
        "status" => "complete",
        "data_movement_status" => "complete",
        "source_cleanup_status" => "complete",
        "topology_removal_status" => "runtime_local_applied",
        "topology_removal_scope" => "runtime_local",
        "topology_removal_cluster_status" => "runtime_converged",
        "topology_removal_deployment_status" => "verified",
        "topology_removal_removed_pool_ids" => [20],
        "physical_removal_status" => "not_started"
      })

    {:ok, view, _html} = live(conn, ~p"/ops/rebalance?job_id=#{job.id}")

    assert has_element?(view, "#ops-rebalance-phase", "physical_removal")
    assert has_element?(view, "#ops-rebalance-next-action", "maxio.rebalance.physical_remove")
    assert has_element?(view, "#ops-rebalance-destructive-boundary", "destructive boundary")
    refute has_element?(view, "#ops-rebalance button")
    refute has_element?(view, "#ops-rebalance form")
  end

  defp insert_job!(attrs \\ %{}) do
    attrs = Map.merge(base_attrs(), attrs)

    %Job{}
    |> Job.changeset(attrs)
    |> Repo.insert!()
  end

  defp base_attrs do
    %{
      "kind" => "rebalance",
      "status" => "planned",
      "data_movement_status" => "not_started",
      "source_cleanup_status" => "not_started",
      "current_only" => false,
      "include_drive_stats" => false,
      "page_size" => 500,
      "plan_status" => "ok",
      "plan" => %{},
      "plan_scanned" => 0,
      "plan_bytes" => 0,
      "plan_placement_fallbacks" => 0,
      "progress_scanned" => 0,
      "progress_moved" => 0,
      "progress_skipped" => 0,
      "progress_errors" => 0,
      "source_cleanup_scanned" => 0,
      "source_cleanup_deleted" => 0,
      "source_cleanup_skipped" => 0,
      "source_cleanup_errors" => 0,
      "rebalance_closure_status" => "not_started",
      "rebalance_closure_results" => %{},
      "rebalance_closure_blockers" => [],
      "topology_removal_status" => "not_started",
      "topology_removal_scope" => "none",
      "topology_removal_target_endpoints" => %{},
      "topology_removal_removed_pool_ids" => [],
      "topology_removal_cluster_status" => "not_started",
      "topology_removal_cluster_nodes" => [],
      "topology_removal_deployment_status" => "not_started",
      "physical_removal_status" => "not_started",
      "physical_removal_scope" => "none",
      "physical_removal_results" => %{},
      "physical_removal_roots_quarantined" => 0,
      "physical_removal_markers_written" => 0,
      "physical_removal_errors" => 0,
      "physical_removal_purge_status" => "not_started",
      "physical_removal_purge_scope" => "none",
      "physical_removal_purge_retention_seconds" => 0,
      "physical_removal_purge_results" => %{},
      "physical_removal_purge_roots_deleted" => 0,
      "physical_removal_purge_files_deleted" => 0,
      "physical_removal_purge_dirs_deleted" => 0,
      "physical_removal_purge_bytes_deleted" => 0,
      "physical_removal_purge_markers_written" => 0,
      "physical_removal_purge_errors" => 0,
      "started_at" => DateTime.utc_now()
    }
  end

  defp safe_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
    |> String.trim("-")
  end
end
