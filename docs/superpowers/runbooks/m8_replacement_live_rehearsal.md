# M8 Replacement Live Rehearsal Runbook

> 目标：把一次 fresh-drive replacement 的 operator 闭环变成可归档、可复跑、可失败的机器证据。
> 本 runbook 复用现有 `mix maxio.replacement.workflow`、fresh-drive heal scheduler bridge、
> rebalance bounded drain 与 closure verifier，不新增 copy/delete/topology/physical 逻辑。

## 适用范围

- same-path software drive identity replacement 或长窗口 offline 后恢复，需要验证 fresh-drive heal、普通 rebalance enqueue/drain 与 placement closure。
- operator 想把 replacement 演练输出保存为 JSON artifact，用于 CI、变更记录或事后审计。
- 不适用于 decommission、topology mutation、deployment finalization、physical removal/purge、secure erase 或硬件拔盘证明。

## 前置检查

1. 所有参与节点连接同一 Postgres，且 runtime topology 已配置。
2. `mix maxio.replacement.workflow --json` 的默认只读输出可正常执行。
3. 若要运行真实修复，先确认 replacement 目标已被 `DriveHealth` / `DriveIdentity` 标记为 `heal_required` 或 `identity_heal_required`。
4. 若要让同一次演练推进 rebalance，使用 `--heal --rebalance-if-needed --advance-steps N`，并按风险选择是否加 `--verify-closure`。

## 只读预检

```powershell
mix maxio.replacement.workflow --json
```

预检通过并不代表 replacement 演练完成。只有当输出满足：

- `status` 为 `audit` 或 `ok`
- `blockers=[]`
- `next_action="none"`

才表示当前没有需要 operator 继续处理的 replacement/rebalance 下一步。

## 严格 CLI Gate

`mix maxio.replacement.workflow --fail-on-blocked --json` 会先输出 JSON，再在 `status=blocked|failed` 时非零退出。

该 gate 只判断 blocked/failed，不会把 `next_action != "none"` 自动视为失败；完整演练请使用下面的 artifact harness。
该 CLI 使用最小 runtime 启动，不调用 `app.start`，因此不会因为 operator 环境中 scheduler 配置为 enabled 而启动完整应用监督树。

## Artifact Harness

只读归档：

```powershell
mix run --no-start scripts/m8_replacement_live_rehearsal.exs -- `
  --artifact artifacts/m8_replacement_audit.json
```

带 heal、rebalance enqueue、bounded drain 与 closure verifier 的演练：

```powershell
mix run --no-start scripts/m8_replacement_live_rehearsal.exs -- `
  --probe `
  --heal `
  --rebalance-if-needed `
  --advance-steps 3 `
  --verify-closure `
  --artifact artifacts/m8_replacement_live_rehearsal.json
```

同时归档后台 scheduler evidence：

```powershell
mix run --no-start scripts/m8_replacement_live_rehearsal.exs -- `
  --probe `
  --heal `
  --rebalance-if-needed `
  --advance-steps 3 `
  --verify-closure `
  --require-scheduler-evidence `
  --scheduler-evidence-from <utc-start> `
  --scheduler-evidence-until <utc-end> `
  --scheduler-evidence-window-minutes 5 `
  --scheduler-evidence-expected-nodes node_a,node_b `
  --scheduler-evidence-expected-interval-ms 60000 `
  --scheduler-evidence-stale-after-ms 120000 `
  --scheduler-evidence-min-effective-nodes 1 `
  --scheduler-evidence-require-lock-loser `
  --artifact artifacts/m8_replacement_live_with_scheduler.json
```

成功条件比 CLI 更严格：

- 子命令 `mix maxio.replacement.workflow --json --fail-on-blocked` exit status 为 0。
- workflow `status` 为 `ok` 或 `audit`。
- `blockers=[]`。
- `next_action` 为 `none` 或缺失。
- 若启用 `--require-scheduler-evidence`，`mix maxio.scheduler.evidence --json --fail-on-attention` 也必须 exit 0、`status="ok"` 且无 warnings。
- 默认 `--dry-run` 不会通过 live gate；如需把 dry-run artifact 作为非 live 证据归档，必须显式加 `--allow-dry-run-success`。

否则 harness 会写 artifact 后非零退出。artifact 包含：

- `generated_at`
- `git_sha`
- 实际执行命令
- workflow exit status
- workflow gate 结果（`gate`）
- bundle gate 结果（`bundle_gate`，启用 scheduler evidence 时作为最终退出依据）
- `replacement_workflow` JSON
- 可选 `scheduler_evidence` JSON、exit status、raw output 与 `scheduler_evidence_gate`
- raw output

## 防假绿规则

- `copy_pass` 或 `source_cleanup` 完成不等于 rebalance closure 完成；必须看 `rebalance_workflow` / `verify_closure` 的 closure 证据。
- active decommission 或其它 active job 必须 blocker，不能被 replacement 演练当作成功。
- `next_action` 不为 `none` 时，说明仍需 operator 继续处理；artifact harness 会失败。
- harness 不调用 `app.start`；它不会因为配置开启而启动后台 scheduler。
- harness 不调用 physical remove/purge，不运行 prune/retention，不改 topology/deployment。显式 `--heal` 仍会通过 disabled scheduler bridge 同步执行 operator 请求的 heal/rebalance steps。
- scheduler 活性另用 `m8_scheduler_live_rehearsal.md` 和 `mix maxio.scheduler.evidence` 证明；manual replacement workflow 不能证明后台 scheduler 长跑健康。
  `--require-scheduler-evidence` 只是把这份独立证据打包进同一 artifact，不会把 scheduler blocker 写进 `replacement_workflow.blockers`。

## 推荐后置证据

完成演练后，若本次 replacement 依赖后台 scheduler，可再按 scheduler runbook 收集 scheduled-only cadence 证据：

也可以先用 replacement automation status 合并检查配置链与近期 scheduler evidence：

```powershell
mix maxio.replacement.automation_status --json --fail-on-attention `
  --require-scheduler-evidence `
  --since-minutes 120 `
  --expected-interval-ms 60000 `
  --stale-after-ms 120000 `
  --expected-nodes node_a,node_b `
  --min-effective-nodes 1 `
  --require-lock-loser
```

该命令仍不启动 application/scheduler，不运行 heal/rebalance；evidence 模式只启动 Repo 读取已有 scheduler ledger。

```powershell
mix run --no-start scripts/m8_scheduler_live_rehearsal.exs -- `
  --scheduler fresh_drive_heal `
  --from <utc-start> --until <utc-end> `
  --window-minutes 5 `
  --expected-nodes node_a,node_b `
  --expected-interval-ms 60000 `
  --stale-after-ms 120000 `
  --min-effective-nodes 1 `
  --require-lock-loser `
  --artifact artifacts/m8_scheduler_after_replacement.json
```
