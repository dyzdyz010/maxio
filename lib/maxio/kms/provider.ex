defmodule Maxio.KMS.Provider do
  @moduledoc """
  Behaviour for KMS-like envelope-key providers.

  Providers own KMS key material and return encrypted data keys. Callers may use
  only the plaintext DEK in memory while streaming object bytes.
  """

  @type data_key :: %{
          plaintext_key: binary(),
          key_id: String.t(),
          encrypted_data_key_b64: String.t(),
          key_iv_b64: String.t(),
          key_tag_b64: String.t()
        }

  @callback generate_data_key(String.t(), binary()) :: {:ok, data_key()} | {:error, term()}
  @callback decrypt_data_key(map(), binary()) :: {:ok, binary()} | {:error, term()}
end
