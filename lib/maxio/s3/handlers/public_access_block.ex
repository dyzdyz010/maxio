defmodule Maxio.S3.Handlers.PublicAccessBlock do
  @moduledoc """
  ?publicAccessBlock handler:
  PutPublicAccessBlock（XML → 校验/存，200）、GetPublicAccessBlock（200+XML，无→404）、
  DeletePublicAccessBlock（204）。
  """
  import Plug.Conn
  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{ControlBody, Error, ExpectedBucketOwner, Log}
  alias Maxio.S3.RequestParsers.PublicAccessBlock, as: Parser
  alias Maxio.S3.Views.PublicAccessBlock, as: View

  @limit 1_048_576

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    {conn, xml} = read_xml_body!(conn)

    case Parser.parse(xml) do
      {:ok, config} ->
        :ok = BucketConfigs.put(bucket, :public_access_block, config)

        Log.info("put public access block",
          action: :put_public_access_block,
          bucket: bucket,
          block_public_acls: config["BlockPublicAcls"],
          ignore_public_acls: config["IgnorePublicAcls"],
          block_public_policy: config["BlockPublicPolicy"],
          restrict_public_buckets: config["RestrictPublicBuckets"]
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

    case Maxio.S3.PublicAccessBlock.get_config(bucket) do
      {:ok, config} ->
        body = View.render(config)

        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, body)

      :none ->
        raise Error.new(:no_such_public_access_block_configuration, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    :ok = BucketConfigs.delete(bucket, :public_access_block)

    Log.info("delete public access block",
      action: :delete_public_access_block,
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
    ControlBody.read_and_verify!(conn, @limit, "PublicAccessBlock config too large",
      require_integrity: :content_md5
    )
  end
end
