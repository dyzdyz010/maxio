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

  ## 已实现的端点

  | 路径 | 方法 | admin action | 响应 |
  |---|---|---|---|
  | `/minio/admin/v3/info` | GET | `admin:ServerInfo` | 200 明文 JSON `InfoMessage` |

  其余一切 `/minio/admin/*`（含 `/minio/admin/v4/*`）落 501 `NotImplemented`(JSON)；
  匿名请求一律 403 `AccessDenied`(JSON)。

  501 而非 404 是刻意的（设计 §9.2）：运维必须看到"该功能未实现"，而不是"路径不存在"
  ——后者会把人引向版本/路径的无效排查（铁律 3：绝不用一个误导性的状态码掩盖真相）。
  `/minio/admin/v4/*` 同样落 501（本批不做 v4→426 回落：实测当前 mc 的 madmin 硬编码
  打 v3，做了无法活体验证，绝不实现无法取证的分支）。

  ## 为什么鉴权判定在路由**之前**

  未认证请求无论打哪条路径都是 403，不是 501。反过来（先路由再鉴权）会让匿名请求从
  501 的措辞里读出"这个端点存在/不存在"，把管控面的实现进度泄露给未认证方；而且
  "未认证"是比"未实现"更根本的拒绝理由，先报它才对得上因果。
  """

  import Plug.Conn

  alias Maxio.Admin.{Authz, ErrorView, ServerInfo}
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

  defp route(conn) do
    if authenticated?(conn) do
      dispatch(conn, conn.method, RawPath.decoded_path(conn))
    else
      render_error(conn, Error.new(:access_denied))
    end
  end

  # madmin 的 ServerInfo 硬编码打 v3（实测 mc RELEASE.2025-08-13）。
  defp dispatch(conn, "GET", "/minio/admin/v3/info"), do: server_info(conn)

  defp dispatch(conn, _method, path) do
    render_error(
      conn,
      Error.new(:not_implemented,
        message: "The MinIO admin API endpoint #{path} is not implemented by maxio."
      )
    )
  end

  defp server_info(conn) do
    case Authz.authorize(conn, conn.assigns[:principal], "admin:ServerInfo") do
      :ok ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode_to_iodata!(server_info_body(conn)))
        |> halt()

      {:error, reason} ->
        Log.warn("admin server info denied",
          action: "admin_server_info",
          required_action: "admin:ServerInfo",
          decision: "deny",
          reason: to_string(reason),
          method: conn.method,
          resource: RawPath.decoded_path(conn),
          auth_type: conn.assigns[:auth_type],
          principal_arn: principal_arn(conn)
        )

        render_error(conn, Error.new(:access_denied))
    end
  end

  # VERIFY-AT-IMPL V-A13：madmin **v3** 的 ServerInfo() 是否也发 `no-cache` query 未抓包核实
  # （v4 确定发；实测 mc RELEASE.2025-08-13 打的是 `/minio/admin/v3/info?metrics=false`）。
  # 无论它发不发，服务端支持这个参数都是正确的：收到就绕过 usage / 盘容量的短 TTL 快照，
  # 这个参数存在的全部意义就是"我要最新的，别给我缓存的"。
  defp server_info_body(conn) do
    conn = fetch_query_params(conn)

    ServerInfo.build(
      no_cache: no_cache?(conn),
      host: conn.host,
      scheme: conn.scheme
    )
  end

  defp no_cache?(conn) do
    case conn.query_params["no-cache"] do
      nil -> false
      value -> String.downcase(to_string(value)) not in ["false", "0", ""]
    end
  end

  defp principal_arn(conn) do
    case conn.assigns[:principal] do
      %{arn: arn} -> arn
      _other -> nil
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
