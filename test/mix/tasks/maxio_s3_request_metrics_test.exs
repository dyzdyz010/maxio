defmodule Mix.Tasks.MaxioS3RequestMetricsTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Repo
  alias Maxio.S3.Metrics.RequestMetric
  alias Mix.Tasks.Maxio.S3.RequestMetrics, as: RequestMetricsTask

  @task "maxio.s3.request_metrics"
  @window ~U[2026-06-30 01:23:00.000000Z]

  setup do
    Mix.Task.reenable(@task)
    on_exit(fn -> Mix.Task.reenable(@task) end)
  end

  test "prints json rows with filters without writing ledger rows" do
    insert_metric!(bucket: "metriccli", filter_id: "entire", operation: "get_object")
    insert_metric!(bucket: "metriccli", filter_id: "docs", operation: "put_object")

    before_count = Repo.aggregate(RequestMetric, :count)

    output =
      capture_io(fn ->
        RequestMetricsTask.run(["--bucket", "metriccli", "--id", "entire", "--json"])
      end)

    assert %{"count" => 1, "metrics" => [row]} = Jason.decode!(output)
    assert row["bucket"] == "metriccli"
    assert row["filter_id"] == "entire"
    assert row["operation"] == "get_object"
    assert row["request_count"] == 1

    assert Repo.aggregate(RequestMetric, :count) == before_count
  end

  test "text output escapes values and status class filter applies" do
    insert_metric!(
      bucket: "metriccli\nforged",
      filter_id: "entire",
      operation: "get_object",
      status_code: 404
    )

    output =
      capture_io(fn ->
        RequestMetricsTask.run(["--status-class", "4xx"])
      end)

    lines = String.split(output, "\n", trim: true)
    assert length(lines) == 2
    assert Enum.at(lines, 0) == "[maxio s3.request_metrics] rows=1"
    assert Enum.at(lines, 1) =~ ~s(bucket="metriccli\\nforged")
    assert Enum.at(lines, 1) =~ ~s(status=404)
  end

  test "invalid args fail closed before querying" do
    assert_raise Mix.Error, ~r/usage: mix maxio\.s3\.request_metrics/, fn ->
      RequestMetricsTask.run(["--bad"])
    end

    assert_raise Mix.Error, ~r/--minutes cannot be combined/, fn ->
      RequestMetricsTask.run(["--minutes", "5", "--from", DateTime.to_iso8601(@window)])
    end

    assert_raise Mix.Error, ~r/--status-class must be one of/, fn ->
      RequestMetricsTask.run(["--status-class", "400"])
    end
  end

  defp insert_metric!(attrs) do
    attrs = Map.new(attrs)
    status_code = Map.get(attrs, :status_code, 200)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %RequestMetric{
      bucket: Map.fetch!(attrs, :bucket),
      filter_id: Map.fetch!(attrs, :filter_id),
      window_started_at: Map.get(attrs, :window_started_at, @window),
      operation: Map.fetch!(attrs, :operation),
      metric_family: Map.get(attrs, :metric_family, "get"),
      status_code: status_code,
      status_class: status_class(status_code),
      request_count: Map.get(attrs, :request_count, 1),
      bytes_uploaded_sum: Map.get(attrs, :bytes_uploaded_sum, 0),
      bytes_downloaded_sum: Map.get(attrs, :bytes_downloaded_sum, 10),
      latency_ms_sum: Map.get(attrs, :latency_ms_sum, 3),
      latency_ms_min: Map.get(attrs, :latency_ms_min, 3),
      latency_ms_max: Map.get(attrs, :latency_ms_max, 3),
      first_seen_at: now,
      last_seen_at: now
    }
    |> Repo.insert!()
  end

  defp status_class(status) when status >= 200 and status < 300, do: "2xx"
  defp status_class(status) when status >= 400 and status < 500, do: "4xx"
  defp status_class(_status), do: "other"
end
