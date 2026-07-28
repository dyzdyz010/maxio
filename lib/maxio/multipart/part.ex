defmodule Maxio.Multipart.Part do
  @moduledoc "分段上传分块元数据 schema（分块字节归存储后端，本表只存元信息）。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "multipart_parts" do
    field :part_number, :integer
    field :etag, :string
    field :size, :integer, default: 0
    field :checksum, :map, default: %{}

    belongs_to :upload, Maxio.Multipart.Upload, foreign_key: :upload_id, references: :id

    timestamps(type: :utc_datetime_usec)
  end

  @required [:upload_id, :part_number, :etag, :size]
  @optional [:checksum]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(part, attrs) do
    part
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:part_number, 1..10_000)
    |> unique_constraint([:upload_id, :part_number],
      name: :multipart_parts_upload_id_part_number_index
    )
  end
end
