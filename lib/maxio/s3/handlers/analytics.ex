defmodule Maxio.S3.Handlers.Analytics do
  @moduledoc """
  ?analytics handler for Bucket Analytics configuration APIs.

  This stores the analytics control-plane document only. Analytics data export
  generation is a separate feature.
  """
  import Plug.Conn

  alias Maxio.Buckets
  alias Maxio.S3.{Analytics, ControlBody, Error, ExpectedBucketOwner, Log}
  alias Maxio.S3.RequestParsers.Analytics, as: Parser
  alias Maxio.S3.Views.Analytics, as: View

  @limit 131_072

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    id = analytics_id!(conn)
    {conn, xml} = read_xml_body!(conn)

    case Parser.parse(xml) do
      {:ok, config} ->
        case Analytics.validate_client_config(config, id) do
          {:ok, config} ->
            :ok = Analytics.put_config(bucket, config)

            Log.info("put bucket analytics configuration",
              action: :put_bucket_analytics_configuration,
              bucket: bucket,
              analytics_id: id,
              filter?: Map.has_key?(config, "Filter"),
              data_export?: get_in(config, ["StorageClassAnalysis", "DataExport"]) != nil,
              export_implemented?: false
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
    id = analytics_id!(conn)

    case Analytics.get_config(bucket, id) do
      {:ok, config} ->
        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, View.render_config(config))

      :none ->
        raise Error.new(:no_such_analytics_configuration, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    id = analytics_id!(conn)
    :ok = Analytics.delete_config(bucket, id)

    Log.info("delete bucket analytics configuration",
      action: :delete_bucket_analytics_configuration,
      bucket: bucket,
      analytics_id: id
    )

    send_resp(conn, 204, "")
  end

  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    page = Analytics.list_configs(bucket, Map.get(conn.query_params || %{}, "continuation-token"))

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, View.render_list(page))
  end

  defp analytics_id!(conn) do
    id = conn.query_params |> Map.get("id") |> normalize_query_value()

    if Analytics.valid_id?(id) do
      id
    else
      raise Error.new(:invalid_argument,
              message:
                "The analytics configuration id is required and must be 1 to 64 characters of letters, numbers, periods, dashes, or underscores.",
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
    ControlBody.read_and_verify!(conn, @limit, "AnalyticsConfiguration exceeds 128KB")
  end
end
