defmodule Maxio.S3.Plugs.PrometheusMetrics do
  @moduledoc """
  Intercepts MinIO-style Prometheus metrics paths before S3 bucket dispatch.
  """

  import Plug.Conn

  alias Maxio.S3.{Log, Prometheus, PrometheusAuthz, PrometheusToken}

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    path = conn.request_path || ""

    if Prometheus.metrics_path?(path) do
      dispatch(conn, path)
    else
      conn
    end
  end

  defp dispatch(conn, path) when conn.method in ["GET", "HEAD"] do
    with :ok <- authorize(conn) do
      render_family(conn, path)
    else
      {:error, reason} -> deny(conn, reason)
    end
  end

  defp dispatch(conn, _path) do
    conn
    |> put_resp_header("allow", "GET, HEAD")
    |> put_resp_content_type("text/plain")
    |> send_resp(405, "method not allowed\n")
    |> halt()
  end

  defp render_family(conn, path) do
    case Prometheus.family_for_path(path) do
      {:ok, family} ->
        body = if conn.method == "HEAD", do: "", else: Prometheus.render(family)

        conn
        |> put_resp_header("content-type", Prometheus.content_type())
        |> send_resp(200, body)
        |> halt()

      :unknown ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "metrics endpoint not found\n")
        |> halt()
    end
  end

  defp authorize(conn) do
    cond do
      public?() ->
        :ok

      true ->
        with {:ok, token} <- bearer_token(conn),
             {:ok, principal, _claims} <- PrometheusToken.authenticate(token, now: now(conn)) do
          PrometheusAuthz.authorize(conn, principal)
        end
    end
  end

  defp public? do
    :maxio
    |> Application.get_env(:prometheus_metrics, [])
    |> Keyword.get(:public, false)
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      ["bearer " <> token] when token != "" -> {:ok, token}
      [] -> {:error, :missing_bearer_token}
      _other -> {:error, :invalid_bearer_token}
    end
  end

  defp now(conn), do: conn.private[:maxio_now] || DateTime.utc_now()

  defp deny(conn, reason) do
    Log.warn("prometheus metrics auth rejected",
      action: "admin:Prometheus",
      reason: reason,
      code: "AccessDenied",
      status: 403
    )

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "prometheus metrics access denied\n")
    |> halt()
  end
end
