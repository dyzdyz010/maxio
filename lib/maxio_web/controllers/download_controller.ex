defmodule MaxioWeb.DownloadController do
  @moduledoc """
  Console 对象下载（plain controller，非 LiveView）。复用 Maxio.S3.Handlers.Object 同构的
  send_chunked + Enum.reduce_while 流式（绝不全缓冲，铁律 4）。
  *key 通配段是路径数组；?versionId= 可指定版本。
  """
  use MaxioWeb, :controller

  alias Maxio.{Objects, Storage}
  alias Maxio.Cluster.Placement
  alias Maxio.Objects.Object

  def show(conn, %{"bucket" => bucket, "key" => key_segments} = params) do
    key = Enum.join(key_segments, "/")
    version_id = Map.get(params, "versionId")

    fetch =
      if version_id,
        do: Objects.get_version(bucket, key, version_id),
        else: Objects.get_metadata(bucket, key)

    case fetch do
      {:ok, %Object{is_delete_marker: false} = object} ->
        {:ok, stream} =
          Storage.get(bucket, key, object.version_id, nil, Placement.storage_opts(object))

        filename = Path.basename(key)

        conn
        |> put_resp_content_type(object.content_type || "application/octet-stream")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_chunked(200)
        |> stream_object(stream)

      _ ->
        conn
        |> put_status(:not_found)
        |> text("Not Found")
    end
  end

  # 逐块 chunk；客户端断开（{:error, :closed}）则优雅 halt。
  defp stream_object(conn, stream) do
    Enum.reduce_while(stream, conn, fn data, acc ->
      case chunk(acc, data) do
        {:ok, acc2} -> {:cont, acc2}
        {:error, :closed} -> {:halt, acc}
      end
    end)
  end
end
