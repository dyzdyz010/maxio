case Maxio.Ops.LiveRehearsalBundle.run(System.argv()) do
  {:ok, result} ->
    Maxio.Ops.LiveRehearsalBundle.print_result(result)

  {:error, result} ->
    Maxio.Ops.LiveRehearsalBundle.print_result(result)
    System.halt(result.exit_code)
end
