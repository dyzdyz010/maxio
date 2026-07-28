defmodule MaxioWeb.OpsCompatLiveTest do
  use MaxioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_ops_compat_live_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    old_dir = Application.get_env(:maxio, :compat_matrix_artifacts_dir)
    Application.put_env(:maxio, :compat_matrix_artifacts_dir, dir)

    on_exit(fn ->
      restore_env(:compat_matrix_artifacts_dir, old_dir)
      File.rm_rf!(dir)
    end)

    {:ok, conn: log_in_console(conn), dir: dir}
  end

  test "renders read-only compat shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ops/compat")

    assert has_element?(view, "#ops-compat")
    assert has_element?(view, "#nav-ops-compat")
    assert has_element?(view, "#ops-compat-readonly-boundary", "read-only")
    assert has_element?(view, "#ops-compat-summary")
    assert has_element?(view, "#ops-compat-artifacts")
    assert has_element?(view, "#ops-compat-artifact-provenance")
    assert has_element?(view, "#ops-compat-internal-suites")
    assert has_element?(view, "#ops-compat-external-clients")
    assert has_element?(view, "#ops-compat-external-smoke")
    assert has_element?(view, "#ops-compat-streaming-stress")
    assert has_element?(view, "#ops-compat-blockers")
    assert has_element?(view, "#ops-compat-warnings")
    assert has_element?(view, "#ops-compat-cross-links")
    assert has_element?(view, "#ops-compat-link-gate")
    assert has_element?(view, "#ops-compat-link-upgrade")
    assert has_element?(view, "#ops-compat-link-scan")
    assert has_element?(view, "#ops-compat-link-cluster")
    refute has_element?(view, "#ops-compat button")
    refute has_element?(view, "#ops-compat form")
  end

  test "renders archived compat matrix evidence and selection warnings", %{conn: conn, dir: dir} do
    write_matrix!(dir, "s3_compat_matrix_old.json", %{
      "generated_at" => "2026-07-04T00:00:00Z",
      "run_id" => "old-run"
    })

    write_matrix!(dir, "s3_compat_matrix_new.json", %{
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "run_id" => "new-run"
    })

    {:ok, view, _html} = live(conn, ~p"/ops/compat?artifact=s3_compat_matrix_old.json")

    assert has_element?(view, "#ops-compat-artifacts", "s3_compat_matrix_new.json")
    assert has_element?(view, "#ops-compat-internal-suites", "authz_matrix")
    assert has_element?(view, "#ops-compat-external-clients", "aws_cli")
    assert has_element?(view, "#ops-compat-external-smoke", "python_boto3")
    assert has_element?(view, "#ops-compat-streaming-stress", "object_bytes")
    assert has_element?(view, "#ops-compat-selection-warning", "selected_not_latest")
    refute render(view) =~ "super-secret"
    refute render(view) =~ "C:/private"

    {:ok, invalid_view, _html} = live(conn, ~p"/ops/compat?artifact=../outside.json")
    assert has_element?(invalid_view, "#ops-compat-selection-warning", "invalid_parameter")
    refute has_element?(invalid_view, "#ops-compat button")
    refute has_element?(invalid_view, "#ops-compat form")
  end

  test "mounts invalid supplement evidence with stable unique blocker rows", %{
    conn: conn,
    dir: dir
  } do
    File.write!(
      Path.join(dir, "s3_compat_matrix_external_phase1_list_supplement.json"),
      Jason.encode!(%{
        "kind" => "external_phase1_list_supplement",
        "purpose" => "phase1 compatibility evidence",
        "clients" => [%{"id" => "aws_cli"}]
      })
    )

    {:ok, view, _html} = live(conn, ~p"/ops/compat")

    assert has_element?(
             view,
             "#ops-compat-blockers-row-blocker-synthetic-1"
           )

    assert has_element?(
             view,
             "#ops-compat-blockers-row-blocker-artifact-1"
           )

    assert has_element?(view, "#ops-compat-blockers", "not_compat_matrix_artifact")
  end

  test "mounts structured blocker evidence without using display fields as DOM identity", %{
    conn: conn,
    dir: dir
  } do
    write_matrix!(dir, "s3_compat_matrix_structured.json", %{
      "blockers" => [%{"reason" => %{"code" => "structured_reason"}}]
    })

    {:ok, view, _html} = live(conn, ~p"/ops/compat")

    assert has_element?(view, "#ops-compat-blockers-row-blocker-artifact-1")
    assert has_element?(view, "#ops-compat-blockers", "structured_reason")
  end

  defp write_matrix!(dir, file_name, attrs) do
    payload =
      %{
        "schema_version" => 1,
        "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "run_id" => "compat-run",
        "git_sha" => "abc123",
        "node" => "maxio@n0",
        "mix_env" => "test",
        "command" =>
          "mix maxio.compat.matrix --external-secret-key super-secret --artifact C:/private/matrix.json",
        "artifact_path" => "C:/private/matrix.json",
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
          suite("authz_matrix"),
          suite("streaming_stress_matrix")
        ],
        "external_clients" => [
          %{
            "kind" => "external_client",
            "id" => "aws_cli",
            "label" => "aws-cli",
            "mode" => "external_availability",
            "status" => "attention",
            "path" => "C:/tools/aws.exe",
            "detail" => "missing super-secret",
            "warnings" => [%{"reason" => "external_client_not_configured"}],
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
      |> Map.merge(attrs)

    File.write!(Path.join(dir, file_name), Jason.encode!(payload))
  end

  defp suite(id) do
    %{
      "kind" => "internal_suite",
      "id" => id,
      "name" => id,
      "path" => "test/maxio/s3/#{id}_test.exs",
      "mode" => "internal_self_signed",
      "mix_command" => "test test/maxio/s3/#{id}_test.exs",
      "status" => "ok",
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

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
