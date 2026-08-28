defmodule Maxio.S3.Plugs.RequestMetrics do
  @moduledoc """
  Best-effort observer for local S3 request metrics.

  The plug records through `register_before_send/2` and never changes the S3
  response. Errors are logged and swallowed.
  """

  @behaviour Plug

  import Plug.Conn

  alias Maxio.S3.Log
  alias Maxio.S3.Metrics.RequestMetrics

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{maxio_surface: :admin}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_private(:maxio_request_metrics_started_at, System.monotonic_time(:microsecond))
    |> register_before_send(&record/1)
  end

  defp record(conn) do
    RequestMetrics.record_conn(conn)
    conn
  rescue
    err ->
      Log.warn("request metrics plug skipped",
        action: conn.assigns[:s3_action],
        bucket: conn.assigns[:s3_bucket],
        key: conn.assigns[:s3_key],
        reason: Exception.message(err)
      )

      conn
  catch
    kind, reason ->
      Log.warn("request metrics plug caught",
        action: conn.assigns[:s3_action],
        bucket: conn.assigns[:s3_bucket],
        key: conn.assigns[:s3_key],
        reason: inspect({kind, reason})
      )

      conn
  end
end
