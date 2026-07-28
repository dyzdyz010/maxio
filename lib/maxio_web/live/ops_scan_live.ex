defmodule MaxioWeb.OpsScanLive do
  use MaxioWeb, :live_view

  alias Maxio.Ops.ScanEvidenceConsole

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Ops Scan")
     |> assign(:console, ScanEvidenceConsole.load())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="ops-scan" class="space-y-6">
        <.header>
          Ops Scan
          <:subtitle>Read-only scanner, reconcile, and drive-health evidence</:subtitle>
        </.header>

        <div
          id="ops-scan-readonly-boundary"
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

        <div class="grid gap-6 xl:grid-cols-2">
          <.rows_panel
            id="ops-scan-authority"
            title="Authority & Scanner Config"
            empty_text="no authority evidence"
            rows={@console.authority_rows}
          />
          <.rows_panel
            id="ops-scan-topology"
            title="Runtime Topology"
            empty_text="no topology evidence"
            rows={@console.topology_rows}
          />
        </div>

        <div id="ops-scan-usage-snapshots" class="rounded-box border border-base-300 bg-base-100">
          <.panel_header title="Usage Snapshots" status={@console.usage_snapshots.status} />
          <div
            :if={@console.usage_snapshots.rows == []}
            id="ops-scan-usage-empty"
            class="px-5 py-8 text-center text-sm text-base-content/50"
          >
            no usage snapshots
          </div>
          <div :if={@console.usage_snapshots.rows != []} class="overflow-x-auto">
            <table id="ops-scan-usage-table" class="table table-sm">
              <thead>
                <tr>
                  <th>status</th>
                  <th>bucket</th>
                  <th>objects</th>
                  <th>bytes</th>
                  <th>scanned</th>
                  <th>age_ms</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @console.usage_snapshots.rows} id={"ops-scan-usage-bucket-#{row.id}"}>
                  <td><span class={status_badge_class(row.status)}>{row.status}</span></td>
                  <td>{row.bucket}</td>
                  <td>{row.object_count}</td>
                  <td>{row.total_size}</td>
                  <td>{format_text(row.scanned_at)}</td>
                  <td>{format_text(row.age_ms)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div id="ops-scan-drive-health" class="rounded-box border border-base-300 bg-base-100">
          <.panel_header title="Drive Health Snapshot" status={@console.drive_health.status} />
          <div class="grid gap-2 border-b border-base-300 px-5 py-4 sm:grid-cols-4 lg:grid-cols-7">
            <.metric_box
              id="ops-scan-drive-health-total"
              label="total"
              value={@console.drive_health.counts.total}
            />
            <.metric_box
              id="ops-scan-drive-health-online"
              label="online"
              value={@console.drive_health.counts.online}
            />
            <.metric_box
              id="ops-scan-drive-health-suspect"
              label="suspect"
              value={@console.drive_health.counts.suspect}
            />
            <.metric_box
              id="ops-scan-drive-health-offline"
              label="offline"
              value={@console.drive_health.counts.offline}
            />
            <.metric_box
              id="ops-scan-drive-health-heal"
              label="heal"
              value={@console.drive_health.counts.heal_required}
            />
            <.metric_box
              id="ops-scan-drive-health-replace"
              label="replace"
              value={@console.drive_health.counts.identity_replacements}
            />
            <.metric_box
              id="ops-scan-drive-health-errors"
              label="id errors"
              value={@console.drive_health.counts.identity_errors}
            />
          </div>
          <div class="px-5 py-2 text-xs text-base-content/50">
            source: {@console.drive_health.source}
          </div>
          <div
            :if={@console.drive_health.rows == []}
            id="ops-scan-drive-health-empty"
            class="px-5 py-8 text-center text-sm text-base-content/50"
          >
            no runtime drive health observations
          </div>
          <div :if={@console.drive_health.rows != []} class="overflow-x-auto">
            <table id="ops-scan-drive-health-table" class="table table-sm">
              <thead>
                <tr>
                  <th>status</th>
                  <th>endpoint</th>
                  <th>set</th>
                  <th>failures</th>
                  <th>heal</th>
                  <th>identity</th>
                  <th>reason</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @console.drive_health.rows}
                  id={"ops-scan-drive-health-row-#{row.id}"}
                >
                  <td><span class={status_badge_class(row.status)}>{row.status}</span></td>
                  <td class="max-w-96 break-words text-xs">{row.endpoint}</td>
                  <td>{row.set_id}</td>
                  <td>{row.failure_count}</td>
                  <td>{Map.get(row, :heal_required?)}</td>
                  <td>
                    replace={Map.get(row, :identity_replacement_detected?)} heal={Map.get(
                      row,
                      :identity_heal_required?
                    )} error={Map.get(row, :identity_error?)}
                  </td>
                  <td class="max-w-64 break-words text-xs">{row.last_reason}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div id="ops-scan-drive-identities" class="rounded-box border border-base-300 bg-base-100">
          <.panel_header title="Drive Identity Snapshot" status={@console.drive_identities.status} />
          <div class="grid gap-2 border-b border-base-300 px-5 py-4 sm:grid-cols-3">
            <.metric_box
              id="ops-scan-drive-identities-total"
              label="total"
              value={@console.drive_identities.counts.total}
            />
            <.metric_box
              id="ops-scan-drive-identities-heal"
              label="heal required"
              value={@console.drive_identities.counts.heal_required}
            />
            <.metric_box
              id="ops-scan-drive-identities-replace"
              label="replacement"
              value={@console.drive_identities.counts.replacements}
            />
          </div>
          <div class="px-5 py-2 text-xs text-base-content/50">
            source: {@console.drive_identities.source}; drive UUIDs are fingerprinted
          </div>
          <div
            :if={@console.drive_identities.rows == []}
            id="ops-scan-drive-identities-empty"
            class="px-5 py-8 text-center text-sm text-base-content/50"
          >
            no persisted drive identities
          </div>
          <div :if={@console.drive_identities.rows != []} class="overflow-x-auto">
            <table id="ops-scan-drive-identities-table" class="table table-sm">
              <thead>
                <tr>
                  <th>endpoint</th>
                  <th>generation</th>
                  <th>set</th>
                  <th>fingerprints</th>
                  <th>state</th>
                  <th>last seen</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @console.drive_identities.rows}
                  id={"ops-scan-drive-identities-row-#{row.id}"}
                >
                  <td class="max-w-96 break-words text-xs">{row.endpoint}</td>
                  <td>{row.generation}</td>
                  <td>{row.set_id}:{row.endpoint_index}</td>
                  <td class="text-xs">
                    current={row.drive_uuid}
                    <br /> previous={row.previous_drive_uuid}
                  </td>
                  <td>
                    replacement={Map.get(row, :replacement_detected?)} heal={Map.get(
                      row,
                      :identity_heal_required?
                    )}
                  </td>
                  <td class="text-xs">{format_text(row.last_seen_at)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div id="ops-scan-archived-evidence" class="rounded-box border border-base-300 bg-base-100">
          <.panel_header title="Archived Gate Evidence" status={@console.archived_evidence.status} />
          <div
            :if={@console.archived_evidence.latest_artifact}
            id="ops-scan-archived-latest"
            class="grid gap-2 border-b border-base-300 px-5 py-3 text-xs text-base-content/60 md:grid-cols-4"
          >
            <div>file: {@console.archived_evidence.latest_artifact.file_name}</div>
            <div>run: {@console.archived_evidence.latest_artifact.run_id}</div>
            <div>generated: {@console.archived_evidence.latest_artifact.generated_at}</div>
            <div>gate: {@console.archived_evidence.latest_artifact.gate_status}</div>
          </div>
          <div
            :for={warning <- @console.archived_evidence.warnings}
            id={"ops-scan-archived-warning-#{warning.id}"}
            class="border-b border-warning/30 bg-warning/5 px-5 py-3 text-sm text-warning"
          >
            {warning.reason}: {warning.generated_at}
          </div>
          <div
            :if={@console.archived_evidence.rows == []}
            id="ops-scan-archived-evidence-empty"
            class="px-5 py-8 text-center text-sm text-base-content/50"
          >
            no archived scanner or fresh-drive evidence
          </div>
          <div :if={@console.archived_evidence.rows != []} class="divide-y divide-base-300">
            <div
              :for={row <- @console.archived_evidence.rows}
              id={"ops-scan-archived-row-#{row.id}"}
              class="px-5 py-4"
            >
              <div class="flex flex-wrap items-center gap-2">
                <span class={status_badge_class(row.status)}>{row.status}</span>
                <span class="text-sm font-semibold">{row.title}</span>
                <span class="text-xs text-base-content/45">{row.task}</span>
              </div>
              <div class="mt-1 text-xs text-base-content/55">
                artifact={row.artifact_file_name} run={row.artifact_run_id} check={row.check_id}
              </div>
              <div class="mt-3 grid gap-2 md:grid-cols-2">
                <div :for={field <- row.fields} class="rounded-lg bg-base-200/60 px-3 py-2 text-xs">
                  <span class="font-medium text-base-content/50">{field.label}</span>
                  <span class="ml-2 break-words text-base-content/80">{field.value}</span>
                </div>
              </div>
            </div>
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

  defp rows_panel(assigns) do
    ~H"""
    <div id={@id} class="rounded-box border border-base-300 bg-base-100">
      <div class="border-b border-base-300 px-5 py-3">
        <h2 class="text-sm font-semibold text-base-content/75">{@title}</h2>
      </div>
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
          class="grid gap-2 px-5 py-3 text-sm md:grid-cols-[14rem_1fr]"
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
      value when value in ["ok", "online"] ->
        "badge badge-success badge-outline gap-1"

      value when value in ["attention", "stale", "missing", "suspect", "empty"] ->
        "badge badge-warning badge-outline gap-1"

      value when value in ["blocked", "error", "failed", "offline"] ->
        "badge badge-error badge-outline gap-1"

      _other ->
        "badge badge-neutral badge-outline gap-1"
    end
  end

  defp format_text(nil), do: "-"
  defp format_text(""), do: "-"
  defp format_text(value), do: to_string(value)
end
