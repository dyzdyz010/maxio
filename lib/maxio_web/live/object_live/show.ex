defmodule MaxioWeb.ObjectLive.Show do
  @moduledoc """
  Object Detail 占位 LiveView（M5-5 注册）：M5-5 的 ObjectLive.Index 行内对象名链接
  `~p"/buckets/<bucket>/object/<key>"` 需要该路由 + 目标 LiveView 模块编译期即存在
  （Phoenix 1.8 验证路由 + 路由 `__checks__/0` 校验 LiveView 定义 `__live__/0`），
  否则 `--warnings-as-errors` 失败。故此处先挂最小占位（与 M5-1 DashboardLive、
  M5-2 BucketLive.Index、M5-4 BucketLive.Settings 占位同模式）。mount/3 与
  M5-6 真实实现签名一致（匹配 `%{"bucket" => bucket, "key" => key_segments}`，action `:show`）。
  *** M5-6 必须「完整替换」本模块 *** 为对象详情 + tags 编辑 + 版本列表；
  路由已注册，M5-6 勿重复添加。
  """
  use MaxioWeb, :live_view

  @impl true
  def mount(%{"bucket" => bucket, "key" => key_segments}, _session, socket) do
    key = Enum.join(key_segments, "/")

    {:ok,
     socket
     |> assign(:page_title, key)
     |> assign(:bucket, bucket)
     |> assign(:key, key)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="object-detail-placeholder">
        <.header>
          <span class="font-mono text-base">{@key}</span>
          <:subtitle>
            <.link navigate={~p"/buckets/#{@bucket}/browse"} class="link">← 返回 {@bucket}</.link>
          </:subtitle>
        </.header>
        <p class="text-base-content/70">对象详情、标签编辑与版本历史将在 M5-6 上线。</p>
      </div>
    </Layouts.app>
    """
  end
end
