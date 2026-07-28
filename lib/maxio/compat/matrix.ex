defmodule Maxio.Compat.Matrix do
  @moduledoc """
  Unified S3 compatibility matrix harness.

  The first slice intentionally aggregates existing internal, self-signed
  compatibility suites and records external client availability as evidence.
  External aws-cli/mc/boto3 checks are reporting-only unless strict failure
  flags are requested.
  """

  alias Maxio.Compat.{ExternalSmoke, StreamingStressConfig}

  @usage """
  Usage:
    mix maxio.compat.matrix [--json] [--artifact PATH] [--mix-cmd mix]
      [--suite authz_matrix|m4_matrix|multipart_range_matrix|list_conditional_matrix|sdk_highfreq_matrix|streaming_matrix|streaming_stress_matrix]
      [--skip-external-probes]
      [--include-external-smoke] [--no-internal-suites]
      [--external-smoke-client aws_cli|minio_mc|python_boto3]
      [--external-endpoint URL] [--external-access-key KEY]
      [--external-secret-key SECRET] [--external-region REGION]
      [--fail-on-blocked] [--fail-on-attention] [--strict]

  Default internal suites:
    authz_matrix:           mix test test/maxio/s3/authz_matrix_test.exs --max-failures 1
    m4_matrix:              mix test test/maxio/s3/m4_matrix_test.exs --max-failures 1
    multipart_range_matrix: mix test test/maxio/s3/multipart_range_matrix_test.exs --max-failures 1
    list_conditional_matrix: mix test test/maxio/s3/list_conditional_matrix_test.exs --max-failures 1
    sdk_highfreq_matrix:    mix test test/maxio/s3/sdk_highfreq_matrix_test.exs --max-failures 1
    streaming_matrix:       mix test test/maxio/s3/streaming_matrix_test.exs --max-failures 1

  Optional internal suites:
    streaming_stress_matrix: mix test test/maxio/s3/streaming_stress_matrix_test.exs --max-failures 1
    storage_fault_matrix: mix test test/maxio/storage/atomic_commit_test.exs test/maxio/storage/erasure/bitrot_e2e_test.exs test/maxio/storage/scanner_test.exs --max-failures 1
    ops_resilience_matrix: mix test test/maxio/cluster/m8_integration_test.exs test/maxio/cluster/scheduler_cadence_test.exs test/maxio/cluster/replacement_rebalance_integration_test.exs --max-failures 1

  External availability evidence:
    aws-cli, MinIO mc, and python-boto3 are probed when available. Missing
    clients are recorded as attention evidence, not blockers, unless
    --fail-on-attention or --strict is explicit.

  External smoke evidence:
    --include-external-smoke explicitly runs minimal bucket/object CRUD through
    selected external clients against an already-running endpoint. The command
    does not start Maxio. Missing tools or missing endpoint/credentials are
    attention evidence; failed client operations are blocked evidence.
  """

  @default_suites [
    %{
      id: "authz_matrix",
      name: "S3 authz matrix",
      path: "test/maxio/s3/authz_matrix_test.exs",
      args: ["test", "test/maxio/s3/authz_matrix_test.exs", "--max-failures", "1"],
      mode: "internal_self_signed"
    },
    %{
      id: "m4_matrix",
      name: "M4 advanced S3 matrix",
      path: "test/maxio/s3/m4_matrix_test.exs",
      args: ["test", "test/maxio/s3/m4_matrix_test.exs", "--max-failures", "1"],
      mode: "internal_self_signed"
    },
    %{
      id: "multipart_range_matrix",
      name: "Multipart and Range S3 matrix",
      path: "test/maxio/s3/multipart_range_matrix_test.exs",
      args: ["test", "test/maxio/s3/multipart_range_matrix_test.exs", "--max-failures", "1"],
      mode: "internal_self_signed"
    },
    %{
      id: "list_conditional_matrix",
      name: "ListObjects and Conditional S3 matrix",
      path: "test/maxio/s3/list_conditional_matrix_test.exs",
      args: ["test", "test/maxio/s3/list_conditional_matrix_test.exs", "--max-failures", "1"],
      mode: "internal_self_signed"
    },
    %{
      id: "sdk_highfreq_matrix",
      name: "SDK high-frequency S3 matrix",
      path: "test/maxio/s3/sdk_highfreq_matrix_test.exs",
      args: ["test", "test/maxio/s3/sdk_highfreq_matrix_test.exs", "--max-failures", "1"],
      mode: "internal_self_signed"
    },
    %{
      id: "streaming_matrix",
      name: "SigV4 aws-chunked streaming S3 matrix",
      path: "test/maxio/s3/streaming_matrix_test.exs",
      args: ["test", "test/maxio/s3/streaming_matrix_test.exs", "--max-failures", "1"],
      mode: "internal_self_signed"
    }
  ]

  @optional_suites [
    %{
      id: "streaming_stress_matrix",
      name: "SigV4 aws-chunked streaming stress matrix",
      path: "test/maxio/s3/streaming_stress_matrix_test.exs",
      args: ["test", "test/maxio/s3/streaming_stress_matrix_test.exs", "--max-failures", "1"],
      mode: "internal_self_signed_stress"
    },
    %{
      id: "storage_fault_matrix",
      name: "Storage atomicity, bitrot, and scanner fault matrix",
      path: "test/maxio/storage/atomic_commit_test.exs",
      args: [
        "test",
        "test/maxio/storage/atomic_commit_test.exs",
        "test/maxio/storage/erasure/bitrot_e2e_test.exs",
        "test/maxio/storage/scanner_test.exs",
        "--max-failures",
        "1"
      ],
      mode: "internal_fault_injection"
    },
    %{
      id: "ops_resilience_matrix",
      name: "Ops scheduler, M8, replacement, and rebalance resilience matrix",
      path: "test/maxio/cluster/m8_integration_test.exs",
      args: [
        "test",
        "test/maxio/cluster/m8_integration_test.exs",
        "test/maxio/cluster/scheduler_cadence_test.exs",
        "test/maxio/cluster/replacement_rebalance_integration_test.exs",
        "--max-failures",
        "1"
      ],
      mode: "internal_ops_resilience"
    }
  ]

  @all_suites @default_suites ++ @optional_suites

  def usage, do: @usage

  def run(argv, opts \\ []) do
    case normalize(argv) do
      {:ok, config} -> run_matrix(config, opts)
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
          skip_external_probes: :boolean,
          include_external_smoke: :boolean,
          no_internal_suites: :boolean,
          external_smoke_client: :string,
          external_endpoint: :string,
          external_access_key: :string,
          external_secret_key: :string,
          external_region: :string,
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
    requested_suites = requested_suites(argv)
    requested_smoke_clients = requested_smoke_clients(argv)

    with :ok <- validate_suites(requested_suites),
         :ok <- validate_smoke_clients(requested_smoke_clients) do
      {:ok,
       %{
         argv: argv,
         opts: opts,
         requested_suites: requested_suites,
         requested_smoke_clients: requested_smoke_clients,
         artifact_path: Keyword.get(opts, :artifact),
         mix_cmd: Keyword.get(opts, :mix_cmd) || System.find_executable("mix") || "mix",
         json?: Keyword.get(opts, :json, false),
         skip_external_probes?: Keyword.get(opts, :skip_external_probes, false),
         include_external_smoke?: Keyword.get(opts, :include_external_smoke, false),
         no_internal_suites?: Keyword.get(opts, :no_internal_suites, false),
         external_smoke_config: external_smoke_config(opts, requested_smoke_clients),
         fail_on_blocked?: Keyword.get(opts, :fail_on_blocked, false),
         fail_on_attention?:
           Keyword.get(opts, :fail_on_attention, false) or Keyword.get(opts, :strict, false),
         strict?: Keyword.get(opts, :strict, false)
       }}
    end
  end

  defp requested_suites(argv) do
    argv
    |> collect_requested_values("--suite", [])
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp requested_smoke_clients(argv) do
    argv
    |> collect_requested_values("--external-smoke-client", [])
    |> Enum.reverse()
    |> Enum.map(&ExternalSmoke.canonical_client_id/1)
    |> Enum.uniq()
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

  defp run_matrix(config, opts) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    artifact_writer = Keyword.get(opts, :artifact_writer, &write_artifact!/2)

    external_probe_fun =
      Keyword.get(opts, :external_probe_fun) ||
        fn ->
          probe_external_clients(
            Keyword.get(opts, :external_executable_finder, &System.find_executable/1),
            Keyword.get(opts, :external_command_runner, &System.cmd/3)
          )
        end

    external_smoke_fun =
      Keyword.get(opts, :external_smoke_fun) ||
        fn smoke_config ->
          ExternalSmoke.run(smoke_config,
            executable_finder:
              Keyword.get(
                opts,
                :external_smoke_executable_finder,
                Keyword.get(opts, :external_executable_finder, &System.find_executable/1)
              ),
            command_runner: Keyword.get(opts, :external_smoke_command_runner, &System.cmd/3),
            tmp_root_fun: Keyword.get(opts, :external_smoke_tmp_root_fun, &System.tmp_dir!/0)
          )
        end

    git_sha_fun = Keyword.get(opts, :git_sha_fun, &git_sha/0)
    now_fun = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)

    generated_at = now_fun.()
    run_id = run_id(generated_at)
    artifact_path = config.artifact_path || default_artifact_path(run_id)

    suites =
      config
      |> configured_suites()
      |> Enum.map(&run_suite(&1, config.mix_cmd, command_runner))

    external_clients =
      if config.skip_external_probes? do
        []
      else
        run_external_probes(external_probe_fun)
      end

    external_smoke =
      if config.include_external_smoke? do
        run_external_smoke(external_smoke_fun, config.external_smoke_config)
      else
        []
      end

    entries = suites ++ external_clients ++ external_smoke
    gate_status = overall_status(entries)
    blockers = gate_items(entries, "blockers")
    warnings = gate_items(entries, "warnings")

    artifact = %{
      "schema_version" => 1,
      "generated_at" => DateTime.to_iso8601(generated_at),
      "run_id" => run_id,
      "git_sha" => git_sha_fun.(),
      "node" => Atom.to_string(Node.self()),
      "mix_env" => mix_env(),
      "command" => parent_command(config),
      "artifact_path" => artifact_path,
      "config" => config_view(config),
      "gate_status" => gate_status,
      "counts" => counts(entries),
      "blockers" => blockers,
      "warnings" => warnings,
      "suites" => suites,
      "external_clients" => external_clients,
      "external_smoke" => external_smoke
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

  defp configured_suites(%{no_internal_suites?: true}), do: []
  defp configured_suites(%{requested_suites: []}), do: @default_suites

  defp configured_suites(%{requested_suites: requested_suites}) do
    Enum.filter(@all_suites, &(&1.id in requested_suites))
  end

  defp run_suite(suite, mix_cmd, command_runner) do
    started = System.monotonic_time(:millisecond)

    try do
      {output, exit_status} = command_runner.(mix_cmd, suite.args, stderr_to_stdout: true)
      duration_ms = System.monotonic_time(:millisecond) - started
      finish_suite(suite, output, exit_status, duration_ms)
    rescue
      error ->
        duration_ms = System.monotonic_time(:millisecond) - started
        error_suite(suite, Exception.message(error), duration_ms)
    end
  end

  defp finish_suite(suite, output, exit_status, duration_ms) do
    exunit = parse_exunit_counts(output)
    status = suite_status(exit_status, exunit)

    suite
    |> suite_view(output, exit_status, duration_ms, status, exunit)
    |> put_suite_gate_items(status, exit_status)
  end

  defp suite_view(suite, output, exit_status, duration_ms, status, exunit) do
    %{
      "kind" => "internal_suite",
      "id" => suite.id,
      "name" => suite.name,
      "path" => suite.path,
      "mode" => suite.mode,
      "command" => command_string([suite.path | Enum.drop(suite.args, 2)]),
      "mix_command" => command_string(suite.args),
      "status" => status,
      "exit_status" => exit_status,
      "duration_ms" => duration_ms,
      "exunit" => exunit,
      "output_snippet" => output_snippet(output)
    }
    |> maybe_put_suite_evidence(suite)
  end

  defp suite_status(0, %{"tests" => tests}) when is_integer(tests) and tests > 0, do: "ok"
  defp suite_status(0, _exunit), do: "blocked"
  defp suite_status(_exit_status, _exunit), do: "blocked"

  defp maybe_put_suite_evidence(view, %{id: "streaming_stress_matrix"}) do
    Map.put(view, "evidence", StreamingStressConfig.artifact_evidence!())
  end

  defp maybe_put_suite_evidence(view, %{id: "storage_fault_matrix"}) do
    Map.put(view, "evidence", %{
      "profile" => "local_storage_fault_matrix",
      "scenarios" => [
        "storage atomic commit and failed-write cleanup",
        "erasure bitrot detection and heal evidence",
        "scanner metadata reconciliation and failure handling"
      ]
    })
  end

  defp maybe_put_suite_evidence(view, %{id: "ops_resilience_matrix"}) do
    Map.put(view, "evidence", %{
      "profile" => "local_ops_resilience_matrix",
      "scenarios" => [
        "M8 ops gate integration evidence",
        "scheduler cadence and stale-run detection",
        "replacement and rebalance workflow integration"
      ]
    })
  end

  defp maybe_put_suite_evidence(view, _suite), do: view

  defp put_suite_gate_items(view, "blocked", 0) do
    view
    |> Map.put("blockers", [
      %{
        "reason" => "compat_suite_no_tests",
        "exit_status" => 0,
        "path" => view["path"]
      }
    ])
    |> Map.put("warnings", [])
  end

  defp put_suite_gate_items(view, "blocked", exit_status) do
    view
    |> Map.put("blockers", [
      %{
        "reason" => "compat_suite_failed",
        "exit_status" => exit_status,
        "path" => view["path"]
      }
    ])
    |> Map.put("warnings", [])
  end

  defp put_suite_gate_items(view, _status, _exit_status) do
    view
    |> Map.put("blockers", [])
    |> Map.put("warnings", [])
  end

  defp error_suite(suite, message, duration_ms) do
    %{
      "kind" => "internal_suite",
      "id" => suite.id,
      "name" => suite.name,
      "path" => suite.path,
      "mode" => suite.mode,
      "command" => command_string([suite.path | Enum.drop(suite.args, 2)]),
      "mix_command" => command_string(suite.args),
      "status" => "error",
      "exit_status" => nil,
      "duration_ms" => duration_ms,
      "exunit" => %{"tests" => nil, "failures" => nil, "excluded" => nil},
      "output_snippet" => message,
      "blockers" => [%{"reason" => "command_failed", "message" => message}],
      "warnings" => []
    }
  end

  defp run_external_probes(external_probe_fun) do
    external_probe_fun.()
    |> Enum.map(&normalize_external_client/1)
  rescue
    error ->
      [
        %{
          "kind" => "external_client",
          "id" => "external_probe",
          "label" => "external client probe",
          "mode" => "external_availability",
          "status" => "error",
          "path" => nil,
          "detail" => nil,
          "blockers" => [
            %{"reason" => "external_probe_failed", "message" => Exception.message(error)}
          ],
          "warnings" => []
        }
      ]
  end

  defp run_external_smoke(external_smoke_fun, smoke_config) do
    external_smoke_fun.(smoke_config)
    |> Enum.map(&normalize_external_smoke/1)
  rescue
    error ->
      [
        %{
          "kind" => "external_smoke",
          "id" => "external_smoke",
          "label" => "external smoke",
          "mode" => "external_smoke",
          "status" => "error",
          "duration_ms" => nil,
          "steps" => [],
          "blockers" => [
            %{"reason" => "external_smoke_failed", "message" => Exception.message(error)}
          ],
          "warnings" => []
        }
      ]
  end

  defp probe_external_clients(executable_finder, command_runner) do
    [
      probe_cli("aws_cli", "aws-cli", "aws", ["--version"], executable_finder, command_runner),
      probe_cli("minio_mc", "MinIO mc", "mc", ["--version"], executable_finder, command_runner),
      probe_python_boto3(executable_finder, command_runner)
    ]
  end

  defp probe_cli(id, label, executable, args, executable_finder, command_runner) do
    case executable_finder.(executable) do
      nil ->
        external_attention(id, label,
          executable: executable,
          reason: "external_client_not_configured",
          detail: "#{executable} executable was not found on PATH"
        )

      path ->
        case command_runner.(path, args, stderr_to_stdout: true) do
          {output, 0} ->
            %{
              "id" => id,
              "label" => label,
              "status" => "ok",
              "path" => path,
              "detail" => "#{executable} probe ok: #{compact_output(output)}",
              "warnings" => [],
              "blockers" => []
            }

          {output, exit_status} ->
            external_attention(id, label,
              executable: path,
              reason: "external_client_probe_failed",
              detail:
                "#{executable} #{Enum.join(args, " ")} exited #{exit_status}: #{compact_output(output)}"
            )
        end
    end
  rescue
    error ->
      external_attention(id, label,
        executable: executable,
        reason: "external_client_probe_failed",
        detail: Exception.message(error)
      )
  end

  defp probe_python_boto3(executable_finder, command_runner) do
    case python_executable(executable_finder) do
      nil ->
        external_attention("python_boto3", "python-boto3",
          executable: "python",
          reason: "external_client_not_configured",
          detail: "python executable was not found on PATH"
        )

      python ->
        python_code =
          "import importlib.util, sys; " <>
            "sys.exit(0 if importlib.util.find_spec('boto3') else 2)"

        case command_runner.(python, ["-c", python_code], stderr_to_stdout: true) do
          {_output, 0} ->
            %{
              "id" => "python_boto3",
              "label" => "python-boto3",
              "status" => "ok",
              "path" => python,
              "detail" => "boto3 module found",
              "warnings" => [],
              "blockers" => []
            }

          {output, exit_status} ->
            external_attention("python_boto3", "python-boto3",
              executable: python,
              reason: "external_client_not_configured",
              detail: "boto3 module probe exited #{exit_status}: #{compact_output(output)}"
            )
        end
    end
  rescue
    error ->
      external_attention("python_boto3", "python-boto3",
        executable: "python",
        reason: "external_client_probe_failed",
        detail: Exception.message(error)
      )
  end

  defp external_attention(id, label, opts) do
    reason = Keyword.fetch!(opts, :reason)
    executable = Keyword.get(opts, :executable)
    detail = Keyword.get(opts, :detail)

    %{
      "id" => id,
      "label" => label,
      "status" => "attention",
      "path" => nil,
      "detail" => detail,
      "warnings" => [
        %{
          "reason" => reason,
          "client" => id,
          "executable" => executable,
          "detail" => detail
        }
      ],
      "blockers" => []
    }
  end

  defp python_executable(executable_finder) do
    Enum.find_value(["python", "python3", "py"], executable_finder)
  end

  defp normalize_external_client(client) do
    client = stringify_keys(client)
    {status, status_blockers} = normalize_status(client["status"])
    id = to_string(client["id"] || client["client"] || "external_client")
    label = to_string(client["label"] || id)

    warnings =
      client
      |> Map.get("warnings", [])
      |> normalize_items("external_client_attention")

    blockers =
      client
      |> Map.get("blockers", [])
      |> normalize_items("external_client_blocked")
      |> Kernel.++(status_blockers)

    blockers =
      if status in ["blocked", "error"] and blockers == [] do
        [%{"reason" => "external_client_#{status}"}]
      else
        blockers
      end

    warnings =
      if status == "attention" and warnings == [] do
        [%{"reason" => "external_client_attention"}]
      else
        warnings
      end

    base = %{
      "kind" => "external_client",
      "id" => id,
      "label" => label,
      "mode" => "external_availability",
      "status" => status,
      "path" => client["path"],
      "detail" => client["detail"],
      "blockers" => blockers,
      "warnings" => warnings
    }

    Map.merge(client, base)
  end

  defp normalize_external_smoke(entry) do
    entry = stringify_keys(entry)
    {status, status_blockers} = normalize_smoke_status(entry["status"])
    id = to_string(entry["id"] || "external_smoke")
    label = to_string(entry["label"] || id)

    warnings =
      entry
      |> Map.get("warnings", [])
      |> normalize_items("external_smoke_attention")

    blockers =
      entry
      |> Map.get("blockers", [])
      |> normalize_items("external_smoke_blocked")
      |> Kernel.++(status_blockers)

    blockers =
      if status in ["blocked", "error"] and blockers == [] do
        [%{"reason" => "external_smoke_#{status}"}]
      else
        blockers
      end

    warnings =
      if status == "attention" and warnings == [] do
        [%{"reason" => "external_smoke_attention"}]
      else
        warnings
      end

    base = %{
      "kind" => "external_smoke",
      "id" => id,
      "label" => label,
      "mode" => "external_smoke",
      "status" => status,
      "duration_ms" => entry["duration_ms"],
      "steps" => Map.get(entry, "steps", []),
      "blockers" => blockers,
      "warnings" => warnings
    }

    Map.merge(entry, base)
  end

  defp normalize_status("ok"), do: {"ok", []}
  defp normalize_status("attention"), do: {"attention", []}
  defp normalize_status("blocked"), do: {"blocked", []}
  defp normalize_status("error"), do: {"error", []}

  defp normalize_status(other) do
    {"error",
     [
       %{
         "reason" => "external_client_status_invalid",
         "status" => json_ready(other)
       }
     ]}
  end

  defp normalize_smoke_status("ok"), do: {"ok", []}
  defp normalize_smoke_status("attention"), do: {"attention", []}
  defp normalize_smoke_status("blocked"), do: {"blocked", []}
  defp normalize_smoke_status("error"), do: {"error", []}

  defp normalize_smoke_status(other) do
    {"error",
     [
       %{
         "reason" => "external_smoke_status_invalid",
         "status" => json_ready(other)
       }
     ]}
  end

  defp normalize_items([], _fallback), do: []

  defp normalize_items(nil, _fallback), do: []

  defp normalize_items(items, fallback) when is_list(items) do
    Enum.map(items, &normalize_item(&1, fallback))
  end

  defp normalize_items(item, fallback), do: [normalize_item(item, fallback)]

  defp normalize_item(%{} = item, _fallback) do
    Map.new(item, fn {key, value} -> {to_string(key), json_ready(value)} end)
  end

  defp normalize_item(value, _fallback) when is_binary(value), do: %{"reason" => value}
  defp normalize_item(value, fallback), do: %{"reason" => fallback, "detail" => inspect(value)}

  defp overall_status(entries) do
    cond do
      Enum.any?(entries, &(&1["status"] == "error")) -> "error"
      Enum.any?(entries, &(&1["status"] == "blocked")) -> "blocked"
      Enum.any?(entries, &(&1["status"] == "attention")) -> "attention"
      true -> "ok"
    end
  end

  defp gate_items(entries, key) do
    entries
    |> Enum.flat_map(fn entry ->
      entry
      |> Map.get(key, [])
      |> Enum.map(fn item ->
        %{
          "entry" => entry["id"],
          "kind" => entry["kind"],
          "label" => entry["name"] || entry["label"],
          "reason" => item_reason(item),
          "detail" => item
        }
      end)
    end)
  end

  defp item_reason(%{"reason" => reason}), do: to_string(reason)
  defp item_reason(%{reason: reason}), do: to_string(reason)
  defp item_reason(item), do: inspect(item)

  defp counts(entries) do
    %{
      "total" => length(entries),
      "ok" => Enum.count(entries, &(&1["status"] == "ok")),
      "attention" => Enum.count(entries, &(&1["status"] == "attention")),
      "blocked" => Enum.count(entries, &(&1["status"] == "blocked")),
      "error" => Enum.count(entries, &(&1["status"] == "error"))
    }
  end

  defp stdout(artifact, %{json?: true}), do: Jason.encode!(artifact) <> "\n"

  defp stdout(artifact, _config) do
    summary =
      "[maxio compat.matrix] gate_status=#{artifact["gate_status"]} " <>
        "entries=#{artifact["counts"]["total"]} ok=#{artifact["counts"]["ok"]} " <>
        "attention=#{artifact["counts"]["attention"]} " <>
        "blocked=#{artifact["counts"]["blocked"]} error=#{artifact["counts"]["error"]} " <>
        "artifact=#{artifact["artifact_path"]}\n"

    suite_lines =
      artifact["suites"]
      |> Enum.map(fn suite ->
        "[maxio compat.matrix.suite] id=#{suite["id"]} status=#{suite["status"]} " <>
          "exit_status=#{format_value(suite["exit_status"])} " <>
          "tests=#{format_value(suite["exunit"]["tests"])} " <>
          "failures=#{format_value(suite["exunit"]["failures"])} " <>
          "duration_ms=#{suite["duration_ms"]} command=#{inspect(suite["mix_command"])}\n"
      end)
      |> Enum.join()

    external_lines =
      artifact["external_clients"]
      |> Enum.map(fn client ->
        "[maxio compat.matrix.external] id=#{client["id"]} status=#{client["status"]} " <>
          "path=#{inspect(client["path"])} detail=#{inspect(client["detail"])}\n"
      end)
      |> Enum.join()

    smoke_lines =
      artifact["external_smoke"]
      |> Enum.map(fn smoke ->
        "[maxio compat.matrix.smoke] id=#{smoke["id"]} status=#{smoke["status"]} " <>
          "bucket=#{inspect(smoke["bucket"])} steps=#{length(smoke["steps"] || [])} " <>
          "scenarios=#{inspect(smoke["scenario_counts"] || %{})} " <>
          "duration_ms=#{format_value(smoke["duration_ms"])}\n"
      end)
      |> Enum.join()

    blocker_lines = Enum.map_join(artifact["blockers"], "", &gate_line("blocker", &1))
    warning_lines = Enum.map_join(artifact["warnings"], "", &gate_line("warning", &1))

    summary <> suite_lines <> external_lines <> smoke_lines <> blocker_lines <> warning_lines
  end

  defp gate_line(kind, item) do
    "[maxio compat.matrix.#{kind}] entry=#{item["entry"]} kind=#{item["kind"]} " <>
      "reason=#{item["reason"]}\n"
  end

  defp stderr(0, _gate_status), do: nil
  defp stderr(_exit_code, gate_status), do: "[maxio compat.matrix] gate failed: #{gate_status}\n"

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
      "default_suites" => Enum.map(@default_suites, & &1.id),
      "optional_suites" => Enum.map(@optional_suites, & &1.id),
      "requested_suites" => config.requested_suites,
      "skip_external_probes" => config.skip_external_probes?,
      "no_internal_suites" => config.no_internal_suites?,
      "include_external_smoke" => config.include_external_smoke?,
      "external_smoke" => smoke_config_view(config.external_smoke_config),
      "fail_on_blocked" => config.fail_on_blocked?,
      "fail_on_attention" => config.fail_on_attention?,
      "strict" => config.strict?
    }
  end

  defp smoke_config_view(config) do
    %{
      "clients" => config.clients,
      "endpoint" => config.endpoint,
      "region" => config.region,
      "access_key_configured" => configured?(config.access_key),
      "secret_key_configured" => configured?(config.secret_key)
    }
  end

  defp validate_suites([]), do: :ok

  defp validate_suites(requested_suites) do
    valid = Enum.map(@all_suites, & &1.id)
    invalid = Enum.reject(requested_suites, &(&1 in valid))

    if invalid == [] do
      :ok
    else
      {:error, "--suite must be one of #{Enum.join(valid, ", ")}, got #{inspect(invalid)}"}
    end
  end

  defp validate_smoke_clients([]), do: :ok

  defp validate_smoke_clients(requested_clients) do
    valid = ExternalSmoke.client_ids()
    invalid = Enum.reject(requested_clients, &(&1 in valid))

    if invalid == [] do
      :ok
    else
      {:error,
       "--external-smoke-client must be one of #{Enum.join(valid, ", ")}, got #{inspect(invalid)}"}
    end
  end

  defp external_smoke_config(opts, requested_clients) do
    %{
      endpoint:
        option_env_or_config(
          Keyword.get(opts, :external_endpoint),
          ["MAXIO_COMPAT_ENDPOINT"],
          &configured_s3_endpoint/0
        ),
      access_key:
        option_env_or_config(
          Keyword.get(opts, :external_access_key),
          ["MAXIO_COMPAT_ACCESS_KEY", "AWS_ACCESS_KEY_ID"],
          &configured_root_user/0
        ),
      secret_key:
        option_env_or_config(
          Keyword.get(opts, :external_secret_key),
          ["MAXIO_COMPAT_SECRET_KEY", "AWS_SECRET_ACCESS_KEY"],
          &configured_root_password/0
        ),
      region:
        option_env_or_config(
          Keyword.get(opts, :external_region),
          ["MAXIO_COMPAT_REGION", "AWS_REGION", "AWS_DEFAULT_REGION"],
          fn -> configured_s3_region() || "us-east-1" end
        ),
      clients:
        if(requested_clients == [], do: ExternalSmoke.client_ids(), else: requested_clients)
    }
  end

  defp option_env_or_config(option, env_names, config_fun) do
    option
    |> blank_to_nil()
    |> case do
      nil ->
        env_names
        |> Enum.find_value(fn env_name -> System.get_env(env_name) |> blank_to_nil() end)
        |> case do
          nil -> config_fun.() |> blank_to_nil()
          value -> value
        end

      value ->
        value
    end
  end

  defp configured_s3_endpoint do
    config = Application.get_env(:maxio, Maxio.S3.Endpoint, [])
    port = Keyword.get(config, :port)

    if is_integer(port) and port > 0 do
      "http://#{configured_s3_host(Keyword.get(config, :ip, {127, 0, 0, 1}))}:#{port}"
    end
  end

  defp configured_s3_host(:any), do: "127.0.0.1"
  defp configured_s3_host({a, b, c, d}), do: Enum.join([a, b, c, d], ".")
  defp configured_s3_host(host) when is_binary(host), do: host
  defp configured_s3_host(_host), do: "127.0.0.1"

  defp configured_root_user do
    :maxio
    |> Application.get_env(:s3, [])
    |> Keyword.get(:root_user)
  end

  defp configured_root_password do
    :maxio
    |> Application.get_env(:s3, [])
    |> Keyword.get(:root_password)
  end

  defp configured_s3_region do
    :maxio
    |> Application.get_env(:s3, [])
    |> Keyword.get(:region)
  end

  defp parse_exunit_counts(output) when is_binary(output) do
    %{
      "tests" => regex_int(~r/(\d+)\s+tests?/, output),
      "failures" => regex_int(~r/(\d+)\s+failures?/, output),
      "excluded" => regex_int(~r/(\d+)\s+excluded/, output)
    }
  end

  defp parse_exunit_counts(_output) do
    %{"tests" => nil, "failures" => nil, "excluded" => nil}
  end

  defp regex_int(regex, value) do
    case Regex.run(regex, value) do
      [_, number] -> String.to_integer(number)
      _other -> nil
    end
  end

  defp output_snippet(output) when is_binary(output) do
    output
    |> String.trim()
    |> String.slice(0, 4_000)
  end

  defp output_snippet(output), do: inspect(output)

  defp compact_output(output) when is_binary(output) do
    output
    |> String.trim()
    |> String.split("\n")
    |> List.first()
    |> case do
      nil -> ""
      line -> String.slice(line, 0, 300)
    end
  end

  defp compact_output(output), do: output |> inspect() |> String.slice(0, 300)

  defp write_artifact!(path, artifact) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode!(artifact) <> "\n")
  end

  defp usage_result(message) do
    %{
      exit_code: 64,
      stderr: "[maxio compat.matrix] #{message}\n\n" <> @usage
    }
  end

  defp default_artifact_path(run_id), do: Path.join("artifacts", "#{run_id}.json")

  defp parent_command(config) do
    [config.mix_cmd, "maxio.compat.matrix" | config.argv]
    |> command_string()
    |> redact_sensitive(config.external_smoke_config)
  end

  defp run_id(%DateTime{} = generated_at) do
    stamp =
      generated_at
      |> DateTime.to_iso8601()
      |> String.replace(~r/[^0-9A-Za-z_.-]/, "_")

    "s3_compat_matrix_#{stamp}_#{System.unique_integer([:positive])}"
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

  defp redact_sensitive(value, config) do
    config
    |> sensitive_values()
    |> Enum.reduce(value, fn sensitive, acc -> String.replace(acc, sensitive, "[REDACTED]") end)
  end

  defp sensitive_values(config) do
    [config && config.access_key, config && config.secret_key]
    |> Enum.flat_map(fn value ->
      case blank_to_nil(value) do
        nil -> []
        value -> [value, URI.encode_www_form(value)]
      end
    end)
    |> Enum.uniq()
  end

  defp quote_arg(part) do
    part = to_string(part)

    if String.match?(part, ~r/^[A-Za-z0-9_@.,:\/\\=-]+$/) do
      part
    else
      inspect(part)
    end
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), json_ready(value)} end)
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

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp configured?(value), do: not is_nil(blank_to_nil(value))
end
