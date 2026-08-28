defmodule Maxio.Admin.ConfigKV.Request do
  @moduledoc """
  Transport and caller-secret envelope boundary for Admin Config KVS requests.

  This module verifies bounded encrypted mutation bodies before decrypting them.
  It deliberately has no knowledge of configuration subsystem names, keys, or
  plaintext grammar.
  """

  import Plug.Conn, only: [get_req_header: 2]

  alias Maxio.Admin.Envelope
  alias Maxio.Auth.SigningSecret
  alias Maxio.S3.{ControlBody, Error}

  @max_encrypted_size 262_272
  @too_large_message "Configuration data provided exceeds the allowed maximum of 262272 bytes"
  @ascii_decimal ~r/\A[0-9]+\z/

  @spec declared_mutation_length!(Plug.Conn.t()) :: non_neg_integer()
  def declared_mutation_length!(conn) do
    case {get_req_header(conn, "content-length"), get_req_header(conn, "transfer-encoding")} do
      {[value], []} -> parse_declared_length!(value)
      _invalid_or_ambiguous -> raise(Error.new(:admin_config_too_large))
    end
  end

  @spec read_mutation!(Plug.Conn.t(), SigningSecret.t(), non_neg_integer()) ::
          {Plug.Conn.t(), String.t()}
  def read_mutation!(conn, %SigningSecret{} = caller_secret, declared_length)
      when is_integer(declared_length) and declared_length >= 0 do
    expected_hash = authenticated_payload_hash!(conn)

    {conn, ciphertext, _trailers} =
      ControlBody.read!(conn, @max_encrypted_size, @too_large_message,
        too_large_error: :admin_config_too_large,
        expected_length: declared_length,
        length_mismatch_error: :admin_config_bad_json,
        verify_payload_sha256: expected_hash
      )

    case Envelope.decrypt(caller_secret, ciphertext) do
      {:ok, plaintext} -> validate_plaintext!(conn, plaintext)
      {:error, _discarded_reason} -> raise(Error.new(:admin_config_bad_json))
    end
  end

  def read_mutation!(_conn, _caller_secret, _declared_length),
    do: raise(Error.new(:internal_error))

  @spec encrypt_get!(SigningSecret.t(), iodata()) :: binary()
  def encrypt_get!(%SigningSecret{} = caller_secret, plaintext) do
    case Envelope.encrypt(caller_secret, plaintext) do
      {:ok, ciphertext} -> ciphertext
      {:error, _discarded_reason} -> raise(Error.new(:internal_error))
    end
  end

  def encrypt_get!(_caller_secret, _plaintext), do: raise(Error.new(:internal_error))

  defp parse_declared_length!(value) when is_binary(value) do
    with true <- Regex.match?(@ascii_decimal, value),
         {length, ""} <- Integer.parse(value),
         true <- length <= @max_encrypted_size do
      length
    else
      _invalid -> raise(Error.new(:admin_config_too_large))
    end
  end

  defp parse_declared_length!(_value), do: raise(Error.new(:admin_config_too_large))

  defp authenticated_payload_hash!(%{assigns: %{sigv4_context: %{signed_payload_sha256: hash}}})
       when is_binary(hash),
       do: hash

  defp authenticated_payload_hash!(_conn), do: raise(Error.new(:internal_error))

  defp validate_plaintext!(conn, plaintext) when is_binary(plaintext) do
    if String.valid?(plaintext) do
      {conn, plaintext}
    else
      raise(Error.new(:admin_config_bad_json))
    end
  end

  defp validate_plaintext!(_conn, _plaintext), do: raise(Error.new(:admin_config_bad_json))
end
