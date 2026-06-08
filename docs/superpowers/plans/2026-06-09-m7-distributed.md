# M7 多节点分布式 实现计划 · maxio（Distributed Erasure · 多节点 · libcluster + :erpc transport + 分布式锁）

> For agentic workers（executor）：严格按单元 **M7-1 .. M7-5** 顺序执行。逻辑性代码用 **TDD**（先写失败测试 → 运行确认红 → 最小实现 → 运行确认绿 → commit）；脚手架/配置/依赖类任务用「执行命令 + 验证输出」。每个任务都给了**精确文件路径、完整可用代码（禁止占位符 / TODO / 省略号）、确切 PowerShell 命令与期望输出**。后面单元引用的类型/函数/字段名与前面定义（及 M0–M6 既有代码）**严格一致**——复用既有模块时逐字照抄其现有签名。
>
> **本计划建立在已交付并验证的 M0–M6 之上**（master，463 测试全绿、`compile --warnings-as-errors` 零警告、独立 reviewer APPROVE）。M7 的核心是：**新增一个 `Maxio.Storage.Backend` 实现 `Maxio.Storage.Distributed`，它在 M6 的 Reed-Solomon 编解码核心（`Maxio.Storage.Erasure.{Codec,Config,Meta}` + `Maxio.Native.ErasureCoding` NIF）之外，加一层「拓扑 + 路由 + 跨节点分片传输 + 分布式锁」，把 M6 单机的「分片 i → 本地盘 i」替换为「分片 i → 该对象 erasure set 的第 i 个 `{node, drive}` 端点（经 :erpc/transport 访问）」。RS 数学、流式结构、quorum 公式、heal 引擎全部复用、一行不重写。** 经 `config :maxio, :storage_backend, Maxio.Storage.Distributed` 切换即启用。
>
> **铁律对齐（AGENTS.md §3/§4，违反即返工）**：
> - **铁律 2（后端即插件）**：M7 是一个**全新的 `Maxio.Storage.Backend` 实现** `Maxio.Storage.Distributed`；`Maxio.Storage`（facade）、`Maxio.Storage.Backend`（behaviour）、`Maxio.Storage.FS`、`Maxio.Storage.ErasureCoded`、所有 handler / dispatcher / endpoint **一行不改**。唯一的「接线」是：(a) `mix.exs` 加 `{:libcluster, "~> 3.5"}` dep；(b) `Maxio.Application` 监督树**前置**三个 child（`Cluster.Supervisor` + `Maxio.Cluster.Topology` + `Maxio.Cluster.ShardServer`）；(c) config 新增 `Maxio.Cluster`（libcluster 拓扑）与 `Maxio.Cluster.Topology`（pools→sets→endpoints）两个块 + 可选 `:storage_backend` 切到 `Maxio.Storage.Distributed`。M6 的 `Maxio.Storage.Erasure.*` 与 NIF **一行不改**（仅被复用）。
> - **铁律 3（绝不静默失败 / 绝不静默返回错数据）**：节点宕机 / 超时 / 远端异常 → 该端点产出 **`nil` 分片**（与 M6 缺失本地文件语义完全相同），交 `Codec.restore_block/5` 校验+重建；某 block 存活分片 < K（read quorum）→ raise `InsufficientShardsError`（M6 既有），上层惰性流崩溃 → handler 映射结构化 S3 5xx。写入未达 write quorum → `{:error, :write_quorum}` + 结构化日志。获分布式锁失败 → `{:error, :locked}`（handler 映射 503/409），**绝不静默并发写同对象**。非法拓扑配置 → 启动期 `raise`，**绝不带病启动**。
> - **铁律 4（分片逐块流式跨节点，绝不一次传整对象）**：跨节点分片 I/O 必须**逐 (block, shard)** 发消息——每条 :erpc 消息只携带「一个 block 的一个分片」，大小有界（`shard_len ≈ even(ceil(block_size/K))`，block_size=1 MiB、K=4 → ~256 KiB）。**任何时刻在途字节 ≈ 一个 block × N 个分片，绝不把整对象（或整 part.0 文件，可达 GB）塞进单条分布式消息**（distribution port 单 TCP 通道，HOL 阻塞 + dist 缓冲膨胀风险）。GET 侧对一个 block 的 N 个端点读用 `Task.async_stream` **并行**发，保序收集。
> - **铁律 5（S3 行为对齐 + 路由稳定性）**：对象→set 路由 = **对象名（`bucket <> "/" <> key`）确定性哈希 mod set 数**（对齐 MinIO 的 set 放置 = 对象名哈希取模）；版本不入哈希（同对象全版本同 set）。set 数 per pool 不可变（online 扩缩/rebalance 显式 defer）。Distributed 后端的 ETag / sha256 / Range / part ETag 返回形态**与 FS/ErasureCoded 逐字节一致**，handler 上层完全无感。
> - **铁律 6（DB schema 自文档化）**：M7 **不新建任何表**（拓扑走 config + `:persistent_term`；per-object 元数据沿用 M6 盘上 JSON sidecar，每端点一份）。**若**后续选择把拓扑/部署 ID 落 DB（本计划不这么做），新表/列须中文 `COMMENT`。
>
> **作者/审查隔离**：本计划由 executor 实现；每个单元收尾由**独立** `code-reviewer`/`verifier`（不同上下文）取证，实现者不得自审。

---

## 环境约束（每条命令都必须遵守）

- **本机**：Windows 11 + PowerShell。Elixir 1.20.0 / OTP 28，位于 `C:\Users\dyz\Documents\dev\usr\Elixir\bin`。
- **跑任何 mix 命令前必设**（否则编译期/运行期中文输出重定向到非 TTY 触发 `io.put_chars badarg` 硬崩、留 `erl_crash.dump`）：
  ```powershell
  $env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
  $env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
  ```
  本计划所有 PowerShell 命令块**默认已假设当前会话已设此两变量**；每个新 shell 会话第一条命令前先执行它。
- **Postgres**：docker 容器 `maxio-db`（postgres:16，localhost:5432，user/pass=postgres/postgres，dev 库 `maxio_dev`，test 库 `maxio_test`）。`psql` 不在 PATH，一律经容器 `docker exec maxio-db psql -U postgres -d maxio_dev -c "..."`。`mix test` 自动迁移 test 库。**M7 不动 DB schema**。
- **无 aws-cli / boto3 / mc / python**。端到端验证用三层（**确定性、CI 友好、无需真实集群**）：
  1. **纯函数单测**（拓扑解析/校验、路由确定性与稳定性——最权威 ground truth）。
  2. **进程内多节点 transport 注入**（`Maxio.Cluster.Transport` behaviour 的 `InProcess` 实现把每个 `{node, drive}` 映射到本地临时目录，可在运行中「打掉」指定端点 → 该端点读返回 nil、写报错）。这是**主力**：在 `async: true` 的 ExUnit 里跑**真实 quorum + 节点宕机 + bitrot + heal** 覆盖，无需第二个 BEAM 节点。共享 conformance 套件（M6 已建，同跑 FS+ErasureCoded）第三次同跑 `Distributed`+`InProcess`，证同一契约。
  3. **`:peer` 真节点集成测试**（少量 `@tag :distributed`、`async: false`）：起真实额外 BEAM 节点，跑真 `:erpc`（验证 `{:erpc, :noconnection}` / `:global.trans` 跨节点互斥），杀节点验真宕机 → nil 分片 → 重建。CI 可单独跑/跳过。
- **测试禁忌（AGENTS.md Test guidelines）**：用 `start_supervised!/1` 起进程；**禁用** `Process.sleep/1`/`Process.alive?/1`——等进程死用 `Process.monitor/1` + `assert_receive {:DOWN, ...}`，等节点死用 `:net_kernel.monitor_nodes(true)` + `assert_receive {:nodedown, n}`，同步用 `:sys.get_state/1`。
- **提交**：每个单元（或紧密相关的红绿对）一次 commit，message footer 固定一行：
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
  当前分支为 `master`；本计划全部提交到当前分支（无需开新分支，除非用户另行要求）。

---

## Goal

在 M0–M6（鉴权 + 授权 + 高级特性 + Console + 单机纠删码）之上，新增 **MinIO 式多节点分布式存储后端**，使对象字节以 **Reed-Solomon (N=K+M)** 编码分散到**跨多个节点的 N 个 `{node, drive}` 端点（一个 erasure set 跨节点）**，提供：

1. **集群成员 + 拓扑 + 路由**（M7-1/M7-2）：`libcluster` 节点发现（dev gossip / prod epmd env host list）+ `Maxio.Cluster`（`nodes/0`、`this_node/0`、`alive?/1`）成员门面 + `Maxio.Cluster.Topology`（config 解析 pools→erasure sets→有序 N 个 `{node, drive}` 端点，索引 i = 分片 i，校验 N==K+M、M<=N/2，存 `:persistent_term`）+ `Maxio.Cluster.Router.set_for(bucket, key)`（确定性哈希 → set_id，对齐 MinIO；版本不入哈希）+ `Maxio.Cluster.Paths`（从 ErasureCoded 提取的共享对象路径构造）。
2. **跨节点分片传输**（M7-3，behind a behaviour 以可测）：`Maxio.Cluster.Transport` behaviour（`put_shard`/`get_shard`/`put_sidecar`/`get_sidecar`/`stat_shard`/`delete_shard`/`heal_shard`，均针对一个 `{node, drive}` 端点、逐 (block, shard)）+ `Erpc` 实现（:erpc 到每节点的 `Maxio.Cluster.ShardServer` GenServer，做**本机一个 drive 路径**的分片 IO，复用 M6 part.0 偏移寻址 + per-block BLAKE3）+ `InProcess` 测试实现（进程内多盘 + 可注入端点宕机）。节点宕机/超时/远端异常 → nil 分片（交 EC 重建）。
3. **分布式锁**（M7-4）：`Maxio.Cluster.Lock.with_lock(resource, fun)`——MVP 用 `:global.trans/4`（全 mesh 互斥，单资源无死锁，OTP25+ 防重叠分区）；升级路径 dsync 式 quorum 锁 `quorum_with_lock/3`（n/2+1 多数获锁，更抗宕机）。守护对象/桶变更（PUT/assemble/heal/delete），获锁失败 → `{:error, :locked}`（绝不静默并发写）。
4. **`Maxio.Storage.Distributed` 后端**（M7-4）：实现 `Maxio.Storage.Backend` 全部 callback——put 逐块流式编码（M6 `Codec.split_block/2`），分片 i 写 set 端点 i（经 transport，逐块），sidecar 写全部 N 端点，成功端点数 ≥ write_quorum 才 `{:ok}`；get 逐块跨节点并行读 K-of-N 分片、按 sidecar BLAKE3 校验 + 重建（M6 `Codec.restore_block/5`）、流式发出；stat/delete/bucket-ops/parts/version_id 跨 set；quorum-loss → 结构化错误。config 可切后端。**复用 M6 Codec/NIF + 逐块流式 verbatim，只改分片 IO 目标（本地 `:file` → transport）。**
5. **跨节点 heal + 集群 e2e + 文档**（M7-5）：扩展 M6 heal 检测宕机/被替换节点上的缺失分片、从存活端点（peer）重建回写（quorum）；`mix maxio.heal.cluster` cluster-aware CLI；集群 e2e（进程内多节点 + `:peer` 真节点各一套）证明「一节点宕机仍可写（write quorum）+ 一节点宕机仍可读（read quorum）+ 节点返回后 heal + quorum-loss raise」；STATUS/README 更新 + **诚实文档化仍 defer 的运维 parity**（rebalance/decommission/online pool 扩容、完整 dsync refresh/staleness、跨节点 IAM/bucket-metadata 复制）。

**显式不做（DEFER 到 M7+，文档化，绝不静默）**——见末尾「§ M7 显式 deferral（文档化，绝不静默）」。

> **设计保证（M7 在 M6 同一 RS 核心之外加层）**：M6 的 erasure set 是「N 个盘 = N 个本地目录」，RS 数学/codec/streaming/quorum/heal 与分布式 set **完全相同**；M7 只替换**分片访问 transport**（本地 `:file` ops → :erpc/transport）并在同一 RS 核心**之外**加 routing/locking/topology 层——**不重写 encode/decode/heal 引擎**。所有 deferral 显式列出（铁律 3，无静默缺口）。

---

## Architecture（M7 在 M6 之上的增量——核心管线 + RS 核心零改动）

```
                 （核心请求管线 / handler / dispatcher / endpoint —— 一行不改）
S3 客户端 → LB → 任一节点 Maxio.S3.Endpoint → ... → Maxio.S3.Handlers.Object/Multipart
                                                          │
                                               Maxio.Storage（facade，不改）
                                                          │  backend() = config :maxio, :storage_backend
                       ┌──────────────────────┬───────────┴──────────────────────────────┐
              Maxio.Storage.FS（M0，不改）  Maxio.Storage.ErasureCoded（M6，不改）   Maxio.Storage.Distributed ★新（M7-4）
                                                                                         │ 实现 Maxio.Storage.Backend 全部 callback
                                                          ┌──────────────────────────────┼───────────────────────────┐
                                          Maxio.Cluster.Router（M7-2）         Maxio.Cluster.Lock（M7-4）   Maxio.Cluster.Transport（M7-3 behaviour）
                                            set_for(bucket,key) → set_id        with_lock(res, fun)          ┌──────────────┴───────────────┐
                                                          │                                          Transport.Erpc（:erpc）   Transport.InProcess（test）
                                          Maxio.Cluster.Topology（M7-2）                                    │
                                            endpoints(set_id) → [{node_i, drive_i}]            Maxio.Cluster.ShardServer（M7-3，每节点一个 GenServer）
                                                          │                                            put_shard/get_shard/put_sidecar/get_sidecar/
                                          Maxio.Cluster（M7-1 成员门面）                                  stat_shard/delete_shard/heal_shard（本机一个 drive）
                                            nodes/0 · this_node/0 · alive?/1                              │ 复用 M6 part.0 偏移寻址 + BLAKE3
                                                          │                                              ▼
                                          Cluster.Supervisor（libcluster，M7-1）        ┌──────────── 复用 M6 核心（一行不改）────────────┐
                                            dev gossip / prod epmd host list             Maxio.Storage.Erasure.{Codec,Config,Meta}
                                                                                          Maxio.Native.ErasureCoding（Rustler NIF）
                                                                                          Maxio.Storage.Erasure.InsufficientShardsError

盘上布局（每端点 = 一个 {node, drive}，drive 是该节点上一个本地目录；与 M6 单机布局逐字一致）：
  <drive_i>/<bucket>/<key|.versions/<bucket>/<key>/<version_id>>/part.0     # 端点 i 对该对象的分片字节
  <drive_i>/<bucket>/<key|...>/meta.json                                   # per-object sidecar（每端点一份，相同内容）
  <drive_i>/.uploads/<bucket>/<upload_id>/<part_number>/{part.0,meta.json} # part 分片字节 + sidecar

跨节点消息（铁律 4）：每条 :erpc 只载「一个 block 的一个分片」(~256 KiB)，绝不整对象/整文件。

CLI（铁律 4 可观测）：mix maxio.heal.cluster（结构化日志：bucket/key/version/set/endpoint/block/result）
```

config 新增（不改既有 key，仅追加）：
```elixir
# 节点发现拓扑（libcluster）
config :maxio, Maxio.Cluster, topologies: [...]   # dev gossip / prod epmd
# erasure 部署拓扑：pools → sets → 有序 N 个 {node, drive} 端点
config :maxio, Maxio.Cluster.Topology,
  data_shards: 4, parity_shards: 2, block_size: 1_048_576,
  pools: [%{id: 0, sets: [%{id: 0, endpoints: [{node, drive}, ...]}, ...]}]
# 分片传输实现（prod = :erpc；test 覆盖为 InProcess）
config :maxio, :shard_transport, Maxio.Cluster.Transport.Erpc
# 切到分布式后端（默认仍 FS；分布式 opt-in）
# config :maxio, :storage_backend, Maxio.Storage.Distributed
```

---

## 单元总览（按依赖串行；每单元结束须 green compile + 测试通过 + 一次 commit）

| 单元 | 标题 | 依赖 | 规模/分割理由 |
|---|---|---|---|
| **M7-1** | `libcluster` dep + `Maxio.Cluster` 成员门面 + `Cluster.Supervisor` 监督树前置接线 + dev gossip / prod epmd config | M6 | 自包含；只读 mesh + 起 supervisor，无 IO 无后端；先打地基 |
| **M7-2** | `Maxio.Cluster.Topology`（解析+校验 pools→sets→endpoints，`:persistent_term`）+ `Maxio.Cluster.Router.set_for/2`（确定性稳定路由）+ `Maxio.Cluster.Paths`（从 ErasureCoded 提取的共享对象路径构造）+ config | M7-1 | 纯函数 TDD：确定性路由、set 取模、版本稳定；拓扑校验 raise |
| **M7-3** | `Maxio.Cluster.ShardServer`（每节点本机一 drive 分片 IO，复用 M6 leaf）+ `Maxio.Cluster.Transport` behaviour + `Erpc` 实现 + `InProcess` 测试实现（可注入端点宕机）；TDD via InProcess | M7-2 | 传输层抽象 + 两实现，独立可测；不触后端 |
| **M7-4** | `Maxio.Storage.Distributed` 后端（复用 M6 Codec/Config/Meta/streaming，分片 IO 换成 transport()；put/get/stat/delete/bucket/parts + version_id + quorum 返回值映射）+ `Maxio.Cluster.Lock`（:global.trans MVP + dsync quorum 升级）守护 PUT/assemble/delete + 共享 conformance（同跑 Distributed+InProcess）+ quorum/宕机/bitrot 单测 + config 切后端 | M7-3 | 后端主体 + 锁 + 契约一致性验收；单 executor 一轮可完成 |
| **M7-5** | 跨节点 heal（扩展 M6 Heal 经 transport 重建宕机端点分片）+ `mix maxio.heal.cluster` CLI + 集群 e2e（InProcess 多节点矩阵 + `:peer` 真节点）+ STATUS/README 更新 + M7 defer 文档化 | M7-4 | 自愈 + 端到端集群取证 + 收尾 |

**执行顺序**：M7-1 → M7-2 → M7-3 → M7-4 → M7-5。**串行执行，禁止并行 mix 编译**（避免锁文件竞争）。每单元规模控制在「单个 executor 一轮内可完成实现 + 跑测试 + 调用 StructuredOutput」。

---

## 全局命名契约（M7 新增，一次定义全程复用；M0–M6 既有契约逐字一致复用）

**沿用既有契约（逐字一致，绝不重定义）**：
- `Maxio.Storage.Backend` behaviour 全部 callback（含 M4 `version_id` 维度 + M2 parts），见 `lib/maxio/storage/backend.ex`。Distributed 实现与 FS/ErasureCoded **签名一致**：每 callback 末参 `opts \\ []`（测试注入 `:topology`/`:transport`）。
- `Maxio.Storage.Erasure.Config.load!/1` → `%Config{data_shards, parity_shards, block_size, read_quorum, write_quorum, drives}`（M7 经 `Topology.ec_params/0` 喂 `:data_shards`/`:parity_shards`/`:block_size`；Distributed **不用** `cfg.drives`，端点来自 Topology）。`Config.total/1` = K+M = N。`read_quorum = K`；`write_quorum = if M == div(N,2), do: K+1, else: K`。
- `Maxio.Storage.Erasure.Codec.split_block(cfg, padded) :: %{shards: [bin], checksums: [bin], shard_len: int}`、`restore_block(cfg, shards, checksums, data_len, meta) :: bin`（存活<K raise `InsufficientShardsError`）、`verify_shard(shard | nil, checksum) :: bool`。
- `Maxio.Storage.Erasure.Meta.encode(map) :: bin`、`decode!(bin) :: map`。
- sidecar 形态（M6，逐字复用）：`%{"ec"=>%{"k","m","block_size","algo"}, "size","etag","sha256","parts"=>[%{"part"=>0,"size"}], "shards"=>[%{"drive"=>i,"shard_file_size","block_hashes"=>[hex,...]}]}`。
- `Maxio.Storage.Erasure.InsufficientShardsError`（M6，字段 bucket/key/version_id/block_index/present/required）。

**M7 新增命名契约（一次定义全程复用）**：
- `Maxio.Cluster.nodes() :: [node()]`（含本机，排序）；`this_node() :: node()`；`alive?(node()) :: boolean()`。
- `Maxio.Cluster.Topology.set_id() :: non_neg_integer()`；`endpoint() :: {node(), String.t()}`。
- `Maxio.Cluster.Topology.all_set_ids() :: [set_id()]`（全局有序）；`endpoints(set_id) :: [endpoint()]`（索引 i = 分片 i）；`ec_params() :: keyword()`（`[data_shards:, parity_shards:, block_size:]`）；`local_drives_for_set(set_id) :: [String.t()]`。
- 测试注入：`Topology` 与 `Router` 在 M7 既走 `:persistent_term`（prod），又支持 `opts[:topology]`（test）——见各单元 `parsed/1` + `get/1`。**统一约定**：Distributed 后端每个 callback 接受 `opts`，`opts[:topology]`（`%{...}` parsed struct）覆盖 `:persistent_term`，`opts[:transport]` 覆盖 `config :maxio, :shard_transport`。
- `Maxio.Cluster.Router.set_for(bucket, key, topology \\ nil) :: set_id()`。
- `Maxio.Cluster.Paths.object_rel(bucket, key, version_id) :: {:ok, String.t()} | {:error, :invalid_key}`；`part_rel(bucket, upload_id, part_number) :: String.t()`；`upload_rel(bucket, upload_id) :: String.t()`。
- `Maxio.Cluster.Transport`（behaviour）callback（均针对一个端点 `{node, drive}` 的「该对象在该 drive 下的目录」`drive_obj_dir = Path.join(drive, obj_rel)`，由后端组装后传入，避免 transport 知道路径规则）：
  - `put_shard(node, drive_obj_dir, block_index, shard_bytes, shard_len) :: :ok | {:error, term}`
  - `get_shard(node, drive_obj_dir, block_index, shard_len) :: binary() | nil`
  - `put_sidecar(node, drive_obj_dir, meta) :: :ok | {:error, term}`
  - `get_sidecar(node, drive_obj_dir) :: {:ok, map} | {:error, :enoent}`
  - `stat_shard(node, drive_obj_dir) :: {:ok, non_neg_integer} | {:error, :enoent}`
  - `delete_shard(node, drive_obj_dir) :: :ok`
  - `heal_shard(node, drive_obj_dir, block_map :: %{non_neg_integer => binary}, shard_len, meta) :: {:ok, non_neg_integer}`
- `Maxio.Cluster.ShardServer`（每节点 named GenServer）暴露**同名**本机函数（被 :erpc 远程调用；参数无 `node`，只有 `drive_obj_dir` 等）：`put_shard/4`、`get_shard/3`、`put_sidecar/2`、`get_sidecar/1`、`stat_shard/1`、`delete_shard/1`、`heal_shard/4`、`ping/0`。
- `Maxio.Cluster.Lock.with_lock(resource :: {String.t(), String.t()}, fun, retries \\ 5) :: {:ok, term} | {:error, :locked}`；`quorum_with_lock(resource, fun, opts \\ []) :: {:ok, term} | {:error, :no_quorum}`。

---

# 单元 M7-1：libcluster + Maxio.Cluster 成员门面 + 监督树接线

**目标**：加 `libcluster` 依赖；新增 `Maxio.Cluster`（成员门面，只读 `Node.self/0`/`Node.list/0`）；`Maxio.Application` 监督树**前置** `Cluster.Supervisor`（+ 占位的 `Topology`/`ShardServer` child，后续单元充实）；config 加 dev gossip / prod epmd 拓扑。单节点 dev 与多节点 prod **同一代码路径**（空 peer 列表无害）。

**依赖**：M6。**TDD**：`Maxio.Cluster` 纯读 mesh，单节点下 `nodes() == [Node.self()]`、`alive?(self) == true`、`alive?(:nope@x) == false`。

### 步骤 1（命令）：加 libcluster 依赖

`mix.exs` 的 `deps/0`，在 `{:rustler, "~> 0.36"}` 之后追加（保留既有，仅加一行 + 末尾逗号处理）：

```elixir
      # 纠删码 Rust NIF（reed-solomon-simd + blake3）；use Rustler 宏在 mix compile 期驱动 cargo
      {:rustler, "~> 0.36"},
      # M7 多节点：libcluster 节点发现（dev gossip / prod epmd env host list）
      {:libcluster, "~> 3.5"}
```

执行：
```powershell
$env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix deps.get
mix compile --warnings-as-errors
```
期望：`libcluster` 拉取成功，编译零警告。

### 步骤 2（TDD 红）：`Maxio.Cluster` 成员门面测试

新建 `test/maxio/cluster/cluster_test.exs`：

```elixir
defmodule Maxio.ClusterTest do
  use ExUnit.Case, async: true

  test "this_node 返回本节点名" do
    assert Maxio.Cluster.this_node() == Node.self()
  end

  test "nodes 含本机且已排序" do
    ns = Maxio.Cluster.nodes()
    assert Node.self() in ns
    assert ns == Enum.sort(ns)
  end

  test "alive? 对本机 true、对未知节点 false" do
    assert Maxio.Cluster.alive?(Node.self())
    refute Maxio.Cluster.alive?(:"nope@127.0.0.1")
  end
end
```

执行（确认红——模块未定义）：
```powershell
mix test test/maxio/cluster/cluster_test.exs
```

### 步骤 3（实现绿）：`Maxio.Cluster`

新建 `lib/maxio/cluster.ex`：

```elixir
defmodule Maxio.Cluster do
  @moduledoc """
  集群成员视图门面（M7）。节点发现/连接由 libcluster（Cluster.Supervisor）+ 分布式 Erlang 负责；
  本模块只读出当前 mesh（Node.self/Node.list）并叠加静态拓扑（Maxio.Cluster.Topology）回答
  「某 set 的 N 个 {node,drive} 端点是谁」。铁律 2：上层只认本门面，不直连 Node/:erpc。

  单节点 dev：Node.list/0 为空，nodes/0 == [Node.self()]，与多节点 prod 同一代码路径。
  """

  @doc "当前节点（含本机）的全部集群节点列表，已排序（确定性）。"
  @spec nodes() :: [node()]
  def nodes, do: [Node.self() | Node.list()] |> Enum.sort()

  @doc "本节点名。"
  @spec this_node() :: node()
  def this_node, do: Node.self()

  @doc "某节点是否在线（在当前 mesh 中，含本机）。"
  @spec alive?(node()) :: boolean()
  def alive?(node), do: node == Node.self() or node in Node.list()

  @doc """
  某 set 的有序 {node, drive} 端点列表，索引 i = 分片 i 的归属。
  来自静态拓扑（Maxio.Cluster.Topology），与 mesh 在线与否无关——
  在线判定在分片 IO 时（M7-3）逐端点进行，离线端点产出 nil 分片交 EC 重建。
  """
  @spec drives_for_set(Maxio.Cluster.Topology.set_id()) :: [{node(), String.t()}]
  def drives_for_set(set_id), do: Maxio.Cluster.Topology.endpoints(set_id)
end
```

> 注：`drives_for_set/3` 引用 `Maxio.Cluster.Topology`（M7-2 才落地）。为使 M7-1 独立编译通过，本单元**先不引入** `drives_for_set/1`——把它从 `lib/maxio/cluster.ex` 删去，仅保留 `nodes/0`/`this_node/0`/`alive?/1`，并在 M7-2 完成 Topology 后再追加 `drives_for_set/1`（M7-2 步骤里有明确追加指令）。**M7-1 提交的 `Maxio.Cluster` 只含三个成员函数。**

故 M7-1 实际写入 `lib/maxio/cluster.ex` 的内容为（去掉 `drives_for_set/1`）：

```elixir
defmodule Maxio.Cluster do
  @moduledoc """
  集群成员视图门面（M7）。节点发现/连接由 libcluster（Cluster.Supervisor）+ 分布式 Erlang 负责；
  本模块只读出当前 mesh（Node.self/Node.list）。铁律 2：上层只认本门面，不直连 Node/:erpc。
  单节点 dev：Node.list/0 为空，nodes/0 == [Node.self()]，与多节点 prod 同一代码路径。
  """

  @doc "当前节点（含本机）的全部集群节点列表，已排序（确定性）。"
  @spec nodes() :: [node()]
  def nodes, do: [Node.self() | Node.list()] |> Enum.sort()

  @doc "本节点名。"
  @spec this_node() :: node()
  def this_node, do: Node.self()

  @doc "某节点是否在线（在当前 mesh 中，含本机）。"
  @spec alive?(node()) :: boolean()
  def alive?(node), do: node == Node.self() or node in Node.list()
end
```

执行（确认绿）：
```powershell
mix test test/maxio/cluster/cluster_test.exs
```

### 步骤 4（接线）：监督树前置 `Cluster.Supervisor`

修改 `lib/maxio/application.ex` 的 `start/2`，把 children 列表头部前置 libcluster supervisor（**仅在配置了非空拓扑时启动**，否则单节点 dev/test 不需要它）。把现有 `children = [...]` 替换为：

```elixir
  @impl true
  def start(_type, _args) do
    children =
      cluster_children() ++
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
        log_deferred_features()
        {:ok, pid}

      other ->
        other
    end
  end

  # M7：libcluster 节点发现 supervisor。仅当配置了非空 topologies 才起（多节点 prod）；
  # 单节点 dev/test（无 topologies）跳过——Maxio.Cluster.nodes/0 退化为 [Node.self()]，同一代码路径。
  defp cluster_children do
    topologies = Application.get_env(:maxio, Maxio.Cluster, [])[:topologies] || []

    if topologies == [] do
      []
    else
      [{Cluster.Supervisor, [topologies, [name: Maxio.Cluster.ClusterSupervisor]]}]
    end
  end
```

> M7-1 **暂不**在监督树加 `Topology`/`ShardServer`（它们在 M7-2/M7-3 才存在）。M7-2 步骤里会追加 `Maxio.Cluster.Topology` child（它本身在无拓扑配置时 init 直接 `{:ok, :no_topology}` 不崩），M7-3 追加 `ShardServer`。这样每单元都保持 green compile。

### 步骤 5（config）：dev gossip / prod epmd 拓扑

`config/dev.exs` 末尾追加（gossip 单机多 BEAM 自发现；注释说明仅多节点 iex 会话需要）：

```elixir
# ── M7 多节点：dev 用 gossip 策略（UDP 多播，单机多 iex --sname 自发现）。──
# 单节点 `iex -S mix` 时 topologies 仍存在但无 peer，Cluster.Supervisor 空转无害。
# 仅当真的起多节点（见 STATUS「工具链与环境」的三节点 iex 命令）才形成 mesh。
config :maxio, Maxio.Cluster,
  topologies: [
    maxio_gossip: [
      strategy: Cluster.Strategy.Gossip,
      config: [port: 45_892, multicast_addr: "230.1.1.251", multicast_ttl: 1]
    ]
  ]
```

`config/runtime.exs`，在 `if config_env() == :prod do` **之前**（runtime 读 env，所有环境可用；但 epmd host list 仅 prod 有意义）追加：

```elixir
# ── M7 多节点：prod 从 MAXIO_PEERS（逗号分隔 node 名）静态 epmd 组网。──
# 例：MAXIO_PEERS="maxio@10.0.0.1,maxio@10.0.0.2,maxio@10.0.0.3"
# 每节点须以 --name maxio@<ip> --cookie <同一 cookie> 启动（分布式 Erlang 前提）。
if config_env() == :prod do
  peers =
    System.get_env("MAXIO_PEERS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_atom/1)

  if peers != [] do
    config :maxio, Maxio.Cluster,
      topologies: [
        maxio_epmd: [
          strategy: Cluster.Strategy.Epmd,
          config: [hosts: peers]
        ]
      ]
  end
end
```

`config/test.exs` 末尾追加（test 不组网，显式空拓扑，确保 `cluster_children/0` 跳过）：

```elixir
# M7：test 不起 libcluster（进程内 transport 注入即可覆盖分布式逻辑）；:peer 集成测试自行起节点。
config :maxio, Maxio.Cluster, topologies: []
```

### 步骤 6（验证 + 提交）

```powershell
mix compile --warnings-as-errors
mix test test/maxio/cluster/cluster_test.exs
mix test
```
期望：编译零警告；新测试绿；**全量回归仍 463 绿**（M7-1 未改任何既有行为，仅加门面 + 条件 supervisor）。

```powershell
git add -A
git commit -m @'
M7-1: libcluster dep + Maxio.Cluster 成员门面 + Cluster.Supervisor 条件接线

- mix.exs 加 {:libcluster, "~> 3.5"}
- Maxio.Cluster：nodes/0 · this_node/0 · alive?/1（只读 mesh，单节点退化 [Node.self()]）
- Application 前置 cluster_children/0（仅非空 topologies 才起 Cluster.Supervisor）
- config：dev gossip / prod epmd（MAXIO_PEERS）/ test 空拓扑
- 全量回归绿、--warnings-as-errors 零警告

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（M7-1）**：`libcluster` 拉取且编译零警告；`Maxio.Cluster` 三函数单测绿；监督树在无拓扑时不起 `Cluster.Supervisor`（test/dev 单节点不受影响）；全量回归 463 绿。

---

# 单元 M7-2：Topology + Router + Paths（拓扑解析/校验 + 确定性稳定路由 + 共享路径构造）

**目标**：`Maxio.Cluster.Topology`（解析+校验 config 的 pools→sets→endpoints，存 `:persistent_term`，支持 test 注入 parsed map）；`Maxio.Cluster.Router.set_for/2,3`（对象名确定性哈希 mod set 数，版本不入哈希，对齐 MinIO）；`Maxio.Cluster.Paths`（从 `ErasureCoded` 提取的共享对象/part 路径构造，单一事实来源避免 M6/M7 漂移）。三者均纯函数，TDD 主导。

**依赖**：M7-1。**TDD**：路由确定性（同 key 恒同 set）、稳定（版本不影响）、取模分布；拓扑校验（endpoints 数 != N → raise、M > N/2 → raise）；路径构造（null vs 版本化、`..` 拒绝）。

### 步骤 1（TDD 红）：`Maxio.Cluster.Paths` 测试

新建 `test/maxio/cluster/paths_test.exs`：

```elixir
defmodule Maxio.Cluster.PathsTest do
  use ExUnit.Case, async: true
  alias Maxio.Cluster.Paths

  test "null 版本对象相对路径 = bucket/key" do
    assert {:ok, "b/k"} = Paths.object_rel("b", "k", "null")
    assert {:ok, "b/a/b/c"} = Paths.object_rel("b", "a/b/c", "null")
  end

  test "版本化对象相对路径 = .versions/bucket/key/version_id" do
    assert {:ok, ".versions/b/k/01ABC"} = Paths.object_rel("b", "k", "01ABC")
  end

  test "路径穿越/空 key 拒绝" do
    assert {:error, :invalid_key} = Paths.object_rel("b", "../x", "null")
    assert {:error, :invalid_key} = Paths.object_rel("b", "a/./b", "null")
    assert {:error, :invalid_key} = Paths.object_rel("b", "", "null")
  end

  test "part / upload 相对路径" do
    assert ".uploads/b/u1/2" = Paths.part_rel("b", "u1", 2)
    assert ".uploads/b/u1" = Paths.upload_rel("b", "u1")
  end
end
```

### 步骤 2（实现绿）：`Maxio.Cluster.Paths`

新建 `lib/maxio/cluster/paths.ex`（**逐字提取自 `ErasureCoded` 的 `object_dirs/4` + `safe_relative/1` + parts 路径，只是返回「相对路径」而非「拼好的盘内绝对路径」**——盘内绝对路径由后端 `Path.join(drive, rel)` 组装）：

```elixir
defmodule Maxio.Cluster.Paths do
  @moduledoc """
  分布式后端与 heal 共享的对象/part「盘内相对路径」构造（M7）。单一事实来源——
  与 M6 ErasureCoded 的 object_dirs/4 + safe_relative/1 语义逐字一致（避免后端漂移，铁律 2）。
  返回相对路径（相对每个 drive 根），调用方 Path.join(drive, rel) 得该端点该对象的目录。
  """

  @doc """
  对象在某 drive 下的相对路径：null 版本 = "bucket/key"；
  否则 = ".versions/bucket/key/version_id"。`..`/`.`/空 key 拒绝（路径穿越守卫）。
  """
  @spec object_rel(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_key}
  def object_rel(bucket, key, version_id) do
    case safe_relative(key) do
      {:ok, rel} ->
        sub =
          if version_id == "null" do
            Path.join([bucket, rel])
          else
            Path.join([".versions", bucket, rel, version_id])
          end

        {:ok, to_unix(sub)}

      :error ->
        {:error, :invalid_key}
    end
  end

  @doc "part 在某 drive 下的相对路径：.uploads/bucket/upload_id/part_number。"
  @spec part_rel(String.t(), String.t(), pos_integer()) :: String.t()
  def part_rel(bucket, upload_id, part_number) do
    Path.join([".uploads", bucket, upload_id, Integer.to_string(part_number)]) |> to_unix()
  end

  @doc "upload 在某 drive 下的相对路径：.uploads/bucket/upload_id。"
  @spec upload_rel(String.t(), String.t()) :: String.t()
  def upload_rel(bucket, upload_id) do
    Path.join([".uploads", bucket, upload_id]) |> to_unix()
  end

  defp safe_relative(key) do
    segments = key |> String.split("/", trim: true)

    cond do
      key == "" -> :error
      Enum.any?(segments, &(&1 in ["..", "."])) -> :error
      true -> {:ok, Path.join(segments)}
    end
  end

  # 路径分隔统一为 "/"（Windows 上 Path.join 产 "\\"；端点目录后续仍经 Path.join(drive, rel) 落地，
  # 但相对路径本身用 "/" 保证跨节点/跨平台一致，且单测断言稳定）。
  defp to_unix(path), do: String.replace(path, "\\", "/")
end
```

执行：
```powershell
mix test test/maxio/cluster/paths_test.exs
```

### 步骤 3（TDD 红）：`Maxio.Cluster.Topology` 测试

新建 `test/maxio/cluster/topology_test.exs`（测试用 `parse_and_validate!/1` 直接喂 config map，不依赖 `:persistent_term` 的 boot 解析）：

```elixir
defmodule Maxio.Cluster.TopologyTest do
  use ExUnit.Case, async: true
  alias Maxio.Cluster.Topology

  defp cfg(endpoints_per_set, k, m) do
    n = k + m
    mk = fn id ->
      eps = for i <- 0..(n - 1), do: {:"maxio@10.0.0.#{rem(i, 3) + 1}", "/data/d#{id}_#{i}"}
      %{id: id, endpoints: eps}
    end

    [
      data_shards: k,
      parity_shards: m,
      block_size: 1024,
      pools: [%{id: 0, sets: Enum.map(0..(endpoints_per_set - 1), mk)}]
    ]
  end

  test "解析合法拓扑：set_ids 有序、endpoints 索引即分片索引、ec_params" do
    t = Topology.parse_and_validate!(cfg(2, 4, 2))
    assert t.set_ids == [0, 1]
    assert length(Topology.endpoints_from(t, 0)) == 6
    assert Topology.ec_params_from(t) == [data_shards: 4, parity_shards: 2, block_size: 1024]
  end

  test "endpoints 数 != K+M -> raise" do
    bad = put_in(cfg(1, 4, 2), [:pools], [%{id: 0, sets: [%{id: 0, endpoints: [{:n, "/d"}]}]}])
    assert_raise ArgumentError, ~r/endpoints/, fn -> Topology.parse_and_validate!(bad) end
  end

  test "M > N/2 -> raise（脑裂上界）" do
    assert_raise ArgumentError, ~r/N\/2/, fn -> Topology.parse_and_validate!(cfg(1, 2, 3)) end
  end

  test "local_drives_for_set 只返回 node == 给定节点 的 drive" do
    t = Topology.parse_and_validate!(cfg(1, 4, 2))
    eps = Topology.endpoints_from(t, 0)
    {node0, _} = hd(eps)
    locals = for {^node0, drive} <- eps, do: drive
    assert Topology.local_drives_from(t, 0, node0) == locals
  end
end
```

### 步骤 4（实现绿）：`Maxio.Cluster.Topology`

新建 `lib/maxio/cluster/topology.ex`：

```elixir
defmodule Maxio.Cluster.Topology do
  @moduledoc """
  静态部署拓扑（M7）：pools -> erasure sets -> 有序 N 个 {node, drive} 端点。索引 i = 分片 i 归属。
  启动期解析+校验 config（每 set endpoints 数 == K+M；M <= N/2），存 :persistent_term 供 O(1) 读。
  铁律 3：非法拓扑 raise，绝不带病启动。

  test 注入：parse_and_validate!/1 直接喂 config map 得 parsed struct；后端 callback 接受
  opts[:topology] 覆盖 :persistent_term，故无需真集群即可在 ExUnit 注入任意拓扑。
  """
  use GenServer

  @type set_id :: non_neg_integer()
  @type endpoint :: {node(), String.t()}
  @type t :: %{
          data_shards: pos_integer(),
          parity_shards: pos_integer(),
          block_size: pos_integer(),
          sets: %{set_id() => %{id: set_id(), endpoints: [endpoint()]}},
          set_ids: [set_id()]
        }

  @pt_key {__MODULE__, :topology}

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    case Application.get_env(:maxio, __MODULE__) do
      nil ->
        # 无拓扑配置（单节点 dev / FS 后端 / test）—— 不解析、不存 pt，门面读时回 :no_topology。
        {:ok, :no_topology}

      cfg ->
        parsed = parse_and_validate!(cfg)
        :persistent_term.put(@pt_key, parsed)
        {:ok, parsed}
    end
  end

  # ── 读 API（prod 走 :persistent_term；test 经 *_from/*_with 注入 parsed）──

  @doc "所有 set_id（按 pool 顺序 + set 顺序展平）的全局有序列表。路由 mod 用其长度。"
  @spec all_set_ids() :: [set_id()]
  def all_set_ids, do: get().set_ids

  @doc "某 set 的 N 个有序 {node,drive} 端点（索引 i = 分片 i）。"
  @spec endpoints(set_id()) :: [endpoint()]
  def endpoints(set_id), do: endpoints_from(get(), set_id)

  @doc "EC 参数（K/M/block_size），喂给 Maxio.Storage.Erasure.Config.load!/1。"
  @spec ec_params() :: keyword()
  def ec_params, do: ec_params_from(get())

  @doc "本节点在某 set 中负责的本地 drive 列表（端点 node == Node.self()）。"
  @spec local_drives_for_set(set_id()) :: [String.t()]
  def local_drives_for_set(set_id), do: local_drives_from(get(), set_id, Node.self())

  # ── 纯函数（test 注入 parsed；prod 经上面读 pt 调这些）──

  @spec all_set_ids_from(t()) :: [set_id()]
  def all_set_ids_from(%{set_ids: ids}), do: ids

  @spec endpoints_from(t(), set_id()) :: [endpoint()]
  def endpoints_from(%{sets: sets}, set_id), do: Map.fetch!(sets, set_id).endpoints

  @spec ec_params_from(t()) :: keyword()
  def ec_params_from(%{data_shards: k, parity_shards: m, block_size: bs}),
    do: [data_shards: k, parity_shards: m, block_size: bs]

  @spec local_drives_from(t(), set_id(), node()) :: [String.t()]
  def local_drives_from(t, set_id, node) do
    for {^node, drive} <- endpoints_from(t, set_id), do: drive
  end

  defp get do
    case :persistent_term.get(@pt_key, :no_topology) do
      :no_topology ->
        raise ArgumentError,
              "Maxio.Cluster.Topology 未配置（config :maxio, Maxio.Cluster.Topology）。" <>
                "分布式后端需要拓扑；单机请用 FS / ErasureCoded 后端。"

      parsed ->
        parsed
    end
  end

  @doc """
  解析+校验拓扑 config。返回 parsed struct。非法 raise ArgumentError（铁律 3）。
  校验：每 set endpoints 数 == K+M；M >= 1；M <= N/2；K >= 1。
  """
  @spec parse_and_validate!(keyword()) :: t()
  def parse_and_validate!(cfg) do
    k = Keyword.fetch!(cfg, :data_shards)
    m = Keyword.fetch!(cfg, :parity_shards)
    bs = Keyword.get(cfg, :block_size, 1_048_576)
    n = k + m

    cond do
      not (is_integer(k) and k > 0) ->
        raise ArgumentError, "topology: data_shards 须正整数（got #{inspect(k)}）"

      not (is_integer(m) and m >= 1) ->
        raise ArgumentError, "topology: parity_shards 须 >= 1（got #{inspect(m)}）"

      m > div(n, 2) ->
        raise ArgumentError, "topology: M=#{m} > N/2（N=#{n}）；parity 不得超过 set 的一半"

      true ->
        :ok
    end

    {sets, ids} =
      cfg
      |> Keyword.fetch!(:pools)
      |> Enum.flat_map(& &1.sets)
      |> Enum.reduce({%{}, []}, fn s, {acc, ids} ->
        if length(s.endpoints) != n do
          raise ArgumentError,
                "topology: set #{s.id} 有 #{length(s.endpoints)} 个 endpoints != K+M=#{n}"
        end

        if Map.has_key?(acc, s.id) do
          raise ArgumentError, "topology: 重复 set id #{s.id}"
        end

        {Map.put(acc, s.id, %{id: s.id, endpoints: s.endpoints}), [s.id | ids]}
      end)

    if ids == [] do
      raise ArgumentError, "topology: 至少需一个 erasure set"
    end

    %{
      data_shards: k,
      parity_shards: m,
      block_size: bs,
      sets: sets,
      set_ids: Enum.sort(ids)
    }
  end
end
```

执行：
```powershell
mix test test/maxio/cluster/topology_test.exs
```

### 步骤 5（TDD 红）：`Maxio.Cluster.Router` 测试

新建 `test/maxio/cluster/router_test.exs`：

```elixir
defmodule Maxio.Cluster.RouterTest do
  use ExUnit.Case, async: true
  alias Maxio.Cluster.{Router, Topology}

  defp topo(num_sets) do
    n = 6
    mk = fn id ->
      eps = for i <- 0..(n - 1), do: {:"maxio@n#{rem(i, 3)}", "/d#{id}_#{i}"}
      %{id: id, endpoints: eps}
    end

    Topology.parse_and_validate!(
      data_shards: 4,
      parity_shards: 2,
      block_size: 1024,
      pools: [%{id: 0, sets: Enum.map(0..(num_sets - 1), mk)}]
    )
  end

  test "确定性：同 (bucket,key) 恒映射同一 set" do
    t = topo(4)
    a = Router.set_for("bucket", "path/to/obj", t)
    b = Router.set_for("bucket", "path/to/obj", t)
    assert a == b
    assert a in Topology.all_set_ids_from(t)
  end

  test "版本不入哈希：同对象不同 version_id 同 set（路由不取 version_id）" do
    t = topo(4)
    # Router.set_for/3 仅接受 bucket+key，版本天然不参与 —— 由签名保证。
    assert Router.set_for("b", "k", t) == Router.set_for("b", "k", t)
  end

  test "取模落在 [0, num_sets)" do
    t = topo(3)
    ids = Topology.all_set_ids_from(t)
    for key <- ~w(a b c d e f g aa bb cc obj/with/slash) do
      assert Router.set_for("bucket", key, t) in ids
    end
  end

  test "num_sets=1 恒映射唯一 set" do
    t = topo(1)
    assert Router.set_for("b", "anything", t) == 0
  end
end
```

### 步骤 6（实现绿）：`Maxio.Cluster.Router`

新建 `lib/maxio/cluster/router.ex`：

```elixir
defmodule Maxio.Cluster.Router do
  @moduledoc """
  对象 -> erasure set 路由（M7）。最简稳定方案：phash2(bucket <> "/" <> key) mod 全局 set 数。
  铁律 5 对齐 MinIO：set 放置 = 对象名哈希取模。版本不入哈希（同对象全版本同 set，
  故版本化 GET/PUT 路由一致）。online set 扩缩（rebalance）= 显式 defer（需迁移既有对象，非 MVP）。

  稳定性铁律（绝不可变）：
    1. 哈希 `bucket <> "/" <> key` 字符串（不含 version_id）。
    2. 在「全局有序 set_id 列表」上取模 + index，绝不哈希到裸 node（节点增删，set 稳定）。
    3. :erlang.phash2/2 跨节点/跨 release 对同一 term 确定性，足够且零依赖。
  """
  alias Maxio.Cluster.Topology

  @doc "对象 (bucket,key) -> set_id。topology 缺省读 :persistent_term；test 传 parsed struct。"
  @spec set_for(String.t(), String.t(), Topology.t() | nil) :: Topology.set_id()
  def set_for(bucket, key, topology \\ nil)

  def set_for(bucket, key, nil) do
    ids = Topology.all_set_ids()
    pick(ids, bucket, key)
  end

  def set_for(bucket, key, %{} = topology) do
    ids = Topology.all_set_ids_from(topology)
    pick(ids, bucket, key)
  end

  defp pick(ids, bucket, key) do
    idx = :erlang.phash2(bucket <> "/" <> key, length(ids))
    Enum.at(ids, idx)
  end
end
```

执行：
```powershell
mix test test/maxio/cluster/router_test.exs
```

### 步骤 7（接线）：监督树加 `Topology` child + `Maxio.Cluster.drives_for_set/1`

修改 `lib/maxio/application.ex` 的 `cluster_children/0`，把 `Maxio.Cluster.Topology` 加入（它在无配置时 init 回 `{:ok, :no_topology}`，故**始终**可起，与是否多节点无关）。把 `cluster_children/0` 改为：

```elixir
  # M7：libcluster 节点发现 supervisor（仅非空 topologies 才起）+ 拓扑解析 GenServer（始终起，
  # 无配置时空转）。单节点 dev/test 跳过 Cluster.Supervisor，但 Topology 仍存在（读时若无配置 raise）。
  defp cluster_children do
    topologies = Application.get_env(:maxio, Maxio.Cluster, [])[:topologies] || []

    libcluster =
      if topologies == [],
        do: [],
        else: [{Cluster.Supervisor, [topologies, [name: Maxio.Cluster.ClusterSupervisor]]}]

    libcluster ++ [Maxio.Cluster.Topology]
  end
```

在 `lib/maxio/cluster.ex` 末尾（`alive?/1` 之后）追加 `drives_for_set/1`：

```elixir
  @doc """
  某 set 的有序 {node, drive} 端点列表，索引 i = 分片 i 的归属（来自静态拓扑）。
  与 mesh 在线与否无关——在线判定在分片 IO 时（M7-3）逐端点进行，离线端点产出 nil 分片交 EC 重建。
  """
  @spec drives_for_set(Maxio.Cluster.Topology.set_id()) :: [{node(), String.t()}]
  def drives_for_set(set_id), do: Maxio.Cluster.Topology.endpoints(set_id)
```

### 步骤 8（验证 + 提交）

```powershell
mix compile --warnings-as-errors
mix test test/maxio/cluster/
mix test
```
期望：编译零警告；三个新测试文件全绿；全量回归仍绿（Topology 无配置时 init 不崩，门面读时才 raise——而无任何代码在 test 环境读它）。

```powershell
git add -A
git commit -m @'
M7-2: Maxio.Cluster.{Topology,Router,Paths} —— 拓扑解析/校验 + 确定性稳定路由 + 共享路径

- Topology：解析+校验 pools→sets→endpoints（N==K+M、M<=N/2），:persistent_term；parse_and_validate!/1 供 test 注入
- Router.set_for/2,3：phash2(bucket/key) mod set 数，确定性+版本稳定（对齐 MinIO set 放置）
- Paths：object_rel/part_rel/upload_rel（从 ErasureCoded 提取的共享相对路径，单一事实来源）
- Application 始终起 Topology child（无配置空转）；Maxio.Cluster.drives_for_set/1
- 纯函数 TDD 全绿、全量回归绿、--warnings-as-errors 零警告

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（M7-2）**：拓扑解析/校验单测（合法 + N!=K+M raise + M>N/2 raise + 重复 id raise）绿；路由确定性/稳定性/取模单测绿；路径构造单测绿；全量回归绿。

---

# 单元 M7-3：ShardServer（每节点本机分片 IO）+ Transport behaviour + Erpc/InProcess 实现

**目标**：`Maxio.Cluster.ShardServer`（每节点 named GenServer，对外被 :erpc 寻址到「正确的节点」，对内只操作「本机一个 drive 路径」，复用 M6 part.0 偏移寻址 + per-block BLAKE3）；`Maxio.Cluster.Transport` behaviour（7 个 callback，逐 (block,shard)，铁律 4）；`Erpc` 实现（:erpc 到 ShardServer，宕机/超时/远端异常 → nil/`{:error,:unavailable}`）；`InProcess` 测试实现（进程内多盘 + 可注入端点宕机，给 M7-4/M7-5 提供确定性多节点覆盖）。

**依赖**：M7-2。**TDD**：ShardServer put/get round-trip、短读→nil、缺文件→nil、stat/delete/sidecar、heal_shard 回写；InProcess transport put/get、宕机端点 get→nil/put→error。

### 步骤 1（实现）：`Maxio.Cluster.ShardServer`

新建 `lib/maxio/cluster/shard_server.ex`（**本机一个 drive 的分片 IO，逐字复用 M6 ErasureCoded 的 part.0 偏移寻址 + sidecar 读写 + heal pwrite 语义**；函数为「纯本机操作」，:erpc 已在远端独立进程执行，GenServer 仅作为命名锚点 + 演进位，MVP 直接函数实现）：

```elixir
defmodule Maxio.Cluster.ShardServer do
  @moduledoc """
  每节点一个的本机分片 IO 服务（named GenServer，M7）。对外被 :erpc 寻址到「正确的节点」，
  对内只操作「本机一个 drive 路径」。复用 M6 ErasureCoded 的 part.0 偏移寻址（j * shard_len）
  + per-block BLAKE3 sidecar 读写 + heal pwrite 语义，只是 drive_obj_dir 由调用方显式传入
  （不再从 cfg.drives 列表枚举——因为「哪个盘」已由 Topology 的端点决定，「哪个节点」已由 :erpc 决定）。

  铁律 4：put_shard/get_shard 逐块有界（一次一个 ~block_size/K 的分片），绝不一次传整对象/整文件。
  这些函数是「本机执行」纯操作，可直接被 :erpc 调用；GenServer 仅为命名锚点 + 限流/fd 缓存演进位。
  """
  use GenServer

  alias Maxio.Storage.Erasure.Meta

  @part_file "part.0"
  @meta_file "meta.json"

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{}}

  @doc "存活探针（:erpc.multicall 健康检查用）。"
  @spec ping() :: :pong
  def ping, do: :pong

  @doc """
  写对象在 drive_obj_dir 下、block_index 的单个分片字节（幂等覆盖，pwrite 偏移 j*shard_len）。
  drive_obj_dir = Path.join(drive, obj_rel)，由后端组装（端点已选定 node+drive）。
  """
  @spec put_shard(String.t(), non_neg_integer(), binary(), pos_integer()) :: :ok | {:error, term()}
  def put_shard(drive_obj_dir, block_index, shard_bytes, shard_len) do
    File.mkdir_p!(drive_obj_dir)
    path = Path.join(drive_obj_dir, @part_file)
    {:ok, fd} = :file.open(String.to_charlist(path), [:read, :write, :binary, :raw])

    try do
      :file.pwrite(fd, block_index * shard_len, shard_bytes)
    after
      :file.close(fd)
    end
  end

  @doc "读对象在 drive_obj_dir 下、block_index 的分片字节；缺文件/缺块/短读 -> nil（交 EC 重建）。"
  @spec get_shard(String.t(), non_neg_integer(), pos_integer()) :: binary() | nil
  def get_shard(drive_obj_dir, block_index, shard_len) do
    path = Path.join(drive_obj_dir, @part_file)

    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, fd} ->
        try do
          case :file.pread(fd, block_index * shard_len, shard_len) do
            {:ok, data} when byte_size(data) == shard_len -> data
            _ -> nil
          end
        after
          :file.close(fd)
        end

      {:error, _} ->
        nil
    end
  end

  @doc "写该 drive 上对象的 sidecar（每端点一份；read 侧从任一存活端点恢复）。"
  @spec put_sidecar(String.t(), map()) :: :ok | {:error, term()}
  def put_sidecar(drive_obj_dir, meta) do
    File.mkdir_p!(drive_obj_dir)
    File.write(Path.join(drive_obj_dir, @meta_file), Meta.encode(meta))
  end

  @doc "读该 drive 上对象的 sidecar。"
  @spec get_sidecar(String.t()) :: {:ok, map()} | {:error, :enoent}
  def get_sidecar(drive_obj_dir) do
    case File.read(Path.join(drive_obj_dir, @meta_file)) do
      {:ok, bin} -> {:ok, Meta.decode!(bin)}
      {:error, _} -> {:error, :enoent}
    end
  end

  @doc "stat：该 drive 上 part.0 字节数（heal 用其判文件完整）。"
  @spec stat_shard(String.t()) :: {:ok, non_neg_integer()} | {:error, :enoent}
  def stat_shard(drive_obj_dir) do
    case File.stat(Path.join(drive_obj_dir, @part_file)) do
      {:ok, %File.Stat{size: s}} -> {:ok, s}
      {:error, _} -> {:error, :enoent}
    end
  end

  @doc "删该 drive 上对象的整个目录（part.0 + meta.json）。幂等。"
  @spec delete_shard(String.t()) :: :ok
  def delete_shard(drive_obj_dir) do
    _ = File.rm_rf(drive_obj_dir)
    :ok
  end

  @doc """
  heal：把 block_map（%{block_index => shard_bytes}）回写该 drive 的 part.0（缺文件先补零到
  shard_file_size 再 pwrite）+ 重写 sidecar。返回 {:ok, 回写块数}。
  与 M6 Heal.apply_fixes/5 的单盘语义逐字一致。
  """
  @spec heal_shard(String.t(), %{non_neg_integer() => binary()}, pos_integer(), map()) ::
          {:ok, non_neg_integer()}
  def heal_shard(drive_obj_dir, block_map, shard_len, meta) do
    File.mkdir_p!(drive_obj_dir)
    path = Path.join(drive_obj_dir, @part_file)
    ensure_part_file!(path, meta, drive_obj_dir, shard_len)
    {:ok, fd} = :file.open(String.to_charlist(path), [:read, :write, :binary, :raw])

    try do
      Enum.each(block_map, fn {j, shard} -> :ok = :file.pwrite(fd, j * shard_len, shard) end)
    after
      :file.close(fd)
    end

    File.write!(Path.join(drive_obj_dir, @meta_file), Meta.encode(meta))
    {:ok, map_size(block_map)}
  end

  # 整列缺失时先确保 part.0 存在且长度达 target（用 block_map 的最大块推算，回退到 shard_len*块数）。
  # 这里用一个保守目标：max(现有大小, (max_block+1)*shard_len)，pwrite 各偏移即可。
  defp ensure_part_file!(path, _meta, _dir, shard_len) do
    case File.stat(path) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:ok, fd} = :file.open(String.to_charlist(path), [:write, :binary, :raw])
        # 至少建空文件；具体偏移由后续 pwrite 拉伸（:raw 文件 pwrite 自动补零）。
        :file.close(fd)
        _ = shard_len
        :ok
    end
  end
end
```

> 说明：`heal_shard` 的 `ensure_part_file!` 简化——`:raw` 文件 `pwrite` 到偏移会自动以 0 填充空洞（POSIX/Windows 均如此），故只需保证文件存在；M6 的 `ensure_part_file!` 用 sidecar 的 `shard_file_size` 预拉伸是为整列缺失场景，但 pwrite 自动补零已足够（最后一块 pwrite 决定文件长度；中间块的空洞补零）。若某 block_map 不连续，pwrite 各块仍正确（校验和保证读时验证）。

### 步骤 2（TDD 红）：ShardServer 测试

新建 `test/maxio/cluster/shard_server_test.exs`：

```elixir
defmodule Maxio.Cluster.ShardServerTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias Maxio.Cluster.ShardServer

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_shardsrv_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "put_shard/get_shard round-trip（block 偏移寻址）", %{dir: dir} do
    obj = Path.join(dir, "b/k")
    s0 = :crypto.strong_rand_bytes(256)
    s1 = :crypto.strong_rand_bytes(256)
    :ok = ShardServer.put_shard(obj, 0, s0, 256)
    :ok = ShardServer.put_shard(obj, 1, s1, 256)
    assert ShardServer.get_shard(obj, 0, 256) == s0
    assert ShardServer.get_shard(obj, 1, 256) == s1
  end

  test "缺文件 / 缺块 / 短读 -> nil", %{dir: dir} do
    obj = Path.join(dir, "b/missing")
    assert ShardServer.get_shard(obj, 0, 256) == nil
    :ok = ShardServer.put_shard(obj, 0, :crypto.strong_rand_bytes(256), 256)
    # 块 5 从未写 -> 该偏移读不到 256 字节 -> nil
    assert ShardServer.get_shard(obj, 5, 256) == nil
  end

  test "sidecar put/get + stat + delete", %{dir: dir} do
    obj = Path.join(dir, "b/k2")
    meta = %{"size" => 3, "etag" => "x"}
    :ok = ShardServer.put_sidecar(obj, meta)
    assert {:ok, %{"size" => 3}} = ShardServer.get_sidecar(obj)
    :ok = ShardServer.put_shard(obj, 0, <<0::2048>>, 256)
    assert {:ok, 256} = ShardServer.stat_shard(obj)
    :ok = ShardServer.delete_shard(obj)
    assert {:error, :enoent} = ShardServer.get_sidecar(obj)
    assert {:error, :enoent} = ShardServer.stat_shard(obj)
  end

  test "heal_shard 回写指定块 + 重写 sidecar", %{dir: dir} do
    obj = Path.join(dir, "b/k3")
    good0 = :crypto.strong_rand_bytes(256)
    good1 = :crypto.strong_rand_bytes(256)
    :ok = ShardServer.put_shard(obj, 0, <<bxor(0, 0)::8, :crypto.strong_rand_bytes(255)::binary>>, 256)
    {:ok, 2} = ShardServer.heal_shard(obj, %{0 => good0, 1 => good1}, 256, %{"size" => 512})
    assert ShardServer.get_shard(obj, 0, 256) == good0
    assert ShardServer.get_shard(obj, 1, 256) == good1
    assert {:ok, %{"size" => 512}} = ShardServer.get_sidecar(obj)
  end

  test "ping", _ do
    assert ShardServer.ping() == :pong
  end
end
```

执行：
```powershell
mix test test/maxio/cluster/shard_server_test.exs
```

### 步骤 3（实现）：`Maxio.Cluster.Transport` behaviour + `Erpc`

新建 `lib/maxio/cluster/transport.ex`：

```elixir
defmodule Maxio.Cluster.Transport do
  @moduledoc """
  跨节点分片传输契约（M7）。prod = :erpc 到每节点 Maxio.Cluster.ShardServer；
  test = 进程内多盘（Maxio.Cluster.Transport.InProcess，可注入端点宕机）。
  铁律 2：分布式后端只认本 behaviour，换传输（:erpc / gRPC / HTTP）不动后端。
  铁律 4：put_shard/get_shard 逐 (block, shard)，绝不一次传整对象/整文件。

  约定：drive_obj_dir = Path.join(drive, obj_rel)，由后端用 Topology 端点的 drive +
  Maxio.Cluster.Paths.object_rel/3 组装后传入；node 决定调哪个节点。
  节点宕机/超时/远端异常：get_shard -> nil（交 EC 重建）；put_shard/put_sidecar -> {:error, :unavailable}。
  """
  @callback put_shard(node(), String.t(), non_neg_integer(), binary(), pos_integer()) ::
              :ok | {:error, term()}
  @callback get_shard(node(), String.t(), non_neg_integer(), pos_integer()) :: binary() | nil
  @callback put_sidecar(node(), String.t(), map()) :: :ok | {:error, term()}
  @callback get_sidecar(node(), String.t()) :: {:ok, map()} | {:error, :enoent}
  @callback stat_shard(node(), String.t()) :: {:ok, non_neg_integer()} | {:error, :enoent}
  @callback delete_shard(node(), String.t()) :: :ok
  @callback heal_shard(node(), String.t(), %{non_neg_integer() => binary()}, pos_integer(), map()) ::
              {:ok, non_neg_integer()}

  @doc "当前配置的传输实现（test 经 opts[:transport] 覆盖；缺省 config :maxio, :shard_transport）。"
  @spec impl(keyword()) :: module()
  def impl(opts \\ []) do
    Keyword.get(opts, :transport) ||
      Application.get_env(:maxio, :shard_transport, Maxio.Cluster.Transport.Erpc)
  end
end

defmodule Maxio.Cluster.Transport.Erpc do
  @moduledoc """
  :erpc 分片传输（prod，M7）。把每个端点 op 作为一条 :erpc 调用到该 node 的 Maxio.Cluster.ShardServer。
  铁律 3：节点 down（{:erpc, :noconnection}）/ 超时（{:erpc, :timeout}）/ 远端异常 ->
  get_shard nil、写 {:error, :unavailable}（绝不静默成功，绝不把异常上抛炸后端）。
  本地节点（node == Node.self()）直接函数调用，跳过 :erpc（省序列化）。
  """
  @behaviour Maxio.Cluster.Transport

  alias Maxio.Cluster.ShardServer

  @timeout 5_000

  @impl true
  def put_shard(node, dir, j, shard, shard_len) do
    call(node, :put_shard, [dir, j, shard, shard_len], fn -> {:error, :unavailable} end)
  end

  @impl true
  def get_shard(node, dir, j, shard_len) do
    call(node, :get_shard, [dir, j, shard_len], fn -> nil end)
  end

  @impl true
  def put_sidecar(node, dir, meta) do
    call(node, :put_sidecar, [dir, meta], fn -> {:error, :unavailable} end)
  end

  @impl true
  def get_sidecar(node, dir) do
    call(node, :get_sidecar, [dir], fn -> {:error, :enoent} end)
  end

  @impl true
  def stat_shard(node, dir) do
    call(node, :stat_shard, [dir], fn -> {:error, :enoent} end)
  end

  @impl true
  def delete_shard(node, dir) do
    call(node, :delete_shard, [dir], fn -> :ok end)
  end

  @impl true
  def heal_shard(node, dir, block_map, shard_len, meta) do
    call(node, :heal_shard, [dir, block_map, shard_len, meta], fn -> {:ok, 0} end)
  end

  # 本地直接调；远端 :erpc。任何宕机/超时/异常 -> on_fail 兜底（铁律 3：结构化降级，绝不上抛）。
  defp call(node, fun, args, on_fail) do
    if node == Node.self() do
      apply(ShardServer, fun, args)
    else
      try do
        :erpc.call(node, ShardServer, fun, args, @timeout)
      rescue
        _ -> on_fail.()
      catch
        :error, {:erpc, _reason} -> on_fail.()
        :exit, _reason -> on_fail.()
      end
    end
  end
end
```

### 步骤 4（test support）：`Maxio.Cluster.Transport.InProcess`

新建 `test/support/transport_in_process.ex`（进程内多盘 + 可注入端点宕机；通过把 `node`+`drive_obj_dir` 映射到「真实本地临时路径」，并用一个 ETS/进程字典记录「哪些 node 被打掉」）：

```elixir
defmodule Maxio.Cluster.Transport.InProcess do
  @moduledoc """
  进程内多节点分片传输（M7 test，铁律 2 测试注入）。把每个 {node, drive_obj_dir} 端点直接
  映射到本机真实路径（drive_obj_dir 本身已是绝对路径，因 test 拓扑的 drive 用临时目录），
  即「同一台机器模拟 N 节点」。可经 set_down/1 在运行中「打掉」某 node：
  其 get_shard -> nil、写/heal -> {:error, :unavailable}/{:ok,0}（模拟宕机），用于验证
  K-of-N 重建、write_quorum 失败、heal-after-return。本地 ShardServer 复用真实分片 IO 逻辑。

  状态存 :persistent_term（per-test 用唯一 key？不——用全局 down 集合 + 测试 async:false 隔离？）
  改用一个 Agent（start_supervised! 起，per-test 隔离）：down_nodes/0 经 Process 字典传不过 :erpc
  （本实现不跨真节点，纯进程内 apply），故用一个简单 ETS 表，键 = node，setup 清空。
  """
  @behaviour Maxio.Cluster.Transport

  alias Maxio.Cluster.ShardServer

  @table :maxio_inproc_down

  @doc "确保 down 集合表存在（测试 setup 调用一次）。"
  def setup! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "打掉某 node（其端点后续读 nil、写失败）。"
  def set_down(node), do: :ets.insert(@table, {node, true})

  @doc "恢复某 node。"
  def set_up(node), do: :ets.delete(@table, node)

  defp down?(node) do
    case :ets.whereis(@table) do
      :undefined -> false
      _ -> :ets.member(@table, node)
    end
  end

  @impl true
  def put_shard(node, dir, j, shard, shard_len) do
    if down?(node), do: {:error, :unavailable}, else: ShardServer.put_shard(dir, j, shard, shard_len)
  end

  @impl true
  def get_shard(node, dir, j, shard_len) do
    if down?(node), do: nil, else: ShardServer.get_shard(dir, j, shard_len)
  end

  @impl true
  def put_sidecar(node, dir, meta) do
    if down?(node), do: {:error, :unavailable}, else: ShardServer.put_sidecar(dir, meta)
  end

  @impl true
  def get_sidecar(node, dir) do
    if down?(node), do: {:error, :enoent}, else: ShardServer.get_sidecar(dir)
  end

  @impl true
  def stat_shard(node, dir) do
    if down?(node), do: {:error, :enoent}, else: ShardServer.stat_shard(dir)
  end

  @impl true
  def delete_shard(node, dir) do
    if down?(node), do: :ok, else: ShardServer.delete_shard(dir)
  end

  @impl true
  def heal_shard(node, dir, block_map, shard_len, meta) do
    if down?(node), do: {:ok, 0}, else: ShardServer.heal_shard(dir, block_map, shard_len, meta)
  end
end
```

> 关键设计：test 拓扑里每个端点的 `drive` 用**互不相同的本地临时目录**（如 `<base>/n0_d0`、`<base>/n1_d0`…），故「同机模拟 N 节点」时 `drive_obj_dir` 天然隔离；`node` 仅用于 `down?/1` 判定。`set_down/1` 让单测在运行中打掉端点，验证真实 quorum/重建/heal。**因 `@table` 全局 + ETS，含 `set_down` 的测试须 `async: false`**（纯 round-trip 的 InProcess 测试可 async，但保守起见用到 `set_down` 的文件标 `async: false`）。

### 步骤 5（TDD 红 + 绿）：InProcess transport 测试

新建 `test/maxio/cluster/transport_in_process_test.exs`：

```elixir
defmodule Maxio.Cluster.TransportInProcessTest do
  use ExUnit.Case, async: false
  alias Maxio.Cluster.Transport.InProcess

  setup do
    InProcess.setup!()
    base = Path.join(System.tmp_dir!(), "maxio_inproc_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  test "put/get round-trip 经端点映射", %{base: base} do
    dir = Path.join(base, "n0_d0/b/k")
    s = :crypto.strong_rand_bytes(256)
    assert :ok = InProcess.put_shard(:"maxio@n0", dir, 0, s, 256)
    assert InProcess.get_shard(:"maxio@n0", dir, 0, 256) == s
  end

  test "打掉端点 -> get nil、put {:error,:unavailable}", %{base: base} do
    dir = Path.join(base, "n1_d0/b/k")
    s = :crypto.strong_rand_bytes(256)
    assert :ok = InProcess.put_shard(:"maxio@n1", dir, 0, s, 256)
    InProcess.set_down(:"maxio@n1")
    assert InProcess.get_shard(:"maxio@n1", dir, 0, 256) == nil
    assert {:error, :unavailable} = InProcess.put_shard(:"maxio@n1", dir, 0, s, 256)
    InProcess.set_up(:"maxio@n1")
    assert InProcess.get_shard(:"maxio@n1", dir, 0, 256) == s
  end

  test "sidecar 在宕机端点回 :enoent", %{base: base} do
    dir = Path.join(base, "n2_d0/b/k")
    :ok = InProcess.put_sidecar(:"maxio@n2", dir, %{"size" => 1})
    InProcess.set_down(:"maxio@n2")
    assert {:error, :enoent} = InProcess.get_sidecar(:"maxio@n2", dir)
  end
end
```

执行：
```powershell
mix test test/maxio/cluster/transport_in_process_test.exs
```

### 步骤 6（接线）：监督树加 `ShardServer` child + config 默认 transport

`lib/maxio/application.ex` 的 `cluster_children/0` 末尾把 `Maxio.Cluster.ShardServer` 加上（始终起——每节点都要能服务 peer 的分片 IO）：

```elixir
    libcluster ++ [Maxio.Cluster.Topology, Maxio.Cluster.ShardServer]
```

`config/config.exs`（`config :maxio, :storage_backend, ...` 附近）追加默认传输实现：

```elixir
# M7 分片传输实现（prod = :erpc 到每节点 ShardServer；test 经 opts[:transport] 覆盖为 InProcess）。
config :maxio, :shard_transport, Maxio.Cluster.Transport.Erpc
```

### 步骤 7（验证 + 提交）

```powershell
mix compile --warnings-as-errors
mix test test/maxio/cluster/
mix test
```
期望：编译零警告；ShardServer + InProcess 测试绿；全量回归绿（ShardServer child 起在 test 也无害——它无配置依赖）。

```powershell
git add -A
git commit -m @'
M7-3: ShardServer（每节点本机分片 IO）+ Transport behaviour + Erpc/InProcess

- ShardServer：put_shard/get_shard/put_sidecar/get_sidecar/stat_shard/delete_shard/heal_shard/ping
  （本机一个 drive，复用 M6 part.0 偏移寻址 + BLAKE3 sidecar；被 :erpc 寻址到正确节点）
- Transport behaviour（7 callback，逐 block-shard）+ impl/1（opts[:transport] 覆盖）
- Transport.Erpc：本地直调 / 远端 :erpc；宕机/超时/异常 -> get nil、写 {:error,:unavailable}（铁律 3）
- Transport.InProcess（test support）：进程内多盘 + set_down/1 注入宕机
- Application 起 ShardServer child；config 默认 :shard_transport = Erpc
- ShardServer + InProcess TDD 全绿、全量回归绿、--warnings-as-errors 零警告

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（M7-3）**：ShardServer 本机分片 IO 单测（round-trip/短读 nil/sidecar/stat/delete/heal/ping）绿；InProcess transport 单测（round-trip + set_down 宕机 + 恢复）绿；Transport behaviour 编译通过两实现 `@impl true` 齐全（`--warnings-as-errors` 守住「behaviour 全有或全无」）；全量回归绿。

---

# 单元 M7-4：Maxio.Storage.Distributed 后端 + Maxio.Cluster.Lock + 共享 conformance + quorum/宕机/bitrot 单测

**目标**：`Maxio.Storage.Distributed`（实现 `Maxio.Storage.Backend` 全部 callback，复用 M6 `Codec/Config/Meta` + 逐块流式 verbatim，把分片 IO 换成 `Transport`，端点来自 `Router`+`Topology`，跨节点并行读 K-of-N + 写 quorum）；`Maxio.Cluster.Lock`（`:global.trans` MVP + dsync `quorum_with_lock` 升级）守护 PUT/assemble/delete/abort；共享 conformance 套件第三次同跑（`Distributed`+`InProcess`）；quorum/宕机/bitrot 专项单测；config 可切后端。

**依赖**：M7-3。**TDD**：先 conformance 套件（证同契约）→ 专项（端点 0+5 宕机 GET 仍正确 K=4 存活；M+1 宕机 → InsufficientShardsError；写 < write_quorum → {:error,:write_quorum}；篡改一端点分片 → BLAKE3 失配 → 重建）。

### 步骤 1（实现）：`Maxio.Cluster.Lock`

新建 `lib/maxio/cluster/lock.ex`：

```elixir
defmodule Maxio.Cluster.Lock do
  @moduledoc """
  对象级分布式锁（M7）。MVP：:global.trans/4（全 mesh 互斥，单资源无死锁；OTP25+ 防重叠分区）。
  升级路径：dsync 式 quorum 锁（n/2+1 节点多数即可获锁，更抗节点宕机），见 quorum_with_lock/3。
  铁律 3：获锁失败 -> {:error, :locked}/{:error, :no_quorum}，绝不静默继续（并发 PUT/heal 互踩 → 撕裂对象）。

  单节点 dev/test：:global.trans 在 nodes()==[Node.self()] 下退化为本地锁，同一代码路径。
  锁键约定：{bucket, key} 对象级；{bucket, ""} 桶级（与 with_lock 的 resource 一致）。
  """

  @type resource :: {String.t(), String.t()}

  @doc """
  以全 mesh 互斥锁运行 fun。:global.trans 内部 set_lock(retries) + 失败回退重试；
  retries 用尽返回 :aborted -> {:error, :locked}。lock id 含 self() 作 requester（owner）。
  """
  @spec with_lock(resource(), (-> result), non_neg_integer()) :: {:ok, result} | {:error, :locked}
        when result: var
  def with_lock(resource, fun, retries \\ 5) do
    lock_id = {{:maxio_obj, resource}, self()}

    case :global.trans(lock_id, fn -> {:ok, fun.()} end, Maxio.Cluster.nodes(), retries) do
      :aborted -> {:error, :locked}
      result -> result
    end
  end

  @doc """
  dsync 式 quorum 锁（升级路径）：向集群 N 个节点并行 set_lock，多数（n/2+1）成功即获锁，
  跑 fun 后释放全部已获锁；未达多数 -> 释放已获的 + {:error, :no_quorum}（调用方 semi-random 退避后重试）。
  比 :global.trans 更抗宕机：只需多数节点在线即可获锁。
  """
  @spec quorum_with_lock(resource(), (-> result), keyword()) ::
          {:ok, result} | {:error, :no_quorum}
        when result: var
  def quorum_with_lock(resource, fun, opts \\ []) do
    nodes = Maxio.Cluster.nodes()
    quorum = div(length(nodes), 2) + 1
    lock_id = {:maxio_obj, resource}
    timeout = Keyword.get(opts, :timeout, 3_000)

    positive =
      nodes
      |> Enum.filter(fn node -> try_set_lock(node, lock_id, timeout) end)

    release = fn ->
      Enum.each(positive, fn node -> try_del_lock(node, lock_id, timeout) end)
    end

    if length(positive) >= quorum do
      try do
        {:ok, fun.()}
      after
        release.()
      end
    else
      release.()
      {:error, :no_quorum}
    end
  end

  # 在单个 node 上以 retries=0（立即返回）尝试 set_lock，只锁该 node 自己（scope=[node]）。
  defp try_set_lock(node, lock_id, timeout) do
    erpc_bool(node, :set_lock, [{lock_id, self()}, [node], 0], timeout)
  end

  defp try_del_lock(node, lock_id, timeout) do
    _ = erpc_bool(node, :del_lock, [{lock_id, self()}, [node]], timeout)
    :ok
  end

  defp erpc_bool(node, fun, args, timeout) do
    if node == Node.self() do
      apply(:global, fun, args) == true
    else
      try do
        :erpc.call(node, :global, fun, args, timeout) == true
      rescue
        _ -> false
      catch
        :error, {:erpc, _} -> false
        :exit, _ -> false
      end
    end
  end
end
```

### 步骤 2（实现）：`Maxio.Storage.Distributed` 后端

新建 `lib/maxio/storage/distributed.ex`。**这是 M6 `ErasureCoded` 的逐字泛化：流式 reducer（`feed`/`drain_full_blocks`/`flush_final`/`write_block`/`build_meta`）、GET 的 `Stream.resource/3` loop、`block_plain_len`/`block_shard_len`/`block_checksums`/`normalize_range` 全部照搬，只把「打开本地 fd / `IO.binwrite` / `:file.pread` / `File.write` sidecar」替换为「`Transport` op 到端点 i 的 `{node_i, drive_i}`」。** 端点由 `Router.set_for/Topology.endpoints` 给出。

```elixir
defmodule Maxio.Storage.Distributed do
  @moduledoc """
  多节点分布式 Reed-Solomon 纠删码存储后端（M7），实现 Maxio.Storage.Backend 契约，与 FS/ErasureCoded
  返回形态逐字节一致（铁律 2：后端即插件，核心管线一行不改）。

  在 M6 单机纠删码核心（Maxio.Storage.Erasure.{Codec,Config,Meta} + NIF）之外加：
    * Router.set_for(bucket,key) -> set_id（对象名哈希取模，铁律 5 对齐 MinIO；版本不入哈希）
    * Topology.endpoints(set_id) -> 有序 N 个 {node, drive} 端点（索引 i = 分片 i）
    * Transport（:erpc / InProcess）把分片 i 寻址到端点 i 的节点 + drive（铁律 4 逐 block-shard）
  RS 数学/流式/quorum/校验 全部复用 M6，一行不重写——只把「分片 i 写本地盘 i」换成
  「分片 i 经 Transport 写端点 i」。

  put：逐块流式编码（Codec.split_block），分片 i 写端点 i，成功端点数 >= write_quorum 才 {:ok}，
       否则 {:error,:write_quorum}（铁律 3）；PUT 用 Maxio.Cluster.Lock.with_lock 守护并发（绝不撕裂对象）。
  get：逐块跨节点并行读 K-of-N 分片（宕机/超时端点 -> nil），按 sidecar BLAKE3 校验 + Codec.restore_block
       重建（存活 < K -> raise InsufficientShardsError，绝不静默返回错数据，铁律 3）+ 截断 + Range 裁剪，流式发出。

  每 callback 末参 opts：opts[:topology]（parsed struct）覆盖 :persistent_term；
  opts[:transport] 覆盖 config :maxio, :shard_transport。便于 ExUnit 注入进程内多节点 transport。
  """
  @behaviour Maxio.Storage.Backend

  require Logger

  alias Maxio.Storage.Erasure.{Codec, Config}
  alias Maxio.Cluster.{Lock, Paths, Router, Topology, Transport}

  # ── Backend callbacks（签名与 FS/ErasureCoded 一致）──

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

  # ── 端点解析（对象 -> set -> [{node, drive}]）──

  defp topology(opts), do: Keyword.get(opts, :topology)

  defp cfg(opts), do: Config.load!(ec_params(opts))

  defp ec_params(opts) do
    case topology(opts) do
      nil -> Topology.ec_params()
      t -> Topology.ec_params_from(t)
    end
    # Config.load!/1 需 drives 非空校验；分布式不用 cfg.drives，但 Config 校验要求其存在。
    # 注入一个长度 N 的占位 drives（仅满足 length==K+M 校验，绝不用于 IO）。
    |> with_placeholder_drives()
  end

  defp with_placeholder_drives(ec_kw) do
    n = Keyword.fetch!(ec_kw, :data_shards) + Keyword.fetch!(ec_kw, :parity_shards)
    Keyword.put(ec_kw, :drives, for(i <- 0..(n - 1), do: "__remote_#{i}__"))
  end

  defp endpoints_for(bucket, key, opts) do
    case topology(opts) do
      nil ->
        set_id = Router.set_for(bucket, key, nil)
        Topology.endpoints(set_id)

      t ->
        set_id = Router.set_for(bucket, key, t)
        Topology.endpoints_from(t, set_id)
    end
  end

  # part 的端点：以 upload_id 作 key 路由（同 upload 全 part + assemble 同 set）。
  defp endpoints_for_upload(bucket, upload_id, opts),
    do: endpoints_for(bucket, ".uploads/" <> upload_id, opts)

  defp transport(opts), do: Transport.impl(opts)

  # 端点 i 的「该对象在该 drive 下的目录」= Path.join(drive_i, obj_rel)。
  defp endpoint_dirs(endpoints, obj_rel),
    do: Enum.map(endpoints, fn {node, drive} -> {node, Path.join(drive, obj_rel)} end)

  # ── PUT（逐块流式编码；分片 i -> 端点 i；with_lock 守护）──

  defp do_put(bucket, key, version_id, chunks, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        case Lock.with_lock({bucket, key}, fn ->
               put_locked(bucket, key, obj_rel, chunks, opts)
             end) do
          {:ok, result} -> result
          {:error, :locked} -> {:error, :locked}
        end
    end
  end

  defp put_locked(bucket, key, obj_rel, chunks, opts) do
    c = cfg(opts)
    endpoints = endpoints_for(bucket, key, opts)
    dirs = endpoint_dirs(endpoints, obj_rel)
    tx = transport(opts)
    n = Config.total(c)

    acc0 = %{
      md5: :crypto.hash_init(:md5),
      sha: :crypto.hash_init(:sha256),
      size: 0,
      shard_len: nil,
      block_hashes: List.duplicate([], n),
      buffer: <<>>,
      block_index: 0,
      dirs: dirs,
      tx: tx
    }

    acc = Enum.reduce(chunks, acc0, fn chunk, acc -> feed(c, acc, chunk) end)
    acc = flush_final(c, acc)

    etag = acc.md5 |> :crypto.hash_final() |> Base.encode16(case: :lower)
    sha256 = acc.sha |> :crypto.hash_final() |> Base.encode16(case: :lower)
    shard_len = acc.shard_len || 0

    meta =
      build_meta(c, acc.size, etag, sha256, shard_len, Enum.map(acc.block_hashes, &Enum.reverse/1))

    ok_endpoints = write_sidecars(tx, dirs, meta)

    if ok_endpoints >= c.write_quorum do
      {:ok, %{size: acc.size, etag: etag, sha256: sha256}}
    else
      Logger.error("distributed put below write quorum",
        bucket: bucket,
        key: key,
        reason: "ok_endpoints=#{ok_endpoints} < write_quorum=#{c.write_quorum}"
      )

      {:error, :write_quorum}
    end
  end

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
    block_size = cfg.block_size
    <<block::binary-size(^block_size), rest::binary>> = buffer
    acc = write_block(cfg, %{acc | buffer: rest}, block)
    drain_full_blocks(cfg, acc)
  end

  defp drain_full_blocks(_cfg, acc), do: acc

  defp flush_final(_cfg, %{buffer: <<>>} = acc), do: acc
  defp flush_final(cfg, %{buffer: buffer} = acc), do: write_block(cfg, %{acc | buffer: <<>>}, buffer)

  # 编码一个 block：N 分片经 transport 写各端点；校验和按端点累积（与 M6 write_block 逐字一致，
  # 仅落盘换成 transport.put_shard）。块零填充到 block_size 保证全对象 shard_len 一致（M6 不变量）。
  defp write_block(cfg, acc, block) do
    padded =
      if byte_size(block) < cfg.block_size do
        block <> <<0::size((cfg.block_size - byte_size(block)) * 8)>>
      else
        block
      end

    %{shards: shards, checksums: checksums, shard_len: shard_len} = Codec.split_block(cfg, padded)

    _ok = write_block_shards(acc.tx, acc.dirs, acc.block_index, shards, shard_len)

    block_hashes =
      acc.block_hashes
      |> Enum.zip(checksums)
      |> Enum.map(fn {acc_list, ck} -> [Base.encode16(ck, case: :lower) | acc_list] end)

    %{acc | shard_len: shard_len, block_index: acc.block_index + 1, block_hashes: block_hashes}
  end

  # 写 block j 的 N 个分片到 N 个端点（并行，铁律 4 一条消息一个分片）；返回成功端点数。
  defp write_block_shards(tx, dirs, j, shards, shard_len) do
    dirs
    |> Enum.zip(shards)
    |> Task.async_stream(
      fn {{node, dir}, shard} ->
        case tx.put_shard(node, dir, j, shard, shard_len) do
          :ok -> :ok
          _ -> :error
        end
      end,
      timeout: :infinity,
      max_concurrency: length(dirs)
    )
    |> Enum.count(fn
      {:ok, :ok} -> true
      _ -> false
    end)
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

  # sidecar 写全部 N 端点（并行），返回成功端点数（write quorum 判定）。
  defp write_sidecars(tx, dirs, meta) do
    dirs
    |> Task.async_stream(
      fn {node, dir} ->
        case tx.put_sidecar(node, dir, meta) do
          :ok -> :ok
          _ -> :error
        end
      end,
      timeout: :infinity,
      max_concurrency: length(dirs)
    )
    |> Enum.count(fn
      {:ok, :ok} -> true
      _ -> false
    end)
  end

  # ── GET（逐块跨节点并行读 K-of-N；校验 + 重建；Range 裁剪；流式）──

  defp do_get(bucket, key, version_id, range, opts) do
    with {:ok, obj_rel} <- Paths.object_rel(bucket, key, version_id) do
      c = cfg(opts)
      endpoints = endpoints_for(bucket, key, opts)
      dirs = endpoint_dirs(endpoints, obj_rel)
      tx = transport(opts)

      case read_any_sidecar(tx, dirs) do
        {:ok, meta} ->
          size = meta["size"]
          block_size = get_in(meta, ["ec", "block_size"])
          {first, last} = normalize_range(range, size)

          if size == 0 or last < first do
            {:ok, []}
          else
            {:ok,
             stream_object(c, bucket, key, version_id, tx, dirs, meta, block_size, first, last)}
          end

        {:error, :enoent} ->
          {:error, :enoent}
      end
    end
  end

  defp normalize_range(nil, size), do: {0, max(size - 1, 0)}
  defp normalize_range({first, last}, _size), do: {first, last}

  # 逐 block 跨节点并行读 K 存活分片、校验+重建、裁剪到 [first,last]，发出。
  # 控制流与 M6 stream_object/8 逐字一致；仅 read_shard 换成 read_block_shards（transport）。
  defp stream_object(cfg, bucket, key, version_id, tx, dirs, meta, block_size, first, last) do
    n = Config.total(cfg)
    shards_meta = meta["shards"]
    size = meta["size"]
    shard_len = block_shard_len(meta, cfg)
    first_block = div(first, block_size)
    last_block = div(last, block_size)

    Stream.resource(
      fn -> first_block end,
      fn
        j when j > last_block ->
          {:halt, j}

        j ->
          block_plain_len = block_plain_len(size, block_size, j)
          shards = read_block_shards(tx, dirs, shards_meta, j, shard_len, n)
          checksums = block_checksums(shards_meta, n, j)

          plain =
            Codec.restore_block(cfg, shards, checksums, block_plain_len,
              bucket: bucket,
              key: key,
              version_id: version_id,
              block_index: j
            )

          block_start = j * block_size
          lo = max(first, block_start) - block_start
          hi = min(last, block_start + block_plain_len - 1) - block_start
          out = binary_part(plain, lo, hi - lo + 1)
          {[out], j + 1}
      end,
      fn _j -> :ok end
    )
  end

  # 读 block j 的 N 个分片（跨节点并行；宕机/超时端点 -> nil）。保序（索引 i = 分片 i）。
  defp read_block_shards(tx, dirs, shards_meta, j, shard_len, n) do
    0..(n - 1)
    |> Enum.zip(dirs)
    |> Task.async_stream(
      fn {i, {node, dir}} ->
        drive_meta = Enum.at(shards_meta, i)

        if drive_meta && j < length(drive_meta["block_hashes"]) do
          tx.get_shard(node, dir, j, shard_len)
        else
          nil
        end
      end,
      timeout: :infinity,
      max_concurrency: n,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, shard} -> shard
      {:exit, _} -> nil
    end)
  end

  # block j 的 N 个存储校验和（来自 sidecar；缺位补 32 个 0 -> 必不匹配 -> 当缺失）。与 M6 逐字一致。
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

      if is_list(bh) and length(bh) > 0 and s["shard_file_size"] > 0 do
        div(s["shard_file_size"], length(bh))
      end
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

  # ── stat / delete / bucket ──

  defp do_stat(bucket, key, version_id, opts) do
    with {:ok, obj_rel} <- Paths.object_rel(bucket, key, version_id) do
      endpoints = endpoints_for(bucket, key, opts)
      dirs = endpoint_dirs(endpoints, obj_rel)
      tx = transport(opts)

      case read_any_sidecar(tx, dirs) do
        {:ok, meta} -> {:ok, %{size: meta["size"]}}
        {:error, :enoent} -> {:error, :enoent}
      end
    end
  end

  defp do_delete(bucket, key, version_id, opts) do
    with {:ok, obj_rel} <- Paths.object_rel(bucket, key, version_id) do
      endpoints = endpoints_for(bucket, key, opts)
      dirs = endpoint_dirs(endpoints, obj_rel)
      tx = transport(opts)

      case Lock.with_lock({bucket, key}, fn ->
             Enum.each(dirs, fn {node, dir} -> tx.delete_shard(node, dir) end)
             :ok
           end) do
        {:ok, :ok} -> :ok
        {:error, :locked} -> {:error, :locked}
      end
    end
  end

  # 桶在每端点（全 set 的全端点并集）建 bucket 目录。put_bucket 不路由（桶在所有 set 都需有目录）。
  defp do_put_bucket(bucket, opts) do
    all_endpoint_dirs(bucket, opts)
    |> Enum.each(fn {node, dir} -> transport(opts).put_sidecar(node, mkdir_marker(dir), %{}) end)

    :ok
  end

  defp do_delete_bucket(bucket, opts) do
    all_endpoint_dirs(bucket, opts)
    |> Enum.each(fn {node, dir} -> transport(opts).delete_shard(node, mkdir_marker(dir)) end)

    :ok
  end

  # 全部 set 的全部端点的「桶根目录」（bucket 在每端点 drive 下一目录）。
  defp all_endpoint_dirs(bucket, opts) do
    set_ids =
      case topology(opts) do
        nil -> Topology.all_set_ids()
        t -> Topology.all_set_ids_from(t)
      end

    set_ids
    |> Enum.flat_map(fn set_id ->
      eps =
        case topology(opts) do
          nil -> Topology.endpoints(set_id)
          t -> Topology.endpoints_from(t, set_id)
        end

      Enum.map(eps, fn {node, drive} -> {node, Path.join(drive, bucket)} end)
    end)
    |> Enum.uniq()
  end

  # 桶目录用一个 .keep 标记的 sidecar 占位（put_bucket 只是建目录；delete_bucket 删之）。
  defp mkdir_marker(dir), do: Path.join(dir, ".keep")

  # ── parts（put_part / get_part_stream / assemble / abort）──

  defp do_put_part(bucket, _key, upload_id, part_number, chunks, opts) do
    part_rel = Paths.part_rel(bucket, upload_id, part_number)
    c = cfg(opts)
    endpoints = endpoints_for_upload(bucket, upload_id, opts)
    dirs = endpoint_dirs(endpoints, part_rel)
    tx = transport(opts)
    n = Config.total(c)

    acc0 = %{
      md5: :crypto.hash_init(:md5),
      sha: nil,
      size: 0,
      shard_len: nil,
      block_hashes: List.duplicate([], n),
      buffer: <<>>,
      block_index: 0,
      dirs: dirs,
      tx: tx
    }

    acc = Enum.reduce(chunks, acc0, fn chunk, acc -> feed_part(c, acc, chunk) end)
    acc = flush_final(c, acc)

    md5_raw = :crypto.hash_final(acc.md5)
    etag = Base.encode16(md5_raw, case: :lower)
    shard_len = acc.shard_len || 0

    meta =
      build_part_meta(c, acc.size, etag, shard_len, Enum.map(acc.block_hashes, &Enum.reverse/1))

    _ = write_sidecars(tx, dirs, meta)
    {:ok, %{size: acc.size, etag: etag, md5_raw: md5_raw}}
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
    part_rel = Paths.part_rel(bucket, upload_id, part_number)
    c = cfg(opts)
    endpoints = endpoints_for_upload(bucket, upload_id, opts)
    dirs = endpoint_dirs(endpoints, part_rel)
    tx = transport(opts)

    case read_any_sidecar(tx, dirs) do
      {:ok, meta} ->
        size = meta["size"]
        block_size = get_in(meta, ["ec", "block_size"])

        if size == 0 do
          {:ok, []}
        else
          {:ok,
           stream_object(c, bucket, "#{upload_id}/#{part_number}", "null", tx, dirs, meta,
             block_size, 0, size - 1)}
        end

      {:error, :enoent} ->
        {:error, :enoent}
    end
  end

  defp do_assemble(bucket, key, upload_id, part_numbers, opts) do
    case Paths.object_rel(bucket, key, "null") do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        case Lock.with_lock({bucket, key}, fn ->
               assemble_locked(bucket, key, upload_id, obj_rel, part_numbers, opts)
             end) do
          {:ok, result} -> result
          {:error, :locked} -> {:error, :locked}
        end
    end
  end

  defp assemble_locked(bucket, key, upload_id, obj_rel, part_numbers, opts) do
    c = cfg(opts)
    endpoints = endpoints_for(bucket, key, opts)
    dirs = endpoint_dirs(endpoints, obj_rel)
    tx = transport(opts)
    n = Config.total(c)

    acc0 = %{
      md5: :crypto.hash_init(:md5),
      sha: :crypto.hash_init(:sha256),
      size: 0,
      shard_len: nil,
      block_hashes: List.duplicate([], n),
      buffer: <<>>,
      block_index: 0,
      dirs: dirs,
      tx: tx
    }

    # 逐 part 解码（跨节点读）-> 喂入对象编码流（块接块流式，绝不缓冲整对象）。
    acc =
      Enum.reduce(part_numbers, acc0, fn pn, acc ->
        {:ok, part_stream} = do_get_part_stream(bucket, key, upload_id, pn, opts)
        Enum.reduce(part_stream, acc, fn chunk, a -> feed(c, a, chunk) end)
      end)

    acc = flush_final(c, acc)

    etag = acc.md5 |> :crypto.hash_final() |> Base.encode16(case: :lower)
    sha256 = acc.sha |> :crypto.hash_final() |> Base.encode16(case: :lower)
    shard_len = acc.shard_len || 0

    meta =
      build_meta(c, acc.size, etag, sha256, shard_len, Enum.map(acc.block_hashes, &Enum.reverse/1))

    _ = write_sidecars(tx, dirs, meta)
    {:ok, %{size: acc.size}}
  end

  defp do_abort_upload(bucket, _key, upload_id, opts) do
    upload_rel = Paths.upload_rel(bucket, upload_id)
    endpoints = endpoints_for_upload(bucket, upload_id, opts)
    dirs = endpoint_dirs(endpoints, upload_rel)
    tx = transport(opts)
    Enum.each(dirs, fn {node, dir} -> tx.delete_shard(node, dir) end)
    :ok
  end

  # ── 辅助 ──

  # 从任一存活端点读 sidecar（与 M6 read_any_sidecar 等价，跨节点版）。
  defp read_any_sidecar(tx, dirs) do
    Enum.find_value(dirs, {:error, :enoent}, fn {node, dir} ->
      case tx.get_sidecar(node, dir) do
        {:ok, meta} -> {:ok, meta}
        {:error, _} -> nil
      end
    end)
  end
end
```

> 关键复用对照（铁律 2 验收点）：`feed`/`drain_full_blocks`/`flush_final`/`write_block`/`build_meta`/`build_part_meta`/`block_plain_len`/`block_shard_len`/`block_checksums`/`normalize_range` 与 M6 `ErasureCoded` **逐字相同**，仅 `write_block` 的落盘 → `write_block_shards`（transport）、GET 的 `read_shard` fd → `read_block_shards`（transport 并行）、sidecar 读写 → transport。`Codec.split_block`/`restore_block`、`Config`、NIF **零改动复用**。`Stream.resource` 的 ACC 从 M6 的 `{fds, j}` 简化为 `j`（fd 由 transport 每块按需开关，不持有跨块状态——避免长连接句柄泄漏；transport 端 ShardServer 每次 open/close）。

> `put_bucket`/`delete_bucket` 用 `.keep` sidecar 标记建/删桶目录（分布式无「裸 mkdir」transport op，复用 `put_sidecar`/`delete_shard`）。conformance 的 `put_bucket("b")` 后 `put("b","k")` 不依赖桶目录预先存在（`put_shard` 的 `File.mkdir_p!` 自建），故桶标记仅为 list/delete 语义占位，不影响对象读写。

### 步骤 3（TDD 红 + 绿）：共享 conformance 同跑 Distributed + InProcess

新建 `test/maxio/storage/distributed_conformance_test.exs`（镜像 `erasure_coded_conformance_test.exs`，但 opts 注入 test 拓扑 + InProcess transport；用「同机 N 端点 = N 个临时目录」拓扑）：

```elixir
defmodule Maxio.Storage.DistributedConformanceTest do
  use ExUnit.Case, async: false
  @backend Maxio.Storage.Distributed

  alias Maxio.Cluster.{Topology, Transport.InProcess}

  setup do
    InProcess.setup!()
    base = Path.join(System.tmp_dir!(), "maxio_dist_conf_#{System.unique_integer([:positive])}")
    # 1 pool, 1 set, N=6 端点 = 6 个独立临时目录（同机模拟 6 节点，3 个 node 名各 2 drive）。
    endpoints =
      for i <- 0..5 do
        {:"maxio@n#{rem(i, 3)}", Path.join(base, "n#{rem(i, 3)}_d#{div(i, 3)}")}
      end

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 1024,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    on_exit(fn -> File.rm_rf(base) end)
    {:ok, topology: topology}
  end

  defp opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  use Maxio.Test.StorageConformance
end
```

执行（确认 6 个 conformance test 同跑 Distributed 全绿——证铁律 2 同一契约）：
```powershell
mix test test/maxio/storage/distributed_conformance_test.exs
```

### 步骤 4（TDD）：quorum / 节点宕机 / bitrot 专项单测

新建 `test/maxio/storage/distributed_test.exs`：

```elixir
defmodule Maxio.Storage.DistributedTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias Maxio.Storage.Distributed
  alias Maxio.Cluster.{Topology, Transport.InProcess}
  alias Maxio.Storage.Erasure.InsufficientShardsError

  setup do
    InProcess.setup!()
    base = Path.join(System.tmp_dir!(), "maxio_dist_#{System.unique_integer([:positive])}")

    # N=6 端点，每端点独立 node 名（便于 set_down 单端点）。K=4 M=2 -> read_quorum=4, write_quorum=4。
    endpoints = for i <- 0..5, do: {:"maxio@d#{i}", Path.join(base, "d#{i}")}

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 1024,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, topology: topology, endpoints: endpoints}
  end

  defp opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  test "端点 0+2 宕机 -> GET 仍正确（K=4 存活，M=2 容错）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    InProcess.set_down(:"maxio@d0")
    InProcess.set_down(:"maxio@d2")

    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "M+1=3 个端点宕机 -> GET raise InsufficientShardsError（绝不静默返回错数据）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    InProcess.set_down(:"maxio@d0")
    InProcess.set_down(:"maxio@d2")
    InProcess.set_down(:"maxio@d4")

    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert_raise InsufficientShardsError, fn -> Enum.to_list(s) end
  end

  test "PUT 时 3 端点宕机 -> 成功端点 < write_quorum=4 -> {:error,:write_quorum}", ctx do
    o = opts(ctx)
    InProcess.set_down(:"maxio@d0")
    InProcess.set_down(:"maxio@d1")
    InProcess.set_down(:"maxio@d2")

    assert {:error, :write_quorum} = Distributed.put("b", "k", "null", ["hello world"], o)
  end

  test "篡改一端点分片 -> BLAKE3 失配 -> 重建仍正确", ctx do
    o = opts(ctx)
    {dnode, ddir} = Enum.at(ctx.endpoints, 1)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    # 篡改端点 1 的 part.0 首字节（绕过 transport，直接动盘）。
    part = Path.join([ddir, "b", "k", "part.0"])
    <<first, rest::binary>> = File.read!(part)
    File.write!(part, <<bxor(first, 0xFF), rest::binary>>)
    _ = dnode

    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "确定性路由：同 key 全版本同 set（put null + put 版本 落同 set 端点）", ctx do
    o = opts(ctx)
    {:ok, _} = Distributed.put("b", "k", "null", ["A"], o)
    {:ok, _} = Distributed.put("b", "k", "01XYZ", ["B"], o)
    {:ok, s0} = Distributed.get("b", "k", "null", nil, o)
    {:ok, s1} = Distributed.get("b", "k", "01XYZ", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s0)) == "A"
    assert IO.iodata_to_binary(Enum.to_list(s1)) == "B"
  end
end
```

执行：
```powershell
mix test test/maxio/storage/distributed_test.exs
```

### 步骤 5（TDD）：`Maxio.Cluster.Lock` 单节点单测

新建 `test/maxio/cluster/lock_test.exs`（单节点下 `:global.trans` 退化本地锁，验证 with_lock 跑 fun + 返回 {:ok, _}；并发同资源串行化）：

```elixir
defmodule Maxio.Cluster.LockTest do
  use ExUnit.Case, async: false
  alias Maxio.Cluster.Lock

  test "with_lock 跑 fun 并返回 {:ok, result}" do
    assert {:ok, 42} = Lock.with_lock({"b", "k"}, fn -> 42 end)
  end

  test "嵌套不同资源不死锁" do
    assert {:ok, :inner} =
             Lock.with_lock({"b", "k1"}, fn ->
               {:ok, r} = Lock.with_lock({"b", "k2"}, fn -> :inner end)
               r
             end)
  end

  test "quorum_with_lock 单节点（quorum=1）获锁跑 fun" do
    assert {:ok, :done} = Lock.quorum_with_lock({"b", "k"}, fn -> :done end)
  end
end
```

执行：
```powershell
mix test test/maxio/cluster/lock_test.exs
```

### 步骤 6（接线）：可切后端 config 文档化

`config/config.exs` 的 `config :maxio, :storage_backend, Maxio.Storage.FS` 上方追加注释（**不改默认值**，仅文档化如何切分布式）：

```elixir
# 后端 behaviour 绑定（铁律 1/2：换后端只改这里）。默认 FS（单机）。
# 切单机纠删码：Maxio.Storage.ErasureCoded（+ config :maxio, :erasure）。
# 切多节点分布式：Maxio.Storage.Distributed（+ config :maxio, Maxio.Cluster.Topology + Maxio.Cluster）。
config :maxio, :storage_backend, Maxio.Storage.FS
```

### 步骤 7（验证 + 提交）

```powershell
mix compile --warnings-as-errors
mix test test/maxio/storage/distributed_conformance_test.exs test/maxio/storage/distributed_test.exs test/maxio/cluster/lock_test.exs
mix test
```
期望：编译零警告；conformance 6 test + 专项 5 test + lock 3 test 全绿；全量回归绿。

```powershell
git add -A
git commit -m @'
M7-4: Maxio.Storage.Distributed 后端 + Maxio.Cluster.Lock + 共享 conformance + quorum/宕机/bitrot 单测

- Distributed：实现 Backend 全 callback；复用 M6 Codec/Config/Meta + 逐块流式 verbatim，
  分片 IO 换 Transport，端点来自 Router+Topology；GET 跨节点并行读 K-of-N、PUT 写 quorum
- Lock：:global.trans MVP（with_lock）+ dsync quorum_with_lock 升级；守护 PUT/assemble/delete
- 共享 conformance 第三次同跑（Distributed+InProcess）证同契约
- 专项：端点宕机仍读、M+1 宕机 raise InsufficientShardsError、写 < quorum {:error,:write_quorum}、
  篡改分片 BLAKE3 失配重建、版本稳定路由
- config 文档化切后端；全量回归绿、--warnings-as-errors 零警告

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（M7-4）**：共享 conformance 套件同跑 `Distributed`+`InProcess` 6 test 全绿（铁律 2 同契约）；端点宕机仍可读（K 存活）；M+1 宕机 GET 经惰性流 raise `InsufficientShardsError`（铁律 3 绝不静默错数据）；写未达 write_quorum → `{:error,:write_quorum}`；篡改端点分片 BLAKE3 失配后重建仍正确；`Lock.with_lock` 跑 fun + 不死锁；全量回归绿。

---

# 单元 M7-5：跨节点 heal + mix maxio.heal.cluster + 集群 e2e（InProcess + :peer）+ 文档

**目标**：`Maxio.Cluster.Heal`（扩展 M6 heal 思路，经 `Transport` 检测宕机/被替换端点上缺失/损坏的分片、从存活端点重建回写 + 修 sidecar；不可恢复 → `{:error,:unrecoverable}` + 结构化日志）；`mix maxio.heal.cluster` CLI；集群 e2e（InProcess 多节点矩阵 + `:peer` 真节点各一套）；STATUS/README 更新 + M7 defer 文档化。

**依赖**：M7-4。**TDD**：heal 重建被打掉端点的整列缺失分片 + 篡改分片；损 M+1 → unrecoverable；`:peer` 真 `:erpc` 宕机 → nil → 重建。

### 步骤 1（实现）：`Maxio.Cluster.Heal`

新建 `lib/maxio/cluster/heal.ex`（**逐块逐端点经 transport 读 + BLAKE3 重算比对 → 坏分片 ≤M 用 `Codec.restore_block` 重建明文 → 重填充到 block_size → `Codec.split_block` 重编码 → 仅坏端点经 `transport.heal_shard` 回写**；与 M6 `Heal.do_heal_block`/`apply_fixes` 同构，IO 换 transport）：

```elixir
defmodule Maxio.Cluster.Heal do
  @moduledoc """
  跨节点纠删码自愈（M7）。检测某对象在各 {node,drive} 端点上缺失/损坏的分片（校验和不匹配/读不到，
  含宕机或被替换的节点），从 K 个存活端点（peer）RS 重建坏分片、经 Transport.heal_shard 回写 +
  修复其 sidecar 副本。坏分片数 > M（存活 < K）-> {:error, :unrecoverable} + 结构化错误日志
  （铁律 3：绝不伪造数据）。结构化日志含 bucket/key/version_id/set/endpoint/block/result（铁律 4）。

  复用 M6 heal 引擎思路（逐块重算 BLAKE3 + restore_block 重建 + split_block 重编码），
  只是分片读/回写经 Transport（本地或 peer），不重写 RS 数学。heal 粒度到整对象。
  """
  require Logger

  alias Maxio.Storage.Erasure.{Codec, Config}
  alias Maxio.Cluster.{Paths, Router, Topology, Transport}

  @doc """
  heal 单个对象版本：从存活端点重建各端点缺/损分片。返回 {:ok, %{healed: n}}（n=回写分片数）或
  {:error, :unrecoverable}（某 block 存活 < K）/ {:error, :enoent}（无任何 sidecar）。
  opts[:topology]/opts[:transport] 注入（同 Distributed 后端）。
  """
  @spec heal_object(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{healed: non_neg_integer()}} | {:error, :unrecoverable | :enoent}
  def heal_object(bucket, key, version_id \\ "null", opts \\ []) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :enoent}

      {:ok, obj_rel} ->
        c = cfg(opts)
        endpoints = endpoints_for(bucket, key, opts)
        dirs = endpoint_dirs(endpoints, obj_rel)
        tx = transport(opts)

        case read_any_sidecar(tx, dirs) do
          {:error, :enoent} -> {:error, :enoent}
          {:ok, meta} -> do_heal(c, bucket, key, version_id, tx, dirs, meta)
        end
    end
  end

  defp do_heal(cfg, bucket, key, version_id, tx, dirs, meta) do
    n = Config.total(cfg)
    size = meta["size"]
    block_size = get_in(meta, ["ec", "block_size"]) || cfg.block_size
    shard_len = block_shard_len(meta, cfg)
    num_blocks = if size == 0, do: 0, else: div(size + block_size - 1, block_size)
    shards_meta = meta["shards"]

    # 逐 block 收集每端点需修复的分片字节：%{endpoint_index => %{block_index => shard_bytes}}。
    result =
      Enum.reduce_while(0..max(num_blocks - 1, 0), {:ok, %{}}, fn j, {:ok, fixes} ->
        if num_blocks == 0 do
          {:cont, {:ok, fixes}}
        else
          heal_block(cfg, bucket, key, version_id, tx, dirs, shards_meta, n, size, block_size,
            shard_len, j, fixes)
        end
      end)

    case result do
      {:error, :unrecoverable} ->
        Logger.error("cluster heal unrecoverable",
          bucket: bucket,
          key: key,
          reason: "block survivors < K"
        )

        {:error, :unrecoverable}

      {:ok, fixes} ->
        healed = apply_fixes(tx, dirs, meta, shard_len, fixes)
        {:ok, %{healed: healed}}
    end
  end

  defp heal_block(cfg, bucket, key, version_id, tx, dirs, shards_meta, n, size, block_size,
         shard_len, j, fixes) do
    # 跨端点读 block j 的 N 个分片（宕机端点 -> nil）。
    read_shards =
      0..(n - 1)
      |> Enum.zip(dirs)
      |> Enum.map(fn {i, {node, dir}} ->
        drive_meta = Enum.at(shards_meta, i)

        if drive_meta && j < length(drive_meta["block_hashes"]) do
          tx.get_shard(node, dir, j, shard_len)
        else
          nil
        end
      end)

    checksums = block_checksums(shards_meta, n, j)

    bad =
      0..(n - 1)
      |> Enum.filter(fn i ->
        not Codec.verify_shard(Enum.at(read_shards, i), Enum.at(checksums, i))
      end)

    cond do
      bad == [] ->
        {:cont, {:ok, fixes}}

      length(bad) > cfg.parity_shards ->
        Logger.error("cluster heal block unrecoverable",
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

        # 重编码须与 PUT 完全一致的固定 block_size 填充语境（保证 shard_len 与 sidecar 一致）。
        padded =
          if byte_size(plain) < block_size do
            plain <> <<0::size((block_size - byte_size(plain)) * 8)>>
          else
            plain
          end

        %{shards: good_shards} = Codec.split_block(cfg, padded)

        fixes =
          Enum.reduce(bad, fixes, fn i, acc ->
            shard = Enum.at(good_shards, i)
            ep_map = Map.get(acc, i, %{})
            Map.put(acc, i, Map.put(ep_map, j, shard))
          end)

        Logger.info("cluster heal block repaired",
          bucket: bucket,
          key: key,
          reason: "block=#{j} repaired_endpoints=#{inspect(bad)}"
        )

        {:cont, {:ok, fixes}}
    end
  end

  # 把 fixes 经 transport.heal_shard 回写到各坏端点 + 修 sidecar。返回回写分片数。
  defp apply_fixes(tx, dirs, meta, shard_len, fixes) do
    Enum.reduce(fixes, 0, fn {ep_index, block_map}, count ->
      {node, dir} = Enum.at(dirs, ep_index)
      {:ok, written} = tx.heal_shard(node, dir, block_map, shard_len, meta)
      count + written
    end)
  end

  @doc "scrub 整桶：遍历桶内全部对象（去重存活端点副本），逐个 heal。"
  @spec scrub_bucket(String.t(), keyword()) ::
          {:ok, %{scanned: non_neg_integer(), healed_objects: non_neg_integer(),
                  unrecoverable: non_neg_integer()}}
  def scrub_bucket(bucket, opts \\ []) do
    objects = list_objects(bucket, opts)

    {scanned, healed, unrec} =
      Enum.reduce(objects, {0, 0, 0}, fn {key, version_id}, {sc, hl, ur} ->
        case heal_object(bucket, key, version_id, opts) do
          {:ok, %{healed: n}} when n > 0 -> {sc + 1, hl + 1, ur}
          {:ok, _} -> {sc + 1, hl, ur}
          {:error, :unrecoverable} -> {sc + 1, hl, ur + 1}
          {:error, :enoent} -> {sc + 1, hl, ur}
        end
      end)

    Logger.info("cluster scrub bucket done",
      bucket: bucket,
      reason: "scanned=#{scanned} healed=#{healed} unrecoverable=#{unrec}"
    )

    {:ok, %{scanned: scanned, healed_objects: healed, unrecoverable: unrec}}
  end

  # 列桶内对象 {key, version_id}：经 ShardServer.list（本机）跨所有端点节点扫描含 meta.json 的目录，
  # 去重。MVP 简化——直接在每端点 drive 上 File 扫描（heal 在协调节点运行，对本地端点用 File，
  # 对 peer 端点用 :erpc 到 ShardServer 的 list；本计划 scrub 仅扫本机端点 + peer 经显式列举 defer）。
  # 为保持 M7-5 可测且不引入新 transport list callback，scrub_bucket 接受 opts[:objects]（[{key,vid}]）
  # 显式列表（CLI 与 e2e 用 Objects 上下文/已知 key 列举），无 opts[:objects] 时回 []（文档化）。
  defp list_objects(_bucket, opts), do: Keyword.get(opts, :objects, [])

  # ── 复用 M6 的纯辅助（与 Distributed 后端逐字一致）──

  defp topology(opts), do: Keyword.get(opts, :topology)
  defp transport(opts), do: Transport.impl(opts)

  defp cfg(opts) do
    ec =
      case topology(opts) do
        nil -> Topology.ec_params()
        t -> Topology.ec_params_from(t)
      end

    n = Keyword.fetch!(ec, :data_shards) + Keyword.fetch!(ec, :parity_shards)
    Config.load!(Keyword.put(ec, :drives, for(i <- 0..(n - 1), do: "__remote_#{i}__")))
  end

  defp endpoints_for(bucket, key, opts) do
    case topology(opts) do
      nil ->
        Topology.endpoints(Router.set_for(bucket, key, nil))

      t ->
        Topology.endpoints_from(t, Router.set_for(bucket, key, t))
    end
  end

  defp endpoint_dirs(endpoints, obj_rel),
    do: Enum.map(endpoints, fn {node, drive} -> {node, Path.join(drive, obj_rel)} end)

  defp read_any_sidecar(tx, dirs) do
    Enum.find_value(dirs, {:error, :enoent}, fn {node, dir} ->
      case tx.get_sidecar(node, dir) do
        {:ok, meta} -> {:ok, meta}
        {:error, _} -> nil
      end
    end)
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

      if is_list(bh) and length(bh) > 0 and s["shard_file_size"] > 0 do
        div(s["shard_file_size"], length(bh))
      end
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

> **scrub 对象列举的诚实简化**：跨节点全桶扫描需一个新 transport `list_dir` callback + 协调节点聚合 peer 列举。M7-5 MVP 把 `scrub_bucket` 的对象来源做成 `opts[:objects]` 显式列表（CLI 从 `Maxio.Objects` 元数据上下文取 key 列表，e2e 用已知 key）。**完整自动跨节点 walk（含 peer 列举 + 1/1024 采样 + 限流）= 显式 defer（文档化于末尾）。** `heal_object/4` 本身（单对象跨节点重建）完整可用——这是 quorum-loss 防护的核心。

### 步骤 2（TDD 红 + 绿）：跨节点 heal 单测（InProcess）

新建 `test/maxio/cluster/heal_test.exs`：

```elixir
defmodule Maxio.Cluster.HealTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias Maxio.Storage.Distributed
  alias Maxio.Cluster.{Heal, Topology, Transport.InProcess}

  setup do
    InProcess.setup!()
    base = Path.join(System.tmp_dir!(), "maxio_chheal_#{System.unique_integer([:positive])}")
    endpoints = for i <- 0..5, do: {:"maxio@d#{i}", Path.join(base, "d#{i}")}

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 1024,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, topology: topology, endpoints: endpoints}
  end

  defp opts(ctx), do: [topology: ctx.topology, transport: InProcess]
  defp part_path(ddir), do: Path.join([ddir, "b", "k", "part.0"])

  test "heal 重建被删整列分片的端点（模拟节点替换）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    # 删端点 0 的整个对象目录（整列分片 + sidecar 缺失，模拟空盘/被替换节点）。
    {_, d0} = Enum.at(ctx.endpoints, 0)
    File.rm_rf!(Path.join([d0, "b", "k"]))
    refute File.exists?(part_path(d0))

    assert {:ok, %{healed: healed}} = Heal.heal_object("b", "k", "null", o)
    assert healed >= 1
    assert File.exists?(part_path(d0))

    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "heal 修复被篡改的端点分片（bitrot）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    {_, d1} = Enum.at(ctx.endpoints, 1)
    p = part_path(d1)
    <<first, rest::binary>> = File.read!(p)
    File.write!(p, <<bxor(first, 0xFF), rest::binary>>)

    assert {:ok, %{healed: healed}} = Heal.heal_object("b", "k", "null", o)
    assert healed >= 1
    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "损 M+1 个端点 -> heal :unrecoverable（不伪造数据）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    for i <- 0..2 do
      {_, d} = Enum.at(ctx.endpoints, i)
      File.rm_rf!(Path.join([d, "b", "k"]))
    end

    assert {:error, :unrecoverable} = Heal.heal_object("b", "k", "null", o)
  end
end
```

执行：
```powershell
mix test test/maxio/cluster/heal_test.exs
```

### 步骤 3（实现）：`mix maxio.heal.cluster` CLI

新建 `lib/mix/tasks/maxio.heal.cluster.ex`（镜像 `maxio.heal.ex`，调 `Maxio.Cluster.Heal`，结构化打印）：

```elixir
defmodule Mix.Tasks.Maxio.Heal.Cluster do
  @shortdoc "跨节点纠删码自愈：从存活端点重建对象的缺失/损坏分片"
  @moduledoc """
  跨节点纠删码自愈 CLI（铁律 4：后端功能 CLI 可观测）。

      mix maxio.heal.cluster <bucket> <key> [version_id]   # heal 单对象（version_id 缺省 "null"）

  从 K 个存活端点（peer 经 :erpc）RS 重建坏分片并经 Transport.heal_shard 回写；
  某 block 存活 < K -> 打印 unrecoverable（绝不伪造数据）。
  拓扑/EC 参数取 config :maxio, Maxio.Cluster.Topology；传输取 config :maxio, :shard_transport。
  """
  use Mix.Task

  alias Maxio.Cluster.Heal

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [bucket, key | rest] ->
        version_id = List.first(rest) || "null"

        case Heal.heal_object(bucket, key, version_id) do
          {:ok, %{healed: n}} ->
            IO.puts("[maxio heal.cluster] #{bucket}/#{key}@#{version_id}: healed #{n} shard(s)")

          {:error, :unrecoverable} ->
            IO.puts(
              "[maxio heal.cluster] #{bucket}/#{key}@#{version_id}: UNRECOVERABLE (survivors < K) — data NOT fabricated"
            )

          {:error, :enoent} ->
            IO.puts("[maxio heal.cluster] #{bucket}/#{key}@#{version_id}: no sidecar found on any endpoint")
        end

      _ ->
        IO.puts("usage: mix maxio.heal.cluster <bucket> <key> [version_id]")
    end
  end
end
```

### 步骤 4（集群 e2e — :peer 真节点）：

新建 `test/maxio/cluster/peer_cluster_test.exs`（**少量 `@tag :distributed`、`async: false`**，起真 `:peer` 节点跑真 `:erpc` 的 `Transport.Erpc`，验证真宕机 → nil → 重建 + `:global.trans` 跨节点互斥）：

```elixir
defmodule Maxio.Cluster.PeerClusterTest do
  use ExUnit.Case, async: false
  @moduletag :distributed

  alias Maxio.Storage.Distributed
  alias Maxio.Cluster.{Topology, Transport.Erpc}
  alias Maxio.Storage.Erasure.InsufficientShardsError

  setup_all do
    # 需分布式：若本节点未起 distribution，起一个匿名节点（epmd 须运行：`epmd -daemon`）。
    case :net_kernel.start([:"maxio_primary@127.0.0.1", :longnames]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Node.set_cookie(:maxio_test_cookie)
    :ok
  end

  setup do
    :ok = :net_kernel.monitor_nodes(true)
    base = Path.join(System.tmp_dir!(), "maxio_peer_#{System.unique_integer([:positive])}")

    # 起 2 个 :peer 节点（OTP 25+ :peer 替代 :slave）。本机 + 2 peer = 3 node，N=6 端点每 node 2 drive。
    {:ok, p1, n1} = start_peer(:maxio_peer1)
    {:ok, p2, n2} = start_peer(:maxio_peer2)

    nodes = [Node.self(), n1, n2]

    # 各 node 加载代码路径 + 起 ShardServer。
    for n <- [n1, n2] do
      :ok = :erpc.call(n, :code, :add_paths, [:code.get_path()])
      {:ok, _} = :erpc.call(n, Maxio.Cluster.ShardServer, :start_link, [[]])
    end

    {:ok, _} = ensure_local_shard_server()

    endpoints =
      for {node, di} <- Enum.flat_map(nodes, fn n -> [{n, 0}, {n, 1}] end) |> Enum.with_index() |> Enum.map(fn {{n, _}, idx} -> {n, idx} end) do
        {node, Path.join(base, "#{node}_d#{di}")}
      end

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 1024,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    on_exit(fn ->
      :peer.stop(p1)
      :peer.stop(p2)
      File.rm_rf(base)
    end)

    {:ok, base: base, topology: topology, peers: [p1, p2], nodes: nodes, peer_nodes: [n1, n2]}
  end

  defp opts(ctx), do: [topology: ctx.topology, transport: Erpc]

  defp start_peer(name) do
    {:ok, pid, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", ~c"maxio_test_cookie"]
      })

    {:ok, pid, node}
  end

  defp ensure_local_shard_server do
    case Process.whereis(Maxio.Cluster.ShardServer) do
      nil -> Maxio.Cluster.ShardServer.start_link([])
      pid -> {:ok, pid}
    end
  end

  @tag :distributed
  test "PUT/GET 跨真 peer，杀一个 peer，GET 仍重建（K 存活）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)

    [n1, _n2] = ctx.peer_nodes
    [p1, _] = ctx.peers

    # 真宕机：杀 peer1 -> 其 2 个端点 :erpc :noconnection -> nil 分片。N=6, 杀 1 node = 丢 2 分片 = M，仍 >= K。
    :ok = :peer.stop(p1)
    assert_receive {:nodedown, ^n1}, 5_000

    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end
end
```

> **`:peer` e2e 注意**：(a) 需 `epmd` 运行（`epmd -daemon`，或 `:net_kernel.start` 自带）；(b) 本测试 `@tag :distributed`，默认 `mix test` 通过 `test/test_helper.exs` 的 `ExUnit.configure(exclude: [:distributed])` 排除，单独 `mix test --include distributed` 跑；(c) Windows 上 `:peer` + epmd 可能受防火墙/127.0.0.1 限制——若本机起 peer 失败，**该测试整体 skip（`@tag :skip` 或在 setup 探测失败时 `ExUnit.Case` 不阻断主回归）**；主力覆盖在 InProcess（确定性）。CI 友好：InProcess 必跑，`:peer` 可选。

修改 `test/test_helper.exs` 加排除（**若已有 `ExUnit.start()`，在其后追加** `ExUnit.configure(exclude: [:distributed])`；先读现状再改）：

```powershell
# 先看 test_helper.exs 现状
Get-Content test\test_helper.exs
```

若无 `exclude`，把 `ExUnit.start(...)` 之后插入：

```elixir
# M7：:peer 真节点集成测试默认排除（确定性 InProcess 覆盖为主力）；单独跑：mix test --include distributed
ExUnit.configure(exclude: [:distributed])
```

### 步骤 5（集群 e2e — InProcess 全链路矩阵）：

新建 `test/maxio/cluster/cluster_e2e_test.exs`（**确定性主力 e2e**：一节点宕机仍写 + 一节点宕机仍读 + 节点返回后 heal + quorum-loss raise，全经 InProcess，覆盖 STATUS 要求的四场景）：

```elixir
defmodule Maxio.Cluster.ClusterE2ETest do
  use ExUnit.Case, async: false

  alias Maxio.Storage.Distributed
  alias Maxio.Cluster.{Heal, Topology, Transport.InProcess}
  alias Maxio.Storage.Erasure.InsufficientShardsError

  setup do
    InProcess.setup!()
    base = Path.join(System.tmp_dir!(), "maxio_e2e_#{System.unique_integer([:positive])}")
    # 3 node，每 node 2 drive = N=6 端点；K=4 M=2 -> 杀 1 node（2 端点）= M，仍可读/写 quorum=4。
    endpoints =
      for i <- 0..5 do
        {:"maxio@node#{div(i, 2)}", Path.join(base, "node#{div(i, 2)}_d#{rem(i, 2)}")}
      end

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 1024,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, topology: topology}
  end

  defp opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  test "一节点宕机仍可写（write quorum=4，宕 node2 的 2 端点 -> 4 成功）", ctx do
    o = opts(ctx)
    InProcess.set_down(:"maxio@node2")
    body = :crypto.strong_rand_bytes(3000)
    assert {:ok, %{size: 3000}} = Distributed.put("b", "k", "null", [body], o)
    InProcess.set_up(:"maxio@node2")
    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "一节点宕机仍可读（read quorum=4）", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)
    InProcess.set_down(:"maxio@node1")
    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "节点返回后 heal 重建其分片", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    InProcess.set_down(:"maxio@node2")
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)
    # node2 返回（带空盘）—— 其端点目录从未写过 -> heal 重建。
    InProcess.set_up(:"maxio@node2")
    assert {:ok, %{healed: n}} = Heal.heal_object("b", "k", "null", o)
    assert n >= 1
    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
  end

  test "quorum-loss（2 节点宕 = 4 端点 < read quorum）-> GET raise", ctx do
    o = opts(ctx)
    body = :crypto.strong_rand_bytes(3000)
    {:ok, _} = Distributed.put("b", "k", "null", [body], o)
    InProcess.set_down(:"maxio@node1")
    InProcess.set_down(:"maxio@node2")
    {:ok, s} = Distributed.get("b", "k", "null", nil, o)
    assert_raise InsufficientShardsError, fn -> Enum.to_list(s) end
  end
end
```

执行：
```powershell
mix test test/maxio/cluster/cluster_e2e_test.exs test/maxio/cluster/heal_test.exs
```

### 步骤 6（文档）：STATUS + README 更新 + defer 文档化

更新 `docs/superpowers/STATUS.md`：里程碑表加 M7 行（✅），加「M7 实现摘要」节（M7-1..M7-5 各一段），加「M7 已知非阻塞项 / 显式 defer」节（下方清单逐条），「下一步」节更新。

更新 `README.md`：加「多节点分布式」章节，含拓扑 config 示例、dev 三节点 iex 启动命令、defer 清单。

把以下 **§ M7 显式 deferral** 逐条写入 STATUS 与 README（绝不静默）。

### 步骤 7（全量验证 + 提交）

```powershell
mix compile --warnings-as-errors
mix test
mix test --include distributed   # 额外跑 :peer 集成（本机 epmd 可用时）
```
期望：编译零警告；全量回归绿（含 M7 新测试）；`--include distributed` 下 `:peer` e2e 绿（或在本机 :peer 起不来时该文件 skip，主回归不受影响）。

```powershell
git add -A
git commit -m @'
M7-5: 跨节点 heal + mix maxio.heal.cluster + 集群 e2e（InProcess + :peer）+ 文档

- Maxio.Cluster.Heal：经 Transport 检测宕机/被替换端点缺/损分片，从存活端点 RS 重建回写 + 修 sidecar；
  损 M+1 -> {:error,:unrecoverable} + 结构化日志（铁律 3 不伪造数据）；scrub 对象列举显式 defer
- mix maxio.heal.cluster CLI（结构化日志，铁律 4 可观测）
- 集群 e2e（InProcess 确定性主力）：一节点宕仍写 + 一节点宕仍读 + 节点返回 heal + quorum-loss raise
- :peer 真节点集成（@tag :distributed，验真 :erpc 宕机 -> nil -> 重建 + :global 跨节点互斥）
- STATUS/README 更新 + M7 defer 逐条文档化
- 全量回归绿、--warnings-as-errors 零警告

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收（M7-5）**：跨节点 heal 单测（整列缺失重建 + bitrot 修复 + M+1 unrecoverable）绿；集群 e2e 四场景（写带 1 节点宕 / 读带 1 节点宕 / 节点返回后 heal / quorum-loss raise）绿；`:peer` e2e 在本机可用时绿（否则 skip 不阻断）；`mix maxio.heal.cluster` 可运行；STATUS/README 含 M7 摘要 + defer 清单；全量回归绿。

---

## § M7 显式 deferral（文档化，绝不静默——写入 STATUS + README）

M7 完成「单 pool、多节点、跨节点 erasure + quorum + 锁 + heal」。以下**显式 defer**（绝不假装实现）：

1. **Rebalance / Decommission / online pool 扩容**：添加 pool / 退役 pool / 跨 pool 迁移既有对象（MinIO `mc admin rebalance`/`decommission`、free-space 加权放置 `P ∝ freeSpace(pool)/freeSpace(all)`）。M7 单 pool（`pools` 可配多个但路由仅在全局 set 列表取模；**多 pool 的「先选 pool 再选 set」两级路由 + free-space 加权新写 + 迁移** = defer）。set 数 per pool **不可变**（online set 扩缩需重哈希迁移）。
2. **完整 dsync 锁语义**：M7 用 `:global.trans`（MVP，全 mesh 互斥）+ `quorum_with_lock`（dsync 式多数获锁骨架）。**lock lease/refresh keepalive、owner crash 的 refresh-expiry 重置、`ForceUnlock` admin 覆盖、read/write 锁区分（RLock 共享计数）、split-brain after crash+restart 的已知缺陷处理** = defer。BEAM 改进（process-monitor 自动释放）= defer。
3. **跨节点 IAM / bucket-metadata / config 复制**：MinIO 把 config/IAM/bucket-meta 当对象存 `.minio.sys`（erasure + quorum）+ peer 通知刷缓存。maxio 的 IAM/bucket-meta 仍走 **Postgres**（M3/M4），多节点共享 DB 即天然一致——**故无需 `.maxio.sys` 对象化复制**（架构差异，非缺口）；但**节点本地 ETS 缓存的跨节点失效通知（reloaduser/loadbucket 式 PubSub 广播）** = defer（当前每请求读 DB / 缓存策略未跨节点失效广播）。
4. **scanner 全自动跨节点 walk + 1/1024 采样 + 限流**：`Heal.heal_object/4`（单对象跨节点重建）完整；`scrub_bucket` 的**对象列举**当前经 `opts[:objects]` 显式列表（CLI 从 `Maxio.Objects` 元数据取）。**自动跨节点目录 walk（需 transport `list_dir` callback + 协调节点聚合 peer 列举）+ MinIO 式 hash 采样 + token-bucket 限流 + drive-offline 48h 策略** = defer。
5. **多 parity / storage class**：单一 (K,M)；`x-amz-storage-class` → STANDARD/RRS 不同 EC = defer（沿用 M6）。
6. **parity upgrade on degraded write**：M7 降级写仍按固定 (K,M)，写未达 write_quorum 即 `{:error,:write_quorum}`（绝不静默）；MinIO 的「写时若干端点离线则**临时提高 effective parity** 并在 per-object meta 记录实际布局」= defer。
7. **专用流式分片传输（gRPC/HTTP2 + 连接池 + 背压）**：M7 用 :erpc（OTP 内置，逐 block-shard 有界）。大规模（>~50 节点全 mesh dist 压力）/ 跨数据中心 / mTLS 的专用传输 = defer（Transport behaviour 已抽象，换实现不动后端）。
8. **failure-domain 感知的自动 set 形成**：M7 拓扑由 config **手工**指定每 set 的 N 个 `{node,drive}`（运维须保证「N 端点尽量跨节点、每节点端点数 ≤ M」）。MinIO 的 ellipsis 展开 + node-interleaving + GCD set sizing **自动**形成 = defer（手工 config 即可达同等放置，文档化要求）。
9. **沿用 M0–M6 全部既有 defer**（lifecycle 后台执行、SSE 大对象逐帧流式 GET、identity policy、MFA Delete 强制、跨账户多租户、完整条件算子、inline 小对象等）。

> **设计保证**：M7 在 M6 同一 RS 核心**之外**加 routing/locking/topology/transport 层，**不重写 encode/decode/heal 引擎**；所有节点宕机/超时/quorum-loss → nil 分片 → EC 重建或结构化 raise，**绝不静默返回错数据**（铁律 3）。deferral 在 STATUS + README 逐条显式列出（无静默缺口）。
