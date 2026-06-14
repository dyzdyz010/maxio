defmodule Mix.Tasks.Maxio.Rebalance.PreflightRemoval do
  @shortdoc "Preflight a completed decommission set for topology removal"
  @moduledoc """
  Run the read-only safety preflight before removing a decommissioned set from
  topology configuration.

      mix maxio.rebalance.preflight_removal --job-id <uuid>
      mix maxio.rebalance.preflight_removal <uuid> --json

  The command verifies the decommission job state, placement metadata contract,
  active multipart uploads, target-set reachability, and physical residual
  evidence. It does not mutate topology, remove pools, or delete shards.
  """
  use Mix.Task

  alias Maxio.Cluster.Rebalance.{Jobs, TopologyMutation}

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          job_id: :string,
          json: :boolean
        ]
      )

    job_id = Keyword.get(opts, :job_id) || List.first(rest)
    extra = if job_id && rest == [job_id], do: [], else: rest

    if extra != [] or invalid != [] do
      unexpected = extra ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.rebalance.preflight_removal [JOB_ID|--job-id <uuid>] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    Mix.Task.run("app.start")

    with {:ok, job_id} <- resolve_job_id(job_id),
         {:ok, report} <- TopologyMutation.removal_preflight(job_id) do
      print_or_json(opts, report)
    else
      {:error, reason} -> Mix.raise(error_message(reason))
    end
  end

  defp resolve_job_id(job_id) when is_binary(job_id), do: {:ok, job_id}

  defp resolve_job_id(nil) do
    case Jobs.latest(kind: "decommission") do
      nil -> {:error, :not_found}
      job -> {:ok, job.id}
    end
  end

  defp print_or_json(opts, report) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(json_ready(report)))
    else
      IO.puts(
        "[maxio rebalance.preflight_removal] job_id=#{report.job_id} " <>
          "status=#{report.status} target_set_id=#{report.target_set_id} " <>
          "destination_set_id=#{report.destination_set_id} removable=#{report.removable} " <>
          "blockers=#{inspect(report.blockers)} " <>
          "pg_placements_remaining=#{report.pg_placements_remaining} " <>
          "missing_placements=#{report.missing_placements} " <>
          "unknown_placements=#{report.unknown_placements} " <>
          "active_multipart_uploads=#{report.active_multipart_uploads} " <>
          "physical_residuals=#{report.physical_residuals} " <>
          "physical_bucket_roots=#{report.physical_bucket_roots} " <>
          "physical_version_roots=#{report.physical_version_roots} " <>
          "endpoint_errors=#{report.endpoint_errors} bucket_markers=#{report.bucket_markers} " <>
          "topology_mutation=false"
      )
    end
  end

  defp error_message(:not_found), do: "no decommission job found"

  defp error_message(:no_topology),
    do: "cannot preflight topology removal without configured topology"

  defp error_message(:missing_target_set_id), do: "decommission job has no target_set_id"

  defp error_message({:unsupported_job_kind, kind}),
    do: "preflight_removal only supports decommission jobs, got kind=#{inspect(kind)}"

  defp error_message({:unknown_target_set_id, set_id, set_ids}) do
    "job target_set_id=#{inspect(set_id)} is not in configured set ids: #{inspect(set_ids)}"
  end

  defp error_message(reason), do: "rebalance removal preflight failed: #{inspect(reason)}"

  defp json_ready(nil), do: nil
  defp json_ready(value) when is_boolean(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)

  defp json_ready(%{} = value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)

  defp json_ready(value), do: value
end
