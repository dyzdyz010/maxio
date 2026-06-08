# M6 纠删码 实现计划 · maxio（Reed-Solomon Erasure Coding · 单机多盘 · Rustler NIF）

> For agentic workers（executor）：严格按单元 **M6-1 .. M6-5** 顺序执行。逻辑性代码用 **TDD**（先写失败测试 → 运行确认红 → 最小实现 → 运行确认绿 → commit）；脚手架/配置/迁移/Rust crate 类任务用「执行命令 + 验证输出」。每个任务都给了**精确文件路径、完整可用代码（禁止占位符 / TODO / 省略号）、确切 PowerShell 命令与期望输出**。后面单元引用的类型/函数/字段名与前面定义（及 M0–M5 既有代码）**严格一致**——复用既有模块时逐字照抄其现有签名。
>
> **本计划建立在已交付并验证的 M0+M1+M2+M3+M4+M5 之上**（master，412 测试全绿、`compile --warnings-as-errors` 零警告、独立 reviewer APPROVE_WITH_NOTES／0 must-fix）。M6 复用 M0–M5 既有契约**且核心管线一行不改**：核心是新增一个 `Maxio.Storage.Backend` 的实现 `Maxio.Storage.ErasureCoded`，它满足与 `Maxio.Storage.FS` **完全相同**的 behaviour 契约（put/get/stat/delete/put_bucket/delete_bucket + put_part/get_part_stream/assemble/abort_upload + M4 加入的 `version_id` 维度 + 流式 + ETag/sha256 返回形态），经 `config :maxio, :storage_backend` 切换即可启用。**上层 handler / 编排 / Storage 门面对后端实现无感**。
>
> **铁律对齐（AGENTS.md §3/§4，违反即返工）**：
> - **铁律 2（后端即插件）**：M6 是一个**全新的 `Maxio.Storage.Backend` 实现**；`Maxio.Storage`（facade）、`Maxio.Storage.Backend`（behaviour）、`Maxio.Storage.FS`、所有 handler / dispatcher / endpoint **一行不改**（仅 `lib/maxio/storage/backend.ex` 在 M4 已定型，本计划**不动它的契约**）。唯一的"接线"是 config 切后端 + mix.exs 加 `{:rustler, "~> 0.36"}` dep + 新增 `native/maxio_native` crate。
> - **铁律 4（body 绝不进内存）**：encode/decode 必须**逐块流式**——PUT 把 chunks 重切成固定 `block_size`（默认 1 MiB）逻辑块，每块 RS 编码后把分片 i 追加到盘 i；GET 用 `Stream.resource/3` 逐块读 K 个分片、校验、重建、发出。**任何时刻内存 ≈ 一个 block × N 个分片，绝不缓冲整对象**。NIF 按块调用（每次调用有界、快速，绝不长跑 NIF 卡调度器）。
> - **铁律 3（绝不静默失败）**：bitrot（分片校验和不匹配）/ 分片不足（< K）/ 写入未达 write quorum，**必须 raise 结构化错误 + 打结构化日志**，绝不静默返回错数据或静默落盘。GET 解码时若某 block 存活分片 < K → raise（上层映射结构化 S3 5xx）。
> - **铁律 6（DB schema 自文档化）**：M6 **不新建任何表**（per-object 元数据走盘上 JSON sidecar，非 DB）。**若**后续选择把 EC 参数落 DB（本计划不这么做），新表/列须中文 `COMMENT`。
> - **铁律 5（S3 行为对齐）**：ErasureCoded 后端的 ETag（单 PUT = MD5 hex 无引号）、sha256、Range（含端点 0-based）、part ETag（md5_raw 16 字节）返回形态**与 FS 逐字节一致**，handler 上层完全无感。
>
> **作者/审查隔离**：本计划由 executor 实现；每个单元收尾由**独立** `code-reviewer`/`verifier`（不同上下文）取证，实现者不得自审。

---

## 环境约束（每条命令都必须遵守）

- **本机**：Windows 11 + PowerShell。Elixir 1.20.0 / OTP 28，位于 `C:\Users\dyz\Documents\dev\usr\Elixir\bin`。
- **Rust 工具链**：rustc 1.95.0 + cargo 在 `C:\Users\dyz\.cargo\bin`（已在 PATH）。`use Rustler` 宏在 `mix compile` 期间编译 crate。**rustler 0.36：mix.exs 的 `project/0` 里 NO `:compilers` / `rustler_crates` 配置（与 huanxi 完全一致）**。第一次 `mix compile` 会下载 crate 依赖（reed-solomon-simd / blake3 / rustler）并构建 cdylib（`.dll`，慢，可能数分钟）；后续增量编译走缓存。
- **跑任何 mix 命令前必设**（否则编译期/运行期中文输出重定向到非 TTY 触发 `io.put_chars badarg` 硬崩、留 `erl_crash.dump`）：
  ```powershell
  $env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
  $env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
  ```
  本计划所有 PowerShell 命令块**默认已假设当前会话已设此两变量**；每个新 shell 会话第一条命令前先执行它。
- **Postgres**：docker 容器 `maxio-db`（postgres:16，localhost:5432，user/pass=postgres/postgres，dev 库 `maxio_dev`，test 库 `maxio_test`）。`psql` 不在 PATH，一律经容器 `docker exec maxio-db psql -U postgres -d maxio_dev -c "..."`。`mix test` 自动迁移 test 库。**M6 不动 DB schema**，故 DB 仅用于既有元数据上下文（Objects/Buckets/Multipart）测试不受影响。
- **无 aws-cli / boto3 / mc / python**。端到端验证只用：(a) **纯函数单测**（NIF round-trip / 重建 / bitrot 检测——独立 ground truth，最权威）；(b) **后端 behaviour 一致性测试**（同一套 conformance 套件同时跑 FS 与 ErasureCoded）；(c) **自签 SigV4** 集成测试（config-select 后端到 ErasureCoded 跑既有 S3 e2e 的一个切片，经 `Maxio.S3.Endpoint.call/2`，复用 `test/support/sigv4_request.ex`）。**禁止依赖外部 CLI**。
- **提交**：每个单元（或紧密相关的红绿对）一次 commit，message footer 固定一行：
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
  当前分支为 `master`；本计划全部提交到当前分支（无需开新分支，除非用户另行要求）。

---

## Goal

在 M0–M5（鉴权 + 授权 + 高级特性 + Console）之上，新增 **MinIO 式纠删码存储后端**，使对象字节以 **Reed-Solomon (N=K+M)** 编码分散到 **N 个本地盘目录（单机多盘 = 一个 erasure set）**，提供：

1. **Rustler NIF**（`native/maxio_native`，镜像姊妹项目 huanxi 的 `h3o` Rustler 模式）封装 `reed-solomon-simd`（actively maintained、纯 Rust SIMD、GF(2^16)）：`rs_encode`（K+M 等长分片）+ `rs_reconstruct`（从 `[binary | nil]` 重建，缺失/损坏分片置 nil），以及 `blake3`（per-shard bitrot 校验和）。**契约："成功即返回值、非法即 raise"，与 `Huanxi.Geo.H3` 一致。**
2. **块编解码层** `Maxio.Storage.Erasure.Codec`（纯 Elixir，over NIF）：把一个 block 切成 K+M 分片 + per-shard 校验和；读时验证 + 重建，**分片不足 / 全损 → raise 结构化错误**（铁律 3）。
3. **纠删码后端** `Maxio.Storage.ErasureCoded`（实现 `Maxio.Storage.Backend` 全部 callback）：put 把对象**逐块流式**编码、分片 i 写盘 i + per-object meta sidecar（EC 参数 / block 数 / per-block-per-shard 校验和 / 总长 / etag / sha256，over 明文流，与 FS 一致）；get 逐块读 K 个存活分片、验证、重建、流式发出（`send_chunked` 兼容 Enumerable）；stat/delete/put_bucket/delete_bucket 跨盘；`version_id` 维度同 FS。**绝不缓冲整对象**。
4. **multipart parts** 在纠删码后端上（put_part/get_part_stream/assemble/abort_upload）+ **共享 conformance 测试套件**（同跑 FS 与 ErasureCoded）+ config 切后端 + 一片 S3 e2e 跑在纠删码后端上。
5. **HEAL / SCRUB**：读路径检测缺失/损坏分片（校验和不匹配或文件缺失），从 K 个存活分片 RS 重建、回写坏分片；`mix maxio.heal`（单对象/单桶）+ `mix maxio.scrub`（全盘扫描）CLI；e2e：写对象 → 删/损坏至多 M 个分片 → GET 仍返回正确字节（decode-on-read），heal 回写；删 M+1 个分片 → **结构化错误（绝不静默返回错数据）**。

**显式不做（DEFER 到 M7，文档化，绝不静默）**：
- **真正的多节点分布**：分片 I/O 跨主机（RPC 而非本地 FS）。
- **多个 erasure set + 对象→set 路由**（按对象名 hash）、**server pools** + pool 路由、扩容/rebalance。
- **跨节点读写 quorum**（含 `K == M` 即 `M == N/2` 时 write quorum = K+1 的脑裂规则——M6 在单机也**实现并强制** quorum 返回值，但跨节点分区语义 defer）。
- **分布式锁**（跨节点对象级锁，并发 PUT/heal 安全）。
- **拓扑感知路由 / 跨节点 heal 协调 / heal 限流 / failure-domain 感知分片放置**。
- **存储类（`x-amz-storage-class` → STANDARD/RRS 不同 parity）**：M6 单一 (K,M) 配置；多 storage class 的 parity 切换 defer。
- **inline 小对象（< 128 KiB 直接进 sidecar 省 part 文件）**：MinIO 的优化，M6 不做（所有对象都写 part 文件），文档化。

> **设计保证（M6 是诚实的 M7 垫脚石）**：M6 的 erasure set 是「N 个盘 = N 个本地目录」，RS 数学与分布式 set **完全相同**；M7 只替换**分片访问 transport**（本地 `:file` ops → RPC）并在同一 RS 核心**之外**加 routing/locking/pools 层——不重写 encode/decode/heal 引擎。deferral 显式列出（铁律 3，无静默缺口）。

---

## Architecture（M6 在 M5 之上的增量——核心管线零改动）

```
                 （核心请求管线 / handler / dispatcher / endpoint —— 一行不改）
S3 客户端 → Maxio.S3.Endpoint → ... → Maxio.S3.Handlers.Object/Multipart
                                              │
                                   Maxio.Storage（facade，不改）
                                              │  backend() = config :maxio, :storage_backend
                            ┌─────────────────┴───────────────────┐
                   Maxio.Storage.FS（M0，不改）        Maxio.Storage.ErasureCoded ★新（M6-3/4/5）
                                                                   │  实现 Maxio.Storage.Backend 全部 callback
                                                                   ▼
                                              Maxio.Storage.Erasure.Codec ★新（M6-2）
                                                 split_block / restore_block（block→shards + 校验和）
                                                                   ▼
                                              Maxio.Native.ErasureCoding ★新（M6-1）
                                                 encode/3 · reconstruct/3 · blake3/1（Rustler NIF 绑定）
                                                                   ▼
                                              native/maxio_native（Rust crate ★新，M6-1）
                                                 reed-solomon-simd（GF(2^16) SIMD）+ blake3 + rustler 0.38

盘上布局（单机 N 个目录 = 一个 erasure set）：
  <drive_i>/<bucket>/<key|.versions/...>/<version_id>/part.0     # 盘 i 对该对象的分片字节（流式追加）
  <drive_i>/<bucket>/<key|...>/<version_id>/meta.json            # per-object sidecar（每盘一份，相同内容）
  <drive_i>/.uploads/<bucket>/<upload_id>/<part_number>.part     # part 分片字节
  <drive_i>/.uploads/<bucket>/<upload_id>/<part_number>.meta.json# part sidecar

CLI（铁律 4 CLI 可观测）：mix maxio.heal · mix maxio.scrub（结构化日志：bucket/key/version/drive/block/result）
```

config 新增（不改既有 key，仅追加）：
```elixir
config :maxio, :erasure,
  drives: ["<d0>", "<d1>", ..., "<dN-1>"],   # N 个本地目录 = erasure set
  data_shards: K, parity_shards: M,           # N = K + M
  block_size: 1_048_576                        # 1 MiB 流式块
```

---

## 单元总览（按依赖串行；每单元结束须 green compile + 测试通过 + 一次 commit）

| 单元 | 标题 | 依赖 | 规模/分割理由 |
|---|---|---|---|
| **M6-1** | Rust NIF crate（`native/maxio_native`）+ `Maxio.Native.ErasureCoding` 绑定 + mix.exs rustler dep + .gitignore；encode→reconstruct round-trip / 至多 M 分片 nil / blake3 TDD | M5 | 自包含；纯计算，无 DB/无后端；先打地基 |
| **M6-2** | `Maxio.Storage.Erasure.Codec`（block→K+M 分片 + per-shard blake3；verify+reconstruct；不足/全损 raise 结构化错误）+ EC 参数解析/校验 `Maxio.Storage.Erasure.Config` | M6-1 | 纯 Elixir codec 层，over NIF，独立可 TDD |
| **M6-3** | `Maxio.Storage.ErasureCoded` 的 **put/get/stat/delete + bucket ops**（流式逐块编码/解码、meta sidecar、跨盘、version_id 维度、write/read quorum 返回值映射） | M6-2 | 后端主体的对象读写一半，单 executor 可完成 |
| **M6-4** | ErasureCoded 的 **parts**（put_part/get_part_stream/assemble/abort_upload）+ **共享 conformance 测试套件**（同跑 FS 与 ErasureCoded）+ config 切后端 + 一片 S3 e2e 跑纠删码后端 | M6-3 | 后端另一半 + 契约一致性验收 |
| **M6-5** | **HEAL / SCRUB**：检测缺/损分片→RS 重建→回写；`mix maxio.heal` + `mix maxio.scrub` CLI；bitrot e2e（损 ≤M 仍正确 + heal 回写；损 M+1 结构化错误）+ STATUS/README 更新 + M7 defer 文档化 | M6-4 | 自愈子系统 + 端到端 bitrot 取证 + 收尾 |

**执行顺序**：M6-1 → M6-2 → M6-3 → M6-4 → M6-5。**串行执行，禁止并行 mix 编译**（避免锁文件竞争 + Rust crate 并发构建竞争）。每单元规模控制在「单个 executor 一轮内可完成实现 + 跑测试 + 调用 StructuredOutput」。

---

## 全局命名契约（M6 新增，一次定义全程复用；M0–M5 既有契约见对应计划）

**沿用既有契约（逐字一致，绝不重定义）**：
- `Maxio.Storage.Backend` behaviour 全部 callback 签名（含 M4 的 `version_id` 维度），见 `lib/maxio/storage/backend.ex`：
  - `put(bucket, key, version_id, chunks, opts) :: {:ok, %{size, etag, sha256}} | {:error, term}`
  - `get(bucket, key, version_id, range) :: {:ok, Enumerable.t} | {:error, :enoent | term}`（range = nil | {first, last} 含端点 0-based）
  - `stat(bucket, key, version_id) :: {:ok, %{size}} | {:error, :enoent}`
  - `delete(bucket, key, version_id) :: :ok | {:error, term}`
  - `put_bucket(bucket) :: :ok | {:error, term}` / `delete_bucket(bucket) :: :ok | {:error, term}`
  - `put_part(bucket, key, upload_id, part_number, chunks, opts) :: {:ok, %{size, etag, md5_raw}} | {:error, term}`
  - `get_part_stream(bucket, key, upload_id, part_number, opts) :: {:ok, Enumerable.t} | {:error, :enoent | term}`
  - `assemble(bucket, key, upload_id, part_numbers, opts) :: {:ok, %{size}} | {:error, term}`
  - `abort_upload(bucket, key, upload_id, opts) :: :ok | {:error, term}`
- ETag = `MD5(明文) |> Base.encode16(case: :lower)`（无引号）；sha256 同理 `:sha256`；part 的 `md5_raw` = 16 字节原始 MD5。**全部 over 明文（解码后）字节流，与 FS 完全一致。**
- FS 的 `safe_relative/1`（`..`/`.`/空 key 守卫，返回 `{:ok, rel} | :error`）+ `object_path` 的 version 路径约定（`"null"`→原路径、否则 `.versions/<bucket>/<key>/<version_id>`）+ part 路径约定（`.uploads/<bucket>/<upload_id>/<n>.part`）——ErasureCoded **照抄这些约定**，只是每个「文件」变成 N 个盘上的分片文件 + sidecar。
- 测试隔离：每个 backend callback 接受可选末参 `opts`，FS 用 `:data_dir` 覆盖根目录；ErasureCoded 用 `:drives`（覆盖盘目录列表）+ `:data_shards`/`:parity_shards`/`:block_size`（覆盖 EC 参数），缺省从 `config :maxio, :erasure` 读。

**M6 新增模块与签名（跨单元引用，逐字一致）**：

- `Maxio.Native.ErasureCoding`（M6-1，`use Rustler, otp_app: :maxio, crate: :maxio_native`）：
  - `encode(k :: pos_integer, m :: pos_integer, data :: binary) :: [shard :: binary]` —— 共 N=k+m 个等长二进制分片（前 k 个数据分片 systematic、后 m 个校验分片）；分片长 = even(ceil(byte_size/k))；末数据分片零填充。非法参数 raise。
  - `reconstruct(k, m, shards :: [binary | nil]) :: binary` —— 从长度 N 的分片列表重建（缺/损置 nil），返回含零填充的数据（调用方按原始长度截断）；存活 < k → raise。
  - `blake3(data :: binary) :: binary` —— 32 字节 BLAKE3-256 摘要。
- `Maxio.Storage.Erasure.Config`（M6-2）：
  - `%Maxio.Storage.Erasure.Config{drives: [String.t], data_shards: pos_integer, parity_shards: pos_integer, block_size: pos_integer, read_quorum: pos_integer, write_quorum: pos_integer}`
  - `load!(opts :: keyword) :: t()` —— 合并 opts 与 `config :maxio, :erasure`，校验 `length(drives) == K+M`、`M >= 1`、`M <= N/2`，计算 `read_quorum = K`、`write_quorum = if(M == div(N,2), do: K+1, else: K)`；非法 raise `ArgumentError`。
  - `total(t) :: pos_integer`（= K+M = length(drives)）。
- `Maxio.Storage.Erasure.Codec`（M6-2）：
  - `split_block(cfg :: Config.t(), block :: binary) :: %{shards: [binary], checksums: [binary], shard_len: pos_integer}` —— N 个等长分片 + N 个 blake3 校验和。
  - `restore_block(cfg, shards :: [binary | nil], checksums :: [binary], data_len :: non_neg_integer) :: binary` —— 验证每个非 nil 分片的 blake3，匹配的留、不匹配置 nil；存活 ≥ K → 重建并截断到 data_len；存活 < K → raise `Maxio.Storage.Erasure.InsufficientShardsError`。
  - `verify_shard(shard :: binary | nil, checksum :: binary) :: boolean` —— nil→false；blake3 匹配→true。
- `Maxio.Storage.Erasure.InsufficientShardsError`（M6-2）：exception，字段 `bucket/key/version_id/block_index/present/required`。
- `Maxio.Storage.Erasure.Meta`（M6-3）：per-object sidecar 编解码。
  - `encode(map) :: binary`（Jason）/ `decode!(binary) :: map`。
  - sidecar map 形态（见 M6-3 完整定义）：`%{"ec" => %{"k","m","block_size","algo"}, "size", "etag", "sha256", "parts" => [...], "shards" => [%{"drive", "shard_file_size", "block_hashes" => [hex,...]}, ...]}`。
- `Maxio.Storage.ErasureCoded`（M6-3/4，`@behaviour Maxio.Storage.Backend`）：实现全部 9+ callback，签名与 FS 完全一致（含可选 `opts` 末参默认）。

---

## 命名一致性检查清单（executor 每单元落地前自查）

- ErasureCoded 的每个 callback 返回形态**逐字段对齐 FS**（`%{size, etag, sha256}` / `%{size, etag, md5_raw}` / `{:ok, Enumerable}` / `{:error, :enoent}`）；ETag/sha256/md5_raw over **明文**字节。
- 路径守卫一律复用 FS 同款 `safe_relative/1` 语义（`..`/`.`/空 → `:error` → `{:error, :invalid_key}`）。
- version_id 维度：`"null"` → 原路径段、否则 `.versions/<bucket>/<key>/<version_id>` 段（与 FS 物理隔离约定一致），只是落在每个 drive 下。
- NIF 函数名 `native_rs_encode`/`native_rs_reconstruct`/`native_blake3` 与 `src/lib.rs` 的 `#[rustler::nif] fn` 名**逐字一致**（`native_` 前缀，镜像 huanxi）。
- 绝不静默：bitrot/不足分片/未达 write quorum → raise 结构化异常 + `Logger`（含 bucket/key/version_id/drive/block/reason 元数据）。
- 流式：PUT 用 `Stream`/手写块缓冲，单块 ≤ block_size；GET 用 `Stream.resource/3`；**绝不 `Enum.to_list` 整对象 / 绝不一次性读整分片文件**（除非该「文件」本就是一个 part 的单块场景——见 M6-4 part 说明）。
- mix.exs 不加 `:compilers`/`rustler_crates`（rustler 0.36 由 `use Rustler` 宏驱动 cargo 构建，镜像 huanxi）。
- 每条 mix 命令前已设 `$env:Path` + `$env:ERL_FLAGS`。
- 每单元一次 commit，footer 固定 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。

---

## M6-1 · Rust NIF crate（`native/maxio_native`）+ `Maxio.Native.ErasureCoding` 绑定

**目标**：镜像姊妹项目 huanxi 的 `h3o` Rustler 模式，建一个自包含的 Rust crate，封装 Reed-Solomon 编解码（`reed-solomon-simd`，GF(2^16) SIMD、纯 Rust、Windows MSVC 零额外依赖）与 BLAKE3 per-shard 校验和；Elixir 侧 `Maxio.Native.ErasureCoding`（`use Rustler`）给「成功即返回值、非法即 raise」的友好包装。**纯计算，无 DB、无后端依赖。**

**依赖**：M5（master）。**规模**：一个 Cargo.toml + 一个 src/lib.rs + 一个 Elixir 绑定模块 + mix.exs dep + .gitignore + 单测。

### 关键事实（研究已核验，bake-in）

- **crate 选型**：`reed-solomon-simd = "3.1"`（actively maintained 2025-10、纯 Rust SIMD、GF(2^16)、O(n log n)、Windows MSVC 无需 C 编译器）。`rustler = "0.38"`（Rust 侧，与 huanxi 的 `native/Cargo.toml` 一致；Elixir 侧 hex dep 写 `{:rustler, "~> 0.36"}`，与 huanxi 的 `mix.exs` 一致——`~>` 解析到最新 0.3x）。`blake3 = "1"`（per-shard bitrot 校验和，纯 Rust）。
- **systematic 码**：前 K 个分片 = 原始数据切片（零损时直接拼接 + 截断，无需解码数学）；后 M 个为校验分片。
- **分片等长 + 偶数**：`reed-solomon-simd` 工作于 16-bit 符号，要求 `shard_len` 为偶数。`shard_len = even_up(ceil(L / K))`，末数据分片零填充。**调用方（Codec/后端）必须存原始长度 L，重建后截断零填充。**
- **NIF 二进制边界**（关键陷阱）：`Vec<u8>` 在 rustler 里编码为 **Elixir 整数列表**，不是 binary。返回 binary 必须用 `NewBinary`。输入 binary 参数类型 `Binary<'a>`，`.as_slice()` 得 `&[u8]`；`[binary | nil]` 解码为 `Vec<Option<Binary>>`。返回 `Result<T, String>` 由 rustler 自动编码 `Ok(x)` 为 `{:ok,x}`、`Err(s)` 为 `{:error,s}`（与 huanxi 的 `h3.ex` 注释所述一致）。
- **rustler init 单参自动发现形式**：`rustler::init!("Elixir.Maxio.Native.ErasureCoding");`（无需显式 fn 列表/`load`），与 huanxi 的 `rustler::init!("Elixir.Huanxi.Geo.H3");` 一致。
- **reed_solomon_simd::decode** 入参为 (k, m, 存活 originals 的 `(index, bytes)` 迭代器, 存活 recovery 的 `(index, bytes)` 迭代器)，返回 `HashMap<usize, Vec<u8>>` 仅含**被恢复的** original index（你已有的存活 original 不回显）。需 ≥ K 个分片（任意混合）。

### 步骤 1：建 crate 目录与 Cargo.toml

新建 `native/maxio_native/Cargo.toml`（镜像 huanxi，换 h3o 为 RS + blake3）：

```toml
[package]
name = "maxio_native"
version = "0.1.0"
authors = ["maxio"]
edition = "2021"

[lib]
name = "maxio_native"
path = "src/lib.rs"
crate-type = ["cdylib"]

[dependencies]
rustler = "0.38"
reed-solomon-simd = "3.1"
blake3 = "1"
```

### 步骤 2：src/lib.rs（完整，无占位符）

新建 `native/maxio_native/src/lib.rs`：

```rust
use rustler::{Binary, Env, NewBinary};
use std::collections::HashMap;

/// 把长度向上取到偶数（reed-solomon-simd 要求分片长为偶数；GF(2^16) 16-bit 符号）。
fn even_up(n: usize) -> usize {
    if n % 2 == 0 {
        n
    } else {
        n + 1
    }
}

/// 由字节切片构造 Elixir binary（Vec<u8> 会被编码成整数列表而非 binary，必须显式用 NewBinary）。
fn to_bin<'a>(env: Env<'a>, data: &[u8]) -> Binary<'a> {
    let mut b = NewBinary::new(env, data.len());
    b.as_mut_slice().copy_from_slice(data);
    b.into()
}

/// 把 `data` 编码为 K 个数据分片 + M 个校验分片（N = K + M），返回 N 个等长 binary 列表
/// （前 K 个为数据分片、systematic；后 M 个为校验分片）。
/// shard_len = even(ceil(len/K))，末数据分片零填充；调用方须保存原始 byte_size(data) 以便重建后截断。
#[rustler::nif]
fn native_rs_encode<'a>(
    env: Env<'a>,
    data_shards: usize,
    parity_shards: usize,
    data: Binary<'a>,
) -> Result<Vec<Binary<'a>>, String> {
    if data_shards == 0 || parity_shards == 0 {
        return Err(format!(
            "data_shards and parity_shards must be > 0 (got {data_shards},{parity_shards})"
        ));
    }
    let bytes = data.as_slice();
    let shard_len = even_up((bytes.len() + data_shards - 1) / data_shards).max(2);

    // 切分 + 零填充为 K 个等长偶数长度数据分片。
    let mut data_owned: Vec<Vec<u8>> = Vec::with_capacity(data_shards);
    for i in 0..data_shards {
        let start = i * shard_len;
        let mut shard = vec![0u8; shard_len];
        if start < bytes.len() {
            let end = (start + shard_len).min(bytes.len());
            shard[..end - start].copy_from_slice(&bytes[start..end]);
        }
        data_owned.push(shard);
    }

    // 编码 -> M 个校验分片。
    let parity: Vec<Vec<u8>> =
        reed_solomon_simd::encode(data_shards, parity_shards, data_owned.iter())
            .map_err(|e| format!("rs encode failed: {e}"))?;

    // 发出全部 N 个分片（数据在前、校验在后）为 Elixir binary。
    let mut out: Vec<Binary<'a>> = Vec::with_capacity(data_shards + parity_shards);
    for s in &data_owned {
        out.push(to_bin(env, s));
    }
    for s in &parity {
        out.push(to_bin(env, s));
    }
    Ok(out)
}

/// 从长度为 N = data_shards + parity_shards 的分片列表重建原始数据
/// （缺失/损坏分片为 `nil` -> None）。至少需 data_shards 个分片在场。
/// 返回 {:ok, 重建数据 binary}，长度 = data_shards * shard_len（调用方按存储的原始长度截断）。
#[rustler::nif]
fn native_rs_reconstruct<'a>(
    env: Env<'a>,
    data_shards: usize,
    parity_shards: usize,
    shards: Vec<Option<Binary<'a>>>,
) -> Result<Binary<'a>, String> {
    let total = data_shards + parity_shards;
    if shards.len() != total {
        return Err(format!(
            "expected {total} shards (={data_shards}+{parity_shards}), got {}",
            shards.len()
        ));
    }
    let present = shards.iter().filter(|s| s.is_some()).count();
    if present < data_shards {
        return Err(format!(
            "need at least {data_shards} shards to reconstruct, only {present} present"
        ));
    }

    // 由任一存活分片确定 shard_len。
    let shard_len = shards
        .iter()
        .filter_map(|s| s.as_ref())
        .map(|b| b.as_slice().len())
        .next()
        .ok_or_else(|| "no shards present".to_string())?;

    // 快路径：K 个数据分片全在 -> 直接拼接（systematic 码，无需解码）。
    let all_data_present = (0..data_shards).all(|i| shards[i].is_some());
    if all_data_present {
        let mut out = NewBinary::new(env, data_shards * shard_len);
        let buf = out.as_mut_slice();
        for i in 0..data_shards {
            let s = shards[i].as_ref().unwrap().as_slice();
            buf[i * shard_len..(i + 1) * shard_len].copy_from_slice(s);
        }
        return Ok(out.into());
    }

    // 解码路径：拆存活分片为 (index, bytes) 的 originals 与 recovery。
    let originals: Vec<(usize, &[u8])> = (0..data_shards)
        .filter_map(|i| shards[i].as_ref().map(|b| (i, b.as_slice())))
        .collect();
    let recovery: Vec<(usize, &[u8])> = (0..parity_shards)
        .filter_map(|j| shards[data_shards + j].as_ref().map(|b| (j, b.as_slice())))
        .collect();

    let restored: HashMap<usize, Vec<u8>> = reed_solomon_simd::decode(
        data_shards,
        parity_shards,
        originals.iter().copied(),
        recovery.iter().copied(),
    )
    .map_err(|e| format!("rs decode failed: {e}"))?;

    // 重组 K 个数据分片：存活 originals + 恢复出的。
    let mut out = NewBinary::new(env, data_shards * shard_len);
    let buf = out.as_mut_slice();
    for i in 0..data_shards {
        let slot = &mut buf[i * shard_len..(i + 1) * shard_len];
        if let Some(b) = shards[i].as_ref() {
            slot.copy_from_slice(b.as_slice());
        } else if let Some(r) = restored.get(&i) {
            slot.copy_from_slice(r);
        } else {
            return Err(format!("shard {i} neither present nor restored"));
        }
    }
    Ok(out.into())
}

/// BLAKE3-256 摘要（32 字节 binary）。用于 per-shard bitrot 校验和。
#[rustler::nif]
fn native_blake3<'a>(env: Env<'a>, data: Binary<'a>) -> Binary<'a> {
    let hash = blake3::hash(data.as_slice());
    to_bin(env, hash.as_bytes())
}

// 单参自动发现形式（与 huanxi 的 rustler::init!("Elixir.Huanxi.Geo.H3"); 一致）。
rustler::init!("Elixir.Maxio.Native.ErasureCoding");
```

### 步骤 3：mix.exs 加 rustler dep + .gitignore

修改 `mix.exs` 的 `deps/0`，把既有末项 `{:saxy, "~> 1.6"}` 改为带逗号并在其后追加 rustler：

```elixir
      # S3 XML 出站构造 + 入站 SAX 解析（一依赖两用）
      {:saxy, "~> 1.6"},
      # 纠删码 Rust NIF（reed-solomon-simd + blake3）；use Rustler 宏在 mix compile 期驱动 cargo
      {:rustler, "~> 0.36"}
```

> **不加** `:compilers` / `rustler_crates` 配置（rustler 0.36 由 `use Rustler` 宏注入 mix 编译器，镜像 huanxi 的 `mix.exs`）。crate 默认解析路径为 `native/maxio_native/`（与 `crate: :maxio_native` 同名），无需 `:path`。

修改根目录 `.gitignore`，追加 Rust 构建产物（避免提交 target/）：

```
# Rust NIF 构建产物
/native/*/target/
```

### 步骤 4：拉依赖 + 首次编译（构建 Rust cdylib）

```powershell
mix deps.get
mix compile
```

期望：`mix deps.get` 解析 `rustler` 等；`mix compile` **首次会下载并构建 reed-solomon-simd / blake3 / rustler crate + 编译 maxio_native cdylib（慢，可能数分钟）**，最终 `Compiling NIF crate :maxio_native (native/maxio_native)...` 成功、零错误。若报 cargo / rustc 未找到，确认 `C:\Users\dyz\.cargo\bin` 在 PATH。

### 步骤 5：Elixir 绑定 `Maxio.Native.ErasureCoding`（TDD）

先写失败测试。新建 `test/maxio/native/erasure_coding_test.exs`：

```elixir
defmodule Maxio.Native.ErasureCodingTest do
  use ExUnit.Case, async: true
  alias Maxio.Native.ErasureCoding, as: EC

  describe "encode/3" do
    test "返回 N=k+m 个等长 binary 分片，前 k 个 systematic 拼接=零填充原文" do
      data = :crypto.strong_rand_bytes(1000)
      shards = EC.encode(4, 2, data)
      assert length(shards) == 6
      assert Enum.all?(shards, &is_binary/1)
      lens = Enum.map(shards, &byte_size/1)
      assert lens |> Enum.uniq() |> length() == 1
      [len | _] = lens
      assert rem(len, 2) == 0
      # 前 4 个数据分片拼接后截断到原长 == 原文
      joined = shards |> Enum.take(4) |> IO.iodata_to_binary()
      assert binary_part(joined, 0, byte_size(data)) == data
    end

    test "空数据也能编码（分片长 >= 2 偶数）" do
      shards = EC.encode(3, 2, "")
      assert length(shards) == 5
      assert Enum.all?(shards, &(byte_size(&1) >= 2))
    end

    test "非法参数 raise" do
      assert_raise ArgumentError, fn -> EC.encode(0, 2, "x") end
      assert_raise ArgumentError, fn -> EC.encode(3, 0, "x") end
    end
  end

  describe "reconstruct/3（round-trip）" do
    setup do
      data = :crypto.strong_rand_bytes(5000)
      {:ok, data: data, k: 4, m: 2, shards: EC.encode(4, 2, data)}
    end

    test "无丢失：重建后截断 == 原文", %{data: data, k: k, m: m, shards: shards} do
      present = Enum.map(shards, & &1)
      out = EC.reconstruct(k, m, present)
      assert binary_part(out, 0, byte_size(data)) == data
    end

    test "丢失 1 个数据分片仍可重建", %{data: data, k: k, m: m, shards: shards} do
      shards = List.replace_at(shards, 0, nil)
      out = EC.reconstruct(k, m, shards)
      assert binary_part(out, 0, byte_size(data)) == data
    end

    test "丢失 M 个分片（数据+校验混合）仍可重建", %{data: data, k: k, m: m, shards: shards} do
      # 丢 1 个数据分片 + 1 个校验分片 = M=2 个
      shards = shards |> List.replace_at(1, nil) |> List.replace_at(5, nil)
      out = EC.reconstruct(k, m, shards)
      assert binary_part(out, 0, byte_size(data)) == data
    end

    test "丢失 M+1 个分片 -> raise（存活 < K）", %{k: k, m: m, shards: shards} do
      shards =
        shards
        |> List.replace_at(0, nil)
        |> List.replace_at(1, nil)
        |> List.replace_at(2, nil)

      assert_raise ArgumentError, fn -> EC.reconstruct(k, m, shards) end
    end

    test "分片数量与 N 不符 -> raise", %{k: k, m: m, shards: shards} do
      assert_raise ArgumentError, fn -> EC.reconstruct(k, m, Enum.take(shards, 5)) end
    end
  end

  describe "blake3/1" do
    test "返回 32 字节摘要，确定性，输入不同摘要不同" do
      h1 = EC.blake3("hello")
      h2 = EC.blake3("hello")
      h3 = EC.blake3("hellp")
      assert byte_size(h1) == 32
      assert h1 == h2
      assert h1 != h3
    end
  end
end
```

运行确认红（绑定模块尚不存在 -> 编译失败）：

```powershell
mix test test/maxio/native/erasure_coding_test.exs
```

新建 `lib/maxio/native/erasure_coding.ex`（镜像 `Huanxi.Geo.H3`：`use Rustler` + 私有 `native_*` 桩 + `unwrap!` 解包 raise）：

```elixir
defmodule Maxio.Native.ErasureCoding do
  @moduledoc """
  Reed-Solomon 纠删码 + BLAKE3 校验和的 Rust NIF 绑定（底层 reed-solomon-simd GF(2^16) SIMD + blake3）。

  契约："成功即返回值、非法即 raise"，与 `Huanxi.Geo.H3` 一致：
    * encode/3      —— (k, m, data :: binary) -> [shard :: binary]，共 N=k+m 个等长分片
                       （前 k 个数据分片 systematic、后 m 个校验分片）
    * reconstruct/3 —— (k, m, shards :: [binary | nil]) -> 重建后的数据 binary（含零填充，
                       调用方按对象元数据里的原始长度 L 截断）；存活 < k 时 raise
    * blake3/1      —— (data :: binary) -> 32 字节 BLAKE3-256 摘要（per-shard bitrot 校验和）

  底层 NIF（encode/reconstruct）返回 {:ok, _} / {:error, reason}（rustler 0.38 对 Rust Result 的标准编码），
  这里解包；{:error, _} 显式 raise ArgumentError，使调用方可安全假设拿到值（铁律 3：绝不静默）。
  blake3/1 永不失败，NIF 直接返回 binary。
  """
  use Rustler, otp_app: :maxio, crate: :maxio_native

  @type shard :: binary()

  @doc """
  把 `data` 编码为 k 个数据分片 + m 个校验分片，返回 N=k+m 个等长二进制分片。
  分片长为 even(ceil(byte_size(data)/k))；末尾数据分片零填充。
  调用方须保存原始 byte_size(data) 以便重建后截断。非法 k/m raise。
  """
  @spec encode(pos_integer(), pos_integer(), binary()) :: [shard()]
  def encode(data_shards, parity_shards, data)
      when is_integer(data_shards) and data_shards > 0 and
             is_integer(parity_shards) and parity_shards > 0 and is_binary(data) do
    unwrap!(
      native_rs_encode(data_shards, parity_shards, data),
      {:encode, data_shards, parity_shards, byte_size(data)}
    )
  end

  @doc """
  从长度为 N=k+m 的分片列表重建原始数据（缺失/损坏分片置 nil）。
  至少需 k 个分片在场，否则 raise。返回值含零填充，调用方按原始长度截断。
  """
  @spec reconstruct(pos_integer(), pos_integer(), [shard() | nil]) :: binary()
  def reconstruct(data_shards, parity_shards, shards)
      when is_integer(data_shards) and data_shards > 0 and
             is_integer(parity_shards) and parity_shards > 0 and is_list(shards) do
    unwrap!(
      native_rs_reconstruct(data_shards, parity_shards, shards),
      {:reconstruct, data_shards, parity_shards, length(shards)}
    )
  end

  @doc "BLAKE3-256 摘要（32 字节）。用于 per-shard bitrot 校验和。"
  @spec blake3(binary()) :: binary()
  def blake3(data) when is_binary(data), do: native_blake3(data)

  # NIF 入口桩：未加载时 raise；加载后被替换为 Rust 实现。
  # 函数名与 src/lib.rs 中 #[rustler::nif] fn 名逐字一致（native_ 前缀）。
  defp native_rs_encode(_k, _m, _data), do: err()
  defp native_rs_reconstruct(_k, _m, _shards), do: err()
  defp native_blake3(_data), do: err()

  defp unwrap!({:ok, value}, _ctx), do: value

  defp unwrap!({:error, reason}, ctx) do
    raise ArgumentError, "ErasureCoding #{inspect(ctx)} failed: #{inspect(reason)}"
  end

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
```

运行确认绿：

```powershell
mix test test/maxio/native/erasure_coding_test.exs
```

期望：所有用例通过（encode 3 + reconstruct 5 + blake3 1 = 9 个，`0 failures`）。

### 单元收尾验证（M6-1）

```powershell
mix compile --warnings-as-errors
mix test test/maxio/native/erasure_coding_test.exs
```

期望：编译零警告；NIF 测试全绿。提交：

```powershell
git add -A
git commit -m @'
M6-1: Rust NIF crate native/maxio_native (reed-solomon-simd + blake3, rustler 0.38) mirroring huanxi h3o pattern; Maxio.Native.ErasureCoding binding (encode/reconstruct/blake3, success-or-raise); mix.exs rustler dep; gitignore native target; round-trip / up-to-M-missing / bitrot-hash TDD

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) `native/maxio_native` crate 按 huanxi 模式构建出 cdylib，`mix compile` 零错误；(2) encode→reconstruct round-trip 正确（无丢失 / 丢 1 数据分片 / 丢 M 个混合分片均还原原文）；(3) 丢 M+1 分片 raise（不静默返回错数据）；(4) blake3 32 字节确定性；(5) mix.exs 无 `:compilers`/`rustler_crates`、`.gitignore` 含 `native/*/target/`；(6) 零警告。

---


## M6-2 · 块编解码层 `Maxio.Storage.Erasure.Codec` + EC 参数 `Maxio.Storage.Erasure.Config`

**目标**：在 NIF 之上建一个**纯 Elixir** codec 层：把一个 block 切成 K+M 分片 + per-shard BLAKE3 校验和（`split_block`）；读时验证每个非 nil 分片的校验和、把损坏的置 nil、重建并截断（`restore_block`）；**存活分片 < K（不足）或全损 → raise 结构化异常**（铁律 3，绝不静默返回错数据）。同时建 `Config`（EC 参数加载 + 校验 + quorum 计算）。**纯函数，独立可 TDD，不触盘、不触 DB。**

**依赖**：M6-1。**规模**：一个 exception + 一个 Config + 一个 Codec + 单测。

### 关键事实（bake-in）

- **RS 只纠 erasure（已知缺失），不定位 silent corruption**。若把已损坏分片当「在场」喂给 reconstruct，会得到干净却错误的结果。**因此 per-shard 校验和是强制的**：校验和告诉你哪个分片坏了 → 置 nil → 只要 ≤ M 个坏，RS 能恢复。`restore_block` 必须**先验证再 nil 化再重建**。
- `Codec` 不感知盘/路径/version——它只对「一个 block 的 N 个分片字节 + N 个校验和」做纯运算。盘 I/O 与 sidecar 在 M6-3 后端层。
- 校验和算法标识写进 sidecar 的 `ec.algo`（`"blake3-256"`），便于未来切换。

### 步骤 1：异常 + Config（TDD）

新建 `test/maxio/storage/erasure/config_test.exs`：

```elixir
defmodule Maxio.Storage.Erasure.ConfigTest do
  use ExUnit.Case, async: true
  alias Maxio.Storage.Erasure.Config

  defp drives(n), do: for(i <- 0..(n - 1), do: "/d#{i}")

  test "load! 合并 opts，计算 quorum（M < N/2 -> write_quorum = K）" do
    cfg = Config.load!(drives: drives(6), data_shards: 4, parity_shards: 2, block_size: 1024)
    assert cfg.data_shards == 4
    assert cfg.parity_shards == 2
    assert cfg.block_size == 1024
    assert cfg.read_quorum == 4
    assert cfg.write_quorum == 4
    assert Config.total(cfg) == 6
  end

  test "M == N/2（脑裂边界）-> write_quorum = K+1" do
    cfg = Config.load!(drives: drives(8), data_shards: 4, parity_shards: 4)
    assert cfg.read_quorum == 4
    assert cfg.write_quorum == 5
  end

  test "drives 数量与 K+M 不符 -> raise" do
    assert_raise ArgumentError, fn ->
      Config.load!(drives: drives(5), data_shards: 4, parity_shards: 2)
    end
  end

  test "M < 1 或 M > N/2 -> raise" do
    assert_raise ArgumentError, fn ->
      Config.load!(drives: drives(4), data_shards: 4, parity_shards: 0)
    end

    assert_raise ArgumentError, fn ->
      # M=3 > N/2=2.5 (N=5)
      Config.load!(drives: drives(5), data_shards: 2, parity_shards: 3)
    end
  end
end
```

运行确认红。新建 `lib/maxio/storage/erasure/insufficient_shards_error.ex`：

```elixir
defmodule Maxio.Storage.Erasure.InsufficientShardsError do
  @moduledoc """
  某个 block 的存活（校验和通过）分片数 < K（read quorum），无法重建。
  铁律 3：绝不静默返回错数据，直接 raise；上层（后端 get）令惰性流崩溃，handler 映射结构化 S3 5xx。
  """
  defexception [:bucket, :key, :version_id, :block_index, :present, :required, :message]

  @impl true
  def exception(opts) do
    bucket = Keyword.get(opts, :bucket)
    key = Keyword.get(opts, :key)
    version_id = Keyword.get(opts, :version_id)
    block_index = Keyword.get(opts, :block_index)
    present = Keyword.get(opts, :present)
    required = Keyword.get(opts, :required)

    msg =
      "erasure read quorum lost: bucket=#{inspect(bucket)} key=#{inspect(key)} " <>
        "version_id=#{inspect(version_id)} block=#{inspect(block_index)} " <>
        "present=#{inspect(present)} required=#{inspect(required)}"

    %__MODULE__{
      bucket: bucket,
      key: key,
      version_id: version_id,
      block_index: block_index,
      present: present,
      required: required,
      message: msg
    }
  end
end
```

新建 `lib/maxio/storage/erasure/config.ex`：

```elixir
defmodule Maxio.Storage.Erasure.Config do
  @moduledoc """
  纠删码参数（单机多盘 = 一个 erasure set）：N 个本地盘目录、K 个数据分片、M 个校验分片、
  block_size 流式块大小，以及由此推出的 read/write quorum。

  load!/1 合并调用方 opts 与 `config :maxio, :erasure`，做启动期校验：
    * length(drives) == K + M
    * M >= 1 且 M <= N/2（parity 至多半数）
  并计算：read_quorum = K；write_quorum = if M == div(N,2)（脑裂边界 K==M）, do: K+1, else: K。
  非法配置 raise ArgumentError（铁律 3：绝不带病启动）。
  """
  alias __MODULE__

  @type t :: %Config{
          drives: [String.t()],
          data_shards: pos_integer(),
          parity_shards: pos_integer(),
          block_size: pos_integer(),
          read_quorum: pos_integer(),
          write_quorum: pos_integer()
        }

  defstruct [:drives, :data_shards, :parity_shards, :block_size, :read_quorum, :write_quorum]

  @default_block_size 1_048_576

  @doc "由 opts（覆盖）+ config 加载并校验 EC 参数。"
  @spec load!(keyword()) :: t()
  def load!(opts \\ []) do
    env = Application.get_env(:maxio, :erasure, [])
    drives = Keyword.get(opts, :drives) || Keyword.get(env, :drives) || []
    k = Keyword.get(opts, :data_shards) || Keyword.get(env, :data_shards)
    m = Keyword.get(opts, :parity_shards) || Keyword.get(env, :parity_shards)

    block_size =
      Keyword.get(opts, :block_size) || Keyword.get(env, :block_size) || @default_block_size

    validate!(drives, k, m, block_size)

    n = k + m
    read_quorum = k
    write_quorum = if m == div(n, 2), do: k + 1, else: k

    %Config{
      drives: drives,
      data_shards: k,
      parity_shards: m,
      block_size: block_size,
      read_quorum: read_quorum,
      write_quorum: write_quorum
    }
  end

  @doc "分片总数 N = K + M = length(drives)。"
  @spec total(t()) :: pos_integer()
  def total(%Config{data_shards: k, parity_shards: m}), do: k + m

  defp validate!(drives, k, m, block_size) do
    cond do
      not (is_list(drives) and length(drives) > 0) ->
        raise ArgumentError, "erasure: drives must be a non-empty list (got #{inspect(drives)})"

      not (is_integer(k) and k > 0) ->
        raise ArgumentError, "erasure: data_shards must be a positive integer (got #{inspect(k)})"

      not (is_integer(m) and m >= 1) ->
        raise ArgumentError, "erasure: parity_shards must be >= 1 (got #{inspect(m)})"

      length(drives) != k + m ->
        raise ArgumentError,
              "erasure: length(drives)=#{length(drives)} must equal data_shards+parity_shards=#{k + m}"

      m > div(k + m, 2) ->
        raise ArgumentError,
              "erasure: parity_shards=#{m} must be <= N/2 (N=#{k + m}); parity cannot exceed half the set"

      not (is_integer(block_size) and block_size > 0) ->
        raise ArgumentError, "erasure: block_size must be a positive integer (got #{inspect(block_size)})"

      true ->
        :ok
    end
  end
end
```

运行确认绿：

```powershell
mix test test/maxio/storage/erasure/config_test.exs
```

期望：`4 tests, 0 failures`。

### 步骤 2：Codec（TDD）

新建 `test/maxio/storage/erasure/codec_test.exs`：

```elixir
defmodule Maxio.Storage.Erasure.CodecTest do
  use ExUnit.Case, async: true
  alias Maxio.Storage.Erasure.{Codec, Config, InsufficientShardsError}

  defp cfg, do: Config.load!(drives: for(i <- 0..5, do: "/d#{i}"), data_shards: 4, parity_shards: 2)

  test "split_block 产出 N 个等长分片 + N 个 32 字节校验和" do
    block = :crypto.strong_rand_bytes(900)
    %{shards: shards, checksums: cks, shard_len: sl} = Codec.split_block(cfg(), block)
    assert length(shards) == 6
    assert length(cks) == 6
    assert Enum.all?(shards, &(byte_size(&1) == sl))
    assert Enum.all?(cks, &(byte_size(&1) == 32))
    assert rem(sl, 2) == 0
  end

  test "split -> restore round-trip（无丢失）还原原文" do
    block = :crypto.strong_rand_bytes(900)
    %{shards: shards, checksums: cks} = Codec.split_block(cfg(), block)
    out = Codec.restore_block(cfg(), shards, cks, byte_size(block))
    assert out == block
  end

  test "restore 容忍 M 个 nil 分片" do
    block = :crypto.strong_rand_bytes(2048)
    %{shards: shards, checksums: cks} = Codec.split_block(cfg(), block)
    damaged = shards |> List.replace_at(0, nil) |> List.replace_at(5, nil)
    out = Codec.restore_block(cfg(), damaged, cks, byte_size(block))
    assert out == block
  end

  test "restore 检测 bitrot（分片被篡改但非 nil）-> 校验和不符置 nil -> 仍重建" do
    block = :crypto.strong_rand_bytes(2048)
    %{shards: shards, checksums: cks} = Codec.split_block(cfg(), block)
    # 篡改第 0 个分片的首字节（校验和将不匹配，应被当作缺失）
    corrupt = List.update_at(shards, 0, fn <<b, rest::binary>> -> <<bxor(b, 0xFF), rest::binary>> end)
    out = Codec.restore_block(cfg(), corrupt, cks, byte_size(block))
    assert out == block
  end

  test "存活分片 < K（含篡改）-> raise InsufficientShardsError" do
    block = :crypto.strong_rand_bytes(2048)
    %{shards: shards, checksums: cks} = Codec.split_block(cfg(), block)
    # 置 nil 2 个 + 篡改 1 个 = 3 个失效 > M=2，存活 3 < K=4
    bad =
      shards
      |> List.replace_at(0, nil)
      |> List.replace_at(1, nil)
      |> List.update_at(2, fn <<b, rest::binary>> -> <<bxor(b, 0xFF), rest::binary>> end)

    assert_raise InsufficientShardsError, fn ->
      Codec.restore_block(cfg(), bad, cks, byte_size(block), bucket: "b", key: "k", block_index: 0)
    end
  end

  test "verify_shard：nil -> false；匹配 -> true；篡改 -> false" do
    block = :crypto.strong_rand_bytes(128)
    %{shards: [s0 | _], checksums: [c0 | _]} = Codec.split_block(cfg(), block)
    assert Codec.verify_shard(s0, c0)
    refute Codec.verify_shard(nil, c0)
    <<b, rest::binary>> = s0
    refute Codec.verify_shard(<<bxor(b, 0xFF), rest::binary>>, c0)
  end
end
```

> 注：`bxor/2` 在 Elixir 是 `Bitwise.bxor/2`，测试文件顶部需 `import Bitwise`。executor 落地时在测试 `use ExUnit.Case` 后加 `import Bitwise`。

运行确认红。新建 `lib/maxio/storage/erasure/codec.ex`：

```elixir
defmodule Maxio.Storage.Erasure.Codec do
  @moduledoc """
  纠删码块编解码（纯 Elixir，over Maxio.Native.ErasureCoding NIF）。

    * split_block/2    —— 把一个 block 编码为 N=K+M 个等长分片 + 每分片一个 BLAKE3-256 校验和。
    * restore_block/5  —— 验证每个非 nil 分片的校验和（不匹配/缺失视为丢失），从存活分片重建并截断到
                          原始 block 长度。**存活 < K（read quorum）-> raise InsufficientShardsError**（铁律 3）。
    * verify_shard/2   —— 单分片校验和验证（nil -> false）。

  RS 只纠 erasure（已知缺失），不定位 silent corruption；本层用校验和把损坏分片显式标记为缺失，
  再交 NIF 重建——这是 bitrot 安全的关键：绝不把"在场但损坏"的分片当好分片喂解码器。
  """
  alias Maxio.Native.ErasureCoding
  alias Maxio.Storage.Erasure.{Config, InsufficientShardsError}

  @type split :: %{shards: [binary()], checksums: [binary()], shard_len: pos_integer()}

  @doc "把 block 切成 N 个分片 + N 个 BLAKE3-256 校验和。"
  @spec split_block(Config.t(), binary()) :: split()
  def split_block(%Config{data_shards: k, parity_shards: m}, block) when is_binary(block) do
    shards = ErasureCoding.encode(k, m, block)
    checksums = Enum.map(shards, &ErasureCoding.blake3/1)
    [first | _] = shards
    %{shards: shards, checksums: checksums, shard_len: byte_size(first)}
  end

  @doc "验证单个分片：nil 或校验和不符 -> false。"
  @spec verify_shard(binary() | nil, binary()) :: boolean()
  def verify_shard(nil, _checksum), do: false

  def verify_shard(shard, checksum) when is_binary(shard) and is_binary(checksum) do
    ErasureCoding.blake3(shard) == checksum
  end

  @doc """
  从 N 个分片（缺失/损坏为 nil）+ N 个存储校验和重建 block，截断到 data_len。
  逐分片验证校验和：不通过的强制置 nil（视为缺失）。存活 >= K -> 重建+截断；< K -> raise。
  `meta` 为可选元数据（bucket/key/version_id/block_index）用于结构化异常/日志。
  """
  @spec restore_block(Config.t(), [binary() | nil], [binary()], non_neg_integer(), keyword()) ::
          binary()
  def restore_block(%Config{} = cfg, shards, checksums, data_len, meta \\ [])
      when is_list(shards) and is_list(checksums) and is_integer(data_len) and data_len >= 0 do
    %Config{data_shards: k, parity_shards: m, read_quorum: read_quorum} = cfg

    verified =
      shards
      |> Enum.zip(checksums)
      |> Enum.map(fn {shard, ck} -> if verify_shard(shard, ck), do: shard, else: nil end)

    present = Enum.count(verified, &(&1 != nil))

    if present < read_quorum do
      raise InsufficientShardsError,
        bucket: Keyword.get(meta, :bucket),
        key: Keyword.get(meta, :key),
        version_id: Keyword.get(meta, :version_id),
        block_index: Keyword.get(meta, :block_index),
        present: present,
        required: read_quorum
    end

    padded = ErasureCoding.reconstruct(k, m, verified)
    binary_part(padded, 0, min(data_len, byte_size(padded)))
  end
end
```

运行确认绿：

```powershell
mix test test/maxio/storage/erasure/codec_test.exs
```

期望：`6 tests, 0 failures`。

### 单元收尾验证（M6-2）

```powershell
mix compile --warnings-as-errors
mix test test/maxio/storage/erasure/config_test.exs test/maxio/storage/erasure/codec_test.exs
```

期望：编译零警告；两文件全绿。提交：

```powershell
git add -A
git commit -m @'
M6-2: Erasure block codec layer over NIF — Config (K/M/block_size load+validate, read/write quorum incl. K==M split-brain K+1); Codec split_block/restore_block/verify_shard with per-shard BLAKE3 bitrot detection (corrupt shard -> treated missing -> reconstruct); InsufficientShardsError raised when survivors < K (never silent wrong data)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) Config 校验 N==K+M / M<=N/2 / quorum 计算（含 K==M -> write_quorum=K+1）；(2) Codec round-trip + 容忍 M 个 nil + **bitrot（篡改分片）经校验和被当缺失仍重建**；(3) 存活 < K raise `InsufficientShardsError`（结构化字段齐全，不静默）；(4) 零警告。

---


## M6-3 · `Maxio.Storage.ErasureCoded`：put/get/stat/delete + bucket ops（流式逐块 + sidecar + quorum）

**目标**：实现纠删码后端的对象读写一半——`put/get/stat/delete/put_bucket/delete_bucket`，满足 `Maxio.Storage.Backend` 契约且**与 FS 返回形态逐字节一致**。put 把对象**逐块流式**编码、分片 i 追加到盘 i 的 `part.0`、写 per-object meta sidecar 到全部 N 盘；get 逐块读 K 个存活分片、校验、重建、流式发出；stat 读 sidecar 的 size；delete 跨盘删对象目录。**绝不缓冲整对象**（铁律 4）。parts 留 M6-4。

**依赖**：M6-2。**规模**：大（Meta sidecar 编解码 + 后端 put/get/stat/delete/bucket ops + 流式块缓冲 + quorum 映射 + config + 单测）。

### 关键事实与设计（bake-in）

- **盘上布局**（每盘 i，version_id="null" 走原路径段、否则 `.versions/<bucket>/<key>/<version_id>` 段，照抄 FS 约定）：
  ```
  <drive_i>/<bucket>/<rel>/part.0       # 盘 i 对该对象单 PUT 的分片字节（流式追加）
  <drive_i>/<bucket>/<rel>/meta.json    # per-object sidecar（每盘一份，内容相同）
  ```
  其中 `<rel>` = `safe_relative(key)` 的结果（version="null"）或 `.versions/<bucket>/<rel>/<version_id>`（带版本）。注意：对象是一个**目录**（含 part.0 + meta.json），不是单文件——与 FS 的「单文件对象」不同，但上层 behaviour 无感（只认 `{:ok, %{size,etag,sha256}}` / 流）。
- **per-object meta sidecar**（Jason JSON，每盘一份；heal 用任一存活副本）：
  ```json
  {
    "ec":   {"k": 4, "m": 2, "block_size": 1048576, "algo": "blake3-256"},
    "size": 1234567,
    "etag": "<md5 hex of 明文>",
    "sha256": "<sha256 hex of 明文>",
    "parts": [{"part": 0, "size": 1234567}],
    "shards": [
      {"drive": 0, "shard_file_size": 308642, "block_hashes": ["<hex b0>", "<hex b1>", ...]},
      ... 每盘一项 0..N-1 ...
    ]
  }
  ```
  - `block_hashes[j]` = 盘 i 分片在 block j 的 BLAKE3 校验和（hex）。GET/heal 用它做 per-block bitrot 检测。
  - `size` = 明文总长 L（GET 重建时按 L 截断 + Range 计算）；`shard_file_size` = 该盘 part.0 字节数（= 块数 × shard_len，所有盘相同，但分开记便于 heal 校验文件完整）。
  - `etag`/`sha256` over **明文流**，与 FS 完全一致。
- **流式 PUT**：把 `chunks` Enumerable 重切成固定 `block_size` 逻辑块（手写一个累积缓冲 reducer，**任意时刻只持有 < block_size 的待累积字节 + 当前满块**）。每满一块：喂明文 MD5/SHA256；`Codec.split_block` → N 个分片 + N 校验和；分片 i `IO.binwrite` 追加到盘 i 的 part.0 fd；把 block j 的 N 个校验和按盘累积进 `block_hashes`。流尽后写最后不满块（含空对象 → 至少一个块以保持解码一致；空对象 block_size 块数为 0，sidecar `size:0`、part.0 为 0 字节、`block_hashes:[]`，GET 返回空流）。
- **write quorum**：N 盘里成功写完所有分片 + sidecar 的盘数 ≥ `write_quorum` → `{:ok, ...}`（即使个别盘失败也成功，degraded，结构化 warning 日志，heal 后补）。< write_quorum → `{:error, :write_quorum}`（铁律 3）。
  - **MVP 简化（诚实文档化）**：M6-3 的 PUT 在所有盘**串行 fd 写**；若某盘 open/write 抛错，记录该盘失败、继续其余盘；末尾按成功盘数判 quorum。所有盘成功是常态（单机本地盘）；盘级失败注入主要在 heal 测试（M6-5）覆盖。
- **流式 GET**：`Stream.resource/3` 逐 block：对每盘 i `:file.pread(fd_i, j*shard_len, shard_len)` 取 block j 的分片（读不到/盘缺失 → nil）；`Codec.restore_block`（内部按 sidecar 的 `block_hashes[j]` 验证 + 重建 + 截断到该 block 的明文长度）→ emit。最后一块明文长度 = `L - (num_blocks-1)*block_size`。**read quorum 不足在 restore_block 内 raise**（惰性流崩溃 → handler 映射 5xx；GET 入口先 stat 确认对象存在，故 `{:error,:enoent}` 与 quorum 错误区分清晰）。
- **Range**：把 `{first,last}` 映射到 block 区间，跳过 first 之前的整块、解码含 first 的块起逐块发出、裁剪首尾边界块——与 FS `stream_file/3` 的含端点 0-based 语义一致。
- **version_id 维度**：完全照抄 FS 的 `object_path` version 约定，只是每盘一份。

### 步骤 1：Meta sidecar（TDD）

新建 `test/maxio/storage/erasure/meta_test.exs`：

```elixir
defmodule Maxio.Storage.Erasure.MetaTest do
  use ExUnit.Case, async: true
  alias Maxio.Storage.Erasure.Meta

  test "encode -> decode! round-trip 保形" do
    m = %{
      "ec" => %{"k" => 4, "m" => 2, "block_size" => 1024, "algo" => "blake3-256"},
      "size" => 900,
      "etag" => "abc",
      "sha256" => "def",
      "parts" => [%{"part" => 0, "size" => 900}],
      "shards" => [
        %{"drive" => 0, "shard_file_size" => 256, "block_hashes" => ["aa", "bb"]},
        %{"drive" => 1, "shard_file_size" => 256, "block_hashes" => ["cc", "dd"]}
      ]
    }

    bin = Meta.encode(m)
    assert is_binary(bin)
    assert Meta.decode!(bin) == m
  end
end
```

运行确认红。新建 `lib/maxio/storage/erasure/meta.ex`：

```elixir
defmodule Maxio.Storage.Erasure.Meta do
  @moduledoc """
  纠删码 per-object（及 per-part）元数据 sidecar 的编解码（Jason JSON）。每盘一份，内容相同；
  heal 从任一存活副本恢复。形态见 M6 计划「盘上布局」节。
  """

  @spec encode(map()) :: binary()
  def encode(map) when is_map(map), do: Jason.encode!(map)

  @spec decode!(binary()) :: map()
  def decode!(bin) when is_binary(bin), do: Jason.decode!(bin)
end
```

运行确认绿：

```powershell
mix test test/maxio/storage/erasure/meta_test.exs
```

期望：`1 test, 0 failures`。

### 步骤 2：后端 put/get/stat/delete + bucket ops（TDD）

新建 `test/maxio/storage/erasure_coded_test.exs`（本单元只测对象读写 + bucket；parts/conformance 在 M6-4）：

```elixir
defmodule Maxio.Storage.ErasureCodedTest do
  use ExUnit.Case, async: true

  alias Maxio.Storage.ErasureCoded

  setup do
    base = Path.join(System.tmp_dir!(), "maxio_ec_test_#{System.unique_integer([:positive])}")
    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, drives: drives}
  end

  defp opts(drives), do: [drives: drives, data_shards: 4, parity_shards: 2, block_size: 1024]

  test "put 流式写入并返回 size/etag(明文 MD5)/sha256(明文)", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    body = :crypto.strong_rand_bytes(3000)
    chunks = for <<c::binary-500 <- body>>, do: c

    {:ok, %{size: size, etag: etag, sha256: sha256}} =
      ErasureCoded.put("b", "k.bin", "null", chunks, opts(drives))

    assert size == byte_size(body)
    assert etag == (:crypto.hash(:md5, body) |> Base.encode16(case: :lower))
    assert sha256 == (:crypto.hash(:sha256, body) |> Base.encode16(case: :lower))
    refute String.contains?(etag, "\"")
  end

  test "get 全量重建 == 原文（跨多块）", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], opts(drives))
    {:ok, stream} = ErasureCoded.get("b", "k", "null", nil, opts(drives))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  test "get 容忍 M 个分片缺失（删盘上 part.0）后仍重建", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], opts(drives))
    # 删除 2 个盘（M=2）的对象目录
    Enum.each([Enum.at(drives, 0), Enum.at(drives, 5)], fn d ->
      File.rm_rf!(Path.join([d, "b", "k"]))
    end)

    {:ok, stream} = ErasureCoded.get("b", "k", "null", nil, opts(drives))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  test "get Range 返回含端点字节区间", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    body = for(i <- 0..2999, do: rem(i, 256)) |> :erlang.list_to_binary()
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], opts(drives))

    {:ok, s1} = ErasureCoded.get("b", "k", "null", {0, 4}, opts(drives))
    assert IO.iodata_to_binary(Enum.to_list(s1)) == binary_part(body, 0, 5)

    {:ok, s2} = ErasureCoded.get("b", "k", "null", {1000, 1500}, opts(drives))
    assert IO.iodata_to_binary(Enum.to_list(s2)) == binary_part(body, 1000, 501)
  end

  test "空对象 round-trip", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    {:ok, %{size: 0, etag: etag}} = ErasureCoded.put("b", "empty", "null", [], opts(drives))
    assert etag == (:crypto.hash(:md5, "") |> Base.encode16(case: :lower))
    {:ok, stream} = ErasureCoded.get("b", "empty", "null", nil, opts(drives))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == ""
  end

  test "stat 返回 size；不存在 :enoent", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    {:ok, _} = ErasureCoded.put("b", "k", "null", ["abc"], opts(drives))
    assert {:ok, %{size: 3}} = ErasureCoded.stat("b", "k", "null", opts(drives))
    assert {:error, :enoent} = ErasureCoded.stat("b", "missing", "null", opts(drives))
  end

  test "delete 跨盘删对象，重复 get :enoent；幂等", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    {:ok, _} = ErasureCoded.put("b", "k", "null", ["abc"], opts(drives))
    assert :ok = ErasureCoded.delete("b", "k", "null", opts(drives))
    assert {:error, :enoent} = ErasureCoded.get("b", "k", "null", nil, opts(drives))
    assert :ok = ErasureCoded.delete("b", "k", "null", opts(drives))
  end

  test "version_id 维度：不同版本物理隔离", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    {:ok, _} = ErasureCoded.put("b", "k", "null", ["v-null"], opts(drives))
    {:ok, _} = ErasureCoded.put("b", "k", "01ABC", ["v-one"], opts(drives))
    {:ok, s0} = ErasureCoded.get("b", "k", "null", nil, opts(drives))
    {:ok, s1} = ErasureCoded.get("b", "k", "01ABC", nil, opts(drives))
    assert IO.iodata_to_binary(Enum.to_list(s0)) == "v-null"
    assert IO.iodata_to_binary(Enum.to_list(s1)) == "v-one"
  end

  test "key 含 ../ 被拒", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", opts(drives))
    assert {:error, :invalid_key} = ErasureCoded.put("b", "../escape", "null", ["x"], opts(drives))
  end

  test "put_bucket 建各盘目录；delete_bucket 删各盘空目录", %{drives: drives} do
    assert :ok = ErasureCoded.put_bucket("nb", opts(drives))
    assert Enum.all?(drives, &File.dir?(Path.join(&1, "nb")))
    assert :ok = ErasureCoded.delete_bucket("nb", opts(drives))
    refute Enum.any?(drives, &File.exists?(Path.join(&1, "nb")))
  end
end
```

运行确认红。新建 `lib/maxio/storage/erasure_coded.ex`（完整对象读写 + bucket ops；parts 在 M6-4 追加同模块）：

```elixir
defmodule Maxio.Storage.ErasureCoded do
  @moduledoc """
  Reed-Solomon 纠删码存储后端（单机多盘 = 一个 erasure set），实现 Maxio.Storage.Backend 契约，
  与 Maxio.Storage.FS 返回形态逐字节一致（铁律 2：后端即插件，核心管线一行不改）。

  对象在每个盘 i 落成一个目录：part.0（盘 i 的分片字节，逐块流式追加）+ meta.json（per-object sidecar）。
  put 逐块流式编码（绝不缓冲整对象，铁律 4），分片 i 写盘 i + sidecar 写全部 N 盘，
  成功盘数 >= write_quorum 才 {:ok}，否则 {:error,:write_quorum}（铁律 3）。
  get 逐块读 K 个存活分片、按 sidecar 的 per-block BLAKE3 校验、重建、流式发出；
  存活 < K -> raise InsufficientShardsError（绝不静默返回错数据）。

  每个 callback 接受可选末参 opts（:drives 覆盖盘目录列表、:data_shards/:parity_shards/:block_size
  覆盖 EC 参数，便于测试隔离），缺省从 config :maxio, :erasure 读。
  """
  @behaviour Maxio.Storage.Backend

  require Logger

  alias Maxio.Storage.Erasure.{Codec, Config, Meta}

  @meta_file "meta.json"
  @part_file "part.0"
  @read_chunk 1_048_576

  # ── Backend callbacks（签名与 FS 一致；opts 末参默认）──

  @impl true
  def put(bucket, key, version_id \\ "null", chunks, opts \\ [])
  def put(bucket, key, version_id, chunks, opts), do: do_put(bucket, key, version_id, chunks, opts)

  @impl true
  def get(bucket, key, version_id \\ "null", range \\ nil, opts \\ []),
    do: do_get(bucket, key, version_id, range, opts)

  @impl true
  def stat(bucket, key, version_id \\ "null", opts \\ []), do: do_stat(bucket, key, version_id, opts)

  @impl true
  def delete(bucket, key, version_id \\ "null", opts \\ []),
    do: do_delete(bucket, key, version_id, opts)

  @impl true
  def put_bucket(bucket, opts \\ []), do: do_put_bucket(bucket, opts)

  @impl true
  def delete_bucket(bucket, opts \\ []), do: do_delete_bucket(bucket, opts)

  # ── 对象目录布局（每盘一份）──

  # 对象在盘 d 下的目录：<d>/<bucket>/<rel>（null 版本）或 <d>/.versions/<bucket>/<rel>/<version_id>。
  defp object_dirs(bucket, key, version_id, cfg) do
    case safe_relative(key) do
      {:ok, rel} ->
        sub =
          if version_id == "null" do
            Path.join([bucket, rel])
          else
            Path.join([".versions", bucket, rel, version_id])
          end

        {:ok, Enum.map(cfg.drives, &Path.join(&1, sub))}

      :error ->
        {:error, :invalid_key}
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

  # ── PUT：逐块流式编码 ──

  defp do_put(bucket, key, version_id, chunks, opts) do
    cfg = Config.load!(opts)

    with {:ok, dirs} <- object_dirs(bucket, key, version_id, cfg) do
      Enum.each(dirs, &File.mkdir_p!/1)
      # 每盘打开 part.0 写句柄。
      fds = Enum.map(dirs, fn dir -> open_write!(Path.join(dir, @part_file)) end)

      try do
        acc0 = %{
          md5: :crypto.hash_init(:md5),
          sha: :crypto.hash_init(:sha256),
          size: 0,
          shard_len: nil,
          # 每盘一个 block_hashes 反序列表（hex）
          block_hashes: List.duplicate([], Config.total(cfg)),
          buffer: <<>>,
          fds: fds
        }

        acc = Enum.reduce(chunks, acc0, fn chunk, acc -> feed(cfg, acc, chunk) end)
        acc = flush_final(cfg, acc)

        etag = acc.md5 |> :crypto.hash_final() |> Base.encode16(case: :lower)
        sha256 = acc.sha |> :crypto.hash_final() |> Base.encode16(case: :lower)
        shard_len = acc.shard_len || 0

        meta =
          build_meta(cfg, acc.size, etag, sha256, shard_len, Enum.map(acc.block_hashes, &Enum.reverse/1))

        # sidecar 写全部 N 盘，统计成功盘数（write quorum）。
        ok_drives = write_sidecars(dirs, meta)

        if ok_drives >= cfg.write_quorum do
          {:ok, %{size: acc.size, etag: etag, sha256: sha256}}
        else
          Logger.error("erasure put below write quorum",
            bucket: bucket,
            key: key,
            reason: "ok_drives=#{ok_drives} < write_quorum=#{cfg.write_quorum}"
          )

          {:error, :write_quorum}
        end
      after
        Enum.each(fds, &File.close/1)
      end
    end
  end

  # 累积 chunk 到 buffer，满 block_size 即编码落盘。
  defp feed(cfg, acc, chunk) do
    acc = %{
      acc
      | md5: :crypto.hash_update(acc.md5, chunk),
        sha: :crypto.hash_update(acc.sha, chunk),
        size: acc.size + byte_size(chunk),
        buffer: acc.buffer <> chunk
    }

    drain_full_blocks(cfg, acc)
  end

  defp drain_full_blocks(cfg, %{buffer: buffer} = acc) when byte_size(buffer) >= cfg.block_size do
    <<block::binary-size(cfg.block_size), rest::binary>> = buffer
    acc = write_block(cfg, %{acc | buffer: rest}, block)
    drain_full_blocks(cfg, acc)
  end

  defp drain_full_blocks(_cfg, acc), do: acc

  # 流尽：写最后不满块（非空对象至少一个块；空对象 buffer="" 不写块）。
  defp flush_final(_cfg, %{buffer: <<>>} = acc), do: acc
  defp flush_final(cfg, %{buffer: buffer} = acc), do: write_block(cfg, %{acc | buffer: <<>>}, buffer)

  # 编码一个 block：N 分片写各盘 fd，校验和按盘累积。
  defp write_block(cfg, acc, block) do
    %{shards: shards, checksums: checksums, shard_len: shard_len} = Codec.split_block(cfg, block)

    Enum.zip(acc.fds, shards) |> Enum.each(fn {fd, shard} -> :ok = IO.binwrite(fd, shard) end)

    block_hashes =
      acc.block_hashes
      |> Enum.zip(checksums)
      |> Enum.map(fn {acc_list, ck} -> [Base.encode16(ck, case: :lower) | acc_list] end)

    %{acc | shard_len: shard_len, block_hashes: block_hashes}
  end

  defp build_meta(cfg, size, etag, sha256, shard_len, block_hashes_per_drive) do
    n = Config.total(cfg)

    shards =
      for i <- 0..(n - 1) do
        hashes = Enum.at(block_hashes_per_drive, i)
        %{"drive" => i, "shard_file_size" => length(hashes) * shard_len, "block_hashes" => hashes}
      end

    %{
      "ec" => %{
        "k" => cfg.data_shards,
        "m" => cfg.parity_shards,
        "block_size" => cfg.block_size,
        "algo" => "blake3-256"
      },
      "size" => size,
      "etag" => etag,
      "sha256" => sha256,
      "parts" => [%{"part" => 0, "size" => size}],
      "shards" => shards
    }
  end

  defp write_sidecars(dirs, meta) do
    bin = Meta.encode(meta)

    Enum.reduce(dirs, 0, fn dir, ok ->
      case File.write(Path.join(dir, @meta_file), bin) do
        :ok -> ok + 1
        {:error, _} -> ok
      end
    end)
  end

  # ── GET：逐块流式重建 ──

  defp do_get(bucket, key, version_id, range, opts) do
    cfg = Config.load!(opts)

    with {:ok, dirs} <- object_dirs(bucket, key, version_id, cfg),
         {:ok, meta} <- read_any_sidecar(dirs) do
      size = meta["size"]
      block_size = get_in(meta, ["ec", "block_size"])
      {first, last} = normalize_range(range, size)

      if size == 0 or last < first do
        {:ok, []}
      else
        {:ok, stream_object(cfg, bucket, key, version_id, dirs, meta, block_size, first, last)}
      end
    else
      {:error, :enoent} -> {:error, :enoent}
      :error -> {:error, :invalid_key}
    end
  end

  defp normalize_range(nil, size), do: {0, max(size - 1, 0)}
  defp normalize_range({first, last}, _size), do: {first, last}

  # 逐 block 读 K 存活分片、校验+重建、裁剪到 [first,last]，发出。
  defp stream_object(cfg, bucket, key, version_id, dirs, meta, block_size, first, last) do
    n = Config.total(cfg)
    shards_meta = meta["shards"]
    size = meta["size"]
    shard_len = block_shard_len(meta, cfg)
    first_block = div(first, block_size)
    last_block = div(last, block_size)

    Stream.resource(
      fn ->
        fds =
          Enum.map(dirs, fn dir ->
            case :file.open(String.to_charlist(Path.join(dir, @part_file)), [:read, :binary, :raw]) do
              {:ok, fd} -> fd
              {:error, _} -> nil
            end
          end)

        {fds, first_block}
      end,
      fn
        {fds, j} when j > last_block ->
          {:halt, fds}

        {fds, j} ->
          block_plain_len = block_plain_len(size, block_size, j)

          shards =
            Enum.with_index(fds)
            |> Enum.map(fn {fd, i} -> read_shard(fd, j, shard_len, shards_meta, i) end)

          checksums = block_checksums(shards_meta, n, j)

          plain =
            Codec.restore_block(cfg, shards, checksums, block_plain_len,
              bucket: bucket,
              key: key,
              version_id: version_id,
              block_index: j
            )

          # 裁剪到 [first,last] 与本块的交集。
          block_start = j * block_size
          lo = max(first, block_start) - block_start
          hi = min(last, block_start + block_plain_len - 1) - block_start
          out = binary_part(plain, lo, hi - lo + 1)
          {[out], {fds, j + 1}}
      end,
      fn fds -> Enum.each(fds, fn fd -> if fd, do: :file.close(fd) end) end
    )
  end

  # 某盘缺/读不到 -> nil；否则该盘 block j 的分片字节。
  defp read_shard(nil, _j, _shard_len, _shards_meta, _i), do: nil

  defp read_shard(fd, j, shard_len, shards_meta, i) do
    drive_meta = Enum.at(shards_meta, i)

    if drive_meta && j < length(drive_meta["block_hashes"]) do
      case :file.pread(fd, j * shard_len, shard_len) do
        {:ok, data} when byte_size(data) == shard_len -> data
        _ -> nil
      end
    else
      nil
    end
  end

  # block j 的 N 个存储校验和（来自 sidecar，原始字节；缺位补 32 个 0 -> 必不匹配 -> 当缺失）。
  defp block_checksums(shards_meta, n, j) do
    for i <- 0..(n - 1) do
      drive_meta = Enum.at(shards_meta, i)
      hex = drive_meta && Enum.at(drive_meta["block_hashes"], j)

      case hex && Base.decode16(hex, case: :lower) do
        {:ok, raw} -> raw
        _ -> <<0::256>>
      end
    end
  end

  # 由 sidecar 推 shard_len：shard_file_size / 块数（取首个有块的盘）。
  defp block_shard_len(meta, cfg) do
    block_size = get_in(meta, ["ec", "block_size"]) || cfg.block_size

    meta["shards"]
    |> Enum.find_value(fn s ->
      bh = s["block_hashes"]

      if is_list(bh) and length(bh) > 0 and s["shard_file_size"] > 0 do
        div(s["shard_file_size"], length(bh))
      end
    end) || div(block_size + cfg.data_shards - 1, cfg.data_shards)
  end

  # 第 j 块的明文长度（除最后一块外都是 block_size）。
  defp block_plain_len(size, block_size, j) do
    num_blocks = div(size + block_size - 1, block_size)

    cond do
      num_blocks == 0 -> 0
      j < num_blocks - 1 -> block_size
      true -> size - (num_blocks - 1) * block_size
    end
  end

  # ── stat / delete / bucket ──

  defp do_stat(bucket, key, version_id, opts) do
    cfg = Config.load!(opts)

    with {:ok, dirs} <- object_dirs(bucket, key, version_id, cfg),
         {:ok, meta} <- read_any_sidecar(dirs) do
      {:ok, %{size: meta["size"]}}
    else
      {:error, :enoent} -> {:error, :enoent}
      :error -> {:error, :invalid_key}
    end
  end

  defp do_delete(bucket, key, version_id, opts) do
    cfg = Config.load!(opts)

    with {:ok, dirs} <- object_dirs(bucket, key, version_id, cfg) do
      Enum.each(dirs, fn dir -> _ = File.rm_rf(dir) end)
      :ok
    end
  end

  defp do_put_bucket(bucket, opts) do
    cfg = Config.load!(opts)
    Enum.each(cfg.drives, fn d -> File.mkdir_p!(Path.join(d, bucket)) end)
    :ok
  end

  defp do_delete_bucket(bucket, opts) do
    cfg = Config.load!(opts)

    Enum.each(cfg.drives, fn d ->
      case File.rmdir(Path.join(d, bucket)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        # 其余盘上非空/出错忽略（与 FS 单盘 rmdir 语义对齐：仅删空目录）
        {:error, _} -> :ok
      end
    end)

    :ok
  end

  # ── 辅助 ──

  defp read_any_sidecar(dirs) do
    Enum.find_value(dirs, {:error, :enoent}, fn dir ->
      case File.read(Path.join(dir, @meta_file)) do
        {:ok, bin} -> {:ok, Meta.decode!(bin)}
        {:error, _} -> nil
      end
    end)
  end

  defp open_write!(path) do
    {:ok, fd} = File.open(path, [:write, :binary, :raw])
    fd
  end

  # @read_chunk 供 M6-4 part 读复用（避免未用告警：part 流读以它为单位）。
  def __read_chunk__, do: @read_chunk
end
```

> **实现注记（executor 必读）**：
> - `delete_bucket` 在 FS 是「仅删空 bucket 目录」（`File.rmdir`）。EC 跨盘同义：每盘 `rmdir` bucket 目录，非空/出错宽容忽略（与上层「DeleteBucket 非空 409」由 handler 经元数据判定一致——存储层只负责物理删空壳）。
> - `@read_chunk` + `__read_chunk__/0` 仅为 M6-4 的 part 流读预留并消除「未用模块属性」告警；若 executor 在 M6-3 编译期遇到未用告警，保留此函数即可（M6-4 会真正用到 part 流读单位）。
> - 空对象：`chunks=[]` → 无块写入 → `shard_len=0`、`block_hashes` 全空、part.0 为 0 字节、sidecar `size:0`；`get` 命中 `size==0` 分支返回 `[]`（空流），etag/sha256 为空串内容的哈希。

运行确认绿：

```powershell
mix test test/maxio/storage/erasure_coded_test.exs
```

期望：全部用例通过（put/get 全量/容忍 M 缺失/Range/空对象/stat/delete/version/路径守卫/bucket = 约 11 个，`0 failures`）。

### 步骤 3：config 追加 erasure 配置块（不改既有 key）

修改 `config/config.exs`，在 `config :maxio, :storage_backend, Maxio.Storage.FS` 之前追加（**默认仍 FS，erasure 仅提供默认参数供 opt-in 与测试**）：

```elixir
# 纠删码后端默认参数（单机多盘 = 一个 erasure set）。默认后端仍为 FS（见下）；
# 切到纠删码：把 storage_backend 改为 Maxio.Storage.ErasureCoded 即可（铁律 2：换后端只改一行）。
# drives = N 个本地盘目录（N = data_shards + parity_shards）；block_size = 流式块（MinIO v2 默认 1 MiB）。
config :maxio, :erasure,
  drives: [
    Path.expand("../priv/s3_data/ec/d0", __DIR__),
    Path.expand("../priv/s3_data/ec/d1", __DIR__),
    Path.expand("../priv/s3_data/ec/d2", __DIR__),
    Path.expand("../priv/s3_data/ec/d3", __DIR__),
    Path.expand("../priv/s3_data/ec/d4", __DIR__),
    Path.expand("../priv/s3_data/ec/d5", __DIR__)
  ],
  data_shards: 4,
  parity_shards: 2,
  block_size: 1_048_576
```

### 单元收尾验证（M6-3）

```powershell
mix compile --warnings-as-errors
mix test test/maxio/storage/erasure/meta_test.exs test/maxio/storage/erasure_coded_test.exs
```

期望：编译零警告；两文件全绿。提交：

```powershell
git add -A
git commit -m @'
M6-3: Maxio.Storage.ErasureCoded put/get/stat/delete + bucket ops — streaming block-at-a-time RS encode on PUT (shard i -> drive i, per-object meta.json sidecar on all N drives, write quorum), decode-on-read GET (per-block BLAKE3 verify + reconstruct, tolerate M missing, Range), version_id dimension + path guard mirroring FS; meta sidecar codec; erasure config defaults

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) put 返回 `%{size,etag,sha256}` 且 etag/sha256 over 明文、逐字节对齐 FS；(2) get 全量重建跨多块正确、容忍 M 个分片缺失、Range 含端点正确、空对象正确；(3) PUT/GET 流式（无 `Enum.to_list` 整对象）；(4) stat/delete/version 维度/路径守卫/bucket ops 正确且幂等；(5) sidecar 每盘一份且内容一致；(6) 零警告。

---


## M6-4 · ErasureCoded parts（multipart）+ 共享 conformance 套件 + config 切后端 + S3 e2e 切片

**目标**：补齐纠删码后端的另一半——`put_part/get_part_stream/assemble/abort_upload`（复用同一块编解码机制）；建一套**共享 backend conformance 测试**，同时跑 `Maxio.Storage.FS` 与 `Maxio.Storage.ErasureCoded`（证明两后端满足同一契约）；提供 config 切后端能力，并把既有 S3 集成 e2e 的一个切片跑在纠删码后端上。

**依赖**：M6-3。**规模**：parts 实现（在 ErasureCoded 同模块追加）+ 共享 conformance 套件 + 一个 e2e 切片 + 测试基础设施。

### 关键事实与设计（bake-in）

- **part 盘上布局**（照抄 FS 的 `.uploads/<bucket>/<upload_id>/<n>.part` 约定，每盘一份 + part sidecar）：
  ```
  <drive_i>/.uploads/<bucket>/<upload_id>/<part_number>/part.0        # 盘 i 对该 part 的分片字节
  <drive_i>/.uploads/<bucket>/<upload_id>/<part_number>/meta.json     # part sidecar（含 md5_raw hex + block_hashes）
  ```
- `put_part`：流式逐块编码该 part（与 `do_put` 同机制，但额外算 part 的 16 字节原始 MD5 `md5_raw`，**不算 sha256**——FS 的 part_put_result 只有 `%{size, etag, md5_raw}`）。返回 `%{size, etag, md5_raw}`，etag = MD5 hex（无引号）。
- `get_part_stream`：EC-解码该 part 的分片回明文（整 part，无 Range），与 `do_get` `range=nil` 同路径。
- `assemble`：按 part number 升序，逐 part EC-解码其分片回明文、**再逐块 EC-重新编码进最终对象的 part.0**（流式，块接块），累计总 size 与最终对象 etag/sha256，写对象 sidecar 到全部 N 盘。这是最简单正确路径（组装后对象是普通 EC 对象，GET 走 `do_get`）。
- `abort_upload`：跨盘 `File.rm_rf` 该 upload 的目录；幂等。
- **md5_raw 语义**：part 的 `md5_raw` 是**该 part 明文字节**的 16 字节 MD5（multipart complete 的 ETag 由各 part md5_raw 拼接再 MD5——上层 `Maxio.Multipart` 逻辑不变，只要后端返回正确 md5_raw）。

### 步骤 1：parts 实现（追加到 `lib/maxio/storage/erasure_coded.ex`）

在 ErasureCoded 模块的 bucket ops 段之后、`# ── 辅助 ──` 段之前，追加 parts callbacks 与实现：

```elixir
  # ── 分段上传 parts 回调（M6-4）。part 分片落
  # <drive_i>/.uploads/<bucket>/<upload_id>/<n>/part.0 + meta.json；
  # assemble 逐 part 解码再重编码进对象 part.0；abort 跨盘删 upload 目录。──

  @impl true
  def put_part(bucket, key, upload_id, part_number, chunks, opts \\ []),
    do: do_put_part(bucket, key, upload_id, part_number, chunks, opts)

  @impl true
  def get_part_stream(bucket, key, upload_id, part_number, opts \\ []),
    do: do_get_part_stream(bucket, key, upload_id, part_number, opts)

  @impl true
  def assemble(bucket, key, upload_id, part_numbers, opts \\ []),
    do: do_assemble(bucket, key, upload_id, part_numbers, opts)

  @impl true
  def abort_upload(bucket, key, upload_id, opts \\ []),
    do: do_abort_upload(bucket, key, upload_id, opts)

  # part 在盘 d 下的目录。
  defp part_dirs(bucket, upload_id, part_number, cfg) do
    sub = Path.join([".uploads", bucket, upload_id, Integer.to_string(part_number)])
    Enum.map(cfg.drives, &Path.join(&1, sub))
  end

  defp upload_dirs(bucket, upload_id, cfg) do
    sub = Path.join([".uploads", bucket, upload_id])
    Enum.map(cfg.drives, &Path.join(&1, sub))
  end

  defp do_put_part(bucket, _key, upload_id, part_number, chunks, opts) do
    cfg = Config.load!(opts)
    dirs = part_dirs(bucket, upload_id, part_number, cfg)
    Enum.each(dirs, &File.mkdir_p!/1)
    fds = Enum.map(dirs, fn dir -> open_write!(Path.join(dir, @part_file)) end)

    try do
      acc0 = %{
        md5: :crypto.hash_init(:md5),
        sha: nil,
        size: 0,
        shard_len: nil,
        block_hashes: List.duplicate([], Config.total(cfg)),
        buffer: <<>>,
        fds: fds
      }

      acc = Enum.reduce(chunks, acc0, fn chunk, acc -> feed_part(cfg, acc, chunk) end)
      acc = flush_final(cfg, acc)

      md5_raw = :crypto.hash_final(acc.md5)
      etag = Base.encode16(md5_raw, case: :lower)
      shard_len = acc.shard_len || 0

      meta =
        build_part_meta(cfg, acc.size, etag, shard_len, Enum.map(acc.block_hashes, &Enum.reverse/1))

      _ = write_sidecars(dirs, meta)
      {:ok, %{size: acc.size, etag: etag, md5_raw: md5_raw}}
    after
      Enum.each(fds, &File.close/1)
    end
  end

  # 与 feed/3 同，但只更新 MD5（part 不需 sha256）。
  defp feed_part(cfg, acc, chunk) do
    acc = %{
      acc
      | md5: :crypto.hash_update(acc.md5, chunk),
        size: acc.size + byte_size(chunk),
        buffer: acc.buffer <> chunk
    }

    drain_full_blocks(cfg, acc)
  end

  defp build_part_meta(cfg, size, etag, shard_len, block_hashes_per_drive) do
    n = Config.total(cfg)

    shards =
      for i <- 0..(n - 1) do
        hashes = Enum.at(block_hashes_per_drive, i)
        %{"drive" => i, "shard_file_size" => length(hashes) * shard_len, "block_hashes" => hashes}
      end

    %{
      "ec" => %{
        "k" => cfg.data_shards,
        "m" => cfg.parity_shards,
        "block_size" => cfg.block_size,
        "algo" => "blake3-256"
      },
      "size" => size,
      "etag" => etag,
      "parts" => [%{"part" => 0, "size" => size}],
      "shards" => shards
    }
  end

  defp do_get_part_stream(bucket, _key, upload_id, part_number, opts) do
    cfg = Config.load!(opts)
    dirs = part_dirs(bucket, upload_id, part_number, cfg)

    case read_any_sidecar(dirs) do
      {:ok, meta} ->
        size = meta["size"]
        block_size = get_in(meta, ["ec", "block_size"])

        if size == 0 do
          {:ok, []}
        else
          {:ok,
           stream_object(cfg, bucket, "#{upload_id}/#{part_number}", "null", dirs, meta, block_size,
             0, size - 1)}
        end

      {:error, :enoent} ->
        {:error, :enoent}
    end
  end

  defp do_assemble(bucket, key, upload_id, part_numbers, opts) do
    cfg = Config.load!(opts)

    with {:ok, dirs} <- object_dirs(bucket, key, "null", cfg) do
      Enum.each(dirs, &File.mkdir_p!/1)
      fds = Enum.map(dirs, fn dir -> open_write!(Path.join(dir, @part_file)) end)

      try do
        acc0 = %{
          md5: :crypto.hash_init(:md5),
          sha: :crypto.hash_init(:sha256),
          size: 0,
          shard_len: nil,
          block_hashes: List.duplicate([], Config.total(cfg)),
          buffer: <<>>,
          fds: fds
        }

        # 逐 part 解码 -> 喂入对象编码流（块接块流式）。
        acc =
          Enum.reduce(part_numbers, acc0, fn pn, acc ->
            {:ok, part_stream} = do_get_part_stream(bucket, key, upload_id, pn, opts)
            Enum.reduce(part_stream, acc, fn chunk, a -> feed(cfg, a, chunk) end)
          end)

        acc = flush_final(cfg, acc)

        etag = acc.md5 |> :crypto.hash_final() |> Base.encode16(case: :lower)
        sha256 = acc.sha |> :crypto.hash_final() |> Base.encode16(case: :lower)
        shard_len = acc.shard_len || 0

        meta =
          build_meta(cfg, acc.size, etag, sha256, shard_len, Enum.map(acc.block_hashes, &Enum.reverse/1))

        _ = write_sidecars(dirs, meta)
        {:ok, %{size: acc.size}}
      after
        Enum.each(fds, &File.close/1)
      end
    end
  end

  defp do_abort_upload(bucket, _key, upload_id, opts) do
    cfg = Config.load!(opts)
    Enum.each(upload_dirs(bucket, upload_id, cfg), fn dir -> _ = File.rm_rf(dir) end)
    :ok
  end
```

> **注记**：`do_get_part_stream` 复用 `stream_object/9`，传一个合成 key（`"<upload_id>/<part_number>"`）仅用于异常日志上下文（不参与路径，路径已由 `dirs` 给定）。assemble 复用 `feed/3`（对象需 sha256）而非 `feed_part/3`。`@read_chunk`/`__read_chunk__/0` 此时已被 part 流读路径间接覆盖——若仍报未用，executor 可删 `__read_chunk__/0` 与 `@read_chunk`（M6-3 注记已说明其为预留）。

### 步骤 2：共享 backend conformance 套件

新建可被多后端复用的测试宏。新建 `test/support/storage_conformance.ex`：

```elixir
defmodule Maxio.Test.StorageConformance do
  @moduledoc """
  存储后端 behaviour 一致性测试套件（铁律 2：FS 与 ErasureCoded 必须满足同一契约）。
  用法：在具体后端的测试模块里 `use Maxio.Test.StorageConformance, backend: Mod, opts_fun: fun`，
  其中 opts_fun/1 接受 setup 上下文返回该后端的 opts（FS -> [data_dir: dir]；EC -> [drives: ..., ...]）。
  """
  defmacro __using__(_opts) do
    quote do
      @backend Module.get_attribute(__MODULE__, :backend) ||
                 raise("set @backend before `use Maxio.Test.StorageConformance`")

      # opts/1：由具体后端测试定义，接受 ctx（含 setup 产物）返回 backend opts。
      test "put/get round-trip + etag/sha256 over 明文", ctx do
        o = opts(ctx)
        :ok = @backend.put_bucket("b", o)
        body = :crypto.strong_rand_bytes(2500)
        {:ok, r} = @backend.put("b", "k", "null", [body], o)
        assert r.size == byte_size(body)
        assert r.etag == (:crypto.hash(:md5, body) |> Base.encode16(case: :lower))
        assert r.sha256 == (:crypto.hash(:sha256, body) |> Base.encode16(case: :lower))
        {:ok, stream} = @backend.get("b", "k", "null", nil, o)
        assert IO.iodata_to_binary(Enum.to_list(stream)) == body
      end

      test "get Range 含端点", ctx do
        o = opts(ctx)
        :ok = @backend.put_bucket("b", o)
        {:ok, _} = @backend.put("b", "k", "null", ["0123456789"], o)
        {:ok, s} = @backend.get("b", "k", "null", {2, 5}, o)
        assert IO.iodata_to_binary(Enum.to_list(s)) == "2345"
      end

      test "stat / delete / enoent", ctx do
        o = opts(ctx)
        :ok = @backend.put_bucket("b", o)
        {:ok, _} = @backend.put("b", "k", "null", ["abc"], o)
        assert {:ok, %{size: 3}} = @backend.stat("b", "k", "null", o)
        assert :ok = @backend.delete("b", "k", "null", o)
        assert {:error, :enoent} = @backend.stat("b", "k", "null", o)
        assert {:error, :enoent} = @backend.get("b", "k", "null", nil, o)
      end

      test "version 维度物理隔离", ctx do
        o = opts(ctx)
        :ok = @backend.put_bucket("b", o)
        {:ok, _} = @backend.put("b", "k", "null", ["A"], o)
        {:ok, _} = @backend.put("b", "k", "01XYZ", ["B"], o)
        {:ok, s0} = @backend.get("b", "k", "null", nil, o)
        {:ok, s1} = @backend.get("b", "k", "01XYZ", nil, o)
        assert IO.iodata_to_binary(Enum.to_list(s0)) == "A"
        assert IO.iodata_to_binary(Enum.to_list(s1)) == "B"
      end

      test "路径穿越被拒", ctx do
        o = opts(ctx)
        :ok = @backend.put_bucket("b", o)
        assert {:error, :invalid_key} = @backend.put("b", "../x", "null", ["x"], o)
      end

      test "parts: put_part/get_part_stream/assemble/abort", ctx do
        o = opts(ctx)
        :ok = @backend.put_bucket("b", o)
        {:ok, p2} = @backend.put_part("b", "big", "u1", 2, ["DEF"], o)
        {:ok, p1} = @backend.put_part("b", "big", "u1", 1, ["ABC"], o)
        assert p1.size == 3
        assert p1.md5_raw == :crypto.hash(:md5, "ABC")
        assert byte_size(p1.md5_raw) == 16
        assert p2.etag == (:crypto.hash(:md5, "DEF") |> Base.encode16(case: :lower))

        {:ok, ps} = @backend.get_part_stream("b", "big", "u1", 1, o)
        assert IO.iodata_to_binary(Enum.to_list(ps)) == "ABC"

        {:ok, %{size: 6}} = @backend.assemble("b", "big", "u1", [1, 2], o)
        {:ok, obj} = @backend.get("b", "big", "null", nil, o)
        assert IO.iodata_to_binary(Enum.to_list(obj)) == "ABCDEF"

        assert :ok = @backend.abort_upload("b", "big", "u1", o)
        assert {:error, :enoent} = @backend.get_part_stream("b", "big", "u1", 1, o)
        assert :ok = @backend.abort_upload("b", "big", "u1", o)
      end
    end
  end
end
```

> **注记**：`@backend` 与 `opts/1` 由具体后端测试模块提供。`elixirc_paths(:test)` 已含 `test/support`（见 mix.exs），故该 support 文件会被编译。

新建 `test/maxio/storage/fs_conformance_test.exs`（FS 跑同一套契约——证明套件正确 + FS 仍合规）：

```elixir
defmodule Maxio.Storage.FSConformanceTest do
  use ExUnit.Case, async: true
  @backend Maxio.Storage.FS

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_fs_conf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp opts(ctx), do: [data_dir: ctx.dir]

  use Maxio.Test.StorageConformance
end
```

新建 `test/maxio/storage/erasure_coded_conformance_test.exs`：

```elixir
defmodule Maxio.Storage.ErasureCodedConformanceTest do
  use ExUnit.Case, async: true
  @backend Maxio.Storage.ErasureCoded

  setup do
    base = Path.join(System.tmp_dir!(), "maxio_ec_conf_#{System.unique_integer([:positive])}")
    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, drives: drives}
  end

  defp opts(ctx), do: [drives: ctx.drives, data_shards: 4, parity_shards: 2, block_size: 1024]

  use Maxio.Test.StorageConformance
end
```

> **关键**：`use Maxio.Test.StorageConformance` 放在 `opts/1` 与 `@backend` 定义**之后**（宏体内的 `test` 子句引用 `opts/1`/`@backend`，编译期需已可见）。executor 落地时保持此顺序。

运行确认两后端同套契约全绿：

```powershell
mix test test/maxio/storage/fs_conformance_test.exs test/maxio/storage/erasure_coded_conformance_test.exs
```

期望：两文件各 6+ 用例全绿（同一套契约，两后端均满足）。

### 步骤 3：config 切后端能力 + S3 e2e 切片跑纠删码后端

S3 e2e 切片通过在测试内**临时把 `config :maxio, :storage_backend` 切到 ErasureCoded**（并指向临时盘目录），跑既有集成路径的一个子集，证明纠删码后端在真实 S3 管线下可用。

新建 `test/maxio/s3/erasure_e2e_test.exs`：

```elixir
defmodule Maxio.S3.ErasureE2ETest do
  @moduledoc """
  把存储后端 config-select 到 Maxio.Storage.ErasureCoded，跑一片 S3 e2e（经 Endpoint.call/2 自签 SigV4）：
  CreateBucket -> PutObject（流式）-> GetObject 全量 -> Range -> HeadObject -> DeleteObject。
  证明纠删码后端在真实 S3 请求管线下满足同一契约（铁律 2：核心管线一行不改）。
  """
  use Maxio.ConnCase, async: false

  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  setup do
    base = Path.join(System.tmp_dir!(), "maxio_ec_e2e_#{System.unique_integer([:positive])}")
    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)

    prev_backend = Application.get_env(:maxio, :storage_backend)
    prev_ec = Application.get_env(:maxio, :erasure)

    Application.put_env(:maxio, :storage_backend, Maxio.Storage.ErasureCoded)

    Application.put_env(:maxio, :erasure,
      drives: drives,
      data_shards: 4,
      parity_shards: 2,
      block_size: 1024
    )

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, prev_backend)
      if prev_ec, do: Application.put_env(:maxio, :erasure, prev_ec), else: Application.delete_env(:maxio, :erasure)
      File.rm_rf(base)
    end)

    :ok
  end

  test "纠删码后端下 PutObject/GetObject/Range/Head/Delete e2e" do
    bucket = "ecbucket"
    key = "obj.bin"
    body = :crypto.strong_rand_bytes(3000)

    # CreateBucket
    conn = SigV4Request.signed_conn(:put, "/#{bucket}") |> Endpoint.call([])
    assert conn.status in [200, 204]

    # PutObject（单块 UNSIGNED-PAYLOAD 或 single；复用 SigV4Request 默认上传方式）
    conn = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body) |> Endpoint.call([])
    assert conn.status == 200
    etag = conn |> Plug.Conn.get_resp_header("etag") |> List.first()
    assert etag == ~s("#{:crypto.hash(:md5, body) |> Base.encode16(case: :lower)}")

    # GetObject 全量
    conn = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> Endpoint.call([])
    assert conn.status == 200
    assert conn.resp_body == body

    # Range
    conn =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", headers: [{"range", "bytes=1000-1999"}])
      |> Endpoint.call([])

    assert conn.status == 206
    assert conn.resp_body == binary_part(body, 1000, 1000)

    # HeadObject
    conn = SigV4Request.signed_conn(:head, "/#{bucket}/#{key}") |> Endpoint.call([])
    assert conn.status == 200

    # DeleteObject -> 再 Get 404
    conn = SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}") |> Endpoint.call([])
    assert conn.status == 204
    conn = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> Endpoint.call([])
    assert conn.status == 404
  end
end
```

> **VERIFY-AT-IMPL（executor 必做）**：`SigV4Request.signed_conn/2,3` 的确切参数形态（`body:`/`headers:` 选项、返回 `conn`）以既有 `test/support/sigv4_request.ex` 与既有集成测试（`test/maxio/s3/integration_test.exs`）**为准**——executor 落地前**先读这两个文件**，逐字对齐调用形态（包括 PutObject 默认走 single 还是 aws-chunked、ETag 是否带引号、Range 响应头断言）。本测试的断言形态以既有 integration_test 同类用例为模板照抄。若既有 e2e 用 `Maxio.Buckets.create/2` 预建桶元数据，则同样照搬（纠删码只改字节后端，元数据上下文不变）。

运行确认绿：

```powershell
mix test test/maxio/s3/erasure_e2e_test.exs
```

期望：`1 test, 0 failures`（纠删码后端在真实 S3 管线下 Put/Get/Range/Head/Delete 全过）。

### 单元收尾验证（M6-4）

```powershell
mix compile --warnings-as-errors
mix test test/maxio/storage/ test/maxio/native/ test/maxio/s3/erasure_e2e_test.exs
mix test
```

期望：编译零警告；存储/NIF/纠删码 e2e 全绿；**全量回归通过**（既有 412 + M6 新增，FS 仍默认后端不受影响）。提交：

```powershell
git add -A
git commit -m @'
M6-4: ErasureCoded multipart parts (put_part/get_part_stream/assemble/abort_upload, streaming RS per block, md5_raw); shared StorageConformance suite run against BOTH FS and ErasureCoded; config-select backend; S3 e2e slice (CreateBucket/Put/Get/Range/Head/Delete) on erasure backend via Endpoint.call/2

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) parts 全套返回形态对齐 FS（`%{size,etag,md5_raw}`、md5_raw 16 字节明文 MD5）、assemble 后 GET 拼接正确；(2) **共享 conformance 套件同跑 FS 与 ErasureCoded 全绿**（同一契约两后端满足）；(3) config 切 ErasureCoded 后 S3 e2e 切片 Put/Get/Range/Head/Delete 全过；(4) 全量回归绿（FS 默认不受影响）；(5) 零警告。

---


## M6-5 · HEAL / SCRUB + bitrot e2e + 文档收尾（M7 defer 显式化）

**目标**：实现自愈子系统——检测缺失/损坏分片（校验和不匹配或文件缺失），从 K 个存活分片 RS 重建、回写坏分片 + 修复其 sidecar block hash；`mix maxio.heal`（单对象/单桶）+ `mix maxio.scrub`（全盘扫描）CLI（结构化日志可观测，铁律 4）；端到端 bitrot 取证（删/损 ≤ M 分片仍正确 + heal 回写；损 M+1 → 结构化错误，绝不静默返回错数据）；STATUS + README 更新，M7 defer 显式文档化。

**依赖**：M6-4。**规模**：Heal 模块 + 两个 mix 任务 + bitrot e2e + 文档。

### 关键事实与设计（bake-in）

- **检测**：对每个对象（每盘 sidecar 取任一存活副本得 EC 参数 + per-block-per-shard `block_hashes`），逐 block：对每盘 i `pread` 分片 block j、BLAKE3 重算、比对 sidecar 的 `block_hashes[i][j]`。文件缺失/读不到/不匹配 → 该 (盘 i, block j) 为坏分片。
- **重建条件**：某 block 的坏分片数 ≤ M（即存活 ≥ K）→ 可 heal。`Codec.restore_block` 拿到该 block 明文 → `Codec.split_block` 重新编码出全部 N 个分片 → 仅把坏盘的分片字节回写（`pwrite` 到 `j*shard_len`，或缺整文件时重建整列）。
- **整文件重建（新/替换空盘）**：若某盘整列分片文件缺失，heal 对该对象的每个 block 重算该盘分片并顺序写其 part.0 + 重建该盘 sidecar 副本。
- **不可恢复**：某 block 坏分片 > M（存活 < K）→ 结构化 **unrecoverable** 错误日志 + heal 该对象返回 `{:error, :unrecoverable}`（绝不伪造数据，铁律 3）。
- **scrub**：遍历所有盘上所有对象目录（去重——同对象在 N 盘各有目录），对每个对象调 heal；MinIO 式采样（1/1024）M6 不做，scrub 全扫（单机量可控），文档化为 M7 可加采样/限流。
- **MVP 简化（诚实文档化）**：M6 heal 同步、单进程、无并发锁（单机串行）；跨节点 heal 协调/限流 defer M7。heal 粒度到「整对象」（重建该对象所有坏分片），非 MinIO 的 per-block 增量回写优化——正确优先。

### 步骤 1：Heal 核心（TDD）

新建 `test/maxio/storage/erasure/heal_test.exs`：

```elixir
defmodule Maxio.Storage.Erasure.HealTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias Maxio.Storage.ErasureCoded
  alias Maxio.Storage.Erasure.Heal

  setup do
    base = Path.join(System.tmp_dir!(), "maxio_heal_#{System.unique_integer([:positive])}")
    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, drives: drives}
  end

  defp opts(drives), do: [drives: drives, data_shards: 4, parity_shards: 2, block_size: 1024]

  defp part_path(drive, bucket, key), do: Path.join([drive, bucket, key, "part.0"])

  test "heal 重建被删除的 1 个分片文件（整列缺失）", %{drives: drives} do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], o)

    # 删掉盘 0 的对象目录（整列分片 + sidecar 缺失）
    File.rm_rf!(Path.join([Enum.at(drives, 0), "b", "k"]))
    refute File.exists?(part_path(Enum.at(drives, 0), "b", "k"))

    assert {:ok, %{healed: healed}} = Heal.heal_object("b", "k", "null", o)
    assert healed >= 1
    # 盘 0 分片文件 + sidecar 已回写
    assert File.exists?(part_path(Enum.at(drives, 0), "b", "k"))
    assert File.exists?(Path.join([Enum.at(drives, 0), "b", "k", "meta.json"]))

    # heal 后 GET 仍正确
    {:ok, stream} = ErasureCoded.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  test "heal 修复被篡改的分片（bitrot）", %{drives: drives} do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], o)

    # 篡改盘 1 的 part.0 首字节
    p = part_path(Enum.at(drives, 1), "b", "k")
    <<first, rest::binary>> = File.read!(p)
    File.write!(p, <<bxor(first, 0xFF), rest::binary>>)

    assert {:ok, %{healed: healed}} = Heal.heal_object("b", "k", "null", o)
    assert healed >= 1
    # 篡改已被修正（重算校验和匹配）
    {:ok, stream} = ErasureCoded.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  test "损坏 M+1 个分片 -> heal 返回 :unrecoverable（不伪造数据）", %{drives: drives} do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)
    body = :crypto.strong_rand_bytes(1000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], o)

    # 删 3 个盘（M=2，存活 3 < K=4）
    Enum.each([0, 1, 2], fn i -> File.rm_rf!(Path.join([Enum.at(drives, i), "b", "k"])) end)

    assert {:error, :unrecoverable} = Heal.heal_object("b", "k", "null", o)
  end

  test "无损对象 heal 为 no-op（healed=0）", %{drives: drives} do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [:crypto.strong_rand_bytes(2000)], o)
    assert {:ok, %{healed: 0}} = Heal.heal_object("b", "k", "null", o)
  end

  test "scrub_bucket 扫描并 heal 桶内全部对象", %{drives: drives} do
    o = opts(drives)
    :ok = ErasureCoded.put_bucket("b", o)
    {:ok, _} = ErasureCoded.put("b", "k1", "null", [:crypto.strong_rand_bytes(2000)], o)
    {:ok, _} = ErasureCoded.put("b", "a/k2", "null", [:crypto.strong_rand_bytes(2000)], o)
    File.rm_rf!(Path.join([Enum.at(drives, 0), "b", "k1"]))

    assert {:ok, %{scanned: scanned, healed_objects: healed}} = Heal.scrub_bucket("b", o)
    assert scanned >= 2
    assert healed >= 1
  end
end
```

运行确认红。新建 `lib/maxio/storage/erasure/heal.ex`：

```elixir
defmodule Maxio.Storage.Erasure.Heal do
  @moduledoc """
  纠删码自愈：检测缺失/损坏分片（校验和不匹配或文件缺失），从 K 个存活分片 RS 重建、回写坏分片 +
  修复其 sidecar 副本。坏分片数 > M（存活 < K）-> 不可恢复，返回 {:error, :unrecoverable} +
  结构化错误日志（铁律 3：绝不伪造数据）。结构化日志含 bucket/key/version_id/drive/block/result（铁律 4）。

  heal 粒度到整对象（重建该对象所有坏分片）；scrub 全扫桶/全盘（MinIO 式 1/1024 采样 + 限流 defer M7）。
  """
  require Logger

  alias Maxio.Storage.Erasure.{Codec, Config, Meta}

  @part_file "part.0"
  @meta_file "meta.json"

  @doc """
  heal 单个对象版本：检测+重建坏分片。返回 {:ok, %{healed: n}}（n=回写的坏分片数）或
  {:error, :unrecoverable}（某 block 存活 < K）/ {:error, :enoent}（无任何 sidecar）。
  """
  @spec heal_object(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{healed: non_neg_integer()}} | {:error, :unrecoverable | :enoent}
  def heal_object(bucket, key, version_id \\ "null", opts \\ []) do
    cfg = Config.load!(opts)
    dirs = object_dirs(bucket, key, version_id, cfg)

    case read_any_sidecar(dirs) do
      {:error, :enoent} ->
        {:error, :enoent}

      {:ok, meta} ->
        do_heal(cfg, bucket, key, version_id, dirs, meta)
    end
  end

  defp do_heal(cfg, bucket, key, version_id, dirs, meta) do
    n = Config.total(cfg)
    size = meta["size"]
    block_size = get_in(meta, ["ec", "block_size"]) || cfg.block_size
    shard_len = block_shard_len(meta, cfg)
    num_blocks = if size == 0, do: 0, else: div(size + block_size - 1, block_size)

    # 打开各盘 part.0 读句柄（缺失 -> nil）。
    read_fds =
      Enum.map(dirs, fn dir ->
        case :file.open(String.to_charlist(Path.join(dir, @part_file)), [:read, :binary, :raw]) do
          {:ok, fd} -> fd
          {:error, _} -> nil
        end
      end)

    try do
      # 逐 block 收集每盘是否需修复的分片字节。
      result =
        Enum.reduce_while(0..max(num_blocks - 1, 0), {:ok, %{}}, fn j, {:ok, fixes} ->
          heal_block(cfg, bucket, key, version_id, meta, read_fds, n, size, block_size, shard_len, j, fixes, num_blocks)
        end)

      case result do
        {:error, :unrecoverable} ->
          Logger.error("erasure heal unrecoverable",
            bucket: bucket,
            key: key,
            reason: "block survivors < K"
          )

          {:error, :unrecoverable}

        {:ok, fixes} ->
          healed = apply_fixes(cfg, dirs, meta, shard_len, fixes)
          {:ok, %{healed: healed}}
      end
    after
      Enum.each(read_fds, fn fd -> if fd, do: :file.close(fd) end)
    end
  end

  # fixes: %{drive_index => %{block_index => shard_bytes}}（需回写的分片）。
  defp heal_block(cfg, bucket, key, version_id, meta, read_fds, n, size, block_size, shard_len, j, fixes, _num_blocks) do
    shards_meta = meta["shards"]

    read_shards =
      Enum.with_index(read_fds)
      |> Enum.map(fn {fd, i} -> read_shard(fd, j, shard_len, shards_meta, i) end)

    checksums = block_checksums(shards_meta, n, j)

    # 哪些盘的分片坏了（校验不过）。
    bad =
      0..(n - 1)
      |> Enum.filter(fn i ->
        not Codec.verify_shard(Enum.at(read_shards, i), Enum.at(checksums, i))
      end)

    cond do
      bad == [] ->
        {:cont, {:ok, fixes}}

      length(bad) > cfg.parity_shards ->
        Logger.error("erasure heal block unrecoverable",
          bucket: bucket,
          key: key,
          reason: "block=#{j} bad=#{length(bad)} > M=#{cfg.parity_shards}"
        )

        {:halt, {:error, :unrecoverable}}

      true ->
        block_plain_len = block_plain_len(size, block_size, j)

        plain =
          Codec.restore_block(cfg, read_shards, checksums, block_plain_len,
            bucket: bucket,
            key: key,
            version_id: version_id,
            block_index: j
          )

        %{shards: good_shards} = Codec.split_block(cfg, plain)

        fixes =
          Enum.reduce(bad, fixes, fn i, acc ->
            shard = Enum.at(good_shards, i)
            drive_map = Map.get(acc, i, %{})
            Map.put(acc, i, Map.put(drive_map, j, shard))
          end)

        Logger.info("erasure heal block repaired",
          bucket: bucket,
          key: key,
          reason: "block=#{j} repaired_drives=#{inspect(bad)}"
        )

        {:cont, {:ok, fixes}}
    end
  end

  # 把 fixes 回写到各盘 part.0（缺整文件先重建整列），并重写该盘 sidecar 副本。返回回写分片数。
  defp apply_fixes(cfg, dirs, meta, shard_len, fixes) do
    bin = Meta.encode(meta)

    Enum.reduce(fixes, 0, fn {drive_index, block_map}, count ->
      dir = Enum.at(dirs, drive_index)
      File.mkdir_p!(dir)
      part = Path.join(dir, @part_file)

      # 整列缺失时先确保文件存在且达 shard_file_size（用 0 占位，随后 pwrite 覆盖）。
      ensure_part_file!(part, meta, drive_index, shard_len)

      {:ok, fd} = :file.open(String.to_charlist(part), [:read, :write, :binary, :raw])

      try do
        Enum.each(block_map, fn {j, shard} ->
          :ok = :file.pwrite(fd, j * shard_len, shard)
        end)
      after
        :file.close(fd)
      end

      # 修复该盘 sidecar 副本（用 leader sidecar 内容，保证全盘一致）。
      File.write!(Path.join(dir, @meta_file), bin)
      count + map_size(block_map)
    end)
  end

  # 确保 part.0 存在且长度 = 该盘 shard_file_size（缺则补零，便于 pwrite 各 block 偏移）。
  defp ensure_part_file!(part, meta, drive_index, shard_len) do
    drive_meta = Enum.at(meta["shards"], drive_index)
    target = (drive_meta && drive_meta["shard_file_size"]) || 0
    target = if target > 0, do: target, else: length((drive_meta && drive_meta["block_hashes"]) || []) * shard_len

    cur =
      case File.stat(part) do
        {:ok, %File.Stat{size: s}} -> s
        {:error, _} -> 0
      end

    cond do
      cur == target ->
        :ok

      true ->
        # 写到目标长度（截断或补零）。
        {:ok, fd} = :file.open(String.to_charlist(part), [:write, :binary, :raw])

        try do
          if target > 0, do: :ok = :file.pwrite(fd, target - 1, <<0>>)
        after
          :file.close(fd)
        end
    end
  end

  @doc """
  scrub 整桶：遍历桶内全部对象（去重 N 盘副本），逐个 heal。
  返回 {:ok, %{scanned, healed_objects, unrecoverable}}。
  """
  @spec scrub_bucket(String.t(), keyword()) ::
          {:ok, %{scanned: non_neg_integer(), healed_objects: non_neg_integer(), unrecoverable: non_neg_integer()}}
  def scrub_bucket(bucket, opts \\ []) do
    cfg = Config.load!(opts)
    objects = list_objects(cfg, bucket)

    {scanned, healed, unrec} =
      Enum.reduce(objects, {0, 0, 0}, fn {key, version_id}, {sc, hl, ur} ->
        case heal_object(bucket, key, version_id, opts) do
          {:ok, %{healed: n}} when n > 0 -> {sc + 1, hl + 1, ur}
          {:ok, _} -> {sc + 1, hl, ur}
          {:error, :unrecoverable} -> {sc + 1, hl, ur + 1}
          {:error, :enoent} -> {sc + 1, hl, ur}
        end
      end)

    Logger.info("erasure scrub bucket done",
      bucket: bucket,
      reason: "scanned=#{scanned} healed=#{healed} unrecoverable=#{unrec}"
    )

    {:ok, %{scanned: scanned, healed_objects: healed, unrecoverable: unrec}}
  end

  @doc "scrub 全部盘上全部桶。"
  @spec scrub_all(keyword()) :: {:ok, map()}
  def scrub_all(opts \\ []) do
    cfg = Config.load!(opts)

    buckets =
      cfg.drives
      |> Enum.flat_map(fn d ->
        case File.ls(d) do
          {:ok, entries} -> entries
          {:error, _} -> []
        end
      end)
      |> Enum.reject(&(&1 == ".uploads"))
      |> Enum.uniq()

    results = Enum.map(buckets, fn b -> {b, scrub_bucket(b, opts)} end)
    {:ok, %{buckets: results}}
  end

  # 列桶内对象 {key, version_id}（扫描所有盘并集，去重）。识别含 meta.json 的目录为对象。
  defp list_objects(cfg, bucket) do
    cfg.drives
    |> Enum.flat_map(fn d ->
      null_objs = scan_dir_for_objects(Path.join(d, bucket), [], "null")
      versions_root = Path.join([d, ".versions", bucket])
      ver_objs = scan_versioned(versions_root)
      null_objs ++ ver_objs
    end)
    |> Enum.uniq()
  end

  # 递归找含 meta.json 的目录；返回 {key, "null"}（key = 相对 bucket 根的路径）。
  defp scan_dir_for_objects(root, _acc, _vid) do
    if File.dir?(root) do
      do_scan(root, root, "null")
    else
      []
    end
  end

  defp do_scan(base, dir, vid) do
    entries =
      case File.ls(dir) do
        {:ok, es} -> es
        {:error, _} -> []
      end

    if @meta_file in entries do
      key = Path.relative_to(dir, base) |> to_unix()
      [{key, vid}]
    else
      Enum.flat_map(entries, fn e ->
        sub = Path.join(dir, e)
        if File.dir?(sub), do: do_scan(base, sub, vid), else: []
      end)
    end
  end

  # 版本化对象：.versions/<bucket>/<key...>/<version_id> 目录含 meta.json。
  defp scan_versioned(root) do
    if File.dir?(root) do
      do_scan_versioned(root, root)
    else
      []
    end
  end

  defp do_scan_versioned(base, dir) do
    entries =
      case File.ls(dir) do
        {:ok, es} -> es
        {:error, _} -> []
      end

    if @meta_file in entries do
      rel = Path.relative_to(dir, base) |> to_unix()
      # rel 形如 "<key...>/<version_id>"；拆出末段为 version_id。
      segs = String.split(rel, "/")
      {key_segs, [vid]} = Enum.split(segs, length(segs) - 1)
      [{Enum.join(key_segs, "/"), vid}]
    else
      Enum.flat_map(entries, fn e ->
        sub = Path.join(dir, e)
        if File.dir?(sub), do: do_scan_versioned(base, sub), else: []
      end)
    end
  end

  defp to_unix(path), do: String.replace(path, "\\", "/")

  # ── 与 ErasureCoded 私有逻辑等价的本地辅助（heal 独立模块，避免暴露后端私有）──

  defp object_dirs(bucket, key, version_id, cfg) do
    {:ok, rel} = safe_relative(key)

    sub =
      if version_id == "null",
        do: Path.join([bucket, rel]),
        else: Path.join([".versions", bucket, rel, version_id])

    Enum.map(cfg.drives, &Path.join(&1, sub))
  end

  defp safe_relative(key) do
    segments = key |> String.split("/", trim: true)
    if key == "" or Enum.any?(segments, &(&1 in ["..", "."])), do: :error, else: {:ok, Path.join(segments)}
  end

  defp read_any_sidecar(dirs) do
    Enum.find_value(dirs, {:error, :enoent}, fn dir ->
      case File.read(Path.join(dir, @meta_file)) do
        {:ok, bin} -> {:ok, Meta.decode!(bin)}
        {:error, _} -> nil
      end
    end)
  end

  defp read_shard(nil, _j, _shard_len, _shards_meta, _i), do: nil

  defp read_shard(fd, j, shard_len, shards_meta, i) do
    drive_meta = Enum.at(shards_meta, i)

    if drive_meta && j < length(drive_meta["block_hashes"]) do
      case :file.pread(fd, j * shard_len, shard_len) do
        {:ok, data} when byte_size(data) == shard_len -> data
        _ -> nil
      end
    else
      nil
    end
  end

  defp block_checksums(shards_meta, n, j) do
    for i <- 0..(n - 1) do
      drive_meta = Enum.at(shards_meta, i)
      hex = drive_meta && Enum.at(drive_meta["block_hashes"], j)

      case hex && Base.decode16(hex, case: :lower) do
        {:ok, raw} -> raw
        _ -> <<0::256>>
      end
    end
  end

  defp block_shard_len(meta, cfg) do
    block_size = get_in(meta, ["ec", "block_size"]) || cfg.block_size

    meta["shards"]
    |> Enum.find_value(fn s ->
      bh = s["block_hashes"]
      if is_list(bh) and length(bh) > 0 and s["shard_file_size"] > 0, do: div(s["shard_file_size"], length(bh))
    end) || div(block_size + cfg.data_shards - 1, cfg.data_shards)
  end

  defp block_plain_len(size, block_size, j) do
    num_blocks = div(size + block_size - 1, block_size)

    cond do
      num_blocks == 0 -> 0
      j < num_blocks - 1 -> block_size
      true -> size - (num_blocks - 1) * block_size
    end
  end
end
```

> **实现注记（executor 必读）**：
> - Heal 复用 Codec 的 `restore_block`/`split_block`/`verify_shard` 与 sidecar 读法；为避免暴露 ErasureCoded 私有函数，Heal 内**重声明等价的 `object_dirs`/`read_shard`/`block_checksums`/`block_shard_len`/`block_plain_len` 本地辅助**（与 ErasureCoded 逻辑逐字一致）。这不是「打补丁式重复」——两模块对同一盘上格式各持只读/读写视角，是清晰的关注点分离；若 reviewer 要求去重，executor 可把这些纯函数抽到 `Maxio.Storage.Erasure.Layout` 共享模块（M6-5 可选优化，不阻塞）。
> - `apply_fixes` 用 `:file.pwrite` 精确回写坏 block 偏移；整列缺失时 `ensure_part_file!` 先把 part.0 补到目标长度再 pwrite。

运行确认绿：

```powershell
mix test test/maxio/storage/erasure/heal_test.exs
```

期望：`5 tests, 0 failures`（重建整列 / 修篡改 / 不可恢复 / no-op / scrub）。

### 步骤 2：mix maxio.heal + mix maxio.scrub CLI

新建 `lib/mix/tasks/maxio.heal.ex`：

```elixir
defmodule Mix.Tasks.Maxio.Heal do
  @shortdoc "纠删码自愈：重建单个对象（或单桶）的缺失/损坏分片"
  @moduledoc """
  纠删码自愈 CLI（铁律 4：后端功能 CLI 可观测）。

      mix maxio.heal <bucket> <key> [version_id]   # heal 单个对象（version_id 缺省 "null"）
      mix maxio.heal <bucket>                       # scrub 整桶

  从 K 个存活分片 RS 重建坏分片并回写；某 block 存活 < K -> 打印 unrecoverable（绝不伪造数据）。
  EC 参数取 config :maxio, :erasure。
  """
  use Mix.Task

  alias Maxio.Storage.Erasure.Heal

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [bucket, key | rest] ->
        version_id = List.first(rest) || "null"

        case Heal.heal_object(bucket, key, version_id) do
          {:ok, %{healed: n}} ->
            IO.puts("[maxio heal] #{bucket}/#{key}@#{version_id}: healed #{n} shard(s)")

          {:error, :unrecoverable} ->
            IO.puts("[maxio heal] #{bucket}/#{key}@#{version_id}: UNRECOVERABLE (survivors < K) — data NOT fabricated")

          {:error, :enoent} ->
            IO.puts("[maxio heal] #{bucket}/#{key}@#{version_id}: no sidecar found (object missing)")
        end

      [bucket] ->
        {:ok, %{scanned: sc, healed_objects: hl, unrecoverable: ur}} = Heal.scrub_bucket(bucket)
        IO.puts("[maxio heal] bucket #{bucket}: scanned=#{sc} healed=#{hl} unrecoverable=#{ur}")

      _ ->
        IO.puts("usage: mix maxio.heal <bucket> [<key> [version_id]]")
    end
  end
end
```

新建 `lib/mix/tasks/maxio.scrub.ex`：

```elixir
defmodule Mix.Tasks.Maxio.Scrub do
  @shortdoc "纠删码全盘巡检：扫描所有桶/对象，检测并自愈坏分片"
  @moduledoc """
  纠删码 scrub CLI（全盘巡检 + 自愈，铁律 4 可观测）。

      mix maxio.scrub             # 扫描所有盘上所有桶的全部对象，逐个 heal
      mix maxio.scrub <bucket>    # 仅扫描指定桶

  M6 全扫（单机量可控）；MinIO 式 1/1024 采样 + 限流 defer M7（见 README）。
  EC 参数取 config :maxio, :erasure。
  """
  use Mix.Task

  alias Maxio.Storage.Erasure.Heal

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [bucket] ->
        {:ok, %{scanned: sc, healed_objects: hl, unrecoverable: ur}} = Heal.scrub_bucket(bucket)
        IO.puts("[maxio scrub] bucket #{bucket}: scanned=#{sc} healed=#{hl} unrecoverable=#{ur}")

      [] ->
        {:ok, %{buckets: results}} = Heal.scrub_all()

        Enum.each(results, fn {b, {:ok, %{scanned: sc, healed_objects: hl, unrecoverable: ur}}} ->
          IO.puts("[maxio scrub] bucket #{b}: scanned=#{sc} healed=#{hl} unrecoverable=#{ur}")
        end)

      _ ->
        IO.puts("usage: mix maxio.scrub [<bucket>]")
    end
  end
end
```

### 步骤 3：bitrot e2e（端到端取证）

新建 `test/maxio/storage/erasure/bitrot_e2e_test.exs`：

```elixir
defmodule Maxio.Storage.Erasure.BitrotE2ETest do
  @moduledoc """
  bitrot 端到端取证（铁律 3）：写对象 -> 删/损坏 ≤ M 个分片 -> GET 仍返回正确字节（decode-on-read）；
  heal 回写恢复全冗余；删 M+1 个分片 -> GET raise（结构化错误，绝不静默返回错数据）。
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias Maxio.Storage.ErasureCoded
  alias Maxio.Storage.Erasure.{Heal, InsufficientShardsError}

  setup do
    base = Path.join(System.tmp_dir!(), "maxio_bitrot_#{System.unique_integer([:positive])}")
    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, drives: drives}
  end

  defp o(drives), do: [drives: drives, data_shards: 4, parity_shards: 2, block_size: 1024]
  defp part(drive, b, k), do: Path.join([drive, b, k, "part.0"])

  test "删 M 个分片 GET 仍正确，heal 后冗余恢复", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", o(drives))
    body = :crypto.strong_rand_bytes(5000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], o(drives))

    # 删 2 个盘（M=2）
    Enum.each([0, 5], fn i -> File.rm_rf!(Path.join([Enum.at(drives, i), "b", "k"])) end)

    {:ok, stream} = ErasureCoded.get("b", "k", "null", nil, o(drives))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body

    {:ok, %{healed: n}} = Heal.heal_object("b", "k", "null", o(drives))
    assert n >= 1
    assert File.exists?(part(Enum.at(drives, 0), "b", "k"))
  end

  test "篡改 M 个分片 GET 仍正确（校验和检测+重建）", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", o(drives))
    body = :crypto.strong_rand_bytes(5000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], o(drives))

    Enum.each([1, 2], fn i ->
      p = part(Enum.at(drives, i), "b", "k")
      <<first, rest::binary>> = File.read!(p)
      File.write!(p, <<bxor(first, 0xFF), rest::binary>>)
    end)

    {:ok, stream} = ErasureCoded.get("b", "k", "null", nil, o(drives))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  test "删 M+1 个分片 GET raise（结构化错误，绝不静默错数据）", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", o(drives))
    body = :crypto.strong_rand_bytes(5000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], o(drives))

    Enum.each([0, 1, 2], fn i -> File.rm_rf!(Path.join([Enum.at(drives, i), "b", "k"])) end)

    assert_raise InsufficientShardsError, fn ->
      {:ok, stream} = ErasureCoded.get("b", "k", "null", nil, o(drives))
      IO.iodata_to_binary(Enum.to_list(stream))
    end
  end
end
```

> **注**：删 M+1 时仍有 3 个盘留 sidecar（K=4 个数据盘里删了 0/1/2，盘 3 + 校验盘 4/5 留存），故 `get` 入口的 `read_any_sidecar` 成功返回流；流在 `restore_block` 处因存活 3 < K=4 raise `InsufficientShardsError`。这正是「绝不静默」的取证点。

运行确认绿：

```powershell
mix test test/maxio/storage/erasure/bitrot_e2e_test.exs
```

期望：`3 tests, 0 failures`。

### 步骤 4：STATUS + README 更新（M7 defer 显式文档化）

更新 `docs/superpowers/STATUS.md`：把里程碑表 M6 行状态改为已实现并验证，并追加「M6 实现摘要」+「M6 已知非阻塞项 / M7 显式 defer」两节（照搬 M4/M5 摘要的格式与详尽度）。M6 摘要须列：M6-1 NIF crate（reed-solomon-simd + blake3 + rustler 0.38，镜像 huanxi）；M6-2 Codec/Config（quorum、bitrot 校验和、InsufficientShardsError）；M6-3 ErasureCoded put/get/stat/delete + bucket（流式逐块、sidecar、write/read quorum）；M6-4 parts + 共享 conformance + config 切后端 + S3 e2e 切片；M6-5 heal/scrub + bitrot e2e。

更新 `README.md`：新增「Erasure Coding (M6, single-node multi-drive)」章节，说明：config 切后端方式（`config :maxio, :storage_backend, Maxio.Storage.ErasureCoded` + `config :maxio, :erasure, drives/data_shards/parity_shards/block_size`）；EC:M 记法与 quorum（read=K、write=K 或 K+1）；bitrot 检测（per-shard BLAKE3 sidecar）+ heal/scrub CLI（`mix maxio.heal` / `mix maxio.scrub`）；**M7 显式 defer 清单**（多节点分布 / 多 erasure set + 对象→set 路由 / server pools + rebalance / 跨节点 quorum + 脑裂 / 分布式锁 / 拓扑感知 + 跨节点 heal 协调 + 限流 / 存储类多 parity / inline 小对象）——逐条列出，绝不静默。

### 单元收尾验证（M6-5）

```powershell
mix compile --warnings-as-errors
mix test
```

期望：编译零警告；**全量回归全绿**（既有 412 + M6 全部新增）。提交：

```powershell
git add -A
git commit -m @'
M6-5: erasure heal/scrub — Heal.heal_object (detect missing/corrupt shard via BLAKE3, RS-reconstruct, pwrite repair + sidecar fix; survivors<K -> :unrecoverable, never fabricate) + scrub_bucket/scrub_all; mix maxio.heal / mix maxio.scrub CLI (structured logs); bitrot e2e (lose/corrupt <=M still correct + heal; M+1 -> InsufficientShardsError); STATUS + README (M7 defer documented)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（独立 verifier）**：(1) heal 重建被删整列分片 + 修篡改分片，heal 后 GET 正确；(2) 损 M+1 → `{:error, :unrecoverable}`（不伪造数据）；(3) `mix maxio.heal`/`mix maxio.scrub` CLI 可跑、结构化日志含 bucket/key/drive/block/result；(4) bitrot e2e：删/篡改 ≤M 仍正确 + heal 回写；删 M+1 GET raise `InsufficientShardsError`（绝不静默）；(5) STATUS/README 更新含 M7 defer 完整清单；(6) 全量回归绿、零警告。

---

## 完成判据（M6 整体，独立 verifier + code-reviewer 取证）

- 零待办；`mix compile --warnings-as-errors` 零警告；`mix test` 全量绿（既有 412 + M6 新增，FS 默认后端不受影响）。
- **铁律 2**：`Maxio.Storage`（facade）/`Maxio.Storage.Backend`（behaviour）/`Maxio.Storage.FS`/所有 handler/dispatcher/endpoint **一行未改**（git diff 仅含 native/ 新增 + lib/maxio/storage/erasure* + lib/maxio/native/ + lib/mix/tasks/maxio.{heal,scrub} + config 追加 + mix.exs dep + 测试 + 文档）。共享 conformance 套件证明 FS 与 ErasureCoded 满足同一契约。
- **铁律 4**：PUT/GET 流式逐块（内存 ≈ block × N），无整对象缓冲；NIF 按块调用有界。
- **铁律 3**：bitrot/不足分片/未达 write quorum → 结构化异常 + 结构化日志，绝不静默；M7 deferral 在 STATUS + README 逐条显式列出。
- CLI 可观测：`mix maxio.heal` / `mix maxio.scrub` + 结构化日志取证。
- 独立 reviewer/verifier 终审（实现者不自审）。

## M7 显式 defer 清单（文档化，绝不静默丢弃）

1. **真正多节点分布**：分片 I/O 跨主机（RPC 替本地 `:file`）。M6 的「N 盘 = N 目录」与分布式 set 数学相同，M7 只换 transport。
2. **多 erasure set + 对象→set 路由**（对象名 hash）；**server pools** + pool 路由；扩容/rebalance。
3. **跨节点读写 quorum**（含网络分区下 `K==M` 的 K+1 脑裂规则——M6 单机已实现并强制 quorum 返回值，分区语义 defer）。
4. **分布式锁**（跨节点对象级锁，并发 PUT/heal 安全）。
5. **拓扑感知路由 / 跨节点 heal 协调 / heal 限流 / failure-domain 感知分片放置**；MinIO 式 1/1024 scrub 采样。
6. **存储类多 parity**（`x-amz-storage-class` → STANDARD/RRS 不同 EC:M）。
7. **inline 小对象**（< 128 KiB 直接进 sidecar 省 part 文件）。

**设计保证**：M7 在 M6 同一 RS 编解码/heal 核心**之外**加 routing/locking/pools/transport 层，不重写引擎。

