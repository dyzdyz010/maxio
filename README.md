# Maxio

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix

## 高级特性（M4）

maxio 在 S3 核心读写（M1）、分段上传/流式签名（M2）、IAM/策略/授权（M3）之上，实现了以下 S3 高级特性子系统。本节同时**诚实标注**每个特性的边界与显式 defer（不会假装「已生效」）。

### Versioning（版本化）

- **三态**（`PutBucketVersioning`/`GetBucketVersioning`，`?versioning`）：`Unversioned`（从未设置，`GetBucketVersioning` 不回 `<Status>`）、`Enabled`、`Suspended`。
- **版本 ID**：ULID（26 字符 Crockford base32，时间有序、URL-safe）；无版本写入用保留串 `null`（既是存储值也是 `x-amz-version-id` 回显值）。
- **对象多版本模型**：`objects` 表每 `(bucket, key, version_id)` 一行。`Enabled` 下 PutObject 生成新 ULID 并置为当前版本；`Suspended`/`Unversioned` 用 `null` 版本就地覆盖。
- **Delete marker**：`Enabled` 下无 `versionId` 的 DELETE 插入删除标记（无字节的特殊版本行）。当前版本为删除标记时 GET/HEAD 返回 `404 + x-amz-delete-marker: true`；`?versionId` 指向删除标记返回 `405 + x-amz-delete-marker: true`。`?versionId` 的 DELETE 永久删除该版本（删除当前版本时自动提升下一个最新版本）。
- **ListObjectVersions**（`?versions`）：Version 与 DeleteMarker 元素交错、按 `key` 升序 + 版本 newest-first、二维分页（`key-marker` + `version-id-marker`）、`delimiter`/`CommonPrefixes`。
- **响应头**：`x-amz-version-id`（仅非 `null` 时）、`x-amz-delete-marker`（仅为真时）。
- **ListObjectsV2** 仍只返回「当前版本且非删除标记」的对象。

### Tagging（标签）

- **对象 / 桶 tagging**（`?tagging` PUT/GET/DELETE，Tagging XML）。
- **PutObject 的 `x-amz-tagging` 头**（query-string 编码）在写对象时一并落到版本行。
- **`x-amz-tagging-count` 响应头**：GET/HEAD 在标签数 > 0 时返回。
- **Limits → `InvalidTag 400`**：对象至多 10 个、桶至多 50 个；键 1..128 字符、值 0..256 字符；不可 `aws:` 前缀；键唯一。
- `?tagging&versionId=` 作用于指定版本行。

### CORS

- **`PutBucketCors`/`GetBucketCors`/`DeleteBucketCors`**（`?cors`）：解析 + 校验（至多 100 规则、方法非空、`AllowedOrigin`/`AllowedHeader` 至多一个 `*`）+ 持久化 + 出站；无配置 → `NoSuchCORSConfiguration 404`。
- **OPTIONS 预检**：在 SigV4 鉴权**之前**命中匹配规则并返回 `200 + CORS 头`（`Access-Control-Allow-Origin/Methods/Headers/Max-Age/Expose-Headers` + `Vary`）并 halt——**预检不签名**。
- **实际请求带 `Origin`**：注册 `before_send` 注入 CORS 响应头（流式安全，不缓冲）。无 `Origin` 的请求完全不受影响。
- **仅作用于 S3 Endpoint**（dev:9900 / prod:9000）；Console Endpoint（:4000）不受 CORS 影响。

### Lifecycle（配置 + CLI / 后台调度）

- **`PutBucketLifecycleConfiguration`/`Get`/`Delete`**（`?lifecycle`）：存储 / 校验 / 出站配置（Filter/And/legacy Prefix、Tag/size filter、Expiration、NoncurrentVersionExpiration、AbortIncompleteMultipartUpload、Transition）；无配置 → `NoSuchLifecycleConfiguration 404`。非法/非正数值、缺 Key/Value 的 Tag filter 会 fail-closed 拒绝，避免删除选择器被静默放宽。
- **执行器**：`mix maxio.lifecycle.run [--bucket name] [--dry-run]` 执行当前版本 `Expiration`（Days/Date）、`NoncurrentVersionExpiration`（按成为非当前的时间 + `NewerNoncurrentVersions` 保留数永久删除）、`ExpiredObjectDeleteMarker` 清理、`AbortIncompleteMultipartUpload`。未知 CLI 参数或对象级 partial error 会失败退出。
- **后台调度器**：`Maxio.Lifecycle.Scheduler` 默认启动但不调度；配置 `config :maxio, :lifecycle_scheduler, enabled: true` 后按 `interval_ms` 周期调用同一个 `Maxio.Lifecycle.run/1`。`Transition` / `NoncurrentVersionTransition` 仍仅持久化与回放，runner 计为 unsupported no-op。

### IAM identity policies（续作已支持）

- **Principal 内联策略**：`principal_policies/1` 不再恒空；`principal_policies` 表按 `principal_arn + policy_name` 存储 identity-based policy，并与 bucket policy / ACL 一起交给同一个 Evaluator。显式 Deny 仍优先于任意 Allow。
- **Principal 语义**：identity policy 绑定在 principal 上，JSON 内不允许 `Principal`；绑定关系隐式提供当前 principal。bucket policy 仍要求显式 `Principal`。
- **CLI**：`mix maxio.iam.put_policy --principal ARN --name NAME --file policy.json`、`mix maxio.iam.list_policies --principal ARN`、`mix maxio.iam.delete_policy --principal ARN --name NAME`。

### IAM condition operators（续作已支持）

- **基础算子与集合限定符真实求值**：`String*` / `Arn*` / `Date*` / `Numeric*` 正反向比较、`Bool`、IPv4/IPv6 `IpAddress`/`NotIpAddress`、`Null`、`*IfExists`、`ForAnyValue:` / `ForAllValues:` 已在 bucket policy 与 identity policy 的 Condition 求值器中实现；真实 S3 请求上下文已抽取 `aws:SecureTransport`、`aws:SourceIp`、`aws:CurrentTime`、`aws:PrincipalArn`、`s3:prefix`、`s3:delimiter`、`s3:max-keys`、常用 `s3:x-amz-*` header，以及 `aws:PrincipalTag/*` / `s3:BucketTag/*` / `aws:ResourceTag/*` / `s3:ExistingObjectTag/*` / `s3:RequestObjectTag*` / `aws:RequestTag/*` / `aws:TagKeys` 等 tag 条件键。`PutObjectTagging` 的 XML body request tags 会在 handler bounded read + XML/tag 校验后、写入前做二阶段授权。
- **缺失键语义**：正向算子缺键为 false；否定算子缺键为 true；`*IfExists` 缺键为 true；`ForAnyValue:` 缺键/空请求值为 false，`ForAllValues:` 缺键/空请求值按 AWS 语义为 true；`Null` 做存在性/null dataset 判断，可用于阻断空字符串等空值。无法解析的值 fail-closed，不命中 statement。
- **ListBucket 数值条件**：授权上下文会传入 `s3:max-keys`，可用 `NumericLessThanEquals` 等条件限制单次列举数量。
- **仍 defer**：跨账户与更广泛 AWS 全局上下文键。

### IAM policy variables（续作已支持）

- **变量展开范围**：`Version: "2012-10-17"` 的 policy 会在 `Resource` / `NotResource` 以及 String/Arn 系 Condition policy value 中展开 `${context-key}`；缺省或 legacy `Version` 下 `${...}` 按字面量处理。支持默认值语法 `${key, 'default'}` 与字面量转义 `${*}` / `${?}` / `${$}`。
- **principal 上下文**：真实授权上下文已补齐 `aws:PrincipalType`、`aws:userid`、IAM user 的 `aws:username`。当前单租户实现中 `aws:userid` 使用 maxio access-key，`aws:username` 从本项目 IAM user ARN 尾段派生；可用于 identity policy 中按 access-key principal 隔离对象前缀，例如 `arn:aws:s3:::bucket/home/${aws:username}/*`。
- **fail-closed 边界**：变量只接受单值标量上下文；缺失、空值或多值变量若无默认值则不匹配。`NotResource` 中任何未解析变量都会使该 resource selector 不命中，避免反向匹配被变量缺失放大。

### IAM negated selectors（续作已支持）

- **`NotAction` / `NotResource`**：policy statement 支持 `Action`/`NotAction`、`Resource`/`NotResource` 二选一 selector；评估时按 AWS IAM 语义匹配“除列出项之外”的 action 或 resource，显式 Deny 仍优先。
- **`NotPrincipal`**：bucket policy 支持 resource-based `Deny` statement 中的 `NotPrincipal`；identity policy 继续拒绝 `Principal` / `NotPrincipal`，因为绑定关系隐式提供 principal。
- **边界**：`NotResource` 在 bucket policy 写入时仍按目标 bucket 做 ARN 作用域校验，防止 bucket policy 静默声明其它 bucket 的资源；跨账户 principal、Service/CanonicalUser 细粒度语义仍属后续扩展。

### ACL explicit grants（续作已支持）

- **显式 grant 持久化与授权**：`x-amz-grant-read/write/read-acp/write-acp/full-control` 以及 PutBucketAcl/PutObjectAcl 的 ACL XML 会写入 `acl_grants` jsonb 文档，并与 `acl_canned` 一起经 `Maxio.Policy.ACL` 折叠成同一个 Evaluator statement 列表。
- **支持 grantee**：Group URI 支持 AllUsers / AuthenticatedUsers / LogDelivery（LogDelivery 当前不产生可匹配 principal）；CanonicalUser 以 maxio principal ARN 精确匹配；email grantee 继续 `InvalidArgument 400`。
- **sidecar 保真**：对象显式 grants 会随 maxio/2 sidecar 写入并参与 scanner reconcile / shadow 比对；CopyObject 默认仍按 AWS 语义重置为 private，显式 `x-amz-acl` 或 `x-amz-grant-*` 才应用到目标。

### PublicAccessBlock（续作已支持）

- **API**：`Put/Get/DeletePublicAccessBlock`（`?publicAccessBlock`）支持 bucket-level `BlockPublicAcls` / `IgnorePublicAcls` / `BlockPublicPolicy` / `RestrictPublicBuckets` 四布尔项；无配置的 GET 返回 `NoSuchPublicAccessBlockConfiguration 404`。
- **ACL 防护**：`BlockPublicAcls=true` 时，PutBucketAcl、PutObjectAcl、PutObject、CopyObject、CreateMultipartUpload 携带公共 canned ACL 或 AllUsers / AuthenticatedUsers grant 会在写入前 `AccessDenied 403`，不落对象、ACL 或 MPU 会话副作用。
- **有效权限**：`IgnorePublicAcls=true` 不删除既有 ACL，但授权时忽略公共 ACL 派生 statement；GetBucketAcl/GetObjectAcl 返回有效权限视图，不回显被忽略的公共 grant。
- **Policy 防护**：`BlockPublicPolicy=true` 在 PutBucketPolicy 写入前拒绝公共 bucket policy 并保留既有 policy；`RestrictPublicBuckets=true` 对已存在公共 bucket policy 在授权聚合阶段抑制公共 Allow。
- **边界**：当前仅实现 bucket-level 设置；AWS account / organization / access point 级叠加、跨账户精细限制、Service principal 例外仍随多租户/IAM 扩展后续实现。

### SSE-S3（服务端加密）

- **真实 AES-256-GCM 信封加密**：PutObject 带 `x-amz-server-side-encryption: AES256`（或桶默认加密配置）时，对象字节**真实加密落盘**——每对象生成随机 256-bit 数据密钥（DEK），数据重切为 64KB 帧、每帧独立 AES-256-GCM（随机 IV + 认证 tag），DEK 由服务端主密钥 AES-256-GCM 包裹后随对象元数据存储。GET 透明解密；GCM 认证失败会**抛错**，绝不静默返回错数据。
- **`PutBucketEncryption`/`Get`/`Delete`**（`?encryption`）配置桶默认加密；无配置 → `ServerSideEncryptionConfigurationNotFoundError 404`。
- **密钥管理简化**：单一静态服务端主密钥（`config :maxio, :sse, master_key`，dev/test 固定值，prod 经环境变量）——**无密钥轮转、无 HSM、无 KMS**。
- **仅 SSE-S3（AES256）**：`aws:kms`/`aws:kms:dsse` 的 `SSEAlgorithm` 或 `x-amz-server-side-encryption-customer-*`（SSE-C）头 → `501 NotImplemented`（绝不静默当 AES256）。`BucketKeyEnabled` 接受持久化但 no-op（KMS 专属）。
- **Range / 大对象**：MVP 对加密对象的 Range 请求降级为返回完整对象（`200`，绝不返回错误字节）；GET 整对象解密后 `send_resp`（大对象逐帧流式解密留后续优化）。SSE 对象的 ETag 是密文 MD5（与 AWS SSE-S3 一致，非明文 MD5）。

### M4 显式 defer 清单（汇总；文档化，绝不静默）

1. **Lifecycle Transition / NoncurrentVersionTransition 执行**：当前版本过期、非当前版本过期、仅存 delete marker 清理、旧 MPU 中止可由 `mix maxio.lifecycle.run` 或 `config :maxio, :lifecycle_scheduler, enabled: true` 后台周期执行；Transition / NoncurrentVersionTransition 仍 no-op 并显式暴露。
2. **MFA Delete**：`MfaDelete` 状态解析/存储/回显（仅曾配置时回 `<MfaDelete>`），但不强制 MFA 校验（无设备），`x-amz-mfa` 头不验证。
3. **SSE-C / SSE-KMS / DSSE-KMS**：仅 SSE-S3（AES256）；其余 → `501 NotImplemented`。`BucketKeyEnabled` no-op。
4. **SSE 密钥管理简化**：单一静态主密钥，无轮转/HSM/KMS。
5. **SSE 对象 + Range / 大对象逐帧流式解密**：Range 降级为完整对象；整对象解密后返回。
6. **Multipart 完成对象版本化（2026-06-12 已收敛）**：CompleteMultipartUpload 在 Enabled 桶生成独立 ULID `version_id`，字节、sidecar、PG/索引与 `x-amz-version-id` 响应头使用同一版本；Suspended/Unversioned 仍写 `null` 版本。
7. **对象级逐版本独立 tag set**：tag 挂在版本行（`?tagging&versionId` 已支持指定版本）；`s3:*VersionTagging` 按同名非 version 权限评估（单租户）。
8. **lifecycle `Transition` / `NoncurrentVersionTransition` 执行**：仅存储/校验/回放；runner 计 unsupported，不做静默转储。
9. **沿用 M3 剩余 defer**：跨账户/多租户、更广泛 AWS 全局上下文键、STS/session token、email grantee、checksum trailer 重算、secret at-rest 加密。

## Console（M5，LiveView 管理控制台）

maxio 内置 MinIO Console 式的 Web 管理台，跑在 `MaxioWeb.Endpoint`（默认 :4000），
**物理隔离于 S3 Endpoint**（:9900 dev / :9000 prod）。Console **直接调用 maxio context**
（同进程，不经 S3 HTTP API；唯一例外是预签名分享 URL——按定义指向 S3 Endpoint）。

### 登录

访问 `http://localhost:4000/login`，用 **access key + secret key** 登录
（复用 S3 数据面同一套 `Maxio.Auth.CredentialStore` 凭据，常数时间比对，绝不泄露 ak/sk 谁错；
dev 默认 root = `minioadmin` / `minioadmin`）。登录成功只把 access_key 落进签名 session（secret 绝不入 session），
LiveView mount 时凭 access_key 重查 principal。鉴权经 `live_session` 的 `on_mount`
`:require_authenticated` 钩子门控所有受保护页（未登录全程 redirect `/login`）。

### 功能（M5 已实现）

- **Dashboard**：桶数 / 对象数（当前版本，非 delete marker）/ 总用量 / per-bucket 大小 / access key 数 / 进行中分段上传（廉价 `Repo.aggregate` 聚合，无 Prometheus）。
- **Buckets**：列表（streams）/ 创建（S3 名校验）/ 删除（非空守卫；所有错误显式 flash）。
- **Object Browser**：prefix/folder 面包屑导航（`list_objects_v2` delimiter）/ 上传（`allow_upload` 流式 `File.stream!` 喂 `Storage.put`，≤5 GiB 单 PUT 路径，绝不全缓冲）/ 下载（plain controller `send_chunked` 流式）/ 新建文件夹（零字节 `prefix/` 对象）/ 删除（版本化感知：Enabled 插 delete marker，否则永久删）。
- **Object Detail**：元数据（size/etag/content-type/storage-class/version_id/修改时间）/ 标签编辑（`Tags.validate`，`:invalid_tag` 显式 flash）/ 版本历史（`list_object_versions`，含 delete marker badge，per-version 流式下载/永久删除）。
- **Bucket Settings**（8 tab，`?tab=` 切换）：版本化（`put_versioning`）/ 桶策略 JSON（`Statement.parse_policy` 校验）/ canned ACL（`put_acl`）/ 桶标签（`Tags.validate`）/ CORS（复用 S3 `PutBucketCors` 语义校验）/ 生命周期（复用 S3 `PutBucketLifecycle` 语义校验，提示可用 CLI 或 lifecycle scheduler 执行支持动作）/ 默认加密（SSE-S3 AES256；SSE-KMS 绝不静默当 AES256）/ PublicAccessBlock（四布尔项 bucket-level 设置）。
- **Access Keys**：列表（绝不回 secret）/ 创建（secret 仅在创建响应里显示一次，不入 stream/session）/ 删除（保护最后一个 root：`:cannot_delete_last_root` 显式 flash）。

前端可调试钩子：app.js 暴露 `window.__maxio = {liveSocket, log, version: "M5"}`，所有 Console 日志带标签 `[maxio][Console]`。

### 显式未实现（defer，绝不假装实现 / 不画死按钮）

- **Identity → Users / Groups / STS / IdP**：maxio 单租户，无独立 user/group 实体；IAM identity policy 已支持 CLI 绑定到 access-key principal，但 Console 暂未提供 UI。Console 用 **access key** 作 identity primitive；Users/Groups 在侧边栏**不出现**（不画灰条目假装有）。
- **Bucket → Quota / Events-Notifications / Replication / Object-Lock-Retention-Legal-Hold**：后端未实现，Settings 页不画这些 tab。PublicAccessBlock 后端与 Settings tab 已接入；account / organization / access point 级叠加仍随多租户/IAM 扩展 defer。
- **Object → 内联预览 / Legal hold / Retention**：后端未实现 / SSE 对象 GET 全缓冲（M4 defer）使大加密对象预览有风险——仅提供下载。
- **Monitoring → Logs/Trace/Audit 流 / Drives/Heal / 流量·API速率·延迟 时序图**：需 Prometheus/纠删码（M6）。Dashboard 只做廉价计数，不画时序图。
- **Configuration / Settings 运行时编辑 / Tiers / Site Replication / Batch Jobs / License**：后端无运行时配置存储；不做。
- **Console 大文件多段上传**：MVP 走单 PUT（≤5 GiB，服务端临时文件中转）；接 `Maxio.Multipart` 逐 part 上传标为后续优化。
- **Lifecycle Transition / NoncurrentVersionTransition**：Console 可编辑规则，支持 `mix maxio.lifecycle.run` 或后台 scheduler 执行已支持动作；Transition、NoncurrentVersionTransition 仍 defer。
- **预签名分享 URL**：可经 `Maxio.Auth.SigV4.Signer` 生成指向 S3 端的预签名 GET（唯一引用 S3 HTTP 之处），MVP 未做 UI（不画死按钮）。

## Erasure Coding（M6，单机多盘 Reed-Solomon 纠删码）

maxio 在 FS 后端之上新增一个 **MinIO 式纠删码存储后端** `Maxio.Storage.ErasureCoded`，把对象字节以
**Reed-Solomon (N = K + M)** 编码分散到 **N 个本地盘目录（单机多盘 = 一个 erasure set）**，提供
per-shard BLAKE3 bitrot 检测、decode-on-read 容错与自愈/scrub。它实现与 `Maxio.Storage.FS`
**完全相同**的 `Maxio.Storage.Backend` 契约（put/get/stat/delete + bucket ops + multipart parts +
version_id 维度 + 流式 + ETag/sha256 返回形态逐字节一致），**核心请求管线 / handler / dispatcher /
endpoint 一行不改**（铁律 2：后端即插件）。底层经 Rustler NIF（`native/maxio_native`，镜像姊妹项目
huanxi 的 `h3o` 模式）封装 `reed-solomon-simd`（GF(2^16) SIMD、纯 Rust）+ `blake3`。

### 启用方式（config 切后端）

```elixir
# 1) 把存储后端从 FS 切到纠删码（缺省仍是 Maxio.Storage.FS）
config :maxio, :storage_backend, Maxio.Storage.ErasureCoded

# 2) 配置 erasure set（N 个本地目录 = K + M，block_size 为流式块大小）
config :maxio, :erasure,
  drives: ["/data/d0", "/data/d1", "/data/d2", "/data/d3", "/data/d4", "/data/d5"],
  data_shards: 4,        # K
  parity_shards: 2,      # M（N = K + M = length(drives)）
  block_size: 1_048_576  # 1 MiB 逻辑块
```

启动期 `Maxio.Storage.Erasure.Config.load!/1` 校验 `length(drives) == K + M`、`M >= 1`、
`M <= N/2`（parity 至多半数），非法配置 **raise**（绝不带病启动）。

### EC:M 记法与 quorum

- 记法 **EC:M**（如 `EC:2` = M=2 校验分片）；对象在 N 个盘各落一个分片（前 K 个 systematic 数据分片、后 M 个校验分片）。
- **read quorum = K**：任意 K 个存活分片即可重建整对象（可容忍最多 M 个盘缺失/损坏）。
- **write quorum = K**（一般情形）；当 **K == M（即 M == N/2，脑裂边界）时 write quorum = K + 1**——单机已实现并强制此 quorum 返回值（跨节点分区语义 defer M7）。写入成功盘数 < write quorum → `{:error, :write_quorum}` + 结构化日志（绝不静默落盘）。

### Bitrot 检测 + 自愈（heal / scrub）

- **per-shard BLAKE3-256 校验和** 随对象元数据存进每盘的 `meta.json` sidecar（`shards[i].block_hashes[j]` = 盘 i 在 block j 的分片校验和）。
- **decode-on-read**：GET 逐块 `pread` 各盘分片、重算 BLAKE3 与 sidecar 比对，**不匹配/缺失的分片显式置 nil**（RS 只纠已知 erasure、不定位 silent corruption，故必须先校验再重建——绝不把「在场但损坏」的分片喂解码器）；存活 ≥ K 重建并返回正确字节；存活 < K → raise `InsufficientShardsError`（**绝不静默返回错数据**，铁律 3）。
- **heal**：从 K 个存活分片 RS 重建坏分片字节，`:file.pwrite` 精确回写坏 block 偏移（整列分片文件缺失时先补齐再回写）+ 修复该盘 sidecar 副本；某 block 存活 < K → **unrecoverable**（返回 `{:error, :unrecoverable}` + 结构化 error 日志，**绝不伪造数据**）。
- **CLI**（铁律 4 可观测，结构化日志含 bucket/key/drive/block/result）：

```bash
mix maxio.heal <bucket> <key> [version_id]   # heal 单个对象（version_id 缺省 "null"）
mix maxio.heal <bucket>                       # scrub 整桶（逐对象 heal）
mix maxio.scrub                               # 全盘巡检：所有桶全部对象逐个 heal
mix maxio.scrub <bucket>                      # 仅扫描指定桶
```

### 流式保证（铁律 4：body 绝不进内存）

PUT 把上传字节流重切成固定 `block_size` 逻辑块，逐块 RS 编码后分片 i 追加到盘 i（手写有界块缓冲，
绝不缓冲整对象）；GET 用 `Stream.resource/3` 逐块读 K 个存活分片、校验、重建、流式发出。任意时刻内存
≈ 一个 block × N 分片。NIF 按块调用（每次有界、快速，绝不长跑卡调度器）。

### M6 显式 defer 清单（M7，文档化，绝不静默丢弃）

1. **真正多节点分布**：分片 I/O 跨主机（RPC 替本地 `:file`）。M6 的「N 盘 = N 本地目录」与分布式 erasure set 的 RS 数学**完全相同**，M7 只换分片访问 transport，不重写 encode/decode/heal 引擎。
2. **多 erasure set + 对象→set 路由**（对象名 hash）；**server pools** + pool 路由；扩容 / rebalance。
3. **跨节点读写 quorum**（含网络分区下 `K==M` 的 K+1 脑裂规则——M6 单机已实现并强制 quorum 返回值，分区语义 defer）。
4. **分布式锁**（跨节点对象级锁，保证并发 PUT/heal 安全）。
5. **拓扑感知路由 / 跨节点 heal 协调 / heal 限流 / failure-domain 感知分片放置**；MinIO 式 1/1024 scrub 采样（M6 全扫，单机量可控）。
6. **存储类多 parity**（`x-amz-storage-class` → STANDARD/RRS 不同 EC:M）：M6 单一 (K, M) 配置。
7. **inline 小对象**（< 128 KiB 直接进 sidecar 省 part 文件）：M6 所有对象都写 part 文件。
8. **heal MVP 简化**：同步、单进程、无并发锁（单机串行）；heal 粒度到整对象（非 MinIO per-block 增量回写优化，正确优先）。

**设计保证**：M7 在 M6 同一 RS 编解码 / heal 核心**之外**加 routing/locking/pools/transport 层，不重写引擎。

## 多节点分布式纠删码（M7，跨节点 erasure + quorum + 分布式锁 + 跨节点 heal）

maxio 在 M6 单机纠删码核心之上新增 **MinIO 式多节点分布式存储后端** `Maxio.Storage.Distributed`，
把对象字节以 **Reed-Solomon (N = K + M)** 编码分散到**跨多个节点的 N 个 `{node, drive}` 端点
（一个 erasure set 跨节点）**。它实现与 `Maxio.Storage.FS`/`Maxio.Storage.ErasureCoded`
**完全相同**的 `Maxio.Storage.Backend` 契约（ETag/sha256/Range/part ETag 返回形态逐字节一致），
**核心请求管线 / handler / dispatcher / endpoint 一行不改**（铁律 2：后端即插件）。M6 的 RS 数学、
流式结构、quorum 公式、heal 引擎**全部复用、一行不重写**——只把「分片 i → 本地盘 i」替换为
「分片 i → 该对象 erasure set 的第 i 个 `{node, drive}` 端点（经 :erpc/transport 访问）」。

### 启用方式（config 切后端）

```elixir
# 1) 把存储后端切到分布式（缺省仍是 Maxio.Storage.FS）
config :maxio, :storage_backend, Maxio.Storage.Distributed

# 2) 节点发现拓扑（libcluster）：dev gossip / prod epmd（MAXIO_PEERS env 逗号分隔 node 名）
config :maxio, Maxio.Cluster,
  topologies: [
    maxio_gossip: [strategy: Cluster.Strategy.Gossip, config: [port: 45_892]]
  ]

# 3) erasure 部署拓扑：pools → sets → 有序 N 个 {node, drive} 端点（索引 i = 分片 i）
config :maxio, Maxio.Cluster.Topology,
  data_shards: 4,        # K
  parity_shards: 2,      # M（N = K + M = 每 set 的端点数）
  block_size: 1_048_576, # 1 MiB 逻辑块
  pools: [
    %{
      id: 0,
      sets: [
        %{
          id: 0,
          endpoints: [
            {:"maxio@10.0.0.1", "/data/d0"}, {:"maxio@10.0.0.1", "/data/d1"},
            {:"maxio@10.0.0.2", "/data/d0"}, {:"maxio@10.0.0.2", "/data/d1"},
            {:"maxio@10.0.0.3", "/data/d0"}, {:"maxio@10.0.0.3", "/data/d1"}
          ]
        }
      ]
    }
  ]

# 4) 分片传输实现（prod = :erpc；test 覆盖为 InProcess）
config :maxio, :shard_transport, Maxio.Cluster.Transport.Erpc
```

启动期 `Maxio.Cluster.Topology.parse_and_validate!/1` 校验每 set endpoints 数 `== K+M`、
`M >= 1`、`M <= N/2`、set id 不重复、至少一个 set，非法拓扑 **raise**（绝不带病启动）。
运维须保证「N 个端点尽量跨节点、每节点端点数 ≤ M」（failure-domain 自动 set 形成 = defer，见下）。

### dev 单机多节点起法（自发现 + iex）

```bash
# 三个 iex 会话（同一 cookie；gossip UDP 自发现），各起一个具名节点：
iex --sname maxio_a --cookie maxio -S mix
iex --sname maxio_b --cookie maxio -S mix
iex --sname maxio_c --cookie maxio -S mix
# Maxio.Cluster.nodes/0 会汇出三节点；拓扑 config 把端点的 node 写成 :"maxio_a@<host>" 等。
```

### 对象 → erasure set 路由（铁律 5 对齐 MinIO）

- **`Maxio.Cluster.Router.set_for(bucket, key)`** = `phash2(bucket <> "/" <> key) mod 全局 set 数`，
  确定性放置。**版本不入哈希**（同对象全版本同 set，故版本化 GET/PUT 路由一致）。
- set 数 per pool **不可变**（online 扩缩需重哈希迁移 = defer）。

### 跨节点 quorum + 容错（铁律 3）

- **read quorum = K**、**write quorum = K**（一般情形）；**K == M（脑裂边界）时 write quorum = K + 1**。
  以 K=4 M=2（N=6）为例：read_quorum=4、write_quorum=4，可容忍最多 M=2 个端点（≈1 节点 2 drive）缺失。
- **PUT**：逐块 RS 编码，分片 i 经 transport 并行写端点 i（铁律 4：每条 :erpc 消息只载一个 block 的一个分片，
  绝不一次传整对象/整文件）；成功端点数 `>= write_quorum` 才 `{:ok}`，否则 `{:error, :write_quorum}` + 结构化日志。
- **GET**：逐块跨节点并行读 K-of-N 分片（宕机/超时端点经 transport 兜底 → nil），按 sidecar BLAKE3 校验 +
  RS 重建（存活 `< K` → raise `InsufficientShardsError`，**绝不静默返回错数据**）+ Range 裁剪 + 流式发出。
- **并发守护**：PUT/assemble/delete 经 `Maxio.Cluster.Lock.with_lock`（每节点 `LockServer` + quorum lease；
  单节点退化 quorum=1，公共 API 保持不变），获锁失败 → `{:error, :locked}`，
  S3 API 层回 503 `RequestTimeout`（**绝不静默并发写同对象**）。
- **节点宕机/超时/远端异常**：`Transport.Erpc` 统一兜底为 nil 分片（与 M6 缺失本地文件语义完全相同），
  交 RS 重建，绝不把异常上抛炸后端。

### 跨节点 heal（自愈）

- **`Maxio.Cluster.Heal.heal_object(bucket, key, version_id, opts)`**：经 `Transport` 逐块跨端点读 +
  BLAKE3 重算比对 → 检测宕机/被替换节点上缺失的整列分片、被篡改（bitrot）的分片 → 从 K 个存活端点（peer）
  RS 重建坏分片 → 经 `transport.heal_shard` 仅回写坏端点 + 修复其 sidecar 副本；某 block 存活 `< K` →
  `{:error, :unrecoverable}` + 结构化 error 日志（**绝不伪造数据**，铁律 3）；无任何 sidecar → `{:error, :enoent}`。
- **CLI**（铁律 4 可观测，结构化日志含 bucket/key/block/repaired_endpoints）：

```bash
mix maxio.heal.cluster <bucket> <key> [version_id]   # heal 单对象（version_id 缺省 "null"）
```

### 测试覆盖（确定性 InProcess 主力 + :peer 真节点）

- **进程内多节点 transport 注入**（`Maxio.Cluster.Transport.InProcess`，可在运行中 `set_down/1` 打掉端点）：
  在 `async` ExUnit 里跑真实 quorum + 节点宕机 + bitrot + heal，无需第二个 BEAM 节点。共享 `StorageConformance`
  套件第三次同跑 `Distributed`+`InProcess` 证同一契约。集群 e2e 四场景（一节点宕仍写 / 一节点宕仍读 /
  节点返回后 heal / 两节点宕 quorum-loss raise）全绿。
- **`:peer` 真节点集成测试**（`@moduletag :distributed`，默认排除，`mix test --include distributed` 跑）：
  起真实额外 BEAM 节点跑真 `:erpc`，杀节点验真 `:erpc :noconnection` → nil 分片 → RS 重建。
  本机 epmd/`:peer` 不可用时自动 skip（主回归不受影响）。

### M7 显式 defer 清单（文档化，绝不静默假装实现）

1. **Rebalance / Decommission / online pool 扩容**：添加/退役 pool、跨 pool 迁移、free-space 加权放置
   （MinIO `mc admin rebalance`/`decommission`）。M7 单 pool（多 pool 两级路由 + 加权新写 + 迁移 = defer）；
   set 数 per pool 不可变。
2. **完整 dsync 锁语义**：M8-1 已把 `:global.trans` MVP 升级为 `LockServer` + quorum lease，
   支持 acquire/release/refresh/force_unlock、read/write 锁区分、owner-death 与 TTL sweep。
   仍 defer：Raft 线性化锁、fencing token、split-brain 下陈旧写硬拒绝。
3. **跨节点 IAM / bucket-metadata 复制**：maxio 的 IAM/bucket-meta 走 **Postgres**（多节点共享 DB 天然一致，
   故无需 `.maxio.sys` 对象化复制——架构差异，非缺口）；M8-2 已接入 PubSub metadata invalidation spine，
   让节点本地 ETS credential cache 与后续 read-through cache 有统一失效路径。它不是 `.minio.sys` shared-nothing
   元数据复制，也不替代后续 sidecar 权威化的完整收敛。
4. **scanner 成熟度**：M8-3a/b/c/d + orphan cleanup 续作已新增 `Maxio.Cluster.Scrubber`，可从 PG 对象元数据分页自动枚举、
   刷新 usage 快照，并按 `sample_inverse` 做确定性 1/N 深度 heal 采样；`Maxio.Cluster.Heal.heal_object/4`
   仍是单对象跨节点重建核心。`Maxio.Storage.Scanner` 现在会检测盘上孤儿 shard
   （`part.0` 无 sidecar、delete-marker 目录残留 `part.0`），默认只计数/日志；显式
   `--cleanup-orphan-shards` 时才在 sidecar 写权威、全端点可达、对象锁、二次探针、年龄门和每轮删除上限
   同时满足后删除 `part.0`。M8 续作已补保守 token-bucket object pacing；
   仍 defer：live IO 自适应暂停与长期离线盘策略。
5. **多 parity / storage class**：单一 (K,M)；`x-amz-storage-class` → 不同 EC = defer（沿用 M6）。
6. **parity upgrade on degraded write**：写未达 write_quorum 即 `{:error, :write_quorum}`（绝不静默）；
   MinIO 的「写时临时提高 effective parity」= defer。
7. **专用流式分片传输（gRPC/HTTP2 + 连接池 + 背压）**：M7 用 :erpc（OTP 内置，逐 block-shard 有界）。
   大规模 / 跨数据中心 / mTLS 专用传输 = defer（`Transport` behaviour 已抽象，换实现不动后端）。
8. **failure-domain 感知的自动 set 形成**：M7 拓扑由 config **手工**指定每 set 的 N 个 `{node, drive}`。
   MinIO 的 ellipsis 展开 + node-interleaving + GCD set sizing 自动形成 = defer（手工 config 即可达同等放置）。
9. **沿用 M0–M6 全部既有 defer**（lifecycle Transition/NoncurrentVersionTransition、SSE 大对象逐帧流式 GET、
   IAM managed-policy/group/role/session 扩展、MFA Delete 强制、跨账户多租户、条件高级扩展、inline 小对象等）。

**设计保证**：M7 在 M6 同一 RS 核心**之外**加 routing/locking/topology/transport 层，**不重写
encode/decode/heal 引擎**；所有节点宕机/超时/quorum-loss → nil 分片 → EC 重建或结构化 raise，
**绝不静默返回错数据**（铁律 3）。deferral 逐条显式列出，无静默缺口。

## 分布式运维成熟度（M8，进行中）

当前已完成 **M8-1 quorum lock core**、**M8-2 cache invalidation spine**、
**M8-3a/b/c/d/e PG metadata-driven scrubber/auto-heal + optional index reconcile pre-pass + orphan shard evidence/cleanup**
与 **M8-4 integration evidence + peer lock harness**。
`Maxio.Cluster.LockServer` 作为每节点本地 lease table，
`Maxio.Cluster.Lock` 在多个节点上获取同一 token，达到 quorum 后才运行调用方临界区。它保留
`with_lock/2,3` 与 `quorum_with_lock/2,3` 返回形态，因此 S3 handler 和存储后端调用面不变。

支持能力：

- write lock 独占、read lock 共享；
- owner 进程退出自动释放本地 token；
- monotonic TTL sweep 清理过期 lease；
- `acquire/2`、`release/1`、`refresh/1`、`force_unlock/2` 可用于后续 scanner/运维任务；
- heartbeat 丢失 quorum 会中止受保护 worker，避免 lease 失效后继续写入；
- unknown-token release 会短期取消该 token，防止远端超时 acquire 后到造成未跟踪锁；
- 锁竞争继续在 S3 层映射为 `503 RequestTimeout`，不同于 write quorum 的 `SlowDownWrite`。

边界：这是 dsync/Redlock 类 best-effort 锁，不是 Raft 线性化锁；节点重启会遗忘本地 lease。
后续若要把锁作为强写 epoch，需要 fencing token 写入 sidecar/元数据来拒绝陈旧 writer。

M8-2 已提供：

- `Maxio.Cluster.Notify`：统一通过 `Phoenix.PubSub` topic `maxio:metadata` 广播 metadata invalidation event；
- `Maxio.Cluster.CacheInvalidator`：监督树内订阅 topic，当前对 credential MemoryStore 执行真实 ETS 失效；
- `CredentialStore.invalidate/1` 可选 callback，EctoStore 当前 no-op（生产路径每请求读 Postgres，无本地 credential cache）；
- IAM access key、bucket config、bucket metadata、bucket/identity policy、object ACL/tag mutation 成功后在 context/facade 层广播事件，S3 API、Console、Mix 任务共享同一失效路径。

边界：当前多数 metadata 仍由共享 Postgres 或 sidecar 权威入口读取，失效订阅者多数事件是为未来缓存预留的 no-op；
这不是 `.minio.sys` shared-nothing 元数据复制，也不提供 Raft/epoch 强一致。

M8-3a/b/c/d/e 已提供：

- `Maxio.Cluster.Scrubber`：默认随监督树启动但不调度；`config :maxio, :scrubber, enabled: true`
  后按 `interval_ms` 周期运行。周期轮按 `sample_inverse` 做确定性 1/N 深度 heal 检查，
  `mix maxio.scan` / `run_once` 默认仍为全量取证。
- `mix maxio.scan [--bucket <name>] [--versions] [--no-throttle] [--max-objects-per-sec N] [--object-burst N] [--sleep-between-batches-ms MS] [--reconcile-index]`：
  一次性扫描入口，输出
  buckets/scanned/damaged/healed/unrecoverable/missing/skipped/sampled_out/index_status/index_scanned/index_upserted/index_gc/index_skipped/index_divergent/index_orphan_shards/index_orphan_bytes/index_orphan_cleaned/index_orphan_cleaned_bytes/objects/bytes。
  `--reconcile-index` 会先调用既有 `Maxio.Storage.Scanner` 做 disk/peer sidecar → PG 派生索引收敛，
  再用刷新后的 PG inventory 做 usage/heal；默认不越过 write-authority 安全闸，需要明确接受盘权威时才加
  `--force-reconcile-index`。
- 对象来源为 `Maxio.Objects` 的有界分页；FS 后端只刷新 `Maxio.Cluster.Scrubber.Usage` 快照，
  `ErasureCoded`/`Distributed` 后端按 erasure set 通过 `Maxio.Cluster.Lock.quorum_with_lock/3`
  获取 heartbeat-backed 短租约后调用 `Maxio.Storage.Erasure.Heal` 或 `Maxio.Cluster.Heal`。
  Distributed 的默认锁节点来自对象所在 erasure set 端点节点，避免多节点本地-only 重复扫描。
- `Maxio.Storage.Scanner` 会在 reconcile 轮附带 orphan shard evidence：检测 `part.0`
  无 `meta.json`、delete-marker sidecar 旁残留 `part.0`，默认输出 `orphan_shards/orphan_bytes`，
  并透传到 `mix maxio.scan` 的 `index_orphan_*` 字段。显式
  `--cleanup-orphan-shards` / `--orphan-cleanup-dry-run` 可执行或演练 guarded cleanup；
  清理只删除 `part.0`，绝不删除目录或 `meta.json`，并输出 `orphan_cleaned/orphan_cleaned_bytes`。
- 不可恢复对象只计数并结构化 error 日志，绝不伪造数据；拿不到 set 锁的对象计为 skipped。

M8-4 已提供：

- `test/maxio/cluster/m8_integration_test.exs`：默认回归中证明监督树内 `Scrubber.scan_now/1`
  能对 `Distributed` + `InProcess` 拓扑执行 PG-inventory driven heal；同一流程验证
  bucket/object metadata mutation 仍经 `Notify` topic 可观测。
- 同一集成测试证明 `Distributed` scrubber 使用 set-resource 锁；local-node topology 下 set lock 被持有时对象计为
  `skipped` 且不越权 heal，释放后下一轮才修复 shard。多节点 quorum 语义由 peer harness 收集。
- `test/maxio/cluster/peer_lock_test.exs`：`@tag :distributed` 默认排除，单独
  `MAXIO_RUN_PEER_LOCK=1 mix test test/maxio/cluster/peer_lock_test.exs --include distributed`
  时才尝试起真实 `:peer` BEAM 节点，收集 `Lock.acquire/2` 经 `:erpc` 到 peer `LockServer`
  后跨节点排他、三节点丢一 peer 仍保留多数 quorum、以及 peer-backed scrubber 默认 set-node
  lock 选择的证据。未设置环境变量时该文件报告 skipped，避免把不可用 peer 环境伪装成通过。

M8 剩余：

- 完整 MinIO data-scanner parity：live IO 自适应限流、drive-offline 长窗口策略。
  当前已有保守 token-bucket object pacing（`max_objects_per_sec` + `object_burst`，允许 burst 后限制下一次对象扫描开始），
  但尚未接入 live request/drive IO 负载反馈。
