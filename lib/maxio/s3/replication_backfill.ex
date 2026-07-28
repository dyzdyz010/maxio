defmodule Maxio.S3.ReplicationBackfill do
  @moduledoc """
  Operator-driven replication backfill for existing source object versions.

  This is MaxIO's local equivalent of an S3 Batch Replication run: it scans the
  source metadata index in bounded chunks, reuses the normal replication rule
  matcher, and persists idempotent tasks into the durable replication outbox.
  It never copies bytes itself; `Maxio.S3.ReplicationDelivery` remains the only
  data-plane delivery path.
  """

  import Ecto.Query

  alias Maxio.Buckets
  alias Maxio.Objects.Object
  alias Maxio.Repo
  alias Maxio.S3.{Log, Replication, ReplicationDelivery, ReplicationOutbox}
  alias Maxio.S3.ReplicationOutbox.Event

  @created_event "s3:ObjectCreated:Put"
  @delete_marker_event "s3:ObjectRemoved:DeleteMarkerCreated"
  @default_limit 1_000
  @max_limit 10_000

  @type summary :: %{
          source_bucket: String.t(),
          dry_run: boolean(),
          limit: pos_integer(),
          key_marker: String.t() | nil,
          version_id_marker: String.t() | nil,
          scanned_versions: non_neg_integer(),
          skipped_replica_versions: non_neg_integer(),
          skipped_no_rule_versions: non_neg_integer(),
          matched_versions: non_neg_integer(),
          matched_tasks: non_neg_integer(),
          existing_tasks: non_neg_integer(),
          would_enqueue_tasks: non_neg_integer(),
          enqueued_tasks: non_neg_integer(),
          refreshed_source_statuses: non_neg_integer(),
          is_truncated: boolean(),
          next_key_marker: String.t() | nil,
          next_version_id_marker: String.t() | nil
        }

  @doc """
  Scan a bounded source bucket chunk and optionally enqueue matching existing
  object versions for replication.

  Required option:

    * `:source_bucket` - source bucket name

  Useful options:

    * `:dry_run` - defaults to `true`; when false, outbox rows are inserted
    * `:limit` - source versions to scan in this chunk; default 1000, max 10000
    * `:key_marker` / `:version_id_marker` - resume after a prior truncated run
    * `:repo` - test override

  Backfill always enumerates source versions by `key`, then source commit order
  (`inserted_at`, `id`). The public resume marker is still key + version id;
  the marker row is read back to recover its stable commit-order cursor.
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts) when is_list(opts) do
    source_bucket = Keyword.get(opts, :source_bucket)
    dry_run = Keyword.get(opts, :dry_run, true)
    limit = normalize_limit(Keyword.get(opts, :limit))
    key_marker = blank_to_nil(Keyword.get(opts, :key_marker))
    version_id_marker = blank_to_nil(Keyword.get(opts, :version_id_marker))
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with :ok <- validate_source_bucket(source_bucket),
         :ok <- validate_markers(key_marker, version_id_marker),
         {:ok, _bucket} <- lookup_source_bucket(source_bucket),
         {:ok, _config} <- lookup_replication_config(source_bucket),
         {:ok, {versions, truncated?, next_key_marker, next_version_id_marker}} <-
           source_versions(source_bucket, key_marker, version_id_marker, limit, repo) do
      state =
        versions
        |> Enum.reduce_while(
          {:ok,
           initial_state(
             source_bucket,
             dry_run,
             limit,
             key_marker,
             version_id_marker,
             truncated?,
             next_key_marker,
             next_version_id_marker,
             now,
             opts
           )},
          fn
            %Object{} = object, {:ok, acc} ->
              case process_version(object, acc) do
                {:ok, next} -> {:cont, {:ok, next}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
          end
        )

      case state do
        {:ok, state} ->
          summary = public_summary(state)
          log_summary(summary)
          {:ok, summary}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp process_version(%Object{replication_status: "REPLICA"} = object, state) do
    object
    |> count_version(state)
    |> increment(:skipped_replica_versions)
    |> ok()
  end

  defp process_version(%Object{} = object, state) do
    state = count_version(object, state)
    tasks = replication_tasks(object)

    cond do
      tasks == [] ->
        state
        |> increment(:skipped_no_rule_versions)
        |> ok()

      true ->
        state =
          state
          |> increment(:matched_versions)
          |> add(:matched_tasks, length(tasks))

        process_tasks(tasks, state)
    end
  end

  defp process_tasks(tasks, %{dry_run: true} = state) do
    Enum.reduce(tasks, state, fn task, acc ->
      case ReplicationOutbox.existing_equivalent(task, repo: acc.repo) do
        %Event{} -> increment(acc, :existing_tasks)
        nil -> increment(acc, :would_enqueue_tasks)
      end
    end)
    |> ok()
  end

  defp process_tasks(tasks, %{repo: repo} = state) do
    case repo.transaction(fn ->
           state =
             Enum.reduce(tasks, state, fn task, acc ->
               process_write_task!(task, acc)
             end)

           case Map.get(state, :source_status_event) do
             %Event{} = event ->
               ReplicationOutbox.refresh_source_status!(
                 event,
                 state.opts |> Keyword.put(:repo, repo)
               )

               state
               |> increment(:refreshed_source_statuses)
               |> Map.delete(:source_status_event)

             nil ->
               state
           end
         end) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_write_task!(task, %{repo: repo} = state) do
    case ReplicationOutbox.existing_equivalent(task, repo: repo) do
      %Event{} = event ->
        state
        |> increment(:existing_tasks)
        |> remember_status_event(event)

      nil ->
        enqueue_write_task!(task, state)
    end
  end

  defp enqueue_write_task!(task, %{repo: repo} = state) do
    enqueue_opts =
      state.opts
      |> Keyword.put(:repo, repo)
      |> Keyword.put(:now, DateTime.add(state.base_now, state.task_sequence, :microsecond))

    case ReplicationOutbox.enqueue(task, enqueue_opts) do
      {:ok, %Event{} = event} ->
        state
        |> increment(:enqueued_tasks)
        |> increment_task_sequence()
        |> remember_status_event(event)

      {:error, reason} ->
        repo.rollback({:replication_backfill_enqueue_failed, task_key(task), reason})
    end
  end

  defp remember_status_event(%{source_status_event: %Event{}} = state, _event), do: state

  defp remember_status_event(state, %Event{} = event) do
    Map.put(state, :source_status_event, event)
  end

  defp replication_tasks(%Object{} = object) do
    event_name =
      if object.is_delete_marker do
        @delete_marker_event
      else
        @created_event
      end

    ReplicationDelivery.pending_tasks(event_name, %{
      bucket: object.bucket_name,
      key: object.key,
      version_id: object.version_id,
      tags: object.tags || %{},
      etag: object.etag,
      size: object.size
    })
  end

  defp source_versions(bucket, key_marker, version_id_marker, limit, repo) do
    query =
      from o in Object,
        where: o.bucket_name == ^bucket,
        order_by: [
          asc: o.key,
          asc: o.inserted_at,
          asc: o.id
        ],
        limit: ^(limit + 1)

    with {:ok, query} <- maybe_apply_marker(query, bucket, key_marker, version_id_marker, repo) do
      rows = repo.all(query)
      {versions, rest} = Enum.split(rows, limit)
      truncated? = rest != []

      result =
        case {truncated?, List.last(versions)} do
          {true, %Object{} = last} -> {versions, true, last.key, last.version_id}
          _other -> {versions, false, nil, nil}
        end

      {:ok, result}
    end
  end

  defp maybe_apply_marker(query, _bucket, nil, nil, _repo), do: {:ok, query}

  defp maybe_apply_marker(query, bucket, key_marker, version_id_marker, repo) do
    case marker_object(bucket, key_marker, version_id_marker, repo) do
      %Object{} = marker ->
        query =
          where(
            query,
            [o],
            o.key > ^marker.key or
              (o.key == ^marker.key and
                 (o.inserted_at > ^marker.inserted_at or
                    (o.inserted_at == ^marker.inserted_at and o.id > ^marker.id)))
          )

        {:ok, query}

      nil ->
        {:error, :invalid_backfill_marker}
    end
  end

  defp marker_object(bucket, key, version_id, repo) do
    Object
    |> where([o], o.bucket_name == ^bucket and o.key == ^key and o.version_id == ^version_id)
    |> repo.one()
  end

  defp initial_state(
         source_bucket,
         dry_run,
         limit,
         key_marker,
         version_id_marker,
         truncated?,
         next_key_marker,
         next_version_id_marker,
         now,
         opts
       ) do
    %{
      source_bucket: source_bucket,
      dry_run: dry_run,
      limit: limit,
      key_marker: key_marker,
      version_id_marker: version_id_marker,
      scanned_versions: 0,
      skipped_replica_versions: 0,
      skipped_no_rule_versions: 0,
      matched_versions: 0,
      matched_tasks: 0,
      existing_tasks: 0,
      would_enqueue_tasks: 0,
      enqueued_tasks: 0,
      refreshed_source_statuses: 0,
      is_truncated: truncated?,
      next_key_marker: next_key_marker,
      next_version_id_marker: next_version_id_marker,
      repo: Keyword.get(opts, :repo, Repo),
      base_now: now,
      task_sequence: 0,
      opts: opts
    }
  end

  defp public_summary(state) do
    state
    |> Map.take([
      :source_bucket,
      :dry_run,
      :limit,
      :key_marker,
      :version_id_marker,
      :scanned_versions,
      :skipped_replica_versions,
      :skipped_no_rule_versions,
      :matched_versions,
      :matched_tasks,
      :existing_tasks,
      :would_enqueue_tasks,
      :enqueued_tasks,
      :refreshed_source_statuses,
      :is_truncated,
      :next_key_marker,
      :next_version_id_marker
    ])
  end

  defp validate_source_bucket(bucket) when is_binary(bucket) and bucket != "", do: :ok
  defp validate_source_bucket(_bucket), do: {:error, :source_bucket_required}

  defp validate_markers(nil, nil), do: :ok
  defp validate_markers(key, version_id) when is_binary(key) and is_binary(version_id), do: :ok
  defp validate_markers(_key, _version_id), do: {:error, :key_and_version_markers_required}

  defp lookup_source_bucket(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, %{versioning: "Enabled"} = bucket} -> {:ok, bucket}
      {:ok, _bucket} -> {:error, :source_bucket_versioning_not_enabled}
      {:error, :not_found} -> {:error, :source_bucket_not_found}
    end
  end

  defp lookup_replication_config(bucket) do
    case Replication.get_config(bucket) do
      {:ok, config} -> {:ok, config}
      :none -> {:error, :replication_configuration_not_found}
    end
  end

  defp normalize_limit(nil), do: @default_limit

  defp normalize_limit(limit) when is_integer(limit) and limit > 0 and limit <= @max_limit,
    do: limit

  defp normalize_limit(limit) when is_integer(limit) and limit > @max_limit, do: @max_limit
  defp normalize_limit(_limit), do: @default_limit

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp count_version(_object, state), do: increment(state, :scanned_versions)
  defp increment(state, key), do: Map.update!(state, key, &(&1 + 1))
  defp add(state, key, value), do: Map.update!(state, key, &(&1 + value))
  defp increment_task_sequence(state), do: Map.update!(state, :task_sequence, &(&1 + 1))
  defp ok(state), do: {:ok, state}

  defp task_key(task) do
    %{
      source_bucket: Map.get(task, :source_bucket) || Map.get(task, "source_bucket"),
      source_key: Map.get(task, :source_key) || Map.get(task, "source_key"),
      source_version_id: Map.get(task, :source_version_id) || Map.get(task, "source_version_id"),
      destination_bucket:
        Map.get(task, :destination_bucket) || Map.get(task, "destination_bucket"),
      event_name: Map.get(task, :event_name) || Map.get(task, "event_name")
    }
  end

  defp log_summary(summary) do
    Log.info("replication backfill scanned source bucket",
      action: :bucket_replication_backfill,
      bucket: summary.source_bucket,
      dry_run: summary.dry_run,
      scanned_versions: summary.scanned_versions,
      matched_tasks: summary.matched_tasks,
      existing_tasks: summary.existing_tasks,
      would_enqueue_tasks: summary.would_enqueue_tasks,
      enqueued_tasks: summary.enqueued_tasks,
      is_truncated: summary.is_truncated
    )
  end
end
