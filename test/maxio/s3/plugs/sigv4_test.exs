defmodule Maxio.S3.Plugs.SigV4Test do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Maxio.S3.Plugs.SigV4

  @empty_hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  # 用官方 VECTOR A 构造一个已正确签名的请求（注意 host 必须与签名时一致）。
  defp signed_conn(signature) do
    auth =
      "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," <>
        "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date," <>
        "Signature=#{signature}"

    # host 经 URL 提供（新版 Plug.Test 禁止用 put_req_header 设 host，
    # host 的权威来源是 conn.host；SigV4 plug 从 conn.host 补齐 host 签名头）。
    conn(:get, "http://examplebucket.s3.amazonaws.com/test.txt")
    |> put_req_header("range", "bytes=0-9")
    |> put_req_header("x-amz-content-sha256", @empty_hash)
    |> put_req_header("x-amz-date", "20130524T000000Z")
    |> put_req_header("authorization", auth)
    |> put_private(:maxio_now, ~U[2013-05-24 00:00:00Z])
  end

  test "正确签名通过，写 principal/auth_type/payload_mode，不 halt" do
    conn =
      signed_conn("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
      |> SigV4.call(SigV4.init([]))

    refute conn.halted
    assert conn.assigns.principal.type == :root
    assert conn.assigns.auth_type == :header
    assert conn.assigns.payload_mode == :single
  end

  test "错误签名 halt + 403 SignatureDoesNotMatch XML" do
    conn =
      signed_conn("00000000000000000000000000000000000000000000000000000000deadbeef")
      |> SigV4.call(SigV4.init([]))

    assert conn.halted
    assert conn.status == 403
    assert conn.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/xml"
  end

  test "缺 Authorization 且无 presigned 参数 → 400 MissingSecurityHeader" do
    conn = conn(:get, "http://x/test.txt") |> SigV4.call(SigV4.init([]))
    assert conn.halted
    assert conn.status == 400
    assert conn.resp_body =~ "<Code>MissingSecurityHeader</Code>"
  end
end
