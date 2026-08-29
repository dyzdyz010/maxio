defmodule Maxio.S3.Plugs.ResponseTransformPolicy do
  @moduledoc """
  Applies response transformation policy before the HTTP adapter sees a response.

  Config help has an exact plaintext JSON wire contract. Bandit otherwise compresses
  any eligible response when the client advertises a supported content encoding,
  including authentication and handler errors produced before or after Admin dispatch.
  Registering the policy before authentication keeps every outcome on the same framing
  rule without changing Bandit's global compression behavior for other surfaces.
  """

  @behaviour Plug

  import Plug.Conn, only: [register_before_send: 2, update_resp_header: 4]

  @config_help_path "/minio/admin/v3/help-config-kv"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %{
          assigns: %{maxio_surface: :admin, s3_address_style: :path},
          method: "GET",
          request_path: @config_help_path
        } = conn,
        _opts
      ) do
    register_before_send(conn, &prevent_transform/1)
  end

  def call(conn, _opts), do: conn

  defp prevent_transform(conn) do
    update_resp_header(conn, "cache-control", "no-transform", &merge_no_transform/1)
  end

  defp merge_no_transform(value) do
    if "no-transform" in Plug.Conn.Utils.list(value) do
      value
    else
      case String.trim(value) do
        "" -> "no-transform"
        _nonempty -> value <> ", no-transform"
      end
    end
  end
end
