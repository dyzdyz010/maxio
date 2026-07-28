defmodule Maxio.S3.Inventory.ReportRun do
  @moduledoc "Persistent ledger row for scheduled S3 Inventory report generation."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "s3_inventory_report_runs" do
    field :bucket, :string
    field :inventory_id, :string
    field :report_date, :date
    field :frequency, :string
    field :config_hash, :string
    field :trigger, :string
    field :status, :string
    field :attempts, :integer, default: 0
    field :run_id, :string
    field :file_id, :string
    field :lease_until, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :duration_ms, :integer, default: 0
    field :manifest_key, :string
    field :data_key, :string
    field :checksum_key, :string
    field :symlink_key, :string
    field :rows_written, :integer, default: 0
    field :objects_written, :integer, default: 0
    field :summary, :map, default: %{}
    field :error_reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  @frequencies ~w(Daily Weekly)
  @triggers ~w(manual scheduled)
  @statuses ~w(running ok failed skipped)

  @required [
    :bucket,
    :inventory_id,
    :report_date,
    :frequency,
    :config_hash,
    :trigger,
    :status,
    :attempts,
    :run_id,
    :file_id,
    :started_at,
    :duration_ms,
    :rows_written,
    :objects_written,
    :summary
  ]

  @optional [
    :lease_until,
    :finished_at,
    :manifest_key,
    :data_key,
    :checksum_key,
    :symlink_key,
    :error_reason
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:frequency, @frequencies)
    |> validate_inclusion(:trigger, @triggers)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:rows_written, greater_than_or_equal_to: 0)
    |> validate_number(:objects_written, greater_than_or_equal_to: 0)
    |> validate_length(:config_hash, is: 64)
    |> unique_constraint([:bucket, :inventory_id, :report_date],
      name: :s3_inventory_report_runs_unique_report_index
    )
  end
end
