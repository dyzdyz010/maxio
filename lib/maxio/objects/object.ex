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
    field :content_encoding, :string
    field :content_disposition, :string
    field :cache_control, :string
    field :expires, :string
    field :metadata, :map, default: %{}
    field :storage_class, :string, default: "STANDARD"
    field :acl_canned, :string, default: "private"
    field :acl_grants, :map, default: %{"grants" => []}
    field :version_id, :string, default: "null"
    field :is_latest, :boolean, default: true
    field :is_delete_marker, :boolean, default: false
    field :tags, :map, default: %{}
    field :sse_algorithm, :string
    field :sse_envelope, :map
    field :placement_set_id, :integer
    field :placement_pool_id, :integer
    field :placement_topology_hash, :string

    # ROUTE B B5-1 —— PG 派生索引同步追踪：synced_at = 最后一次与盘上 sidecar 权威确认同步的时刻
    # （NULL=尚未经 scanner 确认）；index_generation = 同步时对应的 sidecar 版本 generation（判 stale 用）。
    field :synced_at, :utc_datetime_usec
    field :index_generation, :integer, default: 0

    belongs_to :bucket, Maxio.Buckets.Bucket

    timestamps(type: :utc_datetime_usec)
  end

  @castable [
    :bucket_id,
    :bucket_name,
    :key,
    :size,
    :etag,
    :content_type,
    :content_encoding,
    :content_disposition,
    :cache_control,
    :expires,
    :metadata,
    :storage_class,
    :acl_canned,
    :acl_grants,
    :version_id,
    :is_latest,
    :is_delete_marker,
    :tags,
    :sse_algorithm,
    :sse_envelope,
    :placement_set_id,
    :placement_pool_id,
    :placement_topology_hash,
    :synced_at,
    :index_generation
  ]
  # etag 仅对真实对象版本必填；delete marker 无字节、无 etag（空串），故 etag 从必填中排除。
  @required [:bucket_id, :bucket_name, :key, :size]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(object, attrs) do
    object
    |> cast(attrs, @castable)
    |> validate_required(@required)
    |> validate_etag_required()
    |> unique_constraint([:bucket_id, :key, :version_id],
      name: :objects_bucket_id_key_version_id_index
    )
  end

  # 非 delete marker 必须有非空 etag；delete marker 无字节、无 etag——因 DB 列 NOT NULL，
  # 且 Ecto cast 把空串归一化为 nil，故 delete marker 显式回填空串（绝不写 NULL）。
  defp validate_etag_required(changeset) do
    if get_field(changeset, :is_delete_marker) do
      case get_field(changeset, :etag) do
        nil -> put_change(changeset, :etag, "")
        _ -> changeset
      end
    else
      validate_required(changeset, [:etag])
    end
  end
end
