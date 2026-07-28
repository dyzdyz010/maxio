defmodule Mix.Tasks.Maxio.Scheduler.Status do
  @shortdoc "Print persistent scheduler run ledger status"
  @moduledoc """
  Print persistent run/state evidence for cluster schedulers.

      mix maxio.scheduler.status
      mix maxio.scheduler.status --scheduler fresh_drive_heal
      mix maxio.scheduler.status --runs 50
      mix maxio.scheduler.status --state-only --json
      mix maxio.scheduler.status --cadence --since-minutes 120 --json
      mix maxio.scheduler.status --rollups --rollup-limit 24 --json
      mix maxio.scheduler.status --cadence --fail-on-blocked --json
  """

  use Mix.Task

  alias Maxio.Cluster.SchedulerRuns

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          scheduler: :string,
          trigger: :string,
          runs: :integer,
          rollups: :boolean,
          rollup_limit: :integer,
          state_only: :boolean,
          cadence: :boolean,
          since_minutes: :integer,
          expected_interval_ms: :integer,
          stale_after_ms: :integer,
          fail_on_blocked: :boolean,
          fail_on_attention: :boolean,
          json: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.scheduler.status [--scheduler fresh_drive_heal|rebalance] " <>
          "[--trigger manual|scheduled] [--runs N] [--state-only] [--rollups] " <>
          "[--rollup-limit N] [--cadence] [--since-minutes N] " <>
          "[--expected-interval-ms N] [--stale-after-ms N] " <>
          "[--fail-on-blocked] [--fail-on-attention] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_scheduler!(Keyword.get(opts, :scheduler))
    validate_trigger!(Keyword.get(opts, :trigger))
    validate_runs!(Keyword.get(opts, :runs))
    validate_rollup_limit!(Keyword.get(opts, :rollup_limit))
    validate_positive_int!(opts, :since_minutes, "--since-minutes")
    validate_positive_int!(opts, :expected_interval_ms, "--expected-interval-ms")
    validate_positive_int!(opts, :stale_after_ms, "--stale-after-ms")

    ensure_repo_started!()

    states =
      opts
      |> scheduler_opts()
      |> SchedulerRuns.list_states()
      |> Enum.map(&SchedulerRuns.to_view/1)

    runs =
      if Keyword.get(opts, :state_only, false) do
        []
      else
        opts
        |> scheduler_opts()
        |> Keyword.put(:limit, Keyword.get(opts, :runs, 20))
        |> SchedulerRuns.list_runs()
        |> Enum.map(&SchedulerRuns.to_view/1)
      end

    rollups =
      if Keyword.get(opts, :rollups, false) do
        opts
        |> rollup_opts()
        |> Keyword.put(:limit, Keyword.get(opts, :rollup_limit, 20))
        |> SchedulerRuns.list_rollups()
        |> Enum.map(&SchedulerRuns.rollup_to_view/1)
      else
        []
      end

    report = %{states: states, runs: runs, rollups: rollups}

    report =
      if Keyword.get(opts, :cadence, false) do
        {:ok, cadence} =
          opts
          |> scheduler_opts()
          |> cadence_opts(opts)
          |> SchedulerRuns.cadence_report()

        Map.put(report, :cadence, SchedulerRuns.cadence_to_view(cadence))
      else
        report
      end

    report = put_gate(report)

    print_or_json(report, opts)
    fail_if_needed!(report, opts)
  end

  defp print_or_json(report, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(report))
    else
      print_text(report)
    end
  end

  defp print_text(%{states: [], runs: [], rollups: []} = report) do
    print_summary(report)
    IO.puts("[maxio scheduler.status] status=not_started schedulers=0 runs=0")
    print_gate_items(report)
    print_cadence_reports(report)
  end

  defp print_text(%{states: states, runs: runs, rollups: rollups} = report) do
    print_summary(report)

    Enum.each(states, fn state ->
      IO.puts(
        "[maxio scheduler.status] scheduler=#{state.scheduler} status=#{state.status} " <>
          "consecutive_failures=#{state.consecutive_failures} " <>
          "alert_status=#{state.alert_status} backoff_until=#{format_value(state.backoff_until)} " <>
          "last_run_id=#{format_value(state.last_run_id)} " <>
          "last_error_reason=#{format_value(state.last_error_reason)}"
      )
    end)

    Enum.each(runs, fn run ->
      IO.puts(
        "[maxio scheduler.run] id=#{run.id} scheduler=#{run.scheduler} trigger=#{run.trigger} " <>
          "node=#{run.node} status=#{run.status} result_kind=#{run.result_kind} " <>
          "phase=#{format_value(run.phase)} job_id=#{format_value(run.job_id)} " <>
          "duration_ms=#{run.duration_ms} failures_after=#{run.consecutive_failures_after} " <>
          "alert_status=#{run.alert_status} error_reason=#{format_value(run.error_reason)}"
      )
    end)

    Enum.each(rollups, &print_rollup/1)
    print_gate_items(report)
    print_cadence_reports(report)
  end

  defp print_summary(report) do
    IO.puts(
      "[maxio scheduler.status.summary] gate_status=#{report.gate_status} " <>
        "states=#{length(report.states)} runs=#{length(report.runs)} " <>
        "rollups=#{length(report.rollups)} blockers=#{length(report.blockers)} " <>
        "warnings=#{length(report.warnings)}"
    )
  end

  defp print_gate_items(report) do
    Enum.each(report.blockers, &print_gate_item(:blocker, &1))
    Enum.each(report.warnings, &print_gate_item(:warning, &1))
  end

  defp print_gate_item(kind, item) do
    fields =
      item
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} -> "#{key}=#{format_value(value)}" end)
      |> Enum.join(" ")

    IO.puts("[maxio scheduler.status.#{kind}] #{fields}")
  end

  defp print_rollup(rollup) do
    IO.puts(
      "[maxio scheduler.rollup] scheduler=#{rollup.scheduler} trigger=#{rollup.trigger} " <>
        "window_started_at=#{rollup.window_started_at} " <>
        "window_finished_at=#{rollup.window_finished_at} window_ms=#{rollup.window_ms} " <>
        "runs=#{rollup.run_count} ok=#{rollup.ok_count} idle=#{rollup.idle_count} " <>
        "skipped=#{rollup.skipped_count} blocked=#{rollup.blocked_count} " <>
        "failed=#{rollup.failed_count} effective=#{rollup.effective_count} " <>
        "healthy=#{rollup.healthy_count} last_status=#{format_value(rollup.last_status)}"
    )
  end

  defp print_cadence_reports(report) do
    case Map.get(report, :cadence) do
      %{reports: cadence_reports} -> Enum.each(cadence_reports, &print_cadence/1)
      _other -> :ok
    end
  end

  defp print_cadence(cadence) do
    IO.puts(
      "[maxio scheduler.cadence] scheduler=#{cadence.scheduler} health=#{cadence.health} " <>
        "reason=#{cadence.reason} healthy?=#{cadence.healthy?} " <>
        "expected_interval_ms=#{format_value(cadence.expected_interval_ms)} " <>
        "stale_after_ms=#{format_value(cadence.stale_after_ms)} " <>
        "last_healthy_scheduled_at=#{format_value(cadence.last_healthy_scheduled_finished_at)} " <>
        "healthy_age_ms=#{format_value(cadence.effective_age_ms)} " <>
        "nodes=#{format_list(cadence.scheduled_nodes)} " <>
        "effective_nodes=#{format_list(cadence.effective_scheduled_nodes)} " <>
        "healthy_nodes=#{format_list(cadence.healthy_scheduled_nodes)} " <>
        "skipped_nodes=#{format_list(cadence.skipped_scheduled_nodes)} " <>
        "lock_losers=#{format_list(cadence.lock_loser_nodes)}"
    )

    IO.puts(
      "[maxio scheduler.cadence.window] scheduler=#{cadence.scheduler} " <>
        "since=#{format_value(cadence.since)} scheduled=#{cadence.scheduled_runs} " <>
        "effective=#{cadence.effective_scheduled_runs} skipped=#{cadence.skipped_scheduled_runs} " <>
        "blocked=#{cadence.blocked_scheduled_runs} failed=#{cadence.failed_scheduled_runs} " <>
        "lock_loser_count=#{cadence.lock_loser_count}"
    )
  end

  defp scheduler_opts(opts) do
    case Keyword.get(opts, :scheduler) do
      nil -> []
      scheduler -> [scheduler: scheduler]
    end
  end

  defp rollup_opts(opts) do
    opts
    |> scheduler_opts()
    |> maybe_put(:trigger, Keyword.get(opts, :trigger))
  end

  defp put_gate(report) do
    blockers = gate_blockers(report)
    warnings = gate_warnings(report)

    report
    |> Map.put(:gate_status, gate_status(blockers, warnings))
    |> Map.put(:blockers, blockers)
    |> Map.put(:warnings, warnings)
  end

  defp gate_blockers(report) do
    report.states
    |> Enum.flat_map(&state_blocker/1)
    |> Kernel.++(cadence_blockers(Map.get(report, :cadence)))
  end

  defp gate_warnings(report) do
    []
    |> Kernel.++(Enum.flat_map(report.states, &state_warning/1))
    |> Kernel.++(Enum.flat_map(report.runs, &run_warning/1))
    |> Kernel.++(Enum.flat_map(report.rollups, &rollup_warning/1))
    |> Kernel.++(cadence_warnings(Map.get(report, :cadence)))
  end

  defp state_blocker(%{alert_status: "alert"} = state) do
    [
      %{
        scope: "state",
        scheduler: state.scheduler,
        reason: "scheduler_state_alert",
        status: state.status,
        alert_status: state.alert_status,
        last_run_id: state.last_run_id
      }
    ]
  end

  defp state_blocker(%{status: status} = state) when status in ["blocked", "failed"] do
    [
      %{
        scope: "state",
        scheduler: state.scheduler,
        reason: "scheduler_state_blocked",
        status: state.status,
        alert_status: state.alert_status,
        last_run_id: state.last_run_id
      }
    ]
  end

  defp state_blocker(_state), do: []

  defp state_warning(%{status: status} = state) when status in ["blocked", "failed"] do
    if state_blocker(state) == [] do
      [
        %{
          scope: "state",
          scheduler: state.scheduler,
          reason: "scheduler_state_problem",
          status: state.status,
          alert_status: state.alert_status,
          last_run_id: state.last_run_id
        }
      ]
    else
      []
    end
  end

  defp state_warning(%{alert_status: "warning"} = state) do
    [
      %{
        scope: "state",
        scheduler: state.scheduler,
        reason: "scheduler_state_warning",
        status: state.status,
        alert_status: state.alert_status,
        consecutive_failures: state.consecutive_failures
      }
    ]
  end

  defp state_warning(%{consecutive_failures: failures} = state)
       when is_integer(failures) and failures > 0 do
    [
      %{
        scope: "state",
        scheduler: state.scheduler,
        reason: "scheduler_state_failures_seen",
        status: state.status,
        consecutive_failures: failures
      }
    ]
  end

  defp state_warning(_state), do: []

  defp run_warning(%{status: status} = run) when status in ["blocked", "failed"] do
    [
      %{
        scope: "run",
        scheduler: run.scheduler,
        reason: "recent_problem_run",
        run_id: run.id,
        trigger: run.trigger,
        status: run.status,
        phase: run.phase,
        job_id: run.job_id
      }
    ]
  end

  defp run_warning(_run), do: []

  defp rollup_warning(rollup) do
    problem_count = Map.get(rollup, :blocked_count, 0) + Map.get(rollup, :failed_count, 0)

    if problem_count > 0 do
      [
        %{
          scope: "rollup",
          scheduler: rollup.scheduler,
          reason: "rollup_problem_runs_seen",
          trigger: rollup.trigger,
          rollup_id: Map.get(rollup, :id),
          blocked_count: Map.get(rollup, :blocked_count, 0),
          failed_count: Map.get(rollup, :failed_count, 0)
        }
      ]
    else
      []
    end
  end

  defp cadence_blockers(%{reports: reports}) do
    reports
    |> Enum.reject(&(&1.health == "ok"))
    |> Enum.map(fn cadence ->
      %{
        scope: "cadence",
        scheduler: cadence.scheduler,
        reason: "scheduler_cadence_not_healthy",
        health: cadence.health,
        cadence_reason: cadence.reason,
        state_status: cadence.state_status,
        alert_status: cadence.alert_status
      }
    end)
  end

  defp cadence_blockers(_cadence), do: []

  defp cadence_warnings(%{reports: reports}) do
    Enum.flat_map(reports, fn cadence ->
      []
      |> maybe_gate_warning(
        cadence.blocked_scheduled_runs > 0,
        %{
          scope: "cadence",
          scheduler: cadence.scheduler,
          reason: "blocked_scheduled_runs_seen",
          count: cadence.blocked_scheduled_runs
        }
      )
      |> maybe_gate_warning(
        cadence.failed_scheduled_runs > 0,
        %{
          scope: "cadence",
          scheduler: cadence.scheduler,
          reason: "failed_scheduled_runs_seen",
          count: cadence.failed_scheduled_runs
        }
      )
    end)
  end

  defp cadence_warnings(_cadence), do: []

  defp maybe_gate_warning(items, true, item), do: [item | items]
  defp maybe_gate_warning(items, false, _item), do: items

  defp gate_status([_ | _], _warnings), do: "blocked"
  defp gate_status([], [_ | _]), do: "attention"
  defp gate_status([], []), do: "ok"

  defp fail_if_needed!(%{gate_status: "blocked"}, opts) do
    if Keyword.get(opts, :fail_on_blocked, false) or Keyword.get(opts, :fail_on_attention, false) do
      Mix.raise("scheduler status blocked")
    end
  end

  defp fail_if_needed!(%{gate_status: "attention"}, opts) do
    if Keyword.get(opts, :fail_on_attention, false) do
      Mix.raise("scheduler status attention")
    end
  end

  defp fail_if_needed!(_report, _opts), do: :ok

  defp validate_scheduler!(nil), do: :ok
  defp validate_scheduler!("fresh_drive_heal"), do: :ok
  defp validate_scheduler!("rebalance"), do: :ok

  defp validate_scheduler!(scheduler) do
    Mix.raise("--scheduler must be fresh_drive_heal or rebalance, got #{inspect(scheduler)}")
  end

  defp validate_runs!(nil), do: :ok
  defp validate_runs!(value) when is_integer(value) and value > 0, do: :ok

  defp validate_runs!(value),
    do: Mix.raise("--runs must be a positive integer, got #{inspect(value)}")

  defp validate_trigger!(nil), do: :ok
  defp validate_trigger!("manual"), do: :ok
  defp validate_trigger!("scheduled"), do: :ok

  defp validate_trigger!(trigger) do
    Mix.raise("--trigger must be manual or scheduled, got #{inspect(trigger)}")
  end

  defp validate_rollup_limit!(nil), do: :ok
  defp validate_rollup_limit!(value) when is_integer(value) and value > 0, do: :ok

  defp validate_rollup_limit!(value),
    do: Mix.raise("--rollup-limit must be a positive integer, got #{inspect(value)}")

  defp validate_positive_int!(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> Mix.raise("#{flag} must be a positive integer, got #{inspect(value)}")
    end
  end

  defp cadence_opts(opts, parsed_opts) do
    opts
    |> maybe_put(:since_minutes, Keyword.get(parsed_opts, :since_minutes))
    |> maybe_put(:expected_interval_ms, Keyword.get(parsed_opts, :expected_interval_ms))
    |> maybe_put(:stale_after_ms, Keyword.get(parsed_opts, :stale_after_ms))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_value(nil), do: "nil"
  defp format_value(values) when is_list(values), do: format_list(values)
  defp format_value(value), do: to_string(value)

  defp format_list(values) when is_list(values), do: Enum.join(values, ",")
  defp format_list(_values), do: ""

  defp ensure_repo_started! do
    ensure_started!(:ecto_sql)
    ensure_started!(:postgrex)

    case Process.whereis(Maxio.Repo) do
      nil ->
        case Maxio.Repo.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> Mix.raise("failed to start Maxio.Repo: #{inspect(reason)}")
        end

      _pid ->
        :ok
    end
  end

  defp ensure_started!(application) do
    case Application.ensure_all_started(application) do
      {:ok, _apps} -> :ok
      {:error, {app, reason}} -> Mix.raise("failed to start #{inspect(app)}: #{inspect(reason)}")
    end
  end
end
