defmodule MaxioWeb.OpsClusterLive do
  use MaxioWeb, :live_view

  alias Maxio.Ops.ClusterHealthConsole

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Ops Cluster")
     |> assign(:console, ClusterHealthConsole.load())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="ops-cluster" class="space-y-6">
        <.header>
          Ops Cluster
          <:subtitle>Read-only cluster health and topology drift evidence</:subtitle>
        </.header>

        <div
          id="ops-cluster-readonly-boundary"
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

        <div id="ops-cluster-summary" class="rounded-box border border-base-300 bg-base-100">
          <div class="flex flex-col gap-4 border-b border-base-300 px-5 py-4 lg:flex-row lg:items-start lg:justify-between">
            <div class="min-w-0 space-y-2">
              <div class="flex flex-wrap items-center gap-2">
                <span id="ops-cluster-status" class={status_badge_class(@console.status)}>
                  <.icon name={status_icon(@console.status)} class="size-3.5" />
                  {@console.status}
                </span>
                <span
                  id="ops-cluster-drift-status"
                  class={status_badge_class(@console.topology_drift.status)}
                >
                  drift: {@console.topology_drift.status}
                </span>
                <span id="ops-cluster-node-status" class={status_badge_class(@console.nodes.status)}>
                  nodes: {@console.nodes.status}
                </span>
              </div>
              <h2 class="break-words text-lg font-semibold">
                Cluster Evidence
              </h2>
              <div class="text-xs text-base-content/60">
                topology: {@console.topology_drift.reason}
              </div>
            </div>

            <div class="grid gap-2 sm:grid-cols-3 lg:w-[28rem]">
              <.metric_box
                id="ops-cluster-summary-nodes"
                label="nodes"
                value={length(@console.nodes.rows)}
              />
              <.metric_box
                id="ops-cluster-summary-runtime"
                label="runtime"
                value={@console.runtime_topology.raw_status}
              />
              <.metric_box
                id="ops-cluster-summary-persisted"
                label="persisted"
                value={@console.persisted_topology.raw_status}
              />
            </div>
          </div>

          <div class="divide-y divide-base-300">
            <div
              :for={row <- @console.summary_rows}
              id={"ops-cluster-summary-row-#{row.id}"}
              class="grid gap-2 px-5 py-3 text-sm md:grid-cols-[13rem_1fr]"
            >
              <div class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                {row.label}
              </div>
              <div class="min-w-0 break-words text-base-content/75">{format_text(row.value)}</div>
            </div>
          </div>
        </div>

        <div id="ops-cluster-nodes" class="rounded-box border border-base-300 bg-base-100">
          <.panel_header title="Cluster Nodes" status={@console.nodes.status} />
          <div
            :if={@console.nodes.rows == []}
            id="ops-cluster-nodes-empty"
            class="px-5 py-8 text-center text-sm text-base-content/50"
          >
            no cluster nodes
          </div>
          <div :if={@console.nodes.rows != []} class="overflow-x-auto">
            <table id="ops-cluster-nodes-table" class="table table-sm">
              <thead>
                <tr>
                  <th>status</th>
                  <th>node</th>
                  <th>role</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @console.nodes.rows} id={"ops-cluster-node-#{safe_id(row.id)}"}>
                  <td><span class={status_badge_class(row.status)}>{row.status}</span></td>
                  <td>{row.node}</td>
                  <td>{row.role}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="grid gap-6 xl:grid-cols-2">
          <.rows_panel
            id="ops-cluster-runtime-topology"
            title="Runtime Topology"
            empty_text="no runtime topology evidence"
            rows={@console.runtime_topology.rows}
            status={@console.runtime_topology.status}
          />
          <.rows_panel
            id="ops-cluster-persisted-topology"
            title="Persisted Topology"
            empty_text="no persisted topology evidence"
            rows={@console.persisted_topology.rows}
            status={@console.persisted_topology.status}
          />
          <.rows_panel
            id="ops-cluster-topology-drift"
            title="Topology Drift"
            empty_text="no topology drift evidence"
            rows={@console.topology_drift.rows}
            status={@console.topology_drift.status}
          />
          <.rows_panel
            id="ops-cluster-locks"
            title="Lock Evidence"
            empty_text="no lock evidence"
            rows={@console.locks.rows}
            status={@console.locks.status}
          />
          <.rows_panel
            id="ops-cluster-cache-invalidation"
            title="Cache Invalidation"
            empty_text="no cache invalidation evidence"
            rows={@console.cache_invalidation.rows}
            status={@console.cache_invalidation.status}
          />
          <.rows_panel
            id="ops-cluster-pressure-local"
            title="Local Pressure"
            empty_text="no local pressure evidence"
            rows={@console.pressure.local.rows}
            status={@console.pressure.local.status}
          />
        </div>

        <div id="ops-cluster-pressure" class="rounded-box border border-base-300 bg-base-100">
          <.panel_header title="Cluster Pressure" status={@console.pressure.status} />

          <div class="grid gap-6 p-5 xl:grid-cols-2">
            <div class="rounded-lg border border-base-300">
              <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold text-base-content/75">
                Peer Pressure Cache
              </div>
              <div
                :if={@console.pressure.peers.rows == []}
                id="ops-cluster-pressure-peers-empty"
                class="px-5 py-8 text-center text-sm text-base-content/50"
              >
                no cached peer pressure snapshots
              </div>
              <div :if={@console.pressure.peers.rows != []} class="overflow-x-auto">
                <table id="ops-cluster-pressure-peers-table" class="table table-sm">
                  <thead>
                    <tr>
                      <th>status</th>
                      <th>node</th>
                      <th>s3</th>
                      <th>storage</th>
                      <th>combined</th>
                      <th>device</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={row <- @console.pressure.peers.rows}
                      id={"ops-cluster-pressure-peer-#{safe_id(row.id)}"}
                    >
                      <td><span class={status_badge_class(row.status)}>{row.status}</span></td>
                      <td>{row.node}</td>
                      <td>{row.s3_in_flight}</td>
                      <td>{row.storage_ops}</td>
                      <td>{row.combined}</td>
                      <td>{row.drive_device_io}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>

            <div class="rounded-lg border border-base-300">
              <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold text-base-content/75">
                Drive Device IO Cache
              </div>
              <div class="divide-y divide-base-300">
                <div
                  :for={row <- @console.pressure.device.rows}
                  id={"ops-cluster-device-row-#{row.id}"}
                  class="grid gap-2 px-4 py-3 text-sm md:grid-cols-[12rem_1fr]"
                >
                  <div class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                    {row.label}
                  </div>
                  <div class="min-w-0 break-words text-base-content/75">
                    {format_text(row.value)}
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div
            :if={@console.pressure.device.samples == []}
            id="ops-cluster-pressure-device-samples-empty"
            class="border-t border-base-300 px-5 py-8 text-center text-sm text-base-content/50"
          >
            no cached drive device samples
          </div>
          <div :if={@console.pressure.device.samples != []} class="overflow-x-auto">
            <table id="ops-cluster-pressure-device-samples-table" class="table table-sm">
              <thead>
                <tr>
                  <th>status</th>
                  <th>endpoint</th>
                  <th>set</th>
                  <th>pressure</th>
                  <th>queue</th>
                  <th>busy</th>
                  <th>reason</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @console.pressure.device.samples}
                  id={"ops-cluster-device-sample-#{safe_id(row.id)}"}
                >
                  <td><span class={status_badge_class(row.status)}>{row.status}</span></td>
                  <td class="max-w-96 break-words text-xs">{row.endpoint}</td>
                  <td>{row.set_id}</td>
                  <td>{row.pressure}</td>
                  <td>{row.queue_depth}</td>
                  <td>{row.busy_percent_x100}</td>
                  <td class="max-w-72 break-words text-xs">{row.reason}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div id="ops-cluster-cross-links" class="rounded-box border border-base-300 bg-base-100 p-5">
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
      value when value in ["ok", "ready", "alive", "configured", "active"] ->
        "badge badge-success badge-outline gap-1"

      value when value in ["attention", "empty", "no_topology", "missing", "partial"] ->
        "badge badge-warning badge-outline gap-1"

      value when value in ["blocked", "failed", "error", "unavailable"] ->
        "badge badge-error badge-outline gap-1"

      _other ->
        "badge badge-neutral badge-outline gap-1"
    end
  end

  defp status_icon(status) do
    case status do
      value when value in ["ok", "ready", "alive", "configured", "active"] -> "hero-check-circle"
      value when value in ["blocked", "failed", "error", "unavailable"] -> "hero-x-circle"
      _other -> "hero-exclamation-triangle"
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
