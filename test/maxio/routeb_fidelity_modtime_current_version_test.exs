defmodule Maxio.RouteBFidelityModtimeCurrentVersionTest do
  @moduledoc """
  ROUTE B fidelity（B5-2 审计 critical/high）—— 跨版本「当前版本」必须按**写时间序**收敛
  （对齐 MinIO sortByModTime / AWS suspended-bucket delete marker 语义），绝不无条件剔除 "null"。

  旧缺陷：`Listing.current_version` 先 reject "null" 再 max-ULID —— "null" 只在无 ULID 时当选。
  后果（Enabled 历史 + Suspend 后）：
    * DELETE（无 versionId）写出的 null delete-marker 永远当不上当前版本 → sidecar 读权威下
      GET 仍 200 旧 ULID 版本、LIST 仍列出 key = **已删对象复活**；
    * Suspended PUT 的 null 版本同样永远当不上当前版本 → GET 返回陈旧 ULID 数据；
    * B5-2 scanner 以同一语义收敛 PG → 把（正确的）PG marker latest 翻回旧 ULID 版本，
      在派生索引读路径上**主动**复活已删对象。

  AWS：「Amazon S3 inserts a delete marker that becomes the current version of the object」——
  明确包括 versioning-suspended 桶且既有真实 versionId 版本的场景（DeletingObjectsfromVersioning-
  SuspendedBuckets / DeleteMarker 文档）。MinIO：xl.meta versions 严格按 ModTime 降序，index 0 =
  latest，与 version-id 形态无关（cmd/xl-storage-format-v2.go sortByModTime/sortsBefore）。

  范式与 routeb_b5_0_delete_marker_sidecar_e2e_test.exs 一致：distributed 后端 + InProcess
  transport + 注入 3 端点 K=2/M=1/N=3 topology，全部经真实写路径（Storage.put /
  Storage.put_delete_marker）落盘，绝不手搓 sidecar。`async: false`：全局 backend 切换 + InProcess。
  """
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Listing, ObjectMeta, Objects, Storage}
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.Scanner
  alias Maxio.Versioning.VersionId

  @bucket "rbmtcv"
  @owner "arn:aws:iam:::root"

  setup do
    InProcess.setup!()

    prev_backend = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)

    eps =
      for i <- 0..2,
          do:
            {:"rbmt#{i}",
             Path.join(System.tmp_dir!(), "rbmt_d#{i}_#{System.unique_integer([:positive])}")}

    # K=2 M=1 N=3 → read_quorum=2、write_quorum=3，单 set（与既有 sidecar authority 套件一致）。
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

  defp put_opts(topo), do: [transport: InProcess, topology: topo]

  defp read_opts(topo),
    do: [transport: InProcess, topology: topo, authoritative_source: [read: :sidecar]]

  defp list_opts(topo),
    do: [transport: InProcess, topology: topo, authoritative_source: [list: :sidecar]]

  defp scan_opts(topo),
    do: [
      transport: InProcess,
      topology: topo,
      bucket: @bucket,
      authoritative_source: [write: :sidecar]
    ]

  defp object_meta do
    %{
      content_type: "text/plain",
      tags: %{},
      sse: nil,
      acl_canned: "private",
      storage_class: "STANDARD",
      user_metadata: %{}
    }
  end

  defp real_put(topo, key, version_id, body) do
    {:ok, %{etag: etag}} =
      Storage.put(
        @bucket,
        key,
        version_id,
        [body],
        [object_meta: object_meta()] ++ put_opts(topo)
      )

    etag
  end

  describe "Enabled 历史 + Suspend 后 DELETE：null delete marker 必须成为当前版本" do
    test "GET latest → 404 视图（is_delete_marker，version null）；LIST 隐藏 key；current_version 选 null",
         %{topo: topo} do
      obj_vid = VersionId.generate()
      _etag = real_put(topo, "k", obj_vid, "enabled-era object body")

      # Suspend 后 DELETE（无 versionId）→ null marker（写在 ULID 版本之后 = modtime 更晚）。
      # 与 handler commit_delete_marker_sidecar 的 Suspended 流程逐字一致：先删既有 null 版本
      # （此处不存在，no-op）再写 null marker sidecar。
      Process.sleep(5)
      assert :ok = Storage.put_delete_marker(@bucket, "k", "null", [], put_opts(topo))

      # 单一语义源直接取证：null（晚写的 marker）胜过既有 ULID 版本。
      assert Listing.current_version(@bucket, "k", [obj_vid, "null"], put_opts(topo)) == "null"
      assert Listing.discover_current_version(@bucket, "k", put_opts(topo)) == "null"

      # :read=:sidecar GET latest → 404 视图（is_delete_marker:true + null version），绝不复活旧 ULID 版本。
      after_del = ObjectMeta.get(@bucket, "k", nil, read_opts(topo))
      assert %Objects.Object{} = after_del
      assert after_del.is_delete_marker == true
      assert after_del.version_id == "null"

      # :list=:sidecar LIST → key 不出现（当前版本为 delete marker）。
      res = ObjectMeta.list(@bucket, %{}, list_opts(topo))
      assert Enum.find(res.objects, fn o -> o.key == "k" end) == nil
    end

    test "scanner 收敛保持 marker latest（绝不把正确的 PG marker 行翻回旧 ULID 版本）", %{topo: topo} do
      {:ok, _b} = Buckets.create(@bucket, @owner)

      obj_vid = VersionId.generate()
      etag = real_put(topo, "kscan", obj_vid, "scan body")
      Process.sleep(5)
      assert :ok = Storage.put_delete_marker(@bucket, "kscan", "null", [], put_opts(topo))

      # PG 预置「正确」状态（模拟在线写路径已落索引）：ULID 版本行 + null marker latest 行。
      {:ok, _} =
        Objects.put_version_with_id(@bucket, "kscan", obj_vid, %{
          size: byte_size("scan body"),
          etag: etag,
          content_type: "text/plain"
        })

      {:ok, _} = Objects.insert_delete_marker_with_id(@bucket, "kscan", "null")

      {:ok, marker_pre} = Objects.get_version(@bucket, "kscan", "null")
      assert marker_pre.is_latest == true

      # 一轮 scanner：marker 行必须保持 is_latest=true、ULID 行 is_latest=false
      # （旧语义会把 latest 翻回 ULID 行 = 派生索引上的已删对象复活）。
      assert {:ok, %{status: :ok}} = Scanner.run_once(scan_opts(topo))

      {:ok, marker} = Objects.get_version(@bucket, "kscan", "null")
      assert marker.is_delete_marker == true
      assert marker.is_latest == true

      {:ok, obj} = Objects.get_version(@bucket, "kscan", obj_vid)
      assert obj.is_delete_marker == false
      assert obj.is_latest == false
    end

    test "PG 全缺时 scanner 从盘建行：marker latest、旧 ULID 版本非 latest", %{topo: topo} do
      {:ok, _b} = Buckets.create(@bucket, @owner)

      obj_vid = VersionId.generate()
      _etag = real_put(topo, "kfresh", obj_vid, "fresh body")
      Process.sleep(5)
      assert :ok = Storage.put_delete_marker(@bucket, "kfresh", "null", [], put_opts(topo))

      assert {:ok, %{upserted: 2}} = Scanner.run_once(scan_opts(topo))

      {:ok, marker} = Objects.get_version(@bucket, "kfresh", "null")
      assert marker.is_delete_marker == true
      assert marker.is_latest == true

      {:ok, obj} = Objects.get_version(@bucket, "kfresh", obj_vid)
      assert obj.is_latest == false
    end
  end

  describe "Enabled 历史 + Suspend 后 PUT：晚写的 null 版本必须成为当前版本" do
    test "GET latest 返回 null 版本（新字节），绝不再返回陈旧 ULID 版本", %{topo: topo} do
      obj_vid = VersionId.generate()
      _old_etag = real_put(topo, "kput", obj_vid, "old ulid bytes")

      Process.sleep(5)
      new_etag = real_put(topo, "kput", "null", "new suspended null bytes")

      assert Listing.current_version(@bucket, "kput", [obj_vid, "null"], put_opts(topo)) == "null"

      latest = ObjectMeta.get(@bucket, "kput", nil, read_opts(topo))
      assert %Objects.Object{} = latest
      assert latest.version_id == "null"
      assert latest.etag == new_etag
      assert latest.is_delete_marker == false
    end
  end

  describe "回归保护：null 先写、ULID 后写 → ULID 仍是当前版本（写时间序，非 null 偏好）" do
    test "GET latest 返回更晚的 ULID 版本", %{topo: topo} do
      _null_etag = real_put(topo, "kreg", "null", "older null bytes")
      Process.sleep(5)
      obj_vid = VersionId.generate()
      ulid_etag = real_put(topo, "kreg", obj_vid, "newer ulid bytes")

      assert Listing.current_version(@bucket, "kreg", ["null", obj_vid], put_opts(topo)) ==
               obj_vid

      latest = ObjectMeta.get(@bucket, "kreg", nil, read_opts(topo))
      assert latest.version_id == obj_vid
      assert latest.etag == ulid_etag
    end

    test "纯 ULID 集仍取 max ULID（零读盘路径不变）", %{topo: topo} do
      v1 = VersionId.generate()
      Process.sleep(2)
      v2 = VersionId.generate()
      assert Listing.current_version(@bucket, "nokey", [v1, v2], put_opts(topo)) == max(v1, v2)
    end

    test "仅 null → null；空集 → nil", %{topo: topo} do
      assert Listing.current_version(@bucket, "nokey", ["null"], put_opts(topo)) == "null"
      assert Listing.current_version(@bucket, "nokey", [], put_opts(topo)) == nil
    end
  end

  describe "VersionId.timestamp_ms（ULID 写时间下界回退）" do
    test "解析自产 ULID 的 48-bit ms 时间戳（与当前时刻同量级）" do
      before_ms = System.system_time(:millisecond)
      vid = VersionId.generate()
      after_ms = System.system_time(:millisecond)

      assert {:ok, ms} = VersionId.timestamp_ms(vid)
      assert ms >= before_ms and ms <= after_ms
    end

    test "\"null\" / 非法长度 → :error（绝不猜）" do
      assert VersionId.timestamp_ms("null") == :error
      assert VersionId.timestamp_ms("") == :error
      assert VersionId.timestamp_ms(String.duplicate("u", 26)) == :error
    end
  end
end
