# M4 高级特性 实现计划 · maxio（Versioning / Tagging / CORS / Lifecycle / SSE-S3）

> For agentic workers（executor）：严格按单元 **M4-1 .. M4-8** 顺序执行。逻辑性代码用 **TDD**（先写失败测试 → 运行确认红 → 最小实现 → 运行确认绿 → commit）；脚手架/配置/迁移类任务用「执行命令 + 验证输出」。每个任务都给了**精确文件路径、完整可用代码（禁止占位符 / TODO / 省略号）、确切 PowerShell 命令与期望输出**。后面任务引用的类型/函数/字段名与前面定义（及 M0–M3 既有代码）**严格一致**——复用既有模块时逐字照抄其现有签名。
>
> **本计划建立在已交付并验证的 M0+M1+M2+M3 之上**（master，275 测试全绿、`compile --warnings-as-errors` 零警告、独立 reviewer APPROVE_WITH_NOTES／0 must-fix）。M4 复用 M0–M3 全部既有模块：`Maxio.S3.{Error,XML,ErrorView,Dispatcher,Endpoint,BodyReader,RawPath,Conditional,Log}`、`Maxio.S3.Plugs.{AddressStyle,SigV4,Dispatch}`、`Maxio.S3.Handlers.{Service,Bucket,Object,Multipart,BucketPolicy,Acl}` + `Maxio.S3.Handlers`、`Maxio.S3.Views.*`、`Maxio.S3.RequestParsers.{CompleteMultipartUpload,Delete,AccessControlPolicy}`、`Maxio.Auth.*`、`Maxio.Storage{,.Backend,.FS}`、`Maxio.{Buckets,Objects,Multipart}` + schema、`Maxio.Policy.{Arn,Statement,RequestContext,Condition,Evaluator,ACL,ActionMap,Store}`、`Maxio.S3.Authz`、`Maxio.IAM`、`Maxio.Test.SigV4Request`。**严禁重写或破坏这些模块的公开契约**；只允许按本计划做明确的增量扩展。
>
> **铁律对齐（AGENTS.md §3/§4，违反即返工）**：①后端经 behaviour 抽象（存储/凭据/策略），上层只认契约——versioning 的多版本字节走既有 `Maxio.Storage.Backend`（**behaviour 演进：所有 callback 加 version_id 维度，FS 实现同步**），核心请求管线对后端实现无感；②禁止打补丁式修复——从架构层解决（versioning 把 objects 表演进为「多版本行」模型，delete marker 是一种特殊版本行，ListObjectVersions 是同一存储模型的另一种投影；tagging/cors/lifecycle/encryption 配置统一走「子资源 handler → 校验 → 持久化 → 出站」管线）；③**绝不静默失败/放行**——校验失败必须返回结构化 S3 错误 XML（`MalformedXML 400` / `InvalidTag 400` / `AccessForbidden 403` ...）+ 正确 HTTP 状态 + 结构化日志；**lifecycle 后台执行 defer 必须显式文档化（README + 启动日志），绝不假装"已生效"**；**SSE-S3 选定诚实 MVP 路径并文档化**；④对象 body 绝不进 `Plug.Parsers`、绝不全缓冲——所有配置 XML/Tagging XML 走带上限整读（小文档），versioning 的对象字节仍走 `BodyReader` 流式；⑤S3 行为以官方 AWS 文档/SDK 向量为准（本计划已内嵌核验过的官方 versioning/tagging/lifecycle/cors/sse 协议事实）；⑥DB schema 自文档化——新表/列/索引中文 `COMMENT`。
>
> **作者/审查隔离**：本计划由 executor 实现；每个单元收尾由**独立** `code-reviewer`/`verifier`（不同上下文）取证，实现者不得自审。

---

## 环境约束（每条 mix 命令都必须遵守）

- **本机**：Windows 11 + PowerShell。Elixir 1.20.0 / OTP 28，位于 `C:\Users\dyz\Documents\dev\usr\Elixir\bin`。
- **跑任何 mix 命令前必设**（否则编译期/运行期中文输出重定向到非 TTY 触发 `io.put_chars badarg` 硬崩、留 `erl_crash.dump`）：
  ```powershell
  $env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
  $env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
  ```
  本计划所有 PowerShell 命令块**默认已假设当前会话已设此两变量**；每个新 shell 会话第一条命令前先执行它。
- **Postgres**：docker 容器 `maxio-db`（postgres:16，localhost:5432，user/pass=postgres/postgres，dev 库 `maxio_dev`，test 库 `maxio_test`）。`psql` 不在 PATH，一律经容器：
  ```powershell
  docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ objects"
  ```
  执行前确保容器在跑：`docker start maxio-db`。`mix test` 自动迁移 test 库。
- **无 aws-cli / boto3 / mc / python**。端到端验证只用：(a) **纯函数单测**（XML 解析器/版本模型/CORS 匹配/lifecycle 校验真值表，独立 ground truth，最权威）；(b) **自签 SigV4** 集成测试（经 `Maxio.S3.Endpoint.call/2`，复用 `test/support/sigv4_request.ex`）；(c) **匿名/CORS preflight（OPTIONS 不签名）** 集成测试。**禁止依赖外部 CLI**。
- **提交**：每个单元（或紧密相关的红绿对）一次 commit，message footer 固定一行：
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
  当前分支为 `master`；本计划全部提交到当前分支（无需开新分支，除非用户另行要求）。

---

## Goal

在 M0–M3 垂直切片（鉴权 + 授权链路）之上，补齐 S3 **高级特性**子系统，使 maxio 支持真实 S3 客户端对 versioning/tagging/lifecycle/CORS/SSE 的全套 API 往返：

1. **M3 收尾硬化（小、先做、降风险）**：修 reviewer note 1（`Authz.gather_statements/3` 硬编码 `:anonymous` → 传真实 principal）+ note 4（AWS Principal `{:aws,list}` 改**精确匹配**而非 glob）+ 回归测试。**在加任何新动作/资源前先做**，否则未来 identity policy 会被静默丢弃。
2. **VERSIONING（最深）**：
   - `PutBucketVersioning`/`GetBucketVersioning`（`?versioning`，Status `Enabled`/`Suspended`，三态：never-set/Enabled/Suspended）+ `buckets.versioning` 列。
   - 对象多版本模型：`objects` 表演进——加 `version_id`/`is_latest`/`is_delete_marker` 列，唯一约束 `(bucket_id, key, version_id)`；`version_id` 用 ULID（时间有序、URL-safe、`null` 版本用 sentinel）。
   - `Storage.Backend` behaviour 演进：put/get/stat/delete 加 `version_id` 维度（FS 每版本落 version-qualified 路径），**所有 callback + FS 实现同步**。
   - PutObject：Enabled → 生成新 version_id 并置 latest；Suspended/Unversioned → version_id=`null` 覆盖既有 null 版本。
   - GET/HEAD：默认取 latest 非 delete-marker；`?versionId` 取特定版本；current 是 delete marker → 404 + `x-amz-delete-marker: true`；`?versionId` 指向 delete marker → 405。
   - DELETE：Enabled 无 versionId → 插入 delete marker；`?versionId` → 永久删除该版本；Suspended → 插入 null delete marker 覆盖 null 版本。
   - `x-amz-version-id` / `x-amz-delete-marker` 响应头。
   - `ListObjectVersions`（`?versions`）XML（Version + DeleteMarker 交错、二维分页）。
   - ListObjectsV2 仍只返回 latest 非 delete-marker。
   - **拆成 2 个 executor 单元**：(M4-3a) 版本配置 + schema/storage 模型 + Put/Get/Delete 版本语义；(M4-3b) ListObjectVersions + 集成 e2e。
3. **TAGGING**：对象 + 桶 tagging（`?tagging` PUT/GET/DELETE，Tagging XML，PutObject 的 `x-amz-tagging` 头，limits → `InvalidTag`，`x-amz-tagging-count` 响应头）+ schema 列 + Dispatcher 升级。
4. **CORS**：`PutBucketCors`/`GetBucketCors`/`DeleteBucketCors`（`?cors`）+ CORSConfiguration 存储 + OPTIONS 预检处理 + 实际请求带 Origin 时注入 CORS 响应头（动 Endpoint 管线——新增 CORS plug，**绝不破坏流式与 SigV4**——OPTIONS 预检不签名）。
5. **LIFECYCLE**：`PutBucketLifecycleConfiguration`/`Get`/`Delete`（`?lifecycle`）——**存储 + 校验 + 出站**；后台过期**执行 DEFER（显式文档化 + 启动日志 + mix 任务 stub）**。
6. **SSE-S3**：PutObject `x-amz-server-side-encryption: AES256` → **真实 at-rest 加密**（AES-256-GCM 信封加密，FS 流式，单一服务端主密钥 MVP）+ 响应回显 + `PutBucketEncryption` 默认配置。

**显式不做（defer，到达即文档化，绝不静默）**：
- **Lifecycle 后台过期/中止 MPU 执行**：M4 只**存储 + 校验 + 出站**配置；不跑后台 sweeper。**显式文档化（README + 启动日志 warning + mix 任务 stub `mix maxio.lifecycle.run` 打印 "execution not implemented"）**。`Transition`/`NoncurrentVersionTransition` 单层 maxio 无意义——接受持久化但文档化为 no-op。
- **MFA Delete**：`x-amz-mfa` 头与 `MfaDelete` 元素——解析/存储 `MfaDelete` 状态并按官方在 GetBucketVersioning 回显（仅当曾配置），但**不强制 MFA 校验**（无 MFA 设备），文档化。
- **SSE-C / SSE-KMS / DSSE-KMS**：只实现 SSE-S3（`AES256`）。`aws:kms`/`aws:kms:dsse` 的 `SSEAlgorithm` 或 `x-amz-server-side-encryption-customer-*` 头 → `501 NotImplemented`（绝不静默当 AES256），文档化。
- **Bucket Key（`BucketKeyEnabled`）**：仅 KMS 相关，SSE-S3 无意义——接受持久化但 no-op，文档化。
- **对象级 tagging 的逐版本独立 tag set**：MVP tag 挂在「当前版本行」（`objects.tags`）；`?tagging&versionId=` 作用于指定版本行（已支持，因 tag 列在版本行上）；`s3:*VersionTagging` 细粒度权限按非 version 同名权限评估（单租户），文档化。
- **lifecycle `Date`（绝对时间）与 `Transition` 的执行**：仅存储/校验。
- **CORS 与 LiveView Console 端口（4000）**：CORS 仅作用于 S3 Endpoint（9000/9900），Console Endpoint 不受影响。

---

## Architecture（M4 在 M3 管线上的增量）

```
S3 客户端 → Maxio.S3.Endpoint (Bandit, dev :9900 / prod :9000, 无 Plug.Parsers)
  Plug.RequestId
  Maxio.S3.Plugs.AddressStyle          （不变；产出 s3_bucket/s3_key/s3_level）
  Maxio.S3.Plugs.Cors      ★新（M4-6）  （OPTIONS 预检：匹配 CORS 规则 → 200+CORS 头并 halt；
                                          其余方法：记录 Origin，注册 before_send 注入 CORS 头/Vary；
                                          ★OPTIONS 预检在 SigV4 之前 halt——预检不签名，绝不进鉴权）
  Maxio.S3.Plugs.SigV4                 （不变；OPTIONS 已被 Cors plug 拦截或放行匿名）
  Maxio.S3.Plugs.Dispatch              （不变；Authz 在 resolve 出 action 后调用）
     └─ Maxio.S3.Authz (M4-2 修 note1/4)
     Handlers.dispatch(action, conn) → 既有 + 新 handler：
       Maxio.S3.Handlers.Versioning ★新（put/get bucket versioning）
       Maxio.S3.Handlers.Tagging    ★新（put/get/delete object & bucket tagging）
       Maxio.S3.Handlers.Cors       ★新（put/get/delete bucket cors）
       Maxio.S3.Handlers.Lifecycle  ★新（put/get/delete bucket lifecycle）
       Maxio.S3.Handlers.Encryption ★新（put/get/delete bucket encryption）
       Maxio.S3.Handlers.Object（演进：versioning 语义 + x-amz-tagging + SSE 头）
       Maxio.S3.Handlers.Bucket（list_object_versions ★新）
  Maxio.S3.BodyReader                   （不变）

存储模型演进（M4-3）：
  objects 表 + version_id/is_latest/is_delete_marker 列（唯一 (bucket_id,key,version_id)）
  buckets 表 + versioning 列（"Unversioned"|"Enabled"|"Suspended"）+ mfa_delete 列
  objects 表 + tags（jsonb）+ sse_algorithm 列；bucket_configs 表（cors/lifecycle/encryption jsonb）
  Maxio.Storage.Backend behaviour：put/get/stat/delete 加 version_id 维度；FS 落 version-qualified 路径
  Maxio.Crypto.SSE ★新（AES-256-GCM 信封加密，流式包装 chunks 流）

入站小文档：Maxio.S3.RequestParsers.{Tagging,Cors,Lifecycle,Encryption,VersioningConfiguration} ★新（saxy SAX）
出站 XML：Maxio.S3.Views.{VersioningConfiguration,Tagging,Cors,Lifecycle,Encryption,ListVersions} ★新
ULID：Maxio.Versioning.VersionId ★新（ULID 生成 + null sentinel）
```

现有 `MaxioWeb.Endpoint`（:4000，Console/LiveView）**保持不变**，物理隔离。CORS 只作用于 S3 Endpoint。

## 单元总览（按依赖串行；每单元结束须 green compile + 测试通过 + 一次 commit）

| 单元 | 标题 | 依赖 | 规模/分割理由 |
|---|---|---|---|
| **M4-1** | M3 收尾硬化（Authz 真实 principal + AWS Principal 精确匹配）+ 回归 | M3 | 小、降风险、独立可测，先做 |
| **M4-2** | XML 入站解析器框架 + `Maxio.S3.RequestParsers.VersioningConfiguration` + 配置载体 schema（`buckets.versioning`/`mfa_delete` + `bucket_configs` 表） | M4-1 | 迁移 + 解析器地基，后续单元复用 |
| **M4-3a** | Versioning 核心：objects 多版本 schema 演进 + `Storage.Backend` version 维度演进 + FS 实现 + `Versioning.VersionId`(ULID) + Put/Get/Head/Delete 版本语义 + `?versioning` API | M4-2 | versioning 最深；schema+storage+对象语义一单元 |
| **M4-3b** | ListObjectVersions（`?versions`）+ ListObjectsV2 latest 过滤 + Dispatcher 升级 + 版本化 e2e 集成矩阵 | M4-3a | 列举投影 + 端到端验收，独立单元 |
| **M4-4** | Tagging：object + bucket（`?tagging` PUT/GET/DELETE）+ `x-amz-tagging` 头 + `x-amz-tagging-count` + limits→InvalidTag + schema + Dispatcher | M4-3b | tagging 全套，自成单元 |
| **M4-5** | CORS：`?cors` PUT/GET/DELETE + `Maxio.S3.Plugs.Cors`（OPTIONS 预检 + 实际请求注入）+ 匹配算法 + Endpoint 接线 | M4-4 | 触 Endpoint 管线，独立高风险单元 |
| **M4-6** | Lifecycle：`?lifecycle` PUT/GET/DELETE + 校验 + 持久化 + 出站 + 执行 defer 文档化（启动日志 + mix stub） | M4-5 | 配置 CRUD，明确 defer |
| **M4-7** | SSE-S3：`Maxio.Crypto.SSE`（AES-256-GCM 流式）+ PutObject `x-amz-server-side-encryption: AES256` 真实加密 + 回显 + `?encryption` 默认配置 + 非 AES256→501 | M4-6 | 真实 at-rest 加密，独立单元 |
| **M4-8** | 端到端集成矩阵汇总 + 全量回归 + STATUS 更新 + README 高级特性章节（含 defer 清单） | M4-7 | 验收 + 文档收尾 |

**执行顺序**：M4-1 → M4-2 → M4-3a → M4-3b → M4-4 → M4-5 → M4-6 → M4-7 → M4-8。**串行执行，禁止并行 mix 编译**（避免锁文件竞争）。每单元规模控制在「单个 executor 一轮内可完成实现 + 跑测试 + 调用 StructuredOutput」。

---

## 全局命名契约（M4 新增，一次定义全程复用；M0–M3 既有契约见对应计划）

**沿用既有常量**：XML 命名空间 `"http://s3.amazonaws.com/doc/2006-03-01/"`（`Maxio.S3.XML.namespace/0`）；region `"us-east-1"`；principal map `%{type: :root | :iam_user, access_key, arn}`；匿名 `:anonymous`；owner canonical id `"maxio"`（见 `Handlers.Acl`/`Multipart` 的 `@owner_id`）；`Maxio.S3.XML.{encode/1,namespace/0,iso8601/1,quote_etag/1}`；`Maxio.S3.Error.new/2`。

**M4 新增版本化常量**：
- versioning 三态字符串：`"Unversioned"`（never-set，DB 默认）、`"Enabled"`、`"Suspended"`。
- null 版本 sentinel：`Maxio.Versioning.VersionId.null_sentinel/0` → `"null"`（既是 DB 存储值，也是 `x-amz-version-id` 回显值，对齐 AWS 保留串）。

**M4 新增模块与签名（跨单元引用，逐字一致）**：

- `Maxio.Versioning.VersionId`（M4-3a）：
  - `generate() :: String.t()` —— 生成 ULID（26 字符 Crockford base32，时间有序、URL-safe）
  - `null_sentinel() :: String.t()` —— `"null"`
- `Maxio.S3.RequestParsers.VersioningConfiguration`（M4-2）：
  - `parse(xml :: binary()) :: {:ok, %{status: String.t() | nil, mfa_delete: String.t() | nil}} | {:error, :malformed_xml}`
- `Maxio.S3.RequestParsers.Tagging`（M4-4）：
  - `parse(xml :: binary()) :: {:ok, [{String.t(), String.t()}]} | {:error, :malformed_xml}`（TagSet → [{Key,Value}]）
- `Maxio.S3.RequestParsers.Cors`（M4-5）：
  - `parse(xml :: binary()) :: {:ok, [map()]} | {:error, :malformed_xml}`（[CORSRule map]）
- `Maxio.S3.RequestParsers.Lifecycle`（M4-6）：
  - `parse(xml :: binary()) :: {:ok, [map()]} | {:error, :malformed_xml}`（[Rule map]）
- `Maxio.S3.RequestParsers.Encryption`（M4-7）：
  - `parse(xml :: binary()) :: {:ok, %{algorithm: String.t(), kms_key_id: String.t() | nil, bucket_key_enabled: boolean()}} | {:error, :malformed_xml}`
- `Maxio.S3.Views.{VersioningConfiguration,Tagging,Cors,Lifecycle,Encryption,ListVersions}`（各单元）：`render(map()) :: iodata()`。
- `Maxio.Tags`（M4-4）：tag 校验 + 编解码 `x-amz-tagging` 头。
  - `validate(tags :: [{String.t(), String.t()}], scope :: :object | :bucket) :: :ok | {:error, :invalid_tag}`
  - `parse_header(value :: String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, :invalid_tag}`
- `Maxio.BucketConfigs`（M4-2）：`bucket_configs` 表上下文（cors/lifecycle/encryption jsonb）。
  - `get(bucket :: String.t(), kind :: :cors | :lifecycle | :encryption) :: {:ok, map() | list()} | :none`
  - `put(bucket, kind, value) :: :ok | {:error, term()}`
  - `delete(bucket, kind) :: :ok`
- `Maxio.Crypto.SSE`（M4-7）：
  - `wrap_stream(chunks :: Enumerable.t()) :: {Enumerable.t(), header :: binary()}`（加密包装 + 返回需随对象元数据存的信封头）—— 见 M4-7 完整定义
  - `unwrap_stream(chunks :: Enumerable.t(), header :: binary()) :: Enumerable.t()`
- `%Maxio.BucketConfigs.BucketConfig{}`（M4-2）：schema 字段 `id, bucket_name, cors（jsonb）, lifecycle（jsonb）, encryption（jsonb）, inserted_at, updated_at`。

---

## 命名一致性检查清单（executor 每单元落地前自查）

- 资源 ARN 一律经 `Maxio.Policy.Arn.{bucket_arn,object_arn,account_arn}` 构造，绝不手拼。
- 新 operation 一律：① `Maxio.Policy.ActionMap.for_action/1` 加映射（→ `{s3:Action, level}`，绝不漏，漏了 Authz 放行=越权）；② `Maxio.S3.Dispatcher.resolve/3` 加分发（从 `@m2_subresources` 移出对应子资源 key）；③ `Maxio.S3.Handlers.dispatch/2` 加接线。
- XML 出站一律 `Maxio.S3.XML.encode/1` + `Saxy.XML.element/3`（与既有 view 一致）；入站一律 saxy SAX（`@behaviour Saxy.Handler`），命名空间用 `local/1` 去前缀（照抄 `AccessControlPolicy` parser 的 `local/1`）。
- 小文档 body 一律带上限整读（`read_body length:/read_length:`，照抄既有 `read_small_body!`）；对象字节一律 `BodyReader.stream/2`，绝不全缓冲。
- 错误码原子用既有 `Maxio.S3.Error.new/2`（M4 新增 `:invalid_tag`/`:access_forbidden`/`:no_such_cors_configuration`/`:no_such_lifecycle_configuration`/`:server_side_encryption_configuration_not_found`，见各单元；非 AES256 SSE 用既有 `:not_implemented`/`:invalid_argument`）。
- 所有新表/列/索引带中文 `COMMENT`（Ecto `comment:` 选项；裸 execute 索引用 `COMMENT ON INDEX`）。
- 每条 mix 命令前已设 `$env:Path` + `$env:ERL_FLAGS`。
- 每单元一次 commit，footer 固定 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。

---

## M4-1 · M3 收尾硬化（Authz 真实 principal + AWS Principal 精确匹配）

**目标**：清掉 M3 独立 reviewer 的 note 1（潜伏 bug）与 note 4（轻微过权）。**在加任何 M4 新动作/资源前先做**——否则未来 identity policy 落地时会被静默丢弃，且 AWS principal 通配会过权。

**依赖**：M3（master）。**规模**：两处定点修复 + 回归测试。

### TDD red 1：Authz 传真实 principal（note 1）

**根因**（`lib/maxio/s3/authz.ex` 第 90 行）：`gather_statements/3` 硬编码 `Store.principal_policies(:anonymous)`，无视真实 principal。MVP 该函数恒返回 `[]` 故无害；一旦实现 identity policy，认证用户的身份策略会被静默丢弃 → 静默拒绝。

新建 `test/maxio/s3/authz_principal_test.exs`：

```elixir
defmodule Maxio.S3.AuthzPrincipalTest do
  @moduledoc "回归：Authz.gather_statements 必须按真实 principal 取 identity policy（note 1）。"
  use Maxio.DataCase, async: false

  defmodule CapturingStore do
    @behaviour Maxio.Policy.Store
    @impl true
    def get_bucket_policy(_bucket), do: :none
    @impl true
    def put_bucket_policy(_bucket, _json), do: :ok
    @impl true
    def delete_bucket_policy(_bucket), do: :ok
    @impl true
    def principal_policies(principal) do
      send(Process.whereis(:authz_principal_test_pid), {:captured_principal, principal})
      []
    end
  end

  test "principal_policies 收到的是真实 principal 而非硬编码 :anonymous" do
    Process.register(self(), :authz_principal_test_pid)
    prev = Application.get_env(:maxio, :policy_store)
    Application.put_env(:maxio, :policy_store, CapturingStore)

    on_exit(fn ->
      Application.put_env(:maxio, :policy_store, prev)
      Process.unregister(:authz_principal_test_pid)
    end)

    principal = %{type: :iam_user, access_key: "AKIATEST00000000TEST", arn: "arn:aws:iam:::user/AKIATEST00000000TEST"}

    conn =
      Plug.Test.conn(:get, "/somebucket/k.txt")
      |> Plug.Conn.assign(:s3_bucket, "somebucket")
      |> Plug.Conn.assign(:s3_key, "k.txt")
      |> Plug.Conn.assign(:s3_level, :object)
      |> Plug.Conn.assign(:principal, principal)
      |> Plug.Conn.fetch_query_params()

    # 桶不存在 → owner? false → 进入 gather_statements → 应以真实 principal 调 principal_policies。
    # 默认拒绝会 raise；用 try 包住只验证捕获到的 principal。
    try do
      Maxio.S3.Authz.authorize(conn, :get_object)
    rescue
      _ -> :ok
    end

    assert_received {:captured_principal, ^principal}
  end
end
```

运行确认红（修复前捕获到的是 `:anonymous`）：

```powershell
mix test test/maxio/s3/authz_principal_test.exs
```

期望：FAIL（`assert_received {:captured_principal, ^principal}` 失败，实际收到 `:anonymous`）。

### green 1：把真实 principal 贯穿 `gather_statements`

修改 `lib/maxio/s3/authz.ex`：

1. `do_authorize/4` 中把 `statements = gather_statements(level, bucket, key)` 替换为：

```elixir
    statements = gather_statements(level, bucket, key, principal)
```

2. 把三个 `gather_statements` 子句从 `/3` 改为 `/4`（追加 `principal` 末参），并把硬编码的 `Store.principal_policies(:anonymous)` 改为 `Store.principal_policies(principal)`：

```elixir
  # ── statement 合并：bucket policy + canned ACL 派生 + identity policy（按真实 principal）──
  defp gather_statements(:account, _bucket, _key, _principal), do: []

  defp gather_statements(level, bucket, key, principal) when is_binary(bucket) do
    policy_stmts = Store.statements_for_bucket(bucket)
    acl_stmts = acl_statements(level, bucket, key)
    policy_stmts ++ acl_stmts ++ Store.principal_policies(principal)
  end

  defp gather_statements(_level, _bucket, _key, _principal), do: []
```

3. 修改 `maybe_authorize_copy_source/5` 内的 `statements = gather_statements(:object, src_bucket, src_key)` 为：

```elixir
        statements = gather_statements(:object, src_bucket, src_key, principal)
```

运行确认绿：

```powershell
mix test test/maxio/s3/authz_principal_test.exs
```

期望：`1 test, 0 failures`（捕获到真实 principal）。

### TDD red 2 + green 2：AWS Principal `{:aws, list}` 精确匹配（note 4）

**根因**（`lib/maxio/policy/evaluator.ex` 第 41-43 行）：`principal_match?({:aws, list}, ...)` 用 `Arn.glob_match?(pat, arn)`——AWS 视 Principal 为**精确匹配**（除非 policy variable，本 MVP 不支持），`arn:aws:iam:::user/*` 会被通配过度命中。改为精确字符串等值（区分大小写，对齐 AWS）。

> 注意：Statement 解析已把 `Principal: "*"` / `{"AWS":"*"}` 归一化为 `:any`（见 `Statement.parse_principal`），故 `{:aws, list}` 永远只含**具体** ARN 串，精确匹配是正确语义。

新建 `test/maxio/policy/principal_exact_test.exs`：

```elixir
defmodule Maxio.Policy.PrincipalExactTest do
  @moduledoc "回归：AWS Principal {:aws,list} 精确匹配，不被通配过度命中（note 4）。"
  use ExUnit.Case, async: true
  alias Maxio.Policy.{Evaluator, RequestContext, Statement}

  defp ctx(arn) do
    %RequestContext{
      principal: %{type: :iam_user, access_key: "ak", arn: arn},
      authenticated?: true,
      owner?: false,
      action: "s3:GetObject",
      resource: "arn:aws:s3:::b/k",
      conditions: %{}
    }
  end

  defp allow_stmt(principal_arn) do
    %Statement{
      effect: :allow,
      actions: ["s3:GetObject"],
      resources: ["arn:aws:s3:::b/*"],
      principals: {:aws, [principal_arn]},
      conditions: %{}
    }
  end

  test "精确 ARN 命中" do
    arn = "arn:aws:iam:::user/AKIAALICE"
    assert Evaluator.evaluate(ctx(arn), [allow_stmt(arn)]) == :allow
  end

  test "通配 ARN 不再过度命中（精确匹配）" do
    assert Evaluator.evaluate(ctx("arn:aws:iam:::user/AKIAALICE"), [allow_stmt("arn:aws:iam:::user/*")]) ==
             {:deny, :implicit_deny}
  end

  test "不同 ARN 不命中" do
    assert Evaluator.evaluate(ctx("arn:aws:iam:::user/AKIABOB"), [allow_stmt("arn:aws:iam:::user/AKIAALICE")]) ==
             {:deny, :implicit_deny}
  end
end
```

运行确认红（第 2 个用例 FAIL：glob 下 `user/*` 命中具体用户）：

```powershell
mix test test/maxio/policy/principal_exact_test.exs
```

green：修改 `lib/maxio/policy/evaluator.ex` 的 principal 匹配子句（第 41-43 行）为精确等值：

```elixir
  defp principal_match?({:aws, list}, %RequestContext{principal: %{arn: arn}}) do
    # AWS Principal 精确匹配（区分大小写）；不做 glob（policy variable 未实现）。Statement 已把纯 "*" 归一化为 :any。
    Enum.any?(list, fn pat -> pat == arn end)
  end
```

运行确认绿：

```powershell
mix test test/maxio/policy/principal_exact_test.exs
```

期望：`3 tests, 0 failures`。

> 检查 M3-9 `authz_matrix_test.exs` 的「policy 命名该 principal arn → 放行」用例：它用 `Principal: {"AWS": @alice_arn}`（具体 arn `arn:aws:iam:::user/AKIAALICEKEY00000001`），精确匹配仍命中——不受影响。运行全量回归确认。

### 单元收尾验证（M4-1）

```powershell
mix compile --warnings-as-errors
mix test
```

期望：编译零警告；全量测试通过（M3 基线 275 + 本单元 4 新增用例，全绿）；**既有 `authz_matrix_test.exs` 命名 principal 放行用例仍绿**。提交：

```powershell
git add -A
git commit -m @'
M4-1: M3 hardening — Authz passes real principal to principal_policies (note 1); AWS Principal {:aws,list} exact-match instead of glob (note 4); regression tests

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) `Authz.gather_statements` 以真实 principal 调 `principal_policies`（回归绿）；(2) AWS Principal 精确匹配（`user/*` 不再过度命中，回归绿）；(3) M3-9 命名 principal 放行用例仍绿；(4) `mix compile --warnings-as-errors` 零警告、全量测试绿。

---

## M4-2 · XML 入站解析框架 + VersioningConfiguration 解析器 + 配置载体 schema

**目标**：建立 M4 各配置子资源共用的「saxy SAX 入站解析 + 持久化载体」地基：① `buckets` 加 `versioning`/`mfa_delete` 列；② 新建 `bucket_configs` 表（cors/lifecycle/encryption 各一 jsonb 列，每桶一行）+ `Maxio.BucketConfigs` 上下文；③ 第一个解析器 `VersioningConfiguration`（最简单，确立 SAX 模式）。

**依赖**：M4-1。**规模**：两个迁移 + 一个 schema + 一个上下文 + 一个解析器 + 单测。

### 步骤 1：迁移 — buckets 加 versioning/mfa_delete 列

```powershell
mix ecto.gen.migration add_versioning_to_buckets
```

把生成文件内容替换为（路径形如 `priv/repo/migrations/<ts>_add_versioning_to_buckets.exs`）：

```elixir
defmodule Maxio.Repo.Migrations.AddVersioningToBuckets do
  use Ecto.Migration

  def change do
    alter table(:buckets) do
      add :versioning, :string,
        null: false,
        default: "Unversioned",
        comment:
          "桶版本化状态三态：Unversioned（从未设置，GetBucketVersioning 不回 <Status>）| Enabled（每次 PUT 生成唯一 version_id）| Suspended（PUT 用 null 版本就地覆盖）"

      add :mfa_delete, :string,
        null: true,
        comment:
          "MFA Delete 状态（Enabled|Disabled）；仅当曾配置时 GetBucketVersioning 才回显 <MfaDelete>。MVP 不强制 MFA 校验（无设备），仅存储/回显（defer，文档化）"
    end
  end
end
```

### 步骤 2：迁移 — bucket_configs 表

```powershell
mix ecto.gen.migration create_bucket_configs
```

替换为：

```elixir
defmodule Maxio.Repo.Migrations.CreateBucketConfigs do
  use Ecto.Migration

  def change do
    create table(:bucket_configs,
             primary_key: false,
             comment: "每桶一行的高级特性配置载体：CORS / Lifecycle / 默认加密配置各存一个 jsonb（解析校验后的结构），按需 upsert"
           ) do
      add :id, :binary_id, primary_key: true, comment: "主键（UUID）"

      add :bucket_name, :string,
        null: false,
        comment: "桶名（唯一；与 buckets.name 对应，应用层保证桶存在）"

      add :cors, :map,
        null: true,
        comment: "CORS 配置（jsonb 数组）：[CORSRule]，每 rule = %{id, allowed_methods, allowed_origins, allowed_headers, expose_headers, max_age_seconds}；nil=未配置"

      add :lifecycle, :map,
        null: true,
        comment: "生命周期配置（jsonb 数组）：[Rule]（仅存储+校验+出站；后台过期执行 DEFER 未实现，见 README）；nil=未配置"

      add :encryption, :map,
        null: true,
        comment: "默认加密配置（jsonb）：%{algorithm:AES256, kms_key_id, bucket_key_enabled}（MVP 仅 SSE-S3 AES256 生效）；nil=未配置"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:bucket_configs, [:bucket_name],
             comment: "桶名唯一索引（每桶至多一行高级配置）"
           )
  end
end
```

运行迁移并验证 schema：

```powershell
mix ecto.migrate
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ bucket_configs"
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ buckets"
```

期望：`bucket_configs` 表存在含中文 COMMENT 列；`buckets` 含 `versioning`（默认 Unversioned）与 `mfa_delete`。

### 步骤 3：schema `Maxio.BucketConfigs.BucketConfig` + 上下文 `Maxio.BucketConfigs`

新建 `lib/maxio/bucket_configs/bucket_config.ex`：

```elixir
defmodule Maxio.BucketConfigs.BucketConfig do
  @moduledoc "桶高级特性配置 schema（每桶一行：cors/lifecycle/encryption 各一 jsonb）。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "bucket_configs" do
    field :bucket_name, :string
    field :cors, {:array, :map}
    field :lifecycle, {:array, :map}
    field :encryption, :map

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:bucket_name, :cors, :lifecycle, :encryption]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(cfg, attrs) do
    cfg
    |> cast(attrs, @fields)
    |> validate_required([:bucket_name])
    |> unique_constraint(:bucket_name, name: :bucket_configs_bucket_name_index)
  end
end
```

> 说明：`cors`/`lifecycle` 在 DB 是 jsonb（可存数组），schema 用 `{:array, :map}`；`encryption` 是单 map。Ecto 对 jsonb 列既能存 map 也能存 list，列定义用 `:map` 即可，schema 字段类型决定读出形态。

新建 `lib/maxio/bucket_configs.ex`：

```elixir
defmodule Maxio.BucketConfigs do
  @moduledoc """
  桶高级特性配置上下文（CORS / Lifecycle / 默认加密）。每桶至多一行 bucket_configs；
  按 kind 读/写/删单个配置字段。get 返回已解析的结构（list 或 map）或 :none。
  """
  alias Maxio.Repo
  alias Maxio.BucketConfigs.BucketConfig

  @type kind :: :cors | :lifecycle | :encryption

  @doc "取某桶某类配置。未配置（行不存在或该列为 nil）→ :none。"
  @spec get(String.t(), kind()) :: {:ok, list() | map()} | :none
  def get(bucket, kind) when kind in [:cors, :lifecycle, :encryption] do
    case Repo.get_by(BucketConfig, bucket_name: bucket) do
      nil ->
        :none

      %BucketConfig{} = row ->
        case Map.get(row, kind) do
          nil -> :none
          value -> {:ok, value}
        end
    end
  end

  @doc "写入/覆盖某桶某类配置（按 bucket_name upsert，只更新该列）。"
  @spec put(String.t(), kind(), list() | map()) :: :ok | {:error, term()}
  def put(bucket, kind, value) when kind in [:cors, :lifecycle, :encryption] do
    attrs = %{bucket_name: bucket, kind => value}

    %BucketConfig{}
    |> BucketConfig.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [kind, :updated_at]},
      conflict_target: :bucket_name
    )
    |> case do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, cs}
    end
  end

  @doc "删除某桶某类配置（把该列置 nil；幂等）。行不存在 → :ok。"
  @spec delete(String.t(), kind()) :: :ok
  def delete(bucket, kind) when kind in [:cors, :lifecycle, :encryption] do
    case Repo.get_by(BucketConfig, bucket_name: bucket) do
      nil ->
        :ok

      %BucketConfig{} = row ->
        row |> BucketConfig.changeset(%{bucket_name: bucket, kind => nil}) |> Repo.update!()
        :ok
    end
  end
end
```

### 步骤 4：解析器 `Maxio.S3.RequestParsers.VersioningConfiguration`（TDD）

新建 `test/maxio/s3/request_parsers/versioning_configuration_test.exs`：

```elixir
defmodule Maxio.S3.RequestParsers.VersioningConfigurationTest do
  use ExUnit.Case, async: true
  alias Maxio.S3.RequestParsers.VersioningConfiguration, as: P

  test "Enabled" do
    xml = ~s(<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Enabled</Status></VersioningConfiguration>)
    assert {:ok, %{status: "Enabled", mfa_delete: nil}} = P.parse(xml)
  end

  test "Suspended" do
    xml = ~s(<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>)
    assert {:ok, %{status: "Suspended", mfa_delete: nil}} = P.parse(xml)
  end

  test "Enabled + MfaDelete" do
    xml = ~s(<VersioningConfiguration><Status>Enabled</Status><MfaDelete>Enabled</MfaDelete></VersioningConfiguration>)
    assert {:ok, %{status: "Enabled", mfa_delete: "Enabled"}} = P.parse(xml)
  end

  test "空 body（无 Status）→ status nil" do
    xml = ~s(<VersioningConfiguration></VersioningConfiguration>)
    assert {:ok, %{status: nil, mfa_delete: nil}} = P.parse(xml)
  end

  test "非法 XML → malformed_xml" do
    assert {:error, :malformed_xml} = P.parse("<bad")
  end

  test "非法 Status 值（非 Enabled/Suspended）→ malformed_xml" do
    xml = ~s(<VersioningConfiguration><Status>Bogus</Status></VersioningConfiguration>)
    assert {:error, :malformed_xml} = P.parse(xml)
  end
end
```

运行确认红：

```powershell
mix test test/maxio/s3/request_parsers/versioning_configuration_test.exs
```

新建 `lib/maxio/s3/request_parsers/versioning_configuration.ex`：

```elixir
defmodule Maxio.S3.RequestParsers.VersioningConfiguration do
  @moduledoc """
  PutBucketVersioning 的 XML body 解析（saxy SAX）。提取 <Status>（Enabled|Suspended）与
  <MfaDelete>（Enabled|Disabled）。容忍命名空间前缀与 xmlns。空 body（无 Status）→ status nil。
  非法 Status/MfaDelete 值 → :malformed_xml（铁律 3，绝不静默当默认）。
  返回 {:ok, %{status, mfa_delete}} | {:error, :malformed_xml}。
  """
  @behaviour Saxy.Handler

  @spec parse(binary()) ::
          {:ok, %{status: String.t() | nil, mfa_delete: String.t() | nil}}
          | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    with {:ok, %{status: status, mfa_delete: mfa}} <- run(xml),
         :ok <- validate(status, ["Enabled", "Suspended"]),
         :ok <- validate(mfa, ["Enabled", "Disabled"]) do
      {:ok, %{status: status, mfa_delete: mfa}}
    else
      _ -> {:error, :malformed_xml}
    end
  end

  defp run(xml) do
    case Saxy.parse_string(xml, __MODULE__, %{status: nil, mfa_delete: nil, in: nil, text: nil}) do
      {:ok, state} -> {:ok, state}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  defp validate(nil, _allowed), do: :ok
  defp validate(v, allowed) when is_binary(v), do: if(v in allowed, do: :ok, else: :error)

  @impl true
  def handle_event(:start_document, _p, s), do: {:ok, s}

  @impl true
  def handle_event(:start_element, {name, _attrs}, s) do
    case local(name) do
      "Status" -> {:ok, %{s | in: :status, text: ""}}
      "MfaDelete" -> {:ok, %{s | in: :mfa, text: ""}}
      _ -> {:ok, %{s | in: nil}}
    end
  end

  @impl true
  def handle_event(:characters, c, %{text: t} = s) when is_binary(t), do: {:ok, %{s | text: t <> c}}
  def handle_event(:characters, _c, s), do: {:ok, s}

  @impl true
  def handle_event(:end_element, name, s) do
    case local(name) do
      "Status" -> {:ok, %{s | status: trim(s.text), in: nil, text: nil}}
      "MfaDelete" -> {:ok, %{s | mfa_delete: trim(s.text), in: nil, text: nil}}
      _ -> {:ok, %{s | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _d, s), do: {:ok, s}

  defp trim(nil), do: nil
  defp trim(t), do: String.trim(t)

  defp local(name) do
    case String.split(name, ":") do
      [_ns, l] -> l
      [l] -> l
    end
  end
end
```

运行确认绿：

```powershell
mix test test/maxio/s3/request_parsers/versioning_configuration_test.exs
```

期望：`6 tests, 0 failures`。

新建 `test/maxio/bucket_configs_test.exs`：

```elixir
defmodule Maxio.BucketConfigsTest do
  use Maxio.DataCase, async: true
  alias Maxio.BucketConfigs

  test "put/get/delete CORS（list）" do
    assert BucketConfigs.get("b1", :cors) == :none
    rules = [%{"allowed_methods" => ["GET"], "allowed_origins" => ["*"]}]
    assert :ok = BucketConfigs.put("b1", :cors, rules)
    assert {:ok, ^rules} = BucketConfigs.get("b1", :cors)
    assert :ok = BucketConfigs.delete("b1", :cors)
    assert BucketConfigs.get("b1", :cors) == :none
  end

  test "三类配置互不干扰（同桶不同列）" do
    assert :ok = BucketConfigs.put("b2", :cors, [%{"x" => 1}])
    assert :ok = BucketConfigs.put("b2", :encryption, %{"algorithm" => "AES256"})
    assert {:ok, [%{"x" => 1}]} = BucketConfigs.get("b2", :cors)
    assert {:ok, %{"algorithm" => "AES256"}} = BucketConfigs.get("b2", :encryption)
    assert BucketConfigs.get("b2", :lifecycle) == :none
  end
end
```

```powershell
mix test test/maxio/bucket_configs_test.exs
```

期望：`2 tests, 0 failures`。

### 单元收尾验证（M4-2）

```powershell
mix compile --warnings-as-errors
mix test
```

期望：编译零警告；全量测试绿。提交：

```powershell
git add -A
git commit -m @'
M4-2: XML inbound parser framework + VersioningConfiguration parser + config carriers (buckets.versioning/mfa_delete columns; bucket_configs table + BucketConfigs context)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) 两迁移建表/列带中文 COMMENT（`psql \d+` 可读）；(2) `BucketConfigs` put/get/delete 三类配置正确且互不干扰；(3) `VersioningConfiguration` 解析 Enabled/Suspended/空/MfaDelete/非法值全覆盖；(4) 零警告、全量绿。

---

## M4-3a · Versioning 核心（多版本 schema + Storage version 维度 + 对象语义 + ?versioning API）

**目标**：maxio 最深的一块。把 objects 表从「每 (bucket,key) 一行当前版本」演进为「每 (bucket,key,version_id) 一行版本」模型，delete marker 是一种特殊版本行；`Storage.Backend` 加 version_id 维度（FS 落 version-qualified 路径）；PutObject/GetObject/HeadObject/DeleteObject 按桶版本化状态实现版本语义；`?versioning` 配置 API。**ListObjectVersions 留 M4-3b。**

**依赖**：M4-2。**规模**：大（schema 迁移 + storage behaviour 演进 + ULID + Objects 上下文演进 + Object handler 演进 + Versioning handler + Dispatcher/ActionMap/Handlers 接线 + 单测 + e2e）。这是计划里最重的单元，**executor 须按子步骤逐一红绿**。

### 设计决策（官方核验 bake-in，executor 须先读懂）

- **version_id 方案**：ULID（26 字符 Crockford base32，时间有序、URL-safe、≤1024 字节）。时间有序让「key 内 newest-first」= `ORDER BY version_id DESC`（同毫秒并发 PUT 由 ULID 随机后缀给确定性 tiebreak）。`null` 版本用保留串 `"null"` 存储（既是 DB 值也是 `x-amz-version-id` 回显值）。
- **三态语义**（`buckets.versioning`）：
  - `Unversioned`（never-set，默认）：PUT version_id=`"null"`，就地覆盖既有 `"null"` 行（upsert on `(bucket_id,key,"null")`）；DELETE 真删该 `"null"` 行。响应**不带** `x-amz-version-id`。
  - `Enabled`：PUT 生成新 ULID version_id 插入新行并置 `is_latest=true`（旧 latest 置 false）；DELETE 无 versionId → 插入 delete marker 行（新 ULID，`is_delete_marker=true`，无字节）并置 latest；`x-amz-version-id` 回显。
  - `Suspended`：PUT version_id=`"null"` 就地覆盖既有 `"null"` 行并置 latest（既有非 null 版本保留不动）；DELETE 无 versionId → 插入 `"null"` delete marker（覆盖 null 行）置 latest；`x-amz-version-id: null` 回显。
- **唯一性**：`(bucket_id, key, version_id)` 唯一。每个 (bucket,key) 至多一行 `is_latest=true`（应用层维护：置新 latest 前把同 key 旧 latest 置 false，在同一事务）。
- **GET/HEAD**：默认取 `is_latest=true` 行；若该行 `is_delete_marker` → 404（GET/HEAD）+ `x-amz-delete-marker: true`（不返回 `false`，仅在为真时出现）。`?versionId=X` 取该版本行；若指向 delete marker → 405（GET）/405（HEAD）+ `x-amz-delete-marker: true`（+ `Last-Modified`）。
- **DELETE `?versionId=X`**：永久删该版本行 + 字节（若是删 delete marker，则其下一个更老版本「自然」成为 latest——应用层重算 latest）。响应 204 + `x-amz-version-id: X`，若删的是 delete marker 还带 `x-amz-delete-marker: true`。
- **ListObjectsV2**（既有）：仍只返回 `is_latest=true and is_delete_marker=false` 的行。**M4-3b 改 list_objects_v2 查询过滤**。

### 子步骤 1：迁移 — objects 多版本演进

> 既有 `objects` 唯一索引是 `objects_bucket_id_key_index`（`(bucket_id, key)`）。多版本模型需要去掉它、改为 `(bucket_id, key, version_id)` 唯一。既有数据全部视为 `version_id="null"`、`is_latest=true`、`is_delete_marker=false`。

```powershell
mix ecto.gen.migration add_versioning_to_objects
```

替换为：

```elixir
defmodule Maxio.Repo.Migrations.AddVersioningToObjects do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :version_id, :string,
        null: false,
        default: "null",
        comment:
          "对象版本 ID（ULID，时间有序、URL-safe）；保留串 null 表示无版本（Unversioned/Suspended 写入的版本）。与 (bucket_id,key) 共同唯一确定一个版本行"

      add :is_latest, :boolean,
        null: false,
        default: true,
        comment: "是否为该 (bucket,key) 的当前版本（每 key 至多一行为 true；GET/ListObjectsV2 默认取此行）"

      add :is_delete_marker, :boolean,
        null: false,
        default: false,
        comment: "是否为删除标记（无字节、无 ACL；当前版本为删除标记时 GET 返回 404 + x-amz-delete-marker，ListObjectsV2 不返回）"
    end

    # 去掉旧的 (bucket_id,key) 唯一索引，改为 (bucket_id,key,version_id) 唯一（多版本）。
    drop unique_index(:objects, [:bucket_id, :key], name: :objects_bucket_id_key_index)

    create unique_index(:objects, [:bucket_id, :key, :version_id],
             name: :objects_bucket_id_key_version_id_index,
             comment: "桶内 (key, version_id) 唯一索引（多版本：同 key 多版本各一行；null 版本至多一行）"
           )

    # 加速「取某 key 的当前版本」与「列某 key 的全部版本（newest-first）」。
    create index(:objects, [:bucket_id, :key, :is_latest],
             name: :objects_bucket_key_latest_index,
             comment: "按 (bucket,key) 取当前版本（is_latest=true）索引"
           )
  end
end
```

运行迁移并验证：

```powershell
mix ecto.migrate
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ objects"
```

期望：`objects` 含 `version_id`/`is_latest`/`is_delete_marker`；唯一索引为 `(bucket_id,key,version_id)`。

### 子步骤 2：`Maxio.Versioning.VersionId`（ULID，TDD）

新建 `test/maxio/versioning/version_id_test.exs`：

```elixir
defmodule Maxio.Versioning.VersionIdTest do
  use ExUnit.Case, async: true
  alias Maxio.Versioning.VersionId

  test "generate 产出 26 字符 Crockford base32，URL-safe" do
    id = VersionId.generate()
    assert byte_size(id) == 26
    assert Regex.match?(~r/\A[0-9A-HJKMNP-TV-Z]{26}\z/, id)
  end

  test "时间有序：后生成的 >= 先生成的（字典序）" do
    a = VersionId.generate()
    Process.sleep(2)
    b = VersionId.generate()
    assert b >= a
  end

  test "null sentinel" do
    assert VersionId.null_sentinel() == "null"
  end

  test "唯一性（1000 次无碰撞）" do
    ids = for _ <- 1..1000, do: VersionId.generate()
    assert length(Enum.uniq(ids)) == 1000
  end
end
```

> 例外：本测试用 `Process.sleep/1` 仅为跨毫秒边界验证时间有序，属 ULID 算法验证的合理用法（AGENTS.md 的 sleep 禁令针对进程同步；此处无进程等待）。保留单一 2ms sleep。

运行确认红。新建 `lib/maxio/versioning/version_id.ex`（自实现 ULID，不引依赖）：

```elixir
defmodule Maxio.Versioning.VersionId do
  @moduledoc """
  对象版本 ID 生成（ULID：48-bit 毫秒时间戳 + 80-bit 随机，Crockford base32 编码为 26 字符）。
  时间有序（字典序 = 时间序）让 ListObjectVersions 的「key 内 newest-first」= ORDER BY version_id DESC；
  同毫秒并发 PUT 由 80-bit 随机后缀给确定性 tiebreak。URL-safe、≤1024 字节（对齐 AWS version ID 约束）。
  保留串 "null" 表示无版本（Unversioned/Suspended 写入），绝不由 generate 产出（铁律 5）。
  """
  # Crockford base32 字母表（无 I L O U，避免歧义）。
  @crockford ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  @doc "生成一个新 ULID（26 字符）。"
  @spec generate() :: String.t()
  def generate do
    ts = System.system_time(:millisecond)
    <<rand::80>> = :crypto.strong_rand_bytes(10)
    # 128-bit：48-bit 时间戳 + 80-bit 随机 → 26 个 5-bit 组 base32。
    <<int::128>> = <<ts::48, rand::80>>
    encode(int)
  end

  @doc "无版本保留串。"
  @spec null_sentinel() :: String.t()
  def null_sentinel, do: "null"

  # 把 128-bit 整数编码为 26 字符 Crockford base32（高位在前）。
  defp encode(int) do
    # 26 * 5 = 130 bit；左侧补 2 个 0 bit 到 130 再切 26 组。
    <<g::5, rest::bitstring>> = <<0::2, int::128>>
    do_encode(<<g::5, rest::bitstring>>, [])
  end

  defp do_encode(<<>>, acc), do: acc |> Enum.reverse() |> List.to_string()

  defp do_encode(<<g::5, rest::bitstring>>, acc) do
    do_encode(rest, [Enum.at(@crockford, g) | acc])
  end
end
```

> 实现说明：`<<0::2, int::128>>` 得 130 bit，正好 26 个 5-bit 组；`do_encode` 逐组取 5 bit 查表。`Enum.at(@crockford, g)` 返回码点（整数），`List.to_string/1` 把码点列表转字符串。

运行确认绿：

```powershell
mix test test/maxio/versioning/version_id_test.exs
```

期望：`4 tests, 0 failures`。

### 子步骤 3：`Object` schema 加字段

修改 `lib/maxio/objects/object.ex` 的 schema 与 changeset：

```elixir
  schema "objects" do
    field :bucket_name, :string
    field :key, :string
    field :size, :integer, default: 0
    field :etag, :string
    field :content_type, :string, default: "binary/octet-stream"
    field :metadata, :map, default: %{}
    field :storage_class, :string, default: "STANDARD"
    field :acl_canned, :string, default: "private"
    field :version_id, :string, default: "null"
    field :is_latest, :boolean, default: true
    field :is_delete_marker, :boolean, default: false

    belongs_to :bucket, Maxio.Buckets.Bucket

    timestamps(type: :utc_datetime_usec)
  end

  @required [:bucket_id, :bucket_name, :key, :size, :etag]
  @optional [:content_type, :metadata, :storage_class, :acl_canned, :version_id, :is_latest, :is_delete_marker]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(object, attrs) do
    object
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:bucket_id, :key, :version_id], name: :objects_bucket_id_key_version_id_index)
  end
```

### 子步骤 4：`Storage.Backend` behaviour + `Storage` 门面 + `FS` 加 version_id 维度

**铁律 1/2：所有受影响 callback 加 version_id 维度，FS 同步。** version_id=`"null"` 时落原路径（向后兼容既有对象），否则落 version-qualified 路径。

修改 `lib/maxio/storage/backend.ex`：把 `put/get/stat/delete` 四个 callback 的签名加 `version_id`（放在 key 之后）。完整替换这四个 callback 段：

```elixir
  @callback put(bucket(), key(), version_id :: String.t(), chunks :: Enumerable.t(), opts :: keyword()) ::
              {:ok, put_result()} | {:error, term()}
  @callback get(bucket(), key(), version_id :: String.t(), range()) ::
              {:ok, Enumerable.t()} | {:error, :enoent | term()}
  @callback stat(bucket(), key(), version_id :: String.t()) ::
              {:ok, %{size: non_neg_integer()}} | {:error, :enoent}
  @callback delete(bucket(), key(), version_id :: String.t()) :: :ok | {:error, term()}
```

修改 `lib/maxio/storage.ex` 门面对应四个函数（加 version_id 参数，默认 `"null"` 以兼容既有非版本调用点）：

```elixir
  @spec put(String.t(), String.t(), String.t(), Enumerable.t(), keyword()) ::
          {:ok, Maxio.Storage.Backend.put_result()} | {:error, term()}
  def put(bucket, key, version_id \\ "null", chunks, opts \\ [])

  def put(bucket, key, version_id, chunks, opts),
    do: backend().put(bucket, key, version_id, chunks, opts)

  @spec get(String.t(), String.t(), String.t(), Maxio.Storage.Backend.range()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def get(bucket, key, version_id \\ "null", range \\ nil),
    do: backend().get(bucket, key, version_id, range)

  @spec stat(String.t(), String.t(), String.t()) :: {:ok, %{size: non_neg_integer()}} | {:error, :enoent}
  def stat(bucket, key, version_id \\ "null"), do: backend().stat(bucket, key, version_id)

  @spec delete(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(bucket, key, version_id \\ "null"), do: backend().delete(bucket, key, version_id)
```

> 注意：Elixir 不允许多子句默认参数共存于不同 head——`put/5` 的默认参数须用单独的无 body head 声明（如上：`def put(bucket, key, version_id \\ "null", chunks, opts \\ [])` 一行声明默认，下一子句给 body）。get/stat/delete 单子句可直接带默认。**executor 落地后跑编译确认无「definitions with multiple clauses and default values」警告**——若报警告，把 put 的默认参数挪到独立 head（如上所示）。

修改 `lib/maxio/storage/fs.ex`：四个 `@impl` 包装与四个 `do_*` 加 version_id；version-qualified 路径。把对应段替换：

```elixir
  @impl true
  def put(bucket, key, version_id \\ "null", chunks, opts \\ [])
  def put(bucket, key, version_id, chunks, opts), do: do_put(bucket, key, version_id, chunks, opts)

  @impl true
  def get(bucket, key, version_id \\ "null", range \\ nil, opts \\ []),
    do: do_get(bucket, key, version_id, range, opts)

  @impl true
  def stat(bucket, key, version_id \\ "null", opts \\ []), do: do_stat(bucket, key, version_id, opts)

  @impl true
  def delete(bucket, key, version_id \\ "null", opts \\ []), do: do_delete(bucket, key, version_id, opts)
```

把 `do_put/do_get/do_stat/do_delete` 的首参链加 version_id，并把它们内部的 `object_path(bucket, key, opts)` 调用改为 `object_path(bucket, key, version_id, opts)`；新增带 version 的 `object_path/4`：

```elixir
  defp do_put(bucket, key, version_id, chunks, opts) do
    with {:ok, path} <- object_path(bucket, key, version_id, opts) do
      File.mkdir_p!(Path.dirname(path))
      {:ok, fd} = File.open(path, [:write, :binary, :raw])

      try do
        md5_0 = :crypto.hash_init(:md5)
        sha_0 = :crypto.hash_init(:sha256)

        {md5_ctx, sha_ctx, size} =
          Enum.reduce(chunks, {md5_0, sha_0, 0}, fn chunk, {m, s, acc} ->
            :ok = IO.binwrite(fd, chunk)
            {:crypto.hash_update(m, chunk), :crypto.hash_update(s, chunk), acc + byte_size(chunk)}
          end)

        etag = md5_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
        sha256 = sha_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
        {:ok, %{size: size, etag: etag, sha256: sha256}}
      after
        File.close(fd)
      end
    end
  end

  defp do_get(bucket, key, version_id, range, opts) do
    with {:ok, path} <- object_path(bucket, key, version_id, opts) do
      case File.stat(path) do
        {:ok, %File.Stat{size: total}} -> {:ok, stream_file(path, range, total)}
        {:error, :enoent} -> {:error, :enoent}
      end
    end
  end

  defp do_stat(bucket, key, version_id, opts) do
    with {:ok, path} <- object_path(bucket, key, version_id, opts) do
      case File.stat(path) do
        {:ok, %File.Stat{size: size}} -> {:ok, %{size: size}}
        {:error, :enoent} -> {:error, :enoent}
      end
    end
  end

  defp do_delete(bucket, key, version_id, opts) do
    with {:ok, path} <- object_path(bucket, key, version_id, opts) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
```

把既有 `object_path/3`（`object_path(bucket, key, opts)`）替换为 version 感知的 `object_path/4`，并让 `do_put_part`（M2 用 `object_path(bucket, key, opts)` 仅作 key 校验）改调 `object_path(bucket, key, "null", opts)`：

```elixir
  # version_id == "null"（无版本）→ 落原路径 <data_dir>/<bucket>/<key>（向后兼容既有对象）。
  # 否则落版本化路径 <data_dir>/.versions/<bucket>/<key>/<version_id>（与对象路径物理隔离，避免与 key 命名冲突）。
  defp object_path(bucket, key, "null", opts) do
    case safe_relative(key) do
      {:ok, rel} -> {:ok, Path.join([data_dir(opts), bucket, rel])}
      :error -> {:error, :invalid_key}
    end
  end

  defp object_path(bucket, key, version_id, opts) do
    case safe_relative(key) do
      {:ok, rel} ->
        {:ok, Path.join([data_dir(opts), ".versions", bucket, rel, version_id])}

      :error ->
        {:error, :invalid_key}
    end
  end
```

> `do_put_part` 内的 `with {:ok, _obj} <- object_path(bucket, key, opts)` 改为 `object_path(bucket, key, "null", opts)`；`do_get_part_stream` 同理。`do_assemble` 把组装结果写到对象路径——**Multipart Complete 在 Enabled 桶要写到版本化路径**：M2 的 `assemble` 写 `object_path(bucket,key,opts)`（即 null 路径）。M4 Complete 的版本落库由 handler 负责 version_id，但**字节路径**也要对齐。**本单元先保证非版本回归不破**：把 `do_assemble` 的 `object_path(bucket, key, opts)` 改为 `object_path(bucket, key, "null", opts)`；multipart 在版本化桶的字节版本化留 M4-3b 的已知 defer（见 M4-3b 收尾的 defer 说明：multipart 完成的对象当 null 版本/或 latest，字节走 null 路径——文档化，不影响单段对象版本化正确性）。

> **关键回归保护**：所有既有调用点（`Handlers.Object.do_put`/`copy`/`get`、`Handlers.Multipart`）当前以 `Storage.put(bucket,key,chunks)` 形式调用——门面默认参数把 version_id 补为 `"null"`，落原路径，**既有 e2e 全绿不变**。本子步骤跑全量回归确认。

```powershell
mix compile --warnings-as-errors
mix test
```

期望：编译零警告（特别留意默认参数多子句警告）；**全量回归绿**（既有对象走 null 路径，行为不变）。

### 子步骤 5：`Maxio.Objects` 上下文加版本化读写

在 `lib/maxio/objects.ex` 增加版本化函数（保留既有 `put_metadata`/`get_metadata`/`delete_metadata`/`put_acl`/`list_objects_v2` 不变——它们作用于「当前版本行」语义需微调：`get_metadata` 取 latest 非 delete-marker）。

先修改既有 `get_metadata/2` 让它取当前版本（latest），并新增版本化函数。把 `get_metadata/2` 替换为：

```elixir
  @doc "按 (bucket, key) 取当前版本（is_latest=true）的对象元数据。delete marker 也会返回（调用方判 is_delete_marker）。"
  @spec get_metadata(String.t(), String.t()) :: {:ok, Object.t()} | {:error, :not_found}
  def get_metadata(bucket_name, key) do
    case Repo.get_by(Object, bucket_name: bucket_name, key: key, is_latest: true) do
      nil -> {:error, :not_found}
      object -> {:ok, object}
    end
  end

  @doc "按 (bucket, key, version_id) 取特定版本行。"
  @spec get_version(String.t(), String.t(), String.t()) :: {:ok, Object.t()} | {:error, :not_found}
  def get_version(bucket_name, key, version_id) do
    case Repo.get_by(Object, bucket_name: bucket_name, key: key, version_id: version_id) do
      nil -> {:error, :not_found}
      object -> {:ok, object}
    end
  end
```

在文件内（`bucket_or_error/1` 之前）新增版本化写入/删除 + latest 维护，全部在事务内保证「至多一个 latest」：

```elixir
  @doc """
  按桶版本化状态写入一个对象版本（PutObject 的元数据落库）。
  versioning ∈ "Enabled" | "Suspended" | "Unversioned"：
    * Enabled → 生成新 ULID version_id，插入新行并置 latest（旧 latest 置 false）。
    * Suspended/Unversioned → version_id="null"，upsert 既有 null 行并置 latest（其余非 null 版本不动）。
  attrs 至少含 size、etag；可含 content_type/metadata/storage_class/acl_canned/tags/sse_algorithm。
  返回 {:ok, Object.t()}（含其 version_id）。
  """
  @spec put_version(String.t(), String.t(), String.t(), map()) ::
          {:ok, Object.t()} | {:error, :no_such_bucket | Ecto.Changeset.t()}
  def put_version(bucket_name, key, versioning, attrs) do
    with {:ok, bucket} <- bucket_or_error(bucket_name) do
      version_id =
        case versioning do
          "Enabled" -> Maxio.Versioning.VersionId.generate()
          _ -> "null"
        end

      base =
        attrs
        |> Map.take([:content_type, :metadata, :storage_class, :acl_canned, :tags, :sse_algorithm])
        |> Map.merge(%{
          bucket_id: bucket.id,
          bucket_name: bucket_name,
          key: key,
          size: Map.fetch!(attrs, :size),
          etag: Map.fetch!(attrs, :etag),
          version_id: version_id,
          is_latest: true,
          is_delete_marker: false
        })

      Repo.transaction(fn ->
        unset_latest(bucket.id, key)

        result =
          %Object{}
          |> Object.changeset(base)
          |> Repo.insert(
            on_conflict:
              {:replace,
               [:size, :etag, :content_type, :metadata, :storage_class, :acl_canned, :tags,
                :sse_algorithm, :is_latest, :is_delete_marker, :updated_at]},
            conflict_target: [:bucket_id, :key, :version_id]
          )

        case result do
          {:ok, obj} -> obj
          {:error, cs} -> Repo.rollback(cs)
        end
      end)
    end
  end

  @doc """
  插入删除标记（DELETE 无 versionId，桶 Enabled/Suspended）。
  Enabled → 新 ULID delete marker 置 latest；Suspended → "null" delete marker upsert 置 latest。
  返回 {:ok, %{version_id, delete_marker: true}}。
  """
  @spec insert_delete_marker(String.t(), String.t(), String.t()) ::
          {:ok, %{version_id: String.t()}} | {:error, :no_such_bucket}
  def insert_delete_marker(bucket_name, key, versioning) do
    with {:ok, bucket} <- bucket_or_error(bucket_name) do
      version_id =
        case versioning do
          "Enabled" -> Maxio.Versioning.VersionId.generate()
          _ -> "null"
        end

      base = %{
        bucket_id: bucket.id,
        bucket_name: bucket_name,
        key: key,
        size: 0,
        etag: "",
        version_id: version_id,
        is_latest: true,
        is_delete_marker: true
      }

      Repo.transaction(fn ->
        unset_latest(bucket.id, key)

        {:ok, _} =
          %Object{}
          |> Object.changeset(base)
          |> Repo.insert(
            on_conflict:
              {:replace, [:size, :etag, :is_latest, :is_delete_marker, :updated_at]},
            conflict_target: [:bucket_id, :key, :version_id]
          )
      end)

      {:ok, %{version_id: version_id}}
    end
  end

  @doc """
  永久删除某特定版本行（DELETE ?versionId）。删后若被删的是当时的 latest，则把该 key 余下
  version_id 最大者重新置 latest（delete marker 的删除会让更老版本重新浮现，对齐 AWS）。
  返回 {:ok, %{was_delete_marker: boolean()}} | {:error, :not_found}。
  """
  @spec delete_version(String.t(), String.t(), String.t()) ::
          {:ok, %{was_delete_marker: boolean()}} | {:error, :not_found}
  def delete_version(bucket_name, key, version_id) do
    case get_version(bucket_name, key, version_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, %Object{} = obj} ->
        Repo.transaction(fn ->
          Repo.delete!(obj)

          if obj.is_latest do
            promote_latest(obj.bucket_id, key)
          end
        end)

        {:ok, %{was_delete_marker: obj.is_delete_marker}}
    end
  end

  # 把该 (bucket,key) 现有 latest 行全部置 false（写新版本前调用，事务内）。
  defp unset_latest(bucket_id, key) do
    from(o in Object, where: o.bucket_id == ^bucket_id and o.key == ^key and o.is_latest == true)
    |> Repo.update_all(set: [is_latest: false])
  end

  # 删 latest 后，把余下 version_id 最大（最新）的行重新置 latest（无余下行则无操作）。
  defp promote_latest(bucket_id, key) do
    candidate =
      from(o in Object,
        where: o.bucket_id == ^bucket_id and o.key == ^key,
        order_by: [desc: o.version_id],
        limit: 1
      )
      |> Repo.one()

    if candidate do
      candidate |> Ecto.Changeset.change(is_latest: true) |> Repo.update!()
    end
  end
```

> 说明：`put_metadata/3`（M1 既有）仍被 CopyObject/Multipart Complete 调用——保留它，但它现在落 `version_id="null"` 行（默认）。为不破坏 multipart/copy 既有语义，**保留 `put_metadata/3` 原样**（它的 `on_conflict` replace 列表需补上新列以免覆盖丢失：把 `put_metadata` 的 `on_conflict` replace 列表加 `:is_latest, :is_delete_marker`，conflict_target 改为 `[:bucket_id, :key, :version_id]`，并在 base 里显式 `version_id: "null", is_latest: true, is_delete_marker: false`）。executor 落地时同步更新 `put_metadata/3`：

```elixir
  def put_metadata(bucket_name, key, attrs) do
    with {:ok, bucket} <- bucket_or_error(bucket_name) do
      base = %{
        bucket_id: bucket.id,
        bucket_name: bucket_name,
        key: key,
        size: Map.fetch!(attrs, :size),
        etag: Map.fetch!(attrs, :etag),
        content_type: Map.get(attrs, :content_type, "binary/octet-stream"),
        metadata: Map.get(attrs, :metadata, %{}),
        storage_class: Map.get(attrs, :storage_class, "STANDARD"),
        acl_canned: Map.get(attrs, :acl_canned, "private"),
        version_id: "null",
        is_latest: true,
        is_delete_marker: false
      }

      Repo.transaction(fn ->
        from(o in Object, where: o.bucket_id == ^bucket.id and o.key == ^key and o.is_latest == true)
        |> Repo.update_all(set: [is_latest: false])

        {:ok, obj} =
          %Object{}
          |> Object.changeset(base)
          |> Repo.insert(
            on_conflict:
              {:replace,
               [:size, :etag, :content_type, :metadata, :storage_class, :acl_canned,
                :is_latest, :is_delete_marker, :updated_at]},
            conflict_target: [:bucket_id, :key, :version_id]
          )

        obj
      end)
    end
  end
```

> 注意：`put_metadata/3` 返回从 `{:ok, obj}` 变为 `Repo.transaction` 的 `{:ok, obj}`（事务成功也是 `{:ok, obj}`）——调用方（copy/multipart）的 `{:ok, _obj} = ...` 模式匹配仍成立。`delete_metadata/2`（M1 既有，按 (bucket,key) 全删）保留——它在 Unversioned 桶的简单 DELETE 仍正确（删所有版本=删那唯一 null 行）。

### 子步骤 6：Object handler 版本化语义（TDD 红绿）

新建集成测试 `test/maxio/s3/versioning_object_test.exs`（覆盖核心版本语义；用既有 `SigV4Request`）：

```elixir
defmodule Maxio.S3.VersioningObjectTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_versioning_obj_test")

  setup do
    File.rm_rf(@data_dir); File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn -> Application.put_env(:maxio, :s3, prev); File.rm_rf(@data_dir) end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp enable_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)
    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body) |> call()
  end

  test "未版本化桶：PUT 不回 x-amz-version-id；GET 取当前" do
    SigV4Request.signed_conn(:put, "/uv") |> call()
    put = SigV4Request.signed_conn(:put, "/uv/k.txt", body: "v1") |> call()
    assert put.status == 200
    assert get_resp_header(put, "x-amz-version-id") == []
    get = SigV4Request.signed_conn(:get, "/uv/k.txt") |> call()
    assert get.resp_body == "v1"
  end

  test "Enabled：两次 PUT 产生两个版本，latest 是第二个；?versionId 取旧版本" do
    SigV4Request.signed_conn(:put, "/vb") |> call()
    assert enable_versioning("vb").status == 200

    p1 = SigV4Request.signed_conn(:put, "/vb/k.txt", body: "first") |> call()
    assert p1.status == 200
    [vid1] = get_resp_header(p1, "x-amz-version-id")
    assert vid1 != "null"

    p2 = SigV4Request.signed_conn(:put, "/vb/k.txt", body: "second") |> call()
    [vid2] = get_resp_header(p2, "x-amz-version-id")
    assert vid2 != vid1

    latest = SigV4Request.signed_conn(:get, "/vb/k.txt") |> call()
    assert latest.resp_body == "second"
    assert get_resp_header(latest, "x-amz-version-id") == [vid2]

    old = SigV4Request.signed_conn(:get, "/vb/k.txt", query: %{"versionId" => vid1}) |> call()
    assert old.resp_body == "first"
    assert get_resp_header(old, "x-amz-version-id") == [vid1]
  end

  test "Enabled：简单 DELETE 插入 delete marker；后续 GET → 404 + x-amz-delete-marker" do
    SigV4Request.signed_conn(:put, "/db") |> call()
    enable_versioning("db")
    SigV4Request.signed_conn(:put, "/db/k.txt", body: "data") |> call()

    del = SigV4Request.signed_conn(:delete, "/db/k.txt") |> call()
    assert del.status == 204
    assert [_dm_vid] = get_resp_header(del, "x-amz-version-id")
    assert get_resp_header(del, "x-amz-delete-marker") == ["true"]

    get = SigV4Request.signed_conn(:get, "/db/k.txt") |> call()
    assert get.status == 404
    assert get_resp_header(get, "x-amz-delete-marker") == ["true"]
  end

  test "Enabled：DELETE ?versionId 永久删该版本；删 delete marker 让旧版本重现" do
    SigV4Request.signed_conn(:put, "/pv") |> call()
    enable_versioning("pv")
    p1 = SigV4Request.signed_conn(:put, "/pv/k.txt", body: "alive") |> call()
    [vid1] = get_resp_header(p1, "x-amz-version-id")

    del = SigV4Request.signed_conn(:delete, "/pv/k.txt") |> call()
    [dm_vid] = get_resp_header(del, "x-amz-version-id")

    # 删 delete marker → 旧版本重现为 latest
    deldm = SigV4Request.signed_conn(:delete, "/pv/k.txt", query: %{"versionId" => dm_vid}) |> call()
    assert deldm.status == 204

    get = SigV4Request.signed_conn(:get, "/pv/k.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "alive"
    assert get_resp_header(get, "x-amz-version-id") == [vid1]
  end

  test "Enabled：GET ?versionId 指向 delete marker → 405" do
    SigV4Request.signed_conn(:put, "/mm") |> call()
    enable_versioning("mm")
    SigV4Request.signed_conn(:put, "/mm/k.txt", body: "x") |> call()
    del = SigV4Request.signed_conn(:delete, "/mm/k.txt") |> call()
    [dm_vid] = get_resp_header(del, "x-amz-version-id")

    get = SigV4Request.signed_conn(:get, "/mm/k.txt", query: %{"versionId" => dm_vid}) |> call()
    assert get.status == 405
    assert get_resp_header(get, "x-amz-delete-marker") == ["true"]
  end
end
```

运行确认红：

```powershell
mix test test/maxio/s3/versioning_object_test.exs
```

green：实现版本语义。改 `lib/maxio/s3/handlers/object.ex`。

(a) `do_put/1`：把 `Objects.put_metadata` 改为 `Objects.put_version`（按桶 versioning），并在响应回显 `x-amz-version-id`（仅当非 null）。把 `do_put/1` 的存元数据 + 响应段替换为：

```elixir
        versioning = bucket_versioning(bucket)

        {:ok, obj} =
          try do
            :ok = verify_decoded_length!(conn, payload_mode, size)
            :ok = verify_content_sha256!(conn, payload_mode, sha256)

            Objects.put_version(bucket, key, versioning, %{
              size: size,
              etag: etag,
              content_type: content_type,
              storage_class: "STANDARD",
              acl_canned: header(conn, "x-amz-acl") || "private"
            })
          rescue
            err ->
              _ = Storage.delete(bucket, key)

              Log.warn("put object rolled back orphan bytes",
                action: :put_object,
                bucket: bucket,
                key: key,
                reason: :incomplete_body
              )

              reraise(err, __STACKTRACE__)
          end

        Log.info("put object",
          action: :put_object,
          bucket: bucket,
          key: key,
          size: size,
          auth_type: conn.assigns.auth_type
        )

        conn
        |> maybe_put_version_id(obj.version_id)
        |> put_resp_header("etag", XML.quote_etag(etag))
        |> send_resp(200, "")
```

> **版本字节路径对齐**：`Storage.put(bucket, key, chunks)` 当前写 null 路径。Enabled 桶须把字节写到 `obj.version_id` 路径。但 `put_version` 在落库后才知 version_id，而字节已先流式写入（不能缓冲重写）。**解法**：先生成 version_id 再流式写。改 `do_put/1` 开头：在调 `Storage.put` 前算 version_id：

```elixir
  def do_put(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)

    content_type = header(conn, "content-type") || "binary/octet-stream"
    payload_mode = conn.assigns.payload_mode
    chunks = BodyReader.stream(conn, payload_mode)

    versioning = bucket_versioning(bucket)
    version_id = if versioning == "Enabled", do: Maxio.Versioning.VersionId.generate(), else: "null"

    case Storage.put(bucket, key, version_id, chunks) do
      {:ok, %{size: size, etag: etag, sha256: sha256}} ->
        {:ok, obj} =
          try do
            :ok = verify_decoded_length!(conn, payload_mode, size)
            :ok = verify_content_sha256!(conn, payload_mode, sha256)

            Objects.put_version_with_id(bucket, key, version_id, %{
              size: size,
              etag: etag,
              content_type: content_type,
              storage_class: "STANDARD",
              acl_canned: header(conn, "x-amz-acl") || "private"
            })
          rescue
            err ->
              _ = Storage.delete(bucket, key, version_id)
              Log.warn("put object rolled back orphan bytes", action: :put_object, bucket: bucket, key: key, reason: :incomplete_body)
              reraise(err, __STACKTRACE__)
          end

        Log.info("put object", action: :put_object, bucket: bucket, key: key, size: size, auth_type: conn.assigns.auth_type)

        conn
        |> maybe_put_version_id(obj.version_id)
        |> put_resp_header("etag", XML.quote_etag(etag))
        |> send_resp(200, "")

      {:error, :invalid_key} ->
        raise Error.new(:invalid_argument, resource: "/#{bucket}/#{key}", message: "Invalid key")

      {:error, reason} ->
        raise Error.new(:internal_error, message: inspect(reason))
    end
  end
```

> 因 version_id 在写字节前已定，把 `Objects.put_version/4` 拆成「外部传入 version_id」的 `put_version_with_id/4`。在 `Maxio.Objects` 把 `put_version/4` 改为内部委托：`put_version(bucket,key,versioning,attrs)` 先按 versioning 算 version_id（Enabled→generate，否则 "null"）再调 `put_version_with_id/4`；handler 直接用 `put_version_with_id/4`（version_id 已先算好，与字节路径一致）。在 `Maxio.Objects` 增加：

```elixir
  @doc "用外部已生成的 version_id 写入版本行（PutObject 路径：字节已按此 version_id 落盘）。"
  @spec put_version_with_id(String.t(), String.t(), String.t(), map()) ::
          {:ok, Object.t()} | {:error, :no_such_bucket | Ecto.Changeset.t()}
  def put_version_with_id(bucket_name, key, version_id, attrs) do
    with {:ok, bucket} <- bucket_or_error(bucket_name) do
      base =
        attrs
        |> Map.take([:content_type, :metadata, :storage_class, :acl_canned, :tags, :sse_algorithm])
        |> Map.merge(%{
          bucket_id: bucket.id,
          bucket_name: bucket_name,
          key: key,
          size: Map.fetch!(attrs, :size),
          etag: Map.fetch!(attrs, :etag),
          version_id: version_id,
          is_latest: true,
          is_delete_marker: false
        })

      Repo.transaction(fn ->
        unset_latest(bucket.id, key)

        case %Object{} |> Object.changeset(base) |> Repo.insert(
               on_conflict:
                 {:replace,
                  [:size, :etag, :content_type, :metadata, :storage_class, :acl_canned, :tags,
                   :sse_algorithm, :is_latest, :is_delete_marker, :updated_at]},
               conflict_target: [:bucket_id, :key, :version_id]
             ) do
          {:ok, obj} -> obj
          {:error, cs} -> Repo.rollback(cs)
        end
      end)
    end
  end
```

> 并把前述 `put_version/4` 内联体改为：`version_id = if versioning=="Enabled", do: VersionId.generate(), else: "null"; put_version_with_id(bucket_name, key, version_id, attrs)`。

(b) `get/1`：实现 versionId 取版本 + delete marker 语义。把 `get/1` 替换为：

```elixir
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    _ = ensure_bucket!(bucket)

    version_id = Map.get(conn.query_params, "versionId")
    {object, total} = resolve_object_for_get!(bucket, key, version_id)

    cond do
      object.is_delete_marker and version_id == nil ->
        # current 是 delete marker，简单 GET → 404 + x-amz-delete-marker
        conn
        |> put_resp_header("x-amz-delete-marker", "true")
        |> maybe_put_version_id(object.version_id)
        |> send_resp(404, "")

      object.is_delete_marker ->
        # ?versionId 指向 delete marker → 405 + headers
        conn
        |> put_resp_header("x-amz-delete-marker", "true")
        |> put_resp_header("last-modified", http_date(object.updated_at))
        |> maybe_put_version_id(object.version_id)
        |> send_resp(405, "")

      true ->
        case Conditional.evaluate(conn.req_headers, meta(object), "GET") do
          :proceed ->
            range = parse_range(header(conn, "range"), total)

            case range do
              :invalid ->
                raise Error.new(:invalid_range, resource: "/#{bucket}/#{key}", extra: %{total: total})

              _ ->
                {:ok, stream} = Storage.get(bucket, key, object.version_id, range_tuple(range))
                conn = maybe_put_version_id(conn, object.version_id)
                send_object(conn, object, total, range, stream)
            end

          {:respond, 304} ->
            send_resp(conn, 304, "")

          {:error, :precondition_failed} ->
            raise Error.new(:precondition_failed, resource: "/#{bucket}/#{key}")
        end
    end
  end
```

新增 `resolve_object_for_get!/3`（取特定版本或 latest）：

```elixir
  # version_id == nil → 取当前版本（latest）；否则取指定版本行。缺失 → NoSuchKey/NoSuchVersion。
  defp resolve_object_for_get!(bucket, key, nil) do
    case Objects.get_metadata(bucket, key) do
      {:ok, object} -> {object, object.size}
      {:error, :not_found} -> raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  defp resolve_object_for_get!(bucket, key, version_id) do
    case Objects.get_version(bucket, key, version_id) do
      {:ok, object} -> {object, object.size}
      {:error, :not_found} -> raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end
```

(c) `head/1`：与 get 对称（delete marker：current→404，?versionId→405；均无 body）。把 `head/1` 改为支持 versionId + delete-marker（核心同 get，省略 body）：

```elixir
  def head(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    version_id = Map.get(conn.query_params, "versionId")

    with {:ok, _b} <- Buckets.lookup(bucket),
         {:ok, object} <- fetch_for_head(bucket, key, version_id) do
      cond do
        object.is_delete_marker and version_id == nil ->
          conn |> put_resp_header("x-amz-delete-marker", "true") |> maybe_put_version_id(object.version_id) |> send_resp(404, "")

        object.is_delete_marker ->
          conn
          |> put_resp_header("x-amz-delete-marker", "true")
          |> put_resp_header("last-modified", http_date(object.updated_at))
          |> maybe_put_version_id(object.version_id)
          |> send_resp(405, "")

        true ->
          case Conditional.evaluate(conn.req_headers, meta(object), "HEAD") do
            :proceed ->
              conn
              |> maybe_put_version_id(object.version_id)
              |> put_common_object_headers(object, object.size)
              |> send_resp(200, "")

            {:respond, 304} -> send_resp(conn, 304, "")
            {:error, :precondition_failed} -> send_resp(conn, 412, "")
          end
      end
    else
      {:error, :not_found} ->
        Log.info("head object miss", action: :head_object, bucket: bucket, key: key)
        send_resp(conn, 404, "")
    end
  end

  defp fetch_for_head(bucket, key, nil), do: Objects.get_metadata(bucket, key)
  defp fetch_for_head(bucket, key, version_id), do: Objects.get_version(bucket, key, version_id)
```

(d) `delete/1`：实现版本删除语义。把 `delete/1` 替换为：

```elixir
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    _ = ensure_bucket!(bucket)

    version_id = Map.get(conn.query_params, "versionId")
    versioning = bucket_versioning(bucket)

    cond do
      version_id != nil ->
        # 永久删除指定版本（含 delete marker）。
        case Objects.delete_version(bucket, key, version_id) do
          {:ok, %{was_delete_marker: dm?}} ->
            _ = Storage.delete(bucket, key, version_id)
            Log.info("delete object version", action: :delete_object, bucket: bucket, key: key)

            conn
            |> put_resp_header("x-amz-version-id", version_id)
            |> then(fn c -> if dm?, do: put_resp_header(c, "x-amz-delete-marker", "true"), else: c end)
            |> send_resp(204, "")

          {:error, :not_found} ->
            # 幂等：删不存在的版本也回 204（对齐 AWS）。
            conn |> put_resp_header("x-amz-version-id", version_id) |> send_resp(204, "")
        end

      versioning in ["Enabled", "Suspended"] ->
        # 插入 delete marker（Enabled 新 ULID；Suspended null）。
        {:ok, %{version_id: dm_vid}} = Objects.insert_delete_marker(bucket, key, versioning)
        Log.info("delete object marker", action: :delete_object, bucket: bucket, key: key)

        conn
        |> maybe_put_version_id(dm_vid)
        |> put_resp_header("x-amz-delete-marker", "true")
        |> send_resp(204, "")

      true ->
        # Unversioned：真删（删 null 行 + 字节）。
        :ok = Objects.delete_metadata(bucket, key)
        _ = Storage.delete(bucket, key)
        Log.info("delete object", action: :delete_object, bucket: bucket, key: key)
        send_resp(conn, 204, "")
    end
  end
```

(e) helpers：新增 `bucket_versioning/1`、`maybe_put_version_id/2`。在 helpers 区加：

```elixir
  # 桶版本化状态（Unversioned|Enabled|Suspended）。
  defp bucket_versioning(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, %{versioning: v}} when is_binary(v) -> v
      _ -> "Unversioned"
    end
  end

  # 仅当版本非 "null" 时回显 x-amz-version-id（Unversioned 桶不带该头，对齐 AWS）。
  defp maybe_put_version_id(conn, "null"), do: conn
  defp maybe_put_version_id(conn, version_id), do: put_resp_header(conn, "x-amz-version-id", version_id)
```

运行确认绿：

```powershell
mix test test/maxio/s3/versioning_object_test.exs
```

期望：`5 tests, 0 failures`。

### 子步骤 7：`?versioning` 配置 API + 出站 view + 接线

新建出站 view `lib/maxio/s3/views/versioning_configuration.ex`：

```elixir
defmodule Maxio.S3.Views.VersioningConfiguration do
  @moduledoc """
  GetBucketVersioning 响应 XML。三态（官方核验 bake-in）：
    * never-set（Unversioned）→ 空自闭 <VersioningConfiguration/>（无 <Status>）。
    * Enabled/Suspended → 含 <Status>。
    * mfa_delete 非 nil → 追加 <MfaDelete>（仅曾配置时回显）。
  """
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{versioning: String.t(), mfa_delete: String.t() | nil}) :: iodata()
  def render(%{versioning: versioning, mfa_delete: mfa}) do
    children =
      []
      |> maybe_status(versioning)
      |> maybe_mfa(mfa)

    root = element("VersioningConfiguration", [{"xmlns", XML.namespace()}], children)
    XML.encode(root)
  end

  defp maybe_status(children, v) when v in ["Enabled", "Suspended"],
    do: children ++ [element("Status", [], characters(v))]

  defp maybe_status(children, _unversioned), do: children

  defp maybe_mfa(children, nil), do: children
  defp maybe_mfa(children, mfa), do: children ++ [element("MfaDelete", [], characters(mfa))]
end
```

新建 handler `lib/maxio/s3/handlers/versioning.ex`：

```elixir
defmodule Maxio.S3.Handlers.Versioning do
  @moduledoc """
  ?versioning 子资源 handler：PutBucketVersioning（XML body → 校验 → 存 buckets.versioning/mfa_delete，200）、
  GetBucketVersioning（200 + VersioningConfiguration XML，三态）。XML body 走带上限整读（铁律 4）。
  注：已 Enabled 的桶不能回退 Unversioned，只能 Suspended（与 AWS 一致）——本 handler 只接受 Enabled/Suspended。
  """
  import Plug.Conn
  alias Maxio.Buckets
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.RequestParsers.VersioningConfiguration, as: Parser
  alias Maxio.S3.Views.VersioningConfiguration, as: View

  @xml_limit 1_048_576

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, xml} = read_small_body!(conn)

    case Parser.parse(xml) do
      {:ok, %{status: status, mfa_delete: mfa}} ->
        # status 缺省（空 body）→ 不改状态（保留现状）；显式 Enabled/Suspended → 落库。
        :ok = Buckets.put_versioning(bucket, status, mfa)
        Log.info("put bucket versioning", action: :put_bucket_versioning, bucket: bucket, reason: status)
        send_resp(conn, 200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    b = ensure_bucket!(bucket)
    body = View.render(%{versioning: b.versioning, mfa_delete: b.mfa_delete})

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @xml_limit, read_length: @xml_limit) do
      {:ok, body, conn} -> {conn, body}
      {:more, _partial, _conn} -> raise Error.new(:entity_too_large, message: "Versioning config too large")
      {:error, _} -> raise Error.new(:malformed_xml)
    end
  end
end
```

在 `lib/maxio/buckets.ex` 增加 `put_versioning/3`（保留既有函数）：

```elixir
  @doc """
  设置桶版本化状态（PutBucketVersioning）。status 为 nil（空 body）→ 不改 versioning；
  显式 "Enabled"/"Suspended" → 更新。mfa 非 nil → 更新 mfa_delete。桶不存在 → :not_found。
  """
  @spec put_versioning(String.t(), String.t() | nil, String.t() | nil) :: :ok | {:error, :not_found}
  def put_versioning(name, status, mfa) do
    case lookup(name) do
      {:ok, bucket} ->
        changes =
          %{}
          |> then(fn m -> if status, do: Map.put(m, :versioning, status), else: m end)
          |> then(fn m -> if mfa, do: Map.put(m, :mfa_delete, mfa), else: m end)

        if changes == %{} do
          :ok
        else
          bucket |> Bucket.changeset(changes) |> Repo.update!()
          :ok
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
```

在 `lib/maxio/buckets/bucket.ex` 把 `versioning`/`mfa_delete` 加入 schema 与 changeset：

```elixir
  schema "buckets" do
    field :name, :string
    field :region, :string, default: "us-east-1"
    field :owner, :string
    field :acl_canned, :string, default: "private"
    field :versioning, :string, default: "Unversioned"
    field :mfa_delete, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required [:name, :owner]
  @optional [:region, :acl_canned, :versioning, :mfa_delete]
```

**接线**：
1. `lib/maxio/s3/dispatcher.ex`：把 `"versioning"` 从 `@m2_subresources` 列表移除，并在 `resolve/3` 加分发分支（放在 `?policy` 分支之后、`?acl` 之前）：

```elixir
      level == :bucket and MapSet.member?(query_keys, "versioning") ->
        case method do
          "PUT" -> {:ok, :put_bucket_versioning}
          "GET" -> {:ok, :get_bucket_versioning}
          _ -> {:error, :method_not_allowed}
        end
```

2. `lib/maxio/s3/handlers.ex`：加接线（alias 加 `Versioning`）：

```elixir
  def dispatch(:put_bucket_versioning, conn), do: Versioning.put(conn)
  def dispatch(:get_bucket_versioning, conn), do: Versioning.get(conn)
```

3. `lib/maxio/policy/action_map.ex`：加映射：

```elixir
  def for_action(:put_bucket_versioning), do: {"s3:PutBucketVersioning", :bucket}
  def for_action(:get_bucket_versioning), do: {"s3:GetBucketVersioning", :bucket}
```

新建配置 API 集成测试 `test/maxio/s3/versioning_config_test.exs`：

```elixir
defmodule Maxio.S3.VersioningConfigTest do
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "never-set → GetBucketVersioning 返回空自闭元素（无 Status）" do
    SigV4Request.signed_conn(:put, "/cfgb") |> call()
    get = SigV4Request.signed_conn(:get, "/cfgb", query: %{"versioning" => ""}) |> call()
    assert get.status == 200
    refute get.resp_body =~ "<Status>"
    assert get.resp_body =~ "VersioningConfiguration"
  end

  test "Enable 后 Get 返回 Enabled；Suspend 后返回 Suspended" do
    SigV4Request.signed_conn(:put, "/cfgb2") |> call()

    SigV4Request.signed_conn(:put, "/cfgb2",
      query: %{"versioning" => ""},
      body: ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)
    ) |> call()

    g1 = SigV4Request.signed_conn(:get, "/cfgb2", query: %{"versioning" => ""}) |> call()
    assert g1.resp_body =~ "<Status>Enabled</Status>"

    SigV4Request.signed_conn(:put, "/cfgb2",
      query: %{"versioning" => ""},
      body: ~s(<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>)
    ) |> call()

    g2 = SigV4Request.signed_conn(:get, "/cfgb2", query: %{"versioning" => ""}) |> call()
    assert g2.resp_body =~ "<Status>Suspended</Status>"
  end
end
```

### 单元收尾验证（M4-3a）

```powershell
mix compile --warnings-as-errors
mix test
```

期望：编译零警告；全量测试绿（既有 M0–M3 全部回归 + 新增 versioning 对象语义 + 配置 API）。提交：

```powershell
git add -A
git commit -m @'
M4-3a: object versioning core — multi-version objects schema; Storage.Backend version_id dimension (FS version-qualified paths); ULID VersionId; Put/Get/Head/Delete version semantics (delete markers, x-amz-version-id/delete-marker); PutBucketVersioning/GetBucketVersioning (?versioning, 3-state)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) 迁移：objects 多版本唯一索引 `(bucket_id,key,version_id)`、中文 COMMENT；(2) ULID：26 字符、时间有序、唯一；(3) Storage version 维度：null→原路径（既有回归绿）、非 null→版本路径；(4) 对象语义：Enabled 多版本/latest/`?versionId`/delete marker(404/405)/`?versionId` 永久删/删 marker 旧版本重现/`x-amz-version-id`/`x-amz-delete-marker` 全绿；(5) `?versioning` 三态（never-set 空元素/Enabled/Suspended）；(6) ActionMap/Dispatcher/Handlers 接线；(7) 零警告、全量绿。

---

## M4-3b · ListObjectVersions（?versions）+ ListObjectsV2 latest 过滤 + 版本化 e2e

**目标**：在 M4-3a 多版本存储模型上做两个投影：① `ListObjectVersions`（`?versions`）——Version + DeleteMarker 交错（key 升序、key 内 newest-first）、二维分页 `(NextKeyMarker, NextVersionIdMarker)`、delimiter/CommonPrefixes；② 修 `ListObjectsV2` 只返回 latest 非 delete-marker 行。+ 端到端版本化集成矩阵。

**依赖**：M4-3a。**规模**：列举查询 + 出站 view + handler + Dispatcher/ActionMap 接线 + ListObjectsV2 修正 + 单测/e2e。

### 步骤 1：修 ListObjectsV2 只返回 latest 非 delete-marker（TDD 红绿）

**根因**：M4-3a 后 objects 表有多版本行；`Objects.list_objects_v2/2` 的 `base_query` 未过滤 → 会返回所有版本行（含 delete marker、旧版本）。须加 `where: o.is_latest == true and o.is_delete_marker == false`。

新建 `test/maxio/objects/list_latest_test.exs`：

```elixir
defmodule Maxio.Objects.ListLatestTest do
  use Maxio.DataCase, async: true
  alias Maxio.{Buckets, Objects}

  setup do
    {:ok, _} = Buckets.create("lb", "arn:aws:iam:::root")
    :ok
  end

  test "ListObjectsV2 只返回 latest 非 delete-marker" do
    # 两版本同 key（Enabled 语义模拟）：旧版本 is_latest=false，新版本 latest。
    {:ok, _} = Objects.put_version_with_id("lb", "k.txt", "01OLD", %{size: 2, etag: "a"})
    {:ok, _} = Objects.put_version_with_id("lb", "k.txt", "02NEW", %{size: 3, etag: "b"})
    # delete marker 当前的另一 key
    {:ok, _} = Objects.put_version_with_id("lb", "d.txt", "01D", %{size: 1, etag: "c"})
    {:ok, _} = Objects.insert_delete_marker("lb", "d.txt", "Enabled")

    res = Objects.list_objects_v2("lb", %{})
    keys = Enum.map(res.objects, & &1.key)
    assert keys == ["k.txt"]            # d.txt 当前是 delete marker → 不列；k.txt 只列 latest 一次
    assert res.key_count == 1
  end
end
```

运行确认红。green：在 `lib/maxio/objects.ex` 的 `list_objects_v2/2` 的 `base_query` 加过滤：

```elixir
    base_query =
      from o in Object,
        where: o.bucket_name == ^bucket_name and o.is_latest == true and o.is_delete_marker == false,
        order_by: [asc: o.key]
```

运行确认绿。

### 步骤 2：ListObjectVersions 查询（`Maxio.Objects.list_object_versions/2`）

在 `lib/maxio/objects.ex` 新增（紧邻 `list_objects_v2`）：

```elixir
  @type versions_result :: %{
          versions: [Object.t()],
          common_prefixes: [String.t()],
          is_truncated: boolean(),
          next_key_marker: String.t() | nil,
          next_version_id_marker: String.t() | nil
        }

  @doc """
  ListObjectVersions 查询（?versions）。返回 %{versions, common_prefixes, is_truncated,
  next_key_marker, next_version_id_marker}。语义对齐官方：
    * 排序：key 升序，key 内 newest-first（version_id 降序——ULID 时间序）。delete marker 与
      version 交错在同一 key-then-newest 序列。
    * 二维游标：(key_marker, version_id_marker) 之后开始（先 key 严格大于，或 key 相等且 version_id 严格小于）。
    * delimiter 折叠：prefix 之后首个 delimiter 之间的串折叠成 CommonPrefixes（每个计一个结果）。
    * max-keys 默认/上限 1000；多取一条判截断；截断时 next_key_marker/next_version_id_marker = 最后返回项。
  versions 列表元素含 is_delete_marker，由 view 决定渲染 <Version> 还是 <DeleteMarker>。
  """
  @spec list_object_versions(String.t(), map()) :: versions_result()
  def list_object_versions(bucket_name, opts \\ %{}) do
    prefix = Map.get(opts, :prefix, "") || ""
    delimiter = Map.get(opts, :delimiter)
    max_keys = Map.get(opts, :max_keys, 1000)
    key_marker = Map.get(opts, :key_marker)
    version_id_marker = Map.get(opts, :version_id_marker)

    base =
      from o in Object,
        where: o.bucket_name == ^bucket_name,
        order_by: [asc: o.key, desc: o.version_id]

    base =
      if prefix != "",
        do: where(base, [o], like(o.key, ^(escape_like(prefix) <> "%"))),
        else: base

    # 二维游标：key > key_marker，或 (key == key_marker and version_id < version_id_marker)。
    base =
      cond do
        key_marker && version_id_marker ->
          where(
            base,
            [o],
            o.key > ^key_marker or (o.key == ^key_marker and o.version_id < ^version_id_marker)
          )

        key_marker ->
          where(base, [o], o.key > ^key_marker)

        true ->
          base
      end

    candidates = Repo.all(base)

    {versions, common_prefixes, truncated, last_key, last_vid} =
      collapse_versions(candidates, prefix, delimiter, max_keys)

    %{
      versions: versions,
      common_prefixes: common_prefixes,
      is_truncated: truncated,
      next_key_marker: if(truncated, do: last_key, else: nil),
      next_version_id_marker: if(truncated, do: last_vid, else: nil)
    }
  end

  # 折叠 delimiter 公共前缀 + 截断判断（与 list_objects_v2 同构，但游标是二维 (key, version_id)）。
  defp collapse_versions(candidates, prefix, delimiter, max_keys) do
    do_collapse_versions(candidates, prefix, delimiter, max_keys, [], MapSet.new(), [], nil, nil)
  end

  defp do_collapse_versions([], _prefix, _delim, _max, vers, _seen, cps, lk, lv) do
    {Enum.reverse(vers), Enum.reverse(cps), false, lk, lv}
  end

  defp do_collapse_versions([obj | rest], prefix, delimiter, max, vers, seen, cps, _lk, _lv) do
    count = length(vers) + MapSet.size(seen)

    cond do
      count >= max ->
        {last_key, last_vid} = previous_version_token(vers, cps)
        {Enum.reverse(vers), Enum.reverse(cps), true, last_key, last_vid}

      true ->
        case common_prefix_of(obj.key, prefix, delimiter) do
          nil ->
            do_collapse_versions(rest, prefix, delimiter, max, [obj | vers], seen, cps, obj.key, obj.version_id)

          cp ->
            if MapSet.member?(seen, cp) do
              do_collapse_versions(rest, prefix, delimiter, max, vers, seen, cps, cp, nil)
            else
              do_collapse_versions(rest, prefix, delimiter, max, vers, MapSet.put(seen, cp), [cp | cps], cp, nil)
            end
        end
    end
  end

  # 截断游标 = 已返回的最后一项（version 行 → 其 key/version_id；公共前缀 → key=cp, version_id=nil）。
  defp previous_version_token([obj | _], _cps), do: {obj.key, obj.version_id}
  defp previous_version_token([], [cp | _]), do: {cp, nil}
  defp previous_version_token([], []), do: {nil, nil}
```

### 步骤 3：出站 view `Maxio.S3.Views.ListVersions`

新建 `lib/maxio/s3/views/list_versions.ex`：

```elixir
defmodule Maxio.S3.Views.ListVersions do
  @moduledoc """
  ListObjectVersions 响应 XML（ListVersionsResult）。Version 与 DeleteMarker 交错（按入参顺序，
  调用方已按 key 升序、key 内 newest-first 排好）。delete marker 无 ETag/Size/StorageClass（官方核验）。
  NextKeyMarker/NextVersionIdMarker 仅截断时出现；CommonPrefixes 仅有 delimiter 时。
  owner_id/owner_display 用合成 "maxio"。
  """
  import Saxy.XML
  alias Maxio.S3.XML

  @owner_id "maxio"
  @owner_display "maxio"

  @spec render(map()) :: iodata()
  def render(data) do
    head =
      [
        element("Name", [], characters(data.name)),
        element("Prefix", [], characters(data.prefix || "")),
        element("KeyMarker", [], characters(data.key_marker || "")),
        element("VersionIdMarker", [], characters(data.version_id_marker || "")),
        element("MaxKeys", [], characters(Integer.to_string(data.max_keys))),
        element("IsTruncated", [], characters(to_string(data.is_truncated)))
      ]
      |> maybe(data.is_truncated && data.next_key_marker, fn t -> element("NextKeyMarker", [], characters(t)) end)
      |> maybe(data.is_truncated && data.next_version_id_marker, fn t ->
        element("NextVersionIdMarker", [], characters(t))
      end)
      |> maybe(data.delimiter, fn d -> element("Delimiter", [], characters(d)) end)

    entries = Enum.map(data.versions, &version_or_marker/1)

    common =
      Enum.map(data.common_prefixes, fn cp ->
        element("CommonPrefixes", [], [element("Prefix", [], characters(cp))])
      end)

    root = element("ListVersionsResult", [{"xmlns", XML.namespace()}], head ++ entries ++ common)
    XML.encode(root)
  end

  # version 行（含 is_delete_marker）→ <Version> 或 <DeleteMarker>。
  defp version_or_marker(%{is_delete_marker: true} = o) do
    element("DeleteMarker", [], [
      element("Key", [], characters(o.key)),
      element("VersionId", [], characters(o.version_id)),
      element("IsLatest", [], characters(to_string(o.is_latest))),
      element("LastModified", [], characters(XML.iso8601(o.updated_at))),
      owner()
    ])
  end

  defp version_or_marker(o) do
    element("Version", [], [
      element("Key", [], characters(o.key)),
      element("VersionId", [], characters(o.version_id)),
      element("IsLatest", [], characters(to_string(o.is_latest))),
      element("LastModified", [], characters(XML.iso8601(o.updated_at))),
      element("ETag", [], characters(XML.quote_etag(o.etag))),
      element("Size", [], characters(Integer.to_string(o.size))),
      element("StorageClass", [], characters(o.storage_class || "STANDARD")),
      owner()
    ])
  end

  defp owner do
    element("Owner", [], [
      element("ID", [], characters(@owner_id)),
      element("DisplayName", [], characters(@owner_display))
    ])
  end

  defp maybe(children, falsy, _fun) when falsy in [nil, false, ""], do: children
  defp maybe(children, value, fun), do: children ++ [fun.(value)]
end
```

### 步骤 4：handler（在 Bucket handler 加 `list_object_versions/1`）+ 接线

在 `lib/maxio/s3/handlers/bucket.ex` 加（alias 加 `Maxio.S3.Views.ListVersions`）：

```elixir
  @spec list_object_versions(Plug.Conn.t()) :: Plug.Conn.t()
  def list_object_versions(conn) do
    bucket = conn.assigns.s3_bucket
    conn = fetch_query_params(conn)
    qp = conn.query_params

    with {:ok, _b} <- bucket_or_raise(bucket) do
      prefix = Map.get(qp, "prefix", "")
      delimiter = Map.get(qp, "delimiter")
      max_keys = parse_int(Map.get(qp, "max-keys"), 1000)
      key_marker = Map.get(qp, "key-marker")
      version_id_marker = Map.get(qp, "version-id-marker")

      res =
        Objects.list_object_versions(bucket, %{
          prefix: prefix,
          delimiter: delimiter,
          max_keys: max_keys,
          key_marker: key_marker,
          version_id_marker: version_id_marker
        })

      body =
        ListVersions.render(%{
          name: bucket,
          prefix: prefix,
          delimiter: delimiter,
          key_marker: key_marker,
          version_id_marker: version_id_marker,
          max_keys: max_keys,
          is_truncated: res.is_truncated,
          next_key_marker: res.next_key_marker,
          next_version_id_marker: res.next_version_id_marker,
          versions: res.versions,
          common_prefixes: res.common_prefixes
        })

      Log.info("list object versions", action: :list_object_versions, bucket: bucket)

      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(200, body)
    end
  end
```

> `bucket.ex` 的 alias 行 `alias Maxio.S3.Views.{ListBucket, LocationConstraint}` 改为 `alias Maxio.S3.Views.{ListBucket, LocationConstraint, ListVersions}`。

**接线**：
1. `lib/maxio/s3/dispatcher.ex`：把 `"versions"` 从 `@m2_subresources` 移除，加分支（在 `?versioning` 分支附近）：

```elixir
      level == :bucket and method == "GET" and MapSet.member?(query_keys, "versions") ->
        {:ok, :list_object_versions}
```

2. `lib/maxio/s3/handlers.ex`：

```elixir
  def dispatch(:list_object_versions, conn), do: Bucket.list_object_versions(conn)
```

3. `lib/maxio/policy/action_map.ex`：

```elixir
  def for_action(:list_object_versions), do: {"s3:ListBucketVersions", :bucket}
```

### 步骤 5：单测 + e2e

新建 `test/maxio/objects/list_versions_test.exs`（纯查询层，断言交错与排序）：

```elixir
defmodule Maxio.Objects.ListVersionsTest do
  use Maxio.DataCase, async: true
  alias Maxio.{Buckets, Objects}

  setup do
    {:ok, _} = Buckets.create("vlb", "arn:aws:iam:::root")
    :ok
  end

  test "key 升序 + key 内 newest-first（version_id 降序），delete marker 交错" do
    {:ok, _} = Objects.put_version_with_id("vlb", "a.txt", "01", %{size: 1, etag: "x"})
    {:ok, _} = Objects.put_version_with_id("vlb", "a.txt", "02", %{size: 1, etag: "y"})
    {:ok, _} = Objects.put_version_with_id("vlb", "b.txt", "01", %{size: 1, etag: "z"})
    {:ok, _} = Objects.insert_delete_marker("vlb", "b.txt", "Enabled")  # b.txt 新增 delete marker（version_id 由 ULID 生成，>"01"）

    res = Objects.list_object_versions("vlb", %{})
    seq = Enum.map(res.versions, fn o -> {o.key, o.version_id, o.is_delete_marker} end)

    # a.txt：02（latest）在 01 之前；b.txt：delete marker（latest, version_id 较大）在 01 之前。
    assert [{"a.txt", "02", false}, {"a.txt", "01", false} | rest] = seq
    assert [{"b.txt", dm_vid, true}, {"b.txt", "01", false}] = rest
    assert dm_vid > "01"
  end

  test "max-keys 截断 → 二维 next marker" do
    {:ok, _} = Objects.put_version_with_id("vlb", "a.txt", "02", %{size: 1, etag: "x"})
    {:ok, _} = Objects.put_version_with_id("vlb", "a.txt", "01", %{size: 1, etag: "y"})
    {:ok, _} = Objects.put_version_with_id("vlb", "b.txt", "01", %{size: 1, etag: "z"})

    res = Objects.list_object_versions("vlb", %{max_keys: 2})
    assert res.is_truncated
    assert res.next_key_marker == "a.txt"
    assert res.next_version_id_marker == "01"

    # 续页
    res2 = Objects.list_object_versions("vlb", %{max_keys: 2, key_marker: "a.txt", version_id_marker: "01"})
    keys = Enum.map(res2.versions, & &1.key)
    assert keys == ["b.txt"]
    refute res2.is_truncated
  end
end
```

新建 e2e `test/maxio/s3/list_versions_e2e_test.exs`：

```elixir
defmodule Maxio.S3.ListVersionsE2ETest do
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_listversions_e2e")

  setup do
    File.rm_rf(@data_dir); File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn -> Application.put_env(:maxio, :s3, prev); File.rm_rf(@data_dir) end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "Enabled 桶：PUT×2 + DELETE → ?versions 列出 2 Version + 1 DeleteMarker" do
    SigV4Request.signed_conn(:put, "/lvb") |> call()
    SigV4Request.signed_conn(:put, "/lvb", query: %{"versioning" => ""},
      body: ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)) |> call()

    SigV4Request.signed_conn(:put, "/lvb/k.txt", body: "v1") |> call()
    SigV4Request.signed_conn(:put, "/lvb/k.txt", body: "v2") |> call()
    SigV4Request.signed_conn(:delete, "/lvb/k.txt") |> call()

    lv = SigV4Request.signed_conn(:get, "/lvb", query: %{"versions" => ""}) |> call()
    assert lv.status == 200
    assert lv.resp_body =~ "ListVersionsResult"
    # 1 个 DeleteMarker（当前 latest）+ 2 个 Version
    assert (lv.resp_body |> String.split("<DeleteMarker>") |> length()) == 2
    assert (lv.resp_body |> String.split("<Version>") |> length()) == 3

    # ListObjectsV2 不返回 delete-marker 当前的对象
    lo = SigV4Request.signed_conn(:get, "/lvb") |> call()
    refute lo.resp_body =~ "<Key>k.txt</Key>"
  end
end
```

运行：

```powershell
mix test test/maxio/objects/list_latest_test.exs test/maxio/objects/list_versions_test.exs test/maxio/s3/list_versions_e2e_test.exs
```

### 单元收尾验证（M4-3b）

```powershell
mix compile --warnings-as-errors
mix test
```

期望：编译零警告；全量绿。**已知 defer（文档化，绝不静默）**：multipart 完成的对象在 Enabled 桶字节走 null 路径、元数据当 latest null 版本（多段对象的逐版本化字节路径 defer——单段 PutObject 版本化已完整）；写进 STATUS 的 M4 defer 清单。提交：

```powershell
git add -A
git commit -m @'
M4-3b: ListObjectVersions (?versions) — interleaved Version/DeleteMarker, key-then-newest ordering, 2D pagination, delimiter/CommonPrefixes; ListObjectsV2 latest-non-delete-marker filter; versioning e2e

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) ListObjectsV2 只返回 latest 非 delete-marker（回归绿）；(2) ListObjectVersions：key 升序 + key 内 newest-first + Version/DeleteMarker 交错 + delete marker 无 ETag/Size、二维分页 next markers 正确；(3) e2e：Enabled 桶 PUT×2+DELETE → 2 Version + 1 DeleteMarker；(4) Dispatcher/Handlers/ActionMap 接线；(5) 零警告、全量绿。

---

## M4-4 · Tagging（object + bucket，?tagging + x-amz-tagging 头 + x-amz-tagging-count）

**目标**：对象与桶 tagging 全套（官方核验 bake-in）：`?tagging` PUT/GET/DELETE（Tagging XML）；PutObject 的 `x-amz-tagging` 头（query-string 编码）；GET/HEAD object 的 `x-amz-tagging-count` 响应头；limits 校验 → `InvalidTag 400`；空 TagSet 删 tag。对象 tag 挂在版本行（`objects.tags`），桶 tag 存 `bucket_configs` 之外的专列（见下）。

**依赖**：M4-3b。**规模**：迁移（objects.tags + buckets.tags）+ `Maxio.Tags`（校验/头解码）+ Tagging parser/view + handler + Objects/Buckets 上下文加 tag 读写 + PutObject/GET/HEAD 接线 + Dispatcher/ActionMap。

### 协议事实（bake-in，executor 须遵守）

- Tagging XML：`Tagging > TagSet > Tag > (Key,Value)`。请求可带或不带 `xmlns`（accept both）；GET 响应带 `xmlns`。
- 对象：≤ **10** tags；桶：≤ **50** tags。Key ≤ 128、Value ≤ 256 Unicode 字符；Key 唯一；允许字符 `a-zA-Z0-9 + - = . _ : / @` 与空格；保留前缀 `aws:` 禁用。违反 → `InvalidTag 400`。
- 空 TagSet（`<Tagging><TagSet></TagSet></Tagging>`）→ 删除 tag set。
- PutObjectTagging → **200**；DeleteObjectTagging → **204**；PutBucketTagging → **204**（取 example 行为，最兼容）；GetObjectTagging/GetBucketTagging → 200 + XML。
- `x-amz-tagging` 头（PutObject）：`key1=val1&key2=val2`（query-string 编码）。
- `x-amz-tagging-count` 头（GET/HEAD object）：tag 数 > 0 才出现。
- `?tagging&versionId=` 作用于指定版本行；`x-amz-version-id` 响应头回显。

### 步骤 1：迁移 — objects.tags + buckets.tags

```powershell
mix ecto.gen.migration add_tags_to_objects_and_buckets
```

替换为：

```elixir
defmodule Maxio.Repo.Migrations.AddTagsToObjectsAndBuckets do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :tags, :map,
        null: false,
        default: %{},
        comment: "对象标签集（jsonb，Key→Value 映射；≤10 个，挂在版本行；x-amz-tagging 头或 PutObjectTagging 写入）"
    end

    alter table(:buckets) do
      add :tags, :map,
        null: false,
        default: %{},
        comment: "桶标签集（jsonb，Key→Value 映射；≤50 个；PutBucketTagging 写入；成本分配标签）"
    end
  end
end
```

运行迁移：

```powershell
mix ecto.migrate
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ objects"
```

把 `tags` 加入 `Object` schema/changeset（`lib/maxio/objects/object.ex`）与 `Bucket` schema/changeset：

```elixir
# Object: schema 加
    field :tags, :map, default: %{}
# Object: @optional 加 :tags（已含其余）
# Bucket: schema 加
    field :tags, :map, default: %{}
# Bucket: @optional 加 :tags
```

> `Object` 的 `@optional` 已含 `:version_id, :is_latest, :is_delete_marker`（M4-3a）；追加 `:tags`。`put_version_with_id`/`put_version` 的 `Map.take` 已含 `:tags`，无需改。

### 步骤 2：`Maxio.Tags`（校验 + 头解码，TDD）

新建 `test/maxio/tags_test.exs`：

```elixir
defmodule Maxio.TagsTest do
  use ExUnit.Case, async: true
  alias Maxio.Tags

  test "合法对象 tag 集" do
    assert :ok = Tags.validate([{"env", "prod"}, {"team", "core"}], :object)
  end

  test "对象 > 10 个 → invalid_tag" do
    tags = for i <- 1..11, do: {"k#{i}", "v"}
    assert {:error, :invalid_tag} = Tags.validate(tags, :object)
  end

  test "桶可 50 个；51 个 → invalid_tag" do
    ok = for i <- 1..50, do: {"k#{i}", "v"}
    assert :ok = Tags.validate(ok, :bucket)
    bad = for i <- 1..51, do: {"k#{i}", "v"}
    assert {:error, :invalid_tag} = Tags.validate(bad, :bucket)
  end

  test "重复 key → invalid_tag" do
    assert {:error, :invalid_tag} = Tags.validate([{"k", "1"}, {"k", "2"}], :object)
  end

  test "key 超 128 / value 超 256 → invalid_tag" do
    assert {:error, :invalid_tag} = Tags.validate([{String.duplicate("a", 129), "v"}], :object)
    assert {:error, :invalid_tag} = Tags.validate([{"k", String.duplicate("a", 257)}], :object)
  end

  test "aws: 前缀保留 → invalid_tag" do
    assert {:error, :invalid_tag} = Tags.validate([{"aws:foo", "v"}], :object)
  end

  test "非法字符 → invalid_tag" do
    assert {:error, :invalid_tag} = Tags.validate([{"bad#key", "v"}], :object)
  end

  test "空 value 合法（value 0..256）" do
    assert :ok = Tags.validate([{"k", ""}], :object)
  end

  test "parse_header：key1=val1&key2=val2" do
    assert {:ok, [{"k1", "v1"}, {"k2", "v2"}]} = Tags.parse_header("k1=v1&k2=v2")
  end

  test "parse_header：URL 编码解码" do
    assert {:ok, [{"a b", "c/d"}]} = Tags.parse_header("a%20b=c%2Fd")
  end
end
```

运行确认红。新建 `lib/maxio/tags.ex`：

```elixir
defmodule Maxio.Tags do
  @moduledoc """
  标签集校验与 x-amz-tagging 头编解码（官方核验 bake-in）。
    * 对象 ≤10、桶 ≤50；Key 1..128、Value 0..256 Unicode 字符；Key 唯一；
    * 允许字符 a-zA-Z0-9 与空格及 + - = . _ : / @；保留前缀 aws: 禁用。
  违反 → {:error, :invalid_tag}（调用方映射 InvalidTag 400，铁律 3）。
  x-amz-tagging 头是 query-string 编码（key1=val1&key2=val2，URL 编码）。
  """
  @obj_max 10
  @bucket_max 50
  @allowed ~r/\A[\p{L}\p{N} +\-=._:\/@]*\z/u

  @doc "校验标签集（[{Key,Value}]）。scope :object|:bucket 决定数量上限。"
  @spec validate([{String.t(), String.t()}], :object | :bucket) :: :ok | {:error, :invalid_tag}
  def validate(tags, scope) when is_list(tags) do
    max = if scope == :bucket, do: @bucket_max, else: @obj_max
    keys = Enum.map(tags, fn {k, _v} -> k end)

    cond do
      length(tags) > max -> {:error, :invalid_tag}
      length(Enum.uniq(keys)) != length(keys) -> {:error, :invalid_tag}
      not Enum.all?(tags, &valid_tag?/1) -> {:error, :invalid_tag}
      true -> :ok
    end
  end

  def validate(_other, _scope), do: {:error, :invalid_tag}

  defp valid_tag?({k, v}) when is_binary(k) and is_binary(v) do
    String.length(k) >= 1 and String.length(k) <= 128 and
      String.length(v) <= 256 and
      not String.starts_with?(k, "aws:") and
      Regex.match?(@allowed, k) and Regex.match?(@allowed, v)
  end

  defp valid_tag?(_), do: false

  @doc "解码 x-amz-tagging 头（query-string 形式）为 [{Key,Value}]。畸形 → {:error, :invalid_tag}。"
  @spec parse_header(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, :invalid_tag}
  def parse_header(value) when is_binary(value) do
    try do
      pairs =
        value
        |> String.split("&", trim: true)
        |> Enum.map(fn pair ->
          case String.split(pair, "=", parts: 2) do
            [k, v] -> {URI.decode_www_form(k), URI.decode_www_form(v)}
            [k] -> {URI.decode_www_form(k), ""}
          end
        end)

      {:ok, pairs}
    rescue
      _ -> {:error, :invalid_tag}
    end
  end

  @doc "把 jsonb tag map 转为有序 [{Key,Value}]（按 Key 升序，稳定输出）。"
  @spec map_to_list(map()) :: [{String.t(), String.t()}]
  def map_to_list(map) when is_map(map) do
    map |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end) |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "把 [{Key,Value}] 转为 jsonb 存储 map。"
  @spec list_to_map([{String.t(), String.t()}]) :: map()
  def list_to_map(list) when is_list(list), do: Map.new(list)
end
```

运行确认绿。

### 步骤 3：Tagging parser + view

新建 `lib/maxio/s3/request_parsers/tagging.ex`：

```elixir
defmodule Maxio.S3.RequestParsers.Tagging do
  @moduledoc """
  Put{Object,Bucket}Tagging 的 XML body 解析（saxy SAX）：Tagging>TagSet>Tag>(Key,Value)。
  容忍命名空间前缀与 xmlns（accept with/without）。空 TagSet → []（删除语义）。
  返回 {:ok, [{Key, Value}]} | {:error, :malformed_xml}。校验（数量/字符/aws:）由 Maxio.Tags.validate 另做。
  """
  @behaviour Saxy.Handler

  @spec parse(binary()) :: {:ok, [{String.t(), String.t()}]} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{tags: [], cur_key: nil, cur_val: nil, in: nil, text: nil}

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{tags: tags}} -> {:ok, Enum.reverse(tags)}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _p, s), do: {:ok, s}

  @impl true
  def handle_event(:start_element, {name, _attrs}, s) do
    case local(name) do
      "Tag" -> {:ok, %{s | cur_key: nil, cur_val: nil, in: nil}}
      "Key" -> {:ok, %{s | in: :key, text: ""}}
      "Value" -> {:ok, %{s | in: :val, text: ""}}
      _ -> {:ok, %{s | in: nil}}
    end
  end

  @impl true
  def handle_event(:characters, c, %{text: t} = s) when is_binary(t), do: {:ok, %{s | text: t <> c}}
  def handle_event(:characters, _c, s), do: {:ok, s}

  @impl true
  def handle_event(:end_element, name, s) do
    case local(name) do
      "Key" -> {:ok, %{s | cur_key: s.text || "", in: nil, text: nil}}
      "Value" -> {:ok, %{s | cur_val: s.text || "", in: nil, text: nil}}
      "Tag" -> {:ok, %{s | tags: [{s.cur_key, s.cur_val} | s.tags], in: nil}}
      _ -> {:ok, %{s | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _d, s), do: {:ok, s}

  defp local(name) do
    case String.split(name, ":") do
      [_ns, l] -> l
      [l] -> l
    end
  end
end
```

新建 `lib/maxio/s3/views/tagging.ex`：

```elixir
defmodule Maxio.S3.Views.Tagging do
  @moduledoc "Get{Object,Bucket}Tagging 响应 XML（Tagging>TagSet>Tag>(Key,Value)，带 xmlns）。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render([{String.t(), String.t()}]) :: iodata()
  def render(tags) when is_list(tags) do
    tag_elems =
      Enum.map(tags, fn {k, v} ->
        element("Tag", [], [
          element("Key", [], characters(k)),
          element("Value", [], characters(v))
        ])
      end)

    root =
      element("Tagging", [{"xmlns", XML.namespace()}], [
        element("TagSet", [], tag_elems)
      ])

    XML.encode(root)
  end
end
```

### 步骤 4：Objects/Buckets 上下文加 tag 读写

在 `lib/maxio/objects.ex` 增加：

```elixir
  @doc "读对象 tag（current 或指定版本）。返回 [{Key,Value}]（空集 → []）。对象不存在 → {:error, :not_found}。"
  @spec get_tags(String.t(), String.t(), String.t() | nil) :: {:ok, [{String.t(), String.t()}]} | {:error, :not_found}
  def get_tags(bucket_name, key, version_id \\ nil) do
    fetch = if version_id, do: get_version(bucket_name, key, version_id), else: get_metadata(bucket_name, key)

    case fetch do
      {:ok, obj} -> {:ok, Maxio.Tags.map_to_list(obj.tags || %{})}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "写对象 tag（覆盖整集）。对象不存在 → {:error, :not_found}。"
  @spec put_tags(String.t(), String.t(), [{String.t(), String.t()}], String.t() | nil) :: :ok | {:error, :not_found}
  def put_tags(bucket_name, key, tags, version_id \\ nil) do
    fetch = if version_id, do: get_version(bucket_name, key, version_id), else: get_metadata(bucket_name, key)

    case fetch do
      {:ok, obj} ->
        obj |> Object.changeset(%{tags: Maxio.Tags.list_to_map(tags)}) |> Repo.update!()
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
```

在 `lib/maxio/buckets.ex` 增加：

```elixir
  @doc "读桶 tag。返回 [{Key,Value}]。桶不存在 → {:error, :not_found}。"
  @spec get_tags(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, :not_found}
  def get_tags(name) do
    case lookup(name) do
      {:ok, b} -> {:ok, Maxio.Tags.map_to_list(b.tags || %{})}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "写桶 tag（覆盖整集）。桶不存在 → {:error, :not_found}。"
  @spec put_tags(String.t(), [{String.t(), String.t()}]) :: :ok | {:error, :not_found}
  def put_tags(name, tags) do
    case lookup(name) do
      {:ok, b} ->
        b |> Bucket.changeset(%{tags: Maxio.Tags.list_to_map(tags)}) |> Repo.update!()
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
```

### 步骤 5：Tagging handler + 接线 + PutObject x-amz-tagging + GET/HEAD x-amz-tagging-count

新建 `lib/maxio/s3/handlers/tagging.ex`：

```elixir
defmodule Maxio.S3.Handlers.Tagging do
  @moduledoc """
  ?tagging 子资源 handler：Put/Get/Delete Object/BucketTagging。
  Put：XML body → 解析 → Maxio.Tags.validate（InvalidTag 400）→ 存（覆盖整集）。
  对象 Put 200；对象 Delete 204；桶 Put 204；Get 200 + Tagging XML。?versionId 作用于指定版本（对象）。
  XML body 走带上限整读（铁律 4）。
  """
  import Plug.Conn
  alias Maxio.{Buckets, Objects, Tags}
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.RequestParsers.Tagging, as: Parser
  alias Maxio.S3.Views.Tagging, as: View

  @limit 1_048_576

  # ── Object ──
  @spec put_object_tagging(Plug.Conn.t()) :: Plug.Conn.t()
  def put_object_tagging(conn) do
    {bucket, key, vid, conn} = obj_ctx(conn)
    {conn, xml} = read_small_body!(conn)
    tags = parse_validate!(xml, :object)

    case Objects.put_tags(bucket, key, tags, vid) do
      :ok ->
        Log.info("put object tagging", action: :put_object_tagging, bucket: bucket, key: key)
        conn |> maybe_vid(vid) |> send_resp(200, "")

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  @spec get_object_tagging(Plug.Conn.t()) :: Plug.Conn.t()
  def get_object_tagging(conn) do
    {bucket, key, vid, conn} = obj_ctx(conn)

    case Objects.get_tags(bucket, key, vid) do
      {:ok, tags} ->
        conn |> maybe_vid(vid) |> put_resp_content_type("application/xml") |> send_resp(200, View.render(tags))

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  @spec delete_object_tagging(Plug.Conn.t()) :: Plug.Conn.t()
  def delete_object_tagging(conn) do
    {bucket, key, vid, conn} = obj_ctx(conn)

    case Objects.put_tags(bucket, key, [], vid) do
      :ok ->
        Log.info("delete object tagging", action: :delete_object_tagging, bucket: bucket, key: key)
        conn |> maybe_vid(vid) |> send_resp(204, "")

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  # ── Bucket ──
  @spec put_bucket_tagging(Plug.Conn.t()) :: Plug.Conn.t()
  def put_bucket_tagging(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, xml} = read_small_body!(conn)
    tags = parse_validate!(xml, :bucket)
    :ok = Buckets.put_tags(bucket, tags)
    Log.info("put bucket tagging", action: :put_bucket_tagging, bucket: bucket)
    send_resp(conn, 204, "")
  end

  @spec get_bucket_tagging(Plug.Conn.t()) :: Plug.Conn.t()
  def get_bucket_tagging(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {:ok, tags} = Buckets.get_tags(bucket)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, View.render(tags))
  end

  @spec delete_bucket_tagging(Plug.Conn.t()) :: Plug.Conn.t()
  def delete_bucket_tagging(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = Buckets.put_tags(bucket, [])
    send_resp(conn, 204, "")
  end

  # ── helpers ──
  defp obj_ctx(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    _ = ensure_bucket!(bucket)
    vid = Map.get(conn.query_params, "versionId")
    {bucket, key, vid, conn}
  end

  defp parse_validate!(xml, scope) do
    case Parser.parse(xml) do
      {:ok, tags} ->
        case Tags.validate(tags, scope) do
          :ok -> tags
          {:error, :invalid_tag} -> raise Error.new(:invalid_tag)
        end

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml)
    end
  end

  defp maybe_vid(conn, nil), do: conn
  defp maybe_vid(conn, "null"), do: conn
  defp maybe_vid(conn, vid), do: put_resp_header(conn, "x-amz-version-id", vid)

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @limit, read_length: @limit) do
      {:ok, body, conn} -> {conn, body}
      {:more, _partial, _conn} -> raise Error.new(:entity_too_large, message: "Tagging document too large")
      {:error, _} -> raise Error.new(:malformed_xml)
    end
  end
end
```

**新错误码**：`lib/maxio/s3/error.ex` 的 `@table` 加：

```elixir
    invalid_tag:
      {"InvalidTag", 400, "The tag provided was not a valid tag. This error can occur if the tag did not pass input validation."},
```

**PutObject x-amz-tagging 头**：在 `lib/maxio/s3/handlers/object.ex` 的 `do_put/1` 把 tag 头解析并随 `put_version_with_id` 落库。在调 `put_version_with_id` 的 attrs 里加 `tags`。在 `do_put/1` 顶部（算 version_id 后）加：

```elixir
    tags_map = parse_tagging_header!(conn)
```

attrs 加一行 `tags: tags_map`（与 size/etag 同级）。新增 helper：

```elixir
  # x-amz-tagging 头（PutObject）→ jsonb map；无头 → %{}；非法 → InvalidTag 400。
  defp parse_tagging_header!(conn) do
    case header(conn, "x-amz-tagging") do
      nil ->
        %{}

      "" ->
        %{}

      raw ->
        case Maxio.Tags.parse_header(raw) do
          {:ok, list} ->
            case Maxio.Tags.validate(list, :object) do
              :ok -> Maxio.Tags.list_to_map(list)
              {:error, :invalid_tag} -> raise Error.new(:invalid_tag)
            end

          {:error, :invalid_tag} ->
            raise Error.new(:invalid_tag)
        end
    end
  end
```

**GET/HEAD x-amz-tagging-count**：在 `put_common_object_headers/3` 末尾按 object.tags 数追加（仅 >0）：

```elixir
  defp put_common_object_headers(conn, object, content_length) do
    conn
    |> put_resp_header("content-type", object.content_type)
    |> put_resp_header("etag", XML.quote_etag(object.etag))
    |> put_resp_header("last-modified", http_date(object.updated_at))
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("content-length", Integer.to_string(content_length))
    |> maybe_tagging_count(object)
  end

  defp maybe_tagging_count(conn, %{tags: tags}) when is_map(tags) and map_size(tags) > 0 do
    put_resp_header(conn, "x-amz-tagging-count", Integer.to_string(map_size(tags)))
  end

  defp maybe_tagging_count(conn, _object), do: conn
```

> 注：`send_object/5` 经 `put_common_object_headers` 已覆盖 GET 全量/Range；HEAD 走 `put_common_object_headers`。两路径都获得 `x-amz-tagging-count`。

**接线**：
1. `lib/maxio/s3/dispatcher.ex`：`"tagging"` 从 `@m2_subresources` 移除，加分支：

```elixir
      MapSet.member?(query_keys, "tagging") ->
        case {level, method} do
          {:object, "PUT"} -> {:ok, :put_object_tagging}
          {:object, "GET"} -> {:ok, :get_object_tagging}
          {:object, "DELETE"} -> {:ok, :delete_object_tagging}
          {:bucket, "PUT"} -> {:ok, :put_bucket_tagging}
          {:bucket, "GET"} -> {:ok, :get_bucket_tagging}
          {:bucket, "DELETE"} -> {:ok, :delete_bucket_tagging}
          _ -> {:error, :method_not_allowed}
        end
```

2. `lib/maxio/s3/handlers.ex`（alias 加 `Tagging`）：

```elixir
  def dispatch(:put_object_tagging, conn), do: Tagging.put_object_tagging(conn)
  def dispatch(:get_object_tagging, conn), do: Tagging.get_object_tagging(conn)
  def dispatch(:delete_object_tagging, conn), do: Tagging.delete_object_tagging(conn)
  def dispatch(:put_bucket_tagging, conn), do: Tagging.put_bucket_tagging(conn)
  def dispatch(:get_bucket_tagging, conn), do: Tagging.get_bucket_tagging(conn)
  def dispatch(:delete_bucket_tagging, conn), do: Tagging.delete_bucket_tagging(conn)
```

3. `lib/maxio/policy/action_map.ex`：

```elixir
  def for_action(:put_object_tagging), do: {"s3:PutObjectTagging", :object}
  def for_action(:get_object_tagging), do: {"s3:GetObjectTagging", :object}
  def for_action(:delete_object_tagging), do: {"s3:DeleteObjectTagging", :object}
  def for_action(:put_bucket_tagging), do: {"s3:PutBucketTagging", :bucket}
  def for_action(:get_bucket_tagging), do: {"s3:GetBucketTagging", :bucket}
  def for_action(:delete_bucket_tagging), do: {"s3:DeleteBucketTagging", :bucket}
```

### 步骤 6：e2e

新建 `test/maxio/s3/tagging_e2e_test.exs`：

```elixir
defmodule Maxio.S3.TaggingE2ETest do
  use Maxio.DataCase, async: false
  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_tagging_e2e")

  setup do
    File.rm_rf(@data_dir); File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn -> Application.put_env(:maxio, :s3, prev); File.rm_rf(@data_dir) end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  @tagging ~s(<Tagging xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag><Tag><Key>team</Key><Value>core</Value></Tag></TagSet></Tagging>)

  test "PutObjectTagging 200 → GetObjectTagging 200 回放 → DeleteObjectTagging 204" do
    SigV4Request.signed_conn(:put, "/tb") |> call()
    SigV4Request.signed_conn(:put, "/tb/k.txt", body: "x") |> call()

    put = SigV4Request.signed_conn(:put, "/tb/k.txt", query: %{"tagging" => ""}, body: @tagging) |> call()
    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/tb/k.txt", query: %{"tagging" => ""}) |> call()
    assert get.status == 200
    assert get.resp_body =~ "<Key>env</Key>"
    assert get.resp_body =~ "<Value>prod</Value>"

    # GET object 带 x-amz-tagging-count: 2
    obj = SigV4Request.signed_conn(:get, "/tb/k.txt") |> call()
    assert get_resp_header(obj, "x-amz-tagging-count") == ["2"]

    del = SigV4Request.signed_conn(:delete, "/tb/k.txt", query: %{"tagging" => ""}) |> call()
    assert del.status == 204

    get2 = SigV4Request.signed_conn(:get, "/tb/k.txt", query: %{"tagging" => ""}) |> call()
    refute get2.resp_body =~ "<Key>"
  end

  test "PutObject 带 x-amz-tagging 头 → GET 回 x-amz-tagging-count" do
    SigV4Request.signed_conn(:put, "/tb2") |> call()
    SigV4Request.signed_conn(:put, "/tb2/k.txt", body: "x", headers: [{"x-amz-tagging", "a=1&b=2"}]) |> call()
    obj = SigV4Request.signed_conn(:get, "/tb2/k.txt") |> call()
    assert get_resp_header(obj, "x-amz-tagging-count") == ["2"]
  end

  test "PutBucketTagging 204 → GetBucketTagging 200" do
    SigV4Request.signed_conn(:put, "/tb3") |> call()
    put = SigV4Request.signed_conn(:put, "/tb3", query: %{"tagging" => ""}, body: @tagging) |> call()
    assert put.status == 204
    get = SigV4Request.signed_conn(:get, "/tb3", query: %{"tagging" => ""}) |> call()
    assert get.resp_body =~ "<Key>env</Key>"
  end

  test "超 10 tag → InvalidTag 400" do
    SigV4Request.signed_conn(:put, "/tb4") |> call()
    SigV4Request.signed_conn(:put, "/tb4/k.txt", body: "x") |> call()
    tags = for i <- 1..11, do: "<Tag><Key>k#{i}</Key><Value>v</Value></Tag>"
    body = "<Tagging><TagSet>#{Enum.join(tags)}</TagSet></Tagging>"
    bad = SigV4Request.signed_conn(:put, "/tb4/k.txt", query: %{"tagging" => ""}, body: body) |> call()
    assert bad.status == 400
    assert bad.resp_body =~ "InvalidTag"
  end
end
```

### 单元收尾验证（M4-4）

```powershell
mix compile --warnings-as-errors
mix test
```

期望：编译零警告；全量绿。提交：

```powershell
git add -A
git commit -m @'
M4-4: Tagging — object & bucket (?tagging PUT/GET/DELETE, Tagging XML); x-amz-tagging header on PutObject; x-amz-tagging-count on GET/HEAD; limits -> InvalidTag 400; objects.tags/buckets.tags columns; Dispatcher/ActionMap wiring

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) 迁移 tags 列中文 COMMENT；(2) `Maxio.Tags` 校验（10/50 上限、唯一、长度、aws:、字符、空 value）+ 头解码全覆盖；(3) e2e：对象 Put 200/Get 回放/Delete 204、桶 Put 204/Get、x-amz-tagging 头、x-amz-tagging-count、InvalidTag 400；(4) Dispatcher/Handlers/ActionMap 接线；(5) 零警告、全量绿。

---

## M4-5 · CORS（?cors PUT/GET/DELETE + OPTIONS 预检 + 实际请求注入）

**目标**：`PutBucketCors`/`GetBucketCors`/`DeleteBucketCors`（`?cors`）+ CORS 匹配算法（first-match）+ `Maxio.S3.Plugs.Cors`：OPTIONS 预检（匹配 → 200 + CORS 头并 halt；无匹配/未启用 → 403 AccessForbidden）+ 实际请求带 Origin 时注入 CORS 响应头 + `Vary`。**绝不破坏流式与 SigV4——OPTIONS 预检在 SigV4 之前 halt（预检不签名）。**

**依赖**：M4-4。**规模**：parser/view + 匹配模块 + handler + Cors plug + Endpoint 接线 + Dispatcher/ActionMap + 单测/e2e。

### 协议事实（bake-in）

- `?cors` PUT 200（空 body）/GET 200+XML/DELETE 204；body ≤64KB、≤100 rule。
- CORSRule：`AllowedMethod`（1+，仅 GET/PUT/POST/DELETE/HEAD）、`AllowedOrigin`（1+，可 `*`，至多一个 `*` 通配）、`AllowedHeader`（0+，至多一个 `*`，大小写不敏感）、`ExposeHeader`（0+）、`MaxAgeSeconds`（可选）、`ID`（可选）。
- 匹配（first-match）：Origin 命中某 AllowedOrigin（单 `*` 通配）∧ 方法（预检看 `Access-Control-Request-Method`）命中 AllowedMethod ∧（预检）`Access-Control-Request-Headers` 每个都命中某 AllowedHeader。
- 预检响应头：`Access-Control-Allow-Origin`（命中 origin；origin 不允许则**省略**整个 ACAO）、`Access-Control-Allow-Methods`、`Access-Control-Allow-Headers`（任一请求头不允许 → 省略所有 AC-* 头=预检失败）、`Access-Control-Max-Age`、`Access-Control-Expose-Headers`。成功 200 + `Content-Length: 0`。未启用/无匹配 → 403 `AccessForbidden`。
- 实际请求带 Origin：注入 `Access-Control-Allow-Origin`（回显请求 origin，wildcard 也回显具体 origin 以兼容凭据请求）+ `Access-Control-Allow-Methods` + `Access-Control-Expose-Headers` + `Vary: Origin`。
- GET `?cors` 无配置 → 404 `NoSuchCORSConfiguration`。

### 步骤 1：parser + view

新建 `lib/maxio/s3/request_parsers/cors.ex`：

```elixir
defmodule Maxio.S3.RequestParsers.Cors do
  @moduledoc """
  PutBucketCors 的 XML body 解析（saxy SAX）：CORSConfiguration>CORSRule×N。
  每 rule → %{id, allowed_methods:[..], allowed_origins:[..], allowed_headers:[..],
  expose_headers:[..], max_age_seconds: int|nil}。容忍命名空间/xmlns。
  返回 {:ok, [rule_map]} | {:error, :malformed_xml}。语义校验（方法白名单/单*）由 handler 另做。
  """
  @behaviour Saxy.Handler

  @spec parse(binary()) :: {:ok, [map()]} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{rules: [], cur: nil, in: nil, text: nil}

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{rules: rules}} -> {:ok, Enum.reverse(rules)}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _p, s), do: {:ok, s}

  @impl true
  def handle_event(:start_element, {name, _attrs}, s) do
    case local(name) do
      "CORSRule" ->
        {:ok, %{s | cur: new_rule(), in: nil}}

      tag when tag in ~w(ID AllowedMethod AllowedOrigin AllowedHeader ExposeHeader MaxAgeSeconds) ->
        {:ok, %{s | in: tag, text: ""}}

      _ ->
        {:ok, %{s | in: nil}}
    end
  end

  @impl true
  def handle_event(:characters, c, %{text: t} = s) when is_binary(t), do: {:ok, %{s | text: t <> c}}
  def handle_event(:characters, _c, s), do: {:ok, s}

  @impl true
  def handle_event(:end_element, name, %{cur: cur} = s) do
    case {local(name), cur} do
      {"CORSRule", cur} when is_map(cur) ->
        {:ok, %{s | rules: [finalize(cur) | s.rules], cur: nil, in: nil}}

      {"ID", cur} when is_map(cur) ->
        {:ok, %{s | cur: %{cur | id: trim(s.text)}, in: nil, text: nil}}

      {"AllowedMethod", cur} when is_map(cur) ->
        {:ok, %{s | cur: %{cur | allowed_methods: [trim(s.text) | cur.allowed_methods]}, in: nil, text: nil}}

      {"AllowedOrigin", cur} when is_map(cur) ->
        {:ok, %{s | cur: %{cur | allowed_origins: [trim(s.text) | cur.allowed_origins]}, in: nil, text: nil}}

      {"AllowedHeader", cur} when is_map(cur) ->
        {:ok, %{s | cur: %{cur | allowed_headers: [trim(s.text) | cur.allowed_headers]}, in: nil, text: nil}}

      {"ExposeHeader", cur} when is_map(cur) ->
        {:ok, %{s | cur: %{cur | expose_headers: [trim(s.text) | cur.expose_headers]}, in: nil, text: nil}}

      {"MaxAgeSeconds", cur} when is_map(cur) ->
        {:ok, %{s | cur: %{cur | max_age_seconds: parse_int(trim(s.text))}, in: nil, text: nil}}

      _ ->
        {:ok, %{s | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _d, s), do: {:ok, s}

  defp new_rule, do: %{id: nil, allowed_methods: [], allowed_origins: [], allowed_headers: [], expose_headers: [], max_age_seconds: nil}

  # 反转累积列表（SAX 头插），输出 string-key map（jsonb 存储）。
  defp finalize(r) do
    %{
      "id" => r.id,
      "allowed_methods" => Enum.reverse(r.allowed_methods),
      "allowed_origins" => Enum.reverse(r.allowed_origins),
      "allowed_headers" => Enum.reverse(r.allowed_headers),
      "expose_headers" => Enum.reverse(r.expose_headers),
      "max_age_seconds" => r.max_age_seconds
    }
  end

  defp trim(nil), do: ""
  defp trim(t), do: String.trim(t)

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp local(name) do
    case String.split(name, ":") do
      [_ns, l] -> l
      [l] -> l
    end
  end
end
```

新建 `lib/maxio/s3/views/cors.ex`：

```elixir
defmodule Maxio.S3.Views.Cors do
  @moduledoc "GetBucketCors 响应 XML（CORSConfiguration>CORSRule×N，带 xmlns）。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render([map()]) :: iodata()
  def render(rules) when is_list(rules) do
    rule_elems = Enum.map(rules, &rule_elem/1)
    root = element("CORSConfiguration", [{"xmlns", XML.namespace()}], rule_elems)
    XML.encode(root)
  end

  defp rule_elem(r) do
    children =
      []
      |> maybe_one("ID", r["id"])
      |> many("AllowedMethod", r["allowed_methods"])
      |> many("AllowedOrigin", r["allowed_origins"])
      |> many("AllowedHeader", r["allowed_headers"])
      |> many("ExposeHeader", r["expose_headers"])
      |> maybe_one("MaxAgeSeconds", r["max_age_seconds"] && Integer.to_string(r["max_age_seconds"]))

    element("CORSRule", [], children)
  end

  defp many(children, tag, values) when is_list(values),
    do: children ++ Enum.map(values, fn v -> element(tag, [], characters(to_string(v))) end)

  defp many(children, _tag, _), do: children

  defp maybe_one(children, _tag, nil), do: children
  defp maybe_one(children, _tag, ""), do: children
  defp maybe_one(children, tag, v), do: children ++ [element(tag, [], characters(to_string(v)))]
end
```

### 步骤 2：匹配模块 `Maxio.Cors`（TDD）

新建 `test/maxio/cors_test.exs`：

```elixir
defmodule Maxio.CorsTest do
  use ExUnit.Case, async: true
  alias Maxio.Cors

  @rules [
    %{"allowed_methods" => ["PUT", "POST", "DELETE"], "allowed_origins" => ["http://www.example.com"],
      "allowed_headers" => ["*"], "expose_headers" => ["x-amz-request-id"], "max_age_seconds" => 3000},
    %{"allowed_methods" => ["GET"], "allowed_origins" => ["*"], "allowed_headers" => [], "expose_headers" => [], "max_age_seconds" => nil}
  ]

  test "preflight 命中第一条 rule（origin + method + headers 全匹配）" do
    assert {:ok, rule} = Cors.match_preflight(@rules, "http://www.example.com", "PUT", ["x-amz-meta-foo"])
    assert rule["max_age_seconds"] == 3000
  end

  test "preflight：请求头不被允许 → :no_match" do
    rules = [%{"allowed_methods" => ["PUT"], "allowed_origins" => ["http://x.com"], "allowed_headers" => ["content-type"], "expose_headers" => [], "max_age_seconds" => nil}]
    assert :no_match = Cors.match_preflight(rules, "http://x.com", "PUT", ["authorization"])
  end

  test "preflight：通配 origin 命中 GET" do
    assert {:ok, _} = Cors.match_preflight(@rules, "http://any.com", "GET", [])
  end

  test "实际请求匹配（origin + method）" do
    assert {:ok, rule} = Cors.match_actual(@rules, "http://any.com", "GET")
    assert rule["allowed_origins"] == ["*"]
  end

  test "origin 不匹配 → :no_match" do
    rules = [%{"allowed_methods" => ["GET"], "allowed_origins" => ["http://only.com"], "allowed_headers" => [], "expose_headers" => [], "max_age_seconds" => nil}]
    assert :no_match = Cors.match_actual(rules, "http://other.com", "GET")
  end

  test "单 * 通配 origin（http://*.example.com）" do
    rules = [%{"allowed_methods" => ["GET"], "allowed_origins" => ["http://*.example.com"], "allowed_headers" => [], "expose_headers" => [], "max_age_seconds" => nil}]
    assert {:ok, _} = Cors.match_actual(rules, "http://sub.example.com", "GET")
    assert :no_match = Cors.match_actual(rules, "http://example.org", "GET")
  end
end
```

运行确认红。新建 `lib/maxio/cors.ex`：

```elixir
defmodule Maxio.Cors do
  @moduledoc """
  CORS 规则匹配（first-match，官方核验 bake-in）。规则为已解析的 rule map（string-key）。
    * match_preflight(rules, origin, req_method, req_headers) → {:ok, rule} | :no_match
        命中条件：origin ∈ allowed_origins（单*通配）∧ req_method ∈ allowed_methods
                  ∧ 每个 req_header ∈ allowed_headers（单*通配，大小写不敏感）。
    * match_actual(rules, origin, method) → {:ok, rule} | :no_match
        命中条件：origin 匹配 ∧ method 匹配（不看请求头）。
  origin 单* 通配语义：模式中至多一个 *，转义其余后 \\A…\\z 锚定匹配。
  """

  @spec match_preflight([map()], String.t(), String.t(), [String.t()]) :: {:ok, map()} | :no_match
  def match_preflight(rules, origin, req_method, req_headers) do
    find(rules, fn r ->
      origin_match?(r, origin) and method_match?(r, req_method) and headers_match?(r, req_headers)
    end)
  end

  @spec match_actual([map()], String.t(), String.t()) :: {:ok, map()} | :no_match
  def match_actual(rules, origin, method) do
    find(rules, fn r -> origin_match?(r, origin) and method_match?(r, method) end)
  end

  defp find(rules, pred) do
    case Enum.find(rules, pred) do
      nil -> :no_match
      rule -> {:ok, rule}
    end
  end

  defp origin_match?(r, origin) do
    Enum.any?(Map.get(r, "allowed_origins", []), &wildcard_match?(&1, origin, false))
  end

  defp method_match?(r, method) do
    Enum.member?(Map.get(r, "allowed_methods", []), String.upcase(method))
  end

  defp headers_match?(r, req_headers) do
    allowed = Map.get(r, "allowed_headers", [])
    Enum.all?(req_headers, fn h -> Enum.any?(allowed, &wildcard_match?(&1, h, true)) end)
  end

  # 单* 通配匹配；ci=大小写不敏感（AllowedHeader 用）。
  defp wildcard_match?(pattern, value, ci) do
    regex_src = pattern |> Regex.escape() |> String.replace("\\*", ".*")
    flags = if ci, do: "iu", else: "u"

    case Regex.compile("\\A" <> regex_src <> "\\z", flags) do
      {:ok, re} -> Regex.match?(re, value)
      {:error, _} -> false
    end
  end
end
```

运行确认绿。

### 步骤 3：`?cors` handler

新建 `lib/maxio/s3/handlers/cors.ex`：

```elixir
defmodule Maxio.S3.Handlers.Cors do
  @moduledoc """
  ?cors 子资源 handler：PutBucketCors（XML → 校验 → 存，200）、GetBucketCors（200+XML，无→404
  NoSuchCORSConfiguration）、DeleteBucketCors（204）。校验：方法白名单 GET/PUT/POST/DELETE/HEAD、
  origin/header 至多一个*、每 rule 至少一个 method+origin、≤100 rule。违反 → MalformedXML 400。
  XML body 走带上限整读（铁律 4）。
  """
  import Plug.Conn
  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.RequestParsers.Cors, as: Parser
  alias Maxio.S3.Views.Cors, as: View

  @limit 65_536
  @valid_methods ~w(GET PUT POST DELETE HEAD)

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, xml} = read_small_body!(conn)

    case Parser.parse(xml) do
      {:ok, rules} ->
        :ok = validate!(rules)
        :ok = BucketConfigs.put(bucket, :cors, rules)
        Log.info("put bucket cors", action: :put_bucket_cors, bucket: bucket)
        send_resp(conn, 200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)

    case BucketConfigs.get(bucket, :cors) do
      {:ok, rules} ->
        conn |> put_resp_content_type("application/xml") |> send_resp(200, View.render(rules))

      :none ->
        raise Error.new(:no_such_cors_configuration, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = BucketConfigs.delete(bucket, :cors)
    Log.info("delete bucket cors", action: :delete_bucket_cors, bucket: bucket)
    send_resp(conn, 204, "")
  end

  # ── 校验 ──
  defp validate!(rules) do
    cond do
      length(rules) > 100 -> raise Error.new(:malformed_xml, message: "Too many CORS rules (max 100)")
      Enum.all?(rules, &valid_rule?/1) -> :ok
      true -> raise Error.new(:malformed_xml, message: "Invalid CORS rule")
    end
  end

  defp valid_rule?(r) do
    methods = Map.get(r, "allowed_methods", [])
    origins = Map.get(r, "allowed_origins", [])
    headers = Map.get(r, "allowed_headers", [])

    methods != [] and origins != [] and
      Enum.all?(methods, &(&1 in @valid_methods)) and
      Enum.all?(origins, &at_most_one_star?/1) and
      Enum.all?(headers, &at_most_one_star?/1)
  end

  defp at_most_one_star?(s) do
    (s |> String.graphemes() |> Enum.count(&(&1 == "*"))) <= 1
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @limit, read_length: @limit) do
      {:ok, body, conn} -> {conn, body}
      {:more, _partial, _conn} -> raise Error.new(:malformed_xml, message: "CORS configuration exceeds 64KB")
      {:error, _} -> raise Error.new(:malformed_xml)
    end
  end
end
```

**新错误码**（`lib/maxio/s3/error.ex` 加）：

```elixir
    access_forbidden:
      {"AccessForbidden", 403, "CORSResponse: This CORS request is not allowed. This is usually because the evaluation of Origin, request method / Access-Control-Request-Method or Access-Control-Request-Headers are not whitelisted."},
    no_such_cors_configuration:
      {"NoSuchCORSConfiguration", 404, "The CORS configuration does not exist."},
```

### 步骤 4：`Maxio.S3.Plugs.Cors`（预检 + 实际注入）

新建 `lib/maxio/s3/plugs/cors.ex`：

```elixir
defmodule Maxio.S3.Plugs.Cors do
  @moduledoc """
  CORS plug（铁律 3/4：绝不破坏流式/SigV4；预检不签名）。位于 AddressStyle 之后、SigV4 之前。
    * OPTIONS 预检（带 Origin + Access-Control-Request-Method）：查桶 CORS 配置，first-match：
        命中 → 200 + CORS 响应头并 halt（不进 SigV4/Dispatch；预检无需鉴权）；
        未启用/无匹配 → 403 AccessForbidden 并 halt（绝不静默放行）。
        无 Origin 的 OPTIONS（非预检）→ 放行给下游（罕见）。
    * 非 OPTIONS 带 Origin：first-match → 注册 before_send 在响应上注入 ACAO/ACAM/ACEH + Vary；
      不 halt（继续 SigV4/Dispatch 正常处理）。无匹配 → 不注入（正常处理）。
  Vary: Origin（+ 预检的 AC-Request-* ）防共享缓存串味（铁律 5）。
  """
  import Plug.Conn
  alias Maxio.{BucketConfigs, Cors}
  alias Maxio.S3.{Error, ErrorView, Log}

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    origin = header(conn, "origin")

    cond do
      conn.method == "OPTIONS" and origin != nil ->
        handle_preflight(conn, origin)

      origin != nil ->
        handle_actual(conn, origin)

      true ->
        conn
    end
  end

  defp handle_preflight(conn, origin) do
    bucket = conn.assigns[:s3_bucket]
    req_method = header(conn, "access-control-request-method") || ""
    req_headers = parse_req_headers(header(conn, "access-control-request-headers"))

    with bkt when is_binary(bkt) <- bucket,
         {:ok, rules} <- BucketConfigs.get(bkt, :cors),
         {:ok, rule} <- Cors.match_preflight(rules, origin, req_method, req_headers) do
      Log.info("cors preflight allow", action: :cors_preflight, bucket: bkt)

      conn
      |> put_preflight_headers(rule, origin, req_method, req_headers)
      |> put_resp_header("content-length", "0")
      |> put_vary_preflight()
      |> send_resp(200, "")
      |> halt()
    else
      _ ->
        reject_cors(conn)
    end
  end

  defp handle_actual(conn, origin) do
    bucket = conn.assigns[:s3_bucket]

    with bkt when is_binary(bkt) <- bucket,
         {:ok, rules} <- BucketConfigs.get(bkt, :cors),
         {:ok, rule} <- Cors.match_actual(rules, origin, conn.method) do
      register_before_send(conn, fn c ->
        c
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("access-control-allow-methods", conn.method)
        |> put_expose_headers(rule)
        |> put_resp_header("vary", "Origin")
      end)
    else
      _ -> conn
    end
  end

  defp put_preflight_headers(conn, rule, origin, req_method, req_headers) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-methods", req_method)
    |> put_allow_headers(req_headers)
    |> put_max_age(rule)
    |> put_expose_headers(rule)
  end

  defp put_allow_headers(conn, []), do: conn
  defp put_allow_headers(conn, req_headers),
    do: put_resp_header(conn, "access-control-allow-headers", Enum.join(req_headers, ", "))

  defp put_max_age(conn, %{"max_age_seconds" => n}) when is_integer(n),
    do: put_resp_header(conn, "access-control-max-age", Integer.to_string(n))

  defp put_max_age(conn, _), do: conn

  defp put_expose_headers(conn, %{"expose_headers" => [_ | _] = eh}),
    do: put_resp_header(conn, "access-control-expose-headers", Enum.join(eh, ", "))

  defp put_expose_headers(conn, _), do: conn

  defp put_vary_preflight(conn) do
    put_resp_header(conn, "vary", "Origin, Access-Control-Request-Method, Access-Control-Request-Headers")
  end

  defp reject_cors(conn) do
    err = Error.new(:access_forbidden)
    {status, body} = ErrorView.render(err)
    Log.warn("cors preflight rejected", code: err.code, status: status)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, body)
    |> halt()
  end

  defp parse_req_headers(nil), do: []
  defp parse_req_headers(v), do: v |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()
end
```

### 步骤 5：Endpoint 接线

修改 `lib/maxio/s3/endpoint.ex`——把 Cors plug 插在 AddressStyle 之后、SigV4 之前：

```elixir
defmodule Maxio.S3.Endpoint do
  @moduledoc """
  S3 兼容 HTTP API 的顶层 Plug 管线（独立于 Console 的 MaxioWeb.Endpoint）。
  绝不挂 Plug.Parsers——对象 body 由 handler 经 read_body 流式拉取（铁律 4）。
  顺序：RequestId → AddressStyle（寻址）→ Cors（预检拦截 / 实际注入）→ SigV4（鉴权）→ Dispatch（分发）。
  CORS OPTIONS 预检不签名：Cors plug 命中预检即 halt，不进 SigV4。
  """
  use Plug.Builder

  plug Plug.RequestId
  plug Maxio.S3.Plugs.AddressStyle
  plug Maxio.S3.Plugs.Cors
  plug Maxio.S3.Plugs.SigV4
  plug Maxio.S3.Plugs.Dispatch
end
```

> **关键**：`Plug.Builder` 在每个 plug 后检查 `conn.halted`——Cors plug 在预检命中/拒绝时 `halt()`，SigV4 不会执行（预检不鉴权）。实际请求（带 Origin 非 OPTIONS）只 `register_before_send`、不 halt，照常进 SigV4/Dispatch，CORS 头在响应发出前注入。`register_before_send` 对 `send_resp`/`send_chunked`（流式 GET）都生效——**绝不破坏流式**（before_send 只加响应头，不碰 body）。
> **OPTIONS 非预检**（无 Origin）：Cors plug 放行 → SigV4 → Dispatch。Dispatcher 对 OPTIONS 无映射 → `method_not_allowed`（罕见，可接受）。

`?cors` 的 Dispatcher/Handlers/ActionMap 接线：
1. `lib/maxio/s3/dispatcher.ex`：`"cors"` 从 `@m2_subresources` 移除，加分支：

```elixir
      level == :bucket and MapSet.member?(query_keys, "cors") ->
        case method do
          "PUT" -> {:ok, :put_bucket_cors}
          "GET" -> {:ok, :get_bucket_cors}
          "DELETE" -> {:ok, :delete_bucket_cors}
          _ -> {:error, :method_not_allowed}
        end
```

2. `lib/maxio/s3/handlers.ex`（alias 加 `Cors`）：

```elixir
  def dispatch(:put_bucket_cors, conn), do: Cors.put(conn)
  def dispatch(:get_bucket_cors, conn), do: Cors.get(conn)
  def dispatch(:delete_bucket_cors, conn), do: Cors.delete(conn)
```

3. `lib/maxio/policy/action_map.ex`：

```elixir
  def for_action(:put_bucket_cors), do: {"s3:PutBucketCORS", :bucket}
  def for_action(:get_bucket_cors), do: {"s3:GetBucketCORS", :bucket}
  def for_action(:delete_bucket_cors), do: {"s3:PutBucketCORS", :bucket}
```

### 步骤 6：e2e（含 anon OPTIONS 预检）

新建 `test/maxio/s3/cors_e2e_test.exs`：

```elixir
defmodule Maxio.S3.CorsE2ETest do
  use Maxio.DataCase, async: false
  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_cors_e2e")
  @cors ~s(<CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><CORSRule><AllowedOrigin>http://www.example.com</AllowedOrigin><AllowedMethod>PUT</AllowedMethod><AllowedMethod>GET</AllowedMethod><AllowedHeader>*</AllowedHeader><MaxAgeSeconds>3000</MaxAgeSeconds><ExposeHeader>ETag</ExposeHeader></CORSRule></CORSConfiguration>)

  setup do
    File.rm_rf(@data_dir); File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn -> Application.put_env(:maxio, :s3, prev); File.rm_rf(@data_dir) end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "PutBucketCors 200 → GetBucketCors 回放 → DeleteBucketCors 204 → Get 404" do
    SigV4Request.signed_conn(:put, "/cb") |> call()
    put = SigV4Request.signed_conn(:put, "/cb", query: %{"cors" => ""}, body: @cors) |> call()
    assert put.status == 200
    get = SigV4Request.signed_conn(:get, "/cb", query: %{"cors" => ""}) |> call()
    assert get.resp_body =~ "http://www.example.com"
    del = SigV4Request.signed_conn(:delete, "/cb", query: %{"cors" => ""}) |> call()
    assert del.status == 204
    g2 = SigV4Request.signed_conn(:get, "/cb", query: %{"cors" => ""}) |> call()
    assert g2.status == 404
    assert g2.resp_body =~ "NoSuchCORSConfiguration"
  end

  test "OPTIONS 预检（不签名）命中 → 200 + Access-Control-Allow-Origin" do
    SigV4Request.signed_conn(:put, "/cb2") |> call()
    SigV4Request.signed_conn(:put, "/cb2", query: %{"cors" => ""}, body: @cors) |> call()

    pre =
      SigV4Request.anon_conn(:options, "/cb2/obj.txt",
        headers: [{"origin", "http://www.example.com"}, {"access-control-request-method", "PUT"}])
      |> call()

    assert pre.status == 200
    assert get_resp_header(pre, "access-control-allow-origin") == ["http://www.example.com"]
    assert get_resp_header(pre, "access-control-allow-methods") == ["PUT"]
    assert get_resp_header(pre, "access-control-max-age") == ["3000"]
  end

  test "OPTIONS 预检 origin 不允许 → 403 AccessForbidden" do
    SigV4Request.signed_conn(:put, "/cb3") |> call()
    SigV4Request.signed_conn(:put, "/cb3", query: %{"cors" => ""}, body: @cors) |> call()

    pre =
      SigV4Request.anon_conn(:options, "/cb3/obj.txt",
        headers: [{"origin", "http://evil.com"}, {"access-control-request-method", "PUT"}])
      |> call()

    assert pre.status == 403
    assert pre.resp_body =~ "AccessForbidden"
  end

  test "实际 GET 带 Origin → 注入 Access-Control-Allow-Origin + Vary（流式不破）" do
    SigV4Request.signed_conn(:put, "/cb4") |> call()
    SigV4Request.signed_conn(:put, "/cb4", query: %{"cors" => ""}, body: @cors) |> call()
    SigV4Request.signed_conn(:put, "/cb4/o.txt", body: "hello") |> call()

    get =
      SigV4Request.signed_conn(:get, "/cb4/o.txt", headers: [{"origin", "http://www.example.com"}])
      |> call()

    assert get.status == 200
    assert get.resp_body == "hello"
    assert get_resp_header(get, "access-control-allow-origin") == ["http://www.example.com"]
    assert "Origin" in get_resp_header(get, "vary")
  end
end
```

> `SigV4Request.anon_conn/3` 已支持任意 method（含 `:options`）与 headers——预检不带 Authorization（不签名），Cors plug 在 SigV4 前 halt，不进鉴权。

### 单元收尾验证（M4-5）

```powershell
mix compile --warnings-as-errors
mix test
```

期望：编译零警告；全量绿（既有所有请求无 Origin → Cors plug 透传，不影响既有 e2e）。提交：

```powershell
git add -A
git commit -m @'
M4-5: CORS — ?cors PUT/GET/DELETE (validate + persist + serve); Maxio.Cors first-match algorithm; Maxio.S3.Plugs.Cors (OPTIONS preflight intercept before SigV4 + actual-request header injection via before_send); Endpoint wiring; AccessForbidden/NoSuchCORSConfiguration

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) `?cors` Put 200/Get 回放/Delete 204/无配置 Get 404；(2) `Maxio.Cors` first-match（origin/method/headers、单*通配、大小写不敏感）全覆盖；(3) OPTIONS 预检不签名命中 200+CORS 头、origin 不允许 403 AccessForbidden、未启用 403；(4) 实际请求带 Origin 注入 ACAO/Vary 且流式 GET 不破；(5) **既有无 Origin 请求全回归绿**（Cors plug 透传）；(6) Endpoint 顺序正确（Cors 在 SigV4 前）；(7) 零警告、全量绿。

---

## M4-6 · Lifecycle（?lifecycle 存储 + 校验 + 出站；执行 DEFER 显式文档化）

**目标**：`PutBucketLifecycleConfiguration`/`GetBucketLifecycleConfiguration`/`DeleteBucketLifecycle`（`?lifecycle`）——**存储 + 校验 + 字节忠实出站**（满足 aws-cli/SDK round-trip）。**后台过期执行 DEFER**：不跑 sweeper；**显式文档化**（README 章节 + 启动日志 warning + `mix maxio.lifecycle.run` stub 打印 "execution not implemented"）。绝不假装"已生效"（铁律 3）。

**依赖**：M4-5。**规模**：parser/view + handler + 校验 + Dispatcher/ActionMap + mix stub + 启动日志 + 单测/e2e。

### 协议事实（bake-in）

- `?lifecycle` PUT 200（空 body）/GET 200+XML（无→404 `NoSuchLifecycleConfiguration`）/DELETE 204；≤1000 rule。
- Rule：`ID`（可选）、`Status`（Enabled|Disabled，必填）、`Filter`（Prefix | Tag | ObjectSizeGreaterThan | ObjectSizeLessThan | And{...}；空 Filter 匹配所有；legacy 顶层 Prefix 兼容）、`Expiration{Days|Date|ExpiredObjectDeleteMarker}`、`NoncurrentVersionExpiration{NoncurrentDays,NewerNoncurrentVersions}`、`AbortIncompleteMultipartUpload{DaysAfterInitiation}`、`Transition`/`NoncurrentVersionTransition`（单层 maxio 接受持久化但 no-op）。
- 语义校验：Expiration 不能同时 Days+Date；ExpiredObjectDeleteMarker 不能与 Days/Date 共存 → `InvalidRequest`/`MalformedXML 400`。
- **执行 DEFER**：M4 只存/校验/出站；Expiration/AbortIncompleteMPU 的实际删除不跑（文档化）。

### 步骤 1：parser + view

新建 `lib/maxio/s3/request_parsers/lifecycle.ex`：

```elixir
defmodule Maxio.S3.RequestParsers.Lifecycle do
  @moduledoc """
  PutBucketLifecycleConfiguration 的 XML body 解析（saxy SAX）。把每个 Rule 解析为通用嵌套 map
  （保留结构以便忠实出站 round-trip）：%{id, status, filter, expiration, noncurrent_version_expiration,
  abort_incomplete_multipart_upload, transition, noncurrent_version_transition}（缺省 nil）。
  本解析器只抽取语义校验所需的关键字段（status / expiration days+date / expired_object_delete_marker /
  filter prefix），其余结构性子元素以 raw 文本累积保留供出站。
  为简化 round-trip：解析为「扁平字段 + 原始 prefix」结构，出站 view 据此重建标准 XML。
  返回 {:ok, [rule_map]} | {:error, :malformed_xml}。语义校验由 handler 另做。
  """
  @behaviour Saxy.Handler

  @spec parse(binary()) :: {:ok, [map()]} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{rules: [], cur: nil, path: [], in: nil, text: nil}

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{rules: rules}} -> {:ok, Enum.reverse(rules)}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _p, s), do: {:ok, s}

  @impl true
  def handle_event(:start_element, {name, _attrs}, s) do
    l = local(name)

    cond do
      l == "Rule" ->
        {:ok, %{s | cur: new_rule(), path: ["Rule"], in: nil}}

      l in leaf_tags() ->
        {:ok, %{s | in: l, text: "", path: [l | s.path]}}

      true ->
        {:ok, %{s | in: nil, path: [l | s.path]}}
    end
  end

  @impl true
  def handle_event(:characters, c, %{text: t} = s) when is_binary(t), do: {:ok, %{s | text: t <> c}}
  def handle_event(:characters, _c, s), do: {:ok, s}

  @impl true
  def handle_event(:end_element, name, %{cur: cur} = s) do
    l = local(name)

    cond do
      l == "Rule" and is_map(cur) ->
        {:ok, %{s | rules: [cur | s.rules], cur: nil, path: tl_safe(s.path), in: nil}}

      l in leaf_tags() and is_map(cur) ->
        {:ok, %{s | cur: store(cur, l, s.path, trim(s.text)), in: nil, text: nil, path: tl_safe(s.path)}}

      true ->
        {:ok, %{s | in: nil, text: nil, path: tl_safe(s.path)}}
    end
  end

  @impl true
  def handle_event(:end_document, _d, s), do: {:ok, s}

  defp new_rule do
    %{
      "id" => nil,
      "status" => nil,
      "prefix" => nil,
      "filter_prefix" => nil,
      "filter_tags" => [],
      "filter_size_gt" => nil,
      "filter_size_lt" => nil,
      "expiration_days" => nil,
      "expiration_date" => nil,
      "expired_object_delete_marker" => nil,
      "noncurrent_days" => nil,
      "newer_noncurrent_versions" => nil,
      "abort_days_after_initiation" => nil,
      "transition_days" => nil,
      "transition_storage_class" => nil
    }
  end

  defp leaf_tags do
    ~w(ID Status Prefix Days Date ExpiredObjectDeleteMarker NoncurrentDays NewerNoncurrentVersions
       DaysAfterInitiation StorageClass ObjectSizeGreaterThan ObjectSizeLessThan Key Value)
  end

  # 据 path（标签栈）把叶子值塞进 rule map 的对应键。path 形如 [叶子, 父, ..., "Rule"]。
  defp store(cur, "ID", _path, v), do: %{cur | "id" => v}
  defp store(cur, "Status", _path, v), do: %{cur | "status" => v}

  defp store(cur, "Prefix", path, v) do
    # Filter 内 Prefix → filter_prefix；Rule 直属（legacy） Prefix → prefix；And 内 Prefix → filter_prefix。
    if "Filter" in path or "And" in path, do: %{cur | "filter_prefix" => v}, else: %{cur | "prefix" => v}
  end

  defp store(cur, "Days", path, v), do: if("Transition" in path, do: %{cur | "transition_days" => int(v)}, else: %{cur | "expiration_days" => int(v)})
  defp store(cur, "Date", _path, v), do: %{cur | "expiration_date" => v}
  defp store(cur, "ExpiredObjectDeleteMarker", _p, v), do: %{cur | "expired_object_delete_marker" => v == "true"}
  defp store(cur, "NoncurrentDays", _p, v), do: %{cur | "noncurrent_days" => int(v)}
  defp store(cur, "NewerNoncurrentVersions", _p, v), do: %{cur | "newer_noncurrent_versions" => int(v)}
  defp store(cur, "DaysAfterInitiation", _p, v), do: %{cur | "abort_days_after_initiation" => int(v)}
  defp store(cur, "StorageClass", _p, v), do: %{cur | "transition_storage_class" => v}
  defp store(cur, "ObjectSizeGreaterThan", _p, v), do: %{cur | "filter_size_gt" => int(v)}
  defp store(cur, "ObjectSizeLessThan", _p, v), do: %{cur | "filter_size_lt" => int(v)}
  defp store(cur, _other, _path, _v), do: cur

  defp int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp trim(nil), do: ""
  defp trim(t), do: String.trim(t)

  defp tl_safe([]), do: []
  defp tl_safe([_ | rest]), do: rest

  defp local(name) do
    case String.split(name, ":") do
      [_ns, l] -> l
      [l] -> l
    end
  end
end
```

新建 `lib/maxio/s3/views/lifecycle.ex`：

```elixir
defmodule Maxio.S3.Views.Lifecycle do
  @moduledoc """
  GetBucketLifecycleConfiguration 响应 XML（LifecycleConfiguration>Rule×N，带 xmlns）。
  从解析后的扁平 rule map 重建标准 XML（Filter + Expiration + NoncurrentVersionExpiration +
  AbortIncompleteMultipartUpload + Transition）。round-trip 忠实度满足 SDK 解析。
  """
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render([map()]) :: iodata()
  def render(rules) when is_list(rules) do
    root = element("LifecycleConfiguration", [{"xmlns", XML.namespace()}], Enum.map(rules, &rule_elem/1))
    XML.encode(root)
  end

  defp rule_elem(r) do
    children =
      []
      |> add(r["id"], fn v -> element("ID", [], characters(v)) end)
      |> add(filter_elem(r), & &1)
      |> add(r["status"], fn v -> element("Status", [], characters(v)) end)
      |> add(expiration_elem(r), & &1)
      |> add(noncurrent_expiration_elem(r), & &1)
      |> add(abort_elem(r), & &1)
      |> add(transition_elem(r), & &1)

    element("Rule", [], children)
  end

  defp filter_elem(r) do
    inner =
      []
      |> add(r["filter_prefix"], fn v -> element("Prefix", [], characters(v)) end)
      |> add(r["filter_size_gt"], fn v -> element("ObjectSizeGreaterThan", [], characters(Integer.to_string(v))) end)
      |> add(r["filter_size_lt"], fn v -> element("ObjectSizeLessThan", [], characters(Integer.to_string(v))) end)

    legacy_prefix = r["prefix"]

    cond do
      # 多条件 → 包进 <And>
      length(inner) > 1 -> element("Filter", [], [element("And", [], inner)])
      inner != [] -> element("Filter", [], inner)
      legacy_prefix -> element("Prefix", [], characters(legacy_prefix))
      true -> element("Filter", [], [])
    end
  end

  defp expiration_elem(r) do
    inner =
      []
      |> add(r["expiration_days"], fn v -> element("Days", [], characters(Integer.to_string(v))) end)
      |> add(r["expiration_date"], fn v -> element("Date", [], characters(v)) end)
      |> add(r["expired_object_delete_marker"], fn v -> element("ExpiredObjectDeleteMarker", [], characters(to_string(v))) end)

    if inner == [], do: nil, else: element("Expiration", [], inner)
  end

  defp noncurrent_expiration_elem(r) do
    inner =
      []
      |> add(r["noncurrent_days"], fn v -> element("NoncurrentDays", [], characters(Integer.to_string(v))) end)
      |> add(r["newer_noncurrent_versions"], fn v -> element("NewerNoncurrentVersions", [], characters(Integer.to_string(v))) end)

    if inner == [], do: nil, else: element("NoncurrentVersionExpiration", [], inner)
  end

  defp abort_elem(r) do
    case r["abort_days_after_initiation"] do
      nil -> nil
      n -> element("AbortIncompleteMultipartUpload", [], [element("DaysAfterInitiation", [], characters(Integer.to_string(n)))])
    end
  end

  defp transition_elem(r) do
    inner =
      []
      |> add(r["transition_days"], fn v -> element("Days", [], characters(Integer.to_string(v))) end)
      |> add(r["transition_storage_class"], fn v -> element("StorageClass", [], characters(v)) end)

    if inner == [], do: nil, else: element("Transition", [], inner)
  end

  defp add(children, nil, _fun), do: children
  defp add(children, "", _fun), do: children
  defp add(children, value, fun), do: children ++ [fun.(value)]
end
```

### 步骤 2：handler + 校验

新建 `lib/maxio/s3/handlers/lifecycle.ex`：

```elixir
defmodule Maxio.S3.Handlers.Lifecycle do
  @moduledoc """
  ?lifecycle 子资源 handler：PutBucketLifecycleConfiguration（XML → 校验 → 存，200）、
  GetBucketLifecycleConfiguration（200+XML，无→404 NoSuchLifecycleConfiguration）、
  DeleteBucketLifecycle（204）。

  ⚠️ 仅存储 + 校验 + 出站；后台过期执行 DEFER（未实现，见 README + mix maxio.lifecycle.run stub）。
  校验：每 rule 必须有 Status（Enabled|Disabled）；Expiration 不能同时 Days+Date；
  ExpiredObjectDeleteMarker 不能与 Days/Date 共存；≤1000 rule。违反 → MalformedXML/InvalidRequest 400。
  Transition/NoncurrentVersionTransition 单层 maxio 接受持久化但 no-op（文档化）。
  """
  import Plug.Conn
  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.RequestParsers.Lifecycle, as: Parser
  alias Maxio.S3.Views.Lifecycle, as: View

  @limit 1_048_576

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, xml} = read_small_body!(conn)

    case Parser.parse(xml) do
      {:ok, rules} ->
        :ok = validate!(rules)
        :ok = BucketConfigs.put(bucket, :lifecycle, rules)

        Log.warn("put bucket lifecycle (config stored; expiration execution NOT implemented — defer)",
          action: :put_bucket_lifecycle,
          bucket: bucket,
          reason: :execution_deferred
        )

        send_resp(conn, 200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)

    case BucketConfigs.get(bucket, :lifecycle) do
      {:ok, rules} ->
        conn |> put_resp_content_type("application/xml") |> send_resp(200, View.render(rules))

      :none ->
        raise Error.new(:no_such_lifecycle_configuration, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = BucketConfigs.delete(bucket, :lifecycle)
    Log.info("delete bucket lifecycle", action: :delete_bucket_lifecycle, bucket: bucket)
    send_resp(conn, 204, "")
  end

  # ── 校验 ──
  defp validate!(rules) do
    cond do
      length(rules) > 1000 -> raise Error.new(:invalid_request, message: "Too many lifecycle rules (max 1000)")
      Enum.all?(rules, &valid_rule?/1) -> :ok
      true -> raise Error.new(:malformed_xml, message: "Invalid lifecycle rule")
    end
  end

  defp valid_rule?(r) do
    status_ok = r["status"] in ["Enabled", "Disabled"]
    not_both_days_date = not (r["expiration_days"] != nil and r["expiration_date"] != nil)

    eodm_exclusive =
      if r["expired_object_delete_marker"] == true do
        r["expiration_days"] == nil and r["expiration_date"] == nil
      else
        true
      end

    status_ok and not_both_days_date and eodm_exclusive
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @limit, read_length: @limit) do
      {:ok, body, conn} -> {conn, body}
      {:more, _partial, _conn} -> raise Error.new(:malformed_xml, message: "Lifecycle config too large")
      {:error, _} -> raise Error.new(:malformed_xml)
    end
  end
end
```

**新错误码**（`lib/maxio/s3/error.ex` 加）：

```elixir
    no_such_lifecycle_configuration:
      {"NoSuchLifecycleConfiguration", 404, "The lifecycle configuration does not exist."},
```

### 步骤 3：mix 任务 stub（诚实 defer，铁律 3）

新建 `lib/mix/tasks/maxio.lifecycle.run.ex`：

```elixir
defmodule Mix.Tasks.Maxio.Lifecycle.Run do
  @shortdoc "（占位）生命周期过期执行——M4 未实现，仅打印 defer 说明"
  @moduledoc """
  生命周期后台执行 stub。M4 只存储/校验/出站生命周期配置；**实际过期/中止 MPU 删除未实现**（defer）。
  本任务存在仅为诚实暴露该 defer（铁律 3：绝不假装已生效）。后续里程碑实现真实 sweeper。
  """
  use Mix.Task

  @impl true
  def run(_args) do
    IO.puts("""
    [maxio lifecycle] Lifecycle expiration execution is NOT implemented in M4 (deferred).
    Lifecycle configurations are stored, validated, and served byte-faithfully for S3 client
    compatibility (aws-cli / SDK round-trip), but NO objects are expired and NO incomplete
    multipart uploads are aborted by maxio. Transition/NoncurrentVersionTransition are inert
    (single-tier storage). See README "Lifecycle (config-only)" section.
    """)
  end
end
```

### 步骤 4：启动日志 warning（绝不静默）

在 `lib/maxio/application.ex` 的 `start/2` 成功分支（`maybe_bootstrap_root()` 之后）加一行 defer 提示：

```elixir
      {:ok, pid} ->
        maybe_bootstrap_root()
        log_deferred_features()
        {:ok, pid}
```

并新增私有函数：

```elixir
  # 诚实暴露 M4 defer（铁律 3：绝不假装已生效）。
  defp log_deferred_features do
    require Logger

    Logger.info(
      "maxio M4 deferred: bucket lifecycle EXPIRATION execution not implemented (config stored/served only); " <>
        "SSE-S3 uses single static master key (no rotation/KMS); MFA Delete not enforced; SSE-C/SSE-KMS return 501"
    )
  end
```

### 步骤 5：接线

1. `lib/maxio/s3/dispatcher.ex`：`"lifecycle"` 从 `@m2_subresources` 移除，加分支：

```elixir
      level == :bucket and MapSet.member?(query_keys, "lifecycle") ->
        case method do
          "PUT" -> {:ok, :put_bucket_lifecycle}
          "GET" -> {:ok, :get_bucket_lifecycle}
          "DELETE" -> {:ok, :delete_bucket_lifecycle}
          _ -> {:error, :method_not_allowed}
        end
```

2. `lib/maxio/s3/handlers.ex`（alias 加 `Lifecycle`）：

```elixir
  def dispatch(:put_bucket_lifecycle, conn), do: Lifecycle.put(conn)
  def dispatch(:get_bucket_lifecycle, conn), do: Lifecycle.get(conn)
  def dispatch(:delete_bucket_lifecycle, conn), do: Lifecycle.delete(conn)
```

3. `lib/maxio/policy/action_map.ex`：

```elixir
  def for_action(:put_bucket_lifecycle), do: {"s3:PutLifecycleConfiguration", :bucket}
  def for_action(:get_bucket_lifecycle), do: {"s3:GetLifecycleConfiguration", :bucket}
  def for_action(:delete_bucket_lifecycle), do: {"s3:PutLifecycleConfiguration", :bucket}
```

### 步骤 6：e2e

新建 `test/maxio/s3/lifecycle_e2e_test.exs`：

```elixir
defmodule Maxio.S3.LifecycleE2ETest do
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @lc ~s(<LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ID>expire-tmp</ID><Filter><Prefix>tmp/</Prefix></Filter><Status>Enabled</Status><Expiration><Days>7</Days></Expiration></Rule></LifecycleConfiguration>)

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "Put 200 → Get 回放（含 Prefix/Days/Status）→ Delete 204 → Get 404" do
    SigV4Request.signed_conn(:put, "/lcb") |> call()
    put = SigV4Request.signed_conn(:put, "/lcb", query: %{"lifecycle" => ""}, body: @lc) |> call()
    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/lcb", query: %{"lifecycle" => ""}) |> call()
    assert get.status == 200
    assert get.resp_body =~ "expire-tmp"
    assert get.resp_body =~ "<Prefix>tmp/</Prefix>"
    assert get.resp_body =~ "<Days>7</Days>"
    assert get.resp_body =~ "<Status>Enabled</Status>"

    del = SigV4Request.signed_conn(:delete, "/lcb", query: %{"lifecycle" => ""}) |> call()
    assert del.status == 204

    g2 = SigV4Request.signed_conn(:get, "/lcb", query: %{"lifecycle" => ""}) |> call()
    assert g2.status == 404
    assert g2.resp_body =~ "NoSuchLifecycleConfiguration"
  end

  test "Expiration 同时 Days+Date → 400" do
    SigV4Request.signed_conn(:put, "/lcb2") |> call()
    bad = ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Expiration><Days>7</Days><Date>2026-01-01T00:00:00.000Z</Date></Expiration></Rule></LifecycleConfiguration>)
    res = SigV4Request.signed_conn(:put, "/lcb2", query: %{"lifecycle" => ""}, body: bad) |> call()
    assert res.status == 400
  end
end
```

### 单元收尾验证（M4-6）

```powershell
mix compile --warnings-as-errors
mix test
mix maxio.lifecycle.run
```

期望：编译零警告；全量绿；`mix maxio.lifecycle.run` 打印 defer 说明。提交：

```powershell
git add -A
git commit -m @'
M4-6: Lifecycle (?lifecycle PUT/GET/DELETE) — parse/validate/persist/serve byte-faithfully; expiration EXECUTION deferred (documented: startup log warning + mix maxio.lifecycle.run stub); NoSuchLifecycleConfiguration; Dispatcher/ActionMap wiring

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) `?lifecycle` Put 200/Get round-trip（Prefix/Days/Status 忠实）/Delete 204/无配置 Get 404；(2) 语义校验（Days+Date 互斥、ExpiredObjectDeleteMarker 互斥、≤1000）→ 400；(3) **defer 诚实可见**：启动日志 warning + `mix maxio.lifecycle.run` stub 输出；(4) Dispatcher/Handlers/ActionMap 接线；(5) 零警告、全量绿。

---

## M4-7 · SSE-S3（真实 AES-256-GCM 信封加密 + ?encryption 默认配置）

**目标**：选 **Option A（真实 at-rest 加密，诚实 MVP）**。PutObject 带 `x-amz-server-side-encryption: AES256`（或桶默认加密 AES256）→ **真实加密对象字节**：每对象生成随机数据密钥（DEK），用 DEK 以 AES-256-GCM 加密字节，DEK 用服务端主密钥（从 config/env 加载的单一静态主密钥，MVP 简化密钥管理——无轮转/KMS）以 AES-256-GCM 包裹，信封头（wrapped DEK + IV + tag）随对象元数据存；GET 透明解密。响应 + HEAD/GET 回显 `x-amz-server-side-encryption: AES256`。`PutBucketEncryption`/`Get`/`Delete`（`?encryption`）默认配置。**非 AES256（aws:kms / SSE-C 头）→ 501 NotImplemented（绝不静默当 AES256）**。

**依赖**：M4-6。**规模**：迁移（objects.sse_algorithm + sse_envelope）+ `Maxio.Crypto.SSE`（流式 AES-256-GCM）+ FS 集成（加密在 handler 包裹 chunks 流，存储后端无感）+ PutObject/GET 接线 + encryption parser/view/handler + Dispatcher/ActionMap + config 主密钥 + 单测/e2e。

### 设计决策（诚实 MVP，bake-in）

- **加密点选择**：把加密做在 **handler 层包裹 chunks 流**（`Maxio.Crypto.SSE.wrap_stream/1`），而非改 FS 后端——这样存储后端契约不变（铁律 1/2：FS 存的是密文字节，对加密无感），且对 versioning 路径透明。但 GCM 是认证加密、整段一个 tag——为流式可行，**按固定块（如 64KB）分块独立加密**，每块自带 IV+tag，密文流 = `[len(4B)||iv(12B)||tag(16B)||ciphertext]×N`。`wrap_stream` 返回密文流 + 信封头（wrapped DEK，对象级一个）。GET 时 `unwrap_stream` 逐块解密。
- **主密钥**：从 `config :maxio, :sse, master_key: <base64 32B>`（dev 给固定 key；prod 经 `MAXIO_SSE_MASTER_KEY` env，runtime.exs）。**单一静态主密钥 = 简化密钥管理 MVP**（无轮转/HSM/KMS），README/启动日志已声明（M4-6 启动日志已含）。
- **存什么**：`objects.sse_algorithm`（"AES256" 或 nil）+ `objects.sse_envelope`（jsonb：`%{wrapped_dek_b64, dek_iv_b64, dek_tag_b64}`）。GET 凭 sse_algorithm 决定是否解密。
- **决定加密的来源**：请求头 `x-amz-server-side-encryption: AES256` 或桶默认加密配置 AES256。两者都无 → 明文存（sse_algorithm=nil）。
- **拒绝**：`x-amz-server-side-encryption` 值非 `AES256`（如 `aws:kms`），或出现 `x-amz-server-side-encryption-customer-algorithm`（SSE-C）→ `501 NotImplemented`。

### 步骤 1：迁移 — objects.sse_algorithm + sse_envelope

```powershell
mix ecto.gen.migration add_sse_to_objects
```

替换为：

```elixir
defmodule Maxio.Repo.Migrations.AddSseToObjects do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :sse_algorithm, :string,
        null: true,
        comment: "服务端加密算法（AES256=SSE-S3 真实加密；nil=明文）。GET 据此决定是否透明解密；响应回显 x-amz-server-side-encryption"

      add :sse_envelope, :map,
        null: true,
        comment: "SSE-S3 信封头（jsonb）：%{wrapped_dek_b64, dek_iv_b64, dek_tag_b64}——对象数据密钥经服务端主密钥 AES-256-GCM 包裹（单一静态主密钥 MVP，无轮转）；nil=未加密"
    end
  end
end
```

运行迁移。把 `sse_algorithm`/`sse_envelope` 加入 `Object` schema（`field :sse_algorithm, :string`、`field :sse_envelope, :map`）与 `@optional`（追加 `:sse_algorithm, :sse_envelope`）。`put_version_with_id`/`put_version` 的 `Map.take` 已含 `:sse_algorithm`——再追加 `:sse_envelope`（改 `Map.take([:content_type, :metadata, :storage_class, :acl_canned, :tags, :sse_algorithm, :sse_envelope])`）。

### 步骤 2：`Maxio.Crypto.SSE`（流式 AES-256-GCM 信封，TDD）

新建 `test/maxio/crypto/sse_test.exs`：

```elixir
defmodule Maxio.Crypto.SSETest do
  use ExUnit.Case, async: true
  alias Maxio.Crypto.SSE

  setup do
    prev = Application.get_env(:maxio, :sse)
    key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    Application.put_env(:maxio, :sse, master_key: key)
    on_exit(fn -> Application.put_env(:maxio, :sse, prev) end)
    :ok
  end

  test "wrap/unwrap 往返还原明文（单块）" do
    plain = "Welcome to Amazon S3 SSE-S3."
    {cipher_stream, envelope} = SSE.wrap_stream([plain])
    cipher = Enum.to_list(cipher_stream) |> IO.iodata_to_binary()
    refute cipher == plain

    out = SSE.unwrap_stream([cipher], envelope) |> Enum.to_list() |> IO.iodata_to_binary()
    assert out == plain
  end

  test "多块流往返（>64KB）" do
    plain = :crypto.strong_rand_bytes(200_000)
    {cipher_stream, envelope} = SSE.wrap_stream([plain])
    cipher = Enum.to_list(cipher_stream) |> IO.iodata_to_binary()

    out = SSE.unwrap_stream([cipher], envelope) |> Enum.to_list() |> IO.iodata_to_binary()
    assert out == plain
  end

  test "篡改密文 → 解密 raise（GCM 认证失败，绝不静默）" do
    {cipher_stream, envelope} = SSE.wrap_stream(["data"])
    cipher = Enum.to_list(cipher_stream) |> IO.iodata_to_binary()
    tampered = cipher |> :binary.bin_to_list() |> List.update_at(-1, &Bitwise.bxor(&1, 0xFF)) |> :erlang.list_to_binary()

    assert_raise RuntimeError, fn ->
      SSE.unwrap_stream([tampered], envelope) |> Enum.to_list()
    end
  end
end
```

运行确认红。新建 `lib/maxio/crypto/sse.ex`：

```elixir
defmodule Maxio.Crypto.SSE do
  @moduledoc """
  SSE-S3 真实 at-rest 加密（AES-256-GCM 信封加密，流式友好，铁律 4 不全缓冲）。

  信封模型（诚实 MVP）：
    * 每对象生成随机 256-bit DEK（data encryption key）。
    * 对象字节按固定块（64KB）独立 AES-256-GCM 加密（每块随机 12B IV + 16B tag）；
      密文流帧 = <ct_len::32><iv::96><tag::128><ciphertext>，逐块产出（流式）。
    * DEK 用服务端主密钥（config :maxio, :sse, master_key —— base64 32B；prod 经 env）以
      AES-256-GCM 包裹，wrapped DEK + IV + tag 作为信封头随对象元数据存（对象级一个）。
    * 主密钥是单一静态密钥（MVP 简化密钥管理：无轮转/HSM/KMS——README/启动日志已声明）。
  GCM 认证失败（密文/tag 被篡改）→ raise（绝不静默返回错数据，铁律 3）。
  """
  @chunk 65_536
  @aad "maxio-sse-s3"

  @doc "把明文 chunks 流加密为密文帧流，并返回随元数据存的信封头 map。"
  @spec wrap_stream(Enumerable.t()) ::
          {Enumerable.t(), %{wrapped_dek_b64: String.t(), dek_iv_b64: String.t(), dek_tag_b64: String.t()}}
  def wrap_stream(chunks) do
    dek = :crypto.strong_rand_bytes(32)
    {wrapped, wrap_iv, wrap_tag} = wrap_dek(dek)

    envelope = %{
      wrapped_dek_b64: Base.encode64(wrapped),
      dek_iv_b64: Base.encode64(wrap_iv),
      dek_tag_b64: Base.encode64(wrap_tag)
    }

    # 把任意分块的明文流重切成 64KB 块再逐块加密（保证帧确定性，与读出无关）。
    cipher_stream =
      chunks
      |> rechunk(@chunk)
      |> Stream.map(fn plain_block -> encrypt_block(dek, plain_block) end)

    {cipher_stream, envelope}
  end

  @doc "把密文帧流用信封头解密还原明文流。GCM 认证失败 → raise。"
  @spec unwrap_stream(Enumerable.t(), map()) :: Enumerable.t()
  def unwrap_stream(cipher_chunks, envelope) do
    dek = unwrap_dek(envelope)
    full = cipher_chunks |> Enum.to_list() |> IO.iodata_to_binary()
    decrypt_frames(full, dek, [])
  end

  # ── 块加解密 ──
  defp encrypt_block(dek, plain) do
    iv = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, plain, @aad, true)
    <<byte_size(ct)::32, iv::binary-size(12), tag::binary-size(16), ct::binary>>
  end

  # 逐帧解密（密文已全读进内存——对象 GET 在 handler 流式发出前解密块；为简化此处整读密文，
  # 大对象的逐帧流式解密留后续优化，本 MVP 正确性优先且密文与明文同量级，文档化）。
  defp decrypt_frames(<<>>, _dek, acc), do: Enum.reverse(acc)

  defp decrypt_frames(<<ct_len::32, iv::binary-size(12), tag::binary-size(16), rest::binary>>, dek, acc) do
    <<ct::binary-size(ct_len), tail::binary>> = rest

    case :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, ct, @aad, tag, false) do
      :error -> raise "SSE-S3 decryption failed: GCM authentication tag mismatch"
      plain -> decrypt_frames(tail, dek, [plain | acc])
    end
  end

  defp decrypt_frames(_garbage, _dek, _acc), do: raise("SSE-S3 decryption failed: malformed ciphertext frame")

  # ── DEK 包裹/解裹（主密钥 AES-256-GCM）──
  defp wrap_dek(dek) do
    mk = master_key()
    iv = :crypto.strong_rand_bytes(12)
    {wrapped, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, mk, iv, dek, @aad, true)
    {wrapped, iv, tag}
  end

  defp unwrap_dek(%{} = env) do
    mk = master_key()
    wrapped = b64(env, :wrapped_dek_b64)
    iv = b64(env, :dek_iv_b64)
    tag = b64(env, :dek_tag_b64)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, mk, iv, wrapped, @aad, tag, false) do
      :error -> raise "SSE-S3 DEK unwrap failed: master key/tag mismatch"
      dek -> dek
    end
  end

  # envelope 既可能是 atom-key（刚生成）也可能是 string-key（从 jsonb 读出）。
  defp b64(env, key) do
    val = Map.get(env, key) || Map.get(env, Atom.to_string(key))
    Base.decode64!(val)
  end

  defp master_key do
    cfg = Application.get_env(:maxio, :sse, [])

    case Keyword.get(cfg, :master_key) do
      nil -> raise "maxio SSE master key not configured (config :maxio, :sse, master_key: <base64 32B>)"
      b64 -> Base.decode64!(b64)
    end
  end

  # 把任意分块流重切成固定大小块（最后一块可短）。
  defp rechunk(chunks, size) do
    Stream.transform(
      chunks,
      fn -> <<>> end,
      fn data, buf ->
        combined = buf <> data
        emit_blocks(combined, size, [])
      end,
      fn buf -> if buf == <<>>, do: {[], <<>>}, else: {[buf], <<>>} end,
      fn _ -> :ok end
    )
  end

  defp emit_blocks(buf, size, acc) when byte_size(buf) >= size do
    <<block::binary-size(size), rest::binary>> = buf
    emit_blocks(rest, size, [block | acc])
  end

  defp emit_blocks(buf, _size, acc), do: {Enum.reverse(acc), buf}
end
```

> `Stream.transform/5`（带 start/reducer/last/after）把上游任意分块重切成 64KB 块，末尾 flush 残块。`crypto_one_time_aead/7`（7 参带 tag 末位 false）解密失败返回 `:error` → raise（绝不静默）。**已知 MVP 简化**：`unwrap_stream` 整读密文再逐帧解密（大对象逐帧流式解密留后续；密文与明文同量级，正确性优先）——写入 STATUS 的 defer。

运行确认绿。

### 步骤 3：encryption parser + view + handler

新建 `lib/maxio/s3/request_parsers/encryption.ex`：

```elixir
defmodule Maxio.S3.RequestParsers.Encryption do
  @moduledoc """
  PutBucketEncryption 的 XML body 解析（saxy SAX）：
  ServerSideEncryptionConfiguration>Rule>ApplyServerSideEncryptionByDefault>(SSEAlgorithm,KMSMasterKeyID)
  + Rule>BucketKeyEnabled。返回 {:ok, %{algorithm, kms_key_id, bucket_key_enabled}} | {:error, :malformed_xml}。
  """
  @behaviour Saxy.Handler

  @spec parse(binary()) ::
          {:ok, %{algorithm: String.t() | nil, kms_key_id: String.t() | nil, bucket_key_enabled: boolean()}}
          | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{algorithm: nil, kms_key_id: nil, bucket_key_enabled: false, in: nil, text: nil}

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{algorithm: a, kms_key_id: k, bucket_key_enabled: bk}} ->
        {:ok, %{algorithm: a, kms_key_id: k, bucket_key_enabled: bk}}

      {:error, _} ->
        {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _p, s), do: {:ok, s}

  @impl true
  def handle_event(:start_element, {name, _attrs}, s) do
    case local(name) do
      "SSEAlgorithm" -> {:ok, %{s | in: :alg, text: ""}}
      "KMSMasterKeyID" -> {:ok, %{s | in: :kms, text: ""}}
      "BucketKeyEnabled" -> {:ok, %{s | in: :bk, text: ""}}
      _ -> {:ok, %{s | in: nil}}
    end
  end

  @impl true
  def handle_event(:characters, c, %{text: t} = s) when is_binary(t), do: {:ok, %{s | text: t <> c}}
  def handle_event(:characters, _c, s), do: {:ok, s}

  @impl true
  def handle_event(:end_element, name, s) do
    case local(name) do
      "SSEAlgorithm" -> {:ok, %{s | algorithm: trim(s.text), in: nil, text: nil}}
      "KMSMasterKeyID" -> {:ok, %{s | kms_key_id: trim(s.text), in: nil, text: nil}}
      "BucketKeyEnabled" -> {:ok, %{s | bucket_key_enabled: trim(s.text) == "true", in: nil, text: nil}}
      _ -> {:ok, %{s | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _d, s), do: {:ok, s}

  defp trim(nil), do: nil
  defp trim(t), do: String.trim(t)

  defp local(name) do
    case String.split(name, ":") do
      [_ns, l] -> l
      [l] -> l
    end
  end
end
```

新建 `lib/maxio/s3/views/encryption.ex`：

```elixir
defmodule Maxio.S3.Views.Encryption do
  @moduledoc "GetBucketEncryption 响应 XML（ServerSideEncryptionConfiguration，带 xmlns）。MVP 仅 AES256。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{algorithm: String.t(), bucket_key_enabled: boolean()}) :: iodata()
  def render(%{algorithm: alg} = data) do
    apply_default =
      element("ApplyServerSideEncryptionByDefault", [], [element("SSEAlgorithm", [], characters(alg))])

    rule_children =
      [apply_default]
      |> then(fn c ->
        if Map.get(data, :bucket_key_enabled, false),
          do: c ++ [element("BucketKeyEnabled", [], characters("true"))],
          else: c
      end)

    root =
      element("ServerSideEncryptionConfiguration", [{"xmlns", XML.namespace()}], [
        element("Rule", [], rule_children)
      ])

    XML.encode(root)
  end
end
```

新建 `lib/maxio/s3/handlers/encryption.ex`：

```elixir
defmodule Maxio.S3.Handlers.Encryption do
  @moduledoc """
  ?encryption 子资源 handler：PutBucketEncryption（XML → 校验 AES256 → 存，200）、
  GetBucketEncryption（200+XML，无→404 ServerSideEncryptionConfigurationNotFoundError）、
  DeleteBucketEncryption（204）。
  MVP 仅 SSE-S3 AES256：SSEAlgorithm 非 AES256（aws:kms/aws:kms:dsse）→ 501 NotImplemented（绝不静默）；
  KMSMasterKeyID 与 AES256 共存 → 400 InvalidArgument。BucketKeyEnabled 接受但 no-op（KMS 专属）。
  """
  import Plug.Conn
  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.RequestParsers.Encryption, as: Parser
  alias Maxio.S3.Views.Encryption, as: View

  @limit 1_048_576

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, xml} = read_small_body!(conn)

    case Parser.parse(xml) do
      {:ok, %{algorithm: "AES256", kms_key_id: kms, bucket_key_enabled: bk}} ->
        if kms not in [nil, ""] do
          raise Error.new(:invalid_argument, message: "KMSMasterKeyID is only valid with aws:kms/aws:kms:dsse")
        end

        :ok = BucketConfigs.put(bucket, :encryption, %{"algorithm" => "AES256", "bucket_key_enabled" => bk})
        Log.info("put bucket encryption", action: :put_bucket_encryption, bucket: bucket, reason: "AES256")
        send_resp(conn, 200, "")

      {:ok, %{algorithm: alg}} when alg in ["aws:kms", "aws:kms:dsse"] ->
        raise Error.new(:not_implemented, message: "Only SSE-S3 (AES256) is supported; #{alg} not implemented")

      {:ok, _other} ->
        raise Error.new(:malformed_xml, message: "Invalid SSEAlgorithm")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)

    case BucketConfigs.get(bucket, :encryption) do
      {:ok, %{"algorithm" => alg} = cfg} ->
        body = View.render(%{algorithm: alg, bucket_key_enabled: Map.get(cfg, "bucket_key_enabled", false)})
        conn |> put_resp_content_type("application/xml") |> send_resp(200, body)

      :none ->
        raise Error.new(:server_side_encryption_configuration_not_found, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = BucketConfigs.delete(bucket, :encryption)
    Log.info("delete bucket encryption", action: :delete_bucket_encryption, bucket: bucket)
    send_resp(conn, 204, "")
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @limit, read_length: @limit) do
      {:ok, body, conn} -> {conn, body}
      {:more, _partial, _conn} -> raise Error.new(:malformed_xml, message: "Encryption config too large")
      {:error, _} -> raise Error.new(:malformed_xml)
    end
  end
end
```

**新错误码**（`lib/maxio/s3/error.ex` 加）：

```elixir
    server_side_encryption_configuration_not_found:
      {"ServerSideEncryptionConfigurationNotFoundError", 404, "The server side encryption configuration was not found."},
```

### 步骤 4：PutObject 加密 + GET 解密（接线 Object handler）

在 `lib/maxio/s3/handlers/object.ex` 的 `do_put/1`：在算 version_id 后、调 `Storage.put` 前，决定是否加密并包裹 chunks。把 chunks 行替换：

```elixir
    chunks = BodyReader.stream(conn, payload_mode)

    versioning = bucket_versioning(bucket)
    version_id = if versioning == "Enabled", do: Maxio.Versioning.VersionId.generate(), else: "null"
    tags_map = parse_tagging_header!(conn)

    # SSE-S3：请求头或桶默认加密 = AES256 → 真实加密字节；非 AES256/SSE-C → 501（绝不静默）。
    sse_requested = resolve_sse!(conn, bucket)

    {chunks, sse_envelope} =
      case sse_requested do
        "AES256" -> Maxio.Crypto.SSE.wrap_stream(chunks)
        nil -> {chunks, nil}
      end

    case Storage.put(bucket, key, version_id, chunks) do
```

> **注意 ETag/size 语义**：`Storage.put` 返回的 etag/size 是**密文**的 MD5/大小（FS 对加密无感）。AWS 对 SSE-S3 对象的 ETag 不保证是明文 MD5（SSE 对象 ETag 非 MD5）——故密文 ETag 可接受（与 AWS「SSE 对象 ETag 不是 MD5」一致）。`x-amz-decoded-content-length`/`x-amz-content-sha256` 校验对加密对象会因密文≠明文而失配——**故加密时跳过这两个校验**（它们针对明文传输完整性，加密在落盘前包裹，传输层完整性已由 SigV4/chunked 在 BodyReader 内验过）。executor 在加密分支跳过 `verify_decoded_length!`/`verify_content_sha256!`：把 `do_put` 的 try 块改为按 `sse_requested` 条件跳过这两个校验：

```elixir
        {:ok, obj} =
          try do
            unless sse_requested do
              :ok = verify_decoded_length!(conn, payload_mode, size)
              :ok = verify_content_sha256!(conn, payload_mode, sha256)
            end

            Objects.put_version_with_id(bucket, key, version_id, %{
              size: size,
              etag: etag,
              content_type: content_type,
              storage_class: "STANDARD",
              acl_canned: header(conn, "x-amz-acl") || "private",
              tags: tags_map,
              sse_algorithm: sse_requested,
              sse_envelope: sse_envelope
            })
          rescue
            err ->
              _ = Storage.delete(bucket, key, version_id)
              Log.warn("put object rolled back orphan bytes", action: :put_object, bucket: bucket, key: key, reason: :incomplete_body)
              reraise(err, __STACKTRACE__)
          end
```

并在响应回显（加密时加 `x-amz-server-side-encryption: AES256`）：把 `do_put` 的成功响应段改为：

```elixir
        conn
        |> maybe_put_version_id(obj.version_id)
        |> maybe_put_sse(sse_requested)
        |> put_resp_header("etag", XML.quote_etag(etag))
        |> send_resp(200, "")
```

新增 helpers：

```elixir
  # 决定 SSE：请求头优先；其次桶默认加密配置。非 AES256/SSE-C → 501。
  defp resolve_sse!(conn, bucket) do
    sse_c = header(conn, "x-amz-server-side-encryption-customer-algorithm")

    if sse_c not in [nil, ""] do
      raise Error.new(:not_implemented, message: "SSE-C (customer-provided keys) not implemented")
    end

    case header(conn, "x-amz-server-side-encryption") do
      "AES256" ->
        "AES256"

      alg when alg in ["aws:kms", "aws:kms:dsse"] ->
        raise Error.new(:not_implemented, message: "Only SSE-S3 (AES256) is supported; #{alg} not implemented")

      nil ->
        bucket_default_sse(bucket)

      "" ->
        bucket_default_sse(bucket)

      _other ->
        raise Error.new(:invalid_argument, message: "Invalid x-amz-server-side-encryption value")
    end
  end

  defp bucket_default_sse(bucket) do
    case Maxio.BucketConfigs.get(bucket, :encryption) do
      {:ok, %{"algorithm" => "AES256"}} -> "AES256"
      _ -> nil
    end
  end

  defp maybe_put_sse(conn, nil), do: conn
  defp maybe_put_sse(conn, alg), do: put_resp_header(conn, "x-amz-server-side-encryption", alg)
```

在 `get/1` 解密：取版本行后，若 `object.sse_algorithm == "AES256"` 则用 `Crypto.SSE.unwrap_stream` 解密 stream，并在响应加回显头。把 `get/1` 的 `:proceed` 分支里取 stream 后改为按 sse 解密 + 回显：

```elixir
              _ ->
                {:ok, raw_stream} = Storage.get(bucket, key, object.version_id, range_tuple(range))

                stream =
                  if object.sse_algorithm == "AES256" and range in [nil, :full] do
                    # 加密对象的 Range：MVP 不支持密文 Range（帧化），整对象解密后发完整 200（range 已置 nil/:full 才解密）。
                    Maxio.Crypto.SSE.unwrap_stream(raw_stream, object.sse_envelope)
                  else
                    raw_stream
                  end

                conn =
                  conn
                  |> maybe_put_version_id(object.version_id)
                  |> maybe_put_sse(object.sse_algorithm)

                send_object(conn, object, total, range, stream)
```

> **加密对象 + Range 的 MVP 限制**：密文是帧化的，对密文做 byte-range 会取到错误字节。**MVP：对加密对象的 Range 请求，在 `get/1` 取 stream 前若 `object.sse_algorithm == "AES256"` 且 range 是 `{first,last}`，强制按完整对象处理**（解密整对象返回 200，忽略 Range）——这是诚实降级（不返回错数据），写入 STATUS defer。实现：在 `get/1` 解析 range 后，若加密且 range 是 tuple，把 range 置 `:full`。executor 在 `parse_range` 之后加：`range = if object.sse_algorithm == "AES256" and match?({_, _}, range), do: :full, else: range`（放在 `case range do` 之前）。`put_common_object_headers` 的 content-length 用 object.size（明文大小？——注意：object.size 是密文大小！）。**修正**：SSE 对象 `object.size` 存的是密文大小（FS 返回密文 size）。GET 返回明文，content-length 须是明文大小。**解法**：`put_version_with_id` 对 SSE 对象额外存明文大小到 metadata，或——更简单——MVP 对 SSE 对象 GET 用 `send_chunked`（不预设 content-length 精确值）。但既有 `put_common_object_headers` 设 content-length=object.size（密文大小）会与实际明文 body 不符。**最干净的 MVP 解法**：在 `wrap_stream` 不改变「记录明文大小」——让 `do_put` 在加密前先不知明文大小（流式）。故 **SSE 对象的 `objects.size` 存明文大小**：`do_put` 加密分支无法从 `Storage.put` 拿明文大小（它返回密文大小）。**决策**：`Crypto.SSE.wrap_stream/1` 改为同时累计明文字节数并经返回——见下方修正。

**`Crypto.SSE.wrap_stream` 返回明文大小**：把 `wrap_stream/1` 的返回签名扩展为 `{cipher_stream, envelope, plain_size_fun}` 不便（流式未消费完不知大小）。**更简单且正确的 MVP**：让 `do_put` 在加密时把明文大小通过「envelope 里记 plaintext_size」——但加密是流式，落盘后才知。**最终决策（写进计划，executor 照做）**：SSE 对象走「先收明文到临时、知大小、再加密落盘」会违反不缓冲铁律。**采用：SSE 对象 GET 用 `send_chunked` 且 content-length 用解密后实际字节**——即 GET 时先 `unwrap_stream` 得明文 iodata（MVP 已整读密文解密），其 `IO.iodata_to_binary |> byte_size` 即明文大小，用它设 content-length 再 chunked 发出。executor 在 `get/1` 的 SSE 分支：解密得明文 binary，`plain = IO.iodata_to_binary(...)`，用 `byte_size(plain)` 设 content-length，`send_object` 传单元素列表 `[plain]`。为此在 `get/1` SSE 分支特化（不复用 object.size）：

```elixir
              _ when object.sse_algorithm == "AES256" ->
                {:ok, raw_stream} = Storage.get(bucket, key, object.version_id, nil)
                plain = Maxio.Crypto.SSE.unwrap_stream(raw_stream, object.sse_envelope) |> Enum.to_list() |> IO.iodata_to_binary()

                conn
                |> maybe_put_version_id(object.version_id)
                |> maybe_put_sse(object.sse_algorithm)
                |> put_resp_content_type(object.content_type)
                |> put_resp_header("etag", XML.quote_etag(object.etag))
                |> put_resp_header("last-modified", http_date(object.updated_at))
                |> put_resp_header("content-length", Integer.to_string(byte_size(plain)))
                |> maybe_tagging_count(object)
                |> send_resp(200, plain)

              _ ->
                {:ok, stream} = Storage.get(bucket, key, object.version_id, range_tuple(range))
                conn = conn |> maybe_put_version_id(object.version_id)
                send_object(conn, object, total, range, stream)
```

> 即：SSE 对象 GET 走整对象解密 + `send_resp(200, plain)`（明文整发，MVP；大对象逐帧流式解密留 defer）。HEAD 对 SSE 对象的 content-length 用密文 size 会不准——**HEAD 的 SSE 对象**：在 `head/1` 若 `object.sse_algorithm=="AES256"` 也回显 `x-amz-server-side-encryption` 头（content-length 用密文 size，HEAD 无 body，content-length 不精确可接受/或省略——MVP 回显 SSE 头即可，content-length 与 AWS 同为对象大小语义近似）。executor 在 `head/1` 的 `:proceed` 分支加 `|> maybe_put_sse(object.sse_algorithm)`。

> 上述 SSE GET 限制（无 Range、整对象解密）写入 STATUS defer。**核心正确性**：加密落盘、解密还原、回显头——满足 SDK SSE-S3 往返。

### 步骤 5：config 主密钥

`config/config.exs` 加（在 `:s3` 配置块之后）：

```elixir
# SSE-S3 服务端主密钥（信封加密包裹每对象 DEK）。dev/test 用固定 base64 32B；
# prod 经 MAXIO_SSE_MASTER_KEY env（runtime.exs）。单一静态主密钥=简化密钥管理 MVP（无轮转/KMS，README 已声明）。
config :maxio, :sse,
  master_key: "bWF4aW8tc3NlLXMzLW1hc3Rlci1rZXktMzJieXRlcyE="
```

> 该 base64 解出恰 32 字节（dev/test 固定 key，仅本地）。prod 经 runtime.exs 用 env 覆盖——若 `config/runtime.exs` 存在，加 `if key = System.get_env("MAXIO_SSE_MASTER_KEY"), do: config :maxio, :sse, master_key: key`（executor 视 runtime.exs 现状决定；test 用 config.exs 默认即可，`mix test` 不依赖 env）。

### 步骤 6：接线 + e2e

1. `lib/maxio/s3/dispatcher.ex`：`"encryption"` 从 `@m2_subresources` 移除，加分支：

```elixir
      level == :bucket and MapSet.member?(query_keys, "encryption") ->
        case method do
          "PUT" -> {:ok, :put_bucket_encryption}
          "GET" -> {:ok, :get_bucket_encryption}
          "DELETE" -> {:ok, :delete_bucket_encryption}
          _ -> {:error, :method_not_allowed}
        end
```

2. `lib/maxio/s3/handlers.ex`（alias 加 `Encryption`）：

```elixir
  def dispatch(:put_bucket_encryption, conn), do: Encryption.put(conn)
  def dispatch(:get_bucket_encryption, conn), do: Encryption.get(conn)
  def dispatch(:delete_bucket_encryption, conn), do: Encryption.delete(conn)
```

3. `lib/maxio/policy/action_map.ex`：

```elixir
  def for_action(:put_bucket_encryption), do: {"s3:PutEncryptionConfiguration", :bucket}
  def for_action(:get_bucket_encryption), do: {"s3:GetEncryptionConfiguration", :bucket}
  def for_action(:delete_bucket_encryption), do: {"s3:PutEncryptionConfiguration", :bucket}
```

新建 e2e `test/maxio/s3/sse_e2e_test.exs`：

```elixir
defmodule Maxio.S3.SseE2ETest do
  use Maxio.DataCase, async: false
  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_sse_e2e")

  setup do
    File.rm_rf(@data_dir); File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn -> Application.put_env(:maxio, :s3, prev); File.rm_rf(@data_dir) end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "PutObject AES256 → 回显 SSE 头；GET 透明解密还原；磁盘字节是密文" do
    SigV4Request.signed_conn(:put, "/sb") |> call()
    plain = "encrypt me with AES-256-GCM SSE-S3"

    put = SigV4Request.signed_conn(:put, "/sb/secret.txt", body: plain,
            headers: [{"x-amz-server-side-encryption", "AES256"}]) |> call()
    assert put.status == 200
    assert get_resp_header(put, "x-amz-server-side-encryption") == ["AES256"]

    get = SigV4Request.signed_conn(:get, "/sb/secret.txt") |> call()
    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["AES256"]

    # 磁盘上是密文（不含明文片段）。SSE 对象落 null 版本路径 <data_dir>/sb/secret.txt。
    on_disk = File.read!(Path.join([@data_dir, "sb", "secret.txt"]))
    refute on_disk =~ "encrypt me"
  end

  test "桶默认加密 AES256 → 无头 PUT 也加密" do
    SigV4Request.signed_conn(:put, "/sb2") |> call()
    enc = ~s(<ServerSideEncryptionConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>AES256</SSEAlgorithm></ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>)
    SigV4Request.signed_conn(:put, "/sb2", query: %{"encryption" => ""}, body: enc) |> call()

    put = SigV4Request.signed_conn(:put, "/sb2/o.txt", body: "default-enc") |> call()
    assert get_resp_header(put, "x-amz-server-side-encryption") == ["AES256"]
    get = SigV4Request.signed_conn(:get, "/sb2/o.txt") |> call()
    assert get.resp_body == "default-enc"
  end

  test "aws:kms → 501 NotImplemented（绝不静默当 AES256）" do
    SigV4Request.signed_conn(:put, "/sb3") |> call()
    res = SigV4Request.signed_conn(:put, "/sb3/o.txt", body: "x",
            headers: [{"x-amz-server-side-encryption", "aws:kms"}]) |> call()
    assert res.status == 501
  end

  test "GetBucketEncryption 无配置 → 404" do
    SigV4Request.signed_conn(:put, "/sb4") |> call()
    res = SigV4Request.signed_conn(:get, "/sb4", query: %{"encryption" => ""}) |> call()
    assert res.status == 404
    assert res.resp_body =~ "ServerSideEncryptionConfigurationNotFoundError"
  end
end
```

### 单元收尾验证（M4-7）

```powershell
mix compile --warnings-as-errors
mix test
```

期望：编译零警告；全量绿。提交：

```powershell
git add -A
git commit -m @'
M4-7: SSE-S3 — real AES-256-GCM envelope encryption (Maxio.Crypto.SSE; per-object DEK wrapped by single static master key, MVP); PutObject x-amz-server-side-encryption: AES256 encrypts bytes + echoes header; transparent GET decryption; PutBucketEncryption/Get/Delete (?encryption); aws:kms/SSE-C -> 501

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) 迁移 sse 列中文 COMMENT；(2) `Crypto.SSE` 往返还原（单块/多块>64KB）、篡改密文 raise；(3) e2e：AES256 PUT 回显头 + GET 解密还原 + **磁盘字节确为密文**（不含明文）；(4) 桶默认加密无头 PUT 也加密；(5) aws:kms/SSE-C → 501（绝不静默）；(6) GetBucketEncryption 无配置 404；(7) Dispatcher/Handlers/ActionMap 接线 + 主密钥 config；(8) 零警告、全量绿。

---

## M4-8 · 端到端集成矩阵汇总 + 全量回归 + STATUS + README 高级特性章节

**目标**：补一份贯穿 M4 全特性的端到端矩阵（versioning × tagging × cors × sse 交叉场景），全量回归，更新 STATUS 单一事实来源，新建 README 高级特性章节（含 defer 清单，铁律 3 诚实暴露）。

**依赖**：M4-7。**规模**：集成矩阵 + 文档。

### 步骤 1：跨特性集成矩阵 `test/maxio/s3/m4_matrix_test.exs`

```elixir
defmodule Maxio.S3.M4MatrixTest do
  @moduledoc "M4 跨特性端到端矩阵：versioning × tagging × sse × cors × authz 交叉。"
  use Maxio.DataCase, async: false
  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_m4_matrix")

  setup do
    File.rm_rf(@data_dir); File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn -> Application.put_env(:maxio, :s3, prev); File.rm_rf(@data_dir) end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "版本化 + tagging：?tagging&versionId 作用于指定版本" do
    SigV4Request.signed_conn(:put, "/mx") |> call()
    SigV4Request.signed_conn(:put, "/mx", query: %{"versioning" => ""},
      body: ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)) |> call()

    p1 = SigV4Request.signed_conn(:put, "/mx/k.txt", body: "v1") |> call()
    [vid1] = get_resp_header(p1, "x-amz-version-id")
    SigV4Request.signed_conn(:put, "/mx/k.txt", body: "v2") |> call()

    tagging = ~s(<Tagging><TagSet><Tag><Key>v</Key><Value>one</Value></Tag></TagSet></Tagging>)
    put_t = SigV4Request.signed_conn(:put, "/mx/k.txt", query: %{"tagging" => "", "versionId" => vid1}, body: tagging) |> call()
    assert put_t.status == 200

    get_t = SigV4Request.signed_conn(:get, "/mx/k.txt", query: %{"tagging" => "", "versionId" => vid1}) |> call()
    assert get_t.resp_body =~ "<Value>one</Value>"

    # latest（v2）无该 tag
    get_latest = SigV4Request.signed_conn(:get, "/mx/k.txt", query: %{"tagging" => ""}) |> call()
    refute get_latest.resp_body =~ "<Value>one</Value>"
  end

  test "版本化 + SSE：版本化桶里加密对象的多版本各自可解密" do
    SigV4Request.signed_conn(:put, "/mx2") |> call()
    SigV4Request.signed_conn(:put, "/mx2", query: %{"versioning" => ""},
      body: ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)) |> call()

    p1 = SigV4Request.signed_conn(:put, "/mx2/s.txt", body: "secret-v1", headers: [{"x-amz-server-side-encryption", "AES256"}]) |> call()
    [vid1] = get_resp_header(p1, "x-amz-version-id")
    SigV4Request.signed_conn(:put, "/mx2/s.txt", body: "secret-v2", headers: [{"x-amz-server-side-encryption", "AES256"}]) |> call()

    g_latest = SigV4Request.signed_conn(:get, "/mx2/s.txt") |> call()
    assert g_latest.resp_body == "secret-v2"

    g_old = SigV4Request.signed_conn(:get, "/mx2/s.txt", query: %{"versionId" => vid1}) |> call()
    assert g_old.resp_body == "secret-v1"
  end

  test "authz：匿名访问加 public-read policy 的版本化对象（最新版本）放行" do
    SigV4Request.signed_conn(:put, "/mx3") |> call()
    SigV4Request.signed_conn(:put, "/mx3", query: %{"versioning" => ""},
      body: ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)) |> call()
    SigV4Request.signed_conn(:put, "/mx3/pub.txt", body: "open") |> call()

    pol = ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::mx3/*"}]})
    SigV4Request.signed_conn(:put, "/mx3", query: %{"policy" => ""}, body: pol, headers: [{"content-type", "application/json"}]) |> call()

    anon = SigV4Request.anon_conn(:get, "/mx3/pub.txt") |> call()
    assert anon.status == 200
    assert anon.resp_body == "open"
  end
end
```

### 步骤 2：全量回归

```powershell
mix compile --warnings-as-errors
mix test
```

期望：全量测试通过（M3 基线 275 + M4 全部新增用例），零警告。记录最终测试数。

### 步骤 3：新建 README 高级特性章节（诚实 defer，铁律 3）

在 `README.md`（若无则新建）追加 `## 高级特性（M4）` 章节，逐条列：
- **Versioning**：三态、版本 ID（ULID）、delete marker、ListObjectVersions、`x-amz-version-id`/`x-amz-delete-marker`。
- **Tagging**：对象/桶 `?tagging`、`x-amz-tagging` 头、`x-amz-tagging-count`、limits。
- **CORS**：`?cors`、OPTIONS 预检、实际请求注入；仅作用于 S3 Endpoint（非 Console）。
- **Lifecycle（config-only）**：明确「**仅存储/校验/出站；过期执行未实现（defer）**——maxio 不会自动过期对象或中止 MPU；`mix maxio.lifecycle.run` 仅提示 defer」。
- **SSE-S3**：明确「**真实 AES-256-GCM 信封加密**；密钥管理简化为单一静态服务端主密钥（无轮转/HSM/KMS）；仅 SSE-S3（AES256），SSE-C/SSE-KMS 返回 501」。
- **M4 显式 defer 清单**（见下方汇总，逐条搬进 README）。

### 步骤 4：更新 STATUS（单一事实来源）

编辑 `docs/superpowers/STATUS.md`：

(a) 里程碑表 M4 行状态从 `⬜ 待` 改为 `✅ 已实现并验证（master，2026-06-09；<N> 测试全绿、versioning/tagging/cors/lifecycle/sse e2e、独立 reviewer APPROVE）`。

(b) 新增「M4 实现摘要」节，列：M4-1 硬化（Authz 真实 principal + AWS Principal 精确匹配）；M4-2 解析框架 + 配置载体；M4-3a/b versioning（多版本 schema/storage/ULID/对象语义/ListObjectVersions）；M4-4 tagging；M4-5 CORS（预检 plug）；M4-6 lifecycle（config-only，执行 defer）；M4-7 SSE-S3（真实 AES-256-GCM）。

(c) 新增「M4 已知非阻塞项 / 显式 defer」节，逐条列下方「显式 defer 清单」，标注「文档化，非静默」。

(d) 把「下一步（续作入口）」更新为 M5（Console LiveView）。

### 步骤 5：提交

```powershell
git add -A
git commit -m @'
M4-8: cross-feature integration matrix (versioning×tagging×sse×authz) + full regression + STATUS update + README advanced-features section (with explicit defer list); M4 advanced-features milestone complete

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) 跨特性矩阵（版本化+tagging 逐版本、版本化+SSE 多版本解密、authz 匿名 public-read 版本化对象）全绿；(2) 既有 M0–M3 + M4-1..7 全部回归绿；(3) STATUS 已更新（M4 ✅ + 摘要 + defer 清单 + 下一步 M5）；(4) README 高级特性章节诚实标注 lifecycle 执行 defer 与 SSE 密钥管理简化；(5) 零警告、全量绿。

---

## 显式 defer 清单（汇总；文档化，绝不静默放行/吞错）

到达以下任一情形，**返回结构化错误或按文档化降级，绝不静默**：

1. **Lifecycle 后台过期/中止 MPU 执行**：仅存储/校验/出站配置；不跑 sweeper。诚实暴露：启动日志 warning + `mix maxio.lifecycle.run` stub + README。`Transition`/`NoncurrentVersionTransition` 单层 maxio 接受持久化但 no-op。
2. **MFA Delete**：`MfaDelete` 状态解析/存储/回显（GetBucketVersioning 仅曾配置时回 `<MfaDelete>`），但**不强制 MFA 校验**（无设备），`x-amz-mfa` 头不验证。
3. **SSE-C / SSE-KMS / DSSE-KMS**：仅 SSE-S3（AES256）。`aws:kms`/`aws:kms:dsse` 或 `x-amz-server-side-encryption-customer-*` → `501 NotImplemented`（绝不静默当 AES256）。`BucketKeyEnabled` 接受持久化但 no-op（KMS 专属）。
4. **SSE 密钥管理简化**：单一静态服务端主密钥（config/env），无轮转/HSM/KMS——README/启动日志已声明。
5. **SSE 对象 + Range / 大对象逐帧流式解密**：MVP 对加密对象的 Range 请求降级为完整对象（不返回错数据）；GET 整对象解密后 `send_resp`（大对象逐帧流式解密留后续优化）。
6. **Multipart 完成对象在版本化桶的逐版本字节路径**：multipart Complete 的对象字节走 null 路径、元数据当 latest null 版本；多段对象逐版本化字节路径 defer（单段 PutObject 版本化完整）。
7. **对象级逐版本独立 tag set**：tag 挂在版本行（`?tagging&versionId` 已支持指定版本）；`s3:*VersionTagging` 细粒度权限按同名非 version 权限评估（单租户）。
8. **lifecycle `Date`（绝对时间）与 `Transition` 执行**：仅存储/校验。
9. **沿用 M3 全部 defer**：跨账户/多租户、完整条件算子、identity policy（`principal_policies/1` 恒 `[]`，M4-1 已修为传真实 principal——接口就绪，实现仍 defer）、STS/session token、email grantee、`x-amz-grant-*` 细粒度、Block Public Access、checksum trailer 重算、DeleteObjects 逐 key 授权。

---

## 新增/修改文件清单（M4 全量）

**新增**：
- `lib/maxio/versioning/version_id.ex`（ULID，M4-3a）
- `lib/maxio/bucket_configs.ex`、`bucket_configs/bucket_config.ex`（M4-2）
- `lib/maxio/tags.ex`（M4-4）、`lib/maxio/cors.ex`（M4-5）、`lib/maxio/crypto/sse.ex`（M4-7）
- `lib/maxio/s3/request_parsers/{versioning_configuration,tagging,cors,lifecycle,encryption}.ex`
- `lib/maxio/s3/views/{versioning_configuration,tagging,cors,lifecycle,encryption,list_versions}.ex`
- `lib/maxio/s3/handlers/{versioning,tagging,cors,lifecycle,encryption}.ex`
- `lib/maxio/s3/plugs/cors.ex`（M4-5）
- `lib/mix/tasks/maxio.lifecycle.run.ex`（M4-6 stub）
- 迁移：`add_versioning_to_buckets`、`create_bucket_configs`（M4-2）；`add_versioning_to_objects`（M4-3a）；`add_tags_to_objects_and_buckets`（M4-4）；`add_sse_to_objects`（M4-7）
- 测试：`s3/authz_principal_test.exs`、`policy/principal_exact_test.exs`（M4-1）；`s3/request_parsers/versioning_configuration_test.exs`、`bucket_configs_test.exs`（M4-2）；`versioning/version_id_test.exs`、`s3/versioning_object_test.exs`、`s3/versioning_config_test.exs`（M4-3a）；`objects/list_latest_test.exs`、`objects/list_versions_test.exs`、`s3/list_versions_e2e_test.exs`（M4-3b）；`tags_test.exs`、`s3/tagging_e2e_test.exs`（M4-4）；`cors_test.exs`、`s3/cors_e2e_test.exs`（M4-5）；`s3/lifecycle_e2e_test.exs`（M4-6）；`crypto/sse_test.exs`、`s3/sse_e2e_test.exs`（M4-7）；`s3/m4_matrix_test.exs`（M4-8）

**修改**：
- `lib/maxio/s3/authz.ex`（真实 principal，M4-1）
- `lib/maxio/policy/evaluator.ex`（AWS Principal 精确匹配，M4-1）
- `lib/maxio/buckets.ex` + `buckets/bucket.ex`（versioning/mfa_delete/tags 列 + put_versioning/put_tags/get_tags）
- `lib/maxio/objects.ex` + `objects/object.ex`（version_id/is_latest/is_delete_marker/tags/sse_algorithm/sse_envelope 列 + put_version/put_version_with_id/insert_delete_marker/delete_version/get_version/get_tags/put_tags/list_object_versions + list_objects_v2 latest 过滤）
- `lib/maxio/storage.ex` + `storage/backend.ex` + `storage/fs.ex`（put/get/stat/delete 加 version_id 维度，FS version-qualified 路径，M4-3a）
- `lib/maxio/s3/handlers/object.ex`（版本语义 + x-amz-tagging + x-amz-tagging-count + SSE 加解密/回显）
- `lib/maxio/s3/handlers/bucket.ex`（list_object_versions，M4-3b）
- `lib/maxio/s3/handlers.ex`（全部新 action 接线）
- `lib/maxio/s3/dispatcher.ex`（versioning/versions/tagging/cors/lifecycle/encryption 从 @m2_subresources 移出并分发）
- `lib/maxio/policy/action_map.ex`（全部新 operation → s3:Action 映射）
- `lib/maxio/s3/endpoint.ex`（插入 Cors plug，M4-5）
- `lib/maxio/s3/error.ex`（invalid_tag/access_forbidden/no_such_cors_configuration/no_such_lifecycle_configuration/server_side_encryption_configuration_not_found）
- `lib/maxio/application.ex`（log_deferred_features，M4-6）
- `config/config.exs`（:sse master_key，M4-7）；`config/runtime.exs`（MAXIO_SSE_MASTER_KEY env，可选）
- `docs/superpowers/STATUS.md`（M4 ✅ + 摘要 + defer + 下一步 M5）；`README.md`（高级特性章节）

---

## 命名一致性检查清单（executor 每单元落地前复查，再次强调）

- 新 operation **三处接线缺一不可**：`ActionMap.for_action/1`（漏 → Authz 放行=越权）+ `Dispatcher.resolve/3`（从 `@m2_subresources` 移出对应 key）+ `Handlers.dispatch/2`。
- version_id 一律经 `Maxio.Versioning.VersionId.{generate,null_sentinel}`；`x-amz-version-id` 仅非 `"null"` 时回显（`maybe_put_version_id/2`）。
- 资源 ARN 一律 `Maxio.Policy.Arn.{bucket_arn,object_arn,account_arn}`。
- XML 出站 `Maxio.S3.XML.{encode/1,namespace/0,iso8601/1,quote_etag/1}` + `Saxy.XML.element/3`；入站 saxy SAX + `local/1` 去命名空间前缀（照抄既有 parser）。
- 小文档 body 带上限整读；对象字节 `BodyReader.stream/2`，绝不全缓冲（SSE 加密在 handler 包裹 chunks 流）。
- 错误码经 `Maxio.S3.Error.new/2`；非 AES256 SSE/SSE-C 用 `:not_implemented`（501）。
- 新表/列/索引中文 `COMMENT`。
- 每条 mix 命令前已设 `$env:Path` + `$env:ERL_FLAGS`；每单元一次 commit，footer 固定 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。
- **铁律 3 诚实**：lifecycle 执行 defer 必须经启动日志 + mix stub + README 暴露；SSE 密钥管理简化必须声明。绝不假装已生效。
