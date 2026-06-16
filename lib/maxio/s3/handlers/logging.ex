defmodule Maxio.S3.Handlers.Logging do
  @moduledoc """
  ?logging handler for PutBucketLogging and GetBucketLogging.

  This stores and returns the S3 BucketLoggingStatus control-plane document.
  Server access log delivery is a separate data-plane feature.
  """
  import Plug.Conn

  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{Checksum, Error, Log, Logging, OwnershipControls}
  alias Maxio.S3.RequestParsers.Logging, as: Parser
  alias Maxio.S3.Views.Logging, as: View

  @limit 131_072
  @local_account_id "000000000000"

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = verify_expected_bucket_owner!(conn, bucket)
    :ok = reject_streaming_body!(conn)
    :ok = reject_checksum_trailers!(conn)
    {conn, xml} = read_small_body!(conn)
    :ok = validate_checksums!(conn, xml)

    case Parser.parse(xml) do
      {:ok, %{"LoggingEnabled" => nil}} ->
        :ok = BucketConfigs.delete(bucket, :logging)

        Log.info("disable bucket logging", action: :put_bucket_logging, bucket: bucket)

        send_resp(conn, 200, "")

      {:ok, config} ->
        config = validate_config!(config, bucket)
        :ok = BucketConfigs.put(bucket, :logging, config)

        enabled = config["LoggingEnabled"]

        Log.info("put bucket logging",
          action: :put_bucket_logging,
          bucket: bucket,
          target_bucket: enabled["TargetBucket"],
          target_prefix: enabled["TargetPrefix"]
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
    :ok = verify_expected_bucket_owner!(conn, bucket)
    {:ok, config} = Logging.get_config(bucket)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, View.render(config))
  end

  defp validate_config!(config, source_bucket) do
    normalized =
      case Logging.validate_client_config(config) do
        {:ok, %{"LoggingEnabled" => enabled} = normalized} when is_map(enabled) ->
          normalized

        _other ->
          raise Error.new(:malformed_xml, resource: "/" <> source_bucket)
      end

    enabled = normalized["LoggingEnabled"]

    :ok = verify_target_bucket!(enabled["TargetBucket"], source_bucket)
    :ok = reject_target_grants_for_enforced_target!(enabled, source_bucket)

    normalized
  end

  defp verify_target_bucket!(source_bucket, source_bucket), do: :ok

  defp verify_target_bucket!(target_bucket, source_bucket) do
    case Buckets.lookup(target_bucket) do
      {:ok, _bucket} ->
        :ok

      {:error, :not_found} ->
        raise Error.new(:invalid_target_bucket_for_logging, resource: "/" <> source_bucket)
    end
  end

  defp reject_target_grants_for_enforced_target!(
         %{"TargetBucket" => target_bucket, "TargetGrants" => grants},
         source_bucket
       )
       when is_list(grants) and grants != [] do
    if OwnershipControls.bucket_owner_enforced?(target_bucket) do
      raise Error.new(:invalid_target_bucket_for_logging, resource: "/" <> source_bucket)
    end

    :ok
  end

  defp reject_target_grants_for_enforced_target!(_enabled, _source_bucket), do: :ok

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
        raise Error.new(:malformed_xml, message: "BucketLoggingStatus exceeds 128KB")

      {:error, _reason} ->
        raise Error.new(:malformed_xml)
    end
  end

  defp reject_streaming_body!(conn) do
    if conn.assigns[:payload_mode] == :streaming do
      raise Error.new(:not_implemented,
              message: "Bucket Logging aws-chunked XML bodies are not implemented",
              resource: "/" <> conn.assigns.s3_bucket
            )
    end

    :ok
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

  defp reject_checksum_trailers!(conn) do
    case get_req_header(conn, "x-amz-trailer") do
      [] ->
        :ok

      _trailers ->
        raise Error.new(:not_implemented,
                message: "Bucket Logging checksum trailers are not implemented",
                resource: "/" <> conn.assigns.s3_bucket
              )
    end
  end
end
