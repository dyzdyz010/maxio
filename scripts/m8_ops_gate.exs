case Maxio.Ops.Gate.run(System.argv()) do
  {:ok, result} ->
    Maxio.Ops.Gate.print_result(result)

  {:error, result} ->
    Maxio.Ops.Gate.print_result(result)
    System.halt(result.exit_code)
end
