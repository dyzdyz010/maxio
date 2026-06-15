defmodule Maxio.S3.Handlers.RequestPayment do
  @moduledoc """
  ?requestPayment handler for PutBucketRequestPayment and GetBucketRequestPayment.
  """
  import Plug.Conn

  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{Checksum, Error, Log}
  alias Maxio.S3.RequestParsers.RequestPayment, as: Parser
  alias Maxio.S3.Views.RequestPayment, as: View

  @limit 131_072

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, xml} = read_small_body!(conn)
    :ok = validate_checksums!(conn, xml)

    case Parser.parse(xml) do
      {:ok, config} ->
        :ok = BucketConfigs.put(bucket, :request_payment, config)

        Log.info("put bucket request payment",
          action: :put_bucket_request_payment,
          bucket: bucket,
          payer: config["Payer"]
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
    {:ok, config} = Maxio.S3.RequestPayment.get_config(bucket)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, View.render(config))
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, bucket} -> bucket
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @limit, read_length: @limit) do
      {:ok, body, conn} ->
        {conn, body}

      {:more, _partial, _conn} ->
        raise Error.new(:malformed_xml, message: "RequestPaymentConfiguration exceeds 128KB")

      {:error, _reason} ->
        raise Error.new(:malformed_xml)
    end
  end

  defp validate_checksums!(conn, body) do
    case get_req_header(conn, "content-md5") do
      [_value] ->
        checksum = Checksum.from_conn!(conn)
        {stream, get_context, _discard_context} = Checksum.wrap_stream([body], checksum)
        _ = Enum.to_list(stream)
        checksum = get_context.()
        checksum.verify!.()

      [] ->
        raise Error.new(:missing_security_header,
                message: "Missing required Content-MD5 header",
                resource: "/" <> conn.assigns.s3_bucket
              )

      _multiple ->
        raise Error.new(:bad_digest, resource: "/" <> conn.assigns.s3_bucket)
    end
  end
end
