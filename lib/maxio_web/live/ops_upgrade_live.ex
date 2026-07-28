defmodule MaxioWeb.OpsUpgradeLive do
  use MaxioWeb, :live_view

  alias Maxio.Ops.UpgradeReadinessConsole

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Ops Upgrade")
     |> assign(:console, UpgradeReadinessConsole.load())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="ops-upgrade" class="space-y-6">
        <.header>
          Ops Upgrade
          <:subtitle>Read-only upgrade and rollback readiness evidence</:subtitle>
        </.header>

        <div
          id="ops-upgrade-readonly-boundary"
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

        <div id="ops-upgrade-summary" class="rounded-box border border-base-300 bg-base-100">
          <div class="flex flex-col gap-4 border-b border-base-300 px-5 py-4 lg:flex-row lg:items-start lg:justify-between">
            <div class="min-w-0 space-y-2">
              <div class="flex flex-wrap items-center gap-2">
                <span id="ops-upgrade-status" class={status_badge_class(@console.status)}>
                  <.icon name={status_icon(@console.status)} class="size-3.5" />
                  {@console.status}
                </span>
                <span
                  id="ops-upgrade-schema-status"
                  class={status_badge_class(@console.schema.status)}
                >
                  schema: {@console.schema.status}
                </span>
                <span
                  id="ops-upgrade-scheduler-status"
                  class={status_badge_class(@console.scheduler_ledger.status)}
                >
                  scheduler: {@console.scheduler_ledger.status}
                </span>
              </div>
              <h2 class="break-words text-lg font-semibold">Upgrade Readiness</h2>
              <div class="text-xs text-base-content/60">
                schema: {@console.schema.reason}
              </div>
            </div>

            <div class="grid gap-2 sm:grid-cols-3 lg:w-[28rem]">
              <.metric_box
                id="ops-upgrade-summary-code-migrations"
                label="code migrations"
                value={length(@console.schema.code_versions)}
              />
              <.metric_box
                id="ops-upgrade-summary-db-migrations"
                label="db migrations"
                value={length(@console.schema.db_versions)}
              />
              <.metric_box
                id="ops-upgrade-summary-rollback"
                label="rollback"
                value={length(@console.rollback_candidates.rows)}
              />
            </div>
          </div>

          <div class="divide-y divide-base-300">
            <div
              :for={row <- @console.summary_rows}
              id={"ops-upgrade-summary-row-#{row.id}"}
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
            id="ops-upgrade-release"
            title="Release Metadata"
            empty_text="no release evidence"
            rows={@console.release.rows}
            status={@console.release.status}
          />
          <.rows_panel
            id="ops-upgrade-schema"
            title="Schema Readiness"
            empty_text="no schema evidence"
            rows={@console.schema.rows}
            status={@console.schema.status}
          />
          <.rows_panel
            id="ops-upgrade-topology-revisions"
            title="Active Topology Revision"
            empty_text="no active topology revision evidence"
            rows={@console.topology_revisions.rows}
            status={@console.topology_revisions.status}
          />
          <.table_panel
            id="ops-upgrade-rollback-candidates"
            title="Rollback Candidates"
            status={@console.rollback_candidates.status}
            empty_text="no superseded topology revisions"
            rows={@console.rollback_candidates.rows}
            columns={[
              {"status", :status},
              {"revision", :revision_id},
              {"revision_status", :revision_status},
              {"activated", :activated_at},
              {"reason", :reason}
            ]}
          />
        </div>

        <.table_panel
          id="ops-upgrade-gate-artifacts"
          title="Gate Artifacts"
          status={@console.gate_artifacts.status}
          empty_text="no gate artifacts"
          rows={@console.gate_artifacts.rows}
          columns={[
            {"status", :status},
            {"file", :file_name},
            {"gate", :gate_status},
            {"run", :run_id},
            {"generated", :generated_at},
            {"reason", :reason}
          ]}
        />

        <.table_panel
          id="ops-upgrade-rehearsal-bundles"
          title="P0 Rehearsal Bundles"
          status={@console.rehearsal_bundles.status}
          empty_text="no P0 rehearsal bundles"
          rows={@console.rehearsal_bundles.rows}
          columns={[
            {"status", :status},
            {"file", :file_name},
            {"gate", :gate_status},
            {"run", :run_id},
            {"replacement", :replacement_mode},
            {"scheduler", :scheduler_mode}
          ]}
        />

        <div id="ops-upgrade-scheduler-ledger" class="rounded-box border border-base-300 bg-base-100">
          <.panel_header title="Scheduler Ledger" status={@console.scheduler_ledger.status} />

          <div class="grid gap-6 p-5 xl:grid-cols-3">
            <.mini_table
              id="ops-upgrade-scheduler-states"
              title="States"
              empty_text="no scheduler states"
              rows={@console.scheduler_ledger.states.rows}
              columns={[
                {"status", :status},
                {"scheduler", :scheduler},
                {"state", :state_status},
                {"alert", :alert_status},
                {"backoff", :backoff_until}
              ]}
            />
            <.mini_table
              id="ops-upgrade-scheduler-runs"
              title="Recent Runs"
              empty_text="no scheduler runs"
              rows={@console.scheduler_ledger.runs.rows}
              columns={[
                {"status", :status},
                {"scheduler", :scheduler},
                {"trigger", :trigger},
                {"run", :run_status},
                {"finished", :finished_at}
              ]}
            />
            <.mini_table
              id="ops-upgrade-scheduler-rollups"
              title="Rollups"
              empty_text="no scheduler rollups"
              rows={@console.scheduler_ledger.rollups.rows}
              columns={[
                {"status", :status},
                {"scheduler", :scheduler},
                {"trigger", :trigger},
                {"runs", :run_count},
                {"healthy", :healthy_count}
              ]}
            />
          </div>
        </div>

        <div id="ops-upgrade-cross-links" class="rounded-box border border-base-300 bg-base-100 p-5">
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
        class="px-5 py-8 text-center text-sm text-base-content/50"
      >
        {@empty_text}
      </div>
      <div :if={@rows != []} class="divide-y divide-base-300">
        <div
          :for={row <- @rows}
          id={"#{@id}-row-#{row.id}"}
          class="grid gap-2 px-5 py-3 text-sm md:grid-cols-[13rem_1fr]"
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
      <.mini_table
        id={"#{@id}-table-wrap"}
        title={@title}
        empty_text={@empty_text}
        rows={@rows}
        columns={@columns}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :empty_text, :string, required: true
  attr :rows, :list, required: true
  attr :columns, :list, required: true

  defp mini_table(assigns) do
    ~H"""
    <div id={@id} class="min-w-0">
      <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold text-base-content/75">
        {@title}
      </div>
      <div
        :if={@rows == []}
        id={"#{@id}-empty"}
        class="px-5 py-8 text-center text-sm text-base-content/50"
      >
        {@empty_text}
      </div>
      <div :if={@rows != []} class="overflow-x-auto">
        <table id={"#{@id}-table"} class="table table-sm">
          <thead>
            <tr>
              <th :for={{label, _field} <- @columns}>{label}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} id={"#{@id}-row-#{safe_id(Map.get(row, :id))}"}>
              <td :for={{_label, field} <- @columns} class="max-w-80 break-words text-xs">
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
    <div id={@id} class="rounded-lg border border-base-300 bg-base-200/50 px-3 py-3">
      <div class="text-[0.68rem] uppercase tracking-wide text-base-content/45">{@label}</div>
      <div class="mt-1 truncate text-lg font-semibold text-base-content/85">
        {format_text(@value)}
      </div>
    </div>
    """
  end

  defp status_badge_class(status) do
    case status do
      value when value in ["ok", "ready", "active"] ->
        "badge badge-success badge-outline gap-1"

      value when value in ["attention", "empty", "missing", "stale"] ->
        "badge badge-warning badge-outline gap-1"

      value when value in ["blocked", "failed", "error", "invalid", "unavailable"] ->
        "badge badge-error badge-outline gap-1"

      _other ->
        "badge badge-neutral badge-outline gap-1"
    end
  end

  defp status_icon(status) do
    case status do
      value when value in ["ok", "ready", "active"] ->
        "hero-check-circle"

      value when value in ["blocked", "failed", "error", "invalid", "unavailable"] ->
        "hero-x-circle"

      _other ->
        "hero-exclamation-triangle"
    end
  end

  defp safe_id(nil), do: "unknown"

  defp safe_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      id -> id
    end
  end

  defp format_text(nil), do: "-"
  defp format_text(""), do: "-"
  defp format_text(value), do: to_string(value)
end
