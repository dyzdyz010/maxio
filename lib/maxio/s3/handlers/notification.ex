defmodule Maxio.S3.Handlers.Notification do
  @moduledoc """
  ?notification handler for PutBucketNotificationConfiguration and
  GetBucketNotificationConfiguration.

  This slice stores the control-plane document only. Actual event delivery is
  not implemented, so non-empty configs must opt out of destination validation
  with x-amz-skip-destination-validation:true.
  """
  import Plug.Conn

  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{Checksum, Error, Log, Notification}
  alias Maxio.S3.RequestParsers.Notification, as: Parser
  alias Maxio.S3.Views.Notification, as: View

  @limit 131_072
  @local_account_id "000000000000"

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = verify_expected_bucket_owner!(conn, bucket)
    :ok = reject_streaming_body!(conn)
    :ok = reject_checksum_trailers!(conn)
    {conn, xml} = read_small_body!(conn)
    :ok = validate_checksums!(conn, xml)

    case Parser.parse(xml) do
      {:ok, config} ->
        {:ok, config} = Notification.validate_client_config(config)
        :ok = validate_delivery_boundary!(conn, config)
        :ok = persist_config(bucket, config)

        Log.info("put bucket notification configuration",
          action: :put_bucket_notification,
          bucket: bucket,
          topic_configurations: length(config["TopicConfigurations"]),
          queue_configurations: length(config["QueueConfigurations"]),
          lambda_function_configurations: length(config["LambdaFunctionConfigurations"]),
          event_bridge_configuration?: not is_nil(config["EventBridgeConfiguration"]),
          delivery_implemented?: false
        )

        send_resp(conn, 200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = verify_expected_bucket_owner!(conn, bucket)
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
    if Notification.empty_config?(config) or skip_destination_validation?(conn) do
      :ok
    else
      raise Error.new(:not_implemented,
              message:
                "Bucket notification destination validation and event delivery are not implemented; retry with x-amz-skip-destination-validation:true to store configuration only",
              resource: "/" <> conn.assigns.s3_bucket
            )
    end
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

  defp verify_expected_bucket_owner!(conn, bucket) do
    case get_req_header(conn, "x-amz-expected-bucket-owner") do
      [] ->
        :ok

      [owner] ->
        if owner == account_id() do
          :ok
        else
          raise Error.new(:access_denied, resource: "/" <> bucket)
        end

      _multiple ->
        raise Error.new(:access_denied, resource: "/" <> bucket)
    end
  end

  defp account_id do
    :maxio
    |> Application.get_env(:sts, [])
    |> Keyword.get(:account_id, @local_account_id)
    |> to_string()
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @limit, read_length: @limit) do
      {:ok, body, conn} ->
        {conn, body}

      {:more, _partial, _conn} ->
        raise Error.new(:malformed_xml, message: "NotificationConfiguration exceeds 128KB")

      {:error, _reason} ->
        raise Error.new(:malformed_xml)
    end
  end

  defp reject_streaming_body!(conn) do
    if conn.assigns[:payload_mode] == :streaming do
      raise Error.new(:not_implemented,
              message: "Bucket Notification aws-chunked XML bodies are not implemented",
              resource: "/" <> conn.assigns.s3_bucket
            )
    end

    :ok
  end

  defp validate_checksums!(conn, body) do
    checksum = Checksum.from_conn!(conn)
    {stream, get_context, _discard_context} = Checksum.wrap_stream([body], checksum)
    _ = Enum.to_list(stream)
    checksum = get_context.()
    checksum.verify!.()
  end

  defp reject_checksum_trailers!(conn) do
    case get_req_header(conn, "x-amz-trailer") do
      [] ->
        :ok

      _trailers ->
        raise Error.new(:not_implemented,
                message: "Bucket Notification checksum trailers are not implemented",
                resource: "/" <> conn.assigns.s3_bucket
              )
    end
  end
end
