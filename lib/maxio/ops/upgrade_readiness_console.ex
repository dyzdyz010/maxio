defmodule Maxio.Ops.UpgradeReadinessConsole do
  @moduledoc """
  Read-only Console projection for upgrade and rollback readiness evidence.

  This module reads release metadata, migration/schema state, topology revision
  history, archived gate artifacts, rehearsal bundles, and scheduler ledger
  evidence. It never runs migrations, gates, schedulers, shell commands, or
  topology mutation workflows.
  """

  import Ecto.Query

  alias Maxio.Cluster.{
    SchedulerRunRollup,
    SchedulerRuns,
    Topology,
    TopologyRevision,
    TopologyStore
  }

  alias Maxio.Ops.Gate.Artifacts, as: GateArtifacts
  alias Maxio.Ops.RehearsalBundle.Artifacts, as: BundleArtifacts
  alias Maxio.Repo

  @default_migrations_dir Path.expand("priv/repo/migrations")
  @max_rows 24
  @max_text 480
  @max_artifacts 6
  @max_scheduler_rows 8
  @schema_query "select version from schema_migrations"
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
    ~r/((?:--)?(?:secret|password|token|credential|access[-_]?key)(?:=|\s+))[^\s,;\]]+/i
  ]

  @doc "Load the read-only upgrade readiness console projection."
  @spec load(keyword()) :: map()
  def load(opts \\ []) when is_list(opts) do
    now = now(opts)
    release = release(opts)
    schema = schema(opts)
    topology = topology_revisions(opts)
    rollback = rollback_candidates(topology)
    gate = gate_artifacts(opts, now)
    bundles = rehearsal_bundles(opts, now)
    scheduler = scheduler_ledger(opts)

    status =
      rollup_status([
        release.status,
        schema.status,
        topology.status,
        rollback.status,
        gate.status,
        bundles.status,
        scheduler.status
      ])

    %{
      status: status,
      readonly_boundary: readonly_boundary(),
      summary_rows:
        summary_rows(status, release, schema, topology, rollback, gate, bundles, scheduler),
      release: release,
      schema: schema,
      topology_revisions: topology,
      rollback_candidates: rollback,
      gate_artifacts: gate,
      rehearsal_bundles: bundles,
      scheduler_ledger: scheduler,
      cross_links: cross_links()
    }
  end

  defp release(opts) do
    app_vsn_fun = Keyword.get(opts, :app_vsn_fun, &app_vsn/0)
    runtime_fun = Keyword.get(opts, :runtime_fun, &runtime_metadata/0)

    with {:ok, app_vsn} <- safe_call0(app_vsn_fun),
         {:ok, runtime} when is_map(runtime) <- safe_call0(runtime_fun) do
      %{
        status: "ok",
        rows: [
          row("release-app-version", "app_version", app_vsn),
          row("release-elixir", "elixir_version", map_get(runtime, :elixir_version)),
          row("release-otp", "otp_release", map_get(runtime, :otp_release)),
          row("release-erts", "erts_version", map_get(runtime, :erts_version)),
          row("release-node", "node", map_get(runtime, :node)),
          row("release-mix-env", "mix_env", map_get(runtime, :mix_env))
        ]
      }
    else
      {:ok, other} -> rows_error_section("release", {:bad_runtime_metadata, other})
      {:error, reason} -> rows_error_section("release", reason)
    end
  end

  defp schema(opts) do
    migration_files_fun = Keyword.get(opts, :migration_files_fun, &migration_files/1)
    db_versions_fun = Keyword.get(opts, :db_schema_versions_fun, &db_schema_versions/1)
    migration_opts = Keyword.get(opts, :migration_opts, [])
    schema_opts = Keyword.get(opts, :schema_opts, [])

    with {:ok, files} when is_list(files) <-
           safe_call1(migration_files_fun, migration_opts) |> unwrap_read_result(),
         {:ok, db_versions} when is_list(db_versions) <-
           safe_call1(db_versions_fun, schema_opts) |> unwrap_read_result() do
      schema_from_versions(files, db_versions)
    else
      {:ok, other} -> schema_unavailable({:bad_schema_evidence, other})
      {:error, reason} -> schema_unavailable(reason)
    end
  end

  defp schema_from_versions(files, db_versions) do
    versions =
      files
      |> Enum.map(&normalize_migration_file/1)
      |> Enum.reject(&is_nil/1)

    invalid =
      files
      |> Enum.map(&invalid_migration_file/1)
      |> Enum.reject(&is_nil/1)

    code_version_values = Enum.map(versions, & &1.version)
    duplicate_versions = duplicate_versions(code_version_values)
    code_versions = code_version_values |> Enum.uniq() |> Enum.sort()

    db_versions =
      db_versions |> Enum.map(&version_text/1) |> Enum.reject(&(&1 == "")) |> Enum.sort()

    pending = code_versions -- db_versions
    db_ahead = db_versions -- code_versions

    status =
      cond do
        files == [] -> "blocked"
        invalid != [] -> "blocked"
        duplicate_versions != [] -> "blocked"
        pending != [] or db_ahead != [] -> "blocked"
        true -> "ok"
      end

    reason =
      cond do
        files == [] -> "missing_migration_files"
        invalid != [] -> "invalid_migration_files"
        duplicate_versions != [] -> "duplicate_migration_versions"
        pending != [] -> "pending_migrations"
        db_ahead != [] -> "db_schema_ahead_of_code"
        true -> "code_and_db_schema_match"
      end

    %{
      status: status,
      reason: reason,
      code_versions: code_versions,
      db_versions: db_versions,
      pending_versions: pending,
      db_ahead_versions: db_ahead,
      duplicate_versions: duplicate_versions,
      rows: [
        row("schema-status", "status", status),
        row("schema-reason", "reason", reason),
        row("schema-code-count", "code_migrations", length(code_versions)),
        row("schema-db-count", "db_migrations", length(db_versions)),
        row("schema-latest-code", "latest_code_version", List.last(code_versions)),
        row("schema-latest-db", "latest_db_version", List.last(db_versions)),
        row("schema-pending", "pending_versions", pending),
        row("schema-db-ahead", "db_ahead_versions", db_ahead),
        row("schema-duplicates", "duplicate_migration_versions", duplicate_versions),
        row("schema-invalid", "invalid_migration_files", invalid)
      ]
    }
  end

  defp topology_revisions(opts) do
    active_fun =
      Keyword.get(opts, :active_topology_fun, &TopologyStore.active_revision_topology/1)

    history_fun = Keyword.get(opts, :topology_history_fun, &topology_history/1)
    active_opts = Keyword.get(opts, :active_topology_opts, [])
    history_opts = Keyword.get(opts, :topology_history_opts, [])

    active = active_topology(active_fun, active_opts)
    history = topology_history_section(history_fun, history_opts)

    %{
      status: rollup_status([active.status, history.status]),
      active: active,
      history: history,
      rows: active.rows,
      history_rows: history.rows
    }
  end

  defp active_topology(fun, opts) do
    case safe_call1(fun, opts) do
      {:ok, {:ok, %{revision: revision, topology: topology}}} ->
        revision_topology_section("topology-active", revision, topology)

      {:ok, {:error, :no_active_topology_revision}} ->
        %{
          status: "attention",
          reason: "no_active_topology_revision",
          rows: [
            row("topology-active-status", "status", "attention"),
            row("topology-active-reason", "reason", "no_active_topology_revision")
          ]
        }

      {:ok, {:error, reason}} ->
        unavailable_rows("topology-active", "blocked", reason)

      {:ok, other} ->
        unavailable_rows("topology-active", "blocked", {:bad_active_topology_result, other})

      {:error, reason} ->
        unavailable_rows("topology-active", "blocked", reason)
    end
  end

  defp topology_history_section(fun, opts) do
    case safe_call1(fun, opts) do
      {:ok, revisions} when is_list(revisions) ->
        rows =
          revisions
          |> Enum.take(@max_rows)
          |> Enum.with_index()
          |> Enum.map(fn {revision, index} -> topology_revision_row(revision, index) end)

        %{
          status: topology_history_status(rows),
          rows: rows
        }

      {:ok, other} ->
        table_error_section("topology-history", {:bad_topology_history_result, other})

      {:error, reason} ->
        table_error_section("topology-history", reason)
    end
  end

  defp rollback_candidates(%{history: %{rows: rows}}) do
    rows =
      rows
      |> Enum.filter(&(&1.revision_status == "superseded"))
      |> Enum.take(@max_rows)

    %{
      status: if(rows == [], do: "attention", else: rows_status(rows)),
      rows: rows
    }
  end

  defp gate_artifacts(opts, now) do
    fun = Keyword.get(opts, :gate_artifacts_fun, &GateArtifacts.list_recent/1)
    artifact_opts = Keyword.get(opts, :gate_artifacts_opts, limit: @max_artifacts)

    case safe_call1(fun, artifact_opts) do
      {:ok, artifacts} when is_list(artifacts) ->
        rows =
          artifacts
          |> Enum.take(@max_artifacts)
          |> Enum.with_index()
          |> Enum.map(fn {artifact, index} -> gate_artifact_row(artifact, index, now, opts) end)

        %{
          status: artifact_rows_status(rows),
          rows: rows,
          latest: List.first(rows)
        }

      {:ok, other} ->
        artifact_error_section("gate-artifacts", {:bad_gate_artifacts_result, other})

      {:error, reason} ->
        artifact_error_section("gate-artifacts", reason)
    end
  end

  defp rehearsal_bundles(opts, now) do
    fun = Keyword.get(opts, :rehearsal_bundles_fun, &BundleArtifacts.list_recent/1)
    bundle_opts = Keyword.get(opts, :rehearsal_bundles_opts, limit: @max_artifacts)

    case safe_call1(fun, bundle_opts) do
      {:ok, bundles} when is_list(bundles) ->
        rows =
          bundles
          |> Enum.take(@max_artifacts)
          |> Enum.with_index()
          |> Enum.map(fn {bundle, index} -> bundle_row(bundle, index, now, opts) end)

        %{
          status: artifact_rows_status(rows),
          rows: rows,
          latest: List.first(rows)
        }

      {:ok, other} ->
        artifact_error_section("rehearsal-bundles", {:bad_rehearsal_bundles_result, other})

      {:error, reason} ->
        artifact_error_section("rehearsal-bundles", reason)
    end
  end

  defp scheduler_ledger(opts) do
    states = scheduler_states(opts)
    runs = scheduler_runs(opts)
    rollups = scheduler_rollups(opts)

    %{
      status: rollup_status([states.status, runs.status, rollups.status]),
      states: states,
      runs: runs,
      rollups: rollups
    }
  end

  defp scheduler_states(opts) do
    fun = Keyword.get(opts, :scheduler_states_fun, &SchedulerRuns.list_states/1)
    state_opts = Keyword.get(opts, :scheduler_states_opts, [])

    case safe_call1(fun, state_opts) do
      {:ok, states} when is_list(states) ->
        rows =
          states
          |> Enum.take(@max_scheduler_rows)
          |> Enum.map(&scheduler_state_row/1)

        %{status: scheduler_state_rows_status(rows), rows: rows}

      {:ok, other} ->
        scheduler_table_error("scheduler-states", {:bad_scheduler_states_result, other})

      {:error, reason} ->
        scheduler_table_error("scheduler-states", reason)
    end
  end

  defp scheduler_runs(opts) do
    fun = Keyword.get(opts, :scheduler_runs_fun, &SchedulerRuns.list_runs/1)
    run_opts = Keyword.get(opts, :scheduler_runs_opts, limit: @max_scheduler_rows)

    case safe_call1(fun, run_opts) do
      {:ok, runs} when is_list(runs) ->
        rows =
          runs
          |> Enum.take(@max_scheduler_rows)
          |> Enum.map(&scheduler_run_row/1)

        %{status: scheduler_run_rows_status(rows), rows: rows}

      {:ok, other} ->
        scheduler_table_error("scheduler-runs", {:bad_scheduler_runs_result, other})

      {:error, reason} ->
        scheduler_table_error("scheduler-runs", reason)
    end
  end

  defp scheduler_rollups(opts) do
    fun = Keyword.get(opts, :scheduler_rollups_fun, &SchedulerRuns.list_rollups/1)
    rollup_opts = Keyword.get(opts, :scheduler_rollups_opts, limit: @max_scheduler_rows)

    case safe_call1(fun, rollup_opts) do
      {:ok, rollups} when is_list(rollups) ->
        rows =
          rollups
          |> Enum.take(@max_scheduler_rows)
          |> Enum.map(&scheduler_rollup_row/1)

        %{status: scheduler_rollup_rows_status(rows), rows: rows}

      {:ok, other} ->
        scheduler_table_error("scheduler-rollups", {:bad_scheduler_rollups_result, other})

      {:error, reason} ->
        scheduler_table_error("scheduler-rollups", reason)
    end
  end

  defp summary_rows(status, release, schema, topology, rollback, gate, bundles, scheduler) do
    [
      row("summary-status", "status", status),
      row("summary-release", "release", release.status),
      row("summary-schema", "schema", schema.status),
      row("summary-topology", "topology_revisions", topology.status),
      row("summary-rollback", "rollback_candidates", rollback.status),
      row("summary-gate", "gate_artifacts", gate.status),
      row("summary-bundles", "rehearsal_bundles", bundles.status),
      row("summary-scheduler", "scheduler_ledger", scheduler.status)
    ]
  end

  defp readonly_boundary do
    %{
      message:
        "This page only reads release, schema, topology revision, artifact, and scheduler ledger evidence.",
      forbidden: [
        "System.cmd/Mix.Task.run/Ecto.Migrator.run",
        "Repo insert/update/delete",
        "Topology install/activate",
        "Scheduler record/rollup/prune/retention_prune",
        "Ops gate/live rehearsal run",
        "scan/heal/rebalance/replacement execution APIs"
      ]
    }
  end

  defp cross_links do
    [
      %{id: "ops-upgrade-link-cluster", label: "Ops Cluster", path: "/ops/cluster"},
      %{id: "ops-upgrade-link-gate", label: "Ops Gate", path: "/ops/gate"},
      %{id: "ops-upgrade-link-replacement", label: "Ops Replacement", path: "/ops/replacement"},
      %{id: "ops-upgrade-link-rebalance", label: "Ops Rebalance", path: "/ops/rebalance"},
      %{id: "ops-upgrade-link-scan", label: "Ops Scan", path: "/ops/scan"}
    ]
  end

  defp app_vsn do
    case Application.spec(:maxio, :vsn) do
      nil -> "unknown"
      value -> to_string(value)
    end
  end

  defp runtime_metadata do
    %{
      elixir_version: System.version(),
      otp_release: to_string(:erlang.system_info(:otp_release)),
      erts_version: to_string(:erlang.system_info(:version)),
      node: Node.self(),
      mix_env: Application.get_env(:maxio, :env, "unknown")
    }
  end

  defp migration_files(opts) do
    dir = Keyword.get(opts, :dir, @default_migrations_dir)
    max_candidates = positive_int(Keyword.get(opts, :max_candidates), 500)

    with {:ok, names} <- File.ls(dir) do
      files =
        names
        |> Enum.filter(&safe_path_segment?/1)
        |> Enum.filter(&migration_candidate?/1)
        |> Enum.sort()
        |> Enum.take(max_candidates)
        |> Enum.map(&migration_file_entry(dir, &1))

      invalid = Enum.filter(files, &match?({:error, _reason}, &1))

      if invalid == [] do
        {:ok, Enum.map(files, fn {:ok, file} -> file end)}
      else
        {:error, {:invalid_migration_files, Enum.map(invalid, fn {:error, reason} -> reason end)}}
      end
    else
      {:error, reason} -> {:error, {:migration_dir_unavailable, reason}}
    end
  end

  defp migration_file_entry(dir, name) do
    path = Path.join(dir, name)

    with {:ok, stat} <- File.lstat(path, time: :posix),
         true <- stat.type == :regular,
         [version] <- Regex.run(~r/^(\d+)_.*\.exs$/, name, capture: :all_but_first) do
      {:ok,
       %{
         version: version,
         file_name: name,
         modified_at: posix_to_iso8601(stat.mtime),
         size_bytes: stat.size
       }}
    else
      {:error, reason} -> {:error, %{file_name: name, reason: reason}}
      false -> {:error, %{file_name: name, reason: :not_regular_file}}
      nil -> {:error, %{file_name: name, reason: :invalid_migration_file_name}}
      [] -> {:error, %{file_name: name, reason: :invalid_migration_file_name}}
    end
  end

  defp db_schema_versions(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.query(@schema_query, [], log: false) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [version | _rest] -> version_text(version) end)}

      {:error, reason} ->
        {:error, {:schema_migrations_query_failed, reason}}
    end
  end

  defp topology_history(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    limit = positive_int(Keyword.get(opts, :limit), @max_rows)

    query =
      from(r in TopologyRevision,
        order_by: [desc_nulls_last: r.activated_at, desc: r.inserted_at],
        limit: ^limit
      )

    {:ok, repo.all(query)}
  end

  defp revision_topology_section(prefix, revision, topology) do
    hash = text(map_get(revision, :topology_hash))

    case validate_topology_hash(topology, hash) do
      :ok ->
        %{
          status: "ok",
          reason: "active_topology_revision_valid",
          rows: [
            row("#{prefix}-status", "status", map_get(revision, :status, "active")),
            row("#{prefix}-id", "revision_id", map_get(revision, :id)),
            row("#{prefix}-hash", "topology_hash", hash),
            row("#{prefix}-source", "source", map_get(revision, :source)),
            row("#{prefix}-activated", "activated_at", map_get(revision, :activated_at)),
            row("#{prefix}-sets", "set_ids", topology_list(topology, :set_ids)),
            row("#{prefix}-pools", "pool_ids", topology_list(topology, :pool_ids))
          ]
        }

      {:error, reason} ->
        unavailable_rows(prefix, "blocked", reason)
    end
  end

  defp topology_revision_row(revision, index) do
    decoded =
      with {:ok, topology} <- TopologyStore.decode_config(map_get(revision, :config, %{})),
           :ok <- validate_topology_hash(topology, map_get(revision, :topology_hash)) do
        {:ok, topology}
      end

    status =
      case decoded do
        {:ok, _topology} -> "ok"
        {:error, _reason} -> "blocked"
      end

    reason =
      case decoded do
        {:ok, _topology} -> "revision_valid"
        {:error, reason} -> text(reason)
      end

    %{
      id: safe_id(map_get(revision, :id, "revision-#{index}")),
      status: status,
      reason: reason,
      revision_id: text(map_get(revision, :id)),
      revision_status: text(map_get(revision, :status)),
      topology_hash: text(map_get(revision, :topology_hash)),
      source: text(map_get(revision, :source)),
      source_job_id: text(map_get(revision, :source_job_id)),
      activated_at: text(map_get(revision, :activated_at))
    }
  end

  defp validate_topology_hash(topology, hash) do
    actual = Topology.fingerprint(topology)

    if actual == text(hash) do
      :ok
    else
      {:error, {:topology_revision_hash_mismatch, hash, actual}}
    end
  rescue
    error -> {:error, {:topology_revision_decode_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:topology_revision_decode_failed, kind, reason}}
  end

  defp gate_artifact_row(artifact, index, now, opts) do
    status = artifact_status(artifact, now, opts)

    %{
      id: safe_id(map_get(artifact, :file_name, "gate-#{index}")),
      status: status,
      file_name: text(map_get(artifact, :file_name)),
      artifact_status: text(map_get(artifact, :status, "unknown")),
      gate_status: text(map_get(artifact, :gate_status, "unknown")),
      run_id: text(map_get(artifact, :run_id)),
      generated_at: text(map_get(artifact, :generated_at)),
      modified_at: text(map_get(artifact, :modified_at)),
      schema_version: text(map_get(artifact, :schema_version)),
      counts: text(map_get(artifact, :counts)),
      reason: artifact_reason(artifact, now, opts)
    }
  end

  defp bundle_row(bundle, index, now, opts) do
    status = artifact_status(bundle, now, opts)

    %{
      id: safe_id(map_get(bundle, :file_name, "bundle-#{index}")),
      status: status,
      file_name: text(map_get(bundle, :file_name)),
      artifact_status: text(map_get(bundle, :status, "unknown")),
      gate_status: text(map_get(bundle, :gate_status, "unknown")),
      run_id: text(map_get(bundle, :run_id)),
      generated_at: text(map_get(bundle, :generated_at)),
      scenario: text(map_get(bundle, :scenario)),
      replacement_mode: text(map_get(bundle, :replacement_mode)),
      scheduler_mode: text(map_get(bundle, :scheduler_mode)),
      child_results: text(bundle_child_results(bundle)),
      reason: artifact_reason(bundle, now, opts)
    }
  end

  defp artifact_status(artifact, now, opts) do
    artifact_status = status_text(map_get(artifact, :status))
    gate_status = status_text(map_get(artifact, :gate_status))
    freshness_issue = artifact_freshness_issue(artifact, now, opts)

    cond do
      artifact_status == "invalid" -> "blocked"
      freshness_issue != nil -> "blocked"
      gate_status in ["blocked", "failed", "error", "invalid"] -> "blocked"
      gate_status in ["attention", "warning", "unknown", ""] -> "attention"
      artifact_status in ["ok", ""] and gate_status == "ok" -> "ok"
      true -> "attention"
    end
  end

  defp artifact_reason(artifact, now, opts) do
    freshness_issue = artifact_freshness_issue(artifact, now, opts)

    cond do
      text(map_get(artifact, :error_reason)) != "-" ->
        text(map_get(artifact, :error_reason))

      freshness_issue != nil ->
        freshness_issue

      true ->
        text(map_get(artifact, :gate_status, "unknown"))
    end
  end

  defp artifact_freshness_issue(artifact, now, opts) do
    max_age_minutes = positive_int(Keyword.get(opts, :artifact_max_age_minutes), 24 * 60)

    artifact
    |> map_get(:generated_at)
    |> generated_at_freshness_issue(now, max_age_minutes)
  end

  defp generated_at_freshness_issue(value, now, max_age_minutes) do
    case parse_iso8601(value) do
      {:ok, generated_at} ->
        cond do
          DateTime.compare(generated_at, now) == :gt -> "future_generated_at"
          DateTime.diff(now, generated_at, :minute) > max_age_minutes -> "stale_artifact"
          true -> nil
        end

      :error ->
        if missing_generated_at?(value), do: "missing_generated_at", else: "invalid_generated_at"
    end
  end

  defp bundle_child_results(bundle) do
    bundle
    |> map_get(:child_results, [])
    |> list()
    |> Enum.map(fn child ->
      %{
        id: map_get(child, :id),
        status: map_get(child, :status),
        gate_status: map_get(child, :gate_status)
      }
    end)
  end

  defp scheduler_state_row(state) do
    view = scheduler_view(state)

    %{
      id: safe_id(map_get(view, :id, map_get(view, :scheduler, "state"))),
      status: scheduler_state_status(view),
      scheduler: text(map_get(view, :scheduler)),
      node: text(map_get(view, :node)),
      state_status: text(map_get(view, :status)),
      alert_status: text(map_get(view, :alert_status)),
      last_run_id: text(map_get(view, :last_run_id)),
      last_finished_at: text(map_get(view, :last_finished_at)),
      backoff_until: text(map_get(view, :backoff_until)),
      consecutive_failures: text(map_get(view, :consecutive_failures, 0)),
      last_error_reason: text(map_get(view, :last_error_reason)),
      last_summary: text(sanitize_value(map_get(view, :last_summary, %{})))
    }
  end

  defp scheduler_run_row(run) do
    view = scheduler_view(run)

    %{
      id: safe_id(map_get(view, :id, "run")),
      status: scheduler_run_status(view),
      scheduler: text(map_get(view, :scheduler)),
      trigger: text(map_get(view, :trigger)),
      run_status: text(map_get(view, :status)),
      result_kind: text(map_get(view, :result_kind)),
      phase: text(map_get(view, :phase)),
      job_id: text(map_get(view, :job_id)),
      started_at: text(map_get(view, :started_at)),
      finished_at: text(map_get(view, :finished_at)),
      duration_ms: text(map_get(view, :duration_ms, 0)),
      error_reason: text(map_get(view, :error_reason)),
      summary: text(sanitize_value(map_get(view, :summary, %{})))
    }
  end

  defp scheduler_rollup_row(%SchedulerRunRollup{} = rollup) do
    %{
      id:
        safe_id(rollup.id || "#{rollup.scheduler}-#{rollup.trigger}-#{rollup.window_started_at}"),
      status: scheduler_rollup_status(rollup),
      scheduler: text(rollup.scheduler),
      trigger: text(rollup.trigger),
      window_started_at: text(rollup.window_started_at),
      window_finished_at: text(rollup.window_finished_at),
      run_count: text(rollup.run_count),
      healthy_count: text(rollup.healthy_count),
      blocked_count: text(rollup.blocked_count),
      failed_count: text(rollup.failed_count),
      last_status: text(rollup.last_status),
      last_finished_at: text(rollup.last_finished_at),
      pruned_at: text(rollup.pruned_at)
    }
  end

  defp scheduler_rollup_row(%{} = rollup) do
    %{
      id: safe_id(map_get(rollup, :id, "rollup")),
      status: scheduler_rollup_status(rollup),
      scheduler: text(map_get(rollup, :scheduler)),
      trigger: text(map_get(rollup, :trigger)),
      window_started_at: text(map_get(rollup, :window_started_at)),
      window_finished_at: text(map_get(rollup, :window_finished_at)),
      run_count: text(map_get(rollup, :run_count, 0)),
      healthy_count: text(map_get(rollup, :healthy_count, 0)),
      blocked_count: text(map_get(rollup, :blocked_count, 0)),
      failed_count: text(map_get(rollup, :failed_count, 0)),
      last_status: text(map_get(rollup, :last_status)),
      last_finished_at: text(map_get(rollup, :last_finished_at)),
      pruned_at: text(map_get(rollup, :pruned_at))
    }
  end

  defp scheduler_view(%{__struct__: struct} = value)
       when struct in [Maxio.Cluster.SchedulerRun, Maxio.Cluster.SchedulerState],
       do: SchedulerRuns.to_view(value)

  defp scheduler_view(%{} = value), do: value

  defp scheduler_state_status(view) do
    cond do
      status_text(map_get(view, :alert_status)) == "alert" -> "blocked"
      status_text(map_get(view, :status)) in ["blocked", "failed"] -> "blocked"
      text(map_get(view, :backoff_until)) != "-" -> "blocked"
      status_text(map_get(view, :alert_status)) == "warning" -> "attention"
      status_text(map_get(view, :status)) in ["ok", "idle"] -> "ok"
      true -> "attention"
    end
  end

  defp scheduler_run_status(view) do
    case status_text(map_get(view, :status)) do
      value when value in ["blocked", "failed"] -> "blocked"
      value when value in ["ok", "idle"] -> "ok"
      "skipped" -> "attention"
      _other -> "attention"
    end
  end

  defp scheduler_rollup_status(%SchedulerRunRollup{} = rollup) do
    cond do
      rollup.failed_count > 0 or rollup.blocked_count > 0 -> "blocked"
      rollup.run_count == 0 -> "attention"
      rollup.healthy_count == 0 -> "attention"
      true -> "ok"
    end
  end

  defp scheduler_rollup_status(%{} = rollup) do
    failed = int_value(map_get(rollup, :failed_count, 0))
    blocked = int_value(map_get(rollup, :blocked_count, 0))
    run_count = int_value(map_get(rollup, :run_count, 0))
    healthy = int_value(map_get(rollup, :healthy_count, 0))

    cond do
      failed > 0 or blocked > 0 -> "blocked"
      run_count == 0 -> "attention"
      healthy == 0 -> "attention"
      true -> "ok"
    end
  end

  defp unavailable_rows(prefix, status, reason) do
    %{
      status: status,
      reason: text(reason),
      rows: [
        row("#{prefix}-status", "status", status),
        row("#{prefix}-reason", "reason", reason)
      ]
    }
  end

  defp schema_unavailable(reason) do
    "schema"
    |> unavailable_rows("blocked", reason)
    |> Map.merge(%{
      code_versions: [],
      db_versions: [],
      pending_versions: [],
      db_ahead_versions: [],
      duplicate_versions: []
    })
  end

  defp rows_error_section(prefix, reason), do: unavailable_rows(prefix, "blocked", reason)

  defp table_error_section(prefix, reason) do
    %{
      status: "blocked",
      rows: [
        %{
          id: "#{prefix}-error",
          status: "blocked",
          reason: text(reason),
          revision_id: "-",
          revision_status: "-",
          topology_hash: "-",
          source: "-",
          source_job_id: "-",
          activated_at: "-"
        }
      ]
    }
  end

  defp artifact_error_section(prefix, reason) do
    %{
      status: "blocked",
      rows: [
        %{
          id: "#{prefix}-error",
          status: "blocked",
          file_name: "-",
          artifact_status: "blocked",
          gate_status: "-",
          run_id: "-",
          generated_at: "-",
          reason: text(reason)
        }
      ],
      latest: nil
    }
  end

  defp scheduler_table_error(prefix, reason) do
    %{
      status: "blocked",
      rows: [%{id: "#{prefix}-error", status: "blocked", reason: text(reason)}]
    }
  end

  defp topology_history_status([]), do: "attention"
  defp topology_history_status(rows), do: rows_status(rows)

  defp rows_status(rows) do
    cond do
      rows == [] -> "attention"
      Enum.any?(rows, &(&1.status == "blocked")) -> "blocked"
      Enum.any?(rows, &(&1.status in ["attention", "empty", "missing"])) -> "attention"
      true -> "ok"
    end
  end

  defp artifact_rows_status([]), do: "attention"
  defp artifact_rows_status(rows), do: rows_status(rows)

  defp scheduler_state_rows_status([]), do: "attention"
  defp scheduler_state_rows_status(rows), do: rows_status(rows)

  defp scheduler_run_rows_status([]), do: "attention"
  defp scheduler_run_rows_status(rows), do: rows_status(rows)

  defp scheduler_rollup_rows_status([]), do: "attention"
  defp scheduler_rollup_rows_status(rows), do: rows_status(rows)

  defp rollup_status(statuses) do
    statuses = Enum.map(statuses, &section_status/1)

    cond do
      Enum.any?(statuses, &(&1 == "blocked")) -> "blocked"
      Enum.any?(statuses, &(&1 in ["attention", "empty", "missing"])) -> "attention"
      true -> "ok"
    end
  end

  defp section_status(status) do
    case status_text(status) do
      value when value in ["ok", "ready", "active"] -> "ok"
      value when value in ["blocked", "failed", "error", "invalid", "unavailable"] -> "blocked"
      value when value in ["attention", "empty", "missing", "stale"] -> "attention"
      _other -> "attention"
    end
  end

  defp row(id, label, value), do: %{id: id, label: label, value: text(value)}

  defp safe_call0(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    error -> {:error, {:crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:caught, kind, reason}}
  end

  defp safe_call1(fun, arg) when is_function(fun, 1) do
    {:ok, fun.(arg)}
  rescue
    error -> {:error, {:crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:caught, kind, reason}}
  end

  defp unwrap_read_result({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_read_result({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_read_result(result), do: result

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      nil -> DateTime.utc_now()
      other -> other
    end
  end

  defp normalize_migration_file(%{version: version} = file) do
    version = version_text(version)

    if version == "" do
      nil
    else
      Map.put(file, :version, version)
    end
  end

  defp normalize_migration_file(_file), do: nil

  defp duplicate_versions(versions) do
    versions
    |> Enum.frequencies()
    |> Enum.filter(fn {_version, count} -> count > 1 end)
    |> Enum.map(fn {version, _count} -> version end)
    |> Enum.sort()
  end

  defp invalid_migration_file(%{version: version} = file) do
    if version_text(version) == "" do
      file
    else
      nil
    end
  end

  defp invalid_migration_file(file), do: file

  defp version_text(value) when is_integer(value), do: Integer.to_string(value)
  defp version_text(value) when is_binary(value), do: String.trim(value)
  defp version_text(nil), do: ""
  defp version_text(value), do: value |> to_string() |> String.trim()

  defp topology_list(topology, :set_ids) do
    Topology.all_set_ids_from(topology)
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp topology_list(topology, :pool_ids) do
    Topology.pool_ids_from(topology)
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

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

  defp sanitize_value(values) when is_list(values), do: Enum.map(values, &sanitize_value/1)
  defp sanitize_value(value) when is_binary(value), do: redact_text(value)
  defp sanitize_value(value), do: value

  defp sensitive_key?(key) do
    downcased = String.downcase(key)
    Enum.any?(@sensitive_key_fragments, &String.contains?(downcased, &1))
  end

  defp redact_text(text) do
    Enum.reduce(@sensitive_text_patterns, text, fn pattern, acc ->
      Regex.replace(pattern, acc, "\\1[REDACTED]")
    end)
  end

  defp safe_path_segment?(value) when is_binary(value) do
    value not in ["", ".", ".."] and
      not String.contains?(value, ["/", "\\", ".."]) and
      Path.basename(value) == value
  end

  defp safe_path_segment?(_value), do: false

  defp migration_candidate?(name) when is_binary(name) do
    String.ends_with?(name, ".exs") and not String.starts_with?(name, ".")
  end

  defp migration_candidate?(_name), do: false

  defp map_get(value, key, default \\ nil)

  defp map_get(%{} = map, key, default) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp map_get(value, key, default) do
    if is_struct(value) and Map.has_key?(value, key), do: Map.get(value, key), else: default
  end

  defp list(values) when is_list(values), do: values
  defp list(_values), do: []

  defp status_text(nil), do: ""
  defp status_text(value) when is_atom(value), do: Atom.to_string(value)
  defp status_text(value) when is_binary(value), do: value
  defp status_text(value), do: to_string(value)

  defp int_value(value) when is_integer(value), do: value

  defp int_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> 0
    end
  end

  defp int_value(_value), do: 0

  defp text(nil), do: "-"
  defp text(""), do: "-"
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_boolean(value), do: to_string(value)
  defp text(value) when is_number(value), do: to_string(value)
  defp text(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp text(value) when is_binary(value) do
    value
    |> redact_text()
    |> String.slice(0, @max_text)
  end

  defp text(value) when is_list(value) or is_map(value) or is_tuple(value) do
    value
    |> sanitize_value()
    |> inspect(limit: 20, printable_limit: @max_text)
    |> String.slice(0, @max_text)
  end

  defp text(value), do: value |> inspect(limit: 10) |> String.slice(0, @max_text)

  defp safe_id(nil), do: "unknown"

  defp safe_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      id -> id
    end
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp parse_iso8601(nil), do: :error
  defp parse_iso8601(""), do: :error

  defp parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> :error
    end
  end

  defp parse_iso8601(_value), do: :error

  defp missing_generated_at?(value) when value in [nil, ""], do: true
  defp missing_generated_at?(value) when is_binary(value), do: String.trim(value) == ""
  defp missing_generated_at?(_value), do: false

  defp posix_to_iso8601(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _other -> nil
    end
  end

  defp posix_to_iso8601(_value), do: nil
end
