defmodule Maxio.IAM.AccountAlias do
  @moduledoc "Persisted local IAM account alias metadata."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "iam_account_aliases" do
    field :account_alias, :string
    field :singleton_key, :integer, default: 1

    timestamps(type: :utc_datetime_usec)
  end

  @required [:account_alias]
  @optional [:singleton_key]
  @alias_pattern ~r/\A[a-z0-9](?:[a-z0-9]|-(?!-)){1,61}[a-z0-9]\z/

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(account_alias, attrs) do
    account_alias
    |> cast(attrs, @required ++ @optional)
    |> put_change(:singleton_key, 1)
    |> validate_required(@required)
    |> validate_length(:account_alias, min: 3, max: 63)
    |> validate_format(:account_alias, @alias_pattern)
    |> validate_number(:singleton_key, equal_to: 1)
    |> unique_constraint(:account_alias, name: :iam_account_aliases_account_alias_index)
    |> unique_constraint(:singleton_key, name: :iam_account_aliases_singleton_key_index)
  end
end
