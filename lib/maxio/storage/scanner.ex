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
       `Maxio.Listing.current_version/1`（与读权威 `discover_current_version` 同一语义源）跨版本
       判定当前版本，按其覆盖 entry is_latest 后再比对/upsert——PG 的 latest 标记向「盘上版本集
       整体」收敛，与处理顺序无关。
    2. **reverse-GC（PG → 盘）**：每桶 keyset 分页（batch_size）扫 PG 行，forward 未在盘上见过的
       行逐端点经 `list_dir` 探针确认：**仅当所有端点全部可达且全部显式 missing**（版本目录无
       meta.json——meta.json 即版本记录本体，对齐 MinIO xl.meta）→ 删该 PG 行 + 日志
       （action: :reverse_gc）；任一端点 down/异常 → skip + 日志，**绝不猜**（铁律 3）。
       探针必须用 `list_dir`（宕机 → `{:error, :unavailable}`，结构性区分「不可达」与「可达但
       不存在 `{:ok, entries}`」）——`get_sidecar` 把宕机塌缩成 `:enoent`，对 GC 判定不可用。

  每轮汇总日志：scanned（forward 检视的盘上版本数）/ upserted / gc / skipped（端点不可达跳过 +
  写失败留待下轮）/ divergent（quorum 仲裁失败）。`--dry-run` 只报告（would-计数）**绝不写**。

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
  无分布式拓扑（单机 FS / dev）时 `run_once` 安全 no-op（status: :no_topology + 日志，绝不
  raise——盘上枚举需要拓扑端点，FS sidecar 接线 = B6-1 defer）。
  """
  use GenServer

  import Ecto.Query

  alias Maxio.{Buckets, Listing, MetaReconcile, ObjectMeta, Objects, Repo}
  alias Maxio.Cluster.{Paths, Router, Topology, Transport}
  alias Maxio.Objects.Object
  alias Maxio.S3.Log
  alias Maxio.Storage.Erasure.Config

  @count_keys [:scanned, :upserted, :gc, :skipped, :divergent]

  @type report :: %{
          status: :ok | :no_topology | :authority_mismatch,
          dry_run: boolean(),
          buckets: non_neg_integer(),
          scanned: non_neg_integer(),
          upserted: non_neg_integer(),
          gc: non_neg_integer(),
          skipped: non_neg_integer(),
          divergent: non_neg_integer()
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
    * `:transport` / `:topology` / `:authoritative_source`——test 注入（与读/列路径同款依赖注入）。

  返回 `{:ok, report}`（见 `t:report/0`）。写权威非 :sidecar 且未 force → status:
  :authority_mismatch 零计数（拒绝）；无分布式拓扑 → status: :no_topology 零计数（安全 no-op）。
  """
  @spec run_once(keyword()) :: {:ok, report()}
  def run_once(opts \\ []) do
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
            merge_counts(acc, scan_bucket(bucket, batch_size, dry_run, opts))
          end)
          |> Map.put(:buckets, length(buckets))

        Log.info(
          "scanner round complete: buckets=#{report.buckets} scanned=#{report.scanned} " <>
            "upserted=#{report.upserted} gc=#{report.gc} skipped=#{report.skipped} " <>
            "divergent=#{report.divergent} dry_run=#{report.dry_run}",
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

  # opts[:topology]（test 注入）优先；否则须有真集群拓扑（与 ObjectMeta.shadow_enabled? 同语义）。
  defp topology_available?(opts) do
    Keyword.get(opts, :topology) != nil or Topology.configured?()
  end

  defp bucket_names(nil), do: Buckets.list() |> Enum.map(& &1.name)

  defp bucket_names(filter),
    do: Buckets.list() |> Enum.map(& &1.name) |> Enum.filter(&(&1 == filter))

  # 单桶一轮：forward（盘 → PG）+ reverse-GC（PG → 盘）。单桶异常绝不炸整轮（记日志计零续下桶）。
  defp scan_bucket(bucket, batch_size, dry_run, opts) do
    {forward_counts, seen} = forward_pass(bucket, batch_size, dry_run, opts)
    reverse_counts = reverse_pass(bucket, batch_size, dry_run, seen, opts)
    merge_counts(forward_counts, reverse_counts)
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

    # 当前版本跨版本判定（与读权威 discover_current_version 同一语义源）：entry 的 is_latest 是
    # 写时缓存（每版本独立 sidecar，跨版本可能多个 true），PG latest 必须向版本集整体收敛。
    current_vid = Listing.current_version(vids)

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

  # ── reverse-GC：PG keyset 分页 → forward 未见过的行逐端点探针 → 全可达全 missing 才删 ──

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
            probe_endpoint(transport, node, drive, rel)
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
  defp probe_endpoint(transport, node, drive, rel) do
    dir = Path.join(drive, rel)
    parent = Path.dirname(dir)
    base = Path.basename(dir)

    case transport.list_dir(node, parent, []) do
      {:ok, entries} ->
        if Enum.any?(entries, &(&1.name == base and &1.object?)), do: :present, else: :missing

      {:error, _} ->
        :unreachable
    end
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
      batch_size: Keyword.get(cfg, :batch_size, 500)
    ]
  end

  defp zero_counts, do: Map.new(@count_keys, &{&1, 0})

  defp zero_report(dry_run, status),
    do: Map.merge(zero_counts(), %{status: status, dry_run: dry_run, buckets: 0})

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  defp merge_counts(acc, counts) do
    Enum.reduce(@count_keys, acc, fn k, a -> Map.update!(a, k, &(&1 + Map.fetch!(counts, k))) end)
  end
end
