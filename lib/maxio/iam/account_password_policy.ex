defmodule Maxio.IAM.AccountPasswordPolicy do
  @moduledoc "Persisted local IAM account password policy metadata."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "iam_account_password_policies" do
    field :singleton_key, :integer, default: 1
    field :minimum_password_length, :integer, default: 6
    field :require_symbols, :boolean, default: false
    field :require_numbers, :boolean, default: false
    field :require_uppercase_characters, :boolean, default: false
    field :require_lowercase_characters, :boolean, default: false
    field :allow_users_to_change_password, :boolean, default: false
    field :hard_expiry, :boolean, default: false
    field :max_password_age, :integer
    field :password_reuse_prevention, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :minimum_password_length,
    :require_symbols,
    :require_numbers,
    :require_uppercase_characters,
    :require_lowercase_characters,
    :allow_users_to_change_password,
    :hard_expiry,
    :max_password_age,
    :password_reuse_prevention
  ]

  @required [
    :minimum_password_length,
    :require_symbols,
    :require_numbers,
    :require_uppercase_characters,
    :require_lowercase_characters,
    :allow_users_to_change_password,
    :hard_expiry
  ]

  @spec defaults() :: map()
  def defaults do
    %{
      minimum_password_length: 6,
      require_symbols: false,
      require_numbers: false,
      require_uppercase_characters: false,
      require_lowercase_characters: false,
      allow_users_to_change_password: false,
      hard_expiry: false,
      max_password_age: nil,
      password_reuse_prevention: nil
    }
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:singleton_key | @fields])
    |> put_change(:singleton_key, 1)
    |> validate_required(@required)
    |> validate_number(:singleton_key, equal_to: 1)
    |> validate_number(:minimum_password_length,
      greater_than_or_equal_to: 6,
      less_than_or_equal_to: 128
    )
    |> validate_optional_number(:max_password_age, 1, 1095)
    |> validate_optional_number(:password_reuse_prevention, 1, 24)
    |> unique_constraint(:singleton_key, name: :iam_account_password_policies_singleton_key_index)
    |> check_constraint(:singleton_key,
      name: :iam_account_password_policies_singleton_key_is_one
    )
    |> check_constraint(:minimum_password_length,
      name: :iam_account_password_policies_minimum_password_length_range
    )
    |> check_constraint(:max_password_age,
      name: :iam_account_password_policies_max_password_age_range
    )
    |> check_constraint(:password_reuse_prevention,
      name: :iam_account_password_policies_reuse_prevention_range
    )
  end

  defp validate_optional_number(changeset, field, min, max) do
    value = get_field(changeset, field)

    if is_nil(value) do
      changeset
    else
      validate_number(changeset, field, greater_than_or_equal_to: min, less_than_or_equal_to: max)
    end
  end
end
