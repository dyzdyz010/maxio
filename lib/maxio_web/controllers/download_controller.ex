defmodule MaxioWeb.DownloadController do
  @moduledoc """
  Streams Console object downloads and inline previews without buffering object bytes.

  The `*key` route segment is received as a path segment list. `versionId=` can
  select a specific object version.
  """
  use MaxioWeb, :controller

  alias Maxio.{Objects, Storage}
  alias Maxio.Cluster.Placement
  alias Maxio.Objects.Object
  alias Maxio.S3.Log
  alias MaxioWeb.ObjectPreview

  def show(conn, %{"bucket" => bucket, "key" => key_segments} = params) do
    send_object(conn, bucket, key_segments, params, :attachment)
  end

  def preview(conn, %{"bucket" => bucket, "key" => key_segments} = params) do
    send_object(conn, bucket, key_segments, params, :inline)
  end

  defp send_object(conn, bucket, key_segments, params, disposition) do
    key = Enum.join(key_segments, "/")
    version_id = Map.get(params, "versionId")

    with {:ok, %Object{is_delete_marker: false} = object} <- fetch_object(bucket, key, version_id),
         :ok <- ensure_previewable(disposition, object),
         {:ok, stream} <- storage_stream(bucket, key, object, disposition) do
      conn
      |> put_resp_content_type(object.content_type || "application/octet-stream")
      |> put_resp_header("content-disposition", content_disposition(disposition, key))
      |> put_preview_security_headers(disposition)
      |> send_chunked(200)
      |> stream_object(stream)
    else
      {:error, :preview_not_supported} ->
        conn
        |> put_status(:unsupported_media_type)
        |> put_resp_header("x-content-type-options", "nosniff")
        |> text("Preview Not Supported")

      {:error, :storage_read_failed} ->
        conn
        |> put_status(:internal_server_error)
        |> put_resp_header("x-content-type-options", "nosniff")
        |> text("Storage Read Failed")

      _ ->
        conn
        |> put_status(:not_found)
        |> text("Not Found")
    end
  end

  defp fetch_object(bucket, key, nil), do: Objects.get_metadata(bucket, key)
  defp fetch_object(bucket, key, version_id), do: Objects.get_version(bucket, key, version_id)

  defp ensure_previewable(:attachment, _object), do: :ok

  defp ensure_previewable(:inline, object) do
    if ObjectPreview.previewable?(object), do: :ok, else: {:error, :preview_not_supported}
  end

  defp storage_stream(bucket, key, object, disposition) do
    case Storage.get(bucket, key, object.version_id, nil, Placement.storage_opts(object)) do
      {:ok, stream} ->
        {:ok, stream}

      {:error, reason} ->
        Log.error("console object stream failed",
          action: stream_action(disposition),
          bucket: bucket,
          key: key,
          version_id: object.version_id,
          reason: inspect(reason)
        )

        {:error, :storage_read_failed}
    end
  end

  defp stream_action(:attachment), do: :console_object_download
  defp stream_action(:inline), do: :console_object_preview

  defp content_disposition(disposition, key) do
    filename =
      key
      |> Path.basename()
      |> String.replace(~r/["\r\n]/, "")

    ~s(#{disposition}; filename="#{filename}")
  end

  defp put_preview_security_headers(conn, :inline) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "sandbox")
  end

  defp put_preview_security_headers(conn, :attachment), do: conn

  defp stream_object(conn, stream) do
    Enum.reduce_while(stream, conn, fn data, acc ->
      case chunk(acc, data) do
        {:ok, acc2} -> {:cont, acc2}
        {:error, :closed} -> {:halt, acc}
      end
    end)
  end
end
