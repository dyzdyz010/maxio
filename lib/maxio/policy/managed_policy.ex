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
    field :description, :string, default: ""
    field :tags, :map, default: %{}
    field :next_version_number, :integer, default: 2

    has_many :versions, Maxio.Policy.ManagedPolicyVersion

    timestamps(type: :utc_datetime_usec)
  end

  @required [:policy_arn, :document]
  @optional [:description, :tags, :next_version_number]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:policy_arn, min: 1, max: 768)
    |> validate_length(:description, max: 1000)
    |> validate_number(:next_version_number, greater_than_or_equal_to: 2)
    |> unique_constraint(:policy_arn, name: :managed_policies_policy_arn_index)
    |> unique_constraint(:policy_arn, name: :managed_policies_policy_name_lower_index)
  end
end
