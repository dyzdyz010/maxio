defmodule Maxio.S3.Handlers.Accelerate do
  @moduledoc """
  ?accelerate handler for PutBucketAccelerateConfiguration and GetBucketAccelerateConfiguration.
  """
  import Plug.Conn

  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{ControlBody, Error, ExpectedBucketOwner, Log}
  alias Maxio.S3.RequestParsers.Accelerate, as: Parser
  alias Maxio.S3.Views.Accelerate, as: View

  @limit 131_072

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    :ok = reject_dotted_bucket!(bucket)
    {conn, xml} = read_xml_body!(conn)

    case Parser.parse(xml) do
      {:ok, config} ->
        :ok = BucketConfigs.put(bucket, :accelerate, config)

        Log.info("put bucket accelerate configuration",
          action: :put_bucket_accelerate_configuration,
          bucket: bucket,
          status: config["Status"]
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
    {:ok, config} = Maxio.S3.Accelerate.get_config(bucket)

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

  defp reject_dotted_bucket!(bucket) do
    if String.contains?(bucket, ".") do
      raise Error.new(:invalid_request,
              message:
                "Transfer Acceleration is not supported for buckets with periods in their names",
              resource: "/" <> bucket
            )
    end

    :ok
  end

  defp read_xml_body!(conn) do
    ControlBody.read_and_verify!(conn, @limit, "AccelerateConfiguration exceeds 128KB")
  end
end
