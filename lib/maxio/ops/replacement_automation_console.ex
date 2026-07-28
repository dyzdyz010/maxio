defmodule Maxio.Ops.ReplacementAutomationConsole do
  @moduledoc """
  Read-only Console projection for replacement automation readiness.

  The projection reads replacement automation config/profile evidence and the
  scheduler run ledger. It never starts schedulers, runs heal/rebalance work,
  mutates topology, or touches physical layout.
  """

  alias Maxio.Cluster.{SchedulerRun, SchedulerRuns, SchedulerState}
  alias Maxio.Cluster.Replacement.AutomationProfile

  @default_run_limit 20
  @default_evidence_since_minutes 60
  @default_evidence_expected_interval_ms 60_000
  @default_evidence_stale_after_ms 300_000
  @max_messages 12
  @max_scheduler_evidence_rows 8
  @sensitive_key_fragments ~w(secret password token credential authorization access_key access-key raw body data)
  @sensitive_text_patterns [
    ~r/(AWS4-HMAC-SHA256\s+Credential=)[^\s,]+/i,
    ~r/(authorization:?\s*)[^\s,]+/i,
    ~r/((?:--)?(?:secret|password|token|credential|access[-_]?key)(?:=|\s+))[^\s,;\]\}]+/i
  ]

  @doc "Load the read-only replacement automation console projection."
  @spec load(keyword()) :: map()
  def load(opts \\ []) when is_list(opts) do
    profile = load_profile(opts)
    scheduler_evidence = scheduler_evidence_section(profile)
    scheduler_states = scheduler_states_section(opts)
    recent_runs = recent_runs_section(opts)
    blockers = uniq_messages(profile.blockers ++ scheduler_evidence.blockers)
    warnings = uniq_messages(profile.warnings ++ scheduler_evidence.warnings)

    %{
      status:
        rollup_status(
          profile.status,
          scheduler_evidence.status,
          scheduler_states.status,
          recent_runs.status
        ),
      readonly_boundary: readonly_boundary(),
      profile: profile,
      profile_rows: profile_rows(profile),
      fresh_drive_heal_rows: fresh_drive_heal_rows(profile),
      rebalance_rows: rebalance_rows(profile),
      scheduler_evidence: scheduler_evidence,
      blockers: blockers,
      warnings: warnings,
      scheduler_states: scheduler_states,
      recent_runs: recent_runs,
      cross_links: cross_links()
    }
  end

  defp load_profile(opts) do
    profile_fun = Keyword.get(opts, :automation_profile_fun, &AutomationProfile.status/1)
    profile_opts = automation_profile_opts(opts)

    case safe_call(profile_fun, profile_opts) do
      {:ok, profile} when is_map(profile) ->
        normalize_profile(profile)

      {:ok, other} ->
        unavailable_profile({:bad_replacement_automation_profile, other})

      {:error, reason} ->
        unavailable_profile(reason)
    end
  end

  defp automation_profile_opts(opts) do
    profile_opts = Keyword.get(opts, :automation_profile_opts, [])

    scheduler_evidence_opts =
      Keyword.get(
        profile_opts,
        :scheduler_evidence_opts,
        Keyword.get(opts, :scheduler_evidence_opts, default_scheduler_evidence_opts())
      )

    profile_opts
    |> Keyword.put_new(
      :require_scheduler_evidence?,
      Keyword.get(opts, :require_scheduler_evidence?, true)
    )
    |> Keyword.put_new(:scheduler_evidence_opts, scheduler_evidence_opts)
  end

  defp default_scheduler_evidence_opts do
    [
      since_minutes: @default_evidence_since_minutes,
      expected_interval_ms: @default_evidence_expected_interval_ms,
      stale_after_ms: @default_evidence_stale_after_ms,
      min_effective_nodes: 1
    ]
  end

  defp normalize_profile(profile) do
    checks = profile |> map_get(:checks, %{}) |> sanitize_value()

    %{
      profile: text(map_get(profile, :profile, "replacement_automation_v1")),
      status: profile_status(map_get(profile, :status)),
      ready?: truthy?(map_get(profile, :ready?, false)),
      automation_path: text(map_get(profile, :automation_path)),
      checks: checks,
      fresh_drive_heal: map_get(checks, :fresh_drive_heal_scheduler, %{}),
      rebalance: map_get(checks, :rebalance_scheduler, %{}),
      scheduler_evidence: map_get(checks, :scheduler_evidence, %{}),
      scheduler_ledger: map_get(checks, :scheduler_ledger, %{}),
      blockers: message_list(map_get(profile, :blockers, [])),
      warnings: message_list(map_get(profile, :warnings, [])),
      next_action: text(map_get(profile, :next_action, "review replacement automation profile")),
      boundaries: message_list(map_get(profile, :boundaries, []))
    }
  end

  defp unavailable_profile(reason) do
    %{
      profile: "replacement_automation_v1",
      status: "blocked",
      ready?: false,
      automation_path: "-",
      checks: %{},
      fresh_drive_heal: %{},
      rebalance: %{},
      scheduler_evidence: %{required?: true, status: :unavailable, reason: inspect(reason)},
      scheduler_ledger: %{},
      blockers: ["replacement_automation_profile_unavailable"],
      warnings: [],
      next_action: "inspect replacement automation profile availability",
      boundaries: readonly_boundary().forbidden
    }
  end

  defp scheduler_evidence_section(profile) do
    evidence = profile.scheduler_evidence || %{}
    required? = truthy?(map_get(evidence, :required?, false))
    raw_status = evidence_status(evidence, required?)
    report = map_get(evidence, :report, %{})
    blockers = report_messages(evidence, report, :blockers)
    warnings = report_messages(evidence, report, :warnings)
    rows = scheduler_evidence_rows(evidence, report, required?, raw_status)
    scheduler_rows = scheduler_evidence_scheduler_rows(report)

    %{
      status: raw_status,
      required?: required?,
      rows: rows,
      scheduler_rows: scheduler_rows,
      blockers: blockers,
      warnings: warnings
    }
  end

  defp scheduler_evidence_rows(evidence, report, required?, status) do
    [
      row("scheduler-evidence-required", "required", required?),
      row("scheduler-evidence-status", "status", status),
      row("scheduler-evidence-generated", "generated_at", map_get(report, :generated_at)),
      row("scheduler-evidence-from", "from", map_get(report, :from)),
      row("scheduler-evidence-until", "until", map_get(report, :until)),
      row("scheduler-evidence-window-ms", "window_ms", map_get(report, :window_ms)),
      row(
        "scheduler-evidence-min-nodes",
        "min_effective_nodes",
        map_get(report, :min_effective_nodes)
      ),
      row("scheduler-evidence-reason", "reason", map_get(evidence, :reason))
    ]
    |> Enum.reject(&empty_row?/1)
  end

  defp scheduler_evidence_scheduler_rows(report) do
    report
    |> map_get(:schedulers, [])
    |> list()
    |> Enum.take(@max_scheduler_evidence_rows)
    |> Enum.with_index()
    |> Enum.map(fn {scheduler, index} ->
      cadence = map_get(scheduler, :cadence, %{})

      %{
        id: safe_id(map_get(scheduler, :scheduler, index)),
        scheduler: text(map_get(scheduler, :scheduler)),
        status: evidence_row_status(map_get(scheduler, :status)),
        health: text(map_get(cadence, :health)),
        reason: text(map_get(cadence, :reason)),
        scheduled_nodes: text(map_get(scheduler, :scheduled_nodes, [])),
        effective_nodes: text(map_get(scheduler, :effective_scheduled_nodes, [])),
        healthy_nodes: text(map_get(scheduler, :healthy_scheduled_nodes, [])),
        blockers: text(map_get(scheduler, :blockers, [])),
        warnings: text(map_get(scheduler, :warnings, []))
      }
    end)
  end

  defp scheduler_states_section(opts) do
    states_fun = Keyword.get(opts, :scheduler_states_fun, &SchedulerRuns.list_states/1)

    case safe_call(states_fun, Keyword.get(opts, :scheduler_states_opts, [])) do
      {:ok, states} when is_list(states) ->
        rows =
          states
          |> Enum.map(&scheduler_state_view/1)
          |> Enum.sort_by(&{&1.scheduler, &1.node})

        %{status: ledger_rows_status(rows), rows: rows}

      {:ok, other} ->
        ledger_error_section({:bad_scheduler_states_result, other})

      {:error, reason} ->
        ledger_error_section(reason)
    end
  end

  defp recent_runs_section(opts) do
    runs_fun = Keyword.get(opts, :scheduler_runs_fun, &SchedulerRuns.list_runs/1)

    run_opts =
      opts
      |> Keyword.get(:scheduler_runs_opts, [])
      |> Keyword.put_new(:limit, Keyword.get(opts, :run_limit, @default_run_limit))

    case safe_call(runs_fun, run_opts) do
      {:ok, runs} when is_list(runs) ->
        rows =
          runs
          |> Enum.take(Keyword.get(run_opts, :limit, @default_run_limit))
          |> Enum.map(&scheduler_run_view/1)

        %{status: ledger_rows_status(rows), rows: rows}

      {:ok, other} ->
        ledger_error_section({:bad_scheduler_runs_result, other})

      {:error, reason} ->
        ledger_error_section(reason)
    end
  end

  defp scheduler_state_view(%SchedulerState{} = state),
    do: state |> SchedulerRuns.to_view() |> scheduler_state_view()

  defp scheduler_state_view(%{} = state) do
    %{
      id: safe_id(map_get(state, :id, "#{map_get(state, :scheduler)}-#{map_get(state, :node)}")),
      scheduler: text(map_get(state, :scheduler)),
      node: text(map_get(state, :node)),
      status: ledger_status(map_get(state, :status)),
      consecutive_failures: text(map_get(state, :consecutive_failures, 0)),
      last_run_id: text(map_get(state, :last_run_id)),
      last_started_at: text(map_get(state, :last_started_at)),
      last_finished_at: text(map_get(state, :last_finished_at)),
      backoff_until: text(map_get(state, :backoff_until)),
      alert_status: text(map_get(state, :alert_status)),
      alerted_at: text(map_get(state, :alerted_at)),
      last_error_reason: text(map_get(state, :last_error_reason)),
      last_summary: text(map_get(state, :last_summary))
    }
  end

  defp scheduler_state_view(other) do
    %{
      id: safe_id(:bad_state),
      scheduler: "-",
      node: "-",
      status: "blocked",
      consecutive_failures: "-",
      last_run_id: "-",
      last_started_at: "-",
      last_finished_at: "-",
      backoff_until: "-",
      alert_status: "-",
      alerted_at: "-",
      last_error_reason: text({:bad_scheduler_state, other}),
      last_summary: "-"
    }
  end

  defp scheduler_run_view(%SchedulerRun{} = run),
    do: run |> SchedulerRuns.to_view() |> scheduler_run_view()

  defp scheduler_run_view(%{} = run) do
    %{
      id: safe_id(map_get(run, :id, "#{map_get(run, :scheduler)}-#{map_get(run, :started_at)}")),
      scheduler: text(map_get(run, :scheduler)),
      trigger: text(map_get(run, :trigger)),
      node: text(map_get(run, :node)),
      status: ledger_status(map_get(run, :status)),
      result_kind: text(map_get(run, :result_kind)),
      phase: text(map_get(run, :phase)),
      job_id: text(map_get(run, :job_id)),
      started_at: text(map_get(run, :started_at)),
      finished_at: text(map_get(run, :finished_at)),
      duration_ms: text(map_get(run, :duration_ms)),
      consecutive_failures_after: text(map_get(run, :consecutive_failures_after)),
      backoff_until: text(map_get(run, :backoff_until)),
      alert_status: text(map_get(run, :alert_status)),
      error_reason: text(map_get(run, :error_reason)),
      summary: text(map_get(run, :summary))
    }
  end

  defp scheduler_run_view(other) do
    %{
      id: safe_id(:bad_run),
      scheduler: "-",
      trigger: "-",
      node: "-",
      status: "blocked",
      result_kind: "-",
      phase: "-",
      job_id: "-",
      started_at: "-",
      finished_at: "-",
      duration_ms: "-",
      consecutive_failures_after: "-",
      backoff_until: "-",
      alert_status: "-",
      error_reason: text({:bad_scheduler_run, other}),
      summary: "-"
    }
  end

  defp profile_rows(profile) do
    [
      row("replacement-profile-name", "profile", profile.profile),
      row("replacement-profile-status", "status", profile.status),
      row("replacement-profile-ready", "ready", profile.ready?),
      row("replacement-profile-path", "automation_path", profile.automation_path),
      row("replacement-profile-next-action", "next_action", profile.next_action),
      row("replacement-profile-boundaries", "boundaries", profile.boundaries)
    ]
  end

  defp fresh_drive_heal_rows(profile) do
    fresh = profile.fresh_drive_heal || %{}
    run_opts = map_get(fresh, :run_opts, %{})

    [
      row("fresh-drive-heal-enabled", "enabled", map_get(fresh, :enabled)),
      row("fresh-drive-heal-probe", "probe_drive_health", map_get(fresh, :probe_drive_health)),
      row(
        "fresh-drive-heal-auto-rebalance",
        "auto_rebalance_after_heal",
        map_get(fresh, :auto_rebalance_after_heal)
      ),
      row(
        "fresh-drive-heal-auto-advance",
        "auto_advance_rebalance_after_heal",
        map_get(fresh, :auto_advance_rebalance_after_heal)
      ),
      row(
        "fresh-drive-heal-advance-steps",
        "rebalance_advance_max_steps",
        map_get(fresh, :rebalance_advance_max_steps)
      ),
      row(
        "fresh-drive-heal-inline-closure",
        "inline_closure_verifier",
        map_get(fresh, :inline_closure_verifier)
      ),
      row("fresh-drive-heal-run-dry-run", "run_opts.dry_run", map_get(run_opts, :dry_run)),
      row("fresh-drive-heal-run-bucket", "run_opts.bucket", map_get(run_opts, :bucket)),
      row(
        "fresh-drive-heal-run-versions",
        "run_opts.scan_versions",
        map_get(run_opts, :scan_versions)
      ),
      row(
        "fresh-drive-heal-run-max-objects",
        "run_opts.max_objects",
        map_get(run_opts, :max_objects)
      ),
      row("fresh-drive-heal-ledger", "ledger_enabled", map_get(fresh, :ledger_enabled))
    ]
    |> Enum.reject(&empty_row?/1)
  end

  defp rebalance_rows(profile) do
    rebalance = profile.rebalance || %{}
    run_opts = map_get(rebalance, :run_opts, %{})

    [
      row("rebalance-enabled", "enabled", map_get(rebalance, :enabled)),
      row(
        "rebalance-source-cleanup",
        "auto_source_cleanup",
        map_get(rebalance, :auto_source_cleanup)
      ),
      row(
        "rebalance-closure",
        "auto_rebalance_closure",
        map_get(rebalance, :auto_rebalance_closure)
      ),
      row("rebalance-run-dry-run", "run_opts.dry_run", map_get(run_opts, :dry_run)),
      row("rebalance-ledger", "ledger_enabled", map_get(rebalance, :ledger_enabled)),
      row(
        "rebalance-ledger-fresh",
        "scheduler_ledger.fresh_drive_heal_enabled",
        map_get(profile.scheduler_ledger, :fresh_drive_heal_enabled)
      ),
      row(
        "rebalance-ledger-rebalance",
        "scheduler_ledger.rebalance_enabled",
        map_get(profile.scheduler_ledger, :rebalance_enabled)
      )
    ]
    |> Enum.reject(&empty_row?/1)
  end

  defp readonly_boundary do
    %{
      message:
        "This page only reads replacement automation profile and scheduler ledger evidence.",
      forbidden: [
        "FreshDriveHeal.run_once",
        "FreshDriveHeal.Scheduler.run_now",
        "Rebalance.Runner.run_once",
        "Rebalance.Scheduler.run_now",
        "topology apply/persist/verify",
        "physical remove/purge"
      ]
    }
  end

  defp cross_links do
    [
      %{id: "ops-replacement-link-scan", label: "Ops Scan", path: "/ops/scan"},
      %{id: "ops-replacement-link-rebalance", label: "Ops Rebalance", path: "/ops/rebalance"},
      %{id: "ops-replacement-link-gate", label: "Ops Gate", path: "/ops/gate"}
    ]
  end

  defp report_messages(evidence, report, key) do
    evidence
    |> map_get(key, map_get(report, key, []))
    |> message_list()
  end

  defp ledger_error_section(reason) do
    %{
      status: "blocked",
      rows: [
        %{
          id: "ledger-error",
          scheduler: "-",
          node: "-",
          status: "blocked",
          last_error_reason: text(reason),
          summary: "-"
        }
      ]
    }
  end

  defp ledger_rows_status([]), do: "empty"

  defp ledger_rows_status(rows) do
    statuses = Enum.map(rows, &Map.get(&1, :status))

    cond do
      Enum.any?(statuses, &blocked_status?/1) -> "blocked"
      Enum.any?(statuses, &attention_status?/1) -> "attention"
      true -> "ok"
    end
  end

  defp rollup_status(statuses) when is_list(statuses) do
    normalized = Enum.map(statuses, &section_status/1)

    cond do
      Enum.any?(normalized, &(&1 == "blocked")) -> "blocked"
      Enum.all?(normalized, &(&1 == "empty")) -> "empty"
      Enum.any?(normalized, &(&1 in ["attention", "empty"])) -> "attention"
      "ready" in normalized -> "ready"
      true -> "ok"
    end
  end

  defp rollup_status(profile, evidence, states, runs),
    do: rollup_status([profile, evidence, states, runs])

  defp section_status(status) do
    status = status_text(status)

    cond do
      blocked_status?(status) or status in ["unavailable", "missing"] -> "blocked"
      status in ["empty", "not_requested"] -> "empty"
      attention_status?(status) -> "attention"
      status == "ready" -> "ready"
      status == "ok" -> "ok"
      true -> "attention"
    end
  end

  defp profile_status(:ready), do: "ready"
  defp profile_status("ready"), do: "ready"
  defp profile_status(status), do: section_status(status)

  defp evidence_status(_evidence, false), do: "not_requested"

  defp evidence_status(evidence, true) do
    case status_text(map_get(evidence, :status)) do
      "" -> "missing"
      status -> status
    end
  end

  defp evidence_row_status(status) do
    case status_text(status) do
      "" -> "missing"
      value -> value
    end
  end

  defp ledger_status(status) do
    case status_text(status) do
      "" -> "missing"
      value -> value
    end
  end

  defp blocked_status?(status) do
    status_text(status) in ["blocked", "failed", "error", "unavailable", "missing"]
  end

  defp attention_status?(status) do
    status_text(status) in [
      "attention",
      "stale",
      "warning",
      "skipped",
      "backoff",
      "alerting",
      "not_started",
      "not_requested",
      "empty"
    ]
  end

  defp row(id, label, value), do: %{id: id, label: label, value: text(value)}

  defp empty_row?(%{value: value}), do: value in ["", "-"]

  defp safe_call(fun, arg) when is_function(fun, 1) do
    {:ok, fun.(arg)}
  rescue
    error -> {:error, {:crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:caught, kind, reason}}
  end

  defp map_get(value, key, default \\ nil)

  defp map_get(%{} = map, key, default) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp map_get(_value, _key, default), do: default

  defp list(values) when is_list(values), do: values
  defp list(_value), do: []

  defp message_list(values) when is_list(values) do
    values
    |> Enum.map(&text/1)
    |> Enum.reject(&(&1 in ["", "-"]))
    |> Enum.take(@max_messages)
  end

  defp message_list(value) when is_nil(value), do: []
  defp message_list(value), do: [text(value)]

  defp uniq_messages(messages) do
    messages
    |> message_list()
    |> Enum.uniq()
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp status_text(nil), do: ""
  defp status_text(value) when is_atom(value), do: Atom.to_string(value)
  defp status_text(value) when is_binary(value), do: value
  defp status_text(value), do: to_string(value)

  defp text(nil), do: "-"
  defp text(""), do: "-"
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_boolean(value), do: to_string(value)
  defp text(value) when is_number(value), do: to_string(value)
  defp text(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp text(value) when is_binary(value) do
    value
    |> String.slice(0, 480)
    |> redact_text()
  end

  defp text(value) when is_map(value) or is_list(value) or is_tuple(value) do
    value
    |> sanitize_value()
    |> inspect(limit: 20, printable_limit: 480)
    |> redact_text()
  end

  defp text(value), do: value |> inspect(limit: 10) |> redact_text()

  defp sanitize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_value(value) when is_binary(value), do: redact_text(value)

  defp sanitize_value(value) when is_boolean(value) or is_nil(value) or is_number(value),
    do: value

  defp sanitize_value(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> sanitize_value()

  defp sanitize_value(values) when is_list(values), do: Enum.map(values, &sanitize_value/1)

  defp sanitize_value(%{} = map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, sanitize_value(value)}
      end
    end)
  end

  defp sanitize_value(value), do: value

  defp sensitive_key?(key) do
    key_text = key |> to_string() |> String.downcase()
    Enum.any?(@sensitive_key_fragments, &String.contains?(key_text, &1))
  end

  defp redact_text(text) do
    Enum.reduce(@sensitive_text_patterns, text, fn pattern, acc ->
      String.replace(acc, pattern, "\\1[REDACTED]")
    end)
  end

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
end
