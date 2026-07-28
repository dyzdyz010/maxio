defmodule Maxio.Cluster.Rebalance.Workflow do
  @moduledoc """
  Read-only phase/audit view for rebalance and decommission jobs.

  The workflow view deliberately does not advance a job or call destructive
  phases. It only combines the persistent job audit with the current runtime
  and deployment topology facts so operators can see the next safe action,
  whether a decommission target set/pool is retired from Maxio's control
  plane, and whether a rebalance has converged to current router placement.
  """

  alias Maxio.{Buckets, Multipart, ObjectMeta, Objects}
  alias Maxio.Cluster.{Router, Topology, TopologyStore}
  alias Maxio.Cluster.Rebalance.{Job, Jobs}

  @audit_example_limit 10
  @default_audit_page_size 500

  @type report :: map()

  @doc "Build a read-only workflow report for a job id or already loaded job."
  @spec summary(String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  @spec summary(Job.t(), keyword()) :: report()
  def summary(job_or_id, opts \\ [])

  def summary(job_id, opts) when is_binary(job_id) do
    with {:ok, job} <- Jobs.get(job_id) do
      {:ok, summary(job, opts)}
    end
  end

  def summary(%Job{} = job, opts) do
    phase = phase(job)
    runtime = runtime_state(job)
    deployment = deployment_state(job, opts)
    rebalance_audit = rebalance_audit(job, phase, runtime, opts)
    blockers = blockers(job, phase, runtime, deployment, rebalance_audit)
    set_retired? = retired_from_both_topologies?(job, runtime, deployment)
    pool_retired? = pool_retired?(job, runtime, deployment)
    status = workflow_status(phase, blockers)
    next_action = next_action(phase, job, blockers, rebalance_audit)
    destructive_next_action? = destructive_phase?(phase)
    warnings = warnings(status, next_action, destructive_next_action?, blockers)

    %{
      status: status,
      phase: phase,
      gate_status: gate_status(blockers, warnings),
      next_action: next_action,
      destructive_next_action?: destructive_next_action?,
      job_id: job.id,
      job_kind: job.kind,
      target_set_id: job.target_set_id,
      destination_set_id: job.destination_set_id,
      removed_pool_ids: normalize_pool_ids(job.topology_removal_removed_pool_ids),
      set_retired?: set_retired?,
      pool_retired?: pool_retired?,
      rebalance_complete?: rebalance_complete?(job, phase, blockers),
      rebalance_audit: rebalance_audit,
      rebalance_closure: persisted_rebalance_closure(job),
      blockers: blockers,
      warnings: warnings,
      runtime_topology: runtime,
      deployment_topology: deployment,
      job: Jobs.to_view(job)
    }
  end

  defp phase(%Job{kind: kind}) when kind not in ["decommission", "rebalance"], do: "unsupported"
  defp phase(%Job{status: "failed"}), do: "failed"
  defp phase(%Job{status: "canceled"}), do: "canceled"
  defp phase(%Job{data_movement_status: status}) when status != "complete", do: "copy_pass"
  defp phase(%Job{source_cleanup_status: status}) when status != "complete", do: "source_cleanup"

  defp phase(%Job{kind: "rebalance"}), do: "rebalance_closure"

  defp phase(%Job{topology_removal_cluster_status: status}) when status != "runtime_converged",
    do: "runtime_topology"

  defp phase(%Job{topology_removal_deployment_status: status}) when status != "verified",
    do: "deployment_topology"

  defp phase(%Job{physical_removal_status: status}) when status != "quarantined",
    do: "physical_removal"

  defp phase(%Job{physical_removal_purge_status: status}) when status != "purged",
    do: "physical_purge"

  defp phase(%Job{}), do: "retired"

  defp workflow_status("retired", []), do: "complete"
  defp workflow_status("rebalance_closure", []), do: "complete"
  defp workflow_status(_phase, []), do: "in_progress"
  defp workflow_status(_phase, _blockers), do: "blocked"

  defp warnings(_status, _next_action, _destructive_next_action?, [_ | _]), do: []

  defp warnings(status, next_action, destructive_next_action?, []) do
    []
    |> maybe_block(
      status == "in_progress" and next_action not in [nil, "none"],
      "workflow_next_action_required"
    )
    |> maybe_block(destructive_next_action?, "destructive_next_action_required")
    |> Enum.reverse()
  end

  defp gate_status([_ | _], _warnings), do: "blocked"
  defp gate_status([], [_ | _]), do: "attention"
  defp gate_status([], []), do: "ok"

  @failure_blockers ~w(
    job_failed
    job_canceled
    data_movement_failed
    data_movement_canceled
    source_cleanup_failed
    rebalance_closure_failed
    topology_removal_failed
    cluster_topology_failed
    deployment_topology_failed
    physical_removal_failed
    physical_purge_failed
  )

  @placement_repair_blockers ~w(
    missing_persisted_placement
    unknown_placement_set
    stale_placement_topology_hash
  )

  @multipart_repair_blockers ~w(
    missing_multipart_upload_placement
    unknown_multipart_upload_placement
    stale_multipart_upload_topology_hash
  )

  @environment_repair_blockers ~w(
    unsupported_authoritative_source
    runtime_topology_unavailable
  )

  defp next_action(phase, job, blockers, rebalance_audit) do
    case failure_next_action(job, blockers) do
      nil ->
        case next_action(phase, job, blockers, rebalance_audit, :dispatch) do
          :continue -> next_action(phase, job)
          action -> action
        end

      action ->
        action
    end
  end

  defp failure_next_action(%Job{id: id}, blockers) when is_list(blockers) do
    if any_blocker?(blockers, @failure_blockers) do
      "mix maxio.rebalance.status --job-id #{id} --json"
    end
  end

  defp failure_next_action(_job, _blockers), do: nil

  defp next_action("rebalance_closure", %Job{} = job, blockers, rebalance_audit, :dispatch),
    do: rebalance_closure_next_action(job, blockers, rebalance_audit)

  defp next_action(_phase, _job, _blockers, _rebalance_audit, :dispatch), do: :continue

  defp rebalance_closure_next_action(%Job{}, [], _rebalance_audit),
    do: "none"

  defp rebalance_closure_next_action(%Job{id: id}, blockers, rebalance_audit) do
    cond do
      any_blocker?(blockers, @environment_repair_blockers) ->
        "mix maxio.rebalance.workflow --job-id #{id} --json"

      "active_job_exists" in blockers ->
        active_job_next_action(rebalance_audit)

      any_blocker?(blockers, @placement_repair_blockers ++ @multipart_repair_blockers) ->
        "mix maxio.rebalance.verify_closure --job-id #{id} --json"

      "routing_mismatch" in blockers ->
        "mix maxio.rebalance.start --json"

      true ->
        "mix maxio.rebalance.workflow --job-id #{id} --json"
    end
  end

  defp active_job_next_action(%{active_job_id: active_id})
       when is_binary(active_id) and byte_size(active_id) > 0,
       do: "mix maxio.rebalance.workflow --job-id #{active_id} --json"

  defp active_job_next_action(_rebalance_audit), do: "mix maxio.rebalance.status --all --json"

  defp any_blocker?(blockers, candidates),
    do: Enum.any?(candidates, &(&1 in blockers))

  defp next_action("copy_pass", %Job{id: id}),
    do: "mix maxio.rebalance.run --job-id #{id}"

  defp next_action("source_cleanup", %Job{id: id}),
    do: "mix maxio.rebalance.cleanup --job-id #{id}"

  defp next_action("runtime_topology", %Job{id: id}),
    do: "mix maxio.rebalance.apply_removal_cluster --job-id #{id} --yes"

  defp next_action("deployment_topology", %Job{id: id} = job),
    do:
      "mix maxio.rebalance.persist_removal_deployment --job-id #{id} " <>
        "--runtime-node <live-runtime-node> --expected-proposed-topology-hash #{proposed_hash(job)} " <>
        "--yes && mix maxio.rebalance.verify_removal_deployment --job-id #{id}"

  defp next_action("physical_removal", %Job{id: id}),
    do: "mix maxio.rebalance.physical_remove --job-id #{id} --confirm-job-id #{id}"

  defp next_action("physical_purge", %Job{id: id, physical_removal_quarantine_id: qid})
       when is_binary(qid) and byte_size(qid) > 0,
       do:
         "mix maxio.rebalance.physical_purge --job-id #{id} --confirm-job-id #{id} " <>
           "--confirm-quarantine-id #{qid}"

  defp next_action("physical_purge", %Job{id: id}),
    do: "mix maxio.rebalance.physical_purge_preflight --job-id #{id}"

  defp next_action("rebalance_closure", _job), do: "none"
  defp next_action("retired", _job), do: "none"
  defp next_action(_phase, _job), do: "none"

  defp proposed_hash(%Job{topology_removal_proposed_hash: hash})
       when is_binary(hash) and byte_size(hash) > 0,
       do: hash

  defp proposed_hash(%Job{}), do: "<proposed-hash>"

  defp destructive_phase?(phase), do: phase in ["physical_removal", "physical_purge"]

  defp blockers(%Job{} = job, phase, runtime, deployment, rebalance_audit) do
    []
    |> maybe_block(job.kind not in ["decommission", "rebalance"], "unsupported_job_kind")
    |> maybe_block(job.status == "failed", "job_failed")
    |> maybe_block(job.status == "canceled", "job_canceled")
    |> maybe_block(job.data_movement_status == "failed", "data_movement_failed")
    |> maybe_block(job.data_movement_status == "canceled", "data_movement_canceled")
    |> maybe_block(job.source_cleanup_status == "failed", "source_cleanup_failed")
    |> maybe_block(job.rebalance_closure_status == "failed", "rebalance_closure_failed")
    |> maybe_block(job.topology_removal_status == "failed", "topology_removal_failed")
    |> maybe_block(job.topology_removal_cluster_status == "failed", "cluster_topology_failed")
    |> maybe_block(
      job.topology_removal_deployment_status == "failed",
      "deployment_topology_failed"
    )
    |> maybe_block(job.physical_removal_status == "failed", "physical_removal_failed")
    |> maybe_block(job.physical_removal_purge_status == "failed", "physical_purge_failed")
    |> rebalance_audit_blockers(job, phase, rebalance_audit)
    |> retired_topology_blockers(job, phase, runtime, deployment)
  end

  defp rebalance_complete?(%Job{kind: "rebalance"}, "rebalance_closure", []), do: true
  defp rebalance_complete?(_job, _phase, _blockers), do: false

  defp rebalance_audit_blockers(blockers, %Job{kind: "rebalance"}, "rebalance_closure", %{
         blockers: audit_blockers
       })
       when is_list(audit_blockers) do
    Enum.reduce(audit_blockers, blockers, fn blocker, acc -> [blocker | acc] end)
  end

  defp rebalance_audit_blockers(blockers, _job, _phase, _rebalance_audit), do: blockers

  defp retired_topology_blockers(blockers, %Job{} = job, "retired", runtime, deployment) do
    blockers
    |> maybe_block(not topology_retired?(job, runtime), "runtime_topology_not_retired")
    |> maybe_block(not topology_retired?(job, deployment), "deployment_topology_not_retired")
    |> maybe_block(
      normalize_pool_ids(job.topology_removal_removed_pool_ids) != [] and
        not pool_retired?(job, runtime, deployment),
      "removed_pool_still_configured"
    )
  end

  defp retired_topology_blockers(blockers, _job, _phase, _runtime, _deployment), do: blockers

  defp rebalance_audit(%Job{kind: "rebalance"} = job, "rebalance_closure", runtime, opts) do
    with :ok <- ensure_pg_authoritative(opts),
         :ok <- ensure_runtime_configured(runtime),
         {:ok, topology} <- Topology.current() do
      build_rebalance_audit(job, topology, opts)
    else
      {:error, :unsupported_authoritative_source, sources} ->
        empty_rebalance_audit("blocked")
        |> Map.put(:reason, "unsupported_authoritative_source")
        |> Map.put(:authoritative_source, sources)
        |> Map.put(:blockers, ["unsupported_authoritative_source"])

      {:error, :runtime_topology_unavailable} ->
        empty_rebalance_audit("blocked")
        |> Map.put(:reason, "runtime_topology_unavailable")
        |> Map.put(:blockers, ["runtime_topology_unavailable"])

      {:error, reason} ->
        empty_rebalance_audit("blocked")
        |> Map.put(:reason, inspect(reason))
        |> Map.put(:blockers, ["runtime_topology_unavailable"])
    end
  end

  defp rebalance_audit(%Job{kind: "rebalance"}, _phase, _runtime, _opts) do
    empty_rebalance_audit("not_checked")
    |> Map.put(:reason, "rebalance_not_at_closure")
  end

  defp rebalance_audit(_job, _phase, _runtime, _opts), do: empty_rebalance_audit("not_applicable")

  defp build_rebalance_audit(%Job{} = job, topology, opts) do
    topology_hash = Topology.fingerprint(topology)
    set_ids = Topology.all_set_ids_from(topology)
    pool_ids = Topology.pool_ids_from(topology)
    page_size = audit_page_size(job, opts)
    active_job_id = active_other_job_id(job)

    audit =
      scan_rebalance_versions(topology, set_ids, topology_hash, page_size)
      |> Map.merge(%{
        topology_hash: topology_hash,
        set_ids: set_ids,
        pool_ids: pool_ids,
        active_multipart_uploads: Multipart.count_uploads(),
        missing_multipart_upload_placements: Multipart.count_uploads_missing_placement_set(),
        unknown_multipart_upload_placements:
          Multipart.count_uploads_with_unknown_placement_set(set_ids),
        stale_multipart_upload_topology_hashes:
          Multipart.count_uploads_with_placement_topology_hash_mismatch(topology_hash),
        active_job_id: active_job_id
      })

    blockers =
      []
      |> maybe_block(active_job_id != nil, "active_job_exists")
      |> maybe_block(audit.missing_placements > 0, "missing_persisted_placement")
      |> maybe_block(audit.unknown_placements > 0, "unknown_placement_set")
      |> maybe_block(audit.stale_topology_hashes > 0, "stale_placement_topology_hash")
      |> maybe_block(audit.routing_mismatches > 0, "routing_mismatch")
      |> maybe_block(
        audit.missing_multipart_upload_placements > 0,
        "missing_multipart_upload_placement"
      )
      |> maybe_block(
        audit.unknown_multipart_upload_placements > 0,
        "unknown_multipart_upload_placement"
      )
      |> maybe_block(
        audit.stale_multipart_upload_topology_hashes > 0,
        "stale_multipart_upload_topology_hash"
      )

    audit
    |> Map.put(:status, if(blockers == [], do: "ok", else: "blocked"))
    |> Map.put(:blockers, blockers)
    |> Map.update!(:examples, &Enum.reverse/1)
  end

  defp empty_rebalance_audit(status) do
    %{
      status: status,
      reason: nil,
      topology_hash: nil,
      set_ids: [],
      pool_ids: [],
      versions_scanned: 0,
      routing_mismatches: 0,
      missing_placements: 0,
      unknown_placements: 0,
      stale_topology_hashes: 0,
      active_multipart_uploads: 0,
      missing_multipart_upload_placements: 0,
      unknown_multipart_upload_placements: 0,
      stale_multipart_upload_topology_hashes: 0,
      active_job_id: nil,
      authoritative_source: nil,
      blockers: [],
      examples: []
    }
  end

  defp persisted_rebalance_closure(%Job{} = job) do
    %{
      status: job.rebalance_closure_status,
      checked_at: iso8601(job.rebalance_closure_checked_at),
      verified_at: iso8601(job.rebalance_closure_verified_at),
      topology_hash: job.rebalance_closure_topology_hash,
      results: job.rebalance_closure_results,
      blockers: job.rebalance_closure_blockers,
      error_reason: job.rebalance_closure_error_reason
    }
  end

  defp ensure_pg_authoritative(opts) do
    read_source = ObjectMeta.authoritative_source(:read, opts)
    list_source = ObjectMeta.authoritative_source(:list, opts)

    if read_source == :pg and list_source == :pg do
      :ok
    else
      sources = %{read: to_string(read_source), list: to_string(list_source)}
      {:error, :unsupported_authoritative_source, sources}
    end
  end

  defp ensure_runtime_configured(%{status: "configured"}), do: :ok
  defp ensure_runtime_configured(_runtime), do: {:error, :runtime_topology_unavailable}

  defp active_other_job_id(%Job{id: id}) do
    case Jobs.active_job() do
      %Job{id: ^id} -> nil
      %Job{id: active_id} -> active_id
      nil -> nil
    end
  end

  defp audit_page_size(%Job{page_size: page_size}, opts) do
    opts
    |> Keyword.get(:audit_page_size, Keyword.get(opts, :page_size, page_size))
    |> positive_integer(@default_audit_page_size)
  end

  defp scan_rebalance_versions(topology, set_ids, topology_hash, page_size) do
    Buckets.list()
    |> Enum.reduce(empty_rebalance_audit("ok"), fn bucket, acc ->
      scan_bucket_versions(
        bucket.name,
        topology,
        set_ids,
        topology_hash,
        page_size,
        nil,
        nil,
        acc
      )
    end)
  end

  defp scan_bucket_versions(
         bucket,
         topology,
         set_ids,
         topology_hash,
         page_size,
         key_marker,
         version_id_marker,
         acc
       ) do
    page =
      Objects.list_object_versions(bucket, %{
        max_keys: page_size,
        key_marker: key_marker,
        version_id_marker: version_id_marker
      })

    acc =
      Enum.reduce(page.versions, acc, fn object, scan_acc ->
        record_version_audit(scan_acc, bucket, object, topology, set_ids, topology_hash)
      end)

    if page.is_truncated do
      scan_bucket_versions(
        bucket,
        topology,
        set_ids,
        topology_hash,
        page_size,
        page.next_key_marker,
        page.next_version_id_marker,
        acc
      )
    else
      acc
    end
  end

  defp record_version_audit(acc, bucket, object, topology, set_ids, topology_hash) do
    expected_set_id = Router.set_for(bucket, object.key, topology)
    placement_set_id = object.placement_set_id

    missing? = is_nil(placement_set_id)
    unknown? = not missing? and placement_set_id not in set_ids
    stale? = not missing? and not unknown? and object.placement_topology_hash != topology_hash
    routing_mismatch? = not missing? and not unknown? and placement_set_id != expected_set_id

    reason =
      cond do
        missing? -> "missing_persisted_placement"
        unknown? -> "unknown_placement_set"
        stale? -> "stale_placement_topology_hash"
        routing_mismatch? -> "routing_mismatch"
        true -> nil
      end

    acc
    |> Map.update!(:versions_scanned, &(&1 + 1))
    |> maybe_increment(missing?, :missing_placements)
    |> maybe_increment(unknown?, :unknown_placements)
    |> maybe_increment(stale?, :stale_topology_hashes)
    |> maybe_increment(routing_mismatch?, :routing_mismatches)
    |> maybe_add_version_example(reason, bucket, object, expected_set_id, topology_hash)
  end

  defp maybe_increment(acc, true, key), do: Map.update!(acc, key, &(&1 + 1))
  defp maybe_increment(acc, false, _key), do: acc

  defp maybe_add_version_example(acc, nil, _bucket, _object, _expected_set_id, _topology_hash),
    do: acc

  defp maybe_add_version_example(acc, reason, bucket, object, expected_set_id, topology_hash) do
    if length(acc.examples) < @audit_example_limit do
      example = %{
        type: "object_version",
        reason: reason,
        bucket: bucket,
        key: object.key,
        version_id: object.version_id,
        is_delete_marker: object.is_delete_marker,
        placement_set_id: object.placement_set_id,
        expected_set_id: expected_set_id,
        placement_topology_hash: object.placement_topology_hash,
        expected_topology_hash: topology_hash
      }

      Map.update!(acc, :examples, &[example | &1])
    else
      acc
    end
  end

  defp runtime_state(%Job{} = job) do
    case Topology.current() do
      {:ok, topology} -> topology_state("runtime", topology, job)
      {:error, reason} -> unavailable_state("runtime", reason, job)
    end
  end

  defp deployment_state(%Job{} = job, opts) do
    case Keyword.fetch(opts, :deployment_topology) do
      {:ok, topology} ->
        normalize_deployment_topology("override", topology, job)

      :error ->
        deployment_state_from_source(job)
    end
  end

  defp deployment_state_from_source(%Job{} = job) do
    case Application.get_env(:maxio, :topology_source, :config) do
      source when source in [:db, "db"] ->
        case TopologyStore.active_topology() do
          {:ok, topology} -> topology_state("db", topology, job)
          {:error, reason} -> unavailable_state("db", reason, job)
        end

      source when source in [:config, "config"] ->
        case Application.get_env(:maxio, Topology) do
          nil -> unavailable_state("config", :no_deployment_topology, job)
          config -> normalize_deployment_topology("config", config, job)
        end

      other ->
        unavailable_state(to_string(other), {:invalid_topology_source, other}, job)
    end
  end

  defp normalize_deployment_topology(source, %{set_ids: _set_ids} = topology, job),
    do: topology_state(source, topology, job)

  defp normalize_deployment_topology(source, config, job) when is_list(config) do
    topology =
      try do
        Topology.parse_and_validate!(config)
      rescue
        error -> {:error, Exception.message(error)}
      end

    case topology do
      {:error, reason} -> unavailable_state(source, reason, job)
      parsed -> topology_state(source, parsed, job)
    end
  end

  defp normalize_deployment_topology(source, other, job),
    do: unavailable_state(source, {:invalid_deployment_topology, other}, job)

  defp topology_state(source, topology, %Job{} = job) do
    set_ids = Topology.all_set_ids_from(topology)
    pool_ids = Topology.pool_ids_from(topology)
    removed_pool_ids = normalize_pool_ids(job.topology_removal_removed_pool_ids)

    %{
      source: source,
      status: "configured",
      topology_hash: Topology.fingerprint(topology),
      set_ids: set_ids,
      pool_ids: pool_ids,
      target_set_configured?: job.target_set_id in set_ids,
      removed_pool_ids_configured?: Enum.any?(removed_pool_ids, &(&1 in pool_ids))
    }
  end

  defp unavailable_state(source, reason, %Job{} = job) do
    %{
      source: source,
      status: "unavailable",
      reason: inspect(reason),
      topology_hash: nil,
      set_ids: [],
      pool_ids: [],
      target_set_configured?: not is_nil(job.target_set_id),
      removed_pool_ids_configured?:
        normalize_pool_ids(job.topology_removal_removed_pool_ids) != []
    }
  end

  defp retired_from_both_topologies?(%Job{} = job, runtime, deployment) do
    topology_retired?(job, runtime) and topology_retired?(job, deployment)
  end

  defp topology_retired?(%Job{} = job, %{status: "configured"} = topology) do
    topology.topology_hash == job.topology_removal_proposed_hash and
      topology.target_set_configured? == false and
      topology.removed_pool_ids_configured? == false
  end

  defp topology_retired?(_job, _topology), do: false

  defp pool_retired?(%Job{} = job, runtime, deployment) do
    normalize_pool_ids(job.topology_removal_removed_pool_ids) != [] and
      retired_from_both_topologies?(job, runtime, deployment)
  end

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, fallback), do: fallback

  defp normalize_pool_ids(ids) when is_list(ids), do: ids |> Enum.uniq() |> Enum.sort()
  defp normalize_pool_ids(_ids), do: []

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp maybe_block(blockers, true, blocker), do: [blocker | blockers]
  defp maybe_block(blockers, false, _blocker), do: blockers
end
