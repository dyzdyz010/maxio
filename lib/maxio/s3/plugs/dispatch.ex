defmodule Maxio.S3.Plugs.Dispatch do
  @moduledoc """
  分发 plug：用 assigns 的 s3_level + conn.method + query 子资源 key 调 Dispatcher.resolve/3，
  得 action 后交 Maxio.S3.Handlers.dispatch/2。统一 try/rescue %Maxio.S3.Error{} → ErrorView，
  绝不静默 500（未预期异常也包成 InternalError 并打 error 日志，铁律 3）。
  """
  import Plug.Conn
  alias Maxio.S3.{Dispatcher, Error, ErrorView, Handlers, Log, RawPath}

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Maxio.S3.InFlight.track(fn -> do_call(conn) end)
  end

  defp do_call(conn) do
    conn = fetch_query_params(conn)

    try do
      case Dispatcher.resolve(conn.assigns.s3_level, conn.method, conn.query_params) do
        {:ok, action} ->
          conn = assign(conn, :s3_action, action)
          :ok = Maxio.S3.Authz.authorize(conn, action)
          Handlers.dispatch(action, conn)

        {:error, reason} ->
          raise Error.new(reason)
      end
    rescue
      err in Maxio.S3.Error ->
        render_error(conn, err)

      other ->
        # 完整异常 message 只进服务端日志，绝不进客户端 XML——File.Error 等的 message 内嵌
        # 服务器绝对盘路径（data_dir），曾沿 <Message> 序列化给客户端（信息泄露）。客户端只见
        # 通用 InternalError 文案（与 MinIO 一致：内部错误细节永不出现在 S3 错误响应里）。
        Log.error("unhandled exception in dispatch",
          code: "InternalError",
          status: 500,
          reason: Exception.message(other)
        )

        render_error(conn, Error.new(:internal_error))
    end
  end

  defp render_error(conn, %Error{} = err) do
    request_id = conn |> get_req_header("x-request-id") |> List.first()

    # resource 用原始解码路径（保留尾/连续/前导斜杠），与 SigV4 CanonicalURI 一致，不用 path_info。
    resource = RawPath.decoded_path(conn)
    err = %{err | request_id: request_id, resource: err.resource || resource}
    {status, body} = ErrorView.render(err)

    Log.warn("s3 error response",
      code: err.code,
      status: status,
      bucket: conn.assigns[:s3_bucket],
      key: conn.assigns[:s3_key]
    )

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, body)
  end
end
