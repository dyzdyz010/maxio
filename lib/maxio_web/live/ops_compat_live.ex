defmodule MaxioWeb.OpsCompatLive do
  use MaxioWeb, :live_view

  alias Maxio.Ops.CompatMatrixConsole

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Ops Compat")
     |> assign(:console, CompatMatrixConsole.load(%{}, artifacts_fun: fn _ -> [] end))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, assign(socket, :console, CompatMatrixConsole.load(params))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="ops-compat" class="space-y-6">
        <.header>
          Ops Compat
          <:subtitle>Read-only S3 compatibility and external client evidence</:subtitle>
        </.header>

        <div
          id="ops-compat-readonly-boundary"
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

        <div id="ops-compat-summary" class="rounded-box border border-base-300 bg-base-100">
          <div class="flex flex-col gap-4 border-b border-base-300 px-5 py-4 lg:flex-row lg:items-start lg:justify-between">
            <div class="min-w-0 space-y-2">
              <div class="flex flex-wrap items-center gap-2">
                <span id="ops-compat-status" class={status_badge_class(@console.status)}>
                  <.icon name={status_icon(@console.status)} class="size-3.5" />
                  {@console.status}
                </span>
                <span class={status_badge_class(@console.internal_suites.status)}>
                  suites: {@console.internal_suites.status}
                </span>
                <span class={status_badge_class(@console.external_clients.status)}>
                  external: {@console.external_clients.status}
                </span>
              </div>
              <h2 class="break-words text-lg font-semibold">Compatibility Evidence</h2>
              <div class="text-xs text-base-content/60">
                selected: {selected_file(@console.selected_artifact)}
              </div>
            </div>

            <div class="grid gap-2 sm:grid-cols-3 lg:w-[28rem]">
              <.metric_box
                id="ops-compat-summary-artifacts"
                label="artifacts"
                value={length(@console.artifacts.rows)}
              />
              <.metric_box
                id="ops-compat-summary-suites"
                label="suites"
                value={length(@console.internal_suites.rows)}
              />
              <.metric_box
                id="ops-compat-summary-external"
                label="external"
                value={length(@console.external_clients.rows)}
              />
            </div>
          </div>

          <div class="divide-y divide-base-300">
            <div
              :for={row <- @console.summary_rows}
              id={"ops-compat-summary-row-#{row.id}"}
              class="grid gap-2 px-5 py-3 text-sm md:grid-cols-[13rem_1fr]"
            >
              <div class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                {row.label}
              </div>
              <div class="min-w-0 break-words text-base-content/75">{format_text(row.value)}</div>
            </div>
          </div>
        </div>

        <div
          :if={@console.selection_warning}
          id="ops-compat-selection-warning"
          class="rounded-box border border-warning/30 bg-warning/10 p-4 text-sm"
        >
          <div class="flex items-start gap-3">
            <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-warning" />
            <div class="min-w-0">
              <div class="font-semibold text-warning">artifact selection warning</div>
              <div class="break-words text-xs text-base-content/70">
                requested={@console.selection_warning.requested} reason={@console.selection_warning.reason} showing={@console.selection_warning.showing}
              </div>
            </div>
          </div>
        </div>

        <.artifact_table id="ops-compat-artifacts" section={@console.artifacts} />

        <div class="grid gap-6 xl:grid-cols-2">
          <.rows_panel
            id="ops-compat-artifact-provenance"
            title="Artifact Provenance"
            empty_text="no artifact provenance"
            rows={@console.artifact_provenance.rows}
            status={@console.artifact_provenance.status}
          />
          <.rows_panel
            id="ops-compat-streaming-stress"
            title="Streaming Stress"
            empty_text="no streaming stress evidence"
            rows={@console.streaming_stress.rows}
            status={@console.streaming_stress.status}
          />
        </div>

        <.table_panel
          id="ops-compat-internal-suites"
          title="Internal Suites"
          status={@console.internal_suites.status}
          empty_text="no internal suite evidence"
          rows={@console.internal_suites.rows}
          columns={[
            {"status", :status},
            {"suite", :suite},
            {"mode", :mode},
            {"tests", :tests},
            {"failures", :failures},
            {"reason", :reason}
          ]}
        />

        <.table_panel
          id="ops-compat-external-clients"
          title="External Clients"
          status={@console.external_clients.status}
          empty_text="no external client evidence"
          rows={@console.external_clients.rows}
          columns={[
            {"status", :status},
            {"client", :client},
            {"label", :label},
            {"executable", :executable},
            {"detail", :detail},
            {"reason", :reason}
          ]}
        />

        <.table_panel
          id="ops-compat-external-smoke"
          title="External Smoke"
          status={@console.external_smoke.status}
          empty_text="no external smoke evidence"
          rows={@console.external_smoke.rows}
          columns={[
            {"status", :status},
            {"client", :client},
            {"steps", :steps},
            {"scenarios", :scenarios},
            {"duration", :duration_ms},
            {"reason", :reason}
          ]}
        />

        <div class="grid gap-6 xl:grid-cols-2">
          <.table_panel
            id="ops-compat-blockers"
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
            id="ops-compat-warnings"
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

        <div id="ops-compat-cross-links" class="rounded-box border border-base-300 bg-base-100 p-5">
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

  attr :id, :string, required: true
  attr :section, :map, required: true

  defp artifact_table(assigns) do
    ~H"""
    <div id={@id} class="rounded-box border border-base-300 bg-base-100">
      <.panel_header title="Compatibility Artifacts" status={@section.status} />
      <div
        :if={@section.rows == []}
        id={"#{@id}-empty"}
        class="px-5 py-8 text-sm text-base-content/55"
      >
        no compatibility matrix artifacts
      </div>
      <div :if={@section.rows != []} class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>status</th>
              <th>file</th>
              <th>gate</th>
              <th>generated</th>
              <th>suites</th>
              <th>external</th>
              <th>reason</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @section.rows} id={"#{@id}-row-#{row.id}"}>
              <td><span class={status_badge_class(row.status)}>{row.status}</span></td>
              <td>
                <.link patch={~p"/ops/compat?artifact=#{row.file_name}"} class="link link-primary">
                  {row.file_name}
                </.link>
              </td>
              <td>{row.gate_status}</td>
              <td>{row.generated_at}</td>
              <td>{row.suites}</td>
              <td>{row.external_clients}</td>
              <td class="max-w-xs break-words">{row.reason}</td>
            </tr>
          </tbody>
        </table>
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
      <div
        :if={@rows == []}
        id={"#{@id}-empty"}
        class="px-5 py-8 text-sm text-base-content/55"
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

  defp selected_file(nil), do: "-"
  defp selected_file(artifact), do: Map.get(artifact, :file_name, "-")

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
