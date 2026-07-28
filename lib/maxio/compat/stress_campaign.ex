defmodule Maxio.Compat.StressCampaign do
  @moduledoc """
  Local, repeatable stress and fault campaign harness.

  The campaign is intentionally local-safe by default. It wraps the compat
  matrix optional stress/fault suites, skips external client probes, writes a
  single operator artifact, and lets callers opt into fatal exit codes with
  `--fail-on-blocked` / `--fail-on-attention`.
  """

  alias Maxio.Compat.Matrix

  @default_suites ~w(streaming_stress_matrix storage_fault_matrix ops_resilience_matrix)

  @usage """
  Usage:
    mix maxio.stress.campaign [--json] [--artifact PATH] [--mix-cmd mix]
      [--suite streaming_stress_matrix|storage_fault_matrix|ops_resilience_matrix]
      [--fail-on-blocked] [--fail-on-attention] [--strict]

  Default local-safe suites:
    streaming_stress_matrix: aws-chunked PutObject/MPU stress with env-controlled scale
    storage_fault_matrix: atomic commit, erasure bitrot/heal, scanner evidence
    ops_resilience_matrix: M8 integration, scheduler cadence, replacement/rebalance workflow

  This task does not require or run external aws-cli/mc/boto3 clients. It writes
  a single stress campaign JSON artifact containing the child matrix evidence.
  """

  def usage, do: @usage

  def run(argv, opts \\ []) do
    case normalize(argv) do
      {:ok, config} -> run_campaign(config, opts)
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
          suite: :string,
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
    requested_suites =
      argv
      |> collect_requested_values("--suite", [])
      |> Enum.reverse()
      |> Enum.uniq()

    {:ok,
     %{
       argv: argv,
       opts: opts,
       artifact_path: Keyword.get(opts, :artifact),
       mix_cmd: Keyword.get(opts, :mix_cmd) || System.find_executable("mix") || "mix",
       suites: if(requested_suites == [], do: @default_suites, else: requested_suites),
       json?: Keyword.get(opts, :json, false),
       fail_on_blocked?: Keyword.get(opts, :fail_on_blocked, false),
       fail_on_attention?:
         Keyword.get(opts, :fail_on_attention, false) or Keyword.get(opts, :strict, false),
       strict?: Keyword.get(opts, :strict, false)
     }}
  end

  defp collect_requested_values([], _flag, acc), do: acc

  defp collect_requested_values([flag, value | rest], flag, acc) do
    collect_requested_values(rest, flag, [value | acc])
  end

  defp collect_requested_values([arg | rest], flag, acc) do
    prefix = flag <> "="

    if String.starts_with?(arg, prefix) do
      collect_requested_values(rest, flag, [String.replace_prefix(arg, prefix, "") | acc])
    else
      collect_requested_values(rest, flag, acc)
    end
  end

  defp run_campaign(config, opts) do
    now_fun = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)
    git_sha_fun = Keyword.get(opts, :git_sha_fun, &git_sha/0)
    artifact_writer = Keyword.get(opts, :artifact_writer, &write_artifact!/2)

    generated_at = now_fun.()
    run_id = run_id(generated_at)
    artifact_path = config.artifact_path || default_artifact_path(run_id)

    matrix_args = matrix_args(config, artifact_path)

    matrix_opts =
      opts
      |> Keyword.take([:command_runner, :git_sha_fun, :now_fun])
      |> Keyword.put(:artifact_writer, fn _path, _artifact -> :ok end)

    case Matrix.run(matrix_args, matrix_opts) do
      {:ok, matrix_result} ->
        finish_campaign(
          config,
          generated_at,
          run_id,
          artifact_path,
          matrix_args,
          matrix_result,
          artifact_writer,
          git_sha_fun
        )

      {:error, %{exit_code: 64} = usage} ->
        {:error, usage_result("child matrix usage error: #{String.trim(usage.stderr || "")}")}

      {:error, matrix_result} ->
        finish_campaign(
          config,
          generated_at,
          run_id,
          artifact_path,
          matrix_args,
          matrix_result,
          artifact_writer,
          git_sha_fun
        )
    end
  end

  defp finish_campaign(
         config,
         generated_at,
         run_id,
         artifact_path,
         matrix_args,
         matrix_result,
         artifact_writer,
         git_sha_fun
       ) do
    matrix_artifact = matrix_result.artifact

    artifact = %{
      "schema_version" => 1,
      "evidence_kind" => "stress_campaign",
      "scenario" => "local_stress_fault_campaign",
      "generated_at" => DateTime.to_iso8601(generated_at),
      "run_id" => run_id,
      "git_sha" => git_sha_fun.(),
      "node" => Atom.to_string(Node.self()),
      "mix_env" => mix_env(),
      "command" => command_string([config.mix_cmd, "maxio.stress.campaign" | config.argv]),
      "artifact_path" => artifact_path,
      "profile" => "local_safe_default",
      "gate_status" => matrix_result.gate_status,
      "counts" => matrix_artifact["counts"],
      "blockers" => matrix_artifact["blockers"],
      "warnings" => matrix_artifact["warnings"],
      "config" => %{
        "suites" => config.suites,
        "matrix_command" => command_string([config.mix_cmd, "maxio.compat.matrix" | matrix_args]),
        "fail_on_blocked" => config.fail_on_blocked?,
        "fail_on_attention" => config.fail_on_attention?,
        "strict" => config.strict?,
        "external_clients_required" => false
      },
      "matrix" => matrix_artifact
    }

    artifact_writer.(artifact_path, artifact)

    result = %{
      exit_code: matrix_result.exit_code,
      gate_status: matrix_result.gate_status,
      artifact_path: artifact_path,
      artifact: artifact,
      stdout: stdout(artifact, config),
      stderr: stderr(matrix_result.exit_code, matrix_result.gate_status)
    }

    if result.exit_code == 0, do: {:ok, result}, else: {:error, result}
  end

  defp matrix_args(config, artifact_path) do
    base = [
      "--mix-cmd",
      config.mix_cmd,
      "--artifact",
      artifact_path,
      "--skip-external-probes"
    ]

    suite_args = Enum.flat_map(config.suites, &["--suite", &1])

    base ++ suite_args ++ failure_flags(config)
  end

  defp failure_flags(config) do
    []
    |> maybe_flag(config.fail_on_blocked?, "--fail-on-blocked")
    |> maybe_flag(config.fail_on_attention?, "--fail-on-attention")
    |> maybe_flag(config.strict?, "--strict")
  end

  defp maybe_flag(flags, true, flag), do: [flag | flags]
  defp maybe_flag(flags, false, _flag), do: flags

  defp stdout(artifact, %{json?: true}), do: Jason.encode!(artifact) <> "\n"

  defp stdout(artifact, _config) do
    summary =
      "[maxio stress.campaign] gate_status=#{artifact["gate_status"]} " <>
        "entries=#{artifact["counts"]["total"]} ok=#{artifact["counts"]["ok"]} " <>
        "attention=#{artifact["counts"]["attention"]} " <>
        "blocked=#{artifact["counts"]["blocked"]} error=#{artifact["counts"]["error"]} " <>
        "artifact=#{artifact["artifact_path"]}\n"

    suite_lines =
      artifact["matrix"]["suites"]
      |> Enum.map(fn suite ->
        "[maxio stress.campaign.suite] id=#{suite["id"]} status=#{suite["status"]} " <>
          "tests=#{format_value(suite["exunit"]["tests"])} " <>
          "failures=#{format_value(suite["exunit"]["failures"])} " <>
          "duration_ms=#{suite["duration_ms"]}\n"
      end)
      |> Enum.join()

    blocker_lines = Enum.map_join(artifact["blockers"], "", &gate_line("blocker", &1))
    warning_lines = Enum.map_join(artifact["warnings"], "", &gate_line("warning", &1))

    summary <> suite_lines <> blocker_lines <> warning_lines
  end

  defp gate_line(kind, item) do
    "[maxio stress.campaign.#{kind}] entry=#{item["entry"]} kind=#{item["kind"]} " <>
      "reason=#{item["reason"]}\n"
  end

  defp stderr(0, _gate_status), do: nil

  defp stderr(_exit_code, gate_status),
    do: "[maxio stress.campaign] gate failed: #{gate_status}\n"

  defp usage_result(message) do
    %{
      exit_code: 64,
      stderr: "[maxio stress.campaign] #{message}\n\n" <> @usage
    }
  end

  defp write_artifact!(path, artifact) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode!(artifact) <> "\n")
  end

  defp default_artifact_path(run_id), do: Path.join("artifacts", "#{run_id}.json")

  defp run_id(%DateTime{} = generated_at) do
    stamp =
      generated_at
      |> DateTime.to_iso8601()
      |> String.replace(~r/[^0-9A-Za-z_.-]/, "_")

    "p2_stress_campaign_#{stamp}_#{System.unique_integer([:positive])}"
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
