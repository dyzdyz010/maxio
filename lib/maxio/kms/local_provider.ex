defmodule Maxio.KMS.LocalProvider do
  @moduledoc """
  Local KMS provider for maxio development and tests.

  This is not an AWS KMS client. It implements the same envelope shape with a
  configurable local 256-bit wrapping key so the S3 data path can stay provider
  agnostic.
  """
  @behaviour Maxio.KMS.Provider

  @aad_prefix "maxio-local-kms-v1"
  @default_key_id "alias/maxio/default"

  @impl true
  def generate_data_key(key_id, context) when is_binary(key_id) and is_binary(context) do
    with {:ok, wrapping_key} <- wrapping_key(key_id) do
      dek = :crypto.strong_rand_bytes(32)
      iv = :crypto.strong_rand_bytes(12)

      {encrypted, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          wrapping_key,
          iv,
          dek,
          aad(key_id, context),
          true
        )

      {:ok,
       %{
         plaintext_key: dek,
         key_id: key_id,
         encrypted_data_key_b64: Base.encode64(encrypted),
         key_iv_b64: Base.encode64(iv),
         key_tag_b64: Base.encode64(tag)
       }}
    end
  end

  @impl true
  def decrypt_data_key(%{} = envelope, context) when is_binary(context) do
    key_id = envelope_value(envelope, :kms_key_id)

    with key_id when is_binary(key_id) and key_id != "" <- key_id,
         {:ok, wrapping_key} <- wrapping_key(key_id),
         {:ok, encrypted} <- b64_value(envelope, :kms_encrypted_dek_b64),
         {:ok, iv} <- b64_value(envelope, :kms_dek_iv_b64),
         {:ok, tag} <- b64_value(envelope, :kms_dek_tag_b64) do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             wrapping_key,
             iv,
             encrypted,
             aad(key_id, context),
             tag,
             false
           ) do
        :error -> {:error, :authentication_failed}
        dek when byte_size(dek) == 32 -> {:ok, dek}
        _wrong_size -> {:error, :invalid_data_key}
      end
    else
      nil -> {:error, :missing_key_id}
      "" -> {:error, :missing_key_id}
      :error -> {:error, :invalid_envelope}
      {:error, _} = err -> err
      _other -> {:error, :invalid_envelope}
    end
  end

  @spec default_key_id() :: String.t()
  def default_key_id do
    :maxio
    |> Application.get_env(:kms, [])
    |> Keyword.get(:default_key_id, @default_key_id)
  end

  defp wrapping_key(key_id) do
    cfg = Application.get_env(:maxio, :kms, [])
    keys = Keyword.get(cfg, :keys, %{})

    cond do
      is_map(keys) and map_size(keys) > 0 ->
        case Map.fetch(keys, key_id) do
          {:ok, key} -> decode_key(key)
          :error -> {:error, :unknown_key_id}
        end

      key = Keyword.get(cfg, :master_key) ->
        decode_key(key)

      true ->
        :maxio
        |> Application.get_env(:sse, [])
        |> Keyword.get(:master_key)
        |> decode_key()
    end
  end

  defp decode_key(nil), do: {:error, :missing_master_key}

  defp decode_key(key) when is_binary(key) do
    case Base.decode64(key) do
      {:ok, raw} when byte_size(raw) == 32 -> {:ok, raw}
      {:ok, _wrong_size} -> {:error, :invalid_master_key}
      :error -> {:error, :invalid_master_key}
    end
  end

  defp aad(key_id, context),
    do: IO.iodata_to_binary([@aad_prefix, 0, key_id, 0, context])

  defp b64_value(envelope, key) do
    case envelope_value(envelope, key) do
      value when is_binary(value) -> Base.decode64(value)
      _other -> :error
    end
  end

  defp envelope_value(envelope, key),
    do: Map.get(envelope, key) || Map.get(envelope, Atom.to_string(key))
end
