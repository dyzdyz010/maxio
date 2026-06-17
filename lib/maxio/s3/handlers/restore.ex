defmodule Maxio.S3.Handlers.Restore do
  @moduledoc """
  RestoreObject control-plane handler.

  maxio does not yet move bytes to a real archive tier. For cold storage classes,
  RestoreObject records S3-visible restore metadata so HEAD/GET can expose
  `x-amz-restore` and GET can fail closed until a restore request succeeds.
  """

  import Plug.Conn

  alias Maxio.{Buckets, ObjectRestoreSidecar, Objects}
  alias Maxio.S3.{Checksum, Error, Log}
  alias Maxio.S3.RequestParsers.Restore, as: Parser
  alias Maxio.Versioning.VersionId

  @limit 131_072
  @local_account_id "000000000000"

  @spec post(Plug.Conn.t()) :: Plug.Conn.t()
  def post(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    _ = ensure_bucket!(bucket)
    :ok = verify_expected_bucket_owner!(conn, bucket)
    :ok = Maxio.Cluster.Paths.validate_key(key)

    version_id =
      conn.query_params
      |> Map.get("versionId")
      |> VersionId.normalize_param()

    :ok = validate_version_id!(bucket, key, version_id)
    :ok = reject_streaming_body!(conn)
    :ok = reject_checksum_trailers!(conn)
    {conn, xml} = read_small_body!(conn)
    :ok = validate_checksums!(conn, xml)

    request =
      case Parser.parse(xml) do
        {:ok, request} ->
          request

        {:error, :select_restore} ->
          raise Error.new(:not_implemented,
                  message: "RestoreObject select restore is not implemented",
                  resource: "/#{bucket}/#{key}"
                )

        {:error, :malformed_xml} ->
          raise Error.new(:malformed_xml, resource: "/#{bucket}/#{key}")
      end

    object = object_or_raise(bucket, key, version_id)
    :ok = reject_delete_marker!(object, bucket, key)
    :ok = reject_non_archive_storage!(object, bucket, key)

    {status, attrs} = restore_response_and_attrs(object, request)

    case update_restore_state_authoritative(bucket, key, object.version_id, attrs) do
      :ok ->
        Log.info("restore object metadata updated",
          action: :restore_object,
          bucket: bucket,
          key: key,
          version_id: object.version_id,
          storage_class: object.storage_class,
          days: request["Days"],
          tier: request["Tier"],
          status: status
        )

        conn
        |> maybe_put_version_id(object.version_id)
        |> send_resp(status, "")

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      {:error, reason} when reason in [:write_quorum, :read_quorum, :no_topology] ->
        raise Error.new(:slow_down_write, resource: "/#{bucket}/#{key}")

      {:error, _reason} ->
        raise Error.new(:internal_error, resource: "/#{bucket}/#{key}")
    end
  end

  defp restore_response_and_attrs(object, %{"Days" => days}) do
    attrs = %{
      restore_status: "restored",
      restore_expiry: DateTime.add(DateTime.utc_now(), days * 86_400, :second)
    }

    if restore_active?(object), do: {200, attrs}, else: {202, attrs}
  end

  defp update_restore_state_authoritative(bucket, key, version_id, attrs) do
    case Maxio.ObjectMeta.authoritative_source(:write) do
      :sidecar ->
        update_restore_state_sidecar(bucket, key, version_id, attrs)

      _pg ->
        update_restore_state_pg(bucket, key, version_id, attrs)
    end
  end

  defp update_restore_state_sidecar(bucket, key, version_id, attrs) do
    case ObjectRestoreSidecar.update(bucket, key, version_id, attrs) do
      {:ok, generation} ->
        best_effort_restore_index_update(bucket, key, version_id, attrs, generation)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_restore_state_pg(bucket, key, version_id, attrs) do
    case Objects.put_restore_state(bucket, key, version_id, attrs) do
      {:ok, _object} ->
        mirror_restore_sidecar(bucket, key, version_id, attrs)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp best_effort_restore_index_update(bucket, key, version_id, attrs, generation) do
    case Objects.put_restore_state(bucket, key, version_id, attrs, generation) do
      {:ok, _object} ->
        :ok

      {:error, reason} ->
        Log.error("pg restore index update failed",
          action: :restore_object,
          bucket: bucket,
          key: key,
          version_id: version_id,
          reason: inspect(reason)
        )
    end
  end

  defp mirror_restore_sidecar(bucket, key, version_id, attrs) do
    case ObjectRestoreSidecar.update(bucket, key, version_id, attrs) do
      {:ok, generation} ->
        _ = Objects.put_restore_state(bucket, key, version_id, attrs, generation)
        :ok

      {:error, reason} ->
        Log.warn("sidecar restore metadata mirror failed (PG remains authoritative)",
          action: :restore_object,
          bucket: bucket,
          key: key,
          version_id: version_id,
          reason: inspect(reason)
        )
    end
  rescue
    e ->
      Log.warn("sidecar restore metadata mirror raised (PG remains authoritative)",
        action: :restore_object,
        bucket: bucket,
        key: key,
        version_id: version_id,
        reason: inspect(e)
      )
  end

  defp object_or_raise(bucket, key, version_id) do
    case Maxio.ObjectMeta.get(bucket, key, version_id, []) do
      %Objects.Object{} = object -> object
      {:error, :not_found} -> raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
      {:error, :read_quorum} -> raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")
    end
  end

  defp reject_delete_marker!(%Objects.Object{is_delete_marker: false}, _bucket, _key), do: :ok

  defp reject_delete_marker!(%Objects.Object{}, bucket, key) do
    raise Error.new(:method_not_allowed, resource: "/#{bucket}/#{key}")
  end

  defp reject_non_archive_storage!(%Objects.Object{storage_class: storage_class}, bucket, key) do
    if archive_storage_class?(storage_class) do
      :ok
    else
      raise Error.new(:invalid_object_state,
              message: "RestoreObject is not valid for this object's storage class",
              resource: "/#{bucket}/#{key}"
            )
    end
  end

  defp archive_storage_class?(storage_class) do
    storage_class in ["GLACIER", "DEEP_ARCHIVE"]
  end

  defp restore_active?(%Objects.Object{
         restore_status: "restored",
         restore_expiry: %DateTime{} = dt
       }) do
    DateTime.compare(dt, DateTime.utc_now()) == :gt
  end

  defp restore_active?(_object), do: false

  defp validate_version_id!(_bucket, _key, nil), do: :ok

  defp validate_version_id!(bucket, key, version_id) do
    if VersionId.valid?(version_id) do
      :ok
    else
      raise Error.new(:invalid_argument,
              message: "Invalid version id specified",
              resource: "/#{bucket}/#{key}"
            )
    end
  end

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

  defp reject_streaming_body!(conn) do
    if conn.assigns[:payload_mode] == :streaming do
      raise Error.new(:not_implemented,
              message: "RestoreObject aws-chunked XML bodies are not implemented",
              resource: "/#{conn.assigns.s3_bucket}/#{conn.assigns.s3_key}"
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
                message: "RestoreObject checksum trailers are not implemented",
                resource: "/#{conn.assigns.s3_bucket}/#{conn.assigns.s3_key}"
              )
    end
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @limit, read_length: @limit) do
      {:ok, body, conn} ->
        {conn, body}

      {:more, _partial, _conn} ->
        raise Error.new(:malformed_xml, message: "RestoreRequest exceeds 128KB")

      {:error, _reason} ->
        raise Error.new(:malformed_xml)
    end
  end

  defp validate_checksums!(conn, body) do
    checksum = Checksum.from_conn!(conn)
    {stream, get_context, _discard_context} = Checksum.wrap_stream([body], checksum)
    _ = Enum.to_list(stream)
    checksum = get_context.()
    checksum.verify!.()
  end

  defp maybe_put_version_id(conn, "null"), do: conn

  defp maybe_put_version_id(conn, version_id),
    do: put_resp_header(conn, "x-amz-version-id", version_id)
end
