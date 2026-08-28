defmodule Maxio.S3.Plugs.SurfaceClassifier do
  @moduledoc """
  Classifies requests for downstream observers after address-style resolution.

  Path-style MinIO admin requests are control-plane traffic and must not be
  attributed to the shadowed S3 bucket named `minio`. Virtual-host requests
  with the same path remain ordinary S3 object traffic.
  """

  @behaviour Plug

  import Plug.Conn, only: [assign: 3]

  alias Maxio.S3.ReservedNamespace

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    surface = if ReservedNamespace.claimed?(conn, :admin), do: :admin, else: :s3
    assign(conn, :maxio_surface, surface)
  end
end
