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

classifier 必须在计票前完整预检 expected identity、响应 identity、scope/mode、tuple/status/
class 与 aggregate 重入。任一结构漂移均生成规范化 `placement_drift` failure，固定
`verified=0, observed_owned=0, unavailable=0`；finalize 另固定
`finalized=0, orphaned=0`，只保留一条有界脱敏 witness。只有输入集结构合法后才进入
successor 与 D5 的语义裁决。identity 只允许 `"local"` 或 `"ordinal:N"`；整数 ordinal
必须先限制十进制表示，使最终 identity 总长不超过 128 bytes。

所有可持久化 aggregate failure/superseded summary 还必须满足统一 witness 规则：

```text
proof/finalize failed:
  verified < required
  fenced 不得作为 failed class
  corrupt/mismatch 必须保留 owned=true、同 class endpoint witness
  placement_drift 必须使用上述 canonical zero counts，并保留 drift witness

proof/finalize superseded:
  aggregate 无 outer class
  必须保留 status=superseded、class=fenced、owned=false 的 endpoint witness
  verified/observed_owned/unavailable/debt 规范化为零
  finalize 另将 finalized/orphaned 规范化为零
```

validator 必须从保留的有界 detail 重验这些关系；不能只相信 aggregate outer status/class。

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

所有 evidence 先经 `PublishedProof` 限界/脱敏。API 必须 phase-aware：

```elixir
journal_evidence(target_phase, published_proof_or_nil, last_failure_or_nil)
merge_failure(target_phase, evidence, last_failure)
```

journal 固定只保存：

```elixir
%{
  "published_proof" => aggregate_proof_success_or_nil,
  "last_failure" => failure_summary_or_nil
}
```

`published_proof` 只允许 aggregate proof 的 verified/degraded success。`last_failure` 只允许
aggregate proof 的 failed/superseded，或 aggregate finalize 的
failed/cleanup_pending/superseded；endpoint summary、proof success 与 finalize finalized 均拒绝。

- `published_proof=nil` 时，`last_failure` 必须是 proof-mode failed/superseded；初始 proof
  失败要把 `claimed → rollback_pending` 与该 evidence 原子持久化，fingerprint 保持 nil。
- `published`/`metadata_committed`/`finalize_pending`/`finalized` 必须已有成功 published proof。
- `rollback_pending`/`rolled_back`/`quarantined` 可在 proof 前或后产生；nil proof 时仍必须满足
  上述初始 proof failure 形态。
- finalize-mode last failure 必须同时存在成功 published proof，且只允许在 metadata/finalize
  后续 phase。`nil/nil` 不是合法 proof evidence。

有界 endpoint detail 合计最多 32 条，其余放对应 omitted；PublishedProof wrapper 的编码结果
必须不超过 60 KiB，并继续通过 Journal 既有 JSON-safe/64 KiB gate。后续
`mark_error`/quarantine 必须用 phase-aware merge 更新 `"last_failure"`，保留初始
`"published_proof"`，不得整图覆盖。

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
