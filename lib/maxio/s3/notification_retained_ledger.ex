defmodule Maxio.S3.NotificationRetainedLedger do
  @moduledoc """
  Retained bucket notification ledger replay/prune helper.

  Per-version `notification_outbox` entries are still written into object
  sidecars for normal scanner replay. This module adds an object-key retained
  carrier outside the object/version tree so null-version overwrites and hard
  deletes cannot erase post-commit replay evidence before it reaches the PG
  notification outbox.
  """

  alias Maxio.{ObjectMeta, Storage}
  alias Maxio.Objects.Object
  alias Maxio.S3.{Error, Log, NotificationDelivery}

  @type summary :: %{
          scanned: non_neg_integer(),
          replayed: non_neg_integer(),
          pruned: non_neg_integer(),
          aborted: non_neg_integer(),
          ambiguous: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc "Predicate for a mutation that commits by making a version visible."
  @spec version_present(String.t(), keyword()) :: map()
  def version_present(version_id, opts \\ []) do
    %{
      "type" => "version_present",
      "version_id" => version_id
    }
    |> maybe_put("entry_type", Keyword.get(opts, :entry_type))
    |> maybe_put("etag", Keyword.get(opts, :etag))
    |> maybe_put("size", Keyword.get(opts, :size))
  end

  @doc "Predicate for a mutation that commits by removing a version."
  @spec version_absent(String.t(), map()) :: map()
  def version_absent(version_id, target) do
    %{
      "type" => "version_absent",
      "version_id" => version_id,
      "target" => target_proof(target)
    }
  end

  @doc """
  Predicate for RestoreObject metadata-only commits.

  The version exists before and after RestoreObject, so `version_present/2` is
  not sufficient evidence. This transition is committed only when the sidecar
  read view has the expected post-restore metadata; if it still has the
  pre-restore metadata, the prepared notification is pruned as aborted.
  """
  @spec restore_state_transition(String.t(), map() | struct(), map(), keyword()) :: map()
  def restore_state_transition(version_id, before_state, after_state, opts \\ []) do
    %{
      "type" => "restore_state_transition",
      "version_id" => version_id,
      "before" => restore_state_proof(before_state),
      "after" => restore_state_proof(after_state)
    }
    |> maybe_put("entry_type", Keyword.get(opts, :entry_type))
    |> maybe_put("etag", Keyword.get(opts, :etag))
    |> maybe_put("size", Keyword.get(opts, :size))
  end

  @doc """
  Wrap sidecar notification ledger entries into retained ledger entries.

  The retained entry preserves the stable sidecar id/payload so replay remains
  idempotent through `notification_outbox.id`.
  """
  @spec entries([map()] | nil, keyword()) :: [map()]
  def entries(nil, _opts), do: []
  def entries([], _opts), do: []

  def entries(sidecar_entries, opts) when is_list(sidecar_entries) do
    bucket = Keyword.fetch!(opts, :bucket)
    key = Keyword.fetch!(opts, :key)
    operation = Keyword.fetch!(opts, :operation)
    predicate = Keyword.fetch!(opts, :predicate)
    request_id = Keyword.get(opts, :request_id)

    Enum.map(sidecar_entries, fn %{"id" => id, "payload" => payload} ->
      %{
        "id" => id,
        "bucket" => bucket,
        "key" => key,
        "event_name" => Map.get(payload, "event_name"),
        "operation" => to_string(operation),
        "payload" => payload,
        "commit_predicate" => predicate,
        "request_id" => request_id,
        "created_at_ns" => System.os_time(:nanosecond)
      }
      |> maybe_put("storage_opts", storage_opts_payload(Keyword.get(opts, :storage_opts, [])))
    end)
  end

  @doc "Persist retained ledger entries before the object/version mutation commits."
  @spec persist!(String.t(), String.t(), [map()], keyword()) :: :ok
  def persist!(_bucket, _key, [], _opts), do: :ok

  def persist!(bucket, key, entries, opts) when is_list(entries) do
    case Storage.put_notification_ledgers(bucket, key, entries, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Log.error("bucket notification retained ledger persist failed",
          action: :bucket_notification_delivery,
          bucket: bucket,
          key: key,
          reason: inspect(reason)
        )

        raise retained_storage_error(
                bucket,
                key,
                reason,
                "S3 bucket notification retained ledger persist failed; retry the write"
              )
    end
  end

  @doc """
  Replay/prune retained ledgers for one key before another sidecar mutation.

  This is called while the object lock is held. If committed evidence cannot be
  replayed into the durable outbox, the caller must fail instead of overwriting
  or deleting the only remaining predicate evidence.
  """
  @spec recover_key!(String.t(), String.t(), keyword()) :: :ok
  def recover_key!(bucket, key, opts \\ []) do
    opts = sidecar_opts(opts)

    case Storage.list_notification_ledgers(bucket, key, opts) do
      {:ok, entries} ->
        summary = replay_entries(entries, false, opts)

        if summary.failed > 0 or summary.ambiguous > 0 do
          raise Error.new(:internal_error,
                  message:
                    "S3 bucket notification retained ledger recovery failed; retry after scanner or operator repair"
                )
        end

        :ok

      {:error, reason} ->
        Log.error("bucket notification retained ledger list failed",
          action: :bucket_notification_delivery,
          bucket: bucket,
          key: key,
          reason: inspect(reason)
        )

        raise retained_storage_error(
                bucket,
                key,
                reason,
                "S3 bucket notification retained ledger recovery failed; retry the write"
              )
    end
  end

  @doc "Replay retained ledgers for a whole bucket. Scanner uses this before object forward pass."
  @spec replay_bucket(String.t(), boolean(), keyword()) :: summary()
  def replay_bucket(bucket, dry_run, opts \\ []) do
    opts = sidecar_opts(opts)

    case Storage.list_notification_ledgers(bucket, :all, opts) do
      {:ok, entries} ->
        replay_entries(entries, dry_run, opts)

      {:error, reason} ->
        Log.error("scanner: retained notification ledger list failed",
          action: :bucket_notification_delivery,
          bucket: bucket,
          reason: inspect(reason)
        )

        %{zero_summary() | failed: 1}
    end
  end

  @doc "Replay retained ledgers that were just committed by the online request, then prune them."
  @spec replay_committed([map()], keyword()) :: :ok
  def replay_committed([], _opts), do: :ok

  def replay_committed(entries, opts) when is_list(entries) do
    opts = sidecar_opts(opts)
    _summary = replay_entries(entries, false, opts)
    :ok
  end

  defp replay_entries(entries, dry_run, opts) do
    Enum.reduce(entries, zero_summary(), fn entry, summary ->
      process_entry(entry, dry_run, opts, Map.update!(summary, :scanned, &(&1 + 1)))
    end)
  end

  defp process_entry(entry, dry_run, opts, summary) do
    entry_opts = entry_opts(entry, opts)

    case classify(entry, entry_opts) do
      :committed ->
        replay_committed_entry(entry, dry_run, entry_opts, summary)

      :aborted ->
        prune_aborted_entry(entry, dry_run, entry_opts, summary)

      :ambiguous ->
        Log.warn("retained notification ledger ambiguous; left for operator repair",
          action: :bucket_notification_delivery,
          bucket: entry_bucket(entry),
          key: entry_key(entry),
          notification_event_id: entry_id(entry),
          reason: inspect(Map.get(entry, "commit_predicate"))
        )

        Map.update!(summary, :ambiguous, &(&1 + 1))

      :invalid ->
        Log.error("retained notification ledger invalid; left for operator repair",
          action: :bucket_notification_delivery,
          bucket: entry_bucket(entry),
          key: entry_key(entry),
          notification_event_id: entry_id(entry),
          reason: inspect(entry, limit: 10)
        )

        Map.update!(summary, :failed, &(&1 + 1))
    end
  end

  defp replay_committed_entry(entry, true = _dry_run, _opts, summary) do
    Log.info("scanner dry-run: would replay retained notification ledger",
      action: :bucket_notification_delivery,
      bucket: entry_bucket(entry),
      key: entry_key(entry),
      notification_event_id: entry_id(entry)
    )

    Map.update!(summary, :replayed, &(&1 + 1))
  end

  defp replay_committed_entry(entry, false = _dry_run, opts, summary) do
    try do
      _ =
        entry
        |> sidecar_replay_entry()
        |> List.wrap()
        |> NotificationDelivery.replay_sidecar_ledger()

      summary
      |> Map.update!(:replayed, &(&1 + 1))
      |> prune_entry(entry, opts)
    rescue
      err ->
        Log.error("retained notification ledger replay failed",
          action: :bucket_notification_delivery,
          bucket: entry_bucket(entry),
          key: entry_key(entry),
          notification_event_id: entry_id(entry),
          reason: inspect(err)
        )

        Map.update!(summary, :failed, &(&1 + 1))
    end
  end

  defp prune_aborted_entry(entry, true = _dry_run, _opts, summary) do
    Log.info("scanner dry-run: would prune aborted retained notification ledger",
      action: :bucket_notification_delivery,
      bucket: entry_bucket(entry),
      key: entry_key(entry),
      notification_event_id: entry_id(entry)
    )

    Map.update!(summary, :aborted, &(&1 + 1))
  end

  defp prune_aborted_entry(entry, false = _dry_run, opts, summary) do
    summary
    |> Map.update!(:aborted, &(&1 + 1))
    |> prune_entry(entry, opts)
  end

  defp prune_entry(summary, entry, opts) do
    bucket = entry_bucket(entry)
    key = entry_key(entry)
    id = entry_id(entry)

    case Storage.delete_notification_ledgers(bucket, key, [id], opts) do
      :ok ->
        Map.update!(summary, :pruned, &(&1 + 1))

      {:error, reason} ->
        Log.warn("retained notification ledger prune failed; replay remains idempotent",
          action: :bucket_notification_delivery,
          bucket: bucket,
          key: key,
          notification_event_id: id,
          reason: inspect(reason)
        )

        Map.update!(summary, :failed, &(&1 + 1))
    end
  end

  defp classify(entry, opts) do
    with bucket when is_binary(bucket) <- entry_bucket(entry),
         key when is_binary(key) <- entry_key(entry),
         id when is_binary(id) <- entry_id(entry),
         payload when is_map(payload) <- Map.get(entry, "payload"),
         %{"type" => type, "version_id" => version_id} = predicate
         when is_binary(version_id) <- Map.get(entry, "commit_predicate") do
      _ = {id, payload}
      classify_predicate(type, bucket, key, version_id, predicate, opts)
    else
      _ -> :invalid
    end
  end

  defp classify_predicate("version_present", bucket, key, version_id, predicate, opts) do
    case ObjectMeta.get(bucket, key, version_id, opts) do
      %Object{} = object ->
        if present_predicate_matches?(object, predicate) do
          :committed
        else
          :ambiguous
        end

      {:error, :not_found} ->
        :aborted

      {:error, _reason} ->
        :ambiguous
    end
  end

  defp classify_predicate("version_absent", bucket, key, version_id, predicate, opts) do
    case ObjectMeta.get(bucket, key, version_id, opts) do
      {:error, :not_found} ->
        :committed

      %Object{} = object ->
        if matches_target?(object, Map.get(predicate, "target")),
          do: :aborted,
          else: :ambiguous

      {:error, _reason} ->
        :ambiguous
    end
  end

  defp classify_predicate("restore_state_transition", bucket, key, version_id, predicate, opts) do
    case ObjectMeta.get(bucket, key, version_id, opts) do
      %Object{} = object ->
        cond do
          present_predicate_matches?(object, predicate) and
              restore_state_matches?(object, Map.get(predicate, "after")) ->
            :committed

          present_predicate_matches?(object, predicate) and
              restore_state_matches?(object, Map.get(predicate, "before")) ->
            :aborted

          true ->
            :ambiguous
        end

      {:error, :not_found} ->
        :ambiguous

      {:error, _reason} ->
        :ambiguous
    end
  end

  defp classify_predicate(_type, _bucket, _key, _version_id, _predicate, _opts), do: :invalid

  defp present_predicate_matches?(%Object{} = object, predicate) do
    type_matches? =
      case Map.get(predicate, "entry_type") do
        "delete_marker" -> object.is_delete_marker == true
        "object" -> object.is_delete_marker != true
        nil -> true
        _other -> false
      end

    type_matches? and optional_match?(predicate, "etag", object.etag) and
      optional_match?(predicate, "size", object.size)
  end

  defp optional_match?(predicate, key, value) do
    case Map.get(predicate, key) do
      nil -> true
      expected -> expected == value
    end
  end

  defp matches_target?(%Object{} = object, target) when is_map(target) do
    target["version_id"] == object.version_id and
      target["etag"] == object.etag and
      target["size"] == object.size and
      target["is_delete_marker"] == (object.is_delete_marker == true)
  end

  defp matches_target?(_object, _target), do: false

  defp restore_state_matches?(%Object{} = object, expected) when is_map(expected) do
    restore_state_proof(object) == expected
  end

  defp restore_state_matches?(_object, _expected), do: false

  defp sidecar_replay_entry(entry) do
    %{"id" => entry_id(entry), "payload" => Map.fetch!(entry, "payload")}
  end

  defp target_proof(target) when is_map(target) do
    %{
      "deleted" => Map.get(target, :deleted?),
      "version_id" => Map.get(target, :version_id),
      "etag" => Map.get(target, :etag),
      "size" => Map.get(target, :size),
      "is_delete_marker" => Map.get(target, :was_delete_marker) == true
    }
  end

  defp restore_state_proof(state) when is_map(state) do
    %{
      "restore_status" => restore_state_value(state, :restore_status),
      "restore_expiry" => normalize_datetime(restore_state_value(state, :restore_expiry))
    }
  end

  defp restore_state_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(value) when is_binary(value), do: value
  defp normalize_datetime(_value), do: nil

  defp sidecar_opts(opts) do
    source =
      opts
      |> Keyword.get(:authoritative_source, [])
      |> case do
        value when is_list(value) -> value
        _ -> []
      end
      |> Keyword.merge(read: :sidecar, list: :sidecar, write: :sidecar)

    opts
    |> Keyword.put(:authoritative_source, source)
    |> Keyword.put(:read_prefer_index, false)
    |> ObjectMeta.put_effective_topology()
  end

  defp entry_opts(entry, opts) do
    Keyword.merge(
      opts,
      storage_opts(Map.get(entry, "storage_opts") || Map.get(entry, :storage_opts) || [])
    )
  end

  defp storage_opts(opts) when is_list(opts) do
    opts
    |> Keyword.take([:placement_set_id, :placement_pool_id, :placement_topology_hash])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp storage_opts(opts) when is_map(opts) do
    []
    |> maybe_storage_opt(:placement_set_id, map_value(opts, "placement_set_id"))
    |> maybe_storage_opt(:placement_pool_id, map_value(opts, "placement_pool_id"))
    |> maybe_storage_opt(:placement_topology_hash, map_value(opts, "placement_topology_hash"))
  end

  defp storage_opts(_opts), do: []

  defp storage_opts_payload(opts) do
    case storage_opts(opts) do
      [] ->
        nil

      opts ->
        Map.new(opts, fn {key, value} -> {Atom.to_string(key), value} end)
    end
  end

  defp maybe_storage_opt(opts, _key, nil), do: opts
  defp maybe_storage_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

  defp retained_storage_error(bucket, key, reason, internal_message) do
    if retryable_retained_storage_error?(reason) do
      Error.new(:slow_down_write, resource: "/#{bucket}/#{key}")
    else
      Error.new(:internal_error, message: internal_message)
    end
  end

  defp retryable_retained_storage_error?(reason)

  defp retryable_retained_storage_error?(reason) when reason in [:write_quorum, :rename_busy],
    do: true

  defp retryable_retained_storage_error?(
         {:notification_ledger_list_failed, _node, _path, reason}
       ),
       do: retryable_retained_storage_error?(reason)

  defp retryable_retained_storage_error?(
         {:notification_ledger_read_failed, _node, _path, reason}
       ),
       do: retryable_retained_storage_error?(reason)

  defp retryable_retained_storage_error?(:unavailable), do: true
  defp retryable_retained_storage_error?(_reason), do: false

  defp entry_bucket(entry), do: Map.get(entry, "bucket") || Map.get(entry, :bucket)
  defp entry_key(entry), do: Map.get(entry, "key") || Map.get(entry, :key)
  defp entry_id(entry), do: Map.get(entry, "id") || Map.get(entry, :id)

  defp zero_summary do
    %{scanned: 0, replayed: 0, pruned: 0, aborted: 0, ambiguous: 0, failed: 0}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
