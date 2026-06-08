defmodule Maxio.S3.Handlers do
  @moduledoc """
  Handler 分发门面：按 Dispatcher 解析出的 action 调对应 Service/Bucket/Object handler。
  M1 授权 stub：principal.type == :root 全权放行（非 root 当前不会出现，留接口）。

  E7（第一半）：SERVICE + BUCKET action 已接真实 handler；Object action（put/get/head/delete）
  暂返回 NotImplemented，待 E7b（BodyReader + Object handler）落地。
  """
  alias Maxio.S3.Error
  alias Maxio.S3.Handlers.{Service, Bucket}

  @object_actions [:put_object, :get_object, :head_object, :delete_object]

  @spec dispatch(atom(), Plug.Conn.t()) :: Plug.Conn.t()
  def dispatch(:list_buckets, conn), do: Service.list_buckets(conn)

  def dispatch(:create_bucket, conn), do: Bucket.create(conn)
  def dispatch(:delete_bucket, conn), do: Bucket.delete(conn)
  def dispatch(:head_bucket, conn), do: Bucket.head(conn)
  def dispatch(:list_objects_v2, conn), do: Bucket.list_objects_v2(conn)
  def dispatch(:get_bucket_location, conn), do: Bucket.get_location(conn)

  def dispatch(action, _conn) when action in @object_actions do
    raise Error.new(:not_implemented)
  end
end
