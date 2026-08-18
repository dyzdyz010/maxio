defmodule Maxio.S3.Handlers.Multipart do
  @moduledoc """
  Multipart 级 handler：Create/UploadPart/Complete/Abort/ListParts/ListMultipartUploads。
  会话/分块元数据走 Maxio.Multipart，分块字节走 Maxio.Storage（FS parts）。
  对象 body 绝不整读（UploadPart 流式）；只有 CompleteMultipartUpload 的小 XML 走带上限整读 + SAX。
  """
  import Plug.Conn
  alias Maxio.{Buckets, Multipart, Objects, Storage}
  alias Maxio.Cluster.Placement
  alias Maxio.Console.DirectMultipartUpload
  alias Maxio.Policy.ACL

  alias Maxio.S3.{
    BodyReader,
    Checksum,
    Conditional,
    ControlBody,
    CopySource,
    Error,
    ExpectedBucketOwner,
    ListQuery,
    Log,
    NotificationDelivery,
    NotificationRetainedLedger,
    OwnershipControls,
    PublicAccessBlock,
    ReplicationDelivery,
    RequestPayer,
    SSE,
    StorageClass,
    SystemHeaders,
    XML
  }

  alias Maxio.S3.RequestParsers.CompleteMultipartUpload, as: CompleteParser

  @max_uploads_limit 1000

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
    conn = fetch_query_params(conn)
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket, resource: "/#{bucket}/#{key}")
    charge = RequestPayer.require!(conn, bucket, resource: "/#{bucket}/#{key}")

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

    sse_target = SSE.resolve_target!(conn.req_headers, bucket)
    sse_algorithm = SSE.storage_algorithm(sse_target)
    sse_envelope = multipart_sse_envelope(sse_target)
    owner = conn.assigns.principal.arn
    checksum_intent = Checksum.multipart_upload_intent!(conn.req_headers)
    registry_attrs = console_direct_registry_attrs!(conn, bucket, key)

    # ROUTE B B4-6 fidelity：CreateMultipartUpload 须捕获客户端 x-amz-meta-*（与 PutObject 同源解析器），
    # 落进会话 metadata，使 CompleteMultipartUpload 后的最终对象 HEAD/GET 回显这些用户元数据
    # （对齐 AWS/MinIO：CreateMultipartUpload Request Syntax 显式列出 x-amz-meta-<key>）。
    # 写会话之前先做 2 KB 大小闸（与 PutObject 同阈值/同语义）——超限 → 400 MetadataTooLarge、
    # 失败 pre-create、无孤儿会话（铁律 3）。
    user_metadata = Maxio.Metadata.parse_headers(conn.req_headers)
    :ok = Maxio.Metadata.validate_size!(user_metadata)
    tags = parse_tagging_header!(conn)
    conn = assign(conn, :s3_metrics_tags, tags)

    attrs =
      %{
        content_type: content_type,
        storage_class: storage_class,
        acl_canned: acl_input.canned,
        acl_grants: acl_input.grants_doc,
        sse_algorithm: sse_algorithm,
        sse_envelope: sse_envelope,
        owner: owner,
        metadata: user_metadata,
        tags: tags
      }
      |> Map.merge(system_headers)
      |> Map.merge(checksum_intent)

    case initiate_multipart_upload(bucket, key, attrs, registry_attrs) do
      {:ok, upload} ->
        Log.info("create multipart upload",
          action: :create_multipart_upload,
          bucket: bucket,
          key: key,
          console_direct_registered: not is_nil(registry_attrs)
        )

        body =
          InitiateMultipartUpload.render(%{
            bucket: bucket,
            key: key,
            upload_id: upload.upload_id
          })

        conn
        |> put_resp_content_type("application/xml")
        |> assign(:s3_metrics_tags, upload.tags || %{})
        |> Checksum.put_multipart_upload_response_headers(upload)
        |> SSE.put_response_header(sse_target)
        |> RequestPayer.put_charged_header(charge)
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

  defp initiate_multipart_upload(bucket, key, attrs, nil) do
    Multipart.initiate(bucket, key, attrs)
  end

  defp initiate_multipart_upload(bucket, key, attrs, registry_attrs) do
    Multipart.initiate_with(bucket, key, attrs, fn upload ->
      DirectMultipartUpload.register(upload, registry_attrs)
    end)
  end

  defp console_direct_registry_attrs!(conn, bucket, key) do
    query = conn.query_params || %{}

    if DirectMultipartUpload.direct_multipart_query?(query) do
      case DirectMultipartUpload.registry_intent_attrs(query, conn.assigns.principal) do
        {:ok, attrs} ->
          attrs

        {:error, reason} ->
          Log.warn("console direct multipart registry intent rejected",
            action: :create_multipart_upload,
            bucket: bucket,
            key: key,
            reason: reason
          )

          raise Error.new(:invalid_argument,
                  message: console_direct_registry_error_message(reason),
                  resource: "/#{bucket}/#{key}"
                )
      end
    end
  end

  defp console_direct_registry_error_message(:invalid_size),
    do: "Console direct multipart file size is invalid"

  defp console_direct_registry_error_message(:invalid_part_size),
    do: "Console direct multipart part size is invalid"

  defp console_direct_registry_error_message(:too_many_parts),
    do: "Console direct multipart part count is too large"

  defp console_direct_registry_error_message(:invalid_file_name),
    do: "Console direct multipart file name is invalid"

  defp console_direct_registry_error_message(:invalid_file_last_modified),
    do: "Console direct multipart file last modified timestamp is invalid"

  defp console_direct_registry_error_message(_reason),
    do: "Console direct multipart registry intent is invalid"

  @spec upload_part(Plug.Conn.t()) :: Plug.Conn.t()
  def upload_part(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    upload_id = Map.fetch!(conn.query_params, "uploadId")
    part_number = parse_part_number!(Map.fetch!(conn.query_params, "partNumber"))
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket, resource: "/#{bucket}/#{key}")
    charge = RequestPayer.require!(conn, bucket, resource: "/#{bucket}/#{key}")

    upload = upload_or_raise(bucket, key, upload_id)
    conn = assign(conn, :s3_metrics_tags, upload.tags || %{})

    case header(conn, "x-amz-copy-source") do
      nil ->
        customer_key = upload_part_customer_key!(conn, upload, bucket, key)
        upload_part_body(conn, bucket, key, upload_id, part_number, upload, charge, customer_key)

      raw ->
        upload_part_copy(conn, bucket, key, upload_id, part_number, upload, raw, charge)
    end
  end

  defp upload_part_customer_key!(conn, %{sse_algorithm: "SSE-C"} = upload, bucket, key) do
    {customer_key, _key_md5_b64} =
      SSE.resolve_customer_read!(conn.req_headers, upload.sse_envelope,
        resource: "/#{bucket}/#{key}"
      )

    customer_key
  end

  defp upload_part_customer_key!(conn, _upload, bucket, key) do
    reject_unexpected_target_sse_c_headers!(conn, bucket, key)
    nil
  end

  defp maybe_encrypt_upload_part_stream(chunks, %{sse_algorithm: "SSE-C"}, customer_key)
       when is_binary(customer_key) and byte_size(customer_key) == 32 do
    {counted_chunks, visible_size} = counted_stream(chunks)

    {Maxio.Crypto.SSE.encrypt_stream_with_customer_key(counted_chunks, customer_key),
     visible_size}
  end

  defp maybe_encrypt_upload_part_stream(
         chunks,
         %{sse_algorithm: "aws:kms", sse_envelope: %{} = envelope},
         _customer_key
       ) do
    {counted_chunks, visible_size} = counted_stream(chunks)
    {Maxio.Crypto.SSE.encrypt_stream_with_kms_envelope(counted_chunks, envelope), visible_size}
  end

  defp maybe_encrypt_upload_part_stream(
         chunks,
         %{sse_algorithm: "aws:kms:dsse", sse_envelope: %{} = envelope},
         _customer_key
       ) do
    {counted_chunks, visible_size} = counted_stream(chunks)

    {Maxio.Crypto.SSE.encrypt_stream_with_dsse_kms_envelope(counted_chunks, envelope),
     visible_size}
  end

  defp maybe_encrypt_upload_part_stream(_chunks, %{sse_algorithm: "aws:kms"}, _customer_key) do
    raise Error.new(:invalid_request, message: "SSE-KMS multipart upload is missing its envelope")
  end

  defp maybe_encrypt_upload_part_stream(_chunks, %{sse_algorithm: "aws:kms:dsse"}, _customer_key) do
    raise Error.new(:invalid_request,
            message: "DSSE-KMS multipart upload is missing its envelope"
          )
  end

  defp maybe_encrypt_upload_part_stream(chunks, _upload, _customer_key),
    do: {chunks, fn -> 0 end}

  defp upload_part_body(conn, bucket, key, upload_id, part_number, upload, charge, customer_key) do
    checksum = Checksum.from_conn!(conn)

    {body_stream, get_trailers, discard_trailers} =
      BodyReader.stream_with_trailers(conn, conn.assigns.payload_mode)

    checksum =
      checksum
      |> Checksum.with_trailer_getter(get_trailers)
      |> Checksum.with_multipart_algorithm!(upload.checksum_algorithm)

    {chunks, get_checksum, discard_checksum} =
      body_stream |> Checksum.wrap_stream(checksum)

    {chunks, visible_size} = maybe_encrypt_upload_part_stream(chunks, upload, customer_key)

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
      {:ok, %{size: stored_size, etag: etag} = part_result} ->
        checksum = Map.get(part_result, :checksum, checksum)

        size =
          if upload.sse_algorithm in ["SSE-C", "aws:kms", "aws:kms:dsse"],
            do: visible_size.(),
            else: stored_size

        {:ok, _} =
          Multipart.put_part(upload, part_number, %{
            etag: etag,
            size: size,
            checksum: Checksum.part_metadata(checksum)
          })

        Log.info("upload part",
          action: :upload_part,
          bucket: bucket,
          key: key,
          size: size
        )

        conn
        |> assign(:s3_metrics_bytes_uploaded, size)
        |> assign(:s3_metrics_tags, upload.tags || %{})
        |> Checksum.put_response_headers(checksum)
        |> RequestPayer.put_charged_header(charge)
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

  defp upload_part_copy(
         conn,
         bucket,
         key,
         upload_id,
         part_number,
         upload,
         copy_source_header,
         dest_charge
       ) do
    :ok = Checksum.reject_upload_part_headers!(conn)
    customer_key = upload_part_customer_key!(conn, upload, bucket, key)

    source = CopySource.parse!(copy_source_header)
    :ok = validate_object_key!(source.bucket, source.key)
    :ok = CopySource.validate_version_id!(source)

    src_obj = copy_source_or_raise(source)
    source_customer_key = copy_part_source_customer_key!(conn, source, src_obj)

    :ok =
      ExpectedBucketOwner.verify!(conn, source.bucket,
        header: "x-amz-source-expected-bucket-owner",
        resource: "/#{source.bucket}/#{source.key}"
      )

    source_charge =
      RequestPayer.require!(conn, source.bucket, resource: "/#{source.bucket}/#{source.key}")

    charge = RequestPayer.merge(dest_charge, source_charge)

    reject_copy_source_marker!(source, src_obj)

    case CopySource.conditional_result(conn, src_obj) do
      :proceed ->
        :ok

      {:error, :precondition_failed} ->
        raise Error.new(:precondition_failed, resource: "/#{source.bucket}/#{source.key}")
    end

    range = CopySource.parse_range!(header(conn, "x-amz-copy-source-range"), src_obj.size)
    reject_small_range_copy!(range, source, src_obj)
    chunks = copy_part_source_stream!(source, src_obj, range, source_customer_key)
    checksum = Checksum.for_multipart_algorithm!(upload.checksum_algorithm)
    {chunks, get_checksum, discard_checksum} = Checksum.wrap_stream(chunks, checksum)
    {chunks, visible_size} = maybe_encrypt_upload_part_stream(chunks, upload, customer_key)

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
          discard_checksum.()
          reraise(err, __STACKTRACE__)
      catch
        kind, reason ->
          discard_checksum.()
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case put_result do
      {:ok, %{size: stored_size, etag: etag} = part_result} ->
        checksum = Map.get(part_result, :checksum, checksum)

        size =
          if upload.sse_algorithm in ["SSE-C", "aws:kms", "aws:kms:dsse"],
            do: visible_size.(),
            else: stored_size

        {:ok, part} =
          Multipart.put_part(upload, part_number, %{
            etag: etag,
            size: size,
            checksum: Checksum.part_metadata(checksum)
          })

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
            last_modified: part.updated_at,
            checksum: part.checksum || %{}
          })

        conn
        |> put_resp_content_type("application/xml")
        |> assign(:s3_metrics_operation, :upload_part_copy)
        |> assign(:s3_metrics_bytes_uploaded, size)
        |> assign(:s3_metrics_tags, upload.tags || %{})
        |> maybe_put_copy_source_version_id(src_obj.version_id)
        |> SSE.put_response_header(upload.sse_algorithm, upload.sse_envelope)
        |> RequestPayer.put_charged_header(charge)
        |> send_resp(200, body)

      {:error, :invalid_key} ->
        discard_checksum.()
        raise Error.new(:invalid_object_name, resource: "/#{bucket}/#{key}")

      {:error, reason} when reason in [:write_quorum, :rename_busy] ->
        discard_checksum.()
        raise Error.new(:slow_down_write, resource: "/#{bucket}/#{key}")

      {:error, reason} ->
        discard_checksum.()
        raise upload_part_error(reason, bucket, key)
    end
  end

  @spec complete_multipart_upload(Plug.Conn.t()) :: Plug.Conn.t()
  def complete_multipart_upload(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    upload_id = Map.fetch!(conn.query_params, "uploadId")
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket, resource: "/#{bucket}/#{key}")
    charge = RequestPayer.require!(conn, bucket, resource: "/#{bucket}/#{key}")

    upload = upload_or_raise(bucket, key, upload_id)
    conn = assign(conn, :s3_metrics_tags, upload.tags || %{})
    customer_key = complete_customer_key!(conn, upload, bucket, key)
    {conn, xml, trailers} = read_complete_body!(conn)
    :ok = verify_complete_content_md5!(conn.req_headers, xml, bucket, key)
    complete_checksum_request = Checksum.complete_multipart_request!(conn, trailers)

    requested =
      case CompleteParser.parse(xml) do
        {:ok, parts} -> parts
        {:error, :malformed_xml} -> raise Error.new(:malformed_xml, resource: "/#{bucket}/#{key}")
      end

    # Complete and metadata commit share the object lock so same-key writes cannot interleave.
    # Conditional Complete lock conflicts map to 409; ordinary lock conflicts still map to 503.
    # The backend assemble path does not acquire its own object lock.
    commit_result =
      Maxio.Lock.with_object_lock({bucket, key}, fn ->
        recover_retained_notifications!(bucket, key)
        :ok = ensure_complete_write_conditions!(conn.req_headers, bucket, key)

        bucket_record = ensure_bucket!(bucket)
        version_id = complete_version_id(bucket_record)
        replication_tags = upload.tags || %{}

        replication_tasks =
          replication_tasks_for(
            "s3:ObjectCreated:CompleteMultipartUpload",
            bucket,
            key,
            version_id,
            replication_tags
          )

        replication_status = replication_status_for(replication_tasks)

        complete_opts =
          [
            version_id: version_id,
            complete_checksum_request: complete_checksum_request,
            object_meta_extra: fn %{size: size, etag: etag, version_id: version_id} = info ->
              complete_object_meta_extra(
                {"s3:ObjectCreated:CompleteMultipartUpload",
                 notification_attrs(conn, bucket, key, size, etag, version_id)},
                Placement.storage_opts(info),
                replication_status
              )
            end
          ]
          |> maybe_put_sse_customer_key(customer_key)

        case Multipart.complete(upload, requested, complete_opts) do
          {:ok,
           %{
             etag: etag,
             size: size,
             checksum: checksum,
             object_parts: object_parts,
             sse_envelope: sse_envelope,
             version_id: version_id
           } = complete_result} ->
            notification =
              {"s3:ObjectCreated:CompleteMultipartUpload",
               notification_attrs(conn, bucket, key, size, etag, version_id)}

            replication = replication_delivery(replication_tasks, size, etag)

            # ROUTE B B5-1：元数据提交按写权威分流（与 object.ex commit_metadata 同模式）。
            notification_delivery =
              try do
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
                    website_redirect_location: upload.website_redirect_location,
                    storage_class: upload.storage_class,
                    checksum:
                      SSE.checksum_for_storage(checksum, upload.sse_algorithm, sse_envelope),
                    object_parts:
                      SSE.object_parts_for_storage(
                        object_parts,
                        upload.sse_algorithm,
                        sse_envelope
                      ),
                    acl_canned: upload.acl_canned,
                    acl_grants: upload.acl_grants || ACL.empty_grants_doc(),
                    sse_algorithm: upload.sse_algorithm,
                    sse_envelope: sse_envelope,
                    # ROUTE B B4-6 fidelity：会话捕获的 user_metadata 也写入 PG 索引行，
                    # 消除已完成多段对象在 :pg(默认) 读路径下 metadata=%{} 的 D3-style 分裂——
                    # 与 sidecar 透传（assemble_object_meta.user_metadata）保持两路一致。
                    metadata: upload.metadata || %{},
                    tags: upload.tags || %{},
                    replication_status: replication_status
                  }
                  |> Map.merge(Placement.attrs_from_result(complete_result)),
                  notification,
                  replication,
                  Map.get(complete_result, :notification_outbox, []),
                  Map.get(complete_result, :notification_retained_ledger, [])
                )
              rescue
                err ->
                  cleanup_complete_object_bytes_after_metadata_failure(
                    bucket,
                    key,
                    version_id,
                    upload_id,
                    complete_result
                  )

                  reraise(err, __STACKTRACE__)
              end

            record_console_direct_completed_history(upload, %{
              etag: etag,
              version_id: version_id,
              size: size
            })

            cleanup_terminal_upload(upload, :complete_multipart_upload)

            {:ok,
             {etag, size, checksum, upload.sse_algorithm, sse_envelope, version_id,
              notification_delivery}}

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case commit_result do
      {:ok,
       {:ok,
        {etag, size, checksum, sse_algorithm, sse_envelope, version_id, notification_delivery}}} ->
        deliver_committed_notification(notification_delivery)

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
            etag: etag,
            checksum: checksum
          })

        conn
        |> put_resp_content_type("application/xml")
        |> assign(:s3_metrics_bytes_uploaded, size)
        |> assign(:s3_metrics_tags, upload.tags || %{})
        |> SSE.put_response_header(sse_algorithm, sse_envelope)
        |> maybe_put_version_id(version_id)
        |> RequestPayer.put_charged_header(charge)
        |> send_resp(200, body)

      {:ok, {:error, reason}} ->
        raise complete_error(reason, bucket, key)

      {:error, :locked} ->
        raise complete_lock_error(conn.req_headers, bucket, key)
    end
  end

  defp complete_customer_key!(conn, %{sse_algorithm: "SSE-C"} = upload, bucket, key) do
    {customer_key, _key_md5_b64} =
      SSE.resolve_customer_read!(conn.req_headers, upload.sse_envelope,
        resource: "/#{bucket}/#{key}"
      )

    customer_key
  end

  defp complete_customer_key!(conn, _upload, bucket, key) do
    reject_unexpected_target_sse_c_headers!(conn, bucket, key)
    nil
  end

  defp maybe_put_sse_customer_key(opts, nil), do: opts

  defp maybe_put_sse_customer_key(opts, customer_key),
    do: Keyword.put(opts, :sse_customer_key, customer_key)

  defp record_console_direct_completed_history(upload, attrs) do
    case DirectMultipartUpload.record_completed(upload, attrs) do
      {:ok, _history} ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        Log.warn("console direct multipart completed history write failed",
          action: :console_direct_multipart_history,
          bucket: upload.bucket_name,
          key: upload.key,
          upload_id: upload.upload_id,
          terminal_state: :completed,
          reason: inspect(reason)
        )
    end
  end

  defp console_direct_aborted_history_recorder(upload) do
    registry = DirectMultipartUpload.registry_for_upload(upload)

    fn ->
      case registry do
        {:ok, registry_upload} -> record_console_direct_aborted_history(registry_upload)
        {:error, :not_found} -> :ok
      end
    end
  end

  defp record_console_direct_aborted_history(registry_upload) do
    case DirectMultipartUpload.record_aborted(registry_upload) do
      {:ok, _history} ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        Log.warn("console direct multipart aborted history write failed",
          action: :console_direct_multipart_history,
          bucket: registry_upload.bucket_name,
          key: registry_upload.key,
          upload_id: registry_upload.upload_id,
          terminal_state: :aborted,
          reason: inspect(reason)
        )
    end
  end

  defp cleanup_terminal_upload(upload, terminal_action) do
    case Multipart.cleanup_after_terminal(upload) do
      :ok ->
        :ok

      {:error, reason} ->
        Log.warn("multipart terminal cleanup failed",
          action: :multipart_terminal_cleanup,
          terminal_action: terminal_action,
          bucket: upload.bucket_name,
          key: upload.key,
          upload_id: upload.upload_id,
          reason: inspect(reason)
        )
    end
  end

  @spec abort_multipart_upload(Plug.Conn.t()) :: Plug.Conn.t()
  def abort_multipart_upload(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    upload_id = Map.fetch!(conn.query_params, "uploadId")
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket, resource: "/#{bucket}/#{key}")
    charge = RequestPayer.require!(conn, bucket, resource: "/#{bucket}/#{key}")

    upload = upload_or_raise(bucket, key, upload_id)
    conn = assign(conn, :s3_metrics_tags, upload.tags || %{})
    record_history_after_abort = console_direct_aborted_history_recorder(upload)

    case Multipart.abort(upload) do
      :ok ->
        record_history_after_abort.()

        Log.info("abort multipart upload",
          action: :abort_multipart_upload,
          bucket: bucket,
          key: key
        )

      {:error, reason} ->
        raise abort_error(reason, bucket, key)
    end

    conn
    |> RequestPayer.put_charged_header(charge)
    |> send_resp(204, "")
  end

  @spec list_parts(Plug.Conn.t()) :: Plug.Conn.t()
  def list_parts(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    upload_id = Map.fetch!(conn.query_params, "uploadId")
    max_parts = parse_int(Map.get(conn.query_params, "max-parts"), 1000)
    marker = parse_int(Map.get(conn.query_params, "part-number-marker"), 0)
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket, resource: "/#{bucket}/#{key}")
    charge = RequestPayer.require!(conn, bucket, resource: "/#{bucket}/#{key}")

    upload = upload_or_raise(bucket, key, upload_id)
    conn = assign(conn, :s3_metrics_tags, upload.tags || %{})
    res = Multipart.list_parts(upload, %{max_parts: max_parts, part_number_marker: marker})

    parts =
      Enum.map(res.parts, fn p ->
        %{
          part_number: p.part_number,
          last_modified: p.updated_at,
          etag: p.etag,
          size: p.size,
          checksum: p.checksum || %{}
        }
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
    |> RequestPayer.put_charged_header(charge)
    |> send_resp(200, body)
  end

  @spec list_multipart_uploads(Plug.Conn.t()) :: Plug.Conn.t()
  def list_multipart_uploads(conn) do
    bucket = conn.assigns.s3_bucket
    conn = fetch_query_params(conn)
    qp = conn.query_params
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket, resource: "/" <> bucket)
    charge = RequestPayer.require!(conn, bucket, resource: "/" <> bucket)

    prefix = Map.get(qp, "prefix", "")
    delimiter = ListQuery.delimiter(qp)

    max_uploads =
      parse_limited_query_int!(
        qp,
        "max-uploads",
        @max_uploads_limit,
        1,
        @max_uploads_limit
      )

    key_marker = ListQuery.cursor(qp, "key-marker")
    upload_id_marker = ListQuery.cursor(qp, "upload-id-marker")

    res =
      Multipart.list_uploads(bucket, %{
        prefix: prefix,
        delimiter: delimiter,
        max_uploads: max_uploads,
        key_marker: key_marker,
        upload_id_marker: upload_id_marker
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
        upload_id_marker: upload_id_marker,
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
    |> RequestPayer.put_charged_header(charge)
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
  #     PG 仅派生索引，用 put_version_index 对普通 PG index 失败 best-effort：失败 → Log.error
  #     （绝不静默）+ 不失败请求（索引滞后由 B5-2 scanner reconcile）。S3 语义错误（如 bucket
  #     hard quota）会重新抛出并由外层 fail-closed 清理字节。响应（etag/size）来自
  #     Multipart.complete，本就不依赖 PG 读回，无需内存视图。
  defp commit_complete_metadata(
         bucket,
         key,
         version_id,
         attrs,
         notification,
         replication,
         sidecar_notification_outbox,
         retained_notification_ledger
       ) do
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

        notification_after_sidecar_commit(
          notification,
          sidecar_notification_outbox,
          bucket,
          key,
          retained_notification_ledger,
          Placement.storage_opts(attrs)
        )

      _pg ->
        case Objects.put_version_with_id(
               bucket,
               key,
               version_id,
               attrs,
               post_commit_transaction_opts(notification, replication)
             ) do
          {:ok, {_obj, enqueued}} -> {:enqueued, enqueued}
          {:ok, _obj} -> :none
        end
    end
  end

  defp post_commit_transaction_opts(nil, nil), do: []

  defp post_commit_transaction_opts(notification, replication) do
    [
      transaction_hook: fn repo, _object ->
        %{
          notifications: enqueue_notification(notification, repo),
          replication: enqueue_replication(replication, repo)
        }
      end
    ]
  end

  defp enqueue_notification(nil, _repo), do: []

  defp enqueue_notification({event_name, attrs}, repo) do
    NotificationDelivery.enqueue(event_name, attrs, repo: repo)
  end

  defp enqueue_replication(nil, _repo), do: []

  defp enqueue_replication({:tasks, tasks}, repo) when is_list(tasks) do
    ReplicationDelivery.enqueue_tasks(tasks, repo: repo)
  end

  defp enqueue_replication({event_name, attrs}, repo) do
    ReplicationDelivery.enqueue(event_name, attrs, repo: repo)
  end

  defp notification_after_sidecar_commit(
         notification,
         ledger,
         bucket,
         key,
         retained,
         storage_opts
       )

  defp notification_after_sidecar_commit(nil, _ledger, _bucket, _key, _retained, _storage_opts),
    do: :none

  defp notification_after_sidecar_commit(_notification, [], _bucket, _key, [], _storage_opts),
    do: :none

  defp notification_after_sidecar_commit(
         _notification,
         ledger,
         bucket,
         key,
         retained,
         storage_opts
       ),
       do:
         {:sidecar_ledger, ledger,
          %{bucket: bucket, key: key, retained: retained, storage_opts: storage_opts}}

  defp deliver_committed_notification(:none), do: :ok

  defp deliver_committed_notification(%{notifications: notifications}) do
    NotificationDelivery.deliver_enqueued(notifications)
  end

  defp deliver_committed_notification({:enqueued, %{notifications: notifications}}) do
    NotificationDelivery.deliver_enqueued(notifications)
  end

  defp deliver_committed_notification({:enqueued, enqueued_notifications}) do
    NotificationDelivery.deliver_enqueued(enqueued_notifications)
  end

  defp deliver_committed_notification({:emit, {event_name, attrs}}) do
    NotificationDelivery.emit(event_name, attrs)
  end

  defp deliver_committed_notification({:sidecar_ledger, ledger, context}) do
    ledger
    |> NotificationDelivery.replay_sidecar_ledger()
    |> NotificationDelivery.deliver_enqueued()

    context
    |> Map.get(:retained, [])
    |> NotificationRetainedLedger.replay_committed(Map.get(context, :storage_opts, []))
  rescue
    err ->
      Log.error("bucket notification sidecar ledger replay deferred",
        action: :bucket_notification_delivery,
        bucket: Map.get(context, :bucket),
        key: Map.get(context, :key),
        reason: inspect(err)
      )

      :ok
  end

  defp complete_object_meta_extra({event_name, attrs}, storage_opts, replication_status) do
    replication_object_meta = replication_object_meta(replication_status)

    case Maxio.ObjectMeta.authoritative_source(:write) do
      :sidecar ->
        notification_outbox = NotificationDelivery.sidecar_ledger(event_name, attrs)
        bucket = Map.fetch!(attrs, :bucket)
        key = Map.fetch!(attrs, :key)
        version_id = Map.fetch!(attrs, :version_id)

        notification_retained_ledger =
          NotificationRetainedLedger.entries(notification_outbox,
            bucket: bucket,
            key: key,
            operation: :complete_multipart_upload,
            predicate:
              NotificationRetainedLedger.version_present(version_id,
                entry_type: "object",
                etag: Map.fetch!(attrs, :etag),
                size: Map.fetch!(attrs, :size)
              ),
            request_id: Map.get(attrs, :request_id),
            storage_opts: storage_opts
          )

        NotificationRetainedLedger.persist!(
          bucket,
          key,
          notification_retained_ledger,
          storage_opts
        )

        %{
          notification_outbox: notification_outbox,
          notification_retained_ledger: notification_retained_ledger,
          object_meta: Map.put(replication_object_meta, :notification_outbox, notification_outbox)
        }

      _pg ->
        maybe_object_meta(replication_object_meta)
    end
  end

  defp replication_object_meta(nil), do: %{}
  defp replication_object_meta(status), do: %{replication_status: status}

  defp maybe_object_meta(map) when map == %{}, do: %{}
  defp maybe_object_meta(map), do: %{object_meta: map}

  defp recover_retained_notifications!(bucket, key) do
    case Maxio.ObjectMeta.authoritative_source(:write) do
      :sidecar -> NotificationRetainedLedger.recover_key!(bucket, key)
      _pg -> :ok
    end
  end

  defp complete_version_id(%{versioning: "Enabled"}),
    do: Maxio.Versioning.VersionId.generate()

  defp complete_version_id(_bucket), do: "null"

  defp cleanup_complete_object_bytes_after_metadata_failure(
         bucket,
         key,
         version_id,
         upload_id,
         complete_result
       ) do
    case Storage.delete(bucket, key, version_id, Placement.storage_opts(complete_result)) do
      :ok ->
        Log.warn("complete multipart upload rolled back orphan bytes",
          action: :complete_multipart_upload,
          bucket: bucket,
          key: key,
          upload_id: upload_id,
          reason: :metadata_commit_failed
        )

      {:error, reason} ->
        Log.error("complete multipart orphan bytes cleanup failed after metadata rollback",
          action: :complete_multipart_upload,
          bucket: bucket,
          key: key,
          upload_id: upload_id,
          version_id: version_id,
          reason: inspect(reason)
        )
    end
  end

  defp ensure_complete_write_conditions!(headers, bucket, key) do
    if complete_write_conditions?(headers) do
      case Maxio.ObjectMeta.get(bucket, key, nil, []) do
        %Objects.Object{is_delete_marker: true} ->
          ensure_complete_absent_conditions!(headers, bucket, key)

        %Objects.Object{} = object ->
          meta = %{etag: object.etag, last_modified: object.updated_at}

          case Conditional.evaluate(headers, meta, "PUT") do
            :proceed ->
              :ok

            {:error, :precondition_failed} ->
              raise Error.new(:precondition_failed, resource: "/#{bucket}/#{key}")

            {:respond, 304} ->
              raise Error.new(:precondition_failed, resource: "/#{bucket}/#{key}")
          end

        {:error, :not_found} ->
          ensure_complete_absent_conditions!(headers, bucket, key)

        {:error, :read_quorum} ->
          Log.warn(
            "complete multipart precondition target unavailable: sidecar read_quorum unmet",
            action: :complete_multipart_upload,
            bucket: bucket,
            key: key,
            reason: :read_quorum
          )

          raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")
      end
    else
      :ok
    end
  end

  defp complete_write_conditions?(headers) do
    header_value(headers, "if-match") != nil or header_value(headers, "if-none-match") != nil
  end

  defp ensure_complete_absent_conditions!(headers, bucket, key) do
    if header_value(headers, "if-match") do
      raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    else
      :ok
    end
  end

  defp complete_lock_error(headers, bucket, key) do
    if complete_write_conditions?(headers) do
      Error.new(:conditional_request_conflict, resource: "/#{bucket}/#{key}")
    else
      Error.new(:request_timeout, resource: "/#{bucket}/#{key}")
    end
  end

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

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {header_name, value} ->
      if String.downcase(header_name) == name, do: value
    end)
  end

  defp multipart_sse_envelope({:customer, raw_key, key_md5_b64}) do
    Maxio.Crypto.SSE.customer_key_envelope(raw_key, key_md5_b64)
  end

  defp multipart_sse_envelope({:kms, key_id, context_b64, bucket_key_enabled}) do
    Maxio.Crypto.SSE.kms_envelope(key_id, context_b64, bucket_key_enabled: bucket_key_enabled)
  end

  defp multipart_sse_envelope({:kms_dsse, key_id, context_b64}) do
    Maxio.Crypto.SSE.dsse_kms_envelope(key_id, context_b64)
  end

  defp multipart_sse_envelope(_target), do: nil

  defp reject_unexpected_target_sse_c_headers!(conn, bucket, key) do
    if SSE.target_customer_headers?(conn.req_headers) do
      raise Error.new(:invalid_request,
              message: "SSE-C headers are only valid for SSE-C multipart uploads",
              resource: "/#{bucket}/#{key}"
            )
    end

    :ok =
      SSE.reject_target_kms_headers!(
        conn.req_headers,
        "SSE-KMS headers are only valid on CreateMultipartUpload"
      )

    :ok
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

  defp copy_part_source_customer_key!(
         conn,
         source,
         %{sse_algorithm: "SSE-C", sse_envelope: envelope}
       ) do
    {customer_key, _key_md5_b64} =
      SSE.resolve_copy_source_customer_read!(conn.req_headers, envelope,
        resource: "/#{source.bucket}/#{source.key}"
      )

    customer_key
  end

  defp copy_part_source_customer_key!(conn, source, _src_obj) do
    if SSE.copy_source_customer_headers?(conn.req_headers) do
      raise Error.new(:invalid_request,
              message: "SSE-C copy source headers are only valid for SSE-C source objects",
              resource: "/#{source.bucket}/#{source.key}"
            )
    end

    nil
  end

  defp copy_part_source_stream!(source, src_obj, range, source_customer_key) do
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

      "aws:kms" ->
        {:ok, raw_stream} =
          Storage.get(
            source.bucket,
            source.key,
            src_obj.version_id,
            nil,
            Placement.storage_opts(src_obj)
          )

        raw_stream
        |> Maxio.Crypto.SSE.unwrap_stream_with_kms_key(src_obj.sse_envelope)
        |> trim_stream(range)

      "aws:kms:dsse" ->
        {:ok, raw_stream} =
          Storage.get(
            source.bucket,
            source.key,
            src_obj.version_id,
            nil,
            Placement.storage_opts(src_obj)
          )

        raw_stream
        |> Maxio.Crypto.SSE.unwrap_stream_with_dsse_kms_key(src_obj.sse_envelope)
        |> trim_stream(range)

      "SSE-C" ->
        {:ok, raw_stream} =
          Storage.get(
            source.bucket,
            source.key,
            src_obj.version_id,
            nil,
            Placement.storage_opts(src_obj)
          )

        raw_stream
        |> Maxio.Crypto.SSE.unwrap_stream_with_customer_key(
          src_obj.sse_envelope,
          source_customer_key
        )
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

  defp read_complete_body!(conn) do
    ControlBody.read!(conn, @complete_xml_limit, "Complete request body too large",
      too_large_error: :entity_too_large
    )
  end

  defp verify_complete_content_md5!(headers, body, bucket, key) do
    case header_value(headers, "content-md5") do
      nil ->
        :ok

      value ->
        with {:ok, expected} <- Base.decode64(value),
             16 <- byte_size(expected),
             computed <- :crypto.hash(:md5, body),
             true <- Maxio.Auth.SigV4.Signer.secure_compare(computed, expected) do
          :ok
        else
          _other -> raise Error.new(:bad_digest, resource: "/#{bucket}/#{key}")
        end
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

  defp complete_error(:bad_digest, b, k), do: Error.new(:bad_digest, resource: "/#{b}/#{k}")

  defp complete_error(:invalid_request, b, k),
    do: Error.new(:invalid_request, resource: "/#{b}/#{k}")

  defp complete_error(:checksum_not_implemented, b, k),
    do:
      Error.new(:not_implemented,
        resource: "/#{b}/#{k}",
        message: "CompleteMultipartUpload CRC64NVME full-object checksum is not implemented"
      )

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

  defp abort_error(reason, b, k) when reason in [:write_quorum, :rename_busy],
    do: Error.new(:slow_down_write, resource: "/#{b}/#{k}")

  defp abort_error(reason, b, k) do
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

  defp parse_limited_query_int!(params, name, default, min, max) do
    case Map.get(params, name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {n, ""} when n >= min and n <= max ->
            n

          _ ->
            raise Error.new(:invalid_argument,
                    message: "#{name} must be #{min}..#{max}"
                  )
        end
    end
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp parse_tagging_header!(conn) do
    case header(conn, "x-amz-tagging") do
      nil ->
        %{}

      "" ->
        %{}

      raw ->
        case Maxio.Tags.parse_header(raw) do
          {:ok, tags} ->
            case Maxio.Tags.validate(tags, :object) do
              :ok -> Maxio.Tags.list_to_map(tags)
              {:error, :invalid_tag} -> raise Error.new(:invalid_tag)
            end

          {:error, :invalid_tag} ->
            raise Error.new(:invalid_tag)
        end
    end
  end

  defp replication_tasks_for(event_name, bucket, key, version_id, tags) do
    attrs = %{bucket: bucket, key: key, version_id: version_id, tags: tags || %{}}

    case Maxio.ObjectMeta.authoritative_source(:write) do
      :pg -> ReplicationDelivery.pending_tasks(event_name, attrs)
      _sidecar -> []
    end
  end

  defp replication_status_for([]), do: nil
  defp replication_status_for(_tasks), do: "PENDING"

  defp replication_delivery([], _size, _etag), do: nil

  defp replication_delivery(tasks, size, etag) when is_list(tasks) do
    {:tasks, Enum.map(tasks, &Map.merge(&1, %{source_size: size, source_etag: etag}))}
  end

  defp notification_attrs(conn, bucket, key, size, etag, version_id) do
    %{
      bucket: bucket,
      key: key,
      size: size,
      etag: etag,
      version_id: version_id,
      request_id: header(conn, "x-request-id"),
      principal: Map.get(conn.assigns, :principal),
      source_ip: conn.remote_ip
    }
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
