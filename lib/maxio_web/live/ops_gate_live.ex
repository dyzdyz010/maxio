defmodule MaxioWeb.OpsGateLive do
  use MaxioWeb, :live_view

  alias Maxio.Ops.Gate.Artifacts
  alias Maxio.Ops.RehearsalBundle.Artifacts, as: RehearsalBundleArtifacts

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Ops Gate")
     |> assign_artifacts(params)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_artifacts(socket, params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <div id="ops-gate" class="space-y-6">
        <.header>
          Ops Gate
          <:subtitle>M8 运维门禁 artifacts</:subtitle>
        </.header>

        <div
          :if={@artifacts == []}
          id="ops-gate-empty"
          class="rounded-box border border-dashed border-base-300 bg-base-100 px-6 py-12 text-center"
        >
          <.icon name="hero-shield-exclamation" class="mx-auto size-10 text-base-content/30" />
          <div class="mt-3 text-sm font-medium text-base-content/70">暂无 ops gate artifacts</div>
          <div class="mt-1 text-xs text-base-content/45">
            artifacts/m8_ops_gate_*.json
          </div>
        </div>

        <div
          :if={@selected_artifact}
          id="ops-gate-summary"
          class="rounded-box border border-base-300 bg-base-100 p-5"
        >
          <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
            <div class="min-w-0 space-y-2">
              <div class="flex flex-wrap items-center gap-2">
                <span id="ops-gate-status" class={status_badge_class(@selected_artifact.gate_status)}>
                  <.icon name={status_icon(@selected_artifact.gate_status)} class="size-3.5" />
                  {@selected_artifact.gate_status}
                </span>
                <span
                  :if={@selected_artifact.status == "invalid"}
                  id="ops-gate-invalid"
                  class="badge badge-error badge-outline gap-1"
                >
                  <.icon name="hero-exclamation-triangle" class="size-3.5" />
                  {@selected_artifact.error_reason}
                </span>
              </div>
              <h2 id="ops-gate-run-id" class="truncate text-xl font-semibold">
                {format_text(@selected_artifact.run_id || @selected_artifact.file_name)}
              </h2>
              <div class="grid gap-2 text-xs text-base-content/55 md:grid-cols-2">
                <div id="ops-gate-generated-at">
                  generated_at: {format_text(@selected_artifact.generated_at)}
                </div>
                <div id="ops-gate-file-name">
                  file: {format_text(@selected_artifact.file_name)}
                </div>
                <div id="ops-gate-node">
                  node: {format_text(@selected_artifact.node)}
                </div>
                <div id="ops-gate-mix-env">
                  MIX_ENV: {format_text(@selected_artifact.mix_env)}
                </div>
              </div>
              <div
                :if={@selected_artifact.command}
                id="ops-gate-command"
                class="break-words rounded-lg bg-base-200 px-3 py-2 text-xs text-base-content/70"
              >
                {@selected_artifact.command}
              </div>
            </div>

            <div id="ops-gate-counts" class="grid grid-cols-5 gap-2 lg:w-[28rem]">
              <.count_box
                id="ops-gate-count-total"
                label="total"
                value={@selected_artifact.counts.total}
              />
              <.count_box id="ops-gate-count-ok" label="ok" value={@selected_artifact.counts.ok} />
              <.count_box
                id="ops-gate-count-attention"
                label="attention"
                value={@selected_artifact.counts.attention}
              />
              <.count_box
                id="ops-gate-count-blocked"
                label="blocked"
                value={@selected_artifact.counts.blocked}
              />
              <.count_box
                id="ops-gate-count-error"
                label="error"
                value={@selected_artifact.counts.error}
              />
            </div>
          </div>
        </div>

        <div
          :if={@artifact_selection_notice}
          id="ops-gate-selection-warning"
          class="rounded-box border border-warning/30 bg-warning/5 p-4 text-sm"
        >
          <div class="flex items-start gap-3">
            <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-warning" />
            <div class="min-w-0 space-y-1">
              <div class="font-semibold text-warning">Artifact selection fallback</div>
              <div class="text-xs text-base-content/65">
                requested: {format_text(@artifact_selection_notice.requested)}
              </div>
              <div class="text-xs text-base-content/65">
                reason: {@artifact_selection_notice.reason}
              </div>
              <div class="text-xs text-base-content/65">
                showing: {format_text(@artifact_selection_notice.selected)}
              </div>
            </div>
          </div>
        </div>

        <div
          :if={@artifacts != []}
          id="ops-gate-artifacts"
          class="rounded-box border border-base-300 bg-base-100"
        >
          <div class="border-b border-base-300 px-5 py-3">
            <h2 class="text-sm font-semibold text-base-content/75">Artifacts</h2>
          </div>
          <div class="overflow-x-auto">
            <table id="ops-gate-artifacts-table" class="table table-sm">
              <thead>
                <tr>
                  <th>status</th>
                  <th>run</th>
                  <th>generated</th>
                  <th>checks</th>
                  <th>file</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={artifact <- @artifacts}
                  id={"ops-gate-artifact-#{safe_id(artifact.file_name)}"}
                  class={artifact_row_class(artifact, @selected_artifact)}
                >
                  <td>
                    <span class={status_badge_class(artifact.gate_status)}>
                      {artifact.gate_status}
                    </span>
                  </td>
                  <td class="max-w-64 truncate">
                    <.link
                      patch={~p"/ops/gate?#{%{artifact: artifact.file_name}}"}
                      class="link link-primary"
                    >
                      {format_text(artifact.run_id || artifact.file_name)}
                    </.link>
                  </td>
                  <td>{format_text(artifact.generated_at || artifact.modified_at)}</td>
                  <td>{artifact.counts.total}</td>
                  <td class="max-w-64 truncate text-xs text-base-content/55">
                    {artifact.file_name}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <.artifact_provenance_panel
          artifact={@selected_artifact}
          recency_notice={@artifact_recency_notice}
        />
        <.live_rehearsal_bundles_panel
          bundles={@live_rehearsal_bundles}
          related_bundle={@related_live_rehearsal_bundle}
        />
        <.evidence_matrix_panel artifact={@selected_artifact} />
        <.evidence_sources_panel artifact={@selected_artifact} />
        <.check_evidence_panel artifact={@selected_artifact} />
        <.operator_runbook_panel artifact={@selected_artifact} />

        <div
          :if={@selected_artifact && @selected_artifact.blockers != []}
          id="ops-gate-blockers"
          class="rounded-box border border-error/30 bg-error/5 p-5"
        >
          <h2 class="mb-3 text-sm font-semibold text-error">Blockers</h2>
          <div class="space-y-2">
            <.gate_item
              :for={{item, index} <- Enum.with_index(@selected_artifact.blockers)}
              item={item}
              id={"ops-gate-blocker-#{index}"}
            />
          </div>
        </div>

        <div
          :if={@selected_artifact && @selected_artifact.warnings != []}
          id="ops-gate-warnings"
          class="rounded-box border border-warning/30 bg-warning/5 p-5"
        >
          <h2 class="mb-3 text-sm font-semibold text-warning">Warnings</h2>
          <div class="space-y-2">
            <.gate_item
              :for={{item, index} <- Enum.with_index(@selected_artifact.warnings)}
              item={item}
              id={"ops-gate-warning-#{index}"}
            />
          </div>
        </div>

        <div
          :if={@selected_artifact}
          id="ops-gate-checks"
          class="rounded-box border border-base-300 bg-base-100"
        >
          <div class="border-b border-base-300 px-5 py-3">
            <h2 class="text-sm font-semibold text-base-content/75">Checks</h2>
          </div>
          <div
            :if={@selected_artifact.checks == []}
            id="ops-gate-checks-empty"
            class="px-5 py-8 text-center text-sm text-base-content/50"
          >
            no checks
          </div>
          <div :if={@selected_artifact.checks != []} class="overflow-x-auto">
            <table id="ops-gate-checks-table" class="table table-sm">
              <thead>
                <tr>
                  <th>status</th>
                  <th>check</th>
                  <th>mode</th>
                  <th>exit</th>
                  <th>duration</th>
                  <th>command</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={check <- @selected_artifact.checks}
                  id={"ops-gate-check-#{safe_id(check.id)}"}
                >
                  <td>
                    <span class={status_badge_class(check.status)}>
                      {check.status}
                    </span>
                  </td>
                  <td>
                    <div class="font-medium">{check.id}</div>
                    <div class="text-xs text-base-content/50">{check.task}</div>
                  </td>
                  <td>{check.mode}</td>
                  <td>{format_text(check.exit_status)}</td>
                  <td>{format_duration(check.duration_ms)}</td>
                  <td class="max-w-80 break-words text-xs text-base-content/60">
                    {format_text(check.command)}
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

  attr :bundles, :list, default: []
  attr :related_bundle, :map, default: nil

  defp live_rehearsal_bundles_panel(assigns) do
    assigns =
      assigns
      |> assign(:related_summary_rows, bundle_summary_rows(assigns.related_bundle))
      |> assign(:related_child_results, bundle_child_results(assigns.related_bundle))
      |> assign(:related_boundary_warnings, bundle_boundary_warnings(assigns.related_bundle))

    ~H"""
    <section id="ops-gate-live-bundles" class="rounded-box border border-base-300 bg-base-100">
      <div class="border-b border-base-300 px-5 py-4">
        <h2 class="text-sm font-semibold text-base-content/75">P0 Live Rehearsal Bundle</h2>
        <p class="text-xs text-base-content/50">
          archived replacement, scheduler, and ops-gate rehearsal evidence
        </p>
      </div>

      <div
        :if={@bundles == []}
        id="ops-gate-live-bundles-empty"
        class="px-5 py-8 text-center text-sm text-base-content/50"
      >
        no P0 live rehearsal bundle artifacts in the current artifact directory
      </div>

      <div :if={@bundles != []} class="overflow-x-auto border-b border-base-300">
        <table id="ops-gate-live-bundles-table" class="table table-sm">
          <thead>
            <tr>
              <th>status</th>
              <th>run</th>
              <th>generated</th>
              <th>replacement</th>
              <th>scheduler</th>
              <th>file</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={bundle <- @bundles}
              id={"ops-gate-live-bundle-#{safe_id(bundle.file_name)}"}
              class={bundle_row_class(bundle, @related_bundle)}
            >
              <td>
                <span class={status_badge_class(bundle.gate_status)}>
                  {format_text(bundle.gate_status)}
                </span>
              </td>
              <td class="max-w-64 truncate">{format_text(bundle.run_id || bundle.file_name)}</td>
              <td>{format_text(bundle.generated_at || bundle.modified_at)}</td>
              <td>{format_text(bundle.replacement_mode)}</td>
              <td>{format_text(bundle.scheduler_mode)}</td>
              <td class="max-w-64 truncate text-xs text-base-content/55">
                {format_text(bundle.file_name)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div
        :if={@related_bundle}
        id="ops-gate-related-bundle"
        class="border-b border-base-300"
      >
        <div class="grid gap-3 px-5 py-4 md:grid-cols-2">
          <div
            :for={row <- @related_summary_rows}
            id={"ops-gate-related-bundle-summary-#{safe_id(row.id)}"}
            class="min-w-0"
          >
            <div class="text-[11px] uppercase text-base-content/45">{row.label}</div>
            <div class="break-words text-xs text-base-content/70">{format_text(row.value)}</div>
          </div>
        </div>

        <div
          :if={@related_boundary_warnings != []}
          id="ops-gate-related-bundle-boundary"
          class="border-t border-warning/20 bg-warning/5 px-5 py-4"
        >
          <div class="flex items-start gap-3">
            <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-warning" />
            <div class="min-w-0 space-y-2">
              <div class="text-sm font-semibold text-warning">Explicit rehearsal boundary</div>
              <div
                :for={warning <- @related_boundary_warnings}
                id={"ops-gate-related-bundle-warning-#{safe_id(warning.id)}"}
                class="break-words text-xs text-base-content/65"
              >
                {format_text(warning.label)}: {format_text(warning.value)}
              </div>
            </div>
          </div>
        </div>

        <div :if={@related_child_results != []} class="overflow-x-auto border-t border-base-300">
          <table id="ops-gate-related-bundle-results" class="table table-sm">
            <thead>
              <tr>
                <th>child</th>
                <th>status</th>
                <th>exit</th>
                <th>gate</th>
                <th>artifact</th>
                <th>command</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={child <- @related_child_results}
                id={"ops-gate-related-bundle-child-#{safe_id(child.id)}"}
              >
                <td class="font-medium">{format_text(child.label)}</td>
                <td>
                  <span class={status_badge_class(child.status)}>
                    {format_text(child.status)}
                  </span>
                </td>
                <td>{format_text(child.exit_code)}</td>
                <td>{format_text(child.gate_status)}</td>
                <td class="max-w-80 break-words text-xs text-base-content/60">
                  {format_text(child.artifact_path)}
                </td>
                <td class="max-w-96 break-words text-xs text-base-content/60">
                  {format_text(child.command)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div
        :if={@related_bundle == nil and @bundles != []}
        id="ops-gate-related-bundle-empty"
        class="px-5 py-8 text-center text-sm text-base-content/50"
      >
        no bundle artifact references the selected ops gate artifact
      </div>
    </section>
    """
  end

  attr :artifact, :map, default: nil
  attr :recency_notice, :map, default: nil

  defp artifact_provenance_panel(assigns) do
    assigns = assign(assigns, :provenance, artifact_provenance(assigns.artifact))

    ~H"""
    <section id="ops-gate-artifact-provenance" class="rounded-box border border-base-300 bg-base-100">
      <div class="border-b border-base-300 px-5 py-4">
        <h2 class="text-sm font-semibold text-base-content/75">Artifact Provenance</h2>
        <p class="text-xs text-base-content/50">
          archived artifact metadata from the current artifact directory
        </p>
      </div>

      <div
        :if={@recency_notice}
        id="ops-gate-artifact-recency-warning"
        class="border-b border-warning/20 bg-warning/5 px-5 py-4"
      >
        <div class="flex items-start gap-3">
          <.icon name="hero-clock" class="mt-0.5 size-5 shrink-0 text-warning" />
          <div class="min-w-0 space-y-1">
            <div class="text-sm font-semibold text-warning">Archived selection is not latest</div>
            <div class="text-xs text-base-content/65">
              selected: {format_text(@recency_notice.selected_file)}
            </div>
            <div class="text-xs text-base-content/65">
              latest: {format_text(@recency_notice.latest_file)}
            </div>
            <div class="text-xs text-base-content/65">
              latest generated_at: {format_text(@recency_notice.latest_generated_at)}
            </div>
            <div class="text-xs text-base-content/65">
              latest gate_status: {format_text(@recency_notice.latest_gate_status)}
            </div>
          </div>
        </div>
      </div>

      <div
        :if={@provenance == nil}
        id="ops-gate-artifact-provenance-empty"
        class="px-5 py-8 text-center text-sm text-base-content/50"
      >
        no artifact provenance in selected artifact
      </div>

      <div :if={@provenance != nil} class="overflow-x-auto">
        <table id="ops-gate-artifact-provenance-table" class="table table-sm">
          <tbody>
            <tr
              :for={row <- provenance_rows(@provenance)}
              id={"ops-gate-artifact-provenance-row-#{safe_id(row.id)}"}
            >
              <th class="w-48 text-xs uppercase text-base-content/45">{row.label}</th>
              <td class="max-w-96 break-words text-xs text-base-content/65">
                {format_text(row.value)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :artifact, :map, default: nil

  defp evidence_matrix_panel(assigns) do
    assigns = assign(assigns, :summary, evidence_summary(assigns.artifact))

    ~H"""
    <section id="ops-gate-evidence-matrix" class="rounded-box border border-base-300 bg-base-100">
      <div class="flex flex-col gap-3 border-b border-base-300 px-5 py-4 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <h2 class="text-sm font-semibold text-base-content/75">Evidence Matrix</h2>
          <p class="text-xs text-base-content/50">
            read-only rehearsal coverage for operator gates
          </p>
        </div>
        <div id="ops-gate-evidence-profile" class="flex flex-wrap gap-2 text-xs">
          <span class="badge badge-ghost">profile: {format_text(@summary.profile)}</span>
          <span class="badge badge-ghost">artifacts: {@summary.artifact_count}</span>
          <span class="badge badge-ghost">read-only: {format_bool(@summary.read_only)}</span>
        </div>
      </div>

      <div id="ops-gate-required-kinds" class="grid grid-cols-3 border-b border-base-300 md:w-96">
        <.count_box
          id="ops-gate-required-covered"
          label="covered"
          value={@summary.covered_required_count}
        />
        <.count_box
          id="ops-gate-required-missing"
          label="missing"
          value={@summary.missing_count}
        />
        <.count_box
          id="ops-gate-required-total"
          label="required"
          value={@summary.required_count}
        />
      </div>

      <div
        :if={!@summary.available}
        id="ops-gate-evidence-empty"
        class="px-5 py-8 text-center text-sm text-base-content/50"
      >
        no evidence matrix in selected artifact
      </div>

      <div :if={@summary.available} class="overflow-x-auto">
        <table id="ops-gate-evidence-table" class="table table-sm">
          <thead>
            <tr>
              <th>status</th>
              <th>kind</th>
              <th>coverage</th>
              <th>check</th>
              <th>issues</th>
              <th>source</th>
            </tr>
          </thead>
          <tbody>
            <.evidence_kind_row :for={row <- @summary.rows} row={row} />
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :artifact, :map, default: nil

  defp check_evidence_panel(assigns) do
    assigns = assign(assigns, :rows, check_evidence_rows(assigns.artifact))

    ~H"""
    <section id="ops-gate-check-evidence" class="rounded-box border border-base-300 bg-base-100">
      <div class="border-b border-base-300 px-5 py-4">
        <h2 class="text-sm font-semibold text-base-content/75">Check Evidence</h2>
        <p class="text-xs text-base-content/50">
          archived parsed-output drilldown for operator checks
        </p>
      </div>

      <div
        :if={@rows == []}
        id="ops-gate-check-evidence-empty"
        class="px-5 py-8 text-center text-sm text-base-content/50"
      >
        no parsed check evidence in selected artifact
      </div>

      <div :if={@rows != []} class="overflow-x-auto">
        <table id="ops-gate-check-evidence-table" class="table table-sm">
          <thead>
            <tr>
              <th>status</th>
              <th>check</th>
              <th>evidence</th>
              <th>field</th>
              <th>value</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @rows}
              id={"ops-gate-check-evidence-field-#{safe_id(row.row_id)}"}
            >
              <td>
                <span class={status_badge_class(row.status)}>
                  {row.status}
                </span>
              </td>
              <td>
                <div class="font-medium">{format_text(row.check_id)}</div>
                <div class="text-xs text-base-content/50">{format_text(row.task)}</div>
              </td>
              <td>
                <div
                  id={"ops-gate-check-evidence-kind-#{safe_id(row.row_id)}"}
                  class="font-medium"
                >
                  {format_text(row.title)}
                </div>
                <div class="text-xs text-base-content/50">{format_text(row.kind)}</div>
              </td>
              <td>{row.field_label}</td>
              <td class="max-w-96 break-words text-xs text-base-content/65">
                {format_text(row.field_value)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :artifact, :map, default: nil

  defp operator_runbook_panel(assigns) do
    assigns = assign(assigns, :runbook, operator_runbook(assigns.artifact))

    ~H"""
    <section id="ops-gate-runbook" class="rounded-box border border-base-300 bg-base-100">
      <div class="border-b border-base-300 px-5 py-4">
        <h2 class="text-sm font-semibold text-base-content/75">Operator Runbook</h2>
        <p class="text-xs text-base-content/50">
          archived next-step evidence for the selected gate run
        </p>
      </div>

      <div
        :if={@runbook.rows == [] and @runbook.warnings == []}
        id="ops-gate-runbook-empty"
        class="px-5 py-8 text-center text-sm text-base-content/50"
      >
        no operator runbook evidence in selected artifact
      </div>

      <div
        :if={@runbook.warnings != []}
        id="ops-gate-runbook-mutating-boundary"
        class="border-b border-warning/20 bg-warning/5 px-5 py-4"
      >
        <div class="flex items-start gap-3">
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-warning" />
          <div class="min-w-0 space-y-2">
            <div class="text-sm font-semibold text-warning">Explicit operator boundary</div>
            <div
              :for={warning <- @runbook.warnings}
              id={"ops-gate-runbook-boundary-#{safe_id(warning.id)}"}
              class="break-words text-xs text-base-content/65"
            >
              {format_text(warning.label)}: {format_text(warning.value)}
            </div>
          </div>
        </div>
      </div>

      <div :if={@runbook.rows != []} class="overflow-x-auto">
        <table id="ops-gate-runbook-table" class="table table-sm">
          <thead>
            <tr>
              <th>kind</th>
              <th>field</th>
              <th>check</th>
              <th>value</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @runbook.rows} id={"ops-gate-runbook-row-#{safe_id(row.id)}"}>
              <td>
                <div class="font-medium">{format_text(row.kind)}</div>
                <span :if={row.status} class={status_badge_class(row.status)}>
                  {row.status}
                </span>
              </td>
              <td>{format_text(row.label)}</td>
              <td>
                <div>{format_text(row.check_id)}</div>
                <div class="text-xs text-base-content/50">{format_text(row.task)}</div>
              </td>
              <td class="max-w-96 break-words text-xs text-base-content/65">
                {format_text(row.value)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :artifact, :map, default: nil

  defp evidence_sources_panel(assigns) do
    assigns = assign(assigns, :rows, evidence_source_rows(assigns.artifact))

    ~H"""
    <section id="ops-gate-evidence-sources" class="rounded-box border border-base-300 bg-base-100">
      <div class="border-b border-base-300 px-5 py-4">
        <h2 class="text-sm font-semibold text-base-content/75">Evidence Sources</h2>
        <p class="text-xs text-base-content/50">
          read-only source traceability for gate checks
        </p>
      </div>

      <div
        :if={@rows == []}
        id="ops-gate-evidence-sources-empty"
        class="px-5 py-8 text-center text-sm text-base-content/50"
      >
        no evidence sources in selected artifact
      </div>

      <div :if={@rows != []} class="overflow-x-auto">
        <table id="ops-gate-evidence-sources-table" class="table table-sm">
          <thead>
            <tr>
              <th>status</th>
              <th>kind</th>
              <th>scenario</th>
              <th>check</th>
              <th>source</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @rows}
              id={"ops-gate-evidence-source-#{safe_id(row.row_id)}"}
            >
              <td>
                <span class={status_badge_class(row.status)}>
                  {row.status}
                </span>
              </td>
              <td>
                <div class="font-medium">{format_text(row.kind)}</div>
                <div
                  :if={row.source_status}
                  id={"ops-gate-evidence-source-status-#{safe_id(row.row_id)}"}
                  class="text-xs text-base-content/50"
                >
                  {row.source_status}
                </div>
              </td>
              <td id={"ops-gate-evidence-source-scenario-#{safe_id(row.row_id)}"}>
                {format_text(row.scenario)}
              </td>
              <td>
                <div>{format_text(row.check_id)}</div>
                <div class="text-xs text-base-content/50">{format_text(row.task)}</div>
              </td>
              <td
                id={"ops-gate-evidence-source-path-#{safe_id(row.row_id)}"}
                class="max-w-96 break-words text-xs text-base-content/60"
              >
                {format_source_path(row.artifact_path)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :row, :map, required: true

  defp evidence_kind_row(assigns) do
    ~H"""
    <tr id={"ops-gate-kind-row-#{safe_id(@row.kind)}"}>
      <td>
        <span
          id={"ops-gate-kind-status-#{safe_id(@row.kind)}"}
          class={status_badge_class(@row.status)}
        >
          {@row.status}
        </span>
      </td>
      <td>
        <div class="font-medium">{@row.kind}</div>
        <div :if={@row.scenario} class="text-xs text-base-content/50">
          {format_text(@row.scenario)}
        </div>
      </td>
      <td>
        <div class="flex flex-wrap gap-1">
          <span :if={@row.required} class="badge badge-outline badge-xs">required</span>
          <span :if={@row.covered} class="badge badge-success badge-outline badge-xs">covered</span>
          <span :if={@row.missing} class="badge badge-error badge-outline badge-xs">missing</span>
        </div>
      </td>
      <td>
        <div>{format_text(@row.check_id)}</div>
        <div class="text-xs text-base-content/50">{format_text(@row.task)}</div>
      </td>
      <td>
        <div class="text-xs text-base-content/60">
          blockers:
          <span id={"ops-gate-kind-blockers-#{safe_id(@row.kind)}"}>{@row.blocker_count}</span>
          · warnings:
          <span id={"ops-gate-kind-warnings-#{safe_id(@row.kind)}"}>{@row.warning_count}</span>
        </div>
        <div :if={@row.blockers != []} class="mt-1 space-y-1">
          <div
            :for={{item, index} <- Enum.with_index(@row.blockers)}
            id={"ops-gate-kind-blocker-#{safe_id(@row.kind)}-#{index}"}
            class="rounded bg-error/10 px-2 py-1 text-xs text-error"
          >
            {item.reason}
          </div>
        </div>
        <div :if={@row.warnings != []} class="mt-1 space-y-1">
          <div
            :for={{item, index} <- Enum.with_index(@row.warnings)}
            id={"ops-gate-kind-warning-#{safe_id(@row.kind)}-#{index}"}
            class="rounded bg-warning/10 px-2 py-1 text-xs text-warning"
          >
            {item.reason}
          </div>
        </div>
      </td>
      <td class="max-w-80 break-words text-xs text-base-content/60">
        {format_text(@row.artifact_path)}
      </td>
    </tr>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp count_box(assigns) do
    ~H"""
    <div id={@id} class="min-w-0 rounded-lg border border-base-300 px-3 py-2 text-center">
      <div class="truncate text-[11px] uppercase text-base-content/45">{@label}</div>
      <div class="text-lg font-semibold">{@value}</div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :item, :map, required: true

  defp gate_item(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg bg-base-100/80 px-3 py-2 text-sm">
      <div class="font-medium">{@item.reason}</div>
      <div :if={@item.check || @item.task} class="mt-1 text-xs text-base-content/55">
        {format_text(@item.check)} · {format_text(@item.task)}
      </div>
    </div>
    """
  end

  defp assign_artifacts(socket, params) do
    artifacts = Artifacts.list_recent()
    bundles = RehearsalBundleArtifacts.list_recent()
    {selected, selection_notice} = selected_artifact(artifacts, Map.get(params, "artifact"))
    latest = List.first(artifacts)
    related_bundle = RehearsalBundleArtifacts.related_bundle(bundles, selected)

    socket
    |> assign(:artifacts, artifacts)
    |> assign(:selected_artifact, selected)
    |> assign(:latest_artifact, latest)
    |> assign(:live_rehearsal_bundles, bundles)
    |> assign(:related_live_rehearsal_bundle, related_bundle)
    |> assign(:artifact_selection_notice, selection_notice)
    |> assign(:artifact_recency_notice, artifact_recency_notice(selected, latest))
  end

  defp selected_artifact(artifacts, file_name) do
    latest = List.first(artifacts)

    case normalize_requested_artifact(file_name) do
      :none ->
        {latest, nil}

      {:ok, requested} ->
        case Enum.find(artifacts, &(&1.file_name == requested)) do
          nil -> {latest, selection_notice("not_found", requested, latest)}
          artifact -> {artifact, nil}
        end

      {:error, requested} ->
        {latest, selection_notice("invalid_parameter", requested, latest)}
    end
  end

  defp normalize_requested_artifact(nil), do: :none

  defp normalize_requested_artifact(value) when is_binary(value) do
    requested = String.trim(value)

    cond do
      requested == "" -> {:error, display_requested_artifact(value)}
      String.length(requested) > 255 -> {:error, display_requested_artifact(value)}
      not safe_artifact_token?(requested) -> {:error, display_requested_artifact(value)}
      true -> {:ok, requested}
    end
  end

  defp normalize_requested_artifact(value), do: {:error, display_requested_artifact(value)}

  defp safe_artifact_token?(value) do
    value not in [".", ".."] and
      not String.contains?(value, ["/", "\\", ".."]) and
      Path.basename(value) == value
  end

  defp selection_notice(reason, requested, selected) do
    %{
      reason: reason,
      requested: display_requested_artifact(requested),
      selected: if(selected, do: selected.file_name)
    }
  end

  defp display_requested_artifact(value) when is_binary(value) do
    value
    |> String.replace(~r/[\r\n\t]/, " ")
    |> String.slice(0, 128)
  end

  defp display_requested_artifact(value) do
    value
    |> inspect(limit: 10, printable_limit: 128, charlists: :as_lists)
    |> display_requested_artifact()
  end

  defp status_badge_class(status) do
    [
      "badge gap-1 whitespace-nowrap",
      case status do
        "ok" -> "badge-success"
        "attention" -> "badge-warning"
        "blocked" -> "badge-error"
        "error" -> "badge-error badge-outline"
        "invalid" -> "badge-error badge-outline"
        _other -> "badge-ghost"
      end
    ]
  end

  defp status_icon("ok"), do: "hero-check-circle"
  defp status_icon("attention"), do: "hero-exclamation-triangle"
  defp status_icon("blocked"), do: "hero-x-circle"
  defp status_icon("error"), do: "hero-x-circle"
  defp status_icon("invalid"), do: "hero-exclamation-triangle"
  defp status_icon(_status), do: "hero-question-mark-circle"

  defp artifact_row_class(artifact, selected) do
    [
      selected && artifact.file_name == selected.file_name && "bg-primary/5"
    ]
  end

  defp bundle_row_class(bundle, related) do
    [
      related && bundle.file_name == related.file_name && "bg-primary/5"
    ]
  end

  defp format_text(nil), do: "n/a"
  defp format_text(value) when is_binary(value) and value == "", do: "n/a"
  defp format_text(value), do: to_string(value)

  defp format_bool(true), do: "yes"
  defp format_bool(false), do: "no"
  defp format_bool(_value), do: "n/a"

  defp format_duration(nil), do: "n/a"
  defp format_duration(value), do: "#{value} ms"

  defp format_source_path(nil), do: "-"
  defp format_source_path(""), do: "-"
  defp format_source_path(value), do: to_string(value)

  defp bundle_summary_rows(nil), do: []

  defp bundle_summary_rows(bundle) do
    [
      %{id: "file-name", label: "file", value: bundle.file_name},
      %{id: "run-id", label: "run", value: bundle.run_id},
      %{id: "gate-status", label: "gate status", value: bundle.gate_status},
      %{id: "generated-at", label: "generated", value: bundle.generated_at},
      %{id: "replacement-mode", label: "replacement", value: bundle.replacement_mode},
      %{id: "scheduler-mode", label: "scheduler mode", value: bundle.scheduler_mode},
      %{id: "scheduler", label: "scheduler", value: bundle.scheduler},
      %{
        id: "bundle-artifact-path",
        label: "bundle path",
        value: Map.get(bundle.artifact_paths, "bundle")
      },
      %{
        id: "ops-gate-artifact-path",
        label: "ops gate path",
        value: Map.get(bundle.artifact_paths, "ops_gate")
      }
    ]
    |> Enum.filter(&present?(&1.value))
  end

  defp bundle_child_results(%{child_results: child_results}) when is_list(child_results),
    do: child_results

  defp bundle_child_results(_bundle), do: []

  defp bundle_boundary_warnings(%{boundary_warnings: warnings}) when is_list(warnings),
    do: warnings

  defp bundle_boundary_warnings(_bundle), do: []

  defp artifact_provenance(%{artifact_provenance: provenance}) when is_map(provenance),
    do: provenance

  defp artifact_provenance(_artifact), do: nil

  defp provenance_rows(provenance) do
    [
      %{id: "file-name", label: "file", value: Map.get(provenance, :file_name)},
      %{
        id: "archived-artifact-path",
        label: "archived path",
        value: Map.get(provenance, :archived_artifact_path)
      },
      %{id: "schema-version", label: "schema", value: Map.get(provenance, :schema_version)},
      %{id: "git-sha", label: "git sha", value: Map.get(provenance, :git_sha)},
      %{id: "node", label: "node", value: Map.get(provenance, :node)},
      %{id: "mix-env", label: "mix env", value: Map.get(provenance, :mix_env)},
      %{id: "generated-at", label: "generated", value: Map.get(provenance, :generated_at)},
      %{id: "modified-at", label: "modified", value: Map.get(provenance, :modified_at)},
      %{id: "size-bytes", label: "size", value: Map.get(provenance, :size_bytes)},
      %{id: "gate-status", label: "gate status", value: Map.get(provenance, :gate_status)},
      %{id: "error-reason", label: "error", value: Map.get(provenance, :error_reason)}
    ]
    |> Enum.filter(&present?(&1.value))
  end

  defp artifact_recency_notice(nil, _latest), do: nil
  defp artifact_recency_notice(_selected, nil), do: nil

  defp artifact_recency_notice(selected, latest) do
    if selected.file_name != latest.file_name do
      %{
        selected_file: selected.file_name,
        latest_file: latest.file_name,
        latest_generated_at: latest.generated_at || latest.modified_at,
        latest_gate_status: latest.gate_status
      }
    end
  end

  defp evidence_summary(nil) do
    %{
      available: false,
      profile: nil,
      read_only: nil,
      artifact_count: 0,
      required_count: 0,
      covered_required_count: 0,
      missing_count: 0,
      rows: []
    }
  end

  defp evidence_summary(%{ops_evidence_matrix: matrix, checks: checks}) when is_map(matrix) do
    required = string_list(Map.get(matrix, "required_rehearsal_kinds"))
    covered = string_list(Map.get(matrix, "covered_rehearsal_kinds"))
    missing = string_list(Map.get(matrix, "missing_rehearsal_kinds"))
    rows = evidence_rows(required, covered, missing, checks)

    %{
      available: required != [] or covered != [] or missing != [] or rows != [],
      profile: Map.get(matrix, "profile"),
      read_only: Map.get(matrix, "read_only"),
      artifact_count: int_value(Map.get(matrix, "artifact_count")),
      required_count: length(required),
      covered_required_count:
        length(Enum.filter(required, &(&1 in covered and &1 not in missing))),
      missing_count: length(missing),
      rows: rows
    }
  end

  defp evidence_summary(%{checks: checks}) do
    rows = evidence_rows([], [], [], checks)

    %{
      available: rows != [],
      profile: nil,
      read_only: nil,
      artifact_count: 0,
      required_count: 0,
      covered_required_count: 0,
      missing_count: 0,
      rows: rows
    }
  end

  defp evidence_summary(_artifact), do: evidence_summary(nil)

  defp operator_runbook(%{operator_runbook: %{rows: rows, warnings: warnings} = runbook})
       when is_list(rows) and is_list(warnings) do
    %{
      rows: rows,
      warnings: warnings,
      mutating_boundary: Map.get(runbook, :mutating_boundary, warnings != [])
    }
  end

  defp operator_runbook(_artifact), do: %{rows: [], warnings: [], mutating_boundary: false}

  defp check_evidence_rows(%{checks: checks}) when is_list(checks) do
    checks
    |> Enum.with_index()
    |> Enum.flat_map(fn {check, check_index} ->
      check_evidence_rows_for_check(check, check_index)
    end)
  end

  defp check_evidence_rows(_artifact), do: []

  defp check_evidence_rows_for_check(%{evidence_summary: %{fields: fields}} = check, check_index)
       when is_list(fields) do
    fields
    |> Enum.filter(&evidence_field?/1)
    |> Enum.with_index()
    |> Enum.map(fn {field, field_index} ->
      %{
        row_id:
          Enum.join(
            [check_index, check.id, check.evidence_summary.kind, field_index, field.label],
            "-"
          ),
        check_id: check.id,
        task: check.task,
        status: check.status,
        kind: check.evidence_summary.kind,
        title: check.evidence_summary.title,
        field_label: field.label,
        field_value: field.value
      }
    end)
  end

  defp check_evidence_rows_for_check(_check, _check_index), do: []

  defp evidence_field?(%{label: label, value: value}), do: present?(label) and present?(value)
  defp evidence_field?(_field), do: false

  defp evidence_rows(required, covered, missing, checks) when is_list(checks) do
    check_kinds =
      checks
      |> Enum.map(& &1.evidence_kind)
      |> Enum.reject(&is_nil/1)

    (required ++ covered ++ missing ++ check_kinds)
    |> Enum.uniq()
    |> Enum.map(&evidence_row(&1, required, covered, missing, checks))
  end

  defp evidence_rows(_required, _covered, _missing, _checks), do: []

  defp evidence_row(kind, required, covered, missing, checks) do
    check = evidence_check_for_kind(checks, kind)
    blockers = if check, do: check.blockers, else: missing_blockers(kind, missing)
    warnings = if check, do: check.warnings, else: []

    %{
      kind: kind,
      status: evidence_status(kind, covered, missing, check),
      required: kind in required,
      covered: kind in covered,
      missing: kind in missing,
      check_id: if(check, do: check.id),
      task: if(check, do: check.task),
      scenario: if(check, do: check.scenario),
      artifact_path: if(check, do: check.artifact_path),
      blockers: blockers,
      warnings: warnings,
      blocker_count: length(blockers),
      warning_count: length(warnings)
    }
  end

  defp evidence_check_for_kind(checks, kind) do
    Enum.find(checks, &(&1.evidence_kind == kind)) ||
      Enum.find(checks, &(&1.id == "required_rehearsal_kind_#{kind}")) ||
      Enum.find(checks, &(&1.task == "artifact:#{kind}"))
  end

  defp evidence_status(_kind, _covered, _missing, %{status: status}) when is_binary(status),
    do: status

  defp evidence_status(kind, covered, missing, _check) do
    cond do
      kind in missing -> "blocked"
      kind in covered -> "ok"
      true -> "unknown"
    end
  end

  defp missing_blockers(kind, missing) do
    if kind in missing do
      [%{reason: "required_rehearsal_kind_missing", check: nil, task: "artifact:#{kind}"}]
    else
      []
    end
  end

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp string_list(_values), do: []

  defp int_value(value) when is_integer(value), do: value

  defp int_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> 0
    end
  end

  defp int_value(_value), do: 0

  defp evidence_source_rows(%{checks: checks}) when is_list(checks) do
    checks
    |> Enum.map(&evidence_source_row/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&{&1.kind || "", &1.scenario || "", &1.check_id || "", &1.task || ""})
  end

  defp evidence_source_rows(_artifact), do: []

  defp evidence_source_row(check) do
    kind = first_present([check.evidence_kind, artifact_kind_from_check(check)])
    has_source_field? = Enum.any?([kind, check.scenario, check.artifact_path], &present?/1)

    if has_source_field? do
      %{
        row_id: evidence_source_row_id(check, kind),
        status: check.status,
        kind: kind,
        scenario: check.scenario,
        check_id: check.id,
        task: check.task,
        artifact_path: check.artifact_path,
        source_status: source_status(check.artifact_path)
      }
    end
  end

  defp artifact_kind_from_check(%{task: "artifact:" <> kind}) when kind != "", do: kind

  defp artifact_kind_from_check(%{id: "required_rehearsal_kind_" <> kind}) when kind != "",
    do: kind

  defp artifact_kind_from_check(_check), do: nil

  defp evidence_source_row_id(check, kind) do
    primary = source_id_fields([kind, check.id, check.task])
    fallback = source_id_fields([check.scenario, check.artifact_path])

    fields =
      case primary do
        [] -> fallback
        ["unknown", "unknown"] -> fallback ++ primary
        values -> values
      end

    fields =
      case fields do
        [] -> ["unknown-source"]
        values -> values
      end

    Enum.join(fields, "-")
  end

  defp source_id_fields(values) do
    values
    |> Enum.filter(&present?/1)
  end

  defp source_status(nil), do: "no_source"
  defp source_status(""), do: "no_source"
  defp source_status(_path), do: nil

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp present?(value), do: not is_nil(value) and value != ""

  defp safe_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
  end
end
