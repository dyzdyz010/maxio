defmodule Maxio.Policy.PrincipalPolicy do
  @moduledoc "IAM identity policy schema：绑定到 principal ARN 的内联策略。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "principal_policies" do
    field :principal_arn, :string
    field :policy_name, :string
    field :document, :map

    timestamps(type: :utc_datetime_usec)
  end

  @required [:principal_arn, :policy_name, :document]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> validate_length(:principal_arn, min: 1)
    |> validate_length(:policy_name, min: 1, max: 128)
    |> unique_constraint([:principal_arn, :policy_name],
      name: :principal_policies_principal_arn_policy_name_index
    )
  end
end
