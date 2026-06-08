# M3 IAM / 授权 / 策略评估 / Canned ACL / Bucket Policy / 匿名访问 实现计划 · maxio

> For agentic workers（executor）：严格按单元 **M3-1 .. M3-9** 顺序执行。逻辑性代码用 **TDD**（先写失败测试 → 运行确认红 → 最小实现 → 运行确认绿 → commit）；脚手架/配置/迁移类任务用「执行命令 + 验证输出」。每个任务都给了**精确文件路径、完整可用代码（禁止占位符 / TODO / 省略号）、确切 PowerShell 命令与期望输出**。后面任务引用的类型/函数/字段名与前面定义（及 M0/M1/M2 既有代码）**严格一致**——复用既有模块时逐字照抄其现有签名。
>
> **本计划建立在已交付并验证的 M0+M1+M2 之上**（master，191 测试全绿、独立 reviewer APPROVE_WITH_NOTES／0 must-fix）。M3 复用 M0–M2 全部既有模块：`Maxio.S3.{Error,XML,ErrorView,Dispatcher,Endpoint,BodyReader,RawPath,Conditional,Log}`、`Maxio.S3.Plugs.{AddressStyle,SigV4,Dispatch}`、`Maxio.S3.Handlers.{Service,Bucket,Object,Multipart}` + `Maxio.S3.Handlers`、`Maxio.S3.Views.*`、`Maxio.S3.RequestParsers.{CompleteMultipartUpload,Delete}`、`Maxio.Auth` + `Maxio.Auth.SigV4.{Canonical,Signer,AuthHeaderParser,SignedRequest,StreamingVerifier}`、`Maxio.Auth.CredentialStore{,.MemoryStore}`、`Maxio.Storage{,.Backend,.FS}`、`Maxio.{Buckets,Objects,Multipart}` + schema。**严禁重写或破坏这些模块的公开契约**；只允许按本计划做明确的增量扩展。
>
> **铁律对齐（AGENTS.md §3/§4，违反即返工）**：①后端经 behaviour 抽象（存储/凭据/**策略**），上层只认契约——凭据走新增 `EctoStore`（实现既有 `Maxio.Auth.CredentialStore` behaviour），bucket policy 走新增 `Maxio.Policy.Store` behaviour，**核心请求管线对后端实现无感**；②禁止打补丁式修复——从架构层解决（授权统一走纯函数 Evaluator + 单一 Authz 关卡，ACL 与 policy **折叠成同一套 statement** 喂同一个 Evaluator，绝不另起 ACL 评估代码路径）；③**绝不静默失败/放行**——授权拒绝必须返回结构化 S3 错误 XML（`AccessDenied` 403）+ 正确 HTTP 状态 + 结构化日志；匿名请求**只有**当 bucket policy 显式 Allow 匿名 principal 时才放行，其余一律拒绝（默认拒绝、显式 Deny 优先）；④对象 body 绝不进 `Plug.Parsers`、绝不全缓冲——PutBucketPolicy 的 JSON body 与 ACL XML body 走带上限整读（小文档），授权关卡**绝不缓冲对象字节**；⑤S3 行为以官方 AWS 文档/SDK 向量为准（本计划已内嵌核验过的官方策略/ACL/ARN/算法事实）；⑥DB schema 自文档化——新表/列/索引中文 `COMMENT`。
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
  docker exec maxio-db psql -U postgres -d maxio_dev -c "SELECT 1;"
  ```
  执行前确保容器在跑：`docker start maxio-db`。`mix test` 自动迁移 test 库。
- **无 aws-cli / boto3 / mc / python**。端到端验证只用：(a) **纯函数 Evaluator 真值表**单测（独立 ground truth，最权威）；(b) **自签 SigV4** 集成测试（经 `Maxio.S3.Endpoint.call/2`，扩展 `test/support/sigv4_request.ex`）；(c) **匿名（无凭据）请求**集成测试（构造无 `Authorization`/无 `X-Amz-Signature` 的 conn，验证 public bucket policy 放行、无 policy 时 403）。**禁止依赖外部 CLI**。
- **提交**：每个单元（或紧密相关的红绿对）一次 commit，message footer 固定一行：
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
  当前分支为 `master`；本计划全部提交到当前分支（无需开新分支，除非用户另行要求）。

---

## Goal

在 M0–M2 垂直切片之上，补齐**授权（Authorization）子系统**，使 maxio 从「root 全权 stub」升级为真实的 S3 兼容鉴权+授权链路：

1. **M2 硬化（小、先做、降风险）**：
   - **(a) 修 CopyObject REPLACE 自拷贝数据丢失（必修，M2 reviewer note #1）**：`src==dest` 时 `Storage.put(dest,...)` 以 `[:write]` 截断 dest 早于读 source 流 → 源被清零。改为：检测 `src==dest`，走临时 key 中转（读源→写 temp→重命名/再读 temp 写 dest），并加回归测试证明字节不丢。
   - **(b) Multipart.complete 双重清理去重（M2 note #2）**：`Multipart.complete` 内部已 `abort_upload`，handler 又调一次 `Multipart.abort`，去其一。
   - **(c) 条件头 sub-second 截断（M2 note #3）**：`Conditional` 比较时把存储 `last_modified` 截断到秒，避免同秒内修改与 AWS 秒粒度 HTTP-date 结论分歧。
2. **凭据持久化**：`Maxio.Auth.CredentialStore.EctoStore`（`access_keys` 表，中文 COMMENT）实现既有 behaviour，替换 `MemoryStore` 为 dev/prod 默认；root 从 env/config 引导（boot 时幂等 upsert）；`Maxio.IAM` 上下文 + `mix maxio.iam.*` CLI 管 access key 全生命周期（create/list/delete，铁律 4）。MemoryStore 保留供单测。
3. **策略引擎（纯函数核心）**：`Maxio.Policy.{Arn, Statement, RequestContext, Evaluator}`——`Evaluator.evaluate(ctx, statements) :: :allow | {:deny, reason}`，默认拒绝、显式 Deny 优先、glob 匹配 Action(大小写不敏感)/Resource(大小写敏感)、匿名 principal 只匹配 `*`、root/owner 短路放行。MVP 条件算子子集（`StringEquals`/`StringLike`/`Bool`/`IpAddress`/`DateGreaterThan`）。**硬测真值表**。
4. **Bucket Policy 存储 + API**：`Maxio.Policy.Store` behaviour + `EctoStore`（`bucket_policies` 表）；`PutBucketPolicy`/`GetBucketPolicy`/`DeleteBucketPolicy`（`?policy` 子资源，JSON body，validate → `MalformedPolicy`）；`Dispatcher` 从 `:not_implemented` 升级为真实分发。
5. **Canned ACL**：`x-amz-acl` 于 CreateBucket/PutObject 存为元数据；`Put/GetBucketAcl` + `Put/GetObjectAcl`（`?acl` 子资源）`AccessControlPolicy` XML 出入站；canned ACL → 等价 allow statement，**折叠进同一个 Evaluator**。`Dispatcher` 升级 `?acl`。
6. **Authz 关卡 + 匿名**：`Maxio.S3.Authz`（在 Dispatch resolve 出 action 之后、handler 之前调用）构造 `RequestContext`（principal + `s3:Action` + 资源 ARN，按 operation→action 表），评估 bucket policy + ACL 派生 statement，拒绝 → `AccessDenied(403)` + 结构化日志（绝不静默）。`SigV4` plug 允许「完全无凭据」→ principal `:anonymous`（而非 `MissingSecurityHeader 400`），使 public bucket policy 能放行匿名；坏凭据仍硬失败（铁律 3 边界精确）。把每个 M1/M2 handler operation 映射到其 `s3:Action` + 资源层级。

**显式不做（defer，到达即文档化，绝不静默）**：
- **跨账户 / 多租户所有权**：maxio 单租户。`bucket-owner-read`/`bucket-owner-full-control` canned ACL 仅存名、按 `private` 评估（文档化）。`AuthenticatedUsers` 组 = 任意已认证 principal（本系统即任意有效签名）。
- **完整条件算子**：只实现 MVP 子集（见 §M3-4）；`StringNotEquals`/`Numeric*`/`Arn*`/`Null`/`ForAnyValue:`/`*IfExists`/`NotAction`/`NotResource`/`NotPrincipal` → defer（识别但不评估，或保守按不匹配处理，文档化）。
- **IAM identity policy（user inline policy）**：MVP 授权**仅由 bucket policy + ACL 派生 statement + owner/root 短路**驱动；identity policy 留 `Maxio.Policy.Store.principal_policies/1` 接口返回 `[]`（文档化）。
- **STS / 临时凭据 / session token**：`X-Amz-Security-Token` 不解析/不验证（presigned 仍兼容长期 key）。文档化。
- **email grantee（AmazonCustomerByEmail）**：AWS 2025-10-01 已停支。supply 即 `400 InvalidArgument`（不建解析逻辑）。
- **explicit `x-amz-grant-*` 头 / 任意多 grantee 细粒度评估**：ACL XML **round-trip 解析/渲染**支持（GetAcl 正确），但细粒度跨 canonical-user 授权评估 defer（单租户无意义）。
- **Block Public Access** 设置 → defer。
- **`aws-exec-read` / `log-delivery-write` canned** → 仅存名不评估（文档化）。
- **checksum trailer 重算** → 仍按 M2 defer。

---

## Architecture（M3 在 M2 管线上的增量）

```
S3 客户端 → Maxio.S3.Endpoint (Bandit, dev :9900 / prod :9000, 无 Plug.Parsers)
  Plug.RequestId
  Maxio.S3.Plugs.AddressStyle          （不变；产出 s3_bucket/s3_key/s3_level）
  Maxio.S3.Plugs.SigV4                 （★改：无凭据 → principal :anonymous 而非 400；坏凭据仍硬失败）
  Maxio.S3.Plugs.Dispatch              （★改：resolve 出 action 后、调 handler 前插入 Authz.authorize/2）
     └─ Maxio.S3.Authz  ★新            （构造 RequestContext → 评估 → :ok | raise AccessDenied）
          ├─ Maxio.Policy.ActionMap ★新（s3_action atom → {"s3:Xxx", :bucket|:object|:account} 映射表）
          ├─ Maxio.Policy.Store(behaviour)+EctoStore ★新（bucket policy 文档 → [Statement]）
          ├─ Maxio.Policy.ACL ★新       （canned ACL/owner → 等价 [Statement]，折叠进同一 Evaluator）
          └─ Maxio.Policy.Evaluator ★新（纯函数：默认拒绝/显式 Deny 优先/glob/匿名/owner 短路）
                ├─ Maxio.Policy.Arn ★新       （ARN 构造 + glob 匹配）
                ├─ Maxio.Policy.Statement ★新 （解析/规范化/校验 JSON statement）
                └─ Maxio.Policy.RequestContext ★新（principal/action/resource/conditions 结构）
     Handlers.Service/.Bucket/.Object/.Multipart（不变 + 扩：BucketPolicy/ACL handler；CreateBucket/PutObject 存 x-amz-acl）
       入站小文档：Jason（policy JSON）、Maxio.S3.RequestParsers.AccessControlPolicy ★新（saxy SAX）
       出站 XML：Maxio.S3.Views.AccessControlPolicy ★新
  Maxio.S3.BodyReader                   （不变）

凭据后端：config :maxio, :credential_store → Maxio.Auth.CredentialStore.EctoStore ★新（access_keys 表）
策略后端：config :maxio, :policy_store    → Maxio.Policy.Store.EctoStore ★新（bucket_policies 表）
启动引导：Maxio.IAM.bootstrap_root/0 在 application start 幂等 upsert root（EctoStore 下）
CLI：mix maxio.iam.create_key / list_keys / delete_key ★新
```

现有 `MaxioWeb.Endpoint`（:4000，Console/LiveView）**保持不变**，物理隔离。

## 单元总览（按依赖串行；每单元结束须 green compile + 测试通过 + 一次 commit）

| 单元 | 标题 | 依赖 | 规模/分割理由 |
|---|---|---|---|
| **M3-1** | M2 硬化（CopyObject 自拷贝数据丢失 + Complete 双清理 + 条件头秒截断） | M2 | 小、降风险、独立可测，先做 |
| **M3-2** | `Maxio.Policy.{Arn,Statement,RequestContext}` 纯数据/解析/校验（TDD 重） | M3-1 | 纯函数，无 DB，单独成单元 |
| **M3-3** | `Maxio.Policy.Evaluator` 纯函数评估器 + 条件算子子集（**真值表硬测**） | M3-2 | 授权核心，纯函数，TDD 最重 |
| **M3-4** | 凭据持久化：`access_keys` 迁移 + `EctoStore` + `Maxio.IAM` + root 引导 + CLI | M3-1 | context+迁移+CLI，与策略并行无依赖（排 Evaluator 后保证编译稳定） |
| **M3-5** | Bucket policy 存储：`Maxio.Policy.Store` behaviour + `bucket_policies` 迁移 + `EctoStore` | M3-3 | 后端 behaviour + 迁移 |
| **M3-6** | Bucket Policy API：Put/Get/DeleteBucketPolicy + Dispatcher 升级 + 新错误码 + e2e | M3-5 | handler + 分发接线 + 集成 |
| **M3-7** | Canned ACL 存储 + `Maxio.Policy.ACL` 折叠 + Put/Get Bucket/Object ACL XML + Dispatcher | M3-5 | ACL 元数据 + XML 出入站 + 折叠 |
| **M3-8** | `Maxio.Policy.ActionMap` + `Maxio.S3.Authz` 关卡 + 匿名 principal（SigV4 改） + 接线 | M3-6, M3-7 | 授权关卡总装 + 匿名 + 全 operation 映射 |
| **M3-9** | 端到端授权集成测试矩阵 + STATUS 更新（授权场景活体取证） | M3-8 | 集成验收 + 文档收尾 |

**执行顺序**：M3-1 → M3-2 → M3-3 → M3-4 → M3-5 → M3-6 → M3-7 → M3-8 → M3-9。**串行执行，禁止并行 mix 编译**（避免锁文件竞争）。每单元规模都控制在「单个 executor 一轮内可完成实现 + 跑测试 + 调用 StructuredOutput」。

---

## 全局命名契约（M3 新增，一次定义全程复用；M0–M2 既有契约见对应计划）

**沿用既有常量**：XML 命名空间 `"http://s3.amazonaws.com/doc/2006-03-01/"`（`Maxio.S3.XML.namespace/0`）；region `"us-east-1"`；service `"s3"`；algorithm `"AWS4-HMAC-SHA256"`；root principal map `%{type: :root, access_key: ..., arn: "arn:aws:iam:::root"}`；iam_user principal map `%{type: :iam_user, access_key: ..., arn: "arn:aws:iam:::user/<ak>"}`（见 `MemoryStore`）。

**M3 新增 principal 形态**：匿名 principal 统一为原子 `:anonymous`（不是 map）。Authz/Evaluator 必须同时接受 map principal（认证）与 `:anonymous`（匿名）。

**M3 新增 ACL canonical group URI 常量**（见 §M3-7，对齐官方）：
- AllUsers：`"http://acs.amazonaws.com/groups/global/AllUsers"`
- AuthenticatedUsers：`"http://acs.amazonaws.com/groups/global/AuthenticatedUsers"`

**M3 新增模块与签名（跨单元引用，逐字一致）**：

- `Maxio.Policy.Arn`（M3-2）：
  - `bucket_arn(bucket :: String.t()) :: String.t()` —— `"arn:aws:s3:::<bucket>"`
  - `object_arn(bucket :: String.t(), key :: String.t()) :: String.t()` —— `"arn:aws:s3:::<bucket>/<key>"`
  - `account_arn() :: String.t()` —— `"arn:aws:s3:::*"`（ListAllMyBuckets 用）
  - `glob_match?(pattern :: String.t(), value :: String.t(), opts :: keyword()) :: boolean()` —— `opts[:case_insensitive]`，`*`→`.*`、`?`→`.`、其余 `Regex.escape`，`\A…\z` 锚定
- `Maxio.Policy.Statement`（M3-2）：
  - 结构 `%Statement{sid, effect :: :allow | :deny, actions :: [String.t()], resources :: [String.t()], principals :: :any | {:aws, [String.t()]}, conditions :: map()}`
  - `from_json(map()) :: {:ok, t()} | {:error, :malformed}` —— 单条 statement 规范化
  - `parse_policy(json_binary :: binary()) :: {:ok, [t()]} | {:error, :malformed}` —— 解析整篇 policy（Jason + 规范化 + 校验 Version/Effect/Action/Resource）
- `Maxio.Policy.RequestContext`（M3-2）：
  - 结构 `%RequestContext{principal :: map() | :anonymous, authenticated? :: boolean(), owner? :: boolean(), action :: String.t(), resource :: String.t(), conditions :: map()}`
- `Maxio.Policy.Evaluator`（M3-3）：
  - `evaluate(ctx :: RequestContext.t(), statements :: [Statement.t()]) :: :allow | {:deny, :explicit_deny | :implicit_deny}`
- `Maxio.Policy.ACL`（M3-7）：
  - `canned_to_statements(canned :: String.t(), level :: :bucket | :object, bucket :: String.t(), key :: String.t() | nil) :: [Statement.t()]`
  - `to_xml(acl :: map(), owner_id :: String.t()) :: iodata()`（委托 view）
  - `parse_xml(xml :: binary()) :: {:ok, map()} | {:error, :malformed_xml}`（委托 request parser）
- `Maxio.Policy.ActionMap`（M3-8）：
  - `for_action(s3_action :: atom()) :: {required :: String.t(), level :: :bucket | :object | :account} | {:multi, [...]}` —— 见 §M3-8 完整表
- `Maxio.Policy.Store`（M3-5，behaviour）：
  - `@callback get_bucket_policy(bucket :: String.t()) :: {:ok, binary()} | :none`（返回原始 JSON 文档字节）
  - `@callback put_bucket_policy(bucket :: String.t(), json :: binary()) :: :ok | {:error, term()}`
  - `@callback delete_bucket_policy(bucket :: String.t()) :: :ok`
  - `@callback principal_policies(principal :: map() | :anonymous) :: [Maxio.Policy.Statement.t()]`（MVP 恒 `[]`）
- `Maxio.S3.Authz`（M3-8）：
  - `authorize(conn :: Plug.Conn.t(), action :: atom()) :: :ok`（拒绝时 `raise Maxio.S3.Error`）
- `Maxio.IAM`（M3-4）：
  - `bootstrap_root() :: :ok`、`create_access_key(opts :: keyword()) :: {:ok, map()} | {:error, term()}`、`list_access_keys() :: [map()]`、`delete_access_key(ak :: String.t()) :: :ok`
- `Maxio.Auth.CredentialStore.EctoStore`（M3-4，实现既有 behaviour）。
- `%Maxio.IAM.AccessKey{}`（M3-4）：schema 字段 `id, access_key_id, secret_key, principal_arn, type, status, inserted_at, updated_at`。
- `%Maxio.Policy.BucketPolicy{}`（M3-5）：schema 字段 `id, bucket_name, document（jsonb 原始文档）, inserted_at, updated_at`。

---

## M3-1 · M2 硬化（CopyObject 自拷贝数据丢失 + Complete 双清理 + 条件头秒截断）

**目标**：清掉 M2 reviewer 三项 note。其中 (a) 是**数据丢失级必修**，先做。

**依赖**：M2（master）。**规模**：小，三处定点修复 + 回归测试。

### TDD red 1：CopyObject REPLACE 自拷贝数据丢失回归

**根因**（`lib/maxio/s3/handlers/object.ex` `copy/1`）：`src==dest` 时 `Storage.get(src,...)` 返回惰性 `Stream.resource`（打开源文件 fd 在**消费时**才发生），而 `Storage.put(dest, dest, src_stream)` 的 FS `do_put` 先 `File.open(path, [:write])`（**截断 dest=src 为 0 字节**）再 `Enum.reduce` 消费源流 → 此时源已被清零 → 写入 0 字节。COPY 自拷贝有 400 守卫，REPLACE 自拷贝无守卫、无测试。

新建 `test/maxio/s3/copy_self_test.exs`：

```elixir
defmodule Maxio.S3.CopySelfTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_copyself_test")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "CopyObject REPLACE 自拷贝 不丢字节（src==dest, metadata-directive=REPLACE）" do
    SigV4Request.signed_conn(:put, "/cb") |> call()
    body = "Welcome to Amazon S3. Self-copy must not truncate."

    put =
      SigV4Request.signed_conn(:put, "/cb/self.txt",
        body: body,
        headers: [{"content-type", "text/plain"}]
      )
      |> call()

    assert put.status == 200

    copy =
      SigV4Request.signed_conn(:put, "/cb/self.txt",
        headers: [
          {"x-amz-copy-source", "/cb/self.txt"},
          {"x-amz-metadata-directive", "REPLACE"},
          {"content-type", "application/octet-stream"}
        ]
      )
      |> call()

    assert copy.status == 200

    get = SigV4Request.signed_conn(:get, "/cb/self.txt") |> call()
    assert get.status == 200
    assert get.resp_body == body
    assert get_resp_header(get, "content-type") == ["application/octet-stream"]
  end
end
```

运行确认红（修复前会得到空 body）：

```powershell
mix test test/maxio/s3/copy_self_test.exs
```

期望：该用例 FAIL（`get.resp_body` 为 `""` ≠ body）。

### green 1：`copy/1` 自拷贝走临时 key 中转

修改 `lib/maxio/s3/handlers/object.ex` 的 `copy/1`：把「读源流 → 写目标」一段改为：当 `src_bucket==dest_bucket and src_key==dest_key`（自拷贝，此时 directive 必为 REPLACE，否则已被上方 400 守卫拦截）时，先读源流写到一个**唯一临时 key**，成功后再把临时对象流式搬到 dest，最后删临时对象。非自拷贝路径不变。

把现有从 `# 拷贝字节：读源流 ...` 注释起、到对应 `case Storage.put(...) do ... end` 全块（即 object.ex 第 224–254 行那一段，含 metadata 落库 + 日志 + 响应）替换为：

```elixir
    # 拷贝字节（铁律 4 不全缓冲）。自拷贝（src==dest，此处必为 REPLACE）必须避免
    # 「截断 dest 早于读 source」的数据丢失：先流式写到唯一临时 key，再流式搬到 dest，最后删临时。
    self_copy? = src_bucket == dest_bucket and src_key == dest_key

    {size, etag} = copy_bytes(self_copy?, src_bucket, src_key, dest_bucket, dest_key)

    {:ok, obj} =
      Objects.put_metadata(dest_bucket, dest_key, %{
        size: size,
        etag: etag,
        content_type: content_type,
        storage_class: "STANDARD"
      })

    Log.info("copy object",
      action: :copy_object,
      bucket: dest_bucket,
      key: dest_key,
      src_bucket: src_bucket,
      src_key: src_key,
      self_copy: self_copy?
    )

    body =
      Maxio.S3.Views.CopyObjectResult.render(%{etag: etag, last_modified: obj.updated_at})

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  # 非自拷贝：直接流式读源写目标。
  defp copy_bytes(false, src_bucket, src_key, dest_bucket, dest_key) do
    {:ok, src_stream} = Storage.get(src_bucket, src_key, nil)

    case Storage.put(dest_bucket, dest_key, src_stream) do
      {:ok, %{size: size, etag: etag}} -> {size, etag}
      {:error, reason} -> raise Error.new(:internal_error, message: inspect(reason))
    end
  end

  # 自拷贝（src==dest）：先写唯一临时 key（避免截断源），再流式搬到 dest，最后删临时。
  defp copy_bytes(true, src_bucket, src_key, dest_bucket, dest_key) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    tmp_key = dest_key <> ".maxio-copytmp-" <> suffix
    {:ok, src_stream} = Storage.get(src_bucket, src_key, nil)

    case Storage.put(dest_bucket, tmp_key, src_stream) do
      {:ok, _tmp} ->
        {:ok, tmp_stream} = Storage.get(dest_bucket, tmp_key, nil)

        result =
          case Storage.put(dest_bucket, dest_key, tmp_stream) do
            {:ok, %{size: size, etag: etag}} -> {size, etag}
            {:error, reason} -> raise Error.new(:internal_error, message: inspect(reason))
          end

        _ = Storage.delete(dest_bucket, tmp_key)
        result

      {:error, reason} ->
        raise Error.new(:internal_error, message: inspect(reason))
    end
  end
```

> 说明：把字节拷贝抽成两个 `copy_bytes/5` 子句，自拷贝走临时 key 中转。`safe_relative/1` 已禁止 `..`/`.`；临时 key 含随机 hex 后缀不会与正常 key 冲突。替换时**务必把原块结尾的 `end`（copy/1 函数收尾）保留**——上面新代码块在 `send_resp(200, body)` 后给出了 `copy/1` 的收尾 `end`，再接两个私有 `copy_bytes/5`。executor 替换后检查 `copy/1` 与新私有函数的 `end` 配平。

运行确认绿：

```powershell
mix test test/maxio/s3/copy_self_test.exs
```

期望：`1 test, 0 failures`，`get.resp_body == body`。

### green 2：Multipart.complete 双清理去重（M2 note #2）

`lib/maxio/multipart.ex` `complete/3` 内已有 `_ = Maxio.Storage.abort_upload(...)`（assemble 成功后清 part 字节）；`lib/maxio/s3/handlers/multipart.ex` `complete_multipart_upload/1` 又调 `_ = Multipart.abort(upload)`（再次 abort_upload + 删会话/级联删 part 元数据）。**保留 handler 侧 `Multipart.abort(upload)`**（它还负责删会话元数据），**删掉 context 侧 complete 内的 `abort_upload` 调用**。

修改 `lib/maxio/multipart.ex` `complete/3` 的 assemble 成功分支：

```elixir
      case Maxio.Storage.assemble(upload.bucket_name, upload.key, upload.upload_id, part_numbers) do
        {:ok, %{size: size}} ->
          # part 字节清理 + 会话/分块元数据删除统一由调用方 handler 的 Multipart.abort/1 负责
          # （单一职责，不在此重复 abort_upload）。
          {:ok, %{etag: etag, size: size}}

        {:error, _} = err ->
          err
      end
```

### TDD red 3 + green 3：条件头 sub-second 截断（M2 note #3）

**根因**：`Maxio.S3.Conditional` 用全微秒 `last_modified`（`utc_datetime_usec`）与秒粒度 HTTP-date `DateTime.compare/2`。须把比较双方截断到秒。

新建 `test/maxio/s3/conditional_subsecond_test.exs`：

```elixir
defmodule Maxio.S3.ConditionalSubsecondTest do
  use ExUnit.Case, async: true
  alias Maxio.S3.Conditional

  test "If-Unmodified-Since 同秒（亚秒被截断）→ proceed 而非 412" do
    lm = ~U[2026-06-08 12:00:00.500000Z]
    headers = [{"if-unmodified-since", "Mon, 08 Jun 2026 12:00:00 GMT"}]
    assert Conditional.evaluate(headers, %{etag: "abc", last_modified: lm}, "PUT") == :proceed
  end

  test "If-Modified-Since 同秒（亚秒被截断）→ 304 而非 proceed（GET）" do
    lm = ~U[2026-06-08 12:00:00.999000Z]
    headers = [{"if-modified-since", "Mon, 08 Jun 2026 12:00:00 GMT"}]
    assert Conditional.evaluate(headers, %{etag: "abc", last_modified: lm}, "GET") == {:respond, 304}
  end
end
```

运行确认红：

```powershell
mix test test/maxio/s3/conditional_subsecond_test.exs
```

期望：两个用例 FAIL。

green：在 `lib/maxio/s3/conditional.ex` 的 `evaluate/3` 入口把 `lm` 截断到秒：

```elixir
  def evaluate(headers, %{etag: etag, last_modified: lm}, method) do
    if_match = get(headers, "if-match")
    if_unmod = get(headers, "if-unmodified-since")
    if_none = get(headers, "if-none-match")
    if_mod = get(headers, "if-modified-since")

    # HTTP-date 是秒粒度；把存储的亚秒 last_modified 截断到秒再比较（M2 note #3，铁律 5）。
    lm = truncate_to_second(lm)

    step1(if_match, if_unmod, if_none, if_mod, etag, lm, method)
  end

  defp truncate_to_second(%DateTime{} = dt), do: %{dt | microsecond: {0, 0}}
```

运行确认绿：

```powershell
mix test test/maxio/s3/conditional_subsecond_test.exs
```

期望：`2 tests, 0 failures`。

### 单元收尾验证（M3-1）

```powershell
mix compile --warnings-as-errors
mix test
```

期望：编译零警告；全量测试通过（M2 基线 191 + 本单元新增用例，全绿）。提交：

```powershell
git add -A
git commit -m @'
M3-1: M2 hardening — fix CopyObject REPLACE self-copy data loss; dedupe multipart complete cleanup; second-truncate conditional dates

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) 自拷贝 REPLACE 后 GET 返回完整源字节（非空）；(2) `Multipart.complete` 不再含 `abort_upload` 调用，且 multipart 完整 e2e 仍绿；(3) Conditional 秒截断两用例绿；(4) `mix compile --warnings-as-errors` 零警告、全量测试绿。

---

## M3-2 · `Maxio.Policy.{Arn, Statement, RequestContext}`（纯数据 / 解析 / 校验）

**目标**：策略引擎的纯数据与解析层。无 DB、无 plug、无副作用。TDD 重。

**依赖**：M3-1。**规模**：三个纯模块 + 完整单测。

### 模块 1：`Maxio.Policy.Arn`（ARN 构造 + glob 匹配）

新建 `lib/maxio/policy/arn.ex`：

```elixir
defmodule Maxio.Policy.Arn do
  @moduledoc """
  S3 ARN 构造与通配匹配（铁律 5，对齐官方）。
  S3 ARN 的 region/account 段恒空：`arn:aws:s3:::<bucket>[/<key>]`。
  桶级动作用桶 ARN，对象级动作用对象 ARN（getting this wrong 是 S3 授权头号 bug）。

  通配（Action 与 Resource 共用，policy 文档语义）：
    * `*` = 多字符（≥0）通配  →  正则 `.*`
    * `?` = 单字符通配        →  正则 `.`
    * 其余字符 Regex.escape，整体 `\\A…\\z` 锚定。
  Action 匹配大小写不敏感（官方：`iam:ListAccessKeys` == `IAM:listaccesskeys`）；
  Resource 匹配大小写敏感（S3 key 区分大小写）。
  """

  @doc "桶资源 ARN：arn:aws:s3:::<bucket>"
  @spec bucket_arn(String.t()) :: String.t()
  def bucket_arn(bucket), do: "arn:aws:s3:::" <> bucket

  @doc "对象资源 ARN：arn:aws:s3:::<bucket>/<key>"
  @spec object_arn(String.t(), String.t()) :: String.t()
  def object_arn(bucket, key), do: "arn:aws:s3:::" <> bucket <> "/" <> key

  @doc "账户级伪资源（ListAllMyBuckets）：arn:aws:s3:::*"
  @spec account_arn() :: String.t()
  def account_arn, do: "arn:aws:s3:::*"

  @doc """
  通配匹配。opts[:case_insensitive]（默认 false）。
  pattern 来自 policy（可含 `*`/`?`），value 是请求的具体 action/resource 串。
  """
  @spec glob_match?(String.t(), String.t(), keyword()) :: boolean()
  def glob_match?(pattern, value, opts \\ []) when is_binary(pattern) and is_binary(value) do
    regex_src =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    flags = if Keyword.get(opts, :case_insensitive, false), do: "iu", else: "u"

    case Regex.compile("\\A" <> regex_src <> "\\z", flags) do
      {:ok, re} -> Regex.match?(re, value)
      {:error, _} -> false
    end
  end
end
```

单测 `test/maxio/policy/arn_test.exs`：

```elixir
defmodule Maxio.Policy.ArnTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.Arn

  test "ARN 构造" do
    assert Arn.bucket_arn("mybucket") == "arn:aws:s3:::mybucket"
    assert Arn.object_arn("mybucket", "a/b.txt") == "arn:aws:s3:::mybucket/a/b.txt"
    assert Arn.account_arn() == "arn:aws:s3:::*"
  end

  test "Resource glob：bucket/* 命中对象 ARN，不命中桶 ARN" do
    assert Arn.glob_match?("arn:aws:s3:::b/*", "arn:aws:s3:::b/k.txt")
    assert Arn.glob_match?("arn:aws:s3:::b/*", "arn:aws:s3:::b/a/deep/k.txt")
    refute Arn.glob_match?("arn:aws:s3:::b/*", "arn:aws:s3:::b")
  end

  test "Resource glob：桶 ARN 精确，不命中对象 ARN" do
    assert Arn.glob_match?("arn:aws:s3:::b", "arn:aws:s3:::b")
    refute Arn.glob_match?("arn:aws:s3:::b", "arn:aws:s3:::b/k")
  end

  test "前缀通配 + ? 单字符" do
    assert Arn.glob_match?("arn:aws:s3:::b/home/*", "arn:aws:s3:::b/home/x")
    refute Arn.glob_match?("arn:aws:s3:::b/home/*", "arn:aws:s3:::b/other/x")
    assert Arn.glob_match?("a?c", "abc")
    refute Arn.glob_match?("a?c", "ac")
  end

  test "Action 大小写不敏感；Resource 大小写敏感" do
    assert Arn.glob_match?("s3:get*", "s3:GetObject", case_insensitive: true)
    assert Arn.glob_match?("s3:*", "s3:DeleteObject", case_insensitive: true)
    refute Arn.glob_match?("arn:aws:s3:::B/*", "arn:aws:s3:::b/k")
  end

  test "正则元字符被转义（点不当通配）" do
    assert Arn.glob_match?("arn:aws:s3:::b/a.txt", "arn:aws:s3:::b/a.txt")
    refute Arn.glob_match?("arn:aws:s3:::b/a.txt", "arn:aws:s3:::b/aXtxt")
  end
end
```

### 模块 2：`Maxio.Policy.Statement`（解析 / 规范化 / 校验）

新建 `lib/maxio/policy/statement.ex`：

```elixir
defmodule Maxio.Policy.Statement do
  @moduledoc """
  策略 statement 规范化结构 + 整篇 policy 解析/校验（铁律 5，对齐官方策略文档格式）。

  policy 文档（JSON）：{ "Version": "2012-10-17", "Id"?, "Statement": stmt | [stmt] }
    Version 只接受 "2012-10-17" 或 legacy "2008-10-17"；其余 → :malformed。
  statement：{ "Sid"?, "Effect": "Allow"|"Deny", "Principal"?, "Action": s|[s],
               "Resource": s|[s], "Condition"? }
    bucket policy（resource-based）必须有 Principal；本 MVP 把缺省 Principal 视为
    {:aws,["*"]}? —— 不，bucket policy 缺 Principal 应判 :malformed（与 AWS 一致）。
    Effect 必须恰为 "Allow"/"Deny"（区分大小写）。
    Action/Resource 必须存在且非空（本 MVP 不支持 NotAction/NotResource → 出现即忽略该字段
    但若导致无 Action/Resource 则 :malformed）。

  本 MVP defer（识别即文档化，不静默）：NotAction/NotResource/NotPrincipal、Service principal、
  CanonicalUser principal 细粒度（保留串，评估时按非匿名特定账户处理）。
  """
  alias Maxio.Policy.Arn

  @type effect :: :allow | :deny
  @type principals :: :any | {:aws, [String.t()]}
  @type t :: %__MODULE__{
          sid: String.t() | nil,
          effect: effect(),
          actions: [String.t()],
          resources: [String.t()],
          principals: principals(),
          conditions: map()
        }

  defstruct sid: nil, effect: :allow, actions: [], resources: [], principals: :any, conditions: %{}

  @allowed_versions ["2012-10-17", "2008-10-17"]

  @doc "解析整篇 policy JSON。成功 → {:ok, [t()]}；任何畸形 → {:error, :malformed}。"
  @spec parse_policy(binary()) :: {:ok, [t()]} | {:error, :malformed}
  def parse_policy(json) when is_binary(json) do
    with {:ok, doc} <- decode(json),
         :ok <- check_version(doc),
         {:ok, raw_stmts} <- fetch_statements(doc),
         {:ok, stmts} <- normalize_all(raw_stmts) do
      {:ok, stmts}
    else
      _ -> {:error, :malformed}
    end
  end

  @doc "规范化单条 statement map。"
  @spec from_json(map()) :: {:ok, t()} | {:error, :malformed}
  def from_json(%{} = stmt) do
    with {:ok, effect} <- parse_effect(Map.get(stmt, "Effect")),
         {:ok, actions} <- to_nonempty_list(Map.get(stmt, "Action")),
         {:ok, resources} <- to_nonempty_list(Map.get(stmt, "Resource")),
         {:ok, principals} <- parse_principal(Map.get(stmt, "Principal")),
         {:ok, conditions} <- parse_conditions(Map.get(stmt, "Condition")) do
      {:ok,
       %__MODULE__{
         sid: Map.get(stmt, "Sid"),
         effect: effect,
         actions: actions,
         resources: resources,
         principals: principals,
         conditions: conditions
       }}
    else
      _ -> {:error, :malformed}
    end
  end

  def from_json(_), do: {:error, :malformed}

  # ── 内部 ──
  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{} = doc} -> {:ok, doc}
      _ -> {:error, :malformed}
    end
  end

  defp check_version(doc) do
    case Map.get(doc, "Version") do
      nil -> :ok
      v when v in @allowed_versions -> :ok
      _ -> {:error, :malformed}
    end
  end

  defp fetch_statements(doc) do
    case Map.get(doc, "Statement") do
      %{} = single -> {:ok, [single]}
      list when is_list(list) and list != [] -> {:ok, list}
      _ -> {:error, :malformed}
    end
  end

  defp normalize_all(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn stmt, {:ok, acc} ->
      case from_json(stmt) do
        {:ok, s} -> {:cont, {:ok, [s | acc]}}
        {:error, _} -> {:halt, {:error, :malformed}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp parse_effect("Allow"), do: {:ok, :allow}
  defp parse_effect("Deny"), do: {:ok, :deny}
  defp parse_effect(_), do: {:error, :malformed}

  defp to_nonempty_list(v) when is_binary(v) and v != "", do: {:ok, [v]}

  defp to_nonempty_list(list) when is_list(list) do
    strs = Enum.filter(list, &(is_binary(&1) and &1 != ""))
    if strs == [], do: {:error, :malformed}, else: {:ok, strs}
  end

  defp to_nonempty_list(_), do: {:error, :malformed}

  # Principal："*" | {"AWS": "*" | ak | [..]} | {"Service": ...}(defer→当特定) | 缺省(bucket policy 非法)
  defp parse_principal("*"), do: {:ok, :any}
  defp parse_principal(%{"AWS" => "*"}), do: {:ok, :any}

  defp parse_principal(%{"AWS" => aws}) when is_binary(aws), do: {:ok, {:aws, [aws]}}

  defp parse_principal(%{"AWS" => list}) when is_list(list) do
    strs = Enum.filter(list, &is_binary/1)
    cond do
      "*" in strs -> {:ok, :any}
      strs == [] -> {:error, :malformed}
      true -> {:ok, {:aws, strs}}
    end
  end

  # Service / CanonicalUser 等其它形态：MVP 不细评估，保留为特定 principal（不匹配匿名）。
  defp parse_principal(%{} = other) do
    vals = other |> Map.values() |> List.flatten() |> Enum.filter(&is_binary/1)
    if vals == [], do: {:error, :malformed}, else: {:ok, {:aws, vals}}
  end

  # 缺省 Principal：bucket policy（resource-based）必须显式 Principal → 判畸形。
  defp parse_principal(nil), do: {:error, :malformed}
  defp parse_principal(_), do: {:error, :malformed}

  defp parse_conditions(nil), do: {:ok, %{}}
  defp parse_conditions(%{} = cond_map), do: {:ok, cond_map}
  defp parse_conditions(_), do: {:error, :malformed}

  @doc "便于测试/调试：判断某 action 串是否被本 statement 的 Action 命中（大小写不敏感）。"
  @spec action_match?(t(), String.t()) :: boolean()
  def action_match?(%__MODULE__{actions: actions}, action) do
    Enum.any?(actions, &Arn.glob_match?(&1, action, case_insensitive: true))
  end

  @doc "便于测试/调试：判断某 resource ARN 是否被本 statement 的 Resource 命中（大小写敏感）。"
  @spec resource_match?(t(), String.t()) :: boolean()
  def resource_match?(%__MODULE__{resources: resources}, resource) do
    Enum.any?(resources, &Arn.glob_match?(&1, resource))
  end
end
```

单测 `test/maxio/policy/statement_test.exs`：

```elixir
defmodule Maxio.Policy.StatementTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.Statement

  @public_read ~s({"Version":"2012-10-17","Statement":[{"Sid":"P","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}]})

  test "解析 public-read（单 statement、Principal *）" do
    assert {:ok, [s]} = Statement.parse_policy(@public_read)
    assert s.effect == :allow
    assert s.principals == :any
    assert s.actions == ["s3:GetObject"]
    assert s.resources == ["arn:aws:s3:::b/*"]
    assert Statement.action_match?(s, "s3:GetObject")
    assert Statement.resource_match?(s, "arn:aws:s3:::b/k.txt")
  end

  test "Statement 单对象（非数组）归一化为列表" do
    json = ~s({"Version":"2012-10-17","Statement":{"Effect":"Deny","Principal":"*","Action":["s3:*"],"Resource":["arn:aws:s3:::b","arn:aws:s3:::b/*"]}})
    assert {:ok, [s]} = Statement.parse_policy(json)
    assert s.effect == :deny
    assert s.actions == ["s3:*"]
  end

  test "Action/Resource 数组" do
    json = ~s({"Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::111:user/x"},"Action":["s3:GetObject","s3:PutObject"],"Resource":["arn:aws:s3:::b/*"]}]})
    assert {:ok, [s]} = Statement.parse_policy(json)
    assert s.principals == {:aws, ["arn:aws:iam::111:user/x"]}
  end

  test "AWS:* 归一化为 :any" do
    json = ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"*"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})
    assert {:ok, [s]} = Statement.parse_policy(json)
    assert s.principals == :any
  end

  test "畸形：非 JSON" do
    assert {:error, :malformed} = Statement.parse_policy("not json")
  end

  test "畸形：Effect 非法" do
    json = ~s({"Statement":{"Effect":"Permit","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::b"}})
    assert {:error, :malformed} = Statement.parse_policy(json)
  end

  test "畸形：bucket policy 缺 Principal" do
    json = ~s({"Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})
    assert {:error, :malformed} = Statement.parse_policy(json)
  end

  test "畸形：缺 Action" do
    json = ~s({"Statement":{"Effect":"Allow","Principal":"*","Resource":"arn:aws:s3:::b"}})
    assert {:error, :malformed} = Statement.parse_policy(json)
  end

  test "畸形：Version 未知" do
    json = ~s({"Version":"1999-01-01","Statement":{"Effect":"Allow","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::b"}})
    assert {:error, :malformed} = Statement.parse_policy(json)
  end

  test "Condition 透传为 map" do
    json = ~s({"Statement":{"Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::b","arn:aws:s3:::b/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}})
    assert {:ok, [s]} = Statement.parse_policy(json)
    assert s.conditions == %{"Bool" => %{"aws:SecureTransport" => "false"}}
  end
end
```

### 模块 3：`Maxio.Policy.RequestContext`

新建 `lib/maxio/policy/request_context.ex`：

```elixir
defmodule Maxio.Policy.RequestContext do
  @moduledoc """
  授权评估输入（纯数据）。由 Maxio.S3.Authz 按 operation→action 映射 + 当前 principal 组装。

  字段：
    * principal —— 认证 principal map（%{type, access_key, arn}）或 :anonymous。
    * authenticated? —— 是否带有效签名（AuthenticatedUsers 组判定用；:anonymous → false）。
    * owner? —— principal 是否为该资源（桶/对象）所有者或 root（短路放行用）。
    * action —— "s3:GetObject" 等具体动作串。
    * resource —— 已构造的具体资源 ARN（桶级动作=桶 ARN，对象级=对象 ARN，账户级=arn:aws:s3:::*）。
    * conditions —— 从 HTTP 请求抽取的条件键值（aws:SecureTransport / aws:SourceIp /
      aws:CurrentTime / s3:prefix / s3:delimiter 等），供条件算子求值。
  """
  @type t :: %__MODULE__{
          principal: map() | :anonymous,
          authenticated?: boolean(),
          owner?: boolean(),
          action: String.t(),
          resource: String.t(),
          conditions: map()
        }

  defstruct principal: :anonymous,
            authenticated?: false,
            owner?: false,
            action: "",
            resource: "",
            conditions: %{}
end
```

单测 `test/maxio/policy/request_context_test.exs`：

```elixir
defmodule Maxio.Policy.RequestContextTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.RequestContext

  test "默认值（匿名、未认证、非 owner）" do
    ctx = %RequestContext{}
    assert ctx.principal == :anonymous
    assert ctx.authenticated? == false
    assert ctx.owner? == false
    assert ctx.conditions == %{}
  end

  test "可构造认证 owner 上下文" do
    ctx = %RequestContext{
      principal: %{type: :root, access_key: "ak", arn: "arn:aws:iam:::root"},
      authenticated?: true,
      owner?: true,
      action: "s3:GetObject",
      resource: "arn:aws:s3:::b/k",
      conditions: %{"aws:SecureTransport" => true}
    }

    assert ctx.owner?
    assert ctx.action == "s3:GetObject"
  end
end
```

### 单元收尾验证（M3-2）

```powershell
mix test test/maxio/policy/arn_test.exs test/maxio/policy/statement_test.exs test/maxio/policy/request_context_test.exs
mix compile --warnings-as-errors
mix test
```

期望：三文件全绿；编译零警告；全量测试绿。提交：

```powershell
git add -A
git commit -m @'
M3-2: Policy data layer — Arn (glob match), Statement (JSON parse/validate), RequestContext

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) Arn glob 正反例（bucket/* vs bucket、大小写、元字符转义）全绿；(2) Statement 解析 public-read/单对象归一化/数组/畸形（非 JSON、Effect 非法、缺 Principal/Action、Version 未知）全覆盖；(3) 零警告、全量绿。

---

## M3-3 · `Maxio.Policy.Evaluator`（纯函数评估器 + 条件算子子集，真值表硬测）

**目标**：授权决策核心。纯函数：`evaluate(ctx, statements) :: :allow | {:deny, :explicit_deny | :implicit_deny}`。默认拒绝、显式 Deny 优先、glob 匹配、匿名 principal 只匹配 `*`、owner/root 短路。**这是 M3 最重的 TDD 单元——真值表必须穷举。**

**依赖**：M3-2。**规模**：一个评估器模块 + 一个条件算子模块 + 详尽真值表单测。

### 评估算法（官方核验，§RESEARCH 已 bake-in）

```
Rule 0: ctx.owner? == true → :allow（root/资源所有者短路，等价 AWS「root 全权 + 资源所有者可访问」）
Step 1: 任一 applicable 且 effect==:deny → {:deny, :explicit_deny}（Deny 永远压倒 Allow）
Step 2: 任一 applicable 且 effect==:allow → :allow
Step 3: 否则 → {:deny, :implicit_deny}（默认拒绝）

statement applicable ⇔ principal_match? ∧ action_match? ∧ resource_match? ∧ conditions_hold?
（effect 不参与 applicable 判定，只决定终局裁决）
```

principal_match 规则（关键）：
- `:any`（policy `Principal:"*"`）→ 匹配匿名 **和** 任意认证 principal。
- `{:aws, list}`（特定账户/用户/canonical-user 串）→ 只匹配认证 principal 且其 `arn` 被 list 中某项 glob 命中（MVP 单租户：list 含 `"*"` 已在 Statement 归一化为 `:any`；否则按 arn 串匹配，匿名永不命中）。
- 匿名 principal 绝不匹配 `{:aws, list}`（即使 list 里有特定账户）。

### 模块 1：`Maxio.Policy.Condition`（MVP 条件算子子集）

新建 `lib/maxio/policy/condition.ex`：

```elixir
defmodule Maxio.Policy.Condition do
  @moduledoc """
  策略 Condition 块求值（铁律 5，对齐官方条件算子语义）。MVP 子集：
    StringEquals / StringLike / Bool / IpAddress / DateGreaterThan。
  其余算子（StringNotEquals / Numeric* / Arn* / Null / ForAnyValue: / *IfExists /
  StringEqualsIgnoreCase / NotIpAddress / DateLessThan...）→ defer：本 MVP 把含未知算子的
  Condition 块判为「不成立」（保守：含 defer 算子的 statement 不命中，绝不静默放行）。

  语义：
    * Condition 块 = %{ operator => %{ key => value | [values] } }；所有 operator/key 项须全真（AND）。
    * 单 key 内 policy 值为数组 → 任一命中即真（OR）。
    * 缺失 key（请求未提供该条件键）→ 该项为 false（statement 不命中）。MVP 无 *IfExists/Null。
    * Bool 的 policy 值是字符串 "true"/"false"，与请求实际布尔比较。
    * IpAddress 支持单 IP（视为 /32）与 CIDR。
    * DateGreaterThan：请求时间 > policy ISO8601 时间。
  """

  @known ~w(StringEquals StringLike Bool IpAddress DateGreaterThan)

  @doc "Condition 块是否全部成立。conditions = 请求上下文条件键值 map。"
  @spec hold?(map() | nil, map()) :: boolean()
  def hold?(nil, _ctx), do: true
  def hold?(block, _ctx) when block == %{}, do: true

  def hold?(block, ctx) when is_map(block) do
    Enum.all?(block, fn {operator, kv} ->
      # 含未知（defer）算子 → 保守判 false（不放行）。
      operator in @known and operator_holds?(operator, kv, ctx)
    end)
  end

  def hold?(_block, _ctx), do: false

  defp operator_holds?(op, kv, ctx) when is_map(kv) do
    Enum.all?(kv, fn {key, policy_val} ->
      case Map.fetch(ctx, key) do
        # 缺失条件键 → false（MVP 无 IfExists/Null）。
        :error -> false
        {:ok, req_val} -> eval(op, policy_val, req_val)
      end
    end)
  end

  defp operator_holds?(_op, _kv, _ctx), do: false

  # policy 值数组 → OR
  defp eval(op, policy_vals, req_val) when is_list(policy_vals) do
    Enum.any?(policy_vals, &eval(op, &1, req_val))
  end

  defp eval("StringEquals", policy_val, req_val) do
    to_string(policy_val) == to_string(req_val)
  end

  defp eval("StringLike", policy_val, req_val) do
    Maxio.Policy.Arn.glob_match?(to_string(policy_val), to_string(req_val))
  end

  defp eval("Bool", policy_val, req_val) do
    norm_bool(policy_val) == norm_bool(req_val)
  end

  defp eval("IpAddress", cidr, req_ip) when is_binary(req_ip) do
    ip_in_cidr?(req_ip, to_string(cidr))
  end

  defp eval("IpAddress", _cidr, _req_ip), do: false

  defp eval("DateGreaterThan", policy_iso, %DateTime{} = req_dt) do
    case DateTime.from_iso8601(to_string(policy_iso)) do
      {:ok, policy_dt, _} -> DateTime.compare(req_dt, policy_dt) == :gt
      _ -> false
    end
  end

  defp eval("DateGreaterThan", _policy, _req), do: false
  defp eval(_op, _policy, _req), do: false

  defp norm_bool(true), do: true
  defp norm_bool(false), do: false
  defp norm_bool("true"), do: true
  defp norm_bool("false"), do: false
  defp norm_bool(_), do: :invalid

  # req_ip 在 cidr 范围内（IPv4；单 IP 视为 /32）。解析失败 → false（保守）。
  defp ip_in_cidr?(req_ip, cidr) do
    with {:ok, req} <- parse_ipv4(req_ip),
         {:ok, {net, bits}} <- parse_cidr(cidr) do
      mask = mask_for(bits)
      band(req, mask) == band(net, mask)
    else
      _ -> false
    end
  end

  defp parse_cidr(cidr) do
    case String.split(cidr, "/", parts: 2) do
      [ip, bits_str] ->
        with {:ok, net} <- parse_ipv4(ip),
             {bits, ""} <- Integer.parse(bits_str),
             true <- bits >= 0 and bits <= 32 do
          {:ok, {net, bits}}
        else
          _ -> :error
        end

      [ip] ->
        case parse_ipv4(ip) do
          {:ok, net} -> {:ok, {net, 32}}
          _ -> :error
        end
    end
  end

  defp parse_ipv4(str) do
    case String.split(str, ".") do
      [a, b, c, d] ->
        with {oa, ""} <- Integer.parse(a),
             {ob, ""} <- Integer.parse(b),
             {oc, ""} <- Integer.parse(c),
             {od, ""} <- Integer.parse(d),
             true <- Enum.all?([oa, ob, oc, od], &(&1 >= 0 and &1 <= 255)) do
          {:ok, (oa <<< 24) + (ob <<< 16) + (oc <<< 8) + od}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp mask_for(0), do: 0
  defp mask_for(bits), do: band(bxor(0xFFFFFFFF, (1 <<< (32 - bits)) - 1), 0xFFFFFFFF)

  import Bitwise
end
```

> 注意：`import Bitwise` 须放在模块顶部（Elixir 允许 `import` 在模块体内任意位置但只对其后生效；为稳妥，executor 把 `import Bitwise` 移到 `@moduledoc` 之后、第一个函数之前）。`<<<`/`band`/`bxor`/`bor` 来自 Bitwise。

### 模块 2：`Maxio.Policy.Evaluator`

新建 `lib/maxio/policy/evaluator.ex`：

```elixir
defmodule Maxio.Policy.Evaluator do
  @moduledoc """
  授权评估器（纯函数，无副作用，可 IEx 复算，铁律 3/4）。
  evaluate(ctx, statements) :: :allow | {:deny, :explicit_deny | :implicit_deny}

  算法（官方核验，§RESEARCH bake-in）：
    Rule 0: ctx.owner? → :allow（root/资源所有者短路）
    Step 1: 任一 applicable Deny → {:deny, :explicit_deny}
    Step 2: 任一 applicable Allow → :allow
    Step 3: 否则 → {:deny, :implicit_deny}
  applicable ⇔ principal ∧ action ∧ resource ∧ conditions 全部命中（effect 不参与 applicable）。
  """
  alias Maxio.Policy.{Arn, Condition, RequestContext, Statement}

  @spec evaluate(RequestContext.t(), [Statement.t()]) ::
          :allow | {:deny, :explicit_deny | :implicit_deny}
  def evaluate(%RequestContext{owner?: true}, _statements), do: :allow

  def evaluate(%RequestContext{} = ctx, statements) when is_list(statements) do
    applicable = Enum.filter(statements, &statement_applies?(&1, ctx))

    cond do
      Enum.any?(applicable, &(&1.effect == :deny)) -> {:deny, :explicit_deny}
      Enum.any?(applicable, &(&1.effect == :allow)) -> :allow
      true -> {:deny, :implicit_deny}
    end
  end

  defp statement_applies?(%Statement{} = s, %RequestContext{} = ctx) do
    principal_match?(s.principals, ctx) and
      action_match?(s.actions, ctx.action) and
      resource_match?(s.resources, ctx.resource) and
      Condition.hold?(s.conditions, ctx.conditions)
  end

  # :any 匹配匿名与任意认证；{:aws,list} 只匹配认证 principal 且 arn 命中（匿名永不命中）。
  defp principal_match?(:any, _ctx), do: true

  defp principal_match?({:aws, _list}, %RequestContext{principal: :anonymous}), do: false

  defp principal_match?({:aws, list}, %RequestContext{principal: %{arn: arn}}) do
    Enum.any?(list, fn pat -> Arn.glob_match?(pat, arn) end)
  end

  defp principal_match?(_principals, _ctx), do: false

  defp action_match?(actions, action) do
    Enum.any?(actions, &Arn.glob_match?(&1, action, case_insensitive: true))
  end

  defp resource_match?(resources, resource) do
    Enum.any?(resources, &Arn.glob_match?(&1, resource))
  end
end
```

### TDD 真值表单测 `test/maxio/policy/evaluator_test.exs`（穷举）

```elixir
defmodule Maxio.Policy.EvaluatorTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.{Evaluator, RequestContext, Statement}

  defp parse!(json), do: (fn {:ok, s} -> s end).(Statement.parse_policy(json))

  defp anon_ctx(action, resource, conds \\ %{}) do
    %RequestContext{principal: :anonymous, authenticated?: false, owner?: false,
      action: action, resource: resource, conditions: conds}
  end

  defp auth_ctx(arn, action, resource, conds \\ %{}) do
    %RequestContext{principal: %{type: :iam_user, access_key: "ak", arn: arn},
      authenticated?: true, owner?: false, action: action, resource: resource, conditions: conds}
  end

  test "owner 短路放行（无视 statements）" do
    ctx = %RequestContext{owner?: true, action: "s3:DeleteObject", resource: "arn:aws:s3:::b/k"}
    assert Evaluator.evaluate(ctx, []) == :allow
  end

  test "默认拒绝（无 statement）" do
    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k"), []) == {:deny, :implicit_deny}
  end

  test "public-read 放行匿名 GetObject" do
    stmts = parse!(~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}}))
    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k.txt"), stmts) == :allow
  end

  test "public-read 不放行 PutObject（action 不匹配 → 隐式拒绝）" do
    stmts = parse!(~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}}))
    assert Evaluator.evaluate(anon_ctx("s3:PutObject", "arn:aws:s3:::b/k.txt"), stmts) == {:deny, :implicit_deny}
  end

  test "对象 action 不命中桶 ARN 资源（resource 层级错配 → 隐式拒绝）" do
    # Resource 写成桶 ARN（无 /*），GetObject 是对象动作 → 资源不匹配。
    stmts = parse!(~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b"}}))
    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k"), stmts) == {:deny, :implicit_deny}
  end

  test "显式 Deny 压倒 Allow（同 principal 同动作）" do
    stmts = parse!(~s({"Statement":[
      {"Effect":"Allow","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::b","arn:aws:s3:::b/*"]},
      {"Effect":"Deny","Principal":"*","Action":"s3:DeleteObject","Resource":"arn:aws:s3:::b/*"}
    ]}))
    assert Evaluator.evaluate(anon_ctx("s3:DeleteObject", "arn:aws:s3:::b/k"), stmts) == {:deny, :explicit_deny}
    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k"), stmts) == :allow
  end

  test "s3:* 通配 action 命中具体动作（大小写不敏感）" do
    stmts = parse!(~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::b/*"}}))
    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k"), stmts) == :allow
  end

  test "认证特定账户 principal：arn 命中放行，不命中隐拒" do
    stmts = parse!(~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam:::user/alice"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}}))
    assert Evaluator.evaluate(auth_ctx("arn:aws:iam:::user/alice", "s3:GetObject", "arn:aws:s3:::b/k"), stmts) == :allow
    assert Evaluator.evaluate(auth_ctx("arn:aws:iam:::user/bob", "s3:GetObject", "arn:aws:s3:::b/k"), stmts) == {:deny, :implicit_deny}
  end

  test "特定账户 principal 绝不匹配匿名" do
    stmts = parse!(~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam:::user/alice"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}}))
    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k"), stmts) == {:deny, :implicit_deny}
  end

  # ── 条件算子真值表 ──
  test "Deny aws:SecureTransport=false：HTTP 请求命中 Deny，HTTPS 不命中" do
    stmts = parse!(~s({"Statement":[
      {"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"},
      {"Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::b","arn:aws:s3:::b/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}
    ]}))
    # 明文 HTTP：Deny 命中 → explicit_deny
    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k", %{"aws:SecureTransport" => false}), stmts) == {:deny, :explicit_deny}
    # HTTPS：Deny 的 Bool 不命中 → 仅 Allow 命中 → allow
    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k", %{"aws:SecureTransport" => true}), stmts) == :allow
  end

  test "StringEquals s3:prefix：命中放行，不命中隐拒（缺键也不命中）" do
    stmts = parse!(~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:ListBucket","Resource":"arn:aws:s3:::b","Condition":{"StringEquals":{"s3:prefix":["home/","public/"]}}}}))
    assert Evaluator.evaluate(anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{"s3:prefix" => "home/"}), stmts) == :allow
    assert Evaluator.evaluate(anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{"s3:prefix" => "secret/"}), stmts) == {:deny, :implicit_deny}
    # 缺 s3:prefix 键 → 条件不成立 → 隐拒
    assert Evaluator.evaluate(anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{}), stmts) == {:deny, :implicit_deny}
  end

  test "StringLike s3:prefix 通配" do
    stmts = parse!(~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:ListBucket","Resource":"arn:aws:s3:::b","Condition":{"StringLike":{"s3:prefix":["home/*"]}}}}))
    assert Evaluator.evaluate(anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{"s3:prefix" => "home/alice/x"}), stmts) == :allow
    assert Evaluator.evaluate(anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{"s3:prefix" => "away/x"}), stmts) == {:deny, :implicit_deny}
  end

  test "IpAddress aws:SourceIp CIDR" do
    stmts = parse!(~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","Condition":{"IpAddress":{"aws:SourceIp":["203.0.113.0/24"]}}}}))
    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k", %{"aws:SourceIp" => "203.0.113.5"}), stmts) == :allow
    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k", %{"aws:SourceIp" => "198.51.100.1"}), stmts) == {:deny, :implicit_deny}
  end

  test "未知（defer）条件算子 → 保守不命中" do
    stmts = parse!(~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","Condition":{"NumericLessThan":{"s3:max-keys":"10"}}}}))
    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k", %{"s3:max-keys" => "5"}), stmts) == {:deny, :implicit_deny}
  end
end
```

### Condition 单测 `test/maxio/policy/condition_test.exs`

```elixir
defmodule Maxio.Policy.ConditionTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.Condition

  test "nil / 空块 → true" do
    assert Condition.hold?(nil, %{})
    assert Condition.hold?(%{}, %{})
  end

  test "StringEquals 数组 OR" do
    block = %{"StringEquals" => %{"s3:prefix" => ["a/", "b/"]}}
    assert Condition.hold?(block, %{"s3:prefix" => "b/"})
    refute Condition.hold?(block, %{"s3:prefix" => "c/"})
  end

  test "Bool 字符串 vs 布尔" do
    assert Condition.hold?(%{"Bool" => %{"aws:SecureTransport" => "true"}}, %{"aws:SecureTransport" => true})
    refute Condition.hold?(%{"Bool" => %{"aws:SecureTransport" => "false"}}, %{"aws:SecureTransport" => true})
  end

  test "缺键 → false" do
    refute Condition.hold?(%{"StringEquals" => %{"s3:prefix" => "a/"}}, %{})
  end

  test "IpAddress 单 IP（/32）" do
    assert Condition.hold?(%{"IpAddress" => %{"aws:SourceIp" => "10.0.0.1"}}, %{"aws:SourceIp" => "10.0.0.1"})
    refute Condition.hold?(%{"IpAddress" => %{"aws:SourceIp" => "10.0.0.1"}}, %{"aws:SourceIp" => "10.0.0.2"})
  end

  test "DateGreaterThan" do
    block = %{"DateGreaterThan" => %{"aws:CurrentTime" => "2020-01-01T00:00:00Z"}}
    assert Condition.hold?(block, %{"aws:CurrentTime" => ~U[2026-06-08 00:00:00Z]})
    refute Condition.hold?(block, %{"aws:CurrentTime" => ~U[2019-01-01 00:00:00Z]})
  end

  test "多算子 AND" do
    block = %{"Bool" => %{"aws:SecureTransport" => "true"}, "StringEquals" => %{"s3:prefix" => "home/"}}
    assert Condition.hold?(block, %{"aws:SecureTransport" => true, "s3:prefix" => "home/"})
    refute Condition.hold?(block, %{"aws:SecureTransport" => true, "s3:prefix" => "away/"})
  end
end
```

### 单元收尾验证（M3-3）

```powershell
mix test test/maxio/policy/condition_test.exs test/maxio/policy/evaluator_test.exs
mix compile --warnings-as-errors
mix test
```

期望：真值表全绿；编译零警告；全量绿。提交：

```powershell
git add -A
git commit -m @'
M3-3: Policy Evaluator (default-deny, explicit-deny-wins, glob, owner short-circuit) + condition operator subset, exhaustive truth table

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) owner 短路、默认拒绝、public-read 放行、Deny 压倒 Allow、resource 层级错配隐拒、特定 principal 不匹配匿名、`s3:*` 通配、五个条件算子（含缺键、defer 算子保守不命中、SecureTransport HTTP/HTTPS 分支）全覆盖且绿；(2) 零警告、全量绿。

---

## M3-4 · 凭据持久化：`access_keys` 迁移 + `EctoStore` + `Maxio.IAM` + root 引导 + CLI

**目标**：把凭据从内存 ETS（`MemoryStore`）升级为 Postgres 持久化（`EctoStore`，实现既有 `Maxio.Auth.CredentialStore` behaviour），dev/prod 默认切到 EctoStore；root 从 config 引导（boot 幂等 upsert）；`Maxio.IAM` 管 access key 全生命周期 + `mix maxio.iam.*` CLI（铁律 4）。**MemoryStore 保留**，test 仍用它（无 DB 依赖、快、与既有 SigV4Request 的 root key 对齐）。

**依赖**：M3-1（与 M3-2/3 无代码依赖，但排在 Evaluator 后保证编译序稳定）。**规模**：迁移 + schema + EctoStore + IAM context + 3 个 mix 任务。

### 步骤 1：迁移 `access_keys`

```powershell
mix ecto.gen.migration create_access_keys
```

编辑生成的 `priv/repo/migrations/<ts>_create_access_keys.exs`：

```elixir
defmodule Maxio.Repo.Migrations.CreateAccessKeys do
  use Ecto.Migration

  def change do
    create table(:access_keys,
             primary_key: false,
             comment:
               "S3 访问密钥（SigV4 凭据）：每个 access key 一行；root 由 boot 幂等引导，其余经 mix maxio.iam.create_key 创建"
           ) do
      add :id, :binary_id, primary_key: true, comment: "访问密钥主键（UUID）"

      add :access_key_id, :string,
        null: false,
        comment: "Access Key ID（SigV4 Credential 的首段；查 secret 与 principal 的键）"

      add :secret_key, :string,
        null: false,
        comment: "Secret Access Key（SigV4 签名密钥；MVP 明文存储——at-rest 加密留后续里程碑，见计划 defer）"

      add :principal_arn, :string,
        null: false,
        comment: "该密钥对应的 principal ARN（root=arn:aws:iam:::root；iam_user=arn:aws:iam:::user/<ak>）"

      add :type, :string,
        null: false,
        default: "iam_user",
        comment: "principal 类型：root | iam_user（决定 Authz 是否走 root 全权短路）"

      add :status, :string,
        null: false,
        default: "active",
        comment: "密钥状态：active | inactive（inactive 视同不存在，鉴权拒绝）"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:access_keys, [:access_key_id],
             comment: "Access Key ID 全局唯一索引（鉴权按此 O(1) 查 secret/principal）"
           )
  end
end
```

> **at-rest 加密决策（文档化，不静默）**：MVP `secret_key` 明文存储（与 MinIO 单机默认一致，简化 SigV4 复算）。`COMMENT` 已标注。后续里程碑可引入 `Cloak`/KMS 信封加密——届时只改 EctoStore 的读写两点，不动鉴权逻辑（铁律 1/2）。

应用迁移并核验 schema：

```powershell
mix ecto.migrate
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ access_keys"
```

期望：表 `access_keys` 含 6 业务列 + 时间戳，每列带中文 COMMENT，`access_key_id` 唯一索引存在。

### 步骤 2：schema `Maxio.IAM.AccessKey`

新建 `lib/maxio/iam/access_key.ex`：

```elixir
defmodule Maxio.IAM.AccessKey do
  @moduledoc "S3 访问密钥（SigV4 凭据）schema。secret 明文存储（MVP；at-rest 加密见计划 defer）。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "access_keys" do
    field :access_key_id, :string
    field :secret_key, :string
    field :principal_arn, :string
    field :type, :string, default: "iam_user"
    field :status, :string, default: "active"

    timestamps(type: :utc_datetime_usec)
  end

  @required [:access_key_id, :secret_key, :principal_arn]
  @optional [:type, :status]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(ak, attrs) do
    ak
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:type, ["root", "iam_user"])
    |> validate_inclusion(:status, ["active", "inactive"])
    |> unique_constraint(:access_key_id, name: :access_keys_access_key_id_index)
  end
end
```

### 步骤 3：`Maxio.IAM` 上下文

新建 `lib/maxio/iam.ex`：

```elixir
defmodule Maxio.IAM do
  @moduledoc """
  访问密钥生命周期 context（铁律 4：CLI 可观测）。root 从 config 引导（boot 幂等 upsert）；
  create/list/delete access key。底层走 EctoStore（持久化）。principal map 形态与 MemoryStore 对齐：
    root     → %{type: :root, access_key: ak, arn: "arn:aws:iam:::root"}
    iam_user → %{type: :iam_user, access_key: ak, arn: "arn:aws:iam:::user/<ak>"}
  """
  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.IAM.AccessKey

  @doc "从 config :maxio, :s3 的 root_user/root_password 幂等引导 root（boot 调用）。"
  @spec bootstrap_root() :: :ok
  def bootstrap_root do
    s3 = Application.fetch_env!(:maxio, :s3)
    ak = Keyword.fetch!(s3, :root_user)
    sk = Keyword.fetch!(s3, :root_password)

    %AccessKey{}
    |> AccessKey.changeset(%{
      access_key_id: ak,
      secret_key: sk,
      principal_arn: "arn:aws:iam:::root",
      type: "root",
      status: "active"
    })
    |> Repo.insert(
      on_conflict: {:replace, [:secret_key, :principal_arn, :type, :status, :updated_at]},
      conflict_target: :access_key_id
    )

    :ok
  end

  @doc "创建 access key。opts: :access_key_id（默认随机）、:secret_key（默认随机）、:type（默认 iam_user）。"
  @spec create_access_key(keyword()) :: {:ok, map()} | {:error, term()}
  def create_access_key(opts \\ []) do
    ak = Keyword.get(opts, :access_key_id) || gen_access_key_id()
    sk = Keyword.get(opts, :secret_key) || gen_secret_key()
    type = Keyword.get(opts, :type, "iam_user")
    arn = if type == "root", do: "arn:aws:iam:::root", else: "arn:aws:iam:::user/#{ak}"

    case %AccessKey{}
         |> AccessKey.changeset(%{
           access_key_id: ak,
           secret_key: sk,
           principal_arn: arn,
           type: type,
           status: "active"
         })
         |> Repo.insert() do
      {:ok, row} ->
        {:ok, %{access_key_id: row.access_key_id, secret_key: sk, principal_arn: arn, type: type}}

      {:error, cs} ->
        {:error, cs}
    end
  end

  @doc "列出全部 access key（不回 secret）。"
  @spec list_access_keys() :: [map()]
  def list_access_keys do
    Repo.all(from a in AccessKey, order_by: [asc: a.inserted_at])
    |> Enum.map(fn a ->
      %{access_key_id: a.access_key_id, principal_arn: a.principal_arn, type: a.type, status: a.status}
    end)
  end

  @doc "删除 access key（幂等）。拒绝删除最后一个 root（避免锁死，铁律 3 不静默放行也不让系统不可用）。"
  @spec delete_access_key(String.t()) :: :ok | {:error, :cannot_delete_last_root}
  def delete_access_key(access_key_id) do
    case Repo.get_by(AccessKey, access_key_id: access_key_id) do
      nil ->
        :ok

      %AccessKey{type: "root"} = row ->
        root_count = Repo.aggregate(from(a in AccessKey, where: a.type == "root"), :count, :id)

        if root_count <= 1 do
          {:error, :cannot_delete_last_root}
        else
          Repo.delete!(row)
          :ok
        end

      %AccessKey{} = row ->
        Repo.delete!(row)
        :ok
    end
  end

  defp gen_access_key_id, do: "AKIA" <> (:crypto.strong_rand_bytes(8) |> Base.encode32(padding: false))
  defp gen_secret_key, do: :crypto.strong_rand_bytes(30) |> Base.encode64() |> binary_part(0, 40)
end
```

### 步骤 4：`Maxio.Auth.CredentialStore.EctoStore`（实现既有 behaviour）

新建 `lib/maxio/auth/credential_store/ecto_store.ex`：

```elixir
defmodule Maxio.Auth.CredentialStore.EctoStore do
  @moduledoc """
  Postgres 凭据后端（铁律 1：实现既有 CredentialStore behaviour，换后端不动鉴权逻辑）。
  get_secret 按 access_key_id 查 active 密钥，返回 %{secret_key, principal}；
  principal map 形态与 MemoryStore 对齐（%{type, access_key, arn}）。inactive/缺失 → :error。
  """
  @behaviour Maxio.Auth.CredentialStore

  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.IAM.AccessKey

  @impl true
  def get_secret(access_key) do
    case Repo.get_by(AccessKey, access_key_id: access_key, status: "active") do
      nil ->
        :error

      %AccessKey{} = row ->
        principal = %{
          type: String.to_existing_atom(row.type),
          access_key: row.access_key_id,
          arn: row.principal_arn
        }

        {:ok, %{secret_key: row.secret_key, principal: principal}}
    end
  end

  @impl true
  def put_access_key(%{access_key: ak, secret_key: sk} = attrs) do
    type = Map.get(attrs, :type, "iam_user")
    arn = Map.get(attrs, :arn) || (if type == "root", do: "arn:aws:iam:::root", else: "arn:aws:iam:::user/#{ak}")

    %AccessKey{}
    |> AccessKey.changeset(%{access_key_id: ak, secret_key: sk, principal_arn: arn, type: to_string(type), status: "active"})
    |> Repo.insert(
      on_conflict: {:replace, [:secret_key, :principal_arn, :type, :status, :updated_at]},
      conflict_target: :access_key_id
    )
    |> case do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, cs}
    end
  end

  def put_access_key(_), do: {:error, :invalid_attrs}

  @impl true
  def list_keys do
    Repo.all(from a in AccessKey)
    |> Enum.map(fn a ->
      %{access_key: a.access_key_id, principal: %{type: String.to_existing_atom(a.type), access_key: a.access_key_id, arn: a.principal_arn}}
    end)
  end
end
```

> `String.to_existing_atom/1` 安全：`:root`/`:iam_user` 在编译期已存在（MemoryStore 用过）。type 列经 changeset `validate_inclusion` 限定，不会出现任意值。

### 步骤 5：dev/prod 默认切到 EctoStore，test 保留 MemoryStore

编辑 `config/config.exs`，把凭据后端默认改为 EctoStore（在 `config :maxio, :credential_store, ...` 一行）：

```elixir
config :maxio, :credential_store, Maxio.Auth.CredentialStore.EctoStore
```

编辑 `config/test.exs`，**追加**一行让 test 仍用 MemoryStore（无 DB 依赖、与 SigV4Request 的 root key 对齐、async 友好）：

```elixir
# 凭据后端：test 用 MemoryStore（ETS，无需 DB 引导，root 从 config :maxio, :s3 引导，
# 与 Maxio.Test.SigV4Request 的 root key 对齐）。EctoStore 由其专属测试单独覆盖。
config :maxio, :credential_store, Maxio.Auth.CredentialStore.MemoryStore
```

### 步骤 6：boot 引导 root（仅 EctoStore 下）

编辑 `lib/maxio/application.ex`，在 `Supervisor.start_link` 成功后幂等引导 root（仅当后端是 EctoStore 时）：

```elixir
  @impl true
  def start(_type, _args) do
    children =
      [
        MaxioWeb.Telemetry,
        Maxio.Repo,
        {DNSCluster, query: Application.get_env(:maxio, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Maxio.PubSub},
        MaxioWeb.Endpoint
      ] ++ s3_children()

    opts = [strategy: :one_for_one, name: Maxio.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        maybe_bootstrap_root()
        {:ok, pid}

      other ->
        other
    end
  end

  # 仅 EctoStore 下在 Repo 起来后幂等引导 root（MemoryStore 自带惰性引导，无需此步）。
  defp maybe_bootstrap_root do
    if Application.get_env(:maxio, :credential_store) == Maxio.Auth.CredentialStore.EctoStore do
      try do
        Maxio.IAM.bootstrap_root()
      rescue
        e -> require Logger; Logger.warning("root bootstrap skipped: #{Exception.message(e)}")
      end
    end
  end
```

> `try/rescue` 容错：迁移未跑的环境（如首次 `mix ecto.setup` 前）不应让 app 启动崩溃；引导失败打 warning（不静默）。test 环境后端是 MemoryStore，跳过此步。

### 步骤 7：CLI（`mix maxio.iam.*`，铁律 4）

新建 `lib/mix/tasks/maxio.iam.create_key.ex`：

```elixir
defmodule Mix.Tasks.Maxio.Iam.CreateKey do
  @shortdoc "创建一个 S3 access key（持久化到 access_keys 表）"
  @moduledoc """
  创建访问密钥（铁律 4：CLI 管凭据生命周期）。

  用法（先设 $env:ERL_FLAGS）：
      mix maxio.iam.create_key                       # 随机 ak/sk，type=iam_user
      mix maxio.iam.create_key --access-key MYKEY --secret MYSECRET
      mix maxio.iam.create_key --type root           # 额外 root（谨慎）

  打印新建的 access_key_id / secret_key（secret 仅此一次可见）。
  """
  use Mix.Task

  @switches [access_key: :string, secret: :string, type: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    iam_opts =
      []
      |> put_if(:access_key_id, opts[:access_key])
      |> put_if(:secret_key, opts[:secret])
      |> put_if(:type, opts[:type])

    case Maxio.IAM.create_access_key(iam_opts) do
      {:ok, key} ->
        IO.puts("AccessKeyId : #{key.access_key_id}")
        IO.puts("SecretKey   : #{key.secret_key}")
        IO.puts("PrincipalArn: #{key.principal_arn}")
        IO.puts("Type        : #{key.type}")

      {:error, reason} ->
        Mix.raise("create_access_key failed: #{inspect(reason)}")
    end
  end

  defp put_if(kw, _key, nil), do: kw
  defp put_if(kw, key, val), do: Keyword.put(kw, key, val)
end
```

新建 `lib/mix/tasks/maxio.iam.list_keys.ex`：

```elixir
defmodule Mix.Tasks.Maxio.Iam.ListKeys do
  @shortdoc "列出全部 S3 access key（不显示 secret）"
  @moduledoc "列出访问密钥（铁律 4）。用法：mix maxio.iam.list_keys"
  use Mix.Task

  @impl true
  def run(_argv) do
    Mix.Task.run("app.start")

    Maxio.IAM.list_access_keys()
    |> Enum.each(fn k ->
      IO.puts("#{k.access_key_id}\t#{k.type}\t#{k.status}\t#{k.principal_arn}")
    end)
  end
end
```

新建 `lib/mix/tasks/maxio.iam.delete_key.ex`：

```elixir
defmodule Mix.Tasks.Maxio.Iam.DeleteKey do
  @shortdoc "删除一个 S3 access key（拒绝删最后一个 root）"
  @moduledoc "删除访问密钥（铁律 4）。用法：mix maxio.iam.delete_key --access-key MYKEY"
  use Mix.Task

  @switches [access_key: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    ak = opts[:access_key] || Mix.raise("--access-key required")

    case Maxio.IAM.delete_access_key(ak) do
      :ok -> IO.puts("deleted: #{ak}")
      {:error, :cannot_delete_last_root} -> Mix.raise("refusing to delete the last root key")
    end
  end
end
```

### 步骤 8：EctoStore + IAM 单测（用 DataCase，走 test 库）

新建 `test/maxio/iam_test.exs`：

```elixir
defmodule Maxio.IAMTest do
  use Maxio.DataCase, async: true
  alias Maxio.IAM
  alias Maxio.Auth.CredentialStore.EctoStore

  test "bootstrap_root 幂等：重复调用不报错且 root 存在" do
    assert :ok = IAM.bootstrap_root()
    assert :ok = IAM.bootstrap_root()
    s3 = Application.fetch_env!(:maxio, :s3)
    ak = Keyword.fetch!(s3, :root_user)
    assert {:ok, %{secret_key: _, principal: %{type: :root, arn: "arn:aws:iam:::root"}}} = EctoStore.get_secret(ak)
  end

  test "create/list/get/delete access key" do
    {:ok, key} = IAM.create_access_key(access_key_id: "AKIATESTKEY1", secret_key: "topsecret", type: "iam_user")
    assert key.access_key_id == "AKIATESTKEY1"
    assert key.principal_arn == "arn:aws:iam:::user/AKIATESTKEY1"

    assert {:ok, %{secret_key: "topsecret", principal: %{type: :iam_user}}} = EctoStore.get_secret("AKIATESTKEY1")

    assert Enum.any?(IAM.list_access_keys(), &(&1.access_key_id == "AKIATESTKEY1"))

    assert :ok = IAM.delete_access_key("AKIATESTKEY1")
    assert :error = EctoStore.get_secret("AKIATESTKEY1")
  end

  test "inactive 密钥视同不存在" do
    {:ok, _} = IAM.create_access_key(access_key_id: "AKIAINACTIVE", secret_key: "s")
    Repo.update_all(from(a in Maxio.IAM.AccessKey, where: a.access_key_id == "AKIAINACTIVE"), set: [status: "inactive"])
    assert :error = EctoStore.get_secret("AKIAINACTIVE")
  end

  test "拒绝删除最后一个 root" do
    IAM.bootstrap_root()
    s3 = Application.fetch_env!(:maxio, :s3)
    root_ak = Keyword.fetch!(s3, :root_user)
    assert {:error, :cannot_delete_last_root} = IAM.delete_access_key(root_ak)
  end
end
```

> 该测试 `use Maxio.DataCase`（走 Repo sandbox + test 库），直接驱动 EctoStore，与全局 `config :maxio, :credential_store, MemoryStore`（test 默认）无冲突——测试显式调 `EctoStore.get_secret/1`。

### 单元收尾验证（M3-4）

```powershell
mix ecto.migrate
mix test test/maxio/iam_test.exs
mix compile --warnings-as-errors
mix test
```

期望：迁移成功；IAM 测试全绿；编译零警告；全量测试绿（test 仍用 MemoryStore，既有 SigV4 集成测试不受影响）。

CLI 烟测（dev 库，可选活体取证）：

```powershell
mix maxio.iam.list_keys
mix maxio.iam.create_key --access-key AKIADEMO0001 --secret demosecretdemosecret
mix maxio.iam.list_keys
mix maxio.iam.delete_key --access-key AKIADEMO0001
```

期望：list 至少含 root（minioadmin）；create 打印新 key；delete 后 list 不再含。提交：

```powershell
git add -A
git commit -m @'
M3-4: credential persistence — access_keys table + EctoStore (CredentialStore behaviour) + Maxio.IAM lifecycle + root bootstrap + mix maxio.iam.* CLI; test keeps MemoryStore

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) `access_keys` 表/列/索引中文 COMMENT 齐备；(2) EctoStore 实现 behaviour 三回调、principal map 形态与 MemoryStore 一致、inactive 视同不存在；(3) `bootstrap_root` 幂等；(4) 拒绝删最后一个 root；(5) 三 CLI 任务可跑；(6) dev 默认 EctoStore、test 默认 MemoryStore；(7) 零警告、全量绿。

---

## M3-5 · Bucket policy 存储：`Maxio.Policy.Store` behaviour + `bucket_policies` 迁移 + `EctoStore`

**目标**：bucket policy 文档的持久化后端（behaviour 抽象，铁律 1）。存**原始 JSON 文档字节**（GetBucketPolicy 须 round-trip 原样返回），评估时由 `Statement.parse_policy/1` 解析。

**依赖**：M3-3（Statement）。**规模**：behaviour + 迁移 + schema + EctoStore + 单测。

### 步骤 1：迁移 `bucket_policies`

```powershell
mix ecto.gen.migration create_bucket_policies
```

编辑生成文件：

```elixir
defmodule Maxio.Repo.Migrations.CreateBucketPolicies do
  use Ecto.Migration

  def change do
    create table(:bucket_policies,
             primary_key: false,
             comment: "S3 桶策略：每桶至多一行；存原始 JSON 文档（GetBucketPolicy 原样回放），授权时解析为 statement"
           ) do
      add :id, :binary_id, primary_key: true, comment: "桶策略主键（UUID）"

      add :bucket_name, :string,
        null: false,
        comment: "所属桶名（与 buckets.name 对应；每桶唯一一条 policy）"

      add :document, :map,
        null: false,
        comment: "策略 JSON 文档（jsonb；PutBucketPolicy 原样存，GetBucketPolicy 原样回放，铁律 5 round-trip）"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:bucket_policies, [:bucket_name],
             comment: "桶名唯一索引（每桶至多一条 policy；PutBucketPolicy 走 upsert 覆盖）"
           )
  end
end
```

> **存储选型说明**：`document` 用 `:map`（Postgres `jsonb`）。PutBucketPolicy 入站是 JSON 字节，先 `Jason.decode/1` 校验 + `Statement.parse_policy/1` 语义校验（不通过 → MalformedPolicy），通过后把**解析出的 map** 存入 jsonb。GetBucketPolicy 取回 map → `Jason.encode!/1` 回放为 JSON 字节。这样 round-trip 是「语义等价 JSON」（键序可能变，但 S3 客户端按结构解析，不依赖字节序——与 AWS jsonb 化行为一致）。

应用并核验：

```powershell
mix ecto.migrate
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ bucket_policies"
```

### 步骤 2：schema `Maxio.Policy.BucketPolicy`

新建 `lib/maxio/policy/bucket_policy.ex`：

```elixir
defmodule Maxio.Policy.BucketPolicy do
  @moduledoc "S3 桶策略 schema：每桶至多一条，document 为解析校验后的策略 JSON（jsonb map）。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "bucket_policies" do
    field :bucket_name, :string
    field :document, :map

    timestamps(type: :utc_datetime_usec)
  end

  @required [:bucket_name, :document]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(bp, attrs) do
    bp
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> unique_constraint(:bucket_name, name: :bucket_policies_bucket_name_index)
  end
end
```

### 步骤 3：behaviour `Maxio.Policy.Store`

新建 `lib/maxio/policy/store.ex`：

```elixir
defmodule Maxio.Policy.Store do
  @moduledoc """
  策略存储 behaviour（铁律 1）。bucket policy 持久化经此抽象；门面按
  config :maxio, :policy_store 派发。MVP 提供 EctoStore（Postgres jsonb）。
  principal_policies/1（IAM identity policy）MVP 恒 []（defer，见计划）。
  """
  alias Maxio.Policy.Statement

  @callback get_bucket_policy(bucket :: String.t()) :: {:ok, binary()} | :none
  @callback put_bucket_policy(bucket :: String.t(), json :: binary()) :: :ok | {:error, term()}
  @callback delete_bucket_policy(bucket :: String.t()) :: :ok
  @callback principal_policies(principal :: map() | :anonymous) :: [Statement.t()]

  @doc "当前配置的策略后端模块。"
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:maxio, :policy_store)

  @spec get_bucket_policy(String.t()) :: {:ok, binary()} | :none
  def get_bucket_policy(bucket), do: impl().get_bucket_policy(bucket)

  @spec put_bucket_policy(String.t(), binary()) :: :ok | {:error, term()}
  def put_bucket_policy(bucket, json), do: impl().put_bucket_policy(bucket, json)

  @spec delete_bucket_policy(String.t()) :: :ok
  def delete_bucket_policy(bucket), do: impl().delete_bucket_policy(bucket)

  @spec principal_policies(map() | :anonymous) :: [Statement.t()]
  def principal_policies(principal), do: impl().principal_policies(principal)

  @doc """
  便捷：取桶策略并解析为 [Statement]。无 policy → []；解析失败（理论上不该发生，
  因 Put 时已校验）→ [] 且打 warning（绝不静默 crash 授权链）。
  """
  @spec statements_for_bucket(String.t()) :: [Statement.t()]
  def statements_for_bucket(bucket) do
    case get_bucket_policy(bucket) do
      {:ok, json} ->
        case Statement.parse_policy(json) do
          {:ok, stmts} ->
            stmts

          {:error, _} ->
            require Logger
            Logger.warning("stored bucket policy failed to parse", bucket: bucket)
            []
        end

      :none ->
        []
    end
  end
end
```

### 步骤 4：`Maxio.Policy.Store.EctoStore`

新建 `lib/maxio/policy/store/ecto_store.ex`：

```elixir
defmodule Maxio.Policy.Store.EctoStore do
  @moduledoc """
  Postgres 策略后端（实现 Maxio.Policy.Store behaviour）。document 存 jsonb（解析后的 map），
  get 时 Jason.encode! 回放为 JSON 字节（round-trip 语义等价）。principal_policies MVP 恒 []（defer）。
  """
  @behaviour Maxio.Policy.Store

  alias Maxio.Repo
  alias Maxio.Policy.BucketPolicy

  @impl true
  def get_bucket_policy(bucket) do
    case Repo.get_by(BucketPolicy, bucket_name: bucket) do
      nil -> :none
      %BucketPolicy{document: doc} -> {:ok, Jason.encode!(doc)}
    end
  end

  @impl true
  def put_bucket_policy(bucket, json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = doc} ->
        %BucketPolicy{}
        |> BucketPolicy.changeset(%{bucket_name: bucket, document: doc})
        |> Repo.insert(
          on_conflict: {:replace, [:document, :updated_at]},
          conflict_target: :bucket_name
        )
        |> case do
          {:ok, _} -> :ok
          {:error, cs} -> {:error, cs}
        end

      _ ->
        {:error, :malformed}
    end
  end

  @impl true
  def delete_bucket_policy(bucket) do
    import Ecto.Query
    Repo.delete_all(from p in BucketPolicy, where: p.bucket_name == ^bucket)
    :ok
  end

  @impl true
  def principal_policies(_principal), do: []
end
```

### 步骤 5：config 注册策略后端

编辑 `config/config.exs`，在凭据后端绑定附近加：

```elixir
config :maxio, :policy_store, Maxio.Policy.Store.EctoStore
```

> test 也用 EctoStore（bucket policy 测试需要持久化；走 DataCase sandbox）——无需在 test.exs 覆盖。

### 步骤 6：单测 `test/maxio/policy/store_test.exs`

```elixir
defmodule Maxio.Policy.StoreTest do
  use Maxio.DataCase, async: true
  alias Maxio.Policy.Store

  @policy ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}]})

  test "put → get round-trip（语义等价）" do
    assert :ok = Store.put_bucket_policy("b", @policy)
    assert {:ok, json} = Store.get_bucket_policy("b")
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["Statement"] |> hd() |> Map.get("Effect") == "Allow"
  end

  test "无 policy → :none / []" do
    assert :none = Store.get_bucket_policy("nope")
    assert [] = Store.statements_for_bucket("nope")
  end

  test "statements_for_bucket 解析为 Statement 列表" do
    Store.put_bucket_policy("b2", @policy)
    assert [%Maxio.Policy.Statement{effect: :allow}] = Store.statements_for_bucket("b2")
  end

  test "put 覆盖（upsert）" do
    Store.put_bucket_policy("b3", @policy)
    deny = ~s({"Statement":{"Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::b3","arn:aws:s3:::b3/*"]}})
    assert :ok = Store.put_bucket_policy("b3", deny)
    assert [%{effect: :deny}] = Store.statements_for_bucket("b3")
  end

  test "delete 幂等" do
    Store.put_bucket_policy("b4", @policy)
    assert :ok = Store.delete_bucket_policy("b4")
    assert :none = Store.get_bucket_policy("b4")
    assert :ok = Store.delete_bucket_policy("b4")
  end

  test "principal_policies MVP 恒 []" do
    assert [] = Store.principal_policies(:anonymous)
    assert [] = Store.principal_policies(%{type: :root})
  end
end
```

### 单元收尾验证（M3-5）

```powershell
mix ecto.migrate
mix test test/maxio/policy/store_test.exs
mix compile --warnings-as-errors
mix test
```

期望：迁移成功；store 测试全绿；编译零警告；全量绿。提交：

```powershell
git add -A
git commit -m @'
M3-5: bucket policy storage — Policy.Store behaviour + bucket_policies (jsonb) migration + EctoStore + statements_for_bucket helper

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) `bucket_policies` 表/列/索引中文 COMMENT；(2) put/get round-trip 语义等价、upsert 覆盖、delete 幂等、无 policy → :none/[]；(3) `statements_for_bucket` 返回 Statement 列表；(4) `principal_policies` 恒 []；(5) 零警告、全量绿。

---

## M3-6 · Bucket Policy API：Put/Get/DeleteBucketPolicy + Dispatcher 升级 + 新错误码 + e2e

**目标**：`?policy` 子资源三动作（JSON body）。Put 校验 → MalformedPolicy；Get 原样回放 JSON（404 NoSuchBucketPolicy）；Delete 幂等 204。`Dispatcher` 从 `:not_implemented` 升级为真实分发。

**依赖**：M3-5。**规模**：错误码 + Dispatcher 改 + handler 模块 + handlers facade 接线 + e2e。

### 步骤 1：新增错误码（`lib/maxio/s3/error.ex`）

在 `@table` map 内追加两条（放在 `incomplete_body` 之后，注意前一条要补逗号）：

```elixir
    incomplete_body:
      {"IncompleteBody", 400,
       "You did not provide the number of bytes specified by the Content-Length HTTP header."},
    malformed_policy:
      {"MalformedPolicy", 400, "Policies must be valid JSON and the first byte must be '{'."},
    no_such_bucket_policy:
      {"NoSuchBucketPolicy", 404, "The bucket policy does not exist."}
```

### 步骤 2：Dispatcher 升级（`lib/maxio/s3/dispatcher.ex`）

(a) 从 `@m2_subresources` 列表中**移除** `policy`（否则会 fall through 到 `:not_implemented`）：

```elixir
  @m2_subresources ~w(acl tagging versioning cors lifecycle website
                      versions notification replication encryption object-lock legal-hold retention
                      attributes select torrent restore accelerate analytics inventory metrics
                      ownershipcontrols publicaccessblock requestpayment logging)
```

(b) 在 `resolve/3` 的 `cond` 中、**在 `m2_subresource?` 之前**插入 policy 分支：

```elixir
  def resolve(level, method, query_keys) do
    cond do
      multipart_action(level, method, query_keys) != nil ->
        {:ok, multipart_action(level, method, query_keys)}

      level == :bucket and method == "POST" and MapSet.member?(query_keys, "delete") ->
        {:ok, :delete_objects}

      level == :bucket and MapSet.member?(query_keys, "policy") ->
        case method do
          "PUT" -> {:ok, :put_bucket_policy}
          "GET" -> {:ok, :get_bucket_policy}
          "DELETE" -> {:ok, :delete_bucket_policy}
          _ -> {:error, :method_not_allowed}
        end

      m2_subresource?(query_keys) ->
        {:error, :not_implemented}

      level == :bucket and method == "GET" and MapSet.member?(query_keys, "location") ->
        {:ok, :get_bucket_location}

      true ->
        dispatch(level, method)
    end
  end
```

### 步骤 3：handler 模块 `Maxio.S3.Handlers.BucketPolicy`

新建 `lib/maxio/s3/handlers/bucket_policy.ex`：

```elixir
defmodule Maxio.S3.Handlers.BucketPolicy do
  @moduledoc """
  ?policy 子资源 handler：PutBucketPolicy（JSON body → 校验 → 存，204）、
  GetBucketPolicy（200 application/json 原样回放，无则 404 NoSuchBucketPolicy）、
  DeleteBucketPolicy（204，幂等）。JSON body 走带上限整读（铁律 4：小文档不进 Plug.Parsers）。
  """
  import Plug.Conn
  alias Maxio.{Buckets}
  alias Maxio.Policy.{Statement, Store}
  alias Maxio.S3.{Error, Log}

  @policy_limit 1_048_576

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, json} = read_small_body!(conn)

    # 语义校验：JSON 合法 + 策略结构合法（Version/Effect/Action/Resource/Principal）。
    case Statement.parse_policy(json) do
      {:ok, _stmts} ->
        case Store.put_bucket_policy(bucket, json) do
          :ok ->
            Log.info("put bucket policy", action: :put_bucket_policy, bucket: bucket)
            send_resp(conn, 204, "")

          {:error, _} ->
            raise Error.new(:malformed_policy, resource: "/" <> bucket)
        end

      {:error, :malformed} ->
        Log.warn("malformed bucket policy", action: :put_bucket_policy, bucket: bucket, reason: :malformed_policy)
        raise Error.new(:malformed_policy, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)

    case Store.get_bucket_policy(bucket) do
      {:ok, json} ->
        Log.info("get bucket policy", action: :get_bucket_policy, bucket: bucket)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, json)

      :none ->
        raise Error.new(:no_such_bucket_policy, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = Store.delete_bucket_policy(bucket)
    Log.info("delete bucket policy", action: :delete_bucket_policy, bucket: bucket)
    send_resp(conn, 204, "")
  end

  # ── helpers ──
  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  # 小 JSON 整读（带上限，铁律 4）。
  defp read_small_body!(conn) do
    case read_body(conn, length: @policy_limit, read_length: @policy_limit) do
      {:ok, body, conn} -> {conn, body}
      {:more, _partial, _conn} -> raise Error.new(:entity_too_large, message: "Policy document too large")
      {:error, _} -> raise Error.new(:malformed_policy)
    end
  end
end
```

### 步骤 4：handlers facade 接线（`lib/maxio/s3/handlers.ex`）

(a) 在 `alias` 行加 `BucketPolicy`：

```elixir
  alias Maxio.S3.Handlers.{Service, Bucket, Object, Multipart, BucketPolicy}
```

(b) 在 dispatch 子句末尾加三条：

```elixir
  def dispatch(:put_bucket_policy, conn), do: BucketPolicy.put(conn)
  def dispatch(:get_bucket_policy, conn), do: BucketPolicy.get(conn)
  def dispatch(:delete_bucket_policy, conn), do: BucketPolicy.delete(conn)
```

### 步骤 5：扩展 `SigV4Request` 支持 JSON body + 自定义 content-type（已支持）

`signed_conn/3` 已支持 `:body` 与 `:headers`（content-type）。PutBucketPolicy 测试用 `body: json, headers: [{"content-type","application/json"}]` 即可——签名对 body 算 `x-amz-content-sha256`，与现有 PutObject 路径一致。无需改 support。

### 步骤 6：e2e `test/maxio/s3/bucket_policy_test.exs`

```elixir
defmodule Maxio.S3.BucketPolicyTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_policy_test")
  @policy ~s({"Version":"2012-10-17","Statement":[{"Sid":"P","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::pb/*"}]})

  setup do
    File.rm_rf(@data_dir); File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn -> Application.put_env(:maxio, :s3, prev); File.rm_rf(@data_dir) end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "PutBucketPolicy 204 → GetBucketPolicy 200 JSON → DeleteBucketPolicy 204" do
    SigV4Request.signed_conn(:put, "/pb") |> call()

    put =
      SigV4Request.signed_conn(:put, "/pb",
        query: %{"policy" => ""},
        body: @policy,
        headers: [{"content-type", "application/json"}]
      )
      |> call()

    assert put.status == 204

    get = SigV4Request.signed_conn(:get, "/pb", query: %{"policy" => ""}) |> call()
    assert get.status == 200
    assert get_resp_header(get, "content-type") |> hd() =~ "application/json"
    assert {:ok, doc} = Jason.decode(get.resp_body)
    assert doc["Statement"] |> hd() |> Map.get("Effect") == "Allow"

    del = SigV4Request.signed_conn(:delete, "/pb", query: %{"policy" => ""}) |> call()
    assert del.status == 204

    get2 = SigV4Request.signed_conn(:get, "/pb", query: %{"policy" => ""}) |> call()
    assert get2.status == 404
    assert get2.resp_body =~ "NoSuchBucketPolicy"
  end

  test "GetBucketPolicy 无 policy → 404 NoSuchBucketPolicy" do
    SigV4Request.signed_conn(:put, "/pb2") |> call()
    get = SigV4Request.signed_conn(:get, "/pb2", query: %{"policy" => ""}) |> call()
    assert get.status == 404
    assert get.resp_body =~ "NoSuchBucketPolicy"
  end

  test "PutBucketPolicy 畸形 JSON → 400 MalformedPolicy" do
    SigV4Request.signed_conn(:put, "/pb3") |> call()

    put =
      SigV4Request.signed_conn(:put, "/pb3",
        query: %{"policy" => ""},
        body: "not json",
        headers: [{"content-type", "application/json"}]
      )
      |> call()

    assert put.status == 400
    assert put.resp_body =~ "MalformedPolicy"
  end

  test "DeleteBucketPolicy 无 policy 也 204（幂等）" do
    SigV4Request.signed_conn(:put, "/pb4") |> call()
    del = SigV4Request.signed_conn(:delete, "/pb4", query: %{"policy" => ""}) |> call()
    assert del.status == 204
  end
end
```

> 注意：这些测试在 M3-8 接入 Authz 之前跑，principal 为 root（SigV4Request 用 root key），root 短路放行——故纯走 handler 逻辑。M3-8 接入 Authz 后，root owner 仍放行，这些用例继续绿（PutBucketPolicy/GetBucketPolicy/DeleteBucketPolicy 的 owner=root）。

### 单元收尾验证（M3-6）

```powershell
mix test test/maxio/s3/bucket_policy_test.exs
mix compile --warnings-as-errors
mix test
```

期望：policy e2e 全绿；编译零警告；全量绿。提交：

```powershell
git add -A
git commit -m @'
M3-6: Bucket Policy API — Put/Get/DeleteBucketPolicy (?policy, JSON body, MalformedPolicy/NoSuchBucketPolicy); Dispatcher upgrade from not_implemented

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) Put 204 + Get 200 `application/json` round-trip + Delete 204；(2) Get 无 policy → 404 NoSuchBucketPolicy；(3) Put 畸形 → 400 MalformedPolicy；(4) Delete 幂等 204；(5) Dispatcher 不再把 `policy` 当 `:not_implemented`；(6) 零警告、全量绿。

---

## M3-7 · Canned ACL：存储 + `Maxio.Policy.ACL` 折叠 + Put/Get Bucket/Object ACL XML + Dispatcher

**目标**：`x-amz-acl` 于 CreateBucket/PutObject 存为元数据；`Put/GetBucketAcl` + `Put/GetObjectAcl`（`?acl`）`AccessControlPolicy` XML 出入站；canned ACL → 等价 allow statement，**折叠进 M3-3 的同一个 Evaluator**（不另起 ACL 评估路径，铁律 2）。

**依赖**：M3-5（Statement）。**规模**：迁移（加 acl 列）+ ACL 折叠模块 + view + request parser + handler + Dispatcher + 元数据存储接线 + 单测。

### MVP 范围（官方核验，§RESEARCH bake-in）

实现 canned：`private`（默认）、`public-read`、`public-read-write`、`authenticated-read`。`x-amz-acl` 头于 CreateBucket/PutObject/PutBucketAcl/PutObjectAcl。GetBucketAcl/GetObjectAcl 返回展开后 XML（含 `<?xml?>` prolog + root `xmlns` + `xsi:type` 属性形式）。组 grantee：AllUsers / AuthenticatedUsers + owner CanonicalUser。

**defer（存名不评估或拒绝，文档化）**：`bucket-owner-read`/`bucket-owner-full-control`（单租户按 private 评估）、`aws-exec-read`/`log-delivery-write`（存名不评估）、`x-amz-grant-*` 头细粒度评估、email grantee（→ 400 InvalidArgument）、自定义 canonical-user 细粒度授权。

### 步骤 1：迁移给 buckets/objects 加 acl 列

```powershell
mix ecto.gen.migration add_acl_to_buckets_and_objects
```

编辑生成文件：

```elixir
defmodule Maxio.Repo.Migrations.AddAclToBucketsAndObjects do
  use Ecto.Migration

  def change do
    alter table(:buckets) do
      add :acl_canned, :string,
        null: false,
        default: "private",
        comment: "桶的 canned ACL 名（private|public-read|public-read-write|authenticated-read 等；GetBucketAcl 展开为 grant XML，授权时折叠为等价 statement）"
    end

    alter table(:objects) do
      add :acl_canned, :string,
        null: false,
        default: "private",
        comment: "对象的 canned ACL 名（默认 private；PutObject 的 x-amz-acl 写入；授权时折叠为等价 statement）"
    end
  end
end
```

应用并核验：

```powershell
mix ecto.migrate
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ buckets"
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ objects"
```

### 步骤 2：schema 加 `acl_canned` 字段

`lib/maxio/buckets/bucket.ex`：schema 内加 `field :acl_canned, :string, default: "private"`；`@optional` 加 `:acl_canned`。

`lib/maxio/objects/object.ex`：schema 内加 `field :acl_canned, :string, default: "private"`；`@optional` 加 `:acl_canned`。

`lib/maxio/objects.ex` `put_metadata/3` 的 `base` map 加 `acl_canned: Map.get(attrs, :acl_canned, "private")`，并把 `on_conflict` 的 `:replace` 列表加 `:acl_canned`：

```elixir
      base = %{
        bucket_id: bucket.id,
        bucket_name: bucket_name,
        key: key,
        size: Map.fetch!(attrs, :size),
        etag: Map.fetch!(attrs, :etag),
        content_type: Map.get(attrs, :content_type, "binary/octet-stream"),
        metadata: Map.get(attrs, :metadata, %{}),
        storage_class: Map.get(attrs, :storage_class, "STANDARD"),
        acl_canned: Map.get(attrs, :acl_canned, "private")
      }

      %Object{}
      |> Object.changeset(base)
      |> Repo.insert(
        on_conflict:
          {:replace, [:size, :etag, :content_type, :metadata, :storage_class, :acl_canned, :updated_at]},
        conflict_target: [:bucket_id, :key]
      )
```

`lib/maxio/buckets.ex` `create/3`：把 `acl_canned` 经 opts 传入 attrs（CreateBucket 的 `x-amz-acl`）：

```elixir
  def create(name, owner, opts \\ []) do
    region = Keyword.get(opts, :region, default_region())
    acl = Keyword.get(opts, :acl_canned, "private")

    with :ok <- validate_name(name) do
      attrs = %{name: name, owner: owner, region: region, acl_canned: acl}
      # ...（其余不变）
```

并新增一个更新桶 ACL 的便捷函数（PutBucketAcl 用）：

```elixir
  @doc "更新桶的 canned ACL（PutBucketAcl）。桶不存在 → :not_found。"
  @spec put_acl(String.t(), String.t()) :: :ok | {:error, :not_found}
  def put_acl(name, canned) do
    case lookup(name) do
      {:ok, bucket} ->
        bucket |> Bucket.changeset(%{acl_canned: canned}) |> Repo.update!()
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
```

`lib/maxio/objects.ex` 新增更新对象 ACL 便捷函数（PutObjectAcl 用）：

```elixir
  @doc "更新对象的 canned ACL（PutObjectAcl）。对象不存在 → :not_found。"
  @spec put_acl(String.t(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def put_acl(bucket_name, key, canned) do
    case get_metadata(bucket_name, key) do
      {:ok, obj} ->
        obj |> Object.changeset(%{acl_canned: canned}) |> Repo.update!()
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
```

### 步骤 3：`Maxio.Policy.ACL`（canned → statement 折叠 + XML 互转）

新建 `lib/maxio/policy/acl.ex`：

```elixir
defmodule Maxio.Policy.ACL do
  @moduledoc """
  Canned ACL ↔ 等价策略 statement 折叠（铁律 2：ACL 与 policy 共用同一个 Evaluator，不另起评估路径）
  + AccessControlPolicy XML 出入站（委托 view / request parser）。

  官方核验（§RESEARCH bake-in）映射：
    AllUsers 组          → principal "*"（匿名+认证均匹配）
    AuthenticatedUsers 组 → 任意认证 principal（本系统：principal "*" 但要求 authenticated?；
                            MVP 用 {:authenticated} 哨兵 statement，由 Authz 在构造 ctx 前过滤）
  ACL permission → S3 action（对象/桶分别）：
    READ(对象)  → s3:GetObject(+Version)        READ(桶)  → s3:ListBucket(+Versions,+MultipartUploads)
    WRITE(桶)   → s3:PutObject                  READ_ACP  → s3:Get{Bucket,Object}Acl
    WRITE_ACP   → s3:Put{Bucket,Object}Acl
  Owner FULL_CONTROL 隐含——本系统 owner 由 Evaluator owner? 短路处理，故 canned 只产生“公共/组”授权 statement。

  支持 canned：private / public-read / public-read-write / authenticated-read。
  其余 canned（bucket-owner-*/aws-exec-read/log-delivery-write）→ 存名不产生公共 statement（按 private 评估，文档化）。
  """
  alias Maxio.Policy.{Arn, Statement}

  @public_canned ~w(public-read public-read-write authenticated-read)

  @doc "已知/受支持的 canned 名（用于校验 x-amz-acl）。"
  @spec known?(String.t()) :: boolean()
  def known?(canned) do
    canned in ~w(private public-read public-read-write authenticated-read
                 bucket-owner-read bucket-owner-full-control aws-exec-read log-delivery-write)
  end

  @doc """
  canned ACL → 等价 [Statement]（折叠进 Evaluator）。
  level=:bucket → resource=桶 ARN；level=:object → resource=对象 ARN（key 必给）。
  private 与未支持 canned → []（仅 owner 短路，无公共授权）。
  """
  @spec canned_to_statements(String.t(), :bucket | :object, String.t(), String.t() | nil) ::
          [Statement.t()]
  def canned_to_statements(canned, _level, _bucket, _key) when canned not in @public_canned, do: []

  def canned_to_statements("public-read", :object, bucket, key) do
    [allow_stmt(:any, ["s3:GetObject", "s3:GetObjectVersion"], [Arn.object_arn(bucket, key)])]
  end

  def canned_to_statements("public-read", :bucket, bucket, _key) do
    [allow_stmt(:any, bucket_read_actions(), [Arn.bucket_arn(bucket)])]
  end

  def canned_to_statements("public-read-write", :object, bucket, key) do
    [
      allow_stmt(:any, ["s3:GetObject", "s3:GetObjectVersion"], [Arn.object_arn(bucket, key)]),
      allow_stmt(:any, ["s3:PutObject"], [Arn.object_arn(bucket, key)])
    ]
  end

  def canned_to_statements("public-read-write", :bucket, bucket, _key) do
    [
      allow_stmt(:any, bucket_read_actions(), [Arn.bucket_arn(bucket)]),
      allow_stmt(:any, ["s3:PutObject"], [Arn.bucket_arn(bucket) <> "/*"])
    ]
  end

  # authenticated-read：仅认证 principal。用 :authenticated 哨兵 principal，
  # Authz 构造 ctx 时若 authenticated?==false 则丢弃这些 statement（详见 M3-8 注释）。
  def canned_to_statements("authenticated-read", :object, bucket, key) do
    [allow_stmt(:authenticated, ["s3:GetObject", "s3:GetObjectVersion"], [Arn.object_arn(bucket, key)])]
  end

  def canned_to_statements("authenticated-read", :bucket, bucket, _key) do
    [allow_stmt(:authenticated, bucket_read_actions(), [Arn.bucket_arn(bucket)])]
  end

  defp bucket_read_actions, do: ["s3:ListBucket", "s3:ListBucketVersions", "s3:ListBucketMultipartUploads"]

  # principal=:any → :any；principal=:authenticated → 用 {:aws,["*AUTHENTICATED*"]} 不可行，
  # 改为在 Statement 增设特殊标记不优雅；本 MVP 用 principals=:any 但在 conditions 里塞一个
  # 仅 Authz 识别的内部条件键 "maxio:Authenticated"=="true"，Authz 构造 ctx 时填该键。
  defp allow_stmt(:authenticated, actions, resources) do
    %Statement{
      effect: :allow,
      actions: actions,
      resources: resources,
      principals: :any,
      conditions: %{"StringEquals" => %{"maxio:Authenticated" => "true"}}
    }
  end

  defp allow_stmt(:any, actions, resources) do
    %Statement{effect: :allow, actions: actions, resources: resources, principals: :any, conditions: %{}}
  end
end
```

> **`authenticated-read` 折叠技巧（文档化）**：AuthenticatedUsers 与 AllUsers 唯一差别是「是否要求请求已认证」。本 MVP 用内部条件键 `"maxio:Authenticated"`（值 `"true"`）表达——Authz 构造 `RequestContext` 时把 `authenticated?` 布尔写入 `conditions["maxio:Authenticated"]`（`"true"`/`"false"`），`Condition.hold?` 的 `StringEquals` 即可正确区分。该键以 `maxio:` 前缀命名，绝不与真实 AWS 条件键冲突。`Maxio.Policy.Condition` 的 `StringEquals` 已能处理（缺键→false→匿名不命中 authenticated-read，正确）。

### 步骤 4：出站 view `Maxio.S3.Views.AccessControlPolicy`

新建 `lib/maxio/s3/views/access_control_policy.ex`：

```elixir
defmodule Maxio.S3.Views.AccessControlPolicy do
  @moduledoc """
  GetBucketAcl / GetObjectAcl 响应 XML（AccessControlPolicy）。
  对齐官方（§RESEARCH bake-in）：prolog + root xmlns；grantee 用 xsi:type 属性形式
  （xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"）；canned 名展开为具体 Grant。
  owner_id 为资源所有者 canonical user id（本系统用 "maxio" 合成 id）。
  """
  import Saxy.XML
  alias Maxio.S3.XML

  @all_users "http://acs.amazonaws.com/groups/global/AllUsers"
  @auth_users "http://acs.amazonaws.com/groups/global/AuthenticatedUsers"
  @xsi "http://www.w3.org/2001/XMLSchema-instance"

  @doc """
  render(%{canned, owner_id, owner_display}) :: iodata()
  把 canned 名展开为 owner FULL_CONTROL + 公共/组 grant。
  """
  @spec render(%{canned: String.t(), owner_id: String.t(), owner_display: String.t()}) :: iodata()
  def render(%{canned: canned, owner_id: owner_id, owner_display: owner_display}) do
    grants = [owner_full_control(owner_id, owner_display) | extra_grants(canned)]

    root =
      element("AccessControlPolicy", [{"xmlns", XML.namespace()}], [
        element("Owner", [], [
          element("ID", [], characters(owner_id)),
          element("DisplayName", [], characters(owner_display))
        ]),
        element("AccessControlList", [], grants)
      ])

    XML.encode(root)
  end

  defp owner_full_control(id, display) do
    element("Grant", [], [
      element("Grantee", [{"xmlns:xsi", @xsi}, {"xsi:type", "CanonicalUser"}], [
        element("ID", [], characters(id)),
        element("DisplayName", [], characters(display))
      ]),
      element("Permission", [], characters("FULL_CONTROL"))
    ])
  end

  defp extra_grants("public-read"), do: [group_grant(@all_users, "READ")]

  defp extra_grants("public-read-write"),
    do: [group_grant(@all_users, "READ"), group_grant(@all_users, "WRITE")]

  defp extra_grants("authenticated-read"), do: [group_grant(@auth_users, "READ")]
  defp extra_grants(_private_or_other), do: []

  defp group_grant(uri, permission) do
    element("Grant", [], [
      element("Grantee", [{"xmlns:xsi", @xsi}, {"xsi:type", "Group"}], [
        element("URI", [], characters(uri))
      ]),
      element("Permission", [], characters(permission))
    ])
  end
end
```

### 步骤 5：入站 request parser `Maxio.S3.RequestParsers.AccessControlPolicy`

新建 `lib/maxio/s3/request_parsers/access_control_policy.ex`：

```elixir
defmodule Maxio.S3.RequestParsers.AccessControlPolicy do
  @moduledoc """
  PutBucketAcl/PutObjectAcl 的 XML body 解析（saxy SAX）。MVP 把显式 grant XML 映射回最接近的
  canned 名（owner-only→private；AllUsers READ→public-read；AllUsers READ+WRITE→public-read-write；
  AuthenticatedUsers READ→authenticated-read）。容忍 xmlns="" 重置与 <Type> 元素变体（只读不产出）。
  无法识别的精细组合 → 退化为 private（保守，不静默放行更多权限）。
  返回 {:ok, canned :: String.t()} | {:error, :malformed_xml}。
  """
  @behaviour Saxy.Handler

  @all_users "http://acs.amazonaws.com/groups/global/AllUsers"
  @auth_users "http://acs.amazonaws.com/groups/global/AuthenticatedUsers"

  @spec parse(binary()) :: {:ok, String.t()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{grants: [], cur_uri: nil, cur_perm: nil, in: nil, text: nil}

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{grants: grants}} -> {:ok, classify(grants)}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _p, s), do: {:ok, s}

  @impl true
  def handle_event(:start_element, {name, _attrs}, s) do
    case local(name) do
      "Grant" -> {:ok, %{s | cur_uri: nil, cur_perm: nil, in: nil}}
      "URI" -> {:ok, %{s | in: :uri, text: ""}}
      "Permission" -> {:ok, %{s | in: :perm, text: ""}}
      _ -> {:ok, %{s | in: nil}}
    end
  end

  @impl true
  def handle_event(:characters, _c, %{in: nil} = s), do: {:ok, s}

  def handle_event(:characters, c, %{text: t} = s) when is_binary(t),
    do: {:ok, %{s | text: t <> c}}

  def handle_event(:characters, _c, s), do: {:ok, s}

  @impl true
  def handle_event(:end_element, name, s) do
    case local(name) do
      "URI" -> {:ok, %{s | cur_uri: String.trim(s.text || ""), in: nil, text: nil}}
      "Permission" -> {:ok, %{s | cur_perm: String.trim(s.text || ""), in: nil, text: nil}}
      "Grant" -> {:ok, %{s | grants: [{s.cur_uri, s.cur_perm} | s.grants], in: nil}}
      _ -> {:ok, %{s | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _d, s), do: {:ok, s}

  # 把抓到的 (uri, perm) 组 grant 分类回 canned。仅看组 grantee（CanonicalUser owner grant 忽略）。
  defp classify(grants) do
    group_perms =
      grants
      |> Enum.filter(fn {uri, _p} -> uri in [@all_users, @auth_users] end)
      |> Enum.map(fn {uri, p} -> {uri, String.upcase(to_string(p))} end)
      |> MapSet.new()

    cond do
      MapSet.member?(group_perms, {@all_users, "WRITE"}) and MapSet.member?(group_perms, {@all_users, "READ"}) ->
        "public-read-write"

      MapSet.member?(group_perms, {@all_users, "READ"}) ->
        "public-read"

      MapSet.member?(group_perms, {@auth_users, "READ"}) ->
        "authenticated-read"

      true ->
        "private"
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

### 步骤 6：handler `Maxio.S3.Handlers.Acl`

新建 `lib/maxio/s3/handlers/acl.ex`：

```elixir
defmodule Maxio.S3.Handlers.Acl do
  @moduledoc """
  ?acl 子资源 handler：GetBucketAcl/PutBucketAcl/GetObjectAcl/PutObjectAcl。
  Get → AccessControlPolicy XML（canned 展开）。Put → 接受 x-amz-acl 头或 XML body（互斥），
  归一化为 canned 名存元数据。email grantee → 400 InvalidArgument（defer）。
  """
  import Plug.Conn
  alias Maxio.{Buckets, Objects}
  alias Maxio.Policy.ACL
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.Views.AccessControlPolicy, as: AclView
  alias Maxio.S3.RequestParsers.AccessControlPolicy, as: AclParser

  @owner_id "maxio"
  @owner_display "maxio"
  @acl_limit 1_048_576

  @spec get_bucket_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def get_bucket_acl(conn) do
    bucket = conn.assigns.s3_bucket
    b = ensure_bucket!(bucket)
    render_acl(conn, b.acl_canned)
  end

  @spec put_bucket_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def put_bucket_acl(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, canned} = resolve_canned!(conn)
    :ok = Buckets.put_acl(bucket, canned)
    Log.info("put bucket acl", action: :put_bucket_acl, bucket: bucket, reason: canned)
    send_resp(conn, 200, "")
  end

  @spec get_object_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def get_object_acl(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)

    case Objects.get_metadata(bucket, key) do
      {:ok, obj} -> render_acl(conn, obj.acl_canned)
      {:error, :not_found} -> raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  @spec put_object_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def put_object_acl(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)
    {conn, canned} = resolve_canned!(conn)

    case Objects.put_acl(bucket, key, canned) do
      :ok ->
        Log.info("put object acl", action: :put_object_acl, bucket: bucket, key: key, reason: canned)
        send_resp(conn, 200, "")

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  # ── helpers ──
  defp render_acl(conn, canned) do
    body = AclView.render(%{canned: canned, owner_id: @owner_id, owner_display: @owner_display})

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  # 归一化 ACL 输入为 canned 名。x-amz-acl 头与 XML body 互斥（官方）。
  # 头优先；无头则读 XML body 分类；email grantee → 400。
  defp resolve_canned!(conn) do
    header_acl = header(conn, "x-amz-acl")

    cond do
      is_binary(header_acl) ->
        unless ACL.known?(header_acl) do
          raise Error.new(:invalid_argument, message: "Unsupported x-amz-acl: #{header_acl}")
        end

        {conn, header_acl}

      grant_headers?(conn) ->
        # x-amz-grant-* 头细粒度评估 defer：接受但退化为 private（不静默放行更多权限）。
        Log.warn("x-amz-grant-* headers not fully evaluated; treated as private", action: :put_acl)
        {conn, "private"}

      true ->
        {conn, xml} = read_small_body!(conn)
        if xml =~ "AmazonCustomerByEmail" or xml =~ "EmailAddress" do
          raise Error.new(:invalid_argument, message: "Email grantee ACLs are not supported")
        end

        case AclParser.parse(xml) do
          {:ok, canned} -> {conn, canned}
          {:error, :malformed_xml} -> raise Error.new(:malformed_xml)
        end
    end
  end

  defp grant_headers?(conn) do
    Enum.any?(conn.req_headers, fn {k, _} -> String.starts_with?(String.downcase(k), "x-amz-grant-") end)
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @acl_limit, read_length: @acl_limit) do
      {:ok, body, conn} -> {conn, body}
      {:more, _partial, _conn} -> raise Error.new(:entity_too_large, message: "ACL document too large")
      {:error, _} -> raise Error.new(:malformed_xml)
    end
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()
end
```

### 步骤 7：Dispatcher 升级 `?acl`

(a) 从 `@m2_subresources` 移除 `acl`：

```elixir
  @m2_subresources ~w(tagging versioning cors lifecycle website
                      versions notification replication encryption object-lock legal-hold retention
                      attributes select torrent restore accelerate analytics inventory metrics
                      ownershipcontrols publicaccessblock requestpayment logging)
```

(b) 在 `resolve/3` 的 `cond` 中、**在 `m2_subresource?` 之前**（policy 分支之后）加 acl 分支（桶级与对象级各自）：

```elixir
      MapSet.member?(query_keys, "acl") ->
        case {level, method} do
          {:bucket, "GET"} -> {:ok, :get_bucket_acl}
          {:bucket, "PUT"} -> {:ok, :put_bucket_acl}
          {:object, "GET"} -> {:ok, :get_object_acl}
          {:object, "PUT"} -> {:ok, :put_object_acl}
          _ -> {:error, :method_not_allowed}
        end
```

### 步骤 8：handlers facade 接线（`lib/maxio/s3/handlers.ex`）

(a) alias 加 `Acl`：

```elixir
  alias Maxio.S3.Handlers.{Service, Bucket, Object, Multipart, BucketPolicy, Acl}
```

(b) dispatch 子句加四条：

```elixir
  def dispatch(:get_bucket_acl, conn), do: Acl.get_bucket_acl(conn)
  def dispatch(:put_bucket_acl, conn), do: Acl.put_bucket_acl(conn)
  def dispatch(:get_object_acl, conn), do: Acl.get_object_acl(conn)
  def dispatch(:put_object_acl, conn), do: Acl.put_object_acl(conn)
```

### 步骤 9：CreateBucket / PutObject 接 `x-amz-acl`

`lib/maxio/s3/handlers/bucket.ex` `create/1`：把 `x-amz-acl` 头透传给 `Buckets.create`（对象专属 canned 在桶级忽略——官方语义；本 MVP 对未知/对象专属 canned 直接存名、不报错）：

```elixir
  def create(conn) do
    bucket = conn.assigns.s3_bucket
    owner = conn.assigns.principal.arn
    acl = bucket_canned(conn |> Plug.Conn.get_req_header("x-amz-acl") |> List.first())

    case Buckets.create(bucket, owner, region: region(), acl_canned: acl) do
      # ...（其余不变）
```

并加私有：

```elixir
  # CreateBucket 的 x-amz-acl：对象专属 canned（bucket-owner-*）在桶级被静默忽略（官方），落 private。
  defp bucket_canned(nil), do: "private"
  defp bucket_canned(c) when c in ~w(bucket-owner-read bucket-owner-full-control), do: "private"
  defp bucket_canned(c), do: c
```

`lib/maxio/s3/handlers/object.ex` `do_put/1`：把 `x-amz-acl` 存入元数据（在 `Objects.put_metadata` 调用的 attrs 加 `acl_canned`）：

```elixir
          {:ok, _obj} =
            Objects.put_metadata(bucket, key, %{
              size: size,
              etag: etag,
              content_type: content_type,
              storage_class: "STANDARD",
              acl_canned: header(conn, "x-amz-acl") || "private"
            })
```

> 注意：`do_put/1` 这段在 `try` 块内（rescue 清理孤儿字节），仅在 attrs 加一行，其它不动。

### 步骤 10：单测

**ACL 折叠单测** `test/maxio/policy/acl_test.exs`：

```elixir
defmodule Maxio.Policy.ACLTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.{ACL, Evaluator, RequestContext, Statement}

  defp anon(action, resource, conds \\ %{}) do
    %RequestContext{principal: :anonymous, authenticated?: false, owner?: false,
      action: action, resource: resource, conditions: conds}
  end

  test "private 对象 ACL → 无公共 statement（匿名隐拒）" do
    stmts = ACL.canned_to_statements("private", :object, "b", "k")
    assert stmts == []
    assert Evaluator.evaluate(anon("s3:GetObject", "arn:aws:s3:::b/k"), stmts) == {:deny, :implicit_deny}
  end

  test "public-read 对象 → 匿名 GetObject allow" do
    stmts = ACL.canned_to_statements("public-read", :object, "b", "k")
    assert Evaluator.evaluate(anon("s3:GetObject", "arn:aws:s3:::b/k"), stmts) == :allow
    assert Evaluator.evaluate(anon("s3:PutObject", "arn:aws:s3:::b/k"), stmts) == {:deny, :implicit_deny}
  end

  test "public-read-write 对象 → 匿名 Put 也 allow" do
    stmts = ACL.canned_to_statements("public-read-write", :object, "b", "k")
    assert Evaluator.evaluate(anon("s3:PutObject", "arn:aws:s3:::b/k"), stmts) == :allow
  end

  test "public-read 桶 → 匿名 ListBucket allow（桶 ARN）" do
    stmts = ACL.canned_to_statements("public-read", :bucket, "b", nil)
    assert Evaluator.evaluate(anon("s3:ListBucket", "arn:aws:s3:::b"), stmts) == :allow
  end

  test "authenticated-read 对象 → 匿名隐拒，认证放行" do
    stmts = ACL.canned_to_statements("authenticated-read", :object, "b", "k")
    # 匿名：maxio:Authenticated 缺键 → 条件不成立 → 隐拒
    assert Evaluator.evaluate(anon("s3:GetObject", "arn:aws:s3:::b/k", %{"maxio:Authenticated" => "false"}), stmts) == {:deny, :implicit_deny}
    # 认证：maxio:Authenticated=="true" → allow
    assert Evaluator.evaluate(anon("s3:GetObject", "arn:aws:s3:::b/k", %{"maxio:Authenticated" => "true"}), stmts) == :allow
  end

  test "bucket-owner-* / 未知 canned → 无公共 statement（按 private）" do
    assert ACL.canned_to_statements("bucket-owner-full-control", :object, "b", "k") == []
    assert ACL.canned_to_statements("aws-exec-read", :object, "b", "k") == []
  end

  test "XML round-trip：parser 分类回 canned" do
    {:ok, canned} =
      Maxio.S3.RequestParsers.AccessControlPolicy.parse(~s(
        <AccessControlPolicy><AccessControlList>
          <Grant><Grantee xsi:type="Group"><URI>http://acs.amazonaws.com/groups/global/AllUsers</URI></Grantee><Permission>READ</Permission></Grant>
        </AccessControlList></AccessControlPolicy>))
    assert canned == "public-read"
  end
end
```

**ACL e2e** `test/maxio/s3/acl_test.exs`：

```elixir
defmodule Maxio.S3.AclTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_acl_test")

  setup do
    File.rm_rf(@data_dir); File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn -> Application.put_env(:maxio, :s3, prev); File.rm_rf(@data_dir) end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "PutObject x-amz-acl=public-read → GetObjectAcl 展开 AllUsers READ" do
    SigV4Request.signed_conn(:put, "/ab") |> call()

    SigV4Request.signed_conn(:put, "/ab/pub.txt",
      body: "hi",
      headers: [{"x-amz-acl", "public-read"}]
    )
    |> call()

    acl = SigV4Request.signed_conn(:get, "/ab/pub.txt", query: %{"acl" => ""}) |> call()
    assert acl.status == 200
    assert acl.resp_body =~ ~s(xsi:type="Group")
    assert acl.resp_body =~ "AllUsers"
    assert acl.resp_body =~ "<Permission>READ</Permission>"
    assert acl.resp_body =~ ~s(xmlns="http://s3.amazonaws.com/doc/2006-03-01/")
  end

  test "GetBucketAcl 默认 private → 仅 owner FULL_CONTROL" do
    SigV4Request.signed_conn(:put, "/ab2") |> call()
    acl = SigV4Request.signed_conn(:get, "/ab2", query: %{"acl" => ""}) |> call()
    assert acl.status == 200
    assert acl.resp_body =~ "<Permission>FULL_CONTROL</Permission>"
    refute acl.resp_body =~ "AllUsers"
  end

  test "PutBucketAcl x-amz-acl=public-read → GetBucketAcl 展开" do
    SigV4Request.signed_conn(:put, "/ab3") |> call()

    put =
      SigV4Request.signed_conn(:put, "/ab3", query: %{"acl" => ""}, headers: [{"x-amz-acl", "public-read"}])
      |> call()

    assert put.status == 200

    acl = SigV4Request.signed_conn(:get, "/ab3", query: %{"acl" => ""}) |> call()
    assert acl.resp_body =~ "AllUsers"
  end
end
```

### 单元收尾验证（M3-7）

```powershell
mix ecto.migrate
mix test test/maxio/policy/acl_test.exs test/maxio/s3/acl_test.exs
mix compile --warnings-as-errors
mix test
```

期望：ACL 折叠 + e2e 全绿；编译零警告；全量绿。提交：

```powershell
git add -A
git commit -m @'
M3-7: Canned ACL — acl_canned columns + Policy.ACL fold into Evaluator + AccessControlPolicy XML in/out + Put/Get Bucket/Object ACL + Dispatcher ?acl + x-amz-acl on CreateBucket/PutObject

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) buckets/objects `acl_canned` 列中文 COMMENT；(2) canned→statement 折叠（private/public-read/public-read-write/authenticated-read，对象/桶层级、AuthenticatedUsers vs AllUsers）经**同一 Evaluator**正确；(3) GetAcl XML 含 prolog+root xmlns+xsi:type 属性形式+正确组 URI；(4) PutObject/PutBucketAcl x-amz-acl 存储并 GetAcl 展开；(5) email grantee → 400；(6) Dispatcher `?acl` 不再 not_implemented；(7) 零警告、全量绿。

---

## M3-8 · `ActionMap` + `Maxio.S3.Authz` 关卡 + 匿名 principal（SigV4 改）+ 管线接线

**目标**：把前面所有零件总装为单一授权关卡。`Dispatch` resolve 出 action 后、调 handler 前调 `Authz.authorize(conn, action)`：构造 `RequestContext`（principal + s3:Action + 资源 ARN + 条件键），合并 bucket policy + ACL 派生 statement，过 Evaluator，拒绝 → `AccessDenied(403)` + 结构化日志。`SigV4` plug 改：完全无凭据 → principal `:anonymous`（而非 400），使 public bucket policy 能放行匿名；坏凭据仍硬失败。

**依赖**：M3-6, M3-7。**规模**：ActionMap + Authz 模块 + SigV4 改 + Dispatch 接线 + 集成测试。

### 步骤 1：`Maxio.Policy.ActionMap`（operation → s3:Action + 资源层级）

新建 `lib/maxio/policy/action_map.ex`（官方核验，§RESEARCH bake-in 的 operation→action 表）：

```elixir
defmodule Maxio.Policy.ActionMap do
  @moduledoc """
  S3 操作（Dispatcher 的 action atom）→ 所需 s3:Action + 资源层级（铁律 5，对齐官方
  「Required permissions for S3 API operations」表）。资源层级决定 Authz 构造桶 ARN 还是对象 ARN：
    :bucket  → arn:aws:s3:::<bucket>
    :object  → arn:aws:s3:::<bucket>/<key>
    :account → arn:aws:s3:::*（ListAllMyBuckets）
  CopyObject / UploadPartCopy 需源 GetObject + 目标 PutObject 两次检查（{:multi, [...]}），
  本 MVP 由 Authz 特判（见 authorize/2）。
  """

  @type level :: :bucket | :object | :account
  @type spec :: {String.t(), level()}

  @doc "返回 {required_action, level}。未知 action → nil（Authz 当作无需授权放行——仅子资源管理动作已显式列出）。"
  @spec for_action(atom()) :: spec() | nil
  def for_action(:list_buckets), do: {"s3:ListAllMyBuckets", :account}

  def for_action(:create_bucket), do: {"s3:CreateBucket", :bucket}
  def for_action(:delete_bucket), do: {"s3:DeleteBucket", :bucket}
  def for_action(:head_bucket), do: {"s3:ListBucket", :bucket}
  def for_action(:list_objects_v2), do: {"s3:ListBucket", :bucket}
  def for_action(:get_bucket_location), do: {"s3:GetBucketLocation", :bucket}

  def for_action(:put_object), do: {"s3:PutObject", :object}
  def for_action(:get_object), do: {"s3:GetObject", :object}
  def for_action(:head_object), do: {"s3:GetObject", :object}
  def for_action(:delete_object), do: {"s3:DeleteObject", :object}
  # DeleteObjects 批删：Authz 用桶级 s3:DeleteObject 作粗粒度门（细粒度逐 key 检查 defer，文档化）。
  def for_action(:delete_objects), do: {"s3:DeleteObject", :bucket}

  def for_action(:create_multipart_upload), do: {"s3:PutObject", :object}
  def for_action(:upload_part), do: {"s3:PutObject", :object}
  def for_action(:complete_multipart_upload), do: {"s3:PutObject", :object}
  def for_action(:abort_multipart_upload), do: {"s3:AbortMultipartUpload", :object}
  def for_action(:list_parts), do: {"s3:ListMultipartUploadParts", :object}
  def for_action(:list_multipart_uploads), do: {"s3:ListBucketMultipartUploads", :bucket}

  def for_action(:put_bucket_policy), do: {"s3:PutBucketPolicy", :bucket}
  def for_action(:get_bucket_policy), do: {"s3:GetBucketPolicy", :bucket}
  def for_action(:delete_bucket_policy), do: {"s3:DeleteBucketPolicy", :bucket}

  def for_action(:get_bucket_acl), do: {"s3:GetBucketAcl", :bucket}
  def for_action(:put_bucket_acl), do: {"s3:PutBucketAcl", :bucket}
  def for_action(:get_object_acl), do: {"s3:GetObjectAcl", :object}
  def for_action(:put_object_acl), do: {"s3:PutObjectAcl", :object}

  # CopyObject 走 :put_object（put 路径内部分流），源读权限的二次检查由 Authz 特判（见 authorize/2 的 copy 分支）。
  def for_action(_other), do: nil
end
```

> **CopyObject 两次检查（文档化）**：CopyObject 经 `:put_object` 进入（Object.put 内部按 `x-amz-copy-source` 分流）。Authz 在 `:put_object` 且存在 `x-amz-copy-source` 头时，**额外**对源对象做一次 `s3:GetObject` 授权（见步骤 3）。UploadPartCopy 本 MVP 未实现（M2 未做 UploadPartCopy），故不涉及。

单测 `test/maxio/policy/action_map_test.exs`：

```elixir
defmodule Maxio.Policy.ActionMapTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.ActionMap

  test "桶级动作 → :bucket" do
    assert ActionMap.for_action(:list_objects_v2) == {"s3:ListBucket", :bucket}
    assert ActionMap.for_action(:head_bucket) == {"s3:ListBucket", :bucket}
    assert ActionMap.for_action(:list_multipart_uploads) == {"s3:ListBucketMultipartUploads", :bucket}
  end

  test "对象级动作 → :object" do
    assert ActionMap.for_action(:get_object) == {"s3:GetObject", :object}
    assert ActionMap.for_action(:head_object) == {"s3:GetObject", :object}
    assert ActionMap.for_action(:upload_part) == {"s3:PutObject", :object}
    assert ActionMap.for_action(:list_parts) == {"s3:ListMultipartUploadParts", :object}
  end

  test "账户级 ListAllMyBuckets" do
    assert ActionMap.for_action(:list_buckets) == {"s3:ListAllMyBuckets", :account}
  end

  test "未知 action → nil" do
    assert ActionMap.for_action(:nonexistent) == nil
  end
end
```

### 步骤 2：SigV4 plug 允许匿名（无凭据 → :anonymous，坏凭据仍硬失败）

修改 `lib/maxio/s3/plugs/sigv4.ex` 的 `detect_and_parse/1` 的 `true ->` 兜底分支——把「无凭据 → `{:error, :missing_security_header}`」改为返回一个哨兵 `:anonymous`，并在 `do_authenticate/1` 中处理。精确改法：

(a) `detect_and_parse/1` 兜底分支改为：

```elixir
  defp detect_and_parse(conn) do
    cond do
      Map.has_key?(conn.query_params, "X-Amz-Signature") ->
        AuthHeaderParser.parse_presigned(conn.query_params)

      auth = get_req_header(conn, "authorization") |> List.first() ->
        amz_date = header(conn, "x-amz-date")
        content_sha = header(conn, "x-amz-content-sha256") || ""
        AuthHeaderParser.parse_header(auth, amz_date, content_sha)

      true ->
        # 完全无凭据（无 Authorization 头 + 无 X-Amz-Signature 查询参数）→ 匿名 principal。
        # 绝不静默放行：仅把放行/拒绝裁决下沉到 Authz/policy 层（默认拒绝、显式 deny 优先）。
        # 注意：坏凭据（有 Authorization 但畸形 / 有 X-Amz-Signature 但缺参）仍走上面两分支硬失败——
        # 匿名只从「凭据完全缺席」推断，绝不从解析失败推断（铁律 3 的精确边界）。
        :anonymous
    end
  end
```

(b) `do_authenticate/1` 增加 `:anonymous` 处理（在 `case detect_and_parse(conn) do` 内加一支）：

```elixir
  defp do_authenticate(conn) do
    case detect_and_parse(conn) do
      :anonymous ->
        conn
        |> assign(:principal, :anonymous)
        |> assign(:auth_type, :anonymous)
        |> assign(:payload_mode, :unsigned)

      {:ok, signed_request} ->
        material = build_material(conn, signed_request)

        case Auth.authenticate(material) do
          {:ok, principal, sig_context} ->
            conn
            |> assign(:principal, principal)
            |> assign(:auth_type, signed_request.auth_type)
            |> assign(:payload_mode, signed_request.payload_mode)
            |> assign(:sigv4_context, sig_context)

          {:error, %Error{} = err} ->
            reject(conn, err)
        end

      {:error, code} ->
        reject(conn, Error.new(code))
    end
  end
```

> 不变量保持：(1) 有 `Authorization` 但非 `AWS4-HMAC-SHA256`/畸形 → `parse_header` 返 `{:error, :authorization_header_malformed}` → reject（硬失败）。(2) 有 `X-Amz-Signature` 但缺参 → `parse_presigned` 返 `{:error, :authorization_query_parameters_error}` → reject。(3) 未知 key / 坏签名 / 偏移 / 过期 → `Auth.authenticate` 内 reject。**匿名仅从凭据完全缺席推断**。

### 步骤 3：`Maxio.S3.Authz` 关卡

新建 `lib/maxio/s3/authz.ex`：

```elixir
defmodule Maxio.S3.Authz do
  @moduledoc """
  授权关卡（铁律 3：绝不静默放行；拒绝 → AccessDenied 403 + 结构化日志）。
  在 Dispatch 解析出 action 之后、调用 handler 之前调用：
    1. 用 ActionMap 把 action → {s3:Action, 资源层级}；未映射的 action → 放行（无授权语义）。
    2. 构造资源 ARN（桶/对象/账户）+ 抽取条件键（aws:SecureTransport/SourceIp/CurrentTime/s3:prefix...）。
    3. 合并 statement 来源（顺序无关，Deny 优先由 Evaluator 保证）：
         bucket policy statements（Store.statements_for_bucket）
         ++ 该资源 canned ACL 派生 statements（桶 ACL 与/或对象 ACL）
         ++ principal_policies（MVP []）
    4. 构造 RequestContext（含 owner?/authenticated?）→ Evaluator.evaluate。
       :allow → :ok；{:deny, _} → raise AccessDenied(403)。
  owner? 判定（单租户）：principal.type == :root，或 principal 的 arn == 资源所属桶 owner。

  绝不缓冲对象 body（铁律 4）：本关卡只读 conn 元信息（assigns/headers/query），不 read_body。
  CopyObject（:put_object 且带 x-amz-copy-source）：额外对源对象做一次 s3:GetObject 授权。
  """
  import Plug.Conn
  alias Maxio.{Buckets, Objects}
  alias Maxio.Policy.{ACL, ActionMap, Arn, Evaluator, RequestContext, Store}
  alias Maxio.S3.{Error, Log}

  @spec authorize(Plug.Conn.t(), atom()) :: :ok
  def authorize(conn, action) do
    case ActionMap.for_action(action) do
      nil ->
        # 未映射动作（无明确 S3 授权语义）→ 放行（不静默掩盖：这些都是已显式列出的管理动作之外的）。
        :ok

      {required_action, level} ->
        do_authorize(conn, action, required_action, level)
    end
  end

  defp do_authorize(conn, action, required_action, level) do
    bucket = conn.assigns[:s3_bucket]
    key = conn.assigns[:s3_key]
    principal = conn.assigns[:principal]
    authenticated? = principal != :anonymous

    resource = resource_arn(level, bucket, key)
    conditions = extract_conditions(conn, authenticated?)

    statements = gather_statements(level, bucket, key)

    ctx = %RequestContext{
      principal: principal,
      authenticated?: authenticated?,
      owner?: owner?(principal, bucket),
      action: required_action,
      resource: resource,
      conditions: conditions
    }

    case Evaluator.evaluate(ctx, statements) do
      :allow ->
        # CopyObject 二次检查：源对象 s3:GetObject（铁律 5，对齐官方 CopyObject 双检查）。
        maybe_authorize_copy_source(conn, action, principal, authenticated?, conditions)
        :ok

      {:deny, reason} ->
        deny(conn, action, required_action, resource, reason)
    end
  end

  # ── owner 短路判定（单租户）──
  defp owner?(:anonymous, _bucket), do: false
  defp owner?(%{type: :root}, _bucket), do: true

  defp owner?(%{arn: arn}, bucket) when is_binary(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, %{owner: ^arn}} -> true
      _ -> false
    end
  end

  defp owner?(_principal, _bucket), do: false

  # ── 资源 ARN ──
  defp resource_arn(:account, _bucket, _key), do: Arn.account_arn()
  defp resource_arn(:bucket, bucket, _key), do: Arn.bucket_arn(bucket)
  defp resource_arn(:object, bucket, key), do: Arn.object_arn(bucket, key)

  # ── statement 合并：bucket policy + canned ACL 派生 ──
  defp gather_statements(:account, _bucket, _key), do: []

  defp gather_statements(level, bucket, key) when is_binary(bucket) do
    policy_stmts = Store.statements_for_bucket(bucket)
    acl_stmts = acl_statements(level, bucket, key)
    policy_stmts ++ acl_stmts ++ Store.principal_policies(:anonymous)
  end

  defp gather_statements(_level, _bucket, _key), do: []

  # 桶级动作看桶 ACL；对象级动作看对象 ACL（对象不存在则空——put 路径对象尚未建，靠 policy/owner）。
  defp acl_statements(:bucket, bucket, _key) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> ACL.canned_to_statements(b.acl_canned, :bucket, bucket, nil)
      _ -> []
    end
  end

  defp acl_statements(:object, bucket, key) do
    case Objects.get_metadata(bucket, key) do
      {:ok, obj} -> ACL.canned_to_statements(obj.acl_canned, :object, bucket, key)
      _ -> []
    end
  end

  # ── 条件键抽取（铁律 5：SecureTransport/SourceIp/CurrentTime 务必填，否则相关 Deny 失效）──
  defp extract_conditions(conn, authenticated?) do
    %{
      "aws:SecureTransport" => conn.scheme == :https,
      "aws:SourceIp" => source_ip(conn),
      "aws:CurrentTime" => now(conn),
      # ACL authenticated-read 折叠用的内部键（见 Policy.ACL）。
      "maxio:Authenticated" => if(authenticated?, do: "true", else: "false")
    }
    |> put_list_conditions(conn)
  end

  # ListObjects* 的 s3:prefix / s3:delimiter（来自 query）。
  defp put_list_conditions(conds, conn) do
    qp = conn.query_params || %{}

    conds
    |> maybe_put("s3:prefix", Map.get(qp, "prefix"))
    |> maybe_put("s3:delimiter", Map.get(qp, "delimiter"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp source_ip(conn) do
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      _ -> nil
    end
  end

  defp now(conn), do: conn.private[:maxio_now] || DateTime.utc_now()

  # ── CopyObject 源对象二次检查 ──
  defp maybe_authorize_copy_source(conn, :put_object, principal, authenticated?, conditions) do
    case conn |> get_req_header("x-amz-copy-source") |> List.first() do
      nil ->
        :ok

      raw ->
        {src_bucket, src_key} = parse_copy_source(raw)
        resource = Arn.object_arn(src_bucket, src_key)
        statements = gather_statements(:object, src_bucket, src_key)

        ctx = %RequestContext{
          principal: principal,
          authenticated?: authenticated?,
          owner?: owner?(principal, src_bucket),
          action: "s3:GetObject",
          resource: resource,
          conditions: conditions
        }

        case Evaluator.evaluate(ctx, statements) do
          :allow -> :ok
          {:deny, reason} -> deny(conn, :copy_object_source, "s3:GetObject", resource, reason)
        end
    end
  end

  defp maybe_authorize_copy_source(_conn, _action, _p, _a, _c), do: :ok

  defp parse_copy_source(raw) do
    decoded = URI.decode(raw)
    trimmed = String.replace_prefix(decoded, "/", "")
    [path | _] = String.split(trimmed, "?", parts: 2)

    case String.split(path, "/", parts: 2) do
      [b, k] when k != "" -> {b, k}
      _ -> {"", ""}
    end
  end

  # ── 拒绝（绝不静默，铁律 3）──
  defp deny(conn, action, required_action, resource, reason) do
    Log.warn("authz denied",
      action: action,
      reason: reason,
      bucket: conn.assigns[:s3_bucket],
      key: conn.assigns[:s3_key],
      code: "AccessDenied",
      status: 403
    )

    _ = required_action
    raise Error.new(:access_denied, resource: resource)
  end
end
```

### 步骤 4：Dispatch 接线（resolve 出 action 后、调 handler 前调 Authz）

修改 `lib/maxio/s3/plugs/dispatch.ex` 的 `call/2`，在 `{:ok, action}` 分支插入 Authz：

```elixir
  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    query_keys = conn.query_params |> Map.keys() |> Enum.map(&String.downcase/1) |> MapSet.new()

    try do
      case Dispatcher.resolve(conn.assigns.s3_level, conn.method, query_keys) do
        {:ok, action} ->
          conn = assign(conn, :s3_action, action)
          :ok = Maxio.S3.Authz.authorize(conn, action)
          Handlers.dispatch(action, conn)

        {:error, reason} ->
          raise Error.new(reason)
      end
    rescue
      err in Maxio.S3.Error ->
        render_error(conn, err)

      other ->
        Log.error("unhandled exception in dispatch", code: "InternalError", status: 500)
        render_error(conn, Error.new(:internal_error, message: Exception.message(other)))
    end
  end
```

> Authz raise 的 `Maxio.S3.Error`（AccessDenied 403）被既有 `rescue err in Maxio.S3.Error` 捕获并渲染为标准 XML（绝不静默 500）。`alias` 行已有 `Error/ErrorView/Handlers`；`Maxio.S3.Authz` 用全限定名即可（或在 alias 加 `Authz`）。

### 步骤 5：扩展 `SigV4Request` 支持匿名请求 + remote_ip/scheme（集成测试用）

在 `test/support/sigv4_request.ex` 末尾（`def access_key` 前后）新增匿名构造辅助：

```elixir
  @doc """
  构造一个匿名（无凭据）请求 conn——无 Authorization 头、无 X-Amz-Signature 查询参数。
  用于测试 public bucket policy / ACL 放行匿名访问。opts: :query、:headers、:body。
  """
  def anon_conn(method, path, opts \\ []) do
    query = Keyword.get(opts, :query, %{})
    extra_headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")

    query_string = URI.encode_query(query)
    full_path = if query_string == "", do: path, else: path <> "?" <> query_string

    conn =
      conn(method, full_path, body)
      |> Map.put(:host, @host)
      |> put_private(:maxio_now, DateTime.utc_now())

    Enum.reduce(extra_headers, conn, fn {k, v}, acc -> put_req_header(acc, String.downcase(k), v) end)
  end
```

> `Plug.Test.conn/3` 默认 `scheme: :http`、`remote_ip: {127,0,0,1}`——Authz 的 `aws:SecureTransport`=false、`aws:SourceIp`="127.0.0.1" 自然成立。已认证请求（`signed_conn`）同理是 http+127.0.0.1。这对默认（无 SecureTransport Deny 的）policy 不影响裁决。

### 步骤 6：集成测试 `test/maxio/s3/authz_test.exs`

```elixir
defmodule Maxio.S3.AuthzTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_authz_test")
  @public_get ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::pubb/*"}]})

  setup do
    File.rm_rf(@data_dir); File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn -> Application.put_env(:maxio, :s3, prev); File.rm_rf(@data_dir) end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "root（owner）始终放行（owner 短路）" do
    SigV4Request.signed_conn(:put, "/rb") |> call()
    put = SigV4Request.signed_conn(:put, "/rb/k.txt", body: "x") |> call()
    assert put.status == 200
    get = SigV4Request.signed_conn(:get, "/rb/k.txt") |> call()
    assert get.status == 200
  end

  test "匿名请求无 policy → 403 AccessDenied（默认拒绝，绝不静默放行）" do
    SigV4Request.signed_conn(:put, "/privb") |> call()
    SigV4Request.signed_conn(:put, "/privb/secret.txt", body: "top") |> call()

    anon = SigV4Request.anon_conn(:get, "/privb/secret.txt") |> call()
    assert anon.status == 403
    assert anon.resp_body =~ "AccessDenied"
  end

  test "匿名请求 + public bucket policy → 放行 GetObject" do
    SigV4Request.signed_conn(:put, "/pubb") |> call()
    SigV4Request.signed_conn(:put, "/pubb/open.txt", body: "hello world") |> call()

    # owner（root）装 public-read policy
    SigV4Request.signed_conn(:put, "/pubb",
      query: %{"policy" => ""}, body: @public_get, headers: [{"content-type", "application/json"}])
    |> call()

    anon = SigV4Request.anon_conn(:get, "/pubb/open.txt") |> call()
    assert anon.status == 200
    assert anon.resp_body == "hello world"
  end

  test "匿名请求 + public-read ACL 对象 → 放行 GetObject" do
    SigV4Request.signed_conn(:put, "/aclb") |> call()
    SigV4Request.signed_conn(:put, "/aclb/p.txt", body: "acl-open", headers: [{"x-amz-acl", "public-read"}]) |> call()

    anon = SigV4Request.anon_conn(:get, "/aclb/p.txt") |> call()
    assert anon.status == 200
    assert anon.resp_body == "acl-open"
  end

  test "匿名 + public-read 只放行 Get，不放行 Delete → 403" do
    SigV4Request.signed_conn(:put, "/rob") |> call()
    SigV4Request.signed_conn(:put, "/rob/x.txt", body: "ro", headers: [{"x-amz-acl", "public-read"}]) |> call()

    del = SigV4Request.anon_conn(:delete, "/rob/x.txt") |> call()
    assert del.status == 403
    assert del.resp_body =~ "AccessDenied"
  end

  test "显式 Deny policy 压倒 → 即便 owner 之外的认证用户被拒（用第二个 key 模拟）" do
    # root 建桶 + 对象 + 装 Deny-all-non-owner policy（这里用匿名验证 Deny 生效，owner 仍短路）。
    SigV4Request.signed_conn(:put, "/denyb") |> call()
    SigV4Request.signed_conn(:put, "/denyb/d.txt", body: "deny") |> call()

    deny = ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::denyb/*"},{"Effect":"Deny","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::denyb/*"}]})
    SigV4Request.signed_conn(:put, "/denyb", query: %{"policy" => ""}, body: deny, headers: [{"content-type", "application/json"}]) |> call()

    anon = SigV4Request.anon_conn(:get, "/denyb/d.txt") |> call()
    assert anon.status == 403
  end

  test "坏凭据仍硬失败（不退化为匿名）：篡改签名 → 403 SignatureDoesNotMatch" do
    SigV4Request.signed_conn(:put, "/badb") |> call()

    conn = SigV4Request.signed_conn(:get, "/badb", query: %{"location" => ""})
    [auth] = get_req_header(conn, "authorization")
    tampered = String.replace(auth, ~r/Signature=.*/, "Signature=deadbeef")
    bad = conn |> delete_req_header("authorization") |> put_req_header("authorization", tampered) |> call()
    assert bad.status == 403
    assert bad.resp_body =~ "SignatureDoesNotMatch"
  end

  test "完全无凭据访问 service 级 ListBuckets → 403（账户级默认拒绝匿名）" do
    anon = SigV4Request.anon_conn(:get, "/") |> call()
    assert anon.status == 403
  end
end
```

> 注：现有 `test/maxio/s3/integration_test.exs` 的全部用例用 root（SigV4Request 默认 root key）→ owner 短路放行 → 不受 Authz 接入影响，应继续全绿。M3-9 会再补一轮回归确认。

### 单元收尾验证（M3-8）

```powershell
mix test test/maxio/policy/action_map_test.exs test/maxio/s3/authz_test.exs
mix compile --warnings-as-errors
mix test
```

期望：ActionMap + Authz 集成全绿；**既有 integration_test.exs 仍全绿**（root 短路）；编译零警告；全量绿。提交：

```powershell
git add -A
git commit -m @'
M3-8: Authz gate — Policy.ActionMap (operation→action→resource), Maxio.S3.Authz (RequestContext build + Evaluator + AccessDenied), anonymous principal in SigV4 (no-creds, bad-creds still hard-fail), wired into Dispatch

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) root owner 短路放行（既有 e2e 全绿）；(2) 匿名无 policy → 403 AccessDenied（默认拒绝）；(3) 匿名 + public bucket policy / public-read ACL → 放行 Get、拒绝 Delete；(4) 显式 Deny 压倒；(5) **坏凭据仍硬失败**（篡改签名 → SignatureDoesNotMatch，不退化匿名）；(6) ActionMap 全 operation 映射正确；(7) Authz 不缓冲 body、拒绝走标准 XML 而非 500；(8) 零警告、全量绿。

---

## M3-9 · 端到端授权集成矩阵 + STATUS 更新

**目标**：补齐授权场景活体取证矩阵（覆盖 M1/M2 全操作在「认证非 owner / 匿名 / 条件键」下的裁决），全量回归，更新 STATUS 单一事实来源。

**依赖**：M3-8。**规模**：集成测试矩阵 + 文档。

### 步骤 1：授权矩阵集成测试 `test/maxio/s3/authz_matrix_test.exs`

用一个**非 owner 认证 principal**（经 `Maxio.IAM`/MemoryStore 注入第二个 key）验证「认证但无授权 → 403」与「policy 命名该 principal → 放行」。

> test 环境凭据后端是 MemoryStore（惰性引导 root）；本测试在 setup 里用 `Maxio.Auth.CredentialStore.put_access_key/1` 注入第二个 key（iam_user），并扩展 `SigV4Request` 支持自定义 access_key/secret 签名。

(a) 扩展 `test/support/sigv4_request.ex`：把 `signed_conn/3` 的 `@access_key`/`@secret` 改为可经 opts 覆盖（默认仍 root）：

```elixir
  def signed_conn(method, path, opts \\ []) do
    query = Keyword.get(opts, :query, %{})
    extra_headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")
    access_key = Keyword.get(opts, :access_key, @access_key)
    secret = Keyword.get(opts, :secret, @secret)
    # ...（now/amz_date/scope 不变）
    # 把后续用到 @access_key 的地方替换为 access_key，用到 @secret 的替换为 secret：
    #   payload_hash 不变；
    #   key = Signer.derive_signing_key(secret, scope_date, @region, @service)
    #   auth = "AWS4-HMAC-SHA256 Credential=#{access_key}/#{scope}," <> ...
    # 其余逐字不变。
```

> executor 实现时：在函数顶部加 `access_key`/`secret` 两个绑定（默认取模块属性），把函数体内 `@access_key`→`access_key`、`@secret`→`secret` 两处替换。`signed_chunked_conn` 不需改（流式测试仍用 root）。

(b) 矩阵测试：

```elixir
defmodule Maxio.S3.AuthzMatrixTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.Auth.CredentialStore
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_authz_matrix_test")
  @alice_ak "AKIAALICEKEY00000001"
  @alice_secret "alicealicealicealicealicealice12"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak

  setup do
    File.rm_rf(@data_dir); File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    # 注入非 owner 认证 principal（MemoryStore）。
    :ok = CredentialStore.put_access_key(%{access_key: @alice_ak, secret_key: @alice_secret,
            principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}})

    on_exit(fn -> Application.put_env(:maxio, :s3, prev); File.rm_rf(@data_dir) end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))
  defp alice(method, path, opts), do: SigV4Request.signed_conn(method, path, Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts))

  test "认证非 owner 无 policy → 403（认证 ≠ 授权）" do
    SigV4Request.signed_conn(:put, "/mb") |> call()       # root 建桶（owner=root）
    SigV4Request.signed_conn(:put, "/mb/o.txt", body: "x") |> call()

    get = alice(:get, "/mb/o.txt", []) |> call()
    assert get.status == 403
    assert get.resp_body =~ "AccessDenied"
  end

  test "policy 命名该 principal arn → 放行" do
    SigV4Request.signed_conn(:put, "/mb2") |> call()
    SigV4Request.signed_conn(:put, "/mb2/o.txt", body: "yes") |> call()

    pol = ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::mb2/*"}})
    SigV4Request.signed_conn(:put, "/mb2", query: %{"policy" => ""}, body: pol, headers: [{"content-type", "application/json"}]) |> call()

    get = alice(:get, "/mb2/o.txt", []) |> call()
    assert get.status == 200
    assert get.resp_body == "yes"
  end

  test "policy StringLike s3:prefix 限制 ListBucket" do
    SigV4Request.signed_conn(:put, "/mb3") |> call()

    pol = ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:ListBucket","Resource":"arn:aws:s3:::mb3","Condition":{"StringLike":{"s3:prefix":["home/*"]}}}})
    SigV4Request.signed_conn(:put, "/mb3", query: %{"policy" => ""}, body: pol, headers: [{"content-type", "application/json"}]) |> call()

    ok = alice(:get, "/mb3", query: %{"prefix" => "home/alice/"}) |> call()
    assert ok.status == 200

    denied = alice(:get, "/mb3", query: %{"prefix" => "secret/"}) |> call()
    assert denied.status == 403
  end

  test "CopyObject 源读权限：源对象对 alice private → copy 被拒（源 GetObject 二次检查）" do
    SigV4Request.signed_conn(:put, "/mb4") |> call()
    SigV4Request.signed_conn(:put, "/mb4/src.txt", body: "src") |> call()
    # 给 alice 目标 PutObject 权限，但不给源 GetObject → 二次检查应拒。
    pol = ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::mb4/*"}})
    SigV4Request.signed_conn(:put, "/mb4", query: %{"policy" => ""}, body: pol, headers: [{"content-type", "application/json"}]) |> call()

    copy = alice(:put, "/mb4/dst.txt", headers: [{"x-amz-copy-source", "/mb4/src.txt"}]) |> call()
    assert copy.status == 403
  end
end
```

### 步骤 2：全量回归

```powershell
mix compile --warnings-as-errors
mix test
```

期望：全量测试通过（M2 基线 191 + M3 新增全部用例），零警告。记录最终测试数。

### 步骤 3：更新 STATUS（单一事实来源）

编辑 `docs/superpowers/STATUS.md`：

(a) 里程碑表 M3 行状态从 `⬜ 待` 改为 `✅ 已实现并验证（master，2026-06-08；<N> 测试全绿、Evaluator 真值表 + 匿名/public policy/ACL e2e、独立 reviewer APPROVE）`。

(b) 新增「M3 实现摘要」节，列：M3-1 硬化（自拷贝数据丢失修复等）；M3-2/3 Policy 纯函数层（Arn/Statement/RequestContext/Evaluator/Condition，真值表）；M3-4 凭据持久化（access_keys/EctoStore/IAM/CLI/root 引导）；M3-5/6 bucket policy（Store behaviour/jsonb/Put-Get-Delete API）；M3-7 canned ACL（折叠进同一 Evaluator + AccessControlPolicy XML）；M3-8 Authz 关卡 + 匿名 principal；M3-9 授权矩阵。

(c) 新增「M3 已知非阻塞项 / 显式 defer」节，逐条列本计划「显式不做」清单（跨账户、完整条件算子、identity policy、STS/session token、email grantee、x-amz-grant-* 细粒度、Block Public Access、bucket-owner-*/aws-exec-read/log-delivery-write 仅存名、checksum trailer），标注「文档化，非静默」。

(d) 把「下一步（续作入口）」更新为 M4（versioning/tagging/lifecycle/CORS/SSE）。

提交：

```powershell
git add -A
git commit -m @'
M3-9: end-to-end authorization matrix (authenticated non-owner, named-principal allow, prefix condition, copy-source check) + STATUS update; M3 IAM/policy milestone complete

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) 授权矩阵（认证非 owner 拒绝、命名 principal 放行、prefix 条件、CopyObject 源读二次检查拒绝）全绿；(2) 既有 M0–M2 全部 e2e 回归绿；(3) STATUS 已更新（M3 ✅ + 摘要 + defer 清单 + 下一步 M4）；(4) 零警告、全量绿。

---

## 显式 defer 清单（汇总；文档化，绝不静默）

到达以下任一情形，**返回结构化错误或按文档化降级，绝不静默放行/吞错**：

1. **跨账户 / 多租户所有权**：单租户。`bucket-owner-read`/`bucket-owner-full-control` 仅存 canned 名、按 `private` 评估。`AuthenticatedUsers` = 任意有效签名 principal。
2. **完整条件算子**：仅 `StringEquals`/`StringLike`/`Bool`/`IpAddress`/`DateGreaterThan`。其余算子（含 `NotAction`/`NotResource`/`NotPrincipal` 语义）→ 含该算子的 Condition 块**保守判不成立**（statement 不命中），绝不放行更多权限。
3. **IAM identity policy（user inline policy）**：`Store.principal_policies/1` 恒 `[]`。授权由 bucket policy + ACL 派生 + owner/root 短路驱动。
4. **STS / 临时凭据 / session token**：`X-Amz-Security-Token` 不解析。presigned 仅支持长期 key。
5. **email grantee（AmazonCustomerByEmail）**：→ `400 InvalidArgument`（AWS 已于 2025-10-01 停支）。
6. **explicit `x-amz-grant-*` 头 / 多 grantee 细粒度评估**：PutAcl 收到 `x-amz-grant-*` → 退化为 `private`（不放行更多权限）+ warning。ACL XML round-trip 解析仅分类回最接近 canned。
7. **Block Public Access** 设置 → 未实现。
8. **`aws-exec-read` / `log-delivery-write` canned** → 仅存名不产生公共 statement。
9. **checksum trailer 重算** → 沿用 M2 defer。
10. **CopyObject 之外的双检查动作**：UploadPartCopy 本 MVP 未实现（M2 未做），不涉及。
11. **DeleteObjects 逐 key 细粒度授权**：用桶级 `s3:DeleteObject` 作粗粒度门；逐 key 检查 defer。
12. **secret at-rest 加密**：MVP 明文存储（COMMENT 已标）；信封加密留后续，仅改 EctoStore 读写两点。

---

## 新增/修改文件清单（M3 全量）

**新增**：
- `lib/maxio/policy/arn.ex`、`statement.ex`、`request_context.ex`、`condition.ex`、`evaluator.ex`、`acl.ex`、`action_map.ex`（M3-2/3/7/8）
- `lib/maxio/policy/store.ex`（behaviour）、`store/ecto_store.ex`、`bucket_policy.ex`（M3-5）
- `lib/maxio/iam.ex`、`iam/access_key.ex`、`auth/credential_store/ecto_store.ex`（M3-4）
- `lib/mix/tasks/maxio.iam.create_key.ex`、`maxio.iam.list_keys.ex`、`maxio.iam.delete_key.ex`（M3-4）
- `lib/maxio/s3/handlers/bucket_policy.ex`、`acl.ex`（M3-6/7）
- `lib/maxio/s3/views/access_control_policy.ex`、`request_parsers/access_control_policy.ex`（M3-7）
- `lib/maxio/s3/authz.ex`（M3-8）
- 迁移：`create_access_keys`（M3-4）、`create_bucket_policies`（M3-5）、`add_acl_to_buckets_and_objects`（M3-7）
- 测试：`copy_self_test.exs`、`conditional_subsecond_test.exs`（M3-1）；`policy/{arn,statement,request_context,condition,evaluator,acl,action_map,store}_test.exs`；`iam_test.exs`；`s3/{bucket_policy,acl,authz,authz_matrix}_test.exs`

**修改**：
- `lib/maxio/s3/handlers/object.ex`（自拷贝修复 + PutObject x-amz-acl）
- `lib/maxio/multipart.ex`（去重 abort）
- `lib/maxio/s3/conditional.ex`（秒截断）
- `lib/maxio/s3/error.ex`（malformed_policy + no_such_bucket_policy）
- `lib/maxio/s3/dispatcher.ex`（policy / acl 分发，移出 @m2_subresources）
- `lib/maxio/s3/handlers.ex`（BucketPolicy/Acl 分发接线）
- `lib/maxio/s3/plugs/sigv4.ex`（匿名 principal）
- `lib/maxio/s3/plugs/dispatch.ex`（Authz 接线）
- `lib/maxio/buckets.ex` + `buckets/bucket.ex`（acl_canned + put_acl）
- `lib/maxio/objects.ex` + `objects/object.ex`（acl_canned + put_acl）
- `lib/maxio/s3/handlers/bucket.ex`（CreateBucket x-amz-acl）
- `lib/maxio/application.ex`（root 引导）
- `config/config.exs`（credential_store→EctoStore、policy_store→EctoStore）+ `config/test.exs`（credential_store→MemoryStore）
- `test/support/sigv4_request.ex`（anon_conn + 自定义 access_key/secret）

---

## 命名一致性检查清单（executor 落地前自查）

- principal map 形态严格沿用既有：`%{type: :root | :iam_user, access_key, arn}`；匿名统一 `:anonymous`（原子，非 map）。
- 资源 ARN 一律经 `Maxio.Policy.Arn.{bucket_arn,object_arn,account_arn}/*` 构造，绝不手拼。
- glob 匹配一律经 `Maxio.Policy.Arn.glob_match?/3`（Action `case_insensitive: true`，Resource 默认大小写敏感）。
- Evaluator 返回严格 `:allow | {:deny, :explicit_deny | :implicit_deny}`，调用方只区分 allow/deny。
- 错误码原子用既有 `Maxio.S3.Error.new/2`（新增 `:malformed_policy`/`:no_such_bucket_policy`，AccessDenied 用既有 `:access_denied`）。
- XML 出站一律经 `Maxio.S3.XML.{encode/1,namespace/0}` + `Saxy.XML.element/3`（与既有 view 一致）。
- 凭据/策略后端经 behaviour 门面派发（`CredentialStore.impl/0`、`Store.impl/0`），换后端只改 config。
- 所有新表/列/索引带中文 `COMMENT`（Ecto `comment:` 选项）。
- 每条 mix 命令前已设 `$env:Path` + `$env:ERL_FLAGS`。
- 每单元一次 commit，footer 固定 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。
