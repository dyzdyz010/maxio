defmodule Maxio.Ops.LiveRehearsalBundle do
  @moduledoc """
  P0 ops rehearsal bundle runner.

  The bundle runs the existing replacement rehearsal, scheduler rehearsal, and
  `p0_ops_1` gate in sequence. It keeps going after child gates fail so the
  final gate can report real artifact evidence instead of "artifact missing".
  """

  alias Maxio.Cluster.ReplacementLiveRehearsal
  alias Maxio.Cluster.SchedulerEnabledRehearsal
  alias Maxio.Cluster.SchedulerLiveRehearsal
  alias Maxio.Ops.Gate

  @usage """
  Usage:
    mix run --no-start scripts/m8_p0_ops_live_rehearsal_bundle.exs -- \\
      [--artifact-dir artifacts] [--artifact PATH] [--run-id ID] [--mix-cmd mix] \\
      [--replacement-live] [--replacement-arg ARG ...] \\
      [--scheduler fresh_drive_heal|rebalance|all] [--scheduler-enabled] \\
      [--scheduler-from ISO8601Z --scheduler-until ISO8601Z | --scheduler-since-minutes N] \\
      [--scheduler-window-minutes N] [--expected-nodes node_a,node_b] \\
      [--expected-interval-ms N] [--stale-after-ms N] [--min-effective-nodes N] \\
      [--require-lock-loser] [--require-rollups] \\
      [--fail-on-gate] [--json]

  Default mode is safe for local rehearsal evidence: the replacement rehearsal
  receives `--dry-run --allow-dry-run-success --rehearsal-ready`, scheduler
  evidence is read-only, and the final ops gate is report-only. Use
  `--replacement-live` to remove the default dry-run replacement flags,
  `--scheduler-enabled` to start bounded local scheduler GenServers with
  controlled no-op runners, and `--fail-on-gate` when automation should return
  non-zero for a blocked P0 gate. Artifact paths
  are constrained to `--artifact-dir`, which itself must resolve under the
  current working directory; `--artifact` is interpreted relative to
  `--artifact-dir` unless it is already absolute.
  """

  @default_scheduler "rebalance"
  @default_scheduler_enabled_scheduler "all"
  @default_scheduler_since_minutes 120
  @default_scheduler_window_minutes 5
  @default_expected_interval_ms 60_000
  @default_stale_after_ms 120_000
  @default_min_effective_nodes 1

  def usage, do: @usage

  def run(argv, opts \\ []) do
    case normalize(argv, opts) do
      {:ok, config} -> run_bundle(config, opts)
      {:help, usage} -> {:ok, %{exit_code: 0, stdout: usage}}
      {:error, message} -> {:error, usage_result(message)}
    end
  end

  def print_result(result) do
    if Map.get(result, :stdout), do: IO.write(result.stdout)
    if Map.get(result, :stderr), do: IO.write(:stderr, result.stderr)
  end

  defp normalize(argv, opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          artifact_dir: :string,
          artifact: :string,
          run_id: :string,
          mix_cmd: :string,
          replacement_live: :boolean,
          replacement_arg: :keep,
          scheduler: :string,
          scheduler_enabled: :boolean,
          scheduler_from: :string,
          scheduler_until: :string,
          scheduler_since_minutes: :integer,
          scheduler_window_minutes: :integer,
          expected_nodes: :string,
          expected_interval_ms: :integer,
          stale_after_ms: :integer,
          min_effective_nodes: :integer,
          require_lock_loser: :boolean,
          require_rollups: :boolean,
          fail_on_gate: :boolean,
          json: :boolean,
          help: :boolean
        ]
      )

    cond do
      Keyword.get(parsed, :help, false) ->
        {:help, @usage}

      rest != [] or invalid != [] ->
        {:error, "unexpected arguments: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}"}

      true ->
        normalize_opts(argv, parsed, opts)
    end
  end

  defp normalize_opts(argv, parsed, opts) do
    now = Keyword.get(opts, :now_fun, &DateTime.utc_now/0).()
    scheduler_enabled? = Keyword.get(parsed, :scheduler_enabled, false)
    scheduler = Keyword.get(parsed, :scheduler, default_scheduler(scheduler_enabled?))

    with :ok <- validate_scheduler(scheduler, scheduler_enabled?),
         :ok <- validate_positive(parsed, :scheduler_since_minutes, "--scheduler-since-minutes"),
         :ok <- validate_positive(parsed, :scheduler_window_minutes, "--scheduler-window-minutes"),
         :ok <- validate_positive(parsed, :expected_interval_ms, "--expected-interval-ms"),
         :ok <- validate_positive(parsed, :stale_after_ms, "--stale-after-ms"),
         :ok <- validate_positive(parsed, :min_effective_nodes, "--min-effective-nodes"),
         :ok <- validate_scheduler_window_mode(parsed),
         :ok <- validate_scheduler_enabled_window_mode(parsed, scheduler_enabled?),
         :ok <- validate_replacement_args(parsed),
         {:ok, scheduler_window} <- scheduler_window(parsed, now),
         {:ok, expected_nodes} <- expected_nodes(parsed),
         :ok <- validate_scheduler_enabled_nodes(expected_nodes, scheduler_enabled?) do
      run_id = Keyword.get(parsed, :run_id) || run_id(now)
      mix_cmd = Keyword.get(parsed, :mix_cmd) || System.find_executable("mix") || "mix"
      base_dir = Keyword.get(opts, :base_dir, File.cwd!())

      with :ok <- validate_run_id(run_id),
           {:ok, artifact_dir} <-
             normalize_artifact_dir(Keyword.get(parsed, :artifact_dir, "artifacts"), base_dir),
           {:ok, artifact_paths} <-
             artifact_paths(artifact_dir, run_id, Keyword.get(parsed, :artifact)) do
        {:ok,
         %{
           argv: argv,
           opts: parsed,
           run_id: run_id,
           generated_at: now,
           artifact_dir: artifact_dir,
           artifact_paths: artifact_paths,
           replacement_live?: Keyword.get(parsed, :replacement_live, false),
           replacement_args: replacement_args(parsed, artifact_paths.replacement, mix_cmd),
           scheduler_enabled?: scheduler_enabled?,
           scheduler: scheduler,
           scheduler_window: scheduler_window,
           scheduler_window_minutes:
             Keyword.get(parsed, :scheduler_window_minutes, @default_scheduler_window_minutes),
           expected_nodes: expected_nodes,
           expected_interval_ms:
             Keyword.get(parsed, :expected_interval_ms, @default_expected_interval_ms),
           stale_after_ms: Keyword.get(parsed, :stale_after_ms, @default_stale_after_ms),
           min_effective_nodes:
             Keyword.get(parsed, :min_effective_nodes, @default_min_effective_nodes),
           require_lock_loser?: Keyword.get(parsed, :require_lock_loser, false),
           require_rollups?: Keyword.get(parsed, :require_rollups, false),
           fail_on_gate?: Keyword.get(parsed, :fail_on_gate, false),
           json?: Keyword.get(parsed, :json, false),
           mix_cmd: mix_cmd
         }}
      end
    end
  end

  defp run_bundle(config, opts) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    artifact_writer = Keyword.get(opts, :artifact_writer, &write_artifact!/2)
    git_sha_fun = Keyword.get(opts, :git_sha_fun, &git_sha/0)
    now_fun = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)

    scheduler_enabled_runner =
      Keyword.get(opts, :scheduler_enabled_runner, &SchedulerEnabledRehearsal.run/2)

    child_opts = [
      command_runner: command_runner,
      git_sha_fun: git_sha_fun,
      now_fun: now_fun
    ]

    replacement_result =
      capture_result(fn ->
        ReplacementLiveRehearsal.run(config.replacement_args, child_opts)
      end)

    scheduler_result =
      capture_result(fn ->
        if config.scheduler_enabled? do
          scheduler_enabled_runner.(scheduler_args(config), child_opts)
        else
          SchedulerLiveRehearsal.run(scheduler_args(config), child_opts)
        end
      end)

    gate_result =
      capture_result(fn ->
        Gate.run(gate_args(config),
          command_runner: command_runner,
          git_sha_fun: git_sha_fun,
          now_fun: now_fun
        )
      end)

    gate_status = result_field(gate_result, :gate_status, "error")
    gate_exit = result_field(gate_result, :exit_code, 1)

    artifact =
      bundle_artifact(config, git_sha_fun.(), replacement_result, scheduler_result, gate_result)

    artifact_writer.(config.artifact_paths.bundle, artifact)

    exit_code =
      cond do
        gate_status == "error" -> 1
        config.fail_on_gate? and gate_status != "ok" -> 1
        true -> 0
      end

    result = %{
      exit_code: exit_code,
      gate_status: gate_status,
      artifact_path: config.artifact_paths.bundle,
      artifact: artifact,
      stdout: stdout(artifact, config),
      stderr: stderr(exit_code, gate_status, gate_exit)
    }

    if exit_code == 0, do: {:ok, result}, else: {:error, result}
  end

  defp capture_result(fun) do
    case fun.() do
      {:ok, result} -> %{status: :ok, result: result}
      {:error, result} -> %{status: :error, result: result}
    end
  rescue
    error ->
      %{
        status: :exception,
        result: %{exit_code: 1, stderr: Exception.message(error), stdout: nil}
      }
  end

  defp replacement_args(parsed, artifact_path, mix_cmd) do
    default_args =
      if Keyword.get(parsed, :replacement_live, false) do
        []
      else
        ["--dry-run", "--allow-dry-run-success", "--rehearsal-ready"]
      end

    default_args ++
      Keyword.get_values(parsed, :replacement_arg) ++
      ["--artifact", artifact_path, "--mix-cmd", mix_cmd]
  end

  defp scheduler_args(config) do
    [
      "--scheduler",
      config.scheduler,
      "--window-minutes",
      Integer.to_string(config.scheduler_window_minutes),
      "--expected-interval-ms",
      Integer.to_string(config.expected_interval_ms),
      "--stale-after-ms",
      Integer.to_string(config.stale_after_ms),
      "--min-effective-nodes",
      Integer.to_string(config.min_effective_nodes),
      "--artifact",
      config.artifact_paths.scheduler
    ]
    |> maybe_enabled_scheduler_args(config)
    |> maybe_flag(config.require_lock_loser?, "--require-lock-loser")
    |> maybe_flag(config.require_rollups?, "--require-rollups")
  end

  defp maybe_enabled_scheduler_args(args, %{scheduler_enabled?: true} = config) do
    args ++ ["--nodes", Enum.join(config.expected_nodes, ",")]
  end

  defp maybe_enabled_scheduler_args(args, config) do
    args ++
      [
        "--from",
        DateTime.to_iso8601(config.scheduler_window.from),
        "--until",
        DateTime.to_iso8601(config.scheduler_window.until),
        "--expected-nodes",
        Enum.join(config.expected_nodes, ","),
        "--mix-cmd",
        config.mix_cmd
      ]
  end

  defp gate_args(config) do
    [
      "--artifact",
      config.artifact_paths.gate,
      "--mix-cmd",
      config.mix_cmd,
      "--ops-profile",
      "p0_ops_1",
      "--rehearsal-artifact",
      config.artifact_paths.replacement,
      "--rehearsal-artifact",
      config.artifact_paths.scheduler
    ]
    |> maybe_flag(not config.replacement_live?, "--replacement-rehearsal-ready")
    |> maybe_flag(config.fail_on_gate?, "--fail-on-blocked")
  end

  defp bundle_artifact(config, git_sha, replacement_result, scheduler_result, gate_result) do
    %{
      "schema_version" => 1,
      "evidence_kind" => "p0_ops_live_rehearsal_bundle",
      "scenario" => "p0_ops_1_rehearsal_bundle",
      "generated_at" => DateTime.to_iso8601(config.generated_at),
      "run_id" => config.run_id,
      "git_sha" => git_sha,
      "node" => Atom.to_string(Node.self()),
      "mix_env" => mix_env(),
      "replacement_mode" => if(config.replacement_live?, do: "live", else: "dry_run"),
      "replacement_rehearsal_ready?" => not config.replacement_live?,
      "scheduler_mode" =>
        if(config.scheduler_enabled?, do: "enabled_rehearsal", else: "read_only"),
      "scheduler" => config.scheduler,
      "artifact_paths" => %{
        "replacement_live_rehearsal" => config.artifact_paths.replacement,
        "scheduler_live_rehearsal" => config.artifact_paths.scheduler,
        "ops_gate" => config.artifact_paths.gate,
        "bundle" => config.artifact_paths.bundle
      },
      "commands" => %{
        "replacement_live_rehearsal" =>
          command_string([
            config.mix_cmd,
            "run",
            "--no-start",
            "scripts/m8_replacement_live_rehearsal.exs",
            "--" | config.replacement_args
          ]),
        "scheduler_live_rehearsal" =>
          command_string([
            config.mix_cmd,
            "run",
            "--no-start",
            scheduler_script(config),
            "--" | scheduler_args(config)
          ]),
        "ops_gate" => command_string([config.mix_cmd, "maxio.ops.gate" | gate_args(config)])
      },
      "child_results" => %{
        "replacement_live_rehearsal" => result_view(replacement_result),
        "scheduler_live_rehearsal" => result_view(scheduler_result),
        "ops_gate" => result_view(gate_result)
      },
      "gate_status" => result_field(gate_result, :gate_status, "error"),
      "ops_gate_artifact" => result_field(gate_result, :artifact, nil)
    }
  end

  defp scheduler_script(%{scheduler_enabled?: true}),
    do: "scripts/m8_scheduler_enabled_rehearsal.exs"

  defp scheduler_script(_config), do: "scripts/m8_scheduler_live_rehearsal.exs"

  defp result_view(%{status: status, result: result}) do
    %{
      "status" => Atom.to_string(status),
      "exit_code" => Map.get(result, :exit_code),
      "artifact_path" => Map.get(result, :artifact_path),
      "gate_status" => Map.get(result, :gate_status),
      "stdout" => Map.get(result, :stdout),
      "stderr" => Map.get(result, :stderr)
    }
  end

  defp result_field(%{result: result}, key, default), do: Map.get(result, key, default)
  defp result_field(_result, _key, default), do: default

  defp stdout(artifact, %{json?: true}), do: Jason.encode!(artifact) <> "\n"

  defp stdout(artifact, _config) do
    replacement = artifact["child_results"]["replacement_live_rehearsal"]
    scheduler = artifact["child_results"]["scheduler_live_rehearsal"]
    gate = artifact["child_results"]["ops_gate"]

    "[maxio ops.live_rehearsal_bundle] run_id=#{artifact["run_id"]} " <>
      "gate_status=#{artifact["gate_status"]} " <>
      "replacement_exit=#{format_value(replacement["exit_code"])} " <>
      "scheduler_exit=#{format_value(scheduler["exit_code"])} " <>
      "gate_exit=#{format_value(gate["exit_code"])} " <>
      "artifact=#{artifact["artifact_paths"]["bundle"]}\n"
  end

  defp stderr(0, _gate_status, _gate_exit), do: nil

  defp stderr(_exit_code, gate_status, gate_exit) do
    "[maxio ops.live_rehearsal_bundle] gate failed: #{gate_status} gate_exit=#{gate_exit}\n"
  end

  defp scheduler_window(parsed, now) do
    cond do
      Keyword.has_key?(parsed, :scheduler_from) ->
        with {:ok, from} <- parse_utc(Keyword.fetch!(parsed, :scheduler_from), "--scheduler-from"),
             {:ok, until} <-
               parse_utc(Keyword.fetch!(parsed, :scheduler_until), "--scheduler-until"),
             :ok <- validate_from_until(from, until) do
          {:ok, %{from: from, until: until}}
        end

      true ->
        since_minutes =
          Keyword.get(parsed, :scheduler_since_minutes, @default_scheduler_since_minutes)

        {:ok, %{from: DateTime.add(now, -since_minutes * 60, :second), until: now}}
    end
  end

  defp expected_nodes(parsed) do
    nodes =
      parsed
      |> Keyword.get(:expected_nodes, Atom.to_string(Node.self()))
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if nodes == [] do
      {:error, "--expected-nodes must contain at least one node"}
    else
      {:ok, nodes}
    end
  end

  defp validate_scheduler_enabled_nodes(nodes, true) when length(nodes) >= 2, do: :ok

  defp validate_scheduler_enabled_nodes(_nodes, true),
    do: {:error, "--scheduler-enabled requires --expected-nodes with at least two node names"}

  defp validate_scheduler_enabled_nodes(_nodes, false), do: :ok

  defp validate_scheduler("all", true), do: :ok

  defp validate_scheduler(scheduler, _enabled?)
       when scheduler in ["fresh_drive_heal", "rebalance"], do: :ok

  defp validate_scheduler(_scheduler, true),
    do:
      {:error,
       "--scheduler must be fresh_drive_heal, rebalance, or all when --scheduler-enabled is used"}

  defp validate_scheduler(_scheduler, false),
    do: {:error, "--scheduler must be fresh_drive_heal or rebalance"}

  defp default_scheduler(true), do: @default_scheduler_enabled_scheduler
  defp default_scheduler(false), do: @default_scheduler

  defp validate_positive(parsed, key, flag) do
    case Keyword.get(parsed, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> {:error, "#{flag} must be a positive integer, got #{inspect(value)}"}
    end
  end

  defp validate_scheduler_window_mode(parsed) do
    cond do
      Keyword.has_key?(parsed, :scheduler_from) != Keyword.has_key?(parsed, :scheduler_until) ->
        {:error, "--scheduler-from and --scheduler-until must be provided together"}

      Keyword.has_key?(parsed, :scheduler_from) and
          Keyword.has_key?(parsed, :scheduler_since_minutes) ->
        {:error, "--scheduler-from and --scheduler-since-minutes cannot be used together"}

      true ->
        :ok
    end
  end

  defp validate_scheduler_enabled_window_mode(parsed, true) do
    if Enum.any?(
         [:scheduler_from, :scheduler_until, :scheduler_since_minutes],
         &Keyword.has_key?(parsed, &1)
       ) do
      {:error,
       "--scheduler-enabled uses --scheduler-window-minutes and does not accept --scheduler-from/--scheduler-until/--scheduler-since-minutes"}
    else
      :ok
    end
  end

  defp validate_scheduler_enabled_window_mode(_parsed, false), do: :ok

  defp validate_replacement_args(parsed) do
    blocked =
      parsed
      |> Keyword.get_values(:replacement_arg)
      |> Enum.filter(&(&1 in ["--artifact", "--mix-cmd"]))

    case blocked do
      [] -> :ok
      _ -> {:error, "--replacement-arg cannot override --artifact or --mix-cmd"}
    end
  end

  defp parse_utc(value, flag) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, 0} -> {:ok, dt}
      {:ok, _dt, _offset} -> {:error, "#{flag} must use UTC Z offset"}
      {:error, reason} -> {:error, "#{flag} must be ISO8601: #{inspect(reason)}"}
    end
  end

  defp validate_from_until(from, until) do
    if DateTime.compare(from, until) == :lt do
      :ok
    else
      {:error, "--scheduler-from must be before --scheduler-until"}
    end
  end

  defp artifact_paths(dir, run_id, bundle_path) do
    with {:ok, bundle} <- bundle_path(dir, run_id, bundle_path) do
      {:ok,
       %{
         replacement: Path.join(dir, "#{run_id}_replacement.json"),
         scheduler: Path.join(dir, "#{run_id}_scheduler.json"),
         gate: Path.join(dir, "#{run_id}_gate.json"),
         bundle: bundle
       }}
    end
  end

  defp bundle_path(dir, run_id, nil), do: {:ok, Path.join(dir, "#{run_id}_bundle.json")}

  defp bundle_path(dir, _run_id, path) when is_binary(path) do
    with :ok <- reject_parent_refs(path, "--artifact"),
         expanded <- expand_under_dir(path, dir),
         true <- under_dir?(expanded, dir) do
      {:ok, expanded}
    else
      false -> {:error, "--artifact must resolve under --artifact-dir"}
      {:error, _message} = error -> error
    end
  end

  defp validate_run_id(run_id) do
    if safe_path_segment?(run_id) do
      :ok
    else
      {:error, "--run-id must be a safe file name segment"}
    end
  end

  defp normalize_artifact_dir(dir, base_dir) when is_binary(dir) do
    with :ok <- reject_parent_refs(dir, "--artifact-dir"),
         expanded <- Path.expand(dir, base_dir),
         true <- under_dir?(expanded, base_dir) do
      {:ok, expanded}
    else
      false -> {:error, "--artifact-dir must resolve under the current working directory"}
      {:error, _message} = error -> error
    end
  end

  defp normalize_artifact_dir(_dir, _base_dir), do: {:error, "--artifact-dir is required"}

  defp reject_parent_refs(path, flag) do
    if ".." in Path.split(path) do
      {:error, "#{flag} cannot contain parent directory segments"}
    else
      :ok
    end
  end

  defp expand_under_dir(path, dir) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, dir)
    end
  end

  defp safe_path_segment?(value) when is_binary(value) do
    value not in ["", ".", ".."] and
      Path.basename(value) == value and
      not String.contains?(value, ["/", "\\", ".."])
  end

  defp safe_path_segment?(_value), do: false

  defp under_dir?(path, dir) do
    path_parts = path |> Path.expand() |> path_parts()
    dir_parts = dir |> Path.expand() |> path_parts()

    Enum.take(path_parts, length(dir_parts)) == dir_parts
  end

  defp path_parts(path) do
    path
    |> Path.split()
    |> Enum.map(&String.downcase/1)
  end

  defp maybe_flag(args, true, flag), do: args ++ [flag]
  defp maybe_flag(args, false, _flag), do: args

  defp write_artifact!(path, artifact) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode!(artifact) <> "\n")
  end

  defp usage_result(message) do
    %{
      exit_code: 64,
      stderr: "[maxio ops.live_rehearsal_bundle] #{message}\n\n" <> @usage
    }
  end

  defp run_id(%DateTime{} = now) do
    stamp =
      now
      |> DateTime.to_iso8601()
      |> String.replace(~r/[^0-9A-Za-z_.-]/, "_")

    "m8_p0_ops_live_rehearsal_#{stamp}_#{System.unique_integer([:positive])}"
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

  defp format_value(nil), do: "nil"
  defp format_value(value), do: to_string(value)
end
