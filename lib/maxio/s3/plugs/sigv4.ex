defmodule Maxio.S3.Plugs.SigV4 do
  @moduledoc """
  SigV4 鉴权 plug（铁律 3/4）。从 conn 提取签名材料（不消费 body！），调
  `Maxio.Auth.authenticate/1`，成功写 assigns.principal/auth_type/payload_mode；
  失败 halt + S3 Error XML，并打结构化日志（绝不静默放行）。

  分流：
    * query 含 X-Amz-Signature → presigned；
    * 有 Authorization: AWS4-HMAC-SHA256 → header；
    * 否则 MissingSecurityHeader（400）。

  时钟参考（依赖注入）：优先 `conn.private[:maxio_now]`（测试注入固定时刻），
  否则 `DateTime.utc_now()`（生产真实时钟），交由 Maxio.Auth 做偏移/过期判定。
  """
  import Plug.Conn
  alias Maxio.Auth
  alias Maxio.Auth.CredentialStore
  alias Maxio.Auth.SigV4.AuthHeaderParser
  alias Maxio.IAM
  alias Maxio.S3.{Error, ErrorView, Log, RawPath}

  @behaviour Plug

  @console_direct_multipart_signed_only_headers MapSet.new([
                                                  "cache-control",
                                                  "content-disposition",
                                                  "content-encoding",
                                                  "expires"
                                                ])

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    content_sha = header(conn, "x-amz-content-sha256") || ""

    # SigV4A（ECDSA P-256）流式变体早拒 501：它非 HMAC，无法用 kSigning 验 seed/逐块签名。
    if sigv4a_streaming?(content_sha) do
      reject(
        conn,
        Error.new(:not_implemented, message: "SigV4A streaming (ECDSA P-256) not supported")
      )
    else
      do_authenticate(conn)
    end
  end

  defp sigv4a_streaming?(v) do
    v in [
      "STREAMING-AWS4-ECDSA-P256-SHA256-PAYLOAD",
      "STREAMING-AWS4-ECDSA-P256-SHA256-PAYLOAD-TRAILER"
    ]
  end

  defp do_authenticate(conn) do
    case detect_and_parse(conn) do
      :anonymous ->
        conn
        |> assign(:principal, :anonymous)
        |> assign(:auth_type, :anonymous)
        |> assign(:payload_mode, :unsigned)

      {:ok, signed_request} ->
        material = build_material(conn, signed_request)

        case Auth.authenticate(material) do
          {:ok, principal, sig_context} ->
            case validate_console_direct_multipart_scope(conn, signed_request) do
              :ok ->
                record_long_term_access_key_use(conn, principal, signed_request)

                conn
                |> assign(:principal, principal)
                |> assign(:auth_type, signed_request.auth_type)
                |> assign(:payload_mode, signed_request.payload_mode)
                |> assign(:sigv4_signed_headers, signed_request.signed_headers)
                |> assign(:sigv4_signed_request, signed_request)
                |> assign(:sigv4_context, sig_context)

              {:error, %Error{} = err} ->
                reject(conn, err)
            end

          {:error, %Error{} = err} ->
            reject(conn, err)
        end

      {:error, code} ->
        reject(conn, Error.new(code))
    end
  end

  defp detect_and_parse(conn) do
    cond do
      Map.has_key?(conn.query_params, "X-Amz-Signature") ->
        AuthHeaderParser.parse_presigned(conn.query_params)

      auth = get_req_header(conn, "authorization") |> List.first() ->
        amz_date = header(conn, "x-amz-date")
        content_sha = header(conn, "x-amz-content-sha256") || ""
        AuthHeaderParser.parse_header(auth, amz_date, content_sha)

      true ->
        # 完全无凭据（无 Authorization 头 + 无 X-Amz-Signature 查询参数）→ 匿名 principal。
        # 绝不静默放行：仅把放行/拒绝裁决下沉到 Authz/policy 层（默认拒绝、显式 deny 优先）。
        # 注意：坏凭据（有 Authorization 但畸形 / 有 X-Amz-Signature 但缺参）仍走上面两分支硬失败——
        # 匿名只从「凭据完全缺席」推断，绝不从解析失败推断（铁律 3 的精确边界）。
        :anonymous
    end
  end

  defp build_material(conn, sr) do
    {session_token, session_token_source, session_token_error} = extract_session_token(conn, sr)
    sr = %{sr | session_token: session_token, session_token_source: session_token_source}

    payload_hash =
      case sr.auth_type do
        :presigned -> "UNSIGNED-PAYLOAD"
        :header -> header(conn, "x-amz-content-sha256") || ""
      end

    %{
      signed_request: sr,
      method: conn.method,
      path: decoded_path(conn),
      query: signing_query(conn, sr),
      headers: req_headers_lower(conn),
      payload_hash: payload_hash,
      now: now(conn),
      session_token: session_token,
      session_token_source: session_token_source,
      session_token_error: session_token_error
    }
  end

  defp extract_session_token(conn, %{auth_type: :header}) do
    header_token = header(conn, "x-amz-security-token")
    query_token = Map.get(conn.query_params || %{}, "X-Amz-Security-Token")

    cond do
      present?(header_token) and present?(query_token) ->
        {nil, nil, :invalid_request}

      present?(query_token) ->
        {nil, nil, :invalid_request}

      present?(header_token) ->
        {header_token, :header, nil}

      true ->
        {nil, nil, nil}
    end
  end

  defp extract_session_token(conn, %{auth_type: :presigned}) do
    header_token = header(conn, "x-amz-security-token")
    query_token = Map.get(conn.query_params || %{}, "X-Amz-Security-Token")

    cond do
      present?(header_token) and present?(query_token) ->
        {nil, nil, :invalid_request}

      present?(header_token) ->
        {nil, nil, :invalid_request}

      present?(query_token) ->
        {query_token, :query, nil}

      true ->
        {nil, nil, nil}
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp validate_console_direct_multipart_scope(conn, sr) do
    case Map.get(conn.query_params || %{}, "x-maxio-console-direct-multipart") do
      "1" ->
        do_validate_console_direct_multipart_scope(conn, sr)

      _other ->
        :ok
    end
  end

  defp do_validate_console_direct_multipart_scope(_conn, %{auth_type: auth_type})
       when auth_type != :presigned do
    {:error,
     Error.new(:invalid_request,
       message: "Console direct multipart scope requires presigned authentication"
     )}
  end

  defp do_validate_console_direct_multipart_scope(conn, sr) do
    signed = sr.signed_headers |> Enum.map(&String.downcase/1) |> MapSet.new()

    unsigned_semantic_header =
      conn.req_headers
      |> Enum.map(fn {name, _value} -> String.downcase(name) end)
      |> Enum.find(fn name ->
        console_direct_multipart_signed_only_header?(name) and not MapSet.member?(signed, name)
      end)

    case unsigned_semantic_header do
      nil ->
        :ok

      header ->
        Log.warn("console direct multipart unsigned semantic header rejected",
          reason: :unsigned_headers,
          header: header
        )

        {:error,
         Error.new(:unsigned_headers,
           message:
             "Console direct multipart requests may not include unsigned S3 semantic headers"
         )}
    end
  end

  defp console_direct_multipart_signed_only_header?(name) do
    String.starts_with?(name, "x-amz-") or
      MapSet.member?(@console_direct_multipart_signed_only_headers, name)
  end

  defp record_long_term_access_key_use(conn, principal, signed_request) do
    if long_term_principal?(principal) and ecto_credential_store?() do
      case IAM.record_access_key_last_used(
             signed_request.access_key,
             signed_request.service,
             signed_request.region,
             now(conn)
           ) do
        :ok ->
          :ok

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          Log.warn("access key last-used update failed",
            action: :access_key_last_used,
            access_key_id: signed_request.access_key,
            service: signed_request.service,
            region: signed_request.region,
            reason: inspect(reason)
          )
      end
    end
  end

  defp long_term_principal?(%{credential_type: :session}), do: false
  defp long_term_principal?(%{type: type}) when type in [:root, :iam_user], do: true
  defp long_term_principal?(_principal), do: false

  defp ecto_credential_store? do
    CredentialStore.impl() == Maxio.Auth.CredentialStore.EctoStore
  end

  # 已 URL 解码的真实路径（Canonical 内部再做 S3 单次编码）。
  # 必须取自**原始 request_path**（保留尾/连续/前导斜杠），绝不用 conn.path_info——
  # 后者折叠空段会让重建的 CanonicalURI ≠ 客户端签名路径，误判 SignatureDoesNotMatch（铁律 5）。
  defp decoded_path(conn), do: RawPath.decoded_path(conn)

  # header 形态用真实 raw query（conn.query_string，保留 '+'/重复键）；
  # presigned 形态需排除 X-Amz-Signature，故从 raw query 串里剔除该参数后再传。
  defp signing_query(conn, %{auth_type: :presigned}),
    do: raw_query_without(conn.query_string, "X-Amz-Signature")

  defp signing_query(conn, _sr), do: conn.query_string

  # 从 raw query 串里剔除指定参数名（保留其余原始编码，绝不经 map 往返）。
  defp raw_query_without(raw, name) do
    raw
    |> String.split("&", trim: true)
    |> Enum.reject(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k | _] -> k == name
        _ -> false
      end
    end)
    |> Enum.join("&")
  end

  # SigV4 的 SignedHeaders 几乎总含 host，但 host 的权威来源是 conn.host
  # （由 HTTP 适配器从 Host 头/authority 解析；某些适配器不把它放进 req_headers）。
  # 为跨适配器稳健（铁律 5），若 req_headers 缺 host，则用 conn.host 补齐。
  defp req_headers_lower(conn) do
    lowered = Enum.map(conn.req_headers, fn {name, value} -> {String.downcase(name), value} end)

    if List.keymember?(lowered, "host", 0) do
      lowered
    else
      [{"host", host_value(conn)} | lowered]
    end
  end

  defp host_value(conn) do
    case conn.port do
      nil -> conn.host
      80 -> conn.host
      443 -> conn.host
      port -> "#{conn.host}:#{port}"
    end
  end

  defp header(conn, name) do
    conn |> get_req_header(name) |> List.first()
  end

  # 依赖注入时钟：测试经 conn.private[:maxio_now] 注入固定时刻，生产用真实时钟。
  defp now(conn), do: conn.private[:maxio_now] || DateTime.utc_now()

  defp reject(conn, %Error{} = err) do
    request_id = conn |> get_req_header("x-request-id") |> List.first()
    err = %{err | request_id: request_id, resource: decoded_path(conn)}
    {status, body} = ErrorView.render(err)
    Log.warn("sigv4 rejected", code: err.code, status: status)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, body)
    |> halt()
  end
end
