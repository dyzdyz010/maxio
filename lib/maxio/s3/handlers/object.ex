defmodule Maxio.S3.Handlers.Object do
  @moduledoc """
  Object 级 handler：put（流式）/ get（含 Range）/ head / delete。
  对象字节走 Maxio.Storage（FS 流式），元数据走 Maxio.Objects。
  """
  import Plug.Conn
  alias Maxio.{Buckets, Objects, Storage}
  alias Maxio.Cluster.Placement
  alias Maxio.Policy.ACL

  alias Maxio.S3.{
    BodyReader,
    Conditional,
    CopySource,
    Checksum,
    Error,
    Log,
    PublicAccessBlock,
    MFADelete,
    SSE,
    StorageClass,
    SystemHeaders,
    XML
  }

  alias Maxio.S3.RequestParsers.Delete, as: DeleteParser
  alias Maxio.S3.Views.DeleteResult

  @complete_xml_limit 1_048_576
  @owner_id "maxio"

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

    # B5-3 R3/R4：对象 key 入口守卫（保留布局名段/点段 → 400 XMinioInvalidObjectName），
    # 在读 body / 写任何字节之前失败 pre-commit（铁律 3，无孤儿）。
    :ok = validate_object_key!(bucket, key)

    content_type = header(conn, "content-type") || "binary/octet-stream"
    system_headers = SystemHeaders.from_req_headers(conn.req_headers)
    storage_class = StorageClass.parse!(header(conn, "x-amz-storage-class"))
    acl_input = acl_from_headers!(conn)
    :ok = PublicAccessBlock.reject_public_acl_write!(bucket, acl_input)
    payload_mode = conn.assigns.payload_mode
    checksum = Checksum.from_conn!(conn)

    # 版本字节路径对齐：先按桶 versioning 算 version_id（Enabled→新 ULID，否则 "null"），
    # 字节流式写入该 version_id 路径；落库用同一 version_id（铁律 4：不缓冲重写）。
    version_id =
      if bucket_versioning(bucket) == "Enabled",
        do: Maxio.Versioning.VersionId.generate(),
        else: "null"

    user_metadata = parse_user_metadata(conn)
    :ok = Maxio.Metadata.validate_size!(user_metadata)

    # x-amz-tagging 头（PutObject）→ jsonb tag map（校验失败 → InvalidTag 400，铁律 3）。
    tags_map = parse_tagging_header!(conn)

    # SSE-S3：请求头或桶默认加密 = AES256 → 真实加密字节；非 AES256/SSE-C → 501（绝不静默）。
    sse_requested = SSE.resolve_target!(conn.req_headers, bucket)

    # ROUTE B B4-6 D2/D3：用户元数据（x-amz-meta-*）解析一次，喂两路（sidecar object_meta + PG attrs），
    # 消除 :pg/:sidecar 读分裂（D3）。写任何字节/sidecar 之前先做 2 KB 大小闸（D2）——超限 →
    # MetadataTooLarge 400、失败 pre-commit、无孤儿（铁律 3，与 parse_tagging_header!/SSE.resolve_target! 并列）。
    user_metadata = parse_user_metadata(conn)
    :ok = Maxio.Metadata.validate_size!(user_metadata)

    # ROUTE B B4-5：把已算出的富 S3 元数据组成 object_meta，透传进 Storage.put，使纠删/分布式后端
    # 写出完整 maxio/2 sidecar（盘上即事实来源，read/list=:sidecar 下对真实对象可读/可列）。
    # PutObject 当前未捕获 x-amz-meta-*，此处用既有 parse_user_metadata/1 解析并入 sidecar（自描述完整）；
    # PG 索引侧 attrs 保持不变（:pg 默认路径字节级可回滚，user_metadata 仅注入 sidecar）。
    # B1-1：把整个提交 seam（字节经 Storage.put + 元数据经 Objects.put_version_with_id）纳入
    # 同一对象锁，消灭并发同 key 写的「A 字节 + B 元数据」交错（静默 ETag/bytes 分歧）。
    # version_id/SSE/tags 等纯计算/读保持锁外；获锁失败 -> {:error,:locked} -> 503 RequestTimeout（铁律 3）。
    # PutObject body/checksum state is created only after static validation and object lock.
    commit_result =
      Maxio.Lock.with_object_lock({bucket, key}, fn ->
        {body_stream, get_trailers, discard_trailers} =
          BodyReader.stream_with_trailers(conn, payload_mode)

        checksum = Checksum.with_trailer_getter(checksum, get_trailers)

        {plain_chunks, get_checksum, discard_checksum} =
          body_stream |> Checksum.wrap_stream(checksum)

        try do
          {chunks, sse_envelope, visible_size} =
            case sse_requested do
              "AES256" ->
                {counted_chunks, visible_size} = counted_stream(plain_chunks)
                {cipher_stream, envelope} = Maxio.Crypto.SSE.wrap_stream(counted_chunks)
                {cipher_stream, envelope, visible_size}

              nil ->
                {plain_chunks, nil, nil}
            end

          object_meta =
            build_object_meta(
              content_type,
              system_headers,
              storage_class,
              tags_map,
              sse_requested,
              sse_envelope,
              user_metadata,
              visible_size,
              acl_input
            )

          before_object_commit = fn %{size: stored_size, sha256: sha256} ->
            size = if sse_requested == "AES256", do: visible_size.(), else: stored_size
            checksum = get_checksum.()
            :ok = checksum.verify!.()
            :ok = verify_decoded_length!(conn, payload_mode, size)

            unless sse_requested do
              :ok = verify_content_sha256!(conn, payload_mode, sha256)
            end

            %{checksum: checksum, visible_size: size}
          end

          case Storage.put(bucket, key, version_id, chunks,
                 object_meta: object_meta,
                 before_object_commit: before_object_commit
               ) do
            {:ok, %{size: stored_size, etag: etag} = write_result} ->
              # 校验/落库失败 → 先清理已写字节再抛（绝不留孤儿，铁律 3）。
              # SSE 加密对象：后端返回的 stored_size 是密文帧长度；S3 可见 size 用明文计数流统计。
              # x-amz-decoded-content-length 仍按明文 size 校验；x-amz-content-sha256 在 SSE 路径暂不复算
              # 明文 SHA（SigV4/chunked 已在 BodyReader 层验签，后续再补明文 checksum 取证任务）。
              #
              # 传输完整性（decoded-length / content-sha256）失败在两条权威分支下都**致命 + 回滚孤儿**
              # （这是 digest/签名失配，与 PG 无关，铁律 3 绝不静默接受）；仅 PG 索引写在
              # authoritative_source(:write)==:sidecar 时降为 best-effort（见下）。
              size = Map.get(write_result, :visible_size, stored_size)
              checksum = Map.get(write_result, :checksum, checksum)

              {obj, checksum} =
                try do
                  attrs =
                    %{
                      size: size,
                      etag: etag,
                      content_type: content_type,
                      storage_class: storage_class,
                      acl_canned: acl_input.canned,
                      acl_grants: acl_input.grants_doc,
                      # ROUTE B B4-6 D3：user metadata 也写入 PG 索引（键 :metadata，与 CopyObject 的
                      # metadata: meta_map 对齐），消除 :pg(默认) 与 :sidecar 两路读 user metadata 的分裂。
                      metadata: user_metadata,
                      tags: tags_map,
                      sse_algorithm: sse_requested,
                      sse_envelope: sse_envelope
                    }
                    |> Map.merge(system_headers)
                    |> Map.merge(Placement.attrs_from_result(write_result))

                  {commit_metadata(bucket, key, version_id, attrs), checksum}
                rescue
                  err ->
                    _ =
                      Storage.delete(
                        bucket,
                        key,
                        version_id,
                        Placement.storage_opts(write_result)
                      )

                    Log.warn("put object rolled back orphan bytes",
                      action: :put_object,
                      bucket: bucket,
                      key: key,
                      reason: :incomplete_body
                    )

                    reraise(err, __STACKTRACE__)
                end

              {:ok, {size, etag, obj, checksum}}

            {:error, reason} ->
              discard_upload_body_state(discard_checksum, discard_trailers)
              {:error, reason}
          end
        rescue
          err ->
            discard_upload_body_state(discard_checksum, discard_trailers)
            reraise(err, __STACKTRACE__)
        catch
          kind, reason ->
            discard_upload_body_state(discard_checksum, discard_trailers)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end
      end)

    case commit_result do
      {:ok, {:ok, {size, etag, obj, checksum}}} ->
        Log.info("put object",
          action: :put_object,
          bucket: bucket,
          key: key,
          size: size,
          auth_type: conn.assigns.auth_type
        )

        conn
        |> maybe_put_version_id(obj.version_id)
        |> SSE.put_response_header(sse_requested)
        |> Checksum.put_response_headers(checksum)
        |> put_resp_header("etag", XML.quote_etag(etag))
        |> send_resp(200, "")

      {:ok, {:error, :invalid_key}} ->
        # backstop：后端 Paths.encode_key 对非法 key（空 key / 点段，如守卫部署前遗留的在途
        # multipart 会话）结构化拒绝 → 同样映射 400 XMinioInvalidObjectName（绝不 500/静默折叠）。
        raise Error.new(:invalid_object_name, resource: "/#{bucket}/#{key}")

      {:ok, {:error, :key_too_long}} ->
        # backstop：FS 后端把 OS 段长超限（:enametoolong，MinIO errFileNameTooLong 同因）
        # 结构化为 :key_too_long → 400 KeyTooLongError（对齐 MinIO toObjectErr 的
        # ObjectNameTooLong 映射，绝不 500 / 绝不泄露盘路径）。入口守卫
        # （Paths.validate_key 段长闸）已先行拦截，此处仅兜底。
        raise Error.new(:key_too_long, resource: "/#{bucket}/#{key}")

      # 写 quorum 不足 / 原子 rename 争用 = 瞬时写限流，对齐 MinIO 的 SlowDownWrite(503)
      # （cmd/api-errors.go: errErasureWriteQuorum -> ErrSlowDownWrite）。SDK 据此指数退避重试，
      # 集群降级/争用得以自愈；绝不能映射成 500 InternalError（被客户端当硬失败）。
      {:ok, {:error, reason}} when reason in [:write_quorum, :rename_busy] ->
        raise Error.new(:slow_down_write, resource: "/#{bucket}/#{key}")

      {:ok, {:error, reason}} ->
        raise_storage_write_error(reason, bucket, key)

      {:error, :locked} ->
        raise Error.new(:request_timeout, resource: "/#{bucket}/#{key}")
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    _ = ensure_bucket!(bucket)

    # B5-3 R3/R4：对象 key 入口守卫（与 PUT 同源，MinIO 在任何查找前校验对象名）。
    :ok = validate_object_key!(bucket, key)

    # B6-2a：空 `?versionId=` 归一化为 absent（= latest，AWS/MinIO 语义）——绝非 400；
    # 单一来源 VersionId.normalize_param/1（GET/HEAD/DELETE/tagging 同源）。
    version_id =
      conn.query_params
      |> Map.get("versionId")
      |> Maxio.Versioning.VersionId.normalize_param()

    # B5-4：客户端 versionId 入口守卫（非法形状 → 400 InvalidArgument，先于任何查找/盘路径构造）。
    :ok = validate_version_id!(bucket, key, version_id)
    # ROUTE B：经 Maxio.ObjectMeta.get 取对象（读权威单一入口）。
    #   :pg（默认）→ 返回 PG %Object{} + 内部 best-effort sidecar shadow（行为不变）；
    #   :read=:sidecar（B4-3）→ 返回 reconcile 的 sidecar 视图，read_quorum 不足 → 503（绝不猜）。
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
                # SSE-S3 加密对象：密文是帧化的，Range 必须作用在解密后的明文字节上。
                # 对单区间 Range，先映射到覆盖该明文区间的完整密文帧 byte-range，再解密和裁剪首尾
                # 明文帧；避免为了小范围读取/认证无关的后续密文帧。
                {cipher_range, plain_slice} = sse_ranges(range, total)

                {:ok, raw_stream} =
                  Storage.get(
                    bucket,
                    key,
                    object.version_id,
                    cipher_range,
                    Placement.storage_opts(object)
                  )

                send_authenticated_sse_object!(
                  conn,
                  object,
                  total,
                  range,
                  raw_stream,
                  plain_slice
                )

              _ ->
                {:ok, stream} =
                  Storage.get(
                    bucket,
                    key,
                    object.version_id,
                    range_tuple(range),
                    Placement.storage_opts(object)
                  )

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

    # B6-2a：空 `?versionId=` 归一化为 absent（与 GET 同源，单一来源 normalize_param/1）。
    version_id =
      conn.query_params
      |> Map.get("versionId")
      |> Maxio.Versioning.VersionId.normalize_param()

    # ROUTE B：经 Maxio.ObjectMeta.get 取对象（读权威单一入口；:pg 默认含内部 shadow，行为不变）。
    # HEAD 无 body：缺失/read_quorum 不足都只回状态 + 头（read_quorum 不足 → 503，对齐 GET SlowDownRead）。
    # B5-3 R3/R4：key 守卫与 GET 同源（Paths.validate_key）；B5-4：超长 key（:key_too_long）与
    # 客户端 versionId 形状守卫（validate_version_id）同样先于任何查找——HEAD 无 body 故仅回 400 状态。
    with {:ok, _b} <- Buckets.lookup(bucket),
         :ok <- Maxio.Cluster.Paths.validate_key(key),
         :ok <- validate_version_id(version_id),
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
              |> SSE.put_response_header(object.sse_algorithm)
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

      {:error, :invalid_key} ->
        # B5-3 R3/R4：保留布局名段/点段 key → 400（与 GET 的 XMinioInvalidObjectName 同因；
        # HEAD 无 body 故仅状态码，结构化日志留痕，铁律 3 不静默）。
        Log.info("head object invalid key",
          action: :head_object,
          bucket: bucket,
          key: key,
          reason: :invalid_key
        )

        send_resp(conn, 400, "")

      {:error, :key_too_long} ->
        # B5-4：原始 key 超 1024 字节 → 400（与 GET 的 KeyTooLongError 同因；HEAD 无 body
        # 故仅状态码，结构化日志留痕，铁律 3 不静默）。
        Log.info("head object key too long",
          action: :head_object,
          bucket: bucket,
          key: key,
          reason: :key_too_long
        )

        send_resp(conn, 400, "")

      {:error, :invalid_version_id} ->
        # B5-4：客户端 versionId 形状非法 → 400（与 GET 的 InvalidArgument 同因；先于任何
        # 查找/盘路径构造；HEAD 无 body 故仅状态码，结构化日志留痕，铁律 3 不静默）。
        Log.info("head object invalid version id",
          action: :head_object,
          bucket: bucket,
          key: key,
          reason: :invalid_version_id
        )

        send_resp(conn, 400, "")

      {:error, :read_quorum} ->
        # 仅 :read=:sidecar 时可达：sidecar reconcile 不足 read_quorum → 503（绝不猜，铁律 3）。
        # HEAD 无 body：只回 503 状态（与 GET 的 SlowDownRead 同源，SDK 据此退避重试；HEAD 响应无
        # XML body 故不渲染 Code，但状态码与 GET 的 503 一致，对齐 MinIO errErasureReadQuorum）。
        Log.warn("head object unavailable: sidecar read_quorum unmet",
          action: :head_object,
          bucket: bucket,
          key: key,
          reason: :read_quorum
        )

        send_resp(conn, 503, "")
    end
  end

  # 经 ObjectMeta.get 统一读权威分流：%Object{} → {:ok, object}；错误元组原样透传给 head/1 的 else。
  defp fetch_for_head(bucket, key, version_id) do
    case Maxio.ObjectMeta.get(bucket, key, version_id, []) do
      %Objects.Object{} = object -> {:ok, object}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    bucket_meta = ensure_bucket!(bucket)

    # B5-3 R3/R4：key 守卫（保留布局名段/点段 → 400，修 delete-marker 路径此前的 500 InternalError）。
    :ok = validate_object_key!(bucket, key)

    # B6-2a：空 `?versionId=` 归一化为 absent（= 走 marker/普通删除分支，AWS/MinIO 语义）。
    version_id =
      conn.query_params
      |> Map.get("versionId")
      |> Maxio.Versioning.VersionId.normalize_param()

    # B5-4：客户端 ?versionId 入口守卫（非法形状 → 400 InvalidArgument，先于任何查找/盘路径构造
    # ——尤其 :write=:sidecar 下 Storage.delete_version 直接以 versionId 构造盘路径）。
    :ok = validate_version_id!(bucket, key, version_id)
    versioning = bucket_meta.versioning

    cond do
      version_id != nil ->
        MFADelete.require_for_delete_version!(conn, bucket_meta)

        # 永久删除指定版本（含 delete marker）。ROUTE B fidelity：按写权威分流的单一提交路径
        # commit_version_delete（:sidecar → 盘上 quorum 删除即权威提交，quorum 不足 503 绝不 204；
        # :pg → PG 删行权威先行），与 DeleteObjects 的 do_delete_one 共用。幂等：不存在也 204。
        %{was_delete_marker: dm?} = commit_version_delete(bucket, key, version_id)
        Log.info("delete object version", action: :delete_object, bucket: bucket, key: key)

        conn
        |> put_resp_header("x-amz-version-id", version_id)
        |> then(fn c ->
          if dm?, do: put_resp_header(c, "x-amz-delete-marker", "true"), else: c
        end)
        |> send_resp(204, "")

      versioning in ["Enabled", "Suspended"] ->
        MFADelete.require_for_delete_marker!(conn, bucket_meta)

        # 插入 delete marker（Enabled 新 ULID；Suspended null）。ROUTE B B5-0：先盘上落
        # delete-marker sidecar（sidecar 权威下的删除完整性，quorum 致命），再 PG 索引（best-effort）。
        dm_vid = commit_delete_marker(bucket, key, versioning)
        Log.info("delete object marker", action: :delete_object, bucket: bucket, key: key)

        conn
        |> maybe_put_version_id(dm_vid)
        |> put_resp_header("x-amz-delete-marker", "true")
        |> send_resp(204, "")

      true ->
        # Unversioned：真删（删 null 行 + 字节）。B1-1：元数据 + 字节删除纳入同一对象锁，
        # 避免与并发同 key PUT 的提交 seam 交错（获锁失败 -> 503 RequestTimeout，铁律 3）。
        case Maxio.Lock.with_object_lock({bucket, key}, fn ->
               storage_opts = storage_opts_for_current(bucket, key)
               :ok = Objects.delete_metadata(bucket, key)
               _ = Storage.delete(bucket, key, "null", storage_opts)
               :ok
             end) do
          {:ok, :ok} ->
            Log.info("delete object", action: :delete_object, bucket: bucket, key: key)
            send_resp(conn, 204, "")

          {:error, :locked} ->
            raise Error.new(:request_timeout, resource: "/#{bucket}/#{key}")
        end
    end
  end

  @spec delete_objects(Plug.Conn.t()) :: Plug.Conn.t()
  def delete_objects(conn) do
    bucket = conn.assigns.s3_bucket
    bucket_meta = ensure_bucket!(bucket)
    {conn, xml} = read_small_body!(conn)

    %{quiet: quiet, objects: objects} =
      case DeleteParser.parse(xml) do
        {:ok, parsed} -> parsed
        {:error, :malformed_xml} -> raise Error.new(:malformed_xml, resource: "/" <> bucket)
      end

    if length(objects) > 1000 do
      raise Error.new(:malformed_xml, message: "A maximum of 1000 keys may be specified")
    end

    MFADelete.validate_batch_delete!(conn, bucket_meta, objects)

    versioning = bucket_meta.versioning

    # 逐 key 对象级授权（铁律 2：复用 Authz 单一授权路径，仅资源 ARN 改成每个 key 的对象 ARN）。
    # 无权 key 回 per-key <Error>AccessDenied</Error>（HTTP 200 混合结果）且绝不删；有权 key 才删。
    principal = conn.assigns[:principal]
    authenticated? = principal != :anonymous
    conditions = Maxio.S3.Authz.conditions_for(conn, authenticated?)
    owner? = Maxio.S3.Authz.owner?(principal, bucket)

    {deleted, errors} =
      Enum.reduce(objects, {[], []}, fn obj, {dacc, eacc} ->
        if delete_authorized?(
             bucket,
             obj.key,
             obj.version_id,
             principal,
             authenticated?,
             owner?,
             conditions
           ) do
          case delete_one(bucket, obj, versioning) do
            {:ok, entry} -> {[entry | dacc], eacc}
            {:error, err} -> {dacc, [err | eacc]}
          end
        else
          # B6-2a：per-key <Error> 携带请求给的 VersionId（MinIO DeleteError 对 AccessDenied
          # 同样回显 object.VersionID；nil 不渲染）。
          err = %{
            key: obj.key,
            version_id: obj.version_id,
            code: "AccessDenied",
            message: "Access Denied"
          }

          {dacc, [err | eacc]}
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

      # B6-2a：错误条目回显请求给的 per-key VersionId（AWS Error 元素含 VersionId；
      # MinIO DeleteError 原样回显 object.VersionID；nil 不渲染）。
      {:error, %{key: key, version_id: version_id, code: s3err.code, message: s3err.message}}
  end

  defp do_delete_one(bucket, key, version_id, versioning) do
    cond do
      version_id != nil ->
        # B6-2a（修 B5-4 的 Code 偏离）：批量删除的 per-key 畸形 versionId → 该 key
        # <Error><Code>NoSuchVersion</Code>（对齐 MinIO DeleteMultipleObjectsHandler：
        # uuid.Parse 失败 → ErrNoSuchVersion 落 per-key DeleteError，绝非整请求级的
        # ErrInvalidVersionID——后者专属单删 DELETE ?versionId 的 400）。raise 由 delete_one
        # 的 rescue 降为该 key 的 <Error> 条目（携回显 VersionId）；守卫语义不变：仍先于
        # 任何查找/盘路径构造拦截（B5-4 安全闸，形状单一来源 VersionId.valid?/1）。
        if not Maxio.Versioning.VersionId.valid?(version_id) do
          raise Error.new(:no_such_version,
                  message: "The specified version does not exist. (invalid version id specified)",
                  resource: "/#{bucket}/#{key}"
                )
        end

        # 永久删指定版本（含 delete marker）。幂等：删不存在的版本也算成功。ROUTE B fidelity：
        # 与单删 delete/1 同一 commit_version_delete 提交路径（:sidecar 写权威下盘上 quorum 删除
        # 即权威提交；quorum 不足上抛 SlowDownWrite，由 delete_one 的 rescue 降为该 key 的 <Error>）。
        %{was_delete_marker: dm?} = commit_version_delete(bucket, key, version_id)
        {:ok, %{key: key, version_id: version_id, delete_marker: dm?}}

      versioning in ["Enabled", "Suspended"] ->
        # 无 VersionId 且版本化桶 → 插 delete marker（绝不硬删历史版本）。ROUTE B B5-0：与单删
        # delete/1 同路径——先盘上落 delete-marker sidecar（quorum 致命），再 PG 索引（best-effort）。
        dm_vid = commit_delete_marker(bucket, key, versioning)
        {:ok, %{key: key, delete_marker: true, delete_marker_version_id: dm_vid}}

      true ->
        # 未版本化桶 → 硬删（删 null 行 + 字节）。缺失 key 也算成功（S3 语义）。
        storage_opts = storage_opts_for_current(bucket, key)
        :ok = Objects.delete_metadata(bucket, key)
        _ = Storage.delete(bucket, key, "null", storage_opts)
        {:ok, %{key: key}}
    end
  end

  # 单 key 是否被授权删除：owner/root 短路放行；否则对该 key 的对象 ARN 跑 Evaluator。
  # VersionId 永久删除必须要求 s3:DeleteObjectVersion；普通删除仍要求 s3:DeleteObject。
  # 复用 Maxio.S3.Authz 暴露的同源零件（conditions/object_statements/Evaluator），绝不另起授权逻辑。
  defp delete_authorized?(
         bucket,
         key,
         version_id,
         principal,
         _authenticated?,
         true,
         conditions
       ) do
    resource = Maxio.Policy.Arn.object_arn(bucket, key)
    action = if version_id, do: "s3:DeleteObjectVersion", else: "s3:DeleteObject"

    Maxio.S3.Authz.session_policy_allows?(principal, action, resource, conditions)
  end

  defp delete_authorized?(bucket, key, version_id, principal, authenticated?, _owner?, conditions) do
    resource = Maxio.Policy.Arn.object_arn(bucket, key)
    statements = Maxio.S3.Authz.object_statements(bucket, key, principal)
    action = if version_id, do: "s3:DeleteObjectVersion", else: "s3:DeleteObject"

    ctx = %Maxio.Policy.RequestContext{
      principal: principal,
      authenticated?: authenticated?,
      owner?: false,
      action: action,
      resource: resource,
      conditions: conditions
    }

    case Maxio.Policy.Evaluator.evaluate(ctx, statements) do
      :allow -> Maxio.S3.Authz.session_policy_allows?(principal, action, resource, conditions)
      {:deny, _reason} -> false
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

    # B5-3 R3/R4：Copy 目标与源 key 都过同一入口守卫（保留布局名段/点段 → 400）。
    :ok = validate_object_key!(dest_bucket, dest_key)

    {src_bucket, src_key, src_version_id} =
      parse_copy_source!(header(conn, "x-amz-copy-source"))

    :ok = validate_object_key!(src_bucket, src_key)

    # B5-4：Copy 源 versionId 入口守卫（与 GET/HEAD/DELETE 的 ?versionId 同源单一来源）——
    # 非法形状 → 400 InvalidArgument，先于任何源查找/盘路径构造。
    :ok = validate_version_id!(src_bucket, src_key, src_version_id)

    directive = parse_copy_directive!(conn, "x-amz-metadata-directive")
    tagging_directive = parse_copy_directive!(conn, "x-amz-tagging-directive")
    storage_class = StorageClass.parse!(header(conn, "x-amz-storage-class"))
    acl_input = acl_from_headers!(conn)
    :ok = PublicAccessBlock.reject_public_acl_write!(dest_bucket, acl_input)
    target_sse = SSE.resolve_target!(conn.req_headers, dest_bucket)
    SSE.reject_copy_source_customer_headers!(conn.req_headers)

    # 源对象按真实版本解析（默认 current/latest，?versionId= 选特定版本），并经 ObjectMeta
    # 统一读权威入口分流：:pg 默认行为不变；:read=:sidecar 时 CopyObject 继承的是盘上权威元数据。
    {src_obj, _total} = object_or_raise(src_bucket, src_key, src_version_id)

    # 源是 delete marker 时必须在读字节前结构化拒绝：latest marker → 404（表现为已删除）；
    # 显式 versionId 指向 marker → 400 InvalidArgument（CopySource 不允许 marker 版本）。
    cond do
      src_obj.is_delete_marker and src_version_id == nil ->
        raise Error.new(:no_such_key, resource: "/#{src_bucket}/#{src_key}")

      src_obj.is_delete_marker ->
        raise Error.new(:invalid_argument,
                message: "Cannot copy a delete marker version",
                resource: "/#{src_bucket}/#{src_key}"
              )

      true ->
        :ok
    end

    # 源条件头（对源对象求值；失败 412）。
    case eval_copy_source_conditions(conn, src_obj) do
      :proceed ->
        :ok

      {:error, :precondition_failed} ->
        raise Error.new(:precondition_failed, resource: "/#{src_bucket}/#{src_key}")
    end

    system_headers = copy_system_headers(conn, src_obj, directive)

    content_type =
      case directive do
        "REPLACE" -> header(conn, "content-type") || "binary/octet-stream"
        _ -> src_obj.content_type
      end

    # FX-M4：用户 metadata（x-amz-meta-*）按 metadata-directive 计算——
    # COPY（默认）保留源对象 metadata；REPLACE 用请求头 x-amz-meta-* 头（不继承源）。
    meta_map = copy_user_metadata(conn, src_obj, directive)

    # ROUTE B B4-6 D2：仅 REPLACE 时请求头 x-amz-meta-* 生效，做 2 KB 大小闸（与 PutObject 同阈值/同语义）。
    # 在写任何字节/sidecar 之前 → 超限 MetadataTooLarge 400、失败 pre-commit、无孤儿（铁律 3）。
    # COPY（继承源 metadata）不校验：源对象写入时已过闸，避免对历史对象误判。
    if directive == "REPLACE", do: :ok = Maxio.Metadata.validate_size!(meta_map)

    # tags 受 tagging-directive 独立控制（与 metadata-directive 正交，对齐 AWS/MinIO，铁律 5）：
    # COPY（默认）→ 目标继承源 tag-set；REPLACE → 用 x-amz-tagging 头解析的新 tag-set
    # （复用 PutObject helper，非法 → InvalidTag 400）。

    # 自拷贝守卫：src==dest 且没有 metadata / tag / storage-class / ACL 变化 → 400 InvalidRequest。
    # AWS CopyObject 可用 x-amz-storage-class 或 x-amz-acl 改现有对象；这种自拷贝是合法变化，
    # 不能被旧的「directive == COPY 即拒」粗守卫挡住。SSE 状态变化（加密/解密）同样是合法变化。
    if src_bucket == dest_bucket and src_key == dest_key and directive == "COPY" and
         tagging_directive == "COPY" and storage_class == (src_obj.storage_class || "STANDARD") and
         acl_input.canned == (src_obj.acl_canned || "private") and
         acl_input.grants_doc == (src_obj.acl_grants || ACL.empty_grants_doc()) and
         target_sse == src_obj.sse_algorithm and not SSE.explicit_target?(conn.req_headers) do
      raise Error.new(:invalid_request,
              message:
                "This copy request is illegal because it is trying to copy an object to itself " <>
                  "without changing the object's metadata, storage class, website redirect location " <>
                  "or encryption attributes."
            )
    end

    tags =
      case tagging_directive do
        "REPLACE" -> parse_tagging_header!(conn)
        _ -> src_obj.tags || %{}
      end

    # 拷贝字节（铁律 4 不全缓冲）。合法自拷贝必须避免
    # 「截断 dest 早于读 source」的数据丢失：先流式写到唯一临时 key，再流式搬到 dest，最后删临时。
    self_copy? = src_bucket == dest_bucket and src_key == dest_key

    # FX-H2：目标版本按目标桶 versioning 决定（Enabled→新 ULID，否则 "null"，与 do_put 一致，铁律 5）。
    # 目标字节落该 version_id 路径、落库用同一 version_id（put_version_with_id 尊重外部 id），
    # Enabled 桶每次 copy 产生新版本并回 x-amz-version-id；Unversioned 仍 upsert null 行不回版本头。
    dest_versioning = bucket_versioning(dest_bucket)

    dest_version_id =
      if dest_versioning == "Enabled", do: Maxio.Versioning.VersionId.generate(), else: "null"

    # B1-1：目标提交 seam（目标字节写 + Objects.put_version_with_id）纳入「目标对象锁」单点。
    # 源读（含自拷贝先写临时 key）在锁外完成 —— 仅目标 dest_key 持目标锁，绝不在源读上持目标锁，
    # 避免跨 key 死锁 + :global.trans 非重入死等（铁律 2：锁是请求编排关注点）。
    src_stream =
      prepare_copy_source(
        self_copy?,
        src_bucket,
        src_key,
        src_obj,
        src_obj.version_id,
        dest_bucket,
        dest_key
      )

    commit_result =
      try do
        {copy_stream, target_sse_envelope, visible_size} =
          prepare_copy_payload(src_obj, src_stream.stream, target_sse)

        # ROUTE B B4-5：CopyObject 同样透传 object_meta（content_type/tags/user_metadata 已按
        # metadata/tagging-directive 解析），使复制对象也写出完整 maxio/2 sidecar。SSE-S3 源对象先解密
        # 成明文；目标是否加密由目标请求头 / 目标桶默认加密决定（对齐 CopyObject 的“新对象”语义）。
        # ACL 不继承源对象（AWS CopyObject 默认 private），显式 x-amz-acl 才应用到目标。
        dest_object_meta =
          %{
            size: visible_size,
            content_type: content_type,
            tags: tags,
            acl_canned: acl_input.canned,
            acl_grants: acl_input.grants_doc,
            storage_class: storage_class,
            sse: sse_meta(target_sse, target_sse_envelope),
            user_metadata: meta_map
          }
          |> Map.merge(SystemHeaders.to_object_meta(system_headers))

        Maxio.Lock.with_object_lock({dest_bucket, dest_key}, fn ->
          {_stored_size, etag, write_result} =
            case Storage.put(dest_bucket, dest_key, dest_version_id, copy_stream,
                   object_meta: dest_object_meta
                 ) do
              {:ok, %{size: size, etag: etag} = write_result} -> {size, etag, write_result}
              {:error, reason} -> raise_storage_write_error(reason, dest_bucket, dest_key)
            end

          size = visible_size.()

          # ROUTE B B5-1：CopyObject 元数据提交收敛到与 do_put 同一 commit_metadata 分流
          # （铁律 2 单一提交路径）：:pg（默认）→ put_version_with_id 致命（{:ok,obj} 匹配失败上抛），
          # 字节级不变；:sidecar → put_version_index best-effort（失败 Log.error 非致命——目标 sidecar
          # 已随 Storage.put 达 write_quorum 权威落盘）+ build_put_view 内存构造响应视图（不依赖 PG 读回）。
          obj =
            commit_metadata(
              dest_bucket,
              dest_key,
              dest_version_id,
              %{
                size: size,
                etag: etag,
                content_type: content_type,
                storage_class: storage_class,
                acl_canned: acl_input.canned,
                acl_grants: acl_input.grants_doc,
                metadata: meta_map,
                tags: tags,
                sse_algorithm: target_sse,
                sse_envelope: target_sse_envelope
              }
              |> Map.merge(system_headers)
              |> Map.merge(Placement.attrs_from_result(write_result)),
              :copy_object
            )

          {size, etag, obj}
        end)
      after
        cleanup_copy_source(src_stream)
      end

    {_size, etag, obj} =
      case commit_result do
        {:ok, committed} ->
          committed

        {:error, :locked} ->
          raise Error.new(:request_timeout, resource: "/#{dest_bucket}/#{dest_key}")
      end

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

    # Enabled 目标回 x-amz-version-id（"null" 不回显）；版本化源回 x-amz-copy-source-version-id
    # （"null" 未版本化源不回显），对齐 AWS CopyObject 响应头（铁律 5）。
    conn
    |> put_resp_content_type("application/xml")
    |> maybe_put_version_id(obj.version_id)
    |> maybe_put_copy_source_version_id(src_obj.version_id)
    |> SSE.put_response_header(target_sse)
    |> send_resp(200, body)
  end

  defp prepare_copy_payload(src_obj, raw_stream, target_sse) do
    plain_stream =
      case src_obj.sse_algorithm do
        nil ->
          raw_stream

        "AES256" ->
          Maxio.Crypto.SSE.unwrap_stream(raw_stream, src_obj.sse_envelope)

        alg ->
          raise Error.new(:not_implemented,
                  message: "CopyObject for #{alg} source objects not implemented"
                )
      end

    {plain_stream, visible_size} = counted_stream(plain_stream)

    case target_sse do
      "AES256" ->
        {cipher_stream, envelope} = Maxio.Crypto.SSE.wrap_stream(plain_stream)
        {cipher_stream, envelope, visible_size}

      nil ->
        {plain_stream, nil, visible_size}
    end
  end

  # 非自拷贝：直接返回源对象「真实版本」流（锁外打开，目标写时消费）。
  # src_version_id 为源对象的真实版本路径（版本化源 ULID、未版本化源 "null"），绝不再硬编码 "null"
  # （否则版本化源读不到字节 → 静默产生空目标，铁律 5）。:tmp_key=nil 表示无临时副本需清理。
  defp prepare_copy_source(
         false,
         src_bucket,
         src_key,
         src_obj,
         src_version_id,
         _dest_bucket,
         _dest_key
       ) do
    {:ok, src_stream} =
      Storage.get(src_bucket, src_key, src_version_id, nil, Placement.storage_opts(src_obj))

    %{stream: src_stream, dest_bucket: nil, tmp_key: nil}
  end

  # 自拷贝（src==dest）：锁外先把源「真实版本」流式写到唯一临时 key（避免目标写截断源），
  # 返回临时流供目标写消费。
  defp prepare_copy_source(
         true,
         src_bucket,
         src_key,
         src_obj,
         src_version_id,
         dest_bucket,
         dest_key
       ) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    # B5-4：临时 key 自身必须通过 key 守卫（1024 字节长度闸）——近上限 dest_key 直接整段做前缀
    # 会超限（曾静默通过，现会被 Paths 拒绝）。仅取 dest_key 的码点安全前缀（≤ 64 码点 ≤ 256 字节）
    # 作归因可读性；唯一性由 16 hex 随机后缀保证；末段恒以 ".maxio-copytmp-<hex>" 结尾，
    # 绝不构成 `.`/`..` 段——tmp_key 恒为合法 key。
    tmp_key = String.slice(dest_key, 0, 64) <> ".maxio-copytmp-" <> suffix

    {:ok, src_stream} =
      Storage.get(src_bucket, src_key, src_version_id, nil, Placement.storage_opts(src_obj))

    case Storage.put(dest_bucket, tmp_key, "null", src_stream) do
      {:ok, tmp_result} ->
        tmp_storage_opts = Placement.storage_opts(tmp_result)
        {:ok, tmp_stream} = Storage.get(dest_bucket, tmp_key, "null", nil, tmp_storage_opts)

        %{
          stream: tmp_stream,
          dest_bucket: dest_bucket,
          tmp_key: tmp_key,
          tmp_storage_opts: tmp_storage_opts
        }

      {:error, reason} ->
        raise_storage_write_error(reason, dest_bucket, dest_key)
    end
  end

  # 清理自拷贝的临时副本（非自拷贝 tmp_key=nil，无操作）。
  defp cleanup_copy_source(%{tmp_key: nil}), do: :ok

  defp cleanup_copy_source(%{
         dest_bucket: dest_bucket,
         tmp_key: tmp_key,
         tmp_storage_opts: tmp_storage_opts
       }) do
    _ = Storage.delete(dest_bucket, tmp_key, "null", tmp_storage_opts)
    :ok
  end

  defp storage_opts_for_current(bucket, key) do
    case Objects.get_metadata(bucket, key) do
      {:ok, obj} -> Placement.storage_opts(obj)
      {:error, :not_found} -> []
    end
  end

  defp storage_opts_for_version(bucket, key, version_id) do
    case Objects.get_version(bucket, key, version_id) do
      {:ok, obj} -> Placement.storage_opts(obj)
      {:error, :not_found} -> []
    end
  end

  defp raise_storage_write_error(reason, bucket, key)
       when reason in [:write_quorum, :rename_busy],
       do: raise(Error.new(:slow_down_write, resource: "/#{bucket}/#{key}"))

  defp raise_storage_write_error(reason, bucket, key) do
    cond do
      placement_unavailable?(reason) ->
        raise Error.new(:slow_down_write, resource: "/#{bucket}/#{key}")

      placement_internal_error?(reason) ->
        raise Error.new(:internal_error, resource: "/#{bucket}/#{key}")

      true ->
        raise Error.new(:internal_error, message: inspect(reason))
    end
  end

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

  # ── helpers ──

  # ROUTE B B5-0 —— delete marker 提交（DELETE 无 versionId，桶 Enabled/Suspended）。
  #
  # 根因：`insert_delete_marker` 纯 PG、盘上从不落 delete-marker sidecar →
  # `authoritative_source(:read|:list)=:sidecar` 下 DeleteObject 后盘上旧对象 sidecar 仍在
  # → GET 仍 200、LIST 仍列出 = **已删对象复活**（critical）。修法：删除是写操作，必须被盘上权威记录。
  #
  # 对象锁内（B1-1：盘 + PG 同锁）按写权威分流，**铁律：权威提交成功之前绝不执行破坏性步骤**：
  #
  #   * `authoritative_source(:write)==:sidecar` → 盘上 marker sidecar 即权威提交：**先**
  #     put_delete_marker（quorum 闸）。meta_only commit 本就原子 rename meta.json 覆盖旧 sidecar
  #     ——Suspended 的 null「替换」语义由该 rename 天然完成（B5-3 R2：取消了旧序「写 marker 前先删
  #     null 版本」的破坏性步骤——那会在 marker quorum 失败时留下裸 404 窗口；现在 quorum 失败 →
  #     503 SlowDownWrite 时旧 null 版本完好可读，重试收敛）。被替换 null 版本的孤儿 part.0 由后端
  #     在 quorum 成功后 best-effort GC（part.0 是盘上布局知识，属后端不属 handler）。PG 索引降
  #     best-effort（insert_delete_marker_index 失败 Log.error 不致命，scanner 后续 reconcile）。
  #
  #   * `:pg`（默认）→ PG upsert 即权威提交：insert_delete_marker_with_id **先行且致命**
  #     （失败 MatchError 上抛 → 500，此时盘上分毫未动 = 与 B5-0 之前的纯 PG 路径同样无破坏性
  #     失败路径，绝不出现「null 版本字节已毁而权威 PG 仍记对象存活」的永久撕裂态）。PG 成功后
  #     才做 Suspended null 版本字节清理 + 盘上 marker 镜像，两者均 best-effort（删除已权威提交，
  #     盘上残留对 PG 读/列权威不可见，只是垃圾字节）。
  #
  # 返回 delete marker 的 version_id；获锁失败 → 503 RequestTimeout，盘 quorum 不足 → 503 SlowDownWrite（铁律 3）。
  defp commit_delete_marker(bucket, key, versioning) do
    version_id =
      if versioning == "Enabled", do: Maxio.Versioning.VersionId.generate(), else: "null"

    result =
      Maxio.Lock.with_object_lock({bucket, key}, fn ->
        case Maxio.ObjectMeta.authoritative_source(:write) do
          :sidecar -> commit_delete_marker_sidecar(bucket, key, version_id)
          _pg -> commit_delete_marker_pg(bucket, key, version_id, versioning)
        end
      end)

    case result do
      {:ok, :ok} ->
        version_id

      {:ok, {:error, :invalid_key}} ->
        # B5-3 R4：路径守卫拒绝的 key（保留布局名段/点段）→ 400 结构化错误，绝不再塌缩成 500
        # InternalError（入口守卫已拦截大多数；此分支兜底空段 key 等 sidecar 布局不可表达的 key）。
        raise Error.new(:invalid_object_name, resource: "/#{bucket}/#{key}")

      {:ok, {:error, reason}} when reason in [:write_quorum, :rename_busy] ->
        raise Error.new(:slow_down_write, resource: "/#{bucket}/#{key}")

      {:ok, {:error, reason}} ->
        raise_storage_write_error(reason, bucket, key)

      {:error, :locked} ->
        raise Error.new(:request_timeout, resource: "/#{bucket}/#{key}")
    end
  end

  # ROUTE B fidelity —— DELETE ?versionId 永久删除指定版本，按写权威分流（镜像 B5-0
  # commit_delete_marker 的提交 split，铁律 2 单一提交路径：单删 delete/1 与批量 do_delete_one 共用）。
  #
  # 根因（B5-2 审计 high）：版本删除从前 PG-first（Objects.delete_version 权威、盘上删除结果静默
  # 丢弃；PG 行缺失时甚至完全不触盘就回 204）→ `authoritative_source(:write)=:sidecar` 下盘上才是
  # 权威介质，「204 但权威盘上版本仍在」会被 B5-2 scanner forward 从幸存 sidecar 忠实 re-upsert 回
  # PG（**已永久删除的版本复活**），且 reverse-GC「盘上确有 → 绝不删」守恒保证该行永不消失。
  #
  #   * `:sidecar` → 盘上版本目录的 quorum 删除即权威提交（`Storage.delete_version`：确认删除 =
  #     端点可达且版本目录显式 missing，≥ write_quorum 端点确认才 :ok；不足 →
  #     {:error,:write_quorum} → 503 SlowDownWrite，**绝不在权威介质仍持有该版本时回 204**——对齐
  #     MinIO DeleteVersion 的 write-quorum 语义：errErasureWriteQuorum → ErrSlowDownWrite，
  #     cmd/api-errors.go）。PG 行删除降 best-effort 索引维护（Objects.delete_version_index，失败
  #     Log.error 非致命，scanner reverse-GC 后续收敛）。x-amz-delete-marker 响应头的 marker 性经
  #     读权威单一入口（ObjectMeta.get）在删除前 best-effort 判定（删的是 marker 时回 true，对齐 AWS）。
  #   * `:pg`（默认）→ 维持既有语义：Objects.delete_version 权威先行（{:error,:not_found} 幂等
  #     204、不触盘——PG 即事实来源，无行 = 版本不存在）；盘上字节删除 best-effort 但结果**不再
  #     静默丢弃**（失败 Log.warn 归因，铁律 3 不静默；PG 权威下盘上残留对读/列不可见，仅垃圾字节）。
  #
  # 幂等：版本不存在（盘上全端点显式 missing / PG 无行）也回 204（对齐 AWS）。
  # 获锁失败 → 503 RequestTimeout；盘 quorum 不足 → 503 SlowDownWrite（铁律 3）。
  defp commit_version_delete(bucket, key, version_id) do
    result =
      Maxio.Lock.with_object_lock({bucket, key}, fn ->
        case Maxio.ObjectMeta.authoritative_source(:write) do
          :sidecar -> commit_version_delete_sidecar(bucket, key, version_id)
          _pg -> commit_version_delete_pg(bucket, key, version_id)
        end
      end)

    case result do
      {:ok, {:ok, dm?}} ->
        %{was_delete_marker: dm?}

      {:ok, {:error, reason}} when reason in [:write_quorum, :rename_busy] ->
        raise Error.new(:slow_down_write, resource: "/#{bucket}/#{key}")

      {:ok, {:error, reason}} ->
        raise Error.new(:internal_error, message: inspect(reason))

      {:error, :locked} ->
        raise Error.new(:request_timeout, resource: "/#{bucket}/#{key}")
    end
  end

  # :sidecar 写权威：盘上版本目录的 quorum 删除即权威提交；PG 行删除 best-effort 索引维护。
  # marker 性在删除前判定（删后盘上无从判定）。{:error,:invalid_key}（路径守卫拒绝的 key 在盘上
  # 不可能存在任何版本）→ 视同不存在（幂等 204，对齐 AWS 删除不存在版本）。
  defp commit_version_delete_sidecar(bucket, key, version_id) do
    dm? = version_is_delete_marker?(bucket, key, version_id)
    storage_opts = storage_opts_for_version(bucket, key, version_id)

    case Storage.delete_version(bucket, key, version_id, storage_opts) do
      :ok ->
        case Objects.delete_version_index(bucket, key, version_id) do
          :ok ->
            :ok

          {:error, reason} ->
            Log.error(
              "pg version-delete index update failed (version durably deleted on disk quorum)",
              action: :delete_object,
              bucket: bucket,
              key: key,
              reason: inspect(reason)
            )
        end

        {:ok, dm?}

      {:error, :invalid_key} ->
        {:ok, false}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # :pg（默认）写权威：PG 删行权威先行（既有语义/状态码不变）；盘上字节删除 best-effort 但失败
  # 必 Log.warn 归因（绝不再静默丢弃结果，铁律 3）。
  defp commit_version_delete_pg(bucket, key, version_id) do
    storage_opts = storage_opts_for_version(bucket, key, version_id)

    case Objects.delete_version(bucket, key, version_id) do
      {:ok, %{was_delete_marker: dm?}} ->
        case Storage.delete(bucket, key, version_id, storage_opts) do
          :ok ->
            :ok

          {:error, reason} ->
            Log.warn(
              "version bytes delete failed after authoritative PG row delete (left for GC)",
              action: :delete_object,
              bucket: bucket,
              key: key,
              reason: inspect(reason)
            )
        end

        {:ok, dm?}

      {:error, :not_found} ->
        # 幂等：删不存在的版本也回 204（对齐 AWS）。:pg 权威下 PG 即事实来源，无行 = 版本不存在。
        {:ok, false}
    end
  end

  # marker 性 best-effort 判定（仅响应头 x-amz-delete-marker 用）：经读权威单一入口取该版本视图；
  # 取不到（not_found / read_quorum / 任何异常）→ false（头缺省，绝不阻断删除本身）。
  defp version_is_delete_marker?(bucket, key, version_id) do
    case Maxio.ObjectMeta.get(bucket, key, version_id, []) do
      %Objects.Object{is_delete_marker: dm?} -> dm? == true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # :sidecar 写权威：盘上 marker sidecar 即权威提交（B5-3 R2 重排）。**先** put_delete_marker
  # （quorum 闸）——meta_only commit 原子 rename meta.json 覆盖旧 sidecar，Suspended 的 null
  # 「替换」语义天然由该 rename 完成，绝不在权威提交前执行破坏性删除（旧序在 marker quorum 失败时
  # 留下「旧 null 版本已毁 + marker 未落」的裸 404 窗口）。被替换 null 版本的孤儿 part.0 由后端在
  # quorum 成功后 best-effort GC。marker quorum 失败 {:error,reason} 原样上抛（→ 503 SlowDownWrite，
  # 旧对象完好可读，重试收敛）；PG 索引 best-effort（盘上 marker 已权威耐久）。
  defp commit_delete_marker_sidecar(bucket, key, version_id) do
    with {:ok, placement} <- Placement.resolve_write(bucket, key),
         :ok <-
           Storage.put_delete_marker(
             bucket,
             key,
             version_id,
             [],
             Placement.storage_opts(placement)
           ) do
      placement_attrs = Placement.attrs_from_result(placement)

      case Objects.insert_delete_marker_index(bucket, key, version_id, placement_attrs) do
        :ok ->
          :ok

        {:error, reason} ->
          Log.error("pg delete-marker index update failed (marker durably stored in sidecars)",
            action: :delete_object,
            bucket: bucket,
            key: key,
            reason: inspect(reason)
          )

          :ok
      end
    end
  end

  # :pg（默认）写权威：PG upsert 先行且致命（失败时盘上分毫未动，无撕裂；{:ok,_} 匹配失败上抛
  # → dispatch 兜底 500）。权威提交成功后才做 Suspended null 字节清理 + 盘上 marker 镜像，
  # 均 best-effort：后端 marker 写失败（FS 单盘 IO 错 / 纠删 quorum 不足，B6-1 起 FS 也实落
  # marker sidecar）不影响已权威提交的删除（盘上残留对 PG 读/列权威不可见），绝不让 :pg 路径因盘失败而失败。
  defp commit_delete_marker_pg(bucket, key, version_id, versioning) do
    old_null_opts = storage_opts_for_version(bucket, key, "null")

    with {:ok, placement} <- Placement.resolve_write(bucket, key) do
      placement_storage_opts = Placement.storage_opts(placement)
      placement_attrs = Placement.attrs_from_result(placement)

      {:ok, _} = Objects.insert_delete_marker_with_id(bucket, key, version_id, placement_attrs)

      # Suspended：null marker 替换既有 null 版本 → 清理被替换的 null 版本字节 + sidecar。
      if versioning == "Suspended", do: _ = Storage.delete(bucket, key, "null", old_null_opts)
      _ = Storage.put_delete_marker(bucket, key, version_id, [], placement_storage_opts)
      :ok
    end
  end

  # ROUTE B B4-2 —— 元数据提交按写权威分流（authoritative_source(:write)）：
  #
  #   :pg（默认）→ 维持 B1-1 致命语义：put_version_with_id 失败则 {:error, cs} 由 Repo.rollback
  #     冒泡成异常（此处 {:ok, obj} 模式匹配失败 -> MatchError），被上层 try/rescue 捕获 -> 回滚字节 +
  #     reraise（对象绝不留孤儿、绝不静默接受落库失败，铁律 3）。
  #
  #   :sidecar → sidecar 已达 write_quorum = 字节 + sidecar 权威已耐久落盘；PG 仅派生索引，用
  #     put_version_index best-effort：失败 -> Log.error（绝不静默，铁律 3）+ **不回滚字节、不失败请求**
  #     （对象耐久存于 sidecar，PG 索引滞后由后续 scanner reconcile）；响应视图由 version_id + 已知 attrs
  #     在内存构造（build_put_view，不依赖 PG 读回，去 PG 写/读回路径 SPOF）。
  #
  # ROUTE B B5-1：CopyObject 也收敛到本分流单点（铁律 2），action 参数仅供结构化日志归因
  # （:put_object / :copy_object），两路语义逐字一致。
  defp commit_metadata(bucket, key, version_id, attrs, action \\ :put_object) do
    case Maxio.ObjectMeta.authoritative_source(:write) do
      :sidecar ->
        case Objects.put_version_index(bucket, key, version_id, attrs) do
          :ok ->
            :ok

          {:error, reason} ->
            Log.error("pg index update failed (object durably stored in sidecars)",
              action: action,
              bucket: bucket,
              key: key,
              reason: inspect(reason)
            )
        end

        build_put_view(bucket, key, version_id, attrs)

      _pg ->
        {:ok, obj} = Objects.put_version_with_id(bucket, key, version_id, attrs)
        obj
    end
  end

  # ROUTE B B4-2 —— :write=:sidecar 时的响应视图（不依赖 PG 读回）：从已写入的 version_id +
  # 已知 attrs 在内存构造一个 %Objects.Object{}（与 :pg 分支返回的结构同型，下游响应管线只读
  # .version_id/.etag/.size 等字段，故无需 PG 行）。updated_at 用当前时刻（响应头 last-modified
  # 由 GET/HEAD 另取，此处 PUT 仅需 version_id/etag）。
  defp build_put_view(bucket, key, version_id, attrs) do
    %Objects.Object{
      bucket_name: bucket,
      key: key,
      version_id: version_id,
      size: Map.fetch!(attrs, :size),
      etag: Map.fetch!(attrs, :etag),
      content_type: Map.get(attrs, :content_type, "binary/octet-stream"),
      content_encoding: Map.get(attrs, :content_encoding),
      content_disposition: Map.get(attrs, :content_disposition),
      cache_control: Map.get(attrs, :cache_control),
      expires: Map.get(attrs, :expires),
      storage_class: Map.get(attrs, :storage_class, "STANDARD"),
      acl_canned: Map.get(attrs, :acl_canned, "private"),
      acl_grants: Map.get(attrs, :acl_grants, ACL.empty_grants_doc()),
      # B5-1：user metadata 随视图携带（PutObject/CopyObject attrs 均含 :metadata），与 :pg 分支
      # 返回的 PG 行同构（视图字段越全，下游对两权威分支的读取越不分裂）。
      metadata: Map.get(attrs, :metadata, %{}),
      tags: Map.get(attrs, :tags, %{}),
      sse_algorithm: Map.get(attrs, :sse_algorithm),
      sse_envelope: Map.get(attrs, :sse_envelope),
      placement_set_id: Map.get(attrs, :placement_set_id),
      placement_pool_id: Map.get(attrs, :placement_pool_id),
      placement_topology_hash: Map.get(attrs, :placement_topology_hash),
      is_latest: true,
      is_delete_marker: false,
      updated_at: DateTime.utc_now()
    }
  end

  # FX-M4：计算 CopyObject 目标的用户 metadata（x-amz-meta-*）：
  #   COPY（默认）→ 原样保留源对象的 metadata（src_obj.metadata，nil 兜底 %{}）；
  #   REPLACE     → 用请求头 x-amz-meta-* 解析的新 metadata（不继承源；无头 → %{}）。
  defp copy_user_metadata(conn, _src_obj, "REPLACE"), do: parse_user_metadata(conn)
  defp copy_user_metadata(_conn, src_obj, _copy), do: src_obj.metadata || %{}

  defp copy_system_headers(conn, _src_obj, "REPLACE"),
    do: SystemHeaders.from_req_headers(conn.req_headers)

  defp copy_system_headers(_conn, src_obj, _directive), do: SystemHeaders.from_object(src_obj)

  defp parse_copy_directive!(conn, header_name) do
    case header(conn, header_name) do
      nil ->
        "COPY"

      value ->
        value = value |> String.trim() |> String.upcase()

        if value in ["COPY", "REPLACE"] do
          value
        else
          raise Error.new(:invalid_argument,
                  message: "#{header_name} must be COPY or REPLACE"
                )
        end
    end
  end

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

          %{
            canned: ACL.classify_grants(grants),
            grants_doc: ACL.grants_doc(grants)
          }
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

  # ROUTE B B4-5：组装透传给 Storage.put 的 object_meta（让后端写出完整 maxio/2 sidecar）。
  # 各字段均来自 do_put/copy 已就绪的计算值（content_type/tags/acl/storage_class/sse），加
  # 用户 metadata（x-amz-meta-* / x-minio-meta-*，PutObject 现注入 sidecar 使其自描述完整）。sse 形状须匹配
  # Sidecar.to_view 读 e["sse"]["algo"] / e["sse"]["envelope"]（信封随读视图携带，绝不丢）。
  defp build_object_meta(
         content_type,
         system_headers,
         storage_class,
         tags_map,
         sse_requested,
         sse_envelope,
         user_metadata,
         visible_size,
         acl_input
       ) do
    %{
      size: visible_size,
      content_type: content_type,
      content_encoding: Map.get(system_headers, :content_encoding),
      content_disposition: Map.get(system_headers, :content_disposition),
      cache_control: Map.get(system_headers, :cache_control),
      expires: Map.get(system_headers, :expires),
      tags: tags_map,
      acl_canned: acl_input.canned,
      acl_grants: acl_input.grants_doc,
      storage_class: storage_class,
      sse: sse_meta(sse_requested, sse_envelope),
      user_metadata: user_metadata
    }
  end

  # sse 字段：未加密 → nil；SSE-S3 → %{"algo" => "AES256", "envelope" => 信封}（信封含 wrapped DEK）。
  defp sse_meta(nil, _envelope), do: nil
  defp sse_meta(algo, envelope), do: %{"algo" => algo, "envelope" => envelope}

  # 用户 metadata 头 → %{"name" => "value"}：复用 Maxio.Metadata 的单一解析器
  # （PutObject / CopyObject(REPLACE) / CreateMultipartUpload 同源，铁律 2）。
  defp parse_user_metadata(conn), do: Maxio.Metadata.parse_headers(conn.req_headers)

  # 条件头求值用的对象元信息（etag 无引号 hex；last_modified 用 updated_at）。
  defp meta(object), do: %{etag: object.etag, last_modified: object.updated_at}

  # x-amz-copy-source 解析："/srcBucket/srcKey[?versionId=v]" | "srcBucket/srcKey[?versionId=v]"
  # （URL 编码）。返回 {bucket, key, version_id | nil}：默认标识源的当前版本，?versionId= 选特定版本
  # （对齐 AWS CopyObject，铁律 5）。
  defp parse_copy_source!(raw) do
    %{bucket: bucket, key: key, version_id: version_id} = CopySource.parse!(raw)
    {bucket, key, version_id}
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

  defp counted_stream(stream) do
    counter = :counters.new(1, [])

    counted =
      Stream.map(stream, fn chunk ->
        :counters.add(counter, 1, IO.iodata_length(chunk))
        chunk
      end)

    {counted, fn -> :counters.get(counter, 1) end}
  end

  defp discard_upload_body_state(discard_checksum, discard_trailers) do
    discard_checksum.()
    discard_trailers.()
  end

  defp send_authenticated_sse_object!(conn, object, total, range, raw_stream, plain_slice) do
    expected_length = expected_plain_length(range, total)
    path = stage_sse_plain_file!(raw_stream, object.sse_envelope, plain_slice, expected_length)

    try do
      plain_stream =
        File.stream!(path, Maxio.Crypto.SSE.plaintext_block_size(), [:read, :binary])

      conn
      |> maybe_put_version_id(object.version_id)
      |> SSE.put_response_header(object.sse_algorithm)
      |> send_object(object, total, range, plain_stream)
    after
      _ = File.rm(path)
    end
  end

  defp stage_sse_plain_file!(raw_stream, envelope, plain_slice, expected_length) do
    path = sse_plain_temp_path()
    counter = :counters.new(1, [])

    try do
      File.open!(path, [:write, :binary], fn io ->
        raw_stream
        |> Maxio.Crypto.SSE.unwrap_stream(envelope)
        |> slice_plain_stream(plain_slice)
        |> Enum.each(fn chunk ->
          :counters.add(counter, 1, IO.iodata_length(chunk))
          IO.binwrite(io, chunk)
        end)
      end)

      if :counters.get(counter, 1) == expected_length do
        path
      else
        raise "SSE-S3 decryption failed: missing plaintext bytes"
      end
    rescue
      err in Error ->
        _ = File.rm(path)
        reraise(err, __STACKTRACE__)

      err ->
        _ = File.rm(path)

        Log.warn("sse object authentication failed before response",
          action: :get_object,
          reason: Exception.message(err)
        )

        raise Error.new(:internal_error)
    end
  end

  defp sse_plain_temp_path do
    name = "maxio_sse_get_#{System.unique_integer([:monotonic, :positive])}.bin"
    Path.join(System.tmp_dir!(), name)
  end

  defp expected_plain_length(range, total) when range in [nil, :full], do: total
  defp expected_plain_length({first, last}, _total), do: last - first + 1

  defp slice_plain_stream(stream, nil), do: stream
  defp slice_plain_stream(stream, :full), do: stream

  defp slice_plain_stream(stream, {first, last}) do
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

  defp sse_ranges(nil, _total), do: {nil, nil}
  defp sse_ranges(:full, _total), do: {nil, :full}

  defp sse_ranges({first, last}, total) do
    block_size = Maxio.Crypto.SSE.plaintext_block_size()
    frame_header_size = Maxio.Crypto.SSE.frame_header_size()
    full_frame_size = frame_header_size + block_size
    first_frame = div(first, block_size)
    last_frame = div(last, block_size)

    cipher_first = first_frame * full_frame_size
    last_frame_plain_size = min(block_size, total - last_frame * block_size)
    cipher_last = last_frame * full_frame_size + frame_header_size + last_frame_plain_size - 1

    plain_first = rem(first, block_size)
    plain_last = plain_first + last - first

    {{cipher_first, cipher_last}, {plain_first, plain_last}}
  end

  defp put_common_object_headers(conn, object, content_length) do
    conn
    |> put_resp_header("content-type", object.content_type)
    |> put_resp_header("etag", XML.quote_etag(object.etag))
    |> put_resp_header("last-modified", http_date(object.updated_at))
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("content-length", Integer.to_string(content_length))
    |> maybe_put_storage_class(object)
    |> SystemHeaders.put_response_headers(object)
    |> put_user_metadata_headers(object)
    |> maybe_tagging_count(object)
  end

  defp maybe_put_storage_class(conn, %{storage_class: storage_class})
       when is_binary(storage_class) and storage_class not in ["", "STANDARD"] do
    put_resp_header(conn, "x-amz-storage-class", storage_class)
  end

  defp maybe_put_storage_class(conn, _object), do: conn

  # ROUTE B B4-6 fidelity：把对象持久化的用户元数据原样回显为 x-amz-meta-<name> 响应头
  # （name 已去前缀、小写），闭合 PutObject/CopyObject/MPU 写入 → GET/HEAD 读回的 round-trip。
  # AWS S3/MinIO 在 GET 与 HEAD 都返回全部 user-defined metadata 为 x-amz-meta-* 头
  # （HeadObject 是检索对象元数据的标准方式）；否则真实 SDK 读不回已存元数据（铁律 3：写了必可读）。
  # 此 helper 同时被 GET（send_object/put_common_object_headers）与 HEAD（put_common_object_headers）
  # 复用；SSE GET 分支单独走 put_resp_header 管线，故那里也显式调用本 helper（见 get/1 AES256 分支）。
  defp put_user_metadata_headers(conn, %{metadata: metadata}) when is_map(metadata) do
    Enum.reduce(metadata, conn, fn {name, value}, acc ->
      put_resp_header(acc, "x-amz-meta-" <> to_string(name), to_string(value))
    end)
  end

  defp put_user_metadata_headers(conn, _object), do: conn

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
          {n, ""} when n > 0 and total > 0 -> {max(total - n, 0), total - 1}
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

  # 对象 key 入口守卫（PUT/GET/HEAD/DELETE/Copy 源与目标统一；multipart 门由
  # Handlers.Multipart.create_multipart_upload 同构守卫，保证「可建即可达」）：仅拒
  # MinIO/AWS 都拒的形态——空 key / `.` `..` 点段 → 400 XMinioInvalidObjectName（对齐 MinIO
  # ErrInvalidObjectName）；原始 key 超 1024 字节 → 400 KeyTooLongError（对齐 MinIO
  # ErrKeyTooLongError / AWS 同 Code，B5-4），均在任何查找/写入之前校验。布局保留名段
  # （meta.json/part.0/...）是 MinIO/AWS 均接受的普通 key，**不**在 API 层拒绝——盘上碰撞由
  # Paths.encode_key 段编码结构化消除。单一事实来源 = Maxio.Cluster.Paths.validate_key/1，
  # handler 仅做错误映射（铁律 2）。
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

  # B5-4 —— 客户端 ?versionId 入口守卫（GET/HEAD/DELETE/Copy 源/tagging 统一）：
  # 单一事实来源 = Maxio.Versioning.VersionId.valid?/1（"null" 或 26 位 Crockford ULID）。
  # 非法（`..`/`../x` 路径段/任意畸形）→ 400 InvalidArgument "Invalid version id specified"
  # （对齐 AWS/MinIO ErrInvalidVersionID，cmd/api-errors.go 描述逐字），在任何查找/盘路径构造
  # 之前拦截——客户端 versionId 曾不经校验直进 Paths.object_rel 盘路径（路径穿越面，铁律 3
  # 结构化拒绝绝不静默）。合法形状但查无此版本仍走既有 404 语义不变。
  # nil（未带参数 / B6-2a：空串经 VersionId.normalize_param 归一化）→ 当前版本语义，放行。
  # DeleteObjects per-key 畸形 versionId 不走本函数（B6-2a：MinIO 对批量删除用 per-key
  # NoSuchVersion <Error> 条目，见 do_delete_one）。
  defp validate_version_id(nil), do: :ok

  defp validate_version_id(version_id) do
    if Maxio.Versioning.VersionId.valid?(version_id),
      do: :ok,
      else: {:error, :invalid_version_id}
  end

  defp validate_version_id!(bucket, key, version_id) do
    case validate_version_id(version_id) do
      :ok ->
        :ok

      {:error, :invalid_version_id} ->
        raise Error.new(:invalid_argument,
                message: "Invalid version id specified",
                resource: "/#{bucket}/#{key}"
              )
    end
  end

  # version_id == nil → 取当前版本（latest）；否则取指定版本行。缺失 → NoSuchKey。
  # src_obj.version_id 即源真实字节所在版本路径（版本化源为 ULID，未版本化源为 "null"）。
  defp object_or_raise(bucket, key, version_id) do
    _ = ensure_bucket!(bucket)

    case Maxio.ObjectMeta.get(bucket, key, version_id, []) do
      %Objects.Object{} = object ->
        {object, object.size}

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      {:error, :read_quorum} ->
        Log.warn("copy source unavailable: sidecar read_quorum unmet",
          action: :copy_object,
          bucket: bucket,
          key: key,
          reason: :read_quorum
        )

        raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")
    end
  end

  # version_id == nil → 取当前版本（latest）；否则取指定版本行。经 ObjectMeta.get 统一读权威分流：
  #   %Object{} → {object, object.size}；
  #   {:error,:not_found} → NoSuchKey 404（既有语义）；
  #   {:error,:read_quorum}（仅 :read=:sidecar 时可达）→ 503 SlowDownRead（绝不返回猜测副本，铁律 3）。
  #     对齐 MinIO：errErasureReadQuorum -> ErrSlowDownRead（cmd/api-errors.go），与 PUT 写 quorum
  #     的 :slow_down_write 对称；绝不用 AWS 泛化的 ServiceUnavailable（MinIO 从不产此 Code）。
  defp resolve_object_for_get!(bucket, key, version_id) do
    case Maxio.ObjectMeta.get(bucket, key, version_id, []) do
      %Objects.Object{} = object ->
        {object, object.size}

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      {:error, :read_quorum} ->
        Log.warn("object read unavailable: sidecar read_quorum unmet",
          action: :get_object,
          bucket: bucket,
          key: key,
          reason: :read_quorum
        )

        raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")
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

  # 源是版本化对象（version_id != "null"）时回 x-amz-copy-source-version-id；
  # 未版本化源（"null"）不回显（对齐 AWS CopyObject 响应，铁律 5）。
  defp maybe_put_copy_source_version_id(conn, "null"), do: conn

  defp maybe_put_copy_source_version_id(conn, version_id),
    do: put_resp_header(conn, "x-amz-copy-source-version-id", version_id)

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
