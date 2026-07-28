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
  alias Maxio.KMS
  alias Maxio.S3.{ControlBody, Error, ExpectedBucketOwner, Log}
  alias Maxio.S3.RequestParsers.Encryption, as: Parser
  alias Maxio.S3.Views.Encryption, as: View

  @limit 1_048_576

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    {conn, xml} = read_xml_body!(conn)

    case Parser.parse(xml) do
      {:ok, %{unsupported_multiple_rules?: true}} ->
        raise Error.new(:not_implemented,
                message: "Multiple bucket encryption rules are not implemented"
              )

      {:ok, %{blocked_encryption_types: [_ | _]}} ->
        raise Error.new(:not_implemented,
                message: "BlockedEncryptionTypes is not implemented"
              )

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

      {:ok, %{algorithm: "aws:kms", kms_key_id: kms, bucket_key_enabled: bk}} ->
        :ok =
          BucketConfigs.put(bucket, :encryption, %{
            "algorithm" => "aws:kms",
            "kms_key_id" => normalize_kms_key_id(kms),
            "bucket_key_enabled" => bk
          })

        Log.info("put bucket encryption",
          action: :put_bucket_encryption,
          bucket: bucket,
          reason: "aws:kms"
        )

        send_resp(conn, 200, "")

      {:ok, %{algorithm: "aws:kms:dsse", kms_key_id: kms, bucket_key_enabled: bk}} ->
        if bk do
          raise Error.new(:invalid_argument,
                  message: "S3 Bucket Keys are not supported with DSSE-KMS"
                )
        end

        :ok =
          BucketConfigs.put(bucket, :encryption, %{
            "algorithm" => "aws:kms:dsse",
            "kms_key_id" => normalize_kms_key_id(kms),
            "bucket_key_enabled" => false
          })

        Log.info("put bucket encryption",
          action: :put_bucket_encryption,
          bucket: bucket,
          reason: "aws:kms:dsse"
        )

        send_resp(conn, 200, "")

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
    :ok = ExpectedBucketOwner.verify!(conn, bucket)

    case BucketConfigs.get(bucket, :encryption) do
      {:ok, %{"algorithm" => alg} = cfg} ->
        body =
          View.render(%{
            algorithm: alg,
            kms_key_id: Map.get(cfg, "kms_key_id"),
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
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
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

  defp read_xml_body!(conn) do
    ControlBody.read_and_verify!(conn, @limit, "Encryption config too large",
      require_integrity: :content_md5_or_flexible
    )
  end

  defp normalize_kms_key_id(nil), do: KMS.default_key_id()
  defp normalize_kms_key_id(""), do: KMS.default_key_id()
  defp normalize_kms_key_id(key_id) when is_binary(key_id), do: key_id
end
