defmodule Mix.Tasks.Maxio.Heal.FreshDrivesTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Cluster.DriveHealth
  alias Mix.Tasks.Maxio.Heal.FreshDrives

  setup do
    DriveHealth.reset()

    on_exit(fn ->
      DriveHealth.reset()
      Mix.Task.reenable("maxio.heal.fresh_drives")
    end)
  end

  test "prints dry-run summary for marked drives" do
    endpoint = {Node.self(), Path.join(System.tmp_dir!(), "fresh-drive-cli")}

    _ =
      DriveHealth.record_probe(endpoint, {:error, :unavailable},
        now_ms: 0,
        offline_after_ms: 0,
        set_id: 0,
        set_write_available?: true
      )

    _ = DriveHealth.record_probe(endpoint, :ok, now_ms: 1, offline_after_ms: 0, set_id: 0)

    output =
      capture_io(fn ->
        FreshDrives.run(["--dry-run"])
      end)

    assert output =~ "[maxio heal.fresh_drives] status=dry_run"
    assert output =~ "drives_considered=1"
    assert output =~ "drives_selected=1"
    assert output =~ "drives_cleared=0"
    assert output =~ "scanned=0"
    assert output =~ "dry_run=true"
  end

  test "accepts fresh-drive heal throttle flags" do
    endpoint = {Node.self(), Path.join(System.tmp_dir!(), "fresh-drive-cli-throttle")}

    _ =
      DriveHealth.record_probe(endpoint, {:error, :unavailable},
        now_ms: 0,
        offline_after_ms: 0,
        set_id: 0,
        set_write_available?: true
      )

    _ = DriveHealth.record_probe(endpoint, :ok, now_ms: 1, offline_after_ms: 0, set_id: 0)

    output =
      capture_io(fn ->
        FreshDrives.run([
          "--dry-run",
          "--no-throttle",
          "--max-objects-per-sec",
          "10",
          "--object-burst",
          "2",
          "--sleep-between-batches-ms",
          "0",
          "--no-adaptive-io",
          "--io-load-source",
          "cluster-combined",
          "--max-live-requests",
          "1",
          "--io-pause-ms",
          "10",
          "--io-max-pause-ms",
          "25"
        ])
      end)

    assert output =~ "[maxio heal.fresh_drives] status=dry_run"
    assert output =~ "drives_selected=1"
  end
end
