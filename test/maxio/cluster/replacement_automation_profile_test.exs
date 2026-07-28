defmodule Maxio.Cluster.ReplacementAutomationProfileTest do
  use ExUnit.Case, async: true

  alias Maxio.Cluster.Replacement.AutomationProfile

  test "default disabled schedulers block production replacement automation" do
    report =
      AutomationProfile.status(
        fresh_drive_heal_scheduler: [],
        rebalance_scheduler: [],
        scheduler_ledger: []
      )

    assert report.status == :blocked
    refute report.ready?
    assert "fresh_drive_heal_scheduler_disabled" in report.blockers
    assert "fresh_drive_heal_auto_rebalance_disabled" in report.blockers
    assert "rebalance_scheduler_disabled" in report.blockers
    assert "rebalance_auto_rebalance_closure_disabled" in report.blockers
    assert report.next_action == "configure :fresh_drive_heal_scheduler, enabled: true"
  end

  test "ready profile requires heal enqueue rebalance drain closure and ledger evidence" do
    report =
      AutomationProfile.status(
        fresh_drive_heal_scheduler: [
          enabled: true,
          probe_drive_health: true,
          auto_rebalance_after_heal: true
        ],
        rebalance_scheduler: [
          enabled: true,
          auto_source_cleanup: true,
          auto_rebalance_closure: true
        ],
        scheduler_ledger: [enabled: true]
      )

    assert report.status == :ready
    assert report.ready?
    assert report.blockers == []
    assert report.warnings == []
    assert report.next_action == "none"
    assert report.checks.fresh_drive_heal_scheduler.ledger_enabled
    assert report.checks.rebalance_scheduler.ledger_enabled
    assert report.checks.scheduler_evidence == %{required?: false, status: :not_requested}
  end

  test "rehearsal ready opts produce an explicit ready local profile" do
    report = AutomationProfile.status(AutomationProfile.rehearsal_ready_opts())

    assert report.status == :ready
    assert report.ready?
    assert report.blockers == []
    assert report.warnings == []
    assert report.next_action == "none"
    assert report.checks.fresh_drive_heal_scheduler.enabled
    assert report.checks.rebalance_scheduler.enabled
    assert report.checks.fresh_drive_heal_scheduler.ledger_enabled
    assert report.checks.rebalance_scheduler.ledger_enabled
    refute report.checks.fresh_drive_heal_scheduler.run_opts.dry_run
    refute report.checks.rebalance_scheduler.run_opts.dry_run
  end

  test "scheduler evidence is opt-in and not called by default" do
    report =
      AutomationProfile.status(
        ready_opts()
        |> Keyword.put(:scheduler_evidence_fun, fn _opts ->
          flunk("scheduler evidence should not be read unless explicitly requested")
        end)
      )

    assert report.status == :ready
    assert report.checks.scheduler_evidence.status == :not_requested
  end

  test "required scheduler evidence keeps ready profile ready when ledger evidence is ok" do
    report =
      AutomationProfile.status(
        ready_opts()
        |> Keyword.merge(
          require_scheduler_evidence?: true,
          scheduler_evidence_opts: [since_minutes: 5],
          scheduler_evidence_fun: fn opts ->
            assert opts == [since_minutes: 5]
            {:ok, %{status: "ok", blockers: [], warnings: [], schedulers: []}}
          end
        )
      )

    assert report.status == :ready
    assert report.ready?
    assert report.blockers == []
    assert report.checks.scheduler_evidence.required?
    assert report.checks.scheduler_evidence.status == "ok"
  end

  test "required scheduler evidence blocks readiness when scheduled evidence is blocked" do
    report =
      AutomationProfile.status(
        ready_opts()
        |> Keyword.merge(
          require_scheduler_evidence?: true,
          scheduler_evidence_fun: fn _opts ->
            {:ok,
             %{
               status: "blocked",
               blockers: [%{scheduler: "fresh_drive_heal", reason: :scheduler_not_healthy}],
               warnings: []
             }}
          end
        )
      )

    assert report.status == :blocked
    assert "scheduler_evidence_blocked" in report.blockers
    assert report.next_action =~ "mix maxio.scheduler.evidence"

    assert report.checks.scheduler_evidence.report.blockers == [
             %{scheduler: "fresh_drive_heal", reason: "scheduler_not_healthy"}
           ]
  end

  test "required scheduler evidence attention is surfaced without blocking config readiness" do
    report =
      AutomationProfile.status(
        ready_opts()
        |> Keyword.merge(
          require_scheduler_evidence?: true,
          scheduler_evidence_fun: fn _opts ->
            {:ok,
             %{
               status: "attention",
               blockers: [],
               warnings: [%{scheduler: "rebalance", reason: :blocked_runs_seen}]
             }}
          end
        )
      )

    assert report.status == :attention
    assert report.ready?
    assert report.blockers == []
    assert "scheduler_evidence_attention" in report.warnings
    assert report.next_action =~ "scheduler.evidence warnings"
  end

  test "required scheduler evidence fails closed when the ledger check is unavailable" do
    report =
      AutomationProfile.status(
        ready_opts()
        |> Keyword.merge(
          require_scheduler_evidence?: true,
          scheduler_evidence_fun: fn _opts -> {:error, :repo_down} end
        )
      )

    assert report.status == :blocked
    assert "scheduler_evidence_unavailable" in report.blockers
    assert report.checks.scheduler_evidence.reason == ":repo_down"
  end

  test "scheduler-specific ledger overrides are part of readiness" do
    report =
      AutomationProfile.status(
        fresh_drive_heal_scheduler: [
          enabled: true,
          probe_drive_health: true,
          auto_rebalance_after_heal: true,
          scheduler_ledger: [enabled: false]
        ],
        rebalance_scheduler: [
          enabled: true,
          auto_source_cleanup: true,
          auto_rebalance_closure: true
        ],
        scheduler_ledger: [enabled: true]
      )

    assert report.status == :blocked
    assert "fresh_drive_heal_scheduler_ledger_disabled" in report.blockers
    assert report.next_action == "enable scheduler ledger for fresh_drive_heal"
  end

  test "production readiness fails closed on scoped or dry-run scheduler run opts" do
    report =
      AutomationProfile.status(
        fresh_drive_heal_scheduler: [
          enabled: true,
          probe_drive_health: true,
          auto_rebalance_after_heal: true,
          run_opts: [
            dry_run: true,
            bucket: "one-bucket",
            scan_versions: false,
            max_objects: 10
          ]
        ],
        rebalance_scheduler: [
          enabled: true,
          auto_source_cleanup: true,
          auto_rebalance_closure: true,
          run_opts: [dry_run: true]
        ],
        scheduler_ledger: [enabled: true]
      )

    assert report.status == :blocked
    assert "fresh_drive_heal_run_opts_dry_run" in report.blockers
    assert "fresh_drive_heal_run_opts_bucket_scoped" in report.blockers
    assert "fresh_drive_heal_run_opts_current_only" in report.blockers
    assert "fresh_drive_heal_run_opts_max_objects_bounded" in report.blockers
    assert "rebalance_scheduler_run_opts_dry_run" in report.blockers

    assert report.next_action ==
             "remove dry_run from :fresh_drive_heal_scheduler run_opts for production automation"
  end

  test "inline advance without closure verification is surfaced as attention" do
    report =
      AutomationProfile.status(
        fresh_drive_heal_scheduler: [
          enabled: true,
          probe_drive_health: true,
          auto_rebalance_after_heal: true,
          auto_advance_rebalance_after_heal: true,
          rebalance_advance_opts: [auto_rebalance_closure: false]
        ],
        rebalance_scheduler: [
          enabled: true,
          auto_source_cleanup: true,
          auto_rebalance_closure: true
        ],
        scheduler_ledger: [enabled: true]
      )

    assert report.status == :attention
    assert report.ready?
    assert "fresh_drive_heal_inline_advance_closure_disabled" in report.warnings
    assert report.next_action =~ "auto_rebalance_closure"
  end

  defp ready_opts do
    [
      fresh_drive_heal_scheduler: [
        enabled: true,
        probe_drive_health: true,
        auto_rebalance_after_heal: true
      ],
      rebalance_scheduler: [
        enabled: true,
        auto_source_cleanup: true,
        auto_rebalance_closure: true
      ],
      scheduler_ledger: [enabled: true]
    ]
  end
end
