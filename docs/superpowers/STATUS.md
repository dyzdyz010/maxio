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
| **M4 高级特性** | versioning / tagging / lifecycle / CORS / CopyObject / SSE | ⬜ 待 |
| **M5 Console** | LiveView 管理台 | ⬜ 待 |
| **M6 纠删码 / 分布式** | Reed-Solomon（Rustler）+ 分布式 + 自愈 | ⬜ 待 |

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

## 下一步（续作入口）

- **M4 高级特性**（下一里程碑）：versioning（版本化 + 版本删除标记）/ object tagging / lifecycle 规则 / CORS 配置 / SSE（服务端加密）。在 M3 授权链路之上扩展（新动作接 `ActionMap` + Authz、新子资源接 Dispatcher、新元数据接 schema 中文 COMMENT）。设计见 `_design_inputs/`。
- M3 续作/可选硬化（非阻塞，已文档化于「M3 已知非阻塞项 / 显式 defer」）：presigned 与 STS 完整化、identity policy（`principal_policies/1` 当前恒 `[]`）、完整条件算子、secret at-rest 加密。
- 每完成一里程碑：独立 reviewer/verifier 取证 + 更新本 STATUS + 提交。
- 已建立的成功模式：研究核验（官方文档/向量）→ opus planner 产出 gold-standard 计划 → 有界串行 executor（每单元强制 StructuredOutput，避免过大）→ 独立 verifier → 有界 fix → 独立 code-reviewer。通用实现 workflow 在 `.omc/workflows/implement-milestone.js`（参数化 milestone/plan_path/baseline/units）。
