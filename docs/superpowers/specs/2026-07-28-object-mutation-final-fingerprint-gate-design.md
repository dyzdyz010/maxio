# ObjectMutation P1-CLOSEOUT-B — final 实际 fingerprint gate 设计

> 日期：2026-07-28  
> 状态：批准实施  
> 范围：普通、PG 写权威的 PutObject；FS / ErasureCoded / Distributed 三后端  
> 上位协议：`docs/superpowers/plans/2026-07-10-object-mutation-protocol.md`  
> 本文是对上位协议“所有 finalize 失败均可成功返回”表述的收窄修订：只有 final 已获 durable proof 后的纯清理失败才可延后。

## 1. 问题与目标

现有协议先把 backend epoch 写成 `published`，再原子发布 final，随后直接提交 PG metadata；`finalize_mutation` 只核对 token/phase，就把 epoch 写成 `committed` 并删除 backup。它没有从 final 目录读取实际 sidecar，也没有确认 `part.0` 的物理形状。于是 rename 后的 final 若缺失、撕裂或与 journal/epoch fingerprint 分叉，请求仍可能返回 200，并删除唯一恢复证据。

AWS S3 对成功 PutObject 的约束是：成功响应表示完整对象已经加入，单 key 更新原子可见，成功 PUT 后的 GET/LIST 立即可见。因而本批目标是：

1. 在 PG metadata 提交前，从 final 实际文件取得 proof；proof 失败时仍处于可回滚区，绝不返回 200。
2. finalize 在删除 backup 前复用同一 proof，抵御发布 proof 与最终清理之间的漂移。
3. 区分 proof failure 与 proof 后的 cleanup failure，避免继续吞掉所有 finalize 错误。
4. 保持 backend 插件边界、对象字节流式管线、fencing/quorum 与历史 placement 不变量。

官方语义依据：

- AWS PutObject：<https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html>
- AWS S3 consistency：<https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel>
- AWS 503 retry guidance：<https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance-guidelines.html>
- MinIO S3 error table：<https://github.com/minio/minio/blob/master/cmd/api-errors.go>

## 2. 核心裁决

### D1 — proof 是 backend behaviour，不进入 Commit 的布局知识

新增：

```elixir
Maxio.Storage.Backend.verify_published(ctx, opts)
Maxio.Storage.verify_published(ctx, opts)
```

返回：

```elixir
{:ok, {:verified, proof_summary}}
| {:ok, {:degraded, proof_summary}}
| {:ok, {:superseded, proof_summary}}
| {:error, {:published_proof_failed, class, evidence}}
```

`class` 只允许 `:unavailable | :mismatch | :corrupt | :fenced | :placement_drift`。`proof_summary` 是有界、可 JSON 化、无对象内容/密钥/完整绝对路径的纯数据；至少含 string-key 的 `status`、`required`、`verified`、`observed_owned`、`unavailable` 与有界 `degraded` endpoint 摘要。

`finalize_if_current/2` 的新唯一返回契约是：

```elixir
{:ok, {:finalized, proof_summary}}
| {:ok, {:cleanup_pending, proof_summary}}
| {:ok, {:superseded, proof_summary}}
| {:error, {:published_proof_failed, class, evidence}}
```

`cleanup_pending` 表示全局 proof 已满足 quorum，因少数 endpoint 尚未证明/清理或 epoch/backup 清理失败而保留 durable debt；它不是 proof failure。`ObjectCommit.Control` 适配规则固定为：三个 `{:ok, {_outcome, _summary}}` 都折叠成 callback `:ok`，proof error 原样返回 `{:error, reason}`。Commit/Recovery 仍依据完整 backend 返回值决定 journal 是否终态，不能用 Control 的折叠结果代替 durable 裁决。

`Commit` 只编排该契约，不读取 `meta.json`、不理解 shard index、不解析 topology。FS、EC、Distributed 分别实现 callback。

### D2 — published journal 只代表 proof 已通过

请求路径固定顺序：

```text
backend publish（epoch published + final atomic rename）
→ 用 publish 返回的 fingerprint 丰富临时 MutationContext
→ Storage.verify_published
→ journal claimed → published
   attrs = published_fingerprint + proof summary
→ metadata_tx（Objects/outbox/quota + journal metadata_committed 同事务）
→ journal finalize_pending
→ Storage.finalize_if_current（同一 proof 的 defense-in-depth）
→ epoch committed + backup cleanup
→ journal finalized
→ HTTP 200
```

proof 在 journal `published` 之前运行的理由：

- crash 在 publish 与 proof/transition 之间时，journal 仍是 `claimed`，Recovery 安全 restore；
- future sidecar-authority 路径不会把“尚未证明的 published journal”误当逻辑提交；
- proof summary 可与 fingerprint 一次 CAS 写入 journal，无需新 phase/schema；
- 与 AWS 成功语义一致：metadata 与成功响应都在 proof 之后。

同步路径必须在写入 `published_fingerprint` 后从 fresh journal 重新构造 `MutationContext`；不得继续使用 claimed 阶段的旧 context。三个 backend 注册进 `ObjectCommit.Control` 的 finalize 闭包也必须捕获带 fingerprint 的 context。

### D3 — A+ 热路径 proof；bitrot 全量校验留给 scrub/heal

现有 fingerprint 定义为：

```text
top-level core etag + top-level core size + SHA256(exact raw meta.json bytes)
```

本批 A+ proof 检查 exact fingerprint 与物理形状，不在每次 PUT 后重读完整对象或全部 shard：

- 避免每次 PUT 双倍数据 I/O；
- 避免大对象读取长时间占住 `EpochStore` partition worker；
- EC/Distributed 不额外放大网络与磁盘故障面；
- 写入流已经边写边生成 core SHA256/MD5 与 shard block hashes，后续全量 bitrot 检测由既有 scrub/heal 负责。

A+ 明确不能发现“同长度 payload 被静默翻位但 sidecar 未变”。交付声明不得称其为 cryptographic payload readback proof。

### D4 — endpoint primitive 在同一短串行段内取证与 finalize

`ShardServer` / `EpochStore` 新增本地 `verify_mutation` primitive。请求必须包含：

```elixir
%{
  target: target,
  token: token,
  mutation_id: mutation_id,
  final_rel: final_rel,
  expected_fingerprint: published_fingerprint,
  layout: %{kind: "fs"} | %{kind: "shard", index: non_neg_integer()}
}
```

endpoint 内按固定顺序：

1. 读取 epoch；absent/损坏结构化失败。
2. 比较 token；successor 立即返回 `:superseded`，不读取/触碰 final 或 backup。
3. standalone publish proof 要求 phase 为 `published` 或幂等重放的 `committed`，且 epoch fingerprint 与 request fingerprint 精确相等。finalize 另允许同 token `claimed` repair：claimed epoch 不计 initial proof quorum；metadata 已提交后的 finalize 只有在 actual final 精确匹配 request/journal fingerprint 时，才可把该 endpoint 直接收敛为带 fingerprint 的 `committed` 并清 backup。claimed final 缺失/不匹配时保持 cleanup debt，等待 heal 后重试。
4. 从 `final_rel` 定位 final，先用 `lstat` 拒绝 symlink/非 regular，并执行 16 MiB hard limit；只读取至 limit+1，取得 exact raw `meta.json` 后再 decode。
5. 从 top-level durable core 取 `etag`/`size`，以 raw sidecar 字节重建 actual fingerprint；禁止使用 `versions` 中 S3-visible 的 ETag/size。
6. 三方比较：request/journal == epoch == actual final。
7. 校验 `part.0` 是 regular file：
   - FS：大小等于 top-level core stored size；
   - shard：按本 endpoint 的固定 ordinal 精确查找 `shards[i]`，大小等于 `shard_file_size`。
   - 零字节对象仍必须有零长度 `part.0`。
8. 普通 object 之外的 value type 显式拒绝；未来 delete marker/meta-only 必须另行设计豁免，不能隐式放宽。

`finalize_mutation` 在同一个 `EpochStore` 串行闭包内复用步骤 1–8。proof 成功后才写 committed epoch，再删除 backup。committed 幂等重放也必须先复验，不能直接删 backup。

Transport 只新增有界 proof RPC，不回传对象/shard 内容。Distributed 只使用 `ctx.placement_snapshot` 的历史 set/topology；禁止回退当前 router。

### D5 — quorum 与降级语义

FS 要求 1/1 proof。

EC/Distributed 中，一个 endpoint 只有同时满足 exact epoch、exact raw sidecar fingerprint 和本 ordinal 的物理 shard 形状，才计为 verified。成功数必须达到既有：

```text
epoch_quorum = max(write_quorum, floor(n / 2) + 1)
```

因此同一 verified 集同时满足数据 write quorum 与 epoch 交集不变量。少数 unavailable/mismatch endpoint 不计成功、不得清其 backup；健康 proof 仍达 `epoch_quorum` 时允许 degraded success，并把有界摘要写入 journal/log，交 scrub/heal 修复。低于 quorum 时整体失败。

degraded success 不能把 journal 直接标成 `finalized`：尚未证明的 endpoint 可能仍持有 published epoch 与 durable backup。请求可以按 quorum 语义成功，但 journal 保持 `finalize_pending`，Recovery 在 heal/端点恢复后继续复验并清理。

当前 journal 没有 durable participant bitmap，而且 publish 顺序允许 manifest/backup 已建立但该 endpoint 的 epoch CAS 未成功。因此本批可证明的终态集合定义为：

- placement 中所有当前可观察到同 token 的 owned endpoint 均已证明并清理；其中 `claimed` 必须经过上述 final-exact claimed repair 后才算清理；
- 没有 unresolved/unavailable endpoint；
- committed/finalized endpoint 仍至少达到 `epoch_quorum`。

epoch absent、旧 token 或从未参与的 endpoint 不构成 destructive 授权，也不阻塞 journal 终态；若它持有 manifest-only/backup-only 残留，本批只记录有界 orphan hint，交后续 mutation-backup orphan GC。禁止为了“清干净”而在 absent/旧 token 上删除 backup。same-token `claimed` 则不是 orphan：它由 exact-final repair 收敛；在 heal 前一直保持 `finalize_pending`。精确 participant 持久化不塞入本批，也不与 P1-CLOSEOUT-C 的 placement durability 混做。

全局 proof 分类顺序固定，禁止因遍历/返回顺序不同而把同一证据随机映射成 500 或 503：

1. quorum 预裁决或任一 endpoint proof 观察到 successor：全局 `:superseded`，立即短路/重新裁决，绝不能把 successor 当少数 degraded failure。
2. `verified >= epoch_quorum`：proof 成功；有失败 endpoint 时是 degraded success。
3. `verified + unavailable >= epoch_quorum`：当前证据仍可能在端点恢复后达到 quorum，分类 `:unavailable`。
4. 否则若存在 owned-token 的 mismatch/corrupt：quorum 已不可能由未知端点补足，分类确定性 mismatch/corrupt。
5. 其余不足 quorum：分类 `:unavailable`。

因此下表中的 mismatch/corrupt 指“按上述全局顺序裁决后的整体 proof failure”，不是健康 quorum 之外的少数坏副本。

finalize 聚合必须区分：

- `proof_passed`：endpoint proof 已通过，但 epoch 写入或 backup 删除失败；
- `finalized`：proof 与清理均成功；
- `proof_failed`：unavailable/mismatch/corrupt/fenced。

若 proof-passed endpoint 不足 quorum，整体是 proof failure；若 proof-passed 达 quorum但 finalized 不足 quorum，或仍有 unresolved/owned endpoint debt，整体是 `cleanup_pending`。只有达到上面的可证明终态集合才返回 `finalized`。这样不会把证据不足伪装成“只是删 backup 失败”，也不会越过 absent-token destructive 防线。

### D6 — 错误与 HTTP 语义

| 场景 | journal/磁盘动作 | HTTP |
| --- | --- | --- |
| metadata 前 proof unavailable / quorum 不足 | request rollback；保留失败证据 | 503 `SlowDownWrite` |
| metadata 前 proof mismatch/corrupt | request rollback；详细证据只进结构化日志 | 500 `InternalError` |
| metadata 后 defense proof unavailable | 不回滚；`finalize_pending` + retry | 503，绝不 200 |
| metadata 后 defense proof mismatch/corrupt | 不回滚；quarantine；保留 backup | 500，绝不 200 |
| proof 已达 quorum，但有少数 endpoint 尚未证明/清理，或 epoch 写/backup 删除失败 | `finalize_pending`，Recovery/heal 后重试 | 可返回 200 |
| successor | 不读/不碰 successor；按既有 superseded evidence 收敛 | 请求路径 503 |

S3 handler 必须显式映射上述错误，使用稳定公共文案；禁止把 `inspect(reason)`、drive/backup 路径或 sidecar 内容写入 XML。结构化日志保留 bucket/key/request_id/mutation_id/backend/action/class/count，不记录对象 body、密钥或 SSE envelope。

successor 的阶段语义固定：

- metadata 前：不得转 `published`/提交 metadata；请求 rollback，restore 以 superseded evidence 收敛，HTTP 503。
- metadata 后同步路径：绝不 rollback；journal 以 superseded evidence 终态收敛，但当前请求返回 503。
- Recovery：以 superseded evidence 终态收敛；它没有 HTTP 响应。

低层错误分类固定：

| endpoint 事实 | proof class |
| --- | --- |
| timeout、节点失联、`:eacces`、`:eio`、读取/`lstat` 暂时失败 | `:unavailable` |
| raw fingerprint、core etag/size、part/shard size 与 expected 不同 | `:mismatch` |
| meta/part 缺失、JSON/shape 非法、symlink/非 regular、sidecar 超 16 MiB、invalid internal request、epoch absent/旧 token | `:corrupt` |
| greater token / successor | `:fenced`，折叠为全局 superseded |
| frozen placement 非法或 topology hash 漂移 | `:placement_drift` |

所有 evidence 先经 `PublishedProof` 限界/脱敏。journal 固定保存：

```elixir
%{
  "published_proof" => proof_summary,
  "last_failure" => failure_summary_or_nil
}
```

`degraded` 最多 32 条，额外数量放 `"omitted"`；整体必须通过 Journal 既有 JSON-safe/64 KiB gate。后续 `mark_error`/quarantine 必须 merge 更新 `"last_failure"`，保留初始 `"published_proof"`，不得整图覆盖。

### D7 — Recovery 复用同一 callback

Recovery 不实现第二套 proof：

- 进入 finalize 前先调用 `Storage.verify_published/2`；
- unavailable → `mark_error` 可重试；
- 全局 proof 分类为 mismatch/corrupt/placement drift → quarantine；少数 mismatch 已被健康 quorum 覆盖时只记录 degraded debt，不隔离整条 mutation；
- successor → 既有 superseded 收敛；
- finalize 返回 proof failure 时沿同一分类；
- cleanup failure 只 `mark_error`，保留 `finalize_pending`。

CLI 继续读取 journal 的 `published_fingerprint` / `recovery_evidence`，展示 proof 阶段、required/verified 与降级摘要；无需 migration。

## 3. 测试与验收

### Endpoint / backend

- raw sidecar 任意字节变化，即使 decode 后 etag/size 相同，也必须 mismatch。
- request/journal 与 epoch 不同，即使 final 匹配 epoch，也必须拒绝。
- `meta.json` 缺失、损坏、symlink、非 regular、超过 16 MiB；`part.0` 缺失、非 regular、截短或加长。
- FS 零字节对象必须存在空 part；SSE 使用 stored/core size；multipart-visible ETag 不得污染 core proof。
- committed replay：正常+backup 存在、正常+backup 已无、异常+backup 存在、cleanup 首次失败后重试。
- successor 在任何 final 读取前短路。
- EC/Distributed：exact quorum、低于 quorum、少数 mismatch/unavailable、sidecar 分叉、ordinal 错配。
- Distributed placement drift fail closed，且 RPC 返回有界摘要。

### Orchestration / HTTP

- metadata 前 proof 失败：旧 bytes 恢复、PG 无新行、backup/epoch/journal 按 rollback 收敛。
- metadata 后 defense mismatch：不回滚、不返回 200、backup 保留、journal quarantined。
- proof 后 cleanup-only failure：请求成功、journal `finalize_pending`，Recovery 最终 finalized。
- 普通 signed PUT 与自签 aws-chunked PUT 覆盖 200/503/500，断言 XML 不泄露内部 reason/path。
- 测试用 monitor、消息或 `:sys.get_state/1` 同步，禁止 `Process.sleep/1`。

### 批量 gate

实现期只跑 focused tests、`mix compile --warnings-as-errors` 与必要 format。所有实现任务独立审查闭环后，由全新 verifier 执行一次完整 `mix precommit`。

## 4. 非目标与后续

- 不处理 P1-CLOSEOUT-C（Distributed claim 前 durable placement snapshot）。
- 不迁移 Phase2A assemble/multipart complete，也不碰 delete/meta-only/tombstone。
- 不新增 migration、不改 IAM、S3 Request/Response 或对象 body 流式 reader。
- 不把少数 degraded endpoint 的数据修复塞进提交路径；由 scrub/heal 处理。
- 不实现 manifest-only/backup-only orphan GC；本批只在 absent/旧 token 时坚持不破坏并记录有界 hint。
- 本批只能声明 P1-CLOSEOUT-B 收口，不能声明 ObjectMutation Phase 1、全局写路径或 MinIO 全兼容完成。
