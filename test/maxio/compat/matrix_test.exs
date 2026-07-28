defmodule Maxio.Compat.MatrixTest do
  use ExUnit.Case, async: true

  alias Maxio.Compat.Matrix

  @now ~U[2026-07-04 09:00:00Z]
  @authz_path "test/maxio/s3/authz_matrix_test.exs"
  @m4_path "test/maxio/s3/m4_matrix_test.exs"
  @multipart_range_path "test/maxio/s3/multipart_range_matrix_test.exs"
  @list_conditional_path "test/maxio/s3/list_conditional_matrix_test.exs"
  @sdk_highfreq_path "test/maxio/s3/sdk_highfreq_matrix_test.exs"
  @streaming_path "test/maxio/s3/streaming_matrix_test.exs"
  @streaming_stress_path "test/maxio/s3/streaming_stress_matrix_test.exs"
  @storage_fault_path "test/maxio/storage/atomic_commit_test.exs"
  @ops_resilience_path "test/maxio/cluster/m8_integration_test.exs"

  test "default matrix runs internal compatibility suites and writes an ok artifact" do
    artifact_path = artifact_path("default-ok")

    {:ok, result} =
      run_matrix(["--artifact", artifact_path, "--skip-external-probes"], ok_responses())

    assert result.exit_code == 0
    assert result.gate_status == "ok"
    assert result.stdout =~ "[maxio compat.matrix] gate_status=ok"
    assert result.artifact_path == artifact_path
    refute Map.get(result, :stderr)

    assert_received {:cmd, ["test", @authz_path, "--max-failures", "1"], [stderr_to_stdout: true]}

    assert_received {:cmd, ["test", @m4_path, "--max-failures", "1"], [stderr_to_stdout: true]}

    assert_received {:cmd, ["test", @multipart_range_path, "--max-failures", "1"],
                     [stderr_to_stdout: true]}

    assert_received {:cmd, ["test", @list_conditional_path, "--max-failures", "1"],
                     [stderr_to_stdout: true]}

    assert_received {:cmd, ["test", @sdk_highfreq_path, "--max-failures", "1"],
                     [stderr_to_stdout: true]}

    assert_received {:cmd, ["test", @streaming_path, "--max-failures", "1"],
                     [stderr_to_stdout: true]}

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["schema_version"] == 1
    assert artifact["generated_at"] == "2026-07-04T09:00:00Z"
    assert artifact["git_sha"] == "test-sha"
    assert artifact["gate_status"] == "ok"
    assert artifact["external_clients"] == []

    assert artifact["config"]["optional_suites"] == [
             "streaming_stress_matrix",
             "storage_fault_matrix",
             "ops_resilience_matrix"
           ]

    suite_ids = Enum.map(artifact["suites"], & &1["id"])

    assert artifact["counts"] == %{
             "attention" => 0,
             "blocked" => 0,
             "error" => 0,
             "ok" => length(suite_ids),
             "total" => length(suite_ids)
           }

    assert suite_ids == [
             "authz_matrix",
             "m4_matrix",
             "multipart_range_matrix",
             "list_conditional_matrix",
             "sdk_highfreq_matrix",
             "streaming_matrix"
           ]

    assert hd(artifact["suites"])["exunit"]["excluded"] == nil
    assert hd(artifact["suites"])["exunit"]["failures"] == 0
    assert is_integer(hd(artifact["suites"])["exunit"]["tests"])
    assert hd(artifact["suites"])["exunit"]["tests"] > 0
  end

  test "external client gaps are attention evidence unless strict is explicit" do
    {:ok, reporting} =
      run_matrix(["--artifact", artifact_path("external-reporting")], ok_responses(), [
        missing_client("aws_cli", "aws-cli"),
        missing_client("minio_mc", "MinIO mc"),
        available_client("python_boto3", "python-boto3")
      ])

    assert reporting.exit_code == 0
    assert reporting.gate_status == "attention"
    assert length(reporting.artifact["warnings"]) == 2

    {:error, strict} =
      run_matrix(
        ["--artifact", artifact_path("external-strict"), "--fail-on-attention", "--json"],
        ok_responses(),
        [
          missing_client("aws_cli", "aws-cli")
        ]
      )

    assert strict.exit_code == 1
    assert strict.gate_status == "attention"
    assert strict.stderr =~ "gate failed"

    decoded = Jason.decode!(strict.stdout)
    assert decoded["gate_status"] == "attention"

    assert [%{"entry" => "aws_cli", "reason" => "external_client_not_configured"}] =
             decoded["warnings"]
  end

  test "malformed external client status fails closed" do
    {:error, result} =
      run_matrix(["--artifact", artifact_path("external-malformed")], ok_responses(), [
        %{"id" => "aws_cli", "label" => "aws-cli", "status" => "surprising"}
      ])

    assert result.exit_code == 1
    assert result.gate_status == "error"

    assert [
             %{
               "entry" => "aws_cli",
               "reason" => "external_client_status_invalid",
               "detail" => %{"status" => "surprising"}
             }
           ] = result.artifact["blockers"]
  end

  test "external probe function exceptions fail closed with artifact evidence" do
    artifact_path = artifact_path("external-probe-error")

    {:error, result} =
      Matrix.run(
        ["--mix-cmd", "fake-mix", "--artifact", artifact_path, "--suite", "authz_matrix"],
        command_runner: fake_suite_runner(self(), ok_responses()),
        external_probe_fun: fn -> raise "external boom" end,
        git_sha_fun: fn -> "test-sha" end,
        now_fun: fn -> @now end
      )

    assert result.exit_code == 1
    assert result.gate_status == "error"
    assert File.exists?(artifact_path)

    assert [
             %{
               "entry" => "external_probe",
               "kind" => "external_client",
               "reason" => "external_probe_failed"
             }
           ] = result.artifact["blockers"]
  end

  test "default external probes execute cli commands and support py launcher" do
    owner = self()

    executable_finder = fn
      "aws" -> "C:/tools/aws.exe"
      "mc" -> "C:/tools/mc.exe"
      "python" -> nil
      "python3" -> nil
      "py" -> "C:/Windows/py.exe"
    end

    external_runner = fn command, args, opts ->
      send(owner, {:external_cmd, command, args, opts})

      case {command, args} do
        {"C:/tools/aws.exe", ["--version"]} -> {"aws-cli/2.15.0 Python/3.11\n", 0}
        {"C:/tools/mc.exe", ["--version"]} -> {"mc probe failed\n", 42}
        {"C:/Windows/py.exe", ["-c", _python_code]} -> {"", 0}
      end
    end

    {:ok, result} =
      Matrix.run(
        [
          "--mix-cmd",
          "fake-mix",
          "--artifact",
          artifact_path("default-external"),
          "--suite",
          "authz_matrix"
        ],
        command_runner: fake_suite_runner(owner, ok_responses()),
        external_executable_finder: executable_finder,
        external_command_runner: external_runner,
        git_sha_fun: fn -> "test-sha" end,
        now_fun: fn -> @now end
      )

    assert result.exit_code == 0
    assert result.gate_status == "attention"
    assert_received {:external_cmd, "C:/tools/aws.exe", ["--version"], [stderr_to_stdout: true]}
    assert_received {:external_cmd, "C:/tools/mc.exe", ["--version"], [stderr_to_stdout: true]}
    assert_received {:external_cmd, "C:/Windows/py.exe", ["-c", _], [stderr_to_stdout: true]}

    clients = Map.new(result.artifact["external_clients"], &{&1["id"], &1})
    assert clients["aws_cli"]["status"] == "ok"
    assert clients["aws_cli"]["detail"] =~ "aws-cli/2.15.0"
    assert clients["minio_mc"]["status"] == "attention"
    assert clients["python_boto3"]["status"] == "ok"
    assert clients["python_boto3"]["path"] == "C:/Windows/py.exe"
  end

  test "failed internal suite is blocked and fail-on-blocked makes it fatal" do
    responses =
      ok_responses()
      |> Map.put(@m4_path, {"Finished in 0.4 seconds\n3 tests, 1 failure\n", 2})

    {:ok, reporting} =
      run_matrix(
        ["--artifact", artifact_path("suite-reporting"), "--skip-external-probes"],
        responses
      )

    assert reporting.exit_code == 0
    assert reporting.gate_status == "blocked"

    assert [%{"entry" => "m4_matrix", "reason" => "compat_suite_failed"}] =
             reporting.artifact["blockers"]

    {:error, fatal} =
      run_matrix(
        [
          "--artifact",
          artifact_path("suite-fatal"),
          "--skip-external-probes",
          "--fail-on-blocked"
        ],
        responses
      )

    assert fatal.exit_code == 1
    assert fatal.gate_status == "blocked"
    assert fatal.stderr =~ "gate failed"
  end

  test "zero-test internal suite fails closed even when command exits successfully" do
    responses =
      ok_responses()
      |> Map.put(@streaming_stress_path, {"Finished in 0.1 seconds\n0 tests, 0 failures\n", 0})

    {:ok, reporting} =
      run_matrix(
        [
          "--artifact",
          artifact_path("suite-zero-tests-reporting"),
          "--skip-external-probes",
          "--suite",
          "streaming_stress_matrix"
        ],
        responses
      )

    assert reporting.exit_code == 0
    assert reporting.gate_status == "blocked"

    assert [%{"entry" => "streaming_stress_matrix", "reason" => "compat_suite_no_tests"}] =
             reporting.artifact["blockers"]

    {:error, fatal} =
      run_matrix(
        [
          "--artifact",
          artifact_path("suite-zero-tests-fatal"),
          "--skip-external-probes",
          "--suite",
          "streaming_stress_matrix",
          "--fail-on-blocked"
        ],
        responses
      )

    assert fatal.exit_code == 1
    assert fatal.gate_status == "blocked"
    assert fatal.stderr =~ "gate failed"
  end

  test "command exceptions fail closed and still write artifact evidence" do
    artifact_path = artifact_path("command-error")
    owner = self()

    runner = fn "fake-mix", cmd_args, opts ->
      send(owner, {:cmd, cmd_args, opts})
      raise "runner boom"
    end

    {:error, result} =
      Matrix.run(
        ["--mix-cmd", "fake-mix", "--artifact", artifact_path, "--skip-external-probes"],
        command_runner: runner,
        git_sha_fun: fn -> "test-sha" end,
        now_fun: fn -> @now end
      )

    assert result.exit_code == 1
    assert result.gate_status == "error"
    assert File.exists?(artifact_path)
    assert Enum.all?(result.artifact["suites"], &(&1["status"] == "error"))

    assert [%{"entry" => "authz_matrix", "reason" => "command_failed"} | _] =
             result.artifact["blockers"]
  end

  test "suite filter and invalid suite handling" do
    {:ok, result} =
      run_matrix(
        [
          "--artifact",
          artifact_path("suite-filter"),
          "--skip-external-probes",
          "--suite",
          "authz_matrix"
        ],
        ok_responses()
      )

    assert Enum.map(result.artifact["suites"], & &1["id"]) == ["authz_matrix"]
    assert_received {:cmd, ["test", @authz_path, "--max-failures", "1"], _opts}
    refute_received {:cmd, ["test", @m4_path, "--max-failures", "1"], _opts}

    {:error, usage} = Matrix.run(["--suite", "missing"])
    assert usage.exit_code == 64
    assert usage.stderr =~ "--suite must be one of"
  end

  test "optional streaming stress suite runs only when explicitly requested" do
    {:ok, result} =
      run_matrix(
        [
          "--artifact",
          artifact_path("streaming-stress"),
          "--skip-external-probes",
          "--suite",
          "streaming_stress_matrix"
        ],
        ok_responses()
      )

    assert result.gate_status == "ok"
    assert Enum.map(result.artifact["suites"], & &1["id"]) == ["streaming_stress_matrix"]

    assert_received {:cmd, ["test", @streaming_stress_path, "--max-failures", "1"],
                     [stderr_to_stdout: true]}

    refute_received {:cmd, ["test", @streaming_path, "--max-failures", "1"], _opts}

    [suite] = result.artifact["suites"]
    assert suite["mode"] == "internal_self_signed_stress"
    assert suite["exunit"]["tests"] == 3
    assert suite["evidence"]["parameters"]["object_bytes"] == 4 * 1024 * 1024
    assert suite["evidence"]["parameters"]["repetitions"] == 3
    assert suite["evidence"]["parameters"]["failure_attempts"] == 3
    assert suite["evidence"]["parameters"]["concurrency"] == 2
    assert suite["evidence"]["parameters"]["multipart_uploads"] == 2
    assert suite["evidence"]["parameters"]["chunk_sizes"] == [64 * 1024, 256 * 1024, 1024 * 1024]

    assert suite["evidence"]["env"] == %{
             "object_bytes" => "MAXIO_STREAMING_STRESS_OBJECT_BYTES",
             "repetitions" => "MAXIO_STREAMING_STRESS_REPETITIONS",
             "chunk_sizes" => "MAXIO_STREAMING_STRESS_CHUNK_SIZES",
             "failure_attempts" => "MAXIO_STREAMING_STRESS_FAILURE_ATTEMPTS",
             "concurrency" => "MAXIO_STREAMING_STRESS_CONCURRENCY",
             "multipart_uploads" => "MAXIO_STREAMING_STRESS_MULTIPART_UPLOADS"
           }
  end

  test "optional fault and ops resilience suites run only when explicitly requested" do
    {:ok, result} =
      run_matrix(
        [
          "--artifact",
          artifact_path("fault-ops"),
          "--skip-external-probes",
          "--suite",
          "storage_fault_matrix",
          "--suite",
          "ops_resilience_matrix"
        ],
        ok_responses()
      )

    assert result.gate_status == "ok"

    assert Enum.map(result.artifact["suites"], & &1["id"]) == [
             "storage_fault_matrix",
             "ops_resilience_matrix"
           ]

    assert_received {:cmd,
                     [
                       "test",
                       @storage_fault_path,
                       "test/maxio/storage/erasure/bitrot_e2e_test.exs",
                       "test/maxio/storage/scanner_test.exs",
                       "--max-failures",
                       "1"
                     ], [stderr_to_stdout: true]}

    assert_received {:cmd,
                     [
                       "test",
                       @ops_resilience_path,
                       "test/maxio/cluster/scheduler_cadence_test.exs",
                       "test/maxio/cluster/replacement_rebalance_integration_test.exs",
                       "--max-failures",
                       "1"
                     ], [stderr_to_stdout: true]}

    [storage_suite, ops_suite] = result.artifact["suites"]
    assert storage_suite["mode"] == "internal_fault_injection"
    assert storage_suite["evidence"]["profile"] == "local_storage_fault_matrix"
    assert ops_suite["mode"] == "internal_ops_resilience"
    assert ops_suite["evidence"]["profile"] == "local_ops_resilience_matrix"
  end

  test "duplicate suite filters run each selected suite once in stable default order" do
    {:ok, result} =
      run_matrix(
        [
          "--artifact",
          artifact_path("suite-duplicates"),
          "--skip-external-probes",
          "--suite",
          "m4_matrix",
          "--suite",
          "authz_matrix",
          "--suite",
          "m4_matrix"
        ],
        ok_responses()
      )

    assert Enum.map(result.artifact["suites"], & &1["id"]) == ["authz_matrix", "m4_matrix"]
    assert_received {:cmd, ["test", @authz_path, "--max-failures", "1"], _opts}
    assert_received {:cmd, ["test", @m4_path, "--max-failures", "1"], _opts}
    refute_received {:cmd, ["test", @m4_path, "--max-failures", "1"], _opts}
  end

  test "external smoke is not run unless explicitly requested" do
    {:ok, result} =
      Matrix.run(
        [
          "--mix-cmd",
          "fake-mix",
          "--artifact",
          artifact_path("smoke-not-default"),
          "--suite",
          "authz_matrix",
          "--skip-external-probes"
        ],
        command_runner: fake_suite_runner(self(), ok_responses()),
        external_smoke_fun: fn _config -> raise "smoke should not run by default" end,
        git_sha_fun: fn -> "test-sha" end,
        now_fun: fn -> @now end
      )

    assert result.gate_status == "ok"
    assert result.artifact["external_smoke"] == []
  end

  test "external smoke opt-in supports smoke-only artifact aggregation and secret redaction" do
    owner = self()

    smoke_fun = fn config ->
      send(owner, {:smoke_config, config})

      [
        %{
          "id" => "aws_cli",
          "label" => "aws-cli",
          "status" => "ok",
          "duration_ms" => 12,
          "steps" => [
            %{
              "id" => "get_object_range",
              "scenario" => "range_read",
              "assertion" => "byte range download returns only the requested slice",
              "status" => "ok"
            }
          ],
          "scenario_counts" => %{"range_read" => 1},
          "blockers" => [],
          "warnings" => []
        }
      ]
    end

    {:ok, result} =
      Matrix.run(
        [
          "--mix-cmd",
          "fake-mix",
          "--artifact",
          artifact_path("smoke-only"),
          "--skip-external-probes",
          "--include-external-smoke",
          "--no-internal-suites",
          "--external-smoke-client",
          "aws_cli",
          "--external-endpoint",
          "http://127.0.0.1:9900",
          "--external-access-key",
          "test-access",
          "--external-secret-key",
          "super-secret",
          "--external-region",
          "us-east-1"
        ],
        command_runner: fake_suite_runner(owner, ok_responses()),
        external_smoke_fun: smoke_fun,
        git_sha_fun: fn -> "test-sha" end,
        now_fun: fn -> @now end
      )

    assert result.exit_code == 0
    assert result.gate_status == "ok"
    assert result.artifact["suites"] == []
    assert result.artifact["external_clients"] == []
    assert [%{"id" => "aws_cli", "kind" => "external_smoke"}] = result.artifact["external_smoke"]

    assert result.artifact["counts"] == %{
             "attention" => 0,
             "blocked" => 0,
             "error" => 0,
             "ok" => 1,
             "total" => 1
           }

    assert result.stdout =~ "[maxio compat.matrix.smoke] id=aws_cli status=ok"
    assert result.stdout =~ "scenarios="

    assert result.artifact["external_smoke"] |> hd() |> Map.fetch!("scenario_counts") ==
             %{"range_read" => 1}

    assert_received {:smoke_config,
                     %{
                       endpoint: "http://127.0.0.1:9900",
                       access_key: "test-access",
                       secret_key: "super-secret",
                       clients: ["aws_cli"]
                     }}

    refute_received {:cmd, _, _}

    encoded = Jason.encode!(result.artifact)
    refute encoded =~ "super-secret"
    refute encoded =~ "test-access"
    assert result.artifact["config"]["external_smoke"]["access_key_configured"]
    assert result.artifact["config"]["external_smoke"]["secret_key_configured"]
  end

  test "external smoke attention is reporting-only unless fail-on-attention is explicit" do
    smoke_fun = fn _config ->
      [
        %{
          "id" => "aws_cli",
          "label" => "aws-cli",
          "status" => "attention",
          "warnings" => [%{"reason" => "external_smoke_not_configured"}],
          "blockers" => []
        }
      ]
    end

    {:ok, reporting} =
      Matrix.run(
        [
          "--mix-cmd",
          "fake-mix",
          "--artifact",
          artifact_path("smoke-attention-reporting"),
          "--skip-external-probes",
          "--include-external-smoke",
          "--no-internal-suites"
        ],
        command_runner: fake_suite_runner(self(), ok_responses()),
        external_smoke_fun: smoke_fun,
        git_sha_fun: fn -> "test-sha" end,
        now_fun: fn -> @now end
      )

    assert reporting.exit_code == 0
    assert reporting.gate_status == "attention"

    {:error, fatal} =
      Matrix.run(
        [
          "--mix-cmd",
          "fake-mix",
          "--artifact",
          artifact_path("smoke-attention-fatal"),
          "--skip-external-probes",
          "--include-external-smoke",
          "--no-internal-suites",
          "--fail-on-attention"
        ],
        command_runner: fake_suite_runner(self(), ok_responses()),
        external_smoke_fun: smoke_fun,
        git_sha_fun: fn -> "test-sha" end,
        now_fun: fn -> @now end
      )

    assert fatal.exit_code == 1
    assert fatal.gate_status == "attention"
    assert [%{"entry" => "aws_cli", "kind" => "external_smoke"}] = fatal.artifact["warnings"]
  end

  test "external smoke malformed status fails closed" do
    {:error, result} =
      Matrix.run(
        [
          "--mix-cmd",
          "fake-mix",
          "--artifact",
          artifact_path("smoke-malformed"),
          "--skip-external-probes",
          "--include-external-smoke",
          "--no-internal-suites"
        ],
        command_runner: fake_suite_runner(self(), ok_responses()),
        external_smoke_fun: fn _config -> [%{"id" => "aws_cli", "status" => "weird"}] end,
        git_sha_fun: fn -> "test-sha" end,
        now_fun: fn -> @now end
      )

    assert result.exit_code == 1
    assert result.gate_status == "error"
    assert [%{"reason" => "external_smoke_status_invalid"}] = result.artifact["blockers"]
  end

  test "invalid external smoke client is a usage error" do
    {:error, usage} =
      Matrix.run(["--include-external-smoke", "--external-smoke-client", "missing"])

    assert usage.exit_code == 64
    assert usage.stderr =~ "--external-smoke-client must be one of"
  end

  defp run_matrix(args, responses, external_clients \\ []) do
    Matrix.run(["--mix-cmd", "fake-mix" | args],
      command_runner: fake_suite_runner(self(), responses),
      external_probe_fun: fn -> external_clients end,
      git_sha_fun: fn -> "test-sha" end,
      now_fun: fn -> @now end
    )
  end

  defp ok_responses do
    %{
      @authz_path => "Finished in 0.8 seconds\n12 tests, 0 failures\n",
      @m4_path => "Finished in 0.2 seconds\n3 tests, 0 failures\n",
      @multipart_range_path => "Finished in 0.3 seconds\n5 tests, 0 failures\n",
      @list_conditional_path => "Finished in 0.4 seconds\n5 tests, 0 failures\n",
      @sdk_highfreq_path => "Finished in 0.5 seconds\n5 tests, 0 failures\n",
      @streaming_path => "Finished in 0.6 seconds\n8 tests, 0 failures\n",
      @streaming_stress_path => "Finished in 0.7 seconds\n3 tests, 0 failures\n",
      @storage_fault_path => "Finished in 0.8 seconds\n9 tests, 0 failures\n",
      @ops_resilience_path => "Finished in 0.9 seconds\n7 tests, 0 failures\n"
    }
  end

  defp fake_suite_runner(owner, responses) do
    fn "fake-mix", cmd_args, opts ->
      send(owner, {:cmd, cmd_args, opts})

      case Map.fetch!(responses, Enum.at(cmd_args, 1)) do
        {output, status} -> {output, status}
        output when is_binary(output) -> {output, 0}
      end
    end
  end

  defp missing_client(id, label) do
    %{
      "id" => id,
      "label" => label,
      "status" => "attention",
      "warnings" => [
        %{
          "reason" => "external_client_not_configured",
          "client" => id
        }
      ]
    }
  end

  defp available_client(id, label) do
    %{
      "id" => id,
      "label" => label,
      "status" => "ok",
      "path" => "/usr/bin/#{id}",
      "warnings" => [],
      "blockers" => []
    }
  end

  defp artifact_path(name) do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_compat_matrix_test_#{System.unique_integer([:positive])}"
      )

    Path.join(base, "#{name}.json")
  end
end
