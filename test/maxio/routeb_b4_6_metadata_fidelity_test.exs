defmodule Maxio.RouteBB46MetadataFidelityTest do
  @moduledoc """
  ROUTE B B4-6 —— 写路径元数据保真补全（修 B4-5 fidelity 审计的 3 个 medium 偏离）的取证。

    * D1：多段完成对象的 maxio/2 sidecar 透传客户端 Content-Type/user_metadata
      （真实多段 PUT → complete，distributed + InProcess + 注入 topology → 落盘 sidecar
      content_type 为客户端声明值而非 binary/octet-stream，user_metadata 自描述）。
    * D2：PutObject / CopyObject(REPLACE) 加 2 KB 用户元数据上限——超 2048 字节 → 400 MetadataTooLarge，
      恰好 ≤2048 通过（端到端经 Endpoint 自签管线取证）。
    * D3：PutObject 带 x-amz-meta-* → :pg(默认) 与 :sidecar 两路读到的 user metadata 一致
      （断言 %Object{}.metadata 两路相等，消除 B4-5 引入的读分裂）。

  **严禁手搓 sidecar** —— D1/D3 sidecar 侧全部经真实写路径取证。
  """
  use Maxio.DataCase, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias Maxio.{Multipart, ObjectMeta, Objects, Sidecar, Storage}
  alias Maxio.Cluster.{Paths, Transport.InProcess}
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @bucket "rb46"
  @data_dir Path.join(System.tmp_dir!(), "maxio_b4_6")

  # ── D1：多段 sidecar 透传 content_type/user_metadata（distributed + InProcess + topology）──

  describe "D1 — 多段完成对象 sidecar 透传 content_type/user_metadata" do
    setup do
      InProcess.setup!()

      prev_backend = Application.get_env(:maxio, :storage_backend)
      Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)

      eps =
        for i <- 0..2,
            do:
              {:"mp#{i}",
               Path.join(System.tmp_dir!(), "b46_d#{i}_#{System.unique_integer([:positive])}")}

      # K=2 M=1 N=3 → read_quorum=2、write_quorum=3，单 set（与 B4-5 e2e 套件一致）。
      topo = %{
        data_shards: 2,
        parity_shards: 1,
        block_size: 1024,
        sets: %{0 => %{id: 0, endpoints: eps}},
        set_ids: [0]
      }

      on_exit(fn ->
        if prev_backend,
          do: Application.put_env(:maxio, :storage_backend, prev_backend),
          else: Application.delete_env(:maxio, :storage_backend)

        Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end)
      end)

      {:ok, eps: eps, topo: topo}
    end

    test "真实多段 PUT（非默认 content-type + user_metadata）→ complete → 落盘 sidecar 自描述正确", %{
      eps: eps,
      topo: topo
    } do
      opts = [transport: InProcess, topology: topo]
      key = "mpobj"

      # CreateMultipartUpload：会话携带客户端声明的 content_type + user_metadata（落 PG 会话行）。
      {:ok, upload} =
        Multipart.initiate(@bucket, key, %{
          content_type: "image/png",
          owner: "arn:aws:iam:::root",
          metadata: %{"author" => "alice", "team" => "core"}
        })

      # 上传单个 part 字节（distributed 后端，注入 transport/topology）；记录 part 元数据到 PG。
      body = "multipart payload bytes for b4-6 fidelity"

      {:ok, %{etag: part_etag, size: part_size}} =
        Maxio.Storage.Distributed.put_part(@bucket, key, upload.upload_id, 1, [body], opts)

      {:ok, _} = Multipart.put_part(upload, 1, %{etag: part_etag, size: part_size})

      # complete：从会话取 content_type/user_metadata 构造 object_meta，经 Storage.assemble 透传后端。
      # caller opts（transport/topology）一并转发；min_part_size:1 放行单小 part。
      {:ok, %{etag: _mp_etag, size: size}} =
        Multipart.complete(
          upload,
          [%{part_number: 1, etag: part_etag}],
          [min_part_size: 1] ++ opts
        )

      assert size == byte_size(body)

      # 落盘 sidecar（"null" 布局，多段对象落 null）：content_type 为客户端声明值、user_metadata 自描述。
      meta = read_disk_sidecar(eps, key, "null")
      assert meta["format"] == "maxio/2"
      assert [entry] = meta["versions"]
      assert entry["content_type"] == "image/png"
      refute entry["content_type"] == "binary/octet-stream"
      assert entry["user_metadata"] == %{"author" => "alice", "team" => "core"}

      # sidecar entry.etag = 组装后字节的 MD5（耐久核心字段，预存在行为，绝不动）；
      # 与 complete 返回的 multipart ETag（"...-1"）形态不同，故只断言非空 hex，不与 etag 比较。
      assert is_binary(entry["etag"]) and entry["etag"] != ""
      assert entry["size"] == byte_size(body)

      # :sidecar 读 GET 视图：content_type 正确（非 octet-stream）、metadata 自描述。
      read_opts = [transport: InProcess, topology: topo, authoritative_source: [read: :sidecar]]
      obj = ObjectMeta.get(@bucket, key, nil, read_opts)
      assert %Objects.Object{} = obj
      assert obj.content_type == "image/png"
      assert obj.metadata == %{"author" => "alice", "team" => "core"}
      assert obj.size == byte_size(body)
    end

    # 从任一解码盘读出落盘 sidecar（真实多段 complete 写出的，绝不手搓）。
    defp read_disk_sidecar(eps, key, version_id) do
      {:ok, rel} = Paths.object_rel(@bucket, key, version_id)

      Enum.find_value(eps, fn {_n, d} ->
        path = Path.join([d, rel, "meta.json"])

        case File.read(path) do
          {:ok, bin} -> Sidecar.decode!(bin)
          {:error, _} -> nil
        end
      end)
    end
  end

  # ── D2：PutObject / CopyObject(REPLACE) 2 KB 上限（端到端经 Endpoint）──

  describe "D2 — 用户元数据 2 KB 上限（MetadataTooLarge 400）" do
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

    test "PutObject >2 KB x-amz-meta-* → 400 MetadataTooLarge" do
      SigV4Request.signed_conn(:put, "/d2a") |> call()

      # 单个 value 2049 字节。含前缀计量：byte_size("x-amz-meta-big")=14 + 2049 = 2063 > 2048。
      big_value = String.duplicate("x", 2049)

      conn =
        SigV4Request.signed_conn(:put, "/d2a/k.txt",
          body: "payload",
          headers: [{"x-amz-meta-big", big_value}]
        )
        |> call()

      assert conn.status == 400
      assert conn.resp_body =~ "MetadataTooLarge"
      # 失败 pre-commit：对象未落库（无孤儿）。
      assert {:error, :not_found} = Objects.get_metadata("d2a", "k.txt")
    end

    test "PutObject 含前缀计量边界：x-amz-meta-big + 2034B（=2048）通过（200）" do
      SigV4Request.signed_conn(:put, "/d2b") |> call()

      # 镜像 MinIO isHTTPHeaderSizeTooLarge：完整 key byte_size("x-amz-meta-big")=14
      # + value 2034 = 2048（恰好 ≤2048，含前缀计量的上界）。
      ok_value = String.duplicate("x", 2034)

      conn =
        SigV4Request.signed_conn(:put, "/d2b/k.txt",
          body: "payload",
          headers: [{"x-amz-meta-big", ok_value}]
        )
        |> call()

      assert conn.status == 200
      {:ok, obj} = Objects.get_metadata("d2b", "k.txt")
      assert obj.metadata == %{"big" => ok_value}
    end

    test "PutObject 含前缀计量边界：x-amz-meta-big + 2035B（=2049）→ 400 MetadataTooLarge" do
      SigV4Request.signed_conn(:put, "/d2b1") |> call()

      # 完整 key 14 + value 2035 = 2049 > 2048，超 1 字节即拒（边界严格对齐 MinIO；
      # 若不计 x-amz-meta- 前缀则误算 2038 而错误放行——本断言钉死前缀必须计入）。
      over_value = String.duplicate("x", 2035)

      conn =
        SigV4Request.signed_conn(:put, "/d2b1/k.txt",
          body: "payload",
          headers: [{"x-amz-meta-big", over_value}]
        )
        |> call()

      assert conn.status == 400
      assert conn.resp_body =~ "MetadataTooLarge"
      # 失败 pre-commit：对象未落库（无孤儿）。
      assert {:error, :not_found} = Objects.get_metadata("d2b1", "k.txt")
    end

    test "CopyObject(REPLACE) >2 KB x-amz-meta-* → 400 MetadataTooLarge" do
      SigV4Request.signed_conn(:put, "/d2c") |> call()
      SigV4Request.signed_conn(:put, "/d2c/src.txt", body: "x") |> call()

      big_value = String.duplicate("y", 2049)

      conn =
        SigV4Request.signed_conn(:put, "/d2c/dst.txt",
          headers: [
            {"x-amz-copy-source", "/d2c/src.txt"},
            {"x-amz-metadata-directive", "REPLACE"},
            {"x-amz-meta-big", big_value}
          ]
        )
        |> call()

      assert conn.status == 400
      assert conn.resp_body =~ "MetadataTooLarge"
      # 失败 pre-commit：目标未落库（无孤儿）。
      assert {:error, :not_found} = Objects.get_metadata("d2c", "dst.txt")
    end

    test "CopyObject(REPLACE) ≤2 KB x-amz-meta-* 通过（200）" do
      SigV4Request.signed_conn(:put, "/d2d") |> call()
      SigV4Request.signed_conn(:put, "/d2d/src.txt", body: "x") |> call()

      # 含前缀计量：byte_size("x-amz-meta-big")=14 + value 2034 = 2048（恰好 ≤2048）。
      ok_value = String.duplicate("y", 2034)

      conn =
        SigV4Request.signed_conn(:put, "/d2d/dst.txt",
          headers: [
            {"x-amz-copy-source", "/d2d/src.txt"},
            {"x-amz-metadata-directive", "REPLACE"},
            {"x-amz-meta-big", ok_value}
          ]
        )
        |> call()

      assert conn.status == 200
      {:ok, dst} = Objects.get_metadata("d2d", "dst.txt")
      assert dst.metadata == %{"big" => ok_value}
    end

    test "CopyObject(COPY 默认)继承的源 metadata 不触发上限闸（不对历史对象误判）" do
      SigV4Request.signed_conn(:put, "/d2e") |> call()
      SigV4Request.signed_conn(:put, "/d2e/src.txt", body: "x") |> call()

      # COPY（默认 directive）：源 metadata 直接继承，不经请求头上限校验。
      conn =
        SigV4Request.signed_conn(:put, "/d2e/dst.txt",
          headers: [{"x-amz-copy-source", "/d2e/src.txt"}]
        )
        |> call()

      assert conn.status == 200
    end
  end

  # ── D3：PutObject user metadata 进 PG（消除 :pg/:sidecar 读分裂）──

  describe "D3 — PutObject user metadata :pg 与 :sidecar 两路读一致" do
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

    test "PutObject 带 x-amz-meta-* → PG %Object{}.metadata 自描述（D3 消除 PG 侧丢弃）" do
      SigV4Request.signed_conn(:put, "/d3a") |> call()

      conn =
        SigV4Request.signed_conn(:put, "/d3a/k.txt",
          body: "hello",
          headers: [{"x-amz-meta-foo", "bar"}, {"x-amz-meta-color", "blue"}]
        )
        |> call()

      assert conn.status == 200

      # :pg 默认路径读：metadata 已携带 x-amz-meta-*（D3 前为 %{}，分裂；D3 后自描述）。
      {:ok, obj} = Objects.get_metadata("d3a", "k.txt")
      assert obj.metadata == %{"foo" => "bar", "color" => "blue"}
    end

    test ":pg 与 :sidecar 两路读到的 %Object{}.metadata 相等", %{} do
      InProcess.setup!()

      user_metadata = %{"foo" => "bar", "color" => "blue"}

      # :pg 路径：默认 FS 后端 handler PUT（D3 使 PG attrs 携带 metadata）。
      File.rm_rf(@data_dir)
      File.mkdir_p!(@data_dir)
      prev = Application.get_env(:maxio, :s3)
      Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

      SigV4Request.signed_conn(:put, "/d3b") |> call()

      SigV4Request.signed_conn(:put, "/d3b/k.txt",
        body: "hi",
        headers: [{"x-amz-meta-foo", "bar"}, {"x-amz-meta-color", "blue"}]
      )
      |> call()

      {:ok, pg_obj} = Objects.get_metadata("d3b", "k.txt")
      Application.put_env(:maxio, :s3, prev)

      # :sidecar 路径：distributed 真实 PUT（object_meta.user_metadata = 同一 map，模拟 handler 透传），
      # ObjectMeta.get read=:sidecar 从盘上 sidecar 解析 metadata。
      eps =
        for i <- 0..2,
            do:
              {:"d3s#{i}",
               Path.join(System.tmp_dir!(), "b46_d3_#{i}_#{System.unique_integer([:positive])}")}

      topo = %{
        data_shards: 2,
        parity_shards: 1,
        block_size: 1024,
        sets: %{0 => %{id: 0, endpoints: eps}},
        set_ids: [0]
      }

      prev_backend = Application.get_env(:maxio, :storage_backend)
      Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)

      on_exit(fn ->
        if prev_backend,
          do: Application.put_env(:maxio, :storage_backend, prev_backend),
          else: Application.delete_env(:maxio, :storage_backend)

        Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end)
      end)

      put_opts = [transport: InProcess, topology: topo]

      om = %{
        content_type: "text/plain",
        tags: %{},
        sse: nil,
        acl_canned: "private",
        storage_class: "STANDARD",
        user_metadata: user_metadata
      }

      {:ok, _} =
        Storage.put(@bucket, "d3sk", "null", ["hi"], [object_meta: om] ++ put_opts)

      read_opts = [transport: InProcess, topology: topo, authoritative_source: [read: :sidecar]]
      sidecar_obj = ObjectMeta.get(@bucket, "d3sk", nil, read_opts)
      assert %Objects.Object{} = sidecar_obj

      # 两路读到的 user metadata 必须相等（消除 :pg/:sidecar 分裂）。
      assert pg_obj.metadata == user_metadata
      assert sidecar_obj.metadata == user_metadata
      assert pg_obj.metadata == sidecar_obj.metadata
    end
  end

  # ── D4：x-amz-meta-* round-trip（PutObject/CopyObject/MPU 写 → HEAD/GET 回显）──
  #
  # 修 B4-6 审计的 2 个 high 偏离：
  #   (a) GET/HEAD 从不回显 x-amz-meta-* → 真实 SDK 读不回已存元数据（写了不可读）。
  #   (b) CreateMultipartUpload HTTP handler 丢弃 x-amz-meta-* → 多段对象 HEAD/GET 无用户元数据。
  describe "D4 — x-amz-meta-* HTTP round-trip（写入即可经 HEAD/GET 读回）" do
    setup do
      File.rm_rf(@data_dir)
      File.mkdir_p!(@data_dir)
      prev = Application.get_env(:maxio, :s3)
      Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
      Application.put_env(:maxio, :multipart_min_part_size, 1)

      on_exit(fn ->
        Application.put_env(:maxio, :s3, prev)
        Application.delete_env(:maxio, :multipart_min_part_size)
        File.rm_rf(@data_dir)
      end)

      :ok
    end

    test "PutObject(x-amz-meta-*) → HEAD 回显 x-amz-meta-* 响应头" do
      SigV4Request.signed_conn(:put, "/d4a") |> call()

      SigV4Request.signed_conn(:put, "/d4a/k.txt",
        body: "hello",
        headers: [{"x-amz-meta-foo", "bar"}, {"x-amz-meta-color", "blue"}]
      )
      |> call()

      head = SigV4Request.signed_conn(:head, "/d4a/k.txt") |> call()
      assert head.status == 200
      assert get_resp_header(head, "x-amz-meta-foo") == ["bar"]
      assert get_resp_header(head, "x-amz-meta-color") == ["blue"]
    end

    test "PutObject(x-amz-meta-*) → GET 回显 x-amz-meta-* 响应头" do
      SigV4Request.signed_conn(:put, "/d4b") |> call()

      SigV4Request.signed_conn(:put, "/d4b/k.txt",
        body: "hello",
        headers: [{"x-amz-meta-author", "alice"}]
      )
      |> call()

      get = SigV4Request.signed_conn(:get, "/d4b/k.txt") |> call()
      assert get.status == 200
      assert get_resp_header(get, "x-amz-meta-author") == ["alice"]
    end

    test "CopyObject(REPLACE, x-amz-meta-*) → 目标 HEAD 回显新元数据，不继承源" do
      SigV4Request.signed_conn(:put, "/d4c") |> call()

      SigV4Request.signed_conn(:put, "/d4c/src.txt",
        body: "x",
        headers: [{"x-amz-meta-src", "original"}]
      )
      |> call()

      SigV4Request.signed_conn(:put, "/d4c/dst.txt",
        headers: [
          {"x-amz-copy-source", "/d4c/src.txt"},
          {"x-amz-metadata-directive", "REPLACE"},
          {"x-amz-meta-dst", "replaced"}
        ]
      )
      |> call()

      head = SigV4Request.signed_conn(:head, "/d4c/dst.txt") |> call()
      assert head.status == 200
      assert get_resp_header(head, "x-amz-meta-dst") == ["replaced"]
      # REPLACE 不继承源 x-amz-meta-src。
      assert get_resp_header(head, "x-amz-meta-src") == []
    end

    test "CopyObject(COPY 默认) → 目标 HEAD 回显从源继承的元数据" do
      SigV4Request.signed_conn(:put, "/d4d") |> call()

      SigV4Request.signed_conn(:put, "/d4d/src.txt",
        body: "x",
        headers: [{"x-amz-meta-src", "inherited"}]
      )
      |> call()

      SigV4Request.signed_conn(:put, "/d4d/dst.txt",
        headers: [{"x-amz-copy-source", "/d4d/src.txt"}]
      )
      |> call()

      head = SigV4Request.signed_conn(:head, "/d4d/dst.txt") |> call()
      assert head.status == 200
      assert get_resp_header(head, "x-amz-meta-src") == ["inherited"]
    end

    test "Multipart：Create(x-amz-meta-*) → Complete → HEAD/GET 回显用户元数据（PG 路径）" do
      SigV4Request.signed_conn(:put, "/d4e") |> call()

      init =
        SigV4Request.signed_conn(:post, "/d4e/mp.bin",
          query: %{"uploads" => ""},
          headers: [{"content-type", "image/png"}, {"x-amz-meta-author", "alice"}]
        )
        |> call()

      assert init.status == 200
      uid = upload_id(init.resp_body)

      up =
        SigV4Request.signed_conn(:put, "/d4e/mp.bin",
          query: %{"partNumber" => "1", "uploadId" => uid},
          body: "multipart payload"
        )
        |> call()

      assert up.status == 200
      [etag1] = get_resp_header(up, "etag")

      complete_xml =
        "<CompleteMultipartUpload>" <>
          "<Part><PartNumber>1</PartNumber><ETag>#{etag1}</ETag></Part>" <>
          "</CompleteMultipartUpload>"

      complete =
        SigV4Request.signed_conn(:post, "/d4e/mp.bin",
          query: %{"uploadId" => uid},
          body: complete_xml
        )
        |> call()

      assert complete.status == 200

      # 完成对象的 PG 行 metadata 自描述（消除 MPU PG 侧 metadata=%{} 的分裂）。
      {:ok, obj} = Objects.get_metadata("d4e", "mp.bin")
      assert obj.metadata == %{"author" => "alice"}
      assert obj.content_type == "image/png"

      # HEAD/GET 回显 x-amz-meta-author（真实 SDK 多段上传 round-trip 可读）。
      head = SigV4Request.signed_conn(:head, "/d4e/mp.bin") |> call()
      assert head.status == 200
      assert get_resp_header(head, "x-amz-meta-author") == ["alice"]
      assert get_resp_header(head, "content-type") == ["image/png"]

      get = SigV4Request.signed_conn(:get, "/d4e/mp.bin") |> call()
      assert get.status == 200
      assert get_resp_header(get, "x-amz-meta-author") == ["alice"]
    end

    test "CreateMultipartUpload >2 KB x-amz-meta-* → 400 MetadataTooLarge（create-time 闸）" do
      SigV4Request.signed_conn(:put, "/d4f") |> call()

      big_value = String.duplicate("x", 2049)

      init =
        SigV4Request.signed_conn(:post, "/d4f/mp.bin",
          query: %{"uploads" => ""},
          headers: [{"x-amz-meta-big", big_value}]
        )
        |> call()

      assert init.status == 400
      assert init.resp_body =~ "MetadataTooLarge"
    end
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  # 从 InitiateMultipartUploadResult 抠 UploadId（简单字符串切，无需 XML 解析依赖）。
  defp upload_id(xml) do
    [_, rest] = String.split(xml, "<UploadId>")
    [id, _] = String.split(rest, "</UploadId>")
    id
  end
end
