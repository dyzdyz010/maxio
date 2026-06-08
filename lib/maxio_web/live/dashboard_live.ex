defmodule MaxioWeb.DashboardLive do
  use MaxioWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Dashboard")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="dashboard">
        <.header>Dashboard</.header>
        <p class="text-base-content/70">maxio Console（M5-2 起逐步充实）。</p>
      </div>
    </Layouts.app>
    """
  end
end
