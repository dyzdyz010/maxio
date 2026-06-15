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
- **MFA Delete**：`MfaDelete` 状态可解析/存储/回显；启用/禁用 MFA Delete、在 MFA Delete 桶中改变 versioning 状态、`DELETE ?versionId`、`Suspended` 桶中会替换 `null` 版本的无 `versionId` 删除、以及含 `<VersionId>` 或会替换 `null` 版本条目的 `DeleteObjects` 都要求 root principal、HTTPS 且已签名的 `x-amz-mfa`，并通过 `config :maxio, :mfa_delete_verifier` 配置的 verifier。未配置 verifier 时受保护操作 fail-closed。`DeleteObjects` 缺/错 MFA 为整请求失败；`Enabled` 桶普通无 `versionId` DELETE 只插入独立 delete marker，不要求 MFA。
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

### STS session credentials（续作已支持）

- **本地临时凭据**：`Maxio.STS.issue_session/1` 基于活跃长期 access key 签发 `ASIA...` 临时 access key、secret key 与 session token；数据库只保存 `session_token_sha256`，secret/token 仅在签发响应中出现一次。
- **SigV4 鉴权**：header auth 支持已签名的 `x-amz-security-token`，presigned URL 支持 `X-Amz-Security-Token` query 参数；临时 key 缺 token、错 token、过期或撤销均 fail-closed，长期 key 携带 stale token 返回 `InvalidToken`。
- **GetSessionToken Query API**：`GET /?Action=GetSessionToken&Version=2011-06-15&DurationSeconds=N` 与 POST `application/x-www-form-urlencoded` form 均已支持；请求必须用长期凭据按 SigV4 `sts` service scope 签名，返回 STS XML `<GetSessionTokenResponse>`，临时凭据可继续签 S3 请求但不能递归调用 `GetSessionToken`。可选 `SerialNumber`/`TokenCode` 会通过本地 TOTP verifier 两阶段校验并消费，成功 session 在后续 S3 授权上下文暴露 `aws:MultiFactorAuthPresent=true`。
- **GetCallerIdentity Query API**：`GET/POST Action=GetCallerIdentity` 已支持；请求必须有效签名且 SigV4 credential scope service 为 `sts`，但不评估 IAM allow/deny policy、不签发新凭据、不落库。长期凭据、`GetSessionToken` 临时凭据与 `AssumeRole` role session 均可调用；响应返回 `UserId`、`Account`、`Arn`。`Account` 来自 `config :maxio, :sts, account_id: ...`（运行时 `MAXIO_ACCOUNT_ID` 可覆盖，默认 `000000000000`）；当前仍沿用 maxio 单账户 ARN/`UserId` 折中，完整 AWS account-id / unique-id / role-id 体系随多租户 IAM 扩展收敛。
- **AssumeRole Query API**：新增 IAM role 存储与 trust policy 解析；`GET/POST Action=AssumeRole` 支持 `RoleArn`、`RoleSessionName`、`DurationSeconds` 与 `Tags.member.N.Key/Value` session tags，按角色信任策略评估 `sts:AssumeRole`，返回 `<AssumeRoleResponse>` 临时凭据。该临时凭据以 role ARN 作为 S3 授权 principal，可通过现有 `principal_policies` 绑定角色权限；session tags 会大小写不敏感覆盖同名 role tags，并在后续 S3 授权上下文暴露为 `aws:PrincipalTag/*`。`GetSessionToken` 临时凭据与 assumed-role 临时凭据均可调用 `AssumeRole`；role chaining 的 `DurationSeconds` 上限按 AWS 语义收紧为 3600 秒。
- **AssumeRole trust context**：`ExternalId`、`SourceIdentity`、`SerialNumber`/`TokenCode` MFA 与 session tag 上下文已参与 trust policy 条件求值（`sts:ExternalId`、`sts:SourceIdentity`、`aws:SourceIdentity`、`aws:MultiFactorAuthPresent`、`aws:RequestTag/*`、`aws:TagKeys`、`aws:ResourceTag/*`）。设置或继承 SourceIdentity 时，目标 role trust policy 必须同时允许 `sts:AssumeRole` 与 `sts:SetSourceIdentity`，且非 root 调用方 identity policy 也必须允许对目标 role 执行 `sts:SetSourceIdentity`；传入 session tags 时，目标 role trust policy 必须同时允许 `sts:AssumeRole` 与 `sts:TagSession`。SourceIdentity 会随会话持久化并在 S3 授权上下文暴露为 `aws:SourceIdentity`；role chaining 会继承既有 SourceIdentity 且拒绝改写。MFA 成功会持久化审计布尔态与 serial SHA256，不保存 raw serial 或 token code。按 AWS 语义，`AssumeRole` 得到的临时凭据后续访问 S3 时不暴露 `aws:MultiFactorAuthPresent`；该键只用于本次 role trust policy 判断。当前 MFA 路径复用本地 root/IAM user TOTP 设备管理。
- **CLI**：`mix maxio.sts.issue_session --access-key AKIA... [--duration-seconds N] [--json]`、`mix maxio.sts.list_sessions [--json]`、`mix maxio.sts.revoke_session --access-key ASIA...`。list/revoke 不输出 secret、token 或 token hash。
- **仍 defer**：WebIdentity、session policy、`TransitiveTagKeys`/链式 session tag 传播、跨账户/account-principal 场景下的 STS caller `sts:AssumeRole` identity-policy side 授权、ProvidedContexts、AWS IAM MFA device API surface、硬件 MFA、Console UI 与 secret at-rest 加密统一治理。

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

### Bucket Website（续作已支持）

- **API**：`PutBucketWebsite` / `GetBucketWebsite` / `DeleteBucketWebsite`（`?website`）支持 bucket-level `WebsiteConfiguration` 持久化与 XML 回放；无配置的 GET 返回 `NoSuchWebsiteConfiguration 404`，DELETE 幂等返回 `204`。
- **配置校验**：请求体按 AWS 上限限制为 128 KiB；`RedirectAllRequestsTo` 与其它属性互斥；普通 website 模式必须有 `IndexDocument/Suffix`；`RoutingRules` 最多 50 条，`Redirect` 必填，`ReplaceKeyWith` 与 `ReplaceKeyPrefixWith` 互斥；`Protocol` 仅支持 `http|https`。
- **授权**：ActionMap/Authz 映射 `s3:PutBucketWebsite` / `s3:GetBucketWebsite` / `s3:DeleteBucketWebsite`，其中 DELETE 使用独立 `s3:DeleteBucketWebsite` 权限。
- **边界**：当前只实现控制面配置 API，不实现静态网站 endpoint、索引文档重写、错误文档回退或 routing rule 对对象读取路径的影响。

### SSE-S3（服务端加密）

- **真实 AES-256-GCM 信封加密**：PutObject 带 `x-amz-server-side-encryption: AES256`（或桶默认加密配置）时，对象字节**真实加密落盘**——每对象生成随机 256-bit 数据密钥（DEK），数据重切为 64KB 帧、每帧独立 AES-256-GCM（随机 IV + 认证 tag），DEK 由服务端主密钥 AES-256-GCM 包裹后随对象元数据存储。GET 透明解密；GCM 认证失败会**抛错**，绝不静默返回错数据。
- **`PutBucketEncryption`/`Get`/`Delete`**（`?encryption`）配置桶默认加密；无配置 → `ServerSideEncryptionConfigurationNotFoundError 404`。
- **密钥管理简化**：单一静态服务端主密钥（`config :maxio, :sse, master_key`，dev/test 固定值，prod 经环境变量）——**无密钥轮转、无 HSM、无 KMS**。
- **仅 SSE-S3（AES256）**：`aws:kms`/`aws:kms:dsse` 的 `SSEAlgorithm` 或 `x-amz-server-side-encryption-customer-*`（SSE-C）头 → `501 NotImplemented`（绝不静默当 AES256）。`BucketKeyEnabled` 接受持久化但 no-op（KMS 专属）。
- **Range / 大对象**：MVP 对加密对象的 Range 请求降级为返回完整对象（`200`，绝不返回错误字节）；GET 整对象解密后 `send_resp`（大对象逐帧流式解密留后续优化）。SSE 对象的 ETag 是密文 MD5（与 AWS SSE-S3 一致，非明文 MD5）。

### M4 显式 defer 清单（汇总；文档化，绝不静默）

1. **Lifecycle Transition / NoncurrentVersionTransition 执行**：当前版本过期、非当前版本过期、仅存 delete marker 清理、旧 MPU 中止可由 `mix maxio.lifecycle.run` 或 `config :maxio, :lifecycle_scheduler, enabled: true` 后台周期执行；Transition / NoncurrentVersionTransition 仍 no-op 并显式暴露。
2. **MFA Delete 设备管理 / 非 HTTP 入口**：S3 HTTP API 已强制 MFA Delete，并在未配置 verifier 时 fail-closed；受保护操作必须 root principal，且 `x-amz-mfa` 必须被 SigV4 `SignedHeaders` 覆盖。已提供 DB-backed root/IAM user TOTP 设备管理、加密 seed 信封、pending→active 激活、CLI 注册/验证/停用/列举与 TOTP step 防重放；MFA Delete verifier 仍只接受 root principal，生产环境必须配置 `MAXIO_MFA_SECRET_KEY`。仍 defer：硬件 MFA/硬件 serial 管理、AWS IAM MFA device API、轮换编排 UI，以及 Console 等非 HTTP operator 路径的 MFA 交互语义。Lifecycle runner 对 MFA Delete 桶会跳过会永久删除版本的动作并计数，不绕过 header verifier。
3. **SSE-C / SSE-KMS / DSSE-KMS**：仅 SSE-S3（AES256）；其余 → `501 NotImplemented`。`BucketKeyEnabled` no-op。
4. **SSE 密钥管理简化**：单一静态主密钥，无轮转/HSM/KMS。
5. **SSE 对象 + Range / 大对象逐帧流式解密**：Range 降级为完整对象；整对象解密后返回。
6. **Multipart 完成对象版本化（2026-06-12 已收敛）**：CompleteMultipartUpload 在 Enabled 桶生成独立 ULID `version_id`，字节、sidecar、PG/索引与 `x-amz-version-id` 响应头使用同一版本；Suspended/Unversioned 仍写 `null` 版本。
7. **对象级逐版本独立 tag set**：tag 挂在版本行（`?tagging&versionId` 已支持指定版本）；`s3:*VersionTagging` 按同名非 version 权限评估（单租户）。
8. **lifecycle `Transition` / `NoncurrentVersionTransition` 执行**：仅存储/校验/回放；runner 计 unsupported，不做静默转储。
9. **沿用 M3 剩余 defer**：跨账户/多租户、更广泛 AWS 全局上下文键、AssumeRole WebIdentity/session policy/`TransitiveTagKeys` 链式 session tag 传播、跨账户/account-principal 场景下的 STS caller `sts:AssumeRole` identity-policy side 授权、email grantee、checksum trailer 重算、secret at-rest 加密。

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

1. **Rebalance / Decommission / online pool 扩容**：添加/退役 pool、跨 pool 迁移
   （MinIO `mc admin rebalance`/`decommission`）。M8 已补 pool metadata、opt-in free-space 加权新写
   与受限旧对象 rebalance copy-pass/source cleanup；topology/pool mutation、pool removal
   与 set 数 per pool 在线扩缩仍 defer。
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
   同时满足后删除 `part.0`。M8 续作已补保守 token-bucket object pacing、本节点
   S3 handler in-flight + ShardServer storage-op 自适应对象间暂停、cached peer pressure aggregation、
   node-local drive health 长窗口离线观测、persistent software drive identity replacement detection、
   operator-triggered fresh-drive heal pass、默认关闭的 marker-based 自动 fresh-drive heal scheduler，以及
   read-only rebalance/decommission planning telemetry、OS/设备级 drive queue/latency/吞吐 pressure telemetry；
   仍 defer：硬件/物理 drive identity 与完整 replacement/rebalance workflow；decommission 主路径已有只读 workflow closure 取证，
   rebalance 现有只读 copy/cleanup/placement closure auditor 与 opt-in closure verifier。
5. **多 parity / storage class**：单一 (K,M)；`x-amz-storage-class` → 不同 EC = defer（沿用 M6）。
6. **parity upgrade on degraded write**：写未达 write_quorum 即 `{:error, :write_quorum}`（绝不静默）；
   MinIO 的「写时临时提高 effective parity」= defer。
7. **专用流式分片传输（gRPC/HTTP2 + 连接池 + 背压）**：M7 用 :erpc（OTP 内置，逐 block-shard 有界）。
   大规模 / 跨数据中心 / mTLS 专用传输 = defer（`Transport` behaviour 已抽象，换实现不动后端）。
8. **failure-domain 感知的自动 set 形成**：M7 拓扑由 config **手工**指定每 set 的 N 个 `{node, drive}`。
   MinIO 的 ellipsis 展开 + node-interleaving + GCD set sizing 自动形成 = defer（手工 config 即可达同等放置）。
9. **沿用 M0–M6 全部既有 defer**（lifecycle Transition/NoncurrentVersionTransition、SSE 大对象逐帧流式 GET、
   IAM managed-policy/group/role/session 扩展、Console operator MFA 交互语义、跨账户多租户、条件高级扩展、inline 小对象等）。

**设计保证**：M7 在 M6 同一 RS 核心**之外**加 routing/locking/topology/transport 层，**不重写
encode/decode/heal 引擎**；所有节点宕机/超时/quorum-loss → nil 分片 → EC 重建或结构化 raise，
**绝不静默返回错数据**（铁律 3）。deferral 逐条显式列出，无静默缺口。

## 分布式运维成熟度（M8，进行中）

当前已完成 **M8-1 quorum lock core**、**M8-2 cache invalidation spine**、
**M8-3a/b/c/d/e PG metadata-driven scrubber/auto-heal + optional index reconcile pre-pass + orphan shard evidence/cleanup**
与 **M8-4 integration evidence + peer lock harness**，并补入 **node-local S3 + storage-op adaptive scrubber pacing**、
**node-local drive health long-window offline registry**、**software drive identity replacement detection**、
**drive IO latency/throughput telemetry CLI**、**OS/device-level drive IO pressure telemetry CLI**、**drive filesystem capacity stats CLI**、
**operator-triggered fresh-drive heal workflow** 和
**config-gated fresh-drive heal scheduler**，并新增 **read-only rebalance/decommission planning CLI**
与 **object placement contract**、**persistent rebalance/decommission job control plane**、
**restricted foreground decommission/rebalance copy-pass runner**、**rebalance runner singleton lock + monotonic progress**
以及 **guarded decommission/rebalance source-shard cleanup**、**decommission write-routing freeze / MPU placement contract**、
**config-gated decommission/rebalance scheduler**、**free-space decommission destination selection**、
**pool free-space weighted new-write placement**、**topology removal preflight CLI**、**topology removal plan artifact CLI**、
**runtime-local topology removal apply CLI**、**cluster runtime topology convergence apply CLI**
和 **DB-backed deployment topology revision persistence CLI**、**deployment topology removal verification CLI**、
**physical removal manifest / read-only preflight CLI**、**operator-gated physical layout quarantine CLI**、
**retention-gated physical quarantine purge CLI**、**read-only decommission workflow/pool-retired auditor CLI**、
**read-only rebalance workflow/placement closure auditor CLI**、**rebalance closure verifier CLI**、
**read-only drive hardware evidence CLI**、**physical-removal hardware evidence audit flag** 与
**persistent scheduler run ledger / backoff / alert CLI** 与 **scheduler cluster-cadence evidence v1**。
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
- `mix maxio.scan [--bucket <name>] [--versions] [--no-throttle] [--max-objects-per-sec N] [--object-burst N] [--sleep-between-batches-ms MS] [--no-adaptive-io] [--io-load-source s3-in-flight|storage-ops|drive-device-io|combined|cluster-s3-in-flight|cluster-storage-ops|cluster-drive-device-io|cluster-combined] [--max-live-requests N] [--io-pause-ms MS] [--io-max-pause-ms MS] [--drive-offline-after-ms MS] [--reconcile-index]`：
  一次性扫描入口，输出
  buckets/scanned/damaged/healed/unrecoverable/missing/skipped/sampled_out/index_status/index_scanned/index_upserted/index_gc/index_skipped/index_divergent/index_orphan_shards/index_orphan_bytes/index_orphan_cleaned/index_orphan_cleaned_bytes/drive_sets/drive_endpoints/drive_online/drive_suspect/drive_offline/drive_heal_required/drive_identity_replacements/drive_identity_heal_required/drive_identity_errors/objects/bytes。
  `--reconcile-index` 会先调用既有 `Maxio.Storage.Scanner` 做 disk/peer sidecar → PG 派生索引收敛，
  再用刷新后的 PG inventory 做 usage/heal；默认不越过 write-authority 安全闸，需要明确接受盘权威时才加
  `--force-reconcile-index`。
- `Maxio.S3.InFlight`：监督树内长期进程持有本节点 ETS 计数器，`S3.Plugs.Dispatch`
  在 handler 生命周期内计数并在正常返回/结构化 S3 错误/异常后释放。计数是 node-local、best-effort，
  不拒绝前台请求，只给后台维护任务提供 live traffic 压力信号。
- `Maxio.Cluster.DriveIO`：监督树内长期进程持有本节点 ETS 计数器，`ShardServer` 的 shard/sidecar/list/probe/stat/delete/commit/heal
  路径会记录 active storage ops、读写/metadata/delete 次数、completed attempts、best-effort bytes、
  应用层 latency（`max_latency_us` 为并发完成下的 best-effort 高水位）与自上次 reset 起的吞吐估算；
  `mix maxio.drive.io [--reset]` 可打印/清零本节点累计 telemetry，reset 保留 active gauges 以免干扰 adaptive pacing。
  计数 fail-open，不影响存储结果。
- `Maxio.Cluster.DriveStats` / `mix maxio.drive.stats [--summary-only] [--drive <path>]`：
  经 `Transport.drive_stats/3` 主动探测当前 topology 的 drive root，输出每个 endpoint 的 filesystem
  capacity/free/used、used_percent、mount_root、source 与 precision，并汇总总量和最小 free-space；
  默认 provider 使用 OTP `os_mon`/`disksup`，测试和特殊部署可经 `config :maxio, :drive_stats, provider: fun/1`
  注入。该信号是 filesystem capacity 观测，不是 queue depth、SMART、硬件身份、物理吞吐。默认不改变对象路由；
  显式启用 pool write policy 时会作为新写 pool 加权落点输入。
- `Maxio.Cluster.DriveDeviceIO` / `mix maxio.drive.device_io [--summary-only] [--drive <path>] [--cached] [--reset]`：
  监督树内维护 fail-open cache，按当前 topology 只采样本节点 drive root；Linux 默认 provider 读取 `/proc/self/mountinfo`
  与 `/proc/diskstats`，把 queue depth、busy%、吞吐、ops/s、平均 latency 或原始 diskstats delta 归一化为
  `pressure`，并把 `drive-device-io` / `cluster-drive-device-io` 纳入 scrubber/fresh-drive adaptive gate。
- `Maxio.Cluster.DriveHardwareEvidence` / `mix maxio.drive.hardware_evidence [--summary-only] [--drive <path>] [--json] [--show-raw] [--smart] [--smartctl-path <path>] [--smart-timeout-ms <ms>] [--smart-nocheck never|sleep|standby|idle]`：
  只读采集 topology endpoint 或单个 drive root 的 mount/device/sysfs 证据；Linux 默认 provider 读取
  `/proc/self/mountinfo` 与 `/sys/dev/block/<major>:<minor>`，输出 mount root/source、fs type、major:minor、
  block/parent device、rotational/model 与 serial/WWID hash。raw serial/WWID 默认不打印，必须显式
  `--show-raw`；每条输出都标记 `destructive_gate=false`。`--smart` 显式开启后会在 endpoint owner node
  上有界执行 `smartctl -j -a -n <mode>`（默认 `standby`，`never` 时省略 `-n`），只抽取 SMART allowlist
  子证据（health/support、power-on/temperature、ATA/NVMe 常见计数、raw SMART identity 的 hash）；
  smartctl 缺失、权限不足、timeout、invalid JSON 或非零 exit 都只进入 `smart.status/error/exit_status`，
  base sample 仍保持只读证据语义，且不会 dump 原始 smartctl JSON。raw SMART serial/WWN/EUI64/NGUID 也默认
  只输出 hash，`--show-raw` 只放行这些明确身份字段，不放行完整 JSON。
  该信号不写 `cluster_drive_identities`，
  不触发 heal/rebalance，不作为 physical remove/purge 安全闸；CLI 不启动完整 app/supervision tree，
  config topology 直接解析，DB topology 仅启动 Repo 做只读 active revision 读取。
  非 Linux、provider 错误/异常、无 topology、stale cache 均返回 0，不影响 S3 路由、quorum、写入或对象迁移；
  SMART passed 也不是硬盘健康保证、secure erase 证明、admission control 或真实物理身份判断。
- `Maxio.Cluster.Placement.PoolWritePolicy`：默认关闭（`config :maxio, :pool_write_policy, mode: :hash`），
  保持 M7 全局 set hash。设置 `mode: :weighted_free_space` 或
  `MAXIO_POOL_WRITE_POLICY=weighted_free_space` 后，普通新写先按健康 pool 的 filesystem free bytes 做确定性加权选择，
  再在该 pool 的 set 列表内按对象名 hash 选择 set；显式 `placement_set_id` 仍优先，读/删/旧对象仍使用
  持久化 placement。candidate pool 若 endpoint telemetry 缺失或 endpoint error 会 fail-closed；
  超过高水位（默认 `max_used_percent_x100: 9900`，可用 `MAXIO_POOL_WRITE_MAX_USED_PERCENT_X100` 覆盖）
  或无可用空间的 pool 会被跳过，直到无可写 pool 时返回结构化错误。当前未内建后台 telemetry cache；
  未传 `drive_stats` 快照时会现场采样，因此仍保持 opt-in。该策略只影响新对象落点，不迁移旧对象、
  不改 topology、不删除 pool。
- `Maxio.Cluster.Rebalance` / `mix maxio.rebalance.plan [--current-only] [--decommission-set <id>] [--page-size <n>] [--no-drive-stats] [--json]`：
  对当前 topology 做只读规划取证，从 PG 对象元数据分页枚举对象/版本/delete marker。对象行有
  `placement_set_id` 时优先按持久化真实落点汇总；旧行或未知落点回退到当前 `Router.set_for/3`，
  并通过 `placement_fallbacks` 暴露估算风险。输出每个 erasure set 的 logical bytes、版本数、
  delete marker 数与可选 drive capacity/free-space。`--decommission-set` 仅估算目标 set 受影响对象范围；
  不移动数据、不改新写 placement、不实现 MinIO `mc admin rebalance/decommission` 状态机。物理 shard bytes
  与真实迁移计划仍需后续迁移层处理。
- `Maxio.Cluster.Rebalance.Jobs` / `mix maxio.rebalance.start|status|cancel`：
  持久化 rebalance/decommission 运维 job 控制面。`start` 会保存当时的 planner 快照、job kind/target set、
  cursor/progress 初始字段与 `data_movement=false` / `data_movement_status=not_started`；DB partial unique index
  与 context 双层保证同一时间最多一个 active job；job creation 与 runtime-local topology apply 共享同一个
  runtime-topology quorum lock，避免在 set removal apply 期间按旧 runtime topology 生成新计划。若计划里存在 `placement_fallbacks`，会拒绝创建 job，
  避免在无法确认真实落点时伪造可执行迁移计划；decommission job 也会拒绝 `--current-only`，必须盘点全版本
  与 delete marker。
- `Maxio.Cluster.Rebalance.Runner` / `mix maxio.rebalance.run [JOB_ID|--job-id <uuid>] [--destination-set <id>|--auto-destination] [--max-versions <n>] [--page-size <n>] [--dry-run] [--json]`：
  受限前台 copy-pass。decommission job 要求 operator 显式指定目标 erasure set 或启用 `--auto-destination`；
  rebalance job 不接受固定 destination，而是逐对象按当前 topology/router 计算目标 set，仅迁移持久化 placement
  与当前路由不一致的版本/delete marker。在 PG object placement 作为 read/list 权威时，目标写成功后用乐观条件更新对象 placement。
  `--max-versions` 可分批推进 cursor；rebalance 对已在目标 set 的行计为 skipped 并推进 cursor；
  非 dry-run 会先获取 job 级 quorum lock，锁内重新读取 job 并重新校验；progress/cursor 只单调前进，
  stale runner 不能回退计数或 cursor。`--dry-run` 只返回计划报告，不修改 job。边界：runner 本身不启动后台 worker；
  source cleanup 走单独 guarded cleanup；不改 topology/pool、不做 pool removal；
  rebalance 使用 current router 而非 write-routing/pool free-space policy；若 read/list authority 不是 PG 会 fail-closed。
- `Maxio.Cluster.Rebalance.SourceCleanup` / `mix maxio.rebalance.cleanup [JOB_ID|--job-id <uuid>] [--max-versions <n>] [--page-size <n>] [--dry-run] [--json]`：
  受限 source-shard cleanup。cleanup 只处理 `data_movement_status=complete` 的 decommission/rebalance job；
  非 dry-run 复用同一个 job-level quorum lock，并在对象锁内重新读取 PG row。decommission 仅在当前
  `placement_set_id == destination_set_id` 时，对旧 `target_set_id` 执行 quorum 删除；PG placement 仍是 target
  会 fail-closed。rebalance 保留 PG-authoritative `placement_set_id`，对当前 topology 中其它 set 的同版本副本执行
  quorum 删除；cleanup activation 会在 runtime-topology quorum lock 内重新读取 job 并重跑 topology/set 校验，避免与
  runtime-local topology apply 交错。缺失或未知 PG placement 会 fail-closed。`--max-versions` 使用独立 cleanup cursor/progress resume；
  `--dry-run` 不删 shard、不改 job。边界：这是已迁移版本的旧副本清理，不是 orphan scanner 或 pool removal；
  不冻结新写、不证明 pool/set 物理为空、不改 topology/pool、不做 free-space placement。
- `Maxio.Cluster.Rebalance.TopologyMutation` / `mix maxio.rebalance.preflight_removal [JOB_ID|--job-id <uuid>] [--json]` /
  `mix maxio.rebalance.plan_removal [JOB_ID|--job-id <uuid>] [--json]` /
  `mix maxio.rebalance.apply_removal [JOB_ID|--job-id <uuid>] --yes [--expected-current-topology-hash <sha256>] [--json]` /
  `mix maxio.rebalance.apply_removal_cluster [JOB_ID|--job-id <uuid>] --yes [--expected-current-topology-hash <sha256>] [--nodes <node1,node2>] [--json]` /
  `mix maxio.rebalance.persist_removal_deployment [JOB_ID|--job-id <uuid>] --runtime-node <node> --expected-proposed-topology-hash <sha256> --yes [--json]` /
  `mix maxio.rebalance.verify_removal_deployment [JOB_ID|--job-id <uuid>] [--json]` /
  `mix maxio.rebalance.physical_removal_preflight [JOB_ID|--job-id <uuid>] [--hardware-evidence] [--json]` /
  `mix maxio.rebalance.physical_remove [JOB_ID|--job-id <uuid>] --confirm-job-id <same uuid> [--hardware-evidence] [--json]` /
  `mix maxio.rebalance.physical_purge_preflight [JOB_ID|--job-id <uuid>] [--retention-hours N] [--json]` /
  `mix maxio.rebalance.physical_purge [JOB_ID|--job-id <uuid>] --confirm-job-id <same uuid> --confirm-quarantine-id <id> [--retention-hours N] [--json]` /
  `mix maxio.rebalance.workflow [JOB_ID|--job-id <uuid>] [--json]` /
  `mix maxio.rebalance.verify_closure [JOB_ID|--job-id <uuid>] [--audit-page-size N] [--json]`：
  `preflight_removal` 是只读 topology removal preflight。它要求 decommission job 已完成 copy-pass 与 source cleanup，确认无其它 active
  rebalance/decommission job、PG 中无 target-set placement row、无缺失/未知 placement row、active MPU 无 target/missing/unknown placement row，
  target set 全 endpoint 可达，且 target set 盘上所有 bucket root、`.versions`、`.uploads` 不再有 `meta.json`/`part.0`
  残留；bucket `.keep` marker 会单独计数但不阻塞。任何条件不满足都返回 blocked + blockers/examples。
  `plan_removal` 仅在 preflight ready 后生成 proposed topology config、before/after topology hash、removed set/pool 列表；
  topology hash 使用包含 EC 参数、pool/set 顺序与有序 `{node, drive}` endpoints 的 full fingerprint；
  若 target set 所在 pool 变空，proposed config 会同时移除该 pool。`apply_removal` 必须显式 `--yes`，会在 global runtime-topology
  quorum lock 内重新跑 preflight，可用 `--expected-current-topology-hash` 绑定 operator 已审阅的 plan artifact，先在 job row
  记录 `topology_removal_status/scope/hash/applied_at` 审计字段、拓扑移除前的 target endpoint manifest 与
  removed pool ids；非空 manifest 必须与 `current_topology_hash` 对应拓扑里的目标 set endpoint 清单逐项一致，再把
  proposed topology 安装到当前 BEAM runtime；
  若 audit 已记录且 before/after topology hash 与当前 plan 一致，重复执行会继续完成 runtime install，用于恢复 audit 后、
  runtime install 前的 lease-loss/进程中断窗口。`apply_removal_cluster` 是显式集群 runtime apply：同样不改 deployment
  config，但会把 proposed topology 安装到选定/推导的 BEAM runtime 节点；显式 `--nodes` 只会增加探测节点，
  不能省略 removal plan 捕获的原始 current topology node roster（包括 removed-set-only 节点）；远端节点先执行、本节点最后执行，
  任一节点 unreachable/hash mismatch 都返回结构化 partial report 且不记录 cluster convergence 审计。成功后记录
  `topology_removal_cluster_status/hash/nodes/verified_at`。随后 operator 可运行 `persist_removal_deployment`，
  必须传入已审阅的 `--expected-proposed-topology-hash`；该命令在同一 topology mutation lock 内确认 runtime/cluster
  已收敛、PG/MPU placement guard 仍干净后，把当前 runtime proposed topology 写入 `cluster_topology_revisions`
  的 active DB 版本。`config :maxio, :topology_source, :config` 仍是默认启动来源；设置
  `MAXIO_TOPOLOGY_SOURCE=db` 后，启动会从 active DB revision 加载拓扑，若缺失、无效或 hash 不匹配则 fail-closed，
  不静默回退旧 config。`verify_removal_deployment` 会按 `:topology_source` 选择部署事实来源：`:db` 必须读取 active DB revision，
  `:config` 只读取 `config :maxio, Maxio.Cluster.Topology`，避免 DB revision 已写入但重启仍加载旧 config 时过早退休 write-routing。
  它确认 target set 已不在部署拓扑、deployment topology hash 等于 apply 记录的 proposed hash，要求 cluster convergence
  审计已存在，并 live-check 审计 node roster、当前 mesh/部署拓扑/显式节点的 runtime topology hash 均已收敛到 proposed hash；
  审计节点当前不可见会以 `:missing_expected_node` fail-closed。随后重新检查 PG/MPU 中无 target/missing/unknown placement；
  通过后记录 `topology_removal_deployment_status=verified`，此时 decommission write-routing 才会退休。
  `physical_removal_preflight` 只能在 deployment verification 之后使用，且只读取 apply 阶段持久化的 target endpoint
  manifest 定位已从当前 topology 删除的 drive root，不从当前 topology 反推。它会重新检查 job complete、data movement/source
  cleanup complete、cluster runtime convergence、deployment verified、无 active job、manifest 有效、endpoint 可达与物理残留为空；
  unknown node atom 会 fail-closed。结果输出 `removable`/blockers/examples，`physical_removal=false`，绝不删除文件、不改
  scheduler、不做物理 pool removal。可选 `--hardware-evidence` 只对 stored manifest endpoints 追加 sanitized drive
  hardware evidence（serial/WWID 仅保留 hash），输出 `drive_hardware_evidence_gate=false`，不改变 `removable`/blockers。
  `physical_remove` 只能在同一 ready gate 后显式运行，且必须传入匹配的 `--confirm-job-id`。它在 runtime topology
  mutation lock 内重跑 physical preflight，把 manifest hash 与 job/quarantine id 绑定，然后经 `Transport.quarantine_layout_roots/5`
  对每个 stored endpoint 做可恢复隔离：只移动 PG 已知 bucket root、`.versions`、`.uploads` 到
  `<drive>/.maxio-removal-quarantine/<quarantine_id>/...`，并写 `<drive>/.maxio-physical-removal.json` marker。
  若带 `--hardware-evidence`，同一锁内 preflight 的 sanitized evidence snapshot 会写入 job `physical_removal_results`，
  但不会写入每个 drive 的 `.maxio-physical-removal.json` marker，也不会作为 destructive gate。
  它会阻塞 unknown top-level directory、layout root 内 unexpected file、drive/root/source/destination symlink 与 unsafe path；
  成功后记录 `physical_removal_status=quarantined`、manifest hash、quarantine id、endpoint results 与计数，重复执行幂等返回
  `already_quarantined`。边界：不 hard delete、不清空 quarantine、不移动整个 drive root、不触碰 `.tmp`，不接 scheduler，
  不提供 secure erase、SMART/hardware identity 或实际物理 pool removal。
  `physical_purge_preflight` 是只读 hard-delete safety gate：要求 job 已 quarantined、deployment/removal 证据仍有效、
  endpoint reachable、source layout 未重新出现、quarantine marker 匹配、purge tree 内无 symlink/unsupported path，
  且 `physical_removal_completed_at + retention-hours` 已到达。`physical_purge` 必须同时确认 job id 与 quarantine id，
  并在同一个 runtime topology mutation lock 内先验证所有 endpoint，再删除每个
  `<drive>/.maxio-removal-quarantine/<quarantine_id>`，最后写 `<drive>/.maxio-physical-purge.json`。
  它只删除 quarantine root，不删除 drive root、不删除 physical-removal marker、不改 topology/deployment、不接 scheduler；
  保留期默认 168 小时，可由 operator 显式传 `--retention-hours`。
  `rebalance.workflow` 是只读 workflow auditor：从 job audit、runtime topology 与当前 deployment topology（config 或 DB active revision）
  计算 phase / next_action / destructive_next_action / set_retired / pool_retired。decommission job 只有当 target set 和 removed pool ids
  同时从 runtime 与 deployment topology 消失，且 job 已完成 physical quarantine purge，才报告 retired。rebalance job 会按
  copy_pass → source_cleanup → rebalance_closure 汇报；closure 阶段只读扫描 PG object placement，对比当前 Router set，
  并统计 missing/unknown/stale placement、routing mismatch 与 active MPU placement/hash 风险，干净时报告 `rebalance_complete?=true`。
  blocked closure 的 `next_action` 是 operator-facing 映射：job/closure 失败先指向
  `mix maxio.rebalance.status --job-id <job-id> --json`；权威源或 runtime topology 不可用时指向只读
  `rebalance.workflow` 重查；存在其它 active job 时指向该 active job 的 workflow；placement/MPU blocker 指向
  `mix maxio.rebalance.verify_closure --job-id <job-id> --json`（operator 先按 examples 修复或完成/abort 受影响 MPU 后再复核）；
  纯 routing mismatch 才指向 `mix maxio.rebalance.start --json` 创建新的普通 rebalance 计划。它不执行 copy/cleanup、
  不自动改 PG placement/hash、不自动 abort MPU、不做 topology apply、deployment persistence、physical remove 或 purge。
  `rebalance.verify_closure` 复用同一 live audit，在 job runner lock 与 runtime topology read lock 下把一次 point-in-time
  closure 证据写回 `cluster_rebalance_jobs.rebalance_closure_*`；干净时标记 `verified`，有 placement/MPU blocker 时标记
  `blocked` 且可在 operator 修复后重试。它不是 read-only（会写审计字段），但仍不移动数据、不删除 shard、不改 topology、不隔离/清理物理 root。
  `Maxio.Cluster.Rebalance.Scheduler` 可在 `auto_runtime_topology: true`、`auto_deployment_topology: true`
  且 `:topology_source == :db` 时调用 `TopologyMutation.apply_removal_cluster/2`，为已完成 source cleanup 的
  decommission job 执行同一套 cluster runtime convergence apply；该阶段会剥离 `topology`、`nodes`、`node_apply_fun`、
  stale expected hash、runtime/deployment topology override 与 raw `lock_opts`，避免 scheduler 用测试级 override
  伪造 topology mutation。cluster convergence audit 记录后，scheduler 再调用 `TopologyMutation.finalize_removal_deployment/2`，
  在同一个 runtime topology lock 内完成 DB persistence + deployment verification；该最终阶段同样不接受 low-level
  runtime/deployment topology override，expected proposed hash 始终来自 job audit。边界：两个自动阶段默认关闭，不删 shard、
  不删除物理 pool、不提供 Raft/all-or-nothing consensus。`auto_rebalance_closure: true` 是单独 opt-in，只会为已完成
  copy/source cleanup 的 rebalance job 调用 `Closure.verify_once/2` 记录 placement closure audit，不触发 decommission topology
  或 physical 阶段。
- `Maxio.Cluster.Rebalance.Scheduler`：默认随监督树启动但不调度；`config :maxio, :rebalance_scheduler, enabled: true`
  后按 `interval_ms` 在 cluster singleton lock 下选择下一个 runnable job。planned/running 的 rebalance/decommission
  copy-pass 优先调用同一个 `Runner.run_once/2`；copy 完成且无其它 active job 阻挡时，才调用
  `SourceCleanup.cleanup_once/2` 推进 source cleanup。scheduler 的 destination 配置只作用于 decommission；
  rebalance job 会剥离 `destination_set_id`/`destination_sets`/`auto_destination`，继续逐对象按 current router 选目标。
  `auto_runtime_topology: true` 只有在 `auto_deployment_topology: true` 且 `:topology_source == :db` 时才会为
  已完成 source cleanup 的 decommission job 复用 `TopologyMutation.apply_removal_cluster/2`，记录 cluster runtime convergence
  审计；随后 `auto_deployment_topology: true` 会复用 `TopologyMutation.finalize_removal_deployment/2` 把 converged runtime
  topology 写入 active DB revision 并完成 deployment verification/write-routing retirement。两个自动阶段默认关闭，
  且不做物理 pool removal。`auto_rebalance_closure: true` 默认关闭；开启后只会写 rebalance closure audit evidence。
- `Maxio.Cluster.SchedulerRuns` / `mix maxio.scheduler.status [--scheduler fresh_drive_heal|rebalance] [--runs N] [--state-only] [--cadence] [--since-minutes N] [--expected-interval-ms N] [--stale-after-ms N] [--json]`：
  为 fresh-drive heal scheduler 与 rebalance scheduler 增加持久化 run ledger / state row。每次手动 `run_now/1`
  或后台 scheduled pass 都会追加 `cluster_scheduler_runs` 取证，并 upsert `cluster_scheduler_states`
  的 effective health、连续失败、退避截止与告警状态；`no_runnable_job` 归类为 idle，`lock_unavailable` 与 backoff skip
  归类为 skipped，不计入 destructive failure，且已有 effective state 时只写入独立 skipped run evidence，不覆盖上一条有效
  ok/blocked/failed/backoff 状态。达到 `config :maxio, :scheduler_ledger, failure_threshold: N`
  后，自动 scheduled pass 会在 `backoff_ms` 窗口内跳过 runner；手动 `run_now/1` 仍可用于 operator 修复与取证。
  `--cadence` 为只读 scheduled-only 健康观察器：manual `run_now/1` 不会被当成后台心跳，`lock_unavailable` 与 backoff
  等 skipped scheduled run 只计入证据窗口但不能让 health 变绿；alert/backoff/blocked/failed 优先于“最近有 run”。cadence 输出会列出
  scheduled/effective/healthy/skipped node 集合、lock loser node/count 与 last effective scheduled node，且忽略 `finished_at > now`
  的未来 run，便于长跑后判断哪些节点实际参与、哪些只是 singleton lock loser。本地 cadence 测试覆盖 fresh-drive 与 rebalance 两个 scheduler 同轮竞争只允许一个 runner 进入；`MAXIO_RUN_PEER_LOCK=1`
  时可运行 `scheduler_peer_cadence_test` 通过真实 `:peer` LockServer 取证。alert sink 失败只注记本次 run summary 的 `alert_emit_error`，不会让 scheduler 崩溃。该 ledger 不启用 scheduler、不移动数据、
  不清理 shard、不改 topology、不触发 physical remove/purge。rebalance closure blocked report 的 `next_action` 会进入 ledger summary，
  并继续走 summary redaction / byte bound。
  `mix maxio.scheduler.evidence [--scheduler fresh_drive_heal|rebalance] [--from <iso8601> --until <iso8601> | --since-minutes N] [--expected-nodes node_a,node_b] [--min-effective-nodes N] [--require-lock-loser] [--require-rollups] [--fail-on-attention] [--json]`
  可把长跑后的 cadence/node/lock-loser/blocked next_action/rollup 覆盖情况汇总成只读 gate artifact；它只启动 Repo 读取 ledger，
  不 `app.start`、不启动 scheduler、不运行 runner、不写 DB。evidence window 使用 `[from, until)` 半开语义，与 rollup/retention 对齐；
  expected node 缺席、effective node 不足、要求 lock-loser 却缺证据、或 `--require-rollups` 缺 scheduled rollup 时都会 fail-closed；
  `--fail-on-attention` 会把 blocked/failed run warnings 也变成非零退出，供长跑演练使用。
  `docs/superpowers/runbooks/m8_scheduler_live_rehearsal.md` 记录真实多节点演练步骤；`scripts/m8_scheduler_live_rehearsal.exs`
  只包装 evidence gate 并写归档 JSON，不启动 scheduler 或执行修复。
  `mix maxio.scheduler.rollup --from <iso8601> --until <iso8601> [--scheduler fresh_drive_heal|rebalance] [--trigger manual|scheduled] [--window-minutes N]`
  可把已关闭窗口写入 `cluster_scheduler_run_rollups` durable audit；`mix maxio.scheduler.status --rollups`
  只读查看。`mix maxio.scheduler.prune --scheduler <name> --trigger manual|scheduled --from <iso8601> --until <iso8601> --window-minutes N --dry-run`
  只做 prune preflight；真实删除必须追加 `--confirm-prune --confirm-scheduler <same> --confirm-trigger <same>`。
  `--confirm-from <same> --confirm-until <same> --confirm-window-minutes <same>`。
  prune 只删除 count/source digest/source max updated_at 与 durable rollup 完全一致的 raw run id 集合；任一窗口缺 rollup、
  digest 不一致、仍处于 open/current window、或命中 `cluster_scheduler_states.last_run_id` / latest scheduled/effective/healthy
  等保护 run 时，整次 range fail-closed 且不做 partial delete。`record`、实际 `rollup` 与 prune 共享 scheduler+trigger
  级 transaction advisory lock；已 prune 的窗口禁止被 rollup 重算覆盖，也拒绝 late raw run 写入。
  `mix maxio.scheduler.retention --scheduler <name> --trigger manual|scheduled --retain-days N --window-minutes N --dry-run`
  可按保留期生成默认关闭的旧 ledger 明细清理计划；真实执行必须追加 `--enable-retention --confirm-retention`
  以及匹配的 scheduler/trigger/retain-days/window-minutes/cutoff 确认。retention 不自动创建 rollup、不删除 rollup rows、
  不接后台 timer；缺 rollup 或 prune 复核失败时 fail-closed。
- `Maxio.Cluster.PressureAggregator`：监督树内缓存 peer node 的 `IOPressure.local_snapshot/0`，
  后台按 `config :maxio, :io_pressure` 刷新；scrubber/fresh-drive gate 只读本地计数 + 新鲜缓存，
  peer timeout/stale/down 均 fail-open，不在对象间同步 RPC。
- `Maxio.Cluster.Scrubber.Throttle`：token-bucket object pacing 后追加 adaptive IO gate；
  当 `adaptive_io: true` 且所选 `io_load_source`（默认 `cluster-combined`）超过 `max_live_requests` 时，scrubber 在对象之间按
  `io_pause_ms` 分段等待，单对象最多等待 `io_max_pause_ms`。`--no-throttle` 会同时关闭 token/fixed/adaptive sleeps。
- `Maxio.Cluster.DriveHealth`：监督树内 node-local registry，按 `{node, drive}` 记录结构化
  reachability probe；scrubber topology 轮使用 root-drive probe，scanner 在既有 `list_dir/3`
  reachability 探针处同步观察。单次失败只进入 `suspect`，超过 `offline_after_ms` 才进入 `offline`。如果离线期间
  erasure set 仍达到 write quorum，恢复后保留 `heal_required?` 标记，供 `FreshDriveHeal` workflow 消费。
  该状态当前是运行时观测信号，不改变 S3 请求路由或 quorum 语义。
- `Maxio.Cluster.DriveIdentity`：每个本机 drive root 写入 `.maxio-drive-identity.json` 软件 UUID marker，
  并用 `cluster_drive_identities` 按 `{node_name, drive_path}` 持久化最近观察到的 UUID。同一路径看到新 UUID
  会记录 `previous_drive_uuid`、递增 generation、置 `identity_heal_required`，并折入 `DriveHealth.heal_required?`；
  这是 same-path replacement detection，不是硬件序列号或自动 rebalance。
- `mix maxio.drive.identities [--heal-required] [--summary-only]`：读取持久化 drive identity inventory；
  `--probe` 会按当前 topology 主动探测并持久化观察结果，默认会为可达的本机或远端 endpoint 创建缺失的
  `.maxio-drive-identity.json`；`--probe --no-create-missing` 用于只取证缺失 marker，`--marker-file <name>`
  可临时指定 marker 文件名。
- `mix maxio.drive.hardware_evidence [--summary-only] [--drive <path>] [--json] [--show-raw] [--smart]`：
  读取只读硬件/设备证据并默认隐藏 raw serial/WWID。它与 `maxio.drive.identities` 分离，不持久化、
  不参与 same-path replacement detection，也不作为任何 destructive operation 的自动判定。`--smart`
  仅增加默认关闭的 SMART allowlist 子证据，失败 fail-open，默认不暴露 raw SMART identity 或完整 smartctl JSON。
- `Maxio.Cluster.FreshDriveHeal` / `mix maxio.heal.fresh_drives`：显式运维入口，枚举 PG inventory
  中落到 affected erasure set 的对象/版本（默认含 delete marker；优先对象持久化 placement，旧行回退 router），复用 `Maxio.Cluster.Heal` 修复缺失 shard
  或 marker sidecar；仅在完整、非 bucket 限定、非 current-only、非 dry-run 且无 missing/skipped/unrecoverable/error 的 pass
  后清除 `DriveHealth.heal_required?`。`--dry-run`、`--bucket`、`--max-objects`、`--current-only` 都不会清 marker。
  `--rebalance-if-needed` 会在同一 CLI 输出中记录 post-heal rebalance enqueue evidence；`--rebalance-advance-steps N`
  会 opt-in 通过普通 rebalance scheduler 对同一个新建 rebalance job 做有界 copy/source-cleanup 步进；`--rebalance-verify-closure`
  会把默认步数设为 3 并开启 rebalance closure verifier。
- `Maxio.Cluster.FreshDriveHeal.Scheduler`：默认随监督树启动但不调度；`config :maxio, :fresh_drive_heal_scheduler, enabled: true`
  后按 `interval_ms` 在 cluster singleton lock 下自动调用同一个 `FreshDriveHeal.run_once/1` workflow。
  默认 `probe_drive_health: true` 会先刷新 topology drive probes；`run_now/1` 可经 IEx/测试手动触发。
  `auto_rebalance_after_heal: true` 默认关闭；显式开启后，只有 clean 且清除 marker 的 pass 才通过
  `Rebalance.Jobs.start_rebalance_if_needed/1` 创建普通 durable rebalance job，且仅在 PG placement 与当前 router 存在
  routing mismatch 时创建，placement fallback / active job 仍 fail-closed 或记录 skip。`auto_advance_rebalance_after_heal: true`
  默认也关闭；显式开启后只对本轮创建的同一个普通 rebalance job 调 `Rebalance.Scheduler.run_steps/1`，受
  `rebalance_advance_max_steps` 限制，并可通过 `rebalance_advance_opts: [auto_rebalance_closure: true]` 记录 closure
  evidence。这不是硬件/物理 replacement identity、decommission、topology mutation 或 destructive automation。
- `Maxio.Cluster.Replacement.Workflow` / `mix maxio.replacement.workflow`：replacement runbook/auditor 入口。
  默认只读输出 `DriveHealth` heal-required 摘要、latest rebalance workflow evidence 与下一条安全命令；
  `--probe` 才刷新 drive probes，`--heal` 才调用 fresh-drive scheduler bridge。`--rebalance-if-needed`、`--advance-steps N`
  与 `--verify-closure` 只在同一次显式 `--heal` run 中生效，并复用上面已有的 rebalance enqueue / same-job bounded drain /
  closure verifier；`--verify-closure` 未给步数时默认 3 步。该入口不接受任意 job_id advance，不执行 decommission、
  topology mutation、deployment finalization、physical remove 或 purge。`--fail-on-blocked` 会先输出 JSON/text，再把
  `status=blocked|failed` 变成非零退出；`mix run --no-start scripts/m8_replacement_live_rehearsal.exs -- ...`
  会把该 workflow 输出归档为 replacement rehearsal JSON，并额外要求 `blockers=[]` 且 `next_action=none` 才通过；
  默认 `--dry-run` 不通过 live gate，除非显式 `--allow-dry-run-success` 作为非 live 证据归档。该 CLI 使用最小 runtime
  启动，不调用 `app.start`，避免 operator 环境中已启用的后台 scheduler 在演练子进程里并发运行。
- `Maxio.Cluster.Replacement.AutomationProfile` / `mix maxio.replacement.automation_status [--fail-on-blocked] [--fail-on-attention] [--json] [--require-scheduler-evidence ...]`：
  只读检查生产 replacement 自动化配置是否形成完整链路：fresh-drive heal scheduler 探测 replacement marker、clean heal 后 enqueue durable
  rebalance、rebalance scheduler 推进 copy/source cleanup、closure verifier 记录 placement closure、两个 scheduler 都有 ledger 取证。
  默认配置会报告 blocked；只有显式启用 fresh-drive scheduler、`auto_rebalance_after_heal`、rebalance scheduler、`auto_source_cleanup`、
  `auto_rebalance_closure` 与 scheduler ledger 后才报告 ready。该 gate 不调用 `app.start`、不启动 scheduler、不运行 heal/rebalance、
  默认不读写 DB、不改 topology/deployment、不触碰 physical layout；显式 `--require-scheduler-evidence` 时仅启动 Repo 读取已有
  scheduler ledger，并复用 `mix maxio.scheduler.evidence` 的 scheduled-only 语义（`--since-minutes`、`--expected-interval-ms`、
  `--stale-after-ms`、`--expected-nodes`、`--min-effective-nodes`、`--require-lock-loser`）确认 fresh-drive/rebalance 后台自动化近期有证据。
  `replacement.workflow` 的默认 audit 会附带该 profile 作为生产化缺口提示，但不会把配置或 scheduler evidence 未 ready 当成一次
  replacement 操作失败。
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

- 完整 MinIO data-scanner parity：硬件/物理 drive identity 已有只读 evidence CLI，physical removal preflight/remove
  已可 opt-in 绑定 sanitized hardware evidence 审计快照；replacement runbook/auditor CLI 已能默认只读审计并显式串起
  fresh-drive heal、rebalance enqueue、same-job bounded drain 与 closure verifier，并可通过
  `scripts/m8_replacement_live_rehearsal.exs` 归档严格 artifact gate，并可用 `mix maxio.replacement.automation_status` 检查生产自动化配置链路是否 ready；
  生产级全自动策略仍待续作。decommission 主路径已有只读 workflow/pool-retired
  auditor 与非空端到端取证，rebalance 已有只读 placement closure auditor 与 opt-in 持久化 closure verifier。
  当前已有保守 token-bucket object pacing（`max_objects_per_sec` + `object_burst`，允许 burst 后限制下一次对象扫描开始），
  本节点/缓存 peer 的 S3 handler in-flight + ShardServer storage-op + OS/device-level drive pressure 自适应对象间暂停（`--io-load-source s3-in-flight|storage-ops|drive-device-io|combined|cluster-s3-in-flight|cluster-storage-ops|cluster-drive-device-io|cluster-combined`）、
  node-local ShardServer IO latency/throughput telemetry、Linux `/proc/diskstats` fail-open drive pressure telemetry、filesystem capacity/free-space stats、node-local drive-offline 长窗口观测、software UUID same-path replacement detection，
  手动 `mix maxio.heal.fresh_drives` marker 消费、默认关闭的 fresh-drive heal scheduler（可 opt-in 在 clean marker-clearing pass
  后 enqueue 普通 rebalance job，并可对该 job 做 bounded same-job copy/cleanup/closure drain），以及只读
  `mix maxio.replacement.workflow` runbook/auditor（默认只读，显式 flags 才 probe/heal/enqueue/advance/closure），以及只读
  `mix maxio.rebalance.plan` logical inventory（优先对象持久化 placement，旧行计 `placement_fallbacks`，并统计
  `routing_mismatches`）
  和 `mix maxio.rebalance.start|status|cancel` 持久化 job 控制面，以及受限前台
  `mix maxio.rebalance.run` decommission/rebalance copy-pass（job-level singleton lock + monotonic progress/cursor）
  与 `mix maxio.rebalance.cleanup` guarded decommission/rebalance source-shard cleanup，并有默认关闭的
  `Maxio.Cluster.Rebalance.Scheduler` 后台推进 copy/cleanup，并有只读
  `mix maxio.rebalance.preflight_removal` / `mix maxio.rebalance.plan_removal` 生成移除前安全证据与 proposed topology artifact，
  显式 `mix maxio.rebalance.apply_removal --yes` 把 proposed topology 安装到当前 BEAM runtime，
  `mix maxio.rebalance.apply_removal_cluster --yes` 证明原始 topology 参与节点均完成 cluster runtime convergence，
  `mix maxio.rebalance.persist_removal_deployment --runtime-node <node> --expected-proposed-topology-hash <sha256> --yes` 把收敛后的 proposed topology
  持久化为 active DB deployment revision，以及 `mix maxio.rebalance.verify_removal_deployment` 核验并退休 write-routing；
  也可通过默认关闭的 `rebalance_scheduler.auto_runtime_topology` + `auto_deployment_topology` 在 DB topology source
  下自动执行 cluster runtime apply 与最后的 single-lock finalization gate；deployment verified 后可运行
  `mix maxio.rebalance.physical_removal_preflight --hardware-evidence` 取得只读物理移除 + sanitized hardware evidence，
  或显式运行 `mix maxio.rebalance.physical_remove --confirm-job-id <job-id> --hardware-evidence` 把 Maxio layout roots 隔离到
  `.maxio-removal-quarantine/<id>` 并写 physical-removal marker；保留期满足后可运行
  `mix maxio.rebalance.physical_purge --confirm-job-id <job-id> --confirm-quarantine-id <id>` 删除对应 quarantine root
  并写 physical-purge marker；`mix maxio.rebalance.workflow --job-id <job-id>` 可只读确认非空 decommission 主路径已达到
  set/pool retired audit closure，也可确认 rebalance job 已完成 copy、source cleanup 与 PG/router placement closure；
  `mix maxio.rebalance.verify_closure --job-id <job-id>` 可把 rebalance closure 的点-in-time 证据写回 job row；
  `mix maxio.scheduler.status --cadence` 可查看 fresh-drive/rebalance scheduler 的持久化 run ledger、effective health、连续失败、退避窗口、告警状态、scheduled-only overdue 健康与 node 参与度/lock loser 证据；
  `mix maxio.scheduler.evidence --fail-on-attention` 可把长跑窗口变成机器可判定的只读 gate artifact（expected nodes、min effective nodes、lock-loser、blocked next_action、可选 rollup 覆盖），
  不启动完整 app、不写 ledger；`mix run --no-start scripts/m8_scheduler_live_rehearsal.exs -- ...`
  可把该 gate 输出归档为 rehearsal JSON；
  `mix run --no-start scripts/m8_replacement_live_rehearsal.exs -- --heal --rebalance-if-needed --advance-steps N --verify-closure`
  可把 replacement/rebalance operator 闭环归档为严格 JSON artifact，只有 workflow 无 blockers 且无剩余 next_action 才通过；显式追加
  `--require-scheduler-evidence` 与 `--scheduler-evidence-*` 参数时，还会 shell out 到
  `mix maxio.scheduler.evidence --json --fail-on-attention`，把 scheduled-only scheduler evidence、exit status 与 gate 结果打包进同一 artifact，
  由 `bundle_gate` 决定最终退出；`gate` 仍只表示本次 replacement workflow，不把 scheduler 健康混入一次手动修复结论。
  `mix maxio.scheduler.rollup --from <iso8601> --until <iso8601> [--window-minutes N]` 可显式把已关闭的 run ledger 窗口聚合进
  `cluster_scheduler_run_rollups`，`mix maxio.scheduler.status --rollups` 只读查看这些聚合窗口；`mix maxio.scheduler.prune --dry-run`
  可复核某个 scheduler+trigger+窗口 range 是否可删，真实 prune 需显式确认 scheduler/trigger/from/until/window。prune 只在 durable rollup 与 raw rows
  count/source digest/source max updated_at 完全一致、且不命中 state/cadence 保护 run 时删除 exact ids；它不改变 scheduler
  state/cadence/backoff/alert，任一窗口不满足条件则整次 range fail-closed。`mix maxio.scheduler.retention --dry-run`
  可按 retain-days/cutoff 规划旧 raw run 清理；真实 retention 仍需显式 enable/confirm，并复用同一 verified prune 内核，
  不自动补 rollup、不启用后台清理。
  已有默认关闭的 SMART allowlist 子证据；尚未接入硬件 service time/物理吞吐或物理 replacement identity、secure erase、
  真实硬件拔盘证明，或 replacement/rebalance 的生产级全自动策略与更多活体端到端取证。
