defmodule Maxio.Storage.Scanner do
  @moduledoc """
  ROUTE B B5-2 —— 派生索引周期 reconcile scanner（盘上 sidecar 权威 → PG 派生索引收敛）
  + 保守 reverse-GC 孤儿行。

  PG 自 B4-2/B5-1 起在 `authoritative_source(:write)=:sidecar` 下降为 best-effort 派生索引：
  PG 写失败请求仍成功（盘上 sidecar 已达 write_quorum = 权威已耐久），漂移留待本 scanner 收敛。
  每轮（`run_once/1`，GenServer 周期触发与 `mix maxio.reconcile_index` 共用同一实现）：

    1. **forward reconcile（盘 → PG）**：遍历 buckets（PG）→ 每桶经 `Maxio.Listing.scan_keys/2`
       走盘原语枚举对象 key（null 布局 ∪ 版本树，含 delete-marker key，不做枚举层 quorum 门）、
       按 batch_size 分批 → 每 key 经 `Maxio.Listing.version_ids/3` 枚举全部版本 → 每版本读全 N
       端点 sidecar 经 `Maxio.MetaReconcile.reconcile/3` quorum 仲裁出 canonical entry：
         * PG 行缺失或 `Maxio.Objects.stale?/2` → `Maxio.Objects.reconcile_from_sidecar/3` upsert
           + 结构化日志（action: :reconcile_index）；
         * quorum 不足/分歧 → 计 divergent + 日志，**绝不写**（铁律 3 绝不在分歧中挑一个）。
       **is_latest 跨版本收敛**：方案 B 每版本独立 sidecar，entry 的 is_latest 是**写时缓存**
       （旧版本 sidecar 不会因新版本写入而更新，跨版本可能多个 true）。scanner 以
       `Maxio.Listing.current_version/4`（与读权威 `discover_current_version` 同一语义源；
       写时间序——null 与 ULID 并存比 sidecar modtime，晚写的 null marker/版本胜出，对齐 MinIO
       sortByModTime / AWS suspended-bucket delete marker 语义）跨版本判定当前版本，按其覆盖
       entry is_latest 后再比对/upsert——PG 的 latest 标记向「盘上版本集整体」收敛，与处理顺序无关。
    2. **reverse-GC（PG → 盘）**：每桶 keyset 分页（batch_size）扫 PG 行，forward 未在盘上见过的
       行逐端点经 `list_dir` 探针确认：**仅当所有端点全部可达且全部显式 missing**（版本目录无
       meta.json——meta.json 即版本记录本体，对齐 MinIO xl.meta）→ 删该 PG 行 + 日志
       （action: :reverse_gc）；任一端点 down/异常 → skip + 日志，**绝不猜**（铁律 3）。
       探针必须用 `list_dir`（宕机 → `{:error, :unavailable}`，结构性区分「不可达」与「可达但
       不存在 `{:ok, entries}`」）——`get_sidecar` 把宕机塌缩成 `:enoent`，对 GC 判定不可用。

  每轮汇总日志：scanned（forward 检视的盘上版本数）/ upserted / gc / skipped（端点不可达跳过 +
  写失败留待下轮）/ divergent（quorum 仲裁失败）/ orphan_shards / orphan_bytes / orphan_cleaned /
  orphan_cleaned_bytes。orphan shard 默认只做取证：盘上 `part.0` 缺 sidecar，或 delete-marker
  版本目录残留 `part.0`，均计数并日志；显式开启清理时仍须满足 age/quorum/authority/lock 安全门，
  且只删除 `part.0`，绝不删除目录或 `meta.json`。`--dry-run` 只报告（would-计数）**绝不写**。

  与在线写路径的竞态（无锁，文档化）：写路径盘先 PG 后——scanner 在两步之间看到「盘有 PG 缺」会
  提前 upsert（与随后的写路径 upsert 同 (bucket,key,version_id) 冲突替换，幂等收敛）；反向探针在
  「盘上确有」时绝不删（present → skip），删除竞态由「全端点显式 missing」前置条件 + 删后下一轮
  forward 再收敛兜底。scanner 是**收敛器**而非事务参与者，所有动作幂等。

  **写权威前置条件（安全闸，强制）**：reconcile 的方向是「盘 → PG」，只在
  `authoritative_source(:write)=:sidecar` 下成立。默认 `:pg` 权威下 PG 才是事实来源，而
  PG-only delete marker（B5-0 之前的全部存量 marker；`:pg` 模式下 best-effort
  `Storage.put_delete_marker` 失败的 marker）盘上**没有** sidecar——跑一轮会让 forward 把被
  marker 遮蔽的旧版本重新提成 is_latest=true（已删对象在 PG 权威 GET/LIST 下复活 = B5-0 修的
  critical 原样重现），reverse-GC 会把权威 marker 行当孤儿删掉。故 `run_once`（周期轮、
  `mix maxio.reconcile_index`、**含 --dry-run**——其 would-计数同样基于错误的盘权威假设，纯误导）
  在写权威非 `:sidecar` 时一律拒绝（status: :authority_mismatch 零计数 + Log.warn），仅显式
  `opts[:force]`（CLI `--force`）越闸。

  默认 `config :maxio, :scanner, enabled: false`：GenServer 启动但不调度（显式日志声明），
  行为零变更；interval_ms 默认 86_400_000（每日一轮），batch_size 默认 500（铁律 4 有界批量）。
  无分布式拓扑且非 FS 后端时 `run_once` 安全 no-op（status: :no_topology + 日志，绝不
  raise——盘上枚举需要拓扑端点）。ROUTE B B6-2：FS 后端无全局拓扑时 `run_once` 入口经
  `Maxio.ObjectMeta.put_effective_topology/1` 注入**合成单端点 topology**
  （`{Node.self(), data_dir}`，quorum=1）——FS 单机的派生索引 reconcile 全机器逐字复用。
  """
  use GenServer

  import Ecto.Query

  alias Maxio.{Buckets, Listing, Lock, MetaReconcile, ObjectMeta, Objects, Repo}
  alias Maxio.Cluster.{DriveHealth, Paths, Router, Topology, Transport}
  alias Maxio.Objects.Object
  alias Maxio.S3.{Log, NotificationDelivery, NotificationRetainedLedger}
  alias Maxio.Storage.Erasure.Config

  @count_keys [
    :scanned,
    :upserted,
    :gc,
    :skipped,
    :divergent,
    :notification_replayed,
    :notification_replay_failed,
    :notification_retained_scanned,
    :notification_retained_pruned,
    :notification_retained_aborted,
    :notification_retained_ambiguous,
    :orphan_shards,
    :orphan_bytes,
    :orphan_cleaned,
    :orphan_cleaned_bytes
  ]

  @type report :: %{
          status: :ok | :no_topology | :authority_mismatch,
          dry_run: boolean(),
          buckets: non_neg_integer(),
          scanned: non_neg_integer(),
          upserted: non_neg_integer(),
          gc: non_neg_integer(),
          skipped: non_neg_integer(),
          divergent: non_neg_integer(),
          notification_replayed: non_neg_integer(),
          notification_replay_failed: non_neg_integer(),
          notification_retained_scanned: non_neg_integer(),
          notification_retained_pruned: non_neg_integer(),
          notification_retained_aborted: non_neg_integer(),
          notification_retained_ambiguous: non_neg_integer(),
          orphan_shards: non_neg_integer(),
          orphan_bytes: non_neg_integer(),
          orphan_cleaned: non_neg_integer(),
          orphan_cleaned_bytes: non_neg_integer()
        }

  # ── GenServer（周期调度；enabled: false 时启动但不调度，显式日志声明状态）──

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    cfg = config()

    if cfg[:enabled] do
      Log.info(
        "scanner enabled: periodic derived-index reconcile scheduled " <>
          "(interval_ms=#{cfg[:interval_ms]} batch_size=#{cfg[:batch_size]})",
        action: :reconcile_index
      )

      schedule(cfg[:interval_ms])
      {:ok, %{enabled: true, interval_ms: cfg[:interval_ms]}}
    else
      Log.info(
        "scanner disabled: periodic derived-index reconcile NOT scheduled " <>
          "(enable via config :maxio, :scanner, enabled: true)",
        action: :reconcile_index
      )

      {:ok, %{enabled: false}}
    end
  end

  @impl true
  def handle_info(:scan, %{enabled: true, interval_ms: interval} = state) do
    safe_run()
    schedule(interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(interval_ms), do: Process.send_after(self(), :scan, interval_ms)

  # 周期轮的异常自吞 + Log.error（后台收敛器绝不让 supervisor 反复重启拖垮系统；铁律 3 不静默）。
  defp safe_run do
    _ = run_once([])
    :ok
  rescue
    e -> Log.error("scanner round crashed", action: :reconcile_index, reason: inspect(e))
  catch
    kind, reason ->
      Log.error("scanner round caught",
        action: :reconcile_index,
        reason: inspect({kind, reason})
      )
  end

  # ── 一轮 reconcile（mix maxio.reconcile_index / 测试 / 周期轮共用同一实现）──

  @doc """
  跑一轮派生索引 reconcile + reverse-GC。opts：

    * `:dry_run`（默认 false）——只报告（would-计数）绝不写 PG；
    * `:bucket`——仅扫指定桶（nil = 全部 PG buckets）；
    * `:batch_size`——覆盖 config 批量（默认 `config :maxio, :scanner` 的 batch_size）；
    * `:force`（默认 false）——`authoritative_source(:write) != :sidecar` 时本函数一律拒绝
      （status: :authority_mismatch 零计数，**含 dry-run**）；force: true 显式越闸，仅当你明确
      接受「以盘为权威重写 PG 索引」的后果（PG-only delete marker 会被复活 + 被 reverse-GC）；
    * `:cleanup_orphan_shards`（默认 false）——显式清理 orphan evidence 中满足安全门的 `part.0`；
      仅删除 `part.0` 文件，绝不删除目录或 `meta.json`。`dry_run: true` 时只计 would-clean；
    * `:orphan_cleanup_min_age_ms`——orphan `part.0` 最小年龄，默认来自 scanner config；
    * `:transport` / `:topology` / `:authoritative_source`——test 注入（与读/列路径同款依赖注入）。

  返回 `{:ok, report}`（见 `t:report/0`）。写权威非 :sidecar 且未 force → status:
  :authority_mismatch 零计数（拒绝）；无分布式拓扑 → status: :no_topology 零计数（安全 no-op）。
  """
  @spec run_once(keyword()) :: {:ok, report()}
  def run_once(opts \\ []) do
    # ROUTE B B6-2：入口处一次性解析有效 topology（与读/列权威同一 helper）——FS 后端无全局
    # 拓扑时注入合成单端点 {Node.self(), data_dir}（quorum=1，单盘确认即权威），下游
    # 枚举（Listing.scan_keys/version_ids）、endpoints_for、read_quorum、reverse-GC 探针
    # 全经既有 opts[:topology] 优先逻辑消费。真集群拓扑 / 显式注入 → 行为不变。
    opts = ObjectMeta.put_effective_topology(opts)
    dry_run = Keyword.get(opts, :dry_run, false)
    batch_size = Keyword.get(opts, :batch_size, config()[:batch_size])

    cond do
      not authority_allows_run?(opts) ->
        Log.warn(
          "scanner refused: authoritative_source(:write) != :sidecar — disk sidecars are not " <>
            "the write authority, so disk-driven reconcile would resurrect versions shadowed " <>
            "by PG-only delete markers and reverse-GC authoritative PG rows (the exact B5-0 " <>
            "critical); pass --force / opts[:force] only if you explicitly accept disk as " <>
            "the authority",
          action: :reconcile_index
        )

        {:ok, zero_report(dry_run, :authority_mismatch)}

      not topology_available?(opts) ->
        Log.warn(
          "scanner skipped: no distributed topology configured (drive-walk reconcile requires " <>
            "Maxio.Cluster.Topology or opts[:topology]); derived-index reconcile is a no-op",
          action: :reconcile_index
        )

        {:ok, zero_report(dry_run, :no_topology)}

      true ->
        buckets = bucket_names(Keyword.get(opts, :bucket))

        report =
          buckets
          |> Enum.reduce(zero_report(dry_run, :ok), fn bucket, acc ->
            bucket_opts = Keyword.put(opts, :orphan_cleanup_used, acc.orphan_cleaned)
            merge_counts(acc, scan_bucket(bucket, batch_size, dry_run, bucket_opts))
          end)
          |> Map.put(:buckets, length(buckets))

        Log.info(
          "scanner round complete: buckets=#{report.buckets} scanned=#{report.scanned} " <>
            "upserted=#{report.upserted} gc=#{report.gc} skipped=#{report.skipped} " <>
            "divergent=#{report.divergent} notification_replayed=#{report.notification_replayed} " <>
            "notification_replay_failed=#{report.notification_replay_failed} " <>
            "notification_retained_scanned=#{report.notification_retained_scanned} " <>
            "notification_retained_pruned=#{report.notification_retained_pruned} " <>
            "notification_retained_aborted=#{report.notification_retained_aborted} " <>
            "notification_retained_ambiguous=#{report.notification_retained_ambiguous} " <>
            "orphan_shards=#{report.orphan_shards} " <>
            "orphan_bytes=#{report.orphan_bytes} orphan_cleaned=#{report.orphan_cleaned} " <>
            "orphan_cleaned_bytes=#{report.orphan_cleaned_bytes} dry_run=#{report.dry_run}",
          action: :reconcile_index
        )

        {:ok, report}
    end
  end

  # 写权威安全闸：scanner 的全部语义（forward 把 PG 向盘收敛、reverse-GC 把盘上不存在的 PG 行
  # 当孤儿删）都建立在「盘上 sidecar = 写权威」之上。authoritative_source(:write) != :sidecar
  # （默认 :pg）时 PG 才是权威：PG-only delete marker（B5-0 之前的存量 marker / :pg 模式下
  # best-effort 盘 marker 写失败）盘上没有 sidecar——forward 会复活被 marker 遮蔽的已删对象、
  # reverse-GC 会删掉权威 marker 行。故一律拒绝（含 dry-run：would-计数同样基于错误的权威假设，
  # 纯误导），除非显式 opts[:force]。opts[:authoritative_source] 与 ObjectMeta 同款 test 注入。
  defp authority_allows_run?(opts) do
    Keyword.get(opts, :force, false) == true or
      ObjectMeta.authoritative_source(:write, opts) == :sidecar
  end

  # opts[:topology]（test 注入 / B6-2 run_once 入口注入的 FS 合成单端点）优先；
  # 否则须有真集群拓扑。FS 后端经入口的 put_effective_topology 已注入合成拓扑，
  # 故 no_topology 仅余「非 FS 后端且无集群拓扑」一种形态。
  defp topology_available?(opts) do
    Keyword.get(opts, :topology) != nil or Topology.configured?()
  end

  defp bucket_names(nil), do: Buckets.list() |> Enum.map(& &1.name)

  defp bucket_names(filter),
    do: Buckets.list() |> Enum.map(& &1.name) |> Enum.filter(&(&1 == filter))

  # 单桶一轮：forward（盘 → PG）+ reverse-GC（PG → 盘）。单桶异常绝不炸整轮（记日志计零续下桶）。
  defp scan_bucket(bucket, batch_size, dry_run, opts) do
    retained_counts = retained_notification_pass(bucket, dry_run, opts)
    {forward_counts, seen} = forward_pass(bucket, batch_size, dry_run, opts)
    reverse_counts = reverse_pass(bucket, batch_size, dry_run, seen, opts)
    orphan_counts = orphan_shard_pass(bucket, dry_run, opts)

    retained_counts
    |> merge_counts(forward_counts)
    |> merge_counts(reverse_counts)
    |> merge_counts(orphan_counts)
  rescue
    e ->
      Log.error("scanner bucket scan failed",
        bucket: bucket,
        action: :reconcile_index,
        reason: inspect(e)
      )

      zero_counts()
  catch
    kind, reason ->
      Log.error("scanner bucket scan caught",
        bucket: bucket,
        action: :reconcile_index,
        reason: inspect({kind, reason})
      )

      zero_counts()
  end

  defp retained_notification_pass(bucket, dry_run, opts) do
    summary = NotificationRetainedLedger.replay_bucket(bucket, dry_run, opts)

    zero_counts()
    |> Map.put(:notification_replayed, summary.replayed)
    |> Map.put(:notification_replay_failed, summary.failed)
    |> Map.put(:notification_retained_scanned, summary.scanned)
    |> Map.put(:notification_retained_pruned, summary.pruned)
    |> Map.put(:notification_retained_aborted, summary.aborted)
    |> Map.put(:notification_retained_ambiguous, summary.ambiguous)
  end

  # ── orphan shard 只读取证：盘上有 part.0 但缺可见 sidecar，或 delete-marker 版本残留 part.0 ──

  defp orphan_shard_pass(bucket, dry_run, opts) do
    transport = Transport.impl(opts)
    endpoints = all_endpoints(opts)
    cleanup = orphan_cleanup_config(bucket, dry_run, opts, transport, endpoints)

    endpoints
    |> Enum.reduce(zero_counts(), fn {node, drive}, counts ->
      walk_orphan_endpoint(counts, transport, node, drive, bucket, cleanup, opts)
    end)
  end

  defp walk_orphan_endpoint(counts, transport, node, drive, bucket, cleanup, opts) do
    bucket_root = Path.join(drive, bucket)

    # Full endpoint outage would otherwise be counted once per root. Probe the bucket root first so
    # one unavailable endpoint contributes one skipped evidence lane, then avoid the version root.
    case observe_drive_probe(
           node,
           drive,
           transport.list_dir(node, bucket_root, include_layout_files: true),
           opts
         ) do
      {:ok, _entries} ->
        counts
        |> walk_orphan_tree(transport, node, drive, bucket_root, [], :null, bucket, cleanup, opts)
        |> walk_orphan_tree(
          transport,
          node,
          drive,
          Path.join([drive, ".versions", bucket]),
          [],
          :versions,
          bucket,
          cleanup,
          opts
        )

      {:error, _reason} ->
        bump(counts, :skipped)
    end
  end

  defp walk_orphan_tree(
         counts,
         transport,
         node,
         drive,
         dir,
         rel_segments,
         layout,
         bucket,
         cleanup,
         opts
       ) do
    case observe_drive_probe(
           node,
           drive,
           transport.list_dir(node, dir, include_layout_files: true),
           opts
         ) do
      {:ok, entries} ->
        files = entries |> Enum.filter(&(entry_type(&1) == :file)) |> MapSet.new(& &1.name)
        dirs = Enum.filter(entries, &(entry_type(&1) == :dir))

        counts =
          maybe_count_orphan_shard(
            counts,
            transport,
            node,
            dir,
            bucket,
            layout,
            rel_segments,
            MapSet.member?(files, "part.0"),
            MapSet.member?(files, "meta.json"),
            cleanup
          )

        Enum.reduce(dirs, counts, fn entry, acc ->
          walk_orphan_tree(
            acc,
            transport,
            node,
            drive,
            Path.join(dir, entry.name),
            rel_segments ++ [entry.name],
            layout,
            bucket,
            cleanup,
            opts
          )
        end)

      {:error, _reason} ->
        bump(counts, :skipped)
    end
  end

  defp maybe_count_orphan_shard(
         counts,
         _transport,
         _node,
         _dir,
         _bucket,
         _layout,
         _rel,
         false,
         _meta?,
         _cleanup
       ),
       do: counts

  defp maybe_count_orphan_shard(
         counts,
         transport,
         node,
         dir,
         bucket,
         layout,
         rel,
         true,
         false,
         cleanup
       ) do
    record_orphan_shard(
      counts,
      transport,
      node,
      dir,
      bucket,
      layout,
      rel,
      :part_without_meta,
      cleanup
    )
  end

  defp maybe_count_orphan_shard(
         counts,
         transport,
         node,
         dir,
         bucket,
         layout,
         rel,
         true,
         true,
         cleanup
       ) do
    case safe_get_sidecar(transport, node, dir) do
      {:ok, meta} ->
        if delete_marker_meta?(meta) do
          record_orphan_shard(
            counts,
            transport,
            node,
            dir,
            bucket,
            layout,
            rel,
            :delete_marker_part,
            cleanup
          )
        else
          counts
        end

      {:error, _} ->
        bump(counts, :skipped)
    end
  end

  defp record_orphan_shard(counts, transport, node, dir, bucket, layout, rel, reason, cleanup) do
    {key, version_id} = orphan_ref(layout, rel)
    info = shard_info(transport, node, dir)
    bytes = info.size

    Log.warn("scanner: orphan shard bytes detected",
      bucket: bucket,
      key: key,
      action: :orphan_shard,
      reason:
        "reason=#{reason} version_id=#{version_id} node=#{node} bytes=#{bytes} path_layout=#{layout}"
    )

    counts
    |> bump(:orphan_shards)
    |> Map.update!(:orphan_bytes, &(&1 + bytes))
    |> maybe_cleanup_orphan_shard(
      transport,
      node,
      dir,
      bucket,
      key,
      version_id,
      reason,
      info,
      cleanup
    )
  end

  defp orphan_cleanup_config(bucket, dry_run, opts, transport, endpoints) do
    mode = orphan_cleanup_mode(opts, dry_run)

    min_age_ms =
      non_negative_int(
        Keyword.get(opts, :orphan_cleanup_min_age_ms, config()[:orphan_cleanup_min_age_ms]),
        172_800_000
      )

    max_deletes =
      positive_int(
        Keyword.get(opts, :orphan_cleanup_max_deletes, config()[:orphan_cleanup_max_deletes]),
        100
      )

    write_authority? = ObjectMeta.authoritative_source(:write, opts) == :sidecar
    require_all? = Keyword.get(opts, :orphan_cleanup_require_all_endpoints, true)

    endpoints_reachable? =
      not require_all? or orphan_cleanup_endpoints_reachable?(transport, endpoints, bucket, opts)

    mode =
      cond do
        mode == :report_only ->
          :report_only

        not write_authority? ->
          Log.warn(
            "scanner: orphan shard cleanup disabled because write authority is not sidecar",
            bucket: bucket,
            action: :orphan_shard,
            reason: "force_does_not_enable_byte_cleanup"
          )

          :report_only

        not endpoints_reachable? ->
          Log.warn(
            "scanner: orphan shard cleanup disabled because at least one endpoint is unreachable",
            bucket: bucket,
            action: :orphan_shard,
            reason: "require_all_endpoints=true"
          )

          :report_only

        true ->
          mode
      end

    %{
      mode: mode,
      min_age_ms: min_age_ms,
      max_deletes: max_deletes,
      used: non_negative_int(Keyword.get(opts, :orphan_cleanup_used, 0), 0),
      opts: opts
    }
  end

  defp orphan_cleanup_mode(opts, dry_run) do
    mode =
      cond do
        Keyword.get(opts, :orphan_cleanup_dry_run, false) -> :dry_run
        Keyword.get(opts, :cleanup_orphan_shards, false) -> :delete
        true -> Keyword.get(opts, :orphan_cleanup, :report_only)
      end

    mode = if dry_run and mode == :delete, do: :dry_run, else: mode
    if mode in [:report_only, :dry_run, :delete], do: mode, else: :report_only
  end

  defp orphan_cleanup_endpoints_reachable?(transport, endpoints, bucket, opts) do
    Enum.all?(endpoints, fn {node, drive} ->
      match?(
        {:ok, _},
        observe_drive_probe(
          node,
          drive,
          transport.list_dir(node, Path.join(drive, bucket), include_layout_files: true),
          opts
        )
      )
    end)
  end

  defp maybe_cleanup_orphan_shard(
         counts,
         _transport,
         _node,
         _dir,
         _bucket,
         _key,
         _version_id,
         _reason,
         _info,
         %{mode: :report_only}
       ),
       do: counts

  defp maybe_cleanup_orphan_shard(
         counts,
         transport,
         node,
         dir,
         bucket,
         key,
         version_id,
         reason,
         info,
         cleanup
       ) do
    cond do
      cleanup.used + counts.orphan_cleaned >= cleanup.max_deletes ->
        counts

      not info.exists? ->
        bump(counts, :skipped)

      not shard_old_enough?(info, cleanup.min_age_ms) ->
        Log.info("scanner: orphan shard cleanup deferred because part.0 is too new",
          bucket: bucket,
          key: key,
          action: :orphan_shard,
          reason: "reason=#{reason} version_id=#{version_id} min_age_ms=#{cleanup.min_age_ms}"
        )

        counts

      true ->
        cleanup_orphan_under_lock(
          counts,
          transport,
          node,
          dir,
          bucket,
          key,
          version_id,
          reason,
          info,
          cleanup
        )
    end
  end

  defp cleanup_orphan_under_lock(
         counts,
         transport,
         node,
         dir,
         bucket,
         key,
         version_id,
         reason,
         info,
         cleanup
       ) do
    case Lock.with_object_lock({bucket, key}, fn ->
           cleanup_orphan_candidate(
             transport,
             node,
             dir,
             bucket,
             key,
             version_id,
             reason,
             info,
             cleanup
           )
         end) do
      {:ok, {:cleaned, bytes}} ->
        counts
        |> bump(:orphan_cleaned)
        |> Map.update!(:orphan_cleaned_bytes, &(&1 + bytes))

      {:ok, :skipped} ->
        counts

      {:error, :locked} ->
        Log.warn("scanner: orphan shard cleanup skipped because object lock is held",
          bucket: bucket,
          key: key,
          action: :orphan_shard,
          reason: "version_id=#{version_id}"
        )

        bump(counts, :skipped)
    end
  end

  defp cleanup_orphan_candidate(
         transport,
         node,
         dir,
         bucket,
         key,
         version_id,
         reason,
         info,
         cleanup
       ) do
    with true <-
           orphan_candidate_still_valid?(
             reason,
             transport,
             node,
             dir,
             bucket,
             key,
             version_id,
             cleanup.opts
           ),
         %{exists?: true} = fresh <- shard_info(transport, node, dir),
         true <- fresh.size == info.size and fresh.mtime_ms == info.mtime_ms do
      case cleanup.mode do
        :dry_run ->
          Log.info("scanner dry-run: would clean orphan shard part.0",
            bucket: bucket,
            key: key,
            action: :orphan_shard,
            reason: "reason=#{reason} version_id=#{version_id} bytes=#{info.size}"
          )

          {:cleaned, info.size}

        :delete ->
          case transport.delete_part_file(node, dir) do
            :ok ->
              Log.info("scanner: cleaned orphan shard part.0",
                bucket: bucket,
                key: key,
                action: :orphan_shard,
                reason: "reason=#{reason} version_id=#{version_id} bytes=#{info.size}"
              )

              {:cleaned, info.size}

            {:error, delete_reason} ->
              Log.warn("scanner: orphan shard cleanup failed",
                bucket: bucket,
                key: key,
                action: :orphan_shard,
                reason: "version_id=#{version_id} error=#{inspect(delete_reason)}"
              )

              :skipped
          end
      end
    else
      _ -> :skipped
    end
  end

  defp orphan_candidate_still_valid?(
         :delete_marker_part,
         transport,
         node,
         dir,
         bucket,
         key,
         version_id,
         opts
       ) do
    with {:ok, meta} <- safe_get_sidecar(transport, node, dir),
         true <- delete_marker_meta?(meta),
         {:ok, entry, _divergent} <-
           MetaReconcile.reconcile(
             read_endpoint_sidecars(bucket, key, version_id, opts),
             read_quorum(opts),
             {:version, version_id}
           ) do
      delete_marker_entry?(entry)
    else
      _ -> false
    end
  end

  defp orphan_candidate_still_valid?(
         :part_without_meta,
         transport,
         node,
         dir,
         bucket,
         key,
         version_id,
         opts
       ) do
    match?({:error, _}, safe_get_sidecar(transport, node, dir)) and
      probe_version(bucket, key, version_id, opts) == :all_missing and
      match?({:error, :not_found}, Objects.get_version(bucket, key, version_id))
  end

  defp orphan_candidate_still_valid?(
         _reason,
         _transport,
         _node,
         _dir,
         _bucket,
         _key,
         _version_id,
         _opts
       ),
       do: false

  defp delete_marker_entry?(entry) do
    Map.get(entry, "is_delete_marker", false) == true or Map.get(entry, "type") == "delete_marker"
  end

  defp shard_old_enough?(_info, min_age_ms) when min_age_ms <= 0, do: true
  defp shard_old_enough?(%{mtime_ms: nil}, _min_age_ms), do: false

  defp shard_old_enough?(%{mtime_ms: mtime_ms}, min_age_ms) do
    System.system_time(:millisecond) - mtime_ms >= min_age_ms
  end

  defp all_endpoints(opts) do
    case Keyword.get(opts, :topology) do
      nil ->
        Topology.all_set_ids()
        |> Enum.flat_map(&Topology.endpoints/1)
        |> Enum.uniq()

      topology ->
        topology
        |> Topology.all_set_ids_from()
        |> Enum.flat_map(&Topology.endpoints_from(topology, &1))
        |> Enum.uniq()
    end
  end

  defp entry_type(%{type: type}), do: type
  defp entry_type(_entry), do: :dir

  defp safe_get_sidecar(transport, node, dir) do
    transport.get_sidecar(node, dir)
  rescue
    _ -> {:error, :unreadable}
  catch
    _, _ -> {:error, :unreadable}
  end

  defp delete_marker_meta?(meta) do
    Map.get(meta, "is_delete_marker", false) == true or
      match?(%{"type" => "delete_marker"}, Maxio.Sidecar.latest(meta))
  end

  defp shard_info(transport, node, dir) do
    case transport.stat_shard_info(node, dir) do
      {:ok, %{size: size, mtime_ms: mtime_ms}} ->
        %{exists?: true, size: size, mtime_ms: mtime_ms}

      {:error, _} ->
        %{exists?: false, size: 0, mtime_ms: nil}
    end
  end

  defp orphan_ref(:null, []), do: {"<invalid-null-root>", "null"}
  defp orphan_ref(:null, rel), do: {Maxio.Cluster.Paths.decode_key(rel), "null"}

  defp orphan_ref(:versions, rel) do
    case Enum.split(rel, max(length(rel) - 1, 0)) do
      {[], _} ->
        {"<invalid-version-root>", "<unknown>"}

      {key_segs, [version_id]} ->
        {Maxio.Cluster.Paths.decode_key(key_segs), version_id}

      _ ->
        {"<invalid-version-root>", "<unknown>"}
    end
  end

  # ── forward reconcile：盘上枚举 → 逐版本 quorum 仲裁 → PG 缺行/stale 收敛 ──

  defp forward_pass(bucket, batch_size, dry_run, opts) do
    bucket
    |> Listing.scan_keys(opts)
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce({zero_counts(), MapSet.new()}, fn batch, acc ->
      Enum.reduce(batch, acc, fn key, inner ->
        reconcile_key(bucket, key, dry_run, opts, inner)
      end)
    end)
  end

  defp reconcile_key(bucket, key, dry_run, opts, {counts, seen}) do
    vids = Listing.version_ids(bucket, key, opts)

    # 当前版本跨版本判定（与读权威 discover_current_version 同一语义源，current_version/4 写时间序：
    # null 与 ULID 并存比 sidecar modtime，晚写的 null marker/版本胜出——绝不把正确的 PG marker
    # latest 翻回旧 ULID 版本）：entry 的 is_latest 是写时缓存（每版本独立 sidecar，跨版本可能
    # 多个 true），PG latest 必须向版本集整体收敛。
    current_vid = Listing.current_version(bucket, key, vids, opts)

    Enum.reduce(vids, {counts, seen}, fn vid, {c, s} ->
      c2 = reconcile_version(bucket, key, vid, vid == current_vid, dry_run, opts, c)
      {c2, MapSet.put(s, {key, vid})}
    end)
  end

  defp reconcile_version(bucket, key, vid, latest?, dry_run, opts, counts) do
    counts = bump(counts, :scanned)
    copies = read_endpoint_sidecars(bucket, key, vid, opts)

    case MetaReconcile.reconcile(copies, read_quorum(opts), {:version, vid}) do
      {:ok, entry, _divergent} ->
        entry = Map.put(entry, "is_latest", latest?)
        counts = replay_notification_ledger(bucket, key, vid, entry, dry_run, counts)

        case row_state(bucket, key, vid, entry) do
          :in_sync ->
            counts

          {:needs_reconcile, reason} ->
            apply_reconcile(bucket, key, vid, entry, reason, dry_run, counts)
        end

      {:error, :read_quorum} ->
        Log.warn(
          "scanner: sidecar quorum unmet for version, skipping reconcile (never guess)",
          bucket: bucket,
          key: key,
          action: :reconcile_index,
          reason: "version_id=#{vid}"
        )

        bump(counts, :divergent)
    end
  end

  defp row_state(bucket, key, vid, entry) do
    case Objects.get_version(bucket, key, vid) do
      {:error, :not_found} ->
        {:needs_reconcile, :missing_row}

      {:ok, row} ->
        if Objects.stale?(row, entry), do: {:needs_reconcile, :stale_row}, else: :in_sync
    end
  end

  defp apply_reconcile(bucket, key, vid, _entry, reason, true = _dry_run, counts) do
    Log.info(
      "scanner dry-run: would reconcile derived index row from sidecar authority",
      bucket: bucket,
      key: key,
      action: :reconcile_index,
      reason: "#{reason} version_id=#{vid} dry_run=true"
    )

    bump(counts, :upserted)
  end

  defp apply_reconcile(bucket, key, vid, entry, reason, false = _dry_run, counts) do
    case Objects.reconcile_from_sidecar(bucket, key, entry) do
      :ok ->
        Log.info(
          "scanner: derived index row reconciled from sidecar authority",
          bucket: bucket,
          key: key,
          action: :reconcile_index,
          reason: "#{reason} version_id=#{vid}"
        )

        bump(counts, :upserted)

      {:error, err} ->
        Log.error(
          "scanner: derived index reconcile failed (left for next round)",
          bucket: bucket,
          key: key,
          action: :reconcile_index,
          reason: inspect(err)
        )

        bump(counts, :skipped)
    end
  end

  defp replay_notification_ledger(bucket, key, vid, entry, true = _dry_run, counts) do
    ledger = notification_ledger(bucket, key, vid, entry)

    case ledger do
      [] ->
        counts

      :invalid ->
        bump(counts, :notification_replay_failed)

      ledger ->
        Log.info(
          "scanner dry-run: would replay sidecar notification ledger",
          bucket: bucket,
          key: key,
          action: :bucket_notification_delivery,
          reason: "version_id=#{vid} entries=#{length(ledger)} dry_run=true"
        )

        Map.update!(counts, :notification_replayed, &(&1 + length(ledger)))
    end
  end

  defp replay_notification_ledger(bucket, key, vid, entry, false = _dry_run, counts) do
    ledger = notification_ledger(bucket, key, vid, entry)

    case ledger do
      [] ->
        counts

      :invalid ->
        bump(counts, :notification_replay_failed)

      ledger ->
        try do
          _ = NotificationDelivery.replay_sidecar_ledger(ledger)

          Log.info(
            "scanner: sidecar notification ledger replayed",
            bucket: bucket,
            key: key,
            action: :bucket_notification_delivery,
            reason: "version_id=#{vid} entries=#{length(ledger)}"
          )

          Map.update!(counts, :notification_replayed, &(&1 + length(ledger)))
        rescue
          err ->
            Log.error(
              "scanner: sidecar notification ledger replay failed",
              bucket: bucket,
              key: key,
              action: :bucket_notification_delivery,
              reason: "version_id=#{vid} error=#{inspect(err)}"
            )

            Map.update!(counts, :notification_replay_failed, &(&1 + length(ledger)))
        end
    end
  end

  # ── reverse-GC：PG keyset 分页 → forward 未见过的行逐端点探针 → 全可达全 missing 才删 ──

  defp notification_ledger(_bucket, _key, _vid, %{"notification_outbox" => ledger})
       when is_list(ledger),
       do: ledger

  defp notification_ledger(_bucket, _key, _vid, %{"notification_outbox" => nil}), do: []

  defp notification_ledger(bucket, key, vid, %{"notification_outbox" => ledger}) do
    Log.error(
      "scanner: sidecar notification ledger invalid (left for operator repair)",
      bucket: bucket,
      key: key,
      action: :bucket_notification_delivery,
      reason: "version_id=#{vid} notification_outbox=#{inspect(ledger, limit: 10)}"
    )

    :invalid
  end

  defp notification_ledger(_bucket, _key, _vid, _entry), do: []

  defp reverse_pass(bucket, batch_size, dry_run, seen, opts) do
    do_reverse(bucket, nil, batch_size, dry_run, seen, opts, zero_counts())
  end

  defp do_reverse(bucket, cursor, batch_size, dry_run, seen, opts, counts) do
    rows = page_rows(bucket, cursor, batch_size)

    counts =
      Enum.reduce(rows, counts, fn row, c ->
        if MapSet.member?(seen, {row.key, row.version_id}),
          do: c,
          else: gc_candidate(bucket, row, dry_run, opts, c)
      end)

    if length(rows) < batch_size do
      counts
    else
      last = List.last(rows)
      do_reverse(bucket, {last.key, last.version_id}, batch_size, dry_run, seen, opts, counts)
    end
  end

  # keyset 分页（升序 (key, version_id) 严格大于游标，铁律 4 绝不 offset / 无界全量物化）。
  defp page_rows(bucket, cursor, batch_size) do
    base =
      from(o in Object,
        where: o.bucket_name == ^bucket,
        order_by: [asc: o.key, asc: o.version_id],
        limit: ^batch_size
      )

    query =
      case cursor do
        nil ->
          base

        {k, v} ->
          where(base, [o], o.key > ^k or (o.key == ^k and o.version_id > ^v))
      end

    Repo.all(query)
  end

  defp gc_candidate(bucket, row, dry_run, opts, counts) do
    case probe_version(bucket, row.key, row.version_id, opts) do
      :all_missing ->
        apply_gc(bucket, row, dry_run, counts)

      :unreachable ->
        Log.warn(
          "scanner: endpoint unreachable, skipping reverse-GC (never guess on partial visibility)",
          bucket: bucket,
          key: row.key,
          action: :reverse_gc,
          reason: "version_id=#{row.version_id}"
        )

        bump(counts, :skipped)

      :present ->
        # 走盘枚举与逐行探针之间的瞬时竞态（如并发新写）：盘上确有该版本 → 绝不删，下一轮 forward 收敛。
        Log.info(
          "scanner: version present on disk but missed by enumeration, skipping reverse-GC",
          bucket: bucket,
          key: row.key,
          action: :reverse_gc,
          reason: "version_id=#{row.version_id} present_on_disk"
        )

        bump(counts, :skipped)

      :unprobeable ->
        Log.warn(
          "scanner: cannot derive on-disk path for row, skipping reverse-GC",
          bucket: bucket,
          key: row.key,
          action: :reverse_gc,
          reason: "version_id=#{row.version_id} invalid_key"
        )

        bump(counts, :skipped)
    end
  end

  defp apply_gc(bucket, row, true = _dry_run, counts) do
    Log.info(
      "scanner dry-run: would reverse-GC orphan derived index row",
      bucket: bucket,
      key: row.key,
      action: :reverse_gc,
      reason: "version_id=#{row.version_id} dry_run=true"
    )

    bump(counts, :gc)
  end

  defp apply_gc(bucket, row, false = _dry_run, counts) do
    {deleted, _} = Repo.delete_all(from(o in Object, where: o.id == ^row.id))

    if deleted > 0 do
      Log.info(
        "scanner: reverse-GC orphan derived index row " <>
          "(all endpoints reachable, version explicitly missing on every one)",
        bucket: bucket,
        key: row.key,
        action: :reverse_gc,
        reason: "version_id=#{row.version_id}"
      )

      bump(counts, :gc)
    else
      # 行已被并发删除（DELETE 请求等）——幂等，无事可做。
      counts
    end
  end

  # 逐端点版本存在性探针。结论三态：
  #   * :all_missing —— 所有端点可达且全部显式无该版本（meta.json 即版本记录本体）→ 可 GC；
  #   * :unreachable —— 任一端点 down/异常（或无端点可证）→ 绝不猜，skip；
  #   * :present —— 任一可达端点上确有 → 绝不删。
  # 必须经 list_dir（宕机 {:error,:unavailable} 与「可达但不存在 {:ok, entries}」结构性可分）；
  # get_sidecar 把宕机塌缩成 :enoent，对 GC 判定不可用（铁律 3 绝不把不可达当不存在）。
  defp probe_version(bucket, key, vid, opts) do
    case Paths.object_rel(bucket, key, vid) do
      {:error, :invalid_key} ->
        :unprobeable

      {:ok, rel} ->
        transport = Transport.impl(opts)

        results =
          for {node, drive} <- endpoints_for(bucket, key, opts) do
            probe_endpoint(transport, node, drive, rel, opts)
          end

        cond do
          results == [] -> :unreachable
          Enum.any?(results, &(&1 == :unreachable)) -> :unreachable
          Enum.any?(results, &(&1 == :present)) -> :present
          true -> :all_missing
        end
    end
  end

  # 单端点探针：列版本目录的父目录，存在 = 有名为版本末段且含 meta.json（object?=true）的子目录。
  # 目录不存在 → {:ok, []}（可达、显式 missing）；端点宕机/异常 → {:error, _}（unreachable）。
  defp probe_endpoint(transport, node, drive, rel, opts) do
    dir = Path.join(drive, rel)
    parent = Path.dirname(dir)
    base = Path.basename(dir)

    case observe_drive_probe(node, drive, transport.list_dir(node, parent, []), opts) do
      {:ok, entries} ->
        if Enum.any?(entries, &(&1.name == base and &1.object?)), do: :present, else: :missing

      {:error, _} ->
        :unreachable
    end
  end

  defp observe_drive_probe(node, drive, result, opts) do
    _ =
      DriveHealth.record_probe(
        {node, drive},
        result,
        offline_after_ms: Keyword.get(opts, :drive_offline_after_ms)
      )

    result
  rescue
    _ -> result
  catch
    _, _ -> result
  end

  # ── 端点/quorum 辅助（与 Maxio.ObjectMeta 的同名私有函数同语义，铁律 5 同源 quorum）──

  # 读全 N 端点该版本 sidecar -> [%{node, drive, meta} | :missing]（喂 MetaReconcile.reconcile）。
  defp read_endpoint_sidecars(bucket, key, vid, opts) do
    transport = Transport.impl(opts)

    case Paths.object_rel(bucket, key, vid) do
      {:ok, rel} ->
        Enum.map(endpoints_for(bucket, key, opts), fn {node, drive} ->
          case transport.get_sidecar(node, Path.join(drive, rel)) do
            {:ok, meta} -> %{node: node, drive: drive, meta: meta}
            {:error, _} -> :missing
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp endpoints_for(bucket, key, opts) do
    case Keyword.get(opts, :topology) do
      nil ->
        set_id = Router.set_for(bucket, key)
        Topology.endpoints(set_id)

      t ->
        set_id = Router.set_for(bucket, key, t)
        Topology.endpoints_from(t, set_id)
    end
  end

  # read_quorum = K（data_shards）。来源优先级与 ObjectMeta/Listing 逐字一致：
  # opts[:topology].data_shards > Config.load! > opts[:read_quorum] || 1。
  defp read_quorum(opts) do
    case Keyword.get(opts, :topology) do
      %{data_shards: k} when is_integer(k) and k > 0 -> k
      _ -> config_read_quorum(opts)
    end
  end

  defp config_read_quorum(opts) do
    cfg = Config.load!(Keyword.take(opts, [:drives, :data_shards, :parity_shards, :block_size]))
    cfg.read_quorum
  rescue
    _ -> Keyword.get(opts, :read_quorum, 1)
  end

  # ── 配置 / 计数 ──

  defp config do
    cfg = Application.get_env(:maxio, :scanner, [])

    [
      enabled: Keyword.get(cfg, :enabled, false),
      interval_ms: Keyword.get(cfg, :interval_ms, 86_400_000),
      batch_size: Keyword.get(cfg, :batch_size, 500),
      orphan_cleanup_min_age_ms: Keyword.get(cfg, :orphan_cleanup_min_age_ms, 172_800_000),
      orphan_cleanup_max_deletes: Keyword.get(cfg, :orphan_cleanup_max_deletes, 100)
    ]
  end

  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n
  defp positive_int(_n, default), do: default

  defp non_negative_int(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_negative_int(_n, default), do: default

  defp zero_counts, do: Map.new(@count_keys, &{&1, 0})

  defp zero_report(dry_run, status),
    do: Map.merge(zero_counts(), %{status: status, dry_run: dry_run, buckets: 0})

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  defp merge_counts(acc, counts) do
    Enum.reduce(@count_keys, acc, fn k, a -> Map.update!(a, k, &(&1 + Map.fetch!(counts, k))) end)
  end
end
