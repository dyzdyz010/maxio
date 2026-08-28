defmodule Mix.Tasks.MaxioStressCampaignTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @task "maxio.stress.campaign"

  # 只重置本用例要跑的那个 task；`Mix.Task.clear/0` 会连 `app.start` / `deps.loadpaths` 的
  # "已执行"记录一起清掉，让后面第一个调用 `Mix.Task.run("app.start")` 的 Mix 任务测试在测试
  # VM 内重跑依赖锁检查，随机抛 `Can't continue due to errors on dependencies`。
  setup do
    Mix.Task.reenable(@task)
    on_exit(fn -> Mix.Task.reenable(@task) end)
    :ok
  end

  test "help output documents the local stress campaign entrypoint" do
    output =
      capture_io(fn ->
        Mix.Task.run(@task, ["--help"])
      end)

    assert output =~ "mix maxio.stress.campaign"
    assert output =~ "streaming_stress_matrix"
    assert output =~ "storage_fault_matrix"
    assert output =~ "ops_resilience_matrix"
    assert output =~ "does not require or run external aws-cli"
  end
end
