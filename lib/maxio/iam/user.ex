defmodule Maxio.IAM.User do
  @moduledoc "Persisted local IAM user metadata."
  use Ecto.Schema
  import Ecto.Changeset

  alias Maxio.IAM.MinioAccessKey

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "iam_users" do
    field :user_name, :string
    field :user_arn, :string
    field :status, :string, default: "active"
    field :tags, :map, default: %{}
    field :permissions_boundary_policy_arn, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required [:user_name, :user_arn]
  @optional [:status, :tags, :permissions_boundary_policy_arn]
  @name_pattern ~r/\A[A-Za-z0-9+=,.@_-]+\z/
  @user_arn_pattern ~r/\Aarn:aws:iam:::user\/[A-Za-z0-9+=,.@_-]+\z/
  @managed_policy_arn_pattern ~r|\Aarn:aws:iam:::policy/[A-Za-z0-9+=,.@_/-]+\z|

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, @required ++ @optional)
    |> trim_change(:user_name)
    |> trim_change(:user_arn)
    |> validate_required(@required)
    |> validate_length(:user_name, min: 1, max: 64)
    |> validate_format(:user_name, @name_pattern)
    |> validate_length(:user_arn, min: 1, max: 512)
    |> validate_format(:user_arn, @user_arn_pattern)
    |> validate_length(:permissions_boundary_policy_arn, max: 2048)
    |> validate_format(:permissions_boundary_policy_arn, @managed_policy_arn_pattern)
    |> validate_arn_matches_name(:user_arn, :user_name, "user")
    |> validate_inclusion(:status, ["active", "inactive"])
    |> validate_tags()
    |> unique_constraint(:user_name, name: :iam_users_user_name_index)
    |> unique_constraint(:user_name, name: :iam_users_user_name_ci_index)
    |> unique_constraint(:user_arn, name: :iam_users_user_arn_index)
  end

  @doc false
  @spec minio_admin_changeset(t(), map()) :: Ecto.Changeset.t()
  def minio_admin_changeset(user, attrs) do
    user
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_minio_access_key()
    |> validate_length(:user_arn, min: 1, max: 512)
    |> validate_length(:permissions_boundary_policy_arn, max: 2048)
    |> validate_format(:permissions_boundary_policy_arn, @managed_policy_arn_pattern)
    |> validate_arn_matches_name(:user_arn, :user_name, "user")
    |> validate_inclusion(:status, ["active", "inactive"])
    |> validate_tags()
    |> unique_constraint(:user_name, name: :iam_users_user_name_index)
    |> unique_constraint(:user_name, name: :iam_users_user_name_ci_index)
    |> unique_constraint(:user_arn, name: :iam_users_user_arn_index)
  end

  defp validate_minio_access_key(changeset) do
    validate_change(changeset, :user_name, fn :user_name, value ->
      case MinioAccessKey.validate(value) do
        :ok -> []
        {:error, :invalid_access_key} -> [user_name: "must be a valid MinIO access key"]
      end
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

  defp trim_change(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.trim(value)
      value -> value
    end)
  end
end
