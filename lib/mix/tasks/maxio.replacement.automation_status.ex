defmodule Mix.Tasks.Maxio.Replacement.AutomationStatus do
  @shortdoc "Check read-only replacement automation readiness"
  @moduledoc """
  Check whether production fresh-drive replacement automation is configured as a
  complete chain.

      mix maxio.replacement.automation_status
      mix maxio.replacement.automation_status --json
      mix maxio.replacement.automation_status --fail-on-blocked --json
      mix maxio.replacement.automation_status --require-scheduler-evidence --since-minutes 120 --json

  This task is read-only. It does not start the application, start schedulers,
  run heal/rebalance work, write DB rows, mutate topology/deployment, or touch
  physical layout. Scheduler evidence mode starts Repo only to read the existing
  scheduler ledger.
  """

  use Mix.Task

  alias Maxio.Cluster.Replacement.AutomationProfile

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          fail_on_blocked: :boolean,
          fail_on_attention: :boolean,
          require_scheduler_evidence: :boolean,
          since_minutes: :integer,
          expected_interval_ms: :integer,
          stale_after_ms: :integer,
          expected_nodes: :string,
          min_effective_nodes: :integer,
          require_lock_loser: :boolean,
          json: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.replacement.automation_status " <>
          "[--fail-on-blocked] [--fail-on-attention] [--json] " <>
          "[--require-scheduler-evidence [--since-minutes N] " <>
          "[--expected-interval-ms N] [--stale-after-ms N] " <>
          "[--expected-nodes node_a,node_b] [--min-effective-nodes N] " <>
          "[--require-lock-loser]] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_positive_int!(opts, :since_minutes, "--since-minutes")
    validate_positive_int!(opts, :expected_interval_ms, "--expected-interval-ms")
    validate_positive_int!(opts, :stale_after_ms, "--stale-after-ms")
    validate_positive_int!(opts, :min_effective_nodes, "--min-effective-nodes")
    validate_scheduler_evidence_requested!(opts)

    require_scheduler_evidence? = Keyword.get(opts, :require_scheduler_evidence, false)

    if require_scheduler_evidence? do
      ensure_repo_started!()
    end

    report =
      AutomationProfile.status(
        require_scheduler_evidence?: require_scheduler_evidence?,
        scheduler_evidence_opts: scheduler_evidence_opts(opts)
      )

    print_or_json(report, opts)
    fail_if_needed!(report, opts)
  end

  defp print_or_json(report, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(json_ready(report)))
    else
      print_text(report)
    end
  end

  defp print_text(report) do
    IO.puts(
      "[maxio replacement.automation_status] status=#{report.status} " <>
        "ready=#{report.ready?} blockers=#{length(report.blockers)} " <>
        "warnings=#{length(report.warnings)} next_action=#{inspect(report.next_action)}"
    )

    fresh = report.checks.fresh_drive_heal_scheduler

    IO.puts(
      "[maxio replacement.automation_check] component=fresh_drive_heal_scheduler " <>
        "enabled=#{fresh.enabled} probe_drive_health=#{fresh.probe_drive_health} " <>
        "auto_rebalance_after_heal=#{fresh.auto_rebalance_after_heal} " <>
        "auto_advance_rebalance_after_heal=#{fresh.auto_advance_rebalance_after_heal} " <>
        "rebalance_advance_max_steps=#{fresh.rebalance_advance_max_steps} " <>
        "ledger_enabled=#{fresh.ledger_enabled}"
    )

    rebalance = report.checks.rebalance_scheduler

    IO.puts(
      "[maxio replacement.automation_check] component=rebalance_scheduler " <>
        "enabled=#{rebalance.enabled} auto_source_cleanup=#{rebalance.auto_source_cleanup} " <>
        "auto_rebalance_closure=#{rebalance.auto_rebalance_closure} " <>
        "ledger_enabled=#{rebalance.ledger_enabled}"
    )

    evidence = report.checks.scheduler_evidence

    IO.puts(
      "[maxio replacement.automation_check] component=scheduler_evidence " <>
        "required=#{Map.get(evidence, :required?)} status=#{Map.get(evidence, :status)} " <>
        "blockers=#{scheduler_evidence_count(evidence, :blockers)} " <>
        "warnings=#{scheduler_evidence_count(evidence, :warnings)}"
    )

    Enum.each(report.blockers, fn blocker ->
      IO.puts("[maxio replacement.automation_blocker] reason=#{blocker}")
    end)

    Enum.each(report.warnings, fn warning ->
      IO.puts("[maxio replacement.automation_warning] reason=#{warning}")
    end)
  end

  defp fail_if_needed!(%{status: :blocked}, opts) do
    if Keyword.get(opts, :fail_on_blocked, false) or Keyword.get(opts, :fail_on_attention, false) do
      Mix.raise("replacement automation blocked")
    end
  end

  defp fail_if_needed!(%{status: :attention}, opts) do
    if Keyword.get(opts, :fail_on_attention, false) do
      Mix.raise("replacement automation attention")
    end
  end

  defp fail_if_needed!(_report, _opts), do: :ok

  defp json_ready(value) when is_boolean(value) or is_nil(value), do: value
  defp json_ready(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(values) when is_list(values), do: Enum.map(values, &json_ready/1)

  defp json_ready(%{} = value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)
  end

  defp json_ready(value), do: value

  defp scheduler_evidence_opts(opts) do
    []
    |> maybe_put(:since_minutes, Keyword.get(opts, :since_minutes))
    |> maybe_put(:expected_interval_ms, Keyword.get(opts, :expected_interval_ms))
    |> maybe_put(:stale_after_ms, Keyword.get(opts, :stale_after_ms))
    |> maybe_put(:expected_nodes, parse_expected_nodes(Keyword.get(opts, :expected_nodes)))
    |> maybe_put(:min_effective_nodes, Keyword.get(opts, :min_effective_nodes))
    |> Keyword.put(:require_lock_loser?, Keyword.get(opts, :require_lock_loser, false))
  end

  defp scheduler_evidence_count(%{report: report}, key) when is_map(report) do
    report
    |> Map.get(key, Map.get(report, to_string(key), []))
    |> length_or_zero()
  end

  defp scheduler_evidence_count(_evidence, _key), do: 0

  defp length_or_zero(values) when is_list(values), do: length(values)
  defp length_or_zero(_values), do: 0

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

  defp validate_scheduler_evidence_requested!(opts) do
    evidence_keys = [
      :since_minutes,
      :expected_interval_ms,
      :stale_after_ms,
      :expected_nodes,
      :min_effective_nodes,
      :require_lock_loser
    ]

    evidence_option? = Enum.any?(evidence_keys, &Keyword.has_key?(opts, &1))

    if evidence_option? and not Keyword.get(opts, :require_scheduler_evidence, false) do
      Mix.raise("scheduler evidence options require --require-scheduler-evidence")
    end
  end

  defp validate_positive_int!(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> Mix.raise("#{flag} must be a positive integer, got #{inspect(value)}")
    end
  end

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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
