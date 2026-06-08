defmodule Maxio.Auth.SigV4.AuthHeaderParserTest do
  use ExUnit.Case, async: true

  alias Maxio.Auth.SigV4.{AuthHeaderParser, SignedRequest}

  test "解析 header-based Authorization（VECTOR A 形态）" do
    auth =
      "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," <>
        "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date," <>
        "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"

    assert {:ok, %SignedRequest{} = sr} =
             AuthHeaderParser.parse_header(
               auth,
               "20130524T000000Z",
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
             )

    assert sr.auth_type == :header
    assert sr.access_key == "AKIAIOSFODNN7EXAMPLE"
    assert sr.scope_date == "20130524"
    assert sr.region == "us-east-1"
    assert sr.service == "s3"
    assert sr.signed_headers == ["host", "range", "x-amz-content-sha256", "x-amz-date"]
    assert sr.signature == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    assert sr.amz_date == "20130524T000000Z"
    assert sr.payload_mode == :single
  end

  test "x-amz-content-sha256=UNSIGNED-PAYLOAD → payload_mode :unsigned" do
    auth =
      "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," <>
        "SignedHeaders=host,Signature=abc"

    {:ok, sr} = AuthHeaderParser.parse_header(auth, "20130524T000000Z", "UNSIGNED-PAYLOAD")
    assert sr.payload_mode == :unsigned
  end

  test "x-amz-content-sha256=STREAMING-AWS4-HMAC-SHA256-PAYLOAD → :streaming" do
    auth =
      "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," <>
        "SignedHeaders=host,Signature=abc"

    {:ok, sr} =
      AuthHeaderParser.parse_header(
        auth,
        "20130524T000000Z",
        "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"
      )

    assert sr.payload_mode == :streaming
  end

  test "畸形 Authorization 头返回 :authorization_header_malformed" do
    assert {:error, :authorization_header_malformed} =
             AuthHeaderParser.parse_header("Basic xxx", "d", "h")

    assert {:error, :authorization_header_malformed} =
             AuthHeaderParser.parse_header("AWS4-HMAC-SHA256 garbage", "d", "h")
  end

  test "解析 presigned query（presigned VECTOR 形态）" do
    query = %{
      "X-Amz-Algorithm" => "AWS4-HMAC-SHA256",
      "X-Amz-Credential" => "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request",
      "X-Amz-Date" => "20130524T000000Z",
      "X-Amz-Expires" => "86400",
      "X-Amz-SignedHeaders" => "host",
      "X-Amz-Signature" => "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
    }

    {:ok, sr} = AuthHeaderParser.parse_presigned(query)
    assert sr.auth_type == :presigned
    assert sr.access_key == "AKIAIOSFODNN7EXAMPLE"
    assert sr.scope_date == "20130524"
    assert sr.signed_headers == ["host"]
    assert sr.signature == "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
    assert sr.amz_date == "20130524T000000Z"
    assert sr.expires == 86400
    assert sr.payload_mode == :unsigned
  end

  test "presigned 缺必需参数返回 :authorization_query_parameters_error" do
    assert {:error, :authorization_query_parameters_error} =
             AuthHeaderParser.parse_presigned(%{"X-Amz-Algorithm" => "AWS4-HMAC-SHA256"})
  end
end
