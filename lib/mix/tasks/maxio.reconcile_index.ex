defmodule Mix.Tasks.Maxio.ReconcileIndex do
  @shortdoc "手动触发一轮派生索引 reconcile（盘上 sidecar 权威 ↔ PG 派生索引）"
  @moduledoc """
  ROUTE B B5-2 —— 派生索引 reconcile / reverse-GC CLI（铁律 4：CLI + 结构化日志，无 GUI 可调试）。

      mix maxio.reconcile_index                    # 真实一轮（与 scanner 周期轮同一实现）
      mix maxio.reconcile_index --dry-run          # 只报告（would-计数）绝不写 PG
      mix maxio.reconcile_index --bucket <name>    # 仅扫指定桶（可与 --dry-run 组合）
      mix maxio.reconcile_index --force            # 写权威非 :sidecar 时仍强制执行（危险，见下）

  **写权威前置条件（安全闸）**：reconcile 以「盘上 sidecar = 写权威」为前提，仅在
  `config :maxio, :authoritative_source` 的 `write: :sidecar` 下有意义。默认 `:pg` 权威下
  PG 才是事实来源，而 PG-only delete marker（B5-0 之前的全部存量 marker；`:pg` 模式下
  best-effort 盘上 marker 写失败的 marker）盘上**没有** sidecar：跑一轮会把被 marker 遮蔽的
  旧版本重新置 latest（**已删对象复活**）并把权威 marker 行当孤儿 reverse-GC 掉。故本任务在
  写权威非 `:sidecar` 时拒绝执行（status=authority_mismatch 零计数），**含 --dry-run**
  （其 would-计数同样基于错误的盘权威假设，纯误导）；仅显式 `--force` 越闸——你必须明确接受
  以盘为权威重写 PG 索引的全部后果。

  报告字段：scanned（盘上检视的版本数）/ upserted（缺行/stale 收敛）/ gc（孤儿行删除）/
  skipped（端点不可达跳过 + 写失败留待下轮）/ divergent（quorum 仲裁失败，绝不写）。
  逐对象动作的结构化日志（action: :reconcile_index / :reverse_gc）随轮输出。
  无分布式拓扑（单机 FS / dev）→ status=no_topology 安全 no-op（盘上枚举需要拓扑端点）。
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [dry_run: :boolean, bucket: :string, force: :boolean])

    if rest != [] or invalid != [] do
      Mix.raise(
        "usage: mix maxio.reconcile_index [--dry-run] [--bucket <name>] [--force] " <>
          "(unexpected: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))})"
      )
    end

    Mix.Task.run("app.start")

    {:ok, report} =
      Maxio.Storage.Scanner.run_once(
        dry_run: Keyword.get(opts, :dry_run, false),
        bucket: Keyword.get(opts, :bucket),
        force: Keyword.get(opts, :force, false)
      )

    IO.puts(
      "[maxio reconcile_index] status=#{report.status} dry_run=#{report.dry_run} " <>
        "buckets=#{report.buckets} scanned=#{report.scanned} upserted=#{report.upserted} " <>
        "gc=#{report.gc} skipped=#{report.skipped} divergent=#{report.divergent}"
    )

    if report.status == :no_topology do
      IO.puts(
        "[maxio reconcile_index] no distributed topology configured — nothing scanned " <>
          "(reconcile requires Maxio.Cluster.Topology; FS 单机 sidecar 接线 = B6-1 defer)"
      )
    end

    if report.status == :authority_mismatch do
      IO.puts(
        "[maxio reconcile_index] refused: authoritative_source(:write) != :sidecar — disk is " <>
          "NOT the write authority. Reconciling PG from disk under :pg authority would " <>
          "resurrect objects deleted via PG-only delete markers and reverse-GC authoritative " <>
          "rows. Rerun with --force only if you explicitly accept disk as the authority."
      )
    end
  end
end
