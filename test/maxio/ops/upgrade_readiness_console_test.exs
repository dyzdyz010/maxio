defmodule Maxio.Ops.UpgradeReadinessConsoleTest do
  use ExUnit.Case, async: true

  alias Maxio.Cluster.{Topology, TopologyStore}
  alias Maxio.Ops.UpgradeReadinessConsole

  @now ~U[2026-07-05 00:00:00.000000Z]

  test "normalizes ready upgrade evidence without leaking raw artifact or scheduler secrets" do
    topology = sample_topology()
    hash = Topology.fingerprint(topology)
    {:ok, config} = TopologyStore.encode_config(topology)

    result =
      UpgradeReadinessConsole.load(
        now: @now,
        app_vsn_fun: fn -> "0.1.0" end,
        runtime_fun: fn ->
          %{
            elixir_version: "1.18.0",
            otp_release: "27",
            erts_version: "15.0",
            node: :maxio@n0,
            mix_env: "test"
          }
        end,
        migration_files_fun: fn _opts ->
          [
            %{version: "20260701000000", file_name: "20260701000000_create_a.exs"},
            %{version: "20260702000000", file_name: "20260702000000_create_b.exs"}
          ]
        end,
        db_schema_versions_fun: fn _opts -> ["20260701000000", "20260702000000"] end,
        active_topology_fun: fn _opts ->
          {:ok,
           %{
             revision: %{
               id: "active-revision",
               status: "active",
               topology_hash: hash,
               source: "operator",
               activated_at: @now
             },
             topology: topology
           }}
        end,
        topology_history_fun: fn _opts ->
          [
            %{
              id: "active-revision",
              status: "active",
              topology_hash: hash,
              source: "operator",
              activated_at: @now,
              config: config
            },
            %{
              id: "rollback-revision",
              status: "superseded",
              topology_hash: hash,
              source: "operator",
              activated_at: DateTime.add(@now, -3600, :second),
              config: config
            }
          ]
        end,
        gate_artifacts_fun: fn _opts ->
          [
            %{
              status: "ok",
              file_name: "m8_ops_gate_ready.json",
              gate_status: "ok",
              run_id: "gate-ready",
              generated_at: DateTime.to_iso8601(@now),
              path: "C:/private/m8_ops_gate_ready.json",
              raw: %{"secret_token" => "super-secret"}
            }
          ]
        end,
        rehearsal_bundles_fun: fn _opts ->
          [
            %{
              status: "ok",
              file_name: "m8_p0_ops_live_rehearsal_ready_bundle.json",
              gate_status: "ok",
              run_id: "bundle-ready",
              generated_at: DateTime.to_iso8601(@now),
              replacement_mode: "dry_run",
              scheduler_mode: "read_only",
              child_results: [%{id: "ops_gate", status: "ok", gate_status: "ok"}]
            }
          ]
        end,
        scheduler_states_fun: fn _opts ->
          [
            %{
              id: "state-1",
              scheduler: "rebalance",
              node: "maxio@n0",
              status: "ok",
              alert_status: "ok",
              last_summary: %{"authorization" => "AWS4-HMAC-SHA256 Credential=AKIA/secret"}
            }
          ]
        end,
        scheduler_runs_fun: fn _opts ->
          [
            %{
              id: "run-1",
              scheduler: "rebalance",
              trigger: "scheduled",
              status: "ok",
              result_kind: "ok",
              finished_at: DateTime.to_iso8601(@now),
              summary: %{"token" => "super-secret"}
            }
          ]
        end,
        scheduler_rollups_fun: fn _opts ->
          [
            %{
              id: "rollup-1",
              scheduler: "rebalance",
              trigger: "scheduled",
              run_count: 2,
              healthy_count: 2,
              blocked_count: 0,
              failed_count: 0
            }
          ]
        end
      )

    assert result.status == "ok"
    assert result.schema.status == "ok"
    assert result.topology_revisions.status == "ok"
    assert [%{revision_id: "rollback-revision", status: "ok"}] = result.rollback_candidates.rows
    assert result.gate_artifacts.latest.run_id == "gate-ready"
    assert result.rehearsal_bundles.latest.run_id == "bundle-ready"
    assert result.scheduler_ledger.status == "ok"

    inspected = inspect(result)
    refute inspected =~ "super-secret"
    refute inspected =~ "C:/private"
    refute inspected =~ "AKIA/secret"
  end

  test "schema pending or db-ahead versions fail closed" do
    result =
      UpgradeReadinessConsole.load(
        base_ready_opts()
        |> Keyword.merge(
          migration_files_fun: fn _opts ->
            [
              %{version: "20260701000000", file_name: "20260701000000_create_a.exs"},
              %{version: "20260702000000", file_name: "20260702000000_create_b.exs"}
            ]
          end,
          db_schema_versions_fun: fn _opts -> ["20260701000000", "20260703000000"] end
        )
      )

    assert result.status == "blocked"
    assert result.schema.status == "blocked"
    assert result.schema.reason == "pending_migrations"
    assert result.schema.pending_versions == ["20260702000000"]
    assert result.schema.db_ahead_versions == ["20260703000000"]
  end

  test "duplicate migration versions fail closed" do
    result =
      UpgradeReadinessConsole.load(
        base_ready_opts()
        |> Keyword.merge(
          migration_files_fun: fn _opts ->
            [
              %{version: "20260701000000", file_name: "20260701000000_create_a.exs"},
              %{version: "20260701000000", file_name: "20260701000000_create_b.exs"}
            ]
          end,
          db_schema_versions_fun: fn _opts -> ["20260701000000"] end
        )
      )

    assert result.status == "blocked"
    assert result.schema.status == "blocked"
    assert result.schema.reason == "duplicate_migration_versions"
    assert result.schema.duplicate_versions == ["20260701000000"]

    assert Enum.find(result.schema.rows, &(&1.id == "schema-duplicates")).value ==
             ~s(["20260701000000"])
  end

  test "malformed topology revision evidence fails closed" do
    topology = sample_topology()
    {:ok, config} = TopologyStore.encode_config(topology)

    result =
      UpgradeReadinessConsole.load(
        base_ready_opts()
        |> Keyword.merge(
          active_topology_fun: fn _opts ->
            {:error, {:topology_revision_hash_mismatch, "stored", "actual"}}
          end,
          topology_history_fun: fn _opts ->
            [
              %{
                id: "bad-rollback",
                status: "superseded",
                topology_hash: String.duplicate("0", 64),
                source: "operator",
                activated_at: @now,
                config: config
              }
            ]
          end
        )
      )

    assert result.status == "blocked"
    assert result.topology_revisions.status == "blocked"
    assert result.topology_revisions.active.reason =~ "topology_revision_hash_mismatch"
    assert [%{status: "blocked", reason: reason}] = result.rollback_candidates.rows
    assert reason =~ "topology_revision_hash_mismatch"
  end

  test "invalid artifacts and empty scheduler ledger are explicit, not healthy" do
    result =
      UpgradeReadinessConsole.load(
        base_ready_opts()
        |> Keyword.merge(
          gate_artifacts_fun: fn _opts ->
            [
              %{
                status: "invalid",
                file_name: "m8_ops_gate_bad.json",
                gate_status: "invalid",
                error_reason: "json_unparseable"
              }
            ]
          end,
          rehearsal_bundles_fun: fn _opts -> [] end,
          scheduler_states_fun: fn _opts -> [] end,
          scheduler_runs_fun: fn _opts -> [] end,
          scheduler_rollups_fun: fn _opts -> [] end
        )
      )

    assert result.status == "blocked"
    assert result.gate_artifacts.status == "blocked"
    assert result.rehearsal_bundles.status == "attention"
    assert result.scheduler_ledger.status == "attention"
  end

  test "artifact timestamps must prove recency" do
    future = @now |> DateTime.add(60, :second) |> DateTime.to_iso8601()

    result =
      UpgradeReadinessConsole.load(
        base_ready_opts()
        |> Keyword.merge(
          gate_artifacts_fun: fn _opts ->
            [
              %{status: "ok", file_name: "m8_ops_gate_missing_time.json", gate_status: "ok"},
              %{
                status: "ok",
                file_name: "m8_ops_gate_bad_time.json",
                gate_status: "ok",
                generated_at: "not-a-timestamp"
              },
              %{
                status: "ok",
                file_name: "m8_ops_gate_future_time.json",
                gate_status: "ok",
                generated_at: future
              }
            ]
          end,
          rehearsal_bundles_fun: fn _opts ->
            [
              %{
                status: "ok",
                file_name: "m8_p0_ops_live_rehearsal_bad_time_bundle.json",
                gate_status: "ok",
                generated_at: "not-a-timestamp"
              }
            ]
          end
        )
      )

    assert result.status == "blocked"
    assert result.gate_artifacts.status == "blocked"

    assert Enum.map(result.gate_artifacts.rows, & &1.reason) == [
             "missing_generated_at",
             "invalid_generated_at",
             "future_generated_at"
           ]

    assert result.rehearsal_bundles.status == "blocked"
    assert result.rehearsal_bundles.latest.reason == "invalid_generated_at"
  end

  defp base_ready_opts do
    topology = sample_topology()
    hash = Topology.fingerprint(topology)
    {:ok, config} = TopologyStore.encode_config(topology)

    [
      now: @now,
      app_vsn_fun: fn -> "0.1.0" end,
      runtime_fun: fn ->
        %{elixir_version: "1.18.0", otp_release: "27", erts_version: "15.0", node: :maxio@n0}
      end,
      migration_files_fun: fn _opts -> [%{version: "20260701000000", file_name: "a.exs"}] end,
      db_schema_versions_fun: fn _opts -> ["20260701000000"] end,
      active_topology_fun: fn _opts ->
        {:ok,
         %{revision: %{id: "active", status: "active", topology_hash: hash}, topology: topology}}
      end,
      topology_history_fun: fn _opts ->
        [
          %{
            id: "active",
            status: "active",
            topology_hash: hash,
            source: "operator",
            config: config
          }
        ]
      end,
      gate_artifacts_fun: fn _opts ->
        [
          %{
            status: "ok",
            file_name: "m8_ops_gate_ok.json",
            gate_status: "ok",
            generated_at: DateTime.to_iso8601(@now)
          }
        ]
      end,
      rehearsal_bundles_fun: fn _opts ->
        [
          %{
            status: "ok",
            file_name: "m8_p0_ops_live_rehearsal_ok_bundle.json",
            gate_status: "ok",
            generated_at: DateTime.to_iso8601(@now)
          }
        ]
      end,
      scheduler_states_fun: fn _opts -> [%{id: "state", scheduler: "rebalance", status: "ok"}] end,
      scheduler_runs_fun: fn _opts ->
        [%{id: "run", scheduler: "rebalance", trigger: "scheduled", status: "ok"}]
      end,
      scheduler_rollups_fun: fn _opts ->
        [
          %{
            id: "rollup",
            scheduler: "rebalance",
            trigger: "scheduled",
            run_count: 1,
            healthy_count: 1
          }
        ]
      end
    ]
  end

  defp sample_topology do
    Topology.parse_and_validate!(
      data_shards: 1,
      parity_shards: 1,
      block_size: 1_048_576,
      allow_colocated_endpoints: true,
      pools: [
        %{
          id: 0,
          sets: [
            %{
              id: 0,
              endpoints: [{:maxio@n0, "/data/d0"}, {:maxio@n1, "/data/d1"}]
            }
          ]
        }
      ]
    )
  end
end
