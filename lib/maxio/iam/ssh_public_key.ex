defmodule Maxio.IAM.SSHPublicKey do
  @moduledoc "Persisted IAM user SSH public key metadata and RSA public key validation."
  use Ecto.Schema
  import Bitwise
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "iam_ssh_public_keys" do
    field :ssh_public_key_id, :string
    field :user_arn, :string
    field :ssh_public_key_body, :string
    field :ssh_public_key_body_ssh, :string
    field :ssh_public_key_body_pem, :string
    field :fingerprint_md5, :string
    field :status, :string, default: "Active"

    timestamps(type: :utc_datetime_usec)
  end

  @required_upload [
    :ssh_public_key_id,
    :user_arn,
    :ssh_public_key_body,
    :ssh_public_key_body_ssh,
    :ssh_public_key_body_pem,
    :fingerprint_md5,
    :status
  ]
  @upload_fields @required_upload
  @status_fields [:status]
  @key_id_pattern ~r/\AAPKA[A-Z2-7]{16}\z/
  @user_arn_pattern ~r/\Aarn:aws:iam:::user\/[A-Za-z0-9+=,.@_-]{1,64}\z/
  @fingerprint_pattern ~r/\A[0-9a-f]{2}(?::[0-9a-f]{2}){15}\z/
  @statuses ~w(Active Inactive)
  @body_max_chars 16_384
  @min_rsa_bits 2_048

  @spec upload_changeset(t(), map()) :: Ecto.Changeset.t()
  def upload_changeset(ssh_public_key, attrs) do
    ssh_public_key
    |> cast(attrs, @upload_fields)
    |> trim_change(:ssh_public_key_id)
    |> trim_change(:user_arn)
    |> normalize_public_key_body()
    |> put_public_key_validation()
    |> validate_required(@required_upload)
    |> validate_common()
  end

  @spec status_changeset(t(), map()) :: Ecto.Changeset.t()
  def status_changeset(ssh_public_key, attrs) do
    ssh_public_key
    |> cast(attrs, @status_fields)
    |> validate_required(@status_fields)
    |> validate_inclusion(:status, @statuses)
  end

  defp validate_common(changeset) do
    changeset
    |> validate_length(:ssh_public_key_id, is: 20)
    |> validate_format(:ssh_public_key_id, @key_id_pattern)
    |> validate_format(:user_arn, @user_arn_pattern)
    |> validate_length(:ssh_public_key_body, min: 1, max: @body_max_chars)
    |> validate_length(:ssh_public_key_body_ssh, min: 1, max: @body_max_chars)
    |> validate_length(:ssh_public_key_body_pem, min: 1, max: @body_max_chars)
    |> validate_format(:fingerprint_md5, @fingerprint_pattern)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:ssh_public_key_id, name: :iam_ssh_public_keys_key_id_index)
    |> unique_constraint(:fingerprint_md5, name: :iam_ssh_public_keys_user_fingerprint_index)
  end

  defp put_public_key_validation(changeset) do
    case parse_public_key(get_change(changeset, :ssh_public_key_body)) do
      {:ok, key} ->
        changeset
        |> put_change(:ssh_public_key_body, key.original_body)
        |> put_change(:ssh_public_key_body_ssh, key.ssh_body)
        |> put_change(:ssh_public_key_body_pem, key.pem_body)
        |> put_change(:fingerprint_md5, key.fingerprint_md5)

      {:error, _reason} ->
        add_error(changeset, :ssh_public_key_body, "must be a valid RSA SSH public key",
          validation: :invalid_public_key
        )
    end
  end

  defp parse_public_key(body) when is_binary(body) do
    body = String.trim(body)

    with true <- body != "",
         {:ok, key} <- parse_public_key_format(body),
         :ok <- validate_rsa_public_key(key.n, key.e) do
      blob = ssh_blob(key.n, key.e)
      ssh_body = "ssh-rsa " <> Base.encode64(blob)
      pem_body = rsa_public_key_pem(key.n, key.e)

      {:ok,
       %{
         original_body: body,
         ssh_body: ssh_body,
         pem_body: pem_body,
         fingerprint_md5: fingerprint_md5(blob)
       }}
    else
      _other -> {:error, :invalid_public_key}
    end
  rescue
    _error -> {:error, :invalid_public_key}
  end

  defp parse_public_key(_body), do: {:error, :invalid_public_key}

  defp parse_public_key_format(body) do
    case parse_ssh_public_key(body) do
      {:ok, key} -> {:ok, key}
      {:error, _reason} -> parse_pem_public_key(body)
    end
  end

  defp parse_ssh_public_key(body) do
    case String.split(body, ~r/\s+/, parts: 3) do
      ["ssh-rsa", blob_b64 | _comment] ->
        with {:ok, blob} <- Base.decode64(blob_b64),
             {:ok, "ssh-rsa", rest} <- take_ssh_string(blob),
             {:ok, e, rest} <- take_ssh_mpint(rest),
             {:ok, n, ""} <- take_ssh_mpint(rest) do
          {:ok, %{n: n, e: e}}
        else
          _other -> {:error, :invalid_public_key}
        end

      _other ->
        {:error, :invalid_public_key}
    end
  end

  defp parse_pem_public_key(body) do
    case :public_key.pem_decode(body) do
      [entry] ->
        case :public_key.pem_entry_decode(entry) do
          {:RSAPublicKey, n, e} -> {:ok, %{n: n, e: e}}
          {:SubjectPublicKeyInfo, _algorithm, {:RSAPublicKey, n, e}} -> {:ok, %{n: n, e: e}}
          {:SubjectPublicKeyInfo, _algorithm, key_der} -> decode_rsa_public_key_der(key_der)
          _other -> {:error, :invalid_public_key}
        end

      _other ->
        {:error, :invalid_public_key}
    end
  end

  defp decode_rsa_public_key_der(key_der) when is_binary(key_der) do
    case :public_key.der_decode(:RSAPublicKey, key_der) do
      {:RSAPublicKey, n, e} -> {:ok, %{n: n, e: e}}
      _other -> {:error, :invalid_public_key}
    end
  end

  defp take_ssh_string(<<len::32, rest::binary>>) when byte_size(rest) >= len do
    <<value::binary-size(^len), tail::binary>> = rest
    {:ok, value, tail}
  end

  defp take_ssh_string(_blob), do: {:error, :invalid_public_key}

  defp take_ssh_mpint(blob) do
    with {:ok, value, rest} <- take_ssh_string(blob),
         {:ok, decoded} <- decode_positive_ssh_mpint(value) do
      {:ok, decoded, rest}
    else
      _other -> {:error, :invalid_public_key}
    end
  end

  defp decode_positive_ssh_mpint(<<>>), do: {:error, :invalid_public_key}
  defp decode_positive_ssh_mpint(<<0>>), do: {:error, :invalid_public_key}

  defp decode_positive_ssh_mpint(<<0, rest::binary>>) when byte_size(rest) > 0 do
    if band(:binary.first(rest), 0x80) == 0x80 do
      {:ok, :binary.decode_unsigned(rest)}
    else
      {:error, :invalid_public_key}
    end
  end

  defp decode_positive_ssh_mpint(<<first, _rest::binary>>) when band(first, 0x80) == 0x80,
    do: {:error, :invalid_public_key}

  defp decode_positive_ssh_mpint(value), do: {:ok, :binary.decode_unsigned(value)}

  defp validate_rsa_public_key(n, e) do
    with true <- is_integer(n) and is_integer(e),
         true <- n > 1,
         true <- valid_rsa_exponent?(e, n),
         :ok <- validate_rsa_size(n) do
      :ok
    else
      _other -> {:error, :invalid_public_key}
    end
  end

  defp valid_rsa_exponent?(e, n) do
    e >= 3 and e < n and rem(e, 2) == 1
  end

  defp validate_rsa_size(n) do
    if bit_size(:binary.encode_unsigned(n)) >= @min_rsa_bits,
      do: :ok,
      else: {:error, :invalid_public_key}
  end

  defp ssh_blob(n, e), do: ssh_string("ssh-rsa") <> ssh_mpint(e) <> ssh_mpint(n)

  defp ssh_string(value), do: <<byte_size(value)::32, value::binary>>

  defp ssh_mpint(value) when is_integer(value) and value > 0 do
    encoded = :binary.encode_unsigned(value)

    if band(:binary.first(encoded), 0x80) == 0x80,
      do: ssh_string(<<0, encoded::binary>>),
      else: ssh_string(encoded)
  end

  defp rsa_public_key_pem(n, e) do
    der =
      der_sequence(
        rsa_encryption_algorithm_identifier() <>
          der_bit_string(rsa_public_key_der(n, e))
      )

    pem_body("PUBLIC KEY", der)
  end

  defp rsa_public_key_der(n, e), do: der_sequence(der_integer(n) <> der_integer(e))

  defp rsa_encryption_algorithm_identifier do
    der_sequence(
      <<0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01>> <>
        <<0x05, 0x00>>
    )
  end

  defp der_bit_string(content) do
    value = <<0, content::binary>>
    <<0x03, der_length(value)::binary, value::binary>>
  end

  defp pem_body(label, der) do
    encoded = der |> Base.encode64() |> wrap_base64()

    "-----BEGIN #{label}-----\n" <> encoded <> "\n-----END #{label}-----"
  end

  defp der_sequence(content), do: <<0x30, der_length(content)::binary, content::binary>>

  defp der_integer(value) when is_integer(value) and value > 0 do
    encoded = :binary.encode_unsigned(value)
    encoded = if :binary.first(encoded) >= 128, do: <<0, encoded::binary>>, else: encoded
    <<0x02, der_length(encoded)::binary, encoded::binary>>
  end

  defp der_length(content), do: der_length_bytes(byte_size(content))

  defp der_length_bytes(length) when length < 128, do: <<length>>

  defp der_length_bytes(length) do
    encoded = :binary.encode_unsigned(length)
    <<0x80 + byte_size(encoded), encoded::binary>>
  end

  defp wrap_base64(encoded) do
    encoded
    |> String.graphemes()
    |> Enum.chunk_every(64)
    |> Enum.map_join("\n", &Enum.join/1)
  end

  defp fingerprint_md5(blob) do
    :crypto.hash(:md5, blob)
    |> Base.encode16(case: :lower)
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
  end

  defp normalize_public_key_body(changeset) do
    update_change(changeset, :ssh_public_key_body, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value ->
        value
    end)
  end

  defp trim_change(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.trim(value)
      value -> value
    end)
  end
end
