# ROUTE B 实现计划 · maxio（Shared-Nothing 对象元数据 · 每对象 sidecar 即唯一事实来源 · Postgres 降级为可选派生索引）

> For agentic workers（executor）：严格按单元 **B1-1 .. B7-3** 顺序执行（阶段内单元串行；阶段间可暂停发布）。逻辑性代码用 **TDD**（先写失败测试 → 运行确认红 → 最小实现 → 运行确认绿 → commit）；脚手架/配置/依赖类任务用「执行命令 + 验证输出」。每个任务都给了**精确文件路径、完整可用代码（禁止占位符 / TODO / 省略号）、确切 PowerShell 命令与期望输出**。后面单元引用的类型/函数/字段名与前面定义（及 M0–M7 既有代码）**严格一致**——复用既有模块时逐字照抄其现有签名。
>
> **本计划建立在已交付并验证的 M0–M7 之上**（master，510 测试全绿、`compile --warnings-as-errors` 零警告、独立 reviewer APPROVE）。ROUTE B 的核心是一项**基础性再架构**：把今天「**Postgres 权威 + 后端字节**」的双平面元数据模型，翻转为「**每对象盘上 sidecar（`meta.json`，今天已在 EC/Distributed 后端写到全 N 端点）即唯一事实来源**」，Postgres 降级为**可选的派生索引（加速 LIST/HEAD，可重建，宕了不影响正确性，不再是 SPOF）**。这一举：
>   - 用**原子提交（temp-dir + rename，数据先于元数据，写 quorum 闸，对象锁横跨整个 seam）**从构造上消灭「双写 / 孤儿分片 / 静默 ETag-bytes 分歧」三类 bug；
>   - 用**跨端点 quorum 读 + 分歧 reconcile + sidecar heal**，把「读任一副本」升级为「读多数一致副本」，使 sidecar 安全成为事实来源；
>   - 用**流式 drive-walk LIST（新 Transport `list_dir` callback）** 替换「SQL 无 LIMIT 全量 `Repo.all`」，从构造上消灭 LIST 的 DoS；
>   - 用 **fsync-before-quorum**（独立）补上 write-quorum 的耐久谎言；用**拓扑 distinct-node 校验器**（独立）补上 failure-domain 漏洞。
>
> **铁律对齐（AGENTS.md §3/§4，违反即返工）**：
> - **铁律 1/2（统一契约 / 后端即插件）**：`Maxio.Storage`（facade）、`Maxio.Storage.Backend`（behaviour）、`Maxio.S3.Endpoint`/`Dispatcher`/handler 的**对外契约**保持稳定。ROUTE B 的元数据权威翻转经一个**新的内部门面 `Maxio.ObjectMeta`**（dual-read/dual-write + reconcile + 派生索引）注入，handler 的调用点签名收敛但行为可经 `authoritative_source` 配置开关。新增能力（sidecar 扩展字段、`list_dir`、drive-walk LIST coordinator）一律走 behaviour / 新模块，**绝不把 walk 逻辑塞进某个具体后端**（铁律 2）。
> - **铁律 3（绝不静默失败 / 绝不静默返回错数据）**：sidecar 跨端点分歧且无值达 read_quorum → 返回 read-quorum 错误（绝不猜一个副本服务），对齐既有 `InsufficientShardsError` 纪律；dual-read 阶段每一处 PG↔sidecar 分歧 → 结构化日志（含 bucket/key/version），驱动到零再切权威；派生索引写失败 → 非致命但**必记日志 + 标 `synced_at` 滞后**（绝不假装一致）；原子提交未达 write_quorum → 回滚 temp + `{:error, :write_quorum}`。残留 PG 依赖（IAM/policy/bucket-config）**诚实文档化，绝不宣称 PG-free**。
> - **铁律 4（body 流式 / 跨节点逐块 / 列举有界内存）**：原子提交仍逐块流式编码（绝不缓冲整对象）；drive-walk LIST 用 `list_dir` 逐目录层 + k-way 流式归并 + 惰性 `Stream`，**任意时刻在途 ≈ O(set 数 × 一层目录项)，绝不把整桶 key 读进内存**；继续不挂 `Plug.Parsers`。
> - **铁律 5（S3 行为对齐 AWS/MinIO）**：sidecar 的 versions 数组、`modtime`/`is_latest`/`is_delete_marker`/`generation` 语义对齐 MinIO `xl.meta` v2；drive-walk LIST 的 prefix/delimiter/start-after/continuation-token/max-keys 行为与今天 SQL LIST **逐场景 parity**（shadow-compare 取证）；ETag/Range/版本选择不变。
> - **铁律 6（DB schema 自文档化）**：派生索引在既有 `objects` 表上**加列**（`synced_at` / `index_generation`），新列须中文 `COMMENT`；不新建权威表。
>
> **作者/审查隔离**：本计划由 executor 实现；每个单元收尾由**独立** `code-reviewer`/`verifier`（不同上下文）取证，实现者不得自审。
>
> **被取代/折叠的计划**：`docs/superpowers/plans/2026-06-09-m8-distributed-ops.md`（未提交）**整体折叠进本计划**——其 quorum 锁仍有用（但锁现在必须**横跨整个提交 seam**，见 B1-1）；其 background scanner 变成**派生索引 reconcile + reverse-GC 引擎**（B5-2）；其 cache-coherence 单元在 PG 降级后**基本变 moot**（对象平面不再有跨节点缓存失效需求；config 平面残留依赖见 §残留 PG 依赖）。复用其 fit 的部分，丢弃其 moot 的部分。

---

## 环境约束（每条命令都必须遵守）

- **本机**：Windows 11 + PowerShell。Elixir 1.20.0 / OTP 28，位于 `C:\Users\dyz\Documents\dev\usr\Elixir\bin`。
- **跑任何 mix 命令前必设**（否则编译期/运行期中文输出重定向到非 TTY 触发 `io.put_chars badarg` 硬崩、留 `erl_crash.dump`）：
  ```powershell
  $env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
  $env:ERL_FLAGS = '-kernel standard_io_encoding unicode'
  ```
  本计划所有 PowerShell 命令块**默认已假设当前会话已设此两变量**；每个新 shell 会话第一条命令前先执行它。
- **Postgres**：docker 容器 `maxio-db`（postgres:16，localhost:5432，user/pass=postgres/postgres，dev 库 `maxio_dev`，test 库 `maxio_test`）。`psql` 不在 PATH，一律经容器 `docker exec maxio-db psql -U postgres -d maxio_dev -c "..."`。`mix test` 自动迁移 test 库。容器没起先 `docker start maxio-db`。新增迁移用 `mix ecto.gen.migration <name>`（时间戳/约定自动），列/索引加中文 `COMMENT`（铁律 6）。
- **rustc 1.95 / cargo 在 PATH**（NIF `use Rustler` 在 `mix compile` 期驱动 cargo；ROUTE B 不改 NIF）。
- **无 aws-cli / boto3 / mc / python**。端到端验证用三层（**确定性、CI 友好、无需真实集群**）：
  1. **纯函数 / 单进程逻辑单测**（sidecar 编解码 round-trip、quorum reconcile 真值表、walk 的 prefix/delimiter/forward-to 折叠、continuation-token 编解码）——最权威 ground truth。
  2. **进程内多节点 transport 注入**（沿用 M7 既有 `Maxio.Cluster.Transport.InProcess` + `opts[:topology]` 注入）：在 `async: false` 的 ExUnit 里跑真实 quorum 读 / sidecar 分歧 / 原子提交 crash-window / drive-walk LIST，无需第二个 BEAM 节点。**主力**。共享 `Maxio.Test.StorageConformance` 套件（M6 已建，已同跑 FS+ErasureCoded+Distributed）继续证同一契约。
  3. **`:peer` 真节点集成测试**（少量 `@tag :distributed`、`async: false`）：复用 `test/maxio/cluster/peer_cluster_test.exs` 的 `:peer` setup 模式，验证 ① 跨节点 `list_dir` 真 :erpc 列举聚合、② 跨节点原子提交 + quorum 读。CI 可单独跑/跳过；本机 epmd/`:peer` 不可用时 setup 探测失败即 skip，主回归不受影响。
- **测试禁忌（AGENTS.md Test guidelines）**：用 `start_supervised!/1` 起进程；**禁用** `Process.sleep/1`/`Process.alive?/1`——等进程死用 `Process.monitor/1` + `assert_receive {:DOWN, ...}`；同步用 `_ = :sys.get_state(pid)`；等节点死用 `:net_kernel.monitor_nodes(true)` + `assert_receive {:nodedown, n}`。注入端点宕机的测试（`Transport.InProcess.set_down/1`）须 `async: false`。
- **提交**：每个单元（或紧密相关的红绿对）一次 commit，message footer 固定一行：
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
  当前分支为 `master`。**ROUTE B 是基础性再架构**：建议每个阶段（Phase）在独立分支或独立验收点收口，确保「每阶段独立可发布 + 可回滚」。除非用户另行要求，提交到当前分支。

---

## Goal

把 maxio 的对象元数据从「Postgres 权威」再架构为「**每对象盘上 sidecar 即事实来源、Postgres 为可选派生索引**」的 shared-nothing 模型，使：

1. **每对象 sidecar 自描述全部 S3 元数据**（B2-1）：在既有 `meta.json`（`ec`/`shards`/`size`/`etag`/`sha256` 不动）之上加 `format:"maxio/2"` 的 `versions` 数组，每版本含 `version_id`/`type`(object|delete_marker)/`is_latest`/`modtime`(ns)/`generation`/`content_type`/`user_metadata`/`tags`/`sse`/`acl_canned`/`storage_class`/`data_dir`/`inline`。FS 后端也写 sidecar（B6-1），单机/非纠删码同样 shared-nothing。
2. **跨端点 quorum 读 + 分歧 reconcile + sidecar heal**（B2-2/B2-3）：读 sidecar 从「任一存活端点」升级为「读全 N 端点 → 按 `(generation, modtime, etag)` quorum 取多数一致 → 无值达 read_quorum 则报错绝不猜；少数分歧副本调度 heal」。这是让 sidecar 安全成为事实来源的**首要正确性升级**。
3. **原子提交写路径**（B1-1 锁横跨 seam + B4-1 temp-then-rename）：写分片 + sidecar 到 temp obj-dir，fsync，再在**横跨整个提交的对象锁**下 rename 到 final（数据先于元数据），write_quorum 闸——从构造上消灭双写/孤儿/静默分歧/耐久谎言。
4. **流式 drive-walk LIST**（B3-1/B3-2）：新 Transport `list_dir` callback（逐目录层、sorted、可 forward-to/limit）+ `Maxio.Listing` coordinator（fan-out 全 set → set 内 quorum-walk → 跨 set k-way 归并 → 惰性 prefix/delimiter/start-after/max-keys → 仅 ≤max_keys 个 hydrate）+ walk-position continuation token——从构造上消灭无 LIMIT DoS。`?versions` 与 ListMultipartUploads 同法（B3-3）。
5. **Postgres 降级为派生索引**（B5-1/B5-2）：`objects` 表加 `synced_at`/`index_generation`，写路径对其做**best-effort 更新（失败非致命，必记日志）**；读 PREFER 索引、FALL BACK drive-walk；background scanner reconcile 索引 + reverse-GC 孤儿。
6. **迁移 + cutover + verify**（B7-1/B7-2/B7-3）：`authoritative_source` feature flag（读/列/写分别可切 `:pg`/`:sidecar`），backfill 既有对象 sidecar，shadow-compare 取证驱分歧到零，永久切 sidecar 权威 + 保留 PG 快路径。

**显式不做（DEFER，文档化，绝不静默）**——见末尾「§ ROUTE B 显式 deferral」。

> **设计保证（ROUTE B 在 M0–M7 之上加层 + 翻转权威）**：M6/M7 的 RS 编解码 / heal 引擎 / transport / 请求管线**不重写**；sidecar 的 `ec`/`shards`/`block_hashes` 耐久元数据**绝不被新字段污染或 clobber**（backfill 是最高风险写，temp+rename+validate 守护）。所有 deferral 显式列出（铁律 3，无静默缺口）。

---

## Architecture（ROUTE B 在 M7 之上的增量——RS 核心 + 请求管线零改写，元数据权威翻转）

```
                （核心请求管线 / dispatcher / endpoint —— 对外契约稳定）
S3 客户端 → LB → 任一节点 Maxio.S3.Endpoint → ... → Maxio.S3.Handlers.Object/Multipart
                                                          │
                          ┌───────────────────────────────┴────────────────────────────────┐
                          │                                                                  │
                Maxio.ObjectMeta（★新门面，B2/B5/B7）                              Maxio.Storage（facade，不改）
                  权威路由：authoritative_source(:pg | :sidecar)                       │ backend() = config :maxio, :storage_backend
                  read：PREFER 索引 → FALL BACK drive-walk/sidecar                     │
                  write：原子 sidecar 提交（权威）+ best-effort PG 索引更新     Maxio.Storage.{FS,ErasureCoded,Distributed}
                  reconcile / divergence 日志 / shadow-compare                         │ put/get/stat/delete/parts（+ 原子提交 B4，+ FS sidecar B6）
                          │                                                            │
          ┌───────────────┼────────────────────────┐                       ┌──────────┴───────────────┐
   Maxio.Listing（★新，B3）   Maxio.Sidecar（★新，B2-1） Maxio.Objects（派生索引，B5）   Maxio.Cluster.Transport（+ list_dir，B3-1）
     fan-out 全 set            versions 数组编解码      objects 表 + synced_at         put/get/sidecar/... + list_dir
     set 内 quorum-walk        + quorum reconcile（B2-2） best-effort 更新 + reconcile        │
     跨 set k-way 归并         + sidecar heal（B2-3）                                  Maxio.Cluster.ShardServer（+ list_dir 本机层）
     惰性 prefix/delim/maxkeys                                                          复用 M6 part.0 + BLAKE3 + temp/rename（B4）
     walk-position token                                                                       │
          │                                                              ┌──────── 复用 M6/M7 核心（不重写）────────┐
   Maxio.Cluster.Lock（横跨 seam，B1-1）                                  Erasure.{Codec,Config,Heal}, NIF, Topology/Router/Paths
   Maxio.Storage.Scanner（reconcile + reverse-GC，B5-2）

盘上布局（每端点 = 一个 {node, drive}；ROUTE B 选「方案 B」最小改动：保留 M7 per-version 目录 +
扩展同目录的 meta.json 为自描述 versions[单元素] 形态，故无需引入跨版本单 sidecar 大改）：
  <drive_i>/<bucket>/<key>/{part.0, meta.json}                       # null 版本：sidecar.versions=[该版本]
  <drive_i>/.versions/<bucket>/<key>/<version_id>/{part.0, meta.json}# 版本化：每版本独立目录 + 自描述 sidecar
  提交临时区（B4）：<drive_i>/.tmp/<uuid>/{part.0, meta.json} → rename 到上面 final 目录

跨节点消息（铁律 4）：put/get 分片仍逐 (block, shard)；list_dir 逐目录层（有界），绝不整桶。

CLI（铁律 4 可观测）：mix maxio.backfill_sidecars / mix maxio.list.walk / mix maxio.reconcile_index
```

config 新增（不改既有 key，仅追加；默认值保证「先发布不改行为」）：
```elixir
# 元数据权威来源（读/列/写分别可切；ROUTE B 各阶段经此 flag 渐进 cutover；默认全 :pg = 今天行为）
config :maxio, :authoritative_source, read: :pg, list: :pg, write: :pg
# sidecar inline 小对象阈值（MinIO smallFileThreshold = 128 KiB）；先关（0 = 不 inline），B 后期开
config :maxio, :sidecar, inline_threshold: 0, format: "maxio/2"
# drive-walk LIST 的每页 set 内 list_dir 批大小 + 跨 set 归并并发
config :maxio, :listing, walk_page_size: 1000, max_set_concurrency: 16
# 原子提交：fsync 开关（耐久；prod true）。
config :maxio, :durability, fsync: true
# 派生索引 reconcile scanner（折叠自 M8）。
config :maxio, :scanner, enabled: false, interval_ms: 86_400_000, batch_size: 500
# 临时安全闸（B1 期）：SQL LIST 硬上限，防 PG 权威期的 no-LIMIT DoS。
config :maxio, :listing, sql_hard_limit: 100_000
# Logger metadata 追加 ROUTE B 键。
config :logger, :default_formatter, metadata: [..., :version_id, :generation, :endpoint, :divergence, :authoritative]
```

---

## 全局命名契约（ROUTE B 新增，一次定义全程复用；M0–M7 既有契约逐字一致复用）

**沿用既有契约（逐字一致，绝不重定义）**：
- `Maxio.Storage`/`Maxio.Storage.Backend` 全部 callback（含 M4 `version_id` 维度 + M2 parts），末参 `opts \\ []`。
- `Maxio.Storage.Erasure.{Codec,Config,Meta}`、`Maxio.Native.ErasureCoding`、`InsufficientShardsError`（字段 bucket/key/version_id/block_index/present/required）。
- sidecar 既有形态（M6，**不破坏**）：`%{"ec"=>%{"k","m","block_size","algo"}, "size","etag","sha256","parts"=>[%{"part"=>0,"size"}], "shards"=>[%{"drive"=>i,"shard_file_size","block_hashes"=>[hex,...]}]}`。
- `Maxio.Cluster.{nodes/0,this_node/0,alive?/1,drives_for_set/1}`；`Topology.{all_set_ids/0,endpoints/1,ec_params/0,*_from/*,parse_and_validate!/1}`；`Router.set_for/2,3`；`Paths.{object_rel/3,part_rel/3,upload_rel/2}`。
- `Maxio.Cluster.Transport`（behaviour，7 callback 首参 `node()` + `impl/1`）/`Transport.Erpc`/`Transport.InProcess`；`ShardServer`（8 本机函数）。
- `Maxio.Cluster.Lock.{with_lock/2,3, quorum_with_lock/2,3}`（resource = `{bucket,key}`）。
- `Maxio.Objects.{put_version_with_id/4, get_metadata/2, get_version/3, list_objects_v2/2, list_object_versions/2, delete_version/3, insert_delete_marker/3, common_prefix_of/3}`、`Maxio.Buckets`、`Maxio.Multipart`、`Maxio.Console.Stats`。

**ROUTE B 新增命名契约（一次定义全程复用）**：
- `Maxio.Sidecar`（B2-1）— sidecar v2 编解码 + 字段访问，纯函数：
  - `@type version_entry :: %{...}`（见 B2-1 完整字段）。
  - `put_version_entry(meta :: map, entry :: map) :: map`（merge 一个版本进 versions 数组，重算 is_latest）。
  - `latest(meta) :: version_entry | nil`（max modtime 的非 delete-marker；全 delete-marker 则取 max modtime 的 marker）。
  - `find_version(meta, version_id) :: version_entry | nil`。
  - `signature(entry) :: binary`（版本体内容 hash，分歧检测用）。
  - `to_object_attrs(bucket, key, entry) :: map`（sidecar → `Maxio.Objects` 索引行 attrs，PG 派生用）。
  - `migrate_v1(meta) :: map`（旧 `meta.json` 升级为 v2 形态，幂等）。
- `Maxio.MetaReconcile`（B2-2）— quorum reconcile 纯逻辑：
  - `reconcile(copies :: [%{node, meta} | :missing], read_quorum, version_id | :latest) :: {:ok, canonical_meta, divergent :: [endpoint_index]} | {:error, :read_quorum}`。
- `Maxio.ObjectMeta`（B2-3/B5/B7）— 元数据门面（dual-read/dual-write + reconcile + 索引）：
  - `get(bucket, key, version_id \\ nil, opts \\ []) :: {:ok, view} | {:error, :not_found | :read_quorum}`（`view` = 与今天 `%Object{}` 字段兼容的 map，handler 无感）。
  - `list(bucket, list_opts) :: list_result`（PREFER 索引 / FALL BACK walk，受 `authoritative_source[:list]` 控）。
  - `commit(bucket, key, version_id, sidecar_meta, opts) :: {:ok, view} | {:error, term}`（原子提交 sidecar 权威 + best-effort 索引）。
  - `authoritative_source(:read | :list | :write) :: :pg | :sidecar`（读 config，可经 opts 覆盖 for tests）。
- `Maxio.Listing`（B3-2）— drive-walk LIST coordinator：
  - `list_objects_v2(bucket, list_opts, opts) :: list_result`（与 `Maxio.Objects.list_objects_v2/2` 返回形态逐字段一致）。
  - `list_object_versions(bucket, opts_map, opts) :: versions_result`。
  - `Continuation.encode(state) :: token`、`Continuation.decode(token) :: {:ok, state} | :error`（base64 包裹 walk-position，**绝不 offset**）。
- `Maxio.Cluster.Transport.list_dir`（B3-1）— 新 callback：
  - `list_dir(node, drive_bucket_dir, opts) :: {:ok, [%{name: String.t(), object?: boolean()}]} | {:error, term}`（一层目录，sorted，object? = 该子目录含 `meta.json`；opts: `:forward_to`/`:prefix_filter`/`:limit`）。
  - `ShardServer.list_dir(drive_bucket_dir, opts)` 本机实现（无 node 首参）。
- 原子提交（B4，ShardServer/Transport 扩展）：
  - `Transport.commit_object(node, drive_obj_dir, prepared :: %{shards_path, meta}, opts) :: :ok | {:error, term}`（temp → fsync → rename）——**或**沿用既有 `put_shard`/`put_sidecar` 但内部改 temp+rename（见 B4-1 决策）。
- 派生索引（B5）：`Maxio.Objects` 加 `mark_synced/4`、`stale?/2`、`reconcile_from_sidecar/3`；`Object` schema 加 `synced_at` / `index_generation` 列。

---

## 单元总览（按阶段 + 依赖串行；每单元结束须 green compile + 全量测试通过 + 一次 commit）

| 单元 | 阶段 | 标题 | 依赖 | 文件（主） |
|---|---|---|---|---|
| **B1-1** | P1 无悔修正 | 对象锁横跨「字节+元数据」提交 seam（handler do_put/copy/delete + Distributed/EC 提交在同一锁内）| M7 | `s3/handlers/object.ex`, `storage/distributed.ex`, `cluster/lock.ex` |
| **B1-2** | P1 | 原子 temp-then-rename + fsync-before-quorum（ShardServer/EC/FS 写分片+sidecar 先 temp 再 rename，fsync）| B1-1 | `cluster/shard_server.ex`, `storage/erasure_coded.ex`, `storage/fs.ex`, `cluster/transport.ex` |
| **B1-3** | P1 | 拓扑 distinct-node failure-domain 校验器 + SQL LIST 临时硬 LIMIT 闸 | M7 | `cluster/topology.ex`, `objects.ex`, `multipart.ex` |
| **B1-4** | P1 | sidecar v2 schema（`Maxio.Sidecar` 编解码 + 字段，向后兼容 v1）+ reverse-GC 脚手架 | B1-2 | `storage/erasure/meta.ex`, `storage/sidecar.ex`(新) |
| **B2-1** | P2 sidecar 自描述 | EC/Distributed 写扩展 sidecar（versions 数组 + 全 S3 字段）；PG 仍权威 | B1-4 | `storage/erasure_coded.ex`, `storage/distributed.ex`, `s3/handlers/object.ex` |
| **B2-2** | P2 | `Maxio.MetaReconcile` quorum reconcile（全端点读 → 多数一致 → 报错绝不猜）+ sidecar heal 扩展 | B2-1 | `storage/meta_reconcile.ex`(新), `cluster/heal.ex`, `storage/erasure/heal.ex` |
| **B2-3** | P2 | sidecar-authoritative READ（`Maxio.ObjectMeta.get` dual-read + shadow-compare + divergence 日志）| B2-2 | `storage/object_meta.ex`(新), `s3/handlers/object.ex` |
| **B3-1** | P3 drive-walk LIST | Transport `list_dir` callback + `ShardServer.list_dir` + `InProcess` 实现 + Erpc | B2-3 | `cluster/transport.ex`, `cluster/shard_server.ex`, `test/support/transport_in_process.ex` |
| **B3-2** | P3 | `Maxio.Listing` coordinator（fan-out + quorum-walk + k-way 归并 + 惰性 filter + walk-token）shadow-mode | B3-1 | `listing.ex`(新), `listing/continuation.ex`(新) |
| **B3-3** | P3 | 版本化 walk（`?versions`）+ multipart shared-nothing walk + FS-backend walk 适配 | B3-2 | `listing.ex`, `multipart.ex`, `storage/fs.ex` |
| **B4-1** | P4 原子写 | sidecar-authoritative WRITE（`Maxio.ObjectMeta.commit` 原子提交点 + PG best-effort）+ crash-window 测试 | B3-3 | `storage/object_meta.ex`, `s3/handlers/object.ex`, `storage/distributed.ex` |
| **B4-2** | P4 | 版本化 / delete-marker / multipart-complete 走原子提交（统一权威写）| B4-1 | `s3/handlers/object.ex`, `multipart.ex`, `storage/object_meta.ex` |
| **B5-1** | P5 PG 派生索引 | `objects` 加 `synced_at`/`index_generation`（迁移 + 中文 COMMENT）+ best-effort 写 + PREFER/FALLBACK 读 | B4-2 | 迁移, `objects/object.ex`, `objects.ex`, `storage/object_meta.ex` |
| **B5-2** | P5 | `Maxio.Storage.Scanner` reconcile 索引 + reverse-GC 孤儿（折叠 M8 scanner）+ `mix maxio.reconcile_index` | B5-1 | `storage/scanner.ex`(新), `lib/mix/tasks/maxio.reconcile_index.ex`(新) |
| **B6-1** | P6 FS sidecar | FS 后端也写扩展 sidecar（单机 shared-nothing）+ FS `list_dir`/quorum=1 walk + 原子提交 | B5-2 | `storage/fs.ex`, `listing.ex` |
| **B7-1** | P7 迁移/cutover | `mix maxio.backfill_sidecars`（PG → sidecar，幂等/限流/temp+rename/validate 不污染 EC 元数据）| B6-1 | `lib/mix/tasks/maxio.backfill_sidecars.ex`(新) |
| **B7-2** | P7 | shadow-compare harness（read+list 双跑 diff 日志）驱分歧到零 + 验证报告 | B7-1 | `test/...shadow_compare`, `storage/object_meta.ex` |
| **B7-3** | P7 | 永久 cutover（`authoritative_source` 切 sidecar）+ 保留 PG 快路径 + STATUS/README + deferral | B7-2 | `config/*`, STATUS, README |

**执行顺序**：B1-1 → … → B7-3，**串行执行，禁止并行 mix 编译**（避免锁文件竞争）。每单元规模控制在「单个 executor 一轮内可完成实现 + 跑测试 + 调用 StructuredOutput」。**每阶段（P1..P7）是一个独立可发布 + 可回滚的边界**：P1 全是无悔修正（不翻权威）；P2-P3-P4 在 shadow/flag 后翻读→列→写权威；P5-P6 补索引与 FS；P7 迁移+永久 cutover。

---
