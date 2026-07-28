defmodule MaxioWeb.OpsRebalanceLive do
  use MaxioWeb, :live_view

  alias Maxio.Ops.RebalanceWorkflowConsole

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Ops Rebalance")
     |> assign(:console, empty_console())
     |> assign(:workflow, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_console(socket, params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="ops-rebalance" class="space-y-6">
        <.header>
          Ops Rebalance
          <:subtitle>Read-only rebalance / decommission workflow evidence</:subtitle>
        </.header>

        <div
          :if={@console.selection_notice}
          id="ops-rebalance-selection-warning"
          class="rounded-box border border-warning/30 bg-warning/5 p-4 text-sm"
        >
          <div class="flex items-start gap-3">
            <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-warning" />
            <div class="min-w-0 space-y-1">
              <div class="font-semibold text-warning">Job selection fallback</div>
              <div class="text-xs text-base-content/65">
                requested: {format_text(@console.selection_notice.requested)}
              </div>
              <div class="text-xs text-base-content/65">
                reason: {@console.selection_notice.reason}
              </div>
              <div class="text-xs text-base-content/65">
                showing: {format_text(@console.selection_notice.selected)}
              </div>
            </div>
          </div>
        </div>

        <div
          :if={@console.jobs == []}
          id="ops-rebalance-empty"
          class="rounded-box border border-dashed border-base-300 bg-base-100 px-6 py-12 text-center"
        >
          <.icon name="hero-arrow-path-rounded-square" class="mx-auto size-10 text-base-content/30" />
          <div class="mt-3 text-sm font-medium text-base-content/70">
            no rebalance or decommission jobs
          </div>
          <div class="mt-1 text-xs text-base-content/45">
            status: {@console.status}
          </div>
        </div>

        <div
          :if={@console.selected_job && @console.workflow}
          id="ops-rebalance-summary"
          class="rounded-box border border-base-300 bg-base-100 p-5"
        >
          <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
            <div class="min-w-0 space-y-3">
              <div class="flex flex-wrap items-center gap-2">
                <span id="ops-rebalance-status" class={status_badge_class(@workflow.status)}>
                  <.icon name={status_icon(@workflow.gate_status)} class="size-3.5" />
                  {@workflow.status}
                </span>
                <span id="ops-rebalance-gate-status" class={status_badge_class(@workflow.gate_status)}>
                  gate: {@workflow.gate_status}
                </span>
                <span id="ops-rebalance-phase" class="badge badge-neutral badge-outline">
                  phase: {@workflow.phase}
                </span>
              </div>

              <h2 id="ops-rebalance-job-id" class="break-all text-xl font-semibold">
                {@workflow.job_id}
              </h2>

              <div class="grid gap-2 text-xs text-base-content/55 md:grid-cols-2">
                <div id="ops-rebalance-job-kind">
                  kind: {format_text(@workflow.job_kind)}
                </div>
                <div id="ops-rebalance-target-set">
                  target_set_id: {format_text(@workflow.target_set_id)}
                </div>
                <div id="ops-rebalance-destination-set">
                  destination_set_id: {format_text(@workflow.destination_set_id)}
                </div>
                <div id="ops-rebalance-retired-state">
                  set_retired: {Map.get(@workflow, :set_retired?)} / pool_retired: {Map.get(
                    @workflow,
                    :pool_retired?
                  )}
                </div>
              </div>
            </div>

            <div class="grid gap-2 sm:grid-cols-3 lg:w-[24rem]">
              <.metric_box
                id="ops-rebalance-plan-scanned"
                label="plan scanned"
                value={@console.selected_job.plan_scanned}
              />
              <.metric_box
                id="ops-rebalance-progress-moved"
                label="moved"
                value={@console.selected_job.progress_moved}
              />
              <.metric_box
                id="ops-rebalance-cleanup-deleted"
                label="cleanup deleted"
                value={@console.selected_job.source_cleanup_deleted}
              />
            </div>
          </div>

          <div
            :if={not Map.get(@workflow, :available?)}
            id="ops-rebalance-summary-error"
            class="mt-4 rounded-lg border border-error/30 bg-error/5 px-4 py-3 text-sm text-error"
          >
            workflow summary could not be rendered
          </div>
        </div>

        <div
          :if={@console.selected_job && @console.workflow}
          id="ops-rebalance-next-action"
          class="rounded-box border border-base-300 bg-base-100 p-5"
        >
          <div class="mb-3 flex items-center gap-2 text-sm font-semibold text-base-content/75">
            <.icon name="hero-command-line" class="size-5" /> Next Action Evidence
          </div>
          <div class="break-words rounded-lg bg-base-200 px-3 py-2 text-xs text-base-content/75">
            {format_text(@workflow.next_action)}
          </div>
          <div
            :if={Map.get(@workflow, :destructive_next_action?)}
            id="ops-rebalance-destructive-boundary"
            class="mt-3 rounded-lg border border-error/30 bg-error/5 px-4 py-3 text-sm text-error"
          >
            <.icon name="hero-exclamation-triangle" class="mr-1 inline size-4" />
            destructive boundary: this page displays the next action as evidence only and does not execute it
          </div>
        </div>

        <div
          :if={@console.selected_job && @console.workflow}
          id="ops-rebalance-workflow-grid"
          class="grid gap-6 xl:grid-cols-2"
        >
          <.rows_panel
            id="ops-rebalance-runtime-topology"
            title="Runtime Topology"
            empty_text="no runtime topology evidence"
            rows={@workflow.runtime_topology_rows}
          />
          <.rows_panel
            id="ops-rebalance-deployment-topology"
            title="Deployment Topology"
            empty_text="no deployment topology evidence"
            rows={@workflow.deployment_topology_rows}
          />
          <.rows_panel
            id="ops-rebalance-audit"
            title="Rebalance Closure Audit"
            empty_text="no closure audit evidence"
            rows={@workflow.rebalance_audit_rows}
          />
          <.rows_panel
            id="ops-rebalance-closure"
            title="Recorded Closure"
            empty_text="no recorded closure evidence"
            rows={@workflow.rebalance_closure_rows}
          />
        </div>

        <div
          :if={@console.selected_job && @console.workflow && @workflow.rebalance_audit_examples != []}
          id="ops-rebalance-audit-examples"
          class="rounded-box border border-base-300 bg-base-100"
        >
          <div class="border-b border-base-300 px-5 py-3">
            <h2 class="text-sm font-semibold text-base-content/75">Audit Examples</h2>
          </div>
          <div class="divide-y divide-base-300">
            <div
              :for={{example, index} <- Enum.with_index(@workflow.rebalance_audit_examples)}
              id={"ops-rebalance-audit-example-#{index}"}
              class="grid gap-2 px-5 py-3 text-xs md:grid-cols-2"
            >
              <div :for={row <- example} class="min-w-0">
                <span class="text-base-content/45">{row.label}:</span>
                <span class="break-words text-base-content/75">{row.value}</span>
              </div>
            </div>
          </div>
        </div>

        <.messages_panel
          :if={@console.selected_job && @console.workflow}
          id="ops-rebalance-blockers"
          title="Blockers"
          tone="error"
          empty_text="no blockers"
          items={@workflow.blockers}
        />

        <.messages_panel
          :if={@console.selected_job && @console.workflow}
          id="ops-rebalance-warnings"
          title="Warnings"
          tone="warning"
          empty_text="no warnings"
          items={@workflow.warnings}
        />

        <div
          :if={@console.jobs != []}
          id="ops-rebalance-jobs"
          class="rounded-box border border-base-300 bg-base-100"
        >
          <div class="border-b border-base-300 px-5 py-3">
            <h2 class="text-sm font-semibold text-base-content/75">Recent Jobs</h2>
          </div>
          <div class="overflow-x-auto">
            <table id="ops-rebalance-jobs-table" class="table table-sm">
              <thead>
                <tr>
                  <th>status</th>
                  <th>job</th>
                  <th>kind</th>
                  <th>copy</th>
                  <th>cleanup</th>
                  <th>destructive</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={job <- @console.jobs}
                  id={"ops-rebalance-job-#{safe_id(job.id)}"}
                  class={job_row_class(job, @console.selected_job)}
                >
                  <td>
                    <span class={status_badge_class(job.status)}>{job.status}</span>
                  </td>
                  <td class="max-w-72 truncate">
                    <.link patch={~p"/ops/rebalance?#{%{job_id: job.id}}"} class="link link-primary">
                      {job.id}
                    </.link>
                  </td>
                  <td>{job.kind}</td>
                  <td>{format_text(job.data_movement_status)}</td>
                  <td>{format_text(job.source_cleanup_status)}</td>
                  <td class="text-xs">
                    topology: {format_text(job.topology_removal_status)}
                    <br /> remove: {format_text(job.physical_removal_status)}
                    <br /> purge: {format_text(job.physical_removal_purge_status)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp assign_console(socket, params) do
    console = RebalanceWorkflowConsole.load(params)

    socket
    |> assign(:console, console)
    |> assign(:workflow, console.workflow)
  end

  defp empty_console do
    %{
      status: "not_started",
      jobs: [],
      selected_job: nil,
      workflow: nil,
      selection_notice: nil
    }
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
          id={"#{@id}-row-#{safe_id(row.label)}"}
          class="grid gap-2 px-5 py-3 text-sm md:grid-cols-[11rem_1fr]"
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

  defp job_row_class(job, selected_job) do
    if selected_job && job.id == selected_job.id do
      "bg-primary/5"
    else
      ""
    end
  end

  defp status_badge_class(status) do
    case status do
      value when value in ["ok", "complete", "verified", "not_started"] ->
        "badge badge-success badge-outline gap-1"

      value
      when value in ["attention", "planned", "running", "in_progress", "moving", "checking"] ->
        "badge badge-warning badge-outline gap-1"

      value when value in ["blocked", "failed", "error", "canceled", "cancel_requested"] ->
        "badge badge-error badge-outline gap-1"

      _other ->
        "badge badge-neutral badge-outline gap-1"
    end
  end

  defp status_icon(status) do
    case status do
      value when value in ["ok", "complete", "verified"] -> "hero-check-circle"
      value when value in ["blocked", "failed", "error"] -> "hero-x-circle"
      _other -> "hero-exclamation-triangle"
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
