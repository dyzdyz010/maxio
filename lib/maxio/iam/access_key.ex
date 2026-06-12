defmodule Maxio.IAM.AccessKey do
  @moduledoc "S3 访问密钥（SigV4 凭据）schema。secret 明文存储（MVP；at-rest 加密见计划 defer）。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "access_keys" do
    field :access_key_id, :string
    field :secret_key, :string
    field :principal_arn, :string
    field :type, :string, default: "iam_user"
    field :status, :string, default: "active"
    field :tags, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required [:access_key_id, :secret_key, :principal_arn]
  @optional [:type, :status, :tags]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(ak, attrs) do
    ak
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:type, ["root", "iam_user"])
    |> validate_inclusion(:status, ["active", "inactive"])
    |> unique_constraint(:access_key_id, name: :access_keys_access_key_id_index)
  end
end
