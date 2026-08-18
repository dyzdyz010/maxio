defmodule Maxio.Admin.Plug do
  @moduledoc """
  MinIO 管控面（`/minio/admin/*`）骨架 plug。

  ## 挂载点：SigV4 **之后**、Dispatch **之前**（设计 D7）

    * 必须在 SigV4 之后——admin 面需要 `conn.assigns.principal`（madmin 的请求是 SigV4
      签名的，service 名同样是 `s3`，credential scope 的 region 段为空串，maxio 现有
      验签路径原样通过，签名层零改动）。
    * 必须在 Dispatch 之前——否则 path-style 会把 `/minio/admin/v3/info` 误判成
      "桶 minio + key admin/v3/info"，返回 S3 XML `NoSuchBucket`。madmin 只解 JSON，
      拿到 XML 后只会显示 "The specified bucket does not exist."，把"管控面未接入"
      伪装成"桶不存在"——这正是接入前的实测症状。

  认领判定经 `ReservedNamespace.claimed?/2`：路径匹配之外还要求寻址结果指向**服务器根
  命名空间**。vhost 下 `Host: <bucket>.<domain>` + `GET /minio/admin/v3/info` 说的是桶
  `<bucket>` 里 key 为 `minio/admin/v3/info` 的对象；管控面若把它认领掉，客户端会拿到
  admin JSON 而不是自己的对象——静默数据劫持（铁律 3）。

  ## 本批范围

  **不实现任何真实 admin 端点**：认证通过的请求一律 501 `NotImplemented`(JSON)，
  匿名请求 403 `AccessDenied`(JSON)。

  501 而非 404 是刻意的（设计 §9.2）：运维必须看到"该功能未实现"，而不是"路径不存在"
  ——后者会把人引向版本/路径的无效排查（铁律 3：绝不用一个误导性的状态码掩盖真相）。
  `/minio/admin/v4/*` 同样落 501（本批不做 v4→426 回落：实测当前 mc 的 madmin 硬编码
  打 v3，做了无法活体验证，绝不实现无法取证的分支）。

  真实端点接入后，本 plug 的 `route/1` 会按路径分发到 handler，并由 handler 层做
  per-endpoint 的 admin action 授权（`admin:ServerInfo` 等，复用 `Maxio.Policy.Evaluator`，
  对齐 `Maxio.S3.PrometheusAuthz`）；`try/rescue` 结构与错误契约此刻已就位，不必再改。
  """

  import Plug.Conn

  alias Maxio.Admin.ErrorView
  alias Maxio.S3.{Error, Log, PipelineOrderError, RawPath, ReservedNamespace}

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if ReservedNamespace.claimed?(conn, :admin) do
      handle(conn)
    else
      conn
    end
  end

  defp handle(conn) do
    try do
      route(conn)
    rescue
      err in Maxio.S3.Error ->
        render_error(conn, err)

      err in PipelineOrderError ->
        # 管线顺序错误是**部署期构造错误**，绝不能被下面的通用 500 兜底吞成一条与偶发
        # InternalError 无法区分的日志——那样"顺序错了要立刻可见"这个意图就只剩一句
        # 语义模糊的 warning。原样上抛 → OTP crash report（含 stacktrace），客户端仍是
        # 500 且细节不变（见 Maxio.S3.PipelineOrderError）。
        reraise err, __STACKTRACE__

      other ->
        # 完整异常 message 只进服务端日志，绝不进客户端 JSON（内部路径/密钥绝不外泄）——
        # 逐字继承 Maxio.S3.Plugs.Dispatch 的纪律。
        Log.error("unhandled exception in admin api",
          code: "InternalError",
          status: 500,
          method: conn.method,
          resource: RawPath.decoded_path(conn),
          reason: Exception.message(other)
        )

        render_error(conn, Error.new(:internal_error))
    end
  end

  # 本批唯一的"路由"：认证通过 → 501；匿名 → 403。两者都是结构化 JSON 错误，绝不静默。
  defp route(conn) do
    if authenticated?(conn) do
      render_error(
        conn,
        Error.new(:not_implemented,
          message:
            "The MinIO admin API endpoint #{RawPath.decoded_path(conn)} is not implemented by maxio."
        )
      )
    else
      render_error(conn, Error.new(:access_denied))
    end
  end

  # "已认证"取 SigV4 自己写下的 `:auth_type`，**显式**排除 `:anonymous`——绝不改用
  # `is_map(principal)` 之类的形状推断：SigV4 若哪天把匿名 principal 从原子 `:anonymous`
  # 换成 map 形状，形状推断会让匿名请求静默走进 501（看起来像"功能未实现"，实则鉴权
  # 判定失灵），而显式匹配在同样的改动下仍然正确（铁律 3）。
  # assign 缺失 = 本 plug 被挂到了 SigV4 之前，管线顺序错了必须立刻可见，绝不当成匿名。
  defp authenticated?(conn) do
    case Map.fetch(conn.assigns, :auth_type) do
      {:ok, :anonymous} ->
        false

      {:ok, _auth_type} ->
        conn.assigns[:principal] != :anonymous

      :error ->
        raise PipelineOrderError,
              "admin surface requires assigns.auth_type; mount Maxio.Admin.Plug after " <>
                "Maxio.S3.Plugs.SigV4"
    end
  end

  defp render_error(conn, %Error{} = err) do
    err = %{
      err
      | request_id: err.request_id || request_id(conn),
        resource: err.resource || RawPath.decoded_path(conn)
    }

    {status, body} = ErrorView.render(err)

    Log.warn("admin api error response",
      code: err.code,
      status: status,
      method: conn.method,
      resource: err.resource,
      request_id: err.request_id,
      auth_type: conn.assigns[:auth_type]
    )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  # Plug.RequestId 把 id 写进 **响应**头（并进 Logger metadata），客户端自带时才有请求头；
  # 两处都读，保证 admin 错误体里的 RequestId 与访问日志能对上。
  defp request_id(conn) do
    case get_resp_header(conn, "x-request-id") do
      [id | _] -> id
      [] -> conn |> get_req_header("x-request-id") |> List.first()
    end
  end
end
