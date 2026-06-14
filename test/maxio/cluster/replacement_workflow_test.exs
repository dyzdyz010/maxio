defmodule Maxio.Cluster.ReplacementWorkflowTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.{DriveHealth, Replacement.Workflow}

  setup do
    DriveHealth.reset()

    on_exit(fn -> DriveHealth.reset() end)
  end

  test "default audit is read-only and reports heal-required drive evidence" do
    endpoint = {Node.self(), Path.join(System.tmp_dir!(), "replacement-workflow-audit")}

    _ =
      DriveHealth.record_probe(endpoint, {:error, :unavailable},
        now_ms: 0,
        offline_after_ms: 0,
        set_id: 0,
        set_write_available?: true
      )

    _ = DriveHealth.record_probe(endpoint, :ok, now_ms: 1, offline_after_ms: 0, set_id: 0)

    assert {:ok, report} = Workflow.run([])
    assert report.status == :audit
    assert report.phase == :audit
    refute report.mutating?
    assert report.probe.status == :not_requested
    assert report.heal.status == :not_requested
    assert report.drive_health_before.heal_required == 1
    assert report.drive_health_after.heal_required == 1
    assert report.next_action == "mix maxio.replacement.workflow --heal --rebalance-if-needed"
    assert DriveHealth.heal_required?(endpoint)
  end

  test "explicit workflow delegates same-run rebalance enqueue advance and closure opts" do
    parent = self()

    fresh_scheduler = fn opts ->
      send(parent, {:fresh_scheduler_opts, opts})

      {:ok,
       %{
         status: :ok,
         drives_cleared: 1,
         rebalance_enqueue: %{status: :created, kind: "rebalance", job_id: "job-1"},
         rebalance_advance: %{
           status: :complete,
           job_id: "job-1",
           steps: 3,
           phases: [:copy, :source_cleanup, :rebalance_closure]
         }
       }}
    end

    rebalance_workflow = fn "job-1", opts ->
      send(parent, {:rebalance_workflow_opts, opts})
      {:ok, %{status: "complete", next_action: "none", blockers: [], job_id: "job-1"}}
    end

    latest_job_fun = fn -> flunk("workflow should use the same-run job id") end

    assert {:ok, report} =
             Workflow.run(
               heal: true,
               rebalance_if_needed: true,
               verify_closure: true,
               topology: :fake_topology,
               transport: :fake_transport,
               page_size: 11,
               audit_page_size: 17,
               fresh_scheduler: fresh_scheduler,
               rebalance_workflow: rebalance_workflow,
               latest_job_fun: latest_job_fun,
               snapshot_fun: fn -> [] end
             )

    assert report.status == :ok
    assert report.phase == :rebalance_advanced
    assert report.job_id == "job-1"
    assert report.rebalance_enqueue.status == :created
    assert report.rebalance_advance.status == :complete
    assert report.rebalance_advance.steps == 3
    assert report.next_action == "none"

    assert_receive {:fresh_scheduler_opts, opts}
    assert Keyword.fetch!(opts, :auto_rebalance_after_heal)
    assert Keyword.fetch!(opts, :auto_advance_rebalance_after_heal)
    assert Keyword.fetch!(opts, :rebalance_advance_max_steps) == 3
    assert Keyword.fetch!(opts, :probe_drive_health) == false

    assert Keyword.fetch!(opts, :rebalance_start_opts)[:topology] == :fake_topology
    assert Keyword.fetch!(opts, :rebalance_advance_opts)[:topology] == :fake_topology
    assert Keyword.fetch!(opts, :rebalance_advance_opts)[:transport] == :fake_transport
    assert Keyword.fetch!(opts, :rebalance_advance_opts)[:audit_page_size] == 17
    assert Keyword.fetch!(opts, :rebalance_advance_opts)[:auto_rebalance_closure]

    assert_receive {:rebalance_workflow_opts, workflow_opts}
    assert Keyword.fetch!(workflow_opts, :audit_page_size) == 17
  end

  test "active decommission enqueue skip is blocked and never surfaced as replacement workflow" do
    fresh_scheduler = fn _opts ->
      {:ok,
       %{
         status: :ok,
         drives_cleared: 1,
         rebalance_enqueue: %{
           status: :skipped,
           reason: :active_job_exists,
           job_id: "decommission-job-1",
           kind: "decommission",
           job_status: "complete"
         }
       }}
    end

    assert {:ok, report} =
             Workflow.run(
               heal: true,
               rebalance_if_needed: true,
               fresh_scheduler: fresh_scheduler,
               rebalance_workflow: fn job_id, _opts ->
                 flunk("replacement workflow surfaced unsupported job #{inspect(job_id)}")
               end,
               latest_job_fun: fn ->
                 flunk("replacement workflow should not fall back after heal")
               end,
               snapshot_fun: fn -> [] end
             )

    assert report.status == :blocked
    assert report.phase == :rebalance_enqueued
    assert is_nil(report.job_id)
    assert report.rebalance_workflow.status == :not_found
    assert "rebalance_enqueue_active_job_exists" in report.blockers
    assert report.next_action == "none"
  end

  test "default audit passes through blocked rebalance closure next action" do
    rebalance_workflow = fn "job-1", _opts ->
      {:ok,
       %{
         status: "blocked",
         next_action: "mix maxio.rebalance.start --json",
         blockers: ["routing_mismatch"],
         job_id: "job-1"
       }}
    end

    latest_job_fun = fn -> %{id: "job-1", kind: "rebalance"} end

    assert {:ok, report} =
             Workflow.run(
               rebalance_workflow: rebalance_workflow,
               latest_job_fun: latest_job_fun,
               snapshot_fun: fn -> [] end
             )

    assert report.status == :blocked
    assert report.next_action == "mix maxio.rebalance.start --json"
    assert "routing_mismatch" in report.blockers
  end

  test "mismatched same-run advance job id is blocked and never surfaced as workflow" do
    fresh_scheduler = fn _opts ->
      {:ok,
       %{
         status: :ok,
         drives_cleared: 1,
         rebalance_enqueue: %{status: :created, kind: "rebalance", job_id: "job-1"},
         rebalance_advance: %{status: :complete, job_id: "job-2", steps: 1}
       }}
    end

    assert {:ok, report} =
             Workflow.run(
               heal: true,
               rebalance_if_needed: true,
               advance_steps: 1,
               fresh_scheduler: fresh_scheduler,
               rebalance_workflow: fn job_id, _opts ->
                 flunk("replacement workflow surfaced inconsistent job #{inspect(job_id)}")
               end,
               latest_job_fun: fn ->
                 flunk("replacement workflow should not fall back after heal")
               end,
               snapshot_fun: fn -> [] end
             )

    assert report.status == :blocked
    assert is_nil(report.job_id)
    assert report.rebalance_workflow.status == :not_found
    assert "rebalance_advance_job_mismatch" in report.blockers
    assert report.next_action == "none"
  end

  test "advance and rebalance automation require an explicit heal run" do
    assert {:error, :advance_requires_heal} = Workflow.run(advance_steps: 1)
    assert {:error, :advance_requires_heal} = Workflow.run(verify_closure: true)
    assert {:error, :rebalance_requires_heal} = Workflow.run(rebalance_if_needed: true)
    assert {:error, {:invalid_advance_steps, 0}} = Workflow.run(heal: true, advance_steps: 0)
  end
end
