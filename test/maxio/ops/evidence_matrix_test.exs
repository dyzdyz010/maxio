defmodule Maxio.Ops.EvidenceMatrixTest do
  use ExUnit.Case, async: true

  alias Maxio.Ops.EvidenceMatrix

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_ops_evidence_matrix_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  test "classifies valid replacement scheduler and ops gate artifact shapes", %{dir: dir} do
    replacement_path =
      write_json!(dir, "replacement.json", %{
        "evidence_kind" => "replacement_live_rehearsal",
        "bundle_gate" => %{"status" => "ok", "reason" => "replacement_workflow_clear"},
        "replacement_workflow" => %{"phase" => "audit"}
      })

    scheduler_path =
      write_json!(dir, "scheduler.json", %{
        "evidence_kind" => "scheduler_live_rehearsal",
        "scheduler" => "rebalance",
        "evidence_exit_status" => 0,
        "scheduler_evidence" => %{"status" => "ok", "warnings" => [], "blockers" => []}
      })

    ops_gate_path =
      write_json!(dir, "ops_gate.json", %{
        "evidence_kind" => "ops_gate",
        "gate_status" => "ok",
        "checks" => []
      })

    checks =
      EvidenceMatrix.checks(
        [replacement_path, scheduler_path, ops_gate_path],
        ["replacement_live_rehearsal", "scheduler_live_rehearsal", "ops_gate"]
      )

    assert Enum.map(checks, & &1["status"]) == ["ok", "ok", "ok"]

    assert Enum.map(checks, & &1["evidence_kind"]) == [
             "replacement_live_rehearsal",
             "scheduler_live_rehearsal",
             "ops_gate"
           ]

    assert EvidenceMatrix.summary(
             [replacement_path, scheduler_path, ops_gate_path],
             ["replacement_live_rehearsal", "scheduler_live_rehearsal", "ops_gate"],
             checks
           )["missing_rehearsal_kinds"] == []
  end

  test "explicit scheduler kind cannot cover replacement-shaped artifact", %{dir: dir} do
    path =
      write_json!(dir, "spoofed-scheduler.json", %{
        "evidence_kind" => "scheduler_live_rehearsal",
        "bundle_gate" => %{"status" => "ok", "reason" => "replacement_workflow_clear"},
        "replacement_workflow" => %{"phase" => "audit"}
      })

    [artifact_check, missing_check] =
      EvidenceMatrix.checks([path], ["scheduler_live_rehearsal"])

    assert artifact_check["status"] == "error"
    assert artifact_check["evidence_kind"] == nil

    assert [
             %{
               "reason" => "rehearsal_artifact_kind_mismatch",
               "evidence_kind" => "scheduler_live_rehearsal",
               "matching_kinds" => ["replacement_live_rehearsal"]
             }
           ] = artifact_check["blockers"]

    assert missing_check["id"] == "required_rehearsal_kind_scheduler_live_rehearsal"
    assert [%{"reason" => "required_rehearsal_kind_missing"}] = missing_check["blockers"]
  end

  test "non-string explicit kind fails closed even when artifact shape is valid", %{dir: dir} do
    path =
      write_json!(dir, "non-string-kind.json", %{
        "evidence_kind" => 123,
        "scheduler" => "rebalance",
        "evidence_exit_status" => 0,
        "scheduler_evidence" => %{"status" => "ok", "warnings" => [], "blockers" => []}
      })

    [artifact_check, missing_check] =
      EvidenceMatrix.checks([path], ["scheduler_live_rehearsal"])

    assert artifact_check["status"] == "error"

    assert [
             %{
               "reason" => "rehearsal_artifact_schema_invalid",
               "evidence_kind" => "123"
             }
           ] = artifact_check["blockers"]

    assert missing_check["id"] == "required_rehearsal_kind_scheduler_live_rehearsal"
  end

  test "unknown explicit kind fails closed even when artifact shape is valid", %{dir: dir} do
    path =
      write_json!(dir, "unknown-kind.json", %{
        "evidence_kind" => "future_kind",
        "scheduler" => "rebalance",
        "evidence_exit_status" => 0,
        "scheduler_evidence" => %{"status" => "ok", "warnings" => [], "blockers" => []}
      })

    [artifact_check, missing_check] =
      EvidenceMatrix.checks([path], ["scheduler_live_rehearsal"])

    assert artifact_check["status"] == "error"
    assert [%{"reason" => "rehearsal_artifact_unrecognized"}] = artifact_check["blockers"]
    assert missing_check["id"] == "required_rehearsal_kind_scheduler_live_rehearsal"
  end

  test "explicit replacement kind cannot cover scheduler-shaped artifact", %{dir: dir} do
    path =
      write_json!(dir, "spoofed-replacement.json", %{
        "evidence_kind" => "replacement_live_rehearsal",
        "scheduler" => "fresh_drive_heal",
        "evidence_exit_status" => 0,
        "scheduler_evidence" => %{"status" => "ok", "warnings" => [], "blockers" => []}
      })

    [artifact_check, missing_check] =
      EvidenceMatrix.checks([path], ["replacement_live_rehearsal"])

    assert artifact_check["status"] == "error"

    assert [
             %{
               "reason" => "rehearsal_artifact_kind_mismatch",
               "evidence_kind" => "replacement_live_rehearsal",
               "matching_kinds" => ["scheduler_live_rehearsal"]
             }
           ] = artifact_check["blockers"]

    assert missing_check["id"] == "required_rehearsal_kind_replacement_live_rehearsal"
  end

  test "ambiguous multi-shape artifact fails closed instead of covering explicit kind", %{
    dir: dir
  } do
    path =
      write_json!(dir, "ambiguous-kind.json", %{
        "evidence_kind" => "scheduler_live_rehearsal",
        "bundle_gate" => %{"status" => "ok", "reason" => "replacement_workflow_clear"},
        "replacement_workflow" => %{"phase" => "audit"},
        "scheduler" => "rebalance",
        "evidence_exit_status" => 0,
        "scheduler_evidence" => %{"status" => "ok", "warnings" => [], "blockers" => []}
      })

    [artifact_check, missing_check] =
      EvidenceMatrix.checks([path], ["scheduler_live_rehearsal"])

    assert artifact_check["status"] == "error"

    assert [
             %{
               "reason" => "rehearsal_artifact_ambiguous_kind",
               "matching_kinds" => [
                 "replacement_live_rehearsal",
                 "scheduler_live_rehearsal"
               ]
             }
           ] = artifact_check["blockers"]

    assert missing_check["id"] == "required_rehearsal_kind_scheduler_live_rehearsal"
  end

  test "ambiguous multi-shape artifact without explicit kind also fails closed", %{dir: dir} do
    path =
      write_json!(dir, "ambiguous-no-kind.json", %{
        "bundle_gate" => %{"status" => "ok", "reason" => "replacement_workflow_clear"},
        "replacement_workflow" => %{"phase" => "audit"},
        "scheduler" => "rebalance",
        "evidence_exit_status" => 0,
        "scheduler_evidence" => %{"status" => "ok", "warnings" => [], "blockers" => []}
      })

    [artifact_check, missing_replacement, missing_scheduler] =
      EvidenceMatrix.checks(
        [path],
        ["replacement_live_rehearsal", "scheduler_live_rehearsal"]
      )

    assert artifact_check["status"] == "error"

    assert [
             %{
               "reason" => "rehearsal_artifact_ambiguous_kind",
               "matching_kinds" => [
                 "replacement_live_rehearsal",
                 "scheduler_live_rehearsal"
               ]
             }
           ] = artifact_check["blockers"]

    assert missing_replacement["id"] == "required_rehearsal_kind_replacement_live_rehearsal"
    assert missing_scheduler["id"] == "required_rehearsal_kind_scheduler_live_rehearsal"
  end

  test "explicit scheduler kind requires scheduler name and evidence map", %{dir: dir} do
    path =
      write_json!(dir, "invalid-scheduler.json", %{
        "evidence_kind" => "scheduler_live_rehearsal",
        "scheduler" => "",
        "scheduler_evidence" => %{"status" => "ok"}
      })

    [artifact_check, missing_check] =
      EvidenceMatrix.checks([path], ["scheduler_live_rehearsal"])

    assert artifact_check["status"] == "error"

    assert [
             %{
               "reason" => "rehearsal_artifact_schema_invalid",
               "evidence_kind" => "scheduler_live_rehearsal"
             }
           ] = artifact_check["blockers"]

    assert missing_check["id"] == "required_rehearsal_kind_scheduler_live_rehearsal"
  end

  test "explicit ops gate kind requires gate status and checks list", %{dir: dir} do
    path =
      write_json!(dir, "invalid-ops-gate.json", %{
        "evidence_kind" => "ops_gate",
        "gate_status" => "ok",
        "checks" => %{"not" => "a-list"}
      })

    [artifact_check, missing_check] = EvidenceMatrix.checks([path], ["ops_gate"])

    assert artifact_check["status"] == "error"

    assert [
             %{
               "reason" => "rehearsal_artifact_schema_invalid",
               "evidence_kind" => "ops_gate"
             }
           ] = artifact_check["blockers"]

    assert missing_check["id"] == "required_rehearsal_kind_ops_gate"
  end

  test "adversarial scalar fields do not crash accepted artifact shapes", %{dir: dir} do
    path =
      write_json!(dir, "odd-status.json", %{
        "evidence_kind" => "scheduler_live_rehearsal",
        "scheduler" => "rebalance",
        "evidence_exit_status" => 0,
        "scheduler_evidence" => %{
          "status" => %{"unexpected" => true},
          "warnings" => [],
          "blockers" => []
        }
      })

    [artifact_check] = EvidenceMatrix.checks([path], [])

    assert artifact_check["evidence_kind"] == "scheduler_live_rehearsal"
    assert artifact_check["status"] == "blocked"
    assert [%{"reason" => reason}] = artifact_check["blockers"]
    assert String.starts_with?(reason, "scheduler_evidence_status_%{")
  end

  defp write_json!(dir, file_name, data) do
    path = Path.join(dir, file_name)
    File.write!(path, Jason.encode!(data))
    path
  end
end
