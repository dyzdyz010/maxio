defmodule Maxio.S3.Handlers.OwnershipControls do
  @moduledoc """
  ?ownershipControls handler:
  PutBucketOwnershipControls, GetBucketOwnershipControls, DeleteBucketOwnershipControls.
  """
  import Plug.Conn

  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{ControlBody, Error, ExpectedBucketOwner, Log}
  alias Maxio.S3.RequestParsers.OwnershipControls, as: Parser
  alias Maxio.S3.Views.OwnershipControls, as: View

  @limit 1_048_576

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    bucket_meta = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    {conn, xml} = read_xml_body!(conn)

    case Parser.parse(xml) do
      {:ok, config} ->
        :ok =
          Maxio.S3.OwnershipControls.reject_invalid_bucket_acl_for_enforced!(
            bucket,
            bucket_meta,
            config
          )

        :ok = BucketConfigs.put(bucket, :ownership_controls, config)

        Log.info("put bucket ownership controls",
          action: :put_bucket_ownership_controls,
          bucket: bucket,
          object_ownership: config["ObjectOwnership"]
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

    case Maxio.S3.OwnershipControls.get_config(bucket) do
      {:ok, config} ->
        body = View.render(config)

        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, body)

      :none ->
        raise Error.new(:ownership_controls_not_found, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    :ok = BucketConfigs.delete(bucket, :ownership_controls)

    Log.info("delete bucket ownership controls",
      action: :delete_bucket_ownership_controls,
      bucket: bucket
    )

    send_resp(conn, 204, "")
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, bucket} -> bucket
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_xml_body!(conn) do
    ControlBody.read_and_verify!(conn, @limit, "OwnershipControls config too large",
      require_integrity: :content_md5_or_flexible
    )
  end
end
