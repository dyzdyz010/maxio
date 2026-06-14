defmodule Mix.Tasks.Maxio.Rebalance.ApplyRemoval do
  @shortdoc "Apply a completed decommission removal to runtime topology"
  @moduledoc """
  Apply the proposed topology removal for a completed decommission job to the
  current BEAM runtime.

      mix maxio.rebalance.apply_removal --job-id <uuid> --yes
      mix maxio.rebalance.apply_removal <uuid> --expected-current-topology-hash <sha256> --yes --json

  This command reruns removal preflight under the global runtime-topology quorum
  lock and then mutates only runtime topology on this node. It does not rewrite
  deployment config, delete shard data, or make the scheduler mutate topology.
  """
  use Mix.Task

  alias Maxio.Cluster.Rebalance.{Jobs, TopologyMutation}

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          job_id: :string,
          expected_current_topology_hash: :string,
          yes: :boolean,
          json: :boolean
        ]
      )

    job_id = Keyword.get(opts, :job_id) || List.first(rest)
    extra = if job_id && rest == [job_id], do: [], else: rest

    if extra != [] or invalid != [] do
      unexpected = extra ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.rebalance.apply_removal [JOB_ID|--job-id <uuid>] " <>
          "[--expected-current-topology-hash <sha256>] --yes [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    unless Keyword.get(opts, :yes, false) do
      Mix.raise("runtime topology removal apply requires --yes")
    end

    Mix.Task.run("app.start")

    apply_opts = [
      expected_current_topology_hash: Keyword.get(opts, :expected_current_topology_hash)
    ]

    with {:ok, job_id} <- resolve_job_id(job_id),
         {:ok, report} <- TopologyMutation.apply_removal(job_id, apply_opts) do
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
        "[maxio rebalance.apply_removal] job_id=#{report.job_id} status=#{report.status} " <>
          "apply_scope=#{report.apply_scope} removed_set_id=#{report.removed_set_id} " <>
          "removed_pool_id=#{report.removed_pool_id} removed_pool_ids=#{inspect(report.removed_pool_ids)} " <>
          "current_topology_hash=#{report.current_topology_hash} " <>
          "proposed_topology_hash=#{report.proposed_topology_hash} " <>
          "current_set_ids=#{inspect(report.current_set_ids)} " <>
          "proposed_set_ids=#{inspect(report.proposed_set_ids)} " <>
          "current_pool_ids=#{inspect(report.current_pool_ids)} " <>
          "proposed_pool_ids=#{inspect(report.proposed_pool_ids)} " <>
          "topology_mutation=runtime_local deployment_config_mutation=false"
      )

      IO.puts(
        "[maxio rebalance.apply_removal.config] #{inspect(report.proposed_config, limit: :infinity)}"
      )
    end
  end

  defp error_message(:not_found), do: "no decommission job found"

  defp error_message({:preflight_blocked, report}) do
    "topology removal preflight is blocked: blockers=#{inspect(report.blockers)} " <>
      "job_id=#{report.job_id}"
  end

  defp error_message({:current_topology_hash_mismatch, expected, actual}) do
    "current topology hash mismatch: expected=#{inspect(expected)} actual=#{actual}"
  end

  defp error_message(:topology_apply_locked),
    do: "could not acquire topology removal apply lock"

  defp error_message(:topology_removal_already_applied),
    do: "topology removal has already been applied for this job"

  defp error_message(:would_remove_last_set),
    do: "cannot remove the last remaining erasure set from topology"

  defp error_message({:unknown_set_id, set_id, set_ids}) do
    "job target_set_id=#{inspect(set_id)} is not in configured set ids: #{inspect(set_ids)}"
  end

  defp error_message({:unknown_target_set_id, set_id, set_ids}) do
    "job target_set_id=#{inspect(set_id)} is not in configured set ids: #{inspect(set_ids)}"
  end

  defp error_message({:unsupported_job_kind, kind}),
    do: "apply_removal only supports decommission jobs, got kind=#{inspect(kind)}"

  defp error_message(:no_topology),
    do: "cannot apply topology removal without configured topology"

  defp error_message(reason), do: "rebalance removal apply failed: #{inspect(reason)}"

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
