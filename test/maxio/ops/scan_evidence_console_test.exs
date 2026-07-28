defmodule Maxio.Ops.ScanEvidenceConsoleTest do
  use ExUnit.Case, async: true

  alias Maxio.Ops.ScanEvidenceConsole

  @now ~U[2026-07-05 00:00:00.000000Z]
  @uuid "abcdefabcdefabcdefabcdefabcdefab"
  @previous_uuid "12345678123456781234567812345678"

  test "normalizes scanner authority, usage, drive snapshots, and archived evidence" do
    result =
      ScanEvidenceConsole.load(
        now: @now,
        authoritative_sources: [read: :pg, list: :sidecar, write: :sidecar],
        storage_backend: Maxio.Storage.FS,
        scrubber_config: [
          enabled: true,
          interval_ms: 1_000,
          page_size: 50,
          scan_versions: true,
          reconcile_index: true,
          reconcile_index_dry_run: true,
          drive_health_enabled: true
        ],
        topology_snapshot: %{
          node: :maxio@test,
          runtime_status: :configured,
          topology_hash: "topology-hash",
          set_ids: [0],
          pool_ids: [0]
        },
        buckets: ["alpha", "beta"],
        usage_snapshots: %{
          "alpha" => %{object_count: 2, total_size: 128, scanned_at: @now}
        },
        usage_stale_after_ms: 10_000,
        drive_health_snapshot: [
          %{
            endpoint: {:maxio@n0, "/data/d0"},
            status: :offline,
            failure_count: 2,
            set_id: 0,
            last_reason: :unavailable,
            heal_required?: true,
            identity_heal_required?: true,
            identity_replacement_detected?: true,
            identity_error?: false
          }
        ],
        drive_identity_snapshot: [
          %{
            endpoint: {:maxio@n0, "/data/d0"},
            drive_uuid: @uuid,
            previous_drive_uuid: @previous_uuid,
            generation: 2,
            identity_heal_required?: true,
            replacement_detected?: true,
            set_id: 0,
            endpoint_index: 1,
            last_seen_at: @now
          }
        ],
        gate_artifacts: [scan_artifact()]
      )

    assert result.status == "blocked"
    assert field(result.authority_rows, "authority-write").value == "sidecar"
    assert field(result.authority_rows, "scrubber-reconcile-index").value == "true"
    assert field(result.topology_rows, "topology-status").value == "configured"

    assert Enum.map(result.usage_snapshots.rows, & &1.bucket) == ["alpha", "beta"]
    assert Enum.find(result.usage_snapshots.rows, &(&1.bucket == "alpha")).status == "ok"
    assert Enum.find(result.usage_snapshots.rows, &(&1.bucket == "beta")).status == "missing"

    assert result.drive_health.status == "blocked"
    assert result.drive_health.counts.offline == 1
    assert [drive] = result.drive_health.rows
    assert drive.endpoint =~ "/data/d0"
    assert Map.fetch!(drive, :heal_required?) == "true"

    assert result.drive_identities.status == "attention"
    assert [identity] = result.drive_identities.rows
    assert identity.drive_uuid == "abcdefab...32"
    assert identity.previous_drive_uuid == "12345678...32"
    refute inspect(identity) =~ @uuid
    refute inspect(identity) =~ @previous_uuid

    assert result.archived_evidence.status == "attention"
    assert result.archived_evidence.latest_artifact.file_name == "m8_ops_gate_scan.json"
    assert [archived] = result.archived_evidence.rows
    assert archived.kind == "scan"
    assert archived.task == "maxio.reconcile_index"

    assert Enum.any?(
             archived.fields,
             &(&1.label == "index_status" and &1.value == "authority_mismatch")
           )
  end

  test "marks stale usage and stale archived evidence without inventing health" do
    old = ~U[2026-07-01 00:00:00.000000Z]

    result =
      ScanEvidenceConsole.load(
        now: @now,
        authoritative_sources: [read: :pg, list: :pg, write: :pg],
        storage_backend: Maxio.Storage.FS,
        topology_snapshot: %{runtime_status: :no_topology},
        buckets: ["alpha"],
        usage_snapshots: %{"alpha" => %{object_count: 1, total_size: 1, scanned_at: old}},
        usage_stale_after_ms: 1_000,
        drive_health_snapshot: [],
        drive_identity_snapshot: [],
        gate_artifacts: [
          scan_artifact(%{
            file_name: "m8_ops_gate_old.json",
            generated_at: DateTime.to_iso8601(old)
          })
        ],
        artifact_stale_after_ms: 1_000
      )

    assert result.usage_snapshots.status == "attention"
    assert [%{status: "stale"}] = result.usage_snapshots.rows
    assert result.archived_evidence.status == "attention"
    assert [%{reason: "latest_archived_evidence_stale"}] = result.archived_evidence.warnings
  end

  test "empty snapshots render explicit empty states" do
    result =
      ScanEvidenceConsole.load(
        authoritative_sources: [read: :pg, list: :pg, write: :pg],
        storage_backend: Maxio.Storage.FS,
        topology_snapshot: %{runtime_status: :no_topology},
        buckets: [],
        usage_snapshots: %{},
        drive_health_snapshot: [],
        drive_identity_snapshot: [],
        gate_artifacts: []
      )

    assert result.status == "empty"
    assert result.usage_snapshots.status == "empty"
    assert result.drive_health.status == "empty"
    assert result.drive_identities.status == "empty"
    assert result.archived_evidence.status == "empty"
  end

  test "archived evidence recency is based on latest relevant scan artifact" do
    old = ~U[2026-07-01 00:00:00.000000Z]

    result =
      ScanEvidenceConsole.load(
        now: @now,
        authoritative_sources: [read: :pg, list: :pg, write: :pg],
        storage_backend: Maxio.Storage.FS,
        topology_snapshot: %{runtime_status: :no_topology},
        buckets: [],
        usage_snapshots: %{},
        drive_health_snapshot: [],
        drive_identity_snapshot: [],
        gate_artifacts: [
          %{
            file_name: "m8_ops_gate_unrelated_new.json",
            generated_at: DateTime.to_iso8601(@now),
            checks: []
          },
          scan_artifact(%{
            file_name: "m8_ops_gate_scan_old.json",
            generated_at: DateTime.to_iso8601(old)
          })
        ],
        artifact_stale_after_ms: 1_000
      )

    assert result.archived_evidence.latest_artifact.file_name == "m8_ops_gate_scan_old.json"
    assert [%{reason: "latest_archived_evidence_stale"}] = result.archived_evidence.warnings
    assert result.archived_evidence.status == "attention"
  end

  defp scan_artifact(overrides \\ %{}) do
    Map.merge(
      %{
        file_name: "m8_ops_gate_scan.json",
        run_id: "scan-run",
        generated_at: DateTime.to_iso8601(@now),
        gate_status: "attention",
        checks: [
          %{
            id: "scanner_reconcile",
            task: "maxio.reconcile_index",
            status: "attention",
            evidence_summary: %{
              kind: "scan",
              title: "Scanner Evidence",
              fields: [
                %{label: "index_status", value: "authority_mismatch"},
                %{label: "scanned", value: "12"}
              ]
            }
          }
        ]
      },
      overrides
    )
  end

  defp field(rows, id), do: Enum.find(rows, &(&1.id == id))
end
