defmodule Maxio.Ops.RecoveryReadinessConsoleTest do
  use ExUnit.Case, async: true

  alias Maxio.Ops.RecoveryReadinessConsole

  @now ~U[2026-07-05 01:00:00Z]

  test "aggregates ready recovery evidence" do
    console = RecoveryReadinessConsole.load(ready_opts())

    assert console.status == "ok"
    assert console.artifact_evidence.status == "ok"
    assert console.operational_evidence.status == "ok"
    assert console.blockers.rows == []
    assert console.warnings.rows == []
    assert length(console.recovery_axes.rows) == 8
    assert Enum.any?(console.artifact_evidence.rows, &(&1.run_id == "bundle-ready"))
    assert Enum.any?(console.artifact_evidence.rows, &(&1.run_id == "gate-ready"))
    assert Enum.any?(console.operational_evidence.rows, &(&1.source == "Cluster Health"))
  end

  test "artifact readiness fields override parse success status" do
    console =
      RecoveryReadinessConsole.load(
        ready_opts(
          rehearsal_bundles_fun: fn _opts ->
            [
              %{
                run_id: "bundle-failed-child",
                status: "ok",
                gate_status: "ok",
                generated_at: @now,
                replacement_rehearsal_ready?: true,
                child_results: [
                  %{id: "replacement_live_rehearsal", status: "ok"},
                  %{id: "scheduler_live_rehearsal", status: "ok"},
                  %{id: "ops_gate", status: "ok", gate_status: "failed"}
                ],
                boundary_warnings: []
              }
            ]
          end,
          gate_artifacts_fun: fn _opts ->
            [
              %{run_id: "gate-failed", status: "ok", gate_status: "failed", generated_at: @now},
              %{
                run_id: "gate-blocker",
                status: "ok",
                gate_status: "ok",
                generated_at: @now,
                blockers: [%{reason: "gate_blocked", detail: "gate artifact blocker"}]
              },
              %{
                run_id: "gate-warning",
                status: "ok",
                gate_status: "ok",
                generated_at: @now,
                warnings: [%{reason: "gate_warning", detail: "gate artifact warning"}]
              }
            ]
          end
        )
      )

    assert console.status == "blocked"

    assert Enum.any?(
             console.artifact_evidence.rows,
             &(&1.run_id == "bundle-failed-child" and &1.status == "blocked" and
                 &1.reason == "child_ops_gate_failed")
           )

    assert Enum.any?(
             console.artifact_evidence.rows,
             &(&1.run_id == "gate-failed" and &1.status == "blocked" and
                 &1.reason == "gate_status_failed")
           )

    assert Enum.any?(
             console.artifact_evidence.rows,
             &(&1.run_id == "gate-blocker" and &1.status == "blocked" and
                 &1.reason == "gate_blocked")
           )

    assert Enum.any?(
             console.artifact_evidence.rows,
             &(&1.run_id == "gate-warning" and &1.status == "attention" and
                 &1.reason == "gate_warning")
           )

    assert Enum.any?(console.blockers.rows, &(&1.reason == "child_ops_gate_failed"))
    assert Enum.any?(console.blockers.rows, &(&1.reason == "gate_status_failed"))
    assert Enum.any?(console.blockers.rows, &(&1.reason == "gate_blocked"))
    assert Enum.any?(console.warnings.rows, &(&1.reason == "gate_warning"))
  end

  test "missing, future, malformed, and crashing evidence fail closed or require attention" do
    future = DateTime.add(@now, 60, :second)

    console =
      RecoveryReadinessConsole.load(
        ready_opts(
          rehearsal_bundles_fun: fn opts ->
            assert opts[:limit] == 3
            []
          end,
          gate_artifacts_fun: fn _opts ->
            [%{run_id: "gate-future", status: "ok", generated_at: future}]
          end,
          cluster_fun: fn ->
            raise "Authorization: Bearer real-token secret=super-secret C:\\private\\ops.json"
          end,
          scan_fun: fn -> "bad-shape" end,
          replacement_fun: fn ->
            %{
              status: "attention",
              warnings: %{rows: [%{reason: "scheduler_warning", detail: "token=raw-token"}]}
            }
          end
        )
      )

    assert console.status == "blocked"
    assert Enum.any?(console.warnings.rows, &(&1.reason == "no_rehearsal_bundle_evidence"))
    assert Enum.any?(console.blockers.rows, &(&1.reason == "future_generated_at"))
    assert Enum.any?(console.blockers.rows, &(&1.reason == "reader_failed"))
    assert Enum.any?(console.blockers.rows, &(&1.reason == "malformed_reader_result"))

    inspected = inspect(console)
    refute inspected =~ "real-token"
    refute inspected =~ "super-secret"
    refute inspected =~ "raw-token"
    refute inspected =~ "C:\\private"
    assert inspected =~ "[REDACTED]"
  end

  test "artifact timestamp evidence must prove recency" do
    stale = DateTime.add(@now, -48 * 60 * 60, :second)

    console =
      RecoveryReadinessConsole.load(
        ready_opts(
          max_artifact_age_minutes: 60,
          gate_artifacts_fun: fn _opts ->
            [
              %{run_id: "gate-stale", status: "ok", generated_at: stale},
              %{run_id: "gate-missing", status: "ok"}
            ]
          end
        )
      )

    assert console.status == "blocked"
    assert Enum.any?(console.warnings.rows, &(&1.reason == "stale_artifact"))
    assert Enum.any?(console.blockers.rows, &(&1.reason == "missing_generated_at"))
  end

  defp ready_opts(overrides \\ []) do
    Keyword.merge(
      [
        now: @now,
        rehearsal_bundles_fun: fn opts ->
          assert opts[:limit] == 3

          [
            %{
              run_id: "bundle-ready",
              status: "ok",
              gate_status: "ok",
              generated_at: @now,
              replacement_rehearsal_ready?: true,
              child_results: [
                %{id: "replacement_live_rehearsal", status: "ok"},
                %{id: "scheduler_live_rehearsal", status: "ok"},
                %{id: "ops_gate", status: "ok", gate_status: "ok"}
              ],
              boundary_warnings: []
            }
          ]
        end,
        gate_artifacts_fun: fn opts ->
          assert opts[:limit] == 3
          [%{run_id: "gate-ready", status: "ok", gate_status: "ok", generated_at: @now}]
        end,
        cluster_fun: fn -> ready_projection("cluster") end,
        scan_fun: fn -> ready_projection("scan") end,
        replacement_fun: fn -> ready_projection("replacement") end,
        rebalance_fun: fn -> ready_projection("rebalance") end,
        upgrade_fun: fn -> ready_projection("upgrade") end,
        observability_fun: fn -> ready_projection("observability") end
      ],
      overrides
    )
  end

  defp ready_projection(label) do
    %{
      status: "ok",
      summary_rows: [%{id: "#{label}-status", label: "#{label}_status", value: "ok"}],
      blockers: %{rows: []},
      warnings: %{rows: []}
    }
  end
end
