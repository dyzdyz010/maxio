defmodule MaxioWeb.DashboardLive do
  use MaxioWeb, :live_view

  alias Maxio.Console.Stats

  @impl true
  def mount(_params, _session, socket) do
    stats = Stats.dashboard()

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:stats, stats)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="dashboard" class="space-y-6">
        <.header>
          Dashboard
          <:subtitle>maxio 对象存储概览</:subtitle>
        </.header>

        <div class="grid grid-cols-2 lg:grid-cols-5 gap-4">
          <.stat_card id="stat-buckets" icon="hero-archive-box" label="桶" value={@stats.bucket_count} />
          <.stat_card
            id="stat-objects"
            icon="hero-document"
            label="对象（当前版本）"
            value={@stats.object_count}
          />
          <.stat_card
            id="stat-size"
            icon="hero-circle-stack"
            label="总用量"
            value={format_bytes(@stats.total_size)}
          />
          <.stat_card id="stat-keys" icon="hero-key" label="Access Keys" value={@stats.access_key_count} />
          <.stat_card
            id="stat-multipart"
            icon="hero-arrow-up-tray"
            label="进行中分段上传"
            value={@stats.multipart_count}
          />
        </div>

        <div>
          <h2 class="text-sm font-semibold mb-2 text-base-content/70">各桶用量</h2>
          <table id="per-bucket-table" class="table table-zebra">
            <thead>
              <tr>
                <th>桶</th>
                <th class="text-right">对象数</th>
                <th class="text-right">大小</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@stats.per_bucket == []}>
                <td colspan="3" class="text-center text-base-content/50">暂无对象</td>
              </tr>
              <tr :for={b <- @stats.per_bucket}>
                <td>
                  <.link navigate={~p"/buckets/#{b.name}/browse"} class="link link-primary">
                    {b.name}
                  </.link>
                </td>
                <td class="text-right">{b.object_count}</td>
                <td class="text-right">{format_bytes(b.size)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat_card(assigns) do
    ~H"""
    <div id={@id} class="rounded-box bg-base-100 border border-base-300 p-4 flex items-center gap-3">
      <div class="rounded-lg bg-primary/10 p-2">
        <.icon name={@icon} class="size-5 text-primary" />
      </div>
      <div class="min-w-0">
        <div class="text-xs text-base-content/60 truncate">{@label}</div>
        <div class="text-lg font-semibold">{@value}</div>
      </div>
    </div>
    """
  end

  # 人类可读字节（二进制单位）。
  defp format_bytes(n) when is_integer(n) and n >= 0 do
    cond do
      n >= 1024 * 1024 * 1024 -> "#{Float.round(n / (1024 * 1024 * 1024), 2)} GiB"
      n >= 1024 * 1024 -> "#{Float.round(n / (1024 * 1024), 2)} MiB"
      n >= 1024 -> "#{Float.round(n / 1024, 2)} KiB"
      true -> "#{n} B"
    end
  end

  defp format_bytes(_), do: "0 B"
end
