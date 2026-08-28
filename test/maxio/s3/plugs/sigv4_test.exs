defmodule Maxio.S3.Plugs.SigV4Test do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Maxio.Auth.CredentialStore.MemoryStore
  alias Maxio.Auth.SigningSecret
  alias Maxio.S3.Plugs.SigV4
  alias Maxio.Test.SigV4Request

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
    assert %SigningSecret{} = conn.assigns.sigv4_context.caller_secret
    assert conn.assigns.sigv4_context.signed_payload_sha256 == @empty_hash
    refute inspect(conn) =~ "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  end

  test "错误签名 halt + 403 SignatureDoesNotMatch XML" do
    conn =
      signed_conn("00000000000000000000000000000000000000000000000000000000deadbeef")
      |> SigV4.call(SigV4.init([]))

    assert conn.halted
    assert conn.status == 403
    assert conn.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/xml"
    refute Map.has_key?(conn.assigns, :sigv4_context)
  end

  test "session authentication keeps only its own redacted signing secret" do
    access_key = "ASIACALLERSECRET#{System.unique_integer([:positive])}"
    session_secret = "session-signing-secret-#{System.unique_integer([:positive])}"
    session_token = "session-token-#{System.unique_integer([:positive])}"

    assert :ok =
             MemoryStore.put_access_key(%{
               access_key: access_key,
               secret_key: session_secret,
               session_token: session_token,
               expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
               principal: %{type: :root, arn: "arn:aws:iam:::root", tags: %{}}
             })

    conn =
      SigV4Request.signed_conn(:get, "/session-secret",
        access_key: access_key,
        secret: session_secret,
        session_token: session_token
      )
      |> SigV4.call(SigV4.init([]))

    refute conn.halted
    assert %SigningSecret{} = conn.assigns.sigv4_context.caller_secret
    refute inspect(conn.assigns.sigv4_context) =~ session_secret
  end

  test "完全无凭据（无 Authorization 且无 presigned 参数）→ 匿名 principal，不 halt（裁决下沉 Authz）" do
    conn = conn(:get, "http://x/test.txt") |> SigV4.call(SigV4.init([]))
    refute conn.halted
    assert conn.assigns.principal == :anonymous
    assert conn.assigns.auth_type == :anonymous
    assert conn.assigns.payload_mode == :unsigned
  end
end
