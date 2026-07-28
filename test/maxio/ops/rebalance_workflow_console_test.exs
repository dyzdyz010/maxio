defmodule Maxio.Ops.RebalanceWorkflowConsoleTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.Rebalance.Job
  alias Maxio.Ops.RebalanceWorkflowConsole

  test "returns not_started evidence when no rebalance jobs exist" do
    result = RebalanceWorkflowConsole.load(%{})

    assert result.status == "not_started"
    assert result.jobs == []
    assert result.selected_job == nil
    assert result.workflow == nil
    assert result.selection_notice == nil
  end

  test "selects the latest job and normalizes only the selected workflow summary" do
    job =
      insert_job!(%{
        "kind" => "rebalance",
        "status" => "planned",
        "data_movement_status" => "not_started",
        "plan_scanned" => 3,
        "plan_bytes" => 1024,
        "progress_moved" => 1,
        "requested_by" => "ops"
      })

    result = RebalanceWorkflowConsole.load(%{})

    assert result.status == "ok"
    assert [%{id: job_id}] = result.jobs
    assert job_id == job.id
    assert result.selected_job.id == job.id
    assert Map.get(result.workflow, :available?) == true
    assert result.workflow.job_id == job.id
    assert result.workflow.phase == "copy_pass"
    assert result.workflow.next_action =~ "maxio.rebalance.run"
    assert result.workflow.next_action =~ job.id
    assert Enum.any?(result.workflow.runtime_topology_rows, &(&1.label == "status"))
  end

  test "blank, invalid, overlong, and unknown job_id requests fall back to latest job" do
    job = insert_job!()

    blank = RebalanceWorkflowConsole.load(%{"job_id" => ""})
    assert blank.selected_job.id == job.id
    assert blank.selection_notice.reason == "blank_job_id"
    assert blank.selection_notice.selected == job.id

    invalid = RebalanceWorkflowConsole.load(%{"job_id" => "../bad"})
    assert invalid.selected_job.id == job.id
    assert invalid.selection_notice.reason == "invalid_job_id"
    assert invalid.selection_notice.selected == job.id

    overlong = RebalanceWorkflowConsole.load(%{"job_id" => String.duplicate("a", 129)})
    assert overlong.selected_job.id == job.id
    assert overlong.selection_notice.reason == "job_id_too_long"

    unknown = RebalanceWorkflowConsole.load(%{"job_id" => "missing-job"})
    assert unknown.selected_job.id == job.id
    assert unknown.selection_notice.reason == "not_found"
  end

  test "marks physical removal as a destructive read-only boundary" do
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

    result = RebalanceWorkflowConsole.load(%{"job_id" => job.id})

    assert result.workflow.phase == "physical_removal"
    assert Map.get(result.workflow, :destructive_next_action?) == true
    assert result.workflow.next_action =~ "maxio.rebalance.physical_remove"
    assert result.workflow.next_action =~ "--confirm-job-id #{job.id}"
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
end
