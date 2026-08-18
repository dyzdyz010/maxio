defmodule Maxio.S3.Plugs.MinioHealth do
  @moduledoc """
  MinIO 风格健康探针：`GET|HEAD /minio/health/live`、`/minio/health/ready` → 200 + 空 body。

  ## 挂载点：AddressStyle 之后、RequestMetrics 与 SigV4 **之前**（设计 D7）

  探针（k8s liveness/readiness、LB、`mc ping`）**不带凭据**。若挂在 SigV4 之后，一份过期
  或畸形的 Authorization 头就会让探针拿到 403 而误报"服务已死"，等于把可用性判断耦合到
  鉴权子系统上——健康的节点会被反复重启。MinIO 自己也把 healthcheck-router 注册在 auth
  middleware 之外（`cmd/healthcheck-router.go` 独立于 adminRouter）。

  但认领判定必须知道**寻址方式**：vhost 下 `Host: <bucket>.<domain>` + `GET /minio/health/live`
  指的是桶 `<bucket>` 里 key 为 `minio/health/live` 的对象，不是探针。故本 plug 挂在
  `AddressStyle` **之后**（AddressStyle 不鉴权、不 halt，探针依旧免鉴权），由
  `ReservedNamespace.claimed?/2` 同时校验路径与寻址结果。自己再解析一遍 Host 会与
  AddressStyle 分裂成两份寻址事实（铁律 1 禁止），故不这么做。

  ## 语义（对齐 minio/cmd/healthcheck-handler.go）

    * `live` —— 不接触任何外部系统；能应答本身就是存活证据。200 空 body。
    * `ready` —— MinIO 的 readiness 只额外探**外部**依赖（KMS、etcd），maxio 当前两者
      皆无外部形态（KMS 是本地 provider，元数据 Repo 是进程内依赖），故与 live 同语义。
      **绝不**把 readiness 绑到 Postgres 可达性上：DB 一次抖动会让所有节点同时被 LB
      摘除，把局部故障放大成整集群不可用（这正是 MinIO 刻意避开存储检查的原因）。
      # VERIFY-AT-IMPL V-H1：接入外部 KMS / 外部一致性存储后，ready 必须开始探它们并在
      # 不可达时返回 5xx；届时须核实 MinIO 的确切状态码与 X-Minio-Server-Status 头语义。

  本批只认领 live / ready 两条；`/minio/health/cluster[/read]`（quorum 语义）不在本批，
  刻意不认领——绝不用一个"永远 200"的假 quorum 答案冒充集群健康判定（铁律 3）。
  """

  import Plug.Conn

  alias Maxio.S3.ReservedNamespace

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if ReservedNamespace.claimed?(conn, :health) do
      respond(conn)
    else
      conn
    end
  end

  defp respond(conn) when conn.method in ["GET", "HEAD"] do
    conn
    |> send_resp(200, "")
    |> halt()
  end

  defp respond(conn) do
    conn
    |> put_resp_header("allow", "GET, HEAD")
    |> put_resp_content_type("text/plain")
    |> send_resp(405, "method not allowed\n")
    |> halt()
  end
end
