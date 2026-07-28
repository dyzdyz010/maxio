defmodule Maxio.IAM.InstanceProfile do
  @moduledoc "Persisted local IAM instance profile metadata."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "iam_instance_profiles" do
    field :instance_profile_name, :string
    field :instance_profile_arn, :string
    field :path, :string, default: "/"
    field :role_arn, :string
    field :tags, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required [:instance_profile_name, :instance_profile_arn, :path]
  @optional [:role_arn, :tags]
  @name_pattern ~r/\A[A-Za-z0-9+=,.@_-]+\z/
  @path_pattern ~r{\A(?:/|/[!-~]+/)\z}
  @instance_profile_arn_pattern ~r|\Aarn:aws:iam:::instance-profile/(?:[!-~]+/)?[A-Za-z0-9+=,.@_-]+\z|
  @role_arn_pattern ~r/\Aarn:aws:iam:::role\/[A-Za-z0-9+=,.@_-]+\z/

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(instance_profile, attrs) do
    instance_profile
    |> cast(attrs, @required ++ @optional)
    |> trim_change(:instance_profile_name)
    |> trim_change(:instance_profile_arn)
    |> trim_change(:path)
    |> trim_change(:role_arn)
    |> validate_required(@required)
    |> validate_length(:instance_profile_name, min: 1, max: 128)
    |> validate_format(:instance_profile_name, @name_pattern)
    |> validate_length(:path, min: 1, max: 512)
    |> validate_format(:path, @path_pattern)
    |> validate_length(:instance_profile_arn, min: 1, max: 512)
    |> validate_format(:instance_profile_arn, @instance_profile_arn_pattern)
    |> validate_length(:role_arn, max: 512)
    |> validate_format(:role_arn, @role_arn_pattern)
    |> validate_arn_matches_name()
    |> validate_tags()
    |> unique_constraint(:instance_profile_name, name: :iam_instance_profiles_name_index)
    |> unique_constraint(:instance_profile_name, name: :iam_instance_profiles_name_ci_index)
    |> unique_constraint(:instance_profile_arn, name: :iam_instance_profiles_arn_index)
    |> foreign_key_constraint(:role_arn, name: :iam_instance_profiles_role_arn_fkey)
  end

  defp validate_arn_matches_name(changeset) do
    validate_change(changeset, :instance_profile_arn, fn field, value ->
      name = get_field(changeset, :instance_profile_name)
      path = get_field(changeset, :path)

      expected =
        if is_binary(name) and name != "" and is_binary(path) do
          "arn:aws:iam:::instance-profile/#{instance_profile_resource(path, name)}"
        end

      if value == expected do
        []
      else
        [{field, "must match instance profile name"}]
      end
    end)
  end

  defp validate_tags(changeset) do
    validate_change(changeset, :tags, fn :tags, value ->
      if is_map(value) do
        tags = Maxio.Tags.map_to_list(value)

        if Maxio.Tags.validate(tags, :bucket) == :ok do
          []
        else
          [tags: "must contain valid IAM tag keys and values"]
        end
      else
        [tags: "must be a map"]
      end
    end)
  end

  defp instance_profile_resource("/", name), do: name

  defp instance_profile_resource("/" <> path_body, name), do: path_body <> name

  defp trim_change(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.trim(value)
      value -> value
    end)
  end
end
