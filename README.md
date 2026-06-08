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
