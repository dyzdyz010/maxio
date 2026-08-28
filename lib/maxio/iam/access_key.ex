defmodule Maxio.IAM.AccessKey do
  @moduledoc "S3 访问密钥（SigV4 凭据）schema。secret_key 存储本地 AES-GCM envelope，旧明文行仅读兼容。"
  use Ecto.Schema
  import Ecto.Changeset

  alias Maxio.IAM.MinioAccessKey

  @type t :: %__MODULE__{}

  @derive {Inspect, except: [:secret_key]}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "access_keys" do
    field :access_key_id, :string
    field :secret_key, :string
    field :principal_arn, :string
    field :type, :string, default: "iam_user"
    field :status, :string, default: "active"
    field :tags, :map, default: %{}
    field :last_used_at, :utc_datetime_usec
    field :last_used_service, :string
    field :last_used_region, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required [:access_key_id, :secret_key, :principal_arn]
  @optional [:type, :status, :tags, :last_used_at, :last_used_service, :last_used_region]
  @user_arn_pattern ~r/\Aarn:aws:iam:::user\/[A-Za-z0-9+=,.@_-]+\z/

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(ak, attrs) do
    ak
    |> base_changeset(attrs)
    |> validate_principal_arn()
  end

  @doc false
  @spec minio_admin_changeset(t(), map()) :: Ecto.Changeset.t()
  def minio_admin_changeset(ak, attrs) do
    ak
    |> base_changeset(attrs)
    |> validate_minio_admin_principal_arn()
  end

  defp base_changeset(ak, attrs) do
    ak
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:type, ["root", "iam_user"])
    |> validate_inclusion(:status, ["active", "inactive", "expired"])
    |> unique_constraint(:access_key_id, name: :access_keys_access_key_id_index)
  end

  defp validate_principal_arn(changeset) do
    type = get_field(changeset, :type)
    principal_arn = get_field(changeset, :principal_arn)

    cond do
      type == "root" and principal_arn == "arn:aws:iam:::root" ->
        changeset

      type == "iam_user" and user_arn?(principal_arn) ->
        changeset

      true ->
        add_error(changeset, :principal_arn, "must match the access key principal type")
    end
  end

  defp user_arn?(principal_arn) when is_binary(principal_arn),
    do: Regex.match?(@user_arn_pattern, principal_arn)

  defp user_arn?(_principal_arn), do: false

  defp validate_minio_admin_principal_arn(changeset) do
    access_key_id = get_field(changeset, :access_key_id)
    principal_arn = get_field(changeset, :principal_arn)
    expected_arn = if is_binary(access_key_id), do: "arn:aws:iam:::user/#{access_key_id}"

    if get_field(changeset, :type) == "iam_user" and principal_arn == expected_arn and
         MinioAccessKey.validate(access_key_id) == :ok do
      changeset
    else
      add_error(changeset, :principal_arn, "must match the MinIO access key principal")
    end
  end
end
