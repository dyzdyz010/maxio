I have the protocol details confirmed. Here is the complete design.

---

# maxio 鉴权(SigV4)与 IAM/策略子系统设计

## 概述

本子系统是 maxio 请求管线的第一道安检关卡，负责回答两个正交问题：**你是谁**（Authentication，SigV4 签名验证 → principal）与**你能做什么**（Authorization，IAM + bucket policy 评估 → allow/deny）。它对外暴露为两个 Plug（`SigV4Plug`、`AuthzPlug`）夹在 Bandit/Phoenix 管线中，对内由 `Maxio.Auth`、`Maxio.IAM`、`Maxio.Policy` 三个边界 context 支撑。设计遵循工程铁律：签名验证逻辑与凭据存储/策略后端均通过 behaviour 抽象解耦（铁律 1），凭据后端可从内存 stub 平滑替换为 Postgres/Ecto；多步签名（流式分块）以显式状态机驱动，签名失败立即返回结构化 S3 错误而非静默放行（铁律 3）；所有验证路径产出带元数据的结构化日志，并提供 Mix 任务做离线签名复算取证（铁律 4）。

MVP 边界先划清：**强制实现** header-based SigV4（单块 + UNSIGNED-PAYLOAD）、presigned URL 验证、root 凭据 + access key 存储、IAM policy + bucket policy 评估（默认拒绝/显式 deny 优先）、canned ACL 映射。**stub/降级**：STREAMING 分块签名（实现分块解帧 + 状态机骨架，但 MVP 可先只验 seed 签名 + 透传校验开关）、trailing-header chunked、Resource 中的条件键(Condition block，如 `aws:SourceIp`)、IAM 用户组/角色继承（MVP 只做 user-level inline policy）。

## 关键设计决策

**决策 1：SigV4 验证作为 Plug 而非散落在 controller。**
选择：在 Phoenix endpoint 中 `plug Maxio.Web.Plugs.SigV4`，挂载于路由分发之前、bucket/object controller 之前。理由：S3 所有路径都需鉴权，集中入口避免遗漏；Plug 把验证结果(`principal`, `auth_type`)写入 `conn.assigns`，下游 controller 与 AuthzPlug 直接消费。备选：在每个 controller 内调用——被否，违反铁律 2（散补丁）且易漏路径。

**决策 2：签名验证不消费 body，payload hash 校验延迟到流读取阶段。**
选择：`SigV4Plug` 只验证 header/canonical-request 层面的签名（此时 `x-amz-content-sha256` 是声明值，不重算 body）；真实 body 哈希校验交给 body reader（单块：边读边 SHA256，读完比对；UNSIGNED-PAYLOAD：跳过；STREAMING：逐块状态机）。理由：Bandit 流式 body 不能在 Plug 阶段全量缓冲（大对象会爆内存），必须流式。这要求 canonical request 用客户端**声明**的 content-sha256，body 实际哈希在落盘管线中验证——与 AWS 行为一致。备选：Plug 内 `read_body` 全缓冲——否，违反流式与内存约束。

**决策 3：凭据存储与策略存储均为 behaviour。**
选择：`Maxio.Auth.CredentialStore` 与 `Maxio.Policy.Store` 两个 behaviour。MVP 提供 `MemoryStore`（root 凭据从环境变量 `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` 等价的 `MAXIO_ROOT_USER`/`MAXIO_ROOT_PASSWORD` 引导，access key 存 ETS），后续提供 `EctoStore`。理由：铁律 1，换后端不改验证逻辑。

**决策 4：策略评估器为纯函数 + 不可变决策结构。**
选择：`Maxio.Policy.Evaluator.evaluate(request_context, policies) :: :allow | {:deny, reason}`，无副作用、可单测、可在 IEx 直接复算。默认拒绝；遍历所有 statement，任一显式 `Deny` 命中即终局拒绝（最高优先级），否则需至少一条 `Allow` 命中，再否则隐式拒绝。理由：契合铁律 3/4，决策可追溯。

**决策 5：时钟偏移容忍 ±15 分钟（可配置）。**
选择：解析 `x-amz-date`，与服务器 UTC 比较，绝对差 > `clock_skew_ms`（默认 900_000）即 `RequestTimeTooSkewed`。presigned URL 另校验 `X-Amz-Expires`(0..604800)。理由：与 AWS/MinIO 默认一致。

## SigV4 Canonical Request 精确步骤 (VERIFY-AT-IMPL)

以下步骤经官方文档核验确认（`sigv4-create-canonical-request`、`sig-v4-header-based-auth`），但**实现时必须逐字段对照官方文档与 AWS SDK 测试向量回归**（尤其 URI 编码与 trim 规则的边界）：

1. **CanonicalRequest** = 以 `\n` 连接的 6 段：
   `HTTPMethod` ⏎ `CanonicalURI` ⏎ `CanonicalQueryString` ⏎ `CanonicalHeaders` ⏎ `SignedHeaders` ⏎ `HashedPayload`
2. **CanonicalURI**：path 段做 URI 编码（**S3 服务特例：路径不做二次编码**，即对象 key 中的 `/` 保留、其他字符 RFC3986 编码，编码字母大写 `%2F`）。`VERIFY-AT-IMPL`：S3 的 `do not normalize path` 与「单次编码」规则。
3. **CanonicalQueryString**：参数名/值各自 URI 编码后，按**编码后的参数名**字典序排序，`key=value` 以 `&` 连接；空值参数写 `key=`。`VERIFY-AT-IMPL`：排序基准是编码后字符串。
4. **CanonicalHeaders**：每条 = `lowercase(name) + ":" + trimall(value) + "\n"`；按 header 名小写后字典序排序。`trimall` = 去首尾空白 + 内部连续空白折叠为单空格（引号内不折叠）。**必须**包含 `host` 与至少一个 `x-amz-*`（通常 `x-amz-date`、`x-amz-content-sha256`）。
5. **SignedHeaders**：参与签名的 header 名小写后字典序、**分号** `;` 连接（如 `host;x-amz-content-sha256;x-amz-date`）。
6. **HashedPayload**：取请求声明的 `x-amz-content-sha256`（值可能是 hex(SHA256(body))、`UNSIGNED-PAYLOAD`、或 `STREAMING-AWS4-HMAC-SHA256-PAYLOAD`），**原样**作为第 6 段。
7. **StringToSign** = `AWS4-HMAC-SHA256` ⏎ `<amz-date ISO8601 basic>` ⏎ `<scope>` ⏎ `hex(SHA256(CanonicalRequest))`，其中 `scope = yyyymmdd/region/service/aws4_request`（service 恒为 `s3`）。
8. **Signing key 推导（HMAC-SHA256 链）**：
   `kDate = HMAC("AWS4"+secret, yyyymmdd)` → `kRegion = HMAC(kDate, region)` → `kService = HMAC(kRegion, "s3")` → `kSigning = HMAC(kService, "aws4_request")`。
9. **Signature** = `hex(HMAC(kSigning, StringToSign))`，与 Authorization header 中 `Signature=` 字段**常数时间比对**（`:crypto.hash_equals`/手写定长比较，防时序侧信道）。

**Presigned URL 差异 (VERIFY-AT-IMPL)**：签名/credential/date/expires/signed-headers 来自 query 参数 `X-Amz-Algorithm`、`X-Amz-Credential`、`X-Amz-Date`、`X-Amz-Expires`、`X-Amz-SignedHeaders`、`X-Amz-Signature`；HashedPayload 固定用 `UNSIGNED-PAYLOAD`；构造 CanonicalQueryString 时**排除** `X-Amz-Signature` 自身，其余照常编码排序。校验过期：`now > X-Amz-Date + X-Amz-Expires` → `AccessDenied`（Request has expired）。

**STREAMING 分块签名 (VERIFY-AT-IMPL)**：seed 签名与普通 header 签名同算（HashedPayload = `STREAMING-AWS4-HMAC-SHA256-PAYLOAD`）。随后每块 chunk 的 string-to-sign = `AWS4-HMAC-SHA256-PAYLOAD` ⏎ `<amz-date>` ⏎ `<scope>` ⏎ `<上一块签名(首块为 seed 签名)>` ⏎ `hex(SHA256(""))` ⏎ `hex(SHA256(chunk-data))`（**末段无换行**）。块格式：`<hex chunk size>;chunk-signature=<sig>\r\n<data>\r\n`，size=0 为终止块。`UNSIGNED-PAYLOAD` 流式变体跳过逐块签名。务必对照官方 `sigv4-streaming` 与 trailer 文档核验空串哈希常量与终止块语义。

## Elixir 模块清单

- **`Maxio.Web.Plugs.SigV4`** — 入口 Plug。职责：分流 header-auth / presigned / anonymous；提取签名材料；调用 `Maxio.Auth` 验证；成功写 `conn.assigns[:principal]`、`[:auth_type]`、`[:signed_payload_mode]`，失败 `halt` 并渲染 S3 错误 XML。关键函数：`call/2`、`detect_auth_type/1`、`put_principal/2`、`reject/3`。
- **`Maxio.Web.Plugs.Authz`** — 授权 Plug，位于 controller 解析出 `{action, bucket, key}` 之后。职责：组装 `RequestContext`，调用策略引擎，deny 即 halt。关键函数：`call/2`、`build_context/2`、`authorize/2`。
- **`Maxio.Auth`** — 鉴权边界 context。`authenticate(parsed_auth, conn_meta) :: {:ok, principal} | {:error, s3_error}`、`verify_signature/2`、`check_clock_skew/2`。
- **`Maxio.Auth.SigV4.Canonical`** — 纯函数。`canonical_request/1`、`canonical_uri/1`、`canonical_query/1`、`canonical_headers/2`、`trimall/1`、`hashed_payload/1`。
- **`Maxio.Auth.SigV4.Signer`** — `string_to_sign/3`、`derive_signing_key/4`（HMAC 链）、`signature/2`、`secure_compare/2`。
- **`Maxio.Auth.SigV4.AuthHeaderParser`** — 解析 `Authorization: AWS4-HMAC-SHA256 Credential=.../scope, SignedHeaders=..., Signature=...` 与 presigned query 形态，产出统一 `%SignedRequest{}`。
- **`Maxio.Auth.SigV4.StreamingVerifier`** — 分块状态机（见下）。`init_seed/1`、`verify_chunk/2`、`next_state/2`。
- **`Maxio.Auth.CredentialStore`** (behaviour) + `MemoryStore`、`EctoStore`。回调见下。
- **`Maxio.IAM`** — 凭据/用户管理 context。`bootstrap_root/0`（从 env 引导 root）、`create_access_key/2`、`lookup_secret/1`、`principal_for_access_key/1`。
- **`Maxio.Policy`** — 策略 context。`Maxio.Policy.Store` (behaviour)、`Maxio.Policy.Statement`、`Maxio.Policy.Evaluator`、`Maxio.Policy.ACL`（canned ACL → 等价 statement 映射）、`Maxio.Policy.Arn`（解析/匹配 `arn:aws:s3:::bucket/key` 通配）。
- **`Maxio.Auth.Errors`** — S3 错误码到 HTTP 状态 + XML body 映射（`SignatureDoesNotMatch` 403, `AccessDenied` 403, `RequestTimeTooSkewed` 403, `InvalidAccessKeyId` 403, `AuthorizationHeaderMalformed` 400, `MissingSecurityHeader` 400）。
- **`Mix.Tasks.Maxio.Sigv4.Debug`** — CLI 取证：给定 method/uri/headers/secret，打印各中间产物（canonical request、string-to-sign、每级 HMAC、最终签名），定位「签名不匹配」（铁律 4）。

## behaviour 回调与数据结构

```elixir
defmodule Maxio.Auth.CredentialStore do
  @callback get_secret(access_key :: String.t()) ::
              {:ok, %{secret_key: String.t(), principal: map()}} | :error
  @callback put_access_key(map()) :: :ok | {:error, term()}
  @callback list_keys() :: [map()]
end

defmodule Maxio.Policy.Store do
  @callback bucket_policy(bucket :: String.t()) :: {:ok, [Statement.t()]} | :none
  @callback principal_policies(principal :: map()) :: [Statement.t()]
end
```

```elixir
# 授权评估输入
%Maxio.Policy.RequestContext{
  principal: %{type: :root | :iam_user, access_key: String.t(), arn: String.t()},
  action: "s3:GetObject",                  # 由 controller 按 S3 操作映射
  resource_arn: "arn:aws:s3:::mybucket/path/to/key",
  bucket: "mybucket", key: "path/to/key",
  conditions: %{source_ip: ..., secure_transport: ...}  # MVP 多数 stub
}

%Maxio.Policy.Statement{
  sid: String.t() | nil, effect: :allow | :deny,
  actions: [String.t()], resources: [String.t()],  # 支持 * 与 ?
  principals: term(), conditions: map()
}
```

**评估算法**：`root` principal 短路放行（等价 MinIO root 全权）；否则汇总 principal_policies ++ bucket_policy，先扫 deny（命中即 `{:deny, :explicit_deny}`），再扫 allow（命中 `:allow`），均不中则 `{:deny, :implicit_deny}`。action/resource 用 glob（`*`→`.*`, `?`→`.`）正则匹配。

**Canned ACL 映射**：`private`→无额外 allow（仅 owner=root/创建者）；`public-read`→注入 `{allow, ["s3:GetObject"], [bucket/*], principal *}`；`public-read-write`→加 `s3:PutObject`；`authenticated-read`→Principal 限已认证。ACL 存为 bucket/object 元数据，评估时翻译成等价 statement 合入。

## 流式签名状态机

`StreamingVerifier` 状态：`:awaiting_seed`（已验 header seed 签名）→ `:verifying_chunk`（持 `prev_signature`，逐块用 chunk string-to-sign 复算比对，成功推进 `prev_signature := chunk_sig`）→ 收到 size=0 终止块 → `:done`；任一块签名不符或解帧错误 → `:failed`（立即中断流、返回 `SignatureDoesNotMatch`，不静默落盘——铁律 3）。

## 请求管线接入

`Endpoint` → `SigV4Plug`（认证，写 principal/auth_type/payload_mode）→ Router → Controller（解析操作 → `{action, bucket, key}`，写 assigns）→ `AuthzPlug`（授权）→ 业务处理（落盘时由 body reader 按 payload_mode 做真实 hash/chunk 校验）。匿名请求 principal=`:anonymous`，仅当 bucket policy 显式 allow 匿名时放行。

## 风险

- **URI/query 编码与 S3 路径不归一化**是签名不匹配头号根因，必须用 AWS SDK 测试向量回归（VERIFY-AT-IMPL）。
- 流式分块 trailer/终止块语义与空串哈希常量易错，MVP 可先 stub 但留状态机骨架。
- 时序侧信道：签名比对务必常数时间。
- `x-amz-content-sha256` 声明值与实际 body 不符必须在落盘阶段拦截，否则数据完整性破防。
- Bandit body 流式与 hash 校验耦合点需明确所有权（建议 body reader 包装器统一处理三种 payload_mode）。

## 依赖

- Hex：`plug`、`bandit`、`phoenix`（已在栈内）；XML 错误响应可用 `saxy` 或手写 iodata 模板（轻量优先，倾向手写 iodata）。`:crypto`（OTP 内置，HMAC/SHA256，无需额外依赖）。
- 可选 Rust crate（后续热点）：`ring` 或 `sha2`+`hmac` 经 Rustler NIF 加速大流式分块哈希——MVP 不需要，OTP `:crypto` 足够。

## 来源

- [Create a signed AWS API request (canonical request)](https://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html)
- [S3 SigV4 header-based auth (single chunk)](https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html)
- [S3 SigV4 streaming (chunked upload)](https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-streaming.html)
- [S3 SigV4 trailing headers (chunked)](https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-streaming-trailers.html)
