defmodule Maxio.S3.Plugs.PostObject do
  @moduledoc """
  Handles S3 POST Object browser forms before the normal SigV4 plug.

  SigV4 POST places its credential, policy, and signature in multipart form
  fields instead of Authorization/query canonical request material, so this plug
  owns that authentication path and then delegates to the shared PutObject core.
  """

  import Plug.Conn

  alias Maxio.S3.Handlers.Object
  alias Maxio.S3.{Error, ErrorView, Log, PostObjectForm, RawPath}

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    if post_object_form?(conn) do
      handle(conn)
    else
      conn
    end
  end

  defp handle(conn) do
    conn = assign(conn, :s3_metrics_operation, :post_object)

    case prepare_form(conn) do
      {:ok, conn, prepared} ->
        delegate_to_object_handler(conn, prepared)

      {:error, conn, err} ->
        render_error(conn, err)
    end
  end

  defp prepare_form(conn) do
    try do
      :ok = reject_query_params!(conn)
      :ok = reject_mixed_auth!(conn)
      :ok = require_content_length!(conn)

      bucket = conn.assigns.s3_bucket
      prepared = PostObjectForm.prepare!(conn, bucket)
      conn = assign_prepared_metrics(conn, prepared)

      {:ok, conn, prepared}
    rescue
      err in Maxio.S3.Error ->
        {:error, conn, err}

      other ->
        Log.error("unhandled exception in post object",
          code: "InternalError",
          status: 500,
          reason: Exception.message(other)
        )

        {:error, conn, Error.new(:internal_error)}
    end
  end

  defp delegate_to_object_handler(conn, prepared) do
    try do
      conn
      |> Object.post_form(prepared)
      |> halt()
    rescue
      err in Maxio.S3.Error ->
        render_error(conn, err)

      other ->
        Log.error("unhandled exception in post object",
          code: "InternalError",
          status: 500,
          reason: Exception.message(other)
        )

        render_error(conn, Error.new(:internal_error))
    end
  end

  defp post_object_form?(conn) do
    conn.method == "POST" and conn.assigns[:s3_level] == :bucket and multipart_form?(conn)
  end

  defp multipart_form?(conn) do
    case header(conn, "content-type") do
      nil ->
        false

      value ->
        value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
          "multipart/form-data"
    end
  end

  defp reject_query_params!(conn) do
    case conn.query_string do
      nil ->
        :ok

      "" ->
        :ok

      _query ->
        raise Error.new(:invalid_request,
                message: "POST Object does not support query parameters"
              )
    end
  end

  defp reject_mixed_auth!(conn) do
    if get_req_header(conn, "authorization") != [] do
      raise Error.new(:invalid_request, message: "POST Object does not use Authorization header")
    end

    :ok
  end

  defp require_content_length!(conn) do
    case get_req_header(conn, "content-length") do
      [raw] ->
        case Integer.parse(raw) do
          {n, ""} when n >= 0 -> :ok
          _ -> raise Error.new(:invalid_request, message: "Invalid Content-Length")
        end

      _other ->
        raise Error.new(:missing_content_length)
    end
  end

  defp render_error(conn, %Error{} = err) do
    request_id = conn |> get_req_header("x-request-id") |> List.first()
    err = %{err | request_id: request_id, resource: err.resource || RawPath.decoded_path(conn)}
    {status, body} = ErrorView.render(err)

    Log.warn("post object error response",
      code: err.code,
      status: status,
      bucket: conn.assigns[:s3_bucket],
      key: conn.assigns[:s3_key]
    )

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, body)
    |> halt()
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp assign_prepared_metrics(conn, prepared) do
    conn
    |> assign(:s3_key, prepared.key)
    |> assign(:s3_level, :object)
    |> assign(:s3_metrics_tags, tags_from_headers(prepared.object_headers))
  end

  defp tags_from_headers(headers) do
    case header_value(headers, "x-amz-tagging") do
      nil ->
        %{}

      "" ->
        %{}

      raw ->
        with {:ok, tags} <- Maxio.Tags.parse_header(raw),
             :ok <- Maxio.Tags.validate(tags, :object) do
          Maxio.Tags.list_to_map(tags)
        else
          _other -> %{}
        end
    end
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {header_name, value} ->
      if String.downcase(header_name) == name, do: value
    end)
  end
end
