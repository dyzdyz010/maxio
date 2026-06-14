defmodule Maxio.IAM.RoleManagedPolicyAttachment do
  @moduledoc "IAM role attached managed policy binding."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "iam_role_managed_policy_attachments" do
    field :role_arn, :string
    field :policy_arn, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required [:role_arn, :policy_arn]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> validate_length(:role_arn, min: 1, max: 512)
    |> validate_length(:policy_arn, min: 1, max: 768)
    |> unique_constraint(:policy_arn,
      name: :iam_role_managed_policy_attachments_role_policy_index
    )
    |> foreign_key_constraint(:role_arn)
    |> foreign_key_constraint(:policy_arn)
  end
end
