defmodule Maxio.Cluster.Rebalance.TopologyMutation do
  @moduledoc """
  Safety gates for rebalance/decommission topology removal.

  The preflight and plan paths are read-only. The apply path is deliberately
  runtime-local: it does not rewrite deployment config, remove pools, or delete
  shards. It proves whether a completed decommission job has cleared the metadata
  and physical-data conditions that an operator must satisfy before removing the
  target set from topology.
  """

  alias Maxio.{Buckets, Multipart, Objects}
  alias Maxio.Cluster.{DriveHardwareEvidence, Lock, Placement, Topology, TopologyStore, Transport}
  alias Maxio.Cluster.Rebalance.{Job, Jobs}
  alias Maxio.S3.Log

  @example_limit 10

  @type report :: %{
          status: :ready | :blocked,
          job_id: String.t(),
          job_kind: String.t(),
          target_set_id: non_neg_integer(),
          destination_set_id: non_neg_integer() | nil,
          topology_mutation: false,
          removable: boolean(),
          blockers: [atom()],
          active_job_id: String.t() | nil,
          job_status: String.t(),
          data_movement_status: String.t(),
          source_cleanup_status: String.t(),
          pg_placements_remaining: non_neg_integer(),
          missing_placements: non_neg_integer(),
          unknown_placements: non_neg_integer(),
          active_multipart_uploads: non_neg_integer(),
          missing_multipart_upload_placements: non_neg_integer(),
          unknown_multipart_upload_placements: non_neg_integer(),
          buckets: non_neg_integer(),
          physical_bucket_roots: non_neg_integer(),
          physical_version_roots: non_neg_integer(),
          endpoints: non_neg_integer(),
          endpoint_errors: non_neg_integer(),
          physical_residuals: non_neg_integer(),
          bucket_markers: non_neg_integer(),
          examples: [map()]
        }

  @type removal_plan :: %{
          status: :ready,
          job_id: String.t(),
          job_kind: String.t(),
          target_set_id: non_neg_integer(),
          destination_set_id: non_neg_integer() | nil,
          topology_mutation: false,
          current_topology_hash: String.t(),
          proposed_topology_hash: String.t(),
          current_set_ids: [non_neg_integer()],
          proposed_set_ids: [non_neg_integer()],
          current_pool_ids: [non_neg_integer()],
          proposed_pool_ids: [non_neg_integer()],
          current_topology_nodes: [node()],
          proposed_topology_nodes: [node()],
          target_endpoints: map(),
          removed_set_id: non_neg_integer(),
          removed_pool_id: non_neg_integer(),
          removed_pool_ids: [non_neg_integer()],
          proposed_topology: Topology.t(),
          proposed_config: keyword(),
          preflight: report()
        }

  @type apply_report :: %{
          status: :applied,
          job_id: String.t(),
          job_kind: String.t(),
          target_set_id: non_neg_integer(),
          destination_set_id: non_neg_integer() | nil,
          topology_mutation: :runtime_local,
          deployment_config_mutation: false,
          apply_scope: :runtime_local,
          applied_nodes: [node()],
          current_topology_hash: String.t(),
          proposed_topology_hash: String.t(),
          current_set_ids: [non_neg_integer()],
          proposed_set_ids: [non_neg_integer()],
          current_pool_ids: [non_neg_integer()],
          proposed_pool_ids: [non_neg_integer()],
          current_topology_nodes: [node()],
          proposed_topology_nodes: [node()],
          target_endpoints: map(),
          removed_set_id: non_neg_integer(),
          removed_pool_id: non_neg_integer(),
          removed_pool_ids: [non_neg_integer()],
          proposed_config: keyword(),
          preflight: report(),
          job: map()
        }

  @type cluster_apply_report :: %{
          status: :applied,
          job_id: String.t(),
          job_kind: String.t(),
          target_set_id: non_neg_integer(),
          destination_set_id: non_neg_integer() | nil,
          topology_mutation: :cluster_runtime,
          deployment_config_mutation: false,
          apply_scope: :cluster_runtime,
          applied_nodes: [node()],
          node_results: [map()],
          current_topology_hash: String.t(),
          proposed_topology_hash: String.t(),
          current_set_ids: [non_neg_integer()],
          proposed_set_ids: [non_neg_integer()],
          current_pool_ids: [non_neg_integer()],
          proposed_pool_ids: [non_neg_integer()],
          current_topology_nodes: [node()],
          proposed_topology_nodes: [node()],
          target_endpoints: map(),
          removed_set_id: non_neg_integer(),
          removed_pool_id: non_neg_integer(),
          removed_pool_ids: [non_neg_integer()],
          proposed_config: keyword(),
          preflight: report(),
          job: map()
        }

  @type physical_removal_preflight_report :: %{
          status: :ready | :blocked,
          job_id: String.t(),
          job_kind: String.t(),
          target_set_id: non_neg_integer(),
          destination_set_id: non_neg_integer() | nil,
          topology_mutation: false,
          deployment_config_mutation: false,
          physical_removal: false,
          removable: boolean(),
          blockers: [atom()],
          active_job_id: String.t() | nil,
          job_status: String.t(),
          data_movement_status: String.t(),
          source_cleanup_status: String.t(),
          topology_removal_cluster_status: String.t(),
          topology_removal_deployment_status: String.t(),
          target_endpoints: map(),
          removed_pool_ids: [non_neg_integer()],
          endpoints: non_neg_integer(),
          endpoint_errors: non_neg_integer(),
          physical_residuals: non_neg_integer(),
          physical_bucket_roots: non_neg_integer(),
          physical_version_roots: non_neg_integer(),
          bucket_markers: non_neg_integer(),
          drive_hardware_evidence: map(),
          drive_hardware_evidence_status: atom(),
          drive_hardware_evidence_errors: non_neg_integer(),
          drive_hardware_evidence_gate: false,
          examples: [map()]
        }

  @type deployment_persist_report :: %{
          status: :persisted,
          job_id: String.t(),
          job_kind: String.t(),
          target_set_id: non_neg_integer(),
          destination_set_id: non_neg_integer() | nil,
          topology_mutation: false,
          deployment_config_mutation: :db_active_revision,
          expected_proposed_hash: String.t(),
          deployment_topology_hash: String.t(),
          deployment_set_ids: [non_neg_integer()],
          deployment_pool_ids: [non_neg_integer()],
          revision_id: String.t(),
          revision_source: String.t(),
          cluster_runtime: map()
        }

  @type deployment_verification_report :: %{
          status: :verified | :blocked,
          job_id: String.t(),
          job_kind: String.t(),
          target_set_id: non_neg_integer(),
          destination_set_id: non_neg_integer() | nil,
          topology_mutation: false,
          deployment_config_mutation: false,
          write_routing_retired: boolean(),
          expected_proposed_hash: String.t(),
          deployment_topology_hash: String.t(),
          deployment_set_ids: [non_neg_integer()],
          deployment_pool_ids: [non_neg_integer()],
          cluster_runtime: map(),
          target_set_configured: boolean(),
          blockers: [atom()],
          job_status: String.t(),
          data_movement_status: String.t(),
          source_cleanup_status: String.t(),
          topology_removal_status: String.t(),
          topology_removal_scope: String.t(),
          pg_placements_remaining: non_neg_integer(),
          missing_placements: non_neg_integer(),
          unknown_placements: non_neg_integer(),
          active_multipart_uploads: non_neg_integer(),
          missing_multipart_upload_placements: non_neg_integer(),
          unknown_multipart_upload_placements: non_neg_integer(),
          job: map() | nil
        }

  @type deployment_finalization_report :: %{
          status: :verified,
          job_id: String.t(),
          job_kind: String.t(),
          target_set_id: non_neg_integer(),
          destination_set_id: non_neg_integer() | nil,
          topology_mutation: false,
          deployment_config_mutation: :db_active_revision,
          expected_proposed_hash: String.t(),
          deployment_topology_hash: String.t(),
          deployment_set_ids: [non_neg_integer()],
          deployment_pool_ids: [non_neg_integer()],
          revision_id: String.t(),
          write_routing_retired: boolean(),
          persistence: deployment_persist_report(),
          verification: deployment_verification_report(),
          job: map()
        }

  @doc """
  Run a read-only preflight for removing a decommission target set from topology.
  """
  @spec removal_preflight(String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def removal_preflight(job_id, opts \\ []) when is_binary(job_id) do
    with {:ok, job} <- Jobs.get(job_id),
         :ok <- ensure_decommission_job(job),
         {:ok, topology} <- topology(opts),
         :ok <- ensure_target_in_topology(job, topology) do
      report = build_report(job, topology, opts)
      log_report(report)
      {:ok, report}
    end
  end

  @doc """
  Build an operator-reviewable topology removal artifact for a completed
  decommission job.

  This is intentionally read-only: it does not rewrite deployment config,
  mutate runtime topology, remove pools, update job state, or delete shards.
  """
  @spec removal_plan(String.t(), keyword()) :: {:ok, removal_plan()} | {:error, term()}
  def removal_plan(job_id, opts \\ []) when is_binary(job_id) do
    with {:ok, preflight} <- removal_preflight(job_id, opts),
         :ok <- ensure_ready(preflight),
         {:ok, topology} <- topology(opts),
         {:ok, proposed_topology} <- Topology.remove_set_from(topology, preflight.target_set_id) do
      plan = build_removal_plan(preflight, topology, proposed_topology)
      log_removal_plan(plan)
      {:ok, plan}
    end
  end

  @doc """
  Apply a completed decommission topology removal to the current runtime.

  This is operator-driven and runtime-local. It reruns the same removal preflight
  inside a quorum singleton lock, records an audit marker on the job, and then
  installs the proposed topology into the current BEAM runtime. It does not
  rewrite deployment config and does not delete shard data.
  """
  @spec apply_removal(String.t(), keyword()) :: {:ok, apply_report()} | {:error, term()}
  def apply_removal(job_id, opts \\ []) when is_binary(job_id) do
    case Lock.quorum_with_lock(
           Topology.runtime_mutation_lock_resource(),
           fn -> apply_removal_locked(job_id, opts) end,
           lock_opts(opts)
         ) do
      {:ok, result} ->
        result

      {:error, :no_quorum} ->
        Log.error("rebalance topology removal apply lock unavailable",
          action: :rebalance_topology_apply_removal,
          reason:
            "job_id=#{job_id} resource=#{inspect(Topology.runtime_mutation_lock_resource())}"
        )

        {:error, :topology_apply_locked}
    end
  end

  @doc """
  Apply a completed decommission topology removal to all selected runtime nodes.

  This is operator-driven and runtime-only. It does not rewrite deployment
  config, delete shard data, or provide Raft-style all-or-nothing consensus.
  Every selected node must either install the proposed topology from the expected
  current hash or already be at the proposed hash before convergence is recorded.
  """
  @spec apply_removal_cluster(String.t(), keyword()) ::
          {:ok, cluster_apply_report()} | {:error, term()}
  def apply_removal_cluster(job_id, opts \\ []) when is_binary(job_id) do
    case Lock.quorum_with_lock(
           Topology.runtime_mutation_lock_resource(),
           fn -> apply_removal_cluster_locked(job_id, opts) end,
           lock_opts(opts)
         ) do
      {:ok, result} ->
        result

      {:error, :no_quorum} ->
        Log.error("rebalance topology removal cluster apply lock unavailable",
          action: :rebalance_topology_apply_removal_cluster,
          reason:
            "job_id=#{job_id} resource=#{inspect(Topology.runtime_mutation_lock_resource())}"
        )

        {:error, :topology_apply_locked}
    end
  end

  @doc """
  Persist the converged runtime removal as the active DB deployment topology.

  This is operator-driven and only writes the control-plane topology revision
  table. It does not mark deployment verification complete and therefore does
  not retire decommission write-routing; `verify_removal_deployment/2` remains
  the final gate.
  """
  @spec persist_removal_deployment(String.t(), keyword()) ::
          {:ok, deployment_persist_report()} | {:error, term()}
  def persist_removal_deployment(job_id, opts \\ []) when is_binary(job_id) do
    case Lock.quorum_with_lock(
           Topology.runtime_mutation_lock_resource(),
           fn -> persist_removal_deployment_locked(job_id, opts) end,
           lock_opts(opts)
         ) do
      {:ok, result} ->
        result

      {:error, :no_quorum} ->
        Log.error("rebalance topology removal deployment persistence lock unavailable",
          action: :rebalance_topology_persist_removal_deployment,
          reason:
            "job_id=#{job_id} resource=#{inspect(Topology.runtime_mutation_lock_resource())}"
        )

        {:error, :topology_persist_locked}
    end
  end

  @doc """
  Persist and verify a converged removal as one deployment finalization gate.

  This is the scheduler-safe form of `persist_removal_deployment/2` followed by
  `verify_removal_deployment/2`: both steps run under the same runtime topology
  mutation lock, and the function refuses to proceed while any active
  rebalance/decommission job exists.
  """
  @spec finalize_removal_deployment(String.t(), keyword()) ::
          {:ok, deployment_finalization_report()} | {:error, term()}
  def finalize_removal_deployment(job_id, opts \\ []) when is_binary(job_id) do
    case Lock.quorum_with_lock(
           Topology.runtime_mutation_lock_resource(),
           fn -> finalize_removal_deployment_locked(job_id, opts) end,
           lock_opts(opts)
         ) do
      {:ok, result} ->
        result

      {:error, :no_quorum} ->
        Log.error("rebalance topology removal deployment finalization lock unavailable",
          action: :rebalance_topology_finalize_removal_deployment,
          reason:
            "job_id=#{job_id} resource=#{inspect(Topology.runtime_mutation_lock_resource())}"
        )

        {:error, :topology_finalize_locked}
    end
  end

  @doc """
  Verify deployment config has persisted a previously applied removal.

  This reads an active DB topology revision only when `:topology_source` is
  `:db`; otherwise it reads `config :maxio, Maxio.Cluster.Topology` unless a
  test override is supplied. It never rewrites deployment config, mutates runtime
  topology, deletes shard data, or probes removed target drives.
  """
  @spec verify_removal_deployment(String.t(), keyword()) ::
          {:ok, deployment_verification_report()} | {:error, term()}
  def verify_removal_deployment(job_id, opts \\ []) when is_binary(job_id) do
    case Lock.quorum_with_lock(
           Topology.runtime_mutation_lock_resource(),
           fn -> verify_removal_deployment_locked(job_id, opts) end,
           lock_opts(opts)
         ) do
      {:ok, result} ->
        result

      {:error, :no_quorum} ->
        Log.error("rebalance topology removal deployment verification lock unavailable",
          action: :rebalance_topology_verify_removal_deployment,
          reason:
            "job_id=#{job_id} resource=#{inspect(Topology.runtime_mutation_lock_resource())}"
        )

        {:error, :topology_verify_locked}
    end
  end

  @doc """
  Read-only post-deployment preflight for later physical removal.

  This uses the endpoint manifest captured on the job before runtime/deployment
  topology removal. It does not infer removed drives from current topology and
  never deletes files.
  """
  @spec physical_removal_preflight(String.t(), keyword()) ::
          {:ok, physical_removal_preflight_report()} | {:error, term()}
  def physical_removal_preflight(job_id, opts \\ []) when is_binary(job_id) do
    with {:ok, job} <- Jobs.get(job_id),
         :ok <- ensure_decommission_job(job) do
      report = build_physical_removal_preflight_report(job, opts)
      log_physical_removal_preflight_report(report)
      {:ok, report}
    end
  end

  defp persist_removal_deployment_locked(job_id, opts) do
    with {:ok, job} <- Jobs.get(job_id),
         :ok <- ensure_decommission_job(job),
         :ok <- ensure_runtime_removal_audited(job),
         :ok <- ensure_cluster_removal_audited(job),
         :ok <- ensure_expected_proposed_topology_hash(job, opts),
         {:ok, runtime_topology} <- runtime_topology(opts),
         :ok <- ensure_target_absent_from_deployment(job, runtime_topology),
         :ok <- ensure_deployment_hash_matches(job, runtime_topology),
         {:ok, cluster_runtime} <-
           ensure_cluster_runtime_topology_matches_audit(job, runtime_topology, opts),
         report <- build_deployment_verification_report(job, runtime_topology, cluster_runtime),
         :ok <- ensure_deployment_persistence_ready(report),
         {:ok, revision} <-
           TopologyStore.activate_topology(runtime_topology, topology_store_opts(job, opts)) do
      report = build_deployment_persist_report(job, runtime_topology, cluster_runtime, revision)
      log_deployment_persist_report(report)
      {:ok, report}
    end
  end

  defp finalize_removal_deployment_locked(job_id, opts) do
    with :ok <- ensure_no_active_rebalance_job(),
         {:ok, persist_report} <- persist_removal_deployment_locked(job_id, opts),
         :ok <- ensure_no_active_rebalance_job(),
         {:ok, verify_report} <- verify_removal_deployment_locked(job_id, opts) do
      {:ok, build_deployment_finalization_report(persist_report, verify_report)}
    end
  end

  defp verify_removal_deployment_locked(job_id, opts) do
    with {:ok, job} <- Jobs.get(job_id),
         :ok <- ensure_decommission_job(job),
         :ok <- ensure_runtime_removal_audited(job),
         :ok <- ensure_cluster_removal_audited(job),
         {:ok, deployment_topology} <- deployment_topology(opts),
         :ok <- ensure_target_absent_from_deployment(job, deployment_topology),
         :ok <- ensure_deployment_hash_matches(job, deployment_topology),
         {:ok, cluster_runtime} <-
           ensure_cluster_runtime_topology_matches_audit(job, deployment_topology, opts),
         report <- build_deployment_verification_report(job, deployment_topology, cluster_runtime),
         :ok <- ensure_deployment_verification_ready(report),
         {:ok, updated} <-
           Jobs.mark_topology_removal_deployment_verified(
             job,
             %{deployment_topology_hash: report.deployment_topology_hash},
             opts
           ) do
      report = %{
        report
        | status: :verified,
          write_routing_retired: true,
          job: Jobs.to_view(updated)
      }

      log_deployment_verification_report(report)
      {:ok, report}
    end
  end

  defp ensure_decommission_job(%Job{kind: "decommission"}), do: :ok
  defp ensure_decommission_job(%Job{kind: kind}), do: {:error, {:unsupported_job_kind, kind}}

  defp ensure_no_active_rebalance_job do
    case Jobs.active_job() do
      nil -> :ok
      %Job{} = active -> {:error, {:active_job_exists, Jobs.to_view(active)}}
    end
  end

  defp topology(opts) do
    case Keyword.fetch(opts, :topology) do
      {:ok, nil} ->
        {:error, :no_topology}

      {:ok, topology} ->
        {:ok, topology}

      :error ->
        if Topology.configured?(), do: {:ok, current_topology()}, else: {:error, :no_topology}
    end
  end

  defp runtime_topology(opts) do
    cond do
      Keyword.has_key?(opts, :runtime_topology) ->
        normalize_deployment_topology(Keyword.fetch!(opts, :runtime_topology))

      Keyword.has_key?(opts, :runtime_config) ->
        parse_deployment_config(Keyword.fetch!(opts, :runtime_config))

      true ->
        Topology.current()
    end
  end

  defp deployment_topology(opts) do
    cond do
      Keyword.has_key?(opts, :deployment_topology) ->
        normalize_deployment_topology(Keyword.fetch!(opts, :deployment_topology))

      Keyword.has_key?(opts, :deployment_config) ->
        parse_deployment_config(Keyword.fetch!(opts, :deployment_config))

      true ->
        configured_deployment_topology()
    end
  end

  defp configured_deployment_topology do
    case topology_source() do
      :db ->
        db_deployment_topology(:required)

      :config ->
        config_deployment_topology()

      other ->
        {:error, {:invalid_topology_source, other}}
    end
  end

  defp db_deployment_topology(:required) do
    case TopologyStore.active_topology() do
      {:ok, topology} ->
        {:ok, topology}

      {:error, :no_active_topology_revision} ->
        {:error, :no_deployment_topology}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp config_deployment_topology do
    case Application.get_env(:maxio, Topology) do
      nil -> {:error, :no_deployment_topology}
      config -> parse_deployment_config(config)
    end
  end

  defp topology_source do
    case Application.get_env(:maxio, :topology_source, :config) do
      :config -> :config
      "config" -> :config
      :db -> :db
      "db" -> :db
      other -> other
    end
  end

  defp normalize_deployment_topology(nil), do: {:error, :no_deployment_topology}

  defp normalize_deployment_topology(%{set_ids: _set_ids, sets: _sets} = topology),
    do: {:ok, topology}

  defp normalize_deployment_topology(config) when is_list(config),
    do: parse_deployment_config(config)

  defp normalize_deployment_topology(value),
    do: {:error, {:invalid_deployment_topology, inspect(value)}}

  defp parse_deployment_config(nil), do: {:error, :no_deployment_topology}

  defp parse_deployment_config(config) when is_list(config) do
    {:ok, Topology.parse_and_validate!(config)}
  rescue
    error -> {:error, {:invalid_deployment_topology, Exception.message(error)}}
  end

  defp parse_deployment_config(value),
    do: {:error, {:invalid_deployment_topology, inspect(value)}}

  defp ensure_runtime_removal_audited(%Job{
         topology_removal_status: "runtime_local_applied",
         topology_removal_scope: "runtime_local",
         topology_removal_proposed_hash: proposed_hash
       })
       when is_binary(proposed_hash) and byte_size(proposed_hash) > 0,
       do: :ok

  defp ensure_runtime_removal_audited(%Job{
         topology_removal_status: "runtime_local_applied",
         topology_removal_scope: "runtime_local"
       }),
       do: {:error, :missing_proposed_topology_hash}

  defp ensure_runtime_removal_audited(%Job{}), do: {:error, :topology_removal_not_applied}

  defp ensure_cluster_removal_audited(%Job{
         topology_removal_cluster_status: "runtime_converged",
         topology_removal_cluster_hash: proposed_hash,
         topology_removal_proposed_hash: proposed_hash,
         topology_removal_cluster_nodes: nodes
       })
       when is_binary(proposed_hash) and is_list(nodes) and nodes != [],
       do: :ok

  defp ensure_cluster_removal_audited(%Job{
         topology_removal_cluster_status: "runtime_converged",
         topology_removal_cluster_hash: nil
       }),
       do: {:error, :missing_cluster_topology_hash}

  defp ensure_cluster_removal_audited(%Job{
         topology_removal_cluster_status: "runtime_converged",
         topology_removal_cluster_nodes: nodes
       })
       when not is_list(nodes) or nodes == [],
       do: {:error, :missing_cluster_topology_nodes}

  defp ensure_cluster_removal_audited(%Job{
         topology_removal_cluster_status: "runtime_converged",
         topology_removal_cluster_hash: cluster_hash,
         topology_removal_proposed_hash: proposed_hash
       })
       when is_binary(cluster_hash) and is_binary(proposed_hash) and cluster_hash != proposed_hash,
       do: {:error, {:cluster_topology_hash_mismatch, proposed_hash, cluster_hash}}

  defp ensure_cluster_removal_audited(%Job{}),
    do: {:error, :topology_removal_cluster_not_converged}

  defp ensure_expected_proposed_topology_hash(
         %Job{topology_removal_proposed_hash: proposed_hash},
         opts
       )
       when is_binary(proposed_hash) do
    case Keyword.fetch(opts, :expected_proposed_topology_hash) do
      {:ok, ^proposed_hash} -> :ok
      {:ok, expected} -> {:error, {:proposed_topology_hash_mismatch, proposed_hash, expected}}
      :error -> {:error, :missing_expected_proposed_topology_hash}
    end
  end

  defp ensure_expected_proposed_topology_hash(%Job{}, _opts),
    do: {:error, :missing_proposed_topology_hash}

  defp ensure_cluster_runtime_topology_matches_audit(
         %Job{topology_removal_proposed_hash: nil},
         _deployment_topology,
         _opts
       ),
       do: {:error, :missing_proposed_topology_hash}

  defp ensure_cluster_runtime_topology_matches_audit(
         %Job{topology_removal_proposed_hash: expected} = job,
         deployment_topology,
         opts
       ) do
    report = build_cluster_runtime_report(expected, job, deployment_topology, opts)

    if report.status == :converged do
      {:ok, report}
    else
      {:error, {:cluster_runtime_topology_not_converged, report}}
    end
  end

  defp ensure_target_absent_from_deployment(%Job{target_set_id: nil}, _topology),
    do: {:error, :missing_target_set_id}

  defp ensure_target_absent_from_deployment(%Job{target_set_id: set_id}, topology) do
    set_ids = Topology.all_set_ids_from(topology)

    if set_id in set_ids do
      {:error, {:target_set_still_configured, set_id, set_ids}}
    else
      :ok
    end
  end

  defp ensure_deployment_hash_matches(%Job{topology_removal_proposed_hash: nil}, _topology),
    do: {:error, :missing_proposed_topology_hash}

  defp ensure_deployment_hash_matches(%Job{topology_removal_proposed_hash: expected}, topology) do
    actual = Placement.topology_hash(topology)

    if actual == expected do
      :ok
    else
      {:error, {:deployment_topology_hash_mismatch, expected, actual}}
    end
  end

  defp build_deployment_verification_report(%Job{} = job, topology, cluster_runtime) do
    set_ids = Topology.all_set_ids_from(topology)
    target_set_configured = job.target_set_id in set_ids
    pg_remaining = Objects.count_versions_with_placement_set(job.target_set_id)
    missing_placements = Objects.count_versions_missing_placement_set()
    unknown_placements = Objects.count_versions_with_unknown_placement_set(set_ids)
    active_uploads = Multipart.count_uploads_with_placement_set(job.target_set_id)
    missing_upload_placements = Multipart.count_uploads_missing_placement_set()
    unknown_upload_placements = Multipart.count_uploads_with_unknown_placement_set(set_ids)

    blockers =
      []
      |> maybe_block(job.status != "complete", :job_not_complete)
      |> maybe_block(job.data_movement_status != "complete", :data_movement_not_complete)
      |> maybe_block(job.source_cleanup_status != "complete", :source_cleanup_not_complete)
      |> maybe_block(
        job.topology_removal_status != "runtime_local_applied",
        :topology_removal_not_applied
      )
      |> maybe_block(job.topology_removal_scope != "runtime_local", :topology_removal_not_applied)
      |> maybe_block(target_set_configured, :target_set_still_configured)
      |> maybe_block(pg_remaining > 0, :pg_placements_remaining)
      |> maybe_block(missing_placements > 0, :missing_persisted_placement)
      |> maybe_block(unknown_placements > 0, :unknown_placement_set)
      |> maybe_block(active_uploads > 0, :active_multipart_uploads)
      |> maybe_block(missing_upload_placements > 0, :missing_multipart_upload_placement)
      |> maybe_block(unknown_upload_placements > 0, :unknown_multipart_upload_placement)
      |> Enum.reverse()

    %{
      status: if(blockers == [], do: :verified, else: :blocked),
      job_id: job.id,
      job_kind: job.kind,
      target_set_id: job.target_set_id,
      destination_set_id: job.destination_set_id,
      topology_mutation: false,
      deployment_config_mutation: false,
      write_routing_retired: false,
      expected_proposed_hash: job.topology_removal_proposed_hash,
      deployment_topology_hash: Placement.topology_hash(topology),
      deployment_set_ids: set_ids,
      deployment_pool_ids: Topology.pool_ids_from(topology),
      cluster_runtime: cluster_runtime,
      target_set_configured: target_set_configured,
      blockers: blockers,
      job_status: job.status,
      data_movement_status: job.data_movement_status,
      source_cleanup_status: job.source_cleanup_status,
      topology_removal_status: job.topology_removal_status,
      topology_removal_scope: job.topology_removal_scope,
      pg_placements_remaining: pg_remaining,
      missing_placements: missing_placements,
      unknown_placements: unknown_placements,
      active_multipart_uploads: active_uploads,
      missing_multipart_upload_placements: missing_upload_placements,
      unknown_multipart_upload_placements: unknown_upload_placements,
      job: nil
    }
  end

  defp build_deployment_persist_report(job, topology, cluster_runtime, revision) do
    %{
      status: :persisted,
      job_id: job.id,
      job_kind: job.kind,
      target_set_id: job.target_set_id,
      destination_set_id: job.destination_set_id,
      topology_mutation: false,
      deployment_config_mutation: :db_active_revision,
      expected_proposed_hash: job.topology_removal_proposed_hash,
      deployment_topology_hash: Placement.topology_hash(topology),
      deployment_set_ids: Topology.all_set_ids_from(topology),
      deployment_pool_ids: Topology.pool_ids_from(topology),
      revision_id: revision.id,
      revision_source: revision.source,
      cluster_runtime: cluster_runtime
    }
  end

  defp build_deployment_finalization_report(persist_report, verify_report) do
    %{
      status: :verified,
      job_id: verify_report.job_id,
      job_kind: verify_report.job_kind,
      target_set_id: verify_report.target_set_id,
      destination_set_id: verify_report.destination_set_id,
      topology_mutation: false,
      deployment_config_mutation: :db_active_revision,
      expected_proposed_hash: verify_report.expected_proposed_hash,
      deployment_topology_hash: verify_report.deployment_topology_hash,
      deployment_set_ids: verify_report.deployment_set_ids,
      deployment_pool_ids: verify_report.deployment_pool_ids,
      revision_id: persist_report.revision_id,
      write_routing_retired: verify_report.write_routing_retired,
      persistence: persist_report,
      verification: verify_report,
      job: verify_report.job
    }
  end

  defp ensure_deployment_verification_ready(%{blockers: []}), do: :ok

  defp ensure_deployment_verification_ready(%{} = report),
    do: {:error, {:deployment_verification_blocked, report}}

  defp ensure_deployment_persistence_ready(%{blockers: []}), do: :ok

  defp ensure_deployment_persistence_ready(%{} = report),
    do: {:error, {:deployment_persistence_blocked, report}}

  defp build_cluster_runtime_report(expected_hash, job, deployment_topology, opts) do
    {nodes, missing_results} = cluster_runtime_nodes(job, deployment_topology, opts)
    snapshot_fun = Keyword.get(opts, :node_snapshot_fun, &runtime_snapshot_on_node/1)

    node_results =
      Enum.map(nodes, fn node ->
        normalize_node_runtime_snapshot(node, expected_hash, snapshot_fun.(node))
      end) ++ missing_results

    converged? = Enum.all?(node_results, &(&1.status == :converged))

    %{
      status: if(converged?, do: :converged, else: :blocked),
      expected_topology_hash: expected_hash,
      required_node_names: job.topology_removal_cluster_nodes || [],
      nodes: nodes,
      node_results: node_results,
      missing_expected_nodes: Enum.map(missing_results, & &1.node),
      failed_nodes:
        node_results
        |> Enum.reject(&(&1.status == :converged))
        |> Enum.map(& &1.node)
    }
  end

  defp cluster_runtime_nodes(job, deployment_topology, opts) do
    requested_nodes =
      case Keyword.get(opts, :nodes) do
        nil -> []
        nodes when is_list(nodes) -> nodes
      end

    base_nodes =
      Maxio.Cluster.nodes() ++
        topology_nodes(deployment_topology) ++ requested_nodes ++ [Node.self()]

    known_nodes = known_node_map(base_nodes)
    required_node_names = job.topology_removal_cluster_nodes || []

    required_nodes =
      required_node_names
      |> Enum.flat_map(fn node_name ->
        case Map.fetch(known_nodes, node_name) do
          {:ok, node} -> [node]
          :error -> []
        end
      end)

    missing_results =
      required_node_names
      |> Enum.reject(&Map.has_key?(known_nodes, &1))
      |> Enum.map(&missing_expected_node_result/1)

    nodes =
      base_nodes
      |> Kernel.++(required_nodes)
      |> unique_sorted_nodes()

    {nodes, missing_results}
  end

  defp runtime_snapshot_on_node(node) do
    if node == Node.self() do
      {:ok, Topology.runtime_snapshot()}
    else
      try do
        {:ok, :erpc.call(node, Topology, :runtime_snapshot, [], 5_000)}
      catch
        :error, reason -> {:error, {:unavailable, reason}}
        :exit, reason -> {:error, {:unavailable, reason}}
        :throw, reason -> {:error, {:unavailable, reason}}
      end
    end
  end

  defp normalize_node_runtime_snapshot(
         node,
         expected_hash,
         {:ok, %{runtime_status: :configured, topology_hash: expected_hash} = snapshot}
       ) do
    snapshot
    |> Map.put(:node, node)
    |> Map.put(:status, :converged)
  end

  defp normalize_node_runtime_snapshot(
         node,
         _expected_hash,
         {:ok, %{runtime_status: :configured, topology_hash: actual_hash} = snapshot}
       ) do
    snapshot
    |> Map.put(:node, node)
    |> Map.put(:status, :hash_mismatch)
    |> Map.put(:actual_topology_hash, actual_hash)
  end

  defp normalize_node_runtime_snapshot(
         node,
         _expected_hash,
         {:ok, %{runtime_status: status} = snapshot}
       ) do
    snapshot
    |> Map.put(:node, node)
    |> Map.put(:status, status)
  end

  defp normalize_node_runtime_snapshot(node, _expected_hash, {:error, reason}) do
    %{node: node, status: :error, reason: inspect(reason), topology_hash: nil}
  end

  defp normalize_node_runtime_snapshot(node, _expected_hash, other) do
    %{node: node, status: :error, reason: inspect({:invalid_result, other}), topology_hash: nil}
  end

  defp ensure_target_in_topology(%Job{target_set_id: set_id}, topology) when is_integer(set_id) do
    set_ids = Topology.all_set_ids_from(topology)

    if set_id in set_ids do
      :ok
    else
      {:error, {:unknown_target_set_id, set_id, set_ids}}
    end
  end

  defp ensure_target_in_topology(%Job{target_set_id: nil}, _topology),
    do: {:error, :missing_target_set_id}

  defp build_report(%Job{} = job, topology, opts) do
    active_job = Jobs.active_job()
    set_ids = Topology.all_set_ids_from(topology)
    pg_remaining = Objects.count_versions_with_placement_set(job.target_set_id)
    missing_placements = Objects.count_versions_missing_placement_set()
    unknown_placements = Objects.count_versions_with_unknown_placement_set(set_ids)
    active_uploads = Multipart.count_uploads_with_placement_set(job.target_set_id)
    missing_upload_placements = Multipart.count_uploads_missing_placement_set()
    unknown_upload_placements = Multipart.count_uploads_with_unknown_placement_set(set_ids)
    probe = probe_target_set(job.target_set_id, topology, opts)

    blockers =
      []
      |> maybe_block(job.status != "complete", :job_not_complete)
      |> maybe_block(job.data_movement_status != "complete", :data_movement_not_complete)
      |> maybe_block(job.source_cleanup_status != "complete", :source_cleanup_not_complete)
      |> maybe_block(is_nil(job.destination_set_id), :missing_destination_set_id)
      |> maybe_block(not is_nil(active_job), :active_job_exists)
      |> maybe_block(pg_remaining > 0, :pg_placements_remaining)
      |> maybe_block(missing_placements > 0, :missing_persisted_placement)
      |> maybe_block(unknown_placements > 0, :unknown_placement_set)
      |> maybe_block(active_uploads > 0, :active_multipart_uploads)
      |> maybe_block(missing_upload_placements > 0, :missing_multipart_upload_placement)
      |> maybe_block(unknown_upload_placements > 0, :unknown_multipart_upload_placement)
      |> maybe_block(probe.endpoint_errors > 0, :target_set_unreachable)
      |> maybe_block(probe.physical_residuals > 0, :physical_residuals_present)
      |> Enum.reverse()

    removable = blockers == []

    %{
      status: if(removable, do: :ready, else: :blocked),
      job_id: job.id,
      job_kind: job.kind,
      target_set_id: job.target_set_id,
      destination_set_id: job.destination_set_id,
      topology_mutation: false,
      removable: removable,
      blockers: blockers,
      active_job_id: if(active_job, do: active_job.id),
      job_status: job.status,
      data_movement_status: job.data_movement_status,
      source_cleanup_status: job.source_cleanup_status,
      pg_placements_remaining: pg_remaining,
      missing_placements: missing_placements,
      unknown_placements: unknown_placements,
      active_multipart_uploads: active_uploads,
      missing_multipart_upload_placements: missing_upload_placements,
      unknown_multipart_upload_placements: unknown_upload_placements,
      buckets: probe.buckets,
      physical_bucket_roots: probe.physical_bucket_roots,
      physical_version_roots: probe.physical_version_roots,
      endpoints: probe.endpoints,
      endpoint_errors: probe.endpoint_errors,
      physical_residuals: probe.physical_residuals,
      bucket_markers: probe.bucket_markers,
      examples: Enum.reverse(probe.examples)
    }
  end

  defp maybe_block(blockers, true, blocker), do: [blocker | blockers]
  defp maybe_block(blockers, false, _blocker), do: blockers

  defp ensure_ready(%{status: :ready}), do: :ok
  defp ensure_ready(%{} = report), do: {:error, {:preflight_blocked, report}}

  defp apply_removal_locked(job_id, opts) do
    with {:ok, plan} <- removal_plan(job_id, opts),
         :ok <-
           ensure_expected_current_hash(plan, Keyword.get(opts, :expected_current_topology_hash)),
         {:ok, job} <-
           Jobs.mark_topology_removal_applied(
             job_id,
             %{
               current_topology_hash: plan.current_topology_hash,
               proposed_topology_hash: plan.proposed_topology_hash,
               target_endpoints: plan.target_endpoints,
               removed_pool_ids: plan.removed_pool_ids
             },
             opts
           ) do
      :ok = after_topology_removal_audit(opts)
      Topology.install_runtime!(plan.proposed_topology)

      report = build_apply_report(plan, job)
      log_apply_report(report)
      {:ok, report}
    end
  end

  defp apply_removal_cluster_locked(job_id, opts) do
    with {:ok, plan} <- removal_plan(job_id, opts),
         :ok <-
           ensure_expected_current_hash(plan, Keyword.get(opts, :expected_current_topology_hash)),
         {:ok, audited} <-
           Jobs.mark_topology_removal_applied(
             job_id,
             %{
               current_topology_hash: plan.current_topology_hash,
               proposed_topology_hash: plan.proposed_topology_hash,
               target_endpoints: plan.target_endpoints,
               removed_pool_ids: plan.removed_pool_ids
             },
             opts
           ),
         {:ok, node_results} <- apply_cluster_runtime_topology(plan, opts),
         {:ok, job} <-
           Jobs.mark_topology_removal_cluster_converged(
             audited,
             %{
               cluster_topology_hash: plan.proposed_topology_hash,
               cluster_nodes: cluster_converged_nodes(plan, node_results)
             },
             opts
           ) do
      report = build_cluster_apply_report(plan, node_results, job)
      log_cluster_apply_report(report)
      {:ok, report}
    end
  end

  defp apply_cluster_runtime_topology(plan, opts) do
    nodes = cluster_apply_nodes(plan, opts)
    node_apply_fun = Keyword.get(opts, :node_apply_fun, &install_runtime_on_node/3)

    results =
      nodes
      |> order_nodes_local_last()
      |> Enum.reduce_while([], fn node, acc ->
        normalize_node_apply_result(
          node,
          node_apply_fun.(node, plan.proposed_topology, plan.current_topology_hash)
        )
        |> case do
          %{status: status} = result when status in [:applied, :already_applied] ->
            {:cont, [result | acc]}

          result ->
            {:halt, [result | acc]}
        end
      end)
      |> Enum.reverse()

    if Enum.all?(results, &(&1.status in [:applied, :already_applied])) do
      {:ok, results}
    else
      {:error,
       {:cluster_topology_apply_failed, build_cluster_apply_failure_report(plan, results)}}
    end
  end

  defp ensure_expected_current_hash(_plan, nil), do: :ok

  defp ensure_expected_current_hash(plan, expected) when expected == plan.current_topology_hash,
    do: :ok

  defp ensure_expected_current_hash(plan, expected),
    do: {:error, {:current_topology_hash_mismatch, expected, plan.current_topology_hash}}

  defp after_topology_removal_audit(opts) do
    case Keyword.get(opts, :after_topology_removal_audit) do
      nil -> :ok
      fun when is_function(fun, 0) -> fun.()
    end
  end

  defp topology_store_opts(job, opts) do
    [
      expected_topology_hash: job.topology_removal_proposed_hash,
      source: "decommission_removal",
      source_job_id: job.id
    ]
    |> maybe_put(:now, Keyword.get(opts, :now))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp cluster_converged_nodes(plan, node_results) do
    plan.current_topology_nodes
    |> Kernel.++(Enum.map(node_results, & &1.node))
    |> unique_sorted_nodes()
  end

  defp cluster_apply_nodes(plan, opts) do
    nodes =
      case Keyword.get(opts, :nodes) do
        nil ->
          Maxio.Cluster.nodes() ++
            plan.current_topology_nodes ++
            plan.proposed_topology_nodes

        nodes when is_list(nodes) ->
          nodes ++ plan.current_topology_nodes ++ plan.proposed_topology_nodes
      end

    nodes
    |> Kernel.++([Node.self()])
    |> unique_sorted_nodes()
  end

  defp topology_nodes(%{preflight: %{}} = plan),
    do: topology_nodes(plan.preflight)

  defp topology_nodes(%{sets: sets}) do
    sets
    |> Map.values()
    |> Enum.flat_map(& &1.endpoints)
    |> Enum.map(fn {node, _drive} -> node end)
  end

  defp topology_nodes(%{target_set_id: _set_id}), do: []
  defp topology_nodes(_value), do: []

  defp unique_sorted_nodes(nodes) do
    nodes
    |> Enum.filter(&is_atom/1)
    |> MapSet.new()
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp known_node_map(nodes) do
    nodes
    |> unique_sorted_nodes()
    |> Map.new(&{Atom.to_string(&1), &1})
  end

  defp missing_expected_node_result(node_name) do
    %{
      node: node_name,
      status: :missing_expected_node,
      reason:
        "expected runtime node from cluster convergence audit is not connected or configured",
      topology_hash: nil
    }
  end

  defp order_nodes_local_last(nodes) do
    nodes
    |> Enum.reject(&(&1 == Node.self()))
    |> Kernel.++(if Node.self() in nodes, do: [Node.self()], else: [])
  end

  defp install_runtime_on_node(node, topology, expected_current_hash) do
    if node == Node.self() do
      Topology.install_runtime_if_hash(topology, expected_current_hash)
    else
      try do
        :erpc.call(
          node,
          Topology,
          :install_runtime_if_hash,
          [topology, expected_current_hash],
          5_000
        )
      catch
        :error, reason -> {:error, {:unavailable, reason}}
        :exit, reason -> {:error, {:unavailable, reason}}
        :throw, reason -> {:error, {:unavailable, reason}}
      end
    end
  end

  defp normalize_node_apply_result(node, {:ok, %{apply_status: status} = snapshot})
       when status in [:applied, :already_applied] do
    snapshot
    |> Map.put(:node, node)
    |> Map.put(:status, status)
  end

  defp normalize_node_apply_result(node, {:ok, %{topology_hash: _hash} = snapshot}) do
    snapshot
    |> Map.put(:node, node)
    |> Map.put_new(:status, :applied)
  end

  defp normalize_node_apply_result(node, {:error, reason}) do
    %{node: node, status: :error, reason: inspect(reason), topology_hash: nil}
  end

  defp normalize_node_apply_result(node, other) do
    %{node: node, status: :error, reason: inspect({:invalid_result, other}), topology_hash: nil}
  end

  defp build_cluster_apply_failure_report(plan, node_results) do
    %{
      status: :blocked,
      job_id: plan.job_id,
      target_set_id: plan.target_set_id,
      topology_mutation: false,
      deployment_config_mutation: false,
      current_topology_hash: plan.current_topology_hash,
      proposed_topology_hash: plan.proposed_topology_hash,
      required_nodes: plan.current_topology_nodes,
      node_results: node_results,
      failed_nodes:
        node_results
        |> Enum.reject(&(&1.status in [:applied, :already_applied]))
        |> Enum.map(& &1.node)
    }
  end

  defp build_removal_plan(preflight, topology, proposed_topology) do
    current_pool_ids = Topology.pool_ids_from(topology)
    proposed_pool_ids = Topology.pool_ids_from(proposed_topology)
    removed_pool_id = Topology.pool_id_for_set_from(topology, preflight.target_set_id)

    %{
      status: :ready,
      job_id: preflight.job_id,
      job_kind: preflight.job_kind,
      target_set_id: preflight.target_set_id,
      destination_set_id: preflight.destination_set_id,
      topology_mutation: false,
      current_topology_hash: Placement.topology_hash(topology),
      proposed_topology_hash: Placement.topology_hash(proposed_topology),
      current_set_ids: Topology.all_set_ids_from(topology),
      proposed_set_ids: Topology.all_set_ids_from(proposed_topology),
      current_pool_ids: current_pool_ids,
      proposed_pool_ids: proposed_pool_ids,
      current_topology_nodes: topology_nodes(topology) |> unique_sorted_nodes(),
      proposed_topology_nodes: topology_nodes(proposed_topology) |> unique_sorted_nodes(),
      target_endpoints: target_endpoint_manifest(topology, preflight.target_set_id),
      removed_set_id: preflight.target_set_id,
      removed_pool_id: removed_pool_id,
      removed_pool_ids: current_pool_ids -- proposed_pool_ids,
      proposed_topology: proposed_topology,
      proposed_config: Topology.to_config(proposed_topology),
      preflight: preflight
    }
  end

  defp build_apply_report(plan, job) do
    %{
      status: :applied,
      job_id: plan.job_id,
      job_kind: plan.job_kind,
      target_set_id: plan.target_set_id,
      destination_set_id: plan.destination_set_id,
      topology_mutation: :runtime_local,
      deployment_config_mutation: false,
      apply_scope: :runtime_local,
      applied_nodes: [Node.self()],
      current_topology_hash: plan.current_topology_hash,
      proposed_topology_hash: plan.proposed_topology_hash,
      current_set_ids: plan.current_set_ids,
      proposed_set_ids: plan.proposed_set_ids,
      current_pool_ids: plan.current_pool_ids,
      proposed_pool_ids: plan.proposed_pool_ids,
      current_topology_nodes: plan.current_topology_nodes,
      proposed_topology_nodes: plan.proposed_topology_nodes,
      target_endpoints: plan.target_endpoints,
      removed_set_id: plan.removed_set_id,
      removed_pool_id: plan.removed_pool_id,
      removed_pool_ids: plan.removed_pool_ids,
      proposed_config: plan.proposed_config,
      preflight: plan.preflight,
      job: Jobs.to_view(job)
    }
  end

  defp build_cluster_apply_report(plan, node_results, job) do
    %{
      status: :applied,
      job_id: plan.job_id,
      job_kind: plan.job_kind,
      target_set_id: plan.target_set_id,
      destination_set_id: plan.destination_set_id,
      topology_mutation: :cluster_runtime,
      deployment_config_mutation: false,
      apply_scope: :cluster_runtime,
      applied_nodes: Enum.map(node_results, & &1.node),
      node_results: node_results,
      current_topology_hash: plan.current_topology_hash,
      proposed_topology_hash: plan.proposed_topology_hash,
      current_set_ids: plan.current_set_ids,
      proposed_set_ids: plan.proposed_set_ids,
      current_pool_ids: plan.current_pool_ids,
      proposed_pool_ids: plan.proposed_pool_ids,
      current_topology_nodes: plan.current_topology_nodes,
      proposed_topology_nodes: plan.proposed_topology_nodes,
      target_endpoints: plan.target_endpoints,
      removed_set_id: plan.removed_set_id,
      removed_pool_id: plan.removed_pool_id,
      removed_pool_ids: plan.removed_pool_ids,
      proposed_config: plan.proposed_config,
      preflight: plan.preflight,
      job: Jobs.to_view(job)
    }
  end

  defp build_physical_removal_preflight_report(%Job{} = job, opts) do
    active_job = Jobs.active_job()
    removed_pool_ids = normalize_removed_pool_ids(job.topology_removal_removed_pool_ids)

    {manifest_status, target_endpoints, endpoints} =
      physical_target_endpoints_from_job(job)

    drive_hardware_evidence =
      physical_removal_drive_hardware_evidence(
        manifest_status,
        endpoints,
        job.target_set_id,
        opts
      )

    probe =
      case manifest_status do
        :ok ->
          probe_endpoint_roots(endpoints, opts)

        {:error, reason} ->
          empty_physical_probe()
          |> record_endpoint_error(%{
            type: :endpoint_error,
            layout: :physical_removal_manifest,
            reason: inspect(reason)
          })
      end

    blockers =
      []
      |> maybe_block(job.status != "complete", :job_not_complete)
      |> maybe_block(job.data_movement_status != "complete", :data_movement_not_complete)
      |> maybe_block(job.source_cleanup_status != "complete", :source_cleanup_not_complete)
      |> maybe_block(
        job.topology_removal_cluster_status != "runtime_converged",
        :cluster_runtime_not_converged
      )
      |> maybe_block(
        job.topology_removal_deployment_status != "verified",
        :deployment_not_verified
      )
      |> maybe_block(not is_nil(active_job), :active_job_exists)
      |> maybe_block(
        manifest_status == {:error, :missing_physical_removal_manifest},
        :missing_physical_removal_manifest
      )
      |> maybe_block(
        match?(
          {:error, reason} when reason != :missing_physical_removal_manifest,
          manifest_status
        ),
        :invalid_physical_removal_manifest
      )
      |> maybe_block(probe.endpoint_errors > 0, :target_endpoints_unreachable)
      |> maybe_block(probe.physical_residuals > 0, :physical_residuals_present)
      |> Enum.reverse()

    ready? = blockers == []

    %{
      status: if(ready?, do: :ready, else: :blocked),
      job_id: job.id,
      job_kind: job.kind,
      target_set_id: job.target_set_id,
      destination_set_id: job.destination_set_id,
      topology_mutation: false,
      deployment_config_mutation: false,
      physical_removal: false,
      removable: ready?,
      blockers: blockers,
      active_job_id: if(active_job, do: active_job.id),
      job_status: job.status,
      data_movement_status: job.data_movement_status,
      source_cleanup_status: job.source_cleanup_status,
      topology_removal_cluster_status: job.topology_removal_cluster_status,
      topology_removal_deployment_status: job.topology_removal_deployment_status,
      target_endpoints: target_endpoints,
      removed_pool_ids: removed_pool_ids,
      endpoints: probe.endpoints,
      endpoint_errors: probe.endpoint_errors,
      physical_residuals: probe.physical_residuals,
      physical_bucket_roots: probe.physical_bucket_roots,
      physical_version_roots: probe.physical_version_roots,
      bucket_markers: probe.bucket_markers,
      drive_hardware_evidence: drive_hardware_evidence,
      drive_hardware_evidence_status: drive_hardware_evidence.status,
      drive_hardware_evidence_errors: drive_hardware_evidence.errors,
      drive_hardware_evidence_gate: false,
      examples: Enum.reverse(probe.examples)
    }
  end

  defp physical_removal_drive_hardware_evidence(:ok, endpoints, target_set_id, opts) do
    if drive_hardware_evidence_requested?(opts) do
      endpoints
      |> DriveHardwareEvidence.sample_endpoints(
        drive_hardware_evidence_sample_opts(opts)
        |> Keyword.put(:set_id, target_set_id)
        |> Keyword.put(:topology_sets, 1)
      )
      |> Map.put(:enabled, true)
      |> Map.put(:drive_hardware_evidence_gate, false)
    else
      empty_physical_drive_hardware_evidence(:not_sampled)
    end
  end

  defp physical_removal_drive_hardware_evidence(
         {:error, reason},
         _endpoints,
         _target_set_id,
         opts
       ) do
    if drive_hardware_evidence_requested?(opts) do
      empty_physical_drive_hardware_evidence(:not_collected)
      |> Map.put(:reason, inspect(reason))
    else
      empty_physical_drive_hardware_evidence(:not_sampled)
    end
  end

  defp drive_hardware_evidence_requested?(opts) do
    Keyword.get(opts, :drive_hardware_evidence, Keyword.get(opts, :hardware_evidence, false))
  end

  defp drive_hardware_evidence_sample_opts(opts) do
    []
    |> Keyword.put(:transport, Transport.impl(opts))
    |> maybe_put_keyword(:provider, Keyword.get(opts, :hardware_evidence_provider))
    |> maybe_put_keyword(:now_ms, Keyword.get(opts, :hardware_evidence_now_ms))
    |> maybe_put_keyword(:now_fun, Keyword.get(opts, :hardware_evidence_now_fun))
    |> Keyword.put(:show_raw, false)
  end

  defp empty_physical_drive_hardware_evidence(status) do
    %{
      enabled: status != :not_sampled,
      status: status,
      topology_sets: 0,
      endpoints: 0,
      ok: 0,
      errors: 0,
      destructive_gate?: false,
      drive_hardware_evidence_gate: false,
      samples: []
    }
  end

  defp maybe_put_keyword(opts, _key, nil), do: opts
  defp maybe_put_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  defp empty_physical_probe do
    %{
      buckets: 0,
      physical_bucket_roots: 0,
      physical_version_roots: 0,
      endpoints: 0,
      endpoint_errors: 0,
      physical_residuals: 0,
      bucket_markers: 0,
      examples: []
    }
  end

  defp physical_target_endpoints_from_job(%Job{} = job) do
    case normalize_physical_manifest(job.topology_removal_target_endpoints) do
      {:ok, manifest} ->
        entries = Map.get(manifest, "endpoints", [])

        cond do
          entries == [] ->
            {{:error, :missing_physical_removal_manifest}, manifest, []}

          validate_physical_manifest_targets_job(job, manifest) != :ok ->
            {{:error, :invalid_physical_removal_manifest}, manifest, []}

          true ->
            case decode_physical_endpoints(entries) do
              {:ok, endpoints} -> {:ok, manifest, endpoints}
              {:error, reason} -> {{:error, reason}, manifest, []}
            end
        end

      {:error, reason} ->
        {{:error, reason}, physical_manifest_for_report(job.topology_removal_target_endpoints),
         []}
    end
  end

  defp normalize_physical_manifest(%{} = manifest) do
    with {:ok, endpoints} <-
           manifest
           |> fetch_manifest_value(:endpoints)
           |> normalize_physical_endpoints() do
      {:ok,
       %{}
       |> maybe_put_manifest_value(
         "target_set_id",
         normalize_int(fetch_manifest_value(manifest, :target_set_id))
       )
       |> maybe_put_manifest_value(
         "target_pool_id",
         normalize_int(fetch_manifest_value(manifest, :target_pool_id))
       )
       |> Map.put("endpoints", endpoints)}
    end
  end

  defp normalize_physical_manifest(nil), do: {:ok, %{"endpoints" => []}}

  defp normalize_physical_manifest(_manifest), do: {:error, :invalid_physical_removal_manifest}

  defp normalize_physical_endpoints(nil), do: {:ok, []}

  defp normalize_physical_endpoints(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case normalize_physical_endpoint(entry) do
        {:ok, endpoint} -> {:cont, {:ok, [endpoint | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, endpoints} -> {:ok, Enum.reverse(endpoints)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_physical_endpoints(_entries), do: {:error, :invalid_physical_removal_manifest}

  defp normalize_physical_endpoint(%{} = entry) do
    node = normalize_node_name(fetch_manifest_value(entry, :node))
    drive = fetch_manifest_value(entry, :drive)

    if is_binary(node) and node != "" and is_binary(drive) and drive != "" do
      {:ok,
       %{"node" => node, "drive" => drive}
       |> maybe_put_manifest_value("set_id", normalize_int(fetch_manifest_value(entry, :set_id)))
       |> maybe_put_manifest_value(
         "pool_id",
         normalize_int(fetch_manifest_value(entry, :pool_id))
       )}
    else
      {:error, {:invalid_physical_removal_endpoint, entry}}
    end
  end

  defp normalize_physical_endpoint(entry),
    do: {:error, {:invalid_physical_removal_endpoint, entry}}

  defp physical_manifest_for_report(%{} = manifest), do: manifest
  defp physical_manifest_for_report(_manifest), do: %{"endpoints" => []}

  defp validate_physical_manifest_targets_job(%Job{} = job, %{} = manifest) do
    target_set_id = Map.get(manifest, "target_set_id")
    target_pool_id = Map.get(manifest, "target_pool_id")
    endpoints = Map.get(manifest, "endpoints", [])

    cond do
      target_set_id != job.target_set_id ->
        {:error, :target_set_mismatch}

      not is_integer(target_pool_id) ->
        {:error, :missing_target_pool_id}

      Enum.any?(
        endpoints,
        &invalid_physical_manifest_endpoint?(&1, target_set_id, target_pool_id)
      ) ->
        {:error, :endpoint_target_mismatch}

      true ->
        :ok
    end
  end

  defp invalid_physical_manifest_endpoint?(%{} = endpoint, target_set_id, target_pool_id) do
    Map.get(endpoint, "set_id") != target_set_id or
      Map.get(endpoint, "pool_id") != target_pool_id or
      not is_binary(Map.get(endpoint, "node")) or
      Map.get(endpoint, "node") == "" or
      not is_binary(Map.get(endpoint, "drive")) or
      Map.get(endpoint, "drive") == ""
  end

  defp invalid_physical_manifest_endpoint?(_endpoint, _target_set_id, _target_pool_id), do: true

  defp decode_physical_endpoints(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      with %{"node" => node_name, "drive" => drive} <- entry,
           {:ok, node} <- existing_node_atom(node_name) do
        {:cont, {:ok, [{node, drive} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, {:invalid_physical_removal_endpoint, entry}}}
      end
    end)
    |> case do
      {:ok, endpoints} -> {:ok, Enum.reverse(endpoints)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp existing_node_atom(node_name) when is_binary(node_name) do
    {:ok, String.to_existing_atom(node_name)}
  rescue
    ArgumentError -> {:error, {:unknown_physical_removal_node, node_name}}
  end

  defp existing_node_atom(node_name), do: {:error, {:invalid_physical_removal_node, node_name}}

  defp normalize_node_name(node) when is_atom(node), do: Atom.to_string(node)
  defp normalize_node_name(node) when is_binary(node), do: node
  defp normalize_node_name(_node), do: nil

  defp fetch_manifest_value(%{} = map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp maybe_put_manifest_value(map, _key, nil), do: map
  defp maybe_put_manifest_value(map, key, value), do: Map.put(map, key, value)

  defp normalize_removed_pool_ids(values) when is_list(values) do
    values
    |> Enum.map(&normalize_int/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_removed_pool_ids(_values), do: []

  defp normalize_int(value) when is_integer(value), do: value

  defp normalize_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_int(_value), do: nil

  defp target_endpoint_manifest(topology, set_id) do
    pool_id = Topology.pool_id_for_set_from(topology, set_id)

    %{
      "target_set_id" => set_id,
      "target_pool_id" => pool_id,
      "endpoints" =>
        topology
        |> Topology.endpoints_from(set_id)
        |> Enum.map(fn {node, drive} ->
          %{
            "node" => Atom.to_string(node),
            "drive" => drive,
            "set_id" => set_id,
            "pool_id" => pool_id
          }
        end)
    }
  end

  defp probe_target_set(set_id, topology, opts) do
    topology
    |> Topology.endpoints_from(set_id)
    |> probe_endpoint_roots(opts)
  end

  defp probe_endpoint_roots(endpoints, opts) do
    transport = Transport.impl(opts)
    pg_buckets = Buckets.list() |> Enum.map(& &1.name)

    probe =
      %{
        buckets: length(pg_buckets),
        physical_bucket_roots: 0,
        physical_version_roots: 0,
        endpoints: length(endpoints),
        endpoint_errors: 0,
        physical_residuals: 0,
        bucket_markers: 0,
        examples: []
      }

    {probe, reachable} = probe_endpoints(probe, transport, endpoints)
    {probe, physical_buckets_by_endpoint} = discover_physical_buckets(probe, transport, reachable)
    {probe, version_buckets_by_endpoint} = discover_version_buckets(probe, transport, reachable)
    physical_bucket_roots = count_physical_bucket_roots(physical_buckets_by_endpoint)
    physical_version_roots = count_physical_bucket_roots(version_buckets_by_endpoint)

    probe = %{
      probe
      | physical_bucket_roots: physical_bucket_roots,
        physical_version_roots: physical_version_roots
    }

    pg_bucket_set = MapSet.new(pg_buckets)

    reachable
    |> Enum.reduce(probe, fn {node, drive}, acc ->
      physical_bucket_set = Map.get(physical_buckets_by_endpoint, {node, drive}, MapSet.new())
      version_bucket_set = Map.get(version_buckets_by_endpoint, {node, drive}, MapSet.new())

      scan_buckets =
        physical_bucket_set
        |> MapSet.union(version_bucket_set)
        |> MapSet.union(pg_bucket_set)
        |> MapSet.to_list()

      Enum.reduce(scan_buckets, acc, fn bucket, inner ->
        inner
        |> walk_root(transport, node, drive, bucket, Path.join(drive, bucket), [], :null)
        |> walk_root(
          transport,
          node,
          drive,
          bucket,
          Path.join([drive, ".versions", bucket]),
          [],
          :versions
        )
      end)
    end)
    |> scan_upload_roots(transport, reachable)
  end

  defp discover_physical_buckets(probe, transport, reachable) do
    Enum.reduce(reachable, {probe, %{}}, fn {node, drive}, {acc, bucket_map} ->
      case transport.list_dir(node, drive, include_layout_files: true) do
        {:ok, entries} ->
          buckets =
            entries
            |> Enum.filter(&(entry_type(&1) == :dir))
            |> Enum.reject(&internal_root?(&1.name))
            |> MapSet.new(& &1.name)

          {acc, Map.put(bucket_map, {node, drive}, buckets)}

        {:error, reason} ->
          acc =
            record_endpoint_error(acc, %{
              type: :endpoint_error,
              node: Atom.to_string(node),
              drive: drive,
              layout: :drive_root,
              rel: ".",
              reason: inspect(reason)
            })

          {acc, bucket_map}
      end
    end)
  end

  defp discover_version_buckets(probe, transport, reachable) do
    Enum.reduce(reachable, {probe, %{}}, fn {node, drive}, {acc, bucket_map} ->
      case transport.list_dir(node, Path.join([drive, ".versions"]), include_layout_files: true) do
        {:ok, entries} ->
          buckets =
            entries
            |> Enum.filter(&(entry_type(&1) == :dir))
            |> Enum.reject(&internal_root?(&1.name))
            |> MapSet.new(& &1.name)

          {acc, Map.put(bucket_map, {node, drive}, buckets)}

        {:error, reason} ->
          acc =
            record_endpoint_error(acc, %{
              type: :endpoint_error,
              node: Atom.to_string(node),
              drive: drive,
              layout: :versions_root,
              rel: ".",
              reason: inspect(reason)
            })

          {acc, bucket_map}
      end
    end)
  end

  defp count_physical_bucket_roots(physical_buckets_by_endpoint) do
    physical_buckets_by_endpoint
    |> Map.values()
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    |> MapSet.size()
  end

  defp scan_upload_roots(probe, transport, reachable) do
    Enum.reduce(reachable, probe, fn {node, drive}, acc ->
      walk_root(acc, transport, node, drive, nil, Path.join([drive, ".uploads"]), [], :uploads)
    end)
  end

  defp probe_endpoints(probe, transport, endpoints) do
    Enum.reduce(endpoints, {probe, []}, fn {node, drive}, {acc, reachable} ->
      case transport.probe_drive(node, drive) do
        :ok ->
          {acc, [{node, drive} | reachable]}

        {:error, reason} ->
          acc =
            record_endpoint_error(acc, %{
              type: :endpoint_error,
              node: Atom.to_string(node),
              drive: drive,
              reason: inspect(reason)
            })

          {acc, reachable}
      end
    end)
  end

  defp walk_root(probe, transport, node, drive, bucket, dir, rel, layout) do
    case transport.list_dir(node, dir, include_layout_files: true) do
      {:ok, entries} ->
        files =
          entries
          |> Enum.filter(&(entry_type(&1) == :file))
          |> MapSet.new(& &1.name)

        probe = maybe_count_residual(probe, node, drive, bucket, layout, rel, files)

        entries
        |> Enum.filter(&(entry_type(&1) == :dir))
        |> Enum.reduce(probe, fn entry, acc ->
          walk_root(
            acc,
            transport,
            node,
            drive,
            bucket,
            Path.join(dir, entry.name),
            rel ++ [entry.name],
            layout
          )
        end)

      {:error, reason} ->
        record_endpoint_error(probe, %{
          type: :endpoint_error,
          node: Atom.to_string(node),
          drive: drive,
          bucket: bucket,
          layout: layout,
          rel: rel_path(rel),
          reason: inspect(reason)
        })
    end
  end

  defp maybe_count_residual(probe, node, drive, bucket, :null, [".keep"] = rel, files) do
    cond do
      MapSet.member?(files, "part.0") ->
        count_physical_residual(probe, node, drive, bucket, :null, rel, files)

      MapSet.member?(files, "meta.json") ->
        Map.update!(probe, :bucket_markers, &(&1 + 1))

      true ->
        probe
    end
  end

  defp maybe_count_residual(probe, node, drive, bucket, layout, rel, files) do
    cond do
      MapSet.size(files) == 0 ->
        probe

      MapSet.member?(files, "meta.json") or MapSet.member?(files, "part.0") ->
        count_physical_residual(probe, node, drive, bucket, layout, rel, files)

      true ->
        probe
    end
  end

  defp count_physical_residual(probe, node, drive, bucket, layout, rel, files) do
    probe
    |> Map.update!(:physical_residuals, &(&1 + 1))
    |> add_example(%{
      type: :physical_residual,
      node: Atom.to_string(node),
      drive: drive,
      bucket: example_bucket(layout, bucket, rel),
      layout: layout,
      rel: rel_path(rel),
      files: files |> MapSet.to_list() |> Enum.sort()
    })
  end

  defp record_endpoint_error(probe, example) do
    probe
    |> Map.update!(:endpoint_errors, &(&1 + 1))
    |> add_example(example)
  end

  defp add_example(probe, example) do
    if length(probe.examples) < @example_limit do
      Map.update!(probe, :examples, &[example | &1])
    else
      probe
    end
  end

  defp entry_type(%{type: type}), do: type
  defp entry_type(_entry), do: :dir

  defp internal_root?(name),
    do: name in [".versions", ".uploads", ".tmp", ".maxio-removal-quarantine"]

  defp example_bucket(:uploads, nil, [bucket | _]), do: bucket
  defp example_bucket(_layout, bucket, _rel), do: bucket

  defp rel_path([]), do: "."
  defp rel_path(rel), do: Path.join(rel)

  defp log_report(report) do
    Log.info("rebalance topology mutation preflight complete",
      action: :rebalance_topology_preflight,
      reason:
        "job_id=#{report.job_id} status=#{report.status} target_set_id=#{report.target_set_id} " <>
          "destination_set_id=#{inspect(report.destination_set_id)} removable=#{report.removable} " <>
          "blockers=#{inspect(report.blockers)} pg_placements_remaining=#{report.pg_placements_remaining} " <>
          "missing_placements=#{report.missing_placements} unknown_placements=#{report.unknown_placements} " <>
          "active_multipart_uploads=#{report.active_multipart_uploads} " <>
          "physical_residuals=#{report.physical_residuals} physical_version_roots=#{report.physical_version_roots} " <>
          "endpoint_errors=#{report.endpoint_errors} " <>
          "topology_mutation=false"
    )
  end

  defp log_removal_plan(plan) do
    Log.info("rebalance topology removal plan generated",
      action: :rebalance_topology_plan_removal,
      reason:
        "job_id=#{plan.job_id} removed_set_id=#{plan.removed_set_id} " <>
          "removed_pool_ids=#{inspect(plan.removed_pool_ids)} " <>
          "current_topology_hash=#{plan.current_topology_hash} " <>
          "proposed_topology_hash=#{plan.proposed_topology_hash} topology_mutation=false"
    )
  end

  defp log_apply_report(report) do
    Log.info("rebalance topology removal applied to runtime",
      action: :rebalance_topology_apply_removal,
      reason:
        "job_id=#{report.job_id} apply_scope=#{report.apply_scope} " <>
          "removed_set_id=#{report.removed_set_id} removed_pool_ids=#{inspect(report.removed_pool_ids)} " <>
          "current_topology_hash=#{report.current_topology_hash} " <>
          "proposed_topology_hash=#{report.proposed_topology_hash} " <>
          "deployment_config_mutation=false"
    )
  end

  defp log_cluster_apply_report(report) do
    Log.info("rebalance topology removal applied to cluster runtime",
      action: :rebalance_topology_apply_removal_cluster,
      reason:
        "job_id=#{report.job_id} apply_scope=#{report.apply_scope} " <>
          "removed_set_id=#{report.removed_set_id} removed_pool_ids=#{inspect(report.removed_pool_ids)} " <>
          "current_topology_hash=#{report.current_topology_hash} " <>
          "proposed_topology_hash=#{report.proposed_topology_hash} " <>
          "applied_nodes=#{inspect(report.applied_nodes)} deployment_config_mutation=false"
    )
  end

  defp log_deployment_persist_report(report) do
    Log.info("rebalance topology removal deployment persisted",
      action: :rebalance_topology_persist_removal_deployment,
      reason:
        "job_id=#{report.job_id} removed_set_id=#{report.target_set_id} " <>
          "expected_proposed_hash=#{report.expected_proposed_hash} " <>
          "deployment_topology_hash=#{report.deployment_topology_hash} " <>
          "revision_id=#{report.revision_id} revision_source=#{report.revision_source} " <>
          "deployment_config_mutation=db_active_revision topology_mutation=false"
    )
  end

  defp log_deployment_verification_report(report) do
    Log.info("rebalance topology removal deployment verified",
      action: :rebalance_topology_verify_removal_deployment,
      reason:
        "job_id=#{report.job_id} removed_set_id=#{report.target_set_id} " <>
          "expected_proposed_hash=#{report.expected_proposed_hash} " <>
          "deployment_topology_hash=#{report.deployment_topology_hash} " <>
          "deployment_set_ids=#{inspect(report.deployment_set_ids)} " <>
          "deployment_pool_ids=#{inspect(report.deployment_pool_ids)} " <>
          "write_routing_retired=#{report.write_routing_retired} " <>
          "topology_mutation=false deployment_config_mutation=false"
    )
  end

  defp log_physical_removal_preflight_report(report) do
    Log.info("rebalance physical removal preflight complete",
      action: :rebalance_physical_removal_preflight,
      reason:
        "job_id=#{report.job_id} status=#{report.status} target_set_id=#{report.target_set_id} " <>
          "blockers=#{inspect(report.blockers)} endpoints=#{report.endpoints} " <>
          "endpoint_errors=#{report.endpoint_errors} physical_residuals=#{report.physical_residuals} " <>
          "physical_bucket_roots=#{report.physical_bucket_roots} " <>
          "physical_version_roots=#{report.physical_version_roots} " <>
          "drive_hardware_evidence_status=#{report.drive_hardware_evidence_status} " <>
          "drive_hardware_evidence_ok=#{report.drive_hardware_evidence.ok} " <>
          "drive_hardware_evidence_errors=#{report.drive_hardware_evidence_errors} " <>
          "drive_hardware_evidence_gate=false physical_removal=false"
    )
  end

  defp lock_opts(opts), do: Keyword.get(opts, :lock_opts, [])

  defp current_topology do
    set_ids = Topology.all_set_ids()
    pool_ids = Topology.pool_ids()

    %{
      data_shards: Keyword.fetch!(Topology.ec_params(), :data_shards),
      parity_shards: Keyword.fetch!(Topology.ec_params(), :parity_shards),
      block_size: Keyword.fetch!(Topology.ec_params(), :block_size),
      allow_colocated_endpoints: Topology.allow_colocated_endpoints?(),
      pool_ids: pool_ids,
      pools:
        Map.new(pool_ids, fn pool_id ->
          {pool_id, %{id: pool_id, set_ids: Topology.set_ids_for_pool(pool_id)}}
        end),
      set_ids: set_ids,
      sets:
        Map.new(set_ids, fn set_id ->
          {set_id,
           %{
             id: set_id,
             pool_id: Topology.pool_id_for_set(set_id),
             endpoints: Topology.endpoints(set_id)
           }}
        end)
    }
  end
end
