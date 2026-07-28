defmodule Maxio.Policy.ManagedPolicyVersion do
  @moduledoc "IAM customer managed policy version schema."
  use Ecto.Schema
  import Ecto.Changeset

  alias Maxio.Policy.ManagedPolicy

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "managed_policy_versions" do
    field :version_id, :string
    field :document, :map
    field :is_default, :boolean, default: false

    belongs_to :managed_policy, ManagedPolicy

    timestamps(type: :utc_datetime_usec)
  end

  @required [:managed_policy_id, :version_id, :document, :is_default]
  @version_pattern ~r/\Av[1-9]\d*\z/

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(version, attrs) do
    version
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> validate_format(:version_id, @version_pattern)
    |> unique_constraint(:version_id, name: :managed_policy_versions_policy_version_index)
    |> unique_constraint(:managed_policy_id, name: :managed_policy_versions_default_index)
  end
end
