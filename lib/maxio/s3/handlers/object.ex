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

    # ROUTE B B4-6 D2/D3：用户元数据（x-amz-meta-*）解析一次，喂两路（sidecar object_meta + PG attrs），
    # 消除 :pg/:sidecar 读分裂（D3）。写任何字节/sidecar 之前先做 2 KB 大小闸（D2）——超限 →
    # MetadataTooLarge 400、失败 pre-commit、无孤儿（铁律 3，与 parse_tagging_header!/resolve_sse! 并列）。
    user_metadata = parse_user_metadata(conn)
    :ok = Maxio.Metadata.validate_size!(user_metadata)

    {chunks, sse_envelope} =
      case sse_requested do
        "AES256" -> Maxio.Crypto.SSE.wrap_stream(chunks)
        nil -> {chunks, nil}
      end

    # ROUTE B B4-5：把已算出的富 S3 元数据组成 object_meta，透传进 Storage.put，使纠删/分布式后端
    # 写出完整 maxio/2 sidecar（盘上即事实来源，read/list=:sidecar 下对真实对象可读/可列）。
    # PutObject 当前未捕获 x-amz-meta-*，此处用既有 parse_user_metadata/1 解析并入 sidecar（自描述完整）；
    # PG 索引侧 attrs 保持不变（:pg 默认路径字节级可回滚，user_metadata 仅注入 sidecar）。
    object_meta =
      build_object_meta(conn, content_type, tags_map, sse_requested, sse_envelope, user_metadata)

    # B1-1：把整个提交 seam（字节经 Storage.put + 元数据经 Objects.put_version_with_id）纳入
    # 同一对象锁，消灭并发同 key 写的「A 字节 + B 元数据」交错（静默 ETag/bytes 分歧）。
    # version_id/SSE/tags 等纯计算/读保持锁外；获锁失败 -> {:error,:locked} -> 503 SlowDown（铁律 3）。
    commit_result =
      Maxio.Lock.with_object_lock({bucket, key}, fn ->
        case Storage.put(bucket, key, version_id, chunks, object_meta: object_meta) do
          {:ok, %{size: size, etag: etag, sha256: sha256}} ->
            # 校验/落库失败 → 先清理已写字节再抛（绝不留孤儿，铁律 3）。
            # SSE 加密对象：x-amz-decoded-content-length / x-amz-content-sha256 是针对明文传输完整性的闸，
            # 而落盘字节是密文（密文≠明文必失配）；传输层完整性已由 SigV4/chunked 在 BodyReader 内验过，
            # 故加密分支跳过这两个校验（铁律 3 仍由 GCM 认证 + 上游签名保证）。
            #
            # 传输完整性（decoded-length / content-sha256）失败在两条权威分支下都**致命 + 回滚孤儿**
            # （这是 digest/签名失配，与 PG 无关，铁律 3 绝不静默接受）；仅 PG 索引写在
            # authoritative_source(:write)==:sidecar 时降为 best-effort（见下）。
            obj =
              try do
                unless sse_requested do
                  :ok = verify_decoded_length!(conn, payload_mode, size)
                  :ok = verify_content_sha256!(conn, payload_mode, sha256)
                end

                attrs = %{
                  size: size,
                  etag: etag,
                  content_type: content_type,
                  storage_class: "STANDARD",
                  acl_canned: header(conn, "x-amz-acl") || "private",
                  # ROUTE B B4-6 D3：user metadata 也写入 PG 索引（键 :metadata，与 CopyObject 的
                  # metadata: meta_map 对齐），消除 :pg(默认) 与 :sidecar 两路读 user metadata 的分裂。
                  metadata: user_metadata,
                  tags: tags_map,
                  sse_algorithm: sse_requested,
                  sse_envelope: sse_envelope
                }

                commit_metadata(bucket, key, version_id, attrs)
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

            {:ok, {size, etag, obj}}

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case commit_result do
      {:ok, {:ok, {size, etag, obj}}} ->
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

      {:ok, {:error, :invalid_key}} ->
        raise Error.new(:invalid_argument, resource: "/#{bucket}/#{key}", message: "Invalid key")

      # 写 quorum 不足 / 原子 rename 争用 = 瞬时写限流，对齐 MinIO 的 SlowDownWrite(503)
      # （cmd/api-errors.go: errErasureWriteQuorum -> ErrSlowDownWrite）。SDK 据此指数退避重试，
      # 集群降级/争用得以自愈；绝不能映射成 500 InternalError（被客户端当硬失败）。
      {:ok, {:error, reason}} when reason in [:write_quorum, :rename_busy] ->
        raise Error.new(:slow_down_write, resource: "/#{bucket}/#{key}")

      {:ok, {:error, reason}} ->
        raise Error.new(:internal_error, message: inspect(reason))

      {:error, :locked} ->
        raise Error.new(:slow_down, resource: "/#{bucket}/#{key}")
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    _ = ensure_bucket!(bucket)

    version_id = Map.get(conn.query_params, "versionId")
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
                |> put_user_metadata_headers(object)
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

    # ROUTE B：经 Maxio.ObjectMeta.get 取对象（读权威单一入口；:pg 默认含内部 shadow，行为不变）。
    # HEAD 无 body：缺失/read_quorum 不足都只回状态 + 头（read_quorum 不足 → 503，对齐 GET SlowDownRead）。
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
        # 避免与并发同 key PUT 的提交 seam 交错（获锁失败 -> 503 SlowDown，铁律 3）。
        case Maxio.Lock.with_object_lock({bucket, key}, fn ->
               :ok = Objects.delete_metadata(bucket, key)
               _ = Storage.delete(bucket, key)
               :ok
             end) do
          {:ok, :ok} ->
            Log.info("delete object", action: :delete_object, bucket: bucket, key: key)
            send_resp(conn, 204, "")

          {:error, :locked} ->
            raise Error.new(:slow_down, resource: "/#{bucket}/#{key}")
        end
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

    # 逐 key 对象级授权（铁律 2：复用 Authz 单一授权路径，仅资源 ARN 改成每个 key 的对象 ARN）。
    # 无权 key 回 per-key <Error>AccessDenied</Error>（HTTP 200 混合结果）且绝不删；有权 key 才删。
    principal = conn.assigns[:principal]
    authenticated? = principal != :anonymous
    conditions = Maxio.S3.Authz.conditions_for(conn, authenticated?)
    owner? = Maxio.S3.Authz.owner?(principal, bucket)

    {deleted, errors} =
      Enum.reduce(objects, {[], []}, fn obj, {dacc, eacc} ->
        if delete_authorized?(bucket, obj.key, principal, authenticated?, owner?, conditions) do
          case delete_one(bucket, obj, versioning) do
            {:ok, entry} -> {[entry | dacc], eacc}
            {:error, err} -> {dacc, [err | eacc]}
          end
        else
          err = %{key: obj.key, code: "AccessDenied", message: "Access Denied"}
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
        # 无 VersionId 且版本化桶 → 插 delete marker（绝不硬删历史版本）。ROUTE B B5-0：与单删
        # delete/1 同路径——先盘上落 delete-marker sidecar（quorum 致命），再 PG 索引（best-effort）。
        dm_vid = commit_delete_marker(bucket, key, versioning)
        {:ok, %{key: key, delete_marker: true, delete_marker_version_id: dm_vid}}

      true ->
        # 未版本化桶 → 硬删（删 null 行 + 字节）。缺失 key 也算成功（S3 语义）。
        :ok = Objects.delete_metadata(bucket, key)
        _ = Storage.delete(bucket, key)
        {:ok, %{key: key}}
    end
  end

  # 单 key 是否被授权删除：owner/root 短路放行；否则对该 key 的对象 ARN 跑 Evaluator（s3:DeleteObject）。
  # 复用 Maxio.S3.Authz 暴露的同源零件（conditions/object_statements/Evaluator），绝不另起授权逻辑。
  defp delete_authorized?(_bucket, _key, _principal, _authenticated?, true, _conditions), do: true

  defp delete_authorized?(bucket, key, principal, authenticated?, _owner?, conditions) do
    resource = Maxio.Policy.Arn.object_arn(bucket, key)
    statements = Maxio.S3.Authz.object_statements(bucket, key, principal)

    ctx = %Maxio.Policy.RequestContext{
      principal: principal,
      authenticated?: authenticated?,
      owner?: false,
      action: "s3:DeleteObject",
      resource: resource,
      conditions: conditions
    }

    case Maxio.Policy.Evaluator.evaluate(ctx, statements) do
      :allow -> true
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

    {src_bucket, src_key, src_version_id} =
      parse_copy_source!(header(conn, "x-amz-copy-source"))

    # 源对象按真实版本解析（默认 current/latest，?versionId= 选特定版本）。
    {src_obj, _total} = object_or_raise(src_bucket, src_key, src_version_id)

    # 源当前版本是 delete marker（src_version_id == nil 即取 latest）→ 对齐 AWS/MinIO：
    # 「If the current version is a delete marker, Amazon S3 behaves as if the object was deleted」
    # → 404 NoSuchKey（铁律 3：已知条件绝不静默 500）。get_metadata 会返回 delete-marker 行
    # （objects.ex 文档），copy 必须像 GET 处理器一样显式判 is_delete_marker，否则后续读不到字节会崩成 500。
    if src_version_id == nil and src_obj.is_delete_marker do
      raise Error.new(:no_such_key, resource: "/#{src_bucket}/#{src_key}")
    end

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
    tagging_directive = header(conn, "x-amz-tagging-directive") || "COPY"

    tags =
      case tagging_directive do
        "REPLACE" -> parse_tagging_header!(conn)
        _ -> src_obj.tags || %{}
      end

    # 拷贝字节（铁律 4 不全缓冲）。自拷贝（src==dest，此处必为 REPLACE）必须避免
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
        src_obj.version_id,
        dest_bucket,
        dest_key
      )

    # ROUTE B B4-5：CopyObject 同样透传 object_meta（content_type/tags/user_metadata 已按
    # metadata/tagging-directive 解析），使复制对象也写出完整 maxio/2 sidecar。CopyObject MVP 不做
    # SSE（sse: nil）；acl/storage_class 用默认（与 :pg 分支 put_version_with_id 的 STANDARD 一致）。
    dest_object_meta = %{
      content_type: content_type,
      tags: tags,
      acl_canned: "private",
      storage_class: "STANDARD",
      sse: nil,
      user_metadata: meta_map
    }

    commit_result =
      Maxio.Lock.with_object_lock({dest_bucket, dest_key}, fn ->
        {size, etag} =
          case Storage.put(dest_bucket, dest_key, dest_version_id, src_stream.stream,
                 object_meta: dest_object_meta
               ) do
            {:ok, %{size: size, etag: etag}} -> {size, etag}
            {:error, reason} -> raise Error.new(:internal_error, message: inspect(reason))
          end

        {:ok, obj} =
          Objects.put_version_with_id(dest_bucket, dest_key, dest_version_id, %{
            size: size,
            etag: etag,
            content_type: content_type,
            storage_class: "STANDARD",
            metadata: meta_map,
            tags: tags
          })

        {size, etag, obj}
      end)

    # 自拷贝的临时 key 在锁外清理（与目标 key 无关，绝不放锁内拖长持锁时间）。
    cleanup_copy_source(src_stream)

    {_size, etag, obj} =
      case commit_result do
        {:ok, committed} -> committed
        {:error, :locked} -> raise Error.new(:slow_down, resource: "/#{dest_bucket}/#{dest_key}")
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
    |> send_resp(200, body)
  end

  # 非自拷贝：直接返回源对象「真实版本」流（锁外打开，目标写时消费）。
  # src_version_id 为源对象的真实版本路径（版本化源 ULID、未版本化源 "null"），绝不再硬编码 "null"
  # （否则版本化源读不到字节 → 静默产生空目标，铁律 5）。:tmp_key=nil 表示无临时副本需清理。
  defp prepare_copy_source(false, src_bucket, src_key, src_version_id, _dest_bucket, _dest_key) do
    {:ok, src_stream} = Storage.get(src_bucket, src_key, src_version_id, nil)
    %{stream: src_stream, dest_bucket: nil, tmp_key: nil}
  end

  # 自拷贝（src==dest）：锁外先把源「真实版本」流式写到唯一临时 key（避免目标写截断源），
  # 返回临时流供目标写消费。
  defp prepare_copy_source(true, src_bucket, src_key, src_version_id, dest_bucket, dest_key) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    tmp_key = dest_key <> ".maxio-copytmp-" <> suffix
    {:ok, src_stream} = Storage.get(src_bucket, src_key, src_version_id, nil)

    case Storage.put(dest_bucket, tmp_key, "null", src_stream) do
      {:ok, _tmp} ->
        {:ok, tmp_stream} = Storage.get(dest_bucket, tmp_key, "null", nil)
        %{stream: tmp_stream, dest_bucket: dest_bucket, tmp_key: tmp_key}

      {:error, reason} ->
        raise Error.new(:internal_error, message: inspect(reason))
    end
  end

  # 清理自拷贝的临时副本（非自拷贝 tmp_key=nil，无操作）。
  defp cleanup_copy_source(%{tmp_key: nil}), do: :ok

  defp cleanup_copy_source(%{dest_bucket: dest_bucket, tmp_key: tmp_key}) do
    _ = Storage.delete(dest_bucket, tmp_key, "null")
    :ok
  end

  # ── helpers ──

  # ROUTE B B5-0 —— delete marker 提交（DELETE 无 versionId，桶 Enabled/Suspended）。
  #
  # 根因：`insert_delete_marker` 纯 PG、盘上从不落 delete-marker sidecar →
  # `authoritative_source(:read|:list)=:sidecar` 下 DeleteObject 后盘上旧对象 sidecar 仍在
  # → GET 仍 200、LIST 仍列出 = **已删对象复活**（critical）。修法：删除是写操作，必须被盘上权威记录。
  #
  # 对象锁内（B1-1：盘 + PG 同锁，与 do_put 一致顺序——盘先 PG 后），**先**盘上 `Storage.put_delete_marker`
  # **再** PG 索引：
  #   * `authoritative_source(:write)==:sidecar` → 盘上 marker sidecar 达 write_quorum = 删除已耐久权威；
  #     quorum 不足 → {:error,:write_quorum} → 503 SlowDownWrite（绝不静默）。PG 索引降 best-effort
  #     （insert_delete_marker_index 失败 Log.error 不致命，scanner 后续 reconcile）。
  #   * `:pg`（默认）→ 维持现状：PG insert_delete_marker_with_id 致命（PG 即权威）；盘上 marker 为
  #     best-effort（FS 后端返回 :not_supported，纠删/分布式后端有则锦上添花，无正确性依赖）。
  #
  # Suspended 桶：null delete marker **替换**既有 null 版本（AWS 语义）——先删 null 版本字节 + sidecar
  # 再写 marker sidecar 到 null 路径（PG 侧 upsert 的 Suspended 语义已有）。
  #
  # 返回 delete marker 的 version_id；获锁失败 → 503 SlowDown，盘 quorum 不足 → 503 SlowDownWrite（铁律 3）。
  defp commit_delete_marker(bucket, key, versioning) do
    version_id =
      if versioning == "Enabled", do: Maxio.Versioning.VersionId.generate(), else: "null"

    result =
      Maxio.Lock.with_object_lock({bucket, key}, fn ->
        # Suspended：null marker 替换既有 null 版本 → 先删 null 版本字节 + sidecar（绝不与新 marker 共存）。
        if versioning == "Suspended", do: Storage.delete(bucket, key, "null")

        with :ok <- write_disk_delete_marker(bucket, key, version_id) do
          commit_delete_marker_index(bucket, key, version_id)
          :ok
        end
      end)

    case result do
      {:ok, :ok} ->
        version_id

      {:ok, {:error, reason}} when reason in [:write_quorum, :rename_busy] ->
        raise Error.new(:slow_down_write, resource: "/#{bucket}/#{key}")

      {:ok, {:error, reason}} ->
        raise Error.new(:internal_error, message: inspect(reason))

      {:error, :locked} ->
        raise Error.new(:slow_down, resource: "/#{bucket}/#{key}")
    end
  end

  # 盘上落 delete-marker sidecar。按写权威分流：
  #   :sidecar → 盘上 marker 是权威，quorum 致命（{:error,reason} 上抛 → 503 SlowDownWrite）。
  #   :pg（默认）→ 盘上 marker best-effort：FS :not_supported / 后端写失败均忽略（PG 才是权威），
  #     成功则锦上添花（让纠删/分布式后端盘上与 PG 一致）。返回 :ok（绝不让 :pg 路径因盘失败而失败）。
  defp write_disk_delete_marker(bucket, key, version_id) do
    case Maxio.ObjectMeta.authoritative_source(:write) do
      :sidecar ->
        Storage.put_delete_marker(bucket, key, version_id)

      _pg ->
        _ = Storage.put_delete_marker(bucket, key, version_id)
        :ok
    end
  end

  # PG delete-marker 索引提交，按写权威分流（镜像 commit_metadata/4）：
  #   :sidecar → best-effort（盘上 marker 已权威）：失败 Log.error 不致命（铁律 3 绝不静默）。
  #   :pg（默认）→ 致命（PG 即权威）：insert_delete_marker_with_id 失败由内部 {:ok,_} 匹配失败上抛。
  defp commit_delete_marker_index(bucket, key, version_id) do
    case Maxio.ObjectMeta.authoritative_source(:write) do
      :sidecar ->
        case Objects.insert_delete_marker_index(bucket, key, version_id) do
          :ok ->
            :ok

          {:error, reason} ->
            Log.error("pg delete-marker index update failed (marker durably stored in sidecars)",
              action: :delete_object,
              bucket: bucket,
              key: key,
              reason: inspect(reason)
            )
        end

      _pg ->
        {:ok, _} = Objects.insert_delete_marker_with_id(bucket, key, version_id)
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
  defp commit_metadata(bucket, key, version_id, attrs) do
    case Maxio.ObjectMeta.authoritative_source(:write) do
      :sidecar ->
        case Objects.put_version_index(bucket, key, version_id, attrs) do
          :ok ->
            :ok

          {:error, reason} ->
            Log.error("pg index update failed (object durably stored in sidecars)",
              action: :put_object,
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
      storage_class: Map.get(attrs, :storage_class, "STANDARD"),
      acl_canned: Map.get(attrs, :acl_canned, "private"),
      tags: Map.get(attrs, :tags, %{}),
      sse_algorithm: Map.get(attrs, :sse_algorithm),
      sse_envelope: Map.get(attrs, :sse_envelope),
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

  # ROUTE B B4-5：组装透传给 Storage.put 的 object_meta（让后端写出完整 maxio/2 sidecar）。
  # 各字段均来自 do_put/copy 已就绪的计算值（content_type/tags/acl/storage_class/sse），加
  # 用户 metadata（x-amz-meta-*，PutObject 现注入 sidecar 使其自描述完整）。sse 形状须匹配
  # Sidecar.to_view 读 e["sse"]["algo"] / e["sse"]["envelope"]（信封随读视图携带，绝不丢）。
  defp build_object_meta(conn, content_type, tags_map, sse_requested, sse_envelope, user_metadata) do
    %{
      content_type: content_type,
      tags: tags_map,
      acl_canned: header(conn, "x-amz-acl") || "private",
      storage_class: "STANDARD",
      sse: sse_meta(sse_requested, sse_envelope),
      user_metadata: user_metadata
    }
  end

  # sse 字段：未加密 → nil；SSE-S3 → %{"algo" => "AES256", "envelope" => 信封}（信封含 wrapped DEK）。
  defp sse_meta(nil, _envelope), do: nil
  defp sse_meta(algo, envelope), do: %{"algo" => algo, "envelope" => envelope}

  # x-amz-meta-* 头 → %{"name" => "value"}：复用 Maxio.Metadata 的单一解析器
  # （PutObject / CopyObject(REPLACE) / CreateMultipartUpload 同源，铁律 2）。
  defp parse_user_metadata(conn), do: Maxio.Metadata.parse_headers(conn.req_headers)

  # 条件头求值用的对象元信息（etag 无引号 hex；last_modified 用 updated_at）。
  defp meta(object), do: %{etag: object.etag, last_modified: object.updated_at}

  # x-amz-copy-source 解析："/srcBucket/srcKey[?versionId=v]" | "srcBucket/srcKey[?versionId=v]"
  # （URL 编码）。返回 {bucket, key, version_id | nil}：默认标识源的当前版本，?versionId= 选特定版本
  # （对齐 AWS CopyObject，铁律 5）。
  defp parse_copy_source!(raw) do
    decoded = URI.decode(raw)
    trimmed = String.replace_prefix(decoded, "/", "")

    {path, version_id} =
      case String.split(trimmed, "?", parts: 2) do
        [p] -> {p, nil}
        [p, q] -> {p, copy_source_version_id(q)}
      end

    case String.split(path, "/", parts: 2) do
      [bucket, key] when key != "" -> {bucket, key, version_id}
      _ -> raise Error.new(:invalid_argument, message: "Invalid x-amz-copy-source")
    end
  end

  # 从 copy-source 查询串提取 versionId（无/空 → nil）。
  defp copy_source_version_id(query) do
    query
    |> URI.decode_query()
    |> Map.get("versionId")
    |> case do
      v when is_binary(v) and v != "" -> v
      _ -> nil
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
    |> put_user_metadata_headers(object)
    |> maybe_tagging_count(object)
  end

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

  # version_id == nil → 取当前版本（latest）；否则取指定版本行。缺失 → NoSuchKey。
  # src_obj.version_id 即源真实字节所在版本路径（版本化源为 ULID，未版本化源为 "null"）。
  defp object_or_raise(bucket, key, nil) do
    _ = ensure_bucket!(bucket)

    case Objects.get_metadata(bucket, key) do
      {:ok, object} -> {object, object.size}
      {:error, :not_found} -> raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  defp object_or_raise(bucket, key, version_id) do
    _ = ensure_bucket!(bucket)

    case Objects.get_version(bucket, key, version_id) do
      {:ok, object} -> {object, object.size}
      {:error, :not_found} -> raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
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
