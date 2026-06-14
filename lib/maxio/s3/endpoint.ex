defmodule Maxio.S3.Endpoint do
  @moduledoc """
  S3 兼容 HTTP API 的顶层 Plug 管线（独立于 Console 的 MaxioWeb.Endpoint）。
  绝不挂 Plug.Parsers——对象 body 由 handler 经 read_body 流式拉取（铁律 4）。
  顺序：RequestId → RequestLimits（请求头/元数据大小闸）→ AddressStyle（寻址）→
  Cors（预检拦截 / 实际注入）→ SigV4（鉴权）→ Dispatch（分发）。
  CORS OPTIONS 预检不签名：Cors plug 命中预检即 halt，不进 SigV4。
  """
  use Plug.Builder

  plug Plug.RequestId
  plug Maxio.S3.Plugs.RequestLimits
  plug Maxio.S3.Plugs.AddressStyle
  plug Maxio.S3.Plugs.Cors
  plug Maxio.S3.Plugs.SigV4
  plug Maxio.STS.QueryPlug
  plug Maxio.S3.Plugs.Dispatch
end
