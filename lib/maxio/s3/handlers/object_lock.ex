defmodule Maxio.S3.Handlers.ObjectLock do
  @moduledoc """
  ?object-lock handler for Bucket Object Lock configuration APIs.

  This stores the bucket-level default retention configuration only. Object
  retention, legal hold, and write-path enforcement are separate object-level
  features.
  """
  import Plug.Conn

  alias Maxio.Buckets
  alias Maxio.S3.{Checksum, Error, Log, ObjectLock}
  alias Maxio.S3.RequestParsers.ObjectLock, as: Parser
  alias Maxio.S3.Views.ObjectLock, as: View

  @limit 131_072
  @local_account_id "000000000000"

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    bucket_meta = ensure_bucket!(bucket)
    :ok = verify_expected_bucket_owner!(conn, bucket)
    :ok = require_bucket_object_lock_enabled!(bucket_meta)
    :ok = reject_streaming_body!(conn)
    :ok = reject_checksum_trailers!(conn)
    {conn, xml} = read_small_body!(conn)
    :ok = validate_checksums!(conn, xml)

    case Parser.parse(xml) do
      {:ok, config} ->
        :ok = ObjectLock.put_config(bucket, config)

        Log.info("put bucket object lock configuration",
          action: :put_bucket_object_lock_configuration,
          bucket: bucket,
          has_default_retention?: Map.has_key?(config, "Rule")
        )

        send_resp(conn, 200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    _bucket_meta = ensure_bucket!(bucket)
    :ok = verify_expected_bucket_owner!(conn, bucket)

    case ObjectLock.get_config(bucket) do
      {:ok, config} ->
        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, View.render(config))

      :none ->
        raise Error.new(:object_lock_configuration_not_found, resource: "/" <> bucket)
    end
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, bucket} -> bucket
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp require_bucket_object_lock_enabled!(%{name: bucket, versioning: "Enabled"}) do
    case ObjectLock.get_config(bucket) do
      {:ok, %{"ObjectLockEnabled" => "Enabled"}} ->
        :ok

      :none ->
        raise Error.new(:invalid_bucket_state,
                message:
                  "Object Lock configuration can only be changed for buckets created with Object Lock enabled",
                resource: "/" <> bucket
              )
    end
  end

  defp require_bucket_object_lock_enabled!(%{name: bucket}) do
    raise Error.new(:invalid_bucket_state,
            message: "Object Lock configuration requires bucket versioning to be enabled",
            resource: "/" <> bucket
          )
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
        raise Error.new(:malformed_xml, message: "ObjectLockConfiguration exceeds 128KB")

      {:error, _reason} ->
        raise Error.new(:malformed_xml)
    end
  end

  defp reject_streaming_body!(conn) do
    if conn.assigns[:payload_mode] == :streaming do
      raise Error.new(:not_implemented,
              message: "Bucket Object Lock aws-chunked XML bodies are not implemented",
              resource: "/" <> conn.assigns.s3_bucket
            )
    end

    :ok
  end

  defp reject_checksum_trailers!(conn) do
    case get_req_header(conn, "x-amz-trailer") do
      [] ->
        :ok

      _trailers ->
        raise Error.new(:not_implemented,
                message: "Bucket Object Lock checksum trailers are not implemented",
                resource: "/" <> conn.assigns.s3_bucket
              )
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
