defmodule Maxio.S3.Handlers.Multipart do
  @moduledoc """
  Multipart 级 handler：Create/UploadPart/Complete/Abort/ListParts/ListMultipartUploads。
  会话/分块元数据走 Maxio.Multipart，分块字节走 Maxio.Storage（FS parts）。
  对象 body 绝不整读（UploadPart 流式）；只有 CompleteMultipartUpload 的小 XML 走带上限整读 + SAX。
  """
  import Plug.Conn
  alias Maxio.{Buckets, Multipart, Objects, Storage}
  alias Maxio.S3.{BodyReader, Error, Log, XML}
  alias Maxio.S3.RequestParsers.CompleteMultipartUpload, as: CompleteParser

  alias Maxio.S3.Views.{
    InitiateMultipartUpload,
    CompleteMultipartUpload,
    ListParts,
    ListMultipartUploads
  }

  @owner_id "maxio"
  @owner_display "maxio"
  @complete_xml_limit 1_048_576

  @spec create_multipart_upload(Plug.Conn.t()) :: Plug.Conn.t()
  def create_multipart_upload(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)

    content_type = header(conn, "content-type") || "binary/octet-stream"
    owner = conn.assigns.principal.arn

    {:ok, upload} =
      Multipart.initiate(bucket, key, %{content_type: content_type, owner: owner})

    Log.info("create multipart upload",
      action: :create_multipart_upload,
      bucket: bucket,
      key: key
    )

    body =
      InitiateMultipartUpload.render(%{bucket: bucket, key: key, upload_id: upload.upload_id})

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  @spec upload_part(Plug.Conn.t()) :: Plug.Conn.t()
  def upload_part(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    upload_id = Map.fetch!(conn.query_params, "uploadId")
    part_number = parse_part_number!(Map.fetch!(conn.query_params, "partNumber"))

    upload = upload_or_raise(bucket, key, upload_id)
    chunks = BodyReader.stream(conn, conn.assigns.payload_mode)

    case Storage.put_part(bucket, key, upload_id, part_number, chunks) do
      {:ok, %{size: size, etag: etag}} ->
        {:ok, _} = Multipart.put_part(upload, part_number, %{etag: etag, size: size})

        Log.info("upload part",
          action: :upload_part,
          bucket: bucket,
          key: key,
          size: size
        )

        conn
        |> put_resp_header("etag", XML.quote_etag(etag))
        |> send_resp(200, "")

      {:error, reason} ->
        raise Error.new(:internal_error, message: inspect(reason))
    end
  end

  @spec complete_multipart_upload(Plug.Conn.t()) :: Plug.Conn.t()
  def complete_multipart_upload(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    upload_id = Map.fetch!(conn.query_params, "uploadId")

    upload = upload_or_raise(bucket, key, upload_id)
    {conn, xml} = read_small_body!(conn)

    requested =
      case CompleteParser.parse(xml) do
        {:ok, parts} -> parts
        {:error, :malformed_xml} -> raise Error.new(:malformed_xml, resource: "/#{bucket}/#{key}")
      end

    # B1-1：提交 seam（assemble 字节 via Multipart.complete + Objects.put_metadata 元数据）
    # 纳入同一对象锁，避免与并发同 key PUT/Complete 交错（获锁失败 -> 503 SlowDown，铁律 3）。
    # 后端 assemble 不再自持锁（锁责任收敛到 handler 单点，避免 :global.trans 非重入死等）。
    commit_result =
      Maxio.Lock.with_object_lock({bucket, key}, fn ->
        case Multipart.complete(upload, requested) do
          {:ok, %{etag: etag, size: size}} ->
            {:ok, _obj} =
              Objects.put_metadata(bucket, key, %{
                size: size,
                etag: etag,
                content_type: upload.content_type,
                storage_class: upload.storage_class
              })

            _ = Multipart.abort(upload)
            {:ok, {etag, size}}

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case commit_result do
      {:ok, {:ok, {etag, size}}} ->
        Log.info("complete multipart upload",
          action: :complete_multipart_upload,
          bucket: bucket,
          key: key,
          size: size
        )

        body =
          CompleteMultipartUpload.render(%{
            location: "/#{bucket}/#{key}",
            bucket: bucket,
            key: key,
            etag: etag
          })

        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, body)

      {:ok, {:error, reason}} ->
        raise complete_error(reason, bucket, key)

      {:error, :locked} ->
        raise Error.new(:slow_down, resource: "/#{bucket}/#{key}")
    end
  end

  @spec abort_multipart_upload(Plug.Conn.t()) :: Plug.Conn.t()
  def abort_multipart_upload(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    upload_id = Map.fetch!(conn.query_params, "uploadId")

    upload = upload_or_raise(bucket, key, upload_id)
    :ok = Multipart.abort(upload)
    Log.info("abort multipart upload", action: :abort_multipart_upload, bucket: bucket, key: key)
    send_resp(conn, 204, "")
  end

  @spec list_parts(Plug.Conn.t()) :: Plug.Conn.t()
  def list_parts(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    upload_id = Map.fetch!(conn.query_params, "uploadId")
    max_parts = parse_int(Map.get(conn.query_params, "max-parts"), 1000)
    marker = parse_int(Map.get(conn.query_params, "part-number-marker"), 0)

    upload = upload_or_raise(bucket, key, upload_id)
    res = Multipart.list_parts(upload, %{max_parts: max_parts, part_number_marker: marker})

    parts =
      Enum.map(res.parts, fn p ->
        %{part_number: p.part_number, last_modified: p.updated_at, etag: p.etag, size: p.size}
      end)

    body =
      ListParts.render(%{
        bucket: bucket,
        key: key,
        upload_id: upload_id,
        part_number_marker: marker,
        next_part_number_marker: res.next_part_number_marker,
        max_parts: max_parts,
        is_truncated: res.is_truncated,
        parts: parts,
        owner_id: @owner_id,
        owner_display: @owner_display,
        storage_class: upload.storage_class
      })

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  @spec list_multipart_uploads(Plug.Conn.t()) :: Plug.Conn.t()
  def list_multipart_uploads(conn) do
    bucket = conn.assigns.s3_bucket
    conn = fetch_query_params(conn)
    qp = conn.query_params
    _ = ensure_bucket!(bucket)

    prefix = Map.get(qp, "prefix", "")
    delimiter = Map.get(qp, "delimiter")
    max_uploads = parse_int(Map.get(qp, "max-uploads"), 1000)
    key_marker = Map.get(qp, "key-marker")

    res =
      Multipart.list_uploads(bucket, %{
        prefix: prefix,
        delimiter: delimiter,
        max_uploads: max_uploads,
        key_marker: key_marker
      })

    uploads =
      Enum.map(res.uploads, fn u ->
        %{
          key: u.key,
          upload_id: u.upload_id,
          storage_class: u.storage_class,
          initiated: u.inserted_at
        }
      end)

    body =
      ListMultipartUploads.render(%{
        bucket: bucket,
        prefix: prefix,
        delimiter: delimiter,
        key_marker: key_marker,
        upload_id_marker: Map.get(qp, "upload-id-marker"),
        next_key_marker: res.next_key_marker,
        next_upload_id_marker: res.next_upload_id_marker,
        max_uploads: max_uploads,
        is_truncated: res.is_truncated,
        uploads: uploads,
        common_prefixes: res.common_prefixes,
        owner_id: @owner_id,
        owner_display: @owner_display
      })

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  # ── helpers ──
  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp upload_or_raise(bucket, key, upload_id) do
    _ = ensure_bucket!(bucket)

    case Multipart.get_upload(bucket, key, upload_id) do
      {:ok, upload} -> upload
      {:error, :not_found} -> raise Error.new(:no_such_upload, resource: "/#{bucket}/#{key}")
    end
  end

  # CompleteMultipartUpload 的小 XML 整读（带上限，铁律 4）。
  defp read_small_body!(conn) do
    case read_body(conn, length: @complete_xml_limit, read_length: @complete_xml_limit) do
      {:ok, body, conn} ->
        {conn, body}

      {:more, _partial, _conn} ->
        raise Error.new(:entity_too_large, message: "Complete request body too large")

      {:error, _} ->
        raise Error.new(:malformed_xml)
    end
  end

  defp complete_error(:no_such_upload, b, k),
    do: Error.new(:no_such_upload, resource: "/#{b}/#{k}")

  defp complete_error(:invalid_part, b, k), do: Error.new(:invalid_part, resource: "/#{b}/#{k}")

  defp complete_error(:invalid_part_order, b, k),
    do: Error.new(:invalid_part_order, resource: "/#{b}/#{k}")

  defp complete_error(:entity_too_small, b, k),
    do: Error.new(:entity_too_small, resource: "/#{b}/#{k}")

  defp complete_error(:no_parts, b, k), do: Error.new(:malformed_xml, resource: "/#{b}/#{k}")
  defp complete_error(_other, b, k), do: Error.new(:internal_error, resource: "/#{b}/#{k}")

  defp parse_part_number!(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 1 and n <= 10_000 -> n
      _ -> raise Error.new(:invalid_argument, message: "partNumber must be 1..10000")
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()
end
