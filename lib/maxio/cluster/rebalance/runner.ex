defmodule Maxio.Cluster.Rebalance.Runner do
  @moduledoc """
  Foreground rebalance/decommission copy-pass runner.

  This is a restricted M8 data movement primitive: it copies object versions and
  delete markers to a new placement set, then atomically switches the PG
  placement row. Decommission copies from one source set to an operator-selected
  or DriveStats-selected destination set. Rebalance jobs copy only rows whose
  persisted set differs from current topology routing. Neither mode deletes
  source shards or mutates topology.
  """

  alias Maxio.{Buckets, ObjectMeta, Objects, Repo, Storage}
  alias Maxio.Cluster.{Lock, Placement, Topology}
  alias Maxio.Cluster.Rebalance.{Destination, Job, Jobs}
  alias Maxio.ObjectMutation.Commit, as: ObjectMutationCommit
  alias Maxio.S3.Log
  alias Maxio.Storage.ObjectCommit.Control

  @type report :: %{
          status: :ok | :dry_run | :partial | :failed | :canceled,
          job_id: String.t(),
          job_kind: String.t(),
          target_set_id: non_neg_integer() | nil,
          destination_set_id: non_neg_integer() | nil,
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
  Run one foreground rebalance/decommission copy pass.

  Options:

    * `:destination_set_id` - explicit destination set for decommission jobs.
    * `:auto_destination` - when true, choose a decommission destination by DriveStats free space.
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
         {:ok, destination_set_id} <- resolve_job_destination(job, opts),
         :ok <- validate_job_sets(job, destination_set_id, opts) do
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

  defp validate_job(%Job{kind: "rebalance", status: status})
       when status in ["planned", "running"],
       do: :ok

  defp validate_job(%Job{kind: "rebalance", status: "canceled"}), do: {:error, :canceled}

  defp validate_job(%Job{kind: "rebalance", status: status}),
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

  defp resolve_job_destination(%Job{kind: "rebalance"}, opts) do
    cond do
      is_integer(Keyword.get(opts, :destination_set_id)) ->
        {:error, :rebalance_uses_dynamic_destinations}

      Keyword.get(opts, :auto_destination, false) ->
        {:error, :rebalance_uses_dynamic_destinations}

      true ->
        {:ok, nil}
    end
  end

  defp resolve_job_destination(%Job{kind: "decommission"} = job, opts) do
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

  defp validate_job_sets(%Job{kind: "rebalance"}, nil, opts) do
    case all_set_ids(opts) do
      [] -> {:error, :no_topology}
      _set_ids -> :ok
    end
  end

  defp validate_job_sets(%Job{kind: "decommission"} = job, destination_set_id, opts),
    do: validate_sets(job.target_set_id, destination_set_id, opts)

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

  defp maybe_begin(%Job{kind: "rebalance"} = job, nil, opts, false) do
    Jobs.begin_rebalance_data_movement(job, opts)
  end

  defp maybe_begin(job, destination_set_id, opts, false) do
    Jobs.begin_data_movement(job, destination_set_id, opts)
  end

  defp config(job, destination_set_id, opts) do
    common_opts =
      []
      |> maybe_put(:topology, Keyword.get(opts, :topology))
      |> maybe_put(:transport, Keyword.get(opts, :transport))

    [
      job_kind: job.kind,
      job_id: job.id,
      target_set_id: job.target_set_id,
      destination_set_id: destination_set_id,
      page_size: positive_int(Keyword.get(opts, :page_size), job.page_size || 500),
      max_versions: positive_int_or_nil(Keyword.get(opts, :max_versions)),
      dry_run: Keyword.get(opts, :dry_run, false),
      free_space_placement: Keyword.get(opts, :free_space_destination, false),
      common_opts: common_opts
    ]
  end

  defp base_report(%Job{} = job, destination_set_id, opts) do
    %{
      status: :ok,
      job_id: job.id,
      job_kind: job.kind,
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

        canceled?(cfg[:job_id]) ->
          {:halt, %{acc | canceled: true}}

        true ->
          case movement_candidate(bucket, cfg, object) do
            :skip ->
              {:cont, acc}

            {:skip, destination_set_id} ->
              reduce_movement_candidate(bucket, cfg, acc, object, destination_set_id, :skipped)

            {:error, reason} ->
              acc =
                acc
                |> bump(:errors)
                |> bump(:run_errors)
                |> log_candidate_error(bucket, object, reason)

              {:halt, acc}

            {:ok, destination_set_id} ->
              reduce_movement_candidate(bucket, cfg, acc, object, destination_set_id, :moved)
          end
      end
    end)
  end

  defp reduce_movement_candidate(bucket, cfg, report, object, destination_set_id, dry_run_result) do
    cond do
      stop?(report) ->
        {:halt, report}

      cap_reached?(report, cfg) ->
        {:halt, %{report | truncated: true}}

      canceled?(cfg[:job_id]) ->
        {:halt, %{report | canceled: true}}

      true ->
        report =
          process_target_object(bucket, cfg, report, object, destination_set_id, dry_run_result)

        cond do
          stop?(report) -> {:halt, report}
          cap_reached?(report, cfg) -> {:halt, %{report | truncated: true}}
          true -> {:cont, report}
        end
    end
  end

  defp movement_candidate(bucket, cfg, object) do
    case cfg[:job_kind] do
      "decommission" -> decommission_movement_candidate(cfg, object)
      "rebalance" -> rebalance_movement_candidate(bucket, cfg, object)
    end
  end

  defp decommission_movement_candidate(cfg, object) do
    if object.placement_set_id == cfg[:target_set_id] do
      {:ok, cfg[:destination_set_id]}
    else
      :skip
    end
  end

  defp rebalance_movement_candidate(bucket, cfg, object) do
    with {:ok, destination} <- rebalance_destination(bucket, cfg, object) do
      cond do
        is_nil(object.placement_set_id) ->
          {:error, {:missing_persisted_placement, object.key, object.version_id}}

        destination == object.placement_set_id ->
          {:skip, destination}

        true ->
          {:ok, destination}
      end
    end
  end

  defp rebalance_destination(bucket, cfg, object) do
    case Placement.resolve(bucket, object.key, cfg[:common_opts]) do
      {:ok, %{set_id: nil}} -> {:error, :no_topology}
      {:ok, %{set_id: set_id}} -> {:ok, set_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_candidate_error(report, bucket, object, reason) do
    Log.error("rebalance runner object candidate failed",
      action: :rebalance_run,
      bucket: bucket,
      key: object.key,
      reason: "version_id=#{object.version_id} reason=#{inspect(reason)}"
    )

    report
  end

  defp process_target_object(bucket, cfg, report, object, destination_set_id, dry_run_result) do
    result =
      if cfg[:dry_run] do
        {:ok, dry_run_result}
      else
        move_with_lock(bucket, cfg, object, destination_set_id)
      end

    report =
      report
      |> bump(:scanned)
      |> bump(:run_scanned)
      |> apply_result(bucket, object, result)

    maybe_record_progress(report, bucket, object, cfg, result)
  end

  defp move_with_lock(bucket, cfg, object, destination_set_id) do
    case Maxio.Lock.with_object_lock({bucket, object.key}, fn ->
           move_locked(bucket, cfg, object, destination_set_id)
         end) do
      {:ok, result} -> result
      {:error, :locked} -> {:error, :locked}
    end
  end

  defp move_locked(bucket, cfg, object, destination_set_id) do
    with {:ok, current} <- Objects.get_version(bucket, object.key, object.version_id),
         {:ok, destination_set_id} <-
           locked_destination(bucket, cfg, current, destination_set_id) do
      if current.is_delete_marker do
        copy_delete_marker(bucket, cfg, current, destination_set_id)
      else
        copy_object(bucket, cfg, current, destination_set_id)
      end
    else
      {:error, :not_found} -> {:ok, :skipped}
      {:error, :stale} -> {:ok, :skipped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp locked_destination(bucket, cfg, object, destination_set_id) do
    case cfg[:job_kind] do
      "decommission" ->
        locked_decommission_destination(cfg, object, destination_set_id)

      "rebalance" ->
        locked_rebalance_destination(bucket, cfg, object)
    end
  end

  defp locked_decommission_destination(cfg, object, destination_set_id) do
    if object.placement_set_id == cfg[:target_set_id] do
      {:ok, destination_set_id}
    else
      {:error, :stale}
    end
  end

  defp locked_rebalance_destination(bucket, cfg, object) do
    with {:ok, destination_set_id} <- rebalance_destination(bucket, cfg, object) do
      cond do
        is_nil(object.placement_set_id) -> {:error, :stale}
        object.placement_set_id == destination_set_id -> {:error, :stale}
        true -> {:ok, destination_set_id}
      end
    end
  end

  # ObjectMutation Phase 2A（C5）：PG 写权威（默认）下 destination copy 全程 journal 化
  # （operation="rebalance_copy"，placement 迁移语义而非新 logical value：不挂
  # notification/replication outbox、不动 is_latest；外层 move_with_lock 已持
  # {bucket, key} 对象锁，seam 在锁内直跑，D5）。storage_opts = dest 写钉扎——
  # common_opts（topology/transport 覆盖）+ Placement.storage_opts(write_info)，保证
  # claim/current_epoch/publish 三者解析同一 dest 端点集（B4 审查项 2）。metadata_tx 把
  # update_placement_if_current（条件 UPDATE，无自带事务）外包 Repo.transaction 并与
  # journal metadata_committed 同一事务（协议 §8 rebalance 行）。迁移前「metadata 失败
  # 无回退（dest 字节孤儿）」被 seam restore 取代：fresh dest 的 manifest entries=[] →
  # epoch=rolled_back、已发布字节留 dest 但 placement 仍指旧 placement、读不受影响
  # （孤儿收敛归 Phase 2C GC）。:sidecar 写权威维持迁移前值语义（publish 后 placement
  # 更新失败不回滚 dest 字节，D1）。copy_delete_marker 不迁（2B）；source cleanup
  # 零接触（2C）。
  defp copy_object(bucket, cfg, object, destination_set_id) do
    source_opts = cfg[:common_opts] ++ Placement.storage_opts(object)
    meta = object_meta(object)

    destination_opts =
      cfg
      |> destination_opts(destination_set_id)
      |> Keyword.put(:object_meta, meta)

    around_object_commit = fn write_info, publish ->
      # 尺寸校验前置到 publish 之前（迁移前在 Storage.put 返回后）：不一致即中止，
      # 零破坏性 IO、零 journal。
      with :ok <- verify_unencrypted_size(object, write_info) do
        # around 接管 commit_opts 后 object_meta 不再经 default_commit_opts merge
        # （C3 复审 High）：本 caller 无 before_object_commit，防御性 merge 后显式
        # 传两条权威分支的 publish。
        committed_object_meta = Map.merge(meta, Map.get(write_info, :object_meta, %{}))

        case ObjectMeta.authoritative_source(:write) do
          :sidecar ->
            commit_rebalance_sidecar_authority(
              object,
              destination_set_id,
              committed_object_meta,
              write_info,
              publish
            )

          _pg ->
            commit_rebalance_pg_authority(
              bucket,
              cfg,
              object,
              destination_set_id,
              committed_object_meta,
              write_info,
              publish
            )
        end
      end
    end

    with {:ok, stream} <- Storage.get(bucket, object.key, object.version_id, nil, source_opts),
         {:ok, write_result} <-
           Storage.put(
             bucket,
             object.key,
             object.version_id,
             stream,
             Keyword.put(destination_opts, :around_object_commit, around_object_commit)
           ),
         {:ok, outcome} <- Map.fetch!(write_result, :around_object_commit_result) do
      {:ok, outcome}
    else
      # placement 行已被并发者改写：与迁移前 {:error, :stale} → skipped 口径一致
      # （pg 分支下 seam 已回滚，dest epoch=rolled_back、placement 行不变）。
      {:error, {:placement_stale, :stale}} -> {:ok, :skipped}
      {:error, reason} -> {:error, {:copy_object_failed, object.key, object.version_id, reason}}
    end
  end

  # PG 写权威：ObjectMutation seam（协议 §0.2 序列）。placement PG 更新与 journal
  # metadata_committed 同一 Repo.transaction（CAS 失败 repo.rollback → 整体回滚，
  # placement 行零半提交）；update_placement_if_current stale/not_found →
  # {:placement_stale, reason} 交 seam 回滚（dest epoch=rolled_back，placement 不变）。
  defp commit_rebalance_pg_authority(
         bucket,
         cfg,
         object,
         destination_set_id,
         object_meta,
         write_info,
         publish
       ) do
    plan = %{
      bucket: bucket,
      key: object.key,
      version_id: object.version_id,
      operation: "rebalance_copy",
      authority_mode: "pg",
      storage_opts: cfg[:common_opts] ++ Placement.storage_opts(write_info),
      write_info: write_info,
      publish: fn extra_commit_opts ->
        publish.(
          Keyword.merge(
            [version_id: object.version_id, object_meta: object_meta],
            extra_commit_opts
          )
        )
      end,
      metadata_tx: fn journal, published_result ->
        with {:ok, attrs} <-
               placement_attrs_from_write(published_result, destination_set_id, object) do
          Repo.transaction(fn ->
            case Objects.update_placement_if_current(object, attrs) do
              {:ok, updated} ->
                _ = ObjectMutationCommit.commit_metadata_in_tx!(journal, Repo)
                updated

              {:error, reason} ->
                Repo.rollback({:placement_stale, reason})
            end
          end)
        end
      end
    }

    case ObjectMutationCommit.run(plan) do
      {:ok, %{published: published_result}} ->
        {:ok, Map.put(published_result, :around_object_commit_result, {:ok, :moved})}

      {:error, _reason} = error ->
        error
    end
  end

  # :sidecar 写权威（D1）：publish 即权威提交（dest 字节一经发布即保留，绝不回滚——
  # 迁移前 Storage.put 返回后才更新 placement，失败仅留孤儿字节），placement 更新结果
  # （moved/skipped/error）经 around_object_commit_result 原样透出，值语义与迁移前一致。
  defp commit_rebalance_sidecar_authority(
         object,
         destination_set_id,
         object_meta,
         write_info,
         publish
       ) do
    case publish.(version_id: object.version_id, object_meta: object_meta) do
      {:ok, published_result} ->
        outcome =
          try do
            with {:ok, attrs} <-
                   placement_attrs_from_write(published_result, destination_set_id, object),
                 {:ok, _updated} <- Objects.update_placement_if_current(object, attrs) do
              {:ok, :moved}
            else
              {:error, :stale} -> {:ok, :skipped}
              {:error, reason} -> {:error, reason}
            end
          rescue
            err -> {:error, err}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        accelerate_mark_committed(write_info, object)
        {:ok, Map.put(published_result, :around_object_commit_result, outcome)}

      {:error, _reason} = error ->
        error
    end
  end

  # 与 do_put :sidecar 分支同构：metadata（placement 更新）完成后立即关闭进程内提交
  # 窗口——此后 publisher DOWN 不再触发字节回滚（sidecar 权威下 publish 已是提交点）。
  defp accelerate_mark_committed(write_info, object) do
    case write_info
         |> Map.fetch!(:object_commit_control)
         |> Control.mark_committed() do
      :ok ->
        :ok

      {:error, reason} ->
        Log.error("object commit finalize failed after metadata commit",
          action: :object_commit_finalize,
          bucket: object.bucket_name,
          key: object.key,
          reason: "version_id=#{object.version_id} reason=#{inspect(reason)}"
        )
    end
  end

  defp copy_delete_marker(bucket, cfg, object, destination_set_id) do
    entry_opts = [modtime: modtime_ns(object), generation: object.index_generation || 0]

    with :ok <-
           Storage.put_delete_marker(
             bucket,
             object.key,
             object.version_id,
             entry_opts,
             destination_opts(cfg, destination_set_id)
           ),
         {:ok, attrs} <- marker_placement_attrs(bucket, cfg, object, destination_set_id),
         {:ok, _updated} <- Objects.update_placement_if_current(object, attrs) do
      {:ok, :moved}
    else
      {:error, :stale} ->
        {:ok, :skipped}

      {:error, reason} ->
        {:error, {:copy_delete_marker_failed, object.key, object.version_id, reason}}
    end
  end

  defp destination_opts(cfg, destination_set_id) do
    Keyword.put(cfg[:common_opts], :placement_set_id, destination_set_id)
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

  defp placement_attrs_from_write(write_result, destination_set_id, object) do
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

  defp marker_placement_attrs(bucket, cfg, object, destination_set_id) do
    attrs =
      bucket
      |> Placement.attrs_for_write(object.key, destination_opts(cfg, destination_set_id))
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
