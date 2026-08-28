defmodule Mix.Tasks.MaxioReleaseReadinessTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @task "maxio.release.readiness"

  # 只重置本用例要跑的那个 task。`Mix.Task.clear/0` 会把**整个 VM** 的"已执行 task"记录清空，
  # 连 `app.start` / `loadpaths` / `deps.loadpaths` 一起清掉：此后第一个调用
  # `Mix.Task.run("app.start")` 的 Mix 任务测试会在测试 VM 内**重跑依赖锁检查**（正常情况下
  # 它是 `:noop`）。git 依赖的 lock 检查一旦瞬时答错，就抛
  # `Mix.Error "Can't continue due to errors on dependencies"`，随机砸在后面某个毫不相干的
  # 用例上（实测：全量跑 seed=424242 时砸中 MaxioRebalanceVerifyClosureTest）。
  setup do
    Mix.Task.reenable(@task)
    on_exit(fn -> Mix.Task.reenable(@task) end)
    :ok
  end

  test "help output documents the release readiness entrypoint" do
    output =
      capture_io(fn ->
        Mix.Task.run(@task, ["--help"])
      end)

    assert output =~ "mix maxio.release.readiness"
    assert output =~ "--artifact PATH"
    assert output =~ "--strict"
    assert output =~ "does not start Maxio"
    assert output =~ "does not run `mix precommit`"
  end
end
