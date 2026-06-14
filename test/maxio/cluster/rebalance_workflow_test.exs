defmodule Maxio.Cluster.RebalanceWorkflowTest do
  use Maxio.DataCase, async: false

  import Ecto.Query

  alias Maxio.{Buckets, Multipart, Objects, Repo}

  alias Maxio.Cluster.{
    Paths,
    Placement,
    Rebalance.Closure,
    Rebalance.Jobs,
    Rebalance.Runner,
    Rebalance.SourceCleanup,
    Rebalance.Workflow,
    Router,
    Topology
  }

  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.Distributed

  @owner "arn:aws:iam:::root"
  @topology_key {Maxio.Cluster.Topology, :topology}

  setup do
    InProcess.setup!()
    previous_backend = Application.get_env(:maxio, :storage_backend)
    previous_deployment_topology = Application.get_env(:maxio, Topology, :__maxio_no_topology__)
    previous_topology_source = Application.get_env(:maxio, :topology_source, :__maxio_no_source__)
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)
    Application.put_env(:maxio, :storage_backend, Distributed)

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_workflow_#{System.unique_integer([:positive])}"
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

    :persistent_term.put(@topology_key, topology)
    Application.put_env(:maxio, Topology, Topology.to_config(topology))
    Application.put_env(:maxio, :topology_source, :config)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous_backend)
      restore_deployment_topology(previous_deployment_topology)
      restore_topology_source(previous_topology_source)
      restore_topology(previous_topology)
      File.rm_rf(base)
    end)

    {:ok, topology: topology}
  end

  test "rebalance workflow reaches clean closure after copy and source cleanup", ctx do
    fixture = seed_mismatched_rebalance(ctx, "rebalance-workflow-clean")

    assert {:ok, planned} = Workflow.summary(fixture.job.id)
    assert planned.job_kind == "rebalance"
    assert planned.phase == "copy_pass"
    assert planned.status == "in_progress"
    assert planned.next_action =~ "mix maxio.rebalance.run"
    assert planned.rebalance_complete? == false
    assert planned.rebalance_audit.status == "not_checked"
    refute planned.destructive_next_action?

    assert {:ok, move} =
             Runner.run_once(fixture.job.id,
               topology: ctx.topology,
               transport: InProcess,
               page_size: 1
             )

    assert move.status == :ok
    assert move.job_kind == "rebalance"
    assert move.moved == 2

    assert {:ok, cleanup_phase} = Workflow.summary(fixture.job.id)
    assert cleanup_phase.phase == "source_cleanup"
    assert cleanup_phase.status == "in_progress"
    assert cleanup_phase.next_action =~ "mix maxio.rebalance.cleanup"

    assert {:ok, cleanup} =
             SourceCleanup.cleanup_once(fixture.job.id,
               topology: ctx.topology,
               transport: InProcess,
               page_size: 1
             )

    assert cleanup.status == :ok
    assert cleanup.deleted == 2

    assert {:ok, final} = Workflow.summary(fixture.job.id, audit_page_size: 1)
    assert final.status == "complete"
    assert final.phase == "rebalance_closure"
    assert final.next_action == "none"
    assert final.rebalance_complete? == true
    assert final.set_retired? == false
    assert final.pool_retired? == false
    assert final.blockers == []

    assert final.rebalance_audit.status == "ok"
    assert final.rebalance_audit.versions_scanned == 2
    assert final.rebalance_audit.routing_mismatches == 0
    assert final.rebalance_audit.missing_placements == 0
    assert final.rebalance_audit.unknown_placements == 0
    assert final.rebalance_audit.stale_topology_hashes == 0
    assert final.rebalance_audit.active_multipart_uploads == 0

    assert {:ok, destination_stream} =
             Distributed.get(fixture.bucket, fixture.key, "v1", nil, fixture.destination_opts)

    assert IO.iodata_to_binary(Enum.to_list(destination_stream)) == fixture.body

    assert {:error, :enoent} =
             Distributed.get(fixture.bucket, fixture.key, "v1", nil, fixture.source_opts)

    assert delete_marker_sidecar?(ctx.topology, fixture.marker_key, fixture.bucket, "dm1", 1)
    refute delete_marker_sidecar?(ctx.topology, fixture.marker_key, fixture.bucket, "dm1", 0)
  end

  test "rebalance closure blocks when persisted placement no longer matches router", ctx do
    fixture = complete_rebalance(ctx, "rebalance-workflow-blocked")

    assert {:ok, moved} = Objects.get_version(fixture.bucket, fixture.key, "v1")

    assert {:ok, _wrong_placement} =
             Objects.update_placement_if_current(moved, %{
               placement_set_id: 0,
               placement_pool_id: 0,
               placement_topology_hash: Placement.topology_hash(ctx.topology)
             })

    assert {:ok, blocked} = Workflow.summary(fixture.job.id)
    assert blocked.phase == "rebalance_closure"
    assert blocked.status == "blocked"
    assert blocked.rebalance_complete? == false
    assert "routing_mismatch" in blocked.blockers
    assert blocked.next_action == "mix maxio.rebalance.start --json"
    refute blocked.destructive_next_action?
    assert blocked.rebalance_audit.status == "blocked"
    assert blocked.rebalance_audit.routing_mismatches == 1
    assert [%{reason: "routing_mismatch"} | _] = blocked.rebalance_audit.examples
  end

  test "rebalance closure points at active job workflow when another job is active", ctx do
    fixture = complete_rebalance(ctx, "rebalance-workflow-active-job")

    assert {:ok, active} =
             Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:ok, blocked} = Workflow.summary(fixture.job.id)
    assert blocked.phase == "rebalance_closure"
    assert blocked.status == "blocked"
    assert "active_job_exists" in blocked.blockers
    assert blocked.rebalance_audit.active_job_id == active.id
    assert blocked.next_action == "mix maxio.rebalance.workflow --job-id #{active.id} --json"
    refute blocked.destructive_next_action?
  end

  test "rebalance closure maps object placement blockers to closure verifier", ctx do
    cases = [
      {"missing_persisted_placement",
       [
         placement_set_id: nil,
         placement_pool_id: nil,
         placement_topology_hash: nil
       ]},
      {"unknown_placement_set",
       [
         placement_set_id: 99,
         placement_pool_id: 0,
         placement_topology_hash: Placement.topology_hash(ctx.topology)
       ]},
      {"stale_placement_topology_hash",
       [
         placement_set_id: 1,
         placement_pool_id: 0,
         placement_topology_hash: "stale-topology-hash"
       ]}
    ]

    for {blocker, attrs} <- cases do
      fixture = complete_rebalance(ctx, "rebalance-workflow-#{bucket_safe(blocker)}")
      update_object_placement!(fixture.bucket, fixture.key, "v1", attrs)

      assert {:ok, blocked} = Workflow.summary(fixture.job.id)
      assert blocked.status == "blocked"
      assert blocker in blocked.blockers

      assert blocked.next_action ==
               "mix maxio.rebalance.verify_closure --job-id #{fixture.job.id} --json"

      refute blocked.destructive_next_action?

      update_object_placement!(fixture.bucket, fixture.key, "v1",
        placement_set_id: 1,
        placement_pool_id: 0,
        placement_topology_hash: Placement.topology_hash(ctx.topology)
      )
    end
  end

  test "rebalance closure verifier persists blocked audit and verifies after repair", ctx do
    fixture = complete_rebalance(ctx, "rebalance-closure-verifier")

    assert {:ok, moved} = Objects.get_version(fixture.bucket, fixture.key, "v1")

    assert {:ok, _wrong_placement} =
             Objects.update_placement_if_current(moved, %{
               placement_set_id: 0,
               placement_pool_id: 0,
               placement_topology_hash: Placement.topology_hash(ctx.topology)
             })

    assert {:ok, blocked} = Closure.verify_once(fixture.job.id, audit_page_size: 1)
    assert blocked.status == :blocked
    assert blocked.phase == :rebalance_closure
    assert blocked.topology_mutation == false
    assert blocked.physical_removal == false
    assert "routing_mismatch" in blocked.blockers

    assert {:ok, blocked_job} = Jobs.get(fixture.job.id)
    assert blocked_job.rebalance_closure_status == "blocked"
    assert blocked_job.rebalance_closure_blockers == ["routing_mismatch"]
    assert blocked_job.rebalance_closure_results["workflow_status"] == "blocked"

    assert {:ok, failed_job} = Jobs.fail_rebalance_closure(fixture.job.id, :simulated_crash)
    assert failed_job.rebalance_closure_status == "failed"
    assert failed_job.rebalance_closure_blockers == []
    assert failed_job.rebalance_closure_results == %{}
    assert is_nil(failed_job.rebalance_closure_topology_hash)
    assert is_nil(failed_job.rebalance_closure_verified_at)

    assert {:ok, failed_workflow} = Workflow.summary(fixture.job.id)
    assert failed_workflow.status == "blocked"
    assert "rebalance_closure_failed" in failed_workflow.blockers

    assert failed_workflow.next_action ==
             "mix maxio.rebalance.status --job-id #{fixture.job.id} --json"

    assert {:ok, wrong} = Objects.get_version(fixture.bucket, fixture.key, "v1")

    assert {:ok, _repaired} =
             Objects.update_placement_if_current(wrong, %{
               placement_set_id: 1,
               placement_pool_id: 0,
               placement_topology_hash: Placement.topology_hash(ctx.topology)
             })

    assert {:ok, verified} = Closure.verify_once(fixture.job.id, audit_page_size: 1)
    assert verified.status == :verified
    assert verified.rebalance_complete?

    assert {:ok, verified_job} = Jobs.get(fixture.job.id)
    assert verified_job.rebalance_closure_status == "verified"
    assert verified_job.rebalance_closure_blockers == []
    assert verified_job.rebalance_closure_verified_at
  end

  test "rebalance closure blocks stale active multipart upload placement hash", ctx do
    fixture = complete_rebalance(ctx, "rebalance-workflow-mpu")

    assert {:ok, upload} =
             Multipart.initiate(
               fixture.bucket,
               "in-flight-mpu.txt",
               %{},
               fixture.destination_opts
             )

    assert {1, _rows} =
             Repo.update_all(
               from(u in Maxio.Multipart.Upload, where: u.id == ^upload.id),
               set: [placement_topology_hash: "stale-topology-hash"]
             )

    assert {:ok, blocked} = Workflow.summary(fixture.job.id)
    assert blocked.phase == "rebalance_closure"
    assert blocked.status == "blocked"
    assert "stale_multipart_upload_topology_hash" in blocked.blockers

    assert blocked.next_action ==
             "mix maxio.rebalance.verify_closure --job-id #{fixture.job.id} --json"

    refute blocked.destructive_next_action?
    assert blocked.rebalance_audit.active_multipart_uploads == 1
    assert blocked.rebalance_audit.stale_multipart_upload_topology_hashes == 1
  end

  test "rebalance closure maps multipart placement blockers to closure verifier", ctx do
    cases = [
      {"missing_multipart_upload_placement", "mpu-missing",
       [
         placement_set_id: nil,
         placement_pool_id: nil,
         placement_topology_hash: nil
       ]},
      {"unknown_multipart_upload_placement", "mpu-unknown",
       [
         placement_set_id: 99,
         placement_pool_id: 0,
         placement_topology_hash: Placement.topology_hash(ctx.topology)
       ]},
      {"stale_multipart_upload_topology_hash", "mpu-stale",
       [
         placement_set_id: 1,
         placement_pool_id: 0,
         placement_topology_hash: "stale-topology-hash"
       ]}
    ]

    for {blocker, suffix, attrs} <- cases do
      fixture = complete_rebalance(ctx, "rebalance-workflow-#{suffix}")

      assert {:ok, upload} =
               Multipart.initiate(
                 fixture.bucket,
                 "in-flight-#{blocker}.txt",
                 %{},
                 fixture.destination_opts
               )

      update_multipart_placement!(upload.id, attrs)

      assert {:ok, blocked} = Workflow.summary(fixture.job.id)
      assert blocked.status == "blocked"
      assert blocker in blocked.blockers

      assert blocked.next_action ==
               "mix maxio.rebalance.verify_closure --job-id #{fixture.job.id} --json"

      refute blocked.destructive_next_action?
      :ok = Multipart.abort(upload, fixture.destination_opts)
    end
  end

  test "rebalance closure reports unsupported non-PG metadata authority with JSON-safe values",
       ctx do
    fixture = complete_rebalance(ctx, "rebalance-workflow-authority")

    assert {:ok, blocked} =
             Workflow.summary(fixture.job.id,
               authoritative_source: [read: :sidecar, list: :sidecar]
             )

    assert blocked.status == "blocked"
    assert "unsupported_authoritative_source" in blocked.blockers

    assert blocked.next_action ==
             "mix maxio.rebalance.workflow --job-id #{fixture.job.id} --json"

    refute blocked.destructive_next_action?
    assert blocked.rebalance_audit.authoritative_source == %{read: "sidecar", list: "sidecar"}
    assert is_binary(Jason.encode!(blocked))
  end

  test "rebalance closure maps missing runtime topology to read-only workflow retry", ctx do
    fixture = complete_rebalance(ctx, "rebalance-workflow-runtime")

    :persistent_term.erase(@topology_key)

    assert {:ok, blocked} = Workflow.summary(fixture.job.id)
    assert blocked.status == "blocked"
    assert "runtime_topology_unavailable" in blocked.blockers

    assert blocked.next_action ==
             "mix maxio.rebalance.workflow --job-id #{fixture.job.id} --json"

    refute blocked.destructive_next_action?
  end

  defp complete_rebalance(ctx, prefix) do
    fixture = seed_mismatched_rebalance(ctx, prefix)

    assert {:ok, _move} =
             Runner.run_once(fixture.job.id, topology: ctx.topology, transport: InProcess)

    assert {:ok, _cleanup} =
             SourceCleanup.cleanup_once(fixture.job.id,
               topology: ctx.topology,
               transport: InProcess
             )

    fixture
  end

  defp seed_mismatched_rebalance(ctx, prefix) do
    bucket = bucket_name(prefix)
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    destination_opts = Keyword.put(opts, :placement_set_id, 1)
    key = key_for_set(bucket, ctx.topology, 1, "#{prefix}-object")
    marker_key = key_for_set(bucket, ctx.topology, 1, "#{prefix}-deleted")
    body = "#{prefix}-body"

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)

    {:ok, _object} = put_object_version!(bucket, key, "v1", body, source_opts)
    :ok = Distributed.put_delete_marker(bucket, marker_key, "dm1", [], source_opts)

    {:ok, _marker} =
      Objects.insert_delete_marker_with_id(
        bucket,
        marker_key,
        "dm1",
        Placement.attrs_for_write(bucket, marker_key, source_opts)
      )

    {:ok, job} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    %{
      bucket: bucket,
      key: key,
      marker_key: marker_key,
      body: body,
      job: job,
      source_opts: source_opts,
      destination_opts: destination_opts
    }
  end

  defp put_object_version!(bucket, key, version_id, body, opts) do
    {:ok, write_result} = Distributed.put(bucket, key, version_id, [body], opts)

    Objects.put_version_with_id(
      bucket,
      key,
      version_id,
      %{size: byte_size(body), etag: write_result.etag}
      |> Map.merge(Placement.attrs_from_result(write_result))
    )
  end

  defp dist_opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  defp delete_marker_sidecar?(topology, key, bucket, version_id, set_id) do
    {:ok, rel} = Paths.object_rel(bucket, key, version_id)
    {node, drive} = topology |> Topology.endpoints_from(set_id) |> hd()

    case InProcess.get_sidecar(node, Path.join(drive, rel)) do
      {:ok, %{"versions" => [%{"type" => "delete_marker", "version_id" => ^version_id}]}} -> true
      _other -> false
    end
  end

  defp update_object_placement!(bucket, key, version_id, attrs) do
    assert {1, _rows} =
             Repo.update_all(
               from(o in Maxio.Objects.Object,
                 where:
                   o.bucket_name == ^bucket and o.key == ^key and
                     o.version_id == ^version_id
               ),
               set: attrs
             )
  end

  defp update_multipart_placement!(upload_id, attrs) do
    assert {1, _rows} =
             Repo.update_all(
               from(u in Maxio.Multipart.Upload, where: u.id == ^upload_id),
               set: attrs
             )
  end

  defp key_for_set(bucket, topology, set_id, prefix) do
    Enum.find_value(0..10_000, fn i ->
      key = "#{prefix}-#{set_id}-#{i}.txt"
      if Router.set_for(bucket, key, topology) == set_id, do: key
    end) || flunk("could not find key for set #{inspect(set_id)}")
  end

  defp bucket_name(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.replace("-", "")

    "#{prefix}-#{suffix}"
  end

  defp bucket_safe(value), do: String.replace(value, "_", "-")

  defp restore_topology(:__maxio_no_topology__), do: :persistent_term.erase(@topology_key)
  defp restore_topology(topology), do: :persistent_term.put(@topology_key, topology)

  defp restore_deployment_topology(:__maxio_no_topology__),
    do: Application.delete_env(:maxio, Topology)

  defp restore_deployment_topology(topology),
    do: Application.put_env(:maxio, Topology, topology)

  defp restore_topology_source(:__maxio_no_source__),
    do: Application.delete_env(:maxio, :topology_source)

  defp restore_topology_source(source),
    do: Application.put_env(:maxio, :topology_source, source)
end
