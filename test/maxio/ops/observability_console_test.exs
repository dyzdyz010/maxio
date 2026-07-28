defmodule Maxio.Ops.ObservabilityConsoleTest do
  use ExUnit.Case, async: false

  alias Maxio.Ops.ObservabilityConsole

  @now ~U[2026-07-05 00:00:00Z]

  test "ready private prometheus and request metrics evidence is ok" do
    console =
      ObservabilityConsole.load(
        now: @now,
        prometheus_config_fun: fn -> [public: false] end,
        streams_fun: fn opts ->
          assert opts[:limit] == 8

          [
            %{
              bucket: "observed",
              filter_id: "entire",
              request_count: 7,
              last_seen_at: @now
            }
          ]
        end,
        recent_metrics_fun: fn opts ->
          assert opts[:limit] == 12

          [
            %{
              bucket: "observed",
              filter_id: "entire",
              operation: "get_object",
              status_code: 200,
              status_class: "2xx",
              request_count: 7,
              window_started_at: @now
            }
          ]
        end,
        dashboard_fun: fn opts ->
          assert opts[:request_metrics][:stream_limit] == 8

          %{
            bucket_count: 1,
            object_count: 2,
            total_size: 32,
            access_key_count: 1,
            multipart_count: 0,
            per_bucket: [%{name: "observed", object_count: 2, size: 32}],
            request_metrics: %{streams: [%{bucket: "observed", filter_id: "entire"}]}
          }
        end
      )

    assert console.status == "ok"
    assert console.prometheus.status == "ok"
    assert console.request_metrics.status == "ok"
    assert console.dashboard_stats.status == "ok"
    assert console.blockers.rows == []
    assert length(console.prometheus.endpoint_rows) == 5

    assert Enum.any?(
             console.operator_commands.rows,
             &(&1.id == "operator-command-prometheus-token")
           )
  end

  test "public prometheus and empty request metrics are visible attention warnings" do
    console =
      ObservabilityConsole.load(
        now: @now,
        prometheus_config_fun: fn -> [public: true] end,
        streams_fun: fn _opts -> [] end,
        recent_metrics_fun: fn _opts -> [] end,
        dashboard_fun: fn _opts ->
          %{
            bucket_count: 0,
            object_count: 0,
            total_size: 0,
            access_key_count: 0,
            multipart_count: 0,
            per_bucket: [],
            request_metrics: %{streams: []}
          }
        end
      )

    assert console.status == "attention"
    assert console.prometheus.status == "attention"
    assert console.request_metrics.status == "attention"
    assert Enum.any?(console.warnings.rows, &(&1.reason == "prometheus_public"))
    assert Enum.any?(console.warnings.rows, &(&1.reason == "no_request_metric_streams"))
    assert console.blockers.rows == []
  end

  test "request metric reader failure fails closed and redacts secrets" do
    console =
      ObservabilityConsole.load(
        now: @now,
        prometheus_config_fun: fn -> [public: false] end,
        streams_fun: fn _opts ->
          raise "Authorization: Bearer real-token secret=super-secret"
        end,
        recent_metrics_fun: fn _opts -> [] end,
        dashboard_fun: fn _opts ->
          %{
            bucket_count: 0,
            object_count: 0,
            total_size: 0,
            access_key_count: 0,
            multipart_count: 0,
            per_bucket: [],
            request_metrics: %{streams: []}
          }
        end
      )

    assert console.status == "blocked"
    assert [%{reason: "request_metrics_read_failed"} = blocker] = console.blockers.rows
    assert blocker.status == "blocked"
    refute inspect(console) =~ "real-token"
    refute inspect(console) =~ "super-secret"
    assert blocker.detail =~ "[REDACTED]"
  end

  test "recent request metric row ids include row identity or window" do
    first_window = @now
    second_window = DateTime.add(@now, -60, :second)

    console =
      ObservabilityConsole.load(
        now: @now,
        prometheus_config_fun: fn -> [public: false] end,
        streams_fun: fn _opts ->
          [
            %{
              bucket: "observed",
              filter_id: "entire",
              request_count: 2,
              last_seen_at: @now
            }
          ]
        end,
        recent_metrics_fun: fn _opts ->
          [
            %{
              bucket: "observed",
              filter_id: "entire",
              operation: "get_object",
              status_code: 200,
              status_class: "2xx",
              request_count: 1,
              window_started_at: first_window
            },
            %{
              bucket: "observed",
              filter_id: "entire",
              operation: "get_object",
              status_code: 200,
              status_class: "2xx",
              request_count: 1,
              window_started_at: second_window
            }
          ]
        end,
        dashboard_fun: fn _opts ->
          %{
            bucket_count: 1,
            object_count: 0,
            total_size: 0,
            access_key_count: 0,
            multipart_count: 0,
            per_bucket: [],
            request_metrics: %{streams: [%{bucket: "observed", filter_id: "entire"}]}
          }
        end
      )

    ids = Enum.map(console.request_metrics.recent_rows, & &1.id)
    assert length(ids) == 2
    assert ids == Enum.uniq(ids)
  end

  test "malformed request metrics shape fails closed" do
    console =
      ObservabilityConsole.load(
        now: @now,
        prometheus_config_fun: fn -> [public: false] end,
        streams_fun: fn _opts -> %{"bad" => "shape"} end,
        recent_metrics_fun: fn _opts -> [] end,
        dashboard_fun: fn _opts ->
          %{
            bucket_count: 0,
            object_count: 0,
            total_size: 0,
            access_key_count: 0,
            multipart_count: 0,
            per_bucket: [],
            request_metrics: %{streams: []}
          }
        end
      )

    assert console.status == "blocked"
    assert [%{reason: "request_metrics_malformed_result"}] = console.blockers.rows
  end
end
