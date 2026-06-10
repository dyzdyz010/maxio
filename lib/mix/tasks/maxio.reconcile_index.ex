defmodule Mix.Tasks.Maxio.ReconcileIndex do
  @shortdoc "手动触发一轮派生索引 reconcile（盘上 sidecar 权威 ↔ PG 派生索引）"
  @moduledoc """
  ROUTE B B5-2 —— 派生索引 reconcile / reverse-GC CLI（铁律 4：CLI + 结构化日志，无 GUI 可调试）。

      mix maxio.reconcile_index                    # 真实一轮（与 scanner 周期轮同一实现）
      mix maxio.reconcile_index --dry-run          # 只报告（would-计数）绝不写 PG
      mix maxio.reconcile_index --bucket <name>    # 仅扫指定桶（可与 --dry-run 组合）

  报告字段：scanned（盘上检视的版本数）/ upserted（缺行/stale 收敛）/ gc（孤儿行删除）/
  skipped（端点不可达跳过 + 写失败留待下轮）/ divergent（quorum 仲裁失败，绝不写）。
  逐对象动作的结构化日志（action: :reconcile_index / :reverse_gc）随轮输出。
  无分布式拓扑（单机 FS / dev）→ status=no_topology 安全 no-op（盘上枚举需要拓扑端点）。
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [dry_run: :boolean, bucket: :string])

    if rest != [] or invalid != [] do
      Mix.raise(
        "usage: mix maxio.reconcile_index [--dry-run] [--bucket <name>] " <>
          "(unexpected: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))})"
      )
    end

    Mix.Task.run("app.start")

    {:ok, report} =
      Maxio.Storage.Scanner.run_once(
        dry_run: Keyword.get(opts, :dry_run, false),
        bucket: Keyword.get(opts, :bucket)
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
  end
end
