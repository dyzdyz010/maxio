defmodule Maxio.Admin.PolicyAssociationRequest do
  @moduledoc """
  Strict transport and encrypted-body boundary for builtin policy association updates.

  Transport validation is intentionally separate from body consumption so the Admin
  dispatcher can apply the MinIO gate order to unknown operations without decrypting them.
  """

  import Plug.Conn, only: [get_req_header: 2]

  alias Maxio.Admin.Envelope
  alias Maxio.Auth.SigningSecret
  alias Maxio.S3.{ControlBody, Error}

  @maximum_encrypted_length 262_272
  @too_large_message "Configuration data provided exceeds the allowed maximum of 262272 bytes"
  @decimal ~r/\A[0-9]+\z/

  @spec validate_transport!(Plug.Conn.t()) :: non_neg_integer()
  def validate_transport!(conn) do
    length = declared_length!(conn)

    case get_req_header(conn, "content-type") do
      ["application/octet-stream"] -> length
      _other -> raise Error.new(:admin_invalid_argument)
    end
  end

  @spec read!(Plug.Conn.t(), SigningSecret.t(), non_neg_integer()) ::
          {Plug.Conn.t(), %{policies: [String.t()], principal: {:user | :group, String.t()}}}
  def read!(conn, %SigningSecret{} = signing_secret, declared_length)
      when is_integer(declared_length) and declared_length >= 0 do
    expected_hash = authenticated_payload_hash!(conn)

    {conn, ciphertext, _trailers} =
      ControlBody.read!(conn, @maximum_encrypted_length, @too_large_message,
        too_large_error: :admin_config_too_large,
        expected_length: declared_length,
        length_mismatch_error: :admin_config_bad_json,
        verify_payload_sha256: expected_hash
      )

    plaintext = decrypt!(signing_secret, ciphertext)
    {conn, decode_request!(plaintext)}
  end

  def read!(_conn, _signing_secret, _declared_length), do: raise(Error.new(:internal_error))

  defp declared_length!(conn) do
    case {get_req_header(conn, "content-length"), get_req_header(conn, "transfer-encoding")} do
      {[value], []} -> parse_length!(value)
      _other -> raise Error.new(:admin_config_too_large)
    end
  end

  defp parse_length!(value) when is_binary(value) do
    with true <- Regex.match?(@decimal, value),
         {length, ""} <- Integer.parse(value),
         true <- length <= @maximum_encrypted_length do
      length
    else
      _other -> raise Error.new(:admin_config_too_large)
    end
  end

  defp parse_length!(_value), do: raise(Error.new(:admin_config_too_large))

  defp authenticated_payload_hash!(%{assigns: %{sigv4_context: %{signed_payload_sha256: hash}}})
       when is_binary(hash),
       do: hash

  defp authenticated_payload_hash!(_conn), do: raise(Error.new(:internal_error))

  defp decrypt!(secret, ciphertext) do
    case Envelope.decrypt(secret, ciphertext) do
      {:ok, plaintext} -> plaintext
      {:error, _reason} -> raise Error.new(:admin_config_bad_json)
    end
  end

  defp decode_request!(plaintext) do
    with {:ok, request} when is_map(request) <- Jason.decode(plaintext),
         policies when is_list(policies) and policies != [] <- Map.get(request, "policies"),
         true <- Enum.all?(policies, &(is_binary(&1) and &1 != "")),
         {:ok, principal} <- principal(request) do
      %{policies: Enum.sort(Enum.uniq(policies)), principal: principal}
    else
      _other -> raise Error.new(:admin_config_bad_json)
    end
  end

  defp principal(request) do
    user = Map.get(request, "user")
    group = Map.get(request, "group")

    case {user, group} do
      {user, nil} when is_binary(user) and user != "" -> {:ok, {:user, user}}
      {nil, group} when is_binary(group) and group != "" -> {:ok, {:group, group}}
      _other -> :error
    end
  end
end
