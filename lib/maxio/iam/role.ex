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
    field :description, :string, default: ""
    field :trust_policy, :map
    field :max_session_duration_seconds, :integer, default: 3600
    field :tags, :map, default: %{}
    field :permissions_boundary_policy_arn, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required [:role_name, :role_arn, :trust_policy, :max_session_duration_seconds]
  @optional [:description, :tags, :permissions_boundary_policy_arn]
  @name_pattern ~r/\A[A-Za-z0-9+=,.@_-]+\z/
  @role_arn_pattern ~r/\Aarn:aws:iam:::role\/[A-Za-z0-9+=,.@_-]+\z/
  @managed_policy_arn_pattern ~r|\Aarn:aws:iam:::policy/[A-Za-z0-9+=,.@_/-]+\z|

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(role, attrs) do
    role
    |> cast(attrs, @required ++ @optional)
    |> trim_change(:role_name)
    |> trim_change(:role_arn)
    |> validate_required(@required)
    |> validate_length(:role_name, min: 1, max: 64)
    |> validate_format(:role_name, @name_pattern)
    |> validate_length(:description, max: 1000)
    |> validate_description()
    |> validate_length(:role_arn, min: 1, max: 512)
    |> validate_format(:role_arn, @role_arn_pattern)
    |> validate_length(:permissions_boundary_policy_arn, max: 2048)
    |> validate_format(:permissions_boundary_policy_arn, @managed_policy_arn_pattern)
    |> validate_arn_matches_name(:role_arn, :role_name, "role")
    |> validate_number(:max_session_duration_seconds,
      greater_than_or_equal_to: 3600,
      less_than_or_equal_to: 43_200
    )
    |> validate_tags()
    |> validate_trust_policy()
    |> unique_constraint(:role_name, name: :iam_roles_role_name_index)
    |> unique_constraint(:role_name, name: :iam_roles_role_name_ci_index)
    |> unique_constraint(:role_arn, name: :iam_roles_role_arn_index)
  end

  defp validate_description(changeset) do
    validate_change(changeset, :description, fn :description, value ->
      if is_binary(value) and description_chars?(value) do
        []
      else
        [description: "must contain valid IAM description characters"]
      end
    end)
  end

  defp description_chars?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(fn char ->
      char in [0x09, 0x0A, 0x0D] or
        (char >= 0x20 and char <= 0x7E) or
        (char >= 0xA1 and char <= 0xFF)
    end)
  end

  defp validate_tags(changeset) do
    validate_change(changeset, :tags, fn :tags, value ->
      if is_map(value) do
        tags = Maxio.Tags.map_to_list(value)

        cond do
          case_insensitive_duplicate_keys?(tags) ->
            [tags: "must not contain duplicate IAM tag keys"]

          Maxio.Tags.validate(tags, :bucket) == :ok ->
            []

          true ->
            [tags: "must contain valid IAM tag keys and values"]
        end
      else
        [tags: "must be a map"]
      end
    end)
  end

  defp case_insensitive_duplicate_keys?(tags) do
    keys = Enum.map(tags, fn {key, _value} -> String.downcase(key) end)
    length(Enum.uniq(keys)) != length(keys)
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
