defmodule Maxio.S3.Endpoint do
  @moduledoc """
  S3 兼容 HTTP API 的顶层 Plug 管线（独立于 Console 的 MaxioWeb.Endpoint）。
  绝不挂 Plug.Parsers——对象 body 由 handler 经 read_body 流式拉取（铁律 4）。
  顺序：RequestId → AddressStyle（寻址）→ SigV4（鉴权）→ Dispatch（分发到 handler）。
  """
  use Plug.Builder

  plug Plug.RequestId
  plug Maxio.S3.Plugs.AddressStyle
  plug Maxio.S3.Plugs.SigV4
  plug Maxio.S3.Plugs.Dispatch
end
