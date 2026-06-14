defmodule Maxio.Cluster.SchedulerRun do
  @moduledoc "Append-only run record for background cluster schedulers."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "cluster_scheduler_runs" do
    field :scheduler, :string
    field :trigger, :string
    field :node, :string
    field :status, :string
    field :result_kind, :string
    field :phase, :string
    field :job_id, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :duration_ms, :integer, default: 0
    field :consecutive_failures_after, :integer, default: 0
    field :backoff_until, :utc_datetime_usec
    field :alert_status, :string, default: "ok"
    field :summary, :map, default: %{}
    field :error_reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  @schedulers ~w(fresh_drive_heal rebalance)
  @triggers ~w(manual scheduled)
  @statuses ~w(ok idle skipped blocked failed)
  @result_kinds ~w(ok error)
  @alert_statuses ~w(ok warning alert)

  @required [
    :scheduler,
    :trigger,
    :node,
    :status,
    :result_kind,
    :started_at,
    :finished_at,
    :duration_ms,
    :consecutive_failures_after,
    :alert_status,
    :summary
  ]

  @optional [
    :phase,
    :job_id,
    :backoff_until,
    :error_reason
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:scheduler, @schedulers)
    |> validate_inclusion(:trigger, @triggers)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:result_kind, @result_kinds)
    |> validate_inclusion(:alert_status, @alert_statuses)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:consecutive_failures_after, greater_than_or_equal_to: 0)
  end
end
