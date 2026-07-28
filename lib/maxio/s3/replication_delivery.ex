defmodule Maxio.S3.ReplicationDelivery do
  @moduledoc """
  Data-plane replication scheduler and runner.

  This is the local same-cluster replication v1 path. Source handlers enqueue
  work in the same metadata transaction as the source object commit. Drain
  workers copy bytes by streaming `Storage.get/5` into `Storage.put/5` and mark
  the source object replication status from durable outbox state.
  """

  alias Maxio.Cluster.Placement
  alias Maxio.{Buckets, ObjectMeta, Objects, Storage}
  alias Maxio.Objects.Object
  alias Maxio.ObjectMutation.Commit, as: ObjectMutationCommit
  alias Maxio.S3.{Log, Replication, ReplicationOutbox}
  alias Maxio.S3.ReplicationOutbox.Event
  alias Maxio.Storage.ObjectCommit.Control

  @default_drain_limit 100

  @doc "Return true when this event would enqueue at least one replication task."
  @spec pending?(String.t(), map()) :: boolean()
  def pending?(event_name, attrs), do: pending_tasks(event_name, attrs) != []

  @doc "Return the replication tasks matched by the current source event snapshot."
  @spec pending_tasks(String.t(), map()) :: [map()]
  def pending_tasks(event_name, attrs) do
    if Map.get(attrs, :skip_replication?) do
      []
    else
      Replication.matching_tasks(event_name, attrs)
    end
  end

  @doc "Enqueue a precomputed task snapshot."
  @spec enqueue_tasks([map()], keyword()) :: [Event.t()]
  def enqueue_tasks(tasks, opts \\ []) when is_list(tasks),
    do: ReplicationOutbox.enqueue_many(tasks, opts)

  @doc "Enqueue all matching replication tasks for a committed source event."
  @spec enqueue(String.t(), map(), keyword()) :: [Event.t()]
  def enqueue(event_name, attrs, opts \\ []) do
    event_name
    |> pending_tasks(attrs)
    |> enqueue_tasks(opts)
  end

  @doc "Drain due replication tasks."
  @spec drain(keyword()) :: {:ok, map()} | {:error, term()}
  def drain(opts \\ []) do
    case ReplicationOutbox.claim_due(Keyword.put_new(opts, :limit, drain_limit(opts))) do
      {:ok, events} ->
        summary =
          Enum.reduce(events, %{claimed: 0, completed: 0, failed: 0}, fn event, acc ->
            acc = Map.update!(acc, :claimed, &(&1 + 1))

            case deliver_claimed(event, opts) do
              :ok -> Map.update!(acc, :completed, &(&1 + 1))
              {:error, _reason} -> Map.update!(acc, :failed, &(&1 + 1))
            end
          end)

        {:ok, summary}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Deliver one retryable outbox row by id."
  @spec deliver_one(Ecto.UUID.t(), keyword()) :: {:ok, :completed} | {:error, term()}
  def deliver_one(id, opts \\ []) when is_binary(id) do
    with {:ok, event} <- ReplicationOutbox.claim(id, opts) do
      case deliver_claimed(event, opts) do
        :ok -> {:ok, :completed}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec deliver_claimed(Event.t(), keyword()) :: :ok | {:error, term()}
  def deliver_claimed(%Event{} = event, opts \\ []) do
    case replicate(event, opts) do
      :ok ->
        with {:ok, completed} <- mark_completed(event, opts) do
          log_completed(completed)
          :ok
        end

      {:error, reason} ->
        with {:ok, failed} <- mark_failed(event, reason, opts) do
          log_failed(failed, reason)
          {:error, reason}
        end
    end
  end

  defp mark_completed(%Event{event_name: "s3:ObjectRemoved:Delete"} = event, opts),
    do: ReplicationOutbox.mark_completed(event, opts)

  defp mark_completed(%Event{} = event, opts),
    do: ReplicationOutbox.mark_completed_with_source_status(event, opts)

  defp mark_failed(%Event{event_name: "s3:ObjectRemoved:Delete"} = event, reason, opts),
    do: ReplicationOutbox.mark_failed(event, reason, opts)

  defp mark_failed(%Event{} = event, reason, opts),
    do: ReplicationOutbox.mark_failed_with_source_status(event, reason, opts)

  defp replicate(%Event{event_name: "s3:ObjectRemoved:DeleteMarkerCreated"} = event, opts) do
    with :ok <- ensure_destination_versioning!(event.destination_bucket),
         %Object{} = source <-
           ObjectMeta.get(event.source_bucket, event.source_key, event.source_version_id, opts),
         true <- source.is_delete_marker == true do
      replicate_delete_marker(event)
    else
      false -> {:error, :source_not_delete_marker}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:source_unavailable, other}}
    end
  end

  defp replicate(%Event{event_name: "s3:ObjectRemoved:Delete"} = event, _opts) do
    with :ok <- ensure_destination_versioning!(event.destination_bucket) do
      replicate_version_delete(event)
    end
  end

  defp replicate(%Event{} = event, opts) do
    with :ok <- ensure_destination_versioning!(event.destination_bucket),
         %Object{} = source <-
           ObjectMeta.get(event.source_bucket, event.source_key, event.source_version_id, opts),
         false <- source.is_delete_marker == true,
         {:ok, stream} <-
           Storage.get(
             event.source_bucket,
             event.source_key,
             event.source_version_id,
             nil,
             Placement.storage_opts(source)
           ) do
      replicate_object(event, source, stream)
    else
      true -> {:error, :source_is_delete_marker}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:source_unavailable, other}}
    end
  end

  defp replicate_object(%Event{} = event, %Object{} = source, stream) do
    Maxio.Lock.with_object_lock({event.destination_bucket, event.source_key}, fn ->
      case existing_replica(event, false) do
        :ok ->
          :ok

        :missing ->
          put_replica_object(event, source, stream)

        {:error, reason} ->
          {:error, reason}
      end
    end)
    |> unwrap_lock()
  end

  defp replicate_delete_marker(%Event{} = event) do
    Maxio.Lock.with_object_lock({event.destination_bucket, event.source_key}, fn ->
      case existing_replica(event, true) do
        :ok ->
          :ok

        :missing ->
          with {:ok, placement} <-
                 Placement.resolve_write(event.destination_bucket, event.source_key),
               storage_opts = Placement.storage_opts(placement),
               attrs =
                 %{replication_status: "REPLICA"}
                 |> Map.merge(Placement.attrs_from_result(placement)),
               :ok <-
                 Storage.put_delete_marker(
                   event.destination_bucket,
                   event.source_key,
                   event.source_version_id,
                   [replication_status: "REPLICA"],
                   storage_opts
                 ) do
            case Objects.insert_delete_marker_with_id(
                   event.destination_bucket,
                   event.source_key,
                   event.source_version_id,
                   attrs
                 ) do
              {:ok, _marker} -> :ok
              {:error, reason} -> {:error, reason}
            end
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
    |> unwrap_lock()
  end

  defp replicate_version_delete(%Event{} = event) do
    Maxio.Lock.with_object_lock({event.destination_bucket, event.source_key}, fn ->
      case ObjectMeta.get(event.destination_bucket, event.source_key, event.source_version_id, []) do
        %Object{replication_status: "REPLICA"} = replica ->
          delete_replica_version(event, replica)

        %Object{} ->
          {:error, :destination_version_conflict}

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          {:error, {:destination_replica_lookup_failed, reason}}
      end
    end)
    |> unwrap_lock()
  end

  defp delete_replica_version(%Event{} = event, %Object{} = replica) do
    storage_opts = Placement.storage_opts(replica)

    with :ok <-
           Storage.delete_version(
             event.destination_bucket,
             event.source_key,
             event.source_version_id,
             storage_opts
           ),
         {:ok, _target} <-
           Objects.delete_version(
             event.destination_bucket,
             event.source_key,
             event.source_version_id
           ) do
      :ok
    else
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ObjectMutation Phase 2A（C5）：PG 写权威（默认）下 replica put 全程 journal 化
  # （operation="replicate"，version_id = event.source_version_id 外部确定、直接入 plan；
  # 外层 replicate_object 已持 {dest_bucket, key} 对象锁，seam 在锁内直跑，D5；
  # existing_replica 幂等检查保留在 seam 之前）。:sidecar 写权威维持迁移前
  # 「put_version_with_id 致命提交」值语义（D1，协议化归 Phase 2B）。原「metadata 失败后
  # plain Storage.delete」回滚点随迁移删除——publish 后 metadata 失败由 seam restore（pg）
  # / ObjectCommit rollback（sidecar）收敛。Commit.run {:error, reason} 原样透出走既有
  # mark_failed/backoff：outbox at-least-once 重试 = 新 mutation_id、更高 generation 的
  # 全新 claim（R6，绝不复用旧 journal 行），覆盖写自带 durable backup，plain delete
  # 破坏幂等的旧问题随删除消失。mark_completed 与 metadata 事务维持分离（协议 §2：
  # replication outbox 行级状态机不在协议内）。
  defp put_replica_object(%Event{} = event, %Object{} = source, stream) do
    attrs = replica_attrs(source, event.destination_storage_class)
    object_meta = replica_object_meta(source, attrs)

    # 元数据 attrs 构造对两条提交路径同源（published_result 携 placement 快照）。
    committed_attrs = fn _write_info, published_result ->
      Map.merge(attrs, Placement.attrs_from_result(published_result))
    end

    around_object_commit = fn write_info, publish ->
      # around 接管 commit_opts 后 before_object_commit extra 的 object_meta merge 被
      # 绕过（C3 复审 High）：本 caller 无 before_object_commit，防御性 merge 保证源
      # 字段透传（checksum/SSE envelope 等）恒进 publish 的 sidecar 权威载体。
      committed_object_meta = Map.merge(object_meta, Map.get(write_info, :object_meta, %{}))

      case ObjectMeta.authoritative_source(:write) do
        :sidecar ->
          commit_replica_sidecar_authority(
            event,
            committed_object_meta,
            committed_attrs,
            write_info,
            publish
          )

        _pg ->
          commit_replica_pg_authority(
            event,
            committed_object_meta,
            committed_attrs,
            write_info,
            publish
          )
      end
    end

    case Storage.put(
           event.destination_bucket,
           event.source_key,
           event.source_version_id,
           stream,
           object_meta: object_meta,
           around_object_commit: around_object_commit
         ) do
      {:ok, %{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # PG 写权威：ObjectMutation seam（协议 §0.2 序列）。metadata_tx = put_version_with_id +
  # Commit.transaction_hook(journal)——journal metadata_committed 与 PG row 同一事务，
  # CAS 失败整体回滚；publish 后 metadata 失败由 seam restore 收敛（fresh 版本化 replica：
  # PG 无行、API 不可见，重试覆盖写自带 backup），绝不 plain delete。metadata_tx 内
  # rescue/catch 转 {:error, err}（协议契约：closure 不 raise），错误走 outbox
  # mark_failed/backoff。
  defp commit_replica_pg_authority(event, object_meta, committed_attrs, write_info, publish) do
    plan = %{
      bucket: event.destination_bucket,
      key: event.source_key,
      version_id: event.source_version_id,
      operation: "replicate",
      authority_mode: "pg",
      storage_opts: Placement.storage_opts(write_info),
      write_info: write_info,
      publish: fn extra_commit_opts ->
        publish.(
          Keyword.merge(
            [version_id: event.source_version_id, object_meta: object_meta],
            extra_commit_opts
          )
        )
      end,
      metadata_tx: fn journal, published_result ->
        try do
          case Objects.put_version_with_id(
                 event.destination_bucket,
                 event.source_key,
                 event.source_version_id,
                 committed_attrs.(write_info, published_result),
                 transaction_hook: ObjectMutationCommit.transaction_hook(journal)
               ) do
            {:ok, {%Object{}, :ok}} -> {:ok, :committed}
            {:error, _reason} = error -> error
          end
        rescue
          err -> {:error, err}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end
    }

    case ObjectMutationCommit.run(plan) do
      {:ok, %{published: published_result}} ->
        {:ok, Map.put(published_result, :around_object_commit_result, :replicated)}

      {:error, _reason} = error ->
        error
    end
  end

  # :sidecar 写权威（D1）：replication 迁移前即以 put_version_with_id 作致命 PG 提交
  # （无 best-effort index 分支），维持该值语义：PG 失败/异常 → {:error, err} 交
  # ObjectCommit rollback 恢复先前状态（不再 plain delete），错误面与迁移前一致
  # （outbox mark_failed/backoff 不变）。
  defp commit_replica_sidecar_authority(event, object_meta, committed_attrs, write_info, publish) do
    case publish.(version_id: event.source_version_id, object_meta: object_meta) do
      {:ok, published_result} ->
        try do
          case Objects.put_version_with_id(
                 event.destination_bucket,
                 event.source_key,
                 event.source_version_id,
                 committed_attrs.(write_info, published_result)
               ) do
            {:ok, %Object{}} ->
              accelerate_mark_committed(write_info, event)
              {:ok, Map.put(published_result, :around_object_commit_result, :replicated)}

            {:error, _reason} = error ->
              error
          end
        rescue
          err -> {:error, err}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # 与 do_put :sidecar 分支同构：metadata 提交后立即关闭进程内提交窗口——此后
  # publisher DOWN 不再触发字节回滚（sidecar 权威下 publish 已是提交点）。
  defp accelerate_mark_committed(write_info, %Event{} = event) do
    case write_info
         |> Map.fetch!(:object_commit_control)
         |> Control.mark_committed() do
      :ok ->
        :ok

      {:error, reason} ->
        Log.error("object commit finalize failed after metadata commit",
          action: :object_commit_finalize,
          bucket: event.destination_bucket,
          key: event.source_key,
          version_id: event.source_version_id,
          commit_identity: Map.fetch!(write_info, :object_commit_identity),
          reason: inspect(reason)
        )
    end
  end

  defp replica_attrs(%Object{} = source, destination_storage_class) do
    %{
      size: source.size,
      etag: source.etag,
      content_type: source.content_type,
      content_encoding: source.content_encoding,
      content_disposition: source.content_disposition,
      cache_control: source.cache_control,
      expires: source.expires,
      website_redirect_location: source.website_redirect_location,
      metadata: source.metadata || %{},
      checksum: source.checksum || %{},
      object_parts: source.object_parts || %{},
      storage_class: destination_storage_class || source.storage_class || "STANDARD",
      acl_canned: source.acl_canned || "private",
      acl_grants: source.acl_grants || %{"grants" => []},
      tags: source.tags || %{},
      sse_algorithm: source.sse_algorithm,
      sse_envelope: source.sse_envelope,
      object_lock_mode: source.object_lock_mode,
      object_lock_retain_until: source.object_lock_retain_until,
      object_lock_legal_hold: source.object_lock_legal_hold,
      restore_status: source.restore_status,
      restore_expiry: source.restore_expiry,
      replication_status: "REPLICA"
    }
  end

  defp replica_object_meta(%Object{} = source, attrs) do
    %{
      size: attrs.size,
      content_type: attrs.content_type,
      content_encoding: attrs.content_encoding,
      content_disposition: attrs.content_disposition,
      cache_control: attrs.cache_control,
      expires: attrs.expires,
      website_redirect_location: attrs.website_redirect_location,
      user_metadata: attrs.metadata || %{},
      checksum: attrs.checksum || %{},
      object_parts: attrs.object_parts || %{},
      storage_class: attrs.storage_class,
      acl_canned: attrs.acl_canned,
      acl_grants: attrs.acl_grants,
      tags: attrs.tags || %{},
      sse: sse_meta(source),
      object_lock_mode: attrs.object_lock_mode,
      object_lock_retain_until: attrs.object_lock_retain_until,
      object_lock_legal_hold: attrs.object_lock_legal_hold,
      restore_status: attrs.restore_status,
      restore_expiry: attrs.restore_expiry,
      replication_status: "REPLICA"
    }
  end

  defp sse_meta(%Object{sse_algorithm: nil}), do: nil

  defp sse_meta(%Object{sse_algorithm: algorithm, sse_envelope: envelope}) do
    %{algo: algorithm, envelope: envelope}
  end

  defp existing_replica(%Event{} = event, delete_marker?) do
    case ObjectMeta.get(event.destination_bucket, event.source_key, event.source_version_id, []) do
      %Object{} = object ->
        if object.is_delete_marker == delete_marker? and object.replication_status == "REPLICA" do
          :ok
        else
          {:error, :destination_version_conflict}
        end

      {:error, :not_found} ->
        :missing

      {:error, reason} ->
        {:error, {:destination_replica_lookup_failed, reason}}
    end
  end

  defp ensure_destination_versioning!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, %{versioning: "Enabled"}} -> :ok
      {:ok, _bucket} -> {:error, :destination_versioning_not_enabled}
      {:error, :not_found} -> {:error, :destination_bucket_not_found}
    end
  end

  defp unwrap_lock({:ok, result}), do: result
  defp unwrap_lock({:error, :locked}), do: {:error, :destination_object_locked}

  defp drain_limit(opts) do
    case Keyword.get(opts, :limit) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_drain_limit
    end
  end

  defp log_completed(%Event{} = event) do
    Log.info("replication task completed",
      action: :bucket_replication_delivery,
      bucket: event.source_bucket,
      key: event.source_key,
      version_id: event.source_version_id,
      destination_bucket: event.destination_bucket,
      event_name: event.event_name
    )
  end

  defp log_failed(%Event{} = event, reason) do
    Log.warn("replication task failed",
      action: :bucket_replication_delivery,
      bucket: event.source_bucket,
      key: event.source_key,
      version_id: event.source_version_id,
      destination_bucket: event.destination_bucket,
      event_name: event.event_name,
      reason: inspect(reason)
    )
  end
end
