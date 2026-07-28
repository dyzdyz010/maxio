defmodule Maxio.Cluster.Rebalance.PhysicalPurge do
  @moduledoc """
  Retention-gated hard delete of already quarantined Maxio layout roots.

  This is the destructive follow-up to `PhysicalRemoval`: it deletes only the
  same-drive `.maxio-removal-quarantine/<id>` roots after an explicit retention
  gate. It does not delete whole drive roots, mutate topology, rewrite
  deployment config, or run from the scheduler.
  """

  alias Maxio.Cluster.{Lock, Topology, Transport}
  alias Maxio.Cluster.Rebalance.{Job, Jobs, SecureEraseEvidence, TopologyMutation}
  alias Maxio.S3.Log

  @default_retention_seconds 7 * 24 * 60 * 60

  @type preflight_report :: %{
          status: :ready | :blocked | :already_purged,
          job_id: String.t(),
          job_kind: String.t() | nil,
          target_set_id: non_neg_integer() | nil,
          quarantine_id: String.t() | nil,
          manifest_hash: String.t() | nil,
          retention_seconds: non_neg_integer(),
          retention_until: DateTime.t() | nil,
          retention_elapsed?: boolean(),
          blockers: [term()],
          endpoint_results: [map()],
          physical_removal_preflight: map() | nil,
          secure_erase_evidence: map(),
          purge: false
        }

  @type report :: %{
          status: :purged | :already_purged,
          job_id: String.t(),
          physical_removal: :quarantine_hard_delete,
          topology_mutation: false,
          deployment_config_mutation: false,
          quarantine_id: String.t(),
          manifest_hash: String.t(),
          roots_deleted: non_neg_integer(),
          files_deleted: non_neg_integer(),
          dirs_deleted: non_neg_integer(),
          bytes_deleted: non_neg_integer(),
          markers_written: non_neg_integer(),
          errors: non_neg_integer(),
          secure_erase_evidence: map(),
          preflight: preflight_report(),
          results: map(),
          job: map()
        }

  @doc "Read-only purge readiness check. This never deletes files."
  @spec preflight(String.t(), keyword()) :: {:ok, preflight_report()} | {:error, term()}
  def preflight(job_id, opts \\ []) when is_binary(job_id) do
    with {:ok, job} <- Jobs.get(job_id) do
      build_preflight(job, opts)
    end
  end

  @doc """
  Hard-delete a quarantined layout after the retention gate.

  Callers must pass both `confirm_job_id: job_id` and
  `confirm_quarantine_id: job.physical_removal_quarantine_id`.
  """
  @spec apply(String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def apply(job_id, opts \\ []) when is_binary(job_id) do
    with :ok <- ensure_confirmed(job_id, opts) do
      case Lock.quorum_with_lock(
             Topology.runtime_mutation_lock_resource(),
             fn -> apply_locked(job_id, opts) end,
             lock_opts(opts)
           ) do
        {:ok, result} ->
          result

        {:error, :no_quorum} ->
          Log.error("rebalance physical purge lock unavailable",
            action: :rebalance_physical_purge,
            reason:
              "job_id=#{job_id} resource=#{inspect(Topology.runtime_mutation_lock_resource())}"
          )

          {:error, :physical_purge_locked}
      end
    end
  end

  defp apply_locked(job_id, opts) do
    with {:ok, preflight} <- preflight(job_id, opts),
         :ok <- ensure_preflight_ready(preflight),
         {:ok, job} <- Jobs.get(job_id) do
      if job.physical_removal_purge_status == "purged" do
        {:ok, build_already_purged_report(job, preflight)}
      else
        begin_and_purge(job, preflight, opts)
      end
    end
  end

  defp begin_and_purge(%Job{} = job, preflight, opts) do
    now = now(opts)

    with {:ok, begun} <-
           Jobs.begin_physical_removal_purge(
             job,
             %{
               quarantine_id: job.physical_removal_quarantine_id,
               manifest_hash: job.physical_removal_manifest_hash,
               retention_seconds: preflight.retention_seconds,
               retention_until: preflight.retention_until,
               preflight_verified_at: now,
               results: initial_results(job, preflight)
             },
             opts
           ) do
      if begun.physical_removal_purge_status == "purged" do
        {:ok, build_already_purged_report(begun, preflight)}
      else
        purge_and_record(begun, preflight, opts)
      end
    end
  end

  defp purge_and_record(%Job{} = job, preflight, opts) do
    transport = Transport.impl(opts)
    marker = marker(job, preflight)

    case purge_endpoints(preflight, transport, marker) do
      {:ok, results} ->
        with {:ok, updated} <-
               Jobs.complete_physical_removal_purge(
                 job,
                 %{
                   quarantine_id: job.physical_removal_quarantine_id,
                   manifest_hash: job.physical_removal_manifest_hash,
                   results: results
                 },
                 opts
               ) do
          report = build_report(:purged, updated, preflight, results)
          log_report(report)
          {:ok, report}
        end

      {:error, reason, results} ->
        {:ok, failed} = Jobs.fail_physical_removal_purge(job, reason, results, opts)
        report = build_report(:failed, failed, preflight, results)
        log_failure(report, reason)
        {:error, {:physical_purge_failed, report}}
    end
  end

  defp build_preflight(%Job{} = job, opts) do
    retention_seconds = retention_seconds(opts)
    retention_until = retention_until(job, retention_seconds)
    now = now(opts)
    retention_elapsed? = retention_elapsed?(retention_until, now)
    already_purged? = job.physical_removal_purge_status == "purged"

    physical_preflight =
      case TopologyMutation.physical_removal_preflight(job.id, opts) do
        {:ok, report} -> report
        {:error, reason} -> %{status: :blocked, blockers: [{:physical_preflight_error, reason}]}
      end

    base_blockers =
      []
      |> maybe_block(job.kind != "decommission", {:unsupported_job_kind, job.kind})
      |> maybe_block(
        job.physical_removal_status != "quarantined",
        :physical_removal_not_quarantined
      )
      |> maybe_block(blank?(job.physical_removal_quarantine_id), :missing_quarantine_id)
      |> maybe_block(blank?(job.physical_removal_manifest_hash), :missing_manifest_hash)
      |> maybe_block(not already_purged? and not retention_elapsed?, :retention_not_elapsed)

    physical_blockers =
      if Map.get(physical_preflight, :status) == :ready do
        []
      else
        [:physical_removal_preflight_blocked | List.wrap(Map.get(physical_preflight, :blockers))]
      end

    {secure_erase_blockers, secure_erase_evidence} =
      secure_erase_evidence(job, physical_preflight, opts)

    {endpoint_blockers, endpoint_results} =
      if base_blockers == [] and physical_blockers == [] do
        endpoint_preflight(
          job,
          physical_preflight,
          Transport.impl(opts),
          marker(job, physical_preflight)
        )
      else
        {[], []}
      end

    blockers = base_blockers ++ physical_blockers ++ secure_erase_blockers ++ endpoint_blockers

    status =
      cond do
        already_purged? and blockers == [] -> :already_purged
        blockers == [] -> :ready
        true -> :blocked
      end

    report = %{
      status: status,
      job_id: job.id,
      job_kind: job.kind,
      target_set_id: job.target_set_id,
      quarantine_id: job.physical_removal_quarantine_id,
      manifest_hash: job.physical_removal_manifest_hash,
      retention_seconds: retention_seconds,
      retention_until: retention_until,
      retention_elapsed?: retention_elapsed?,
      blockers: blockers,
      endpoint_results: endpoint_results,
      physical_removal_preflight: physical_preflight,
      secure_erase_evidence: secure_erase_evidence,
      purge: false
    }

    log_preflight(report)
    {:ok, report}
  end

  defp endpoint_preflight(%Job{} = job, preflight, transport, marker) do
    preflight.target_endpoints
    |> decode_endpoints!()
    |> Enum.reduce_while({[], []}, fn {node, drive}, {blockers, results} ->
      case safe_transport_call(fn ->
             transport.preflight_quarantine_purge_root(
               node,
               drive,
               job.physical_removal_quarantine_id,
               marker
             )
           end) do
        {:ok, result} ->
          endpoint_result =
            result
            |> json_ready()
            |> Map.merge(%{"node" => Atom.to_string(node), "drive" => drive, "status" => "ok"})

          {:cont, {blockers, [endpoint_result | results]}}

        {:error, reason} ->
          endpoint_result = %{
            "node" => Atom.to_string(node),
            "drive" => drive,
            "status" => "error",
            "reason" => inspect(reason)
          }

          {:halt, {[:quarantine_purge_endpoint_blocked], [endpoint_result | results]}}
      end
    end)
    |> then(fn {blockers, results} -> {Enum.reverse(blockers), Enum.reverse(results)} end)
  end

  defp purge_endpoints(preflight, transport, marker) do
    preflight.physical_removal_preflight.target_endpoints
    |> decode_endpoints!()
    |> Enum.reduce_while({:ok, []}, fn {node, drive}, {:ok, acc} ->
      case safe_transport_call(fn ->
             transport.purge_quarantine_root(node, drive, preflight.quarantine_id, marker)
           end) do
        {:ok, result} ->
          endpoint_result =
            result
            |> json_ready()
            |> Map.merge(%{"node" => Atom.to_string(node), "drive" => drive, "status" => "ok"})

          {:cont, {:ok, [endpoint_result | acc]}}

        {:error, reason} ->
          endpoint_result = %{
            "node" => Atom.to_string(node),
            "drive" => drive,
            "status" => "error",
            "reason" => inspect(reason),
            "roots_deleted" => 0,
            "files_deleted" => 0,
            "dirs_deleted" => 0,
            "bytes_deleted" => 0,
            "marker_written" => false
          }

          {:halt, {:error, reason, Enum.reverse([endpoint_result | acc])}}
      end
    end)
    |> case do
      {:ok, endpoints} -> {:ok, results(marker, Enum.reverse(endpoints), preflight)}
      {:error, reason, endpoints} -> {:error, reason, results(marker, endpoints, preflight)}
    end
  end

  defp safe_transport_call(fun) do
    fun.()
  catch
    kind, reason -> {:error, {:transport_callback_failed, kind, reason}}
  end

  defp ensure_confirmed(job_id, opts) do
    confirm_job_id = Keyword.get(opts, :confirm_job_id)
    confirm_quarantine_id = Keyword.get(opts, :confirm_quarantine_id)

    with {:ok, job} <- Jobs.get(job_id) do
      cond do
        confirm_job_id != job_id ->
          {:error, :physical_purge_job_confirmation_required}

        confirm_quarantine_id != job.physical_removal_quarantine_id ->
          {:error, :physical_purge_quarantine_confirmation_required}

        true ->
          :ok
      end
    end
  end

  defp ensure_preflight_ready(%{status: status}) when status in [:ready, :already_purged], do: :ok

  defp ensure_preflight_ready(%{} = report),
    do: {:error, {:physical_purge_preflight_blocked, report}}

  defp retention_seconds(opts) do
    cond do
      Keyword.has_key?(opts, :retention_seconds) ->
        opts |> Keyword.fetch!(:retention_seconds) |> max(0)

      Keyword.has_key?(opts, :retention_hours) ->
        opts |> Keyword.fetch!(:retention_hours) |> max(0) |> Kernel.*(60 * 60)

      true ->
        @default_retention_seconds
    end
  end

  defp retention_until(%Job{physical_removal_completed_at: nil}, _retention_seconds), do: nil

  defp retention_until(%Job{physical_removal_completed_at: completed_at}, retention_seconds),
    do: DateTime.add(completed_at, retention_seconds, :second)

  defp retention_elapsed?(nil, _now), do: false
  defp retention_elapsed?(retention_until, now), do: DateTime.compare(now, retention_until) != :lt

  defp marker(%Job{} = job, _preflight) do
    %{
      "job_id" => job.id,
      "job_kind" => job.kind,
      "target_set_id" => job.target_set_id,
      "destination_set_id" => job.destination_set_id,
      "quarantine_id" => job.physical_removal_quarantine_id,
      "manifest_hash" => job.physical_removal_manifest_hash,
      "physical_removal_completed_at" => iso8601(job.physical_removal_completed_at)
    }
  end

  defp initial_results(%Job{} = job, preflight) do
    %{
      "status" => "purging",
      "quarantine_id" => job.physical_removal_quarantine_id,
      "manifest_hash" => job.physical_removal_manifest_hash,
      "retention_seconds" => preflight.retention_seconds,
      "retention_until" => iso8601(preflight.retention_until),
      "secure_erase_evidence" => preflight.secure_erase_evidence,
      "endpoints" => preflight.endpoint_results
    }
  end

  defp results(marker, endpoints, preflight) do
    %{
      "status" => if(Enum.all?(endpoints, &(&1["status"] == "ok")), do: "ok", else: "error"),
      "quarantine_id" => marker["quarantine_id"],
      "manifest_hash" => marker["manifest_hash"],
      "secure_erase_evidence" => preflight.secure_erase_evidence,
      "endpoints" => endpoints
    }
  end

  defp build_already_purged_report(job, preflight) do
    build_report(
      :already_purged,
      job,
      preflight,
      job.physical_removal_purge_results || %{}
    )
  end

  defp build_report(status, job, preflight, results) do
    summary = summarize_results(results)

    %{
      status: status,
      job_id: job.id,
      physical_removal: :quarantine_hard_delete,
      topology_mutation: false,
      deployment_config_mutation: false,
      quarantine_id: job.physical_removal_quarantine_id,
      manifest_hash: job.physical_removal_manifest_hash,
      roots_deleted: summary.roots_deleted,
      files_deleted: summary.files_deleted,
      dirs_deleted: summary.dirs_deleted,
      bytes_deleted: summary.bytes_deleted,
      markers_written: summary.markers_written,
      errors: summary.errors,
      secure_erase_evidence: secure_erase_evidence_from_results(results, preflight),
      preflight: preflight,
      results: results,
      job: Jobs.to_view(job)
    }
  end

  defp summarize_results(results) when is_map(results) do
    endpoints = Map.get(results, "endpoints") || Map.get(results, :endpoints) || []

    Enum.reduce(
      endpoints,
      %{
        roots_deleted: 0,
        files_deleted: 0,
        dirs_deleted: 0,
        bytes_deleted: 0,
        markers_written: 0,
        errors: 0
      },
      fn endpoint, acc ->
        marker_written? =
          Map.get(endpoint, "marker_written") || Map.get(endpoint, :marker_written)

        status = Map.get(endpoint, "status") || Map.get(endpoint, :status)

        %{
          roots_deleted: acc.roots_deleted + integer_value(endpoint, "roots_deleted"),
          files_deleted: acc.files_deleted + integer_value(endpoint, "files_deleted"),
          dirs_deleted: acc.dirs_deleted + integer_value(endpoint, "dirs_deleted"),
          bytes_deleted: acc.bytes_deleted + integer_value(endpoint, "bytes_deleted"),
          markers_written: acc.markers_written + if(marker_written?, do: 1, else: 0),
          errors: acc.errors + if(status in ["error", :error], do: 1, else: 0)
        }
      end
    )
  end

  defp summarize_results(_results),
    do: %{
      roots_deleted: 0,
      files_deleted: 0,
      dirs_deleted: 0,
      bytes_deleted: 0,
      markers_written: 0,
      errors: 0
    }

  defp secure_erase_evidence(job, physical_preflight, opts) do
    preflight_context = %{
      quarantine_id: job.physical_removal_quarantine_id,
      manifest_hash: job.physical_removal_manifest_hash,
      physical_removal_preflight: physical_preflight
    }

    case SecureEraseEvidence.prepare(job, preflight_context, opts) do
      {:ok, evidence} ->
        {[], evidence}

      {:error, reason, evidence} ->
        {[{:secure_erase_evidence_invalid, reason}], evidence}
    end
  end

  defp secure_erase_evidence_from_results(results, preflight) when is_map(results) do
    case Map.get(results, "secure_erase_evidence") || Map.get(results, :secure_erase_evidence) do
      %{} = evidence -> evidence
      _other -> Map.get(preflight, :secure_erase_evidence, default_secure_erase_evidence())
    end
  end

  defp secure_erase_evidence_from_results(_results, preflight),
    do: Map.get(preflight, :secure_erase_evidence, default_secure_erase_evidence())

  defp default_secure_erase_evidence do
    %{
      "enabled" => false,
      "required" => false,
      "status" => "not_collected",
      "secure_erase_gate" => false,
      "destructive_gate?" => false,
      "endpoints" => 0,
      "errors" => [],
      "samples" => []
    }
  end

  defp integer_value(%{} = map, key) do
    value = Map.get(map, key, Map.get(map, atom_counter_key(key), 0))
    if is_integer(value), do: value, else: 0
  end

  defp atom_counter_key("roots_deleted"), do: :roots_deleted
  defp atom_counter_key("files_deleted"), do: :files_deleted
  defp atom_counter_key("dirs_deleted"), do: :dirs_deleted
  defp atom_counter_key("bytes_deleted"), do: :bytes_deleted
  defp atom_counter_key(_key), do: nil

  defp decode_endpoints!(%{} = manifest) do
    manifest
    |> Map.get("endpoints", Map.get(manifest, :endpoints, []))
    |> Enum.map(fn %{} = endpoint ->
      node_name = Map.get(endpoint, "node", Map.get(endpoint, :node))
      drive = Map.get(endpoint, "drive", Map.get(endpoint, :drive))
      {String.to_existing_atom(node_name), drive}
    end)
  end

  defp maybe_block(blockers, true, blocker), do: [blocker | blockers]
  defp maybe_block(blockers, false, _blocker), do: blockers

  defp blank?(value), do: is_nil(value) or value == ""
  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_ready()
  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)

  defp json_ready(%{} = value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)

  defp json_ready(value), do: value

  defp log_preflight(report) do
    Log.info("rebalance physical purge preflight",
      action: :rebalance_physical_purge_preflight,
      reason:
        "job_id=#{report.job_id} status=#{report.status} blockers=#{inspect(report.blockers)} " <>
          "quarantine_id=#{report.quarantine_id} retention_elapsed?=#{report.retention_elapsed?} " <>
          "secure_erase_evidence_status=#{report.secure_erase_evidence["status"]} purge=false"
    )
  end

  defp log_report(report) do
    Log.info("rebalance physical purge complete",
      action: :rebalance_physical_purge,
      reason:
        "job_id=#{report.job_id} status=#{report.status} quarantine_id=#{report.quarantine_id} " <>
          "roots_deleted=#{report.roots_deleted} files_deleted=#{report.files_deleted} " <>
          "dirs_deleted=#{report.dirs_deleted} bytes_deleted=#{report.bytes_deleted} " <>
          "secure_erase_evidence_status=#{report.secure_erase_evidence["status"]} " <>
          "physical_removal=quarantine_hard_delete topology_mutation=false deployment_config_mutation=false"
    )
  end

  defp log_failure(report, reason) do
    Log.error("rebalance physical purge failed",
      action: :rebalance_physical_purge,
      reason:
        "job_id=#{report.job_id} quarantine_id=#{report.quarantine_id} " <>
          "errors=#{report.errors} reason=#{inspect(reason)}"
    )
  end

  defp lock_opts(opts), do: Keyword.get(opts, :lock_opts, [])

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      _other -> DateTime.utc_now()
    end
  end
end
