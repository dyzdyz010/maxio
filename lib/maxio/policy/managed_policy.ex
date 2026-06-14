defmodule Maxio.Policy.ManagedPolicy do
  @moduledoc "IAM managed policy schema：按 policy ARN 独立持久化，可被 STS PolicyArns 引用。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "managed_policies" do
    field :policy_arn, :string
    field :document, :map

    timestamps(type: :utc_datetime_usec)
  end

  @required [:policy_arn, :document]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> validate_length(:policy_arn, min: 1, max: 768)
    |> unique_constraint(:policy_arn, name: :managed_policies_policy_arn_index)
    |> unique_constraint(:policy_arn, name: :managed_policies_policy_name_lower_index)
  end
end
