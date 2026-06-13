defmodule Mix.Tasks.Maxio.Rebalance.Cancel do
  @shortdoc "Cancel a planned/running rebalance/decommission job"
  @moduledoc """
  Cancel a persistent rebalance/decommission job.

      mix maxio.rebalance.cancel JOB_ID
      mix maxio.rebalance.cancel --job-id <uuid>
      mix maxio.rebalance.cancel --json
  """
  use Mix.Task

  alias Maxio.Cluster.Rebalance.Jobs

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          job_id: :string,
          decommission_set: :integer,
          json: :boolean
        ]
      )

    job_id = Keyword.get(opts, :job_id) || List.first(rest)
    extra = if job_id && rest == [job_id], do: [], else: rest

    if extra != [] or invalid != [] do
      unexpected = extra ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.rebalance.cancel [JOB_ID|--job-id <uuid>] " <>
          "[--decommission-set <id>] [--json] (unexpected: #{inspect(unexpected)})"
      )
    end

    Mix.Task.run("app.start")

    result =
      if job_id do
        Jobs.cancel(job_id)
      else
        Jobs.cancel_latest(target_set_id: Keyword.get(opts, :decommission_set))
      end

    case result do
      {:ok, job} ->
        if Keyword.get(opts, :json, false) do
          IO.puts(Jason.encode!(Jobs.to_view(job)))
        else
          IO.puts(
            "[maxio rebalance.cancel] job_id=#{job.id} kind=#{job.kind} status=#{job.status} " <>
              "data_movement=false data_movement_status=#{job.data_movement_status}"
          )
        end

      {:error, :not_found} ->
        Mix.raise("no cancelable rebalance/decommission job found")

      {:error, {:not_cancelable, status}} ->
        Mix.raise("rebalance job is not cancelable from status=#{status}")

      {:error, reason} ->
        Mix.raise("rebalance cancel failed: #{inspect(reason)}")
    end
  end
end
