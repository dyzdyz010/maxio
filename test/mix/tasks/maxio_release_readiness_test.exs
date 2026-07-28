defmodule Mix.Tasks.MaxioReleaseReadinessTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    Mix.Task.clear()
    :ok
  end

  test "help output documents the release readiness entrypoint" do
    output =
      capture_io(fn ->
        Mix.Task.run("maxio.release.readiness", ["--help"])
      end)

    assert output =~ "mix maxio.release.readiness"
    assert output =~ "--artifact PATH"
    assert output =~ "--strict"
    assert output =~ "does not start Maxio"
    assert output =~ "does not run `mix precommit`"
  end
end
