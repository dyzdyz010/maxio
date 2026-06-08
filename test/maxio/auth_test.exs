defmodule Maxio.AuthTest do
  use ExUnit.Case, async: false

  alias Maxio.Auth
  alias Maxio.Auth.SigV4.SignedRequest
  alias Maxio.S3.Error

  @empty_hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  @now ~U[2013-05-24 00:00:00Z]

  defp vector_a_material(signature) do
    %{
      signed_request: %SignedRequest{
        access_key: "AKIAIOSFODNN7EXAMPLE",
        scope_date: "20130524",
        region: "us-east-1",
        service: "s3",
        signed_headers: ["host", "range", "x-amz-content-sha256", "x-amz-date"],
        signature: signature,
        amz_date: "20130524T000000Z",
        auth_type: :header,
        payload_mode: :single,
        expires: nil
      },
      method: "GET",
      path: "/test.txt",
      query: %{},
      headers: [
        {"host", "examplebucket.s3.amazonaws.com"},
        {"range", "bytes=0-9"},
        {"x-amz-content-sha256", @empty_hash},
        {"x-amz-date", "20130524T000000Z"}
      ],
      payload_hash: @empty_hash,
      now: @now
    }
  end

  test "正确签名（VECTOR A）通过并返回 root principal" do
    material =
      vector_a_material("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")

    assert {:ok, principal, _ctx} = Auth.authenticate(material)
    assert principal.type == :root
    assert principal.access_key == "AKIAIOSFODNN7EXAMPLE"
  end

  test "错误签名 → SignatureDoesNotMatch 403" do
    material = vector_a_material("deadbeef" <> String.duplicate("0", 56))

    assert {:error, %Error{code: "SignatureDoesNotMatch", http_status: 403}} =
             Auth.authenticate(material)
  end

  test "未知 access key → InvalidAccessKeyId 403" do
    material = vector_a_material("whatever")
    material = put_in(material.signed_request.access_key, "NOPEKEY")

    assert {:error, %Error{code: "InvalidAccessKeyId", http_status: 403}} =
             Auth.authenticate(material)
  end

  test "时钟偏移超 15min → RequestTimeTooSkewed 403" do
    material =
      vector_a_material("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")

    skewed = %{material | now: ~U[2013-05-24 00:20:00Z]}

    assert {:error, %Error{code: "RequestTimeTooSkewed", http_status: 403}} =
             Auth.authenticate(skewed)
  end

  test "presigned 过期 → AccessDenied 403" do
    sr = %SignedRequest{
      access_key: "AKIAIOSFODNN7EXAMPLE",
      scope_date: "20130524",
      region: "us-east-1",
      service: "s3",
      signed_headers: ["host"],
      signature: "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
      amz_date: "20130524T000000Z",
      auth_type: :presigned,
      payload_mode: :unsigned,
      expires: 86400
    }

    material = %{
      signed_request: sr,
      method: "GET",
      path: "/test.txt",
      query: %{
        "X-Amz-Algorithm" => "AWS4-HMAC-SHA256",
        "X-Amz-Credential" => "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request",
        "X-Amz-Date" => "20130524T000000Z",
        "X-Amz-Expires" => "86400",
        "X-Amz-SignedHeaders" => "host"
      },
      headers: [{"host", "examplebucket.s3.amazonaws.com"}],
      payload_hash: "UNSIGNED-PAYLOAD",
      now: ~U[2013-05-26 00:00:01Z]
    }

    assert {:error, %Error{code: "AccessDenied", http_status: 403}} = Auth.authenticate(material)
  end

  test "presigned 在有效期内且签名正确通过" do
    sr = %SignedRequest{
      access_key: "AKIAIOSFODNN7EXAMPLE",
      scope_date: "20130524",
      region: "us-east-1",
      service: "s3",
      signed_headers: ["host"],
      signature: "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
      amz_date: "20130524T000000Z",
      auth_type: :presigned,
      payload_mode: :unsigned,
      expires: 86400
    }

    material = %{
      signed_request: sr,
      method: "GET",
      path: "/test.txt",
      query: %{
        "X-Amz-Algorithm" => "AWS4-HMAC-SHA256",
        "X-Amz-Credential" => "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request",
        "X-Amz-Date" => "20130524T000000Z",
        "X-Amz-Expires" => "86400",
        "X-Amz-SignedHeaders" => "host"
      },
      headers: [{"host", "examplebucket.s3.amazonaws.com"}],
      payload_hash: "UNSIGNED-PAYLOAD",
      now: ~U[2013-05-24 01:00:00Z]
    }

    assert {:ok, principal, _ctx} = Auth.authenticate(material)
    assert principal.type == :root
  end
end
