defmodule Maxio.Cluster.SchedulerEnabledRehearsalTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.SchedulerEnabledRehearsal

  @now ~U[2026-07-04 14:00:30Z]

  test "all scheduler rehearsal records scheduled ok and lock loser evidence" do
    artifact_path = artifact_path("all-ok")

    {:ok, result} =
      SchedulerEnabledRehearsal.run(
        [
          "--scheduler",
          "all",
          "--nodes",
          "node_a,node_b",
          "--window-minutes",
          "1",
          "--expected-interval-ms",
          "60000",
          "--stale-after-ms",
          "120000",
          "--min-effective-nodes",
          "1",
          "--require-lock-loser",
          "--require-rollups",
          "--artifact",
          artifact_path
        ],
        now_fun: fn -> @now end,
        git_sha_fun: fn -> "test-sha" end
      )

    assert result.exit_code == 0
    assert result.stdout =~ "status=ok"
    refute result.stderr

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["evidence_kind"] == "scheduler_live_rehearsal"
    assert artifact["scenario"] == "scheduler_enabled_multinode_rehearsal"
    assert artifact["scheduler"] == "all"
    assert artifact["schedulers"] == ["fresh_drive_heal", "rebalance"]
    assert artifact["nodes"] == ["node_a", "node_b"]
    assert artifact["from"] == "2026-07-04T13:59:00.000Z"
    assert artifact["until"] == "2026-07-04T14:00:00.000Z"
    assert artifact["evidence_exit_status"] == 0
    assert artifact["scheduler_evidence"]["status"] == "ok"
    assert artifact["scheduler_evidence"]["blockers"] == []
    assert artifact["scheduler_evidence"]["warnings"] == []

    assert [%{"status" => "ok"}, %{"status" => "ok"}] = artifact["rollups"]

    schedulers_by_name =
      Map.new(artifact["scheduler_evidence"]["schedulers"], &{&1["scheduler"], &1})

    for scheduler <- ["fresh_drive_heal", "rebalance"] do
      evidence = Map.fetch!(schedulers_by_name, scheduler)
      assert evidence["status"] == "ok"
      assert evidence["scheduled_nodes"] == ["node_a", "node_b"]
      assert evidence["effective_scheduled_nodes"] == ["node_a"]
      assert evidence["lock_loser_nodes"] == ["node_b"]
      assert evidence["lock_loser_evidence_met?"]
      assert evidence["rollup_coverage"]["status"] == "ready"
    end
  end

  test "single scheduler rehearsal writes a scheduler_live_rehearsal artifact" do
    artifact_path = artifact_path("fresh")

    {:ok, result} =
      SchedulerEnabledRehearsal.run(
        [
          "--scheduler",
          "fresh_drive_heal",
          "--nodes",
          "fresh_a,fresh_b",
          "--window-minutes",
          "1",
          "--require-lock-loser",
          "--artifact",
          artifact_path
        ],
        now_fun: fn -> @now end,
        git_sha_fun: fn -> "test-sha" end
      )

    assert result.exit_code == 0

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["scheduler"] == "fresh_drive_heal"
    assert [%{"scheduler" => "fresh_drive_heal", "status" => "ok"}] = artifact["scheduler_runs"]
    assert [scheduler] = artifact["scheduler_evidence"]["schedulers"]
    assert scheduler["scheduler"] == "fresh_drive_heal"
    assert scheduler["effective_scheduled_nodes"] == ["fresh_a"]
    assert scheduler["lock_loser_nodes"] == ["fresh_b"]
  end

  test "invalid scheduler and node arguments fail closed before writing" do
    {:error, scheduler_result} =
      SchedulerEnabledRehearsal.run([
        "--scheduler",
        "bad",
        "--artifact",
        artifact_path("bad-scheduler")
      ])

    assert scheduler_result.exit_code == 64
    assert scheduler_result.stderr =~ "--scheduler must be fresh_drive_heal, rebalance, or all"

    path = artifact_path("bad-nodes")

    {:error, node_result} =
      SchedulerEnabledRehearsal.run([
        "--nodes",
        "node_a",
        "--artifact",
        path
      ])

    assert node_result.exit_code == 64
    assert node_result.stderr =~ "--nodes must contain at least two node names"
    refute File.exists?(path)
  end

  defp artifact_path(name) do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_scheduler_enabled_rehearsal_#{System.unique_integer([:positive])}"
      )

    Path.join(base, "#{name}.json")
  end
end
