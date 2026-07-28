# ObjectMutation Phase 2A 实现计划（byte-producing caller 迁移，串行 executor 批次）

依据：`docs/superpowers/plans/2026-07-10-object-mutation-protocol.md`（已批准协议，语义不可更改，Phase 2A 范围见 §6）、`docs/superpowers/plans/2026-07-11-object-mutation-phase1-impl.md`（批次纪律先例）、批间备忘（B1–B7 落地契约）、6 份探索报告核实的现状。范围仅覆盖协议 §6 Phase 2A 列出的 byte-producing caller；Phase 2B（put_part/Abort fence、metadata-only、delete/tombstone）与 Phase 2C（read barrier、heal、GC、source cleanup fence）一律不碰。

---

## 0. 总体架构决策（实现前必须统一认知）

**D1 — sidecar 写权威 put 的协议化：裁决为不纳入 Phase 2A，整体归 Phase 2B。**
所有 2A 迁移 caller 一律以 `Maxio.ObjectMeta.authoritative_source(:write) == :pg` 为 gate：`:pg` 走 seam，`:sidecar` 分支逐字节不变。理由：
1. Phase 2A 要消除的 §1 危险（publish 后 metadata 失败 → plain delete 丢未版本化旧对象）是 pg 权威特有的：sidecar 权威下各 caller 的 PG index 写是 best-effort、失败仅 Log.error、不触发字节回删（探索报告逐条核实），2A 的正确性目标无需触碰 sidecar 语义即可达成。
2. `Commit.run` 支持 sidecar 权威需要"quorum published 即 logical commit → journal 不经 `metadata_committed` 直接 finalize"的完整第二模式（协议 §4），这与 Phase 2B 的 metadata-only/delete 的 sidecar authority transition 是同一块工程，拆到 2A 只会把同一泛化做两遍、审查面翻倍。
3. B5 裁决先例："强行接线即改协议外语义"（与现行 write_authority_test 冲突）。B6 的 recovery 决策表已支持 `authority_mode=sidecar` journal（直接构造覆盖），2B 有现成落地基础。
每个迁移批必须跑 write_authority 相关既有测试作回归门；此边界写入 STATUS（C9）。

**D2 — access log / inventory 高频写入：照常 journal 化，正确性优先，不做采样/批量/绕过。**
- inventory：每日/每周每 config 4 个对象，journal 量可忽略，照常。
- access log：每个启用 BucketLogging 的请求 +1 journal 行生命周期（1 INSERT + ~4 次 phase UPDATE）+ 每 endpoint 2 次 epoch CAS fsync + backup 目录生命周期。仍然照常 journal 化：协议 §6 明确点名 access log delivery；任何采样/旁路都会留下一条非协议 byte-producing 路径，直接违反"禁止 publish 后自行 plain delete"与 §6 末尾的静态 inventory 收口目标。缓解：(a) 该 feature 本身按桶 opt-in；(b) AWS 原生行为就是批量聚合投递而非逐请求投递——"log 聚合投递重设计"作为正确的性能出路记入 STATUS 遗留（产品行为变更，非 2A 范围）；(c) journal 终态行的 GC 属 Phase 2C GC 范畴。

**D3 — Multipart parts 清理时序：本期把 `cleanup_terminal_upload` 移到 `Commit.run` 成功返回之后（即 journal `metadata_committed` durable 之后），parts 清理自身的 journal 化收敛留 2B。**
协议 2B 条款"只有 final object `metadata_committed` 后才能清理 upload parts"的时序半步在 C8 顺势免费满足（metadata_tx 在 seam 内完成后 caller 才继续）；但 upload-level fence、Abort 交错、清理失败的 journal 驱动收敛属 2B。因此 §8 "Complete crash" 行在 2A 只收口 **final object 可恢复** 半边（两侧 crash 均由 recovery 收敛、Upload 行残留可经重试/abort 清理且不阻塞对象可读），"upload cleanup 可恢复（journal 化）"半边记 STATUS 归 2B。

**D4 — rebalance：destination copy 纳入 2A（operation `"rebalance_copy"`，placement PG 更新即 metadata_tx、与 journal `metadata_committed` 同事务）；source cleanup fence 留 2C；delete-marker copy 留 2B。**
切分依据：协议 §6 2A 清单明确含 destination copy；§6 2C 才有"source cleanup 仅在 destination mutation committed 且仍为 current token 时执行"（fence 需要跨 mutation 查询语义，2C 建）；`copy_delete_marker` 依赖 durable tombstone（2B 机制）。语义特殊点：这是 placement 迁移而非新 logical value——metadata_tx 不挂 notification/replication outbox、不动 `is_latest`；generation 按协议 §3.1 递增（rebalance 递增）；claim/publish 全部用 **destination 写钉扎 opts**；源 placement 旧 epoch 不参与（跨 placement epoch 收敛归 2C heal/read barrier，记 STATUS）。

**D5 — 锁策略三分类（统一硬约束：claim → publish → metadata_tx 必须全程在 `{bucket, key}` object lock 内）：**
- 外层已持锁的 caller（Copy、Inventory、Replication、Rebalance）：seam 在锁内直跑，`around_object_commit` 回调不再取锁，锁点零改动。
- 无锁 caller（AccessLog、Console）：在 `around_object_commit` 回调内取 `Maxio.Lock.with_object_lock`（与 do_put 完全同构）。
- Multipart complete：**保留现有外层锁不搬**。协议要求的是 claim→metadata 在锁内，现状锁横跨整个 complete 严格更强；把锁搬进 around 是不必要的大重构（version_id 生成点、precondition 检查全要跟着搬）。version_id 在 Copy/complete 等处于锁外或锁内提前生成均合法：versioned 时是全局唯一新 id，`"null"` 覆盖竞争由锁内 claim CAS fence 兜底。

**D6 — operation 取值集合（已核实无 migration 需求）。**
`20260710135513_create_object_mutations.exs` 对 `operation` 仅有 btrim 非空约束、`Journal` changeset 仅 `validate_format(:operation, ~r/\S/)`、`Commit.run` 透传——**无需 migration、无需 changeset 改动**。本期固定取值：`"put"`（PutObject/Console single put）、`"copy"`（CopyObject）、`"generated_put"`（ObjectWriter/Inventory/AccessLog）、`"replicate"`（replication delivery）、`"rebalance_copy"`、`"complete"`（multipart complete）。写入 `Commit` moduledoc 作为规范来源（取证时 operation 是唯一 caller 判别器）。

**D7 — 批次划分为 9 批（C1–C9），串行。**
理由：(1) seam 共享化先行（C1），否则 7 个 caller 批各自复制 journal-tx 胶水；(2) 最简 caller 先做模板批（C2）以最低成本暴露 seam 工效学缺口，旗舰复杂 caller（C3 Copy）随后；(3) 无锁家族（C4）与 cluster 后台家族（C5）按结构相似性各配对一批，每批两 caller 控制在单 executor 一次完成的量；(4) backend assemble seam（C6 FS+EC、C7 Distributed）是 C8 的前置且是 riskless backend-only 批（无生产调用者传 opt，沿 Phase 1 B2–B4 纪律；Distributed 因 transport/placement 面独立成批沿 Phase 1 先例；FS/EC 各自的协议分支是本文件内既有 put publish 分支的同构复制，合一批可控）；(5) C8（multipart complete + console multipart）依赖最多、attrs provenance 风险最高，放迁移批最后；(6) C9 跨后端矩阵 + 审计 + STATUS + 唯一一次 `mix precommit` 收口。

### 0.1 通用迁移模板（所有 caller 批的公共形态）

```elixir
# caller（已持锁或在 around 内取锁）：
Storage.put(bucket, key, version_id, stream,
  storage_opts ++ [
    object_meta: meta,                      # 及 caller 既有 before_object_commit 等，原样保留
    around_object_commit: fn write_info, guarded_publish ->
      # （无锁 caller 在此处取 Lock.with_object_lock({bucket, key}, fn -> ... end)）
      Maxio.ObjectMutation.Commit.run(%{
        bucket: bucket, key: key, version_id: version_id,
        operation: "...",                   # D6 集合
        authority_mode: "pg",               # D1：caller 侧已 gate :pg 才进入
        storage_opts: Placement.storage_opts(write_info),   # 写钉扎，B4 审查项 2 契约，不得用读 placement
        write_info: write_info,
        publish: fn extra -> guarded_publish.(base_commit_opts ++ extra) end,
        # base_commit_opts 对照 do_put 现有形状（object.ex:452 附近）；返回 map 的
        # :epoch_fingerprint 由后端协议分支产生，wrapper 不得剥离（B2 契约）
        metadata_tx: fn journal, published -> ... end       # 见各批
      })
    end
  ])
```

公共不变量（每批 reviewer 核对项）：
1. `around_object_commit` **绝不能在 metadata 未提交时返回成功**（B2 备忘 4：Control finalize 闭包重放会清 backup）——`Commit.run` 返回什么 around 就返回什么。
2. metadata_tx 内部自行 `Repo.transaction` 且必须经 `Commit.commit_metadata_in_tx!(journal, repo)`（CAS 失败 `repo.rollback`，closure 返回 `{:error, reason}` 不 raise）；返回 ok 但未 CAS → 运行期 `quarantine_contract_violation`（commit.ex:402 既有防线）。
3. 原 metadata 失败后的 plain `Storage.delete` 调用点与函数本体**删除**，不留死代码。
4. `:sidecar` 写权威分支逐字节不变。
5. Failpoint 复用 Phase 1 既有挂点（`:object_mutation_before_metadata_commit` / `:object_mutation_after_metadata_commit` / `:object_mutation_finalize` / `:object_mutation_restore`，都在 `Commit.run` 内，所有 caller 免费获得）；测试零 `Process.sleep`。
6. 所有 mix 命令前置 `$env:ERL_FLAGS="-kernel standard_io_encoding unicode"`；每批仅跑聚焦测试 + `mix compile --warnings-as-errors`（+必要 `mix format --check-formatted`），完整 `mix precommit` 仅 C9 一次；每批完成后交独立 code-reviewer/verifier，实现者绝不自审。

---

## C1 — Seam 共享化 + Phase 2A 遗留项收口（不迁移任何 caller）

### 修改文件
| 路径 | 改动 |
|---|---|
| `lib/maxio/object_mutation/commit.ex` | 新增共享 helper（下）；moduledoc 更新 operation 取值集合（D6）与 caller 迁移契约（模板 §0.1 六条不变量成文） |
| `lib/maxio/s3/handlers/object.ex` | do_put 的 journal 事务胶水（`post_commit_transaction_opts` / `journal_metadata_committed_in_tx!` 中 journal 相关部分）改为调用 Commit 新 helper——**提取而非复制**，行为逐字节不变；`journal = nil` 直通语义必须保留（Copy 未迁移前仍传 nil） |
| `lib/maxio/storage/erasure_coded.ex` | `publish_controlled_replace`（约 :963–:974）窄 case 收口：`commit_object_replace` 返回非 `{:error, :write_quorum}` 的错误由 CaseClauseError 改为结构化 `{:error, {:commit_failed, reason}}` 透出（`:write_quorum` 形状不变） |
| `lib/maxio/cluster/../storage/distributed.ex` | 同名同形窄 case（约 :486–:497）一并收口（grep 已核实仅此两处，fs.ex 无此模式） |
| `test/maxio/object_mutation/commit_test.exs` | helper 单测 + do_put 回归 |
| `test/maxio/object_mutation/recovery_test.exs` | **NEXT-3**：journal 收敛 CAS 失败（journal_convergence_failed → log_no_action 分支）立即释放租约的构造性测试——并发扰动 journal 使锁内收敛 CAS 失败，断言租约即刻可被下一 worker claim（不等 60s 过期），零 sleep |
| `test/maxio/storage/erasure_coded_mutation_test.exs`（或新 focused 文件） | 窄 case 结构化返回断言（注入 commit 非 quorum 错误） |

### API 草案

```elixir
# Maxio.ObjectMutation.Commit 追加：
@spec transaction_hook(Journal.t(), extra :: (repo :: module(), result :: term() -> any()) | nil) ::
        (module(), term() -> :ok)
# 返回可直接作 Objects.put_version_with_id 的 :transaction_hook：
# 先 commit_metadata_in_tx!(journal, repo)（CAS 失败 repo.rollback → 整个事务回滚），
# 再执行 extra（notification/replication enqueue 等 caller 附加 hook）。
# journal = nil 时直通只跑 extra（兼容未迁移调用者）。
```

如 do_put 现有胶水中还有"metadata_tx 结果归一化（rollback 值 → `{:error, reason}`）"的可提取片段，一并上提为 `Commit` 私有/公共 helper，由 executor 按实际代码判断粒度；判断标准：C2–C8 各 caller 的 metadata_tx 不得复制超过 5 行胶水。

### 验证命令与验收断言
```powershell
$env:ERL_FLAGS="-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test test/maxio/object_mutation/commit_test.exs test/maxio/object_mutation/recovery_test.exs test/maxio/storage/erasure_coded_mutation_test.exs test/maxio/storage/distributed_mutation_test.exs
mix test <既有 put handler 聚焦回归（按 B5 实际使用的测试文件）>
```
断言：1) do_put 行为逐字节不变（Phase 1 五位一体快乐路径 + metadata 失败回滚回归全绿）；2) `transaction_hook(nil, extra)` 直通；3) `transaction_hook(journal, _)` CAS 失败 → 事务回滚、PG 无半提交；4) EC/Distributed 窄 case 注入非 quorum 错误 → 结构化 `{:error, {:commit_failed, _}}` 而非 CaseClauseError；5) NEXT-3 租约即时释放断言通过。

---

## C2 — ObjectWriter + Inventory Report（server-generated 模板批）

### 修改文件
| 路径 | 改动 |
|---|---|
| `lib/maxio/s3/object_writer.ex` | `put_generated!/4`：外层 `Lock.with_object_lock` 保留；`Storage.put` 加 `around_object_commit`（模板 §0.1，operation `"generated_put"`）；`commit_metadata/5` 的 pg 分支折叠进 metadata_tx；**删除** `cleanup_bytes_after_metadata_failure/5`（:242–264，plain delete 点）；`:sidecar` 分支不动 |
| `lib/maxio/s3/inventory/report.ex` | `do_write_report_object/10`：同模板逐对象接 seam（每个 report object 独立 journal）；`commit_report_metadata` pg 分支折叠进 metadata_tx；`cleanup_report_object` 的 pg 分支 plain delete **删除**（seam rollback 接管本对象）；`cleanup_written_objects`（跨对象 run abort，目标对象已 finalized——metadata_committed 是 rollback 禁止线，不得也无法经 seam 回滚）**保留现状 delete 并加注释**：这是对已提交对象的"正常 delete 操作"，协议化归 2B tombstone（记 STATUS）；`ensure_safe_report_targets` TOCTOU 收窄：锁内 `Commit.run` 前对 unversioned 目标复检 key 不存在（`Objects.get_version` 同等检查），命中即 abort 本次 run |
| `test/maxio/s3/object_writer_mutation_test.exs`（新建） | 见断言 |
| `test/maxio/s3/inventory/report_mutation_test.exs`（新建） | 见断言 |

### metadata_tx 构造
```elixir
# ObjectWriter（无 quota hook、无 outbox——最干净形态）：
metadata_tx: fn journal, _published ->
  Objects.put_version_with_id(bucket, key, version_id, attrs,
    transaction_hook: Commit.transaction_hook(journal))
end
# Inventory 同形（attrs 来自既有 commit_report_metadata 构造，原样搬入 closure）。
```

### 验证命令与验收断言
```powershell
mix compile --warnings-as-errors
mix test test/maxio/s3/object_writer_mutation_test.exs test/maxio/s3/inventory/report_mutation_test.exs
mix test <既有 restore/select 与 inventory 聚焦回归 + write_authority 回归>
```
断言（**协议 §8 "Copy/ObjectWriter/Inventory/AccessLog | metadata 失败保留旧目标" 行的 ObjectWriter 与 Inventory 落点**，FS 后端）：
1. 快乐路径：bytes/sidecar/PG row/journal(finalized)/epoch(committed) 五位一体同 token/fingerprint。
2. **unversioned 目标已有旧对象 + metadata_tx 注入失败**：旧 bytes/sidecar 逐字节恢复、PG 不变、journal=rolled_back、epoch=rolled_back、backup 清空——plain delete 危险点消除的直接证据。inventory 场景直接驱动 `write_report_object`（绕过 ensure_safe 预检，模拟 TOCTOU 命中）。
3. PG commit 后 kill（failpoint `:after_metadata_commit`）→ `Recovery.run_now` → 新字节保留、journal=finalized。
4. inventory 跨对象 abort：对象 2 失败 → 对象 1（已 finalized）经现状 delete 清理、对象 2 自身 seam 回滚、run 记失败可重试。
5. sidecar 写权威下两条路径行为与现状逐字节一致。

---

## C3 — CopyObject（旗舰批：协议 §1 点名危险点）

### 修改文件
| 路径 | 改动 |
|---|---|
| `lib/maxio/s3/handlers/object.ex` | copy 路径（约 L1467–1561）：dest lock 内的 `Storage.put` 加 `around_object_commit`（operation `"copy"`）；`before_copy_object_commit` 原位保留（staging 期回调不受影响）；metadata_tx 复用既有 `commit_metadata/10` **改传 journal**（Phase 1 已为 put 打通 journal 参数与 `post_commit_transaction_opts`，直接复用，零新胶水）；notification_outbox / notification_retained_ledger 字段改从 metadata_tx 的 `published` 参数（publish 返回的 write_result）取；rescue 中 `cleanup_copy_object_bytes_after_metadata_failure` 调用与函数本体（约 L1724–1743）**删除**；`dest_version_id` 生成点不动（D5 裁决）；自拷贝 tmp_key 裸写（L1913）不迁（internal staging，非 S3 可见对象）；UploadPartCopy 不迁（part 归 2B）；`:sidecar` 分支不动 |
| `test/maxio/s3/copy_object_mutation_test.exs`（新建） | 见断言 |

### 验证命令与验收断言
```powershell
mix compile --warnings-as-errors
mix test test/maxio/s3/copy_object_mutation_test.exs
mix test <既有 copy/SSE copy/条件 copy 聚焦回归 + write_authority 回归>
```
断言（**§8 Copy 行落点**）：
1. 快乐路径五位一体（journal operation="copy"）；SSE 重加密 copy 一条（AES256 → SSE-C 或同等代表分支）。
2. **unversioned 目标已有旧对象 + copy 覆盖 + metadata 注入失败**：旧对象逐字节恢复、PG 不变、journal=rolled_back、backup 清空。这是协议 §1 原文场景的直接测试。
3. metadata_committed 后 kill → recovery finalize、新对象保留。
4. **successor 代表性断言**（硬性不变量 3 的 caller 级证据）：copy published 后 failpoint 停住 → 后继协议化 put 完整走完 → 旧 copy mutation 的 restore → `{:ok, :superseded}`，successor bytes/epoch/PG 三态不变。
5. 自拷贝路径回归（tmp_key staging 行为不变）；条件 copy（precondition 失败）不产生 journal 行。

---

## C4 — Access Log Delivery + Console single-object upload（无锁家族：补锁批）

### 修改文件
| 路径 | 改动 |
|---|---|
| `lib/maxio/s3/plugs/access_log_delivery.ex` | `write_log_object/5`：`Storage.put` 加 `around_object_commit`，**around 内取** `Lock.with_object_lock({target_bucket.name, key}, ...)`（do_put 同构；log key 含时间戳唯一性，锁近零竞争）；operation `"generated_put"`；metadata_tx = `put_version_with_id` + `Commit.transaction_hook(journal)`；**删除** `cleanup_log_object`（约 :343 plain delete）；**best-effort 语义保持**：`Commit.run` 返回 `{:error, _}` 时仅 Log.error、不影响原 S3 响应——journal 侧收敛已由 `Commit.run` 内部 rollback + recovery 兜底，caller 只吞请求层错误；D2 决策以注释落在调用点 |
| `lib/maxio/console/object_upload.ex` | `upload_single_put/6`：同模板，around 内取锁；operation `"put"`；metadata_tx 折叠既有 `commit_metadata/7` pg 分支；`cleanup_uploaded_object` 的 **single-put 分支删除**（multipart 分支 C8 处理，本批不碰 `upload_multipart`/`complete_multipart`） |
| `test/maxio/s3/access_log_mutation_test.exs`（新建） | 直接驱动 `write_log_object`/`deliver` + 一条真实 plug 集成 |
| `test/maxio/console/object_upload_mutation_test.exs`（新建） | `upload_tmp_file` 小文件（single put）路径 |

### 验证命令与验收断言
```powershell
mix compile --warnings-as-errors
mix test test/maxio/s3/access_log_mutation_test.exs test/maxio/console/object_upload_mutation_test.exs
mix test <既有 access log / console upload 聚焦回归 + write_authority 回归>
```
断言（**§8 AccessLog 行落点**）：
1. 两 caller 快乐路径五位一体。
2. AccessLog：unversioned 目标（versioning 非 Enabled 的 target bucket）+ metadata 注入失败 → 旧对象保留、journal=rolled_back；**原始 S3 请求仍成功**（best-effort 语义断言）。
3. Console single put：metadata 失败 → 旧对象保留 + 上抛错误语义与现状一致（console 是 fail 的）。
4. 锁存在性构造断言：around 执行期间另一进程对同 `{bucket, key}` 取锁失败（证明锁已补上）。
5. journal 量注释与 STATUS 遗留条目落笔（reviewer 核对 D2 落点）。

---

## C5 — Replication Delivery + Rebalance destination copy（cluster 后台家族）

### 修改文件
| 路径 | 改动 |
|---|---|
| `lib/maxio/s3/replication_delivery.ex` | `put_replica_object/3`：外层锁已持有，`Storage.put` 加 around；operation `"replicate"`；version_id = `event.source_version_id`（外部确定，直接入 plan）；metadata_tx = `put_version_with_id` + `Commit.transaction_hook(journal)`；**删除** L270–276 plain delete；`Commit.run` `{:error, reason}` → 返回错误走既有 mark_failed/backoff（at-least-once 重试幂等性论证：重试 = 新 mutation_id、更高 generation 的新 claim，覆盖写带 backup，plain delete 破坏幂等的旧问题随删除消失）；`existing_replica` 检查保留在 seam 之前；delete marker replication 路径不动（2B）；`mark_completed` 与 metadata 事务维持现状分离（协议 §2 只约束对象 journal 同事务，replication outbox 行级状态机明确不在协议内） |
| `lib/maxio/cluster/rebalance/runner.ex` | `copy_object/4`：`move_with_lock` 锁内 dest `Storage.put` 加 around；operation `"rebalance_copy"`；**storage_opts 必须 = `Placement.storage_opts(write_info)`（dest 写钉扎）**，claim/current_epoch/publish 三者同一端点集；metadata_tx 见下；失败无回退现状（字节孤儿）被 seam 取代：metadata 失败 → `restore_if_current`（fresh dest：manifest entries=[] → epoch=rolled_back、已发布字节留 dest 但 PG placement 仍指旧 placement、读不受影响，孤儿收敛归 2C GC——记 STATUS）；`copy_delete_marker` 不迁（2B）；source cleanup 零接触（2C） |
| `test/maxio/s3/replication_delivery_mutation_test.exs`（新建） | |
| `test/maxio/cluster/rebalance_runner_mutation_test.exs`（新建） | |

### rebalance metadata_tx 构造（placement 迁移语义，无 outbox）
```elixir
metadata_tx: fn journal, _published ->
  Repo.transaction(fn ->
    case Objects.update_placement_if_current(object, attrs) do
      {:ok, updated} ->
        _ = Maxio.ObjectMutation.Commit.commit_metadata_in_tx!(journal, Repo)
        updated
      {:error, reason} ->
        Repo.rollback({:placement_stale, reason})
    end
  end)
end
```
（`update_placement_if_current` 是条件 UPDATE 无自带事务——已核实 objects.ex:528，外包 `Repo.transaction` 即满足"placement PG 更新与 metadata_committed 同事务"。）

generation 语义：dest endpoints epoch 通常 absent（首迁），世代基数 = max(claim previous, journal `max_generation`)——journal 与 placement 无关，天然接住原协议化 put 的 generation；原 put 未协议化（无 journal、源 epoch 有值而 dest absent）时从低 generation 起，跨 placement 一致性归 2C，记 STATUS。

### 验证命令与验收断言
```powershell
mix compile --warnings-as-errors
mix test test/maxio/s3/replication_delivery_mutation_test.exs test/maxio/cluster/rebalance_runner_mutation_test.exs
mix test <既有 replication_delivery / rebalance runner 聚焦回归>
```
断言：
1. replication 快乐路径五位一体（operation="replicate"，version_id=源版本）；metadata 注入失败 → dest 无残留可见对象、journal=rolled_back、outbox 事件可重试且重试成功（幂等断言）。
2. rebalance 快乐路径：dest 字节 + placement PG 行 + journal metadata_committed **同事务**（注入 CAS 失败 → placement 行未更新，事务原子性断言，**§8 rebalance 行"placement 与 journal 同事务"半边落点**）；`update_placement_if_current` 返回 stale → seam 回滚、旧 placement 不变、dest epoch=rolled_back。
3. rebalance 成功后源 placement 字节仍在（source cleanup 零接触证据）；delete marker 路径行为与现状一致。
4. notification/replication outbox 在 rebalance metadata_tx 中零参与（断言无 outbox 行产生）。

---

## C6 — FS + EC `do_assemble` 协议化（backend-only，riskless：尚无调用者传 opt）

### 修改文件
| 路径 | 改动 |
|---|---|
| `lib/maxio/storage/fs.ex` | `do_assemble`（约 :813–855）改经 `ObjectCommit.run` 编排（与 do_put fs.ex:215 同构）：staging 阶段 = 现有 tmp obj-dir 准备（`begin_tmp` + part 拼接 + sidecar + `run_before_object_commit!`），publish 阶段 = `commit_obj_dir`；`commit_opts[:object_mutation]` 存在时走协议分支——**复用 `publish_mutation_obj_dir` 既有结构**（plan backup 旧 final entries → staged fingerprint → Control.register → manifest 写+fsync → materialize 备份 → epoch CAS claimed→published → ShardServer.commit）；非协议 assemble 路径逐字节不变 |
| `lib/maxio/storage/erasure_coded.ex` | `do_assemble`（约 :261–344）同构：协议分支复用 `publish_mutation_staged_put` 四阶段结构（manifest quorum 前置门 → 物化备份 → 逐盘 epoch CAS quorum 门（不足 → 不 rename、backup 保留）→ 仅 published 盘 `commit_drives`）；错误形状沿 B3 契约（`{:error, {:epoch_publish_quorum, _}}` 等） |
| `lib/maxio/storage/object_commit.ex` | 仅当 `run/5` 的 prepared/write_info 形状不能覆盖"parts 已在盘、无 body staging"时增加入口变体；优先零改动复用——若必须改，`around_object_commit`/Control/discard 语义不得偏离 Phase 1（executor 遇结构性不匹配即暂停上报） |
| `test/maxio/storage/fs_assemble_mutation_test.exs`（新建） | |
| `test/maxio/storage/erasure_coded_assemble_mutation_test.exs`（新建） | |

### 验证命令与验收断言
```powershell
mix compile --warnings-as-errors
mix test test/maxio/storage/fs_assemble_mutation_test.exs test/maxio/storage/erasure_coded_assemble_mutation_test.exs
mix test test/maxio/storage/fs_test.exs test/maxio/storage/fs_conformance_test.exs test/maxio/storage/erasure_coded_test.exs test/maxio/storage/erasure_coded_conformance_test.exs <既有 multipart 后端聚焦回归>
```
断言：
1. 协议化 assemble（构造 ctx + around 驱动 claim/publish）成功：final 有拼接字节、epoch=published→finalize 后 committed、fingerprint 与 final meta.json 匹配、backup 含旧 final entries（overwrite 场景）。
2. publish 后 `restore_if_current`：旧 final 逐字节恢复（unversioned overwrite 场景）、epoch=rolled_back。
3. EC：2 盘注入 CAS 失败仍达 epoch_quorum 通过；3 盘失败 → 不 rename、backup 保留。
4. 非协议 assemble（不传 opt）行为与现状逐字节一致（conformance + multipart 回归全绿）——本批唯一生产影响面。

---

## C7 — Distributed `do_assemble` 协议化

### 修改文件
| 路径 | 改动 |
|---|---|
| `lib/maxio/storage/distributed.ex` | `do_assemble`/`assemble_locked`（约 :1775–1845）coordinator 侧接 `ObjectCommit.run` + 协议分支，与 distributed `publish_staged_put`（:378 附近）同形：per-endpoint `put_mutation_manifest`（复用 B4 既有 Transport callback，**无新 callback**）→ 物化备份 → 逐 endpoint epoch CAS quorum 门 → `commit_all`；claim 返回 `:placement_snapshot`（B4 契约 string-key map），assemble 的 placement 解析 + `revalidate_staged_placement` 复核保留 |
| `test/maxio/storage/distributed_assemble_mutation_test.exs`（新建，async: false，`InProcess.setup!()`） | |

### 验证命令与验收断言
```powershell
mix compile --warnings-as-errors
mix test test/maxio/storage/distributed_assemble_mutation_test.exs
mix test test/maxio/storage/distributed_test.exs test/maxio/storage/distributed_conformance_test.exs
```
断言：C6 断言 1–2 的 Distributed 版；`InProcess.set_down` 两 endpoint 失联达 quorum 通过、再断一节点 publish 拒绝且 backup 保留；`set_cas_epoch_down` 定向注入的 quorum intersection 场景（successor 经交集 endpoint 可见 → restore `:superseded` 不触任何 endpoint）；topology 漂移 → `{:error, {:placement_drift, _}}`；非协议 assemble 回归全绿。

---

## C8 — Multipart.complete 迁移（S3 handler + Console multipart 子路径）

### 修改文件
| 路径 | 改动 |
|---|---|
| `lib/maxio/multipart.ex` | `complete/3` → `assemble_final_object/8` 全部 6 个分支（A1 :503 / A2 :587 / A3 :657 / A4 :726 / A5 :781 的 `Storage.put` + B :828 的 `Storage.assemble`）：把 `opts[:around_object_commit]` 透传进 put_opts/assemble_opts；**不改任何加密/checksum 逻辑** |
| `lib/maxio/s3/handlers/multipart.ex` | `complete_multipart_upload`：外层 `Lock.with_object_lock`（:513）**保留不搬**（D5）；`complete_version_id` 生成点不动（锁内、complete 前）；around 构造 plan（operation `"complete"`）；metadata_tx = `commit_complete_metadata` 改造版——pg 分支加 journal 参数、`transaction_hook` 组合为 `Commit.transaction_hook(journal, 既有 notification/replication enqueue hook)`（同一 PG 事务，Phase 1 同构）；**删除** `cleanup_complete_object_bytes_after_metadata_failure`（:1126–1153）；`cleanup_terminal_upload`（:624/:744）移到 `Commit.run` 成功返回之后、仍在锁内（D3）；`complete_object_meta_extra` / `before_object_commit` 回调原位保留（staging 期执行，先于 publish）；`:sidecar` 分支照旧 |
| `lib/maxio/console/object_upload.ex` | `upload_multipart`/`complete_multipart`：经 complete_opts 传 around（console 无锁 → around 内取 `Lock.with_object_lock`）；console 的 post-complete `commit_metadata` 折叠进 metadata_tx；`cleanup_uploaded_object` 的 multipart 分支**删除** |
| `test/maxio/s3/multipart_complete_mutation_test.exs`（新建） | FS 为主：put 代表分支（A1 FULL_OBJECT、A5 AES256、A2 SSE-C 三选二以上）+ assemble 分支；两条 crash failpoint；console multipart 一条 |

### 关键接线风险（本批第一暂停点条款）
`commit_complete_metadata` 的 attrs 现从 `Multipart.complete` **返回后**的 complete_result 构造，而 metadata_tx 在 `Storage.put/assemble` 内部的 around 回调中执行。executor 必须先审计 attrs 每个字段的 provenance：能从 `(upload, requested_parts, object_meta, write_info, published_result)` 构造的直接搬入 closure；仅在 Storage 返回后才可得的派生值，提前到 `before_object_commit`/object_meta 或预计算。**发现无法前移且会改变持久化形状的字段时，立即暂停上报 orchestrator，禁止自行改语义。**

### 验证命令与验收断言
```powershell
mix compile --warnings-as-errors
mix test test/maxio/s3/multipart_complete_mutation_test.exs
mix test <既有 multipart handler / multipart context / console upload 聚焦回归 + write_authority 回归>
```
断言（**§8 "Complete crash | final object 与 upload cleanup 可恢复" 行的 2A 半边落点**）：
1. put 分支与 assemble 分支快乐路径五位一体（operation="complete"）；ETag/checksum 与现状逐字节一致（attrs provenance 回归证据）。
2. **unversioned 目标已有旧对象 + complete 覆盖 + metadata 注入失败**：旧对象恢复、PG 不变、journal=rolled_back、**Upload 行与 parts 仍在**（客户端可重试 complete）。
3. **PG commit 后 kill**（failpoint `:after_metadata_commit`）→ recovery finalize：final object 保留、PG 行在、journal=finalized；Upload 行残留不阻塞对象可读，可经 abort/重试清理（upload cleanup 的 journal 化收敛归 2B——STATUS 记录本半边边界）。
4. `cleanup_terminal_upload` 时序断言：parts 清理发生在 journal metadata_committed durable 之后（failpoint 在 metadata_tx 内失败时 parts 未被清理）。
5. Console multipart：快乐路径 + metadata 失败旧对象保留。

---

## C9 — 收口批：跨后端代表矩阵、plain-delete 审计、STATUS、唯一一次 precommit

### 新建/修改文件
| 路径 | 改动 |
|---|---|
| `test/maxio/object_mutation/phase2a_matrix_test.exs`（新建，async: false） | 跨后端代表矩阵：Copy 与 Complete（assemble 分支）× {EC, Distributed} describe（`Application.put_env(:maxio, :storage_backend, ...)` + on_exit 还原，B6 备忘 4 同款全局互斥）；每组两场景：metadata 失败保旧目标、PG-commit-后-kill → recovery finalize |
| `docs/superpowers/STATUS.md` | Phase 2A 完成口径 + 遗留清单（见下） |

### 收口任务
1. **矩阵覆盖论证成文**：seam 与 backend 契约已在 Phase 1 三后端锁死、2A caller 接线是 backend-agnostic 的，故 caller 级测试以 FS 为主 + 本批代表性跨后端矩阵兜底；此裁决写入测试文件头注释与 STATUS，供独立 reviewer 质询。
2. **plain delete 静态审计**（审查证据，不造假测试）：grep 全仓确认 7 个 cleanup 点位（`cleanup_copy_object_bytes_after_metadata_failure`、`cleanup_bytes_after_metadata_failure`、`cleanup_report_object` pg 回滚分支、`cleanup_log_object`、`cleanup_uploaded_object`、replication L270 delete、`cleanup_complete_object_bytes_after_metadata_failure`）全部消失；对残余 `Storage.delete` 调用点逐一分类为"正常 delete 操作（2B 迁移）"并列表交独立 reviewer——**"回滚用途"类必须为零**。
3. 日志核对：`Commit.run` 统一打点已覆盖全部 caller；抽查新 operation 值（copy/complete/replicate/rebalance_copy/generated_put）出现在 `mutation_operation` 字段且 formatter 白名单（B7 已加）不丢弃。
4. STATUS 遗留清单：sidecar 写权威协议化归 2B（D1）；access log journal 写放大 + 聚合投递重设计（D2）；Complete 的 upload cleanup journal 化、UploadPartCopy、inventory 跨对象 cleanup delete、replication/rebalance delete-marker 归 2B；rebalance dest 孤儿字节与跨 placement epoch 收敛、source cleanup fence 归 2C；EC 少数盘 claim 残留噪声随 caller 数放大的量级评估。
5. aws-cli 活体清单（隔离环境、heal/rebalance/scanner 关闭，由独立 verifier 执行，executor 只交操作序列）：`aws s3 cp`（单对象）、大文件 cp（multipart complete + aws-chunked）、`aws s3 cp s3://a/k s3://b/k`（copy）、unversioned 桶覆盖 copy、`aws s3api restore-object` SELECT output（如环境可行）。
6. 唯一一次 `mix precommit`。

### 声明口径（完成后只允许）
> Phase 2A byte-producing caller（pg 写权威）已全部进入统一 `ObjectMutation.Commit` seam，publish 后 plain delete 回滚路径已消除，三后端 assemble 已协议化。

不得声明：delete/metadata-only/put_part crash-safe；sidecar 写权威已协议化；upload cleanup 可恢复闭环；heal/rebalance/tombstone 闭环；协议整体闭环。

---

## 硬性不变量 → 实现落点对照表

| 协议不变量 | 落点 |
|---|---|
| 禁止 publish 后 plain delete | C2：`object_writer.ex` cleanup 删除 + `report.ex` pg 回滚分支删除；C3：`object.ex:1724` 删除；C4：`access_log_delivery.ex` cleanup + `object_upload.ex` single 分支删除；C5：`replication_delivery.ex:270-276` 删除；C8：`handlers/multipart.ex:1126` + console multipart 分支删除；每批 §8 "metadata 失败保留旧目标"断言 + C9 grep 审计归零 |
| metadata callback 接收 mutation context 且与 `metadata_committed` 同一事务 | C1 `Commit.transaction_hook/2` 组合器（journal CAS 先行、CAS 失败 `repo.rollback` 整体回滚）；C2–C8 各 metadata_tx 一律经其接入 `put_version_with_id` / `Repo.transaction`；rebalance 的 `update_placement_if_current` 外包事务（C5 断言 2 原子性）；运行期兜底沿用 commit.ex:402 `quarantine_contract_violation` |
| restore 遇 successor 只 `:superseded`，绝不触碰 successor | Phase 1 后端原语继承（B1/B3/B4 已测试锁死，2A 零改动）；caller 级代表断言 C3 断言 4；跨后端矩阵 C9 |
| `nil/:enoent` 不授权 | Phase 1 `EpochStore`/`restore_mutation` 继承；2A 删除的 7 个 plain-delete 点正是旧的"final 缺失/失败即删"违例来源；fresh-dest 场景（rebalance/replication 重试）restore 严格按 manifest 名单回位，绝不以"final missing"推断任何删除（C5 断言）；被 gate 的 sidecar 分支不新增任何以 :enoent 为依据的授权 |

---

## 风险与决策点

**R1 — Sandbox/事务交互。** 全部 caller mutation 测试 `use Maxio.DataCase, async: false`；`Commit.run` 的 journal 各阶段 CAS 是独立事务 + metadata_tx 内嵌事务，均在测试进程内执行（Phase 1 已验证兼容）；scheduler 上下文 caller（inventory Runner spawn、replication drain spawn_monitor、access log register_before_send）测试一律直接驱动函数（`Report.run` / `write_log_object` / `put_replica_object`），不经真实 scheduler；recovery scheduler test.exs 维持 enabled: false；跨后端矩阵批（C9）与 InProcess 全局 ETS 并存必须 async: false。

**R2 — object lock 持有差异。** D5 三分类是本期最大的语义接缝差异源：外层已持锁（Copy/Inventory/Replication/Rebalance）、around 内取锁（AccessLog/Console/PutObject 同构）、multipart 保外层锁。统一验收线 = claim→metadata_tx 在锁内（每批 reviewer 核对）；新增锁均为叶子锁（不嵌套第二对象锁），无死锁面扩大；recovery 持同一锁的第二道防线（B6）对全部新 caller 自动生效。

**R3 — 高频 caller 性能。** 见 D2；executor 不得因性能自行加采样/旁路。EC 少数盘 claim 残留的 `{:partial,_}` 重试噪声（B6 审查项 2）随 caller 数放大——C9 量级评估入 STATUS，2A 不修。

**R4 — 与 Phase 1 已收口路径的回归面。** C1 是唯一触碰 do_put 的批（helper 提取），以 commit_test + put handler 聚焦回归为门；C6/C7 只动 assemble、put publish 分支零改动，各批跑 conformance；C3 与 do_put 共用 `commit_metadata/10`（改动限 journal 参数传递，nil 直通保留至 C3 收口后仅 sidecar 分支使用）。

**R5 — C8 attrs provenance。** 第一暂停点条款（见 C8）；这是全计划唯一预期可能需要 orchestrator 仲裁的结构性风险。

**R6 — 幂等与重试语义。** replication（outbox at-least-once）与 inventory（lease 重试）在 seam 化后重试 = 全新 mutation（新 mutation_id、更高 generation），协议天然支持；executor 不得为重试复用旧 journal 行。

**R7 — 编译串行纪律。** 九批严格串行，每批一个 executor 一次完成；聚焦验证 + 每批独立审查；`mix precommit` 仅 C9 一次；所有 mix 命令前置 `$env:ERL_FLAGS="-kernel standard_io_encoding unicode"`。

**决策点汇总（executor 遇到时按此裁决，不得自行改协议语义）：**
1. sidecar 写权威 = 2B（D1），任何"顺手接线"一律拒绝。
2. 高频 caller 照常 journal 化（D2），性能问题记 STATUS 不改行为。
3. parts 清理只挪时序不 journal 化（D3）。
4. rebalance 只做 destination copy + placement 同事务；delete-marker copy、source cleanup 零接触（D4）。
5. 锁按 D5 三分类，multipart 不搬锁。
6. operation 字符串按 D6 集合，无 migration。

---

## 范围控制（明确排除 + 遗留项编入确认）

排除（2B）：`put_part`/part replacement/Abort upload fence、UploadPartCopy、metadata-only（`ObjectMetadataSidecar.update` 全家）、`put_delete_marker`/current delete/`delete_version`/tombstone、delete marker replication 与 rebalance delete-marker copy、inventory 跨对象 cleanup 的 delete 协议化、Complete 的 upload cleanup journal 化、sidecar 写权威协议化。
排除（2C）：read barrier、heal/fresh-drive heal、tombstone/backup/journal GC、rebalance source cleanup fence、跨 placement epoch 收敛。

批间备忘分配给 Phase 2A 的遗留项编入：B3 审查项 3（`publish_controlled_replace` 窄 case 收口）→ **C1**；NEXT-3（recovery 释放租约构造性测试）→ **C1**；sidecar 写权威归属裁决 → **D1 成文 + C9 STATUS**。

---

## 交付物清单（供 orchestrator 逐批验收）

| 批次 | 一句话验收口径 |
|---|---|
| C1 | seam 胶水共享化且 do_put 零回归；EC/Distributed 窄 case 结构化返回；NEXT-3 租约即释测试绿 |
| C2 | ObjectWriter + Inventory 进 seam，§8 两行 FS 落点绿，跨对象 abort 语义有注释与测试锁定 |
| C3 | CopyObject 进 seam，§8 Copy 行 + successor 代表断言绿，plain delete 点消失，SSE/自拷贝零回归 |
| C4 | AccessLog + Console single put 补锁进 seam，best-effort 语义保持，§8 AccessLog 行绿 |
| C5 | Replication + Rebalance dest copy 进 seam，placement 与 journal 同事务断言绿，source cleanup 零接触 |
| C6 | FS/EC assemble 协议分支绿，非协议 assemble 逐字节零回归 |
| C7 | Distributed assemble 经 Transport 达 quorum、placement snapshot 契约不破，回归零 |
| C8 | Multipart complete 六分支进 seam，§8 Complete crash 行 2A 半边绿，parts 清理后移，attrs 逐字节零漂移 |
| C9 | 跨后端代表矩阵绿、plain delete 审计归零、STATUS/遗留清单落笔、唯一一次 mix precommit；对外声明严格限于允许口径 |