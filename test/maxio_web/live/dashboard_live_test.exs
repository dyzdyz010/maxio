defmodule MaxioWeb.DashboardLiveTest do
  use MaxioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maxio.Repo
  alias Maxio.S3.Metrics.RequestMetric

  setup %{conn: conn} do
    {:ok, conn: log_in_console(conn)}
  end

  test "空状态挂载所有统计卡片", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#stat-buckets")
    assert has_element?(view, "#stat-objects")
    assert has_element?(view, "#stat-size")
    assert has_element?(view, "#stat-keys")
    assert has_element?(view, "#stat-multipart")
    assert has_element?(view, "#per-bucket-table")
    assert has_element?(view, "#request-metrics-panel")
    assert has_element?(view, "#request-metrics-empty")
  end

  test "有桶有对象时统计反映 per-bucket", %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("dash-bucket", "arn:aws:iam:::root")

    {:ok, _o} =
      Maxio.Objects.put_version_with_id("dash-bucket", "a.txt", "null", %{
        size: 100,
        etag: "abc"
      })

    {:ok, view, html} = live(conn, ~p"/")
    assert has_element?(view, "#per-bucket-table")
    assert html =~ "dash-bucket"
  end

  test "请求指标面板展示选中 bucket/filter_id 的本地时序", %{conn: conn} do
    window = minute_window()

    insert_metric!(
      bucket: "dash-bucket",
      filter_id: "entire",
      window_started_at: window,
      operation: "get_object",
      status_code: 200,
      status_class: "2xx",
      request_count: 4,
      bytes_downloaded_sum: 32,
      latency_ms_sum: 40,
      latency_ms_max: 15
    )

    insert_metric!(
      bucket: "dash-bucket",
      filter_id: "entire",
      window_started_at: window,
      operation: "get_object",
      status_code: 404,
      status_class: "4xx",
      request_count: 1,
      latency_ms_sum: 20,
      latency_ms_max: 20
    )

    insert_metric!(
      bucket: "dash-bucket",
      filter_id: "docs",
      window_started_at: window,
      operation: "get_object",
      request_count: 9,
      bytes_downloaded_sum: 90,
      latency_ms_sum: 90
    )

    {:ok, view, _html} =
      live(conn, ~p"/?metrics_bucket=dash-bucket&metrics_id=entire")

    refute has_element?(view, "#request-metrics-empty")
    assert has_element?(view, "#request-metrics-filter-form")
    assert has_element?(view, "#request-metrics-selected", "dash-bucket / entire")
    assert has_element?(view, "#request-metric-total", "5")
    assert has_element?(view, "#request-metric-errors", "1")
    assert has_element?(view, "#request-metric-downloaded", "32 B")
    assert has_element?(view, "#request-metric-avg-latency", "12.0 ms")
    assert has_element?(view, "#request-metric-max-latency", "20 ms")
    assert has_element?(view, "#request-metrics-chart")
    assert has_element?(view, "#request-metrics-bar-0")
    assert has_element?(view, "#request-metrics-bar-59")
    assert has_element?(view, "#request-metrics-series-table")
    assert has_element?(view, "#request-metrics-row-0")
  end

  defp insert_metric!(attrs) do
    window = Keyword.fetch!(attrs, :window_started_at)
    latency_ms_sum = Keyword.get(attrs, :latency_ms_sum, 0)

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
      latency_ms_sum: latency_ms_sum,
      latency_ms_min: Keyword.get(attrs, :latency_ms_min, 0),
      latency_ms_max: Keyword.get(attrs, :latency_ms_max, latency_ms_sum),
      first_seen_at: Keyword.get(attrs, :first_seen_at, window),
      last_seen_at: Keyword.get(attrs, :last_seen_at, window)
    })
  end

  defp minute_window do
    %DateTime{} = now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    %DateTime{now | second: 0, microsecond: {0, 6}}
  end
end
