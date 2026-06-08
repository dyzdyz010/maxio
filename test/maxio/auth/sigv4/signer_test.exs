defmodule Maxio.Auth.SigV4.SignerTest do
  use ExUnit.Case, async: true

  alias Maxio.Auth.SigV4.{Canonical, Signer}

  @secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  @region "us-east-1"
  @service "s3"
  @scope "20130524/us-east-1/s3/aws4_request"
  @amz_date "20130524T000000Z"
  @scope_date "20130524"
  @empty_hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  defp sign(req) do
    canonical = Canonical.canonical_request(req)
    sts = Signer.string_to_sign(@amz_date, @scope, canonical, "AWS4-HMAC-SHA256")
    key = Signer.derive_signing_key(@secret, @scope_date, @region, @service)
    Signer.signature(key, sts)
  end

  test "hex_sha256/1 空串常量" do
    assert Signer.hex_sha256("") == @empty_hash
  end

  test "VECTOR A — GET Object string_to_sign + signature" do
    req = %{
      method: "GET",
      path: "/test.txt",
      query: %{},
      headers: [
        {"host", "examplebucket.s3.amazonaws.com"},
        {"range", "bytes=0-9"},
        {"x-amz-content-sha256", @empty_hash},
        {"x-amz-date", @amz_date}
      ],
      payload_hash: @empty_hash
    }

    canonical = Canonical.canonical_request(req)

    expected_sts =
      "AWS4-HMAC-SHA256\n20130524T000000Z\n20130524/us-east-1/s3/aws4_request\n" <>
        "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972"

    assert Signer.string_to_sign(@amz_date, @scope, canonical, "AWS4-HMAC-SHA256") == expected_sts
    assert sign(req) == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
  end

  test "VECTOR B — PUT Object signature" do
    body_hash = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"

    req = %{
      method: "PUT",
      path: "/test$file.text",
      query: %{},
      headers: [
        {"date", "Fri, 24 May 2013 00:00:00 GMT"},
        {"host", "examplebucket.s3.amazonaws.com"},
        {"x-amz-content-sha256", body_hash},
        {"x-amz-date", @amz_date},
        {"x-amz-storage-class", "REDUCED_REDUNDANCY"}
      ],
      payload_hash: body_hash
    }

    assert sign(req) == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
  end

  test "VECTOR C — GET Bucket Lifecycle signature" do
    req = %{
      method: "GET",
      path: "/",
      query: %{"lifecycle" => ""},
      headers: [
        {"host", "examplebucket.s3.amazonaws.com"},
        {"x-amz-content-sha256", @empty_hash},
        {"x-amz-date", @amz_date}
      ],
      payload_hash: @empty_hash
    }

    assert sign(req) == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
  end

  test "VECTOR D — ListObjects signature" do
    req = %{
      method: "GET",
      path: "/",
      query: %{"max-keys" => "2", "prefix" => "J"},
      headers: [
        {"host", "examplebucket.s3.amazonaws.com"},
        {"x-amz-content-sha256", @empty_hash},
        {"x-amz-date", @amz_date}
      ],
      payload_hash: @empty_hash
    }

    assert sign(req) == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
  end

  test "presigned VECTOR — UNSIGNED-PAYLOAD + 全 X-Amz-* query（除 Signature）" do
    req = %{
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
      payload_hash: "UNSIGNED-PAYLOAD"
    }

    canonical = Canonical.canonical_request(req)

    expected_sts =
      "AWS4-HMAC-SHA256\n20130524T000000Z\n20130524/us-east-1/s3/aws4_request\n" <>
        "3bfa292879f6447bbcda7001decf97f4a54dc650c8942174ae0a9121cf58ad04"

    assert Signer.string_to_sign(@amz_date, @scope, canonical, "AWS4-HMAC-SHA256") == expected_sts
    assert sign(req) == "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  end

  test "secure_compare/2 常数时间比对" do
    assert Signer.secure_compare("abc", "abc") == true
    assert Signer.secure_compare("abc", "abd") == false
  end
end
