defmodule Maxio.S3.RestoreExpiry do
  @moduledoc """
  Background/operator runner for expiring restored archive copies.

  Restore expiry is not applied from GET/HEAD/LIST hot paths. Operators or the
  scheduler run this module to clear due restore metadata and emit the matching
  `s3:ObjectRestore:Delete` bucket notification after the metadata commit.
  """

  alias Maxio.{Buckets, Listing, Lock, ObjectMeta, ObjectRestoreSidecar, Objects}
  alias Maxio.Cluster.Placement
  alias Maxio.Objects.Object
  alias Maxio.S3.{Log, NotificationDelivery, NotificationRetainedLedger}

  @archive_storage_classes ~w(GLACIER DEEP_ARCHIVE)

  @type summary :: %{
          scanned: non_neg_integer(),
          expired: non_neg_integer(),
          stale: non_neg_integer(),
          failed: non_neg_integer(),
          dry_run: boolean(),
          errors: [map()]
        }

  @spec run(keyword()) :: summary()
  def run(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    dry_run? = Keyword.get(opts, :dry_run, false) == true
    {candidates, discovery_errors} = expired_restore_candidates(now, opts, dry_run?)

    summary = record_discovery_errors(zero_summary(dry_run?), discovery_errors)

    Enum.reduce(candidates, summary, fn %Object{} = object, summary ->
      summary = Map.update!(summary, :scanned, &(&1 + 1))

      cond do
        dry_run? ->
          Map.update!(summary, :expired, &(&1 + 1))

        true ->
          case expire_object(object, now, opts) do
            :expired -> Map.update!(summary, :expired, &(&1 + 1))
            :stale -> Map.update!(summary, :stale, &(&1 + 1))
            {:error, reason} -> record_error(summary, object, reason)
          end
      end
    end)
  end

  defp expired_restore_candidates(%DateTime{} = now, opts, dry_run?) do
    case ObjectMeta.authoritative_source(:write, opts) do
      :sidecar -> sidecar_expired_restore_candidates(now, opts, dry_run?)
      _pg -> {Objects.list_expired_restores(now, opts), []}
    end
  end

  defp sidecar_expired_restore_candidates(%DateTime{} = now, opts, dry_run?) do
    opts = sidecar_authority_opts(opts)
    limit = candidate_limit(opts)

    {candidates, errors} =
      opts
      |> Keyword.get(:bucket)
      |> bucket_names()
      |> Enum.reduce({[], []}, fn bucket, {candidates, errors} ->
        retained_errors = recover_bucket_notifications(bucket, dry_run?, opts)
        {bucket_candidates, bucket_errors} = sidecar_bucket_candidates(bucket, now, opts)

        {bucket_candidates ++ candidates, retained_errors ++ bucket_errors ++ errors}
      end)

    candidates =
      candidates
      |> Enum.sort_by(fn %Object{} = object ->
        {DateTime.to_unix(object.restore_expiry, :microsecond), object.bucket_name, object.key,
         object.version_id}
      end)
      |> Enum.take(limit)

    {candidates, Enum.reverse(errors)}
  end

  defp bucket_names(nil), do: Buckets.list() |> Enum.map(& &1.name)
  defp bucket_names(""), do: bucket_names(nil)

  defp bucket_names(bucket) when is_binary(bucket),
    do: Buckets.list() |> Enum.map(& &1.name) |> Enum.filter(&(&1 == bucket))

  defp bucket_names(_other), do: bucket_names(nil)

  defp recover_bucket_notifications(bucket, dry_run?, opts) do
    summary = NotificationRetainedLedger.replay_bucket(bucket, dry_run?, opts)

    if summary.failed > 0 or summary.ambiguous > 0 do
      [
        %{
          bucket: bucket,
          reason: "retained_notification_replay_failed",
          retained_failed: summary.failed,
          retained_ambiguous: summary.ambiguous
        }
      ]
    else
      []
    end
  rescue
    err ->
      [
        %{
          bucket: bucket,
          reason: inspect(err)
        }
      ]
  end

  defp sidecar_bucket_candidates(bucket, %DateTime{} = now, opts) do
    keys = Listing.scan_keys(bucket, opts)

    Enum.reduce(keys, {[], []}, fn key, {candidates, errors} ->
      {key_candidates, key_errors} = sidecar_key_candidates(bucket, key, now, opts)
      {key_candidates ++ candidates, key_errors ++ errors}
    end)
  rescue
    err ->
      {[],
       [
         %{
           bucket: bucket,
           reason: inspect(err)
         }
       ]}
  catch
    kind, reason ->
      {[],
       [
         %{
           bucket: bucket,
           reason: inspect({kind, reason})
         }
       ]}
  end

  defp sidecar_key_candidates(bucket, key, %DateTime{} = now, opts) do
    opts = sidecar_authority_opts(opts)
    version_ids = Listing.version_ids(bucket, key, opts)

    Enum.reduce(version_ids, {[], []}, fn version_id, {candidates, errors} ->
      case ObjectMeta.get(bucket, key, version_id, opts) do
        %Object{} = object ->
          if sidecar_due_candidate?(object, now) do
            {[object | candidates], errors}
          else
            {candidates, errors}
          end

        {:error, :not_found} ->
          {candidates, errors}

        {:error, reason} ->
          {candidates, [discovery_error(bucket, key, version_id, reason) | errors]}
      end
    end)
  rescue
    err -> {[], [discovery_error(bucket, key, nil, err)]}
  catch
    kind, reason -> {[], [discovery_error(bucket, key, nil, {kind, reason})]}
  end

  defp expire_object(%Object{} = object, %DateTime{} = now, opts) do
    case ObjectMeta.authoritative_source(:write, opts) do
      :sidecar -> expire_sidecar(object, now, opts)
      _pg -> expire_pg(object, now, opts)
    end
  end

  defp expire_pg(%Object{} = object, %DateTime{} = now, opts) do
    notifications = restore_delete_notifications(object, opts)

    case Objects.expire_restore_state(
           object,
           now,
           notification_transaction_opts(notifications)
         ) do
      {:ok, {_expired_object, enqueued_notifications}} ->
        mirror_restore_sidecar(object, %{restore_status: nil, restore_expiry: nil})
        NotificationDelivery.deliver_enqueued(enqueued_notifications)
        log_expired(object)
        :expired

      {:ok, _expired_object} ->
        mirror_restore_sidecar(object, %{restore_status: nil, restore_expiry: nil})
        log_expired(object)
        :expired

      :stale ->
        :stale
    end
  rescue
    err -> {:error, err}
  end

  defp expire_sidecar(%Object{} = candidate, %DateTime{} = now, opts) do
    case Lock.with_object_lock({candidate.bucket_name, candidate.key}, fn ->
           do_expire_sidecar(candidate, now, opts)
         end) do
      {:ok, result} -> result
      {:error, :locked} -> {:error, :locked}
    end
  rescue
    err -> {:error, err}
  end

  defp do_expire_sidecar(%Object{} = candidate, %DateTime{} = now, opts) do
    bucket = candidate.bucket_name
    key = candidate.key
    version_id = candidate.version_id
    storage_opts = Placement.storage_opts(candidate)

    NotificationRetainedLedger.recover_key!(bucket, key, storage_opts)

    read_opts =
      opts
      |> Keyword.merge(storage_opts)
      |> Keyword.put(:read_prefer_index, false)
      |> Keyword.put(:authoritative_source, read: :sidecar, list: :sidecar, write: :sidecar)

    case ObjectMeta.get(bucket, key, version_id, read_opts) do
      %Object{} = current ->
        if due_candidate?(current, candidate, now) do
          expire_sidecar_current(current, now, opts, storage_opts)
        else
          :stale
        end

      {:error, :not_found} ->
        :stale

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expire_sidecar_current(%Object{} = object, %DateTime{} = _now, opts, storage_opts) do
    bucket = object.bucket_name
    key = object.key
    attrs = %{restore_status: nil, restore_expiry: nil}
    notifications = restore_delete_notifications(object, opts)

    notification_outbox = sidecar_notification_ledger(notifications)

    retained =
      retained_notification_ledger(
        notification_outbox,
        bucket,
        key,
        object,
        attrs,
        notifications,
        storage_opts
      )

    NotificationRetainedLedger.persist!(bucket, key, retained, storage_opts)

    sidecar_opts = Keyword.merge(storage_opts, notification_outbox: notification_outbox)

    case ObjectRestoreSidecar.update(bucket, key, object.version_id, attrs, sidecar_opts) do
      {:ok, generation} ->
        _ = Objects.put_restore_state(bucket, key, object.version_id, attrs, generation)
        deliver_sidecar_notifications(notification_outbox, retained, storage_opts)
        log_expired(object)
        :expired

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp due_candidate?(%Object{} = current, %Object{} = candidate, %DateTime{} = now) do
    current.version_id == candidate.version_id and current.is_delete_marker != true and
      current.storage_class in @archive_storage_classes and current.restore_status == "restored" and
      same_datetime?(current.restore_expiry, candidate.restore_expiry) and
      due_datetime?(current.restore_expiry, now)
  end

  defp sidecar_due_candidate?(%Object{} = object, %DateTime{} = now) do
    object.is_delete_marker != true and object.storage_class in @archive_storage_classes and
      object.restore_status == "restored" and due_datetime?(object.restore_expiry, now)
  end

  defp due_datetime?(%DateTime{} = expiry, %DateTime{} = now),
    do: DateTime.compare(expiry, now) != :gt

  defp due_datetime?(_expiry, _now), do: false

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp restore_delete_notifications(%Object{} = object, opts) do
    [{"s3:ObjectRestore:Delete", notification_attrs(object, opts)}]
  end

  defp notification_attrs(%Object{} = object, opts) do
    %{
      bucket: object.bucket_name,
      key: object.key,
      size: object.size,
      etag: object.etag,
      version_id: object.version_id,
      storage_class: object.storage_class,
      request_id: Keyword.get(opts, :request_id, "restore-expiry"),
      principal: %{arn: "maxio:restore-expiry"},
      source_ip: nil
    }
  end

  defp notification_transaction_opts(notifications) do
    [
      transaction_hook: fn repo, _object ->
        Enum.flat_map(notifications, fn {event_name, attrs} ->
          NotificationDelivery.enqueue(event_name, attrs, repo: repo)
        end)
      end
    ]
  end

  defp sidecar_notification_ledger(notifications) do
    Enum.flat_map(notifications, fn {event_name, attrs} ->
      NotificationDelivery.sidecar_ledger(event_name, attrs)
    end)
  end

  defp retained_notification_ledger([], _bucket, _key, _object, _attrs, _notifications, _opts),
    do: []

  defp retained_notification_ledger(ledger, bucket, key, object, attrs, notifications, opts) do
    NotificationRetainedLedger.entries(ledger,
      bucket: bucket,
      key: key,
      operation: :restore_expiry,
      predicate:
        NotificationRetainedLedger.restore_state_transition(object.version_id, object, attrs,
          entry_type: "object",
          etag: object.etag,
          size: object.size
        ),
      request_id: retained_request_id(notifications),
      storage_opts: opts
    )
  end

  defp retained_request_id([{_event_name, attrs} | _rest]) when is_map(attrs),
    do: Map.get(attrs, :request_id)

  defp retained_request_id(_notifications), do: nil

  defp deliver_sidecar_notifications([], _retained, _storage_opts), do: :ok

  defp deliver_sidecar_notifications(ledger, retained, storage_opts) do
    ledger
    |> NotificationDelivery.replay_sidecar_ledger()
    |> NotificationDelivery.deliver_enqueued()

    NotificationRetainedLedger.replay_committed(retained, storage_opts)
  rescue
    err ->
      Log.error("bucket notification sidecar ledger replay deferred",
        action: :bucket_notification_delivery,
        reason: inspect(err)
      )

      :ok
  end

  defp mirror_restore_sidecar(%Object{} = object, attrs) do
    case ObjectRestoreSidecar.update(object.bucket_name, object.key, object.version_id, attrs) do
      {:ok, generation} ->
        _ =
          Objects.put_restore_state(
            object.bucket_name,
            object.key,
            object.version_id,
            attrs,
            generation
          )

        :ok

      {:error, reason} ->
        Log.warn("sidecar restore expiry mirror failed (PG remains authoritative)",
          action: :restore_expiry,
          bucket: object.bucket_name,
          key: object.key,
          version_id: object.version_id,
          reason: inspect(reason)
        )
    end
  rescue
    err ->
      Log.warn("sidecar restore expiry mirror raised (PG remains authoritative)",
        action: :restore_expiry,
        bucket: object.bucket_name,
        key: object.key,
        version_id: object.version_id,
        reason: inspect(err)
      )
  end

  defp log_expired(%Object{} = object) do
    Log.info("restore metadata expired",
      action: :restore_expiry,
      bucket: object.bucket_name,
      key: object.key,
      version_id: object.version_id
    )
  end

  defp record_error(summary, %Object{} = object, reason) do
    Log.error("restore expiry failed",
      action: :restore_expiry,
      bucket: object.bucket_name,
      key: object.key,
      version_id: object.version_id,
      reason: inspect(reason)
    )

    summary
    |> Map.update!(:failed, &(&1 + 1))
    |> Map.update!(:errors, fn errors ->
      [
        %{
          bucket: object.bucket_name,
          key: object.key,
          version_id: object.version_id,
          reason: inspect(reason)
        }
        | errors
      ]
    end)
  end

  defp record_discovery_errors(summary, []), do: summary

  defp record_discovery_errors(summary, errors) do
    Enum.reduce(errors, summary, fn error, summary ->
      Log.error("restore expiry discovery failed",
        action: :restore_expiry,
        bucket: Map.get(error, :bucket),
        key: Map.get(error, :key),
        version_id: Map.get(error, :version_id),
        reason: Map.get(error, :reason),
        retained_failed: Map.get(error, :retained_failed),
        retained_ambiguous: Map.get(error, :retained_ambiguous)
      )

      summary
      |> Map.update!(:failed, &(&1 + 1))
      |> Map.update!(:errors, fn existing -> [error | existing] end)
    end)
  end

  defp discovery_error(bucket, key, version_id, reason) do
    %{
      bucket: bucket,
      key: key,
      version_id: version_id,
      reason: inspect(reason)
    }
  end

  defp sidecar_authority_opts(opts) do
    source =
      opts
      |> Keyword.get(:authoritative_source, [])
      |> case do
        value when is_list(value) -> value
        _other -> []
      end
      |> Keyword.merge(read: :sidecar, list: :sidecar, write: :sidecar)

    opts
    |> Keyword.put(:authoritative_source, source)
    |> Keyword.put(:read_prefer_index, false)
    |> ObjectMeta.put_effective_topology()
  end

  defp candidate_limit(opts) do
    case Keyword.get(opts, :limit, 1000) do
      limit when is_integer(limit) and limit > 0 -> min(limit, 10_000)
      _other -> 1000
    end
  end

  defp zero_summary(dry_run?) do
    %{scanned: 0, expired: 0, stale: 0, failed: 0, dry_run: dry_run?, errors: []}
  end
end
