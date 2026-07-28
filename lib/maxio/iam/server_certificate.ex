defmodule Maxio.IAM.ServerCertificate do
  @moduledoc "Persisted local IAM server certificate metadata and PEM validation."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "iam_server_certificates" do
    field :server_certificate_name, :string
    field :server_certificate_arn, :string
    field :path, :string, default: "/"
    field :certificate_body, :string
    field :certificate_chain, :string
    field :private_key, :string, virtual: true
    field :private_key_fingerprint, :string
    field :expiration, :utc_datetime_usec
    field :tags, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required_upload [
    :server_certificate_name,
    :server_certificate_arn,
    :path,
    :certificate_body,
    :private_key,
    :private_key_fingerprint,
    :expiration
  ]
  @metadata_fields [:server_certificate_name, :server_certificate_arn, :path, :tags]
  @optional_upload [:certificate_chain, :tags]
  @name_pattern ~r/\A[A-Za-z0-9+=,.@_-]+\z/
  @path_pattern ~r{\A(?:/|/[!-~]+/)\z}
  @server_certificate_arn_pattern ~r|\Aarn:aws:iam:::server-certificate/(?:[!-~]+/)?[A-Za-z0-9+=,.@_-]+\z|
  @pem_max_chars 2_097_152

  @spec upload_changeset(t(), map()) :: Ecto.Changeset.t()
  def upload_changeset(server_certificate, attrs) do
    server_certificate
    |> cast(attrs, @required_upload ++ @optional_upload)
    |> trim_change(:server_certificate_name)
    |> trim_change(:server_certificate_arn)
    |> trim_change(:path)
    |> normalize_pem_change(:certificate_body)
    |> normalize_pem_change(:certificate_chain)
    |> normalize_pem_change(:private_key)
    |> put_certificate_validation()
    |> validate_required(@required_upload)
    |> validate_common()
  end

  @spec metadata_changeset(t(), map()) :: Ecto.Changeset.t()
  def metadata_changeset(server_certificate, attrs) do
    server_certificate
    |> cast(attrs, @metadata_fields)
    |> trim_change(:server_certificate_name)
    |> trim_change(:server_certificate_arn)
    |> trim_change(:path)
    |> validate_required([:server_certificate_name, :server_certificate_arn, :path])
    |> validate_common()
  end

  defp validate_common(changeset) do
    changeset
    |> validate_length(:server_certificate_name, min: 1, max: 128)
    |> validate_format(:server_certificate_name, @name_pattern)
    |> validate_length(:path, min: 1, max: 512)
    |> validate_format(:path, @path_pattern)
    |> validate_length(:server_certificate_arn, min: 1, max: 512)
    |> validate_format(:server_certificate_arn, @server_certificate_arn_pattern)
    |> validate_length(:certificate_body, min: 1, max: @pem_max_chars)
    |> validate_length(:certificate_chain, max: @pem_max_chars)
    |> validate_length(:private_key, min: 1, max: @pem_max_chars)
    |> validate_length(:private_key_fingerprint, is: 64)
    |> validate_arn_matches_name()
    |> validate_tags()
    |> unique_constraint(:server_certificate_name, name: :iam_server_certificates_name_index)
    |> unique_constraint(:server_certificate_name, name: :iam_server_certificates_name_ci_index)
    |> unique_constraint(:server_certificate_arn, name: :iam_server_certificates_arn_index)
  end

  defp put_certificate_validation(changeset) do
    certificate_body = get_change(changeset, :certificate_body)
    private_key = get_change(changeset, :private_key)
    certificate_chain = get_change(changeset, :certificate_chain)

    with {:ok, cert} <- decode_leaf_certificate(certificate_body),
         {:ok, key} <- decode_private_key(private_key),
         :ok <- validate_certificate_key_pair(cert, key),
         :ok <- validate_certificate_chain(certificate_chain) do
      changeset
      |> put_change(:private_key_fingerprint, private_key_fingerprint(key.der))
      |> put_change(:expiration, cert.expiration)
    else
      {:error, :key_pair_mismatch} ->
        add_error(changeset, :private_key, "does not match certificate public key",
          validation: :key_pair_mismatch
        )

      {:error, _reason} ->
        add_error(changeset, :certificate_body, "must be a valid PEM encoded certificate",
          validation: :malformed_certificate
        )
    end
  end

  defp decode_leaf_certificate(body) when is_binary(body) do
    with [{:Certificate, der, :not_encrypted}] <- :public_key.pem_decode(body),
         {:Certificate,
          {:TBSCertificate, _, _, _, _, {:Validity, _not_before, not_after}, _, spki, _, _, _}, _,
          _} <- :public_key.pem_entry_decode({:Certificate, der, :not_encrypted}),
         {:ok, expiration} <- validity_time(not_after) do
      {:ok, %{der: der, public_key: public_key_der(spki), expiration: expiration}}
    else
      _other -> {:error, :malformed_certificate}
    end
  rescue
    _error -> {:error, :malformed_certificate}
  end

  defp decode_leaf_certificate(_body), do: {:error, :malformed_certificate}

  defp decode_private_key(body) when is_binary(body) do
    case :public_key.pem_decode(body) do
      [{type, der, :not_encrypted} = entry] when type in [:RSAPrivateKey, :PrivateKeyInfo] ->
        case :public_key.pem_entry_decode(entry) do
          {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} ->
            {:ok,
             %{der: der, public_key: :public_key.der_encode(:RSAPublicKey, {:RSAPublicKey, n, e})}}

          _other ->
            {:error, :malformed_certificate}
        end

      _other ->
        {:error, :malformed_certificate}
    end
  rescue
    _error -> {:error, :malformed_certificate}
  end

  defp decode_private_key(_body), do: {:error, :malformed_certificate}

  defp validate_certificate_key_pair(%{public_key: public_key}, %{public_key: public_key}),
    do: :ok

  defp validate_certificate_key_pair(_cert, _key), do: {:error, :key_pair_mismatch}

  defp validate_certificate_chain(nil), do: :ok
  defp validate_certificate_chain(""), do: :ok

  defp validate_certificate_chain(chain) when is_binary(chain) do
    chain
    |> :public_key.pem_decode()
    |> case do
      [] ->
        {:error, :malformed_certificate}

      entries ->
        if Enum.all?(entries, &certificate_entry?/1),
          do: :ok,
          else: {:error, :malformed_certificate}
    end
  rescue
    _error -> {:error, :malformed_certificate}
  end

  defp validate_certificate_chain(_chain), do: {:error, :malformed_certificate}

  defp certificate_entry?({:Certificate, _der, :not_encrypted} = entry) do
    match?({:Certificate, _, _, _}, :public_key.pem_entry_decode(entry))
  rescue
    _error -> false
  end

  defp certificate_entry?(_entry), do: false

  defp private_key_fingerprint(der), do: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)

  defp public_key_der({:SubjectPublicKeyInfo, _algorithm, key_der}), do: key_der

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

  defp validate_arn_matches_name(changeset) do
    validate_change(changeset, :server_certificate_arn, fn field, value ->
      name = get_field(changeset, :server_certificate_name)
      path = get_field(changeset, :path)

      expected =
        if is_binary(name) and name != "" and is_binary(path) do
          "arn:aws:iam:::server-certificate/#{server_certificate_resource(path, name)}"
        end

      if value == expected do
        []
      else
        [{field, "must match server certificate name"}]
      end
    end)
  end

  defp validate_tags(changeset) do
    validate_change(changeset, :tags, fn :tags, value ->
      if is_map(value) do
        tags = Maxio.Tags.map_to_list(value)

        if Maxio.Tags.validate(tags, :bucket) == :ok do
          []
        else
          [tags: "must contain valid IAM tag keys and values"]
        end
      else
        [tags: "must be a map"]
      end
    end)
  end

  defp server_certificate_resource("/", name), do: name

  defp server_certificate_resource("/" <> path_body, name), do: path_body <> name

  defp trim_change(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.trim(value)
      value -> value
    end)
  end

  defp normalize_pem_change(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value <> "\n"

      value ->
        value
    end)
  end
end
