defmodule Maxio.Ops.ReleaseReadinessBundleTest do
  use ExUnit.Case, async: true

  alias Maxio.Ops.ReleaseReadinessBundle

  @now ~U[2026-07-05 06:00:00Z]

  test "builds a release readiness bundle from existing evidence without claiming full readiness" do
    artifact_path = artifact_path("ready")

    {:ok, result} =
      ReleaseReadinessBundle.run(
        ["--artifact", artifact_path],
        base_opts(
          stress_artifacts_fun: fn _opts -> [stress_artifact()] end,
          compat_artifacts_fun: fn _opts -> [] end,
          gate_artifacts_fun: fn _opts -> [ops_gate_artifact()] end,
          rehearsal_bundles_fun: fn _opts -> [rehearsal_artifact()] end,
          external_probe_fun: fn -> external_probe("attention") end,
          git_status_fun: fn -> {:ok, " M lib/maxio/example.ex\n?? scratch.exs\n"} end,
          status_files_fun: fn ->
            "Full closeout verification: mix precommit -> 3386 tests, 0 failures, 5 excluded."
          end
        )
      )

    assert result.exit_code == 0
    assert result.gate_status == "attention"
    assert result.stdout =~ "[maxio release.readiness] gate_status=attention"

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["evidence_kind"] == "release_readiness_bundle"
    assert artifact["scenario"] == "local_release_readiness_evidence"
    assert artifact["counts"]["total"] == 7

    checks = Map.new(artifact["checks"], &{&1["id"], &1})
    assert checks["stress_campaign"]["status"] == "ok"
    assert checks["compat_matrix"]["status"] == "attention"
    assert checks["compat_matrix"]["source"] == "embedded_stress_campaign_matrix"
    assert checks["ops_gate"]["status"] == "ok"
    assert checks["rehearsal_bundle"]["status"] == "ok"
    assert checks["external_clients"]["status"] == "attention"
    assert checks["worktree"]["status"] == "attention"
    assert checks["precommit_evidence"]["status"] == "attention"

    reasons = Enum.map(artifact["warnings"], & &1["reason"])
    assert "compat_matrix_embedded_only" in reasons
    assert "worktree_dirty" in reasons
    assert "docs_only_precommit_evidence" in reasons
  end

  test "missing artifacts and precommit evidence are explicit blockers or attention" do
    {:ok, result} =
      ReleaseReadinessBundle.run(
        [],
        base_opts(
          stress_artifacts_fun: fn _opts -> [] end,
          compat_artifacts_fun: fn _opts -> [] end,
          gate_artifacts_fun: fn _opts -> [] end,
          rehearsal_bundles_fun: fn _opts -> [] end,
          external_probe_fun: fn -> external_probe("ok") end,
          git_status_fun: fn -> {:ok, ""} end,
          status_files_fun: fn -> "no precommit evidence here" end
        )
      )

    assert result.gate_status == "blocked"

    checks = Map.new(result.artifact["checks"], &{&1["id"], &1})
    assert checks["stress_campaign"]["status"] == "attention"
    assert checks["compat_matrix"]["status"] == "attention"
    assert checks["ops_gate"]["status"] == "attention"
    assert checks["rehearsal_bundle"]["status"] == "attention"
    assert checks["precommit_evidence"]["status"] == "blocked"

    assert [%{"entry" => "precommit_evidence", "reason" => "missing_precommit_evidence"}] =
             result.artifact["blockers"]
  end

  test "strict mode fails on attention after writing the artifact" do
    artifact_path = artifact_path("strict")

    {:error, result} =
      ReleaseReadinessBundle.run(
        ["--artifact", artifact_path, "--strict"],
        base_opts(
          stress_artifacts_fun: fn _opts -> [stress_artifact()] end,
          compat_artifacts_fun: fn _opts -> [] end,
          gate_artifacts_fun: fn _opts -> [ops_gate_artifact()] end,
          rehearsal_bundles_fun: fn _opts -> [rehearsal_artifact()] end,
          external_probe_fun: fn -> external_probe("attention") end,
          git_status_fun: fn -> {:ok, ""} end,
          status_files_fun: fn -> "mix precommit -> 3386 tests, 0 failures, 5 excluded" end
        )
      )

    assert result.exit_code == 1
    assert result.gate_status == "attention"
    assert result.stderr =~ "gate failed"
    assert File.exists?(artifact_path)
  end

  test "blocked child artifact fails when fail-on-blocked is explicit" do
    blocked_stress =
      stress_artifact()
      |> Map.put(:gate_status, "blocked")
      |> Map.put(:blockers, [%{"reason" => "stress_failed"}])
      |> put_in([:raw, "gate_status"], "blocked")
      |> put_in([:raw, "blockers"], [%{"reason" => "stress_failed"}])

    {:error, result} =
      ReleaseReadinessBundle.run(
        ["--fail-on-blocked"],
        base_opts(
          stress_artifacts_fun: fn _opts -> [blocked_stress] end,
          compat_artifacts_fun: fn _opts -> [] end,
          gate_artifacts_fun: fn _opts -> [ops_gate_artifact()] end,
          rehearsal_bundles_fun: fn _opts -> [rehearsal_artifact()] end,
          external_probe_fun: fn -> external_probe("ok") end,
          git_status_fun: fn -> {:ok, ""} end,
          status_files_fun: fn -> "mix precommit -> 3386 tests, 0 failures, 5 excluded" end
        )
      )

    assert result.gate_status == "blocked"
    assert result.exit_code == 1

    assert Enum.any?(
             result.artifact["blockers"],
             &(&1["entry"] == "stress_campaign" and &1["reason"] == "stress_failed")
           )
  end

  test "required external clients are blocked when probes are skipped" do
    {:error, result} =
      ReleaseReadinessBundle.run(
        ["--skip-external-probes", "--require-external-clients", "--fail-on-blocked"],
        base_opts(
          stress_artifacts_fun: fn _opts -> [stress_artifact()] end,
          compat_artifacts_fun: fn _opts -> [] end,
          gate_artifacts_fun: fn _opts -> [ops_gate_artifact()] end,
          rehearsal_bundles_fun: fn _opts -> [rehearsal_artifact()] end,
          external_probe_fun: fn -> raise "external probe should be skipped" end,
          git_status_fun: fn -> {:ok, ""} end,
          status_files_fun: fn -> "mix precommit -> 3386 tests, 0 failures, 5 excluded" end
        )
      )

    checks = Map.new(result.artifact["checks"], &{&1["id"], &1})

    assert result.gate_status == "blocked"
    assert result.exit_code == 1
    assert checks["external_clients"]["status"] == "blocked"

    assert Enum.any?(
             result.artifact["blockers"],
             &(&1["entry"] == "external_clients" and
                 &1["reason"] == "external_clients_required_but_probe_skipped")
           )
  end

  test "dirty worktree count is not capped by the artifact sample" do
    dirty_output =
      1..95
      |> Enum.map_join("\n", fn index -> " M lib/maxio/example_#{index}.ex" end)
      |> Kernel.<>("\n")

    {:ok, result} =
      ReleaseReadinessBundle.run(
        [],
        base_opts(
          stress_artifacts_fun: fn _opts -> [stress_artifact()] end,
          compat_artifacts_fun: fn _opts -> [] end,
          gate_artifacts_fun: fn _opts -> [ops_gate_artifact()] end,
          rehearsal_bundles_fun: fn _opts -> [rehearsal_artifact()] end,
          external_probe_fun: fn -> external_probe("ok") end,
          git_status_fun: fn -> {:ok, dirty_output} end,
          status_files_fun: fn -> "mix precommit -> 3386 tests, 0 failures, 5 excluded" end
        )
      )

    checks = Map.new(result.artifact["checks"], &{&1["id"], &1})
    worktree = checks["worktree"]

    assert worktree["status"] == "attention"
    assert worktree["detail"]["changed_count"] == 95
    assert length(worktree["detail"]["sample"]) == 80

    assert Enum.any?(
             result.artifact["warnings"],
             &(&1["entry"] == "worktree" and &1["detail"]["changed_count"] == 95)
           )
  end

  test "precommit evidence prefers the newest docs occurrence" do
    status_text = """
    ## Latest Batch Update
    Full closeout verification: mix precommit -> 3386 tests, 0 failures, 5 excluded.

    ## Historical Batch Update
    Full closeout verification: mix precommit -> 3363 tests, 0 failures, 5 excluded.
    """

    {:ok, result} =
      ReleaseReadinessBundle.run(
        [],
        base_opts(
          stress_artifacts_fun: fn _opts -> [stress_artifact()] end,
          compat_artifacts_fun: fn _opts -> [] end,
          gate_artifacts_fun: fn _opts -> [ops_gate_artifact()] end,
          rehearsal_bundles_fun: fn _opts -> [rehearsal_artifact()] end,
          external_probe_fun: fn -> external_probe("ok") end,
          git_status_fun: fn -> {:ok, ""} end,
          status_files_fun: fn -> status_text end
        )
      )

    checks = Map.new(result.artifact["checks"], &{&1["id"], &1})
    precommit = checks["precommit_evidence"]

    assert precommit["detail"]["tests"] == 3386
    assert precommit["detail"]["summary"] =~ "3386 tests"
    refute precommit["detail"]["summary"] =~ "3363 tests"
  end

  test "external client details summarize warning executables without local paths" do
    local_python = "C:\\Program Files\\Python311\\python.exe"

    {:ok, result} =
      ReleaseReadinessBundle.run(
        [],
        base_opts(
          stress_artifacts_fun: fn _opts -> [stress_artifact()] end,
          compat_artifacts_fun: fn _opts -> [] end,
          gate_artifacts_fun: fn _opts -> [ops_gate_artifact()] end,
          rehearsal_bundles_fun: fn _opts -> [rehearsal_artifact()] end,
          external_probe_fun: fn -> external_probe_with_path(local_python) end,
          git_status_fun: fn -> {:ok, ""} end,
          status_files_fun: fn -> "mix precommit -> 3386 tests, 0 failures, 5 excluded" end
        )
      )

    checks = Map.new(result.artifact["checks"], &{&1["id"], &1})
    external_clients = checks["external_clients"]
    [client] = external_clients["detail"]["clients"]

    assert client["executable"] == "python.exe"

    encoded = Jason.encode!(result.artifact)
    assert encoded =~ "python.exe"
    refute encoded =~ "C:"
    refute encoded =~ "Program Files"
    refute encoded =~ "moonl"
    refute encoded =~ "Python311"
  end

  test "json output emits the release readiness artifact" do
    {:ok, result} =
      ReleaseReadinessBundle.run(
        ["--json"],
        base_opts(
          stress_artifacts_fun: fn _opts -> [stress_artifact()] end,
          compat_artifacts_fun: fn _opts -> [] end,
          gate_artifacts_fun: fn _opts -> [ops_gate_artifact()] end,
          rehearsal_bundles_fun: fn _opts -> [rehearsal_artifact()] end,
          external_probe_fun: fn -> external_probe("ok") end,
          git_status_fun: fn -> {:ok, ""} end,
          status_files_fun: fn -> "mix precommit -> 3386 tests, 0 failures, 5 excluded" end
        )
      )

    decoded = Jason.decode!(result.stdout)
    assert decoded["evidence_kind"] == "release_readiness_bundle"
    assert decoded["checks"] |> Enum.map(& &1["id"]) |> Enum.member?("stress_campaign")
  end

  defp base_opts(overrides) do
    Keyword.merge(
      [
        now_fun: fn -> @now end,
        git_sha_fun: fn -> "test-sha" end,
        artifact_writer: &write_artifact!/2
      ],
      overrides
    )
  end

  defp stress_artifact do
    matrix = %{
      "generated_at" => "2026-07-05T05:30:00Z",
      "run_id" => "matrix-run",
      "git_sha" => "test-sha",
      "gate_status" => "ok",
      "counts" => %{"total" => 3, "ok" => 3, "attention" => 0, "blocked" => 0, "error" => 0},
      "blockers" => [],
      "warnings" => []
    }

    %{
      status: "ok",
      file_name: "p2_stress_local.json",
      generated_at: "2026-07-05T05:29:00Z",
      run_id: "stress-run",
      git_sha: "test-sha",
      gate_status: "ok",
      counts: %{"total" => 3, "ok" => 3, "attention" => 0, "blocked" => 0, "error" => 0},
      blockers: [],
      warnings: [],
      raw: %{
        "evidence_kind" => "stress_campaign",
        "generated_at" => "2026-07-05T05:29:00Z",
        "gate_status" => "ok",
        "matrix" => matrix
      }
    }
  end

  defp ops_gate_artifact do
    %{
      status: "ok",
      file_name: "m8_ops_gate_ready.json",
      generated_at: "2026-07-05T05:31:00Z",
      run_id: "gate-run",
      git_sha: "test-sha",
      gate_status: "ok",
      counts: %{total: 2, ok: 2, attention: 0, blocked: 0, error: 0},
      blockers: [],
      warnings: []
    }
  end

  defp rehearsal_artifact do
    %{
      status: "ok",
      file_name: "m8_p0_ops_live_rehearsal_ready_bundle.json",
      generated_at: "2026-07-05T05:32:00Z",
      run_id: "bundle-run",
      git_sha: "test-sha",
      gate_status: "ok",
      counts: %{total: 3, ok: 3, attention: 0, blocked: 0, error: 0},
      blockers: [],
      warnings: []
    }
  end

  defp external_probe(status) do
    warnings =
      if status == "attention" do
        [
          %{
            "entry" => "aws_cli",
            "kind" => "external_client",
            "reason" => "external_client_not_configured"
          }
        ]
      else
        []
      end

    %{
      artifact: %{
        "gate_status" => status,
        "blockers" => [],
        "warnings" => warnings,
        "external_clients" => [
          %{"id" => "aws_cli", "status" => status, "warnings" => warnings, "blockers" => []}
        ]
      }
    }
  end

  defp external_probe_with_path(path) do
    warning = %{
      "entry" => "python_boto3",
      "kind" => "external_client",
      "reason" => "external_client_probe_failed",
      "executable" => path,
      "detail" => "boto3 import failed from #{path}"
    }

    %{
      artifact: %{
        "gate_status" => "attention",
        "blockers" => [],
        "warnings" => [warning],
        "external_clients" => [
          %{
            "id" => "python_boto3",
            "label" => "python-boto3",
            "mode" => "external_availability",
            "status" => "attention",
            "path" => "nil",
            "detail" => "checked #{path}",
            "warnings" => [warning],
            "blockers" => []
          }
        ]
      }
    }
  end

  defp artifact_path(name) do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_release_readiness_test_#{System.unique_integer([:positive])}"
      )

    Path.join(base, "#{name}.json")
  end

  defp write_artifact!(path, artifact) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(artifact))
  end
end
