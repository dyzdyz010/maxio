defmodule Maxio.S3.Handlers do
  @moduledoc """
  Handler 分发门面：按 Dispatcher 解析出的 action 调对应 Service/Bucket/Object handler。
  M1 授权 stub：principal.type == :root 全权放行（非 root 当前不会出现，留接口）。
  """
  alias Maxio.S3.Handlers.{Service, Bucket, Object, Multipart, BucketPolicy, Acl, Versioning}

  @spec dispatch(atom(), Plug.Conn.t()) :: Plug.Conn.t()
  def dispatch(:list_buckets, conn), do: Service.list_buckets(conn)

  def dispatch(:create_bucket, conn), do: Bucket.create(conn)
  def dispatch(:delete_bucket, conn), do: Bucket.delete(conn)
  def dispatch(:head_bucket, conn), do: Bucket.head(conn)
  def dispatch(:list_objects_v2, conn), do: Bucket.list_objects_v2(conn)
  def dispatch(:get_bucket_location, conn), do: Bucket.get_location(conn)

  def dispatch(:put_object, conn), do: Object.put(conn)
  def dispatch(:get_object, conn), do: Object.get(conn)
  def dispatch(:head_object, conn), do: Object.head(conn)
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
end
