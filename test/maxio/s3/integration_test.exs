defmodule Maxio.S3.IntegrationTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Auth.SigV4.Presigner
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint
  alias Maxio.Cluster.{Paths, ShardServer}
  alias Maxio.Cluster.Transport.InProcess

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
  defp checksum_b64(algorithm, body), do: :crypto.hash(algorithm, body) |> Base.encode64()

  defp lock_resource(bucket, key) do
    parent = self()
    resource = {bucket, key}

    pid =
      spawn(fn ->
        {:ok, lease} = Maxio.Cluster.Lock.acquire(resource, nodes: [Node.self()], refresh: false)
        send(parent, {:locked, self()})

        receive do
          :release -> Maxio.Cluster.Lock.release(lease)
        end
      end)

    assert_receive {:locked, ^pid}
    on_exit(fn -> send(pid, :release) end)
    pid
  end

  defp with_sidecar_read_quorum_env(fun) do
    InProcess.setup!()

    prev_auth = Application.get_env(:maxio, :authoritative_source)
    prev_tx = Application.get_env(:maxio, :shard_transport)
    prev_ec = Application.get_env(:maxio, :erasure)

    prev_topology =
      try do
        {:ok, :persistent_term.get({Maxio.Cluster.Topology, :topology})}
      rescue
        ArgumentError -> :error
      end

    Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :pg, write: :pg)
    Application.put_env(:maxio, :shard_transport, InProcess)

    Application.put_env(:maxio, :erasure,
      drives: ["d0", "d1", "d2"],
      data_shards: 2,
      parity_shards: 1,
      block_size: 1024
    )

    eps =
      for i <- 0..2,
          do:
            {:"objcondrq#{i}",
             Path.join(
               System.tmp_dir!(),
               "obj_cond_rq_#{i}_#{System.unique_integer([:positive])}"
             )}

    topo = %{
      data_shards: 2,
      parity_shards: 1,
      block_size: 1024,
      sets: %{0 => %{id: 0, endpoints: eps}},
      set_ids: [0]
    }

    :persistent_term.put({Maxio.Cluster.Topology, :topology}, topo)

    on_exit(fn ->
      case prev_topology do
        {:ok, topology} -> :persistent_term.put({Maxio.Cluster.Topology, :topology}, topology)
        :error -> :persistent_term.erase({Maxio.Cluster.Topology, :topology})
      end

      restore_env(:authoritative_source, prev_auth)
      restore_env(:shard_transport, prev_tx)
      restore_env(:erasure, prev_ec)
      Enum.each(eps, fn {_node, dir} -> File.rm_rf(dir) end)
    end)

    fun.(eps)
  end

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)

  defp call_presigned_url(url, now, method \\ :get, body \\ "") do
    uri = URI.parse(url)

    Plug.Test.conn(method, uri.path <> "?" <> uri.query, body)
    |> Map.put(:host, uri.host)
    |> Map.put(:port, uri.port || 80)
    |> put_private(:maxio_now, now)
    |> call()
  end

  defp put_single_sidecar!(eps, bucket, key, object_meta) do
    [{_node, drive} | _] = eps
    {:ok, rel} = Paths.object_rel(bucket, key, "null")
    ShardServer.put_sidecar(Path.join(drive, rel), object_meta)
  end

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

  test "GetObject/HeadObject 签名请求支持 response header override" do
    SigV4Request.signed_conn(:put, "/override") |> call()

    SigV4Request.signed_conn(:put, "/override/report.bin",
      body: "report",
      headers: [
        {"content-type", "application/octet-stream"},
        {"cache-control", "max-age=60"},
        {"content-disposition", "inline"}
      ]
    )
    |> call()

    overrides = %{
      "response-cache-control" => "no-store",
      "response-content-disposition" => "attachment",
      "response-content-encoding" => "identity",
      "response-content-language" => "zh-CN",
      "response-content-type" => "text/plain",
      "response-expires" => "2037-10-21T07:28:00Z"
    }

    get = SigV4Request.signed_conn(:get, "/override/report.bin", query: overrides) |> call()

    assert get.status == 200
    assert get.resp_body == "report"
    assert get_resp_header(get, "cache-control") == ["no-store"]
    assert get_resp_header(get, "content-disposition") == ["attachment"]
    assert get_resp_header(get, "content-encoding") == ["identity"]
    assert get_resp_header(get, "content-language") == ["zh-CN"]
    assert get_resp_header(get, "content-type") == ["text/plain"]
    assert get_resp_header(get, "expires") == ["2037-10-21T07:28:00Z"]

    head =
      SigV4Request.signed_conn(:head, "/override/report.bin",
        query: %{"response-content-type" => "text/csv"}
      )
      |> call()

    assert head.status == 200
    assert head.resp_body == ""
    assert get_resp_header(head, "content-type") == ["text/csv"]
    assert get_resp_header(head, "content-length") == ["6"]
  end

  test "production presigner generated GET URL is accepted by S3 endpoint" do
    now = DateTime.utc_now()
    SigV4Request.signed_conn(:put, "/presign") |> call()
    SigV4Request.signed_conn(:put, "/presign/shared.txt", body: "share me") |> call()

    assert {:ok, url} =
             Presigner.presign_url(
               :get,
               "http://localhost",
               "/presign/shared.txt",
               %{
                 access_key: SigV4Request.access_key(),
                 secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
               },
               now: now,
               region: "us-east-1",
               expires: 300
             )

    conn = call_presigned_url(url, now)

    assert conn.status == 200
    assert conn.resp_body == "share me"
  end

  test "production presigner generated PUT URL is accepted by S3 endpoint" do
    now = ~U[2026-06-28 04:00:00Z]
    SigV4Request.signed_conn(:put, "/presignput") |> call()

    assert {:ok, url} =
             Presigner.presign_url(
               :put,
               "http://localhost:9900",
               "/presignput/upload.txt",
               %{
                 access_key: SigV4Request.access_key(),
                 secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
               },
               now: now,
               region: "us-east-1",
               expires: 300
             )

    put = call_presigned_url(url, now, :put, "uploaded with put")
    assert put.status == 200
    assert get_resp_header(put, "etag") != []

    get = SigV4Request.signed_conn(:get, "/presignput/upload.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "uploaded with put"

    wrong_method = call_presigned_url(url, now, :get)
    assert wrong_method.status == 403
    assert wrong_method.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"
  end

  test "production presigned GET URL expires and tampering is rejected" do
    now = ~U[2026-06-28 01:00:00Z]
    SigV4Request.signed_conn(:put, "/presignbad") |> call()
    SigV4Request.signed_conn(:put, "/presignbad/shared.txt", body: "share me") |> call()

    assert {:ok, url} =
             Presigner.presign_url(
               :get,
               "http://localhost:9900",
               "/presignbad/shared.txt",
               %{
                 access_key: SigV4Request.access_key(),
                 secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
               },
               now: now,
               region: "us-east-1",
               expires: 60
             )

    valid = call_presigned_url(url, now)
    assert valid.status == 200
    assert valid.resp_body == "share me"

    expired = call_presigned_url(url, DateTime.add(now, 61, :second))
    assert expired.status == 403
    assert expired.resp_body =~ "<Code>AccessDenied</Code>"
    assert expired.resp_body =~ "Request has expired"

    tampered = String.replace(url, "shared.txt", "other.txt")
    rejected = call_presigned_url(tampered, now)
    assert rejected.status == 403
    assert rejected.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"
  end

  test "production presigned GET URL can target a specific version" do
    now = ~U[2026-06-28 02:00:00Z]
    SigV4Request.signed_conn(:put, "/presignver") |> call()

    versioning_xml =
      ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/presignver",
      query: %{"versioning" => ""},
      body: versioning_xml
    )
    |> call()

    put_v1 = SigV4Request.signed_conn(:put, "/presignver/shared.txt", body: "first") |> call()
    assert [version_1] = get_resp_header(put_v1, "x-amz-version-id")

    put_v2 = SigV4Request.signed_conn(:put, "/presignver/shared.txt", body: "second") |> call()
    assert [version_2] = get_resp_header(put_v2, "x-amz-version-id")
    assert version_1 != version_2

    assert {:ok, url} =
             Presigner.presign_url(
               :get,
               "http://localhost:9900",
               "/presignver/shared.txt",
               %{
                 access_key: SigV4Request.access_key(),
                 secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
               },
               now: now,
               region: "us-east-1",
               expires: 300,
               query: %{"versionId" => version_1}
             )

    old_version = call_presigned_url(url, now)
    assert old_version.status == 200
    assert old_version.resp_body == "first"
    assert get_resp_header(old_version, "x-amz-version-id") == [version_1]

    tampered = String.replace(url, "versionId=#{version_1}", "versionId=#{version_2}")
    rejected = call_presigned_url(tampered, now)
    assert rejected.status == 403
    assert rejected.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"
  end

  test "production presigned GET URL signs response header overrides" do
    now = ~U[2026-06-28 03:00:00Z]
    SigV4Request.signed_conn(:put, "/presignoverride") |> call()

    SigV4Request.signed_conn(:put, "/presignoverride/shared.txt",
      body: "share me",
      headers: [{"content-type", "application/octet-stream"}]
    )
    |> call()

    assert {:ok, url} =
             Presigner.presign_url(
               :get,
               "http://localhost:9900",
               "/presignoverride/shared.txt",
               %{
                 access_key: SigV4Request.access_key(),
                 secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
               },
               now: now,
               region: "us-east-1",
               expires: 300,
               query: %{
                 "response-cache-control" => "max-age=3600",
                 "response-content-disposition" => ~s(attachment; filename="shared.txt"),
                 "response-content-type" => "text/plain"
               }
             )

    valid = call_presigned_url(url, now)
    assert valid.status == 200
    assert valid.resp_body == "share me"
    assert get_resp_header(valid, "cache-control") == ["max-age=3600"]

    assert get_resp_header(valid, "content-disposition") == [
             ~s(attachment; filename="shared.txt")
           ]

    assert get_resp_header(valid, "content-type") == ["text/plain"]

    tampered = String.replace(url, "max-age%3D3600", "max-age%3D0")
    rejected = call_presigned_url(tampered, now)
    assert rejected.status == 403
    assert rejected.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"
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

  test "empty object suffix Range → 416 InvalidRange" do
    SigV4Request.signed_conn(:put, "/emptyrange") |> call()
    SigV4Request.signed_conn(:put, "/emptyrange/k.txt", body: "") |> call()

    get =
      SigV4Request.signed_conn(:get, "/emptyrange/k.txt", headers: [{"range", "bytes=-1"}])
      |> call()

    assert get.status == 416
    assert get.resp_body =~ "<Code>InvalidRange</Code>"
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

  test "DeleteObjects requires Content-MD5 and validates checksum trailers before deleting" do
    SigV4Request.signed_conn(:put, "/delchecksum") |> call()
    SigV4Request.signed_conn(:put, "/delchecksum/a", body: "1") |> call()
    SigV4Request.signed_conn(:put, "/delchecksum/b", body: "2") |> call()
    SigV4Request.signed_conn(:put, "/delchecksum/c", body: "3") |> call()

    xml = "<Delete><Object><Key>a</Key></Object><Object><Key>b</Key></Object></Delete>"

    missing_md5 =
      SigV4Request.signed_conn(:post, "/delchecksum",
        query: %{"delete" => ""},
        body: xml,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum_b64(:sha256, xml)}
        ],
        auto_content_md5: false
      )
      |> call()

    assert missing_md5.status == 400
    assert missing_md5.resp_body =~ "<Code>MissingSecurityHeader</Code>"
    assert (SigV4Request.signed_conn(:head, "/delchecksum/a") |> call()).status == 200
    assert (SigV4Request.signed_conn(:head, "/delchecksum/b") |> call()).status == 200

    bad_md5 =
      SigV4Request.signed_conn(:post, "/delchecksum",
        query: %{"delete" => ""},
        body: xml,
        headers: [{"content-md5", checksum_b64(:md5, "different")}],
        auto_content_md5: false
      )
      |> call()

    assert bad_md5.status == 400
    assert bad_md5.resp_body =~ "<Code>BadDigest</Code>"
    assert (SigV4Request.signed_conn(:head, "/delchecksum/a") |> call()).status == 200
    assert (SigV4Request.signed_conn(:head, "/delchecksum/b") |> call()).status == 200

    bad_trailer =
      SigV4Request.signed_chunked_conn(:post, "/delchecksum", xml,
        query: %{"delete" => ""},
        headers: [
          {"content-md5", checksum_b64(:md5, xml)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", checksum_b64(:sha256, "different")}],
        auto_content_md5: false
      )
      |> call()

    assert bad_trailer.status == 400
    assert bad_trailer.resp_body =~ "<Code>BadDigest</Code>"
    assert (SigV4Request.signed_conn(:head, "/delchecksum/a") |> call()).status == 200
    assert (SigV4Request.signed_conn(:head, "/delchecksum/b") |> call()).status == 200

    ok_trailer =
      SigV4Request.signed_chunked_conn(:post, "/delchecksum", xml,
        query: %{"delete" => ""},
        headers: [
          {"content-md5", checksum_b64(:md5, xml)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", checksum_b64(:sha256, xml)}],
        auto_content_md5: false
      )
      |> call()

    assert ok_trailer.status == 200
    assert ok_trailer.resp_body =~ "<Deleted><Key>a</Key></Deleted>"
    assert ok_trailer.resp_body =~ "<Deleted><Key>b</Key></Deleted>"
    assert (SigV4Request.signed_conn(:head, "/delchecksum/a") |> call()).status == 404
    assert (SigV4Request.signed_conn(:head, "/delchecksum/b") |> call()).status == 404
    assert (SigV4Request.signed_conn(:head, "/delchecksum/c") |> call()).status == 200
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

  test "PutObject If-None-Match star prevents overwrites and allows absent targets" do
    SigV4Request.signed_conn(:put, "/putcondnone") |> call()
    SigV4Request.signed_conn(:put, "/putcondnone/existing.txt", body: "old") |> call()

    rejected =
      SigV4Request.signed_conn(:put, "/putcondnone/existing.txt",
        body: "new",
        headers: [{"if-none-match", "*"}]
      )
      |> call()

    assert rejected.status == 412
    assert rejected.resp_body =~ "<Code>PreconditionFailed</Code>"

    unchanged = SigV4Request.signed_conn(:get, "/putcondnone/existing.txt") |> call()
    assert unchanged.status == 200
    assert unchanged.resp_body == "old"

    accepted =
      SigV4Request.signed_conn(:put, "/putcondnone/fresh.txt",
        body: "fresh",
        headers: [{"if-none-match", "*"}]
      )
      |> call()

    assert accepted.status == 200

    get = SigV4Request.signed_conn(:get, "/putcondnone/fresh.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "fresh"
  end

  test "PutObject If-Match requires the current target ETag" do
    SigV4Request.signed_conn(:put, "/putcondmatch") |> call()
    put = SigV4Request.signed_conn(:put, "/putcondmatch/object.txt", body: "old") |> call()
    [etag] = get_resp_header(put, "etag")

    rejected =
      SigV4Request.signed_conn(:put, "/putcondmatch/object.txt",
        body: "bad",
        headers: [{"if-match", "\"wrong\""}]
      )
      |> call()

    assert rejected.status == 412

    missing =
      SigV4Request.signed_conn(:put, "/putcondmatch/missing.txt",
        body: "bad",
        headers: [{"if-match", etag}]
      )
      |> call()

    assert missing.status == 404
    assert missing.resp_body =~ "<Code>NoSuchKey</Code>"

    accepted =
      SigV4Request.signed_conn(:put, "/putcondmatch/object.txt",
        body: "new",
        headers: [{"if-match", etag}]
      )
      |> call()

    assert accepted.status == 200

    get = SigV4Request.signed_conn(:get, "/putcondmatch/object.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "new"
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

  test "CopyObject If-None-Match star prevents target overwrites" do
    SigV4Request.signed_conn(:put, "/copycondnone") |> call()
    SigV4Request.signed_conn(:put, "/copycondnone/src.txt", body: "source") |> call()
    SigV4Request.signed_conn(:put, "/copycondnone/existing.txt", body: "old") |> call()

    rejected =
      SigV4Request.signed_conn(:put, "/copycondnone/existing.txt",
        headers: [
          {"x-amz-copy-source", "/copycondnone/src.txt"},
          {"if-none-match", "*"}
        ]
      )
      |> call()

    assert rejected.status == 412
    assert rejected.resp_body =~ "<Code>PreconditionFailed</Code>"

    unchanged = SigV4Request.signed_conn(:get, "/copycondnone/existing.txt") |> call()
    assert unchanged.status == 200
    assert unchanged.resp_body == "old"

    accepted =
      SigV4Request.signed_conn(:put, "/copycondnone/fresh.txt",
        headers: [
          {"x-amz-copy-source", "/copycondnone/src.txt"},
          {"if-none-match", "*"}
        ]
      )
      |> call()

    assert accepted.status == 200

    get = SigV4Request.signed_conn(:get, "/copycondnone/fresh.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "source"
  end

  test "CopyObject If-Match requires the current target ETag" do
    SigV4Request.signed_conn(:put, "/copycondmatch") |> call()
    SigV4Request.signed_conn(:put, "/copycondmatch/src.txt", body: "source") |> call()
    put = SigV4Request.signed_conn(:put, "/copycondmatch/dst.txt", body: "old") |> call()
    [etag] = get_resp_header(put, "etag")

    rejected =
      SigV4Request.signed_conn(:put, "/copycondmatch/dst.txt",
        headers: [
          {"x-amz-copy-source", "/copycondmatch/src.txt"},
          {"if-match", "\"wrong\""}
        ]
      )
      |> call()

    assert rejected.status == 412

    missing =
      SigV4Request.signed_conn(:put, "/copycondmatch/missing.txt",
        headers: [
          {"x-amz-copy-source", "/copycondmatch/src.txt"},
          {"if-match", etag}
        ]
      )
      |> call()

    assert missing.status == 404
    assert missing.resp_body =~ "<Code>NoSuchKey</Code>"

    accepted =
      SigV4Request.signed_conn(:put, "/copycondmatch/dst.txt",
        headers: [
          {"x-amz-copy-source", "/copycondmatch/src.txt"},
          {"if-match", etag}
        ]
      )
      |> call()

    assert accepted.status == 200

    get = SigV4Request.signed_conn(:get, "/copycondmatch/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "source"
  end

  test "conditional writes treat current delete markers as absent" do
    SigV4Request.signed_conn(:put, "/condmarker") |> call()

    versioning_xml =
      ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/condmarker",
      query: %{"versioning" => ""},
      body: versioning_xml
    )
    |> call()

    SigV4Request.signed_conn(:put, "/condmarker/src.txt", body: "source") |> call()
    SigV4Request.signed_conn(:put, "/condmarker/dst.txt", body: "old") |> call()
    delete = SigV4Request.signed_conn(:delete, "/condmarker/dst.txt") |> call()
    assert delete.status == 204

    put =
      SigV4Request.signed_conn(:put, "/condmarker/dst.txt",
        body: "new",
        headers: [{"if-none-match", "*"}]
      )
      |> call()

    assert put.status == 200

    SigV4Request.signed_conn(:delete, "/condmarker/dst.txt") |> call()

    copy =
      SigV4Request.signed_conn(:put, "/condmarker/dst.txt",
        headers: [
          {"x-amz-copy-source", "/condmarker/src.txt"},
          {"if-match", "\"old\""}
        ]
      )
      |> call()

    assert copy.status == 404
    assert copy.resp_body =~ "<Code>NoSuchKey</Code>"
  end

  test "PutObject and CopyObject conditional lock conflicts map to ConditionalRequestConflict" do
    SigV4Request.signed_conn(:put, "/condlock") |> call()
    SigV4Request.signed_conn(:put, "/condlock/src.txt", body: "source") |> call()

    put_lock = lock_resource("condlock", "put.txt")

    put =
      SigV4Request.signed_conn(:put, "/condlock/put.txt",
        body: "new",
        headers: [{"if-none-match", "*"}]
      )
      |> call()

    assert put.status == 409
    assert put.resp_body =~ "<Code>ConditionalRequestConflict</Code>"

    ref = Process.monitor(put_lock)
    send(put_lock, :release)
    assert_receive {:DOWN, ^ref, :process, ^put_lock, :normal}

    copy_lock = lock_resource("condlock", "copy.txt")

    copy =
      SigV4Request.signed_conn(:put, "/condlock/copy.txt",
        headers: [
          {"x-amz-copy-source", "/condlock/src.txt"},
          {"if-none-match", "*"}
        ]
      )
      |> call()

    assert copy.status == 409
    assert copy.resp_body =~ "<Code>ConditionalRequestConflict</Code>"

    ref = Process.monitor(copy_lock)
    send(copy_lock, :release)
    assert_receive {:DOWN, ^ref, :process, ^copy_lock, :normal}
  end

  test "PutObject conditional target read quorum failure maps to SlowDownRead" do
    with_sidecar_read_quorum_env(fn eps ->
      bucket = "putcondrq"
      key = "object.bin"

      SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

      put_single_sidecar!(eps, bucket, key, %{
        "format" => "maxio/2",
        "versions" => [
          %{
            "version_id" => "null",
            "type" => "object",
            "is_latest" => true,
            "modtime" => 5,
            "generation" => 0,
            "etag" => "\"old\"",
            "size" => 3,
            "content_type" => "text/plain"
          }
        ]
      })

      rejected =
        SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
          body: "new",
          headers: [{"if-none-match", "*"}]
        )
        |> call()

      assert rejected.status == 503
      assert rejected.resp_body =~ "<Code>SlowDownRead</Code>"
    end)
  end

  test "CopyObject conditional target read quorum is checked before source lookup" do
    with_sidecar_read_quorum_env(fn eps ->
      bucket = "copycondrq"
      key = "dst.txt"

      SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

      put_single_sidecar!(eps, bucket, key, %{
        "format" => "maxio/2",
        "versions" => [
          %{
            "version_id" => "null",
            "type" => "object",
            "is_latest" => true,
            "modtime" => 5,
            "generation" => 0,
            "etag" => "\"old\"",
            "size" => 3,
            "content_type" => "text/plain"
          }
        ]
      })

      rejected =
        SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
          headers: [
            {"x-amz-copy-source", "/#{bucket}/missing-source.txt"},
            {"if-none-match", "*"}
          ]
        )
        |> call()

      assert rejected.status == 503
      assert rejected.resp_body =~ "<Code>SlowDownRead</Code>"
    end)
  end

  test "CopyObject source delete-marker version returns structured 400" do
    SigV4Request.signed_conn(:put, "/copydm") |> call()

    versioning_xml =
      ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/copydm", query: %{"versioning" => ""}, body: versioning_xml)
    |> call()

    SigV4Request.signed_conn(:put, "/copydm/s.txt", body: "y") |> call()

    delete = SigV4Request.signed_conn(:delete, "/copydm/s.txt") |> call()
    assert delete.status == 204
    assert ["true"] = get_resp_header(delete, "x-amz-delete-marker")
    assert [delete_marker_version_id] = get_resp_header(delete, "x-amz-version-id")

    copy =
      SigV4Request.signed_conn(:put, "/copydm/d.txt",
        headers: [{"x-amz-copy-source", "/copydm/s.txt?versionId=#{delete_marker_version_id}"}]
      )
      |> call()

    assert copy.status == 400
    assert copy.resp_body =~ "<Code>InvalidArgument</Code>"
  end
end
