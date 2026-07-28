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
    * 默认 disabled：GenServer 启动但不调度；非 FS 后端无拓扑 run_once 安全 no-op；
      FS 后端无全局拓扑时通过合成单端点 topology 真实 reconcile（B6-2）；
    * 写权威闸：authoritative_source(:write) != :sidecar（默认 :pg）→ run_once 一律拒绝
      （status: :authority_mismatch 零计数零写入，含 dry-run），仅显式 force: true 越闸——
      :pg 权威下 PG-only delete marker 盘上无 sidecar，跑一轮会复活已删对象 + GC 权威 marker 行。

  `async: false`：InProcess down 表全局 + 切全局 :storage_backend。
  """
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maxio.{BucketConfigs, Buckets, Objects, Storage}
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.S3.{NotificationDelivery, NotificationOutbox, NotificationRetainedLedger}
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

  # scanner 仅在 authoritative_source(:write)=:sidecar 下有意义（盘 = 写权威）——经 opts 注入
  # 写权威（与 ObjectMeta 同款 test 注入）过写权威闸；闸本身由「写权威闸」describe 单独取证。
  defp scan_opts(topo, extra \\ []),
    do:
      Keyword.merge(
        [
          transport: InProcess,
          topology: topo,
          bucket: @bucket,
          authoritative_source: [write: :sidecar]
        ],
        extra
      )

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
      content_encoding: "gzip",
      content_disposition: ~s(attachment; filename="scan.txt"),
      cache_control: "max-age=120",
      expires: "Wed, 21 Oct 2037 07:28:00 GMT",
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

  defp put_notification_config! do
    :ok =
      BucketConfigs.put(@bucket, :notification, %{
        "QueueConfigurations" => [
          %{
            "Id" => "scan-retained",
            "Queue" => "arn:aws:sqs:us-east-1:000000000000:scan-retained",
            "Events" => ["s3:ObjectCreated:Put"]
          }
        ],
        "TopicConfigurations" => [],
        "LambdaFunctionConfigurations" => [],
        "EventBridgeConfiguration" => nil
      })
  end

  defp put_restore_notification_config! do
    :ok =
      BucketConfigs.put(@bucket, :notification, %{
        "QueueConfigurations" => [
          %{
            "Id" => "scan-retained-restore",
            "Queue" => "arn:aws:sqs:us-east-1:000000000000:scan-retained-restore",
            "Events" => ["s3:ObjectRestore:Post"]
          }
        ],
        "TopicConfigurations" => [],
        "LambdaFunctionConfigurations" => [],
        "EventBridgeConfiguration" => nil
      })
  end

  defp retained_put_ledger!(topo, key, etag, body) do
    put_notification_config!()

    attrs = %{
      bucket: @bucket,
      key: key,
      size: byte_size(body),
      etag: etag,
      version_id: "null",
      request_id: "scan-retained-request",
      principal: :anonymous,
      source_ip: {127, 0, 0, 1}
    }

    sidecar_ledger = NotificationDelivery.sidecar_ledger("s3:ObjectCreated:Put", attrs)

    retained =
      NotificationRetainedLedger.entries(sidecar_ledger,
        bucket: @bucket,
        key: key,
        operation: :put_object,
        predicate:
          NotificationRetainedLedger.version_present("null",
            entry_type: "object",
            etag: etag,
            size: byte_size(body)
          ),
        request_id: attrs.request_id
      )

    :ok = Storage.put_notification_ledgers(@bucket, key, retained, scan_opts(topo))
    retained
  end

  defp retained_restore_ledger!(topo, key, etag, body, after_attrs) do
    put_restore_notification_config!()

    attrs = %{
      bucket: @bucket,
      key: key,
      size: byte_size(body),
      etag: etag,
      version_id: "null",
      storage_class: "GLACIER",
      source_storage_class: "GLACIER",
      restore_expiry: Map.get(after_attrs, :restore_expiry),
      request_id: "scan-retained-restore-request",
      principal: :anonymous,
      source_ip: {127, 0, 0, 1}
    }

    sidecar_ledger = NotificationDelivery.sidecar_ledger("s3:ObjectRestore:Post", attrs)

    retained =
      NotificationRetainedLedger.entries(sidecar_ledger,
        bucket: @bucket,
        key: key,
        operation: :restore_object,
        predicate:
          NotificationRetainedLedger.restore_state_transition(
            "null",
            %{restore_status: nil, restore_expiry: nil},
            after_attrs,
            entry_type: "object",
            etag: etag,
            size: byte_size(body)
          ),
        request_id: attrs.request_id
      )

    :ok = Storage.put_notification_ledgers(@bucket, key, retained, scan_opts(topo))
    retained
  end

  # 从任一端点读盘上真实写出的 sidecar（绝不手搓；B5-3 R1 取证 entry modtime 用）。
  defp read_disk_sidecar(eps, key, vid) do
    {:ok, rel} = Maxio.Cluster.Paths.object_rel(@bucket, key, vid)

    Enum.find_value(eps, fn {_n, d} ->
      case File.read(Path.join([d, rel, "meta.json"])) do
        {:ok, bin} -> Maxio.Sidecar.decode!(bin)
        {:error, _} -> nil
      end
    end)
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
      assert row.content_encoding == "gzip"
      assert row.content_disposition == ~s(attachment; filename="scan.txt")
      assert row.cache_control == "max-age=120"
      assert row.expires == "Wed, 21 Oct 2037 07:28:00 GMT"
      assert row.metadata == %{"a" => "1"}
      assert row.tags == %{"t" => "v"}
      assert row.is_latest == true
      assert row.is_delete_marker == false
      assert %DateTime{} = row.synced_at
    end

    test "invalid sidecar notification ledger is logged and does not crash scanner", %{
      eps: eps,
      topo: topo
    } do
      key = "k-invalid-notification-ledger"
      _etag = disk_put!(topo, key, "null", "bad ledger body")
      {:ok, rel} = Maxio.Cluster.Paths.object_rel(@bucket, key, "null")

      Enum.each(eps, fn {_node, drive} ->
        path = Path.join([drive, rel, "meta.json"])
        meta = path |> File.read!() |> Maxio.Sidecar.decode!()
        [entry] = meta["versions"]

        meta =
          Map.put(meta, "versions", [
            Map.put(entry, "notification_outbox", %{"unexpected" => "shape"})
          ])

        File.write!(path, Maxio.Sidecar.encode(meta))
      end)

      {result, log} = with_log(fn -> Scanner.run_once(scan_opts(topo)) end)

      assert {:ok, report} = result
      assert report.status == :ok
      assert report.upserted == 1
      assert report.notification_replayed == 0
      assert report.notification_replay_failed == 1
      assert log =~ "sidecar notification ledger invalid"
    end

    test "retained notification ledger storage round-trips and prunes", %{topo: topo} do
      entry = %{
        "id" => Ecto.UUID.generate(),
        "bucket" => @bucket,
        "key" => "k-retained-storage",
        "event_name" => "s3:ObjectCreated:Put",
        "operation" => "put_object",
        "payload" => %{"event_name" => "s3:ObjectCreated:Put"},
        "commit_predicate" => %{"type" => "version_present", "version_id" => "null"}
      }

      assert :ok =
               Storage.put_notification_ledgers(
                 @bucket,
                 "k-retained-storage",
                 [entry],
                 scan_opts(topo)
               )

      assert {:ok, [stored]} =
               Storage.list_notification_ledgers(@bucket, "k-retained-storage", scan_opts(topo))

      assert stored["id"] == entry["id"]
      assert stored["payload"]["event_name"] == "s3:ObjectCreated:Put"

      assert :ok =
               Storage.delete_notification_ledgers(
                 @bucket,
                 "k-retained-storage",
                 [entry["id"]],
                 scan_opts(topo)
               )

      assert {:ok, []} =
               Storage.list_notification_ledgers(@bucket, "k-retained-storage", scan_opts(topo))
    end

    test "scanner replays and prunes committed retained notification ledger", %{topo: topo} do
      key = "k-retained-replay"
      body = "retained body"
      etag = disk_put!(topo, key, "null", body)
      [%{"id" => outbox_id}] = retained_put_ledger!(topo, key, etag, body)

      assert {:ok, report} = Scanner.run_once(scan_opts(topo))
      assert report.notification_retained_scanned == 1
      assert report.notification_replayed == 1
      assert report.notification_retained_pruned == 1
      assert report.notification_retained_ambiguous == 0

      assert [%{id: ^outbox_id, event_name: "s3:ObjectCreated:Put", object_key: ^key}] =
               NotificationOutbox.list(status: "pending")

      assert {:ok, []} = Storage.list_notification_ledgers(@bucket, key, scan_opts(topo))
    end

    test "retained version-present predicate does not replay after null overwrite changes proof",
         %{
           topo: topo
         } do
      key = "k-retained-overwritten"
      body = "first body"
      etag = disk_put!(topo, key, "null", body)
      _retained = retained_put_ledger!(topo, key, etag, body)
      _new_etag = disk_put!(topo, key, "null", "second body")

      assert {:ok, report} = Scanner.run_once(scan_opts(topo))
      assert report.notification_retained_scanned == 1
      assert report.notification_replayed == 0
      assert report.notification_retained_pruned == 0
      assert report.notification_retained_ambiguous == 1
      assert NotificationOutbox.list(status: "pending") == []
    end

    test "retained RestoreObject predicate prunes aborted ledger when restore state did not commit",
         %{topo: topo} do
      key = "k-retained-restore-aborted"
      body = "restore candidate"
      etag = disk_put!(topo, key, "null", body)

      [%{"id" => outbox_id}] =
        retained_restore_ledger!(topo, key, etag, body, %{
          restore_status: "restored",
          restore_expiry: ~U[2026-07-01 00:00:00Z]
        })

      assert {:ok, report} = Scanner.run_once(scan_opts(topo))
      assert report.notification_retained_scanned == 1
      assert report.notification_retained_aborted == 1
      assert report.notification_retained_pruned == 1
      assert report.notification_replayed == 0
      assert report.notification_replay_failed == 0
      assert NotificationOutbox.list(status: "pending") == []
      assert {:ok, []} = Storage.list_notification_ledgers(@bucket, key, scan_opts(topo))
      assert_raise Ecto.NoResultsError, fn -> NotificationOutbox.get!(outbox_id) end
    end

    test "preflight recovery replays retained ledger before same-key overwrite", %{topo: topo} do
      key = "k-retained-preflight"
      body = "preflight body"
      etag = disk_put!(topo, key, "null", body)
      [%{"id" => outbox_id}] = retained_put_ledger!(topo, key, etag, body)

      assert :ok = NotificationRetainedLedger.recover_key!(@bucket, key, scan_opts(topo))
      assert [%{id: ^outbox_id, object_key: ^key}] = NotificationOutbox.list(status: "pending")
      assert {:ok, []} = Storage.list_notification_ledgers(@bucket, key, scan_opts(topo))

      _new_etag = disk_put!(topo, key, "null", "after preflight")

      assert {:ok, %{notification_retained_scanned: 0, notification_replayed: 0}} =
               Scanner.run_once(scan_opts(topo))
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
      assert row.content_encoding == "gzip"
      assert row.content_disposition == ~s(attachment; filename="scan.txt")
      assert row.cache_control == "max-age=120"
      assert row.expires == "Wed, 21 Oct 2037 07:28:00 GMT"
    end

    test "PG stale controlled system headers → scanner detects and reconciles", %{topo: topo} do
      etag = disk_put!(topo, "k-stale-system", "null", "system header bytes")

      {:ok, _} =
        Objects.put_version_with_id(@bucket, "k-stale-system", "null", %{
          size: byte_size("system header bytes"),
          etag: etag,
          content_type: "text/plain",
          content_encoding: "br",
          content_disposition: "inline",
          cache_control: "no-store",
          expires: "Thu, 01 Jan 1970 00:00:00 GMT",
          metadata: %{"a" => "1"},
          tags: %{"t" => "v"},
          storage_class: "STANDARD",
          acl_canned: "private"
        })

      assert {:ok, %{upserted: 1}} = Scanner.run_once(scan_opts(topo))

      {:ok, row} = Objects.get_version(@bucket, "k-stale-system", "null")
      assert row.content_encoding == "gzip"
      assert row.content_disposition == ~s(attachment; filename="scan.txt")
      assert row.cache_control == "max-age=120"
      assert row.expires == "Wed, 21 Oct 2037 07:28:00 GMT"
    end

    test "已同步行 → 幂等零写（第二轮 upserted=0）", %{topo: topo} do
      _ = disk_put!(topo, "k-sync", "null", "stable")

      assert {:ok, %{upserted: 1}} = Scanner.run_once(scan_opts(topo))

      assert {:ok, %{upserted: 0, gc: 0, skipped: 0, scanned: 1}} =
               Scanner.run_once(scan_opts(topo))
    end

    test "B5-3 R1：reconcile 后 updated_at 忠于 sidecar modtime（Last-Modified 绝不漂移到扫描时刻）",
         %{eps: eps, topo: topo} do
      _ = disk_put!(topo, "k-lastmod", "null", "last-modified fidelity")

      # 盘上真实写出的 entry modtime（int64 ns）= 对象写入时刻（Last-Modified 单一语义来源）。
      meta = read_disk_sidecar(eps, "k-lastmod", "null")
      [entry] = meta["versions"]
      {:ok, expected} = DateTime.from_unix(entry["modtime"], :nanosecond)

      Process.sleep(20)
      scan_started = DateTime.utc_now()
      assert {:ok, %{upserted: 1}} = Scanner.run_once(scan_opts(topo))

      {:ok, row} = Objects.get_version(@bucket, "k-lastmod", "null")

      # updated_at == 原 PUT 时刻（sidecar modtime），严格早于扫描时刻（旧缺陷：写成 now → 漂移）。
      assert DateTime.compare(row.updated_at, expected) == :eq
      assert DateTime.compare(row.updated_at, scan_started) == :lt
      # synced_at 是同步确认时刻（≥ 扫描开始），与 updated_at 语义分离。
      assert DateTime.compare(row.synced_at, scan_started) != :lt
    end

    test "B5-3 R1：stale 行 reconcile 后 updated_at 收敛回对象写入时刻（非行刷新时刻）", %{
      eps: eps,
      topo: topo
    } do
      _ = disk_put!(topo, "k-lm2", "null", "stale lastmod")
      meta = read_disk_sidecar(eps, "k-lm2", "null")
      [entry] = meta["versions"]
      {:ok, expected} = DateTime.from_unix(entry["modtime"], :nanosecond)

      # 漂移行：晚于对象写入时刻写入 PG（updated_at = 行刷新时刻 > modtime）。
      Process.sleep(20)

      {:ok, _} =
        Objects.put_version_with_id(@bucket, "k-lm2", "null", %{size: 999, etag: "\"d\""})

      {:ok, pre} = Objects.get_version(@bucket, "k-lm2", "null")
      assert DateTime.compare(pre.updated_at, expected) == :gt

      assert {:ok, %{upserted: 1}} = Scanner.run_once(scan_opts(topo))

      {:ok, row} = Objects.get_version(@bucket, "k-lm2", "null")
      assert DateTime.compare(row.updated_at, expected) == :eq
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
      assert report.skipped == 2
      assert log =~ "endpoint unreachable, skipping reverse-GC"

      assert {:ok, _row} = Objects.get_version(@bucket, "k-ghost2", vid)
    end

    test "orphan-shard evidence marks an unavailable endpoint as skipped", %{eps: eps, topo: topo} do
      {node0, _} = hd(eps)
      InProcess.set_down(node0)

      assert {:ok, report} = Scanner.run_once(scan_opts(topo))
      assert report.skipped == 1
      assert report.orphan_shards == 0
      assert report.orphan_bytes == 0
    end

    test "盘上有版本（forward 已见）绝不被 reverse-GC", %{topo: topo} do
      _ = disk_put!(topo, "k-live", "null", "live")

      assert {:ok, %{gc: 0}} = Scanner.run_once(scan_opts(topo))
      assert {:ok, _} = Objects.get_version(@bucket, "k-live", "null")
    end
  end

  describe "orphan shard report-only evidence" do
    test "part.0 without meta.json is reported but never deleted", %{eps: eps, topo: topo} do
      key = "k-part-without-meta"
      body = "orphan shard bytes"
      {node, drive} = hd(eps)
      {dir, part} = write_orphan_part!(drive, key, "null", body)

      {result, log} = with_log(fn -> Scanner.run_once(scan_opts(topo)) end)

      assert {:ok, report} = result
      assert report.status == :ok
      assert report.orphan_shards == 1
      assert report.orphan_bytes == byte_size(body)
      assert log =~ "orphan shard bytes detected"
      assert log =~ "reason=part_without_meta"
      assert log =~ "node=#{node}"
      assert File.dir?(dir)
      assert File.read!(part) == body
      assert {:error, :not_found} = Objects.get_version(@bucket, key, "null")
    end

    test "delete-marker version with residual part.0 is reported but never deleted", %{
      eps: eps,
      topo: topo
    } do
      key = "k-delete-marker-residual-part"
      vid = VersionId.generate()

      :ok =
        Storage.put_delete_marker(@bucket, key, vid, [],
          transport: InProcess,
          topology: topo
        )

      {_node, drive} = hd(eps)
      {:ok, rel} = Maxio.Cluster.Paths.object_rel(@bucket, key, vid)
      dir = Path.join(drive, rel)
      File.write!(Path.join(dir, "part.0"), "stale")

      {result, log} = with_log(fn -> Scanner.run_once(scan_opts(topo)) end)

      assert {:ok, report} = result
      assert report.upserted == 1
      assert report.orphan_shards == 1
      assert report.orphan_bytes == byte_size("stale")
      assert log =~ "reason=delete_marker_part"
      assert File.read!(Path.join(dir, "part.0")) == "stale"

      {:ok, row} = Objects.get_version(@bucket, key, vid)
      assert row.is_delete_marker == true
    end
  end

  describe "orphan shard cleanup safety gates" do
    test "dry-run cleanup reports would-clean and leaves part.0 in place", %{eps: eps, topo: topo} do
      key = "k-cleanup-dry-run"
      body = "dry-run orphan bytes"
      {_node, drive} = hd(eps)
      {_dir, part} = write_orphan_part!(drive, key, "null", body)

      {result, log} =
        with_info_log(fn ->
          Scanner.run_once(
            scan_opts(topo,
              orphan_cleanup: :dry_run,
              orphan_cleanup_min_age_ms: 0
            )
          )
        end)

      assert {:ok, report} = result
      assert report.orphan_shards == 1
      assert report.orphan_bytes == byte_size(body)
      assert report.orphan_cleaned == 1
      assert report.orphan_cleaned_bytes == byte_size(body)
      assert log =~ "would clean orphan shard part.0"
      assert File.read!(part) == body
    end

    test "explicit cleanup deletes only part.0 for part-without-meta candidates", %{
      eps: eps,
      topo: topo
    } do
      key = "k-cleanup-delete"
      {_node, drive} = hd(eps)
      {dir, part} = write_orphan_part!(drive, key, "null", "delete orphan")

      {result, log} =
        with_info_log(fn ->
          Scanner.run_once(
            scan_opts(topo,
              cleanup_orphan_shards: true,
              orphan_cleanup_min_age_ms: 0
            )
          )
        end)

      assert {:ok, report} = result
      assert report.orphan_cleaned == 1
      assert report.orphan_cleaned_bytes == byte_size("delete orphan")
      assert log =~ "cleaned orphan shard part.0"
      refute File.exists?(part)
      assert File.dir?(dir)
      refute File.exists?(Path.join(dir, "meta.json"))
    end

    test "cleanup removes residual part.0 from delete-marker version and preserves meta.json", %{
      eps: eps,
      topo: topo
    } do
      key = "k-cleanup-delete-marker"
      vid = VersionId.generate()

      :ok =
        Storage.put_delete_marker(@bucket, key, vid, [],
          transport: InProcess,
          topology: topo
        )

      {_node, drive} = hd(eps)
      {:ok, rel} = Maxio.Cluster.Paths.object_rel(@bucket, key, vid)
      dir = Path.join(drive, rel)
      meta = Path.join(dir, "meta.json")
      part = Path.join(dir, "part.0")
      File.write!(part, "marker residual")

      assert File.exists?(meta)

      assert {:ok, report} =
               Scanner.run_once(
                 scan_opts(topo,
                   cleanup_orphan_shards: true,
                   orphan_cleanup_min_age_ms: 0
                 )
               )

      assert report.upserted == 1
      assert report.orphan_shards == 1
      assert report.orphan_cleaned == 1
      refute File.exists?(part)
      assert File.exists?(meta)

      {:ok, row} = Objects.get_version(@bucket, key, vid)
      assert row.is_delete_marker == true
    end

    test "cleanup defers shards younger than the configured age gate", %{eps: eps, topo: topo} do
      key = "k-cleanup-young"
      {_node, drive} = hd(eps)
      {_dir, part} = write_orphan_part!(drive, key, "null", "young orphan")

      {result, log} =
        with_info_log(fn ->
          Scanner.run_once(
            scan_opts(topo,
              cleanup_orphan_shards: true,
              orphan_cleanup_min_age_ms: 60_000
            )
          )
        end)

      assert {:ok, report} = result
      assert report.orphan_shards == 1
      assert report.orphan_cleaned == 0
      assert log =~ "cleanup deferred because part.0 is too new"
      assert File.exists?(part)
    end

    test "cleanup downgrades to report-only when any endpoint is unreachable", %{
      eps: eps,
      topo: topo
    } do
      [{down_node, _down_drive}, {_live_node, live_drive} | _] = eps
      InProcess.set_down(down_node)
      {_dir, part} = write_orphan_part!(live_drive, "k-cleanup-down", "null", "down orphan")

      {result, log} =
        with_log(fn ->
          Scanner.run_once(
            scan_opts(topo,
              cleanup_orphan_shards: true,
              orphan_cleanup_min_age_ms: 0
            )
          )
        end)

      assert {:ok, report} = result
      assert report.orphan_shards == 1
      assert report.orphan_cleaned == 0
      assert report.skipped == 1
      assert log =~ "cleanup disabled because at least one endpoint is unreachable"
      assert File.exists?(part)
    end

    test "part-without-meta cleanup skips when a PG row still exists", %{eps: eps, topo: topo} do
      key = "k-cleanup-pg-row"
      {_node, drive} = hd(eps)
      {_dir, part} = write_orphan_part!(drive, key, "null", "pg row orphan")

      {:ok, _row} =
        Objects.put_version_with_id(@bucket, key, "null", %{
          size: byte_size("pg row orphan"),
          etag: "\"pg-row\""
        })

      assert {:ok, report} =
               Scanner.run_once(
                 scan_opts(topo,
                   dry_run: true,
                   cleanup_orphan_shards: true,
                   orphan_cleanup_min_age_ms: 0
                 )
               )

      assert report.gc == 1
      assert report.orphan_shards == 1
      assert report.orphan_cleaned == 0
      assert File.exists?(part)
      assert {:ok, _row} = Objects.get_version(@bucket, key, "null")
    end

    test "cleanup max delete budget is enforced across the whole scanner run", %{
      eps: eps,
      topo: topo
    } do
      other_bucket = "b52cleanupother"
      {:ok, _bucket} = Buckets.create(other_bucket, @owner)
      {_node, drive} = hd(eps)

      {_dir_a, part_a} = write_orphan_part!(drive, @bucket, "k-budget-a", "null", "budget-a")

      {_dir_b, part_b} =
        write_orphan_part!(drive, other_bucket, "k-budget-b", "null", "budget-b")

      opts =
        scan_opts(topo,
          bucket: nil,
          cleanup_orphan_shards: true,
          orphan_cleanup_min_age_ms: 0,
          orphan_cleanup_max_deletes: 1
        )

      assert {:ok, report} = Scanner.run_once(opts)

      assert report.buckets == 2
      assert report.orphan_shards == 2
      assert report.orphan_cleaned == 1
      assert Enum.count([part_a, part_b], &(not File.exists?(&1))) == 1
      assert Enum.count([part_a, part_b], &File.exists?/1) == 1
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

  describe "默认配置 / 无拓扑（非 FS no-op；FS local topology 可 reconcile）" do
    test "scanner 默认 disabled：config 默认值 + GenServer 启动但不调度" do
      cfg = Application.get_env(:maxio, :scanner)
      assert Keyword.get(cfg, :enabled) == false
      assert Keyword.get(cfg, :interval_ms) == 86_400_000
      assert Keyword.get(cfg, :batch_size) == 500

      pid = Process.whereis(Maxio.Storage.Scanner)
      assert is_pid(pid)
      assert :sys.get_state(pid) == %{enabled: false}
    end

    test "非 FS 后端无拓扑 → run_once 安全 no-op（status: :no_topology 零计数）" do
      # setup 已把 backend 切到 Distributed；写权威闸在拓扑检查之前——注入 :sidecar 写权威
      # 以抵达拓扑分支（闸见下个 describe）。
      {result, log} =
        with_log(fn -> Scanner.run_once(authoritative_source: [write: :sidecar]) end)

      assert {:ok, report} = result
      assert report.status == :no_topology
      assert report.scanned == 0
      assert report.upserted == 0
      assert report.gc == 0
      assert log =~ "no distributed topology"
    end

    test "FS 后端无全局拓扑 → 注入 local_topology 后可 upsert 缺行并 GC 孤儿行", %{
      eps: eps
    } do
      Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end)

      dir = Path.join(System.tmp_dir!(), "b52_fs_local_#{System.unique_integer([:positive])}")
      File.rm_rf(dir)
      File.mkdir_p!(dir)

      prev_backend = Application.get_env(:maxio, :storage_backend)
      prev_s3 = Application.get_env(:maxio, :s3)
      topo_key = {Maxio.Cluster.Topology, :topology}
      prev_topo = :persistent_term.get(topo_key, :__maxio_no_topology__)

      Application.put_env(:maxio, :storage_backend, Maxio.Storage.FS)
      Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, dir))
      :persistent_term.erase(topo_key)

      on_exit(fn ->
        Application.put_env(:maxio, :storage_backend, prev_backend)
        Application.put_env(:maxio, :s3, prev_s3)
        restore_topology(prev_topo)
        File.rm_rf(dir)
      end)

      assert Maxio.ObjectMeta.effective_topology(data_dir: dir) ==
               Maxio.Storage.FS.local_topology(data_dir: dir)

      :ok = Maxio.Storage.FS.put_bucket(@bucket, data_dir: dir)
      fs_etag = fs_put_missing_row!(dir, "fs-missing", "fs local sidecar")

      {:ok, _orphan} =
        Objects.put_version_with_id(@bucket, "fs-orphan", "null", %{
          size: 1,
          etag: "\"ghost\""
        })

      assert {:error, :not_found} = Objects.get_version(@bucket, "fs-missing", "null")
      assert {:ok, _} = Objects.get_version(@bucket, "fs-orphan", "null")

      {result, log} =
        with_info_log(fn ->
          Scanner.run_once(
            bucket: @bucket,
            data_dir: dir,
            authoritative_source: [write: :sidecar]
          )
        end)

      assert {:ok, report} = result
      assert report.status == :ok
      assert report.buckets == 1
      assert report.scanned == 1
      assert report.upserted == 1
      assert report.gc == 1
      assert report.divergent == 0
      assert log =~ "reconciled from sidecar authority"

      assert {:ok, row} = Objects.get_version(@bucket, "fs-missing", "null")
      assert row.etag == fs_etag
      assert row.size == byte_size("fs local sidecar")
      assert {:error, :not_found} = Objects.get_version(@bucket, "fs-orphan", "null")
    end
  end

  describe "写权威闸（authoritative_source(:write) != :sidecar → 拒绝，仅 force 越闸）" do
    test "默认 :pg 写权威 → 拒绝（status: :authority_mismatch 零计数零写入，绝不复活/GC）", %{
      topo: topo
    } do
      # 盘上有 PG 缺（forward 会 upsert 的素材）+ PG 孤儿行（reverse-GC 会删的素材）——
      # 闸生效 = 两者都分毫未动。
      _ = disk_put!(topo, "k-gate-disk", "null", "disk only")
      vid = VersionId.generate()

      {:ok, _} =
        Objects.put_version_with_id(@bucket, "k-gate-ghost", vid, %{size: 1, etag: "\"g\""})

      {result, log} =
        with_log(fn ->
          Scanner.run_once(transport: InProcess, topology: topo, bucket: @bucket)
        end)

      assert {:ok, report} = result
      assert report.status == :authority_mismatch
      assert report.buckets == 0
      assert report.scanned == 0
      assert report.upserted == 0
      assert report.gc == 0
      assert log =~ "scanner refused"
      assert log =~ "authoritative_source(:write) != :sidecar"

      # 拒绝 = 不写：PG 缺行仍缺（不复活）、孤儿行仍在（不 GC 权威行）。
      assert {:error, :not_found} = Objects.get_version(@bucket, "k-gate-disk", "null")
      assert {:ok, _} = Objects.get_version(@bucket, "k-gate-ghost", vid)
    end

    test ":pg 写权威 + dry_run 同样拒绝（would-计数基于错误的盘权威假设，纯误导）", %{topo: topo} do
      _ = disk_put!(topo, "k-gate-dr", "null", "disk only dr")

      {result, _log} =
        with_log(fn ->
          Scanner.run_once(transport: InProcess, topology: topo, bucket: @bucket, dry_run: true)
        end)

      assert {:ok, report} = result
      assert report.status == :authority_mismatch
      assert report.dry_run == true
      assert report.scanned == 0
      assert report.upserted == 0
    end

    test ":pg 写权威 + force: true → 显式越闸执行（status: :ok）", %{topo: topo} do
      _ = disk_put!(topo, "k-gate-force", "null", "forced")

      assert {:ok, report} =
               Scanner.run_once(
                 transport: InProcess,
                 topology: topo,
                 bucket: @bucket,
                 force: true
               )

      assert report.status == :ok
      assert report.upserted == 1
      assert {:ok, _} = Objects.get_version(@bucket, "k-gate-force", "null")
    end
  end

  defp fs_put_missing_row!(dir, key, body) do
    om = %{
      content_type: "text/plain",
      tags: %{"route" => "b6-2"},
      sse: nil,
      acl_canned: "private",
      storage_class: "STANDARD",
      user_metadata: %{"source" => "fs-local"}
    }

    {:ok, %{etag: etag}} =
      Maxio.Storage.FS.put(@bucket, key, "null", [body],
        data_dir: dir,
        object_meta: om
      )

    etag
  end

  defp write_orphan_part!(drive, key, version_id, body),
    do: write_orphan_part!(drive, @bucket, key, version_id, body)

  defp write_orphan_part!(drive, bucket, key, version_id, body) do
    {:ok, rel} = Maxio.Cluster.Paths.object_rel(bucket, key, version_id)
    dir = Path.join(drive, rel)
    File.mkdir_p!(dir)
    part = Path.join(dir, "part.0")
    File.write!(part, body)
    {dir, part}
  end

  defp restore_topology(:__maxio_no_topology__),
    do: :persistent_term.erase({Maxio.Cluster.Topology, :topology})

  defp restore_topology(topo),
    do: :persistent_term.put({Maxio.Cluster.Topology, :topology}, topo)
end
