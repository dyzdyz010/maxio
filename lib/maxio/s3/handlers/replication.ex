defmodule Maxio.S3.Handlers.Replication do
  @moduledoc """
  ?replication handler for Bucket Replication configuration APIs.

  This stores the replication control-plane document only. Background object
  replication is a separate feature.
  """
  import Plug.Conn

  alias Maxio.Buckets
  alias Maxio.S3.{Authz, Checksum, Error, Log, Replication}
  alias Maxio.S3.RequestParsers.Replication, as: Parser
  alias Maxio.S3.Views.Replication, as: View

  @limit 131_072
  @local_account_id "000000000000"

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    bucket_meta = ensure_bucket!(bucket)
    :ok = verify_expected_bucket_owner!(conn, bucket)
    :ok = reject_streaming_body!(conn)
    :ok = reject_checksum_trailers!(conn)
    {conn, xml} = read_small_body!(conn)
    :ok = validate_checksums!(conn, xml)

    case Parser.parse(xml) do
      {:ok, config} ->
        case Replication.validate_client_config(config) do
          {:ok, config} ->
            :ok = require_versioning_enabled!(bucket_meta)
            :ok = Authz.authorize_pass_role(conn, config["Role"])
            :ok = Replication.put_config(bucket, config)

            Log.info("put bucket replication configuration",
              action: :put_bucket_replication,
              bucket: bucket,
              rule_count: length(config["Rules"]),
              replication_implemented?: false
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
    :ok = verify_expected_bucket_owner!(conn, bucket)

    case Replication.get_config(bucket) do
      {:ok, config} ->
        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, View.render_config(config))

      :none ->
        raise Error.new(:replication_configuration_not_found, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = verify_expected_bucket_owner!(conn, bucket)
    :ok = Replication.delete_config(bucket)

    Log.info("delete bucket replication configuration",
      action: :delete_bucket_replication,
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

  defp require_versioning_enabled!(%{name: _bucket, versioning: "Enabled"}), do: :ok

  defp require_versioning_enabled!(%{name: bucket}) do
    raise Error.new(:invalid_request,
            message:
              "Versioning must be enabled on the bucket to apply a replication configuration",
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
        raise Error.new(:malformed_xml, message: "ReplicationConfiguration exceeds 128KB")

      {:error, _reason} ->
        raise Error.new(:malformed_xml)
    end
  end

  defp reject_streaming_body!(conn) do
    if conn.assigns[:payload_mode] == :streaming do
      raise Error.new(:not_implemented,
              message: "Bucket Replication aws-chunked XML bodies are not implemented",
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
                message: "Bucket Replication checksum trailers are not implemented",
                resource: "/" <> conn.assigns.s3_bucket
              )
    end
  end
end
