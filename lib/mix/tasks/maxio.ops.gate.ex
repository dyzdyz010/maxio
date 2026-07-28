defmodule Mix.Tasks.Maxio.Ops.Gate do
  @shortdoc "Run the unified M8 operator gate harness"
  @moduledoc """
  Run the unified M8 operator gate harness and write a versioned JSON artifact.

      mix maxio.ops.gate
      mix maxio.ops.gate --json --fail-on-attention
      mix maxio.ops.gate --include-scanner --include-fresh-drive-heal --json
      mix maxio.ops.gate --include-foreground-scan --allow-mutating --json

  Defaults aggregate only read-only/no-start oriented M8 checks. Heavyweight
  scans and fresh-drive heal evidence require explicit opt-in; foreground scan
  also requires `--allow-mutating`.
  """

  use Mix.Task

  alias Maxio.Ops.Gate

  @impl true
  def run(args) do
    case Gate.run(args) do
      {:ok, result} ->
        Gate.print_result(result)

      {:error, %{exit_code: 64} = result} ->
        Gate.print_result(result)
        Mix.raise("ops gate usage error")

      {:error, result} ->
        Gate.print_result(result)
        Mix.raise("ops gate #{result.gate_status}")
    end
  end
end
