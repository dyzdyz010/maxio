defmodule Maxio.IAM.SigningCertificate do
  @moduledoc "Persisted IAM user/root signing certificate metadata and PEM validation."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "iam_signing_certificates" do
    field :certificate_id, :string
    field :principal_type, :string
    field :user_arn, :string
    field :certificate_body, :string
    field :certificate_fingerprint_sha256, :string
    field :status, :string, default: "Active"
    field :expiration, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_upload [
    :certificate_id,
    :principal_type,
    :certificate_body,
    :certificate_fingerprint_sha256,
    :status
  ]
  @upload_fields @required_upload ++ [:user_arn, :expiration]
  @status_fields [:status]
  @certificate_id_pattern ~r/\ATA[A-Za-z0-9_]{22,126}\z/
  @principal_types ~w(root iam_user)
  @statuses ~w(Active Inactive Expired)
  @certificate_body_max_chars 16_384

  @spec upload_changeset(t(), map()) :: Ecto.Changeset.t()
  def upload_changeset(signing_certificate, attrs) do
    signing_certificate
    |> cast(attrs, @upload_fields)
    |> trim_change(:certificate_id)
    |> trim_change(:principal_type)
    |> trim_change(:user_arn)
    |> normalize_certificate_body()
    |> put_certificate_validation()
    |> validate_required(@required_upload)
    |> validate_common()
  end

  @spec status_changeset(t(), map()) :: Ecto.Changeset.t()
  def status_changeset(signing_certificate, attrs) do
    signing_certificate
    |> cast(attrs, @status_fields)
    |> validate_required(@status_fields)
    |> validate_inclusion(:status, @statuses)
  end

  defp validate_common(changeset) do
    changeset
    |> validate_length(:certificate_id, min: 24, max: 128)
    |> validate_format(:certificate_id, @certificate_id_pattern)
    |> validate_inclusion(:principal_type, @principal_types)
    |> validate_length(:user_arn, max: 512)
    |> validate_length(:certificate_body, min: 1, max: @certificate_body_max_chars)
    |> validate_certificate_body_chars()
    |> validate_length(:certificate_fingerprint_sha256, is: 64)
    |> validate_inclusion(:status, @statuses)
    |> validate_principal_shape()
    |> unique_constraint(:certificate_id, name: :iam_signing_certificates_certificate_id_index)
    |> unique_constraint(:certificate_fingerprint_sha256,
      name: :iam_signing_certificates_fingerprint_sha256_index
    )
  end

  defp put_certificate_validation(changeset) do
    case decode_leaf_certificate(get_change(changeset, :certificate_body)) do
      {:ok, cert} ->
        changeset
        |> put_change(:certificate_fingerprint_sha256, certificate_fingerprint(cert.der))
        |> put_change(:expiration, cert.expiration)

      {:error, _reason} ->
        add_error(changeset, :certificate_body, "must be a valid, unexpired PEM certificate",
          validation: :malformed_certificate
        )
    end
  end

  defp decode_leaf_certificate(body) when is_binary(body) do
    with true <- certificate_body_chars?(body),
         [{:Certificate, der, :not_encrypted}] <- :public_key.pem_decode(body),
         {:Certificate,
          {:TBSCertificate, _, _, _, _, {:Validity, _not_before, not_after}, _, _spki, _, _, _},
          _, _} <- :public_key.pem_entry_decode({:Certificate, der, :not_encrypted}),
         {:ok, expiration} <- validity_time(not_after),
         :gt <- DateTime.compare(expiration, DateTime.utc_now()) do
      {:ok, %{der: der, expiration: expiration}}
    else
      _other -> {:error, :malformed_certificate}
    end
  rescue
    _error -> {:error, :malformed_certificate}
  end

  defp decode_leaf_certificate(_body), do: {:error, :malformed_certificate}

  defp certificate_fingerprint(der), do: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)

  defp validity_time({:utcTime, value}), do: parse_utc_time(to_string(value))
  defp validity_time({:generalTime, value}), do: parse_general_time(to_string(value))
  defp validity_time(_value), do: {:error, :malformed_certificate}

  defp parse_utc_time(<<yy::binary-size(2), rest::binary-size(11)>>) do
    with {year, ""} <- Integer.parse(yy),
         {:ok, dt} <- parse_compact_time(rest, if(year >= 50, do: 1900 + year, else: 2000 + year)) do
      {:ok, dt}
    else
      _other -> {:error, :malformed_certificate}
    end
  end

  defp parse_utc_time(_value), do: {:error, :malformed_certificate}

  defp parse_general_time(<<yyyy::binary-size(4), rest::binary-size(11)>>) do
    with {year, ""} <- Integer.parse(yyyy),
         {:ok, dt} <- parse_compact_time(rest, year) do
      {:ok, dt}
    else
      _other -> {:error, :malformed_certificate}
    end
  end

  defp parse_general_time(_value), do: {:error, :malformed_certificate}

  defp parse_compact_time(
         <<mm::binary-size(2), dd::binary-size(2), hh::binary-size(2), mi::binary-size(2),
           ss::binary-size(2), "Z">>,
         year
       ) do
    with {month, ""} <- Integer.parse(mm),
         {day, ""} <- Integer.parse(dd),
         {hour, ""} <- Integer.parse(hh),
         {minute, ""} <- Integer.parse(mi),
         {second, ""} <- Integer.parse(ss),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, dt} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, %{dt | microsecond: {0, 6}}}
    else
      _other -> {:error, :malformed_certificate}
    end
  end

  defp parse_compact_time(_value, _year), do: {:error, :malformed_certificate}

  defp validate_certificate_body_chars(changeset) do
    validate_change(changeset, :certificate_body, fn field, value ->
      if certificate_body_chars?(value) do
        []
      else
        [{field, {"contains invalid characters", [validation: :malformed_certificate]}}]
      end
    end)
  end

  defp certificate_body_chars?(body) when is_binary(body) do
    body
    |> String.to_charlist()
    |> Enum.all?(fn
      char when char in [?\t, ?\n, ?\r] -> true
      char when char >= 0x20 and char <= 0xFF -> true
      _char -> false
    end)
  rescue
    _error -> false
  end

  defp certificate_body_chars?(_body), do: false

  defp validate_principal_shape(changeset) do
    validate_change(changeset, :principal_type, fn :principal_type, type ->
      user_arn = get_field(changeset, :user_arn)

      cond do
        type == "root" and is_nil(user_arn) ->
          []

        type == "iam_user" and is_binary(user_arn) and user_arn != "" ->
          []

        true ->
          [principal_type: "does not match user_arn"]
      end
    end)
  end

  defp trim_change(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.trim(value)
      value -> value
    end)
  end

  defp normalize_certificate_body(changeset) do
    update_change(changeset, :certificate_body, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value <> "\n"

      value ->
        value
    end)
  end
end
