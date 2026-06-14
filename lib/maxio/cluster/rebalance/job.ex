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
    field :destination_set_id, :integer
    field :source_cleanup_status, :string, default: "not_started"
    field :source_cleanup_cursor_bucket, :string
    field :source_cleanup_cursor_key_marker, :string
    field :source_cleanup_cursor_version_id_marker, :string
    field :source_cleanup_scanned, :integer, default: 0
    field :source_cleanup_deleted, :integer, default: 0
    field :source_cleanup_skipped, :integer, default: 0
    field :source_cleanup_errors, :integer, default: 0
    field :rebalance_closure_status, :string, default: "not_started"
    field :rebalance_closure_checked_at, :utc_datetime_usec
    field :rebalance_closure_verified_at, :utc_datetime_usec
    field :rebalance_closure_topology_hash, :string
    field :rebalance_closure_results, :map, default: %{}
    field :rebalance_closure_blockers, {:array, :string}, default: []
    field :rebalance_closure_error_reason, :string
    field :topology_removal_status, :string, default: "not_started"
    field :topology_removal_scope, :string, default: "none"
    field :topology_removal_current_hash, :string
    field :topology_removal_proposed_hash, :string
    field :topology_removal_target_endpoints, :map, default: %{}
    field :topology_removal_removed_pool_ids, {:array, :integer}, default: []
    field :topology_removal_applied_at, :utc_datetime_usec
    field :topology_removal_cluster_status, :string, default: "not_started"
    field :topology_removal_cluster_hash, :string
    field :topology_removal_cluster_nodes, {:array, :string}, default: []
    field :topology_removal_cluster_verified_at, :utc_datetime_usec
    field :topology_removal_deployment_status, :string, default: "not_started"
    field :topology_removal_deployment_hash, :string
    field :topology_removal_deployment_verified_at, :utc_datetime_usec
    field :physical_removal_status, :string, default: "not_started"
    field :physical_removal_scope, :string, default: "none"
    field :physical_removal_quarantine_id, :string
    field :physical_removal_manifest_hash, :string
    field :physical_removal_preflight_verified_at, :utc_datetime_usec
    field :physical_removal_started_at, :utc_datetime_usec
    field :physical_removal_completed_at, :utc_datetime_usec
    field :physical_removal_results, :map, default: %{}
    field :physical_removal_roots_quarantined, :integer, default: 0
    field :physical_removal_markers_written, :integer, default: 0
    field :physical_removal_errors, :integer, default: 0
    field :physical_removal_error_reason, :string
    field :physical_removal_purge_status, :string, default: "not_started"
    field :physical_removal_purge_scope, :string, default: "none"
    field :physical_removal_purge_quarantine_id, :string
    field :physical_removal_purge_manifest_hash, :string
    field :physical_removal_purge_retention_seconds, :integer, default: 0
    field :physical_removal_purge_retention_until, :utc_datetime_usec
    field :physical_removal_purge_preflight_verified_at, :utc_datetime_usec
    field :physical_removal_purge_started_at, :utc_datetime_usec
    field :physical_removal_purge_completed_at, :utc_datetime_usec
    field :physical_removal_purge_results, :map, default: %{}
    field :physical_removal_purge_roots_deleted, :integer, default: 0
    field :physical_removal_purge_files_deleted, :integer, default: 0
    field :physical_removal_purge_dirs_deleted, :integer, default: 0
    field :physical_removal_purge_bytes_deleted, :integer, default: 0
    field :physical_removal_purge_markers_written, :integer, default: 0
    field :physical_removal_purge_errors, :integer, default: 0
    field :physical_removal_purge_error_reason, :string
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
  @source_cleanup_statuses ~w(not_started moving skipped complete failed)
  @rebalance_closure_statuses ~w(not_started checking verified blocked failed)
  @topology_removal_statuses ~w(not_started runtime_local_applied failed)
  @topology_removal_scopes ~w(none runtime_local)
  @topology_removal_cluster_statuses ~w(not_started runtime_converged failed)
  @topology_removal_deployment_statuses ~w(not_started verified failed)
  @physical_removal_statuses ~w(not_started quarantining quarantined failed)
  @physical_removal_scopes ~w(none layout_quarantine)
  @physical_removal_purge_statuses ~w(not_started purging purged failed)
  @physical_removal_purge_scopes ~w(none quarantine_hard_delete)

  @required [
    :kind,
    :status,
    :data_movement_status,
    :source_cleanup_status,
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
    :source_cleanup_scanned,
    :source_cleanup_deleted,
    :source_cleanup_skipped,
    :source_cleanup_errors,
    :rebalance_closure_status,
    :rebalance_closure_results,
    :rebalance_closure_blockers,
    :topology_removal_status,
    :topology_removal_scope,
    :topology_removal_target_endpoints,
    :topology_removal_removed_pool_ids,
    :topology_removal_cluster_status,
    :topology_removal_cluster_nodes,
    :topology_removal_deployment_status,
    :physical_removal_status,
    :physical_removal_scope,
    :physical_removal_results,
    :physical_removal_roots_quarantined,
    :physical_removal_markers_written,
    :physical_removal_errors,
    :physical_removal_purge_status,
    :physical_removal_purge_scope,
    :physical_removal_purge_retention_seconds,
    :physical_removal_purge_results,
    :physical_removal_purge_roots_deleted,
    :physical_removal_purge_files_deleted,
    :physical_removal_purge_dirs_deleted,
    :physical_removal_purge_bytes_deleted,
    :physical_removal_purge_markers_written,
    :physical_removal_purge_errors,
    :started_at
  ]

  @optional [
    :target_set_id,
    :destination_set_id,
    :source_cleanup_cursor_bucket,
    :source_cleanup_cursor_key_marker,
    :source_cleanup_cursor_version_id_marker,
    :rebalance_closure_checked_at,
    :rebalance_closure_verified_at,
    :rebalance_closure_topology_hash,
    :rebalance_closure_error_reason,
    :topology_removal_current_hash,
    :topology_removal_proposed_hash,
    :topology_removal_applied_at,
    :topology_removal_cluster_hash,
    :topology_removal_cluster_verified_at,
    :topology_removal_deployment_hash,
    :topology_removal_deployment_verified_at,
    :physical_removal_quarantine_id,
    :physical_removal_manifest_hash,
    :physical_removal_preflight_verified_at,
    :physical_removal_started_at,
    :physical_removal_completed_at,
    :physical_removal_error_reason,
    :physical_removal_purge_quarantine_id,
    :physical_removal_purge_manifest_hash,
    :physical_removal_purge_retention_until,
    :physical_removal_purge_preflight_verified_at,
    :physical_removal_purge_started_at,
    :physical_removal_purge_completed_at,
    :physical_removal_purge_error_reason,
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
    |> validate_inclusion(:source_cleanup_status, @source_cleanup_statuses)
    |> validate_inclusion(:rebalance_closure_status, @rebalance_closure_statuses)
    |> validate_inclusion(:topology_removal_status, @topology_removal_statuses)
    |> validate_inclusion(:topology_removal_scope, @topology_removal_scopes)
    |> validate_inclusion(:topology_removal_cluster_status, @topology_removal_cluster_statuses)
    |> validate_inclusion(
      :topology_removal_deployment_status,
      @topology_removal_deployment_statuses
    )
    |> validate_inclusion(:physical_removal_status, @physical_removal_statuses)
    |> validate_inclusion(:physical_removal_scope, @physical_removal_scopes)
    |> validate_inclusion(:physical_removal_purge_status, @physical_removal_purge_statuses)
    |> validate_inclusion(:physical_removal_purge_scope, @physical_removal_purge_scopes)
    |> validate_number(:page_size, greater_than: 0)
    |> validate_number(:destination_set_id, greater_than_or_equal_to: 0)
    |> validate_number(:plan_scanned, greater_than_or_equal_to: 0)
    |> validate_number(:plan_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:plan_placement_fallbacks, greater_than_or_equal_to: 0)
    |> validate_number(:progress_scanned, greater_than_or_equal_to: 0)
    |> validate_number(:progress_moved, greater_than_or_equal_to: 0)
    |> validate_number(:progress_skipped, greater_than_or_equal_to: 0)
    |> validate_number(:progress_errors, greater_than_or_equal_to: 0)
    |> validate_number(:source_cleanup_scanned, greater_than_or_equal_to: 0)
    |> validate_number(:source_cleanup_deleted, greater_than_or_equal_to: 0)
    |> validate_number(:source_cleanup_skipped, greater_than_or_equal_to: 0)
    |> validate_number(:source_cleanup_errors, greater_than_or_equal_to: 0)
    |> validate_number(:physical_removal_roots_quarantined, greater_than_or_equal_to: 0)
    |> validate_number(:physical_removal_markers_written, greater_than_or_equal_to: 0)
    |> validate_number(:physical_removal_errors, greater_than_or_equal_to: 0)
    |> validate_number(:physical_removal_purge_retention_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:physical_removal_purge_roots_deleted, greater_than_or_equal_to: 0)
    |> validate_number(:physical_removal_purge_files_deleted, greater_than_or_equal_to: 0)
    |> validate_number(:physical_removal_purge_dirs_deleted, greater_than_or_equal_to: 0)
    |> validate_number(:physical_removal_purge_bytes_deleted, greater_than_or_equal_to: 0)
    |> validate_number(:physical_removal_purge_markers_written, greater_than_or_equal_to: 0)
    |> validate_number(:physical_removal_purge_errors, greater_than_or_equal_to: 0)
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
