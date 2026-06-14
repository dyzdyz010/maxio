defmodule Maxio.Cluster.ReplacementLiveRehearsalTest do
  use ExUnit.Case, async: true

  alias Maxio.Cluster.ReplacementLiveRehearsal

  @now ~U[2026-06-14 13:00:00Z]

  test "clear audit workflow writes an artifact and passes" do
    workflow = %{
      "status" => "audit",
      "phase" => "audit",
      "blockers" => [],
      "next_action" => "none"
    }

    artifact_path = artifact_path("ok")

    {:ok, result} =
      run_rehearsal(workflow, 0, artifact_path,
        extra_args: ["--probe", "--heal", "--rebalance-if-needed", "--advance-steps", "2"]
      )

    assert result.exit_code == 0
    assert result.stdout =~ "workflow_status=audit"
    assert result.stdout =~ "workflow_gate_status=ok"
    assert result.stdout =~ "bundle_gate_status=ok"
    refute Map.has_key?(result, :stderr)

    assert_received {:workflow_args, args, [stderr_to_stdout: true]}
    assert "maxio.replacement.workflow" in args
    assert "--probe" in args
    assert "--heal" in args
    assert "--rebalance-if-needed" in args
    assert "--advance-steps" in args
    assert "--fail-on-blocked" in args
    assert "--json" in args

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["generated_at"] == "2026-06-14T13:00:00Z"
    assert artifact["git_sha"] == "test-sha"
    assert artifact["workflow_exit_status"] == 0
    assert artifact["replacement_workflow"] == workflow
    assert artifact["gate"]["status"] == "ok"
    assert artifact["gate"]["reason"] == "replacement_workflow_clear"
    assert artifact["bundle_gate"]["status"] == "ok"
    assert artifact["bundle_gate"]["reason"] == "replacement_workflow_clear"
    assert artifact["command"] =~ "--fail-on-blocked"
    assert artifact["scheduler_evidence_required?"] == false
    assert artifact["scheduler_evidence_gate"]["status"] == "not_requested"
    refute_received {:evidence_args, _args, _opts}
  end

  test "blocked workflow fails closed after writing the blocker artifact" do
    workflow = %{
      "status" => "blocked",
      "phase" => "rebalance_closure",
      "blockers" => ["routing_mismatch"],
      "next_action" => "mix maxio.rebalance.start --json"
    }

    artifact_path = artifact_path("blocked")

    {:error, result} = run_rehearsal(workflow, 1, artifact_path)

    assert result.exit_code == 1
    assert result.stdout =~ "workflow_status=blocked"
    assert result.stdout =~ "workflow_gate_status=blocked"
    assert result.stdout =~ "bundle_gate_status=blocked"
    assert result.stderr =~ "gate failed"

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["workflow_exit_status"] == 1
    assert artifact["replacement_workflow"] == workflow
    assert artifact["gate"]["reason"] == "workflow_exit_nonzero"
    assert artifact["bundle_gate"]["reason"] == "workflow_exit_nonzero"
    assert artifact["gate"]["blockers"] == ["routing_mismatch"]
  end

  test "remaining next action is not accepted as a successful rehearsal" do
    workflow = %{
      "status" => "ok",
      "phase" => "rebalance_enqueued",
      "blockers" => [],
      "next_action" => "mix maxio.rebalance.workflow --job-id job-1"
    }

    artifact_path = artifact_path("next-action")

    {:error, result} = run_rehearsal(workflow, 0, artifact_path)

    assert result.exit_code == 1
    assert result.stdout =~ "workflow_status=ok"
    assert result.stderr =~ "gate failed"

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["gate"]["reason"] == "workflow_next_action_required"
    assert artifact["gate"]["next_action"] == "mix maxio.rebalance.workflow --job-id job-1"
  end

  test "dry-run workflows are archived but do not pass the live gate by default" do
    workflow = %{
      "status" => "ok",
      "phase" => "healed",
      "blockers" => [],
      "next_action" => "none"
    }

    artifact_path = artifact_path("dry-run")

    {:error, result} =
      run_rehearsal(workflow, 0, artifact_path, extra_args: ["--dry-run", "--heal"])

    assert result.exit_code == 1
    assert result.stdout =~ "bundle_gate_status=blocked"
    assert result.stderr =~ "gate failed"

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["dry_run?"] == true
    assert artifact["allow_dry_run_success?"] == false
    assert artifact["gate"]["reason"] == "dry_run_not_live"
  end

  test "dry-run workflows can be explicitly accepted as non-live evidence" do
    workflow = %{
      "status" => "ok",
      "phase" => "healed",
      "blockers" => [],
      "next_action" => "none"
    }

    artifact_path = artifact_path("dry-run-allowed")

    {:ok, result} =
      run_rehearsal(workflow, 0, artifact_path,
        extra_args: ["--dry-run", "--heal", "--allow-dry-run-success"]
      )

    assert result.exit_code == 0

    assert_received {:workflow_args, args, [stderr_to_stdout: true]}
    assert "--dry-run" in args
    refute "--allow-dry-run-success" in args

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["dry_run?"] == true
    assert artifact["allow_dry_run_success?"] == true
    assert artifact["gate"]["status"] == "ok"
  end

  test "required scheduler evidence is included in the artifact and participates in the gate" do
    workflow = clear_workflow()
    evidence = %{"status" => "ok", "warnings" => [], "blockers" => []}
    artifact_path = artifact_path("scheduler-evidence-ok")

    {:ok, result} =
      run_rehearsal(workflow, 0, artifact_path,
        evidence: evidence,
        evidence_exit_status: 0,
        extra_args: scheduler_evidence_args()
      )

    assert result.exit_code == 0
    assert result.stdout =~ "workflow_gate_status=ok"
    assert result.stdout =~ "bundle_gate_status=ok"
    assert result.stdout =~ "scheduler_evidence_status=ok"

    assert_received {:evidence_args, args, [stderr_to_stdout: true]}
    assert "maxio.scheduler.evidence" in args
    assert "--scheduler" in args
    assert "rebalance" in args
    assert "--from" in args
    assert "--until" in args
    assert "--window-minutes" in args
    assert "--expected-nodes" in args
    assert "--require-lock-loser" in args
    assert "--require-rollups" in args
    assert "--fail-on-attention" in args
    assert "--json" in args
    refute "--artifact" in args
    refute "--mix-cmd" in args
    refute "--require-scheduler-evidence" in args
    refute "--heal" in args

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["gate"]["reason"] == "replacement_workflow_clear"

    assert artifact["bundle_gate"]["reason"] ==
             "replacement_workflow_and_scheduler_evidence_clear"

    assert artifact["scheduler_evidence_required?"] == true
    assert artifact["scheduler_evidence_exit_status"] == 0
    assert artifact["scheduler_evidence"] == evidence
    assert artifact["scheduler_evidence_raw_output"] =~ ~s("status":"ok")
    assert artifact["scheduler_evidence_gate"]["status"] == "ok"
    assert artifact["commands"]["scheduler_evidence"] =~ "maxio.scheduler.evidence"
  end

  test "blocked scheduler evidence fails the bundled gate even when command exits zero" do
    evidence = %{
      "status" => "blocked",
      "warnings" => [],
      "blockers" => [%{"reason" => "missing_expected_nodes"}]
    }

    artifact_path = artifact_path("scheduler-evidence-blocked")

    {:error, result} =
      run_rehearsal(clear_workflow(), 0, artifact_path,
        evidence: evidence,
        evidence_exit_status: 0,
        extra_args: ["--require-scheduler-evidence"]
      )

    assert result.exit_code == 1
    assert result.stdout =~ "workflow_gate_status=ok"
    assert result.stdout =~ "bundle_gate_status=blocked"

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["gate"]["reason"] == "replacement_workflow_clear"
    assert artifact["bundle_gate"]["reason"] == "scheduler_evidence_status_blocked"
    assert artifact["scheduler_evidence_gate"]["evidence_status"] == "blocked"
  end

  test "scheduler evidence attention fails the strict bundled gate" do
    evidence = %{
      "status" => "attention",
      "warnings" => [%{"reason" => "blocked_runs_seen"}],
      "blockers" => []
    }

    artifact_path = artifact_path("scheduler-evidence-attention")

    {:error, result} =
      run_rehearsal(clear_workflow(), 0, artifact_path,
        evidence: evidence,
        evidence_exit_status: 0,
        extra_args: ["--require-scheduler-evidence"]
      )

    assert result.exit_code == 1

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["gate"]["reason"] == "replacement_workflow_clear"
    assert artifact["bundle_gate"]["reason"] == "scheduler_evidence_status_attention"
    assert artifact["scheduler_evidence_gate"]["warnings"] == [%{"reason" => "blocked_runs_seen"}]
  end

  test "scheduler evidence command non-zero fails even if JSON is ok" do
    artifact_path = artifact_path("scheduler-evidence-exit")

    {:error, _result} =
      run_rehearsal(clear_workflow(), 0, artifact_path,
        evidence: %{"status" => "ok", "warnings" => [], "blockers" => []},
        evidence_exit_status: 1,
        extra_args: ["--require-scheduler-evidence"]
      )

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["gate"]["reason"] == "replacement_workflow_clear"
    assert artifact["bundle_gate"]["reason"] == "scheduler_evidence_exit_nonzero"
    assert artifact["scheduler_evidence_gate"]["evidence_exit_status"] == 1
  end

  test "unparseable scheduler evidence output fails closed" do
    artifact_path = artifact_path("scheduler-evidence-unparseable")

    {:error, _result} =
      run_rehearsal(clear_workflow(), 0, artifact_path,
        evidence_output: "not json\n",
        evidence_exit_status: 0,
        extra_args: ["--require-scheduler-evidence"]
      )

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["scheduler_evidence"] == nil
    assert artifact["scheduler_evidence_gate"]["reason"] == "scheduler_evidence_json_unparseable"
    assert artifact["bundle_gate"]["reason"] == "scheduler_evidence_json_unparseable"
  end

  test "workflow blocker remains authoritative while scheduler evidence is still archived" do
    workflow = %{
      "status" => "blocked",
      "phase" => "rebalance_closure",
      "blockers" => ["routing_mismatch"],
      "next_action" => "mix maxio.rebalance.start --json"
    }

    evidence = %{"status" => "ok", "warnings" => [], "blockers" => []}
    artifact_path = artifact_path("workflow-blocked-with-evidence")

    {:error, result} =
      run_rehearsal(workflow, 1, artifact_path,
        evidence: evidence,
        evidence_exit_status: 0,
        extra_args: ["--require-scheduler-evidence"]
      )

    assert result.exit_code == 1
    assert_received {:evidence_args, _args, [stderr_to_stdout: true]}

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["gate"]["reason"] == "workflow_exit_nonzero"
    assert artifact["bundle_gate"]["reason"] == "workflow_exit_nonzero"
    assert artifact["scheduler_evidence"] == evidence
    assert artifact["scheduler_evidence_gate"]["status"] == "ok"
  end

  test "scheduler evidence options require the explicit bundle flag" do
    {:error, result} =
      ReplacementLiveRehearsal.run(
        base_args(artifact_path("bad-evidence-args")) ++
          ["--scheduler-evidence-since-minutes", "5"]
      )

    assert result.exit_code == 64
    assert result.stderr =~ "scheduler evidence options require --require-scheduler-evidence"
  end

  defp run_rehearsal(workflow, exit_status, artifact_path, opts \\ []) do
    owner = self()
    evidence = Keyword.get(opts, :evidence, :not_expected)
    evidence_exit_status = Keyword.get(opts, :evidence_exit_status, 0)
    evidence_output = Keyword.get(opts, :evidence_output)

    runner = fn "fake-mix", args, opts ->
      case List.first(args) do
        "maxio.replacement.workflow" ->
          send(owner, {:workflow_args, args, opts})
          {Jason.encode!(workflow) <> "\n", exit_status}

        "maxio.scheduler.evidence" when evidence != :not_expected ->
          send(owner, {:evidence_args, args, opts})
          {Jason.encode!(evidence) <> "\n", evidence_exit_status}

        "maxio.scheduler.evidence" when is_binary(evidence_output) ->
          send(owner, {:evidence_args, args, opts})
          {evidence_output, evidence_exit_status}

        "maxio.scheduler.evidence" ->
          flunk("scheduler evidence should not run without --require-scheduler-evidence")
      end
    end

    ReplacementLiveRehearsal.run(base_args(artifact_path) ++ Keyword.get(opts, :extra_args, []),
      command_runner: runner,
      git_sha_fun: fn -> "test-sha" end,
      now_fun: fn -> @now end
    )
  end

  defp clear_workflow do
    %{
      "status" => "ok",
      "phase" => "audit",
      "blockers" => [],
      "next_action" => "none"
    }
  end

  defp scheduler_evidence_args do
    [
      "--require-scheduler-evidence",
      "--scheduler-evidence-scheduler",
      "rebalance",
      "--scheduler-evidence-from",
      "2026-06-14T00:00:00Z",
      "--scheduler-evidence-until",
      "2026-06-14T00:10:00Z",
      "--scheduler-evidence-window-minutes",
      "5",
      "--scheduler-evidence-expected-nodes",
      "node_a,node_b",
      "--scheduler-evidence-expected-interval-ms",
      "60000",
      "--scheduler-evidence-stale-after-ms",
      "120000",
      "--scheduler-evidence-min-effective-nodes",
      "1",
      "--scheduler-evidence-require-lock-loser",
      "--scheduler-evidence-require-rollups"
    ]
  end

  defp base_args(artifact_path) do
    [
      "--artifact",
      artifact_path,
      "--mix-cmd",
      "fake-mix"
    ]
  end

  defp artifact_path(name) do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_replacement_live_rehearsal_#{System.unique_integer([:positive])}"
      )

    Path.join(base, "#{name}.json")
  end
end
