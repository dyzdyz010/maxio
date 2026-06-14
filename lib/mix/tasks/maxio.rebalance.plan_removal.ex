defmodule Mix.Tasks.Maxio.Rebalance.PlanRemoval do
  @shortdoc "Generate a topology patch artifact for a completed decommission"
  @moduledoc """
  Generate the proposed topology config after a completed decommission job has
  passed removal preflight.

      mix maxio.rebalance.plan_removal --job-id <uuid>
      mix maxio.rebalance.plan_removal <uuid> --json

  This command is read-only. It does not mutate runtime topology, deployment
  config, job state, or shard data.
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
        "usage: mix maxio.rebalance.plan_removal [JOB_ID|--job-id <uuid>] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    Mix.Task.run("app.start")

    with {:ok, job_id} <- resolve_job_id(job_id),
         {:ok, plan} <- TopologyMutation.removal_plan(job_id) do
      print_or_json(opts, plan)
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

  defp print_or_json(opts, plan) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(json_ready(plan)))
    else
      IO.puts(
        "[maxio rebalance.plan_removal] job_id=#{plan.job_id} status=#{plan.status} " <>
          "removed_set_id=#{plan.removed_set_id} removed_pool_id=#{plan.removed_pool_id} " <>
          "removed_pool_ids=#{inspect(plan.removed_pool_ids)} " <>
          "current_topology_hash=#{plan.current_topology_hash} " <>
          "proposed_topology_hash=#{plan.proposed_topology_hash} " <>
          "current_set_ids=#{inspect(plan.current_set_ids)} " <>
          "proposed_set_ids=#{inspect(plan.proposed_set_ids)} " <>
          "current_pool_ids=#{inspect(plan.current_pool_ids)} " <>
          "proposed_pool_ids=#{inspect(plan.proposed_pool_ids)} " <>
          "topology_mutation=false"
      )

      IO.puts(
        "[maxio rebalance.plan_removal.config] #{inspect(plan.proposed_config, limit: :infinity)}"
      )
    end
  end

  defp error_message(:not_found), do: "no decommission job found"

  defp error_message({:preflight_blocked, report}) do
    "topology removal preflight is blocked: blockers=#{inspect(report.blockers)} " <>
      "job_id=#{report.job_id}"
  end

  defp error_message(:would_remove_last_set),
    do: "cannot remove the last remaining erasure set from topology"

  defp error_message({:unknown_set_id, set_id, set_ids}) do
    "job target_set_id=#{inspect(set_id)} is not in configured set ids: #{inspect(set_ids)}"
  end

  defp error_message({:unsupported_job_kind, kind}),
    do: "plan_removal only supports decommission jobs, got kind=#{inspect(kind)}"

  defp error_message(:no_topology),
    do: "cannot plan topology removal without configured topology"

  defp error_message(reason), do: "rebalance removal plan failed: #{inspect(reason)}"

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
