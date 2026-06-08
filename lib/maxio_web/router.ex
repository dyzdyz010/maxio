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

  pipeline :api do
    plug :accepts, ["json"]
  end

  # ── 公共：登录页（plain controller）+ 会话 controller ──
  scope "/", MaxioWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
  end

  # ── 受保护：Console 主体（LiveView）──
  scope "/", MaxioWeb do
    pipe_through :browser

    live_session :console_authenticated,
      on_mount: [{MaxioWeb.ConsoleAuth.OnMount, :require_authenticated}] do
      live "/", DashboardLive, :index
      # 侧边栏导航目标路由（M5-2 装配 nav 链接需 ~p 编译期校验通过 + Phoenix 1.8
      # __checks__ 校验 LiveView 模块存在）。故此处先挂最小占位 LiveView，
      # 与 M5-1 的 DashboardLive 占位同模式；各自单元再「完整替换」：
      #   BucketLive.Index → M5-4；AccessKeyLive.Index → M5-8。
      live "/buckets", BucketLive.Index, :index
      live "/buckets/:bucket/browse", ObjectLive.Index, :index
      # M5-4 的 buckets 列表行（及 M5-5 对象浏览器顶栏）用
      # `~p"/buckets/#{bucket}/settings"` 设置链接；Phoenix 1.8 验证路由 + __checks__
      # 要求该路由与目标 LiveView 模块编译期即存在。故此处先挂最小占位
      # BucketLive.Settings（同 M5-1/M5-2/M5-3 占位模式），M5-7 「完整替换」。
      live "/buckets/:bucket/settings", BucketLive.Settings, :show
      live "/access-keys", AccessKeyLive.Index, :index
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", MaxioWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:maxio, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MaxioWeb.Telemetry
    end
  end
end
