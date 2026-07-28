defmodule MaxioWeb.OpsGateLiveTest do
  use MaxioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_ops_gate_live_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    old_dir = Application.get_env(:maxio, :ops_gate_artifacts_dir)
    old_bundle_dir = Application.get_env(:maxio, :ops_rehearsal_bundle_artifacts_dir)
    Application.put_env(:maxio, :ops_gate_artifacts_dir, dir)
    Application.put_env(:maxio, :ops_rehearsal_bundle_artifacts_dir, dir)

    on_exit(fn ->
      restore_env(:ops_gate_artifacts_dir, old_dir)
      restore_env(:ops_rehearsal_bundle_artifacts_dir, old_bundle_dir)
      File.rm_rf!(dir)
    end)

    {:ok, conn: log_in_console(conn), dir: dir}
  end

  test "empty artifact directory shows the read-only ops gate shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ops/gate")

    assert has_element?(view, "#ops-gate")
    assert has_element?(view, "#ops-gate-empty")
    assert has_element?(view, "#ops-gate-evidence-matrix")
    assert has_element?(view, "#ops-gate-evidence-empty")
    assert has_element?(view, "#ops-gate-evidence-sources")
    assert has_element?(view, "#ops-gate-evidence-sources-empty")
    assert has_element?(view, "#ops-gate-check-evidence")
    assert has_element?(view, "#ops-gate-check-evidence-empty")
    assert has_element?(view, "#ops-gate-artifact-provenance")
    assert has_element?(view, "#ops-gate-artifact-provenance-empty")
    refute has_element?(view, "#ops-gate-artifact-recency-warning")
    assert has_element?(view, "#ops-gate-live-bundles")
    assert has_element?(view, "#ops-gate-live-bundles-empty")
    assert has_element?(view, "#ops-gate-runbook")
    assert has_element?(view, "#ops-gate-runbook-empty")
    assert has_element?(view, "#nav-ops-gate")
  end

  test "renders the latest ops gate artifact summary and checks", %{conn: conn, dir: dir} do
    write_artifact!(dir, "m8_ops_gate_old.json", %{
      "generated_at" => "2026-07-04T08:00:00Z",
      "run_id" => "old-run",
      "gate_status" => "ok",
      "counts" => %{"total" => 1, "ok" => 1},
      "checks" => [%{"id" => "scheduler_status", "status" => "ok"}]
    })

    write_artifact!(dir, "m8_ops_gate_new.json", %{
      "generated_at" => "2026-07-04T09:00:00Z",
      "run_id" => "new-run",
      "gate_status" => "blocked",
      "counts" => %{"total" => 2, "ok" => 1, "blocked" => 1},
      "blockers" => [%{"check" => "replacement_workflow", "reason" => "automation_disabled"}],
      "checks" => [
        %{
          "id" => "scheduler_status",
          "task" => "maxio.scheduler.status",
          "status" => "ok",
          "mode" => "read_only",
          "exit_status" => 0,
          "duration_ms" => 12,
          "command" => "maxio.scheduler.status --json"
        },
        %{
          "id" => "replacement_workflow",
          "task" => "maxio.replacement.workflow",
          "status" => "blocked",
          "mode" => "read_only",
          "exit_status" => 0,
          "duration_ms" => 18,
          "command" => "maxio.replacement.workflow --json"
        }
      ]
    })

    {:ok, view, _html} = live(conn, ~p"/ops/gate")

    assert has_element?(view, "#ops-gate-summary")
    assert has_element?(view, "#ops-gate-status", "blocked")
    assert has_element?(view, "#ops-gate-run-id", "new-run")
    assert has_element?(view, "#ops-gate-count-total", "2")
    assert has_element?(view, "#ops-gate-count-blocked", "1")
    assert has_element?(view, "#ops-gate-blockers")
    assert has_element?(view, "#ops-gate-blocker-0", "automation_disabled")
    assert has_element?(view, "#ops-gate-evidence-matrix")
    assert has_element?(view, "#ops-gate-evidence-empty")
    assert has_element?(view, "#ops-gate-evidence-sources-empty")
    assert has_element?(view, "#ops-gate-check-evidence-empty")
    assert has_element?(view, "#ops-gate-artifact-provenance")
    assert has_element?(view, "#ops-gate-artifact-provenance-table")

    assert has_element?(
             view,
             "#ops-gate-artifact-provenance-row-file-name",
             "m8_ops_gate_new.json"
           )

    assert has_element?(view, "#ops-gate-artifact-provenance-row-gate-status", "blocked")
    refute has_element?(view, "#ops-gate-artifact-recency-warning")
    refute has_element?(view, "#ops-gate-artifact-provenance button")
    refute has_element?(view, "#ops-gate-artifact-provenance form")
    assert has_element?(view, "#ops-gate-checks")
    assert has_element?(view, "#ops-gate-check-scheduler_status")
    assert has_element?(view, "#ops-gate-check-replacement_workflow")
    assert has_element?(view, "#ops-gate-artifact-m8_ops_gate_new-json")
    assert has_element?(view, "#ops-gate-artifact-m8_ops_gate_old-json")
  end

  test "renders related P0 live rehearsal bundle evidence without actions", %{
    conn: conn,
    dir: dir
  } do
    gate_path = Path.join(dir, "m8_ops_gate_bundle_gate.json")

    write_artifact!(dir, "m8_ops_gate_bundle_gate.json", %{
      "generated_at" => "2026-07-04T10:00:00Z",
      "run_id" => "bundle-gate-run",
      "artifact_path" => gate_path,
      "gate_status" => "blocked",
      "counts" => %{"total" => 2, "ok" => 1, "blocked" => 1}
    })

    write_bundle!(dir, "m8_p0_ops_live_rehearsal_bundle_gate_bundle.json", %{
      "generated_at" => "2026-07-04T10:01:00Z",
      "run_id" => "bundle-run",
      "replacement_mode" => "live",
      "scheduler_mode" => "enabled_rehearsal",
      "scheduler" => "all",
      "artifact_paths" => %{
        "replacement_live_rehearsal" => Path.join(dir, "replacement.json"),
        "scheduler_live_rehearsal" => Path.join(dir, "scheduler.json"),
        "ops_gate" => gate_path,
        "bundle" => Path.join(dir, "m8_p0_ops_live_rehearsal_bundle_gate_bundle.json")
      },
      "commands" => %{
        "replacement_live_rehearsal" => "mix maxio.replacement.workflow --json",
        "scheduler_live_rehearsal" => "mix maxio.scheduler.enabled_rehearsal --json",
        "ops_gate" => "mix maxio.ops.gate --ops-profile p0_ops_1"
      },
      "child_results" => %{
        "replacement_live_rehearsal" => %{
          "status" => "ok",
          "exit_code" => 0,
          "gate_status" => "ok"
        },
        "scheduler_live_rehearsal" => %{
          "status" => "ok",
          "exit_code" => 0,
          "gate_status" => "ok"
        },
        "ops_gate" => %{
          "status" => "error",
          "exit_code" => 1,
          "gate_status" => "blocked"
        }
      },
      "gate_status" => "blocked"
    })

    {:ok, view, _html} = live(conn, ~p"/ops/gate")

    assert has_element?(view, "#ops-gate-live-bundles")
    assert has_element?(view, "#ops-gate-live-bundles-table")

    assert has_element?(
             view,
             "#ops-gate-live-bundle-m8_p0_ops_live_rehearsal_bundle_gate_bundle-json",
             "bundle-run"
           )

    assert has_element?(view, "#ops-gate-related-bundle")
    assert has_element?(view, "#ops-gate-related-bundle-summary-run-id", "bundle-run")
    assert has_element?(view, "#ops-gate-related-bundle-summary-replacement-mode", "live")

    assert has_element?(
             view,
             "#ops-gate-related-bundle-summary-scheduler-mode",
             "enabled_rehearsal"
           )

    assert has_element?(view, "#ops-gate-related-bundle-boundary")
    assert has_element?(view, "#ops-gate-related-bundle-warning-replacement-live", "live")

    assert has_element?(
             view,
             "#ops-gate-related-bundle-warning-scheduler-enabled",
             "enabled_rehearsal"
           )

    assert has_element?(view, "#ops-gate-related-bundle-results")
    assert has_element?(view, "#ops-gate-related-bundle-child-replacement_live_rehearsal", "ok")
    assert has_element?(view, "#ops-gate-related-bundle-child-scheduler_live_rehearsal", "ok")
    assert has_element?(view, "#ops-gate-related-bundle-child-ops_gate", "blocked")
    assert has_element?(view, "#ops-gate-related-bundle-child-ops_gate", "maxio.ops.gate")

    refute has_element?(view, "#ops-gate-live-bundles button")
    refute has_element?(view, "#ops-gate-live-bundles form")
  end

  test "bundle table renders invalid bundle artifacts without crashing", %{conn: conn, dir: dir} do
    File.write!(Path.join(dir, "m8_p0_ops_live_rehearsal_bad_bundle.json"), "{not-json")

    {:ok, view, _html} = live(conn, ~p"/ops/gate")

    assert has_element?(view, "#ops-gate-empty")
    assert has_element?(view, "#ops-gate-live-bundles-table")

    assert has_element?(
             view,
             "#ops-gate-live-bundle-m8_p0_ops_live_rehearsal_bad_bundle-json",
             "invalid"
           )

    assert has_element?(view, "#ops-gate-related-bundle-empty")
  end

  test "renders archived operator runbook evidence without actions", %{conn: conn, dir: dir} do
    write_artifact!(dir, "m8_ops_gate_runbook.json", %{
      "generated_at" => "2026-07-04T11:00:00Z",
      "run_id" => "runbook-run",
      "gate_status" => "blocked",
      "command" =>
        "mix maxio.ops.gate --json --ops-profile p0_ops_1 --include-foreground-scan --allow-mutating",
      "config" => %{
        "ops_profile" => "p0_ops_1",
        "required_rehearsal_kinds" => [
          "replacement_live_rehearsal",
          "scheduler_live_rehearsal"
        ],
        "allow_mutating" => true,
        "include_foreground_scan" => true,
        "fail_on_blocked" => true,
        "fail_on_attention" => false,
        "strict" => false
      },
      "ops_evidence_matrix" => %{
        "profile" => "p0_ops_1",
        "missing_rehearsal_kinds" => ["scheduler_live_rehearsal"]
      },
      "counts" => %{"total" => 3, "ok" => 1, "attention" => 1, "blocked" => 1},
      "checks" => [
        %{
          "id" => "scheduler_status",
          "task" => "maxio.scheduler.status",
          "mode" => "read_only",
          "status" => "ok",
          "command" => "maxio.scheduler.status --json"
        },
        %{
          "id" => "rebalance_workflow",
          "task" => "maxio.rebalance.workflow",
          "mode" => "read_only",
          "status" => "blocked",
          "command" => "maxio.rebalance.workflow --json"
        },
        %{
          "id" => "foreground_scan",
          "task" => "maxio.scan",
          "mode" => "mutating",
          "status" => "attention",
          "command" => "maxio.scan --json"
        }
      ]
    })

    {:ok, view, _html} = live(conn, ~p"/ops/gate")

    assert has_element?(view, "#ops-gate-runbook")
    assert has_element?(view, "#ops-gate-runbook-table")
    refute has_element?(view, "#ops-gate-runbook-empty")
    assert has_element?(view, "#ops-gate-runbook-row-gate-rerun-command", "maxio.ops.gate")
    assert has_element?(view, "#ops-gate-runbook-row-ops-profile", "p0_ops_1")

    assert has_element?(
             view,
             "#ops-gate-runbook-row-missing-rehearsal-kinds",
             "scheduler_live_rehearsal"
           )

    assert has_element?(
             view,
             "#ops-gate-runbook-row-problem-check-1-rebalance_workflow",
             "maxio.rebalance.workflow --json"
           )

    assert has_element?(
             view,
             "#ops-gate-runbook-row-problem-check-2-foreground_scan",
             "maxio.scan --json"
           )

    assert has_element?(view, "#ops-gate-runbook-mutating-boundary")
    assert has_element?(view, "#ops-gate-runbook-boundary-allow-mutating", "allow_mutating")
    assert has_element?(view, "#ops-gate-runbook-boundary-include-foreground-scan", "true")

    assert has_element?(
             view,
             "#ops-gate-runbook-boundary-mutating-check-2-foreground_scan",
             "foreground_scan"
           )

    refute has_element?(view, "#ops-gate-runbook button")
    refute has_element?(view, "#ops-gate-runbook form")
  end

  test "renders archived parsed check evidence drilldown", %{conn: conn, dir: dir} do
    write_artifact!(dir, "m8_ops_gate_check_evidence.json", %{
      "generated_at" => "2026-07-04T10:00:00Z",
      "run_id" => "check-evidence-run",
      "gate_status" => "attention",
      "counts" => %{"total" => 4, "ok" => 1, "attention" => 2, "blocked" => 1},
      "checks" => [
        %{
          "id" => "scheduler_evidence",
          "task" => "maxio.scheduler.evidence",
          "status" => "blocked",
          "parsed_output" => %{
            "status" => "blocked",
            "schedulers" => [
              %{
                "scheduler" => "rebalance",
                "status" => "blocked",
                "scheduled_nodes" => ["node-a", "node-b"],
                "effective_scheduled_nodes" => ["node-a"],
                "missing_expected_nodes" => ["node-b"],
                "rollup_coverage" => %{"status" => "missing", "windows" => 2}
              }
            ]
          }
        },
        %{
          "id" => "rebalance_workflow",
          "task" => "maxio.rebalance.workflow",
          "status" => "attention",
          "parsed_output" => %{
            "status" => "in_progress",
            "gate_status" => "attention",
            "phase" => "copy_pass",
            "next_action" => "mix maxio.rebalance.workflow --job-id job-1 --json",
            "rebalance_audit" => %{"status" => "not_checked", "missing_placements" => 1}
          }
        },
        %{
          "id" => "scanner_reconcile",
          "task" => "maxio.reconcile_index",
          "status" => "attention",
          "parsed_output" => %{
            "status" => "attention",
            "gate_status" => "attention",
            "index_status" => "authority_mismatch",
            "scanned" => 12,
            "drive_heal_required" => 1
          }
        },
        %{
          "id" => "fresh_drive_heal",
          "task" => "maxio.heal.fresh_drives",
          "status" => "ok",
          "parsed_output" => %{
            "status" => "ok",
            "gate_status" => "ok",
            "dry_run" => true,
            "backend" => "distributed",
            "drives_considered" => 2,
            "drives_selected" => 1,
            "healed_objects" => 3,
            "rebalance_enqueue" => %{"status" => "ok", "reason" => "job_enqueued"}
          }
        },
        %{
          "id" => "malformed_output",
          "task" => "maxio.scheduler.evidence",
          "status" => "error",
          "parsed_output" => "not-json-map"
        }
      ]
    })

    {:ok, view, _html} = live(conn, ~p"/ops/gate")

    assert has_element?(view, "#ops-gate-check-evidence")
    assert has_element?(view, "#ops-gate-check-evidence-table")
    refute has_element?(view, "#ops-gate-check-evidence-empty")

    assert has_element?(
             view,
             "#ops-gate-check-evidence-field-0-scheduler_evidence-scheduler-1-scheduler",
             "rebalance"
           )

    assert has_element?(
             view,
             "#ops-gate-check-evidence-kind-0-scheduler_evidence-scheduler-1-scheduler",
             "Scheduler Evidence"
           )

    assert has_element?(
             view,
             "#ops-gate-check-evidence-field-1-rebalance_workflow-rebalance-3-next_action",
             "mix maxio.rebalance.workflow --job-id job-1 --json"
           )

    assert has_element?(
             view,
             "#ops-gate-check-evidence-field-2-scanner_reconcile-scan-2-index_status",
             "authority_mismatch"
           )

    assert has_element?(
             view,
             "#ops-gate-check-evidence-field-3-fresh_drive_heal-fresh_drive_heal-5-drives_selected",
             "1"
           )

    refute has_element?(view, "#ops-gate-check-evidence-field-4-malformed_output")
  end

  test "matrix metadata without rehearsal kinds renders an explicit empty state", %{
    conn: conn,
    dir: dir
  } do
    write_artifact!(dir, "m8_ops_gate_profile_only.json", %{
      "generated_at" => "2026-07-04T10:00:00Z",
      "run_id" => "profile-only",
      "gate_status" => "ok",
      "ops_evidence_matrix" => %{
        "profile" => "p0_ops_1",
        "read_only" => true,
        "artifact_count" => 0
      },
      "counts" => %{"total" => 1, "ok" => 1}
    })

    {:ok, view, _html} = live(conn, ~p"/ops/gate")

    assert has_element?(view, "#ops-gate-evidence-profile", "profile: p0_ops_1")
    assert has_element?(view, "#ops-gate-evidence-empty")
    assert has_element?(view, "#ops-gate-evidence-sources-empty")
    refute has_element?(view, "#ops-gate-evidence-table")
  end

  test "evidence source rows fall back to scenario and path for legacy checks", %{
    conn: conn,
    dir: dir
  } do
    write_artifact!(dir, "m8_ops_gate_legacy_source.json", %{
      "generated_at" => "2026-07-04T10:00:00Z",
      "run_id" => "legacy-source",
      "gate_status" => "ok",
      "counts" => %{"total" => 1, "ok" => 1},
      "checks" => [
        %{
          "id" => "",
          "task" => "",
          "mode" => "read_only_artifact",
          "status" => "ok",
          "scenario" => "legacy:audit",
          "artifact_path" => "artifacts/legacy.json"
        }
      ]
    })

    {:ok, view, _html} = live(conn, ~p"/ops/gate")

    assert has_element?(view, "#ops-gate-evidence-sources-table")

    assert has_element?(
             view,
             "#ops-gate-evidence-source-legacy-audit-artifacts-legacy-json",
             "legacy:audit"
           )

    assert has_element?(
             view,
             "#ops-gate-evidence-source-path-legacy-audit-artifacts-legacy-json",
             "artifacts/legacy.json"
           )
  end

  test "blank source metadata does not create fallback evidence rows", %{conn: conn, dir: dir} do
    write_artifact!(dir, "m8_ops_gate_blank_source.json", %{
      "generated_at" => "2026-07-04T10:00:00Z",
      "run_id" => "blank-source",
      "gate_status" => "ok",
      "counts" => %{"total" => 2, "ok" => 2},
      "checks" => [
        %{
          "id" => "",
          "task" => "",
          "mode" => "read_only_artifact",
          "status" => "ok",
          "evidence_kind" => "",
          "scenario" => "",
          "artifact_path" => ""
        },
        %{
          "id" => "scheduler_status",
          "task" => "maxio.scheduler.status",
          "mode" => "read_only",
          "status" => "ok"
        }
      ]
    })

    {:ok, view, _html} = live(conn, ~p"/ops/gate")

    assert has_element?(view, "#ops-gate-evidence-sources-empty")
    refute has_element?(view, "#ops-gate-evidence-sources-table")
    refute has_element?(view, "#ops-gate-evidence-source-unknown-source")
  end

  test "renders ops evidence matrix coverage and per-kind issues", %{conn: conn, dir: dir} do
    write_artifact!(dir, "m8_ops_gate_matrix.json", %{
      "generated_at" => "2026-07-04T10:00:00Z",
      "run_id" => "matrix-run",
      "gate_status" => "blocked",
      "ops_evidence_matrix" => %{
        "profile" => "p0_ops_1",
        "read_only" => true,
        "artifact_count" => 1,
        "required_rehearsal_kinds" => [
          "replacement_live_rehearsal",
          "scheduler_live_rehearsal"
        ],
        "covered_rehearsal_kinds" => ["replacement_live_rehearsal"],
        "missing_rehearsal_kinds" => ["scheduler_live_rehearsal"]
      },
      "counts" => %{"total" => 2, "ok" => 1, "blocked" => 1},
      "checks" => [
        %{
          "id" => "rehearsal_artifact_1",
          "task" => "artifact:replacement_live_rehearsal",
          "mode" => "read_only_artifact",
          "status" => "ok",
          "evidence_kind" => "replacement_live_rehearsal",
          "scenario" => "replacement_workflow:audit",
          "artifact_path" => "artifacts/replacement.json",
          "warnings" => [%{"reason" => "source_cleanup_pending"}]
        },
        %{
          "id" => "required_rehearsal_kind_scheduler_live_rehearsal",
          "task" => "artifact:scheduler_live_rehearsal",
          "mode" => "read_only_artifact",
          "status" => "blocked",
          "blockers" => [
            %{
              "kind" => "scheduler_live_rehearsal",
              "reason" => "required_rehearsal_kind_missing"
            }
          ]
        }
      ]
    })

    {:ok, view, _html} = live(conn, ~p"/ops/gate")

    assert has_element?(view, "#ops-gate-evidence-matrix")
    refute has_element?(view, "#ops-gate-evidence-empty")
    assert has_element?(view, "#ops-gate-evidence-profile", "profile: p0_ops_1")
    assert has_element?(view, "#ops-gate-evidence-profile", "artifacts: 1")
    assert has_element?(view, "#ops-gate-evidence-profile", "read-only: yes")
    assert has_element?(view, "#ops-gate-required-covered", "1")
    assert has_element?(view, "#ops-gate-required-missing", "1")
    assert has_element?(view, "#ops-gate-required-total", "2")

    assert has_element?(view, "#ops-gate-kind-row-replacement_live_rehearsal")
    assert has_element?(view, "#ops-gate-kind-status-replacement_live_rehearsal", "ok")
    assert has_element?(view, "#ops-gate-kind-warnings-replacement_live_rehearsal", "1")
    assert has_element?(view, "#ops-gate-evidence-sources")
    assert has_element?(view, "#ops-gate-evidence-sources-table")

    assert has_element?(
             view,
             "#ops-gate-evidence-source-replacement_live_rehearsal-rehearsal_artifact_1-artifact-replacement_live_rehearsal",
             "replacement_live_rehearsal"
           )

    assert has_element?(
             view,
             "#ops-gate-evidence-source-scenario-replacement_live_rehearsal-rehearsal_artifact_1-artifact-replacement_live_rehearsal",
             "replacement_workflow:audit"
           )

    assert has_element?(
             view,
             "#ops-gate-evidence-source-path-replacement_live_rehearsal-rehearsal_artifact_1-artifact-replacement_live_rehearsal",
             "artifacts/replacement.json"
           )

    assert has_element?(
             view,
             "#ops-gate-kind-warning-replacement_live_rehearsal-0",
             "source_cleanup_pending"
           )

    assert has_element?(view, "#ops-gate-kind-row-scheduler_live_rehearsal")
    assert has_element?(view, "#ops-gate-kind-status-scheduler_live_rehearsal", "blocked")
    assert has_element?(view, "#ops-gate-kind-blockers-scheduler_live_rehearsal", "1")

    assert has_element?(
             view,
             "#ops-gate-evidence-source-status-scheduler_live_rehearsal-required_rehearsal_kind_scheduler_live_rehearsal-artifact-scheduler_live_rehearsal",
             "no_source"
           )

    assert has_element?(
             view,
             "#ops-gate-kind-blocker-scheduler_live_rehearsal-0",
             "required_rehearsal_kind_missing"
           )
  end

  test "query param selects a known artifact by file name", %{conn: conn, dir: dir} do
    write_artifact!(dir, "m8_ops_gate_old.json", %{
      "generated_at" => "2026-07-04T08:00:00Z",
      "run_id" => "old-run",
      "gate_status" => "attention",
      "ops_evidence_matrix" => %{
        "profile" => "p0_ops_1",
        "artifact_count" => 1,
        "required_rehearsal_kinds" => ["replacement_live_rehearsal"],
        "covered_rehearsal_kinds" => ["replacement_live_rehearsal"],
        "missing_rehearsal_kinds" => []
      },
      "counts" => %{"total" => 1, "attention" => 1}
    })

    write_artifact!(dir, "m8_ops_gate_new.json", %{
      "generated_at" => "2026-07-04T09:00:00Z",
      "run_id" => "new-run",
      "ops_evidence_matrix" => %{
        "profile" => "default",
        "artifact_count" => 0,
        "required_rehearsal_kinds" => [],
        "covered_rehearsal_kinds" => [],
        "missing_rehearsal_kinds" => []
      },
      "gate_status" => "ok",
      "counts" => %{"total" => 1, "ok" => 1}
    })

    {:ok, view, _html} = live(conn, ~p"/ops/gate?#{%{artifact: "m8_ops_gate_old.json"}}")

    assert has_element?(view, "#ops-gate-run-id", "old-run")
    assert has_element?(view, "#ops-gate-status", "attention")
    assert has_element?(view, "#ops-gate-evidence-profile", "profile: p0_ops_1")
    assert has_element?(view, "#ops-gate-required-covered", "1")
    assert has_element?(view, "#ops-gate-kind-row-replacement_live_rehearsal")

    assert has_element?(
             view,
             "#ops-gate-artifact-provenance-row-file-name",
             "m8_ops_gate_old.json"
           )

    assert has_element?(view, "#ops-gate-artifact-recency-warning", "m8_ops_gate_old.json")
    assert has_element?(view, "#ops-gate-artifact-recency-warning", "m8_ops_gate_new.json")
    assert has_element?(view, "#ops-gate-artifact-recency-warning", "2026-07-04T09:00:00Z")
    assert has_element?(view, "#ops-gate-artifact-recency-warning", "ok")
    refute has_element?(view, "#ops-gate-selection-warning")
  end

  test "unknown artifact query selects latest artifact and shows selection warning", %{
    conn: conn,
    dir: dir
  } do
    write_artifact!(dir, "m8_ops_gate_old.json", %{
      "generated_at" => "2026-07-04T08:00:00Z",
      "run_id" => "old-run",
      "gate_status" => "attention",
      "counts" => %{"total" => 1, "attention" => 1}
    })

    write_artifact!(dir, "m8_ops_gate_new.json", %{
      "generated_at" => "2026-07-04T09:00:00Z",
      "run_id" => "new-run",
      "gate_status" => "ok",
      "counts" => %{"total" => 1, "ok" => 1}
    })

    {:ok, view, _html} = live(conn, ~p"/ops/gate?#{%{artifact: "does-not-exist.json"}}")

    assert has_element?(view, "#ops-gate-run-id", "new-run")
    assert has_element?(view, "#ops-gate-selection-warning", "does-not-exist.json")
    assert has_element?(view, "#ops-gate-selection-warning", "not_found")
    assert has_element?(view, "#ops-gate-selection-warning", "m8_ops_gate_new.json")
  end

  test "unsafe artifact query falls back to latest artifact and shows selection warning", %{
    conn: conn,
    dir: dir
  } do
    write_artifact!(dir, "m8_ops_gate_new.json", %{
      "generated_at" => "2026-07-04T09:00:00Z",
      "run_id" => "new-run",
      "gate_status" => "ok",
      "counts" => %{"total" => 1, "ok" => 1}
    })

    {:ok, view, _html} = live(conn, ~p"/ops/gate?#{%{artifact: "../outside.json"}}")

    assert has_element?(view, "#ops-gate-run-id", "new-run")
    assert has_element?(view, "#ops-gate-selection-warning", "../outside.json")
    assert has_element?(view, "#ops-gate-selection-warning", "invalid_parameter")
    assert has_element?(view, "#ops-gate-selection-warning", "m8_ops_gate_new.json")
  end

  test "invalid artifact query shapes fall back to latest artifact with selection warning", %{
    conn: conn,
    dir: dir
  } do
    write_artifact!(dir, "m8_ops_gate_new.json", %{
      "generated_at" => "2026-07-04T09:00:00Z",
      "run_id" => "new-run",
      "gate_status" => "ok",
      "counts" => %{"total" => 1, "ok" => 1}
    })

    invalid_queries = [
      {%{artifact: " \t "}, nil},
      {%{artifact: String.duplicate("a", 256)}, String.duplicate("a", 128)},
      {%{artifact: "dir\\file.json"}, "dir\\file.json"},
      {%{artifact: %{"foo" => "bar"}}, "foo"}
    ]

    for {query, requested_text} <- invalid_queries do
      {:ok, view, _html} = live(conn, ~p"/ops/gate?#{query}")

      assert has_element?(view, "#ops-gate-run-id", "new-run")
      assert has_element?(view, "#ops-gate-selection-warning", "invalid_parameter")
      assert has_element?(view, "#ops-gate-selection-warning", "m8_ops_gate_new.json")

      if requested_text do
        assert has_element?(view, "#ops-gate-selection-warning", requested_text)
      end
    end
  end

  test "invalid artifact query without artifacts shows warning instead of crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ops/gate?#{%{artifact: %{"foo" => "bar"}}}")

    assert has_element?(view, "#ops-gate-empty")
    assert has_element?(view, "#ops-gate-selection-warning", "invalid_parameter")
    assert has_element?(view, "#ops-gate-selection-warning", "foo")
    assert has_element?(view, "#ops-gate-selection-warning", "n/a")
  end

  test "bad artifact JSON renders as an invalid artifact instead of crashing", %{
    conn: conn,
    dir: dir
  } do
    File.write!(Path.join(dir, "m8_ops_gate_bad.json"), "{not-json")

    {:ok, view, _html} = live(conn, ~p"/ops/gate")

    assert has_element?(view, "#ops-gate-summary")
    assert has_element?(view, "#ops-gate-status", "invalid")
    assert has_element?(view, "#ops-gate-invalid", "json_unparseable")
    assert has_element?(view, "#ops-gate-artifact-provenance-table")

    assert has_element?(
             view,
             "#ops-gate-artifact-provenance-row-file-name",
             "m8_ops_gate_bad.json"
           )

    assert has_element?(view, "#ops-gate-artifact-provenance-row-gate-status", "invalid")

    assert has_element?(
             view,
             "#ops-gate-artifact-provenance-row-error-reason",
             "json_unparseable"
           )

    assert has_element?(view, "#ops-gate-checks-empty")
  end

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)

  defp write_artifact!(dir, file_name, attrs) do
    artifact =
      Map.merge(
        %{
          "schema_version" => 1,
          "generated_at" => "2026-07-04T08:00:00Z",
          "run_id" => "test-run",
          "git_sha" => "test-sha",
          "node" => "nonode@nohost",
          "mix_env" => "test",
          "command" => "mix maxio.ops.gate --json",
          "artifact_path" => Path.join(dir, file_name),
          "gate_status" => "ok",
          "counts" => %{"total" => 0, "ok" => 0, "attention" => 0, "blocked" => 0, "error" => 0},
          "blockers" => [],
          "warnings" => [],
          "checks" => []
        },
        attrs
      )

    File.write!(Path.join(dir, file_name), Jason.encode!(artifact))
  end

  defp write_bundle!(dir, file_name, attrs) do
    artifact =
      Map.merge(
        %{
          "schema_version" => 1,
          "evidence_kind" => "p0_ops_live_rehearsal_bundle",
          "scenario" => "p0_ops_1_rehearsal_bundle",
          "generated_at" => "2026-07-04T08:00:00Z",
          "run_id" => "test-bundle",
          "git_sha" => "test-sha",
          "node" => "nonode@nohost",
          "mix_env" => "test",
          "replacement_mode" => "dry_run",
          "replacement_rehearsal_ready?" => true,
          "scheduler_mode" => "read_only",
          "scheduler" => "rebalance",
          "artifact_paths" => %{
            "replacement_live_rehearsal" => Path.join(dir, "replacement.json"),
            "scheduler_live_rehearsal" => Path.join(dir, "scheduler.json"),
            "ops_gate" => Path.join(dir, "m8_ops_gate_test.json"),
            "bundle" => Path.join(dir, file_name)
          },
          "commands" => %{},
          "child_results" => %{},
          "gate_status" => "ok"
        },
        attrs
      )

    File.write!(Path.join(dir, file_name), Jason.encode!(artifact))
  end
end
