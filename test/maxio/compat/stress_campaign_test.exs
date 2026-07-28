defmodule Maxio.Compat.StressCampaignTest do
  use ExUnit.Case, async: true

  alias Maxio.Compat.StressCampaign

  @now ~U[2026-07-05 04:45:00Z]
  @streaming_stress_path "test/maxio/s3/streaming_stress_matrix_test.exs"
  @storage_fault_path "test/maxio/storage/atomic_commit_test.exs"
  @ops_resilience_path "test/maxio/cluster/m8_integration_test.exs"

  test "default campaign runs local stress and fault suites and writes an artifact" do
    artifact_path = artifact_path("default")

    {:ok, result} =
      run_campaign(["--artifact", artifact_path], ok_responses())

    assert result.exit_code == 0
    assert result.gate_status == "ok"
    assert result.artifact_path == artifact_path
    assert result.stdout =~ "[maxio stress.campaign] gate_status=ok"
    refute Map.get(result, :stderr)

    assert_received {:cmd, ["test", @streaming_stress_path, "--max-failures", "1"],
                     [stderr_to_stdout: true]}

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

    artifact = artifact_path |> File.read!() |> Jason.decode!()
    assert artifact["schema_version"] == 1
    assert artifact["evidence_kind"] == "stress_campaign"
    assert artifact["scenario"] == "local_stress_fault_campaign"
    assert artifact["generated_at"] == "2026-07-05T04:45:00Z"
    assert artifact["git_sha"] == "test-sha"
    assert artifact["profile"] == "local_safe_default"
    assert artifact["gate_status"] == "ok"
    assert artifact["config"]["external_clients_required"] == false
    assert artifact["matrix"]["external_clients"] == []
    assert artifact["matrix"]["external_smoke"] == []

    assert artifact["config"]["suites"] == [
             "streaming_stress_matrix",
             "storage_fault_matrix",
             "ops_resilience_matrix"
           ]

    assert Enum.map(artifact["matrix"]["suites"], & &1["id"]) == artifact["config"]["suites"]
    assert artifact["counts"]["ok"] == 3
    assert artifact["counts"]["total"] == 3
  end

  test "blocked child suite is reporting-only unless fail-on-blocked is explicit" do
    responses =
      ok_responses()
      |> Map.put(@storage_fault_path, {"Finished in 0.3 seconds\n5 tests, 1 failure\n", 2})

    {:ok, reporting} =
      run_campaign(["--artifact", artifact_path("blocked-reporting")], responses)

    assert reporting.exit_code == 0
    assert reporting.gate_status == "blocked"

    assert [%{"entry" => "storage_fault_matrix", "reason" => "compat_suite_failed"}] =
             reporting.artifact["blockers"]

    {:error, fatal} =
      run_campaign(
        ["--artifact", artifact_path("blocked-fatal"), "--fail-on-blocked"],
        responses
      )

    assert fatal.exit_code == 1
    assert fatal.gate_status == "blocked"
    assert fatal.stderr =~ "gate failed"
    assert File.exists?(fatal.artifact_path)
  end

  test "zero-test child suite remains blocked through campaign artifact" do
    responses =
      ok_responses()
      |> Map.put(@streaming_stress_path, {"Finished in 0.1 seconds\n0 tests, 0 failures\n", 0})

    {:error, result} =
      run_campaign(
        ["--artifact", artifact_path("zero-tests"), "--fail-on-blocked"],
        responses
      )

    assert result.exit_code == 1
    assert result.gate_status == "blocked"

    assert [%{"entry" => "streaming_stress_matrix", "reason" => "compat_suite_no_tests"}] =
             result.artifact["blockers"]

    assert File.exists?(result.artifact_path)
  end

  test "suite filter limits the campaign to requested local suites" do
    {:ok, result} =
      run_campaign(
        ["--artifact", artifact_path("filtered"), "--suite", "streaming_stress_matrix"],
        ok_responses()
      )

    assert Enum.map(result.artifact["matrix"]["suites"], & &1["id"]) == [
             "streaming_stress_matrix"
           ]

    assert_received {:cmd, ["test", @streaming_stress_path, "--max-failures", "1"], _opts}
    refute_received {:cmd, ["test", @storage_fault_path | _rest], _opts}
    refute_received {:cmd, ["test", @ops_resilience_path | _rest], _opts}
  end

  test "json output emits the campaign artifact" do
    {:ok, result} =
      run_campaign(["--artifact", artifact_path("json"), "--json"], ok_responses())

    decoded = Jason.decode!(result.stdout)
    assert decoded["evidence_kind"] == "stress_campaign"
    assert decoded["matrix"]["gate_status"] == "ok"
  end

  test "invalid child suite is a usage error" do
    {:error, result} = StressCampaign.run(["--suite", "missing"])

    assert result.exit_code == 64
    assert result.stderr =~ "child matrix usage error"
    assert result.stderr =~ "--suite must be one of"
  end

  defp run_campaign(args, responses) do
    StressCampaign.run(["--mix-cmd", "fake-mix" | args],
      command_runner: fake_suite_runner(self(), responses),
      git_sha_fun: fn -> "test-sha" end,
      now_fun: fn -> @now end
    )
  end

  defp ok_responses do
    %{
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

  defp artifact_path(name) do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_stress_campaign_test_#{System.unique_integer([:positive])}"
      )

    Path.join(base, "#{name}.json")
  end
end
