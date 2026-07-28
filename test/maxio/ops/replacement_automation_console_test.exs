defmodule Maxio.Ops.ReplacementAutomationConsoleTest do
  use ExUnit.Case, async: true

  alias Maxio.Ops.ReplacementAutomationConsole

  @now ~U[2026-07-05 00:00:00.000000Z]

  test "normalizes ready automation profile and scheduler ledger evidence" do
    result =
      ReplacementAutomationConsole.load(
        automation_profile_fun: fn opts ->
          assert Keyword.fetch!(opts, :require_scheduler_evidence?)
          ready_profile()
        end,
        scheduler_states_fun: fn opts ->
          assert opts == []

          [
            %{
              id: 1,
              scheduler: "fresh_drive_heal",
              node: "maxio@n0",
              status: "ok",
              consecutive_failures: 0,
              last_run_id: 10,
              last_started_at: @now,
              last_finished_at: @now,
              alert_status: "clear",
              last_summary: %{"status" => "ok", "access_key" => "AKIA_TEST"}
            }
          ]
        end,
        scheduler_runs_fun: fn opts ->
          assert Keyword.fetch!(opts, :limit) == 20

          [
            %{
              id: 10,
              scheduler: "fresh_drive_heal",
              trigger: "scheduled",
              node: "maxio@n0",
              status: "ok",
              result_kind: "ok",
              phase: "fresh_drive_heal",
              job_id: "job-1",
              started_at: @now,
              finished_at: @now,
              duration_ms: 12,
              consecutive_failures_after: 0,
              summary: %{"status" => "ok", "secret_token" => "super-secret"}
            }
          ]
        end
      )

    assert result.status == "ready"
    assert result.profile.status == "ready"
    assert result.scheduler_evidence.status == "ok"
    assert result.scheduler_states.status == "ok"
    assert result.recent_runs.status == "ok"
    assert field(result.fresh_drive_heal_rows, "fresh-drive-heal-enabled").value == "true"
    assert field(result.rebalance_rows, "rebalance-closure").value == "true"

    assert [scheduler] = result.scheduler_evidence.scheduler_rows
    assert scheduler.scheduler == "fresh_drive_heal"
    assert scheduler.health == "ok"

    refute inspect(result) =~ "AKIA_TEST"
    refute inspect(result) =~ "AKIA_PROFILE"
    refute inspect(result) =~ "super-secret"
    refute inspect(result) =~ "profile-secret"
    assert [state] = result.scheduler_states.rows
    assert state.last_summary =~ "[REDACTED]"
    assert [run] = result.recent_runs.rows
    assert run.summary =~ "[REDACTED]"
    assert inspect(result) =~ "[REDACTED]"
  end

  test "missing runtime scheduler rows are explicit and do not produce healthy rollup" do
    result =
      ReplacementAutomationConsole.load(
        automation_profile_fun: fn _opts ->
          ready_profile(%{
            checks: %{scheduler_evidence: %{required?: false, status: :not_requested}}
          })
        end,
        scheduler_states_fun: fn _opts -> [] end,
        scheduler_runs_fun: fn _opts -> [] end
      )

    assert result.profile.status == "ready"
    assert result.scheduler_evidence.status == "not_requested"
    assert result.scheduler_states.status == "empty"
    assert result.recent_runs.status == "empty"
    assert result.status == "attention"
  end

  test "surfaces detailed scheduler evidence blockers and warnings without raw secrets" do
    result =
      ReplacementAutomationConsole.load(
        automation_profile_fun: fn _opts ->
          ready_profile(%{
            status: :attention,
            ready?: true,
            checks: %{
              scheduler_evidence: %{
                required?: true,
                status: "attention",
                report: %{
                  status: "attention",
                  blockers: [
                    %{
                      scheduler: "fresh_drive_heal",
                      reason: :missing_expected_nodes,
                      access_key: "AKIA_BLOCKER"
                    }
                  ],
                  warnings: [
                    %{
                      scheduler: "rebalance",
                      reason: :blocked_runs_seen,
                      secret_token: "warning-secret"
                    }
                  ],
                  schedulers: []
                }
              }
            },
            blockers: ["scheduler_evidence_blocked"],
            warnings: ["scheduler_evidence_attention"]
          })
        end,
        scheduler_states_fun: fn _opts -> [] end,
        scheduler_runs_fun: fn _opts -> [] end
      )

    assert Enum.any?(result.blockers, &String.contains?(&1, "missing_expected_nodes"))
    assert Enum.any?(result.warnings, &String.contains?(&1, "blocked_runs_seen"))
    refute inspect(result) =~ "AKIA_BLOCKER"
    refute inspect(result) =~ "warning-secret"
  end

  test "unavailable automation profile is blocked with read-only boundaries intact" do
    result =
      ReplacementAutomationConsole.load(
        automation_profile_fun: fn _opts -> raise "profile unavailable" end,
        scheduler_states_fun: fn _opts -> [] end,
        scheduler_runs_fun: fn _opts -> [] end
      )

    assert result.status == "blocked"
    assert result.profile.status == "blocked"
    assert "replacement_automation_profile_unavailable" in result.blockers
    assert "FreshDriveHeal.run_once" in result.readonly_boundary.forbidden
    assert "physical remove/purge" in result.readonly_boundary.forbidden
  end

  defp ready_profile(overrides \\ %{}) do
    base = %{
      profile: :replacement_automation_v1,
      status: :ready,
      ready?: true,
      automation_path:
        "fresh_drive_heal_scheduler -> rebalance_enqueue -> rebalance_scheduler_drain -> rebalance_closure",
      checks: %{
        fresh_drive_heal_scheduler: %{
          enabled: true,
          probe_drive_health: true,
          auto_rebalance_after_heal: true,
          auto_advance_rebalance_after_heal: false,
          rebalance_advance_max_steps: 2,
          inline_closure_verifier: true,
          run_opts: %{dry_run: false, bucket: nil, scan_versions: true, max_objects: nil},
          ledger_enabled: true
        },
        rebalance_scheduler: %{
          enabled: true,
          auto_source_cleanup: true,
          auto_rebalance_closure: true,
          run_opts: %{dry_run: false},
          ledger_enabled: true
        },
        scheduler_evidence: %{
          required?: true,
          status: "ok",
          report: %{
            status: "ok",
            generated_at: @now,
            from: @now,
            until: @now,
            window_ms: 60_000,
            min_effective_nodes: 1,
            blockers: [],
            warnings: [],
            schedulers: [
              %{
                scheduler: "fresh_drive_heal",
                status: "ok",
                cadence: %{health: "ok", reason: "healthy"},
                scheduled_nodes: ["maxio@n0"],
                effective_scheduled_nodes: ["maxio@n0"],
                healthy_scheduled_nodes: ["maxio@n0"],
                state: %{
                  status: "ok",
                  last_summary: %{
                    "status" => "ok",
                    "access_key" => "AKIA_PROFILE",
                    "secret_token" => "profile-secret"
                  }
                },
                blockers: [],
                warnings: []
              }
            ]
          }
        },
        scheduler_ledger: %{fresh_drive_heal_enabled: true, rebalance_enabled: true}
      },
      blockers: [],
      warnings: [],
      next_action: "none",
      boundaries: [
        "does_not_start_schedulers",
        "does_not_run_heal_or_rebalance",
        "does_not_mutate_topology_or_deployment",
        "does_not_remove_or_purge_physical_layout"
      ]
    }

    deep_merge(base, overrides)
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp field(rows, id), do: Enum.find(rows, &(&1.id == id))
end
