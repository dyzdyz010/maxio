defmodule MaxioWeb.Router do
  use MaxioWeb, :router

  import MaxioWeb.ConsoleAuthPlug

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MaxioWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_principal
  end

  pipeline :browser_download do
    plug :accepts, ["html", "csv"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_principal
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :console_authenticated do
    plug :require_authenticated
  end

  pipeline :console_json do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_principal
    plug :require_authenticated
  end

  scope "/", MaxioWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
  end

  scope "/", MaxioWeb do
    pipe_through [:browser, :console_authenticated]

    live_session :console_authenticated,
      on_mount: [{MaxioWeb.ConsoleAuth.OnMount, :require_authenticated}] do
      live "/", DashboardLive, :index
      live "/buckets", BucketLive.Index, :index
      live "/buckets/:bucket/browse", ObjectLive.Index, :index
      live "/buckets/:bucket/object/*key", ObjectLive.Show, :show
      live "/buckets/:bucket/settings", BucketLive.Settings, :show
      live "/access-keys", AccessKeyLive.Index, :index
      live "/users", UserLive.Index, :index
      live "/groups", GroupLive.Index, :index
      live "/roles", RoleLive.Index, :index
      live "/idp", IdpLive.Index, :index
      live "/sts-sessions", StsSessionLive.Index, :index
      live "/ops/cluster", OpsClusterLive, :index
      live "/ops/compat", OpsCompatLive, :index
      live "/ops/gate", OpsGateLive, :index
      live "/ops/observability", OpsObservabilityLive, :index
      live "/ops/rebalance", OpsRebalanceLive, :index
      live "/ops/recovery", OpsRecoveryLive, :index
      live "/ops/replacement", OpsReplacementLive, :index
      live "/ops/scan", OpsScanLive, :index
      live "/ops/upgrade", OpsUpgradeLive, :index
    end

    get "/buckets/:bucket/download/*key", DownloadController, :show
    get "/buckets/:bucket/preview/*key", DownloadController, :preview
  end

  scope "/", MaxioWeb do
    pipe_through [:browser_download, :console_authenticated]

    get "/buckets/:bucket/direct-multipart/history.csv",
        ConsoleDirectMultipartHistoryController,
        :export
  end

  scope "/console/api", MaxioWeb do
    pipe_through :console_json

    post "/buckets/:bucket/direct-multipart/initiate/*key",
         ConsoleMultipartUploadController,
         :initiate

    post "/buckets/:bucket/direct-multipart/sign-parts/*key",
         ConsoleMultipartUploadController,
         :sign_parts

    post "/buckets/:bucket/direct-multipart/list-parts/*key",
         ConsoleMultipartUploadController,
         :list_parts

    post "/buckets/:bucket/direct-multipart/register/*key",
         ConsoleMultipartUploadController,
         :register

    post "/buckets/:bucket/direct-multipart/lookup/*key",
         ConsoleMultipartUploadController,
         :lookup

    post "/buckets/:bucket/direct-multipart/complete/*key",
         ConsoleMultipartUploadController,
         :complete

    post "/buckets/:bucket/direct-multipart/abort/*key",
         ConsoleMultipartUploadController,
         :abort
  end

  if Application.compile_env(:maxio, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MaxioWeb.Telemetry
    end
  end
end
