defmodule Mix.Tasks.MaxioRebalancePhysicalPurgeTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Buckets

  alias Maxio.Cluster.{
    Placement,
    Rebalance.Jobs,
    Rebalance.PhysicalRemoval,
    Rebalance.TopologyMutation,
    Topology
  }

  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.Distributed
  alias Mix.Tasks.Maxio.Rebalance.PhysicalPurge
  alias Mix.Tasks.Maxio.Rebalance.PhysicalPurgePreflight

  @owner "arn:aws:iam:::root"
  @purge_task "maxio.rebalance.physical_purge"
  @preflight_task "maxio.rebalance.physical_purge_preflight"
  @topology_key {Maxio.Cluster.Topology, :topology}

  setup do
    InProcess.setup!()
    previous_backend = Application.get_env(:maxio, :storage_backend)
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)
    Application.put_env(:maxio, :storage_backend, Distributed)
    Mix.Task.reenable(@purge_task)
    Mix.Task.reenable(@preflight_task)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous_backend)
      restore_topology(previous_topology)
      Mix.Task.reenable(@purge_task)
      Mix.Task.reenable(@preflight_task)
    end)

    :ok
  end

  test "requires matching job id and quarantine id confirmations" do
    assert_raise Mix.Error, ~r/--confirm-quarantine-id/, fn ->
      PhysicalPurge.run([
        "--job-id",
        Ecto.UUID.generate(),
        "--confirm-job-id",
        Ecto.UUID.generate()
      ])
    end
  end

  test "preflight json reports retention readiness" do
    {topology, base} = topology()
    on_exit(fn -> File.rm_rf(base) end)
    :persistent_term.put(@topology_key, topology)

    {job, _bucket, _apply_report} =
      verified_empty_decommission!("physical-purge-preflight", topology)

    assert {:ok, quarantine} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    output =
      capture_io(fn ->
        PhysicalPurgePreflight.run(["--job-id", job.id, "--retention-hours", "0", "--json"])
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "ready"
    assert decoded["quarantine_id"] == quarantine.quarantine_id
    assert decoded["purge"] == false
    assert decoded["retention_elapsed?"] == true
  end

  test "json output reports purged quarantine roots" do
    {topology, base} = topology()
    on_exit(fn -> File.rm_rf(base) end)
    :persistent_term.put(@topology_key, topology)
    {job, bucket, _apply_report} = verified_empty_decommission!("physical-purge-cli", topology)

    assert {:ok, quarantine} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    output =
      capture_io(fn ->
        PhysicalPurge.run([
          "--job-id",
          job.id,
          "--confirm-job-id",
          job.id,
          "--confirm-quarantine-id",
          quarantine.quarantine_id,
          "--retention-hours",
          "0",
          "--json"
        ])
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "purged"
    assert decoded["physical_removal"] == "quarantine_hard_delete"
    assert decoded["topology_mutation"] == false
    assert decoded["deployment_config_mutation"] == false
    assert decoded["errors"] == 0
    assert decoded["roots_deleted"] == 2

    for {_node, drive} <- Topology.endpoints_from(topology, 0) do
      refute File.exists?(
               Path.join([drive, ".maxio-removal-quarantine", quarantine.quarantine_id])
             )

      refute File.exists?(Path.join(drive, bucket))
      assert File.exists?(Path.join(drive, ".maxio-physical-purge.json"))
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
        "maxio_rebalance_physical_purge_cli_#{System.unique_integer([:positive])}"
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
end
