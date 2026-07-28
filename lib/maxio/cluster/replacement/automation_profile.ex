defmodule Maxio.Cluster.Replacement.AutomationProfile do
  @moduledoc """
  Read-only readiness profile for production fresh-drive replacement automation.

  The profile checks whether existing schedulers are configured as one complete
  chain:

    * fresh-drive heal scheduler observes replacement markers,
    * a clean heal pass enqueues a durable rebalance job,
    * the rebalance scheduler drains copy/source cleanup,
    * rebalance closure verification is recorded,
    * both schedulers persist run ledger evidence.

  It does not start schedulers, write configuration, run heal/rebalance work,
  mutate topology, or touch physical layout.
  """

  @profile "replacement_automation_v1"

  alias Maxio.Cluster.SchedulerRuns

  @doc """
  Build a read-only replacement automation profile.

  Test callers may inject config through `:fresh_drive_heal_scheduler`,
  `:rebalance_scheduler`, and `:scheduler_ledger`. Production callers default to
  `Application.get_env/3`.
  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) when is_list(opts) do
    global_ledger = config(opts, :scheduler_ledger)
    fresh = fresh_config(config(opts, :fresh_drive_heal_scheduler), global_ledger)
    rebalance = rebalance_config(config(opts, :rebalance_scheduler), global_ledger)
    scheduler_evidence = scheduler_evidence(opts)

    checks = %{
      fresh_drive_heal_scheduler: fresh,
      rebalance_scheduler: rebalance,
      scheduler_evidence: scheduler_evidence,
      scheduler_ledger: %{
        fresh_drive_heal_enabled: fresh.ledger_enabled,
        rebalance_enabled: rebalance.ledger_enabled
      }
    }

    blockers = blockers(fresh, rebalance) ++ scheduler_evidence_blockers(scheduler_evidence)
    warnings = warnings(fresh, rebalance) ++ scheduler_evidence_warnings(scheduler_evidence)

    %{
      profile: @profile,
      status: status_from(blockers, warnings),
      ready?: blockers == [],
      automation_path: automation_path(fresh),
      checks: checks,
      blockers: blockers,
      warnings: warnings,
      next_action: next_action(blockers, warnings),
      boundaries: [
        "does_not_start_schedulers",
        "does_not_run_heal_or_rebalance",
        "scheduler_evidence_reads_ledger_only_when_requested",
        "does_not_mutate_topology_or_deployment",
        "does_not_remove_or_purge_physical_layout"
      ]
    }
  end

  @doc """
  Explicit local rehearsal readiness config.

  This is not a production default. It exists so bounded operator rehearsals can
  prove the replacement workflow/gate path without changing deployment config or
  starting destructive scheduler work.
  """
  def rehearsal_ready_opts do
    [
      fresh_drive_heal_scheduler: [
        enabled: true,
        probe_drive_health: true,
        auto_rebalance_after_heal: true,
        auto_advance_rebalance_after_heal: false,
        run_opts: [],
        scheduler_ledger: [enabled: true]
      ],
      rebalance_scheduler: [
        enabled: true,
        auto_source_cleanup: true,
        auto_rebalance_closure: true,
        run_opts: [],
        scheduler_ledger: [enabled: true]
      ],
      scheduler_ledger: [enabled: true]
    ]
  end

  defp config(opts, key) do
    opts
    |> Keyword.get(key, Application.get_env(:maxio, key, []))
    |> normalize_keyword()
  end

  defp normalize_keyword(value) when is_list(value), do: value
  defp normalize_keyword(_value), do: []

  defp fresh_config(cfg, global_ledger) do
    rebalance_advance_opts = normalize_keyword(Keyword.get(cfg, :rebalance_advance_opts, []))
    run_opts = normalize_keyword(Keyword.get(cfg, :run_opts, []))

    %{
      enabled: Keyword.get(cfg, :enabled, false),
      probe_drive_health: Keyword.get(cfg, :probe_drive_health, true),
      auto_rebalance_after_heal: Keyword.get(cfg, :auto_rebalance_after_heal, false),
      auto_advance_rebalance_after_heal:
        Keyword.get(cfg, :auto_advance_rebalance_after_heal, false),
      rebalance_advance_max_steps:
        positive_int(Keyword.get(cfg, :rebalance_advance_max_steps, 2), 2),
      inline_closure_verifier:
        Keyword.get(rebalance_advance_opts, :auto_rebalance_closure, :inherit),
      run_opts: %{
        dry_run: Keyword.get(run_opts, :dry_run, false),
        bucket: Keyword.get(run_opts, :bucket),
        scan_versions: Keyword.get(run_opts, :scan_versions, true),
        max_objects: Keyword.get(run_opts, :max_objects)
      },
      ledger_enabled: ledger_enabled?(cfg, global_ledger)
    }
  end

  defp rebalance_config(cfg, global_ledger) do
    run_opts = normalize_keyword(Keyword.get(cfg, :run_opts, []))

    %{
      enabled: Keyword.get(cfg, :enabled, false),
      auto_source_cleanup: Keyword.get(cfg, :auto_source_cleanup, true),
      auto_rebalance_closure: Keyword.get(cfg, :auto_rebalance_closure, false),
      run_opts: %{
        dry_run: Keyword.get(run_opts, :dry_run, false)
      },
      ledger_enabled: ledger_enabled?(cfg, global_ledger)
    }
  end

  defp ledger_enabled?(scheduler_cfg, global_ledger) do
    scheduler_cfg
    |> Keyword.get(:scheduler_ledger, [])
    |> normalize_keyword()
    |> Keyword.get(:enabled, Keyword.get(global_ledger, :enabled, true))
  end

  defp blockers(fresh, rebalance) do
    []
    |> maybe_block(not fresh.enabled, "fresh_drive_heal_scheduler_disabled")
    |> maybe_block(not fresh.probe_drive_health, "fresh_drive_heal_probe_disabled")
    |> maybe_block(
      not fresh.auto_rebalance_after_heal,
      "fresh_drive_heal_auto_rebalance_disabled"
    )
    |> maybe_block(fresh.run_opts.dry_run, "fresh_drive_heal_run_opts_dry_run")
    |> maybe_block(not is_nil(fresh.run_opts.bucket), "fresh_drive_heal_run_opts_bucket_scoped")
    |> maybe_block(
      fresh.run_opts.scan_versions == false,
      "fresh_drive_heal_run_opts_current_only"
    )
    |> maybe_block(
      not is_nil(fresh.run_opts.max_objects),
      "fresh_drive_heal_run_opts_max_objects_bounded"
    )
    |> maybe_block(not rebalance.enabled, "rebalance_scheduler_disabled")
    |> maybe_block(not rebalance.auto_source_cleanup, "rebalance_auto_source_cleanup_disabled")
    |> maybe_block(
      not rebalance.auto_rebalance_closure,
      "rebalance_auto_rebalance_closure_disabled"
    )
    |> maybe_block(rebalance.run_opts.dry_run, "rebalance_scheduler_run_opts_dry_run")
    |> maybe_block(not fresh.ledger_enabled, "fresh_drive_heal_scheduler_ledger_disabled")
    |> maybe_block(not rebalance.ledger_enabled, "rebalance_scheduler_ledger_disabled")
    |> Enum.reverse()
  end

  defp warnings(fresh, rebalance) do
    inline_closure =
      case fresh.inline_closure_verifier do
        :inherit -> rebalance.auto_rebalance_closure
        value -> value
      end

    []
    |> maybe_block(
      fresh.auto_advance_rebalance_after_heal and not inline_closure,
      "fresh_drive_heal_inline_advance_closure_disabled"
    )
    |> Enum.reverse()
  end

  defp scheduler_evidence(opts) do
    if Keyword.get(opts, :require_scheduler_evidence?, false) do
      opts
      |> scheduler_evidence_fun()
      |> safe_scheduler_evidence_call(Keyword.get(opts, :scheduler_evidence_opts, []))
    else
      %{required?: false, status: :not_requested}
    end
  end

  defp scheduler_evidence_fun(opts) do
    case Keyword.get(opts, :scheduler_evidence_fun) do
      fun when is_function(fun, 1) -> fun
      _other -> &SchedulerRuns.evidence_report/1
    end
  end

  defp safe_scheduler_evidence_call(fun, evidence_opts) do
    case fun.(evidence_opts) do
      {:ok, report} when is_map(report) ->
        view = SchedulerRuns.evidence_to_view(report)

        %{
          required?: true,
          status: evidence_status(view),
          report: view
        }

      {:error, reason} ->
        scheduler_evidence_unavailable(reason)

      other ->
        scheduler_evidence_unavailable({:bad_scheduler_evidence_result, other})
    end
  rescue
    e -> scheduler_evidence_unavailable({:crashed, Exception.message(e)})
  catch
    kind, reason -> scheduler_evidence_unavailable({:caught, kind, reason})
  end

  defp scheduler_evidence_unavailable(reason) do
    %{
      required?: true,
      status: :unavailable,
      reason: inspect(reason)
    }
  end

  defp evidence_status(%{} = report), do: Map.get(report, :status) || Map.get(report, "status")
  defp evidence_status(_report), do: nil

  defp scheduler_evidence_blockers(%{required?: true, status: :unavailable}),
    do: ["scheduler_evidence_unavailable"]

  defp scheduler_evidence_blockers(%{required?: true, status: "blocked"}),
    do: ["scheduler_evidence_blocked"]

  defp scheduler_evidence_blockers(_evidence), do: []

  defp scheduler_evidence_warnings(%{required?: true, status: "attention"}),
    do: ["scheduler_evidence_attention"]

  defp scheduler_evidence_warnings(_evidence), do: []

  defp status_from([], []), do: :ready
  defp status_from([], _warnings), do: :attention
  defp status_from(_blockers, _warnings), do: :blocked

  defp automation_path(%{auto_advance_rebalance_after_heal: true}),
    do:
      "fresh_drive_heal_scheduler -> rebalance_enqueue -> bounded_rebalance_drain -> rebalance_closure"

  defp automation_path(_fresh),
    do:
      "fresh_drive_heal_scheduler -> rebalance_enqueue -> rebalance_scheduler_drain -> rebalance_closure"

  defp next_action([blocker | _], _warnings), do: next_action_for(blocker)
  defp next_action([], [warning | _]), do: next_action_for(warning)
  defp next_action([], []), do: "none"

  defp next_action_for("fresh_drive_heal_scheduler_disabled"),
    do: "configure :fresh_drive_heal_scheduler, enabled: true"

  defp next_action_for("fresh_drive_heal_probe_disabled"),
    do: "configure :fresh_drive_heal_scheduler, probe_drive_health: true"

  defp next_action_for("fresh_drive_heal_auto_rebalance_disabled"),
    do: "configure :fresh_drive_heal_scheduler, auto_rebalance_after_heal: true"

  defp next_action_for("fresh_drive_heal_run_opts_dry_run"),
    do: "remove dry_run from :fresh_drive_heal_scheduler run_opts for production automation"

  defp next_action_for("fresh_drive_heal_run_opts_bucket_scoped"),
    do: "remove bucket from :fresh_drive_heal_scheduler run_opts for cluster-wide automation"

  defp next_action_for("fresh_drive_heal_run_opts_current_only"),
    do: "enable version scanning in :fresh_drive_heal_scheduler run_opts"

  defp next_action_for("fresh_drive_heal_run_opts_max_objects_bounded"),
    do: "remove max_objects from :fresh_drive_heal_scheduler run_opts for production automation"

  defp next_action_for("rebalance_scheduler_disabled"),
    do: "configure :rebalance_scheduler, enabled: true"

  defp next_action_for("rebalance_auto_source_cleanup_disabled"),
    do: "configure :rebalance_scheduler, auto_source_cleanup: true"

  defp next_action_for("rebalance_auto_rebalance_closure_disabled"),
    do: "configure :rebalance_scheduler, auto_rebalance_closure: true"

  defp next_action_for("rebalance_scheduler_run_opts_dry_run"),
    do: "remove dry_run from :rebalance_scheduler run_opts for production automation"

  defp next_action_for("fresh_drive_heal_scheduler_ledger_disabled"),
    do: "enable scheduler ledger for fresh_drive_heal"

  defp next_action_for("rebalance_scheduler_ledger_disabled"),
    do: "enable scheduler ledger for rebalance"

  defp next_action_for("fresh_drive_heal_inline_advance_closure_disabled"),
    do:
      "set fresh-drive rebalance_advance_opts auto_rebalance_closure or rely on rebalance scheduler closure"

  defp next_action_for("scheduler_evidence_unavailable"),
    do: "inspect scheduler ledger availability for replacement automation evidence"

  defp next_action_for("scheduler_evidence_blocked"),
    do: "run mix maxio.scheduler.evidence --json and repair scheduler cadence evidence"

  defp next_action_for("scheduler_evidence_attention"),
    do: "review mix maxio.scheduler.evidence warnings for replacement automation"

  defp next_action_for(_reason), do: "review replacement automation profile"

  defp maybe_block(blockers, true, blocker), do: [blocker | blockers]
  defp maybe_block(blockers, false, _blocker), do: blockers

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default
end
