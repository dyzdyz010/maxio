defmodule Maxio.RouteBB62aResidualsTest do
  @moduledoc """
  ROUTE B B6-2a —— B6-1 fidelity 审计残留 4 medium 的修复取证（计划 2026-06-11-routeB-phase6）：

    * R1：DeleteObjects per-key **畸形 versionId** → 该 key `<Error>` 携 `<Key>+<VersionId>`
      回显 + `<Code>NoSuchVersion</Code>`（对齐 MinIO DeleteMultipleObjectsHandler：uuid.Parse
      失败 → ErrNoSuchVersion 落 per-key DeleteError；AWS API_DeleteObjects Response Syntax 的
      Error 元素集 = Code/Key/Message/VersionId）。单删 DELETE ?versionId 的 400 InvalidArgument
      （ErrInvalidVersionID）语义不变（两 Code 分流）。
    * R2：**空 `?versionId=`**（query 给了参数但值为空串）= absent（latest/普通语义，MinIO
      `r.Form.Get` 空串即 absent）——绝非 400。GET/HEAD/DELETE/tagging 统一经
      `VersionId.normalize_param/1` 归一化。
    * R3：tagging 三操作（Get/Put/DeleteObjectTagging 的 ?versionId）接入 B5-4 入口守卫：
      畸形 versionId → 400 InvalidArgument "Invalid version id specified"（此前漏接走老路径）；
      合法 "null"/空串不受影响。
    * R4/R5：多段完成对象的 sidecar versions entry etag = **S3 多段 ETag**（hex(MD5(concat
      part MD5s))-N，经 Multipart.complete 的 object_meta 透传覆盖）；耐久 core 顶层 etag 保持
      整体字节 MD5（完整性校验语义）。R4 = FS（默认后端）盘上取证 + PG 路径 GET ETag 头回归锁；
      R5 = Distributed + InProcess + 全局 topology 的 `:read=:sidecar` HTTP GET ETag 头 == -N
      形状（既有 e2e 范式）。三后端 version_opts 同源（EC 与 Distributed 逐字一致）。

  `async: false`：setup 切换全局 :s3 data_dir（R5 另切全局 backend/topology/authoritative_source）。
  """
  use Maxio.DataCase, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias Maxio.Cluster.{Paths, Transport.InProcess}
  alias Maxio.S3.Endpoint
  alias Maxio.Sidecar
  alias Maxio.Test.SigV4Request

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp set_versioning(bucket, status) do
    body = ~s(<VersioningConfiguration><Status>#{status}</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  # 从 InitiateMultipartUploadResult 抠 UploadId（与 b4_6 测试同款字符串切）。
  defp upload_id(xml) do
    [_, rest] = String.split(xml, "<UploadId>")
    [id, _] = String.split(rest, "</UploadId>")
    id
  end

  # 从 CompleteMultipartUploadResult 抠 ETag（渲染带引号），返回去引号裸值。
  defp complete_etag(xml) do
    [_, rest] = String.split(xml, "<ETag>")
    [etag, _] = String.split(rest, "</ETag>")
    String.trim(etag, "\"")
  end

  # 经 HTTP 端点完成一次两-part 多段上传，返回 complete 响应的裸 ETag（"...-2"）。
  defp http_mpu!(bucket, key, part1, part2) do
    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}", query: %{"uploads" => ""}) |> call()

    assert init.status == 200
    uid = upload_id(init.resp_body)

    etags =
      for {pn, body} <- [{1, part1}, {2, part2}] do
        up =
          SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
            query: %{"partNumber" => Integer.to_string(pn), "uploadId" => uid},
            body: body
          )
          |> call()

        assert up.status == 200
        [etag] = get_resp_header(up, "etag")
        {pn, etag}
      end

    complete_xml =
      "<CompleteMultipartUpload>" <>
        Enum.map_join(etags, fn {pn, etag} ->
          "<Part><PartNumber>#{pn}</PartNumber><ETag>#{etag}</ETag></Part>"
        end) <>
        "</CompleteMultipartUpload>"

    complete =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploadId" => uid},
        body: complete_xml
      )
      |> call()

    assert complete.status == 200
    complete_etag(complete.resp_body)
  end

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "maxio_b62a_#{System.unique_integer([:positive])}")

    File.rm_rf(data_dir)
    File.mkdir_p!(data_dir)
    prev_s3 = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))
    Application.put_env(:maxio, :multipart_min_part_size, 1)

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      Application.delete_env(:maxio, :multipart_min_part_size)
      File.rm_rf(data_dir)
    end)

    {:ok, data_dir: data_dir}
  end

  # ── R1：DeleteObjects per-key 畸形 versionId → NoSuchVersion + VersionId 回显 ──

  describe "R1 — DeleteObjects per-key 畸形 versionId" do
    setup do
      assert SigV4Request.signed_conn(:put, "/rb62r1") |> call() |> Map.fetch!(:status) == 200

      put = SigV4Request.signed_conn(:put, "/rb62r1/doc.txt", body: "r1 body") |> call()
      assert put.status == 200
      :ok
    end

    test "畸形 per-key versionId → <Error> 携 <Key>+<VersionId>+<Code>NoSuchVersion</Code>（MinIO 同源），其余 key 正常删" do
      put = SigV4Request.signed_conn(:put, "/rb62r1/ok.txt", body: "deletable") |> call()
      assert put.status == 200

      xml =
        "<Delete>" <>
          "<Object><Key>doc.txt</Key><VersionId>not-a-valid-ulid</VersionId></Object>" <>
          "<Object><Key>ok.txt</Key></Object>" <>
          "</Delete>"

      resp =
        SigV4Request.signed_conn(:post, "/rb62r1", query: %{"delete" => ""}, body: xml)
        |> call()

      assert resp.status == 200

      # AWS Error 元素集（Code/Key/Message/VersionId）；渲染序 Key→VersionId→Code→Message
      # （AWS 响应示例 Key 先行；SDK 按元素名解析，元素集是契约）。
      assert resp.resp_body =~
               "<Key>doc.txt</Key><VersionId>not-a-valid-ulid</VersionId>" <>
                 "<Code>NoSuchVersion</Code>"

      assert resp.resp_body =~ "The specified version does not exist."
      refute resp.resp_body =~ "InvalidArgument"
      refute resp.resp_body =~ "InternalError"

      # per-key 隔离：合法 key 正常删除、畸形 versionId 的 key 完好。
      assert resp.resp_body =~ "<Deleted><Key>ok.txt</Key></Deleted>"

      assert SigV4Request.signed_conn(:get, "/rb62r1/ok.txt") |> call() |> Map.fetch!(:status) ==
               404

      assert SigV4Request.signed_conn(:get, "/rb62r1/doc.txt") |> call() |> Map.fetch!(:status) ==
               200
    end

    test "单删 DELETE ?versionId 畸形仍 400 InvalidArgument（与 per-key NoSuchVersion 分流）" do
      del =
        SigV4Request.signed_conn(:delete, "/rb62r1/doc.txt",
          query: %{"versionId" => "not-a-valid-ulid"}
        )
        |> call()

      assert del.status == 400
      assert del.resp_body =~ "<Code>InvalidArgument</Code>"
      assert del.resp_body =~ "Invalid version id specified"
      refute del.resp_body =~ "NoSuchVersion"
    end
  end

  # ── R2：空 ?versionId= = absent（latest/普通语义），绝非 400 ──

  describe "R2 — 空 ?versionId= 视为 absent" do
    setup do
      assert SigV4Request.signed_conn(:put, "/rb62r2") |> call() |> Map.fetch!(:status) == 200

      put = SigV4Request.signed_conn(:put, "/rb62r2/doc.txt", body: "empty vid body") |> call()
      assert put.status == 200
      :ok
    end

    test "GET/HEAD ?versionId=（空串）→ 200 latest（曾 400）" do
      get =
        SigV4Request.signed_conn(:get, "/rb62r2/doc.txt", query: %{"versionId" => ""}) |> call()

      assert get.status == 200
      assert get.resp_body == "empty vid body"

      head =
        SigV4Request.signed_conn(:head, "/rb62r2/doc.txt", query: %{"versionId" => ""}) |> call()

      assert head.status == 200
    end

    test "DELETE ?versionId=（空串）→ 普通删除语义（Enabled 桶插 marker，绝非 400/永久删）" do
      bucket = "rb62r2en"
      assert SigV4Request.signed_conn(:put, "/" <> bucket) |> call() |> Map.fetch!(:status) == 200
      assert set_versioning(bucket, "Enabled").status == 200

      put = SigV4Request.signed_conn(:put, "/#{bucket}/v.txt", body: "versioned") |> call()
      assert put.status == 200
      [vid] = get_resp_header(put, "x-amz-version-id")

      del =
        SigV4Request.signed_conn(:delete, "/#{bucket}/v.txt", query: %{"versionId" => ""})
        |> call()

      assert del.status == 204
      assert get_resp_header(del, "x-amz-delete-marker") == ["true"]

      # marker 拿到新 ULID（≠ 被删对象版本）——空 versionId 走 marker 分支而非永久删。
      [marker_vid] = get_resp_header(del, "x-amz-version-id")
      assert marker_vid != vid

      # latest 被 marker 遮蔽 404；原版本字节完好可读（绝未被永久删除）。
      assert SigV4Request.signed_conn(:get, "/#{bucket}/v.txt") |> call() |> Map.fetch!(:status) ==
               404

      versioned =
        SigV4Request.signed_conn(:get, "/#{bucket}/v.txt", query: %{"versionId" => vid})
        |> call()

      assert versioned.status == 200
      assert versioned.resp_body == "versioned"
    end

    test "GetObjectTagging ?versionId=（空串）→ 200 current（tagging 同源归一化）" do
      get =
        SigV4Request.signed_conn(:get, "/rb62r2/doc.txt",
          query: %{"tagging" => "", "versionId" => ""}
        )
        |> call()

      assert get.status == 200
      assert get.resp_body =~ "<TagSet"
    end
  end

  # ── R3：tagging 操作接入 ?versionId 入口守卫 ──

  describe "R3 — tagging 的 ?versionId 守卫（Get/Put/DeleteObjectTagging）" do
    @bad_version_ids ["../x", "..", "not-a-valid-ulid", String.duplicate("I", 26)]
    @tag_xml "<Tagging><TagSet><Tag><Key>k1</Key><Value>v1</Value></Tag></TagSet></Tagging>"

    setup do
      assert SigV4Request.signed_conn(:put, "/rb62r3") |> call() |> Map.fetch!(:status) == 200

      put = SigV4Request.signed_conn(:put, "/rb62r3/doc.txt", body: "tagging guard") |> call()
      assert put.status == 200
      :ok
    end

    test "Get/Put/DeleteObjectTagging ?versionId 非法 → 400 InvalidArgument（先于任何查找）" do
      for bad <- @bad_version_ids do
        get =
          SigV4Request.signed_conn(:get, "/rb62r3/doc.txt",
            query: %{"tagging" => "", "versionId" => bad}
          )
          |> call()

        assert get.status == 400, "GET tagging versionId #{inspect(bad)} must be rejected"
        assert get.resp_body =~ "<Code>InvalidArgument</Code>"
        assert get.resp_body =~ "Invalid version id specified"
        refute get.resp_body =~ "InternalError"

        put =
          SigV4Request.signed_conn(:put, "/rb62r3/doc.txt",
            query: %{"tagging" => "", "versionId" => bad},
            body: @tag_xml
          )
          |> call()

        assert put.status == 400, "PUT tagging versionId #{inspect(bad)} must be rejected"
        assert put.resp_body =~ "<Code>InvalidArgument</Code>"

        del =
          SigV4Request.signed_conn(:delete, "/rb62r3/doc.txt",
            query: %{"tagging" => "", "versionId" => bad}
          )
          |> call()

        assert del.status == 400, "DELETE tagging versionId #{inspect(bad)} must be rejected"
        assert del.resp_body =~ "<Code>InvalidArgument</Code>"
      end
    end

    test "合法 \"null\"：Put → Get 回读 → Delete 全链不受守卫影响" do
      put =
        SigV4Request.signed_conn(:put, "/rb62r3/doc.txt",
          query: %{"tagging" => "", "versionId" => "null"},
          body: @tag_xml
        )
        |> call()

      assert put.status == 200

      get =
        SigV4Request.signed_conn(:get, "/rb62r3/doc.txt",
          query: %{"tagging" => "", "versionId" => "null"}
        )
        |> call()

      assert get.status == 200
      assert get.resp_body =~ "<Key>k1</Key>"
      assert get.resp_body =~ "<Value>v1</Value>"

      del =
        SigV4Request.signed_conn(:delete, "/rb62r3/doc.txt",
          query: %{"tagging" => "", "versionId" => "null"}
        )
        |> call()

      assert del.status == 204
    end
  end

  # ── R4：FS（默认后端）多段完成对象 sidecar etag = -N；core etag = 整体 MD5 ──

  describe "R4 — FS 多段 sidecar versions entry etag = S3 多段 ETag" do
    test "两-part MPU → 盘上 versions[0].etag == \"...-2\"，core etag == 整体字节 MD5；GET ETag 头（:pg）== -2",
         %{data_dir: data_dir} do
      bucket = "rb62r4"
      key = "mp.bin"
      assert SigV4Request.signed_conn(:put, "/" <> bucket) |> call() |> Map.fetch!(:status) == 200

      part1 = "fs multipart part one bytes"
      part2 = "fs multipart part two bytes!"
      mp_etag = http_mpu!(bucket, key, part1, part2)
      assert String.ends_with?(mp_etag, "-2")

      # 盘上 sidecar（真实写路径产物，绝不手搓）：entry etag = 多段 ETag；core etag = 整体 MD5。
      {:ok, rel} = Paths.object_rel(bucket, key, "null")
      meta = Path.join([data_dir, rel, "meta.json"]) |> File.read!() |> Sidecar.decode!()
      whole_md5 = :crypto.hash(:md5, part1 <> part2) |> Base.encode16(case: :lower)

      assert meta["format"] == "maxio/2"
      assert [entry] = meta["versions"]
      assert entry["etag"] == mp_etag
      assert meta["etag"] == whole_md5
      refute meta["etag"] == mp_etag

      # 多段 ETag 的 MD5 部分 = MD5(concat part MD5s)，与整体 MD5 不同（-N 形态可分辨）。
      assert mp_etag ==
               :crypto.hash(
                 :md5,
                 :crypto.hash(:md5, part1) <> :crypto.hash(:md5, part2)
               )
               |> Base.encode16(case: :lower)
               |> Kernel.<>("-2")

      # 默认 :pg 读路径回归锁：GET ETag 头 == 引号包裹的 -2 形态、字节完好。
      get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
      assert get.status == 200
      assert get_resp_header(get, "etag") == ["\"#{mp_etag}\""]
      assert get.resp_body == part1 <> part2
    end
  end

  # ── R5：Distributed + :read=:sidecar 下 HTTP GET 的 ETag 头 == -N（既有 e2e 范式）──

  describe "R5 — :read=:sidecar 多段对象 GET ETag 头 = -N（Distributed + InProcess + 全局 topology）" do
    setup do
      InProcess.setup!()

      prev_backend = Application.get_env(:maxio, :storage_backend)
      Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)
      prev_auth = Application.get_env(:maxio, :authoritative_source)
      Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :pg, write: :pg)
      prev_tx = Application.get_env(:maxio, :shard_transport)
      Application.put_env(:maxio, :shard_transport, InProcess)

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
              {:"b62a#{i}",
               Path.join(System.tmp_dir!(), "b62a_d#{i}_#{System.unique_integer([:positive])}")}

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

        if prev_backend,
          do: Application.put_env(:maxio, :storage_backend, prev_backend),
          else: Application.delete_env(:maxio, :storage_backend)

        if prev_auth,
          do: Application.put_env(:maxio, :authoritative_source, prev_auth),
          else: Application.delete_env(:maxio, :authoritative_source)

        if prev_tx,
          do: Application.put_env(:maxio, :shard_transport, prev_tx),
          else: Application.delete_env(:maxio, :shard_transport)

        if prev_ec,
          do: Application.put_env(:maxio, :erasure, prev_ec),
          else: Application.delete_env(:maxio, :erasure)

        Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end)
      end)

      {:ok, eps: eps}
    end

    test "两-part MPU → :read=:sidecar GET ETag 头 == \"...-2\"；端点 sidecar entry/core etag 分工正确",
         %{eps: eps} do
      bucket = "rb62r5"
      key = "mp.bin"
      assert SigV4Request.signed_conn(:put, "/" <> bucket) |> call() |> Map.fetch!(:status) == 200

      part1 = "distributed sidecar mpu part one"
      part2 = "distributed sidecar mpu part two!"
      mp_etag = http_mpu!(bucket, key, part1, part2)
      assert String.ends_with?(mp_etag, "-2")

      # :read=:sidecar 的 HTTP GET：ETag 头即盘上 sidecar entry etag —— 必须是 -N 多段形态。
      get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
      assert get.status == 200
      assert get_resp_header(get, "etag") == ["\"#{mp_etag}\""]
      assert get.resp_body == part1 <> part2

      # 端点盘上 sidecar：entry etag = 多段 ETag；耐久 core etag = 整体字节 MD5（不动）。
      {:ok, rel} = Paths.object_rel(bucket, key, "null")
      whole_md5 = :crypto.hash(:md5, part1 <> part2) |> Base.encode16(case: :lower)

      meta =
        Enum.find_value(eps, fn {_n, d} ->
          case File.read(Path.join([d, rel, "meta.json"])) do
            {:ok, bin} -> Sidecar.decode!(bin)
            {:error, _} -> nil
          end
        end)

      assert meta["format"] == "maxio/2"
      assert [entry] = meta["versions"]
      assert entry["etag"] == mp_etag
      assert meta["etag"] == whole_md5
    end
  end
end
