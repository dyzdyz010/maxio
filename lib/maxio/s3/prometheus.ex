defmodule Maxio.S3.Prometheus do
  @moduledoc """
  MinIO-style Prometheus text exposition for Maxio-local usage metrics.

  This exporter intentionally starts with durable, locally authoritative usage
  facts from bucket/object metadata. It does not claim CloudWatch delivery or
  full MinIO metric-family parity.
  """

  import Ecto.Query

  alias Maxio.Buckets.Bucket
  alias Maxio.Objects.Object
  alias Maxio.Repo

  @content_type "text/plain; version=0.0.4; charset=utf-8"

  @type family :: :cluster | :objects | :buckets

  @spec content_type() :: String.t()
  def content_type, do: @content_type

  @spec family_for_path(String.t()) :: {:ok, family()} | :unknown
  def family_for_path(path) when is_binary(path) do
    case String.trim_trailing(path, "/") do
      "/minio/metrics/v3" -> {:ok, :cluster}
      "/minio/metrics/v3/cluster" -> {:ok, :cluster}
      "/minio/metrics/v3/cluster/usage/objects" -> {:ok, :objects}
      "/minio/metrics/v3/cluster/usage/buckets" -> {:ok, :buckets}
      "/minio/v2/metrics" -> {:ok, :cluster}
      "/minio/v2/metrics/cluster" -> {:ok, :cluster}
      _other -> :unknown
    end
  end

  @spec metrics_path?(String.t()) :: boolean()
  def metrics_path?(path) when is_binary(path) do
    path == "/minio/v2/metrics" or
      String.starts_with?(path, "/minio/v2/metrics/") or
      path == "/minio/metrics/v3" or
      String.starts_with?(path, "/minio/metrics/v3/")
  end

  @spec render(family()) :: iodata()
  def render(family) when family in [:cluster, :objects, :buckets] do
    stats = usage_stats()

    []
    |> maybe_add_objects(family, stats)
    |> maybe_add_buckets(family, stats)
    |> Enum.reverse()
  end

  @spec usage_stats(keyword()) :: map()
  def usage_stats(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    bucket_names = bucket_names(repo)
    usage_by_bucket = bucket_usage(repo) |> Map.new(&{&1.bucket, &1})

    buckets =
      Enum.map(bucket_names, fn bucket ->
        Map.get(usage_by_bucket, bucket, zero_bucket(bucket))
      end)

    %{
      bucket_count: length(bucket_names),
      object_count: Enum.sum(Enum.map(buckets, & &1.object_count)),
      version_count: Enum.sum(Enum.map(buckets, & &1.version_count)),
      delete_marker_count: Enum.sum(Enum.map(buckets, & &1.delete_marker_count)),
      total_bytes: Enum.sum(Enum.map(buckets, & &1.total_bytes)),
      buckets: buckets
    }
  end

  defp maybe_add_objects(lines, family, stats) when family in [:cluster, :objects] do
    lines
    |> add_metric(
      "minio_cluster_usage_objects_since_last_update_seconds",
      "Time since last update of usage metrics in seconds.",
      "gauge",
      0
    )
    |> add_metric(
      "minio_cluster_usage_objects_count",
      "Total number of current non-delete-marker objects in the cluster.",
      "gauge",
      stats.object_count
    )
    |> add_metric(
      "minio_cluster_usage_objects_versions_count",
      "Total number of object versions including delete markers in the cluster.",
      "gauge",
      stats.version_count
    )
    |> add_metric(
      "minio_cluster_usage_objects_delete_markers_count",
      "Total number of delete-marker versions in the cluster.",
      "gauge",
      stats.delete_marker_count
    )
    |> add_metric(
      "minio_cluster_usage_objects_buckets_count",
      "Total number of buckets in the cluster.",
      "gauge",
      stats.bucket_count
    )
    |> add_metric(
      "minio_cluster_usage_objects_total_bytes",
      "Total logical bytes across all non-delete-marker object versions.",
      "gauge",
      stats.total_bytes
    )
  end

  defp maybe_add_objects(lines, _family, _stats), do: lines

  defp maybe_add_buckets(lines, family, stats) when family in [:cluster, :buckets] do
    lines =
      add_metric(
        lines,
        "minio_cluster_usage_buckets_since_last_update_seconds",
        "Time since last update of usage metrics in seconds.",
        "gauge",
        0
      )

    stats.buckets
    |> bucket_series(lines)
  end

  defp maybe_add_buckets(lines, _family, _stats), do: lines

  defp add_metric(lines, name, help, type, value, labels \\ []) do
    sample = [name, labels(labels), " ", format_value(value), "\n"]
    [["# HELP ", name, " ", help, "\n", "# TYPE ", name, " ", type, "\n", sample] | lines]
  end

  defp add_metric_series(lines, name, help, type, samples) do
    sample_lines =
      Enum.map(samples, fn {value, labels} ->
        [name, labels(labels), " ", format_value(value), "\n"]
      end)

    [["# HELP ", name, " ", help, "\n", "# TYPE ", name, " ", type, "\n", sample_lines] | lines]
  end

  defp bucket_series(buckets, lines) do
    lines
    |> add_metric_series(
      "minio_cluster_usage_buckets_objects_count",
      "Total number of current non-delete-marker objects in a bucket.",
      "gauge",
      Enum.map(buckets, &{&1.object_count, [bucket: &1.bucket]})
    )
    |> add_metric_series(
      "minio_cluster_usage_buckets_versions_count",
      "Total number of object versions including delete markers in a bucket.",
      "gauge",
      Enum.map(buckets, &{&1.version_count, [bucket: &1.bucket]})
    )
    |> add_metric_series(
      "minio_cluster_usage_buckets_delete_markers_count",
      "Total number of delete-marker versions in a bucket.",
      "gauge",
      Enum.map(buckets, &{&1.delete_marker_count, [bucket: &1.bucket]})
    )
    |> add_metric_series(
      "minio_cluster_usage_buckets_total_bytes",
      "Total logical bytes across all non-delete-marker object versions in a bucket.",
      "gauge",
      Enum.map(buckets, &{&1.total_bytes, [bucket: &1.bucket]})
    )
  end

  defp labels([]), do: ""

  defp labels(labels) do
    encoded =
      labels
      |> Enum.map(fn {key, value} -> [Atom.to_string(key), "=\"", escape_label(value), "\""] end)
      |> Enum.intersperse(",")

    ["{", encoded, "}"]
  end

  defp escape_label(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\"", "\\\"")
  end

  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(%Decimal{} = value), do: value |> Decimal.to_integer() |> Integer.to_string()

  defp format_value(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 6])

  defp bucket_names(repo) do
    Bucket
    |> select([b], b.name)
    |> order_by([b], asc: b.name)
    |> repo.all()
  end

  defp bucket_usage(repo) do
    from(o in Object,
      group_by: o.bucket_name,
      select: %{
        bucket: o.bucket_name,
        object_count:
          type(
            fragment(
              "COALESCE(SUM(CASE WHEN ? = TRUE AND ? = FALSE THEN 1 ELSE 0 END), 0)",
              o.is_latest,
              o.is_delete_marker
            ),
            :integer
          ),
        version_count: count(o.id),
        delete_marker_count:
          type(
            fragment(
              "COALESCE(SUM(CASE WHEN ? = TRUE THEN 1 ELSE 0 END), 0)",
              o.is_delete_marker
            ),
            :integer
          ),
        total_bytes:
          type(
            fragment(
              "COALESCE(SUM(CASE WHEN ? = FALSE THEN ? ELSE 0 END), 0)",
              o.is_delete_marker,
              o.size
            ),
            :integer
          )
      },
      order_by: [asc: o.bucket_name]
    )
    |> repo.all()
  end

  defp zero_bucket(bucket) do
    %{
      bucket: bucket,
      object_count: 0,
      version_count: 0,
      delete_marker_count: 0,
      total_bytes: 0
    }
  end
end
