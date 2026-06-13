defmodule Maxio.Cluster.Rebalance.Runner do
  @moduledoc """
  Foreground decommission copy-pass runner.

  This is a restricted M8 data movement primitive: it copies object versions and
  delete markers from a persisted source set to an operator-selected destination
  set, then atomically switches the PG placement row. It can choose a bounded
  DriveStats-based destination when explicitly requested, but it never deletes
  source shards or mutates topology.
  """

  alias Maxio.{Buckets, ObjectMeta, Objects, Storage}
  alias Maxio.Cluster.{Lock, Placement, Topology}
  alias Maxio.Cluster.Rebalance.{Destination, Job, Jobs}
  alias Maxio.S3.Log

  @type report :: %{
          status: :ok | :dry_run | :partial | :failed | :canceled,
          job_id: String.t(),
          target_set_id: non_neg_integer(),
          destination_set_id: non_neg_integer(),
          dry_run: boolean(),
          truncated: boolean(),
          source_cleanup: false,
          free_space_placement: boolean(),
          topology_mutation: false,
          scanned: non_neg_integer(),
          moved: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc """
  Run one foreground decommission copy pass.

  Options:

    * `:destination_set_id` - explicit destination set.
    * `:auto_destination` - when true, choose a destination by DriveStats free space.
    * `:max_versions` - cap versions/delete markers processed in this invocation.
    * `:page_size` - ListObjectVersions page size; defaults to job page size.
    * `:dry_run` - enumerate target rows without writing bytes or job progress.
    * `:topology` / `:transport` - storage overrides for tests/operators.
    * `:authoritative_source` - test override; read/list must be `:pg`.
  """
  @spec run_once(String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def run_once(job_id, opts \\ []) when is_binary(job_id) do
    if Keyword.get(opts, :dry_run, false) do
      run_once_unlocked(job_id, opts)
    else
      with_runner_lock(job_id, opts, fn -> run_once_unlocked(job_id, opts) end)
    end
  end

  defp run_once_unlocked(job_id, opts) do
    with {:ok, job} <- Jobs.get(job_id),
         :ok <- validate_job(job),
         :ok <- ensure_pg_authority(opts),
         {:ok, destination_set_id} <- resolve_destination(job, opts),
         :ok <- validate_sets(job.target_set_id, destination_set_id, opts) do
      opts =
        Keyword.put(opts, :free_space_destination, free_space_destination_selected?(job, opts))

      run_job(job, destination_set_id, opts)
    end
  end

  defp with_runner_lock(job_id, opts, fun) do
    resource = runner_lock_resource(job_id)

    case Lock.quorum_with_lock(resource, fun, runner_lock_opts(opts)) do
      {:ok, result} ->
        result

      {:error, :no_quorum} ->
        Log.error("rebalance runner lock unavailable",
          action: :rebalance_run,
          reason: "job_id=#{job_id} resource=#{inspect(resource)}"
        )

        {:error, :runner_locked}
    end
  end

  defp runner_lock_resource(job_id), do: {:rebalance_job_runner, job_id}

  defp runner_lock_opts(opts) do
    Keyword.get(opts, :runner_lock_opts, [])
  end

  defp run_job(%Job{} = job, destination_set_id, opts) do
    dry_run = Keyword.get(opts, :dry_run, false)

    with {:ok, job} <- maybe_begin(job, destination_set_id, opts, dry_run) do
      cfg = config(job, destination_set_id, opts)

      report =
        job
        |> base_report(destination_set_id, opts)
        |> scan_buckets(cfg)
        |> put_status()

      maybe_finish(job, report, opts)
    end
  end

  defp validate_job(%Job{kind: "decommission", status: status})
       when status in ["planned", "running"],
       do: :ok

  defp validate_job(%Job{kind: "decommission", status: "canceled"}), do: {:error, :canceled}

  defp validate_job(%Job{kind: "decommission", status: status}),
    do: {:error, {:not_runnable, status}}

  defp validate_job(%Job{kind: kind}), do: {:error, {:unsupported_job_kind, kind}}

  defp ensure_pg_authority(opts) do
    Enum.reduce_while([:read, :list], :ok, fn kind, :ok ->
      case ObjectMeta.authoritative_source(kind, opts) do
        :pg -> {:cont, :ok}
        source -> {:halt, {:error, {:unsupported_authoritative_source, kind, source}}}
      end
    end)
  end

  defp resolve_destination(%Job{} = job, opts) do
    requested = Keyword.get(opts, :destination_set_id)

    cond do
      is_integer(requested) and is_nil(job.destination_set_id) ->
        {:ok, requested}

      is_integer(requested) and requested == job.destination_set_id ->
        {:ok, requested}

      is_integer(requested) ->
        {:error, {:destination_mismatch, job.destination_set_id, requested}}

      is_integer(job.destination_set_id) ->
        {:ok, job.destination_set_id}

      Keyword.get(opts, :auto_destination, false) ->
        case Destination.select_decommission_destination(
               job.target_set_id,
               destination_selection_opts(job, opts)
             ) do
          {:ok, %{set_id: set_id}} -> {:ok, set_id}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :missing_destination_set_id}
    end
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

  defp maybe_begin(job, _destination_set_id, _opts, true), do: {:ok, job}

  defp maybe_begin(job, destination_set_id, opts, false) do
    Jobs.begin_data_movement(job, destination_set_id, opts)
  end

  defp config(job, destination_set_id, opts) do
    common_opts =
      []
      |> maybe_put(:topology, Keyword.get(opts, :topology))
      |> maybe_put(:transport, Keyword.get(opts, :transport))

    [
      job_id: job.id,
      target_set_id: job.target_set_id,
      destination_set_id: destination_set_id,
      page_size: positive_int(Keyword.get(opts, :page_size), job.page_size || 500),
      max_versions: positive_int_or_nil(Keyword.get(opts, :max_versions)),
      dry_run: Keyword.get(opts, :dry_run, false),
      free_space_placement: Keyword.get(opts, :free_space_destination, false),
      common_opts: common_opts,
      destination_opts: Keyword.put(common_opts, :placement_set_id, destination_set_id)
    ]
  end

  defp base_report(%Job{} = job, destination_set_id, opts) do
    %{
      status: :ok,
      job_id: job.id,
      target_set_id: job.target_set_id,
      destination_set_id: destination_set_id,
      dry_run: Keyword.get(opts, :dry_run, false),
      max_versions: positive_int_or_nil(Keyword.get(opts, :max_versions)),
      truncated: false,
      canceled: false,
      source_cleanup: false,
      free_space_placement: Keyword.get(opts, :free_space_destination, false),
      topology_mutation: false,
      cursor_bucket: job.cursor_bucket,
      cursor_key_marker: job.cursor_key_marker,
      cursor_version_id_marker: job.cursor_version_id_marker,
      scanned: job.progress_scanned || 0,
      moved: job.progress_moved || 0,
      skipped: job.progress_skipped || 0,
      errors: job.progress_errors || 0,
      run_scanned: 0,
      run_moved: 0,
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
      Log.error("rebalance runner bucket scan crashed",
        action: :rebalance_run,
        bucket: bucket,
        reason: Exception.message(e)
      )

      report |> bump(:errors) |> bump(:run_errors)
  catch
    kind, reason ->
      Log.error("rebalance runner bucket scan caught",
        action: :rebalance_run,
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

        object.placement_set_id != cfg[:target_set_id] ->
          {:cont, acc}

        canceled?(cfg[:job_id]) ->
          {:halt, %{acc | canceled: true}}

        true ->
          acc = process_target_object(bucket, cfg, acc, object)

          cond do
            stop?(acc) -> {:halt, acc}
            cap_reached?(acc, cfg) -> {:halt, %{acc | truncated: true}}
            true -> {:cont, acc}
          end
      end
    end)
  end

  defp process_target_object(bucket, cfg, report, object) do
    result =
      if cfg[:dry_run] do
        {:ok, :moved}
      else
        move_with_lock(bucket, cfg, object)
      end

    report =
      report
      |> bump(:scanned)
      |> bump(:run_scanned)
      |> apply_result(bucket, object, result)

    maybe_record_progress(report, bucket, object, cfg, result)
  end

  defp move_with_lock(bucket, cfg, object) do
    case Maxio.Lock.with_object_lock({bucket, object.key}, fn ->
           move_locked(bucket, cfg, object)
         end) do
      {:ok, result} -> result
      {:error, :locked} -> {:error, :locked}
    end
  end

  defp move_locked(bucket, cfg, object) do
    with {:ok, current} <- Objects.get_version(bucket, object.key, object.version_id),
         :ok <- ensure_current_target(current, cfg[:target_set_id]) do
      if current.is_delete_marker do
        copy_delete_marker(bucket, cfg, current)
      else
        copy_object(bucket, cfg, current)
      end
    else
      {:error, :not_found} -> {:ok, :skipped}
      {:error, :stale} -> {:ok, :skipped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_current_target(%{placement_set_id: target_set_id}, target_set_id), do: :ok
  defp ensure_current_target(_object, _target_set_id), do: {:error, :stale}

  defp copy_object(bucket, cfg, object) do
    source_opts = cfg[:common_opts] ++ Placement.storage_opts(object)
    destination_opts = Keyword.put(cfg[:destination_opts], :object_meta, object_meta(object))

    with {:ok, stream} <- Storage.get(bucket, object.key, object.version_id, nil, source_opts),
         {:ok, write_result} <-
           Storage.put(bucket, object.key, object.version_id, stream, destination_opts),
         :ok <- verify_unencrypted_size(object, write_result),
         {:ok, attrs} <- placement_attrs_from_write(write_result, cfg, object),
         {:ok, _updated} <- Objects.update_placement_if_current(object, attrs) do
      {:ok, :moved}
    else
      {:error, :stale} -> {:ok, :skipped}
      {:error, reason} -> {:error, {:copy_object_failed, object.key, object.version_id, reason}}
    end
  end

  defp copy_delete_marker(bucket, cfg, object) do
    entry_opts = [modtime: modtime_ns(object), generation: object.index_generation || 0]

    with :ok <-
           Storage.put_delete_marker(
             bucket,
             object.key,
             object.version_id,
             entry_opts,
             cfg[:destination_opts]
           ),
         {:ok, attrs} <- marker_placement_attrs(bucket, cfg, object),
         {:ok, _updated} <- Objects.update_placement_if_current(object, attrs) do
      {:ok, :moved}
    else
      {:error, :stale} ->
        {:ok, :skipped}

      {:error, reason} ->
        {:error, {:copy_delete_marker_failed, object.key, object.version_id, reason}}
    end
  end

  defp object_meta(object) do
    %{
      size: object.size,
      etag: object.etag,
      content_type: object.content_type || "binary/octet-stream",
      content_encoding: object.content_encoding,
      content_disposition: object.content_disposition,
      cache_control: object.cache_control,
      expires: object.expires,
      tags: object.tags || %{},
      sse: sse_meta(object),
      acl_canned: object.acl_canned || "private",
      acl_grants: object.acl_grants || %{"grants" => []},
      storage_class: object.storage_class || "STANDARD",
      user_metadata: object.metadata || %{},
      modtime: modtime_ns(object),
      generation: object.index_generation || 0
    }
  end

  defp sse_meta(%{sse_algorithm: nil}), do: nil

  defp sse_meta(%{sse_algorithm: algorithm, sse_envelope: envelope}) do
    %{"algo" => algorithm, "envelope" => envelope}
  end

  defp verify_unencrypted_size(%{sse_algorithm: algorithm}, _write_result)
       when not is_nil(algorithm),
       do: :ok

  defp verify_unencrypted_size(object, %{size: size}) when size == object.size, do: :ok

  defp verify_unencrypted_size(object, %{size: size}),
    do: {:error, {:size_mismatch, object.size, size}}

  defp verify_unencrypted_size(_object, _write_result), do: {:error, :missing_write_size}

  defp placement_attrs_from_write(write_result, cfg, object) do
    destination_set_id = cfg[:destination_set_id]

    attrs =
      write_result
      |> Placement.attrs_from_result()
      |> Map.put(:index_generation, object.index_generation || 0)

    case Map.get(attrs, :placement_set_id) do
      ^destination_set_id ->
        {:ok, attrs}

      other ->
        {:error, {:unexpected_destination_set_id, other}}
    end
  end

  defp marker_placement_attrs(bucket, cfg, object) do
    destination_set_id = cfg[:destination_set_id]

    attrs =
      bucket
      |> Placement.attrs_for_write(object.key, cfg[:destination_opts])
      |> Map.put(:index_generation, object.index_generation || 0)

    case Map.get(attrs, :placement_set_id) do
      ^destination_set_id ->
        {:ok, attrs}

      other ->
        {:error, {:unexpected_destination_set_id, other}}
    end
  end

  defp apply_result(report, _bucket, _object, {:ok, :moved}) do
    report |> bump(:moved) |> bump(:run_moved)
  end

  defp apply_result(report, _bucket, _object, {:ok, :skipped}) do
    report |> bump(:skipped) |> bump(:run_skipped)
  end

  defp apply_result(report, bucket, object, {:error, reason}) do
    Log.error("rebalance runner object failed",
      action: :rebalance_run,
      bucket: bucket,
      key: object.key,
      reason: "version_id=#{object.version_id} reason=#{inspect(reason)}"
    )

    report |> bump(:errors) |> bump(:run_errors)
  end

  defp maybe_record_progress(report, bucket, object, cfg, result) do
    if cfg[:dry_run] do
      report
    else
      cursor =
        case result do
          {:error, _reason} ->
            %{}

          _ok_or_skip ->
            %{
              cursor_bucket: bucket,
              cursor_key_marker: object.key,
              cursor_version_id_marker: object.version_id
            }
        end

      counters = Map.take(report, [:scanned, :moved, :skipped, :errors])

      case Jobs.record_progress(cfg[:job_id], counters, cursor) do
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
          Log.error("rebalance runner progress update failed",
            action: :rebalance_run,
            bucket: bucket,
            key: object.key,
            reason: "version_id=#{object.version_id} reason=#{inspect(reason)}"
          )

          report |> bump(:errors) |> bump(:run_errors)
      end
    end
  end

  defp maybe_finish(_job, %{dry_run: true} = report, _opts) do
    log_complete(report)
    {:ok, public_report(report)}
  end

  defp maybe_finish(job, %{status: :ok} = report, opts) do
    with {:ok, _job} <- Jobs.complete_data_movement(job.id, opts) do
      log_complete(report)
      {:ok, public_report(report)}
    end
  end

  defp maybe_finish(_job, %{status: :partial} = report, _opts) do
    log_complete(report)
    {:ok, public_report(report)}
  end

  defp maybe_finish(_job, %{status: :canceled} = report, _opts) do
    log_complete(report)
    {:ok, public_report(report)}
  end

  defp maybe_finish(job, %{status: :failed} = report, opts) do
    reason = {:rebalance_run_failed, report.run_errors}

    with {:ok, _job} <- Jobs.fail_data_movement(job.id, reason, opts) do
      log_complete(report)
      {:ok, public_report(report)}
    end
  end

  defp put_status(%{dry_run: true} = report), do: %{report | status: :dry_run}
  defp put_status(%{canceled: true} = report), do: %{report | status: :canceled}
  defp put_status(%{truncated: true} = report), do: %{report | status: :partial}
  defp put_status(%{run_errors: errors} = report) when errors > 0, do: %{report | status: :failed}
  defp put_status(report), do: %{report | status: :ok}

  defp log_complete(report) do
    Log.info("rebalance runner pass complete",
      action: :rebalance_run,
      reason:
        "job_id=#{report.job_id} status=#{report.status} target_set_id=#{report.target_set_id} " <>
          "destination_set_id=#{report.destination_set_id} scanned=#{report.scanned} " <>
          "moved=#{report.moved} skipped=#{report.skipped} errors=#{report.errors} " <>
          "truncated=#{report.truncated} source_cleanup=false " <>
          "free_space_placement=#{report.free_space_placement} topology_mutation=false"
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

  defp destination_selection_opts(job, opts) do
    opts
    |> Keyword.take([
      :topology,
      :transport,
      :provider,
      :drive_stats_fun,
      :now_ms,
      :now_fun
    ])
    |> Keyword.put(:bytes_required, job.plan_bytes || 0)
  end

  defp free_space_destination_selected?(%Job{} = job, opts) do
    Keyword.get(opts, :auto_destination, false) and
      not is_integer(Keyword.get(opts, :destination_set_id)) and
      not is_integer(job.destination_set_id)
  end

  defp modtime_ns(%{updated_at: %DateTime{} = updated_at}),
    do: DateTime.to_unix(updated_at, :nanosecond)

  defp modtime_ns(_object), do: System.os_time(:nanosecond)

  defp bump(report, key), do: Map.update!(report, key, &(&1 + 1))

  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n
  defp positive_int(_n, default), do: default

  defp positive_int_or_nil(n) when is_integer(n) and n > 0, do: n
  defp positive_int_or_nil(_n), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
