defmodule Maxio.Auth.SigV4.PresignerTest do
  use ExUnit.Case, async: true

  alias Maxio.Auth.SigV4.Presigner

  @access_key "AKIAIOSFODNN7EXAMPLE"
  @secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  @now ~U[2013-05-24 00:00:00Z]

  test "presigns AWS SigV4 GET vector" do
    assert {:ok, url} =
             Presigner.presign_url(
               :get,
               "https://examplebucket.s3.amazonaws.com",
               "/test.txt",
               %{access_key: @access_key, secret_key: @secret},
               now: @now,
               region: "us-east-1",
               expires: 86_400
             )

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.scheme == "https"
    assert uri.host == "examplebucket.s3.amazonaws.com"
    assert uri.path == "/test.txt"
    assert query["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
    assert query["X-Amz-Credential"] == "#{@access_key}/20130524/us-east-1/s3/aws4_request"
    assert query["X-Amz-Date"] == "20130524T000000Z"
    assert query["X-Amz-Expires"] == "86400"
    assert query["X-Amz-SignedHeaders"] == "host"

    assert query["X-Amz-Signature"] ==
             "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  end

  test "preserves S3 path encoding and signs non-default port in host" do
    assert {:ok, url} =
             Presigner.presign_url(
               :get,
               "http://localhost:9900",
               "/bucket/a b/%25.txt",
               %{access_key: @access_key, secret_key: @secret},
               now: @now,
               region: "us-east-1",
               expires: 60
             )

    uri = URI.parse(url)

    assert uri.path == "/bucket/a%20b/%2525.txt"
    assert uri.port == 9900
  end

  test "signs caller supplied query parameters" do
    version_id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    assert {:ok, versioned_url} =
             Presigner.presign_url(
               :get,
               "http://localhost:9900",
               "/bucket/object.txt",
               credentials(),
               now: @now,
               region: "us-east-1",
               expires: 60,
               query: %{"versionId" => version_id}
             )

    assert {:ok, latest_url} =
             Presigner.presign_url(
               :get,
               "http://localhost:9900",
               "/bucket/object.txt",
               credentials(),
               now: @now,
               region: "us-east-1",
               expires: 60
             )

    versioned_query = versioned_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    latest_query = latest_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert versioned_query["versionId"] == version_id
    refute Map.has_key?(latest_query, "versionId")
    assert versioned_query["X-Amz-Signature"] != latest_query["X-Amz-Signature"]
  end

  test "HTTP method participates in the presigned signature" do
    assert {:ok, get_url} =
             Presigner.presign_url(
               :get,
               "http://localhost:9900",
               "/bucket/object.txt",
               credentials(),
               now: @now,
               region: "us-east-1",
               expires: 60
             )

    assert {:ok, put_url} =
             Presigner.presign_url(
               :put,
               "http://localhost:9900",
               "/bucket/object.txt",
               credentials(),
               now: @now,
               region: "us-east-1",
               expires: 60
             )

    get_query = get_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    put_query = put_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert get_query["X-Amz-Signature"] != put_query["X-Amz-Signature"]
    assert get_query["X-Amz-SignedHeaders"] == "host"
    assert put_query["X-Amz-SignedHeaders"] == "host"
  end

  test "can bind additional request headers into the presigned signature" do
    assert {:ok, url} =
             Presigner.presign_url(
               :put,
               "http://localhost:9900",
               "/bucket/object.txt",
               credentials(),
               now: @now,
               region: "us-east-1",
               expires: 60,
               headers: [{"Content-Type", " text/plain "}]
             )

    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["X-Amz-SignedHeaders"] == "content-type;host"

    assert {:ok, other_url} =
             Presigner.presign_url(
               :put,
               "http://localhost:9900",
               "/bucket/object.txt",
               credentials(),
               now: @now,
               region: "us-east-1",
               expires: 60,
               headers: [{"content-type", "application/octet-stream"}]
             )

    other_query = other_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["X-Amz-Signature"] != other_query["X-Amz-Signature"]
  end

  test "rejects unsafe or reserved signed headers" do
    for headers <- [
          [{"host", "evil.example"}],
          [{"authorization", "AWS4-HMAC-SHA256 ..."}],
          [{"x-amz-security-token", "token"}]
        ] do
      assert {:error, :reserved_signed_header} =
               Presigner.presign_url(
                 :put,
                 "http://localhost:9900",
                 "/bucket/object.txt",
                 credentials(),
                 now: @now,
                 region: "us-east-1",
                 expires: 60,
                 headers: headers
               )
    end

    assert {:error, :duplicate_signed_header} =
             Presigner.presign_url(
               :put,
               "http://localhost:9900",
               "/bucket/object.txt",
               credentials(),
               now: @now,
               region: "us-east-1",
               expires: 60,
               headers: [{"content-type", "text/plain"}, {"Content-Type", "application/json"}]
             )

    assert {:error, :invalid_signed_header} =
             Presigner.presign_url(
               :put,
               "http://localhost:9900",
               "/bucket/object.txt",
               credentials(),
               now: @now,
               region: "us-east-1",
               expires: 60,
               headers: [{"content-type", "text/plain\r\nx-bad: 1"}]
             )

    assert {:error, :invalid_signed_header} =
             Presigner.presign_url(
               :put,
               "http://localhost:9900",
               "/bucket/object.txt",
               credentials(),
               now: @now,
               region: "us-east-1",
               expires: 60,
               headers: [{%{}, "text/plain"}]
             )

    assert {:error, :invalid_signed_header} =
             Presigner.presign_url(
               :put,
               "http://localhost:9900",
               "/bucket/object.txt",
               credentials(),
               now: @now,
               region: "us-east-1",
               expires: 60,
               headers: [{"content-type", %{}}]
             )
  end

  test "rejects caller supplied reserved signing query parameters" do
    for reserved <- [
          "X-Amz-Algorithm",
          "X-Amz-Credential",
          "X-Amz-Date",
          "X-Amz-Expires",
          "X-Amz-Security-Token",
          "X-Amz-Signature",
          "X-Amz-SignedHeaders"
        ] do
      assert {:error, :reserved_query_param} =
               Presigner.presign_url(
                 :get,
                 "http://localhost:9900",
                 "/bucket/object.txt",
                 credentials(),
                 now: @now,
                 region: "us-east-1",
                 expires: 60,
                 query: %{reserved => "caller"}
               )
    end
  end

  test "rejects invalid expiration and base url" do
    assert {:error, :invalid_expires} =
             Presigner.presign_url(:get, "http://localhost:9000", "/b/k", credentials(),
               expires: 0
             )

    assert {:error, :invalid_expires} =
             Presigner.presign_url(:get, "http://localhost:9000", "/b/k", credentials(),
               expires: 604_801
             )

    assert {:error, :invalid_base_url} =
             Presigner.presign_url(:get, "/relative", "/b/k", credentials())

    assert {:error, :invalid_base_url} =
             Presigner.presign_url(:get, "http://localhost:9000/proxy", "/b/k", credentials())
  end

  defp credentials, do: %{access_key: @access_key, secret_key: @secret}
end
