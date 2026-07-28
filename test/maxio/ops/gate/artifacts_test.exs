defmodule Maxio.Ops.Gate.ArtifactsTest do
  use ExUnit.Case, async: true

  alias Maxio.Ops.Gate.Artifacts

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_ops_gate_artifacts_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  test "lists ops gate artifacts newest first by generated_at", %{dir: dir} do
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
      "ops_evidence_matrix" => %{
        "profile" => "p0_ops_1",
        "covered_rehearsal_kinds" => ["replacement_live_rehearsal"],
        "missing_rehearsal_kinds" => ["scheduler_live_rehearsal"]
      },
      "counts" => %{"total" => 2, "blocked" => 1, "ok" => 1},
      "blockers" => [%{"check" => "replacement_workflow", "reason" => "automation_disabled"}],
      "checks" => [
        %{"id" => "scheduler_status", "task" => "maxio.scheduler.status", "status" => "ok"},
        %{
          "id" => "replacement_workflow",
          "task" => "maxio.replacement.workflow",
          "status" => "blocked",
          "evidence_kind" => "replacement_live_rehearsal",
          "scenario" => "replacement_workflow:audit",
          "artifact_path" => "artifacts/replacement.json",
          "blockers" => [%{"reason" => "automation_disabled"}]
        }
      ]
    })

    [new, old] = Artifacts.list_recent(dir: dir)

    assert new.run_id == "new-run"
    assert new.gate_status == "blocked"
    assert new.ops_evidence_matrix["profile"] == "p0_ops_1"
    assert new.ops_evidence_matrix["missing_rehearsal_kinds"] == ["scheduler_live_rehearsal"]
    assert new.counts.total == 2
    assert [%{reason: "automation_disabled", check: "replacement_workflow"}] = new.blockers
    assert Enum.map(new.checks, & &1.id) == ["scheduler_status", "replacement_workflow"]

    replacement_check = Enum.find(new.checks, &(&1.id == "replacement_workflow"))
    assert replacement_check.evidence_kind == "replacement_live_rehearsal"
    assert replacement_check.scenario == "replacement_workflow:audit"
    assert replacement_check.artifact_path == "artifacts/replacement.json"

    assert old.run_id == "old-run"
    assert old.gate_status == "ok"
  end

  test "normalizes archived parsed output into bounded check evidence summaries", %{dir: dir} do
    write_artifact!(dir, "m8_ops_gate_evidence.json", %{
      "generated_at" => "2026-07-04T10:00:00Z",
      "run_id" => "evidence-run",
      "gate_status" => "blocked",
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
                "scheduled_nodes" => for(index <- 1..8, do: "node-#{index}"),
                "effective_scheduled_nodes" => ["node-1"],
                "healthy_scheduled_nodes" => ["node-1"],
                "missing_expected_nodes" => ["node-2"],
                "lock_loser_nodes" => ["node-2"],
                "lock_loser_count" => 1,
                "blocked_runs" => 2,
                "failed_runs" => 1,
                "next_actions" => [%{"action" => "mix maxio.rebalance.workflow --json"}],
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
            "destructive_next_action?" => false,
            "rebalance_complete?" => false,
            "rebalance_audit" => %{
              "status" => "not_checked",
              "routing_mismatches" => 0,
              "missing_placements" => 1
            }
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
            "index_orphan_shards" => 2,
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
          "id" => %{"bad" => "shape"},
          "task" => "maxio.scheduler.evidence",
          "status" => "error",
          "parsed_output" => "not-json-map"
        }
      ]
    })

    [artifact] = Artifacts.list_recent(dir: dir)

    scheduler = Enum.find(artifact.checks, &(&1.id == "scheduler_evidence"))
    assert scheduler.evidence_summary.kind == "scheduler"
    assert scheduler.evidence_summary.title == "Scheduler Evidence"
    assert field_value(scheduler.evidence_summary, "scheduler") == "rebalance"
    assert field_value(scheduler.evidence_summary, "missing_nodes") == "node-2"
    assert field_value(scheduler.evidence_summary, "rollup_status") == "missing"
    assert field_value(scheduler.evidence_summary, "next_actions") == "1"
    assert field_value(scheduler.evidence_summary, "scheduled_nodes") =~ "node-6"
    refute field_value(scheduler.evidence_summary, "scheduled_nodes") =~ "node-7"

    rebalance = Enum.find(artifact.checks, &(&1.id == "rebalance_workflow"))
    assert rebalance.evidence_summary.kind == "rebalance"
    assert field_value(rebalance.evidence_summary, "next_action") =~ "maxio.rebalance.workflow"
    assert field_value(rebalance.evidence_summary, "missing_placements") == "1"

    scan = Enum.find(artifact.checks, &(&1.id == "scanner_reconcile"))
    assert scan.evidence_summary.kind == "scan"
    assert field_value(scan.evidence_summary, "index_status") == "authority_mismatch"
    assert field_value(scan.evidence_summary, "drive_heal_required") == "1"

    fresh = Enum.find(artifact.checks, &(&1.id == "fresh_drive_heal"))
    assert fresh.evidence_summary.kind == "fresh_drive_heal"
    assert field_value(fresh.evidence_summary, "drives_selected") == "1"
    assert field_value(fresh.evidence_summary, "rebalance_enqueue_status") == "ok"

    malformed = Enum.find(artifact.checks, &String.contains?(&1.id, "\"bad\""))
    assert malformed.evidence_summary == nil
  end

  test "normalizes operator runbook evidence from archived gate artifacts", %{dir: dir} do
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

    [artifact] = Artifacts.list_recent(dir: dir)
    runbook = artifact.operator_runbook

    assert runbook.mutating_boundary == true
    assert runbook_row_value(runbook, "gate-rerun-command") =~ "maxio.ops.gate"
    assert runbook_row_value(runbook, "artifact-path") =~ "m8_ops_gate_runbook.json"
    assert runbook_row_value(runbook, "ops-profile") == "p0_ops_1"
    assert runbook_row_value(runbook, "required-rehearsal-kinds") =~ "replacement_live_rehearsal"
    assert runbook_row_value(runbook, "missing-rehearsal-kinds") == "scheduler_live_rehearsal"
    assert runbook_row_value(runbook, "allow_mutating") == "true"
    assert runbook_row_value(runbook, "fail_on_blocked") == "true"
    assert runbook_row_value(runbook, "fail_on_attention") == "false"

    assert runbook_row_value(runbook, "problem-check-1-rebalance_workflow") =~
             "rebalance.workflow"

    assert runbook_row_value(runbook, "problem-check-2-foreground_scan") =~ "maxio.scan"

    assert Enum.map(runbook.warnings, & &1.id) == [
             "include-foreground-scan",
             "allow-mutating",
             "mutating-check-2-foreground_scan"
           ]
  end

  test "operator runbook tolerates malformed config and check shapes", %{dir: dir} do
    write_artifact!(dir, "m8_ops_gate_malformed_runbook.json", %{
      "generated_at" => "2026-07-04T11:00:00Z",
      "run_id" => "malformed-runbook",
      "gate_status" => "ok",
      "command" => String.duplicate("mix maxio.ops.gate ", 30),
      "config" => ["not", "a", "map"],
      "checks" => "not-a-list"
    })

    [artifact] = Artifacts.list_recent(dir: dir)

    assert artifact.checks == []
    assert artifact.operator_runbook.mutating_boundary == false
    assert runbook_row_value(artifact.operator_runbook, "gate-rerun-command") =~ "mix maxio"

    assert String.length(runbook_row_value(artifact.operator_runbook, "gate-rerun-command")) <=
             160
  end

  test "normalizes bounded artifact provenance without exposing reader path", %{dir: dir} do
    archived_path = "artifacts/m8_ops_gate_provenance.json"

    write_artifact!(dir, "m8_ops_gate_provenance.json", %{
      "generated_at" => "2026-07-04T12:00:00Z",
      "run_id" => "provenance-run",
      "git_sha" => String.duplicate("abcdef", 40),
      "node" => "maxio@node-a",
      "mix_env" => "prod",
      "artifact_path" => archived_path,
      "gate_status" => "attention",
      "schema_version" => 7
    })

    [artifact] = Artifacts.list_recent(dir: dir)
    provenance = artifact.artifact_provenance

    assert provenance.file_name == "m8_ops_gate_provenance.json"
    assert provenance.archived_artifact_path == archived_path
    assert provenance.schema_version == "7"
    assert provenance.node == "maxio@node-a"
    assert provenance.mix_env == "prod"
    assert provenance.generated_at == "2026-07-04T12:00:00Z"
    assert provenance.gate_status == "attention"
    assert is_binary(provenance.size_bytes)
    assert String.length(provenance.git_sha) <= 160
    refute Map.has_key?(provenance, :path)
  end

  test "invalid JSON is visible as an invalid artifact", %{dir: dir} do
    File.write!(Path.join(dir, "m8_ops_gate_bad.json"), "{not-json")

    [artifact] = Artifacts.list_recent(dir: dir)

    assert artifact.status == "invalid"
    assert artifact.gate_status == "invalid"
    assert artifact.error_reason == "json_unparseable"
    assert artifact.checks == []
    assert artifact.artifact_provenance.file_name == "m8_ops_gate_bad.json"
    assert artifact.artifact_provenance.gate_status == "invalid"
    assert artifact.artifact_provenance.error_reason == "json_unparseable"
    assert artifact.artifact_provenance.archived_artifact_path == nil
  end

  test "non ops gate JSON is visible as invalid and non-matching files are ignored", %{dir: dir} do
    File.write!(Path.join(dir, "m8_ops_gate_other.json"), Jason.encode!(%{"hello" => "world"}))
    File.write!(Path.join(dir, "other.json"), Jason.encode!(%{"gate_status" => "ok"}))

    [artifact] = Artifacts.list_recent(dir: dir)

    assert artifact.file_name == "m8_ops_gate_other.json"
    assert artifact.status == "invalid"
    assert artifact.error_reason == "not_ops_gate_artifact"
  end

  test "regular artifact candidate reads are bounded after stat filtering", %{dir: dir} do
    for index <- 1..5 do
      suffix = index |> Integer.to_string() |> String.pad_leading(3, "0")

      write_artifact!(dir, "m8_ops_gate_#{suffix}.json", %{
        "generated_at" => "2026-07-04T09:00:00Z",
        "run_id" => "run-#{suffix}",
        "gate_status" => "ok"
      })
    end

    artifacts = Artifacts.list_recent(dir: dir, max_candidates: 2, limit: 10)

    assert Enum.map(artifacts, & &1.file_name) == [
             "m8_ops_gate_005.json",
             "m8_ops_gate_004.json"
           ]
  end

  test "matching directories do not consume the regular artifact candidate window", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "m8_ops_gate_999.json"))
    File.mkdir_p!(Path.join(dir, "m8_ops_gate_998.json"))

    write_artifact!(dir, "m8_ops_gate_001.json", %{
      "generated_at" => "2026-07-04T09:00:00Z",
      "run_id" => "visible-run",
      "gate_status" => "ok"
    })

    [artifact] = Artifacts.list_recent(dir: dir, max_candidates: 1, limit: 10)

    assert artifact.file_name == "m8_ops_gate_001.json"
    assert artifact.run_id == "visible-run"
  end

  test "matching symlinks do not consume the regular artifact candidate window", %{dir: dir} do
    target = Path.join(dir, "target.json")
    File.write!(target, Jason.encode!(%{"gate_status" => "ok", "checks" => []}))

    link = Path.join(dir, "m8_ops_gate_999.json")

    case File.ln_s(target, link) do
      :ok ->
        write_artifact!(dir, "m8_ops_gate_001.json", %{
          "generated_at" => "2026-07-04T09:00:00Z",
          "run_id" => "visible-run",
          "gate_status" => "ok"
        })

        [artifact] = Artifacts.list_recent(dir: dir, max_candidates: 1, limit: 10)

        assert artifact.file_name == "m8_ops_gate_001.json"
        assert artifact.run_id == "visible-run"

      {:error, _reason} ->
        :ok
    end
  end

  test "unsafe globs cannot escape the artifact directory", %{dir: dir} do
    write_artifact!(dir, "m8_ops_gate_ok.json", %{"run_id" => "inside"})

    outside_name = "m8_ops_gate_outside_#{System.unique_integer([:positive])}.json"
    sibling = Path.join(Path.dirname(dir), outside_name)
    write_artifact!(Path.dirname(dir), outside_name, %{"run_id" => "outside"})

    on_exit(fn -> File.rm(sibling) end)

    assert Artifacts.list_recent(dir: dir, glob: "../m8_ops_gate_*.json") == []
    assert Artifacts.list_recent(dir: dir, glob: Path.join(dir, "m8_ops_gate_*.json")) == []
  end

  test "nested artifacts and traversal-looking file names are ignored", %{dir: dir} do
    nested = Path.join(dir, "nested")
    File.mkdir_p!(nested)
    write_artifact!(nested, "m8_ops_gate_nested.json", %{"run_id" => "nested"})
    write_artifact!(dir, "m8_ops_gate_..json", %{"run_id" => "dotdot"})
    write_artifact!(dir, "m8_ops_gate_ok.json", %{"run_id" => "ok"})

    [artifact] = Artifacts.list_recent(dir: dir)

    assert artifact.file_name == "m8_ops_gate_ok.json"
    assert artifact.run_id == "ok"
  end

  test "matching directories and symlinks are not read as artifacts", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "m8_ops_gate_dir.json"))

    target = Path.join(dir, "target.json")
    File.write!(target, Jason.encode!(%{"gate_status" => "ok", "checks" => []}))

    link = Path.join(dir, "m8_ops_gate_link.json")

    case File.ln_s(target, link) do
      :ok -> assert {:ok, %{type: :symlink}} = File.lstat(link)
      {:error, _reason} -> :ok
    end

    assert Artifacts.list_recent(dir: dir) == []
  end

  test "oversized artifacts are not read", %{dir: dir} do
    write_artifact!(dir, "m8_ops_gate_large.json", %{
      "generated_at" => "2026-07-04T09:00:00Z",
      "run_id" => "large-run",
      "gate_status" => "ok",
      "checks" => []
    })

    [artifact] = Artifacts.list_recent(dir: dir, max_bytes: 8)

    assert artifact.status == "invalid"
    assert artifact.error_reason == "artifact_too_large"
    assert artifact.run_id == nil
  end

  test "missing artifact directory returns an empty list", %{dir: dir} do
    assert Artifacts.list_recent(dir: Path.join(dir, "missing")) == []
  end

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

  defp field_value(summary, label) do
    summary.fields
    |> Enum.find(&(&1.label == label))
    |> Map.fetch!(:value)
  end

  defp runbook_row_value(runbook, id) do
    runbook.rows
    |> Enum.find(&(&1.id == id))
    |> Map.fetch!(:value)
  end
end
