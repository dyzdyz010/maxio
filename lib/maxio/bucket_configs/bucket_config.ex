defmodule Maxio.BucketConfigs.BucketConfig do
  @moduledoc "桶高级特性配置 schema（每桶一行：cors/lifecycle/encryption/quota 等各一 jsonb）。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "bucket_configs" do
    field :bucket_name, :string
    field :cors, {:array, :map}
    field :lifecycle, {:array, :map}
    field :encryption, :map
    field :public_access_block, :map
    field :ownership_controls, :map
    field :website, :map
    field :request_payment, :map
    field :accelerate, :map
    field :logging, :map
    field :notification, :map
    field :metrics, :map
    field :analytics, :map
    field :inventory, :map
    field :replication, :map
    field :object_lock, :map
    field :quota, :map

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :bucket_name,
    :cors,
    :lifecycle,
    :encryption,
    :public_access_block,
    :ownership_controls,
    :website,
    :request_payment,
    :accelerate,
    :logging,
    :notification,
    :metrics,
    :analytics,
    :inventory,
    :replication,
    :object_lock,
    :quota
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(cfg, attrs) do
    cfg
    |> cast(attrs, @fields)
    |> validate_required([:bucket_name])
    |> unique_constraint(:bucket_name, name: :bucket_configs_bucket_name_index)
  end
end
