defmodule Maxio.S3.Handlers.Object do
  @moduledoc """
  Object 级 handler：put（流式）/ get（含 Range）/ head / delete。
  对象字节走 Maxio.Storage（FS 流式），元数据走 Maxio.Objects。
  """
  import Plug.Conn
  alias Maxio.{Buckets, Objects, Storage}
  alias Maxio.S3.{BodyReader, Conditional, Error, Log, XML}
  alias Maxio.S3.RequestParsers.Delete, as: DeleteParser
  alias Maxio.S3.Views.DeleteResult

  @complete_xml_limit 1_048_576

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    # x-amz-copy-source 头存在 → 服务端拷贝（CopyObject）；否则普通上传（PutObject）。
    case header(conn, "x-amz-copy-source") do
      nil -> do_put(conn)
      _src -> copy(conn)
    end
  end

  @spec do_put(Plug.Conn.t()) :: Plug.Conn.t()
  def do_put(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)

    content_type = header(conn, "content-type") || "binary/octet-stream"
    payload_mode = conn.assigns.payload_mode
    chunks = BodyReader.stream(conn, payload_mode)

    case Storage.put(bucket, key, chunks) do
      {:ok, %{size: size, etag: etag, sha256: sha256}} ->
        # 校验/落库失败 → 先清理已写字节再抛（绝不留孤儿，铁律 3）。
        try do
          :ok = verify_decoded_length!(conn, payload_mode, size)
          :ok = verify_content_sha256!(conn, payload_mode, sha256)

          {:ok, _obj} =
            Objects.put_metadata(bucket, key, %{
              size: size,
              etag: etag,
              content_type: content_type,
              storage_class: "STANDARD",
              acl_canned: header(conn, "x-amz-acl") || "private"
            })
        rescue
          err ->
            _ = Storage.delete(bucket, key)

            Log.warn("put object rolled back orphan bytes",
              action: :put_object,
              bucket: bucket,
              key: key,
              reason: :incomplete_body
            )

            reraise(err, __STACKTRACE__)
        end

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

    # 条件头（If-*）按 RFC 7232 §6 次序求值。304/412 不应有 body（304 尤其禁止），
    # 故 GET 的 304 直接 send_resp(304, "")，412 raise PreconditionFailed（带 XML body，符合 S3）。
    case Conditional.evaluate(conn.req_headers, meta(object), "GET") do
      :proceed ->
        range = parse_range(header(conn, "range"), total)

        case range do
          :invalid ->
            raise Error.new(:invalid_range, resource: "/#{bucket}/#{key}", extra: %{total: total})

          _ ->
            {:ok, stream} = Storage.get(bucket, key, range_tuple(range))
            send_object(conn, object, total, range, stream)
        end

      {:respond, 304} ->
        send_resp(conn, 304, "")

      {:error, :precondition_failed} ->
        raise Error.new(:precondition_failed, resource: "/#{bucket}/#{key}")
    end
  end

  @spec head(Plug.Conn.t()) :: Plug.Conn.t()
  def head(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key

    with {:ok, _b} <- Buckets.lookup(bucket),
         {:ok, object} <- Objects.get_metadata(bucket, key) do
      # HEAD 条件头：304/412 都无 body（HEAD 禁止 body），直接 send_resp。
      case Conditional.evaluate(conn.req_headers, meta(object), "HEAD") do
        :proceed ->
          conn
          |> put_common_object_headers(object, object.size)
          |> send_resp(200, "")

        {:respond, 304} ->
          send_resp(conn, 304, "")

        {:error, :precondition_failed} ->
          send_resp(conn, 412, "")
      end
    else
      {:error, :not_found} ->
        # HEAD 无 body：缺失桶/对象只回状态 + 头，绝不发 XML body（与 head_bucket 一致）。
        Log.info("head object miss", action: :head_object, bucket: bucket, key: key)
        send_resp(conn, 404, "")
    end
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

  @spec delete_objects(Plug.Conn.t()) :: Plug.Conn.t()
  def delete_objects(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, xml} = read_small_body!(conn)

    %{quiet: quiet, objects: objects} =
      case DeleteParser.parse(xml) do
        {:ok, parsed} -> parsed
        {:error, :malformed_xml} -> raise Error.new(:malformed_xml, resource: "/" <> bucket)
      end

    if length(objects) > 1000 do
      raise Error.new(:malformed_xml, message: "A maximum of 1000 keys may be specified")
    end

    {deleted, errors} =
      Enum.reduce(objects, {[], []}, fn %{key: key}, {dacc, eacc} ->
        # 缺失 key 也算 success（S3 语义）；删元数据 + 字节皆幂等。
        :ok = Objects.delete_metadata(bucket, key)
        _ = Storage.delete(bucket, key)
        {[key | dacc], eacc}
      end)

    Log.info("delete objects", action: :delete_objects, bucket: bucket, size: length(objects))

    body =
      DeleteResult.render(%{
        deleted: if(quiet, do: [], else: Enum.reverse(deleted)),
        errors: Enum.reverse(errors)
      })

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  @spec copy(Plug.Conn.t()) :: Plug.Conn.t()
  def copy(conn) do
    dest_bucket = conn.assigns.s3_bucket
    dest_key = conn.assigns.s3_key
    _ = ensure_bucket!(dest_bucket)

    {src_bucket, src_key} = parse_copy_source!(header(conn, "x-amz-copy-source"))
    {src_obj, _total} = object_or_raise(src_bucket, src_key)

    # 源条件头（对源对象求值；失败 412）。
    case eval_copy_source_conditions(conn, src_obj) do
      :proceed ->
        :ok

      {:error, :precondition_failed} ->
        raise Error.new(:precondition_failed, resource: "/#{src_bucket}/#{src_key}")
    end

    directive = header(conn, "x-amz-metadata-directive") || "COPY"

    # 自拷贝守卫：src==dest 且 COPY 且无元数据变化 → 400 InvalidRequest。
    if src_bucket == dest_bucket and src_key == dest_key and directive == "COPY" do
      raise Error.new(:invalid_request,
        message:
          "This copy request is illegal because it is trying to copy an object to itself " <>
            "without changing the object's metadata, storage class, website redirect location " <>
            "or encryption attributes."
      )
    end

    content_type =
      case directive do
        "REPLACE" -> header(conn, "content-type") || "binary/octet-stream"
        _ -> src_obj.content_type
      end

    # 拷贝字节（铁律 4 不全缓冲）。自拷贝（src==dest，此处必为 REPLACE）必须避免
    # 「截断 dest 早于读 source」的数据丢失：先流式写到唯一临时 key，再流式搬到 dest，最后删临时。
    self_copy? = src_bucket == dest_bucket and src_key == dest_key

    {size, etag} = copy_bytes(self_copy?, src_bucket, src_key, dest_bucket, dest_key)

    {:ok, obj} =
      Objects.put_metadata(dest_bucket, dest_key, %{
        size: size,
        etag: etag,
        content_type: content_type,
        storage_class: "STANDARD"
      })

    Log.info("copy object",
      action: :copy_object,
      bucket: dest_bucket,
      key: dest_key,
      src_bucket: src_bucket,
      src_key: src_key,
      self_copy: self_copy?
    )

    body =
      Maxio.S3.Views.CopyObjectResult.render(%{etag: etag, last_modified: obj.updated_at})

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  # 非自拷贝：直接流式读源写目标。
  defp copy_bytes(false, src_bucket, src_key, dest_bucket, dest_key) do
    {:ok, src_stream} = Storage.get(src_bucket, src_key, nil)

    case Storage.put(dest_bucket, dest_key, src_stream) do
      {:ok, %{size: size, etag: etag}} -> {size, etag}
      {:error, reason} -> raise Error.new(:internal_error, message: inspect(reason))
    end
  end

  # 自拷贝（src==dest）：先写唯一临时 key（避免截断源），再流式搬到 dest，最后删临时。
  defp copy_bytes(true, src_bucket, src_key, dest_bucket, dest_key) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    tmp_key = dest_key <> ".maxio-copytmp-" <> suffix
    {:ok, src_stream} = Storage.get(src_bucket, src_key, nil)

    case Storage.put(dest_bucket, tmp_key, src_stream) do
      {:ok, _tmp} ->
        {:ok, tmp_stream} = Storage.get(dest_bucket, tmp_key, nil)

        result =
          case Storage.put(dest_bucket, dest_key, tmp_stream) do
            {:ok, %{size: size, etag: etag}} -> {size, etag}
            {:error, reason} -> raise Error.new(:internal_error, message: inspect(reason))
          end

        _ = Storage.delete(dest_bucket, tmp_key)
        result

      {:error, reason} ->
        raise Error.new(:internal_error, message: inspect(reason))
    end
  end

  # ── helpers ──

  # 条件头求值用的对象元信息（etag 无引号 hex；last_modified 用 updated_at）。
  defp meta(object), do: %{etag: object.etag, last_modified: object.updated_at}

  # x-amz-copy-source 解析："/srcBucket/srcKey" | "srcBucket/srcKey"（URL 编码；忽略 ?versionId=）。
  defp parse_copy_source!(raw) do
    decoded = URI.decode(raw)
    trimmed = String.replace_prefix(decoded, "/", "")
    # 去掉 ?versionId=...（M2 无 versioning）。
    [path | _] = String.split(trimmed, "?", parts: 2)

    case String.split(path, "/", parts: 2) do
      [bucket, key] when key != "" -> {bucket, key}
      _ -> raise Error.new(:invalid_argument, message: "Invalid x-amz-copy-source")
    end
  end

  # 源条件头（x-amz-copy-source-if-*）→ 复用 Conditional，先映射成标准头名再对源对象求值。
  # 用 method="COPY"（非 GET/HEAD）：If-None-Match 命中 → 412（状态变更语义，非 304）。
  defp eval_copy_source_conditions(conn, src_obj) do
    mapped =
      conn.req_headers
      |> Enum.flat_map(fn {k, v} ->
        case String.downcase(k) do
          "x-amz-copy-source-if-match" -> [{"if-match", v}]
          "x-amz-copy-source-if-none-match" -> [{"if-none-match", v}]
          "x-amz-copy-source-if-modified-since" -> [{"if-modified-since", v}]
          "x-amz-copy-source-if-unmodified-since" -> [{"if-unmodified-since", v}]
          _ -> []
        end
      end)

    case Conditional.evaluate(
           mapped,
           %{etag: src_obj.etag, last_modified: src_obj.updated_at},
           "COPY"
         ) do
      :proceed -> :proceed
      {:respond, 304} -> {:error, :precondition_failed}
      {:error, :precondition_failed} -> {:error, :precondition_failed}
    end
  end

  # DeleteObjects 的小 XML 整读（带上限，铁律 4）。read_body 会推进 conn，
  # 返回后用推进过的 conn 发响应。
  defp read_small_body!(conn) do
    case read_body(conn, length: @complete_xml_limit, read_length: @complete_xml_limit) do
      {:ok, body, conn} ->
        {conn, body}

      {:more, _partial, _conn} ->
        raise Error.new(:entity_too_large, message: "Delete request body too large")

      {:error, _} ->
        raise Error.new(:malformed_xml)
    end
  end

  # nil（无 Range）与 :full（多区间 → 对齐 S3 返回完整 200）走同一完整 200 分支。
  defp send_object(conn, object, total, range, stream) when range in [nil, :full] do
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

  # Range: bytes=a-b | bytes=a- | bytes=-suffix → {first,last} | nil | :full | :invalid
  # 多区间（含逗号）对齐 S3 返回完整 200（不实现 multipart/byteranges）→ :full。
  defp parse_range(nil, _total), do: nil

  defp parse_range("bytes=" <> spec, total) do
    if String.contains?(spec, ",") do
      :full
    else
      parse_single_range(spec, total)
    end
  end

  defp parse_range(_other, _total), do: :invalid

  defp parse_single_range(spec, total) do
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

  defp range_tuple(nil), do: nil
  defp range_tuple(:full), do: nil
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

  # :single 模式：声明的 x-amz-content-sha256 必须等于实际字节 SHA256（铁律 3/5）。
  # UNSIGNED-PAYLOAD / STREAMING-* 不在此校验（前者声明 unsigned，后者由 StreamingVerifier 验）。
  defp verify_content_sha256!(conn, :single, actual_sha256) do
    case header(conn, "x-amz-content-sha256") do
      nil ->
        :ok

      declared ->
        cond do
          declared in ["UNSIGNED-PAYLOAD", ""] ->
            :ok

          String.downcase(declared) == actual_sha256 ->
            :ok

          true ->
            Log.warn("content sha256 mismatch", reason: :bad_digest)

            raise Error.new(:x_amz_content_sha256_mismatch,
              message: "declared #{declared} != computed #{actual_sha256}"
            )
        end
    end
  end

  defp verify_content_sha256!(_conn, _mode, _sha256), do: :ok

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  # HTTP Last-Modified 用 RFC1123 GMT（与列举体 ISO8601 不同）。
  defp http_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
  end
end
