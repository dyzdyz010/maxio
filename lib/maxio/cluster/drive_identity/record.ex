defmodule Maxio.Cluster.DriveIdentity.Record do
  @moduledoc "Persistent software drive identity for one configured cluster endpoint."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "cluster_drive_identities" do
    field :node_name, :string
    field :drive_path, :string
    field :set_id, :integer
    field :endpoint_index, :integer
    field :drive_uuid, :string
    field :previous_drive_uuid, :string
    field :generation, :integer, default: 1
    field :identity_heal_required, :boolean, default: false
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :replacement_detected_at, :utc_datetime_usec
    field :healed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required [:node_name, :drive_path, :drive_uuid, :generation, :first_seen_at, :last_seen_at]
  @optional [
    :set_id,
    :endpoint_index,
    :previous_drive_uuid,
    :identity_heal_required,
    :replacement_detected_at,
    :healed_at
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:generation, greater_than: 0)
    |> validate_length(:drive_uuid, is: 32)
    |> validate_format(:drive_uuid, ~r/\A[0-9a-f]{32}\z/)
    |> validate_previous_uuid()
    |> unique_constraint([:node_name, :drive_path],
      name: :cluster_drive_identities_endpoint_index
    )
  end

  defp validate_previous_uuid(changeset) do
    case get_field(changeset, :previous_drive_uuid) do
      nil ->
        changeset

      _uuid ->
        changeset
        |> validate_length(:previous_drive_uuid, is: 32)
        |> validate_format(:previous_drive_uuid, ~r/\A[0-9a-f]{32}\z/)
    end
  end
end
