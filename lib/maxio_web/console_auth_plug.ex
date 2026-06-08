defmodule MaxioWeb.ConsoleAuthPlug do
  @moduledoc "Console controller 侧鉴权插件：还原 principal assign + 已登录跳转。"
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias MaxioWeb.ConsoleAuth

  @doc "把 session 的 access_key 还原成 :current_principal assign（供 SessionController 等用）。"
  def fetch_current_principal(conn, _opts) do
    assign(conn, :current_principal, ConsoleAuth.fetch_principal(get_session(conn)))
  end

  @doc "已登录用户访问 /login → 跳回 /。"
  def redirect_if_authenticated(conn, _opts) do
    if conn.assigns[:current_principal] do
      conn |> redirect(to: "/") |> halt()
    else
      conn
    end
  end
end
