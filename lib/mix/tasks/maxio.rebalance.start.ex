defmodule Mix.Tasks.Maxio.Rebalance.Start do
  @shortdoc "Create a planned rebalance/decommission job"
  @moduledoc """
  Create a persistent rebalance/decommission control-plane job.

      mix maxio.rebalance.start
      mix maxio.rebalance.start --decommission-set 1
      mix maxio.rebalance.start --no-drive-stats
      mix maxio.rebalance.start --json

  This stores a plan snapshot and job row only. It does not move shards yet.
  Job creation shares the runtime-topology mutation lock used by explicit
  topology removal apply. Jobs with placement fallback rows are refused because
  future movement needs persisted source placement.
  """
  use Mix.Task

  alias Maxio.Cluster.Rebalance.Jobs

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          decommission_set: :integer,
          current_only: :boolean,
          page_size: :integer,
          no_drive_stats: :boolean,
          json: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.rebalance.start [--decommission-set <id>] [--current-only] " <>
          "[--page-size <n>] [--no-drive-stats] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_positive!(opts, :page_size, "--page-size")
    Mix.Task.run("app.start")

    start_opts = [
      decommission_set: Keyword.get(opts, :decommission_set),
      current_only: Keyword.get(opts, :current_only, false),
      page_size: Keyword.get(opts, :page_size),
      include_drive_stats: not Keyword.get(opts, :no_drive_stats, false),
      requested_by: "mix maxio.rebalance.start"
    ]

    case Jobs.start(start_opts) do
      {:ok, job} ->
        if Keyword.get(opts, :json, false) do
          IO.puts(Jason.encode!(Jobs.to_view(job)))
        else
          print_job("start", job)
        end

      {:error, reason} ->
        Mix.raise(error_message(reason))
    end
  end

  defp print_job(action, job) do
    IO.puts(
      "[maxio rebalance.#{action}] job_id=#{job.id} kind=#{job.kind} status=#{job.status} " <>
        "data_movement=false data_movement_status=#{job.data_movement_status} " <>
        "target_set_id=#{format_value(job.target_set_id)} " <>
        "plan_status=#{job.plan_status} scanned=#{job.plan_scanned} bytes=#{job.plan_bytes} " <>
        "placement_fallbacks=#{job.plan_placement_fallbacks}"
    )
  end

  defp error_message({:active_job_exists, job}) do
    "active rebalance/decommission job already exists: job_id=#{job.id} kind=#{job.kind} status=#{job.status}"
  end

  defp error_message({:placement_fallbacks, count}) do
    "cannot create movement job while placement_fallbacks=#{count}; backfill or reconcile object placement first"
  end

  defp error_message(:no_topology), do: "cannot create rebalance job without configured topology"

  defp error_message(:decommission_requires_versions) do
    "cannot create decommission job with --current-only; decommission jobs must scan all versions and delete markers"
  end

  defp error_message({:unknown_set_id, set_id, set_ids}) do
    "unknown --decommission-set #{inspect(set_id)}; configured set ids: #{inspect(set_ids)}"
  end

  defp error_message({:invalid_target_set_id, value}),
    do: "invalid --decommission-set #{inspect(value)}"

  defp error_message(:missing_target_set_id), do: "missing --decommission-set"

  defp error_message(:topology_mutation_locked),
    do: "cannot create rebalance/decommission job while runtime topology mutation is locked"

  defp error_message(reason), do: "rebalance start failed: #{inspect(reason)}"

  defp validate_positive!(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> Mix.raise("#{flag} must be a positive integer, got #{inspect(value)}")
    end
  end

  defp format_value(nil), do: "nil"
  defp format_value(value), do: to_string(value)
end
