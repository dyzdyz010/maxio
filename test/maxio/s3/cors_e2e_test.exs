defmodule Maxio.S3.CorsE2ETest do
  use Maxio.DataCase, async: false
  import Plug.Conn
  alias Maxio.BucketConfigs
  alias Maxio.Console.DirectMultipartUpload.Cors, as: DirectMultipartCors
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_cors_e2e")
  @cors ~s(<CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><CORSRule><AllowedOrigin>http://www.example.com</AllowedOrigin><AllowedMethod>PUT</AllowedMethod><AllowedMethod>GET</AllowedMethod><AllowedHeader>*</AllowedHeader><MaxAgeSeconds>3000</MaxAgeSeconds><ExposeHeader>ETag</ExposeHeader></CORSRule></CORSConfiguration>)

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp put_cors(bucket, body, opts \\ []) do
    headers =
      Keyword.get(opts, :headers, [])
      |> maybe_add_content_md5(body, Keyword.get(opts, :content_md5, true))

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"cors" => ""},
      body: body,
      headers: headers
    )
    |> call()
  end

  defp maybe_add_content_md5(headers, _body, false), do: headers

  defp maybe_add_content_md5(headers, body, true),
    do: [{"content-md5", content_md5(body)} | headers]

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()
  defp content_sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode64()

  test "PutBucketCors 200 → GetBucketCors 回放 → DeleteBucketCors 204 → Get 404" do
    SigV4Request.signed_conn(:put, "/corb") |> call()
    put = put_cors("corb", @cors)
    assert put.status == 200
    get = SigV4Request.signed_conn(:get, "/corb", query: %{"cors" => ""}) |> call()
    assert get.resp_body =~ "http://www.example.com"
    del = SigV4Request.signed_conn(:delete, "/corb", query: %{"cors" => ""}) |> call()
    assert del.status == 204
    g2 = SigV4Request.signed_conn(:get, "/corb", query: %{"cors" => ""}) |> call()
    assert g2.status == 404
    assert g2.resp_body =~ "NoSuchCORSConfiguration"
  end

  test "DeleteBucket cascades bucket configs so same-name re-creation starts clean" do
    bucket = "cors-delete-recreate"

    create = SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert create.status == 200
    assert put_cors(bucket, @cors).status == 200
    assert {:ok, [_rule]} = BucketConfigs.get(bucket, :cors)

    delete = SigV4Request.signed_conn(:delete, "/#{bucket}") |> call()
    assert delete.status == 204
    assert BucketConfigs.get(bucket, :cors) == :none

    recreate = SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert recreate.status == 200

    get = SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"cors" => ""}) |> call()
    assert get.status == 404
    assert get.resp_body =~ "NoSuchCORSConfiguration"
    assert BucketConfigs.get(bucket, :cors) == :none
  end

  test "PutBucketCors malformed strict XML does not overwrite existing config" do
    SigV4Request.signed_conn(:put, "/corsstrict") |> call()
    assert put_cors("corsstrict", @cors).status == 200

    invalid_max_age =
      ~s(<CORSConfiguration><CORSRule><AllowedOrigin>https://new.example.com</AllowedOrigin><AllowedMethod>GET</AllowedMethod><MaxAgeSeconds>abc</MaxAgeSeconds></CORSRule></CORSConfiguration>)

    bad = put_cors("corsstrict", invalid_max_age)
    assert bad.status == 400
    assert bad.resp_body =~ "MalformedXML"

    assert {:ok, [%{"allowed_origins" => ["http://www.example.com"]}]} =
             BucketConfigs.get("corsstrict", :cors)

    unknown =
      ~s(<CORSConfiguration><CORSRule><AllowedOrigin>https://new.example.com</AllowedOrigin><AllowedMethod>GET</AllowedMethod><Unexpected>true</Unexpected></CORSRule></CORSConfiguration>)

    bad_unknown = put_cors("corsstrict", unknown)
    assert bad_unknown.status == 400
    assert bad_unknown.resp_body =~ "MalformedXML"

    get = SigV4Request.signed_conn(:get, "/corsstrict", query: %{"cors" => ""}) |> call()
    assert get.status == 200
    assert get.resp_body =~ "http://www.example.com"
    refute get.resp_body =~ "https://new.example.com"
  end

  test "OPTIONS 预检（不签名）命中 → 200 + Access-Control-Allow-Origin" do
    SigV4Request.signed_conn(:put, "/cb2") |> call()
    put_cors("cb2", @cors)

    pre =
      SigV4Request.anon_conn(:options, "/cb2/obj.txt",
        headers: [{"origin", "http://www.example.com"}, {"access-control-request-method", "PUT"}]
      )
      |> call()

    assert pre.status == 200
    assert get_resp_header(pre, "access-control-allow-origin") == ["http://www.example.com"]
    assert get_resp_header(pre, "access-control-allow-methods") == ["PUT"]
    assert get_resp_header(pre, "access-control-max-age") == ["3000"]
  end

  test "OPTIONS 预检 origin 不允许 → 403 AccessForbidden" do
    SigV4Request.signed_conn(:put, "/cb3") |> call()
    put_cors("cb3", @cors)

    pre =
      SigV4Request.anon_conn(:options, "/cb3/obj.txt",
        headers: [{"origin", "http://evil.com"}, {"access-control-request-method", "PUT"}]
      )
      |> call()

    assert pre.status == 403
    assert pre.resp_body =~ "AccessForbidden"
  end

  test "OPTIONS 预检 未配置 CORS → 403 AccessForbidden" do
    SigV4Request.signed_conn(:put, "/cb5") |> call()

    pre =
      SigV4Request.anon_conn(:options, "/cb5/obj.txt",
        headers: [{"origin", "http://www.example.com"}, {"access-control-request-method", "PUT"}]
      )
      |> call()

    assert pre.status == 403
    assert pre.resp_body =~ "AccessForbidden"
  end

  test "实际 GET 带 Origin → 注入 Access-Control-Allow-Origin + Vary（流式不破）" do
    SigV4Request.signed_conn(:put, "/cb4") |> call()
    put_cors("cb4", @cors)
    SigV4Request.signed_conn(:put, "/cb4/o.txt", body: "hello") |> call()

    get =
      SigV4Request.signed_conn(:get, "/cb4/o.txt",
        headers: [{"origin", "http://www.example.com"}]
      )
      |> call()

    assert get.status == 200
    assert get.resp_body == "hello"
    assert get_resp_header(get, "access-control-allow-origin") == ["http://www.example.com"]
    assert get_resp_header(get, "access-control-allow-methods") == []
    assert "Origin" in get_resp_header(get, "vary")
  end

  test "direct multipart helper CORS allows browser preflight and exposes ETag" do
    origin = "http://console.example.test:4000"
    SigV4Request.signed_conn(:put, "/corsdirect") |> call()

    assert {:ok, _rules, :updated} =
             DirectMultipartCors.ensure_bucket_rule("corsdirect", origin)

    for {method, request_headers} <- [
          {"POST",
           "content-type, content-md5, cache-control, content-disposition, content-encoding, expires, x-amz-storage-class, x-amz-meta-maxio, x-amz-tagging, x-amz-server-side-encryption, x-amz-checksum-algorithm, x-amz-checksum-type, x-amz-request-payer, x-amz-mp-object-size"},
          {"PUT", "content-type, x-amz-request-payer"},
          {"GET", "x-amz-request-payer"},
          {"DELETE", "x-amz-request-payer"}
        ] do
      preflight =
        SigV4Request.anon_conn(:options, "/corsdirect/object.bin",
          headers: [
            {"origin", origin},
            {"access-control-request-method", method},
            {"access-control-request-headers", request_headers}
          ]
        )
        |> call()

      assert preflight.status == 200
      assert get_resp_header(preflight, "access-control-allow-origin") == [origin]
      assert get_resp_header(preflight, "access-control-allow-methods") == [method]
      assert get_resp_header(preflight, "access-control-allow-headers") == [request_headers]
      assert get_resp_header(preflight, "access-control-expose-headers") == ["ETag"]
    end

    put =
      SigV4Request.signed_conn(:put, "/corsdirect/object.bin",
        body: "hello",
        headers: [{"origin", origin}]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "access-control-allow-origin") == [origin]
    assert get_resp_header(put, "access-control-expose-headers") == ["ETag"]
    assert [_etag] = get_resp_header(put, "etag")
  end

  test "预检命中 → 回 Access-Control-Allow-Credentials: true" do
    SigV4Request.signed_conn(:put, "/cbc1") |> call()
    put_cors("cbc1", @cors)

    pre =
      SigV4Request.anon_conn(:options, "/cbc1/obj.txt",
        headers: [{"origin", "http://www.example.com"}, {"access-control-request-method", "PUT"}]
      )
      |> call()

    assert pre.status == 200
    assert get_resp_header(pre, "access-control-allow-credentials") == ["true"]
  end

  test "实际跨源响应 → 回 Access-Control-Allow-Credentials: true" do
    SigV4Request.signed_conn(:put, "/cbc2") |> call()
    put_cors("cbc2", @cors)
    SigV4Request.signed_conn(:put, "/cbc2/o.txt", body: "x") |> call()

    res =
      SigV4Request.signed_conn(:get, "/cbc2/o.txt",
        headers: [{"origin", "http://www.example.com"}]
      )
      |> call()

    assert get_resp_header(res, "access-control-allow-credentials") == ["true"]
  end

  test "PutBucketCors requires and validates Content-MD5" do
    assert (SigV4Request.signed_conn(:put, "/corsmd5") |> call()).status == 200

    missing = put_cors("corsmd5", @cors, content_md5: false)

    assert missing.status == 400
    assert missing.resp_body =~ "MissingSecurityHeader"
    assert BucketConfigs.get("corsmd5", :cors) == :none

    bad =
      put_cors("corsmd5", @cors,
        headers: [{"content-md5", content_md5("different")}],
        content_md5: false
      )

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert BucketConfigs.get("corsmd5", :cors) == :none
  end

  test "x-amz-expected-bucket-owner is enforced on Get Put and Delete" do
    assert (SigV4Request.signed_conn(:put, "/corsowner") |> call()).status == 200

    denied_put =
      put_cors("corsowner", @cors, headers: [{"x-amz-expected-bucket-owner", "999999999999"}])

    assert denied_put.status == 403
    assert denied_put.resp_body =~ "AccessDenied"
    assert BucketConfigs.get("corsowner", :cors) == :none

    allowed_put =
      put_cors("corsowner", @cors, headers: [{"x-amz-expected-bucket-owner", "000000000000"}])

    assert allowed_put.status == 200

    denied_get =
      SigV4Request.signed_conn(:get, "/corsowner",
        query: %{"cors" => ""},
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )
      |> call()

    assert denied_get.status == 403
    assert denied_get.resp_body =~ "AccessDenied"

    allowed_get =
      SigV4Request.signed_conn(:get, "/corsowner",
        query: %{"cors" => ""},
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )
      |> call()

    assert allowed_get.status == 200
    assert allowed_get.resp_body =~ "http://www.example.com"

    denied_delete =
      SigV4Request.signed_conn(:delete, "/corsowner",
        query: %{"cors" => ""},
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )
      |> call()

    assert denied_delete.status == 403
    assert denied_delete.resp_body =~ "AccessDenied"
    assert {:ok, _rules} = BucketConfigs.get("corsowner", :cors)

    allowed_delete =
      SigV4Request.signed_conn(:delete, "/corsowner",
        query: %{"cors" => ""},
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )
      |> call()

    assert allowed_delete.status == 204
    assert BucketConfigs.get("corsowner", :cors) == :none
  end

  test "checksum trailers and aws-chunked CORS XML bodies require Content-MD5 and validate before storing config" do
    assert (SigV4Request.signed_conn(:put, "/corschunked") |> call()).status == 200

    plain_trailer =
      put_cors("corschunked", @cors,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "InvalidRequest"
    assert BucketConfigs.get("corschunked", :cors) == :none

    missing_md5 =
      SigV4Request.signed_chunked_conn(:put, "/corschunked", @cors,
        query: %{"cors" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(@cors)}]
      )
      |> call()

    assert missing_md5.status == 400
    assert missing_md5.resp_body =~ "MissingSecurityHeader"
    assert BucketConfigs.get("corschunked", :cors) == :none

    missing_trailer =
      SigV4Request.signed_chunked_conn(:put, "/corschunked", @cors,
        query: %{"cors" => ""},
        headers: [
          {"content-md5", content_md5(@cors)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ],
        streaming_payload_hash: "STREAMING-UNSIGNED-PAYLOAD-TRAILER"
      )
      |> call()

    assert missing_trailer.status == 400
    assert missing_trailer.resp_body =~ "IncompleteBody"
    assert BucketConfigs.get("corschunked", :cors) == :none

    bad =
      SigV4Request.signed_chunked_conn(:put, "/corschunked", @cors,
        query: %{"cors" => ""},
        headers: [
          {"content-md5", content_md5(@cors)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256("different")}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert BucketConfigs.get("corschunked", :cors) == :none

    ok_trailer =
      SigV4Request.signed_chunked_conn(:put, "/corschunked", @cors,
        query: %{"cors" => ""},
        headers: [
          {"content-md5", content_md5(@cors)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(@cors)}]
      )
      |> call()

    assert ok_trailer.status == 200

    assert {:ok, [%{"allowed_origins" => ["http://www.example.com"]}]} =
             BucketConfigs.get("corschunked", :cors)

    bad_signed_trailer =
      SigV4Request.signed_chunked_conn(:put, "/corschunked", @cors,
        query: %{"cors" => ""},
        headers: [
          {"content-md5", content_md5(@cors)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(@cors)}],
        streaming_payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER",
        tamper: fn chunked ->
          Regex.replace(
            ~r/x-amz-trailer-signature:[0-9a-f]{64}/,
            chunked,
            "x-amz-trailer-signature:" <> String.duplicate("0", 64)
          )
        end
      )
      |> call()

    assert bad_signed_trailer.status == 403
    assert bad_signed_trailer.resp_body =~ "SignatureDoesNotMatch"

    assert {:ok, [%{"allowed_origins" => ["http://www.example.com"]}]} =
             BucketConfigs.get("corschunked", :cors)

    ok_chunked =
      SigV4Request.signed_chunked_conn(:put, "/corschunked", @cors,
        query: %{"cors" => ""},
        headers: [{"content-md5", content_md5(@cors)}]
      )
      |> call()

    assert ok_chunked.status == 200

    oversized = String.duplicate("x", 65_537)

    too_large =
      SigV4Request.signed_chunked_conn(:put, "/corschunked", oversized,
        query: %{"cors" => ""},
        chunk_size: byte_size(oversized),
        decoded_length_override: 65_536,
        headers: [{"content-md5", content_md5(oversized)}]
      )
      |> call()

    assert too_large.status == 400
    assert too_large.resp_body =~ "MalformedXML"
    assert too_large.resp_body =~ "CORS configuration exceeds 64KB"

    assert {:ok, [%{"allowed_origins" => ["http://www.example.com"]}]} =
             BucketConfigs.get("corschunked", :cors)
  end
end
