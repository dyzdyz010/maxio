defmodule Mix.Tasks.MaxioStressCampaignTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    Mix.Task.clear()
    :ok
  end

  test "help output documents the local stress campaign entrypoint" do
    output =
      capture_io(fn ->
        Mix.Task.run("maxio.stress.campaign", ["--help"])
      end)

    assert output =~ "mix maxio.stress.campaign"
    assert output =~ "streaming_stress_matrix"
    assert output =~ "storage_fault_matrix"
    assert output =~ "ops_resilience_matrix"
    assert output =~ "does not require or run external aws-cli"
  end
end
