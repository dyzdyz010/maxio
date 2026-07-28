defmodule MaxioWeb.OpsScanLiveTest do
  use MaxioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maxio.Cluster.{DriveHealth, DriveIdentity}
  alias Maxio.Cluster.Scrubber.Usage

  @uuid "abcdefabcdefabcdefabcdefabcdefab"
  @replacement_uuid "12345678123456781234567812345678"
  @now ~U[2026-07-05 00:00:00.000000Z]

  setup %{conn: conn} do
    dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_ops_scan_live_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    old_dir = Application.get_env(:maxio, :ops_gate_artifacts_dir)
    old_scrubber = Application.get_env(:maxio, :scrubber)
    Application.put_env(:maxio, :ops_gate_artifacts_dir, dir)
    Application.put_env(:maxio, :scrubber, enabled: true, interval_ms: 1_000, page_size: 50)
    :ok = DriveHealth.reset()
    :ok = Usage.clear()

    on_exit(fn ->
      restore_env(:ops_gate_artifacts_dir, old_dir)
      restore_env(:scrubber, old_scrubber)
      :ok = DriveHealth.reset()
      :ok = Usage.clear()
      File.rm_rf!(dir)
    end)

    {:ok, conn: log_in_console(conn), dir: dir}
  end

  test "empty evidence renders the read-only ops scan shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ops/scan")

    assert has_element?(view, "#ops-scan")
    assert has_element?(view, "#nav-ops-scan")
    assert has_element?(view, "#ops-scan-readonly-boundary", "read-only")
    assert has_element?(view, "#ops-scan-authority")
    assert has_element?(view, "#ops-scan-topology")
    assert has_element?(view, "#ops-scan-usage-empty")
    assert has_element?(view, "#ops-scan-drive-health-empty")
    assert has_element?(view, "#ops-scan-drive-identities-empty")
    assert has_element?(view, "#ops-scan-archived-evidence-empty")
    refute has_element?(view, "#ops-scan button")
    refute has_element?(view, "#ops-scan form")
  end

  test "renders usage, drive health, drive identity, and archived scanner evidence", %{
    conn: conn,
    dir: dir
  } do
    Usage.put("alpha", %{object_count: 2, total_size: 128, scanned_at: @now})

    endpoint = {:maxio@n0, Path.join(dir, "d0")}

    _ =
      DriveHealth.record_probe(endpoint, {:error, :unavailable},
        now_ms: 0,
        offline_after_ms: 0,
        set_id: 0,
        set_write_available?: true
      )

    assert {:ok, _first} =
             DriveIdentity.register_observation(endpoint, %{drive_uuid: @uuid},
               set_id: 0,
               endpoint_index: 1,
               now: @now
             )

    assert {:ok, _replacement} =
             DriveIdentity.register_observation(endpoint, %{drive_uuid: @replacement_uuid},
               set_id: 0,
               endpoint_index: 1,
               now: DateTime.add(@now, 60, :second)
             )

    write_artifact!(dir, "m8_ops_gate_scan.json", %{
      "generated_at" => DateTime.to_iso8601(@now),
      "run_id" => "scan-run",
      "gate_status" => "attention",
      "counts" => %{"total" => 2, "attention" => 1, "ok" => 1},
      "checks" => [
        %{
          "id" => "scanner_reconcile",
          "task" => "maxio.reconcile_index",
          "status" => "attention",
          "parsed_output" => %{
            "status" => "attention",
            "gate_status" => "attention",
            "index_status" => "authority_mismatch",
            "scanned" => 12,
            "drive_heal_required" => 1
          }
        },
        %{
          "id" => "fresh_drive_heal",
          "task" => "maxio.heal.fresh_drives",
          "status" => "ok",
          "parsed_output" => %{
            "status" => "ok",
            "dry_run" => true,
            "backend" => "distributed",
            "drives_selected" => 1,
            "healed_objects" => 3
          }
        }
      ]
    })

    {:ok, view, _html} = live(conn, ~p"/ops/scan")

    assert has_element?(view, "#ops-scan-usage-table")
    assert has_element?(view, "#ops-scan-usage-bucket-alpha", "128")
    assert has_element?(view, "#ops-scan-drive-health-table")
    assert has_element?(view, "#ops-scan-drive-health-offline", "1")
    assert has_element?(view, "#ops-scan-drive-identities-table")
    assert has_element?(view, "#ops-scan-drive-identities-replace", "1")
    assert has_element?(view, "#ops-scan-archived-latest", "scan-run")
    assert has_element?(view, "#ops-scan-archived-evidence", "authority_mismatch")
    assert has_element?(view, "#ops-scan-archived-evidence", "Fresh-Drive Heal Evidence")

    html = render(view)
    refute html =~ @uuid
    refute html =~ @replacement_uuid
    refute has_element?(view, "#ops-scan button")
    refute has_element?(view, "#ops-scan form")
  end

  defp write_artifact!(dir, name, payload) do
    File.write!(Path.join(dir, name), Jason.encode!(payload))
  end

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
