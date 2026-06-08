defmodule Maxio.Policy.BucketPolicy do
  @moduledoc "S3 桶策略 schema：每桶至多一条，document 为解析校验后的策略 JSON（jsonb map）。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "bucket_policies" do
    field :bucket_name, :string
    field :document, :map

    timestamps(type: :utc_datetime_usec)
  end

  @required [:bucket_name, :document]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(bp, attrs) do
    bp
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> unique_constraint(:bucket_name, name: :bucket_policies_bucket_name_index)
  end
end
