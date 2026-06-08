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

    now = DateTime.utc_now()
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    scope_date = Calendar.strftime(now, "%Y%m%d")
    scope = "#{scope_date}/#{@region}/#{@service}/aws4_request"

    payload_hash =
      Keyword.get(opts, :content_sha256_override) || Signer.hex_sha256(body)

    base_headers =
      [
        {"host", @host},
        {"x-amz-content-sha256", payload_hash},
        {"x-amz-date", amz_date}
      ] ++ Enum.map(extra_headers, fn {k, v} -> {String.downcase(k), v} end)

    canonical_req = %{
      method: to_string(method) |> String.upcase(),
      path: path,
      query: query,
      headers: base_headers,
      payload_hash: payload_hash
    }

    canonical = Canonical.canonical_request(canonical_req)
    sts = Signer.string_to_sign(amz_date, scope, canonical, "AWS4-HMAC-SHA256")
    key = Signer.derive_signing_key(@secret, scope_date, @region, @service)
    signature = Signer.signature(key, sts)
    signed_headers = Canonical.signed_headers(base_headers)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{@access_key}/#{scope}," <>
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
  自签一个 aws-chunked（STREAMING-AWS4-HMAC-SHA256-PAYLOAD）流式请求。
  用项目自己的 Signer 算 seed 与逐块签名，拼合法 chunk-signed body（"我们签→我们验"闭环）。
  opts：:chunk_size（默认整 body 一块）、:headers、:tamper（fn binary -> binary，
  对最终 chunked body 做篡改，用于负向测试）、:decoded_length_override（覆盖声明长度）。
  """
  def signed_chunked_conn(method, path, body, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, max(byte_size(body), 1))
    extra_headers = Keyword.get(opts, :headers, [])

    now = DateTime.utc_now()
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    scope_date = Calendar.strftime(now, "%Y%m%d")
    scope = "#{scope_date}/#{@region}/#{@service}/aws4_request"
    decoded_len = byte_size(body)
    decoded_len_header = Keyword.get(opts, :decoded_length_override, decoded_len)

    data_chunks = chunk_body(body, chunk_size)

    base_headers =
      [
        {"host", @host},
        {"content-encoding", "aws-chunked"},
        {"x-amz-content-sha256", "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"},
        {"x-amz-date", amz_date},
        {"x-amz-decoded-content-length", Integer.to_string(decoded_len_header)}
      ] ++ Enum.map(extra_headers, fn {k, v} -> {String.downcase(k), v} end)

    canonical_req = %{
      method: to_string(method) |> String.upcase(),
      path: path,
      query: %{},
      headers: base_headers,
      payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"
    }

    canonical = Canonical.canonical_request(canonical_req)
    sts = Signer.string_to_sign(amz_date, scope, canonical, "AWS4-HMAC-SHA256")
    key = Signer.derive_signing_key(@secret, scope_date, @region, @service)
    seed_sig = Signer.signature(key, sts)
    signed_headers = Canonical.signed_headers(base_headers)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{@access_key}/#{scope}," <>
        "SignedHeaders=#{signed_headers},Signature=#{seed_sig}"

    chunked_body = build_chunked_body(data_chunks, key, amz_date, scope, seed_sig)
    chunked_body = if t = Keyword.get(opts, :tamper), do: t.(chunked_body), else: chunked_body

    conn =
      conn(method, path, chunked_body)
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

  defp build_chunked_body(data_chunks, key, amz_date, scope, seed_sig) do
    {frames, _last} =
      Enum.reduce(data_chunks ++ [""], {[], seed_sig}, fn data, {acc, prev} ->
        data_hash = Signer.hex_sha256(data)

        chunk_sts =
          Maxio.Auth.SigV4.StreamingVerifier.chunk_string_to_sign(amz_date, scope, prev, data_hash)

        sig = Signer.signature(key, chunk_sts)
        size_hex = Integer.to_string(byte_size(data), 16) |> String.downcase()
        frame = "#{size_hex};chunk-signature=#{sig}\r\n" <> data <> "\r\n"
        {[frame | acc], sig}
      end)

    frames |> Enum.reverse() |> IO.iodata_to_binary()
  end

  def access_key, do: @access_key
end
