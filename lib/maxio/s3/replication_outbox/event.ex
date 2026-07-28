defmodule Maxio.S3.ReplicationOutbox.Event do
  @moduledoc "Persistent S3 bucket replication outbox task."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "s3_replication_outbox" do
    field :source_bucket, :string
    field :source_key, :string
    field :source_version_id, :string
    field :event_name, :string
    field :destination_bucket, :string
    field :rule_id, :string
    field :destination_storage_class, :string
    field :source_etag, :string
    field :source_size, :integer
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :last_attempted_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :error_reason, :string
    field :payload, :map

    timestamps(type: :utc_datetime_usec)
  end

  @statuses ~w(pending delivering completed failed)

  @required [
    :source_bucket,
    :source_key,
    :source_version_id,
    :event_name,
    :destination_bucket,
    :status,
    :attempts,
    :next_attempt_at,
    :payload
  ]

  @optional [
    :rule_id,
    :destination_storage_class,
    :source_etag,
    :source_size,
    :last_attempted_at,
    :completed_at,
    :error_reason
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
  end
end
