defmodule Maxio.S3.Handlers.Notification do
  @moduledoc """
  ?notification handler for PutBucketNotificationConfiguration and
  GetBucketNotificationConfiguration.

  This handler stores the control-plane document. SNS/SQS/Lambda destination
  validation is delegated to a configurable validator; without one, direct
  destinations fail closed unless the request explicitly skips validation.
  """
  import Plug.Conn

  alias Maxio.{Buckets, BucketConfigs}

  alias Maxio.S3.{
    ControlBody,
    Error,
    ExpectedBucketOwner,
    Log,
    Notification,
    NotificationDestinationValidator
  }

  alias Maxio.S3.RequestParsers.Notification, as: Parser
  alias Maxio.S3.Views.Notification, as: View

  @limit 131_072

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    {conn, xml} = read_xml_body!(conn)

    case Parser.parse(xml) do
      {:ok, config} ->
        {:ok, config} = Notification.validate_client_config(config)
        validation = validate_delivery_boundary!(conn, config)
        :ok = persist_config(bucket, config)

        Log.info("put bucket notification configuration",
          action: :put_bucket_notification,
          bucket: bucket,
          topic_configurations: length(config["TopicConfigurations"]),
          queue_configurations: length(config["QueueConfigurations"]),
          lambda_function_configurations: length(config["LambdaFunctionConfigurations"]),
          event_bridge_configuration?: not is_nil(config["EventBridgeConfiguration"]),
          destination_validation: validation[:status],
          test_messages_sent: get_in(validation, [:metadata, :test_messages_sent])
        )

        conn
        |> maybe_put_sns_test_message_id(config, validation)
        |> send_resp(200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    {:ok, config} = Notification.get_config(bucket)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, View.render(config))
  end

  defp persist_config(bucket, config) do
    if Notification.empty_config?(config) do
      BucketConfigs.delete(bucket, :notification)
    else
      BucketConfigs.put(bucket, :notification, config)
    end
  end

  defp validate_delivery_boundary!(conn, config) do
    bucket = conn.assigns.s3_bucket

    cond do
      Notification.empty_config?(config) ->
        %{status: :empty}

      skip_destination_validation?(conn) ->
        %{status: :skipped}

      true ->
        case NotificationDestinationValidator.validate(bucket, config) do
          {:ok, metadata} ->
            %{status: :validated, metadata: metadata}

          {:error, :no_validator} ->
            raise Error.new(:not_implemented,
                    message:
                      "Bucket notification destination validation is not configured; retry with x-amz-skip-destination-validation:true to store direct SNS/SQS/Lambda destinations without validation",
                    resource: "/" <> bucket
                  )

          {:error, reason} ->
            Log.warn("bucket notification destination validation failed",
              action: :put_bucket_notification,
              bucket: bucket,
              reason: inspect(reason)
            )

            raise Error.new(:invalid_argument,
                    message: "Unable to validate the following destination configurations",
                    resource: "/" <> bucket
                  )
        end
    end
  end

  defp maybe_put_sns_test_message_id(conn, config, validation) do
    message_id = get_in(validation, [:metadata, :sns_test_message_id])

    if single_reduced_redundancy_topic?(config) and is_binary(message_id) and message_id != "" do
      put_resp_header(conn, "x-amz-sns-test-message-id", message_id)
    else
      conn
    end
  end

  defp single_reduced_redundancy_topic?(config) do
    match?(
      %{
        "TopicConfigurations" => [%{"Events" => ["s3:ReducedRedundancyLostObject"]}],
        "QueueConfigurations" => [],
        "LambdaFunctionConfigurations" => [],
        "EventBridgeConfiguration" => nil
      },
      config
    )
  end

  defp skip_destination_validation?(conn) do
    conn
    |> get_req_header("x-amz-skip-destination-validation")
    |> case do
      [value] -> value |> String.trim() |> String.downcase() == "true"
      _other -> false
    end
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, bucket} -> bucket
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_xml_body!(conn) do
    ControlBody.read_and_verify!(conn, @limit, "NotificationConfiguration exceeds 128KB")
  end
end
