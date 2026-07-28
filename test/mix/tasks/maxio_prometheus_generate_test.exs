defmodule Mix.Tasks.MaxioPrometheusGenerateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Maxio.S3.PrometheusToken

  @root_ak "AKIAIOSFODNN7EXAMPLE"
  @root_secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

  setup do
    Mix.Task.clear()
    :ok
  end

  test "token-only output emits a verifiable bearer token" do
    output =
      capture_io(fn ->
        Mix.Task.run("maxio.prometheus.generate", [
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
        Mix.Task.run("maxio.prometheus.generate", [
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
