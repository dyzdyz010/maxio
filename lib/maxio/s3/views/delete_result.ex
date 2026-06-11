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

  @type error_entry :: %{
          required(:key) => String.t(),
          required(:code) => String.t(),
          required(:message) => String.t(),
          optional(:version_id) => String.t() | nil
        }

  @spec render(%{deleted: [deleted_entry()], errors: [error_entry()]}) :: iodata()
  def render(%{deleted: deleted, errors: errors}) do
    deleted_elems = Enum.map(deleted, &deleted_elem/1)

    # B6-2a：<Error> 条目按 AWS DeleteObjects Response Syntax 携带 Key/VersionId/Code/Message
    # （API_DeleteObjects：Error = Code, Key, Message, VersionId；元素集对齐）。请求里给了
    # per-key VersionId 就回显（MinIO DeleteError 同样原样回显 object.VersionID）；未给（nil）
    # 不渲染。镜像 MinIO：畸形 versionId 的 NoSuchVersion 条目必须携 <VersionId>，否则 SDK
    # 无法把错误归因到具体版本。
    error_elems =
      Enum.map(errors, fn e ->
        children =
          [element("Key", [], characters(e.key))]
          |> error_version_id(Map.get(e, :version_id))
          |> Kernel.++([
            element("Code", [], characters(e.code)),
            element("Message", [], characters(e.message))
          ])

        element("Error", [], children)
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

  # <Error> 的 VersionId：请求 per-key 给了就回显（含畸形串原样回显，MinIO DeleteError 语义）；
  # 未给（nil）不渲染。与 Deleted 的 maybe_version_id 不同：Error 回显的是**请求输入**，
  # "null" 也原样回显（MinIO 不对 error 条目做 null 折叠）。
  defp error_version_id(children, nil), do: children

  defp error_version_id(children, vid),
    do: children ++ [element("VersionId", [], characters(vid))]

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
