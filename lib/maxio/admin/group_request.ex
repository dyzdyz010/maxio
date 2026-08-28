defmodule Maxio.Admin.GroupRequest do
  @moduledoc """
  Bounded plaintext request boundary for MinIO admin group membership updates.

  The wire structure follows Go's `encoding/json` zero-value, unknown-field,
  and duplicate-key behavior. IAM validation deliberately happens after this
  parser so member request order remains available for error precedence.
  """

  alias Maxio.S3.{ControlBody, Error}

  @max_group_request_bytes 262_272
  @too_large_message "Configuration data provided exceeds the allowed maximum of 262272 bytes"

  @type update_request :: %{
          group: String.t(),
          members: [String.t()],
          group_status: String.t(),
          remove?: boolean()
        }

  @spec read_update_body!(Plug.Conn.t()) :: {Plug.Conn.t(), update_request()}
  def read_update_body!(conn) do
    {conn, body, _trailers} =
      ControlBody.read!(conn, @max_group_request_bytes, @too_large_message,
        too_large_error: :admin_config_too_large
      )

    {conn, decode_request!(body)}
  end

  defp decode_request!(body) do
    with {:ok, %Jason.OrderedObject{values: values}} <-
           Jason.decode(body, objects: :ordered_objects),
         request = Map.new(values),
         {:ok, group} <- string_or_zero(request, "group"),
         {:ok, members} <- members_or_zero(request),
         {:ok, group_status} <- string_or_zero(request, "groupStatus"),
         {:ok, remove?} <- boolean_or_zero(request, "isRemove") do
      %{
        group: group,
        members: members,
        group_status: group_status,
        remove?: remove?
      }
    else
      _other -> raise Error.new(:admin_config_bad_json)
    end
  end

  defp string_or_zero(request, key) do
    case Map.get(request, key) do
      nil -> {:ok, ""}
      value when is_binary(value) -> {:ok, value}
      _other -> :error
    end
  end

  defp members_or_zero(request) do
    case Map.get(request, "members") do
      nil ->
        {:ok, []}

      members when is_list(members) ->
        if Enum.all?(members, &is_binary/1), do: {:ok, members}, else: :error

      _other ->
        :error
    end
  end

  defp boolean_or_zero(request, key) do
    case Map.get(request, key) do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      _other -> :error
    end
  end
end
