defmodule Maxio.IAM.Group do
  @moduledoc "Persisted local IAM group metadata."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "iam_groups" do
    field :group_name, :string
    field :group_arn, :string
    field :status, :string, default: "active"
    field :tags, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required [:group_name, :group_arn]
  @optional [:status, :tags]
  @name_pattern ~r/\A[A-Za-z0-9+=,.@_-]+\z/
  @group_arn_pattern ~r/\Aarn:aws:iam:::group\/[A-Za-z0-9+=,.@_-]+\z/

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(group, attrs) do
    group
    |> cast(attrs, @required ++ @optional)
    |> trim_change(:group_name)
    |> trim_change(:group_arn)
    |> validate_required(@required)
    |> validate_length(:group_name, min: 1, max: 128)
    |> validate_format(:group_name, @name_pattern)
    |> validate_length(:group_arn, min: 1, max: 512)
    |> validate_format(:group_arn, @group_arn_pattern)
    |> validate_arn_matches_name(:group_arn, :group_name, "group")
    |> validate_inclusion(:status, ["active", "inactive"])
    |> unique_constraint(:group_name, name: :iam_groups_group_name_index)
    |> unique_constraint(:group_name, name: :iam_groups_group_name_ci_index)
    |> unique_constraint(:group_arn, name: :iam_groups_group_arn_index)
  end

  defp validate_arn_matches_name(changeset, arn_field, name_field, kind) do
    validate_change(changeset, arn_field, fn field, value ->
      name = get_field(changeset, name_field)
      expected = if is_binary(name) and name != "", do: "arn:aws:iam:::#{kind}/#{name}"

      if value == expected do
        []
      else
        [{field, "must match #{kind} name"}]
      end
    end)
  end

  defp trim_change(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.trim(value)
      value -> value
    end)
  end
end
