defmodule Maxio.Ops.CompatMatrix.Artifacts do
  @moduledoc """
  Read-only helpers for S3 compatibility matrix artifact discovery.

  Console pages use this module to inspect archived `Maxio.Compat.Matrix`
  reports. It never runs Mix tasks, external probes, external smoke checks, or
  shell commands, and it never follows user-supplied paths.
  """

  @default_dir "artifacts"
  @default_glob "s3_compat_matrix_*.json"
  @default_limit 20
  @default_max_candidates 100
  @default_max_bytes 2_000_000
  @default_max_items 100
  @max_text 320
  @max_list_items 12
  @sensitive_key_fragments [
    "secret",
    "password",
    "token",
    "credential",
    "authorization",
    "access_key",
    "raw",
    "body",
    "data"
  ]
  @sensitive_text_patterns [
    ~r/(AWS4-HMAC-SHA256\s+Credential=)[^\s,]+/i,
    ~r/(authorization:?\s*)[^\s,]+/i,
    ~r/((?:--)?[a-z0-9_-]*(?:secret|password|token|credential|access[-_]?key)[a-z0-9_-]*(?:=|\s+))[^\s,;\]]+/i,
    ~r/()[^\s,;]*(?:secret|password|token|credential|access)[^\s,;]*/i
  ]

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
          Application.get_env(:maxio, :compat_matrix_artifacts_dir, @default_dir),
      glob:
        Keyword.get(opts, :glob) ||
          Application.get_env(:maxio, :compat_matrix_artifacts_glob, @default_glob),
      limit: positive_int(Keyword.get(opts, :limit), @default_limit),
      max_candidates: positive_int(Keyword.get(opts, :max_candidates), @default_max_candidates),
      max_bytes: positive_int(Keyword.get(opts, :max_bytes), @default_max_bytes),
      max_items: positive_int(Keyword.get(opts, :max_items), @default_max_items)
    }
  end

  defp artifact_paths(dir, opts) do
    with {:ok, names} <- File.ls(dir),
         {:ok, matcher} <- safe_glob_matcher(opts.glob) do
      names
      |> Enum.filter(&safe_path_segment?/1)
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

  # 两个调用方原先各自用 `when is_binary(...)` + 非二进制兜底再包一层，
  # 与 `safe_path_segment?/1` 自己的 `is_binary` 守卫 + false 兜底完全重复，
  # 并让后者的兜底永远不可达。合并成一层：非二进制输入直接进谓词兜底得到 false，
  # 结果逐字相同（`safe_glob_matcher` 仍是 `:error`，候选名仍被过滤掉）。
  defp safe_glob_matcher(glob) do
    if safe_path_segment?(glob) do
      regex = glob_to_regex(glob)
      {:ok, fn name -> Regex.match?(regex, name) end}
    else
      :error
    end
  end

  defp safe_path_segment?(value) when is_binary(value) do
    value not in ["", ".", ".."] and
      not String.contains?(value, ["/", "\\", ".."]) and
      Path.basename(value) == value
  end

  defp safe_path_segment?(_value), do: false

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
         true <- compat_matrix_artifact?(decoded) do
      normalize_artifact(decoded, base, opts)
    else
      {:error, %Jason.DecodeError{}} -> invalid_artifact(base, "json_unparseable")
      {:error, reason} -> invalid_artifact(base, "read_error", %{read_error: inspect(reason)})
      false -> invalid_artifact(base, "not_compat_matrix_artifact")
      _other -> invalid_artifact(base, "invalid_artifact")
    end
  rescue
    _error -> invalid_artifact(base, "read_error")
  end

  defp compat_matrix_artifact?(artifact) do
    Map.has_key?(artifact, "gate_status") and
      (Map.has_key?(artifact, "suites") or Map.has_key?(artifact, "external_clients") or
         Map.has_key?(artifact, "external_smoke"))
  end

  defp normalize_artifact(artifact, base, opts) do
    shape_errors = section_shape_errors(artifact)
    suites = entries(artifact["suites"], opts.max_items, &suite_entry/1)

    external_clients =
      entries(artifact["external_clients"], opts.max_items, &external_client_entry/1)

    external_smoke = entries(artifact["external_smoke"], opts.max_items, &external_smoke_entry/1)
    blockers = shape_errors ++ items(artifact["blockers"], opts.max_items)
    warnings = items(artifact["warnings"], opts.max_items)
    generated_at = string_value(artifact["generated_at"])
    generated_at_unix = generated_at_unix(generated_at)
    count_check = count_check(artifact["counts"], suites, external_clients, external_smoke)

    base
    |> Map.merge(%{
      status: if(shape_errors == [], do: "ok", else: "invalid"),
      error_reason: if(shape_errors == [], do: nil, else: "malformed_sections"),
      schema_version: summary_value(artifact["schema_version"] || "unknown"),
      generated_at: generated_at,
      run_id: string_value(artifact["run_id"]),
      git_sha: string_value(artifact["git_sha"]),
      node: string_value(artifact["node"]),
      mix_env: string_value(artifact["mix_env"]),
      command: summary_value(artifact["command"]),
      gate_status: status_value(artifact["gate_status"]),
      config: config_summary(artifact["config"]),
      counts: counts(artifact["counts"]),
      count_check: count_check,
      blockers: blockers,
      warnings: warnings,
      suites: suites,
      external_clients: external_clients,
      external_smoke: external_smoke,
      streaming_stress: streaming_stress(suites),
      artifact_provenance: artifact_provenance(base, artifact, nil),
      sort_unix: generated_at_unix || base.sort_unix
    })
  end

  defp invalid_artifact(base, reason, extra \\ %{}) do
    base
    |> Map.merge(%{
      status: "invalid",
      error_reason: reason,
      schema_version: "unknown",
      generated_at: nil,
      run_id: nil,
      git_sha: nil,
      node: nil,
      mix_env: nil,
      command: nil,
      gate_status: "invalid",
      config: %{},
      counts: %{"total" => 0, "ok" => 0, "attention" => 0, "blocked" => 0, "error" => 0},
      count_check: %{status: "blocked", reason: reason, expected: %{}, actual: %{}},
      blockers: [%{"reason" => reason}],
      warnings: [],
      suites: [],
      external_clients: [],
      external_smoke: [],
      streaming_stress: nil,
      artifact_provenance: artifact_provenance(base, %{}, reason)
    })
    |> Map.merge(extra)
  end

  defp entries(values, max_items, fun) when is_list(values) do
    values
    |> Enum.take(max_items)
    |> Enum.map(fun)
  end

  defp entries(_values, _max_items, _fun), do: []

  defp section_shape_errors(artifact) do
    ["suites", "external_clients", "external_smoke"]
    |> Enum.flat_map(fn key ->
      case Map.fetch(artifact, key) do
        {:ok, value} when is_list(value) ->
          []

        {:ok, _value} ->
          [%{"entry" => key, "kind" => "compat_matrix_section", "reason" => "malformed_section"}]

        :error ->
          []
      end
    end)
  end

  defp suite_entry(entry) when is_map(entry) do
    exunit = map_value(entry["exunit"])
    evidence = map_value(entry["evidence"])

    %{
      id: summary_value(entry["id"]),
      kind: "internal_suite",
      name: summary_value(entry["name"]),
      status: status_value(entry["status"]),
      mode: summary_value(entry["mode"]),
      path: summary_value(entry["path"]),
      command: summary_value(entry["mix_command"] || entry["command"]),
      exit_status: scalar_value(entry["exit_status"]),
      duration_ms: scalar_value(entry["duration_ms"]),
      tests: scalar_value(exunit["tests"]),
      failures: scalar_value(exunit["failures"]),
      excluded: scalar_value(exunit["excluded"]),
      output_snippet: summary_value(entry["output_snippet"]),
      blockers: items(entry["blockers"], @max_list_items),
      warnings: items(entry["warnings"], @max_list_items),
      evidence: sanitize_value(evidence)
    }
  end

  defp suite_entry(_entry) do
    %{
      id: "invalid_suite",
      kind: "internal_suite",
      name: "-",
      status: "blocked",
      mode: "-",
      path: "-",
      command: "-",
      exit_status: "-",
      duration_ms: "-",
      tests: "-",
      failures: "-",
      excluded: "-",
      output_snippet: "-",
      blockers: [%{"reason" => "invalid_suite_entry"}],
      warnings: [],
      evidence: %{}
    }
  end

  defp external_client_entry(entry) when is_map(entry) do
    %{
      id: summary_value(entry["id"]),
      kind: "external_client",
      label: summary_value(entry["label"]),
      status: status_value(entry["status"]),
      mode: summary_value(entry["mode"]),
      executable: executable_name(entry["path"]),
      detail: summary_value(entry["detail"]),
      blockers: items(entry["blockers"], @max_list_items),
      warnings: items(entry["warnings"], @max_list_items)
    }
  end

  defp external_client_entry(_entry) do
    %{
      id: "invalid_external_client",
      kind: "external_client",
      label: "-",
      status: "blocked",
      mode: "-",
      executable: "-",
      detail: "-",
      blockers: [%{"reason" => "invalid_external_client_entry"}],
      warnings: []
    }
  end

  defp external_smoke_entry(entry) when is_map(entry) do
    %{
      id: summary_value(entry["id"]),
      kind: "external_smoke",
      label: summary_value(entry["label"]),
      status: status_value(entry["status"]),
      mode: summary_value(entry["mode"]),
      duration_ms: scalar_value(entry["duration_ms"]),
      step_count: length(list_value(entry["steps"])),
      scenario_counts: sanitize_value(map_value(entry["scenario_counts"])),
      blockers: items(entry["blockers"], @max_list_items),
      warnings: items(entry["warnings"], @max_list_items)
    }
  end

  defp external_smoke_entry(_entry) do
    %{
      id: "invalid_external_smoke",
      kind: "external_smoke",
      label: "-",
      status: "blocked",
      mode: "-",
      duration_ms: "-",
      step_count: 0,
      scenario_counts: %{},
      blockers: [%{"reason" => "invalid_external_smoke_entry"}],
      warnings: []
    }
  end

  defp config_summary(config) when is_map(config) do
    config
    |> map_value()
    |> Map.take([
      "default_suites",
      "optional_suites",
      "requested_suites",
      "skip_external_probes",
      "no_internal_suites",
      "include_external_smoke",
      "fail_on_blocked",
      "fail_on_attention",
      "strict",
      "external_smoke"
    ])
    |> sanitize_value()
  end

  defp config_summary(_config), do: %{}

  defp counts(counts) when is_map(counts) do
    %{
      "total" => non_negative_int(counts["total"]),
      "ok" => non_negative_int(counts["ok"]),
      "attention" => non_negative_int(counts["attention"]),
      "blocked" => non_negative_int(counts["blocked"]),
      "error" => non_negative_int(counts["error"])
    }
  end

  defp counts(_counts),
    do: %{"total" => 0, "ok" => 0, "attention" => 0, "blocked" => 0, "error" => 0}

  defp count_check(counts, suites, external_clients, external_smoke) do
    expected = counts(counts)
    entries = suites ++ external_clients ++ external_smoke

    actual = %{
      "total" => length(entries),
      "ok" => Enum.count(entries, &(&1.status == "ok")),
      "attention" => Enum.count(entries, &(&1.status == "attention")),
      "blocked" => Enum.count(entries, &(&1.status == "blocked")),
      "error" => Enum.count(entries, &(&1.status == "error"))
    }

    if expected == actual do
      %{status: "ok", reason: "counts_match", expected: expected, actual: actual}
    else
      %{status: "blocked", reason: "counts_mismatch", expected: expected, actual: actual}
    end
  end

  defp streaming_stress(suites) do
    Enum.find_value(suites, fn
      %{id: "streaming_stress_matrix", evidence: evidence} when is_map(evidence) ->
        %{
          status: "ok",
          profile: summary_value(evidence["profile"]),
          parameters: sanitize_value(map_value(evidence["parameters"])),
          env: sanitize_value(map_value(evidence["env"])),
          scenarios:
            evidence |> Map.get("scenarios") |> list_value() |> Enum.map(&summary_value/1)
        }

      _suite ->
        nil
    end) ||
      %{
        status: "attention",
        profile: "not_present",
        parameters: %{},
        env: %{},
        scenarios: []
      }
  end

  defp artifact_provenance(base, artifact, invalid_reason) do
    %{
      file_name: base.file_name,
      size_bytes: base.size_bytes,
      modified_at: base.modified_at,
      schema_version: summary_value(artifact["schema_version"] || "unknown"),
      generated_at: summary_value(artifact["generated_at"]),
      run_id: summary_value(artifact["run_id"]),
      git_sha: summary_value(artifact["git_sha"]),
      node: summary_value(artifact["node"]),
      mix_env: summary_value(artifact["mix_env"]),
      gate_status: status_value(artifact["gate_status"] || "invalid"),
      invalid_reason: invalid_reason
    }
  end

  defp items(values, max_items) when is_list(values) do
    values
    |> Enum.take(max_items)
    |> Enum.map(&item/1)
  end

  defp items(_values, _max_items), do: []

  defp item(value) when is_map(value) do
    value
    |> map_value()
    |> Map.take(["entry", "kind", "reason", "detail", "message", "client", "step", "exit_status"])
    |> sanitize_value()
  end

  defp item(value), do: %{"reason" => summary_value(value)}

  defp status_value(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.trim()
    |> case do
      status when status in ["ok", "attention", "blocked", "error", "invalid"] -> status
      "" -> "unknown"
      _other -> "unknown"
    end
  end

  defp status_value(value) when is_atom(value), do: value |> Atom.to_string() |> status_value()
  defp status_value(_value), do: "unknown"

  defp string_value(nil), do: nil
  defp string_value(value) when is_binary(value), do: String.trim(value)
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value), do: to_string(value)

  defp summary_value(nil), do: "-"

  defp summary_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> redact_text()
    |> truncate(@max_text)
    |> case do
      "" -> "-"
      text -> text
    end
  end

  defp summary_value(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: value

  defp summary_value(value) when is_atom(value), do: Atom.to_string(value)

  defp summary_value(value) do
    value
    |> inspect(limit: 12, printable_limit: @max_text)
    |> summary_value()
  end

  defp scalar_value(nil), do: "-"

  defp scalar_value(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: value

  defp scalar_value(value), do: summary_value(value)

  defp executable_name(nil), do: "-"

  defp executable_name(value) when is_binary(value),
    do: value |> Path.basename() |> summary_value()

  defp executable_name(value), do: summary_value(value)

  defp sanitize_value(%{} = map) do
    Map.new(map, fn {key, value} ->
      key = to_string(key)

      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, sanitize_value(value)}
      end
    end)
  end

  defp sanitize_value(values) when is_list(values) do
    values
    |> Enum.take(@max_list_items)
    |> Enum.map(&sanitize_value/1)
  end

  defp sanitize_value(value) when is_binary(value), do: summary_value(value)

  defp sanitize_value(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: value

  defp sanitize_value(nil), do: nil
  defp sanitize_value(value), do: summary_value(value)

  defp sensitive_key?(key) do
    downcased = String.downcase(key)
    Enum.any?(@sensitive_key_fragments, &String.contains?(downcased, &1))
  end

  defp redact_text(text) do
    Enum.reduce(@sensitive_text_patterns, text, fn pattern, acc ->
      Regex.replace(pattern, acc, "\\1[REDACTED]")
    end)
  end

  defp map_value(value) when is_map(value),
    do: Map.new(value, fn {key, val} -> {to_string(key), val} end)

  defp map_value(_value), do: %{}

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> 0
    end
  end

  defp non_negative_int(_value), do: 0

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp generated_at_unix(nil), do: nil

  defp generated_at_unix(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      _other -> nil
    end
  end

  defp generated_at_unix(_value), do: nil

  defp posix_to_iso8601(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _other -> nil
    end
  end

  defp posix_to_iso8601(_value), do: nil

  defp sort_key(%{sort_unix: unix}) when is_integer(unix), do: unix
  defp sort_key(_artifact), do: 0

  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    binary_part(text, 0, max) <> "..."
  end
end
