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
