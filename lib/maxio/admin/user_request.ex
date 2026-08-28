defmodule Maxio.Admin.UserRequest do
  @moduledoc """
  Strict bounded request boundary for MinIO admin AddUser.

  The encrypted body is length-checked and compared with the SHA256 value that
  SigV4 authenticated before it is decrypted. Plaintext and either credential
  remain request-local and are never logged or embedded in error terms.
  """

  import Plug.Conn

  alias Maxio.Admin.Envelope
  alias Maxio.Auth.SigningSecret
  alias Maxio.S3.{ControlBody, Error}

  @max_encrypted_size 262_272
  @too_large_message "Configuration data provided exceeds the allowed maximum of 262272 bytes"
  @allowed_keys MapSet.new(["policy", "secretKey", "status"])
  @ascii_decimal ~r/\A[0-9]+\z/

  @spec read_add_body!(Plug.Conn.t(), SigningSecret.t()) ::
          {Plug.Conn.t(), %{secret_key: binary(), policy: binary(), status: String.t()}}
  def read_add_body!(conn, %SigningSecret{} = caller_secret) do
    expected_length = declared_length!(conn)
    expected_hash = authenticated_payload_hash!(conn)

    {conn, ciphertext, _trailers} =
      ControlBody.read!(conn, @max_encrypted_size, @too_large_message,
        too_large_error: :admin_config_too_large,
        expected_length: expected_length,
        length_mismatch_error: :admin_config_bad_json,
        verify_payload_sha256: expected_hash
      )

    plaintext = decrypt!(caller_secret, ciphertext)
    {conn, decode_request!(plaintext)}
  end

  def read_add_body!(_conn, _caller_secret), do: raise(Error.new(:internal_error))

  defp declared_length!(conn) do
    transfer_encoding = get_req_header(conn, "transfer-encoding")

    case {get_req_header(conn, "content-length"), transfer_encoding} do
      {[value], []} -> parse_declared_length!(value)
      _other -> raise Error.new(:admin_config_too_large)
    end
  end

  defp parse_declared_length!(value) when is_binary(value) do
    with true <- Regex.match?(@ascii_decimal, value),
         {length, ""} <- Integer.parse(value),
         true <- length <= @max_encrypted_size do
      length
    else
      _other -> raise Error.new(:admin_config_too_large)
    end
  end

  defp parse_declared_length!(_value), do: raise(Error.new(:admin_config_too_large))

  defp authenticated_payload_hash!(conn) do
    case conn.assigns do
      %{sigv4_context: %{signed_payload_sha256: expected_hash}} -> expected_hash
      _missing_capability -> raise Error.new(:internal_error)
    end
  end

  defp decrypt!(caller_secret, ciphertext) do
    case Envelope.decrypt(caller_secret, ciphertext) do
      {:ok, plaintext} -> plaintext
      {:error, _reason} -> raise Error.new(:admin_config_bad_json)
    end
  end

  defp decode_request!(plaintext) do
    with {:ok, %Jason.OrderedObject{values: values}} <-
           Jason.decode(plaintext, objects: :ordered_objects),
         true <- unique_allowed_keys?(values),
         request = Map.new(values),
         "enabled" <- Map.get(request, "status"),
         policy when is_binary(policy) <- Map.get(request, "policy", ""),
         true <- policy == "" do
      validate_secret!(Map.get(request, "secretKey"), policy)
    else
      _other -> raise Error.new(:admin_config_bad_json)
    end
  end

  defp unique_allowed_keys?(values) do
    keys = Enum.map(values, &elem(&1, 0))
    length(keys) == length(Enum.uniq(keys)) and MapSet.subset?(MapSet.new(keys), @allowed_keys)
  end

  defp validate_secret!(secret_key, policy) when is_binary(secret_key) do
    if byte_size(secret_key) >= 8 do
      %{secret_key: secret_key, policy: policy, status: "enabled"}
    else
      raise Error.new(:admin_invalid_secret_key)
    end
  end

  defp validate_secret!(_secret_key, _policy), do: raise(Error.new(:admin_invalid_secret_key))
end
