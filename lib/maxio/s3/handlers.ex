defmodule Maxio.S3.Handlers do
  @moduledoc """
  Handler 分发门面：按 Dispatcher 解析出的 action 调对应 Service/Bucket/Object handler。
  M1 授权 stub：principal.type == :root 全权放行（非 root 当前不会出现，留接口）。
  """
  alias Maxio.S3.Handlers.{
    Service,
    Bucket,
    Object,
    Multipart,
    BucketPolicy,
    Acl,
    Versioning,
    Tagging,
    Cors,
    Lifecycle,
    Encryption,
    PublicAccessBlock,
    OwnershipControls,
    Website,
    RequestPayment,
    Accelerate,
    Logging,
    Notification
  }

  @spec dispatch(atom(), Plug.Conn.t()) :: Plug.Conn.t()
  def dispatch(:list_buckets, conn), do: Service.list_buckets(conn)

  def dispatch(:create_bucket, conn), do: Bucket.create(conn)
  def dispatch(:delete_bucket, conn), do: Bucket.delete(conn)
  def dispatch(:head_bucket, conn), do: Bucket.head(conn)
  def dispatch(:list_objects, conn), do: Bucket.list_objects(conn)
  def dispatch(:list_objects_v2, conn), do: Bucket.list_objects_v2(conn)
  def dispatch(:list_object_versions, conn), do: Bucket.list_object_versions(conn)
  def dispatch(:get_bucket_location, conn), do: Bucket.get_location(conn)

  def dispatch(:put_object, conn), do: Object.put(conn)
  def dispatch(:get_object, conn), do: Object.get(conn)
  def dispatch(:head_object, conn), do: Object.head(conn)
  def dispatch(:get_object_attributes, conn), do: Object.get_attributes(conn)
  def dispatch(:delete_object, conn), do: Object.delete(conn)
  def dispatch(:delete_objects, conn), do: Object.delete_objects(conn)

  def dispatch(:create_multipart_upload, conn), do: Multipart.create_multipart_upload(conn)
  def dispatch(:upload_part, conn), do: Multipart.upload_part(conn)
  def dispatch(:complete_multipart_upload, conn), do: Multipart.complete_multipart_upload(conn)
  def dispatch(:abort_multipart_upload, conn), do: Multipart.abort_multipart_upload(conn)
  def dispatch(:list_parts, conn), do: Multipart.list_parts(conn)
  def dispatch(:list_multipart_uploads, conn), do: Multipart.list_multipart_uploads(conn)

  def dispatch(:put_bucket_policy, conn), do: BucketPolicy.put(conn)
  def dispatch(:get_bucket_policy, conn), do: BucketPolicy.get(conn)
  def dispatch(:delete_bucket_policy, conn), do: BucketPolicy.delete(conn)

  def dispatch(:get_bucket_acl, conn), do: Acl.get_bucket_acl(conn)
  def dispatch(:put_bucket_acl, conn), do: Acl.put_bucket_acl(conn)
  def dispatch(:get_object_acl, conn), do: Acl.get_object_acl(conn)
  def dispatch(:put_object_acl, conn), do: Acl.put_object_acl(conn)

  def dispatch(:put_bucket_versioning, conn), do: Versioning.put(conn)
  def dispatch(:get_bucket_versioning, conn), do: Versioning.get(conn)

  def dispatch(:put_object_tagging, conn), do: Tagging.put_object_tagging(conn)
  def dispatch(:get_object_tagging, conn), do: Tagging.get_object_tagging(conn)
  def dispatch(:delete_object_tagging, conn), do: Tagging.delete_object_tagging(conn)
  def dispatch(:put_bucket_tagging, conn), do: Tagging.put_bucket_tagging(conn)
  def dispatch(:get_bucket_tagging, conn), do: Tagging.get_bucket_tagging(conn)
  def dispatch(:delete_bucket_tagging, conn), do: Tagging.delete_bucket_tagging(conn)

  def dispatch(:put_bucket_cors, conn), do: Cors.put(conn)
  def dispatch(:get_bucket_cors, conn), do: Cors.get(conn)
  def dispatch(:delete_bucket_cors, conn), do: Cors.delete(conn)

  def dispatch(:put_bucket_lifecycle, conn), do: Lifecycle.put(conn)
  def dispatch(:get_bucket_lifecycle, conn), do: Lifecycle.get(conn)
  def dispatch(:delete_bucket_lifecycle, conn), do: Lifecycle.delete(conn)

  def dispatch(:put_bucket_encryption, conn), do: Encryption.put(conn)
  def dispatch(:get_bucket_encryption, conn), do: Encryption.get(conn)
  def dispatch(:delete_bucket_encryption, conn), do: Encryption.delete(conn)

  def dispatch(:put_public_access_block, conn), do: PublicAccessBlock.put(conn)
  def dispatch(:get_public_access_block, conn), do: PublicAccessBlock.get(conn)
  def dispatch(:delete_public_access_block, conn), do: PublicAccessBlock.delete(conn)

  def dispatch(:put_bucket_ownership_controls, conn), do: OwnershipControls.put(conn)
  def dispatch(:get_bucket_ownership_controls, conn), do: OwnershipControls.get(conn)
  def dispatch(:delete_bucket_ownership_controls, conn), do: OwnershipControls.delete(conn)

  def dispatch(:put_bucket_website, conn), do: Website.put(conn)
  def dispatch(:get_bucket_website, conn), do: Website.get(conn)
  def dispatch(:delete_bucket_website, conn), do: Website.delete(conn)

  def dispatch(:put_bucket_request_payment, conn), do: RequestPayment.put(conn)
  def dispatch(:get_bucket_request_payment, conn), do: RequestPayment.get(conn)

  def dispatch(:put_bucket_accelerate_configuration, conn), do: Accelerate.put(conn)
  def dispatch(:get_bucket_accelerate_configuration, conn), do: Accelerate.get(conn)

  def dispatch(:put_bucket_logging, conn), do: Logging.put(conn)
  def dispatch(:get_bucket_logging, conn), do: Logging.get(conn)

  def dispatch(:put_bucket_notification, conn), do: Notification.put(conn)
  def dispatch(:get_bucket_notification, conn), do: Notification.get(conn)
end
