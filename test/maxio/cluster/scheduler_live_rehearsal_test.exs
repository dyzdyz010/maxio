defmodule Maxio.Cluster.SchedulerLiveRehearsalTest do
  use ExUnit.Case, async: true

  alias Maxio.Cluster.SchedulerLiveRehearsal

  @now ~U[2026-06-14 12:00:00Z]

  test "ok evidence writes an artifact and exits successfully" do
    evidence = %{"status" => "ok", "warnings" => [], "blockers" => []}
    artifact_path = artifact_path("ok")

    {:ok, result} = run_rehearsal(evidence, 0, artifact_path)

    assert result.exit_code == 0
    assert result.artifact_path == artifact_path
    assert result.stdout =~ "evidence_status=ok"
    assert result.stdout =~ "evidence_exit=0"
    refute Map.has_key?(result, :stderr)

    assert_received {:evidence_args, args, [stderr_to_stdout: true]}
    assert "maxio.scheduler.evidence" in args
    assert "--fail-on-attention" in args
    assert "--json" in args

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["evidence_kind"] == "scheduler_live_rehearsal"
    assert artifact["scenario"] == "scheduler_evidence_rehearsal"
    assert artifact["generated_at"] == "2026-06-14T12:00:00Z"
    assert artifact["git_sha"] == "test-sha"
    assert artifact["scheduler"] == "rebalance"
    assert artifact["expected_nodes"] == ["node_a", "node_b"]
    assert artifact["evidence_exit_status"] == 0
    assert artifact["scheduler_evidence"] == evidence
    assert artifact["raw_output"] =~ ~s("status":"ok")
    assert artifact["commands"]["evidence"] =~ "--fail-on-attention"
  end

  test "attention evidence fails closed and still writes an artifact" do
    evidence = %{
      "status" => "attention",
      "warnings" => [%{"reason" => "blocked_runs_seen"}],
      "blockers" => []
    }

    artifact_path = artifact_path("attention")

    {:error, result} = run_rehearsal(evidence, 1, artifact_path)

    assert result.exit_code == 1
    assert result.stdout =~ "evidence_status=attention"
    assert result.stdout =~ "evidence_exit=1"
    assert result.stderr =~ "evidence gate failed"

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["evidence_exit_status"] == 1
    assert artifact["scheduler_evidence"] == evidence
  end

  test "blocked evidence fails closed and keeps the blocker artifact" do
    evidence = %{
      "status" => "blocked",
      "warnings" => [],
      "blockers" => [%{"reason" => "missing_expected_nodes"}]
    }

    artifact_path = artifact_path("blocked")

    {:error, result} = run_rehearsal(evidence, 1, artifact_path)

    assert result.exit_code == 1
    assert result.stdout =~ "evidence_status=blocked"
    assert result.stderr =~ "evidence gate failed"

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["scheduler_evidence"]["blockers"] == [%{"reason" => "missing_expected_nodes"}]
  end

  test "evidence command exceptions still write a fail-closed artifact" do
    artifact_path = artifact_path("command-exception")

    runner = fn "fake-mix", _args, _opts ->
      raise "scheduler boom"
    end

    {:error, result} =
      SchedulerLiveRehearsal.run(base_args(artifact_path),
        command_runner: runner,
        git_sha_fun: fn -> "test-sha" end,
        now_fun: fn -> @now end
      )

    assert result.exit_code == 1
    assert result.stderr =~ "evidence gate failed"

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["evidence_exit_status"] == nil
    assert artifact["scheduler_evidence"] == nil
    assert artifact["raw_output"] =~ "scheduler boom"
  end

  defp run_rehearsal(evidence, exit_status, artifact_path) do
    owner = self()

    runner = fn "fake-mix", args, opts ->
      send(owner, {:evidence_args, args, opts})
      {Jason.encode!(evidence) <> "\n", exit_status}
    end

    SchedulerLiveRehearsal.run(base_args(artifact_path),
      command_runner: runner,
      git_sha_fun: fn -> "test-sha" end,
      now_fun: fn -> @now end
    )
  end

  defp base_args(artifact_path) do
    [
      "--scheduler",
      "rebalance",
      "--from",
      "2026-06-14T00:00:00Z",
      "--until",
      "2026-06-14T00:10:00Z",
      "--window-minutes",
      "5",
      "--expected-nodes",
      "node_a,node_b",
      "--expected-interval-ms",
      "60000",
      "--stale-after-ms",
      "120000",
      "--min-effective-nodes",
      "1",
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
        "maxio_scheduler_live_rehearsal_#{System.unique_integer([:positive])}"
      )

    Path.join(base, "#{name}.json")
  end
end
