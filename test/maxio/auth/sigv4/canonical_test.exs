defmodule Maxio.Auth.SigV4.CanonicalTest do
  use ExUnit.Case, async: true

  alias Maxio.Auth.SigV4.Canonical

  @empty_hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  describe "uri_encode/2（S3：单次编码，CanonicalURI 不编码 /）" do
    test "对象 key 特殊字符单次编码（path 模式保留 /）" do
      assert Canonical.uri_encode("/test.txt", :path) == "/test.txt"
      assert Canonical.uri_encode("/test$file.text", :path) == "/test%24file.text"
      assert Canonical.uri_encode("/a/b/c", :path) == "/a/b/c"
    end

    test "query 模式编码所有保留字符（含 /）" do
      assert Canonical.uri_encode("a/b", :query) == "a%2Fb"
      assert Canonical.uri_encode("a b", :query) == "a%20b"
      assert Canonical.uri_encode("a~b-c_d.e", :query) == "a~b-c_d.e"
    end
  end

  test "VECTOR A — GET Object（空 query 第3行空行，blank 行在 SignedHeaders 前）" do
    req = %{
      method: "GET",
      path: "/test.txt",
      query: %{},
      headers: [
        {"host", "examplebucket.s3.amazonaws.com"},
        {"range", "bytes=0-9"},
        {"x-amz-content-sha256", @empty_hash},
        {"x-amz-date", "20130524T000000Z"}
      ],
      payload_hash: @empty_hash
    }

    expected =
      "GET\n" <>
        "/test.txt\n" <>
        "\n" <>
        "host:examplebucket.s3.amazonaws.com\n" <>
        "range:bytes=0-9\n" <>
        "x-amz-content-sha256:#{@empty_hash}\n" <>
        "x-amz-date:20130524T000000Z\n" <>
        "\n" <>
        "host;range;x-amz-content-sha256;x-amz-date\n" <>
        @empty_hash

    assert Canonical.canonical_request(req) == expected
  end

  test "VECTOR B — PUT Object（key 单次编码 /test%24file.text，签 date+host）" do
    body_hash = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"

    req = %{
      method: "PUT",
      path: "/test$file.text",
      query: %{},
      headers: [
        {"date", "Fri, 24 May 2013 00:00:00 GMT"},
        {"host", "examplebucket.s3.amazonaws.com"},
        {"x-amz-content-sha256", body_hash},
        {"x-amz-date", "20130524T000000Z"},
        {"x-amz-storage-class", "REDUCED_REDUNDANCY"}
      ],
      payload_hash: body_hash
    }

    expected =
      "PUT\n" <>
        "/test%24file.text\n" <>
        "\n" <>
        "date:Fri, 24 May 2013 00:00:00 GMT\n" <>
        "host:examplebucket.s3.amazonaws.com\n" <>
        "x-amz-content-sha256:#{body_hash}\n" <>
        "x-amz-date:20130524T000000Z\n" <>
        "x-amz-storage-class:REDUCED_REDUNDANCY\n" <>
        "\n" <>
        "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class\n" <>
        body_hash

    assert Canonical.canonical_request(req) == expected
  end

  test "VECTOR C — GET Bucket Lifecycle（?lifecycle → lifecycle=）" do
    req = %{
      method: "GET",
      path: "/",
      query: %{"lifecycle" => ""},
      headers: [
        {"host", "examplebucket.s3.amazonaws.com"},
        {"x-amz-content-sha256", @empty_hash},
        {"x-amz-date", "20130524T000000Z"}
      ],
      payload_hash: @empty_hash
    }

    expected =
      "GET\n/\nlifecycle=\nhost:examplebucket.s3.amazonaws.com\n" <>
        "x-amz-content-sha256:#{@empty_hash}\nx-amz-date:20130524T000000Z\n\n" <>
        "host;x-amz-content-sha256;x-amz-date\n#{@empty_hash}"

    assert Canonical.canonical_request(req) == expected
  end

  test "VECTOR D — ListObjects（?max-keys=2&prefix=J 按编码 key 排序）" do
    req = %{
      method: "GET",
      path: "/",
      query: %{"max-keys" => "2", "prefix" => "J"},
      headers: [
        {"host", "examplebucket.s3.amazonaws.com"},
        {"x-amz-content-sha256", @empty_hash},
        {"x-amz-date", "20130524T000000Z"}
      ],
      payload_hash: @empty_hash
    }

    expected =
      "GET\n/\nmax-keys=2&prefix=J\nhost:examplebucket.s3.amazonaws.com\n" <>
        "x-amz-content-sha256:#{@empty_hash}\nx-amz-date:20130524T000000Z\n\n" <>
        "host;x-amz-content-sha256;x-amz-date\n#{@empty_hash}"

    assert Canonical.canonical_request(req) == expected
  end

  test "trimall/1 折叠内部连续空白并去首尾" do
    assert Canonical.trimall("  a   b  c ") == "a b c"
  end
end
