defmodule Maxio.Cluster.Rebalance.Job do
  @moduledoc "Persistent control-plane record for a rebalance/decommission job."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "cluster_rebalance_jobs" do
    field :kind, :string
    field :status, :string, default: "planned"
    field :data_movement_status, :string, default: "not_started"
    field :target_set_id, :integer
    field :current_only, :boolean, default: false
    field :include_drive_stats, :boolean, default: true
    field :page_size, :integer, default: 500
    field :plan_status, :string
    field :plan, :map
    field :plan_scanned, :integer, default: 0
    field :plan_bytes, :integer, default: 0
    field :plan_placement_fallbacks, :integer, default: 0
    field :cursor_bucket, :string
    field :cursor_key_marker, :string
    field :cursor_version_id_marker, :string
    field :progress_scanned, :integer, default: 0
    field :progress_moved, :integer, default: 0
    field :progress_skipped, :integer, default: 0
    field :progress_errors, :integer, default: 0
    field :cancel_requested_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :error_reason, :string
    field :requested_by, :string

    timestamps(type: :utc_datetime_usec)
  end

  @kinds ~w(rebalance decommission)
  @statuses ~w(planned running cancel_requested complete failed canceled)
  @data_movement_statuses ~w(not_started moving paused complete failed canceled)

  @required [
    :kind,
    :status,
    :data_movement_status,
    :current_only,
    :include_drive_stats,
    :page_size,
    :plan_status,
    :plan,
    :plan_scanned,
    :plan_bytes,
    :plan_placement_fallbacks,
    :progress_scanned,
    :progress_moved,
    :progress_skipped,
    :progress_errors,
    :started_at
  ]

  @optional [
    :target_set_id,
    :cursor_bucket,
    :cursor_key_marker,
    :cursor_version_id_marker,
    :cancel_requested_at,
    :finished_at,
    :error_reason,
    :requested_by
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(job, attrs) do
    job
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:data_movement_status, @data_movement_statuses)
    |> validate_number(:page_size, greater_than: 0)
    |> validate_number(:plan_scanned, greater_than_or_equal_to: 0)
    |> validate_number(:plan_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:plan_placement_fallbacks, greater_than_or_equal_to: 0)
    |> validate_number(:progress_scanned, greater_than_or_equal_to: 0)
    |> validate_number(:progress_moved, greater_than_or_equal_to: 0)
    |> validate_number(:progress_skipped, greater_than_or_equal_to: 0)
    |> validate_number(:progress_errors, greater_than_or_equal_to: 0)
    |> validate_target_set()
    |> unique_constraint(:status, name: :cluster_rebalance_jobs_active_singleton_index)
  end

  defp validate_target_set(changeset) do
    case get_field(changeset, :kind) do
      "decommission" -> validate_required(changeset, [:target_set_id])
      "rebalance" -> put_change(changeset, :target_set_id, nil)
      _other -> changeset
    end
  end
end
