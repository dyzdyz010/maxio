defmodule Maxio.S3.NotificationOutbox do
  @moduledoc """
  Durable outbox for S3 bucket notification data-plane events.

  S3 object mutations enqueue events after the object change has committed.
  Delivery workers claim rows from this table and mark success or failure. A
  failed row remains retryable after `next_attempt_at`; an expired delivering
  lease is also retryable so a crashed task does not permanently strand an
  event.
  """

  import Ecto.Query

  alias Maxio.Repo
  alias Maxio.S3.NotificationOutbox.Event

  @default_claim_limit 100
  @default_lease_ms 60_000
  @default_failure_backoff_ms 60_000
  @max_error_reason_chars 500

  @type claim_error :: :not_found | :not_retryable | term()

  @doc "Persist a notification event as pending outbox work."
  @spec enqueue(map(), keyword()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(event, opts \\ []) when is_map(event) do
    event
    |> event_to_payload()
    |> enqueue_payload(opts)
  end

  @doc """
  Persist an already-rendered notification payload as pending outbox work.

  `:id` may be supplied by sidecar notification ledger replay. Existing rows for
  the same id are returned unchanged so post-commit replay and scanner replay are
  idempotent.
  """
  @spec enqueue_payload(map(), keyword()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t() | term()}
  def enqueue_payload(payload, opts \\ []) when is_map(payload) do
    now = Keyword.get_lazy(opts, :now, &now/0)
    repo = Keyword.get(opts, :repo, Repo)
    id = Keyword.get(opts, :id)
    event = payload_to_event(payload)

    repo.transaction(fn ->
      attrs = %{
        bucket: Map.fetch!(event, :bucket),
        object_key: Map.fetch!(event, :key),
        event_name: Map.fetch!(event, :event_name),
        destination_type: get_in(event, [:destination, :type]),
        destination_arn: get_in(event, [:destination, :arn]),
        configuration_id: get_in(event, [:destination, :id]),
        status: "pending",
        attempts: 0,
        next_attempt_at: now,
        payload: payload
      }

      case existing_by_id(repo, id) do
        %Event{} = row ->
          row

        nil ->
          with {:ok, row} <- insert_payload_row(repo, attrs, id),
               {:ok, row} <- persist_payload_sequencer(repo, row) do
            row
          else
            {:error, reason} -> repo.rollback(reason)
          end
      end
    end)
  end

  @doc "Claim one retryable event by id."
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

  @doc "Claim a bounded batch of due notification events."
  @spec claim_due(keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def claim_due(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)
    limit = positive_int(Keyword.get(opts, :limit), @default_claim_limit)

    repo.transaction(fn ->
      Event
      |> due_query(now)
      |> maybe_exclude_ids(Keyword.get(opts, :exclude_ids, []))
      |> order_by([e], asc: e.next_attempt_at, asc: e.inserted_at)
      |> limit(^limit)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> repo.all()
      |> Enum.map(&claim_locked!(repo, &1, now, opts))
    end)
  rescue
    error -> {:error, {:claim_due_failed, Exception.message(error)}}
  end

  @doc "Claim the next due notification event, if one is available."
  @spec claim_next(keyword()) :: {:ok, Event.t()} | :none | {:error, term()}
  def claim_next(opts \\ []) do
    case claim_due(Keyword.put(opts, :limit, 1)) do
      {:ok, [event]} -> {:ok, event}
      {:ok, []} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Mark a claimed event delivered."
  @spec mark_delivered(Event.t(), keyword()) :: {:ok, Event.t()} | {:error, term()}
  def mark_delivered(%Event{} = event, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &now/0)
    repo = Keyword.get(opts, :repo, Repo)

    updates = [
      set: [
        status: "delivered",
        delivered_at: now,
        next_attempt_at: now,
        error_reason: nil,
        updated_at: now
      ]
    ]

    update_claimed(repo, event, updates)
  end

  @doc "Mark a claimed event failed and schedule its next retry."
  @spec mark_failed(Event.t(), term(), keyword()) ::
          {:ok, Event.t()} | {:error, term()}
  def mark_failed(%Event{} = event, reason, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &now/0)
    repo = Keyword.get(opts, :repo, Repo)
    backoff_ms = failure_backoff_ms(opts)
    next_attempt_at = DateTime.add(now, backoff_ms, :millisecond)

    updates = [
      set: [
        status: "failed",
        next_attempt_at: next_attempt_at,
        error_reason: error_reason(reason),
        updated_at: now
      ]
    ]

    update_claimed(repo, event, updates)
  end

  @doc "List recent outbox events, primarily for CLI and tests."
  @spec list(keyword()) :: [Event.t()]
  def list(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    limit = positive_int(Keyword.get(opts, :limit), 50)
    status = Keyword.get(opts, :status)

    Event
    |> maybe_filter_status(status)
    |> order_by([e], desc: e.inserted_at, desc: e.sequence, desc: e.id)
    |> limit(^limit)
    |> repo.all()
  end

  @doc "Fetch an outbox event by id."
  @spec get!(Ecto.UUID.t(), keyword()) :: Event.t()
  def get!(id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    repo.get!(Event, id)
  end

  @doc "Convert a persisted payload back into the deliverer event shape."
  @spec payload_to_event(map()) :: map()
  def payload_to_event(payload) when is_map(payload) do
    destination = value(payload, "destination")

    %{
      destination: %{
        type: value(destination, "type"),
        arn: value(destination, "arn"),
        id: value(destination, "id"),
        events: value(destination, "events") || [],
        filter: value(destination, "filter")
      },
      message: value(payload, "message") || %{},
      record: value(payload, "record") || %{},
      event_name: value(payload, "event_name"),
      bucket: value(payload, "bucket"),
      key: value(payload, "key")
    }
  end

  @doc "Convert the deliverer event shape into the durable JSON payload shape."
  @spec event_to_payload(map()) :: map()
  def event_to_payload(event) when is_map(event) do
    destination = Map.fetch!(event, :destination)

    %{
      "destination" => %{
        "type" => Map.get(destination, :type),
        "arn" => Map.get(destination, :arn),
        "id" => Map.get(destination, :id),
        "events" => Map.get(destination, :events) || [],
        "filter" => Map.get(destination, :filter)
      },
      "message" => Map.fetch!(event, :message),
      "record" => Map.fetch!(event, :record),
      "event_name" => Map.fetch!(event, :event_name),
      "bucket" => Map.fetch!(event, :bucket),
      "key" => Map.fetch!(event, :key)
    }
  end

  @doc "Return an operator-friendly row view without dumping full payloads."
  @spec to_view(Event.t()) :: map()
  def to_view(%Event{} = event) do
    %{
      id: event.id,
      bucket: event.bucket,
      key: event.object_key,
      event_name: event.event_name,
      destination_type: event.destination_type,
      destination_arn: event.destination_arn,
      configuration_id: event.configuration_id,
      sequence: event.sequence,
      status: event.status,
      attempts: event.attempts,
      next_attempt_at: event.next_attempt_at,
      last_attempted_at: event.last_attempted_at,
      delivered_at: event.delivered_at,
      error_reason: event.error_reason,
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
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

  defp existing_by_id(_repo, nil), do: nil
  defp existing_by_id(repo, id) when is_binary(id), do: repo.get(Event, id)

  defp insert_payload_row(repo, attrs, nil) do
    %Event{}
    |> Event.changeset(attrs)
    |> repo.insert()
  end

  defp insert_payload_row(repo, attrs, id) when is_binary(id) do
    %Event{id: id}
    |> Event.changeset(attrs)
    |> repo.insert(on_conflict: :nothing, conflict_target: [:id], returning: true)
    |> case do
      {:ok, %Event{inserted_at: nil}} -> {:ok, repo.get!(Event, id)}
      {:ok, %Event{} = row} -> {:ok, row}
      other -> other
    end
  end

  defp persist_payload_sequencer(repo, %Event{} = row) do
    payload = put_payload_sequencer(row.payload, sequence_to_hex(row.sequence))

    row
    |> Event.changeset(%{payload: payload})
    |> repo.update()
  end

  defp put_payload_sequencer(payload, sequencer) when is_map(payload) do
    payload
    |> update_in(["message"], &put_message_sequencer(&1, sequencer))
    |> update_in(["record"], &put_record_sequencer(&1, sequencer))
  end

  defp put_message_sequencer(%{"Records" => [record]} = message, sequencer) do
    Map.put(message, "Records", [put_record_sequencer(record, sequencer)])
  end

  defp put_message_sequencer(%{"detail" => %{"object" => object} = detail} = message, sequencer) do
    Map.put(message, "detail", Map.put(detail, "object", Map.put(object, "sequencer", sequencer)))
  end

  defp put_message_sequencer(message, _sequencer), do: message

  defp put_record_sequencer(%{"s3" => %{"object" => object} = s3} = record, sequencer) do
    Map.put(record, "s3", Map.put(s3, "object", Map.put(object, "sequencer", sequencer)))
  end

  defp put_record_sequencer(%{"detail" => %{"object" => object} = detail} = record, sequencer) do
    Map.put(record, "detail", Map.put(detail, "object", Map.put(object, "sequencer", sequencer)))
  end

  defp put_record_sequencer(record, _sequencer), do: record

  defp sequence_to_hex(sequence) when is_integer(sequence) and sequence > 0 do
    sequence
    |> Integer.to_string(16)
    |> String.upcase()
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [e], e.status == ^status)

  defp maybe_exclude_ids(query, []), do: query
  defp maybe_exclude_ids(query, ids) when is_list(ids), do: where(query, [e], e.id not in ^ids)
  defp maybe_exclude_ids(query, _ids), do: query

  defp failure_backoff_ms(opts) do
    case Keyword.get(opts, :failure_backoff_ms) do
      value when is_integer(value) and value >= 0 ->
        value

      _other ->
        :maxio
        |> Application.get_env(:notification_delivery, [])
        |> Keyword.get(:failure_backoff_ms, @default_failure_backoff_ms)
        |> non_negative_int(@default_failure_backoff_ms)
    end
  end

  defp error_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: @max_error_reason_chars)
    |> String.slice(0, @max_error_reason_chars)
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, atom_key(key))
  defp value(_map, _key), do: nil

  defp atom_key("destination"), do: :destination
  defp atom_key("message"), do: :message
  defp atom_key("record"), do: :record
  defp atom_key("event_name"), do: :event_name
  defp atom_key("bucket"), do: :bucket
  defp atom_key("key"), do: :key
  defp atom_key("type"), do: :type
  defp atom_key("arn"), do: :arn
  defp atom_key("id"), do: :id
  defp atom_key("events"), do: :events
  defp atom_key("filter"), do: :filter
  defp atom_key(_key), do: :__maxio_unknown_key__

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value, default), do: default

  defp now, do: DateTime.utc_now()
end
