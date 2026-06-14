defmodule Maxio.Cluster.Rebalance.SourceCleanup do
  @moduledoc """
  Guarded foreground cleanup for decommissioned/rebalanced source-set replicas.

  This is not pool removal. Decommission cleanup deletes the old target-set copy
  for versions whose current PG placement has already moved to the job
  destination set. Rebalance cleanup keeps the PG-authoritative placement set and
  deletes configured non-authoritative set copies for the same version. PG object
  metadata remains authoritative and is never deleted here.
  """

  alias Maxio.{Buckets, ObjectMeta, Objects, Storage}
  alias Maxio.Cluster.{Lock, Placement, Topology}
  alias Maxio.Cluster.Rebalance.{Job, Jobs}
  alias Maxio.S3.Log

  @type report :: %{
          status: :ok | :dry_run | :partial | :failed | :canceled,
          job_id: String.t(),
          job_kind: String.t(),
          target_set_id: non_neg_integer() | nil,
          destination_set_id: non_neg_integer() | nil,
          dry_run: boolean(),
          truncated: boolean(),
          source_cleanup: true,
          free_space_placement: false,
          topology_mutation: false,
          source_cleanup_status: String.t(),
          scanned: non_neg_integer(),
          deleted: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc """
  Run one bounded source cleanup pass.

  Options:

    * `:max_versions` - cap versions/delete markers processed in this invocation.
    * `:page_size` - ListObjectVersions page size; defaults to job page size.
    * `:dry_run` - enumerate candidates without deleting shards or job progress.
    * `:topology` / `:transport` - storage overrides for tests/operators.
    * `:authoritative_source` - test override; read/list must be `:pg`.
  """
  @spec cleanup_once(String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def cleanup_once(job_id, opts \\ []) when is_binary(job_id) do
    if Keyword.get(opts, :dry_run, false) do
      cleanup_once_unlocked(job_id, opts)
    else
      with_runner_lock(job_id, opts, fn -> cleanup_once_unlocked(job_id, opts) end)
    end
  end

  defp cleanup_once_unlocked(job_id, opts) do
    with {:ok, job} <- Jobs.get(job_id),
         :ok <- validate_job(job),
         :ok <- ensure_pg_authority(opts),
         :ok <- validate_job_sets(job, opts) do
      cleanup_job(job, opts)
    end
  end

  defp with_runner_lock(job_id, opts, fun) do
    resource = runner_lock_resource(job_id)

    case Lock.quorum_with_lock(resource, fun, runner_lock_opts(opts)) do
      {:ok, result} ->
        result

      {:error, :no_quorum} ->
        Log.error("rebalance source cleanup lock unavailable",
          action: :rebalance_source_cleanup,
          reason: "job_id=#{job_id} resource=#{inspect(resource)}"
        )

        {:error, :runner_locked}
    end
  end

  defp runner_lock_resource(job_id), do: {:rebalance_job_runner, job_id}
  defp runner_lock_opts(opts), do: Keyword.get(opts, :runner_lock_opts, [])

  defp cleanup_job(%Job{} = job, opts) do
    dry_run = Keyword.get(opts, :dry_run, false)

    with {:ok, job} <- maybe_begin(job, opts, dry_run) do
      cfg = config(job, opts)

      report =
        job
        |> base_report(opts)
        |> scan_buckets(cfg)
        |> put_status()

      maybe_finish(job, report, opts)
    end
  end

  defp validate_job(%Job{kind: kind}) when kind not in ["decommission", "rebalance"],
    do: {:error, {:unsupported_job_kind, kind}}

  defp validate_job(%Job{data_movement_status: status}) when status != "complete",
    do: {:error, {:data_movement_not_complete, status}}

  defp validate_job(%Job{status: "canceled"}), do: {:error, :canceled}

  defp validate_job(%Job{source_cleanup_status: "complete"}),
    do: {:error, :source_cleanup_complete}

  defp validate_job(%Job{kind: "decommission", source_cleanup_status: "skipped"}),
    do: {:error, :source_cleanup_skipped}

  defp validate_job(%Job{
         kind: "decommission",
         target_set_id: target,
         destination_set_id: destination
       })
       when is_integer(target) and is_integer(destination) and target != destination,
       do: :ok

  defp validate_job(%Job{
         kind: "decommission",
         target_set_id: target,
         destination_set_id: destination
       })
       when target == destination,
       do: {:error, :destination_matches_target}

  defp validate_job(%Job{kind: "decommission", destination_set_id: nil}),
    do: {:error, :missing_destination_set_id}

  defp validate_job(%Job{kind: "decommission", target_set_id: nil}),
    do: {:error, :missing_target_set_id}

  defp validate_job(%Job{kind: "rebalance", target_set_id: nil, destination_set_id: nil}),
    do: :ok

  defp validate_job(%Job{kind: "rebalance"}), do: {:error, :stale_job}

  defp ensure_pg_authority(opts) do
    Enum.reduce_while([:read, :list], :ok, fn kind, :ok ->
      case ObjectMeta.authoritative_source(kind, opts) do
        :pg -> {:cont, :ok}
        source -> {:halt, {:error, {:unsupported_authoritative_source, kind, source}}}
      end
    end)
  end

  defp validate_job_sets(%Job{kind: "rebalance"}, opts) do
    case all_set_ids(opts) do
      [] -> {:error, :no_topology}
      _set_ids -> :ok
    end
  end

  defp validate_job_sets(%Job{kind: "decommission"} = job, opts) do
    validate_sets(job.target_set_id, job.destination_set_id, opts)
  end

  defp validate_sets(target_set_id, destination_set_id, opts) do
    set_ids = all_set_ids(opts)

    cond do
      set_ids == [] ->
        {:error, :no_topology}

      target_set_id == destination_set_id ->
        {:error, :destination_matches_target}

      target_set_id not in set_ids ->
        {:error, {:unknown_target_set_id, target_set_id, set_ids}}

      destination_set_id not in set_ids ->
        {:error, {:unknown_destination_set_id, destination_set_id, set_ids}}

      true ->
        :ok
    end
  end

  defp maybe_begin(job, _opts, true), do: {:ok, job}

  defp maybe_begin(job, opts, false) do
    with_topology_lock(job.id, opts, fn ->
      with {:ok, current} <- Jobs.get(job.id),
           :ok <- validate_job(current),
           :ok <- ensure_pg_authority(opts),
           :ok <- validate_job_sets(current, opts) do
        opts = Keyword.put(opts, :topology_lock_held, true)
        Jobs.begin_source_cleanup(current, opts)
      end
    end)
  end

  defp with_topology_lock(job_id, opts, fun) do
    resource = Topology.runtime_mutation_lock_resource()

    case Lock.quorum_with_lock(resource, fun, topology_lock_opts(opts)) do
      {:ok, result} ->
        result

      {:error, :no_quorum} ->
        Log.error("rebalance source cleanup topology lock unavailable",
          action: :rebalance_source_cleanup,
          reason: "job_id=#{job_id} resource=#{inspect(resource)}"
        )

        {:error, :topology_mutation_locked}
    end
  end

  defp topology_lock_opts(opts),
    do: Keyword.get(opts, :topology_lock_opts, Keyword.get(opts, :lock_opts, []))

  defp config(job, opts) do
    common_opts =
      []
      |> maybe_put(:topology, Keyword.get(opts, :topology))
      |> maybe_put(:transport, Keyword.get(opts, :transport))

    %{
      job_id: job.id,
      job_kind: job.kind,
      target_set_id: job.target_set_id,
      destination_set_id: job.destination_set_id,
      all_set_ids: all_set_ids(opts),
      topology_hash: Placement.topology_hash_for_opts(common_opts),
      page_size: positive_int(Keyword.get(opts, :page_size), job.page_size || 500),
      max_versions: positive_int_or_nil(Keyword.get(opts, :max_versions)),
      dry_run: Keyword.get(opts, :dry_run, false),
      common_opts: common_opts,
      source_opts: Keyword.put(common_opts, :placement_set_id, job.target_set_id)
    }
  end

  defp base_report(%Job{} = job, opts) do
    %{
      status: :ok,
      job_id: job.id,
      job_kind: job.kind,
      target_set_id: job.target_set_id,
      destination_set_id: job.destination_set_id,
      dry_run: Keyword.get(opts, :dry_run, false),
      max_versions: positive_int_or_nil(Keyword.get(opts, :max_versions)),
      truncated: false,
      canceled: false,
      source_cleanup: true,
      free_space_placement: false,
      topology_mutation: false,
      source_cleanup_status: job.source_cleanup_status,
      cursor_bucket: job.source_cleanup_cursor_bucket,
      cursor_key_marker: job.source_cleanup_cursor_key_marker,
      cursor_version_id_marker: job.source_cleanup_cursor_version_id_marker,
      scanned: job.source_cleanup_scanned || 0,
      deleted: job.source_cleanup_deleted || 0,
      skipped: job.source_cleanup_skipped || 0,
      errors: job.source_cleanup_errors || 0,
      run_scanned: 0,
      run_deleted: 0,
      run_skipped: 0,
      run_errors: 0
    }
  end

  defp scan_buckets(report, cfg) do
    report.cursor_bucket
    |> bucket_names_from_cursor()
    |> Enum.reduce_while(report, fn bucket, acc ->
      acc = scan_bucket(bucket, cfg, acc)

      if stop?(acc), do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  defp scan_bucket(bucket, cfg, report) do
    {key_marker, version_marker} =
      if report.cursor_bucket == bucket do
        {report.cursor_key_marker, report.cursor_version_id_marker}
      else
        {nil, nil}
      end

    reduce_version_pages(bucket, cfg, report, key_marker, version_marker)
  rescue
    e ->
      Log.error("rebalance source cleanup bucket scan crashed",
        action: :rebalance_source_cleanup,
        bucket: bucket,
        reason: Exception.message(e)
      )

      report |> bump(:errors) |> bump(:run_errors)
  catch
    kind, reason ->
      Log.error("rebalance source cleanup bucket scan caught",
        action: :rebalance_source_cleanup,
        bucket: bucket,
        reason: inspect({kind, reason})
      )

      report |> bump(:errors) |> bump(:run_errors)
  end

  defp reduce_version_pages(bucket, cfg, report, key_marker, version_marker) do
    page =
      Objects.list_object_versions(bucket, %{
        max_keys: cfg[:page_size],
        key_marker: key_marker,
        version_id_marker: version_marker
      })

    report = reduce_objects(bucket, cfg, report, page.versions)

    cond do
      stop?(report) ->
        report

      page.is_truncated ->
        reduce_version_pages(
          bucket,
          cfg,
          report,
          page.next_key_marker,
          page.next_version_id_marker
        )

      true ->
        report
    end
  end

  defp reduce_objects(bucket, cfg, report, objects) do
    Enum.reduce_while(objects, report, fn object, acc ->
      cond do
        stop?(acc) ->
          {:halt, acc}

        cap_reached?(acc, cfg) ->
          {:halt, %{acc | truncated: true}}

        canceled?(cfg[:job_id]) ->
          {:halt, %{acc | canceled: true}}

        true ->
          acc = process_object(bucket, cfg, acc, object)

          cond do
            stop?(acc) -> {:halt, acc}
            cap_reached?(acc, cfg) -> {:halt, %{acc | truncated: true}}
            true -> {:cont, acc}
          end
      end
    end)
  end

  defp process_object(bucket, cfg, report, object) do
    result =
      if cfg[:dry_run] do
        dry_run_result(classify(bucket, object, cfg))
      else
        cleanup_with_lock(bucket, cfg, object)
      end

    report =
      report
      |> bump(:scanned)
      |> bump(:run_scanned)
      |> apply_result(bucket, object, result)

    maybe_record_progress(report, bucket, object, cfg, result)
  end

  defp cleanup_with_lock(bucket, cfg, object) do
    case Maxio.Lock.with_object_lock({bucket, object.key}, fn ->
           cleanup_locked(bucket, cfg, object)
         end) do
      {:ok, result} -> result
      {:error, :locked} -> {:error, :locked}
    end
  end

  defp cleanup_locked(bucket, cfg, object) do
    with {:ok, current} <- Objects.get_version(bucket, object.key, object.version_id),
         {:ok, action} <- classify(bucket, current, cfg) do
      case action do
        {:delete, source_set_ids} ->
          delete_source_copies(bucket, cfg, current, source_set_ids)

        :skip ->
          {:ok, :skipped}
      end
    else
      {:error, :not_found} -> {:ok, :skipped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify(_bucket, object, %{job_kind: "decommission"} = cfg),
    do: classify_decommission(object, cfg)

  defp classify(bucket, object, %{job_kind: "rebalance"} = cfg),
    do: classify_rebalance(bucket, object, cfg)

  defp classify_decommission(%{placement_set_id: target_set_id}, %{target_set_id: target_set_id}) do
    {:error, :source_still_authoritative}
  end

  defp classify_decommission(%{placement_set_id: destination_set_id}, %{
         destination_set_id: destination_set_id
       }) do
    {:ok, {:delete, [destination_target_placeholder()]}}
  end

  defp classify_decommission(_object, _cfg), do: {:ok, :skip}

  defp classify_rebalance(_bucket, %{placement_set_id: nil} = object, _cfg) do
    {:error, {:missing_persisted_placement, object.key, object.version_id}}
  end

  defp classify_rebalance(
         bucket,
         %{placement_set_id: placement_set_id} = object,
         %{
           all_set_ids: set_ids
         } = cfg
       ) do
    cond do
      placement_set_id not in set_ids ->
        {:error,
         {:unknown_placement_set_id, object.key, object.version_id, placement_set_id, set_ids}}

      true ->
        with :ok <- ensure_rebalance_topology_current(bucket, object, cfg) do
          source_set_ids = Enum.reject(set_ids, &(&1 == placement_set_id))

          if source_set_ids == [] do
            {:ok, :skip}
          else
            {:ok, {:delete, source_set_ids}}
          end
        end
    end
  end

  defp ensure_rebalance_topology_current(bucket, object, cfg) do
    with :ok <- ensure_topology_hash_current(object, cfg),
         {:ok, %{set_id: routed_set_id}} <-
           Placement.resolve(bucket, object.key, cfg[:common_opts]) do
      cond do
        is_nil(routed_set_id) ->
          {:error, :no_topology}

        object.placement_set_id == routed_set_id ->
          :ok

        true ->
          {:error,
           {:stale_rebalance_placement, object.key, object.version_id, object.placement_set_id,
            routed_set_id}}
      end
    end
  end

  defp ensure_topology_hash_current(%{placement_topology_hash: nil} = object, _cfg) do
    {:error, {:missing_placement_topology_hash, object.key, object.version_id}}
  end

  defp ensure_topology_hash_current(object, %{topology_hash: topology_hash})
       when is_binary(topology_hash) do
    if object.placement_topology_hash == topology_hash do
      :ok
    else
      {:error,
       {:stale_topology_hash, object.key, object.version_id, object.placement_topology_hash,
        topology_hash}}
    end
  end

  defp ensure_topology_hash_current(object, %{topology_hash: nil}) do
    {:error,
     {:stale_topology_hash, object.key, object.version_id, object.placement_topology_hash, nil}}
  end

  defp dry_run_result({:ok, {:delete, _source_set_ids}}), do: {:ok, :deleted}
  defp dry_run_result({:ok, :skip}), do: {:ok, :skipped}
  defp dry_run_result({:error, reason}), do: {:error, reason}

  defp delete_source_copies(bucket, cfg, object, [placeholder])
       when placeholder == :decommission_target do
    case Storage.delete_version(bucket, object.key, object.version_id, cfg[:source_opts]) do
      :ok -> {:ok, :deleted}
      {:error, reason} -> {:error, {:delete_source_failed, reason}}
    end
  end

  defp delete_source_copies(bucket, cfg, object, source_set_ids) do
    Enum.reduce_while(source_set_ids, :ok, fn source_set_id, :ok ->
      opts = Keyword.put(cfg[:common_opts], :placement_set_id, source_set_id)

      case Storage.delete_version(bucket, object.key, object.version_id, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {source_set_id, reason}}}
      end
    end)
    |> case do
      :ok ->
        {:ok, :deleted}

      {:error, {source_set_id, reason}} ->
        {:error, {:delete_source_failed, source_set_id, reason}}
    end
  end

  defp apply_result(report, _bucket, _object, {:ok, :deleted}) do
    report |> bump(:deleted) |> bump(:run_deleted)
  end

  defp apply_result(report, _bucket, _object, {:ok, :skipped}) do
    report |> bump(:skipped) |> bump(:run_skipped)
  end

  defp apply_result(report, bucket, object, {:error, reason}) do
    Log.error("rebalance source cleanup object failed",
      action: :rebalance_source_cleanup,
      bucket: bucket,
      key: object.key,
      reason: "version_id=#{object.version_id} reason=#{inspect(reason)}"
    )

    report |> bump(:errors) |> bump(:run_errors)
  end

  defp maybe_record_progress(report, _bucket, _object, %{dry_run: true}, _result), do: report

  defp maybe_record_progress(report, bucket, object, cfg, result) do
    cursor =
      case result do
        {:error, _reason} ->
          %{}

        _ok_or_skip ->
          %{
            source_cleanup_cursor_bucket: bucket,
            source_cleanup_cursor_key_marker: object.key,
            source_cleanup_cursor_version_id_marker: object.version_id
          }
      end

    counters = Map.take(report, [:scanned, :deleted, :skipped, :errors])

    case Jobs.record_source_cleanup_progress(cfg[:job_id], counters, cursor) do
      {:ok, _job} ->
        case cursor do
          %{} when map_size(cursor) == 0 ->
            report

          _ ->
            %{
              report
              | cursor_bucket: bucket,
                cursor_key_marker: object.key,
                cursor_version_id_marker: object.version_id
            }
        end

      {:error, reason} ->
        Log.error("rebalance source cleanup progress update failed",
          action: :rebalance_source_cleanup,
          bucket: bucket,
          key: object.key,
          reason: "version_id=#{object.version_id} reason=#{inspect(reason)}"
        )

        report |> bump(:errors) |> bump(:run_errors)
    end
  end

  defp maybe_finish(_job, %{dry_run: true} = report, _opts) do
    log_complete(report)
    {:ok, public_report(report)}
  end

  defp maybe_finish(job, %{status: :ok} = report, opts) do
    with :ok <- run_before_complete(opts),
         :ok <- ensure_completion_guard(job, opts),
         {:ok, _job} <- Jobs.complete_source_cleanup(job.id, opts) do
      report = %{report | source_cleanup_status: "complete"}
      log_complete(report)
      {:ok, public_report(report)}
    else
      {:error, reason} -> fail_completion_guard(job, report, reason, opts)
    end
  end

  defp maybe_finish(_job, %{status: :partial} = report, _opts) do
    report = %{report | source_cleanup_status: "moving"}
    log_complete(report)
    {:ok, public_report(report)}
  end

  defp maybe_finish(_job, %{status: :canceled} = report, _opts) do
    log_complete(report)
    {:ok, public_report(report)}
  end

  defp maybe_finish(job, %{status: :failed} = report, opts) do
    reason = {:rebalance_source_cleanup_failed, report.run_errors}

    with {:ok, _job} <- Jobs.fail_source_cleanup(job.id, reason, opts) do
      report = %{report | source_cleanup_status: "failed"}
      log_complete(report)
      {:ok, public_report(report)}
    end
  end

  defp run_before_complete(opts) do
    case Keyword.get(opts, :before_complete) do
      nil ->
        :ok

      fun when is_function(fun, 0) ->
        case fun.() do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
          other -> {:error, {:before_complete_failed, other}}
        end
    end
  end

  defp ensure_completion_guard(%Job{kind: "decommission"} = job, _opts) do
    ensure_no_remaining_target_placements(job.target_set_id)
  end

  defp ensure_completion_guard(%Job{kind: "rebalance"}, opts) do
    set_ids = all_set_ids(opts)
    topology_hash = Placement.topology_hash_for_opts(opts)

    cond do
      set_ids == [] ->
        {:error, :no_topology}

      is_nil(topology_hash) ->
        {:error, :no_topology}

      Objects.any_version_missing_placement_set?() ->
        {:error, :missing_persisted_placement}

      Objects.any_version_with_unknown_placement_set?(set_ids) ->
        {:error, {:unknown_placement_set_id, set_ids}}

      Objects.any_version_with_placement_topology_hash_mismatch?(topology_hash) ->
        {:error, {:stale_topology_hash, topology_hash}}

      true ->
        :ok
    end
  end

  defp ensure_no_remaining_target_placements(target_set_id) do
    if Objects.any_version_with_placement_set?(target_set_id),
      do: {:error, {:source_target_placements_remaining, target_set_id}},
      else: :ok
  end

  defp fail_completion_guard(job, report, reason, opts) do
    Log.error("rebalance source cleanup final guard failed",
      action: :rebalance_source_cleanup,
      reason: "job_id=#{job.id} reason=#{inspect(reason)}"
    )

    report =
      report
      |> bump(:errors)
      |> bump(:run_errors)
      |> Map.merge(%{status: :failed, source_cleanup_status: "failed"})

    with {:ok, _job} <- Jobs.fail_source_cleanup(job.id, reason, opts) do
      log_complete(report)
      {:ok, public_report(report)}
    end
  end

  defp put_status(%{dry_run: true} = report), do: %{report | status: :dry_run}
  defp put_status(%{canceled: true} = report), do: %{report | status: :canceled}
  defp put_status(%{truncated: true} = report), do: %{report | status: :partial}
  defp put_status(%{run_errors: errors} = report) when errors > 0, do: %{report | status: :failed}
  defp put_status(report), do: report

  defp log_complete(report) do
    Log.info("rebalance source cleanup pass complete",
      action: :rebalance_source_cleanup,
      reason:
        "job_id=#{report.job_id} status=#{report.status} target_set_id=#{report.target_set_id} " <>
          "destination_set_id=#{report.destination_set_id} scanned=#{report.scanned} " <>
          "deleted=#{report.deleted} skipped=#{report.skipped} errors=#{report.errors} " <>
          "truncated=#{report.truncated} job_kind=#{report.job_kind} " <>
          "source_cleanup=true topology_mutation=false"
    )
  end

  defp public_report(report) do
    report
    |> Map.drop([
      :canceled,
      :cursor_bucket,
      :cursor_key_marker,
      :cursor_version_id_marker
    ])
  end

  defp stop?(report), do: report.truncated or report.canceled or report.run_errors > 0

  defp cap_reached?(report, cfg) do
    is_integer(cfg[:max_versions]) and report.run_scanned >= cfg[:max_versions]
  end

  defp canceled?(job_id) do
    case Jobs.get(job_id) do
      {:ok, %{status: "canceled"}} -> true
      _ -> false
    end
  end

  defp bucket_names_from_cursor(nil), do: Buckets.list() |> Enum.map(& &1.name)

  defp bucket_names_from_cursor(cursor_bucket) do
    buckets = bucket_names_from_cursor(nil)

    case Enum.drop_while(buckets, &(&1 != cursor_bucket)) do
      [] -> buckets
      remaining -> remaining
    end
  end

  defp all_set_ids(opts) do
    case Keyword.fetch(opts, :topology) do
      {:ok, nil} ->
        []

      {:ok, topology} ->
        Topology.all_set_ids_from(topology)

      :error ->
        if Topology.configured?(), do: Topology.all_set_ids(), else: []
    end
  end

  defp bump(report, key), do: Map.update!(report, key, &(&1 + 1))

  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n
  defp positive_int(_n, default), do: default

  defp positive_int_or_nil(n) when is_integer(n) and n > 0, do: n
  defp positive_int_or_nil(_n), do: nil

  defp destination_target_placeholder, do: :decommission_target

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
