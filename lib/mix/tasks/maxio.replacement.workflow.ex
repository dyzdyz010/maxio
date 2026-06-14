defmodule Mix.Tasks.Maxio.Replacement.Workflow do
  @shortdoc "Audit or explicitly advance the fresh-drive replacement workflow"
  @moduledoc """
  Audit or explicitly advance the fresh-drive replacement workflow.

      mix maxio.replacement.workflow
      mix maxio.replacement.workflow --probe
      mix maxio.replacement.workflow --heal --rebalance-if-needed
      mix maxio.replacement.workflow --heal --rebalance-if-needed --advance-steps 2
      mix maxio.replacement.workflow --heal --rebalance-if-needed --verify-closure --json

  Default mode is read-only. Mutating work requires explicit flags. This task
  never invokes decommission, topology mutation, deployment finalization,
  physical removal, or purge. Use `--fail-on-blocked` when rehearsal automation
  should treat blocked/failed reports as a non-zero gate.
  """

  use Mix.Task

  alias Maxio.Cluster.Replacement.Workflow

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          probe: :boolean,
          heal: :boolean,
          dry_run: :boolean,
          rebalance_if_needed: :boolean,
          advance_steps: :integer,
          verify_closure: :boolean,
          bucket: :string,
          max_objects: :integer,
          page_size: :integer,
          audit_page_size: :integer,
          scan_current_only: :boolean,
          fail_on_blocked: :boolean,
          json: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.replacement.workflow [--probe] [--heal] [--dry-run] " <>
          "[--rebalance-if-needed] [--advance-steps N] [--verify-closure] " <>
          "[--bucket <name>] [--max-objects N] [--page-size N] " <>
          "[--audit-page-size N] [--scan-current-only] [--fail-on-blocked] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_positive!(opts, :advance_steps, "--advance-steps")
    validate_positive!(opts, :max_objects, "--max-objects")
    validate_positive!(opts, :page_size, "--page-size")
    validate_positive!(opts, :audit_page_size, "--audit-page-size")

    workflow_opts = workflow_opts(opts)
    ensure_minimal_runtime_started!(workflow_opts)

    case Workflow.run(workflow_opts) do
      {:ok, report} ->
        print_or_json(report, opts)
        fail_if_needed!(report, opts)

      {:error, reason} ->
        Mix.raise(error_message(reason))
    end
  end

  defp workflow_opts(opts) do
    [
      probe: Keyword.get(opts, :probe, false),
      heal: Keyword.get(opts, :heal, false),
      dry_run: Keyword.get(opts, :dry_run, false),
      rebalance_if_needed:
        Keyword.get(opts, :rebalance_if_needed, false) or
          Keyword.has_key?(opts, :advance_steps) or Keyword.get(opts, :verify_closure, false),
      advance_steps: Keyword.get(opts, :advance_steps),
      verify_closure: Keyword.get(opts, :verify_closure, false),
      bucket: Keyword.get(opts, :bucket),
      max_objects: Keyword.get(opts, :max_objects),
      page_size: Keyword.get(opts, :page_size),
      audit_page_size: Keyword.get(opts, :audit_page_size),
      scan_versions: not Keyword.get(opts, :scan_current_only, false)
    ]
    |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp print_or_json(report, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(json_ready(report)))
    else
      IO.puts(
        "[maxio replacement.workflow] status=#{report.status} phase=#{report.phase} " <>
          "mutating=#{report.mutating?} " <>
          "drive_heal_required=#{report.drive_health_after.heal_required} " <>
          "identity_heal_required=#{report.drive_health_after.identity_heal_required} " <>
          "probe_status=#{status(report.probe)} " <>
          "heal_status=#{status(report.heal)} " <>
          "drives_cleared=#{Map.get(report.heal, :drives_cleared, 0)} " <>
          "rebalance_enqueue_status=#{status(report.rebalance_enqueue)} " <>
          "rebalance_job_id=#{format_value(report.job_id)} " <>
          "rebalance_advance_status=#{status(report.rebalance_advance)} " <>
          "rebalance_advance_steps=#{Map.get(report.rebalance_advance, :steps, 0)} " <>
          "rebalance_workflow_status=#{status(report.rebalance_workflow)} " <>
          "automation_status=#{status(report.automation_profile)} " <>
          "automation_blockers=#{length(Map.get(report.automation_profile, :blockers, []))} " <>
          "blockers=#{inspect(report.blockers)} " <>
          "next_action=#{inspect(report.next_action)}"
      )
    end
  end

  defp status(%{status: status}), do: status
  defp status(_value), do: :unknown

  defp format_value(nil), do: "nil"
  defp format_value(value), do: to_string(value)

  defp validate_positive!(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> Mix.raise("#{flag} must be a positive integer, got #{inspect(value)}")
    end
  end

  defp ensure_minimal_runtime_started!(workflow_opts) do
    ensure_repo_started!()
    ensure_named_started!(Maxio.Cluster.Topology)
    ensure_named_started!(Maxio.Cluster.DriveHealth)

    if Keyword.get(workflow_opts, :heal, false) do
      ensure_named_started!(Maxio.Cluster.LockServer)
      ensure_named_started!(Maxio.Cluster.ShardServer)
      ensure_named_started!(Maxio.Cluster.FreshDriveHeal.Scheduler, enabled: false)
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

  defp ensure_named_started!(module, opts \\ []) do
    case Process.whereis(module) do
      nil ->
        case module.start_link(opts) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> Mix.raise("failed to start #{inspect(module)}: #{inspect(reason)}")
        end

      _pid ->
        :ok
    end
  end

  defp fail_if_needed!(report, opts) do
    if Keyword.get(opts, :fail_on_blocked, false) and status(report) in [:blocked, :failed] do
      Mix.raise("replacement workflow #{status(report)}")
    end
  end

  defp error_message(:advance_requires_heal),
    do: "--advance-steps and --verify-closure require --heal"

  defp error_message(:rebalance_requires_heal),
    do: "--rebalance-if-needed requires --heal"

  defp error_message({:invalid_advance_steps, value}),
    do: "--advance-steps must be a positive integer, got #{inspect(value)}"

  defp error_message(reason), do: "replacement workflow failed: #{inspect(reason)}"

  defp json_ready(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_ready(value) when is_boolean(value) or is_nil(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_ready()
  defp json_ready(values) when is_list(values), do: Enum.map(values, &json_ready/1)

  defp json_ready(%{} = value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)
  end

  defp json_ready(value), do: value
end
