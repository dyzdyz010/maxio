defmodule Mix.Tasks.Maxio.Release.Readiness do
  @shortdoc "Build a release readiness evidence bundle"
  @moduledoc """
  Build a read-only release readiness evidence bundle.

      mix maxio.release.readiness
      mix maxio.release.readiness --json --artifact artifacts/p2_release_local.json
      mix maxio.release.readiness --strict

  The task aggregates existing artifacts and local environment evidence. It
  does not start Maxio, run external smoke tests, mutate ops state, or rerun
  `mix precommit`.
  """

  use Mix.Task

  alias Maxio.Ops.ReleaseReadinessBundle

  @impl true
  def run(args) do
    case ReleaseReadinessBundle.run(args) do
      {:ok, result} ->
        ReleaseReadinessBundle.print_result(result)

      {:error, %{exit_code: 64} = result} ->
        ReleaseReadinessBundle.print_result(result)
        Mix.raise("release readiness usage error")

      {:error, result} ->
        ReleaseReadinessBundle.print_result(result)
        Mix.raise("release readiness #{result.gate_status}")
    end
  end
end
