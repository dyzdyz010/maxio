defmodule Mix.Tasks.Maxio.Heal.FreshDrivesTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Cluster.{DriveHealth, Topology}
  alias Maxio.Storage.Distributed
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
    assert output =~ "gate_status=attention"
    assert output =~ "drives_considered=1"
    assert output =~ "drives_selected=1"
    assert output =~ "drives_cleared=0"
    assert output =~ "scanned=0"
    assert output =~ "dry_run=true"
    assert output =~ "blockers=0"
    assert output =~ "warnings=1"
    assert output =~ "[maxio heal.fresh_drives.warning] reason=fresh_drive_heal_dry_run"
  end

  test "json output exposes dry-run attention evidence" do
    _endpoint = mark_drive_for_fresh_heal("fresh-drive-cli-json-dry-run")

    output =
      capture_io(fn ->
        FreshDrives.run(["--dry-run", "--json"])
      end)

    report = Jason.decode!(String.trim(output))

    assert report["status"] == "dry_run"
    assert report["gate_status"] == "attention"
    assert report["backend"] == "Maxio.Storage.Distributed"
    assert report["dry_run"] == true
    assert report["drives_considered"] == 1
    assert report["drives_selected"] == 1
    assert report["drives_cleared"] == 0
    assert report["blockers"] == []
    assert report["warnings"] == ["fresh_drive_heal_dry_run"]
  end

  test "fail-on-attention raises after emitting dry-run json evidence" do
    _endpoint = mark_drive_for_fresh_heal("fresh-drive-cli-json-attention")

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/fresh-drive heal attention/, fn ->
          FreshDrives.run(["--dry-run", "--json", "--fail-on-attention"])
        end
      end)

    report = Jason.decode!(String.trim(output))

    assert report["status"] == "dry_run"
    assert report["gate_status"] == "attention"
    assert report["blockers"] == []
    assert report["warnings"] == ["fresh_drive_heal_dry_run"]
  end

  test "fail-on-blocked raises after emitting partial-scope json evidence" do
    _endpoint = mark_drive_for_fresh_heal("fresh-drive-cli-partial-scope")
    install_runtime_topology!()

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/fresh-drive heal blocked/, fn ->
          FreshDrives.run(["--current-only", "--json", "--fail-on-blocked"])
        end
      end)

    report = Jason.decode!(String.trim(output))

    assert report["status"] == "partial_scope"
    assert report["gate_status"] == "blocked"
    assert report["scan_versions"] == false
    assert report["blockers"] == ["fresh_drive_heal_status_partial_scope"]
    assert report["warnings"] == []
  end

  test "fail-on-attention also raises for blocked partial-scope reports" do
    _endpoint = mark_drive_for_fresh_heal("fresh-drive-cli-partial-scope-attention")
    install_runtime_topology!()

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/fresh-drive heal blocked/, fn ->
          FreshDrives.run(["--current-only", "--json", "--fail-on-attention"])
        end
      end)

    report = Jason.decode!(String.trim(output))

    assert report["gate_status"] == "blocked"
    assert report["blockers"] == ["fresh_drive_heal_status_partial_scope"]
    assert report["warnings"] == []
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
          "drive-device-io",
          "--max-live-requests",
          "1",
          "--io-pause-ms",
          "10",
          "--io-max-pause-ms",
          "25"
        ])
      end)

    assert output =~ "[maxio heal.fresh_drives] status=dry_run"
    assert output =~ "gate_status=attention"
    assert output =~ "drives_selected=1"
  end

  test "rebalance-if-needed flag uses scheduler bridge and prints enqueue evidence" do
    endpoint = {Node.self(), Path.join(System.tmp_dir!(), "fresh-drive-cli-rebalance")}

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
        FreshDrives.run(["--dry-run", "--rebalance-if-needed"])
      end)

    assert output =~ "[maxio heal.fresh_drives] status=dry_run"
    assert output =~ "gate_status=attention"
    assert output =~ "rebalance_enqueue_status=not_eligible"
    assert output =~ "rebalance_enqueue_reason=dry_run"
    refute output =~ "rebalance_advance_status="
  end

  test "rebalance-if-needed json exposes enqueue evidence" do
    _endpoint = mark_drive_for_fresh_heal("fresh-drive-cli-rebalance-json")

    output =
      capture_io(fn ->
        FreshDrives.run(["--dry-run", "--rebalance-if-needed", "--json"])
      end)

    report = Jason.decode!(String.trim(output))

    assert report["status"] == "dry_run"
    assert report["gate_status"] == "attention"
    assert report["rebalance_enqueue"]["status"] == "not_eligible"
    assert report["rebalance_enqueue"]["reason"] == "dry_run"
    assert report["rebalance_enqueue"]["drives_cleared"] == 0
    refute Map.has_key?(report, "rebalance_advance")
    assert report["warnings"] == ["fresh_drive_heal_dry_run"]
  end

  test "rebalance advance json exposes nested blocked evidence" do
    with_scheduler_config!(
      runner: fn _opts -> {:ok, fake_report(:ok, drives_cleared: 1)} end,
      rebalance_starter: fn _opts ->
        {:ok,
         {:created,
          %{
            id: "fresh-rebalance-json-job",
            kind: "rebalance",
            plan_scanned: 1,
            plan: %{"routing_mismatches" => 0}
          }}}
      end,
      rebalance_advancer: fn _opts ->
        {:ok,
         %{
           status: :blocked,
           job_id: "fresh-rebalance-json-job",
           steps: 1,
           phases: [:copy, :source_cleanup, :rebalance_closure],
           terminal_phase: :rebalance_closure,
           blockers: [:routing_mismatch],
           reason: :rebalance_closure
         }}
      end
    )

    output =
      capture_io(fn ->
        FreshDrives.run(["--rebalance-advance-steps", "1", "--json"])
      end)

    report = Jason.decode!(String.trim(output))

    assert report["status"] == "ok"
    assert report["gate_status"] == "blocked"
    assert report["blockers"] == ["rebalance_advance_blocked"]
    assert report["warnings"] == []
    assert report["rebalance_enqueue"]["status"] == "created"
    assert report["rebalance_enqueue"]["job_id"] == "fresh-rebalance-json-job"
    assert report["rebalance_advance"]["status"] == "blocked"
    assert report["rebalance_advance"]["job_id"] == "fresh-rebalance-json-job"
    assert report["rebalance_advance"]["steps"] == 1

    assert report["rebalance_advance"]["phases"] == [
             "copy",
             "source_cleanup",
             "rebalance_closure"
           ]

    assert report["rebalance_advance"]["terminal_phase"] == "rebalance_closure"
    assert report["rebalance_advance"]["blockers"] == ["routing_mismatch"]
    assert report["rebalance_advance"]["reason"] == "rebalance_closure"
  end

  test "scheduler bridge errors emit blocked json evidence before failing" do
    with_scheduler_config!(runner: fn _opts -> raise "cli-scheduler-boom" end)

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/fresh-drive heal blocked/, fn ->
          FreshDrives.run(["--rebalance-if-needed", "--json", "--fail-on-blocked"])
        end
      end)

    report = Jason.decode!(String.trim(output))

    assert report["status"] == "scheduler_error"
    assert report["gate_status"] == "blocked"
    assert report["errors"] == 1
    assert report["blockers"] == ["fresh_drive_heal_scheduler_error"]
    assert report["warnings"] == []
    assert report["error_reason"] =~ "cli-scheduler-boom"
  end

  test "rebalance-verify-closure implies bounded advance evidence" do
    endpoint = {Node.self(), Path.join(System.tmp_dir!(), "fresh-drive-cli-closure")}

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
        FreshDrives.run(["--dry-run", "--rebalance-verify-closure"])
      end)

    assert output =~ "[maxio heal.fresh_drives] status=dry_run"
    assert output =~ "gate_status=attention"
    assert output =~ "rebalance_enqueue_status=not_eligible"
    assert output =~ "rebalance_advance_status=not_eligible"
    assert output =~ "rebalance_advance_reason={:rebalance_enqueue, :not_eligible}"
  end

  test "rebalance advance steps must be positive" do
    assert_raise Mix.Error, ~r/--rebalance-advance-steps must be a positive integer/, fn ->
      FreshDrives.run(["--rebalance-advance-steps", "0"])
    end
  end

  defp mark_drive_for_fresh_heal(label) do
    endpoint = {Node.self(), Path.join(System.tmp_dir!(), label)}

    _ =
      DriveHealth.record_probe(endpoint, {:error, :unavailable},
        now_ms: 0,
        offline_after_ms: 0,
        set_id: 0,
        set_write_available?: true
      )

    _ = DriveHealth.record_probe(endpoint, :ok, now_ms: 1, offline_after_ms: 0, set_id: 0)

    endpoint
  end

  defp install_runtime_topology! do
    base =
      Path.join(
        System.tmp_dir!(),
        "fresh-drive-cli-topology-#{System.unique_integer([:positive])}"
      )

    endpoints = for i <- 0..5, do: {Node.self(), Path.join(base, "d#{i}")}

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    topo_key = {Topology, :topology}
    previous = :persistent_term.get(topo_key, :__maxio_no_topology__)
    Topology.install_runtime!(topology)

    on_exit(fn ->
      restore_topology(previous)
      File.rm_rf(base)
    end)

    topology
  end

  defp restore_topology(:__maxio_no_topology__), do: :persistent_term.erase({Topology, :topology})
  defp restore_topology(topology), do: :persistent_term.put({Topology, :topology}, topology)

  defp with_scheduler_config!(overrides) do
    previous = Application.get_env(:maxio, :fresh_drive_heal_scheduler, [])
    Application.put_env(:maxio, :fresh_drive_heal_scheduler, Keyword.merge(previous, overrides))

    on_exit(fn ->
      Application.put_env(:maxio, :fresh_drive_heal_scheduler, previous)
    end)
  end

  defp fake_report(status, attrs) do
    %{
      status: status,
      backend: Distributed,
      bucket: nil,
      scan_versions: true,
      dry_run: false,
      max_objects: nil,
      drives_considered: 1,
      drives_selected: 1,
      drives_cleared: 0,
      drives_skipped_same_set: 0,
      drives_waiting: 0,
      sets: 1,
      buckets: 0,
      scanned: 0,
      healed_objects: 0,
      healed_shards: 0,
      unrecoverable: 0,
      missing: 0,
      skipped: 0,
      errors: 0,
      truncated: false
    }
    |> Map.merge(Map.new(attrs))
  end
end
