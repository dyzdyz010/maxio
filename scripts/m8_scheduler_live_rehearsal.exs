case Maxio.Cluster.SchedulerLiveRehearsal.run(System.argv()) do
  {:ok, result} ->
    Maxio.Cluster.SchedulerLiveRehearsal.print_result(result)

  {:error, result} ->
    Maxio.Cluster.SchedulerLiveRehearsal.print_result(result)
    System.halt(result.exit_code)
end
