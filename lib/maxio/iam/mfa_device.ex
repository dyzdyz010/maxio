defmodule Maxio.IAM.MFADevice do
  @moduledoc "Local MFA device registration for S3 MFA Delete and STS MFA context."
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Inspect, except: [:secret_envelope]}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending active disabled)
  @principal_types ~w(root iam_user)
  @kinds ~w(totp)
  @algorithms ~w(sha1)
  @fields [
    :principal_arn,
    :principal_type,
    :serial,
    :device_name,
    :kind,
    :status,
    :secret_envelope,
    :algorithm,
    :digits,
    :period_seconds,
    :drift_steps,
    :last_accepted_step,
    :confirmed_at,
    :last_used_at,
    :disabled_at
  ]

  @type t :: %__MODULE__{}

  schema "mfa_devices" do
    field :principal_arn, :string
    field :principal_type, :string, default: "root"
    field :serial, :string
    field :device_name, :string
    field :kind, :string, default: "totp"
    field :status, :string, default: "pending"
    field :secret_envelope, :map
    field :algorithm, :string, default: "sha1"
    field :digits, :integer, default: 6
    field :period_seconds, :integer, default: 30
    field :drift_steps, :integer, default: 1
    field :last_accepted_step, :integer
    field :confirmed_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(device, attrs) do
    device
    |> cast(attrs, @fields)
    |> trim_change(:principal_arn)
    |> trim_change(:serial)
    |> trim_change(:device_name)
    |> validate_required([
      :principal_arn,
      :principal_type,
      :serial,
      :device_name,
      :kind,
      :status,
      :secret_envelope,
      :algorithm,
      :digits,
      :period_seconds,
      :drift_steps
    ])
    |> validate_inclusion(:principal_type, @principal_types)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:algorithm, @algorithms)
    |> validate_format(:principal_arn, ~r/^\S+$/)
    |> validate_format(:serial, ~r/^\S+$/)
    |> validate_format(:device_name, ~r/^\S+$/)
    |> validate_number(:digits, equal_to: 6)
    |> validate_number(:period_seconds, equal_to: 30)
    |> validate_number(:drift_steps, greater_than_or_equal_to: 0, less_than_or_equal_to: 2)
    |> validate_length(:principal_arn, max: 512)
    |> validate_length(:serial, max: 512)
    |> validate_length(:device_name, max: 128)
    |> unique_constraint(:serial, name: :mfa_devices_serial_index)
    |> unique_constraint(:device_name, name: :mfa_devices_principal_device_name_index)
  end

  defp trim_change(changeset, field) do
    update_change(changeset, field, &String.trim/1)
  end
end
