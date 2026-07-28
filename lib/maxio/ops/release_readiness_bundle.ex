defmodule Maxio.Ops.ReleaseReadinessBundle do
  @moduledoc """
  Read-only release readiness evidence bundle.

  This bundle does not prove production release readiness by itself. It gathers
  existing machine-readable artifacts and local environment evidence into one
  JSON artifact, making missing, stale, docs-only, or unavailable evidence
  explicit for operators.
  """

  alias Maxio.Compat.Matrix
  alias Maxio.Ops.CompatMatrix.Artifacts, as: CompatArtifacts
  alias Maxio.Ops.Gate.Artifacts, as: GateArtifacts
  alias Maxio.Ops.RehearsalBundle.Artifacts, as: RehearsalArtifacts

  @default_max_age_hours 168
  @default_artifacts_dir "artifacts"
  @default_max_bytes 2_000_000
  @default_limit 20
  @status_files ["docs/superpowers/STATUS.md", "docs/superpowers/TODO.md"]

  @usage """
  Usage:
    mix maxio.release.readiness [--json] [--artifact PATH] [--artifacts-dir DIR]
      [--max-age-hours HOURS] [--skip-external-probes]
      [--require-external-clients] [--require-clean-worktree]
      [--fail-on-blocked] [--fail-on-attention] [--strict]

  The task is read-only except for writing the release readiness JSON artifact.
  It does not start Maxio, does not run external smoke tests, does not mutate
  ops state, and does not run `mix precommit`.
  """

  def usage, do: @usage

  def run(argv, opts \\ []) do
    case normalize(argv) do
      {:ok, config} -> run_bundle(config, opts)
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
          artifacts_dir: :string,
          max_age_hours: :integer,
          skip_external_probes: :boolean,
          require_external_clients: :boolean,
          require_clean_worktree: :boolean,
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
        max_age_hours =
          opts
          |> Keyword.get(:max_age_hours, @default_max_age_hours)
          |> positive_int(@default_max_age_hours)

        {:ok,
         %{
           argv: argv,
           artifact_path: Keyword.get(opts, :artifact),
           artifacts_dir: Keyword.get(opts, :artifacts_dir, @default_artifacts_dir),
           max_age_hours: max_age_hours,
           skip_external_probes?: Keyword.get(opts, :skip_external_probes, false),
           require_external_clients?: Keyword.get(opts, :require_external_clients, false),
           require_clean_worktree?: Keyword.get(opts, :require_clean_worktree, false),
           fail_on_blocked?: Keyword.get(opts, :fail_on_blocked, false),
           fail_on_attention?:
             Keyword.get(opts, :fail_on_attention, false) or Keyword.get(opts, :strict, false),
           strict?: Keyword.get(opts, :strict, false),
           json?: Keyword.get(opts, :json, false)
         }}
    end
  end

  defp run_bundle(config, opts) do
    now_fun = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)
    generated_at = now_fun.()
    run_id = run_id(generated_at)
    artifact_path = config.artifact_path || default_artifact_path(run_id)
    artifact_writer = Keyword.get(opts, :artifact_writer, &write_artifact!/2)
    git_sha_fun = Keyword.get(opts, :git_sha_fun, &git_sha/0)

    stress_artifacts = stress_artifacts(config, opts)
    latest_stress = List.first(stress_artifacts)

    checks = [
      stress_campaign_check(latest_stress, generated_at, config),
      compat_matrix_check(latest_stress, config, opts, generated_at),
      ops_gate_check(config, opts, generated_at),
      rehearsal_bundle_check(config, opts, generated_at),
      external_clients_check(config, opts),
      worktree_check(config, opts),
      precommit_evidence_check(opts)
    ]

    gate_status = overall_status(checks)
    blockers = gate_items(checks, "blockers")
    warnings = gate_items(checks, "warnings")

    artifact = %{
      "schema_version" => 1,
      "evidence_kind" => "release_readiness_bundle",
      "scenario" => "local_release_readiness_evidence",
      "generated_at" => DateTime.to_iso8601(generated_at),
      "run_id" => run_id,
      "git_sha" => git_sha_fun.(),
      "node" => Atom.to_string(Node.self()),
      "mix_env" => mix_env(),
      "command" => command_string(["mix", "maxio.release.readiness" | config.argv]),
      "artifact_path" => artifact_path,
      "profile" => "local_release_readiness",
      "config" => %{
        "artifacts_dir" => config.artifacts_dir,
        "max_age_hours" => config.max_age_hours,
        "skip_external_probes" => config.skip_external_probes?,
        "require_external_clients" => config.require_external_clients?,
        "require_clean_worktree" => config.require_clean_worktree?,
        "fail_on_blocked" => config.fail_on_blocked?,
        "fail_on_attention" => config.fail_on_attention?,
        "strict" => config.strict?
      },
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

  defp stress_artifacts(config, opts) do
    stress_artifacts_fun = Keyword.get(opts, :stress_artifacts_fun, &list_stress_artifacts/1)

    stress_artifacts_fun.(
      dir: config.artifacts_dir,
      limit: @default_limit,
      max_bytes: @default_max_bytes
    )
  rescue
    error ->
      [
        invalid_artifact("stress_campaign_probe_error", "reader_crashed",
          message: Exception.message(error)
        )
      ]
  end

  defp stress_campaign_check(nil, _now, _config) do
    check("stress_campaign", "Stress/fault campaign artifact", "attention",
      source: "artifacts",
      warnings: [
        %{
          "reason" => "missing_stress_campaign_artifact",
          "detail" => "Run mix maxio.stress.campaign before release readiness closure."
        }
      ]
    )
  end

  defp stress_campaign_check(artifact, now, config) do
    artifact_gate_check(
      "stress_campaign",
      "Stress/fault campaign artifact",
      artifact,
      now,
      config,
      source: "stress_campaign"
    )
  end

  defp compat_matrix_check(latest_stress, config, opts, now) do
    compat_artifacts_fun =
      Keyword.get(opts, :compat_artifacts_fun, &CompatArtifacts.list_recent/1)

    artifact =
      compat_artifacts_fun.(dir: config.artifacts_dir, limit: @default_limit)
      |> List.first()

    cond do
      not is_nil(artifact) ->
        artifact_gate_check(
          "compat_matrix",
          "S3 compatibility matrix artifact",
          artifact,
          now,
          config,
          source: "compat_matrix"
        )

      matrix = embedded_matrix(latest_stress) ->
        artifact_gate_check(
          "compat_matrix",
          "S3 compatibility matrix artifact",
          matrix,
          now,
          config,
          source: "embedded_stress_campaign_matrix",
          warnings: [
            %{
              "reason" => "compat_matrix_embedded_only",
              "detail" => "Using matrix evidence embedded inside the stress campaign artifact."
            }
          ]
        )

      true ->
        check("compat_matrix", "S3 compatibility matrix artifact", "attention",
          source: "artifacts",
          warnings: [
            %{
              "reason" => "missing_compat_matrix_artifact",
              "detail" =>
                "Run mix maxio.compat.matrix or keep a stress campaign with embedded matrix."
            }
          ]
        )
    end
  rescue
    error ->
      check("compat_matrix", "S3 compatibility matrix artifact", "blocked",
        source: "compat_matrix_reader",
        blockers: [%{"reason" => "reader_crashed", "detail" => Exception.message(error)}]
      )
  end

  defp ops_gate_check(config, opts, now) do
    gate_artifacts_fun = Keyword.get(opts, :gate_artifacts_fun, &GateArtifacts.list_recent/1)

    gate_artifacts_fun.(dir: config.artifacts_dir, limit: @default_limit)
    |> List.first()
    |> case do
      nil ->
        check("ops_gate", "Ops gate artifact", "attention",
          source: "artifacts",
          warnings: [
            %{
              "reason" => "missing_ops_gate_artifact",
              "detail" => "No m8_ops_gate artifact was found for this release bundle."
            }
          ]
        )

      artifact ->
        artifact_gate_check("ops_gate", "Ops gate artifact", artifact, now, config,
          source: "ops_gate"
        )
    end
  rescue
    error ->
      check("ops_gate", "Ops gate artifact", "blocked",
        source: "ops_gate_reader",
        blockers: [%{"reason" => "reader_crashed", "detail" => Exception.message(error)}]
      )
  end

  defp rehearsal_bundle_check(config, opts, now) do
    rehearsal_bundles_fun =
      Keyword.get(opts, :rehearsal_bundles_fun, &RehearsalArtifacts.list_recent/1)

    rehearsal_bundles_fun.(dir: config.artifacts_dir, limit: @default_limit)
    |> List.first()
    |> case do
      nil ->
        check("rehearsal_bundle", "P0 live rehearsal bundle", "attention",
          source: "artifacts",
          warnings: [
            %{
              "reason" => "missing_rehearsal_bundle_artifact",
              "detail" =>
                "No P0 live rehearsal bundle artifact was found for this release bundle."
            }
          ]
        )

      artifact ->
        artifact_gate_check(
          "rehearsal_bundle",
          "P0 live rehearsal bundle",
          artifact,
          now,
          config,
          source: "p0_live_rehearsal_bundle"
        )
    end
  rescue
    error ->
      check("rehearsal_bundle", "P0 live rehearsal bundle", "blocked",
        source: "rehearsal_bundle_reader",
        blockers: [%{"reason" => "reader_crashed", "detail" => Exception.message(error)}]
      )
  end

  defp external_clients_check(
         %{skip_external_probes?: true, require_external_clients?: true},
         _opts
       ) do
    check("external_clients", "External client availability", "blocked",
      source: "local_probe",
      blockers: [
        %{
          "reason" => "external_clients_required_but_probe_skipped",
          "detail" => "`--require-external-clients` cannot be satisfied with skipped probes."
        }
      ]
    )
  end

  defp external_clients_check(%{skip_external_probes?: true}, _opts) do
    check("external_clients", "External client availability", "attention",
      source: "local_probe",
      warnings: [%{"reason" => "external_client_probe_skipped"}]
    )
  end

  defp external_clients_check(config, opts) do
    external_probe_fun = Keyword.get(opts, :external_probe_fun, &run_external_probe/0)
    result = external_probe_fun.()
    artifact = result_artifact(result)
    gate_status = status_value(artifact["gate_status"])

    {status, blockers, warnings} =
      if config.require_external_clients? and gate_status != "ok" do
        {"blocked",
         [
           %{
             "reason" => "external_clients_required_not_ready",
             "detail" => artifact["warnings"] || []
           }
         ], []}
      else
        {gate_to_check_status(gate_status), artifact["blockers"] || [],
         artifact["warnings"] || []}
      end

    check("external_clients", "External client availability", status,
      source: "compat_matrix_probe",
      detail: external_clients_detail(artifact, gate_status),
      blockers: sanitize_external_items(blockers),
      warnings: sanitize_external_items(warnings)
    )
  rescue
    error ->
      check("external_clients", "External client availability", "blocked",
        source: "compat_matrix_probe",
        blockers: [%{"reason" => "external_probe_failed", "detail" => Exception.message(error)}]
      )
  end

  defp external_clients_detail(artifact, gate_status) do
    %{
      "gate_status" => gate_status,
      "clients" => summarize_external_clients(artifact["external_clients"])
    }
  end

  defp summarize_external_clients(clients) when is_list(clients) do
    Enum.map(clients, &summarize_external_client/1)
  end

  defp summarize_external_clients(_clients), do: []

  defp summarize_external_client(%{} = client) do
    client = Map.new(client, fn {key, value} -> {to_string(key), value} end)
    id = summary_string(client["id"] || client["client"] || "external_client")

    %{
      "kind" => summary_string(client["kind"] || "external_client"),
      "id" => id,
      "label" => summary_string(client["label"] || id),
      "mode" => summary_string(client["mode"]),
      "status" => status_value(client["status"]),
      "executable" => external_client_executable(client),
      "detail" => redact_local_paths(summary_string(client["detail"])),
      "blockers" => sanitize_external_items(client["blockers"] || []),
      "warnings" => sanitize_external_items(client["warnings"] || [])
    }
  end

  defp summarize_external_client(_client) do
    %{
      "kind" => "external_client",
      "id" => "invalid_external_client",
      "label" => "invalid_external_client",
      "mode" => nil,
      "status" => "blocked",
      "executable" => nil,
      "detail" => nil,
      "blockers" => [%{"reason" => "invalid_external_client_entry"}],
      "warnings" => []
    }
  end

  defp executable_basename(nil), do: nil

  defp executable_basename(value) do
    if present_external_value?(value) do
      value
      |> to_string()
      |> String.replace("\\", "/")
      |> Path.basename()
      |> redact_local_paths()
    end
  end

  defp external_client_executable(client) do
    [
      client["path"],
      client["executable"],
      executable_from_items(client["warnings"]),
      executable_from_items(client["blockers"])
    ]
    |> Enum.find(&present_external_value?/1)
    |> executable_basename()
  end

  defp executable_from_items(items) do
    items
    |> List.wrap()
    |> Enum.find_value(fn
      %{} = item ->
        item = Map.new(item, fn {key, value} -> {to_string(key), value} end)
        item["executable"] || item["path"]

      _other ->
        nil
    end)
  end

  defp present_external_value?(nil), do: false

  defp present_external_value?(value) do
    value =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()

    value not in ["", "nil", "null", "-"]
  end

  defp sanitize_external_items(items) do
    items
    |> normalize_items()
    |> Enum.map(&sanitize_external_value/1)
  end

  defp sanitize_external_value(%{} = value) do
    Map.new(value, fn
      {key, _item} when key in ["path", :path] ->
        {to_string(key), nil}

      {key, item} when key in ["executable", :executable] ->
        {to_string(key), executable_basename(item)}

      {key, item} ->
        {to_string(key), sanitize_external_value(item)}
    end)
  end

  defp sanitize_external_value(values) when is_list(values) do
    Enum.map(values, &sanitize_external_value/1)
  end

  defp sanitize_external_value(value) when is_binary(value), do: redact_local_paths(value)
  defp sanitize_external_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize_external_value(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_external_value(value), do: value

  defp summary_string(nil), do: nil
  defp summary_string(value) when is_binary(value), do: redact_local_paths(value)
  defp summary_string(value) when is_atom(value), do: Atom.to_string(value)
  defp summary_string(value), do: value |> inspect() |> redact_local_paths()

  defp redact_local_paths(nil), do: nil

  defp redact_local_paths(value) when is_binary(value) do
    Regex.replace(~r/[A-Za-z]:[\/\\][^,;\]\}\)"]+/, value, "[LOCAL_PATH]")
  end

  defp run_external_probe do
    case Matrix.run(["--no-internal-suites"],
           artifact_writer: fn _path, _artifact -> :ok end
         ) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp worktree_check(config, opts) do
    git_status_fun = Keyword.get(opts, :git_status_fun, &git_status_short/0)

    case git_status_fun.() do
      {:ok, output} ->
        all_lines = String.split(output, "\n", trim: true)
        sample = Enum.take(all_lines, 80)
        changed_count = length(all_lines)

        if all_lines == [] do
          check("worktree", "Git worktree state", "ok",
            source: "git_status",
            detail: %{"changed_count" => 0, "sample" => []}
          )
        else
          status = if config.require_clean_worktree?, do: "blocked", else: "attention"

          item = %{
            "reason" => "worktree_dirty",
            "changed_count" => changed_count
          }

          items =
            if status == "blocked" do
              [blockers: [item]]
            else
              [warnings: [item]]
            end

          check("worktree", "Git worktree state", status,
            source: "git_status",
            detail: %{"changed_count" => changed_count, "sample" => sample}
          )
          |> Map.merge(%{
            "blockers" => normalize_items(Keyword.get(items, :blockers, [])),
            "warnings" => normalize_items(Keyword.get(items, :warnings, []))
          })
        end

      {:error, reason} ->
        check("worktree", "Git worktree state", "blocked",
          source: "git_status",
          blockers: [%{"reason" => "git_status_failed", "detail" => inspect(reason)}]
        )
    end
  end

  defp precommit_evidence_check(opts) do
    status_files_fun = Keyword.get(opts, :status_files_fun, &read_status_files/0)

    case latest_precommit(status_files_fun.()) do
      nil ->
        check("precommit_evidence", "Latest precommit evidence", "blocked",
          source: "status_docs",
          blockers: [%{"reason" => "missing_precommit_evidence"}]
        )

      evidence ->
        check("precommit_evidence", "Latest precommit evidence", "attention",
          source: "status_docs",
          detail: evidence,
          warnings: [
            %{
              "reason" => "docs_only_precommit_evidence",
              "detail" =>
                "Precommit evidence was read from STATUS/TODO text, not rerun by this bundle."
            }
          ]
        )
    end
  rescue
    error ->
      check("precommit_evidence", "Latest precommit evidence", "blocked",
        source: "status_docs",
        blockers: [%{"reason" => "status_docs_read_failed", "detail" => Exception.message(error)}]
      )
  end

  defp artifact_gate_check(id, label, artifact, now, config, opts) do
    base_status = artifact_status(artifact)
    recency = recency_status(artifact, now, config.max_age_hours)
    extra_warnings = Keyword.get(opts, :warnings, [])
    extra_blockers = Keyword.get(opts, :blockers, [])
    extra_status = if extra_warnings == [] and extra_blockers == [], do: "ok", else: "attention"

    status =
      [base_status.status, recency.status, extra_status]
      |> Enum.reject(&(&1 == "ok"))
      |> overall_status_from_statuses()

    detail =
      artifact
      |> artifact_detail()
      |> Map.put("source", Keyword.fetch!(opts, :source))

    blockers =
      normalize_items(base_status.blockers ++ recency.blockers ++ extra_blockers)

    warnings =
      normalize_items(base_status.warnings ++ recency.warnings ++ extra_warnings)

    check(id, label, status,
      source: Keyword.fetch!(opts, :source),
      detail: detail,
      blockers: blockers,
      warnings: warnings
    )
  end

  defp artifact_status(artifact) do
    if field(artifact, :status) == "invalid" do
      %{
        status: "blocked",
        blockers: [
          %{
            "reason" => field(artifact, :error_reason) || "invalid_artifact",
            "file_name" => field(artifact, :file_name)
          }
        ],
        warnings: []
      }
    else
      artifact_gate_status(artifact)
    end
  end

  defp artifact_gate_status(artifact) do
    gate_status = status_value(field(artifact, :gate_status) || field(artifact, "gate_status"))

    case gate_status do
      "ok" ->
        %{status: "ok", blockers: [], warnings: []}

      "attention" ->
        %{status: "attention", blockers: [], warnings: artifact_items(artifact, :warnings)}

      status when status in ["blocked", "error", "invalid", "unknown"] ->
        %{
          status: "blocked",
          blockers:
            artifact_items(artifact, :blockers) ++
              [%{"reason" => "artifact_gate_status_#{status}"}],
          warnings: artifact_items(artifact, :warnings)
        }
    end
  end

  defp recency_status(artifact, now, max_age_hours) do
    generated_at = field(artifact, :generated_at) || field(artifact, "generated_at")

    case parse_datetime(generated_at) do
      {:ok, datetime} ->
        cond do
          DateTime.compare(datetime, DateTime.add(now, 5, :second)) == :gt ->
            %{
              status: "blocked",
              blockers: [%{"reason" => "future_generated_at", "generated_at" => generated_at}],
              warnings: []
            }

          DateTime.diff(now, datetime, :hour) > max_age_hours ->
            %{
              status: "attention",
              blockers: [],
              warnings: [
                %{
                  "reason" => "stale_artifact",
                  "generated_at" => generated_at,
                  "max_age_hours" => max_age_hours
                }
              ]
            }

          true ->
            %{status: "ok", blockers: [], warnings: []}
        end

      :missing ->
        %{
          status: "blocked",
          blockers: [%{"reason" => "missing_generated_at"}],
          warnings: []
        }

      :invalid ->
        %{
          status: "blocked",
          blockers: [%{"reason" => "invalid_generated_at", "generated_at" => generated_at}],
          warnings: []
        }
    end
  end

  defp embedded_matrix(nil), do: nil

  defp embedded_matrix(stress_artifact) do
    raw = field(stress_artifact, :raw) || field(stress_artifact, "raw") || %{}

    case raw["matrix"] do
      %{} = matrix ->
        %{
          status: "ok",
          file_name: "#{field(stress_artifact, :file_name) || "stress_campaign"}#matrix",
          generated_at: matrix["generated_at"],
          gate_status: matrix["gate_status"],
          run_id: matrix["run_id"],
          git_sha: matrix["git_sha"],
          counts: matrix["counts"],
          blockers: matrix["blockers"] || [],
          warnings: matrix["warnings"] || [],
          raw: matrix
        }

      _other ->
        nil
    end
  end

  defp list_stress_artifacts(opts) do
    dir = opts |> Keyword.get(:dir, @default_artifacts_dir) |> Path.expand()
    limit = positive_int(Keyword.get(opts, :limit), @default_limit)
    max_bytes = positive_int(Keyword.get(opts, :max_bytes), @default_max_bytes)

    with {:ok, names} <- File.ls(dir) do
      names
      |> Enum.filter(&safe_candidate_name?/1)
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.sort(:desc)
      |> Enum.flat_map(&read_stress_candidate(dir, &1, max_bytes))
      |> Enum.sort_by(&(&1.sort_unix || 0), :desc)
      |> Enum.take(limit)
    else
      _error -> []
    end
  end

  defp read_stress_candidate(dir, name, max_bytes) do
    path = Path.join(dir, name)
    expanded = Path.expand(path)

    with true <- Path.dirname(expanded) == dir,
         {:ok, stat} <- File.lstat(expanded, time: :posix),
         true <- stat.type == :regular do
      cond do
        stat.size > max_bytes ->
          [invalid_artifact(name, "artifact_too_large", modified_at_unix: stat.mtime)]

        true ->
          decode_stress_artifact(expanded, name, stat)
      end
    else
      _other -> []
    end
  end

  defp decode_stress_artifact(path, name, stat) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         true <- decoded["evidence_kind"] == "stress_campaign" do
      [
        %{
          status: "ok",
          file_name: name,
          size_bytes: stat.size,
          modified_at: posix_to_iso8601(stat.mtime),
          modified_at_unix: stat.mtime,
          sort_unix: generated_at_unix(decoded["generated_at"]) || stat.mtime,
          generated_at: decoded["generated_at"],
          run_id: decoded["run_id"],
          git_sha: decoded["git_sha"],
          gate_status: decoded["gate_status"],
          counts: decoded["counts"],
          blockers: decoded["blockers"] || [],
          warnings: decoded["warnings"] || [],
          raw: decoded
        }
      ]
    else
      {:error, %Jason.DecodeError{}} ->
        [invalid_artifact(name, "json_unparseable", modified_at_unix: stat.mtime)]

      {:error, reason} ->
        [
          invalid_artifact(name, "read_error",
            modified_at_unix: stat.mtime,
            detail: inspect(reason)
          )
        ]

      false ->
        []

      _other ->
        [invalid_artifact(name, "invalid_artifact", modified_at_unix: stat.mtime)]
    end
  rescue
    error ->
      [
        invalid_artifact(name, "read_error",
          modified_at_unix: stat.mtime,
          detail: Exception.message(error)
        )
      ]
  end

  defp invalid_artifact(file_name, reason, extra) do
    %{
      status: "invalid",
      file_name: file_name,
      error_reason: reason,
      gate_status: "invalid",
      generated_at: nil,
      run_id: nil,
      git_sha: nil,
      counts: nil,
      blockers: [%{"reason" => reason}],
      warnings: [],
      sort_unix: Keyword.get(extra, :modified_at_unix, 0),
      detail: Keyword.get(extra, :detail)
    }
  end

  defp artifact_detail(artifact) do
    %{
      "file_name" => field(artifact, :file_name),
      "generated_at" => field(artifact, :generated_at),
      "run_id" => field(artifact, :run_id),
      "git_sha" => field(artifact, :git_sha),
      "gate_status" => field(artifact, :gate_status),
      "counts" => sanitize_value(field(artifact, :counts))
    }
  end

  defp artifact_items(artifact, key) do
    artifact
    |> field(key)
    |> normalize_items()
  end

  defp check(id, label, status, opts) do
    %{
      "id" => id,
      "label" => label,
      "kind" => "release_readiness_check",
      "source" => Keyword.get(opts, :source),
      "status" => status_value(status),
      "detail" => sanitize_value(Keyword.get(opts, :detail, %{})),
      "blockers" => normalize_items(Keyword.get(opts, :blockers, [])),
      "warnings" => normalize_items(Keyword.get(opts, :warnings, []))
    }
  end

  defp gate_items(checks, key) do
    checks
    |> Enum.flat_map(fn check ->
      check
      |> Map.get(key, [])
      |> Enum.map(fn item ->
        %{
          "entry" => check["id"],
          "kind" => check["kind"],
          "label" => check["label"],
          "reason" => item_reason(item),
          "detail" => item
        }
      end)
    end)
  end

  defp counts(checks) do
    %{
      "total" => length(checks),
      "ok" => Enum.count(checks, &(&1["status"] == "ok")),
      "attention" => Enum.count(checks, &(&1["status"] == "attention")),
      "blocked" => Enum.count(checks, &(&1["status"] == "blocked")),
      "error" => Enum.count(checks, &(&1["status"] == "error"))
    }
  end

  defp overall_status(checks) do
    checks
    |> Enum.map(& &1["status"])
    |> overall_status_from_statuses()
  end

  defp overall_status_from_statuses(statuses) do
    cond do
      Enum.any?(statuses, &(&1 == "error")) -> "error"
      Enum.any?(statuses, &(&1 == "blocked")) -> "blocked"
      Enum.any?(statuses, &(&1 == "attention")) -> "attention"
      true -> "ok"
    end
  end

  defp gate_to_check_status(status) when status in ["ok", "attention", "blocked", "error"],
    do: status

  defp gate_to_check_status(_status), do: "blocked"

  defp exit_code("error", _config), do: 1

  defp exit_code("blocked", config) do
    if config.fail_on_blocked? or config.fail_on_attention?, do: 1, else: 0
  end

  defp exit_code("attention", config) do
    if config.fail_on_attention?, do: 1, else: 0
  end

  defp exit_code(_gate_status, _config), do: 0

  defp stdout(artifact, %{json?: true}), do: Jason.encode!(artifact) <> "\n"

  defp stdout(artifact, _config) do
    summary =
      "[maxio release.readiness] gate_status=#{artifact["gate_status"]} " <>
        "checks=#{artifact["counts"]["total"]} ok=#{artifact["counts"]["ok"]} " <>
        "attention=#{artifact["counts"]["attention"]} " <>
        "blocked=#{artifact["counts"]["blocked"]} error=#{artifact["counts"]["error"]} " <>
        "artifact=#{artifact["artifact_path"]}\n"

    check_lines =
      artifact["checks"]
      |> Enum.map(fn check ->
        "[maxio release.readiness.check] id=#{check["id"]} status=#{check["status"]} " <>
          "source=#{check["source"]}\n"
      end)
      |> Enum.join()

    blocker_lines = Enum.map_join(artifact["blockers"], "", &gate_line("blocker", &1))
    warning_lines = Enum.map_join(artifact["warnings"], "", &gate_line("warning", &1))

    summary <> check_lines <> blocker_lines <> warning_lines
  end

  defp gate_line(kind, item) do
    "[maxio release.readiness.#{kind}] entry=#{item["entry"]} " <>
      "reason=#{item["reason"]}\n"
  end

  defp stderr(0, _gate_status), do: nil

  defp stderr(_exit_code, gate_status),
    do: "[maxio release.readiness] gate failed: #{gate_status}\n"

  defp usage_result(message) do
    %{
      exit_code: 64,
      stderr: "[maxio release.readiness] #{message}\n\n" <> @usage
    }
  end

  defp result_artifact(%{artifact: artifact}) when is_map(artifact), do: artifact
  defp result_artifact({:ok, %{artifact: artifact}}) when is_map(artifact), do: artifact
  defp result_artifact({:error, %{artifact: artifact}}) when is_map(artifact), do: artifact
  defp result_artifact(artifact) when is_map(artifact), do: artifact

  defp git_status_short do
    case System.cmd("git", ["status", "--short"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, exit_status} -> {:error, %{exit_status: exit_status, output: output}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp read_status_files do
    @status_files
    |> Enum.map(fn path ->
      case File.read(path) do
        {:ok, contents} -> contents
        {:error, _reason} -> ""
      end
    end)
    |> Enum.join("\n")
  end

  defp latest_precommit(text) when is_binary(text) do
    regex = ~r/mix precommit[^.\n\r]*?(\d+)\s+tests,\s+0\s+failures(?:,\s+(\d+)\s+excluded)?/i

    regex
    |> Regex.scan(text)
    |> List.first()
    |> case do
      [line, tests, excluded] ->
        %{
          "summary" => String.slice(line, 0, 240),
          "tests" => String.to_integer(tests),
          "failures" => 0,
          "excluded" => int_or_nil(excluded)
        }

      [line, tests] ->
        %{
          "summary" => String.slice(line, 0, 240),
          "tests" => String.to_integer(tests),
          "failures" => 0,
          "excluded" => nil
        }

      _other ->
        nil
    end
  end

  defp latest_precommit(_text), do: nil

  defp parse_datetime(nil), do: :missing
  defp parse_datetime(""), do: :missing

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> :invalid
    end
  end

  defp parse_datetime(_value), do: :invalid

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

    "p2_release_readiness_#{stamp}_#{System.unique_integer([:positive])}"
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

  defp field(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(%{} = map, key), do: Map.get(map, key)
  defp field(_value, _key), do: nil

  defp normalize_items(nil), do: []

  defp normalize_items(items) when is_list(items) do
    Enum.map(items, &normalize_item/1)
  end

  defp normalize_items(item), do: [normalize_item(item)]

  defp normalize_item(%{} = item) do
    Map.new(item, fn {key, value} -> {to_string(key), sanitize_value(value)} end)
  end

  defp normalize_item(value) when is_binary(value), do: %{"reason" => value}
  defp normalize_item(value), do: %{"reason" => inspect(value)}

  defp item_reason(%{"reason" => reason}), do: to_string(reason)
  defp item_reason(%{reason: reason}), do: to_string(reason)
  defp item_reason(item), do: inspect(item)

  defp sanitize_value(%{} = value) do
    Map.new(value, fn {key, item} -> {to_string(key), sanitize_value(item)} end)
  end

  defp sanitize_value(values) when is_list(values), do: Enum.map(values, &sanitize_value/1)
  defp sanitize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_value(value), do: value

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

  defp safe_candidate_name?(name) when is_binary(name) do
    name not in ["", ".", ".."] and
      not String.contains?(name, ["/", "\\", ".."]) and
      Path.basename(name) == name
  end

  defp safe_candidate_name?(_name), do: false

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp int_or_nil(nil), do: nil
  defp int_or_nil(""), do: nil
  defp int_or_nil(value), do: String.to_integer(value)
end
