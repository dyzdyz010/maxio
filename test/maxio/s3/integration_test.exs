defmodule Maxio.S3.IntegrationTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_int_test")

  setup do
    # 隔离对象数据目录（避免污染 dev/test 共享目录）
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

  test "CreateBucket → 200 + Location 头" do
    conn = SigV4Request.signed_conn(:put, "/mybucket") |> call()
    assert conn.status == 200
    assert get_resp_header(conn, "location") == ["/mybucket"]
  end

  test "ListBuckets 列出已创建的桶" do
    SigV4Request.signed_conn(:put, "/b-one") |> call()
    SigV4Request.signed_conn(:put, "/b-two") |> call()

    conn = SigV4Request.signed_conn(:get, "/") |> call()
    assert conn.status == 200
    assert conn.resp_body =~ "<Name>b-one</Name>"
    assert conn.resp_body =~ "<Name>b-two</Name>"
  end

  test "PutObject 流式 → GetObject 取回完整内容 + ETag" do
    SigV4Request.signed_conn(:put, "/data") |> call()

    body = "Welcome to Amazon S3."

    put =
      SigV4Request.signed_conn(:put, "/data/hello.txt",
        body: body,
        headers: [{"content-type", "text/plain"}]
      )
      |> call()

    assert put.status == 200
    expected_etag = "\"" <> (:crypto.hash(:md5, body) |> Base.encode16(case: :lower)) <> "\""
    assert get_resp_header(put, "etag") == [expected_etag]

    get = SigV4Request.signed_conn(:get, "/data/hello.txt") |> call()
    assert get.status == 200
    assert get.resp_body == body
    assert get_resp_header(get, "content-type") == ["text/plain"]
    assert get_resp_header(get, "etag") == [expected_etag]
  end

  test "GetObject Range → 206 + Content-Range + 区间内容" do
    SigV4Request.signed_conn(:put, "/data") |> call()
    SigV4Request.signed_conn(:put, "/data/r.txt", body: "0123456789") |> call()

    get =
      SigV4Request.signed_conn(:get, "/data/r.txt", headers: [{"range", "bytes=2-5"}]) |> call()

    assert get.status == 206
    assert get_resp_header(get, "content-range") == ["bytes 2-5/10"]
    assert get.resp_body == "2345"
  end

  test "HeadObject → 200 空体 + 元数据头" do
    SigV4Request.signed_conn(:put, "/data") |> call()
    SigV4Request.signed_conn(:put, "/data/h.txt", body: "abc") |> call()

    head = SigV4Request.signed_conn(:head, "/data/h.txt") |> call()
    assert head.status == 200
    assert head.resp_body == ""
    assert get_resp_header(head, "content-length") == ["3"]
  end

  test "DeleteObject → 204；再 Get → 404 NoSuchKey" do
    SigV4Request.signed_conn(:put, "/data") |> call()
    SigV4Request.signed_conn(:put, "/data/d.txt", body: "x") |> call()

    del = SigV4Request.signed_conn(:delete, "/data/d.txt") |> call()
    assert del.status == 204

    get = SigV4Request.signed_conn(:get, "/data/d.txt") |> call()
    assert get.status == 404
    assert get.resp_body =~ "<Code>NoSuchKey</Code>"
  end

  test "ListObjectsV2 prefix + delimiter → CommonPrefixes" do
    SigV4Request.signed_conn(:put, "/listbk") |> call()

    for k <- ~w(photos/2006/a photos/2007/b top.txt) do
      SigV4Request.signed_conn(:put, "/listbk/#{k}", body: "z") |> call()
    end

    conn =
      SigV4Request.signed_conn(:get, "/listbk",
        query: %{"list-type" => "2", "prefix" => "photos/", "delimiter" => "/"}
      )
      |> call()

    assert conn.status == 200
    assert conn.resp_body =~ "<CommonPrefixes><Prefix>photos/2006/</Prefix></CommonPrefixes>"
    assert conn.resp_body =~ "<CommonPrefixes><Prefix>photos/2007/</Prefix></CommonPrefixes>"
  end

  test "GetBucketLocation us-east-1 返回空体" do
    SigV4Request.signed_conn(:put, "/loc") |> call()
    conn = SigV4Request.signed_conn(:get, "/loc", query: %{"location" => ""}) |> call()
    assert conn.status == 200
    assert conn.resp_body =~ "<LocationConstraint"
    refute conn.resp_body =~ "us-east-1"
  end

  test "DeleteBucket 非空 → 409 BucketNotEmpty；空桶 → 204" do
    SigV4Request.signed_conn(:put, "/delbk") |> call()
    SigV4Request.signed_conn(:put, "/delbk/o", body: "x") |> call()

    busy = SigV4Request.signed_conn(:delete, "/delbk") |> call()
    assert busy.status == 409
    assert busy.resp_body =~ "<Code>BucketNotEmpty</Code>"

    SigV4Request.signed_conn(:delete, "/delbk/o") |> call()
    ok = SigV4Request.signed_conn(:delete, "/delbk") |> call()
    assert ok.status == 204
  end

  test "未知桶 GetObject → 404 NoSuchBucket" do
    conn = SigV4Request.signed_conn(:get, "/ghost/key") |> call()
    assert conn.status == 404
    assert conn.resp_body =~ "<Code>NoSuchBucket</Code>"
  end

  # ── 铁律 5：含尾/连续/前导斜杠的 key 端到端不丢数据、签名不误判（修复回归）──
  # 旧实现从折叠空段的 conn.path_info 重建路径：CanonicalURI ≠ 客户端签名路径 → 误 403，
  # 且 key 退化丢字节。下列用例证明改用原始 request_path 后签名通过且 key 完整 round-trip。
  test "folder marker 'dir/' 端到端：PUT 不误 403、key 完整保留、GET 取回" do
    SigV4Request.signed_conn(:put, "/marker") |> call()

    put = SigV4Request.signed_conn(:put, "/marker/dir/", body: "") |> call()
    # 关键：不再是 403 SignatureDoesNotMatch
    refute put.resp_body =~ "SignatureDoesNotMatch"
    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/marker/dir/") |> call()
    assert get.status == 200
    assert get.resp_body == ""
  end

  test "连续斜杠 key 'a//b.txt' 端到端 round-trip（不折叠空段）" do
    SigV4Request.signed_conn(:put, "/cons") |> call()

    put = SigV4Request.signed_conn(:put, "/cons/a//b.txt", body: "payload") |> call()
    refute put.resp_body =~ "SignatureDoesNotMatch"
    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/cons/a//b.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "payload"

    # 折叠后的 a/b.txt 不应存在（证明空段被忠实保留为不同的 key）
    miss = SigV4Request.signed_conn(:get, "/cons/a/b.txt") |> call()
    assert miss.status == 404
  end

  test "前导斜杠 key '/leading.txt' 端到端 round-trip" do
    SigV4Request.signed_conn(:put, "/lead") |> call()

    put = SigV4Request.signed_conn(:put, "/lead//leading.txt", body: "L") |> call()
    refute put.resp_body =~ "SignatureDoesNotMatch"
    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/lead//leading.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "L"
  end

  # ── MinIO-fidelity：相邻 key 绝不在盘上互相别名（'a//b'↔'a/b'、'dir/'↔'dir' 曾静默同路径
  #    = 后写者覆写前者字节）。Paths.encode_key 段编码使两者各落各的盘路径。──
  test "'a//b.txt' 与 'a/b.txt' 共存：各自字节独立，互不覆写（曾盘上别名）" do
    SigV4Request.signed_conn(:put, "/alias") |> call()

    assert SigV4Request.signed_conn(:put, "/alias/a//b.txt", body: "double-slash bytes")
           |> call()
           |> Map.fetch!(:status) == 200

    assert SigV4Request.signed_conn(:put, "/alias/a/b.txt", body: "single-slash bytes")
           |> call()
           |> Map.fetch!(:status) == 200

    # 第二个 PUT 绝不覆写第一个 key 的字节。
    g1 = SigV4Request.signed_conn(:get, "/alias/a//b.txt") |> call()
    assert g1.status == 200
    assert g1.resp_body == "double-slash bytes"

    g2 = SigV4Request.signed_conn(:get, "/alias/a/b.txt") |> call()
    assert g2.status == 200
    assert g2.resp_body == "single-slash bytes"
  end

  test "'dir/'（folder marker）与 'dir' 共存：两个独立对象（对齐 AWS；MinIO 以 __XLDIR__ 同构区分）" do
    SigV4Request.signed_conn(:put, "/alias2") |> call()

    assert SigV4Request.signed_conn(:put, "/alias2/dir", body: "plain object")
           |> call()
           |> Map.fetch!(:status) == 200

    assert SigV4Request.signed_conn(:put, "/alias2/dir/", body: "")
           |> call()
           |> Map.fetch!(:status) == 200

    g1 = SigV4Request.signed_conn(:get, "/alias2/dir") |> call()
    assert g1.status == 200
    assert g1.resp_body == "plain object"

    g2 = SigV4Request.signed_conn(:get, "/alias2/dir/") |> call()
    assert g2.status == 200
    assert g2.resp_body == ""
  end

  test "保留布局名 key（data/meta.json）普通 round-trip；不存在时 404 NoSuchKey（对齐 MinIO/AWS）" do
    SigV4Request.signed_conn(:put, "/resv") |> call()

    miss = SigV4Request.signed_conn(:get, "/resv/data/meta.json") |> call()
    assert miss.status == 404
    assert miss.resp_body =~ "<Code>NoSuchKey</Code>"

    put = SigV4Request.signed_conn(:put, "/resv/data/meta.json", body: "{\"a\":1}") |> call()
    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/resv/data/meta.json") |> call()
    assert get.status == 200
    assert get.resp_body == "{\"a\":1}"
  end

  test "篡改签名 → 403 SignatureDoesNotMatch（非静默）" do
    # 取一个完全合法的自签请求，仅把 Authorization 头里的 Signature=<hex> 篡改为伪值，
    # 其余（scope-date 与 x-amz-date 对齐、Credential、SignedHeaders）保持合法——
    # 故解析/时钟/查 secret 均通过，唯独签名比对失败 → SignatureDoesNotMatch（铁律 3：非静默）。
    conn = SigV4Request.signed_conn(:get, "/")
    [auth] = get_req_header(conn, "authorization")

    tampered_auth =
      String.replace(
        auth,
        ~r/Signature=[0-9a-f]+$/,
        "Signature=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
      )

    bad = put_req_header(conn, "authorization", tampered_auth)
    out = call(bad)
    assert out.status == 403
    assert out.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"
  end

  test "HeadObject 缺失 key → 404 且响应体为空（HEAD 无 body）" do
    SigV4Request.signed_conn(:put, "/headmiss") |> call()
    head = SigV4Request.signed_conn(:head, "/headmiss/nope") |> call()
    assert head.status == 404
    assert head.resp_body == ""
  end

  test "HeadObject 缺失桶 → 404 且响应体为空" do
    head = SigV4Request.signed_conn(:head, "/no-such-bucket-head/x") |> call()
    assert head.status == 404
    assert head.resp_body == ""
  end

  test "PutObject :single 声明 sha256 与实际不符 → 400 XAmzContentSHA256Mismatch" do
    SigV4Request.signed_conn(:put, "/digestbk") |> call()

    bad =
      SigV4Request.signed_conn(:put, "/digestbk/x.txt",
        body: "real-bytes",
        content_sha256_override: String.duplicate("a", 64)
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "<Code>XAmzContentSHA256Mismatch</Code>"
  end

  test "aws-chunked PutObject（单块）→ GET 取回 + ETag 为 MD5（解帧后）" do
    SigV4Request.signed_conn(:put, "/chunkbk") |> call()

    body = "Welcome to Amazon S3."
    put = SigV4Request.signed_chunked_conn(:put, "/chunkbk/c.txt", body) |> call()
    assert put.status == 200
    expected = "\"" <> (:crypto.hash(:md5, body) |> Base.encode16(case: :lower)) <> "\""
    assert get_resp_header(put, "etag") == [expected]

    get = SigV4Request.signed_conn(:get, "/chunkbk/c.txt") |> call()
    assert get.status == 200
    assert get.resp_body == body
  end

  test "aws-chunked PutObject（多块）→ 解帧后内容完整" do
    SigV4Request.signed_conn(:put, "/chunkmb") |> call()

    body = String.duplicate("z", 20)
    put = SigV4Request.signed_chunked_conn(:put, "/chunkmb/m.txt", body, chunk_size: 7) |> call()
    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/chunkmb/m.txt") |> call()
    assert get.resp_body == body
  end

  test "aws-chunked 篡改某块 data → 403 SignatureDoesNotMatch（硬停，绝不落盘）" do
    SigV4Request.signed_conn(:put, "/chunkbad") |> call()

    tamper = fn chunked -> String.replace(chunked, "abcdefghij", "abcdefghiZ") end

    bad =
      SigV4Request.signed_chunked_conn(:put, "/chunkbad/x.txt", "abcdefghij",
        chunk_size: 10,
        tamper: tamper
      )
      |> call()

    assert bad.status == 403
    assert bad.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"

    get = SigV4Request.signed_conn(:get, "/chunkbad/x.txt") |> call()
    assert get.status == 404
  end

  test "aws-chunked 声明 decoded-content-length 与实际不符 → 400 IncompleteBody" do
    SigV4Request.signed_conn(:put, "/chunklen") |> call()

    bad =
      SigV4Request.signed_chunked_conn(:put, "/chunklen/x.txt", "abcdefghij",
        decoded_length_override: 999
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "<Code>IncompleteBody</Code>"
  end

  test "SigV4A 流式（ECDSA）→ 501 NotImplemented" do
    SigV4Request.signed_conn(:put, "/sigv4a") |> call()
    # 直接发一个声明 SigV4A 流式的 PUT（不必合法签名，plug 早拒 501）
    conn =
      SigV4Request.signed_conn(:put, "/sigv4a/x.txt",
        headers: [{"x-amz-content-sha256", "STREAMING-AWS4-ECDSA-P256-SHA256-PAYLOAD"}],
        content_sha256_override: "STREAMING-AWS4-ECDSA-P256-SHA256-PAYLOAD"
      )
      |> call()

    assert conn.status == 501
    assert conn.resp_body =~ "<Code>NotImplemented</Code>"
  end

  test "DeleteObjects 批量删除 → 200 DeleteResult（含缺失 key 也算 success）" do
    SigV4Request.signed_conn(:put, "/batchdel") |> call()
    SigV4Request.signed_conn(:put, "/batchdel/a", body: "1") |> call()
    SigV4Request.signed_conn(:put, "/batchdel/b", body: "2") |> call()

    xml = "<Delete><Object><Key>a</Key></Object><Object><Key>ghost</Key></Object></Delete>"

    del =
      SigV4Request.signed_conn(:post, "/batchdel", query: %{"delete" => ""}, body: xml) |> call()

    assert del.status == 200
    assert del.resp_body =~ "<Deleted><Key>a</Key></Deleted>"
    assert del.resp_body =~ "<Deleted><Key>ghost</Key></Deleted>"

    # a 已删
    assert SigV4Request.signed_conn(:get, "/batchdel/a") |> call() |> Map.get(:status) == 404
    # b 未删
    assert SigV4Request.signed_conn(:get, "/batchdel/b") |> call() |> Map.get(:status) == 200
  end

  test "DeleteObjects quiet 模式不返回 Deleted" do
    SigV4Request.signed_conn(:put, "/quietdel") |> call()
    SigV4Request.signed_conn(:put, "/quietdel/a", body: "1") |> call()

    xml = "<Delete><Quiet>true</Quiet><Object><Key>a</Key></Object></Delete>"

    del =
      SigV4Request.signed_conn(:post, "/quietdel", query: %{"delete" => ""}, body: xml) |> call()

    assert del.status == 200
    refute del.resp_body =~ "<Deleted>"
  end

  test "DeleteObjects 超过 1000 key → 400 MalformedXML" do
    SigV4Request.signed_conn(:put, "/bigdel") |> call()

    objects =
      1..1001
      |> Enum.map(fn n -> "<Object><Key>k#{n}</Key></Object>" end)
      |> Enum.join()

    xml = "<Delete>" <> objects <> "</Delete>"

    del =
      SigV4Request.signed_conn(:post, "/bigdel", query: %{"delete" => ""}, body: xml) |> call()

    assert del.status == 400
    assert del.resp_body =~ "<Code>MalformedXML</Code>"
  end

  test "GET If-None-Match 命中 → 304 无 body" do
    SigV4Request.signed_conn(:put, "/condbk") |> call()
    put = SigV4Request.signed_conn(:put, "/condbk/c.txt", body: "hello") |> call()
    [etag] = get_resp_header(put, "etag")

    get =
      SigV4Request.signed_conn(:get, "/condbk/c.txt", headers: [{"if-none-match", etag}])
      |> call()

    assert get.status == 304
    assert get.resp_body == ""
  end

  test "GET If-Match 不符 → 412" do
    SigV4Request.signed_conn(:put, "/condbk2") |> call()
    SigV4Request.signed_conn(:put, "/condbk2/c.txt", body: "hello") |> call()

    get =
      SigV4Request.signed_conn(:get, "/condbk2/c.txt", headers: [{"if-match", "\"nope\""}])
      |> call()

    assert get.status == 412
    assert get.resp_body =~ "<Code>PreconditionFailed</Code>"
  end

  test "多区间 Range（含逗号）→ 完整 200（对齐 S3，不实现 multipart/byteranges）" do
    SigV4Request.signed_conn(:put, "/multirange") |> call()
    SigV4Request.signed_conn(:put, "/multirange/r.txt", body: "0123456789") |> call()

    get =
      SigV4Request.signed_conn(:get, "/multirange/r.txt", headers: [{"range", "bytes=0-2,5-7"}])
      |> call()

    assert get.status == 200
    assert get.resp_body == "0123456789"
  end

  test "CopyObject 复制源对象到目标 + CopyObjectResult（ETag 一致）" do
    SigV4Request.signed_conn(:put, "/copybk") |> call()
    put = SigV4Request.signed_conn(:put, "/copybk/src.txt", body: "copy-me") |> call()
    [src_etag] = get_resp_header(put, "etag")

    copy =
      SigV4Request.signed_conn(:put, "/copybk/dst.txt",
        headers: [{"x-amz-copy-source", "/copybk/src.txt"}]
      )
      |> call()

    assert copy.status == 200
    assert copy.resp_body =~ "<CopyObjectResult"
    assert copy.resp_body =~ "<ETag>"

    get = SigV4Request.signed_conn(:get, "/copybk/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "copy-me"
    assert get_resp_header(get, "etag") == [src_etag]
  end

  test "CopyObject 自拷贝（COPY 无变化）→ 400 InvalidRequest" do
    SigV4Request.signed_conn(:put, "/selfcopy") |> call()
    SigV4Request.signed_conn(:put, "/selfcopy/x.txt", body: "x") |> call()

    copy =
      SigV4Request.signed_conn(:put, "/selfcopy/x.txt",
        headers: [{"x-amz-copy-source", "/selfcopy/x.txt"}]
      )
      |> call()

    assert copy.status == 400
    assert copy.resp_body =~ "<Code>InvalidRequest</Code>"
  end

  test "CopyObject 源 if-match 不符 → 412" do
    SigV4Request.signed_conn(:put, "/copycond") |> call()
    SigV4Request.signed_conn(:put, "/copycond/s.txt", body: "y") |> call()

    copy =
      SigV4Request.signed_conn(:put, "/copycond/d.txt",
        headers: [
          {"x-amz-copy-source", "/copycond/s.txt"},
          {"x-amz-copy-source-if-match", "\"wrong\""}
        ]
      )
      |> call()

    assert copy.status == 412
  end
end
