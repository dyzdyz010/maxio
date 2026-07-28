defmodule Maxio.Cluster.ReplacementLiveRehearsal do
  @moduledoc """
  Bounded replacement/rebalance live rehearsal harness.

  This backs `scripts/m8_replacement_live_rehearsal.exs`. It shells out to the
  operator-facing replacement workflow CLI, archives the machine-readable report,
  and applies a stricter rehearsal gate than the CLI default: no blockers and no
  remaining next action.
  """

  @usage """
  Usage:
    mix run --no-start scripts/m8_replacement_live_rehearsal.exs -- \\
      [--probe] [--heal] [--dry-run] [--rebalance-if-needed] \\
      [--advance-steps N] [--verify-closure] \\
      [--bucket <name>] [--max-objects N] [--page-size N] \\
      [--audit-page-size N] [--scan-current-only] \\
      [--allow-dry-run-success] [--rehearsal-ready] \\
      [--require-scheduler-evidence \\
       [--scheduler-evidence-scheduler fresh_drive_heal|rebalance] \\
       [--scheduler-evidence-from <iso8601>] [--scheduler-evidence-until <iso8601>] \\
       [--scheduler-evidence-since-minutes N] [--scheduler-evidence-window-minutes N] \\
       [--scheduler-evidence-expected-nodes node_a,node_b] \\
       [--scheduler-evidence-expected-interval-ms N] \\
       [--scheduler-evidence-stale-after-ms N] \\
       [--scheduler-evidence-min-effective-nodes N] \\
       [--scheduler-evidence-require-lock-loser] [--scheduler-evidence-require-rollups]] \\
      [--artifact artifacts/m8_replacement_live_rehearsal.json]

  The harness does not implement repair logic itself and never invokes
  decommission, topology mutation, deployment finalization, physical removal, or
  purge. It runs `mix maxio.replacement.workflow --json --fail-on-blocked`,
  optionally runs `mix maxio.scheduler.evidence --json --fail-on-attention`,
  writes an artifact, and exits non-zero unless every requested gate is clear.
  Dry-run workflows are archived but do not pass the live gate unless
  `--allow-dry-run-success` is explicit.
  """

  @workflow_flags [
    :probe,
    :heal,
    :dry_run,
    :rebalance_if_needed,
    :verify_closure,
    :scan_current_only,
    :rehearsal_ready
  ]

  @workflow_values [
    advance_steps: "--advance-steps",
    bucket: "--bucket",
    max_objects: "--max-objects",
    page_size: "--page-size",
    audit_page_size: "--audit-page-size"
  ]

  @scheduler_evidence_values [
    scheduler_evidence_scheduler: "--scheduler",
    scheduler_evidence_from: "--from",
    scheduler_evidence_until: "--until",
    scheduler_evidence_since_minutes: "--since-minutes",
    scheduler_evidence_window_minutes: "--window-minutes",
    scheduler_evidence_expected_nodes: "--expected-nodes",
    scheduler_evidence_expected_interval_ms: "--expected-interval-ms",
    scheduler_evidence_stale_after_ms: "--stale-after-ms",
    scheduler_evidence_min_effective_nodes: "--min-effective-nodes"
  ]

  @scheduler_evidence_flags [
    scheduler_evidence_require_lock_loser: "--require-lock-loser",
    scheduler_evidence_require_rollups: "--require-rollups"
  ]

  def usage, do: @usage

  def run(argv, opts \\ []) do
    case normalize(argv) do
      {:ok, config} -> run_workflow(config, opts)
      {:help, usage} -> {:ok, %{exit_code: 0, stdout: usage}}
      {:error, message} -> {:error, usage_result(message)}
    end
  end

  def print_result(result) do
    if Map.get(result, :stdout) do
      IO.write(result.stdout)
    end

    if Map.get(result, :stderr) do
      IO.write(:stderr, result.stderr)
    end
  end

  defp normalize(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          probe: :boolean,
          heal: :boolean,
          dry_run: :boolean,
          rebalance_if_needed: :boolean,
          advance_steps: :integer,
          verify_closure: :boolean,
          bucket: :string,
          max_objects: :integer,
          page_size: :integer,
          audit_page_size: :integer,
          scan_current_only: :boolean,
          allow_dry_run_success: :boolean,
          rehearsal_ready: :boolean,
          require_scheduler_evidence: :boolean,
          scheduler_evidence_scheduler: :string,
          scheduler_evidence_from: :string,
          scheduler_evidence_until: :string,
          scheduler_evidence_since_minutes: :integer,
          scheduler_evidence_window_minutes: :integer,
          scheduler_evidence_expected_nodes: :string,
          scheduler_evidence_expected_interval_ms: :integer,
          scheduler_evidence_stale_after_ms: :integer,
          scheduler_evidence_min_effective_nodes: :integer,
          scheduler_evidence_require_lock_loser: :boolean,
          scheduler_evidence_require_rollups: :boolean,
          artifact: :string,
          mix_cmd: :string,
          help: :boolean
        ]
      )

    cond do
      Keyword.get(opts, :help, false) ->
        {:help, @usage}

      rest != [] or invalid != [] ->
        {:error, "unexpected arguments: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}"}

      true ->
        normalize_opts(opts)
    end
  end

  defp normalize_opts(opts) do
    with :ok <- validate_positive(opts, :advance_steps, "--advance-steps"),
         :ok <- validate_positive(opts, :max_objects, "--max-objects"),
         :ok <- validate_positive(opts, :page_size, "--page-size"),
         :ok <- validate_positive(opts, :audit_page_size, "--audit-page-size"),
         :ok <- validate_scheduler_evidence_opts(opts) do
      {:ok,
       %{
         workflow_opts: opts,
         scheduler_evidence_opts: scheduler_evidence_opts(opts),
         require_scheduler_evidence?: Keyword.get(opts, :require_scheduler_evidence, false),
         dry_run?: Keyword.get(opts, :dry_run, false),
         allow_dry_run_success?: Keyword.get(opts, :allow_dry_run_success, false),
         rehearsal_ready?: Keyword.get(opts, :rehearsal_ready, false),
         artifact_path: artifact_path(opts),
         mix_cmd: Keyword.get(opts, :mix_cmd) || System.find_executable("mix") || "mix"
       }}
    end
  end

  defp run_workflow(config, opts) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    git_sha_fun = Keyword.get(opts, :git_sha_fun, &git_sha/0)
    now_fun = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)
    artifact_writer = Keyword.get(opts, :artifact_writer, &write_artifact!/2)

    args = workflow_args(config.workflow_opts)
    command = command_string([config.mix_cmd | args])
    {output, exit_status} = run_command(command_runner, config.mix_cmd, args)
    workflow = extract_json(output)
    workflow_gate = workflow_gate(workflow, exit_status, config)

    scheduler_evidence_result =
      maybe_run_scheduler_evidence(config, command_runner)

    scheduler_evidence_gate = scheduler_evidence_gate(scheduler_evidence_result)
    bundle_gate = bundle_gate(workflow_gate, scheduler_evidence_gate)

    commands =
      %{"workflow" => command}
      |> maybe_put_command("scheduler_evidence", scheduler_evidence_result.command)

    artifact = %{
      "version" => 1,
      "evidence_kind" => "replacement_live_rehearsal",
      "scenario" => "replacement_workflow_rehearsal",
      "generated_at" => now_fun.() |> DateTime.to_iso8601(),
      "git_sha" => git_sha_fun.(),
      "dry_run?" => config.dry_run?,
      "allow_dry_run_success?" => config.allow_dry_run_success?,
      "rehearsal_ready?" => config.rehearsal_ready?,
      "command" => command,
      "commands" => commands,
      "workflow_exit_status" => exit_status,
      "scheduler_evidence_required?" => config.require_scheduler_evidence?,
      "scheduler_evidence_exit_status" => scheduler_evidence_result.exit_status,
      "gate" => workflow_gate,
      "bundle_gate" => bundle_gate,
      "scheduler_evidence_gate" => scheduler_evidence_gate,
      "replacement_workflow" => workflow,
      "scheduler_evidence" => scheduler_evidence_result.evidence,
      "scheduler_evidence_raw_output" => scheduler_evidence_result.output,
      "raw_output" => output
    }

    artifact_writer.(config.artifact_path, artifact)

    status = if is_map(workflow), do: Map.get(workflow, "status"), else: "unparseable"
    next_action = if is_map(workflow), do: Map.get(workflow, "next_action"), else: nil

    stdout =
      "[maxio replacement.live_rehearsal] artifact=#{config.artifact_path} " <>
        "workflow_status=#{status} workflow_exit=#{exit_status} " <>
        "workflow_gate_status=#{workflow_gate["status"]} " <>
        "bundle_gate_status=#{bundle_gate["status"]} next_action=#{inspect(next_action)} " <>
        "rehearsal_ready=#{config.rehearsal_ready?} " <>
        "scheduler_evidence_status=#{scheduler_evidence_gate["status"]}\n"

    result = %{
      exit_code: if(bundle_gate["status"] == "ok", do: 0, else: 1),
      stdout: stdout,
      artifact_path: config.artifact_path,
      artifact: artifact
    }

    if bundle_gate["status"] == "ok" do
      {:ok, result}
    else
      {:error, Map.put(result, :stderr, "[maxio replacement.live_rehearsal] gate failed\n")}
    end
  end

  defp workflow_args(opts) do
    ["maxio.replacement.workflow"]
    |> append_flags(opts)
    |> append_values(opts)
    |> Kernel.++(["--fail-on-blocked", "--json"])
  end

  defp append_flags(args, opts) do
    Enum.reduce(@workflow_flags, args, fn key, acc ->
      if Keyword.get(opts, key, false), do: acc ++ [flag_name(key)], else: acc
    end)
  end

  defp append_values(args, opts) do
    Enum.reduce(@workflow_values, args, fn {key, flag}, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        value -> acc ++ [flag, to_string(value)]
      end
    end)
  end

  defp maybe_run_scheduler_evidence(%{require_scheduler_evidence?: false}, _command_runner) do
    %{
      command: nil,
      output: nil,
      exit_status: nil,
      evidence: nil
    }
  end

  defp maybe_run_scheduler_evidence(config, command_runner) do
    args = scheduler_evidence_args(config.scheduler_evidence_opts)
    command = command_string([config.mix_cmd | args])
    {output, exit_status} = run_command(command_runner, config.mix_cmd, args)

    %{
      command: command,
      output: output,
      exit_status: exit_status,
      evidence: extract_json(output)
    }
  end

  defp scheduler_evidence_args(opts) do
    ["maxio.scheduler.evidence"]
    |> append_scheduler_evidence_values(opts)
    |> append_scheduler_evidence_flags(opts)
    |> Kernel.++(["--fail-on-attention", "--json"])
  end

  defp append_scheduler_evidence_values(args, opts) do
    Enum.reduce(@scheduler_evidence_values, args, fn {key, flag}, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        value -> acc ++ [flag, to_string(value)]
      end
    end)
  end

  defp append_scheduler_evidence_flags(args, opts) do
    Enum.reduce(@scheduler_evidence_flags, args, fn {key, flag}, acc ->
      if Keyword.get(opts, key, false), do: acc ++ [flag], else: acc
    end)
  end

  defp workflow_gate(%{} = workflow, exit_status, config) do
    blockers = Map.get(workflow, "blockers", [])
    next_action = Map.get(workflow, "next_action")
    status = Map.get(workflow, "status")

    cond do
      exit_status != 0 ->
        blocked_gate("workflow_exit_nonzero", exit_status, blockers, next_action)

      config.dry_run? and not config.allow_dry_run_success? ->
        blocked_gate("dry_run_not_live", exit_status, blockers, next_action)

      status not in ["ok", "audit"] ->
        blocked_gate("workflow_status_#{status}", exit_status, blockers, next_action)

      blockers != [] ->
        blocked_gate("workflow_blockers", exit_status, blockers, next_action)

      next_action not in [nil, "none"] ->
        blocked_gate("workflow_next_action_required", exit_status, blockers, next_action)

      true ->
        %{
          "status" => "ok",
          "reason" => "replacement_workflow_clear",
          "blockers" => [],
          "next_action" => next_action
        }
    end
  end

  defp workflow_gate(_workflow, exit_status, _config) do
    blocked_gate("workflow_json_unparseable", exit_status, [], nil)
  end

  defp blocked_gate(reason, exit_status, blockers, next_action) do
    %{
      "status" => "blocked",
      "reason" => reason,
      "workflow_exit_status" => exit_status,
      "blockers" => blockers,
      "next_action" => next_action
    }
  end

  defp scheduler_evidence_gate(%{command: nil}) do
    %{"status" => "not_requested"}
  end

  defp scheduler_evidence_gate(%{evidence: nil, exit_status: exit_status}) do
    scheduler_evidence_blocked_gate("scheduler_evidence_json_unparseable", exit_status, nil, [])
  end

  defp scheduler_evidence_gate(%{evidence: evidence, exit_status: exit_status})
       when is_map(evidence) do
    status = Map.get(evidence, "status")
    warnings = Map.get(evidence, "warnings", [])

    cond do
      status == "blocked" ->
        scheduler_evidence_blocked_gate(
          "scheduler_evidence_status_blocked",
          exit_status,
          status,
          warnings
        )

      status == "attention" ->
        scheduler_evidence_blocked_gate(
          "scheduler_evidence_status_attention",
          exit_status,
          status,
          warnings
        )

      status != "ok" ->
        scheduler_evidence_blocked_gate(
          "scheduler_evidence_status_#{status}",
          exit_status,
          status,
          warnings
        )

      warnings != [] ->
        scheduler_evidence_blocked_gate(
          "scheduler_evidence_warnings",
          exit_status,
          status,
          warnings
        )

      exit_status != 0 ->
        scheduler_evidence_blocked_gate(
          "scheduler_evidence_exit_nonzero",
          exit_status,
          status,
          warnings
        )

      true ->
        %{
          "status" => "ok",
          "reason" => "scheduler_evidence_clear",
          "evidence_status" => status,
          "evidence_exit_status" => exit_status
        }
    end
  end

  defp scheduler_evidence_blocked_gate(reason, exit_status, evidence_status, warnings) do
    %{
      "status" => "blocked",
      "reason" => reason,
      "evidence_exit_status" => exit_status,
      "evidence_status" => evidence_status,
      "warnings" => warnings
    }
  end

  defp bundle_gate(%{"status" => workflow_status} = workflow_gate, %{
         "status" => "not_requested"
       })
       when workflow_status != "ok",
       do: workflow_gate

  defp bundle_gate(%{"status" => "ok"} = workflow_gate, %{"status" => "not_requested"}) do
    workflow_gate
  end

  defp bundle_gate(%{"status" => "ok"} = workflow_gate, %{"status" => "ok"} = evidence_gate) do
    %{
      "status" => "ok",
      "reason" => "replacement_workflow_and_scheduler_evidence_clear",
      "blockers" => [],
      "next_action" => Map.get(workflow_gate, "next_action"),
      "workflow_gate" => workflow_gate,
      "scheduler_evidence_gate" => evidence_gate
    }
  end

  defp bundle_gate(%{"status" => "ok"} = workflow_gate, evidence_gate) do
    %{
      "status" => "blocked",
      "reason" => Map.get(evidence_gate, "reason", "scheduler_evidence_failed"),
      "blockers" => [],
      "next_action" => Map.get(workflow_gate, "next_action"),
      "workflow_gate" => workflow_gate,
      "scheduler_evidence_gate" => evidence_gate
    }
  end

  defp bundle_gate(workflow_gate, evidence_gate) do
    Map.put(workflow_gate, "scheduler_evidence_gate", evidence_gate)
  end

  defp extract_json(output) do
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

  defp run_command(command_runner, mix_cmd, args) do
    command_runner.(mix_cmd, args, stderr_to_stdout: true)
  rescue
    error -> {Exception.message(error), nil}
  end

  defp write_artifact!(path, artifact) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode!(artifact) <> "\n")
  end

  defp maybe_put_command(commands, _key, nil), do: commands
  defp maybe_put_command(commands, key, command), do: Map.put(commands, key, command)

  defp artifact_path(opts) do
    Keyword.get_lazy(opts, :artifact, fn ->
      stamp =
        DateTime.utc_now()
        |> DateTime.to_iso8601()
        |> String.replace(~r/[^0-9A-Za-z_.-]/, "_")

      Path.join("artifacts", "m8_replacement_live_rehearsal_#{stamp}.json")
    end)
  end

  defp validate_positive(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      _value -> {:error, "#{flag} must be a positive integer"}
    end
  end

  defp validate_scheduler_evidence_opts(opts) do
    with :ok <- validate_scheduler_evidence_required(opts),
         :ok <-
           validate_positive(
             opts,
             :scheduler_evidence_since_minutes,
             "--scheduler-evidence-since-minutes"
           ),
         :ok <-
           validate_positive(
             opts,
             :scheduler_evidence_window_minutes,
             "--scheduler-evidence-window-minutes"
           ),
         :ok <-
           validate_positive(
             opts,
             :scheduler_evidence_expected_interval_ms,
             "--scheduler-evidence-expected-interval-ms"
           ),
         :ok <-
           validate_positive(
             opts,
             :scheduler_evidence_stale_after_ms,
             "--scheduler-evidence-stale-after-ms"
           ),
         :ok <-
           validate_positive(
             opts,
             :scheduler_evidence_min_effective_nodes,
             "--scheduler-evidence-min-effective-nodes"
           ),
         :ok <- validate_scheduler_evidence_scheduler(opts),
         :ok <- validate_scheduler_evidence_window_mode(opts) do
      :ok
    end
  end

  defp validate_scheduler_evidence_required(opts) do
    evidence_option? =
      Enum.any?(
        [:require_scheduler_evidence | Keyword.keys(@scheduler_evidence_values)] ++
          Keyword.keys(@scheduler_evidence_flags),
        &Keyword.has_key?(opts, &1)
      )

    if evidence_option? and not Keyword.get(opts, :require_scheduler_evidence, false) do
      {:error, "scheduler evidence options require --require-scheduler-evidence"}
    else
      :ok
    end
  end

  defp validate_scheduler_evidence_scheduler(opts) do
    case Keyword.get(opts, :scheduler_evidence_scheduler) do
      nil ->
        :ok

      "fresh_drive_heal" ->
        :ok

      "rebalance" ->
        :ok

      other ->
        {:error,
         "--scheduler-evidence-scheduler must be fresh_drive_heal or rebalance, got #{inspect(other)}"}
    end
  end

  defp validate_scheduler_evidence_window_mode(opts) do
    cond do
      Keyword.has_key?(opts, :scheduler_evidence_from) and
          Keyword.has_key?(opts, :scheduler_evidence_since_minutes) ->
        {:error,
         "--scheduler-evidence-from and --scheduler-evidence-since-minutes cannot be used together"}

      true ->
        :ok
    end
  end

  defp scheduler_evidence_opts(opts) do
    opts
    |> Keyword.take(
      [:require_scheduler_evidence] ++
        Keyword.keys(@scheduler_evidence_values) ++ Keyword.keys(@scheduler_evidence_flags)
    )
  end

  defp usage_result(message) do
    %{
      exit_code: 64,
      stderr: "[maxio replacement.live_rehearsal] #{message}\n\n" <> @usage
    }
  end

  defp flag_name(key), do: "--" <> String.replace(to_string(key), "_", "-")

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> "unknown"
    end
  rescue
    _error -> "unknown"
  end

  defp command_string(parts), do: Enum.map_join(parts, " ", &quote_arg/1)

  defp quote_arg(part) do
    if String.match?(part, ~r/^[A-Za-z0-9_@.,:\/\\=-]+$/) do
      part
    else
      inspect(part)
    end
  end
end
