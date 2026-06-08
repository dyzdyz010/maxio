defmodule Maxio.S3.Handlers.Service do
  @moduledoc "Service 级 handler：ListBuckets。"
  import Plug.Conn
  alias Maxio.Buckets
  alias Maxio.S3.Views.ListAllMyBuckets
  alias Maxio.S3.Log

  @spec list_buckets(Plug.Conn.t()) :: Plug.Conn.t()
  def list_buckets(conn) do
    principal = conn.assigns.principal

    buckets =
      Buckets.list()
      |> Enum.map(fn b -> %{name: b.name, creation_date: b.inserted_at} end)

    body =
      ListAllMyBuckets.render(%{
        owner: %{id: principal.access_key, display_name: "maxio"},
        buckets: buckets
      })

    Log.info("list buckets", action: :list_buckets, auth_type: conn.assigns.auth_type)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end
end
