defmodule Maxio.Cluster.SchedulerState do
  @moduledoc "Restart-stable state for a background cluster scheduler."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "cluster_scheduler_states" do
    field :scheduler, :string
    field :node, :string
    field :status, :string, default: "idle"
    field :consecutive_failures, :integer, default: 0
    field :last_run_id, :binary_id
    field :last_started_at, :utc_datetime_usec
    field :last_finished_at, :utc_datetime_usec
    field :backoff_until, :utc_datetime_usec
    field :alert_status, :string, default: "ok"
    field :alerted_at, :utc_datetime_usec
    field :last_error_reason, :string
    field :last_summary, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @schedulers ~w(fresh_drive_heal rebalance)
  @statuses ~w(ok idle skipped blocked failed)
  @alert_statuses ~w(ok warning alert)

  @required [
    :scheduler,
    :status,
    :consecutive_failures,
    :alert_status,
    :last_summary
  ]

  @optional [
    :node,
    :last_run_id,
    :last_started_at,
    :last_finished_at,
    :backoff_until,
    :alerted_at,
    :last_error_reason
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(state, attrs) do
    state
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:scheduler, @schedulers)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:alert_status, @alert_statuses)
    |> validate_number(:consecutive_failures, greater_than_or_equal_to: 0)
    |> unique_constraint(:scheduler, name: :cluster_scheduler_states_scheduler_index)
  end
end
