defmodule Maxio.Ops.RecoveryReadinessConsole do
  @moduledoc """
  Read-only Console projection for recovery and disaster-recovery readiness.

  This projection aggregates existing operations evidence. It does not run
  recovery drills, start schedulers, execute scan/heal/rebalance workflows,
  generate tokens, issue HTTP requests, or write Repo state.
  """

  alias Maxio.Ops.{
    ClusterHealthConsole,
    Gate,
    ObservabilityConsole,
    RebalanceWorkflowConsole,
    RehearsalBundle,
    ReplacementAutomationConsole,
    ScanEvidenceConsole,
    UpgradeReadinessConsole
  }

  @artifact_limit 3
  @max_items 16
  @default_max_artifact_age_minutes 24 * 60

  @doc "Load the read-only recovery readiness console projection."
  @spec load(keyword()) :: map()
  def load(opts \\ []) when is_list(opts) do
    now = now(opts)

    artifact_sections = [
      artifact_source(
        :rehearsal_bundles_fun,
        "live-rehearsal-bundles",
        "P0 Live Rehearsal Bundles",
        "rehearsal_bundle",
        fn query_opts -> RehearsalBundle.Artifacts.list_recent(query_opts) end,
        now,
        opts
      ),
      artifact_source(
        :gate_artifacts_fun,
        "ops-gate-artifacts",
        "Ops Gate Artifacts",
        "ops_gate",
        fn query_opts -> Gate.Artifacts.list_recent(query_opts) end,
        now,
        opts
      )
    ]

    operational_sections = [
      projection_source(
        :cluster_fun,
        "cluster-health",
        "Cluster Health",
        "cluster",
        fn ->
          ClusterHealthConsole.load()
        end,
        opts
      ),
      projection_source(
        :scan_fun,
        "scan-drive-health",
        "Scanner and Drive Health",
        "scan",
        fn ->
          ScanEvidenceConsole.load()
        end,
        opts
      ),
      projection_source(
        :replacement_fun,
        "replacement-automation",
        "Replacement Automation",
        "replacement",
        fn -> ReplacementAutomationConsole.load() end,
        opts
      ),
      projection_source(
        :rebalance_fun,
        "rebalance-workflow",
        "Rebalance Workflow",
        "rebalance",
        fn -> RebalanceWorkflowConsole.load(%{}, []) end,
        opts
      ),
      projection_source(
        :upgrade_fun,
        "upgrade-rollback",
        "Upgrade and Rollback",
        "upgrade",
        fn -> UpgradeReadinessConsole.load() end,
        opts
      ),
      projection_source(
        :observability_fun,
        "observability",
        "Observability Readiness",
        "observability",
        fn -> ObservabilityConsole.load() end,
        opts
      )
    ]

    sections = artifact_sections ++ operational_sections
    blockers = blockers_section(sections)
    warnings = warnings_section(sections)

    status =
      sections
      |> Enum.map(& &1.status)
      |> Kernel.++([blockers.status, warnings.status])
      |> rollup_status()

    %{
      status: status,
      readonly_boundary: readonly_boundary(),
      summary_rows: summary_rows(status, artifact_sections, operational_sections),
      recovery_axes: %{
        status: rollup_status(Enum.map(sections, & &1.status)),
        rows: Enum.map(sections, &axis_row/1)
      },
      artifact_evidence: %{
        status: rollup_status(Enum.map(artifact_sections, & &1.status)),
        rows: Enum.flat_map(artifact_sections, & &1.rows)
      },
      operational_evidence: %{
        status: rollup_status(Enum.map(operational_sections, & &1.status)),
        rows: Enum.flat_map(operational_sections, & &1.rows)
      },
      blockers: blockers,
      warnings: warnings,
      cross_links: cross_links()
    }
  end

  defp artifact_source(key, id, label, kind, default_fun, now, opts) do
    fun = Keyword.get(opts, key, default_fun)

    case safe_call1(fun, limit: Keyword.get(opts, :artifact_limit, @artifact_limit)) do
      {:ok, artifacts} when is_list(artifacts) ->
        rows =
          artifacts
          |> Enum.take(@artifact_limit)
          |> Enum.map(&artifact_row(id, label, kind, &1, now, opts))

        empty_warning =
          if rows == [] do
            [
              item(
                "#{id}-missing",
                id,
                "no_#{kind}_evidence",
                "no recent #{label} artifacts were found",
                "attention"
              )
            ]
          else
            []
          end

        status =
          rollup_status(
            if(rows == [], do: ["attention"], else: []) ++ Enum.map(rows, & &1.status)
          )

        %{
          id: id,
          label: label,
          kind: kind,
          status: status,
          rows: rows,
          blockers: row_items(rows, "blocked", id),
          warnings: empty_warning ++ row_items(rows, "attention", id)
        }

      {:ok, _other} ->
        unavailable_source(id, label, kind, "malformed_reader_result", "non_list_result")

      {:error, reason} ->
        unavailable_source(id, label, kind, "reader_failed", reason)
    end
  end

  defp projection_source(key, id, label, kind, default_fun, opts) do
    fun = Keyword.get(opts, key, default_fun)

    case safe_call0(fun) do
      {:ok, projection} when is_map(projection) ->
        status = status_text(map_get(projection, :status, "attention"))

        rows = [
          evidence_row("#{id}-status", id, label, kind, status, "status", status),
          evidence_row(
            "#{id}-summary",
            id,
            label,
            kind,
            status,
            "summary",
            projection_summary(projection)
          )
        ]

        blockers =
          item_rows(map_get(projection, :blockers)) |> normalize_items(id, kind, "blocked")

        warnings =
          item_rows(map_get(projection, :warnings)) |> normalize_items(id, kind, "attention")

        blockers =
          if status == "blocked" and blockers == [] do
            [item("#{id}-blocked", id, "#{kind}_blocked", "#{label} reported blocked", "blocked")]
          else
            blockers
          end

        warnings =
          if status == "attention" and warnings == [] do
            [
              item(
                "#{id}-attention",
                id,
                "#{kind}_attention",
                "#{label} needs operator attention",
                "attention"
              )
            ]
          else
            warnings
          end

        %{
          id: id,
          label: label,
          kind: kind,
          status: status,
          rows: rows,
          blockers: blockers,
          warnings: warnings
        }

      {:ok, _other} ->
        unavailable_source(id, label, kind, "malformed_reader_result", "non_map_result")

      {:error, reason} ->
        unavailable_source(id, label, kind, "reader_failed", reason)
    end
  end

  defp artifact_row(section_id, section_label, kind, artifact, now, opts) when is_map(artifact) do
    run_id =
      map_get(artifact, :run_id) ||
        map_get(artifact, :id) ||
        map_get(artifact, :name) ||
        map_get(artifact, :artifact) ||
        "unknown"

    raw_status = artifact_raw_status(kind, artifact)

    {timestamp_status, timestamp_reason} =
      timestamp_status(map_get(artifact, :generated_at), now, opts)

    status = rollup_status([raw_status, timestamp_status])

    reason =
      cond do
        timestamp_reason != "ok" -> timestamp_reason
        raw_status != "ok" -> artifact_reason(kind, artifact, raw_status)
        true -> "ok"
      end

    %{
      id: safe_id("#{section_id}-#{run_id}"),
      source: section_label,
      kind: kind,
      status: status,
      run_id: text(run_id),
      generated_at: timestamp_text(map_get(artifact, :generated_at)),
      reason: reason,
      detail: artifact_detail(kind, artifact, reason)
    }
  end

  defp artifact_row(section_id, section_label, kind, artifact, _now, _opts) do
    %{
      id: safe_id("#{section_id}-malformed"),
      source: section_label,
      kind: kind,
      status: "blocked",
      run_id: "malformed_artifact",
      generated_at: "-",
      reason: "malformed_artifact",
      detail: redact(text(artifact))
    }
  end

  defp artifact_raw_status(kind, artifact) do
    rollup_status([artifact_parse_status(artifact), artifact_kind_status(kind, artifact)])
  end

  defp artifact_parse_status(artifact) do
    cond do
      map_get(artifact, :valid?) == false -> "blocked"
      map_get(artifact, :valid) == false -> "blocked"
      true -> status_text(map_get(artifact, :status, map_get(artifact, :state, "attention")))
    end
  end

  defp artifact_kind_status("ops_gate", artifact) do
    rollup_status([
      gate_status_status(artifact),
      list_status(map_get(artifact, :blockers), "blocked"),
      list_status(map_get(artifact, :warnings), "attention"),
      gate_checks_status(map_get(artifact, :checks))
    ])
  end

  defp artifact_kind_status("rehearsal_bundle", artifact) do
    rollup_status([
      gate_status_status(artifact),
      child_results_status(map_get(artifact, :child_results)),
      list_status(map_get(artifact, :boundary_warnings), "attention"),
      bool_ready_status(map_get(artifact, :replacement_rehearsal_ready?))
    ])
  end

  defp artifact_kind_status(_kind, _artifact), do: "ok"

  defp gate_status_status(artifact) do
    case map_get(artifact, :gate_status) do
      nil -> "attention"
      "" -> "attention"
      "-" -> "attention"
      status -> status_text(status)
    end
  end

  defp list_status(rows, nonempty_status) do
    if item_rows(rows) == [], do: "ok", else: nonempty_status
  end

  defp gate_checks_status(checks) do
    statuses =
      checks
      |> item_rows()
      |> Enum.map(fn check ->
        rollup_status([
          status_text(map_get(check, :status, "attention")),
          list_status(map_get(check, :blockers), "blocked"),
          list_status(map_get(check, :warnings), "attention")
        ])
      end)

    case statuses do
      [] -> "ok"
      statuses -> rollup_status(statuses)
    end
  end

  defp child_results_status(child_results) do
    statuses =
      child_results
      |> item_rows()
      |> Enum.map(&child_result_status/1)

    case statuses do
      [] -> "attention"
      statuses -> rollup_status(statuses)
    end
  end

  defp child_result_status(child) when is_map(child) do
    gate_status =
      case map_get(child, :gate_status) do
        nil -> "ok"
        "" -> "ok"
        "-" -> "ok"
        status -> status_text(status)
      end

    rollup_status([status_text(map_get(child, :status, "attention")), gate_status])
  end

  defp child_result_status(_child), do: "blocked"

  defp bool_ready_status(false), do: "blocked"
  defp bool_ready_status(_value), do: "ok"

  defp artifact_reason(kind, artifact, fallback) do
    explicit =
      map_get(artifact, :reason) ||
        map_get(artifact, :error_reason) ||
        map_get(artifact, :error)

    (explicit || artifact_kind_reason(kind, artifact, fallback) || fallback)
    |> text()
  end

  defp artifact_kind_reason("ops_gate", artifact, fallback) do
    cond do
      gate_status_status(artifact) != "ok" ->
        "gate_status_#{reason_token(map_get(artifact, :gate_status, fallback))}"

      item_rows(map_get(artifact, :blockers)) != [] ->
        first_item_reason(map_get(artifact, :blockers), "artifact_blocker")

      problem_check = first_problem_check(map_get(artifact, :checks)) ->
        "check_#{reason_token(map_get(problem_check, :status, fallback))}"

      item_rows(map_get(artifact, :warnings)) != [] ->
        first_item_reason(map_get(artifact, :warnings), "artifact_warning")

      true ->
        fallback
    end
  end

  defp artifact_kind_reason("rehearsal_bundle", artifact, fallback) do
    cond do
      gate_status_status(artifact) != "ok" ->
        "gate_status_#{reason_token(map_get(artifact, :gate_status, fallback))}"

      problem_child = first_problem_child(map_get(artifact, :child_results)) ->
        "child_#{reason_token(map_get(problem_child, :id, "unknown"))}_#{child_status_reason(problem_child)}"

      item_rows(map_get(artifact, :child_results)) == [] ->
        "missing_child_results"

      item_rows(map_get(artifact, :boundary_warnings)) != [] ->
        first_item_reason(map_get(artifact, :boundary_warnings), "boundary_warning")

      map_get(artifact, :replacement_rehearsal_ready?) == false ->
        "replacement_rehearsal_not_ready"

      true ->
        fallback
    end
  end

  defp artifact_kind_reason(_kind, _artifact, fallback), do: fallback

  defp first_problem_check(checks) do
    checks
    |> item_rows()
    |> Enum.find(fn check ->
      rollup_status([
        status_text(map_get(check, :status, "attention")),
        list_status(map_get(check, :blockers), "blocked"),
        list_status(map_get(check, :warnings), "attention")
      ]) != "ok"
    end)
  end

  defp first_problem_child(child_results) do
    child_results
    |> item_rows()
    |> Enum.find(&(child_result_status(&1) != "ok"))
  end

  defp child_status_reason(child) do
    case map_get(child, :gate_status) do
      nil -> reason_token(map_get(child, :status, "unknown"))
      "" -> reason_token(map_get(child, :status, "unknown"))
      "-" -> reason_token(map_get(child, :status, "unknown"))
      status -> reason_token(status)
    end
  end

  defp first_item_reason(rows, fallback) do
    case List.first(item_rows(rows)) do
      nil ->
        fallback

      row ->
        row
        |> map_get(:reason, map_get(row, :label, map_get(row, :id, fallback)))
        |> text()
    end
  end

  defp reason_token(value) do
    value
    |> text()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "unknown"
      token -> token
    end
  end

  defp artifact_detail(kind, artifact, fallback) do
    artifact_reason(kind, artifact, fallback)
    |> text()
    |> redact()
  end

  defp timestamp_status(nil, _now, _opts), do: {"blocked", "missing_generated_at"}

  defp timestamp_status(%DateTime{} = generated_at, %DateTime{} = now, opts) do
    max_age_minutes =
      positive_int(
        Keyword.get(opts, :max_artifact_age_minutes),
        @default_max_artifact_age_minutes
      )

    cond do
      DateTime.compare(generated_at, now) == :gt ->
        {"blocked", "future_generated_at"}

      DateTime.diff(now, generated_at, :minute) > max_age_minutes ->
        {"attention", "stale_artifact"}

      true ->
        {"ok", "ok"}
    end
  end

  defp timestamp_status(value, now, opts) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, generated_at, _offset} -> timestamp_status(generated_at, now, opts)
      {:error, _reason} -> {"blocked", "invalid_generated_at"}
    end
  end

  defp timestamp_status(_value, _now, _opts), do: {"blocked", "invalid_generated_at"}

  defp timestamp_text(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp_text(value), do: text(value)

  defp unavailable_source(id, label, kind, reason, detail) do
    %{
      id: id,
      label: label,
      kind: kind,
      status: "blocked",
      rows: [
        evidence_row(
          "#{id}-unavailable",
          id,
          label,
          kind,
          "blocked",
          reason,
          detail
        )
      ],
      blockers: [item("#{id}-#{reason}", id, reason, detail, "blocked")],
      warnings: []
    }
  end

  defp axis_row(section) do
    %{
      id: section.id,
      status: section.status,
      source: section.label,
      kind: section.kind,
      evidence_rows: length(section.rows),
      blockers: length(section.blockers),
      warnings: length(section.warnings)
    }
  end

  defp evidence_row(id, source, label, kind, status, reason, detail) do
    %{
      id: safe_id(id),
      source: text(label || source),
      kind: text(kind),
      status: status_text(status),
      reason: text(reason),
      detail: detail |> text() |> redact()
    }
  end

  defp row_items(rows, status, source) do
    rows
    |> Enum.filter(&(&1.status == status))
    |> Enum.map(fn row ->
      item(
        "#{row.id}-#{status}",
        source,
        row.reason,
        row.detail,
        status
      )
    end)
  end

  defp blockers_section(sections) do
    rows =
      sections
      |> Enum.flat_map(& &1.blockers)
      |> Enum.take(@max_items)

    %{status: if(rows == [], do: "ok", else: "blocked"), rows: rows}
  end

  defp warnings_section(sections) do
    rows =
      sections
      |> Enum.flat_map(& &1.warnings)
      |> Enum.take(@max_items)

    %{status: if(rows == [], do: "ok", else: "attention"), rows: rows}
  end

  defp normalize_items(rows, source, kind, fallback_status) do
    rows
    |> Enum.take(@max_items)
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      reason = map_get(row, :reason, map_get(row, :label, "#{kind}_#{fallback_status}"))
      detail = map_get(row, :detail, map_get(row, :value, reason))

      item(
        "#{source}-#{fallback_status}-#{index}-#{reason}",
        source,
        reason,
        detail,
        fallback_status
      )
    end)
  end

  defp item_rows(%{rows: rows}) when is_list(rows), do: rows
  defp item_rows(rows) when is_list(rows), do: rows
  defp item_rows(_rows), do: []

  defp item(id, entry, reason, detail, status) do
    %{
      id: safe_id(id),
      status: status_text(status),
      entry: text(entry),
      kind: "recovery_readiness",
      reason: text(reason),
      detail: detail |> text() |> redact()
    }
  end

  defp summary_rows(status, artifact_sections, operational_sections) do
    artifact_rows = Enum.flat_map(artifact_sections, & &1.rows)
    operational_rows = Enum.flat_map(operational_sections, & &1.rows)

    [
      row("summary-status", "status", status),
      row("summary-artifact-sources", "artifact_sources", length(artifact_sections)),
      row("summary-artifact-rows", "artifact_rows", length(artifact_rows)),
      row("summary-operational-sources", "operational_sources", length(operational_sections)),
      row("summary-operational-rows", "operational_rows", length(operational_rows)),
      row(
        "summary-blocked-sources",
        "blocked_sources",
        Enum.count(artifact_sections ++ operational_sections, &(&1.status == "blocked"))
      ),
      row(
        "summary-attention-sources",
        "attention_sources",
        Enum.count(artifact_sections ++ operational_sections, &(&1.status == "attention"))
      )
    ]
  end

  defp readonly_boundary do
    %{
      status: "ok",
      message: "This page only reads already-recorded recovery and operations evidence.",
      forbidden: [
        "recovery/failover execution",
        "fault injection",
        "scheduler runs",
        "gate execution",
        "scan/heal/rebalance/replacement execution",
        "topology activation",
        "lock mutation",
        "HTTP scraping",
        "System/Mix commands",
        "Repo writes"
      ]
    }
  end

  defp cross_links do
    [
      %{id: "ops-recovery-link-gate", label: "Ops Gate", path: "/ops/gate"},
      %{id: "ops-recovery-link-cluster", label: "Ops Cluster", path: "/ops/cluster"},
      %{id: "ops-recovery-link-scan", label: "Ops Scan", path: "/ops/scan"},
      %{id: "ops-recovery-link-replacement", label: "Ops Replacement", path: "/ops/replacement"},
      %{id: "ops-recovery-link-rebalance", label: "Ops Rebalance", path: "/ops/rebalance"},
      %{id: "ops-recovery-link-upgrade", label: "Ops Upgrade", path: "/ops/upgrade"},
      %{
        id: "ops-recovery-link-observability",
        label: "Ops Observability",
        path: "/ops/observability"
      }
    ]
  end

  defp projection_summary(projection) do
    summary_rows = item_rows(map_get(projection, :summary_rows))

    cond do
      summary_rows != [] ->
        summary_rows
        |> Enum.take(3)
        |> Enum.map(fn row ->
          "#{text(map_get(row, :label, map_get(row, :id)))}=#{text(map_get(row, :value))}"
        end)
        |> Enum.join(", ")
        |> redact()

      map_get(projection, :reason) not in [nil, ""] ->
        projection |> map_get(:reason) |> text() |> redact()

      true ->
        "status=#{text(map_get(projection, :status, "attention"))}"
    end
  end

  defp rollup_status(statuses) do
    statuses = Enum.map(statuses, &status_text/1)

    cond do
      Enum.any?(statuses, &(&1 == "blocked")) -> "blocked"
      Enum.any?(statuses, &(&1 == "attention")) -> "attention"
      true -> "ok"
    end
  end

  defp status_text(status) when status in ["ok", "ready", "healthy", "passed"], do: "ok"
  defp status_text(status) when status in ["blocked", "error", "invalid", "failed"], do: "blocked"

  defp status_text(status) when status in ["attention", "warning", "empty", "stale", "missing"],
    do: "attention"

  defp status_text(:ok), do: "ok"
  defp status_text(:ready), do: "ok"
  defp status_text(:blocked), do: "blocked"
  defp status_text(:error), do: "blocked"
  defp status_text(:attention), do: "attention"
  defp status_text(:warning), do: "attention"
  defp status_text(_status), do: "attention"

  defp row(id, label, value), do: %{id: id, label: label, value: text(value)}

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp safe_call0(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_call1(fun, arg) do
    {:ok, fun.(arg)}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(nil, _key, default), do: default

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default

  defp text(nil), do: "-"
  defp text(""), do: "-"
  defp text(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp text(value) when is_binary(value), do: value

  defp text(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: to_string(value)

  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(%{__exception__: true} = error), do: Exception.message(error)
  defp text(value), do: inspect(value, limit: 8, printable_limit: 160)

  defp safe_id(nil), do: "unknown"

  defp safe_id(value) do
    value
    |> text()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      id -> id
    end
  end

  defp redact(value) when is_binary(value) do
    value
    |> String.replace(~r/(?i)authorization\s*[:=]\s*bearer\s+[^,\s]+/, "[REDACTED]")
    |> String.replace(~r/(?i)\bbearer\s+[^,\s]+/, "Bearer [REDACTED]")
    |> String.replace(
      ~r/(?i)(secret|token|password|credential)\s*[:=]\s*[^,\s]+/,
      "\\1=[REDACTED]"
    )
    |> String.replace(~r/[A-Za-z]:[\\\/][^,\s]+/, "[REDACTED_PATH]")
  end

  defp redact(value), do: value
end
