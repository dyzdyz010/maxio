defmodule Maxio.IAM.STSSession do
  @moduledoc """
  Persisted STS temporary credential metadata.

  The plaintext session token is returned only at issuance time and is never
  stored. `session_token_sha256` is intentionally excluded from Inspect output.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @derive {Inspect, except: [:secret_key, :session_token_sha256]}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sts_sessions" do
    field :access_key_id, :string
    field :secret_key, :string
    field :session_token_sha256, :string
    field :issuer_access_key_id, :string
    field :principal_arn, :string
    field :principal_type, :string
    field :session_name, :string
    field :status, :string, default: "active"
    field :issued_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :tags, :map, default: %{}
    field :transitive_tag_keys, {:array, :string}, default: []
    field :session_policy, :map
    field :source_identity, :string
    field :mfa_authenticated, :boolean, default: false
    field :mfa_serial_hash, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required [
    :access_key_id,
    :secret_key,
    :session_token_sha256,
    :issuer_access_key_id,
    :principal_arn,
    :principal_type,
    :session_name,
    :issued_at,
    :expires_at
  ]
  @optional [
    :status,
    :revoked_at,
    :tags,
    :transitive_tag_keys,
    :session_policy,
    :source_identity,
    :mfa_authenticated,
    :mfa_serial_hash
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:access_key_id, min: 4)
    |> validate_length(:source_identity, min: 2, max: 64)
    |> validate_format(:source_identity, ~r/\A(?!aws:)[A-Za-z0-9+=,.@_-]+\z/i)
    |> validate_inclusion(:principal_type, ["root", "iam_user", "assumed_role"])
    |> validate_inclusion(:status, ["active", "revoked"])
    |> unique_constraint(:access_key_id, name: :sts_sessions_access_key_id_index)
  end
end
