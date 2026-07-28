defmodule MaxioWeb.ConsoleAuthPlug do
  @moduledoc "Console controller authentication plugs."
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias MaxioWeb.ConsoleAuth

  def fetch_current_principal(conn, _opts) do
    assign(conn, :current_principal, ConsoleAuth.fetch_principal(get_session(conn)))
  end

  def require_authenticated(conn, _opts) do
    if conn.assigns[:current_principal] do
      conn
    else
      conn
      |> redirect(to: "/login")
      |> halt()
    end
  end

  def redirect_if_authenticated(conn, _opts) do
    if conn.assigns[:current_principal] do
      conn |> redirect(to: "/") |> halt()
    else
      conn
    end
  end
end
