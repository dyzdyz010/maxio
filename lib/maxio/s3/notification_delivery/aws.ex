defmodule Maxio.S3.NotificationDelivery.AWS do
  @moduledoc """
  AWS-backed bucket notification deliverer.

  This module is opt-in via:

      config :maxio, :notification_delivery,
        deliverer: {Maxio.S3.NotificationDelivery.AWS, opts}

  It consumes already-persisted outbox events and sends them to AWS SNS, SQS,
  Lambda, or EventBridge with SigV4-signed HTTP requests. It never validates or
  stores bucket notification configuration; that remains the control-plane
  validator's responsibility.
  """

  @behaviour Maxio.S3.NotificationDelivery

  alias Maxio.S3.{AWSClient, Notification}

  @sns_version "2010-03-31"
  @eventbridge_target "AWSEvents.PutEvents"
  @sqs_target "AmazonSQS.SendMessage"

  @impl true
  def deliver(%{destination: %{type: "Topic"}} = event, opts), do: deliver_sns(event, opts)
  def deliver(%{destination: %{type: "Queue"}} = event, opts), do: deliver_sqs(event, opts)

  def deliver(%{destination: %{type: "LambdaFunction"}} = event, opts),
    do: deliver_lambda(event, opts)

  def deliver(%{destination: %{type: "EventBridge"}} = event, opts),
    do: deliver_eventbridge(event, opts)

  def deliver(%{destination: %{type: type}}, _opts),
    do: {:error, {:unsupported_destination, type}}

  def deliver(_event, _opts), do: {:error, :invalid_event}

  @doc """
  Sends the AWS S3 control-plane `s3:TestEvent` probe to an SNS/SQS destination.

  PutBucketNotificationConfiguration uses this during destination validation.
  It is not a durable object event and must not be enqueued in the notification
  outbox.
  """
  @spec deliver_test_message(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def deliver_test_message(bucket, %{type: type} = destination, opts)
      when is_binary(bucket) and type in ["Topic", "Queue"] and is_list(opts) do
    event = %{
      destination: destination,
      message: Notification.test_event_payload(bucket, opts),
      record: %{},
      event_name: "s3:TestEvent",
      bucket: bucket,
      key: ""
    }

    case type do
      "Topic" ->
        with {:ok, body} <- publish_sns(event, opts) do
          {:ok, %{message_id: sns_message_id(body)}}
        end

      "Queue" ->
        with :ok <- deliver_sqs(event, opts) do
          {:ok, %{}}
        end
    end
  end

  def deliver_test_message(_bucket, %{type: type}, _opts),
    do: {:error, {:unsupported_test_message_destination, type}}

  def deliver_test_message(_bucket, _destination, _opts), do: {:error, :invalid_destination}

  defp deliver_sns(event, opts) do
    case publish_sns(event, opts) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_sns(event, opts) do
    with {:ok, arn} <- destination_arn(event),
         {:ok, arn_parts} <- AWSClient.parse_arn(arn, "sns"),
         {:ok, request} <-
           AWSClient.signed_form_request(
             :post,
             AWSClient.endpoint(opts, :sns, arn_parts),
             "sns",
             arn_parts.region,
             %{
               "Action" => "Publish",
               "Version" => @sns_version,
               "TopicArn" => arn,
               "Message" => encode_message(event.message)
             },
             opts
           ) do
      AWSClient.perform_request(request, opts)
    end
  end

  defp deliver_sqs(event, opts) do
    with {:ok, arn} <- destination_arn(event),
         {:ok, arn_parts} <- AWSClient.parse_arn(arn, "sqs"),
         {:ok, queue_url} <- AWSClient.queue_url(arn, arn_parts, opts),
         {:ok, request} <-
           AWSClient.signed_json_request(
             :post,
             AWSClient.endpoint(opts, :sqs, arn_parts),
             "sqs",
             arn_parts.region,
             %{"x-amz-target" => @sqs_target, "content-type" => "application/x-amz-json-1.0"},
             %{
               "QueueUrl" => queue_url,
               "MessageBody" => encode_message(event.message)
             },
             opts
           ) do
      AWSClient.send_request(request, opts)
    end
  end

  defp deliver_lambda(event, opts) do
    with {:ok, arn} <- destination_arn(event),
         {:ok, arn_parts} <- AWSClient.parse_arn(arn, "lambda"),
         {:ok, request} <-
           AWSClient.signed_request(
             :post,
             String.trim_trailing(AWSClient.endpoint(opts, :lambda, arn_parts), "/") <>
               "/2015-03-31/functions/#{arn}/invocations",
             "lambda",
             arn_parts.region,
             %{
               "content-type" => "application/json",
               "x-amz-invocation-type" => "Event"
             },
             encode_message(event.message),
             opts
           ) do
      AWSClient.send_request(request, opts, success_statuses: [202])
    end
  end

  defp deliver_eventbridge(event, opts) do
    region = region(opts)
    partition = Keyword.get(opts, :partition, "aws")
    message = event.message

    entry =
      %{
        "Source" => eventbridge_source(opts),
        "DetailType" => Map.get(message, "detail-type") || event.event_name,
        "Detail" => Jason.encode!(Map.get(message, "detail") || message),
        "Resources" => Map.get(message, "resources") || []
      }
      |> maybe_put("EventBusName", event_bus_name(opts))

    with :ok <- AWSClient.ensure_supported_partition(partition),
         {:ok, request} <-
           AWSClient.signed_json_request(
             :post,
             AWSClient.endpoint(opts, :eventbridge, %{partition: partition, region: region}),
             "events",
             region,
             %{
               "x-amz-target" => @eventbridge_target,
               "content-type" => "application/x-amz-json-1.1"
             },
             %{"Entries" => [entry]},
             opts
           ),
         {:ok, body} <- AWSClient.perform_request(request, opts),
         :ok <- ensure_eventbridge_success(body) do
      :ok
    end
  end

  defp ensure_eventbridge_success(nil), do: {:error, :eventbridge_empty_response}

  defp ensure_eventbridge_success(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> ensure_eventbridge_success(decoded)
      {:error, reason} -> {:error, {:eventbridge_bad_response, Exception.message(reason)}}
    end
  end

  defp ensure_eventbridge_success(%{"FailedEntryCount" => 0, "Entries" => entries})
       when is_list(entries) do
    if Enum.all?(entries, &eventbridge_entry_delivered?/1) do
      :ok
    else
      {:error, {:eventbridge_missing_event_id, entries}}
    end
  end

  defp ensure_eventbridge_success(%{"FailedEntryCount" => count, "Entries" => entries})
       when is_integer(count) and count > 0 do
    {:error, {:eventbridge_failed_entries, entries}}
  end

  defp ensure_eventbridge_success(decoded), do: {:error, {:eventbridge_bad_response, decoded}}

  defp eventbridge_entry_delivered?(%{"EventId" => event_id}) when is_binary(event_id),
    do: event_id != ""

  defp eventbridge_entry_delivered?(_entry), do: false

  defp region(opts) do
    Keyword.get(opts, :region) ||
      System.get_env("AWS_REGION") ||
      System.get_env("AWS_DEFAULT_REGION") ||
      Application.get_env(:maxio, :s3, [])[:region] ||
      "us-east-1"
  end

  defp event_bus_name(opts),
    do: Keyword.get(opts, :event_bus_name) || Keyword.get(opts, :event_bus)

  defp eventbridge_source(opts), do: Keyword.get(opts, :eventbridge_source, "maxio.s3")

  defp destination_arn(%{destination: %{arn: arn}}) when is_binary(arn) and arn != "",
    do: {:ok, arn}

  defp destination_arn(%{destination: destination}),
    do: {:error, {:missing_destination_arn, destination}}

  defp encode_message(message), do: Jason.encode!(message)

  defp sns_message_id(body) when is_binary(body) do
    case Regex.run(~r/<MessageId>([^<]+)<\/MessageId>/, body) do
      [_, message_id] -> message_id
      _other -> nil
    end
  end

  defp sns_message_id(_body), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
