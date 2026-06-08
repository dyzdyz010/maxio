# maxio — S3 兼容对象存储 · 总体设计 spec（合并索引）

> 单一设计索引。本文件整合两份子系统设计输入，给出系统总体架构、模块边界、里程碑分解与跨子系统契约。
> 子系统详细设计（由架构 subagent 产出）：
> - **S3 API / HTTP 层与路由**：[`_design_inputs/s3_api_layer.md`](_design_inputs/s3_api_layer.md)
> - **鉴权（SigV4）与 IAM/策略**：[`_design_inputs/auth_iam.md`](_design_inputs/auth_iam.md)
>
> 工程准则：`AGENTS.md`（先读）；Claude/OMC 执行细节：`CLAUDE.md`。当前状态：`STATUS.md`。

## 1. 目标与边界

**目标**：用 Elixir/Phoenix 完整复刻 MinIO 的全功能、Amazon S3 兼容对象存储。对外暴露 S3 REST API（aws-cli / boto3 / mc / SDK 直连），对内做鉴权/授权/对象管理/可插拔存储，并提供 MinIO Console 式 LiveView 管理台。

**第一阶段（M0–M1）边界**：打通一条 **aws-cli 可真实访问的 S3 垂直切片**——独立 S3 Endpoint（端口 9000）+ SigV4 鉴权 + 判定表分发 + 桶/对象 CRUD + ListObjectsV2 + 单机 FS 存储后端 + XML 渲染 + 错误映射 + CLI 取证。分段上传、aws-chunked 流式签名、IAM 策略、versioning、Console、纠删码留后续里程碑。

## 2. 总体架构（请求生命周期）

```
S3 客户端 (aws-cli/boto3/mc/SDK)
   │  HTTP/HTTPS, SigV4 签名, XML
   ▼
Maxio.S3.Endpoint  (独立 Bandit endpoint, 端口 9000, 不挂 Plug.Parsers)
   │
   ├─ Plug.RequestId / Plug.Telemetry
   ├─ Maxio.S3.Plugs.AddressStyle   寻址解析 → conn.assigns {s3_bucket, s3_key, s3_level}
   ├─ Maxio.S3.Plugs.Auth (SigV4)   认证 → conn.assigns {principal, auth_type, payload_mode}
   └─ Maxio.S3.Plugs.Dispatch       Dispatcher.resolve(level, method, query) → action
        │                            → 对应 Handler；统一 try/rescue Maxio.S3.Error → ErrorView
        ▼
   Handlers (Service/Bucket/Object)  解析参数 → (授权 AuthzPlug/inline) → 调编排/上下文
        │
        ├─ Maxio.Buckets / Maxio.Objects   元数据上下文 (Ecto + Postgres)
        └─ Maxio.Storage.Backend (behaviour) → Maxio.Storage.FS   对象字节 (流式 read/write)
        ▼
   XML 出站 (saxy) / 二进制流 (send_chunked) / 错误 XML
```

Console（M5）走**另一条独立管线**（现有 `MaxioWeb.Endpoint`，端口 4000，session/CSRF/LiveView），与 S3 管线物理隔离。

## 3. 核心契约与 behaviour（跨子系统单一真相源）

- **`Maxio.S3.Request` / `Maxio.S3.Response`**：handler 只认内部契约，与 Plug.Conn 解耦（铁律 1）。
- **`Maxio.Storage.Backend`**（behaviour）：`put(bucket, key, stream, meta)` / `get(bucket, key, range)` / `stat` / `delete` / `list`。MVP 实现 `Maxio.Storage.FS`（单机文件系统，流式）；后续 `ErasureCoded` / `Distributed`（铁律 2）。
- **`Maxio.Auth.CredentialStore`**（behaviour）：`get_secret(access_key)` / `put_access_key` / `list_keys`。MVP `MemoryStore`（root 从 env 引导）；后续 `EctoStore`。详见 auth_iam.md。
- **`Maxio.Policy.Store`**（behaviour）：`bucket_policy` / `principal_policies`。策略评估器为纯函数（默认拒绝、显式 deny 优先）。详见 auth_iam.md。
- **`Maxio.S3.Error`**（defexception）：`code/message/http_status/resource/request_id`；统一错误码→HTTP 状态映射表 + 错误 XML 渲染（绝不静默 500，铁律 3）。

## 4. 里程碑分解

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M0 地基** | 存储后端 behaviour + FS 实现；bucket/object 元数据 schema（中文 COMMENT）+ 上下文；s3 config（端口/domain/root 凭据/数据目录）；结构化日志基座 | 见 STATUS |
| **M1 S3 核心读写** | 独立 S3 Endpoint；AddressStyle plug；SigV4（header + UNSIGNED-PAYLOAD + presigned）+ MemoryStore；Dispatcher 判定表；Handlers：ListBuckets/CreateBucket/DeleteBucket/HeadBucket/ListObjectsV2 + PutObject/GetObject(Range)/HeadObject/DeleteObject；XML 渲染 + 错误映射；`mix maxio.sigv4.debug` CLI；aws-cli e2e | 见 STATUS |
| **M2 分段上传 + 流式** | CreateMultipartUpload/UploadPart/Complete/Abort/ListParts；`aws-chunked`(STREAMING-AWS4-HMAC-SHA256) body reader + chunk 签名状态机；Range 多区间；条件头（If-Match 等）；DeleteObjects 批量 | 待 |
| **M3 IAM / 策略** | access key 全生命周期 + EctoStore；IAM policy + bucket policy 评估；canned ACL；presigned 完整；Authz plug | 待 |
| **M4 高级特性** | versioning；object/bucket tagging；lifecycle；CORS；CopyObject；encryption（SSE） | 待 |
| **M5 Console** | LiveView 管理台（桶/对象浏览、用户/策略管理、监控仪表） | 待 |
| **M6 纠删码 / 分布式** | Reed-Solomon 纠删码存储后端（Rustler NIF）；多节点分布式模式；自愈 | 待 |

## 5. 头号风险（来自子系统设计，须早验）

1. **aws-chunked 流式签名**（最大）：aws-cli 默认对上传用 `STREAMING-AWS4-HMAC-SHA256`，wire 上 body 是 chunk-signature 包裹的分块格式，须 `ChunkedBodyReader` 边读边解帧+校验再输出纯净字节。M1 若用 header 单块签名 + UNSIGNED-PAYLOAD 可先打通；完整 aws-cli 上传兼容在 M2。**M1 验证策略**：用 `aws s3api put-object` 配合可控签名，或自签 ExUnit 集成测试覆盖 header 签名路径；记录 aws-chunked 为 M2 入口。
2. **URI/query 编码 + S3 路径不归一化**：签名不匹配头号根因，须用 AWS SDK 测试向量回归（VERIFY-AT-IMPL）。
3. **body 误进内存**：任何无意挂 `Plug.Parsers` 或 Auth plug `read_body` 后不下传都会破坏流式（铁律 4）。
4. **XML 兼容细节**：命名空间、日期格式、空列表元素省略与否，SDK 敏感。
5. **时序侧信道**：签名比对须常数时间（`Plug.Crypto.secure_compare`）。

## 6. 与现有脚手架的关系

现有 `MaxioWeb.Endpoint`/`Router`（端口 4000，LiveView/Dashboard）**保持不变**，专供 Console。S3 管线是**新增的独立 Endpoint**（端口 9000），在 `Maxio.Application` 监督树新增。`config/config.exs`/`runtime.exs` 增 `Maxio.S3.Endpoint` 配置与 `s3_domain`、root 凭据、数据目录。`mix.exs` 增 `:saxy`。详见 s3_api_layer.md「落地改造点」。

## 7. 来源

子系统设计文档各自附 AWS 官方文档来源；实现期对每个 `VERIFY-AT-IMPL` 标记须对照官方 S3 API Reference 与 AWS SDK 测试向量核验。
