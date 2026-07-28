defmodule MaxioWeb.OpsObservabilityLive do
  use MaxioWeb, :live_view

  alias Maxio.Ops.ObservabilityConsole

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Ops Observability")
     |> assign(:console, ObservabilityConsole.load())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="ops-observability" class="space-y-6">
        <.header>
          Ops Observability
          <:subtitle>Read-only metrics, scrape, and dashboard readiness evidence</:subtitle>
        </.header>

        <div
          id="ops-observability-readonly-boundary"
          class="rounded-box border border-info/30 bg-info/5 p-4 text-sm"
        >
          <div class="flex items-start gap-3">
            <.icon name="hero-lock-closed" class="mt-0.5 size-5 shrink-0 text-info" />
            <div class="min-w-0 space-y-1">
              <div class="font-semibold text-info">read-only evidence boundary</div>
              <div class="text-xs text-base-content/65">
                {@console.readonly_boundary.message}
              </div>
              <div class="text-xs text-base-content/65">
                forbidden: {Enum.join(@console.readonly_boundary.forbidden, ", ")}
              </div>
            </div>
          </div>
        </div>

        <div id="ops-observability-summary" class="rounded-box border border-base-300 bg-base-100">
          <div class="flex flex-col gap-4 border-b border-base-300 px-5 py-4 lg:flex-row lg:items-start lg:justify-between">
            <div class="min-w-0 space-y-2">
              <div class="flex flex-wrap items-center gap-2">
                <span id="ops-observability-status" class={status_badge_class(@console.status)}>
                  <.icon name={status_icon(@console.status)} class="size-3.5" />
                  {@console.status}
                </span>
                <span class={status_badge_class(@console.prometheus.status)}>
                  prometheus: {@console.prometheus.status}
                </span>
                <span class={status_badge_class(@console.request_metrics.status)}>
                  request metrics: {@console.request_metrics.status}
                </span>
              </div>
              <h2 class="break-words text-lg font-semibold">Observability Readiness</h2>
              <div class="text-xs text-base-content/60">
                durable local metrics and MinIO-style scrape evidence
              </div>
            </div>

            <div class="grid gap-2 sm:grid-cols-3 lg:w-[28rem]">
              <.metric_box
                id="ops-observability-summary-endpoints"
                label="endpoints"
                value={length(@console.prometheus.endpoint_rows)}
              />
              <.metric_box
                id="ops-observability-summary-streams"
                label="streams"
                value={length(@console.request_metrics.rows)}
              />
              <.metric_box
                id="ops-observability-summary-recent"
                label="recent rows"
                value={length(@console.request_metrics.recent_rows)}
              />
            </div>
          </div>

          <div class="divide-y divide-base-300">
            <div
              :for={row <- @console.summary_rows}
              id={"ops-observability-summary-row-#{row.id}"}
              class="grid gap-2 px-5 py-3 text-sm md:grid-cols-[13rem_1fr]"
            >
              <div class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                {row.label}
              </div>
              <div class="min-w-0 break-words text-base-content/75">{format_text(row.value)}</div>
            </div>
          </div>
        </div>

        <div class="grid gap-6 xl:grid-cols-2">
          <.rows_panel
            id="ops-observability-prometheus"
            title="Prometheus Scrape Surface"
            empty_text="no prometheus evidence"
            rows={@console.prometheus.rows}
            status={@console.prometheus.status}
          >
            <:extra>
              <.evidence_table
                id="ops-observability-prometheus-endpoints"
                rows={@console.prometheus.endpoint_rows}
                empty_text="no prometheus endpoints"
                columns={[
                  {"status", :status},
                  {"method", :method},
                  {"path", :path},
                  {"family", :family}
                ]}
              />
            </:extra>
          </.rows_panel>

          <.rows_panel
            id="ops-observability-dashboard-stats"
            title="Dashboard Stats"
            empty_text="no dashboard stats"
            rows={@console.dashboard_stats.rows}
            status={@console.dashboard_stats.status}
          />
        </div>

        <.request_metrics_panel section={@console.request_metrics} />

        <.table_panel
          id="ops-observability-operator-commands"
          title="Operator Commands"
          status={@console.operator_commands.status}
          empty_text="no operator commands"
          rows={@console.operator_commands.rows}
          columns={[
            {"status", :status},
            {"label", :label},
            {"command", :command},
            {"boundary", :boundary}
          ]}
        />

        <div class="grid gap-6 xl:grid-cols-2">
          <.table_panel
            id="ops-observability-blockers"
            title="Blockers"
            status={@console.blockers.status}
            empty_text="no blockers"
            rows={@console.blockers.rows}
            columns={[
              {"status", :status},
              {"entry", :entry},
              {"kind", :kind},
              {"reason", :reason},
              {"detail", :detail}
            ]}
          />
          <.table_panel
            id="ops-observability-warnings"
            title="Warnings"
            status={@console.warnings.status}
            empty_text="no warnings"
            rows={@console.warnings.rows}
            columns={[
              {"status", :status},
              {"entry", :entry},
              {"kind", :kind},
              {"reason", :reason},
              {"detail", :detail}
            ]}
          />
        </div>

        <div
          id="ops-observability-cross-links"
          class="rounded-box border border-base-300 bg-base-100 p-5"
        >
          <div class="mb-3 text-sm font-semibold text-base-content/75">Related Evidence</div>
          <div class="flex flex-wrap gap-2">
            <.link
              :for={link <- @console.cross_links}
              id={link.id}
              navigate={link.path}
              class="inline-flex items-center rounded border border-base-300 px-3 py-1.5 text-sm font-medium text-base-content/70 transition hover:border-primary/50 hover:text-primary"
            >
              {link.label}
            </.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  slot :extra

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :empty_text, :string, required: true
  attr :rows, :list, required: true
  attr :status, :string, required: true

  defp rows_panel(assigns) do
    ~H"""
    <div id={@id} class="rounded-box border border-base-300 bg-base-100">
      <.panel_header title={@title} status={@status} />
      <div
        :if={@rows == []}
        id={"#{@id}-empty"}
        class="px-5 py-8 text-sm text-base-content/55"
      >
        {@empty_text}
      </div>
      <div :if={@rows != []} class="divide-y divide-base-300">
        <div
          :for={row <- @rows}
          id={"#{@id}-row-#{row.id}"}
          class="grid gap-2 px-5 py-3 text-sm md:grid-cols-[12rem_1fr]"
        >
          <div class="text-xs font-medium uppercase tracking-wide text-base-content/45">
            {row.label}
          </div>
          <div class="min-w-0 break-words text-base-content/75">{format_text(row.value)}</div>
        </div>
      </div>
      {render_slot(@extra)}
    </div>
    """
  end

  attr :section, :map, required: true

  defp request_metrics_panel(assigns) do
    ~H"""
    <div id="ops-observability-request-metrics" class="rounded-box border border-base-300 bg-base-100">
      <.panel_header title="Request Metrics Ledger" status={@section.status} />
      <div class="grid gap-6 p-5 xl:grid-cols-2">
        <.evidence_table
          id="ops-observability-request-metrics-streams"
          rows={@section.rows}
          empty_text="no request metric streams"
          columns={[
            {"status", :status},
            {"bucket", :bucket},
            {"filter", :filter_id},
            {"requests", :request_count},
            {"last seen", :last_seen_at},
            {"reason", :reason}
          ]}
        />
        <.evidence_table
          id="ops-observability-request-metrics-recent"
          rows={@section.recent_rows}
          empty_text="no recent request metric rows"
          columns={[
            {"status", :status},
            {"bucket", :bucket},
            {"filter", :filter_id},
            {"operation", :operation},
            {"status code", :status_code},
            {"requests", :request_count}
          ]}
        />
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :status, :string, required: true

  defp panel_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3 border-b border-base-300 px-5 py-3">
      <h2 class="text-sm font-semibold text-base-content/75">{@title}</h2>
      <span class={status_badge_class(@status)}>{@status}</span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :status, :string, required: true
  attr :empty_text, :string, required: true
  attr :rows, :list, required: true
  attr :columns, :list, required: true

  defp table_panel(assigns) do
    ~H"""
    <div id={@id} class="rounded-box border border-base-300 bg-base-100">
      <.panel_header title={@title} status={@status} />
      <div class="p-5">
        <.evidence_table
          id={"#{@id}-table"}
          rows={@rows}
          empty_text={@empty_text}
          columns={@columns}
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :empty_text, :string, required: true
  attr :columns, :list, required: true

  defp evidence_table(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@rows == []}
        id={"#{@id}-empty"}
        class="px-1 py-4 text-sm text-base-content/55"
      >
        {@empty_text}
      </div>
      <div :if={@rows != []} class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th :for={{label, _field} <- @columns}>{label}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} id={"#{@id}-row-#{row.id}"}>
              <td :for={{_label, field} <- @columns} class="max-w-xs break-words">
                <%= if field == :status do %>
                  <span class={status_badge_class(Map.get(row, field))}>
                    {format_text(Map.get(row, field))}
                  </span>
                <% else %>
                  {format_text(Map.get(row, field))}
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp metric_box(assigns) do
    ~H"""
    <div id={@id} class="rounded border border-base-300 bg-base-200/60 px-3 py-2">
      <div class="text-[0.65rem] font-medium uppercase tracking-wide text-base-content/45">
        {@label}
      </div>
      <div class="mt-1 truncate text-lg font-semibold">{format_text(@value)}</div>
    </div>
    """
  end

  defp format_text(nil), do: "-"
  defp format_text(""), do: "-"
  defp format_text(value) when is_binary(value), do: value

  defp format_text(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: to_string(value)

  defp format_text(value), do: inspect(value, limit: 8, printable_limit: 160)

  defp status_badge_class(status) do
    base = "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-semibold"

    case to_string(status || "unknown") do
      "ok" -> base <> " bg-success/15 text-success"
      "blocked" -> base <> " bg-error/15 text-error"
      "error" -> base <> " bg-error/15 text-error"
      "invalid" -> base <> " bg-error/15 text-error"
      "attention" -> base <> " bg-warning/15 text-warning"
      _other -> base <> " bg-base-300 text-base-content/60"
    end
  end

  defp status_icon(status) do
    case to_string(status || "unknown") do
      "ok" -> "hero-check-circle"
      "blocked" -> "hero-x-circle"
      "error" -> "hero-x-circle"
      "invalid" -> "hero-x-circle"
      "attention" -> "hero-exclamation-triangle"
      _other -> "hero-question-mark-circle"
    end
  end
end
