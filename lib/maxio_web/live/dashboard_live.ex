defmodule MaxioWeb.DashboardLive do
  use MaxioWeb, :live_view

  alias Maxio.Console.Stats

  @chart_width 600
  @chart_height 150
  @chart_top_padding 12
  @chart_bottom_padding 24
  @chart_plot_height @chart_height - @chart_top_padding - @chart_bottom_padding

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign_dashboard(params)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_dashboard(socket, params)}
  end

  @impl true
  def handle_event("select_request_metrics", %{"metrics" => %{"stream" => value}}, socket) do
    case parse_stream_value(value) do
      {:ok, bucket, filter_id} ->
        {:noreply,
         push_patch(socket,
           to: ~p"/?#{%{metrics_bucket: bucket, metrics_id: filter_id}}"
         )}

      :error ->
        {:noreply, push_patch(socket, to: ~p"/")}
    end
  end

  def handle_event("select_request_metrics", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/")}
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
          <.stat_card
            id="stat-buckets"
            icon="hero-archive-box"
            label="桶"
            value={@stats.bucket_count}
          />
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
          <.stat_card
            id="stat-keys"
            icon="hero-key"
            label="Access Keys"
            value={@stats.access_key_count}
          />
          <.stat_card
            id="stat-multipart"
            icon="hero-arrow-up-tray"
            label="进行中分段上传"
            value={@stats.multipart_count}
          />
        </div>

        <.request_metrics_panel metrics={@stats.request_metrics} form={@metrics_form} />

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

  attr :metrics, :map, required: true
  attr :form, Phoenix.HTML.Form, required: true

  defp request_metrics_panel(assigns) do
    ~H"""
    <section
      id="request-metrics-panel"
      class="rounded-box bg-base-100 border border-base-300 p-4 md:p-5 space-y-4"
    >
      <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
        <div>
          <h2 class="text-sm font-semibold text-base-content/80">请求指标</h2>
          <p class="text-xs text-base-content/55">
            本地 Bucket Metrics 账本，按单个 bucket/filter_id 展示最近 {@metrics.range_minutes} 分钟。
          </p>
        </div>

        <.form
          :if={@metrics.streams != []}
          for={@form}
          id="request-metrics-filter-form"
          phx-change="select_request_metrics"
          class="w-full md:w-80"
        >
          <.input
            field={@form[:stream]}
            type="select"
            id="metrics_stream"
            label="指标流"
            options={stream_options(@metrics.streams)}
            class="w-full select select-sm"
          />
        </.form>
      </div>

      <div
        :if={is_nil(@metrics.selected)}
        id="request-metrics-empty"
        class="rounded-lg border border-dashed border-base-300 px-4 py-8 text-center text-sm text-base-content/55"
      >
        暂无请求指标。为 bucket 配置 MetricsConfiguration 后，S3 请求会出现在这里。
      </div>

      <div :if={@metrics.selected} id="request-metrics-selected-view" class="space-y-4">
        <div class="flex flex-col gap-1 text-xs text-base-content/60 md:flex-row md:items-center md:justify-between">
          <div>
            当前流：
            <span id="request-metrics-selected" class="font-medium text-base-content">
              {stream_label(@metrics.selected)}
            </span>
          </div>
          <div id="request-metrics-window">
            {format_datetime(@metrics.from)} - {format_datetime(@metrics.until)}
          </div>
        </div>

        <div class="grid grid-cols-2 gap-3 md:grid-cols-6">
          <.metric_summary
            id="request-metric-total"
            label="请求"
            value={@metrics.totals.request_count}
          />
          <.metric_summary
            id="request-metric-errors"
            label="错误"
            value={@metrics.totals.error_count}
          />
          <.metric_summary
            id="request-metric-uploaded"
            label="上传"
            value={format_bytes(@metrics.totals.bytes_uploaded_sum)}
          />
          <.metric_summary
            id="request-metric-downloaded"
            label="下载"
            value={format_bytes(@metrics.totals.bytes_downloaded_sum)}
          />
          <.metric_summary
            id="request-metric-avg-latency"
            label="平均延迟"
            value={format_latency(@metrics.totals.latency_ms_avg)}
          />
          <.metric_summary
            id="request-metric-max-latency"
            label="峰值延迟"
            value={format_latency(@metrics.totals.latency_ms_max)}
          />
        </div>

        <div id="request-metrics-chart" class="overflow-x-auto">
          <svg
            viewBox={chart_view_box()}
            preserveAspectRatio="none"
            role="img"
            aria-label="每分钟请求数量"
            class="h-40 w-full min-w-[640px]"
          >
            <line
              x1="0"
              x2={chart_width()}
              y1={chart_baseline()}
              y2={chart_baseline()}
              class="stroke-base-300"
              stroke-width="1"
            />
            <rect
              :for={bar <- chart_bars(@metrics.points)}
              id={bar.id}
              data-window={bar.window}
              x={bar.x}
              y={bar.y}
              width={bar.width}
              height={bar.height}
              class={bar.class}
              rx="1"
            >
              <title>{bar.title}</title>
            </rect>
            <text
              :for={tick <- chart_ticks(@metrics.points)}
              x={tick.x}
              y={tick.y}
              text-anchor="middle"
              class="fill-base-content/50 text-[10px]"
            >
              {tick.label}
            </text>
          </svg>
        </div>

        <div class="overflow-x-auto">
          <table id="request-metrics-series-table" class="table table-xs">
            <thead>
              <tr>
                <th>窗口</th>
                <th class="text-right">请求</th>
                <th class="text-right">错误</th>
                <th class="text-right">上传</th>
                <th class="text-right">下载</th>
                <th class="text-right">平均延迟</th>
                <th class="text-right">峰值延迟</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{point, index} <- Enum.with_index(recent_points(@metrics.points))}
                id={"request-metrics-row-#{index}"}
              >
                <td>{point.label}</td>
                <td class="text-right">{point.request_count}</td>
                <td class="text-right">{point.error_count}</td>
                <td class="text-right">{format_bytes(point.bytes_uploaded_sum)}</td>
                <td class="text-right">{format_bytes(point.bytes_downloaded_sum)}</td>
                <td class="text-right">{format_latency(point.latency_ms_avg)}</td>
                <td class="text-right">{format_latency(point.latency_ms_max)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp metric_summary(assigns) do
    ~H"""
    <div id={@id} class="min-w-0 border-l border-base-300 pl-3">
      <div class="truncate text-[11px] text-base-content/50">{@label}</div>
      <div class="truncate text-sm font-semibold text-base-content">{@value}</div>
    </div>
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

  defp assign_dashboard(socket, params) do
    stats = Stats.dashboard(request_metrics: request_metrics_params(params))

    socket
    |> assign(:stats, stats)
    |> assign(:metrics_form, metrics_form(stats.request_metrics))
  end

  defp request_metrics_params(params) when is_map(params) do
    [
      bucket: Map.get(params, "metrics_bucket"),
      filter_id: Map.get(params, "metrics_id")
    ]
  end

  defp metrics_form(metrics) do
    to_form(%{"stream" => stream_value(metrics.selected)}, as: :metrics)
  end

  defp stream_options(streams) do
    Enum.map(streams, fn stream -> {stream_label(stream), stream_value(stream)} end)
  end

  defp stream_label(%{bucket: bucket, filter_id: filter_id}), do: "#{bucket} / #{filter_id}"
  defp stream_label(_stream), do: ""

  defp stream_value(nil), do: ""

  defp stream_value(%{bucket: bucket, filter_id: filter_id}) do
    bucket_value = Base.url_encode64(bucket, padding: false)
    filter_value = Base.url_encode64(filter_id, padding: false)
    bucket_value <> "." <> filter_value
  end

  defp parse_stream_value(value) when is_binary(value) do
    with [bucket_value, filter_value] <- String.split(value, ".", parts: 2),
         {:ok, bucket} <- Base.url_decode64(bucket_value, padding: false),
         {:ok, filter_id} <- Base.url_decode64(filter_value, padding: false),
         false <- bucket == "" or filter_id == "" do
      {:ok, bucket, filter_id}
    else
      _other -> :error
    end
  end

  defp parse_stream_value(_value), do: :error

  defp chart_view_box, do: "0 0 #{@chart_width} #{@chart_height}"
  defp chart_width, do: @chart_width
  defp chart_baseline, do: @chart_top_padding + @chart_plot_height

  defp chart_bars(points) do
    max_count =
      points
      |> Enum.map(& &1.request_count)
      |> Enum.max(fn -> 0 end)

    count = max(length(points), 1)
    gap = 2
    width = (@chart_width - gap * (count - 1)) / count

    points
    |> Enum.with_index()
    |> Enum.map(fn {point, index} ->
      height =
        cond do
          max_count <= 0 -> 0
          point.request_count <= 0 -> 0
          true -> max(point.request_count / max_count * @chart_plot_height, 2)
        end

      x = index * (width + gap)
      y = chart_baseline() - height

      %{
        id: "request-metrics-bar-#{index}",
        window: DateTime.to_iso8601(point.window_started_at),
        x: chart_number(x),
        y: chart_number(y),
        width: chart_number(max(width, 1)),
        height: chart_number(height),
        class: if(point.error_count > 0, do: "fill-error", else: "fill-primary"),
        title: "#{point.label}: #{point.request_count} requests"
      }
    end)
  end

  defp chart_ticks(points) do
    bars = chart_bars(points)
    last_index = max(length(points) - 1, 0)

    points
    |> Enum.with_index()
    |> Enum.filter(fn {_point, index} -> rem(index, 15) == 0 or index == last_index end)
    |> Enum.map(fn {point, index} ->
      bar = Enum.at(bars, index)
      %{x: bar.x + bar.width / 2, y: @chart_height - 7, label: point.label}
    end)
  end

  defp chart_number(value) when is_float(value), do: Float.round(value, 2)
  defp chart_number(value) when is_integer(value), do: value

  defp recent_points(points) do
    points
    |> Enum.take(-10)
    |> Enum.reverse()
  end

  defp format_datetime(%DateTime{} = value) do
    date = Date.to_iso8601(DateTime.to_date(value))
    time = value.hour |> Integer.to_string() |> String.pad_leading(2, "0")
    minute = value.minute |> Integer.to_string() |> String.pad_leading(2, "0")
    date <> " " <> time <> ":" <> minute <> " UTC"
  end

  defp format_datetime(_value), do: ""

  defp format_latency(nil), do: "n/a"
  defp format_latency(value) when is_integer(value), do: "#{value} ms"

  defp format_latency(value) when is_float(value),
    do: "#{Float.round(value, 1)} ms"

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
