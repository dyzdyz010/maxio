defmodule Maxio.S3.Metrics.RequestMetrics do
  @moduledoc """
  Local request metrics ledger for S3 Bucket Metrics configurations.

  AWS S3 request metrics are delivered to CloudWatch. Maxio does not emit to
  CloudWatch in this slice; instead it maintains a best-effort, minute-level
  local ledger that can be inspected with CLI tooling.
  """

  import Ecto.Query
  import Plug.Conn, only: [get_req_header: 2, get_resp_header: 2]

  alias Maxio.Objects.Object
  alias Maxio.{ObjectMeta, Repo}
  alias Maxio.S3.{Dispatcher, Log, Metrics}
  alias Maxio.S3.Metrics.RequestMetric

  @bucket_list_operations MapSet.new(~w(
                            list_objects
                            list_objects_v2
                            list_object_versions
                            list_multipart_uploads
                          ))

  @single_object_operations MapSet.new(~w(
                              put_object
                              copy_object
                              post_object
                              get_object
                              head_object
                              delete_object
                              create_multipart_upload
                              upload_part
                              upload_part_copy
                              complete_multipart_upload
                              abort_multipart_upload
                              list_parts
                              get_object_attributes
                              restore_object
                              put_object_tagging
                              get_object_tagging
                              delete_object_tagging
                              get_object_acl
                              put_object_acl
                              put_object_retention
                              get_object_retention
                              put_object_legal_hold
                              get_object_legal_hold
                            ))

  @recordable_operations MapSet.union(
                           @single_object_operations,
                           MapSet.put(@bucket_list_operations, "delete_objects")
                         )

  @write_sized_operations MapSet.new(~w(
                            put_object
                            copy_object
                            post_object
                            complete_multipart_upload
                          ))

  @upload_body_operations MapSet.new(~w(upload_part))
  @download_operations MapSet.new(~w(get_object))

  @multipart_session_operations MapSet.new(~w(
                                  create_multipart_upload
                                  upload_part
                                  upload_part_copy
                                  complete_multipart_upload
                                  abort_multipart_upload
                                  list_parts
                                ))

  @default_limit 100
  @max_limit 1_000
  @default_timeseries_minutes 60
  @max_timeseries_minutes 240
  @status_classes ~w(2xx 3xx 4xx 5xx other)

  @type event :: %{
          bucket: String.t(),
          key: String.t() | nil,
          operation: String.t(),
          metric_family: String.t(),
          status_code: non_neg_integer(),
          status_class: String.t(),
          window_started_at: DateTime.t(),
          latency_ms: non_neg_integer(),
          bytes_uploaded: non_neg_integer(),
          bytes_downloaded: non_neg_integer(),
          tags: map()
        }

  @spec record_conn(Plug.Conn.t(), keyword()) :: :ok
  def record_conn(conn, opts \\ []) do
    case event_from_conn(conn) do
      {:ok, event} -> record_event(event, opts)
      :skip -> :ok
    end
  rescue
    err ->
      Log.warn("request metrics recording skipped",
        action: conn.assigns[:s3_action],
        bucket: conn.assigns[:s3_bucket],
        key: conn.assigns[:s3_key],
        reason: Exception.message(err)
      )

      :ok
  catch
    kind, reason ->
      Log.warn("request metrics recording caught",
        action: conn.assigns[:s3_action],
        bucket: conn.assigns[:s3_bucket],
        key: conn.assigns[:s3_key],
        reason: inspect({kind, reason})
      )

      :ok
  end

  @spec record_event(event(), keyword()) :: :ok
  def record_event(%{} = event, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    configs = Metrics.all_configs(event.bucket)

    configs
    |> Enum.filter(&config_matches?(&1, event))
    |> upsert_matches(event, repo)

    :ok
  rescue
    err ->
      Log.warn("request metrics event skipped",
        operation: Map.get(event, :operation),
        bucket: Map.get(event, :bucket),
        key: Map.get(event, :key),
        reason: Exception.message(err)
      )

      :ok
  end

  @spec list(keyword()) :: [RequestMetric.t()]
  def list(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    limit = opts |> Keyword.get(:limit, @default_limit) |> bounded_limit()

    RequestMetric
    |> maybe_where(:bucket, Keyword.get(opts, :bucket))
    |> maybe_where(:filter_id, Keyword.get(opts, :filter_id))
    |> maybe_where(:operation, Keyword.get(opts, :operation))
    |> maybe_where(:status_class, Keyword.get(opts, :status_class))
    |> maybe_from(Keyword.get(opts, :from))
    |> maybe_to(Keyword.get(opts, :to))
    |> order_by([m],
      desc: m.window_started_at,
      asc: m.bucket,
      asc: m.filter_id,
      asc: m.operation,
      asc: m.status_code
    )
    |> limit(^limit)
    |> repo.all()
  end

  @spec streams(keyword()) :: [map()]
  def streams(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    limit = opts |> Keyword.get(:limit, @default_limit) |> bounded_limit()

    from(m in RequestMetric,
      group_by: [m.bucket, m.filter_id],
      select: %{
        bucket: m.bucket,
        filter_id: m.filter_id,
        last_seen_at: max(m.last_seen_at),
        request_count: type(fragment("COALESCE(SUM(?), 0)", m.request_count), :integer)
      },
      order_by: [desc: max(m.last_seen_at), asc: m.bucket, asc: m.filter_id],
      limit: ^limit
    )
    |> maybe_from(Keyword.get(opts, :from))
    |> repo.all()
  end

  @spec timeseries(keyword()) :: map()
  def timeseries(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    bucket = Keyword.get(opts, :bucket)
    filter_id = Keyword.get(opts, :filter_id)
    minutes = opts |> Keyword.get(:minutes, @default_timeseries_minutes) |> bounded_minutes()
    until_window = opts |> Keyword.get(:now, DateTime.utc_now()) |> window_started_at()
    from_window = DateTime.add(until_window, -60 * (minutes - 1), :second)

    rows =
      if blank?(bucket) or blank?(filter_id) do
        []
      else
        RequestMetric
        |> where([m], m.bucket == ^bucket and m.filter_id == ^filter_id)
        |> where([m], m.window_started_at >= ^from_window)
        |> where([m], m.window_started_at <= ^until_window)
        |> order_by([m], asc: m.window_started_at, asc: m.operation, asc: m.status_code)
        |> repo.all()
      end

    points = points(from_window, minutes, rows)

    %{
      selected: selected(bucket, filter_id),
      range_minutes: minutes,
      from: from_window,
      until: until_window,
      totals: totals(rows),
      points: points
    }
  end

  @spec to_map(RequestMetric.t()) :: map()
  def to_map(%RequestMetric{} = metric) do
    %{
      id: metric.id,
      bucket: metric.bucket,
      filter_id: metric.filter_id,
      window_started_at: DateTime.to_iso8601(metric.window_started_at),
      operation: metric.operation,
      metric_family: metric.metric_family,
      status_code: metric.status_code,
      status_class: metric.status_class,
      request_count: metric.request_count,
      bytes_uploaded_sum: metric.bytes_uploaded_sum,
      bytes_downloaded_sum: metric.bytes_downloaded_sum,
      latency_ms_sum: metric.latency_ms_sum,
      latency_ms_min: metric.latency_ms_min,
      latency_ms_max: metric.latency_ms_max,
      first_seen_at: DateTime.to_iso8601(metric.first_seen_at),
      last_seen_at: DateTime.to_iso8601(metric.last_seen_at),
      inserted_at: DateTime.to_iso8601(metric.inserted_at),
      updated_at: DateTime.to_iso8601(metric.updated_at)
    }
  end

  @spec event_from_conn(Plug.Conn.t()) :: {:ok, event()} | :skip
  defp event_from_conn(%{method: "OPTIONS"}), do: :skip

  defp event_from_conn(conn) do
    bucket = conn.assigns[:s3_bucket]
    operation = operation(conn)

    cond do
      not MapSet.member?(@recordable_operations, operation) ->
        :skip

      not is_binary(bucket) or bucket == "" ->
        :skip

      not is_integer(conn.status) ->
        :skip

      true ->
        event =
          %{
            bucket: bucket,
            key: conn.assigns[:s3_key],
            operation: operation,
            metric_family: metric_family(operation, conn.method),
            status_code: conn.status,
            status_class: status_class(conn.status),
            window_started_at: conn |> event_time() |> window_started_at(),
            latency_ms: response_start_latency_ms(conn),
            bytes_uploaded: bytes_uploaded(conn, operation),
            bytes_downloaded: bytes_downloaded(conn, operation),
            tags: tags_for_matching(conn, operation)
          }

        {:ok, event}
    end
  end

  defp upsert_matches([], _event, _repo), do: :ok

  defp upsert_matches(configs, event, repo) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    counters = counters(event)

    rows =
      Enum.map(configs, fn config ->
        Map.merge(counters, %{
          id: Ecto.UUID.generate(),
          bucket: event.bucket,
          filter_id: config["Id"],
          window_started_at: event.window_started_at,
          operation: event.operation,
          metric_family: event.metric_family,
          status_code: event.status_code,
          status_class: event.status_class,
          first_seen_at: now,
          last_seen_at: now,
          inserted_at: now,
          updated_at: now
        })
      end)

    {_count, _rows} =
      repo.insert_all(RequestMetric, rows,
        conflict_target: [:bucket, :filter_id, :window_started_at, :operation, :status_code],
        on_conflict: conflict_update(counters, event, now)
      )

    :ok
  end

  defp conflict_update(counters, event, now) do
    from(m in RequestMetric,
      update: [
        inc: [
          request_count: ^counters.request_count,
          bytes_uploaded_sum: ^counters.bytes_uploaded_sum,
          bytes_downloaded_sum: ^counters.bytes_downloaded_sum,
          latency_ms_sum: ^counters.latency_ms_sum
        ],
        set: [
          metric_family: ^event.metric_family,
          status_class: ^event.status_class,
          latency_ms_min: fragment("LEAST(?, ?)", m.latency_ms_min, ^event.latency_ms),
          latency_ms_max: fragment("GREATEST(?, ?)", m.latency_ms_max, ^event.latency_ms),
          last_seen_at: ^now,
          updated_at: ^now
        ]
      ]
    )
  end

  defp counters(event) do
    %{
      request_count: 1,
      bytes_uploaded_sum: event.bytes_uploaded,
      bytes_downloaded_sum: event.bytes_downloaded,
      latency_ms_sum: event.latency_ms,
      latency_ms_min: event.latency_ms,
      latency_ms_max: event.latency_ms
    }
  end

  defp operation(conn) do
    conn.assigns[:s3_metrics_operation]
    |> normalize_operation(conn)
    |> case do
      nil -> conn.assigns[:s3_action] |> normalize_operation(conn)
      operation -> operation
    end
    |> case do
      nil -> conn |> resolved_action() |> normalize_operation(conn)
      operation -> operation
    end
  end

  defp normalize_operation(nil, _conn), do: nil

  defp normalize_operation(:put_object, conn) do
    cond do
      header?(conn, "x-amz-copy-source") -> "copy_object"
      conn.method == "POST" -> "post_object"
      true -> "put_object"
    end
  end

  defp normalize_operation(:upload_part, conn) do
    if header?(conn, "x-amz-copy-source"), do: "upload_part_copy", else: "upload_part"
  end

  defp normalize_operation(operation, _conn) when is_atom(operation),
    do: Atom.to_string(operation)

  defp normalize_operation(operation, _conn) when is_binary(operation), do: operation
  defp normalize_operation(_operation, _conn), do: nil

  defp resolved_action(conn) do
    level = conn.assigns[:s3_level]

    if level in [:service, :bucket, :object] do
      query = query_params(conn)

      case Dispatcher.resolve(level, conn.method || "", query) do
        {:ok, action} -> action
        _other -> nil
      end
    end
  rescue
    _err -> nil
  catch
    _kind, _reason -> nil
  end

  defp query_params(%{query_params: %Plug.Conn.Unfetched{}} = conn),
    do: Plug.Conn.fetch_query_params(conn).query_params

  defp query_params(%{query_params: query}) when is_map(query), do: query
  defp query_params(_conn), do: %{}

  defp metric_family(operation, method) do
    cond do
      MapSet.member?(@bucket_list_operations, operation) or operation == "list_parts" ->
        "list"

      operation == "delete_objects" ->
        "delete"

      method in ["GET", "PUT", "DELETE", "HEAD", "POST"] ->
        String.downcase(method)

      true ->
        "other"
    end
  end

  defp status_class(status) when status >= 200 and status < 300, do: "2xx"
  defp status_class(status) when status >= 300 and status < 400, do: "3xx"
  defp status_class(status) when status >= 400 and status < 500, do: "4xx"
  defp status_class(status) when status >= 500 and status < 600, do: "5xx"
  defp status_class(_status), do: "other"

  defp config_matches?(%{"Filter" => filter}, event) do
    single_object?(event) and filter_matches?(filter, event)
  end

  defp config_matches?(_config, _event), do: true

  defp filter_matches?(%{"Prefix" => prefix}, %{key: key})
       when is_binary(prefix) and is_binary(key),
       do: String.starts_with?(key, prefix)

  defp filter_matches?(%{"Tag" => tag}, event), do: tag_matches?(tag, event.tags)

  defp filter_matches?(%{"AccessPointArn" => arn}, event) do
    Log.warn("request metrics access point filter skipped",
      operation: event.operation,
      bucket: event.bucket,
      key: event.key,
      access_point_arn: arn,
      reason: :access_points_not_supported
    )

    false
  end

  defp filter_matches?(%{"And" => and_filter}, event) do
    prefix_ok? =
      case Map.get(and_filter, "Prefix") do
        nil ->
          true

        prefix when is_binary(prefix) and is_binary(event.key) ->
          String.starts_with?(event.key, prefix)

        _other ->
          false
      end

    tags_ok? =
      and_filter
      |> Map.get("Tags", [])
      |> Enum.all?(&tag_matches?(&1, event.tags))

    access_point_ok? =
      case Map.get(and_filter, "AccessPointArn") do
        nil ->
          true

        arn ->
          Log.warn("request metrics access point filter skipped",
            operation: event.operation,
            bucket: event.bucket,
            key: event.key,
            access_point_arn: arn,
            reason: :access_points_not_supported
          )

          false
      end

    prefix_ok? and tags_ok? and access_point_ok?
  end

  defp filter_matches?(_filter, _event), do: false

  defp tag_matches?(%{"Key" => key, "Value" => value}, tags) when is_map(tags),
    do: Map.get(tags, key) == value

  defp tag_matches?(_tag, _tags), do: false

  defp tags_for_matching(conn, operation) do
    cond do
      not MapSet.member?(@single_object_operations, operation) ->
        %{}

      is_map(conn.assigns[:s3_metrics_tags]) ->
        conn.assigns[:s3_metrics_tags]

      MapSet.member?(@multipart_session_operations, operation) ->
        %{}

      true ->
        object_tags(conn)
    end
  end

  defp object_tags(%{assigns: %{s3_bucket: bucket, s3_key: key}}) when is_binary(key) do
    case ObjectMeta.get(bucket, key, nil, []) do
      %Object{is_delete_marker: false, tags: tags} when is_map(tags) -> tags
      _other -> %{}
    end
  rescue
    _err -> %{}
  catch
    _kind, _reason -> %{}
  end

  defp object_tags(_conn), do: %{}

  defp single_object?(%{operation: operation, key: key}),
    do: is_binary(key) and key != "" and MapSet.member?(@single_object_operations, operation)

  defp bytes_uploaded(conn, operation) do
    cond do
      explicit_int(conn.assigns[:s3_metrics_bytes_uploaded]) != nil ->
        explicit_int(conn.assigns[:s3_metrics_bytes_uploaded])

      success?(conn) and MapSet.member?(@write_sized_operations, operation) ->
        object_size(conn) || request_body_size(conn)

      success?(conn) and MapSet.member?(@upload_body_operations, operation) ->
        request_body_size(conn)

      true ->
        0
    end
  end

  defp bytes_downloaded(conn, operation) do
    cond do
      explicit_int(conn.assigns[:s3_metrics_bytes_downloaded]) != nil ->
        explicit_int(conn.assigns[:s3_metrics_bytes_downloaded])

      success?(conn) and MapSet.member?(@download_operations, operation) ->
        response_body_size(conn)

      true ->
        0
    end
  end

  defp object_size(%{assigns: %{s3_bucket: bucket, s3_key: key}}) when is_binary(key) do
    case ObjectMeta.get(bucket, key, nil, []) do
      %Object{is_delete_marker: false, size: size} when is_integer(size) and size >= 0 -> size
      _other -> nil
    end
  rescue
    _err -> nil
  catch
    _kind, _reason -> nil
  end

  defp object_size(_conn), do: nil

  defp request_body_size(conn) do
    conn
    |> header_int("x-amz-decoded-content-length", :req)
    |> case do
      nil -> header_int(conn, "content-length", :req) || 0
      size -> size
    end
  end

  defp response_body_size(conn) do
    conn
    |> header_int("content-length", :resp)
    |> case do
      nil -> iodata_size(conn.resp_body)
      size -> size
    end
  end

  defp iodata_size(nil), do: 0

  defp iodata_size(body) do
    IO.iodata_length(body)
  rescue
    _err -> 0
  end

  defp header_int(conn, name, source) do
    conn
    |> header(name, source)
    |> parse_non_negative_integer()
  end

  defp header?(conn, name), do: header(conn, name, :req) not in [nil, ""]
  defp header(conn, name, :req), do: conn |> get_req_header(name) |> List.first()
  defp header(conn, name, :resp), do: conn |> get_resp_header(name) |> List.first()

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _other -> nil
    end
  end

  defp parse_non_negative_integer(_value), do: nil

  defp explicit_int(value) when is_integer(value) and value >= 0, do: value
  defp explicit_int(_value), do: nil

  defp success?(%{status: status}) when is_integer(status), do: status >= 200 and status < 300
  defp success?(_conn), do: false

  defp event_time(conn) do
    case conn.private[:maxio_now] do
      %DateTime{} = time -> time
      _other -> DateTime.utc_now()
    end
  end

  defp window_started_at(%DateTime{} = time),
    do: %DateTime{time | second: 0, microsecond: {0, 6}}

  defp points(from_window, minutes, rows) do
    rows_by_window = Enum.group_by(rows, & &1.window_started_at)

    0..(minutes - 1)
    |> Enum.map(fn offset ->
      window = DateTime.add(from_window, offset * 60, :second)
      point(window, Map.get(rows_by_window, window, []))
    end)
  end

  defp point(window, rows) do
    request_count = sum_field(rows, :request_count)
    bytes_uploaded_sum = sum_field(rows, :bytes_uploaded_sum)
    bytes_downloaded_sum = sum_field(rows, :bytes_downloaded_sum)
    latency_ms_sum = sum_field(rows, :latency_ms_sum)

    %{
      window_started_at: window,
      label: window_label(window),
      request_count: request_count,
      error_count: error_count(rows),
      status_counts: status_counts(rows),
      bytes_uploaded_sum: bytes_uploaded_sum,
      bytes_downloaded_sum: bytes_downloaded_sum,
      bytes_total: bytes_uploaded_sum + bytes_downloaded_sum,
      latency_ms_avg: average(latency_ms_sum, request_count),
      latency_ms_max: max_field(rows, :latency_ms_max)
    }
  end

  defp totals(rows) do
    request_count = sum_field(rows, :request_count)
    bytes_uploaded_sum = sum_field(rows, :bytes_uploaded_sum)
    bytes_downloaded_sum = sum_field(rows, :bytes_downloaded_sum)
    latency_ms_sum = sum_field(rows, :latency_ms_sum)

    %{
      request_count: request_count,
      error_count: error_count(rows),
      bytes_uploaded_sum: bytes_uploaded_sum,
      bytes_downloaded_sum: bytes_downloaded_sum,
      latency_ms_avg: average(latency_ms_sum, request_count),
      latency_ms_max: max_field(rows, :latency_ms_max)
    }
  end

  defp status_counts(rows) do
    base = Map.new(@status_classes, &{&1, 0})

    Enum.reduce(rows, base, fn row, acc ->
      class = known_status_class(row.status_class)
      Map.update!(acc, class, &(&1 + row.request_count))
    end)
  end

  defp error_count(rows) do
    rows
    |> Enum.filter(&(&1.status_class in ["4xx", "5xx"]))
    |> sum_field(:request_count)
  end

  defp selected(bucket, filter_id) do
    if blank?(bucket) or blank?(filter_id) do
      nil
    else
      %{bucket: bucket, filter_id: filter_id}
    end
  end

  defp window_label(%DateTime{} = window) do
    hour = window.hour |> Integer.to_string() |> String.pad_leading(2, "0")
    minute = window.minute |> Integer.to_string() |> String.pad_leading(2, "0")
    hour <> ":" <> minute
  end

  defp average(_sum, 0), do: nil
  defp average(sum, count), do: sum / count

  defp sum_field(rows, field), do: Enum.sum(Enum.map(rows, &Map.get(&1, field, 0)))

  defp max_field([], _field), do: 0

  defp max_field(rows, field) do
    rows
    |> Enum.map(&Map.get(&1, field, 0))
    |> Enum.max()
  end

  defp known_status_class(class) when class in @status_classes, do: class
  defp known_status_class(_class), do: "other"

  defp response_start_latency_ms(conn) do
    case conn.private[:maxio_request_metrics_started_at] do
      started_at when is_integer(started_at) ->
        max(System.monotonic_time(:microsecond) - started_at, 0)
        |> div(1000)

      _other ->
        0
    end
  end

  defp maybe_where(query, _field, nil), do: query
  defp maybe_where(query, _field, ""), do: query

  defp maybe_where(query, field, value),
    do: where(query, [m], field(m, ^field) == ^value)

  defp maybe_from(query, nil), do: query
  defp maybe_from(query, %DateTime{} = from), do: where(query, [m], m.window_started_at >= ^from)

  defp maybe_to(query, nil), do: query
  defp maybe_to(query, %DateTime{} = to), do: where(query, [m], m.window_started_at <= ^to)

  defp bounded_limit(value) when is_integer(value) and value > 0, do: min(value, @max_limit)
  defp bounded_limit(_value), do: @default_limit

  defp bounded_minutes(value) when is_integer(value) and value > 0,
    do: min(value, @max_timeseries_minutes)

  defp bounded_minutes(_value), do: @default_timeseries_minutes

  defp blank?(value), do: not is_binary(value) or value == ""
end
