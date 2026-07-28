defmodule Maxio.Console.Stats do
  @moduledoc """
  Console Dashboard 聚合（直接 Repo 聚合，无 Prometheus）。
  object_count/total_size 只算当前版本（is_latest=true 且非 delete marker），与 ListObjectsV2 口径一致。
  """
  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.Buckets.Bucket
  alias Maxio.Objects.Object
  alias Maxio.Multipart.Upload
  alias Maxio.S3.Metrics.RequestMetrics

  @request_metrics_stream_limit 25
  @request_metrics_range_minutes 60

  @type t :: %{
          bucket_count: non_neg_integer(),
          object_count: non_neg_integer(),
          total_size: non_neg_integer(),
          access_key_count: non_neg_integer(),
          multipart_count: non_neg_integer(),
          per_bucket: [
            %{name: String.t(), object_count: non_neg_integer(), size: non_neg_integer()}
          ],
          request_metrics: map()
        }

  @doc "汇总 Dashboard 所需全部计数。"
  @spec dashboard(keyword()) :: t()
  def dashboard(opts \\ []) do
    current = from o in Object, where: o.is_latest == true and o.is_delete_marker == false

    %{
      bucket_count: Repo.aggregate(Bucket, :count, :id),
      object_count: Repo.aggregate(current, :count, :id),
      total_size: Repo.aggregate(current, :sum, :size) || 0,
      access_key_count: length(Maxio.IAM.list_access_keys()),
      multipart_count: Repo.aggregate(Upload, :count, :id),
      per_bucket: per_bucket(),
      request_metrics: request_metrics(Keyword.get(opts, :request_metrics, []))
    }
  end

  defp per_bucket do
    from(o in Object,
      where: o.is_latest == true and o.is_delete_marker == false,
      group_by: o.bucket_name,
      select: %{
        name: o.bucket_name,
        object_count: count(o.id),
        size: coalesce(sum(o.size), 0)
      },
      order_by: [asc: o.bucket_name]
    )
    |> Repo.all()
  end

  defp request_metrics(opts) do
    streams =
      RequestMetrics.streams(
        limit: Keyword.get(opts, :stream_limit, @request_metrics_stream_limit)
      )

    selected = selected_stream(streams, opts)
    range_minutes = Keyword.get(opts, :minutes, @request_metrics_range_minutes)
    now = Keyword.get(opts, :now)

    series =
      case selected do
        nil ->
          RequestMetrics.timeseries(non_nil_opts(minutes: range_minutes, now: now))

        %{bucket: bucket, filter_id: filter_id} ->
          RequestMetrics.timeseries(
            non_nil_opts(
              bucket: bucket,
              filter_id: filter_id,
              minutes: range_minutes,
              now: now
            )
          )
      end

    series
    |> Map.put(:streams, streams)
    |> Map.put(:selected, selected)
  end

  defp selected_stream(streams, opts) do
    bucket = Keyword.get(opts, :bucket)
    filter_id = Keyword.get(opts, :filter_id)

    Enum.find(streams, &(&1.bucket == bucket and &1.filter_id == filter_id)) ||
      List.first(streams)
  end

  defp non_nil_opts(opts), do: Enum.reject(opts, fn {_key, value} -> is_nil(value) end)
end
