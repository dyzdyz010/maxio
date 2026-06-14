defmodule Maxio.IAM.MFASecret do
  @moduledoc """
  AES-GCM envelope encryption for local MFA TOTP seeds.

  The encrypted payload is bound to the MFA serial through AEAD associated data,
  preventing ciphertexts from being copied between devices.
  """

  @aad_prefix "maxio:mfa-delete:totp:"

  @spec wrap(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def wrap(secret_base32, serial) when is_binary(secret_base32) and is_binary(serial) do
    with {:ok, key} <- master_key() do
      iv = :crypto.strong_rand_bytes(12)
      aad = aad(serial)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, secret_base32, aad, true)

      {:ok,
       %{
         "alg" => "AES-256-GCM",
         "key_id" => "local-default",
         "iv_b64" => Base.encode64(iv),
         "ciphertext_b64" => Base.encode64(ciphertext),
         "tag_b64" => Base.encode64(tag)
       }}
    end
  end

  @spec unwrap(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def unwrap(%{} = envelope, serial) when is_binary(serial) do
    with {:ok, key} <- master_key(),
         {:ok, iv} <- decode_b64(envelope, "iv_b64"),
         {:ok, ciphertext} <- decode_b64(envelope, "ciphertext_b64"),
         {:ok, tag} <- decode_b64(envelope, "tag_b64") do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             aad(serial),
             tag,
             false
           ) do
        :error -> {:error, :mfa_secret_decrypt_failed}
        secret -> {:ok, secret}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :mfa_secret_decrypt_failed}
  end

  def unwrap(_envelope, _serial), do: {:error, :invalid_mfa_secret_envelope}

  defp aad(serial), do: @aad_prefix <> serial

  defp decode_b64(envelope, key) do
    value = Map.get(envelope, key) || Map.get(envelope, String.to_atom(key))

    case value do
      value when is_binary(value) ->
        case Base.decode64(value) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, :invalid_mfa_secret_envelope}
        end

      _other ->
        {:error, :invalid_mfa_secret_envelope}
    end
  end

  defp master_key do
    cfg = Application.get_env(:maxio, :mfa, [])

    with key_b64 when is_binary(key_b64) <- Keyword.get(cfg, :secret_key),
         {:ok, key} <- Base.decode64(key_b64),
         32 <- byte_size(key) do
      {:ok, key}
    else
      _other -> {:error, :mfa_secret_key_not_configured}
    end
  end
end
