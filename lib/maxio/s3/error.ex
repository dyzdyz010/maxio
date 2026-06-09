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
    no_such_upload: {"NoSuchUpload", 404, "The specified multipart upload does not exist."},
    access_denied: {"AccessDenied", 403, "Access Denied"},
    signature_does_not_match:
      {"SignatureDoesNotMatch", 403,
       "The request signature that the server calculated does not match the signature that you provided. Check your AWS secret access key and signing method."},
    invalid_access_key_id:
      {"InvalidAccessKeyId", 403,
       "The AWS access key ID that you provided does not exist in our records."},
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
    invalid_tag:
      {"InvalidTag", 400,
       "The tag provided was not a valid tag. This error can occur if the tag did not pass input validation."},
    invalid_bucket_name: {"InvalidBucketName", 400, "The specified bucket is not valid."},
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
    slow_down:
      {"SlowDown", 503,
       "Please reduce your request rate."},
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
    access_forbidden:
      {"AccessForbidden", 403,
       "CORSResponse: This CORS request is not allowed. This is usually because the evaluation of Origin, request method / Access-Control-Request-Method or Access-Control-Request-Headers are not whitelisted."},
    no_such_cors_configuration:
      {"NoSuchCORSConfiguration", 404, "The CORS configuration does not exist."},
    no_such_lifecycle_configuration:
      {"NoSuchLifecycleConfiguration", 404, "The lifecycle configuration does not exist."},
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
