defmodule Maxio.S3.Error do
  @moduledoc """
  统一 S3 错误异常（铁律 3：绝不静默 500）。内部用原子错误码，经 new/2 映射到
  官方 S3 Error Code 字符串 + 正确 HTTP 状态 + 默认 Message。渲染为 <Error> XML 由
  Maxio.S3.ErrorView 负责。错误码→状态表逐项对照官方 ErrorResponses 文档。
  """
  defexception [:code, :message, :http_status, :resource, :request_id, extra: %{}]

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          http_status: pos_integer(),
          resource: String.t() | nil,
          request_id: String.t() | nil,
          extra: map()
        }

  # {官方 Code 字符串, HTTP 状态, 默认 Message}
  @table %{
    no_such_bucket: {"NoSuchBucket", 404, "The specified bucket does not exist."},
    no_such_key: {"NoSuchKey", 404, "The specified key does not exist."},
    # B6-2a：DeleteObjects 的 per-key 畸形 versionId 对齐 MinIO DeleteMultipleObjectsHandler——
    # uuid.Parse 失败 → errorCodes.ToAPIErr(ErrNoSuchVersion)（Code "NoSuchVersion"，HTTP 404，
    # 描述逐字 cmd/api-errors.go），落 per-key <Error>（整响应仍 200）；与单删 DELETE ?versionId
    # 的 ErrInvalidVersionID（400 InvalidArgument）分流。AWS 同 Code（ErrorResponses）。
    no_such_version: {"NoSuchVersion", 404, "The specified version does not exist."},
    no_such_upload: {"NoSuchUpload", 404, "The specified multipart upload does not exist."},
    access_denied: {"AccessDenied", 403, "Access Denied"},
    # MinIO extractSignedHeaders 在验签前的硬性检查：SignedHeaders 漏强制 host →
    # ErrUnsignedHeaders（Code AccessDenied，但 HTTP 400，区别于上面 403 的 access_denied）。
    unsigned_headers:
      {"AccessDenied", 400, "There were headers present in the request which were not signed"},
    signature_does_not_match:
      {"SignatureDoesNotMatch", 403,
       "The request signature that the server calculated does not match the signature that you provided. Check your AWS secret access key and signing method."},
    invalid_access_key_id:
      {"InvalidAccessKeyId", 403,
       "The AWS access key ID that you provided does not exist in our records."},
    invalid_token: {"InvalidToken", 400, "The provided token is malformed or otherwise invalid."},
    expired_token: {"ExpiredToken", 400, "The provided token has expired."},
    request_time_too_skewed:
      {"RequestTimeTooSkewed", 403,
       "The difference between the request time and the server's time is too large."},
    bucket_already_owned_by_you:
      {"BucketAlreadyOwnedByYou", 409,
       "The bucket that you tried to create already exists, and you own it."},
    bucket_already_exists:
      {"BucketAlreadyExists", 409,
       "The requested bucket name is not available. The bucket namespace is shared by all users of the system."},
    bucket_not_empty:
      {"BucketNotEmpty", 409, "The bucket that you tried to delete is not empty."},
    invalid_argument: {"InvalidArgument", 400, "Invalid Argument"},
    invalid_storage_class:
      {"InvalidStorageClass", 400, "The storage class that you specified is not valid."},
    invalid_object_state:
      {"InvalidObjectState", 403, "The operation is not valid for the object's storage class."},
    invalid_tag:
      {"InvalidTag", 400,
       "The tag provided was not a valid tag. This error can occur if the tag did not pass input validation."},
    invalid_bucket_name: {"InvalidBucketName", 400, "The specified bucket is not valid."},
    invalid_target_bucket_for_logging:
      {"InvalidTargetBucketForLogging", 400,
       "The target bucket for logging does not exist or is not writable."},
    # ROUTE B B5-3 R3/R4：key 含盘上布局保留名段（meta.json/part.0/.versions/.uploads/.tmp）或
    # ./.. 点段 → 对齐 MinIO ErrInvalidObjectName（Code "XMinioInvalidObjectName"，HTTP 400，
    # cmd/api-errors.go，描述逐字对齐）。结构化 400 拒绝，绝不 500（铁律 3）。
    invalid_object_name:
      {"XMinioInvalidObjectName", 400, "Object name contains unsupported characters."},
    # ROUTE B B5-4：对象 key（原始字节，非盘上编码后）超 1024 字节 → 对齐 MinIO
    # ErrKeyTooLongError（Code "KeyTooLongError"，HTTP 400，cmd/api-errors.go；AWS 同 Code，
    # 描述逐字对齐）。与 :invalid_object_name（点段/空 key）分流（B5-4 入口守卫）。
    key_too_long: {"KeyTooLongError", 400, "Your key is too long"},
    # AWS/MinIO 用户元数据（x-amz-meta-*）总量 2 KB 硬上限超限 → MetadataTooLarge(400)。
    # 权威：AWS UsingMetadata.html（user-defined metadata 限 2 KB / 每 key+value UTF-8 字节和）+
    # minio/minio cmd/generic-handlers.go isHTTPHeaderSizeTooLarge（maxUserDataSize=2*1024，key 含前缀）。
    metadata_too_large:
      {"MetadataTooLarge", 400, "Your metadata headers exceed the maximum allowed metadata size."},
    entity_too_small:
      {"EntityTooSmall", 400,
       "Your proposed upload is smaller than the minimum allowed object size."},
    entity_too_large:
      {"EntityTooLarge", 400, "Your proposed upload exceeds the maximum allowed object size."},
    invalid_part: {"InvalidPart", 400, "One or more of the specified parts could not be found."},
    invalid_part_order:
      {"InvalidPartOrder", 400, "The list of parts was not in ascending order."},
    malformed_xml:
      {"MalformedXML", 400,
       "The XML that you provided was not well formed or did not validate against our published schema."},
    precondition_failed:
      {"PreconditionFailed", 412,
       "At least one of the preconditions that you specified did not hold."},
    not_modified: {"NotModified", 304, "The resource was not changed."},
    invalid_range: {"InvalidRange", 416, "The requested range cannot be satisfied."},
    method_not_allowed:
      {"MethodNotAllowed", 405, "The specified method is not allowed against this resource."},
    missing_content_length:
      {"MissingContentLength", 411, "You must provide the Content-Length HTTP header."},
    not_implemented:
      {"NotImplemented", 501,
       "A header that you provided implies functionality that is not implemented."},
    request_timeout:
      {"RequestTimeout", 503,
       "A timeout occurred while trying to lock a resource, please reduce your request rate"},
    slow_down: {"SlowDown", 503, "Please reduce your request rate."},
    # MinIO 区分写/读 quorum 不足为可重试的 503（cmd/api-errors.go:
    # errErasureWriteQuorum -> ErrSlowDownWrite{Code:"SlowDownWrite",503}；
    # errErasureReadQuorum -> ErrSlowDownRead{Code:"SlowDownRead",503}）。SDK 标准重试策略
    # 把 503 SlowDown* 视为限流并指数退避，依赖此路径在集群降级/瞬时争用下自愈；
    # 绝不能退化成 500 InternalError（被多数客户端当硬失败、跳过退避）。
    slow_down_write: {"SlowDownWrite", 503, "Please reduce your write request rate."},
    # ROUTE B B4-3：翻读权威（:read=:sidecar）后，GET/HEAD 的 sidecar reconcile 不足 read_quorum
    # （端点宕机 / 副本分歧）→ 对象当前不可读、绝不返回猜测副本（铁律 3）。映射为 SlowDownRead(503)，
    # 与 PUT 写 quorum 的 :slow_down_write 对称，逐字对齐 MinIO toAPIErrorCode()：
    # errErasureReadQuorum / InsufficientReadQuorum -> ErrSlowDownRead（cmd/api-errors.go）。
    # 绝不用 AWS 泛化的 ServiceUnavailable——MinIO errorCodes 表无该 Code，maxio 声称 MinIO 兼容，
    # 须产 MinIO 字节一致的 SlowDownRead（SDK 重试分类器据 SlowDown* 视为限流退避）。
    slow_down_read: {"SlowDownRead", 503, "Please reduce your read request rate."},
    internal_error: {"InternalError", 500, "An internal error occurred. Try again."},
    authorization_header_malformed:
      {"AuthorizationHeaderMalformed", 400,
       "The authorization header that you provided is not valid."},
    authorization_query_parameters_error:
      {"AuthorizationQueryParametersError", 400,
       "The authorization query parameters that you provided are not valid."},
    missing_security_header:
      {"MissingSecurityHeader", 400, "Your request is missing a required header."},
    invalid_request: {"InvalidRequest", 400, "Invalid Request"},
    invalid_bucket_state:
      {"InvalidBucketState", 409,
       "The request is not valid with the current state of the bucket."},
    bad_digest:
      {"BadDigest", 400,
       "The Content-MD5 or checksum value that you specified did not match what the server received."},
    x_amz_content_sha256_mismatch:
      {"XAmzContentSHA256Mismatch", 400,
       "The provided 'x-amz-content-sha256' header does not match what was computed."},
    incomplete_body:
      {"IncompleteBody", 400,
       "You did not provide the number of bytes specified by the Content-Length HTTP header."},
    malformed_policy:
      {"MalformedPolicy", 400, "Policies must be valid JSON and the first byte must be '{'."},
    no_such_bucket_policy: {"NoSuchBucketPolicy", 404, "The bucket policy does not exist."},
    no_such_public_access_block_configuration:
      {"NoSuchPublicAccessBlockConfiguration", 404,
       "The public access block configuration was not found."},
    ownership_controls_not_found:
      {"OwnershipControlsNotFoundError", 404, "The bucket ownership controls were not found."},
    access_control_list_not_supported:
      {"AccessControlListNotSupported", 400, "The bucket does not allow ACLs."},
    invalid_bucket_acl_with_object_ownership:
      {"InvalidBucketAclWithObjectOwnership", 400,
       "Bucket cannot have ACLs set with ObjectOwnership's BucketOwnerEnforced setting."},
    access_forbidden:
      {"AccessForbidden", 403,
       "CORSResponse: This CORS request is not allowed. This is usually because the evaluation of Origin, request method / Access-Control-Request-Method or Access-Control-Request-Headers are not whitelisted."},
    no_such_cors_configuration:
      {"NoSuchCORSConfiguration", 404, "The CORS configuration does not exist."},
    no_such_lifecycle_configuration:
      {"NoSuchLifecycleConfiguration", 404, "The lifecycle configuration does not exist."},
    no_such_website_configuration:
      {"NoSuchWebsiteConfiguration", 404, "The website configuration does not exist."},
    no_such_metrics_configuration:
      {"NoSuchConfiguration", 404, "The specified metrics configuration does not exist."},
    no_such_analytics_configuration:
      {"NoSuchConfiguration", 404, "The specified analytics configuration does not exist."},
    no_such_inventory_configuration:
      {"NoSuchConfiguration", 404, "The specified inventory configuration does not exist."},
    replication_configuration_not_found:
      {"ReplicationConfigurationNotFoundError", 404,
       "The replication configuration was not found."},
    object_lock_configuration_not_found:
      {"ObjectLockConfigurationNotFoundError", 404,
       "Object Lock configuration does not exist for this bucket."},
    too_many_configurations:
      {"TooManyConfigurations", 400,
       "You are attempting to create a new configuration but have already reached the configuration limit."},
    server_side_encryption_configuration_not_found:
      {"ServerSideEncryptionConfigurationNotFoundError", 404,
       "The server side encryption configuration was not found."}
  }

  @doc """
  构造 S3 错误。`code` 为内部原子（见映射表）；opts 可含 :message :resource :request_id :extra。
  未知 code 兜底 InternalError(500)。
  """
  @spec new(atom(), keyword()) :: t()
  def new(code, opts \\ []) when is_atom(code) do
    {code_str, status, default_msg} =
      Map.get(@table, code, {"InternalError", 500, "An internal error occurred. Try again."})

    %__MODULE__{
      code: code_str,
      message: Keyword.get(opts, :message, default_msg),
      http_status: status,
      resource: Keyword.get(opts, :resource),
      request_id: Keyword.get(opts, :request_id),
      extra: Keyword.get(opts, :extra, %{})
    }
  end

  @impl true
  def message(%__MODULE__{code: code, message: msg}), do: "#{code}: #{msg}"

  @doc "全部已知错误码原子（用于测试/文档）。"
  @spec codes() :: [atom()]
  def codes, do: Map.keys(@table)
end
