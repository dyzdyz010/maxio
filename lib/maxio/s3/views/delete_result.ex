defmodule Maxio.S3.Views.DeleteResult do
  @moduledoc """
  DeleteObjects 响应 XML（DeleteResult）。verbose 含每个 Deleted；quiet 仅 Error。
  每个 Deleted 可携带 version_id / delete_marker / delete_marker_version_id（版本化语义，
  对齐 AWS DeleteObjects Response Syntax: DeletedObject = Key, VersionId, DeleteMarker,
  DeleteMarkerVersionId）。version_id == "null" 不渲染 <VersionId>（对齐 AWS 不回显 null 版本）。
  """
  import Saxy.XML
  alias Maxio.S3.XML

  @type deleted_entry :: %{
          required(:key) => String.t(),
          optional(:version_id) => String.t() | nil,
          optional(:delete_marker) => boolean(),
          optional(:delete_marker_version_id) => String.t() | nil
        }

  @spec render(%{
          deleted: [deleted_entry()],
          errors: [%{key: String.t(), code: String.t(), message: String.t()}]
        }) :: iodata()
  def render(%{deleted: deleted, errors: errors}) do
    deleted_elems = Enum.map(deleted, &deleted_elem/1)

    error_elems =
      Enum.map(errors, fn e ->
        element("Error", [], [
          element("Key", [], characters(e.key)),
          element("Code", [], characters(e.code)),
          element("Message", [], characters(e.message))
        ])
      end)

    root = element("DeleteResult", [{"xmlns", XML.namespace()}], deleted_elems ++ error_elems)
    XML.encode(root)
  end

  defp deleted_elem(entry) do
    children =
      [element("Key", [], characters(entry.key))]
      |> maybe_version_id(Map.get(entry, :version_id))
      |> maybe_delete_marker(Map.get(entry, :delete_marker, false))
      |> maybe_delete_marker_version_id(Map.get(entry, :delete_marker_version_id))

    element("Deleted", [], children)
  end

  # 永久删指定版本时回 <VersionId>；"null"/nil 不渲染（对齐 AWS）。
  defp maybe_version_id(children, nil), do: children
  defp maybe_version_id(children, "null"), do: children

  defp maybe_version_id(children, vid),
    do: children ++ [element("VersionId", [], characters(vid))]

  defp maybe_delete_marker(children, true),
    do: children ++ [element("DeleteMarker", [], characters("true"))]

  defp maybe_delete_marker(children, _), do: children

  defp maybe_delete_marker_version_id(children, nil), do: children
  defp maybe_delete_marker_version_id(children, "null"), do: children

  defp maybe_delete_marker_version_id(children, vid),
    do: children ++ [element("DeleteMarkerVersionId", [], characters(vid))]
end
