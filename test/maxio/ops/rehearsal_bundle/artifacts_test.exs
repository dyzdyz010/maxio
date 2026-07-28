defmodule Maxio.Ops.RehearsalBundle.ArtifactsTest do
  use ExUnit.Case, async: true

  alias Maxio.Ops.RehearsalBundle.Artifacts

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_ops_rehearsal_bundle_artifacts_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  test "lists P0 rehearsal bundles newest first and links selected gate artifacts", %{dir: dir} do
    old_gate_path = Path.join(dir, "m8_ops_gate_old.json")
    new_gate_path = Path.join(dir, "m8_ops_gate_new.json")

    write_bundle!(dir, "m8_p0_ops_live_rehearsal_old_bundle.json", %{
      "generated_at" => "2026-07-04T08:00:00Z",
      "run_id" => "old-bundle",
      "artifact_paths" => %{"ops_gate" => old_gate_path},
      "gate_status" => "ok"
    })

    write_bundle!(dir, "m8_p0_ops_live_rehearsal_new_bundle.json", %{
      "generated_at" => "2026-07-04T09:00:00Z",
      "run_id" => "new-bundle",
      "replacement_mode" => "live",
      "scheduler_mode" => "enabled_rehearsal",
      "scheduler" => "all",
      "artifact_paths" => %{
        "replacement_live_rehearsal" => Path.join(dir, "replacement.json"),
        "scheduler_live_rehearsal" => Path.join(dir, "scheduler.json"),
        "ops_gate" => new_gate_path,
        "bundle" => Path.join(dir, "m8_p0_ops_live_rehearsal_new_bundle.json")
      },
      "commands" => %{
        "replacement_live_rehearsal" => String.duplicate("mix maxio.replacement.workflow ", 20),
        "scheduler_live_rehearsal" => "mix maxio.scheduler.enabled_rehearsal --json",
        "ops_gate" => "mix maxio.ops.gate --ops-profile p0_ops_1"
      },
      "child_results" => %{
        "replacement_live_rehearsal" => %{
          "status" => "ok",
          "exit_code" => 0,
          "gate_status" => "ok"
        },
        "scheduler_live_rehearsal" => %{
          "status" => "ok",
          "exit_code" => 0,
          "gate_status" => "ok"
        },
        "ops_gate" => %{
          "status" => "error",
          "exit_code" => 1,
          "gate_status" => "blocked"
        }
      },
      "gate_status" => "blocked"
    })

    [new, old] = Artifacts.list_recent(dir: dir)

    assert new.run_id == "new-bundle"
    assert new.gate_status == "blocked"
    assert new.replacement_mode == "live"
    assert new.scheduler_mode == "enabled_rehearsal"
    assert new.scheduler == "all"
    assert Map.get(new.artifact_paths, "ops_gate") == new_gate_path
    assert String.length(Map.fetch!(new.commands, "replacement_live_rehearsal")) <= 160
    refute Map.has_key?(new, :path)

    assert Enum.map(new.boundary_warnings, & &1.id) == [
             "replacement-live",
             "scheduler-enabled"
           ]

    ops_gate = Enum.find(new.child_results, &(&1.id == "ops_gate"))
    assert ops_gate.status == "error"
    assert ops_gate.exit_code == "1"
    assert ops_gate.gate_status == "blocked"
    assert ops_gate.artifact_path == new_gate_path
    assert ops_gate.command =~ "maxio.ops.gate"

    assert old.run_id == "old-bundle"
    assert Artifacts.related_bundle([new, old], %{file_name: "m8_ops_gate_new.json"}) == new
    assert Artifacts.related_bundle([new, old], %{artifact_path: new_gate_path}) == new
  end

  test "invalid and non-bundle JSON are visible as invalid bundle artifacts", %{dir: dir} do
    File.write!(Path.join(dir, "m8_p0_ops_live_rehearsal_bad_bundle.json"), "{not-json")

    write_json!(dir, "m8_p0_ops_live_rehearsal_other_bundle.json", %{
      "hello" => "world"
    })

    artifacts = Artifacts.list_recent(dir: dir)

    bad = Enum.find(artifacts, &(&1.file_name == "m8_p0_ops_live_rehearsal_bad_bundle.json"))
    other = Enum.find(artifacts, &(&1.file_name == "m8_p0_ops_live_rehearsal_other_bundle.json"))

    assert bad.status == "invalid"
    assert bad.gate_status == "invalid"
    assert bad.error_reason == "json_unparseable"
    assert bad.child_results == []

    assert other.status == "invalid"
    assert other.error_reason == "not_live_rehearsal_bundle"
  end

  test "regular bundle candidate reads are bounded after stat filtering", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "m8_p0_ops_live_rehearsal_999_bundle.json"))

    write_bundle!(dir, "m8_p0_ops_live_rehearsal_001_bundle.json", %{
      "generated_at" => "2026-07-04T09:00:00Z",
      "run_id" => "visible-bundle"
    })

    [artifact] = Artifacts.list_recent(dir: dir, max_candidates: 1, limit: 10)

    assert artifact.file_name == "m8_p0_ops_live_rehearsal_001_bundle.json"
    assert artifact.run_id == "visible-bundle"
  end

  test "unsafe globs cannot escape the artifact directory", %{dir: dir} do
    write_bundle!(dir, "m8_p0_ops_live_rehearsal_inside_bundle.json", %{"run_id" => "inside"})

    outside_name = "m8_p0_ops_live_rehearsal_outside_bundle.json"
    sibling = Path.join(Path.dirname(dir), outside_name)
    write_bundle!(Path.dirname(dir), outside_name, %{"run_id" => "outside"})

    on_exit(fn -> File.rm(sibling) end)

    assert Artifacts.list_recent(dir: dir, glob: "../m8_p0_ops_live_rehearsal_*_bundle.json") ==
             []

    assert Artifacts.list_recent(
             dir: dir,
             glob: Path.join(dir, "m8_p0_ops_live_rehearsal_*_bundle.json")
           ) == []
  end

  test "oversized bundles are not read", %{dir: dir} do
    write_bundle!(dir, "m8_p0_ops_live_rehearsal_large_bundle.json", %{
      "run_id" => "large-bundle"
    })

    [artifact] = Artifacts.list_recent(dir: dir, max_bytes: 8)

    assert artifact.status == "invalid"
    assert artifact.error_reason == "artifact_too_large"
    assert artifact.run_id == nil
  end

  test "missing bundle directory returns an empty list", %{dir: dir} do
    assert Artifacts.list_recent(dir: Path.join(dir, "missing")) == []
  end

  defp write_bundle!(dir, file_name, attrs) do
    artifact =
      Map.merge(
        %{
          "schema_version" => 1,
          "evidence_kind" => "p0_ops_live_rehearsal_bundle",
          "scenario" => "p0_ops_1_rehearsal_bundle",
          "generated_at" => "2026-07-04T08:00:00Z",
          "run_id" => "test-bundle",
          "git_sha" => "test-sha",
          "node" => "nonode@nohost",
          "mix_env" => "test",
          "replacement_mode" => "dry_run",
          "replacement_rehearsal_ready?" => true,
          "scheduler_mode" => "read_only",
          "scheduler" => "rebalance",
          "artifact_paths" => %{
            "replacement_live_rehearsal" => Path.join(dir, "replacement.json"),
            "scheduler_live_rehearsal" => Path.join(dir, "scheduler.json"),
            "ops_gate" => Path.join(dir, "m8_ops_gate_test.json"),
            "bundle" => Path.join(dir, file_name)
          },
          "commands" => %{},
          "child_results" => %{},
          "gate_status" => "ok"
        },
        attrs
      )

    write_json!(dir, file_name, artifact)
  end

  defp write_json!(dir, file_name, artifact) do
    File.write!(Path.join(dir, file_name), Jason.encode!(artifact))
  end
end
