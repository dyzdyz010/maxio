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
    field :content_encoding, :string
    field :content_disposition, :string
    field :cache_control, :string
    field :expires, :string
    field :website_redirect_location, :string
    field :storage_class, :string, default: "STANDARD"
    field :acl_canned, :string, default: "private"
    field :acl_grants, :map, default: %{"grants" => []}
    field :sse_algorithm, :string

    # SSE 信封（包裹后的 DEK 材料）：redact 防止 struct/changeset 的 inspect 经日志 reason
    # 通道泄露密钥材料（与 Objects.Object 同源，B7 脱敏收口，B5 审查项 2）。
    field :sse_envelope, :map, redact: true
    field :owner, :string
    field :metadata, :map, default: %{}
    field :tags, :map, default: %{}
    field :placement_set_id, :integer
    field :placement_pool_id, :integer
    field :placement_topology_hash, :string
    field :checksum_algorithm, :string
    field :checksum_type, :string

    has_many :parts, Maxio.Multipart.Part, foreign_key: :upload_id, references: :id

    timestamps(type: :utc_datetime_usec)
  end

  @required [:upload_id, :bucket_name, :key, :owner]
  @optional [
    :content_type,
    :content_encoding,
    :content_disposition,
    :cache_control,
    :expires,
    :website_redirect_location,
    :storage_class,
    :acl_canned,
    :acl_grants,
    :sse_algorithm,
    :sse_envelope,
    :metadata,
    :tags,
    :placement_set_id,
    :placement_pool_id,
    :placement_topology_hash,
    :checksum_algorithm,
    :checksum_type
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(upload, attrs) do
    upload
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:upload_id, name: :multipart_uploads_upload_id_index)
  end
end
