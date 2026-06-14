defmodule Maxio.Cluster.DriveHardwareEvidenceTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.{DriveHardwareEvidence, DriveIdentity, Topology, Transport.InProcess}

  setup do
    previous_env = Application.get_env(:maxio, :drive_hardware_evidence)
    :ok = InProcess.setup!()

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_drive_hardware_evidence_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      restore_env(previous_env)
      File.rm_rf(base)
    end)

    {:ok, base: base}
  end

  test "sample_local_drive normalizes provider evidence and redacts raw ids by default", %{
    base: base
  } do
    drive = Path.join(base, "d0")
    File.mkdir_p!(drive)

    provider = fn ^drive ->
      {:ok,
       %{
         mount_root: "test-mount",
         mount_source: "/dev/sda1",
         fs_type: "xfs",
         major_minor: "8:1",
         block_device: "sda1",
         parent_device: "sda",
         rotational?: false,
         model: "FAST-DISK",
         serial: "SERIAL-1",
         wwid: "WWID-1",
         source: :test_sysfs
       }}
    end

    summary = DriveHardwareEvidence.sample_local_drive(drive, provider: provider, now_ms: 123)

    assert summary.status == :ok
    assert summary.topology_sets == 0
    assert summary.endpoints == 1
    assert summary.ok == 1
    assert Map.fetch!(summary, :destructive_gate?) == false
    assert [sample] = summary.samples
    assert sample.drive == Path.expand(drive)
    assert sample.mount_root == "test-mount"
    assert sample.mount_source == "/dev/sda1"
    assert sample.fs_type == "xfs"
    assert sample.major_minor == "8:1"
    assert sample.block_device == "sda1"
    assert sample.parent_device == "sda"
    assert sample.rotational? == false
    assert sample.model == "FAST-DISK"
    assert sample.serial_hash == sha256("SERIAL-1")
    assert sample.wwid_hash == sha256("WWID-1")
    assert sample.source == :test_sysfs
    assert sample.confidence == :high
    assert sample.observed_at_ms == 123
    assert Map.fetch!(sample, :destructive_gate?) == false
    refute Map.has_key?(sample, :serial)
    refute Map.has_key?(sample, :wwid)
    refute Map.has_key?(sample, :smart)
  end

  test "show_raw explicitly includes raw serial and wwid", %{base: base} do
    drive = Path.join(base, "d1")
    File.mkdir_p!(drive)

    provider = fn ^drive -> {:ok, %{serial: "SERIAL-RAW", wwid: "WWID-RAW"}} end

    summary =
      DriveHardwareEvidence.sample_local_drive(drive,
        provider: provider,
        show_raw: true,
        now_ms: 124
      )

    assert [%{serial: "SERIAL-RAW", wwid: "WWID-RAW"}] = summary.samples
  end

  test "provider-supplied malformed hash fields are re-hashed before output", %{base: base} do
    drive = Path.join(base, "d1-hash")
    File.mkdir_p!(drive)

    provider = fn ^drive ->
      {:ok,
       %{
         serial_hash: "SERIAL-LEAK",
         wwid_hash: "WWID-LEAK",
         source: :test_sysfs
       }}
    end

    summary = DriveHardwareEvidence.sample_local_drive(drive, provider: provider, now_ms: 125)

    assert [%{serial_hash: serial_hash, wwid_hash: wwid_hash}] = summary.samples
    assert serial_hash == sha256("SERIAL-LEAK")
    assert wwid_hash == sha256("WWID-LEAK")
    refute inspect(summary) =~ "SERIAL-LEAK"
    refute inspect(summary) =~ "WWID-LEAK"
  end

  test "opt-in SMART evidence parses ATA smartctl JSON and redacts raw SMART identity", %{
    base: base
  } do
    drive = Path.join(base, "smart-ata")
    File.mkdir_p!(drive)

    provider = fn ^drive ->
      {:ok,
       %{
         mount_root: "smart-mount",
         mount_source: "/dev/sda1",
         block_device: "sda1",
         parent_device: "sda",
         source: :test_sysfs
       }}
    end

    smart_runner = fn device, args ->
      assert device == "/dev/sda"
      assert args == ["-j", "-a", "-n", "standby", "/dev/sda"]

      {Jason.encode!(ata_smart_json()), 0}
    end

    summary =
      DriveHardwareEvidence.sample_local_drive(drive,
        provider: provider,
        smart: true,
        smart_runner: smart_runner,
        now_ms: 126
      )

    assert [%{status: :ok, smart: smart}] = summary.samples
    assert smart.status == :passed
    assert smart.source == :smartctl_json
    assert smart.device == "/dev/sda"
    assert smart.exit_status == 0
    assert smart.smart_status_passed? == true
    assert smart.smart_support_available? == true
    assert smart.smart_support_enabled? == true
    assert smart.model_name == "SMART-DISK"
    assert smart.firmware_version == "1.2.3"
    assert smart.serial_hash == sha256("SMART-SERIAL")
    assert smart.wwn_hash == sha256("5:123456:789")
    assert smart.temperature_celsius == 31
    assert smart.power_on_hours == 99
    assert smart.power_cycle_count == 7
    assert smart.reallocated_sector_count == 1
    assert smart.current_pending_sector == 2
    assert smart.offline_uncorrectable == 3
    assert smart.udma_crc_error_count == 4
    assert smart.error_log_count == 5
    assert smart.self_test_failure_count == 1
    assert smart.latest_self_test_status == "Completed: read failure"
    refute Map.has_key?(smart, :serial_number)
    refute Map.has_key?(smart, :wwn)
    refute inspect(summary) =~ "SMART-SERIAL"
  end

  test "show_raw exposes allowlisted raw SMART identity but never full smartctl JSON", %{
    base: base
  } do
    drive = Path.join(base, "smart-raw")
    File.mkdir_p!(drive)

    provider = fn ^drive ->
      {:ok, %{mount_source: "/dev/sdb", block_device: "sdb", source: :test_sysfs}}
    end

    summary =
      DriveHardwareEvidence.sample_local_drive(drive,
        provider: provider,
        smart: true,
        show_raw: true,
        smart_runner: fn _device, _args -> {Jason.encode!(ata_smart_json()), 0} end,
        now_ms: 127
      )

    assert [%{smart: smart}] = summary.samples
    assert smart.serial_number == "SMART-SERIAL"
    assert smart.wwn == "5:123456:789"
    refute inspect(summary) =~ "ata_smart_attributes"
  end

  test "opt-in SMART evidence parses NVMe smartctl JSON", %{base: base} do
    drive = Path.join(base, "smart-nvme")
    File.mkdir_p!(drive)

    provider = fn ^drive ->
      {:ok,
       %{
         mount_source: "/dev/nvme0n1p1",
         block_device: "nvme0n1p1",
         parent_device: "nvme0n1",
         source: :test_sysfs
       }}
    end

    summary =
      DriveHardwareEvidence.sample_local_drive(drive,
        provider: provider,
        smart: true,
        smart_nocheck: :never,
        smart_runner: fn device, args ->
          assert device == "/dev/nvme0n1"
          assert args == ["-j", "-a", "/dev/nvme0n1"]
          {Jason.encode!(nvme_smart_json()), 4}
        end,
        now_ms: 128
      )

    assert [%{smart: smart}] = summary.samples
    assert smart.status == :unknown
    assert smart.exit_status == 4
    assert smart.eui64_hash == sha256("EUI64-RAW")
    assert smart.nguid_hash == sha256("NGUID-RAW")
    assert smart.critical_warning == 1
    assert smart.percentage_used == 12
    assert smart.available_spare == 98
    assert smart.media_errors == 6
    assert smart.unsafe_shutdowns == 8
    assert smart.error_log_count == 11
    assert smart.exit_flags == [:command_failed]
    refute inspect(summary) =~ "EUI64-RAW"
    refute inspect(summary) =~ "NGUID-RAW"
  end

  test "SMART exit bitmask is decoded even when JSON reports passed", %{base: base} do
    drive = Path.join(base, "smart-exit")
    File.mkdir_p!(drive)

    provider = fn ^drive ->
      {:ok, %{mount_source: "/dev/sdd", block_device: "sdd", source: :test_sysfs}}
    end

    summary =
      DriveHardwareEvidence.sample_local_drive(drive,
        provider: provider,
        smart: true,
        smart_runner: fn _device, _args ->
          {Jason.encode!(%{"smart_status" => %{"passed" => true}}), 0b1100_1000}
        end,
        now_ms: 132
      )

    assert [
             %{
               status: :ok,
               smart: %{
                 status: :passed,
                 smart_status_passed?: true,
                 exit_status: 0b1100_1000,
                 exit_flags: [
                   :disk_failing,
                   :device_error_log_contains_records,
                   :self_test_log_contains_errors
                 ]
               }
             }
           ] = summary.samples
  end

  test "SMART probe failures stay attached to ok base evidence", %{base: base} do
    drive = Path.join(base, "smart-fail")
    File.mkdir_p!(drive)

    provider = fn ^drive ->
      {:ok, %{mount_source: "/dev/sdc", block_device: "sdc", source: :test_sysfs}}
    end

    timeout_summary =
      DriveHardwareEvidence.sample_local_drive(drive,
        provider: provider,
        smart: true,
        smart_runner: fn _device, _args -> {:error, :timeout} end,
        now_ms: 129
      )

    assert timeout_summary.status == :ok
    assert [%{status: :ok, smart: %{status: :timeout, error: :timeout}}] = timeout_summary.samples

    invalid_json_summary =
      DriveHardwareEvidence.sample_local_drive(drive,
        provider: provider,
        smart: true,
        smart_runner: fn _device, _args -> {"not-json SERIAL-SMART", 2} end,
        now_ms: 130
      )

    assert invalid_json_summary.status == :ok

    assert [%{status: :ok, smart: %{status: :invalid_json, exit_status: 2}}] =
             invalid_json_summary.samples

    refute inspect(invalid_json_summary) =~ "SERIAL-SMART"
  end

  test "base provider failure does not invoke SMART runner", %{base: base} do
    drive = Path.join(base, "smart-base-error")
    File.mkdir_p!(drive)

    summary =
      DriveHardwareEvidence.sample_local_drive(drive,
        provider: fn ^drive -> {:error, {:probe_failed, "SERIAL-BASE"}} end,
        smart: true,
        smart_runner: fn _device, _args -> raise "should not run" end,
        now_ms: 131
      )

    assert summary.status == :partial
    assert [%{status: :error, reason: {:probe_failed, "[redacted]"}}] = summary.samples
    refute inspect(summary) =~ "SERIAL-BASE"
  end

  test "provider errors and crashes are structured evidence failures", %{base: base} do
    drive = Path.join(base, "d2")
    File.mkdir_p!(drive)

    error_summary =
      DriveHardwareEvidence.sample_local_drive(drive,
        provider: fn ^drive -> {:error, :unsupported_os} end,
        now_ms: 10
      )

    assert error_summary.status == :partial
    assert error_summary.ok == 0
    assert error_summary.errors == 1
    assert [%{status: :error, reason: :unsupported_os}] = error_summary.samples
    assert Map.fetch!(hd(error_summary.samples), :destructive_gate?) == false

    crash_summary =
      DriveHardwareEvidence.sample_local_drive(drive,
        provider: fn ^drive -> raise "sysfs failed SERIAL-SECRET" end,
        now_ms: 11
      )

    assert crash_summary.status == :partial

    assert [%{status: :error, reason: {:exception, "[redacted]"}}] =
             crash_summary.samples

    raw_error_summary =
      DriveHardwareEvidence.sample_local_drive(drive,
        provider: fn ^drive -> {:error, {:probe_failed, "SERIAL-SECRET"}} end,
        show_raw: true,
        now_ms: 12
      )

    assert [%{status: :error, reason: {:probe_failed, "SERIAL-SECRET"}}] =
             raw_error_summary.samples
  end

  test "sample_topology probes endpoints through transport without writing identity rows", %{
    base: base
  } do
    drive0 = Path.join(base, "d3")
    drive1 = Path.join(base, "d4")
    File.mkdir_p!(drive0)
    File.mkdir_p!(drive1)

    topology =
      Topology.parse_and_validate!(
        data_shards: 1,
        parity_shards: 1,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [
          %{
            id: 0,
            sets: [
              %{
                id: 0,
                endpoints: [
                  {Node.self(), drive0},
                  {:maxio@remote, drive1}
                ]
              }
            ]
          }
        ]
      )

    Application.put_env(:maxio, :drive_hardware_evidence,
      provider: fn
        ^drive0 -> {:ok, %{mount_root: "m0", major_minor: "8:1", block_device: "sda1"}}
        ^drive1 -> {:ok, %{mount_root: "m1", major_minor: "8:2", block_device: "sdb1"}}
      end
    )

    summary =
      DriveHardwareEvidence.sample_topology(
        topology: topology,
        transport: InProcess,
        now_ms: 300
      )

    assert summary.status == :ok
    assert summary.topology_sets == 1
    assert summary.endpoints == 2
    assert summary.ok == 2

    assert Enum.map(summary.samples, & &1.endpoint) == [
             {Node.self(), Path.expand(drive0)},
             {:maxio@remote, Path.expand(drive1)}
           ]

    assert DriveIdentity.snapshot() == []
  end

  test "sample_endpoints summarizes a bounded endpoint list without raw identifiers", %{
    base: base
  } do
    drive0 = Path.join(base, "d4a")
    drive1 = Path.join(base, "d4b")
    File.mkdir_p!(drive0)
    File.mkdir_p!(drive1)

    provider = fn
      ^drive0 -> {:ok, %{mount_root: "m0", serial: "SERIAL-0", source: :test_sysfs}}
      ^drive1 -> {:error, {:probe_failed, "SERIAL-1"}}
    end

    summary =
      DriveHardwareEvidence.sample_endpoints(
        [{Node.self(), drive0}, {Node.self(), drive1}],
        transport: InProcess,
        provider: provider,
        set_id: 9,
        topology_sets: 1,
        now_ms: 333
      )

    assert summary.status == :partial
    assert summary.topology_sets == 1
    assert summary.endpoints == 2
    assert summary.ok == 1
    assert summary.errors == 1

    assert [
             %{
               status: :ok,
               endpoint: {_, expanded0},
               set_id: 9,
               endpoint_index: 0,
               serial_hash: serial_hash
             },
             %{
               status: :error,
               endpoint: {_, expanded1},
               set_id: 9,
               endpoint_index: 1,
               reason: {:probe_failed, "[redacted]"}
             }
           ] = summary.samples

    assert expanded0 == Path.expand(drive0)
    assert expanded1 == Path.expand(drive1)
    assert serial_hash == sha256("SERIAL-0")
    refute inspect(summary) =~ "SERIAL-"
  end

  test "remote endpoint uses owning-node provider config instead of caller provider", %{
    base: base
  } do
    local_drive = Path.join(base, "d5")
    remote_drive = Path.join(base, "d6")
    File.mkdir_p!(local_drive)
    File.mkdir_p!(remote_drive)

    topology =
      Topology.parse_and_validate!(
        data_shards: 1,
        parity_shards: 1,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [
          %{
            id: 0,
            sets: [
              %{
                id: 0,
                endpoints: [
                  {Node.self(), local_drive},
                  {:maxio@remote, remote_drive}
                ]
              }
            ]
          }
        ]
      )

    Application.put_env(:maxio, :drive_hardware_evidence,
      provider: fn ^remote_drive ->
        {:ok, %{mount_root: "remote-owned", major_minor: "8:2", block_device: "sdb1"}}
      end
    )

    caller_provider = fn
      ^local_drive ->
        {:ok, %{mount_root: "caller-local", major_minor: "8:1", block_device: "sda1"}}

      ^remote_drive ->
        raise "coordinator provider leaked SERIAL-REMOTE"
    end

    summary =
      DriveHardwareEvidence.sample_topology(
        topology: topology,
        transport: InProcess,
        provider: caller_provider,
        now_ms: 301
      )

    assert summary.status == :ok
    assert Enum.map(summary.samples, & &1.mount_root) == ["caller-local", "remote-owned"]
  end

  test "remote SMART evidence uses owning-node runner config instead of caller runner", %{
    base: base
  } do
    local_drive = Path.join(base, "smart-local")
    remote_drive = Path.join(base, "smart-remote")
    File.mkdir_p!(local_drive)
    File.mkdir_p!(remote_drive)

    topology =
      Topology.parse_and_validate!(
        data_shards: 1,
        parity_shards: 1,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [
          %{
            id: 0,
            sets: [
              %{
                id: 0,
                endpoints: [
                  {Node.self(), local_drive},
                  {:maxio@remote, remote_drive}
                ]
              }
            ]
          }
        ]
      )

    Application.put_env(:maxio, :drive_hardware_evidence,
      provider: fn
        ^remote_drive -> {:ok, %{mount_source: "/dev/sdz", block_device: "sdz"}}
        ^local_drive -> {:ok, %{mount_source: "/dev/sda", block_device: "sda"}}
      end,
      smart_runner: fn
        "/dev/sdz", _args -> {Jason.encode!(%{"smart_status" => %{"passed" => false}}), 8}
        "/dev/sda", _args -> raise "coordinator smart runner leaked to env"
      end
    )

    caller_provider = fn ^local_drive ->
      {:ok, %{mount_source: "/dev/sda", block_device: "sda"}}
    end

    caller_runner = fn
      "/dev/sda", _args -> {Jason.encode!(%{"smart_status" => %{"passed" => true}}), 0}
      "/dev/sdz", _args -> raise "coordinator smart runner leaked to remote"
    end

    summary =
      DriveHardwareEvidence.sample_topology(
        topology: topology,
        transport: InProcess,
        provider: caller_provider,
        smart: true,
        smart_runner: caller_runner,
        now_ms: 302
      )

    assert summary.status == :ok
    assert Enum.map(summary.samples, & &1.smart.status) == [:passed, :failed]
    assert Enum.map(summary.samples, & &1.smart.device) == ["/dev/sda", "/dev/sdz"]
  end

  test "no topology returns an explicit no_topology summary" do
    summary = DriveHardwareEvidence.sample_topology(topology: nil)

    assert summary.status == :no_topology
    assert summary.topology_sets == 0
    assert summary.endpoints == 0
    assert summary.samples == []
    assert Map.fetch!(summary, :destructive_gate?) == false
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp ata_smart_json do
    %{
      "smart_status" => %{"passed" => true},
      "smart_support" => %{"available" => true, "enabled" => true},
      "model_name" => "SMART-DISK",
      "firmware_version" => "1.2.3",
      "serial_number" => "SMART-SERIAL",
      "wwn" => %{"naa" => 5, "oui" => 123_456, "id" => 789},
      "temperature" => %{"current" => 31},
      "power_on_time" => %{"hours" => 99},
      "power_cycle_count" => 7,
      "ata_smart_attributes" => %{
        "table" => [
          %{"name" => "Reallocated_Sector_Ct", "raw" => %{"value" => 1}},
          %{"name" => "Current_Pending_Sector", "raw" => %{"value" => 2}},
          %{"name" => "Offline_Uncorrectable", "raw" => %{"value" => 3}},
          %{"name" => "UDMA_CRC_Error_Count", "raw" => %{"value" => 4}}
        ]
      },
      "ata_smart_error_log" => %{"summary" => %{"count" => 5}},
      "ata_smart_self_test_log" => %{
        "standard" => %{
          "table" => [
            %{"status" => %{"passed" => false, "string" => "Completed: read failure"}},
            %{"status" => %{"passed" => true, "string" => "Completed without error"}}
          ]
        }
      }
    }
  end

  defp nvme_smart_json do
    %{
      "eui64" => "EUI64-RAW",
      "nguid" => "NGUID-RAW",
      "nvme_smart_health_information_log" => %{
        "critical_warning" => 1,
        "percentage_used" => 12,
        "available_spare" => 98,
        "media_errors" => 6,
        "unsafe_shutdowns" => 8,
        "num_err_log_entries" => 11
      }
    }
  end

  defp restore_env(nil), do: Application.delete_env(:maxio, :drive_hardware_evidence)
  defp restore_env(value), do: Application.put_env(:maxio, :drive_hardware_evidence, value)
end
