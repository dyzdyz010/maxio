defmodule Maxio.IAM.AccessKeySecret do
  @moduledoc """
  AES-GCM envelope encryption for long-term IAM access-key secrets.

  The encrypted payload is bound to the access key id through AEAD associated
  data. Existing plaintext rows are still readable so operators can deploy this
  change before rotating or rewriting old credentials.
  """

  @prefix "maxio-ak-secret-v1:"
  @aad_prefix "maxio:iam:access-key-secret:v1:"

  alias Maxio.IAM.SigningSecretKeyring

  @spec wrap(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def wrap(secret_key, access_key_id)
      when is_binary(secret_key) and secret_key != "" and is_binary(access_key_id) and
             access_key_id != "" do
    with {:ok, {key_id, key}} <- SigningSecretKeyring.current_key() do
      iv = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          iv,
          secret_key,
          aad(access_key_id),
          true
        )

      envelope = %{
        "alg" => "AES-256-GCM",
        "key_id" => key_id,
        "iv_b64" => Base.encode64(iv),
        "ciphertext_b64" => Base.encode64(ciphertext),
        "tag_b64" => Base.encode64(tag)
      }

      {:ok, @prefix <> Base.url_encode64(Jason.encode!(envelope), padding: false)}
    end
  end

  def wrap(_secret_key, _access_key_id), do: {:error, :invalid_access_key_secret}

  @spec unwrap(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def unwrap(@prefix <> encoded, access_key_id)
      when is_binary(encoded) and is_binary(access_key_id) and access_key_id != "" do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, envelope} <- decode_envelope(json),
         :ok <- validate_alg(envelope),
         {:ok, key_id} <- envelope_key_id(envelope),
         {:ok, key} <- SigningSecretKeyring.key(key_id),
         {:ok, iv} <- decode_b64(envelope, "iv_b64"),
         {:ok, ciphertext} <- decode_b64(envelope, "ciphertext_b64"),
         {:ok, tag} <- decode_b64(envelope, "tag_b64") do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             aad(access_key_id),
             tag,
             false
           ) do
        :error -> {:error, :access_key_secret_decrypt_failed}
        "" -> {:error, :invalid_access_key_secret}
        plaintext -> {:ok, plaintext}
      end
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :invalid_access_key_secret_envelope}
      _other -> {:error, :invalid_access_key_secret_envelope}
    end
  rescue
    _error -> {:error, :access_key_secret_decrypt_failed}
  end

  def unwrap("", _access_key_id), do: {:error, :invalid_access_key_secret}
  def unwrap(secret_key, _access_key_id) when is_binary(secret_key), do: {:ok, secret_key}
  def unwrap(_secret_key, _access_key_id), do: {:error, :invalid_access_key_secret}

  @spec encrypted?(term()) :: boolean()
  def encrypted?(@prefix <> _encoded), do: true
  def encrypted?(_other), do: false

  @spec envelope_metadata(term()) ::
          {:ok, %{alg: String.t(), key_id: String.t()}} | :plaintext | {:error, term()}
  def envelope_metadata(@prefix <> encoded) when is_binary(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, envelope} <- decode_envelope(json),
         :ok <- validate_alg(envelope),
         {:ok, key_id} <- envelope_key_id(envelope) do
      {:ok, %{alg: "AES-256-GCM", key_id: key_id}}
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :invalid_access_key_secret_envelope}
      _other -> {:error, :invalid_access_key_secret_envelope}
    end
  rescue
    _error -> {:error, :invalid_access_key_secret_envelope}
  end

  def envelope_metadata(secret_key) when is_binary(secret_key), do: :plaintext
  def envelope_metadata(_secret_key), do: {:error, :invalid_access_key_secret}

  defp aad(access_key_id), do: @aad_prefix <> access_key_id

  defp decode_envelope(json) do
    case Jason.decode(json) do
      {:ok, %{} = envelope} -> {:ok, envelope}
      {:ok, _other} -> {:error, :invalid_access_key_secret_envelope}
      {:error, _error} -> {:error, :invalid_access_key_secret_envelope}
    end
  end

  defp decode_b64(envelope, key) do
    case Map.get(envelope, key) || Map.get(envelope, atom_key(key)) do
      value when is_binary(value) ->
        case Base.decode64(value) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, :invalid_access_key_secret_envelope}
        end

      _other ->
        {:error, :invalid_access_key_secret_envelope}
    end
  end

  defp atom_key("iv_b64"), do: :iv_b64
  defp atom_key("ciphertext_b64"), do: :ciphertext_b64
  defp atom_key("tag_b64"), do: :tag_b64
  defp atom_key("key_id"), do: :key_id
  defp atom_key("alg"), do: :alg

  defp validate_alg(envelope) do
    case Map.get(envelope, "alg") || Map.get(envelope, atom_key("alg")) do
      "AES-256-GCM" -> :ok
      _other -> {:error, :invalid_access_key_secret_envelope}
    end
  end

  defp envelope_key_id(envelope) do
    case Map.get(envelope, "key_id") || Map.get(envelope, atom_key("key_id")) do
      key_id when is_binary(key_id) and key_id != "" ->
        {:ok, key_id}

      _other ->
        {:error, :invalid_access_key_secret_envelope}
    end
  end
end
