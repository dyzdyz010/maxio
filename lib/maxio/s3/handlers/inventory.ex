defmodule Maxio.S3.Handlers.Inventory do
  @moduledoc """
  ?inventory handler for Bucket Inventory configuration APIs.

  This stores the inventory control-plane document only. Inventory report
  generation is a separate feature.
  """
  import Plug.Conn

  alias Maxio.Buckets
  alias Maxio.S3.{Authz, Checksum, Error, Inventory, Log}
  alias Maxio.S3.RequestParsers.Inventory, as: Parser
  alias Maxio.S3.Views.Inventory, as: View

  @limit 131_072
  @local_account_id "000000000000"

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = verify_expected_bucket_owner!(conn, bucket)
    id = inventory_id!(conn)
    :ok = reject_streaming_body!(conn)
    :ok = reject_checksum_trailers!(conn)
    {conn, xml} = read_small_body!(conn)
    :ok = validate_checksums!(conn, xml)

    case Parser.parse(xml) do
      {:ok, config} ->
        case Inventory.validate_client_config(config, id) do
          {:ok, config} ->
            :ok =
              Authz.authorize_put_bucket_inventory_configuration(
                conn,
                bucket,
                Inventory.optional_fields(config)
              )

            :ok = Inventory.put_config(bucket, config)

            Log.info("put bucket inventory configuration",
              action: :put_bucket_inventory_configuration,
              bucket: bucket,
              inventory_id: id,
              optional_fields: Inventory.optional_fields(config),
              report_generation_implemented?: false
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
    :ok = verify_expected_bucket_owner!(conn, bucket)
    id = inventory_id!(conn)

    case Inventory.get_config(bucket, id) do
      {:ok, config} ->
        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, View.render_config(config))

      :none ->
        raise Error.new(:no_such_inventory_configuration, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = verify_expected_bucket_owner!(conn, bucket)
    id = inventory_id!(conn)
    :ok = Inventory.delete_config(bucket, id)

    Log.info("delete bucket inventory configuration",
      action: :delete_bucket_inventory_configuration,
      bucket: bucket,
      inventory_id: id
    )

    send_resp(conn, 204, "")
  end

  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = verify_expected_bucket_owner!(conn, bucket)
    page = Inventory.list_configs(bucket, Map.get(conn.query_params || %{}, "continuation-token"))

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, View.render_list(page))
  end

  defp inventory_id!(conn) do
    id = conn.query_params |> Map.get("id") |> normalize_query_value()

    if Inventory.valid_id?(id) do
      id
    else
      raise Error.new(:invalid_argument,
              message:
                "The inventory configuration id is required and must be 1 to 64 characters of letters, numbers, periods, dashes, or underscores.",
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
        raise Error.new(:malformed_xml, message: "InventoryConfiguration exceeds 128KB")

      {:error, _reason} ->
        raise Error.new(:malformed_xml)
    end
  end

  defp reject_streaming_body!(conn) do
    if conn.assigns[:payload_mode] == :streaming do
      raise Error.new(:not_implemented,
              message: "Bucket Inventory aws-chunked XML bodies are not implemented",
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
                message: "Bucket Inventory checksum trailers are not implemented",
                resource: "/" <> conn.assigns.s3_bucket
              )
    end
  end
end
