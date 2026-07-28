defmodule Mix.Tasks.Maxio.Ops.LiveRehearsalBundle do
  @shortdoc "Run the P0 ops live rehearsal artifact bundle"
  @moduledoc """
  Run the P0 ops live rehearsal artifact bundle and write a versioned JSON artifact.

      mix maxio.ops.live_rehearsal_bundle --json
      mix maxio.ops.live_rehearsal_bundle --fail-on-gate
      mix maxio.ops.live_rehearsal_bundle --replacement-live --replacement-arg --probe

  Default mode is report-only and uses dry-run replacement evidence. The final
  gate artifact still records blocked/attention/error states from real child
  evidence.
  """

  use Mix.Task

  alias Maxio.Ops.LiveRehearsalBundle

  @impl true
  def run(args) do
    case LiveRehearsalBundle.run(args) do
      {:ok, result} ->
        LiveRehearsalBundle.print_result(result)

      {:error, %{exit_code: 64} = result} ->
        LiveRehearsalBundle.print_result(result)
        System.halt(result.exit_code)

      {:error, result} ->
        LiveRehearsalBundle.print_result(result)
        Mix.raise("ops live rehearsal bundle #{result.gate_status}")
    end
  end
end
