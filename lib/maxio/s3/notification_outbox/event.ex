defmodule Maxio.S3.NotificationOutbox.Event do
  @moduledoc "Persistent S3 bucket notification outbox event."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "s3_notification_outbox" do
    field :bucket, :string
    field :object_key, :string
    field :event_name, :string
    field :destination_type, :string
    field :destination_arn, :string
    field :configuration_id, :string
    field :sequence, :integer, read_after_writes: true
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :last_attempted_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    field :error_reason, :string
    field :payload, :map

    timestamps(type: :utc_datetime_usec)
  end

  @statuses ~w(pending delivering delivered failed)

  @required [
    :bucket,
    :object_key,
    :event_name,
    :destination_type,
    :status,
    :attempts,
    :next_attempt_at,
    :payload
  ]

  @optional [
    :destination_arn,
    :configuration_id,
    :last_attempted_at,
    :delivered_at,
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
