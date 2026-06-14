defmodule Mix.Tasks.Maxio.Rebalance.PersistRemovalDeployment do
  @shortdoc "Persist a decommission removal as the active DB deployment topology"
  @moduledoc """
  Persist the current converged runtime topology as the active DB-backed
  deployment topology revision for a completed decommission removal.

      mix maxio.rebalance.persist_removal_deployment --job-id <uuid> --runtime-node maxio@host --expected-proposed-topology-hash <sha256> --yes
      mix maxio.rebalance.persist_removal_deployment <uuid> --runtime-node maxio@host --expected-proposed-topology-hash <sha256> --yes --json

  This command does not delete shard data, mutate runtime topology, or mark
  deployment verification complete. It only writes an immutable control-plane
  topology revision after the job has completed, source cleanup has completed,
  cluster runtime convergence is recorded, and the current runtime topology hash
  matches the reviewed proposed hash.
  """
  use Mix.Task

  alias Maxio.Cluster.Topology
  alias Maxio.Cluster.Rebalance.{Jobs, TopologyMutation}

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          job_id: :string,
          runtime_node: :string,
          expected_proposed_topology_hash: :string,
          yes: :boolean,
          json: :boolean
        ]
      )

    job_id = Keyword.get(opts, :job_id) || List.first(rest)
    extra = if job_id && rest == [job_id], do: [], else: rest

    if extra != [] or invalid != [] do
      unexpected = extra ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.rebalance.persist_removal_deployment [JOB_ID|--job-id <uuid>] " <>
          "--runtime-node <node> --expected-proposed-topology-hash <sha256> --yes [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    unless Keyword.get(opts, :yes, false) do
      Mix.raise("deployment topology revision persistence requires --yes")
    end

    expected_hash =
      Keyword.get(opts, :expected_proposed_topology_hash) ||
        Mix.raise(
          "deployment topology revision persistence requires --expected-proposed-topology-hash"
        )

    Mix.Task.run("app.start")

    with {:ok, job_id} <- resolve_job_id(job_id),
         {:ok, runtime_node} <- parse_runtime_node(Keyword.get(opts, :runtime_node)),
         {:ok, runtime_topology} <- fetch_runtime_topology(runtime_node),
         {:ok, report} <-
           TopologyMutation.persist_removal_deployment(job_id,
             expected_proposed_topology_hash: expected_hash,
             runtime_topology: runtime_topology,
             nodes: [runtime_node]
           ) do
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

  defp parse_runtime_node(nil), do: {:error, :missing_runtime_node}

  defp parse_runtime_node(node_name) when is_binary(node_name) do
    known = Map.new(known_nodes(), &{Atom.to_string(&1), &1})

    case Map.fetch(known, node_name) do
      {:ok, node} -> {:ok, node}
      :error -> {:error, {:unknown_runtime_node, node_name, Map.keys(known) |> Enum.sort()}}
    end
  end

  defp known_nodes do
    topology_nodes =
      if Topology.configured?() do
        Topology.all_set_ids()
        |> Enum.flat_map(&Topology.endpoints/1)
        |> Enum.map(fn {node, _drive} -> node end)
      else
        []
      end

    ([Node.self() | Node.list()] ++ topology_nodes)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp fetch_runtime_topology(node) do
    if node == Node.self() do
      Topology.current()
    else
      with :ok <- ensure_runtime_node_reachable(node) do
        case runtime_topology_on_node(node) do
          {:ok, topology} -> {:ok, topology}
          {:error, reason} -> {:error, {:runtime_node_topology_unavailable, node, reason}}
          other -> {:error, {:invalid_runtime_node_topology_result, node, other}}
        end
      end
    end
  end

  defp ensure_runtime_node_reachable(node) do
    case Node.ping(node) do
      :pong -> :ok
      :pang -> {:error, {:runtime_node_unavailable, node}}
    end
  end

  defp runtime_topology_on_node(node) do
    :erpc.call(node, Topology, :current, [], 5_000)
  catch
    :error, reason -> {:error, {:unavailable, reason}}
    :exit, reason -> {:error, {:unavailable, reason}}
    :throw, reason -> {:error, {:unavailable, reason}}
  end

  defp print_or_json(opts, report) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(json_ready(report)))
    else
      IO.puts(
        "[maxio rebalance.persist_removal_deployment] job_id=#{report.job_id} " <>
          "status=#{report.status} target_set_id=#{report.target_set_id} " <>
          "expected_proposed_hash=#{report.expected_proposed_hash} " <>
          "deployment_topology_hash=#{report.deployment_topology_hash} " <>
          "deployment_set_ids=#{inspect(report.deployment_set_ids)} " <>
          "deployment_pool_ids=#{inspect(report.deployment_pool_ids)} " <>
          "revision_id=#{report.revision_id} revision_source=#{report.revision_source} " <>
          "topology_mutation=false deployment_config_mutation=db_active_revision"
      )
    end
  end

  defp error_message(:not_found), do: "no decommission job found"

  defp error_message(:missing_runtime_node),
    do:
      "deployment topology revision persistence requires --runtime-node <node>; " <>
        "run the task from a distributed VM connected to the live maxio node"

  defp error_message({:unknown_runtime_node, node, known}) do
    "unknown runtime node #{inspect(node)}; known=#{inspect(known)}"
  end

  defp error_message({:runtime_node_unavailable, node}) do
    "runtime node #{inspect(node)} is not reachable; start the task with --name/--sname and matching cookie"
  end

  defp error_message({:runtime_node_topology_unavailable, node, reason}) do
    "runtime node #{inspect(node)} did not return a topology: #{inspect(reason)}"
  end

  defp error_message({:invalid_runtime_node_topology_result, node, result}) do
    "runtime node #{inspect(node)} returned invalid topology result: #{inspect(result)}"
  end

  defp error_message(:topology_persist_locked),
    do: "could not acquire topology removal deployment persistence lock"

  defp error_message(:missing_expected_proposed_topology_hash),
    do: "missing required --expected-proposed-topology-hash"

  defp error_message(:missing_proposed_topology_hash),
    do: "job is missing the proposed topology hash recorded by apply_removal"

  defp error_message({:proposed_topology_hash_mismatch, proposed, expected}) do
    "expected proposed topology hash mismatch: job_proposed=#{proposed} cli_expected=#{expected}"
  end

  defp error_message(:topology_removal_not_applied),
    do: "runtime topology removal has not been applied for this job"

  defp error_message(:topology_removal_cluster_not_converged),
    do: "cluster runtime topology convergence has not been recorded for this job"

  defp error_message(:missing_cluster_topology_hash),
    do: "job is missing the cluster topology convergence hash"

  defp error_message(:missing_cluster_topology_nodes),
    do: "job is missing the cluster topology convergence node roster"

  defp error_message({:cluster_runtime_topology_not_converged, report}) do
    "cluster runtime topology is not converged: failed_nodes=#{inspect(report.failed_nodes)} " <>
      "expected=#{report.expected_topology_hash}"
  end

  defp error_message({:target_set_still_configured, set_id, set_ids}) do
    "runtime topology still contains target_set_id=#{inspect(set_id)} in set_ids=#{inspect(set_ids)}"
  end

  defp error_message({:deployment_topology_hash_mismatch, expected, actual}) do
    "runtime topology hash mismatch: expected proposed=#{expected} actual=#{actual}"
  end

  defp error_message({:deployment_persistence_blocked, report}) do
    "deployment topology persistence is blocked: blockers=#{inspect(report.blockers)} " <>
      "job_id=#{report.job_id}"
  end

  defp error_message({:topology_revision_expected_hash_mismatch, expected, actual}) do
    "topology revision hash mismatch: expected=#{expected} actual=#{actual}"
  end

  defp error_message({:unsupported_job_kind, kind}),
    do: "persist_removal_deployment only supports decommission jobs, got kind=#{inspect(kind)}"

  defp error_message(:no_topology),
    do: "cannot persist deployment topology without configured runtime topology"

  defp error_message(reason),
    do: "rebalance removal deployment persistence failed: #{inspect(reason)}"

  defp json_ready(nil), do: nil
  defp json_ready(value) when is_boolean(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_ready()
  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)

  defp json_ready(%{} = value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)

  defp json_ready(value), do: value
end
