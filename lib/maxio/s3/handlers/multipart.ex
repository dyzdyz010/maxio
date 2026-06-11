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

    # multipart 门与单 key 写路径共用同一入口守卫——空 key / ./.. 点段 key 在
    # CreateMultipartUpload 即 400 XMinioInvalidObjectName（对齐 MinIO：对象名校验同样作用于
    # CreateMultipartUpload，ErrInvalidObjectName）。失败 pre-initiate：零会话、零 part 字节、
    # 无孤儿（铁律 3）。布局保留名段（meta.json 等）是 MinIO/AWS 均接受的普通 key——不拒，
    # 盘上碰撞由 Paths.encode_key 段编码消除。单一事实来源 = Paths.validate_key/1（铁律 2）。
    :ok = validate_object_key!(bucket, key)

    content_type = header(conn, "content-type") || "binary/octet-stream"
    owner = conn.assigns.principal.arn

    # ROUTE B B4-6 fidelity：CreateMultipartUpload 须捕获客户端 x-amz-meta-*（与 PutObject 同源解析器），
    # 落进会话 metadata，使 CompleteMultipartUpload 后的最终对象 HEAD/GET 回显这些用户元数据
    # （对齐 AWS/MinIO：CreateMultipartUpload Request Syntax 显式列出 x-amz-meta-<key>）。
    # 写会话之前先做 2 KB 大小闸（与 PutObject 同阈值/同语义）——超限 → 400 MetadataTooLarge、
    # 失败 pre-create、无孤儿会话（铁律 3）。
    user_metadata = Maxio.Metadata.parse_headers(conn.req_headers)
    :ok = Maxio.Metadata.validate_size!(user_metadata)

    {:ok, upload} =
      Multipart.initiate(bucket, key, %{
        content_type: content_type,
        owner: owner,
        metadata: user_metadata
      })

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

      {:error, :invalid_key} ->
        # B5-3 R4 backstop：入口守卫部署前遗留的在途会话（点段 key）打到后端路径层
        # （FS object_path）结构化拒绝 → 400 XMinioInvalidObjectName，绝不塌缩 500（铁律 3）。
        # 新会话已被 create_multipart_upload 入口守卫拦截，此分支仅兜历史在途上传。
        raise Error.new(:invalid_object_name, resource: "/#{bucket}/#{key}")

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
            # ROUTE B B5-1：元数据提交按写权威分流（与 object.ex commit_metadata 同模式）。
            :ok =
              commit_complete_metadata(bucket, key, %{
                size: size,
                etag: etag,
                content_type: upload.content_type,
                storage_class: upload.storage_class,
                # ROUTE B B4-6 fidelity：会话捕获的 user_metadata 也写入 PG 索引行，
                # 消除已完成多段对象在 :pg(默认) 读路径下 metadata=%{} 的 D3-style 分裂——
                # 与 sidecar 透传（assemble_object_meta.user_metadata）保持两路一致。
                metadata: upload.metadata || %{}
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

  # ROUTE B B5-1 —— CompleteMultipartUpload 元数据提交按写权威分流
  # （镜像 object.ex 的 commit_metadata/5，铁律 2 同一分流模式）：
  #
  #   :pg（默认）→ 维持既有致命语义：put_metadata 失败则 {:ok,_} 模式匹配失败上抛
  #     （PG 即权威，绝不静默接受落库失败，铁律 3）——字节级不变。
  #
  #   :sidecar → 盘上 assemble 已写出权威 maxio/2 sidecar（达 write_quorum = 最终对象已耐久落盘）；
  #     PG 仅派生索引，用 put_metadata_index best-effort：失败 → Log.error（绝不静默）+ 不失败请求
  #     （索引滞后由 B5-2 scanner reconcile）。响应（etag/size）来自 Multipart.complete，
  #     本就不依赖 PG 读回，无需内存视图。
  defp commit_complete_metadata(bucket, key, attrs) do
    case Maxio.ObjectMeta.authoritative_source(:write) do
      :sidecar ->
        case Objects.put_metadata_index(bucket, key, attrs) do
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
        {:ok, _obj} = Objects.put_metadata(bucket, key, attrs)
        :ok
    end
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  # B5-3 R3/R4 —— 对象 key 入口守卫（与 Handlers.Object.validate_object_key!/2 同构）：
  # 单一事实来源 = Maxio.Cluster.Paths.validate_key/1（与盘上路径构造同源），
  # handler 仅做错误映射 400 XMinioInvalidObjectName（铁律 2）。
  defp validate_object_key!(bucket, key) do
    case Maxio.Cluster.Paths.validate_key(key) do
      :ok ->
        :ok

      {:error, :invalid_key} ->
        raise Error.new(:invalid_object_name, resource: "/#{bucket}/#{key}")
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

  # B5-3 R4 backstop：入口守卫部署前遗留在途会话的点段 key 在 assemble（FS object_path）被
  # 结构化拒绝 → 400 XMinioInvalidObjectName（与 object.ex PUT 提交分支同映射），绝不塌缩
  # 500 InternalError（铁律 3）。新会话已被 create_multipart_upload 入口守卫拦截。
  defp complete_error(:invalid_key, b, k),
    do: Error.new(:invalid_object_name, resource: "/#{b}/#{k}")

  # 写 quorum 不足 / 原子 rename 争用 = 瞬时写限流，对齐 MinIO 的 SlowDownWrite(503)，
  # SDK 据此退避重试自愈（与 object.ex PUT 一致）；绝不退化成 500 InternalError。
  defp complete_error(reason, b, k) when reason in [:write_quorum, :rename_busy],
    do: Error.new(:slow_down_write, resource: "/#{b}/#{k}")

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
