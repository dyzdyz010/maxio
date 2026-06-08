defmodule Maxio.Objects.Object do
  @moduledoc "S3 对象元数据 schema（字节由存储后端持有，本表只存元信息）。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "objects" do
    field :bucket_name, :string
    field :key, :string
    field :size, :integer, default: 0
    field :etag, :string
    field :content_type, :string, default: "binary/octet-stream"
    field :metadata, :map, default: %{}
    field :storage_class, :string, default: "STANDARD"

    belongs_to :bucket, Maxio.Buckets.Bucket

    timestamps(type: :utc_datetime_usec)
  end

  @required [:bucket_id, :bucket_name, :key, :size, :etag]
  @optional [:content_type, :metadata, :storage_class]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(object, attrs) do
    object
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:bucket_id, :key], name: :objects_bucket_id_key_index)
  end
end
