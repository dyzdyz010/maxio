defmodule MaxioWeb.ObjectLive.Index do
  @moduledoc """
  Object Browser 占位 LiveView（M5-3）：仅为 Dashboard per-bucket 行的导航目标
  `~p"/buckets/:bucket/browse"` 可解析（Phoenix 1.8 路由 `__checks__` 要求 LiveView
  模块存在 + `~p` 编译期校验）。M5-5 将「完整替换」本模块为对象列表 + 面包屑 +
  上传/下载/删除/新建文件夹。与 M5-1 的 DashboardLive、M5-2 的 BucketLive.Index 占位同模式。
  """
  use MaxioWeb, :live_view

  @impl true
  def mount(%{"bucket" => bucket}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Browse · #{bucket}")
     |> assign(:bucket, bucket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="objects-placeholder">
        <.header>
          {@bucket}
          <:subtitle>对象浏览（M5-5 充实）</:subtitle>
        </.header>
        <p class="text-base-content/70">对象列表、上传、下载与删除将在后续单元上线。</p>
      </div>
    </Layouts.app>
    """
  end
end
