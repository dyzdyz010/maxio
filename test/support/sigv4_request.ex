defmodule Maxio.Test.SigV4Request do
  @moduledoc """
  测试辅助：用项目自己的 SigV4 Signer 自签一个请求并经 Maxio.S3.Endpoint 打进管线。
  这是无 aws-cli 环境下的端到端活体取证：证明 我们签 → 我们验 闭环成立，
  且管线（AddressStyle→SigV4→Dispatch→Handler→XML）端到端工作。

  时钟用**当前时刻**（DateTime.utc_now()），并把同一时刻经 conn.private[:maxio_now]
  注入，使 SigV4 plug 的时钟偏移校验自然通过（铁律 5：不写死过期时间）。

  寻址：host=localhost（domain 配置即 localhost）走 path-style。
  注意（Plug 1.19.2 必要偏差）：Plug.Test 禁止 put_req_header("host", ...) 且不把
  host 放进 req_headers——host 的权威来源是 conn.host（SigV4 plug 读 conn.host）。
  故本辅助签名时把 {"host","localhost"} 计入 canonical headers，构造 conn 时用
  `%{conn | host: "localhost"}` 设置真实 host（与 E5/E6 plug 测试一致），不经
  put_req_header 注入 host。
  """
  import Plug.Test
  import Plug.Conn

  alias Maxio.Auth.SigV4.{Canonical, Signer}

  @access_key "AKIAIOSFODNN7EXAMPLE"
  @secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  @region "us-east-1"
  @service "s3"
  @host "localhost"

  @doc """
  自签并构造 conn。opts：:query (map)、:headers ([{name,value}])、:body (binary)。
  自动加 host/x-amz-date/x-amz-content-sha256，签名后加 Authorization。
  """
  def signed_conn(method, path, opts \\ []) do
    query = Keyword.get(opts, :query, %{})
    extra_headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")
    access_key = Keyword.get(opts, :access_key, @access_key)
    secret = Keyword.get(opts, :secret, @secret)
    session_token = Keyword.get(opts, :session_token)
    service = Keyword.get(opts, :service, @service)

    now = DateTime.utc_now()
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    scope_date = Calendar.strftime(now, "%Y%m%d")
    scope = "#{scope_date}/#{@region}/#{service}/aws4_request"

    payload_hash =
      Keyword.get(opts, :content_sha256_override) || Signer.hex_sha256(body)

    base_headers =
      maybe_add_session_token(
        [
          {"host", @host},
          {"x-amz-content-sha256", payload_hash},
          {"x-amz-date", amz_date}
        ] ++ Enum.map(extra_headers, fn {k, v} -> {String.downcase(k), v} end),
        session_token
      )

    canonical_req = %{
      method: to_string(method) |> String.upcase(),
      # 签名用**已解码**路径（与服务端 RawPath.decoded_path 契约一致）：Plug.Test.conn/3 会把
      # full_path 单次解码进 conn.request_path，SigV4 plug 再 decode_once + canonical_uri 单次编码。
      # 客户端若传 percent-encoded 路径（如 test%20file%283%29.png），这里须先单次解码再交给
      # canonical_request（其内部 canonical_uri 单次编码），否则字面 '%' 被二次编码致签名不匹配。
      # 普通无 '%' 路径下 URI.decode/1 为恒等，既有用例不受影响（铁律 5：签名路径忠于服务端重建）。
      path: URI.decode(path),
      query: query,
      headers: base_headers,
      payload_hash: payload_hash
    }

    canonical = Canonical.canonical_request(canonical_req)
    sts = Signer.string_to_sign(amz_date, scope, canonical, "AWS4-HMAC-SHA256")
    key = Signer.derive_signing_key(secret, scope_date, @region, service)
    signature = Signer.signature(key, sts)
    signed_headers = Canonical.signed_headers(base_headers)
    signed_headers = maybe_transform_signed_headers(signed_headers, opts)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{access_key}/#{scope}," <>
        "SignedHeaders=#{signed_headers},Signature=#{signature}"

    query_string = URI.encode_query(query)
    full_path = if query_string == "", do: path, else: path <> "?" <> query_string

    conn =
      conn(method, full_path, body)
      |> Map.put(:host, @host)
      |> put_private(:maxio_now, now)

    # host 不经 put_req_header（Plug.Test 禁止），已由 conn.host 承载并参与签名。
    base_headers
    |> Enum.reject(fn {k, _v} -> k == "host" end)
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> put_req_header("authorization", auth)
  end

  @doc """
  自签一个 aws-chunked 流式请求。
  用项目自己的 Signer 算 seed 与逐块签名，拼合法 chunk-signed body（"我们签→我们验"闭环）。
  opts：:chunk_size（默认整 body 一块）、:headers、:tamper（fn binary -> binary，
  对最终 chunked body 做篡改，用于负向测试）、:decoded_length_override（覆盖声明长度）、
  :trailer_headers（map/list；存在时默认 STREAMING-UNSIGNED-PAYLOAD-TRAILER）、
  :streaming_payload_hash（覆盖 x-amz-content-sha256）。
  """
  def signed_chunked_conn(method, path, body, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, max(byte_size(body), 1))
    extra_headers = Keyword.get(opts, :headers, [])
    access_key = Keyword.get(opts, :access_key, @access_key)
    secret = Keyword.get(opts, :secret, @secret)
    session_token = Keyword.get(opts, :session_token)
    service = Keyword.get(opts, :service, @service)
    query = Keyword.get(opts, :query, %{})

    now = DateTime.utc_now()
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    scope_date = Calendar.strftime(now, "%Y%m%d")
    scope = "#{scope_date}/#{@region}/#{service}/aws4_request"
    decoded_len = byte_size(body)
    decoded_len_header = Keyword.get(opts, :decoded_length_override, decoded_len)
    trailer_headers = Keyword.get(opts, :trailer_headers, [])
    trailer_names = trailer_headers |> Enum.map(fn {name, _value} -> String.downcase(name) end)

    default_payload_hash =
      if trailer_names == [],
        do: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD",
        else: "STREAMING-UNSIGNED-PAYLOAD-TRAILER"

    payload_hash =
      Keyword.get(
        opts,
        :streaming_payload_hash,
        default_payload_hash
      )

    data_chunks = chunk_body(body, chunk_size)

    base_headers =
      maybe_add_session_token(
        [
          {"host", @host},
          {"content-encoding", "aws-chunked"},
          {"x-amz-content-sha256", payload_hash},
          {"x-amz-date", amz_date},
          {"x-amz-decoded-content-length", Integer.to_string(decoded_len_header)}
        ] ++
          maybe_trailer_header(trailer_names) ++
          Enum.map(extra_headers, fn {k, v} -> {String.downcase(k), v} end),
        session_token
      )

    canonical_req = %{
      method: to_string(method) |> String.upcase(),
      path: path,
      query: query,
      headers: base_headers,
      payload_hash: payload_hash
    }

    canonical = Canonical.canonical_request(canonical_req)
    sts = Signer.string_to_sign(amz_date, scope, canonical, "AWS4-HMAC-SHA256")
    key = Signer.derive_signing_key(secret, scope_date, @region, service)
    seed_sig = Signer.signature(key, sts)
    signed_headers = Canonical.signed_headers(base_headers)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{access_key}/#{scope}," <>
        "SignedHeaders=#{signed_headers},Signature=#{seed_sig}"

    chunked_body =
      build_chunked_body(
        data_chunks,
        trailer_headers,
        payload_hash,
        key,
        amz_date,
        scope,
        seed_sig
      )

    chunked_body = if t = Keyword.get(opts, :tamper), do: t.(chunked_body), else: chunked_body
    query_string = URI.encode_query(query)
    full_path = if query_string == "", do: path, else: path <> "?" <> query_string

    conn =
      conn(method, full_path, chunked_body)
      |> Map.put(:host, @host)
      |> put_private(:maxio_now, now)

    base_headers
    |> Enum.reject(fn {k, _v} -> k == "host" end)
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> put_req_header("authorization", auth)
  end

  defp chunk_body("", _size), do: []

  defp chunk_body(body, size) do
    body
    |> :binary.bin_to_list()
    |> Enum.chunk_every(size)
    |> Enum.map(&:erlang.list_to_binary/1)
  end

  defp maybe_trailer_header([]), do: []
  defp maybe_trailer_header(names), do: [{"x-amz-trailer", Enum.join(names, ",")}]

  defp build_chunked_body(
         data_chunks,
         trailer_headers,
         "STREAMING-UNSIGNED-PAYLOAD-TRAILER",
         _key,
         _amz_date,
         _scope,
         _seed_sig
       ) do
    frames =
      data_chunks
      |> Enum.map(fn data ->
        size_hex = Integer.to_string(byte_size(data), 16) |> String.downcase()
        "#{size_hex}\r\n" <> data <> "\r\n"
      end)

    IO.iodata_to_binary([frames, "0\r\n", trailer_block(trailer_headers), "\r\n"])
  end

  defp build_chunked_body(
         data_chunks,
         trailer_headers,
         "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER",
         key,
         amz_date,
         scope,
         seed_sig
       ) do
    {frames, last_sig} = signed_data_frames(data_chunks ++ [""], key, amz_date, scope, seed_sig)
    trailer = trailer_block(trailer_headers)
    trailer_signature_block = trailer_signature_block(trailer_headers)

    trailer_sts =
      Maxio.Auth.SigV4.StreamingVerifier.trailer_string_to_sign(
        amz_date,
        scope,
        last_sig,
        Signer.hex_sha256(trailer_signature_block)
      )

    trailer_sig = Signer.signature(key, trailer_sts)
    IO.iodata_to_binary([frames, trailer, "x-amz-trailer-signature:", trailer_sig, "\r\n"])
  end

  defp build_chunked_body(
         data_chunks,
         _trailer_headers,
         _payload_hash,
         key,
         amz_date,
         scope,
         seed_sig
       ) do
    {frames, _last} = signed_data_frames(data_chunks ++ [""], key, amz_date, scope, seed_sig)
    frames |> IO.iodata_to_binary()
  end

  defp signed_data_frames(chunks, key, amz_date, scope, seed_sig) do
    {frames, last} =
      Enum.reduce(chunks, {[], seed_sig}, fn data, {acc, prev} ->
        data_hash = Signer.hex_sha256(data)

        chunk_sts =
          Maxio.Auth.SigV4.StreamingVerifier.chunk_string_to_sign(
            amz_date,
            scope,
            prev,
            data_hash
          )

        sig = Signer.signature(key, chunk_sts)
        size_hex = Integer.to_string(byte_size(data), 16) |> String.downcase()
        frame = "#{size_hex};chunk-signature=#{sig}\r\n" <> data <> "\r\n"
        {[frame | acc], sig}
      end)

    {Enum.reverse(frames), last}
  end

  defp trailer_block(headers) do
    headers
    |> Enum.map(fn {name, value} -> String.downcase(name) <> ":" <> value <> "\r\n" end)
    |> IO.iodata_to_binary()
  end

  defp trailer_signature_block(headers) do
    headers
    |> Enum.map(fn {name, value} -> String.downcase(name) <> ":" <> value <> "\n" end)
    |> IO.iodata_to_binary()
  end

  def access_key, do: @access_key

  @doc """
  Builds a presigned request conn. `session_token`, when provided, is encoded as
  `X-Amz-Security-Token` and therefore participates in the canonical query.
  """
  def presigned_conn(method, path, opts \\ []) do
    query = Keyword.get(opts, :query, %{})
    access_key = Keyword.get(opts, :access_key, @access_key)
    secret = Keyword.get(opts, :secret, @secret)
    session_token = Keyword.get(opts, :session_token)
    expires = Keyword.get(opts, :expires, 900)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    service = Keyword.get(opts, :service, @service)

    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    scope_date = Calendar.strftime(now, "%Y%m%d")
    scope = "#{scope_date}/#{@region}/#{service}/aws4_request"

    signing_query =
      query
      |> Map.merge(%{
        "X-Amz-Algorithm" => "AWS4-HMAC-SHA256",
        "X-Amz-Credential" => "#{access_key}/#{scope}",
        "X-Amz-Date" => amz_date,
        "X-Amz-Expires" => Integer.to_string(expires),
        "X-Amz-SignedHeaders" => "host"
      })
      |> maybe_put_query_token(session_token)

    canonical_req = %{
      method: to_string(method) |> String.upcase(),
      path: URI.decode(path),
      query: signing_query,
      headers: [{"host", @host}],
      payload_hash: "UNSIGNED-PAYLOAD"
    }

    canonical = Canonical.canonical_request(canonical_req)
    sts = Signer.string_to_sign(amz_date, scope, canonical, "AWS4-HMAC-SHA256")
    key = Signer.derive_signing_key(secret, scope_date, @region, service)
    signature = Signer.signature(key, sts)

    final_query = Map.put(signing_query, "X-Amz-Signature", signature)
    full_path = path <> "?" <> URI.encode_query(final_query)

    conn(method, full_path, "")
    |> Map.put(:host, @host)
    |> put_private(:maxio_now, now)
  end

  @doc """
  构造一个匿名（无凭据）请求 conn——无 Authorization 头、无 X-Amz-Signature 查询参数。
  用于测试 public bucket policy / ACL 放行匿名访问。opts: :query、:headers、:body。
  """
  def anon_conn(method, path, opts \\ []) do
    query = Keyword.get(opts, :query, %{})
    extra_headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")

    query_string = URI.encode_query(query)
    full_path = if query_string == "", do: path, else: path <> "?" <> query_string

    conn =
      conn(method, full_path, body)
      |> Map.put(:host, @host)
      |> put_private(:maxio_now, DateTime.utc_now())

    Enum.reduce(extra_headers, conn, fn {k, v}, acc ->
      put_req_header(acc, String.downcase(k), v)
    end)
  end

  defp maybe_add_session_token(headers, nil), do: headers
  defp maybe_add_session_token(headers, ""), do: headers

  defp maybe_add_session_token(headers, token) do
    [{"x-amz-security-token", token} | headers]
  end

  defp maybe_put_query_token(query, nil), do: query
  defp maybe_put_query_token(query, ""), do: query
  defp maybe_put_query_token(query, token), do: Map.put(query, "X-Amz-Security-Token", token)

  defp maybe_transform_signed_headers(signed_headers, opts) do
    case Keyword.get(opts, :signed_headers_transform) do
      nil -> signed_headers
      transform when is_function(transform, 1) -> transform.(signed_headers)
    end
  end
end
