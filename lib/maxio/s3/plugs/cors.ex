defmodule Maxio.S3.Plugs.Cors do
  @moduledoc """
  CORS plug（铁律 3/4：绝不破坏流式/SigV4；预检不签名）。位于 AddressStyle 之后、SigV4 之前。
    * OPTIONS 预检（带 Origin + Access-Control-Request-Method）：查桶 CORS 配置，first-match：
        命中 → 200 + CORS 响应头并 halt（不进 SigV4/Dispatch；预检无需鉴权）；
        未启用/无匹配 → 403 AccessForbidden 并 halt（绝不静默放行）。
        无 Origin 的 OPTIONS（非预检）→ 放行给下游（罕见）。
    * 非 OPTIONS 带 Origin：first-match → 注册 before_send 在响应上注入 ACAO/ACAM/ACEH + Vary；
      不 halt（继续 SigV4/Dispatch 正常处理）。无匹配 → 不注入（正常处理）。
  Vary: Origin（+ 预检的 AC-Request-* ）防共享缓存串味（铁律 5）。
  """
  import Plug.Conn
  alias Maxio.{BucketConfigs, Cors}
  alias Maxio.S3.{Error, ErrorView, Log}

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    origin = header(conn, "origin")

    cond do
      conn.method == "OPTIONS" and origin != nil ->
        handle_preflight(conn, origin)

      origin != nil ->
        handle_actual(conn, origin)

      true ->
        conn
    end
  end

  defp handle_preflight(conn, origin) do
    bucket = conn.assigns[:s3_bucket]
    req_method = header(conn, "access-control-request-method") || ""
    req_headers = parse_req_headers(header(conn, "access-control-request-headers"))

    with bkt when is_binary(bkt) <- bucket,
         {:ok, rules} <- BucketConfigs.get(bkt, :cors),
         {:ok, rule} <- Cors.match_preflight(rules, origin, req_method, req_headers) do
      Log.info("cors preflight allow", action: :cors_preflight, bucket: bkt)

      conn
      |> put_preflight_headers(rule, origin, req_method, req_headers)
      |> put_resp_header("content-length", "0")
      |> put_vary_preflight()
      |> send_resp(200, "")
      |> halt()
    else
      _ ->
        reject_cors(conn)
    end
  end

  defp handle_actual(conn, origin) do
    bucket = conn.assigns[:s3_bucket]

    with bkt when is_binary(bkt) <- bucket,
         {:ok, rules} <- BucketConfigs.get(bkt, :cors),
         {:ok, rule} <- Cors.match_actual(rules, origin, conn.method) do
      register_before_send(conn, fn c ->
        c
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("access-control-allow-methods", conn.method)
        |> put_expose_headers(rule)
        |> put_resp_header("vary", "Origin")
      end)
    else
      _ -> conn
    end
  end

  defp put_preflight_headers(conn, rule, origin, req_method, req_headers) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-methods", req_method)
    |> put_allow_headers(req_headers)
    |> put_max_age(rule)
    |> put_expose_headers(rule)
  end

  defp put_allow_headers(conn, []), do: conn

  defp put_allow_headers(conn, req_headers),
    do: put_resp_header(conn, "access-control-allow-headers", Enum.join(req_headers, ", "))

  defp put_max_age(conn, %{"max_age_seconds" => n}) when is_integer(n),
    do: put_resp_header(conn, "access-control-max-age", Integer.to_string(n))

  defp put_max_age(conn, _), do: conn

  defp put_expose_headers(conn, %{"expose_headers" => [_ | _] = eh}),
    do: put_resp_header(conn, "access-control-expose-headers", Enum.join(eh, ", "))

  defp put_expose_headers(conn, _), do: conn

  defp put_vary_preflight(conn) do
    put_resp_header(
      conn,
      "vary",
      "Origin, Access-Control-Request-Method, Access-Control-Request-Headers"
    )
  end

  defp reject_cors(conn) do
    err = Error.new(:access_forbidden)
    {status, body} = ErrorView.render(err)
    Log.warn("cors preflight rejected", code: err.code, status: status)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, body)
    |> halt()
  end

  defp parse_req_headers(nil), do: []
  defp parse_req_headers(v), do: v |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()
end
