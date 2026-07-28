defmodule Maxio.S3.Handlers.SelectObjectContent do
  @moduledoc """
  SelectObjectContent handler.

  CSV/JSON SelectObjectContent handler that stages executor output before
  emitting AWS event-stream Records/Stats/End messages. Unsupported features
  fail explicitly before response streaming starts.
  """

  import Plug.Conn

  alias Maxio.{Buckets, ObjectMeta, Objects}

  alias Maxio.S3.{
    ControlBody,
    Error,
    EventStream,
    ExpectedBucketOwner,
    Log,
    RequestPayer,
    ErrorView,
    SelectRunner
  }

  alias Maxio.S3.RequestParsers.SelectObjectContent, as: SelectParser

  @xml_limit 1_048_576
  @event_chunk_size 64 * 1024
  @response_header_overrides [
    "response-cache-control",
    "response-content-disposition",
    "response-content-encoding",
    "response-content-language",
    "response-content-type",
    "response-expires"
  ]

  @spec post(Plug.Conn.t()) :: Plug.Conn.t()
  def post(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)

    :ok = require_select_type!(conn)
    :ok = reject_anonymous!(conn, bucket, key)
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket, resource: "/#{bucket}/#{key}")
    charge = RequestPayer.require!(conn, bucket, resource: "/#{bucket}/#{key}")
    :ok = reject_unsupported_headers!(conn, bucket, key)
    :ok = reject_version_id!(conn, bucket, key)
    :ok = validate_object_key!(bucket, key)

    version_id =
      conn.query_params
      |> Map.get("versionId")
      |> Maxio.Versioning.VersionId.normalize_param()

    :ok = validate_version_id!(bucket, key, version_id)
    {object, _total} = resolve_object_for_select!(bucket, key, version_id)
    conn = assign(conn, :s3_metrics_tags, metrics_object_tags(object))

    cond do
      object.is_delete_marker and version_id == nil ->
        conn
        |> put_resp_header("x-amz-delete-marker", "true")
        |> send_select_error(Error.new(:no_such_key, resource: "/#{bucket}/#{key}"))

      object.is_delete_marker ->
        conn
        |> put_resp_header("x-amz-delete-marker", "true")
        |> put_resp_header("allow", "DELETE")
        |> put_resp_header("last-modified", http_date(object.updated_at))
        |> send_select_error(Error.new(:method_not_allowed, resource: "/#{bucket}/#{key}"))

      true ->
        :ok = SelectRunner.validate_sse_read_headers!(conn, object, bucket, key)
        {conn, body} = read_small_body!(conn)
        request = parse_request!(body)

        stream =
          SelectRunner.stage_object!(conn, object, request,
            bucket: bucket,
            key: key
          )

        Log.info("select object content",
          action: :select_object_content,
          bucket: bucket,
          key: key,
          version_id: object.version_id,
          size: stream.bytes_processed,
          auth_type: conn.assigns.auth_type
        )

        try do
          conn
          |> RequestPayer.put_charged_header(charge)
          |> put_resp_header("content-type", EventStream.content_type())
          |> send_chunked(200)
          |> stream_event_messages(stream, request.request_progress)
        after
          SelectRunner.cleanup_stream(stream)
        end
    end
  end

  defp require_select_type!(conn) do
    case Map.get(conn.query_params, "select-type") do
      "2" ->
        :ok

      _other ->
        raise Error.new(:invalid_argument,
                message: "SelectObjectContent requires select-type=2",
                resource: resource(conn)
              )
    end
  end

  defp reject_anonymous!(conn, bucket, key) do
    if conn.assigns[:principal] == :anonymous or conn.assigns[:auth_type] == :anonymous do
      Log.warn("anonymous SelectObjectContent rejected",
        action: :select_object_content,
        bucket: bucket,
        key: key,
        reason: :anonymous_not_supported
      )

      raise Error.new(:access_denied, resource: "/#{bucket}/#{key}")
    end

    :ok
  end

  defp reject_unsupported_headers!(conn, bucket, key) do
    cond do
      header(conn, "range") != nil ->
        raise Error.new(:invalid_request,
                message: "Range header is not supported for SelectObjectContent",
                resource: "/#{bucket}/#{key}"
              )

      Enum.any?(@response_header_overrides, &Map.has_key?(conn.query_params, &1)) ->
        raise Error.new(:invalid_request,
                message: "Response header overrides are not supported for SelectObjectContent",
                resource: "/#{bucket}/#{key}"
              )

      true ->
        :ok
    end
  end

  defp reject_version_id!(conn, bucket, key) do
    if Map.has_key?(conn.query_params, "versionId") do
      raise Error.new(:invalid_argument,
              message: "versionId is not supported for SelectObjectContent",
              resource: "/#{bucket}/#{key}"
            )
    end

    :ok
  end

  defp parse_request!(body) do
    case SelectParser.parse(body) do
      {:ok, request} -> request
      {:error, :malformed_xml} -> raise Error.new(:malformed_xml)
    end
  end

  defp send_select_error(conn, %Error{} = err) do
    request_id = conn |> get_req_header("x-request-id") |> List.first()
    err = %{err | request_id: request_id}
    {status, body} = ErrorView.render(err)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, body)
  end

  defp stream_event_messages(conn, stream, request_progress?) do
    stats = %{
      bytes_scanned: stream.bytes_scanned,
      bytes_processed: stream.bytes_processed,
      bytes_returned: stream.bytes_returned
    }

    conn =
      stream.path
      |> File.stream!(@event_chunk_size, [:read, :binary])
      |> Enum.reduce_while(conn, fn data, acc ->
        case chunk(acc, EventStream.records(data)) do
          {:ok, acc2} -> {:cont, acc2}
          {:error, :closed} -> {:halt, acc}
        end
      end)

    conn =
      if request_progress? do
        safe_chunk(conn, EventStream.progress(stats))
      else
        conn
      end

    conn
    |> safe_chunk(EventStream.stats(stats))
    |> safe_chunk(EventStream.end_event())
  end

  defp safe_chunk(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} -> conn
      {:error, :closed} -> conn
    end
  end

  defp read_small_body!(conn) do
    ControlBody.read_and_verify!(conn, @xml_limit, "SelectObjectContent request body too large",
      too_large_error: :entity_too_large
    )
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp validate_object_key!(bucket, key) do
    case Maxio.Cluster.Paths.validate_key(key) do
      :ok ->
        :ok

      {:error, :invalid_key} ->
        raise Error.new(:invalid_object_name, resource: "/#{bucket}/#{key}")

      {:error, :key_too_long} ->
        raise Error.new(:key_too_long, resource: "/#{bucket}/#{key}")
    end
  end

  defp validate_version_id!(_bucket, _key, nil), do: :ok

  defp validate_version_id!(bucket, key, version_id) do
    if Maxio.Versioning.VersionId.valid?(version_id) do
      :ok
    else
      raise Error.new(:invalid_argument,
              message: "Invalid version id specified",
              resource: "/#{bucket}/#{key}"
            )
    end
  end

  defp resolve_object_for_select!(bucket, key, version_id) do
    case ObjectMeta.get(bucket, key, version_id, []) do
      %Objects.Object{} = object ->
        {object, object.size}

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      {:error, :read_quorum} ->
        Log.warn("select object unavailable: sidecar read_quorum unmet",
          action: :select_object_content,
          bucket: bucket,
          key: key,
          reason: :read_quorum
        )

        raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")
    end
  end

  defp metrics_object_tags(%{tags: tags}) when is_map(tags), do: tags
  defp metrics_object_tags(_object), do: %{}

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp resource(%Plug.Conn{assigns: %{s3_bucket: bucket, s3_key: key}}), do: "/#{bucket}/#{key}"

  defp http_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
end
