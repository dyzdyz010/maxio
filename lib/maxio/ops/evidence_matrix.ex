defmodule Maxio.Ops.EvidenceMatrix do
  @moduledoc """
  Read-only evidence matrix helpers for P0/M8 operator rehearsal artifacts.

  The matrix consumes already-written rehearsal artifacts and turns them into
  `Maxio.Ops.Gate`-compatible checks. It never executes operator actions.
  """

  @supported_kinds [
    "replacement_live_rehearsal",
    "scheduler_live_rehearsal",
    "ops_gate"
  ]

  @scheduler_names ["fresh_drive_heal", "rebalance", "all"]
  @max_artifact_bytes 2_000_000

  def supported_kinds, do: @supported_kinds

  def checks(paths, required_kinds, opts \\ []) do
    paths = string_list(paths)
    required_kinds = required_kinds |> string_list() |> Enum.uniq()
    max_bytes = Keyword.get(opts, :max_bytes, @max_artifact_bytes)

    artifact_checks =
      paths
      |> Enum.with_index(1)
      |> Enum.map(fn {path, index} -> artifact_check(path, index, max_bytes) end)

    covered_kinds =
      artifact_checks
      |> Enum.map(& &1["evidence_kind"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    missing_checks =
      required_kinds
      |> Enum.reject(&(&1 in covered_kinds))
      |> Enum.map(&missing_kind_check/1)

    artifact_checks ++ missing_checks
  end

  def summary(paths, required_kinds, checks) do
    paths = string_list(paths)
    required_kinds = required_kinds |> string_list() |> Enum.uniq()

    covered_kinds =
      checks
      |> Enum.map(& &1["evidence_kind"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    missing_kinds = Enum.reject(required_kinds, &(&1 in covered_kinds))

    %{
      "artifact_count" => length(paths),
      "required_rehearsal_kinds" => required_kinds,
      "covered_rehearsal_kinds" => covered_kinds,
      "missing_rehearsal_kinds" => missing_kinds
    }
  end

  defp artifact_check(path, index, max_bytes) do
    started = System.monotonic_time(:millisecond)
    expanded = Path.expand(path)

    with {:ok, stat} <- File.lstat(expanded),
         true <- stat.type == :regular,
         true <- stat.size <= max_bytes,
         {:ok, contents} <- File.read(expanded),
         {:ok, artifact} <- Jason.decode(contents),
         true <- is_map(artifact),
         {:ok, kind} <- infer_kind(artifact) do
      duration_ms = System.monotonic_time(:millisecond) - started
      artifact_check_view(path, expanded, index, kind, artifact, duration_ms)
    else
      {:error, %Jason.DecodeError{}} ->
        error_check(path, expanded, index, "rehearsal_artifact_json_unparseable", started)

      {:error, :unknown_kind} ->
        error_check(path, expanded, index, "rehearsal_artifact_unrecognized", started)

      {:error, {:kind_mismatch, explicit_kind, matching_kinds}} ->
        error_check(path, expanded, index, "rehearsal_artifact_kind_mismatch", started, %{
          "evidence_kind" => explicit_kind,
          "matching_kinds" => matching_kinds
        })

      {:error, {:ambiguous_kind, matching_kinds}} ->
        error_check(path, expanded, index, "rehearsal_artifact_ambiguous_kind", started, %{
          "matching_kinds" => matching_kinds
        })

      {:error, {:schema_invalid, explicit_kind}} ->
        error_check(path, expanded, index, "rehearsal_artifact_schema_invalid", started, %{
          "evidence_kind" => explicit_kind
        })

      {:error, reason} ->
        error_check(path, expanded, index, "rehearsal_artifact_read_error", started, %{
          "read_error" => inspect(reason)
        })

      false ->
        error_check(path, expanded, index, "rehearsal_artifact_invalid", started)
    end
  rescue
    error ->
      error_check(
        path,
        Path.expand(path),
        index,
        "rehearsal_artifact_exception",
        System.monotonic_time(:millisecond),
        %{"message" => Exception.message(error)}
      )
  end

  defp artifact_check_view(path, expanded, index, kind, artifact, duration_ms) do
    gate = artifact_gate(kind, artifact)

    %{
      "id" => "rehearsal_artifact_#{index}",
      "task" => "artifact:#{kind}",
      "command" => "read #{path}",
      "mode" => "read_only_artifact",
      "required" => true,
      "status" => gate.status,
      "exit_status" => nil,
      "duration_ms" => duration_ms,
      "parsed_output" => artifact,
      "raw_output" => nil,
      "artifact_path" => expanded,
      "evidence_kind" => kind,
      "scenario" => scenario(kind, artifact),
      "blockers" => gate.blockers,
      "warnings" => gate.warnings
    }
  end

  defp infer_kind(%{"evidence_kind" => explicit_kind} = artifact) do
    matching_kinds = matching_kinds(artifact)

    cond do
      not is_binary(explicit_kind) ->
        {:error, {:schema_invalid, safe_string(explicit_kind)}}

      explicit_kind not in @supported_kinds ->
        {:error, :unknown_kind}

      length(matching_kinds) > 1 ->
        {:error, {:ambiguous_kind, matching_kinds}}

      explicit_kind in matching_kinds ->
        {:ok, explicit_kind}

      matching_kinds != [] ->
        {:error, {:kind_mismatch, explicit_kind, matching_kinds}}

      true ->
        {:error, {:schema_invalid, explicit_kind}}
    end
  end

  defp infer_kind(artifact) do
    case matching_kinds(artifact) do
      [kind] -> {:ok, kind}
      [] -> {:error, :unknown_kind}
      matching_kinds -> {:error, {:ambiguous_kind, matching_kinds}}
    end
  end

  defp matching_kinds(artifact) do
    [
      {"replacement_live_rehearsal", replacement_rehearsal_shape?(artifact)},
      {"scheduler_live_rehearsal", scheduler_rehearsal_shape?(artifact)},
      {"ops_gate", ops_gate_shape?(artifact)}
    ]
    |> Enum.filter(fn {_kind, matches?} -> matches? end)
    |> Enum.map(fn {kind, _matches?} -> kind end)
  end

  defp replacement_rehearsal_shape?(%{} = artifact) do
    is_map(artifact["replacement_workflow"]) and
      (is_map(artifact["bundle_gate"]) or is_map(artifact["gate"]))
  end

  defp replacement_rehearsal_shape?(_artifact), do: false

  defp scheduler_rehearsal_shape?(%{} = artifact) do
    artifact["scheduler"] in @scheduler_names and is_map(artifact["scheduler_evidence"])
  end

  defp scheduler_rehearsal_shape?(_artifact), do: false

  defp ops_gate_shape?(%{} = artifact) do
    is_binary(artifact["gate_status"]) and is_list(artifact["checks"])
  end

  defp ops_gate_shape?(_artifact), do: false

  defp artifact_gate("replacement_live_rehearsal", artifact) do
    gate = map_value(artifact["bundle_gate"]) || map_value(artifact["gate"]) || %{}
    status = string_value(gate["status"], "unknown")
    reason = string_value(gate["reason"], "replacement_live_rehearsal_not_clear")

    if status == "ok" do
      gate_result("ok")
    else
      gate_result("blocked", [%{"reason" => reason, "gate_status" => status, "gate" => gate}])
    end
  end

  defp artifact_gate("scheduler_live_rehearsal", artifact) do
    evidence = map_value(artifact["scheduler_evidence"]) || %{}
    status = string_value(evidence["status"], "unknown")
    warnings = list_value(evidence["warnings"])
    blockers = list_value(evidence["blockers"])
    exit_status = artifact["evidence_exit_status"]

    cond do
      status == "ok" and warnings == [] and exit_status in [0, nil] ->
        gate_result("ok")

      status == "blocked" ->
        gate_result("blocked", [
          %{
            "reason" => "scheduler_evidence_status_blocked",
            "evidence_status" => status,
            "blockers" => blockers
          }
        ])

      status == "attention" ->
        gate_result("blocked", [
          %{
            "reason" => "scheduler_evidence_status_attention",
            "evidence_status" => status,
            "warnings" => warnings
          }
        ])

      warnings != [] ->
        gate_result("blocked", [
          %{
            "reason" => "scheduler_evidence_warnings",
            "evidence_status" => status,
            "warnings" => warnings
          }
        ])

      exit_status not in [0, nil] ->
        gate_result("blocked", [
          %{
            "reason" => "scheduler_evidence_exit_nonzero",
            "evidence_exit_status" => exit_status,
            "evidence_status" => status
          }
        ])

      true ->
        gate_result("blocked", [
          %{"reason" => "scheduler_evidence_status_#{status}", "evidence_status" => status}
        ])
    end
  end

  defp artifact_gate("ops_gate", artifact) do
    case string_value(artifact["gate_status"], "unknown") do
      "ok" ->
        gate_result("ok")

      "attention" ->
        gate_result("attention", [], list_value(artifact["warnings"]))

      "blocked" ->
        gate_result("blocked", list_value(artifact["blockers"]))

      "error" ->
        gate_result("error", list_value(artifact["blockers"]))

      other ->
        gate_result("error", [%{"reason" => "ops_gate_status_#{other}"}])
    end
  end

  defp missing_kind_check(kind) do
    %{
      "id" => "required_rehearsal_kind_#{kind}",
      "task" => "artifact:#{kind}",
      "command" => "read required #{kind}",
      "mode" => "read_only_artifact",
      "required" => true,
      "status" => "blocked",
      "exit_status" => nil,
      "duration_ms" => 0,
      "parsed_output" => nil,
      "raw_output" => nil,
      "artifact_path" => nil,
      "evidence_kind" => nil,
      "scenario" => "required_rehearsal_kind",
      "blockers" => [%{"reason" => "required_rehearsal_kind_missing", "kind" => kind}],
      "warnings" => []
    }
  end

  defp error_check(path, expanded, index, reason, started, extra \\ %{}) do
    duration_ms = System.monotonic_time(:millisecond) - started

    %{
      "id" => "rehearsal_artifact_#{index}",
      "task" => "artifact:unknown",
      "command" => "read #{path}",
      "mode" => "read_only_artifact",
      "required" => true,
      "status" => "error",
      "exit_status" => nil,
      "duration_ms" => duration_ms,
      "parsed_output" => nil,
      "raw_output" => nil,
      "artifact_path" => expanded,
      "evidence_kind" => nil,
      "scenario" => "rehearsal_artifact_read",
      "blockers" => [Map.merge(%{"reason" => reason}, extra)],
      "warnings" => []
    }
  end

  defp gate_result(status, blockers \\ [], warnings \\ []) do
    %{status: status, blockers: list_value(blockers), warnings: list_value(warnings)}
  end

  defp scenario("replacement_live_rehearsal", artifact) do
    workflow = map_value(artifact["replacement_workflow"]) || %{}
    phase = string_value(workflow["phase"], "unknown")
    "replacement_workflow:#{phase}"
  end

  defp scenario("scheduler_live_rehearsal", artifact) do
    "scheduler_evidence:#{string_value(artifact["scheduler"], "unknown")}"
  end

  defp scenario("ops_gate", _artifact), do: "ops_gate"

  defp map_value(%{} = value), do: value
  defp map_value(_value), do: nil

  defp list_value(value) when is_list(value), do: value
  defp list_value(nil), do: []
  defp list_value(value), do: [value]

  defp string_list(values) when is_list(values), do: Enum.map(values, &safe_string/1)
  defp string_list(nil), do: []
  defp string_list(value), do: [safe_string(value)]

  defp string_value(value, default)
  defp string_value(value, _default) when is_binary(value), do: value
  defp string_value(nil, default), do: default
  defp string_value(value, _default), do: safe_string(value)

  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_string(value) when is_float(value), do: Float.to_string(value)

  # 布尔量由上面的 is_atom/1 子句吸收（Atom.to_string(true) == to_string(true)），无需单列。
  defp safe_string(value), do: inspect(value, limit: 20, printable_limit: 200)
end
