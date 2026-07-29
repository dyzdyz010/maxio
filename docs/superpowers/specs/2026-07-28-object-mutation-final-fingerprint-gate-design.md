# ObjectMutation P1-CLOSEOUT-B — final 实际 fingerprint gate 设计

> 日期：2026-07-28  
> 状态：批准实施  
> 范围：所有已接入 `ObjectMutation.Commit` 的普通对象、PG 写权威路径；FS / ErasureCoded / Distributed 三后端
> 上位协议：`docs/superpowers/plans/2026-07-10-object-mutation-protocol.md`  
> 本文是对上位协议“所有 finalize 失败均可成功返回”表述的收窄修订：只有 final 已获 durable proof 后的纯清理失败才可延后。

## 1. 问题与目标

现有协议先把 backend epoch 写成 `published`，再原子发布 final，随后直接提交 PG metadata；`finalize_mutation` 只核对 token/phase，就把 epoch 写成 `committed` 并删除 backup。它没有从 final 目录读取实际 sidecar，也没有确认 `part.0` 的物理形状。于是 rename 后的 final 若缺失、撕裂或与 journal/epoch fingerprint 分叉，请求仍可能返回 200，并删除唯一恢复证据。

AWS S3 对成功 PutObject 的约束是：成功响应表示完整对象已经加入，单 key 更新原子可见，成功 PUT 后的 GET/LIST 立即可见。因而本批目标是：

1. 在 PG metadata 提交前，从 final 实际文件取得 proof；proof 失败时仍处于可回滚区，绝不返回 200。
2. finalize 在删除 backup 前复用同一 proof，抵御发布 proof 与最终清理之间的漂移。
3. 区分 proof failure 与 proof 后的 cleanup failure，避免继续吞掉所有 finalize 错误。
4. 保持 backend 插件边界、对象字节流式管线、fencing/quorum 与历史 placement 不变量。

本批的编排范围固定为现有八个 `ObjectMutation.Commit` 生产 caller：PutObject、
CopyObject、Console upload、ObjectWriter、inventory、access-log、replication 与 rebalance。
八条路径共用同一个 gate 和稳定公共错误适配器。本批不新增 multipart assemble/complete、
delete、meta-only 或 tombstone caller；这些 Phase2A/后续路径不得顺手迁入。sidecar authority
继续作为独立 legacy 收敛分支，不冒充 PG proof wrapper。

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

backend callback 必须返回 Task 1 的精确 aggregate sum type。`Maxio.Storage` facade 是插件
trust boundary：每个 proof/finalize 返回都先经
`PublishedProof.validate_callback_result(mode, result)` 非变异验证，其中
`mode in [:proof, :finalize]`。它只接受
所选 mode 的 canonical aggregate result，绝不裁剪、重排、修复或返回替代值。obsolete tuple、
wrong scope/mode 或伪造 status/class/count 一律转换为：

```elixir
{:error, {:published_proof_contract_violation, mode}}
```

其中 `mode in [:proof, :finalize]`。该 facade-only 错误不扩宽 backend behaviour union，
且按 integrity fail closed；不得删除
backup，也不得持久化、记录或公开 raw callback term。

endpoint wire observation 与 backend aggregate proof 是两个不可混用的域：

- summary 必须带 `"scope" => "endpoint" | "aggregate"` 与
  `"mode" => "proof" | "finalize"`；endpoint summary 另带稳定 `"endpoint"` identity。
  FS identity 固定为 `"local"`，shard identity 固定为冻结 placement 的全局
  `"ordinal:N"`，不含 node/drive 路径。
- `EpochStore` / `ShardServer` / `Transport.verify_mutation` 只返回 endpoint result；
  `Storage.Backend.verify_published` 才返回 aggregate result。endpoint wire 不允许自报
  `:degraded`，且 endpoint summary 根本不携带
  `required/verified/observed_owned/unavailable/degraded/omitted` 聚合计数；每条有效 endpoint
  observation 由本地 classifier 最多贡献一票。
- 聚合入口接收 `{expected_identity, endpoint_result}`，expected identity 必须唯一且与响应
  identity 精确相等。重复、错配、aggregate 重入或 outcome/status/class/count 不一致均在计票前
  fail closed 为 `:placement_drift`，绝不静默去重或接受自报 quorum。
- aggregate summary 明示 `"debt"`；它等于有界 `degraded` 条目数加 `"omitted"`。finalize
  aggregate 另以 `"orphaned"`、`"orphan_hints"`、`"orphan_omitted"` 单列 absent/旧 token
  的非破坏性提示；orphan 不投票、不计 debt，也不授权删除。journal 只接受合法 aggregate
  summary，endpoint summary 永远不能作为 durable evidence 或再次参与 quorum。

低层与聚合返回联合逐项冻结为：

```elixir
@type endpoint_proof_result ::
  {:ok, {:verified | :superseded, endpoint_summary}}
  | {:error, {:published_proof_failed, class, endpoint_summary}}

@type aggregate_proof_result ::
  {:ok, {:verified | :degraded | :superseded, aggregate_summary}}
  | {:error, {:published_proof_failed, class, aggregate_summary}}

@type endpoint_finalize_result ::
  {:ok, {:finalized | :cleanup_pending | :orphan | :superseded,
         endpoint_finalize_summary}}
  | {:error, {:published_proof_failed, class, endpoint_finalize_summary}}

@type aggregate_finalize_result ::
  {:ok, {:finalized | :cleanup_pending | :superseded, aggregate_finalize_summary}}
  | {:error, {:published_proof_failed, class, aggregate_finalize_summary}}
```

endpoint proof summary 固定带 `scope="endpoint", mode="proof"`，合法语义只有三种：

| tuple outcome | endpoint `status` | `owned` | `class` |
| --- | --- | --- | --- |
| `:verified` | `"verified"` | `true` | 不存在 |
| `:superseded` | `"superseded"` | `false` | `"fenced"` |
| error | `"failed"` | exact requested token 已确认时才为 `true` | 必须与 outer class 相同 |

outcome/status、outer/detail class、mode 或 identity 任一不一致即结构漂移。endpoint finalize
summary 固定带 `scope="endpoint", mode="finalize"`，并额外带 boolean `proof_passed` 与
`finalized`：

| tuple outcome | `status` | `owned` | `proof_passed` | `finalized` | class/reason |
| --- | --- | ---: | ---: | ---: | --- |
| `:finalized` | `"finalized"` | `true` | `true` | `true` | 均不存在 |
| `:cleanup_pending` | `"cleanup_pending"` | `true` | `true` | `false` | 均不存在 |
| `:orphan` | `"orphan"` | `false` | `false` | `false` | `orphan_reason="epoch_absent"|"older_token"` |
| `:superseded` | `"superseded"` | `false` | `false` | `false` | `class="fenced"` |
| error | `"failed"` | exact requested token 已确认时才为 `true` | `false` | `false` | outer/detail class 必须一致 |

`:orphan` 只能由 finalize 阶段对 clean epoch read 的 absent，或 target 完全一致且 token
严格更旧的 endpoint 显式构造；禁止从任意 `owned=false` failure/code 推导 orphan。
未通过 endpoint proof 的 claimed/缺失/分叉不能伪装 cleanup-only debt，仍以
endpoint proof error 进入 backend 聚合，由健康 quorum 决定全局是 proof failure 还是
`cleanup_pending`。

aggregate proof summary 固定带 `scope="aggregate", mode="proof"`，由 classifier 唯一生成：
`required > 0`，所有计数非负，
`debt == length(degraded) + omitted`，`unavailable <= debt`，
`verified <= observed_owned <= verified + debt`。`verified` 状态要求
`verified >= required && debt == 0`；`degraded` 要求
`verified >= required && debt > 0`；`failed` 要求 `verified < required` 且 tuple/summary
class 一致。`corrupt`/`mismatch` failure 还必须保留至少一条同 class、`owned=true`
的决定性 endpoint witness；只改 outer class 的 forged summary 一律拒绝。

aggregate finalize summary 固定带 `scope="aggregate", mode="finalize"`，另带
`finalized`、`orphaned`、`orphan_hints`、`orphan_omitted`，并满足：

```text
debt == length(degraded) + omitted
orphaned == length(orphan_hints) + orphan_omitted
finalized <= verified <= observed_owned <= verified + debt
unavailable <= debt
length(degraded) + length(orphan_hints) <= 32
```

`degraded` 与 `orphan_hints` 的 identity 必须各自唯一且互斥。终态要求
`verified >= required && finalized >= required && debt == 0 && unavailable == 0`；
否则 proof quorum 已过但仍有清理债务才是 `cleanup_pending`。`orphaned > 0` 不阻塞已有
真实 finalized quorum；orphan-only 且未达 quorum 仍是全局 unavailable failure。

finalize aggregate 还必须把 proof-passed/unfinalized endpoint 与具体 detail 类型守恒。令
`gap = verified - finalized`，`visible_cleanup` 为 retained `degraded` 中
`status="cleanup_pending" && proof_passed=true && finalized=false` 的条数，必须满足：

```text
visible_cleanup <= gap <= visible_cleanup + omitted
```

因此 unrelated mismatch/corrupt/unavailable/drift/superseded debt 不能冒充 cleanup gap，
retained cleanup detail 也不能从 aggregate 计数中消失。继续要求
`cleanup_pending` 必须 `verified >= required && debt > 0`，并保留至少一条 cleanup/debt
witness；`finalized` 在 `debt == 0` 时必然
`verified == finalized == observed_owned`。不能只改 status/finalized 计数伪造无债务的
cleanup pending，也不能让 proof-passed/unfinalized endpoint 从 terminal summary 消失。

独立区间还不够：同一个 omitted slot 不能同时代表互斥 endpoint outcome。令
`visible_owned_failure` 为 retained degraded 中 `status="failed" && owned=true` 的条数，
`visible_unavailable` 为 retained unavailable detail 条数，并定义：

```text
hidden_cleanup = gap - visible_cleanup
hidden_owned_failure =
  observed_owned - verified - visible_owned_failure
hidden_unavailable = unavailable - visible_unavailable
```

三者都必须非负，且：

```text
hidden_cleanup + max(hidden_owned_failure, hidden_unavailable) <= omitted
```

`visible/hidden_owned_failure` 与 `visible/hidden_unavailable` 在 proof/finalize 两种 mode
使用同一定义；proof endpoint detail 没有 `proof_passed` 字段，禁止用该字段识别 owned
failure。`hidden_cleanup` 只属于 finalize；proof mode 的 slot 方程将其视为零。

owned failure 与 unavailable 可由同一 omitted failure 重叠解释，故取 `max`；cleanup
proof 已通过，与所有 proof failure 互斥，必须另占 slot。Stage A 与 normalization 后的
Stage B 都必须重验这一联合可实现性。

outer failure class 也必须可实现。proof/finalize 若：

```text
status == "failed"
class == "unavailable"
verified + unavailable < required
```

则处于 fallback unavailable 分支，必须另满足：

```text
hidden_owned_failure <= hidden_unavailable
```

否则至少一个 hidden owned failure 不是 unavailable；owned placement drift/successor
均被禁止后，它只能是 corrupt/mismatch，classifier 必须优先选择 integrity class，不可能
落入 fallback unavailable。

classifier 必须在计票前完整预检 expected identity、响应 identity、scope/mode、tuple/status/
class 与 aggregate 重入。任一结构漂移均生成规范化 `placement_drift` failure，固定
`verified=0, observed_owned=0, unavailable=0`；finalize 另固定
`finalized=0, orphaned=0`，只保留一条有界脱敏 witness。只有输入集结构合法后才进入
successor 与 D5 的语义裁决。identity 只允许 `"local"` 或 `"ordinal:N"`；整数 ordinal
必须先限制十进制表示，使最终 identity 总长不超过 128 bytes。

durable aggregate validator 必须重放同一优先级：任一 retained endpoint successor 都要求
canonical aggregate superseded；没有 successor 时，任一 retained placement drift 都要求
canonical aggregate placement-drift failure。success/degraded/cleanup 或低优先级 failed
outer shape 不能包住这两类强裁决 detail。

所有可持久化 aggregate failure/superseded summary 还必须满足统一 witness 规则：

```text
proof/finalize failed:
  verified < required
  fenced 不得作为 failed class
  corrupt/mismatch 必须保留 owned=true、同 class endpoint witness
  placement_drift endpoint witness 必须 owned=false
  placement_drift aggregate 必须使用上述 canonical zero counts，并保留 drift witness

proof/finalize superseded:
  aggregate 无 outer class
  必须保留 status=superseded、class=fenced、owned=false 的 endpoint witness
  verified/observed_owned/unavailable 规范化为零
  finalize 另将 finalized/orphaned 规范化为零
  witness 保存在 degraded；debt == length(degraded) + omitted 且至少为 1
```

validator 必须从保留的有界 detail 重验这些关系；不能只相信 aggregate outer status/class。
public endpoint constructor 对 `placement_drift, owned=true` 必须拒绝；结构预检生成的 drift
witness 必须重新构造为非 owned 的有界 canonical detail，不能原样保留不可信 observation。

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

metadata 前 proof failure/superseded 必须在同一个 id/phase/attempt/lease CAS 中写入
`rollback_pending`、`published_fingerprint: nil`、phase-valid recovery evidence 与 bounded
`last_error`。公开 API 固定为
`request_rollback(journal, attrs, opts \\ [])`；`attrs` 仅允许
`published_fingerprint`、`recovery_evidence`、`last_error`，旧 keyword-opts arity 不保留。
初始 proof failure/superseded 必须显式供应完整原子三元组，即使其中
`published_fingerprint` 或 `recovery_evidence` 为 nil，也不得借“未供应”保留旧值。
入口顺序固定为 authority/phase 与 evidence domain、durable JSON、supplied attrs 的严格
`===` replay 比较，最后才可进入 CAS；existing-state 或 equality shortcut 不得绕过前述
validation。错误 outcome 与 stable `last_error` 的逐字映射固定为：

```elixir
%{
  unavailable: "published_proof_failed:proof:unavailable",
  corrupt: "published_proof_failed:proof:corrupt",
  mismatch: "published_proof_failed:proof:mismatch",
  placement_drift: "published_proof_failed:proof:placement_drift",
  superseded: "published_proof_superseded:proof"
}
```

任一 outcome/code 错配、任意 code、wrong-phase evidence 或非 durable evidence 都返回
`{:error, :invalid_rollback_evidence}`，并在 SQL 前零写入。`rollback_pending` 幂等重放要求
所有 supplied attrs 与持久值严格 `===`；冲突零写入。真正进入 CAS 后若丢失竞争，必须
fresh-read 判定：evidence 不同返回
`{:error, {:rollback_evidence_conflict, :recovery_evidence}}`；evidence 相同而
`last_error` 不同返回 `{:error, {:rollback_evidence_conflict, :last_error}}`，不得把 loser
误判成幂等成功。每个 CAS loser 只允许一次 `object_mutations` UPDATE attempt，且不得改写
winner 的完整 row 或 forensic JSON bytes。
`rolled_back` 是不可重写的终态。generic Journal evidence 的 65,536/65,537-byte 门与
PublishedProof 的 60 KiB 门分别测试，不能把二者混为一个上限。

request-level successor 形状固定为
`{:published_proof_superseded, aggregate_summary}`；禁止伪造
`{:published_proof_failed, :fenced, summary}`。

Storage facade contract violation 没有 canonical aggregate summary，不是 proof result。
metadata 前的 proof-mode contract violation 不得调用 `journal_evidence/3` 或伪造 failed
summary；它经同一 rollback CAS 写 nil fingerprint、exact stable last error
`"published_proof_contract_violation:proof"` 与以下 bounded generic Journal evidence：

```elixir
%{
  "authority_mode" => "pg",
  "stage" => "verify_published",
  "outcome" => "contract_violation",
  "mode" => "proof"
}
```

随后 best-effort restore；无 metadata，restore 失败仍保留 backup 并由 Recovery 收敛。

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
2. 先比较 decoded epoch target 与 request canonical target。target 不同即结构损坏；即使其中
   token 更大也不得伪装 successor，且不探测 final。
3. target 相同后比较 token；successor 立即返回 `:superseded`，不读取/触碰 final 或 backup。
4. standalone publish proof 要求 phase 为 `published` 或幂等重放的 `committed`，且 epoch fingerprint 与 request fingerprint 精确相等。finalize 另允许同 token `claimed` repair：claimed epoch 不计 initial proof quorum；metadata 已提交后的 finalize 只有在 actual final 精确匹配 request/journal fingerprint 时，才可把该 endpoint 直接收敛为带 fingerprint 的 `committed` 并清 backup。claimed final 缺失/不匹配时保持 cleanup debt，等待 heal 后重试。
5. 从 `final_rel` 定位 final，先用 `lstat` 拒绝 symlink/非 regular，并执行 16 MiB hard limit；只读取至 limit+1，取得 exact raw `meta.json` 后再 decode。
6. 通过 `Maxio.Sidecar` 的唯一 non-raising durable-object decoder 验证完整的普通对象
   `maxio/2` envelope：format、top-level `etag`/`size`/`sha256`、非空 versions，以及与
   target version_id **恰好一条**、且 type 为 object 的 entry；同 version_id 重复（包括
   delete-marker/object 冲突）一律 corrupt，不能让 proof 的 existential lookup 与读侧
   `find_version/2` 的首项语义分叉。随后只从 top-level durable core 取
   `etag`/`size`，以 raw sidecar 字节重建 actual fingerprint；禁止使用 `versions` 中
   S3-visible 的 ETag/size，也禁止要求二者与 core 相等（SSE/multipart 可合法不同）。
7. 三方比较：request/journal == epoch == actual final。
8. 校验 `part.0` 是 regular file：
   - FS：大小等于 top-level core stored size；
   - shard：按本 endpoint 的固定 ordinal 精确查找 `shards[i]`，大小等于 `shard_file_size`。
   - 零字节对象仍必须有零长度 `part.0`。
8. 普通 object 之外的 value type 显式拒绝；未来 delete marker/meta-only 必须另行设计豁免，不能隐式放宽。

`finalize_mutation` 在同一个 `EpochStore` 串行闭包内复用步骤 1–8。proof 成功后才写 committed epoch，再删除 backup。committed 幂等重放也必须先复验，不能直接删 backup。

Transport 只新增有界 proof RPC，不回传对象/shard 内容。Distributed 只使用
`ctx.placement_snapshot` 的历史 set/topology；禁止回退当前 router。invalid request/root 等
外围失败必须返回结构化 endpoint failure 而不是抛异常；shard request 即使尚未打开 root 也
保留请求中的冻结 ordinal。ERPC 的远端调用与 local `apply` 必须位于同一异常/exit 归一化边界。

target 与路径身份另有硬约束：

- request target、epoch 内 decoded target 与 canonical target bytes 必须精确相等；target
  不同的 greater token 不能伪装 successor。`final_rel` 必须逐字等于
  `Paths.object_rel(bucket, key, version_id)`，不能只做词法安全检查。
- configured drive root 必须是非空绝对目录。root 到 final directory 的每个路径组件在 proof
  前后都要检查；扫描范围从 volume/filesystem root 到 configured drive root 的每个前缀，再到
  canonical final directory。Unix 使用 `lstat`；Windows 不能依赖 OTP `lstat` 识别 junction，
  必须经 `Maxio.Native.PathSafety` 的 DirtyIo NIF 调用 Rust
  `symlink_metadata`，并拒绝全部 `FILE_ATTRIBUTE_REPARSE_POINT (0x400)`。NIF 未加载或返回
  不可判定时 fail closed 为 unavailable，绝不回退成“OTP 看起来是 directory 就安全”。
- 现有 Rustler crate 改由中性的 `Maxio.Native` loader 注册；ErasureCoding 与 PathSafety
  分别通过 wrapper 委托。静态 reparse detector 只用 Rust std，不新增 dependency，也不能
  污染 `Maxio.Native.ErasureCoding` 的公开职责。
- sidecar 采用 opened-handle 复验：pre-lstat → raw open → fstat/path-lstat identity 对照 →
  limit+1 read → fstat/path-lstat/ancestor 二次对照。sidecar handle/path 比较稳定 identity、
  size 与时间信息；祖先目录只比较 type/device/inode/可用 file-id 等稳定 identity，并在前后
  重复 type/reparse 检查，禁止比较 size/mtime/ctime/links/mode，以免同 bucket 其他 key 的
  正常并发目录变化被误判为 corrupt。任一相关身份或 sidecar 大小漂移 fail closed；part
  仍只做 stat/shape proof，不读取对象字节。
- 标准 OTP 没有跨平台 `openat2/O_NOFOLLOW` 或 Windows reparse-point handle 能力。本批保证受控
  数据盘、Maxio writer 经 EpochStore 串行下的静态 link/junction、常见换链与布局损坏检测；
  native scan 与 opened-handle 复验之间仍不能消除 hostile concurrent junction swap/ABA。
  不宣称抵御拥有本地写权限的恶意进程精心竞态。若未来威胁模型包含 hostile local writer，
  必须新增原生文件能力层，不能在当前代码上夸大保证。

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

全局 proof 分类顺序固定，禁止因遍历/返回顺序不同而把同一证据随机映射成 500 或 503。
先对完整输入集做上述结构预检；结构合法后再执行：

1. 合法 endpoint 观察到 successor：全局 `:superseded`，立即短路/重新裁决，绝不能把
   successor 当少数 degraded failure；successor 不算 same-token owned。
2. `verified >= epoch_quorum`：proof 成功；有失败 endpoint 时是 degraded success。
3. `verified + unavailable >= epoch_quorum`：当前证据仍可能在端点恢复后达到 quorum，分类
   `:unavailable`。
4. 否则若存在 owned-token `:corrupt`，分类 `:corrupt`；再考虑 owned-token
   `:mismatch`。epoch absent/旧 token 的 non-owned corrupt 不参与确定性 integrity 选择。
5. 其余不足 quorum：分类 `:unavailable`。

因此下表中的 mismatch/corrupt 指“按上述全局顺序裁决后的整体 proof failure”，不是健康 quorum 之外的少数坏副本。

finalize 聚合必须区分：

- `proof_passed`：endpoint proof 已通过，但 epoch 写入或 backup 删除失败；
- `finalized`：proof 与清理均成功；
- `orphan`：仅 clean absent/older-token 的 finalize-only 非破坏性提示，不投票、不计 debt；
- `proof_failed`：unavailable/mismatch/corrupt/fenced。

若 proof-passed endpoint 不足 quorum，整体是 proof failure；若 proof-passed 达 quorum但 finalized 不足 quorum，或仍有 unresolved/owned endpoint debt，整体是 `cleanup_pending`。只有达到上面的可证明终态集合才返回 `finalized`。这样不会把证据不足伪装成“只是删 backup 失败”，也不会越过 absent-token destructive 防线。

### D6 — 错误与 HTTP 语义

| 场景 | journal/磁盘动作 | HTTP |
| --- | --- | --- |
| metadata 前 proof unavailable / quorum 不足 | request rollback；保留失败证据 | 503 `SlowDownWrite` |
| metadata 前 proof mismatch/corrupt | request rollback；详细证据只进结构化日志 | 500 `InternalError` |
| metadata 后 defense proof unavailable | 不回滚；`finalize_pending` + retry | 503，绝不 200 |
| metadata 后 defense proof mismatch/corrupt | 不回滚；quarantine；保留 backup | 500，绝不 200 |
| Storage callback contract violation | metadata 前 rollback；metadata 后/sidecar quarantine；保留 backup | 500 `InternalError` |
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
| timeout、节点失联、`:eacces`、`:eperm`、`:eio`、`:enodev`、`:estale`、`:etimedout`、`:ebusy` 等暂时失败 | `:unavailable` |
| raw fingerprint、core etag/size、part/shard size 与 expected 不同 | `:mismatch` |
| meta/part 缺失、JSON/shape 非法、symlink/junction/非 regular、`:enotdir`、`:eloop`、sidecar 超 16 MiB、invalid internal request、initial proof 的 epoch absent/旧 token | `:corrupt` |
| greater token / successor | `:fenced`，折叠为全局 superseded |
| frozen placement 非法或 topology hash 漂移 | `:placement_drift` |

Rust raw errno 必须按 `target_os` 分表，或只使用稳定 `ErrorKind` 加 OS-specific raw
whitelist；未知/瞬态 errno 必须映射 unavailable，不能因不同 Unix 数值复用而误报 corrupt。

#### Durable JSON 是 JSONB 严格回读契约

“Jason 可编码”不足以证明数据可持久化：Jason 1.4.5 默认只解码至多 1,024 个十进制
token bytes 的整数；PostgreSQL JSONB 会归一化某些 float，并拒绝 U+0000。所有新写入或
replay-validation 的 journal JSON 值必须先经过唯一、中立、纯函数边界：

```elixir
Maxio.DurableJSON.validate(value,
  max_depth: non_neg_integer(),
  max_encoded_bytes: pos_integer()
)
# => {:ok, encoded_binary} | {:error, :invalid_durable_json}
```

该 helper 从 root depth 0 开始计数；只接受 string-key map、list、binary、boolean、nil 与
integer。所有 key/value binary 必须是 valid UTF-8 且不含 U+0000；struct 与所有 float
一律拒绝；每个 integer 的 `byte_size(Integer.to_string(integer)) <= 1_024`，负号计入
token bytes。它还必须依次证明 caller-specific depth、`Jason.encode/1` 成功、exact encoded
bytes 不超过 caller 上限、对这些 exact bytes 的 `Jason.decode/1` 成功，且 decoded term
与输入严格 `===`。缺少、额外或类型错误的 options 与任何异常都统一返回
`{:error, :invalid_durable_json}`，helper 不 raise；caller 保留既有 public error taxonomy。

调用 profile 固定为：

- `PublishedProof` 在完整 semantic validation 后调用
  `max_depth: 6, max_encoded_bytes: 61_440`；
- `Journal.changeset/2` 的每个 JSONB-backed field（含 `recovery_evidence`）以及
  `Journal.json_evidence_valid?/1` 调用
  `max_depth: 15, max_encoded_bytes: 65_536`。

Journal 的 root-zero depth 15 与既有 root-one、`depth > 16` 拒绝语义等价，不得暗中扩缩。
PublishedProof 的 list/map/key/string/phase/detail/witness 等限制仍属于 semantic layer，
不能下沉成 helper 的可配置选项。不得提高 Jason 全局 integer limit，也不得把 formal
PublishedProof ceiling 降到 32 KiB：已有 clean intended-canonical wrapper 被四重取证为
37,883 encoded bytes、public durable validator `:ok`、Jason strict `===`，且经 PostgreSQL
16.14 JSONB 实际 INSERT/SELECT 后 strict `===`。60 KiB 仍是 absolute defense，不宣称
today's schema 能达到 exact positive endpoint。

证据保全更新是刻意的例外：已从数据库装载的 malformed evidence 必须原样保留时，SQL
update set 不包含该 column，因而不得为了“修复”它而重新经过 changeset/durable gate。
但任何新值、supplied replay 值或 equality/idempotency 候选均必须先验证，再做严格
`===` 比较。

`recovery_evidence` 有两个互斥 domain，绝不互相伪装：

1. canonical PublishedProof wrapper：只承载 aggregate proof/finalize 事实，经
   `PublishedProof` phase-aware trust boundary；
2. generic non-PublishedProof evidence：包括 PG 的 pre-proof/rollback operational facts
   （含 exact contract-violation subshape），以及 legacy sidecar recovery 的
   `current_epoch` pre-adapter 与 finalize adapter 两个 exact bounded scalar subshape。它们经
   Journal 的 shared durable-JSON/depth/64-KiB gate 和各调用点的
   authority/phase/keys/value validator，不调用 PublishedProof normalize/merge，也不消费
   31/32/60-KiB proof budget。

PublishedProof API 固定为：

```elixir
journal_evidence(target_phase, published_proof_or_nil, last_failure_or_nil)
merge_failure(target_phase, evidence, last_failure)
```

canonical PublishedProof domain 固定只保存：

```elixir
%{
  "published_proof" => aggregate_proof_success_or_nil,
  "last_failure" => failure_summary_or_nil
}
```

`published_proof` 只允许 aggregate proof 的 verified/degraded success。`last_failure` 只允许
aggregate proof 的 failed/superseded，或 aggregate finalize 的
failed/cleanup_pending/superseded；endpoint summary、proof success 与 finalize finalized 均拒绝。

- 在 canonical wrapper 内，`published_proof=nil` 时，`last_failure` 必须是 proof-mode
  failed/superseded；初始 proof
  失败要把 `claimed → rollback_pending` 与该 evidence 原子持久化，fingerprint 保持 nil。
- PG authority 的 `published`/`metadata_committed`/`finalize_pending`/`finalized` 必须已有
  成功 canonical published proof。
- PG `rollback_pending`/`rolled_back`/`quarantined` 可持有 canonical wrapper 或合法 generic
  operational evidence；只有声称自己是 canonical wrapper 的 nil proof 才必须满足上述
  proof failure/superseded 形态。
- finalize-mode last failure 必须同时存在成功 published proof，且只允许在 metadata/finalize
  后续 phase。`nil/nil` 不是合法 proof evidence。
- sidecar authority 不要求 PG wrapper：`published` 进入 D7 的 existing current-epoch
  adjudication；`finalize_pending`/`finalized`/`quarantined` 服从 D7 exact legacy scalar
  subshape 与 authority/phase validator。sidecar `metadata_committed` 始终非法。

本批新增的 PG contract-violation generic evidence 只能由
`authority_mode="pg"`、observed phase `claimed` 的
`request_rollback(journal, attrs, opts)` 生成；target phase 必须是 `rollback_pending`，
fingerprint 必须 nil，`last_error` 必须精确为
`"published_proof_contract_violation:proof"`，evidence 必须 map-size 4 且逐字匹配：

```elixir
%{
  "authority_mode" => "pg",
  "stage" => "verify_published",
  "outcome" => "contract_violation",
  "mode" => "proof"
}
```

`request_rollback` 在 SQL 前先执行上述 phase/authority/fingerprint/keys/value validator，
再用 `Journal.changeset` 执行 shared durable-JSON/depth/65,536-byte gate；任一步失败均
零写入。该
evidence 可随 rollback 收敛保留在 `rollback_pending`、`rolled_back` 或 `quarantined`，
restore/lease/generic error 只用 evidence-preserving operational update 改 attempts/backoff/
last_error，不覆盖它。它在 `published`/metadata/finalize phase 永不合法，也不参与
PublishedProof 的 31/32/60-KiB 预算。

一个 journal evidence wrapper 中，`published_proof.degraded`、
`last_failure.degraded` 与 finalize `last_failure.orphan_hints` 合计最多保留 32 条。
为了让后续 merge 保持初始 `"published_proof"` byte-for-byte 不变，初次持久化成功 proof
时最多保留 31 条 detail，并把其余精确计入 proof `"omitted"`，为未来 last failure 的强制
witness 预留一条。若 published proof 少于 31 条，未用预算可供 last failure 使用。

evidence 入口固定为两阶段 trust boundary。Stage A 在任何裁剪、重排或 omitted 调整前，
完整验证 source proof/failure 的 sum type、phase、非负计数、精确 debt/orphan 关系、
上述 typed finalize conservation、identity 唯一/互斥、endpoint 脱敏形态、全局优先级与
mandatory witness。非法 source 立即拒绝；禁止让 normalization 修复负 omitted、重复/
非法 tail detail，或把 successor/placement drift 洗入匿名 omitted。

Stage B 只对已通过 Stage A 的 source 执行 wrapper 分配：

1. 已持久化的 published proof 不再裁剪或重排；
2. 初次持久化的 successful proof 按既有确定顺序裁至最多 31 条，并精确增加 omitted；
3. last failure 按 status/class 显式选择 mandatory canonical decisive/debt witness 并置于
   retained 首位，不能只相信输入 list 位置；
4. cleanup gap 为正时优先选择 visible cleanup witness；没有该类 mandatory witness
   要求的 unavailable 等状态不得凭空合成 witness；
5. 剩余预算按 `last_failure.degraded`、再 `last_failure.orphan_hints` 的既有确定顺序填充；
6. 每次裁剪都保持 `debt`/`orphaned` 总数不变，并精确增加对应
   `omitted`/`orphan_omitted`；
7. pre-published 的 nil-proof failure 可独占全部 32 条预算；
8. normalization 后再次运行完整 durable semantic validator，并显式校验 proof retained
   `<=31`、wrapper retained `<=32`、shared durable JSON 与编码 `<=60 KiB`。

若 mandatory witness 缺失，必须拒绝 evidence，不能仅靠 omitted 合成决定性事实。
`merge_failure/3` 还必须先证明输入是已持久化的 31-detail durable wrapper；既有
`published_proof` 不得再次裁剪/重排，只允许新 last failure 走 Stage A/Stage B，返回的
proof term 与编码必须和输入完全一致。伪造的 32-detail “已持久化 proof”直接拒绝。
PublishedProof wrapper 的编码结果必须不超过 60 KiB，并继续通过 Journal 既有
shared durable-JSON/64 KiB gate。canonical proof/finalize outcome 才能用 phase-aware merge 更新
`"last_failure"`，并保留初始 `"published_proof"`。lock、lease、restore、generic exception
等 operational error 不能伪装 aggregate proof failure。凡现有 evidence 必须原样保留
（valid wrapper、invalid wrapper 取证、或上述 exact generic contract evidence），分别使用精确
`mark_operational_error(journal, reason, opts \\ [])` 与
`quarantine_preserving_evidence(journal, reason, opts \\ [])`。前者 SQL update set 仅含
`attempts`、`next_attempt_at`、bounded `last_error`、`updated_at`；后者仅含 quarantine
phase/timestamp/lease cleanup 与 bounded `last_error`。二者都不得更新 fingerprint 或
recovery evidence。invalid-proof quarantine 同样保留 malformed source evidence 的 term 与
JSON 编码，供取证使用。`reason` 必须是 binary；非 binary 统一返回
`{:error, :invalid_operational_reason}`，在 SQL 前零写入且完整 row 严格不变。

`quarantine_preserving_evidence/3` 的 CAS loser 不得走 generic terminal idempotency：
同一 stale snapshot 的不同 reason 竞争只允许一次 `object_mutations` UPDATE attempt，
fresh-read 后精确返回 `{:error, {:stale_journal, "quarantined", attempts}}`；winner 完整 row
与 forensic JSON bytes 保持权威。

### D7 — Recovery 复用同一 callback

Recovery 不实现第二套 proof，且必须先按 authority/phase 精确分流：

1. PG `metadata_committed` / `finalize_pending`：先调用非变异
   `PublishedProof.validate_durable_evidence(target_phase, evidence)`；合法 wrapper 才执行
   `Storage.verify_published/2`，随后调用 proof-aware finalize。
2. sidecar `published`：保留既有 `current_epoch` 裁决，转 `finalize_pending` 后调用
   sidecar finalize adapter。
3. sidecar `finalize_pending`：直接继续同一个 sidecar finalize adapter；backend finalize
   内部会 re-proof，不额外调用 standalone verify，也不要求 PG wrapper。
4. sidecar `metadata_committed`：不可能状态，任何 endpoint I/O 前 fail closed。

PG 分支中 unavailable 可重试；全局 mismatch/corrupt/placement drift quarantine；少数
mismatch 已被健康 quorum 覆盖时只记录 cleanup debt；successor 短路 finalize 并终态记录；
cleanup pending 保留 `finalize_pending`。durable validator 只返回
`:ok | {:error, :invalid_proof_evidence}`，不裁剪、不重排、不修 omitted，也不返回 replacement
map。缺失/畸形 wrapper 在 endpoint 调用前 quarantine，并保留原 evidence 取证。

metadata 后的 proof/finalize facade contract violation 不得进入 aggregate merge；使用
`quarantine_preserving_evidence/3`，以 exact stable last error
`"published_proof_contract_violation:proof"` 或
`"published_proof_contract_violation:finalize"` 隔离，同时保持既有 valid wrapper 与
fingerprint term/编码不变、保留 backup、绝不 rollback。同步请求返回 500，Recovery 同样
收敛为 quarantine。

sidecar 有三个可选方向：伪造 PG wrapper 会混淆 authority，持久化完整 raw aggregate 会扩大
泄漏/预算面，冻结 sidecar Recovery 又会破坏现存合法 `finalize_pending`。因此选择独立、固定
scalar adapter：只消费已经由 backend classifier/Storage trust boundary 裁决的 union，不复制
quorum 逻辑，也不把 legacy sidecar evidence 伪装成 PG proof。

sidecar `published` 的 `current_epoch` 裁决先使用独立 pre-adapter 表：

| `current_epoch` 结果 | action | exact outcome / last_error |
| --- | --- | --- |
| exact target/token，phase 为 `published`/`committed`，或 exact-target greater token | 进入 proof-aware finalize adapter | 不写 pre-adapter evidence |
| `:absent` | quarantine，保留 backup | `missing` / `"sidecar_current_epoch:missing"` |
| read/RPC error | quarantine，保留 backup | `unavailable` / `"sidecar_current_epoch:unavailable"` |
| same/older token 的非法 phase、target/token conflict | quarantine，保留 backup | `conflict` / `"sidecar_current_epoch:conflict"` |
| malformed/obsolete return 或 exception | quarantine，保留 backup | `contract_violation` / `"sidecar_current_epoch:contract_violation"` |

四个失败 outcome 均只持久化 exact map-size 3：

```elixir
%{
  "authority_mode" => "sidecar",
  "stage" => "current_epoch",
  "outcome" => outcome
}
```

validator 只允许 observed `authority_mode="sidecar", phase="published"` 到
`quarantined`，逐字校验三个 key、allowed outcome 与对应 stable last_error，再跑 Journal
shared durable-JSON/depth/64-KiB gate；phase、last_error 与 evidence 在同一个既有
phase/attempt/lease CAS 写入，任一步失败零写入。禁止存 endpoint、node/drive/path、token
generation/mutation id、raw/inspected reason 或 placement payload。带上述 sentinel 的
absent/unavailable/conflict/contract-violation 测试必须证明 journal、log、CLI 均不泄漏。

两个合法 sidecar entry state 共用以下完整 finalize union 适配表：

| backend result | sidecar journal action |
| --- | --- |
| `{:ok, {:finalized, summary}}` | 写 bounded sidecar evidence，终态 `finalized` |
| `{:ok, {:cleanup_pending, summary}}` | 保持 `finalize_pending`，写 evidence，backoff retry |
| `{:ok, {:superseded, summary}}` | 写 evidence，按既有语义终态 `finalized`，outcome 为 superseded |
| `{:error, {:published_proof_failed, :unavailable, summary}}` | 保持 `finalize_pending`，写 evidence，backoff retry |
| mismatch/corrupt/placement-drift proof error | quarantine，保留 backup |
| `{:error, {:published_proof_contract_violation, :finalize}}` 或任意 obsolete/malformed/wrong-mode tuple | contract violation quarantine；不删除 backup，不记录 raw tuple |

sidecar evidence 是独立 generic Journal shape，不调用 PG
`journal_evidence/3`、`merge_failure/3` 或 `validate_durable_evidence/2`。canonical summary
只投影 `authority_mode="sidecar"`、`stage="finalize"`、outcome、可选 class、mode/status、
required/verified/finalized/debt/unavailable/omitted/orphaned 标量；不存 detail、path、
node/drive、endpoint identity、raw tuple 或 inspected reason。malformed callback 只存
`authority_mode`、`stage` 与 `outcome="contract_violation"`。

CLI 继续读取 journal 的 `published_fingerprint` / `recovery_evidence`，展示 proof 阶段、required/verified 与降级摘要；无需 migration。

## 3. 测试与验收

### Endpoint / backend

- raw sidecar 任意字节变化，即使 decode 后 etag/size 相同，也必须 mismatch。
- wrong/missing `maxio/2` format、缺 core SHA256、空 versions、无对应 object version，即使
  request/epoch/final fingerprint 自洽也必须 corrupt；同 version_id 重复或
  delete-marker/object 冲突同样拒绝；SSE/multipart 的 versions ETag/size 与 core 不同时仍可通过。
- request/journal 与 epoch 不同，即使 final 匹配 epoch，也必须拒绝。
- request target、decoded epoch target 与 canonical final_rel 三方身份绑定；跨 key/version
  final_rel、target-mismatch greater token、祖先 symlink/junction 与确定性换链均 fail closed。
- `meta.json` 缺失、损坏、symlink、非 regular、超过 16 MiB；`part.0` 缺失、非 regular、截短或加长。
- sidecar 恰好 16 MiB 可有界读取；lstat 后增长到 limit+1 必须拒绝。successor 测试必须通过
  file-op seam 证明 final descendant 零探测，而不是仅依赖 final 缺失。
- FS 零字节对象必须存在空 part；SSE 使用 stored/core size；multipart-visible ETag 不得污染 core proof。
- committed replay：正常+backup 存在、正常+backup 已无、异常+backup 存在、cleanup 首次失败后重试。
- successor 在任何 final 读取前短路。
- EC/Distributed：exact quorum、低于 quorum、少数 mismatch/unavailable、sidecar 分叉、ordinal 错配。
- forged endpoint counts、outcome/status/class 不一致、aggregate 重入、重复/错配 ordinal identity
  均不得获得票；verified + non-owned corrupt 低于 quorum 是 unavailable，owned corrupt 优先于
  owned mismatch，non-owned corrupt 不触发 quarantine。
- Distributed placement drift fail closed，且 RPC 返回有界摘要。

### Orchestration / HTTP

- metadata 前 proof 失败：旧 bytes 恢复、PG 无新行、backup/epoch/journal 按 rollback 收敛。
- metadata 后 defense mismatch：不回滚、不返回 200、backup 保留、journal quarantined。
- proof 后 cleanup-only failure：请求成功、journal `finalize_pending`，Recovery 最终 finalized。
- durable validator：canonical wrapper 返回 `:ok` 且调用前后 term/Jason bytes 完全相同；
  missing/extra key、非法 phase、已持久化 32-detail、非法 hidden counter/witness、超过 60 KiB
  全部拒绝，且不得 trim/reorder/repair。
- shared DurableJSON 独立覆盖正数 1,024/1,025 digits、负号加 1,023/1,024 digits、所有
  float、U+0000 key/value、缺失/额外/非法 options，以及 codec-roundtrippable string payload
  的 exact 61,440/61,441 bytes；不得用 source regex 代替 public call。
- PublishedProof 大正控使用 clean intended-canonical wrapper，断言 measured
  `>32 KiB && <=60 KiB`、public validator `:ok`、Jason strict `===` 与真实 JSONB reload
  strict `===`；已知含 over-permissive detail 的 42,587-byte transport fixture 不得成为 public
  contract。huge-counter exact-61,440/61,441 wrapper 均是 rejection oracle，不是 size-positive。
- helper capability、PublishedProof public rejection、Journal changeset NUL、ObjectMutation NUL
  与 ObjectMutation 61,441 equality-bypass attack 必须是独立 test cases。ObjectMutation attack
  用 real PG prepared row + tests-only rejecting repo，证明 validation 在 equality/CAS 前发生、
  zero UPDATE、完整 row `===` 与 forensic bytes 不变；不得把 U+0000 提交给真实 JSONB。
- rollback stable-code 的五个正控、每 outcome wrong-code 与 arbitrary-code 负控均断言 exact
  result、pre-SQL zero UPDATE；另覆盖 generic wrong-phase 的 term-identical replay。两类
  rollback CAS loser 与 quarantine CAS loser 都用 Repo telemetry 证明 exactly one UPDATE
  attempt，并证明 winner 完整 row/bytes 权威；所有 pre-SQL rejection 用 telemetry 而非
  “调用后值相同”证明零写入。
- `mark_operational_error/3` 与 `quarantine_preserving_evidence/3` 分别覆盖 non-binary
  reason 的 exact `{:error, :invalid_operational_reason}`、zero UPDATE 与完整 row 不变。
- sidecar `published` 与合法 `finalize_pending` 均覆盖 finalized、cleanup-pending、
  superseded、unavailable、integrity failure 与 malformed/obsolete callback；所有非 finalized
  分支保留 backup。
- lock、lease、restore、generic exception、invalid-proof quarantine 用 sentinel 证明
  recovery evidence term 与 `Jason.encode!/1` bytes 不变。
- pre-metadata callback contract violation 用 exact generic PG evidence 原子 rollback 且不伪造
  proof summary；post-metadata proof/finalize violation 与 Recovery 均保留 canonical wrapper
  term/bytes 后 quarantine。
- exact eight shared-Commit callers 均有回归覆盖，且没有新增 Phase2A caller。
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
