defmodule Maxio.IAM.GroupMembership do
  @moduledoc "IAM user to group membership binding."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "iam_group_memberships" do
    field :user_arn, :string
    field :group_arn, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required [:user_arn, :group_arn]
  @user_arn_pattern ~r/\Aarn:aws:iam:::user\/[A-Za-z0-9+=,.@_-]+\z/
  @group_arn_pattern ~r/\Aarn:aws:iam:::group\/[A-Za-z0-9+=,.@_-]+\z/

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> validate_length(:user_arn, min: 1, max: 512)
    |> validate_length(:group_arn, min: 1, max: 512)
    |> validate_format(:user_arn, @user_arn_pattern)
    |> validate_format(:group_arn, @group_arn_pattern)
    |> unique_constraint(:group_arn, name: :iam_group_memberships_user_group_index)
    |> foreign_key_constraint(:user_arn)
    |> foreign_key_constraint(:group_arn)
  end
end
