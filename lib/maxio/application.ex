defmodule Maxio.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        MaxioWeb.Telemetry,
        Maxio.Repo,
        {DNSCluster, query: Application.get_env(:maxio, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Maxio.PubSub},
        # Start a worker by calling: Maxio.Worker.start_link(arg)
        # {Maxio.Worker, arg},
        # Start to serve requests, typically the last entry
        MaxioWeb.Endpoint
      ] ++ s3_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Maxio.Supervisor]
    Supervisor.start_link(children, opts)
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
