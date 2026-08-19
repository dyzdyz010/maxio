defmodule Maxio.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @pt_started_at {__MODULE__, :started_at}

  @impl true
  def start(_type, _args) do
    record_started_at()

    children =
      [
        MaxioWeb.Telemetry,
        Maxio.Repo
      ] ++
        cluster_children() ++
        [
          {DNSCluster, query: Application.get_env(:maxio, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Maxio.PubSub},
          # 运行时配置快照（设计 D2/D5）：必须在 PubSub 之后（要订阅失效广播）、在任何
          # 读配置的子系统之前（否则第一批请求会读到空快照然后回落 app env——那是安全的
          # 降级，但没必要）。它自身对 PG 不可达是容错的：空快照 = 纯 Application env 行为。
          Maxio.Config.Store,
          # M8 live-IO 自适应限流：本节点 S3 handler in-flight 计数器，由长期进程持有 ETS。
          Maxio.S3.InFlight,
          Maxio.S3.NotificationDelivery.Scheduler,
          Maxio.S3.ReplicationDelivery.Scheduler,
          Maxio.S3.Inventory.Scheduler,
          Maxio.IAM.SigningSecretRotation.Scheduler,
          Maxio.IAM.OIDCProviderRefresh.Scheduler,
          Maxio.Console.DirectMultipartUpload.Scheduler,
          # ObjectMutation Phase 1 B6：journal 收敛 recovery scheduler（实现计划决策点 1：
          # correctness 组件而非可选优化，生产默认 enabled——PG-commit-后-kill 的 finalize、
          # metadata-前-kill 的旧字节恢复都依赖它兜底；test.exs 显式关闭，测试用
          # start_supervised! + run_now 同步驱动）。
          Maxio.ObjectMutation.Recovery.Scheduler,
          Maxio.Cluster.DriveIO,
          Maxio.Cluster.DriveDeviceIO,
          Maxio.Cluster.PressureAggregator,
          Maxio.Cluster.CacheInvalidator,
          Maxio.Cluster.DriveHealth,
          Maxio.Cluster.FreshDriveHeal.Scheduler,
          # M8 decommission 后台推进器（默认 disabled）：只编排既有 copy-pass/source-cleanup，
          # 不做 topology mutation / free-space placement / pool removal。
          Maxio.Cluster.Rebalance.Scheduler,
          # ROUTE B B5-2：派生索引周期 reconcile scanner（默认 disabled——启动但不调度，
          # init 显式日志声明状态；config :maxio, :scanner, enabled: true 开启周期轮）。
          Maxio.Storage.Scanner,
          # M8-3：运维 scrubber（默认 disabled——启动但不调度）。职责与 Storage.Scanner 分离：
          # 从 PG 元数据分页枚举对象，刷新 usage 快照，并对纠删码/分布式后端调度 auto-heal。
          Maxio.Cluster.Scrubber,
          # S3 Lifecycle 周期调度器（默认 disabled——与 scanner 一样启动但不调度；手动 CLI
          # 与后台轮次共用 Maxio.Lifecycle.run/1，Transition 仍显式 no-op）。
          Maxio.Lifecycle.Scheduler,
          # Start a worker by calling: Maxio.Worker.start_link(arg)
          # {Maxio.Worker, arg},
          # Start to serve requests, typically the last entry
          MaxioWeb.Endpoint
        ] ++ s3_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Maxio.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        maybe_bootstrap_root()
        audit_reserved_bucket()
        log_deferred_features()
        {:ok, pid}

      other ->
        other
    end
  end

  # ── 进程启动时刻（madmin ServerInfo 的 servers[].uptime 数据源）──
  # monotonic 时钟：uptime 必须单调，绝不能被系统时钟回拨改写成负数。
  # 同时记一份 wall-clock 起始时刻供 CLI/Console 展示"什么时候起来的"。
  defp record_started_at do
    :persistent_term.put(@pt_started_at, %{
      monotonic_s: System.monotonic_time(:second),
      system_time: DateTime.utc_now()
    })
  end

  @doc """
  本节点 maxio 应用启动至今的秒数。

  应用未经 `start/2` 起来时（例如某些只跑单模块的 Mix 任务）返回 `nil`——绝不返回 0
  冒充"刚启动"，`0` 与"不知道"在监控里是两个完全不同的信号（ServerInfo 据此 omit 该字段）。
  """
  @spec uptime_seconds() :: non_neg_integer() | nil
  def uptime_seconds do
    case :persistent_term.get(@pt_started_at, nil) do
      %{monotonic_s: started} -> max(System.monotonic_time(:second) - started, 0)
      nil -> nil
    end
  end

  @doc "本节点 maxio 应用的启动时刻（wall clock）；未记录时为 nil。"
  @spec started_at() :: DateTime.t() | nil
  def started_at do
    case :persistent_term.get(@pt_started_at, nil) do
      %{system_time: at} -> at
      nil -> nil
    end
  end

  # M7：libcluster 节点发现 supervisor（仅非空 topologies 才起）+ 拓扑解析 GenServer（始终起，
  # 无配置时空转）。单节点 dev/test 跳过 Cluster.Supervisor，但 Topology 仍存在（读时若无配置 raise）。
  defp cluster_children do
    topologies = Application.get_env(:maxio, Maxio.Cluster, [])[:topologies] || []

    libcluster =
      if topologies == [],
        do: [],
        else: [{Cluster.Supervisor, [topologies, [name: Maxio.Cluster.ClusterSupervisor]]}]

    libcluster ++
      [
        Maxio.Cluster.Topology,
        # ObjectMutation B1：节点本地 epoch 串行执行器（per-endpoint CAS 原子性 +
        # Windows 两步 rename 窗口不可见的落点；ShardServer epoch 原语委托它执行）。
        {PartitionSupervisor,
         child_spec: Maxio.Storage.EpochStore.Worker, name: Maxio.Storage.EpochStore},
        Maxio.Cluster.ShardServer,
        Maxio.Cluster.LockServer
      ]
  end

  # 诚实暴露仍未完成的高级特性（铁律 3：绝不假装已生效）。
  defp log_deferred_features do
    require Logger

    lifecycle_scheduler =
      if Application.get_env(:maxio, :lifecycle_scheduler, [])[:enabled] do
        "lifecycle background scheduler enabled for supported sweeps; "
      else
        "lifecycle background scheduler disabled by default (enable config :maxio, :lifecycle_scheduler or run mix maxio.lifecycle.run); "
      end

    notification_scheduler =
      if Application.get_env(:maxio, :notification_delivery_scheduler, [])[:enabled] do
        "bucket notification outbox scheduler enabled for retry drains; "
      else
        "bucket notification outbox scheduler disabled by default (enable config :maxio, :notification_delivery_scheduler or run mix maxio.notification.drain); "
      end

    replication_scheduler =
      if Application.get_env(:maxio, :replication_delivery_scheduler, [])[:enabled] do
        "bucket replication outbox scheduler enabled for retry drains; "
      else
        "bucket replication outbox scheduler disabled by default (enable config :maxio, :replication_delivery_scheduler or run mix maxio.replication.drain); "
      end

    inventory_scheduler =
      if Application.get_env(:maxio, :inventory_report_scheduler, [])[:enabled] do
        "inventory report scheduler enabled for due InventoryConfiguration reports; "
      else
        "inventory report scheduler disabled by default (enable config :maxio, :inventory_report_scheduler or run mix maxio.inventory.schedule); "
      end

    object_mutation_recovery =
      if Application.get_env(:maxio, :object_mutation_recovery_scheduler, [])[:enabled] do
        "object mutation recovery scheduler enabled (correctness component: journal-driven crash convergence for protocol PutObject); "
      else
        "object mutation recovery scheduler DISABLED (correctness component -- crashed protocol PutObject journals will not converge; enable config :maxio, :object_mutation_recovery_scheduler or drain via Maxio.ObjectMutation.Recovery.drain/1); "
      end

    direct_multipart_pruner =
      if Application.get_env(:maxio, :console_direct_multipart_pruner, [])[:enabled] do
        "console direct multipart prune scheduler enabled for unfinished MPU maintenance; "
      else
        "console direct multipart prune scheduler disabled by default (enable config :maxio, :console_direct_multipart_pruner or run mix maxio.console.direct_multipart.prune); "
      end

    iam_secret_rotation =
      if Application.get_env(:maxio, :iam_signing_secret_rotation, [])[:enabled] do
        "iam signing secret rotation scheduler enabled (actual writes require confirm_rotation: true); "
      else
        "iam signing secret rotation scheduler disabled by default (enable config :maxio, :iam_signing_secret_rotation or run mix maxio.iam.rotate_secret_key); "
      end

    oidc_jwks_refresh =
      if Application.get_env(:maxio, :iam_oidc_provider_jwks_refresh, [])[:enabled] do
        "iam oidc provider jwks refresh scheduler enabled (actual writes require confirm_refresh: true); "
      else
        "iam oidc provider jwks refresh scheduler disabled by default (enable config :maxio, :iam_oidc_provider_jwks_refresh or run mix maxio.iam.oidc.refresh_jwks); "
      end

    Logger.info(
      "maxio deferred: " <>
        lifecycle_scheduler <>
        notification_scheduler <>
        replication_scheduler <>
        inventory_scheduler <>
        object_mutation_recovery <>
        direct_multipart_pruner <>
        iam_secret_rotation <>
        oidc_jwks_refresh <>
        "lifecycle transition actions remain no-op; SSE-S3 uses single static master key; " <>
        "SSE-KMS uses local provider/wrapping key (no rotation/external KMS); " <>
        "MFA Delete requires configured verifier; SSE-C and SSE-KMS object/copy/multipart paths supported; DSSE-KMS returns 501"
    )
  end

  # 启动期报告被保留路径影子化的对象 key（设计 D8）：只报告，不删除，不阻止启动。
  # DB 尚未可达时降级为一条结构化 error——审计本身绝不能成为启动失败的新原因，但
  # "审计没跑成"必须留下**可归因**的痕迹：走项目统一的结构化日志（`Maxio.S3.Log`，
  # 进 Logger metadata 可按 reason 检索），并把 stacktrace 一并留下（只记 message 的话，
  # 一句 "** (DBConnection.ConnectionError) ..." 根本定位不到是谁在什么位置炸的）。
  defp audit_reserved_bucket do
    Maxio.S3.ReservedBucketAudit.audit()
  rescue
    e ->
      report_reserved_bucket_audit_failure(Exception.format(:error, e, __STACKTRACE__))
  catch
    # `rescue` 只接 raise。启动期 DB 尚未就绪时最常见的失败形态恰恰是 **exit**——
    # Ecto 连接池 checkout 超时 / Repo 进程未起，`Repo.all` 会 `exit({:noproc, ...})` 或
    # `exit({:timeout, ...})`，那会原样穿过 rescue 中断 `Application.start/2`。
    # 本函数的全部承诺就是"审计绝不成为启动失败的新原因"，故 exit 与 throw 一并兜住。
    kind, reason ->
      report_reserved_bucket_audit_failure(Exception.format(kind, reason, __STACKTRACE__))
  end

  defp report_reserved_bucket_audit_failure(formatted) do
    Maxio.S3.Log.error(
      "reserved path audit did not run; shadowed object keys are NOT reported this boot",
      reason: formatted,
      code: "ReservedPathAuditFailed",
      action: "startup_audit"
    )

    :ok
  end

  # 仅 EctoStore 下在 Repo 起来后幂等引导 root（MemoryStore 自带惰性引导，无需此步）。
  defp maybe_bootstrap_root do
    if Application.get_env(:maxio, :credential_store) == Maxio.Auth.CredentialStore.EctoStore do
      try do
        Maxio.IAM.bootstrap_root()
      rescue
        e ->
          require Logger
          Logger.warning("root bootstrap skipped: #{Exception.message(e)}")
      end
    end
  end

  # 独立 S3 Endpoint（Bandit, 端口 9000）。test 环境 server: false 时不启监听（走 Plug.Test）。
  defp s3_children do
    cfg = Application.get_env(:maxio, Maxio.S3.Endpoint, [])

    if Keyword.get(cfg, :server, true) do
      port = Keyword.get(cfg, :port, 9000)
      ip = Keyword.get(cfg, :ip, :any)

      [
        Supervisor.child_spec(
          {Bandit, plug: Maxio.S3.Endpoint, scheme: :http, port: port, ip: ip},
          id: :maxio_s3_bandit
        )
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MaxioWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
