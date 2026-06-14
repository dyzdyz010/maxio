# M8 Scheduler Live Rehearsal Runbook

> 目标：用真实或 env-gated 的多 BEAM 节点演练 scheduler 长跑窗口，证明
> `cluster_scheduler_runs`、singleton lock loser、scheduled-only cadence、
> blocked `next_action`、rollup 覆盖与 `mix maxio.scheduler.evidence` 能一起工作。
>
> 本 runbook 不启用新的生产自动化，不自动修复 PG placement/MPU，不做 topology /
> deployment / physical remove / purge，不接 retention timer。

## 1. 适用范围

- scheduler：`fresh_drive_heal` 或 `rebalance`。
- 证据窗口：使用 UTC `[from, until)` 半开区间，必须记录精确 `from` / `until`。
- 节点：至少两个具名 BEAM 节点，共享同一个 Postgres Repo 与相同代码版本。
- 日常回归：不跑真实长跑；真实 `:peer` / 多节点演练必须 env-gated。

## 2. 前置检查

1. 确认所有节点使用同一 commit：

   ```powershell
   git rev-parse HEAD
   ```

2. 确认 scheduler ledger 开启，目标 scheduler 本身仍是显式 opt-in：

   ```elixir
   config :maxio, :scheduler_ledger, enabled: true
   config :maxio, :fresh_drive_heal_scheduler, enabled: true
   # 或：
   config :maxio, :rebalance_scheduler, enabled: true
   ```

3. 为演练选择短周期和有界窗口，例如 5 分钟窗口、60 秒 interval。不要在生产数据上直接缩短 interval。

4. 记录节点名。后续 `--expected-nodes` 必须使用 ledger 里的 `node` 字符串，例如：

   ```text
   maxio_a@host,maxio_b@host
   ```

## 3. 启动节点

示例，按本机/测试环境调整 `--sname`、cookie、配置来源：

```powershell
iex --sname maxio_a --cookie maxio -S mix phx.server
iex --sname maxio_b --cookie maxio -S mix phx.server
```

演练期间不要手动写 `cluster_scheduler_runs`。后台活性只能由真实 scheduled tick 产生；
`run_now/1` 是 manual trigger，不能证明 scheduler 存活。

## 4. 记录窗口

使用 UTC `Z` 时间，窗口必须覆盖完整 scheduler 周期：

```powershell
$from = "2026-06-14T00:00:00Z"
$until = "2026-06-14T00:30:00Z"
$nodes = "maxio_a@host,maxio_b@host"
```

等待窗口结束后再收集证据。不要把 `until` 设置到未来。

## 5. 写入可选 rollup

如果要使用 `--require-rollups`，先显式写 scheduled rollup。Rollup 只写
`cluster_scheduler_run_rollups` 审计摘要，不删除 raw ledger：

```powershell
mix maxio.scheduler.rollup `
  --scheduler fresh_drive_heal `
  --trigger scheduled `
  --from $from `
  --until $until `
  --window-minutes 5 `
  --json
```

不要在 rehearsal 中运行 prune/retention。prune/retention 是单独的 destructive operator action。

## 6. 收集 evidence gate

直接收集 JSON：

```powershell
mix maxio.scheduler.evidence `
  --scheduler fresh_drive_heal `
  --from $from `
  --until $until `
  --window-minutes 5 `
  --expected-interval-ms 60000 `
  --stale-after-ms 120000 `
  --expected-nodes $nodes `
  --min-effective-nodes 1 `
  --require-lock-loser `
  --require-rollups `
  --fail-on-attention `
  --json
```

判定规则：

- `status="ok"` 且 `warnings=[]`：演练 gate 通过。
- `status="blocked"`：缺 expected node、effective node 不足、缺 lock loser、缺 required rollup、或 scheduler 本身不健康。
- `status="attention"`：有 blocked/failed run 等警告；`--fail-on-attention` 会让演练非零退出。

## 7. 写归档 artifact

推荐用脚本包装 evidence 命令并写 artifact：

```powershell
mix run --no-start scripts/m8_scheduler_live_rehearsal.exs -- `
  --scheduler fresh_drive_heal `
  --from $from `
  --until $until `
  --window-minutes 5 `
  --expected-interval-ms 60000 `
  --stale-after-ms 120000 `
  --expected-nodes $nodes `
  --min-effective-nodes 1 `
  --require-lock-loser `
  --require-rollups `
  --artifact artifacts/m8_scheduler_live_rehearsal_fresh_drive_heal.json
```

脚本行为：

- 不启动 `Maxio.Application`。
- 不启动 scheduler。
- 不运行 heal/rebalance runner。
- 不写 ledger、state、rollup、prune 或 retention。
- 只调用 `mix maxio.scheduler.evidence --json --fail-on-attention` 并写 artifact。
- artifact 包含 `git_sha`、窗口、expected nodes、执行命令、evidence JSON 和 raw output。

## 8. Env-gated true-peer 检查

默认测试不收集真实 peer 证据。需要时单独运行：

```powershell
$env:MAXIO_RUN_PEER_LOCK = "1"
mix test test/maxio/cluster/scheduler_peer_cadence_test.exs --include distributed
```

若未来新增 `MAXIO_RUN_SCHEDULER_LONGRUN=1` 的真长跑测试，env 未设置时可以 skip；
env 已设置但 distribution、peer、shared DB 或 ledger 不可用时必须 fail，不得 skip 成假绿。

## 9. 常见 false green

- manual `run_now/1` 被当成 scheduled heartbeat。
- 只有 `lock_unavailable` / backoff skipped rows，却被算作 effective heartbeat。
- 只检查 `scheduled_nodes`，没有检查 `effective_scheduled_nodes`。
- 未指定 exact `[from, until)`，被旧 ledger 污染。
- `until` 边界 row 被错误计入本窗口。
- JSON `status="attention"` 但脚本仍按通过处理。
- `--require-rollups` 缺 rollup 被当 warning，而不是 blocker。
