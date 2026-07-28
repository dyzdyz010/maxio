defmodule Maxio.S3.Metrics.RequestMetric do
  @moduledoc """
  Minute-level local S3 request metrics aggregate.

  This is Maxio's local ledger for Bucket Metrics configurations. It records
  request counters and observed bytes; it is not a CloudWatch emitter.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "s3_request_metrics" do
    field :bucket, :string
    field :filter_id, :string
    field :window_started_at, :utc_datetime_usec
    field :operation, :string
    field :metric_family, :string
    field :status_code, :integer
    field :status_class, :string
    field :request_count, :integer, default: 0
    field :bytes_uploaded_sum, :integer, default: 0
    field :bytes_downloaded_sum, :integer, default: 0
    field :latency_ms_sum, :integer, default: 0
    field :latency_ms_min, :integer, default: 0
    field :latency_ms_max, :integer, default: 0
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required [
    :bucket,
    :filter_id,
    :window_started_at,
    :operation,
    :metric_family,
    :status_code,
    :status_class,
    :request_count,
    :bytes_uploaded_sum,
    :bytes_downloaded_sum,
    :latency_ms_sum,
    :latency_ms_min,
    :latency_ms_max,
    :first_seen_at,
    :last_seen_at
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(metric, attrs) do
    metric
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> unique_constraint([:bucket, :filter_id, :window_started_at, :operation, :status_code],
      name: :s3_request_metrics_unique_window_operation_status_index
    )
  end
end
