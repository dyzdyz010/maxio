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
  | `/minio/admin/v3/add-canned-policy` | PUT | `admin:CreatePolicy` | 200 空 body |
  | `/minio/admin/v3/list-canned-policies` | GET | `admin:ListUserPolicies` | 200 明文 JSON |
  | `/minio/admin/v3/info-canned-policy` | GET | `admin:GetPolicy` | 200 明文 JSON |
  | `/minio/admin/v3/remove-canned-policy` | DELETE | `admin:DeletePolicy` | 200 空 body |
  | `/minio/admin/v3/user-info` | GET | `admin:GetUser` | 200 明文 JSON `UserInfo` |

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

  alias Maxio.Admin.{
    Authz,
    ErrorMap,
    ErrorView,
    PolicyAdapter,
    PolicyRequest,
    ServerInfo,
    UserAdapter
  }

  alias Maxio.S3.{Error, Log, PipelineOrderError, RawPath, ReservedNamespace}

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{maxio_surface: :admin}} = conn, _opts), do: handle(conn)
  def call(%{assigns: %{maxio_surface: :s3}} = conn, _opts), do: conn

  def call(conn, _opts) do
    if ReservedNamespace.admin_path?(conn.request_path || "") do
      raise PipelineOrderError,
            "admin surface requires assigns.maxio_surface; mount " <>
              "Maxio.S3.Plugs.SurfaceClassifier after Maxio.S3.Plugs.AddressStyle and before " <>
              "Maxio.Admin.Plug"
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
      conn = fetch_query_params(conn)
      dispatch(conn, conn.method, RawPath.decoded_path(conn))
    else
      render_error(conn, Error.new(:access_denied))
    end
  end

  # madmin 的 ServerInfo 硬编码打 v3（实测 mc RELEASE.2025-08-13）。
  defp dispatch(conn, "GET", "/minio/admin/v3/info"), do: server_info(conn)

  defp dispatch(conn, "PUT", "/minio/admin/v3/add-canned-policy"),
    do: create_policy(conn)

  defp dispatch(conn, "GET", "/minio/admin/v3/list-canned-policies"),
    do: list_policies(conn)

  defp dispatch(conn, "GET", "/minio/admin/v3/info-canned-policy"),
    do: policy_info(conn)

  defp dispatch(conn, "DELETE", "/minio/admin/v3/remove-canned-policy"),
    do: remove_policy(conn)

  defp dispatch(conn, "GET", "/minio/admin/v3/user-info"), do: user_info(conn)

  defp dispatch(conn, _method, path) do
    render_not_implemented(conn, path)
  end

  defp create_policy(conn) do
    authorize_and_run(conn, "admin:CreatePolicy", "admin_policy_create", fn conn ->
      {conn, body} = PolicyRequest.read_add_body!(conn)

      case PolicyAdapter.create(conn.query_params["name"], body) do
        {:ok, _policy} -> send_empty_success(conn)
        {:error, reason} -> render_error(conn, ErrorMap.from_reason(reason))
      end
    end)
  end

  defp list_policies(conn) do
    authorize_and_run(conn, "admin:ListUserPolicies", "admin_policy_list", fn conn ->
      if Map.has_key?(conn.query_params, "bucket") do
        render_not_implemented(conn, RawPath.decoded_path(conn))
      else
        {:ok, %{policies: policies, omitted: omitted}} = PolicyAdapter.list()

        if omitted != [] do
          Log.info("non-root policies omitted from MinIO admin view",
            action: "admin_policy_list",
            admin_action: "admin_policy_list",
            omitted_non_root_path_policies: length(omitted),
            request_id: request_id(conn),
            surface: conn.assigns[:maxio_surface]
          )
        end

        send_json(conn, policies)
      end
    end)
  end

  defp policy_info(conn) do
    authorize_and_run(conn, "admin:GetPolicy", "admin_policy_info", fn conn ->
      case conn.query_params["v"] do
        version when version in [nil, "", "2"] -> policy_info(conn, version)
        _unsupported -> render_error(conn, Error.new(:admin_invalid_argument))
      end
    end)
  end

  defp policy_info(conn, version) do
    case PolicyAdapter.info(conn.query_params["name"]) do
      {:ok, info} when version == "2" -> send_json(conn, info)
      {:ok, info} -> send_json(conn, info["Policy"])
      {:error, reason} -> render_error(conn, ErrorMap.from_reason(reason))
    end
  end

  defp remove_policy(conn) do
    authorize_and_run(conn, "admin:DeletePolicy", "admin_policy_remove", fn conn ->
      case PolicyAdapter.remove(conn.query_params["name"]) do
        :ok -> send_empty_success(conn)
        {:error, reason} -> render_error(conn, ErrorMap.from_reason(reason))
      end
    end)
  end

  defp user_info(conn) do
    authorize_and_run(
      conn,
      "admin:GetUser",
      "admin_user_info",
      [target_user: conn.query_params["accessKey"]],
      fn conn ->
        case UserAdapter.info(conn.query_params["accessKey"]) do
          {:ok, result} ->
            log_user_info_projection(conn, result.evidence)
            send_json(conn, result.wire)

          {:error, reason} ->
            render_error(conn, ErrorMap.from_reason(reason))
        end
      end
    )
  end

  defp log_user_info_projection(conn, evidence) do
    metadata =
      user_info_log_metadata(conn, evidence)

    Log.info("admin user info projected", metadata)

    if evidence.direct_managed.omitted_names != [] do
      Log.warn("ambiguous direct managed policy omitted from MinIO UserInfo", metadata)
    end
  end

  defp user_info_log_metadata(conn, evidence) do
    [
      action: "admin_user_info",
      admin_action: "admin_user_info",
      target_user: conn.query_params["accessKey"],
      credential_bearing: evidence.credential_bearing,
      managed_policies: evidence.direct_managed.count,
      inline_policies: evidence.direct_inline.count,
      group_inherited: evidence.group_inline.count + evidence.group_managed.count,
      role_attached: evidence.role_managed.count,
      minio_view_partial: evidence.minio_view_partial,
      omitted_reason: Enum.join(evidence.omitted_reason, ","),
      request_id: request_id(conn),
      surface: conn.assigns[:maxio_surface]
    ]
  end

  defp authorize_and_run(conn, required_action, admin_action, callback) do
    authorize_and_run(conn, required_action, admin_action, [], callback)
  end

  defp authorize_and_run(conn, required_action, admin_action, target_metadata, callback) do
    metadata =
      admin_log_metadata(conn, required_action, admin_action, target_metadata)

    case Authz.authorize(conn, conn.assigns[:principal], required_action) do
      :ok ->
        Log.info("admin request authorized", [{:decision, "allow"} | metadata])
        callback.(conn)

      {:error, reason} ->
        Log.warn("admin request denied", [
          {:decision, "deny"},
          {:reason, to_string(reason)}
          | metadata
        ])

        render_error(conn, Error.new(:access_denied))
    end
  end

  defp admin_log_metadata(conn, required_action, admin_action, target_metadata) do
    base = [
      action: admin_action,
      admin_action: admin_action,
      admin_endpoint: RawPath.decoded_path(conn),
      required_action: required_action,
      method: conn.method,
      resource: RawPath.decoded_path(conn),
      request_id: request_id(conn),
      auth_type: conn.assigns[:auth_type],
      principal_arn: principal_arn(conn),
      surface: conn.assigns[:maxio_surface]
    ]

    default_target =
      if String.starts_with?(admin_action, "admin_policy_") do
        [target_policy: conn.query_params["name"]]
      else
        []
      end

    target_metadata ++ default_target ++ base
  end

  defp send_json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode_to_iodata!(body))
    |> halt()
  end

  defp send_empty_success(conn), do: conn |> send_resp(200, "") |> halt()

  defp render_not_implemented(conn, path) do
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
