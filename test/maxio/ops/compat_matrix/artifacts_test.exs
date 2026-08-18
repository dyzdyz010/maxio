defmodule Maxio.Ops.CompatMatrix.ArtifactsTest do
  use ExUnit.Case, async: true

  alias Maxio.Ops.CompatMatrix.Artifacts

  @generated_at "2026-07-05T00:00:00Z"

  test "lists recent compat matrix artifacts without leaking raw paths or secrets" do
    dir = tmp_dir()

    write_json(dir, "s3_compat_matrix_ready.json", ready_artifact())

    [artifact] = Artifacts.list_recent(dir: dir)

    assert artifact.status == "ok"
    assert artifact.file_name == "s3_compat_matrix_ready.json"
    assert artifact.gate_status == "attention"
    assert artifact.count_check.status == "ok"
    assert artifact.counts["total"] == 4
    assert Enum.map(artifact.suites, & &1.id) == ["authz_matrix", "streaming_stress_matrix"]
    assert artifact.streaming_stress.parameters["object_bytes"] == 4_194_304
    assert [%{id: "aws_cli", executable: "aws.exe"} | _] = artifact.external_clients

    encoded = inspect(artifact)
    refute encoded =~ "super-secret"
    refute encoded =~ "test-access"
    refute encoded =~ "C:/private"
    refute Map.has_key?(artifact, :path)
  end

  test "malformed oversized and non-matrix artifacts fail closed" do
    dir = tmp_dir()

    write_file(dir, "s3_compat_matrix_bad.json", "{")
    write_file(dir, "s3_compat_matrix_other.json", Jason.encode!(%{"hello" => "world"}))
    write_file(dir, "s3_compat_matrix_large.json", String.duplicate("x", 64))

    artifacts = Artifacts.list_recent(dir: dir, max_bytes: 16)
    reasons = artifacts |> Enum.map(& &1.error_reason) |> Enum.sort()

    assert reasons == ["artifact_too_large", "artifact_too_large", "json_unparseable"]
    assert Enum.all?(artifacts, &(&1.status == "invalid"))
    assert Enum.all?(artifacts, &(&1.gate_status == "invalid"))
  end

  test "unsafe glob and non-regular candidates do not hide valid artifacts" do
    dir = tmp_dir()
    nested = Path.join(dir, "nested")
    File.mkdir_p!(nested)
    write_json(dir, "s3_compat_matrix_ready.json", ready_artifact())
    write_json(nested, "s3_compat_matrix_nested.json", ready_artifact())

    assert Artifacts.list_recent(dir: dir, glob: "../*.json") == []
    assert [%{file_name: "s3_compat_matrix_ready.json"}] = Artifacts.list_recent(dir: dir)
  end

  test "count mismatch is explicit blocked evidence" do
    dir = tmp_dir()

    artifact =
      ready_artifact()
      |> put_in(["counts", "ok"], 99)

    write_json(dir, "s3_compat_matrix_counts.json", artifact)

    [artifact] = Artifacts.list_recent(dir: dir)

    assert artifact.count_check.status == "blocked"
    assert artifact.count_check.reason == "counts_mismatch"
    assert artifact.count_check.expected["ok"] == 99
    assert artifact.count_check.actual["ok"] == 2
  end

  test "malformed section shapes fail closed" do
    dir = tmp_dir()

    artifact =
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

    write_json(dir, "s3_compat_matrix_bad_shape.json", artifact)

    [artifact] = Artifacts.list_recent(dir: dir)

    assert artifact.status == "invalid"
    assert artifact.error_reason == "malformed_sections"

    assert Enum.map(artifact.blockers, & &1["entry"]) == [
             "suites",
             "external_clients",
             "external_smoke"
           ]

    assert Enum.all?(artifact.blockers, &(&1["reason"] == "malformed_section"))
  end

  test "missing provenance fields stay nil instead of becoming the string \"nil\"" do
    dir = tmp_dir()

    artifact =
      ready_artifact()
      |> Map.drop(["generated_at", "run_id", "git_sha", "node", "mix_env"])

    write_json(dir, "s3_compat_matrix_missing_fields.json", artifact)

    [artifact] = Artifacts.list_recent(dir: dir)

    assert artifact.status == "ok"
    assert artifact.generated_at == nil
    assert artifact.run_id == nil
    assert artifact.git_sha == nil
    assert artifact.node == nil
    assert artifact.mix_env == nil
  end

  defp ready_artifact do
    %{
      "schema_version" => 1,
      "generated_at" => @generated_at,
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
        %{
          "kind" => "internal_suite",
          "id" => "authz_matrix",
          "name" => "Authz",
          "path" => "test/maxio/s3/authz_matrix_test.exs",
          "mode" => "internal_self_signed",
          "mix_command" => "test test/maxio/s3/authz_matrix_test.exs",
          "status" => "ok",
          "exit_status" => 0,
          "duration_ms" => 100,
          "exunit" => %{"tests" => 12, "failures" => 0, "excluded" => 0},
          "output_snippet" => "12 tests, 0 failures",
          "blockers" => [],
          "warnings" => []
        },
        %{
          "kind" => "internal_suite",
          "id" => "streaming_stress_matrix",
          "name" => "Streaming stress",
          "path" => "test/maxio/s3/streaming_stress_matrix_test.exs",
          "mode" => "internal_self_signed_stress",
          "mix_command" => "test test/maxio/s3/streaming_stress_matrix_test.exs",
          "status" => "ok",
          "exit_status" => 0,
          "duration_ms" => 200,
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

  defp write_json(dir, name, value), do: write_file(dir, name, Jason.encode!(value))

  defp write_file(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "maxio-compat-artifacts-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
