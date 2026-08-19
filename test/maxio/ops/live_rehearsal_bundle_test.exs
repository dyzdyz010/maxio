defmodule Maxio.Ops.LiveRehearsalBundleTest do
  use ExUnit.Case, async: true

  alias Maxio.Ops.LiveRehearsalBundle

  @now ~U[2026-07-04 14:00:00Z]

  test "report-only bundle writes replacement, scheduler, gate, and bundle artifacts" do
    {:ok, result} = run_bundle(ok_responses())

    assert result.exit_code == 0
    assert result.gate_status == "ok"
    assert result.stdout =~ "gate_status=ok"
    refute result.stderr

    artifact = result.artifact
    assert artifact["evidence_kind"] == "p0_ops_live_rehearsal_bundle"
    assert artifact["scenario"] == "p0_ops_1_rehearsal_bundle"
    assert artifact["generated_at"] == "2026-07-04T14:00:00Z"
    assert artifact["git_sha"] == "test-sha"
    assert artifact["replacement_mode"] == "dry_run"
    assert artifact["replacement_rehearsal_ready?"] == true

    paths = artifact["artifact_paths"]
    assert File.exists?(paths["replacement_live_rehearsal"])
    assert File.exists?(paths["scheduler_live_rehearsal"])
    assert File.exists?(paths["ops_gate"])
    assert File.exists?(paths["bundle"])

    gate_artifact = paths["ops_gate"] |> File.read!() |> Jason.decode!()
    assert gate_artifact["gate_status"] == "ok"

    assert gate_artifact["counts"] == %{
             "attention" => 0,
             "blocked" => 0,
             "error" => 0,
             "ok" => 6,
             "total" => 6
           }

    assert gate_artifact["ops_evidence_matrix"]["missing_rehearsal_kinds"] == []

    assert artifact["child_results"]["replacement_live_rehearsal"]["status"] == "ok"
    assert artifact["child_results"]["scheduler_live_rehearsal"]["status"] == "ok"
    assert artifact["child_results"]["ops_gate"]["status"] == "ok"

    assert_received {:cmd, ["maxio.replacement.workflow" | replacement_args],
                     [stderr_to_stdout: true]}

    assert "--dry-run" in replacement_args
    assert "--rehearsal-ready" in replacement_args
    assert "--allow-dry-run-success" not in replacement_args

    assert artifact["commands"]["ops_gate"] =~ "--replacement-rehearsal-ready"

    automation_check =
      Enum.find(gate_artifact["checks"], &(&1["id"] == "replacement_automation_status"))

    assert automation_check["status"] == "ok"
    assert automation_check["parsed_output"]["status"] == "ready"
    assert automation_check["parsed_output"]["blockers"] == []

    refute_received {:cmd, ["maxio.replacement.automation_status", "--json", "--rehearsal-ready"],
                     [stderr_to_stdout: true]}

    assert_received {:cmd, ["maxio.replacement.workflow", "--json", "--rehearsal-ready"],
                     [stderr_to_stdout: true]}

    assert_received {:cmd, ["maxio.scheduler.evidence" | scheduler_args],
                     [stderr_to_stdout: true]}

    assert "--from" in scheduler_args
    assert "2026-07-04T12:00:00Z" in scheduler_args
    assert "--until" in scheduler_args
    assert "2026-07-04T14:00:00Z" in scheduler_args
  end

  test "blocked scheduler rehearsal still produces a real p0 gate artifact by default" do
    responses =
      ok_responses()
      |> Map.put("maxio.scheduler.evidence", {Jason.encode!(blocked_evidence()) <> "\n", 1})

    {:ok, result} = run_bundle(responses)

    assert result.exit_code == 0
    assert result.gate_status == "blocked"
    assert result.stdout =~ "scheduler_exit=1"

    gate_artifact =
      result.artifact["artifact_paths"]["ops_gate"] |> File.read!() |> Jason.decode!()

    assert gate_artifact["gate_status"] == "blocked"
    assert gate_artifact["ops_evidence_matrix"]["missing_rehearsal_kinds"] == []

    refute Enum.any?(
             gate_artifact["checks"],
             &(&1["id"] == "required_rehearsal_kind_scheduler_live_rehearsal")
           )

    scheduler_check =
      Enum.find(gate_artifact["checks"], &(&1["evidence_kind"] == "scheduler_live_rehearsal"))

    assert scheduler_check["status"] == "blocked"
    assert [%{"reason" => "scheduler_evidence_status_blocked"}] = scheduler_check["blockers"]
  end

  test "replacement-live mode does not use rehearsal-ready overrides" do
    {:ok, result} = run_bundle(ok_responses(), ["--replacement-live"])

    assert result.exit_code == 0
    assert result.artifact["replacement_mode"] == "live"
    assert result.artifact["replacement_rehearsal_ready?"] == false
    refute result.artifact["commands"]["ops_gate"] =~ "--replacement-rehearsal-ready"

    assert_received {:cmd, ["maxio.replacement.workflow" | replacement_args],
                     [stderr_to_stdout: true]}

    refute "--dry-run" in replacement_args
    refute "--allow-dry-run-success" in replacement_args
    refute "--rehearsal-ready" in replacement_args

    assert_received {:cmd, ["maxio.replacement.automation_status", "--json"],
                     [stderr_to_stdout: true]}

    assert_received {:cmd, ["maxio.replacement.workflow", "--json"], [stderr_to_stdout: true]}
  end

  test "fail-on-gate turns a blocked p0 bundle into a non-zero result" do
    responses =
      ok_responses()
      |> Map.put("maxio.scheduler.evidence", {Jason.encode!(blocked_evidence()) <> "\n", 1})

    {:error, result} = run_bundle(responses, ["--fail-on-gate"])

    assert result.exit_code == 1
    assert result.gate_status == "blocked"
    assert result.stderr =~ "gate failed: blocked"
    assert File.exists?(result.artifact["artifact_paths"]["bundle"])
    assert File.exists?(result.artifact["artifact_paths"]["ops_gate"])
  end

  test "scheduler-enabled bundle uses bounded scheduler rehearsal artifact" do
    owner = self()

    scheduler_enabled_runner = fn args, _opts ->
      send(owner, {:scheduler_enabled_args, args})
      artifact_path = arg_after(args, "--artifact")

      artifact = %{
        "version" => 1,
        "evidence_kind" => "scheduler_live_rehearsal",
        "scenario" => "scheduler_enabled_multinode_rehearsal",
        "scheduler" => "all",
        "evidence_exit_status" => 0,
        "scheduler_evidence" => %{"status" => "ok", "warnings" => [], "blockers" => []}
      }

      File.mkdir_p!(Path.dirname(artifact_path))
      File.write!(artifact_path, Jason.encode!(artifact) <> "\n")

      {:ok,
       %{
         exit_code: 0,
         artifact_path: artifact_path,
         artifact: artifact,
         stdout: "[maxio scheduler.enabled_rehearsal] status=ok\n"
       }}
    end

    {:ok, result} =
      run_bundle(
        ok_responses(),
        ["--scheduler-enabled", "--scheduler", "all", "--require-lock-loser"],
        scheduler_enabled_runner: scheduler_enabled_runner
      )

    assert result.exit_code == 0
    assert result.gate_status == "ok"
    assert result.artifact["scheduler_mode"] == "enabled_rehearsal"
    assert result.artifact["scheduler"] == "all"

    assert result.artifact["commands"]["scheduler_live_rehearsal"] =~
             "scripts/m8_scheduler_enabled_rehearsal.exs"

    assert_received {:scheduler_enabled_args, args}
    assert "--nodes" in args
    assert "node_a,node_b" in args
    refute "--from" in args
    refute "--until" in args
    assert "--require-lock-loser" in args

    scheduler_artifact =
      result.artifact["artifact_paths"]["scheduler_live_rehearsal"]
      |> File.read!()
      |> Jason.decode!()

    assert scheduler_artifact["scenario"] == "scheduler_enabled_multinode_rehearsal"
  end

  test "non-map child rehearsal result is counted as a failure instead of crashing the bundle" do
    # 通过既有的注入缝驱动一个**非 map** 的子任务结果：`capture_result/1` 必须把它归一成
    # exit_code=1 的失败结果，bundle 继续产出制品，而不是在 `result_view/1` / `result_field/3`
    # 里 BadMapError 炸掉整个编排（AGENTS.md §3 失败按失败计）。
    # 注意这里子任务返回的是 `{:ok, ...}`：制品里的 `status` 必须跟着 `exit_code` 一起降级成
    # `"error"`，不能出现 `"status" => "ok"` 配 `"exit_code" => 1` 的自相矛盾记录。
    scheduler_enabled_runner = fn _args, _opts -> {:ok, :not_a_map} end

    {:error, result} =
      run_bundle(
        ok_responses(),
        ["--scheduler-enabled", "--scheduler", "all"],
        scheduler_enabled_runner: scheduler_enabled_runner
      )

    scheduler_view = result.artifact["child_results"]["scheduler_live_rehearsal"]

    assert scheduler_view["status"] == "error"
    assert scheduler_view["exit_code"] == 1
    assert scheduler_view["stderr"] =~ "unexpected child result"
    assert scheduler_view["stderr"] =~ ":not_a_map"
    assert scheduler_view["artifact_path"] == nil
    assert result.exit_code == 1
    assert result.gate_status == "error"
    assert result.stdout =~ "scheduler_exit=1"
    assert File.exists?(result.artifact["artifact_paths"]["bundle"])
  end

  test "scheduler-enabled requires at least two expected nodes before running children" do
    {:error, result} =
      LiveRehearsalBundle.run([
        "--scheduler-enabled"
      ])

    assert result.exit_code == 64

    assert result.stderr =~
             "--scheduler-enabled requires --expected-nodes with at least two node names"
  end

  test "replacement arg cannot override bundle-controlled artifact or mix command" do
    {:error, result} =
      LiveRehearsalBundle.run([
        "--replacement-arg=--artifact"
      ])

    assert result.exit_code == 64
    assert result.stderr =~ "--replacement-arg cannot override --artifact or --mix-cmd"
  end

  test "unsafe run ids and bundle artifact paths are rejected before writing" do
    {:error, run_id_result} =
      LiveRehearsalBundle.run([
        "--run-id",
        "../outside"
      ])

    assert run_id_result.exit_code == 64
    assert run_id_result.stderr =~ "--run-id must be a safe file name segment"

    {:error, artifact_result} =
      LiveRehearsalBundle.run([
        "--artifact-dir",
        "tmp/maxio_ops_bundle_path_safety",
        "--artifact",
        "../outside.json"
      ])

    assert artifact_result.exit_code == 64
    assert artifact_result.stderr =~ "--artifact cannot contain parent directory segments"
  end

  defp run_bundle(responses, extra_args \\ [], opts \\ []) do
    owner = self()

    runner = fn "fake-mix", cmd_args, opts ->
      send(owner, {:cmd, cmd_args, opts})

      case Map.fetch!(responses, List.first(cmd_args)) do
        {output, status} -> {output, status}
        response -> {Jason.encode!(response) <> "\n", 0}
      end
    end

    LiveRehearsalBundle.run(
      base_args() ++ extra_args,
      [
        command_runner: runner,
        git_sha_fun: fn -> "test-sha" end,
        now_fun: fn -> @now end
      ] ++ opts
    )
  end

  defp arg_after(args, flag) do
    index = Enum.find_index(args, &(&1 == flag))
    Enum.at(args, index + 1)
  end

  defp base_args do
    [
      "--artifact-dir",
      artifact_dir(),
      "--run-id",
      "p0-ops-2-test",
      "--mix-cmd",
      "fake-mix",
      "--expected-nodes",
      "node_a,node_b"
    ]
  end

  defp artifact_dir do
    Path.join("tmp", "maxio_ops_live_rehearsal_bundle_#{System.unique_integer([:positive])}")
  end

  defp ok_responses do
    %{
      "maxio.replacement.workflow" => %{
        "status" => "ok",
        "phase" => "audit",
        "blockers" => [],
        "warnings" => [],
        "next_action" => "none"
      },
      "maxio.scheduler.evidence" => %{
        "status" => "ok",
        "warnings" => [],
        "blockers" => []
      },
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
      "maxio.rebalance.workflow" => %{
        "status" => "not_started",
        "gate_status" => "ok",
        "blockers" => [],
        "warnings" => []
      }
    }
  end

  defp blocked_evidence do
    %{
      "status" => "blocked",
      "warnings" => [],
      "blockers" => [%{"reason" => "missing_expected_nodes"}]
    }
  end
end
