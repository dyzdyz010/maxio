defmodule MaxioWeb.OpsObservabilityLiveTest do
  use MaxioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maxio.Repo
  alias Maxio.S3.Metrics.RequestMetric

  setup %{conn: conn} do
    old_prometheus = Application.get_env(:maxio, :prometheus_metrics)
    Application.put_env(:maxio, :prometheus_metrics, public: false)
    Repo.delete_all(RequestMetric)

    on_exit(fn ->
      case old_prometheus do
        nil -> Application.delete_env(:maxio, :prometheus_metrics)
        value -> Application.put_env(:maxio, :prometheus_metrics, value)
      end
    end)

    {:ok, conn: log_in_console(conn)}
  end

  test "renders read-only observability shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ops/observability")

    assert has_element?(view, "#ops-observability")
    assert has_element?(view, "#nav-ops-observability")
    assert has_element?(view, "#ops-observability-readonly-boundary", "read-only")
    assert has_element?(view, "#ops-observability-summary")
    assert has_element?(view, "#ops-observability-prometheus")
    assert has_element?(view, "#ops-observability-prometheus-endpoints")
    assert has_element?(view, "#ops-observability-request-metrics")
    assert has_element?(view, "#ops-observability-dashboard-stats")
    assert has_element?(view, "#ops-observability-operator-commands")
    assert has_element?(view, "#ops-observability-blockers")
    assert has_element?(view, "#ops-observability-warnings")
    assert has_element?(view, "#ops-observability-cross-links")
    assert has_element?(view, "#ops-observability-link-dashboard")
    assert has_element?(view, "#ops-observability-link-compat")
    assert has_element?(view, "#ops-observability-link-gate")
    assert has_element?(view, "#ops-observability-link-cluster")
    assert has_element?(view, "#ops-observability-link-upgrade")
    refute has_element?(view, "#ops-observability button")
    refute has_element?(view, "#ops-observability form")
  end

  test "renders seeded request metrics evidence without operator execution controls", %{
    conn: conn
  } do
    insert_metric!(
      bucket: "observed",
      filter_id: "entire",
      operation: "get_object",
      status_code: 200,
      status_class: "2xx",
      request_count: 3,
      bytes_downloaded_sum: 96
    )

    {:ok, view, _html} = live(conn, ~p"/ops/observability")

    assert has_element?(view, "#ops-observability-request-metrics", "observed")
    assert has_element?(view, "#ops-observability-request-metrics", "get_object")
    assert has_element?(view, "#ops-observability-prometheus", "/minio/metrics/v3/cluster")
    assert has_element?(view, "#ops-observability-operator-commands", "maxio.s3.request_metrics")
    refute has_element?(view, "#ops-observability button")
    refute has_element?(view, "#ops-observability form")
  end

  defp insert_metric!(attrs) do
    window =
      DateTime.utc_now()
      |> DateTime.truncate(:microsecond)
      |> then(fn %DateTime{} = now -> %DateTime{now | second: 0, microsecond: {0, 6}} end)

    Repo.insert!(%RequestMetric{
      bucket: Keyword.fetch!(attrs, :bucket),
      filter_id: Keyword.fetch!(attrs, :filter_id),
      window_started_at: window,
      operation: Keyword.get(attrs, :operation, "get_object"),
      metric_family: Keyword.get(attrs, :metric_family, "get"),
      status_code: Keyword.get(attrs, :status_code, 200),
      status_class: Keyword.get(attrs, :status_class, "2xx"),
      request_count: Keyword.get(attrs, :request_count, 1),
      bytes_uploaded_sum: Keyword.get(attrs, :bytes_uploaded_sum, 0),
      bytes_downloaded_sum: Keyword.get(attrs, :bytes_downloaded_sum, 0),
      latency_ms_sum: Keyword.get(attrs, :latency_ms_sum, 0),
      latency_ms_min: Keyword.get(attrs, :latency_ms_min, 0),
      latency_ms_max: Keyword.get(attrs, :latency_ms_max, 0),
      first_seen_at: Keyword.get(attrs, :first_seen_at, window),
      last_seen_at: Keyword.get(attrs, :last_seen_at, window)
    })
  end
end
