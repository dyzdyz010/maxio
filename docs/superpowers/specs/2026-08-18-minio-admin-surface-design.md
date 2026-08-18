# MinIO 管控面接入设计 —— 运行时配置存储 + `/minio/admin/v3/*` 骨架

> 日期：2026-08-18
> 状态：设计草案，待评审后进入 RED 阶段
> 作者 lane：architect / planner（本文不含实现代码）
> 上位准则：`AGENTS.md` §3 架构铁律、§4 工程方法；`CLAUDE.md`
> 相关状态：`docs/superpowers/STATUS.md`（§"Configuration 运行时编辑 / Tiers / Site Replication / Batch Jobs / License：后端无运行时配置存储；不做"）

---

## 0. 背景与本文范围

### 0.1 已取证的现状

独立调研 lane 已对全仓取证，结论如下（这些是本设计的事实基线，不是推测）：

- **MinIO 专有管控面为零**。`grep -rn "admin/v3\|/minio/admin\|ServerInfo\|server_info\|AdminAPI\|admin_api" lib/` 零命中；无 `/minio/health/live`、无 `/minio/health/ready`。因此 `mc admin *` 全部不可用，`mc alias set` 能否成功也未经验证。
- **唯一已存在的 MinIO 专有路径命名空间**是 Prometheus：`Maxio.S3.Prometheus.metrics_path?/1` 在 `Maxio.S3.Plugs.PrometheusMetrics` 中早于 `AddressStyle` 拦截 `/minio/metrics/v3[...]` 与 `/minio/v2/metrics[...]`，并用 `admin:Prometheus` 这一 **admin action** 做授权。这是本设计要严格对齐的既有先例。
- **后端能力其实很厚**：IAM 35 模块 + 118 个 AWS IAM Query action + ~40 个 mix CLI；heal/scrub/rebalance 有 `Maxio.Storage.Erasure.Heal`、`Maxio.Cluster.*`、18 个 `mix maxio.rebalance.*`；drive 遥测有 `DriveHealth` / `DriveStats` / `DriveIdentity` / `DriveHardwareEvidence`。缺的是**把这些能力翻译成 madmin 线格式的适配层**，不是能力本身。
- **不存在通用 key-value 配置表**。全仓 39 张表里最接近的是四类：`cluster_topology_revisions`（版本链 + active 单飞）、`bucket_configs`（每桶一行、按 kind 分 jsonb 列）、`iam_account_password_policies`（singleton 行 + CHECK 约束）、`cluster_scheduler_states`（按名一行）。
- **编译期固化面几乎为零**：全仓 `Application.compile_env` 只有 1 处（`lib/maxio_web/router.ex:120` 的 `:dev_routes`），没有任何 `@attr Application.get_env(...)` 形式的模块属性固化。这是一个**极好的消息**：运行时配置存储的改造不需要处理 compile_env 陷阱。

### 0.2 本文交付什么

两件互相耦合的事，合并为一份设计：

1. **运行时配置存储（config store）** —— Admin API 的硬前置。没有它，`mc admin config set/get`、Tiers、Site Replication、Batch Jobs 全都无处落地，而且第一批 ServerInfo 里的 `deploymentID` 也无处持久化。
2. **`/minio/admin/v3/*` 骨架** —— 挂载点、鉴权、响应/错误契约、第一批端点范围、后续分批边界。

本文**不涵盖**：具体 handler 的 Elixir 代码、madmin 加密封装端点、`mc admin trace`/`mc admin console` 的流式协议、Site Replication、Batch Jobs、Tiers 的业务语义。

---

## 第一部分：运行时配置存储（config store）

## 1. 现状核查

### 1.1 配置怎么读的

配置全部走 **Application env**，共 160 处读取跨 85 个文件，分四种形态：

| 形态 | 出现数 | 含义 | 运行时可变？ |
|---|---|---|---|
| `Application.compile_env/2,3` | **1 处**（`lib/maxio_web/router.ex:120` 的 `:dev_routes`） | 编译期固化 | ❌ 必须重编译 |
| `@attr Application.get_env(...)` 模块属性 | **0 处** | —— | —— |
| `Application.fetch_env!/2` | 13 处 | 缺失即崩（fail-fast） | ✅ 技术上可 `put_env` |
| `Application.get_env/3` | 其余 | 带默认值 | ✅ 技术上可 `put_env` |

`config/runtime.exs` 只覆盖约 15 个环境变量，集中在「密钥 + 端口 + 数据目录 + 账号 id + 拓扑源 + pool 策略」：
`PHX_SERVER` / `PORT` / `MAXIO_ROOT_USER` / `MAXIO_ROOT_PASSWORD` / `MAXIO_DATA_DIR` / `MAXIO_S3_PORT` / `MAXIO_SSE_MASTER_KEY` / `MAXIO_KMS_MASTER_KEY` / `MAXIO_KMS_DEFAULT_KEY_ID` / `MAXIO_MFA_SECRET_KEY` / `MAXIO_ACCESS_KEY_SECRET_KEY[_ID/_KEYRING/_KEYRING_FILE]` / `MAXIO_ACCOUNT_ID` / `MAXIO_WEB_IDENTITY_PROVIDERS` / `MAXIO_TOPOLOGY_SOURCE` / `MAXIO_POOL_WRITE_POLICY` / `MAXIO_PEERS` / `DATABASE_URL` / `POOL_SIZE` / `DNS_CLUSTER_QUERY`。

**所有功能开关 / 调度器开关 / 阈值 / 权威源切换 / behaviour 绑定都不可运行时注入**，只能改代码重启。

### 1.2 已有的"运行时可变"先例（必须复用而非另起炉灶）

| 先例 | 位置 | 可借鉴的部分 |
|---|---|---|
| 拓扑版本链 | `lib/maxio/cluster/topology_store.ex` + `topology_revision.ex` + 迁移 `20260613153149` | config-or-DB 双源（`:topology_source, :config \| :db`）、active 单飞唯一索引、`topology_hash` 校验、`Topology.install_runtime!/1` 写 `:persistent_term` 做热应用 |
| 桶级配置 | `lib/maxio/bucket_configs.ex` | 按 kind 分列、写后 `Cluster.Notify` 广播；**但它每次 `Repo.get_by` 直查、无缓存**，config store 不能照抄这一点 |
| 单例行 | `iam_account_password_policies`（`singleton_key` + CHECK + 唯一索引） | 全局单行配置的建模范式 |
| 运行时改 app env | `lib/maxio/iam/signing_secret_rotation.ex:188` 的 `put_runtime_env/4` | 已有先例：轮转后把新 keyring 写回 `:access_key_secret` |
| 失效通路 | `lib/maxio/cluster/notify.ex`（PubSub topic `"maxio:metadata"`）+ `cache_invalidator.ex` | 现成的广播 + 订阅骨架；缺 `:config_changed` 事件类型 |

### 1.3 热路径读取点（性能约束的来源）

S3 请求管线（`lib/maxio/s3/endpoint.ex`）每请求都会读配置的点：

- `Plugs.PrometheusMetrics:75` → `:prometheus_metrics.public`
- `Plugs.AddressStyle:81,86` → `:s3.domain` / `:s3.website_domain`
- `Plugs.AccessLogDelivery:572` → `:sts`
- `Maxio.Auth:223` → `:s3.clock_skew_ms`（每次验签）
- `Auth.CredentialStore:20` / `Policy.Store:123` → behaviour 派发（每请求）
- `Maxio.ObjectMeta:39` → `:authoritative_source`（**每次对象读/列/写元数据**）
- `Maxio.Storage:9` → `:storage_backend`（每次存储操作）
- `Maxio.Storage.FS:1677` → `:s3.data_dir`（每次路径解析，最高频）
- `Storage.FS:618` / `ErasureCoded:1759` / `EpochStore:1250` / `ShardServer:1317` → `:durability.fsync`（每次写提交）

> **硬约束（决定后续所有设计）**：Application env 读取本身走 `:persistent_term`，是 O(1) 无锁读。任何"改成 DB 支撑"的方案**必须保留同等量级的本地读性能**，绝不允许退化成每请求一次 `Repo` 查询。这直接推导出 D2（读路径为 `:persistent_term` 缓存）。

### 1.4 分类：哪些配置项适合搬到运行时存储

分类判据三条：(a) 运维语义上确实需要不重启就改；(b) 改动不破坏正在进行的请求/数据不变量；(c) 不是安全根信任材料。

#### A 类 —— 适合运行时存储，且**热更新即刻生效**（读路径每次重读）

| 配置键 | 理由 | 生效方式 |
|---|---|---|
| `:prometheus_metrics.public` | 纯策略开关，读点在 plug 内 | 下一个请求 |
| `:s3.clock_skew_ms` | 纯阈值 | 下一次验签 |
| `:listing.sql_hard_limit` | 纯 DoS 闸门阈值 | 下一次 LIST |
| `:multipart_min_part_size` | 纯阈值（当前是隐式键） | 下一次 MPU |
| `:drive_health.*` / `:drive_identity.*` / `:drive_stats.provider` / `:drive_hardware_evidence.provider` / `:io_pressure.*` | 观测型遥测，无数据面不变量 | 下一次采样 |
| `:scheduler_ledger.*` / `:scheduler_ledger_retention.*` | 审计侧 | 下一轮 |
| `:pool_write_policy.*` | 只影响**新写**放置，既有对象读仍走持久化 placement | 下一次写 |
| `:notification_delivery.async?` | 投递策略 | 下一次投递 |
| `:read_prefer_index` | 快路径开关，miss 仍回落正确路径 | 下一次读 |

#### B 类 —— 适合运行时存储，但**只在下一轮调度生效**（scheduler tick 内重读）

已确认这批 scheduler **本来就在 tick 内重读 Application env**（`lifecycle/scheduler.ex:134`、`cluster/scrubber.ex:542`、`cluster/rebalance/scheduler.ex:826`、`cluster/fresh_drive_heal/scheduler.ex:464`、`s3/inventory/scheduler.ex:315`、`s3/notification_delivery/scheduler.ex:182`、`s3/replication_delivery/scheduler.ex:294`、`object_mutation/recovery/scheduler.ex:277`、`console/direct_multipart_upload/scheduler.ex:221`、`iam/signing_secret_rotation/scheduler.ex:195`、`iam/oidc_provider_refresh/scheduler.ex:197`、`storage/scanner.ex:1296`），所以只要读路径换成统一门面，它们**自动获得运行时可调能力**，无需改调度逻辑：

`:lifecycle_scheduler`、`:scrubber`（20 个子键）、`:fresh_drive_heal_scheduler`、`:rebalance_scheduler`、`:notification_delivery_scheduler`、`:replication_delivery_scheduler`、`:object_mutation_recovery_scheduler`、`:inventory_report_scheduler`、`:console_direct_multipart_pruner`、`:iam_oidc_provider_jwks_refresh`、`:iam_signing_secret_rotation`、`:scanner`。

> ⚠️ 但注意：这批键的 `enabled` 目前**同时**在 `lib/maxio/application.ex:98-147` 的 supervision tree 组装期被读一次，用于决定是否把 child 放进 tree。运行时把 `enabled` 从 `false` 改成 `true`，进程根本不存在，改了也不会跑。见 D6。

#### C 类 —— 可运行时存储，但**必须显式标注"需重启"**

| 配置键 | 为什么不能热更新 |
|---|---|
| `Maxio.S3.Endpoint.port` / `.ip` | Bandit 监听 socket 在 `Application.start` 期绑定 |
| `MaxioWeb.Endpoint.*` | 同上 |
| `Maxio.Repo` 连接参数 | 连接池在启动期建立 |
| `Maxio.Cluster.topologies`（libcluster） | 启动期 |
| 各 scheduler 的 `enabled`（见 B 类脚注） | supervision tree 组装期 |

这些**允许写入 config store**（这样 `mc admin config set` 有地方落、Console 能展示），但读路径仍在启动期读一次，且门面必须在写入时返回 `{:ok, :requires_restart}` 而不是假装已生效（铁律 3）。

#### D 类 —— **不纳入运行时配置**（见 §4）

### 1.5 分类：哪些必须保持编译期

只有一项：`:dev_routes`（`Application.compile_env`，`lib/maxio_web/router.ex:120`）。它决定 router 里是否编译进 dev-only 路由，语义上就是编译期的。不动。

---

## 2. 核心裁决

### D1 —— config store 是 **Postgres 单表 + 版本链**，不是 KV blob

**裁决**：新建 `runtime_configs` 表，**每个配置键一行**（键为 `subsystem` + `key` 两段），值为 `jsonb`，并保留 `previous_value` 与审计元数据；另建 `runtime_config_audits` 表记录完整变更历史。

**为什么不是单行大 JSON blob**：
- 单行 blob 的并发写必然互相覆盖（last-write-wins 静默丢失他人改动），违反铁律 3。
- 每键一行天然得到 per-key 乐观并发（`version` 列 + `WHERE version = ?`）。
- `mc admin config set <subsys> <k>=<v>` 的粒度本来就是 subsystem 级，与表结构同构。

**为什么不是 `Application.put_env` + 文件**：`put_env` 不跨节点、不跨重启、无审计、无校验；已有的 `signing_secret_rotation.ex` 的 `put_runtime_env` 是密钥轮转的特例（有落盘 keyring 兜底），不能推广成通用配置机制。

**为什么用 Postgres 而不是盘上 sidecar**：Postgres 已是 IAM / bucket / policy / topology 的元数据权威（`AGENTS.md` §2 明确"元数据走 Postgres + Ecto"）。配置是元数据不是对象字节，落 PG 与既有权威边界一致。ROUTE B 的 sidecar 权威切换只针对**对象元数据**，不涉及集群配置。

**契合铁律**：铁律 1（统一数据契约——配置读写经单一门面）、铁律 3（明确状态设计：每次变更有版本、有审计、非法值硬失败）。

### D2 —— 读路径是 `:persistent_term` 快照 + 统一门面 `Maxio.Config.get/2,3`

**裁决**：进程启动时把 config store 全量物化进 `:persistent_term`，读路径永不打 DB。

```
Maxio.Config.get(subsystem, key, default \\ :__no_default__)
Maxio.Config.fetch!(subsystem, key)
Maxio.Config.get_all(subsystem)         # 返回 keyword，兼容现有 Keyword.get 风格
Maxio.Config.source(subsystem, key)     # :runtime | :env | :compile —— 取证用，绝不猜
```

**优先级（自高而低，硬规定）**：

```
1. runtime override（runtime_configs 表中该键的 active 行）
2. env var（config/runtime.exs 已注入 Application env 的值）
3. compile-time default（config/*.exs 的值）
```

**为什么 runtime > env**：运维在 `mc admin config set` 之后期望立刻看到效果；如果 env 反过来压住 runtime，操作会静默无效（铁律 3 禁止）。但为了不让运维困惑，门面必须提供 `source/2`，并在 Console / `mix maxio.config.get` 输出中显示每个键的**实际生效来源**。

**为什么不是相反**：env var 在容器编排里是"部署时意图"，runtime override 是"运维时意图"，后者更新更晚、更具体。这与 Kubernetes 的 `kubectl set env` 覆盖镜像默认值同构。

**实现形态（关键）**：`:persistent_term` 的 key 用 `{Maxio.Config, subsystem}`，value 是该 subsystem 的完整合并后 keyword/map。这样：
- 读是 O(1) 无锁无拷贝（大 term 只在写时全局 GC 一次）。
- 一次写只影响一个 subsystem 的 term，`:persistent_term` 全局 GC 代价被限制在低频写路径。
- 现有热路径的 `Application.get_env(:maxio, :durability) |> Keyword.get(:fsync)` 可以逐点换成 `Maxio.Config.get(:durability, :fsync)`，语义与性能同量级。

**迁移策略（不做一次性大爆炸改造）**：门面第一版的实现 **fallback 到 `Application.get_env`**。即 `Maxio.Config.get/3` 在 `:persistent_term` 中未找到 runtime override 时，直接回落到现有 `Application.get_env(:maxio, subsystem)`。这样：
- 第一批只需要新增门面 + store + 少量键的接线，不必一次改 160 个读取点。
- 后续每批把一组读取点换成门面调用，行为不变（因为 fallback 语义与原来完全相同）。
- **绝不允许"部分键走门面、部分键直读 env，但两者对同一键给出不同答案"** —— 一旦某键被纳入 config store 白名单，它的所有读取点必须同批换成门面（见 §7 测试策略的一致性回归）。

**契合铁律**：铁律 1（后端/配置读取经统一契约）、铁律 4 无关（不涉及 body）。

### D3 —— 只有**白名单键**能进 config store；白名单是代码里的 schema，不是 DB 里的数据

**裁决**：新增 `Maxio.Config.Schema` 模块，用编译期数据结构声明每个可运行时配置的键：

```
%{
  {:durability, :fsync}       => %{type: :boolean, default: true,  apply: :hot,     doc: "..."},
  {:listing, :sql_hard_limit} => %{type: {:integer, 1..10_000_000}, default: 100_000, apply: :hot, doc: "..."},
  {:s3, :clock_skew_ms}       => %{type: {:integer, 0..3_600_000}, default: 900_000, apply: :hot, doc: "..."},
  {Maxio.S3.Endpoint, :port}  => %{type: {:integer, 1..65_535},   default: 9000,   apply: :restart, doc: "..."},
  ...
}
```

`apply` 只有三个值：`:hot`（下一次读即生效）、`:next_cycle`（下一轮 scheduler tick）、`:restart`（需重启进程/节点）。

**为什么白名单而不是"任意键都能写"**：
- 任意键可写 = 运维可以写进一个没人读的键，然后以为改生效了 —— 这是典型的静默失败（铁律 3）。
- 白名单让 `mc admin config set` 的未知键能立刻返回结构化错误。
- 白名单的 `type` 让校验有据可依，不用在每个读取点重复防御。
- 白名单的 `apply` 让写路径能诚实告诉运维"这个改动需要重启"。

**为什么 schema 在代码里而不是 DB 表里**：schema 的正确性由代码决定（哪些键真的被读、类型是什么）。放 DB 会出现"schema 说有这个键但代码不读它"的漂移。代码里的 schema 可以被测试静态断言（见 §7 T1）。

**契合铁律**：铁律 3（绝不静默失败）、铁律 5（行为对齐真实实现 —— MinIO 的 `mc admin config set` 对未知 subsystem/key 也是硬报错）。

### D4 —— 写路径：admin 鉴权 + schema 校验 + 事务内审计 + 广播失效

写一次配置的完整链路（每一步失败都必须结构化报错、绝不部分生效）：

```
1. 鉴权：admin action `admin:ConfigUpdate` → 复用 Policy.Evaluator
   ⚠️ VERIFY-AT-IMPL V-A3：**读**配置用哪个 action 尚未实锤。已从 `minio/pkg` 的
   `policy/admin-action.go` 取证到的常量表里只有 `ConfigUpdateAdminAction = "admin:ConfigUpdate"`，
   没有独立的读 action。在核实前，读写统一用 `admin:ConfigUpdate`，**绝不自造 action 名**。
2. schema 查表：键不在白名单 → {:error, {:unknown_config_key, subsystem, key}}
3. 类型/范围校验：不合法 → {:error, {:invalid_config_value, subsystem, key, reason}}
4. 语义校验（可选 validator fun）：如 :erasure 的 parity <= N/2 → {:error, {:invalid_config_value, ...}}
5. 单事务：
     a. SELECT ... FOR UPDATE 取当前行
     b. 乐观并发：入参 expected_version 与当前 version 不符 → {:error, :config_version_conflict}
     c. UPDATE runtime_configs（value/previous_value/version+1/updated_by/updated_at）
     d. INSERT runtime_config_audits（完整前后值 + principal_arn + request_id + source）
6. 事务提交后：Cluster.Notify.broadcast({:config_changed, subsystem, key})
7. 本节点 + 各节点 CacheInvalidator 收到 → Maxio.Config.Store.reload(subsystem) → :persistent_term 重装
8. 返回 {:ok, %{applied: :hot | :next_cycle | :restart, version: n}}
```

**关键点：第 8 步的 `applied` 必须是白名单里 `apply` 字段的诚实回传。** 对 `:restart` 类键，返回值明确告诉运维"已持久化，但需要重启才生效"，且 `mix maxio.config.set` 与 Console 都必须显示这句话。这是铁律 3 在配置面的具体体现 —— **写成功 ≠ 生效**，两者绝不能混为一谈。

**谁能写**：只有通过 `admin:ConfigUpdate` 授权的 principal。root 短路（对齐 `PrometheusAuthz.root?/1`）。CLI（`mix maxio.config.set`）走同一 store 函数，但以 `source: "cli"` 标注审计行；CLI 在本机 BEAM 内运行，不经 HTTP 鉴权（与既有 40 个 `mix maxio.iam.*` 任务同构）。

**审计**：`runtime_config_audits` 记录 `principal_arn` / `access_key_id` / `request_id` / `source`（`"admin_api" | "cli" | "console"`）/ `old_value` / `new_value` / `applied` / `inserted_at`。**敏感值绝不落审计明文**（见 §4）。

### D5 —— 多节点：PG 是单一事实来源，节点缓存靠"广播 + 版本兜底"

**裁决**：
- **权威**：`runtime_configs` 表。任何节点重启后从 PG 重新物化，不依赖广播。
- **传播（快路径）**：复用 `Maxio.Cluster.Notify.broadcast/1`，新增事件 `{:config_changed, subsystem, key}`；`Maxio.Cluster.CacheInvalidator` 新增 handler 调 `Maxio.Config.Store.reload/1`。
- **兜底（慢路径）**：`Maxio.Config.Store` 是 GenServer，每 `refresh_interval_ms`（默认 30s）拉一次 `MAX(version)` 聚合；若与本地快照的聚合版本不同则整体重载。

**为什么必须有慢路径兜底**：`Cluster.Notify` 的 moduledoc 明说"M8 使用 Phoenix.PubSub 作为本地 transport，libcluster 传播可以后续叠加"，且 `broadcast/1` 在 PubSub 未起时是 **best-effort 静默 `:ok`**。也就是说广播**不保证送达**。如果只靠广播，一次丢失就会导致某节点长期用旧配置 —— 这正是"静默失败"。周期性版本对账把最坏情况从"永久分歧"收敛成"最多落后一个 refresh 周期"，并且可观测。

**可观测性（强制）**：`Maxio.Config.Store` 必须导出每节点的 `%{aggregate_version, loaded_at, last_reload_reason}`，并且：
- `mix maxio.config.status` 打印本节点快照版本 + PG 权威版本 + 是否漂移；
- ServerInfo / Console 的集群健康视图暴露"各节点配置版本是否一致"；
- 检测到本节点落后超过 N 个周期 → `Log.error` 结构化告警（绝不静默）。

**为什么不用 PG `LISTEN/NOTIFY`**：可以，但那是第二选择。Phoenix.PubSub 通路已经存在且已被 IAM 凭据失效复用；引入第二套通知机制会分裂失效语义。若后续 libcluster 传播不达标，`LISTEN/NOTIFY` 是明确的升级路径（记为 VERIFY-AT-IMPL V-C3）。

**并发**：同键并发写由第 5b 步的乐观版本冲突处理（返回 `:config_version_conflict`，调用方重试）。跨键并发无需协调（每键独立行）。

### D6 —— scheduler `enabled` 的启动期读取是**已知缺口**，本设计只标注不修复

`lib/maxio/application.ex:98-147` 在组装 supervision tree 时读 12 个 scheduler 的 `enabled`。运行时把 `enabled` 从 `false` 改 `true`，进程不存在。

**裁决**：第一批**不修复**。config store 对这批键统一标 `apply: :restart`，写入返回 `{:ok, %{applied: :restart}}`，运维得到诚实反馈。

**为什么不顺手修**：正确的修法是把每个 scheduler 无条件放进 tree、由 tick 内的 `enabled` 判定决定是否干活（大部分 scheduler 已经在 tick 内重读了 `enabled`）。这是一个跨 12 个模块的行为改动，需要独立的批次与独立复审 —— 塞进 Admin API 骨架批次就是打补丁式扩张（`AGENTS.md` §4.2 反对的模式）。记为后续批次 **B-LATER-1**。

---

## 3. Schema 草案

> 命名与注释风格对齐 `priv/repo/migrations/20260613153149_create_cluster_topology_revisions.exs`：主键 `binary_id`、`timestamps(type: :utc_datetime_usec)`、每表每列中文 `comment:`、裸 `execute` 建的索引用 `COMMENT ON INDEX`、`down` 里逆序置 `NULL`。因含 `execute`，迁移用 `def up/def down` 而非 `change`。

### 3.1 `runtime_configs` —— 运行时配置当前值（每键一行）

```elixir
create table(:runtime_configs,
         primary_key: false,
         comment: "运行时配置存储；每个白名单配置键一行，是集群配置覆盖值的单一事实来源，优先级高于 env var 与编译期默认"
       ) do
  add :id, :binary_id, primary_key: true, comment: "运行时配置行 UUID 主键"

  add :subsystem, :string,
    null: false,
    comment: "配置子系统名；对应 Application env 的第二级键，如 durability / listing / s3 / scrubber，或模块名字符串如 Elixir.Maxio.S3.Endpoint"

  add :key, :string,
    null: false,
    comment: "子系统内的配置键名，如 fsync / sql_hard_limit / clock_skew_ms；与 subsystem 组成白名单查表主键"

  add :value, :map,
    null: false,
    comment: "配置值的 JSON 包装 %{\"v\" => 值}；统一包成 object 以便存储标量、列表与 map，读取时按 Schema 声明的类型解码"

  add :previous_value, :map,
    comment: "上一版配置值的 JSON 包装；NULL 表示这是该键的首次覆盖，供快速回滚与漂移取证"

  add :version, :integer,
    null: false,
    default: 1,
    comment: "该键的单调递增版本号；写路径以 expected_version 做乐观并发，冲突返回结构化错误而非静默覆盖"

  add :apply_mode, :string,
    null: false,
    comment: "生效方式快照：hot 表示下一次读即生效，next_cycle 表示下一轮调度生效，restart 表示已持久化但需重启节点才生效"

  add :updated_by, :string,
    comment: "最后一次写入者的 principal ARN；CLI 写入记为 arn:aws:iam:::root 或实际操作者，供审计追溯"

  add :source, :string,
    null: false,
    comment: "最后一次写入来源：admin_api / cli / console；区分变更通道以便定位误操作"

  timestamps(type: :utc_datetime_usec)
end

create unique_index(:runtime_configs, [:subsystem, :key],
         name: :runtime_configs_subsystem_key_index,
         comment: "运行时配置键唯一索引；同一 subsystem 下同名键最多一行，保证配置无歧义"
       )

create index(:runtime_configs, [:updated_at],
         name: :runtime_configs_updated_at_index,
         comment: "按更新时间检索配置变更；供节点缓存对账与最近变更取证"
       )

execute("""
ALTER TABLE runtime_configs
  ADD CONSTRAINT runtime_configs_apply_mode_check
  CHECK (apply_mode IN ('hot', 'next_cycle', 'restart'))
""")

execute("""
COMMENT ON CONSTRAINT runtime_configs_apply_mode_check ON runtime_configs IS
'生效方式白名单约束；禁止写入未知 apply_mode，避免运维误判配置是否已生效'
""")

execute("""
ALTER TABLE runtime_configs
  ADD CONSTRAINT runtime_configs_source_check
  CHECK (source IN ('admin_api', 'cli', 'console'))
""")

execute("""
COMMENT ON CONSTRAINT runtime_configs_source_check ON runtime_configs IS
'变更来源白名单约束；禁止写入未知来源，保证审计通道可枚举'
""")

execute("COMMENT ON COLUMN runtime_configs.inserted_at IS '该配置键首次被覆盖的时间'")
execute("COMMENT ON COLUMN runtime_configs.updated_at IS '该配置键最后一次变更时间'")
```

### 3.2 `runtime_config_audits` —— 变更审计流水（只追加）

```elixir
create table(:runtime_config_audits,
         primary_key: false,
         comment: "运行时配置变更审计流水；只追加不修改，记录每次 set/reset 的前后值与操作者，供合规追溯与回滚取证"
       ) do
  add :id, :binary_id, primary_key: true, comment: "配置审计记录 UUID 主键"

  add :subsystem, :string, null: false, comment: "被变更配置的子系统名；与 runtime_configs.subsystem 同义，审计行不设外键以便配置行删除后审计仍保留"
  add :key, :string, null: false, comment: "被变更配置的键名；与 runtime_configs.key 同义"

  add :operation, :string,
    null: false,
    comment: "变更操作：set 表示写入覆盖值，reset 表示删除覆盖值回落到 env/编译期默认"

  add :old_value, :map, comment: "变更前的配置值 JSON 包装；NULL 表示变更前无覆盖值。敏感键此列写入脱敏占位符，绝不落明文"
  add :new_value, :map, comment: "变更后的配置值 JSON 包装；reset 操作为 NULL。敏感键此列写入脱敏占位符，绝不落明文"

  add :from_version, :integer, comment: "变更前的键版本号；NULL 表示首次覆盖"
  add :to_version, :integer, null: false, comment: "变更后的键版本号；与 runtime_configs.version 对应"

  add :apply_mode, :string, null: false, comment: "本次变更的生效方式：hot / next_cycle / restart，记录当时 Schema 声明值"

  add :principal_arn, :string, comment: "发起变更的 principal ARN；匿名或无法解析时为 NULL 并在 source 中标注通道"
  add :access_key_id, :string, comment: "发起变更所用的 access key id；便于与 IAM 访问记录关联，CLI 通道可为 NULL"
  add :request_id, :string, comment: "触发变更的 HTTP 请求 id；与结构化日志的 request_id 对齐，CLI 通道为 NULL"

  add :source, :string, null: false, comment: "变更来源通道：admin_api / cli / console"

  timestamps(type: :utc_datetime_usec, updated_at: false)
end

create index(:runtime_config_audits, [:subsystem, :key, :inserted_at],
         name: :runtime_config_audits_key_time_index,
         comment: "按配置键与时间倒查变更历史；供单键回滚与漂移定位"
       )

create index(:runtime_config_audits, [:inserted_at],
         name: :runtime_config_audits_time_index,
         comment: "按时间检索全局配置变更流水；供审计导出与近期变更巡检"
       )

execute("""
ALTER TABLE runtime_config_audits
  ADD CONSTRAINT runtime_config_audits_operation_check
  CHECK (operation IN ('set', 'reset'))
""")

execute("""
COMMENT ON CONSTRAINT runtime_config_audits_operation_check ON runtime_config_audits IS
'配置审计操作白名单约束；只允许 set / reset 两种已定义变更语义'
""")

execute("COMMENT ON COLUMN runtime_config_audits.inserted_at IS '配置变更发生时间；审计行只追加，无更新时间列'")
```

### 3.3 Ecto schema（对齐 `cluster_scheduler_state.ex` 惯例）

`Maxio.Config.RuntimeConfig` 与 `Maxio.Config.RuntimeConfigAudit`，均 `@primary_key {:id, :binary_id, autogenerate: true}` + `timestamps(type: :utc_datetime_usec)`，枚举用 `~w()` 白名单 + `validate_inclusion`（不用 `Ecto.Enum`，对齐全仓惯例），唯一约束用显式索引名。

---

## 4. 明确**不纳入**运行时配置的项

以下键**禁止**进入 config store 白名单，写入尝试必须返回 `{:error, {:forbidden_config_key, subsystem, key}}` 并打 `Log.warn`：

| 键 | 理由 |
|---|---|
| `:sse.master_key` | SSE-S3 信封加密主密钥。它是**根信任材料**：一旦落进可经 Admin API 读写的 PG 表，任何拿到 `admin:ConfigUpdate` 的 principal 就能替换主密钥（导致既有对象永久不可解）或读出主密钥（导致全量对象可解）。密钥必须继续经 `MAXIO_SSE_MASTER_KEY` 注入，prod 已有 base64/32B 强校验（`config/runtime.exs`）。 |
| `:kms.master_key` / `:kms.provider` | 同上。`provider` 是可加载任意模块的 behaviour 绑定，写它等于远程代码执行面。 |
| `:access_key_secret.*`（`secret_key` / `keyring` / `keyring_file`） | 包裹所有长期 access key 与 STS session 签名密钥的信封密钥。已有专门的轮转机制（`Maxio.IAM.SigningSecretRotation`），且轮转会 rewrap 既有密文 —— 绕过它直接改 key 会让全部凭据不可解。 |
| `:mfa.secret_key` | MFA/MFA-Delete 秘密的信封密钥，同上。 |
| `:s3.root_user` / `:s3.root_password` | root 凭据。可运行时改 = 提权路径（有 `admin:ConfigUpdate` 的普通 IAM 用户可把自己变成 root）。 |
| `:storage_backend` / `:credential_store` / `:policy_store` / `:mfa_delete_verifier` / `:shard_transport` | **behaviour 绑定 = 任意模块名**。运行时写模块名 = 让配置写权限升级为代码执行权限。而且切后端会让既有对象的物理布局解释权瞬间改变（FS 布局 ≠ EC 布局），数据面直接崩。铁律 2 说"换后端只改一行配置"，指的是**部署期**改一行，不是运行期热切。 |
| `:erasure.drives` / `.data_shards` / `.parity_shards` | 改这三项会让**既有对象的 shard 布局解释错误**（读出乱码或 quorum 误判）。EC 参数变更在 MinIO 里也是 pool 级不可变量，必须走 rebalance/decommission 流程。 |
| `:authoritative_source`（read/list/write） | 元数据权威源切换是 ROUTE B 的分阶段 cutover 开关，需要 shadow 比对驱零取证才能翻。运行时热翻会让读/写在同一秒内看到两套权威，破坏一致性不变量。保持部署期配置 + 显式 cutover 流程。 |
| `:topology_source` | 决定拓扑来自 config 还是 DB。运行时改会让 `Topology.install_runtime!/1` 的 persistent_term 与实际来源脱钩。拓扑已有自己的版本链与激活流程（`TopologyStore.activate_topology/2`），不应再叠一层。 |
| `Maxio.Repo` 连接参数 | 改它需要重建连接池；且 config store 自己就住在这个 Repo 里 —— 自举依赖（改错就再也读不到配置来改回去）。 |
| `:dev_routes` | `Application.compile_env`，编译期语义。 |

**通用判据（写进 `Maxio.Config.Schema` 的文档）**：一个键**不得**运行时可写，若它满足以下任一条：
1. 是密钥 / 根信任材料；
2. 是模块名（behaviour 绑定），写它等价于代码执行；
3. 改它会让**既有已落盘数据**的解释方式改变；
4. 它是 config store 自身的自举依赖；
5. 它是 `Application.compile_env`。

---

## 5. 绝不静默失败：错误契约

`Maxio.Config` 写路径的全部失败形态（每一个都有专属结构化错误 + `Log.warn/error`，绝不回落到默认值继续跑）：

| 错误 | 触发 | HTTP 映射（Admin API） |
|---|---|---|
| `{:unknown_config_key, subsystem, key}` | 键不在 Schema 白名单 | 400 |
| `{:forbidden_config_key, subsystem, key}` | 键在 §4 禁止清单 | 403 |
| `{:invalid_config_value, subsystem, key, reason}` | 类型/范围/语义校验失败 | 400 |
| `:config_version_conflict` | 乐观并发冲突 | 409 |
| `{:config_store_unavailable, reason}` | PG 不可达 | 503 |

**启动期的严格性**：`Maxio.Config.Store` 在 `init/1` 物化快照时，若 PG 中存在**当前 Schema 白名单里不存在的键**（例如降级回旧版本二进制），必须：
- `Log.error("runtime config key not in schema", subsystem:, key:)`；
- **忽略该行**（不把未知键塞进 persistent_term）；
- 在 `mix maxio.config.status` 与 ServerInfo 的健康视图中标记为 `orphan_config_keys`。

**绝不做的事**：把无法解析的配置值静默替换成默认值然后继续启动。若某个**白名单内**的键在 PG 里的值无法按 Schema 类型解码，`Store.init/1` 直接 `raise`（fail-fast），因为这说明写路径校验被绕过了，是完整性问题。

---

## 6. CLI（`AGENTS.md` §4.4 强制）

| 任务 | 作用 |
|---|---|
| `mix maxio.config.list [--subsystem S] [--json]` | 列出全部白名单键：当前生效值、来源（runtime/env/compile）、apply 模式、版本 |
| `mix maxio.config.get <subsystem> <key> [--json]` | 单键取证，显示生效值 + 三层来源各自的值（**这是定位"我改了怎么没生效"的核心工具**） |
| `mix maxio.config.set <subsystem> <key> <value> [--expected-version N]` | 写覆盖值；输出必须明确打印 `applied: hot \| next_cycle \| restart` |
| `mix maxio.config.reset <subsystem> <key>` | 删除覆盖值，回落 env/编译期默认 |
| `mix maxio.config.history <subsystem> <key> [--limit N]` | 打印审计流水 |
| `mix maxio.config.status [--json]` | 本节点快照版本 vs PG 权威版本、漂移检测、orphan 键 |

结构化日志字段（需加入 `config/config.exs` 的 logger metadata 白名单，否则会被静默丢弃 —— 已有 ObjectMutation 的前车之鉴）：
`:config_subsystem`、`:config_key`、`:config_version`、`:config_apply_mode`、`:config_source`。

---

# 第二部分：MinIO Admin API 骨架

## 7. 现状核查：现有管线与挂载点

### 7.1 `Maxio.S3.Endpoint` 的 plug 链（`lib/maxio/s3/endpoint.ex`，全文 25 行）

```
Plug.RequestId
Maxio.S3.Plugs.RequestLimits          # 请求头/元数据大小闸
Maxio.S3.Plugs.PrometheusMetrics      # ← MinIO 专有路径的既有先例：早于 AddressStyle 拦截 + halt
Maxio.S3.Plugs.AddressStyle           # path/vhost → s3_bucket / s3_key / s3_level（非 halt）
Maxio.S3.Plugs.RequestMetrics
Maxio.S3.Plugs.AccessLogDelivery
Maxio.S3.Plugs.WebsiteEndpoint        # 仅当 s3_endpoint_kind == :website 时 halt
Maxio.S3.Plugs.Cors                   # OPTIONS 预检 halt
Maxio.S3.Plugs.PostObject             # 仅当 POST multipart/form-data 时 claim
Maxio.S3.Plugs.SigV4                  # 鉴权；无凭据 → :anonymous（不 halt）；坏凭据 → halt XML
Maxio.IAM.QueryPlug                   # 仅当 credential scope service == "iam" 时 claim POST form
Maxio.STS.QueryPlug
Maxio.S3.Plugs.Dispatch               # Dispatcher.resolve/3 判定表 → Authz → Handlers
```

三个对本设计至关重要的既有事实：

1. **`AddressStyle` 不 halt**，只 assign。所以下游插入新分支不会被它拦住。
2. **`SigV4` 在完全无凭据时返回 `:anonymous` 而不是 401**（`detect_and_parse/1` 的第三分支，注释明确写了"匿名只从『凭据完全缺席』推断"）。但**有 Authorization 头却畸形时是硬失败 halt**。
3. `PrometheusMetrics` 已经确立了"MinIO 专有路径在 `AddressStyle` 之前拦截并 halt"的模式，并用 admin action 授权。

### 7.2 `Maxio.S3.Dispatcher` 是 S3 数据面专用的判定表

`Dispatcher.resolve(level, method, query_keys)` 的输入是 `{:service | :bucket | :object}` × method × query 子资源集合。**Admin API 是 REST-shaped 的（路径即动作，`/minio/admin/v3/info`），不是 RPC-over-query**，硬塞进这张判定表会污染它的语义（它的三个 level 对 admin 路径毫无意义）。因此 **admin 不进 Dispatcher**。

---

## 8. 核心裁决（Admin 面）

### D7 —— Admin 面挂在**同一个 `Maxio.S3.Endpoint`**，用新的 plug 分支，**不新建 Endpoint**

**裁决依据是硬事实，不是偏好**：madmin 的 `makeTargetURL` 用的就是 alias 的 host:port。`mc admin info myalias` 会打到 `http://localhost:9000/minio/admin/v3/info` —— 与 S3 请求**同一个端口**。独立 Endpoint 意味着独立端口，`mc` 无法访问。所以这是被客户端协议钉死的，没有选择空间。

这也与 `AGENTS.md` 的表述不冲突：那句"S3 用独立 Endpoint"指的是 **S3 API 面独立于 Console 的 `MaxioWeb.Endpoint`**，而 admin 面在 MinIO 里本来就是 S3 端口上的保留路径命名空间（`minioReservedBucketPath = "/minio"`），属于 S3 Endpoint 的一部分。

**具体插入位置（两个 plug，不是一个）**：

```
Plug.RequestId
Maxio.S3.Plugs.RequestLimits
Maxio.S3.Plugs.AddressStyle       # ← 上移：保留面的认领判定需要寻址结果（见 D8 回写 1）
Maxio.S3.Plugs.MinioHealth        # ← 新增①：/minio/health/*，无鉴权，早于 SigV4
Maxio.S3.Plugs.PrometheusMetrics  # ← 同样移到 AddressStyle 之后（同一劫持缺陷）
... （原有中段不变：RequestMetrics / AccessLogDelivery / WebsiteEndpoint / Cors / PostObject）
Maxio.S3.Plugs.SigV4
Maxio.Admin.Plug                  # ← 新增②：/minio/admin/v3/*，需要 assigns.principal
Maxio.IAM.QueryPlug
Maxio.STS.QueryPlug
Maxio.S3.Plugs.Dispatch
```

> 实现批次修正：health / metrics 原设计挂在 `AddressStyle` **之前**，实测会在 virtual-host 寻址下
> 劫持任意桶的 `minio/...` key（D8 回写 1）。二者移到 `AddressStyle` 之后、`RequestMetrics` 之前——
> 既拿到寻址结果，又保持"探针与 metrics 面对数据面统计不可见"的既有语义不变；仍早于 SigV4，
> 探针依旧免鉴权（`AddressStyle` 不鉴权也不 halt）。

**为什么 health 与 admin 必须拆成两个 plug、且分列 SigV4 两侧**：

- health 是 **liveness/readiness 探针**。k8s / LB 的探针**不带凭据**。若把它放在 SigV4 之后，一旦有人给探针配了过期凭据（或 header 畸形），SigV4 会 halt 并返回 403 XML —— 探针会因为**鉴权问题**而误报服务已死，触发不必要的重启。健康探针因鉴权失败而失败，是把可用性判断耦合到了鉴权子系统上，属于设计缺陷。MinIO 自己也是把 `healthcheck-router` 注册在 auth middleware 之外的（`cmd/healthcheck-router.go` 独立于 `adminRouter`）。
- admin 需要 `conn.assigns.principal`，必须在 SigV4 之后。

**为什么不放进 `PrometheusMetrics` 那个 plug**：职责隔离。Prometheus 是 bearer token + 文本曝露格式；admin 是 SigV4 + JSON。合并会让一个 plug 承担两套鉴权与两套响应格式。

### D8 —— `/minio` 必须成为**保留 bucket 名**，否则路径影子化是静默数据不可达

`lib/maxio/buckets.ex:12-13` 目前只保留 `xn-- / sthree- / amzn-s3-demo-` 前缀与 `-s3alias / --ol-s3 / .mrap / --x-s3 / --table-s3` 后缀。**`minio` 不在保留名单**。

一旦 `MinioHealth` / `Admin.Plug` 上线，path-style 的 `GET /minio/...` 会被它们 claim，导致**一个名为 `minio` 的既有桶在 path-style 下永久不可达**，且客户端拿到的是 admin 面的 404 JSON 而不是 S3 错误 —— 这是典型的静默失败（铁律 3）。

**裁决**：本批必须同时：
1. 把 `minio` 加入 `Maxio.Buckets` 的保留桶名，`CreateBucket` 时返回 `InvalidBucketName`（400）；
2. 迁移/启动期检查：若 PG 中已存在名为 `minio` 的桶，**启动时 `Log.error` 结构化告警并在 `mix maxio.config.status` / ServerInfo 健康视图标记**，绝不静默；
3. `MinioHealth` / `Admin.Plug` 的路径匹配必须**精确**（`/minio/health/...`、`/minio/admin/...` 前缀 + 完整段匹配），不能用 `String.starts_with?("/minio")` 粗匹配 —— 否则 `/minioxyz` 这个合法桶也会被误吞。对齐 `Prometheus.metrics_path?/1` 已有的谨慎写法（它显式区分 `/minio/v2/metrics` 与 `/minio/v2/metricsfoobar`）。

> **VERIFY-AT-IMPL V-A1**：真实 MinIO 是否把 `minio` 整体保留为桶名（`isMinioReservedBucket`），还是只保留 `/minio` 路径前缀。需核对 `minio/cmd/utils.go`。maxio 的取舍应对齐真实行为。

**D8 实现批次回写（2026-08-18）**——落地时补齐的三条，均有活体取证，后续批次直接以此为准：

1. **认领必须同时约束寻址方式**。原文只说"路径匹配必须精确"，不够：virtual-host 寻址下
   `Host: <bucket>.<domain>` + `GET /minio/health/live` 指的是**桶 `<bucket>` 里 key 为
   `minio/health/live` 的对象**。只看 `conn.request_path` 认领会把**任意桶**的这批 key 劫持成
   200 空 body / admin JSON / metrics 文本——比报错更危险，备份与同步工具会把 200 空 body 当成
   一个合法的空对象。故三个保留面（health / admin / metrics）**统一挂在 `AddressStyle` 之后**，
   经 `ReservedNamespace.claimed?/2` 要求 `assigns.s3_address_style == :path`。
   health / metrics 仍在 SigV4 之前（探针不带凭据），admin 仍在 SigV4 之后（需要 principal）。
   回归用例：`test/maxio/s3/reserved_namespace_addressing_test.exs`。
2. **"禁止新建"与"合法已存在"是两个概念，必须各有名字**。保留名单只能用于 CreateBucket
   准入（`Maxio.Buckets.validate_creatable_name/1`）；写路径 / journal changeset /
   `ObjectEpoch` target 一律只做**桶名语法**校验（`validate_addressable_name/1`）。
   两者混用会让"新增一个保留名"把**存量同名桶**静默降级成只读（每次 PutObject 在 journal
   changeset 上失败 → 500 InternalError），这正是保留 `minio` 之后实测到的症状。
3. **只报告是不够的，必须给出运维出路**。path-style 部署下被影子化的 key 既读不到也删不掉
   （DELETE 同样被认领），于是 DeleteBucket 永远 `BucketNotEmpty`。因此除启动期审计外还提供
   `mix maxio.reserved_bucket.purge`（默认 dry-run，`--confirm-delete` 才删），审计文案直接
   指向它。**未采用**"plug 在 DELETE 时放行"的方案：它只能救 health 的两条精确路径、救不了
   admin 的整个前缀，且会让探针行为随数据状态漂移，而 GET 仍被认领——运维能删却读不到自己
   要删的东西。审计的扫描面由认领规则表派生（`ReservedNamespace.shadowed_targets/0`），
   总数走精确聚合、逐 key 列举有上限但明说截断量，绝不静默截断。
4. **保留面只在 path-style 下可达，是对 MinIO 的已知偏离，运维后果必须写明**。
   MinIO 把 health / admin / metrics 注册在**顶层 mux、不看 Host**（`cmd/routers.go`：
   `healthcheck-router` / `adminRouter` / `metricsRouter` 都注册在 bucket 路由之前且不做
   Host 匹配），所以 `mc admin info https://minio.example.com` 也能命中。maxio 的
   `ReservedNamespace.claimed?/2` 额外要求 `assigns.s3_address_style == :path`（第 1 条的
   数据完整性取舍），于是当 `config :maxio, :s3, :domain` 配了真实域名时：

   | 场景 | MinIO | maxio |
   |---|---|---|
   | `GET https://s3.example.com/minio/health/live`（path-style） | 200 | 200 |
   | `GET https://minio.example.com/minio/health/live`（vhost，桶名 `minio`） | 200 | 落 S3 面 → `NoSuchBucket`/对象 404 |
   | `mc admin info https://<bucket>.example.com` | admin JSON | S3 XML 错误，madmin 显示 "bucket does not exist" |
   | `GET https://<bucket>.example.com/minio/v2/metrics` | metrics 文本 | 落 S3 面 |

   **运维要求**：k8s/LB 探针、`mc admin`、Prometheus scrape target **一律用 path-style
   endpoint**（Host 里不带桶名）。**不得**把 `:domain` 配成会让运维 Host 被解析成桶名的形式。

   **诊断**：一条被认领的路径仅因寻址方式被跳过时，`claimed?/2` 打结构化 warning
   （`reason: "reserved_surface_skipped_non_path_addressing"`，带 surface / bucket /
   address_style / resource），运维可据此把 `NoSuchBucket` 直接归因到寻址方式，
   而不是去排查"admin 面是不是没上线"。**不接受**"沉默地返回 NoSuchBucket"（铁律 3）。

   为什么不对齐 MinIO：对齐就必须在 vhost 下也认领 `/minio/...`，那会让**任意桶**里
   `minio/health/live` 这类真实对象被劫持成 200 空 body / admin JSON / metrics 文本
   ——静默数据劫持的危害远大于"运维必须用 path-style endpoint"的不便。

### D9 —— 鉴权：**完全复用现有 SigV4 + Policy 评估器**，零新鉴权代码

调研已实锤三件事，使得复用是自然的而不是勉强的：

**(a) 签名 service 名就是 `s3`**。madmin 用 minio-go 的 `signer.SignV4`，`ServiceTypeS3 = "s3"`。maxio 的 `Maxio.Auth.verify_signature/3` 用 `sr.service` 逐字重建 scope 并派生 kSigning，对 service 名没有白名单限制 —— 天然通过。

**(b) 【头号兼容风险，已提前排雷】credential scope 的 region 段是空字符串**。madmin `api.go` 的 `location := ""` **全程不被赋值**，所以 scope 形如 `20260818//s3/aws4_request`。maxio 侧核查结论：
- `AuthHeaderParser.parse_credential/1` 用 `String.split(credential, "/")` 匹配 `[ak, date, region, service, "aws4_request"]`。空 region 会产生 `["AK","20260818","","s3","aws4_request"]` —— **5 元素，模式匹配成功，region = `""`**。
- `Maxio.Auth.verify_signature/3` 把 `sr.region` 原样拼回 scope 并原样喂给 `derive_signing_key/4`，**全仓无任何 region 校验**（`grep "invalid_region\|region ==" lib/maxio/auth*` 零命中）。

→ **maxio 当前实现应当已经能验证 madmin 的空 region 签名**。这是本设计最重要的正面发现：admin 面不需要任何签名层改动。但它**必须在 RED 阶段用真实 mc 抓包证实**（V-A2），因为这是"签名不匹配"类问题的头号来源。

**(c) `X-Amz-Content-Sha256` 永远是 payload 的 hex SHA256，绝不是 `UNSIGNED-PAYLOAD`**。madmin `newRequest` 无条件 `sum := sha256.Sum256(reqData.content)`。GET `/info` 的 content 为空 → `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`。maxio 的 `payload_mode/1` 会把它归为 `:single`，但因为 `Admin.Plug` 在 `Dispatch` 之前 halt、且 admin GET 不读 body，**不会触发任何 body 哈希校验**。无风险。

**授权：新增 `Maxio.Admin.Authz`，结构对齐 `Maxio.S3.PrometheusAuthz`**（后者只有 49 行，是精确的模板）：

```
action   = "admin:ServerInfo"（每端点一个，见 §9 表）
resource = "arn:aws:s3:::*"
ctx      = %RequestContext{principal:, authenticated?:, owner?: root?(principal),
                           action:, resource:, conditions: Authz.conditions_for(conn, authenticated?)}
Evaluator.evaluate(ctx, Store.principal_policies(principal))
  :allow → 再过 Authz.session_policy_allows?/4（STS session policy boundary）
  {:deny, reason} → 403
```

**为什么这能直接工作**：
- `Maxio.Policy.Evaluator.evaluate/2` 对 action 字符串是**完全通用的**，`Statement.action_match?/2` 不区分 `s3:` 与 `admin:` 前缀。
- `Maxio.Policy.Statement` **已经**为 admin action 开了限定性兼容口子（`statement.ex:281-307` 的 `maybe_default_admin_resource/1`）：当 identity statement 的 `Action` **全部**是 `admin:*` 且缺 `Resource` 时补 `Resource: "*"`。这正是 MinIO 官方最小 admin policy 的形态（`{"Effect":"Allow","Action":"admin:ServerInfo"}`）。这个口子是为 `admin:Prometheus` 开的，`admin:ServerInfo` 等直接受益，**无需改 policy 层一行**。
- **identity policy only**：bucket policy 与 ACL 不能授予集群级 admin 动作，与 `PrometheusAuthz` 的 moduledoc 立场一致。
- **root 短路**：`root?(%{type: :root})` → `owner?: true` → Evaluator Step 2 放行；显式 Deny 仍优先（Step 1）。

**admin action 名（已从 `minio/pkg` 的 `policy/admin-action.go` 实锤）**：`admin:ServerInfo`、`admin:Heal`、`admin:StorageInfo`、`admin:DataUsageInfo`、`admin:Prometheus`（已用）、`admin:ConfigUpdate`、`admin:CreateUser`、`admin:DeleteUser`、`admin:ListUsers`、`admin:GetUser`、`admin:EnableUser`、`admin:DisableUser`、`admin:CreatePolicy`、`admin:DeletePolicy`、`admin:GetPolicy`、`admin:AttachUserOrGroupPolicy`、`admin:ListUserPolicies`、`admin:AddUserToGroup`、`admin:RemoveUserFromGroup`、`admin:GetGroup`、`admin:ListGroups`、`admin:SetBucketQuota`、`admin:GetBucketQuota`、`admin:ServerTrace`、`admin:ConsoleLog`、`admin:TopLocksInfo`、`admin:ForceUnlock`、`admin:SetTier`、`admin:ListTier`、`admin:*`。

> **VERIFY-AT-IMPL V-A3**：**读**配置（`GET /minio/admin/v3/config`、`/get-config-kv`）用的是哪个 action。已实锤的常量表里只有 `ConfigUpdateAdminAction = "admin:ConfigUpdate"`，没有独立的读 action。**在核实前一律使用 `admin:ConfigUpdate`，绝不自造 action 名**（§D4 已按此收敛）。

### D10 —— 响应格式：**明文 JSON**；本批**不做** madmin 加密封装

已实锤的加密边界：

| 端点 | 封装 |
|---|---|
| `/minio/admin/v3/info` | **明文 JSON**（`json.NewDecoder(resp.Body).Decode(&InfoMessage)`，不经 `DecryptData`） |
| `/minio/admin/v3/healthinfo` | 明文 JSON 流 |
| `/minio/admin/v3/config`（GET/PUT） | **`DecryptData` / `EncryptData`**（Argon2id KDF，password = secret key） |
| `/minio/admin/v3/get-config-kv` / `set-config-kv` / `del-config-kv` | **加密** |
| `/minio/admin/v3/inspect-data` | 自有加密格式（可选公钥） |

**裁决**：第一批**只做明文 JSON 端点**。理由：
1. `mc admin info` 走的正是明文路径，第一批目标（`mc admin info` 跑通）不需要加密。
2. 加密封装需要在 Elixir 侧实现 **Argon2id KDF + MinIO 特定的 salt/nonce 布局**，属于密码学互操作，必须用官方测试向量逐字节验证 —— 那是一个独立批次的工作量，混进骨架批次会同时拖慢两件事。
3. 这直接决定了 **`mc admin config get/set` 不在第一批**（它依赖加密封装），而第一部分的 config store 在第一批只经 **CLI + Console** 暴露。config store 与 admin config 端点的解耦是有意为之：store 先落地、线格式后接。

> **VERIFY-AT-IMPL V-A4**：`/storageinfo`、`/datausageinfo`、`/list-users`、`/heal` 是否也全是明文。调研只对 `/info`、`/healthinfo` 做了实锤，其余为推断。第二/三批开工前必须逐个读 madmin 源码或抓包确认 —— **不确定就不能声称支持**。

### D11 —— 错误契约：**复用 `Maxio.S3.Error` 结构体，新增 JSON view**，不新建错误体系

这是本设计里最漂亮的一处契合，因为它来自 MinIO 自己的实现事实：MinIO 的 admin 错误响应用的是**同一个 `APIErrorResponse` struct**，只是换成 JSON 编码器：

```go
func writeErrorResponseJSON(...) {
    errorResponse := getAPIErrorResponse(ctx, err, reqURL.Path, requestID, hostID)
    writeResponse(w, err.HTTPStatusCode, encodeResponseJSON(errorResponse), mimeJSON)
}

type APIErrorResponse struct {
    XMLName xml.Name `xml:"Error" json:"-"`
    Code, Message, Resource string
    RequestID string `xml:"RequestId" json:"RequestId"`
    HostID    string `xml:"HostId"    json:"HostId"`
    Key, BucketName, Region string  // omitempty
}
```

线格式：
```json
{"Code":"AccessDenied","Message":"...","Resource":"/minio/admin/v3/info","RequestId":"...","HostId":""}
```

**裁决**：
- **`Maxio.S3.Error` 结构体不动**（`code / message / http_status / resource / request_id / extra`）—— 它的字段与 MinIO 的 `APIErrorResponse` 是一一对应的。
- 新增 `Maxio.Admin.ErrorView.render/1 :: {status, json_iodata}`，与既有 `Maxio.S3.ErrorView.render/1`（XML）平行。
- `Maxio.S3.Error` 的 `@table` 需**追加** admin 专用码（如 `XMinioAdminNoSuchUser`、`XMinioAdminConfigNotFound`）；已有的 `access_denied` / `invalid_argument` / `internal_error` / `not_implemented` 直接复用。注意表里**已经有一个 admin 码先例**：`bucket_quota_exceeded → {"XMinioAdminBucketQuotaExceeded", 400, ...}`。
- `Maxio.Admin.Plug` 的 `try/rescue` 结构对齐 `Maxio.S3.Plugs.Dispatch.do_call/1`：`rescue err in Maxio.S3.Error → JSON view`；`rescue other → Log.error 完整 message（仅服务端）+ 客户端只见通用 InternalError`（**内部路径/密钥绝不外泄**，这条纪律必须逐字继承）。

**契合铁律 1**：一个错误契约，两个 view（XML for S3、JSON for admin）。上层 handler 只 raise `Maxio.S3.Error`，对线格式无感。

---

## 9. 第一批（MVP）范围

**判据**：让 `mc alias set` + `mc admin info` 真正跑通。

### 9.1 关键发现：`mc alias set` **根本不碰 admin API**

调研读了 `mc/cmd/alias-set.go` 的完整流程，结论与直觉相反：

```
mainAliasSet
  → promptTrustSelfSignedCert（仅 https + TTY + 非 --json 时；http 完全不触发）
  → BuildS3Config
      → 若显式 --api s3v4 → 直接返回，零请求
      → 否则 probeS3Signature：
          probeBucketName = "probe-bsign-" + randString(60)
          s3Client.Stat()  →  minio-go BucketExists  →  HEAD /<probe-bucket>
          （因 mc 默认 Region == ""，minio-go 会先发 GET /<probe-bucket>/?location=）
          期望：BucketDoesNotExist 或 AccessDenied → 判定签名版本可用
  → setAlias（纯本地写配置文件）
```

即：**`mc alias set` 只需要 `GET /<bucket>?location=` 与 `HEAD /<不存在的桶>` 返回 404 `NoSuchBucket`（或 403 `AccessDenied`）**。这两个 maxio **都已实现**（`Dispatcher` 的 `get_bucket_location` 与 `head_bucket`）。

**推论（必须在 RED 阶段第一件事验证）**：`mc alias set` 很可能**当前就已经能成功**。RED 的第一个测试应当是"用真实 mc 对 maxio 跑 `mc alias set`"，结果无非两种：
- 通过 → 第一批范围收窄，把精力全放在 `mc admin info` 上；
- 失败 → 拿到真实失败证据（抓包 + `mix maxio.sigv4.debug`），那才是真正要修的东西。

**绝不能**在没有这个证据的情况下先假设 `alias set` 需要 admin 端点而去实现一堆东西。

### 9.2 第一批端点表

| # | 状态 | 路径 | 方法 | 鉴权 | 授权 action | 响应 | 必要性 |
|---|---|---|---|---|---|---|---|
| 1 | ✅ 已实现 | `/minio/health/live` | GET, HEAD | **无** | —— | 200，**空 body** | 运维基线；k8s liveness |
| 2 | ✅ 已实现（语义已改，见下） | `/minio/health/ready` | GET, HEAD | **无** | —— | 200，空 body | k8s readiness |
| 3 | ❌ 本批不做（见下） | `/minio/health/cluster` | GET, HEAD | **无** | —— | —— | madmin `Healthy()` 用 |
| 4 | ❌ 本批不做（见下） | `/minio/health/cluster/read` | GET, HEAD | **无** | —— | —— | —— |
| 5 | ❌ 本批不做 | `/minio/admin/v3/info` | GET | SigV4 | `admin:ServerInfo` | 200 明文 JSON `InfoMessage` | 落到 #7 的 501 |
| 6 | ⚠️ 落 501 而非 426（见下） | `/minio/admin/v4/*` | any | SigV4 | —— | **501 JSON** `NotImplemented` | —— |
| 7 | ✅ 已实现 | `/minio/admin/*`（全部路径） | any | SigV4 | —— | **501 JSON** `NotImplemented`；匿名 403 JSON | 绝不 404 假装路径不存在 |

> 上表的"状态"列与下面三条裁定是**实现批次回写**（2026-08-18，骨架批次）。设计与实现出现分歧时，
> 以本节为准，下一批不要再从原始设计文字重新论证一遍。

**#2 `ready` 的语义改为与 `live` 一致（不探 Repo / 存储后端）**。原文要求"须真实反映 Repo + 存储后端可达性"，实现刻意不这么做，理由：readiness 决定的是**LB 是否把流量摘掉**。把它绑到 Postgres 可达性上，等于让 DB 的一次抖动**同时**摘除所有节点——把一个局部/共享依赖的故障放大成整集群不可用，而且此时节点其实还能服务任何不碰元数据的请求。MinIO 自己的 readiness 也只探**外部**依赖（KMS、etcd），刻意避开存储检查（`cmd/healthcheck-handler.go`）；maxio 当前两者皆无外部形态（KMS 是本地 provider，Repo 是进程内依赖），故 ready 与 live 同语义。
> **重新开探的触发条件**（写死在 `Maxio.S3.Plugs.MinioHealth` 的 V-H1）：接入**外部** KMS 或外部一致性存储后，`ready` 必须开始探它们并在不可达时返回 5xx，届时须核实 MinIO 的确切状态码与 `X-Minio-Server-Status` 头语义。"Repo 可达性"本身不在触发条件里。

**#3/#4 cluster health 本批不实现**（原文写的是"第一批实现，FS 后端下返回 200 且不发 quorum 头"）。改判理由：这两条端点的**唯一语义**就是回答"写/读 quorum 是否满足"。FS 后端下 maxio 没有 quorum 概念，一个"永远 200"的答复不是"诚实的降级"，而是**用一个恒真的假答案冒充集群健康判定**——运维会据此认为集群写入安全，而它根本没做过判定（铁律 3）。不认领这两条路径的代价是明确的、可见的（madmin `Healthy()` 拿到 S3 的 404/403），比一个静默的假 200 好。EC/分布式后端接入时（`Erasure.Config` 的 `read_quorum` / `write_quorum` + `DriveHealth.probe_topology/1` 已具备）再一并实现，届时 FS 后端应显式返回"不适用"而非 200。

**#6 `/minio/admin/v4/*` 落 501 而非 426**。原文希望用 426 让未来 v4 madmin 自动回落 v3。实测依据：当前 mc 的 madmin **硬编码打 v3**，没有任何客户端会发 v4 请求，因此 426 分支**无法活体验证**——按 AGENTS §4 与铁律 5，不实现无法取证的分支（写了也只是一段没人走过的代码，且它宣称了一种我们没验证过的协商行为）。v4 统一落 #7 的 501 JSON，语义诚实（"这个端点 maxio 没实现"）。等到出现真发 v4 的客户端、能抓到它对 426 的实际反应时再实现，记为 **V-A9**。

### 9.3 明确**不在**第一批

| 项 | 理由 |
|---|---|
| `GetBucketPolicyStatus`（S3 面） | 调研实锤：**`mc anonymous` 走的是纯 S3 `GetBucketPolicy` / `PutBucketPolicy` / `DeleteBucketPolicy`，minio-go v7 根本没有 `GetBucketPolicyStatus` 方法**，mc 不会调它。它的真正调用方是 aws-cli `get-bucket-policy-status` 与 Console。它是一个**独立的 S3 数据面特性**（`?policyStatus` 子资源 + XML view + `s3:GetBucketPolicyStatus` action），与 admin 骨架无依赖关系。**并入本批会让批次不 coherent**（`AGENTS.md` §5.3 要求批次内聚）。建议作为独立的小批次 **B-LATER-2**。 |
| `mc admin config get/set` | 依赖 madmin 加密封装（D10）。config store 本批只经 CLI/Console 暴露。 |
| `mc admin user/policy/group *` | 见 §10 第二批 |
| `mc admin heal / trace / console` | 见 §10 第三批 |
| Tiers / Site Replication / Batch Jobs | 依赖 config store 落地后才有意义，且各自是完整子系统 |
| madmin 加密封装（Argon2id） | 独立密码学互操作批次，需官方测试向量 |

---

## 10. `ServerInfo` 响应体：字段 → maxio 数据源

madmin `InfoMessage`（v4 verbatim，v3 为其子集）的字段与 maxio 数据源的逐项映射。**分类原则：有真实数据源就用真实值；没有对应概念就 omit（依赖 `omitempty`），绝不填造出来的值。**

### 10.1 顶层字段

| 字段 | maxio 数据源 | 诚实性裁决 |
|---|---|---|
| `mode` | `Maxio.Ops.ClusterHealthConsole.load/1` 的 `:status`（`"ok"/"attention"/"blocked"/"empty"`） | **映射而非伪造**：只有 `:status == "ok"` 才输出 `"online"`；其余输出真实降级态。V-A6：需核实 MinIO `mode` 的合法取值集合 |
| `domain` | `Application.fetch_env!(:maxio, :s3)[:domain]`（`AddressStyle` 的私有 `domain/0` 需提升为公开或由 `Maxio.Config.get(:s3, :domain)` 取） | 真实 |
| `region` | `Application.fetch_env!(:maxio, :s3)[:region]` | 真实 |
| `sqsARN` | maxio 有 bucket notification（`bucket_configs.notification`）但**没有 MinIO 式的全局 SQS ARN 注册表** | **omit** |
| `deploymentID` | **新建**：首次启动时生成 UUIDv4，持久化进 config store（`{:cluster, :deployment_id}`，`apply: :restart`） | 真实（这是 config store 在第一批的**第一个真实消费者**，也是把两部分绑在一起的理由） |
| `objectNamingMode` | maxio 无此概念 | **omit** |
| `buckets.count` | `Maxio.S3.Prometheus.usage_stats/1` → `:bucket_count` | 真实 |
| `objects.count` | 同上 → `:object_count`（`is_latest AND NOT is_delete_marker`） | 真实 |
| `versions.count` | 同上 → `:version_count` | 真实 |
| `deletemarkers.count` | 同上 → `:delete_marker_count` | 真实 |
| `usage.size` | 同上 → `:total_bytes` | 真实（**逻辑字节**，非物理占用；须在文档与 README 明示口径，与 quota/Prometheus 口径一致） |
| `services` | KMS：`config :maxio, :kms`；Notifications：`:notification_delivery_scheduler`；**LDAP：maxio 无** | 只填有的，LDAP **omit** |
| `backend` | 见 §10.2 | |
| `servers[]` | 见 §10.3 | |
| `pools` | `Maxio.Cluster.Topology.pool_ids/0` + `set_ids_for_pool/1`；FS 后端下无拓扑 | 有拓扑才填，否则 **omit** |

> ⚠️ **性能注意**：`Prometheus.usage_stats/1` 每次调用都是一次**全表 group-by 扫描** `objects`，无缓存。`mc admin info` 若被监控系统高频轮询会打爆 DB。**裁决**：ServerInfo 的 usage 部分必须走短 TTL 缓存（建议 `:persistent_term` + 30s TTL，或复用 `Maxio.Cluster.Scrubber.Usage` 的 `:persistent_term` 缓存），并在响应中**诚实反映数据新鲜度**。madmin 的 `no-cache=true` query 参数正是为此存在 —— 收到它时绕过缓存直查。

### 10.2 `backend`（`ErasureBackend`）

| 字段 | 数据源 | 裁决 |
|---|---|---|
| `backendType` | `Maxio.Storage.backend/0`：`Maxio.Storage.FS → "FS"`；`ErasureCoded` / `Distributed → "Erasure"` | 真实映射 |
| `onlineDisks` / `offlineDisks` | `Maxio.Cluster.DriveHealth.probe_topology/1` → `%{online, suspect, offline, ...}`。**注意 maxio 是三态**（多一个 `:suspect`） | `online` 只计 `:online`；`:suspect` **计入 offline**（保守，不夸大健康度）。FS 后端无拓扑 → `onlineDisks: 1, offlineDisks: 0`（本机数据目录本身，真实） |
| `standardSCParity` | `Maxio.Storage.Erasure.Config.load!/1` 的 `:parity_shards`，或 `Topology.ec_params/0` | 真实；FS 后端 **omit**（FS 无 parity 概念，填 0 会被读成"零冗余"，虽然事实如此但语义上是 EC 字段） |
| `rrSCParity` | maxio **没有 REDUCED_REDUNDANCY 存储类的独立 parity** | **omit。明确拒绝"回填 = standardSCParity"的做法** —— 那等于宣称存在一个 maxio 根本没实现的存储类分级，是伪造能力。 |
| `totalSets` / `totalDrivesPerSet` | `Topology.all_set_ids/0` / `endpoints/1` | 有拓扑才填 |

### 10.3 `servers[]`（`ServerProperties`）

**总裁决：第一批只输出一个条目 —— 本节点。**

理由：maxio **没有 per-node HTTP endpoint 注册表**。`Maxio.Cluster.nodes/0` 返回的是 BEAM 节点名（`maxio@host`），`Topology.endpoints/1` 返回的是 `{node, drive_path}` —— **两者都不是 `host:port` URL**。为多节点编造 endpoint URL 就是伪造。

| 字段 | 数据源 | 裁决 |
|---|---|---|
| `state` | 本节点恒 `"online"`（能响应这个请求本身就是证据） | 真实 |
| `endpoint` | `config :maxio, Maxio.S3.Endpoint` 的 `port` + 请求的 `conn.host` | 真实（本节点的实际监听点） |
| `scheme` | `conn.scheme` | 真实 |
| `uptime` | **新建**：`Maxio.Application.start/2` 里记 `System.monotonic_time(:second)` 进 `:persistent_term`；ServerInfo 取差值 | 真实（一行改动，值得做） |
| `version` | `Application.spec(:maxio, :vsn)`（`mix.exs` 的 `"0.1.0"`） | 真实。**绝不冒充 MinIO 的 `RELEASE.xxx` 版本串** |
| `commitID` | maxio 无 git sha 注入 | **omit**。可选后续：build 期注入真实 sha 再填 |
| `network` | `Maxio.Cluster.nodes/0` + `alive?/1` 合成 BEAM 层视图 | 真实但**语义不同**（BEAM mesh，非 HTTP peer）。裁决：**omit**，避免让运维以为是 HTTP 探活。V-A7：确认 mc 是否依赖此字段 |
| `drives[]` | 见 §10.4 | |
| `poolNumber` / `poolNumbers` | `Topology.pool_id_for_set/1` 反查本节点所属 pool | 有拓扑才填 |
| `mem_stats` | `:erlang.memory/0` | 真实但**是 BEAM 内存不是 Go 内存**。裁决：填真实 BEAM 值，字段语义在 README 注明 |
| `go_max_procs` | maxio 无 Go 运行时 | **omit** |
| `num_cpu` | `:erlang.system_info(:logical_processors)` | 真实 |
| `runtime_version` | `"Elixir #{System.version()} / OTP #{System.otp_release()}"` | 真实。**不伪装成 `go1.x`** |
| `minio_env_vars` / `minio_env_hash` | maxio 无 MinIO env 体系 | **omit** |
| `edition` | maxio 不是 MinIO 的任何 edition | **omit**（V-A8：确认 mc 在 `edition` 缺失时的渲染行为；`Edition` 没有 `omitempty`，可能必须发空串） |
| `license` | 无 | **omit** |
| `is_leader` / `leaders` | maxio 无 leader 选举 | **omit** |
| `ilm_expiry_in_progress` | `Maxio.Lifecycle.Scheduler` 是否在跑 | 可填真实值，或 omit |
| `host` / `pid` / `cmd_line` / `username` | `:os.getpid/0` 等 | 低价值，**第一批 omit** |
| `api_version` / `restarting_since` | v4 新增 | v3 不需要 |

### 10.4 `drives[]`（`Disk`）

| 字段 | 数据源 | 裁决 |
|---|---|---|
| `endpoint` / `path` | 有拓扑：`Topology.endpoints/1` / `local_drives_for_set/1`；FS：`config :maxio, :s3, :data_dir` | 真实 |
| `state` | `Maxio.Cluster.DriveHealth.status/1` 的 `:status`（三态） | `:online → "ok"`；`:offline → "offline"`；`:suspect → ` V-A9（需确认 MinIO 的合法 state 串，**不确定就用 `"offline"` 保守值**，绝不把可疑盘报成 ok） |
| `uuid` | `Maxio.Cluster.DriveIdentity.status/1` 的 `drive_uuid` | 真实 |
| `totalspace` / `usedspace` / `availspace` | `Maxio.Cluster.DriveStats.sample_endpoint/2` / `sample_local_drive/2` → `capacity_bytes` / `used_bytes` / `free_bytes` | 真实（os_mon disksup） |
| `healing` / `healing_queued` | `DriveHealth.heal_required?/1` | 真实 |
| `scanning` | `Maxio.Cluster.Scrubber` 是否在扫该盘 | 可填，或 omit |
| `model` | `Maxio.Cluster.DriveHardwareEvidence` 的 `:model`（默认 provider 为 nil） | 有 provider 才填 |
| `readthroughput` / `writethroughput` / `readlatency` / `writelatency` / `utilization` | `Maxio.Cluster.DriveIO.snapshot/0`（本节点 IO 计数器） | **谨慎**：maxio 的计数器口径与 MinIO 未必一致。V-A10 未核实前 **omit**，绝不用不同口径的数字冒充 |
| `major` / `minor` / `used_inodes` / `free_inodes` | maxio 无 | **omit**（`major`/`minor` 无 omitempty，可能被迫发 0） |
| `pool_index` / `set_index` / `disk_index` | `Topology` | 有拓扑才填 |
| `local` | 恒 `true`（第一批只报本节点） | 真实 |

**FS 后端的合成单盘视图**：`Topology.configured?/0` 为 false 时（默认配置），`probe_topology/1` 与 `sample_topology/1` 返回全零/空。此时 ServerInfo 必须走 `DriveStats.sample_local_drive/2` + `config :maxio, :s3, :data_dir`，合成**一个** drive 条目。这不是伪造 —— 那确实就是 maxio 在 FS 模式下唯一的真实存储位置。`Maxio.Storage.FS` 的 moduledoc 已记载 Scanner 用过同样的"合成单端点 topology"手法，本设计复用它。

### 10.5 诚实性纪律（写进模块 moduledoc + README）

对齐 README 既有立场（"不伪造未实现的 MinIO 指标族"、"绝不伪造数据"）：

1. **能 omit 的字段一律 omit，绝不填 0/空串冒充"已测量"**。`0` 与"没有这个概念"在监控里是两个完全不同的信号。
2. **口径不同的数字绝不复用字段名**（如 IO 吞吐、`usage.size` 的逻辑 vs 物理字节）。口径必须在 README 与 moduledoc 里写清楚。
3. **无 `omitempty` 的字段**（`major`/`minor`/`pool_index`/`is_leader`/`edition`/`mem_stats`/`api_version`）无法省略，被迫发零值。这些**必须在 README 单列一节**说明"这些字段的零值代表 maxio 无此概念，不代表测得为零"。
4. ServerInfo 响应本身应带一个 maxio 专有的诚实性标记（如 `servers[].minio_env_vars` 之外的自定义键，或独立文档），**但绝不能破坏 madmin 的 JSON 解码**（Go 的 `json.Decode` 忽略未知字段，所以加自定义键是安全的）。V-A11 需实测确认。

---

## 11. 分批计划

### 第一批（本设计的实施范围）

**A. config store 地基**
- 迁移 `runtime_configs` + `runtime_config_audits`（含全部中文 COMMENT）
- `Maxio.Config`（门面，含 `get/2,3`、`fetch!/2`、`get_all/1`、`source/2`）
- `Maxio.Config.Schema`（白名单 + 类型 + apply 模式 + 禁止清单）
- `Maxio.Config.Store`（GenServer：物化 `:persistent_term`、订阅 `Cluster.Notify`、周期版本对账）
- `Cluster.Notify` 新增 `{:config_changed, subsystem, key}`；`CacheInvalidator` 新增 handler
- 6 个 `mix maxio.config.*` CLI
- **第一个真实消费者**：`{:cluster, :deployment_id}`（首启生成 UUID）
- 白名单第一批只放**少量低风险键**：`:cluster/:deployment_id`、`:prometheus_metrics/:public`、`:listing/:sql_hard_limit`、`:s3/:clock_skew_ms`。其余键**先不接线**（门面 fallback 到 `Application.get_env`，行为零变化）

**B. Admin 骨架**
- `Maxio.S3.Plugs.MinioHealth`（4 个 health 端点，SigV4 之前）
- `Maxio.Admin.Plug`（路径路由 + `Admin.Authz` + `try/rescue` → JSON 错误）
- `Maxio.Admin.Authz`（对齐 `PrometheusAuthz`，49 行量级）
- `Maxio.Admin.ErrorView`（JSON view，复用 `Maxio.S3.Error`）
- `Maxio.Admin.ServerInfo`（聚合 + 短 TTL 缓存 + `no-cache` 绕过）
- `Maxio.Application` 记录 `started_at`
- `Maxio.Buckets` 保留 `minio` 桶名 + 既有同名桶的启动期告警
- `/minio/admin/v4/*` → 426；未实现 `/minio/admin/v3/*` → 501 JSON
- CLI：`mix maxio.admin.info [--json]`（本地复算 ServerInfo，不经 HTTP —— 用于在 mc 失败时区分"数据源坏了"还是"线格式坏了"）

**依赖关系**：B 依赖 A 仅在 `deployment_id` 一点上。若要进一步解耦，`deployment_id` 可先落 `cluster_topology_revisions` 之外的独立单例表 —— 但那会造成两套配置持久化机制，**不推荐**。保持 A → B 的串行依赖。

### 第二批：user / policy 适配层（`mc admin user *` / `mc admin policy *`）

**边界**：纯**适配层**，把 madmin 的 JSON 线格式翻译成对既有 `Maxio.IAM` / `Maxio.Policy.Store` 的调用。**绝不新增 IAM 业务逻辑** —— 35 个 IAM 模块与 118 个 Query action 已经在那里了。

**依赖**：
- 第一批的 `Admin.Plug` / `Admin.Authz` / `Admin.ErrorView`（骨架）
- **madmin 加密封装**？—— V-A4 必须先确认 `/list-users` 等是否明文。若加密，本批的前置就变成"Argon2id 互操作批次"，范围会显著变化。**这是第二批开工前必须消解的最大不确定性。**

**范围**：`admin:ListUsers` / `GetUser` / `CreateUser`(`PUT /v3/add-user`) / `DeleteUser` / `EnableUser` / `DisableUser`、`ListGroups` / `GetGroup` / `AddUserToGroup` / `RemoveUserFromGroup`、`CreatePolicy` / `DeletePolicy` / `GetPolicy` / `ListCannedPolicies` / `AttachUserOrGroupPolicy`。

**已知语义鸿沟（必须在该批设计时解决，不能糊过去）**：MinIO 的 admin user 模型是 **access key = user**（扁平），而 maxio 实现的是 **AWS IAM 模型**（user 与 access key 是两级）。适配层必须明确定义映射规则，且**双向一致**（经 admin API 建的用户要能被 IAM Query API 看到，反之亦然），否则会出现两套互不可见的用户视图 —— 那是最恶劣的静默失败。

### 第三批：heal / trace 适配层

**边界**：把 `Maxio.Storage.Erasure.Heal` / `Maxio.Cluster.*` / 18 个 `mix maxio.rebalance.*` 的既有能力翻译成 madmin 的 heal 线格式。

**依赖与风险**：
- `mc admin heal` 是**长连接流式响应**（持续推送 heal 进度），不是单次 JSON。协议形态与第一批的请求-响应完全不同，需要单独设计（Bandit 的 chunked 响应 + 有界背压）。
- `mc admin trace` / `mc admin console` 是**服务端推流**（每个请求一条 trace 记录）。maxio 有结构化日志（`Maxio.S3.Log`）与 `Maxio.S3.Metrics`，但**没有 per-request trace 的实时订阅通道**。需要新建（`:telemetry` handler → PubSub → 流式响应），这是一个独立子系统，不是适配层。
- **裁决**：第三批应当**再拆**：3a = `mc admin heal`（有既有 heal 引擎，是适配）；3b = `mc admin trace/console`（需新建订阅通道，是新子系统）。

**绝不能做的事**：为了让 `mc admin heal` "有输出"而返回编造的进度。若 heal 引擎在当前后端不适用（FS 后端无 EC 冗余可修），必须返回结构化的 `NotImplemented` / 明确的"该后端不支持"，而不是报告 0 个对象已修复然后成功退出。

---

## 12. VERIFY-AT-IMPL 清单

**规则**：以下每一项在被核实前，实现代码里必须带 `# VERIFY-AT-IMPL V-xx` 注释；核实后把结论写进 STATUS.md。**任何一项未核实就声称"`mc admin info` 支持"，都属于 overclaim。**

### 签名 / 协议层（最高优先级 —— 这些错了什么都跑不通）

| ID | 事项 | 核实方法 |
|---|---|---|
| **V-A2** | madmin 的 credential scope region 段为空串（`20260818//s3/aws4_request`），maxio 是否真能验过 | 真实 `mc admin info` 抓包 + `mix maxio.sigv4.debug` 复算。**源码层面已强推断为通过，但必须活体证实** |
| **V-A12** | `mc alias set` 对 maxio 是否**当前就已成功** | 真实 mc，先跑再说。这决定第一批范围 |
| **V-A13** | madmin v3.0.107 的 `ServerInfo()` 是否同时发 `no-cache` query（v4 确定发，v3 只确认了 `metrics`） | 抓包 |
| **V-A14** | `mc` 实际用的 madmin 版本（不同 mc 版本可能是 v3 或 v4） | `mc --version` + 抓包看请求路径是 `/v3/` 还是 `/v4/` |
| **V-A15** | v4 → v3 的 426 回落端到端行为 | 用 v4 madmin 的 mc 实测 |

### ServerInfo schema

| ID | 事项 | 核实方法 |
|---|---|---|
| **V-A16** | `InfoMessage` 在 **v3.0.107** 的逐字段 json tag（本设计引用的是 v4 verbatim，v3 是子集） | 读 `madmin-go/v3.0.107/info-commands.go` |
| **V-A17** | `Buckets`/`Objects`/`Versions`/`DeleteMarkers`/`Usage`/`Services` 小 struct 的精确 json tag | 同上 |
| **V-A8** | `edition` 等**无 `omitempty`** 的字段缺失时 mc 的渲染行为（是否 panic / 显示异常） | 读 `mc/cmd/admin-info.go` 的 `String()` + 实测 |
| **V-A6** | MinIO `mode` 字段的合法取值集合 | 读 `minio/cmd/admin-handlers.go` |
| **V-A9** | `Disk.state` 的合法取值串（`"ok"` / `"offline"` / 其他） | 读 madmin `Disk` 相关常量 |
| **V-A7** | mc 是否依赖 `servers[].network` 字段渲染 | 读 `String()` |
| **V-A11** | 在 `InfoMessage` JSON 里加 maxio 自定义键是否安全（Go json.Decode 应忽略未知键） | 实测 |
| **V-A10** | maxio `DriveIO` 的吞吐/延迟口径与 MinIO `Disk.readthroughput` 是否可比 | 读双方定义；不可比则 omit |

### Admin API 面

| ID | 事项 | 核实方法 |
|---|---|---|
| **V-A4** | `/storageinfo`、`/datausageinfo`、`/list-users`、`/heal` 是否明文 JSON（调研只对 `/info`、`/healthinfo` 实锤） | 逐个读 madmin 源码。**第二批开工的前置** |
| **V-A3** | 读配置（`GET /v3/config`、`/get-config-kv`）的 admin action 名；核实前一律用 `admin:ConfigUpdate` | 读 `minio/pkg/policy/admin-action.go` + `minio/cmd/admin-handlers-config-kv.go` |
| **V-A18** | admin 错误 JSON 里 `HostId` 的实际取值（MinIO 填什么） | 抓真实 MinIO 的错误响应 |
| **V-A19** | HTTP 状态码 → 具体 error `Code` 的完整兜底映射表（`httpRespToErrorResponse`） | 读 madmin `api-error-response.go` |
| **V-A5** | FS 后端下不发 `X-Minio-Write-Quorum` 头是否会让 madmin `Healthy()` 异常 | 读 `madmin-go/cluster-health.go` + 实测 |
| **V-A1** | 真实 MinIO 是否把 `minio` 整体保留为桶名，还是只保留 `/minio` 路径前缀 | 读 `minio/cmd/utils.go` 的 `isMinioReservedBucket` |

### config store 面

| ID | 事项 | 核实方法 |
|---|---|---|
| **V-C1** | `:persistent_term` 存 per-subsystem 大 term 时，写入触发的全局 GC 代价在 maxio 的实际负载下是否可接受 | 基准测试：高并发 S3 读写下做一次配置变更，测 p99 抖动 |
| **V-C2** | `Phoenix.PubSub` 在 maxio 当前的 libcluster 配置下**是否真能跨节点**送达（`Notify` moduledoc 说 M8 只是本地 transport） | 多节点实测；不达标则启用 §D5 的 `LISTEN/NOTIFY` 升级路径 |
| **V-C3** | PG `LISTEN/NOTIFY` 作为备选传播通道的可行性（Ecto/Postgrex 支持度） | 查 Postgrex 文档 |
| **V-C4** | 12 个 scheduler 中，究竟有几个的 `enabled` 真的只在 `Application.start` 读、tick 内不重读（D6 的准确边界） | 逐个读 §1.4-B 列出的模块 |

---

## 13. 测试策略（RED 阶段）

`CLAUDE.md` 强制"端到端活体取证"。以下按 RED 优先级排序 —— **T0 必须最先跑，它可能直接改变第一批范围**。

### T0（先于任何编码）—— 真实 mc 基线取证

```
mc alias set maxio http://localhost:9900 minioadmin minioadmin
mc ls maxio
mc admin info maxio
```

抓包（`mc --debug` 或代理）记录**每一个** HTTP 请求的完整 method / path / query / 全部签名相关 header。产出物是一份「mc 实际调用了什么」的取证文件，进 `docs/superpowers/` 或 STATUS.md。

**这份取证直接消解 V-A12 / V-A2 / V-A13 / V-A14**，是后续所有设计假设的地基。**在拿到它之前，第一批的端点清单只是推断。**

### T1 —— config store 单元 / 属性测试

| 测试 | 断言 |
|---|---|
| Schema 完备性（**静态断言**） | 白名单里的每个 `{subsystem, key}` 在 `lib/` 中**确实存在读取点**；反向：被门面接线的键必须在白名单里。防 D3 的漂移 |
| 优先级 | runtime > env > compile；`source/2` 报告的来源与实际生效值一致（三层各自单独设值再交叉验证） |
| 禁止清单 | §4 的每个键写入都返回 `{:error, {:forbidden_config_key, _, _}}`。**逐键回归，不抽样** |
| 校验 | 类型错、范围越界、语义违规各自返回对应结构化错误；**绝不落库** |
| 乐观并发 | 两个并发 set 同键，一个成功一个 `:config_version_conflict`；DB 里 version 只 +1 |
| 审计完整性 | 每次 set/reset 恰好一条审计行；敏感键的 old/new 值为脱敏占位符 |
| 启动期严格性 | PG 有白名单外的 orphan 键 → 忽略 + `Log.error`，**不进 persistent_term**；白名单内的值类型不可解码 → `Store.init/1` raise |
| `apply` 诚实性 | `:restart` 类键 set 后，`Application` 层的实际生效值**未改变**，且返回值是 `applied: :restart` |
| 失效传播 | 多节点（`start_supervised!` 起两个 Store）下，广播后两边 persistent_term 一致；**故意丢弃广播**后，周期对账仍能在一个周期内收敛 |

### T2 —— Admin 骨架：自签 SigV4 的 ExUnit 集成测试

必须用**手工构造的、region 段为空**的 credential scope（`20260818//s3/aws4_request`）签名，复现 madmin 的确切行为：

| 测试 | 断言 |
|---|---|
| 空 region 签名 | `GET /minio/admin/v3/info` 带空 region scope + hex payload sha256 → 200 |
| 授权：root | 200 |
| 授权：普通 IAM 用户无 policy | 403 + **JSON** 错误体（`Code == "AccessDenied"`） |
| 授权：identity policy `{"Effect":"Allow","Action":"admin:ServerInfo"}`（**无 Resource**） | 200（验证 `Statement.maybe_default_admin_resource/1` 的口子对新 action 生效） |
| 授权：显式 Deny 优先于 root | 403 |
| 授权：bucket policy 授予 `admin:ServerInfo` | **仍 403**（identity-policy only） |
| 授权：STS session policy boundary | 生效 |
| 匿名 | 403 JSON |
| 错误线格式 | 错误响应是 JSON 且 `content-type: application/json`；字段名 `Code`/`Message`/`Resource`/`RequestId`/`HostId` 逐字对齐 |
| 内部异常 | handler 内 raise 任意异常 → 500 JSON 通用 `InternalError`；**服务端日志有完整 message，客户端响应体不含任何绝对路径/密钥**（继承 `Dispatch` 的纪律，需专门回归） |
| 未实现路径 | `/minio/admin/v3/heal` → **501**，不是 404 |
| v4 路径 | `/minio/admin/v4/info` → **426** |
| health 无鉴权 | `/minio/health/live` 不带任何 header → 200 空 body；GET 与 HEAD 都通 |
| **health 抗鉴权故障** | 带**畸形** `Authorization` 头请求 `/minio/health/live` → **仍 200**（证明 D7 的分层是对的：SigV4 之前拦截） |
| 路径影子化 | 创建桶 `minioxyz` → `GET /minioxyz` 仍走 S3 路径，**不被 admin plug 吞掉**；`CreateBucket("minio")` → `InvalidBucketName` |
| Prometheus 不回归 | `/minio/metrics/v3` 仍按原样工作（新 plug 插入未破坏既有拦截顺序） |

### T3 —— ServerInfo 诚实性回归（**本设计最关键的一类测试**）

| 测试 | 断言 |
|---|---|
| FS 后端（默认配置） | `backendType == "FS"`；`rrSCParity` **键不存在**；`standardSCParity` **键不存在**；`drives` 恰好一条且 `path == :s3.data_dir` |
| EC 后端 | `backendType == "Erasure"`；`standardSCParity == config 的 parity_shards`（真实值比对） |
| omit 纪律（**表驱动**） | 对 §10 中标记 omit 的**每一个**字段断言 JSON 里键不存在。**这是防伪造的主防线，必须逐字段而非抽样** |
| usage 数字真实性 | 造 N 个桶 / M 个对象 / K 字节 → ServerInfo 的 `buckets.count`/`objects.count`/`usage.size` 与 `Prometheus.usage_stats/1` **完全一致**（同一口径，绝不分叉） |
| `deploymentID` | 首启生成；**重启后不变**（持久化生效）；不同部署不同 |
| `uptime` | 单调递增且 > 0 |
| `version` | 等于 `mix.exs` 的版本，**不是** MinIO 风格的 `RELEASE.` 串 |
| drive state 保守性 | `DriveHealth` 报 `:suspect` 时，ServerInfo 的 `state` **不是** `"ok"`，且该盘计入 `offlineDisks` |
| 缓存与 `no-cache` | 默认走缓存（连续两次调用只打一次 DB —— 用 Ecto 的 telemetry/sandbox 计数断言）；`?no-cache=true` 绕过缓存 |

### T4 —— 真实 mc 端到端（`Maxio.Compat.ExternalSmoke` 扩展）

仓库已有 `Maxio.Compat.ExternalSmoke`（`lib/maxio/compat/external_smoke.ex`，已含 `minio_mc` client spec 与 `mc-config` 临时目录）与 `mix maxio.compat.matrix`。**在这里扩展，不另起炉灶**：

新增断言项：
- `"mc alias set 能对 maxio 成功建立 alias"`
- `"mc admin info 返回可解析的 ServerInfo 且 mode/version/buckets 非空"`
- `"mc admin info 显示的 bucket 数与实际建桶数一致"`
- `"curl /minio/health/live 返回 200"`

**这是"验证才算完成"的最终取证**（`CLAUDE.md`）。声称 `mc admin info` 可用之前，必须有这一项的通过记录。

### T5 —— CLI 取证对照

`mix maxio.admin.info --json` 的输出与 HTTP `GET /minio/admin/v3/info` 的响应体**逐字段一致**。

**为什么这个测试重要**：当 mc 报错时，它能立刻区分「数据聚合层坏了」还是「HTTP/签名/线格式层坏了」，把排查空间对半砍。这是 `AGENTS.md` §4.4「CLI + 结构化日志优先」在管控面的具体落实。

---

## 14. 与架构铁律的对照

| 铁律 | 本设计如何契合 |
|---|---|
| **1. 统一数据契约** | 配置读写唯一门面 `Maxio.Config`；错误契约唯一 `Maxio.S3.Error`，XML/JSON 两个 view；ServerInfo 的 usage 与 Prometheus/quota 共用 `usage_stats/1` 同一口径，绝不分叉 |
| **2. 后端即插件** | Admin 面**只读**既有 behaviour 门面（`Maxio.Storage.backend/0`、`DriveHealth`、`Topology`），不新增后端知识、不绕过 behaviour 直接摸盘；config store 明确**禁止**运行时改 behaviour 绑定（§4），保护插件边界的完整性 |
| **3. 明确状态设计 + 绝不静默失败** | 配置写路径 5 类结构化错误；`apply: :restart` 诚实回传（写成功 ≠ 生效）；orphan 键告警不吞；未实现 admin 路径返回 501 而非 404；ServerInfo 缺概念的字段 omit 而非填 0；`:suspect` 盘保守计入 offline；广播不可靠 → 周期版本对账兜底 |
| **4. body 绝不进内存** | Admin 面全是小 JSON 响应，无对象字节；`Admin.Plug` 在 `Dispatch` 前 halt，不触碰 body 流；health 端点响应空 body |
| **5. 行为对齐真实实现** | 全部端点路径/方法/JSON schema/action 名/签名细节均引自 `minio/mc`、`madmin-go`、`minio/minio`、`minio/pkg` 源码并附 URL；无法实锤的一律进 §12 VERIFY-AT-IMPL，**不凭记忆编造** |

## 15. 参考来源

- mc `alias set` 流程：<https://github.com/minio/mc/blob/master/cmd/alias-set.go>、<https://github.com/minio/mc/blob/master/cmd/client-s3.go>
- mc `admin info`：<https://github.com/minio/mc/blob/master/cmd/admin-info.go>
- madmin `ServerInfo` / `InfoMessage`：<https://github.com/minio/madmin-go/blob/main/info-commands.go>
- madmin 签名与 `newRequest`：<https://github.com/minio/madmin-go/blob/main/api.go>
- madmin API 版本与 426 回落：<https://github.com/minio/madmin-go/blob/main/utils.go>
- madmin 错误响应：<https://github.com/minio/madmin-go/blob/main/api-error-response.go>
- madmin 加密封装：<https://github.com/minio/madmin-go/blob/main/encrypt.go>、<https://github.com/minio/madmin-go/blob/main/config-kv-commands.go>
- madmin cluster health：<https://github.com/minio/madmin-go/blob/main/cluster-health.go>
- MinIO health router / handler：<https://github.com/minio/minio/blob/master/cmd/healthcheck-router.go>、<https://github.com/minio/minio/blob/master/cmd/healthcheck-handler.go>
- MinIO admin router / handlers：<https://github.com/minio/minio/blob/master/cmd/admin-router.go>、<https://github.com/minio/minio/blob/master/cmd/admin-handlers.go>
- MinIO 错误响应 struct：<https://github.com/minio/minio/blob/master/cmd/api-response.go>、<https://github.com/minio/minio/blob/master/cmd/api-errors.go>
- MinIO SigV4 region 宽松校验：<https://github.com/minio/minio/blob/master/cmd/signature-v4-parser.go>
- admin action 常量：<https://github.com/minio/pkg/blob/main/policy/admin-action.go>
- minio-go 签名 service 常量：<https://github.com/minio/minio-go/blob/master/pkg/signer/request-signature-v4.go>
- minio-go bucket policy（`mc anonymous` 依赖）：<https://github.com/minio/minio-go/blob/master/api-bucket-policy.go>
- MinIO `GetBucketPolicyStatus` 路由：<https://github.com/minio/minio/blob/master/cmd/api-router.go>

