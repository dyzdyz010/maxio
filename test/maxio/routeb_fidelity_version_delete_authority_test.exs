defmodule Maxio.RouteBFidelityVersionDeleteAuthorityTest do
  @moduledoc """
  ROUTE B fidelity（B5-2 审计 high）—— DELETE ?versionId 必须被**写权威介质**记录。

  旧缺陷：版本永久删除 PG-first（`Objects.delete_version` 权威、盘上删除结果静默丢弃；PG 行缺失时
  甚至完全不触盘就回 204）。`authoritative_source(:write)=:sidecar` 下盘上才是权威：客户端拿到 204
  但盘上版本仍在 → B5-2 scanner forward 从幸存 sidecar 忠实 re-upsert 回 PG（**已永久删除的版本
  复活**），且 reverse-GC「盘上确有 → 绝不删」守恒保证该行永不消失。

  修法（镜像 B5-0 commit_delete_marker split）：
    * `:sidecar` 写权威 → `Storage.delete_version`（盘上版本目录 quorum 删除 + list_dir 确认探针）
      即权威提交；quorum 不足 → `{:error,:write_quorum}` → 503 SlowDownWrite，绝不 204
      （对齐 MinIO DeleteVersion：errErasureWriteQuorum → ErrSlowDownWrite）；PG 行删除降
      best-effort 索引维护（`Objects.delete_version_index`）。
    * `:pg`（默认）→ 语义不变，盘上删除失败不再静默丢弃（Log.warn）。

  取证层次：
    1. Distributed.delete_version 的 quorum 语义（全可达 :ok 全端点清除；端点 down → 绝不静默成功）；
    2. scanner 不复活：write_quorum < N 拓扑下 204 后幸存副本 < read_quorum → 绝不 re-index；
    3. 端点级 handler 回归（FS + 全局 write=:sidecar）：PG 行缺失时 DELETE ?versionId 仍删盘上
       字节（旧代码 204 完全不触盘）。
  """
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Listing, Objects, Storage}
  alias Maxio.Cluster.{Paths, Transport.InProcess}
  alias Maxio.S3.Endpoint
  alias Maxio.Storage.Scanner
  alias Maxio.Test.SigV4Request
  alias Maxio.Versioning.VersionId

  @owner "arn:aws:iam:::root"

  # ── 共用构件 ──

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

  defp make_topo(prefix, n, k, m) do
    eps =
      for i <- 0..(n - 1),
          do:
            {:"#{prefix}#{i}",
             Path.join(System.tmp_dir!(), "#{prefix}_d#{i}_#{System.unique_integer([:positive])}")}

    topo = %{
      data_shards: k,
      parity_shards: m,
      block_size: 1024,
      sets: %{0 => %{id: 0, endpoints: eps}},
      set_ids: [0]
    }

    {eps, topo}
  end

  defp put_opts(topo), do: [transport: InProcess, topology: topo]

  defp real_put(topo, bucket, key, version_id, body) do
    {:ok, %{etag: etag}} =
      Storage.put(bucket, key, version_id, [body], [object_meta: object_meta()] ++ put_opts(topo))

    etag
  end

  defp sidecar_path(drive, bucket, key, version_id) do
    {:ok, rel} = Paths.object_rel(bucket, key, version_id)
    Path.join([drive, rel, "meta.json"])
  end

  defp distributed_env(_ctx) do
    InProcess.setup!()

    prev_backend = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)

    on_exit(fn ->
      if prev_backend,
        do: Application.put_env(:maxio, :storage_backend, prev_backend),
        else: Application.delete_env(:maxio, :storage_backend)
    end)

    :ok
  end

  describe "Storage.delete_version（distributed）—— quorum 确认的权威删除" do
    setup :distributed_env

    # K=2 M=1 N=3 → write_quorum=3：全端点确认才成功。
    setup do
      {eps, topo} = make_topo("rbvd", 3, 2, 1)
      on_exit(fn -> Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end) end)
      {:ok, eps: eps, topo: topo}
    end

    test "全端点可达 → :ok 且版本目录全端点清除（幂等：再删仍 :ok）", %{eps: eps, topo: topo} do
      vid = VersionId.generate()
      _etag = real_put(topo, "rbvdb", "k", vid, "to be permanently deleted")

      for {_n, d} <- eps, do: assert(File.regular?(sidecar_path(d, "rbvdb", "k", vid)))

      assert :ok = Storage.delete_version("rbvdb", "k", vid, put_opts(topo))

      for {_n, d} <- eps, do: refute(File.exists?(sidecar_path(d, "rbvdb", "k", vid)))
      assert Listing.version_ids("rbvdb", "k", put_opts(topo)) == []

      # 幂等：版本本就不存在 → 仍 :ok（对齐 AWS 删除不存在版本回 204）。
      assert :ok = Storage.delete_version("rbvdb", "k", vid, put_opts(topo))
    end

    test "端点 down（确认数 < write_quorum）→ {:error, :write_quorum}，绝不静默成功", %{
      eps: eps,
      topo: topo
    } do
      vid = VersionId.generate()
      _etag = real_put(topo, "rbvdb", "kq", vid, "quorum gated delete")

      {node0, _} = hd(eps)
      InProcess.set_down(node0)

      # delete_shard 把宕机塌缩成 :ok——确认必须经 list_dir 探针，down 端点绝不计入确认。
      assert {:error, :write_quorum} = Storage.delete_version("rbvdb", "kq", vid, put_opts(topo))
    end
  end

  describe "scanner 不复活已 204 的版本删除（write_quorum < N 拓扑，幸存副本 < read_quorum）" do
    setup :distributed_env

    # K=3 M=1 N=4 → write_quorum=K=3 < N：一端点 down 时删除仍可 quorum 提交，
    # 该端点归来后持有幸存副本（1 < read_quorum=3）——scanner 绝不据此 re-index。
    setup do
      {eps, topo} = make_topo("rbvs", 4, 3, 1)
      on_exit(fn -> Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end) end)
      {:ok, eps: eps, topo: topo}
    end

    test "204（quorum 删除）后幸存盘上副本 → scanner 计 divergent、绝不 re-upsert PG 行", %{
      eps: eps,
      topo: topo
    } do
      bucket = "rbvsb"
      {:ok, _b} = Buckets.create(bucket, @owner)

      vid = VersionId.generate()
      etag = real_put(topo, bucket, "ks", vid, "deleted but one copy survives")

      # 在线写路径的 PG 索引行（best-effort 写穿）。
      {:ok, _} =
        Objects.put_version_with_id(bucket, "ks", vid, %{
          size: byte_size("deleted but one copy survives"),
          etag: etag,
          content_type: "text/plain"
        })

      # 端点 3 宕机期间 DELETE ?versionId：3/4 端点确认 ≥ write_quorum=3 → 权威提交成功（= 204），
      # PG 行 best-effort 删除。
      {node3, drive3} = List.last(eps)
      InProcess.set_down(node3)
      assert :ok = Storage.delete_version(bucket, "ks", vid, put_opts(topo))
      assert :ok = Objects.delete_version_index(bucket, "ks", vid)
      assert {:error, :not_found} = Objects.get_version(bucket, "ks", vid)

      # 端点 3 归来：幸存副本仍在其盘上（1 副本 < read_quorum=3）。
      InProcess.set_up(node3)
      assert File.regular?(sidecar_path(drive3, bucket, "ks", vid))

      # scanner 一轮：绝不把已永久删除的版本 reconcile 回 PG（quorum 不足 → divergent + skip）。
      assert {:ok, report} =
               Scanner.run_once(
                 transport: InProcess,
                 topology: topo,
                 bucket: bucket,
                 authoritative_source: [write: :sidecar]
               )

      assert report.status == :ok
      assert report.upserted == 0
      assert report.divergent >= 1
      assert {:error, :not_found} = Objects.get_version(bucket, "ks", vid)
    end
  end

  describe "端点级 handler 回归（FS + 全局 write=:sidecar）：PG 行缺失时 DELETE ?versionId 仍删盘" do
    setup do
      # 隔离对象数据目录 + 写权威切 :sidecar（与 write_authority_test 同范式）。
      data_dir = Path.join(System.tmp_dir!(), "maxio_vda_#{System.unique_integer([:positive])}")
      File.rm_rf(data_dir)
      File.mkdir_p!(data_dir)

      prev_s3 = Application.get_env(:maxio, :s3)
      prev_auth = Application.get_env(:maxio, :authoritative_source)
      Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))
      Application.put_env(:maxio, :authoritative_source, Keyword.put(prev_auth, :write, :sidecar))

      on_exit(fn ->
        Application.put_env(:maxio, :s3, prev_s3)
        Application.put_env(:maxio, :authoritative_source, prev_auth)
        File.rm_rf(data_dir)
      end)

      :ok
    end

    defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

    test "索引行缺失（best-effort 写失败模拟）→ DELETE ?versionId 204 且盘上字节必须被删除" do
      assert SigV4Request.signed_conn(:put, "/vda-sc") |> call() |> Map.fetch!(:status) == 200

      body = "version delete must hit the write authority medium"

      put =
        SigV4Request.signed_conn(:put, "/vda-sc/obj.txt", body: body) |> call()

      assert put.status == 200

      # 模拟 best-effort PG 索引写失败后的状态：行缺失，但盘上（写权威介质）字节仍在。
      :ok = Objects.delete_metadata("vda-sc", "obj.txt")
      assert {:ok, %{size: _}} = Storage.stat("vda-sc", "obj.txt", "null")

      # 旧缺陷：{:error,:not_found} 分支回 204 而完全不触盘 → scanner 复活。修后：盘上删除是
      # 权威提交，204 必须伴随盘上版本清除。
      del =
        SigV4Request.signed_conn(:delete, "/vda-sc/obj.txt", query: %{"versionId" => "null"})
        |> call()

      assert del.status == 204
      assert {:error, :enoent} = Storage.stat("vda-sc", "obj.txt", "null")

      # 幂等：再删同版本仍 204。
      del2 =
        SigV4Request.signed_conn(:delete, "/vda-sc/obj.txt", query: %{"versionId" => "null"})
        |> call()

      assert del2.status == 204
    end

    test "索引行在场 → DELETE ?versionId 204、盘 + 索引双清除" do
      assert SigV4Request.signed_conn(:put, "/vda-sc2") |> call() |> Map.fetch!(:status) == 200

      put = SigV4Request.signed_conn(:put, "/vda-sc2/obj.txt", body: "both media") |> call()
      assert put.status == 200
      assert {:ok, _} = Objects.get_version("vda-sc2", "obj.txt", "null")

      del =
        SigV4Request.signed_conn(:delete, "/vda-sc2/obj.txt", query: %{"versionId" => "null"})
        |> call()

      assert del.status == 204
      assert {:error, :enoent} = Storage.stat("vda-sc2", "obj.txt", "null")
      assert {:error, :not_found} = Objects.get_version("vda-sc2", "obj.txt", "null")
    end
  end
end
