defmodule Maxio.Ops.ObservabilityConsole do
  @moduledoc """
  Read-only Console projection for observability and metrics readiness.

  The projection reads existing Prometheus configuration, local S3 request
  metrics ledger rows, and Dashboard aggregate counters. It never generates
  bearer tokens, scrapes HTTP endpoints, runs Mix tasks, samples drives, starts
  schedulers, or writes data.
  """

  alias Maxio.Console.Stats
  alias Maxio.S3.Metrics.RequestMetrics
  alias Maxio.S3.{Prometheus, PrometheusToken}

  @max_streams 8
  @max_recent_metrics 12
  @default_stale_minutes 60

  @doc "Load the read-only observability console projection."
  @spec load(keyword()) :: map()
  def load(opts \\ []) when is_list(opts) do
    now = now(opts)
    prometheus = prometheus_section(opts)
    request_metrics = request_metrics_section(now, opts)
    dashboard_stats = dashboard_stats_section(opts)
    operator_commands = operator_commands_section(opts)

    blockers = blockers_section([prometheus, request_metrics, dashboard_stats])
    warnings = warnings_section([prometheus, request_metrics, dashboard_stats])

    status =
      rollup_status([
        prometheus.status,
        request_metrics.status,
        dashboard_stats.status,
        blockers.status,
        warnings.status
      ])

    %{
      status: status,
      readonly_boundary: readonly_boundary(),
      summary_rows:
        summary_rows(status, prometheus, request_metrics, dashboard_stats, operator_commands),
      prometheus: prometheus,
      request_metrics: request_metrics,
      dashboard_stats: dashboard_stats,
      operator_commands: operator_commands,
      blockers: blockers,
      warnings: warnings,
      cross_links: cross_links()
    }
  end

  defp prometheus_section(opts) do
    config_result =
      opts
      # 经 Maxio.Config 门面读（config store 白名单键）：Console 展示的必须是**生效值**，
      # 直读 Application env 会在运维刚做完 `mix maxio.config.set` 之后显示旧值——
      # 一个和数据面不一致的观测台比没有观测台更糟。
      |> Keyword.get(:prometheus_config_fun, fn -> Maxio.Config.get_all(:prometheus_metrics) end)
      |> safe_call0()

    case config_result do
      {:ok, config} ->
        public? = public_prometheus?(config)

        rows = [
          row("prometheus-public", "public", public?),
          row("prometheus-auth-mode", "auth_mode", if(public?, do: "public", else: "bearer")),
          row("prometheus-required-action", "required_action", "admin:Prometheus"),
          row("prometheus-content-type", "content_type", Prometheus.content_type()),
          row("prometheus-token-ttl-days", "token_ttl_days", token_ttl_days()),
          row("prometheus-families", "supported_families", "cluster, objects, buckets")
        ]

        %{
          status: if(public?, do: "attention", else: "ok"),
          rows: rows,
          endpoint_rows: prometheus_endpoint_rows(),
          blockers: [],
          warnings:
            if(public?,
              do: [
                item(
                  "prometheus-public",
                  "prometheus",
                  "prometheus_public",
                  "public scrape must be isolated behind trusted network controls"
                )
              ],
              else: []
            )
        }

      {:error, reason} ->
        blocked_section(
          "prometheus_config_read_failed",
          "prometheus",
          reason
        )
        |> Map.put(:endpoint_rows, [])
    end
  end

  defp request_metrics_section(now, opts) do
    streams_result =
      opts
      |> Keyword.get(:streams_fun, fn query_opts -> RequestMetrics.streams(query_opts) end)
      |> safe_call1(limit: Keyword.get(opts, :stream_limit, @max_streams))

    recent_result =
      opts
      |> Keyword.get(:recent_metrics_fun, fn query_opts -> RequestMetrics.list(query_opts) end)
      |> safe_call1(limit: Keyword.get(opts, :recent_limit, @max_recent_metrics))

    with {:ok, streams} when is_list(streams) <- streams_result,
         {:ok, recent_metrics} when is_list(recent_metrics) <- recent_result do
      stream_rows =
        streams
        |> Enum.take(@max_streams)
        |> Enum.map(&stream_row(&1, now, opts))

      recent_rows =
        recent_metrics
        |> Enum.take(@max_recent_metrics)
        |> Enum.map(&recent_metric_row/1)

      warnings =
        []
        |> maybe_add_warning(stream_rows == [], "request_metrics", "no_request_metric_streams")
        |> maybe_add_warning(
          Enum.any?(stream_rows, &(&1.status == "attention")),
          "request_metrics",
          "stale_or_malformed_streams"
        )

      %{
        status: request_metrics_status(stream_rows, recent_rows),
        rows: stream_rows,
        recent_rows: recent_rows,
        blockers: [],
        warnings: warnings
      }
    else
      {:ok, _other} ->
        blocked_request_metrics("request_metrics_malformed_result", "non_list_result")

      {:error, reason} ->
        blocked_request_metrics("request_metrics_read_failed", reason)
    end
  end

  defp dashboard_stats_section(opts) do
    result =
      opts
      |> Keyword.get(:dashboard_fun, fn dashboard_opts -> Stats.dashboard(dashboard_opts) end)
      |> safe_call1(
        request_metrics: [stream_limit: Keyword.get(opts, :stream_limit, @max_streams)]
      )

    case result do
      {:ok, dashboard} when is_map(dashboard) ->
        request_metrics = map_get(dashboard, :request_metrics, %{})
        streams = request_metrics |> map_get(:streams, []) |> list_value()

        rows = [
          row("dashboard-buckets", "bucket_count", map_get(dashboard, :bucket_count)),
          row("dashboard-objects", "object_count", map_get(dashboard, :object_count)),
          row("dashboard-total-size", "total_size", map_get(dashboard, :total_size)),
          row("dashboard-access-keys", "access_key_count", map_get(dashboard, :access_key_count)),
          row("dashboard-multipart", "multipart_count", map_get(dashboard, :multipart_count)),
          row(
            "dashboard-per-bucket",
            "per_bucket_rows",
            length(list_value(map_get(dashboard, :per_bucket)))
          ),
          row("dashboard-metrics-streams", "request_metric_streams", length(streams))
        ]

        %{
          status: "ok",
          rows: rows,
          blockers: [],
          warnings: []
        }

      {:ok, _other} ->
        blocked_section("dashboard_stats_malformed_result", "dashboard", "non_map_result")

      {:error, reason} ->
        blocked_section("dashboard_stats_read_failed", "dashboard", reason)
    end
  end

  defp operator_commands_section(_opts) do
    %{
      status: "ok",
      rows: [
        %{
          id: "operator-command-prometheus-token",
          status: "ok",
          label: "generate bearer token",
          command:
            "mix maxio.prometheus.generate --access-key <access-key> --endpoint <s3-endpoint>",
          boundary: "operator-run read-only CLI; this page does not run it"
        },
        %{
          id: "operator-command-prometheus-scrape",
          status: "ok",
          label: "scrape cluster metrics",
          command:
            "curl -H \"Authorization: Bearer <token>\" <s3-endpoint>/minio/metrics/v3/cluster",
          boundary: "operator-run external scrape; this page does not perform HTTP"
        },
        %{
          id: "operator-command-request-metrics",
          status: "ok",
          label: "inspect local request ledger",
          command: "mix maxio.s3.request_metrics --bucket <bucket> --id <filter-id> --json",
          boundary: "operator-run read-only CLI; this page does not run it"
        },
        %{
          id: "operator-command-dashboard",
          status: "ok",
          label: "console dashboard",
          command: "open Console Dashboard /",
          boundary: "navigation only"
        }
      ]
    }
  end

  defp blockers_section(sections) do
    rows =
      sections
      |> Enum.flat_map(&Map.get(&1, :blockers, []))
      |> Enum.take(@max_recent_metrics)

    %{status: if(rows == [], do: "ok", else: "blocked"), rows: rows}
  end

  defp warnings_section(sections) do
    rows =
      sections
      |> Enum.flat_map(&Map.get(&1, :warnings, []))
      |> Enum.take(@max_recent_metrics)

    %{status: if(rows == [], do: "ok", else: "attention"), rows: rows}
  end

  defp blocked_request_metrics(reason, detail) do
    blocked_section(reason, "request_metrics", detail)
    |> Map.put(:recent_rows, [])
  end

  defp blocked_section(reason, entry, detail) do
    %{
      status: "blocked",
      rows: [],
      blockers: [blocker_item("#{entry}-blocked", entry, reason, detail)],
      warnings: []
    }
  end

  defp stream_row(stream, now, opts) do
    last_seen = map_get(stream, :last_seen_at)
    reason = stream_reason(last_seen, now, opts)

    %{
      id: safe_id("stream-#{map_get(stream, :bucket)}-#{map_get(stream, :filter_id)}"),
      status: if(reason == "ok", do: "ok", else: "attention"),
      bucket: text(map_get(stream, :bucket)),
      filter_id: text(map_get(stream, :filter_id)),
      request_count: text(map_get(stream, :request_count)),
      last_seen_at: datetime_text(last_seen),
      reason: reason
    }
  end

  defp recent_metric_row(metric) do
    %{
      id: recent_metric_id(metric),
      status: metric_status(map_get(metric, :status_class)),
      bucket: text(map_get(metric, :bucket)),
      filter_id: text(map_get(metric, :filter_id)),
      operation: text(map_get(metric, :operation)),
      status_code: text(map_get(metric, :status_code)),
      status_class: text(map_get(metric, :status_class)),
      request_count: text(map_get(metric, :request_count)),
      window_started_at: datetime_text(map_get(metric, :window_started_at))
    }
  end

  defp recent_metric_id(metric) do
    unique =
      case map_get(metric, :id) do
        value when value not in [nil, ""] -> value
        _other -> map_get(metric, :window_started_at)
      end

    safe_id(
      "metric-#{map_get(metric, :bucket)}-#{map_get(metric, :filter_id)}-#{map_get(metric, :operation)}-#{map_get(metric, :status_code)}-#{unique}"
    )
  end

  defp stream_reason(nil, _now, _opts), do: "missing_last_seen_at"

  defp stream_reason(%DateTime{} = last_seen, %DateTime{} = now, opts) do
    max_age_minutes = positive_int(Keyword.get(opts, :stale_minutes), @default_stale_minutes)

    cond do
      DateTime.compare(last_seen, now) == :gt -> "future_last_seen_at"
      DateTime.diff(now, last_seen, :minute) > max_age_minutes -> "stale_last_seen_at"
      true -> "ok"
    end
  end

  defp stream_reason(_last_seen, _now, _opts), do: "invalid_last_seen_at"

  defp metric_status(class) when class in ["4xx", "5xx"], do: "attention"
  defp metric_status(_class), do: "ok"

  defp request_metrics_status([], _recent_rows), do: "attention"

  defp request_metrics_status(stream_rows, recent_rows) do
    cond do
      Enum.any?(stream_rows, &(&1.status == "attention")) -> "attention"
      Enum.any?(recent_rows, &(&1.status == "attention")) -> "attention"
      true -> "ok"
    end
  end

  defp prometheus_endpoint_rows do
    [
      endpoint_row("/minio/metrics/v3"),
      endpoint_row("/minio/metrics/v3/cluster"),
      endpoint_row("/minio/metrics/v3/cluster/usage/objects"),
      endpoint_row("/minio/metrics/v3/cluster/usage/buckets"),
      endpoint_row("/minio/v2/metrics/cluster")
    ]
  end

  defp endpoint_row(path) do
    family =
      case Prometheus.family_for_path(path) do
        {:ok, family} -> Atom.to_string(family)
        :unknown -> "unknown"
      end

    %{
      id: safe_id("endpoint-#{path}"),
      status: if(family == "unknown", do: "blocked", else: "ok"),
      method: "GET/HEAD",
      path: path,
      family: family
    }
  end

  defp summary_rows(status, prometheus, request_metrics, dashboard_stats, operator_commands) do
    [
      row("summary-status", "status", status),
      row("summary-prometheus", "prometheus", prometheus.status),
      row("summary-request-metrics", "request_metrics", request_metrics.status),
      row("summary-dashboard", "dashboard_stats", dashboard_stats.status),
      row(
        "summary-prometheus-endpoints",
        "prometheus_endpoints",
        length(prometheus.endpoint_rows)
      ),
      row("summary-metric-streams", "request_metric_streams", length(request_metrics.rows)),
      row("summary-recent-metrics", "recent_metric_rows", length(request_metrics.recent_rows)),
      row("summary-operator-commands", "operator_commands", length(operator_commands.rows))
    ]
  end

  defp readonly_boundary do
    %{
      status: "ok",
      message: "This page only reads observability configuration and stored metrics evidence.",
      forbidden: [
        "bearer token generation",
        "Mix task execution",
        "HTTP scraping",
        "shell/system commands",
        "Repo writes",
        "drive sampling",
        "scan/heal/rebalance/gate execution"
      ]
    }
  end

  defp cross_links do
    [
      %{id: "ops-observability-link-dashboard", label: "Dashboard", path: "/"},
      %{id: "ops-observability-link-compat", label: "Ops Compat", path: "/ops/compat"},
      %{id: "ops-observability-link-gate", label: "Ops Gate", path: "/ops/gate"},
      %{id: "ops-observability-link-cluster", label: "Ops Cluster", path: "/ops/cluster"},
      %{id: "ops-observability-link-upgrade", label: "Ops Upgrade", path: "/ops/upgrade"}
    ]
  end

  defp item(id, entry, reason, detail) do
    %{
      id: safe_id(id),
      status: "attention",
      entry: text(entry),
      kind: "observability",
      reason: text(reason),
      detail: detail |> error_text() |> redact()
    }
  end

  defp blocker_item(id, entry, reason, detail) do
    item(id, entry, reason, detail)
    |> Map.put(:status, "blocked")
  end

  defp maybe_add_warning(rows, false, _entry, _reason), do: rows

  defp maybe_add_warning(rows, true, entry, reason),
    do: [item(reason, entry, reason, reason) | rows]

  defp rollup_status(statuses) do
    statuses = Enum.map(statuses, &status_text/1)

    cond do
      Enum.any?(statuses, &(&1 == "blocked")) -> "blocked"
      Enum.any?(statuses, &(&1 == "attention")) -> "attention"
      true -> "ok"
    end
  end

  defp public_prometheus?(config) when is_list(config),
    do: Keyword.get(config, :public, false) == true

  defp public_prometheus?(%{} = config),
    do: Map.get(config, :public, Map.get(config, "public", false)) == true

  defp public_prometheus?(_config), do: false

  defp token_ttl_days, do: div(PrometheusToken.default_ttl_seconds(), 24 * 60 * 60)

  defp row(id, label, value), do: %{id: id, label: label, value: text(value)}

  defp text(nil), do: "-"
  defp text(""), do: "-"
  defp text(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp text(value) when is_binary(value), do: value

  defp text(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: to_string(value)

  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value), do: inspect(value, limit: 8, printable_limit: 160)

  defp error_text(%{__exception__: true} = error), do: Exception.message(error)
  defp error_text(value), do: text(value)

  defp datetime_text(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_text(value), do: text(value)

  defp status_text(status) when status in ["ok", "attention", "blocked"], do: status
  defp status_text(:ok), do: "ok"
  defp status_text(:attention), do: "attention"
  defp status_text(:blocked), do: "blocked"
  defp status_text(_status), do: "attention"

  defp map_get(map, key, default \\ nil)

  defp map_get(nil, _key, default), do: default

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp safe_id(nil), do: "unknown"

  defp safe_id(value) do
    value
    |> text()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      id -> id
    end
  end

  defp redact(value) when is_binary(value) do
    value
    |> String.replace(
      ~r/(?i)authorization\s*[:=]\s*bearer\s+[^,\s]+/,
      "[REDACTED]"
    )
    |> String.replace(~r/(?i)bearer\s+[^,\s]+/, "[REDACTED]")
    |> String.replace(
      ~r/(?i)(secret|token|password|credential)(?:[=:]|\s+)\s*[^,\s]+/,
      "[REDACTED]"
    )
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      _other -> DateTime.utc_now()
    end
  end

  defp safe_call0(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_call1(fun, arg) do
    {:ok, fun.(arg)}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
