defmodule MaxioWeb.OpsUpgradeLiveTest do
  use MaxioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maxio.Cluster.{SchedulerRun, SchedulerRunRollup, SchedulerState, TopologyRevision}
  alias Maxio.Repo

  setup %{conn: conn} do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_ops_upgrade_live_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    old_gate_dir = Application.get_env(:maxio, :ops_gate_artifacts_dir)
    old_bundle_dir = Application.get_env(:maxio, :ops_rehearsal_bundle_artifacts_dir)
    Application.put_env(:maxio, :ops_gate_artifacts_dir, dir)
    Application.put_env(:maxio, :ops_rehearsal_bundle_artifacts_dir, dir)

    Repo.delete_all(SchedulerRunRollup)
    Repo.delete_all(SchedulerRun)
    Repo.delete_all(SchedulerState)
    Repo.delete_all(TopologyRevision)

    on_exit(fn ->
      restore_env(:ops_gate_artifacts_dir, old_gate_dir)
      restore_env(:ops_rehearsal_bundle_artifacts_dir, old_bundle_dir)
      File.rm_rf!(dir)
    end)

    {:ok, conn: log_in_console(conn), dir: dir}
  end

  test "renders read-only upgrade shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ops/upgrade")

    assert has_element?(view, "#ops-upgrade")
    assert has_element?(view, "#nav-ops-upgrade")
    assert has_element?(view, "#ops-upgrade-readonly-boundary", "read-only")
    assert has_element?(view, "#ops-upgrade-summary")
    assert has_element?(view, "#ops-upgrade-release")
    assert has_element?(view, "#ops-upgrade-schema")
    assert has_element?(view, "#ops-upgrade-topology-revisions")
    assert has_element?(view, "#ops-upgrade-rollback-candidates")
    assert has_element?(view, "#ops-upgrade-gate-artifacts")
    assert has_element?(view, "#ops-upgrade-rehearsal-bundles")
    assert has_element?(view, "#ops-upgrade-scheduler-ledger")
    assert has_element?(view, "#ops-upgrade-cross-links")
    assert has_element?(view, "#ops-upgrade-link-cluster")
    assert has_element?(view, "#ops-upgrade-link-gate")
    assert has_element?(view, "#ops-upgrade-link-replacement")
    assert has_element?(view, "#ops-upgrade-link-rebalance")
    assert has_element?(view, "#ops-upgrade-link-scan")
    refute has_element?(view, "#ops-upgrade button")
    refute has_element?(view, "#ops-upgrade form")
  end

  test "renders archived gate artifact and P0 rehearsal bundle evidence", %{conn: conn, dir: dir} do
    write_gate!(dir, "m8_ops_gate_upgrade.json", %{
      "run_id" => "upgrade-gate",
      "gate_status" => "ok",
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    write_bundle!(dir, "m8_p0_ops_live_rehearsal_upgrade_bundle.json", %{
      "run_id" => "upgrade-bundle",
      "gate_status" => "ok",
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:ok, view, _html} = live(conn, ~p"/ops/upgrade")

    assert has_element?(view, "#ops-upgrade-gate-artifacts", "upgrade-gate")
    assert has_element?(view, "#ops-upgrade-rehearsal-bundles", "upgrade-bundle")
    refute has_element?(view, "#ops-upgrade button")
    refute has_element?(view, "#ops-upgrade form")
  end

  defp write_gate!(dir, file_name, attrs) do
    payload =
      Map.merge(
        %{
          "schema_version" => 1,
          "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "run_id" => "gate-run",
          "gate_status" => "ok",
          "counts" => %{"total" => 0, "ok" => 0, "attention" => 0, "blocked" => 0, "error" => 0},
          "checks" => []
        },
        attrs
      )

    File.write!(Path.join(dir, file_name), Jason.encode!(payload))
  end

  defp write_bundle!(dir, file_name, attrs) do
    payload =
      Map.merge(
        %{
          "schema_version" => 1,
          "evidence_kind" => "p0_ops_live_rehearsal_bundle",
          "scenario" => "p0_ops_1_rehearsal_bundle",
          "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "run_id" => "bundle-run",
          "replacement_mode" => "dry_run",
          "scheduler_mode" => "read_only",
          "gate_status" => "ok",
          "artifact_paths" => %{},
          "commands" => %{},
          "child_results" => %{}
        },
        attrs
      )

    File.write!(Path.join(dir, file_name), Jason.encode!(payload))
  end

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
