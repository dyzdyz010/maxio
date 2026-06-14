defmodule Maxio.Cluster.RebalancePhysicalRemovalTest do
  use Maxio.DataCase, async: false

  alias Maxio.Buckets

  alias Maxio.Cluster.{
    Placement,
    Rebalance.Jobs,
    Rebalance.PhysicalPurge,
    Rebalance.PhysicalRemoval,
    Rebalance.TopologyMutation,
    Topology
  }

  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.Distributed

  @owner "arn:aws:iam:::root"
  @topology_key {Maxio.Cluster.Topology, :topology}

  setup do
    InProcess.setup!()
    previous_backend = Application.get_env(:maxio, :storage_backend)
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)
    Application.put_env(:maxio, :storage_backend, Distributed)

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_physical_removal_#{System.unique_integer([:positive])}"
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

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous_backend)
      restore_topology(previous_topology)
      File.rm_rf(base)
    end)

    {:ok, topology: topology}
  end

  test "apply quarantines stored target endpoint layout roots after deployment verification",
       ctx do
    {job, bucket, _apply_report} = verified_empty_removal!("physical-remove-ok", ctx)
    [{_node, drive} | _] = Topology.endpoints_from(ctx.topology, 0)
    File.write!(Path.join(drive, "operator-note.txt"), "do not touch")

    assert {:ok, report} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert report.status == :quarantined
    assert report.physical_removal == :layout_quarantine
    assert report.topology_mutation == false
    assert report.deployment_config_mutation == false
    assert report.errors == 0
    assert report.markers_written == 2
    assert report.roots_quarantined >= 2

    for {_node, target_drive} <- Topology.endpoints_from(ctx.topology, 0) do
      quarantine = Path.join([target_drive, ".maxio-removal-quarantine", report.quarantine_id])
      assert File.dir?(target_drive)
      refute File.exists?(Path.join(target_drive, bucket))
      assert File.dir?(Path.join([quarantine, "buckets", bucket]))
      assert File.exists?(Path.join(target_drive, ".maxio-physical-removal.json"))
    end

    assert File.exists?(Path.join(drive, "operator-note.txt"))

    assert {:ok, updated} = Jobs.get(job.id)
    assert updated.physical_removal_status == "quarantined"
    assert updated.physical_removal_scope == "layout_quarantine"
    assert updated.physical_removal_quarantine_id == report.quarantine_id
    assert updated.physical_removal_roots_quarantined == report.roots_quarantined
  end

  test "apply persists sanitized drive hardware evidence only in job results", ctx do
    {job, _bucket, _apply_report} = verified_empty_removal!("physical-remove-evidence", ctx)
    [{_node, first_drive} | _] = Topology.endpoints_from(ctx.topology, 0)

    provider = fn drive ->
      {:ok,
       %{
         mount_root: Path.expand(drive),
         mount_source: "/dev/#{Path.basename(drive)}",
         major_minor: "8:1",
         block_device: Path.basename(drive),
         serial: "SERIAL-#{Path.basename(drive)}",
         wwid: "WWID-#{Path.basename(drive)}",
         source: :test_sysfs
       }}
    end

    assert {:ok, report} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]],
               drive_hardware_evidence: true,
               hardware_evidence_provider: provider,
               hardware_evidence_now_ms: 555
             )

    evidence = report.drive_hardware_evidence
    assert evidence["status"] == "ok"
    assert evidence["endpoints"] == 2
    assert evidence["ok"] == 2
    assert evidence["errors"] == 0
    assert evidence["drive_hardware_evidence_gate"] == false
    assert hd(evidence["samples"])["observed_at_ms"] == 555
    assert inspect(evidence) =~ sha256("SERIAL-#{Path.basename(first_drive)}")
    refute inspect(report.results) =~ "SERIAL-"
    refute inspect(report.results) =~ "WWID-"

    assert {:ok, updated} = Jobs.get(job.id)
    persisted = updated.physical_removal_results["drive_hardware_evidence"]
    assert persisted["status"] == "ok"
    assert persisted["endpoints"] == 2
    refute inspect(updated.physical_removal_results) =~ "SERIAL-"
    refute inspect(updated.physical_removal_results) =~ "WWID-"

    marker =
      first_drive
      |> Path.join(".maxio-physical-removal.json")
      |> File.read!()
      |> Jason.decode!()

    refute Map.has_key?(marker, "drive_hardware_evidence")
  end

  test "apply records partial drive hardware evidence without changing removal gates", ctx do
    {job, _bucket, _apply_report} =
      verified_empty_removal!("physical-remove-evidence-error", ctx)

    provider = fn _drive -> {:error, {:probe_failed, "SERIAL-SECRET"}} end

    assert {:ok, report} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]],
               drive_hardware_evidence: true,
               hardware_evidence_provider: provider
             )

    assert report.status == :quarantined
    assert report.errors == 0
    assert report.drive_hardware_evidence["status"] == "partial"
    assert report.drive_hardware_evidence["errors"] == 2
    refute inspect(report.results) =~ "SERIAL-SECRET"

    assert {:ok, updated} = Jobs.get(job.id)
    assert updated.physical_removal_status == "quarantined"
    assert updated.physical_removal_results["drive_hardware_evidence"]["status"] == "partial"
  end

  test "apply is idempotent after quarantine", ctx do
    {job, _bucket, _apply_report} = verified_empty_removal!("physical-remove-idem", ctx)

    assert {:ok, first} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert {:ok, second} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert first.status == :quarantined
    assert second.status == :already_quarantined
    assert second.quarantine_id == first.quarantine_id
    assert second.errors == 0
  end

  test "idempotent apply can attach missing drive hardware evidence", ctx do
    {job, _bucket, _apply_report} =
      verified_empty_removal!("physical-remove-idem-evidence", ctx)

    assert {:ok, first} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert first.status == :quarantined
    assert first.drive_hardware_evidence["status"] == "not_sampled"

    provider = fn drive ->
      {:ok,
       %{
         mount_root: Path.expand(drive),
         serial_hash: "SERIAL-HASH-FIELD-#{Path.basename(drive)}",
         source: :test_sysfs
       }}
    end

    assert {:ok, second} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]],
               drive_hardware_evidence: true,
               hardware_evidence_provider: provider
             )

    assert second.status == :already_quarantined
    assert second.drive_hardware_evidence["status"] == "ok"
    assert second.drive_hardware_evidence["endpoints"] == 2
    refute inspect(second.results) =~ "SERIAL-HASH-FIELD"

    assert {:ok, updated} = Jobs.get(job.id)
    assert updated.physical_removal_results["drive_hardware_evidence"]["status"] == "ok"
    refute inspect(updated.physical_removal_results) =~ "SERIAL-HASH-FIELD"
  end

  test "apply requires explicit confirmation", ctx do
    {job, _bucket, _apply_report} = verified_empty_removal!("physical-remove-confirm", ctx)

    assert {:error, :physical_removal_confirmation_required} =
             PhysicalRemoval.apply(job.id, transport: InProcess)
  end

  test "apply blocks before deployment verification", ctx do
    {job, _bucket, _apply_report} = applied_empty_removal!("physical-remove-unverified", ctx)

    assert {:error, {:physical_removal_preflight_blocked, report}} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert :deployment_not_verified in report.blockers

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.physical_removal_status == "not_started"
  end

  test "apply blocks unreachable manifest endpoint before filesystem mutation", ctx do
    {job, bucket, _apply_report} = verified_empty_removal!("physical-remove-down", ctx)
    [{node, drive} | _] = Topology.endpoints_from(ctx.topology, 0)
    InProcess.set_drive_down(node, drive)

    assert {:error, {:physical_removal_preflight_blocked, report}} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert :target_endpoints_unreachable in report.blockers
    assert File.exists?(Path.join(drive, bucket))

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.physical_removal_status == "not_started"
  end

  test "apply fails closed on unknown top-level directory and records retryable failure", ctx do
    {job, bucket, _apply_report} = verified_empty_removal!("physical-remove-unknown", ctx)
    [{_node, drive} | _] = Topology.endpoints_from(ctx.topology, 0)
    File.mkdir_p!(Path.join(drive, "shared-data"))

    assert {:error, {:physical_removal_failed, report}} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert report.status == :failed
    assert report.errors == 1
    assert File.exists?(Path.join(drive, bucket))
    assert File.dir?(Path.join(drive, "shared-data"))
    refute File.exists?(Path.join(drive, ".maxio-physical-removal.json"))

    assert {:ok, failed} = Jobs.get(job.id)
    assert failed.physical_removal_status == "failed"
    assert failed.physical_removal_errors == 1
    assert failed.physical_removal_quarantine_id
  end

  test "physical purge deletes retained quarantine roots after explicit confirmation", ctx do
    {job, bucket, _apply_report} = verified_empty_removal!("physical-purge-ok", ctx)
    [{_node, drive} | _] = Topology.endpoints_from(ctx.topology, 0)
    File.write!(Path.join(drive, "operator-note.txt"), "do not touch")

    assert {:ok, quarantine} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert {:ok, preflight} =
             PhysicalPurge.preflight(job.id,
               retention_seconds: 0,
               transport: InProcess
             )

    assert preflight.status == :ready
    assert preflight.quarantine_id == quarantine.quarantine_id
    assert preflight.retention_elapsed? == true

    assert {:ok, purged} =
             PhysicalPurge.apply(job.id,
               confirm_job_id: job.id,
               confirm_quarantine_id: quarantine.quarantine_id,
               retention_seconds: 0,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert purged.status == :purged
    assert purged.physical_removal == :quarantine_hard_delete
    assert purged.roots_deleted == 2
    assert purged.errors == 0

    for {_node, target_drive} <- Topology.endpoints_from(ctx.topology, 0) do
      refute File.exists?(
               Path.join([target_drive, ".maxio-removal-quarantine", quarantine.quarantine_id])
             )

      assert File.exists?(Path.join(target_drive, ".maxio-physical-removal.json"))
      assert File.exists?(Path.join(target_drive, ".maxio-physical-purge.json"))
      refute File.exists?(Path.join(target_drive, bucket))
    end

    assert File.exists?(Path.join(drive, "operator-note.txt"))

    assert {:ok, updated} = Jobs.get(job.id)
    assert updated.physical_removal_purge_status == "purged"
    assert updated.physical_removal_purge_scope == "quarantine_hard_delete"
    assert updated.physical_removal_purge_quarantine_id == quarantine.quarantine_id
    assert updated.physical_removal_purge_roots_deleted == purged.roots_deleted
  end

  test "physical purge is idempotent after successful purge", ctx do
    {job, _bucket, _apply_report} = verified_empty_removal!("physical-purge-idem", ctx)

    assert {:ok, quarantine} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    opts = [
      confirm_job_id: job.id,
      confirm_quarantine_id: quarantine.quarantine_id,
      retention_seconds: 0,
      transport: InProcess,
      lock_opts: [nodes: [Node.self()]]
    ]

    assert {:ok, first} = PhysicalPurge.apply(job.id, opts)
    assert {:ok, second} = PhysicalPurge.apply(job.id, opts)

    assert {:ok, third} =
             PhysicalPurge.apply(job.id,
               confirm_job_id: job.id,
               confirm_quarantine_id: quarantine.quarantine_id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert first.status == :purged
    assert second.status == :already_purged
    assert third.status == :already_purged
    assert second.quarantine_id == first.quarantine_id
  end

  test "physical purge blocks before quarantine", ctx do
    {job, _bucket, _apply_report} = verified_empty_removal!("physical-purge-before", ctx)

    assert {:ok, report} =
             PhysicalPurge.preflight(job.id,
               retention_seconds: 0,
               transport: InProcess
             )

    assert report.status == :blocked
    assert :physical_removal_not_quarantined in report.blockers
  end

  test "physical purge blocks before retention has elapsed", ctx do
    {job, _bucket, _apply_report} = verified_empty_removal!("physical-purge-retention", ctx)

    assert {:ok, quarantine} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert {:error, {:physical_purge_preflight_blocked, report}} =
             PhysicalPurge.apply(job.id,
               confirm_job_id: job.id,
               confirm_quarantine_id: quarantine.quarantine_id,
               retention_seconds: 86_400,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert :retention_not_elapsed in report.blockers

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.physical_removal_purge_status == "not_started"
  end

  test "physical purge blocks unreachable endpoint before mutation", ctx do
    {job, _bucket, _apply_report} = verified_empty_removal!("physical-purge-down", ctx)

    assert {:ok, quarantine} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    [{node, drive} | _] = Topology.endpoints_from(ctx.topology, 0)
    InProcess.set_drive_down(node, drive)

    assert {:error, {:physical_purge_preflight_blocked, report}} =
             PhysicalPurge.apply(job.id,
               confirm_job_id: job.id,
               confirm_quarantine_id: quarantine.quarantine_id,
               retention_seconds: 0,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert :physical_removal_preflight_blocked in report.blockers
    assert File.dir?(Path.join([drive, ".maxio-removal-quarantine", quarantine.quarantine_id]))

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.physical_removal_purge_status == "not_started"
  end

  test "physical purge records failed state when purge callback fails after preflight", ctx do
    {job, _bucket, _apply_report} = verified_empty_removal!("physical-purge-fail", ctx)

    assert {:ok, quarantine} =
             PhysicalRemoval.apply(job.id,
               confirm_job_id: job.id,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    [{node, drive} | _] = Topology.endpoints_from(ctx.topology, 0)
    InProcess.set_purge_quarantine_root_down(node, drive)

    assert {:error, {:physical_purge_failed, report}} =
             PhysicalPurge.apply(job.id,
               confirm_job_id: job.id,
               confirm_quarantine_id: quarantine.quarantine_id,
               retention_seconds: 0,
               transport: InProcess,
               lock_opts: [nodes: [Node.self()]]
             )

    assert report.status == :failed
    assert report.errors == 1
    assert File.dir?(Path.join([drive, ".maxio-removal-quarantine", quarantine.quarantine_id]))

    assert {:ok, failed} = Jobs.get(job.id)
    assert failed.physical_removal_purge_status == "failed"
    assert failed.physical_removal_purge_errors == 1
    assert failed.physical_removal_purge_error_reason =~ ":unavailable"
  end

  defp verified_empty_removal!(prefix, ctx) do
    {job, bucket, apply_report} = applied_empty_removal!(prefix, ctx)

    {:ok, _verified} =
      Jobs.mark_topology_removal_deployment_verified(apply_report.job_id, %{
        deployment_topology_hash: apply_report.proposed_topology_hash
      })

    {job, bucket, apply_report}
  end

  defp applied_empty_removal!(prefix, ctx) do
    :persistent_term.put(@topology_key, ctx.topology)
    bucket = bucket_name(prefix)
    opts = [topology: ctx.topology, transport: InProcess]
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, complete} = Jobs.complete_data_movement(job.id)
    {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)
    {:ok, complete} = Jobs.complete_source_cleanup(cleaning.id)

    {:ok, apply_report} =
      TopologyMutation.apply_removal_cluster(complete.id,
        topology: ctx.topology,
        transport: InProcess,
        expected_current_topology_hash: Placement.topology_hash(ctx.topology),
        lock_opts: [nodes: [Node.self()]]
      )

    {complete, bucket, apply_report}
  end

  defp bucket_name(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.replace("-", "")

    "#{prefix}-#{suffix}"
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp restore_topology(:__maxio_no_topology__), do: :persistent_term.erase(@topology_key)
  defp restore_topology(topology), do: :persistent_term.put(@topology_key, topology)
end
