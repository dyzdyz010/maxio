defmodule MaxioWeb.BucketLive.Settings do
  @moduledoc """
  Bucket Settings 占位 LiveView（M5-4 引入）：M5-4 的 buckets 列表行（及 M5-5 对象浏览器顶栏）
  用 `<.link navigate={~p"/buckets/<bucket>/settings"}>` 跳转到设置页。Phoenix 1.8 验证路由
  在编译期校验 `~p"/buckets/:bucket/settings"` 路径存在，且 router `__checks__` 校验
  `BucketLive.Settings` 模块定义 `__live__/0`——两者均会触发 `--warnings-as-errors` 失败，除非
  路由与 LiveView 模块此刻即存在。与 M5-1（DashboardLive）/M5-2（BucketLive.Index、
  AccessKeyLive.Index）/M5-3（ObjectLive.Index）的占位同模式：注册受保护路由 + 最小占位
  LiveView，M5-7 将「完整替换」本模块为 versioning/policy/acl/tags/cors/lifecycle/encryption
  tabbed 编辑器（mount 用 %{"bucket" => bucket}、action :show，签名一致）。
  """
  use MaxioWeb, :live_view

  @impl true
  def mount(%{"bucket" => bucket}, _session, socket) do
    {:ok,
     socket
     |> assign(:bucket, bucket)
     |> assign(:page_title, "#{bucket} · 设置")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="bucket-settings-placeholder">
        <.header>
          {@bucket} · 设置
          <:subtitle>
            <.link navigate={~p"/buckets/#{@bucket}/browse"} class="link">← 返回浏览</.link>
          </:subtitle>
        </.header>
        <p class="text-base-content/70">
          桶设置（版本化 / 策略 / ACL / 标签 / CORS / 生命周期 / 加密）将在 M5-7 上线。
        </p>
      </div>
    </Layouts.app>
    """
  end
end
