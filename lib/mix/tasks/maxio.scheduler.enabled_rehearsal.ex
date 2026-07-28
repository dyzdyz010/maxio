defmodule Mix.Tasks.Maxio.Scheduler.EnabledRehearsal do
  @shortdoc "Run bounded scheduler-enabled rehearsal evidence"
  @moduledoc """
  Run a bounded scheduler-enabled rehearsal and write a scheduler rehearsal artifact.

      mix maxio.scheduler.enabled_rehearsal --scheduler all --json
      mix maxio.scheduler.enabled_rehearsal --scheduler rebalance --require-lock-loser

  The default run starts local scheduler GenServers and records scheduled ledger
  evidence through controlled no-op runners. It does not start the application
  background scheduler tree and does not run destructive heal/rebalance work.
  """

  use Mix.Task

  alias Maxio.Cluster.SchedulerEnabledRehearsal

  @impl true
  def run(args) do
    case SchedulerEnabledRehearsal.run(args) do
      {:ok, result} ->
        SchedulerEnabledRehearsal.print_result(result)

      {:error, %{exit_code: 64} = result} ->
        SchedulerEnabledRehearsal.print_result(result)
        System.halt(result.exit_code)

      {:error, result} ->
        SchedulerEnabledRehearsal.print_result(result)
        Mix.raise("scheduler enabled rehearsal failed")
    end
  end
end
