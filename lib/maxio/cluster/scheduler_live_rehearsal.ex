defmodule Maxio.Cluster.SchedulerLiveRehearsal do
  @moduledoc """
  Bounded live scheduler rehearsal harness.

  This module backs `scripts/m8_scheduler_live_rehearsal.exs`. It does not start
  schedulers or repair work; it only shells out to the read-only evidence task and
  writes an artifact for the operator runbook.
  """

  @usage """
  Usage:
    mix run --no-start scripts/m8_scheduler_live_rehearsal.exs -- \\
      --scheduler fresh_drive_heal|rebalance \\
      --from 2026-06-14T00:00:00Z --until 2026-06-14T02:00:00Z \\
      --window-minutes 5 \\
      --expected-nodes node_a,node_b \\
      --expected-interval-ms 60000 --stale-after-ms 120000 \\
      [--min-effective-nodes N] [--require-lock-loser] [--require-rollups] \\
      [--artifact artifacts/m8_scheduler_live_rehearsal.json]

  This script does not start schedulers or run repair work. It shells out to
  `mix maxio.scheduler.evidence --json --fail-on-attention`, writes a rehearsal
  artifact, and exits non-zero unless evidence status is ok.
  """

  @default_max_duration_minutes 240

  def usage, do: @usage

  def run(argv, opts \\ []) do
    case normalize(argv) do
      {:ok, config} -> run_evidence(config, opts)
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
          scheduler: :string,
          from: :string,
          until: :string,
          window_minutes: :integer,
          expected_nodes: :string,
          expected_interval_ms: :integer,
          stale_after_ms: :integer,
          min_effective_nodes: :integer,
          max_duration_minutes: :integer,
          require_lock_loser: :boolean,
          require_rollups: :boolean,
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
    with {:ok, scheduler} <- required(opts, :scheduler, "--scheduler"),
         :ok <- validate_scheduler(scheduler),
         {:ok, from_text} <- required(opts, :from, "--from"),
         {:ok, until_text} <- required(opts, :until, "--until"),
         {:ok, from} <- parse_utc(from_text, "--from"),
         {:ok, until} <- parse_utc(until_text, "--until"),
         {:ok, window_minutes} <- positive(opts, :window_minutes, "--window-minutes"),
         {:ok, expected_interval_ms} <-
           positive(opts, :expected_interval_ms, "--expected-interval-ms"),
         {:ok, stale_after_ms} <- positive(opts, :stale_after_ms, "--stale-after-ms"),
         {:ok, min_effective_nodes} <- positive_or_default(opts, :min_effective_nodes, 1),
         {:ok, max_duration_minutes} <-
           positive_or_default(opts, :max_duration_minutes, @default_max_duration_minutes),
         {:ok, expected_nodes} <- expected_nodes(opts),
         :ok <- validate_window(from, until, max_duration_minutes) do
      {:ok,
       %{
         scheduler: scheduler,
         from: from_text,
         until: until_text,
         window_minutes: window_minutes,
         expected_nodes: expected_nodes,
         expected_interval_ms: expected_interval_ms,
         stale_after_ms: stale_after_ms,
         min_effective_nodes: min_effective_nodes,
         require_lock_loser?: Keyword.get(opts, :require_lock_loser, false),
         require_rollups?: Keyword.get(opts, :require_rollups, false),
         artifact_path: artifact_path(opts, scheduler, until_text),
         mix_cmd: Keyword.get(opts, :mix_cmd) || System.find_executable("mix") || "mix"
       }}
    end
  end

  defp run_evidence(config, opts) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    git_sha_fun = Keyword.get(opts, :git_sha_fun, &git_sha/0)
    now_fun = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)
    artifact_writer = Keyword.get(opts, :artifact_writer, &write_artifact!/2)

    args = evidence_args(config)
    command = command_string([config.mix_cmd | args])
    {output, exit_status} = run_command(command_runner, config.mix_cmd, args)
    evidence = extract_json(output)

    artifact = %{
      "version" => 1,
      "evidence_kind" => "scheduler_live_rehearsal",
      "scenario" => "scheduler_evidence_rehearsal",
      "generated_at" => now_fun.() |> DateTime.to_iso8601(),
      "git_sha" => git_sha_fun.(),
      "scheduler" => config.scheduler,
      "from" => config.from,
      "until" => config.until,
      "window_minutes" => config.window_minutes,
      "expected_nodes" => config.expected_nodes,
      "expected_interval_ms" => config.expected_interval_ms,
      "stale_after_ms" => config.stale_after_ms,
      "min_effective_nodes" => config.min_effective_nodes,
      "require_lock_loser?" => config.require_lock_loser?,
      "require_rollups?" => config.require_rollups?,
      "commands" => %{"evidence" => command},
      "evidence_exit_status" => exit_status,
      "scheduler_evidence" => evidence,
      "raw_output" => output
    }

    artifact_writer.(config.artifact_path, artifact)

    status = if is_map(evidence), do: Map.get(evidence, "status"), else: "unparseable"
    warnings = if is_map(evidence), do: Map.get(evidence, "warnings", []), else: []

    stdout =
      "[maxio scheduler.live_rehearsal] artifact=#{config.artifact_path} " <>
        "evidence_status=#{status} evidence_exit=#{exit_status}\n"

    if exit_status == 0 and status == "ok" and warnings == [] do
      {:ok,
       %{exit_code: 0, stdout: stdout, artifact_path: config.artifact_path, artifact: artifact}}
    else
      {:error,
       %{
         exit_code: 1,
         stdout: stdout,
         stderr: "[maxio scheduler.live_rehearsal] evidence gate failed\n",
         artifact_path: config.artifact_path,
         artifact: artifact
       }}
    end
  end

  defp evidence_args(config) do
    [
      "maxio.scheduler.evidence",
      "--scheduler",
      config.scheduler,
      "--from",
      config.from,
      "--until",
      config.until,
      "--window-minutes",
      Integer.to_string(config.window_minutes),
      "--expected-interval-ms",
      Integer.to_string(config.expected_interval_ms),
      "--stale-after-ms",
      Integer.to_string(config.stale_after_ms),
      "--expected-nodes",
      Enum.join(config.expected_nodes, ","),
      "--min-effective-nodes",
      Integer.to_string(config.min_effective_nodes),
      "--fail-on-attention",
      "--json"
    ]
    |> maybe_flag(config.require_lock_loser?, "--require-lock-loser")
    |> maybe_flag(config.require_rollups?, "--require-rollups")
  end

  defp maybe_flag(args, true, flag), do: args ++ [flag]
  defp maybe_flag(args, false, _flag), do: args

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

  defp artifact_path(opts, scheduler, until_text) do
    Keyword.get_lazy(opts, :artifact, fn ->
      safe_until = String.replace(until_text, ~r/[^0-9A-Za-z_.-]/, "_")
      Path.join("artifacts", "m8_scheduler_live_rehearsal_#{scheduler}_#{safe_until}.json")
    end)
  end

  defp required(opts, key, flag) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{flag} is required"}
    end
  end

  defp positive(opts, key, flag) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "#{flag} must be a positive integer"}
    end
  end

  defp positive_or_default(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "--#{String.replace(to_string(key), "_", "-")} must be a positive integer"}
    end
  end

  defp expected_nodes(opts) do
    nodes =
      opts
      |> required(:expected_nodes, "--expected-nodes")
      |> case do
        {:ok, value} ->
          value
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        error ->
          error
      end

    case nodes do
      {:error, _message} = error -> error
      [] -> {:error, "--expected-nodes must contain at least one node"}
      nodes -> {:ok, nodes}
    end
  end

  defp parse_utc(value, flag) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, 0} -> {:ok, dt}
      {:ok, _dt, _offset} -> {:error, "#{flag} must use UTC Z offset"}
      {:error, reason} -> {:error, "#{flag} must be ISO8601: #{inspect(reason)}"}
    end
  end

  defp validate_scheduler(scheduler) when scheduler in ["fresh_drive_heal", "rebalance"], do: :ok

  defp validate_scheduler(_scheduler) do
    {:error, "--scheduler must be fresh_drive_heal or rebalance"}
  end

  defp validate_window(from, until, max_duration_minutes) do
    duration_minutes = DateTime.diff(until, from, :second) / 60

    cond do
      DateTime.compare(from, until) != :lt ->
        {:error, "--from must be before --until"}

      duration_minutes > max_duration_minutes ->
        {:error, "window exceeds --max-duration-minutes"}

      true ->
        :ok
    end
  end

  defp usage_result(message) do
    %{
      exit_code: 64,
      stderr: "[maxio scheduler.live_rehearsal] #{message}\n\n" <> @usage
    }
  end

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
