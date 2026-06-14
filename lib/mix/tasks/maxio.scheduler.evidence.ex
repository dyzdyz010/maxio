defmodule Mix.Tasks.Maxio.Scheduler.Evidence do
  @shortdoc "Check read-only long-run scheduler evidence"
  @moduledoc """
  Build a read-only scheduler long-run evidence gate from the persistent ledger.

      mix maxio.scheduler.evidence --scheduler rebalance --from 2026-06-14T00:00:00Z --until 2026-06-14T02:00:00Z --expected-nodes node_a,node_b --min-effective-nodes 1 --require-lock-loser --json
      mix maxio.scheduler.evidence --scheduler fresh_drive_heal --since-minutes 120 --expected-interval-ms 60000 --stale-after-ms 120000

  This task never starts schedulers, runs heal/rebalance work, writes ledger rows,
  prunes rows, or changes topology/physical state. Use `--fail-on-attention`
  when long-run rehearsal automation should treat warnings as a non-zero gate.
  """

  use Mix.Task

  alias Maxio.Cluster.SchedulerRuns

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          scheduler: :string,
          from: :string,
          until: :string,
          since_minutes: :integer,
          window_minutes: :integer,
          expected_interval_ms: :integer,
          stale_after_ms: :integer,
          expected_nodes: :string,
          min_effective_nodes: :integer,
          require_lock_loser: :boolean,
          require_rollups: :boolean,
          fail_on_attention: :boolean,
          json: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.scheduler.evidence [--scheduler fresh_drive_heal|rebalance] " <>
          "[--from <iso8601>] [--until <iso8601>] [--since-minutes N] " <>
          "[--window-minutes N] [--expected-interval-ms N] [--stale-after-ms N] " <>
          "[--expected-nodes node_a,node_b] [--min-effective-nodes N] " <>
          "[--require-lock-loser] [--require-rollups] [--fail-on-attention] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_scheduler!(Keyword.get(opts, :scheduler))
    validate_positive_int!(opts, :since_minutes, "--since-minutes")
    validate_positive_int!(opts, :window_minutes, "--window-minutes")
    validate_positive_int!(opts, :expected_interval_ms, "--expected-interval-ms")
    validate_positive_int!(opts, :stale_after_ms, "--stale-after-ms")
    validate_positive_int!(opts, :min_effective_nodes, "--min-effective-nodes")
    validate_since_or_from!(opts)

    ensure_repo_started!()

    evidence_opts =
      []
      |> maybe_put(:scheduler, Keyword.get(opts, :scheduler))
      |> maybe_put(:from, parse_datetime(Keyword.get(opts, :from), "--from"))
      |> maybe_put(:until, parse_datetime(Keyword.get(opts, :until), "--until"))
      |> maybe_put(:since_minutes, Keyword.get(opts, :since_minutes))
      |> maybe_put(:window_ms, window_ms(opts))
      |> maybe_put(:expected_interval_ms, Keyword.get(opts, :expected_interval_ms))
      |> maybe_put(:stale_after_ms, Keyword.get(opts, :stale_after_ms))
      |> maybe_put(:expected_nodes, parse_expected_nodes(Keyword.get(opts, :expected_nodes)))
      |> maybe_put(:min_effective_nodes, Keyword.get(opts, :min_effective_nodes))
      |> Keyword.put(:require_lock_loser?, Keyword.get(opts, :require_lock_loser, false))
      |> Keyword.put(:require_rollups?, Keyword.get(opts, :require_rollups, false))

    case SchedulerRuns.evidence_report(evidence_opts) do
      {:ok, report} ->
        view = SchedulerRuns.evidence_to_view(report)
        print_or_json(view, opts)

        fail_if_needed!(view, opts)

      {:error, reason} ->
        Mix.raise("scheduler evidence failed: #{inspect(reason)}")
    end
  end

  defp print_or_json(report, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(report))
    else
      print_text(report)
    end
  end

  defp print_text(report) do
    IO.puts(
      "[maxio scheduler.evidence] status=#{report.status} from=#{report.from} " <>
        "until=#{report.until} window_ms=#{report.window_ms} " <>
        "schedulers=#{length(report.schedulers)} blockers=#{length(report.blockers)} " <>
        "warnings=#{length(report.warnings)}"
    )

    Enum.each(report.schedulers, fn scheduler ->
      cadence = scheduler.cadence

      IO.puts(
        "[maxio scheduler.evidence.scheduler] scheduler=#{scheduler.scheduler} " <>
          "status=#{scheduler.status} health=#{cadence.health} reason=#{cadence.reason} " <>
          "expected_nodes=#{format_list(scheduler.expected_nodes)} " <>
          "missing_expected_nodes=#{format_list(scheduler.missing_expected_nodes)} " <>
          "effective_nodes=#{format_list(scheduler.effective_scheduled_nodes)} " <>
          "min_effective_nodes=#{scheduler.min_effective_nodes} " <>
          "lock_losers=#{format_list(scheduler.lock_loser_nodes)} " <>
          "blocked_runs=#{scheduler.blocked_runs} failed_runs=#{scheduler.failed_runs}"
      )

      Enum.each(scheduler.next_actions, fn action ->
        IO.puts(
          "[maxio scheduler.evidence.next_action] scheduler=#{scheduler.scheduler} " <>
            "run_id=#{action.run_id} phase=#{format_value(action.phase)} " <>
            "job_id=#{format_value(action.job_id)} action=#{inspect(action.action)}"
        )
      end)

      Enum.each(scheduler.blockers, fn blocker ->
        IO.puts(
          "[maxio scheduler.evidence.blocker] scheduler=#{scheduler.scheduler} " <>
            "reason=#{format_value(blocker.reason)}"
        )
      end)

      Enum.each(scheduler.warnings, fn warning ->
        IO.puts(
          "[maxio scheduler.evidence.warning] scheduler=#{scheduler.scheduler} " <>
            "reason=#{format_value(warning.reason)}"
        )
      end)
    end)
  end

  defp fail_if_needed!(%{status: "blocked"}, _opts), do: Mix.raise("scheduler evidence blocked")

  defp fail_if_needed!(%{status: "attention"}, opts) do
    if Keyword.get(opts, :fail_on_attention, false) do
      Mix.raise("scheduler evidence attention")
    end
  end

  defp fail_if_needed!(_report, _opts), do: :ok

  defp parse_datetime(nil, _flag), do: nil

  defp parse_datetime(value, flag) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, 0} -> dt
      {:ok, _dt, _offset} -> Mix.raise("#{flag} must be UTC ISO8601 with Z offset")
      {:error, reason} -> Mix.raise("#{flag} must be ISO8601 datetime: #{inspect(reason)}")
    end
  end

  defp parse_expected_nodes(nil), do: nil

  defp parse_expected_nodes(value) do
    nodes =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case nodes do
      [] -> Mix.raise("--expected-nodes must contain at least one node")
      nodes -> nodes
    end
  end

  defp window_ms(opts) do
    case Keyword.get(opts, :window_minutes) do
      nil -> nil
      minutes -> minutes * 60 * 1_000
    end
  end

  defp validate_since_or_from!(opts) do
    if Keyword.has_key?(opts, :from) and Keyword.has_key?(opts, :since_minutes) do
      Mix.raise("--from and --since-minutes cannot be used together")
    end
  end

  defp validate_scheduler!(nil), do: :ok
  defp validate_scheduler!("fresh_drive_heal"), do: :ok
  defp validate_scheduler!("rebalance"), do: :ok

  defp validate_scheduler!(scheduler) do
    Mix.raise("--scheduler must be fresh_drive_heal or rebalance, got #{inspect(scheduler)}")
  end

  defp validate_positive_int!(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> Mix.raise("#{flag} must be a positive integer, got #{inspect(value)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

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

  defp format_list(values) when is_list(values), do: Enum.join(values, ",")
  defp format_list(_values), do: ""

  defp format_value(nil), do: "nil"
  defp format_value(value), do: to_string(value)
end
