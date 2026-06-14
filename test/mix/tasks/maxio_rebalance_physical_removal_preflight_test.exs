defmodule Mix.Tasks.MaxioRebalancePhysicalRemovalPreflightTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Buckets
  alias Maxio.Cluster.{Placement, Rebalance.Jobs, Rebalance.TopologyMutation, Topology}
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.Distributed
  alias Mix.Tasks.Maxio.Rebalance.PhysicalRemovalPreflight

  @owner "arn:aws:iam:::root"
  @task "maxio.rebalance.physical_removal_preflight"
  @topology_key {Maxio.Cluster.Topology, :topology}

  setup do
    InProcess.setup!()
    previous_backend = Application.get_env(:maxio, :storage_backend)
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)
    previous_hardware_evidence = Application.get_env(:maxio, :drive_hardware_evidence)
    Application.put_env(:maxio, :storage_backend, Distributed)
    Mix.Task.reenable(@task)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous_backend)
      restore_hardware_evidence(previous_hardware_evidence)
      restore_topology(previous_topology)
      Mix.Task.reenable(@task)
    end)

    :ok
  end

  test "json output reports stored endpoint manifest without deleting residual files" do
    {topology, base} = topology()
    on_exit(fn -> File.rm_rf(base) end)
    :persistent_term.put(@topology_key, topology)
    complete = completed_empty_decommission!("physical-preflight-cli", topology)
    expected_hash = Placement.topology_hash(topology)

    {:ok, apply_report} =
      TopologyMutation.apply_removal_cluster(complete.id,
        topology: topology,
        transport: InProcess,
        expected_current_topology_hash: expected_hash,
        lock_opts: [nodes: [Node.self()]]
      )

    {:ok, _verified} =
      Jobs.mark_topology_removal_deployment_verified(apply_report.job_id, %{
        deployment_topology_hash: apply_report.proposed_topology_hash
      })

    [%{"drive" => drive} | _] = apply_report.target_endpoints["endpoints"]
    residual_dir = Path.join([drive, ".uploads", "cli-bucket", "upload-id", "1"])
    File.mkdir_p!(residual_dir)
    File.write!(Path.join(residual_dir, "part.0"), "residual")

    Application.put_env(:maxio, :drive_hardware_evidence,
      provider: fn endpoint_drive ->
        {:ok,
         %{
           mount_root: Path.expand(endpoint_drive),
           serial: "SERIAL-#{Path.basename(endpoint_drive)}",
           wwid: "WWID-#{Path.basename(endpoint_drive)}",
           source: :test_sysfs
         }}
      end
    )

    output =
      capture_io(fn ->
        PhysicalRemovalPreflight.run(["--job-id", complete.id, "--hardware-evidence", "--json"])
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "blocked"
    assert decoded["physical_removal"] == false
    assert decoded["topology_mutation"] == false
    assert "physical_residuals_present" in decoded["blockers"]
    assert decoded["physical_residuals"] > 0
    assert decoded["target_endpoints"]["target_set_id"] == 0
    assert length(decoded["target_endpoints"]["endpoints"]) == 2
    assert decoded["drive_hardware_evidence_status"] == "ok"
    assert decoded["drive_hardware_evidence_errors"] == 0
    assert decoded["drive_hardware_evidence"]["status"] == "ok"
    assert decoded["drive_hardware_evidence"]["drive_hardware_evidence_gate"] == false
    assert length(decoded["drive_hardware_evidence"]["samples"]) == 2
    refute output =~ "SERIAL-"
    refute output =~ "WWID-"
    assert File.exists?(Path.join(residual_dir, "part.0"))
  end

  defp completed_empty_decommission!(prefix, topology) do
    bucket = bucket_name(prefix)
    opts = [topology: topology, transport: InProcess]
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, complete} = Jobs.complete_data_movement(job.id)
    {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)
    {:ok, complete} = Jobs.complete_source_cleanup(cleaning.id)
    complete
  end

  defp topology do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_physical_preflight_cli_#{System.unique_integer([:positive])}"
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

  defp restore_topology(:__maxio_no_topology__),
    do: :persistent_term.erase(@topology_key)

  defp restore_topology(topology),
    do: :persistent_term.put(@topology_key, topology)

  defp restore_hardware_evidence(nil),
    do: Application.delete_env(:maxio, :drive_hardware_evidence)

  defp restore_hardware_evidence(value),
    do: Application.put_env(:maxio, :drive_hardware_evidence, value)
end
