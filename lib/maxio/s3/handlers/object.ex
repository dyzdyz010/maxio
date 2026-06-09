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

    # 版本字节路径对齐：先按桶 versioning 算 version_id（Enabled→新 ULID，否则 "null"），
    # 字节流式写入该 version_id 路径；落库用同一 version_id（铁律 4：不缓冲重写）。
    versioning = bucket_versioning(bucket)

    version_id =
      if versioning == "Enabled", do: Maxio.Versioning.VersionId.generate(), else: "null"

    # x-amz-tagging 头（PutObject）→ jsonb tag map（校验失败 → InvalidTag 400，铁律 3）。
    tags_map = parse_tagging_header!(conn)

    # SSE-S3：请求头或桶默认加密 = AES256 → 真实加密字节；非 AES256/SSE-C → 501（绝不静默）。
    sse_requested = resolve_sse!(conn, bucket)

    {chunks, sse_envelope} =
      case sse_requested do
        "AES256" -> Maxio.Crypto.SSE.wrap_stream(chunks)
        nil -> {chunks, nil}
      end

    case Storage.put(bucket, key, version_id, chunks) do
      {:ok, %{size: size, etag: etag, sha256: sha256}} ->
        # 校验/落库失败 → 先清理已写字节再抛（绝不留孤儿，铁律 3）。
        # SSE 加密对象：x-amz-decoded-content-length / x-amz-content-sha256 是针对明文传输完整性的闸，
        # 而落盘字节是密文（密文≠明文必失配）；传输层完整性已由 SigV4/chunked 在 BodyReader 内验过，
        # 故加密分支跳过这两个校验（铁律 3 仍由 GCM 认证 + 上游签名保证）。
        {:ok, obj} =
          try do
            unless sse_requested do
              :ok = verify_decoded_length!(conn, payload_mode, size)
              :ok = verify_content_sha256!(conn, payload_mode, sha256)
            end

            Objects.put_version_with_id(bucket, key, version_id, %{
              size: size,
              etag: etag,
              content_type: content_type,
              storage_class: "STANDARD",
              acl_canned: header(conn, "x-amz-acl") || "private",
              tags: tags_map,
              sse_algorithm: sse_requested,
              sse_envelope: sse_envelope
            })
          rescue
            err ->
              _ = Storage.delete(bucket, key, version_id)

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
        |> maybe_put_version_id(obj.version_id)
        |> maybe_put_sse(sse_requested)
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
    conn = fetch_query_params(conn)
    _ = ensure_bucket!(bucket)

    version_id = Map.get(conn.query_params, "versionId")
    {object, total} = resolve_object_for_get!(bucket, key, version_id)

    cond do
      object.is_delete_marker and version_id == nil ->
        # current 是 delete marker，简单 GET → 404 + x-amz-delete-marker
        conn
        |> put_resp_header("x-amz-delete-marker", "true")
        |> maybe_put_version_id(object.version_id)
        |> send_resp(404, "")

      object.is_delete_marker ->
        # ?versionId 指向 delete marker → 405 + headers
        conn
        |> put_resp_header("x-amz-delete-marker", "true")
        |> put_resp_header("last-modified", http_date(object.updated_at))
        |> maybe_put_version_id(object.version_id)
        |> send_resp(405, "")

      true ->
        # 条件头（If-*）按 RFC 7232 §6 次序求值。304/412 不应有 body（304 尤其禁止），
        # 故 GET 的 304 直接 send_resp(304, "")，412 raise PreconditionFailed（带 XML body，符合 S3）。
        case Conditional.evaluate(conn.req_headers, meta(object), "GET") do
          :proceed ->
            range = parse_range(header(conn, "range"), total)

            case range do
              :invalid ->
                raise Error.new(:invalid_range,
                        resource: "/#{bucket}/#{key}",
                        extra: %{total: total}
                      )

              _ when object.sse_algorithm == "AES256" ->
                # SSE-S3 加密对象：整对象解密返回明文（密文是帧化的，对密文做 byte-range 会取错字节，
                # 故 MVP 对加密对象忽略 Range，整对象解密 + 200，content-length 用解密后明文长度）。
                # 大对象逐帧流式解密留 defer（密文与明文同量级，正确性优先）。
                {:ok, raw_stream} = Storage.get(bucket, key, object.version_id, nil)

                plain =
                  Maxio.Crypto.SSE.unwrap_stream(raw_stream, object.sse_envelope)
                  |> Enum.to_list()
                  |> IO.iodata_to_binary()

                conn
                |> maybe_put_version_id(object.version_id)
                |> maybe_put_sse(object.sse_algorithm)
                |> put_resp_content_type(object.content_type)
                |> put_resp_header("etag", XML.quote_etag(object.etag))
                |> put_resp_header("last-modified", http_date(object.updated_at))
                |> put_resp_header("accept-ranges", "bytes")
                |> put_resp_header("content-length", Integer.to_string(byte_size(plain)))
                |> maybe_tagging_count(object)
                |> send_resp(200, plain)

              _ ->
                {:ok, stream} = Storage.get(bucket, key, object.version_id, range_tuple(range))
                conn = maybe_put_version_id(conn, object.version_id)
                send_object(conn, object, total, range, stream)
            end

          {:respond, 304} ->
            send_resp(conn, 304, "")

          {:error, :precondition_failed} ->
            raise Error.new(:precondition_failed, resource: "/#{bucket}/#{key}")
        end
    end
  end

  @spec head(Plug.Conn.t()) :: Plug.Conn.t()
  def head(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    version_id = Map.get(conn.query_params, "versionId")

    with {:ok, _b} <- Buckets.lookup(bucket),
         {:ok, object} <- fetch_for_head(bucket, key, version_id) do
      cond do
        object.is_delete_marker and version_id == nil ->
          conn
          |> put_resp_header("x-amz-delete-marker", "true")
          |> maybe_put_version_id(object.version_id)
          |> send_resp(404, "")

        object.is_delete_marker ->
          conn
          |> put_resp_header("x-amz-delete-marker", "true")
          |> put_resp_header("last-modified", http_date(object.updated_at))
          |> maybe_put_version_id(object.version_id)
          |> send_resp(405, "")

        true ->
          # HEAD 条件头：304/412 都无 body（HEAD 禁止 body），直接 send_resp。
          case Conditional.evaluate(conn.req_headers, meta(object), "HEAD") do
            :proceed ->
              conn
              |> maybe_put_version_id(object.version_id)
              |> maybe_put_sse(object.sse_algorithm)
              |> put_common_object_headers(object, object.size)
              |> send_resp(200, "")

            {:respond, 304} ->
              send_resp(conn, 304, "")

            {:error, :precondition_failed} ->
              send_resp(conn, 412, "")
          end
      end
    else
      {:error, :not_found} ->
        # HEAD 无 body：缺失桶/对象只回状态 + 头，绝不发 XML body（与 head_bucket 一致）。
        Log.info("head object miss", action: :head_object, bucket: bucket, key: key)
        send_resp(conn, 404, "")
    end
  end

  defp fetch_for_head(bucket, key, nil), do: Objects.get_metadata(bucket, key)
  defp fetch_for_head(bucket, key, version_id), do: Objects.get_version(bucket, key, version_id)

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    _ = ensure_bucket!(bucket)

    version_id = Map.get(conn.query_params, "versionId")
    versioning = bucket_versioning(bucket)

    cond do
      version_id != nil ->
        # 永久删除指定版本（含 delete marker）。
        case Objects.delete_version(bucket, key, version_id) do
          {:ok, %{was_delete_marker: dm?}} ->
            _ = Storage.delete(bucket, key, version_id)
            Log.info("delete object version", action: :delete_object, bucket: bucket, key: key)

            conn
            |> put_resp_header("x-amz-version-id", version_id)
            |> then(fn c ->
              if dm?, do: put_resp_header(c, "x-amz-delete-marker", "true"), else: c
            end)
            |> send_resp(204, "")

          {:error, :not_found} ->
            # 幂等：删不存在的版本也回 204（对齐 AWS）。
            conn |> put_resp_header("x-amz-version-id", version_id) |> send_resp(204, "")
        end

      versioning in ["Enabled", "Suspended"] ->
        # 插入 delete marker（Enabled 新 ULID；Suspended null）。
        {:ok, %{version_id: dm_vid}} = Objects.insert_delete_marker(bucket, key, versioning)
        Log.info("delete object marker", action: :delete_object, bucket: bucket, key: key)

        conn
        |> maybe_put_version_id(dm_vid)
        |> put_resp_header("x-amz-delete-marker", "true")
        |> send_resp(204, "")

      true ->
        # Unversioned：真删（删 null 行 + 字节）。
        :ok = Objects.delete_metadata(bucket, key)
        _ = Storage.delete(bucket, key)
        Log.info("delete object", action: :delete_object, bucket: bucket, key: key)
        send_resp(conn, 204, "")
    end
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

    versioning = bucket_versioning(bucket)

    {deleted, errors} =
      Enum.reduce(objects, {[], []}, fn obj, {dacc, eacc} ->
        case delete_one(bucket, obj, versioning) do
          {:ok, entry} -> {[entry | dacc], eacc}
          {:error, err} -> {dacc, [err | eacc]}
        end
      end)

    Log.info("delete objects",
      action: :delete_objects,
      bucket: bucket,
      size: length(objects),
      deleted: length(deleted),
      errors: length(errors)
    )

    body =
      DeleteResult.render(%{
        deleted: if(quiet, do: [], else: Enum.reverse(deleted)),
        errors: Enum.reverse(errors)
      })

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  # 单个 <Object> 删除：镜像 Object.delete/1 的 versioning 分支（铁律 2 复用既有正确语义）。
  # 返回 {:ok, deleted_entry_map} | {:error, error_entry_map}。
  # deleted_entry_map 字段：:key 必有；:version_id / :delete_marker / :delete_marker_version_id 可选。
  # S3 DeleteObjects 的失败是 per-key 的（回 <Error>），单 key 出错绝不让整批 500（铁律 3：不静默、
  # 不连坐丢成功项）。故底层 DB/Storage 抛错时降级为该 key 的结构化 <Error> 条目并打日志。
  defp delete_one(bucket, %{key: key, version_id: version_id}, versioning) do
    do_delete_one(bucket, key, version_id, versioning)
  rescue
    err ->
      s3err = as_s3_error(err)

      Log.warn("delete object failed",
        action: :delete_objects,
        bucket: bucket,
        key: key,
        code: s3err.code,
        reason: Exception.message(err)
      )

      {:error, %{key: key, code: s3err.code, message: s3err.message}}
  end

  defp do_delete_one(bucket, key, version_id, versioning) do
    cond do
      version_id != nil ->
        # 永久删指定版本（含 delete marker）。幂等：删不存在的版本也算成功。
        case Objects.delete_version(bucket, key, version_id) do
          {:ok, %{was_delete_marker: dm?}} ->
            _ = Storage.delete(bucket, key, version_id)
            {:ok, %{key: key, version_id: version_id, delete_marker: dm?}}

          {:error, :not_found} ->
            {:ok, %{key: key, version_id: version_id, delete_marker: false}}
        end

      versioning in ["Enabled", "Suspended"] ->
        # 无 VersionId 且版本化桶 → 插 delete marker（绝不硬删历史版本）。
        {:ok, %{version_id: dm_vid}} = Objects.insert_delete_marker(bucket, key, versioning)
        {:ok, %{key: key, delete_marker: true, delete_marker_version_id: dm_vid}}

      true ->
        # 未版本化桶 → 硬删（删 null 行 + 字节）。缺失 key 也算成功（S3 语义）。
        :ok = Objects.delete_metadata(bucket, key)
        _ = Storage.delete(bucket, key)
        {:ok, %{key: key}}
    end
  end

  # 把任意 rescue 到的异常归一为 S3 错误（已是 Error 则原样，否则兜底 InternalError）。
  defp as_s3_error(%Error{} = err), do: err
  defp as_s3_error(err), do: Error.new(:internal_error, message: Exception.message(err))

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

  # 非自拷贝：直接流式读源写目标（均走 null 版本路径——拷贝目标当 null 版本，对齐 put_metadata）。
  defp copy_bytes(false, src_bucket, src_key, dest_bucket, dest_key) do
    {:ok, src_stream} = Storage.get(src_bucket, src_key, "null", nil)

    case Storage.put(dest_bucket, dest_key, "null", src_stream) do
      {:ok, %{size: size, etag: etag}} -> {size, etag}
      {:error, reason} -> raise Error.new(:internal_error, message: inspect(reason))
    end
  end

  # 自拷贝（src==dest）：先写唯一临时 key（避免截断源），再流式搬到 dest，最后删临时。
  defp copy_bytes(true, src_bucket, src_key, dest_bucket, dest_key) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    tmp_key = dest_key <> ".maxio-copytmp-" <> suffix
    {:ok, src_stream} = Storage.get(src_bucket, src_key, "null", nil)

    case Storage.put(dest_bucket, tmp_key, "null", src_stream) do
      {:ok, _tmp} ->
        {:ok, tmp_stream} = Storage.get(dest_bucket, tmp_key, "null", nil)

        result =
          case Storage.put(dest_bucket, dest_key, "null", tmp_stream) do
            {:ok, %{size: size, etag: etag}} -> {size, etag}
            {:error, reason} -> raise Error.new(:internal_error, message: inspect(reason))
          end

        _ = Storage.delete(dest_bucket, tmp_key, "null")
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
    |> maybe_tagging_count(object)
  end

  # GET/HEAD object：tag 数 > 0 才出现 x-amz-tagging-count（对齐 AWS）。
  defp maybe_tagging_count(conn, %{tags: tags}) when is_map(tags) and map_size(tags) > 0 do
    put_resp_header(conn, "x-amz-tagging-count", Integer.to_string(map_size(tags)))
  end

  defp maybe_tagging_count(conn, _object), do: conn

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

  # version_id == nil → 取当前版本（latest）；否则取指定版本行。缺失 → NoSuchKey。
  defp resolve_object_for_get!(bucket, key, nil) do
    case Objects.get_metadata(bucket, key) do
      {:ok, object} -> {object, object.size}
      {:error, :not_found} -> raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  defp resolve_object_for_get!(bucket, key, version_id) do
    case Objects.get_version(bucket, key, version_id) do
      {:ok, object} -> {object, object.size}
      {:error, :not_found} -> raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  # 桶版本化状态（Unversioned|Enabled|Suspended）。
  defp bucket_versioning(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, %{versioning: v}} when is_binary(v) -> v
      _ -> "Unversioned"
    end
  end

  # 仅当版本非 "null" 时回显 x-amz-version-id（Unversioned 桶不带该头，对齐 AWS）。
  defp maybe_put_version_id(conn, "null"), do: conn

  defp maybe_put_version_id(conn, version_id),
    do: put_resp_header(conn, "x-amz-version-id", version_id)

  # 决定 SSE：请求头优先；其次桶默认加密配置。非 AES256/SSE-C → 501（绝不静默，铁律 3）。
  defp resolve_sse!(conn, bucket) do
    sse_c = header(conn, "x-amz-server-side-encryption-customer-algorithm")

    if sse_c not in [nil, ""] do
      raise Error.new(:not_implemented, message: "SSE-C (customer-provided keys) not implemented")
    end

    case header(conn, "x-amz-server-side-encryption") do
      "AES256" ->
        "AES256"

      alg when alg in ["aws:kms", "aws:kms:dsse"] ->
        raise Error.new(:not_implemented,
                message: "Only SSE-S3 (AES256) is supported; #{alg} not implemented"
              )

      nil ->
        bucket_default_sse(bucket)

      "" ->
        bucket_default_sse(bucket)

      _other ->
        raise Error.new(:invalid_argument, message: "Invalid x-amz-server-side-encryption value")
    end
  end

  defp bucket_default_sse(bucket) do
    case Maxio.BucketConfigs.get(bucket, :encryption) do
      {:ok, %{"algorithm" => "AES256"}} -> "AES256"
      _ -> nil
    end
  end

  defp maybe_put_sse(conn, nil), do: conn
  defp maybe_put_sse(conn, alg), do: put_resp_header(conn, "x-amz-server-side-encryption", alg)

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

  # x-amz-tagging 头（PutObject）→ jsonb map；无头/空 → %{}；非法 → InvalidTag 400。
  defp parse_tagging_header!(conn) do
    case header(conn, "x-amz-tagging") do
      nil ->
        %{}

      "" ->
        %{}

      raw ->
        case Maxio.Tags.parse_header(raw) do
          {:ok, list} ->
            case Maxio.Tags.validate(list, :object) do
              :ok -> Maxio.Tags.list_to_map(list)
              {:error, :invalid_tag} -> raise Error.new(:invalid_tag)
            end

          {:error, :invalid_tag} ->
            raise Error.new(:invalid_tag)
        end
    end
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  # HTTP Last-Modified 用 RFC1123 GMT（与列举体 ISO8601 不同）。
  defp http_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
  end
end
