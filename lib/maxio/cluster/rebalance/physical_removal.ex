defmodule Maxio.Cluster.Rebalance.PhysicalRemoval do
  @moduledoc """
  Operator-gated physical layout quarantine for verified decommission jobs.

  This moves only Maxio-owned layout roots on the stored target endpoint
  manifest into a same-drive quarantine. It does not delete whole drives, hard
  delete quarantine contents, mutate topology, rewrite deployment config, or run
  from the scheduler.
  """

  alias Maxio.Buckets
  alias Maxio.Cluster.{Lock, Topology, Transport}
  alias Maxio.Cluster.Rebalance.{Job, Jobs, TopologyMutation}
  alias Maxio.S3.Log

  @type report :: %{
          status: :quarantined | :already_quarantined,
          job_id: String.t(),
          job_kind: String.t(),
          target_set_id: non_neg_integer(),
          destination_set_id: non_neg_integer() | nil,
          topology_mutation: false,
          deployment_config_mutation: false,
          physical_removal: :layout_quarantine,
          quarantine_id: String.t(),
          manifest_hash: String.t(),
          endpoints: non_neg_integer(),
          roots_quarantined: non_neg_integer(),
          markers_written: non_neg_integer(),
          errors: non_neg_integer(),
          preflight: map(),
          postflight: map() | nil,
          results: map(),
          drive_hardware_evidence: map(),
          job: map()
        }

  @doc """
  Quarantine Maxio layout roots for one verified decommission job.

  Callers must pass `confirm_job_id: job_id`. There is intentionally no "latest
  job" fallback for this operation.
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
          Log.error("rebalance physical removal lock unavailable",
            action: :rebalance_physical_remove,
            reason:
              "job_id=#{job_id} resource=#{inspect(Topology.runtime_mutation_lock_resource())}"
          )

          {:error, :physical_removal_locked}
      end
    end
  end

  defp apply_locked(job_id, opts) do
    with {:ok, preflight} <- TopologyMutation.physical_removal_preflight(job_id, opts),
         :ok <- ensure_preflight_ready(preflight),
         {:ok, job} <- Jobs.get(job_id),
         manifest_hash <- manifest_hash(job),
         quarantine_id <- quarantine_id(job, opts),
         now <- now(opts),
         {:ok, begun} <-
           Jobs.begin_physical_removal(
             job,
             %{
               quarantine_id: quarantine_id,
               manifest_hash: manifest_hash,
               preflight_verified_at: now,
               results: initial_results(preflight, quarantine_id, manifest_hash)
             },
             opts
           ) do
      if begun.physical_removal_status == "quarantined" do
        with {:ok, begun} <-
               maybe_attach_already_quarantined_hardware_evidence(
                 begun,
                 preflight,
                 manifest_hash,
                 opts
               ) do
          {:ok, build_already_quarantined_report(begun, preflight)}
        end
      else
        quarantine_and_record(begun, preflight, manifest_hash, opts)
      end
    end
  end

  defp quarantine_and_record(%Job{} = job, preflight, manifest_hash, opts) do
    bucket_names = Buckets.list() |> Enum.map(& &1.name)
    transport = Transport.impl(opts)
    marker = marker(job, preflight, manifest_hash)

    case quarantine_endpoints(preflight, transport, bucket_names, marker) do
      {:ok, results} ->
        complete_after_postflight(job, preflight, manifest_hash, results, opts)

      {:error, reason, results} ->
        fail_and_return(job, reason, results, preflight, nil, manifest_hash, opts)
    end
  end

  defp complete_after_postflight(job, preflight, manifest_hash, results, opts) do
    case TopologyMutation.physical_removal_preflight(job.id, opts) do
      {:ok, %{status: :ready} = postflight} ->
        with {:ok, updated} <-
               Jobs.complete_physical_removal(
                 job,
                 %{manifest_hash: manifest_hash, results: results},
                 opts
               ) do
          report = build_report(:quarantined, updated, preflight, postflight, results)
          log_report(report)
          {:ok, report}
        end

      {:ok, postflight} ->
        fail_and_return(
          job,
          {:postflight_blocked, postflight.blockers},
          results,
          preflight,
          postflight,
          manifest_hash,
          opts
        )

      {:error, reason} ->
        fail_and_return(
          job,
          {:postflight_failed, reason},
          results,
          preflight,
          nil,
          manifest_hash,
          opts
        )
    end
  end

  defp fail_and_return(job, reason, results, preflight, postflight, _manifest_hash, opts) do
    {:ok, failed} = Jobs.fail_physical_removal(job, reason, results, opts)
    report = build_report(:failed, failed, preflight, postflight, results)
    log_failure(report, reason)
    {:error, {:physical_removal_failed, report}}
  end

  defp quarantine_endpoints(preflight, transport, bucket_names, marker) do
    endpoints = decode_endpoints!(preflight.target_endpoints)

    Enum.reduce_while(endpoints, {:ok, []}, fn {node, drive}, {:ok, acc} ->
      case transport.quarantine_layout_roots(
             node,
             drive,
             bucket_names,
             marker["quarantine_id"],
             marker
           ) do
        {:ok, result} ->
          endpoint_result =
            result
            |> json_ready()
            |> Map.merge(%{
              "node" => Atom.to_string(node),
              "drive" => drive,
              "status" => "ok"
            })

          {:cont, {:ok, [endpoint_result | acc]}}

        {:error, reason} ->
          endpoint_result = %{
            "node" => Atom.to_string(node),
            "drive" => drive,
            "status" => "error",
            "reason" => inspect(reason),
            "roots" => [],
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

  defp ensure_confirmed(job_id, opts) do
    if Keyword.get(opts, :confirm_job_id) == job_id do
      :ok
    else
      {:error, :physical_removal_confirmation_required}
    end
  end

  defp ensure_preflight_ready(%{status: :ready}), do: :ok

  defp ensure_preflight_ready(%{} = report),
    do: {:error, {:physical_removal_preflight_blocked, report}}

  defp decode_endpoints!(%{} = manifest) do
    manifest
    |> Map.get("endpoints", Map.get(manifest, :endpoints, []))
    |> Enum.map(fn %{} = endpoint ->
      node_name = Map.get(endpoint, "node", Map.get(endpoint, :node))
      drive = Map.get(endpoint, "drive", Map.get(endpoint, :drive))
      {String.to_existing_atom(node_name), drive}
    end)
  end

  defp quarantine_id(%Job{physical_removal_quarantine_id: id}, _opts)
       when is_binary(id) and id != "",
       do: id

  defp quarantine_id(_job, opts) do
    Keyword.get_lazy(opts, :quarantine_id, fn ->
      Ecto.UUID.generate()
    end)
  end

  defp marker(%Job{} = job, preflight, manifest_hash) do
    %{
      "job_id" => job.id,
      "job_kind" => job.kind,
      "target_set_id" => job.target_set_id,
      "destination_set_id" => job.destination_set_id,
      "topology_removal_proposed_hash" => job.topology_removal_proposed_hash,
      "topology_removal_cluster_hash" => job.topology_removal_cluster_hash,
      "topology_removal_deployment_hash" => job.topology_removal_deployment_hash,
      "manifest_hash" => manifest_hash,
      "quarantine_id" => quarantine_id(job, []),
      "removed_pool_ids" => preflight.removed_pool_ids
    }
  end

  defp initial_results(preflight, quarantine_id, manifest_hash) do
    %{
      "status" => "quarantining",
      "quarantine_id" => quarantine_id,
      "manifest_hash" => manifest_hash,
      "endpoints" => [],
      "target_endpoints" => json_ready(preflight.target_endpoints),
      "drive_hardware_evidence" => drive_hardware_evidence(preflight)
    }
  end

  defp results(marker, endpoints, preflight) do
    %{
      "status" => if(Enum.all?(endpoints, &(&1["status"] == "ok")), do: "ok", else: "error"),
      "quarantine_id" => marker["quarantine_id"],
      "manifest_hash" => marker["manifest_hash"],
      "drive_hardware_evidence" => drive_hardware_evidence(preflight),
      "endpoints" => endpoints
    }
  end

  defp build_already_quarantined_report(job, preflight) do
    build_report(
      :already_quarantined,
      job,
      preflight,
      preflight,
      job.physical_removal_results || %{}
    )
  end

  defp maybe_attach_already_quarantined_hardware_evidence(
         %Job{} = job,
         preflight,
         manifest_hash,
         opts
       ) do
    if refresh_hardware_evidence_on_idempotent_run?(job.physical_removal_results, preflight) do
      results =
        job.physical_removal_results
        |> case do
          %{} = results -> json_ready(results)
          _other -> %{}
        end
        |> Map.put("drive_hardware_evidence", drive_hardware_evidence(preflight))

      Jobs.update_physical_removal_results(
        job,
        %{manifest_hash: manifest_hash, results: results},
        opts
      )
    else
      {:ok, job}
    end
  end

  defp refresh_hardware_evidence_on_idempotent_run?(results, preflight) do
    preflight_evidence = Map.get(preflight, :drive_hardware_evidence, %{})

    preflight_evidence_enabled?(preflight_evidence) and
      existing_hardware_evidence_status(results) in [nil, "not_sampled", "not_collected"]
  end

  defp preflight_evidence_enabled?(%{} = evidence) do
    Map.get(evidence, :enabled, Map.get(evidence, "enabled", false)) == true and
      Map.get(evidence, :status, Map.get(evidence, "status")) not in [
        nil,
        :not_sampled,
        "not_sampled",
        :not_collected,
        "not_collected"
      ]
  end

  defp preflight_evidence_enabled?(_evidence), do: false

  defp existing_hardware_evidence_status(results) when is_map(results) do
    evidence =
      Map.get(results, "drive_hardware_evidence") ||
        Map.get(results, :drive_hardware_evidence) ||
        %{}

    case evidence do
      %{} -> Map.get(evidence, "status", Map.get(evidence, :status))
      _other -> nil
    end
  end

  defp existing_hardware_evidence_status(_results), do: nil

  defp build_report(status, job, preflight, postflight, results) do
    results = sanitize_physical_removal_results(results)
    summary = summarize_results(results)

    %{
      status: status,
      job_id: job.id,
      job_kind: job.kind,
      target_set_id: job.target_set_id,
      destination_set_id: job.destination_set_id,
      topology_mutation: false,
      deployment_config_mutation: false,
      physical_removal: :layout_quarantine,
      quarantine_id: job.physical_removal_quarantine_id,
      manifest_hash: job.physical_removal_manifest_hash,
      endpoints: preflight.endpoints,
      roots_quarantined: summary.roots_quarantined,
      markers_written: summary.markers_written,
      errors: summary.errors,
      preflight: preflight,
      postflight: postflight,
      results: results,
      drive_hardware_evidence: drive_hardware_evidence_from_results(results, preflight),
      job: Jobs.to_view(job)
    }
  end

  defp summarize_results(results) when is_map(results) do
    endpoints = Map.get(results, "endpoints") || Map.get(results, :endpoints) || []

    Enum.reduce(endpoints, %{roots_quarantined: 0, markers_written: 0, errors: 0}, fn endpoint,
                                                                                      acc ->
      roots = Map.get(endpoint, "roots") || Map.get(endpoint, :roots) || []
      roots = if is_list(roots), do: roots, else: []
      marker_written? = Map.get(endpoint, "marker_written") || Map.get(endpoint, :marker_written)
      status = Map.get(endpoint, "status") || Map.get(endpoint, :status)

      %{
        roots_quarantined: acc.roots_quarantined + length(roots),
        markers_written: acc.markers_written + if(marker_written?, do: 1, else: 0),
        errors: acc.errors + if(status in ["error", :error], do: 1, else: 0)
      }
    end)
  end

  defp summarize_results(_results), do: %{roots_quarantined: 0, markers_written: 0, errors: 0}

  defp drive_hardware_evidence_from_results(results, preflight) when is_map(results) do
    case Map.get(results, "drive_hardware_evidence") || Map.get(results, :drive_hardware_evidence) do
      nil -> drive_hardware_evidence(preflight)
      evidence -> sanitize_physical_removal_results(evidence)
    end
  end

  defp drive_hardware_evidence_from_results(_results, preflight),
    do: drive_hardware_evidence(preflight)

  defp drive_hardware_evidence(%{} = preflight) do
    preflight
    |> Map.get(:drive_hardware_evidence, default_drive_hardware_evidence())
    |> sanitize_physical_removal_results()
  end

  defp drive_hardware_evidence(_preflight), do: default_drive_hardware_evidence()

  defp default_drive_hardware_evidence do
    %{
      "enabled" => false,
      "status" => "not_sampled",
      "topology_sets" => 0,
      "endpoints" => 0,
      "ok" => 0,
      "errors" => 0,
      "destructive_gate?" => false,
      "drive_hardware_evidence_gate" => false,
      "samples" => []
    }
  end

  defp sanitize_physical_removal_results(%{} = value) do
    value
    |> Enum.reject(fn {key, _item} -> raw_hardware_key?(key) end)
    |> Map.new(fn {key, item} ->
      key = to_string(key)
      {key, sanitize_physical_removal_result_value(key, item)}
    end)
  end

  defp sanitize_physical_removal_results(value) when is_list(value),
    do: Enum.map(value, &sanitize_physical_removal_results/1)

  defp sanitize_physical_removal_results(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> sanitize_physical_removal_results()

  defp sanitize_physical_removal_results(value) when is_boolean(value) or is_nil(value),
    do: value

  defp sanitize_physical_removal_results(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_physical_removal_results(value), do: value

  defp sanitize_physical_removal_result_value(key, value)
       when key in ["serial_hash", "wwid_hash"],
       do: safe_hardware_hash(value)

  defp sanitize_physical_removal_result_value(_key, value),
    do: sanitize_physical_removal_results(value)

  defp raw_hardware_key?(key) when key in [:serial, :wwid, "serial", "wwid"], do: true
  defp raw_hardware_key?(_key), do: false

  defp safe_hardware_hash(value) when is_binary(value) and value != "" do
    normalized = String.downcase(value)

    if String.match?(normalized, ~r/\A[0-9a-f]{64}\z/) do
      normalized
    else
      :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
    end
  end

  defp safe_hardware_hash(value), do: sanitize_physical_removal_results(value)

  defp manifest_hash(%Job{} = job) do
    payload =
      canonicalize(%{
        "topology_removal_target_endpoints" => job.topology_removal_target_endpoints || %{},
        "topology_removal_removed_pool_ids" =>
          (job.topology_removal_removed_pool_ids || []) |> Enum.sort(),
        "topology_removal_proposed_hash" => job.topology_removal_proposed_hash
      })

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
  end

  defp canonicalize(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonicalize(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonicalize(values) when is_list(values), do: Enum.map(values, &canonicalize/1)
  defp canonicalize(value), do: value

  defp json_ready(value) when is_boolean(value) or is_nil(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_ready()
  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)

  defp json_ready(%{} = value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)

  defp json_ready(value), do: value

  defp log_report(report) do
    evidence = report.drive_hardware_evidence

    Log.info("rebalance physical removal quarantine complete",
      action: :rebalance_physical_remove,
      reason:
        "job_id=#{report.job_id} status=#{report.status} target_set_id=#{report.target_set_id} " <>
          "quarantine_id=#{report.quarantine_id} endpoints=#{report.endpoints} " <>
          "roots_quarantined=#{report.roots_quarantined} markers_written=#{report.markers_written} " <>
          "drive_hardware_evidence_status=#{evidence_value(evidence, :status)} " <>
          "drive_hardware_evidence_ok=#{evidence_value(evidence, :ok, 0)} " <>
          "drive_hardware_evidence_errors=#{evidence_value(evidence, :errors, 0)} " <>
          "drive_hardware_evidence_gate=false physical_removal=layout_quarantine " <>
          "topology_mutation=false deployment_config_mutation=false"
    )
  end

  defp evidence_value(%{} = evidence, key, default \\ nil) do
    Map.get(evidence, to_string(key), Map.get(evidence, key, default))
  end

  defp log_failure(report, reason) do
    Log.error("rebalance physical removal quarantine failed",
      action: :rebalance_physical_remove,
      reason:
        "job_id=#{report.job_id} target_set_id=#{report.target_set_id} " <>
          "quarantine_id=#{report.quarantine_id} errors=#{report.errors} reason=#{inspect(reason)}"
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
