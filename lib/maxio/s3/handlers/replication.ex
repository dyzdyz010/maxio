defmodule Maxio.S3.Handlers.Replication do
  @moduledoc """
  ?replication handler for Bucket Replication configuration APIs.

  This stores the replication control-plane document only. Background object
  replication is a separate feature.
  """
  import Plug.Conn

  alias Maxio.Buckets
  alias Maxio.S3.{Authz, ControlBody, Error, ExpectedBucketOwner, Log, Replication}
  alias Maxio.S3.RequestParsers.Replication, as: Parser
  alias Maxio.S3.Views.Replication, as: View

  @limit 131_072

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    bucket_meta = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    {conn, xml} = read_xml_body!(conn)

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
    :ok = ExpectedBucketOwner.verify!(conn, bucket)

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
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
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

  defp read_xml_body!(conn) do
    ControlBody.read_and_verify!(conn, @limit, "ReplicationConfiguration exceeds 128KB",
      require_integrity: :content_md5_or_flexible
    )
  end
end
