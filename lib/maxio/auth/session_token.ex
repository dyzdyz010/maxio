defmodule Maxio.Auth.SessionToken do
  @moduledoc """
  Session token hashing and constant-time verification helpers.
  """

  @spec hash(String.t()) :: String.t()
  def hash(token) when is_binary(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  @spec verify(String.t() | nil, String.t() | nil) :: boolean()
  def verify(token, expected_hash) when is_binary(token) and is_binary(expected_hash) do
    computed_hash = hash(token)

    byte_size(computed_hash) == byte_size(expected_hash) and
      Plug.Crypto.secure_compare(computed_hash, expected_hash)
  end

  def verify(_token, _expected_hash), do: false
end
