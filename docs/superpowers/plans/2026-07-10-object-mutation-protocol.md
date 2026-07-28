# ObjectMutation：对象变更耐久提交协议

日期：2026-07-10
状态：设计计划，待实现与独立审查

## 1. 背景与目标

当前 `ObjectCommit` 已解决 PutObject 请求 body 必须由 Bandit request owner 消费的问题，并能在同步 metadata 失败时恢复旧对象。但正式审查仍为 `REQUEST CHANGES`：

- 只有普通 `Storage.put/5` 写入进程内 `object_commit_identity`；Copy、Multipart、delete marker、永久删除、metadata-only、heal、rebalance 等后继写入无法可靠隔离迟到 rollback。
- 删除后 final sidecar 消失，`nil/:enoent` 不能证明“仍由旧 mutation 所有”；迟到 rollback 可能复活已删除对象。
- PG transaction 已提交、`Control.mark_committed/1` 尚未执行时存在崩溃窗口，可能形成“PG 指向新对象、字节恢复成旧对象”的永久分裂。
- rollback/finalize 失败只有进程内日志，没有耐久重试入口。
- CopyObject、`ObjectWriter`、Multipart Complete 等仍采用“先覆盖、metadata 失败后 plain delete”，会丢失未版本化目标的旧对象。

本计划建立统一 `Maxio.ObjectMutation` 状态机，使所有对象变更共享以下语义：

1. 每次变更都有持久 `mutation_id + generation` fence。
2. 删除留下对象 final 目录之外的 durable tombstone。
3. backend 只能通过 CAS 操作恢复、删除或 finalize 当前 mutation。
4. PG metadata transaction 与 journal 的 `metadata_committed` 在同一事务提交。
5. crash recovery 根据 journal 与 backend epoch 作确定性决策，不依赖进程是否存活。
6. FS、ErasureCoded、Distributed 只实现同一 behaviour；handler 不感知后端细节。

## 2. 范围与非目标

协议覆盖：

- 普通 PutObject、CopyObject、server-generated `ObjectWriter`；
- Multipart `put_part`、part replacement、assemble、Complete、Abort；
- delete marker、未版本化删除、显式 version delete；
- ACL、tagging、Object Lock、restore、replication status、storage class 等 metadata-only 更新；
- replication delivery、inventory、access log、Console upload；
- heal、fresh-drive heal、rebalance/decommission copy 与 source cleanup。

不在本协议内：

- bucket 配置、IAM、notification/replication outbox 自身的行级状态机；
- bucket 目录的创建和删除；
- 只读请求。

notification retained ledger 继续使用稳定 outbox id 保证幂等，但其写入/回滚必须挂到对应 ObjectMutation，不能独立决定对象提交结果。

## 3. 核心不变量

### 3.1 Fence

每个 mutation token 为：

```elixir
%{
  generation: non_neg_integer(),
  mutation_id: Ecto.UUID.t()
}
```

token 按 `{generation, mutation_id}` 全序比较。新 claim 使用可见最大 generation 加一；相同 generation 的并发 claim 由 `mutation_id` 打破平局。

endpoint 仅接受大于当前 token 的 claim。publish、rollback、delete、finalize 必须要求当前 token 精确等于调用者 token，并校验允许的 epoch phase。两个 write quorum 必有交集，因此旧 token 在后继 token 建立后不能再次达到 destructive quorum。

现有 sidecar entry `"generation"` 与 durable mutation generation 收敛为同一个逻辑代际：

- 新内容、metadata-only、delete marker、逻辑删除、rebalance 均递增；
- heal 只是修复同一 logical value，必须保留 generation 与 mutation_id，绝不递增或降级；
- legacy sidecar 缺少 token 时按 generation `0` 迁移，但不能把 `nil` 当成 rollback 所有权。

### 3.2 Durable epoch 与 tombstone

epoch 不存放在对象 final 目录中。建议路径：

```text
<drive>/.maxio-object-epochs/<bucket>/<encoded-key>/<encoded-version>/epoch.json
```

multipart part 使用独立 target kind，并将 `upload_id/part_number` 编入路径。

epoch 至少包含：

```json
{
  "format": "maxio/object-epoch/1",
  "target_kind": "object_version",
  "generation": 42,
  "mutation_id": "...",
  "operation": "put",
  "phase": "claimed|published|committed|rolled_back|deleted|quarantined",
  "value_type": "object|delete_marker|deleted",
  "fingerprint": {"etag": "...", "size": 123, "sidecar_sha256": "..."},
  "previous_token": {"generation": 41, "mutation_id": "..."},
  "updated_at": "..."
}
```

删除只清理 S3-visible `part.0/meta.json`，epoch 保留 `value_type=deleted`。read/list/scanner/heal 必须先用 epoch quorum 过滤 stale sidecar；不能仅因某个 endpoint 仍有旧 `meta.json` 就复活对象。

备份放在独立耐久目录：

```text
<drive>/.maxio-object-mutations/<mutation_id>/
```

其中保存 manifest、旧 part/meta 与 previous token。generic `.tmp` 清理不得删除尚有非终态 journal 的目录。

### 3.3 Backend CAS

新增统一 backend mutation contract，具体命名可在实现时微调，但语义不得拆散：

```elixir
claim_epoch(target, proposed_token, operation, opts)
current_epoch(target, opts)
publish_if_current(context, staged, value, opts)
delete_if_current(context, opts)
restore_if_current(context, opts)
finalize_if_current(context, opts)
quarantine(context, reason, opts)
```

要求：

- FS：本地一份 durable epoch，操作在 `ShardServer` 的串行临界区中完成并 fsync。
- EC：epoch、publish、restore、delete、finalize 均须达到 write quorum。
- Distributed：复用 Transport RPC；placement snapshot 在 claim 与 publish 时复核，recovery 使用 journal 保存的历史 placement，不按当前 router 猜测。
- `restore_if_current` 遇到 successor、token mismatch 时只返回 `:superseded`，绝不触碰 successor。
- endpoint 不可达、epoch 损坏、fingerprint 不符或 quorum 不足时保留 backup，转 `quarantined/retryable`；禁止把 `nil/:enoent` 当成可恢复授权。

### 3.4 PG journal

使用 `mix ecto.gen.migration create_object_mutations` 生成迁移，创建 `object_mutations`。建议字段：

- `id`：binary UUID，同时作为 mutation_id；
- `target_kind`：`object_version|multipart_part|multipart_upload`；
- `bucket_name`、`object_key`、`version_id`；
- `upload_id`、`part_number`；
- `generation`、`operation`、`authority_mode`；
- `phase`；
- `backend`、`placement_snapshot`、`previous_epoch`、`published_fingerprint`；
- `attempts`、`next_attempt_at`、`lease_owner`、`lease_expires_at`；
- `last_error`、`metadata_committed_at`、`finalized_at`；
- `inserted_at`、`updated_at`。

状态列先使用 string + CHECK constraint，避免引入不必要的 Postgres enum：

```text
prepared
claimed
published
metadata_committed
finalize_pending
finalized
rollback_pending
rolled_back
quarantined
```

索引至少包括：

- `(phase, next_attempt_at)` recovery claim；
- `(bucket_name, object_key, version_id, inserted_at)` operator 取证；
- `(upload_id, part_number)` multipart recovery；
- mutation id 主键。

表、每个列、索引和 CHECK constraint 必须有中文 COMMENT；down 中清除显式 COMMENT 后再删除对象。

## 4. 状态机

正常 PG-authority 路径：

```text
prepared
  -> claimed
  -> published
  -> metadata_committed   # 与 Objects/outbox/quota 同一 Ecto transaction
  -> finalize_pending
  -> finalized
```

失败路径：

```text
prepared|claimed|published
  -> rollback_pending
  -> rolled_back
```

无法安全判断时：

```text
任意非终态 -> quarantined
```

`metadata_committed` 是 rollback 禁止线。PG transaction 一旦提交，任何 Control DOWN 或 lease lost 都只能 finalize/retry，不能恢复旧字节。

Sidecar-authority 路径中，backend epoch 达到 published write quorum 即 logical authority commit。PG index 失败仍是 best-effort；recovery 看到 `authority_mode=sidecar` 且 durable epoch 已 published 时必须 finalize，不能因 journal 尚未写到 `metadata_committed` 而 rollback。

所有 journal phase 更新使用 SQL CAS，例如 `WHERE id=? AND phase IN (...)`，重复 recovery 必须幂等。

## 5. Control 与 recovery

`ObjectCommit.Control` 降级为同请求内的加速器，不再承担 correctness：

- Control 创建时立即持有 staging discard callback，覆盖 owner 在 publisher 注册前死亡的窗口。
- backend 在第一次 destructive IO 前同步注册 durable mutation context。
- `mark_committed/1` 只能在 journal 已 durable `metadata_committed` 后调用。
- owner/publisher DOWN 调用 `ObjectMutation.request_rollback/1`；最终决定仍由 journal + backend CAS 作出。
- callback 错误写入 journal `last_error/next_attempt_at` 并打结构化日志，不能丢弃。
- finalize 失败保持 `finalize_pending`，请求可成功，但必须由 recovery 收敛。

新增 recovery worker，复用现有 outbox 的 `FOR UPDATE SKIP LOCKED`、lease、attempt/backoff 模式：

- `metadata_committed/finalize_pending`：`finalize_if_current`；
- PG-authority 的 `published`：`restore_if_current`；
- sidecar-authority 的 quorum-published：finalize；
- successor 已建立：标记本 mutation 为 `finalized/rolled_back` 的 superseded 结果，不触碰 final；
- epoch/quorum/fingerprint 模糊：quarantine 并报警。

recovery 获取与请求路径相同的 `{bucket,key}` object lock，但 correctness 仍依赖 durable fence，而不是 lease 本身。

## 6. 分批实施

### Phase 1：当前 external-client PutObject closeout 的最小安全批次

这是一个 coherent batch，目标仅是闭合普通 PutObject 的 body-owner、PG crash window 与可恢复 rollback：

1. 增加 journal migration/schema/context API。
2. 增加 epoch 编解码、target/token/fingerprint 公共契约。
3. 为 FS、EC、Distributed 实现普通 `put` 的 claim/publish/restore/finalize CAS。
4. 普通 PutObject 改由 `Maxio.ObjectMutation` 编排：
   - body 在 request owner 中完整 staging；
   - object lock 内 claim、quota/precondition、publish；
   - `Objects.put_version_with_id`、notification/replication outbox、quota 与 journal `metadata_committed` 同事务；
   - 删除 metadata 失败后的 plain `Storage.delete`。
5. Control 接入 durable journal，并实现 recovery worker。
6. 增加 status/recover CLI、结构化日志与 failpoint。

Phase 1 验收：

- FS/EC/Distributed 普通 Put 的同步 metadata failure、owner DOWN、publisher DOWN、lease lost、PG commit 后 kill、finalize failure 均能恢复或由 recovery 收敛。
- PG commit 后、`mark_committed` 前 kill 最终必须保留新字节。
- metadata commit 前 kill 最终必须恢复旧字节。
- stale rollback 遇到另一个协议化 Put successor 时不触碰 successor。
- 真实 Bandit ordinary signed PUT 与 aws-chunked PUT 通过。
- aws-cli、mc、boto3 的 Put/Head/Get/List 顺序矩阵通过，临时 mc config 与测试桶清理完成。

Phase 1 的 external matrix 必须在 heal、rebalance、scanner destructive cleanup 未并发运行的隔离环境中执行。

完成 Phase 1 后只允许声明：

> 普通 PutObject 的 external-client closeout 与三后端 durable recovery 路径已通过。

不得声明：

- ObjectMutation 已覆盖全部对象写入；
- CopyObject、Multipart、delete、metadata-only 已 crash-safe；
- MinIO 全兼容或 production-ready；
- heal/rebalance 与 tombstone 已闭环。

### Phase 2A：迁移所有 byte-producing caller

所有调用者必须进入同一个 around-mutation seam，禁止 publish 后自行 plain delete：

- CopyObject；
- `Maxio.S3.ObjectWriter` 及 Restore/Select 等 generated object；
- access log delivery；
- inventory report；
- Console single-object upload；
- replication delivery；
- rebalance destination copy；
- `Multipart.complete` 中全部 `Storage.put` 分支及 `Storage.assemble` 分支。

metadata callback 必须接收 mutation context，并在同一事务标记 `metadata_committed`。

### Phase 2B：Multipart part、metadata-only 与 delete

- `put_part` replacement 使用 multipart-part epoch；`Multipart.put_part` 行提交与 journal 同事务。
- Abort 留 upload-level fence，不能与迟到 part publish 交错。
- assemble/Complete 使用 object-version epoch；只有 final object `metadata_committed` 后才能清理 upload parts。
- `ObjectMetadataSidecar.update` 进入统一 mutation，覆盖 ACL、tagging、Object Lock、restore、replication status、storage class 等全部调用者。
- `put_delete_marker`、current delete、`delete_version` 使用 durable tombstone。
- lifecycle、replication marker/delete、Console delete、inventory cleanup 全部迁移。
- 删除路径的 notification/replication outbox 与 journal authority transition 同事务。

### Phase 2C：read barrier、heal、rebalance 与 GC

- GET/HEAD/LIST/scanner 仅接受与 canonical committed epoch token 一致的 sidecar。
- tombstone 达 read quorum时对象不可见；旧 sidecar 不得参与 reconcile。
- heal 复制 canonical generation/token，只修复低代或缺失副本；遇到更高 token 必须跳过并报警。
- fresh-drive heal 同样先同步 epoch/tombstone，再修复 part/meta。
- rebalance/decommission 作为新 mutation 递增 generation；placement PG 更新与 `metadata_committed` 同事务。
- source cleanup 仅在 destination mutation committed 且仍为 current token 时执行。
- scanner reverse-GC 必须同时检查 tombstone、journal 与 backup manifest；“所有 final missing”不再单独构成删除/恢复依据。
- tombstone/backup GC 仅处理终态、超过 retention、无 active journal、无 pending replication/recovery 的记录。

完成 Phase 2 后，Storage backend 应默认拒绝缺少 mutation context 的对象 destructive mutator；heal 使用显式 `repair` context。通过静态 inventory 测试保证没有绕过入口。

## 7. CLI 与结构化日志

新增：

```text
mix maxio.object_mutations.status [--bucket B --key K --mutation-id ID] [--json]
mix maxio.object_mutations.recover --dry-run [--limit N --older-than SECONDS]
mix maxio.object_mutations.recover --execute [--mutation-id ID]
```

CLI 必须展示 journal phase、backend epoch quorum、placement snapshot、backup 是否存在、建议动作；默认只读，`--execute` 才执行恢复。

日志固定字段：

```text
action
request_id
mutation_id
mutation_generation
mutation_operation
mutation_phase
authority_mode
backend
bucket
key
version_id
placement_set_id
outcome
reason
```

关键事件：claim、publish quorum、metadata committed、rollback requested/result、finalize result、recovery decision、quarantine、tombstone GC。绝不记录对象 body、密钥或完整 SSE envelope。

## 8. 测试矩阵

每项至少覆盖 FS、EC、Distributed：

| 场景 | 必须断言 |
|---|---|
| 新 Put 成功 | bytes/sidecar/PG/journal/epoch 同一 token |
| overwrite metadata 失败 | 旧 bytes/sidecar 恢复，PG 不变 |
| PG commit 后进程 kill | 新 bytes 保留，recovery finalize |
| successor Put 后旧 rollback | successor 不变 |
| successor delete 后旧 rollback | tombstone 保留，不复活 |
| Copy/ObjectWriter/Inventory/AccessLog | metadata 失败保留旧目标 |
| Multipart part replacement | part 行失败恢复旧 part |
| Complete crash | final object 与 upload cleanup 可恢复 |
| metadata-only 并发 | generation 单调，旧 updater CAS 失败 |
| delete marker/version delete | tombstone quorum，旧副本不可见 |
| endpoint/quorum 故障 | 不猜测、不破坏，backup 留存 |
| finalize/rollback IO 失败 | journal 可重试，CLI 可取证 |
| heal | 不降 generation、不覆盖 tombstone |
| rebalance | placement 与 journal 同事务，source cleanup 有 fence |

测试不得使用 `Process.sleep/1`；进程崩溃用 monitor/failpoint 精确同步。Distributed 需覆盖不同 endpoint 子集形成的 quorum intersection 与 topology drift。

最终收口顺序：

1. 聚焦 contract/backend/recovery 测试；
2. `mix compile --warnings-as-errors`；
3. mutation caller 集成矩阵；
4. 独立 reviewer 审查；
5. fresh isolated build 下 aws-cli/mc/boto3 活体矩阵；
6. 更新 `STATUS.md`/`TODO.md`；
7. coherent batch 最后仅运行一次完整 `mix precommit`。

只有 Phase 2 全部完成、静态 inventory 无绕过路径、独立审查 APPROVED 后，才可声明 ObjectMutation 协议闭环。
