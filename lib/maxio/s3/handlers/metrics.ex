defmodule Maxio.S3.Handlers.Metrics do
  @moduledoc """
  ?metrics handler for Bucket Metrics configuration APIs.

  This stores the CloudWatch request metrics control-plane document only.
  Metrics emission and CloudWatch integration are separate features.
  """
  import Plug.Conn

  alias Maxio.Buckets
  alias Maxio.S3.{ControlBody, Error, ExpectedBucketOwner, Log, Metrics}
  alias Maxio.S3.RequestParsers.Metrics, as: Parser
  alias Maxio.S3.Views.Metrics, as: View

  @limit 131_072

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    id = metrics_id!(conn)
    {conn, xml} = read_xml_body!(conn)

    case Parser.parse(xml) do
      {:ok, config} ->
        case Metrics.validate_client_config(config, id) do
          {:ok, config} ->
            :ok = Metrics.put_config(bucket, config)

            Log.info("put bucket metrics configuration",
              action: :put_bucket_metrics_configuration,
              bucket: bucket,
              metrics_id: id,
              filter?: Map.has_key?(config, "Filter"),
              emission_implemented?: false
            )

            send_resp(conn, 200, "")

          {:error, :malformed_xml} ->
            raise Error.new(:malformed_xml, resource: "/" <> bucket)
        end

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    id = metrics_id!(conn)

    case Metrics.get_config(bucket, id) do
      {:ok, config} ->
        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, View.render_config(config))

      :none ->
        raise Error.new(:no_such_metrics_configuration, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    id = metrics_id!(conn)
    :ok = Metrics.delete_config(bucket, id)

    Log.info("delete bucket metrics configuration",
      action: :delete_bucket_metrics_configuration,
      bucket: bucket,
      metrics_id: id
    )

    send_resp(conn, 204, "")
  end

  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    page = Metrics.list_configs(bucket, Map.get(conn.query_params || %{}, "continuation-token"))

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, View.render_list(page))
  end

  defp metrics_id!(conn) do
    id = conn.query_params |> Map.get("id") |> normalize_query_value()

    if Metrics.valid_id?(id) do
      id
    else
      raise Error.new(:invalid_argument,
              message:
                "The metrics configuration id is required and must be 1 to 64 characters of letters, numbers, periods, dashes, or underscores.",
              resource: "/" <> conn.assigns.s3_bucket
            )
    end
  end

  defp normalize_query_value([value | _rest]), do: to_string(value)
  defp normalize_query_value(value) when is_binary(value), do: value
  defp normalize_query_value(nil), do: nil
  defp normalize_query_value(value), do: to_string(value)

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, bucket} -> bucket
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_xml_body!(conn) do
    ControlBody.read_and_verify!(conn, @limit, "MetricsConfiguration exceeds 128KB")
  end
end
