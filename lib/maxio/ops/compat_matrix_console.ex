defmodule Maxio.Ops.CompatMatrixConsole do
  @moduledoc """
  Read-only Console projection for S3 compatibility matrix evidence.

  This module reads archived compatibility matrix artifacts and never runs test
  suites, external client probes, external smoke checks, HTTP clients, Mix
  tasks, or shell commands.
  """

  alias Maxio.Ops.CompatMatrix.Artifacts

  @max_artifacts 8
  @max_rows 24
  @default_artifact_max_age_minutes 7 * 24 * 60

  @doc "Load the read-only compatibility matrix console projection."
  @spec load(map(), keyword()) :: map()
  def load(params \\ %{}, opts \\ []) when is_map(params) and is_list(opts) do
    now = now(opts)
    artifacts = artifacts(opts)
    selected_artifact_name = requested_artifact(params)
    selection = select_artifact(artifacts, selected_artifact_name)
    selected = selection.selected

    artifact_section = artifact_section(artifacts, now, opts)
    provenance = artifact_provenance(selected, now, opts)
    internal_suites = internal_suites(selected)
    external_clients = external_clients(selected)
    external_smoke = external_smoke(selected)
    streaming_stress = streaming_stress(selected)
    blockers = blockers(selected, now, opts)
    warnings = warnings(selected, selection, now, opts)

    status =
      rollup_status([
        artifact_section.status,
        provenance.status,
        internal_suites.status,
        external_clients.status,
        external_smoke.status,
        streaming_stress.status,
        blockers.status,
        warnings.status
      ])

    %{
      status: status,
      readonly_boundary: readonly_boundary(),
      summary_rows:
        summary_rows(
          status,
          selected,
          artifact_section,
          internal_suites,
          external_clients,
          external_smoke,
          streaming_stress
        ),
      artifacts: artifact_section,
      selected_artifact: selected,
      selection_warning: selection.warning,
      artifact_provenance: provenance,
      internal_suites: internal_suites,
      external_clients: external_clients,
      external_smoke: external_smoke,
      streaming_stress: streaming_stress,
      blockers: blockers,
      warnings: warnings,
      cross_links: cross_links()
    }
  end

  defp artifacts(opts) do
    fun = Keyword.get(opts, :artifacts_fun, &Artifacts.list_recent/1)
    artifact_opts = Keyword.get(opts, :artifact_opts, limit: @max_artifacts)

    case safe_call1(fun, artifact_opts) |> unwrap_read_result() do
      {:ok, artifacts} when is_list(artifacts) -> artifacts |> Enum.take(@max_artifacts)
      {:ok, _other} -> []
      {:error, _reason} -> []
    end
  end

  defp artifact_section(artifacts, now, opts) do
    rows =
      artifacts
      |> Enum.take(@max_artifacts)
      |> Enum.map(&artifact_row(&1, now, opts))

    %{
      status: if(rows == [], do: "attention", else: rows_status(rows)),
      rows: rows,
      latest: List.first(rows)
    }
  end

  defp artifact_row(artifact, now, opts) do
    %{
      id: safe_id(map_get(artifact, :file_name)),
      status: artifact_status(artifact, now, opts),
      file_name: text(map_get(artifact, :file_name)),
      gate_status: text(map_get(artifact, :gate_status)),
      generated_at: text(map_get(artifact, :generated_at)),
      suites: length(list_value(map_get(artifact, :suites))),
      external_clients: length(list_value(map_get(artifact, :external_clients))),
      external_smoke: length(list_value(map_get(artifact, :external_smoke))),
      reason: artifact_reason(artifact, now, opts)
    }
  end

  defp select_artifact([], requested) do
    %{
      selected: nil,
      warning:
        if(blank?(requested),
          do: nil,
          else: selection_warning("not_found", requested, nil)
        )
    }
  end

  defp select_artifact(artifacts, requested) do
    latest = List.first(artifacts)

    cond do
      blank?(requested) ->
        %{selected: latest, warning: nil}

      not safe_path_segment?(requested) ->
        %{selected: latest, warning: selection_warning("invalid_parameter", requested, latest)}

      selected = Enum.find(artifacts, &(map_get(&1, :file_name) == requested)) ->
        warning =
          if map_get(selected, :file_name) == map_get(latest, :file_name) do
            nil
          else
            selection_warning("selected_not_latest", requested, selected)
          end

        %{selected: selected, warning: warning}

      true ->
        %{selected: latest, warning: selection_warning("not_found", requested, latest)}
    end
  end

  defp selection_warning(reason, requested, selected) do
    %{
      status: "attention",
      reason: reason,
      requested: text(requested),
      showing: text(map_get(selected || %{}, :file_name))
    }
  end

  defp artifact_provenance(nil, _now, _opts) do
    %{
      status: "attention",
      rows: [row("provenance-empty", "reason", "no_compat_matrix_artifact")]
    }
  end

  defp artifact_provenance(artifact, now, opts) do
    provenance = map_get(artifact, :artifact_provenance, %{})
    status = artifact_status(artifact, now, opts)

    %{
      status: status,
      rows: [
        row("provenance-status", "status", status),
        row("provenance-reason", "reason", artifact_reason(artifact, now, opts)),
        row("provenance-file", "file_name", map_get(provenance, :file_name)),
        row("provenance-schema", "schema_version", map_get(provenance, :schema_version)),
        row("provenance-generated", "generated_at", map_get(provenance, :generated_at)),
        row("provenance-modified", "modified_at", map_get(provenance, :modified_at)),
        row("provenance-size", "size_bytes", map_get(provenance, :size_bytes)),
        row("provenance-git", "git_sha", map_get(provenance, :git_sha)),
        row("provenance-node", "node", map_get(provenance, :node)),
        row("provenance-mix-env", "mix_env", map_get(provenance, :mix_env)),
        row("provenance-run", "run_id", map_get(provenance, :run_id)),
        row("provenance-gate", "gate_status", map_get(provenance, :gate_status))
      ]
    }
  end

  defp internal_suites(nil), do: rows_section("attention", [])

  defp internal_suites(artifact) do
    rows =
      artifact
      |> map_get(:suites, [])
      |> list_value()
      |> Enum.take(@max_rows)
      |> Enum.map(fn suite ->
        %{
          id: safe_id(map_get(suite, :id)),
          status: section_status(map_get(suite, :status)),
          suite: text(map_get(suite, :id)),
          mode: text(map_get(suite, :mode)),
          tests: text(map_get(suite, :tests)),
          failures: text(map_get(suite, :failures)),
          exit_status: text(map_get(suite, :exit_status)),
          reason: first_reason(suite)
        }
      end)

    rows_section(if(rows == [], do: "attention", else: rows_status(rows)), rows)
  end

  defp external_clients(nil), do: rows_section("attention", [])

  defp external_clients(artifact) do
    rows =
      artifact
      |> map_get(:external_clients, [])
      |> list_value()
      |> Enum.take(@max_rows)
      |> Enum.map(fn client ->
        %{
          id: safe_id(map_get(client, :id)),
          status: section_status(map_get(client, :status)),
          client: text(map_get(client, :id)),
          label: text(map_get(client, :label)),
          executable: text(map_get(client, :executable)),
          detail: text(map_get(client, :detail)),
          reason: first_reason(client)
        }
      end)

    rows_section(if(rows == [], do: "attention", else: rows_status(rows)), rows)
  end

  defp external_smoke(nil), do: rows_section("attention", [])

  defp external_smoke(artifact) do
    rows =
      artifact
      |> map_get(:external_smoke, [])
      |> list_value()
      |> Enum.take(@max_rows)
      |> Enum.map(fn smoke ->
        %{
          id: safe_id(map_get(smoke, :id)),
          status: section_status(map_get(smoke, :status)),
          client: text(map_get(smoke, :id)),
          steps: text(map_get(smoke, :step_count)),
          scenarios: text(map_get(smoke, :scenario_counts)),
          duration_ms: text(map_get(smoke, :duration_ms)),
          reason: first_reason(smoke)
        }
      end)

    rows_section(if(rows == [], do: "attention", else: rows_status(rows)), rows)
  end

  defp streaming_stress(nil) do
    %{
      status: "attention",
      rows: [row("streaming-stress-empty", "profile", "not_present")]
    }
  end

  defp streaming_stress(artifact) do
    stress = map_get(artifact, :streaming_stress, %{})
    status = section_status(map_get(stress, :status))

    %{
      status: status,
      rows: [
        row("streaming-stress-status", "status", status),
        row("streaming-stress-profile", "profile", map_get(stress, :profile)),
        row("streaming-stress-parameters", "parameters", map_get(stress, :parameters)),
        row("streaming-stress-scenarios", "scenarios", map_get(stress, :scenarios))
      ]
    }
  end

  defp blockers(nil, _now, _opts), do: rows_section("attention", [])

  defp blockers(artifact, now, opts) do
    artifact_blockers =
      artifact
      |> map_get(:blockers, [])
      |> list_value()
      |> gate_item_rows("blocker", "artifact")

    synthetic =
      synthetic_blockers(artifact, now, opts)
      |> gate_item_rows("blocker", "synthetic")

    rows = Enum.take(synthetic ++ artifact_blockers, @max_rows)
    rows_section(if(rows == [], do: "ok", else: "blocked"), rows)
  end

  defp warnings(nil, selection, _now, _opts) do
    rows =
      if selection.warning do
        [warning_row("selection", 1, selection.warning)]
      else
        []
      end

    rows_section(if(rows == [], do: "ok", else: "attention"), rows)
  end

  defp warnings(artifact, selection, now, opts) do
    artifact_warnings =
      artifact
      |> map_get(:warnings, [])
      |> list_value()
      |> gate_item_rows("warning", "artifact")

    freshness =
      case artifact_freshness_issue(artifact, now, opts) do
        nil ->
          []

        reason ->
          [
            warning_row("freshness", 1, %{
              reason: reason,
              requested: nil,
              showing: map_get(artifact, :file_name)
            })
          ]
      end

    selection_rows =
      if selection.warning do
        [warning_row("selection", 1, selection.warning)]
      else
        []
      end

    rows = Enum.take(selection_rows ++ freshness ++ artifact_warnings, @max_rows)
    rows_section(if(rows == [], do: "ok", else: "attention"), rows)
  end

  defp synthetic_blockers(artifact, now, opts) do
    [
      if(map_get(artifact, :status) == "invalid",
        do: %{"reason" => map_get(artifact, :error_reason)}
      ),
      if(count_status(artifact) == "blocked", do: %{"reason" => "counts_mismatch"}),
      case artifact_freshness_issue(artifact, now, opts) do
        nil -> nil
        reason -> %{"reason" => reason}
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp gate_item_rows(items, kind, source) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {item, ordinal} -> gate_item_row(kind, source, ordinal, item) end)
  end

  defp gate_item_row(kind, source, ordinal, item) do
    %{
      id: gate_item_id(kind, source, ordinal),
      status: if(kind == "blocker", do: "blocked", else: "attention"),
      entry: text(map_get(item, :entry)),
      kind: text(map_get(item, :kind, kind)),
      reason: text(map_get(item, :reason)),
      detail: text(map_get(item, :detail, map_get(item, :message)))
    }
  end

  defp warning_row(source, ordinal, warning) do
    %{
      id: gate_item_id("warning", source, ordinal),
      status: "attention",
      entry: text(map_get(warning, :requested)),
      kind: "warning",
      reason: text(map_get(warning, :reason)),
      detail: text(map_get(warning, :showing))
    }
  end

  defp gate_item_id(kind, source, ordinal), do: safe_id("#{kind}-#{source}-#{ordinal}")

  defp rows_section(status, rows), do: %{status: status, rows: rows}

  defp summary_rows(status, selected, artifacts, suites, external_clients, external_smoke, stress) do
    [
      row("summary-status", "status", status),
      row("summary-selected", "selected_artifact", map_get(selected || %{}, :file_name)),
      row("summary-artifacts", "artifacts", length(artifacts.rows)),
      row("summary-suites", "internal_suites", length(suites.rows)),
      row("summary-external-clients", "external_clients", length(external_clients.rows)),
      row("summary-external-smoke", "external_smoke", length(external_smoke.rows)),
      row("summary-streaming-stress", "streaming_stress", stress.status)
    ]
  end

  defp readonly_boundary do
    %{
      status: "ok",
      message:
        "This page only reads archived compatibility matrix artifacts and never runs compatibility checks.",
      forbidden: [
        "compat matrix execution",
        "external smoke execution",
        "external client probing",
        "Mix task execution",
        "shell/system commands",
        "HTTP requests",
        "scan/heal/rebalance/gate execution"
      ]
    }
  end

  defp cross_links do
    [
      %{id: "ops-compat-link-gate", label: "Ops Gate", path: "/ops/gate"},
      %{id: "ops-compat-link-upgrade", label: "Ops Upgrade", path: "/ops/upgrade"},
      %{id: "ops-compat-link-scan", label: "Ops Scan", path: "/ops/scan"},
      %{id: "ops-compat-link-cluster", label: "Ops Cluster", path: "/ops/cluster"}
    ]
  end

  defp artifact_status(nil, _now, _opts), do: "attention"

  defp artifact_status(artifact, now, opts) do
    cond do
      map_get(artifact, :status) == "invalid" -> "blocked"
      count_status(artifact) == "blocked" -> "blocked"
      artifact_freshness_issue(artifact, now, opts) != nil -> "blocked"
      section_status(map_get(artifact, :gate_status)) == "blocked" -> "blocked"
      section_status(map_get(artifact, :gate_status)) == "attention" -> "attention"
      true -> "ok"
    end
  end

  defp artifact_reason(nil, _now, _opts), do: "no_compat_matrix_artifact"

  defp artifact_reason(artifact, now, opts) do
    cond do
      map_get(artifact, :status) == "invalid" ->
        text(map_get(artifact, :error_reason))

      count_status(artifact) == "blocked" ->
        "counts_mismatch"

      reason = artifact_freshness_issue(artifact, now, opts) ->
        reason

      true ->
        text(map_get(artifact, :gate_status, "unknown"))
    end
  end

  defp count_status(artifact) do
    artifact
    |> map_get(:count_check, %{})
    |> map_get(:status)
    |> section_status()
  end

  defp artifact_freshness_issue(artifact, now, opts) do
    max_age_minutes =
      positive_int(
        Keyword.get(opts, :artifact_max_age_minutes),
        @default_artifact_max_age_minutes
      )

    artifact
    |> map_get(:generated_at)
    |> generated_at_freshness_issue(now, max_age_minutes)
  end

  defp generated_at_freshness_issue(value, now, max_age_minutes) do
    case parse_iso8601(value) do
      {:ok, generated_at} ->
        cond do
          DateTime.compare(generated_at, now) == :gt -> "future_generated_at"
          DateTime.diff(now, generated_at, :minute) > max_age_minutes -> "stale_artifact"
          true -> nil
        end

      :error ->
        if blank?(value), do: "missing_generated_at", else: "invalid_generated_at"
    end
  end

  defp first_reason(entry) do
    blockers = list_value(map_get(entry, :blockers))
    warnings = list_value(map_get(entry, :warnings))

    case blockers ++ warnings do
      [first | _rest] -> text(map_get(first, :reason))
      [] -> text(map_get(entry, :status))
    end
  end

  defp rows_status(rows) do
    cond do
      rows == [] -> "attention"
      Enum.any?(rows, &(&1.status == "blocked")) -> "blocked"
      Enum.any?(rows, &(&1.status in ["attention", "empty", "missing"])) -> "attention"
      true -> "ok"
    end
  end

  defp rollup_status(statuses) do
    statuses = Enum.map(statuses, &section_status/1)

    cond do
      Enum.any?(statuses, &(&1 == "blocked")) -> "blocked"
      Enum.any?(statuses, &(&1 in ["attention", "empty", "missing"])) -> "attention"
      true -> "ok"
    end
  end

  defp section_status(status) do
    case status_text(status) do
      value when value in ["ok", "ready", "active"] -> "ok"
      value when value in ["blocked", "failed", "error", "invalid", "unavailable"] -> "blocked"
      value when value in ["attention", "empty", "missing", "stale", "unknown"] -> "attention"
      _other -> "attention"
    end
  end

  defp status_text(nil), do: "unknown"
  defp status_text(status) when is_atom(status), do: status |> Atom.to_string() |> status_text()

  defp status_text(status) when is_binary(status),
    do: status |> String.downcase() |> String.trim()

  defp status_text(status), do: status |> to_string() |> status_text()

  defp row(id, label, value), do: %{id: id, label: label, value: text(value)}

  defp text(nil), do: "-"
  defp text(""), do: "-"
  defp text(value) when is_binary(value), do: value

  defp text(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: to_string(value)

  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value), do: inspect(value, limit: 12, printable_limit: 320)

  defp map_get(map, key, default \\ nil)

  defp map_get(nil, _key, default), do: default

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp requested_artifact(params) do
    params
    |> map_get(:artifact)
    |> case do
      value when is_binary(value) -> String.trim(value)
      _other -> nil
    end
  end

  defp safe_path_segment?(value) when is_binary(value) do
    value not in ["", ".", ".."] and
      not String.contains?(value, ["/", "\\", ".."]) and
      Path.basename(value) == value
  end

  defp safe_path_segment?(_value), do: false

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

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      nil -> DateTime.utc_now()
      other -> other
    end
  end

  defp parse_iso8601(nil), do: :error
  defp parse_iso8601(""), do: :error

  defp parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> :error
    end
  end

  defp parse_iso8601(_value), do: :error

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp safe_call1(fun, arg) do
    {:ok, fun.(arg)}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp unwrap_read_result({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_read_result({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_read_result(result), do: result
end
