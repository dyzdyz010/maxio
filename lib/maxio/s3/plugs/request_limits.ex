defmodule Maxio.S3.Plugs.RequestLimits do
  @moduledoc """
  S3 请求入口级限制 plug。

  对齐 MinIO `setRequestLimitMiddleware` 的请求头闸：请求头完整 key+value 总量超过 8 KiB，
  或用户元数据（`x-amz-meta-*` / `x-minio-meta-*`）完整 key+value 总量超过 2 KiB，
  统一返回 `MetadataTooLarge`(400) 并 halt。该 plug 不读取 body，保持对象上传流式契约。
  """

  import Plug.Conn
  alias Maxio.S3.{Error, ErrorView, Log, RawPath}

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    try do
      :ok = Maxio.Metadata.validate_headers!(conn.req_headers)
      conn
    rescue
      err in Maxio.S3.Error ->
        reject(conn, err)
    end
  end

  defp reject(conn, %Error{} = err) do
    request_id = conn |> get_req_header("x-request-id") |> List.first()
    err = %{err | request_id: request_id, resource: RawPath.decoded_path(conn)}
    {status, body} = ErrorView.render(err)

    Log.warn("s3 request limits rejected", code: err.code, status: status)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, body)
    |> halt()
  end
end
