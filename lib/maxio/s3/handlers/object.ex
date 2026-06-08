defmodule Maxio.S3.Handlers.Object do
  @moduledoc """
  Object 级 handler：put（流式）/ get（含 Range）/ head / delete。
  对象字节走 Maxio.Storage（FS 流式），元数据走 Maxio.Objects。
  """
  import Plug.Conn
  alias Maxio.{Buckets, Objects, Storage}
  alias Maxio.S3.{BodyReader, Error, Log, XML}

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)

    content_type = header(conn, "content-type") || "binary/octet-stream"
    payload_mode = conn.assigns.payload_mode
    chunks = BodyReader.stream(conn, payload_mode)

    case Storage.put(bucket, key, chunks) do
      {:ok, %{size: size, etag: etag}} ->
        :ok = verify_decoded_length!(conn, payload_mode, size)

        {:ok, _obj} =
          Objects.put_metadata(bucket, key, %{
            size: size,
            etag: etag,
            content_type: content_type,
            storage_class: "STANDARD"
          })

        Log.info("put object",
          action: :put_object,
          bucket: bucket,
          key: key,
          size: size,
          auth_type: conn.assigns.auth_type
        )

        conn
        |> put_resp_header("etag", XML.quote_etag(etag))
        |> send_resp(200, "")

      {:error, :invalid_key} ->
        raise Error.new(:invalid_argument, resource: "/#{bucket}/#{key}", message: "Invalid key")

      {:error, reason} ->
        raise Error.new(:internal_error, message: inspect(reason))
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key

    {object, total} = object_or_raise(bucket, key)
    range = parse_range(header(conn, "range"), total)

    case range do
      :invalid ->
        raise Error.new(:invalid_range, resource: "/#{bucket}/#{key}", extra: %{total: total})

      _ ->
        {:ok, stream} = Storage.get(bucket, key, range_tuple(range))
        send_object(conn, object, total, range, stream)
    end
  end

  @spec head(Plug.Conn.t()) :: Plug.Conn.t()
  def head(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    {object, total} = object_or_raise(bucket, key)

    conn
    |> put_common_object_headers(object, total)
    |> send_resp(200, "")
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)

    :ok = Objects.delete_metadata(bucket, key)
    _ = Storage.delete(bucket, key)
    Log.info("delete object", action: :delete_object, bucket: bucket, key: key)
    send_resp(conn, 204, "")
  end

  # ── helpers ──
  defp send_object(conn, object, total, nil, stream) do
    conn
    |> put_common_object_headers(object, total)
    |> send_chunked(200)
    |> stream_chunks(stream)
  end

  defp send_object(conn, object, total, {first, last}, stream) do
    conn
    |> put_common_object_headers(object, last - first + 1)
    |> put_resp_header("content-range", "bytes #{first}-#{last}/#{total}")
    |> send_chunked(206)
    |> stream_chunks(stream)
  end

  defp stream_chunks(conn, stream) do
    Enum.reduce_while(stream, conn, fn data, acc ->
      case chunk(acc, data) do
        {:ok, acc2} -> {:cont, acc2}
        {:error, :closed} -> {:halt, acc}
      end
    end)
  end

  defp put_common_object_headers(conn, object, content_length) do
    conn
    |> put_resp_header("content-type", object.content_type)
    |> put_resp_header("etag", XML.quote_etag(object.etag))
    |> put_resp_header("last-modified", http_date(object.updated_at))
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("content-length", Integer.to_string(content_length))
  end

  # Range: bytes=a-b | bytes=a- | bytes=-suffix → {first,last} | nil | :invalid
  defp parse_range(nil, _total), do: nil

  defp parse_range("bytes=" <> spec, total) do
    case String.split(spec, "-") do
      [a, ""] ->
        case Integer.parse(a) do
          {first, ""} when first < total -> {first, total - 1}
          _ -> :invalid
        end

      ["", suffix] ->
        case Integer.parse(suffix) do
          {n, ""} when n > 0 -> {max(total - n, 0), total - 1}
          _ -> :invalid
        end

      [a, b] ->
        with {first, ""} <- Integer.parse(a),
             {last, ""} <- Integer.parse(b),
             true <- first <= last and first < total do
          {first, min(last, total - 1)}
        else
          _ -> :invalid
        end

      _ ->
        :invalid
    end
  end

  defp parse_range(_other, _total), do: :invalid

  defp range_tuple(nil), do: nil
  defp range_tuple({first, last}), do: {first, last}

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp object_or_raise(bucket, key) do
    _ = ensure_bucket!(bucket)

    case Objects.get_metadata(bucket, key) do
      {:ok, object} -> {object, object.size}
      {:error, :not_found} -> raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  # 流式 PUT 解帧后长度须等于声明的 decoded-content-length（aws-chunked 完整性闸，铁律 3）。
  defp verify_decoded_length!(conn, :streaming, actual_size) do
    case header(conn, "x-amz-decoded-content-length") do
      nil ->
        :ok

      str ->
        case Integer.parse(str) do
          {declared, ""} when declared == actual_size ->
            :ok

          {declared, ""} ->
            Log.warn("decoded length mismatch", reason: :incomplete_body)

            raise Error.new(:incomplete_body,
              message: "decoded length #{actual_size} != declared #{declared}"
            )

          _ ->
            :ok
        end
    end
  end

  defp verify_decoded_length!(_conn, _mode, _size), do: :ok

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  # HTTP Last-Modified 用 RFC1123 GMT（与列举体 ISO8601 不同）。
  defp http_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
  end
end
