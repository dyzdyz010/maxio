defmodule Maxio.RouteBB5_3ResidualsTest do
  @moduledoc """
  ROUTE B B5-3 —— P5 fidelity/review 残留收口取证（计划 2026-06-10-routeB-b5-3-p5-fidelity-residuals）。

    * R1（契约面）：`Objects.reconcile_from_sidecar/3` 的 updated_at 忠于 entry modtime；
      modtime 缺失 → 既有行保留 updated_at + divergent 日志（盘上真实写路径的 R1 取证在
      `test/maxio/storage/scanner_test.exs`）。
    * R2（端点级 e2e）：Suspended + `:write=:sidecar` 的 DELETE 不再有破坏窗口——marker quorum
      失败 → 503 SlowDownWrite 且旧 null 对象完好（GET 仍 200）；成功 → marker 生效 + 孤儿
      part.0 被 GC。distributed 后端 + InProcess transport + persistent_term 注入 topology
      （与 get_head_sidecar_read_e2e_test 同范式）。
    * R3/R4（端点级，MinIO-fidelity 修订）：`.`/`..` 点段 key → 400 `XMinioInvalidObjectName`
      （对齐 MinIO ErrInvalidObjectName），绝不 500。布局保留名段
      （meta.json/part.0/.versions/.uploads/.tmp）是 MinIO/AWS 均接受的**普通合法 key**——
      原 B5-3 R3 的 API 层 400 拒绝是保真偏离，已撤销：现 PUT/GET/HEAD/DELETE/Copy/
      CreateMultipartUpload 全部成功 round-trip（盘上碰撞由 `Paths.encode_key` 段编码结构化
      消除）；不存在的此类 key GET/HEAD → 404 NoSuchKey（不再 400）。空段 key（"a//b"、"dir/"）
      维持合法（铁律 5，integration_test 锁死）且不再与折叠 key 互相覆写字节。守卫前遗留
      在途会话（点段 key）的 UploadPart/Complete 经 :invalid_key backstop 同映射 400（绝不 500）。
    * R5（端点级 e2e）：Enabled + `:write=:sidecar` 的签名 DELETE——成功 204 +
      x-amz-delete-marker:true + `:read=:sidecar` GET 404；down 端点 quorum 失败 → 503
      `<Code>SlowDownWrite</Code>`。
    * R6：`Distributed.put_delete_marker` 不再有 `version_id \\\\ "null"` 默认参（2-arity 不存在）。

  `async: false`：全局 backend/transport/authoritative_source/topology 切换 + InProcess down 表。
  """
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Maxio.{Buckets, Objects, Sidecar}
  alias Maxio.Cluster.Paths
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @owner "arn:aws:iam:::root"

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp set_versioning(bucket, status) do
    body = ~s(<VersioningConfiguration><Status>#{status}</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  # ── R1：reconcile_from_sidecar 的 modtime 缺失分支（契约面；正常路径取证在 scanner_test）──

  describe "R1 — reconcile updated_at 的 modtime 缺失兜底（契约面）" do
    test "modtime 缺失 + 既有行 → 保留行内 updated_at（不漂移到 reconcile 时刻）+ divergent 日志" do
      {:ok, _b} = Buckets.create("rb53r1a", @owner)

      {:ok, _} =
        Objects.put_version_with_id("rb53r1a", "k", "null", %{size: 3, etag: "\"e1\""})

      {:ok, pre} = Objects.get_version("rb53r1a", "k", "null")

      Process.sleep(20)

      # 异常 sidecar entry（无 modtime）——直接喂契约函数（非伪造盘上 sidecar）。
      entry = %{
        "version_id" => "null",
        "type" => "object",
        "is_latest" => true,
        "etag" => "\"e2\"",
        "size" => 7,
        "generation" => 1
      }

      log =
        capture_log(fn ->
          assert :ok = Objects.reconcile_from_sidecar("rb53r1a", "k", entry)
        end)

      assert log =~ "missing modtime"

      {:ok, row} = Objects.get_version("rb53r1a", "k", "null")
      # 其余读可见字段照常收敛到盘上权威……
      assert row.etag == "\"e2\""
      assert row.size == 7

      # ……但 updated_at（Last-Modified 来源）保留既有值，绝不被 reconcile 时刻覆盖。
      assert DateTime.compare(row.updated_at, pre.updated_at) == :eq
    end

    test "modtime 在场 → updated_at == DateTime.from_unix(modtime, :nanosecond)（新插行同样忠实）" do
      {:ok, _b} = Buckets.create("rb53r1b", @owner)

      modtime_ns = 1_700_000_000_123_456_789
      {:ok, expected} = DateTime.from_unix(modtime_ns, :nanosecond)

      entry = %{
        "version_id" => "null",
        "type" => "object",
        "is_latest" => true,
        "etag" => "\"em\"",
        "size" => 5,
        "modtime" => modtime_ns,
        "generation" => 0
      }

      assert :ok = Objects.reconcile_from_sidecar("rb53r1b", "k", entry)

      {:ok, row} = Objects.get_version("rb53r1b", "k", "null")
      assert DateTime.compare(row.updated_at, expected) == :eq
    end
  end

  # ── R3/R4（MinIO-fidelity 修订）：点段 key → 400；保留布局名段 key = 普通合法 key
  #    （FS 默认后端 + :pg 默认权威；盘上碰撞由 Paths.encode_key 段编码消除）──

  describe "R3/R4 — 点段 key → 400；保留布局名段 key 合法 round-trip（对齐 MinIO/AWS）" do
    setup do
      data_dir =
        Path.join(System.tmp_dir!(), "maxio_b53_key_#{System.unique_integer([:positive])}")

      File.rm_rf(data_dir)
      File.mkdir_p!(data_dir)
      prev_s3 = Application.get_env(:maxio, :s3)
      Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))

      on_exit(fn ->
        Application.put_env(:maxio, :s3, prev_s3)
        File.rm_rf(data_dir)
      end)

      SigV4Request.signed_conn(:put, "/rb53key") |> call()
      :ok
    end

    test "保留段 key（a/meta.json/b）PUT/GET/DELETE 完整 round-trip（MinIO/AWS 均接受此类 key）" do
      put =
        SigV4Request.signed_conn(:put, "/rb53key/a/meta.json/b", body: "reserved ok") |> call()

      assert put.status == 200

      get = SigV4Request.signed_conn(:get, "/rb53key/a/meta.json/b") |> call()
      assert get.status == 200
      assert get.resp_body == "reserved ok"

      del = SigV4Request.signed_conn(:delete, "/rb53key/a/meta.json/b") |> call()
      assert del.status == 204

      miss = SigV4Request.signed_conn(:get, "/rb53key/a/meta.json/b") |> call()
      assert miss.status == 404
      assert miss.resp_body =~ "<Code>NoSuchKey</Code>"
    end

    test "不存在的保留段 key GET/HEAD → 404（曾 400；NoSuchKey 对齐 MinIO/AWS）" do
      get = SigV4Request.signed_conn(:get, "/rb53key/ghost/meta.json") |> call()
      assert get.status == 404
      assert get.resp_body =~ "<Code>NoSuchKey</Code>"

      head = SigV4Request.signed_conn(:head, "/rb53key/part.0") |> call()
      assert head.status == 404
      assert head.resp_body == ""
    end

    test "全部保留名段逐一合法 round-trip（盘上经段编码无碰撞）" do
      for seg <- ["meta.json", "part.0", ".versions", ".uploads", ".tmp"] do
        put = SigV4Request.signed_conn(:put, "/rb53key/p/#{seg}/x", body: "v " <> seg) |> call()
        assert put.status == 200, "segment #{seg} must be accepted"

        get = SigV4Request.signed_conn(:get, "/rb53key/p/#{seg}/x") |> call()
        assert get.status == 200
        assert get.resp_body == "v " <> seg
      end
    end

    test "点段 key（a/./b、a/../b）→ 400 不再 500（R4：含版本化桶 delete-marker 路径）" do
      for key <- ["a/./b", "a/../b"] do
        put = SigV4Request.signed_conn(:put, "/rb53key/#{key}", body: "x") |> call()
        assert put.status == 400
        assert put.resp_body =~ "<Code>XMinioInvalidObjectName</Code>"
      end

      # R4 原 500 现场：版本化桶 DELETE（无 versionId）走 delete-marker 提交路径。
      assert set_versioning("rb53key", "Enabled").status == 200
      del = SigV4Request.signed_conn(:delete, "/rb53key/a/../b") |> call()
      assert del.status == 400
      assert del.resp_body =~ "<Code>XMinioInvalidObjectName</Code>"
      refute del.resp_body =~ "InternalError"
    end

    test "Copy 保留段源/目标合法；点段源/目标 400" do
      put = SigV4Request.signed_conn(:put, "/rb53key/a/meta.json/b", body: "copy me") |> call()
      assert put.status == 200

      # 保留段源 → 普通目标：成功。
      dest1 =
        SigV4Request.signed_conn(:put, "/rb53key/dest.txt",
          headers: [{"x-amz-copy-source", "/rb53key/a/meta.json/b"}]
        )
        |> call()

      assert dest1.status == 200
      get1 = SigV4Request.signed_conn(:get, "/rb53key/dest.txt") |> call()
      assert get1.resp_body == "copy me"

      # 普通源 → 保留段目标：成功 round-trip。
      dest2 =
        SigV4Request.signed_conn(:put, "/rb53key/dest/.tmp/x",
          headers: [{"x-amz-copy-source", "/rb53key/dest.txt"}]
        )
        |> call()

      assert dest2.status == 200
      get2 = SigV4Request.signed_conn(:get, "/rb53key/dest/.tmp/x") |> call()
      assert get2.resp_body == "copy me"

      # 点段（真正非法）源与目标仍被拦 → 400。
      bad_dst =
        SigV4Request.signed_conn(:put, "/rb53key/a/../b",
          headers: [{"x-amz-copy-source", "/rb53key/dest.txt"}]
        )
        |> call()

      assert bad_dst.status == 400
      assert bad_dst.resp_body =~ "<Code>XMinioInvalidObjectName</Code>"

      bad_src =
        SigV4Request.signed_conn(:put, "/rb53key/dest2.txt",
          headers: [{"x-amz-copy-source", "/rb53key/a/../b"}]
        )
        |> call()

      assert bad_src.status == 400
      assert bad_src.resp_body =~ "<Code>XMinioInvalidObjectName</Code>"
    end

    test "CreateMultipartUpload 点段 key → 400 零孤儿会话；保留段 key 全程 multipart round-trip（可建即可达）" do
      init_bad =
        SigV4Request.signed_conn(:post, "/rb53key/a/../b", query: %{"uploads" => ""}) |> call()

      assert init_bad.status == 400
      assert init_bad.resp_body =~ "<Code>XMinioInvalidObjectName</Code>"
      refute init_bad.resp_body =~ "InternalError"

      # 失败 pre-initiate：无孤儿会话（端点级 ListMultipartUploads + context 双取证）。
      list = SigV4Request.signed_conn(:get, "/rb53key", query: %{"uploads" => ""}) |> call()
      assert list.status == 200
      assert Maxio.Multipart.list_uploads("rb53key", %{}).uploads == []

      # 保留段 key：initiate → upload part → complete → GET 全程成功（对齐 MinIO/AWS）。
      init =
        SigV4Request.signed_conn(:post, "/rb53key/a/meta.json/b", query: %{"uploads" => ""})
        |> call()

      assert init.status == 200
      [_, upload_id] = Regex.run(~r|<UploadId>([^<]+)</UploadId>|, init.resp_body)

      up =
        SigV4Request.signed_conn(:put, "/rb53key/a/meta.json/b",
          query: %{"partNumber" => "1", "uploadId" => upload_id},
          body: "mpu reserved bytes"
        )
        |> call()

      assert up.status == 200
      [etag] = get_resp_header(up, "etag")

      xml =
        "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber>" <>
          "<ETag>#{etag}</ETag></Part></CompleteMultipartUpload>"

      comp =
        SigV4Request.signed_conn(:post, "/rb53key/a/meta.json/b",
          query: %{"uploadId" => upload_id},
          body: xml
        )
        |> call()

      assert comp.status == 200

      get = SigV4Request.signed_conn(:get, "/rb53key/a/meta.json/b") |> call()
      assert get.status == 200
      assert get.resp_body == "mpu reserved bytes"
    end

    test "守卫前遗留在途会话（点段 key）→ UploadPart/Complete 400 绝不 500（backstop）" do
      # 直接经 context 造会话，模拟入口守卫部署前已存在的在途上传（绕过 handler 门）。
      {:ok, upload} = Maxio.Multipart.initiate("rb53key", "a/../b", %{owner: @owner})

      up =
        SigV4Request.signed_conn(:put, "/rb53key/a/../b",
          query: %{"partNumber" => "1", "uploadId" => upload.upload_id},
          body: "part bytes"
        )
        |> call()

      assert up.status == 400
      assert up.resp_body =~ "<Code>XMinioInvalidObjectName</Code>"
      refute up.resp_body =~ "InternalError"

      # Complete 分支：PG part 行直接造（点段 key 的字节路径必然被后端拒绝，元数据行足以驱动
      # Multipart.complete 走到 Storage.assemble 的 :invalid_key 分支）。
      etag = :crypto.hash(:md5, "p1") |> Base.encode16(case: :lower)
      {:ok, _} = Maxio.Multipart.put_part(upload, 1, %{etag: etag, size: 2})

      xml =
        "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber>" <>
          "<ETag>\"#{etag}\"</ETag></Part></CompleteMultipartUpload>"

      comp =
        SigV4Request.signed_conn(:post, "/rb53key/a/../b",
          query: %{"uploadId" => upload.upload_id},
          body: xml
        )
        |> call()

      assert comp.status == 400
      assert comp.resp_body =~ "<Code>XMinioInvalidObjectName</Code>"
      refute comp.resp_body =~ "InternalError"
    end

    test "正常含点 key（a.b/c.d）与近似名（part.1、metadata.json）不受影响（仅精确保留名）" do
      for key <- ["a.b/c.d", "p/part.1/x", "p/metadata.json", "p/meta.json.bak"] do
        put = SigV4Request.signed_conn(:put, "/rb53key/#{key}", body: "ok " <> key) |> call()
        assert put.status == 200, "key #{key} must be accepted"

        get = SigV4Request.signed_conn(:get, "/rb53key/#{key}") |> call()
        assert get.status == 200
        assert get.resp_body == "ok " <> key
      end
    end
  end

  # ── Paths 单元面：validate_key（API 层，仅拒 MinIO/AWS 都拒的形态）与 object_rel
  #    （盘路径层，段编码无碰撞表达保留名/空段/尾斜杠；完整 codec 取证在 paths_test.exs）──

  describe "Paths.validate_key / object_rel（单一来源，MinIO-fidelity 修订）" do
    test "validate_key：点段/空 key 拒绝；保留段与空段（均为合法 S3 key）放行" do
      assert {:error, :invalid_key} = Paths.validate_key("a/./b")
      assert {:error, :invalid_key} = Paths.validate_key("a/../b")
      assert {:error, :invalid_key} = Paths.validate_key("")

      # 保留布局名段是 MinIO/AWS 均接受的普通 key（盘上碰撞由段编码消除，不在 API 层拒）。
      assert :ok = Paths.validate_key("a/meta.json/b")
      assert :ok = Paths.validate_key("part.0")
      assert :ok = Paths.validate_key(".versions/x")

      assert :ok = Paths.validate_key("a.b/c.d")
      assert :ok = Paths.validate_key("p/part.1/x")

      # 空段 key 是合法 S3 key（folder marker / 连续斜杠），API 层放行（编码无碰撞落盘）。
      assert :ok = Paths.validate_key("dir/")
      assert :ok = Paths.validate_key("a//b")
    end

    test "object_rel：点段拒绝；保留段/空段/尾斜杠经段编码无碰撞落盘（绝不静默折叠）" do
      assert {:error, :invalid_key} = Paths.object_rel("b", "a/../b", "null")
      assert {:error, :invalid_key} = Paths.object_rel("b", "a/./b", "null")

      assert {:ok, "b/a/meta.json__MXESC__/b"} = Paths.object_rel("b", "a/meta.json/b", "null")
      assert {:ok, "b/a/.tmp__MXESC__/x"} = Paths.object_rel("b", "a/.tmp/x", "null")
      assert {:ok, "b/a/__MXEMPTY__/b"} = Paths.object_rel("b", "a//b", "null")
      assert {:ok, "b/dir__MXDIR__"} = Paths.object_rel("b", "dir/", "null")

      assert {:ok, "b/p/part.1/x"} = Paths.object_rel("b", "p/part.1/x", "null")
      assert {:ok, "b/a.b/c.d"} = Paths.object_rel("b", "a.b/c.d", "null")
    end
  end

  # ── R6：Distributed.put_delete_marker 无 version_id 默认参 ──

  describe "R6 — put_delete_marker 默认参对齐" do
    test "Distributed.put_delete_marker 最小 arity = 3（version_id 必须显式传）" do
      # function_exported?/3 不触发模块加载（懒加载 .beam 下未加载模块一律 false）——
      # 先显式 ensure_loaded，否则本测试随用例执行顺序漂移（审计中实测 flaky）。
      for mod <- [Maxio.Storage.Distributed, Maxio.Storage.ErasureCoded, Maxio.Storage] do
        Code.ensure_loaded!(mod)
      end

      refute function_exported?(Maxio.Storage.Distributed, :put_delete_marker, 2)
      assert function_exported?(Maxio.Storage.Distributed, :put_delete_marker, 3)
      # ErasureCoded / Storage 门面本就如此（对齐基准）。
      refute function_exported?(Maxio.Storage.ErasureCoded, :put_delete_marker, 2)
      refute function_exported?(Maxio.Storage, :put_delete_marker, 2)
    end
  end

  # ── R2 + R5：端点级 :sidecar 写权威 DELETE e2e（distributed + InProcess + topology）──

  describe "R2/R5 — 端点级 :sidecar DELETE（distributed + InProcess + 注入拓扑）" do
    setup do
      InProcess.setup!()

      data_dir =
        Path.join(System.tmp_dir!(), "maxio_b53_dist_#{System.unique_integer([:positive])}")

      File.rm_rf(data_dir)
      File.mkdir_p!(data_dir)

      prev_s3 = Application.get_env(:maxio, :s3)
      Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))

      prev_auth = Application.get_env(:maxio, :authoritative_source)

      Application.put_env(:maxio, :authoritative_source,
        read: :sidecar,
        list: :pg,
        write: :sidecar
      )

      prev_tx = Application.get_env(:maxio, :shard_transport)
      Application.put_env(:maxio, :shard_transport, InProcess)

      prev_backend = Application.get_env(:maxio, :storage_backend)
      Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)

      # handler 不透传 topology → read_quorum 取全局 :erasure（drives 仅满足校验，不做 IO）。
      prev_ec = Application.get_env(:maxio, :erasure)

      Application.put_env(:maxio, :erasure,
        drives: ["d0", "d1", "d2"],
        data_shards: 2,
        parity_shards: 1,
        block_size: 1024
      )

      eps =
        for i <- 0..2,
            do:
              {:"b53n#{i}",
               Path.join(System.tmp_dir!(), "b53_d#{i}_#{System.unique_integer([:positive])}")}

      # K=2 M=1 N=3 → read_quorum=2、write_quorum=3：单端点 down 即写 quorum 失败、读仍可达。
      topo = %{
        data_shards: 2,
        parity_shards: 1,
        block_size: 1024,
        sets: %{0 => %{id: 0, endpoints: eps}},
        set_ids: [0]
      }

      :persistent_term.put({Maxio.Cluster.Topology, :topology}, topo)

      on_exit(fn ->
        :persistent_term.erase({Maxio.Cluster.Topology, :topology})
        Application.put_env(:maxio, :s3, prev_s3)

        if prev_auth,
          do: Application.put_env(:maxio, :authoritative_source, prev_auth),
          else: Application.delete_env(:maxio, :authoritative_source)

        if prev_tx,
          do: Application.put_env(:maxio, :shard_transport, prev_tx),
          else: Application.delete_env(:maxio, :shard_transport)

        if prev_backend,
          do: Application.put_env(:maxio, :storage_backend, prev_backend),
          else: Application.delete_env(:maxio, :storage_backend)

        if prev_ec,
          do: Application.put_env(:maxio, :erasure, prev_ec),
          else: Application.delete_env(:maxio, :erasure)

        Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end)
        File.rm_rf(data_dir)
      end)

      {:ok, eps: eps}
    end

    # 读端点盘上真实 sidecar（仅取证，绝不手搓写）。
    defp disk_sidecar(drive, bucket, key, vid) do
      {:ok, rel} = Paths.object_rel(bucket, key, vid)

      case File.read(Path.join([drive, rel, "meta.json"])) do
        {:ok, bin} -> Sidecar.decode!(bin)
        {:error, _} -> nil
      end
    end

    defp part0_path(drive, bucket, key, vid) do
      {:ok, rel} = Paths.object_rel(bucket, key, vid)
      Path.join([drive, rel, "part.0"])
    end

    test "R2 — Suspended：marker quorum 失败 → 503 SlowDownWrite 且旧 null 对象完好；成功 → marker 生效 + 孤儿 part.0 被收",
         %{eps: eps} do
      bucket = "rb53susp"
      body = "suspended null body"
      assert SigV4Request.signed_conn(:put, "/" <> bucket) |> call() |> Map.fetch!(:status) == 200
      assert set_versioning(bucket, "Suspended").status == 200

      put = SigV4Request.signed_conn(:put, "/#{bucket}/doc.txt", body: body) |> call()
      assert put.status == 200

      # 旧 null 对象 sidecar + part.0 在全端点落盘。
      for {_n, d} <- eps do
        assert disk_sidecar(d, bucket, "doc.txt", "null")["versions"]
               |> hd()
               |> Map.fetch!("type") == "object"

        assert File.regular?(part0_path(d, bucket, "doc.txt", "null"))
      end

      # 注入 quorum 失败：单端点 down（write_quorum=3）→ 503 SlowDownWrite（绝不 204）。
      {node0, _drive0} = hd(eps)
      InProcess.set_down(node0)

      del = SigV4Request.signed_conn(:delete, "/#{bucket}/doc.txt") |> call()
      assert del.status == 503
      assert del.resp_body =~ "<Code>SlowDownWrite</Code>"

      # 破坏窗口已消除：旧 null 对象在**所有**端点完好（旧序会先毁 null 版本 → 裸 404 窗口）。
      for {_n, d} <- eps do
        meta = disk_sidecar(d, bucket, "doc.txt", "null")
        assert hd(meta["versions"])["type"] == "object"
        assert File.regular?(part0_path(d, bucket, "doc.txt", "null"))
      end

      # GET 仍 200 原文（2 个存活端点 ≥ read_quorum=2，:read=:sidecar）。
      get = SigV4Request.signed_conn(:get, "/#{bucket}/doc.txt") |> call()
      assert get.status == 200
      assert get.resp_body == body

      # 端点恢复 → 重试 DELETE 收敛：204 + marker 生效。
      InProcess.set_up(node0)
      del2 = SigV4Request.signed_conn(:delete, "/#{bucket}/doc.txt") |> call()
      assert del2.status == 204
      assert get_resp_header(del2, "x-amz-delete-marker") == ["true"]

      # marker 替换 null sidecar + 孤儿 part.0 被 GC（全端点）。
      for {_n, d} <- eps do
        meta = disk_sidecar(d, bucket, "doc.txt", "null")
        assert [%{"type" => "delete_marker", "version_id" => "null"}] = meta["versions"]
        refute File.exists?(part0_path(d, bucket, "doc.txt", "null"))
      end

      get2 = SigV4Request.signed_conn(:get, "/#{bucket}/doc.txt") |> call()
      assert get2.status == 404
      assert get_resp_header(get2, "x-amz-delete-marker") == ["true"]
    end

    test "R5 — Enabled：签名 DELETE 成功 → 204 + x-amz-delete-marker + :read=:sidecar GET 404", %{
      eps: _eps
    } do
      bucket = "rb53en"
      assert SigV4Request.signed_conn(:put, "/" <> bucket) |> call() |> Map.fetch!(:status) == 200
      assert set_versioning(bucket, "Enabled").status == 200

      put = SigV4Request.signed_conn(:put, "/#{bucket}/obj.txt", body: "enabled body") |> call()
      assert put.status == 200
      [obj_vid] = get_resp_header(put, "x-amz-version-id")

      # ULID 48-bit ms 前缀：保证 marker 生成在更晚的毫秒（同毫秒内随机位可能倒序）。
      Process.sleep(5)
      del = SigV4Request.signed_conn(:delete, "/#{bucket}/obj.txt") |> call()
      assert del.status == 204
      assert get_resp_header(del, "x-amz-delete-marker") == ["true"]
      [marker_vid] = get_resp_header(del, "x-amz-version-id")
      assert marker_vid != obj_vid

      get = SigV4Request.signed_conn(:get, "/#{bucket}/obj.txt") |> call()
      assert get.status == 404
      assert get_resp_header(get, "x-amz-delete-marker") == ["true"]
    end

    test "R5 — Enabled：down 端点注入 quorum 失败 → 503 <Code>SlowDownWrite</Code>，对象仍可读", %{
      eps: eps
    } do
      bucket = "rb53enq"
      body = "quorum gated marker"
      assert SigV4Request.signed_conn(:put, "/" <> bucket) |> call() |> Map.fetch!(:status) == 200
      assert set_versioning(bucket, "Enabled").status == 200

      put = SigV4Request.signed_conn(:put, "/#{bucket}/obj.txt", body: body) |> call()
      assert put.status == 200

      {node0, _} = hd(eps)
      InProcess.set_down(node0)

      del = SigV4Request.signed_conn(:delete, "/#{bucket}/obj.txt") |> call()
      assert del.status == 503
      assert del.resp_body =~ "<Code>SlowDownWrite</Code>"

      # 删除未提交：对象仍可读（2 存活端点 ≥ read_quorum=2）。
      get = SigV4Request.signed_conn(:get, "/#{bucket}/obj.txt") |> call()
      assert get.status == 200
      assert get.resp_body == body
    end
  end
end
