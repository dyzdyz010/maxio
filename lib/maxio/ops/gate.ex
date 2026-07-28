defmodule Maxio.Ops.Gate do
  @moduledoc """
  Unified M8 operator gate harness.

  The harness shells out to existing operator-facing Mix tasks, archives their
  machine-readable evidence, and computes a single release/preflight gate.
  Defaults are deliberately read-only/no-start oriented; heavyweight or mutating
  checks require explicit opt-in flags.
  """

  alias Maxio.Cluster.Replacement.AutomationProfile
  alias Maxio.Ops.EvidenceMatrix

  @usage """
  Usage:
    mix maxio.ops.gate [--json] [--artifact PATH] [--mix-cmd mix]
      [--fail-on-blocked] [--fail-on-attention] [--strict]
      [--ops-profile p0_ops_1]
      [--replacement-rehearsal-ready]
      [--rehearsal-artifact PATH ...]
      [--require-rehearsal-kinds replacement_live_rehearsal,scheduler_live_rehearsal]
      [--include-scanner]
      [--include-fresh-drive-heal]
      [--include-foreground-scan --allow-mutating]
      [--include-scheduler-evidence
       [--evidence-scheduler fresh_drive_heal|rebalance]
       [--evidence-from ISO8601Z] [--evidence-until ISO8601Z]
       [--evidence-since-minutes N] [--evidence-window-minutes N]
       [--evidence-expected-interval-ms N] [--evidence-stale-after-ms N]
       [--evidence-expected-nodes node_a,node_b]
       [--evidence-min-effective-nodes N]
       [--evidence-require-lock-loser] [--evidence-require-rollups]]

  Default checks:
    maxio.scheduler.status --json
    maxio.replacement.automation_status --json
    maxio.replacement.workflow --json
    maxio.rebalance.workflow --json

  Optional checks:
    --ops-profile p0_ops_1 requires replacement and scheduler rehearsal
      artifacts unless --require-rehearsal-kinds overrides the required set.
    --replacement-rehearsal-ready passes an explicit local rehearsal-ready
      profile to replacement automation/workflow checks. Defaults remain
      production-readiness checks.
    --rehearsal-artifact adds read-only validation of a previously archived
      replacement, scheduler, or ops gate artifact.
    --include-scanner runs maxio.reconcile_index --dry-run --json.
    --include-fresh-drive-heal runs maxio.heal.fresh_drives --dry-run --json,
      unless --allow-mutating is explicit.
    --include-foreground-scan runs maxio.scan --json and requires
      --allow-mutating because it may perform foreground heal work.
  """

  @default_checks [
    %{
      id: "scheduler_status",
      task: "maxio.scheduler.status",
      args: ["maxio.scheduler.status", "--json"],
      mode: "read_only",
      required: true
    },
    %{
      id: "replacement_automation_status",
      task: "maxio.replacement.automation_status",
      args: ["maxio.replacement.automation_status", "--json"],
      mode: "read_only",
      required: true
    },
    %{
      id: "replacement_workflow",
      task: "maxio.replacement.workflow",
      args: ["maxio.replacement.workflow", "--json"],
      mode: "read_only",
      required: true
    },
    %{
      id: "rebalance_workflow",
      task: "maxio.rebalance.workflow",
      args: ["maxio.rebalance.workflow", "--json"],
      mode: "read_only",
      required: true
    }
  ]

  @positive_int_options [
    {:evidence_since_minutes, "--evidence-since-minutes"},
    {:evidence_window_minutes, "--evidence-window-minutes"},
    {:evidence_expected_interval_ms, "--evidence-expected-interval-ms"},
    {:evidence_stale_after_ms, "--evidence-stale-after-ms"},
    {:evidence_min_effective_nodes, "--evidence-min-effective-nodes"}
  ]

  def usage, do: @usage

  def run(argv, opts \\ []) do
    case normalize(argv) do
      {:ok, config} -> run_checks(config, opts)
      {:help, usage} -> {:ok, %{exit_code: 0, stdout: usage}}
      {:error, message} -> {:error, usage_result(message)}
    end
  end

  def print_result(result) do
    if Map.get(result, :stdout), do: IO.write(result.stdout)
    if Map.get(result, :stderr), do: IO.write(:stderr, result.stderr)
  end

  defp normalize(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          artifact: :string,
          mix_cmd: :string,
          ops_profile: :string,
          replacement_rehearsal_ready: :boolean,
          rehearsal_artifact: :keep,
          require_rehearsal_kinds: :string,
          include_scanner: :boolean,
          include_foreground_scan: :boolean,
          include_fresh_drive_heal: :boolean,
          include_scheduler_evidence: :boolean,
          allow_mutating: :boolean,
          evidence_scheduler: :string,
          evidence_from: :string,
          evidence_until: :string,
          evidence_since_minutes: :integer,
          evidence_window_minutes: :integer,
          evidence_expected_interval_ms: :integer,
          evidence_stale_after_ms: :integer,
          evidence_expected_nodes: :string,
          evidence_min_effective_nodes: :integer,
          evidence_require_lock_loser: :boolean,
          evidence_require_rollups: :boolean,
          fail_on_blocked: :boolean,
          fail_on_attention: :boolean,
          strict: :boolean,
          json: :boolean,
          help: :boolean
        ]
      )

    cond do
      Keyword.get(opts, :help, false) ->
        {:help, @usage}

      rest != [] or invalid != [] ->
        {:error, "unexpected arguments: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}"}

      true ->
        normalize_opts(argv, opts)
    end
  end

  defp normalize_opts(argv, opts) do
    with :ok <- validate_positive_ints(opts),
         {:ok, ops_profile} <- validate_ops_profile(Keyword.get(opts, :ops_profile)),
         {:ok, required_rehearsal_kinds} <- required_rehearsal_kinds(opts, ops_profile),
         :ok <- validate_scheduler(Keyword.get(opts, :evidence_scheduler)),
         :ok <- validate_evidence_requested(opts),
         :ok <- validate_evidence_window(opts),
         :ok <- validate_mutating_scope(opts) do
      {:ok,
       %{
         argv: argv,
         opts: opts,
         ops_profile: ops_profile,
         replacement_rehearsal_ready?: Keyword.get(opts, :replacement_rehearsal_ready, false),
         rehearsal_artifact_paths: Keyword.get_values(opts, :rehearsal_artifact),
         required_rehearsal_kinds: required_rehearsal_kinds,
         artifact_path: Keyword.get(opts, :artifact),
         mix_cmd: Keyword.get(opts, :mix_cmd) || System.find_executable("mix") || "mix",
         json?: Keyword.get(opts, :json, false),
         fail_on_blocked?: Keyword.get(opts, :fail_on_blocked, false),
         fail_on_attention?:
           Keyword.get(opts, :fail_on_attention, false) or Keyword.get(opts, :strict, false),
         strict?: Keyword.get(opts, :strict, false),
         allow_mutating?: Keyword.get(opts, :allow_mutating, false)
       }}
    end
  end

  defp run_checks(config, opts) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    artifact_writer = Keyword.get(opts, :artifact_writer, &write_artifact!/2)
    git_sha_fun = Keyword.get(opts, :git_sha_fun, &git_sha/0)
    now_fun = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)

    rehearsal_ready_automation_status_fun =
      Keyword.get(
        opts,
        :rehearsal_ready_automation_status_fun,
        &rehearsal_ready_automation_status/0
      )

    generated_at = now_fun.()
    run_id = run_id(generated_at)
    artifact_path = config.artifact_path || default_artifact_path(run_id)

    checks =
      config
      |> configured_checks()
      |> Enum.map(
        &run_check(&1, config.mix_cmd, command_runner, rehearsal_ready_automation_status_fun)
      )
      |> Kernel.++(
        EvidenceMatrix.checks(
          config.rehearsal_artifact_paths,
          config.required_rehearsal_kinds
        )
      )

    gate_status = overall_status(checks)
    blockers = gate_items(checks, "blockers")
    warnings = gate_items(checks, "warnings")
    ops_evidence_matrix = ops_evidence_matrix(config, checks)

    artifact = %{
      "schema_version" => 1,
      "generated_at" => DateTime.to_iso8601(generated_at),
      "run_id" => run_id,
      "git_sha" => git_sha_fun.(),
      "node" => Atom.to_string(Node.self()),
      "mix_env" => mix_env(),
      "command" => command_string([config.mix_cmd, "maxio.ops.gate" | config.argv]),
      "artifact_path" => artifact_path,
      "config" => config_view(config),
      "ops_evidence_matrix" => ops_evidence_matrix,
      "gate_status" => gate_status,
      "counts" => counts(checks),
      "blockers" => blockers,
      "warnings" => warnings,
      "checks" => checks
    }

    artifact_writer.(artifact_path, artifact)

    exit_code = exit_code(gate_status, config)

    result = %{
      exit_code: exit_code,
      gate_status: gate_status,
      artifact_path: artifact_path,
      artifact: artifact,
      stdout: stdout(artifact, config),
      stderr: stderr(exit_code, gate_status)
    }

    if exit_code == 0, do: {:ok, result}, else: {:error, result}
  end

  defp configured_checks(config) do
    default_checks(config)
    |> maybe_append(Keyword.get(config.opts, :include_scheduler_evidence, false), fn ->
      scheduler_evidence_check(config.opts)
    end)
    |> maybe_append(Keyword.get(config.opts, :include_scanner, false), fn ->
      %{
        id: "scanner_reconcile",
        task: "maxio.reconcile_index",
        args: ["maxio.reconcile_index", "--dry-run", "--json"],
        mode: "dry_run",
        required: true
      }
    end)
    |> maybe_append(Keyword.get(config.opts, :include_fresh_drive_heal, false), fn ->
      %{
        id: "fresh_drive_heal",
        task: "maxio.heal.fresh_drives",
        args: fresh_drive_heal_args(config),
        mode: if(config.allow_mutating?, do: "mutating", else: "dry_run"),
        required: true
      }
    end)
    |> maybe_append(Keyword.get(config.opts, :include_foreground_scan, false), fn ->
      %{
        id: "foreground_scan",
        task: "maxio.scan",
        args: ["maxio.scan", "--json"],
        mode: "mutating",
        required: true
      }
    end)
  end

  defp default_checks(config) do
    Enum.map(@default_checks, &maybe_rehearsal_ready_replacement_check(&1, config))
  end

  defp maybe_rehearsal_ready_replacement_check(%{id: id} = check, %{
         replacement_rehearsal_ready?: true
       })
       when id in ["replacement_automation_status", "replacement_workflow"] do
    check
    |> Map.update!(:args, &(&1 ++ ["--rehearsal-ready"]))
    |> maybe_local_rehearsal_ready_automation_check()
  end

  defp maybe_rehearsal_ready_replacement_check(check, _config), do: check

  defp maybe_local_rehearsal_ready_automation_check(
         %{id: "replacement_automation_status"} = check
       ),
       do: Map.put(check, :local, :replacement_rehearsal_ready_automation_profile)

  defp maybe_local_rehearsal_ready_automation_check(check), do: check

  defp scheduler_evidence_check(opts) do
    %{
      id: "scheduler_evidence",
      task: "maxio.scheduler.evidence",
      args: scheduler_evidence_args(opts),
      mode: "read_only",
      required: true
    }
  end

  defp scheduler_evidence_args(opts) do
    ["maxio.scheduler.evidence", "--json"]
    |> maybe_arg("--scheduler", Keyword.get(opts, :evidence_scheduler))
    |> maybe_arg("--from", Keyword.get(opts, :evidence_from))
    |> maybe_arg("--until", Keyword.get(opts, :evidence_until))
    |> maybe_arg("--since-minutes", Keyword.get(opts, :evidence_since_minutes))
    |> maybe_arg("--window-minutes", Keyword.get(opts, :evidence_window_minutes))
    |> maybe_arg("--expected-interval-ms", Keyword.get(opts, :evidence_expected_interval_ms))
    |> maybe_arg("--stale-after-ms", Keyword.get(opts, :evidence_stale_after_ms))
    |> maybe_arg("--expected-nodes", Keyword.get(opts, :evidence_expected_nodes))
    |> maybe_arg("--min-effective-nodes", Keyword.get(opts, :evidence_min_effective_nodes))
    |> maybe_flag(Keyword.get(opts, :evidence_require_lock_loser, false), "--require-lock-loser")
    |> maybe_flag(Keyword.get(opts, :evidence_require_rollups, false), "--require-rollups")
  end

  defp fresh_drive_heal_args(%{allow_mutating?: true}), do: ["maxio.heal.fresh_drives", "--json"]
  defp fresh_drive_heal_args(_config), do: ["maxio.heal.fresh_drives", "--dry-run", "--json"]

  defp maybe_append(checks, true, fun), do: checks ++ [fun.()]
  defp maybe_append(checks, false, _fun), do: checks

  defp maybe_arg(args, _flag, nil), do: args
  defp maybe_arg(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_flag(args, true, flag), do: args ++ [flag]
  defp maybe_flag(args, false, _flag), do: args

  defp run_check(
         %{local: :replacement_rehearsal_ready_automation_profile} = check,
         _mix_cmd,
         _command_runner,
         rehearsal_ready_automation_status_fun
       ) do
    started = System.monotonic_time(:millisecond)

    try do
      output =
        rehearsal_ready_automation_status_fun.()
        |> json_ready()
        |> Jason.encode!()
        |> Kernel.<>("\n")

      duration_ms = System.monotonic_time(:millisecond) - started
      finish_check(check, output, 0, duration_ms)
    rescue
      error ->
        duration_ms = System.monotonic_time(:millisecond) - started
        error_check(check, Exception.message(error), duration_ms)
    end
  end

  defp run_check(check, mix_cmd, command_runner, _rehearsal_ready_automation_status_fun) do
    started = System.monotonic_time(:millisecond)

    try do
      {output, exit_status} = command_runner.(mix_cmd, check.args, stderr_to_stdout: true)
      duration_ms = System.monotonic_time(:millisecond) - started
      finish_check(check, output, exit_status, duration_ms)
    rescue
      error ->
        duration_ms = System.monotonic_time(:millisecond) - started
        error_check(check, Exception.message(error), duration_ms)
    end
  end

  defp rehearsal_ready_automation_status do
    AutomationProfile.rehearsal_ready_opts()
    |> AutomationProfile.status()
  end

  defp finish_check(check, output, exit_status, duration_ms) do
    parsed = extract_json(output)
    status = check_status(parsed, exit_status)

    check
    |> check_view(output, exit_status, duration_ms, parsed, status)
    |> put_check_gate_items(status, parsed, exit_status)
  end

  defp check_view(check, output, exit_status, duration_ms, parsed, status) do
    %{
      "id" => check.id,
      "task" => check.task,
      "command" => command_string([check.task | tl(check.args)]),
      "mode" => check.mode,
      "required" => check.required,
      "status" => status,
      "exit_status" => exit_status,
      "duration_ms" => duration_ms,
      "parsed_output" => parsed,
      "raw_output" => output
    }
  end

  defp put_check_gate_items(view, "error", parsed, exit_status) do
    reason =
      cond do
        is_nil(parsed) -> "json_unparseable"
        exit_status != 0 -> "exit_nonzero"
        true -> "check_error"
      end

    view
    |> Map.put("blockers", [%{"reason" => reason, "exit_status" => exit_status}])
    |> Map.put("warnings", [])
  end

  defp put_check_gate_items(view, "blocked", parsed, _exit_status) do
    blockers = normalized_items(parsed, "blockers", "check_blocked")

    view
    |> Map.put("blockers", blockers)
    |> Map.put("warnings", [])
  end

  defp put_check_gate_items(view, "attention", parsed, _exit_status) do
    warnings = normalized_items(parsed, "warnings", "check_attention")

    view
    |> Map.put("blockers", [])
    |> Map.put("warnings", warnings)
  end

  defp put_check_gate_items(view, _status, _parsed, _exit_status) do
    view
    |> Map.put("blockers", [])
    |> Map.put("warnings", [])
  end

  defp error_check(check, message, duration_ms) do
    %{
      "id" => check.id,
      "task" => check.task,
      "command" => command_string([check.task | tl(check.args)]),
      "mode" => check.mode,
      "required" => check.required,
      "status" => "error",
      "exit_status" => nil,
      "duration_ms" => duration_ms,
      "parsed_output" => nil,
      "raw_output" => message,
      "blockers" => [%{"reason" => "command_failed", "message" => message}],
      "warnings" => []
    }
  end

  defp check_status(nil, _exit_status), do: "error"

  defp check_status(parsed, exit_status) do
    gate = Map.get(parsed, "gate_status") || Map.get(parsed, "status")

    cond do
      gate in ["error"] -> "error"
      gate in ["blocked", "failed"] -> "blocked"
      gate == "attention" -> "attention"
      exit_status != 0 -> "error"
      gate in ["ok", "audit", "not_started"] -> "ok"
      is_binary(gate) -> "ok"
      true -> "error"
    end
  end

  defp normalized_items(nil, _key, fallback), do: [%{"reason" => fallback}]

  defp normalized_items(parsed, key, fallback) do
    case Map.get(parsed, key, []) do
      [] -> [%{"reason" => fallback}]
      values when is_list(values) -> Enum.map(values, &normalize_item/1)
      value -> [normalize_item(value)]
    end
  end

  defp normalize_item(%{} = item) do
    Map.new(item, fn {key, value} -> {to_string(key), json_ready(value)} end)
  end

  defp normalize_item(value) when is_binary(value), do: %{"reason" => value}
  defp normalize_item(value), do: %{"reason" => inspect(value)}

  defp overall_status(checks) do
    cond do
      Enum.any?(checks, &(&1["status"] == "error")) -> "error"
      Enum.any?(checks, &(&1["status"] == "blocked")) -> "blocked"
      Enum.any?(checks, &(&1["status"] == "attention")) -> "attention"
      true -> "ok"
    end
  end

  defp gate_items(checks, key) do
    checks
    |> Enum.flat_map(fn check ->
      check
      |> Map.get(key, [])
      |> Enum.map(fn item ->
        %{
          "check" => check["id"],
          "task" => check["task"],
          "reason" => item_reason(item),
          "detail" => item
        }
      end)
    end)
  end

  defp item_reason(%{"reason" => reason}), do: to_string(reason)
  defp item_reason(%{reason: reason}), do: to_string(reason)
  defp item_reason(item), do: inspect(item)

  defp counts(checks) do
    %{
      "total" => length(checks),
      "ok" => Enum.count(checks, &(&1["status"] == "ok")),
      "attention" => Enum.count(checks, &(&1["status"] == "attention")),
      "blocked" => Enum.count(checks, &(&1["status"] == "blocked")),
      "error" => Enum.count(checks, &(&1["status"] == "error"))
    }
  end

  defp stdout(artifact, %{json?: true}), do: Jason.encode!(artifact) <> "\n"

  defp stdout(artifact, _config) do
    summary =
      "[maxio ops.gate] gate_status=#{artifact["gate_status"]} " <>
        "checks=#{artifact["counts"]["total"]} ok=#{artifact["counts"]["ok"]} " <>
        "attention=#{artifact["counts"]["attention"]} " <>
        "blocked=#{artifact["counts"]["blocked"]} error=#{artifact["counts"]["error"]} " <>
        "artifact=#{artifact["artifact_path"]}\n"

    check_lines =
      artifact["checks"]
      |> Enum.map(fn check ->
        "[maxio ops.gate.check] id=#{check["id"]} status=#{check["status"]} " <>
          "exit_status=#{format_value(check["exit_status"])} " <>
          "duration_ms=#{check["duration_ms"]} mode=#{check["mode"]} " <>
          "command=#{inspect(check["command"])}\n"
      end)
      |> Enum.join()

    blocker_lines = Enum.map_join(artifact["blockers"], "", &gate_line("blocker", &1))
    warning_lines = Enum.map_join(artifact["warnings"], "", &gate_line("warning", &1))

    summary <> check_lines <> blocker_lines <> warning_lines
  end

  defp gate_line(kind, item) do
    "[maxio ops.gate.#{kind}] check=#{item["check"]} task=#{item["task"]} " <>
      "reason=#{item["reason"]}\n"
  end

  defp stderr(0, _gate_status), do: nil
  defp stderr(_exit_code, gate_status), do: "[maxio ops.gate] gate failed: #{gate_status}\n"

  defp exit_code("error", _config), do: 1

  defp exit_code("blocked", config) do
    if config.fail_on_blocked? or config.fail_on_attention?, do: 1, else: 0
  end

  defp exit_code("attention", config) do
    if config.fail_on_attention?, do: 1, else: 0
  end

  defp exit_code(_gate_status, _config), do: 0

  defp config_view(config) do
    %{
      "default_checks" => Enum.map(@default_checks, & &1.id),
      "include_scanner" => Keyword.get(config.opts, :include_scanner, false),
      "include_foreground_scan" => Keyword.get(config.opts, :include_foreground_scan, false),
      "include_fresh_drive_heal" => Keyword.get(config.opts, :include_fresh_drive_heal, false),
      "include_scheduler_evidence" =>
        Keyword.get(config.opts, :include_scheduler_evidence, false),
      "ops_profile" => config.ops_profile,
      "replacement_rehearsal_ready" => config.replacement_rehearsal_ready?,
      "rehearsal_artifacts" => config.rehearsal_artifact_paths,
      "required_rehearsal_kinds" => config.required_rehearsal_kinds,
      "allow_mutating" => config.allow_mutating?,
      "fail_on_blocked" => config.fail_on_blocked?,
      "fail_on_attention" => config.fail_on_attention?,
      "strict" => config.strict?
    }
  end

  defp ops_evidence_matrix(config, checks) do
    config.rehearsal_artifact_paths
    |> EvidenceMatrix.summary(config.required_rehearsal_kinds, checks)
    |> Map.merge(%{
      "profile" => config.ops_profile || "default",
      "read_only" => true
    })
  end

  defp validate_positive_ints(opts) do
    Enum.reduce_while(@positive_int_options, :ok, fn {key, flag}, :ok ->
      case Keyword.get(opts, key) do
        nil -> {:cont, :ok}
        value when is_integer(value) and value > 0 -> {:cont, :ok}
        value -> {:halt, {:error, "#{flag} must be a positive integer, got #{inspect(value)}"}}
      end
    end)
  end

  defp validate_ops_profile(nil), do: {:ok, nil}
  defp validate_ops_profile("p0_ops_1"), do: {:ok, "p0_ops_1"}

  defp validate_ops_profile(value),
    do: {:error, "--ops-profile must be p0_ops_1, got #{inspect(value)}"}

  defp required_rehearsal_kinds(opts, ops_profile) do
    case Keyword.get(opts, :require_rehearsal_kinds) do
      nil ->
        {:ok, default_required_rehearsal_kinds(ops_profile)}

      value ->
        parse_required_rehearsal_kinds(value)
    end
  end

  defp default_required_rehearsal_kinds("p0_ops_1") do
    ["replacement_live_rehearsal", "scheduler_live_rehearsal"]
  end

  defp default_required_rehearsal_kinds(_profile), do: []

  defp parse_required_rehearsal_kinds(value) when is_binary(value) do
    kinds =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    unsupported = Enum.reject(kinds, &(&1 in EvidenceMatrix.supported_kinds()))

    cond do
      kinds == [] ->
        {:error, "--require-rehearsal-kinds must contain at least one kind"}

      unsupported != [] ->
        {:error,
         "--require-rehearsal-kinds has unsupported kind(s): #{Enum.join(unsupported, ",")}"}

      true ->
        {:ok, kinds}
    end
  end

  defp validate_scheduler(nil), do: :ok
  defp validate_scheduler("fresh_drive_heal"), do: :ok
  defp validate_scheduler("rebalance"), do: :ok

  defp validate_scheduler(value),
    do:
      {:error,
       "--evidence-scheduler must be fresh_drive_heal or rebalance, got #{inspect(value)}"}

  defp validate_evidence_requested(opts) do
    evidence_options =
      [
        :evidence_scheduler,
        :evidence_from,
        :evidence_until,
        :evidence_since_minutes,
        :evidence_window_minutes,
        :evidence_expected_interval_ms,
        :evidence_stale_after_ms,
        :evidence_expected_nodes,
        :evidence_min_effective_nodes,
        :evidence_require_lock_loser,
        :evidence_require_rollups
      ]

    if Enum.any?(evidence_options, &Keyword.has_key?(opts, &1)) and
         not Keyword.get(opts, :include_scheduler_evidence, false) do
      {:error, "scheduler evidence options require --include-scheduler-evidence"}
    else
      :ok
    end
  end

  defp validate_evidence_window(opts) do
    if Keyword.has_key?(opts, :evidence_from) and Keyword.has_key?(opts, :evidence_since_minutes) do
      {:error, "--evidence-from and --evidence-since-minutes cannot be used together"}
    else
      :ok
    end
  end

  defp validate_mutating_scope(opts) do
    if Keyword.get(opts, :include_foreground_scan, false) and
         not Keyword.get(opts, :allow_mutating, false) do
      {:error, "--include-foreground-scan requires --allow-mutating"}
    else
      :ok
    end
  end

  defp extract_json(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&String.starts_with?(&1, "{"))
    |> case do
      nil -> nil
      json -> Jason.decode!(json)
    end
  rescue
    _error -> nil
  end

  defp write_artifact!(path, artifact) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode!(artifact) <> "\n")
  end

  defp usage_result(message) do
    %{
      exit_code: 64,
      stderr: "[maxio ops.gate] #{message}\n\n" <> @usage
    }
  end

  defp default_artifact_path(run_id), do: Path.join("artifacts", "#{run_id}.json")

  defp run_id(%DateTime{} = generated_at) do
    stamp =
      generated_at
      |> DateTime.to_iso8601()
      |> String.replace(~r/[^0-9A-Za-z_.-]/, "_")

    "m8_ops_gate_#{stamp}_#{System.unique_integer([:positive])}"
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> "unknown"
    end
  rescue
    _error -> "unknown"
  end

  defp mix_env do
    if Code.ensure_loaded?(Mix) do
      Mix.env() |> to_string()
    else
      System.get_env("MIX_ENV") || "unknown"
    end
  end

  defp command_string(parts), do: Enum.map_join(parts, " ", &quote_arg/1)

  defp quote_arg(part) do
    part = to_string(part)

    if String.match?(part, ~r/^[A-Za-z0-9_@.,:\/\\=-]+$/) do
      part
    else
      inspect(part)
    end
  end

  defp json_ready(value) when is_boolean(value) or is_nil(value), do: value
  defp json_ready(value) when is_number(value) or is_binary(value), do: value
  defp json_ready(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(values) when is_list(values), do: Enum.map(values, &json_ready/1)

  defp json_ready(%{} = value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)
  end

  defp json_ready(value), do: inspect(value)

  defp format_value(nil), do: "nil"
  defp format_value(value), do: to_string(value)
end
