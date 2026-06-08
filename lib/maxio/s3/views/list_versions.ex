defmodule Maxio.S3.Views.ListVersions do
  @moduledoc """
  ListObjectVersions 响应 XML（ListVersionsResult）。Version 与 DeleteMarker 交错（按入参顺序，
  调用方已按 key 升序、key 内 newest-first 排好）。delete marker 无 ETag/Size/StorageClass（官方核验）。
  NextKeyMarker/NextVersionIdMarker 仅截断时出现；CommonPrefixes 仅有 delimiter 时。
  owner_id/owner_display 用合成 "maxio"。
  """
  import Saxy.XML
  alias Maxio.S3.XML

  @owner_id "maxio"
  @owner_display "maxio"

  @spec render(map()) :: iodata()
  def render(data) do
    head =
      [
        element("Name", [], characters(data.name)),
        element("Prefix", [], characters(data.prefix || "")),
        element("KeyMarker", [], characters(data.key_marker || "")),
        element("VersionIdMarker", [], characters(data.version_id_marker || "")),
        element("MaxKeys", [], characters(Integer.to_string(data.max_keys))),
        element("IsTruncated", [], characters(to_string(data.is_truncated)))
      ]
      |> maybe(data.is_truncated && data.next_key_marker, fn t -> element("NextKeyMarker", [], characters(t)) end)
      |> maybe(data.is_truncated && data.next_version_id_marker, fn t ->
        element("NextVersionIdMarker", [], characters(t))
      end)
      |> maybe(data.delimiter, fn d -> element("Delimiter", [], characters(d)) end)

    entries = Enum.map(data.versions, &version_or_marker/1)

    common =
      Enum.map(data.common_prefixes, fn cp ->
        element("CommonPrefixes", [], [element("Prefix", [], characters(cp))])
      end)

    root = element("ListVersionsResult", [{"xmlns", XML.namespace()}], head ++ entries ++ common)
    XML.encode(root)
  end

  # version 行（含 is_delete_marker）→ <Version> 或 <DeleteMarker>。
  defp version_or_marker(%{is_delete_marker: true} = o) do
    element("DeleteMarker", [], [
      element("Key", [], characters(o.key)),
      element("VersionId", [], characters(o.version_id)),
      element("IsLatest", [], characters(to_string(o.is_latest))),
      element("LastModified", [], characters(XML.iso8601(o.updated_at))),
      owner()
    ])
  end

  defp version_or_marker(o) do
    element("Version", [], [
      element("Key", [], characters(o.key)),
      element("VersionId", [], characters(o.version_id)),
      element("IsLatest", [], characters(to_string(o.is_latest))),
      element("LastModified", [], characters(XML.iso8601(o.updated_at))),
      element("ETag", [], characters(XML.quote_etag(o.etag))),
      element("Size", [], characters(Integer.to_string(o.size))),
      element("StorageClass", [], characters(o.storage_class || "STANDARD")),
      owner()
    ])
  end

  defp owner do
    element("Owner", [], [
      element("ID", [], characters(@owner_id)),
      element("DisplayName", [], characters(@owner_display))
    ])
  end

  defp maybe(children, falsy, _fun) when falsy in [nil, false, ""], do: children
  defp maybe(children, value, fun), do: children ++ [fun.(value)]
end
