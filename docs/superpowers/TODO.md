# maxio 实时任务 TODO 看板

> 最后更新：2026-07-14 +08:00（P1-CLOSEOUT-A 已完成并通过最终可信 full gate；B1–B7 已实现，但 Phase 1 仍有 final fingerprint gate 与 Distributed prepared-journal placement durability 两项 blocking remediation）
>
> `docs/superpowers/STATUS.md` 是已经收口事实的单一来源；本文件是运行中的任务看板。
> 职责隔离固定：实现/聚焦验证由当前实现 lane 推进；规划/复审由独立 Codex read-only lane 完成，不使用 Claude 复审；实现者不自审。
> 批量验证固定：开发中跑聚焦/相邻测试、compile、format；完整 `mix precommit` 延后到当前 coherent batch 或里程碑收口统一运行。

## 状态图例

| 状态 | 含义 |
| --- | --- |
| 未开始 | 已纳入计划，但当前批次不处理 |
| 待规划 | 需要独立 Codex planning lane 先拆任务和评估风险 |
| 进行中 | 当前实现 lane 正在推进 |
| 待验证 | 代码/文档已改，等待聚焦或相邻验证 |
| 待复审 | 等待独立 Codex read-only lane 复审 |
| 待修复 | 复审或验证发现问题，等待实现 lane 修复 |
| 已完成 | 当前任务已通过必要验证；已收口事实仍以 `STATUS.md` 为准 |
| 受阻 | 外部环境、工具链或缺失依赖阻塞，需要单独解除 |

## 当前总控

| 项 | 当前值 |
| --- | --- |
| 总目标 | 用 Elixir/Phoenix 完整复刻 MinIO 级 S3 兼容对象存储 |
| 当前主线 | ObjectMutation Phase 1 remediation：P1-CLOSEOUT-A 已完成；继续关闭 final fingerprint gate 与 Distributed claim quorum → prepared-journal placement snapshot crash window。B1–B7 已实现，但 Phase 1/全局写路径均不得宣称闭环 |
| 当前 coherent batch | `P1-CLOSEOUT-A`（fresh Put rollback physical absence + `EpochStore.Worker` 单文件拆分 + full-gate 三根因收口） |
| 当前批次状态 | 已完成（独立双审 + 整批最终独立审查 + 可信 full gate + 93 项 TEMP 精确清理） |
| 最近完整收口 | P1-CLOSEOUT-A：fresh previous-absent rollback 物理删除、Worker 一文件一模块、InFlight/Compat/Drive 三项门禁根因修复 |
| 最近完整 precommit | 3665 tests, 0 failures, 5 excluded（2026-07-14；cmd 自重定向完整 log + ASCII exit sidecar，real Mix exit 0） |
| 当前验证策略 | 每个 remediation coherent batch 聚焦验证 + 独立实现/审查隔离；最终 full gate 在 Windows PowerShell 5.1 下使用 cmd 自重定向与 exit sidecar，禁止把截断终端输出当退出证据 |
| 当前复审策略 | 独立 Codex read-only lane，严禁用 Claude 复审 |
| 当前环境风险 | Windows 会话曾有 BEAM 内存压力；Mix 命令继续清理 `PGPORT` 并使用低 scheduler 配置 |
| 工作树注意事项 | 仓库已有大量既有改动和未跟踪文件；只改当前批次必要文件，不回退用户或既有改动 |

## 当前执行指针

| 层级 | 当前任务 | 状态 | 下一步 |
| --- | --- | --- | --- |
| 总目标 | 完整复刻 MinIO 级 S3 兼容对象存储 | 进行中 | 继续按 S3 兼容、Console/Ops、生产化三条线补齐长尾 |
| 当前里程碑 | ObjectMutation Phase 1 remediation | 进行中 | final fingerprint gate → Distributed claim 前 durable frozen placement snapshot → 计划内其余 Phase 1 未完成项；全部独立审查通过前不作 Phase 1 完成声明 |
| 当前切片 | `P1-CLOSEOUT-A` | 已完成 | fresh rollback physical absence 与 Worker 文件隔离已完成；下一批处理 fingerprint gate，不进入 assemble/multipart |
| 当前代码动作 | P1-CLOSEOUT-A 首批条目 | 已完成 | exact-token/phase/manifest 授权下 fresh final 物理删除；overwrite/successor/quorum fail-closed；Worker 等价拆分 |
| 当前验证动作 | 聚焦证据 + 最终可信 full gate | 已完成 | storage 74/0、orchestration 42/0、Worker isolation 21/0；整批最终 `mix precommit` 3665/0（5 excluded），TEMP 本轮 93 项精确清理为 0 |
| 当前复审动作 | 独立初审 + 独立 Minor 复审 + 整批最终独立审查 | 已完成 | 三轮均 APPROVED；最终无 Critical/Important/Minor；批准范围不含 Phase 1 总闭环 |

## 全量任务总表（实时追踪）

| 工作流 | 当前状态 | 已收口事实 | 剩余任务 | 当前动作 |
| --- | --- | --- | --- | --- |
| S3 协议入口 / SigV4 / XML / 错误映射 | 主干完成，严格化维护 | 独立 S3 endpoint、SigV4、RPC-over-query、结构化 S3 XML error、严格 XML parser 批次已多轮收口 | SigV4 streaming 长尾向量、低频 XML/action 差异、外部 SDK 行为取证 | 随数据面交叉矩阵发现即补 |
| Bucket/Object 基础数据面 | 主干完成，交叉矩阵硬化本轮收口 | bucket/object CRUD、ListObjectsV2、GET/HEAD、DELETE/DeleteObjects、CopyObject/UploadPartCopy、Range/conditional/versioning/delete marker 多批次通过；P1-S3-CROSS precommit 3265 tests 通过 | ACL/Object Ownership/Requester Pays 更深组合边界、外部客户端差异 | 后续随真实客户端/长尾矩阵继续补 |
| Multipart / Streaming / Checksum | 主干完成，长路径已补一轮交叉矩阵 | MPU、UploadPartCopy、aws-chunked、checksum/SSE、ranged UploadPartCopy、Complete/ListParts、BadDigest 原子性已有组合覆盖；P1-S3-CROSS precommit 3265 tests 通过 | 更大对象/更高并发/真实客户端长跑、故障中断恢复扩展矩阵 | 后续进入压力/兼容长尾批次 |
| Versioning / Object Lock / Lifecycle / Tagging / CORS | 主干完成，兼容补齐中 | versioning/delete marker、Object Lock、tagging/lifecycle/CORS 均有主干实现和相邻回归 | 与 Copy/Delete/MPU/replication/lifecycle 的组合语义、AWS/MinIO 差异记录 | 数据面矩阵按风险逐项补 |
| IAM / STS / Policy / ACL / Object Ownership | 主干完成，治理补齐中 | access key、policy evaluator、bucket policy、STS、OIDC/WebIdentity、MFA、secret rotation、跨账号 PrincipalAccount、授权决策日志、对象级旁路授权与 KMS boundary 已多批次收口 | 真实多账号/外部客户端取证、低频 IAM/S3 policy 条件、外部 KMS/HSM、ACL/Object Ownership 更深交叉矩阵 | `P1-IAM-GOV-A` 已完成；后续随 compat/longtail 继续补 |
| Encryption / KMS / SSE | 主干完成，生产化待加强 | SSE-S3/SSE-C/SSE-KMS/DSSE 与 copy/MPU 多路径已有覆盖 | 外部 KMS/HSM、key rotation 运行面、SSE 与 MPU/checksum 长路径组合缺口 | 01D 纳入 MPU 长路径核验 |
| Storage backend / Erasure / Distributed | 主干完成，长跑验证待加强 | FS backend、erasure、bitrot/self-heal、distributed backend、ShardServer、libcluster 已推进 | 真实多节点、网络异常、磁盘故障、滚动升级、长跑一致性证据 | 后续 `P2-STRESS` / ops 批次 |
| Ops / Scanner / Heal / Rebalance / Decommission | 进行中 | scanner、foreground scan、fresh-drive heal、scheduler、replacement/rebalance workflow、ops gate、live rehearsal bundle 已多批次收口 | 生产级升级/回滚、真实故障注入、runbook、operator evidence 闭环 | 后续 `P1-CONSOLE-OPS` 与 M8 批次 |
| Console LiveView | 主干完成，运维体验补齐中 | Console/Identity/STS/IdP/Object 管理主干存在；`/ops/gate` 已有 evidence matrix、evidence sources、artifact selection warning、artifact candidate-window hardening、EvidenceMatrix adversarial schema hardening、archived check evidence drilldown、operator runbook evidence、artifact provenance/recency warning、P0 live rehearsal bundle linkage 并通过复审；`/ops/rebalance`、`/ops/scan`、`/ops/replacement`、`/ops/cluster`、`/ops/upgrade`、`/ops/compat`、`/ops/observability`、`/ops/recovery` 只读 evidence Console 均已实现并通过复审；Console/Ops coherent closeout `mix precommit` -> 3363 tests, 0 failures, 5 excluded | fault injection、cluster/drive/operator runbook evidence 更完整操作台、更多浏览器自动化验证 | `P1-CONSOLE-OPS-CLOSEOUT-01` 已完成；下一步规划生产化/兼容/IAM 长尾 |
| External Compatibility | 官方三客户端深度 smoke 已完成 | aws-cli 2.35.20、mc RELEASE.2025-08-13、boto3 1.43.45 已真实运行；final6 artifact 6/6 且零残留/零 secret | 更多语言 SDK、长跑与真实多节点差异矩阵 | `P0-COMPAT-2C` 已完成；后续按新增客户端增量取证 |
| Production Readiness / Release | 进行中 | 多轮 `mix precommit`、ops gate、artifact evidence、结构化 CLI 已建立 | 长跑压测、灾难恢复、发布/回滚、部署文档、监控告警完整闭环 | `P2-STRESS` / `P2-RELEASE` 待规划 |
| Docs / Status / TODO | 进行中，实时维护 | `STATUS.md` 作为已完成事实来源；`TODO.md` 作为运行中看板；B1–B7 与 P1-CLOSEOUT-A 当前边界已同步 | 每个切片开始/完成/验证/复审时同步更新，避免跨会话丢进度 | 已记录 P1-CLOSEOUT-A、三根因修复、可信 3665-test gate 与 93 项 TEMP 精确清理 |

## 当前批次：P1-CLOSEOUT-A（已完成）

目标：关闭后续架构审计确定的首批 Phase 1 remediation：fresh previous-absent rollback 恢复盘上物理 absence，并把 `EpochStore.Worker` 等价拆成单文件单模块；同时收口该批第一次 full gate 暴露的三项独立根因。此完成状态只属于 P1-CLOSEOUT-A，不属于 ObjectMutation Phase 1 或全局写路径。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 结果 |
| --- | --- | --- | --- | --- |
| P1-CLOSEOUT-A1 | fresh Put rollback physical absence | 已完成 | TDD executor + 独立 reviewer | valid RED 后最小 endpoint 修复；FS/EC/Distributed、Commit/Recovery/Bandit 均断言 final 物理不存在，overwrite/successor/quorum 边界不回退 |
| P1-CLOSEOUT-A2 | `EpochStore.Worker` 单文件拆分 | 已完成 | executor + 独立 reviewer/rereviewer | 一文件一模块；child spec/name、路由、timeout、supervisor 拓扑不变；初审与 Minor 复审均 APPROVED |
| P1-CLOSEOUT-A3 | full gate 三根因修复 | 已完成 | 三个独立 TDD/fix lanes + 独立 final-batch reviewer | InFlight backend 完整 behaviour/真实 FS seam；Compat source-qualified ordinal identity；Drive cache owner 单 writer seam；最终整批审查无 findings |
| P1-CLOSEOUT-A4 | 最终可信 capture / exit | 已完成 | 全新独立 verification lane | cmd 内 `mix.bat ... > log 2>&1` + ASCII exit sidecar；real Mix exit 0；3665 tests / 0 failures / 5 excluded；diff-check 通过 |
| P1-CLOSEOUT-A5 | 本轮 TEMP 精确清理 | 已完成 | 独立 audit + cleanup lanes | 93 条绝对路径 allowlist；deleted 93 / remaining 0 / failed 0；allowlist 外 5,325 项指纹一致 |
| P1-CLOSEOUT-B | finalize 前 final 实际 fingerprint gate | 未开始 | 下一独立 coherent batch | fingerprint 不符时保留 backup 并 retry/quarantine；通过 fault/finalize 矩阵与独立审查 |
| P1-CLOSEOUT-C | Distributed claim 前 durable placement snapshot | 未开始 | 后续独立 coherent batch | 在任何 claim IO 前把 frozen placement snapshot durable 写入 prepared journal，关闭 claim quorum → journal crash window |
| P1-CLOSEOUT-NEXT | 计划内其余 Phase 1 未完成项 | 未开始 | 后续 planning/executor lanes | 逐项按批准计划和独立审计收口；不得以 B1–B7 已实现替代最终 fingerprint/placement 等验收 |
| PHASE2A-MULTIPART | `Multipart.complete` 的 `Storage.put` / `Storage.assemble` 协议迁移 | 未开始 | Phase 2A 独立批次 | 明确不属于 P1-CLOSEOUT-A；assemble/multipart complete 留在 Phase 2A，multipart part/abort 与 delete/meta-only 继续按 Phase 2B |

## 已完成基线批次：OBJECT-MUTATION-PHASE1（B1–B7）

目标：按已批准协议 `docs/superpowers/plans/2026-07-10-object-mutation-protocol.md` 与实现计划 `docs/superpowers/plans/2026-07-11-object-mutation-phase1-impl.md` 落地 B1–B7：普通 PutObject 的 PG 写权威路径 journal 化、三后端 epoch CAS/durable recovery、Control、recovery worker/scheduler、CLI 与结构化日志。**状态校正：B1–B7 确已实现；后续审计新增的 P1-CLOSEOUT remediation 未全部完成，因此本节不是 Phase 1 总完成声明。**

约束（协议 §6）：只可声明普通 PutObject 的 PG 写权威路径与三后端 durable recovery 已通过；不得声明 ObjectMutation 全覆盖、Copy/Multipart/delete/metadata-only crash-safe、heal/rebalance/tombstone 闭环或 production-ready。aws-cli/mc/boto3 Put/Head/Get/List 顺序活体矩阵由独立 verifier 在隔离环境（heal/rebalance/scanner 全关）单独执行，未执行前 external-client closeout 验收不算完整达成。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 结果 |
| --- | --- | --- | --- | --- |
| B1 | 共享地基：EpochStore/backup manifest/MutationContext/Failpoint/契约扩展 | 已完成 | 独立 executor + 独立 review | APPROVED；45 tests / 0 failures + atomic_commit 回归 15/0 |
| B2 | FS 后端 claim/current/restore/finalize + 协议化 publish | 已完成 | 独立 executor + 独立 review | APPROVED；fs_mutation 15/0 + fs/conformance/atomic 回归 48/0 |
| B3 | ErasureCoded quorum 编排（epoch_quorum D4 钳制） | 已完成 | 独立 executor + 独立 review | APPROVED；ec_mutation 12/0 + 回归 52/0 |
| B4 | Distributed Transport 扩展 + placement snapshot；behaviour callbacks 转强制 | 已完成 | 独立 executor + 独立 review | APPROVED；distributed_mutation 15/0 + 回归 33/0 + 全后端 109/0 |
| B5 | PutObject orchestration（Commit seam）+ Control 接入 | 已完成 | 独立 executor + 独立 review | APPROVED；commit_test 10/0 + 聚焦 40/0 + handler 回归 65/0+92/0+137/0 |
| B6 | Recovery worker + Scheduler（决策表/lease/superseded/quarantine） | 已完成 | 独立 executor + 独立 review | APPROVED；recovery_test 17/0 + 回归 57/0；Phase 1 头号验收通过 |
| B7 | CLI status/recover、协议 §7 日志字段审计、sse_envelope redact、stale_journal 503 映射、Bandit 普通/aws-chunked/crash-recover e2e、`.tmp` 断言收口、STATUS/TODO 同步、唯一一次完整 precommit | 已完成 | 独立 executor + 独立 review | APPROVED（无 high/medium；4 条 low 见 NEXT-1/NEXT-3）；recovery+fs 44/0、CLI 10/0、e2e 7/0、相邻回归 125/0；`mix precommit` -> 3596 tests, 0 failures, 5 excluded |
| NEXT-1 | aws-cli/mc/boto3 活体矩阵（隔离环境） | 已完成 | 独立 verifier | 主 artifact `s3_compat_matrix_external_phase1.json` gate ok 6/6（aws 12/12、mc 10/10、boto3 ok）+ List 补充 artifact 三客户端 7/7；隔离证据（heal/rebalance/scanner/scrubber/lifecycle 全 disabled）；aws-chunked 由 mc 活体覆盖（aws-cli 2.35.20 对 http 端点已改用 CRC64NVME 预计算，差异如实入 artifact）；零残留零 secret；runbook `docs/superpowers/runbooks/object_mutation_phase1_external_matrix.md` 已入仓库 |
| NEXT-2 | Phase 2A byte-producing caller 迁移 | 进行中（未收口） | 独立 planning/executor/review lanes | 既有 caller 可分批迁移；`Multipart.complete` 的 `Storage.put`/`Storage.assemble` 明确保留在 Phase 2A；不得越过仍开放的 Phase 1 fingerprint/placement gate宣称全局闭环 |
| NEXT-3 | B7 复审 low 后续项 | 已完成 | 后续独立批次 | `Path.wildcard` Windows 假覆盖已改 `File.ls`；recovery 锁内收敛失败主动释放租约及构造性覆盖已落地 |

## 当前批次：P2-COMPAT-LONGTAIL-CLOSEOUT-01（已完成）

目标：对 `P2-COMPAT-LONGTAIL-A` 至 `F` 的 Requester Pays、expected-owner、ObjectOwnership、Object Lock、version/delete-marker、Restore SELECT、GetObjectAttributes 等改动做合并语义审计，修复独立审查暴露的确定性根因，归还各切片延后的完整 `mix precommit` 验证债。

约束：本批不新增 LONGTAIL-G API，不实现 directory bucket/access point/Outposts/email grantee，不声称真实 aws-cli/mc/boto3 兼容已关闭，不扩展 schema/migration/生产多节点/发布文档。Requester Pays 通用指南与 SelectObjectContent/DeleteObjectTagging 单操作 API/SDK model 的冲突、equal-date retention、GOVERNANCE→COMPLIANCE 继续标 `VERIFY-AT-IMPL`，不凭猜测改变协议行为。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 结果 |
| --- | --- | --- | --- | --- |
| CLOSEOUT-0 | 独立 planning / verification-debt audit | 已完成 | 独立 planning + audit lanes | `APPROVED PLAN: P2-COMPAT-LONGTAIL-CLOSEOUT-01`；确认 A-F 尚未被 3396-test precommit 联合覆盖，真实外部客户端仍缺失 |
| CLOSEOUT-1 | AWS/SDK 语义核验 | 已完成 | 独立 research lane | 确认 Restore SELECT 需 source `s3:GetObject`、Object Lock metadata action 不随 versionId 降权、GOV/COMPLIANCE 可延期、restore output header 为尾 `/` job prefix；冲突项保留 VERIFY |
| CLOSEOUT-2 | Restore/Object Lock 根因修复 | 已完成 | 独立 implementation lanes | Restore SELECT source gate + output prefix；Object Lock metadata action + retention state machine；focused 51 tests / 0 failures |
| CLOSEOUT-3 | sidecar authority/quorum hardening | 已完成 | implementation + independent review lanes | authoritative full view、partial lock merge、strict missing/unavailable 分类、derived PG index exception boundary；独立 focused 61 tests / 0 failures |
| CLOSEOUT-4 | Console/Object Detail integration hardening | 已完成 | implementation + debugging + review lanes | marker tag edit fail-closed、历史版本保持可读、AWS extension/Legal Hold 语义、删除最后版本导航；独立 focused 87 tests / 0 failures，最终 Show 49 tests / 0 failures |
| CLOSEOUT-5 | 独立多轮复审 | 已完成 | 独立 read-only review lane | 多轮发现并关闭初审 2 High + 2 Medium、sidecar 2 High + 2 Medium、LiveView 最后 1 Medium；最终 `APPROVED`，无 High/Medium/Low |
| CLOSEOUT-6 | 完整门禁与状态同步 | 已完成 | 独立 verifier + 主线程文档集成 | 首次 full run -> 3427 tests / 8 failures / 5 excluded，修复后最终 `mix precommit` -> 3429 tests / 0 failures / 5 excluded；pre/post 工作树指纹一致；STATUS/TODO 已同步 |

## 当前批次：P2-COMPAT-LONGTAIL-F（已完成）

目标：硬化对象 `GetObjectTagging`、`PutObjectTagging`、`DeleteObjectTagging`、`GetObjectAcl`、`PutObjectAcl` 在 Requester Pays、`x-amz-expected-bucket-owner`、versionId、version-specific IAM action 与 BucketOwnerEnforced Object Ownership 上的组合语义，确保 guard fail-closed 且不突变 tag/ACL 元数据；成功 requester-paid 响应只在应该收费时返回 `x-amz-request-charged`；版本化对象子资源按实际目标版本回 `x-amz-version-id`。

约束：本批次不做 bucket tagging/ACL 扩展，不做 directory bucket/access point/Outposts/email-grantee 行为变更，不跑真实 aws-cli/mc/boto3 external smoke，不重写 schema/model，不扩大到 lifecycle/replication/copy/MPU；完整 `mix precommit` 留到更大 compat milestone。官方语义已按 AWS Get/Put/DeleteObjectTagging、Get/PutObjectAcl、Requester Pays 与 Object Ownership 文档核验；规划/复审继续使用独立 Codex read-only lane，不使用 Claude；实现 lane 不自审。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| COMPAT-F-0 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | planning 返回 `APPROVED PLAN: keep P2-COMPAT-LONGTAIL-F Object Tagging + Object ACL subresource Requester Pays / expected-owner / version / ObjectOwnership guard matrix` |
| COMPAT-F-1 | AWS 官方语义核验 | 已完成 | 当前实现 lane | 已核验 object tagging/ACL 的 versionId、version-specific IAM action、`x-amz-expected-bucket-owner`、Requester Pays authenticated payer/charged header 与 BucketOwnerEnforced read/write ACL 语义 |
| COMPAT-F-2 | 读取相关实现与现有测试 | 已完成 | 当前实现 lane | 已读取 `Tagging`/`Acl` handlers、`Authz` version action 逻辑、`Objects` tags API、tagging/ACL/request-payment/ownership 相邻测试；定位 Tagging version authz 与 ACL/tagging version response header 缺口 |
| COMPAT-F-3 | 实现 Tagging/ACL guard 矩阵与根因修复 | 已完成 | 当前实现 lane | 已新增 `Objects.get_tags_with_version/3`、`put_tags_with_version/4`；Tagging handler 回实际版本并使用 version-specific IAM action；ACL handler Get/PutObjectAcl 回实际版本；review follow-up 修复 delete marker 行不可作为 tagging/ACL 普通目标，显式 delete-marker `versionId` 回 405，current marker 回 404；测试补 Tagging Requester Pays/version action 矩阵、ACL version response header、Requester Pays PutObjectAcl guard 与 delete-marker 回归 |
| COMPAT-F-4 | focused/adjacent 验证 | 已完成 | 当前实现 lane | Baseline focused `mix test test/maxio/s3/tagging_e2e_test.exs test/maxio/s3/acl_test.exs test/maxio/s3/request_payment_e2e_test.exs --max-failures 1` -> 50 tests, 0 failures；Adjacent Tagging/ACL/RequesterPays/OwnershipControls/ExpectedOwner/Authz/Versioning -> 101 tests, 0 failures；delete-marker follow-up `mix test test/maxio/s3/tagging_e2e_test.exs test/maxio/s3/acl_test.exs` -> 34 tests, 0 failures；`MIX_ENV=test mix compile --warnings-as-errors --no-deps-check` passed；direct formatter equivalence passed；scoped diff-check passed |
| COMPAT-F-5 | 独立 Codex review 与状态同步 | 已完成 | 独立 Codex read-only lane + 当前实现 lane | 首轮 independent review 发现 1 Medium delete-marker subresource 语义缺口；实现 lane 修复后 follow-up review `Findings: None`；本 TODO 已同步；完整 `mix precommit` 延后 |

## 当前批次：P2-COMPAT-LONGTAIL-E（已完成）

目标：硬化 Object Lock 的 `PutObjectRetention`、`GetObjectRetention`、`PutObjectLegalHold`、`GetObjectLegalHold` 在 Requester Pays、`x-amz-expected-bucket-owner`、versionId 与 governance bypass 上的组合语义，确保非 owner 缺少/非法 payer 时 fail-closed，不读写对象锁元数据；成功 requester-paid 响应只在应该收费时返回 `x-amz-request-charged`；wrong expected-owner 在 XML 输出或元数据 mutation 前失败；governance bypass 仍同时要求 `s3:BypassGovernanceRetention` 与有效 payer。

约束：本批次不做 directory bucket/access point 行为，不新增 Object Lock 数据模型，不重写 Bucket ObjectLockConfiguration，不要求真实 aws-cli/mc/boto3 external smoke，不做生产多节点或发布文档；开发中只跑 focused/adjacent 验证，完整 `mix precommit` 留到更大 compat milestone。官方语义按 AWS GetObjectRetention、PutObjectRetention、GetObjectLegalHold、PutObjectLegalHold 与 Requester Pays 文档核验；规划/复审继续使用独立 Codex read-only lane，不使用 Claude；实现 lane 不自审。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| COMPAT-E-0 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | planning 返回 `APPROVED PLAN: P2-COMPAT-LONGTAIL-E Object Lock Requester Pays / Governance Guard Matrix` |
| COMPAT-E-1 | AWS 官方语义核验 | 已完成 | 当前实现 lane | 已核验 Retention/LegalHold GET/PUT 的 `x-amz-request-payer`、`x-amz-expected-bucket-owner`、PUT charged response header 与 governance bypass 权限语义 |
| COMPAT-E-2 | 读取相关实现与现有测试 | 已完成 | 当前实现 lane | 已确认 `ObjectLock` handler 对 object retention/legal hold 的 expected-owner 与 RequestPayer guard 顺序；已读取 RequesterPays/expected-owner/authz 相邻测试模式 |
| COMPAT-E-3 | 实现 Object Lock guard 矩阵 | 已完成 | 当前实现 lane | 本轮只补 `test/maxio/s3/object_lock_e2e_test.exs`：非 owner Requester Pays 成功/失败、owner bypass、versionId 定向、governance bypass 权限+payer 双门；生产 handler 未改 |
| COMPAT-E-4 | focused/adjacent 验证 | 已完成 | 当前实现 lane | 复验后 Focused `mix test test/maxio/s3/object_lock_e2e_test.exs --max-failures 1` -> 22 tests, 0 failures；Adjacent ObjectLock/RequestPayment/ExpectedOwner/Authz -> 72 tests, 0 failures；`mix compile --warnings-as-errors`、targeted format、scoped diff-check、TODO no-index whitespace passed；完整 `mix precommit` 延后 |
| COMPAT-E-5 | 独立 Codex review 与状态同步 | 已完成 | 独立 Codex read-only lane + 当前实现 lane | 首轮 Codex review `APPROVED_WITH_LOW_FINDINGS`，无 High/Medium；已补齐 Retention/LegalHold 按 API payer 变体覆盖并修正 TODO 验证策略，且复验通过；follow-up review `APPROVED - no High/Medium/Low findings`；不使用 Claude；`STATUS.md` 与本 TODO 已同步 |

## 当前批次：P2-COMPAT-LONGTAIL-D（已完成）

目标：硬化桶级 discovery/list 入口在 Requester Pays、`x-amz-expected-bucket-owner`、非 owner 授权与错误响应形态上的组合语义，覆盖 `HeadBucket`、`GetBucketLocation`、`ListObjects` V1/V2、`ListObjectVersions`、`ListMultipartUploads`、`ListParts`，确保 guard 失败发生在 XML/list 输出前，成功 charged/owner-bypass 响应头符合 S3 语义。

约束：本批次不做 directory bucket/access point 行为，不要求真实 aws-cli/mc/boto3 external smoke，不重写分页/encoding/list XML，不新增 checksum/SSE/RestoreStatus 字段，不做生产多节点或发布文档；开发中只跑 focused/adjacent 验证，完整 `mix precommit` 留到更大 compat milestone。官方语义按 AWS HeadBucket、GetBucketLocation、ListObjects、ListObjectsV2、ListObjectVersions、ListMultipartUploads、ListParts 与 Requester Pays 文档核验；规划/复审继续使用独立 Codex read-only lane，不使用 Claude；实现 lane 不自审。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| COMPAT-D-0 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | planning 返回 `APPROVED PLAN: P2-COMPAT-LONGTAIL-D Bucket Listing/Discovery Guard Matrix` |
| COMPAT-D-1 | AWS 官方语义核验 | 已完成 | 当前实现 lane | 已核验 bucket/list/multipart listing 的 `x-amz-expected-bucket-owner`、`x-amz-request-payer`、Requester Pays charged-header/owner-bypass 语义；按核验结果补 guard 与测试 |
| COMPAT-D-2 | 读取相关实现与现有测试 | 已完成 | 当前实现 lane | 已确认 `Multipart.list_parts/1` 与 `Multipart.list_multipart_uploads/1` 已有两类 guard；`Bucket` handler 的 list V1/V2/versions 已有 Requester Pays 但缺 expected-owner，HeadBucket/GetBucketLocation 缺 expected-owner |
| COMPAT-D-3 | 实现 Bucket listing/discovery guard 矩阵 | 已完成 | 当前实现 lane | 已补 `Bucket` handler expected-owner guard；新增 `test/maxio/s3/bucket_listing_guard_matrix_test.exs` 覆盖 HeadBucket/GetBucketLocation/ListObjects V1/V2/ListObjectVersions/ListMultipartUploads/ListParts |
| COMPAT-D-4 | focused/adjacent 验证 | 已完成 | 当前实现 lane | Focused -> 3 tests, 0 failures；adjacent bucket/list/requester/expected-owner/multipart/authz -> 94 tests, 0 failures；compile/format/diff-check/no-index whitespace passed；完整 `mix precommit` 延后 |
| COMPAT-D-5 | 独立 Codex review 与状态同步 | 已完成 | 独立 Codex read-only lane + 当前实现 lane | 初始 review `APPROVED`，实现 lane 补齐 GetBucketLocation missing-bucket precedence 直接回归；follow-up review `APPROVED - no High/Medium/Low findings`；不使用 Claude；`STATUS.md` 与本 TODO 已同步 |

## 当前批次：P2-COMPAT-LONGTAIL-C（已完成）

目标：硬化 `GetObjectAttributes` 在 Requester Pays、`x-amz-expected-bucket-owner`、非 owner 授权、条件 `304` 响应头上的组合语义，确保 guard 失败时返回结构化 S3 XML 错误且不生成 attributes XML；成功 charged/owner/version 条件响应保留 S3 关键响应头。

约束：本批次不要求真实 aws-cli/mc/boto3 external smoke，不新增 ObjectAttributes 字段/校验算法，不做 directory bucket 行为，不做生产多节点或发布文档；开发中只跑 focused/adjacent 验证，完整 `mix precommit` 留到更大 compat milestone。官方语义已按 AWS GetObjectAttributes 与 Requester Pays 文档核验；规划/复审继续使用独立 Codex read-only lane，不使用 Claude；实现 lane 不自审。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| COMPAT-C-0 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | planning 返回 `APPROVED PLAN: P2-COMPAT-LONGTAIL-C GetObjectAttributes Requester Pays / Owner Guard Matrix` |
| COMPAT-C-1 | AWS 官方语义核验 | 已完成 | 当前实现 lane | 已核验 GetObjectAttributes `RequestPayer`、`ExpectedBucketOwner`、required object attributes header、version/non-version 权限与条件 304 语义；Requester Pays signed/query payer 与 charged-header 规则已核验 |
| COMPAT-C-2 | 读取相关实现与现有测试 | 已完成 | 当前实现 lane | 已确认 `Object.get_attributes/1` 的 conditional 304 直接 `send_resp/3` 会丢 charged/version/etag/last-modified；现有测试已有 authz/version/SSE 基础覆盖 |
| COMPAT-C-3 | 实现 GetObjectAttributes guard/304 矩阵 | 已完成 | 当前实现 lane | 已修 `get_attributes/1` conditional 304 复用 `send_not_modified/3`；已覆盖 missing/signed/query/invalid/unsigned payer、owner bypass、expected owner wrong/correct、conditional 304 charged/version/etag/last-modified headers |
| COMPAT-C-4 | focused/adjacent 验证 | 已完成 | 当前实现 lane | Focused ObjectAttributes -> 18 tests, 0 failures；adjacent ObjectAttributes + RequesterPays + expected-owner + authz matrix -> 68 tests, 0 failures；`mix compile --warnings-as-errors` passed；targeted format passed；scoped diff-check/no-index whitespace passed；完整 `mix precommit` 延后 |
| COMPAT-C-5 | 独立 Codex review 与状态同步 | 已完成 | 独立 Codex read-only lane + 当前实现 lane | review 返回 `APPROVED - no High/Medium/Low findings`；不使用 Claude；`STATUS.md` 与本 TODO 已同步 |

## 当前批次：P2-COMPAT-LONGTAIL-B（已完成）

目标：硬化 `SelectObjectContent` 在 Requester Pays、`x-amz-expected-bucket-owner`、非 owner 授权与错误响应形态上的组合语义，确保 guard 失败时返回结构化 S3 XML 错误而不是事件流，并且在 Select 执行/输出前 fail-closed。

约束：本批次不要求真实 aws-cli/mc/boto3 external smoke，不扩展 Select SQL/BZIP2/Parquet/事件流重写，不做生产多节点或发布文档；开发中只跑 focused/adjacent 验证，完整 `mix precommit` 留到更大 compat milestone。官方语义不凭记忆，先查 AWS 文档；规划/复审继续使用独立 Codex read-only lane，不使用 Claude；实现 lane 不自审。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| COMPAT-B-0 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | planning 返回 `APPROVED PLAN: P2-COMPAT-LONGTAIL-B SelectObjectContent Requester Pays / Owner Guard Matrix` |
| COMPAT-B-1 | AWS 官方语义核验 | 已完成 | 当前实现 lane | 已核验 SelectObjectContent `RequestPayer`、`ExpectedBucketOwner`、`select-type=2`、所需 `s3:GetObject` 权限与 XML/error-stream 边界；按核验结果补测试 |
| COMPAT-B-2 | 读取相关实现与现有测试 | 已完成 | 当前实现 lane | 已读取 `select_object_content_e2e_test`、handler、`RequestPayer`、`ExpectedBucketOwner`、`ActionMap`；确认本切片最小改动面为 e2e guard 矩阵 |
| COMPAT-B-3 | 实现 SelectObjectContent guard 矩阵 | 已完成 | 当前实现 lane | 已覆盖 missing/signed/query/invalid/unsigned payer、owner bypass、expected owner wrong/correct、guard 失败 XML 响应；生产代码暂未改动 |
| COMPAT-B-4 | focused/adjacent 验证 | 已完成 | 当前实现 lane | Focused SelectObjectContent -> 182 tests, 0 failures；adjacent SelectObjectContent + RequesterPays + expected-owner + authz matrix -> 232 tests, 0 failures；`mix compile --warnings-as-errors` passed；targeted format passed；no-index whitespace passed；完整 `mix precommit` 延后 |
| COMPAT-B-5 | 独立 Codex review 与状态同步 | 已完成 | 独立 Codex read-only lane + 当前实现 lane | 首轮 review `NOT APPROVED`，仅 1 Low：TODO 仍写着相邻验证/compile/format 是下一步；已修复该 stale 状态；follow-up review `APPROVED - no High/Medium/Low findings`；`STATUS.md` 与本 TODO 已同步 |

## 当前批次：P2-COMPAT-LONGTAIL-A（已完成）

目标：硬化 ACL、Object Ownership、Requester Pays 在低频但高风险路径上的组合语义，优先覆盖 POST Object 浏览器表单、Restore Select 输出对象、CopyObject/UploadPartCopy/MPU 旁路和已有 ACL 子资源路径，确保 Requester Pays 不被签名/表单/生成对象路径绕过，BucketOwnerEnforced 不接受非法 ACL 落盘。

约束：本批次不要求真实 aws-cli/mc/boto3 external smoke，不扩大到 S3 Select BZIP2/Parquet、外部 KMS/HSM、发布文档或生产多节点；开发中只跑 focused/adjacent 验证，完整 `mix precommit` 留到 coherent batch 收口。官方语义不凭记忆，先查 AWS 文档；规划/复审继续使用独立 Codex read-only lane，不使用 Claude；实现 lane 不自审。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| COMPAT-A-0 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | planning 返回 `APPROVED PLAN: P2-COMPAT-LONGTAIL-A ACL/Object Ownership/Requester Pays Cross-Matrix`；确认本批优先补协议行为，而不是继续堆 release/docs evidence |
| COMPAT-A-1 | AWS 官方语义核验 | 已完成 | 当前实现 lane | 已核验 Object Ownership BucketOwnerEnforced ACL 规则、Requester Pays signed payer/charged header 规则、RestoreObject RequestPayer 入口；按核验结果补测试 |
| COMPAT-A-2 | 读取相关实现与现有测试 | 已完成 | 当前实现 lane | 已定位 `RequestPayer`、`OwnershipControls`、`PostObjectForm`、`Object.post_form/2`、`Restore.post/1` 与 test helper；确定最小改动面为现有 e2e tests |
| COMPAT-A-3 | 实现交叉矩阵与必要根因修复 | 已完成 | 当前实现 lane | 已覆盖 POST Object 缺少/携带 `x-amz-request-payer`、BucketOwnerEnforced 下非法/例外 ACL、Restore Select output 的 source/output requester-pays 组合；新增矩阵未暴露生产代码缺陷 |
| COMPAT-A-4 | focused/adjacent 验证 | 已完成 | 当前实现 lane | Focused -> 44 tests, 0 failures；adjacent -> 96 tests, 0 failures；compile/format/scoped diff-check passed；未跟踪 scoped 文件 no-index whitespace 检查 passed；完整 `mix precommit` 延后到更大 compat milestone |
| COMPAT-A-5 | 独立 Codex review 与状态同步 | 已完成 | 独立 Codex read-only lane + 当前实现 lane | 首轮 review `NOT APPROVED`：1 Medium（Restore Select output bucket Requester Pays 未被独立证明）；已补 output-only Requester Pays 回归。Follow-up review `APPROVED`，残余风险为复审未重跑命令、未重审 RestoreObject SELECT 更广兼容面；不使用 Claude；`STATUS.md` 与本 TODO 已同步 |

## 最近完成批次：P2-RELEASE-A（已完成）

目标：建立发布准备度证据 bundle，把当前已经存在的压力/故障、compat、ops gate/live rehearsal、外部客户端可用性、worktree 状态与 precommit 文档证据聚合成一个机器可读 JSON artifact。缺失、过期、畸形、docs-only 或真实外部客户端不可用必须显式变成 attention/blocked evidence，绝不静默算 ready。

约束：本批次不运行真实 external smoke，不要求 aws-cli/mc/boto3 已安装，不启动服务，不执行 mutating ops，不声称生产多节点发布完成；只读聚合 artifact 与本地环境证据。开发中只跑 focused/adjacent 验证；完整 `mix precommit` 已在 coherent batch 收口统一运行。规划/复审继续使用独立 Codex read-only lane，不使用 Claude；实现 lane 不自审。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| RELEASE-A-0 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | planning 返回 `APPROVED PLAN: P2-RELEASE-A Release Readiness Evidence Bundle`；确认真实 aws/mc/boto3 仍不可用，external compat 不能在本批假装关闭 |
| RELEASE-A-1 | 读取 release/ops/compat artifact 模式 | 已完成 | 当前实现 lane | 已复用现有 `Maxio.Compat.Matrix`、`Maxio.Compat.StressCampaign`、Ops artifacts readers 与 Mix task 模式 |
| RELEASE-A-2 | 实现 release readiness projection 与 CLI | 已完成 | 当前实现 lane | 已新增 `Maxio.Ops.ReleaseReadinessBundle` 与 `mix maxio.release.readiness`；真实 `mix maxio.release.readiness --artifact artifacts/p2_release_readiness_local.json` -> gate_status=attention，stress ok，其余缺口显式 attention |
| RELEASE-A-3 | focused/adjacent 验证 | 已完成 | 当前实现 lane | Focused `mix test test/maxio/ops/release_readiness_bundle_test.exs test/mix/tasks/maxio_release_readiness_test.exs --max-failures 1` -> 10 tests, 0 failures；相邻 `mix test test/maxio/ops/release_readiness_bundle_test.exs test/mix/tasks/maxio_release_readiness_test.exs test/maxio/ops/compat_matrix/artifacts_test.exs test/maxio/compat/matrix_test.exs test/maxio/compat/stress_campaign_test.exs test/maxio/ops/gate/artifacts_test.exs test/maxio/ops/rehearsal_bundle/artifacts_test.exs --max-failures 1` -> 59 tests, 0 failures；`mix compile --warnings-as-errors`、`mix format --check-formatted`、scoped `git diff --check` passed（仅既有 `STATUS.md` CRLF warning）；未跟踪 scoped 文件 no-index whitespace 检查通过 |
| RELEASE-A-4 | 独立 Codex review 与收口 | 已完成 | 独立 Codex read-only lane + 当前实现 lane | 首轮 review `NOT APPROVED`：1 Medium（`--skip-external-probes --require-external-clients` 可绕过 required clients）+ 2 Low（dirty count 被 sample 截断、外部客户端本机路径原样透传）；均已修复并补回归。Follow-up review 又发现 1 Medium（precommit evidence 取历史最后匹配）+ 1 Low（带空格 Windows 路径脱敏不完整）；均已修复并补回归。最终独立 Codex review `APPROVED`，无 High/Medium，1 Low 为未跟踪文件 diff-check 证据 caveat，已用 no-index whitespace 检查补证；不使用 Claude |
| RELEASE-A-5 | 完整 precommit / STATUS 同步 | 已完成 | 当前实现 lane | 完整 `mix precommit`（低 scheduler Windows 配置）-> 3396 tests, 0 failures, 5 excluded；`STATUS.md` 与本 TODO 已同步；`artifacts/p2_release_readiness_local.json` 重新生成后读取最新 precommit evidence |

## 最近完成批次：P2-STRESS-A（已完成）

目标：建立本地可重复的压力与故障注入证据闭环。默认 profile 必须适合当前 Windows 本地环境，能生成 JSON artifact，记录 child suites、命令、状态、测试计数、stress 参数和 fail-closed gate 结果；放大压力只允许通过显式 env/CLI opt-in。

约束：本批次不关闭 `P0-COMPAT-2C`，不要求真实 aws-cli/mc/boto3，不做真实生产多节点/断网/拔盘/PG 故障作为唯一验收，不做 release/deploy 文档大改，不实现生产 HSM/KMS，不铺开低频 S3 API 长尾。开发中只跑 focused/adjacent 验证；完整 `mix precommit` 仅在本 coherent batch 收口时运行。规划/复审继续使用独立 Codex read-only lane，不使用 Claude；实现 lane 不自审。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| STRESS-A-0 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | planning 返回 `APPROVED PLAN: P2-STRESS-A`；确认优先级高于受阻的真实外部客户端 compat、release 文档和长尾 S3 API |
| STRESS-A-1 | 扩展 streaming stress 配置 | 已完成 | 当前实现 lane | 已增加 `MAXIO_STREAMING_STRESS_CONCURRENCY` 与 `MAXIO_STREAMING_STRESS_MULTIPART_UPLOADS`，artifact evidence 记录参数和 env；focused config 覆盖通过 |
| STRESS-A-2 | 增强 streaming stress matrix 覆盖 | 已完成 | 当前实现 lane | 已覆盖并发 PutObject/MPU、BadDigest retry/no-pollution、Complete 后 GET SHA256 校验；`mix test test/maxio/s3/streaming_stress_matrix_test.exs --max-failures 1` -> 3 tests, 0 failures |
| STRESS-A-3 | 把 stress/fault suites 纳入 compat matrix artifact | 已完成 | 当前实现 lane | 已新增 optional `storage_fault_matrix` 与 `ops_resilience_matrix`，并保留 `streaming_stress_matrix`；focused matrix tests 通过 |
| STRESS-A-4 | 新增 operator CLI campaign | 已完成 | 当前实现 lane | 已新增 `Maxio.Compat.StressCampaign` 与 `mix maxio.stress.campaign`；真实 local campaign artifact `artifacts/p2_stress_local.json` gate_status=ok |
| STRESS-A-5 | focused/adjacent 验证 | 已完成 | 当前实现 lane | Focused config/matrix/campaign/task -> 28 tests, 0 failures；streaming stress -> 3 tests, 0 failures；compat Console adjacent -> 12 tests, 0 failures；compile/format/diff-check passed；真实 campaign artifact -> gate_status=ok |
| STRESS-A-6 | 独立 Codex review 与收口 | 已完成 | 独立 Codex read-only lane + 当前实现 lane | review `APPROVED`，无 High/Medium；1 Low（TODO 滞后）已修复；`STATUS.md` 已同步；完整 `mix precommit` -> 3386 tests, 0 failures, 5 excluded |

## 最近完成批次：P1-IAM-GOV-A（已完成）

目标：在不依赖真实外部客户端和生产 HSM/KMS 的前提下，推进 IAM/授权治理这一 MinIO 兼容核心面：盘点并补齐本地已有模型能支撑的 IAM Query API surface，补跨账号/多账号授权矩阵，硬化 access key lifecycle/audit 语义，明确 local KMS 与外部 KMS/HSM 的策略边界，并补结构化授权日志证据。

约束：本批次不要求真实 aws-cli/mc/boto3 external smoke，不实现生产 HSM/KMS，不铺开低频 S3 API 长尾，不做大规模压力/故障 campaign。开发中只跑 focused/adjacent 验证；完整 `mix precommit` 延后到本 coherent batch 收口。规划/复审继续使用独立 Codex read-only lane，不使用 Claude；实现 lane 不自审。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| IAMGOV-A-0 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | planning 返回 `APPROVED PLAN: P1-IAM-GOV-A`；确认 IAM/governance 优先级高于 P2-STRESS/P2-RELEASE/P2-COMPAT-LONGTAIL |
| IAMGOV-A-1 | 盘点 IAM Query/API/Mix task/test 缺口 | 已完成 | 当前实现 lane | Query API `@supported_actions` 盘点完成：118 个 supported action 均已在 `query_api_test` 中出现，missing=0；本批转向授权治理高风险缺口 |
| IAMGOV-A-2 | 补齐本地可支撑 IAM Query API surface | 已完成 | 当前实现 lane | 本批盘点未发现已有 facade/model 但 Query API 缺失的 supported action；后续新增 IAM facade 时再按同一清单增量补 Query API |
| IAMGOV-A-3 | 跨账号/多账号授权矩阵 | 已完成 | 当前实现 lane | 已补 S3 Authz allow/deny 结构化决策日志：request_id/principal/resource/required_action/decision/policy_source/account_id；已接入 `aws:PrincipalAccount`（本地空账号 -> `local`，匿名 -> `anonymous`），覆盖外部账号 allow、其它账号/匿名 implicit deny、匿名专属 allow、显式 deny优先级与日志 `policy_source=explicit_deny`；已修正 owner/root explicit-deny 语义：普通数据动作显式 Deny 优先，root 仅对 `GetBucketPolicy`/`PutBucketPolicy`/`DeleteBucketPolicy` 保留恢复特例；新增 `Authz.object_action_allowed?/7`，DeleteObjects/ObjectLock governance bypass 旁路复用统一 permissions boundary/session/resource policy 判定；focused authz matrix -> 27 tests, 0 failures；root explicit-deny focused -> 61 tests, 0 failures；review-fix focused -> 25 tests, 0 failures；review-fix core -> 81 tests, 0 failures；adjacent authz/copy/delete/identity -> 38 tests, 0 failures；adjacent object-lock/MFA/PAB -> 49 tests, 0 failures；compile/format/git diff-check passed；独立 Codex follow-up review 已批准 |
| IAMGOV-A-4 | access key lifecycle/audit 硬化 | 已完成 | 当前实现 lane | 已扩展 IAM Query error 结构化日志：caller `principal_arn`、白名单 `user_name`/`access_key_id`、access-key lifecycle `target_principal_arn`、code/status；覆盖 root 最后活跃 key 保护失败与跨 UserName scope 失败，确认不泄露 secret；`query_api_test` -> 49 tests, 0 failures；final query/authz focused -> 76 tests, 0 failures；独立 Codex follow-up review 已批准 |
| IAMGOV-A-5 | local KMS / external KMS-HSM 边界 | 已完成 | 当前实现 lane | 已新增 `Maxio.KMS.status/0` 非 secret provider boundary 状态：区分 `:local_compat` 与 `:external_provider`，默认 `LocalProvider` 明确为本地兼容而非 external KMS/HSM；只有 provider 显式 `production_hsm?/0` 才可声明生产 HSM；状态仅暴露 provider/default_key_id/本地密钥配置存在性与数量，不暴露 master key/DEK；`sse_test` -> 10 tests, 0 failures；compile/format passed；独立 Codex follow-up review 已批准 |
| IAMGOV-A-6 | focused/adjacent 验证 | 已完成 | 当前实现 lane | 已跑 authz focused/adjacent、Query API focused、KMS/SSE focused、root explicit-deny focused、DeleteObjects/ObjectLock 旁路相邻验证、review-fix focused/core、compile、format、diff-check；完整 `mix precommit` -> 3375 tests, 0 failures, 5 excluded |
| IAMGOV-A-7 | 独立 Codex review 与收口 | 已完成 | 独立 Codex read-only lane + 当前实现 lane | 首轮 review `NOT APPROVED` 的 2 个 High 已修复；同一独立 Codex read-only lane follow-up review `APPROVED`，无 High/Medium/Low findings；不使用 Claude；完整 `mix precommit` 通过并同步 `STATUS.md` |

## 更早完成批次：P1-CONSOLE-OPS-CLOSEOUT-01（已完成）

目标：对 OPS4A-OPS4Q 已完成的 Console/Ops 运维证据面做 coherent batch 收口验证，覆盖 `/ops/gate`、`/ops/rebalance`、`/ops/scan`、`/ops/replacement`、`/ops/cluster`、`/ops/upgrade`、`/ops/compat`、`/ops/observability`、`/ops/recovery` 的 route/sidebar/read-only/no button/no form、projection fail-closed、reader crash/malformed/stale/future evidence 语义，并统一跑一次完整 `mix precommit`。

约束：本批次默认不新增功能、不新增 `/ops/*` 页面、不执行 external smoke、不要求真实 aws-cli/mc/boto3、不改 IAM/account/KMS/HSM 语义；只允许修复 focused/adjacent/precommit 暴露的真实问题，且必须从根因修复。复审继续使用独立 Codex read-only lane，不使用 Claude；实现 lane 不自审。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| CLOSEOUT-0 | 核对 OPS4Q 收口与队列头 | 已完成 | 当前实现 lane | OPS4Q 已收口并同步 `STATUS.md`；队列头推进到 Console/Ops closeout |
| CLOSEOUT-1 | 独立 Codex planning 选择 closeout 批次 | 已完成 | 独立 Codex read-only lane | planning 返回 `APPROVED PLAN: P1-CONSOLE-OPS-CLOSEOUT-01`；优先归还 OPS4A-OPS4Q 延后的完整 precommit 验证债 |
| CLOSEOUT-2 | Console/Ops focused/adjacent 验证 | 已完成 | 当前实现 lane | `mix test test/maxio/ops ... ops_*_live ... shell_test --max-failures 1` -> 134 tests, 0 failures |
| CLOSEOUT-3 | 静态验证 | 已完成 | 当前实现 lane | `mix compile --warnings-as-errors` passed；`mix format --check-formatted` passed；LiveView/projection static grep passed；diff-check passed（仅 `STATUS.md` CRLF warning） |
| CLOSEOUT-4 | 完整 `mix precommit` | 已完成 | 当前实现 lane | 低 scheduler 配置运行完整 `mix precommit` -> 3363 tests, 0 failures, 5 excluded |
| CLOSEOUT-5 | 独立 Codex read-only review | 已完成 | 独立 Codex read-only lane | final review 返回 `APPROVED - no High/Medium/Low findings`；不使用 Claude |
| CLOSEOUT-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步；记录完整 `mix precommit` -> 3363 tests, 0 failures, 5 excluded |

## 最近完成批次：P1-CONSOLE-OPS-OPS4Q（已完成）

目标：新增 `/ops/recovery` 只读 Recovery/DR Readiness Console，回答 operator “当前集群能否安全恢复”。页面聚合现有 P0 live rehearsal bundle、ops gate artifact、cluster/topology drift、scanner/drive health、replacement/rebalance workflow、upgrade/rollback readiness、observability readiness 等证据；缺失、过期、future-dated、malformed、reader crash 或未知 shape 必须显示为 attention/blocked，绝不静默健康。

约束：页面只读，不新增恢复执行、故障注入、scheduler run、gate run、scanner/heal/rebalance/replacement execution、topology activation、lock mutation、bearer-token generation、HTTP scrape、System/Mix 命令或 Repo write。规划/复审必须使用独立 Codex read-only lane，不使用 Claude；实现 lane 不自审。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4Q-0 | 核对 OPS4P 收口与队列头 | 已完成 | 当前实现 lane | OPS4P 已通过修复后聚焦/相邻/compile/format/static grep/diff-check 和独立 Codex follow-up 复审；队列头推进到 OPS4Q |
| OPS4Q-1 | 建立完整实时 TODO 看板 | 已完成 | 当前实现 lane + 独立 Codex read-only lane | 顶部总控、当前执行指针、全量任务总表、当前批次任务表、后续执行队列、风险表和实时更新协议已集中到本文件；独立 Codex read-only 复核 `APPROVED`，无 High/Medium/Low findings |
| OPS4Q-2 | 独立 Codex planning 选择下一切片 | 已完成 | 独立 Codex read-only lane | planning lane 返回 `APPROVED PLAN`：实现 `/ops/recovery` read-only Recovery/DR Readiness Console；该方案优先级高于故障注入执行器、真实外部 SDK compat 和 IAM/data-plane 维护线 |
| OPS4Q-3 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已读取相邻 projection modules、LiveViews、router/layout/sidebar 和 tests，并按既有 Console/Ops projection + LiveView 模式落地 |
| OPS4Q-4 | 实现 OPS4Q 切片 | 已完成 | 当前实现 lane | 已新增 `Maxio.Ops.RecoveryReadinessConsole`、`MaxioWeb.OpsRecoveryLive`、route/sidebar、projection/LiveView tests；页面保持只读、fail-closed、结构化证据和现有架构契约 |
| OPS4Q-5 | 聚焦/相邻验证与静态检查 | 已完成 | 当前实现 lane | 修复后 focused recovery/shell 验证通过：8 tests, 0 failures；adjacent rehearsal/gate/cluster/scan/replacement/rebalance/upgrade/observability + LiveView/shell 验证通过：112 tests, 0 failures；`mix compile --warnings-as-errors` passed；scoped format/static grep/trailing whitespace/diff-check passed；完整 precommit 延后 |
| OPS4Q-6 | 独立 Codex read-only 复审 | 已完成 | 独立 Codex read-only lane | 首轮 `NOT APPROVED`：1 High 已修复：`status: "ok"` parse/read 成功不再掩盖 gate_status/blockers/warnings/checks/child_results readiness；follow-up `APPROVED - no High/Medium/Low findings` |
| OPS4Q-7 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步 OPS4Q 收口；完整 `mix precommit` 按批量验证规则继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4P（已完成）

目标：新增 `/ops/observability` 只读 Console 页面，把现有 MinIO-style Prometheus scrape surface、Prometheus auth boundary、local S3 request metrics ledger、Dashboard 统计口径、operator 只读命令和 blockers/warnings 汇总为一个 observability readiness 视图。页面只展示证据，不生成 bearer token、不运行 `maxio.prometheus.generate` 或 `maxio.s3.request_metrics`、不执行 HTTP scrape、不采样 drive、不运行 scheduler/scan/heal/rebalance/gate、不写 DB。

验收 DOM IDs：`#ops-observability`、`#nav-ops-observability`、`#ops-observability-readonly-boundary`、`#ops-observability-summary`、`#ops-observability-prometheus`、`#ops-observability-request-metrics`、`#ops-observability-dashboard-stats`、`#ops-observability-operator-commands`、`#ops-observability-blockers`、`#ops-observability-warnings`、`#ops-observability-cross-links`。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4P-0 | 核对 OPS4O 收口与队列头 | 已完成 | 当前实现 lane | OPS4O 已通过修复后聚焦/相邻/静态验证和独立 Codex follow-up 复审；`STATUS.md` 与本 TODO 已同步；队列头推进到 OPS4P |
| OPS4P-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | planning lane 选定 `Ops Observability & Metrics Readiness Console`；不使用 Claude；worker_done 发送遇到 Orca CLI 连接问题，但终端输出确认方案 |
| OPS4P-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已读取 Prometheus、request metrics ledger、Dashboard stats、router/layout/nav 与相邻测试 |
| OPS4P-3 | 实现下一切片 | 已完成 | 当前实现 lane | 已新增 `Maxio.Ops.ObservabilityConsole`、`/ops/observability` LiveView、route/sidebar 入口与 tests；页面无 token generation、Mix/System/HTTP/Repo write/ops execution entrypoint |
| OPS4P-4 | 聚焦/相邻验证与静态检查 | 已完成 | 当前实现 lane | 修复后聚焦 `mix test test/maxio/ops/observability_console_test.exs test/maxio_web/live/ops_observability_live_test.exs test/maxio_web/live/shell_test.exs --max-failures 1` -> 10 tests, 0 failures；相邻 prometheus/request metrics/dashboard batch -> 39 tests, 0 failures；`mix compile --warnings-as-errors` passed；scoped format/static grep/diff-check passed；完整 precommit 延后 |
| OPS4P-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | 首轮 `NOT APPROVED`：1 Medium（recent metric DOM id 重复风险）和 1 Low（Bearer redaction 形态覆盖不足）已修复；补 recent row window uniqueness 与 Authorization Bearer redaction 回归；follow-up `APPROVED`，无 High/Medium/Low findings；不使用 Claude |
| OPS4P-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步 OPS4P 收口；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4O（已完成）

目标：新增 `/ops/compat` 只读 Console 页面，把 `Maxio.Compat.Matrix` 归档 artifact 中的 internal S3 compatibility suites、external client availability、external smoke evidence、streaming stress parameters、blockers/warnings、artifact provenance 和 staleness 显示给 operator。页面只展示既有 artifact 证据，不运行 compat matrix、不探测外部客户端、不执行 external smoke、不执行 System/Mix/test/HTTP 命令。复审继续使用独立 Codex，不使用 Claude。

验收 DOM IDs：`#ops-compat`、`#nav-ops-compat`、`#ops-compat-readonly-boundary`、`#ops-compat-summary`、`#ops-compat-artifacts`、`#ops-compat-selection-warning`、`#ops-compat-artifact-provenance`、`#ops-compat-internal-suites`、`#ops-compat-external-clients`、`#ops-compat-external-smoke`、`#ops-compat-streaming-stress`、`#ops-compat-blockers`、`#ops-compat-warnings`、`#ops-compat-cross-links`。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4O-0 | 核对 OPS4N 收口与队列头 | 已完成 | 当前实现 lane | OPS4N 已通过修复后聚焦/相邻/静态验证和独立 Codex follow-up 复审；`STATUS.md` 与本 TODO 已同步；队列头推进到 OPS4O |
| OPS4O-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Locke 选定 `/ops/compat Read-only S3 Compatibility & External Client Evidence Console`；继续不使用 Claude |
| OPS4O-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已读取 `Maxio.Compat.Matrix`、`ExternalSmoke`、`StreamingStressConfig`、compat tests、ops artifact readers 与相邻 LiveViews/tests |
| OPS4O-3 | 实现下一切片 | 已完成 | 当前实现 lane | 已新增 `Maxio.Ops.CompatMatrix.Artifacts`、`Maxio.Ops.CompatMatrixConsole`、`/ops/compat` LiveView、route/sidebar 入口与测试；页面只读，无 compat matrix/external smoke/System/Mix/test/HTTP execution entrypoint |
| OPS4O-4 | 聚焦/相邻验证与静态检查 | 已完成 | 当前实现 lane | 修复后聚焦 `mix test test/maxio/ops/compat_matrix/artifacts_test.exs test/maxio/ops/compat_matrix_console_test.exs test/maxio_web/live/ops_compat_live_test.exs test/maxio_web/live/shell_test.exs --max-failures 1` -> 15 tests, 0 failures；相邻 compat/ops batch -> 82 tests, 0 failures；scoped format/compile/static grep/diff-check passed；完整 precommit 延后 |
| OPS4O-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Aquinas 首轮 `NOT APPROVED`：1 Medium（malformed `suites` / `external_clients` / `external_smoke` section shape 会被当空证据）；已修复并补回归；follow-up `APPROVED`，无 High/Medium/Low findings；不使用 Claude |
| OPS4O-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步 OPS4O 收口；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4N（已完成）
目标：新增 `/ops/upgrade` 只读 Console 页面，把 running app/runtime release metadata、migration files vs `schema_migrations`、active/superseded topology revisions、rollback candidates、latest ops gate artifact、latest P0 rehearsal bundle、scheduler ledger evidence 汇总为 upgrade/rollback readiness 视图。页面只展示证据，不执行 upgrade/rollback/migration/topology activation/scheduler/gate/artifact generation/shell 命令。复审继续使用独立 Codex，不使用 Claude。
| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4N-0 | 核对 OPS4M 收口与队列头 | 已完成 | 当前实现 lane | OPS4M 已通过修复后聚焦/相邻/静态验证和独立 Codex follow-up 复审；`STATUS.md` 与本 TODO 已同步；队列头推进到 OPS4N |
| OPS4N-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Dirac 选定 `/ops/upgrade Read-only Upgrade/Rollback Readiness Evidence Console`；继续不使用 Claude |
| OPS4N-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已读取 `Gate.Artifacts`、`RehearsalBundle.Artifacts`、`TopologyStore`、`TopologyRevision`、`SchedulerRuns`、migration/schema read path 与相邻 ops LiveViews/tests |
| OPS4N-3 | 实现下一切片 | 已完成 | 当前实现 lane | 已新增 `Maxio.Ops.UpgradeReadinessConsole`、`/ops/upgrade` LiveView、route/sidebar 入口与测试；页面只读，无 upgrade/rollback/migration/topology activation/gate/scheduler/artifact generation/shell execution entrypoint |
| OPS4N-4 | 聚焦/相邻验证与静态检查 | 已完成 | 当前实现 lane | 修复后聚焦 `mix test test/maxio/ops/upgrade_readiness_console_test.exs test/maxio_web/live/ops_upgrade_live_test.exs test/maxio_web/live/shell_test.exs --max-failures 1` -> 11 tests, 0 failures；相邻 artifact/topology/scheduler/ops pages batch -> 95 tests, 0 failures；scoped format/compile/static grep passed；scoped diff-check 仅 known STATUS CRLF warning；完整 precommit 延后 |
| OPS4N-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Kepler 首轮 `NOT APPROVED`：2 Medium（duplicate migration versions 被静默合并、artifact missing/unparseable/future `generated_at` 未 fail-closed）；已修复并补回归；follow-up `APPROVED`，无 High/Medium/Low findings；不使用 Claude |
| OPS4N-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步 OPS4N 收口；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4M（已完成）
目标：新增 `/ops/cluster` 只读 Console 页面，把 cluster nodes、runtime topology、persisted topology revision、runtime-vs-persisted topology drift、local/peer/device pressure cache、lock server、cache invalidation/PubSub 证据汇总给 operator。页面只展示证据，不安装 runtime topology、不激活 persisted topology、不获取/释放 lock、不刷新 pressure、不采样 drive、不运行 scan/heal/rebalance/scheduler、不执行 Mix/System 命令。
| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4M-0 | 核对 OPS4L 收口与队列头 | 已完成 | 当前实现 lane | OPS4L 已通过修复后聚焦/相邻/静态验证和独立 Codex follow-up 复审；`STATUS.md` 与本 TODO 已同步；队列头推进到 OPS4M |
| OPS4M-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Hubble 选定 `/ops/cluster Read-only Cluster Health & Topology Drift Evidence Console`；继续不使用 Claude |
| OPS4M-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已读取 `Topology`、`TopologyStore`、`IOPressure`、`PressureAggregator`、`DriveDeviceIO`、`Lock`、`CacheInvalidator`、`Notify` 与相邻测试 |
| OPS4M-3 | 实现下一切片 | 已完成 | 当前实现 lane | 已新增 `Maxio.Ops.ClusterHealthConsole`、`/ops/cluster` LiveView、route/sidebar 入口与测试；页面只读，无 topology/lock/pressure/drive/scheduler/heal/rebalance/scan execution entrypoint |
| OPS4M-4 | 聚焦/相邻验证与静态检查 | 已完成 | 当前实现 lane | 修复后聚焦 `mix test test/maxio/ops/cluster_health_console_test.exs test/maxio_web/live/ops_cluster_live_test.exs test/maxio_web/live/shell_test.exs --max-failures 1` -> 12 tests, 0 failures；相邻 topology/runtime/store/pressure/drive_device_io/notify/lock + ops pages batch -> 87 tests, 0 failures；scoped format/compile/static grep/diff-check passed；完整 precommit 延后 |
| OPS4M-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Leibniz 首轮 `NOT APPROVED`：1 Medium（missing runtime topology 可误判 drift match）、2 Low（summary status 与 page status 可不一致、persisted hash fallback 未 fail closed）；已修复并补回归；follow-up `APPROVED`，无 High/Medium/Low findings；不使用 Claude |
| OPS4M-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4L（已完成）

目标：新增 `/ops/replacement` 只读 Console 页面，把 production fresh-drive replacement 自动化链路 readiness 暴露出来：fresh-drive heal scheduler、rebalance scheduler、scheduler ledger evidence、next_action、blockers/warnings、最近 scheduler run/state。页面只展示证据，不启动 scheduler、不运行 heal/rebalance、不写 DB、不改 topology/deployment、不删除 physical layout。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4L-0 | 核对 OPS4K 收口与队列头 | 已完成 | 当前实现 lane | OPS4K 已通过聚焦/相邻验证、静态检查和独立 Codex 复审；`STATUS.md` 与本 TODO 已同步；队列头推进到 OPS4L |
| OPS4L-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Euler 选定 `/ops/replacement Read-only Replacement Automation Profile Console`；继续不使用 Claude |
| OPS4L-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已读取 `Replacement.AutomationProfile.status/1`、`SchedulerRuns` read APIs、Mix status/evidence tests 与相邻 LiveViews |
| OPS4L-3 | 实现下一切片 | 已完成 | 当前实现 lane | 已新增 `Maxio.Ops.ReplacementAutomationConsole`、`/ops/replacement` LiveView、route/sidebar 入口与测试；页面只读，无 scheduler/heal/rebalance/topology/physical execution entrypoint |
| OPS4L-4 | 聚焦/相邻验证与必要浏览器取证 | 已完成 | 当前实现 lane | 修复后聚焦 `mix test test/maxio/ops/replacement_automation_console_test.exs test/maxio_web/live/ops_replacement_live_test.exs test/maxio_web/live/shell_test.exs --max-failures 1` -> 10 tests, 0 failures；相邻 replacement/scheduler/scan/rebalance/gate batch -> 86 tests, 0 failures；scoped format/compile/static grep/diff-check passed；完整 precommit 延后 |
| OPS4L-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Franklin 首轮 `NOT APPROVED`：2 个 Medium（raw scheduler evidence secret leakage、detailed scheduler evidence blockers/warnings 未展示）；已修复并补回归；follow-up `APPROVED`，无 High/Medium/Low findings；不使用 Claude |
| OPS4L-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4K

目标：新增 `/ops/scan` 只读 Console 页面，把当前 scanner/scrubber 配置、派生索引权威边界、usage snapshot、DriveHealth/DriveIdentity 运行态快照，以及最新 `/ops/gate` 归档的 scan/reconcile/fresh-drive evidence 汇总到一个运维证据视图。页面只展示证据，不触发 scan/reconcile/heal/probe。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4K-0 | 核对 OPS4J 收口与队列头 | 已完成 | 当前实现 lane | OPS4J 已通过聚焦/相邻验证、静态检查和独立 Codex 复审；`STATUS.md` 与本 TODO 已同步；队列头推进到 OPS4K |
| OPS4K-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Plato 选定 `/ops/scan Read-only Scanner/Reconcile & Drive-Health Evidence Console`；继续不使用 Claude |
| OPS4K-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已读取 `ObjectMeta.authoritative_source/1`、scanner/scrubber config、usage snapshots、DriveHealth/DriveIdentity snapshot、Gate.Artifacts 与相邻测试 |
| OPS4K-3 | 实现下一切片 | 已完成 | 当前实现 lane | 新增 `Maxio.Ops.ScanEvidenceConsole`、`/ops/scan` LiveView、route/sidebar 入口与测试；不新增执行动作 |
| OPS4K-4 | 聚焦/相邻验证与必要浏览器取证 | 已完成 | 当前实现 lane | 修复后聚焦 `mix test test/maxio/ops/scan_evidence_console_test.exs test/maxio_web/live/ops_scan_live_test.exs test/maxio_web/live/shell_test.exs --max-failures 1` -> 9 tests, 0 failures；相邻 scanner/scrubber/drive/gate batch -> 121 tests, 0 failures；scoped format/compile/static grep/diff-check passed（仅 known STATUS CRLF warning）；完整 precommit 延后 |
| OPS4K-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Ramanujan 首轮 `NOT APPROVED`：2 Medium（归档 recency 使用最新无关 artifact、全 empty 顶层 rollup 被标为 ok）；已修复为 latest relevant artifact + all-empty -> `empty`，并补回归；follow-up `APPROVED`，无新 High/Medium/Low findings；不使用 Claude |
| OPS4K-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4J

目标：新增 `/ops/rebalance` 只读 Console 证据页，让 operator 能查看最近 rebalance/decommission jobs、当前选中 job 的 workflow phase、gate_status、next_action、runtime/deployment topology、rebalance closure audit、blockers/warnings 与 destructive next_action 边界；只展示证据，不执行任何 rebalance/decommission/scan/heal/scheduler/gate 动作。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4J-0 | 核对 OPS4I 收口与队列头 | 已完成 | 当前实现 lane | OPS4I 已通过聚焦/相邻验证、静态检查和独立 Codex 复审；`STATUS.md` 与本 TODO 已同步；队列头推进到 OPS4J |
| OPS4J-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Laplace 选定 `/ops/rebalance Read-only Rebalance Workflow Evidence Console`；继续不使用 Claude |
| OPS4J-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已读取 `Maxio.Cluster.Rebalance.Jobs`、`Workflow.summary/2`、相邻 cluster/mix task tests 与 Console shell |
| OPS4J-3 | 实现下一切片 | 已完成 | 当前实现 lane | 新增 `Maxio.Ops.RebalanceWorkflowConsole`、`/ops/rebalance` LiveView、router/sidebar 入口；只对 selected job 调 workflow summary；不新增执行动作 |
| OPS4J-4 | 聚焦/相邻验证与必要浏览器取证 | 已完成 | 当前实现 lane | 聚焦 `mix test test/maxio/ops/rebalance_workflow_console_test.exs test/maxio_web/live/ops_rebalance_live_test.exs --max-failures 1` -> 8 tests, 0 failures；相邻 Console/Ops/rebalance batch -> 81 tests, 0 failures；scoped format passed；compile --warnings-as-errors passed；完整 precommit 延后 |
| OPS4J-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Avicenna 首轮 `NOT APPROVED`：1 Medium（初始 render 重复执行重 workflow summary）；已修复为 `mount/3` 不调用 `RebalanceWorkflowConsole.load/1`，并补 blank job_id 测试；follow-up `APPROVED`，无新 High/Medium/Low findings；不使用 Claude |
| OPS4J-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4I

目标：在现有 `/ops/gate` 只读页面里，把 `m8_p0_ops_live_rehearsal_*_bundle.json` 证据包接上。页面应展示最近 bundle、当前选中 gate artifact 对应的 bundle、replacement/scheduler/ops_gate child result 状态、artifact paths、bounded commands，并明确 live/dry-run 边界；只读展示，不执行任何命令。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4I-0 | 核对 OPS4H 收口与队列头 | 已完成 | 当前实现 lane | OPS4H 已通过聚焦/相邻验证、静态检查和独立 Codex 复审；`STATUS.md` 与本 TODO 已同步；队列头推进到 OPS4I |
| OPS4I-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Kuhn 选定 `/ops/gate P0 Live Rehearsal Bundle Linkage`；继续不使用 Claude |
| OPS4I-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已读取 `Maxio.Ops.LiveRehearsalBundle`、artifact shape、CLI/test 与 `OpsGateLive` |
| OPS4I-3 | 实现下一切片 | 已完成 | 当前实现 lane | 新增 read-only bundle artifact reader；在 `/ops/gate` 增加 `#ops-gate-live-bundles` / `#ops-gate-related-bundle` 面板；不新增执行动作 |
| OPS4I-4 | 聚焦/相邻验证与必要浏览器取证 | 已完成 | 当前实现 lane | 聚焦 `mix test test/maxio/ops/rehearsal_bundle/artifacts_test.exs test/maxio_web/live/ops_gate_live_test.exs --max-failures 1` -> 22 tests, 0 failures；相邻 Console/Ops batch -> 69 tests, 0 failures；scoped format、compile、diff-check passed；完整 precommit 延后 |
| OPS4I-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Kierkegaard review `APPROVED`，无 High/Medium/Low findings；残余风险为复审未重跑命令、scoped 文件仍未跟踪、复审时 `STATUS.md` 尚未同步，以及 basename fallback 关联在未来多目录同名 artifact 下需更强关联键；不使用 Claude |
| OPS4I-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4H

目标：在 `/ops/gate` 为当前选中的 archived gate artifact 增加只读 `Artifact Provenance` 面板，展示 schema_version、git_sha、node、mix_env、generated_at、modified_at、file_name、归档 artifact_path、size_bytes、gate_status、invalid reason 等来源信息；当 operator 显式选中旧 artifact 时，显示 selected-vs-latest recency warning。只展示归档证据，不执行任何命令，不暴露 reader internal `path`。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4H-0 | 核对 OPS4G 收口与队列头 | 已完成 | 当前实现 lane | OPS4G 已通过聚焦/相邻验证、静态检查和独立 Codex 复审；队列头推进到 OPS4H |
| OPS4H-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Gibbs 选定 `/ops/gate Artifact Provenance & Recency Boundary`；继续不使用 Claude |
| OPS4H-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已确认 artifact reader 有 base metadata 与归档 JSON 字段，LiveView selection 可比较 selected/latest |
| OPS4H-3 | 实现下一切片 | 已完成 | 当前实现 lane | normalized artifact 已增加 bounded `artifact_provenance`；`/ops/gate` 已增加只读 provenance 面板和 selected-vs-latest recency warning |
| OPS4H-4 | 聚焦/相邻验证与必要浏览器取证 | 已完成 | 当前实现 lane | 聚焦 `mix test test/maxio/ops/gate/artifacts_test.exs test/maxio_web/live/ops_gate_live_test.exs --max-failures 1` -> 29 tests, 0 failures；相邻 Console/Ops batch -> 61 tests, 0 failures；scoped format、compile、diff-check passed；完整 precommit 延后 |
| OPS4H-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Lorentz review `APPROVED`，无 High/Medium/Low findings；残余风险为复审未重跑命令、scoped 文件仍未跟踪、复审时 `STATUS.md` 尚未同步；不使用 Claude |
| OPS4H-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4G

目标：在 `/ops/gate` 为当前选中的 archived gate artifact 增加一个只读 `Operator Runbook` 面板，把已有证据整理成 operator 下一步取证视图：gate rerun command、artifact path、P0 profile/required rehearsal kinds、missing evidence、problem-check commands、以及是否出现 `allow_mutating` / `mutating` check 的显式边界提示。只展示归档证据，不执行任何命令。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4G-0 | 核对 OPS4F 收口与队列头 | 已完成 | 当前实现 lane | OPS4F 已通过聚焦/相邻验证、静态检查和独立 Codex 复审；队列头推进到 OPS4G |
| OPS4G-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Socrates 选定 `/ops/gate Operator Runbook Evidence`；继续不使用 Claude |
| OPS4G-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已确认 `Gate` artifact 有 `config`、顶层 `command/artifact_path`、`ops_evidence_matrix`、check `command/mode/status` 等可派生 runbook 的归档字段 |
| OPS4G-3 | 实现下一切片 | 已完成 | 当前实现 lane | 为 normalized artifact 增加 bounded `operator_runbook`，并在 `/ops/gate` 增加只读 `#ops-gate-runbook` 面板；不新增执行动作 |
| OPS4G-4 | 聚焦/相邻验证与必要浏览器取证 | 已完成 | 当前实现 lane | 聚焦 -> 28 tests, 0 failures；相邻 Console/Ops 批次 -> 60 tests, 0 failures；scoped format、compile、diff-check passed；完整 precommit 延后 |
| OPS4G-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Zeno review `APPROVED`，无 High/Medium/Low findings；不使用 Claude |
| OPS4G-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4F

目标：在不新增 scan/heal/rebalance/decommission 执行动作的前提下，把 ops gate artifact 中已归档的 `checks[*].parsed_output` 转成 bounded、稳定、只读的 operator drilldown，并在 `/ops/gate` 用 `#ops-gate-check-evidence` 面板展示 scheduler、rebalance workflow、scan、fresh-drive heal 等证据摘要。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4F-0 | 核对 OPS4E 收口与队列头 | 已完成 | 当前实现 lane | OPS4E 已通过聚焦/相邻验证、静态检查和独立 Codex follow-up 复审；队列头推进到 OPS4F |
| OPS4F-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Banach 选定 `/ops/gate Archived Check Evidence Drilldown`；继续不使用 Claude |
| OPS4F-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已读取 `OpsGateLive`、`Gate.Artifacts`、`Gate` parsed_output 边界、scheduler/scan/fresh-drive/rebalance 输出测试与相邻 LiveView 测试 |
| OPS4F-3 | 实现下一切片 | 已完成 | 当前实现 lane | `Gate.Artifacts` 已为 normalized checks 增加 bounded `evidence_summary`；`OpsGateLive` 已增加只读 `#ops-gate-check-evidence` 面板；不新增 scan/heal/rebalance/decommission 执行动作 |
| OPS4F-4 | 聚焦/相邻验证与浏览器取证 | 已完成 | 当前实现 lane | 聚焦 -> 25 tests, 0 failures；相邻 Console/Ops/Ops-Cluster -> 110 tests, 0 failures；scoped format、compile、diff-check passed；Browser 插件控制入口不可用，LiveViewTest 选择器覆盖新面板 |
| OPS4F-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Pasteur review `APPROVED`，无 High/Medium/Low findings；不使用 Claude |
| OPS4F-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4E

目标：收紧 `Maxio.Ops.EvidenceMatrix` 对 rehearsal artifact 的证据分类边界。显式 `evidence_kind` 必须和 JSON 结构 shape 一致；伪装、缺字段或 malformed artifact 必须 fail-closed 为结构化 error check，不得错误覆盖 P0/M8 必需证据。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4E-0 | 核对 OPS4D 收口与队列头 | 已完成 | 当前实现 lane | OPS4D 已通过聚焦/相邻验证、静态检查和独立 Codex follow-up 复审；队列头推进到 OPS4E |
| OPS4E-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Boole 选定 `EvidenceMatrix` adversarial artifact schema hardening；继续不使用 Claude |
| OPS4E-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已读取 `Maxio.Ops.EvidenceMatrix`、`Maxio.Ops.Gate`、`gate_test`、`live_rehearsal_bundle_test`、`artifacts_test` 与 LiveView 关联点 |
| OPS4E-3 | 实现下一切片 | 已完成 | 当前实现 lane | `EvidenceMatrix` 现在先按结构 shape 识别真实 artifact kind，再校验显式 `evidence_kind`；非字符串 kind、未知 kind、kind/shape 不匹配、缺结构、混合多 shape artifact 均 fail-closed 为稳定 error check；error check 的 `evidence_kind` 保持 nil，不覆盖 required rehearsal kind；不新增 scan/heal/rebalance/decommission 执行动作 |
| OPS4E-4 | 聚焦/相邻验证与浏览器取证 | 已完成 | 当前实现 lane | 最终聚焦 `mix test test/maxio/ops/evidence_matrix_test.exs test/maxio/ops/gate_test.exs --max-failures 1` -> 24 tests, 0 failures；最终相邻 Console/Ops 批次 -> 55 tests, 0 failures；`mix format --check-formatted` passed；`mix compile --warnings-as-errors` passed；scoped `git diff --check` 仅有已知 STATUS CRLF warning |
| OPS4E-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | 首轮 Codex review `NOT APPROVED`：High 非字符串 `evidence_kind` 可绕过、Medium 多 shape 混合 artifact 可被显式 kind 放行；均已修复并补回归；Noether follow-up review `APPROVED`，无 High/Medium/Low findings；复审指出的“无显式 kind 多 shape 覆盖缺口”已补直接回归；不使用 Claude |
| OPS4E-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4D

目标：由独立 Codex planning lane 选择 Console/Ops 下一块最高价值 hardening 切片，优先评估 OPS4A/OPS4C 复审残余项、artifact listing `max_candidates`、adversarial artifact schema、cluster/rebalance/scanner/drive evidence 展示等能继续推进 M8 运维闭环的范围。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4D-0 | 核对 OPS4C 收口与队列头 | 已完成 | 当前实现 lane | OPS4C 已通过聚焦/相邻验证、浏览器取证和独立 Codex follow-up 复审；队列头推进到 OPS4D |
| OPS4D-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Codex planning 选定 Ops Gate artifact candidate-window hardening：目录、symlink、stat 失败等伪候选不应消耗 `max_candidates` 并隐藏有效 artifact；继续不使用 Claude |
| OPS4D-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已读取 `Maxio.Ops.Gate.Artifacts`、`artifacts_test`、`OpsGateLive` 调用点与 TODO/STATUS 残余风险 |
| OPS4D-3 | 实现下一切片 | 已完成 | 当前实现 lane | `Artifacts.list_recent/1` 现在先按 `lstat`/under-dir/regular-file 过滤候选，再应用 `max_candidates`；目录、symlink、stat 失败等伪候选不再隐藏有效 artifact；保持 Console 显式动作边界，本切片只调整 read-only artifact discovery，不新增 destructive scan/heal/rebalance 动作 |
| OPS4D-4 | 聚焦/相邻验证与浏览器取证 | 已完成 | 当前实现 lane | 最终聚焦 `artifacts_test` -> 11 tests, 0 failures；最终相邻 Console/Ops 批次 -> 43 tests, 0 failures；`mix format --check-formatted` passed；`mix compile --warnings-as-errors` passed；scoped `git diff --check` 仅有已知 STATUS CRLF warning；本切片为 backend artifact discovery 行为，LiveView 调用由相邻测试覆盖 |
| OPS4D-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Codex read-only review `APPROVED`；follow-up review after cleanup/optimization `APPROVED`；无 High/Medium/Low findings；残余风险：大量伪候选排在首个 regular 前仍需 lstat 扫描，这是“伪候选不消耗窗口”语义的预期权衡；不使用 Claude |
| OPS4D-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4C

目标：关闭 OPS4A 复审残余中的“无效 artifact query 静默回落 latest”问题：`/ops/gate?artifact=<bad>` 仍安全回退 latest artifact，但必须显示 operator warning，并明确 requested/reason/showing。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4C-0 | 核对 OPS4B 收口与队列头 | 已完成 | 当前实现 lane | OPS4B 已通过聚焦/相邻验证、浏览器取证和独立 Codex 复审；队列头推进到 OPS4C |
| OPS4C-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Codex planning 选定 `/ops/gate` artifact selection hardening：未知/不安全 artifact query 回退 latest 时显示 operator warning；不使用 Claude |
| OPS4C-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已核对 `OpsGateLive` artifact selection、`ops_gate_live_test` 与 `Gate.Artifacts` 安全边界；本切片不改 artifact backend |
| OPS4C-3 | 实现下一切片 | 已完成 | 当前实现 lane | `/ops/gate` 现在对未知/不安全/blank/overlong/path separator/nested `?artifact=` 回退 latest 时显示 `#ops-gate-selection-warning`；非 binary requested display 使用受限 `inspect/2` 防崩溃；保持 Console 只读/显式动作边界，不引入隐式 scan/heal/rebalance 执行 |
| OPS4C-4 | 聚焦/相邻验证与浏览器取证 | 已完成 | 当前实现 lane | 最终聚焦 `ops_gate_live_test` -> 12 tests, 0 failures；最终相邻 Console/Ops 批次 -> 46 tests, 0 failures；`mix format --check-formatted` passed；`mix compile --warnings-as-errors` passed；scoped `git diff --check` 仅有已知 STATUS CRLF warning；Playwright 登录 dev Console 后验证未知 `artifact=does-not-exist.json` 显示 `not_found` warning，不安全 `artifact=../outside.json` 显示 `invalid_parameter` warning，均回退 `m8_ops_gate_codex_browser_new.json` |
| OPS4C-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | 首轮 Codex read-only review `NOT APPROVED`：1 Medium（非 binary/nested `artifact` 参数会无 warning 回退或空目录崩溃）与 1 Low（invalid query classes 覆盖不足）；已统一 `selected_artifact/2` 归一化路径、非 binary requested display 改为受限 `inspect/2`，补 blank/overlong/backslash/nested/空目录回归；follow-up Codex review `APPROVED`，无 High/Medium/Low findings；不使用 Claude |
| OPS4C-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4B

目标：由独立 Codex planning lane 选择 Console/Ops 下一块最高价值切片，把 replacement/rebalance/decommission/scanner/cluster health/drive evidence 中最能推进 M8 运维闭环的一组证据继续做成可测试、可浏览器取证的 LiveView 能力。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS4B-0 | 核对 OPS4A 收口与队列头 | 已完成 | 当前实现 lane | OPS4A 已通过聚焦/相邻验证、浏览器取证和独立 Codex 复审；队列头推进到 OPS4B |
| OPS4B-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Codex planning 选定 `read-only Ops Gate evidence source traceability`：在 `/ops/gate` 展示每个 check 的 evidence kind/scenario/artifact_path 来源链；不使用 Claude |
| OPS4B-2 | 读取目标实现与测试 | 已完成 | 当前实现 lane | 已读取 `OpsGateLive`、`ops_gate_live_test`、`Gate.Artifacts` 与 gate/live rehearsal 相邻测试 |
| OPS4B-3 | 实现下一切片 | 已完成 | 当前实现 lane | 已增加只读 `#ops-gate-evidence-sources` 面板，按 check 展示 evidence kind/scenario/artifact_path，缺 artifact_path 时显示 `no_source`；不引入隐式 scan/heal/rebalance 执行 |
| OPS4B-4 | 聚焦/相邻验证与浏览器取证 | 已完成 | 当前实现 lane | 最终聚焦 `ops_gate_live_test` -> 8 tests, 0 failures；最终相邻 Console/Ops 批次 -> 42 tests, 0 failures；`mix format --check-formatted` passed；`mix compile --warnings-as-errors` passed；scoped `git diff --check` 仅 STATUS CRLF warning；Playwright 登录 dev Console 并验证 `#ops-gate-evidence-sources-table`、source path 与 `no_source` selectors |
| OPS4B-5 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | 最终 Codex read-only 复审 `APPROVED`，无 High/Medium/Low findings；前两轮 Low（row id fallback 与 blank metadata）均已修复并补回归；不使用 Claude；实现者不自审 |
| OPS4B-6 | 批次收口 / STATUS 同步 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步；完整 `mix precommit` 继续延后到 Console/Ops coherent batch 或里程碑收口 |

## 最近完成批次：P1-CONSOLE-OPS-OPS4A

目标：把已有 `ops_evidence_matrix` 从只存在于 JSON artifact 的机器字段，提升为 `/ops/gate` 页面上的可读 evidence matrix，展示 profile、required/covered/missing 覆盖率、每类 rehearsal evidence 的 status、blockers、warnings 和来源，让管理员能直接从 Console 判断 P0/M8 运维证据是否齐备。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| OPS-0 | 核对队列头与前置里程碑 | 已完成 | 当前实现 lane | `P1-S3-CROSS` 已完成 01A-01D 且完整 `mix precommit` -> 3265 tests, 0 failures, 5 excluded；队列头切到 `P1-CONSOLE-OPS` |
| OPS-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Codex planning 选定 `P1-CONSOLE-OPS-OPS4A`：优先把 `ops_evidence_matrix` 展示为可测试的 Console evidence matrix；不使用 Claude |
| OPS-2 | 读取 Console/Ops 现有实现与测试 | 已完成 | 当前实现 lane | 已读取 `OpsGateLive`、`Gate.Artifacts`、`Gate`、`EvidenceMatrix`、`LiveRehearsalBundle`、router/layout/nav 与相关 LiveView/ops 测试 |
| OPS-3 | 查 Phoenix/LiveView 与项目 UI 约束 | 已完成 | 当前实现 lane | 确认继续使用 `<Layouts.app flash={@flash} current_scope={@current_principal}>`、稳定 DOM id、无 inline script、只读 artifact 展示 |
| OPS-4 | 实现 Ops Gate evidence matrix 面板 | 已完成 | 当前实现 lane | `Gate.Artifacts` 现在保留 evidence kind/scenario/artifact_path；`OpsGateLive` 新增 `#ops-gate-evidence-matrix`、coverage count、per-kind rows、blockers/warnings/source 展示；不改变 gate 判定逻辑，不执行 Mix/scan/heal/rebalance |
| OPS-5 | 聚焦/相邻验证与浏览器取证 | 已完成 | 当前实现 lane | 聚焦 `ops_gate_live_test` + `gate/artifacts_test` -> 15 tests, 0 failures；相邻 Console/Ops 批次 -> 40 tests, 0 failures；`mix format --check-formatted` passed；`mix compile --warnings-as-errors` passed；scoped `git diff --check` 仅 STATUS CRLF warning；Playwright 登录 dev Console 并验证 `/ops/gate` evidence matrix selectors |
| OPS-6 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Codex read-only 复审 `APPROVED`，无 High/Medium/Low findings；残余风险记录为 artifact `max_candidates` 先截断、无效 artifact query 静默回落 latest、adversarial schema 组合覆盖可继续加强；不使用 Claude；实现者不自审 |
| OPS-7 | 批次收口 | 已完成 | 当前实现 lane | `STATUS.md` 与本 TODO 已同步；完整 `mix precommit` 继续按 Console/Ops coherent batch 或里程碑收口运行 |

## 最近完成批次：P1-S3-CROSS-01D

目标：补齐 MPU/Range/checksum/SSE 长路径矩阵，重点覆盖 multipart create/upload/copy/list/complete/abort 与 Range、conditional、checksum、SSE、Requester Pays、expected owner、versioning/delete marker 的组合边界。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| MPU-0 | 核对 `TODO.md` / `STATUS.md` 与当前队列头 | 已完成 | 当前实现 lane | `P1-S3-CROSS-01C` 已 scoped 收口；队列头推进到 `P1-S3-CROSS-01D` |
| MPU-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Codex planning 建议优先收 UploadPartCopy 长链路、checksum 失败原子性、SSE+MPU 混合、完成后 Range 回读；不使用 Claude |
| MPU-2 | 查官方 S3 文档确认语义 | 已完成 | 当前实现 lane | 已核验 CreateMultipartUpload、UploadPart、UploadPartCopy、ListParts、CompleteMultipartUpload、checksum/SSE/Requester Pays/expected owner/Range 关键语义 |
| MPU-3 | 读取 MPU handler 与相邻测试覆盖 | 已完成 | 当前实现 lane | 已读取 `multipart.ex`、`checksum.ex`、`sse.ex`、checksum/SSE/request-payment/expected-owner/range/streaming 现有测试 |
| MPU-4 | 新增 MPU 长路径交叉矩阵回归 | 已完成 | 当前实现 lane | 新增 `test/maxio/s3/multipart_cross_matrix_01d_test.exs`，覆盖非 owner Requester Pays + expected owner + SHA256 composite + SSE-KMS + UploadPart + ranged UploadPartCopy + ListParts + Complete + GET Range，以及 BadDigest 不覆盖旧 part 且可重试 complete |
| MPU-5 | 修正 MPU 路径差异 | 已完成 | 当前实现 lane | 本轮新增矩阵未暴露 handler 差异；无需改业务实现，保持现有 MPU/checksum/SSE 契约 |
| MPU-6 | 聚焦与相邻验证 | 已完成 | 当前实现 lane | 聚焦 `mix test test/maxio/s3/multipart_cross_matrix_01d_test.exs --max-failures 1` -> 2 tests, 0 failures；相邻 MPU/range/checksum/SSE/request-payment/expected-owner/streaming 批次 -> 195 tests, 0 failures；`mix format --check-formatted` passed；`mix compile --warnings-as-errors` passed；scoped `git diff --check` passed |
| MPU-7 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Codex read-only 复审 `APPROVED`，无 High/Medium/Low findings；残余风险仅提示负向 payer/expected-owner 仍依赖相邻 e2e 套件守门；不使用 Claude；实现者不自审 |
| MPU-8 | scoped 收口 | 已完成 | 当前实现 lane | `STATUS.md` 已同步；P1-S3-CROSS 里程碑级完整 `mix precommit` -> 3265 tests, 0 failures, 5 excluded |

## 上一完成批次：P1-S3-CROSS-01C

目标：补齐 CopyObject/UploadPartCopy 交叉矩阵，重点覆盖 source/destination Requester Pays、source/destination expected owner、source versionId、metadata directive、checksum/SSE 继承、Object Lock 与权限拒绝边界。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| COPY-0 | 核对 `TODO.md` / `STATUS.md` 与当前队列头 | 已完成 | 当前实现 lane | `P1-S3-CROSS-01B` 已 scoped 收口；队列头推进到 `P1-S3-CROSS-01C` |
| COPY-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Codex planning 建议先收 source/destination ownership、Requester Pays、authz parity，再扩到 checksum/SSE；不使用 Claude |
| COPY-2 | 查官方 S3 文档确认语义 | 已完成 | 当前实现 lane | 已核验 CopyObject、UploadPartCopy、Requester Pays、source/destination expected owner、source version/delete marker 关键语义 |
| COPY-3 | 读取 copy handler/MPU copy 与相邻测试覆盖 | 已完成 | 当前实现 lane | 已读取 `object.ex` CopyObject、`multipart.ex` UploadPartCopy、expected owner/request payer helper，以及 request-payment/expected-owner/MPU/copy/version/SSE 相邻测试 |
| COPY-4 | 新增 CopyObject/UploadPartCopy 交叉矩阵回归 | 已完成 | 当前实现 lane | 新增 `test/maxio/s3/copy_object_cross_matrix_test.exs`，覆盖 source/destination Requester Pays + expected owner gate、source versionId、metadata REPLACE、UploadPartCopy part side-effect、source delete marker CopyObject/UploadPartCopy parity |
| COPY-5 | 修正 copy 路径差异 | 已完成 | 当前实现 lane | 本轮新增矩阵未暴露 handler 差异；无需改业务实现，保持现有 handler 契约 |
| COPY-6 | 聚焦与相邻验证 | 已完成 | 当前实现 lane | 聚焦 `mix test test/maxio/s3/copy_object_cross_matrix_test.exs --max-failures 1` -> 3 tests, 0 failures；相邻 copy/SSE/request-payment/expected-owner/MPU 批次 -> 92 tests, 0 failures；`mix format --check-formatted` passed；`mix compile --warnings-as-errors` passed；scoped `git diff --check` passed |
| COPY-7 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Codex read-only 复审 `APPROVED`，无 High/Medium/Low findings；不使用 Claude；实现者不自审 |
| COPY-8 | scoped 收口 | 已完成 | 当前实现 lane | `STATUS.md` 已同步；完整 `mix precommit` 按用户要求延后到 P1-S3-CROSS 里程碑统一运行 |

## 更早完成批次：P1-S3-CROSS-01B

目标：补齐 DELETE/DeleteObjects 数据面交叉矩阵，重点覆盖 Requester Pays、versioning/delete marker、Object Lock、expected bucket owner、权限拒绝与批量删除部分成功/失败语义，继续复用 01A 建立的交叉矩阵方法。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| DELETE-0 | 核对 `TODO.md` / `STATUS.md` 与当前队列头 | 已完成 | 当前实现 lane | `P1-S3-CROSS-01A` 已收口；队列头推进到 `P1-S3-CROSS-01B` |
| DELETE-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | Codex read-only lane 建议先收 `DeleteObjects` 请求级前置条件 + per-key 成功/失败混合语义；未使用 Claude |
| DELETE-2 | 查官方 S3 文档确认语义 | 已完成 | 当前实现 lane | 已核验 DeleteObject/DeleteObjects、Requester Pays、versioning/delete marker、Object Lock、expected owner、MFA Delete 边界；发现 delete marker version 删除应返回 `DeleteMarkerVersionId` |
| DELETE-3 | 读取删除 handler 与相邻测试覆盖 | 已完成 | 当前实现 lane | 已读取 object delete、DeleteObjects parser/view、versioning/object lock/request payment/MFA/expected owner 现有测试 |
| DELETE-4 | 新增 DELETE/DeleteObjects 交叉矩阵回归 | 已完成 | 当前实现 lane | 新增 `test/maxio/s3/delete_objects_cross_matrix_test.exs`，覆盖 Requester Pays + expected owner 请求级 gate、quiet per-key AccessDenied、delete marker version 删除、Object Lock 部分失败 |
| DELETE-5 | 修正删除路径差异 | 已完成 | 当前实现 lane | 批量删除 explicit delete marker version 时现在回填 `DeleteMarkerVersionId`；保持既有 handler/view 契约 |
| DELETE-6 | 聚焦与相邻验证 | 已完成 | 当前实现 lane | 聚焦 `mix test test/maxio/s3/delete_objects_cross_matrix_test.exs --max-failures 1` -> 3 tests, 0 failures；相邻删除/versioning/request-payment/object-lock/MFA/expected-owner/SDK 批次 -> 70 tests, 0 failures；`mix format --check-formatted` passed；`mix compile --warnings-as-errors` passed；scoped `git diff --check` passed |
| DELETE-7 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | Codex read-only 复审 `APPROVED`，无 High/Medium/Low findings；不使用 Claude；实现者不自审 |
| DELETE-8 | scoped 收口 | 已完成 | 当前实现 lane | `STATUS.md` 已同步；完整 `mix precommit` 按用户要求延后到 P1-S3-CROSS 里程碑统一运行 |

## 更早完成批次：P1-S3-CROSS-01A

目标：补齐 GET/HEAD 对象读取路径里的 Requester Pays、Range、条件头、versionId、delete marker、ETag/checksum/header 返回组合语义，形成可扩展到 DELETE/COPY/MPU/SSE/Object Ownership 的交叉矩阵基线。

| ID | 任务 | 状态 | 责任 lane | 验收证据 / 下一步 |
| --- | --- | --- | --- | --- |
| CROSS-0 | 核对 `TODO.md` / `STATUS.md` 与当前队列头 | 已完成 | 当前实现 lane | 队列头确认为 `P1-S3-CROSS`，上一批 strict XML 已完整收口 |
| CROSS-1 | 独立 Codex planning | 已完成 | 独立 Codex read-only lane | 规划建议优先收 GET/HEAD 数据面交叉矩阵；未使用 Claude |
| CROSS-2 | 整理实时 TODO 看板 | 已完成 | 当前实现 lane | 本文件重写为总控、当前批次、里程碑、队列、风险、更新协议 |
| CROSS-3 | 查官方 S3 文档确认语义 | 已完成 | 当前实现 lane | 已核验 GetObject/HeadObject Range、conditional headers、Requester Pays、delete marker/versioning、`x-amz-request-charged` |
| CROSS-4 | 读取对象 handler 与相邻测试覆盖 | 已完成 | 当前实现 lane | 已读取 `lib/maxio/s3/handlers/object.ex`、`request_payment_e2e_test.exs`、`versioning_object_test.exs`、Range/conditional 矩阵 |
| CROSS-5 | 新增 GET/HEAD 交叉矩阵回归 | 已完成 | 当前实现 lane | `request_payment_e2e_test.exs` 新增非 owner + Requester Pays + Range + If-* + versionId + delete marker 组合回归 |
| CROSS-6 | 修正对象读取路径差异 | 已完成 | 当前实现 lane | HEAD 现在解析 Range 并按可满足范围调整 `Content-Length` / 不可满足返回 416；GET/HEAD conditional 304 回显 `etag`、`last-modified`、`x-amz-version-id`、`x-amz-request-charged` |
| CROSS-7 | 聚焦验证 | 已完成 | 当前实现 lane | `mix test test/maxio/s3/request_payment_e2e_test.exs --max-failures 1` -> 18 tests, 0 failures |
| CROSS-8 | 相邻验证与静态检查 | 已完成 | 当前实现 lane | 相邻 Range/conditional/versioning 批次 -> 19 tests, 0 failures；`mix format --check-formatted` passed；`mix compile --warnings-as-errors` passed；scoped `git diff --check` passed |
| CROSS-9 | 独立 Codex 复审 | 已完成 | 独立 Codex read-only lane | 首轮 Codex read-only 复审 `NOT APPROVED`，2 个 Low：304 未断言 `last-modified`、latest delete marker 缺 HEAD 覆盖；已修复并复跑验证；二轮 Codex read-only 复审 `APPROVED`，无 High/Medium/Low findings；未使用 Claude |
| CROSS-10 | 复审修复与批次收口 | 已完成 | 当前实现 lane | 复审 findings 已修复；聚焦验证 18 tests, 0 failures；相邻验证 19 tests, 0 failures；`mix format --check-formatted` / `mix compile --warnings-as-errors` / scoped `git diff --check` passed；`mix precommit` -> 3257 tests, 0 failures, 5 excluded；`STATUS.md` 已同步 |

## 全局里程碑 TODO

| 里程碑 | 范围 | 当前状态 | 剩余任务 |
| --- | --- | --- | --- |
| M0 Foundation | storage behaviour、FS backend、Postgres 元数据、config、结构化日志 | 已完成，回归维护 | 保持契约稳定；不做无关重构 |
| M1 S3 Core | endpoint、SigV4、dispatcher、bucket/object CRUD、ListObjectsV2、XML/error、CLI | 已完成，兼容硬化中 | 继续用 AWS/MinIO 行为矩阵补边界 |
| M2 Streaming/Multipart | 大对象流式、aws-chunked、multipart、CopyObject、DeleteObjects、Range、条件头 | 主干已完成，矩阵硬化中 | 加强 Range/条件头/MPU/大对象/外部客户端组合验证 |
| M3 IAM/Policy | access key、policy evaluator、ACL、bucket policy、STS/IAM 扩展 | 主干已完成，治理补齐中 | IAM Query API 长尾、跨账号/多账号、secret rotation、外部 KMS/HSM |
| M4 Advanced S3 | versioning、tagging、lifecycle、CORS、SSE、Select、Restore、Replication、Notification、Logging | 主干已完成，保真补齐中 | 严格 XML 已推进；下一步补交叉语义和 AWS/MinIO 差异矩阵 |
| M5 Console | Phoenix LiveView 管理台、Identity/STS/IdP、对象管理 | 主干已完成，体验补齐中 | 运维操作台、cluster/rebalance/scanner 取证、浏览器自动化验证 |
| M6 Erasure | 单机纠删码、bitrot、自愈、scrub | 已完成，长跑验证待加强 | 更长压力、故障注入、数据一致性 evidence |
| M7 Distributed | libcluster、transport、ShardServer、distributed backend、跨节点 heal | 已完成，长跑验证待加强 | 真实多节点、网络异常、滚动升级与恢复回归 |
| M8 Ops Maturity | quorum lock、cache invalidation、scanner/auto-heal、replacement/rebalance/decommission | 进行中 | 升级/回滚/故障注入闭环、operator runbook、生产化 evidence |
| Compatibility | aws-cli、mc、boto3、SDK、MinIO 差异矩阵 | 官方三客户端 smoke 已完成，增量维护 | 更多语言 SDK、长跑、真实多节点与新增 MinIO 差异继续补齐 |
| Production Readiness | 压力、故障注入、升级、发布、runbook、监控 | 进行中 | 长跑压测、灾难恢复、发布/回滚流程证据 |

## 后续执行队列

| 优先级 | ID | 状态 | 完成判据 |
| --- | --- | --- | --- |
| 0 | `P1-S3-CROSS-01A` GET/HEAD 数据面交叉矩阵 | 已完成 | Requester Pays + Range + 条件头 + versionId/delete marker 的 GET/HEAD 组合通过；precommit 3257 tests, 0 failures |
| 1 | `P1-S3-CROSS-01B` DELETE/DeleteObjects 数据面交叉矩阵 | 已完成 | Requester Pays + versioning/delete marker + Object Lock/ownership/expected owner 组合 scoped 验证通过；precommit 延后到 P1-S3-CROSS 里程碑 |
| 2 | `P1-S3-CROSS-01C` CopyObject/UploadPartCopy 交叉矩阵 | 已完成 | source/destination requester payer、expected owner、source version/delete marker、metadata directive、UploadPartCopy part side-effect 组合通过；precommit 延后到 P1-S3-CROSS 里程碑 |
| 3 | `P1-S3-CROSS-01D` MPU/Range/checksum/SSE 长路径矩阵 | 已完成 | multipart read/copy/complete/list parts 与 checksum/SSE/range 组合已通过 scoped 验证和 Codex 复审；P1-S3-CROSS 完整 precommit -> 3265 tests, 0 failures |
| 4 | `P1-CONSOLE-OPS-OPS4A` Ops Gate evidence matrix Console 展示 | 已完成 | `ops_evidence_matrix` 在 `/ops/gate` 可读展示；15 个聚焦测试、40 个相邻测试、format、compile、浏览器取证和独立 Codex review 均通过 |
| 5 | `P1-CONSOLE-OPS-OPS4B` Console evidence source traceability | 已完成 | `/ops/gate` 增加 read-only evidence source traceability，展示每个 gate check 的 evidence kind/scenario/artifact_path；8 个聚焦测试、42 个相邻测试、format、compile、浏览器取证和独立 Codex review 均通过 |
| 6 | `P1-CONSOLE-OPS-OPS4C` Console artifact selection warning | 已完成 | `/ops/gate` 对未知/不安全/blank/overlong/path separator/nested `?artifact=` 显示 operator warning；12 个聚焦测试、46 个相邻测试、format、compile、浏览器取证和独立 Codex follow-up review 均通过 |
| 7 | `P1-CONSOLE-OPS-OPS4D` Console artifact candidate-window hardening | 已完成 | `Artifacts.list_recent/1` 的 `max_candidates` 应用于 regular artifact candidate 窗口；目录/symlink/stat 失败不隐藏有效 artifact；11 个聚焦测试、43 个相邻测试、format、compile 和独立 Codex follow-up review 均通过 |
| 8 | `P1-CONSOLE-OPS-OPS4E` EvidenceMatrix adversarial schema hardening | 已完成 | 显式 `evidence_kind` 与结构 shape 不一致、非字符串 kind、未知 kind、缺结构、多 shape 混合 artifact 均 fail-closed；24 个聚焦测试、55 个相邻测试、format、compile 和独立 Codex follow-up review 均通过 |
| 9 | `P1-CONSOLE-OPS-OPS4F` Archived Check Evidence Drilldown | 已完成 | `/ops/gate` 展示 archived check parsed output 的 bounded drilldown；25 个聚焦测试、110 个相邻测试、format、compile、diff-check 和独立 Codex review 均通过 |
| 10 | `P1-CONSOLE-OPS-OPS4G` Operator Runbook Evidence | 已完成 | `/ops/gate` 展示 archived operator runbook evidence；28 个聚焦测试、60 个相邻测试、format、compile、diff-check 和独立 Codex review 均通过 |
| 11 | `P1-CONSOLE-OPS-OPS4H` Artifact Provenance & Recency Boundary | 已完成 | `/ops/gate` 展示 bounded artifact provenance 与 selected-vs-latest recency warning；29 个聚焦测试、61 个相邻测试、format、compile、diff-check 和独立 Codex review 均通过 |
| 12 | `P1-CONSOLE-OPS-OPS4I` P0 Live Rehearsal Bundle Linkage | 已完成 | `/ops/gate` 展示 P0 live rehearsal bundle 列表、selected gate 关联 bundle、child result、bounded command 与 live/enabled boundary；22 个聚焦测试、69 个相邻测试、format、compile、diff-check 和独立 Codex review 均通过 |
| 13 | `P1-CONSOLE-OPS-OPS4J` Rebalance Workflow Evidence Console | 已完成 | `/ops/rebalance` 展示 rebalance/decommission workflow evidence；修复首轮 review Medium 后 follow-up `APPROVED`；聚焦 11 tests、相邻 81 tests、format、compile、static grep、diff-check 通过 |
| 14 | `P1-CONSOLE-OPS-OPS4K` Scanner/Reconcile & Drive-Health Evidence Console | 已完成 | `/ops/scan` 展示 scanner/reconcile/drive-health/drive-identity/archived evidence；修复首轮 review 2 Medium 后 follow-up `APPROVED`；聚焦 9 tests、相邻 121 tests、format、compile、static grep、diff-check 通过 |
| 15 | `P1-CONSOLE-OPS-OPS4L` Replacement Automation Profile Console | 已完成 | `/ops/replacement` 展示 replacement automation readiness/scheduler ledger evidence；修复首轮 review 2 Medium 后 follow-up `APPROVED`；聚焦 10 tests、相邻 86 tests、format、compile、static grep、diff-check 通过 |
| 16 | `P1-CONSOLE-OPS-OPS4M` Cluster Health & Topology Drift Evidence Console | 已完成 | `/ops/cluster` 展示 cluster health/topology drift/pressure/lock/cache invalidation evidence；修复首轮 review 1 Medium + 2 Low 后 follow-up `APPROVED`；聚焦 12 tests、相邻 87 tests、format、compile、static grep、diff-check 通过 |
| 17 | `P1-CONSOLE-OPS-OPS4N` Upgrade/Rollback Readiness Evidence Console | 已完成 | `/ops/upgrade` 展示 release/schema/topology rollback/gate/bundle/scheduler evidence；修复首轮 review 2 Medium 后 follow-up `APPROVED`；聚焦 11 tests、相邻 95 tests、format、compile、static grep、diff-check 通过 |
| 18 | `P1-CONSOLE-OPS-OPS4O` S3 Compatibility & External Client Evidence Console | 已完成 | `/ops/compat` 展示 compat matrix artifact、internal suites、external clients/smoke、streaming stress、blockers/warnings；修复首轮 review 1 Medium 后 follow-up `APPROVED`；聚焦 15 tests、相邻 82 tests、format、compile、static grep、diff-check 通过 |
| 19 | `P1-CONSOLE-OPS-OPS4P` Ops Observability & Metrics Readiness Console | 已完成 | `/ops/observability` 展示 Prometheus surface/auth boundary、request metrics ledger、Dashboard stats、operator commands、blockers/warnings；修复首轮 review 1 Medium + 1 Low 后 follow-up `APPROVED`；聚焦 10 tests、相邻 39 tests、format、compile、static grep、diff-check 通过 |
| 20 | `P1-CONSOLE-OPS-OPS4Q` `/ops/recovery` Recovery/DR Readiness Console | 已完成 | 只读 recovery/DR evidence Console 已收口；首轮 Codex review 1 High 已修复；focused 8 tests、相邻 112 tests、compile/format/static grep/diff-check passed；follow-up Codex review `APPROVED` |
| 21 | `P1-CONSOLE-OPS-CLOSEOUT-01` Console/Ops OPS4A-OPS4Q coherent batch closeout | 已完成 | focused/adjacent 134 tests, compile/format/static checks passed；完整 `mix precommit` -> 3363 tests, 0 failures, 5 excluded；独立 Codex review `APPROVED - no High/Medium/Low findings` |
| 22 | `P0-COMPAT-2C` 真实外部客户端全量证据 | 已完成 | 官方 aws-cli/mc/boto3 已安装验证；`artifacts/s3_compat_matrix_external_final6.json` 为 6/6，cleanup 与 secret hygiene 通过 |
| 23 | `P1-IAM-GOV-A` IAM governance local compatibility and authorization hardening | 已完成 | Query API surface 盘点、授权决策日志、`aws:PrincipalAccount`、owner/root explicit-deny 语义、object-level bypass 统一授权、IAM error audit、KMS boundary 均已收口；完整 precommit 3375 tests, 0 failures |
| 24 | `P2-STRESS-A` Local Stress/Fault Campaign | 已完成 | 本地安全压力/故障注入 campaign 可重复运行并写 artifact；focused/adjacent 验证、真实 campaign、独立 Codex review 和完整 precommit 均通过 |
| 25 | `P2-RELEASE` 发布/升级/文档 | 待规划 | operator runbook、配置说明、迁移/回滚、监控指标、生产部署路径可复现 |
| 26 | `P2-COMPAT-LONGTAIL` 长尾 S3/MinIO 兼容项 | 进行中 | A-F 与 coherent closeout 已完成；后续 LONGTAIL-G 继续覆盖低频 API、边界 XML、旧 SDK 行为和 MinIO 差异 |
| 27 | `P2-COMPAT-LONGTAIL-CLOSEOUT-01` A-F semantic audit / full verification closeout | 已完成 | 独立多轮审查最终 APPROVED；完整 `mix precommit` -> 3429 tests, 0 failures, 5 excluded |
| 28 | `OBJECT-MUTATION-PHASE1` PutObject durable mutation protocol | 进行中（remediation） | B1–B7 与 P1-CLOSEOUT-A 已完成；下一步依次关闭 finalize 前 final fingerprint gate、Distributed claim IO 前 prepared-journal frozen placement durability，以及计划/审计列出的其余 Phase 1 未完成项；全部关闭前不得声明 Phase 1 闭环 |
| 29 | `OBJECT-MUTATION-PHASE2` 全 mutator/read-barrier/GC 迁移 | 进行中（2A 分批，未收口） | 2A caller 可分批迁移但不得冒充全局闭环；`Multipart.complete` 的 put/assemble 留 2A，multipart part/abort、delete/meta-only 留 2B，read barrier/heal/rebalance/GC 留 2C；当前未迁移路径一律视为未 crash-safe |

## 当前风险与阻塞

| ID | 严重度 | 状态 | 关联 | 描述 | 下一步 |
| --- | --- | --- | --- | --- | --- |
| R-WIN-MEM | Medium | 缓解中 | verification | Windows 会话曾出现 BEAM `eheap_alloc`；完整 precommit 和嵌套 Mix 需低 scheduler | 继续使用低 scheduler 配置，避免频繁完整 precommit |
| R-EXTERNAL-SDK | P0 | 已关闭 | P0-COMPAT-2C | 官方 aws-cli 2.35.20、mc RELEASE.2025-08-13、boto3 1.43.45 已完成真实 deep smoke，final6 6/6 且无残留/secret | 后续新增语言 SDK 或版本时作为增量兼容风险重新取证 |
| R-OBJECT-MUTATION-PHASE1 | P0 | 未关闭 | OBJECT-MUTATION-PHASE1 | B1–B7 backend CAS/handler transaction/recovery/CLI 已实现，P1-CLOSEOUT-A 也已关闭 fresh absence；仍缺 final 实际 fingerprint gate、Distributed claim 前 durable frozen placement snapshot 及计划内其余 Phase 1 未完成项 | 分独立 coherent batch TDD + 独立审查收口；禁止把已实现 B1–B7 或首批 closeout 写成 Phase 1 总闭环 |
| R-OBJECT-MUTATION-PHASE2 | P0 | 未关闭 | OBJECT-MUTATION-PHASE2 | 2A 已有 caller 分批迁移但未收口；`Multipart.complete` put/assemble、multipart part/abort、delete/meta-only、read barrier/heal/rebalance/GC 仍有未协议化路径 | 严格按 2A/2B/2C 边界推进并用静态 inventory + fault matrix 验收；当前不得声明全局写路径 crash-safe |
| R-OPS-MULTINODE | P0 | 部分关闭 | M8/P0-OPS | ops gate/rehearsal/scheduler evidence 已推进；升级/回滚/故障注入仍需闭环 | 后续 M8 批次继续推进 |
| R-CROSS-MATRIX | Medium | 本轮关闭 | P1-S3-CROSS | S3 数据面特性已多，但组合语义容易遗漏或互相覆盖 | GET/HEAD、DELETE、COPY、MPU 长路径均已 scoped 收口；完整 precommit 3265 tests 通过，后续转入真实客户端/长尾矩阵 |
| R-COMPAT-AF-PRECOMMIT | Medium | 已关闭 | P2-COMPAT-LONGTAIL-CLOSEOUT-01 | A-F 曾只有 focused/adjacent 证据，未被同一次完整门禁联合覆盖 | 多轮审查/修复完成，最终 `mix precommit` 3429 tests / 0 failures / 5 excluded |
| R-REQUESTER-PAYER-MODEL | Medium | VERIFY-AT-IMPL | P2-COMPAT-LONGTAIL | AWS Requester Pays 通用指南与 SelectObjectContent/DeleteObjectTagging 单操作 API/SDK model 对 payer 字段存在冲突 | 待真实 AWS/SDK 环境可用后逐操作取证；当前不凭猜测改变行为 |
| R-OPS-GATE-ARTIFACTS | Low | 已关闭 | P1-CONSOLE-OPS | OPS4A 复审残余风险中“无效 artifact query 静默回落 latest”已由 OPS4C 关闭；artifact 候选数先截断再过滤已由 OPS4D 关闭；EvidenceMatrix adversarial schema 组合已由 OPS4E 关闭；archived check parsed output drilldown 已由 OPS4F 关闭；operator runbook evidence 已由 OPS4G 关闭；artifact provenance/recency boundary 已由 OPS4H 关闭；P0 live rehearsal bundle linkage 已由 OPS4I 关闭 | 后续如新增 artifact kind、parsed evidence kind、runbook row kind、provenance field 或 bundle child result kind，再按同样 shape/kind/summary/runbook/provenance/bundle 边界补回归 |
| R-CONSOLE-OPS-PRECOMMIT | Medium | 已关闭 | P1-CONSOLE-OPS-CLOSEOUT-01 | OPS4A-OPS4Q 已多轮 focused/adjacent 验证，完整 `mix precommit` 已在本 closeout 批次归还验证债 | focused/adjacent、compile/format/static checks 与完整 `mix precommit` 均已通过；独立 Codex review 已批准 |
| R-TODO-DRIFT | Medium | 缓解中 | Docs/TODO | 长会话和多 lane 推进容易让当前进度散落在终端输出、STATUS 和口头说明里 | 以本 TODO 作为运行中看板；每次 planning、实现、验证、复审、收口状态变化都先更新当前批次表 |

## 实时更新协议

| 事件 | 必须更新 |
| --- | --- |
| 开始新的 coherent batch | 当前总控、当前批次任务表、后续队列 |
| 完成代码实现分片 | 当前批次任务状态、必要时风险表 |
| 完成聚焦/相邻测试或编译 | 当前批次验收证据，记录命令、测试数量、失败数量 |
| 完成独立 Codex planning/review | 当前批次任务表，记录 APPROVED/NOT APPROVED、findings、修复状态 |
| 完成完整 `mix precommit` | 当前总控、当前批次任务表、风险表 |
| 批次收口 | 同步 `STATUS.md`，当前 batch 标记已完成，选择下一 coherent batch |

## 操作命令约定

| 场景 | 命令约定 |
| --- | --- |
| Mix 命令前 | 清理 `PGPORT`，避免错误连接端口 |
| Windows 低内存验证 | 使用 `$env:ELIXIR_ERL_OPTIONS='+S 1:1 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'` |
| 开发中验证 | 优先 `mix test path/to/test.exs --max-failures 1`、`mix compile --warnings-as-errors`、必要的 `mix format --check-formatted` |
| 批次收口验证 | 仅在 coherent batch 收口时运行完整 `mix precommit` |
