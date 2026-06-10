defmodule Maxio.Storage.ScannerTest do
  @moduledoc """
  ROUTE B B5-2 —— 派生索引 scanner（forward reconcile + 保守 reverse-GC + dry-run）取证。

  范式与 `routeb_real_put_sidecar_authority_e2e_test.exs` 一致：distributed 后端 + InProcess
  transport + 注入 3 端点 topology（K=2/M=1/N=3），**真实 `Storage.put` / `Storage.put_delete_marker`
  产出盘上 maxio/2 sidecar，绝不手搓**。场景矩阵（计划 B5-2 §4）：

    * PG 缺行（盘上有）→ upsert（null 布局 + `.versions` 版本树都覆盖）；
    * PG stale（字段漂移）→ 修正收敛到盘上权威；幂等（第二轮零写）；
    * PG 孤儿行（盘上所有端点可达且全部显式 missing）→ reverse-GC 删行；
    * 任一端点 down → skip 绝不删（铁律 3 绝不把不可达当不存在）；
    * --dry-run → 只报告（would-计数）零 PG 写入；
    * delete marker 版本（B5-0 落盘 sidecar）→ is_delete_marker 行 + 跨版本 latest 收敛；
    * 默认 disabled：GenServer 启动但不调度；无拓扑 run_once 安全 no-op。

  `async: false`：InProcess down 表全局 + 切全局 :storage_backend。
  """
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maxio.{Buckets, Objects, Storage}
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.Scanner
  alias Maxio.Versioning.VersionId

  @bucket "b52scan"
  @owner "arn:aws:iam:::root"

  setup do
    InProcess.setup!()

    prev_backend = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)

    eps =
      for i <- 0..2,
          do:
            {:"b52n#{i}",
             Path.join(System.tmp_dir!(), "b52_d#{i}_#{System.unique_integer([:positive])}")}

    # K=2 M=1 N=3 → read_quorum=2、write_quorum=3，单 set（与既有 sidecar authority 套件一致）。
    topo = %{
      data_shards: 2,
      parity_shards: 1,
      block_size: 1024,
      sets: %{0 => %{id: 0, endpoints: eps}},
      set_ids: [0]
    }

    {:ok, _b} = Buckets.create(@bucket, @owner)

    on_exit(fn ->
      if prev_backend,
        do: Application.put_env(:maxio, :storage_backend, prev_backend),
        else: Application.delete_env(:maxio, :storage_backend)

      Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end)
    end)

    {:ok, eps: eps, topo: topo}
  end

  defp scan_opts(topo, extra \\ []),
    do: [transport: InProcess, topology: topo, bucket: @bucket] ++ extra

  # test 全局 logger level 是 :warning（config/test.exs）——scanner 的逐对象动作日志是 info 级
  # （action: :reconcile_index / :reverse_gc），断言它们须临时降 level 到 :info（async: false 安全）。
  defp with_info_log(fun) do
    prev = Logger.level()
    Logger.configure(level: :info)

    try do
      with_log(fun)
    after
      Logger.configure(level: prev)
    end
  end

  # 真实 PUT 一个对象版本到盘（distributed + InProcess，落 maxio/2 sidecar）；返回盘上 etag。
  defp disk_put!(topo, key, vid, body) do
    om = %{
      content_type: "text/plain",
      tags: %{"t" => "v"},
      sse: nil,
      acl_canned: "private",
      storage_class: "STANDARD",
      user_metadata: %{"a" => "1"}
    }

    {:ok, %{etag: etag}} =
      Storage.put(@bucket, key, vid, [body],
        object_meta: om,
        transport: InProcess,
        topology: topo
      )

    etag
  end

  describe "forward reconcile（盘 → PG）" do
    test "PG 缺行（盘上有，null 布局）→ upsert 建行（全字段 + synced 注入）", %{topo: topo} do
      etag = disk_put!(topo, "k-missing", "null", "hello scanner")
      assert {:error, :not_found} = Objects.get_version(@bucket, "k-missing", "null")

      {result, log} = with_info_log(fn -> Scanner.run_once(scan_opts(topo)) end)

      assert {:ok, report} = result
      assert report.status == :ok
      assert report.buckets == 1
      assert report.upserted == 1
      assert report.gc == 0
      assert report.divergent == 0
      assert log =~ "reconciled from sidecar authority"

      {:ok, row} = Objects.get_version(@bucket, "k-missing", "null")
      assert row.etag == etag
      assert row.size == byte_size("hello scanner")
      assert row.content_type == "text/plain"
      assert row.metadata == %{"a" => "1"}
      assert row.tags == %{"t" => "v"}
      assert row.is_latest == true
      assert row.is_delete_marker == false
      assert %DateTime{} = row.synced_at
    end

    test "PG 缺行（盘上有，.versions 版本树）→ upsert 建行", %{topo: topo} do
      vid = VersionId.generate()
      etag = disk_put!(topo, "k-ver", vid, "versioned body")

      assert {:ok, %{upserted: 1, gc: 0}} = Scanner.run_once(scan_opts(topo))

      {:ok, row} = Objects.get_version(@bucket, "k-ver", vid)
      assert row.etag == etag
      assert row.is_latest == true
    end

    test "PG stale（字段漂移）→ 修正收敛到盘上权威", %{topo: topo} do
      etag = disk_put!(topo, "k-stale", "null", "authoritative bytes")

      {:ok, _} =
        Objects.put_version_with_id(@bucket, "k-stale", "null", %{size: 999, etag: "\"drift\""})

      assert {:ok, report} = Scanner.run_once(scan_opts(topo))
      assert report.upserted == 1

      {:ok, row} = Objects.get_version(@bucket, "k-stale", "null")
      assert row.etag == etag
      assert row.size == byte_size("authoritative bytes")
      assert row.metadata == %{"a" => "1"}
    end

    test "已同步行 → 幂等零写（第二轮 upserted=0）", %{topo: topo} do
      _ = disk_put!(topo, "k-sync", "null", "stable")

      assert {:ok, %{upserted: 1}} = Scanner.run_once(scan_opts(topo))

      assert {:ok, %{upserted: 0, gc: 0, skipped: 0, scanned: 1}} =
               Scanner.run_once(scan_opts(topo))
    end

    test "delete marker 版本（B5-0 落盘 sidecar）→ is_delete_marker 行 + 跨版本 latest 收敛", %{
      topo: topo
    } do
      _ = disk_put!(topo, "k-dm", "null", "to be deleted")
      mvid = VersionId.generate()

      :ok =
        Storage.put_delete_marker(@bucket, "k-dm", mvid, [],
          transport: InProcess,
          topology: topo
        )

      assert {:ok, %{upserted: 2, gc: 0}} = Scanner.run_once(scan_opts(topo))

      {:ok, marker} = Objects.get_version(@bucket, "k-dm", mvid)
      assert marker.is_delete_marker == true
      assert marker.is_latest == true

      # null 对象 sidecar 自身的 is_latest 写时缓存为 true（每版本独立 sidecar 不回写），
      # scanner 跨版本收敛后 PG 行须为 false（marker 才是当前版本）。
      {:ok, obj} = Objects.get_version(@bucket, "k-dm", "null")
      assert obj.is_delete_marker == false
      assert obj.is_latest == false
    end
  end

  describe "reverse-GC（PG 孤儿行）" do
    test "盘上所有端点可达且全部显式 missing → 删行", %{topo: topo} do
      vid = VersionId.generate()
      {:ok, _} = Objects.put_version_with_id(@bucket, "k-ghost", vid, %{size: 1, etag: "\"g\""})

      {result, log} = with_info_log(fn -> Scanner.run_once(scan_opts(topo)) end)

      assert {:ok, report} = result
      assert report.gc == 1
      assert report.skipped == 0
      assert log =~ "reverse-GC orphan derived index row"

      assert {:error, :not_found} = Objects.get_version(@bucket, "k-ghost", vid)
    end

    test "任一端点 down → skip 绝不删（铁律 3 绝不把不可达当不存在）", %{eps: eps, topo: topo} do
      vid = VersionId.generate()
      {:ok, _} = Objects.put_version_with_id(@bucket, "k-ghost2", vid, %{size: 1, etag: "\"g\""})

      # down 表 ETS 归测试进程所有、随其退出销毁（且下个测试 setup! 会清空）——无需 on_exit 还原。
      {node0, _} = hd(eps)
      InProcess.set_down(node0)

      {result, log} = with_log(fn -> Scanner.run_once(scan_opts(topo)) end)

      assert {:ok, report} = result
      assert report.gc == 0
      assert report.skipped == 1
      assert log =~ "endpoint unreachable, skipping reverse-GC"

      assert {:ok, _row} = Objects.get_version(@bucket, "k-ghost2", vid)
    end

    test "盘上有版本（forward 已见）绝不被 reverse-GC", %{topo: topo} do
      _ = disk_put!(topo, "k-live", "null", "live")

      assert {:ok, %{gc: 0}} = Scanner.run_once(scan_opts(topo))
      assert {:ok, _} = Objects.get_version(@bucket, "k-live", "null")
    end
  end

  describe "--dry-run（只报告绝不写）" do
    test "would-upsert + would-gc 都只报告，PG 零写入", %{topo: topo} do
      _ = disk_put!(topo, "k-dr-disk", "null", "disk only")
      vid = VersionId.generate()

      {:ok, _} =
        Objects.put_version_with_id(@bucket, "k-dr-ghost", vid, %{size: 1, etag: "\"g\""})

      {result, log} = with_info_log(fn -> Scanner.run_once(scan_opts(topo, dry_run: true)) end)

      assert {:ok, report} = result
      assert report.dry_run == true
      assert report.upserted == 1
      assert report.gc == 1
      assert log =~ "dry-run: would reconcile"
      assert log =~ "dry-run: would reverse-GC"

      # 零写入：缺行仍缺、孤儿仍在。
      assert {:error, :not_found} = Objects.get_version(@bucket, "k-dr-disk", "null")
      assert {:ok, _} = Objects.get_version(@bucket, "k-dr-ghost", vid)
    end
  end

  describe "--bucket 过滤" do
    test "仅扫指定桶，其他桶的孤儿行不动", %{topo: topo} do
      {:ok, _} = Buckets.create("b52other", @owner)
      vid = VersionId.generate()

      {:ok, _} =
        Objects.put_version_with_id("b52other", "k-other", vid, %{size: 1, etag: "\"o\""})

      assert {:ok, report} = Scanner.run_once(scan_opts(topo))
      assert report.buckets == 1
      assert {:ok, _} = Objects.get_version("b52other", "k-other", vid)
    end
  end

  describe "默认配置 / 无拓扑（行为不变 + 安全 no-op）" do
    test "scanner 默认 disabled：config 默认值 + GenServer 启动但不调度" do
      cfg = Application.get_env(:maxio, :scanner)
      assert Keyword.get(cfg, :enabled) == false
      assert Keyword.get(cfg, :interval_ms) == 86_400_000
      assert Keyword.get(cfg, :batch_size) == 500

      pid = Process.whereis(Maxio.Storage.Scanner)
      assert is_pid(pid)
      assert :sys.get_state(pid) == %{enabled: false}
    end

    test "无拓扑（单机 FS / dev）→ run_once 安全 no-op（status: :no_topology 零计数）" do
      {result, log} = with_log(fn -> Scanner.run_once([]) end)

      assert {:ok, report} = result
      assert report.status == :no_topology
      assert report.scanned == 0
      assert report.upserted == 0
      assert report.gc == 0
      assert log =~ "no distributed topology"
    end
  end
end
