case Maxio.Cluster.SchedulerEnabledRehearsal.run(System.argv()) do
  {:ok, result} ->
    Maxio.Cluster.SchedulerEnabledRehearsal.print_result(result)

  {:error, result} ->
    Maxio.Cluster.SchedulerEnabledRehearsal.print_result(result)
    System.halt(result.exit_code)
end
