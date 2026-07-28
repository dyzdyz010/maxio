defmodule Maxio.Ops.Gate.Artifacts do
  @moduledoc """
  Read-only helpers for operator gate artifact discovery.

  Console pages use this module to inspect archived `Maxio.Ops.Gate` reports.
  It never executes Mix tasks and never follows user-supplied paths.
  """

  @default_dir "artifacts"
  @default_glob "m8_ops_gate_*.json"
  @default_limit 20
  @default_max_candidates 100
  @default_max_bytes 2_000_000
  @default_max_items 100
  @max_summary_fields 16
  @max_summary_list_items 6
  @max_summary_value_chars 160
  @max_runbook_rows 18
  @max_runbook_warnings 8

  def list_recent(opts \\ []) do
    opts = normalize_opts(opts)

    opts.dir
    |> Path.expand()
    |> artifact_paths(opts)
    |> Enum.map(&read_artifact(&1, opts))
    |> Enum.sort_by(&sort_key/1, :desc)
    |> Enum.take(opts.limit)
  end

  defp normalize_opts(opts) do
    %{
      dir:
        Keyword.get(opts, :dir) ||
          Application.get_env(:maxio, :ops_gate_artifacts_dir, @default_dir),
      glob:
        Keyword.get(opts, :glob) ||
          Application.get_env(:maxio, :ops_gate_artifacts_glob, @default_glob),
      limit: positive_int(Keyword.get(opts, :limit), @default_limit),
      max_candidates: positive_int(Keyword.get(opts, :max_candidates), @default_max_candidates),
      max_bytes: positive_int(Keyword.get(opts, :max_bytes), @default_max_bytes),
      max_items: positive_int(Keyword.get(opts, :max_items), @default_max_items)
    }
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp artifact_paths(dir, opts) do
    with {:ok, names} <- File.ls(dir),
         {:ok, matcher} <- safe_glob_matcher(opts.glob) do
      names
      |> Enum.filter(&safe_candidate_name?/1)
      |> Enum.filter(matcher)
      |> Enum.sort(:desc)
      |> regular_artifact_candidates(dir, opts.max_candidates)
    else
      _error -> []
    end
  end

  defp regular_artifact_candidates(names, dir, max_candidates) do
    {candidates, _count} =
      Enum.reduce_while(names, {[], 0}, fn name, {candidates, count} ->
        if count >= max_candidates do
          {:halt, {candidates, count}}
        else
          path = Path.join(dir, name)

          case stat_candidate(path, dir) do
            nil -> {:cont, {candidates, count}}
            candidate -> {:cont, {[candidate | candidates], count + 1}}
          end
        end
      end)

    Enum.reverse(candidates)
  end

  defp safe_glob_matcher(glob) when is_binary(glob) do
    if safe_path_segment?(glob) do
      regex = glob_to_regex(glob)
      {:ok, fn name -> Regex.match?(regex, name) end}
    else
      :error
    end
  end

  defp safe_glob_matcher(_glob), do: :error

  defp safe_candidate_name?(name) when is_binary(name), do: safe_path_segment?(name)
  defp safe_candidate_name?(_name), do: false

  defp safe_path_segment?(value) do
    value not in ["", ".", ".."] and
      not String.contains?(value, ["/", "\\", ".."]) and
      Path.basename(value) == value
  end

  defp glob_to_regex(glob) do
    source =
      glob
      |> String.graphemes()
      |> Enum.map_join(fn
        "*" -> ".*"
        "?" -> "."
        char -> Regex.escape(char)
      end)

    Regex.compile!("^" <> source <> "$")
  end

  defp stat_candidate(path, dir) do
    expanded = Path.expand(path)

    with true <- under_dir?(expanded, dir),
         {:ok, stat} <- File.lstat(expanded, time: :posix),
         true <- stat.type == :regular do
      {expanded, stat}
    else
      _other -> nil
    end
  end

  defp under_dir?(path, dir) do
    dir = Path.expand(dir)
    path = Path.expand(path)

    path == dir or Path.dirname(path) == dir
  end

  defp read_artifact({path, stat}, opts) do
    base = %{
      file_name: Path.basename(path),
      path: path,
      size_bytes: stat.size,
      modified_at: posix_to_iso8601(stat.mtime),
      modified_at_unix: stat.mtime,
      sort_unix: stat.mtime
    }

    cond do
      stat.size > opts.max_bytes ->
        invalid_artifact(base, "artifact_too_large")

      true ->
        decode_artifact(path, base, opts)
    end
  end

  defp decode_artifact(path, base, opts) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         true <- is_map(decoded),
         true <- ops_gate_artifact?(decoded) do
      normalize_artifact(decoded, base, opts)
    else
      {:error, %Jason.DecodeError{}} -> invalid_artifact(base, "json_unparseable")
      {:error, reason} -> invalid_artifact(base, "read_error", %{read_error: inspect(reason)})
      false -> invalid_artifact(base, "not_ops_gate_artifact")
      _other -> invalid_artifact(base, "invalid_artifact")
    end
  rescue
    _error -> invalid_artifact(base, "read_error")
  end

  defp ops_gate_artifact?(artifact) do
    Map.has_key?(artifact, "gate_status") or Map.has_key?(artifact, "checks")
  end

  defp normalize_artifact(artifact, base, opts) do
    generated_at = string_value(artifact["generated_at"])
    generated_at_unix = generated_at_unix(generated_at)
    ops_evidence_matrix = map_value(artifact["ops_evidence_matrix"])
    checks = checks(artifact["checks"], opts.max_items)

    base
    |> Map.merge(%{
      status: "ok",
      error_reason: nil,
      schema_version: artifact["schema_version"] || "unknown",
      generated_at: generated_at,
      run_id: string_value(artifact["run_id"]),
      git_sha: string_value(artifact["git_sha"]),
      node: string_value(artifact["node"]),
      mix_env: string_value(artifact["mix_env"]),
      command: string_value(artifact["command"]),
      artifact_path: string_value(artifact["artifact_path"]),
      gate_status: gate_status(artifact),
      ops_evidence_matrix: ops_evidence_matrix,
      operator_runbook: operator_runbook(artifact, ops_evidence_matrix, checks),
      artifact_provenance: artifact_provenance(base, artifact, gate_status(artifact), nil),
      counts: counts(artifact["counts"]),
      blockers: items(artifact["blockers"], opts.max_items),
      warnings: items(artifact["warnings"], opts.max_items),
      checks: checks,
      raw: artifact,
      sort_unix: generated_at_unix || base.sort_unix
    })
  end

  defp invalid_artifact(base, reason, extra \\ %{}) do
    Map.merge(
      base,
      %{
        status: "invalid",
        error_reason: reason,
        schema_version: "unknown",
        generated_at: nil,
        run_id: nil,
        git_sha: nil,
        node: nil,
        mix_env: nil,
        command: nil,
        artifact_path: nil,
        gate_status: "invalid",
        ops_evidence_matrix: %{},
        operator_runbook: nil,
        artifact_provenance: artifact_provenance(base, %{}, "invalid", reason),
        counts: counts(nil),
        blockers: [],
        warnings: [],
        checks: [],
        raw: nil
      }
    )
    |> Map.merge(extra)
  end

  defp gate_status(artifact) do
    case artifact["gate_status"] do
      value when is_binary(value) and value != "" -> value
      _other -> "unknown"
    end
  end

  defp map_value(%{} = value), do: value
  defp map_value(_value), do: %{}

  defp counts(%{} = counts) do
    %{
      total: int_value(counts["total"]),
      ok: int_value(counts["ok"]),
      attention: int_value(counts["attention"]),
      blocked: int_value(counts["blocked"]),
      error: int_value(counts["error"])
    }
  end

  defp counts(_counts), do: %{total: 0, ok: 0, attention: 0, blocked: 0, error: 0}

  defp checks(checks, max_items) when is_list(checks) do
    checks
    |> Enum.take(max_items)
    |> Enum.map(&normalize_check/1)
  end

  defp checks(_checks, _max_items), do: []

  defp normalize_check(%{} = check) do
    %{
      id: string_value(check["id"], "unknown"),
      task: string_value(check["task"], "unknown"),
      command: string_value(check["command"]),
      mode: string_value(check["mode"], "unknown"),
      status: string_value(check["status"], "unknown"),
      evidence_kind: string_value(check["evidence_kind"]),
      scenario: string_value(check["scenario"]),
      artifact_path: string_value(check["artifact_path"]),
      exit_status: check["exit_status"],
      duration_ms: check["duration_ms"],
      blockers: items(check["blockers"], @default_max_items),
      warnings: items(check["warnings"], @default_max_items),
      evidence_summary: evidence_summary(check)
    }
  end

  defp normalize_check(_check) do
    %{
      id: "unknown",
      task: "unknown",
      command: nil,
      mode: "unknown",
      status: "unknown",
      evidence_kind: nil,
      scenario: nil,
      artifact_path: nil,
      exit_status: nil,
      duration_ms: nil,
      blockers: [],
      warnings: [],
      evidence_summary: nil
    }
  end

  defp artifact_provenance(base, artifact, gate_status, error_reason) do
    %{
      file_name: provenance_value(base.file_name),
      archived_artifact_path: provenance_value(artifact["artifact_path"]),
      schema_version: provenance_value(artifact["schema_version"] || "unknown"),
      git_sha: provenance_value(artifact["git_sha"]),
      node: provenance_value(artifact["node"]),
      mix_env: provenance_value(artifact["mix_env"]),
      generated_at: provenance_value(artifact["generated_at"]),
      modified_at: provenance_value(base.modified_at),
      size_bytes: provenance_value(base.size_bytes),
      gate_status: provenance_value(gate_status),
      error_reason: provenance_value(error_reason)
    }
  end

  defp provenance_value(nil), do: nil
  defp provenance_value(""), do: nil
  defp provenance_value(value), do: summary_value(value)

  defp operator_runbook(artifact, ops_evidence_matrix, checks) do
    config = map_value(artifact["config"])

    rows =
      [
        runbook_row("gate-rerun-command", "gate", "gate_rerun_command", artifact["command"]),
        runbook_row("artifact-path", "artifact", "artifact_path", artifact["artifact_path"]),
        runbook_row(
          "ops-profile",
          "profile",
          "ops_profile",
          config["ops_profile"] || ops_evidence_matrix["profile"]
        ),
        runbook_row(
          "required-rehearsal-kinds",
          "profile",
          "required_rehearsal_kinds",
          config["required_rehearsal_kinds"] ||
            ops_evidence_matrix["required_rehearsal_kinds"]
        ),
        runbook_row(
          "missing-rehearsal-kinds",
          "profile",
          "missing_rehearsal_kinds",
          ops_evidence_matrix["missing_rehearsal_kinds"]
        )
      ]
      |> List.flatten()
      |> Kernel.++(config_flag_rows(config))
      |> Kernel.++(problem_check_rows(checks))
      |> Enum.take(@max_runbook_rows)

    warnings =
      config
      |> runbook_boundary_warnings(checks)
      |> Enum.take(@max_runbook_warnings)

    if rows == [] and warnings == [] do
      nil
    else
      %{
        rows: rows,
        warnings: warnings,
        mutating_boundary: warnings != []
      }
    end
  end

  defp runbook_row(_id, _kind, _label, nil), do: []
  defp runbook_row(_id, _kind, _label, ""), do: []
  defp runbook_row(_id, _kind, _label, []), do: []

  defp runbook_row(id, kind, label, value) do
    [
      %{
        id: id,
        kind: kind,
        label: label,
        value: summary_value(value),
        status: nil,
        check_id: nil,
        task: nil
      }
    ]
  end

  defp config_flag_rows(config) do
    [
      config_flag_row(config, "allow_mutating", "execution_boundary"),
      config_flag_row(config, "include_foreground_scan", "execution_boundary"),
      config_flag_row(config, "fail_on_blocked", "failure_policy"),
      config_flag_row(config, "fail_on_attention", "failure_policy"),
      config_flag_row(config, "strict", "failure_policy")
    ]
    |> List.flatten()
  end

  defp config_flag_row(config, key, kind) do
    if Map.has_key?(config, key) do
      runbook_row(key, kind, key, config[key])
    else
      []
    end
  end

  defp problem_check_rows(checks) when is_list(checks) do
    checks
    |> Enum.with_index()
    |> Enum.flat_map(fn {check, index} ->
      if problem_check?(check) and check.command not in [nil, ""] do
        [
          %{
            id: Enum.join(["problem-check", index, check.id], "-"),
            kind: "problem_check",
            label: "problem_check_command",
            value: summary_value(check.command),
            status: check.status,
            check_id: check.id,
            task: check.task
          }
        ]
      else
        []
      end
    end)
  end

  defp problem_check_rows(_checks), do: []

  defp problem_check?(%{status: status}) when status in ["ok", nil, ""], do: false
  defp problem_check?(%{status: _status}), do: true
  defp problem_check?(_check), do: false

  defp runbook_boundary_warnings(config, checks) do
    []
    |> maybe_runbook_warning(
      config["allow_mutating"] == true,
      "allow-mutating",
      "allow_mutating",
      "true"
    )
    |> maybe_runbook_warning(
      config["include_foreground_scan"] == true,
      "include-foreground-scan",
      "include_foreground_scan",
      "true"
    )
    |> Kernel.++(mutating_check_warnings(checks))
  end

  defp maybe_runbook_warning(warnings, true, id, label, value) do
    [%{id: id, label: label, value: value} | warnings]
  end

  defp maybe_runbook_warning(warnings, false, _id, _label, _value), do: warnings

  defp mutating_check_warnings(checks) when is_list(checks) do
    checks
    |> Enum.with_index()
    |> Enum.flat_map(fn {check, index} ->
      if check.mode == "mutating" do
        [
          %{
            id: Enum.join(["mutating-check", index, check.id], "-"),
            label: "mutating_check",
            value: summary_value([check.id, check.task])
          }
        ]
      else
        []
      end
    end)
  end

  defp mutating_check_warnings(_checks), do: []

  defp evidence_summary(%{"parsed_output" => %{} = parsed} = check) do
    check
    |> check_summary_kind(parsed)
    |> case do
      nil -> nil
      {kind, title, fields} -> build_summary(kind, title, fields)
    end
  end

  defp evidence_summary(_check), do: nil

  defp check_summary_kind(check, parsed) do
    task = string_value(check["task"], "")
    id = string_value(check["id"], "")

    cond do
      task == "maxio.scheduler.evidence" or Map.has_key?(parsed, "schedulers") ->
        scheduler_evidence_summary(parsed)

      task == "maxio.rebalance.workflow" or id == "rebalance_workflow" ->
        rebalance_workflow_summary(parsed)

      task == "maxio.reconcile_index" or task == "maxio.scan" or
          id in ["scanner_reconcile", "foreground_scan"] ->
        scan_summary(parsed)

      task == "maxio.heal.fresh_drives" or id == "fresh_drive_heal" ->
        fresh_drive_heal_summary(parsed)

      true ->
        nil
    end
  end

  defp scheduler_evidence_summary(parsed) do
    scheduler = parsed |> list_value("schedulers") |> List.first() |> map_value()
    rollup = map_value(scheduler["rollup_coverage"])

    fields =
      [
        {"status", parsed["status"]},
        {"scheduler", scheduler["scheduler"]},
        {"scheduler_status", scheduler["status"]},
        {"scheduled_nodes", scheduler["scheduled_nodes"]},
        {"effective_nodes", scheduler["effective_scheduled_nodes"]},
        {"healthy_nodes", scheduler["healthy_scheduled_nodes"]},
        {"missing_nodes", scheduler["missing_expected_nodes"]},
        {"lock_losers", scheduler["lock_loser_nodes"]},
        {"lock_loser_count", scheduler["lock_loser_count"]},
        {"rollup_status", rollup["status"] || rollup["health"]},
        {"rollup_windows", rollup["windows"]},
        {"blocked_runs", scheduler["blocked_runs"]},
        {"failed_runs", scheduler["failed_runs"]},
        {"next_actions", length(list_value(scheduler["next_actions"]))}
      ]

    {"scheduler", "Scheduler Evidence", fields}
  end

  defp rebalance_workflow_summary(parsed) do
    audit = map_value(parsed["rebalance_audit"])

    fields =
      [
        {"status", parsed["status"]},
        {"gate_status", parsed["gate_status"]},
        {"phase", parsed["phase"]},
        {"next_action", parsed["next_action"]},
        {"destructive_next_action", parsed["destructive_next_action?"]},
        {"rebalance_complete", parsed["rebalance_complete?"]},
        {"audit_status", audit["status"]},
        {"routing_mismatches", audit["routing_mismatches"]},
        {"missing_placements", audit["missing_placements"]},
        {"unknown_placements", audit["unknown_placements"]},
        {"stale_topology_hashes", audit["stale_topology_hashes"]},
        {"active_multipart_uploads", audit["active_multipart_uploads"]}
      ]

    {"rebalance", "Rebalance Workflow", fields}
  end

  defp scan_summary(parsed) do
    fields =
      [
        {"status", parsed["status"]},
        {"gate_status", parsed["gate_status"]},
        {"index_status", parsed["index_status"]},
        {"scanned", parsed["scanned"]},
        {"sampled_out", parsed["sampled_out"]},
        {"objects", parsed["object_count"] || parsed["objects"]},
        {"bytes", parsed["total_size"] || parsed["bytes"]},
        {"index_upserted", parsed["index_upserted"]},
        {"index_orphan_shards", parsed["index_orphan_shards"]},
        {"index_orphan_bytes", parsed["index_orphan_bytes"]},
        {"index_orphan_cleaned", parsed["index_orphan_cleaned"]},
        {"drive_online", parsed["drive_online"]},
        {"drive_suspect", parsed["drive_suspect"]},
        {"drive_offline", parsed["drive_offline"]},
        {"drive_heal_required", parsed["drive_heal_required"]},
        {"damaged", parsed["damaged"]},
        {"healed", parsed["healed"]},
        {"unrecoverable", parsed["unrecoverable"]},
        {"missing", parsed["missing"]}
      ]

    {"scan", "Scanner Evidence", fields}
  end

  defp fresh_drive_heal_summary(parsed) do
    enqueue = map_value(parsed["rebalance_enqueue"])
    advance = map_value(parsed["rebalance_advance"])

    fields =
      [
        {"status", parsed["status"]},
        {"gate_status", parsed["gate_status"]},
        {"dry_run", parsed["dry_run"]},
        {"backend", parsed["backend"]},
        {"drives_considered", parsed["drives_considered"]},
        {"drives_selected", parsed["drives_selected"]},
        {"drives_cleared", parsed["drives_cleared"]},
        {"drives_waiting", parsed["drives_waiting"]},
        {"scanned", parsed["scanned"]},
        {"healed_objects", parsed["healed_objects"]},
        {"healed_shards", parsed["healed_shards"]},
        {"unrecoverable", parsed["unrecoverable"]},
        {"missing", parsed["missing"]},
        {"rebalance_enqueue_status", enqueue["status"]},
        {"rebalance_enqueue_reason", enqueue["reason"]},
        {"rebalance_advance_status", advance["status"]},
        {"rebalance_advance_reason", advance["reason"]}
      ]

    {"fresh_drive_heal", "Fresh-Drive Heal Evidence", fields}
  end

  defp build_summary(kind, title, fields) do
    normalized_fields =
      fields
      |> Enum.flat_map(fn {label, value} -> summary_field(label, value) end)
      |> Enum.take(@max_summary_fields)

    if normalized_fields == [] do
      nil
    else
      %{kind: kind, title: title, fields: normalized_fields}
    end
  end

  defp summary_field(_label, nil), do: []
  defp summary_field(_label, ""), do: []
  defp summary_field(label, []), do: [%{label: label, value: "-"}]
  defp summary_field(label, value), do: [%{label: label, value: summary_value(value)}]

  defp summary_value(value) when is_binary(value), do: truncate_value(value)
  defp summary_value(value) when is_integer(value), do: Integer.to_string(value)
  defp summary_value(value) when is_float(value), do: Float.to_string(value)
  defp summary_value(value) when is_boolean(value), do: to_string(value)

  defp summary_value(values) when is_list(values) do
    values
    |> Enum.take(@max_summary_list_items)
    |> Enum.map_join(", ", &summary_value/1)
    |> case do
      "" -> "-"
      value -> truncate_value(value)
    end
  end

  defp summary_value(%{} = value),
    do: truncate_value(inspect(value, limit: 8, printable_limit: 120))

  defp summary_value(value), do: truncate_value(inspect(value, limit: 8, printable_limit: 120))

  defp truncate_value(value), do: String.slice(value, 0, @max_summary_value_chars)

  defp list_value(%{} = map, key), do: list_value(map[key])
  defp list_value(value) when is_list(value), do: value
  defp list_value(nil), do: []
  defp list_value(value), do: [value]

  defp items(items, max_items) when is_list(items) do
    items
    |> Enum.take(max_items)
    |> Enum.map(&normalize_item/1)
  end

  defp items(_items, _max_items), do: []

  defp normalize_item(%{} = item) do
    %{
      reason: string_value(item["reason"], "unknown"),
      check: string_value(item["check"]),
      task: string_value(item["task"]),
      detail: item["detail"] || item
    }
  end

  defp normalize_item(value) when is_binary(value) do
    %{reason: value, check: nil, task: nil, detail: value}
  end

  defp normalize_item(value), do: %{reason: inspect(value), check: nil, task: nil, detail: value}

  defp string_value(value, default \\ nil)
  defp string_value(value, _default) when is_binary(value), do: value
  defp string_value(nil, default), do: default

  defp string_value(value, _default),
    do: inspect(value, limit: 8, printable_limit: 120, charlists: :as_lists)

  defp int_value(value) when is_integer(value), do: value
  defp int_value(value) when is_binary(value), do: parse_int(value)
  defp int_value(_value), do: 0

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> 0
    end
  end

  defp generated_at_unix(nil), do: nil

  defp generated_at_unix(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      _other -> nil
    end
  end

  defp posix_to_iso8601(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _other -> nil
    end
  end

  defp posix_to_iso8601(_value), do: nil

  defp sort_key(artifact), do: {artifact.sort_unix || 0, artifact.file_name}
end
