defmodule Mix.Tasks.Maxio.LifecycleRunTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Maxio.Lifecycle.Run

  test "rejects invalid switches before starting a destructive sweep" do
    Mix.Task.reenable("maxio.lifecycle.run")

    assert_raise Mix.Error, ~r/usage: mix maxio.lifecycle.run/, fn ->
      Run.run(["--dryrun"])
    end
  end
end
