# ObjectMutation Phase 1 步骤 3–6 实现计划（串行 executor 批次）

依据：`docs/superpowers/plans/2026-07-10-object-mutation-protocol.md`（已批准协议，语义不可更改）、AGENTS.md §3 架构铁律、6 份探索报告核实过的现状。范围仅覆盖普通 PutObject（协议 Phase 1）；Copy/Multipart/delete/metadata-only 一律不碰（Phase 2）。

---

## 0. 总体架构决策与批次划分理由

### 0.1 关键架构决策（实现前必须统一认知）

**D1 — 引入节点本地 EpochStore 串行临界区（协议 §3.3 "FS：操作在 ShardServer 的串行临界区中完成并 fsync" 的落地）。**
探索证实 `ShardServer` 是纯函数模块、**没有**串行临界区；而 per-endpoint 的 epoch CAS（read-validate-write）必须原子，否则 fence 单调性被破坏（两个写者同读 gen=5 各写 gen=6 → lost update），且 Windows 上 rename-替换可能需要"先挪走旧文件再 rename 新文件"的两步窗口（窗口内 epoch 暂时 absent，而 `nil/:enoent` 绝不能当授权）。解法：新增 `Maxio.Storage.EpochStore`，用 `PartitionSupervisor` + GenServer pool 按 `phash2({drive_root, epoch_rel_path})` 路由，**同一 epoch 路径的所有读写在同一 worker 内串行执行**。所有 per-endpoint epoch 原语经它执行，两步 rename 窗口对协议不可见。

**D2 — per-endpoint 原语下沉到 ShardServer，三后端只做 quorum 编排。**
per-endpoint 的 4 个原语（`read_epoch` / `cas_epoch` / `restore_mutation` / `finalize_mutation`）实现一次、放在 `ShardServer`（内部委托 EpochStore 串行执行 + fsync + DriveIO.track）：
- FS = 单 drive 直调；
- EC = 对 `cfg.drives` 逐盘直调 + quorum 计数（复用 `commit_drives_results` 同形结构）;
- Distributed = 经 Transport RPC 调远端 ShardServer 同名函数（完全复用 `Transport.Erpc.call(node, fun, args, on_fail)` 既有模式）。
这最大化复用、并让 `restore`（epoch CAS + backup rename 回 final）在单个 endpoint 上是**一次串行原子调用**，避免多轮 RPC 交错。

**D3 — 备份从 `.tmp/<uuid>` 迁移到 `<drive>/.maxio-object-mutations/<mutation_id>/` + durable manifest（协议 §3.2）。**
现状备份放 `.tmp/<uuid>`、plan 只在内存——进程死后 recovery 无法定位备份，durable 恢复不可能。协议化 put 的备份必须落在 mutation 目录并带 manifest（entries + previous token），recovery 仅凭 journal（mutation_id + placement_snapshot）+ 磁盘即可恢复。非协议调用者（Copy 等，Phase 2 迁移）保留旧 `.tmp` 备份路径不动。

**D4 — epoch 破坏性 quorum = `max(write_quorum, ⌊n/2⌋+1)`。**
协议 §3.1 要求"两个 write quorum 必有交集"。EC 现有 `write_quorum = k`（仅 m==n/2 时 k+1），当 k ≤ n/2 时两个 quorum 可能不相交。epoch 的 claim/publish/restore/finalize/读裁决一律用多数派下界钳制，保证交集不变量与后端配置解耦。

**D5 — Control 降级为加速器（协议 §5）。**
owner/publisher DOWN 时 Control 只调 `ObjectMutation.request_rollback/2`（journal CAS → rollback_pending + next_attempt_at=now）并 best-effort 立即尝试一次 restore；**最终决定永远由 journal + backend CAS 作出**，recovery worker 兜底收敛。`prepare` 增加 `initial_backoff_ms`（请求路径默认 60s 宽限），防止 recovery 扫到健康 in-flight 请求的 journal；recovery 另持同一 `{bucket,key}` object lock 作第二道防线。

**D6 — 批次划分调整为 7 批（对建议 6 批的修正）。**
建议的 "B1 FS epoch CAS" 实际隐含了 EpochStore、Backend behaviour 扩展、backup manifest 契约、Failpoint、Paths 保留名等**三后端共享地基**，塞进 FS 批会让首批膨胀且后两批被迫返工接缝。故拆出独立 B1（共享地基，纯 FS 单测、不碰任何后端 put 流程），FS/EC/Distributed 各占一批（Distributed 因需改 Transport behaviour + Erpc + InProcess 三处，风险独立成批），B5 orchestration+Control、B6 recovery worker、B7 CLI/日志收口+e2e，与协议步骤 4/5/6 对齐。每批独立可编译（新 behaviour callbacks 先 `@optional_callbacks`，B4 收口时转强制）、独立聚焦测试。

### 0.2 目标端到端流程（B5 完成后的普通 PutObject）

```
request owner: staging（不变）→ ObjectCommit.run → around_object_commit
  └ Maxio.Lock.with_object_lock({bucket, key}):
      precondition / version_id / quota / retained ledger（现有逻辑，不变）
      ── 新增：Maxio.ObjectMutation.Commit.run(plan) ──
      1. current  = Storage.current_epoch(target, opts)          # quorum 读
      2. gen      = max(epoch_gen, journal_max_gen, legacy 0) + 1
      3. journal  = ObjectMutation.prepare(...)                   # phase=prepared, id=mutation_id
      4. Storage.claim_epoch(target, token, "put", opts)          # per-endpoint CAS + quorum
      5. journal → claimed（attrs: previous_epoch）
      6. publish.(version_id:…, object_mutation: ctx)             # backend 内：
         manifest+backup 落 .maxio-object-mutations/<id>/ →
         epoch CAS claimed→published(+fingerprint) quorum →
         ShardServer.commit rename（数据先于元数据，现状不变）
      7. journal → published（attrs: published_fingerprint）
      8. Repo.transaction: Objects.put_version_with_id + outbox + quota
         + transaction_hook 内 journal → metadata_committed        # 同一 PG 事务
      9. Failpoint.hit(:object_mutation_after_metadata_commit)
     10. journal → finalize_pending → Storage.finalize_if_current(ctx)
         （epoch → committed，discard backup）→ journal → finalized
         finalize 失败：mark_error，请求仍成功，recovery 收敛
     11. Control.mark_committed（仅进程内加速器语义）
  失败路径（1–8 任一步）：request_rollback → best-effort restore_if_current → rolled_back
```

---

## B1 — 共享地基：EpochStore、per-endpoint 原语、backup manifest、Failpoint、契约扩展

### 新建文件
| 路径 | 内容 |
|---|---|
| `lib/maxio/storage/epoch_store.ex` | 节点本地串行 epoch 执行器（PartitionSupervisor + GenServer pool） |
| `lib/maxio/storage/mutation_backup.ex` | backup manifest 纯数据契约（encode/decode/路径） |
| `lib/maxio/storage/mutation_context.ex` | `%Maxio.Storage.MutationContext{}` 结构体 + `from_journal/1` |
| `lib/maxio/failpoint.ex` | 最小 failpoint 设施 |
| `test/maxio/storage/epoch_store_test.exs` | 纯 FS 单测（async: true，tmp dir） |
| `test/maxio/storage/mutation_backup_test.exs` | manifest 编解码/严格校验 |
| `test/maxio/cluster/shard_server_mutation_test.exs` | per-endpoint 原语单测 |
| `test/maxio/failpoint_test.exs` | failpoint arm/disarm/hit |

### 修改文件
| 路径 | 改动 |
|---|---|
| `lib/maxio/storage/backend.ex` | 追加 4 个 `@callback` + `@optional_callbacks`（B4 收口转强制）；docstring 写明 `opts[:object_mutation]` 契约 |
| `lib/maxio/cluster/shard_server.ex` | 追加 `read_epoch/2,3`、`cas_epoch/2`、`restore_mutation/2`、`finalize_mutation/2`（委托 EpochStore）；`list_dir` 跳过名单加两个新根 |
| `lib/maxio/cluster/paths.ex` | `@layout_reserved` 追加 `".maxio-object-epochs"`、`".maxio-object-mutations"`（与 `.maxio-notification-ledger` 同模式；注意注释声明的"list_dir 跳过名单同源"，两处必须同步改） |
| `lib/maxio/application.ex` | children 追加 `{PartitionSupervisor, child_spec: Maxio.Storage.EpochStore.Worker, name: Maxio.Storage.EpochStore}` |

### API 草案

```elixir
defmodule Maxio.Storage.EpochStore do
  @type expect ::
          {:claim, proposed :: ObjectEpoch.token()}          # 接受当前 absent 或 current_token < proposed
          | {:exact, ObjectEpoch.token(), allowed_phases :: [String.t()]}

  @spec read(drive_root :: String.t(), ObjectEpoch.target(), keyword()) ::
          {:ok, ObjectEpoch.t()} | {:ok, :absent} | {:error, {:corrupt, term()} | term()}

  @spec cas(drive_root :: String.t(), next :: ObjectEpoch.t(), expect(), keyword()) ::
          {:ok, :applied}
          | {:error, {:fenced, current_token :: map() | nil}}   # token/phase 不满足 expect
          | {:error, :epoch_missing}                            # expect 为 :exact 而 epoch absent —— 绝不视为授权
          | {:error, {:corrupt, term()} | term()}
end
```
- 写入协议：同 drive 卷 temp 写 `epoch.json` → fsync 文件 → rename 进位（Windows 若 `:eexist` 则串行段内先挪旧文件再 rename）→ fsync 目录。复用/提取 ShardServer 现有 fsync 原语与 `[:maxio, :durability, :fsync]` telemetry。
- `{:corrupt, _}`（JSON 坏 / format 不识别 / decode 拒绝）**永不静默覆盖**，原样上报（后端映射 quarantine 证据）。

```elixir
defmodule Maxio.Storage.MutationBackup do
  @format "maxio/object-mutation-backup/1"
  @spec relative_dir(mutation_id :: String.t()) :: String.t()   # ".maxio-object-mutations/<mutation_id>"
  @spec manifest(target, token, previous_token :: map() | nil, entries :: [%{name: String.t()}]) :: t()
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}       # 严格键校验，同 ObjectEpoch.decode 风格
end
```

```elixir
# ShardServer 追加（全部经 EpochStore 串行执行；请求/响应均为可 erpc 序列化的纯数据）
@spec read_epoch(drive_root, target :: map()) :: {:ok, map()} | {:ok, :absent} | {:error, term()}
@spec cas_epoch(drive_root, request :: map()) :: {:ok, :applied} | {:error, term()}
        # request: %{next: epoch_payload_map, expect: {:claim, token} | {:exact, token, phases}}
@spec restore_mutation(drive_root, request :: map()) ::
        {:ok, :restored} | {:ok, :superseded} | {:error, term()}
        # request: %{target, token, mutation_id, final_rel :: String.t()}
        # 串行段内：read epoch → token 精确匹配且 phase ∈ [claimed, published]（rolled_back 幂等直接 :restored）
        #   → epoch CAS → rolled_back → 按 manifest 把 backup entries rename 回 final → 清 backup dir
        # phase == "committed" 即使 token 匹配也拒绝（{:error, :epoch_committed}，metadata_committed 禁回滚的端点级防线）
        # 当前 token > 调用者 token → {:ok, :superseded}，绝不触碰 final
        # epoch absent → {:error, :epoch_missing}，绝不删/恢复任何字节
@spec finalize_mutation(drive_root, request :: map()) ::
        {:ok, :finalized} | {:ok, :superseded} | {:error, term()}
        # token 精确匹配且 phase ∈ [published, committed(幂等)] → epoch → committed → File.rm_rf backup dir
```

```elixir
# Backend behaviour 追加（@optional_callbacks 至 B4）
@callback claim_epoch(ObjectEpoch.target(), ObjectEpoch.token(), operation :: String.t(), opts :: keyword()) ::
            {:ok, %{previous: ObjectEpoch.t() | nil, endpoints_ok: non_neg_integer()}} | {:error, term()}
@callback current_epoch(ObjectEpoch.target(), opts :: keyword()) ::
            {:ok, ObjectEpoch.t() | :absent} | {:error, term()}
@callback restore_if_current(MutationContext.t(), opts :: keyword()) ::
            {:ok, :restored | :superseded} | {:error, term()}
@callback finalize_if_current(MutationContext.t(), opts :: keyword()) ::
            {:ok, :finalized | :superseded} | {:error, term()}
```

```elixir
defmodule Maxio.Failpoint do
  # persistent_term 支撑，未 arm 时近零成本；测试/演练均可用（含真实 Bandit e2e 崩溃注入）
  @spec arm(name :: atom(), action :: :kill_self | {:raise, String.t()} | {:fun, (-> any())}) :: :ok
  @spec disarm(name :: atom()) :: :ok
  @spec hit(name :: atom()) :: :ok    # 未 arm → :ok；:kill_self → Process.exit(self(), :kill)
end
```

### 验证命令与验收断言
```powershell
$env:ERL_FLAGS="-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test test/maxio/storage/epoch_store_test.exs test/maxio/storage/mutation_backup_test.exs test/maxio/cluster/shard_server_mutation_test.exs test/maxio/failpoint_test.exs
```
断言：
1. claim：absent → 任意合法 token 通过；current gen=5 拒绝 gen=5（不同 mutation_id 但字典序更小）与 gen<5；接受 `{5, 更大 mutation_id}` 与 gen=6（fence 全序落点）。
2. `{:exact,...}` 遇 absent → `{:error, :epoch_missing}`（nil/:enoent 不授权落点）。
3. 并发 CAS：N 个 Task 对同一路径并发 claim 递增 generation，最终 epoch generation 单调、无 lost update（串行临界区证据）。
4. `restore_mutation`：successor token → `:superseded` 且 final/backup 均未变；`committed` phase → 拒绝；`rolled_back` 幂等。
5. epoch 损坏 JSON → `{:corrupt,...}`，文件未被覆盖。
6. Windows 上 CAS 覆盖已存在 epoch.json 成功（rename 语义验证——见风险 R3）。
7. `Paths` 新保留名与 key 编码不冲突（既有保留名测试模式扩一条）。

---

## B2 — FS 后端落地（claim/current/restore/finalize + 协议化 publish）

### 修改文件
- `lib/maxio/storage/fs.ex`
- `test/maxio/storage/fs_mutation_test.exs`（新建，async: true，纯 tmp dir，不需要 DataCase——直接以 map 形式构造 MutationContext，不经 journal）

### 实现要点（接缝）
1. 四个 callback：单 drive（`data_dir(opts)`）直调 ShardServer 原语的薄包装。`claim_epoch` 内部先 `read_epoch` 取 previous，再 `cas_epoch({:claim, token})` 写 `phase: "claimed", value_type: "object", previous_token: current.token`。
2. `publish_staged_put`（fs.ex:218）/ `publish_controlled_obj_dir`（fs.ex:264）：当 `commit_opts[:object_mutation]`（`%MutationContext{}`）存在时走协议分支：
   - `plan_put_backup` 的 backup_dir 改用 `Path.join(data_dir, MutationBackup.relative_dir(mutation_id))`（非协议调用保持 `.tmp` 现状不变）；
   - `Control.register` 之后、`materialize_put_backup` **之前**写 manifest.json 并 fsync（协议 §5 "第一次 destructive IO 前同步注册 durable mutation context"的磁盘侧落点）；
   - `materialize_put_backup` 之后、`ShardServer.commit` rename **之前**执行 `cas_epoch({:exact, token, ["claimed"]})` → `phase: "published"` + fingerprint（fingerprint 用 `ObjectEpoch.fingerprint(etag, size, sidecar_bytes)`，sidecar_bytes = 实际写入 tmp/meta.json 的字节——在 `put_sidecar` 处捕获编码后 binary）；CAS 失败（fenced）→ 不 rename，返回 `{:error, {:epoch_fenced, current}}`；
   - 成功结果 map 追加 `epoch_fingerprint` 键（orchestrator 在 B5 用于 journal published 转换）。
3. 协议分支的 `rollback_fn`/`finalize_fn`（注册进 Control 的闭包）改为调用 `restore_if_current(ctx)` / `finalize_if_current(ctx)`（即 ShardServer 原语），**不再走 identity 比对路径**；`object_commit_identity` sidecar 字段保留写入（旧调用者与取证兼容），但协议分支的所有权判定只认 epoch token。
4. 旧 `rollback_put_plan` 的 `{:error, :enoent} → remove_current_object_files` 分支仅存在于非协议路径（Phase 2 处理），协议路径不触达——在协议分支代码注释中显式标注这一差异与协议条款。

### 验证命令与验收断言
```powershell
mix compile --warnings-as-errors
mix test test/maxio/storage/fs_mutation_test.exs test/maxio/storage/fs_test.exs test/maxio/storage/fs_conformance_test.exs
```
断言：
1. 协议化 put（构造 ctx + `around_object_commit` 内驱动 claim/publish）成功后：final 有新字节、epoch phase=published、fingerprint 与 final meta.json 字节 sha256 精确匹配、backup dir 含 manifest+旧文件。
2. `finalize_if_current` 后 epoch=committed、backup dir 消失；重复调用幂等。
3. publish 后 `restore_if_current`：旧 part.0/meta.json 逐字节恢复、epoch=rolled_back、backup 清空。
4. successor 场景：token A publish 后，用 token B（gen+1）claim+publish，再用 A 的 ctx restore → `{:ok, :superseded}`，B 的 final/epoch 不变（restore successor 落点）。
5. 无协议 opts 的 put 行为与现状逐字节一致（回归：conformance + fs_test 全绿）。
6. claim 遇到 legacy final（meta.json 存在、无 epoch）：previous=nil、claim gen 由调用者给定成功；restore 阶段 epoch 由我们持有、不依赖 nil 授权（legacy generation 迁移落点，见风险 R4）。

---

## B3 — ErasureCoded 后端落地（quorum 编排）

### 修改文件
- `lib/maxio/storage/erasure_coded.ex`
- `lib/maxio/storage/erasure/config.ex`（追加 `epoch_quorum = max(write_quorum, div(n,2)+1)` 字段）
- `test/maxio/storage/erasure_coded_mutation_test.exs`（新建，async: true）

### 实现要点（接缝）
1. 提取通用 helper `epoch_quorum_apply(drives, fun, quorum)`：对每盘执行 per-endpoint 原语、返回 `{oks, supersededs, errors}` 三分类计数（结构复用 `commit_drives_results/3` 第 422 行的盘迭代+计数模式）。
2. `claim_epoch`：逐盘 `cas_epoch({:claim, token})`，oks ≥ epoch_quorum → ok（previous 取 quorum 读中最大 token 的 epoch）；不足 → `{:error, :write_quorum}`（少数盘已写入的 claim 无需回收——单调性保证无害，后继 claim 会取 max+1）。
3. `current_epoch`：逐盘 `read_epoch`，可读盘数 ≥ epoch_quorum 才裁决（取最大 token），否则 `{:error, :epoch_quorum_unavailable}`。
4. publish 集成：`publish_staged_put`（第 858 行）协议分支——`write_tmp_sidecars` 后、`commit_object_replace`（第 472 行）前插入逐盘 `cas_epoch({:exact,...}→published)` quorum 门；不足 quorum → 不进入 rename，保留 backup，返回错误。备份：`plan_object_backups`（第 504 行）协议分支改指向每盘 `<drive>/.maxio-object-mutations/<mutation_id>/` + 每盘 manifest。
5. `restore_if_current` / `finalize_if_current`：先 quorum 读全局裁决（quorum 视图显示 successor → 整体 `:superseded`，**任何盘都不动**）；裁决通过才逐盘 `restore_mutation`/`finalize_mutation`（per-endpoint CAS 仍各自把关），oks ≥ epoch_quorum → 成功，否则 `{:error, {:partial, evidence}}`（journal 侧 mark_error 重试；backup 保留）。

### 验证命令与验收断言
```powershell
mix compile --warnings-as-errors
mix test test/maxio/storage/erasure_coded_mutation_test.exs test/maxio/storage/erasure_coded_test.exs test/maxio/storage/erasure_coded_conformance_test.exs
```
断言：
1. 6 盘（4+2）：claim/publish/finalize 全盘成功路径 + 语义同 B2 断言 1–4。
2. 注入 2 盘 epoch CAS 失败（用文件只读/预写 successor epoch 到该盘）：oks=4 ≥ epoch_quorum → 通过；3 盘失败 → publish 拒绝、final 未 rename、backup 保留（quorum 不足不破坏落点）。
3. quorum intersection：token A 在 {d0..d3} 达 quorum published；token B claim 在 {d2..d5} 达 quorum → A 的 restore 全局裁决读到 B（交集盘）→ `:superseded`，d0/d1 上 A 的旧 epoch 不被 A 恢复动作触碰。
4. 非协议 put 回归全绿。

---

## B4 — Distributed 后端落地（Transport 扩展 + placement snapshot）

### 修改文件
- `lib/maxio/cluster/transport.ex`（behaviour + Erpc 各加 4 个 callback：`read_epoch/3`、`cas_epoch/3`、`restore_mutation/3`、`finalize_mutation/3`，均 `call(node, fun, args, fn -> {:error, :unavailable} end)` 既有模式）
- `test/support/transport_in_process.ex`（同 4 个 callback 直调 ShardServer + `set_cas_epoch_down/set_read_epoch_down` ETS 注入，模式抄 `set_put_sidecar_down`）
- `lib/maxio/storage/distributed.ex`
- `lib/maxio/storage/backend.ex`（**移除 @optional_callbacks，4 个 mutation callback 转强制**——三后端此时均已实现）
- `test/maxio/storage/distributed_mutation_test.exs`（新建，async: false，`InProcess.setup!()`）

### 实现要点（接缝）
1. quorum 编排与 B3 同形，endpoint 换 `{node, drive}`、执行经 `tx.cas_epoch(node, drive, request)`；`Task.async_stream` 并行（抄 `write_sidecars/3` 第 610 行模式）。
2. claim 时把 `Placement.resolve_write/3` 快照（set_id/pool_id/topology_hash）交给调用者（B5 写入 journal `placement_snapshot`）；publish 前保留既有 `revalidate_staged_placement/4` 复核，另加 epoch publish quorum 门（`publish_staged_put/10` 第 378 行，`commit_all` 之前）。
3. `restore_if_current`/`finalize_if_current` 的 endpoints **从 `ctx.placement_snapshot` 解析**（`Topology.endpoints(set_id)`），并核对 topology_hash：漂移 → `{:error, {:placement_drift, evidence}}`（B6 recovery 映射 quarantine），**绝不按当前 router 猜测**。
4. epoch_quorum 同 D4 钳制。

### 验证命令与验收断言
```powershell
mix compile --warnings-as-errors
mix test test/maxio/storage/distributed_mutation_test.exs test/maxio/storage/distributed_test.exs test/maxio/storage/distributed_conformance_test.exs
```
断言：
1. B2 断言 1–4 的 Distributed 版（经 InProcess）。
2. `InProcess.set_down(:maxio@n0)`（2 endpoint 失联）：4/6 达 quorum 通过；再断一节点 → publish 拒绝、backup 保留。
3. 不同 endpoint 子集 quorum intersection 场景（同 B3 断言 3，经 `set_cas_epoch_down` 定向注入）。
4. topology_hash 漂移时 restore 返回 `{:error, {:placement_drift,...}}` 且不触任何 endpoint。
5. `mix compile --warnings-as-errors` 证明三后端均满足强制 callbacks。

---

## B5 — PutObject orchestration + Control 接入（协议步骤 4 + 步骤 5 前半）

### 新建文件
- `lib/maxio/object_mutation/commit.ex`（`Maxio.ObjectMutation.Commit`——可复用 around-mutation seam，Phase 2A 迁移其他调用者时复用）
- `lib/maxio/object_mutation/log.ex`（结构化日志 helper：固定字段 action/request_id/mutation_id/mutation_generation/mutation_operation/mutation_phase/authority_mode/backend/bucket/key/version_id/placement_set_id/outcome/reason，协议 §7）
- `test/maxio/object_mutation/commit_test.exs`（`use Maxio.DataCase, async: false`，FS 后端 tmp dir）

### 修改文件
| 路径 | 改动 |
|---|---|
| `lib/maxio/object_mutation.ex` | 追加 `request_rollback/2`（独立 update_all CAS：phase ∈ prepared/claimed/published → rollback_pending 且 `next_attempt_at = now`，遵守 lease 匹配规则；metadata_committed 及之后 → `{:error, {:illegal_transition,...}}`）；`max_generation/2`（按 target 查 journal 最大 generation，走 `obj_mut_target_idx`）；`prepare/2` 增加 `opts[:initial_backoff_ms]`（默认 0，仅改 next_attempt_at 偏移，其余语义不变） |
| `lib/maxio/storage.ex` | facade 转发 `claim_epoch/4`、`current_epoch/2`、`restore_if_current/2`、`finalize_if_current/2` |
| `lib/maxio/storage/object_commit.ex` | `run/5` 将 discard_fun 在 `Control.start` 时注入（协议 §5 "Control 创建时立即持有 staging discard callback"） |
| `lib/maxio/storage/object_commit/control.ex` | `start(owner, discard_fun)`；registration 前 owner DOWN → 执行 discard；协议路径下 rollback_fn 即 `request_rollback` + best-effort restore（由 fs/ec/distributed 在 B2–B4 注册的闭包已指向 restore_if_current；本批把 journal request_rollback 挂进该闭包链——经 `Commit` 构造 rollback 闭包传入 backend opts） |
| `lib/maxio/s3/handlers/object.ex` | `around_object_commit`（248 行起）改为构造 plan 调 `Commit.run`；`commit_metadata`（2646 行）的 `transaction_hook` 内追加 `ObjectMutation.transition(journal, "metadata_committed", %{}, repo: repo)`，CAS 失败 → `Repo.rollback`（保证"journal metadata_committed 与 Objects/outbox/quota 同一 Ecto transaction"）；`Control.mark_committed` 调用点后移到 journal finalized/finalize_pending 已 durable 之后 |

### `Maxio.ObjectMutation.Commit` API 草案

```elixir
@type plan :: %{
        bucket: String.t(), key: String.t(), version_id: String.t(),
        operation: String.t(),            # Phase 1 固定 "put"
        authority_mode: String.t(),       # Phase 1 固定 "pg"
        storage_opts: keyword(),
        write_info: map(),                # ObjectCommit prepared（含 control/identity）
        publish: (keyword() -> {:ok, map()} | {:error, term()}),
        metadata_tx: (Journal.t() -> {:ok, term()} | {:error, term()})
        # metadata_tx 内部自行 Repo.transaction，并必须经 transaction_hook 调
        # Commit.commit_metadata_in_tx!(journal, repo)（CAS 失败即 raise → 事务回滚）
      }

@spec run(plan()) ::
        {:ok, %{journal: Journal.t(), published: map(), metadata: term()}} | {:error, term()}
@spec commit_metadata_in_tx!(Journal.t(), Ecto.Repo.t()) :: Journal.t()
```

`run/1` 按 §0.2 序列执行；每个阶段打 `Log` 结构化日志（claim / publish quorum / metadata committed / rollback requested+result / finalize result）。失败路径：
- 步骤 1–5 失败（未 publish）：journal → rollback_pending → rolled_back（无破坏性 IO，claim 过的 epoch 留 claimed 由 restore 收敛为 rolled_back）；
- publish 失败 / metadata_tx 失败：`request_rollback` → best-effort `Storage.restore_if_current(ctx)` → 成功则 rolled_back，失败 `mark_error`（recovery 兜底）；向上返回 `{:error, reason}` 使 ObjectCommit 既有 rollback 路径幂等触发；
- 步骤 10 finalize 失败：`mark_error`，**返回成功**（协议 §5：finalize 失败请求可成功）。

Failpoint 挂点（本批埋点）：`:object_mutation_before_metadata_commit`（步骤 8 前）、`:object_mutation_after_metadata_commit`（步骤 9）、`:object_mutation_finalize`（finalize_fn 内）、`:object_mutation_restore`（restore 前）。

### 验证命令与验收断言
```powershell
mix compile --warnings-as-errors
mix test test/maxio/object_mutation/commit_test.exs test/maxio/object_mutation_test.exs test/maxio/storage/object_commit_test.exs
mix test test/maxio_web --only put_object   # 既有 handler put 回归（按实际 tag/文件聚焦）
```
断言：
1. 快乐路径：bytes/sidecar/PG row/journal(finalized)/epoch(committed) 五者同一 token/fingerprint（协议测试矩阵第一行）。
2. metadata_tx 抛异常：PG 无新行、旧字节恢复、journal=rolled_back、epoch=rolled_back、backup 清空。
3. `metadata_committed` 后（failpoint `:after_metadata_commit` 注入 `{:raise,...}`）：journal 停在 metadata_committed/finalize_pending，`request_rollback` 返回 `{:error, {:illegal_transition,...}}`，新字节保留（**metadata_committed 禁 rollback 落点**：`@pg_graph` 无 rollback 边 + `request_rollback` 前置拒绝 + 端点 `restore_mutation` 拒 committed epoch，三层）。
4. owner DOWN（publisher 注册前，`Process.exit` + monitor 同步）：staged tmp 被 discard（Control 持 discard callback 生效）。
5. successor fence：put A published 后不 finalize（failpoint 停住），put B 完整走完；A 的 restore → `:superseded`，B 的 final/epoch/PG 不变。
6. journal CAS 失败（并发扰动 attempts）→ metadata 事务回滚，PG 无半提交。
7. `prepare(initial_backoff_ms: 60_000)` 的 journal 不出现在 `list_due`。

---

## B6 — Recovery worker（协议步骤 5 后半）

### 新建文件
- `lib/maxio/object_mutation/recovery.ex`（drain 门面）
- `lib/maxio/object_mutation/recovery/scheduler.ex`（**照抄 `ReplicationDelivery.Scheduler` 模式**：spawn_monitor 异步 drain、inflight map、timer token、`run_now/2` 同步返回——理由见 outbox-recovery 报告）
- `test/maxio/object_mutation/recovery_test.exs`（`use Maxio.DataCase, async: false`；FS 为主 + Distributed describe（InProcess）覆盖 placement 分支）

### 修改文件
- `lib/maxio/application.ex`（children 追加 Scheduler；`log_deferred_features` 声明开关状态）
- `config/config.exs`（`config :maxio, :object_mutation_recovery_scheduler, enabled: true, interval_ms: 60_000, initial_delay_ms: 60_000, drain_limit: 50, run_opts: []`）
- `config/test.exs`（`enabled: false`——测试用 `start_supervised!({Scheduler, name: nil, ...})` + `run_now`）

### API 草案

```elixir
defmodule Maxio.ObjectMutation.Recovery do
  @spec drain(keyword()) :: %{claimed: n, finalized: n, rolled_back: n, superseded: n,
                              quarantined: n, retried: n, skipped_locked: n}
  @spec recover(Journal.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, Journal.t()} | {:error, term()}   # CLI --mutation-id 复用同一入口
end
```

`drain`：`ObjectMutation.list_due(limit:)` → 逐条 `claim(journal, lease_owner)`（`lease_owner = "#{node()}/#{inspect(self())}"`）→ `Maxio.Lock.with_object_lock({bucket, key}, fn -> decide_and_apply(journal) end)`（`{:error, :locked}` → `mark_error` 短 backoff 跳过）→ 完成后 `release_lease`（终态转换自动清 lease）。长任务期间 `renew_lease`。

决策表 `decide_and_apply`（ctx = `MutationContext.from_journal(journal)`；每个动作前后均 CAS，天然幂等）：

| journal phase + authority | 动作 |
|---|---|
| `metadata_committed` / `finalize_pending`（pg） | → finalize_pending → `finalize_if_current` → finalized；`:superseded` → finalized + evidence |
| `published`（pg） | → rollback_pending → `restore_if_current` → rolled_back；`:superseded` → rolled_back + evidence（不触 final） |
| `published`（sidecar） | 读 epoch quorum：published/committed → **finalize_pending → finalize**（**sidecar-authority published 必须 finalize 落点**；状态机 `@sidecar_published_targets` 已禁 rollback 兜底）；epoch 不足 quorum → quarantine |
| `prepared` / `claimed` | → rollback_pending → `restore_if_current`（claimed epoch → rolled_back；无 backup 条目时仅转 epoch）→ rolled_back |
| `rollback_pending` | `restore_if_current` → rolled_back / superseded |
| `restore/finalize` 返回 `{:error, :epoch_missing \| {:corrupt,_} \| {:partial,_} \| {:placement_drift,_}}` | 可重试类 `mark_error`（backoff）；证据矛盾类（corrupt/fingerprint 不符/drift）→ `quarantine(journal, reason, evidence)`——**不猜测、不破坏、backup 保留** |

每条决策打 `Log`（recovery decision / quarantine 事件）。

### 验证命令与验收断言
```powershell
mix compile --warnings-as-errors
mix test test/maxio/object_mutation/recovery_test.exs
```
断言（全部 `assert_receive`/monitor 同步，**零 `Process.sleep`**，慢收敛用 test-infra 报告的 `assert_eventually` 10ms 轮询）：
1. **PG commit 后 kill**：failpoint `:after_metadata_commit` = `:kill_self`（真实 put 经 `Task` + monitor 等 DOWN）→ `run_now` → journal=finalized、新字节保留、epoch=committed（Phase 1 头号验收）。
2. metadata 前 kill（publish 后 owner kill）→ recovery → 旧字节恢复、journal=rolled_back。
3. finalize failure（failpoint `:object_mutation_finalize` raise 一次）→ 请求成功返回、journal=finalize_pending → `run_now` → finalized。
4. lease：worker A claim 后（构造过期 lease）worker B 接管推进；A 的后续 transition 得 stale_journal 且库不变（既有 contract 测试已锁，此处集成级复验）。
5. superseded：B5 断言 5 的 recovery 版——rolled_back + `recovery_evidence` 记 superseded，successor 三态不变。
6. sidecar-authority published journal（直接构造）+ epoch quorum published → finalized；epoch 不足 → quarantined。
7. `{:error, :locked}`（另一进程持 object lock）→ skipped，journal 保持可重试。
8. Scheduler：`enabled: false` 不调度；`run_now` 同步返回统计；stale timer token 忽略（抄 replication scheduler 测试）。

---

## B7 — CLI、日志收口、failpoint 完备化 + e2e 收口（协议步骤 6 + Phase 1 验收）

### 新建文件
- `lib/mix/tasks/maxio.object_mutations.status.ex`
- `lib/mix/tasks/maxio.object_mutations.recover.ex`
- `test/mix/tasks/maxio_object_mutations_test.exs`
- `test/maxio/s3/put_object_mutation_e2e_test.exs`（真实 Bandit：ordinary signed PUT + `STREAMING-AWS4-HMAC-SHA256` aws-chunked PUT，复用既有 SigV4 e2e 基建；含 failpoint 驱动的 crash-recover 端到端各一条）

### 实现要点
1. CLI 严格按协议 §7 形态：
   ```
   mix maxio.object_mutations.status [--bucket B --key K --mutation-id ID] [--json]
   mix maxio.object_mutations.recover --dry-run [--limit N --older-than SECONDS]
   mix maxio.object_mutations.recover --execute [--mutation-id ID]
   ```
   status 展示：journal phase / backend epoch quorum 读数（逐 endpoint token+phase）/ placement snapshot / backup manifest 是否存在 / 建议动作。默认只读；`--execute` 走 `Recovery.recover/2`（与 worker 同一入口，禁止旁路）。`list_due` 增加 `opts[:older_than_ms]` 支持 `--older-than`。
2. 日志审计：对照协议 §7 固定字段清单逐事件核对（claim、publish quorum、metadata committed、rollback requested/result、finalize result、recovery decision、quarantine）；**绝不记录对象 body/密钥/SSE envelope**（grep 自查 + 测试断言日志元数据键集合）。
3. e2e：真实 HTTP PUT 快乐路径断言五位一体 token 一致；failpoint kill 后 `Recovery.run_now` 收敛断言（e2e 版验收 1/2）。
4. 批次收口：更新 `docs/superpowers/STATUS.md`；执行完整 `mix precommit`（整个 Phase 1 仅此一次）；aws-cli/mc/boto3 活体矩阵由独立 verifier 在隔离环境（heal/rebalance/scanner 均关）执行——executor 只需在计划交付物中留好 `--endpoint-url` 操作序列清单，不自行宣称通过。

### 验证命令与验收断言
```powershell
mix compile --warnings-as-errors
mix test test/mix/tasks/maxio_object_mutations_test.exs test/maxio/s3/put_object_mutation_e2e_test.exs
mix precommit   # 批次收口，仅此一次
```
断言：status 对 finalize_pending journal 建议 finalize、对孤儿 published 建议 restore；`--dry-run` 零副作用（DB/磁盘前后快照相等）；`--execute --mutation-id` 收敛单条；e2e 两条 crash 场景收敛。完成后**只允许声明**协议规定的口径："普通 PutObject 的 external-client closeout 与三后端 durable recovery 路径已通过"，禁止任何扩大声明（协议 §6 Phase 1 结语）。

---

## 硬性不变量 → 实现落点对照表

| 协议不变量 | 落点 |
|---|---|
| fence 按 `{generation, mutation_id}` 全序，endpoint 仅接受更大 token 的 claim；destructive 要求 token 精确相等 | B1 `EpochStore.cas` 的 `{:claim, token}`（`ObjectEpoch.compare_tokens` 严格 `:gt`）与 `{:exact, token, phases}`；B1 断言 1/2；并发单调性 B1 断言 3 |
| 两个 write quorum 必有交集 | D4：`epoch_quorum = max(write_quorum, ⌊n/2⌋+1)`（B3 config.ex、B4 distributed.ex）；B3 断言 3、B4 断言 3 |
| `metadata_committed` 是 rollback 禁止线 | 三层：journal `@pg_graph` 无边（已有）+ B5 `request_rollback` 前置拒绝 + B1 `restore_mutation` 拒 `committed` epoch；B5 断言 3 |
| `restore_if_current` 遇 successor 只返回 `:superseded`，绝不触碰 successor | B1 `restore_mutation` per-endpoint 判定 + B3/B4 quorum 全局裁决先行（successor 可见即整体 superseded、任何 endpoint 不动）；B2 断言 4、B5 断言 5、B6 断言 5 |
| `nil/:enoent` 不当授权 | B1 `{:exact,...}` 遇 absent → `{:error, :epoch_missing}`；`restore_mutation` epoch absent 绝不删字节；B6 决策表 epoch_missing → mark_error/quarantine 而非恢复 |
| sidecar-authority published 必须 finalize、不得因 journal 未 metadata_committed 而 rollback | journal `@sidecar_published_targets`（已有）+ B6 决策表 sidecar 分支；B6 断言 6 |
| journal `metadata_committed` 与 PG metadata/outbox/quota 同事务 | B5 `commit_metadata_in_tx!` 挂 `Objects.put_version_with_id` 既有 `transaction_hook`（objects.ex:779 同一 `Repo.transaction`）；CAS 失败 → `Repo.rollback` |
| 备份 durable、generic 清理不得误删 | D3 `.maxio-object-mutations/<id>/` + manifest；B1 `Paths @layout_reserved` + list_dir 跳过名单；finalize 才 discard、quarantine 保留 |
| heal 不递增 generation / epoch 不放 final 目录 | Phase 1 不触 heal；epoch 路径 `ObjectEpoch.relative_path/1` 已在 final 目录外（既有契约，B1 只做保留名防护） |

---

## 风险与决策点

**R1 — Sandbox 与 recovery worker 事务交互。** Recovery drain 在 spawn_monitor 的独立进程内做 Repo 调用；测试必须 `use Maxio.DataCase, async: false`（shared sandbox 模式允许旁进程）。app 级 Scheduler 在 test.exs 必须 `enabled: false`，否则全局 scheduler 会在别的测试事务外扫 journal。EpochStore worker **绝不**碰 Repo（纯文件 IO），避免任何 sandbox 纠缠。Distributed mutation 测试同时依赖全局 ETS（InProcess）与 DataCase → 必须 async: false（test-infra 报告已确认兼容）。

**R2 — ShardServer/EpochStore 死锁与锁序。** 约定唯一锁序：`Maxio.Lock.with_object_lock({bucket,key})` → journal CAS → EpochStore 串行段；EpochStore worker 内**禁止**再取 object lock、禁止调 Repo、禁止调其他 EpochStore worker（同路径恒同 worker，天然无跨 worker 依赖）。`restore_mutation` 在串行段内做文件 rename——耗时可控（单对象两文件），但 executor 须保证串行段内绝无网络/RPC 调用。Distributed 的 quorum 编排（Task.async_stream + erpc）永远在 EpochStore 之外。

**R3 — Windows fsync/rename 语义。** ① `File.rename` 覆盖已存在目标在 Windows 可能 `:eexist`——B1 必须先写一次性验证测试（断言 6），若失败走串行段内"挪旧→rename 新"两步（对协议不可见）；② 目录 fsync 在 Windows 可能不支持——沿用 ShardServer 既有容错语义（探索确认其已有 fsync 目录步骤与 telemetry），提取而非重写；③ `.maxio-object-mutations` 下残留只读句柄可能让 `File.rm_rf` 失败——finalize 失败已有 mark_error 重试兜底，不必特判。

**R4 — legacy sidecar generation 迁移。** epoch absent + final meta.json 存在（legacy 对象）：current 逻辑代际按协议记 0，`next_generation = max(0, journal_max_gen, epoch_gen) + 1`；journal `previous_epoch = nil` 合法（schema 允许 nil，非法的是不完整 payload）。**restore 授权只认我们 claim 后写下的 epoch token，绝不因 meta.json 里有旧 `object_commit_identity`/`"generation"` 字段而放行**。delete marker sidecar 的 `"generation"`（delete_marker.ex:37）Phase 1 不收敛（属 Phase 2B），仅在 B2 注释标注 `VERIFY-AT-IMPL` 关联。

**R5 — recovery 与 in-flight 请求竞争。** 双保险（D5）：prepare 宽限 60s + recovery 取同一 object lock。residual 风险：超过 60s 仍未离开非终态的巨大 put（staging 在 prepare 之前完成，claim→finalize 窗口内无网络等待，正常毫秒级）——若真发生，recovery 拿不到 object lock 会 skip，而非误回滚。executor 不得把宽限设为 0 图测试方便，测试用 `opts[:now]` 时间注入。

**R6 — 三后端 put 回归面。** B2–B4 每批都动各自 `publish_staged_put`，协议分支必须以 `commit_opts[:object_mutation]` 判空严格隔离，非协议路径逐字节不变，各批都跑对应 conformance + 既有后端测试作回归门。B5 之前没有任何生产调用者传 `object_mutation`，riskless 合入。

**R7 — 编译串行纪律。** 七个批次严格串行（每批一个 executor、一次完成）；每批收口仅跑该批聚焦测试 + `mix compile --warnings-as-errors` + 必要 `mix format --check-formatted`；完整 `mix precommit` 只在 B7 执行一次。所有 mix 命令前置 `$env:ERL_FLAGS="-kernel standard_io_encoding unicode"`。每批完成后由独立 code-reviewer/verifier 审查，实现者绝不自审。

**决策点汇总（executor 遇到时按此裁决，不得自行改协议语义）：**
1. recovery scheduler 生产默认 `enabled: true`（它是 correctness 组件而非可选优化；与其他 deferred scheduler 不同），启动日志显式声明——如 reviewer 有异议，降级为 config 决策不影响代码结构。
2. epoch publish 时机固定为"destructive rename 之前"（§0.2 步骤 6）——crash 窗口两侧均被 recovery 决策表覆盖，不得调换顺序。
3. `Maxio.ObjectMutation.Commit` 是 Phase 2A 的复用 seam，函数命名可微调，但 plan 结构中的 `metadata_tx` 回调 + `commit_metadata_in_tx!` 强制同事务模式不得拆散。

---

## 交付物清单（供 orchestrator 逐批验收）

| 批次 | 一句话验收口径 |
|---|---|
| B1 | EpochStore CAS 单调/串行/拒绝 absent 授权，per-endpoint restore/finalize 原语齐备，failpoint 可 arm/kill |
| B2 | FS 协议化 put 五位一体 + superseded 不触 successor，非协议路径零回归 |
| B3 | EC quorum 门生效，quorum 不足不破坏、backup 保留，交集不变量有测试锁死 |
| B4 | Distributed 经 Transport 达 quorum，placement snapshot 驱动 recovery 端点解析，behaviour callbacks 转强制零警告 |
| B5 | PutObject 全程 journal 化，metadata 同事务，metadata_committed 禁回滚三层落点齐备 |
| B6 | PG-commit-后-kill 保新字节、metadata-前-kill 复旧字节、finalize 失败收敛、lease/superseded/quarantine 决策表全绿，零 sleep |
| B7 | CLI 三命令 + 日志字段审计 + Bandit 普通/aws-chunked e2e + STATUS 更新 + 唯一一次 mix precommit；对外声明严格限于协议允许口径 |