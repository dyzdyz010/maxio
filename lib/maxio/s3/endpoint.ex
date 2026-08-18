defmodule Maxio.S3.Endpoint do
  @moduledoc """
  S3 兼容 HTTP API 的顶层 Plug 管线（独立于 Console 的 MaxioWeb.Endpoint）。
  绝不挂 Plug.Parsers——对象 body 由 handler 经 read_body 流式拉取（铁律 4）。
  顺序：RequestId → RequestLimits（请求头/元数据大小闸）→ AddressStyle（寻址）→
  MinioHealth（探针，匿名放行）→ PrometheusMetrics（MinIO metrics 路径拦截 +
  bearer/admin:Prometheus 鉴权）→ Cors（预检拦截 / 实际注入）→ SigV4（鉴权）→
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

  health / metrics 仍排在 `RequestMetrics` / `AccessLogDelivery` **之前**，保持这两个面对
  数据面统计不可见的既有语义（改这一点是独立议题，不在本批）。

  ## 三个保留面在观测口径上的确切归属（M-5，读指标前必读）

  `admin` 面必须晚于 SigV4（需要 principal），而 `RequestMetrics` / `AccessLogDelivery`
  在 SigV4 **之前**，因此三个面的观测口径不一致，且 admin 那一份是**带偏差**的：

  | 面 | 位置 | RequestMetrics / 访问日志 | 计入的 bucket |
  |---|---|---|---|
  | health（`/minio/health/*`） | RequestMetrics 之前 | **不计** | —— |
  | metrics（`/minio/v2/metrics*`、`/minio/metrics/v3*`） | RequestMetrics 之前 | **不计** | —— |
  | admin（`/minio/admin/*`） | RequestMetrics 之后 | **计入** | **`minio`** |

  admin 请求为什么会被记成 `bucket="minio"`：`AddressStyle` 早于所有保留面运行，它按
  path-style 把 `/minio/admin/v3/info` 逐字切成 `s3_bucket="minio"` + `s3_key="admin/v3/info"`
  （这正是保留面存在的原因——两者在 path-style 下逐字重合），而 `RequestMetrics` 读的就是
  这两个 assign。于是**管控面流量会混进名为 `minio` 的桶的数据面指标与访问日志**。

  口径是刻意先记下来而不是马上改：把 admin 挪到 RequestMetrics 之前会丢掉 principal，
  把 RequestMetrics 挪到 SigV4 之后会改变**全部** S3 流量的既有统计语义（含未签名/被拒
  请求），两者都远超本批范围。读指标时必须知道：`bucket="minio"` 的计数**不等于**该桶的
  对象操作量。修正方案（给 admin 面单独的指标维度、或让保留面 plug 显式改写 `:s3_bucket`
  为 `nil` + 面标签）另立一批。
  """
  use Plug.Builder

  plug Plug.RequestId
  plug Maxio.S3.Plugs.RequestLimits
  plug Maxio.S3.Plugs.AddressStyle
  plug Maxio.S3.Plugs.MinioHealth
  plug Maxio.S3.Plugs.PrometheusMetrics
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
