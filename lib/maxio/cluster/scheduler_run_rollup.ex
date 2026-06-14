defmodule Maxio.Cluster.SchedulerRunRollup do
  @moduledoc "Durable closed-window rollup for scheduler run ledger rows."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "cluster_scheduler_run_rollups" do
    field :scheduler, :string
    field :trigger, :string
    field :window_started_at, :utc_datetime_usec
    field :window_finished_at, :utc_datetime_usec
    field :window_ms, :integer
    field :run_count, :integer, default: 0
    field :ok_count, :integer, default: 0
    field :idle_count, :integer, default: 0
    field :skipped_count, :integer, default: 0
    field :blocked_count, :integer, default: 0
    field :failed_count, :integer, default: 0
    field :effective_count, :integer, default: 0
    field :healthy_count, :integer, default: 0
    field :result_ok_count, :integer, default: 0
    field :result_error_count, :integer, default: 0
    field :duration_total_ms, :integer, default: 0
    field :duration_min_ms, :integer
    field :duration_max_ms, :integer
    field :first_run_id, :binary_id
    field :last_run_id, :binary_id
    field :last_status, :string
    field :last_result_kind, :string
    field :last_phase, :string
    field :last_job_id, :string
    field :last_finished_at, :utc_datetime_usec
    field :last_effective_run_id, :binary_id
    field :last_effective_status, :string
    field :last_effective_finished_at, :utc_datetime_usec
    field :last_healthy_run_id, :binary_id
    field :last_healthy_status, :string
    field :last_healthy_finished_at, :utc_datetime_usec
    field :last_error_reason, :string
    field :last_summary, :map, default: %{}
    field :source_max_updated_at, :utc_datetime_usec
    field :source_digest, :string
    field :rolled_up_at, :utc_datetime_usec
    field :rollup_version, :integer, default: 1
    field :pruned_at, :utc_datetime_usec
    field :pruned_run_count, :integer, default: 0
    field :pruned_source_digest, :string
    field :pruned_by_node, :string

    timestamps(type: :utc_datetime_usec)
  end

  @schedulers ~w(fresh_drive_heal rebalance)
  @triggers ~w(manual scheduled)
  @statuses ~w(ok idle skipped blocked failed)
  @result_kinds ~w(ok error)
  @rollup_version 1

  @required [
    :scheduler,
    :trigger,
    :window_started_at,
    :window_finished_at,
    :window_ms,
    :run_count,
    :ok_count,
    :idle_count,
    :skipped_count,
    :blocked_count,
    :failed_count,
    :effective_count,
    :healthy_count,
    :result_ok_count,
    :result_error_count,
    :duration_total_ms,
    :last_summary,
    :source_digest,
    :rolled_up_at,
    :rollup_version
  ]

  @optional [
    :duration_min_ms,
    :duration_max_ms,
    :first_run_id,
    :last_run_id,
    :last_status,
    :last_result_kind,
    :last_phase,
    :last_job_id,
    :last_finished_at,
    :last_effective_run_id,
    :last_effective_status,
    :last_effective_finished_at,
    :last_healthy_run_id,
    :last_healthy_status,
    :last_healthy_finished_at,
    :last_error_reason,
    :source_max_updated_at,
    :pruned_at,
    :pruned_run_count,
    :pruned_source_digest,
    :pruned_by_node
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rollup, attrs) do
    rollup
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:scheduler, @schedulers)
    |> validate_inclusion(:trigger, @triggers)
    |> validate_inclusion(:last_status, @statuses)
    |> validate_inclusion(:last_effective_status, @statuses)
    |> validate_inclusion(:last_healthy_status, @statuses)
    |> validate_inclusion(:last_result_kind, @result_kinds)
    |> validate_number(:window_ms, greater_than: 0)
    |> validate_number(:run_count, greater_than_or_equal_to: 0)
    |> validate_number(:ok_count, greater_than_or_equal_to: 0)
    |> validate_number(:idle_count, greater_than_or_equal_to: 0)
    |> validate_number(:skipped_count, greater_than_or_equal_to: 0)
    |> validate_number(:blocked_count, greater_than_or_equal_to: 0)
    |> validate_number(:failed_count, greater_than_or_equal_to: 0)
    |> validate_number(:effective_count, greater_than_or_equal_to: 0)
    |> validate_number(:healthy_count, greater_than_or_equal_to: 0)
    |> validate_number(:result_ok_count, greater_than_or_equal_to: 0)
    |> validate_number(:result_error_count, greater_than_or_equal_to: 0)
    |> validate_number(:duration_total_ms, greater_than_or_equal_to: 0)
    |> validate_number(:duration_min_ms, greater_than_or_equal_to: 0)
    |> validate_number(:duration_max_ms, greater_than_or_equal_to: 0)
    |> validate_number(:rollup_version, equal_to: @rollup_version)
    |> validate_number(:pruned_run_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:scheduler,
      name: :cluster_scheduler_run_rollups_scheduler_trigger_window_index
    )
  end
end
