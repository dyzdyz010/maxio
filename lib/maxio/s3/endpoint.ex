defmodule Maxio.S3.Endpoint do
  @moduledoc """
  S3 兼容 HTTP API 的顶层 Plug 管线（独立于 Console 的 MaxioWeb.Endpoint）。
  绝不挂 Plug.Parsers——对象 body 由 handler 经 read_body 流式拉取（铁律 4）。
  顺序：RequestId → RequestLimits（请求头/元数据大小闸）→ AddressStyle（寻址）→
  MinioHealth（探针，匿名放行）→ PrometheusMetrics（MinIO metrics 路径拦截 +
  bearer/admin:Prometheus 鉴权）→ SurfaceClassifier（控制面分类）→
  Cors（预检拦截 / 实际注入）→ SigV4（鉴权）→
  Admin（管控面）→ Dispatch（分发）。
  CORS OPTIONS 预检不签名：Cors plug 命中预检即 halt，不进 SigV4。

  ## MinIO 保留路径面（`/minio/...`）的两条排序约束

  1. **全部晚于 `AddressStyle`**：保留面只在 path-style（桶名来自路径而非 Host）下才等于
     "服务器根命名空间"。vhost 下 `Host: <bucket>.<domain>` + `GET /minio/health/live`
     指的是桶 `<bucket>` 里 key 为 `minio/health/live` 的对象；只看 `request_path` 就认领
     会把任意桶的这批 key 静默劫持（探针返回 200 空 body，比报错更危险——备份工具会当成
     合法空对象）。认领判定统一走 `ReservedNamespace.claimed?/2`，读 AddressStyle 写下的
     `:s3_address_style`，绝不各自再解析一遍 Host（铁律 1）。
  2. **health / metrics 早于 SigV4，admin 晚于 SigV4**（设计 D7）：健康探针不带凭据，
     若晚于 SigV4，一份坏凭据就让探针误报服务已死；admin 面需要 principal，必须晚于
     SigV4，又必须早于 Dispatch（否则 `/minio/admin/...` 被判成桶 minio 的对象，返回 XML）。

  health / metrics 仍排在 `RequestMetrics` / `AccessLogDelivery` **之前**。admin 面虽然为了
  principal 仍在 SigV4 之后处理，但 `SurfaceClassifier` 会在两个 S3 observer 之前把真正的
  path-style admin 请求标成控制面；observer 据此跳过它们。普通 S3 与 vhost 下同路径对象
  仍标成 `:s3`，保留原有统计与访问日志语义。
  """
  use Plug.Builder

  plug Plug.RequestId
  plug Maxio.S3.Plugs.RequestLimits
  plug Maxio.S3.Plugs.AddressStyle
  plug Maxio.S3.Plugs.MinioHealth
  plug Maxio.S3.Plugs.PrometheusMetrics
  plug Maxio.S3.Plugs.SurfaceClassifier
  plug Maxio.S3.Plugs.RequestMetrics
  plug Maxio.S3.Plugs.AccessLogDelivery
  plug Maxio.S3.Plugs.WebsiteEndpoint
  plug Maxio.S3.Plugs.Cors
  plug Maxio.S3.Plugs.PostObject
  plug Maxio.S3.Plugs.SigV4
  plug Maxio.Admin.Plug
  plug Maxio.IAM.QueryPlug
  plug Maxio.STS.QueryPlug
  plug Maxio.S3.Plugs.Dispatch
end
