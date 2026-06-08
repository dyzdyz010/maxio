defmodule MaxioWeb.AccessKeyLive.Index do
  @moduledoc """
  Access Keys 列表占位 LiveView（M5-2）：仅为侧边栏 `#nav-access-keys` 导航目标路由可解析
  （Phoenix 1.8 路由 `__checks__` 要求 LiveView 模块存在 + `~p"/access-keys"` 编译期校验）。
  M5-8 将「完整替换」本模块为列表/创建（一次性 secret）/删除（root 保护）。
  与 M5-1 的 DashboardLive 占位同模式。
  """
  use MaxioWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Access Keys")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="access-keys-placeholder">
        <.header>
          Access Keys
          <:subtitle>访问密钥管理（M5-8 充实）</:subtitle>
        </.header>
        <p class="text-base-content/70">密钥列表、创建与删除将在后续单元上线。</p>
      </div>
    </Layouts.app>
    """
  end
end
