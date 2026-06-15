defmodule Maxio.S3.Handlers.Multipart do
  @moduledoc """
  Multipart 级 handler：Create/UploadPart/Complete/Abort/ListParts/ListMultipartUploads。
  会话/分块元数据走 Maxio.Multipart，分块字节走 Maxio.Storage（FS parts）。
  对象 body 绝不整读（UploadPart 流式）；只有 CompleteMultipartUpload 的小 XML 走带上限整读 + SAX。
  """
  import Plug.Conn
  alias Maxio.{Buckets, Multipart, Objects, Storage}
  alias Maxio.Cluster.Placement
  alias Maxio.Policy.ACL

  alias Maxio.S3.{
    BodyReader,
    Checksum,
    CopySource,
    Error,
    Log,
    OwnershipControls,
    PublicAccessBlock,
    SSE,
    StorageClass,
    SystemHeaders,
    XML
  }

  alias Maxio.S3.RequestParsers.CompleteMultipartUpload, as: CompleteParser

  alias Maxio.S3.Views.{
    InitiateMultipartUpload,
    CopyPartResult,
    CompleteMultipartUpload,
    ListParts,
    ListMultipartUploads
  }

  @owner_id "maxio"
  @owner_display "maxio"
  @complete_xml_limit 1_048_576
  @min_part_copy_range_source_size 5_242_880

  @spec create_multipart_upload(Plug.Conn.t()) :: Plug.Conn.t()
  def create_multipart_upload(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)

    # multipart 门与单 key 写路径共用同一入口守卫——空 key / ./.. 点段 key 在
    # CreateMultipartUpload 即 400 XMinioInvalidObjectName（对齐 MinIO：对象名校验同样作用于
    # CreateMultipartUpload，ErrInvalidObjectName）。失败 pre-initiate：零会话、零 part 字节、
    # 无孤儿（铁律 3）。布局保留名段（meta.json 等）是 MinIO/AWS 均接受的普通 key——不拒，
    # 盘上碰撞由 Paths.encode_key 段编码消除。单一事实来源 = Paths.validate_key/1（铁律 2）。
    :ok = validate_object_key!(bucket, key)

    content_type = header(conn, "content-type") || "binary/octet-stream"
    system_headers = SystemHeaders.from_req_headers(conn.req_headers)
    storage_class = StorageClass.parse!(header(conn, "x-amz-storage-class"))
    acl_input = acl_from_headers!(conn)
    :ok = OwnershipControls.reject_object_acl_headers!(bucket, conn, acl_input)
    :ok = PublicAccessBlock.reject_public_acl_write!(bucket, acl_input)
    sse_algorithm = SSE.resolve_target!(conn.req_headers, bucket)
    owner = conn.assigns.principal.arn

    # ROUTE B B4-6 fidelity：CreateMultipartUpload 须捕获客户端 x-amz-meta-*（与 PutObject 同源解析器），
    # 落进会话 metadata，使 CompleteMultipartUpload 后的最终对象 HEAD/GET 回显这些用户元数据
    # （对齐 AWS/MinIO：CreateMultipartUpload Request Syntax 显式列出 x-amz-meta-<key>）。
    # 写会话之前先做 2 KB 大小闸（与 PutObject 同阈值/同语义）——超限 → 400 MetadataTooLarge、
    # 失败 pre-create、无孤儿会话（铁律 3）。
    user_metadata = Maxio.Metadata.parse_headers(conn.req_headers)
    :ok = Maxio.Metadata.validate_size!(user_metadata)

    attrs =
      %{
        content_type: content_type,
        storage_class: storage_class,
        acl_canned: acl_input.canned,
        acl_grants: acl_input.grants_doc,
        sse_algorithm: sse_algorithm,
        owner: owner,
        metadata: user_metadata
      }
      |> Map.merge(system_headers)

    case Multipart.initiate(bucket, key, attrs) do
      {:ok, upload} ->
        Log.info("create multipart upload",
          action: :create_multipart_upload,
          bucket: bucket,
          key: key
        )

        body =
          InitiateMultipartUpload.render(%{
            bucket: bucket,
            key: key,
            upload_id: upload.upload_id
          })

        conn
        |> put_resp_content_type("application/xml")
        |> SSE.put_response_header(sse_algorithm)
        |> send_resp(200, body)

      {:error, reason} ->
        Log.error("create multipart upload failed",
          action: :create_multipart_upload,
          bucket: bucket,
          key: key,
          reason: inspect(reason)
        )

        raise initiate_error(reason, bucket, key)
    end
  end

  @spec upload_part(Plug.Conn.t()) :: Plug.Conn.t()
  def upload_part(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    upload_id = Map.fetch!(conn.query_params, "uploadId")
    part_number = parse_part_number!(Map.fetch!(conn.query_params, "partNumber"))

    upload = upload_or_raise(bucket, key, upload_id)

    case header(conn, "x-amz-copy-source") do
      nil -> upload_part_body(conn, bucket, key, upload_id, part_number, upload)
      raw -> upload_part_copy(conn, bucket, key, upload_id, part_number, upload, raw)
    end
  end

  defp upload_part_body(conn, bucket, key, upload_id, part_number, upload) do
    checksum = Checksum.from_conn!(conn)

    {body_stream, get_trailers, discard_trailers} =
      BodyReader.stream_with_trailers(conn, conn.assigns.payload_mode)

    checksum = Checksum.with_trailer_getter(checksum, get_trailers)

    {chunks, get_checksum, discard_checksum} =
      body_stream |> Checksum.wrap_stream(checksum)

    opts =
      upload
      |> Placement.upload_storage_opts()
      |> Keyword.put(:before_part_commit, fn _part ->
        checksum = get_checksum.()
        :ok = checksum.verify!.()
        %{checksum: checksum}
      end)

    put_result =
      try do
        Storage.put_part(bucket, key, upload_id, part_number, chunks, opts)
      rescue
        err ->
          discard_upload_part_body_state(discard_checksum, discard_trailers)
          reraise(err, __STACKTRACE__)
      catch
        kind, reason ->
          discard_upload_part_body_state(discard_checksum, discard_trailers)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case put_result do
      {:ok, %{size: size, etag: etag} = part_result} ->
        {:ok, _} = Multipart.put_part(upload, part_number, %{etag: etag, size: size})
        checksum = Map.get(part_result, :checksum, checksum)

        Log.info("upload part",
          action: :upload_part,
          bucket: bucket,
          key: key,
          size: size
        )

        conn
        |> Checksum.put_response_headers(checksum)
        |> put_resp_header("etag", XML.quote_etag(etag))
        |> send_resp(200, "")

      {:error, :invalid_key} ->
        discard_upload_part_body_state(discard_checksum, discard_trailers)

        # B5-3 R4 backstop：入口守卫部署前遗留的在途会话（点段 key）打到后端路径层
        # （FS object_path）结构化拒绝 → 400 XMinioInvalidObjectName，绝不塌缩 500（铁律 3）。
        # 新会话已被 create_multipart_upload 入口守卫拦截，此分支仅兜历史在途上传。
        raise Error.new(:invalid_object_name, resource: "/#{bucket}/#{key}")

      {:error, reason} when reason in [:write_quorum, :rename_busy] ->
        discard_upload_part_body_state(discard_checksum, discard_trailers)
        raise Error.new(:slow_down_write, resource: "/#{bucket}/#{key}")

      {:error, reason} ->
        discard_upload_part_body_state(discard_checksum, discard_trailers)
        raise upload_part_error(reason, bucket, key)
    end
  end

  defp upload_part_copy(conn, bucket, key, upload_id, part_number, upload, copy_source_header) do
    :ok = Checksum.reject_upload_part_headers!(conn)

    source = CopySource.parse!(copy_source_header)
    :ok = validate_object_key!(source.bucket, source.key)
    :ok = CopySource.validate_version_id!(source)
    SSE.reject_copy_source_customer_headers!(conn.req_headers)

    src_obj = copy_source_or_raise(source)
    reject_copy_source_marker!(source, src_obj)

    case CopySource.conditional_result(conn, src_obj) do
      :proceed ->
        :ok

      {:error, :precondition_failed} ->
        raise Error.new(:precondition_failed, resource: "/#{source.bucket}/#{source.key}")
    end

    range = CopySource.parse_range!(header(conn, "x-amz-copy-source-range"), src_obj.size)
    reject_small_range_copy!(range, source, src_obj)
    chunks = copy_part_source_stream!(source, src_obj, range)

    case Storage.put_part(
           bucket,
           key,
           upload_id,
           part_number,
           chunks,
           Placement.upload_storage_opts(upload)
         ) do
      {:ok, %{size: size, etag: etag}} ->
        {:ok, part} = Multipart.put_part(upload, part_number, %{etag: etag, size: size})

        Log.info("upload part copy",
          action: :upload_part_copy,
          bucket: bucket,
          key: key,
          src_bucket: source.bucket,
          src_key: source.key,
          size: size
        )

        body =
          CopyPartResult.render(%{
            etag: etag,
            last_modified: part.updated_at
          })

        conn
        |> put_resp_content_type("application/xml")
        |> maybe_put_copy_source_version_id(src_obj.version_id)
        |> SSE.put_response_header(upload.sse_algorithm)
        |> send_resp(200, body)

      {:error, :invalid_key} ->
        raise Error.new(:invalid_object_name, resource: "/#{bucket}/#{key}")

      {:error, reason} when reason in [:write_quorum, :rename_busy] ->
        raise Error.new(:slow_down_write, resource: "/#{bucket}/#{key}")

      {:error, reason} ->
        raise upload_part_error(reason, bucket, key)
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

    # B1-1：提交 seam（assemble 字节 via Multipart.complete + Objects.put_version_with_id 元数据）
    # 纳入同一对象锁，避免与并发同 key PUT/Complete 交错（获锁失败 -> 503 RequestTimeout，铁律 3）。
    # 后端 assemble 不再自持锁（锁责任收敛到 handler 单点，避免 :global.trans 非重入死等）。
    commit_result =
      Maxio.Lock.with_object_lock({bucket, key}, fn ->
        bucket_record = ensure_bucket!(bucket)
        version_id = complete_version_id(bucket_record)

        case Multipart.complete(upload, requested, version_id: version_id) do
          {:ok,
           %{etag: etag, size: size, sse_envelope: sse_envelope, version_id: version_id} =
               complete_result} ->
            # ROUTE B B5-1：元数据提交按写权威分流（与 object.ex commit_metadata 同模式）。
            :ok =
              commit_complete_metadata(
                bucket,
                key,
                version_id,
                %{
                  size: size,
                  etag: etag,
                  content_type: upload.content_type,
                  content_encoding: upload.content_encoding,
                  content_disposition: upload.content_disposition,
                  cache_control: upload.cache_control,
                  expires: upload.expires,
                  storage_class: upload.storage_class,
                  acl_canned: upload.acl_canned,
                  acl_grants: upload.acl_grants || ACL.empty_grants_doc(),
                  sse_algorithm: upload.sse_algorithm,
                  sse_envelope: sse_envelope,
                  # ROUTE B B4-6 fidelity：会话捕获的 user_metadata 也写入 PG 索引行，
                  # 消除已完成多段对象在 :pg(默认) 读路径下 metadata=%{} 的 D3-style 分裂——
                  # 与 sidecar 透传（assemble_object_meta.user_metadata）保持两路一致。
                  metadata: upload.metadata || %{}
                }
                |> Map.merge(Placement.attrs_from_result(complete_result))
              )

            _ = Multipart.abort(upload)
            {:ok, {etag, size, upload.sse_algorithm, version_id}}

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case commit_result do
      {:ok, {:ok, {etag, size, sse_algorithm, version_id}}} ->
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
        |> SSE.put_response_header(sse_algorithm)
        |> maybe_put_version_id(version_id)
        |> send_resp(200, body)

      {:ok, {:error, reason}} ->
        raise complete_error(reason, bucket, key)

      {:error, :locked} ->
        raise Error.new(:request_timeout, resource: "/#{bucket}/#{key}")
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

  # ROUTE B B5-1 —— CompleteMultipartUpload 元数据提交按写权威分流
  # （镜像 object.ex 的 commit_metadata/5，铁律 2 同一分流模式）：
  #
  #   :pg（默认）→ 维持既有致命语义：put_version_with_id 失败则 {:ok,_} 模式匹配失败上抛
  #     （PG 即权威，绝不静默接受落库失败，铁律 3）——字节级不变。
  #
  #   :sidecar → 盘上 assemble 已写出权威 maxio/2 sidecar（达 write_quorum = 最终对象已耐久落盘）；
  #     PG 仅派生索引，用 put_version_index best-effort：失败 → Log.error（绝不静默）+ 不失败请求
  #     （索引滞后由 B5-2 scanner reconcile）。响应（etag/size）来自 Multipart.complete，
  #     本就不依赖 PG 读回，无需内存视图。
  defp commit_complete_metadata(bucket, key, version_id, attrs) do
    case Maxio.ObjectMeta.authoritative_source(:write) do
      :sidecar ->
        case Objects.put_version_index(bucket, key, version_id, attrs) do
          :ok ->
            :ok

          {:error, reason} ->
            Log.error("pg index update failed (object durably stored in sidecars)",
              action: :complete_multipart_upload,
              bucket: bucket,
              key: key,
              reason: inspect(reason)
            )

            :ok
        end

      _pg ->
        {:ok, _obj} = Objects.put_version_with_id(bucket, key, version_id, attrs)
        :ok
    end
  end

  defp complete_version_id(%{versioning: "Enabled"}),
    do: Maxio.Versioning.VersionId.generate()

  defp complete_version_id(_bucket), do: "null"

  defp maybe_put_version_id(conn, "null"), do: conn

  defp maybe_put_version_id(conn, version_id),
    do: put_resp_header(conn, "x-amz-version-id", version_id)

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  # B5-3 R3/R4 —— 对象 key 入口守卫（与 Handlers.Object.validate_object_key!/2 同构）：
  # 单一事实来源 = Maxio.Cluster.Paths.validate_key/1（与盘上路径构造同源），
  # handler 仅做错误映射——点段/空 key → 400 XMinioInvalidObjectName；超 1024 字节
  # → 400 KeyTooLongError（B5-4，与 PUT 同门，保证「可建即可达」）（铁律 2）。
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

  defp discard_upload_part_body_state(discard_checksum, discard_trailers) do
    discard_checksum.()
    discard_trailers.()
  end

  defp upload_or_raise(bucket, key, upload_id) do
    _ = ensure_bucket!(bucket)

    case Multipart.get_upload(bucket, key, upload_id) do
      {:ok, upload} -> upload
      {:error, :not_found} -> raise Error.new(:no_such_upload, resource: "/#{bucket}/#{key}")
    end
  end

  defp copy_source_or_raise(%{bucket: bucket, key: key, version_id: version_id}) do
    _ = ensure_bucket!(bucket)

    case Maxio.ObjectMeta.get(bucket, key, version_id, []) do
      %Objects.Object{} = object ->
        object

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      {:error, :read_quorum} ->
        Log.warn("upload part copy source unavailable: sidecar read_quorum unmet",
          action: :upload_part_copy,
          bucket: bucket,
          key: key,
          reason: :read_quorum
        )

        raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")
    end
  end

  defp reject_copy_source_marker!(%{version_id: nil, bucket: bucket, key: key}, %{
         is_delete_marker: true
       }) do
    raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
  end

  defp reject_copy_source_marker!(%{bucket: bucket, key: key}, %{is_delete_marker: true}) do
    raise Error.new(:invalid_argument,
            message: "Cannot copy a delete marker version",
            resource: "/#{bucket}/#{key}"
          )
  end

  defp reject_copy_source_marker!(_source, _src_obj), do: :ok

  defp reject_small_range_copy!(nil, _source, _src_obj), do: :ok

  defp reject_small_range_copy!(_range, %{bucket: bucket, key: key}, %{size: size})
       when size <= @min_part_copy_range_source_size do
    raise Error.new(:invalid_request,
            message:
              "Cannot specify x-amz-copy-source-range for source objects smaller than 5 MB",
            resource: "/#{bucket}/#{key}"
          )
  end

  defp reject_small_range_copy!(_range, _source, _src_obj), do: :ok

  defp copy_part_source_stream!(source, src_obj, range) do
    case src_obj.sse_algorithm do
      nil ->
        {:ok, stream} =
          Storage.get(
            source.bucket,
            source.key,
            src_obj.version_id,
            range,
            Placement.storage_opts(src_obj)
          )

        stream

      "AES256" ->
        {:ok, raw_stream} =
          Storage.get(
            source.bucket,
            source.key,
            src_obj.version_id,
            nil,
            Placement.storage_opts(src_obj)
          )

        raw_stream
        |> Maxio.Crypto.SSE.unwrap_stream(src_obj.sse_envelope)
        |> trim_stream(range)

      alg ->
        raise Error.new(:not_implemented,
                message: "UploadPartCopy for #{alg} source objects not implemented"
              )
    end
  end

  defp trim_stream(stream, nil), do: stream

  defp trim_stream(stream, {first, last}) do
    Stream.transform(stream, {first, last - first + 1}, fn chunk, {skip, remaining} ->
      cond do
        remaining <= 0 ->
          {:halt, {0, 0}}

        true ->
          chunk
          |> IO.iodata_to_binary()
          |> slice_chunk(skip, remaining)
      end
    end)
  end

  defp slice_chunk(chunk, skip, remaining) when skip >= byte_size(chunk),
    do: {[], {skip - byte_size(chunk), remaining}}

  defp slice_chunk(chunk, skip, remaining) when skip > 0 do
    <<_skipped::binary-size(^skip), rest::binary>> = chunk
    emit_slice(rest, remaining)
  end

  defp slice_chunk(chunk, 0, remaining), do: emit_slice(chunk, remaining)

  defp emit_slice(chunk, remaining) do
    emit_size = min(byte_size(chunk), remaining)
    <<emit::binary-size(^emit_size), _tail::binary>> = chunk
    {[emit], {0, remaining - emit_size}}
  end

  defp maybe_put_copy_source_version_id(conn, nil), do: conn
  defp maybe_put_copy_source_version_id(conn, "null"), do: conn

  defp maybe_put_copy_source_version_id(conn, version_id),
    do: put_resp_header(conn, "x-amz-copy-source-version-id", version_id)

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

  # B5-3 R4 backstop：入口守卫部署前遗留在途会话的点段 key 在 assemble（FS object_path）被
  # 结构化拒绝 → 400 XMinioInvalidObjectName（与 object.ex PUT 提交分支同映射），绝不塌缩
  # 500 InternalError（铁律 3）。新会话已被 create_multipart_upload 入口守卫拦截。
  defp complete_error(:invalid_key, b, k),
    do: Error.new(:invalid_object_name, resource: "/#{b}/#{k}")

  # 写 quorum 不足 / 原子 rename 争用 = 瞬时写限流，对齐 MinIO 的 SlowDownWrite(503)，
  # SDK 据此退避重试自愈（与 object.ex PUT 一致）；绝不退化成 500 InternalError。
  defp complete_error(reason, b, k) when reason in [:write_quorum, :rename_busy],
    do: Error.new(:slow_down_write, resource: "/#{b}/#{k}")

  defp complete_error(reason, b, k) do
    if placement_unavailable?(reason) do
      Error.new(:slow_down_write, resource: "/#{b}/#{k}")
    else
      Error.new(:internal_error, resource: "/#{b}/#{k}")
    end
  end

  defp upload_part_error(reason, b, k) do
    cond do
      placement_unavailable?(reason) ->
        Error.new(:slow_down_write, resource: "/#{b}/#{k}")

      placement_internal_error?(reason) ->
        Error.new(:internal_error, resource: "/#{b}/#{k}")

      true ->
        Error.new(:internal_error, message: inspect(reason))
    end
  end

  defp initiate_error({:write_routing_unavailable, _reason}, b, k),
    do: Error.new(:slow_down_write, resource: "/#{b}/#{k}")

  defp initiate_error(reason, b, k) do
    if placement_unavailable?(reason) do
      Error.new(:slow_down_write, resource: "/#{b}/#{k}")
    else
      initiate_known_error(reason, b, k)
    end
  end

  defp initiate_known_error({:unknown_set_id, _set_id, _known}, b, k),
    do: Error.new(:internal_error, resource: "/#{b}/#{k}")

  defp initiate_known_error({:decommission_write_route_cycle, _set_id, _destination}, b, k),
    do: Error.new(:internal_error, resource: "/#{b}/#{k}")

  defp initiate_known_error(
         {:invalid_decommission_write_destination, _set_id, _destination},
         b,
         k
       ),
       do: Error.new(:internal_error, resource: "/#{b}/#{k}")

  defp initiate_known_error(reason, b, k) when reason in [:write_quorum, :rename_busy],
    do: Error.new(:slow_down_write, resource: "/#{b}/#{k}")

  defp initiate_known_error(_reason, b, k), do: Error.new(:internal_error, resource: "/#{b}/#{k}")

  defp placement_unavailable?({:pool_telemetry_incomplete, _candidates}), do: true
  defp placement_unavailable?({:no_eligible_pool, _candidates}), do: true
  defp placement_unavailable?({:drive_stats_crashed, _message}), do: true
  defp placement_unavailable?({:drive_stats_caught, _kind, _reason}), do: true
  defp placement_unavailable?({:invalid_drive_stats, _stats}), do: true
  defp placement_unavailable?({:write_routing_unavailable, _reason}), do: true
  defp placement_unavailable?(:no_topology), do: true
  defp placement_unavailable?(_reason), do: false

  defp placement_internal_error?({:unknown_set_id, _set_id, _known}), do: true
  defp placement_internal_error?({:invalid_decommission_write_route, _route}), do: true
  defp placement_internal_error?({:invalid_decommission_write_routes, _routes}), do: true

  defp placement_internal_error?({:decommission_write_route_cycle, _set_id, _destination}),
    do: true

  defp placement_internal_error?(
         {:invalid_decommission_write_destination, _set_id, _destination}
       ),
       do: true

  defp placement_internal_error?(_reason), do: false

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

  defp acl_from_headers!(conn) do
    grant_headers? = ACL.grant_headers?(conn.req_headers)

    case header(conn, "x-amz-acl") do
      canned when is_binary(canned) and grant_headers? ->
        raise Error.new(:invalid_request,
                message: "Cannot specify both x-amz-acl and x-amz-grant-*"
              )

      nil ->
        if grant_headers? do
          grants =
            conn.req_headers
            |> parse_grant_headers!()
            |> ACL.drop_owner_grants(@owner_id)

          %{canned: ACL.classify_grants(grants), grants_doc: ACL.grants_doc(grants)}
        else
          %{canned: "private", grants_doc: ACL.empty_grants_doc()}
        end

      canned ->
        if ACL.known?(canned) do
          %{canned: canned, grants_doc: ACL.empty_grants_doc()}
        else
          raise Error.new(:invalid_argument, message: "Unsupported x-amz-acl: #{canned}")
        end
    end
  end

  defp parse_grant_headers!(headers) do
    case ACL.parse_grant_headers(headers) do
      {:ok, grants} ->
        grants

      {:error, :unsupported_email} ->
        raise Error.new(:invalid_argument, message: "Email grantee ACLs are not supported")

      {:error, :too_many_grants} ->
        raise Error.new(:invalid_argument, message: "ACL can contain at most 100 grants")

      {:error, :invalid_grant} ->
        raise Error.new(:invalid_argument, message: "Invalid ACL grant")
    end
  end
end
