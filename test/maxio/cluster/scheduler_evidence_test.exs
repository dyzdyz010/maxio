defmodule Maxio.Cluster.SchedulerEvidenceTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.SchedulerRuns

  @t0 ~U[2026-06-14 00:00:00.000000Z]

  test "passes with expected node participation and lock loser evidence" do
    {:ok, _ok} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 1, :second),
        {:ok, %{status: :ok}},
        node: :node_a
      )

    {:ok, _skipped} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 2, :second),
        DateTime.add(@t0, 3, :second),
        {:error, :lock_unavailable},
        node: :node_b
      )

    {:ok, report} =
      SchedulerRuns.evidence_report(
        scheduler: :rebalance,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        expected_interval_ms: 60_000,
        stale_after_ms: 120_000,
        expected_nodes: ["node_a", "node_b"],
        min_effective_nodes: 1,
        require_lock_loser?: true
      )

    assert report.status == "ok"
    assert report.blockers == []
    assert [scheduler] = report.schedulers
    assert scheduler.status == "ok"
    assert scheduler.scheduled_nodes == ["node_a", "node_b"]
    assert scheduler.effective_scheduled_nodes == ["node_a"]
    assert scheduler.lock_loser_nodes == ["node_b"]
    assert scheduler.lock_loser_evidence_met?
  end

  test "blocks when an expected scheduled node is absent without writing ledger rows" do
    {:ok, _ok} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 1, :second),
        {:ok, %{status: :ok}},
        node: :node_a
      )

    before_ids = scheduler_run_ids(:rebalance)

    {:ok, report} =
      SchedulerRuns.evidence_report(
        scheduler: :rebalance,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        expected_interval_ms: 60_000,
        stale_after_ms: 120_000,
        expected_nodes: ["node_a", "node_b"],
        min_effective_nodes: 1
      )

    assert report.status == "blocked"
    assert Enum.any?(report.blockers, &(&1.reason == :missing_expected_nodes))
    assert [scheduler] = report.schedulers
    assert scheduler.missing_expected_nodes == ["node_b"]
    assert scheduler_run_ids(:rebalance) == before_ids
  end

  test "blocks when effective node quorum is not met by lock losers" do
    {:ok, _skipped} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        @t0,
        DateTime.add(@t0, 1, :second),
        {:error, :lock_unavailable},
        node: :node_b
      )

    {:ok, report} =
      SchedulerRuns.evidence_report(
        scheduler: :fresh_drive_heal,
        from: @t0,
        until: DateTime.add(@t0, 30, :second),
        expected_interval_ms: 10_000,
        stale_after_ms: 20_000,
        expected_nodes: ["node_b"],
        min_effective_nodes: 1
      )

    assert report.status == "blocked"
    assert Enum.any?(report.blockers, &(&1.reason == :scheduler_not_healthy))
    assert Enum.any?(report.blockers, &(&1.reason == :min_effective_nodes_not_met))
    assert [scheduler] = report.schedulers
    assert scheduler.scheduled_nodes == ["node_b"]
    assert scheduler.effective_scheduled_nodes == []
  end

  test "blocks when required lock loser evidence is missing" do
    {:ok, _ok} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 1, :second),
        {:ok, %{status: :ok}},
        node: :node_a
      )

    {:ok, _idle} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 2, :second),
        DateTime.add(@t0, 3, :second),
        {:error, :no_runnable_job},
        node: :node_b
      )

    {:ok, report} =
      SchedulerRuns.evidence_report(
        scheduler: :rebalance,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        expected_interval_ms: 60_000,
        stale_after_ms: 120_000,
        expected_nodes: ["node_a", "node_b"],
        min_effective_nodes: 1,
        require_lock_loser?: true
      )

    assert report.status == "blocked"
    assert Enum.any?(report.blockers, &(&1.reason == :missing_lock_loser_evidence))
    assert [scheduler] = report.schedulers
    refute scheduler.lock_loser_evidence_met?
  end

  test "captures blocked next actions with defensive redaction" do
    {:ok, _blocked} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 1, :second),
        {:ok,
         %{
           status: :blocked,
           phase: :rebalance_closure,
           job_id: "job-blocked",
           blockers: [:routing_mismatch],
           next_action: "mix repair --token super-secret --access-key AKIASECRET"
         }},
        node: :node_a
      )

    {:ok, report} =
      SchedulerRuns.evidence_report(
        scheduler: :rebalance,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        expected_interval_ms: 60_000,
        stale_after_ms: 120_000,
        expected_nodes: ["node_a"],
        min_effective_nodes: 1
      )

    assert report.status == "blocked"
    assert [scheduler] = report.schedulers

    assert [%{action: action, job_id: "job-blocked", phase: "rebalance_closure"}] =
             scheduler.next_actions

    assert action =~ "--token [REDACTED]"
    assert action =~ "--access-key [REDACTED]"
    refute action =~ "super-secret"
    refute action =~ "AKIASECRET"
  end

  test "ignores future-dated scheduled rows in evidence windows" do
    report_now = DateTime.add(@t0, 10, :second)

    {:ok, _future} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        DateTime.add(report_now, 60, :second),
        DateTime.add(report_now, 61, :second),
        {:ok, %{status: :ok}},
        node: :future_node
      )

    {:ok, report} =
      SchedulerRuns.evidence_report(
        scheduler: :fresh_drive_heal,
        from: @t0,
        until: report_now,
        expected_interval_ms: 60_000,
        stale_after_ms: 120_000,
        expected_nodes: ["future_node"],
        min_effective_nodes: 1
      )

    assert report.status == "blocked"
    assert [scheduler] = report.schedulers
    assert scheduler.scheduled_nodes == []
    assert scheduler.missing_expected_nodes == ["future_node"]
  end

  test "uses half-open evidence window aligned with rollups" do
    until = DateTime.add(@t0, 60, :second)

    {:ok, _boundary} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        until,
        until,
        {:ok, %{status: :ok}},
        node: :node_at_until
      )

    {:ok, report} =
      SchedulerRuns.evidence_report(
        scheduler: :rebalance,
        from: @t0,
        until: until,
        window_ms: 60_000,
        expected_interval_ms: 60_000,
        stale_after_ms: 120_000,
        expected_nodes: ["node_at_until"],
        min_effective_nodes: 1
      )

    assert report.status == "blocked"
    assert [scheduler] = report.schedulers
    assert scheduler.scheduled_nodes == []
    assert scheduler.missing_expected_nodes == ["node_at_until"]
    assert scheduler.rollup_coverage.windows == 1
  end

  defp scheduler_run_ids(scheduler) do
    [scheduler: scheduler, limit: 20]
    |> SchedulerRuns.list_runs()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end
end
