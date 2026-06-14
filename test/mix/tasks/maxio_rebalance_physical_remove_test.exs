defmodule Mix.Tasks.MaxioRebalancePhysicalRemoveTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Buckets

  alias Maxio.Cluster.{
    Placement,
    Rebalance.Job,
    Rebalance.Jobs,
    Rebalance.TopologyMutation,
    Topology
  }

  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Repo
  alias Maxio.Storage.Distributed
  alias Mix.Tasks.Maxio.Rebalance.PhysicalRemove
  alias Mix.Tasks.Maxio.Rebalance.Status

  @owner "arn:aws:iam:::root"
  @task "maxio.rebalance.physical_remove"
  @status_task "maxio.rebalance.status"
  @topology_key {Maxio.Cluster.Topology, :topology}

  setup do
    InProcess.setup!()
    previous_backend = Application.get_env(:maxio, :storage_backend)
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)
    previous_hardware_evidence = Application.get_env(:maxio, :drive_hardware_evidence)
    Application.put_env(:maxio, :storage_backend, Distributed)
    Mix.Task.reenable(@task)
    Mix.Task.reenable(@status_task)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous_backend)
      restore_hardware_evidence(previous_hardware_evidence)
      restore_topology(previous_topology)
      Mix.Task.reenable(@task)
      Mix.Task.reenable(@status_task)
    end)

    :ok
  end

  test "requires matching confirm job id" do
    assert_raise Mix.Error, ~r/--confirm-job-id <same uuid>/, fn ->
      PhysicalRemove.run(["--job-id", Ecto.UUID.generate()])
    end
  end

  test "json output reports quarantined layout roots" do
    {topology, base} = topology()
    on_exit(fn -> File.rm_rf(base) end)
    :persistent_term.put(@topology_key, topology)
    {job, bucket, _apply_report} = verified_empty_decommission!("physical-remove-cli", topology)

    Application.put_env(:maxio, :drive_hardware_evidence,
      provider: fn drive ->
        {:ok,
         %{
           mount_root: Path.expand(drive),
           serial: "SERIAL-#{Path.basename(drive)}",
           wwid: "WWID-#{Path.basename(drive)}",
           source: :test_sysfs
         }}
      end
    )

    output =
      capture_io(fn ->
        PhysicalRemove.run([
          "--job-id",
          job.id,
          "--confirm-job-id",
          job.id,
          "--hardware-evidence",
          "--json"
        ])
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "quarantined"
    assert decoded["physical_removal"] == "layout_quarantine"
    assert decoded["topology_mutation"] == false
    assert decoded["deployment_config_mutation"] == false
    assert decoded["errors"] == 0
    assert decoded["markers_written"] == 2
    assert decoded["drive_hardware_evidence"]["status"] == "ok"
    assert decoded["drive_hardware_evidence"]["endpoints"] == 2
    assert decoded["results"]["drive_hardware_evidence"]["status"] == "ok"
    assert decoded["results"]["drive_hardware_evidence"]["drive_hardware_evidence_gate"] == false
    refute output =~ "SERIAL-"
    refute output =~ "WWID-"

    Mix.Task.reenable(@status_task)

    status_output =
      capture_io(fn ->
        Status.run(["--job-id", job.id, "--json"])
      end)

    status_decoded = Jason.decode!(status_output)
    assert status_decoded["physical_removal_results"]["drive_hardware_evidence"]["status"] == "ok"
    refute status_output =~ "SERIAL-"
    refute status_output =~ "WWID-"

    {:ok, stored} = Jobs.get(job.id)

    raw_results =
      put_in(stored.physical_removal_results, ["drive_hardware_evidence", "samples"], [
        %{
          "status" => "ok",
          "serial" => "SERIAL-RAW-ROW",
          "wwid" => "WWID-RAW-ROW",
          "serial_hash" => "SERIAL-HASH-ROW",
          "wwid_hash" => "WWID-HASH-ROW"
        }
      ])

    stored
    |> Job.changeset(%{physical_removal_results: raw_results})
    |> Repo.update!()

    Mix.Task.reenable(@status_task)

    repaired_status_output =
      capture_io(fn ->
        Status.run(["--job-id", job.id, "--json"])
      end)

    repaired_status = Jason.decode!(repaired_status_output)
    [sample] = repaired_status["physical_removal_results"]["drive_hardware_evidence"]["samples"]
    refute Map.has_key?(sample, "serial")
    refute Map.has_key?(sample, "wwid")
    assert sample["serial_hash"] == sha256("SERIAL-HASH-ROW")
    assert sample["wwid_hash"] == sha256("WWID-HASH-ROW")
    refute repaired_status_output =~ "SERIAL-"
    refute repaired_status_output =~ "WWID-"

    Mix.Task.reenable(@task)

    idempotent_output =
      capture_io(fn ->
        PhysicalRemove.run(["--job-id", job.id, "--confirm-job-id", job.id, "--json"])
      end)

    idempotent_decoded = Jason.decode!(idempotent_output)

    [idempotent_sample] =
      idempotent_decoded["results"]["drive_hardware_evidence"]["samples"]

    assert idempotent_decoded["status"] == "already_quarantined"
    refute Map.has_key?(idempotent_sample, "serial")
    refute Map.has_key?(idempotent_sample, "wwid")
    assert idempotent_sample["serial_hash"] == sha256("SERIAL-HASH-ROW")
    assert idempotent_sample["wwid_hash"] == sha256("WWID-HASH-ROW")
    refute idempotent_output =~ "SERIAL-"
    refute idempotent_output =~ "WWID-"

    for {_node, drive} <- Topology.endpoints_from(topology, 0) do
      quarantine = Path.join([drive, ".maxio-removal-quarantine", decoded["quarantine_id"]])
      refute File.exists?(Path.join(drive, bucket))
      assert File.dir?(Path.join([quarantine, "buckets", bucket]))
    end
  end

  defp verified_empty_decommission!(prefix, topology) do
    bucket = bucket_name(prefix)
    opts = [topology: topology, transport: InProcess]
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, complete} = Jobs.complete_data_movement(job.id)
    {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)
    {:ok, complete} = Jobs.complete_source_cleanup(cleaning.id)

    {:ok, apply_report} =
      TopologyMutation.apply_removal_cluster(complete.id,
        topology: topology,
        transport: InProcess,
        expected_current_topology_hash: Placement.topology_hash(topology),
        lock_opts: [nodes: [Node.self()]]
      )

    {:ok, _verified} =
      Jobs.mark_topology_removal_deployment_verified(apply_report.job_id, %{
        deployment_topology_hash: apply_report.proposed_topology_hash
      })

    {complete, bucket, apply_report}
  end

  defp topology do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_physical_remove_cli_#{System.unique_integer([:positive])}"
      )

    endpoints0 = for i <- 0..1, do: {Node.self(), Path.join(base, "s0d#{i}")}
    endpoints1 = for i <- 0..1, do: {Node.self(), Path.join(base, "s1d#{i}")}

    topology =
      Topology.parse_and_validate!(
        data_shards: 1,
        parity_shards: 1,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [
          %{id: 0, sets: [%{id: 0, endpoints: endpoints0}, %{id: 1, endpoints: endpoints1}]}
        ]
      )

    {topology, base}
  end

  defp bucket_name(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.replace("-", "")

    "#{prefix}-#{suffix}"
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp restore_topology(:__maxio_no_topology__),
    do: :persistent_term.erase(@topology_key)

  defp restore_topology(topology),
    do: :persistent_term.put(@topology_key, topology)

  defp restore_hardware_evidence(nil),
    do: Application.delete_env(:maxio, :drive_hardware_evidence)

  defp restore_hardware_evidence(value),
    do: Application.put_env(:maxio, :drive_hardware_evidence, value)
end
