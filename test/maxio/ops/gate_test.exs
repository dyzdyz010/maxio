defmodule Maxio.Ops.GateTest do
  use ExUnit.Case, async: true

  alias Maxio.Ops.Gate

  @now ~U[2026-07-04 08:00:00Z]

  test "default gate runs only read-only M8 checks and writes an ok artifact" do
    artifact_path = artifact_path("default-ok")

    {:ok, result} =
      run_gate(["--artifact", artifact_path], ok_responses())

    assert result.exit_code == 0
    assert result.gate_status == "ok"
    assert result.stdout =~ "[maxio ops.gate] gate_status=ok"
    assert result.artifact_path == artifact_path
    refute Map.get(result, :stderr)

    assert_received {:cmd, ["maxio.scheduler.status", "--json"], [stderr_to_stdout: true]}

    assert_received {:cmd, ["maxio.replacement.automation_status", "--json"],
                     [stderr_to_stdout: true]}

    assert_received {:cmd, ["maxio.replacement.workflow", "--json"], [stderr_to_stdout: true]}
    assert_received {:cmd, ["maxio.rebalance.workflow", "--json"], [stderr_to_stdout: true]}
    refute_received {:cmd, ["maxio.reconcile_index" | _], _opts}
    refute_received {:cmd, ["maxio.scan" | _], _opts}
    refute_received {:cmd, ["maxio.heal.fresh_drives" | _], _opts}

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["schema_version"] == 1
    assert artifact["generated_at"] == "2026-07-04T08:00:00Z"
    assert artifact["git_sha"] == "test-sha"
    assert artifact["gate_status"] == "ok"

    assert artifact["counts"] == %{
             "attention" => 0,
             "blocked" => 0,
             "error" => 0,
             "ok" => 4,
             "total" => 4
           }

    assert Enum.map(artifact["checks"], & &1["id"]) == [
             "scheduler_status",
             "replacement_automation_status",
             "replacement_workflow",
             "rebalance_workflow"
           ]
  end

  test "attention remains reporting-only unless fail-on-attention is explicit" do
    responses =
      ok_responses()
      |> Map.put("maxio.replacement.workflow", %{
        "status" => "audit",
        "gate_status" => "attention",
        "blockers" => [],
        "warnings" => ["workflow_next_action_required"]
      })

    {:ok, reporting} =
      run_gate(["--artifact", artifact_path("attention-reporting")], responses)

    assert reporting.exit_code == 0
    assert reporting.gate_status == "attention"

    assert [%{"check" => "replacement_workflow", "reason" => "workflow_next_action_required"}] =
             reporting.artifact["warnings"]

    {:error, strict} =
      run_gate(
        ["--artifact", artifact_path("attention-fails"), "--fail-on-attention", "--json"],
        responses
      )

    assert strict.exit_code == 1
    assert strict.gate_status == "attention"
    assert strict.stderr =~ "gate failed"

    decoded = Jason.decode!(strict.stdout)
    assert decoded["gate_status"] == "attention"
    assert decoded["warnings"] != []
  end

  test "replacement rehearsal ready mode is explicit and only passed to replacement checks" do
    artifact_path = artifact_path("replacement-rehearsal-ready")

    {:ok, result} =
      run_gate(["--artifact", artifact_path, "--replacement-rehearsal-ready"], ok_responses())

    assert result.exit_code == 0
    assert result.gate_status == "ok"

    assert_received {:cmd, ["maxio.scheduler.status", "--json"], [stderr_to_stdout: true]}

    refute_received {:cmd, ["maxio.replacement.automation_status", "--json", "--rehearsal-ready"],
                     [stderr_to_stdout: true]}

    assert_received {:cmd, ["maxio.replacement.workflow", "--json", "--rehearsal-ready"],
                     [stderr_to_stdout: true]}

    assert_received {:cmd, ["maxio.rebalance.workflow", "--json"], [stderr_to_stdout: true]}

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["config"]["replacement_rehearsal_ready"] == true

    automation_check =
      Enum.find(artifact["checks"], &(&1["id"] == "replacement_automation_status"))

    assert automation_check["status"] == "ok"

    assert automation_check["command"] ==
             "maxio.replacement.automation_status --json --rehearsal-ready"

    assert automation_check["parsed_output"]["status"] == "ready"
    assert automation_check["parsed_output"]["blockers"] == []
  end

  test "replacement rehearsal ready local automation status exceptions fail closed" do
    artifact_path = artifact_path("replacement-rehearsal-ready-exception")

    {:error, result} =
      run_gate(["--artifact", artifact_path, "--replacement-rehearsal-ready"], ok_responses(),
        rehearsal_ready_automation_status_fun: fn -> raise "profile status exploded" end
      )

    assert result.exit_code == 1
    assert result.gate_status == "error"
    assert result.stderr =~ "gate failed: error"

    refute_received {:cmd, ["maxio.replacement.automation_status", "--json", "--rehearsal-ready"],
                     [stderr_to_stdout: true]}

    artifact = artifact_path |> File.read!() |> Jason.decode!()

    automation_check =
      Enum.find(artifact["checks"], &(&1["id"] == "replacement_automation_status"))

    assert automation_check["status"] == "error"
    assert automation_check["raw_output"] == "profile status exploded"

    assert automation_check["blockers"] == [
             %{"message" => "profile status exploded", "reason" => "command_failed"}
           ]

    assert [%{"check" => "replacement_automation_status", "reason" => "command_failed"}] =
             artifact["blockers"]
  end

  test "unparseable child JSON fails closed even without fail flags" do
    responses =
      ok_responses()
      |> Map.put("maxio.scheduler.status", {"not json\n", 0})

    {:error, result} =
      run_gate(["--artifact", artifact_path("bad-json")], responses)

    assert result.exit_code == 1
    assert result.gate_status == "error"

    assert [%{"check" => "scheduler_status", "reason" => "json_unparseable"}] =
             result.artifact["blockers"]
  end

  test "optional scanner and fresh-drive checks are explicit and dry-run by default" do
    responses =
      ok_responses()
      |> Map.put("maxio.reconcile_index", %{
        "status" => "ok",
        "gate_status" => "ok",
        "blockers" => [],
        "warnings" => []
      })
      |> Map.put("maxio.heal.fresh_drives", %{
        "status" => "dry_run",
        "gate_status" => "attention",
        "blockers" => [],
        "warnings" => ["fresh_drive_heal_dry_run"]
      })

    {:ok, result} =
      run_gate(
        [
          "--artifact",
          artifact_path("optional-dry-run"),
          "--include-scanner",
          "--include-fresh-drive-heal"
        ],
        responses
      )

    assert result.gate_status == "attention"
    assert_received {:cmd, ["maxio.reconcile_index", "--dry-run", "--json"], _opts}
    assert_received {:cmd, ["maxio.heal.fresh_drives", "--dry-run", "--json"], _opts}
  end

  test "foreground scan requires explicit mutating scope" do
    {:error, usage} = Gate.run(["--include-foreground-scan"])

    assert usage.exit_code == 64
    assert usage.stderr =~ "--include-foreground-scan requires --allow-mutating"

    responses =
      ok_responses()
      |> Map.put("maxio.scan", %{
        "status" => "ok",
        "gate_status" => "ok",
        "blockers" => [],
        "warnings" => []
      })

    {:ok, _result} =
      run_gate(
        [
          "--artifact",
          artifact_path("foreground-scan"),
          "--include-foreground-scan",
          "--allow-mutating"
        ],
        responses
      )

    assert_received {:cmd, ["maxio.scan", "--json"], _opts}
  end

  test "scheduler evidence option mapping is preserved" do
    responses =
      ok_responses()
      |> Map.put("maxio.scheduler.evidence", %{
        "status" => "ok",
        "blockers" => [],
        "warnings" => []
      })

    {:ok, result} =
      run_gate(
        [
          "--artifact",
          artifact_path("scheduler-evidence"),
          "--include-scheduler-evidence",
          "--evidence-scheduler",
          "rebalance",
          "--evidence-since-minutes",
          "120",
          "--evidence-expected-interval-ms",
          "60000",
          "--evidence-stale-after-ms",
          "120000",
          "--evidence-expected-nodes",
          "node_a,node_b",
          "--evidence-min-effective-nodes",
          "1",
          "--evidence-require-lock-loser",
          "--evidence-require-rollups"
        ],
        responses
      )

    assert result.gate_status == "ok"

    assert_received {:cmd,
                     [
                       "maxio.scheduler.evidence",
                       "--json",
                       "--scheduler",
                       "rebalance",
                       "--since-minutes",
                       "120",
                       "--expected-interval-ms",
                       "60000",
                       "--stale-after-ms",
                       "120000",
                       "--expected-nodes",
                       "node_a,node_b",
                       "--min-effective-nodes",
                       "1",
                       "--require-lock-loser",
                       "--require-rollups"
                     ], _opts}
  end

  test "p0 ops profile validates replacement and scheduler rehearsal artifacts" do
    replacement_path = artifact_path("replacement-rehearsal")
    scheduler_path = artifact_path("scheduler-rehearsal")

    write_json!(replacement_path, %{
      "version" => 1,
      "bundle_gate" => %{"status" => "ok", "reason" => "replacement_workflow_clear"},
      "gate" => %{"status" => "ok", "reason" => "replacement_workflow_clear"},
      "replacement_workflow" => %{
        "status" => "audit",
        "phase" => "audit",
        "blockers" => [],
        "next_action" => "none"
      }
    })

    write_json!(scheduler_path, %{
      "version" => 1,
      "scheduler" => "rebalance",
      "evidence_exit_status" => 0,
      "scheduler_evidence" => %{"status" => "ok", "warnings" => [], "blockers" => []}
    })

    {:ok, result} =
      run_gate(
        [
          "--artifact",
          artifact_path("p0-ops-profile"),
          "--ops-profile",
          "p0_ops_1",
          "--rehearsal-artifact",
          replacement_path,
          "--rehearsal-artifact",
          scheduler_path
        ],
        ok_responses()
      )

    assert result.gate_status == "ok"

    assert result.artifact["counts"] == %{
             "attention" => 0,
             "blocked" => 0,
             "error" => 0,
             "ok" => 6,
             "total" => 6
           }

    assert result.artifact["ops_evidence_matrix"] == %{
             "artifact_count" => 2,
             "covered_rehearsal_kinds" => [
               "replacement_live_rehearsal",
               "scheduler_live_rehearsal"
             ],
             "missing_rehearsal_kinds" => [],
             "profile" => "p0_ops_1",
             "read_only" => true,
             "required_rehearsal_kinds" => [
               "replacement_live_rehearsal",
               "scheduler_live_rehearsal"
             ]
           }

    artifact_checks =
      Enum.filter(result.artifact["checks"], &(&1["mode"] == "read_only_artifact"))

    assert Enum.map(artifact_checks, & &1["status"]) == ["ok", "ok"]

    assert Enum.map(artifact_checks, & &1["evidence_kind"]) == [
             "replacement_live_rehearsal",
             "scheduler_live_rehearsal"
           ]
  end

  test "p0 ops profile reports missing required rehearsal kinds as blockers" do
    replacement_path = artifact_path("replacement-only")

    write_json!(replacement_path, %{
      "bundle_gate" => %{"status" => "ok", "reason" => "replacement_workflow_clear"},
      "replacement_workflow" => %{"phase" => "audit"}
    })

    {:error, result} =
      run_gate(
        [
          "--artifact",
          artifact_path("p0-ops-missing"),
          "--ops-profile",
          "p0_ops_1",
          "--rehearsal-artifact",
          replacement_path,
          "--fail-on-blocked"
        ],
        ok_responses()
      )

    assert result.gate_status == "blocked"
    assert result.exit_code == 1

    assert [%{"reason" => "required_rehearsal_kind_missing"}] =
             result.artifact["checks"]
             |> Enum.find(&(&1["id"] == "required_rehearsal_kind_scheduler_live_rehearsal"))
             |> Map.fetch!("blockers")

    assert result.artifact["ops_evidence_matrix"]["missing_rehearsal_kinds"] == [
             "scheduler_live_rehearsal"
           ]
  end

  test "scheduler rehearsal attention artifact fails the p0 ops bundle" do
    replacement_path = artifact_path("replacement-ok")
    scheduler_path = artifact_path("scheduler-attention")

    write_json!(replacement_path, %{
      "bundle_gate" => %{"status" => "ok", "reason" => "replacement_workflow_clear"},
      "replacement_workflow" => %{"phase" => "audit"}
    })

    write_json!(scheduler_path, %{
      "scheduler" => "rebalance",
      "evidence_exit_status" => 0,
      "scheduler_evidence" => %{
        "status" => "attention",
        "warnings" => [%{"reason" => "blocked_runs_seen"}],
        "blockers" => []
      }
    })

    {:error, result} =
      run_gate(
        [
          "--artifact",
          artifact_path("p0-ops-attention"),
          "--ops-profile",
          "p0_ops_1",
          "--rehearsal-artifact",
          replacement_path,
          "--rehearsal-artifact",
          scheduler_path,
          "--fail-on-blocked"
        ],
        ok_responses()
      )

    assert result.gate_status == "blocked"

    scheduler_check =
      Enum.find(result.artifact["checks"], &(&1["evidence_kind"] == "scheduler_live_rehearsal"))

    assert scheduler_check["status"] == "blocked"
    assert [%{"reason" => "scheduler_evidence_status_attention"}] = scheduler_check["blockers"]
  end

  test "missing rehearsal artifact path fails closed as an error check" do
    missing_path =
      Path.join(
        System.tmp_dir!(),
        "maxio_missing_rehearsal_#{System.unique_integer([:positive])}.json"
      )

    {:error, result} =
      run_gate(
        [
          "--artifact",
          artifact_path("missing-artifact-path"),
          "--rehearsal-artifact",
          missing_path
        ],
        ok_responses()
      )

    assert result.gate_status == "error"
    assert result.exit_code == 1

    check = Enum.find(result.artifact["checks"], &(&1["id"] == "rehearsal_artifact_1"))
    assert check["status"] == "error"
    assert [%{"reason" => "rehearsal_artifact_read_error"}] = check["blockers"]
  end

  test "p0 ops profile rejects rehearsal artifacts whose explicit kind does not match shape" do
    spoofed_scheduler_path = artifact_path("spoofed-scheduler")

    write_json!(spoofed_scheduler_path, %{
      "evidence_kind" => "scheduler_live_rehearsal",
      "bundle_gate" => %{"status" => "ok", "reason" => "replacement_workflow_clear"},
      "replacement_workflow" => %{"phase" => "audit"}
    })

    {:error, result} =
      run_gate(
        [
          "--artifact",
          artifact_path("p0-ops-spoofed-kind"),
          "--ops-profile",
          "p0_ops_1",
          "--rehearsal-artifact",
          spoofed_scheduler_path,
          "--fail-on-blocked"
        ],
        ok_responses()
      )

    assert result.gate_status == "error"
    assert result.exit_code == 1

    artifact_check =
      Enum.find(result.artifact["checks"], &(&1["id"] == "rehearsal_artifact_1"))

    assert artifact_check["status"] == "error"

    assert [
             %{
               "reason" => "rehearsal_artifact_kind_mismatch",
               "evidence_kind" => "scheduler_live_rehearsal",
               "matching_kinds" => ["replacement_live_rehearsal"]
             }
           ] = artifact_check["blockers"]

    assert result.artifact["ops_evidence_matrix"]["covered_rehearsal_kinds"] == []

    assert result.artifact["ops_evidence_matrix"]["missing_rehearsal_kinds"] == [
             "replacement_live_rehearsal",
             "scheduler_live_rehearsal"
           ]
  end

  test "p0 ops profile rejects ambiguous multi-shape rehearsal artifacts" do
    ambiguous_path = artifact_path("ambiguous-scheduler")

    write_json!(ambiguous_path, %{
      "evidence_kind" => "scheduler_live_rehearsal",
      "bundle_gate" => %{"status" => "ok", "reason" => "replacement_workflow_clear"},
      "replacement_workflow" => %{"phase" => "audit"},
      "scheduler" => "rebalance",
      "evidence_exit_status" => 0,
      "scheduler_evidence" => %{"status" => "ok", "warnings" => [], "blockers" => []}
    })

    {:error, result} =
      run_gate(
        [
          "--artifact",
          artifact_path("p0-ops-ambiguous-kind"),
          "--ops-profile",
          "p0_ops_1",
          "--rehearsal-artifact",
          ambiguous_path,
          "--fail-on-blocked"
        ],
        ok_responses()
      )

    assert result.gate_status == "error"

    artifact_check =
      Enum.find(result.artifact["checks"], &(&1["id"] == "rehearsal_artifact_1"))

    assert [
             %{
               "reason" => "rehearsal_artifact_ambiguous_kind",
               "matching_kinds" => [
                 "replacement_live_rehearsal",
                 "scheduler_live_rehearsal"
               ]
             }
           ] = artifact_check["blockers"]

    assert result.artifact["ops_evidence_matrix"]["covered_rehearsal_kinds"] == []
  end

  defp run_gate(args, responses, opts \\ []) do
    owner = self()

    runner = fn "fake-mix", cmd_args, opts ->
      send(owner, {:cmd, cmd_args, opts})

      case Map.fetch!(responses, List.first(cmd_args)) do
        {output, status} -> {output, status}
        response -> {Jason.encode!(response) <> "\n", 0}
      end
    end

    gate_opts =
      [
        command_runner: runner,
        git_sha_fun: fn -> "test-sha" end,
        now_fun: fn -> @now end
      ]
      |> Keyword.merge(opts)

    Gate.run(["--mix-cmd", "fake-mix" | args], gate_opts)
  end

  defp ok_responses do
    %{
      "maxio.scheduler.status" => %{
        "gate_status" => "ok",
        "blockers" => [],
        "warnings" => []
      },
      "maxio.replacement.automation_status" => %{
        "status" => "ok",
        "blockers" => [],
        "warnings" => []
      },
      "maxio.replacement.workflow" => %{
        "status" => "audit",
        "gate_status" => "ok",
        "blockers" => [],
        "warnings" => []
      },
      "maxio.rebalance.workflow" => %{
        "status" => "not_started",
        "gate_status" => "ok",
        "blockers" => [],
        "warnings" => []
      }
    }
  end

  defp artifact_path(name) do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_ops_gate_test_#{System.unique_integer([:positive])}"
      )

    Path.join(base, "#{name}.json")
  end

  defp write_json!(path, data) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode!(data))
  end
end
