defmodule Maxio.S3.Handlers.Encryption do
  @moduledoc """
  ?encryption 子资源 handler：PutBucketEncryption（XML → 校验 AES256 → 存，200）、
  GetBucketEncryption（200+XML，无→404 ServerSideEncryptionConfigurationNotFoundError）、
  DeleteBucketEncryption（204）。
  MVP 仅 SSE-S3 AES256：SSEAlgorithm 非 AES256（aws:kms/aws:kms:dsse）→ 501 NotImplemented（绝不静默）；
  KMSMasterKeyID 与 AES256 共存 → 400 InvalidArgument。BucketKeyEnabled 接受但 no-op（KMS 专属）。
  """
  import Plug.Conn
  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.RequestParsers.Encryption, as: Parser
  alias Maxio.S3.Views.Encryption, as: View

  @limit 1_048_576

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, xml} = read_small_body!(conn)

    case Parser.parse(xml) do
      {:ok, %{algorithm: "AES256", kms_key_id: kms, bucket_key_enabled: bk}} ->
        if kms not in [nil, ""] do
          raise Error.new(:invalid_argument,
                  message: "KMSMasterKeyID is only valid with aws:kms/aws:kms:dsse"
                )
        end

        :ok =
          BucketConfigs.put(bucket, :encryption, %{
            "algorithm" => "AES256",
            "bucket_key_enabled" => bk
          })

        Log.info("put bucket encryption",
          action: :put_bucket_encryption,
          bucket: bucket,
          reason: "AES256"
        )

        send_resp(conn, 200, "")

      {:ok, %{algorithm: alg}} when alg in ["aws:kms", "aws:kms:dsse"] ->
        raise Error.new(:not_implemented,
                message: "Only SSE-S3 (AES256) is supported; #{alg} not implemented"
              )

      {:ok, _other} ->
        raise Error.new(:malformed_xml, message: "Invalid SSEAlgorithm")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)

    case BucketConfigs.get(bucket, :encryption) do
      {:ok, %{"algorithm" => alg} = cfg} ->
        body =
          View.render(%{
            algorithm: alg,
            bucket_key_enabled: Map.get(cfg, "bucket_key_enabled", false)
          })

        conn |> put_resp_content_type("application/xml") |> send_resp(200, body)

      :none ->
        raise Error.new(:server_side_encryption_configuration_not_found, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = BucketConfigs.delete(bucket, :encryption)
    Log.info("delete bucket encryption", action: :delete_bucket_encryption, bucket: bucket)
    send_resp(conn, 204, "")
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @limit, read_length: @limit) do
      {:ok, body, conn} ->
        {conn, body}

      {:more, _partial, _conn} ->
        raise Error.new(:malformed_xml, message: "Encryption config too large")

      {:error, _} ->
        raise Error.new(:malformed_xml)
    end
  end
end
