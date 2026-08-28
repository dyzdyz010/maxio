defmodule Mix.Tasks.MaxioPrometheusGenerateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Maxio.S3.PrometheusToken

  @root_ak "AKIAIOSFODNN7EXAMPLE"
  @root_secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

  @task "maxio.prometheus.generate"

  # 只重置本用例要跑的那个 task；`Mix.Task.clear/0` 会连 `app.start` / `deps.loadpaths` 的
  # "已执行"记录一起清掉，让后面第一个调用 `Mix.Task.run("app.start")` 的 Mix 任务测试在测试
  # VM 内重跑依赖锁检查，随机抛 `Can't continue due to errors on dependencies`。
  setup do
    Mix.Task.reenable(@task)
    on_exit(fn -> Mix.Task.reenable(@task) end)
    :ok
  end

  test "token-only output emits a verifiable bearer token" do
    output =
      capture_io(fn ->
        Mix.Task.run(@task, [
          "--access-key",
          @root_ak,
          "--secret-key",
          @root_secret,
          "--token-only",
          "--expires-days",
          "1"
        ])
      end)

    token = String.trim(output)

    assert {:ok, %{type: :root}, claims} = PrometheusToken.authenticate(token)
    assert claims["sub"] == @root_ak
    assert claims["aud"] == "prometheus"
  end

  test "default output is a Prometheus scrape config for selected metric type" do
    output =
      capture_io(fn ->
        Mix.Task.run(@task, [
          "--access-key",
          @root_ak,
          "--secret-key",
          @root_secret,
          "--endpoint",
          "127.0.0.1:9900",
          "--type",
          "buckets",
          "--expires-seconds",
          "60"
        ])
      end)

    assert output =~ "scrape_configs:"
    assert output =~ "job_name: maxio-buckets"
    assert output =~ "bearer_token: "
    assert output =~ "metrics_path: /minio/metrics/v3/cluster/usage/buckets"
    assert output =~ "scheme: http"
    assert output =~ ~s(targets: ["127.0.0.1:9900"])
  end
end
