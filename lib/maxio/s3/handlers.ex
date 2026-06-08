defmodule Maxio.S3.Handlers do
  @moduledoc """
  Handler 分发门面：按 Dispatcher 解析出的 action 调对应 Service/Bucket/Object handler。
  M1 授权 stub：principal.type == :root 全权放行（非 root 当前不会出现，留接口）。
  """
  alias Maxio.S3.Handlers.{Service, Bucket, Object}

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
end
