defmodule Maxio.Admin.PolicyRequest do
  @moduledoc false

  import Plug.Conn, only: [get_req_header: 2]

  alias Maxio.S3.{ControlBody, Error}

  @max_policy_bytes 20_480
  @too_large_message "Policy document must not exceed 20480 bytes."

  @spec read_add_body!(Plug.Conn.t()) :: {Plug.Conn.t(), binary()}
  def read_add_body!(conn) do
    declared = positive_content_length!(conn)

    if declared > @max_policy_bytes do
      raise Error.new(:admin_invalid_argument, message: @too_large_message)
    end

    {conn, body, _trailers} =
      ControlBody.read!(conn, @max_policy_bytes, @too_large_message,
        too_large_error: :admin_invalid_argument
      )

    if byte_size(body) != declared do
      raise Error.new(:incomplete_body)
    end

    {conn, body}
  end

  defp positive_content_length!(conn) do
    case {get_req_header(conn, "transfer-encoding"), get_req_header(conn, "content-length")} do
      {[], [value]} when is_binary(value) -> parse_positive_content_length!(value)
      _invalid_or_ambiguous -> raise Error.new(:missing_content_length)
    end
  end

  defp parse_positive_content_length!(value) do
    with true <- Regex.match?(~r/\A[0-9]+\z/, value),
         {length, ""} when length > 0 <- Integer.parse(value) do
      length
    else
      _invalid -> raise Error.new(:missing_content_length)
    end
  end
end
