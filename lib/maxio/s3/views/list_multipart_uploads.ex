defmodule Maxio.S3.Views.ListMultipartUploads do
  @moduledoc "ListMultipartUploads 响应 XML（ListMultipartUploadsResult）。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(map()) :: iodata()
  def render(data) do
    upload_elems =
      Enum.map(data.uploads, fn u ->
        element("Upload", [], [
          element("Key", [], characters(u.key)),
          element("UploadId", [], characters(u.upload_id)),
          element("Initiator", [], [
            element("ID", [], characters(data.owner_id)),
            element("DisplayName", [], characters(data.owner_display))
          ]),
          element("Owner", [], [
            element("ID", [], characters(data.owner_id)),
            element("DisplayName", [], characters(data.owner_display))
          ]),
          element("StorageClass", [], characters(u.storage_class)),
          element("Initiated", [], characters(XML.iso8601(u.initiated)))
        ])
      end)

    common =
      Enum.map(data.common_prefixes, fn cp ->
        element("CommonPrefixes", [], [element("Prefix", [], characters(cp))])
      end)

    children =
      [
        element("Bucket", [], characters(data.bucket)),
        element("KeyMarker", [], characters(data.key_marker || "")),
        element("UploadIdMarker", [], characters(data.upload_id_marker || "")),
        element("NextKeyMarker", [], characters(data.next_key_marker || "")),
        element("NextUploadIdMarker", [], characters(data.next_upload_id_marker || "")),
        element("MaxUploads", [], characters(Integer.to_string(data.max_uploads))),
        element("IsTruncated", [], characters(to_string(data.is_truncated))),
        element("Prefix", [], characters(data.prefix || ""))
      ]
      |> maybe_delimiter(data.delimiter)

    root =
      element(
        "ListMultipartUploadsResult",
        [{"xmlns", XML.namespace()}],
        children ++ upload_elems ++ common
      )

    XML.encode(root)
  end

  defp maybe_delimiter(children, nil), do: children
  defp maybe_delimiter(children, ""), do: children
  defp maybe_delimiter(children, d), do: children ++ [element("Delimiter", [], characters(d))]
end
