defmodule Maxio.S3.ReplicationOutbox do
  @moduledoc """
  Durable outbox for S3 bucket replication data-plane tasks.

  Object handlers enqueue replication work after the source object change has
  committed. Drain workers claim rows from this table and copy source bytes to
  destination buckets idempotently.
  """

  import Ecto.Query

  alias Maxio.{ObjectReplicationStatusSidecar, Objects}
  alias Maxio.Repo
  alias Maxio.S3.Log
  alias Maxio.S3.ReplicationOutbox.Event

  @default_claim_limit 100
  @default_lease_ms 60_000
  @default_failure_backoff_ms 60_000
  @max_error_reason_chars 500

  @type claim_error :: :not_found | :not_retryable | term()

  @spec enqueue(map(), keyword()) :: {:ok, Event.t()} | {:error, term()}
  def enqueue(task, opts \\ []) when is_map(task) do
    now = Keyword.get_lazy(opts, :now, &now/0)
    repo = Keyword.get(opts, :repo, Repo)
    attrs = task_attrs(task, now)

    %Event{}
    |> Event.changeset(attrs)
    |> repo.insert(
      on_conflict: :nothing,
      conflict_target: [
        :source_bucket,
        :source_key,
        :source_version_id,
        :destination_bucket,
        :event_name
      ],
      returning: true
    )
    |> case do
      {:ok, %Event{inserted_at: nil}} -> {:ok, existing_task!(repo, attrs)}
      {:ok, %Event{} = event} -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:enqueue_failed, Exception.message(error)}}
  end

  @spec enqueue_many([map()], keyword()) :: [Event.t()]
  def enqueue_many(tasks, opts \\ []) when is_list(tasks) do
    Enum.map(tasks, fn task ->
      case enqueue(task, opts) do
        {:ok, event} -> event
        {:error, reason} -> raise "replication outbox enqueue failed: #{inspect(reason)}"
      end
    end)
  end

  @doc "Return the durable outbox row for a replication task key, if it already exists."
  @spec existing(map(), keyword()) :: Event.t() | nil
  def existing(task, opts \\ []) when is_map(task) do
    repo = Keyword.get(opts, :repo, Repo)

    Event
    |> task_key_query(task_key_attrs(task))
    |> repo.one()
  end

  @doc """
  Return an equivalent existing outbox row for idempotent backfill.

  S3 object-created event names (`Put`, `Copy`, `CompleteMultipartUpload`,
  `Post`, and future variants) all describe the same source object version for
  replication delivery. Backfill therefore treats any `s3:ObjectCreated:*` row
  for the same source version and destination as already queued.
  """
  @spec existing_equivalent(map(), keyword()) :: Event.t() | nil
  def existing_equivalent(task, opts \\ []) when is_map(task) do
    repo = Keyword.get(opts, :repo, Repo)
    attrs = task_key_attrs(task)

    Event
    |> source_destination_query(attrs)
    |> equivalent_event_query(attrs.event_name)
    |> order_by([e], asc: e.inserted_at, asc: e.id)
    |> limit(1)
    |> repo.one()
  end

  @spec claim(Ecto.UUID.t(), keyword()) :: {:ok, Event.t()} | {:error, claim_error()}
  def claim(id, opts \\ []) when is_binary(id) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)

    repo.transaction(fn ->
      case repo.one(from e in Event, where: e.id == ^id, lock: "FOR UPDATE") do
        nil ->
          repo.rollback(:not_found)

        %Event{} = event ->
          if retryable?(event, now) do
            claim_locked!(repo, event, now, opts)
          else
            repo.rollback(:not_retryable)
          end
      end
    end)
  rescue
    error -> {:error, {:claim_failed, Exception.message(error)}}
  end

  @spec claim_due(keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def claim_due(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)
    limit = positive_int(Keyword.get(opts, :limit), @default_claim_limit)

    repo.transaction(fn ->
      Event
      |> due_query(now)
      |> order_by([e], asc: e.next_attempt_at, asc: e.inserted_at)
      |> limit(^limit)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> repo.all()
      |> Enum.map(&claim_locked!(repo, &1, now, opts))
    end)
  rescue
    error -> {:error, {:claim_due_failed, Exception.message(error)}}
  end

  @spec claim_next(keyword()) :: {:ok, Event.t()} | :none | {:error, term()}
  def claim_next(opts \\ []) do
    case claim_due(Keyword.put(opts, :limit, 1)) do
      {:ok, [event]} -> {:ok, event}
      {:ok, []} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  @spec mark_completed(Event.t(), keyword()) :: {:ok, Event.t()} | {:error, term()}
  def mark_completed(%Event{} = event, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &now/0)
    repo = Keyword.get(opts, :repo, Repo)

    update_claimed(repo, event,
      set: [
        status: "completed",
        completed_at: now,
        next_attempt_at: now,
        error_reason: nil,
        updated_at: now
      ]
    )
  end

  @spec mark_completed_with_source_status(Event.t(), keyword()) ::
          {:ok, Event.t()} | {:error, term()}
  def mark_completed_with_source_status(%Event{} = event, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &now/0)
    repo = Keyword.get(opts, :repo, Repo)

    repo.transaction(fn ->
      lock_source_events!(repo, event)

      case update_claimed(repo, event,
             set: [
               status: "completed",
               completed_at: now,
               next_attempt_at: now,
               error_reason: nil,
               updated_at: now
             ]
           ) do
        {:ok, updated} ->
          put_source_replication_status!(repo, updated, opts)
          updated

        {:error, reason} ->
          repo.rollback(reason)
      end
    end)
  rescue
    error -> {:error, {:mark_completed_failed, Exception.message(error)}}
  end

  @spec mark_failed(Event.t(), term(), keyword()) :: {:ok, Event.t()} | {:error, term()}
  def mark_failed(%Event{} = event, reason, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &now/0)
    repo = Keyword.get(opts, :repo, Repo)
    next_attempt_at = DateTime.add(now, failure_backoff_ms(opts), :millisecond)

    update_claimed(repo, event,
      set: [
        status: "failed",
        next_attempt_at: next_attempt_at,
        error_reason: error_reason(reason),
        updated_at: now
      ]
    )
  end

  @spec mark_failed_with_source_status(Event.t(), term(), keyword()) ::
          {:ok, Event.t()} | {:error, term()}
  def mark_failed_with_source_status(%Event{} = event, reason, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &now/0)
    repo = Keyword.get(opts, :repo, Repo)
    next_attempt_at = DateTime.add(now, failure_backoff_ms(opts), :millisecond)

    repo.transaction(fn ->
      lock_source_events!(repo, event)

      case update_claimed(repo, event,
             set: [
               status: "failed",
               next_attempt_at: next_attempt_at,
               error_reason: error_reason(reason),
               updated_at: now
             ]
           ) do
        {:ok, updated} ->
          put_source_replication_status!(repo, updated, opts)
          updated

        {:error, reason} ->
          repo.rollback(reason)
      end
    end)
  rescue
    error -> {:error, {:mark_failed_failed, Exception.message(error)}}
  end

  @doc """
  Refresh the source object's replication status from all outbox rows for the
  same source version.

  Backfill and repair jobs call this after synthesizing or discovering outbox
  rows so object reads expose the same PENDING/FAILED/COMPLETED aggregate as
  the online write path.
  """
  @spec refresh_source_status(Event.t(), keyword()) :: :ok | {:error, term()}
  def refresh_source_status(%Event{} = event, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.transaction(fn ->
           refresh_source_status!(event, opts)
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:refresh_source_status_failed, Exception.message(error)}}
  end

  @doc """
  Refresh source replication status inside the caller's transaction.

  Callers that create multiple outbox rows for one source version use this after
  all rows exist, so the aggregate status is computed over the complete task
  set rather than a partially-enqueued subset.
  """
  @spec refresh_source_status!(Event.t(), keyword()) :: :ok
  def refresh_source_status!(%Event{} = event, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    lock_source_events!(repo, event)
    put_source_replication_status!(repo, event, opts)
    :ok
  end

  @spec list(keyword()) :: [Event.t()]
  def list(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    limit = positive_int(Keyword.get(opts, :limit), 50)
    status = Keyword.get(opts, :status)

    Event
    |> maybe_filter_status(status)
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^limit)
    |> repo.all()
  end

  @spec source_status(String.t(), String.t(), String.t(), keyword()) ::
          :pending | :failed | :completed | :none
  def source_status(bucket, key, version_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    statuses =
      Event
      |> where(
        [e],
        e.source_bucket == ^bucket and e.source_key == ^key and e.source_version_id == ^version_id
      )
      |> select([e], e.status)
      |> repo.all()

    cond do
      statuses == [] -> :none
      Enum.any?(statuses, &(&1 in ["pending", "delivering"])) -> :pending
      Enum.any?(statuses, &(&1 == "failed")) -> :failed
      true -> :completed
    end
  end

  @spec to_view(Event.t()) :: map()
  def to_view(%Event{} = event) do
    %{
      id: event.id,
      source_bucket: event.source_bucket,
      source_key: event.source_key,
      source_version_id: event.source_version_id,
      event_name: event.event_name,
      destination_bucket: event.destination_bucket,
      rule_id: event.rule_id,
      destination_storage_class: event.destination_storage_class,
      source_etag: event.source_etag,
      source_size: event.source_size,
      status: event.status,
      attempts: event.attempts,
      next_attempt_at: event.next_attempt_at,
      last_attempted_at: event.last_attempted_at,
      completed_at: event.completed_at,
      error_reason: event.error_reason,
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
  end

  defp task_attrs(task, now) do
    %{
      source_bucket: value!(task, :source_bucket),
      source_key: value!(task, :source_key),
      source_version_id: value!(task, :source_version_id),
      event_name: value!(task, :event_name),
      destination_bucket: value!(task, :destination_bucket),
      rule_id: value(task, :rule_id),
      destination_storage_class: value(task, :destination_storage_class),
      source_etag: value(task, :source_etag),
      source_size: value(task, :source_size),
      status: "pending",
      attempts: 0,
      next_attempt_at: now,
      payload: payload(task)
    }
  end

  defp payload(task) do
    %{
      "source_bucket" => value!(task, :source_bucket),
      "source_key" => value!(task, :source_key),
      "source_version_id" => value!(task, :source_version_id),
      "event_name" => value!(task, :event_name),
      "destination_bucket" => value!(task, :destination_bucket),
      "rule_id" => value(task, :rule_id),
      "destination_storage_class" => value(task, :destination_storage_class),
      "source_etag" => value(task, :source_etag),
      "source_size" => value(task, :source_size)
    }
  end

  defp existing_task!(repo, attrs) do
    repo.one!(
      Event
      |> task_key_query(attrs)
    )
  end

  defp task_key_attrs(task) do
    %{
      source_bucket: value!(task, :source_bucket),
      source_key: value!(task, :source_key),
      source_version_id: value!(task, :source_version_id),
      destination_bucket: value!(task, :destination_bucket),
      event_name: value!(task, :event_name)
    }
  end

  defp task_key_query(query, attrs) do
    where(
      query,
      [e],
      e.source_bucket == ^attrs.source_bucket and
        e.source_key == ^attrs.source_key and
        e.source_version_id == ^attrs.source_version_id and
        e.destination_bucket == ^attrs.destination_bucket and
        e.event_name == ^attrs.event_name
    )
  end

  defp source_destination_query(query, attrs) do
    where(
      query,
      [e],
      e.source_bucket == ^attrs.source_bucket and
        e.source_key == ^attrs.source_key and
        e.source_version_id == ^attrs.source_version_id and
        e.destination_bucket == ^attrs.destination_bucket
    )
  end

  defp equivalent_event_query(query, "s3:ObjectCreated:" <> _suffix) do
    where(query, [e], like(e.event_name, "s3:ObjectCreated:%"))
  end

  defp equivalent_event_query(query, event_name) do
    where(query, [e], e.event_name == ^event_name)
  end

  defp claim_locked!(repo, event, now, opts) do
    lease_ms = positive_int(Keyword.get(opts, :lease_ms), @default_lease_ms)

    event
    |> Event.changeset(%{
      status: "delivering",
      attempts: event.attempts + 1,
      last_attempted_at: now,
      next_attempt_at: DateTime.add(now, lease_ms, :millisecond)
    })
    |> repo.update!()
  end

  defp update_claimed(repo, %Event{id: id, attempts: attempts}, updates) do
    {count, _rows} =
      Event
      |> where([e], e.id == ^id and e.status == "delivering" and e.attempts == ^attempts)
      |> repo.update_all(updates)

    case count do
      1 -> {:ok, repo.get!(Event, id)}
      0 -> {:error, :stale_claim}
    end
  rescue
    error -> {:error, {:claim_update_failed, Exception.message(error)}}
  end

  defp lock_source_events!(repo, %Event{} = event) do
    Event
    |> where(
      [e],
      e.source_bucket == ^event.source_bucket and e.source_key == ^event.source_key and
        e.source_version_id == ^event.source_version_id
    )
    |> order_by([e], asc: e.id)
    |> lock("FOR UPDATE")
    |> repo.all()

    :ok
  end

  defp put_source_replication_status!(repo, %Event{} = event, opts) do
    status =
      event.source_bucket
      |> source_status(event.source_key, event.source_version_id, repo: repo)
      |> source_object_status()

    case Objects.put_replication_status(
           event.source_bucket,
           event.source_key,
           event.source_version_id,
           status,
           repo: repo
         ) do
      :ok ->
        mirror_source_replication_status!(repo, event, status, opts)

      {:error, reason} ->
        repo.rollback({:source_replication_status_update_failed, reason})
    end
  end

  defp mirror_source_replication_status!(_repo, _event, nil, _opts), do: :ok

  defp mirror_source_replication_status!(repo, %Event{} = event, status, opts) do
    case ObjectReplicationStatusSidecar.update(
           event.source_bucket,
           event.source_key,
           event.source_version_id,
           status,
           sidecar_update_opts(opts)
         ) do
      {:ok, generation} ->
        case Objects.put_replication_status(
               event.source_bucket,
               event.source_key,
               event.source_version_id,
               status,
               repo: repo,
               generation: generation
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            repo.rollback({:source_replication_status_generation_sync_failed, reason})
        end

      {:error, reason} ->
        log_source_replication_status_mirror_failed(event, status, reason)
        :ok
    end
  rescue
    error ->
      log_source_replication_status_mirror_failed(event, status, error)
      :ok
  catch
    kind, reason ->
      log_source_replication_status_mirror_failed(event, status, {kind, reason})
      :ok
  end

  defp sidecar_update_opts(opts) do
    Keyword.take(opts, [
      :topology,
      :transport,
      :fsync,
      :rename_fun,
      :drives,
      :data_shards,
      :parity_shards,
      :block_size,
      :placement_set_id
    ])
  end

  defp log_source_replication_status_mirror_failed(%Event{} = event, status, reason) do
    Log.warn("sidecar replication status mirror failed (PG remains authoritative)",
      action: :bucket_replication_delivery,
      bucket: event.source_bucket,
      key: event.source_key,
      version_id: event.source_version_id,
      destination_bucket: event.destination_bucket,
      event_name: event.event_name,
      replication_status: status,
      reason: inspect(reason)
    )
  end

  defp source_object_status(:completed), do: "COMPLETED"
  defp source_object_status(:failed), do: "FAILED"
  defp source_object_status(:pending), do: "PENDING"
  defp source_object_status(:none), do: nil

  defp due_query(query, now) do
    where(
      query,
      [e],
      (e.status in ["pending", "failed"] and e.next_attempt_at <= ^now) or
        (e.status == "delivering" and e.next_attempt_at <= ^now)
    )
  end

  defp retryable?(%Event{status: status, next_attempt_at: next_attempt_at}, now)
       when status in ["pending", "failed", "delivering"] do
    DateTime.compare(next_attempt_at, now) != :gt
  end

  defp retryable?(_event, _now), do: false

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [e], e.status == ^status)

  defp failure_backoff_ms(opts) do
    case Keyword.get(opts, :failure_backoff_ms) do
      value when is_integer(value) and value >= 0 ->
        value

      _other ->
        :maxio
        |> Application.get_env(:replication_delivery, [])
        |> Keyword.get(:failure_backoff_ms, @default_failure_backoff_ms)
        |> non_negative_int(@default_failure_backoff_ms)
    end
  end

  defp error_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: @max_error_reason_chars)
    |> String.slice(0, @max_error_reason_chars)
  end

  defp value!(map, key) do
    value(map, key) || raise ArgumentError, "missing replication outbox field #{key}"
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value, default), do: default

  defp now, do: DateTime.utc_now()
end
