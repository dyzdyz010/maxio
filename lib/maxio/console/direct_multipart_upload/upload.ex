defmodule Maxio.Console.DirectMultipartUpload.Upload do
  @moduledoc """
  Console browser-direct multipart upload registry row.

  This table is not object-byte authority. It records enough Console metadata to
  recover an S3 multipart upload after a browser refresh; the authoritative
  upload state remains `multipart_uploads` and `multipart_parts`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "console_direct_multipart_uploads" do
    belongs_to :multipart_upload, Maxio.Multipart.Upload

    field :bucket_name, :string
    field :key, :string
    field :upload_id, :string
    field :principal_arn, :string
    field :access_key, :string
    field :file_name, :string
    field :file_size, :integer
    field :file_last_modified, :integer
    field :part_size, :integer
    field :request_payer, :boolean, default: false
    field :status, :string, default: "active"

    field :part_count, :integer, virtual: true, default: 0
    field :uploaded_size, :integer, virtual: true, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @required [
    :multipart_upload_id,
    :bucket_name,
    :key,
    :upload_id,
    :principal_arn,
    :access_key,
    :file_name,
    :file_size,
    :file_last_modified,
    :part_size
  ]

  @optional [:request_payer, :status]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(upload, attrs) do
    upload
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:file_size, greater_than: 0)
    |> validate_number(:file_last_modified, greater_than_or_equal_to: 0)
    |> validate_number(:part_size, greater_than: 0)
    |> validate_inclusion(:status, ["active"])
    |> unique_constraint(:upload_id, name: :console_direct_multipart_uploads_upload_id_index)
    |> unique_constraint(:multipart_upload_id,
      name: :console_direct_multipart_uploads_multipart_upload_id_index
    )
    |> foreign_key_constraint(:multipart_upload_id)
  end
end
