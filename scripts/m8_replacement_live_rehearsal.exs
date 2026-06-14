case Maxio.Cluster.ReplacementLiveRehearsal.run(System.argv()) do
  {:ok, result} ->
    Maxio.Cluster.ReplacementLiveRehearsal.print_result(result)

  {:error, result} ->
    Maxio.Cluster.ReplacementLiveRehearsal.print_result(result)
    System.halt(result.exit_code)
end
