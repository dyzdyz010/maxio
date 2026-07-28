defmodule Mix.Tasks.Maxio.Stress.Campaign do
  @shortdoc "Run the local Maxio stress/fault campaign"
  @moduledoc """
  Run the local stress/fault campaign and write a JSON evidence artifact.

      mix maxio.stress.campaign
      mix maxio.stress.campaign --fail-on-blocked --artifact artifacts/p2_stress_local.json
      mix maxio.stress.campaign --suite streaming_stress_matrix --json

  The default campaign is local-safe and does not require external aws-cli,
  MinIO mc, or boto3 clients. Scale streaming stress with the
  `MAXIO_STREAMING_STRESS_*` environment variables documented by
  `Maxio.Compat.StreamingStressConfig`.
  """

  use Mix.Task

  alias Maxio.Compat.StressCampaign

  @impl true
  def run(args) do
    case StressCampaign.run(args) do
      {:ok, result} ->
        StressCampaign.print_result(result)

      {:error, %{exit_code: 64} = result} ->
        StressCampaign.print_result(result)
        Mix.raise("stress campaign usage error")

      {:error, result} ->
        StressCampaign.print_result(result)
        Mix.raise("stress campaign #{result.gate_status}")
    end
  end
end
