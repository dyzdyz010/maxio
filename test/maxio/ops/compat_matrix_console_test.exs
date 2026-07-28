defmodule Maxio.Ops.CompatMatrixConsoleTest do
  use ExUnit.Case, async: true

  alias Maxio.Ops.CompatMatrix.Artifacts
  alias Maxio.Ops.CompatMatrixConsole

  @now ~U[2026-07-05 00:00:00Z]

  test "normalizes selected compat artifact without leaking raw secrets or paths" do
    artifacts = artifacts_from_json([{"s3_compat_matrix_ready.json", ready_artifact()}])

    result =
      CompatMatrixConsole.load(%{},
        now: @now,
        artifacts_fun: fn _opts -> artifacts end
      )

    assert result.status == "attention"
    assert result.selected_artifact.file_name == "s3_compat_matrix_ready.json"
    assert result.artifact_provenance.status == "attention"
    assert length(result.internal_suites.rows) == 2
    assert length(result.external_clients.rows) == 1
    assert length(result.external_smoke.rows) == 1
    assert result.streaming_stress.status == "ok"
    assert result.warnings.status == "attention"
    assert result.blockers.status == "ok"

    inspected = inspect(result)
    refute inspected =~ "super-secret"
    refute inspected =~ "test-access"
    refute inspected =~ "C:/private"
  end

  test "invalid and stale artifact evidence fails closed" do
    stale =
      ready_artifact()
      |> Map.put("generated_at", "2026-06-01T00:00:00Z")
      |> Map.put("gate_status", "ok")
      |> Map.put("counts", %{
        "total" => 4,
        "ok" => 4,
        "attention" => 0,
        "blocked" => 0,
        "error" => 0
      })
      |> put_in(["external_clients", Access.at(0), "status"], "ok")
      |> put_in(["external_clients", Access.at(0), "warnings"], [])
      |> put_in(["external_smoke", Access.at(0), "status"], "ok")
      |> put_in(["external_smoke", Access.at(0), "warnings"], [])

    [artifact] = artifacts_from_json([{"s3_compat_matrix_stale.json", stale}])

    result =
      CompatMatrixConsole.load(%{},
        now: @now,
        artifact_max_age_minutes: 60,
        artifacts_fun: fn _opts -> [artifact] end
      )

    assert result.status == "blocked"
    assert result.artifact_provenance.status == "blocked"
    assert [%{reason: "stale_artifact"} | _] = result.blockers.rows
    assert Enum.any?(result.warnings.rows, &(&1.reason == "stale_artifact"))
  end

  test "counts mismatch and future timestamp are blocked" do
    future =
      ready_artifact()
      |> Map.put("generated_at", "2026-07-06T00:00:00Z")
      |> put_in(["counts", "ok"], 99)

    [artifact] = artifacts_from_json([{"s3_compat_matrix_future.json", future}])

    result =
      CompatMatrixConsole.load(%{},
        now: @now,
        artifacts_fun: fn _opts -> [artifact] end
      )

    assert result.status == "blocked"
    assert Enum.any?(result.blockers.rows, &(&1.reason == "counts_mismatch"))
    assert Enum.any?(result.blockers.rows, &(&1.reason == "future_generated_at"))
  end

  test "malformed artifact sections are blocked in the console projection" do
    malformed =
      ready_artifact()
      |> Map.put("suites", "bad")
      |> Map.put("external_clients", %{"bad" => "shape"})
      |> Map.put("external_smoke", nil)
      |> Map.put("gate_status", "ok")
      |> Map.put("counts", %{
        "total" => 0,
        "ok" => 0,
        "attention" => 0,
        "blocked" => 0,
        "error" => 0
      })

    [artifact] = artifacts_from_json([{"s3_compat_matrix_bad_shape.json", malformed}])

    result =
      CompatMatrixConsole.load(%{},
        now: @now,
        artifacts_fun: fn _opts -> [artifact] end
      )

    assert result.status == "blocked"
    assert result.artifact_provenance.status == "blocked"
    assert Enum.any?(result.blockers.rows, &(&1.reason == "malformed_section"))
  end

  test "source-qualified blocker identities preserve invalid supplement evidence" do
    artifacts =
      artifacts_from_json([
        {"s3_compat_matrix_external_phase1_list_supplement.json", supplement_artifact()}
      ])

    result =
      CompatMatrixConsole.load(%{},
        now: @now,
        artifacts_fun: fn _opts -> artifacts end
      )

    duplicate_reason_rows =
      Enum.filter(result.blockers.rows, &(&1.reason == "not_compat_matrix_artifact"))

    assert Enum.map(duplicate_reason_rows, & &1.id) == [
             "blocker-synthetic-1",
             "blocker-artifact-1"
           ]

    blocker_ids = Enum.map(result.blockers.rows, & &1.id)
    assert Enum.uniq(blocker_ids) == blocker_ids
  end

  test "source-qualified warning identities keep duplicate reasons uniquely addressable" do
    old =
      ready_artifact()
      |> Map.put("generated_at", "2026-07-04T00:00:00Z")
      |> Map.put("warnings", [%{"reason" => "selected_not_latest"}])

    artifacts =
      artifacts_from_json([
        {"s3_compat_matrix_old.json", old},
        {"s3_compat_matrix_new.json", ready_artifact()}
      ])

    result =
      CompatMatrixConsole.load(%{"artifact" => "s3_compat_matrix_old.json"},
        now: @now,
        artifacts_fun: fn _opts -> artifacts end
      )

    duplicate_reason_rows =
      Enum.filter(result.warnings.rows, &(&1.reason == "selected_not_latest"))

    assert Enum.map(duplicate_reason_rows, & &1.id) == [
             "warning-selection-1",
             "warning-artifact-1"
           ]

    warning_ids = Enum.map(result.warnings.rows, & &1.id)
    assert Enum.uniq(warning_ids) == warning_ids
  end

  test "structured display evidence does not participate in row identity" do
    structured =
      ready_artifact()
      |> Map.put("blockers", [%{"reason" => %{"code" => "structured_reason"}}])

    [artifact] = artifacts_from_json([{"s3_compat_matrix_structured.json", structured}])

    result =
      CompatMatrixConsole.load(%{},
        now: @now,
        artifacts_fun: fn _opts -> [artifact] end
      )

    assert [%{id: "blocker-artifact-1", reason: reason}] = result.blockers.rows
    assert reason =~ "structured_reason"
  end

  test "artifact query selection warnings are explicit" do
    artifacts =
      artifacts_from_json([
        {"s3_compat_matrix_old.json",
         Map.put(ready_artifact(), "generated_at", "2026-07-04T00:00:00Z")},
        {"s3_compat_matrix_new.json", ready_artifact()}
      ])

    old =
      CompatMatrixConsole.load(%{"artifact" => "s3_compat_matrix_old.json"},
        now: @now,
        artifacts_fun: fn _opts -> artifacts end
      )

    assert old.selection_warning.reason == "selected_not_latest"
    assert old.selection_warning.showing == "s3_compat_matrix_old.json"

    invalid =
      CompatMatrixConsole.load(%{"artifact" => "../outside.json"},
        now: @now,
        artifacts_fun: fn _opts -> artifacts end
      )

    assert invalid.selection_warning.reason == "invalid_parameter"
    assert invalid.selected_artifact.file_name == "s3_compat_matrix_new.json"
  end

  defp artifacts_from_json(entries) do
    dir = tmp_dir()

    Enum.each(entries, fn {name, artifact} ->
      File.write!(Path.join(dir, name), Jason.encode!(artifact))
    end)

    Artifacts.list_recent(dir: dir)
  end

  defp ready_artifact do
    %{
      "schema_version" => 1,
      "generated_at" => DateTime.to_iso8601(@now),
      "run_id" => "s3_compat_matrix_ready",
      "git_sha" => "abc123",
      "node" => "maxio@n0",
      "mix_env" => "test",
      "command" =>
        "mix maxio.compat.matrix --external-access-key test-access --external-secret-key super-secret",
      "artifact_path" => "C:/private/s3_compat_matrix_ready.json",
      "gate_status" => "attention",
      "counts" => %{"total" => 4, "ok" => 2, "attention" => 2, "blocked" => 0, "error" => 0},
      "blockers" => [],
      "warnings" => [
        %{
          "entry" => "aws_cli",
          "kind" => "external_client",
          "reason" => "external_client_not_configured"
        }
      ],
      "suites" => [
        suite("authz_matrix", "ok"),
        suite("streaming_stress_matrix", "ok")
      ],
      "external_clients" => [
        %{
          "kind" => "external_client",
          "id" => "aws_cli",
          "label" => "aws-cli",
          "mode" => "external_availability",
          "status" => "attention",
          "path" => "C:/tools/aws.exe",
          "detail" => "missing test-access super-secret",
          "warnings" => [%{"reason" => "external_client_not_configured", "client" => "aws_cli"}],
          "blockers" => []
        }
      ],
      "external_smoke" => [
        %{
          "kind" => "external_smoke",
          "id" => "python_boto3",
          "label" => "python-boto3",
          "mode" => "external_smoke",
          "status" => "attention",
          "duration_ms" => 50,
          "steps" => [%{"id" => "put_object"}],
          "scenario_counts" => %{"object_write_read" => 1},
          "warnings" => [%{"reason" => "external_smoke_not_configured"}],
          "blockers" => []
        }
      ]
    }
  end

  defp supplement_artifact do
    %{
      "kind" => "external_phase1_list_supplement",
      "purpose" => "phase1 compatibility evidence",
      "clients" => [%{"id" => "aws_cli"}]
    }
  end

  defp suite(id, status) do
    %{
      "kind" => "internal_suite",
      "id" => id,
      "name" => id,
      "path" => "test/maxio/s3/#{id}_test.exs",
      "mode" => "internal_self_signed",
      "mix_command" => "test test/maxio/s3/#{id}_test.exs",
      "status" => status,
      "exit_status" => 0,
      "duration_ms" => 100,
      "exunit" => %{"tests" => 2, "failures" => 0, "excluded" => 0},
      "output_snippet" => "2 tests, 0 failures",
      "blockers" => [],
      "warnings" => [],
      "evidence" => %{
        "profile" => "local_safe_default_with_env_overrides",
        "parameters" => %{"object_bytes" => 4_194_304, "repetitions" => 3},
        "env" => %{"object_bytes" => "MAXIO_STREAMING_STRESS_OBJECT_BYTES"},
        "scenarios" => ["repeated aws-chunked PutObject"]
      }
    }
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "maxio-compat-console-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
