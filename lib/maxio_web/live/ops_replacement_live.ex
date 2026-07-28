defmodule MaxioWeb.OpsReplacementLive do
  use MaxioWeb, :live_view

  alias Maxio.Ops.ReplacementAutomationConsole

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Ops Replacement")
     |> assign(:console, ReplacementAutomationConsole.load())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="ops-replacement" class="space-y-6">
        <.header>
          Ops Replacement
          <:subtitle>Read-only replacement automation readiness and scheduler evidence</:subtitle>
        </.header>

        <div
          id="ops-replacement-readonly-boundary"
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

        <div id="ops-replacement-profile" class="rounded-box border border-base-300 bg-base-100">
          <div class="flex flex-col gap-4 border-b border-base-300 px-5 py-4 lg:flex-row lg:items-start lg:justify-between">
            <div class="min-w-0 space-y-2">
              <div class="flex flex-wrap items-center gap-2">
                <span id="ops-replacement-status" class={status_badge_class(@console.status)}>
                  <.icon name={status_icon(@console.status)} class="size-3.5" />
                  {@console.status}
                </span>
                <span
                  id="ops-replacement-profile-status"
                  class={status_badge_class(@console.profile.status)}
                >
                  profile: {@console.profile.status}
                </span>
                <span id="ops-replacement-profile-ready" class="badge badge-neutral badge-outline">
                  ready: {format_text(@console.profile.ready?)}
                </span>
              </div>
              <h2 class="break-words text-lg font-semibold">
                {@console.profile.profile}
              </h2>
              <div id="ops-replacement-next-action" class="text-xs text-base-content/60">
                next_action: {@console.profile.next_action}
              </div>
            </div>

            <div class="grid gap-2 sm:grid-cols-3 lg:w-[28rem]">
              <.metric_box
                id="ops-replacement-blocker-count"
                label="blockers"
                value={length(@console.blockers)}
              />
              <.metric_box
                id="ops-replacement-warning-count"
                label="warnings"
                value={length(@console.warnings)}
              />
              <.metric_box
                id="ops-replacement-evidence-status"
                label="evidence"
                value={@console.scheduler_evidence.status}
              />
            </div>
          </div>

          <div class="divide-y divide-base-300">
            <div
              :for={row <- @console.profile_rows}
              id={"ops-replacement-profile-row-#{row.id}"}
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
            id="ops-replacement-fresh-drive-heal"
            title="Fresh-Drive Heal Automation"
            empty_text="no fresh-drive heal automation evidence"
            rows={@console.fresh_drive_heal_rows}
          />
          <.rows_panel
            id="ops-replacement-rebalance"
            title="Rebalance Automation"
            empty_text="no rebalance automation evidence"
            rows={@console.rebalance_rows}
          />
        </div>

        <div
          id="ops-replacement-scheduler-evidence"
          class="rounded-box border border-base-300 bg-base-100"
        >
          <.panel_header title="Scheduler Evidence" status={@console.scheduler_evidence.status} />

          <div class="divide-y divide-base-300">
            <div
              :for={row <- @console.scheduler_evidence.rows}
              id={"ops-replacement-scheduler-evidence-row-#{row.id}"}
              class="grid gap-2 px-5 py-3 text-sm md:grid-cols-[13rem_1fr]"
            >
              <div class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                {row.label}
              </div>
              <div class="min-w-0 break-words text-base-content/75">{format_text(row.value)}</div>
            </div>
          </div>

          <div
            :if={@console.scheduler_evidence.scheduler_rows == []}
            id="ops-replacement-scheduler-evidence-empty"
            class="border-t border-base-300 px-5 py-8 text-center text-sm text-base-content/50"
          >
            no scheduler evidence rows
          </div>
          <div :if={@console.scheduler_evidence.scheduler_rows != []} class="overflow-x-auto">
            <table id="ops-replacement-scheduler-evidence-table" class="table table-sm">
              <thead>
                <tr>
                  <th>status</th>
                  <th>scheduler</th>
                  <th>health</th>
                  <th>nodes</th>
                  <th>reason</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @console.scheduler_evidence.scheduler_rows}
                  id={"ops-replacement-scheduler-evidence-scheduler-#{safe_id(row.id)}"}
                >
                  <td><span class={status_badge_class(row.status)}>{row.status}</span></td>
                  <td>{row.scheduler}</td>
                  <td>{row.health}</td>
                  <td class="max-w-80 break-words text-xs">
                    scheduled={row.scheduled_nodes}
                    <br /> effective={row.effective_nodes}
                    <br /> healthy={row.healthy_nodes}
                  </td>
                  <td class="max-w-72 break-words text-xs">{row.reason}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <.messages_panel
          id="ops-replacement-blockers"
          title="Blockers"
          tone="error"
          empty_text="no blockers"
          items={@console.blockers}
        />

        <.messages_panel
          id="ops-replacement-warnings"
          title="Warnings"
          tone="warning"
          empty_text="no warnings"
          items={@console.warnings}
        />

        <div
          id="ops-replacement-scheduler-states"
          class="rounded-box border border-base-300 bg-base-100"
        >
          <.panel_header title="Scheduler States" status={@console.scheduler_states.status} />
          <div
            :if={@console.scheduler_states.rows == []}
            id="ops-replacement-scheduler-states-empty"
            class="px-5 py-8 text-center text-sm text-base-content/50"
          >
            no scheduler state rows
          </div>
          <div :if={@console.scheduler_states.rows != []} class="overflow-x-auto">
            <table id="ops-replacement-scheduler-states-table" class="table table-sm">
              <thead>
                <tr>
                  <th>status</th>
                  <th>scheduler</th>
                  <th>node</th>
                  <th>last run</th>
                  <th>failures</th>
                  <th>backoff</th>
                  <th>error</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @console.scheduler_states.rows}
                  id={"ops-replacement-scheduler-state-#{safe_id(row.id)}"}
                >
                  <td><span class={status_badge_class(row.status)}>{row.status}</span></td>
                  <td>{row.scheduler}</td>
                  <td>{row.node}</td>
                  <td class="text-xs">
                    id={row.last_run_id}
                    <br /> started={row.last_started_at}
                    <br /> finished={row.last_finished_at}
                  </td>
                  <td>{row.consecutive_failures}</td>
                  <td class="text-xs">{row.backoff_until}</td>
                  <td class="max-w-72 break-words text-xs">{row.last_error_reason}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div id="ops-replacement-recent-runs" class="rounded-box border border-base-300 bg-base-100">
          <.panel_header title="Recent Scheduler Runs" status={@console.recent_runs.status} />
          <div
            :if={@console.recent_runs.rows == []}
            id="ops-replacement-recent-runs-empty"
            class="px-5 py-8 text-center text-sm text-base-content/50"
          >
            no recent scheduler runs
          </div>
          <div :if={@console.recent_runs.rows != []} class="overflow-x-auto">
            <table id="ops-replacement-recent-runs-table" class="table table-sm">
              <thead>
                <tr>
                  <th>status</th>
                  <th>scheduler</th>
                  <th>trigger</th>
                  <th>phase</th>
                  <th>job</th>
                  <th>time</th>
                  <th>summary</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @console.recent_runs.rows}
                  id={"ops-replacement-recent-run-#{safe_id(row.id)}"}
                >
                  <td><span class={status_badge_class(row.status)}>{row.status}</span></td>
                  <td>{row.scheduler}</td>
                  <td>{row.trigger}</td>
                  <td>{row.phase}</td>
                  <td class="max-w-48 break-words text-xs">{row.job_id}</td>
                  <td class="text-xs">
                    started={row.started_at}
                    <br /> finished={row.finished_at}
                    <br /> duration_ms={row.duration_ms}
                  </td>
                  <td class="max-w-96 break-words text-xs">{row.summary}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div
          id="ops-replacement-cross-links"
          class="rounded-box border border-base-300 bg-base-100 p-5"
        >
          <div class="mb-3 text-sm font-semibold text-base-content/75">Related Evidence</div>
          <div class="flex flex-wrap gap-2">
            <.link
              :for={link <- @console.cross_links}
              id={link.id}
              navigate={link.path}
              class="btn btn-outline btn-sm"
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

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :tone, :string, required: true
  attr :empty_text, :string, required: true
  attr :items, :list, required: true

  defp messages_panel(assigns) do
    ~H"""
    <div id={@id} class={message_panel_class(@tone)}>
      <h2 class={message_title_class(@tone)}>{@title}</h2>
      <div :if={@items == []} id={"#{@id}-empty"} class="mt-3 text-sm text-base-content/50">
        {@empty_text}
      </div>
      <div :if={@items != []} class="mt-3 space-y-2">
        <div
          :for={{item, index} <- Enum.with_index(@items)}
          id={"#{@id}-item-#{index}"}
          class="rounded-lg bg-base-100/70 px-3 py-2 text-sm"
        >
          {item}
        </div>
      </div>
    </div>
    """
  end

  defp status_badge_class(status) do
    case status do
      value when value in ["ok", "ready", "idle", "complete", "verified"] ->
        "badge badge-success badge-outline gap-1"

      value
      when value in [
             "attention",
             "stale",
             "warning",
             "skipped",
             "backoff",
             "empty",
             "not_requested"
           ] ->
        "badge badge-warning badge-outline gap-1"

      value when value in ["blocked", "failed", "error", "unavailable", "missing"] ->
        "badge badge-error badge-outline gap-1"

      _other ->
        "badge badge-neutral badge-outline gap-1"
    end
  end

  defp status_icon(status) do
    case status do
      value when value in ["ok", "ready", "complete", "verified"] ->
        "hero-check-circle"

      value when value in ["blocked", "failed", "error", "unavailable", "missing"] ->
        "hero-x-circle"

      _other ->
        "hero-exclamation-triangle"
    end
  end

  defp message_panel_class("error"),
    do: "rounded-box border border-error/30 bg-error/5 p-5"

  defp message_panel_class("warning"),
    do: "rounded-box border border-warning/30 bg-warning/5 p-5"

  defp message_panel_class(_tone), do: "rounded-box border border-base-300 bg-base-100 p-5"

  defp message_title_class("error"), do: "text-sm font-semibold text-error"
  defp message_title_class("warning"), do: "text-sm font-semibold text-warning"
  defp message_title_class(_tone), do: "text-sm font-semibold text-base-content/75"

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
