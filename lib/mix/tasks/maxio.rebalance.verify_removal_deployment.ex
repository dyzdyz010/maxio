defmodule Mix.Tasks.Maxio.Rebalance.VerifyRemovalDeployment do
  @shortdoc "Verify deployment config persisted a decommission topology removal"
  @moduledoc """
  Verify that deployment config now matches a previously applied decommission
  topology-removal artifact.

      mix maxio.rebalance.verify_removal_deployment [JOB_ID|--job-id <uuid>]
      mix maxio.rebalance.verify_removal_deployment --job-id <uuid> --json

  This command reads `config :maxio, Maxio.Cluster.Topology`, compares it to the
  job's recorded proposed topology hash, reruns PG/MPU placement guards against
  the deployed set list, and records a deployment-verification audit marker on
  the job. It does not rewrite deployment config, mutate runtime topology, delete
  shard data, or probe removed target-set drives.
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
        "usage: mix maxio.rebalance.verify_removal_deployment " <>
          "[JOB_ID|--job-id <uuid>] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    Mix.Task.run("app.start")

    with {:ok, job_id} <- resolve_job_id(job_id),
         {:ok, report} <- TopologyMutation.verify_removal_deployment(job_id) do
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
        "[maxio rebalance.verify_removal_deployment] job_id=#{report.job_id} " <>
          "status=#{report.status} target_set_id=#{report.target_set_id} " <>
          "expected_proposed_hash=#{report.expected_proposed_hash} " <>
          "deployment_topology_hash=#{report.deployment_topology_hash} " <>
          "deployment_set_ids=#{inspect(report.deployment_set_ids)} " <>
          "deployment_pool_ids=#{inspect(report.deployment_pool_ids)} " <>
          "target_set_configured=#{report.target_set_configured} " <>
          "write_routing_retired=#{report.write_routing_retired} " <>
          "topology_mutation=false deployment_config_mutation=false"
      )
    end
  end

  defp error_message(:not_found), do: "no decommission job found"

  defp error_message(:no_deployment_topology),
    do: "cannot verify removal without deployment topology config"

  defp error_message({:invalid_deployment_topology, reason}),
    do: "deployment topology config is invalid: #{reason}"

  defp error_message({:invalid_topology_revision_config, reason}),
    do: "active deployment topology revision is invalid: #{reason}"

  defp error_message({:topology_revision_hash_mismatch, stored, actual}) do
    "active deployment topology revision hash mismatch: stored=#{stored} actual=#{actual}"
  end

  defp error_message({:invalid_topology_source, source}),
    do: "invalid topology source #{inspect(source)}; expected :config or :db"

  defp error_message(:topology_removal_not_applied),
    do: "runtime topology removal has not been applied for this job"

  defp error_message(:topology_removal_cluster_not_converged),
    do: "cluster runtime topology convergence has not been recorded for this job"

  defp error_message(:missing_cluster_topology_hash),
    do: "job is missing the cluster topology convergence hash"

  defp error_message(:missing_cluster_topology_nodes),
    do: "job is missing the cluster topology convergence node roster"

  defp error_message(:runtime_topology_not_applied),
    do: "current runtime topology does not contain the applied removal"

  defp error_message({:runtime_topology_hash_mismatch, expected, actual}) do
    "runtime topology hash mismatch: expected proposed=#{expected} actual=#{actual}"
  end

  defp error_message({:cluster_runtime_topology_not_converged, report}) do
    "cluster runtime topology is not converged: failed_nodes=#{inspect(report.failed_nodes)} " <>
      "expected=#{report.expected_topology_hash}"
  end

  defp error_message(:topology_verify_locked),
    do: "could not acquire topology removal deployment verification lock"

  defp error_message(:missing_proposed_topology_hash),
    do: "job is missing the proposed topology hash recorded by apply_removal"

  defp error_message({:target_set_still_configured, set_id, set_ids}) do
    "deployment topology still contains target_set_id=#{inspect(set_id)} " <>
      "in set_ids=#{inspect(set_ids)}"
  end

  defp error_message({:deployment_topology_hash_mismatch, expected, actual}) do
    "deployment topology hash mismatch: expected proposed=#{expected} actual=#{actual}"
  end

  defp error_message({:deployment_verification_blocked, report}) do
    "deployment verification is blocked: blockers=#{inspect(report.blockers)} " <>
      "job_id=#{report.job_id}"
  end

  defp error_message(:topology_removal_deployment_already_verified),
    do: "deployment verification has already been recorded with a different hash"

  defp error_message({:unsupported_job_kind, kind}),
    do: "verify_removal_deployment only supports decommission jobs, got kind=#{inspect(kind)}"

  defp error_message(reason),
    do: "rebalance removal deployment verification failed: #{inspect(reason)}"

  defp json_ready(nil), do: nil
  defp json_ready(value) when is_boolean(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_ready()

  defp json_ready(value) when is_list(value) do
    cond do
      Keyword.keyword?(value) ->
        Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)

      true ->
        Enum.map(value, &json_ready/1)
    end
  end

  defp json_ready(%{} = value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)

  defp json_ready(value), do: value
end
