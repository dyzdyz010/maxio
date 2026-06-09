# maxio · 项目状态（STATUS）

> 单一事实来源（cross-session / 抗闪退）。最后更新：2026-06-09。
> 设计 spec：`docs/superpowers/specs/2026-06-08-maxio-s3-foundation-design.md`（+ `_design_inputs/`）
> 工程准则：`AGENTS.md`（先读）；Claude/OMC 执行细节：`CLAUDE.md`

## 项目目标

用 Elixir/Phoenix 完整复刻 MinIO 的全功能、Amazon S3 兼容对象存储系统（aws-cli/boto3/mc/SDK 直连）。工程约束参考姊妹项目寰析（huanxi）。

## 里程碑进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **脚手架** | Phoenix 1.8 项目（Maxio/`:maxio`/`Maxio.Repo`）、Ecto+Postgres、Bandit；config 已关 ColocatedJS 符号链接警告 | ✅ 已生成、可编译 |
| **设计** | 两份子系统设计（S3 API 层、SigV4/IAM）+ 合并 spec 索引 + 工程铁律注入 AGENTS/CLAUDE | ✅ 已完成（2026-06-08） |
| **M0 地基** | 存储后端 behaviour + FS（流式）；bucket/object 元数据 schema（中文 COMMENT）+ 上下文；s3 config；结构化日志基座 | ✅ 已实现并验证（master，2026-06-08；125 测试全绿、独立 reviewer APPROVE） |
| **M1 S3 核心读写** | 独立 S3 Endpoint + AddressStyle + SigV4 + Dispatcher + bucket/object handlers + ListObjectsV2 + XML + 错误映射 + CLI；自签 SigV4 e2e | ✅ 已实现并验证（master，2026-06-08；125 测试全绿、SigV4 与 AWS 向量逐字节一致、独立 reviewer APPROVE_WITH_NOTES／0 must-fix） |
| **M2 分段上传 + 流式** | aws-chunked 逐块签名完整验证 + multipart 全套 + DeleteObjects 批删 + 条件头 + CopyObject + M1 硬化 | ✅ 已实现并验证（master，2026-06-08；191 测试全绿、aws-chunked 与 AWS 流式向量逐字节一致、独立 reviewer APPROVE_WITH_NOTES／0 must-fix） |
| **M3 IAM / 策略** | access key + EctoStore + policy 评估 + canned ACL + bucket policy + Authz + 匿名 | ✅ 已实现并验证（master，2026-06-09；275 测试全绿、Evaluator 真值表 + 匿名/public policy/ACL/授权矩阵 e2e、`compile --warnings-as-errors` 零警告） |
| **M4 高级特性** | versioning / tagging / lifecycle / CORS / SSE | ✅ 已实现并验证（master，2026-06-09；349 测试全绿、`compile --warnings-as-errors` 零警告、versioning/tagging/cors/lifecycle/sse e2e + 跨特性矩阵） |
| **M5 Console** | LiveView 管理台 | ✅ 已实现并验证（master，2026-06-09；`compile --warnings-as-errors` 零警告、跨页 e2e LiveViewTest 矩阵全绿、鉴权/dashboard/buckets/object-browser/object-detail/settings/access-keys 单测全绿） |
| **M6 纠删码（单机多盘）** | Reed-Solomon（Rustler NIF）纠删码后端 + bitrot 检测 + 自愈/scrub（多节点分布 defer M7） | ✅ 已实现并验证（master，2026-06-09；全量回归绿、`compile --warnings-as-errors` 零警告、NIF round-trip / Codec bitrot / 后端 conformance（同跑 FS+EC）/ S3 e2e / heal-scrub / bitrot e2e 全绿） |
| **M7 多节点分布式纠删码** | libcluster 节点发现 + Topology/Router/Paths + 跨节点 Transport（:erpc / InProcess）+ ShardServer + 分布式锁 + `Maxio.Storage.Distributed` 后端 + 跨节点 heal + 集群 e2e | ✅ 已实现并验证（master，2026-06-09；全量回归绿、`compile --warnings-as-errors` 零警告、拓扑/路由纯函数 + Transport + 分布式后端 conformance（同跑 FS+EC+Distributed）+ quorum/宕机/bitrot 单测 + 跨节点 heal + InProcess 集群 e2e 四场景 + `:peer` 真节点 :erpc 重建全绿） |

## 当前会话进展（2026-06-08）

接手上一被中断会话（停在设计阶段，已产出两份 `_design_inputs/` 设计文档）。本会话：
1. ✅ 把工程铁律注入 `AGENTS.md`、新建 `CLAUDE.md`、创建合并 spec 索引与本 STATUS.md。
2. ✅ Workflow 编排（严守"实现者绝不自审"）：5 个并行研究 agent 核验 SigV4/XML/chunked/saxy → opus planner 产出 5012 行详细计划（`plans/2026-06-08-m0-m1-foundation.md`）→ 串行 executor 逐单元实现（E1–E7）→ 独立 verifier → 独立 code-reviewer。
3. ✅ **M0+M1 垂直切片完成并验证**（commit `a1846d1`→`7940d94`，9 个实现/验证/审查 agent）。

### M0+M1 实现摘要（subagent-driven：实现者 → 独立 verifier → 独立 code-reviewer）

- **125 测试全绿、`compile --warnings-as-errors` 零警告**。模块：`Maxio.Storage.{Backend,FS}`、`Maxio.{Buckets,Objects}`、`Maxio.S3.{Error,XML,ErrorView,Dispatcher,Endpoint,BodyReader}`、`Maxio.S3.Plugs.{AddressStyle,SigV4,Dispatch}`、`Maxio.S3.Handlers.{Service,Bucket,Object}`、`Maxio.S3.Views.*`、`Maxio.Auth` + `Maxio.Auth.SigV4.{Canonical,Signer,AuthHeaderParser,SignedRequest}` + `Maxio.Auth.CredentialStore{,.MemoryStore}`、`mix maxio.sigv4.debug`。
- **SigV4 ground truth**：Canonical/Signer 与 AWS 官方 worked-example 已知答案向量 A/B/C/D + presigned **逐字节一致**；常数时间比对（`Plug.Crypto.secure_compare`）；S3 单次编码、不归一化路径、保留 `/`。
- **自签 e2e**（`test/maxio/s3/integration_test.exs`，经 `Endpoint.call/2`）：CreateBucket / ListBuckets / PutObject 流式+ETag / GetObject 全量 / Range 206+Content-Range / HeadObject / DeleteObject→404 / ListObjectsV2 prefix+delimiter / GetBucketLocation / DeleteBucket 非空 409 / 篡改签名 403 / 未知桶 404，共 11 场景。
- **铁律落实**：body 全程流式（`BodyReader` 包 `read_body`；Endpoint 无 `Plug.Parsers`；FS 边写边算 MD5；GET 用 `send_chunked`+`:file.pread`）；所有失败渲染结构化 S3 XML + 结构化日志，绝不静默；存储/凭据经 behaviour；buckets/objects 表/列/索引中文 COMMENT。
- **独立审查抓出并已修复的真实 bug**：签名 CanonicalURI 须用原始 `request_path` 而非折叠的 `path_info`（`Maxio.S3.RawPath`，commit `7940d94`，附 `dir/`、`a//b.txt`、`/leading.txt` 回归）；saxy 强制转义 `"`→`&quot;` 破坏 ETag 兼容性 → `XML.encode/1` 在 facade 单点把 `&quot;`/`&apos;` 还原为字面量（先转义 `&` 保证可逆，对齐 Go encoding/xml / minio-go）。

### M1 已知非阻塞项（reviewer notes，纳入 M2 backlog）

1. **aws-chunked 帧头非 hex 时被强制当 0**（`body_reader.ex`）→ 无 `x-amz-decoded-content-length` 时会静默截断存成"完整"对象（轻微违铁律 3）。建议：非 hex 帧头 raise `IncompleteBody`。M2 做完整逐块签名验证时一并治本。
2. `:single` 模式未校验声明的 `x-amz-content-sha256` 与实际 body（无 `BadDigest`/`XAmzContentSHA256Mismatch`）——M2。
3. `ListBucketResult` 元素顺序与 AWS 规范序略有出入（SDK 按元素名解析，功能容忍；装饰性）。
4. `Object.put` 在 `verify_decoded_length!` 抛错前已写字节 → 长度不符时留孤儿字节（响应正确，仅存储泄漏，需清理）。
5. HeadObject 对缺失 key 经 render_error 产出 XML body（HTTP 层会剥离 HEAD body；与 head_bucket 特例不一致，轻微）。

### 环境特有阻塞（非代码缺陷）

- **本机 Windows 把 TCP 9000–9099 列入 OS 保留排除段**（`netsh int ipv4 show excludedportrange tcp` 实证）→ 监督树绑定 S3 端口 9000 报 `:eacces`。**已在 M2-1 修复**：`config/dev.exs` 把 dev S3 端口移至 **9900**（`config.exs`/prod 仍默认 9000）。测试用 `Endpoint.call/2` 直驱不受端口影响。

## M2 实现摘要（subagent-driven：研究核验 → planner → 串行 executor M2-1…M2-7 → 独立 verifier → 独立 code-reviewer）

- **191 测试全绿、`compile --warnings-as-errors` 零警告**（commit `51e6b0f`→`46f8662`，9 个实现 + 验证/审查 agent）。
- **M2-1 M1 硬化**：dev 端口→9900；aws-chunked 非 hex 帧头 raise `IncompleteBody`（消除静默截断）；`:single` 模式校验声明 `x-amz-content-sha256` 与实际 body（不符→400 `XAmzContentSHA256Mismatch`）；`Object.put` 失败时 try/rescue 删除孤儿字节再 reraise；`HeadObject` 缺失 key 返回 404 空体（HEAD 无 XML body）。`Storage` put_result 加 `:sha256`。
- **M2-2 `Maxio.Auth.SigV4.StreamingVerifier` 状态机**：逐块 6 行 string-to-sign 链 + 常数时间比对 + 0 大小终止块 + trailer 5 行；**内嵌 AWS sigv4-streaming 官方已知答案向量（seed `4f232c..`→`ad80c730..`→`0055627c..`→`b6c6ea8a..`）逐字节回归**。
- **M2-3 接入 `BodyReader`**：替换 M1 passthrough 为逐块真实验证，坏块在惰性流内 raise→Dispatch 渲染 403 SignatureDoesNotMatch 且不落盘；`Auth.authenticate/1` 改返回 `{:ok, principal, sig_context}`（kSigning 只推导一次）；SigV4A 流式早拒 501。
- **M2-4 Multipart 地基**：`Storage.Backend` 新增 parts 回调（put_part/get_part_stream/assemble/abort_upload）+ FS 实现；`multipart_uploads`/`multipart_parts` 迁移（**中文 COMMENT** + FK 级联 + 唯一索引）；`Maxio.Multipart` 上下文；multipart ETag = `hex(MD5(concat 16字节原始MD5))-N`。
- **M2-5 Multipart 管线**：CompleteMultipartUpload 入站 SAX 解析（小 XML 带上限整读）+ 4 出站 view + `Handlers.Multipart` 6 操作 + Dispatcher 升级（`uploads`/`uploadid`/`partnumber` 从 `:not_implemented` 转真实分发）+ 自签 e2e。
- **M2-6 DeleteObjects + 条件头 + 多区间**：`?delete` 批删（Delete SAX + DeleteResult view，verbose/quiet，缺失 key 也算 Deleted，>1000 → MalformedXML）；`Maxio.S3.Conditional`（If-Match/If-None-Match/If-Modified-Since/If-Unmodified-Since，RFC 7232 §6 次序，304/412）于 GET/HEAD/PUT；多区间 Range → 完整 200。
- **M2-7 CopyObject**：`x-amz-copy-source` 分流 + metadata-directive COPY/REPLACE + 源条件头 + 自拷贝守卫 + 流式 src→dest（不缓冲）+ CopyObjectResult view。

### M2 已知非阻塞项（reviewer notes，纳入 M3 开头硬化）

1. **CopyObject 自拷贝 + REPLACE 指令数据丢失（须修）**：`src==dest` 且 metadata-directive=REPLACE 时，FS `do_put` 以 `[:write]` 打开 dest（截断）早于读 source 流 → 源被清零。COPY 自拷贝已守卫 400，REPLACE 自拷贝未防护、无测试。建议：src==dest 检测后走临时文件或拒绝。
2. `Multipart.complete` 内部 `abort_upload` 与 handler 的 `abort` 重复清理（幂等 rm_rf 无害，可去其一）。
3. `Conditional` 用全微秒 last_modified 与秒粒度 HTTP 日期比较，同秒内修改可能与 AWS 秒粒度结论分歧（边缘）。建议截断到秒。

## M3 实现摘要（subagent-driven：研究核验 → planner → 串行 executor M3-1…M3-9 → 独立 verifier/reviewer）

- **275 测试全绿、`compile --warnings-as-errors` 零警告**（M2 基线 191 + M3 新增；串行 executor 逐单元实现 + 强制 StructuredOutput）。计划：`plans/2026-06-08-m3-iam-policy.md`。
- **M3-1 M2 硬化（3 项 reviewer note 治本）**：(a) CopyObject REPLACE **自拷贝数据丢失**修复——`src==dest` 走唯一临时 key 中转（`copy_bytes/5` 两子句，先写 temp 再流式搬 dest 再删 temp，避免「截断 dest 早于读 source」清零）；(b) `Multipart.complete` 去重——移除 context 内 `abort_upload`，清理统一由 handler 的 `Multipart.abort/1` 单一负责；(c) `Conditional.evaluate/3` 把存储 `last_modified` 截断到秒（`truncate_to_second/1`）再与秒粒度 HTTP-date 比较。
- **M3-2 Policy 纯数据/解析层**：`Maxio.Policy.Arn`（`bucket_arn`/`object_arn`/`account_arn`/`glob_match?/3`：`*`→`.*`、`?`→`.`、`\A…\z` 锚定、Action 大小写不敏感/Resource 敏感）；`Maxio.Policy.Statement`（`parse_policy/1`/`from_json/1`：Version/Effect/Action/Resource/Principal/Condition 规范化与校验，畸形 → `:malformed`）；`Maxio.Policy.RequestContext`（principal/authenticated?/owner?/action/resource/conditions）。
- **M3-3 Evaluator 评估核心（真值表硬测）**：`Maxio.Policy.Evaluator.evaluate/2 :: :allow | {:deny, :explicit_deny | :implicit_deny}`——owner? 短路 → 显式 Deny 优先 → 显式 Allow → 默认隐式拒绝；`statement_applies?` = principal ∧ action ∧ resource ∧ Condition.hold?（effect 不参与 applicable）；匿名 principal 绝不匹配 `{:aws,_}`。`Maxio.Policy.Condition` MVP 算子子集 `StringEquals/StringLike/Bool/IpAddress/DateGreaterThan`（未知算子保守判不成立）。
- **M3-4 凭据持久化**：`access_keys` 迁移（binary_id、中文 COMMENT、唯一索引）+ `Maxio.IAM.AccessKey` schema + `Maxio.Auth.CredentialStore.EctoStore`（实现既有 behaviour，inactive 视同缺失）+ `Maxio.IAM`（`bootstrap_root/0` 幂等 upsert、create/list/delete，拒删最后一个 root）+ boot 引导（EctoStore 下 application start 幂等 upsert root）+ `mix maxio.iam.{create_key,list_keys,delete_key}` CLI。config 默认翻 EctoStore（test 覆盖回 MemoryStore）。
- **M3-5/6 Bucket Policy（存储 + API）**：`Maxio.Policy.Store` behaviour（`get/put/delete_bucket_policy`、`principal_policies`、门面 `statements_for_bucket/1`）+ `bucket_policies` 迁移（jsonb document、中文 COMMENT）+ `EctoStore`；`Put/Get/DeleteBucketPolicy`（`?policy` 子资源，JSON body 带上限整读、`Statement.parse_policy` 校验 → `MalformedPolicy 400`）；Dispatcher `?policy` 从 `:not_implemented` 升级真实分发；新错误码 `:malformed_policy`/`:no_such_bucket_policy`。
- **M3-7 Canned ACL（折叠进同一 Evaluator）**：`x-amz-acl` 于 CreateBucket/PutObject 存为 `acl_canned` 元数据（schema + 迁移 + 中文 COMMENT）；`Put/Get Bucket/Object ACL`（`?acl` 子资源，`AccessControlPolicy` XML 出入站，saxy SAX 解析 + view 渲染）；`Maxio.Policy.ACL.canned_to_statements/4` 把 canned 翻成等价 allow statement（`authenticated-read` 用内部条件键 `maxio:Authenticated`）**折叠进同一个 Evaluator**，绝不另起 ACL 评估路径；email grantee → `400 InvalidArgument`，`x-amz-grant-*` 退化 private + warning。
- **M3-8 Authz 关卡 + 匿名 principal**：`Maxio.Policy.ActionMap.for_action/1`（全 M1/M2 operation → `{s3:Action, 层级}`，未映射 → 放行）；`Maxio.S3.Authz.authorize/2` 在 Dispatch 解析出 action 后、调 handler 前插入——构造 RequestContext（owner?/authenticated? + 条件键 SecureTransport/SourceIp/CurrentTime/maxio:Authenticated/s3:prefix）、合并 bucket policy + ACL 派生 statement、评估 → `:ok` 或 `raise AccessDenied(403)` + 结构化日志（绝不静默）；CopyObject 对源对象做 `s3:GetObject` 二次检查（拒 → `copy_object_source` AccessDenied）。SigV4 plug：**完全无凭据 → principal `:anonymous`**（而非 `MissingSecurityHeader 400`），坏凭据/坏签名仍硬失败（边界精确）。
- **M3-9 端到端授权矩阵 + 本文档**：`test/maxio/s3/authz_matrix_test.exs`（认证非 owner 无 policy → 403；policy 命名 principal arn → 放行；`StringLike` `s3:prefix` 限制 ListBucket；CopyObject 源读二次检查拒绝）+ `SigV4Request.signed_conn/3` 支持自定义 `access_key`/`secret`（注入非 owner principal 签名）。

### M3 已知非阻塞项 / 显式 defer（文档化，绝不静默）

1. **跨账户 / 多租户所有权**：单租户。`bucket-owner-read`/`bucket-owner-full-control` canned 仅存名、按 `private` 评估。`AuthenticatedUsers` 组 = 任意有效签名 principal（内部 `maxio:Authenticated`）。
2. **完整条件算子**：仅 `StringEquals`/`StringLike`/`Bool`/`IpAddress`/`DateGreaterThan`。其余算子（含 `NotAction`/`NotResource`/`NotPrincipal`、`Numeric*`/`Arn*`/`Null`/`ForAnyValue:`/`*IfExists`）→ 含该算子的 Condition 块**保守判不成立**（statement 不命中），绝不静默放行更多权限。
3. **IAM identity policy（user inline policy）**：`Store.principal_policies/1` 恒 `[]`。授权由 bucket policy + ACL 派生 + owner/root 短路驱动。
4. **STS / 临时凭据 / session token**：`X-Amz-Security-Token` 不解析；presigned 仅支持长期 key。
5. **email grantee（AmazonCustomerByEmail）**：→ `400 InvalidArgument`（AWS 已于 2025-10-01 停支）。
6. **explicit `x-amz-grant-*` 头 / 多 grantee 细粒度评估**：PutAcl 收到 `x-amz-grant-*` → 退化 `private`（不放行更多权限）+ warning；ACL XML round-trip 仅分类回最接近 canned。
7. **Block Public Access** 设置 → 未实现。
8. **`aws-exec-read` / `log-delivery-write` canned** → 仅存名不产生公共 statement。
9. **checksum trailer 重算** → 沿用 M2 defer。
10. **DeleteObjects 逐 key 细粒度授权**：用桶级 `s3:DeleteObject` 作粗粒度门；逐 key 检查 defer。
11. **secret at-rest 加密**：MVP 明文存储（COMMENT 已标）；信封加密留后续，仅改 EctoStore 读写两点。

### M3 独立 code-reviewer 补充非阻塞项（post-review，纳入 M4 开头修复）

reviewer 终审 APPROVE_WITH_NOTES / 0 must-fix，另挖 4 项（当前无害，M4 前/中修）：

1. **潜伏 bug（当前 inert，须在 M4 IAM identity policy 落地前修）**：`Maxio.S3.Authz.gather_statements/3` 硬编码调用 `Store.principal_policies(:anonymous)`，无视真实 principal。MVP 该函数恒返回 `[]` 故无害；一旦实现 identity policy，认证用户的身份策略会被静默丢弃 → 静默拒绝。**应把真实 principal 传入**。
2. **`delete_objects` 桶级粗粒度门（fail-closed，可接受）**：批删用桶 ARN + `s3:DeleteObject` 鉴权，作用于 `arn:aws:s3:::bucket/*` 的对象级 policy 不会命中 → 批删被拒。**失败偏保守、无安全洞**，逐 key 鉴权已 defer。
3. **CopyObject 不传播 `acl_canned`（正确但隐式）**：copy 覆盖会把目标 ACL 重置为 private——与 AWS 默认（copy 不保留 ACL，除非带 `x-amz-acl`）一致，仅为隐式行为。
4. **Principal `{:aws, list}` 用 glob 匹配（轻微过权）**：AWS 视 Principal 为精确匹配（除非 policy variable）。`arn:aws:iam:::user/*` 会被通配命中。建议后续改 AWS principal 精确匹配。

## M4 实现摘要（subagent-driven：研究核验 → planner → 串行 executor M4-1…M4-8 → 独立 verifier/reviewer）

- **349 测试全绿、`compile --warnings-as-errors` 零警告**（M3 基线 275 + M4 新增；串行 executor 逐单元实现 + 强制 StructuredOutput）。计划：`plans/2026-06-09-m4-advanced-features.md`。
- **M4-1 M3 收尾硬化（reviewer note 1/4 治本）**：`Maxio.S3.Authz.gather_statements/3`→`/4`，把真实 `principal` 贯穿到 `Store.principal_policies/1`（不再硬编码 `:anonymous`，identity policy 落地前接口就绪）；`Maxio.Policy.Evaluator` 的 AWS Principal `{:aws, list}` 改**精确字符串等值**（区分大小写，不再 glob 过度命中；Statement 已把纯 `"*"` 归一化为 `:any`）。回归测试 `authz_principal_test`/`principal_exact_test`。
- **M4-2 XML 入站解析框架 + 配置载体**：`buckets` 加 `versioning`（三态 `Unversioned`/`Enabled`/`Suspended`，默认 Unversioned）+ `mfa_delete` 列；新建 `bucket_configs` 表（每桶一行，`cors`/`lifecycle`/`encryption` 各一 jsonb，唯一 `bucket_name` 索引，全中文 COMMENT）+ `Maxio.BucketConfigs` 上下文（`get/2`/`put/3`/`delete/2`，按 kind 读写单列，`get` 返回已解析 list/map 或 `:none`）；第一个 saxy SAX 解析器 `Maxio.S3.RequestParsers.VersioningConfiguration`（确立 `local/1` 去命名空间前缀模式，非法 Status/MfaDelete 值→`:malformed_xml`）。
- **M4-3a Versioning 核心**：`objects` 表演进为「多版本行」模型——加 `version_id`(ULID 或保留串 `"null"`)/`is_latest`/`is_delete_marker` 列，唯一约束改 `(bucket_id,key,version_id)`，全中文 COMMENT；`Maxio.Versioning.VersionId`（自实现 ULID：48-bit 毫秒时间戳 + 80-bit 随机，Crockford base32 26 字符，时间有序、URL-safe）；`Maxio.Storage.Backend` behaviour 演进——`put/get/stat/delete` 全部加 `version_id` 维度（FS `"null"`→原路径向后兼容、否则 `.versions/<bucket>/<key>/<version_id>` 路径）；`Maxio.Objects` 加 `get_version`/`put_version`/`put_version_with_id`/`insert_delete_marker`/`delete_version`（delete marker 是无字节的特殊版本行，etag 空串 sentinel）；Object handler 实现三态 Put/Get/Head/Delete 版本语义（Enabled 生成新 ULID 置 latest；Suspended/Unversioned `"null"` 就地覆盖；GET 当前 delete marker→404 + `x-amz-delete-marker`，`?versionId` 指向 delete marker→405；DELETE 无 versionId 插 delete marker，`?versionId` 永久删该版本并提升下一最新版本）；`x-amz-version-id`/`x-amz-delete-marker` 响应头；`PutBucketVersioning`/`GetBucketVersioning`（`?versioning`，never-set 不回 `<Status>`）。
- **M4-3b ListObjectVersions + latest 过滤**：`Maxio.Objects.list_objects_v2/2` 收紧为只返回 `is_latest=true and is_delete_marker=false`；`list_object_versions/2`（二维游标 `key>marker OR (key==marker AND version_id<vid_marker)`，`ORDER BY key asc, version_id desc` = newest-first，common prefixes/delimiter）；`Maxio.S3.Views.ListVersions`（Version 与 DeleteMarker 交错，DeleteMarker 无 ETag/Size/StorageClass）；`?versions` Dispatcher/ActionMap/Handlers 三处接线 + e2e。
- **M4-4 Tagging**：`objects.tags`/`buckets.tags`（jsonb，中文 COMMENT）；`Maxio.Tags`（`validate/2` 对象≤10/桶≤50、键 1..128/值 0..256、不可 `aws:` 前缀、允许字符正则；`parse_header/1` 解 `x-amz-tagging` query-string；`map_to_list`/`list_to_map`）；`Maxio.S3.RequestParsers.Tagging` + `Maxio.S3.Views.Tagging`；`Maxio.S3.Handlers.Tagging`（对象/桶 `?tagging` PUT/GET/DELETE）；PutObject 的 `x-amz-tagging` 头落版本行；GET/HEAD 的 `x-amz-tagging-count` 响应头（仅 >0 时）；超限→`InvalidTag 400`（新错误码）；`?tagging&versionId=` 作用于指定版本行。
- **M4-5 CORS**：`Maxio.S3.RequestParsers.Cors` + `Maxio.S3.Views.Cors`；`Maxio.Cors`（`match_preflight/4`/`match_actual/3` 首个匹配、单 `*` 通配、AllowedHeader 大小写不敏感）；`Maxio.S3.Handlers.Cors`（`?cors` PUT/GET/DELETE，校验≤100 规则/方法非空/至多一 `*`，无配置→`NoSuchCORSConfiguration 404`）；`Maxio.S3.Plugs.Cors`（OPTIONS 预检在 SigV4 **之前** 命中→200+CORS 头并 halt，预检不签名；非 OPTIONS 带 Origin→注册 `before_send` 注入 ACAO/ACAM/Expose/Vary，流式安全；无 Origin 完全放行不动既有管线）；Endpoint 插入于 AddressStyle 与 SigV4 之间；新错误码 `access_forbidden`/`no_such_cors_configuration`。仅作用于 S3 Endpoint（Console:4000 不受影响）。
- **M4-6 Lifecycle（config-only，执行 defer）**：`Maxio.S3.RequestParsers.Lifecycle` + `Maxio.S3.Views.Lifecycle`（Filter/And/legacy Prefix、Expiration、NoncurrentVersionExpiration、AbortIncompleteMultipartUpload、Transition 字节级往返）；`Maxio.S3.Handlers.Lifecycle`（`?lifecycle` PUT/GET/DELETE，校验≤1000 规则/Status/Expiration 不可 Days+Date/ExpiredObjectDeleteMarker 互斥，无配置→`NoSuchLifecycleConfiguration 404`）；**后台过期/中止 MPU 执行未实现（defer，诚实暴露）**——`Maxio.Application` 启动 `Logger.info` 列 M4 defer + `mix maxio.lifecycle.run` stub 打印「execution not implemented」+ README 标注。
- **M4-7 SSE-S3（真实 AES-256-GCM 信封加密）**：`objects` 加 `sse_algorithm`(`"AES256"`|nil) + `sse_envelope`(jsonb `%{wrapped_dek_b64,dek_iv_b64,dek_tag_b64}`)，中文 COMMENT；`Maxio.Crypto.SSE`（`wrap_stream`：每对象随机 256-bit DEK，数据重切 64KB 帧、每帧 AES-256-GCM 独立 IV+tag、帧头 `<ct_len::32><iv::96><tag::128>`，DEK 由单一静态主密钥 AES-256-GCM 包裹；`unwrap_stream` 逐帧解密，GCM 认证失败 RAISE 绝不静默）；PutObject `x-amz-server-side-encryption: AES256`（或桶默认加密）→真实 at-rest 加密 + 回显头；GET 透明解密；`PutBucketEncryption`/`Get`/`Delete`（`?encryption`）；`aws:kms`/`aws:kms:dsse`/SSE-C→`501 NotImplemented`（绝不静默当 AES256）；新错误码 `server_side_encryption_configuration_not_found`；主密钥经 `config :maxio, :sse, master_key`（base64 32B，dev/test 固定值，prod 经 env）。
- **M4-8 跨特性集成矩阵 + 文档收尾**：`test/maxio/s3/m4_matrix_test.exs`（版本化+tagging 逐版本作用域、版本化+SSE 多版本各自解密、authz 匿名 public-read 版本化对象放行）全绿；全量回归 349 测试绿；本 STATUS + README 高级特性章节（含 defer 清单）更新。

### M4 已知非阻塞项 / 显式 defer（文档化，绝不静默放行/吞错）

1. **Lifecycle 后台过期/中止 MPU 执行**：M4 仅**存储 + 校验 + 出站**配置；不跑后台 sweeper。诚实暴露：启动 `Logger.info` + `mix maxio.lifecycle.run` stub + README。`Transition`/`NoncurrentVersionTransition` 单层 maxio 接受持久化但 no-op。
2. **MFA Delete**：`MfaDelete` 状态解析/存储/回显（GetBucketVersioning 仅曾配置时回 `<MfaDelete>`），但**不强制 MFA 校验**（无设备），`x-amz-mfa` 头不验证。
3. **SSE-C / SSE-KMS / DSSE-KMS**：仅 SSE-S3（AES256）。`aws:kms`/`aws:kms:dsse` 或 `x-amz-server-side-encryption-customer-*` → `501 NotImplemented`（绝不静默当 AES256）。`BucketKeyEnabled` 接受持久化但 no-op（KMS 专属）。
4. **SSE 密钥管理简化**：单一静态服务端主密钥（`config/env`），无轮转/HSM/KMS——README/启动日志已声明。
5. **SSE 对象 + Range / 大对象逐帧流式解密**：MVP 对加密对象的 Range 请求降级为完整对象（200，绝不返回错数据）；GET 整对象解密后 `send_resp`（大对象逐帧流式解密留后续优化）。SSE 对象 `objects.size` 存密文长度（FS 见密文），GET 的 `Content-Length` 用解密后明文 `byte_size`，HEAD 用密文长度（近似，AWS-like）；ETag 为密文 MD5（与 AWS SSE-S3 一致非明文 MD5）。
6. **Multipart 完成对象在版本化桶的逐版本字节路径**：multipart Complete 的对象字节走 null 路径、元数据当 latest null 版本；多段对象逐版本化字节路径 defer（单段 PutObject 版本化完整）。
7. **对象级逐版本独立 tag set**：tag 挂在版本行（`?tagging&versionId` 已支持指定版本）；`s3:*VersionTagging` 细粒度权限按同名非 version 权限评估（单租户）。
8. **lifecycle `Date`（绝对时间）与 `Transition` 执行**：仅存储/校验。
9. **沿用 M3 全部 defer**：跨账户/多租户、完整条件算子、identity policy（`principal_policies/1` 恒 `[]`，M4-1 已修为传真实 principal——接口就绪，实现仍 defer）、STS/session token、email grantee、`x-amz-grant-*` 细粒度、Block Public Access、checksum trailer 重算、DeleteObjects 逐 key 授权。

### M4 独立 code-reviewer 补充非阻塞项（post-review，纳入 M5 backlog）

reviewer 终审 APPROVE_WITH_NOTES / 0 must-fix，另挖 4 项（均已文档化 defer、无静默失败）：

1. **SSE 对象 GET 全缓冲 + Range 降级（轻微违铁律 4，opt-in）**：加密对象 GET 把整密文读入内存解密（`unwrap_stream` `Enum.to_list`），Range 降级为完整 200。建议后续做逐帧流式 GET + 分帧 Range。
2. **Multipart-complete / CopyObject 在 Enabled 桶仍写 `version_id:"null"`/`is_latest:true`**：内部一致（字节走 null 路径），但 Enabled 桶若已有 ULID 版本，会 unset 它们的 latest 并让 null 行成 latest。已 defer #6，待 MPU 逐版本字节路径时修。
3. **`delete_version` 的 promote_latest 按 `version_id DESC`**：混合 null+ULID 历史下可能把 "null" 当最新提升（源于 #2 的 edge）。
4. **装饰性**：CORS 实际响应设了 `Access-Control-Allow-Methods` 且 `Vary` 仅 `Origin`（AWS 实际响应通常省 ACAM）；`lifecycle valid_rule?` 允许有 Status 无 action 的规则（AWS 要求 ≥1 action）。无害。

## M5 实现摘要（subagent-driven：串行 executor M5-1…M5-9，每单元强制 StructuredOutput + 独立 reviewer/verifier 隔离）

- **`compile --warnings-as-errors` 零警告、全量 `mix test` 绿**（M4 基线 349 + M5 新增 Console 单测与跨页 e2e 矩阵）。计划：`plans/2026-06-09-m5-console.md`。Console 跑在既有 `MaxioWeb.Endpoint`(:4000)，**物理隔离于 S3 Endpoint**(:9900/:9000)，**直接调用 maxio context**（同进程，不经 S3 HTTP API；唯一例外是预签名分享 URL，已 defer）。
- **M5-1 Console 鉴权地基**：`MaxioWeb.ConsoleAuth`（`verify_credentials/2` 复用 `CredentialStore.get_secret/1` 常数时间比对、未知 ak 也假比对抹平计时；`log_in/2` renew session；`log_out/1` drop；`fetch_principal/1`；`session_key/0`→`"console_access_key"`，secret 绝不入 session）+ `ConsoleAuth.OnMount`（`:require_authenticated` 无 principal halt redirect `/login`；`:mount_current_principal`）+ `ConsoleAuthPlug`（`fetch_current_principal/2` 入 `:browser` 管线）+ `SessionController`(:new/:create/:delete) + `SessionHTML`/`new.html.heex`（登录页 `layout: false`，`#login-form`/`#login-error`/`#login-submit`，凭据错不泄露 ak/sk 谁错）+ 路由 public/protected 双区（受保护 `live_session :console_authenticated`）+ ConnCase `log_in_console/2` + app.js `window.__maxio` 钩子 + `[maxio][Console]` 标签日志。架构删除（非 hack）：旧 `PageController`/`PageHTML`/`home.html.heex`/`page_controller_test.exs`（GET / 被受保护 DashboardLive 取代）。
- **M5-2 App Shell**：`Layouts.app/1` 改造为 Console 侧边栏 shell——`#console-sidebar` + `#nav-dashboard`/`#nav-buckets`/`#nav-access-keys`（私有 `nav_link/1` 组件）+ `#current-identity`(@current_scope.access_key) + `#logout-link`(`<.link href="/logout" method="delete">`) + 既有 `theme_toggle`；`flash_group/1` 仍只在 layouts.ex。新增最小占位 `BucketLive.Index`/`AccessKeyLive.Index` 使受保护路由（侧边栏 `~p` 链接）在 Phoenix 1.8 verified-routes + 路由 `__checks__` 下编译期可解析（同 M5-1 对 DashboardLive 的占位模式，各单元再「完整替换」）。
- **M5-3 Dashboard**：`Maxio.Console.Stats.dashboard/0`（廉价 `Repo.aggregate` + per-bucket group_by；object_count/total_size 只算 `is_latest=true and not is_delete_marker`，与 ListObjectsV2 口径一致；`sum` nil → 0 空态不崩）；DashboardLive 充实 5 张统计卡片（`#stat-buckets`/`#stat-objects`/`#stat-size`/`#stat-keys`/`#stat-multipart`）+ `#per-bucket-table`（per-bucket 行可导航 `/buckets/:name/browse`）+ 私有 `format_bytes/1`。
- **M5-4 Buckets 列表/创建/删除**：`BucketLive.Index` 完整替换占位——streams（`#buckets` 父 + `#buckets-empty` 空态）+ 创建表单（`Buckets.create/2`，owner=`current_principal.arn`）+ 删除（先 `lookup` 拿 `%Bucket{}` 再 `stream_delete`）；完整错误 flash 矩阵（`:invalid_bucket_name`/`:already_owned`/changeset/`:not_empty`/`:not_found`，绝不静默吞掉）。
- **M5-5 Object Browser + 下载**：`ObjectLive.Index` 完整替换占位——prefix 面包屑（`handle_params` 读 `?prefix=` → `list_objects_v2` delimiter → `stream(reset: true)`）+ **上传**（`allow_upload` ≤5 GiB → `consume_uploaded_entries` `File.stream!` 流式喂 `Storage.put` + `put_version_with_id`，Storage 错 `{:postpone}` + `[maxio][Console]` Logger.error + flash，绝不静默）+ 新建文件夹（零字节 `prefix/` 对象）+ 删除（版本化感知）；`DownloadController.show/2` plain controller `send_chunked` + `Enum.reduce_while`（`{:error,:closed}` halt，绝不全缓冲，铁律 4）。
- **M5-6 Object Detail**：`ObjectLive.Show` 完整替换占位——`#object-detail` 元数据 + 标签编辑（raw 文本 ↔ `[{k,v}]`，`Tags.validate(_, :object)`，`:invalid_tag` 显式 flash）+ 版本历史 stream（`list_object_versions`，含 delete marker badge，per-version 流式下载/永久删除 `delete_version` 后 `stream(reset: true)` 反映 promote_latest）；不存在桶/对象 `push_navigate` 回 browse + flash。
- **M5-7 Bucket Settings（7 tab）**：`BucketLive.Settings` 完整替换占位——`?tab=` + `push_patch` 在 versioning/policy/acl/tags/cors/lifecycle/encryption 间切换；versioning（`put_versioning/3`，"Unversioned"→"Suspended" 映射）+ policy JSON（`Statement.parse_policy` 校验，空=`delete_bucket_policy`，畸形→MalformedPolicy flash）+ canned ACL（`put_acl/2`，非 @canned 拒绝）+ 桶标签（`Tags.validate(_, :bucket)`）+ CORS/lifecycle JSON（`BucketConfigs` put/delete，畸形 JSON flash，lifecycle 显式 defer-alert）+ 默认加密（`none`=禁用 / `AES256` / SSE-KMS 绝不静默当 AES256，KMS 永不覆盖既有 AES256）。
- **M5-8 Access Keys**：`AccessKeyLive.Index` 完整替换占位——列表 stream（`#access-keys`，自定义 `dom_id`，绝不回 secret）+ 创建（`IAM.create_access_key`，secret 经 `#new-secret-banner` 仅显示一次、一次性 assign 不入 stream/session）+ 删除（`IAM.delete_access_key`，`:cannot_delete_last_root` 显式 flash）；root/iam_user badge 区分。
- **M5-9 Polish + e2e 矩阵 + 文档**：`test/maxio_web/live/console_e2e_test.exs`（全链路 建桶→浏览→详情→设置启用版本化→access keys + 未登录全程门控 `/`/`/buckets`/`/access-keys` 均 redirect `/login`）+ README Console 章节（含完整 defer 清单）+ 本 STATUS 更新。

### M5 已知非阻塞项 / 显式 defer（文档化，绝不静默放行/假装实现）

1. **Identity（Users/Groups/IAM identity policy/STS/IdP）**：maxio 单租户，无独立 user/group 实体（`principal_policies/1` 恒 `[]`）。Console 用 access key 作 identity primitive；Users/Groups 在侧边栏**不出现**（不画灰条目假装有）。
2. **Bucket 高级（Quota/Events-Notifications/Replication/Object-Lock-Retention-Legal-Hold）**：后端未实现，Settings 不画这些 tab。
3. **Object（内联预览/Legal hold/Retention）**：未实现；SSE 对象 GET 全缓冲（M4 defer #5）使大加密对象预览风险——仅下载。
4. **Monitoring（Logs/Trace/Audit/Drives/Heal/时序图）**：需 Prometheus/纠删码（M6）；Dashboard 只做廉价计数。
5. **Configuration 运行时编辑 / Tiers / Site Replication / Batch Jobs / License**：后端无运行时配置存储；不做。
6. **Console 大文件多段上传**：MVP 走单 PUT（≤5 GiB，服务端临时文件中转）；接 `Maxio.Multipart` 逐 part 上传标为后续优化（`VERIFY-AT-IMPL: console multipart`）。
7. **生命周期后台执行**：Console 可编辑规则，后台过期/转储执行未实现（沿用 M4 defer #1）。
8. **预签名分享 URL**：可经 `Maxio.Auth.SigV4.Signer` 生成指向 S3 端的预签名 GET（唯一引用 S3 HTTP 之处），MVP 未做 UI（不画死按钮）。

### M5 各单元 executor 记录的架构性偏差（非 hack，已在各 commit 落证）

- **forward-reference 路由预注册（M5-1..M5-5 一致模式）**：Phoenix 1.8 verified-routes 在编译期校验 `~p` 路径存在，且路由 `__checks__/0` 校验目标 LiveView 定义 `__live__/0`——两者在 `--warnings-as-errors` 下均会失败，除非路由 + 模块当下即存在。故各单元在引入指向后续单元页面的 `<.link navigate=>` 时，同步在 `:console_authenticated` 预注册路由 + 最小占位 LiveView，后续单元「完整替换」占位（绝不重复添加路由）。这把受保护 Console 路由表 + 导航 chrome 视为一个内聚面，符合 verified-routes 契约。
- **`push_navigate` 重定向断言更正**：mount 内 `push_navigate/2` 始终 yield `:live_redirect`（非 `:redirect`）；M5-5/M5-6/M5-7 的 not-found 测试断言相应更正为 `{:error, {:live_redirect, %{...}}}`（LiveView 逻辑不变）。受保护页未登录门控经 OnMount `redirect/2` 则 yield `:redirect`（e2e 矩阵的未登录断言用 `:redirect` 正确）。
- **登出测试**：`configure_session(drop: true)` 仅在响应发送时丢弃 cookie；测试 `recycle()` + 后续 GET 再 `refute get_session` 验证 dropped cookie 不持久化（controller 逻辑不变，标准 Phoenix log_out 模式）。
- **HEEx 安全**：settings 的 CORS 帮助文本曾内嵌字面 JSON（`{`/`:` 被 HEEx 当插值解析失败），改为字段名 `<code>` 列表（同等信息、HEEx 安全）；占位 moduledoc 内 `#{...}` 会被插值，改写为 `<bucket>` 角括号避免 CompileError。
- **ConnCase 不 import `Phoenix.LiveViewTest`**：所有 M5 Console 测试文件各自 `import Phoenix.LiveViewTest`（一致约定）。
- **M5-9 治本的潜伏并发 bug（MemoryStore 惰性建表竞态，架构级修复非 hack）**：`Maxio.Auth.CredentialStore.MemoryStore` 惰性建 `:public, :named_table` ETS 表——建表进程在 `:ets.new` 与 `bootstrap_root` 之间存在窗口，并发 reader 可读到「表已存在但 root 行未注入」→ root `get_secret` 误返回 `:error`（Console 鉴权 mount 误判未登录 → 全程 redirect /login，e2e 矩阵首个 `live(~p"/buckets")` 偶发失败）。M5 e2e 矩阵作为早期 async 测试首次稳定暴露此竞态。修复（铁律 3，绝不静默丢失 root）：`get_secret` 对 root key 的空查询走 `maybe_bootstrap_root_for/1` 幂等补 `bootstrap_root` 再重查；新增私有 `root_access_key/0` 读 config。全量 412 测试在原失败 seed 790436 + seed 0 + 随机 seed 下稳定全绿。

### M5 独立 code-reviewer 补充非阻塞项（post-review，纳入 M6 backlog）

reviewer 终审 APPROVE_WITH_NOTES / 0 must-fix，另挖 4 项（无崩溃/安全洞）：

1. **Console 的 CORS/Lifecycle 保存跳过 S3 handler 的语义 `validate!`（最值得跟进，S3 行为 parity）**：`bucket_live/settings.ex` 的 `save_cors`/`save_lifecycle` 直接 `Jason.decode` → `BucketConfigs.put`，绕过 `Maxio.S3.Handlers.{Cors,Lifecycle}.validate!`（method 白名单 / 至多一个 `*` / 规则数上限 / Status 取值 / Days+Date 互斥）。故运营者可经 Console 存入 S3 `PutBucketCors/Lifecycle` 会拒的配置，再经 S3 `Get*` 回放。无崩溃（matcher/view 防御性读）。建议把 `validate!` 抽到上下文/共享模块，Console 与 S3 handler 共用 + 加负例测试。
2. **`create_folder` 在 Enabled 桶硬编码 version_id "null"**（同 M4 note #2 类，仅文件夹标记）。
3. **`save_upload` 在 `Storage.put` 成功后用 `{:ok, obj} =` 硬匹配 `put_version_with_id`**：元数据插入若非 `{:ok}` 会崩 LV 进程且留孤儿字节（robustness，非鉴权关键路径）。
4. **`download_controller` 用 `{:ok, stream} = Storage.get(...)` 硬匹配**：元数据存在但字节缺失（divergence）时会 500，建议映射结构化 404/500。

## M6 实现摘要（纠删码 · 单机多盘 · Rustler NIF · subagent-driven 串行 executor M6-1…M6-5）

- **`compile --warnings-as-errors` 零警告、全量 `mix test` 绿**（M5 基线 + M6 新增 NIF/Codec/后端/conformance/e2e/heal/scrub/bitrot 全套）。计划：`plans/2026-06-09-m6-erasure-coding.md`。核心管线**一行不改**：M6 仅新增一个 `Maxio.Storage.Backend` 实现 `Maxio.Storage.ErasureCoded`，经 `config :maxio, :storage_backend` 切换即启用（铁律 2 后端即插件，facade/behaviour/FS/handler/dispatcher/endpoint 全部未改）。
- **M6-1 Rust NIF crate**（`native/maxio_native`，镜像姊妹项目 huanxi 的 `h3o` Rustler 模式）：`reed-solomon-simd 3.1`（GF(2^16) SIMD、纯 Rust、Windows MSVC 无 C 依赖）+ `blake3 1` + `rustler 0.38`，cdylib 经 `use Rustler` 宏在 `mix compile` 期驱动 cargo 构建。`Maxio.Native.ErasureCoding`：`encode/3`（K+M 等长分片，systematic 前 K 数据分片、末数据分片零填充）/ `reconstruct/3`（从 `[binary|nil]` 重建，缺/损置 nil）/ `blake3/1`（32 字节 per-shard 校验和）；契约「成功即返回值、非法即 raise ArgumentError」。NIF 名 `native_rs_encode`/`native_rs_reconstruct`/`native_blake3`。**架构级修正**：(a) reed_solomon_simd 3.1 `decode` 返回 `BTreeMap` 非计划所述 `HashMap`（`.get(&i)` API 不变，调用方无感）；(b) k=0 用显式 fallback 子句 raise `ArgumentError`（非 `FunctionClauseError`），对齐 success-or-raise 契约；(c) `.gitignore` 加 `/priv/native/`（避免提交 `mix compile` 拷贝的 cdylib）。
- **M6-2 块编解码层**（纯 Elixir over NIF，不触盘/DB）：`Maxio.Storage.Erasure.Config`（`load!/1` 合并 opts+config、校验 `N==K+M`/`M<=N/2`、计算 `read_quorum=K`、`write_quorum= if M==N/2 then K+1 else K`（脑裂边界），`total/1`）；`Maxio.Storage.Erasure.Codec`（`split_block/2` → N 等长分片 + N 个 BLAKE3-256 校验和；`restore_block/5` 逐分片验校验和、不符/缺失置 nil、存活 ≥K 重建+截断、存活 <K → raise；`verify_shard/2`）；`Maxio.Storage.Erasure.InsufficientShardsError`（结构化字段 bucket/key/version_id/block_index/present/required）。**RS 只纠 erasure 不定位 silent corruption** → 校验和把损坏分片显式标记为缺失再交解码器（bitrot 安全的关键，绝不把「在场但损坏」分片喂 reconstruct）。
- **M6-3 ErasureCoded put/get/stat/delete + bucket ops**（流式逐块 + sidecar + quorum，与 FS 返回形态逐字节一致）：对象在每盘 i 落 `<drive>/<bucket>/<rel>/{part.0,meta.json}`（version="null"）或 `.versions/<bucket>/<rel>/<version_id>/{...}`；PUT 用 `Enum.reduce` 块缓冲逐块编码（内存 ≈ 一块 × N 分片，绝不缓冲整对象）、分片 i 追加盘 i 的 part.0、sidecar 写全部 N 盘、成功盘数 ≥ write_quorum 才 `{:ok}`；GET 用 `Stream.resource/3` 逐块 `pread` K 存活分片、按 sidecar `block_hashes` 校验+重建+截断+Range 裁剪；etag/sha256 over **明文**。**架构级修正**（M6-3 prior executor）：(1) bitstring `binary-size` 用 pin 操作符 `^block_size`（Elixir 1.20 拒绝 struct 字段/local）；(2) **均匀 shard_len 不变量**——`write_block` 把每块零填充到固定 `block_size` 后再 split_block，使全对象所有块 shard_len 一致（= even(ceil(block_size/K))），GET 按每块 block_plain_len 截断（填充字节绝不到客户端），从而 `j*shard_len` 偏移寻址成立、解决末块更短分片破坏多块寻址的 bug；(3) `Stream.resource` ACC 形态 `{fds, j}` 在 start/halt/cleanup 三处一致（避免 Tuple 非 Enumerable 崩溃）。Sidecar 形态 `%{"ec"=>%{k,m,block_size,algo:"blake3-256"}, "size","etag","sha256","parts"=>[%{part:0,size}], "shards"=>[%{drive,shard_file_size,block_hashes:[hex...]}]}`。
- **M6-4 parts + 共享 conformance + config 切后端 + S3 e2e**：4 个 parts 回调（put_part/get_part_stream/assemble/abort_upload）依 prior executor「behaviour 全有或全无 vs --warnings-as-errors」决策已在 M6-3 用计划 M6-4 verbatim 代码提前落地，故 M6-4 仅加测试——`test/support/storage_conformance.ex`（`Maxio.Test.StorageConformance` 6 个共享 `test`，using 模块先定义 `@backend Mod` + `defp opts(ctx)` 再 `use`）**同跑 FS 与 ErasureCoded** 证同一契约；`test/maxio/s3/erasure_e2e_test.exs` config-switch（同设 `:storage_backend` + `:erasure`，on_exit 还原）经 `Maxio.S3.Endpoint.call/2` 跑 Put/Get 全量/Range 206/Head/Delete→404，3000B + block_size 1024 验多块流式 + 跨块 Range。e2e 镜像 integration_test 的 `Maxio.DataCase, async: false` + 自签 SigV4（项目无 `Maxio.ConnCase`）。
- **M6-5 heal/scrub + bitrot e2e**：`Maxio.Storage.Erasure.Heal`——`heal_object/4`（取任一存活 sidecar 得 EC 参数 + per-block-per-shard `block_hashes`，逐块逐盘 `pread`+BLAKE3 重算比对、坏分片 ≤M → `Codec.restore_block` 得明文 → 重填充到 block_size → `Codec.split_block` 重编码 → 仅坏盘分片 `:file.pwrite` 回写 `j*shard_len`（整列缺失先 `ensure_part_file!` 补到 shard_file_size）+ 重写该盘 sidecar；坏分片 >M（存活<K）→ `{:error, :unrecoverable}` + 结构化 error 日志，**绝不伪造数据**）；`scrub_bucket/2`（扫描桶内对象去重逐个 heal）/`scrub_all/1`（全盘所有桶）。`mix maxio.heal` / `mix maxio.scrub` CLI（结构化日志 bucket/key/drive/block/result，铁律 4 可观测）。bitrot e2e（`test/maxio/storage/erasure/bitrot_e2e_test.exs`）：删/篡改 ≤M 分片 GET 仍返回正确字节 + heal 回写；删 M+1 → GET 经惰性流在 `restore_block` raise `InsufficientShardsError`（绝不静默返回错数据）。**架构级修正**（M6-5）：heal 的重编码须与 PUT 的 `write_block` 完全一致——先把 `restore_block` 截断后的明文重新零填充到 `block_size` 再 `split_block`，否则末块（明文 < block_size）会重编码出更短 shard_len、`pwrite` 写入错长分片破坏块布局。

### M6 已知非阻塞项 / M7 显式 defer（文档化，绝不静默丢弃）

1. **真正多节点分布**：分片 I/O 跨主机（RPC 替本地 `:file`）。M6 的「N 盘 = N 本地目录」与分布式 erasure set 的 RS 数学**完全相同**，M7 只替换分片访问 transport，不重写 encode/decode/heal 引擎。
2. **多 erasure set + 对象→set 路由**（对象名 hash）；**server pools** + pool 路由；扩容 / rebalance。
3. **跨节点读写 quorum**（含网络分区下 `K==M` 即 `M==N/2` 的 K+1 脑裂规则——M6 单机已实现并强制 quorum 返回值，分区语义 defer）。
4. **分布式锁**（跨节点对象级锁，保证并发 PUT/heal 安全）。
5. **拓扑感知路由 / 跨节点 heal 协调 / heal 限流 / failure-domain 感知分片放置**；MinIO 式 1/1024 scrub 采样（M6 全扫，单机量可控）。
6. **存储类多 parity**（`x-amz-storage-class` → STANDARD/RRS 不同 EC:M）：M6 单一 (K,M) 配置。
7. **inline 小对象**（< 128 KiB 直接进 sidecar 省 part 文件）：M6 所有对象都写 part 文件。
8. **heal MVP 简化**：同步、单进程、无并发锁（单机串行）；heal 粒度到整对象（非 MinIO per-block 增量回写优化，正确优先）。

**设计保证**：M7 在 M6 同一 RS 编解码 / heal 核心**之外**加 routing/locking/pools/transport 层，不重写引擎（铁律 3，无静默缺口；deferral 在 STATUS + README 逐条显式列出）。

## M7 实现摘要（多节点分布式纠删码 · libcluster + :erpc transport + 分布式锁 · 串行 executor M7-1…M7-5）

- **`compile --warnings-as-errors` 零警告、全量 `mix test` 绿**（M6 基线 + M7 新增 cluster/topology/router/paths/transport/shard_server/lock/distributed/heal/cluster-e2e 全套）。计划：`plans/2026-06-09-m7-distributed.md`。核心请求管线 / handler / dispatcher / endpoint **一行不改**（铁律 2）：M7 仅新增一个 `Maxio.Storage.Backend` 实现 `Maxio.Storage.Distributed`，经 `config :maxio, :storage_backend, Maxio.Storage.Distributed` 切换即启用；唯一接线 = `mix.exs` 加 `{:libcluster, "~> 3.5"}` + 监督树前置 `Cluster.Supervisor`（条件）/`Topology`/`ShardServer` + config 新增 `Maxio.Cluster`/`Maxio.Cluster.Topology` 两块。M6 的 `Maxio.Storage.Erasure.*` + NIF 一行不改（仅被复用）。
- **M7-1 libcluster + 成员门面 + 监督树接线**：`mix.exs` 加 `{:libcluster, "~> 3.5"}`；`Maxio.Cluster`（`nodes/0`/`this_node/0`/`alive?/1` 只读 mesh，单节点退化 `[Node.self()]`，与多节点 prod 同一代码路径）；`Maxio.Application` 前置 `cluster_children/0`（仅非空 topologies 才起 `Cluster.Supervisor`，命名 `Maxio.Cluster.ClusterSupervisor`）；config：dev gossip（UDP 多播自发现）/ prod epmd（`MAXIO_PEERS` 逗号分隔静态组网）/ test 空拓扑。
- **M7-2 Topology + Router + Paths（纯函数 TDD）**：`Maxio.Cluster.Topology`（解析+校验 pools→sets→有序 N 个 `{node,drive}` 端点，索引 i = 分片 i；校验 `K>0`/`M>=1`/`M<=N/2`/每 set endpoints 数 `==K+M`/set id 不重复/至少一 set，违反 `raise ArgumentError`，绝不带病启动；存 `:persistent_term`；`parse_and_validate!/1` 供 test 注入 parsed struct，`*_from/*` 纯函数）；`Maxio.Cluster.Router.set_for/2,3`（`phash2(bucket<>"/"<>key) mod 全局 set 数`，确定性 + 版本不入哈希，对齐 MinIO set 放置）；`Maxio.Cluster.Paths`（`object_rel/3`/`part_rel/3`/`upload_rel/2` 从 ErasureCoded 提取的共享「盘内相对路径」，单一事实来源，`..`/`.`/空 key 拒绝，`"/"` 分隔跨平台一致）。`Topology` child 始终起（无配置 init `{:ok, :no_topology}` 不崩，门面读时才 raise）；`Maxio.Cluster.drives_for_set/1`。
- **M7-3 ShardServer + Transport behaviour + Erpc/InProcess（TDD via InProcess）**：`Maxio.Cluster.ShardServer`（每节点 named GenServer，对外被 :erpc 寻址到正确节点，对内只操作本机一个 drive 路径，逐字复用 M6 part.0 偏移寻址 `j*shard_len` + per-block BLAKE3 sidecar 读写 + heal pwrite；本机函数 `put_shard/4`/`get_shard/3`/`put_sidecar/2`/`get_sidecar/1`/`stat_shard/1`/`delete_shard/1`/`heal_shard/4`/`ping/0`，首参 `drive_obj_dir` 无 node）；`Maxio.Cluster.Transport` behaviour（7 callback 首参 `node()` + `impl/1` 选实现，缺省 `config :maxio, :shard_transport` = `Erpc`）；`Transport.Erpc`（prod，本地直调跳 :erpc 省序列化，远端 :erpc 超时 5s，宕机/超时/远端异常统一 `catch :error/:exit/:throw` 兜底 `on_fail`：get→nil、put→`{:error,:unavailable}`，绝不上抛炸后端）；`Transport.InProcess`（test，全局 ETS `:maxio_inproc_down` + `set_down/1`/`set_up/1` 注入端点宕机，委托 `ShardServer` 真实 IO）。**架构级修正（M7-3 prior executor）**：Erpc.call 去掉 `rescue`（已被 `catch :error` 覆盖，否则 `--warnings-as-errors` 报「catch 子句不可达」），统一 `catch :error/:exit/:throw -> on_fail`。
- **M7-4 Distributed 后端 + Lock + 共享 conformance + quorum/宕机/bitrot 单测**：`Maxio.Storage.Distributed`（实现 `Maxio.Storage.Backend` 全 callback，末参 `opts \\ []`；`opts[:topology]` 覆盖 `:persistent_term`、`opts[:transport]` 覆盖 config；复用 M6 `Codec.split_block/2`/`restore_block/5`/`Config.load!/1`/`Config.total/1` verbatim，只把「分片 i 写本地盘 i」换成「分片 i 经 transport 写端点 i」）：PUT 逐块流式编码、分片 i 经 `Task.async_stream` 并行写端点 i（铁律 4 一条消息一个分片）、sidecar 写全 N 端点、成功端点数 `>= write_quorum` 才 `{:ok}` 否则 `{:error,:write_quorum}`+结构化日志，`Lock.with_lock` 守护；GET 逐块跨节点并行读 K-of-N（宕机端点→nil）、按 sidecar BLAKE3 校验 + `restore_block` 重建（存活 `<K` raise `InsufficientShardsError`）+ Range 裁剪 + 流式发出；stat/delete/bucket-ops/parts/version_id 全跨 set。`Maxio.Cluster.Lock`（`with_lock/2,3` = `:global.trans` 全 mesh 互斥，retries 默认 5，获锁失败 `{:error,:locked}`；`quorum_with_lock/2,3` = dsync 式多数 `div(n,2)+1` 获锁骨架）。共享 `StorageConformance` 第三次同跑 `Distributed`+`InProcess` 证同一契约。**架构级修正（M7-4 prior executor）**：`Lock.erpc_bool` 同 M7-3 去 rescue 统一 catch；`do_get/do_stat/do_delete` 用显式 `case Paths.object_rel/3` 映射 `:invalid_key`（与 do_put 一致）。
- **M7-5 跨节点 heal + CLI + 集群 e2e + 文档**：`Maxio.Cluster.Heal.heal_object/4`（经 `Transport` 逐块跨端点读 + BLAKE3 重算比对 → 坏分片 `<=M` 用 `Codec.restore_block` 重建明文 → 重填充到 block_size → `Codec.split_block` 重编码 → 仅坏端点经 `transport.heal_shard` 回写 + 修 sidecar；坏分片 `>M`（存活 `<K`）→ `{:error,:unrecoverable}` + 结构化 error 日志，**绝不伪造数据**；无任何 sidecar → `{:error,:enoent}`；结构化日志含 bucket/key/block/repaired_endpoints，铁律 3/4）；`scrub_bucket/2` 对象来源经 `opts[:objects]` 显式列表（自动跨节点 walk defer，见下）。`mix maxio.heal.cluster <bucket> <key> [version_id]` CLI（镜像 `maxio.heal`，结构化打印）。集群 e2e：`test/maxio/cluster/cluster_e2e_test.exs`（**InProcess 确定性主力**，3 node×2 drive=N=6，K=4 M=2 → 四场景：write_quorum=4 下宕 1 节点仍写 / read_quorum=4 下宕 1 节点仍读 / 节点返回后 heal 重建 / 宕 2 节点 quorum-loss → `InsufficientShardsError` raise）；`test/maxio/cluster/peer_cluster_test.exs`（`@moduletag :distributed`，起真 `:peer` 节点跑真 `Transport.Erpc`，杀 1 peer → 真 `:erpc :noconnection` → nil → RS 重建仍正确；本机 epmd/`:peer` 不可用时 setup 探测失败即 skip，主回归不受影响——本机实测可用且绿）。`test/test_helper.exs` 加 `ExUnit.configure(exclude: [:distributed])`（默认排除 :peer，单独 `mix test --include distributed` 跑）。

命名契约（M7 全程复用）：`Maxio.Cluster.{nodes/0,this_node/0,alive?/1,drives_for_set/1}`；`Maxio.Cluster.Topology.{parse_and_validate!/1,all_set_ids/0,endpoints/1,ec_params/0,local_drives_for_set/1,all_set_ids_from/1,endpoints_from/2,ec_params_from/1,local_drives_from/3}`（`@pt_key {Maxio.Cluster.Topology,:topology}`）；`Maxio.Cluster.Router.set_for/3`；`Maxio.Cluster.Paths.{object_rel/3,part_rel/3,upload_rel/2}`；`Maxio.Cluster.Transport`（7 callback 首参 `node()` + `impl/1`）/`Transport.Erpc`/`Transport.InProcess`（`setup!/0`/`set_down/1`/`set_up/1`，ETS `:maxio_inproc_down`，含 `set_down` 的测试须 `async: false`）；`Maxio.Cluster.ShardServer`（8 本机函数）；`Maxio.Cluster.Lock.{with_lock/2,3,quorum_with_lock/2,3}`（resource = `{bucket,key}`）；`Maxio.Storage.Distributed`；`Maxio.Cluster.Heal.{heal_object/4,scrub_bucket/2}`。

### M7 已知非阻塞项 / 显式 defer（文档化，绝不静默假装实现）

M7 完成「单 pool、多节点、跨节点 erasure + quorum + 锁 + heal」。以下**显式 defer**（绝不假装实现）：

1. **Rebalance / Decommission / online pool 扩容**：添加 pool / 退役 pool / 跨 pool 迁移既有对象（MinIO `mc admin rebalance`/`decommission`、free-space 加权放置）。M7 单 pool（`pools` 可配多个但路由仅在全局 set 列表取模；**多 pool 的「先选 pool 再选 set」两级路由 + free-space 加权新写 + 迁移** = defer）。set 数 per pool **不可变**（online set 扩缩需重哈希迁移）。
2. **完整 dsync 锁语义**：M7 用 `:global.trans`（MVP，全 mesh 互斥）+ `quorum_with_lock`（dsync 式多数获锁骨架）。**lock lease/refresh keepalive、owner crash 的 refresh-expiry 重置、`ForceUnlock` admin 覆盖、read/write 锁区分（RLock 共享计数）、split-brain after crash+restart 处理** = defer。BEAM 改进（process-monitor 自动释放）= defer。
3. **跨节点 IAM / bucket-metadata / config 复制**：maxio 的 IAM/bucket-meta 走 **Postgres**（M3/M4），多节点共享 DB 即天然一致——**故无需 `.maxio.sys` 对象化复制**（架构差异，非缺口）；但**节点本地 ETS 缓存的跨节点失效通知（PubSub 广播）** = defer（当前每请求读 DB / 缓存策略未跨节点失效广播）。
4. **scanner 全自动跨节点 walk + 1/1024 采样 + 限流**：`Heal.heal_object/4`（单对象跨节点重建）完整；`scrub_bucket` 的**对象列举**当前经 `opts[:objects]` 显式列表（CLI 从 `Maxio.Objects` 元数据取，e2e 用已知 key）。**自动跨节点目录 walk（需 transport `list_dir` callback + 协调节点聚合 peer 列举）+ MinIO 式 hash 采样 + token-bucket 限流 + drive-offline 48h 策略** = defer。
5. **多 parity / storage class**：单一 (K,M)；`x-amz-storage-class` → STANDARD/RRS 不同 EC = defer（沿用 M6）。
6. **parity upgrade on degraded write**：M7 降级写仍按固定 (K,M)，写未达 write_quorum 即 `{:error,:write_quorum}`（绝不静默）；MinIO 的「写时临时提高 effective parity 并在 per-object meta 记录实际布局」= defer。
7. **专用流式分片传输（gRPC/HTTP2 + 连接池 + 背压）**：M7 用 :erpc（OTP 内置，逐 block-shard 有界）。大规模（>~50 节点全 mesh dist 压力）/ 跨数据中心 / mTLS 的专用传输 = defer（`Transport` behaviour 已抽象，换实现不动后端）。
8. **failure-domain 感知的自动 set 形成**：M7 拓扑由 config **手工**指定每 set 的 N 个 `{node,drive}`（运维须保证「N 端点尽量跨节点、每节点端点数 ≤ M」）。MinIO 的 ellipsis 展开 + node-interleaving + GCD set sizing **自动**形成 = defer（手工 config 即可达同等放置，文档化要求）。
9. **沿用 M0–M6 全部既有 defer**（lifecycle 后台执行、SSE 大对象逐帧流式 GET、identity policy、MFA Delete 强制、跨账户多租户、完整条件算子、inline 小对象等）。

**设计保证**：M7 在 M6 同一 RS 核心**之外**加 routing/locking/topology/transport 层，**不重写 encode/decode/heal 引擎**；所有节点宕机/超时/quorum-loss → nil 分片 → EC 重建或结构化 raise，**绝不静默返回错数据**（铁律 3）。

## 工具链与环境（本机 Windows 11，关键教训）

- **Elixir 1.20.0 / Erlang OTP 28** 在 `C:\Users\dyz\Documents\dev\usr\Elixir\bin`；mix / phx_new 1.8.5 / hex 已装；docker / git 可用；**psql 不在 PATH**（用 `docker exec maxio-db psql -U postgres -d maxio_dev -c "..."`）。
- **Postgres**：专用容器 `maxio-db`（postgres:16，端口 5432，卷 `maxio_pgdata`，user/pass=postgres/postgres，db=maxio_dev）。`docker start maxio-db` 恢复。dev.exs 默认连 localhost:5432。
- **坑1（phx.new 崩溃）**：在已存在的非空目录 `mix phx.new .` 会触发交互确认，非 TTY 下读 stdin 失败 → VM 硬崩留 `erl_crash.dump`。解法：生成到全新目录再合并（脚手架已生成，本坑已过）。
- **坑2（Unicode 硬崩）**：mix 输出重定向到非 TTY 时编译期中文/Unicode 输出触发 `io.put_chars badarg` 硬崩。**跑 mix 前必设** `$env:ERL_FLAGS="-kernel standard_io_encoding unicode"`。
- **坑3（ColocatedJS 符号链接）**：Windows 非管理员下 LiveView ColocatedJS 建 node_modules 符号链接失败（:eperm）。已在 `config/config.exs` 设 `config :phoenix_live_view, :colocated_js, disable_symlink_warning: true`。

## 已固化的关键决策

1. **S3 与 Console 双 Endpoint 物理隔离**：S3 走新增独立 `Maxio.S3.Endpoint`（端口 9000，不挂 Plug.Parsers）；Console 走现有 `MaxioWeb.Endpoint`（端口 4000）。理由见 s3_api_layer.md 决策 1（MinIO 本身 API/Console 端口分离）。
2. **动作分发用判定表非 Router**：`Maxio.S3.Dispatcher.resolve(level, method, query_keys)`（S3 是 RPC-over-query，Router 表达不了 `?uploads` vs `?acl`）。
3. **三大后端均 behaviour 抽象**：存储（FS→纠删码→分布式）、凭据（Memory→Ecto）、策略——上层只认 behaviour（铁律 1/2）。
4. **body 流式**：对象字节绝不进 Plug.Parsers/不全缓冲；小 XML 走带上限整读 + saxy。
5. **XML 用 saxy**：出站 builder + 入站 SAX 解析，一依赖两用。
6. **M1 签名范围**：header-based SigV4（单块 + UNSIGNED-PAYLOAD）+ presigned；aws-chunked 流式签名留 M2（aws-cli 默认上传方式，头号兼容风险）。

## 架构评审 + MinIO 保真审计 + 路线 B 决策（2026-06-09，用户质疑「架构是否最优」触发）

用户问「分布式架构是不是最优」。独立对抗式架构评审（4 视角读真实代码 + 对照 MinIO）裁定 **4/10、is_optimal=false**：一致性 4 / 扩展性 4 / MinIO 保真 4 / 运维 3。底层 RS 数据面优秀（quorum 数学与 MinIO 一致、BLAKE3 bitrot、`InsufficientShardsError` 绝不返回错字节），但**根本分歧 = 所有元数据放共享 Postgres（MinIO 是 shared-nothing xl.meta）**，由此：① PG 硬 SPOF + 吞吐天花板闸住 100% S3 操作；② 非原子双写 + DELETE 先删元数据 + GC 只走元数据 → **孤儿分片永久泄漏**；③ 对象锁未覆盖双写接缝 → 并发同 key PUT **静默 ETag/字节不一致**；④ 全程无 fsync（write-quorum 非持久）；⑤ LIST 无 SQL LIMIT（DoS）；⑥ 不可变 mod-N 路由无在线弹性 + 拓扑不校验 distinct-node。

**用户决策**：选**路线 B（元数据 shared-nothing 重构）**——sidecar(meta.json) 升为对象元数据真值源、PG 降为可选派生索引，从构造上消除 SPOF + 双写/孤儿/静默不一致整类问题。7 阶段路线图见 `plans/2026-06-09-routeB-shared-nothing-metadata.md`；P1 详细计划见 `plans/2026-06-09-routeB-phase1-no-regret-fixes.md`。

**同时**：用户要求审查阶段加「MinIO 偏离检查」组——已永久加入 `implement-milestone.js`（Fidelity + Fidelity-Fix 两阶段，对照 AWS 文档 + minio 源码）。一次性回溯审计 M0–M7 查出 **25 偏离（1 critical/7 high/5 medium/12 low）**，计划 `plans/2026-06-09-minio-fidelity-fixes.md`。核心结论：非版本化常规路径高保真，**保真悬崖在 versioning/copy**。用户决策**全修 critical+high+medium（13 项）**，编排 **critical → 路线B P1 → high → medium**。

### ✅ 保真修复批次1（CRITICAL）已交付（2026-06-09，commit `c07a6b4`）

**FX-C1 DeleteObjects 版本化静默数据丢失修复**：原 DeleteObjects 丢弃每对象 VersionId、硬删所有版本历史。修为镜像单对象 `Object.delete` 语义——给定 VersionId 删该版本、Enabled 桶无 VersionId 插 delete marker（绝不硬删历史）、Unversioned 仍硬删；DeleteResult 按 AWS 回显 VersionId/DeleteMarker；per-key 失败降级为结构化 `<Error>`（不整批 500）。**513 测试全绿**（+3 版本化回归，活体证明旧版本批删后仍可经 ?versionId 取回原始字节）、零警告、独立 verify GREEN + reviewer **APPROVE / 0 must-fix** + Fidelity 复检。

### 当前编排队列（critical→P1→high→medium）

```
✅ 批次1 critical（DeleteObjects 数据丢失）— c07a6b4（513 测试）
✅ 路线 B P1（B1-1..B1-4 无悔架构修正）— 8b41b59..b5d2928（557 测试，APPROVE_WITH_NOTES）
     B1-1 锁横跨接缝（消除静默 ETag/字节不一致，Maxio.Lock+SlowDown 503）/ B1-2 原子 temp-rename+fsync（crash 无撕裂+telemetry 断言+quorum 回滚，Windows rename-busy DI 测试）/ B1-3 distinct-node 校验+LIST 硬限（含静默欠截断修复）/ B1-4 sidecar v2 schema+reverse-GC 诚实脚手架
▶  批次2 七个 high 保真偏离（CopyObject 版本化×2 / SigV4 +号 raw-query / PutBucketPolicy ARN 校验 / CORS Allow-Credentials / DeleteObjects 对象级授权 / CopyObject 授权回归锁）← 下一步
   批次3 五个 medium（host 强制签名 / encoding-type=url ×2 / COPY 元数据保留 / 未支持条件算子拒绝）
   评估路线 B P2–P7（sidecar 权威翻转：读→列→写）
```

**P1 遗留（已排入后续，非阻塞）**：CopyObject/CompleteMPU 的 `put_metadata` 硬编码 `version_id:null`（= 批次2 FX-H1/H2 + 路线 B P4 范畴）；max-keys 未夹到 1000（小项）；锁竞争 503 用 Code `SlowDown` 而 MinIO 用 `RequestTimeout`（状态 503 已对，仅 Code 字符串，小项）。LIST 静默欠截断已在 `b5d2928` 当场修复。

## 下一步（续作入口）

- **M7 多节点分布式纠删码已完成**（master，2026-06-09）：libcluster + Topology/Router/Paths + 跨节点 Transport（:erpc/InProcess）+ ShardServer + 分布式锁 + `Maxio.Storage.Distributed` 后端 + 跨节点 heal + 集群 e2e（InProcess 四场景 + `:peer` 真节点）。续作运维 parity 见上「M7 已知非阻塞项 / 显式 defer」9 条（rebalance/decommission、完整 dsync 锁语义、跨节点缓存失效通知、scanner 自动跨节点 walk+采样+限流、多 parity/storage-class、degraded-write parity upgrade、专用流式传输、failure-domain 自动 set 形成）。
- 候选下一里程碑：上述 M7 deferral 中优先级最高者（rebalance/decommission + 多 pool 两级路由，或 dsync 锁完整化），或 M0–M6 既有续作硬化（lifecycle 后台 sweeper、SSE 大对象逐帧流式 GET+Range、identity policy 落地、Console 真实浏览器活体取证）。
- **Console 浏览器活体取证（待补）**：M5 经 `Phoenix.LiveViewTest`（412 测试，含跨页 e2e 矩阵）确定性验证；真实浏览器活体取证（Claude-in-Chrome 启动 dev server + 登录走全链路）需先 `mix ecto.setup` + `mix phx.server`（dev S3 端口 9900）+ Chrome，留作后续确认（前端已埋 `window.__maxio` + `[maxio][Console]` 日志钩子）。
- 续作/可选硬化（非阻塞，已分别文档化于各里程碑「已知非阻塞项」）：M5 note#1 CORS/Lifecycle Console 校验对齐 S3、lifecycle 后台 sweeper、SSE 大对象逐帧流式 GET+Range、multipart 版本化逐版本字节、identity policy、MFA Delete 强制。
- M3 续作/可选硬化（非阻塞）：presigned 与 STS 完整化、identity policy（`principal_policies/1` 当前恒 `[]`，M4-1 已修为传真实 principal，接口就绪）、完整条件算子、secret at-rest 加密。
- 每完成一里程碑：独立 reviewer/verifier 取证 + 更新本 STATUS + 提交。
- 已建立的成功模式：研究核验（官方文档/向量）→ opus planner 产出 gold-standard 计划 → 有界串行 executor（每单元强制 StructuredOutput，避免过大）→ 独立 verifier → 有界 fix → 独立 code-reviewer。通用实现 workflow 在 `.omc/workflows/implement-milestone.js`（参数化 milestone/plan_path/baseline/units）。
