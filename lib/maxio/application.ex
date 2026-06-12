defmodule Maxio.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      cluster_children() ++
        [
          MaxioWeb.Telemetry,
          Maxio.Repo,
          {DNSCluster, query: Application.get_env(:maxio, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Maxio.PubSub},
          # M8 live-IO 自适应限流：本节点 S3 handler in-flight 计数器，由长期进程持有 ETS。
          Maxio.S3.InFlight,
          Maxio.Cluster.CacheInvalidator,
          Maxio.Cluster.DriveHealth,
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
        log_deferred_features()
        {:ok, pid}

      other ->
        other
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

    libcluster ++ [Maxio.Cluster.Topology, Maxio.Cluster.ShardServer, Maxio.Cluster.LockServer]
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

    Logger.info(
      "maxio deferred: " <>
        lifecycle_scheduler <>
        "lifecycle transition actions remain no-op; SSE-S3 uses single static master key " <>
        "(no rotation/KMS); MFA Delete not enforced; SSE-C/SSE-KMS return 501"
    )
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
