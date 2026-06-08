defmodule MaxioWeb.ConsoleAuth.OnMount do
  @moduledoc """
  `live_session` 的 `on_mount` 钩子：
    * `:require_authenticated` —— 受保护页；无 principal 即 halt 重定向到 /login。
    * `:mount_current_principal` —— 公共页（如 /login）只取 principal，不强制。
  钩子在 dead 与 connected 两次 mount 都跑；重定向必须 halt（否则 LiveView raise）。
  """
  import Phoenix.Component, only: [assign_new: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias MaxioWeb.ConsoleAuth

  def on_mount(:require_authenticated, _params, session, socket) do
    socket =
      assign_new(socket, :current_principal, fn ->
        ConsoleAuth.fetch_principal(session)
      end)

    if socket.assigns.current_principal do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end

  def on_mount(:mount_current_principal, _params, session, socket) do
    {:cont,
     assign_new(socket, :current_principal, fn -> ConsoleAuth.fetch_principal(session) end)}
  end
end
