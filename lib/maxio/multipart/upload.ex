defmodule Maxio.Multipart.Upload do
  @moduledoc "分段上传会话 schema（part 字节归存储后端，本表只存会话元信息）。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "multipart_uploads" do
    field :upload_id, :string
    field :bucket_name, :string
    field :key, :string
    field :content_type, :string, default: "binary/octet-stream"
    field :storage_class, :string, default: "STANDARD"
    field :owner, :string
    field :metadata, :map, default: %{}

    has_many :parts, Maxio.Multipart.Part, foreign_key: :upload_id, references: :id

    timestamps(type: :utc_datetime_usec)
  end

  @required [:upload_id, :bucket_name, :key, :owner]
  @optional [:content_type, :storage_class, :metadata]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(upload, attrs) do
    upload
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:upload_id, name: :multipart_uploads_upload_id_index)
  end
end
