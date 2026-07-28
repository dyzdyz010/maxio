defmodule Maxio.Console.DirectMultipartUpload.History do
  @moduledoc """
  Terminal history row for a Console browser-direct multipart upload.

  This table is an audit/display snapshot only. It intentionally does not store
  presigned URLs, signatures, SSE-C customer keys, key MD5 values, header maps,
  or object bytes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "console_direct_multipart_upload_histories" do
    field :upload_id, :string
    field :terminal_state, :string
    field :bucket_name, :string
    field :key, :string
    field :principal_arn, :string
    field :access_key, :string
    field :file_name, :string
    field :file_size, :integer
    field :file_last_modified, :integer
    field :part_size, :integer
    field :part_count, :integer, default: 0
    field :uploaded_size, :integer, default: 0
    field :etag, :string
    field :version_id, :string
    field :content_type, :string
    field :storage_class, :string
    field :request_payer, :boolean, default: false
    field :sse_algorithm, :string
    field :sse_customer_key_required, :boolean, default: false
    field :terminal_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required [
    :upload_id,
    :terminal_state,
    :bucket_name,
    :key,
    :principal_arn,
    :access_key,
    :file_name,
    :file_size,
    :file_last_modified,
    :part_size,
    :terminal_at
  ]

  @optional [
    :part_count,
    :uploaded_size,
    :etag,
    :version_id,
    :content_type,
    :storage_class,
    :request_payer,
    :sse_algorithm,
    :sse_customer_key_required
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(history, attrs) do
    history
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:terminal_state, ["completed", "aborted"])
    |> validate_number(:file_size, greater_than: 0)
    |> validate_number(:file_last_modified, greater_than_or_equal_to: 0)
    |> validate_number(:part_size, greater_than: 0)
    |> validate_number(:part_count, greater_than_or_equal_to: 0)
    |> validate_number(:uploaded_size, greater_than_or_equal_to: 0)
    |> unique_constraint(:upload_id,
      name: :console_direct_multipart_upload_histories_upload_id_index
    )
  end
end
