defmodule Maxio.S3.Handlers.Inventory do
  @moduledoc """
  ?inventory handler for Bucket Inventory configuration APIs.

  This stores the inventory control-plane document. Report objects are produced
  by the explicit local runner in `Maxio.S3.Inventory.Report`.
  """
  import Plug.Conn

  alias Maxio.Buckets
  alias Maxio.S3.{Authz, ControlBody, Error, ExpectedBucketOwner, Inventory, Log}
  alias Maxio.S3.RequestParsers.Inventory, as: Parser
  alias Maxio.S3.Views.Inventory, as: View

  @limit 131_072

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    id = inventory_id!(conn)
    {conn, xml} = read_xml_body!(conn)

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
              optional_fields: Inventory.optional_fields(config)
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
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
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
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
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

  defp read_xml_body!(conn) do
    ControlBody.read_and_verify!(conn, @limit, "InventoryConfiguration exceeds 128KB")
  end
end
