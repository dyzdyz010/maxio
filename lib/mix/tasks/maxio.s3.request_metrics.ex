defmodule Mix.Tasks.Maxio.S3.RequestMetrics do
  @shortdoc "Query local S3 request metrics ledger"
  @moduledoc """
  Queries the local best-effort S3 request metrics ledger.

      mix maxio.s3.request_metrics --bucket photos
      mix maxio.s3.request_metrics --bucket photos --id entire --minutes 60 --json
      mix maxio.s3.request_metrics --operation get_object --status-class 4xx

  This task is read-only. It does not emit CloudWatch metrics, run schedulers,
  or roll up data.
  """

  use Mix.Task

  alias Maxio.S3.Metrics.RequestMetrics

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          bucket: :string,
          id: :string,
          from: :string,
          until: :string,
          minutes: :integer,
          operation: :string,
          status_class: :string,
          limit: :integer,
          json: :boolean
        ],
        aliases: [b: :bucket]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.s3.request_metrics [--bucket BUCKET] [--id ID] " <>
          "[--from ISO8601 --until ISO8601 | --minutes N] [--operation OP] " <>
          "[--status-class 2xx|3xx|4xx|5xx|other] [--limit N] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_opts!(opts)
    Mix.Task.run("app.start")

    rows =
      RequestMetrics.list(
        []
        |> maybe_put(:bucket, Keyword.get(opts, :bucket))
        |> maybe_put(:filter_id, Keyword.get(opts, :id))
        |> maybe_put(:from, from_time(opts))
        |> maybe_put(:to, until_time(opts))
        |> maybe_put(:operation, Keyword.get(opts, :operation))
        |> maybe_put(:status_class, Keyword.get(opts, :status_class))
        |> maybe_put(:limit, Keyword.get(opts, :limit))
      )

    print_rows(rows, opts)
  end

  defp validate_opts!(opts) do
    if Keyword.has_key?(opts, :minutes) and
         (Keyword.has_key?(opts, :from) or Keyword.has_key?(opts, :until)) do
      Mix.raise("--minutes cannot be combined with --from or --until")
    end

    validate_time!("--from", Keyword.get(opts, :from))
    validate_time!("--until", Keyword.get(opts, :until))
    validate_minutes!(Keyword.get(opts, :minutes))
    validate_limit!(Keyword.get(opts, :limit))
    validate_status_class!(Keyword.get(opts, :status_class))
  end

  defp validate_time!(_flag, nil), do: :ok

  defp validate_time!(flag, value) do
    case DateTime.from_iso8601(value) do
      {:ok, _time, _offset} -> :ok
      {:error, _reason} -> Mix.raise("#{flag} must be ISO8601 DateTime, got #{inspect(value)}")
    end
  end

  defp validate_minutes!(nil), do: :ok
  defp validate_minutes!(value) when is_integer(value) and value > 0, do: :ok

  defp validate_minutes!(value),
    do: Mix.raise("--minutes must be a positive integer, got #{inspect(value)}")

  defp validate_limit!(nil), do: :ok
  defp validate_limit!(value) when is_integer(value) and value > 0, do: :ok

  defp validate_limit!(value),
    do: Mix.raise("--limit must be a positive integer, got #{inspect(value)}")

  defp validate_status_class!(nil), do: :ok

  defp validate_status_class!(value) when value in ["2xx", "3xx", "4xx", "5xx", "other"],
    do: :ok

  defp validate_status_class!(value),
    do:
      Mix.raise("--status-class must be one of 2xx, 3xx, 4xx, 5xx, other, got #{inspect(value)}")

  defp from_time(opts) do
    cond do
      minutes = Keyword.get(opts, :minutes) ->
        DateTime.utc_now()
        |> DateTime.add(-minutes, :minute)
        |> DateTime.truncate(:microsecond)

      from = Keyword.get(opts, :from) ->
        parse_time!(from)

      true ->
        nil
    end
  end

  defp until_time(opts) do
    case Keyword.get(opts, :until) do
      nil -> nil
      value -> parse_time!(value)
    end
  end

  defp parse_time!(value) do
    {:ok, time, _offset} = DateTime.from_iso8601(value)
    DateTime.truncate(time, :microsecond)
  end

  defp print_rows(rows, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(
        Jason.encode!(%{count: length(rows), metrics: Enum.map(rows, &RequestMetrics.to_map/1)})
      )
    else
      print_text(rows)
    end
  end

  defp print_text(rows) do
    IO.puts("[maxio s3.request_metrics] rows=#{length(rows)}")

    Enum.each(rows, fn row ->
      IO.puts(
        "[maxio s3.request_metrics] bucket=#{safe(row.bucket)} id=#{safe(row.filter_id)} " <>
          "window=#{safe(DateTime.to_iso8601(row.window_started_at))} " <>
          "operation=#{safe(row.operation)} status=#{row.status_code} " <>
          "class=#{safe(row.status_class)} count=#{row.request_count} " <>
          "uploaded=#{row.bytes_uploaded_sum} downloaded=#{row.bytes_downloaded_sum} " <>
          "latency_sum=#{row.latency_ms_sum} latency_min=#{row.latency_ms_min} " <>
          "latency_max=#{row.latency_ms_max}"
      )
    end)
  end

  defp safe(nil), do: inspect("")
  defp safe(value), do: inspect(to_string(value), printable_limit: 200)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
