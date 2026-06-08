defmodule Maxio.S3.Handlers do
  @moduledoc """
  Handler 分发门面。E6 占位：所有 action 暂返回 NotImplemented（管线骨架先跑通）。
  E7 替换为真实 Service/Bucket/Object handler 分发。
  """
  alias Maxio.S3.Error

  @spec dispatch(atom(), Plug.Conn.t()) :: Plug.Conn.t()
  def dispatch(_action, _conn) do
    raise Error.new(:not_implemented)
  end
end
