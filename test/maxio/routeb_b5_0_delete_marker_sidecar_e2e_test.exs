defmodule Maxio.RouteBB5_0DeleteMarkerSidecarE2ETest do
  @moduledoc """
  ROUTE B B5-0 —— DeleteObject/DeleteObjects 在 version_id 盘上路径落 delete-marker sidecar 的
  端到端取证（修「已删对象复活」critical）。

  根因：`Objects.insert_delete_marker` 纯 PG，盘上从不落 delete-marker sidecar →
  `authoritative_source(:read|:list)=:sidecar` 下 DeleteObject 后盘上旧对象 sidecar 仍在 →
  GET 仍 200、LIST 仍列出 = 已删对象复活。修法（架构层）：删除是写操作，必须被盘上权威记录——
  Storage behaviour 新 callback `put_delete_marker/5` 在 version_id 盘上路径写纯 delete-marker
  maxio/2 sidecar，达 write_quorum（temp→rename 原子，复用 PUT 同级原语）。

  与 `routeb_real_put_sidecar_authority_e2e_test.exs` 同范式（distributed 后端 + InProcess transport
  + 注入 3 端点 K=2/M=1/N=3 topology），**严禁手搓 sidecar**——全部经真实写路径（Storage.put /
  Storage.put_delete_marker）取证。读侧 `ObjectMeta.view_or_not_found` / `Maxio.Listing` 的
  delete_marker 处理 B4-3/B4-4 已就绪，本套件证写侧落盘后读侧不再复活。

    * Case A（Enabled）：真实 PUT → 真实 put_delete_marker（新 ULID marker）→ :read=:sidecar GET
      latest → 404 视图（is_delete_marker:true，不复活）；:list=:sidecar LIST → key 不出现；
      撤销（删 marker version 字节 + PG 行）→ GET 恢复 200。
    * Case B（Suspended）：null marker 替换既有 null 版本——先删 null 字节 + sidecar 再写 null marker
      → :read=:sidecar GET → 404 视图（不复活）。
    * Case C（DeleteObjects 批量语义）：多 key 各落 marker → 各 key GET 404、LIST 全不出现。
  """
  use Maxio.DataCase, async: false

  alias Maxio.{ObjectMeta, Sidecar, Storage}
  alias Maxio.Cluster.{Paths, Transport.InProcess}
  alias Maxio.Versioning.VersionId

  @bucket "rbdm"

  setup do
    InProcess.setup!()

    prev_backend = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)

    eps =
      for i <- 0..2,
          do:
            {:"rbdm#{i}",
             Path.join(System.tmp_dir!(), "rbdm_d#{i}_#{System.unique_integer([:positive])}")}

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

  # 真实 PUT 一个对象版本（驱动 Storage.put → Distributed 后端，落 maxio/2 sidecar）。
  defp real_put(topo, key, version_id, body) do
    assert {:ok, %{etag: etag}} =
             Storage.put(
               @bucket,
               key,
               version_id,
               [body],
               [object_meta: object_meta()] ++ put_opts(topo)
             )

    etag
  end

  # 从任一解码盘读出落盘 sidecar（真实写出的，绝不手搓）。
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

  describe "Case A — Enabled 桶：PUT → put_delete_marker → :sidecar 不复活 + 撤销恢复" do
    test "DeleteObject（无 versionId）后 :read=:sidecar GET 得 404 视图（is_delete_marker），:list 不出现",
         %{eps: eps, topo: topo} do
      obj_vid = VersionId.generate()
      body = "enabled object body to be deleted"
      etag = real_put(topo, "k", obj_vid, body)

      # 删前：latest = 对象版本，GET 返回真实对象（200 路径）。
      pre = ObjectMeta.get(@bucket, "k", nil, read_opts(topo))
      assert %Maxio.Objects.Object{} = pre
      assert pre.is_delete_marker == false
      assert pre.version_id == obj_vid
      assert pre.etag == etag

      # 真实 DELETE（无 versionId）→ 盘上落 delete-marker sidecar（新 ULID marker vid，比对象 vid 大 = 后生成）。
      marker_vid = VersionId.generate()
      assert :ok = Storage.put_delete_marker(@bucket, "k", marker_vid, [], put_opts(topo))

      # 落盘 marker sidecar 是纯 delete-marker maxio/2（无 part.0、无 ec/shards core）。
      meta = read_disk_sidecar(eps, "k", marker_vid)
      assert meta["format"] == "maxio/2"
      assert [entry] = meta["versions"]
      assert entry["type"] == "delete_marker"
      assert entry["version_id"] == marker_vid
      assert entry["is_latest"] == true
      assert entry["generation"] == 0
      assert is_integer(entry["modtime"])
      refute Map.has_key?(meta, "shards")
      refute Map.has_key?(meta, "etag")

      # :read=:sidecar GET latest → 404 视图（is_delete_marker:true + marker version_id），绝不复活。
      after_del = ObjectMeta.get(@bucket, "k", nil, read_opts(topo))
      assert %Maxio.Objects.Object{} = after_del
      assert after_del.is_delete_marker == true
      assert after_del.version_id == marker_vid

      # :list=:sidecar LIST → key 不出现（当前版本为 delete marker 被剔除）。
      res = ObjectMeta.list(@bucket, %{}, list_opts(topo))
      assert Enum.find(res.objects, fn o -> o.key == "k" end) == nil
    end

    test "撤销删除（删 marker version 字节）→ :read=:sidecar GET 恢复 200（对象重新浮现）", %{topo: topo} do
      obj_vid = VersionId.generate()
      etag = real_put(topo, "kundo", obj_vid, "undo body")

      marker_vid = VersionId.generate()
      assert :ok = Storage.put_delete_marker(@bucket, "kundo", marker_vid, [], put_opts(topo))

      # 删后 latest = marker → 404 视图。
      assert %Maxio.Objects.Object{is_delete_marker: true} =
               ObjectMeta.get(@bucket, "kundo", nil, read_opts(topo))

      # 撤销：永久删 marker 的 version_id 盘上字节/sidecar（DELETE ?versionId=<marker>）。
      assert :ok = Maxio.Storage.Distributed.delete(@bucket, "kundo", marker_vid, put_opts(topo))

      # latest 退回到对象版本 → GET 恢复 200（真实对象，etag 一致）。
      restored = ObjectMeta.get(@bucket, "kundo", nil, read_opts(topo))
      assert %Maxio.Objects.Object{} = restored
      assert restored.is_delete_marker == false
      assert restored.version_id == obj_vid
      assert restored.etag == etag
    end
  end

  describe "Case B — Suspended 桶：null marker 替换既有 null 版本" do
    test "先删 null 字节+sidecar 再写 null marker → :read=:sidecar GET 404 视图（不复活）", %{
      eps: eps,
      topo: topo
    } do
      # Suspended 桶对象落 null 路径。
      _etag = real_put(topo, "ksusp", "null", "suspended null object")

      pre = ObjectMeta.get(@bucket, "ksusp", nil, read_opts(topo))
      assert %Maxio.Objects.Object{is_delete_marker: false, version_id: "null"} = pre

      # Suspended 语义：null marker 替换既有 null 版本——先删 null 字节+sidecar 再写 null marker。
      assert :ok = Maxio.Storage.Distributed.delete(@bucket, "ksusp", "null", put_opts(topo))
      assert :ok = Storage.put_delete_marker(@bucket, "ksusp", "null", [], put_opts(topo))

      # null 路径 sidecar 现在是纯 delete marker（替换，绝不与旧对象 sidecar 共存）。
      meta = read_disk_sidecar(eps, "ksusp", "null")
      assert meta["format"] == "maxio/2"
      assert [%{"type" => "delete_marker", "version_id" => "null"}] = meta["versions"]

      after_del = ObjectMeta.get(@bucket, "ksusp", nil, read_opts(topo))
      assert %Maxio.Objects.Object{} = after_del
      assert after_del.is_delete_marker == true
      assert after_del.version_id == "null"

      res = ObjectMeta.list(@bucket, %{}, list_opts(topo))
      assert Enum.find(res.objects, fn o -> o.key == "ksusp" end) == nil
    end
  end

  describe "Case C — DeleteObjects 批量：多 key 各落 marker，全不复活" do
    test "三 key 各 put_delete_marker → 各 GET 404、LIST 全不出现", %{topo: topo} do
      keys = ["batch/a", "batch/b", "batch/c"]

      marker_vids =
        for k <- keys, into: %{} do
          _etag = real_put(topo, k, VersionId.generate(), "batch body #{k}")
          mvid = VersionId.generate()
          assert :ok = Storage.put_delete_marker(@bucket, k, mvid, [], put_opts(topo))
          {k, mvid}
        end

      # 每 key :read=:sidecar GET → 404 视图（is_delete_marker），版本为各自 marker vid。
      for k <- keys do
        v = ObjectMeta.get(@bucket, k, nil, read_opts(topo))
        assert %Maxio.Objects.Object{} = v
        assert v.is_delete_marker == true
        assert v.version_id == marker_vids[k]
      end

      # :list=:sidecar LIST → 三 key 全不出现（当前版本均为 delete marker）。
      res = ObjectMeta.list(@bucket, %{}, list_opts(topo))

      for k <- keys do
        assert Enum.find(res.objects, fn o -> o.key == k end) == nil
      end
    end
  end

  # ROUTE B B6-1：FS put_delete_marker 已实装（marker sidecar 落盘，quorum=1）——B5-0 时期的
  # {:error, :not_supported} 哨兵断言随之退役；FS marker e2e 见 test/maxio/storage/fs_sidecar_test.exs。
  describe "FS 后端 put_delete_marker 实装（B6-1，不再 :not_supported）" do
    test "FS.put_delete_marker 单盘提交成功返回 :ok" do
      dir =
        Path.join(System.tmp_dir!(), "maxio_b50_fs_marker_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert :ok =
               Maxio.Storage.FS.put_delete_marker("anybucket", "anykey", "null", [],
                 data_dir: dir
               )

      meta_path = Path.join([dir, "anybucket", "anykey", "meta.json"])
      assert File.regular?(meta_path)
    end
  end
end
