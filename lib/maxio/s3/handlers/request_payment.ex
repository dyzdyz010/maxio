defmodule Maxio.S3.Handlers.RequestPayment do
  @moduledoc """
  ?requestPayment handler for PutBucketRequestPayment and GetBucketRequestPayment.
  """
  import Plug.Conn

  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{ControlBody, Error, ExpectedBucketOwner, Log}
  alias Maxio.S3.RequestParsers.RequestPayment, as: Parser
  alias Maxio.S3.Views.RequestPayment, as: View

  @limit 131_072

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    {conn, xml} = read_xml_body!(conn)

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
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
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

  defp read_xml_body!(conn) do
    ControlBody.read_and_verify!(conn, @limit, "RequestPaymentConfiguration exceeds 128KB",
      require_integrity: :content_md5
    )
  end
end
