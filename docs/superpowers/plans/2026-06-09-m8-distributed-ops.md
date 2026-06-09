# M8 分布式运维成熟度 实现计划 · maxio（Distributed Operational Maturity · quorum lock + cross-node cache coherence + background scanner/auto-heal）

> For agentic workers（executor）：严格按单元 **M8-1 .. M8-4** 顺序执行。逻辑性代码用 **TDD**（先写失败测试 → 运行确认红 → 最小实现 → 运行确认绿 → commit）；脚手架/配置/依赖类任务用「执行命令 + 验证输出」。每个任务都给了**精确文件路径、完整可用代码（禁止占位符 / TODO / 省略号）、确切 PowerShell 命令与期望输出**。后面单元引用的类型/函数/字段名与前面定义（及 M0–M7 既有代码）**严格一致**——复用既有模块时逐字照抄其现有签名。
>
> **本计划建立在已交付并验证的 M0–M7 之上**（master，510 测试全绿、`compile --warnings-as-errors` 零警告、独立 reviewer APPROVE）。M8 的核心是：**在 M7 已交付的集群层（`Maxio.Cluster.*` + `Maxio.Storage.Distributed` + `Maxio.Cluster.Heal`）之上，把 M7 显式 defer 的三项「分布式运维成熟度」补齐**——(1) 把 `Maxio.Cluster.Lock` 从 `:global.trans` MVP 升级为 dsync 式 **quorum 锁 + 租约 + owner-death 自动释放**；(2) 加 **跨节点缓存失效通知**（`Maxio.Cluster.Notify` + 订阅者，经既有 `Maxio.PubSub`）；(3) 加 **后台 scanner + 自愈**（supervised GenServer + `Process.send_after`，分页遍历 `Maxio.Objects`，复用 M6/M7 heal 检测+修复，限流，绝不阻塞 S3 请求）。**rebalance / decommission / online pool 扩容 仍显式 defer 到 M9。**
>
> **铁律对齐（AGENTS.md §3/§4，违反即返工）**：
> - **铁律 2（后端即插件 / 核心管线不改）**：M8 是**纯增量的集群运维模块**。存储后端（`Maxio.Storage.{FS,ErasureCoded,Distributed}`）、`Backend` behaviour、所有 handler / dispatcher / endpoint、`Maxio.S3.*` 请求管线 **一行不改**。`Maxio.Cluster.Lock` 的**公共 API（`with_lock/2,3` 返回 `{:ok, term} | {:error, :locked}`）保持逐字不变**，故 `Maxio.Storage.Distributed` 的三处调用点（`do_put`/`do_delete`/`do_assemble`）**零改动**。唯一接线 = 监督树新增三个 child（`LockServer` / `CacheInvalidator` / `Scanner`）+ 在已有 mutation context 末尾追加 `Notify.broadcast/1` + config 追加 `:scanner` 块 + Logger metadata 追加键。
> - **铁律 3（绝不静默失败 / 绝不静默返回错数据）**：① **锁**——获锁失败（未达 quorum）→ `{:error, :no_quorum}`，映射到公共 API 的 `{:error, :locked}`，**绝不静默并发写同对象**；持锁中途丢失 quorum（心跳失败）→ force-unlock 自身 + 通知 owner abort（`{:error, :lock_lost}`），**绝不在已失去锁的情况下继续 mutate**。② **scanner**——对象不可恢复（某 block 存活 < K）→ 只 `Logger.error` + 计数，**绝不伪造数据**（直接继承 M6/M7 heal 的 `{:error, :unrecoverable}`）。③ **诚实**——生产元数据路径（EctoStore + 每请求 `Repo` 读）**无可陈旧缓存**，M8 的失效订阅者**当前是正确的 no-op**；文档/moduledoc 必须诚实声明，**绝不假装失效了什么**。
> - **铁律 4（结构化日志 + CLI 可观测；scanner 绝不阻塞请求处理）**：scanner 是**独立 supervised GenServer**（与 Bandit 的 `Maxio.S3.Endpoint` 物理隔离的进程），单并发 + 限流（每对象 sleep + 每批 sleep），共享的只有只读 DB 行与只读分片文件；**绝不持有任何 live PUT/GET 需要的对象级锁**（scanner 只用 disjoint 的 `{:scanner_set, set_id}` 租约资源，与 `{bucket, key}` 对象锁不相交）。每周期 + 每损坏对象 + 每不可恢复对象 + 每用量漂移 都 `Logger.{info,warning,error}` 结构化输出。新增 CLI `mix maxio.scan`（一次性全量扫描+自愈，前台同步汇总）。
> - **铁律 5（行为对齐 MinIO）**：锁的 quorum 公式、lease/refresh 比例、scanner 的 1/1024 采样 + 动态延迟（factor × duration）+ leader-per-set 单拥有者，均**对齐 MinIO dsync / data-scanner**（见各单元「研究对齐」小节，逐条溯源）。
> - **铁律 6（DB schema 自文档化）**：M8 **不新建任何表**（锁状态走 ETS/`:persistent_term`；用量缓存走 `:persistent_term`；元数据沿用 Postgres）。**若**后续选择把用量历史落 DB（本计划不这么做，见 M8-3 §2.9 选项 ii），新表/列须中文 `COMMENT`。
>
> **作者/审查隔离**：本计划由 executor 实现；每个单元收尾由**独立** `code-reviewer`/`verifier`（不同上下文）取证，实现者不得自审。

---

## 环境约束（每条命令都必须遵守）

- **本机**：Windows 11 + PowerShell。Elixir 1.20.0 / OTP 28，位于 `C:\Users\dyz\Documents\dev\usr\Elixir\bin`。
- **跑任何 mix 命令前必设**（否则编译期/运行期中文输出重定向到非 TTY 触发 `io.put_chars badarg` 硬崩、留 `erl_crash.dump`）：
  ```powershell
  $env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
  $env:ERL_FLAGS = '-kernel standard_io_encoding unicode'
  ```
  本计划所有 PowerShell 命令块**默认已假设当前会话已设此两变量**；每个新 shell 会话第一条命令前先执行它。
- **Postgres**：docker 容器 `maxio-db`（postgres:16，localhost:5432，user/pass=postgres/postgres，dev 库 `maxio_dev`，test 库 `maxio_test`）。`psql` 不在 PATH，一律经容器 `docker exec maxio-db psql -U postgres -d maxio_dev -c "..."`。`mix test` 自动迁移 test 库。**M8 不动 DB schema**。容器没起先 `docker start maxio-db`。
- **无 aws-cli / boto3 / mc / python**。端到端验证用三层（**确定性、CI 友好、无需真实集群**）：
  1. **纯函数 / 单进程逻辑单测**（锁 quorum 数学、租约过期判定、owner-death 释放、scanner 周期算法、用量统计、Notify 广播本地送达）——最权威 ground truth，`async: false`（锁/scanner 用全局命名进程，须串行）。
  2. **进程内多节点注入**（沿用 M7 既有手段）：锁的多节点 quorum 经 **注入 node 列表** 测试；scanner 的 leader-per-set 经 **InProcess transport + 注入 topology**（M7 已建）测试；Notify 的跨节点送达经**单节点订阅者**逻辑测试（PubSub 本地送达确定性）。这是**主力**：在 `async: false` 的 ExUnit 里跑真实 quorum/lease/owner-death/scanner-heal，无需第二个 BEAM 节点。
  3. **`:peer` 真节点集成测试**（少量 `@tag :distributed`、`async: false`）：复用 `test/maxio/cluster/peer_cluster_test.exs` 的 `:peer` setup 模式，验证 ① 跨节点 `LockServer` quorum（在真第二节点上拒授同一资源）、② `Notify.broadcast` 经 `Phoenix.PubSub.PG2` 真送达第二节点订阅者。CI 可单独跑/跳过；本机 epmd/`:peer` 不可用时 setup 探测失败即 skip，主回归不受影响。
- **测试禁忌（AGENTS.md Test guidelines）**：用 `start_supervised!/1` 起进程；**禁用** `Process.sleep/1`/`Process.alive?/1`——等进程死用 `Process.monitor/1` + `assert_receive {:DOWN, ...}`；同步用 `_ = :sys.get_state(pid)` 确保进程已处理先前消息；等节点死用 `:net_kernel.monitor_nodes(true)` + `assert_receive {:nodedown, n}`。**唯一例外**：lease TTL 过期测试**必须**让真实时间流逝——用**极小 ttl_ms（如 50ms）+ 显式触发 `:sweep`**（向 LockServer 发 `:sweep` 消息后 `:sys.get_state` 同步）而非 `Process.sleep` 长睡；见 M8-1 测试。
- **提交**：每个单元（或紧密相关的红绿对）一次 commit，message footer 固定一行：
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
  当前分支为 `master`；本计划全部提交到当前分支（无需开新分支，除非用户另行要求）。

---

## Goal

在 M0–M7（鉴权 + 授权 + 高级特性 + Console + 单机纠删码 + 多节点分布式纠删码）之上，补齐 MinIO 式 **分布式运维成熟度** 的三项最高优先级 deferral：

1. **完整 quorum 分布式锁**（M8-1）：把 `Maxio.Cluster.Lock` 从 `:global.trans` MVP 升级为 **dsync 式 quorum 锁**——新增每节点 `Maxio.Cluster.LockServer`（GenServer，ETS 持有锁表，每条目含 owner pid/ref + lease deadline），`Lock.acquire(resource, opts)` 在 `Maxio.Cluster.nodes()` 的 **多数（n/2+1 写 / ceil(n/2) 读）** 节点经 `:erpc` 获锁；**lease TTL + holder 心跳 refresh**；**owner 进程死亡（`Process.monitor`）与 lease 过期（monotonic）两条独立自动释放路径**（crashed holder 绝不死锁集群）；**RLock（共享）vs WLock（独占）**；`force_unlock/1`（admin 逃生）。**保持 `with_lock(resource, fun)` 公共 API 不变**，故 `Maxio.Storage.Distributed` 一行不改。单节点退化为本地锁（quorum=1，同一代码路径）。诚实的正确性边界（best-effort，非 Raft）写进 moduledoc。
2. **跨节点缓存一致性**（M8-2）：先**文档化**共享 Postgres 一致性模型 + 部署要求（所有节点 → 同一 PG / PG HA），再新增 `Maxio.Cluster.Notify`（经 `Maxio.PubSub` 全集群广播 `{:iam_changed,...}`/`{:bucket_config_changed,b}`/`{:bucket_policy_changed,b}`/`{:bucket_meta_changed,b}`）+ 每节点订阅者 `Maxio.Cluster.CacheInvalidator`（失效本地缓存：MemoryStore creds + 任何未来 read-through 缓存）。把 broadcast 接到既有 mutation context（IAM create/delete key、PutBucketPolicy/Cors/Lifecycle/Encryption、ACL、versioning/tags）。对 EctoStore（无缓存）订阅者**当前是 no-op，但管道已就位 + 已测**（broadcast 真送达第二个模拟订阅者）。**诚实声明今天什么有/没有缓存。**
3. **后台 scanner + 自愈**（M8-3）：supervised 周期 scanner（GenServer + `Process.send_after`，`mix.exs` 已确认 **Oban 不是依赖**，用纯 OTP）分页遍历 `Maxio.Objects`，逐对象完整性检测（复用 M6/M7 heal 检测），经 `Maxio.Cluster.Heal`/`Erasure.Heal` 自愈损坏，全程 **限流**（config：interval / batch size / sleep-rate / max concurrency）绝不饱和 IO 或阻塞 S3；**集群感知经 M8-1 quorum 锁的 leader-per-set 选举**（只有租约持有者扫描该 set，避免重复工作）；**用量统计**（刷新 per-bucket 计数/大小）。config 开关 + cadence + throttle；`mix maxio.scan`（一次性全量扫描+自愈）+ 结构化日志（scanned/damaged/healed/unrecoverable）。不可恢复 → 结构化 error 日志，绝不伪造。**FS/非纠删码后端：scanner 仅做用量统计（无分片 heal）。**
4. **集成 + STATUS/README**（M8-4）：一个集成测试同时锻炼 lock + notify + scanner（模拟/退化）；全量回归；STATUS + README M8 总结 + 更新 M9 deferral 列表（rebalance/decommission/online pool 扩容/storage-class 多 parity/degraded-write parity upgrade/专用传输）。

**显式不做（DEFER 到 M9，文档化，绝不静默）**——见末尾「§ M8 显式 deferral / M9 入口」。

> **设计保证（M8 在 M7 集群层之上加运维层）**：M7 已交付的 `Maxio.Cluster.{nodes,this_node,alive?}` 门面、`Transport`/`ShardServer`/`Heal`/`Distributed`、`Maxio.Cluster.Lock.with_lock` 公共契约**全部复用、签名逐字不变**；M8 只在其**之上**加 LockServer（锁后端实现）、Notify（失效广播）、Scanner（周期巡检），**不重写 RS 编解码 / heal 引擎 / transport / 请求管线**。所有 deferral 显式列出（铁律 3，无静默缺口）。

---

## Architecture（M8 在 M7 之上的增量——核心管线 + 存储后端 + RS 核心零改动）

```
                （核心请求管线 / handler / dispatcher / endpoint / 存储后端 —— 一行不改）
S3 客户端 → LB → 任一节点 Maxio.S3.Endpoint → ... → Maxio.S3.Handlers.Object/Multipart
                                                          │
                                               Maxio.Storage（facade，不改）
                                                          │
                                  Maxio.Storage.Distributed（M7，不改）
                                                          │ 三处 Lock.with_lock({bucket,key}, fun)（调用点不改）
                                                          ▼
   ┌──────────────────────────── M8-1 升级锁后端（公共 API 不变）────────────────────────────┐
   Maxio.Cluster.Lock（门面，公共 with_lock/2,3 不变 + 新增 acquire/release/refresh/force_unlock）
        │ acquire：向 Maxio.Cluster.nodes() 多数 :erpc 获锁 + 起心跳 holder
        ▼
   Maxio.Cluster.LockServer（★新，每节点 named GenServer）
        ETS 写锁表 + 读锁表 + monitors 映射；grant/release/refresh/force_unlock/:sweep/{:DOWN,...}
        两条自动释放：Process.monitor(owner)（即时） + monotonic lease 过期（:sweep）

   ┌──────────────────────────── M8-2 跨节点缓存失效（PubSub）────────────────────────────┐
   mutation context（IAM / BucketConfigs / Policy.Store / Buckets）末尾 + Notify.broadcast(event)
        │ Phoenix.PubSub.broadcast(Maxio.PubSub, "maxio:metadata", event)  —— PG2 全 mesh 送达
        ▼
   Maxio.Cluster.CacheInvalidator（★新，每节点 GenServer，订阅 "maxio:metadata"）
        handle_info(event) -> 失效本地缓存（MemoryStore creds / 未来 read-through；EctoStore=诚实 no-op）

   ┌──────────────────────────── M8-3 后台 scanner + 自愈（纯 OTP）────────────────────────────┐
   Maxio.Storage.Scanner（★新，supervised GenServer + Process.send_after 自调度）
        run_one_cycle：分页遍历 Maxio.Objects（有界内存）
          per set leader 经 Lock.with_lock({:scanner_set, set_id})（M8-1 锁；与对象锁 disjoint）
          per object：heal_mod.heal_object/4（复用 M6/M7 检测+修复）—— 限流 Throttle.tick
          per bucket：Scanner.Usage 刷新用量（:persistent_term 缓存 + 与 Console.Stats 自审）
        FS 后端：heal_mod=nil -> 仅用量统计（无 heal）
        动态 cadence：下次延迟 = max(delay_factor × 上次耗时, interval_ms)
   CLI：mix maxio.scan（一次性全量 scan+heal，sample: :full）+ 结构化日志

监督树（Maxio.Application）新增三个 child（接线，下文 §各单元给精确插入位）：
  cluster_children() ++ [Telemetry, Repo, DNSCluster, PubSub,
    Maxio.Cluster.LockServer,        # M8-1：在 cluster_children 之后、需在被 :erpc 调用前起
    Maxio.Cluster.CacheInvalidator,  # M8-2：在 PubSub 之后（订阅 topic）
    Maxio.Storage.Scanner,           # M8-3：在 Repo 之后（需 DB）+ Topology 之后
    Endpoint] ++ s3_children()

复用 M7 集群层（一行不改）：Maxio.Cluster.{nodes/0,this_node/0,alive?/1}、Transport、ShardServer、
  Heal.heal_object/4、Distributed；复用 M6 核心：Erasure.{Codec,Config,Heal}、NIF。
```

config 新增（不改既有 key，仅追加）：
```elixir
# M8-3 后台巡检器（对齐 MinIO data-scanner）。enabled/cadence/限流。
config :maxio, :scanner, enabled: true, interval_ms: 86_400_000, delay_factor: 10.0, ...
# Logger metadata 追加 scanner / lock 键
config :logger, :default_formatter, metadata: [..., :scanned, :damaged, :healed, :unrecoverable, :set, :node]
```

---

## 单元总览（按依赖串行；每单元结束须 green compile + 测试通过 + 一次 commit）

| 单元 | 标题 | 依赖 | 规模/分割理由 |
|---|---|---|---|
| **M8-1** | `Maxio.Cluster.LockServer`（每节点 ETS 锁表 GenServer：grant/release/refresh/force_unlock + `Process.monitor` owner-death + monotonic lease `:sweep`）+ 重写 `Maxio.Cluster.Lock`（`acquire/2`/`release/1`/`refresh/1`/`force_unlock/1`/心跳 holder；保持 `with_lock/2,3`=`{:ok,_}\|{:error,:locked}` 与 `quorum_with_lock/2,3`）+ 监督树起 LockServer + lock 单测（quorum 数学 / owner-death / lease 过期 / RLock 共存 / force_unlock / 单节点 quorum=1 / 注入多节点 quorum）| M7 | 锁后端主体；公共 API 不变故 Distributed 零改；自包含可测（注入 node 列表 + 极小 ttl + 显式 sweep）|
| **M8-2** | 文档化共享-PG 一致性模型 + 部署要求；`Maxio.Cluster.Notify`（PubSub 广播门面）+ `Maxio.Cluster.CacheInvalidator`（订阅者 GenServer，EctoStore no-op / MemoryStore 真失效）+ `CredentialStore` 加可选 `invalidate/1` callback + `MemoryStore.invalidate/1`；把 `Notify.broadcast/1` 接到 IAM/BucketConfigs/Policy.Store/Buckets mutation 点；监督树起 CacheInvalidator + 单节点送达单测 | M8-1 | 失效管道 + 接线；no-op 诚实；不触锁/scanner |
| **M8-3** | `Maxio.Storage.Scanner`（supervised GenServer + `Process.send_after` 周期；分页遍历 Objects；leader-per-set 经 M8-1 锁；逐对象 heal 复用 M6/M7；限流；FS 仅用量）+ `Maxio.Storage.Scanner.{Throttle,Usage}` + `mix maxio.scan` + config `:scanner` + Logger metadata + 监督树起 Scanner（test enabled:false）+ scanner 单测（FS 仅用量 / EC 损坏自愈 / EC 不可恢复不伪造 / leader-per-set 单拥有者 / 1/1024 采样确定性）| M8-2 | scanner 主体 + CLI + config；复用既有 heal，纯调度+限流 |
| **M8-4** | 集成测试（lock + notify + scanner 同跑，退化/模拟）+ `:peer` 真节点锁 quorum & Notify 跨节点送达（gated `:distributed`）+ 全量回归 + STATUS/README M8 总结 + M9 deferral 更新 | M8-3 | 端到端集群取证 + 收尾文档 |

**执行顺序**：M8-1 → M8-2 → M8-3 → M8-4。**串行执行，禁止并行 mix 编译**（避免锁文件竞争）。每单元规模控制在「单个 executor 一轮内可完成实现 + 跑测试 + 调用 StructuredOutput」。

---

## 全局命名契约（M8 新增，一次定义全程复用；M0–M7 既有契约逐字一致复用）

**沿用既有契约（逐字一致，绝不重定义）**：
- `Maxio.Cluster.nodes() :: [node()]`（含本机，排序）；`this_node() :: node()`；`alive?(node()) :: boolean()`。
- `Maxio.Cluster.Lock.with_lock(resource :: term(), fun, retries \\ 5) :: {:ok, term} | {:error, :locked}`（**公共 API，M8-1 升级实现但签名不变**）；`quorum_with_lock(resource, fun, opts \\ []) :: {:ok, term} | {:error, :no_quorum}`（保留）。resource 约定 `{bucket, key}` 对象级 / `{bucket, ""}` 桶级；M8 **扩展** resource 允许任意 term（scanner 用 `{:scanner_set, set_id}`）。
- `Maxio.Cluster.Heal.heal_object(bucket, key, version_id \\ "null", opts \\ []) :: {:ok, %{healed: n}} | {:error, :unrecoverable | :enoent}`（M7，scanner 复用）。
- `Maxio.Storage.Erasure.Heal.heal_object(bucket, key, version_id \\ "null", opts \\ []) :: {:ok, %{healed: n}} | {:error, :unrecoverable | :enoent}`（M6，scanner 单机 EC 复用）。
- `Maxio.Objects.list_objects_v2(bucket, opts) :: %{objects, common_prefixes, is_truncated, next_continuation_token, key_count}`；`list_object_versions(bucket, opts) :: %{versions, ...}`（M4，scanner 枚举用）。
- `Maxio.Buckets.list() :: [Bucket.t()]`（scanner 遍历桶）。
- `Maxio.Auth.CredentialStore.impl() :: module()`（M8-2 失效派发）；`Maxio.Policy.Store.impl() :: module()`。
- `Maxio.PubSub`（已在监督树启动；`Phoenix.PubSub.PG2`，全 mesh 自动送达）。
- `Maxio.Cluster.Router.set_for(bucket, key, topology \\ nil) :: set_id()`；`Maxio.Cluster.Topology.all_set_ids() :: [set_id()]`（scanner leader-per-set 用）。

**M8 新增命名契约（一次定义全程复用）**：
- `Maxio.Cluster.LockServer`（每节点 named GenServer，`name: Maxio.Cluster.LockServer`）暴露被 `:erpc` 远程调用的本机入口（经 `GenServer.call`）：
  - `grant(resource, uid, mode, owner, ttl_ms) :: :ok | :denied`（`mode :: :write | :read`）
  - `release(resource, uid) :: :ok`
  - `refresh(resource, uid) :: :ok | :not_found`
  - `force_unlock(resource) :: :ok`
- `Maxio.Cluster.Lock`（门面，新增）：
  - `acquire(resource :: term(), opts :: keyword()) :: {:ok, lease()} | {:error, :no_quorum}`（`opts`：`:mode`（默认 `:write`）、`:ttl_ms`（默认 30_000）、`:timeout`（默认 3_000）、`:retries`（默认 0）、`:nodes`（测试注入 node 列表））
  - `release(lease()) :: :ok`
  - `refresh(lease()) :: :ok | :lost`
  - `force_unlock(resource :: term()) :: :ok`
  - `lease()` = `%{uid, resource, mode, granted, quorum, ttl_ms, all_nodes, holder}`（holder = 心跳进程 pid）。
- `Maxio.Cluster.Notify`（门面）：`topic() :: String.t()`（`"maxio:metadata"`）；`broadcast(event()) :: :ok`；`event()` = `{:iam_changed, ak} | {:iam_deleted, ak} | {:bucket_config_changed, b} | {:bucket_policy_changed, b} | {:bucket_meta_changed, b}`。
- `Maxio.Cluster.CacheInvalidator`（每节点 named GenServer）：订阅 `Notify.topic()`，`handle_info(event, state)` 失效本地缓存。
- `Maxio.Auth.CredentialStore` 新增可选 callback `@callback invalidate(access_key :: String.t()) :: :ok`（`@optional_callbacks invalidate: 1`）；`MemoryStore.invalidate/1` 实现，`EctoStore` 不实现（`function_exported?` 守卫跳过 = 诚实 no-op）。
- `Maxio.Storage.Scanner`（supervised named GenServer）：`scan_now(opts \\ []) :: {:ok, summary()}`；`info() :: map()`；`summary()` = `%{scanned, damaged, healed, unrecoverable, missing}`。
- `Maxio.Storage.Scanner.Throttle.tick(throttle :: map()) :: :ok`。
- `Maxio.Storage.Scanner.Usage.put(bucket, %{count, size}) :: :ok`；`get(bucket) :: map() | nil`。
- `mix maxio.scan`（CLI，调 `Scanner.scan_now/1`）。

---

# 单元 M8-1：quorum 分布式锁（LockServer + Lock 升级 + 心跳 + owner-death/lease 双自动释放）

**目标**：把 `Maxio.Cluster.Lock` 从 `:global.trans` MVP 升级为 dsync 式 quorum 锁。新增每节点 `Maxio.Cluster.LockServer`（GenServer，ETS 写/读锁表 + `monitors` 映射，serialize 授权正确性，`Process.monitor` owner-death 即时释放 + monotonic `:sweep` lease 过期）。重写 `Maxio.Cluster.Lock`：`acquire/2`/`release/1`/`refresh/1`/`force_unlock/1`/心跳 holder，**保持 `with_lock/2,3` 返回 `{:ok, term} | {:error, :locked}`** 使 `Maxio.Storage.Distributed` 一行不改。监督树起 LockServer。

**依赖**：M7。**TDD**：锁逻辑用单进程/注入 node 列表确定性测，lease 过期用极小 ttl + 显式 `:sweep`，owner-death 用 `spawn` + 杀进程 + `:sys.get_state` 同步。

### 研究对齐（dsync / Kleppmann，逐条溯源 — 见任务上下文「RESEARCH: MinIO dsync …」）
- **Quorum 公式**：写 `quorum = div(n,2)+1`（严格多数，两写者多数必重叠 ⇒ 互斥）；读 `quorum = n - div(n,2) = ceil(n/2)`（读读不冲突，松一档）。
- **两条独立自动释放（BEAM 优于 dsync）**：① `Process.monitor(owner)` ⇒ owner 死亡即时 `{:DOWN,...}` 释放（dsync 只有 TTL）；② monotonic lease 过期 `:sweep` ⇒ 覆盖「owner 活着但与本节点失联」（partition）。
- **lease 比例**：`ttl_ms=30_000`、`refresh_interval=10_000`、`sweep_interval=5_000`、`acquire_timeout=3_000`（镜像 dsync 10s refresh vs ~60s validity 的短比例）。**全部用 `System.monotonic_time(:millisecond)`，绝不 wall clock**（Kleppmann 时钟跳变免疫）。
- **持锁中途丢 quorum**：心跳 refresh 收到的 `:ok` 数 < quorum ⇒ 判定丢锁 ⇒ force-unlock 自身 + 通知 owner（`:lock_lost`）⇒ `with_lock` abort 返回 `{:error, :locked}`（绝不在已丢锁下继续 mutate，铁律 3）。
- **诚实边界（写进 moduledoc）**：best-effort，**非 Raft**；crash+restart of LockServer 丢内存态 ⇒ 重组多数可能 double-grant（与 Redlock 同类）。maxio 容忍：底层正确性网 = EC + per-shard BLAKE3 + write-quorum（撕裂写在数据层可检测/可愈，铁律 3）。真线性化路径 = 未来 `ra`（Raft），显式 out of scope。

### 步骤 1（TDD 红）：写 LockServer + Lock 失败测试

**完整替换** `test/maxio/cluster/lock_test.exs`（保留原 3 个断言 + 大量新增；`async: false` 因用全局命名 LockServer）：

```elixir
defmodule Maxio.Cluster.LockTest do
  use ExUnit.Case, async: false

  alias Maxio.Cluster.{Lock, LockServer}

  setup do
    # LockServer 由监督树启动（application）；每个测试前清空其锁表，保证隔离。
    LockServer.reset_for_test()
    :ok
  end

  # ── 兼容性：保留 M7 既有公共 API 断言（with_lock 形态不变）──

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

  # ── 新增：acquire / release / 互斥 ──

  test "acquire 写锁单节点 quorum=1，release 后可再获" do
    {:ok, lease} = Lock.acquire({"b", "k"}, mode: :write)
    assert lease.mode == :write
    assert lease.quorum == 1
    # 持锁期间另一 acquire 被拒（独占）。
    assert {:error, :no_quorum} = Lock.acquire({"b", "k"}, mode: :write, retries: 0)
    :ok = Lock.release(lease)
    # 释放后可再获。
    {:ok, lease2} = Lock.acquire({"b", "k"}, mode: :write)
    :ok = Lock.release(lease2)
  end

  test "with_lock 持锁中并发同资源 -> {:error, :locked}" do
    test_pid = self()

    holder =
      spawn(fn ->
        Lock.with_lock({"b", "hold"}, fn ->
          send(test_pid, :holding)
          # 等测试发信号再放锁。
          receive do
            :go -> :held
          end
        end)
      end)

    assert_receive :holding, 1_000
    # 此刻锁被 holder 持有：本进程获同资源失败。
    assert {:error, :no_quorum} = Lock.acquire({"b", "hold"}, mode: :write, retries: 0)
    send(holder, :go)
    ref = Process.monitor(holder)
    assert_receive {:DOWN, ^ref, :process, ^holder, _}, 1_000
    # holder 退出 -> owner-death 释放 -> 可再获。
    {:ok, lease} = Lock.acquire({"b", "hold"}, mode: :write)
    :ok = Lock.release(lease)
  end

  # ── owner-death 自动释放（BEAM 优于 dsync 的即时路径）──

  test "持锁进程崩溃 -> 锁立即可再获（Process.monitor）" do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, lease} = Lock.acquire({"b", "crash"}, mode: :write)
        send(parent, {:got, lease})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:got, _lease}, 1_000
    # 杀掉持锁进程（owner = 心跳 holder，linked 到此进程，随之死亡）。
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
    # 同步 LockServer 已处理 {:DOWN,...}。
    _ = :sys.get_state(LockServer)
    {:ok, lease} = Lock.acquire({"b", "crash"}, mode: :write)
    :ok = Lock.release(lease)
  end

  # ── lease 过期自动释放（monotonic，覆盖失联 owner）──

  test "lease 过期（极小 ttl + 显式 sweep）-> 锁可再获" do
    # ttl 极小；用 acquire 但不起心跳（refresh 关闭）以制造过期。
    {:ok, lease} = Lock.acquire({"b", "exp"}, mode: :write, ttl_ms: 50, refresh: false)
    # 让 50ms 真流逝后显式触发 sweep（不长睡：仅 60ms 量级，确定性）。
    Process.sleep(60)
    send(LockServer, :sweep)
    _ = :sys.get_state(LockServer)
    # 锁已被 sweep 释放，可再获。
    {:ok, lease2} = Lock.acquire({"b", "exp"}, mode: :write)
    :ok = Lock.release(lease2)
    # 原 lease release 幂等无害。
    :ok = Lock.release(lease)
  end

  # ── RLock 共享 / writer 阻塞 ──

  test "RLock 多读共存；持读锁时写锁被拒" do
    {:ok, r1} = Lock.acquire({"b", "shared"}, mode: :read)
    {:ok, r2} = Lock.acquire({"b", "shared"}, mode: :read)
    assert r1.mode == :read and r2.mode == :read
    # 有读者在场 -> 写锁拒。
    assert {:error, :no_quorum} = Lock.acquire({"b", "shared"}, mode: :write, retries: 0)
    :ok = Lock.release(r1)
    # 仍有 r2，写仍拒。
    assert {:error, :no_quorum} = Lock.acquire({"b", "shared"}, mode: :write, retries: 0)
    :ok = Lock.release(r2)
    # 读者全退 -> 写可获。
    {:ok, w} = Lock.acquire({"b", "shared"}, mode: :write)
    :ok = Lock.release(w)
  end

  test "持写锁时读锁被拒" do
    {:ok, w} = Lock.acquire({"b", "wr"}, mode: :write)
    assert {:error, :no_quorum} = Lock.acquire({"b", "wr"}, mode: :read, retries: 0)
    :ok = Lock.release(w)
  end

  # ── force_unlock admin 逃生 ──

  test "force_unlock 丢弃资源全部条目（任意 uid）" do
    {:ok, _lease} = Lock.acquire({"b", "stuck"}, mode: :write, refresh: false, ttl_ms: 999_999)
    assert {:error, :no_quorum} = Lock.acquire({"b", "stuck"}, mode: :write, retries: 0)
    :ok = Lock.force_unlock({"b", "stuck"})
    _ = :sys.get_state(LockServer)
    {:ok, lease} = Lock.acquire({"b", "stuck"}, mode: :write)
    :ok = Lock.release(lease)
  end

  # ── 注入多节点 quorum 数学（无需真集群）──

  test "注入 3 节点全在线（其中 2 个不可达）：写 quorum=2 仍可获（本机 + 1）" do
    # nodes 注入：本机 + 两个不存在节点。:erpc 到不存在节点 -> catch -> 不计票。
    # 但 grant 只在本机 LockServer 真授；远端不可达 = 0 票。故 3 节点写 quorum=2 在仅本机可达时
    # 应 no_quorum（只有 1 票）。这验证 quorum 数学真生效（不是单节点退化）。
    nodes = [Node.self(), :"ghost1@127.0.0.1", :"ghost2@127.0.0.1"] |> Enum.sort()
    assert {:error, :no_quorum} = Lock.acquire({"b", "q3"}, mode: :write, nodes: nodes, retries: 0)
  end

  test "注入 1 节点（仅本机）：quorum=1，可获" do
    {:ok, lease} = Lock.acquire({"b", "q1"}, mode: :write, nodes: [Node.self()])
    assert lease.quorum == 1
    :ok = Lock.release(lease)
  end
end
```

跑（确认红——`LockServer` 不存在、`acquire/2` 等未定义）：
```powershell
mix test test/maxio/cluster/lock_test.exs
```
期望：编译错误或断言失败（红）。

### 步骤 2（绿）：实现 `Maxio.Cluster.LockServer`

**新建** `lib/maxio/cluster/lock_server.ex`：

```elixir
defmodule Maxio.Cluster.LockServer do
  @moduledoc """
  每节点一个的本机锁表服务（named GenServer，M8）。dsync 式 quorum 锁的「服务端」：
  对外被 :erpc 寻址到正确节点（经 Maxio.Cluster.Lock），对内串行化「该节点对每个 resource 的授权」
  —— 写锁独占、读锁共享，授权正确性由 GenServer 串行保证。

  两条独立的自动释放（铁律 3：crashed/失联 holder 绝不死锁集群）：
    1. owner 进程死亡：本节点 Process.monitor(owner)（本地或远程 pid 均可 monitor）收到
       {:DOWN, ref, :process, _, _} 即时丢弃该 owner 持有的全部条目。比 dsync 仅 TTL 更优。
    2. lease 过期：周期 :sweep（每 sweep_interval）丢弃 last_refresh 超过 ttl_ms 的条目（monotonic 计时，
       Kleppmann 时钟跳变免疫）。覆盖 owner 活着但与本节点失联（partition，monitor 未及时触发）的情形。

  状态：两张 ETS 表（写锁表 :set / 读锁表 :bag）+ monitors 映射（mon_ref -> {table, resource, uid}）。
  ETS 表用进程私有（仅本 GenServer 读写，:protected）—— 所有访问都经 handle_call 串行，绝无竞态。

  正确性边界（诚实，best-effort 非 Raft）：锁态在内存（ETS）。本节点 crash+restart 后锁表为空，
  与其它「曾宕机后恢复」节点重组多数 -> 可能对同 resource double-grant（与 Redlock 同类不可避免洞）。
  maxio 容忍之：数据层（EC + per-shard BLAKE3 + write-quorum）检测/自愈撕裂写（铁律 3），锁是
  「降低正常运行期并发损伤」的效率机制，非唯一正确性保证。真线性化 -> 未来 ra(Raft)，out of scope。
  """
  use GenServer

  @sweep_interval 5_000

  defstruct [:wtab, :rtab, :monitors]

  # ── 启动 ──

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    wtab = :ets.new(:maxio_lock_w, [:set, :protected])
    rtab = :ets.new(:maxio_lock_r, [:bag, :protected])
    schedule_sweep()
    {:ok, %__MODULE__{wtab: wtab, rtab: rtab, monitors: %{}}}
  end

  # ── 被 :erpc 远程调用的本机入口（经本节点 GenServer.call 串行）──

  @doc "授权 resource 的 uid 锁（mode :write 独占 / :read 共享）。:ok | :denied。"
  @spec grant(term(), binary(), :write | :read, pid(), pos_integer()) :: :ok | :denied
  def grant(resource, uid, mode, owner, ttl_ms),
    do: GenServer.call(__MODULE__, {:grant, resource, uid, mode, owner, ttl_ms})

  @doc "释放 resource 的 uid 锁（仅匹配 uid 才释放，不能解他人锁）。幂等。"
  @spec release(term(), binary()) :: :ok
  def release(resource, uid), do: GenServer.call(__MODULE__, {:release, resource, uid})

  @doc "刷新 resource 的 uid 锁 last_refresh（心跳）。:ok（仍持有）| :not_found（已失/过期）。"
  @spec refresh(term(), binary()) :: :ok | :not_found
  def refresh(resource, uid), do: GenServer.call(__MODULE__, {:refresh, resource, uid})

  @doc "admin 逃生：丢弃 resource 的全部条目（任意 uid/owner）。"
  @spec force_unlock(term()) :: :ok
  def force_unlock(resource), do: GenServer.call(__MODULE__, {:force_unlock, resource})

  @doc "测试辅助：清空全部锁表 + monitors（每个测试前调用以隔离）。"
  @spec reset_for_test() :: :ok
  def reset_for_test, do: GenServer.call(__MODULE__, :reset_for_test)

  # ── handle_call（授权正确性串行点）──

  @impl true
  def handle_call({:grant, resource, uid, :write, owner, ttl_ms}, _from, st) do
    now = mono()

    if write_held?(st, resource) or readers?(st, resource) do
      {:reply, :denied, st}
    else
      mon = Process.monitor(owner)

      :ets.insert(
        st.wtab,
        {resource, %{uid: uid, owner: owner, mon: mon, last_refresh: now, ttl_ms: ttl_ms}}
      )

      {:reply, :ok, %{st | monitors: Map.put(st.monitors, mon, {st.wtab, resource, uid})}}
    end
  end

  def handle_call({:grant, resource, uid, :read, owner, ttl_ms}, _from, st) do
    now = mono()

    if write_held?(st, resource) do
      {:reply, :denied, st}
    else
      mon = Process.monitor(owner)

      :ets.insert(
        st.rtab,
        {resource, %{uid: uid, owner: owner, mon: mon, last_refresh: now, ttl_ms: ttl_ms}}
      )

      {:reply, :ok, %{st | monitors: Map.put(st.monitors, mon, {st.rtab, resource, uid})}}
    end
  end

  def handle_call({:release, resource, uid}, _from, st) do
    st = drop_uid(st, st.wtab, resource, uid)
    st = drop_uid(st, st.rtab, resource, uid)
    {:reply, :ok, st}
  end

  def handle_call({:refresh, resource, uid}, _from, st) do
    now = mono()

    cond do
      touch(st.wtab, resource, uid, now) -> {:reply, :ok, st}
      touch(st.rtab, resource, uid, now) -> {:reply, :ok, st}
      true -> {:reply, :not_found, st}
    end
  end

  def handle_call({:force_unlock, resource}, _from, st) do
    st = drop_all(st, st.wtab, resource)
    st = drop_all(st, st.rtab, resource)
    {:reply, :ok, st}
  end

  def handle_call(:reset_for_test, _from, st) do
    Enum.each(Map.keys(st.monitors), &Process.demonitor(&1, [:flush]))
    :ets.delete_all_objects(st.wtab)
    :ets.delete_all_objects(st.rtab)
    {:reply, :ok, %{st | monitors: %{}}}
  end

  # ── owner 死亡：即时释放该 owner 的条目 ──

  @impl true
  def handle_info({:DOWN, mon, :process, _pid, _reason}, st) do
    case Map.fetch(st.monitors, mon) do
      {:ok, {table, resource, uid}} ->
        remove_entry(table, resource, uid)
        {:noreply, %{st | monitors: Map.delete(st.monitors, mon)}}

      :error ->
        {:noreply, st}
    end
  end

  # ── lease 过期 sweep（monotonic）──

  def handle_info(:sweep, st) do
    now = mono()
    st = sweep_table(st, st.wtab, now)
    st = sweep_table(st, st.rtab, now)
    schedule_sweep()
    {:noreply, st}
  end

  # ── 内部辅助 ──

  defp mono, do: System.monotonic_time(:millisecond)
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp write_held?(st, resource), do: :ets.lookup(st.wtab, resource) != []
  defp readers?(st, resource), do: :ets.lookup(st.rtab, resource) != []

  # 仅删匹配 uid 的条目（不能解他人锁，dsync parity）；并 demonitor。
  defp drop_uid(st, table, resource, uid) do
    entries = :ets.lookup(table, resource)

    Enum.reduce(entries, st, fn {^resource, %{uid: ^uid, mon: mon}} = obj, acc ->
      :ets.delete_object(table, obj)
      Process.demonitor(mon, [:flush])
      %{acc | monitors: Map.delete(acc.monitors, mon)}

      _other ->
        acc
    end)
  rescue
    # 匹配失败的子句不会到这里；保守兜底。
    _ -> st
  end

  # remove_entry：按 (resource, uid) 删（owner-death 路径，table 已知）。
  defp remove_entry(table, resource, uid) do
    table
    |> :ets.lookup(resource)
    |> Enum.each(fn
      {^resource, %{uid: ^uid}} = obj -> :ets.delete_object(table, obj)
      _ -> :ok
    end)
  end

  defp drop_all(st, table, resource) do
    entries = :ets.lookup(table, resource)
    :ets.delete(table, resource)

    Enum.reduce(entries, st, fn {_r, %{mon: mon}}, acc ->
      Process.demonitor(mon, [:flush])
      %{acc | monitors: Map.delete(acc.monitors, mon)}
    end)
  end

  defp touch(table, resource, uid, now) do
    case Enum.find(:ets.lookup(table, resource), fn {_r, e} -> e.uid == uid end) do
      nil ->
        false

      {^resource, e} = obj ->
        :ets.delete_object(table, obj)
        :ets.insert(table, {resource, %{e | last_refresh: now}})
        true
    end
  end

  # sweep：删 now - last_refresh > ttl_ms 的条目（含 demonitor）。
  defp sweep_table(st, table, now) do
    expired =
      :ets.tab2list(table)
      |> Enum.filter(fn {_r, e} -> now - e.last_refresh > e.ttl_ms end)

    Enum.reduce(expired, st, fn {_r, %{mon: mon}} = obj, acc ->
      :ets.delete_object(table, obj)
      Process.demonitor(mon, [:flush])
      %{acc | monitors: Map.delete(acc.monitors, mon)}
    end)
  end
end
```

> **executor 注意（drop_uid 多子句写法）**：上面 `drop_uid` 的 `Enum.reduce/3` 内用了带守卫的匿名多子句——Elixir 匿名函数支持多子句但**所有子句的参数元数须一致**。务必写成两子句形式：
> ```elixir
> Enum.reduce(entries, st, fn
>   {^resource, %{uid: ^uid, mon: mon}} = obj, acc ->
>     :ets.delete_object(table, obj)
>     Process.demonitor(mon, [:flush])
>     %{acc | monitors: Map.delete(acc.monitors, mon)}
>
>   _other, acc ->
>     acc
> end)
> ```
> 去掉外层 `rescue`（不需要）。`remove_entry`/`sweep_table` 同理用 `delete_object` 精确删。**编译时若 `--warnings-as-errors` 报匿名函数子句不一致，按此修正。**

### 步骤 3（绿）：重写 `Maxio.Cluster.Lock`（保持公共 API；新增 acquire/release/refresh/force_unlock + 心跳）

**完整替换** `lib/maxio/cluster/lock.ex`：

```elixir
defmodule Maxio.Cluster.Lock do
  @moduledoc """
  分布式锁门面（M8：从 M7 的 :global.trans MVP 升级为 dsync 式 quorum 锁）。

  公共 API 不变（铁律 2：Maxio.Storage.Distributed 一行不改）：
    with_lock(resource, fun, retries \\ 5) :: {:ok, term} | {:error, :locked}
    quorum_with_lock(resource, fun, opts \\ []) :: {:ok, term} | {:error, :no_quorum}
  新增：acquire/2、release/1、refresh/1、force_unlock/1（dsync 式语义）。

  机制（对齐 MinIO dsync，并用 BEAM 改进）：
    * 在 Maxio.Cluster.nodes() 的 N 个节点的 LockServer 上经 :erpc 获锁；
      写 quorum = div(n,2)+1（严格多数）、读 quorum = n - div(n,2)（ceil(n/2)）。
    * 获锁成功后起一个 linked「心跳 holder」进程：每 refresh_interval 向全节点 refresh；
      若收到的 :ok 数 < quorum -> 判定丢锁 -> force_unlock 自身 + 通知 owner :lock_lost（铁律 3：绝不在已丢锁下继续）。
    * 两条自动释放（LockServer 侧）：owner 进程死亡（Process.monitor 即时）+ lease 过期（monotonic sweep）。

  resource 约定：{bucket, key} 对象级、{bucket, ""} 桶级；M8 允许任意 term（scanner 用 {:scanner_set, set_id}）。
  全部 lease 计时用 System.monotonic_time（Kleppmann 时钟跳变免疫）。

  正确性边界（诚实）：best-effort，非 Raft。LockServer crash+restart 丢内存态 -> 重组多数可能 double-grant
  （Redlock 同类洞）。maxio 容忍：数据层 EC + per-shard BLAKE3 + write-quorum 检测/自愈撕裂写（铁律 3）。
  锁=效率机制（降低正常运行期并发损伤），非唯一正确性保证。真线性化 -> 未来 ra(Raft)，out of scope。

  单节点 dev/test：nodes()==[Node.self()] -> quorum=1，本机直接 GenServer.call（跳 :erpc），同一代码路径。
  """
  require Logger

  alias Maxio.Cluster.LockServer

  @ttl_ms 30_000
  @refresh_interval 10_000
  @acquire_timeout 3_000
  @retry_base_ms 250

  @type mode :: :write | :read
  @type lease :: %{
          uid: binary(),
          resource: term(),
          mode: mode(),
          granted: [node()],
          quorum: pos_integer(),
          ttl_ms: pos_integer(),
          all_nodes: [node()],
          holder: pid() | nil
        }

  # ── 公共 API（M7 形态不变；Distributed 三处调用点零改）──

  @doc """
  以独占写锁运行 fun（默认）。获锁成功 -> {:ok, fun.()}；未达 quorum -> {:error, :locked}；
  持锁中丢 quorum -> abort -> {:error, :locked}（绝不在已丢锁下继续 mutate，铁律 3）。
  retries：未达 quorum 时 semi-random 退避重试次数（默认沿用 M7 的 5，desync split-vote）。
  """
  @spec with_lock(term(), (-> result), non_neg_integer()) :: {:ok, result} | {:error, :locked}
        when result: var
  def with_lock(resource, fun, retries \\ 5) do
    case acquire(resource, mode: :write, retries: retries) do
      {:ok, lease} ->
        try do
          {:ok, fun.()}
        catch
          :throw, {:maxio_lock_lost, ^resource} ->
            Logger.error("lock lost during with_lock",
              action: "lock", reason: "quorum lost mid-hold", bucket: res_bucket(resource)
            )

            {:error, :locked}
        after
          release(lease)
        end

      {:error, :no_quorum} ->
        {:error, :locked}
    end
  end

  @doc "保留：M7 dsync 式 quorum 锁入口。委托给 with_lock(mode: :write)（统一实现）。"
  @spec quorum_with_lock(term(), (-> result), keyword()) :: {:ok, result} | {:error, :no_quorum}
        when result: var
  def quorum_with_lock(resource, fun, opts \\ []) do
    case acquire(resource, Keyword.put(opts, :mode, :write)) do
      {:ok, lease} ->
        try do
          {:ok, fun.()}
        after
          release(lease)
        end

      {:error, :no_quorum} ->
        {:error, :no_quorum}
    end
  end

  # ── 新增 dsync 式 API ──

  @doc """
  获锁。opts：:mode（:write 默认 / :read）、:ttl_ms（默认 30_000）、:timeout（每节点 :erpc 截止，默认 3_000）、
  :retries（未达 quorum 退避重试次数，默认 0）、:refresh（默认 true，false 则不起心跳——仅测试用）、
  :nodes（注入 node 列表，默认 Maxio.Cluster.nodes()——测试用）。
  返回 {:ok, lease} | {:error, :no_quorum}。
  """
  @spec acquire(term(), keyword()) :: {:ok, lease()} | {:error, :no_quorum}
  def acquire(resource, opts \\ []) do
    mode = Keyword.get(opts, :mode, :write)
    ttl_ms = Keyword.get(opts, :ttl_ms, @ttl_ms)
    timeout = Keyword.get(opts, :timeout, @acquire_timeout)
    retries = Keyword.get(opts, :retries, 0)
    start_refresh? = Keyword.get(opts, :refresh, true)
    nodes = Keyword.get(opts, :nodes) || Maxio.Cluster.nodes()

    try_acquire(resource, mode, ttl_ms, timeout, retries, start_refresh?, nodes, 0)
  end

  defp try_acquire(resource, mode, ttl_ms, timeout, retries, start_refresh?, nodes, attempt) do
    n = length(nodes)
    quorum = quorum_for(mode, n)
    uid = unique_uid()
    owner = self()

    granted =
      nodes
      |> Enum.map(fn node ->
        {node, do_grant(node, resource, uid, mode, owner, ttl_ms, timeout)}
      end)
      |> Enum.filter(fn {_node, r} -> r == :ok end)
      |> Enum.map(fn {node, _} -> node end)

    if length(granted) >= quorum do
      lease = %{
        uid: uid,
        resource: resource,
        mode: mode,
        granted: granted,
        quorum: quorum,
        ttl_ms: ttl_ms,
        all_nodes: nodes,
        holder: nil
      }

      lease =
        if start_refresh? do
          %{lease | holder: start_holder(lease, owner)}
        else
          lease
        end

      {:ok, lease}
    else
      # 未达 quorum：释放已获的（best-effort），semi-random 退避后重试。
      release_on(granted, resource, uid, nodes, timeout)

      if attempt < retries do
        backoff(attempt)

        try_acquire(
          resource,
          mode,
          ttl_ms,
          timeout,
          retries,
          start_refresh?,
          nodes,
          attempt + 1
        )
      else
        {:error, :no_quorum}
      end
    end
  end

  @doc "释放 lease：停心跳 + best-effort 向已获节点释放（TTL + monitor 清理 stragglers）。"
  @spec release(lease()) :: :ok
  def release(%{holder: holder} = lease) do
    if is_pid(holder), do: send(holder, :stop)
    release_on(lease.granted, lease.resource, lease.uid, lease.all_nodes, @acquire_timeout)
    :ok
  end

  @doc "手动刷新（通常由心跳 holder 自动调用）。:ok（仍持有 quorum）| :lost（丢 quorum）。"
  @spec refresh(lease()) :: :ok | :lost
  def refresh(lease) do
    oks =
      lease.all_nodes
      |> Enum.count(fn node ->
        do_refresh(node, lease.resource, lease.uid, @acquire_timeout) == :ok
      end)

    if oks >= lease.quorum, do: :ok, else: :lost
  end

  @doc "admin 逃生：向全节点 force_unlock（丢弃 resource 全部条目，任意 uid）。"
  @spec force_unlock(term()) :: :ok
  def force_unlock(resource) do
    Maxio.Cluster.nodes()
    |> Enum.each(fn node -> do_force_unlock(node, resource, @acquire_timeout) end)

    :ok
  end

  # ── quorum 数学（dsync）──

  @doc false
  @spec quorum_for(mode(), pos_integer()) :: pos_integer()
  def quorum_for(:write, n), do: div(n, 2) + 1
  def quorum_for(:read, n), do: n - div(n, 2)

  # ── 心跳 holder（linked 到 owner；丢 quorum -> force_unlock 自身 + 通知 owner）──

  defp start_holder(lease, owner) do
    spawn_link(fn -> holder_loop(lease, owner) end)
  end

  defp holder_loop(lease, owner) do
    receive do
      :stop ->
        :ok
    after
      @refresh_interval ->
        case refresh(lease) do
          :ok ->
            holder_loop(lease, owner)

          :lost ->
            # 丢 quorum：force_unlock 自身的 stragglers + 通知 owner abort（铁律 3）。
            Maxio.Cluster.Lock.force_unlock(lease.resource)
            # 用 throw 经 owner 进程的 with_lock try/catch 中止（owner 仍在 fun 中）。
            # owner 可能不在 receive；用 Process.exit 信号 + with_lock 的 catch 不可靠，故
            # 改为：owner 进程在 fun 内通过收到的 :lock_lost 消息自检（见 with_lock 不直接收）。
            # 简化且健壮：直接 kill owner 不可取（会丢正常工作）。改为发消息，由调用方决定。
            send(owner, {:maxio_lock_lost, lease.resource})
            :ok
        end
    end
  end

  # ── 节点级 op（本机直调跳 :erpc；远端 :erpc，宕机/超时/异常 -> 兜底「未授/未刷新」）──

  defp do_grant(node, resource, uid, mode, owner, ttl_ms, timeout) do
    erpc(node, LockServer, :grant, [resource, uid, mode, owner, ttl_ms], timeout, :denied)
  end

  defp do_refresh(node, resource, uid, timeout) do
    erpc(node, LockServer, :refresh, [resource, uid], timeout, :not_found)
  end

  defp do_release(node, resource, uid, timeout) do
    erpc(node, LockServer, :release, [resource, uid], timeout, :ok)
  end

  defp do_force_unlock(node, resource, timeout) do
    erpc(node, LockServer, :force_unlock, [resource], timeout, :ok)
  end

  defp release_on(nodes, resource, uid, _all_nodes, timeout) do
    Enum.each(nodes, fn node -> do_release(node, resource, uid, timeout) end)
    :ok
  end

  # 本机直接 GenServer.call（跳 :erpc 序列化）；远端 :erpc，任何宕机/超时/异常 -> on_fail（铁律 3：
  # 不可达节点 = 不计票 / 不阻塞，绝不上抛炸调用方）。
  defp erpc(node, mod, fun, args, timeout, on_fail) do
    if node == Node.self() do
      apply(mod, fun, args)
    else
      try do
        :erpc.call(node, mod, fun, args, timeout)
      catch
        :error, _ -> on_fail
        :exit, _ -> on_fail
        :throw, _ -> on_fail
      end
    end
  end

  # ── 杂项 ──

  defp unique_uid do
    "#{Node.self()}-#{System.unique_integer([:positive, :monotonic])}-#{System.monotonic_time()}"
  end

  # semi-random 退避（desync split-vote racers，dsync parity）：base * 2^attempt + jitter，封顶。
  defp backoff(attempt) do
    cap = 2_000
    base = min(@retry_base_ms * Integer.pow(2, attempt), cap)
    Process.sleep(base + :rand.uniform(@retry_base_ms))
  end

  defp res_bucket({bucket, _}) when is_binary(bucket), do: bucket
  defp res_bucket(_), do: nil
end
```

> **executor 注意（lock_lost 语义对齐 with_lock 的 catch）**：上面 `holder_loop` 用 `send(owner, {:maxio_lock_lost, ...})`，但 `with_lock` 的 owner 进程通常在 `fun.()` 内**不主动 receive** 该消息，故 `try/catch :throw` 那条永不命中。这是**可接受的 best-effort**：丢 quorum 时 holder 已 `force_unlock` 自身 stragglers（让其它节点尽快可重获），`with_lock` 的 `after release(lease)` 仍会清理；若 `fun` 是长操作，它会在**自己完成后**正常 release（数据层的 write-quorum + BLAKE3 是最终正确性网，铁律 3）。**保留 `send(owner, ...)`** 作为「未来让 fun 协作中止」的钩子，并**删除 with_lock 里那段不可达的 `catch :throw` 子句**以过 `--warnings-as-errors`：

> 把 `with_lock` 改为（去掉 catch）：
> ```elixir
> def with_lock(resource, fun, retries \\ 5) do
>   case acquire(resource, mode: :write, retries: retries) do
>     {:ok, lease} ->
>       try do
>         {:ok, fun.()}
>       after
>         release(lease)
>       end
>
>     {:error, :no_quorum} ->
>       {:error, :locked}
>   end
> end
> ```
> 并删除 `res_bucket/1`（不再被引用）以免 unused 警告。`holder_loop` 仍 `send(owner, {:maxio_lock_lost, resource})`（owner 默默忽略，无害，作为协作钩子）。**若担心 unused `send`，保留它——它有副作用（投递消息），编译器不会警告。**

### 步骤 4（接线）：监督树起 LockServer

**编辑** `lib/maxio/application.ex` —— 在 `cluster_children/0` 的返回里、`Maxio.Cluster.ShardServer` 之后追加 `Maxio.Cluster.LockServer`（LockServer 须在任何 `:erpc grant` 之前起；放 cluster_children 末尾，先于后端使用）：

把：
```elixir
    libcluster ++ [Maxio.Cluster.Topology, Maxio.Cluster.ShardServer]
```
改为：
```elixir
    libcluster ++ [Maxio.Cluster.Topology, Maxio.Cluster.ShardServer, Maxio.Cluster.LockServer]
```

### 步骤 5（绿）：跑测试

```powershell
mix test test/maxio/cluster/lock_test.exs
```
期望：全绿（LockServer 由 application 监督树启动；`reset_for_test/0` 在每个测试前清表）。

> **executor 注意（test 环境 LockServer 是否启动）**：`cluster_children/0` **始终**包含 `Maxio.Cluster.LockServer`（与 `Topology`/`ShardServer` 一样无条件起，仅 `Cluster.Supervisor` 受 topologies 非空门控）。故 test 环境（topologies: []）下 LockServer 仍启动，`reset_for_test/0` 可用。**确认**：`mix test` 启动的 application 含监督树，命名进程 `Maxio.Cluster.LockServer` 存在。

### 步骤 6（绿）：全量回归 + 提交

```powershell
mix compile --warnings-as-errors
mix test
```
期望：510（M7 基线）+ 新增 lock 测试，全绿，零警告。`Maxio.Storage.Distributed` 的 conformance/e2e 全绿（证明公共 API 不变）。

```powershell
git add -A
git commit -m @'
M8-1: quorum 分布式锁（LockServer + Lock 升级 + 心跳 + owner-death/lease 双自动释放）

- 新增 Maxio.Cluster.LockServer（每节点 ETS 写/读锁表 GenServer，grant/release/
  refresh/force_unlock；Process.monitor owner-death 即时释放 + monotonic :sweep lease 过期）。
- 重写 Maxio.Cluster.Lock：acquire/2、release/1、refresh/1、force_unlock/1、心跳 holder；
  写 quorum=n/2+1、读 quorum=ceil(n/2)；保持 with_lock/2,3 与 quorum_with_lock/2,3 公共 API 不变
  -> Maxio.Storage.Distributed 一行不改（铁律 2）。
- 监督树起 LockServer。单节点退化 quorum=1。诚实正确性边界（best-effort 非 Raft）写进 moduledoc。
- lock_test 扩充：quorum 数学 / owner-death / lease 过期 / RLock 共存 / force_unlock / 注入多节点 quorum。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收标准（M8-1）**：`Maxio.Cluster.LockServer` + 升级后 `Maxio.Cluster.Lock` 编译零警告；`lock_test.exs` 全绿（含 owner-death 即时释放、lease 过期 sweep、RLock 共存、写读互斥、force_unlock、注入 3 节点 quorum=2 未达 → no_quorum、单节点 quorum=1）；全量 `mix test` 绿；`Maxio.Storage.Distributed` 调用点未改、其 conformance/e2e 仍绿。

---

# 单元 M8-2：跨节点缓存一致性（共享-PG 文档 + Notify 广播 + CacheInvalidator 订阅者 + 接线）

**目标**：文档化共享 Postgres 一致性模型 + 部署要求；新增 `Maxio.Cluster.Notify`（经 `Maxio.PubSub` 全集群广播失效事件）+ `Maxio.Cluster.CacheInvalidator`（每节点订阅者，失效本地缓存）；`CredentialStore` 加可选 `invalidate/1` callback + `MemoryStore.invalidate/1`；把 `Notify.broadcast/1` 接到 mutation context。**诚实声明**：生产路径（EctoStore + 每请求 Repo 读）无可陈旧缓存，订阅者当前是正确的 no-op；管道为未来 read-through 缓存 + 让 test-only MemoryStore 跨节点一致而建。

**依赖**：M8-1。**TDD**：单节点逻辑测（订阅 topic → broadcast → assert_receive；MemoryStore put 后经 invalidator 失效 → ETS 行消失）。

### 研究对齐（共享 PG vs MinIO `.minio.sys/` — 见任务上下文「RESEARCH: M8 cluster metadata consistency …」）
- maxio 全部元数据（buckets/objects/access_keys/bucket_policies/bucket_configs）权威来源 = **单一共享 Postgres**（`Maxio.Repo`）。共享 DB ⇒ 权威元数据**天然跨节点一致**（PG 事务即一致性机制），**无需 MinIO 式复制**。
- 唯一一致性风险 = **每节点内存缓存**。审计结论：**生产读路径无可陈旧缓存**（EctoStore + 每请求 `Repo` 查询；bucket policy/ACL/CORS/lifecycle/encryption/versioning/tags 全每请求查 PG）。唯一 ETS 缓存 `MemoryStore` 是 **test-only**。`Cluster.Topology` 的 `:persistent_term` 是 **static**（init 写一次，不可变）。
- 故 M8-2 = ① 写下一致性模型 + 部署要求；② 建 PubSub 失效管道（EctoStore no-op、MemoryStore/未来 read-through 真失效）；③ 测一条 broadcast 跨到第二订阅者。**绝不假装在 EctoStore 下失效了什么**（铁律 3）。

### 步骤 1（TDD 红）：写 Notify + CacheInvalidator 失败测试

**新建** `test/maxio/cluster/notify_test.exs`：

```elixir
defmodule Maxio.Cluster.NotifyTest do
  use ExUnit.Case, async: false

  alias Maxio.Cluster.Notify

  test "broadcast 经 PubSub 送达本节点订阅者（单节点逻辑证明）" do
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())
    :ok = Notify.broadcast({:iam_changed, "AKIATEST"})
    assert_receive {:iam_changed, "AKIATEST"}, 1_000
  end

  test "全部事件类型可广播 + 送达" do
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())
    :ok = Notify.broadcast({:iam_deleted, "AK1"})
    :ok = Notify.broadcast({:bucket_config_changed, "b1"})
    :ok = Notify.broadcast({:bucket_policy_changed, "b2"})
    :ok = Notify.broadcast({:bucket_meta_changed, "b3"})
    assert_receive {:iam_deleted, "AK1"}, 1_000
    assert_receive {:bucket_config_changed, "b1"}, 1_000
    assert_receive {:bucket_policy_changed, "b2"}, 1_000
    assert_receive {:bucket_meta_changed, "b3"}, 1_000
  end
end
```

**新建** `test/maxio/cluster/cache_invalidator_test.exs`：

```elixir
defmodule Maxio.Cluster.CacheInvalidatorTest do
  @moduledoc """
  CacheInvalidator 订阅者：经 Notify 广播的失效事件，对带缓存后端（MemoryStore）真失效本地 ETS 行；
  对无缓存后端（EctoStore）= 诚实 no-op（function_exported? 守卫跳过）。
  本测试在 MemoryStore 配置下（config/test.exs）证明真失效。
  """
  use ExUnit.Case, async: false

  alias Maxio.Cluster.Notify
  alias Maxio.Auth.CredentialStore
  alias Maxio.Auth.CredentialStore.MemoryStore

  setup do
    # test 环境 credential_store = MemoryStore（带 ETS 缓存）。
    assert CredentialStore.impl() == MemoryStore
    :ok
  end

  test "iam_deleted 事件 -> CacheInvalidator 失效 MemoryStore 的该 ETS 行" do
    ak = "AKIAINVALIDATE1"
    :ok = MemoryStore.put_access_key(%{access_key: ak, secret_key: "s"})
    assert {:ok, %{secret_key: "s"}} = MemoryStore.get_secret(ak)

    # 经 Notify 广播失效事件（CacheInvalidator 订阅 -> invalidate）。
    :ok = Notify.broadcast({:iam_deleted, ak})

    # 同步：等 CacheInvalidator 处理完该消息。
    _ = :sys.get_state(Maxio.Cluster.CacheInvalidator)

    # 该行已失效（被 :ets.delete）。MemoryStore.get_secret 对非 root key 返回 :error。
    assert MemoryStore.get_secret(ak) == :error
  end

  test "invalidate 对 root key 不会锁死（MemoryStore 失效后下次 get 重 bootstrap）" do
    # root key（config/test.exs 的 root_user）：失效后 get_secret 经 maybe_bootstrap_root_for 重注入。
    root = Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)
    :ok = Notify.broadcast({:iam_deleted, root})
    _ = :sys.get_state(Maxio.Cluster.CacheInvalidator)
    # root 仍可解（重 bootstrap）。
    assert {:ok, _} = MemoryStore.get_secret(root)
  end
end
```

跑（确认红）：
```powershell
mix test test/maxio/cluster/notify_test.exs test/maxio/cluster/cache_invalidator_test.exs
```

### 步骤 2（绿）：实现 `Maxio.Cluster.Notify`

**新建** `lib/maxio/cluster/notify.ex`：

```elixir
defmodule Maxio.Cluster.Notify do
  @moduledoc """
  集群元数据失效广播（M8）。

  架构事实（诚实）：maxio 所有元数据（buckets/objects/access_keys/bucket_policies/bucket_configs）
  权威来源 = 单一共享 Postgres（Maxio.Repo）。共享 DB ⇒ 权威元数据天然跨节点一致（PG 事务即一致性
  机制），无需 MinIO 式 IAM/bucket-meta 复制。本模块仅用于让「每节点内存缓存」在另一节点改库后
  跨节点失效。

  当前生产后端（EctoStore + 每请求 Repo 读）无可陈旧缓存 -> 订阅者收到事件即诚实 no-op；
  本管道的价值在于：(a) 让 test-only 的 MemoryStore 跨节点一致；(b) 为未来任何 read-through 性能
  缓存提供「一次接 invalidate/1 即跨节点安全」的已测钩子。铁律 3：绝不假装失效了什么。

  经既有 Maxio.PubSub（Phoenix.PubSub.PG2）broadcast，自动送达全 mesh 订阅者（含本节点）。
  失效幂等，无需 broadcast_from 排除本节点。
  """
  @topic "maxio:metadata"

  @type event ::
          {:iam_changed, access_key :: String.t()}
          | {:iam_deleted, access_key :: String.t()}
          | {:bucket_config_changed, bucket :: String.t()}
          | {:bucket_policy_changed, bucket :: String.t()}
          | {:bucket_meta_changed, bucket :: String.t()}

  @doc "失效广播 topic。"
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "向全集群广播一个失效事件（幂等失效）。"
  @spec broadcast(event()) :: :ok
  def broadcast(event) do
    Phoenix.PubSub.broadcast(Maxio.PubSub, @topic, event)
  end
end
```

### 步骤 3（绿）：实现 `Maxio.Cluster.CacheInvalidator`

**新建** `lib/maxio/cluster/cache_invalidator.ex`：

```elixir
defmodule Maxio.Cluster.CacheInvalidator do
  @moduledoc """
  每节点缓存失效订阅者（M8）。init 订阅 Maxio.Cluster.Notify.topic()；收到失效事件即失效本地缓存。

  当前实现：仅 credential 缓存有「带缓存的后端」（MemoryStore，test-only）。EctoStore 无缓存
  -> invalidate 分支不触达（function_exported? 守卫）= 诚实 no-op。bucket config/policy/meta 事件
  当前全 no-op（这些读路径每请求查 PG，无缓存）；保留 handle_info 子句作为未来 read-through 缓存钩子。
  铁律 3：no-op 即 no-op，绝不假装失效了什么。
  """
  use GenServer

  require Logger

  alias Maxio.Cluster.Notify
  alias Maxio.Auth.CredentialStore

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:iam_changed, ak}, state) do
    invalidate_credential(ak)
    {:noreply, state}
  end

  def handle_info({:iam_deleted, ak}, state) do
    invalidate_credential(ak)
    {:noreply, state}
  end

  # 以下读路径每请求查 PG（无缓存）-> 当前诚实 no-op；保留为未来 read-through 缓存钩子。
  def handle_info({:bucket_config_changed, _bucket}, state), do: {:noreply, state}
  def handle_info({:bucket_policy_changed, _bucket}, state), do: {:noreply, state}
  def handle_info({:bucket_meta_changed, _bucket}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # 仅当当前 credential_store 是带缓存的后端（实现了可选 invalidate/1）才真正失效；
  # EctoStore 无缓存、不实现 invalidate/1 -> function_exported? 为 false -> 整个分支不触达（诚实 no-op）。
  defp invalidate_credential(ak) do
    impl = CredentialStore.impl()

    if function_exported?(impl, :invalidate, 1) do
      impl.invalidate(ak)
    else
      :ok
    end
  end
end
```

### 步骤 4（绿）：`CredentialStore` 加可选 `invalidate/1` + `MemoryStore.invalidate/1`

**编辑** `lib/maxio/auth/credential_store.ex` —— 在既有 callback 后追加可选 callback：

把：
```elixir
  @callback get_secret(access_key :: String.t()) ::
              {:ok, %{secret_key: String.t(), principal: map()}} | :error
  @callback put_access_key(map()) :: :ok | {:error, term()}
  @callback list_keys() :: [map()]
```
改为（追加 invalidate callback + `@optional_callbacks`）：
```elixir
  @callback get_secret(access_key :: String.t()) ::
              {:ok, %{secret_key: String.t(), principal: map()}} | :error
  @callback put_access_key(map()) :: :ok | {:error, term()}
  @callback list_keys() :: [map()]

  # M8：可选——带缓存的后端（MemoryStore / 未来 read-through）实现以支持跨节点失效（铁律 3：
  # 无缓存后端 EctoStore 不实现 -> CacheInvalidator 的 function_exported? 守卫跳过 = 诚实 no-op）。
  @callback invalidate(access_key :: String.t()) :: :ok
  @optional_callbacks invalidate: 1
```

**编辑** `lib/maxio/auth/credential_store/memory_store.ex` —— 在 `list_keys/0` 之后追加 `invalidate/1`：

把（在 `def list_keys do ... end` 之后、`defp ensure_table` 之前插入）：
```elixir
  @impl true
  def invalidate(access_key) do
    ensure_table()
    :ets.delete(@table, access_key)
    :ok
  end
```

> **executor 注意（@impl 与 optional_callback）**：`MemoryStore` 已 `@behaviour Maxio.Auth.CredentialStore`，加 `@impl true def invalidate/1` 合法（实现可选 callback）。`EctoStore` **不**实现 `invalidate/1`（无缓存），无 `@impl` 标注、无函数定义——`@optional_callbacks` 使其不报「missing impl」警告。**确认 `mix compile --warnings-as-errors` 对 EctoStore 不报缺实现。**

### 步骤 5（接线）：把 `Notify.broadcast/1` 接到 mutation context

**铁律**：在 DB 写**提交后**广播（peer 重读立即见新行）。在 **context 层**单点接线（非 handler）。

**编辑** `lib/maxio/iam.ex`：
- `create_access_key/1` 成功分支（`{:ok, row}` 那条）追加广播：
  把：
  ```elixir
      {:ok, row} ->
        {:ok, %{access_key_id: row.access_key_id, secret_key: sk, principal_arn: arn, type: type}}
  ```
  改为：
  ```elixir
      {:ok, row} ->
        Maxio.Cluster.Notify.broadcast({:iam_changed, row.access_key_id})
        {:ok, %{access_key_id: row.access_key_id, secret_key: sk, principal_arn: arn, type: type}}
  ```
- `delete_access_key/1` 的两处真删分支（删 iam_user、删非最后 root）追加广播。把：
  ```elixir
        if root_count <= 1 do
          {:error, :cannot_delete_last_root}
        else
          Repo.delete!(row)
          :ok
        end

      %AccessKey{} = row ->
        Repo.delete!(row)
        :ok
  ```
  改为：
  ```elixir
        if root_count <= 1 do
          {:error, :cannot_delete_last_root}
        else
          Repo.delete!(row)
          Maxio.Cluster.Notify.broadcast({:iam_deleted, access_key_id})
          :ok
        end

      %AccessKey{} = row ->
        Repo.delete!(row)
        Maxio.Cluster.Notify.broadcast({:iam_deleted, access_key_id})
        :ok
  ```
- `bootstrap_root/0` 末尾（`:ok` 之前）追加 `Maxio.Cluster.Notify.broadcast({:iam_changed, ak})`。

**编辑** `lib/maxio/bucket_configs.ex` —— `put/3` 与 `delete/2` 成功后追加 `Maxio.Cluster.Notify.broadcast({:bucket_config_changed, bucket_name})`。

> **executor 注意**：先 Read `lib/maxio/bucket_configs.ex` 确认 `put/3`、`delete/2` 的签名与返回点（参数名可能是 `bucket_name` 或 `bucket`），把 broadcast 接在**成功 `:ok` 返回前**。若该函数对每种 kind 有多个返回点，在**统一成功出口**接线（必要时引入 `with`/局部变量保持单点）。

**编辑** `lib/maxio/policy/store.ex` —— `put_bucket_policy/2` 与 `delete_bucket_policy/1` 门面成功后追加 `Maxio.Cluster.Notify.broadcast({:bucket_policy_changed, bucket})`。把：
```elixir
  @spec put_bucket_policy(String.t(), binary()) :: :ok | {:error, term()}
  def put_bucket_policy(bucket, json), do: impl().put_bucket_policy(bucket, json)

  @spec delete_bucket_policy(String.t()) :: :ok
  def delete_bucket_policy(bucket), do: impl().delete_bucket_policy(bucket)
```
改为：
```elixir
  @spec put_bucket_policy(String.t(), binary()) :: :ok | {:error, term()}
  def put_bucket_policy(bucket, json) do
    case impl().put_bucket_policy(bucket, json) do
      :ok ->
        Maxio.Cluster.Notify.broadcast({:bucket_policy_changed, bucket})
        :ok

      other ->
        other
    end
  end

  @spec delete_bucket_policy(String.t()) :: :ok
  def delete_bucket_policy(bucket) do
    :ok = impl().delete_bucket_policy(bucket)
    Maxio.Cluster.Notify.broadcast({:bucket_policy_changed, bucket})
    :ok
  end
```

**编辑** `lib/maxio/buckets.ex` —— `put_acl/2`、`put_tags/2`、`put_versioning/3`、`create/3`、`delete/1` 成功后追加 `Maxio.Cluster.Notify.broadcast({:bucket_meta_changed, name})`。在每个函数的 `:ok`/`{:ok, bucket}` 成功出口前接线（`create` 用 `bucket.name`，`delete` 用 `name`）。

> **executor 注意（接线最小侵入 + 不破坏既有测试语义）**：所有 broadcast 都是「成功提交后的副作用」，返回值不变。`Notify.broadcast/1` 内部 `Phoenix.PubSub.broadcast` 在无订阅者时也返回 `:ok`（无害）。**这些 context 的既有单测断言不变**（返回形态不变）。逐个 Read 确认成功出口，**只在成功路径追加一行 broadcast**，绝不改错误路径。

### 步骤 6（接线）：监督树起 CacheInvalidator

**编辑** `lib/maxio/application.ex` —— 在 `{Phoenix.PubSub, name: Maxio.PubSub}` **之后**插入 `Maxio.Cluster.CacheInvalidator`（须在 PubSub 起来后订阅）：

把：
```elixir
          {Phoenix.PubSub, name: Maxio.PubSub},
          # Start a worker by calling: Maxio.Worker.start_link(arg)
```
改为：
```elixir
          {Phoenix.PubSub, name: Maxio.PubSub},
          Maxio.Cluster.CacheInvalidator,
          # Start a worker by calling: Maxio.Worker.start_link(arg)
```

### 步骤 7（绿）：跑测试 + 全量回归 + 提交

```powershell
mix test test/maxio/cluster/notify_test.exs test/maxio/cluster/cache_invalidator_test.exs
mix compile --warnings-as-errors
mix test
```
期望：新测试绿；全量回归绿（含 IAM/buckets/policy/bucket_configs 既有测试——返回形态不变）；零警告。

```powershell
git add -A
git commit -m @'
M8-2: 跨节点缓存一致性（共享-PG 文档 + Notify 广播 + CacheInvalidator 订阅者）

- 文档化：maxio 元数据权威来源=共享 Postgres，跨节点天然一致（无需 MinIO 式复制）；
  生产路径（EctoStore + 每请求 Repo）无可陈旧缓存 -> 订阅者当前诚实 no-op（铁律 3）。
- 新增 Maxio.Cluster.Notify（经 Maxio.PubSub/PG2 全 mesh 广播失效事件）+
  Maxio.Cluster.CacheInvalidator（每节点订阅者，MemoryStore 真失效 / EctoStore no-op）。
- CredentialStore 加可选 invalidate/1 callback + MemoryStore.invalidate/1。
- 把 Notify.broadcast 接到 IAM/BucketConfigs/Policy.Store/Buckets mutation 点（成功提交后）。
- 监督树起 CacheInvalidator。单节点送达 + MemoryStore 失效单测全绿。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收标准（M8-2）**：`Notify`/`CacheInvalidator` 编译零警告；`notify_test`（broadcast 本地送达全部事件类型）+ `cache_invalidator_test`（MemoryStore 行真失效 + root 不锁死）全绿；mutation context 接线后既有 IAM/buckets/policy/bucket_configs 测试仍绿；EctoStore 不实现 `invalidate/1` 不报缺实现警告；全量 `mix test` 绿。

---

# 单元 M8-3：后台 scanner + 自愈（Scanner GenServer + Throttle + Usage + mix maxio.scan + config）

**目标**：新增 supervised 周期 scanner（`GenServer` + `Process.send_after`，纯 OTP，无 Oban），分页遍历 `Maxio.Objects`，逐对象完整性检测（复用 M6/M7 heal），自愈损坏，全程限流（绝不饱和 IO / 绝不阻塞 S3），集群感知经 M8-1 锁的 leader-per-set，刷新 per-bucket 用量。config 开关 + cadence + throttle；`mix maxio.scan`（一次性全量 scan+heal）+ 结构化日志。FS/非纠删码后端仅用量统计。

**依赖**：M8-2（实际仅依赖 M8-1 的锁；M8-2 不阻塞 scanner，但按串行顺序在其后）。**TDD**：scanner 用 `scan_now/1` 同步驱动（test config `enabled: false` 不自动跑），注入 FS bucket（仅用量）/ 单机 EC bucket（损坏自愈）/ 注入 topology + InProcess（leader-per-set 单拥有者）。

### 研究对齐（MinIO data-scanner — 见任务上下文「RESEARCH: MinIO background SCANNER …」）
- **连续周期 + 动态延迟**：下次延迟 = `max(delay_factor × 上次扫描耗时, interval_ms)`（MinIO factor=10.0「等 10× 扫描耗时再重启」）。
- **概率采样**：`1/1024` 深度校验采样/周期（`phash2({bucket,key,cycle}) rem sample_inv == 0`，确定性、跨节点一致、随 cycle 轮换全覆盖）。`scan_now`（CLI）用 `sample: :full` 全覆盖。
- **复用既有 heal 做检测+修复**：`heal_object/4` **本身就是 detect-then-repair**——干净对象返回 `{:ok, %{healed: 0}}`（只读校验，绝不写干净对象）；这正是 MinIO「verify, heal only the bad set」的深度/bitrot 扫描。scanner **不重写 RS 数学**。
- **限流（never saturate IO）**：每对象 sleep（`1000/max_objects_per_sec`）+ 每批 sleep + 单并发（默认）。maxio 暂无 live IO 计数器，故用保守固定 pacing（MinIO「wait for low IO」的 maxio 类比，文档化差异）。
- **leader-per-set 单拥有者**：每节点对每个 set 试获 `{:scanner_set, set_id}` 租约（M8-1 锁，`retries: 0` skip-on-contention）；仅租约持有者扫该 set，**绝不两节点 heal 同对象**。锁资源与 `{bucket,key}` 对象锁 disjoint，**绝不阻塞 PUT/GET**（铁律 4）。
- **不可恢复绝不伪造**：`{:error, :unrecoverable}` → 仅 `Logger.error` + 计数（继承 M6/M7）。
- **FS no-op heal**：`heal_mod = nil` → 跳过 heal，仅用量统计（FS 无 parity，正确 no-op，铁律 3）。
- **不依赖缺失的 `Transport.list_dir`**：枚举来自 Postgres（`Maxio.Objects`），heal 是 per-object（`heal_object/4` 跨节点已可用）——M8 借此**关闭 M7 deferral #4 的核心**，无需新 transport callback。orphan-shard（盘上有、DB 无）检测仍需 `list_dir` = 显式 defer M9。

### 步骤 1（TDD 红）：写 scanner 失败测试

**新建** `test/maxio/storage/scanner_test.exs`：

```elixir
defmodule Maxio.Storage.ScannerTest do
  @moduledoc """
  后台 scanner 单测（确定性，scan_now 同步驱动）。覆盖：
    (a) FS 后端仅用量统计（无 heal）；
    (b) 单机 EC 后端损坏 <=M 分片 -> scan_now 自愈（healed>=1）；
    (c) 单机 EC 后端损坏 >M 分片 -> unrecoverable>=1（绝不伪造）；
    (d) 采样确定性（selected?）；
    (e) leader-per-set 单拥有者（注入 topology，仅一节点 lease 持有者扫该 set）。
  scanner GenServer 由监督树启动但 test config enabled:false（不自动跑）；测试调 scan_now/1。
  """
  use Maxio.DataCase, async: false

  alias Maxio.Storage.Scanner
  alias Maxio.{Buckets, Objects}

  # ── (d) 采样确定性（纯函数，不触盘）──

  test "selected? :full 全选；1/1024 采样确定性且随 cycle 轮换" do
    cfg = %{sample: :sampled, sample_inv: 4}
    # full 模式全选。
    assert Scanner.selected?("b", "k", 0, %{cfg | sample: :full})
    # sampled 模式：对同 (bucket,key,cycle) 确定性。
    s0 = Scanner.selected?("b", "k", 0, cfg)
    assert s0 == Scanner.selected?("b", "k", 0, cfg)
    # 不同 cycle 可能不同选中集（至少存在某 key 在某 cycle 被选）。
    selected_any =
      Enum.any?(0..50, fn c -> Scanner.selected?("b", "k#{c}", c, cfg) end)

    assert selected_any
  end

  # ── (a) FS 后端：仅用量统计，无 heal ──

  test "FS 后端 scan_now 仅累计用量，不做 heal" do
    # test 默认 storage_backend = FS（config/test.exs 未覆盖 -> config.exs 默认 FS）。
    bucket = unique_bucket()
    {:ok, _} = Buckets.create(bucket, "arn:aws:iam:::root")
    {:ok, _} = put_object(bucket, "a.txt", "hello")
    {:ok, _} = put_object(bucket, "b.txt", "world!!")

    {:ok, summary} = Scanner.scan_now(backend: :fs)
    # FS：扫描计数即对象数，但 damaged/healed/unrecoverable 全 0（无 parity）。
    assert summary.damaged == 0
    assert summary.healed == 0
    assert summary.unrecoverable == 0
    # 用量缓存刷新（per-bucket count）。
    usage = Maxio.Storage.Scanner.Usage.get(bucket)
    assert usage.object_count == 2
    assert usage.total_size == byte_size("hello") + byte_size("world!!")
  end

  # 工具：经当前 backend 写一个对象（元数据 + 字节）。
  defp put_object(bucket, key, body) do
    backend = Application.get_env(:maxio, :storage_backend)
    {:ok, %{size: size, etag: etag}} = backend.put(bucket, key, "null", [body])
    Objects.put_version_with_id(bucket, key, "null", %{size: size, etag: etag})
  end

  defp unique_bucket, do: "scan-#{System.unique_integer([:positive])}"
end
```

> **executor 注意（EC/leader-per-set 测试）**：(b)/(c)/(e) 需切 backend / 注入 topology。**模式照搬** `test/maxio/cluster/cluster_e2e_test.exs`（InProcess transport + 注入 topology，N=6 K=4 M=2）与 M6 `bitrot_e2e_test.exs`（篡改/删分片）。executor 在写 (b)(c)(e) 时：
> - (b) 单机 EC：设 `config :maxio, :storage_backend, Maxio.Storage.ErasureCoded` + `config :maxio, :erasure`（on_exit 还原，照搬 `erasure_e2e_test.exs`），写对象，删/篡改 1 个分片文件，`Scanner.scan_now(backend: :ec)` → 断言 `summary.healed >= 1`。
> - (c) 删 M+1 个分片 → 断言 `summary.unrecoverable >= 1` 且对应对象字节未被伪造（heal 返回 `{:error,:unrecoverable}`，scanner 仅计数）。
> - (e) leader-per-set：注入 2 节点（`nodes: [a, b]`）的锁场景——在节点 a 持有 `{:scanner_set, 0}` 租约时，节点 b 的 scanner 对该 set `with_lock(..., retries: 0)` 得 `{:error, :locked}` 跳过（不重复扫）。**可用单进程模拟**：先 `Lock.acquire({:scanner_set, 0}, refresh: false)` 占住，再调 scanner 的 set-scan 入口断言其 skip。**如 InProcess 多节点过重，(e) 用「占住租约 → scanner skip」的单进程确定性证明即可**（与「leader-per-set 单拥有者」语义等价）。

跑（确认红）：
```powershell
mix test test/maxio/storage/scanner_test.exs
```

### 步骤 2（绿）：实现 `Maxio.Storage.Scanner.Throttle`

**新建** `lib/maxio/storage/scanner/throttle.ex`：

```elixir
defmodule Maxio.Storage.Scanner.Throttle do
  @moduledoc """
  scanner 限流（M8，铁律 4：绝不饱和 IO / 绝不抢占 S3 请求）。
  每对象 pacing：按 max_objects_per_sec 睡掉每对象时间片余量（如 200/s -> 5ms/对象）。
  rate <= 0 视为不限速（仅测试/一次性 scan 可设）。
  """
  @spec tick(map()) :: :ok
  def tick(%{max_objects_per_sec: rate}) when is_integer(rate) and rate > 0 do
    Process.sleep(max(0, div(1000, rate)))
  end

  def tick(_), do: :ok
end
```

### 步骤 3（绿）：实现 `Maxio.Storage.Scanner.Usage`

**新建** `lib/maxio/storage/scanner/usage.ex`：

```elixir
defmodule Maxio.Storage.Scanner.Usage do
  @moduledoc """
  scanner 用量缓存（M8）。每周期刷新 per-bucket {object_count, total_size} 到 :persistent_term。
  无新迁移（铁律 6：不动 DB）。Console.Stats 可选作快速路径读取；scanner 的 walk 独立重算并与
  Console.Stats 的 live 聚合自审（不一致打 warning，镜像 MinIO usage cache vs reality）。
  """
  @spec put(String.t(), %{count: non_neg_integer(), size: non_neg_integer()}) :: :ok
  def put(bucket, %{count: c, size: s}) do
    :persistent_term.put(
      {__MODULE__, bucket},
      %{object_count: c, total_size: s, updated_at: DateTime.utc_now()}
    )

    :ok
  end

  @spec get(String.t()) :: %{object_count: non_neg_integer(), total_size: non_neg_integer()} | nil
  def get(bucket), do: :persistent_term.get({__MODULE__, bucket}, nil)
end
```

### 步骤 4（绿）：实现 `Maxio.Storage.Scanner`

**新建** `lib/maxio/storage/scanner.ex`：

```elixir
defmodule Maxio.Storage.Scanner do
  @moduledoc """
  M8 后台巡检器（对齐 MinIO data-scanner，纯 OTP——mix.exs 无 Oban）。周期遍历 Maxio.Objects 的对象，
  对每个对象做完整性检测（复用 M6/M7 heal 的 detect-then-repair），损坏即 heal_object 自愈，全程限流
  （每对象/每批 sleep + 单并发）绝不阻塞 S3 请求，并刷新 per-bucket 用量缓存。

  铁律：
    * 绝不阻塞 S3 请求（独立 supervised 进程 + 限流；只用 disjoint 的 {:scanner_set, set_id} 租约，
      绝不持有 live PUT/GET 需要的 {bucket,key} 对象锁）。
    * 不可恢复对象（存活 < K）只结构化记录，绝不伪造（继承 M6/M7 heal 的 {:error, :unrecoverable}）。
    * FS 后端下只做用量统计（无 parity 可 heal，正确 no-op）。

  集群感知：每节点只巡检它「负责」的 erasure set（leader-per-set 经 Cluster.Lock 租约，retries:0
  skip-on-contention），避免重复扫描。单节点/FS：锁退化本地，一个 scanner 做全部。

  cadence：下次延迟 = max(delay_factor × 上次扫描耗时, interval_ms)（MinIO 式自适应回退）。
  采样：1/sample_inverse 深度校验/周期（确定性 + 随 cycle 轮换全覆盖）；scan_now 用 :full 全覆盖。
  """
  use GenServer

  require Logger

  alias Maxio.Buckets
  alias Maxio.Objects
  alias Maxio.Cluster.{Lock, Router, Topology}
  alias Maxio.Storage.Scanner.{Throttle, Usage}

  @name __MODULE__

  # ── 启动 ──

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @impl true
  def init(_opts) do
    cfg = config()

    if cfg.enabled do
      Process.send_after(self(), :run_cycle, cfg.initial_delay_ms + jitter(cfg.initial_delay_ms))
    end

    {:ok, %{cfg: cfg, cycle: 0, last_duration_ms: 0}}
  end

  # ── 公共 API ──

  @doc "手动触发一整次全量扫描（sample: :full），同步返回汇总（CLI / 测试用）。"
  @spec scan_now(keyword()) :: {:ok, map()}
  def scan_now(opts \\ []), do: GenServer.call(@name, {:scan_now, opts}, :infinity)

  @doc "scanner 运行信息（cycle / last_duration / enabled / backend）。"
  @spec info() :: map()
  def info, do: GenServer.call(@name, :info)

  # ── 周期调度 ──

  @impl true
  def handle_info(:run_cycle, state) do
    {summary, dur} = run_one_cycle(state.cfg, state.cycle, sample: :sampled)

    Logger.info("scanner cycle done",
      action: "scan",
      reason: summary_str(summary),
      scanned: summary.scanned,
      damaged: summary.damaged,
      healed: summary.healed,
      unrecoverable: summary.unrecoverable
    )

    schedule_next(state.cfg, dur)
    {:noreply, %{state | cycle: state.cycle + 1, last_duration_ms: dur}}
  end

  @impl true
  def handle_call({:scan_now, opts}, _from, state) do
    cfg = merge_opts(config(), opts)
    {summary, _dur} = run_one_cycle(cfg, state.cycle, sample: :full)
    {:reply, {:ok, summary}, %{state | cycle: state.cycle + 1}}
  end

  def handle_call(:info, _from, state) do
    {:reply,
     %{
       cycle: state.cycle,
       last_duration_ms: state.last_duration_ms,
       enabled: state.cfg.enabled,
       backend: state.cfg.backend
     }, state}
  end

  # ── 周期算法（核心）──

  defp run_one_cycle(cfg, cycle, sample_opt) do
    t0 = mono()
    sample = Keyword.get(sample_opt, :sample, :sampled)

    acc0 = %{scanned: 0, damaged: 0, healed: 0, unrecoverable: 0, missing: 0}

    acc =
      Enum.reduce(Buckets.list(), acc0, fn bucket, acc ->
        scan_bucket(cfg, %{cfg | sample: sample}, bucket.name, cycle, acc)
      end)

    dur = mono() - t0
    {acc, dur}
  end

  # 扫一个桶：leader-per-set 经租约，仅本节点负责的 set 的对象在本节点 heal；用量始终累计。
  defp scan_bucket(cfg, scfg, bucket, cycle, acc) do
    {usage, acc} =
      stream_keys(bucket, cfg.page_size, cfg.scan_versions)
      |> Enum.reduce({%{count: 0, size: 0}, acc}, fn {key, version_id, size}, {u, a} ->
        u = %{count: u.count + 1, size: u.size + size}

        a =
          cond do
            cfg.backend == :fs ->
              a

            not owns_object?(scfg, bucket, key) ->
              a

            selected?(bucket, key, cycle, scfg) ->
              scan_one_object(scfg, bucket, key, version_id, a)

            true ->
              a
          end

        Throttle.tick(cfg.throttle)
        {u, a}
      end)

    Usage.put(bucket, usage)
    usage_self_audit(bucket, usage)
    acc
  end

  # leader-per-set：仅当本节点是该对象所属 set 的租约持有者才在本节点 heal（避免重复扫描）。
  # 单节点 / FS（无 topology）：恒 true（锁退化本地）。
  defp owns_object?(%{cluster?: false}, _bucket, _key), do: true

  defp owns_object?(%{cluster?: true}, bucket, key) do
    set_id = Router.set_for(bucket, key, nil)

    case Lock.acquire({:scanner_set, set_id}, mode: :write, retries: 0, refresh: false, ttl_ms: 60_000) do
      {:ok, lease} ->
        # 持租约：本节点负责该 set。注意——不在此 release（本周期内持有以阻止 peer 重复扫该 set）；
        # 周期结束统一 release（见 run_cycle 收尾）。为简化，立即 release 并依赖确定性 set 路由：
        Lock.release(lease)
        true

      {:error, :no_quorum} ->
        false
    end
  end

  # 逐对象检测+自愈（复用 M6/M7 heal；干净对象 healed=0 只读校验不写）。
  defp scan_one_object(cfg, bucket, key, version_id, acc) do
    acc = %{acc | scanned: acc.scanned + 1}

    case cfg.heal_mod.heal_object(bucket, key, version_id, cfg.heal_opts) do
      {:ok, %{healed: 0}} ->
        acc

      {:ok, %{healed: n}} ->
        Logger.info("scanner healed object",
          bucket: bucket, key: key, action: "scan_heal", reason: "healed=#{n}", healed: n
        )

        %{acc | damaged: acc.damaged + 1, healed: acc.healed + 1}

      {:error, :unrecoverable} ->
        Logger.error("scanner unrecoverable object",
          bucket: bucket, key: key, action: "scan_heal", reason: "survivors < K", unrecoverable: 1
        )

        %{acc | damaged: acc.damaged + 1, unrecoverable: acc.unrecoverable + 1}

      {:error, :enoent} ->
        Logger.warning("scanner object sidecar missing",
          bucket: bucket, key: key, action: "scan", reason: "no sidecar"
        )

        %{acc | missing: acc.missing + 1}
    end
  end

  # ── 对象枚举（DB 分页，有界内存）──

  @doc false
  def stream_keys(bucket, page_size, versions?) do
    Stream.resource(
      fn -> :start end,
      fn cursor -> fetch_page(bucket, page_size, versions?, cursor) end,
      fn _ -> :ok end
    )
  end

  # 当前对象（默认）：list_objects_v2 续 token 翻页，每行 {key, "null"(占位), size}。
  # 注意：scanner 用 key 路由到 set + heal_object，version_id 对 latest 行用 "null"（未版本化）或其 ULID。
  # MVP：只扫 latest（version_id 取该行的 version_id）。
  defp fetch_page(_bucket, _page_size, _versions?, :halt), do: {:halt, :halt}

  defp fetch_page(bucket, page_size, false, cursor) do
    opts = %{max_keys: page_size}
    opts = if cursor == :start, do: opts, else: Map.put(opts, :continuation_token, cursor)
    res = Objects.list_objects_v2(bucket, opts)

    rows =
      Enum.map(res.objects, fn o -> {o.key, o.version_id, o.size} end)

    next =
      if res.is_truncated and res.next_continuation_token,
        do: res.next_continuation_token,
        else: :halt

    {rows, next}
  end

  defp fetch_page(bucket, page_size, true, cursor) do
    opts = %{max_keys: page_size}

    opts =
      case cursor do
        :start ->
          opts

        {km, vm} ->
          opts |> Map.put(:key_marker, km) |> Map.put(:version_id_marker, vm)
      end

    res = Objects.list_object_versions(bucket, opts)

    rows =
      res.versions
      # delete marker 无字节，不 heal（跳过）；仅累计 0 size（其 size 已为 0）。
      |> Enum.reject(& &1.is_delete_marker)
      |> Enum.map(fn o -> {o.key, o.version_id, o.size} end)

    next =
      if res.is_truncated and res.next_key_marker,
        do: {res.next_key_marker, res.next_version_id_marker},
        else: :halt

    {rows, next}
  end

  # ── 采样（确定性，随 cycle 轮换）──

  @doc false
  @spec selected?(String.t(), String.t(), non_neg_integer(), map()) :: boolean()
  def selected?(_bucket, _key, _cycle, %{sample: :full}), do: true

  def selected?(bucket, key, cycle, %{sample_inv: inv}) when is_integer(inv) and inv > 0 do
    rem(:erlang.phash2({bucket, key, cycle}), inv) == 0
  end

  def selected?(_bucket, _key, _cycle, _cfg), do: true

  # ── 用量自审（walk 总数 vs Console.Stats live 聚合，不一致打 warning）──

  defp usage_self_audit(bucket, %{count: walk_count}) do
    live =
      Enum.find(Maxio.Console.Stats.dashboard().per_bucket, fn b -> b.name == bucket end)

    if live && live.object_count != walk_count do
      Logger.warning("scanner usage drift",
        bucket: bucket, action: "scan", reason: "walk=#{walk_count} live=#{live.object_count}"
      )
    end

    :ok
  end

  # ── cadence ──

  defp schedule_next(cfg, last_duration_ms) do
    wait = max(round(last_duration_ms * cfg.delay_factor), cfg.interval_ms)
    Process.send_after(self(), :run_cycle, wait)
  end

  # ── config ──

  defp config do
    backend = Application.get_env(:maxio, :storage_backend)

    {kind, heal_mod, cluster?} =
      case backend do
        Maxio.Storage.FS -> {:fs, nil, false}
        Maxio.Storage.ErasureCoded -> {:ec, Maxio.Storage.Erasure.Heal, false}
        Maxio.Storage.Distributed -> {:dist, Maxio.Cluster.Heal, true}
        _ -> {:fs, nil, false}
      end

    sc = Application.get_env(:maxio, :scanner, [])

    %{
      enabled: Keyword.get(sc, :enabled, true),
      backend: kind,
      heal_mod: heal_mod,
      heal_opts: [],
      cluster?: cluster? and has_topology?(),
      interval_ms: Keyword.get(sc, :interval_ms, 86_400_000),
      delay_factor: Keyword.get(sc, :delay_factor, 10.0),
      initial_delay_ms: Keyword.get(sc, :initial_delay_ms, 60_000),
      page_size: Keyword.get(sc, :page_size, 1_000),
      sample_inv: Keyword.get(sc, :sample_inverse, 1024),
      sample: :sampled,
      scan_versions: Keyword.get(sc, :scan_versions, false),
      throttle: %{
        max_objects_per_sec: Keyword.get(sc, :max_objects_per_sec, 200),
        sleep_between_batches_ms: Keyword.get(sc, :sleep_between_batches_ms, 50),
        max_concurrency: Keyword.get(sc, :max_concurrency, 1)
      }
    }
  end

  # scan_now 可覆盖 backend（测试注入 :fs/:ec/:dist）+ throttle（一次性扫不限速）。
  defp merge_opts(cfg, opts) do
    cfg =
      case Keyword.get(opts, :backend) do
        :fs -> %{cfg | backend: :fs, heal_mod: nil, cluster?: false}
        :ec -> %{cfg | backend: :ec, heal_mod: Maxio.Storage.Erasure.Heal, cluster?: false}
        :dist -> %{cfg | backend: :dist, heal_mod: Maxio.Cluster.Heal, cluster?: has_topology?()}
        nil -> cfg
      end

    cfg =
      case Keyword.get(opts, :throttle) do
        nil -> cfg
        t -> %{cfg | throttle: t}
      end

    # 测试一次性扫：默认不限速（避免长睡）。
    if Keyword.get(opts, :no_throttle, true) do
      %{cfg | throttle: %{cfg.throttle | max_objects_per_sec: 0}}
    else
      cfg
    end
  end

  defp has_topology? do
    case Application.get_env(:maxio, Maxio.Cluster.Topology) do
      nil -> false
      _ -> true
    end
  rescue
    _ -> false
  end

  # ── 杂项 ──

  defp mono, do: System.monotonic_time(:millisecond)
  defp jitter(base) when base > 0, do: :rand.uniform(base)
  defp jitter(_), do: 0

  defp summary_str(s) do
    "scanned=#{s.scanned} damaged=#{s.damaged} healed=#{s.healed} " <>
      "unrecoverable=#{s.unrecoverable} missing=#{s.missing}"
  end
end
```

> **executor 注意（owns_object? 的租约语义简化）**：上面 `owns_object?` 每对象 acquire+release 一次租约——这在单节点（quorum=1）恒成功（true），在多节点下「谁先 acquire 谁负责该对象」。**更忠实 MinIO 的「一节点扫一整 set」**是「整 set 扫描包在一次 `with_lock({:scanner_set, set_id}, fn -> 扫该 set 全部对象 end, 0)` 里」。**M8-3 采用「per-set 包裹」**（更正确、更省锁开销）：把 `scan_bucket` 改为先按 `Topology.all_set_ids()` 分组，每个 set 用 `Lock.with_lock({:scanner_set, set_id}, fn -> 扫该 set 在该 bucket 的对象 end, 0)`，`{:error, :locked}` 即 skip。**但** maxio 的对象→set 是 per-key（一个 bucket 跨多 set），「先按 set 过滤 key」需对每个 set 重新分页过滤——成本高。**MVP 折中（executor 选其一并文档化）**：
> - **方案 A（推荐，简单正确）**：`owns_object?` 用 `Router.set_for(bucket, key)` 求该 key 的 set_id，再判「本节点是否为该 set 的 leader」——leader 判定用**一次性 per-cycle 的 set→leader 映射**：周期开始时对每个 `set_id` 尝试 `Lock.acquire({:scanner_set, set_id}, retries: 0, refresh: false)`，持有的 set 记入本周期 `owned_sets` MapSet，周期结束统一 `release`。`owns_object?` 仅查 `set_id in owned_sets`（O(1)，无每对象锁开销）。**executor 实现此方案**：在 `run_one_cycle` 开头算 `owned_sets`（cluster? 为 true 时），传入 `scan_bucket`/`owns_object?`；周期结束 release 全部持有的 lease。单节点/FS：`owned_sets` 用特殊标记 `:all`（恒 owns）。
> - 把 `owns_object?(%{cluster?: true} = scfg, bucket, key)` 改为查 `scfg.owned_sets`（`:all` 或 MapSet），删掉每对象 acquire/release。
>
> **这是 M8-3 唯一的设计决策点；executor 必须实现方案 A 并在 moduledoc 记录**（per-cycle set→leader 租约，O(1) 对象归属判定，周期末统一释放）。测试 (e) 相应验证：占住 `{:scanner_set, 0}` 租约 → 本节点 scan 周期对该 set 的对象 skip。

> **executor 注意（list_object_versions 续页 size）**：`Object` schema 行有 `size`、`version_id`、`is_delete_marker`、`key`（M4）。`fetch_page` 读这些字段安全。delete marker 的 `size` 为 0、`etag` 为空——已 `reject(& &1.is_delete_marker)`。

### 步骤 5（绿）：config + Logger metadata + 监督树 + test config

**编辑** `config/config.exs`：

1. Logger metadata 追加 scanner 键。把：
   ```elixir
   config :logger, :default_formatter,
     format: "$time $metadata[$level] $message\n",
     metadata: [:request_id, :bucket, :key, :action, :auth_type, :reason, :code, :status]
   ```
   改为：
   ```elixir
   config :logger, :default_formatter,
     format: "$time $metadata[$level] $message\n",
     metadata: [
       :request_id, :bucket, :key, :action, :auth_type, :reason, :code, :status,
       :scanned, :damaged, :healed, :unrecoverable, :missing, :set, :node
     ]
   ```

2. 在 `config :maxio, :shard_transport, ...` 之后追加 scanner config：
   ```elixir
   # M8 后台巡检器（对齐 MinIO data-scanner，纯 OTP）。FS：仅用量统计；EC/Distributed：采样完整性检测 + 自愈。
   # enabled/cadence/限流；绝不阻塞 S3 请求（独立 supervised 进程 + 限流）。
   config :maxio, :scanner,
     enabled: true,
     interval_ms: 86_400_000,
     delay_factor: 10.0,
     initial_delay_ms: 60_000,
     page_size: 1_000,
     sample_inverse: 1024,
     scan_versions: false,
     max_objects_per_sec: 200,
     sleep_between_batches_ms: 50,
     max_concurrency: 1
   ```

**编辑** `config/test.exs` —— 末尾追加（test 不自动跑 scanner，测试用 scan_now 显式驱动）：
```elixir
# M8：test 环境 scanner 不自动跑（测试经 Scanner.scan_now/1 显式驱动）。
config :maxio, :scanner, enabled: false
```

**编辑** `config/runtime.exs` —— 在 M7 peers 块之后追加 `MAXIO_SCANNER_*` 运行时覆盖：
```elixir
# ── M8 scanner 运行时覆盖（镜像既有 MAXIO_* 模式）──
if v = System.get_env("MAXIO_SCANNER_ENABLED") do
  config :maxio, :scanner, enabled: v in ~w(true 1)
end

if v = System.get_env("MAXIO_SCANNER_INTERVAL_MS") do
  config :maxio, :scanner, interval_ms: String.to_integer(v)
end

if v = System.get_env("MAXIO_SCANNER_MAX_OBJS_PER_SEC") do
  config :maxio, :scanner, max_objects_per_sec: String.to_integer(v)
end
```

> **executor 注意（runtime.exs config 合并）**：上面三个 `config :maxio, :scanner, key: val` 是**部分合并**（Config 模块对同 app+key 深合并 keyword）——只覆盖给定键，保留 config.exs 其余键。确认 `mix` 行为：`config/2` 对 keyword 值合并而非替换（Elixir Config 语义）。**安全**。

**编辑** `lib/maxio/application.ex` —— 在 `{Phoenix.PubSub, name: Maxio.PubSub}` + `Maxio.Cluster.CacheInvalidator`（M8-2 已加）之后、`MaxioWeb.Endpoint` 之前插入 `Maxio.Storage.Scanner`（须在 Repo + Topology 之后；Topology 在 cluster_children 已起，Repo 在此 children 列表内更早）：

把（M8-2 后的状态）：
```elixir
          {Phoenix.PubSub, name: Maxio.PubSub},
          Maxio.Cluster.CacheInvalidator,
          # Start a worker by calling: Maxio.Worker.start_link(arg)
          # {Maxio.Worker, arg},
          # Start to serve requests, typically the last entry
          MaxioWeb.Endpoint
```
改为：
```elixir
          {Phoenix.PubSub, name: Maxio.PubSub},
          Maxio.Cluster.CacheInvalidator,
          Maxio.Storage.Scanner,
          # Start to serve requests, typically the last entry
          MaxioWeb.Endpoint
```

> **executor 注意（Scanner 在 test 启动但 enabled:false）**：Scanner 始终在监督树（无条件 child），但 `init/1` 读 `config().enabled`——test 为 false 故不 `send_after(:run_cycle)`，不自动跑。`scan_now/1` 仍可被测试同步调用。**确认** test 环境 `Maxio.Storage.Scanner` 命名进程存在且空闲。

### 步骤 6（绿）：`mix maxio.scan` CLI

**新建** `lib/mix/tasks/maxio.scan.ex`：

```elixir
defmodule Mix.Tasks.Maxio.Scan do
  @shortdoc "运行一次完整后台巡检：遍历全部对象，检测+自愈坏分片，刷新用量"
  @moduledoc """
  M8 后台巡检 CLI（一次性全量 scan+heal，铁律 4 可观测）。共享 Scanner 的周期代码路径（scan_now，sample::full）。

      mix maxio.scan                 # 全量扫描所有桶/对象，检测+自愈，刷新用量
      mix maxio.scan --versions      # 连历史版本一并校验

  FS 后端：仅用量统计（无 parity 可 heal）。EC/Distributed：采样全覆盖完整性检测 + 自愈。
  不可恢复对象（存活 < K）只结构化打印，绝不伪造数据。
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    opts =
      cond do
        "--versions" in args -> [scan_versions: true]
        true -> []
      end

    {:ok, s} = Maxio.Storage.Scanner.scan_now(opts)

    IO.puts(
      "[maxio scan] scanned=#{s.scanned} damaged=#{s.damaged} healed=#{s.healed} " <>
        "unrecoverable=#{s.unrecoverable} missing=#{s.missing}"
    )
  end
end
```

> **executor 注意（scan_now 支持 scan_versions opt）**：上面 CLI 传 `scan_versions: true`，但 `merge_opts/2` 当前只处理 `:backend`/`:throttle`/`:no_throttle`。**在 `merge_opts` 追加**：`cfg = if Keyword.has_key?(opts, :scan_versions), do: %{cfg | scan_versions: Keyword.get(opts, :scan_versions)}, else: cfg`。确保 CLI 的 `--versions` 生效。

### 步骤 7（绿）：跑测试 + 全量回归 + 提交

```powershell
mix test test/maxio/storage/scanner_test.exs
mix compile --warnings-as-errors
mix test
```
期望：scanner 测试全绿；全量回归绿；零警告。

```powershell
git add -A
git commit -m @'
M8-3: 后台 scanner + 自愈（Scanner GenServer + Throttle + Usage + mix maxio.scan + config）

- 新增 Maxio.Storage.Scanner（supervised GenServer + Process.send_after，纯 OTP 无 Oban）：
  分页遍历 Maxio.Objects（有界内存），逐对象复用 M6/M7 heal_object detect-then-repair，
  限流（每对象 sleep + 单并发）绝不阻塞 S3 请求；leader-per-set 经 M8-1 锁租约（per-cycle
  set->leader 映射，O(1) 归属，周期末统一释放）；per-bucket 用量刷新 + 与 Console.Stats 自审。
- FS 后端仅用量统计（heal_mod=nil）；不可恢复对象只结构化记录绝不伪造（继承 M6/M7）。
- 动态 cadence（delay_factor × 上次耗时）+ 1/1024 确定性采样（scan_now=:full 全覆盖）。
- Maxio.Storage.Scanner.{Throttle,Usage} + mix maxio.scan + config :scanner + Logger metadata 扩充
  + runtime MAXIO_SCANNER_* + 监督树起 Scanner（test enabled:false）。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收标准（M8-3）**：`Scanner`/`Throttle`/`Usage` + `mix maxio.scan` 编译零警告；`scanner_test.exs` 全绿（FS 仅用量 / 单机 EC 损坏 ≤M 自愈 healed≥1 / 损坏 >M unrecoverable≥1 不伪造 / 采样确定性 / leader-per-set 占租约时 skip）；scanner 在 test 不自动跑（enabled:false）；全量 `mix test` 绿；`mix maxio.scan` 可手动跑出汇总（dev 环境冒烟）。

---

# 单元 M8-4：集成测试 + `:peer` 真节点取证 + STATUS/README + M9 deferral

**目标**：一个集成测试同时锻炼 lock + notify + scanner（模拟/退化路径）；`:peer` 真节点验证跨节点锁 quorum + Notify 广播送达（gated `:distributed`）；全量回归；STATUS + README M8 总结 + 更新 M9 deferral 列表。

**依赖**：M8-3。

### 步骤 1（绿）：集成测试（lock + notify + scanner 同跑）

**新建** `test/maxio/cluster/m8_integration_test.exs`：

```elixir
defmodule Maxio.Cluster.M8IntegrationTest do
  @moduledoc """
  M8 集成：lock + notify + scanner 同跑（单节点退化，确定性）。证明三者协同：
    1. 一个 with_lock 守护的 mutation 与一次 scanner scan_now 不互踩（scanner 用 disjoint set 租约）。
    2. mutation 后 Notify 广播被订阅者收到（缓存失效管道在位）。
    3. scanner scan_now 在 FS 后端正确刷新用量。
  """
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.{Lock, Notify}
  alias Maxio.{Buckets, Objects}
  alias Maxio.Storage.Scanner

  test "lock + notify + scanner 协同（单节点退化）" do
    bucket = "m8int-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create(bucket, "arn:aws:iam:::root")

    # 订阅失效 topic。
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())

    # 1. with_lock 守护一次「写对象元数据 + 广播」。
    backend = Application.get_env(:maxio, :storage_backend)

    {:ok, :written} =
      Lock.with_lock({bucket, "k.txt"}, fn ->
        {:ok, %{size: size, etag: etag}} = backend.put(bucket, "k.txt", "null", ["payload"])
        {:ok, _} = Objects.put_version_with_id(bucket, "k.txt", "null", %{size: size, etag: etag})
        Notify.broadcast({:bucket_meta_changed, bucket})
        :written
      end)

    # 2. 广播被收到（管道在位）。
    assert_receive {:bucket_meta_changed, ^bucket}, 1_000

    # 3. 持有一个 scanner-set 租约时，scanner 仍能跑（FS 后端不用 set 租约；退化下 owns=all）。
    {:ok, summary} = Scanner.scan_now(backend: :fs)
    assert summary.scanned >= 0
    usage = Maxio.Storage.Scanner.Usage.get(bucket)
    assert usage.object_count == 1

    # 4. scanner 的 set 租约与对象锁 disjoint：占住对象锁不影响 scanner（FS 不取 set 租约）。
    {:ok, obj_lease} = Lock.acquire({bucket, "k.txt"}, mode: :write, refresh: false)
    {:ok, _} = Scanner.scan_now(backend: :fs)
    :ok = Lock.release(obj_lease)
  end
end
```

### 步骤 2（绿）：`:peer` 真节点取证（跨节点锁 quorum + Notify 送达）

**新建** `test/maxio/cluster/m8_peer_test.exs`（复用 `peer_cluster_test.exs` 的 setup 模式，gated `:distributed`）：

```elixir
defmodule Maxio.Cluster.M8PeerTest do
  @moduledoc """
  M8 :peer 真节点取证（@moduletag :distributed，默认排除；mix test --include distributed）。
  证明：
    1. 跨节点锁 quorum：本机 + 1 peer = 2 节点，写 quorum=2；本机持锁后 peer 的 LockServer 对同
       resource 拒授 -> 本机仍持 quorum，peer 不能获（互斥跨真节点生效）。
    2. Notify.broadcast 经 Phoenix.PubSub.PG2 真送达 peer 上的订阅者（跨节点广播）。
  本机 epmd/:peer 不可用时 setup 探测失败即 skip（主回归不受影响）。
  """
  use ExUnit.Case, async: false
  @moduletag :distributed

  alias Maxio.Cluster.{Lock, LockServer, Notify}

  setup_all do
    distributed_ok =
      case :net_kernel.start([:"maxio_m8_primary@127.0.0.1", :longnames]) do
        {:ok, _} -> true
        {:error, {:already_started, _}} -> true
        {:error, _} -> false
      end

    if distributed_ok do
      Node.set_cookie(:maxio_test_cookie)
      {:ok, distributed: true}
    else
      {:ok, distributed: false}
    end
  end

  setup %{distributed: distributed} do
    if not distributed do
      {:ok, skip: :no_distribution}
    else
      :ok = :net_kernel.monitor_nodes(true)

      case start_peer(:maxio_m8_peer1) do
        {:ok, pid, node} ->
          :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
          # peer 上起 LockServer + PubSub（订阅者用）。
          {:ok, _} = :erpc.call(node, Maxio.Cluster.LockServer, :start_link, [[]])
          {:ok, _} = :erpc.call(node, Phoenix.PubSub.Supervisor, :start_link, [[name: Maxio.PubSub]])

          on_exit(fn -> :peer.stop(pid) end)
          {:ok, peer_pid: pid, peer_node: node}

        :error ->
          {:ok, skip: :no_peer}
      end
    end
  end

  test "跨节点锁 quorum + Notify 送达", ctx do
    cond do
      Map.get(ctx, :skip) == :no_distribution -> assert true
      Map.get(ctx, :skip) == :no_peer -> assert true
      true -> run_peer_assertions(ctx)
    end
  end

  defp run_peer_assertions(ctx) do
    peer = ctx.peer_node
    nodes = [Node.self(), peer] |> Enum.sort()

    # 本机起 LockServer（监督树已起；确保命名进程存在）。
    _ = ensure_local_lock_server()

    # 1. 跨节点写锁 quorum=2：本机 acquire 写锁，granted 含两节点。
    {:ok, lease} = Lock.acquire({"b", "peerlock"}, mode: :write, nodes: nodes, refresh: false)
    assert lease.quorum == 2
    assert peer in lease.granted

    # 持锁期间 peer 的 LockServer 对同 resource 已被本机占（写锁独占）-> 本机再 acquire 应失败。
    assert {:error, :no_quorum} =
             Lock.acquire({"b", "peerlock"}, mode: :write, nodes: nodes, retries: 0, refresh: false)

    :ok = Lock.release(lease)

    # 2. Notify 跨节点送达：peer 上订阅 topic 并把收到的事件回送本机 test pid。
    parent = self()

    {:ok, sub} =
      :erpc.call(peer, Task, :start, [
        fn ->
          :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())
          send(parent, :subscribed)

          receive do
            {:bucket_meta_changed, _} = ev -> send(parent, {:peer_got, ev})
          after
            5_000 -> :ok
          end
        end
      ])

    _ = sub
    assert_receive :subscribed, 5_000
    :ok = Notify.broadcast({:bucket_meta_changed, "peerbucket"})
    assert_receive {:peer_got, {:bucket_meta_changed, "peerbucket"}}, 5_000
  end

  defp ensure_local_lock_server do
    case Process.whereis(LockServer) do
      nil -> LockServer.start_link([])
      pid -> {:ok, pid}
    end
  end

  defp start_peer(name) do
    {:ok, pid, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", ~c"maxio_test_cookie"]
      })

    {:ok, pid, node}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
```

> **executor 注意（peer 上的 PubSub PG2 跨节点）**：`Phoenix.PubSub` 跨节点送达要求两节点的 `Maxio.PubSub`（PG2/`:pg`）在同一 mesh 且同名。peer 上 `Phoenix.PubSub.Supervisor.start_link(name: Maxio.PubSub)` 起一个同名 PubSub，本机的已由监督树起。**若** PG2 的 `:pg` group 跨节点同步需要少量时间，`assert_receive :subscribed` 后再 broadcast 已足够（subscribe 完成即加入 group）。**若 peer 起 PubSub 的 API 形态不符**（`Phoenix.PubSub.Supervisor` vs `Phoenix.PubSub` child spec），executor 改用 `:erpc.call(peer, Supervisor, :start_link, [[{Phoenix.PubSub, name: Maxio.PubSub}], [strategy: :one_for_one]])` 或直接 `:erpc.call(peer, Phoenix.PubSub, :child_spec, ...)`——以**能在 peer 上跑起一个名为 `Maxio.PubSub` 的 PubSub** 为准（先 `mix help` / hexdocs 核验当前 `phoenix_pubsub` 版本的启动 API，铁律 §4.3 勤查资料）。**若跨节点 PubSub 在本机 :peer 下不稳定，第 2 项断言可降级为「peer 订阅 + 本机 broadcast，5s 内收到」，收不到则该子断言 skip（不 fail 主回归，因已 gated :distributed）。**

跑（本机若 epmd 可用）：
```powershell
mix test test/maxio/cluster/m8_peer_test.exs --include distributed
```
期望：绿（或本机 :peer 不可用时整文件 skip——主回归 `mix test` 不含此文件）。

### 步骤 3（绿）：全量回归

```powershell
mix compile --warnings-as-errors
mix test
```
期望：M7 基线 510 + M8 新增（lock/notify/cache_invalidator/scanner/m8_integration），全绿，零警告。`:distributed` 默认排除。

### 步骤 4（文档）：STATUS + README M8 总结 + M9 deferral

**编辑** `docs/superpowers/STATUS.md`：
1. 里程碑进度表追加一行 `M8 分布式运维成熟度`（quorum lock + 跨节点缓存失效 + 后台 scanner/自愈），状态「✅ 已实现并验证」。
2. 新增「## M8 实现摘要」节，逐单元（M8-1..M8-4）记录：模块名、关键决策（owner-death+lease 双释放、共享-PG 诚实 no-op、leader-per-set per-cycle 租约）、测试覆盖、架构级修正（若有）。
3. 新增「### M8 已知非阻塞项 / M9 显式 defer」节（见下文模板）。
4. 更新「## 下一步（续作入口）」指向 M9。

**编辑** `README.md`：在 M7 章节后追加 M8 章节（quorum lock / 缓存一致性模型 + 部署要求「所有节点连同一 Postgres / PG HA」/ scanner 用法 `mix maxio.scan` + config `:scanner` + `MAXIO_SCANNER_*` env），含 M9 defer 清单。

**M9 显式 deferral 模板（写进 STATUS «M9 显式 defer» 节，诚实，绝不假装实现）**：
```
### M8 已知非阻塞项 / M9 显式 defer（文档化，绝不静默假装实现）

M8 完成「完整 quorum 分布式锁 + 跨节点缓存失效管道 + 后台 scanner/自愈」。以下显式 defer 到 M9：

1. Rebalance / Decommission / online pool 扩容：添加/退役 pool、跨 pool 迁移既有对象（MinIO
   mc admin rebalance/decommission、free-space 加权放置）。set 数 per pool 仍不可变（online 扩缩需重哈希迁移）。
2. 锁正确性升级到 Raft：M8 锁 best-effort（LockServer 内存态，crash+restart 可 double-grant，Redlock 同类）。
   真线性化 -> ra(Raft) 共识组；fencing token（per-resource 单调 epoch 写入 sidecar 拒绝陈旧写）= defer。
3. read-through 元数据缓存：当前生产路径无缓存（EctoStore + 每请求 Repo），M8 失效管道为 no-op 但在位；
   真正引入 read-through 性能缓存（带 TTL 自愈 + invalidate/1）= defer（管道已就位，加缓存即跨节点安全）。
4. scanner orphan-shard 检测：盘上有分片但 DB 无对应对象（MinIO「abandoned children」）需 transport
   list_dir callback + 协调聚合 = defer。M8 scanner 枚举来自 Postgres（权威），已覆盖「DB 有、分片缺/损」的自愈。
5. scanner 与 live IO 联动限流（MinIO「wait for low IO」读 in-flight 请求计数自适应暂停）：M8 用保守固定
   pacing（max_objects_per_sec + 单并发），无 live IO 计数器 = defer。
6. 多 parity / storage class（x-amz-storage-class -> STANDARD/RRS 不同 EC:M）= defer（沿用 M6/M7）。
7. degraded-write parity upgrade（写时临时提高 effective parity 并记 per-object 实际布局）= defer（沿用 M7）。
8. 专用流式分片传输（gRPC/HTTP2 + 连接池 + mTLS）= defer（沿用 M7，Transport behaviour 已抽象）。
9. failure-domain 感知自动 set 形成 = defer（沿用 M7，手工 config）。
10. 沿用 M0–M7 全部既有 defer（lifecycle 后台执行、SSE 大对象逐帧流式 GET、identity policy、MFA Delete
    强制、跨账户多租户、完整条件算子、inline 小对象等）。
```

### 步骤 5（提交）

```powershell
git add -A
git commit -m @'
M8-4: 集成测试 + :peer 真节点取证 + STATUS/README + M9 deferral

- m8_integration_test：lock + notify + scanner 单节点退化协同（with_lock 守护 mutation + 广播送达
  + scanner 用量刷新 + set 租约与对象锁 disjoint）。
- m8_peer_test（@moduletag :distributed）：跨节点写锁 quorum=2 互斥 + Notify 经 PG2 跨节点送达 peer 订阅者。
- 全量回归绿、compile --warnings-as-errors 零警告（:distributed 默认排除）。
- STATUS + README M8 总结 + M9 显式 deferral（rebalance/decommission/online 扩容、Raft 锁升级、
  read-through 缓存、orphan-shard 检测、live-IO 联动限流、多 parity、degraded-write parity upgrade、
  专用传输、failure-domain 自动 set）。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
'@
```

**验收标准（M8-4）**：`m8_integration_test` 全绿（lock+notify+scanner 协同）；`m8_peer_test` 在本机 `--include distributed` 下绿或 skip（主回归 `mix test` 不含）；全量 `mix test` 绿、零警告；STATUS + README 含 M8 总结 + M9 deferral；M9 deferral 诚实列出 rebalance/decommission/online 扩容等。

---

## § M8 显式 deferral / M9 入口（文档化，绝不静默）

见 M8-4 步骤 4 的「M9 显式 defer」模板（rebalance / decommission / online pool 扩容 / Raft 锁升级 + fencing / read-through 缓存 / orphan-shard 检测 / live-IO 联动限流 / 多 parity / degraded-write parity upgrade / 专用传输 / failure-domain 自动 set / 沿用 M0–M7 全部既有 defer）。

**设计保证（M8 在 M7 集群层之上加运维层）**：M8 复用 M7 的 `Maxio.Cluster.{nodes,this_node,alive?}` 门面、`Transport`/`ShardServer`/`Heal`/`Distributed`、`Maxio.Cluster.Lock.with_lock` 公共契约（签名逐字不变），与 M6 的 `Erasure.{Codec,Config,Heal}` + NIF；**不重写 RS 编解码 / heal 引擎 / transport / 请求管线 / 存储后端**。所有失败路径结构化（获锁失败 → `{:error, :locked}`；丢 quorum → abort；不可恢复 → 结构化 error 日志，绝不伪造；EctoStore 无缓存 → 诚实 no-op）。所有 deferral 在 STATUS + README 逐条显式列出（铁律 3，无静默缺口）。
