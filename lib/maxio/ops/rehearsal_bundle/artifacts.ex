defmodule Maxio.Ops.RehearsalBundle.Artifacts do
  @moduledoc """
  Read-only helpers for P0 live rehearsal bundle artifact discovery.

  Console pages use this module to inspect archived
  `Maxio.Ops.LiveRehearsalBundle` reports. It never executes Mix tasks and
  never follows user-supplied paths.
  """

  @default_dir "artifacts"
  @default_glob "m8_p0_ops_live_rehearsal_*_bundle.json"
  @default_limit 20
  @default_max_candidates 100
  @default_max_bytes 2_000_000
  @max_summary_list_items 6
  @max_summary_value_chars 160
  @child_result_keys [
    {"replacement_live_rehearsal", "replacement"},
    {"scheduler_live_rehearsal", "scheduler"},
    {"ops_gate", "ops gate"}
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

  def related_bundle(_bundles, nil), do: nil

  def related_bundle(bundles, gate_artifact) when is_list(bundles) do
    gate_path = gate_artifact_path(gate_artifact)
    gate_file = gate_artifact_file(gate_artifact)

    Enum.find(bundles, &matching_bundle_path?(&1, gate_path)) ||
      Enum.find(bundles, &matching_bundle_file?(&1, gate_file))
  end

  def related_bundle(_bundles, _gate_artifact), do: nil

  defp normalize_opts(opts) do
    %{
      dir:
        Keyword.get(opts, :dir) ||
          Application.get_env(:maxio, :ops_rehearsal_bundle_artifacts_dir) ||
          Application.get_env(:maxio, :ops_gate_artifacts_dir, @default_dir),
      glob:
        Keyword.get(opts, :glob) ||
          Application.get_env(:maxio, :ops_rehearsal_bundle_artifacts_glob, @default_glob),
      limit: positive_int(Keyword.get(opts, :limit), @default_limit),
      max_candidates: positive_int(Keyword.get(opts, :max_candidates), @default_max_candidates),
      max_bytes: positive_int(Keyword.get(opts, :max_bytes), @default_max_bytes)
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
      size_bytes: stat.size,
      modified_at: posix_to_iso8601(stat.mtime),
      modified_at_unix: stat.mtime,
      sort_unix: stat.mtime
    }

    cond do
      stat.size > opts.max_bytes ->
        invalid_artifact(base, "artifact_too_large")

      true ->
        decode_artifact(path, base)
    end
  end

  defp decode_artifact(path, base) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         true <- is_map(decoded),
         true <- rehearsal_bundle_artifact?(decoded) do
      normalize_artifact(decoded, base)
    else
      {:error, %Jason.DecodeError{}} -> invalid_artifact(base, "json_unparseable")
      {:error, reason} -> invalid_artifact(base, "read_error", %{read_error: inspect(reason)})
      false -> invalid_artifact(base, "not_live_rehearsal_bundle")
      _other -> invalid_artifact(base, "invalid_artifact")
    end
  rescue
    _error -> invalid_artifact(base, "read_error")
  end

  defp rehearsal_bundle_artifact?(artifact) do
    artifact["evidence_kind"] == "p0_ops_live_rehearsal_bundle"
  end

  defp normalize_artifact(artifact, base) do
    generated_at = string_value(artifact["generated_at"])
    generated_at_unix = generated_at_unix(generated_at)
    artifact_paths = artifact_paths_value(artifact["artifact_paths"])
    commands = commands_value(artifact["commands"])

    base
    |> Map.merge(%{
      status: "ok",
      error_reason: nil,
      schema_version: summary_value(artifact["schema_version"] || "unknown"),
      evidence_kind: string_value(artifact["evidence_kind"]),
      scenario: string_value(artifact["scenario"]),
      generated_at: generated_at,
      run_id: string_value(artifact["run_id"]),
      git_sha: string_value(artifact["git_sha"]),
      node: string_value(artifact["node"]),
      mix_env: string_value(artifact["mix_env"]),
      gate_status: gate_status(artifact),
      replacement_mode: string_value(artifact["replacement_mode"], "unknown"),
      replacement_rehearsal_ready?: bool_value(artifact["replacement_rehearsal_ready?"]),
      scheduler_mode: string_value(artifact["scheduler_mode"], "unknown"),
      scheduler: string_value(artifact["scheduler"]),
      artifact_paths: artifact_paths,
      commands: commands,
      child_results: child_results(artifact["child_results"], artifact_paths, commands),
      boundary_warnings: boundary_warnings(artifact),
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
        evidence_kind: nil,
        scenario: nil,
        generated_at: nil,
        run_id: nil,
        git_sha: nil,
        node: nil,
        mix_env: nil,
        gate_status: "invalid",
        replacement_mode: nil,
        replacement_rehearsal_ready?: nil,
        scheduler_mode: nil,
        scheduler: nil,
        artifact_paths: %{},
        commands: %{},
        child_results: [],
        boundary_warnings: [],
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

  defp artifact_paths_value(%{} = paths) do
    @child_result_keys
    |> Enum.map(fn {key, _label} -> {key, maybe_summary(paths[key])} end)
    |> Kernel.++([{"bundle", maybe_summary(paths["bundle"])}])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp artifact_paths_value(_paths), do: %{}

  defp commands_value(%{} = commands) do
    @child_result_keys
    |> Enum.map(fn {key, _label} -> {key, maybe_summary(commands[key])} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp commands_value(_commands), do: %{}

  defp child_results(%{} = results, artifact_paths, commands) do
    Enum.map(@child_result_keys, fn {key, label} ->
      child_result(key, label, map_value(results[key]), artifact_paths, commands)
    end)
  end

  defp child_results(_results, artifact_paths, commands) do
    Enum.map(@child_result_keys, fn {key, label} ->
      child_result(key, label, %{}, artifact_paths, commands)
    end)
  end

  defp child_result(key, label, result, artifact_paths, commands) do
    %{
      id: key,
      label: label,
      status: string_value(result["status"], "unknown"),
      exit_code: maybe_summary(result["exit_code"]),
      gate_status: maybe_summary(result["gate_status"]),
      artifact_path: Map.get(artifact_paths, key) || maybe_summary(result["artifact_path"]),
      command: Map.get(commands, key)
    }
  end

  defp boundary_warnings(artifact) do
    []
    |> maybe_boundary_warning(
      artifact["replacement_mode"] == "live",
      "replacement-live",
      "replacement_mode",
      "live"
    )
    |> maybe_boundary_warning(
      artifact["scheduler_mode"] == "enabled_rehearsal",
      "scheduler-enabled",
      "scheduler_mode",
      "enabled_rehearsal"
    )
    |> Enum.reverse()
  end

  defp maybe_boundary_warning(warnings, true, id, label, value) do
    [%{id: id, label: label, value: value} | warnings]
  end

  defp maybe_boundary_warning(warnings, false, _id, _label, _value), do: warnings

  defp gate_artifact_path(%{artifact_path: path}) when is_binary(path) and path != "", do: path

  defp gate_artifact_path(%{artifact_provenance: %{archived_artifact_path: path}})
       when is_binary(path) and path != "",
       do: path

  defp gate_artifact_path(_gate_artifact), do: nil

  defp gate_artifact_file(%{file_name: file_name}) when is_binary(file_name) and file_name != "",
    do: file_name

  defp gate_artifact_file(_gate_artifact), do: nil

  defp matching_bundle_path?(%{status: "ok", artifact_paths: %{"ops_gate" => path}}, gate_path)
       when is_binary(path) and is_binary(gate_path) do
    path == gate_path or path_basename(path) == path_basename(gate_path)
  end

  defp matching_bundle_path?(_bundle, _gate_path), do: false

  defp matching_bundle_file?(%{status: "ok", artifact_paths: %{"ops_gate" => path}}, gate_file)
       when is_binary(path) and is_binary(gate_file) do
    path_basename(path) == gate_file
  end

  defp matching_bundle_file?(_bundle, _gate_file), do: false

  defp path_basename(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> Path.basename()
  end

  defp map_value(%{} = value), do: value
  defp map_value(_value), do: %{}

  defp maybe_summary(nil), do: nil
  defp maybe_summary(""), do: nil
  defp maybe_summary(value), do: summary_value(value)

  defp string_value(value, default \\ nil)
  defp string_value(value, _default) when is_binary(value), do: value
  defp string_value(nil, default), do: default

  defp string_value(value, _default),
    do: inspect(value, limit: 8, printable_limit: 120, charlists: :as_lists)

  defp bool_value(value) when is_boolean(value), do: value
  defp bool_value(_value), do: nil

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
