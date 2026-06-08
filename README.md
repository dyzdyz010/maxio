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

### Lifecycle（仅配置，执行 DEFER）

- **`PutBucketLifecycleConfiguration`/`Get`/`Delete`**（`?lifecycle`）：**仅存储 / 校验 / 出站配置**（字节级往返：Filter/And/legacy Prefix、Expiration、NoncurrentVersionExpiration、AbortIncompleteMultipartUpload、Transition）；无配置 → `NoSuchLifecycleConfiguration 404`。
- **后台过期执行未实现（defer）**：maxio **不会**自动过期对象或中止未完成的分段上传。诚实暴露于三处：(a) 应用启动时 `Logger.info` 列出 M4 defer 清单；(b) `mix maxio.lifecycle.run` 仅打印「expiration execution NOT implemented in M4」；(c) 本 README。
- `Transition`/`NoncurrentVersionTransition` 在单层 maxio 无意义——接受持久化但 **no-op**。`Date`（绝对时间）仅存储/校验。

### SSE-S3（服务端加密）

- **真实 AES-256-GCM 信封加密**：PutObject 带 `x-amz-server-side-encryption: AES256`（或桶默认加密配置）时，对象字节**真实加密落盘**——每对象生成随机 256-bit 数据密钥（DEK），数据重切为 64KB 帧、每帧独立 AES-256-GCM（随机 IV + 认证 tag），DEK 由服务端主密钥 AES-256-GCM 包裹后随对象元数据存储。GET 透明解密；GCM 认证失败会**抛错**，绝不静默返回错数据。
- **`PutBucketEncryption`/`Get`/`Delete`**（`?encryption`）配置桶默认加密；无配置 → `ServerSideEncryptionConfigurationNotFoundError 404`。
- **密钥管理简化**：单一静态服务端主密钥（`config :maxio, :sse, master_key`，dev/test 固定值，prod 经环境变量）——**无密钥轮转、无 HSM、无 KMS**。
- **仅 SSE-S3（AES256）**：`aws:kms`/`aws:kms:dsse` 的 `SSEAlgorithm` 或 `x-amz-server-side-encryption-customer-*`（SSE-C）头 → `501 NotImplemented`（绝不静默当 AES256）。`BucketKeyEnabled` 接受持久化但 no-op（KMS 专属）。
- **Range / 大对象**：MVP 对加密对象的 Range 请求降级为返回完整对象（`200`，绝不返回错误字节）；GET 整对象解密后 `send_resp`（大对象逐帧流式解密留后续优化）。SSE 对象的 ETag 是密文 MD5（与 AWS SSE-S3 一致，非明文 MD5）。

### M4 显式 defer 清单（汇总；文档化，绝不静默）

1. **Lifecycle 后台过期 / 中止 MPU 执行**：仅存储/校验/出站；不跑 sweeper（启动日志 + mix stub + 本 README 暴露）。`Transition`/`NoncurrentVersionTransition` 接受持久化但 no-op。
2. **MFA Delete**：`MfaDelete` 状态解析/存储/回显（仅曾配置时回 `<MfaDelete>`），但不强制 MFA 校验（无设备），`x-amz-mfa` 头不验证。
3. **SSE-C / SSE-KMS / DSSE-KMS**：仅 SSE-S3（AES256）；其余 → `501 NotImplemented`。`BucketKeyEnabled` no-op。
4. **SSE 密钥管理简化**：单一静态主密钥，无轮转/HSM/KMS。
5. **SSE 对象 + Range / 大对象逐帧流式解密**：Range 降级为完整对象；整对象解密后返回。
6. **Multipart 完成对象在版本化桶的逐版本字节路径**：multipart 字节走 null 路径、元数据当当前 null 版本；单段 PutObject 版本化完整。
7. **对象级逐版本独立 tag set**：tag 挂在版本行（`?tagging&versionId` 已支持指定版本）；`s3:*VersionTagging` 按同名非 version 权限评估（单租户）。
8. **lifecycle `Date`（绝对时间）与 `Transition` 执行**：仅存储/校验。
9. **沿用 M3 全部 defer**：跨账户/多租户、完整条件算子、IAM identity policy（`principal_policies/1` 恒 `[]`，接口已就绪传真实 principal）、STS/session token、email grantee、`x-amz-grant-*` 细粒度、Block Public Access、checksum trailer 重算、DeleteObjects 逐 key 授权。

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
- **Bucket Settings**（7 tab，`?tab=` 切换）：版本化（`put_versioning`）/ 桶策略 JSON（`Statement.parse_policy` 校验）/ canned ACL（`put_acl`）/ 桶标签（`Tags.validate`）/ CORS（`BucketConfigs` :cors）/ 生命周期（`BucketConfigs` :lifecycle，明确标注后台执行 defer）/ 默认加密（SSE-S3 AES256；SSE-KMS 绝不静默当 AES256）。
- **Access Keys**：列表（绝不回 secret）/ 创建（secret 仅在创建响应里显示一次，不入 stream/session）/ 删除（保护最后一个 root：`:cannot_delete_last_root` 显式 flash）。

前端可调试钩子：app.js 暴露 `window.__maxio = {liveSocket, log, version: "M5"}`，所有 Console 日志带标签 `[maxio][Console]`。

### 显式未实现（defer，绝不假装实现 / 不画死按钮）

- **Identity → Users / Groups / IAM identity policy / STS / IdP**：maxio 单租户，无独立 user/group 实体（`principal_policies/1` 恒 `[]`）。Console 用 **access key** 作 identity primitive；Users/Groups 在侧边栏**不出现**（不画灰条目假装有）。
- **Bucket → Quota / Events-Notifications / Replication / Object-Lock-Retention-Legal-Hold**：后端未实现，Settings 页不画这些 tab。
- **Object → 内联预览 / Legal hold / Retention**：后端未实现 / SSE 对象 GET 全缓冲（M4 defer）使大加密对象预览有风险——仅提供下载。
- **Monitoring → Logs/Trace/Audit 流 / Drives/Heal / 流量·API速率·延迟 时序图**：需 Prometheus/纠删码（M6）。Dashboard 只做廉价计数，不画时序图。
- **Configuration / Settings 运行时编辑 / Tiers / Site Replication / Batch Jobs / License**：后端无运行时配置存储；不做。
- **Console 大文件多段上传**：MVP 走单 PUT（≤5 GiB，服务端临时文件中转）；接 `Maxio.Multipart` 逐 part 上传标为后续优化。
- **生命周期后台执行**：Console 可编辑规则，但后台过期/转储执行未实现（沿用 M4 defer）。
- **预签名分享 URL**：可经 `Maxio.Auth.SigV4.Signer` 生成指向 S3 端的预签名 GET（唯一引用 S3 HTTP 之处），MVP 未做 UI（不画死按钮）。
