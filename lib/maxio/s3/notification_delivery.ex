defmodule Maxio.S3.NotificationDelivery do
  @moduledoc """
  Bucket notification data-plane delivery facade.

  Object handlers call this only after the object mutation has committed. The
  facade performs notification configuration matching, persists matching events
  to the durable outbox, and hands them to the configured deliverer when one is
  available. Deliverer failures are logged and retried from the outbox; failures
  before an event reaches the outbox are surfaced as S3 errors instead of being
  silently acknowledged.
  """

  alias Maxio.S3.{Error, Log, Notification, NotificationOutbox}

  @type destination :: %{
          required(:type) => String.t(),
          required(:arn) => String.t() | nil,
          required(:id) => String.t() | nil,
          required(:events) => [String.t()],
          required(:filter) => map() | nil
        }

  @type event :: %{
          required(:destination) => destination(),
          required(:message) => map(),
          required(:record) => map(),
          required(:event_name) => String.t(),
          required(:bucket) => String.t(),
          required(:key) => String.t()
        }

  @callback deliver(event(), term()) :: :ok | {:error, term()}

  @type enqueued_event :: %{
          required(:event) => event(),
          required(:outbox_event) => NotificationOutbox.Event.t()
        }

  @spec emit(String.t(), map()) :: :ok
  def emit(event_name, attrs) when is_binary(event_name) and is_map(attrs) do
    event_name
    |> enqueue(attrs)
    |> deliver_enqueued()

    :ok
  end

  @doc """
  Persist matching notification events without delivering them yet.

  Handlers use this inside an object metadata transaction to make the outbox row
  commit atomically with the PG object state. Call `deliver_enqueued/1` only
  after the surrounding transaction has committed.
  """
  @spec enqueue(String.t(), map(), keyword()) :: [enqueued_event()]
  def enqueue(event_name, attrs, opts \\ []) when is_binary(event_name) and is_map(attrs) do
    bucket = Map.fetch!(attrs, :bucket)
    key = Map.fetch!(attrs, :key)

    with {:ok, config} <- notification_config(bucket) do
      config
      |> Notification.matching_destinations(event_name, key)
      |> Enum.map(fn destination ->
        event = build_event(destination, event_name, attrs)
        enqueue_event(event, opts)
      end)
    else
      {:error, reason} ->
        log_config_failure(event_name, attrs, reason)
        raise_config_unavailable!()
    end
  end

  @doc """
  Build durable sidecar notification ledger entries before a sidecar commit.

  The returned entries are JSON-safe maps with a stable UUID and the already
  rendered outbox payload. They are stored inside the sidecar version entry and
  can later be replayed idempotently into the PG outbox.
  """
  @spec sidecar_ledger(String.t(), map()) :: [map()]
  def sidecar_ledger(event_name, attrs) when is_binary(event_name) and is_map(attrs) do
    bucket = Map.fetch!(attrs, :bucket)
    key = Map.fetch!(attrs, :key)

    with {:ok, config} <- notification_config(bucket) do
      config
      |> Notification.matching_destinations(event_name, key)
      |> Enum.map(fn destination ->
        event = build_event(destination, event_name, attrs)

        %{
          "id" => Ecto.UUID.generate(),
          "payload" => NotificationOutbox.event_to_payload(event)
        }
      end)
    else
      {:error, reason} ->
        log_config_failure(event_name, attrs, reason)
        raise_config_unavailable!()
    end
  end

  @doc """
  Replay sidecar notification ledger entries into the PG outbox idempotently.

  Callers may pass the returned entries to `deliver_enqueued/1` after an online
  object commit. Scanner callers can ignore the return value to rebuild pending
  outbox rows without doing external delivery from the scanner process.
  """
  @spec replay_sidecar_ledger([map()] | nil, keyword()) :: [enqueued_event()]
  def replay_sidecar_ledger(entries, opts \\ [])
  def replay_sidecar_ledger(nil, _opts), do: []
  def replay_sidecar_ledger([], _opts), do: []

  def replay_sidecar_ledger(entries, opts) when is_list(entries) do
    Enum.map(entries, &replay_sidecar_ledger_entry(&1, opts))
  end

  @doc "Deliver events that were already persisted to the outbox."
  @spec deliver_enqueued([enqueued_event()] | enqueued_event() | nil) :: :ok
  def deliver_enqueued(nil), do: :ok

  def deliver_enqueued(entries) when is_list(entries) do
    Enum.each(entries, &deliver_enqueued/1)
    :ok
  end

  def deliver_enqueued(%{event: event, outbox_event: outbox_event}) do
    log_delivery_queued(event, outbox_event.id)
    maybe_deliver_async(outbox_event.id, event)
    :ok
  end

  @doc """
  Drain due notification outbox rows through the configured deliverer.

  This is the operator-facing retry path used by CLI/schedulers. It never
  constructs new events and never mutates S3 objects; it only consumes rows that
  were already persisted after successful object mutations.
  """
  @spec drain(keyword()) :: {:ok, map()} | {:error, term()}
  def drain(opts \\ []) do
    case deliverer(opts) do
      nil ->
        {:error, :no_deliverer}

      deliverer ->
        drain_loop(deliverer, opts, drain_limit(opts), MapSet.new(), %{
          claimed: 0,
          delivered: 0,
          failed: 0
        })
    end
  end

  @doc "Deliver one retryable outbox row by id."
  @spec deliver_one(Ecto.UUID.t(), keyword()) :: {:ok, :delivered} | {:error, term()}
  def deliver_one(id, opts \\ []) when is_binary(id) do
    case deliverer(opts) do
      nil ->
        {:error, :no_deliverer}

      deliverer ->
        with {:ok, event} <- NotificationOutbox.claim(id, opts) do
          deliver_claimed(event, deliverer, opts)
        end
    end
  end

  defp notification_config(bucket) do
    Notification.get_config(bucket)
  rescue
    err -> {:error, err}
  end

  defp build_event(destination, event_name, attrs) do
    message =
      case destination.type do
        "EventBridge" -> build_eventbridge_message(event_name, attrs)
        _classic -> build_classic_message(destination, event_name, attrs)
      end

    %{
      destination: destination,
      message: message,
      record: message_record(message),
      event_name: event_name,
      bucket: Map.fetch!(attrs, :bucket),
      key: Map.fetch!(attrs, :key)
    }
  end

  defp build_classic_message(destination, event_name, attrs) do
    %{"Records" => [build_record(destination, event_name, attrs)]}
  end

  defp build_record(destination, event_name, attrs) do
    bucket = Map.fetch!(attrs, :bucket)
    key = Map.fetch!(attrs, :key)

    %{
      "eventVersion" => "2.1",
      "eventSource" => "aws:s3",
      "awsRegion" => region(),
      "eventTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "eventName" => strip_s3_prefix(event_name),
      "userIdentity" => %{"principalId" => principal_id(Map.get(attrs, :principal))},
      "requestParameters" => %{"sourceIPAddress" => source_ip(Map.get(attrs, :source_ip))},
      "responseElements" => %{
        "x-amz-request-id" => Map.get(attrs, :request_id) || "",
        "x-amz-id-2" => ""
      },
      "s3" => %{
        "s3SchemaVersion" => "1.0",
        "configurationId" => destination.id || "",
        "bucket" => %{
          "name" => bucket,
          "ownerIdentity" => %{"principalId" => owner_id()},
          "arn" => "arn:aws:s3:::#{bucket}"
        },
        "object" => object_record(key, attrs)
      }
    }
  end

  defp object_record(key, attrs) do
    %{
      "key" => event_object_key(key),
      "sequencer" => sequencer()
    }
    |> maybe_put("size", Map.get(attrs, :size))
    |> maybe_put("eTag", Map.get(attrs, :etag))
    |> maybe_put_version_id(Map.get(attrs, :version_id))
  end

  defp build_eventbridge_message(event_name, attrs) do
    bucket = Map.fetch!(attrs, :bucket)
    arn = "arn:aws:s3:::#{bucket}"
    region = region()
    account_id = owner_id()

    %{
      "version" => "0",
      "id" => Ecto.UUID.generate(),
      "detail-type" => eventbridge_detail_type(event_name),
      "source" => "aws.s3",
      "account" => account_id,
      "time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "region" => region,
      "resources" => [arn],
      "detail" =>
        %{
          "version" => "0",
          "bucket" => %{"name" => bucket},
          "object" => eventbridge_object(attrs),
          "request-id" => Map.get(attrs, :request_id) || "",
          "requester" => principal_id(Map.get(attrs, :principal)),
          "source-ip-address" => source_ip(Map.get(attrs, :source_ip))
        }
        |> maybe_put("reason", eventbridge_reason(event_name))
        |> maybe_put("deletion-type", eventbridge_deletion_type(event_name))
        |> maybe_put("restore-expiry-time", eventbridge_restore_expiry(event_name, attrs))
        |> maybe_put("source-storage-class", eventbridge_source_storage_class(event_name, attrs))
    }
  end

  defp eventbridge_object(attrs) do
    %{
      "key" => Map.fetch!(attrs, :key),
      "sequencer" => sequencer()
    }
    |> maybe_put("size", Map.get(attrs, :size))
    |> maybe_put("etag", Map.get(attrs, :etag))
    |> maybe_put_eventbridge_version_id(Map.get(attrs, :version_id))
  end

  defp message_record(%{"Records" => [record]}), do: record
  defp message_record(message), do: message

  defp enqueue_event(event, opts) do
    case NotificationOutbox.enqueue(event, Keyword.take(opts, [:repo, :now])) do
      {:ok, outbox_event} ->
        %{event: event, outbox_event: outbox_event}

      {:error, reason} ->
        log_outbox_enqueue_failed(event, reason)
        raise_outbox_enqueue_failed!()
    end
  rescue
    err in Error ->
      reraise err, __STACKTRACE__

    err ->
      log_outbox_enqueue_failed(event, err)
      raise_outbox_enqueue_failed!()
  end

  defp replay_sidecar_ledger_entry(%{"id" => id, "payload" => payload}, opts)
       when is_binary(id) and is_map(payload) do
    event = NotificationOutbox.payload_to_event(payload)

    case NotificationOutbox.enqueue_payload(
           payload,
           Keyword.take(opts, [:repo, :now]) ++ [id: id]
         ) do
      {:ok, outbox_event} ->
        %{event: event, outbox_event: outbox_event}

      {:error, reason} ->
        log_sidecar_replay_failed(id, event, reason)
        raise_outbox_enqueue_failed!()
    end
  rescue
    err in Error ->
      reraise err, __STACKTRACE__

    err ->
      log_sidecar_replay_failed(id, safe_payload_event(payload), err)
      raise_outbox_enqueue_failed!()
  end

  defp replay_sidecar_ledger_entry(entry, _opts) do
    log_sidecar_replay_failed(nil, safe_payload_event(%{}), {:invalid_ledger_entry, entry})
    raise_outbox_enqueue_failed!()
  end

  defp maybe_deliver_async(outbox_event_id, event) do
    cond do
      is_nil(deliverer()) ->
        log_delivery_deferred(event, outbox_event_id)

      immediate_async?() ->
        deliver_enqueued_async(outbox_event_id, event)

      true ->
        _ = deliver_one(outbox_event_id)
        :ok
    end
  end

  defp deliver_enqueued_async(outbox_event_id, event) do
    case Task.start(fn -> deliver_one(outbox_event_id) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> log_delivery_failed(event, reason)
    end
  end

  defp deliver_claimed(outbox_event, deliverer, opts) do
    event = NotificationOutbox.payload_to_event(outbox_event.payload)

    case invoke_deliverer(deliverer, event) do
      :ok ->
        case NotificationOutbox.mark_delivered(outbox_event, opts) do
          {:ok, _event} ->
            log_delivery_delivered(event)
            {:ok, :delivered}

          {:error, reason} ->
            log_delivery_failed(event, {:outbox_mark_delivered_failed, reason})
            {:error, {:outbox_mark_delivered_failed, reason}}
        end

      {:error, reason} ->
        case NotificationOutbox.mark_failed(outbox_event, reason, opts) do
          {:ok, _event} ->
            :ok

          {:error, mark_reason} ->
            log_delivery_failed(event, {:outbox_mark_failed_failed, mark_reason})
        end

        log_delivery_failed(event, reason)
        {:error, reason}
    end
  end

  defp invoke_deliverer({module, opts}, event) when is_atom(module) do
    module.deliver(event, opts)
    |> normalize_delivery_result()
  rescue
    err -> {:error, err}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp invoke_deliverer(module, event) when is_atom(module),
    do: invoke_deliverer({module, []}, event)

  defp invoke_deliverer(fun, event) when is_function(fun, 1) do
    fun.(event)
    |> normalize_delivery_result()
  rescue
    err -> {:error, err}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp invoke_deliverer({fun, opts}, event) when is_function(fun, 2) do
    fun.(event, opts)
    |> normalize_delivery_result()
  rescue
    err -> {:error, err}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp invoke_deliverer(other, _event) do
    {:error, {:invalid_deliverer, other}}
  end

  defp normalize_delivery_result(:ok), do: :ok
  defp normalize_delivery_result({:error, reason}), do: {:error, reason}
  defp normalize_delivery_result(other), do: {:error, {:bad_return, other}}

  defp drain_loop(_deliverer, _opts, 0, _seen_ids, summary), do: {:ok, summary}

  defp drain_loop(deliverer, opts, remaining, seen_ids, summary) do
    claim_opts = Keyword.put(opts, :exclude_ids, MapSet.to_list(seen_ids))

    case NotificationOutbox.claim_next(claim_opts) do
      {:ok, outbox_event} ->
        result = deliver_claimed(outbox_event, deliverer, opts)

        drain_loop(
          deliverer,
          opts,
          remaining - 1,
          MapSet.put(seen_ids, outbox_event.id),
          update_drain_summary(summary, result)
        )

      :none ->
        {:ok, summary}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_drain_summary(summary, {:ok, :delivered}) do
    summary
    |> Map.update!(:claimed, &(&1 + 1))
    |> Map.update!(:delivered, &(&1 + 1))
  end

  defp update_drain_summary(summary, {:error, _reason}) do
    summary
    |> Map.update!(:claimed, &(&1 + 1))
    |> Map.update!(:failed, &(&1 + 1))
  end

  defp log_delivery_delivered(event) do
    Log.info("bucket notification delivered",
      action: :bucket_notification_delivery,
      bucket: event.bucket,
      key: event.key,
      event_name: event.event_name,
      destination_type: event.destination.type,
      destination_arn: event.destination.arn,
      configuration_id: event.destination.id
    )
  end

  defp log_delivery_queued(event, outbox_event_id) do
    Log.info("bucket notification queued",
      action: :bucket_notification_delivery,
      bucket: event.bucket,
      key: event.key,
      event_name: event.event_name,
      destination_type: event.destination.type,
      destination_arn: event.destination.arn,
      configuration_id: event.destination.id,
      notification_event_id: outbox_event_id
    )
  end

  defp log_delivery_deferred(event, outbox_event_id) do
    Log.info("bucket notification delivery deferred",
      action: :bucket_notification_delivery,
      bucket: event.bucket,
      key: event.key,
      event_name: event.event_name,
      destination_type: event.destination.type,
      destination_arn: event.destination.arn,
      configuration_id: event.destination.id,
      notification_event_id: outbox_event_id,
      reason: :no_deliverer
    )
  end

  defp log_outbox_enqueue_failed(event, reason) do
    Log.warn("bucket notification outbox enqueue failed",
      action: :bucket_notification_delivery,
      bucket: event.bucket,
      key: event.key,
      event_name: event.event_name,
      destination_type: event.destination.type,
      destination_arn: event.destination.arn,
      configuration_id: event.destination.id,
      reason: inspect(reason)
    )
  end

  defp log_sidecar_replay_failed(id, event, reason) do
    Log.warn("bucket notification sidecar ledger replay failed",
      action: :bucket_notification_delivery,
      bucket: Map.get(event, :bucket),
      key: Map.get(event, :key),
      event_name: Map.get(event, :event_name),
      notification_event_id: id,
      reason: inspect(reason)
    )
  end

  defp log_delivery_failed(event, reason) do
    Log.warn("bucket notification delivery failed",
      action: :bucket_notification_delivery,
      bucket: event.bucket,
      key: event.key,
      event_name: event.event_name,
      destination_type: event.destination.type,
      destination_arn: event.destination.arn,
      configuration_id: event.destination.id,
      reason: inspect(reason)
    )
  end

  defp log_config_failure(event_name, attrs, reason) do
    Log.warn("bucket notification configuration unavailable",
      action: :bucket_notification_delivery,
      bucket: Map.get(attrs, :bucket),
      key: Map.get(attrs, :key),
      event_name: event_name,
      reason: inspect(reason)
    )
  end

  defp deliverer(opts \\ []) do
    Keyword.get(opts, :deliverer) ||
      configured_deliverer()
  end

  defp configured_deliverer do
    :maxio
    |> Application.get_env(:notification_delivery, [])
    |> Keyword.get(:deliverer)
  end

  defp drain_limit(opts) do
    case Keyword.get(opts, :limit) do
      value when is_integer(value) and value > 0 -> value
      _other -> 100
    end
  end

  defp raise_outbox_enqueue_failed! do
    raise Error.new(:internal_error,
            message:
              "S3 bucket notification outbox enqueue failed; retry request or drain operator evidence before considering the write acknowledged"
          )
  end

  defp raise_config_unavailable! do
    raise Error.new(:internal_error,
            message:
              "S3 bucket notification configuration unavailable; retry request after repairing the bucket notification configuration"
          )
  end

  defp immediate_async? do
    :maxio
    |> Application.get_env(:notification_delivery, [])
    |> Keyword.get(:async?, true)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_version_id(map, nil), do: map
  defp maybe_put_version_id(map, "null"), do: map
  defp maybe_put_version_id(map, version_id), do: Map.put(map, "versionId", version_id)

  defp maybe_put_eventbridge_version_id(map, nil), do: map
  defp maybe_put_eventbridge_version_id(map, "null"), do: map

  defp maybe_put_eventbridge_version_id(map, version_id),
    do: Map.put(map, "version-id", version_id)

  defp strip_s3_prefix("s3:" <> event_name), do: event_name
  defp strip_s3_prefix(event_name), do: event_name

  defp event_object_key(key), do: URI.encode_www_form(key)

  defp eventbridge_detail_type("s3:ObjectCreated:" <> _suffix), do: "Object Created"
  defp eventbridge_detail_type("s3:ObjectRemoved:" <> _suffix), do: "Object Deleted"
  defp eventbridge_detail_type("s3:ObjectRestore:Post"), do: "Object Restore Initiated"
  defp eventbridge_detail_type("s3:ObjectRestore:Completed"), do: "Object Restore Completed"
  defp eventbridge_detail_type("s3:ObjectRestore:Delete"), do: "Object Restore Expired"
  defp eventbridge_detail_type(event_name), do: strip_s3_prefix(event_name)

  defp eventbridge_reason("s3:ObjectCreated:Put"), do: "PutObject"
  defp eventbridge_reason("s3:ObjectCreated:Post"), do: "POST Object"
  defp eventbridge_reason("s3:ObjectCreated:Copy"), do: "CopyObject"

  defp eventbridge_reason("s3:ObjectCreated:CompleteMultipartUpload"),
    do: "CompleteMultipartUpload"

  defp eventbridge_reason("s3:ObjectRemoved:Delete"), do: "DeleteObject"
  defp eventbridge_reason("s3:ObjectRemoved:DeleteMarkerCreated"), do: "DeleteObject"
  defp eventbridge_reason("s3:ObjectRestore:Post"), do: "RestoreObject"
  defp eventbridge_reason("s3:ObjectRestore:Completed"), do: nil
  defp eventbridge_reason("s3:ObjectRestore:Delete"), do: nil
  defp eventbridge_reason(event_name), do: strip_s3_prefix(event_name)

  defp eventbridge_restore_expiry("s3:ObjectRestore:Completed", %{
         restore_expiry: %DateTime{} = dt
       }),
       do: DateTime.to_iso8601(dt)

  defp eventbridge_restore_expiry(_event_name, _attrs), do: nil

  defp eventbridge_source_storage_class(event_name, attrs)
       when event_name in ["s3:ObjectRestore:Post", "s3:ObjectRestore:Completed"],
       do: Map.get(attrs, :source_storage_class) || Map.get(attrs, :storage_class)

  defp eventbridge_source_storage_class(_event_name, _attrs), do: nil

  defp eventbridge_deletion_type("s3:ObjectRemoved:Delete"), do: "Permanently Deleted"

  defp eventbridge_deletion_type("s3:ObjectRemoved:DeleteMarkerCreated"),
    do: "Delete Marker Created"

  defp eventbridge_deletion_type(_event_name), do: nil

  defp principal_id(%{arn: arn}) when is_binary(arn), do: arn
  defp principal_id(%{access_key: access_key}) when is_binary(access_key), do: access_key
  defp principal_id(:anonymous), do: "anonymous"
  defp principal_id(nil), do: "unknown"
  defp principal_id(other), do: inspect(other)

  defp source_ip(nil), do: ""
  defp source_ip(tuple) when is_tuple(tuple), do: tuple |> :inet.ntoa() |> to_string()
  defp source_ip(value), do: to_string(value)

  defp sequencer do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string(16)
    |> String.upcase()
  end

  defp region do
    :maxio
    |> Application.get_env(:s3, [])
    |> Keyword.get(:region, "us-east-1")
  end

  defp owner_id do
    :maxio
    |> Application.get_env(:sts, [])
    |> Keyword.get(:account_id, "000000000000")
    |> to_string()
  end

  defp safe_payload_event(payload) when is_map(payload) do
    NotificationOutbox.payload_to_event(payload)
  rescue
    _ -> %{}
  end
end
