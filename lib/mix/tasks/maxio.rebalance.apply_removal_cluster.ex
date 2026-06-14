defmodule Mix.Tasks.Maxio.Rebalance.ApplyRemovalCluster do
  @shortdoc "Apply a completed decommission removal to cluster runtime topology"
  @moduledoc """
  Apply the proposed topology removal for a completed decommission job to all
  selected runtime nodes.

      mix maxio.rebalance.apply_removal_cluster --job-id <uuid> --yes
      mix maxio.rebalance.apply_removal_cluster <uuid> --nodes node1,node2 --yes --json

  This command reruns removal preflight under the global runtime-topology quorum
  lock, records the same runtime removal audit marker, and installs the proposed
  topology into each selected BEAM runtime. It does not rewrite deployment
  config, delete shard data, or provide Raft-style all-or-nothing consensus.
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
          expected_current_topology_hash: :string,
          nodes: :string,
          yes: :boolean,
          json: :boolean
        ]
      )

    job_id = Keyword.get(opts, :job_id) || List.first(rest)
    extra = if job_id && rest == [job_id], do: [], else: rest

    if extra != [] or invalid != [] do
      unexpected = extra ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.rebalance.apply_removal_cluster [JOB_ID|--job-id <uuid>] " <>
          "[--expected-current-topology-hash <sha256>] [--nodes <node1,node2>] --yes [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    unless Keyword.get(opts, :yes, false) do
      Mix.raise("cluster runtime topology removal apply requires --yes")
    end

    Mix.Task.run("app.start")

    with {:ok, nodes} <- parse_nodes(Keyword.get(opts, :nodes)),
         {:ok, job_id} <- resolve_job_id(job_id),
         {:ok, report} <-
           TopologyMutation.apply_removal_cluster(
             job_id,
             [
               expected_current_topology_hash: Keyword.get(opts, :expected_current_topology_hash)
             ] ++ maybe_nodes(nodes)
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

  defp parse_nodes(nil), do: {:ok, nil}

  defp parse_nodes(nodes_csv) when is_binary(nodes_csv) do
    known = Map.new(known_nodes(), &{Atom.to_string(&1), &1})

    nodes =
      nodes_csv
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    unknown = Enum.reject(nodes, &Map.has_key?(known, &1))

    if unknown == [] do
      {:ok, Enum.map(nodes, &Map.fetch!(known, &1))}
    else
      {:error, {:unknown_nodes, unknown, Map.keys(known) |> Enum.sort()}}
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

  defp maybe_nodes(nil), do: []
  defp maybe_nodes(nodes), do: [nodes: nodes]

  defp print_or_json(opts, report) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(json_ready(report)))
    else
      IO.puts(
        "[maxio rebalance.apply_removal_cluster] job_id=#{report.job_id} " <>
          "status=#{report.status} apply_scope=#{report.apply_scope} " <>
          "removed_set_id=#{report.removed_set_id} " <>
          "current_topology_hash=#{report.current_topology_hash} " <>
          "proposed_topology_hash=#{report.proposed_topology_hash} " <>
          "applied_nodes=#{inspect(report.applied_nodes)} " <>
          "topology_mutation=cluster_runtime deployment_config_mutation=false"
      )
    end
  end

  defp error_message(:not_found), do: "no decommission job found"

  defp error_message({:unknown_nodes, unknown, known}) do
    "unknown node name(s): #{Enum.join(unknown, ",")} known=#{inspect(known)}"
  end

  defp error_message({:cluster_topology_apply_failed, report}) do
    "cluster topology removal apply failed: failed_nodes=#{inspect(report.failed_nodes)} " <>
      "job_id=#{report.job_id}"
  end

  defp error_message({:preflight_blocked, report}) do
    "topology removal preflight is blocked: blockers=#{inspect(report.blockers)} " <>
      "job_id=#{report.job_id}"
  end

  defp error_message({:current_topology_hash_mismatch, expected, actual}) do
    "current topology hash mismatch: expected=#{inspect(expected)} actual=#{actual}"
  end

  defp error_message(:topology_apply_locked),
    do: "could not acquire topology removal cluster apply lock"

  defp error_message(:topology_removal_already_applied),
    do: "topology removal has already been applied for this job with different hashes"

  defp error_message(:would_remove_last_set),
    do: "cannot remove the last remaining erasure set from topology"

  defp error_message({:unsupported_job_kind, kind}),
    do: "apply_removal_cluster only supports decommission jobs, got kind=#{inspect(kind)}"

  defp error_message(:no_topology),
    do: "cannot apply topology removal without configured topology"

  defp error_message(reason), do: "rebalance removal cluster apply failed: #{inspect(reason)}"

  defp json_ready(nil), do: nil
  defp json_ready(value) when is_boolean(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_ready()

  defp json_ready(value) when is_list(value) do
    cond do
      endpoint_list?(value) ->
        Enum.map(value, fn {node, drive} ->
          %{"node" => Atom.to_string(node), "drive" => drive}
        end)

      Keyword.keyword?(value) ->
        Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)

      true ->
        Enum.map(value, &json_ready/1)
    end
  end

  defp json_ready(%{} = value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)

  defp json_ready(value), do: value

  defp endpoint_list?([]), do: false

  defp endpoint_list?(value) do
    Enum.all?(value, fn
      {node, drive} when is_atom(node) and is_binary(drive) -> true
      _other -> false
    end)
  end
end
