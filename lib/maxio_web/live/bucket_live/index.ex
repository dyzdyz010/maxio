defmodule MaxioWeb.BucketLive.Index do
  @moduledoc """
  Buckets 列表占位 LiveView（M5-2）：仅为侧边栏 `#nav-buckets` 导航目标路由可解析
  （Phoenix 1.8 路由 `__checks__` 要求 LiveView 模块存在 + `~p"/buckets"` 编译期校验）。
  M5-4 将「完整替换」本模块为 streams 列表 + 创建/删除 + 错误 flash 矩阵。
  与 M5-1 的 DashboardLive 占位同模式。
  """
  use MaxioWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Buckets")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="buckets-placeholder">
        <.header>
          Buckets
          <:subtitle>桶管理（M5-4 充实）</:subtitle>
        </.header>
        <p class="text-base-content/70">桶列表、创建与删除将在后续单元上线。</p>
      </div>
    </Layouts.app>
    """
  end
end
