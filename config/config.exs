# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :maxio,
  ecto_repos: [Maxio.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :maxio, MaxioWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MaxioWeb.ErrorHTML, json: MaxioWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Maxio.PubSub,
  live_view: [signing_salt: "DCOzLD0u"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  maxio: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  maxio: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :bucket,
    :key,
    :version_id,
    :action,
    :required_action,
    :method,
    :auth_type,
    :payload_mode,
    :reason,
    :code,
    :status,
    :size,
    :expires,
    :resource,
    :decision,
    :policy_source,
    :principal_type,
    :endpoint_source,
    :principal_arn,
    :target_principal_arn,
    :user_name,
    :user_arn,
    :access_key_id,
    :account_id,
    :owner,
    :authenticated,
    :provider_arn,
    :issuer_url,
    :issuer_host_path,
    :mfa_serial_hash,
    :mfa_device_status,
    :mfa_outcome,
    :mfa_reason,
    :mfa_window_offset,
    :event_name,
    :write_authority,
    :matched_tasks,
    :destination_bucket,
    :replication_status,
    :destination_type,
    :destination_arn,
    :configuration_id,
    :notification_event_id,
    :attempts,
    # ObjectMutation 协议 §7 固定字段（B7 日志收口，B5 审查项 1）：Log 模块只放行白名单键，
    # formatter 侧必须同步放行，否则结构化字段被静默丢弃（action/request_id/bucket/key/
    # version_id/reason 已在上方白名单）。绝不放行对象 body / 密钥 / SSE envelope 类键。
    :mutation_id,
    :mutation_generation,
    :mutation_operation,
    :mutation_phase,
    :authority_mode,
    :backend,
    :placement_set_id,
    :outcome
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# 在 Windows 非管理员环境下，LiveView 的 ColocatedJS 无法创建 node_modules 符号链接（:eperm），
# maxio 不使用 colocated hooks/js，关闭该警告以保证 `compile --warnings-as-errors` 干净。
config :phoenix_live_view, :colocated_js, disable_symlink_warning: true

# ── maxio S3 子系统配置（独立于 Console 的 MaxioWeb.Endpoint）──
# 寻址根域名（virtual-host 判定基准）、默认区域、对象数据目录、时钟偏移容忍、root 凭据引导。
config :maxio, :s3,
  domain: "localhost",
  website_domain: "s3-website.localhost",
  region: "us-east-1",
  clock_skew_ms: 900_000,
  data_dir: Path.expand("../priv/s3_data", __DIR__),
  root_user: "minioadmin",
  root_password: "minioadmin"

# Local single-account identity used by STS GetCallerIdentity. Full multi-account
# IAM/account-id semantics remain a later IAM expansion.
config :maxio, :sts, account_id: "000000000000"

# 独立 S3 Endpoint（Bandit child）监听配置。
# prod/默认 9000（对齐 MinIO）；dev 因 Windows 9000–9099 保留段改用 9900（见 dev.exs）；
# 可经 MAXIO_S3_PORT 运行时覆盖（runtime.exs）。
config :maxio, Maxio.S3.Endpoint, port: 9000, ip: :any

# SSE-S3 服务端主密钥（信封加密包裹每对象 DEK）。dev/test 用固定 base64 32B；
# prod 经 MAXIO_SSE_MASTER_KEY env（runtime.exs）。单一静态主密钥=简化密钥管理 MVP（无轮转/HSM）。
config :maxio, :sse, master_key: "bWF4aW8tc3NlLXMzLW1hc3Rlci1rZXktMzJieXRlcyE="

# SSE-KMS 本地 provider 默认配置。dev/test 可回退使用 SSE master key；
# prod runtime.exs 强制要求 MAXIO_KMS_MASTER_KEY，避免使用仓库默认开发密钥。
config :maxio, :kms, provider: Maxio.KMS.LocalProvider, default_key_id: "alias/maxio/default"

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

# 后端 behaviour 绑定（铁律 1/2：换后端只改这里）。默认 FS（单机）。
# 切单机纠删码：Maxio.Storage.ErasureCoded（+ config :maxio, :erasure）。
# 切多节点分布式：Maxio.Storage.Distributed（+ config :maxio, Maxio.Cluster.Topology + Maxio.Cluster）。
config :maxio, :storage_backend, Maxio.Storage.FS
config :maxio, :credential_store, Maxio.Auth.CredentialStore.EctoStore
config :maxio, :policy_store, Maxio.Policy.Store.EctoStore
config :maxio, :mfa_delete_verifier, Maxio.IAM.MFADeleteVerifier

# Local operator/IAM secret envelope keys. Dev/test uses fixed 32B keys;
# production must provide runtime secrets so encrypted seeds and credential
# envelopes are not recoverable from repository defaults.
if config_env() in [:dev, :test] do
  config :maxio, :mfa, secret_key: "bWF4aW8tbWZhLWRlbGV0ZS1tYXN0ZXIta2V5LTMyYiE="

  # Wraps long-term access-key and STS session signing secrets.
  config :maxio, :access_key_secret,
    current_key_id: "local-default",
    secret_key: "bWF4aW8tYWNjZXNzLWtleS1zZWNyZXQta2V5LTMyYiE="
end

# IAM OIDC provider JWKS refresh. Disabled by default; even when enabled,
# scheduled writes require `confirm_refresh: true`. Without confirmation, the
# scheduler validates remote discovery/JWKS as a dry-run and leaves the last
# known good DB snapshot untouched. STS WebIdentity request handling never
# performs network refreshes.
config :maxio, :iam_oidc_provider_jwks_refresh,
  enabled: false,
  confirm_refresh: false,
  refresh_after_seconds: 86_400,
  interval_ms: 3_600_000,
  initial_delay_ms: 60_000,
  limit: 100,
  run_opts: []

# IAM signing-secret key rotation. Disabled by default; even when enabled,
# scheduled writes require `confirm_rotation: true` so operators can first run
# the same path as a dry-run and inspect structured logs.
config :maxio, :iam_signing_secret_rotation,
  enabled: false,
  confirm_rotation: false,
  rewrap: true,
  rotate_after_seconds: 86_400 * 90,
  interval_ms: 3_600_000,
  initial_delay_ms: 60_000

# M7 分片传输实现（prod = :erpc 到每节点 ShardServer；test 经 opts[:transport] 覆盖为 InProcess）。
config :maxio, :shard_transport, Maxio.Cluster.Transport.Erpc

# Deployment topology source. The default reads `config :maxio, Maxio.Cluster.Topology`.
# Operators may switch to :db after persisting a validated active topology revision.
config :maxio, :topology_source, :config

# ROUTE B B1-2 耐久性：写路径 temp-then-rename 提交时是否 fsync（part.0 文件 + final 目录）。
# 默认 true（prod 掉电不丢已确认写；fsync-before-quorum 让 write_quorum 不是耐久谎言）；
# test 关闭以提速（见 test.exs）。可经此 flag 整体回退 fsync。
config :maxio, :durability, fsync: true

# ROUTE B B1-3 列举 SQL 临时硬 LIMIT 闸：PG 权威期三处 LIST（list_objects_v2 / list_object_versions /
# list_uploads）无界 Repo.all 大桶 = DoS。每次 SQL 取数行数封顶 sql_hard_limit（默认 100_000），
# 实际取 min(sql_hard_limit, max_keys*4+1000)。B3 drive-walk 上线后 PG 仅作快路径，此闸保留为 DoS 兜底。
config :maxio, :listing, sql_hard_limit: 100_000

# ROUTE B 元数据权威来源（读/列/写分别可切；P2 引入 :read，P3 引入 :list，B4-2 引入 :write；
# 默认全 :pg = 今天行为，shadow 比对不翻权威）。
# P4 把 :read / :list 切 :sidecar 即翻转读 / 列权威（届时 reconcile / drive-walk quorum 错误成 5xx）；
# B4-2 把 :write 切 :sidecar 即把 PG 写降为 best-effort 索引（sidecar 达 write_quorum = 权威已耐久落盘，
# PG 故障非致命：记 Log.error + 不回滚字节 + 请求仍成功，去 PG 写路径 SPOF）。
config :maxio, :authoritative_source, read: :pg, list: :pg, write: :pg

# ROUTE B B5-2 派生索引周期 reconcile scanner（默认关——先发布不改行为，可整体回滚）：
# enabled: true 时 Maxio.Storage.Scanner 每 interval_ms 跑一轮「盘上 sidecar 权威 → PG 派生索引」
# reconcile（缺行 upsert / stale 修正）+ 保守 reverse-GC（PG 孤儿行仅在所有端点可达且全部显式
# missing 时删除，任一端点 down → skip 绝不猜）+ orphan shard 取证（part.0 无 sidecar、
# delete-marker 残留 part.0 计数/日志）。orphan byte 清理默认关闭；显式 CLI/opts 开启后仍要求
# sidecar 写权威、全端点可达、对象锁、二次探针与年龄门，且只删除 part.0。batch_size 限定每批
# reconcile 工作量（铁律 4 有界）。手动触发/取证：
# mix maxio.reconcile_index [--dry-run] [--bucket <name>] [--cleanup-orphan-shards]。
config :maxio, :scanner,
  enabled: false,
  interval_ms: 86_400_000,
  batch_size: 500,
  orphan_cleanup_min_age_ms: 172_800_000,
  orphan_cleanup_max_deletes: 100

# MinIO-style Prometheus scrape endpoint on the S3 API port.
# By default it requires a MinIO-style bearer token whose principal identity
# policy allows admin:Prometheus. Set `public: true` only behind a trusted
# network/proxy.
config :maxio, :prometheus_metrics, public: false

# M8 drive health registry: node-local, observational drive status based on
# structured list_dir probes. The 48h window matches the fresh-drive-heal policy
# for drives that were offline while their erasure set remained writable.
config :maxio, :drive_health,
  enabled: true,
  offline_after_ms: 172_800_000

# M8 drive software identity marker. The marker lives inside each configured
# drive root and lets drive-health detect same-path replacement before healing.
config :maxio, :drive_identity,
  enabled: true,
  marker_file: ".maxio-drive-identity.json",
  create_missing: true

# M8 drive filesystem stats telemetry. The default provider uses OTP os_mon
# disksup and remains read-only. Tests may inject `provider: fun/1`.
config :maxio, :drive_stats, provider: nil

# M8 drive hardware evidence telemetry. Read-only; hashes raw serial/WWID by
# default and never gates healing, quorum, placement, or physical deletion.
config :maxio, :drive_hardware_evidence, provider: nil

# M8 pool-level write placement. Default :hash preserves the stable M7 object
# hash route. Operators may opt into :weighted_free_space for MinIO-style
# server-pool expansion behavior: choose a healthy pool weighted by free bytes,
# then hash within that pool's set list. Existing object reads still use
# persisted placement; this does not migrate old data or mutate topology.
config :maxio, :pool_write_policy,
  mode: :hash,
  max_used_percent_x100: 9_900,
  exclude_pool_ids: []

# M8 scheduler run ledger. Enabled only as an audit sidecar around scheduler
# passes; it does not enable any scheduler or execute heal/rebalance work by
# itself. Automatic scheduled passes enter backoff after repeated blocked/failed
# results, while manual run_now remains available for operator recovery.
config :maxio, :scheduler_ledger,
  enabled: true,
  failure_threshold: 3,
  backoff_ms: 300_000,
  max_summary_bytes: 16_384,
  alert_sink: nil

# M8 scheduler run ledger retention. Default-off operator policy for pruning old
# raw run rows only after durable rollups already exist and still verify.
config :maxio, :scheduler_ledger_retention,
  enabled: false,
  retain_days: nil,
  window_minutes: 60,
  max_windows: 8_784

# M8 fresh-drive heal scheduler. Disabled by default; when enabled it automates
# only the existing DriveHealth.heal_required? marker workflow. The optional
# auto_rebalance_after_heal bridge only enqueues a durable rebalance job after a
# clean marker-clearing pass; the optional auto_advance_rebalance_after_heal drain
# reuses the normal rebalance scheduler for a bounded number of same-job
# copy/cleanup/closure steps. It does not perform decommission, topology mutation,
# physical removal, or physical drive actions.
config :maxio, :fresh_drive_heal_scheduler,
  enabled: false,
  interval_ms: 86_400_000,
  initial_delay_ms: 60_000,
  probe_drive_health: true,
  auto_rebalance_after_heal: false,
  auto_advance_rebalance_after_heal: false,
  rebalance_advance_max_steps: 2,
  run_opts: [],
  rebalance_start_opts: [],
  rebalance_advance_opts: [],
  lock_ttl_ms: 60_000,
  lock_timeout_ms: 3_000

# M8 decommission scheduler. Disabled by default; when enabled it advances the
# existing decommission copy-pass and guarded source cleanup primitives. Operators
# must still create jobs. If no destination set is explicitly configured, the
# scheduler asks the runner to choose one from DriveStats free-space telemetry.
# Cluster runtime topology apply and DB-backed deployment topology
# persistence/verification are additional explicit opt-ins. Runtime apply only
# runs when both auto_runtime_topology and auto_deployment_topology are enabled
# with :topology_source == :db. Rebalance closure audit recording is a separate
# explicit opt-in. None of these paths removes physical pools.
config :maxio, :rebalance_scheduler,
  enabled: false,
  interval_ms: 300_000,
  initial_delay_ms: 60_000,
  auto_source_cleanup: true,
  auto_destination: true,
  auto_runtime_topology: false,
  auto_deployment_topology: false,
  auto_rebalance_closure: false,
  destination_sets: %{},
  run_opts: [],
  lock_ttl_ms: 60_000,
  lock_timeout_ms: 3_000

# S3 bucket notification outbox retry scheduler. Disabled by default; when
# enabled it periodically drains already-persisted outbox rows through the same
# `Maxio.S3.NotificationDelivery.drain/1` path as `mix maxio.notification.drain`.
# It does not validate external destinations, perform network delivery by
# itself, construct new events, or mutate S3 objects.
#
# Network delivery is opt-in through `config :maxio, :notification_delivery`.
# Use a local `{Module, opts}` deliverer for tests/dev, or
# `{Maxio.S3.NotificationDelivery.AWS, opts}` for SigV4-signed SNS/SQS/Lambda/
# EventBridge delivery. With no deliverer, events remain pending in the durable
# outbox until an operator configures delivery and drains them.
config :maxio, :notification_delivery, deliverer: nil, async?: true

config :maxio, :notification_delivery_scheduler,
  enabled: false,
  interval_ms: 60_000,
  initial_delay_ms: 60_000,
  drain_limit: 100,
  run_opts: []

# S3 bucket replication outbox retry scheduler. Disabled by default. This only
# drains already-persisted replication outbox rows through ReplicationDelivery;
# it does not scan buckets, backfill objects, or synthesize replication tasks.
config :maxio, :replication_delivery_scheduler,
  enabled: false,
  interval_ms: 60_000,
  initial_delay_ms: 60_000,
  drain_limit: 100,
  run_opts: []

# ObjectMutation journal 收敛 recovery scheduler（协议 2026-07-10 §5，Phase 1 B6）。
# 与其他 deferred scheduler 不同（实现计划决策点 1）：这是 correctness 组件——PG commit
# 后进程崩溃的 finalize、metadata 提交前崩溃的旧字节恢复都由它兜底收敛，生产默认开启。
# initial_delay_ms/interval 的 60s 节奏与 prepare(initial_backoff_ms: 60_000) 宽限配合，
# 避免扫到健康 in-flight 请求；recovery 另持同一 {bucket,key} object lock 作第二道防线。
config :maxio, :object_mutation_recovery_scheduler,
  enabled: true,
  interval_ms: 60_000,
  initial_delay_ms: 60_000,
  drain_limit: 50,
  run_opts: []

# S3 Inventory report scheduler. Disabled by default. When enabled, it scans
# enabled InventoryConfiguration entries, claims the persistent
# s3_inventory_report_runs ledger for each due Daily/Weekly report date, then
# delegates object generation to Maxio.S3.Inventory.Report. The ledger keeps
# scheduled runs idempotent; manual one-off generation remains available via
# mix maxio.inventory.run.
config :maxio, :inventory_report_scheduler,
  enabled: false,
  interval_ms: 3_600_000,
  initial_delay_ms: 60_000,
  lease_ms: 3_600_000,
  singleton?: true,
  lock_opts: [],
  run_opts: []

# Console browser-direct multipart unfinished-upload pruner. Disabled by
# default and dry-run by default. When enabled, it periodically evaluates the
# Console direct MPU registry through the same
# `Maxio.Console.DirectMultipartUpload.prune_active/1` path as
# `mix maxio.console.direct_multipart.prune`. Actual aborts still require
# `dry_run: false` and `confirm_abort: true`; object bytes and SSE-C secrets are
# never read or persisted by the pruner.
config :maxio, :console_direct_multipart_pruner,
  enabled: false,
  interval_ms: 3_600_000,
  initial_delay_ms: 60_000,
  older_than_seconds: 86_400,
  limit: 100,
  dry_run: true,
  confirm_abort: false,
  all_owners: true,
  run_opts: []

# S3 bucket notification destination validation. Disabled by default. When set,
# PutBucketNotificationConfiguration without
# x-amz-skip-destination-validation:true calls the validator for direct
# SNS/SQS/Lambda destinations before storing the config. EventBridge-only
# configs do not require a validator. To use the built-in read-only AWS
# validator, set:
#
#   validator: {Maxio.S3.NotificationDestinationValidator.AWS, opts}
#
# where opts can include :credentials, :bucket_region, :source_account,
# :http_client, :endpoints, :sns_endpoint, :sqs_endpoint, :lambda_endpoint and
# :queue_urls. Tests and local harnesses should inject :http_client.
config :maxio, :notification_destination_validator, validator: nil

config :maxio, :io_pressure,
  enabled: true,
  interval_ms: 1_000,
  peer_timeout_ms: 50,
  cache_max_age_ms: 5_000

# M8-3 auto-heal scrubber（默认关——启动进程但不调度，避免 dev/test 意外扫盘）：
# 与 ROUTE B Storage.Scanner 分离。本 scrubber 从 PG 对象元数据分页枚举对象，刷新 usage
# 快照；FS 后端只统计 usage，ErasureCoded/Distributed 后端按 erasure set 短租约锁调度既有
# heal 引擎。reconcile_index:true 时先复用 Storage.Scanner 做 disk/peer sidecar→PG 派生索引收敛。
# 周期轮按 sample_inverse 做确定性 1/N 深度 heal 检查（每 cycle 轮换分区），但
# 手动触发/取证 `mix maxio.scan [--bucket <name>] [--versions] [--no-throttle]` 默认全量扫描。
# max_objects_per_sec + object_burst 使用 token-bucket 限速；object_burst 默认 1，保持保守稳态。
# adaptive_io 会读取所选 io_load_source（默认 cluster_combined = 本节点 + 新鲜 peer cache 的
# S3 in-flight 与 storage-op pressure），超过 max_live_requests 时在对象间短暂停顿；
# 最多 io_max_pause_ms。这不是请求限流/拒绝机制。
config :maxio, :scrubber,
  enabled: false,
  interval_ms: 86_400_000,
  initial_delay_ms: 60_000,
  page_size: 500,
  scan_versions: false,
  sample_inverse: 1024,
  reconcile_index: false,
  max_objects_per_sec: 200,
  object_burst: 1,
  sleep_between_batches_ms: 50,
  adaptive_io: true,
  io_load_source: :cluster_combined,
  max_live_requests: 0,
  io_pause_ms: 100,
  io_max_pause_ms: 5_000,
  lock_ttl_ms: 60_000,
  lock_timeout_ms: 3_000

# S3 Lifecycle 周期调度器（默认关——启动进程但不调度，避免 dev/test 意外删对象）。
# enabled: true 时 Maxio.Lifecycle.Scheduler 每 interval_ms 调用 Maxio.Lifecycle.run/1。
# 支持动作与 `mix maxio.lifecycle.run` 完全相同；Transition / NoncurrentVersionTransition 仍 no-op。
config :maxio, :lifecycle_scheduler, enabled: false, interval_ms: 86_400_000

# ROUTE B B5-1 PREFER 索引读门控（默认关）：仅当 authoritative_source(:read)=:sidecar 时生效——
# true → 单对象读先查 PG 派生索引（scanner 维护新鲜度），命中即返回（快路径），miss 走盘 sidecar；
# false（默认）→ 纯走盘正确性优先。P7-3 cutover 经 shadow 驱零取证后才开。
# LIST 的 PREFER 显式 defer 到 P7（续点 token 形态不同，见 Maxio.ObjectMeta.list/3）。
config :maxio, :read_prefer_index, false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
