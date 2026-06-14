defmodule Maxio.Cluster.TopologyRevision do
  @moduledoc "Persistent deployment topology revision."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "cluster_topology_revisions" do
    field :status, :string, default: "active"
    field :topology_hash, :string
    field :config, :map
    field :source, :string, default: "operator"
    field :source_job_id, :binary_id
    field :activated_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @statuses ~w(active superseded)
  @sources ~w(operator decommission_removal)

  @required [
    :status,
    :topology_hash,
    :config,
    :source,
    :activated_at
  ]

  @optional [
    :source_job_id
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(revision, attrs) do
    revision
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:topology_hash, is: 64)
    |> unique_constraint(:status, name: :cluster_topology_revisions_active_index)
  end
end
