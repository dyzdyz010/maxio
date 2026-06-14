defmodule Mix.Tasks.Maxio.Drive.HardwareEvidenceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Maxio.Cluster.{Topology, Transport.InProcess}
  alias Mix.Tasks.Maxio.Drive.HardwareEvidence

  @task "maxio.drive.hardware_evidence"

  setup do
    previous_env = Application.get_env(:maxio, :drive_hardware_evidence)
    previous_transport = Application.get_env(:maxio, :shard_transport)
    previous_topology_config = Application.get_env(:maxio, Topology)
    previous_topology_source = Application.get_env(:maxio, :topology_source)
    topo_key = {Topology, :topology}
    previous_topology = :persistent_term.get(topo_key, :__maxio_no_topology__)
    :ok = InProcess.setup!()

    Application.put_env(:maxio, :shard_transport, InProcess)
    :persistent_term.erase(topo_key)
    Mix.Task.reenable(@task)

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_drive_hardware_evidence_cli_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      restore_env(:drive_hardware_evidence, previous_env)
      restore_env(:shard_transport, previous_transport)
      restore_env(Topology, previous_topology_config)
      restore_env(:topology_source, previous_topology_source)
      restore_topology(previous_topology)
      Mix.Task.reenable(@task)
      File.rm_rf(base)
    end)

    {:ok, base: base}
  end

  test "prints local hardware evidence with raw ids redacted by default", %{base: base} do
    drive = Path.join(base, "d0")
    File.mkdir_p!(drive)
    put_provider(drive)

    output = run_task(["--drive", drive])

    assert output =~ "[maxio drive.hardware_evidence] status=ok mode=drive"
    assert output =~ "topology_sets=0 endpoints=1 ok=1 errors=0"
    assert output =~ "destructive_gate=false"
    assert output =~ "[maxio drive.hardware_evidence.sample] status=ok"
    assert output =~ "mount_root=\"cli-mount\""
    assert output =~ "mount_source=\"/dev/sda1\""
    assert output =~ "major_minor=\"8:1\""
    assert output =~ "block_device=\"sda1\""
    assert output =~ "serial_hash=#{sha256("SERIAL-CLI")}"
    assert output =~ "wwid_hash=#{sha256("WWID-CLI")}"
    refute output =~ "SERIAL-CLI"
    refute output =~ "WWID-CLI"
    refute output =~ "smart_status="
  end

  test "show-raw prints raw hardware identifiers explicitly", %{base: base} do
    drive = Path.join(base, "d1")
    File.mkdir_p!(drive)
    put_provider(drive)

    output = run_task(["--drive", drive, "--show-raw"])

    assert output =~ "serial=\"SERIAL-CLI\""
    assert output =~ "wwid=\"WWID-CLI\""
  end

  test "json output redacts raw ids unless show-raw is present", %{base: base} do
    drive = Path.join(base, "d2")
    File.mkdir_p!(drive)
    put_provider(drive)

    decoded = run_task(["--drive", drive, "--json"]) |> Jason.decode!()
    [sample] = decoded["samples"]

    assert decoded["status"] == "ok"
    assert decoded["destructive_gate?"] == false
    assert sample["serial_hash"] == sha256("SERIAL-CLI")
    refute Map.has_key?(sample, "serial")
    refute Map.has_key?(sample, "wwid")

    raw_decoded = run_task(["--drive", drive, "--json", "--show-raw"]) |> Jason.decode!()
    [raw_sample] = raw_decoded["samples"]

    assert raw_sample["serial"] == "SERIAL-CLI"
    assert raw_sample["wwid"] == "WWID-CLI"
  end

  test "smart flag prints allowlisted SMART evidence without raw identity by default", %{
    base: base
  } do
    drive = Path.join(base, "smart-d0")
    File.mkdir_p!(drive)
    put_provider(drive)
    put_smart_runner()

    output = run_task(["--drive", drive, "--smart"])

    assert output =~ "smart_status=passed"
    assert output =~ "smart_device=\"/dev/sda\""
    assert output =~ "smart_exit_status=0"
    assert output =~ "serial_hash=#{sha256("SERIAL-CLI")}"
    refute output =~ "SMART-SERIAL-CLI"
    refute output =~ "ata_smart_attributes"

    decoded = run_task(["--drive", drive, "--smart", "--json"]) |> Jason.decode!()
    [sample] = decoded["samples"]

    assert sample["smart"]["status"] == "passed"
    assert sample["smart"]["device"] == "/dev/sda"
    assert sample["smart"]["serial_hash"] == sha256("SMART-SERIAL-CLI")
    assert sample["smart"]["reallocated_sector_count"] == 9
    refute Map.has_key?(sample["smart"], "serial_number")
  end

  test "show-raw exposes allowlisted raw SMART identity in JSON", %{base: base} do
    drive = Path.join(base, "smart-raw-d0")
    File.mkdir_p!(drive)
    put_provider(drive)
    put_smart_runner()

    decoded =
      run_task(["--drive", drive, "--smart", "--json", "--show-raw"])
      |> Jason.decode!()

    [sample] = decoded["samples"]

    assert sample["smart"]["serial_number"] == "SMART-SERIAL-CLI"
    assert sample["smart"]["wwn"] == "5:456:789"
    refute inspect(decoded) =~ "ata_smart_attributes"
  end

  test "smart failures do not make the base sample an error", %{base: base} do
    drive = Path.join(base, "smart-fail-d0")
    File.mkdir_p!(drive)
    put_provider(drive)

    Application.put_env(:maxio, :drive_hardware_evidence,
      provider: fn ^drive ->
        {:ok,
         %{
           mount_root: "cli-mount",
           mount_source: "/dev/sda1",
           block_device: "sda1",
           parent_device: "sda"
         }}
      end,
      smart_runner: fn _device, _args -> {:error, :permission_denied} end
    )

    decoded = run_task(["--drive", drive, "--smart", "--json"]) |> Jason.decode!()
    [sample] = decoded["samples"]

    assert decoded["status"] == "ok"
    assert sample["status"] == "ok"
    assert sample["smart"]["status"] == "permission_denied"
    assert sample["smart"]["error"] == "permission_denied"
  end

  test "error output redacts provider string reasons unless show-raw is present", %{base: base} do
    drive = Path.join(base, "error-d0")
    File.mkdir_p!(drive)

    Application.put_env(:maxio, :drive_hardware_evidence,
      provider: fn ^drive -> {:error, {:probe_failed, "SERIAL-ERROR"}} end
    )

    output = run_task(["--drive", drive])

    assert output =~ "reason={:probe_failed, \"[redacted]\"}"
    refute output =~ "SERIAL-ERROR"

    decoded = run_task(["--drive", drive, "--json"]) |> Jason.decode!()
    [sample] = decoded["samples"]

    assert sample["reason"] == ["probe_failed", "[redacted]"]
    refute run_task(["--drive", drive, "--json"]) =~ "SERIAL-ERROR"

    raw_output = run_task(["--drive", drive, "--show-raw"])

    assert raw_output =~ "SERIAL-ERROR"
  end

  test "summary-only suppresses per-drive rows for topology mode", %{base: base} do
    drive = Path.join(base, "d3")
    sibling_drive = Path.join(base, "d4")
    File.mkdir_p!(drive)
    File.mkdir_p!(sibling_drive)

    Application.put_env(:maxio, :drive_hardware_evidence,
      provider: fn
        ^drive ->
          {:ok, %{mount_root: "cli-mount", major_minor: "8:1", block_device: "sda1"}}

        ^sibling_drive ->
          {:ok, %{mount_root: "cli-mount-2", major_minor: "8:2", block_device: "sdb1"}}
      end
    )

    put_topology([{Node.self(), drive}, {Node.self(), sibling_drive}])

    output = run_task(["--summary-only"])

    assert output =~ "[maxio drive.hardware_evidence] status=ok mode=topology"
    assert output =~ "topology_sets=1 endpoints=2 ok=2 errors=0"
    refute output =~ "[maxio drive.hardware_evidence.sample]"
  end

  test "topology mode can read config topology without app.start", %{base: base} do
    drive = Path.join(base, "config-d0")
    sibling_drive = Path.join(base, "config-d1")
    File.mkdir_p!(drive)
    File.mkdir_p!(sibling_drive)

    Application.put_env(:maxio, :topology_source, :config)

    Application.put_env(:maxio, Topology,
      data_shards: 1,
      parity_shards: 1,
      block_size: 1024,
      allow_colocated_endpoints: true,
      pools: [
        %{
          id: 0,
          sets: [%{id: 0, endpoints: [{Node.self(), drive}, {Node.self(), sibling_drive}]}]
        }
      ]
    )

    Application.put_env(:maxio, :drive_hardware_evidence,
      provider: fn
        ^drive ->
          {:ok, %{mount_root: "config-mount-0", major_minor: "8:1", block_device: "sda1"}}

        ^sibling_drive ->
          {:ok, %{mount_root: "config-mount-1", major_minor: "8:2", block_device: "sdb1"}}
      end
    )

    output = run_task(["--summary-only"])

    assert output =~ "[maxio drive.hardware_evidence] status=ok mode=topology"
    assert output =~ "topology_sets=1 endpoints=2 ok=2 errors=0"
  end

  test "without drive or topology prints explicit no_topology", %{base: _base} do
    output = run_task(["--summary-only"])

    assert output =~ "[maxio drive.hardware_evidence] status=no_topology mode=topology"
    assert output =~ "topology_sets=0 endpoints=0 ok=0 errors=0"
    assert output =~ "destructive_gate=false"
  end

  test "invalid args raise usage" do
    assert_raise Mix.Error, ~r/usage: mix maxio\.drive\.hardware_evidence/, fn ->
      HardwareEvidence.run(["unexpected"])
    end
  end

  test "invalid smart options raise usage" do
    assert_raise Mix.Error, ~r/--smart-timeout-ms must be a positive integer/, fn ->
      HardwareEvidence.run(["--smart", "--smart-timeout-ms", "0"])
    end

    assert_raise Mix.Error, ~r/--smart-nocheck must be one of/, fn ->
      HardwareEvidence.run(["--smart", "--smart-nocheck", "wake"])
    end
  end

  defp run_task(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> HardwareEvidence.run(args) end)
  end

  defp put_provider(drive) do
    Application.put_env(:maxio, :drive_hardware_evidence,
      provider: fn ^drive ->
        {:ok,
         %{
           mount_root: "cli-mount",
           mount_source: "/dev/sda1",
           fs_type: "xfs",
           major_minor: "8:1",
           block_device: "sda1",
           parent_device: "sda",
           rotational?: false,
           model: "CLI-DISK",
           serial: "SERIAL-CLI",
           wwid: "WWID-CLI",
           source: :test_sysfs
         }}
      end
    )
  end

  defp put_smart_runner do
    previous = Application.get_env(:maxio, :drive_hardware_evidence, [])

    Application.put_env(
      :maxio,
      :drive_hardware_evidence,
      Keyword.put(previous, :smart_runner, fn device, args ->
        assert device == "/dev/sda"
        assert args == ["-j", "-a", "-n", "standby", "/dev/sda"]
        {Jason.encode!(smart_json()), 0}
      end)
    )
  end

  defp put_topology(endpoints) do
    topology =
      Topology.parse_and_validate!(
        data_shards: 1,
        parity_shards: 1,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    :persistent_term.put({Topology, :topology}, topology)
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp smart_json do
    %{
      "smart_status" => %{"passed" => true},
      "smart_support" => %{"available" => true, "enabled" => true},
      "serial_number" => "SMART-SERIAL-CLI",
      "wwn" => %{"naa" => 5, "oui" => 456, "id" => 789},
      "ata_smart_attributes" => %{
        "table" => [
          %{"name" => "Reallocated_Sector_Ct", "raw" => %{"value" => 9}}
        ]
      }
    }
  end

  defp restore_topology(:__maxio_no_topology__), do: :persistent_term.erase({Topology, :topology})
  defp restore_topology(topology), do: :persistent_term.put({Topology, :topology}, topology)

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
