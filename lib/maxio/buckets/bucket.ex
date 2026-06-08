defmodule Maxio.Buckets.Bucket do
  @moduledoc "S3 桶元数据 schema（对象字节不在此，归存储后端）。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "buckets" do
    field :name, :string
    field :region, :string, default: "us-east-1"
    field :owner, :string
    field :acl_canned, :string, default: "private"
    field :versioning, :string, default: "Unversioned"
    field :mfa_delete, :string
    field :tags, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required [:name, :owner]
  @optional [:region, :acl_canned, :versioning, :mfa_delete, :tags]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(bucket, attrs) do
    bucket
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:name, name: :buckets_name_index)
  end
end
