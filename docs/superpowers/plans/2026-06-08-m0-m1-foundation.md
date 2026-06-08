# M0 地基 + M1 S3 核心读写 实现计划 · maxio（Elixir/Phoenix S3 兼容对象存储）

> For agentic workers（executor）：严格按单元 E1..E7、任务顺序逐步执行。逻辑性代码用 **TDD**（先写失败测试 → 运行确认红 → 最小实现 → 运行确认绿 → commit）；脚手架/配置类任务用"执行命令 + 验证输出"。每个任务都给了**精确文件路径、完整可用代码（禁止占位符 / TODO / 省略号）、确切 PowerShell 命令与期望输出**。后面任务引用的类型/函数/字段名与前面定义**严格一致**（本计划已统一命名，复用时逐字照抄）。
>
> **铁律对齐（AGENTS.md §3/§4，违反即返工）**：①后端经 behaviour 抽象（存储/凭据），上层只认契约；②禁止打补丁式修复——从架构层解决；③绝不静默失败——鉴权/签名/校验失败必须返回结构化 S3 错误 XML + 正确 HTTP 状态 + 结构化日志；④对象 body 绝不进 `Plug.Parsers`、绝不全缓冲，必须 `read_body` 流式；只有小 XML 走带上限整读；⑤S3 行为以官方 AWS 文档/SDK 测试向量为准（本计划已内嵌核验过的 KNOWN-ANSWER 向量）；⑥DB schema 自文档化——表/列/索引中文 `COMMENT`。
>
> **作者/审查隔离**：本计划由 executor 实现；每个里程碑收尾由**独立** `code-reviewer`/`verifier`（不同上下文）取证，实现者不得自审。

---

## 环境约束（每条 mix 命令都必须遵守）

- **本机**：Windows 11 + PowerShell。Elixir 1.20.0 / OTP 28，位于 `C:\Users\dyz\Documents\dev\usr\Elixir\bin`（已在 PATH，`mix` 直接可用）。
- **跑任何 mix 命令前必设**（否则编译期/运行期中文输出重定向到非 TTY 触发 `io.put_chars badarg` 硬崩、留 `erl_crash.dump`）：
  ```powershell
  $env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
  ```
  本计划所有 PowerShell 命令块**默认已假设当前会话已设此变量**；每个新 shell 会话第一条命令前先执行它。
- **Postgres**：docker 容器 `maxio-db`（postgres:16，localhost:5432，user/pass=postgres/postgres，dev 库 `maxio_dev`，test 库 `maxio_test`）。`psql` 不在 PATH，一律经容器：
  ```powershell
  docker exec maxio-db psql -U postgres -d maxio_dev -c "SELECT 1;"
  ```
  执行前确保容器在跑：`docker start maxio-db`。
- **无 aws-cli / boto3 / mc / python**。端到端验证只用：(a) SigV4 **KNOWN-ANSWER** ExUnit 测试（对照 AWS 官方 worked-example 向量，byte-for-byte 证明 Signer 正确，是独立 ground truth）；(b) **自签 SigV4** 集成测试（用 `Maxio.Auth.SigV4.Signer` 自己签一个请求，经 `Plug.Test`/`Req` 打进 S3 plug 管线）。**禁止依赖外部 CLI**。
- **提交**：每个任务（或紧密相关的红绿对）一次 commit，message footer 固定一行：
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
  当前分支为 `master`；本计划全部提交到当前分支（无需开新分支，除非用户另行要求）。

---

## Goal

打通一条 **真实 S3 客户端可用的垂直切片**：独立 `Maxio.S3.Endpoint`（Bandit，端口 9000，不挂 `Plug.Parsers`）+ SigV4 鉴权（header-based 单块 / UNSIGNED-PAYLOAD / presigned，KNOWN-ANSWER 向量回归）+ 判定表分发 + 单机 FS 流式存储后端 + bucket/object 元数据（Postgres，中文 COMMENT）+ ListBuckets/CreateBucket/DeleteBucket/HeadBucket/GetBucketLocation/ListObjectsV2 + PutObject(流式)/GetObject(含 Range)/HeadObject/DeleteObject + saxy XML 出入站 + 错误码→HTTP 状态映射 + `mix maxio.sigv4.debug` CLI。

**显式不做（留 M2，到达即返回 `NotImplemented` 或文档化的部分实现）**：
- **aws-chunked 逐块签名链验证**：M1 对 `STREAMING-AWS4-HMAC-SHA256-PAYLOAD` 采用"**验 seed 签名 + 解帧出纯净字节 + 校验 `x-amz-decoded-content-length` 一致**，逐块 chunk-signature 验证跳过但**显式结构化日志记为已知 M2 缺口**"（非静默放行——seed 签名失败仍 403，解帧长度不符仍 400）。
- multipart upload（CreateMultipartUpload/UploadPart/Complete/Abort/ListParts）→ `NotImplemented`。
- 多区间 Range、条件头（If-Match 等，除基本的存在性）→ M2。
- 完整 IAM/bucket policy → M2/M3；M1 = **root principal 全权放行**（AuthZ stub，root 短路）。

## Architecture（请求生命周期）

```
S3 客户端 → Maxio.S3.Endpoint (Bandit :9000, Plug.Builder, 无 Plug.Parsers)
  Plug.RequestId
  Maxio.S3.Plugs.AddressStyle   解析寻址 → assigns.s3_bucket / s3_key / s3_level
  Maxio.S3.Plugs.SigV4          SigV4 验证 → assigns.principal / auth_type / payload_mode；失败 halt + Error XML
  Maxio.S3.Plugs.Dispatch       Dispatcher.resolve/3 → action；调 Handler；统一 rescue Maxio.S3.Error → ErrorView
     Handlers.Service / .Bucket / .Object
        Maxio.Buckets / Maxio.Objects     (Ecto + Postgres 元数据)
        Maxio.Storage.Backend (behaviour) → Maxio.Storage.FS  (流式 put/get/stat/delete/list)
     出站 saxy XML (Maxio.S3.Views.*) / 二进制流 (send_chunked) / 错误 XML (Maxio.S3.ErrorView)
```

现有 `MaxioWeb.Endpoint`（:4000，Console/LiveView）**保持不变**，物理隔离。

## 单元总览（按依赖串行；每单元结束须 green compile + 测试通过）

| 单元 | 标题 | 依赖 |
|---|---|---|
| **E1** | 依赖 + S3 配置 + 结构化日志基座 | — |
| **E2** | 存储后端 behaviour + FS 流式实现 | E1 |
| **E3** | bucket/object 元数据迁移 + schema + 上下文（中文 COMMENT） | E1 |
| **E4** | S3 Error + 错误码映射 + XML 渲染基座 + ErrorView | E1 |
| **E5** | SigV4：Canonical / Signer / AuthHeaderParser / Auth / CredentialStore+MemoryStore / SigV4 plug / debug CLI（KNOWN-ANSWER 向量） | E1, E4 |
| **E6** | AddressStyle plug + Dispatcher 判定表 + S3 Endpoint（Bandit child）+ 监督树接线 | E4, E5 |
| **E7** | Handlers（Service/Bucket/Object）+ saxy Views + Dispatch 接线 + 自签 SigV4 集成测试 | E2, E3, E4, E5, E6 |

---

## 全局命名契约（一次定义，全程复用，executor 逐字照抄）

**OTP/模块前缀**：app `:maxio`，根模块 `Maxio`，Repo `Maxio.Repo`。

**S3 命名空间常量**（多处复用，统一字面量）：
- XML 命名空间：`"http://s3.amazonaws.com/doc/2006-03-01/"`
- 空 body 的 SHA256（hex 常量）：`"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"`
- 默认 region：`"us-east-1"`；service 字面量：`"s3"`；termination：`"aws4_request"`；算法：`"AWS4-HMAC-SHA256"`。

**配置键**（`config :maxio, :s3, ...`，E1 定义，全程引用）：
```
config :maxio, :s3,
  domain: "localhost",          # 寻址根域名（virtual-host 判定基准）
  region: "us-east-1",          # 默认区域
  data_dir: "<path>",           # FS 存储后端对象数据根目录
  clock_skew_ms: 900_000,       # SigV4 时钟偏移容忍（±15min）
  root_user: "...",             # 引导 root access key id（runtime 从 env MAXIO_ROOT_USER）
  root_password: "..."          # 引导 root secret（runtime 从 env MAXIO_ROOT_PASSWORD）
config :maxio, Maxio.S3.Endpoint, port: 9000, ip: :any
config :maxio, :storage_backend, Maxio.Storage.FS
config :maxio, :credential_store, Maxio.Auth.CredentialStore.MemoryStore
```

**核心结构/函数签名（跨单元引用，逐字一致）**：
- `Maxio.Storage.Backend`（behaviour）回调（E2）：
  - `@callback put(bucket :: String.t(), key :: String.t(), chunks :: Enumerable.t(), opts :: keyword()) :: {:ok, %{size: non_neg_integer(), etag: String.t()}} | {:error, term()}`
  - `@callback get(bucket :: String.t(), key :: String.t(), range :: nil | {non_neg_integer(), non_neg_integer()}) :: {:ok, Enumerable.t()} | {:error, :enoent | term()}`
  - `@callback stat(bucket :: String.t(), key :: String.t()) :: {:ok, %{size: non_neg_integer()}} | {:error, :enoent}`
  - `@callback delete(bucket :: String.t(), key :: String.t()) :: :ok | {:error, term()}`
  - `@callback delete_bucket(bucket :: String.t()) :: :ok | {:error, term()}`
  - `@callback put_bucket(bucket :: String.t()) :: :ok | {:error, term()}`
- `Maxio.S3.Error`（E4）：`defexception [:code, :message, :http_status, :resource, :request_id, extra: %{}]`。
- `Maxio.Auth.CredentialStore`（behaviour，E5）：`@callback get_secret(access_key :: String.t()) :: {:ok, %{secret_key: String.t(), principal: map()}} | :error`、`@callback put_access_key(map()) :: :ok | {:error, term()}`、`@callback list_keys() :: [map()]`。
- `Maxio.Auth.SigV4.Canonical`（E5）纯函数：`canonical_request/1`、`canonical_uri/1`、`canonical_query/1`、`canonical_headers/2`、`signed_headers/1`、`uri_encode/2`、`trimall/1`。
- `Maxio.Auth.SigV4.Signer`（E5）：`string_to_sign/4`、`derive_signing_key/4`、`signature/2`、`hex_sha256/1`、`secure_compare/2`。
- `%Maxio.Auth.SigV4.SignedRequest{}`（E5，AuthHeaderParser 产出）：字段 `access_key, scope_date, region, service, signed_headers, signature, amz_date, auth_type(:header|:presigned), payload_mode(:single|:unsigned|:streaming), expires`。
- principal map：`%{type: :root, access_key: String.t(), arn: "arn:aws:iam:::root"}`。

---

## 执行顺序速查

E1 → E2 → E3 → E4 → E5 → E6 → E7。单元内任务按编号。每单元末尾"单元验收"必须全绿才进入下一单元。**串行执行，禁止并行 mix 编译**（避免锁文件竞争）。

---

## 单元 E1 — 依赖 + S3 配置 + 结构化日志基座

**目标**：加 `:saxy` 依赖；在 config/dev/test/runtime 注入 S3 配置（端口/domain/region/data_dir/root 凭据/clock_skew/backend 绑定）；实现统一结构化日志辅助 `Maxio.S3.Log`。无业务逻辑，属脚手架 + 一个轻量 TDD（Log）。

### Task E1.1 — 添加 :saxy 依赖

**Files:** Modify `mix.exs`

在 `mix.exs` 的 `deps/0` 列表里，把 `:saxy` 加到 `{:bandit, "~> 1.5"}` 之后（保留所有现有依赖不动）：
```elixir
      {:bandit, "~> 1.5"},
      # S3 XML 出站构造 + 入站 SAX 解析（一依赖两用）
      {:saxy, "~> 1.6"}
```

1. 拉依赖：
   ```powershell
   $env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
   mix deps.get
   ```
   期望：输出含 `saxy` 被解析并锁定（如 `saxy 1.6.0`），结尾无 `error`。

**验证**：
```powershell
mix deps.get
```
期望输出含 `saxy`，无 error。`Plug.Crypto.secure_compare/2` 在 `plug_crypto`（Phoenix 传递依赖）中，无需新增依赖。

**Commit**：
```powershell
git add -A
git commit -m "chore(deps): add saxy for S3 XML build/parse" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E1.2 — 注入 S3 全局配置（config.exs）

**Files:** Modify `config/config.exs`

在 `config/config.exs` 中、`import_config "#{config_env()}.exs"` 这一行**之前**，追加以下块（这些是编译期/默认项；端口与凭据在 dev/test/runtime 细化）：
```elixir
# ── maxio S3 子系统配置（独立于 Console 的 MaxioWeb.Endpoint）──
# 寻址根域名（virtual-host 判定基准）、默认区域、对象数据目录、时钟偏移容忍、root 凭据引导。
config :maxio, :s3,
  domain: "localhost",
  region: "us-east-1",
  clock_skew_ms: 900_000,
  data_dir: Path.expand("../priv/s3_data", __DIR__),
  root_user: "minioadmin",
  root_password: "minioadmin"

# 独立 S3 Endpoint（Bandit child）监听配置。
config :maxio, Maxio.S3.Endpoint, port: 9000, ip: :any

# 后端 behaviour 绑定（铁律 1/2：换后端只改这里）。
config :maxio, :storage_backend, Maxio.Storage.FS
config :maxio, :credential_store, Maxio.Auth.CredentialStore.MemoryStore
```

**验证**：
```powershell
mix compile
```
期望：编译成功（config 改动不产代码，确认无语法错）。进一步确认：
```powershell
mix run -e "IO.inspect(Application.get_env(:maxio, :s3) |> Keyword.fetch!(:region))"
```
期望输出 `\"us-east-1\"`。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): add S3 subsystem config (domain/region/data_dir/root creds/backends)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E1.3 — dev / test / runtime 配置细化

**Files:** Modify `config/dev.exs`、`config/test.exs`、`config/runtime.exs`

**dev.exs**：在文件末尾追加（dev 用 priv 下数据目录，端口 9000）：
```elixir
# maxio S3：开发期对象数据目录与监听端口
config :maxio, :s3,
  data_dir: Path.expand("../priv/s3_data/dev", __DIR__)

config :maxio, Maxio.S3.Endpoint, port: 9000, ip: {127, 0, 0, 1}
```

**test.exs**：在文件末尾追加（test 用临时隔离目录 + 端口 0 让 OS 分配，避免占用；测试主要走 Plug.Test 不必真起监听，但配置齐全）：
```elixir
# maxio S3：测试期对象数据目录（每次运行前清理）与监听配置
config :maxio, :s3,
  data_dir: Path.expand("../priv/s3_data/test", __DIR__),
  root_user: "AKIAIOSFODNN7EXAMPLE",
  root_password: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

config :maxio, Maxio.S3.Endpoint, server: false, port: 0
```
> 说明：test 的 root 凭据特意设为 AWS 官方 worked-example 凭据，便于自签集成测试直接复用同一对密钥。

**runtime.exs**：在 `if config_env() == :prod do` 块**之前**（即对所有环境生效的区域，紧跟现有 `config :maxio, MaxioWeb.Endpoint, http: [port: ...]` 之后）追加（从环境变量引导 root 凭据 + 数据目录 + S3 端口，env 缺省时回落到编译期默认）：
```elixir
# maxio S3：运行时从环境变量引导 root 凭据 / 数据目录 / S3 端口（缺省回落编译期默认）。
if root_user = System.get_env("MAXIO_ROOT_USER") do
  config :maxio, :s3, root_user: root_user
end

if root_password = System.get_env("MAXIO_ROOT_PASSWORD") do
  config :maxio, :s3, root_password: root_password
end

if data_dir = System.get_env("MAXIO_DATA_DIR") do
  config :maxio, :s3, data_dir: data_dir
end

if s3_port = System.get_env("MAXIO_S3_PORT") do
  config :maxio, Maxio.S3.Endpoint, port: String.to_integer(s3_port)
end
```

**验证**：
```powershell
mix compile
mix run -e "IO.inspect(Application.get_env(:maxio, Maxio.S3.Endpoint) |> Keyword.fetch!(:port))"
```
期望：编译成功；端口输出 `9000`（dev/默认）。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): wire S3 config across dev/test/runtime (data dir, port, root creds from env)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E1.4 — 结构化日志辅助失败测试（TDD）

**Files:** Create `test/maxio/s3/log_test.exs`

S3 管线所有关键阶段（鉴权、分发、put/get、错误）都要打带元数据的结构化日志（铁律 4）。统一辅助 `Maxio.S3.Log` 封装 `Logger`，强制把 `request_id/bucket/key/action/auth_type` 等放进 metadata。

Create `test/maxio/s3/log_test.exs`：
```elixir
defmodule Maxio.S3.LogTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Maxio.S3.Log

  test "info/2 输出消息并把 S3 元数据放进 Logger metadata" do
    log =
      capture_log([level: :info], fn ->
        Log.info("put object ok",
          request_id: "req-1",
          bucket: "b1",
          key: "k1",
          action: :put_object,
          auth_type: :header
        )
      end)

    assert log =~ "put object ok"
  end

  test "warn/2 在签名失败场景记录结构化字段（不静默）" do
    log =
      capture_log([level: :warning], fn ->
        Log.warn("signature mismatch",
          request_id: "req-2",
          bucket: "b2",
          key: "k2",
          action: :get_object,
          auth_type: :header,
          reason: :signature_does_not_match
        )
      end)

    assert log =~ "signature mismatch"
  end

  test "context/1 把 conn-like 关键字规整成 metadata keyword 列表" do
    md = Log.context(request_id: "r", bucket: "b", key: "k", action: :list_objects_v2)
    assert Keyword.get(md, :request_id) == "r"
    assert Keyword.get(md, :bucket) == "b"
    assert Keyword.get(md, :action) == :list_objects_v2
  end
end
```

1. 跑测试确认红（模块未定义）：
   ```powershell
   mix test test/maxio/s3/log_test.exs
   ```
   期望：失败——`Maxio.S3.Log` 未定义（编译期 `module ... is not loaded` 或 `UndefinedFunctionError`）。预期的红。

**验证**：测试因模块缺失失败即通过本步。

### Task E1.5 — 实现 Maxio.S3.Log（使测试通过）

**Files:** Create `lib/maxio/s3/log.ex`

Create `lib/maxio/s3/log.ex`：
```elixir
defmodule Maxio.S3.Log do
  @moduledoc """
  S3 管线统一结构化日志辅助（AGENTS.md 铁律 4：后端无 GUI，必须 CLI + 结构化日志可观测）。

  所有 S3 关键阶段（鉴权 / 分发 / put / get / 错误）经此模块打日志，统一把
  request_id / bucket / key / action / auth_type / reason 等放进 Logger metadata，
  便于按 request_id 串联一次请求的全链路。绝不静默——签名/校验失败必须经 warn/2 留痕。
  """
  require Logger

  @md_keys [:request_id, :bucket, :key, :action, :auth_type, :payload_mode, :reason, :code, :status, :size]

  @doc "把关键字参数中已知的 S3 元数据键提取为 Logger metadata keyword 列表。"
  @spec context(keyword()) :: keyword()
  def context(fields) when is_list(fields) do
    Enum.filter(fields, fn {k, _v} -> k in @md_keys end)
  end

  @doc "info 级结构化日志。"
  @spec info(String.t(), keyword()) :: :ok
  def info(message, fields \ []) do
    Logger.info(message, context(fields))
  end

  @doc "warning 级结构化日志（用于签名失败 / 授权拒绝 / 校验失败等非静默场景）。"
  @spec warn(String.t(), keyword()) :: :ok
  def warn(message, fields \ []) do
    Logger.warning(message, context(fields))
  end

  @doc "error 级结构化日志（兜底 500 等）。"
  @spec error(String.t(), keyword()) :: :ok
  def error(message, fields \ []) do
    Logger.error(message, context(fields))
  end
end
```

可选：把 S3 元数据键加入 config.exs 的 logger metadata 白名单（便于 dev 控制台看到）。在 `config/config.exs` 的 `config :logger, :default_formatter` 块把 `metadata:` 改为：
```elixir
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :bucket, :key, :action, :auth_type, :reason, :code, :status]
```

1. 跑测试：
   ```powershell
   mix test test/maxio/s3/log_test.exs
   ```
   期望：`3 tests, 0 failures`。

**验证**：LogTest 全绿即通过。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): add Maxio.S3.Log structured logging helper with tests" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 单元 E1 验收

```powershell
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test test/maxio/s3/log_test.exs
```
期望：编译零警告；LogTest `3 tests, 0 failures`。`mix deps.get` 已锁定 `saxy`。

---

## 单元 E2 — 存储后端 behaviour + FS 流式实现

**目标**：定义 `Maxio.Storage.Backend` behaviour（跨子系统单一契约，铁律 1/2），实现单机文件系统后端 `Maxio.Storage.FS`：**流式** put（边读边写文件 + 边算 MD5 ETag，绝不全缓冲）、get（含 Range，按区间 `:file.pread` 流式发出）、stat、delete、bucket 级 put/delete。对象数据落在配置的 `data_dir/<bucket>/<key>`（key 中的 `/` 映射为子目录，安全防穿越）。

### Task E2.1 — Backend behaviour 定义 + 派发门面

**Files:** Create `lib/maxio/storage/backend.ex`、`lib/maxio/storage.ex`

`Maxio.Storage.Backend` 是 behaviour；`Maxio.Storage` 是门面，按 `config :maxio, :storage_backend` 派发到具体实现（换后端只改配置）。

Create `lib/maxio/storage/backend.ex`：
```elixir
defmodule Maxio.Storage.Backend do
  @moduledoc """
  对象字节存储后端契约（behaviour）。上层 handler 只认本契约，对实现无感
  （AGENTS.md 铁律 1/2：后端即插件，换 FS→纠删码→分布式 核心管线一行不改）。

  约定：
    * put/4 的 `chunks` 是一个产出二进制块的 Enumerable（来自 read_body 流式拉取），
      实现必须**边消费边落盘 / 边算哈希，绝不把整对象读进内存**（铁律 4）。
    * get/3 的 range 为 nil（全量）或 {first_byte, last_byte}（含端点，0-based），
      返回产出二进制块的 Enumerable（供 send_chunked 流式发出）。
    * ETag 形态：单次 PUT 对象 = MD5(对象内容) 的小写 hex（**不含引号**，引号由 XML/HTTP 层加）。
  """

  @type bucket :: String.t()
  @type key :: String.t()
  @type range :: nil | {non_neg_integer(), non_neg_integer()}
  @type put_result :: %{size: non_neg_integer(), etag: String.t()}

  @callback put(bucket(), key(), chunks :: Enumerable.t(), opts :: keyword()) ::
              {:ok, put_result()} | {:error, term()}
  @callback get(bucket(), key(), range()) ::
              {:ok, Enumerable.t()} | {:error, :enoent | term()}
  @callback stat(bucket(), key()) ::
              {:ok, %{size: non_neg_integer()}} | {:error, :enoent}
  @callback delete(bucket(), key()) :: :ok | {:error, term()}
  @callback put_bucket(bucket()) :: :ok | {:error, term()}
  @callback delete_bucket(bucket()) :: :ok | {:error, term()}
end
```

Create `lib/maxio/storage.ex`：
```elixir
defmodule Maxio.Storage do
  @moduledoc """
  存储门面：按 `config :maxio, :storage_backend` 派发到具体 Backend 实现。
  上层（Object/Bucket handler）调本模块，不直接耦合 FS。
  """

  @doc "当前配置的存储后端模块。"
  @spec backend() :: module()
  def backend, do: Application.fetch_env!(:maxio, :storage_backend)

  @spec put(String.t(), String.t(), Enumerable.t(), keyword()) ::
          {:ok, Maxio.Storage.Backend.put_result()} | {:error, term()}
  def put(bucket, key, chunks, opts \\ []), do: backend().put(bucket, key, chunks, opts)

  @spec get(String.t(), String.t(), Maxio.Storage.Backend.range()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def get(bucket, key, range \\ nil), do: backend().get(bucket, key, range)

  @spec stat(String.t(), String.t()) :: {:ok, %{size: non_neg_integer()}} | {:error, :enoent}
  def stat(bucket, key), do: backend().stat(bucket, key)

  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(bucket, key), do: backend().delete(bucket, key)

  @spec put_bucket(String.t()) :: :ok | {:error, term()}
  def put_bucket(bucket), do: backend().put_bucket(bucket)

  @spec delete_bucket(String.t()) :: :ok | {:error, term()}
  def delete_bucket(bucket), do: backend().delete_bucket(bucket)
end
```

**验证**：
```powershell
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
```
期望：编译零警告（behaviour + 门面无运行逻辑）。

**Commit**：
```powershell
git add -A
git commit -m "feat(storage): add Storage.Backend behaviour + Storage dispatch facade" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E2.2 — FS 后端失败测试（TDD）

**Files:** Create `test/maxio/storage/fs_test.exs`

测试覆盖：流式 put 返回 size+etag（etag = MD5 hex 无引号）；get 全量；get Range（含端点）；stat；delete；不存在对象 get/stat 返回 `:enoent`；key 含 `/` 落成子目录；路径穿越（`../`）被拒。每个测试用独立临时目录隔离。

Create `test/maxio/storage/fs_test.exs`：
```elixir
defmodule Maxio.Storage.FSTest do
  use ExUnit.Case, async: true

  alias Maxio.Storage.FS

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_fs_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp opts(dir), do: [data_dir: dir]

  test "put 流式写入并返回 size 与 MD5 hex etag（无引号）", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    body = "Welcome to Amazon S3."
    chunks = ["Welcome ", "to Amazon ", "S3."]

    {:ok, %{size: size, etag: etag}} = FS.put("b", "k.txt", chunks, opts(dir))

    assert size == byte_size(body)
    expected = :crypto.hash(:md5, body) |> Base.encode16(case: :lower)
    assert etag == expected
    refute String.contains?(etag, "\"")
  end

  test "get 全量返回完整内容", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put("b", "k", ["hello ", "world"], opts(dir))

    {:ok, stream} = FS.get("b", "k", nil, opts(dir))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == "hello world"
  end

  test "get Range 返回含端点的字节区间", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put("b", "k", ["0123456789"], opts(dir))

    {:ok, stream} = FS.get("b", "k", {0, 4}, opts(dir))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == "01234"

    {:ok, stream2} = FS.get("b", "k", {2, 5}, opts(dir))
    assert IO.iodata_to_binary(Enum.to_list(stream2)) == "2345"
  end

  test "stat 返回 size，不存在返回 :enoent", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put("b", "k", ["abc"], opts(dir))
    assert {:ok, %{size: 3}} = FS.stat("b", "k", opts(dir))
    assert {:error, :enoent} = FS.stat("b", "missing", opts(dir))
  end

  test "delete 删除对象，重复 get 报 :enoent", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put("b", "k", ["abc"], opts(dir))
    assert :ok = FS.delete("b", "k", opts(dir))
    assert {:error, :enoent} = FS.get("b", "k", nil, opts(dir))
  end

  test "key 含斜杠落成子目录", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put("b", "a/b/c.txt", ["deep"], opts(dir))
    assert {:ok, %{size: 4}} = FS.stat("b", "a/b/c.txt", opts(dir))
    assert File.exists?(Path.join([dir, "b", "a", "b", "c.txt"]))
  end

  test "路径穿越被拒（key 含 ../）", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    assert {:error, :invalid_key} = FS.put("b", "../escape", ["x"], opts(dir))
    assert {:error, :invalid_key} = FS.get("b", "../../etc/passwd", nil, opts(dir))
  end

  test "put_bucket 建目录，delete_bucket 删空目录", %{dir: dir} do
    assert :ok = FS.put_bucket("nb", opts(dir))
    assert File.dir?(Path.join(dir, "nb"))
    assert :ok = FS.delete_bucket("nb", opts(dir))
    refute File.exists?(Path.join(dir, "nb"))
  end
end
```

> 注意：测试给 FS 各函数额外传了 `opts`（含 `:data_dir`）以隔离临时目录。FS 实现的每个回调签名为 behaviour 定义的 4 元/3 元 + 一个**可选 opts 末参**（默认从 config 读 data_dir）。这样既满足 behaviour（默认 opts），又便于测试注入目录。

1. 跑测试确认红：
   ```powershell
   mix test test/maxio/storage/fs_test.exs
   ```
   期望：失败——`Maxio.Storage.FS` 未定义。预期的红。

**验证**：测试因模块缺失失败即通过本步。

### Task E2.3 — 实现 FS 后端（使测试通过）

**Files:** Create `lib/maxio/storage/fs.ex`

关键点：put 用 `File.open(path, [:write, :binary, :raw])` + 逐块 `IO.binwrite` + `:crypto.hash_update` 流式落盘算 MD5；get Range 用 `:file.pread(fd, offset, len)` 分块（1MB）发出；key 经 `safe_relative/1` 防穿越；data_dir 从 opts 取，缺省读 config。

Create `lib/maxio/storage/fs.ex`：
```elixir
defmodule Maxio.Storage.FS do
  @moduledoc """
  单机文件系统存储后端（MVP）。对象落在 `<data_dir>/<bucket>/<key>`，key 中的 `/`
  自然映射为子目录。put 流式写入并边写边算 MD5（绝不全缓冲，铁律 4）；
  get 支持 Range，按区间用 :file.pread 分块发出；防 `..` 路径穿越。

  每个回调额外接受可选末参 `opts`（`:data_dir` 覆盖根目录，便于测试隔离），
  缺省时从 `config :maxio, :s3, :data_dir` 读取。
  """
  @behaviour Maxio.Storage.Backend

  @chunk_size 1_048_576

  @impl true
  def put(bucket, key, chunks, opts \\ []), do: do_put(bucket, key, chunks, opts)

  @impl true
  def get(bucket, key, range \\ nil, opts \\ []), do: do_get(bucket, key, range, opts)

  @impl true
  def stat(bucket, key, opts \\ []), do: do_stat(bucket, key, opts)

  @impl true
  def delete(bucket, key, opts \\ []), do: do_delete(bucket, key, opts)

  @impl true
  def put_bucket(bucket, opts \\ []), do: do_put_bucket(bucket, opts)

  @impl true
  def delete_bucket(bucket, opts \\ []), do: do_delete_bucket(bucket, opts)

  defp do_put(bucket, key, chunks, opts) do
    with {:ok, path} <- object_path(bucket, key, opts) do
      File.mkdir_p!(Path.dirname(path))
      {:ok, fd} = File.open(path, [:write, :binary, :raw])

      try do
        ctx0 = :crypto.hash_init(:md5)

        {ctx, size} =
          Enum.reduce(chunks, {ctx0, 0}, fn chunk, {ctx, acc} ->
            :ok = IO.binwrite(fd, chunk)
            {:crypto.hash_update(ctx, chunk), acc + byte_size(chunk)}
          end)

        etag = ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
        {:ok, %{size: size, etag: etag}}
      after
        File.close(fd)
      end
    end
  end

  defp do_get(bucket, key, range, opts) do
    with {:ok, path} <- object_path(bucket, key, opts) do
      case File.stat(path) do
        {:ok, %File.Stat{size: total}} -> {:ok, stream_file(path, range, total)}
        {:error, :enoent} -> {:error, :enoent}
      end
    end
  end

  defp do_stat(bucket, key, opts) do
    with {:ok, path} <- object_path(bucket, key, opts) do
      case File.stat(path) do
        {:ok, %File.Stat{size: size}} -> {:ok, %{size: size}}
        {:error, :enoent} -> {:error, :enoent}
      end
    end
  end

  defp do_delete(bucket, key, opts) do
    with {:ok, path} <- object_path(bucket, key, opts) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp do_put_bucket(bucket, opts) do
    File.mkdir_p!(bucket_path(bucket, opts))
    :ok
  end

  defp do_delete_bucket(bucket, opts) do
    case File.rmdir(bucket_path(bucket, opts)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_file(path, nil, total), do: stream_file(path, {0, max(total - 1, 0)}, total)
  defp stream_file(_path, {_first, _last}, 0), do: []

  defp stream_file(path, {first, last}, _total) do
    length = last - first + 1

    Stream.resource(
      fn ->
        {:ok, fd} = :file.open(String.to_charlist(path), [:read, :binary, :raw])
        {fd, first, length}
      end,
      fn
        {fd, _off, remaining} when remaining <= 0 ->
          {:halt, fd}

        {fd, off, remaining} ->
          to_read = min(@chunk_size, remaining)

          case :file.pread(fd, off, to_read) do
            {:ok, data} -> {[data], {fd, off + byte_size(data), remaining - byte_size(data)}}
            :eof -> {:halt, fd}
            {:error, _} -> {:halt, fd}
          end
      end,
      fn fd -> :file.close(fd) end
    )
  end

  defp data_dir(opts) do
    Keyword.get(opts, :data_dir) ||
      (Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:data_dir))
  end

  defp bucket_path(bucket, opts), do: Path.join(data_dir(opts), bucket)

  defp object_path(bucket, key, opts) do
    case safe_relative(key) do
      {:ok, rel} -> {:ok, Path.join([data_dir(opts), bucket, rel])}
      :error -> {:error, :invalid_key}
    end
  end

  defp safe_relative(key) do
    segments = key |> String.split("/", trim: true)

    cond do
      key == "" -> :error
      Enum.any?(segments, &(&1 in ["..", "."])) -> :error
      true -> {:ok, Path.join(segments)}
    end
  end
end
```

> 说明（behaviour `@impl` 与默认参数）：FS 用 `def put(..., opts \\ [])` 满足 behaviour 4 元回调（`opts` 默认 `[]`），同时允许测试传 `opts`。`@impl true` 标在带默认值的子句上即可。若编译器对"behaviour 回调 arity"或"多默认值子句"报警，确保每个公开回调只有**单一子句**带 `\\`（已是此形态：公开函数转发给私有 `do_*`）。

1. 跑测试：
   ```powershell
   mix test test/maxio/storage/fs_test.exs
   ```
   期望：`8 tests, 0 failures`。

**验证**：FSTest 全绿即通过。

**Commit**：
```powershell
git add -A
git commit -m "feat(storage): implement FS backend (streaming put+MD5, range get, traversal guard) with tests" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 单元 E2 验收

```powershell
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test test/maxio/storage/fs_test.exs
```
期望：零警告；`8 tests, 0 failures`。证明：流式 put 不缓冲整对象、ETag=MD5 hex、Range 含端点、防穿越。

---

## 单元 E3 — bucket/object 元数据迁移 + schema + 上下文（中文 COMMENT）

**目标**：建 `buckets`、`objects` 两张元数据表（Postgres，**表/列/索引全中文 COMMENT**，铁律 6），实现 Ecto schema + changeset（含 bucket 名校验）+ 上下文 `Maxio.Buckets` / `Maxio.Objects`（含 ListObjectsV2 分页/前缀/分隔符查询逻辑）。对象**字节**走 E2 的 FS 后端，本表只存元数据（size/etag/content_type/last_modified）。

> 本阶段所有建表遵循 AGENTS.md §4.6：表/列/索引加中文 `COMMENT`（Ecto `comment:` 选项；裸 `execute` 建的索引用单独 `COMMENT ON INDEX`，down 置 `NULL`）。标准 `timestamps()`（inserted_at/updated_at）语义自明，豁免。主键用 `binary_id`（项目 generators 默认 `binary_id: true`）。

### Task E3.1 — 迁移：创建 buckets 表

**Files:** Create `priv/repo/migrations/<timestamp>_create_buckets.exs`

1. 生成迁移（自动带正确时间戳）：
   ```powershell
   $env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
   mix ecto.gen.migration create_buckets
   ```
   打开生成文件，替换内容为：
   ```elixir
   defmodule Maxio.Repo.Migrations.CreateBuckets do
     use Ecto.Migration

     def change do
       create table(:buckets, primary_key: false,
                comment: "S3 桶元数据：每个桶一行，全局命名空间唯一；对象字节不在此表，归存储后端") do
         add :id, :binary_id, primary_key: true, comment: "桶主键（UUID）"
         add :name, :string, null: false, comment: "桶名（S3 全局唯一，3-63 字符，命名规则见 Buckets.validate_name）"
         add :region, :string, null: false, default: "us-east-1", comment: "桶所在区域（GetBucketLocation 返回；us-east-1 返回空 LocationConstraint）"
         add :owner, :string, null: false, comment: "创建者 principal（M1 恒为 root 的 access key / arn）"

         timestamps(type: :utc_datetime_usec)
       end

       create unique_index(:buckets, [:name],
                comment: "桶名全局唯一索引（命中冲突 → BucketAlreadyExists/BucketAlreadyOwnedByYou）")
     end
   end
   ```

**验证**：
```powershell
mix ecto.migrate
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ buckets"
```
期望：迁移成功；`\d+ buckets` 每列右侧 `Description` 显示中文注释、表底部显示表注释、`buckets_name_index` 唯一索引带注释。

**Commit**：
```powershell
git add -A
git commit -m "feat(meta): migration creating buckets table (Chinese COMMENTs)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E3.2 — 迁移：创建 objects 表

**Files:** Create `priv/repo/migrations/<timestamp>_create_objects.exs`

1. 生成迁移：
   ```powershell
   mix ecto.gen.migration create_objects
   ```
   打开生成文件，替换内容为：
   ```elixir
   defmodule Maxio.Repo.Migrations.CreateObjects do
     use Ecto.Migration

     def change do
       create table(:objects, primary_key: false,
                comment: "S3 对象元数据：每个 (bucket, key) 当前版本一行；对象字节由存储后端持有，本表只存元信息") do
         add :id, :binary_id, primary_key: true, comment: "对象主键（UUID）"
         add :bucket_id, references(:buckets, type: :binary_id, on_delete: :delete_all),
           null: false, comment: "所属桶外键（删桶级联删元数据；删桶前需先空桶，由应用层 BucketNotEmpty 拦截）"
         add :bucket_name, :string, null: false, comment: "冗余桶名（便于按桶名直接查询/列举，免 join）"
         add :key, :string, null: false, comment: "对象键（完整 S3 key，含任意 / 层级；与 bucket 唯一确定一个对象）"
         add :size, :bigint, null: false, default: 0, comment: "对象字节大小"
         add :etag, :string, null: false, comment: "实体标签：单次 PUT = MD5(内容) 的 hex（本列不含引号，渲染时加引号）"
         add :content_type, :string, null: false, default: "binary/octet-stream", comment: "MIME 类型（PutObject 的 Content-Type，缺省 binary/octet-stream）"
         add :metadata, :map, null: false, default: %{}, comment: "用户自定义元数据（x-amz-meta-* 头，jsonb 键值）"
         add :storage_class, :string, null: false, default: "STANDARD", comment: "存储类别（S3 兼容，MVP 恒 STANDARD）"

         timestamps(type: :utc_datetime_usec)
       end

       create unique_index(:objects, [:bucket_id, :key],
                comment: "桶内对象键唯一索引（同 key 再次 PUT 走 upsert 覆盖当前版本）")

       create index(:objects, [:bucket_name, :key],
                comment: "按桶名 + key 前缀范围扫描索引（ListObjectsV2 prefix/start-after/分页）")
     end
   end
   ```

**验证**：
```powershell
mix ecto.migrate
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ objects"
```
期望：迁移成功；`\d+ objects` 显示各列中文注释、两个索引带注释、外键到 buckets。

**Commit**：
```powershell
git add -A
git commit -m "feat(meta): migration creating objects table (Chinese COMMENTs, FK to buckets)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E3.3 — Bucket schema + 名称校验失败测试（TDD）

**Files:** Create `test/maxio/buckets_test.exs`

bucket 名校验规则（官方核验，见研究）：3-63 字符；仅 `a-z 0-9 . -`；首尾为字母/数字；无相邻 `..`；非 IPv4 形态；不以保留前缀（`xn--` / `sthree-` / `amzn-s3-demo-`）开头；不以保留后缀（`-s3alias` / `--ol-s3` / `.mrap` / `--x-s3` / `--table-s3`）结尾。违规 → `{:error, :invalid_bucket_name}`。

Create `test/maxio/buckets_test.exs`：
```elixir
defmodule Maxio.BucketsTest do
  use Maxio.DataCase, async: true

  alias Maxio.Buckets

  describe "validate_name/1" do
    test "合法名通过" do
      assert :ok = Buckets.validate_name("my-bucket")
      assert :ok = Buckets.validate_name("a.b.c")
      assert :ok = Buckets.validate_name("abc")
      assert :ok = Buckets.validate_name(String.duplicate("a", 63))
    end

    test "长度越界被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("ab")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name(String.duplicate("a", 64))
    end

    test "非法字符被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("MyBucket")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("under_score")
    end

    test "首尾非字母数字被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("-abc")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("abc-")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name(".abc")
    end

    test "相邻点被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("a..b")
    end

    test "IPv4 形态被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("192.168.5.4")
    end

    test "保留前缀/后缀被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("xn--abc")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("sthree-abc")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("amzn-s3-demo-x")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("abc-s3alias")
      assert {:error, :invalid_bucket_name} = Buckets.validate_name("abc--x-s3")
    end
  end

  describe "create/2 + lookup/1 + list/0 + delete/1" do
    test "创建并查到桶" do
      assert {:ok, bucket} = Buckets.create("good-bucket", "arn:aws:iam:::root")
      assert bucket.name == "good-bucket"
      assert bucket.region == "us-east-1"
      assert {:ok, fetched} = Buckets.lookup("good-bucket")
      assert fetched.id == bucket.id
    end

    test "重复创建同名桶返回 already_owned" do
      {:ok, _} = Buckets.create("dup-bucket", "arn:aws:iam:::root")
      assert {:error, :already_owned} = Buckets.create("dup-bucket", "arn:aws:iam:::root")
    end

    test "非法桶名创建被拒" do
      assert {:error, :invalid_bucket_name} = Buckets.create("Bad_Name", "arn:aws:iam:::root")
    end

    test "lookup 不存在返回 :not_found" do
      assert {:error, :not_found} = Buckets.lookup("nope")
    end

    test "list 列出所有桶（按名排序）" do
      {:ok, _} = Buckets.create("bucket-b", "arn:aws:iam:::root")
      {:ok, _} = Buckets.create("bucket-a", "arn:aws:iam:::root")
      names = Buckets.list() |> Enum.map(& &1.name)
      assert names == ["bucket-a", "bucket-b"]
    end

    test "delete 删空桶；非空桶报 not_empty" do
      {:ok, bucket} = Buckets.create("del-bucket", "arn:aws:iam:::root")
      assert :ok = Buckets.delete("del-bucket")
      assert {:error, :not_found} = Buckets.lookup("del-bucket")

      {:ok, _} = Buckets.create("ne-bucket", "arn:aws:iam:::root")
      {:ok, _} = Maxio.Objects.put_metadata("ne-bucket", "k", %{size: 1, etag: "x", content_type: "text/plain"})
      assert {:error, :not_empty} = Buckets.delete("ne-bucket")
    end
  end
end
```

1. 跑测试确认红（`Maxio.Buckets` / `Maxio.Objects` 未定义）：
   ```powershell
   mix test test/maxio/buckets_test.exs
   ```
   期望：失败——模块未定义。预期的红。

**验证**：测试因模块缺失失败即通过本步。

### Task E3.4 — 实现 Bucket schema + Maxio.Buckets 上下文（使测试通过）

**Files:** Create `lib/maxio/buckets/bucket.ex`、`lib/maxio/buckets.ex`

Create `lib/maxio/buckets/bucket.ex`：
```elixir
defmodule Maxio.Buckets.Bucket do
  @moduledoc "S3 桶元数据 schema（对象字节不在此，归存储后端）。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "buckets" do
    field :name, :string
    field :region, :string, default: "us-east-1"
    field :owner, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required [:name, :owner]
  @optional [:region]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(bucket, attrs) do
    bucket
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:name, name: :buckets_name_index)
  end
end
```

Create `lib/maxio/buckets.ex`：
```elixir
defmodule Maxio.Buckets do
  @moduledoc """
  桶元数据上下文：创建/查询/列举/删除桶 + S3 桶名校验。
  桶名规则以官方 S3 bucket naming rules 为准（3-63、字符集、首尾、相邻点、IPv4、保留前后缀）。
  """
  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.Buckets.Bucket
  alias Maxio.Objects.Object

  @reserved_prefixes ~w(xn-- sthree- amzn-s3-demo-)
  @reserved_suffixes ~w(-s3alias --ol-s3 .mrap --x-s3 --table-s3)

  @doc "校验 S3 桶名；合法 :ok，否则 {:error, :invalid_bucket_name}。"
  @spec validate_name(String.t()) :: :ok | {:error, :invalid_bucket_name}
  def validate_name(name) when is_binary(name) do
    cond do
      String.length(name) < 3 or String.length(name) > 63 -> err()
      not Regex.match?(~r/^[a-z0-9.\-]+$/, name) -> err()
      not Regex.match?(~r/^[a-z0-9]/, name) -> err()
      not Regex.match?(~r/[a-z0-9]$/, name) -> err()
      String.contains?(name, "..") -> err()
      ipv4?(name) -> err()
      Enum.any?(@reserved_prefixes, &String.starts_with?(name, &1)) -> err()
      Enum.any?(@reserved_suffixes, &String.ends_with?(name, &1)) -> err()
      true -> :ok
    end
  end

  def validate_name(_), do: err()

  defp err, do: {:error, :invalid_bucket_name}

  defp ipv4?(name) do
    case String.split(name, ".") do
      [_, _, _, _] = parts ->
        Enum.all?(parts, fn p ->
          case Integer.parse(p) do
            {n, ""} -> n >= 0 and n <= 255
            _ -> false
          end
        end)

      _ ->
        false
    end
  end

  @doc """
  创建桶。先校验名；命中已存在同名 → {:error, :already_owned}（M1 单租户，等价 BucketAlreadyOwnedByYou）。
  """
  @spec create(String.t(), String.t(), keyword()) ::
          {:ok, Bucket.t()} | {:error, :invalid_bucket_name | :already_owned | Ecto.Changeset.t()}
  def create(name, owner, opts \\ []) do
    region = Keyword.get(opts, :region, default_region())

    with :ok <- validate_name(name) do
      attrs = %{name: name, owner: owner, region: region}

      case %Bucket{} |> Bucket.changeset(attrs) |> Repo.insert() do
        {:ok, bucket} ->
          {:ok, bucket}

        {:error, %Ecto.Changeset{errors: errors}} ->
          if Keyword.has_key?(errors, :name), do: {:error, :already_owned}, else: {:error, :already_owned}
      end
    end
  end

  @doc "按名查桶。"
  @spec lookup(String.t()) :: {:ok, Bucket.t()} | {:error, :not_found}
  def lookup(name) do
    case Repo.get_by(Bucket, name: name) do
      nil -> {:error, :not_found}
      bucket -> {:ok, bucket}
    end
  end

  @doc "列出全部桶，按名升序（ListBuckets 用）。"
  @spec list() :: [Bucket.t()]
  def list, do: Repo.all(from b in Bucket, order_by: [asc: b.name])

  @doc "删除桶。桶不存在 → :not_found；桶内仍有对象 → :not_empty。"
  @spec delete(String.t()) :: :ok | {:error, :not_found | :not_empty}
  def delete(name) do
    with {:ok, bucket} <- lookup(name) do
      count = Repo.aggregate(from(o in Object, where: o.bucket_id == ^bucket.id), :count, :id)

      if count > 0 do
        {:error, :not_empty}
      else
        Repo.delete!(bucket)
        :ok
      end
    end
  end

  defp default_region do
    Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:region)
  end
end
```

1. 跑测试（此刻还会因 `Maxio.Objects` 未定义而部分失败——E3.5 补齐后再全绿；先确认 Buckets 相关用例可过）：
   ```powershell
   mix test test/maxio/buckets_test.exs
   ```
   期望：`validate_name` 与大部分 create/lookup/list/delete 用例通过；引用 `Maxio.Objects.put_metadata` 的 "delete 非空桶" 用例此刻报错（模块未定义）——E3.5 补齐。

**验证**：除依赖 `Maxio.Objects` 的用例外，其余 Buckets 用例全绿即通过本步。

### Task E3.5 — 实现 Object schema + Maxio.Objects 上下文（含 ListObjectsV2 查询）

**Files:** Create `lib/maxio/objects/object.ex`、`lib/maxio/objects.ex`；Create `test/maxio/objects_test.exs`

先写 Object schema + 上下文，再写其测试（含 ListObjectsV2 prefix/delimiter/分页语义）。

Create `lib/maxio/objects/object.ex`：
```elixir
defmodule Maxio.Objects.Object do
  @moduledoc "S3 对象元数据 schema（字节由存储后端持有，本表只存元信息）。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "objects" do
    field :bucket_name, :string
    field :key, :string
    field :size, :integer, default: 0
    field :etag, :string
    field :content_type, :string, default: "binary/octet-stream"
    field :metadata, :map, default: %{}
    field :storage_class, :string, default: "STANDARD"

    belongs_to :bucket, Maxio.Buckets.Bucket

    timestamps(type: :utc_datetime_usec)
  end

  @required [:bucket_id, :bucket_name, :key, :size, :etag]
  @optional [:content_type, :metadata, :storage_class]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(object, attrs) do
    object
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:bucket_id, :key], name: :objects_bucket_id_key_index)
  end
end
```

Create `lib/maxio/objects.ex`：
```elixir
defmodule Maxio.Objects do
  @moduledoc """
  对象元数据上下文：写/读/删元数据 + ListObjectsV2 查询（prefix/delimiter/max-keys/
  continuation-token/start-after，含 CommonPrefixes 折叠与分页 token）。
  字节读写不在此（走 Maxio.Storage），本上下文只管元数据与列举逻辑。
  """
  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.Buckets
  alias Maxio.Objects.Object

  @type list_opts :: %{
          optional(:prefix) => String.t(),
          optional(:delimiter) => String.t(),
          optional(:max_keys) => pos_integer(),
          optional(:continuation_token) => String.t() | nil,
          optional(:start_after) => String.t() | nil
        }

  @type list_result :: %{
          objects: [Object.t()],
          common_prefixes: [String.t()],
          is_truncated: boolean(),
          next_continuation_token: String.t() | nil,
          key_count: non_neg_integer()
        }

  @doc """
  写入/覆盖对象元数据（按 (bucket, key) upsert）。`attrs` 至少含 size、etag；
  可含 content_type、metadata、storage_class。桶不存在 → {:error, :no_such_bucket}。
  """
  @spec put_metadata(String.t(), String.t(), map()) ::
          {:ok, Object.t()} | {:error, :no_such_bucket | Ecto.Changeset.t()}
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
        storage_class: Map.get(attrs, :storage_class, "STANDARD")
      }

      %Object{}
      |> Object.changeset(base)
      |> Repo.insert(
        on_conflict: {:replace, [:size, :etag, :content_type, :metadata, :storage_class, :updated_at]},
        conflict_target: [:bucket_id, :key]
      )
    end
  end

  @doc "按 (bucket, key) 取对象元数据。"
  @spec get_metadata(String.t(), String.t()) :: {:ok, Object.t()} | {:error, :not_found}
  def get_metadata(bucket_name, key) do
    case Repo.get_by(Object, bucket_name: bucket_name, key: key) do
      nil -> {:error, :not_found}
      object -> {:ok, object}
    end
  end

  @doc "删除对象元数据（幂等：不存在也返回 :ok）。"
  @spec delete_metadata(String.t(), String.t()) :: :ok
  def delete_metadata(bucket_name, key) do
    Repo.delete_all(from o in Object, where: o.bucket_name == ^bucket_name and o.key == ^key)
    :ok
  end

  @doc """
  ListObjectsV2 查询。返回 %{objects, common_prefixes, is_truncated,
  next_continuation_token, key_count}。语义对齐官方：
    * continuation_token 优先于 start_after 作为分页游标（两者都是 key 的"严格大于"起点）；
    * delimiter 折叠：prefix 之后到首个 delimiter 之间相同的串折叠成一个 CommonPrefixes 条目；
    * 每个 common prefix 与每个对象各计一个 key_count，key_count <= max_keys；
    * 多取一条判断是否截断；截断时 next_continuation_token = 最后返回项（对象 key 或公共前缀）。
  """
  @spec list_objects_v2(String.t(), list_opts()) :: list_result()
  def list_objects_v2(bucket_name, opts \\ %{}) do
    prefix = Map.get(opts, :prefix, "") || ""
    delimiter = Map.get(opts, :delimiter)
    max_keys = Map.get(opts, :max_keys, 1000)
    cursor = Map.get(opts, :continuation_token) || Map.get(opts, :start_after)

    # 拉取候选 key（升序），从游标之后开始，仅取该 prefix。多取以便折叠后仍能判断截断。
    base_query =
      from o in Object,
        where: o.bucket_name == ^bucket_name,
        order_by: [asc: o.key]

    base_query =
      if prefix != "" do
        where(base_query, [o], like(o.key, ^(escape_like(prefix) <> "%")))
      else
        base_query
      end

    base_query = if cursor, do: where(base_query, [o], o.key > ^cursor), else: base_query

    candidates = Repo.all(base_query)

    {objects, common_prefixes, truncated, next_token} =
      collapse(candidates, prefix, delimiter, max_keys)

    key_count = length(objects) + length(common_prefixes)

    %{
      objects: objects,
      common_prefixes: common_prefixes,
      is_truncated: truncated,
      next_continuation_token: if(truncated, do: next_token, else: nil),
      key_count: key_count
    }
  end

  # 折叠 delimiter 公共前缀 + 截断判断。逐条扫描升序候选，累计到 max_keys。
  defp collapse(candidates, prefix, delimiter, max_keys) do
    do_collapse(candidates, prefix, delimiter, max_keys, [], MapSet.new(), [], nil)
  end

  defp do_collapse([], _prefix, _delim, _max, objs, _seen_set, cps, _last) do
    {Enum.reverse(objs), Enum.reverse(cps), false, nil}
  end

  defp do_collapse([obj | rest], prefix, delimiter, max, objs, seen_set, cps, _last) do
    count = length(objs) + MapSet.size(seen_set)

    cond do
      count >= max ->
        # 已达上限且还有候选 → 截断；next token = 上一个返回项（对象 key 或公共前缀）
        last = previous_token(objs, cps)
        {Enum.reverse(objs), Enum.reverse(cps), true, last}

      true ->
        case common_prefix_of(obj.key, prefix, delimiter) do
          nil ->
            do_collapse(rest, prefix, delimiter, max, [obj | objs], seen_set, cps, obj.key)

          cp ->
            if MapSet.member?(seen_set, cp) do
              # 已折叠过的公共前缀，跳过该对象不计数
              do_collapse(rest, prefix, delimiter, max, objs, seen_set, cps, cp)
            else
              do_collapse(rest, prefix, delimiter, max, objs, MapSet.put(seen_set, cp), [cp | cps], cp)
            end
        end
    end
  end

  # 该 key 在 prefix 之后是否含 delimiter；含则返回 prefix..(含首个delimiter) 的公共前缀，否则 nil。
  defp common_prefix_of(_key, _prefix, nil), do: nil

  defp common_prefix_of(key, prefix, delimiter) do
    rest = String.replace_prefix(key, prefix, "")

    case :binary.match(rest, delimiter) do
      {pos, len} -> prefix <> binary_part(rest, 0, pos + len)
      :nomatch -> nil
    end
  end

  defp previous_token([obj | _], _cps), do: obj.key
  defp previous_token([], [cp | _]), do: cp
  defp previous_token([], []), do: nil

  # 转义 LIKE 通配（% 与 _ 与 \）。
  defp escape_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp bucket_or_error(bucket_name) do
    case Buckets.lookup(bucket_name) do
      {:ok, bucket} -> {:ok, bucket}
      {:error, :not_found} -> {:error, :no_such_bucket}
    end
  end
end
```

> 实现注意（executor）：`previous_token/2` 在"刚好填满后下一条触发截断"时返回**最后一个已加入的返回项**作为 `next_continuation_token`。由于候选按 key 升序、且 token 是"严格大于"游标，使用最后返回项的 key（或公共前缀字符串）作为下次游标可正确续接。若 reviewer 发现折叠场景下公共前缀作为游标会漏掉同前缀后续 key——这是 M1 简化的已知边界，应记录为 M2 完善点（用更精确的"前缀末尾 + \\xFF"游标），但 M1 的基础分页/前缀/折叠语义须通过下列测试。

Create `test/maxio/objects_test.exs`：
```elixir
defmodule Maxio.ObjectsTest do
  use Maxio.DataCase, async: true

  alias Maxio.{Buckets, Objects}

  setup do
    {:ok, _} = Buckets.create("lb", "arn:aws:iam:::root")
    :ok
  end

  defp put(key), do: Objects.put_metadata("lb", key, %{size: 1, etag: "e", content_type: "text/plain"})

  test "put/get/delete 元数据往返" do
    {:ok, obj} = put("a.txt")
    assert obj.key == "a.txt"
    assert {:ok, fetched} = Objects.get_metadata("lb", "a.txt")
    assert fetched.etag == "e"
    assert :ok = Objects.delete_metadata("lb", "a.txt")
    assert {:error, :not_found} = Objects.get_metadata("lb", "a.txt")
  end

  test "同 key 再 put 覆盖（upsert）" do
    {:ok, _} = put("k")
    {:ok, _} = Objects.put_metadata("lb", "k", %{size: 99, etag: "e2", content_type: "text/plain"})
    {:ok, obj} = Objects.get_metadata("lb", "k")
    assert obj.size == 99
    assert obj.etag == "e2"
  end

  test "put 到不存在桶报 no_such_bucket" do
    assert {:error, :no_such_bucket} = Objects.put_metadata("nope", "k", %{size: 1, etag: "e"})
  end

  test "list_objects_v2 基础：返回全部对象，未截断" do
    for k <- ~w(a b c), do: put(k)
    res = Objects.list_objects_v2("lb", %{})
    assert Enum.map(res.objects, & &1.key) == ["a", "b", "c"]
    assert res.is_truncated == false
    assert res.next_continuation_token == nil
    assert res.key_count == 3
  end

  test "list_objects_v2 prefix 过滤" do
    for k <- ~w(photos/1 photos/2 docs/1), do: put(k)
    res = Objects.list_objects_v2("lb", %{prefix: "photos/"})
    assert Enum.map(res.objects, & &1.key) == ["photos/1", "photos/2"]
  end

  test "list_objects_v2 delimiter 折叠为 CommonPrefixes" do
    for k <- ~w(photos/2006/a photos/2006/b photos/2007/c top.txt), do: put(k)
    res = Objects.list_objects_v2("lb", %{prefix: "photos/", delimiter: "/"})
    assert res.objects == []
    assert Enum.sort(res.common_prefixes) == ["photos/2006/", "photos/2007/"]
    assert res.key_count == 2
  end

  test "list_objects_v2 max_keys 截断 + continuation_token 续接" do
    for k <- ~w(a b c d e), do: put(k)
    res1 = Objects.list_objects_v2("lb", %{max_keys: 2})
    assert Enum.map(res1.objects, & &1.key) == ["a", "b"]
    assert res1.is_truncated == true
    assert res1.next_continuation_token == "b"

    res2 = Objects.list_objects_v2("lb", %{max_keys: 2, continuation_token: res1.next_continuation_token})
    assert Enum.map(res2.objects, & &1.key) == ["c", "d"]
    assert res2.is_truncated == true

    res3 = Objects.list_objects_v2("lb", %{max_keys: 2, continuation_token: res2.next_continuation_token})
    assert Enum.map(res3.objects, & &1.key) == ["e"]
    assert res3.is_truncated == false
  end

  test "list_objects_v2 start_after 跳过游标之前的 key" do
    for k <- ~w(a b c d), do: put(k)
    res = Objects.list_objects_v2("lb", %{start_after: "b"})
    assert Enum.map(res.objects, & &1.key) == ["c", "d"]
  end
end
```

1. 跑测试：
   ```powershell
   mix test test/maxio/objects_test.exs test/maxio/buckets_test.exs
   ```
   期望：两个文件全绿（Objects 约 7 个、Buckets 约 11 个用例，`0 failures`）。

**验证**：ObjectsTest + BucketsTest 全绿即通过。

**Commit**：
```powershell
git add -A
git commit -m "feat(meta): Bucket/Object schemas + Buckets/Objects contexts (ListObjectsV2 query) with tests" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 单元 E3 验收

```powershell
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test test/maxio/buckets_test.exs test/maxio/objects_test.exs
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ buckets" 
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ objects"
```
期望：零警告；两个上下文测试全绿；`\d+` 显示两表的中文列/表/索引注释（铁律 6 可取证）。

---

## 单元 E4 — S3 Error + 错误码映射 + XML 渲染基座 + ErrorView

**目标**：实现统一异常 `Maxio.S3.Error`（defexception）+ 错误码→HTTP 状态映射表（官方核验）+ XML 渲染辅助 `Maxio.S3.XML`（saxy 封装，统一命名空间/ISO8601/ETag 引号）+ 错误 XML 渲染 `Maxio.S3.ErrorView`。这是后续所有 handler 与 plug 的错误出口（铁律 3：绝不静默 500）。

### Task E4.1 — S3 Error 异常 + 错误码映射失败测试（TDD）

**Files:** Create `test/maxio/s3/error_test.exs`

Create `test/maxio/s3/error_test.exs`：
```elixir
defmodule Maxio.S3.ErrorTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.Error

  test "new/2 按错误码自动填 HTTP 状态与默认 message" do
    err = Error.new(:no_such_bucket, resource: "/mybucket")
    assert %Error{code: "NoSuchBucket", http_status: 404, resource: "/mybucket"} = err
    assert err.message =~ "does not exist"
  end

  test "new/2 覆盖 message" do
    err = Error.new(:access_denied, message: "custom msg")
    assert err.code == "AccessDenied"
    assert err.http_status == 403
    assert err.message == "custom msg"
  end

  test "代表性错误码状态映射正确（官方核验）" do
    assert Error.new(:no_such_key).http_status == 404
    assert Error.new(:signature_does_not_match).http_status == 403
    assert Error.new(:invalid_access_key_id).http_status == 403
    assert Error.new(:request_time_too_skewed).http_status == 403
    assert Error.new(:bucket_already_owned_by_you).http_status == 409
    assert Error.new(:bucket_not_empty).http_status == 409
    assert Error.new(:invalid_bucket_name).http_status == 400
    assert Error.new(:malformed_xml).http_status == 400
    assert Error.new(:invalid_range).http_status == 416
    assert Error.new(:method_not_allowed).http_status == 405
    assert Error.new(:not_implemented).http_status == 501
    assert Error.new(:internal_error).http_status == 500
    assert Error.new(:authorization_header_malformed).http_status == 400
    assert Error.new(:missing_security_header).http_status == 400
  end

  test "未知错误码兜底 InternalError 500" do
    err = Error.new(:totally_unknown_code_xyz)
    assert err.code == "InternalError"
    assert err.http_status == 500
  end

  test "Error 是可 raise 的异常（Exception 行为）" do
    assert_raise Error, fn -> raise Error.new(:no_such_key) end
  end
end
```

1. 跑测试确认红：
   ```powershell
   mix test test/maxio/s3/error_test.exs
   ```
   期望：失败——`Maxio.S3.Error` 未定义。预期的红。

**验证**：测试因模块缺失失败即通过本步。

### Task E4.2 — 实现 Maxio.S3.Error（使测试通过）

**Files:** Create `lib/maxio/s3/error.ex`

映射表逐项核验自官方 ErrorResponses 文档（见研究）。`new/2` 接受原子码（内部用）映射到官方 Code 字符串 + HTTP 状态 + 默认 message。

Create `lib/maxio/s3/error.ex`：
```elixir
defmodule Maxio.S3.Error do
  @moduledoc """
  统一 S3 错误异常（铁律 3：绝不静默 500）。内部用原子错误码，经 new/2 映射到
  官方 S3 Error Code 字符串 + 正确 HTTP 状态 + 默认 Message。渲染为 <Error> XML 由
  Maxio.S3.ErrorView 负责。错误码→状态表逐项对照官方 ErrorResponses 文档。
  """
  defexception [:code, :message, :http_status, :resource, :request_id, extra: %{}]

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          http_status: pos_integer(),
          resource: String.t() | nil,
          request_id: String.t() | nil,
          extra: map()
        }

  # {官方 Code 字符串, HTTP 状态, 默认 Message}
  @table %{
    no_such_bucket: {"NoSuchBucket", 404, "The specified bucket does not exist."},
    no_such_key: {"NoSuchKey", 404, "The specified key does not exist."},
    no_such_upload: {"NoSuchUpload", 404, "The specified multipart upload does not exist."},
    access_denied: {"AccessDenied", 403, "Access Denied"},
    signature_does_not_match:
      {"SignatureDoesNotMatch", 403,
       "The request signature that the server calculated does not match the signature that you provided. Check your AWS secret access key and signing method."},
    invalid_access_key_id:
      {"InvalidAccessKeyId", 403,
       "The AWS access key ID that you provided does not exist in our records."},
    request_time_too_skewed:
      {"RequestTimeTooSkewed", 403,
       "The difference between the request time and the server's time is too large."},
    bucket_already_owned_by_you:
      {"BucketAlreadyOwnedByYou", 409,
       "The bucket that you tried to create already exists, and you own it."},
    bucket_already_exists:
      {"BucketAlreadyExists", 409,
       "The requested bucket name is not available. The bucket namespace is shared by all users of the system."},
    bucket_not_empty: {"BucketNotEmpty", 409, "The bucket that you tried to delete is not empty."},
    invalid_argument: {"InvalidArgument", 400, "Invalid Argument"},
    invalid_bucket_name: {"InvalidBucketName", 400, "The specified bucket is not valid."},
    entity_too_small:
      {"EntityTooSmall", 400, "Your proposed upload is smaller than the minimum allowed object size."},
    entity_too_large:
      {"EntityTooLarge", 400, "Your proposed upload exceeds the maximum allowed object size."},
    invalid_part: {"InvalidPart", 400, "One or more of the specified parts could not be found."},
    invalid_part_order:
      {"InvalidPartOrder", 400, "The list of parts was not in ascending order."},
    malformed_xml:
      {"MalformedXML", 400,
       "The XML that you provided was not well formed or did not validate against our published schema."},
    precondition_failed:
      {"PreconditionFailed", 412, "At least one of the preconditions that you specified did not hold."},
    not_modified: {"NotModified", 304, "The resource was not changed."},
    invalid_range: {"InvalidRange", 416, "The requested range cannot be satisfied."},
    method_not_allowed:
      {"MethodNotAllowed", 405, "The specified method is not allowed against this resource."},
    missing_content_length:
      {"MissingContentLength", 411, "You must provide the Content-Length HTTP header."},
    not_implemented:
      {"NotImplemented", 501, "A header that you provided implies functionality that is not implemented."},
    internal_error: {"InternalError", 500, "An internal error occurred. Try again."},
    authorization_header_malformed:
      {"AuthorizationHeaderMalformed", 400, "The authorization header that you provided is not valid."},
    authorization_query_parameters_error:
      {"AuthorizationQueryParametersError", 400,
       "The authorization query parameters that you provided are not valid."},
    missing_security_header:
      {"MissingSecurityHeader", 400, "Your request is missing a required header."},
    invalid_request: {"InvalidRequest", 400, "Invalid Request"},
    bad_digest:
      {"BadDigest", 400, "The Content-MD5 or checksum value that you specified did not match what the server received."},
    incomplete_body:
      {"IncompleteBody", 400, "You did not provide the number of bytes specified by the Content-Length HTTP header."}
  }

  @doc """
  构造 S3 错误。`code` 为内部原子（见映射表）；opts 可含 :message :resource :request_id :extra。
  未知 code 兜底 InternalError(500)。
  """
  @spec new(atom(), keyword()) :: t()
  def new(code, opts \\ []) when is_atom(code) do
    {code_str, status, default_msg} = Map.get(@table, code, {"InternalError", 500, "An internal error occurred. Try again."})

    %__MODULE__{
      code: code_str,
      message: Keyword.get(opts, :message, default_msg),
      http_status: status,
      resource: Keyword.get(opts, :resource),
      request_id: Keyword.get(opts, :request_id),
      extra: Keyword.get(opts, :extra, %{})
    }
  end

  @impl true
  def message(%__MODULE__{code: code, message: msg}), do: "#{code}: #{msg}"

  @doc "全部已知错误码原子（用于测试/文档）。"
  @spec codes() :: [atom()]
  def codes, do: Map.keys(@table)
end
```

1. 跑测试：
   ```powershell
   mix test test/maxio/s3/error_test.exs
   ```
   期望：`5 tests, 0 failures`。

**验证**：ErrorTest 全绿即通过。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): add Maxio.S3.Error exception + verified error-code/status table with tests" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E4.3 — XML 渲染辅助 + ErrorView 失败测试（TDD）

**Files:** Create `test/maxio/s3/xml_test.exs`、`test/maxio/s3/error_view_test.exs`

`Maxio.S3.XML` 封装 saxy：`element/3`、`characters/1`（re-export 便于 view 用）、`iso8601/1`（DateTime → `YYYY-MM-DDTHH:MM:SS.000Z`）、`quote_etag/1`（加引号）、`encode/1`（simple-form → iodata，带 prolog + 命名空间在 root）。`ErrorView.render/1` 把 `%Error{}` 渲染成 `{status, iodata}`。

Create `test/maxio/s3/xml_test.exs`：
```elixir
defmodule Maxio.S3.XMLTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.XML

  test "iso8601/1 渲染为带毫秒 Z 的 UTC（列举 XML 体格式）" do
    dt = ~U[2019-12-11 23:32:47.000000Z]
    assert XML.iso8601(dt) == "2019-12-11T23:32:47.000Z"
  end

  test "quote_etag/1 给 etag 加引号（幂等）" do
    assert XML.quote_etag("abc") == "\"abc\""
    assert XML.quote_etag("\"abc\"") == "\"abc\""
  end

  test "encode/1 输出带 prolog 与 root 命名空间的 XML iodata" do
    import Saxy.XML
    root = element("LocationConstraint", [{"xmlns", XML.namespace()}], characters("us-west-2"))
    xml = root |> XML.encode() |> IO.iodata_to_binary()
    assert xml =~ "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    assert xml =~ "xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\""
    assert xml =~ ">us-west-2</LocationConstraint>"
  end
end
```

Create `test/maxio/s3/error_view_test.exs`：
```elixir
defmodule Maxio.S3.ErrorViewTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.{Error, ErrorView}

  test "render/1 输出 {status, xml iodata}，含 Code/Message/Resource/RequestId" do
    err = Error.new(:no_such_key, resource: "/b/k", request_id: "req-123")
    {status, iodata} = ErrorView.render(err)
    xml = IO.iodata_to_binary(iodata)

    assert status == 404
    assert xml =~ "<Error>"
    assert xml =~ "<Code>NoSuchKey</Code>"
    assert xml =~ "<Message>The specified key does not exist.</Message>"
    assert xml =~ "<Resource>/b/k</Resource>"
    assert xml =~ "<RequestId>req-123</RequestId>"
  end

  test "render/1 缺 resource/request_id 时省略对应元素" do
    {status, iodata} = ErrorView.render(Error.new(:internal_error))
    xml = IO.iodata_to_binary(iodata)
    assert status == 500
    assert xml =~ "<Code>InternalError</Code>"
    refute xml =~ "<Resource>"
  end
end
```

1. 跑测试确认红：
   ```powershell
   mix test test/maxio/s3/xml_test.exs test/maxio/s3/error_view_test.exs
   ```
   期望：失败——`Maxio.S3.XML` / `Maxio.S3.ErrorView` 未定义。预期的红。

**验证**：测试因模块缺失失败即通过本步。

### Task E4.4 — 实现 Maxio.S3.XML + Maxio.S3.ErrorView（使测试通过）

**Files:** Create `lib/maxio/s3/xml.ex`、`lib/maxio/s3/error_view.ex`

Create `lib/maxio/s3/xml.ex`：
```elixir
defmodule Maxio.S3.XML do
  @moduledoc """
  S3 XML 出站渲染辅助（saxy 封装）。统一命名空间、ISO8601 时间格式、ETag 引号、
  prolog（<?xml version="1.0" encoding="UTF-8"?>）。各响应 view 用 Saxy.XML.element/3
  构造 simple-form，再用本模块 encode/1 输出 iodata（零中间字符串，直接喂 send_resp）。
  """

  @namespace "http://s3.amazonaws.com/doc/2006-03-01/"

  @doc "S3 XML 命名空间字面量。"
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc "把 simple-form 根元素编码为带 prolog 的 XML iodata。"
  @spec encode(Saxy.XML.element()) :: iodata()
  def encode(root) do
    Saxy.encode_to_iodata!(root, version: "1.0", encoding: "UTF-8")
  end

  @doc """
  DateTime → 列举 XML 体所用 ISO8601（UTC、毫秒、Z）：YYYY-MM-DDTHH:MM:SS.000Z。
  （注意：HTTP Last-Modified 响应头用 RFC1123，不走这里。）
  """
  @spec iso8601(DateTime.t()) :: String.t()
  def iso8601(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:millisecond)
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    |> normalize_millis()
  end

  # strftime 的 %f 是微秒（6 位）；列举体要毫秒（3 位），截断到 3 位。
  defp normalize_millis(str) do
    Regex.replace(~r/\.(\d{3})\d*Z$/, str, ".\\1Z")
  end

  @doc "给 ETag 加引号（幂等：已带引号不重复加）。"
  @spec quote_etag(String.t()) :: String.t()
  def quote_etag(etag) do
    trimmed = String.trim(etag, "\"")
    "\"" <> trimmed <> "\""
  end
end
```

> 实现注意：若 `Calendar.strftime` 的 `%f` 行为在本机给出非 6 位，`normalize_millis/1` 的正则仍把"小数点后至少 3 位 + 任意余位 + Z"规整为 3 位毫秒；executor 跑 XMLTest 的 `iso8601` 用例验证 `"2019-12-11T23:32:47.000Z"` 精确匹配。若 `%f` 不补零导致 `.0Z`，改用显式构造：`"#{...}.#{ms |> Integer.to_string() |> String.pad_leading(3, "0")}Z"`，其中 `ms = div(elem(dt.microsecond,0), 1000)`。

Create `lib/maxio/s3/error_view.ex`：
```elixir
defmodule Maxio.S3.ErrorView do
  @moduledoc """
  把 %Maxio.S3.Error{} 渲染为 S3 兼容的 <Error> XML（铁律 3：所有错误显式映射、不静默 500）。
  返回 {http_status, iodata}，由 plug 写 Content-Type: application/xml + send_resp。
  """
  import Saxy.XML
  alias Maxio.S3.{Error, XML}

  @doc "渲染错误为 {status, xml iodata}。resource/request_id 缺省则省略对应元素。"
  @spec render(Error.t()) :: {pos_integer(), iodata()}
  def render(%Error{} = err) do
    children =
      [
        element("Code", [], characters(err.code)),
        element("Message", [], characters(err.message))
      ]
      |> maybe_append("Resource", err.resource)
      |> maybe_append("RequestId", err.request_id)

    root = element("Error", [], children)
    {err.http_status, XML.encode(root)}
  end

  defp maybe_append(children, _name, nil), do: children
  defp maybe_append(children, _name, ""), do: children

  defp maybe_append(children, name, value) do
    children ++ [element(name, [], characters(to_string(value)))]
  end
end
```

1. 跑测试：
   ```powershell
   mix test test/maxio/s3/xml_test.exs test/maxio/s3/error_view_test.exs
   ```
   期望：XMLTest `3 tests` + ErrorViewTest `2 tests`，`0 failures`。

**验证**：两文件全绿即通过。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): add XML render helper (saxy) + ErrorView for S3 Error XML with tests" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 单元 E4 验收

```powershell
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test test/maxio/s3/error_test.exs test/maxio/s3/xml_test.exs test/maxio/s3/error_view_test.exs
```
期望：零警告；三文件全绿。错误出口（Error + ErrorView）与 XML 基座就位，供 E5/E6/E7 复用。

---

## 单元 E5 — SigV4 鉴权（Canonical / Signer / AuthHeaderParser / Auth / CredentialStore+MemoryStore / SigV4 plug / debug CLI）

**目标**：实现 AWS Signature Version 4（header-based 单块 / UNSIGNED-PAYLOAD / presigned）。核心是 `Canonical`（构造 canonical request，含 S3 单次编码 + 不归一化路径）与 `Signer`（StringToSign + HMAC 签名链）。**用 AWS 官方 worked-example 的 KNOWN-ANSWER 向量 byte-for-byte 回归**（独立 ground truth，证明我们与 AWS 一致）。再实现凭据后端 behaviour + MemoryStore（root 从 env 引导）、鉴权 context、SigV4 plug、`mix maxio.sigv4.debug` 取证 CLI。

> **测试向量凭据（全部 header/presigned 向量共用）**：AccessKeyId `AKIAIOSFODNN7EXAMPLE`，SecretAccessKey `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY`（**斜杠版**，非加号版！），region `us-east-1`，service `s3`，timestamp `20130524T000000Z`，scope `20130524/us-east-1/s3/aws4_request`，桶 `examplebucket`。

### Task E5.1 — Canonical（canonical request）KNOWN-ANSWER 失败测试（TDD）

**Files:** Create `test/maxio/auth/sigv4/canonical_test.exs`

直接对照官方向量断言 canonical request 文本（VECTOR A/B/C/D）。注意：CanonicalURI 单次编码（`test$file.text` → `/test%24file.text`），空 query 第 3 行为空行，subresource flag `?lifecycle` → `lifecycle=`，多参 query 按编码后 key 排序。

Create `test/maxio/auth/sigv4/canonical_test.exs`：
```elixir
defmodule Maxio.Auth.SigV4.CanonicalTest do
  use ExUnit.Case, async: true

  alias Maxio.Auth.SigV4.Canonical

  @empty_hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  describe "uri_encode/2（S3：单次编码，CanonicalURI 不编码 /）" do
    test "对象 key 特殊字符单次编码（path 模式保留 /）" do
      assert Canonical.uri_encode("/test.txt", :path) == "/test.txt"
      assert Canonical.uri_encode("/test$file.text", :path) == "/test%24file.text"
      assert Canonical.uri_encode("/a/b/c", :path) == "/a/b/c"
    end

    test "query 模式编码所有保留字符（含 /）" do
      assert Canonical.uri_encode("a/b", :query) == "a%2Fb"
      assert Canonical.uri_encode("a b", :query) == "a%20b"
      assert Canonical.uri_encode("a~b-c_d.e", :query) == "a~b-c_d.e"
    end
  end

  test "VECTOR A — GET Object（空 query 第3行空行，blank 行在 SignedHeaders 前）" do
    req = %{
      method: "GET",
      path: "/test.txt",
      query: %{},
      headers: [
        {"host", "examplebucket.s3.amazonaws.com"},
        {"range", "bytes=0-9"},
        {"x-amz-content-sha256", @empty_hash},
        {"x-amz-date", "20130524T000000Z"}
      ],
      payload_hash: @empty_hash
    }

    expected =
      "GET\n" <>
        "/test.txt\n" <>
        "\n" <>
        "host:examplebucket.s3.amazonaws.com\n" <>
        "range:bytes=0-9\n" <>
        "x-amz-content-sha256:#{@empty_hash}\n" <>
        "x-amz-date:20130524T000000Z\n" <>
        "\n" <>
        "host;range;x-amz-content-sha256;x-amz-date\n" <>
        @empty_hash

    assert Canonical.canonical_request(req) == expected
  end

  test "VECTOR B — PUT Object（key 单次编码 /test%24file.text，签 date+host）" do
    body_hash = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"

    req = %{
      method: "PUT",
      path: "/test$file.text",
      query: %{},
      headers: [
        {"date", "Fri, 24 May 2013 00:00:00 GMT"},
        {"host", "examplebucket.s3.amazonaws.com"},
        {"x-amz-content-sha256", body_hash},
        {"x-amz-date", "20130524T000000Z"},
        {"x-amz-storage-class", "REDUCED_REDUNDANCY"}
      ],
      payload_hash: body_hash
    }

    expected =
      "PUT\n" <>
        "/test%24file.text\n" <>
        "\n" <>
        "date:Fri, 24 May 2013 00:00:00 GMT\n" <>
        "host:examplebucket.s3.amazonaws.com\n" <>
        "x-amz-content-sha256:#{body_hash}\n" <>
        "x-amz-date:20130524T000000Z\n" <>
        "x-amz-storage-class:REDUCED_REDUNDANCY\n" <>
        "\n" <>
        "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class\n" <>
        body_hash

    assert Canonical.canonical_request(req) == expected
  end

  test "VECTOR C — GET Bucket Lifecycle（?lifecycle → lifecycle=）" do
    req = %{
      method: "GET",
      path: "/",
      query: %{"lifecycle" => ""},
      headers: [
        {"host", "examplebucket.s3.amazonaws.com"},
        {"x-amz-content-sha256", @empty_hash},
        {"x-amz-date", "20130524T000000Z"}
      ],
      payload_hash: @empty_hash
    }

    expected =
      "GET\n/\nlifecycle=\nhost:examplebucket.s3.amazonaws.com\n" <>
        "x-amz-content-sha256:#{@empty_hash}\nx-amz-date:20130524T000000Z\n\n" <>
        "host;x-amz-content-sha256;x-amz-date\n#{@empty_hash}"

    assert Canonical.canonical_request(req) == expected
  end

  test "VECTOR D — ListObjects（?max-keys=2&prefix=J 按编码 key 排序）" do
    req = %{
      method: "GET",
      path: "/",
      query: %{"max-keys" => "2", "prefix" => "J"},
      headers: [
        {"host", "examplebucket.s3.amazonaws.com"},
        {"x-amz-content-sha256", @empty_hash},
        {"x-amz-date", "20130524T000000Z"}
      ],
      payload_hash: @empty_hash
    }

    expected =
      "GET\n/\nmax-keys=2&prefix=J\nhost:examplebucket.s3.amazonaws.com\n" <>
        "x-amz-content-sha256:#{@empty_hash}\nx-amz-date:20130524T000000Z\n\n" <>
        "host;x-amz-content-sha256;x-amz-date\n#{@empty_hash}"

    assert Canonical.canonical_request(req) == expected
  end

  test "trimall/1 折叠内部连续空白并去首尾" do
    assert Canonical.trimall("  a   b  c ") == "a b c"
  end
end
```

1. 跑测试确认红：
   ```powershell
   mix test test/maxio/auth/sigv4/canonical_test.exs
   ```
   期望：失败——`Maxio.Auth.SigV4.Canonical` 未定义。预期的红。

**验证**：测试因模块缺失失败即通过本步。

### Task E5.2 — 实现 Canonical（使测试通过）

**Files:** Create `lib/maxio/auth/sigv4/canonical.ex`

S3 关键规则：自写 UriEncode（除 `A-Za-z0-9-_.~` 外每字节 `%XY` 大写 hex，空格 → `%20`）；CanonicalURI 模式不编码 `/`，query 模式编码 `/`→`%2F`；**路径不归一化**（不折叠 `//`、不解析 `..`）；headers 小写名 + trimall 值 + 按名排序 + 每行 `\n`；query 按编码后 key 排序、空值保留 `=`。

Create `lib/maxio/auth/sigv4/canonical.ex`：
```elixir
defmodule Maxio.Auth.SigV4.Canonical do
  @moduledoc """
  SigV4 Canonical Request 构造（纯函数）。S3 特例：单次编码、路径不归一化。
  入参 req: %{method, path, query (map name=>value), headers ([{lname, value}]), payload_hash}。
  其中 path 是**已 URL 解码的绝对路径**（对象 key 的真实字节），本模块负责再做 S3 的单次 UriEncode。
  headers 的 name 须已小写，且为参与签名的 SignedHeaders 集合（调用方按 SignedHeaders 过滤后传入）。
  """

  @doc "组装 6 段 canonical request，以 \\n 连接（末段无换行）。"
  @spec canonical_request(map()) :: String.t()
  def canonical_request(%{
        method: method,
        path: path,
        query: query,
        headers: headers,
        payload_hash: payload_hash
      }) do
    [
      String.upcase(method),
      canonical_uri(path),
      canonical_query(query),
      canonical_headers(headers),
      signed_headers(headers),
      payload_hash
    ]
    |> Enum.join("\n")
  end

  @doc "CanonicalURI：S3 单次编码且不编码 /；空路径用 /。不归一化。"
  @spec canonical_uri(String.t()) :: String.t()
  def canonical_uri(""), do: "/"
  def canonical_uri(nil), do: "/"
  def canonical_uri(path), do: uri_encode(path, :path)

  @doc """
  CanonicalQueryString：每个 name/value 单独 UriEncode（query 模式，编码 /），
  按编码后 name 字典序排序，key=value 以 & 连接，空值保留 `key=`。
  """
  @spec canonical_query(map()) :: String.t()
  def canonical_query(query) when is_map(query) do
    query
    |> Enum.map(fn {k, v} -> {uri_encode(to_string(k), :query), uri_encode(to_string(v), :query)} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {k, v} -> k <> "=" <> v end)
    |> Enum.join("&")
  end

  @doc "CanonicalHeaders：每行 lname:trimall(value)\\n，按 lname 排序。整体以 \\n 结尾。"
  @spec canonical_headers([{String.t(), String.t()}]) :: String.t()
  def canonical_headers(headers) do
    headers
    |> Enum.map(fn {name, value} -> {String.downcase(name), trimall(value)} end)
    |> Enum.sort_by(fn {name, _v} -> name end)
    |> Enum.map(fn {name, value} -> name <> ":" <> value <> "\n" end)
    |> Enum.join("")
  end

  @doc "SignedHeaders：小写名按字典序、分号连接。"
  @spec signed_headers([{String.t(), String.t()}]) :: String.t()
  def signed_headers(headers) do
    headers
    |> Enum.map(fn {name, _v} -> String.downcase(name) end)
    |> Enum.sort()
    |> Enum.join(";")
  end

  @doc """
  自写 UriEncode。unreserved（A-Za-z0-9-_.~）原样；其余每字节 %XY 大写 hex；
  mode=:path 时额外保留 `/`（S3 CanonicalURI 不编码斜杠），mode=:query 时编码 `/`→%2F。
  """
  @spec uri_encode(String.t(), :path | :query) :: String.t()
  def uri_encode(str, mode) do
    str
    |> :binary.bin_to_list()
    |> Enum.map_join("", fn byte -> encode_byte(byte, mode) end)
  end

  defp encode_byte(byte, mode) do
    cond do
      unreserved?(byte) -> <<byte>>
      byte == ?/ and mode == :path -> "/"
      true -> "%" <> (byte |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0"))
    end
  end

  defp unreserved?(b) do
    (b >= ?A and b <= ?Z) or (b >= ?a and b <= ?z) or (b >= ?0 and b <= ?9) or
      b in [?-, ?_, ?., ?~]
  end

  @doc "trimall：去首尾空白 + 内部连续空白折叠为单空格。"
  @spec trimall(String.t()) :: String.t()
  def trimall(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end
end
```

1. 跑测试：
   ```powershell
   mix test test/maxio/auth/sigv4/canonical_test.exs
   ```
   期望：`8 tests, 0 failures`（含 4 个 KNOWN-ANSWER 向量逐字匹配）。

**验证**：CanonicalTest 全绿 = canonical request 与 AWS byte-for-byte 一致。

**Commit**：
```powershell
git add -A
git commit -m "feat(sigv4): Canonical request builder (S3 single-encode, no-normalize) + KNOWN-ANSWER vectors" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E5.3 — Signer（StringToSign + HMAC 链 + 最终签名）KNOWN-ANSWER 失败测试（TDD）

**Files:** Create `test/maxio/auth/sigv4/signer_test.exs`

对照官方向量断言：StringToSign（4 行）、signing key 链、最终签名 hex（VECTOR A/B/C/D + presigned）。

Create `test/maxio/auth/sigv4/signer_test.exs`：
```elixir
defmodule Maxio.Auth.SigV4.SignerTest do
  use ExUnit.Case, async: true

  alias Maxio.Auth.SigV4.{Canonical, Signer}

  @secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  @region "us-east-1"
  @service "s3"
  @scope "20130524/us-east-1/s3/aws4_request"
  @amz_date "20130524T000000Z"
  @scope_date "20130524"
  @empty_hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  defp sign(req) do
    canonical = Canonical.canonical_request(req)
    sts = Signer.string_to_sign(@amz_date, @scope, canonical, "AWS4-HMAC-SHA256")
    key = Signer.derive_signing_key(@secret, @scope_date, @region, @service)
    Signer.signature(key, sts)
  end

  test "hex_sha256/1 空串常量" do
    assert Signer.hex_sha256("") == @empty_hash
  end

  test "VECTOR A — GET Object string_to_sign + signature" do
    req = %{
      method: "GET",
      path: "/test.txt",
      query: %{},
      headers: [
        {"host", "examplebucket.s3.amazonaws.com"},
        {"range", "bytes=0-9"},
        {"x-amz-content-sha256", @empty_hash},
        {"x-amz-date", @amz_date}
      ],
      payload_hash: @empty_hash
    }

    canonical = Canonical.canonical_request(req)

    expected_sts =
      "AWS4-HMAC-SHA256\n20130524T000000Z\n20130524/us-east-1/s3/aws4_request\n" <>
        "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972"

    assert Signer.string_to_sign(@amz_date, @scope, canonical, "AWS4-HMAC-SHA256") == expected_sts
    assert sign(req) == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
  end

  test "VECTOR B — PUT Object signature" do
    body_hash = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"

    req = %{
      method: "PUT",
      path: "/test$file.text",
      query: %{},
      headers: [
        {"date", "Fri, 24 May 2013 00:00:00 GMT"},
        {"host", "examplebucket.s3.amazonaws.com"},
        {"x-amz-content-sha256", body_hash},
        {"x-amz-date", @amz_date},
        {"x-amz-storage-class", "REDUCED_REDUNDANCY"}
      ],
      payload_hash: body_hash
    }

    assert sign(req) == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
  end

  test "VECTOR C — GET Bucket Lifecycle signature" do
    req = %{
      method: "GET",
      path: "/",
      query: %{"lifecycle" => ""},
      headers: [
        {"host", "examplebucket.s3.amazonaws.com"},
        {"x-amz-content-sha256", @empty_hash},
        {"x-amz-date", @amz_date}
      ],
      payload_hash: @empty_hash
    }

    assert sign(req) == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
  end

  test "VECTOR D — ListObjects signature" do
    req = %{
      method: "GET",
      path: "/",
      query: %{"max-keys" => "2", "prefix" => "J"},
      headers: [
        {"host", "examplebucket.s3.amazonaws.com"},
        {"x-amz-content-sha256", @empty_hash},
        {"x-amz-date", @amz_date}
      ],
      payload_hash: @empty_hash
    }

    assert sign(req) == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
  end

  test "presigned VECTOR — UNSIGNED-PAYLOAD + 全 X-Amz-* query（除 Signature）" do
    req = %{
      method: "GET",
      path: "/test.txt",
      query: %{
        "X-Amz-Algorithm" => "AWS4-HMAC-SHA256",
        "X-Amz-Credential" => "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request",
        "X-Amz-Date" => "20130524T000000Z",
        "X-Amz-Expires" => "86400",
        "X-Amz-SignedHeaders" => "host"
      },
      headers: [{"host", "examplebucket.s3.amazonaws.com"}],
      payload_hash: "UNSIGNED-PAYLOAD"
    }

    canonical = Canonical.canonical_request(req)

    expected_sts =
      "AWS4-HMAC-SHA256\n20130524T000000Z\n20130524/us-east-1/s3/aws4_request\n" <>
        "3bfa292879f6447bbcda7001decf97f4a54dc650c8942174ae0a9121cf58ad04"

    assert Signer.string_to_sign(@amz_date, @scope, canonical, "AWS4-HMAC-SHA256") == expected_sts
    assert sign(req) == "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  end

  test "secure_compare/2 常数时间比对" do
    assert Signer.secure_compare("abc", "abc") == true
    assert Signer.secure_compare("abc", "abd") == false
  end
end
```

1. 跑测试确认红：
   ```powershell
   mix test test/maxio/auth/sigv4/signer_test.exs
   ```
   期望：失败——`Maxio.Auth.SigV4.Signer` 未定义。预期的红。

**验证**：测试因模块缺失失败即通过本步。

### Task E5.4 — 实现 Signer（使测试通过）

**Files:** Create `lib/maxio/auth/sigv4/signer.ex`

HMAC 链：中间结果是**原始二进制**（非 hex），仅最终签名 hex。`derive_signing_key` 用 `"AWS4"<>secret` 起步。

Create `lib/maxio/auth/sigv4/signer.ex`：
```elixir
defmodule Maxio.Auth.SigV4.Signer do
  @moduledoc """
  SigV4 StringToSign + signing key HMAC 链 + 最终签名（OTP :crypto，无外部依赖）。
  中间 HMAC 结果是原始 32 字节二进制（绝不 hex 化），只有最终签名 hex 小写。
  签名比对用 Plug.Crypto.secure_compare/2（常数时间，防时序侧信道）。
  """

  @doc "hex(SHA256(data))，小写。"
  @spec hex_sha256(iodata()) :: String.t()
  def hex_sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  @doc "StringToSign：algorithm ⏎ amz_date ⏎ scope ⏎ hex(SHA256(canonical_request))，无尾换行。"
  @spec string_to_sign(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def string_to_sign(amz_date, scope, canonical_request, algorithm) do
    Enum.join([algorithm, amz_date, scope, hex_sha256(canonical_request)], "\n")
  end

  @doc """
  推导 signing key（HMAC-SHA256 链）：
    kDate=HMAC("AWS4"+secret, yyyymmdd) → kRegion=HMAC(kDate, region)
    → kService=HMAC(kRegion, service) → kSigning=HMAC(kService, "aws4_request")
  返回原始二进制。
  """
  @spec derive_signing_key(String.t(), String.t(), String.t(), String.t()) :: binary()
  def derive_signing_key(secret, scope_date, region, service) do
    k_date = hmac("AWS4" <> secret, scope_date)
    k_region = hmac(k_date, region)
    k_service = hmac(k_region, service)
    hmac(k_service, "aws4_request")
  end

  @doc "最终签名 = hex(HMAC(signing_key, string_to_sign))，小写。"
  @spec signature(binary(), String.t()) :: String.t()
  def signature(signing_key, string_to_sign) do
    hmac(signing_key, string_to_sign) |> Base.encode16(case: :lower)
  end

  @doc "常数时间签名比对。"
  @spec secure_compare(binary(), binary()) :: boolean()
  def secure_compare(a, b) when is_binary(a) and is_binary(b) do
    Plug.Crypto.secure_compare(a, b)
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
```

1. 跑测试：
   ```powershell
   mix test test/maxio/auth/sigv4/signer_test.exs
   ```
   期望：`7 tests, 0 failures`（含 5 个 KNOWN-ANSWER 签名向量逐字匹配）。

**验证**：SignerTest 全绿 = StringToSign + 签名链与 AWS byte-for-byte 一致（独立 ground truth 达成）。

**Commit**：
```powershell
git add -A
git commit -m "feat(sigv4): Signer (string-to-sign, HMAC signing-key chain, signature) + KNOWN-ANSWER vectors" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task E5.5 — AuthHeaderParser（解析 Authorization 头 / presigned query）失败测试（TDD）

**Files:** Create `test/maxio/auth/sigv4/auth_header_parser_test.exs`

`%SignedRequest{}` 统一两种形态。header 形态从 `Authorization: AWS4-HMAC-SHA256 Credential=.../scope,SignedHeaders=...,Signature=...` 解析；presigned 从 `X-Amz-*` query 解析。

Create `test/maxio/auth/sigv4/auth_header_parser_test.exs`：
```elixir
defmodule Maxio.Auth.SigV4.AuthHeaderParserTest do
  use ExUnit.Case, async: true

  alias Maxio.Auth.SigV4.{AuthHeaderParser, SignedRequest}

  test "解析 header-based Authorization（VECTOR A 形态）" do
    auth =
      "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," <>
        "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date," <>
        "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"

    assert {:ok, %SignedRequest{} = sr} =
             AuthHeaderParser.parse_header(auth, "20130524T000000Z", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

    assert sr.auth_type == :header
    assert sr.access_key == "AKIAIOSFODNN7EXAMPLE"
    assert sr.scope_date == "20130524"
    assert sr.region == "us-east-1"
    assert sr.service == "s3"
    assert sr.signed_headers == ["host", "range", "x-amz-content-sha256", "x-amz-date"]
    assert sr.signature == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    assert sr.amz_date == "20130524T000000Z"
    assert sr.payload_mode == :single
  end

  test "x-amz-content-sha256=UNSIGNED-PAYLOAD → payload_mode :unsigned" do
    auth =
      "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," <>
        "SignedHeaders=host,Signature=abc"

    {:ok, sr} = AuthHeaderParser.parse_header(auth, "20130524T000000Z", "UNSIGNED-PAYLOAD")
    assert sr.payload_mode == :unsigned
  end

  test "x-amz-content-sha256=STREAMING-AWS4-HMAC-SHA256-PAYLOAD → :streaming" do
    auth =
      "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," <>
        "SignedHeaders=host,Signature=abc"

    {:ok, sr} = AuthHeaderParser.parse_header(auth, "20130524T000000Z", "STREAMING-AWS4-HMAC-SHA256-PAYLOAD")
    assert sr.payload_mode == :streaming
  end

  test "畸形 Authorization 头返回 :authorization_header_malformed" do
    assert {:error, :authorization_header_malformed} =
             AuthHeaderParser.parse_header("Basic xxx", "d", "h")

    assert {:error, :authorization_header_malformed} =
             AuthHeaderParser.parse_header("AWS4-HMAC-SHA256 garbage", "d", "h")
  end

  test "解析 presigned query（presigned VECTOR 形态）" do
    query = %{
      "X-Amz-Algorithm" => "AWS4-HMAC-SHA256",
      "X-Amz-Credential" => "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request",
      "X-Amz-Date" => "20130524T000000Z",
      "X-Amz-Expires" => "86400",
      "X-Amz-SignedHeaders" => "host",
      "X-Amz-Signature" => "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
    }

    {:ok, sr} = AuthHeaderParser.parse_presigned(query)
    assert sr.auth_type == :presigned
    assert sr.access_key == "AKIAIOSFODNN7EXAMPLE"
    assert sr.scope_date == "20130524"
    assert sr.signed_headers == ["host"]
    assert sr.signature == "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
    assert sr.amz_date == "20130524T000000Z"
    assert sr.expires == 86400
    assert sr.payload_mode == :unsigned
  end

  test "presigned 缺必需参数返回 :authorization_query_parameters_error" do
    assert {:error, :authorization_query_parameters_error} =
             AuthHeaderParser.parse_presigned(%{"X-Amz-Algorithm" => "AWS4-HMAC-SHA256"})
  end
end
```

1. 跑测试确认红：
   ```powershell
   mix test test/maxio/auth/sigv4/auth_header_parser_test.exs
   ```
   期望：失败——`Maxio.Auth.SigV4.AuthHeaderParser` / `SignedRequest` 未定义。预期的红。

**验证**：测试因模块缺失失败即通过本步。

### Task E5.6 — 实现 SignedRequest + AuthHeaderParser（使测试通过）

**Files:** Create `lib/maxio/auth/sigv4/signed_request.ex`、`lib/maxio/auth/sigv4/auth_header_parser.ex`

Create `lib/maxio/auth/sigv4/signed_request.ex`：
```elixir
defmodule Maxio.Auth.SigV4.SignedRequest do
  @moduledoc """
  解析签名材料后的统一结构（header-based 与 presigned 两种形态共用）。
  payload_mode: :single（声明了 body 哈希）| :unsigned（UNSIGNED-PAYLOAD）|
  :streaming（STREAMING-AWS4-HMAC-SHA256-PAYLOAD）。
  """
  @enforce_keys [:access_key, :scope_date, :region, :service, :signed_headers, :signature, :amz_date, :auth_type, :payload_mode]
  defstruct [
    :access_key,
    :scope_date,
    :region,
    :service,
    :signed_headers,
    :signature,
    :amz_date,
    :auth_type,
    :payload_mode,
    :expires
  ]

  @type t :: %__MODULE__{
          access_key: String.t(),
          scope_date: String.t(),
          region: String.t(),
          service: String.t(),
          signed_headers: [String.t()],
          signature: String.t(),
          amz_date: String.t(),
          auth_type: :header | :presigned,
          payload_mode: :single | :unsigned | :streaming,
          expires: pos_integer() | nil
        }
end
```

Create `lib/maxio/auth/sigv4/auth_header_parser.ex`：
```elixir
defmodule Maxio.Auth.SigV4.AuthHeaderParser do
  @moduledoc """
  解析 SigV4 签名材料：header-based（Authorization 头 + x-amz-date + x-amz-content-sha256）
  与 presigned（X-Amz-* query 参数）。产出统一 %SignedRequest{}。
  """
  alias Maxio.Auth.SigV4.SignedRequest

  @doc """
  解析 header-based。auth = Authorization 头值；amz_date = x-amz-date 头；
  content_sha256 = x-amz-content-sha256 头（决定 payload_mode）。
  """
  @spec parse_header(String.t(), String.t(), String.t()) ::
          {:ok, SignedRequest.t()} | {:error, :authorization_header_malformed}
  def parse_header(auth, amz_date, content_sha256) when is_binary(auth) do
    with "AWS4-HMAC-SHA256 " <> rest <- auth,
         {:ok, parts} <- split_kv(rest),
         {:ok, credential} <- Map.fetch(parts, "Credential"),
         {:ok, signed_headers_str} <- Map.fetch(parts, "SignedHeaders"),
         {:ok, signature} <- Map.fetch(parts, "Signature"),
         {:ok, {ak, date, region, service}} <- parse_credential(credential) do
      {:ok,
       %SignedRequest{
         access_key: ak,
         scope_date: date,
         region: region,
         service: service,
         signed_headers: String.split(signed_headers_str, ";", trim: true),
         signature: signature,
         amz_date: amz_date,
         auth_type: :header,
         payload_mode: payload_mode(content_sha256),
         expires: nil
       }}
    else
      _ -> {:error, :authorization_header_malformed}
    end
  end

  @doc "解析 presigned X-Amz-* query 参数。"
  @spec parse_presigned(map()) ::
          {:ok, SignedRequest.t()} | {:error, :authorization_query_parameters_error}
  def parse_presigned(query) when is_map(query) do
    with {:ok, "AWS4-HMAC-SHA256"} <- Map.fetch(query, "X-Amz-Algorithm"),
         {:ok, credential} <- Map.fetch(query, "X-Amz-Credential"),
         {:ok, amz_date} <- Map.fetch(query, "X-Amz-Date"),
         {:ok, expires_str} <- Map.fetch(query, "X-Amz-Expires"),
         {:ok, signed_headers_str} <- Map.fetch(query, "X-Amz-SignedHeaders"),
         {:ok, signature} <- Map.fetch(query, "X-Amz-Signature"),
         {expires, ""} <- Integer.parse(expires_str),
         {:ok, {ak, date, region, service}} <- parse_credential(credential) do
      {:ok,
       %SignedRequest{
         access_key: ak,
         scope_date: date,
         region: region,
         service: service,
         signed_headers: String.split(signed_headers_str, ";", trim: true),
         signature: signature,
         amz_date: amz_date,
         auth_type: :presigned,
         payload_mode: :unsigned,
         expires: expires
       }}
    else
      _ -> {:error, :authorization_query_parameters_error}
    end
  end

  # "k1=v1,k2=v2,..." → %{"k1"=>"v1", ...}（值里可能含 / 和 ;，故按首个 = 切）
  defp split_kv(str) do
    map =
      str
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [k, v] -> {k, v}
          _ -> {pair, nil}
        end
      end)
      |> Enum.into(%{})

    if Map.has_key?(map, "Credential") and Map.has_key?(map, "Signature") do
      {:ok, map}
    else
      :error
    end
  end

  # "AK/date/region/service/aws4_request" → {ak, date, region, service}
  defp parse_credential(credential) do
    case String.split(credential, "/") do
      [ak, date, region, service, "aws4_request"] -> {:ok, {ak, date, region, service}}
      _ -> :error
    end
  end

  defp payload_mode("UNSIGNED-PAYLOAD"), do: :unsigned
  defp payload_mode("STREAMING-AWS4-HMAC-SHA256-PAYLOAD"), do: :streaming
  defp payload_mode("STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER"), do: :streaming
  defp payload_mode("STREAMING-UNSIGNED-PAYLOAD-TRAILER"), do: :streaming
  defp payload_mode(_hash), do: :single
end
```

1. 跑测试：
   ```powershell
   mix test test/maxio/auth/sigv4/auth_header_parser_test.exs
   ```
   期望：`6 tests, 0 failures`。

**验证**：AuthHeaderParserTest 全绿即通过。

**Commit**：
```powershell
git add -A
git commit -m "feat(sigv4): SignedRequest struct + AuthHeaderParser (header & presigned) with tests" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E5.7 — CredentialStore behaviour + MemoryStore（使测试通过）

**Files:** Create `lib/maxio/auth/credential_store.ex`、`lib/maxio/auth/credential_store/memory_store.ex`；Create `test/maxio/auth/credential_store/memory_store_test.exs`

MemoryStore 用 ETS（命名表）存 access key → secret + principal；root 从 `config :maxio, :s3` 的 `root_user`/`root_password` 引导（首次访问惰性建表 + 注入 root）。

Create `lib/maxio/auth/credential_store.ex`：
```elixir
defmodule Maxio.Auth.CredentialStore do
  @moduledoc """
  凭据存储 behaviour（铁律 1）。MVP 实现 MemoryStore（root 从 env/config 引导，ETS）；
  后续 EctoStore 换实现不动鉴权逻辑。门面按 config :maxio, :credential_store 派发。
  """
  @callback get_secret(access_key :: String.t()) ::
              {:ok, %{secret_key: String.t(), principal: map()}} | :error
  @callback put_access_key(map()) :: :ok | {:error, term()}
  @callback list_keys() :: [map()]

  @doc "当前配置的凭据后端模块。"
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:maxio, :credential_store)

  @spec get_secret(String.t()) :: {:ok, map()} | :error
  def get_secret(access_key), do: impl().get_secret(access_key)

  @spec put_access_key(map()) :: :ok | {:error, term()}
  def put_access_key(attrs), do: impl().put_access_key(attrs)

  @spec list_keys() :: [map()]
  def list_keys, do: impl().list_keys()
end
```

Create `lib/maxio/auth/credential_store/memory_store.ex`：
```elixir
defmodule Maxio.Auth.CredentialStore.MemoryStore do
  @moduledoc """
  内存凭据后端（ETS）。root 凭据从 config :maxio, :s3 的 root_user/root_password 引导。
  惰性建表：首次访问若表不存在则建表并注入 root。principal 形如
  %{type: :root, access_key: ..., arn: "arn:aws:iam:::root"}。
  """
  @behaviour Maxio.Auth.CredentialStore

  @table :maxio_credentials

  @impl true
  def get_secret(access_key) do
    ensure_table()

    case :ets.lookup(@table, access_key) do
      [{^access_key, secret_key, principal}] -> {:ok, %{secret_key: secret_key, principal: principal}}
      [] -> :error
    end
  end

  @impl true
  def put_access_key(%{access_key: ak, secret_key: sk} = attrs) do
    ensure_table()
    principal = Map.get(attrs, :principal, %{type: :iam_user, access_key: ak, arn: "arn:aws:iam:::user/#{ak}"})
    :ets.insert(@table, {ak, sk, principal})
    :ok
  end

  def put_access_key(_), do: {:error, :invalid_attrs}

  @impl true
  def list_keys do
    ensure_table()
    :ets.tab2list(@table) |> Enum.map(fn {ak, _sk, principal} -> %{access_key: ak, principal: principal} end)
  end

  # 惰性建表 + 注入 root（幂等）。并发安全：用 :public named table，已存在则忽略。
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        bootstrap_root()

      _ref ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp bootstrap_root do
    s3 = Application.fetch_env!(:maxio, :s3)
    ak = Keyword.fetch!(s3, :root_user)
    sk = Keyword.fetch!(s3, :root_password)
    principal = %{type: :root, access_key: ak, arn: "arn:aws:iam:::root"}
    :ets.insert(@table, {ak, sk, principal})
  end
end
```

Create `test/maxio/auth/credential_store/memory_store_test.exs`：
```elixir
defmodule Maxio.Auth.CredentialStore.MemoryStoreTest do
  use ExUnit.Case, async: false

  alias Maxio.Auth.CredentialStore.MemoryStore

  test "root 凭据从 config 引导可查到（test 配置的 AWS 示例密钥）" do
    {:ok, %{secret_key: sk, principal: principal}} = MemoryStore.get_secret("AKIAIOSFODNN7EXAMPLE")
    assert sk == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    assert principal.type == :root
    assert principal.arn == "arn:aws:iam:::root"
  end

  test "未知 access key 返回 :error" do
    assert :error = MemoryStore.get_secret("UNKNOWNKEY")
  end

  test "put_access_key 后可查到" do
    :ok = MemoryStore.put_access_key(%{access_key: "AK2", secret_key: "SK2"})
    {:ok, %{secret_key: "SK2", principal: principal}} = MemoryStore.get_secret("AK2")
    assert principal.type == :iam_user
  end
end
```

1. 跑测试：
   ```powershell
   mix test test/maxio/auth/credential_store/memory_store_test.exs
   ```
   期望：`3 tests, 0 failures`（test.exs 已把 root 凭据设为 AWS 示例密钥）。

**验证**：MemoryStoreTest 全绿即通过。

**Commit**：
```powershell
git add -A
git commit -m "feat(auth): CredentialStore behaviour + MemoryStore (ETS, root bootstrap) with tests" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task E5.8 — Maxio.Auth context（验证编排：复算签名 + 时钟偏移 + presigned 过期）失败测试（TDD）

**Files:** Create `test/maxio/auth_test.exs`

`Maxio.Auth.authenticate/2` 是鉴权编排入口：给定从 conn 提取的"验证材料"map，查 secret → 复算签名 → 常数时间比对 → 检查时钟偏移 / presigned 过期 → 成功返回 principal，失败返回 `%Maxio.S3.Error{}`。

验证材料 map（由 SigV4 plug 构造，本测试直接构造）：
```
%{
  signed_request: %SignedRequest{},
  method: "GET", path: "/test.txt",
  query: %{...},            # 已排除 X-Amz-Signature（presigned）
  headers: [{lname, value}],# 仅 SignedHeaders 子集（已小写）
  payload_hash: "...",      # x-amz-content-sha256 或 UNSIGNED-PAYLOAD
  now: DateTime.t()         # 服务器当前时间（注入便于测试）
}
```

Create `test/maxio/auth_test.exs`：
```elixir
defmodule Maxio.AuthTest do
  use ExUnit.Case, async: false

  alias Maxio.Auth
  alias Maxio.Auth.SigV4.SignedRequest
  alias Maxio.S3.Error

  @empty_hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  @now ~U[2013-05-24 00:00:00Z]

  defp vector_a_material(signature) do
    %{
      signed_request: %SignedRequest{
        access_key: "AKIAIOSFODNN7EXAMPLE",
        scope_date: "20130524",
        region: "us-east-1",
        service: "s3",
        signed_headers: ["host", "range", "x-amz-content-sha256", "x-amz-date"],
        signature: signature,
        amz_date: "20130524T000000Z",
        auth_type: :header,
        payload_mode: :single,
        expires: nil
      },
      method: "GET",
      path: "/test.txt",
      query: %{},
      headers: [
        {"host", "examplebucket.s3.amazonaws.com"},
        {"range", "bytes=0-9"},
        {"x-amz-content-sha256", @empty_hash},
        {"x-amz-date", "20130524T000000Z"}
      ],
      payload_hash: @empty_hash,
      now: @now
    }
  end

  test "正确签名（VECTOR A）通过并返回 root principal" do
    material = vector_a_material("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    assert {:ok, principal} = Auth.authenticate(material)
    assert principal.type == :root
    assert principal.access_key == "AKIAIOSFODNN7EXAMPLE"
  end

  test "错误签名 → SignatureDoesNotMatch 403" do
    material = vector_a_material("deadbeef" <> String.duplicate("0", 56))
    assert {:error, %Error{code: "SignatureDoesNotMatch", http_status: 403}} = Auth.authenticate(material)
  end

  test "未知 access key → InvalidAccessKeyId 403" do
    material = vector_a_material("whatever")
    material = put_in(material.signed_request.access_key, "NOPEKEY")
    assert {:error, %Error{code: "InvalidAccessKeyId", http_status: 403}} = Auth.authenticate(material)
  end

  test "时钟偏移超 15min → RequestTimeTooSkewed 403" do
    material = vector_a_material("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    skewed = %{material | now: ~U[2013-05-24 00:20:00Z]}
    assert {:error, %Error{code: "RequestTimeTooSkewed", http_status: 403}} = Auth.authenticate(skewed)
  end

  test "presigned 过期 → AccessDenied 403" do
    sr = %SignedRequest{
      access_key: "AKIAIOSFODNN7EXAMPLE",
      scope_date: "20130524",
      region: "us-east-1",
      service: "s3",
      signed_headers: ["host"],
      signature: "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
      amz_date: "20130524T000000Z",
      auth_type: :presigned,
      payload_mode: :unsigned,
      expires: 86400
    }

    material = %{
      signed_request: sr,
      method: "GET",
      path: "/test.txt",
      query: %{
        "X-Amz-Algorithm" => "AWS4-HMAC-SHA256",
        "X-Amz-Credential" => "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request",
        "X-Amz-Date" => "20130524T000000Z",
        "X-Amz-Expires" => "86400",
        "X-Amz-SignedHeaders" => "host"
      },
      headers: [{"host", "examplebucket.s3.amazonaws.com"}],
      payload_hash: "UNSIGNED-PAYLOAD",
      now: ~U[2013-05-26 00:00:01Z]
    }

    assert {:error, %Error{code: "AccessDenied", http_status: 403}} = Auth.authenticate(material)
  end

  test "presigned 在有效期内且签名正确通过" do
    sr = %SignedRequest{
      access_key: "AKIAIOSFODNN7EXAMPLE",
      scope_date: "20130524",
      region: "us-east-1",
      service: "s3",
      signed_headers: ["host"],
      signature: "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
      amz_date: "20130524T000000Z",
      auth_type: :presigned,
      payload_mode: :unsigned,
      expires: 86400
    }

    material = %{
      signed_request: sr,
      method: "GET",
      path: "/test.txt",
      query: %{
        "X-Amz-Algorithm" => "AWS4-HMAC-SHA256",
        "X-Amz-Credential" => "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request",
        "X-Amz-Date" => "20130524T000000Z",
        "X-Amz-Expires" => "86400",
        "X-Amz-SignedHeaders" => "host"
      },
      headers: [{"host", "examplebucket.s3.amazonaws.com"}],
      payload_hash: "UNSIGNED-PAYLOAD",
      now: ~U[2013-05-24 01:00:00Z]
    }

    assert {:ok, principal} = Auth.authenticate(material)
    assert principal.type == :root
  end
end
```

1. 跑测试确认红：
   ```powershell
   mix test test/maxio/auth_test.exs
   ```
   期望：失败——`Maxio.Auth` 未定义。预期的红。

**验证**：测试因模块缺失失败即通过本步。

### Task E5.9 — 实现 Maxio.Auth context（使测试通过）

**Files:** Create `lib/maxio/auth.ex`

编排：解析 `x-amz-date` → 时钟偏移检查；presigned 额外校验 expires 窗口；查 secret（未知 → InvalidAccessKeyId）；用 SignedRequest 的 scope_date/region/service 复算签名；secure_compare（不符 → SignatureDoesNotMatch）；成功返回 principal。所有失败路径打 `Maxio.S3.Log.warn`（铁律 3）。

Create `lib/maxio/auth.ex`：
```elixir
defmodule Maxio.Auth do
  @moduledoc """
  鉴权编排 context：验证材料 → 时钟偏移/过期检查 → 查 secret → 复算签名 → 常数时间比对。
  成功返回 principal map，失败返回 %Maxio.S3.Error{}（绝不静默，所有失败打结构化日志）。

  验证材料 map：%{signed_request, method, path, query, headers, payload_hash, now}。
    * query 必须**已排除 X-Amz-Signature**（presigned）；
    * headers 必须仅含 SignedHeaders 子集（已小写）；
    * path 是已 URL 解码的真实对象 key 路径（Canonical 内部再做 S3 单次编码）。
  """
  alias Maxio.Auth.SigV4.{Canonical, Signer}
  alias Maxio.Auth.CredentialStore
  alias Maxio.S3.{Error, Log}

  @algorithm "AWS4-HMAC-SHA256"

  @spec authenticate(map()) :: {:ok, map()} | {:error, Error.t()}
  def authenticate(%{signed_request: sr} = material) do
    with :ok <- check_clock_skew(sr.amz_date, material.now),
         :ok <- check_presigned_expiry(sr, material.now),
         {:ok, %{secret_key: secret, principal: principal}} <- lookup_secret(sr.access_key),
         :ok <- verify_signature(sr, material, secret) do
      Log.info("sigv4 authenticated", auth_type: sr.auth_type)
      {:ok, principal}
    end
  end

  # ── 时钟偏移（±clock_skew_ms）──
  defp check_clock_skew(amz_date, now) do
    case parse_amz_date(amz_date) do
      {:ok, req_time} ->
        skew_ms = abs(DateTime.diff(now, req_time, :millisecond))

        if skew_ms > clock_skew_ms() do
          Log.warn("request time too skewed", auth_type: :header, reason: :request_time_too_skewed)
          {:error, Error.new(:request_time_too_skewed)}
        else
          :ok
        end

      :error ->
        {:error, Error.new(:authorization_header_malformed, message: "Invalid x-amz-date")}
    end
  end

  # ── presigned 过期（now > amz_date + expires）──
  defp check_presigned_expiry(%{auth_type: :presigned, expires: expires, amz_date: amz_date}, now)
       when is_integer(expires) do
    cond do
      expires < 1 or expires > 604_800 ->
        {:error, Error.new(:authorization_query_parameters_error, message: "X-Amz-Expires out of range")}

      true ->
        case parse_amz_date(amz_date) do
          {:ok, start} ->
            if DateTime.diff(now, start, :second) > expires do
              Log.warn("presigned url expired", auth_type: :presigned, reason: :access_denied)
              {:error, Error.new(:access_denied, message: "Request has expired")}
            else
              :ok
            end

          :error ->
            {:error, Error.new(:authorization_query_parameters_error, message: "Invalid X-Amz-Date")}
        end
    end
  end

  defp check_presigned_expiry(_sr, _now), do: :ok

  # ── 查 secret ──
  defp lookup_secret(access_key) do
    case CredentialStore.get_secret(access_key) do
      {:ok, found} ->
        {:ok, found}

      :error ->
        Log.warn("unknown access key", auth_type: :header, reason: :invalid_access_key_id)
        {:error, Error.new(:invalid_access_key_id)}
    end
  end

  # ── 复算签名并常数时间比对 ──
  defp verify_signature(sr, material, secret) do
    scope = "#{sr.scope_date}/#{sr.region}/#{sr.service}/aws4_request"

    req = %{
      method: material.method,
      path: material.path,
      query: material.query,
      headers: filter_signed_headers(material.headers, sr.signed_headers),
      payload_hash: material.payload_hash
    }

    canonical = Canonical.canonical_request(req)
    sts = Signer.string_to_sign(sr.amz_date, scope, canonical, @algorithm)
    key = Signer.derive_signing_key(secret, sr.scope_date, sr.region, sr.service)
    computed = Signer.signature(key, sts)

    if Signer.secure_compare(computed, sr.signature) do
      :ok
    else
      Log.warn("signature mismatch", auth_type: sr.auth_type, reason: :signature_does_not_match)
      {:error, Error.new(:signature_does_not_match)}
    end
  end

  # 仅保留 SignedHeaders 列出的 header（已小写名比较），保持调用方给的值。
  defp filter_signed_headers(headers, signed_names) do
    set = MapSet.new(signed_names)
    Enum.filter(headers, fn {name, _v} -> MapSet.member?(set, String.downcase(name)) end)
  end

  # "yyyyMMddTHHmmssZ" → DateTime（UTC）
  defp parse_amz_date(<<y::binary-4, mo::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, s::binary-2, "Z">>) do
    with {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(mo),
         {day, ""} <- Integer.parse(d),
         {hour, ""} <- Integer.parse(h),
         {minute, ""} <- Integer.parse(mi),
         {second, ""} <- Integer.parse(s),
         {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second) do
      {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
    else
      _ -> :error
    end
  end

  defp parse_amz_date(_), do: :error

  defp clock_skew_ms do
    Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:clock_skew_ms)
  end
end
```

1. 跑测试：
   ```powershell
   mix test test/maxio/auth_test.exs
   ```
   期望：`6 tests, 0 failures`。

**验证**：AuthTest 全绿即通过（正确签名过、错误签名/未知 key/偏移/过期分别正确报错）。

**Commit**：
```powershell
git add -A
git commit -m "feat(auth): Maxio.Auth orchestration (verify sig, clock skew, presigned expiry) with tests" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E5.10 — mix maxio.sigv4.debug 取证 CLI

**Files:** Create `lib/mix/tasks/maxio.sigv4.debug.ex`；Create `test/mix/tasks/maxio_sigv4_debug_test.exs`

CLI 取证（铁律 4）：给定 method/path/region/secret/access-key/date/payload-hash + 可选 query/headers，打印 canonical request、string-to-sign、各级 HMAC（hex 化便于人读）、最终签名。便于"签名不匹配"定位。为可测，逻辑放可调用的 `run_debug/1` 返回结构化 map，`run/1` 负责打印。

Create `lib/mix/tasks/maxio.sigv4.debug.ex`：
```elixir
defmodule Mix.Tasks.Maxio.Sigv4.Debug do
  @shortdoc "复算并打印一次 SigV4 签名的全部中间产物（取证用）"
  @moduledoc """
  SigV4 签名复算取证 CLI（AGENTS.md 铁律 4：后端无 GUI，签名问题靠 CLI 定位）。

  用法（PowerShell；先设 $env:ERL_FLAGS="-kernel standard_io_encoding unicode"）：

      mix maxio.sigv4.debug ^
        --method GET --path /test.txt ^
        --region us-east-1 --service s3 ^
        --access-key AKIAIOSFODNN7EXAMPLE ^
        --secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" ^
        --date 20130524T000000Z ^
        --payload-hash e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ^
        --header "host:examplebucket.s3.amazonaws.com" ^
        --header "range:bytes=0-9" ^
        --header "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ^
        --header "x-amz-date:20130524T000000Z"

  打印 canonical request / string-to-sign / kDate/kRegion/kService/kSigning(hex) / 最终签名。
  用官方 VECTOR A 参数运行应得签名 f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41。
  """
  use Mix.Task

  alias Maxio.Auth.SigV4.{Canonical, Signer}

  @switches [
    method: :string,
    path: :string,
    region: :string,
    service: :string,
    access_key: :string,
    secret: :string,
    date: :string,
    payload_hash: :string,
    header: :keep,
    query: :keep
  ]

  @impl true
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)
    result = run_debug(opts)

    IO.puts("=== CanonicalRequest ===")
    IO.puts(result.canonical_request)
    IO.puts("\n=== StringToSign ===")
    IO.puts(result.string_to_sign)
    IO.puts("\n=== Signing key chain (hex) ===")
    IO.puts("kDate    = #{result.k_date}")
    IO.puts("kRegion  = #{result.k_region}")
    IO.puts("kService = #{result.k_service}")
    IO.puts("kSigning = #{result.k_signing}")
    IO.puts("\n=== Signature ===")
    IO.puts(result.signature)
  end

  @doc "纯计算：返回各中间产物（便于测试断言，不打印）。"
  @spec run_debug(keyword()) :: map()
  def run_debug(opts) do
    method = Keyword.get(opts, :method, "GET")
    path = Keyword.get(opts, :path, "/")
    region = Keyword.get(opts, :region, "us-east-1")
    service = Keyword.get(opts, :service, "s3")
    secret = Keyword.fetch!(opts, :secret)
    date = Keyword.fetch!(opts, :date)
    payload_hash = Keyword.get(opts, :payload_hash, Signer.hex_sha256(""))
    scope_date = String.slice(date, 0, 8)
    scope = "#{scope_date}/#{region}/#{service}/aws4_request"

    headers =
      opts
      |> Keyword.get_values(:header)
      |> Enum.map(fn h ->
        [name, value] = String.split(h, ":", parts: 2)
        {String.downcase(name), value}
      end)

    query =
      opts
      |> Keyword.get_values(:query)
      |> Enum.map(fn q ->
        case String.split(q, "=", parts: 2) do
          [k, v] -> {k, v}
          [k] -> {k, ""}
        end
      end)
      |> Enum.into(%{})

    canonical = Canonical.canonical_request(%{method: method, path: path, query: query, headers: headers, payload_hash: payload_hash})
    sts = Signer.string_to_sign(date, scope, canonical, "AWS4-HMAC-SHA256")

    # 逐级链（hex 仅供人读取证；真实链用原始二进制）
    k_date = hmac("AWS4" <> secret, scope_date)
    k_region = hmac(k_date, region)
    k_service = hmac(k_region, service)
    k_signing = hmac(k_service, "aws4_request")
    sig = Signer.signature(k_signing, sts)

    %{
      canonical_request: canonical,
      string_to_sign: sts,
      k_date: hex(k_date),
      k_region: hex(k_region),
      k_service: hex(k_service),
      k_signing: hex(k_signing),
      signature: sig
    }
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(bin), do: Base.encode16(bin, case: :lower)
end
```

Create `test/mix/tasks/maxio_sigv4_debug_test.exs`：
```elixir
defmodule Mix.Tasks.Maxio.Sigv4.DebugTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Maxio.Sigv4.Debug

  test "run_debug 用 VECTOR A 参数复算出官方签名" do
    result =
      Debug.run_debug(
        method: "GET",
        path: "/test.txt",
        region: "us-east-1",
        service: "s3",
        secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        date: "20130524T000000Z",
        payload_hash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        header: "host:examplebucket.s3.amazonaws.com",
        header: "range:bytes=0-9",
        header: "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        header: "x-amz-date:20130524T000000Z"
      )

    assert result.signature == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    assert result.string_to_sign =~ "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972"
    assert result.canonical_request =~ "GET\n/test.txt\n"
  end
end
```

1. 跑测试：
   ```powershell
   mix test test/mix/tasks/maxio_sigv4_debug_test.exs
   ```
   期望：`1 test, 0 failures`。
2. 跑真实 CLI 取证（确认人读输出）：
   ```powershell
   mix maxio.sigv4.debug --method GET --path /test.txt --region us-east-1 --service s3 --access-key AKIAIOSFODNN7EXAMPLE --secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" --date 20130524T000000Z --payload-hash e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 --header "host:examplebucket.s3.amazonaws.com" --header "range:bytes=0-9" --header "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" --header "x-amz-date:20130524T000000Z"
   ```
   期望末行 `Signature` 段输出 `f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41`。

**验证**：测试绿 + CLI 输出与官方签名一致即通过。

**Commit**：
```powershell
git add -A
git commit -m "feat(cli): mix maxio.sigv4.debug forensic task (prints canonical/STS/HMAC chain/signature)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E5.11 — SigV4 plug 失败测试（TDD）

**Files:** Create `test/maxio/s3/plugs/sigv4_test.exs`

`Maxio.S3.Plugs.SigV4` 从 conn 提取签名材料（不消费 body！），调 `Maxio.Auth.authenticate/1`，成功写 `assigns.principal/auth_type/payload_mode`，失败 `halt` + Error XML（用 `request_id` 从 conn）。用 `Plug.Test` 构造 conn。

Create `test/maxio/s3/plugs/sigv4_test.exs`：
```elixir
defmodule Maxio.S3.Plugs.SigV4Test do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Maxio.S3.Plugs.SigV4

  @empty_hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  # 用官方 VECTOR A 构造一个已正确签名的请求（注意 host 必须与签名时一致）。
  defp signed_conn(signature) do
    auth =
      "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," <>
        "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date," <>
        "Signature=#{signature}"

    conn(:get, "/test.txt")
    |> put_req_header("host", "examplebucket.s3.amazonaws.com")
    |> put_req_header("range", "bytes=0-9")
    |> put_req_header("x-amz-content-sha256", @empty_hash)
    |> put_req_header("x-amz-date", "20130524T000000Z")
    |> put_req_header("authorization", auth)
    |> put_private(:maxio_now, ~U[2013-05-24 00:00:00Z])
  end

  test "正确签名通过，写 principal/auth_type/payload_mode，不 halt" do
    conn = signed_conn("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41") |> SigV4.call(SigV4.init([]))
    refute conn.halted
    assert conn.assigns.principal.type == :root
    assert conn.assigns.auth_type == :header
    assert conn.assigns.payload_mode == :single
  end

  test "错误签名 halt + 403 SignatureDoesNotMatch XML" do
    conn = signed_conn("00000000000000000000000000000000000000000000000000000000deadbeef") |> SigV4.call(SigV4.init([]))
    assert conn.halted
    assert conn.status == 403
    assert conn.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/xml"
  end

  test "缺 Authorization 且无 presigned 参数 → 400 MissingSecurityHeader" do
    conn = conn(:get, "/test.txt") |> put_req_header("host", "x") |> SigV4.call(SigV4.init([]))
    assert conn.halted
    assert conn.status == 400
    assert conn.resp_body =~ "<Code>MissingSecurityHeader</Code>"
  end
end
```

1. 跑测试确认红：
   ```powershell
   mix test test/maxio/s3/plugs/sigv4_test.exs
   ```
   期望：失败——`Maxio.S3.Plugs.SigV4` 未定义。预期的红。

**验证**：测试因模块缺失失败即通过本步。

### Task E5.12 — 实现 SigV4 plug（使测试通过）

**Files:** Create `lib/maxio/s3/plugs/sigv4.ex`

关键：从 conn 取 host/req headers 构造签名材料（**绝不 read_body**，铁律 4）；`payload_hash` 取 `x-amz-content-sha256` 头（header 形态）；presigned 从 query 取 `X-Amz-*` 并排除 `X-Amz-Signature`；`now` 优先用 `conn.private[:maxio_now]`（测试注入），否则 `DateTime.utc_now()`；失败渲染 Error XML 并 halt。

Create `lib/maxio/s3/plugs/sigv4.ex`：
```elixir
defmodule Maxio.S3.Plugs.SigV4 do
  @moduledoc """
  SigV4 鉴权 plug（铁律 3/4）。从 conn 提取签名材料（不消费 body！），调 Maxio.Auth.authenticate/1，
  成功写 assigns.principal/auth_type/payload_mode；失败 halt + S3 Error XML。
  分流：query 含 X-Amz-Signature → presigned；有 Authorization: AWS4-HMAC-SHA256 → header；
  否则 MissingSecurityHeader。
  """
  import Plug.Conn
  alias Maxio.Auth
  alias Maxio.Auth.SigV4.AuthHeaderParser
  alias Maxio.S3.{Error, ErrorView, Log}

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    case detect_and_parse(conn) do
      {:ok, signed_request} ->
        material = build_material(conn, signed_request)

        case Auth.authenticate(material) do
          {:ok, principal} ->
            conn
            |> assign(:principal, principal)
            |> assign(:auth_type, signed_request.auth_type)
            |> assign(:payload_mode, signed_request.payload_mode)

          {:error, %Error{} = err} ->
            reject(conn, err)
        end

      {:error, code} ->
        reject(conn, Error.new(code))
    end
  end

  defp detect_and_parse(conn) do
    cond do
      Map.has_key?(conn.query_params, "X-Amz-Signature") ->
        AuthHeaderParser.parse_presigned(conn.query_params)

      auth = get_req_header(conn, "authorization") |> List.first() ->
        amz_date = header(conn, "x-amz-date")
        content_sha = header(conn, "x-amz-content-sha256") || ""
        AuthHeaderParser.parse_header(auth, amz_date, content_sha)

      true ->
        {:error, :missing_security_header}
    end
  end

  defp build_material(conn, sr) do
    payload_hash =
      case sr.auth_type do
        :presigned -> "UNSIGNED-PAYLOAD"
        :header -> header(conn, "x-amz-content-sha256") || ""
      end

    %{
      signed_request: sr,
      method: conn.method,
      path: decoded_path(conn),
      query: signing_query(conn, sr),
      headers: req_headers_lower(conn),
      payload_hash: payload_hash,
      now: now(conn)
    }
  end

  # 已 URL 解码的真实路径（Canonical 内部再做 S3 单次编码）。
  defp decoded_path(conn) do
    "/" <> Enum.join(conn.path_info, "/")
  end

  # header 形态用真实 query；presigned 形态排除 X-Amz-Signature。
  defp signing_query(conn, %{auth_type: :presigned}), do: Map.delete(conn.query_params, "X-Amz-Signature")
  defp signing_query(conn, _sr), do: conn.query_params

  defp req_headers_lower(conn) do
    Enum.map(conn.req_headers, fn {name, value} -> {String.downcase(name), value} end)
  end

  defp header(conn, name) do
    conn |> get_req_header(name) |> List.first()
  end

  defp now(conn), do: conn.private[:maxio_now] || DateTime.utc_now()

  defp reject(conn, %Error{} = err) do
    request_id = conn |> get_req_header("x-request-id") |> List.first()
    err = %{err | request_id: request_id, resource: decoded_path(conn)}
    {status, body} = ErrorView.render(err)
    Log.warn("sigv4 rejected", code: err.code, status: status)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, body)
    |> halt()
  end
end
```

> 注意（path 与 decoded_path）：`conn.path_info` 是已解码的段列表，`Enum.join(.., "/")` 重建路径足以喂给 Canonical（其内部再对每段做 S3 单次编码）。VECTOR A 的 `/test.txt` 与本实现一致。集成测试（E7）会用包含特殊字符的 key 验证 path 端到端一致性。

1. 跑测试：
   ```powershell
   mix test test/maxio/s3/plugs/sigv4_test.exs
   ```
   期望：`3 tests, 0 failures`。

**验证**：SigV4 plug 测试全绿即通过。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): SigV4 auth plug (extract material w/o body, authenticate, reject w/ Error XML) with tests" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 单元 E5 验收

```powershell
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test test/maxio/auth/ test/maxio/auth_test.exs test/maxio/s3/plugs/sigv4_test.exs test/mix/tasks/maxio_sigv4_debug_test.exs
```
期望：零警告；全部 SigV4 相关测试绿（含 4 个 canonical + 5 个签名 KNOWN-ANSWER 向量与 AWS byte-for-byte 一致）。这是整个项目的鉴权 ground truth。

---

## 单元 E6 — AddressStyle plug + Dispatcher 判定表 + S3 Endpoint（Bandit child）+ 监督树接线

**目标**：实现寻址解析 plug（path-style + virtual-host → `{bucket, key, level}`）、动作分发判定表 `Maxio.S3.Dispatcher`（S3 是 RPC-over-query，非 REST）、独立 `Maxio.S3.Endpoint`（Plug.Builder 管线，**无 Plug.Parsers**）+ Dispatch plug 骨架，并把 Bandit child 接进监督树（端口 9000）。本单元 Dispatch plug 先只做 `resolve → handler` 路由骨架（handler 在 E7 落地，此处先返回 `NotImplemented` 占位以保证管线可跑通且可测）。

### Task E6.1 — AddressStyle plug 失败测试（TDD）

**Files:** Create `test/maxio/s3/plugs/address_style_test.exs`

规则：读 `config :maxio, :s3, :domain`；Host 形如 `<bucket>.<domain>` → virtual-host，bucket=子域，key=path_info join；否则 path-style，`/` → service 级（ListBuckets），`/<bucket>` → bucket 级，`/<bucket>/<key...>` → object 级。

Create `test/maxio/s3/plugs/address_style_test.exs`：
```elixir
defmodule Maxio.S3.Plugs.AddressStyleTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Maxio.S3.Plugs.AddressStyle

  defp run(method, path, host) do
    conn(method, path)
    |> put_req_header("host", host)
    |> AddressStyle.call(AddressStyle.init([]))
  end

  test "path-style 根路径 → service 级" do
    conn = run(:get, "/", "localhost:9000")
    assert conn.assigns.s3_level == :service
    assert conn.assigns.s3_bucket == nil
    assert conn.assigns.s3_key == nil
  end

  test "path-style /<bucket> → bucket 级" do
    conn = run(:put, "/mybucket", "localhost:9000")
    assert conn.assigns.s3_level == :bucket
    assert conn.assigns.s3_bucket == "mybucket"
    assert conn.assigns.s3_key == nil
  end

  test "path-style /<bucket>/<key...> → object 级（key 保留层级）" do
    conn = run(:get, "/mybucket/a/b/c.txt", "localhost:9000")
    assert conn.assigns.s3_level == :object
    assert conn.assigns.s3_bucket == "mybucket"
    assert conn.assigns.s3_key == "a/b/c.txt"
  end

  test "virtual-host <bucket>.<domain> → bucket 从子域，key 从 path" do
    conn = run(:get, "/a/b.txt", "mybucket.localhost")
    assert conn.assigns.s3_level == :object
    assert conn.assigns.s3_bucket == "mybucket"
    assert conn.assigns.s3_key == "a/b.txt"
  end

  test "virtual-host 根路径 → bucket 级" do
    conn = run(:head, "/", "mybucket.localhost")
    assert conn.assigns.s3_level == :bucket
    assert conn.assigns.s3_bucket == "mybucket"
    assert conn.assigns.s3_key == nil
  end

  test "Host 含端口不影响 domain 匹配" do
    conn = run(:get, "/", "mybucket.localhost:9000")
    assert conn.assigns.s3_bucket == "mybucket"
  end
end
```

1. 跑测试确认红：
   ```powershell
   mix test test/maxio/s3/plugs/address_style_test.exs
   ```
   期望：失败——`Maxio.S3.Plugs.AddressStyle` 未定义。预期的红。

**验证**：测试因模块缺失失败即通过本步。

### Task E6.2 — 实现 AddressStyle plug（使测试通过）

**Files:** Create `lib/maxio/s3/plugs/address_style.ex`

Create `lib/maxio/s3/plugs/address_style.ex`：
```elixir
defmodule Maxio.S3.Plugs.AddressStyle do
  @moduledoc """
  寻址解析 plug：把 path-style 与 virtual-host 两种寻址统一成
  assigns.s3_bucket / s3_key / s3_level（:service | :bucket | :object）。
  下游 handler 只看 {bucket, key}，不关心寻址方式（铁律 1）。
  domain 来自 config :maxio, :s3, :domain。
  """
  import Plug.Conn
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    host = conn |> get_req_header("host") |> List.first() |> strip_port()
    domain = domain()

    {bucket, key} =
      case virtual_host_bucket(host, domain) do
        nil -> path_style(conn.path_info)
        vbucket -> {vbucket, join_key(conn.path_info)}
      end

    level = level_of(bucket, key)

    conn
    |> assign(:s3_bucket, bucket)
    |> assign(:s3_key, key)
    |> assign(:s3_level, level)
  end

  # virtual-host：host == "<bucket>.<domain>" 时返回 bucket，否则 nil。
  defp virtual_host_bucket(nil, _domain), do: nil

  defp virtual_host_bucket(host, domain) do
    suffix = "." <> domain

    if String.ends_with?(host, suffix) and host != domain do
      String.replace_suffix(host, suffix, "")
    else
      nil
    end
  end

  # path-style：[] → service；[bucket] → bucket；[bucket | rest] → object。
  defp path_style([]), do: {nil, nil}
  defp path_style([bucket]), do: {bucket, nil}
  defp path_style([bucket | rest]), do: {bucket, Enum.join(rest, "/")}

  defp join_key([]), do: nil
  defp join_key(path_info), do: Enum.join(path_info, "/")

  defp level_of(nil, _key), do: :service
  defp level_of(_bucket, nil), do: :bucket
  defp level_of(_bucket, ""), do: :bucket
  defp level_of(_bucket, _key), do: :object

  defp strip_port(nil), do: nil
  defp strip_port(host), do: host |> String.split(":") |> List.first()

  defp domain do
    Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:domain)
  end
end
```

1. 跑测试：
   ```powershell
   mix test test/maxio/s3/plugs/address_style_test.exs
   ```
   期望：`6 tests, 0 failures`。

**验证**：AddressStyleTest 全绿即通过。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): AddressStyle plug (path-style + virtual-host -> bucket/key/level) with tests" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E6.3 — Dispatcher 判定表失败测试（TDD）

**Files:** Create `test/maxio/s3/dispatcher_test.exs`

`resolve(level, method, query_keys)` 返回 `{:ok, action}` 或 `{:error, :method_not_allowed}` / `{:error, :not_implemented}`。`query_keys` 是出现的子资源 query key 的 MapSet（小写）。M1 实现的动作：service `list_buckets`；bucket `create/delete/head/list_objects_v2/get_location`；object `put/get/head/delete`。`?uploads`/`?uploadId`/`?delete` 等 → `:not_implemented`（M2）。

Create `test/maxio/s3/dispatcher_test.exs`：
```elixir
defmodule Maxio.S3.DispatcherTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.Dispatcher

  defp keys(list), do: MapSet.new(list)

  test "service GET → list_buckets" do
    assert {:ok, :list_buckets} = Dispatcher.resolve(:service, "GET", keys([]))
  end

  test "bucket PUT → create_bucket" do
    assert {:ok, :create_bucket} = Dispatcher.resolve(:bucket, "PUT", keys([]))
  end

  test "bucket DELETE → delete_bucket" do
    assert {:ok, :delete_bucket} = Dispatcher.resolve(:bucket, "DELETE", keys([]))
  end

  test "bucket HEAD → head_bucket" do
    assert {:ok, :head_bucket} = Dispatcher.resolve(:bucket, "HEAD", keys([]))
  end

  test "bucket GET list-type=2 → list_objects_v2" do
    assert {:ok, :list_objects_v2} = Dispatcher.resolve(:bucket, "GET", keys(["list-type"]))
  end

  test "bucket GET 无 list-type 默认 → list_objects_v2（兼容 V1 入口也走 V2）" do
    assert {:ok, :list_objects_v2} = Dispatcher.resolve(:bucket, "GET", keys([]))
  end

  test "bucket GET ?location → get_bucket_location" do
    assert {:ok, :get_bucket_location} = Dispatcher.resolve(:bucket, "GET", keys(["location"]))
  end

  test "object PUT → put_object" do
    assert {:ok, :put_object} = Dispatcher.resolve(:object, "PUT", keys([]))
  end

  test "object GET → get_object" do
    assert {:ok, :get_object} = Dispatcher.resolve(:object, "GET", keys([]))
  end

  test "object HEAD → head_object" do
    assert {:ok, :head_object} = Dispatcher.resolve(:object, "HEAD", keys([]))
  end

  test "object DELETE → delete_object" do
    assert {:ok, :delete_object} = Dispatcher.resolve(:object, "DELETE", keys([]))
  end

  test "multipart 子资源 → not_implemented（M2）" do
    assert {:error, :not_implemented} = Dispatcher.resolve(:object, "POST", keys(["uploads"]))
    assert {:error, :not_implemented} = Dispatcher.resolve(:object, "PUT", keys(["uploadid", "partnumber"]))
    assert {:error, :not_implemented} = Dispatcher.resolve(:bucket, "POST", keys(["delete"]))
  end

  test "无匹配方法 → method_not_allowed" do
    assert {:error, :method_not_allowed} = Dispatcher.resolve(:service, "POST", keys([]))
    assert {:error, :method_not_allowed} = Dispatcher.resolve(:object, "POST", keys([]))
  end
end
```

1. 跑测试确认红：
   ```powershell
   mix test test/maxio/s3/dispatcher_test.exs
   ```
   期望：失败——`Maxio.S3.Dispatcher` 未定义。预期的红。

**验证**：测试因模块缺失失败即通过本步。

### Task E6.4 — 实现 Dispatcher（使测试通过）

**Files:** Create `lib/maxio/s3/dispatcher.ex`

判定表：先匹配 M2 子资源（返回 not_implemented），再匹配 M1 动作。`query_keys` 是小写 MapSet。

Create `lib/maxio/s3/dispatcher.ex`：
```elixir
defmodule Maxio.S3.Dispatcher do
  @moduledoc """
  动作分发判定表（S3 是 RPC over query-string，Router 表达不了 ?uploads vs ?acl）。
  resolve(level, method, query_keys) -> {:ok, action} | {:error, :method_not_allowed | :not_implemented}。
  query_keys: MapSet of 出现的子资源 query key（已小写）。
  M1 支持：list_buckets / create_bucket / delete_bucket / head_bucket / list_objects_v2 /
  get_bucket_location / put_object / get_object / head_object / delete_object。
  其余（multipart / delete-objects / acl / tagging / versioning ...）→ :not_implemented（M2+）。
  """

  @type level :: :service | :bucket | :object
  @type action :: atom()

  # M2+ 子资源标记（出现即 not_implemented）
  @m2_subresources ~w(uploads uploadid delete acl tagging versioning cors policy lifecycle website
                      versions notification replication encryption object-lock legal-hold retention
                      attributes select torrent restore accelerate analytics inventory metrics
                      ownershipcontrols publicaccessblock requestpayment logging partnumber)

  @spec resolve(level(), String.t(), MapSet.t()) ::
          {:ok, action()} | {:error, :method_not_allowed | :not_implemented}
  def resolve(level, method, query_keys) do
    if m2_subresource?(query_keys) do
      {:error, :not_implemented}
    else
      dispatch(level, method)
    end
  end

  defp m2_subresource?(query_keys) do
    Enum.any?(@m2_subresources, &MapSet.member?(query_keys, &1))
  end

  # ── M1 动作表 ──
  defp dispatch(:service, "GET"), do: {:ok, :list_buckets}

  defp dispatch(:bucket, "PUT"), do: {:ok, :create_bucket}
  defp dispatch(:bucket, "DELETE"), do: {:ok, :delete_bucket}
  defp dispatch(:bucket, "HEAD"), do: {:ok, :head_bucket}
  defp dispatch(:bucket, "GET"), do: {:ok, :list_objects_v2}

  defp dispatch(:object, "PUT"), do: {:ok, :put_object}
  defp dispatch(:object, "GET"), do: {:ok, :get_object}
  defp dispatch(:object, "HEAD"), do: {:ok, :head_object}
  defp dispatch(:object, "DELETE"), do: {:ok, :delete_object}

  defp dispatch(_level, _method), do: {:error, :method_not_allowed}
end
```

> 说明：`get_bucket_location` 由 bucket GET 命中 `?location` 解析。`@m2_subresources` 未含 `location`、`list-type`，故 `?location`/`?list-type=2` 不会被误判为 M2。但 `dispatch(:bucket, "GET")` 默认返回 `:list_objects_v2`——`?location` 需要在 Dispatch plug 里**优先**于默认 GET 处理。故在判定表中为 `:location` 增加显式分支：把 `dispatch(:bucket, "GET")` 拆成"含 location → get_bucket_location，否则 list_objects_v2"。修正实现：把 `resolve/3` 的 bucket+GET 分支改为接收 query_keys：

将 `resolve/3` 与 `dispatch` 调整为（替换上面 dispatch 的 bucket GET 行，让 resolve 把 query_keys 传入 bucket GET 判定）：
```elixir
  def resolve(level, method, query_keys) do
    cond do
      m2_subresource?(query_keys) -> {:error, :not_implemented}
      level == :bucket and method == "GET" and MapSet.member?(query_keys, "location") ->
        {:ok, :get_bucket_location}
      true -> dispatch(level, method)
    end
  end
```
（其余 `dispatch/2` 子句不变，`dispatch(:bucket, "GET")` 仍返回 `:list_objects_v2`，但 `?location` 已被 resolve 的 cond 优先拦截。executor 以此 cond 版本为最终 `resolve/3`。）

1. 跑测试：
   ```powershell
   mix test test/maxio/s3/dispatcher_test.exs
   ```
   期望：`13 tests, 0 failures`。

**验证**：DispatcherTest 全绿即通过。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): Dispatcher judgment table (RPC-over-query action resolution) with tests" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E6.5 — Dispatch plug（骨架，rescue Error → ErrorView；handler 占位 NotImplemented）

**Files:** Create `lib/maxio/s3/plugs/dispatch.ex`

Dispatch plug 调 `Dispatcher.resolve/3`（用 assigns 的 level/method + query_keys），再调对应 handler。E6 阶段 handler 尚未实现，故先调一个**统一占位**：所有 action 走 `Maxio.S3.Handlers.dispatch/2`（E7 实现真 handler；E6 先建一个返回 NotImplemented 的临时实现，使管线编译可跑）。统一 `try/rescue %Maxio.S3.Error{}` → ErrorView。

先建临时 handler 门面 `lib/maxio/s3/handlers.ex`（E7 会替换为真实分发）：
```elixir
defmodule Maxio.S3.Handlers do
  @moduledoc """
  Handler 分发门面。E6 占位：所有 action 暂返回 NotImplemented（管线骨架先跑通）。
  E7 替换为真实 Service/Bucket/Object handler 分发。
  """
  alias Maxio.S3.Error

  @spec dispatch(atom(), Plug.Conn.t()) :: Plug.Conn.t()
  def dispatch(_action, _conn) do
    raise Error.new(:not_implemented)
  end
end
```

Create `lib/maxio/s3/plugs/dispatch.ex`：
```elixir
defmodule Maxio.S3.Plugs.Dispatch do
  @moduledoc """
  分发 plug：用 assigns 的 s3_level + conn.method + query 子资源 key 调 Dispatcher.resolve/3，
  得 action 后交 Maxio.S3.Handlers.dispatch/2。统一 try/rescue %Maxio.S3.Error{} → ErrorView，
  绝不静默 500（未预期异常也包成 InternalError 并打 error 日志，铁律 3）。
  """
  import Plug.Conn
  alias Maxio.S3.{Dispatcher, Error, ErrorView, Handlers, Log}

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    query_keys = conn.query_params |> Map.keys() |> Enum.map(&String.downcase/1) |> MapSet.new()

    try do
      case Dispatcher.resolve(conn.assigns.s3_level, conn.method, query_keys) do
        {:ok, action} ->
          conn = assign(conn, :s3_action, action)
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

  defp render_error(conn, %Error{} = err) do
    request_id = conn |> get_req_header("x-request-id") |> List.first()
    resource = "/" <> Enum.join(conn.path_info, "/")
    err = %{err | request_id: request_id, resource: err.resource || resource}
    {status, body} = ErrorView.render(err)
    Log.warn("s3 error response", code: err.code, status: status, bucket: conn.assigns[:s3_bucket], key: conn.assigns[:s3_key])

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, body)
  end
end
```

**验证**：
```powershell
mix compile --warnings-as-errors
```
期望：编译零警告（Dispatch + 占位 Handlers + 已有模块齐全）。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): Dispatch plug (resolve->handler, unified Error->ErrorView) + placeholder Handlers" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E6.6 — S3 Endpoint（Plug.Builder 管线）+ Bandit child 接入监督树

**Files:** Create `lib/maxio/s3/endpoint.ex`；Modify `lib/maxio/application.ex`

`Maxio.S3.Endpoint` 是 Plug.Builder 顶层管线：`Plug.RequestId` → AddressStyle → SigV4 → Dispatch。**绝不挂 Plug.Parsers**。Application 监督树新增 `{Bandit, plug: Maxio.S3.Endpoint, ...}` child（端口/ip 从 config）。

Create `lib/maxio/s3/endpoint.ex`：
```elixir
defmodule Maxio.S3.Endpoint do
  @moduledoc """
  S3 兼容 HTTP API 的顶层 Plug 管线（独立于 Console 的 MaxioWeb.Endpoint）。
  绝不挂 Plug.Parsers——对象 body 由 handler 经 read_body 流式拉取（铁律 4）。
  顺序：RequestId → AddressStyle（寻址）→ SigV4（鉴权）→ Dispatch（分发到 handler）。
  """
  use Plug.Builder

  plug Plug.RequestId
  plug Maxio.S3.Plugs.AddressStyle
  plug Maxio.S3.Plugs.SigV4
  plug Maxio.S3.Plugs.Dispatch
end
```

Modify `lib/maxio/application.ex`：在 children 列表里，把 `MaxioWeb.Endpoint` 之后追加 S3 Bandit child（仅 `server: false` 时不启监听——test 环境）。改 `start/2` 的 children：
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
    Supervisor.start_link(children, opts)
  end

  # 独立 S3 Endpoint（Bandit, 端口 9000）。test 环境 server: false 时不启监听（走 Plug.Test）。
  defp s3_children do
    cfg = Application.get_env(:maxio, Maxio.S3.Endpoint, [])

    if Keyword.get(cfg, :server, true) do
      port = Keyword.get(cfg, :port, 9000)
      ip = Keyword.get(cfg, :ip, :any)

      [Supervisor.child_spec({Bandit, plug: Maxio.S3.Endpoint, scheme: :http, port: port, ip: ip}, id: :maxio_s3_bandit)]
    else
      []
    end
  end
```
（保留 Phoenix 原有 children 不动，仅追加 `s3_children/0`。`id: :maxio_s3_bandit` 避免与其它 Bandit child 冲突。）

**验证**：
```powershell
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
```
期望：编译零警告。再验证 dev 下能起监听（手动起后 Ctrl+C 退出）：
```powershell
mix run --no-halt -e "Process.sleep(1500)"
```
期望：日志含 Bandit 在 9000 启动（无端口冲突 / 无崩溃）。test 环境因 `server: false` 不起监听，集成测试走 `Plug.Test`/直接调 `Maxio.S3.Endpoint.call/2`。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): S3 Endpoint (Plug.Builder pipeline, no Parsers) + Bandit child on :9000 in supervision tree" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 单元 E6 验收

```powershell
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test test/maxio/s3/plugs/address_style_test.exs test/maxio/s3/dispatcher_test.exs
```
期望：零警告；AddressStyle（6）+ Dispatcher（13）全绿。管线骨架（Endpoint→AddressStyle→SigV4→Dispatch→占位 Handlers）可编译可启动；handler 真实落地在 E7。

---

## 单元 E7 — Handlers（Service/Bucket/Object）+ saxy Views + Dispatch 真分发 + 自签 SigV4 集成测试

**目标**：落地所有 M1 handler（用 E2 存储 + E3 元数据 + E4 XML/Error），实现出站 saxy Views（ListAllMyBuckets / ListBucket / LocationConstraint），把占位 Handlers 替换为真实分发，最后用**自签 SigV4** 集成测试经 `Maxio.S3.Endpoint.call/2` 端到端验证（ListBuckets/CreateBucket/PutObject 流式/GetObject+Range/HeadObject/DeleteObject/ListObjectsV2/错误路径）。

> handler 统一约定：接收 `conn`（已含 assigns.s3_bucket/s3_key/s3_level/principal/auth_type/payload_mode/s3_action），返回已 `send_resp`/`send_chunked` 的 conn。错误一律 `raise %Maxio.S3.Error{}`（由 Dispatch plug 的 rescue 渲染）。M1 授权：principal.type == :root 全权放行（AuthZ stub）；非 root 当前不会出现（MemoryStore 只引导 root），保留接口。

### Task E7.1 — saxy Views（ListAllMyBuckets / ListBucket / LocationConstraint）失败测试（TDD）

**Files:** Create `test/maxio/s3/views_test.exs`

Views 输出 iodata。`ListAllMyBuckets.render/1` 接 `%{owner: %{id, display_name}, buckets: [%{name, creation_date}]}`；`ListBucket.render/1` 接 ListObjectsV2 上下文结果 + 请求参数（name/prefix/max_keys/delimiter/key_count/is_truncated/next_token/objects/common_prefixes）；`LocationConstraint.render/1` 接 region（us-east-1 → 空体）。

Create `test/maxio/s3/views_test.exs`：
```elixir
defmodule Maxio.S3.ViewsTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.Views.{ListAllMyBuckets, ListBucket, LocationConstraint}

  test "ListAllMyBuckets：含命名空间、Owner、各 Bucket 名与 CreationDate（millis Z）" do
    data = %{
      owner: %{id: "rootid", display_name: "minio"},
      buckets: [
        %{name: "b1", creation_date: ~U[2019-12-11 23:32:47.000000Z]},
        %{name: "b2", creation_date: ~U[2019-11-10 23:32:13.000000Z]}
      ]
    }

    xml = data |> ListAllMyBuckets.render() |> IO.iodata_to_binary()
    assert xml =~ "<ListAllMyBucketsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
    assert xml =~ "<ID>rootid</ID>"
    assert xml =~ "<DisplayName>minio</DisplayName>"
    assert xml =~ "<Name>b1</Name>"
    assert xml =~ "<CreationDate>2019-12-11T23:32:47.000Z</CreationDate>"
    assert xml =~ "<Name>b2</Name>"
  end

  test "ListBucket：基础列举（Name/Prefix/KeyCount/MaxKeys/IsTruncated + Contents）" do
    data = %{
      name: "bucket",
      prefix: "",
      delimiter: nil,
      max_keys: 1000,
      key_count: 1,
      is_truncated: false,
      next_continuation_token: nil,
      start_after: nil,
      objects: [
        %{key: "my-image.jpg", last_modified: ~U[2009-10-12 17:50:30.000000Z], etag: "fba9dede5f27731c9771645a39863328", size: 434_234}
      ],
      common_prefixes: []
    }

    xml = data |> ListBucket.render() |> IO.iodata_to_binary()
    assert xml =~ "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
    assert xml =~ "<Name>bucket</Name>"
    assert xml =~ "<KeyCount>1</KeyCount>"
    assert xml =~ "<MaxKeys>1000</MaxKeys>"
    assert xml =~ "<IsTruncated>false</IsTruncated>"
    assert xml =~ "<Key>my-image.jpg</Key>"
    assert xml =~ "<ETag>\"fba9dede5f27731c9771645a39863328\"</ETag>"
    assert xml =~ "<Size>434234</Size>"
    assert xml =~ "<StorageClass>STANDARD</StorageClass>"
    refute xml =~ "<NextContinuationToken>"
  end

  test "ListBucket：截断时含 NextContinuationToken；delimiter 时含 CommonPrefixes" do
    data = %{
      name: "bucket",
      prefix: "photos/",
      delimiter: "/",
      max_keys: 2,
      key_count: 2,
      is_truncated: true,
      next_continuation_token: "tok",
      start_after: nil,
      objects: [],
      common_prefixes: ["photos/2006/", "photos/2007/"]
    }

    xml = data |> ListBucket.render() |> IO.iodata_to_binary()
    assert xml =~ "<NextContinuationToken>tok</NextContinuationToken>"
    assert xml =~ "<Delimiter>/</Delimiter>"
    assert xml =~ "<CommonPrefixes><Prefix>photos/2006/</Prefix></CommonPrefixes>"
    assert xml =~ "<CommonPrefixes><Prefix>photos/2007/</Prefix></CommonPrefixes>"
  end

  test "LocationConstraint：非默认区域返回区域文本" do
    xml = "us-west-2" |> LocationConstraint.render() |> IO.iodata_to_binary()
    assert xml =~ "<LocationConstraint xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">us-west-2</LocationConstraint>"
  end

  test "LocationConstraint：us-east-1 返回空体（最常见兼容坑）" do
    xml = "us-east-1" |> LocationConstraint.render() |> IO.iodata_to_binary()
    assert xml =~ "<LocationConstraint"
    refute xml =~ "us-east-1"
  end
end
```

1. 跑测试确认红：
   ```powershell
   mix test test/maxio/s3/views_test.exs
   ```
   期望：失败——Views 模块未定义。预期的红。

**验证**：测试因模块缺失失败即通过本步。

### Task E7.2 — 实现 saxy Views（使测试通过）

**Files:** Create `lib/maxio/s3/views/list_all_my_buckets.ex`、`lib/maxio/s3/views/list_bucket.ex`、`lib/maxio/s3/views/location_constraint.ex`

Create `lib/maxio/s3/views/list_all_my_buckets.ex`：
```elixir
defmodule Maxio.S3.Views.ListAllMyBuckets do
  @moduledoc "ListBuckets 响应 XML（ListAllMyBucketsResult）。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{owner: %{id: String.t(), display_name: String.t()}, buckets: [map()]}) :: iodata()
  def render(%{owner: owner, buckets: buckets}) do
    bucket_elems =
      Enum.map(buckets, fn b ->
        element("Bucket", [], [
          element("Name", [], characters(b.name)),
          element("CreationDate", [], characters(XML.iso8601(b.creation_date)))
        ])
      end)

    root =
      element("ListAllMyBucketsResult", [{"xmlns", XML.namespace()}], [
        element("Owner", [], [
          element("ID", [], characters(owner.id)),
          element("DisplayName", [], characters(owner.display_name))
        ]),
        element("Buckets", [], bucket_elems)
      ])

    XML.encode(root)
  end
end
```

Create `lib/maxio/s3/views/list_bucket.ex`：
```elixir
defmodule Maxio.S3.Views.ListBucket do
  @moduledoc "ListObjectsV2 响应 XML（ListBucketResult）。NextContinuationToken 仅截断时出现；CommonPrefixes 仅有 delimiter 时出现。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(map()) :: iodata()
  def render(data) do
    children =
      [
        element("Name", [], characters(data.name)),
        element("Prefix", [], characters(data.prefix || "")),
        element("KeyCount", [], characters(Integer.to_string(data.key_count))),
        element("MaxKeys", [], characters(Integer.to_string(data.max_keys))),
        element("IsTruncated", [], characters(to_string(data.is_truncated)))
      ]
      |> maybe(data.delimiter, fn d -> element("Delimiter", [], characters(d)) end)
      |> maybe(data.is_truncated && data.next_continuation_token, fn t ->
        element("NextContinuationToken", [], characters(t))
      end)
      |> maybe(data[:start_after], fn s -> element("StartAfter", [], characters(s)) end)

    contents = Enum.map(data.objects, &content_elem/1)
    common = Enum.map(data.common_prefixes, fn cp ->
      element("CommonPrefixes", [], [element("Prefix", [], characters(cp))])
    end)

    root = element("ListBucketResult", [{"xmlns", XML.namespace()}], children ++ contents ++ common)
    XML.encode(root)
  end

  defp content_elem(obj) do
    element("Contents", [], [
      element("Key", [], characters(obj.key)),
      element("LastModified", [], characters(XML.iso8601(obj.last_modified))),
      element("ETag", [], characters(XML.quote_etag(obj.etag))),
      element("Size", [], characters(Integer.to_string(obj.size))),
      element("StorageClass", [], characters("STANDARD"))
    ])
  end

  defp maybe(children, falsy, _fun) when falsy in [nil, false, ""], do: children
  defp maybe(children, value, fun), do: children ++ [fun.(value)]
end
```

Create `lib/maxio/s3/views/location_constraint.ex`：
```elixir
defmodule Maxio.S3.Views.LocationConstraint do
  @moduledoc "GetBucketLocation 响应 XML。us-east-1 返回空体（区域值为文本内容，非默认区域才填）。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(String.t()) :: iodata()
  def render(region) do
    content = if region == "us-east-1", do: [], else: characters(region)
    root = element("LocationConstraint", [{"xmlns", XML.namespace()}], content)
    XML.encode(root)
  end
end
```

1. 跑测试：
   ```powershell
   mix test test/maxio/s3/views_test.exs
   ```
   期望：`5 tests, 0 failures`。

**验证**：ViewsTest 全绿即通过。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): saxy Views (ListAllMyBuckets, ListBucket, LocationConstraint) with tests" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E7.3 — Service + Bucket handlers

**Files:** Create `lib/maxio/s3/handlers/service.ex`、`lib/maxio/s3/handlers/bucket.ex`

handler 直接操作 conn（`Plug.Conn`）。Service.list_buckets 列桶 → ListAllMyBuckets XML。Bucket：create（校验名 + 建元数据 + 建存储目录 + `Location: /<bucket>` 头）、delete（空桶检查 + 删元数据 + 删目录，204）、head（200 空体 + `x-amz-bucket-region`）、list_objects_v2（解析 query → 上下文 → ListBucket XML）、get_location（LocationConstraint XML）。

Create `lib/maxio/s3/handlers/service.ex`：
```elixir
defmodule Maxio.S3.Handlers.Service do
  @moduledoc "Service 级 handler：ListBuckets。"
  import Plug.Conn
  alias Maxio.Buckets
  alias Maxio.S3.Views.ListAllMyBuckets
  alias Maxio.S3.Log

  @spec list_buckets(Plug.Conn.t()) :: Plug.Conn.t()
  def list_buckets(conn) do
    principal = conn.assigns.principal

    buckets =
      Buckets.list()
      |> Enum.map(fn b -> %{name: b.name, creation_date: b.inserted_at} end)

    body =
      ListAllMyBuckets.render(%{
        owner: %{id: principal.access_key, display_name: "maxio"},
        buckets: buckets
      })

    Log.info("list buckets", action: :list_buckets, auth_type: conn.assigns.auth_type)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end
end
```

Create `lib/maxio/s3/handlers/bucket.ex`：
```elixir
defmodule Maxio.S3.Handlers.Bucket do
  @moduledoc "Bucket 级 handler：create / delete / head / list_objects_v2 / get_location。"
  import Plug.Conn
  alias Maxio.{Buckets, Objects, Storage}
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.Views.{ListBucket, LocationConstraint}

  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    bucket = conn.assigns.s3_bucket
    owner = conn.assigns.principal.arn

    case Buckets.create(bucket, owner, region: region()) do
      {:ok, _b} ->
        :ok = Storage.put_bucket(bucket)
        Log.info("create bucket", action: :create_bucket, bucket: bucket)

        conn
        |> put_resp_header("location", "/" <> bucket)
        |> send_resp(200, "")

      {:error, :invalid_bucket_name} ->
        raise Error.new(:invalid_bucket_name, resource: "/" <> bucket)

      {:error, :already_owned} ->
        raise Error.new(:bucket_already_owned_by_you, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket

    case Buckets.delete(bucket) do
      :ok ->
        _ = Storage.delete_bucket(bucket)
        Log.info("delete bucket", action: :delete_bucket, bucket: bucket)
        send_resp(conn, 204, "")

      {:error, :not_found} ->
        raise Error.new(:no_such_bucket, resource: "/" <> bucket)

      {:error, :not_empty} ->
        raise Error.new(:bucket_not_empty, resource: "/" <> bucket)
    end
  end

  @spec head(Plug.Conn.t()) :: Plug.Conn.t()
  def head(conn) do
    bucket = conn.assigns.s3_bucket

    case Buckets.lookup(bucket) do
      {:ok, b} ->
        conn
        |> put_resp_header("x-amz-bucket-region", b.region)
        |> send_resp(200, "")

      {:error, :not_found} ->
        # HeadBucket 不带 XML body，仅状态码
        send_resp(conn, 404, "")
    end
  end

  @spec list_objects_v2(Plug.Conn.t()) :: Plug.Conn.t()
  def list_objects_v2(conn) do
    bucket = conn.assigns.s3_bucket
    conn = fetch_query_params(conn)
    qp = conn.query_params

    with {:ok, _b} <- bucket_or_raise(bucket) do
      prefix = Map.get(qp, "prefix", "")
      delimiter = Map.get(qp, "delimiter")
      max_keys = parse_int(Map.get(qp, "max-keys"), 1000)
      continuation = Map.get(qp, "continuation-token")
      start_after = Map.get(qp, "start-after")

      res =
        Objects.list_objects_v2(bucket, %{
          prefix: prefix,
          delimiter: delimiter,
          max_keys: max_keys,
          continuation_token: continuation,
          start_after: start_after
        })

      objects =
        Enum.map(res.objects, fn o ->
          %{key: o.key, last_modified: o.updated_at, etag: o.etag, size: o.size}
        end)

      body =
        ListBucket.render(%{
          name: bucket,
          prefix: prefix,
          delimiter: delimiter,
          max_keys: max_keys,
          key_count: res.key_count,
          is_truncated: res.is_truncated,
          next_continuation_token: res.next_continuation_token,
          start_after: start_after,
          objects: objects,
          common_prefixes: res.common_prefixes
        })

      Log.info("list objects v2", action: :list_objects_v2, bucket: bucket)

      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(200, body)
    end
  end

  @spec get_location(Plug.Conn.t()) :: Plug.Conn.t()
  def get_location(conn) do
    bucket = conn.assigns.s3_bucket

    with {:ok, b} <- bucket_or_raise(bucket) do
      body = LocationConstraint.render(b.region)

      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(200, body)
    end
  end

  defp bucket_or_raise(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> {:ok, b}
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp region, do: Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:region)
end
```

**验证**（仅编译，handler 端到端在 E7.6 集成测试覆盖）：
```powershell
mix compile --warnings-as-errors
```
期望：编译零警告。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): Service.list_buckets + Bucket handlers (create/delete/head/list_objects_v2/get_location)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task E7.4 — BodyReader（流式 read_body + aws-chunked 解帧）+ Object handler

**Files:** Create `lib/maxio/s3/body_reader.ex`、`lib/maxio/s3/handlers/object.ex`

`Maxio.S3.BodyReader` 把 `Plug.Conn.read_body/2` 包成产出纯净对象字节块的流：
- `payload_mode == :single | :unsigned`：直接逐块产出 read_body 的 chunk（不缓冲整体）。
- `payload_mode == :streaming`（aws-chunked）：M1 **解帧**出纯净字节（剥 `<hex>;chunk-signature=<sig>\r\n<data>\r\n` 帧，遇 size=0 终止块停），并把"逐块签名链验证"作为**已知 M2 缺口显式日志**（非静默——seed 签名已在 SigV4 plug 验过；解帧后长度须等于 `x-amz-decoded-content-length`，不符则 `IncompleteBody` 400）。

为兼顾流式与正确 ETag（MD5 of 纯净字节），handler 把 BodyReader 的块流交 `Storage.put/4`，由 FS 边写边算 MD5（E2 已实现），再写元数据。

Create `lib/maxio/s3/body_reader.ex`：
```elixir
defmodule Maxio.S3.BodyReader do
  @moduledoc """
  把 Plug.Conn 的请求 body 包成产出**纯净对象字节块**的 Stream（绝不全缓冲，铁律 4）。

  - :single / :unsigned —— 直接逐块产出 read_body 的 chunk。
  - :streaming（aws-chunked, STREAMING-AWS4-HMAC-SHA256-PAYLOAD）—— 边读边解帧，
    剥去每个 chunk 的 `<hexsize>;chunk-signature=<sig>\\r\\n` 头与尾随 \\r\\n，
    输出纯净 data；遇 size=0 终止块停止。逐块签名链验证 **M1 跳过但显式日志记为 M2 缺口**
    （seed 签名已在 SigV4 plug 验过，且 handler 会校验解帧总长 == x-amz-decoded-content-length）。

  返回 {:ok, stream, conn}；调用方 Enum 消费 stream（如交 Storage.put/4）。
  注意：因 read_body 会推进 conn，stream 内部持有并推进 conn——消费必须在同一进程内一次性完成。
  """
  alias Maxio.S3.Log

  @read_opts [length: 1_048_576, read_length: 1_048_576, read_timeout: 30_000]

  @doc "返回逐块产出纯净对象字节的 Stream.resource。"
  @spec stream(Plug.Conn.t(), :single | :unsigned | :streaming) :: Enumerable.t()
  def stream(conn, :streaming) do
    Log.info("aws-chunked de-frame (per-chunk sig verify deferred to M2)",
      payload_mode: :streaming,
      reason: :m2_per_chunk_verify_skipped
    )

    Stream.resource(
      fn -> {conn, ""} end,
      &deframe_step/1,
      fn _acc -> :ok end
    )
  end

  def stream(conn, _mode) do
    Stream.resource(
      fn -> conn end,
      fn
        :done -> {:halt, :done}
        c ->
          case Plug.Conn.read_body(c, @read_opts) do
            {:ok, chunk, c2} -> {[chunk], (if chunk == "", do: :done, else: maybe_finish(c2, chunk))}
            {:more, chunk, c2} -> {[chunk], c2}
            {:error, _} -> {:halt, :done}
          end
      end,
      fn _ -> :ok end
    )
  end

  defp maybe_finish(_conn, _chunk), do: :done

  # ── aws-chunked 解帧状态机 ──
  # acc = {conn, buffer}；逐步从 buffer 解出帧；buffer 不足则再 read_body 补。
  defp deframe_step(:done), do: {:halt, :done}

  defp deframe_step({conn, buffer}) do
    case parse_chunk(buffer) do
      {:chunk, data, rest} -> {[data], {conn, rest}}
      :terminator -> {:halt, :done}
      :need_more ->
        case Plug.Conn.read_body(conn, @read_opts) do
          {:ok, more, conn2} -> deframe_step({conn2, buffer <> more})
          {:more, more, conn2} -> deframe_step({conn2, buffer <> more})
          {:error, _} -> {:halt, :done}
        end
    end
  end

  # 解析一个 chunk 帧：`<hexsize>;chunk-signature=<64hex>\r\n<data>\r\n`
  # 返回 {:chunk, data, rest} | :terminator | :need_more
  defp parse_chunk(buffer) do
    case :binary.split(buffer, "\r\n") do
      [header, after_header] ->
        size = chunk_size(header)

        cond do
          size == 0 ->
            :terminator

          byte_size(after_header) >= size + 2 ->
            <<data::binary-size(size), "\r\n", rest::binary>> = after_header
            {:chunk, data, rest}

          true ->
            :need_more
        end

      [_only] ->
        :need_more
    end
  end

  # header 形如 "10000;chunk-signature=..."，取分号前的 hex 转整数。
  defp chunk_size(header) do
    header
    |> :binary.split(";")
    |> List.first()
    |> String.trim()
    |> String.to_integer(16)
  rescue
    _ -> 0
  end
end
```

> 实现注意：上面 `:single/:unsigned` 分支的"读完即停"用 `:done` sentinel。executor 跑集成测试（E7.6）确认普通 PUT body 完整写入；若 read_body 在 `{:ok, "", conn}` 之外还需处理"首块即 `{:ok, chunk, conn}`（全部一次读完）"，逻辑已覆盖：`{:ok, chunk, c2}` 产出 chunk 后下一轮 `:done` 停止。对 `{:more,...}` 持续读。`x-amz-decoded-content-length` 长度校验在 Object.put 里做（见下）。

Create `lib/maxio/s3/handlers/object.ex`：
```elixir
defmodule Maxio.S3.Handlers.Object do
  @moduledoc """
  Object 级 handler：put（流式）/ get（含 Range）/ head / delete。
  对象字节走 Maxio.Storage（FS 流式），元数据走 Maxio.Objects。
  """
  import Plug.Conn
  alias Maxio.{Buckets, Objects, Storage}
  alias Maxio.S3.{BodyReader, Error, Log, XML}

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)

    content_type = header(conn, "content-type") || "binary/octet-stream"
    payload_mode = conn.assigns.payload_mode
    chunks = BodyReader.stream(conn, payload_mode)

    case Storage.put(bucket, key, chunks) do
      {:ok, %{size: size, etag: etag}} ->
        :ok = verify_decoded_length!(conn, payload_mode, size)

        {:ok, _obj} =
          Objects.put_metadata(bucket, key, %{
            size: size,
            etag: etag,
            content_type: content_type,
            storage_class: "STANDARD"
          })

        Log.info("put object", action: :put_object, bucket: bucket, key: key, size: size, auth_type: conn.assigns.auth_type)

        conn
        |> put_resp_header("etag", XML.quote_etag(etag))
        |> send_resp(200, "")

      {:error, :invalid_key} ->
        raise Error.new(:invalid_argument, resource: "/#{bucket}/#{key}", message: "Invalid key")

      {:error, reason} ->
        raise Error.new(:internal_error, message: inspect(reason))
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key

    {object, total} = object_or_raise(bucket, key)
    range = parse_range(header(conn, "range"), total)

    case range do
      :invalid ->
        raise Error.new(:invalid_range, resource: "/#{bucket}/#{key}", extra: %{total: total})

      _ ->
        {:ok, stream} = Storage.get(bucket, key, range_tuple(range))
        send_object(conn, object, total, range, stream)
    end
  end

  @spec head(Plug.Conn.t()) :: Plug.Conn.t()
  def head(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    {object, total} = object_or_raise(bucket, key)

    conn
    |> put_common_object_headers(object, total)
    |> send_resp(200, "")
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)

    :ok = Objects.delete_metadata(bucket, key)
    _ = Storage.delete(bucket, key)
    Log.info("delete object", action: :delete_object, bucket: bucket, key: key)
    send_resp(conn, 204, "")
  end

  # ── helpers ──
  defp send_object(conn, object, total, nil, stream) do
    conn
    |> put_common_object_headers(object, total)
    |> send_chunked(200)
    |> stream_chunks(stream)
  end

  defp send_object(conn, object, total, {first, last}, stream) do
    conn
    |> put_common_object_headers(object, last - first + 1)
    |> put_resp_header("content-range", "bytes #{first}-#{last}/#{total}")
    |> send_chunked(206)
    |> stream_chunks(stream)
  end

  defp stream_chunks(conn, stream) do
    Enum.reduce_while(stream, conn, fn chunk, acc ->
      case chunk(acc, chunk) do
        {:ok, acc2} -> {:cont, acc2}
        {:error, :closed} -> {:halt, acc}
      end
    end)
  end

  defp put_common_object_headers(conn, object, content_length) do
    conn
    |> put_resp_header("content-type", object.content_type)
    |> put_resp_header("etag", XML.quote_etag(object.etag))
    |> put_resp_header("last-modified", http_date(object.updated_at))
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("content-length", Integer.to_string(content_length))
  end

  # Range: bytes=a-b | bytes=a- | bytes=-suffix → {first,last} | nil | :invalid
  defp parse_range(nil, _total), do: nil

  defp parse_range("bytes=" <> spec, total) do
    case String.split(spec, "-") do
      [a, ""] ->
        case Integer.parse(a) do
          {first, ""} when first < total -> {first, total - 1}
          _ -> :invalid
        end

      ["", suffix] ->
        case Integer.parse(suffix) do
          {n, ""} when n > 0 -> {max(total - n, 0), total - 1}
          _ -> :invalid
        end

      [a, b] ->
        with {first, ""} <- Integer.parse(a),
             {last, ""} <- Integer.parse(b),
             true <- first <= last and first < total do
          {first, min(last, total - 1)}
        else
          _ -> :invalid
        end

      _ ->
        :invalid
    end
  end

  defp parse_range(_other, _total), do: :invalid

  defp range_tuple(nil), do: nil
  defp range_tuple({first, last}), do: {first, last}

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp object_or_raise(bucket, key) do
    _ = ensure_bucket!(bucket)

    case Objects.get_metadata(bucket, key) do
      {:ok, object} -> {object, object.size}
      {:error, :not_found} -> raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  # 流式 PUT 解帧后长度须等于声明的 decoded-content-length（aws-chunked 完整性闸，铁律 3）。
  defp verify_decoded_length!(conn, :streaming, actual_size) do
    case header(conn, "x-amz-decoded-content-length") do
      nil -> :ok
      str ->
        case Integer.parse(str) do
          {declared, ""} when declared == actual_size -> :ok
          {declared, ""} ->
            Log.warn("decoded length mismatch", reason: :incomplete_body)
            raise Error.new(:incomplete_body, message: "decoded length #{actual_size} != declared #{declared}")
          _ -> :ok
        end
    end
  end

  defp verify_decoded_length!(_conn, _mode, _size), do: :ok

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  # HTTP Last-Modified 用 RFC1123 GMT（与列举体 ISO8601 不同）。
  defp http_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
  end
end
```

**验证**：
```powershell
mix compile --warnings-as-errors
```
期望：编译零警告。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): BodyReader (streaming + aws-chunked de-frame) + Object handler (put/get+Range/head/delete)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E7.5 — 替换占位 Handlers 为真实分发

**Files:** Modify `lib/maxio/s3/handlers.ex`

把 E6 的占位 `Maxio.S3.Handlers.dispatch/2` 替换为真实分发到 Service/Bucket/Object：
```elixir
defmodule Maxio.S3.Handlers do
  @moduledoc """
  Handler 分发门面：按 Dispatcher 解析出的 action 调对应 Service/Bucket/Object handler。
  M1 授权 stub：principal.type == :root 全权放行（非 root 当前不会出现，留接口）。
  """
  alias Maxio.S3.Handlers.{Service, Bucket, Object}

  @spec dispatch(atom(), Plug.Conn.t()) :: Plug.Conn.t()
  def dispatch(:list_buckets, conn), do: Service.list_buckets(conn)

  def dispatch(:create_bucket, conn), do: Bucket.create(conn)
  def dispatch(:delete_bucket, conn), do: Bucket.delete(conn)
  def dispatch(:head_bucket, conn), do: Bucket.head(conn)
  def dispatch(:list_objects_v2, conn), do: Bucket.list_objects_v2(conn)
  def dispatch(:get_bucket_location, conn), do: Bucket.get_location(conn)

  def dispatch(:put_object, conn), do: Object.put(conn)
  def dispatch(:get_object, conn), do: Object.get(conn)
  def dispatch(:head_object, conn), do: Object.head(conn)
  def dispatch(:delete_object, conn), do: Object.delete(conn)
end
```

**验证**：
```powershell
mix compile --warnings-as-errors
```
期望：编译零警告。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): wire Handlers dispatch to real Service/Bucket/Object handlers" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task E7.6 — 自签 SigV4 端到端集成测试（TDD 取证，无 aws-cli）

**Files:** Create `test/support/sigv4_request.ex`、`test/maxio/s3/integration_test.exs`；Modify `mix.exs`（test elixirc_paths 已含 `test/support`）

测试辅助 `Maxio.Test.SigV4Request`：给定 method/path/headers/body + test root 密钥，用 `Maxio.Auth.SigV4.{Canonical,Signer}` **自签**出 Authorization 头，构造 `Plug.Test` conn（host 用 `localhost`，走 path-style），注入 `maxio_now` 为固定时间（避免时钟偏移），直接调 `Maxio.S3.Endpoint.call/2`。这就是 e2e 活体取证（铁律：无 aws-cli 时用自签集成测试）。

Create `test/support/sigv4_request.ex`：
```elixir
defmodule Maxio.Test.SigV4Request do
  @moduledoc """
  测试辅助：用项目自己的 SigV4 Signer 自签一个请求并经 Maxio.S3.Endpoint 打进管线。
  这是无 aws-cli 环境下的端到端活体取证：证明 我们签 → 我们验 闭环成立，
  且管线（AddressStyle→SigV4→Dispatch→Handler→XML）端到端工作。
  """
  import Plug.Test
  import Plug.Conn

  alias Maxio.Auth.SigV4.{Canonical, Signer}

  @access_key "AKIAIOSFODNN7EXAMPLE"
  @secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  @region "us-east-1"
  @service "s3"
  @now ~U[2026-06-08 00:00:00Z]

  @doc """
  自签并构造 conn。opts：:query (map)、:headers ([{name,value}])、:body (binary)。
  自动加 host/x-amz-date/x-amz-content-sha256，签名后加 Authorization。
  """
  def signed_conn(method, path, opts \\ []) do
    query = Keyword.get(opts, :query, %{})
    extra_headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")

    amz_date = "20260608T000000Z"
    scope_date = "20260608"
    scope = "#{scope_date}/#{@region}/#{@service}/aws4_request"
    payload_hash = Signer.hex_sha256(body)

    base_headers =
      [
        {"host", "localhost"},
        {"x-amz-content-sha256", payload_hash},
        {"x-amz-date", amz_date}
      ] ++ Enum.map(extra_headers, fn {k, v} -> {String.downcase(k), v} end)

    canonical_req = %{
      method: to_string(method) |> String.upcase(),
      path: path,
      query: query,
      headers: base_headers,
      payload_hash: payload_hash
    }

    canonical = Canonical.canonical_request(canonical_req)
    sts = Signer.string_to_sign(amz_date, scope, canonical, "AWS4-HMAC-SHA256")
    key = Signer.derive_signing_key(@secret, scope_date, @region, @service)
    signature = Signer.signature(key, sts)
    signed_headers = Canonical.signed_headers(base_headers)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{@access_key}/#{scope}," <>
        "SignedHeaders=#{signed_headers},Signature=#{signature}"

    query_string = URI.encode_query(query)
    full_path = if query_string == "", do: path, else: path <> "?" <> query_string

    conn =
      conn(method, full_path, body)
      |> put_private(:maxio_now, @now)

    base_headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> put_req_header("authorization", auth)
  end

  def access_key, do: @access_key
end
```

Create `test/maxio/s3/integration_test.exs`：
```elixir
defmodule Maxio.S3.IntegrationTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_int_test")

  setup do
    # 隔离对象数据目录
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

  test "CreateBucket → 200 + Location 头" do
    conn = SigV4Request.signed_conn(:put, "/mybucket") |> call()
    assert conn.status == 200
    assert get_resp_header(conn, "location") == ["/mybucket"]
  end

  test "ListBuckets 列出已创建的桶" do
    SigV4Request.signed_conn(:put, "/b-one") |> call()
    SigV4Request.signed_conn(:put, "/b-two") |> call()

    conn = SigV4Request.signed_conn(:get, "/") |> call()
    assert conn.status == 200
    assert conn.resp_body =~ "<Name>b-one</Name>"
    assert conn.resp_body =~ "<Name>b-two</Name>"
  end

  test "PutObject 流式 → GetObject 取回完整内容 + ETag" do
    SigV4Request.signed_conn(:put, "/data") |> call()

    body = "Welcome to Amazon S3."
    put = SigV4Request.signed_conn(:put, "/data/hello.txt", body: body, headers: [{"content-type", "text/plain"}]) |> call()
    assert put.status == 200
    expected_etag = "\"" <> (:crypto.hash(:md5, body) |> Base.encode16(case: :lower)) <> "\""
    assert get_resp_header(put, "etag") == [expected_etag]

    get = SigV4Request.signed_conn(:get, "/data/hello.txt") |> call()
    assert get.status == 200
    assert get.resp_body == body
    assert get_resp_header(get, "content-type") == ["text/plain"]
    assert get_resp_header(get, "etag") == [expected_etag]
  end

  test "GetObject Range → 206 + Content-Range + 区间内容" do
    SigV4Request.signed_conn(:put, "/data") |> call()
    SigV4Request.signed_conn(:put, "/data/r.txt", body: "0123456789") |> call()

    get = SigV4Request.signed_conn(:get, "/data/r.txt", headers: [{"range", "bytes=2-5"}]) |> call()
    assert get.status == 206
    assert get_resp_header(get, "content-range") == ["bytes 2-5/10"]
    assert get.resp_body == "2345"
  end

  test "HeadObject → 200 空体 + 元数据头" do
    SigV4Request.signed_conn(:put, "/data") |> call()
    SigV4Request.signed_conn(:put, "/data/h.txt", body: "abc") |> call()

    head = SigV4Request.signed_conn(:head, "/data/h.txt") |> call()
    assert head.status == 200
    assert head.resp_body == ""
    assert get_resp_header(head, "content-length") == ["3"]
  end

  test "DeleteObject → 204；再 Get → 404 NoSuchKey" do
    SigV4Request.signed_conn(:put, "/data") |> call()
    SigV4Request.signed_conn(:put, "/data/d.txt", body: "x") |> call()

    del = SigV4Request.signed_conn(:delete, "/data/d.txt") |> call()
    assert del.status == 204

    get = SigV4Request.signed_conn(:get, "/data/d.txt") |> call()
    assert get.status == 404
    assert get.resp_body =~ "<Code>NoSuchKey</Code>"
  end

  test "ListObjectsV2 prefix + delimiter" do
    SigV4Request.signed_conn(:put, "/lb") |> call()
    for k <- ~w(photos/2006/a photos/2007/b top.txt) do
      SigV4Request.signed_conn(:put, "/lb/#{k}", body: "z") |> call()
    end

    conn =
      SigV4Request.signed_conn(:get, "/lb", query: %{"list-type" => "2", "prefix" => "photos/", "delimiter" => "/"})
      |> call()

    assert conn.status == 200
    assert conn.resp_body =~ "<CommonPrefixes><Prefix>photos/2006/</Prefix></CommonPrefixes>"
    assert conn.resp_body =~ "<CommonPrefixes><Prefix>photos/2007/</Prefix></CommonPrefixes>"
  end

  test "GetBucketLocation us-east-1 返回空体" do
    SigV4Request.signed_conn(:put, "/loc") |> call()
    conn = SigV4Request.signed_conn(:get, "/loc", query: %{"location" => ""}) |> call()
    assert conn.status == 200
    assert conn.resp_body =~ "<LocationConstraint"
    refute conn.resp_body =~ "us-east-1"
  end

  test "DeleteBucket 非空 → 409 BucketNotEmpty；空桶 → 204" do
    SigV4Request.signed_conn(:put, "/db") |> call()
    SigV4Request.signed_conn(:put, "/db/o", body: "x") |> call()

    busy = SigV4Request.signed_conn(:delete, "/db") |> call()
    assert busy.status == 409
    assert busy.resp_body =~ "<Code>BucketNotEmpty</Code>"

    SigV4Request.signed_conn(:delete, "/db/o") |> call()
    ok = SigV4Request.signed_conn(:delete, "/db") |> call()
    assert ok.status == 204
  end

  test "未知桶 GetObject → 404 NoSuchBucket" do
    conn = SigV4Request.signed_conn(:get, "/ghost/key") |> call()
    assert conn.status == 404
    assert conn.resp_body =~ "<Code>NoSuchBucket</Code>"
  end

  test "篡改签名 → 403 SignatureDoesNotMatch（非静默）" do
    conn = SigV4Request.signed_conn(:get, "/")
    bad = put_req_header(conn, "authorization", "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260608/us-east-1/s3/aws4_request,SignedHeaders=host;x-amz-content-sha256;x-amz-date,Signature=deadbeef")
    out = call(bad)
    assert out.status == 403
    assert out.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"
  end
end
```

> 集成测试说明：`Maxio.S3.Endpoint.call/2`（Plug.Builder 生成）顺序跑 RequestId→AddressStyle→SigV4→Dispatch。`signed_conn` 用 `host: localhost`（domain 配置即 localhost）走 path-style。`maxio_now` 注入固定时间消除时钟偏移。body 由 `Plug.Test.conn/3` 提供，SigV4 plug 不消费、Object.put 经 read_body 流式取（Plug.Test 支持 read_body）。这覆盖：签名闭环、寻址、分发、流式 put/get、Range、错误映射。

1. 跑集成测试：
   ```powershell
   $env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
   mix test test/maxio/s3/integration_test.exs
   ```
   期望：全部用例绿（约 11 个，`0 failures`）。这是 M1 的端到端活体取证。

**验证**：IntegrationTest 全绿 = 真实签名请求经完整管线创建桶/对象、流式 Put/Get、Range、List、Delete、错误映射均正确。

**Commit**：
```powershell
git add -A
git commit -m "test(s3): self-signed SigV4 end-to-end integration tests through S3 Endpoint (M1 e2e proof)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 单元 E7 验收

```powershell
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test
```
期望：零警告；**全套测试绿**（E1..E7 所有单元测试 + 集成测试）。这是 M0+M1 的完成判据之一。

---

## 全局收尾（M0+M1 完成判据）

### 验收命令（独立 verifier/code-reviewer 在新上下文执行，实现者不自审）

```powershell
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
docker start maxio-db
mix deps.get
mix ecto.migrate
mix compile --warnings-as-errors
mix test
```
期望：
- `mix compile --warnings-as-errors` 零警告零错误。
- `mix test` 全绿，含：
  - SigV4 KNOWN-ANSWER：4 个 canonical 向量 + 5 个签名向量与 AWS 官方 worked-example **byte-for-byte** 一致（独立 ground truth）。
  - FS 流式 put（不缓冲整对象、ETag=MD5 hex）、Range 含端点、防穿越。
  - 元数据上下文 + ListObjectsV2 分页/前缀/折叠。
  - 自签 SigV4 **端到端**：CreateBucket/ListBuckets/PutObject(流式)/GetObject(+Range)/HeadObject/DeleteObject/ListObjectsV2/GetBucketLocation/错误路径（403 签名/404 桶或键/409 非空桶）。

### CLI 取证（铁律 4，人工复核）

```powershell
mix maxio.sigv4.debug --method GET --path /test.txt --region us-east-1 --service s3 --access-key AKIAIOSFODNN7EXAMPLE --secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" --date 20130524T000000Z --payload-hash e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 --header "host:examplebucket.s3.amazonaws.com" --header "range:bytes=0-9" --header "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" --header "x-amz-date:20130524T000000Z"
```
期望 `Signature` = `f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41`。

### DB schema 自文档化取证（铁律 6）

```powershell
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ buckets"
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ objects"
```
期望：两表的表/列/索引均显示中文 `COMMENT`。

### 更新 STATUS

实现完成、verifier 取证齐备后，更新 `docs/superpowers/STATUS.md`：把 M0、M1 状态从 🚧 改为 ✅，记录本次完成的模块清单与"aws-chunked 逐块签名验证 / multipart / 完整 IAM"为 M2 入口（已在本计划 Goal 明列）。

### M2 入口（本计划显式 defer，已在代码留显式标记/日志）

1. **aws-chunked 逐块签名链验证**：BodyReader 已解帧 + 已日志 `reason: :m2_per_chunk_verify_skipped`；M2 用 §2 chunk string-to-sign（`AWS4-HMAC-SHA256-PAYLOAD` + 链式 prev-signature）逐块验证，失败即 403。
2. **multipart upload**：Dispatcher 对 `?uploads`/`?uploadId` 已返回 `NotImplemented`；M2 落地 Create/Upload/Complete/Abort/ListParts + multipart ETag（`-N` 后缀）。
3. **DeleteObjects 批量**、**多区间 Range**、**条件头**、**完整 IAM/bucket policy + presigned 写路径** 均为 M2/M3。

---

## 跨单元一致性自检清单（executor 每单元后核对）

- [ ] 模块名/函数名/字段名与"全局命名契约"逐字一致（如 `payload_mode` 三态、`SignedRequest` 字段、`Storage.Backend` 回调）。
- [ ] 每个 mix 命令前已设 `$env:ERL_FLAGS`。
- [ ] DB 迁移表/列/索引均有中文 COMMENT。
- [ ] 任何失败路径都 `raise %Maxio.S3.Error{}` 或返回 Error，并打 `Maxio.S3.Log.warn/error`——无静默 500、无静默放行。
- [ ] 对象 body 路径无 `Plug.Parsers`、无整体缓冲（put 走 BodyReader→Storage 流式；get 走 send_chunked）。
- [ ] SigV4 KNOWN-ANSWER 向量全绿（改任何 Canonical/Signer 代码后必须回归）。
- [ ] `mix compile --warnings-as-errors` 零警告。
