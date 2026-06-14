defmodule Maxio.IAM.Role do
  @moduledoc "Persisted IAM role metadata used by STS AssumeRole."
  use Ecto.Schema
  import Ecto.Changeset

  alias Maxio.Policy.Statement

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "iam_roles" do
    field :role_name, :string
    field :role_arn, :string
    field :trust_policy, :map
    field :max_session_duration_seconds, :integer, default: 3600
    field :tags, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required [:role_name, :role_arn, :trust_policy, :max_session_duration_seconds]
  @optional [:tags]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(role, attrs) do
    role
    |> cast(attrs, @required ++ @optional)
    |> trim_change(:role_name)
    |> trim_change(:role_arn)
    |> validate_required(@required)
    |> validate_length(:role_name, min: 1, max: 64)
    |> validate_format(:role_name, ~r/\A[A-Za-z0-9+=,.@_-]+\z/)
    |> validate_length(:role_arn, min: 1, max: 512)
    |> validate_number(:max_session_duration_seconds,
      greater_than_or_equal_to: 3600,
      less_than_or_equal_to: 43_200
    )
    |> validate_trust_policy()
    |> unique_constraint(:role_name, name: :iam_roles_role_name_index)
    |> unique_constraint(:role_arn, name: :iam_roles_role_arn_index)
  end

  defp validate_trust_policy(changeset) do
    validate_change(changeset, :trust_policy, fn :trust_policy, value ->
      with true <- is_map(value) and map_size(value) > 0,
           {:ok, encoded} <- Jason.encode(value),
           {:ok, statements} <-
             Statement.parse_trust_policy(encoded, get_field(changeset, :role_arn)),
           true <- statements != [] do
        []
      else
        _ -> [trust_policy: "must be a valid role trust policy"]
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
