defmodule Maxio.S3.Views.ListParts do
  @moduledoc "ListParts 响应 XML（ListPartsResult）。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(map()) :: iodata()
  def render(data) do
    part_elems =
      Enum.map(data.parts, fn p ->
        children =
          [
            element("PartNumber", [], characters(Integer.to_string(p.part_number))),
            element("LastModified", [], characters(XML.iso8601(p.last_modified))),
            element("ETag", [], characters(XML.quote_etag(p.etag))),
            element("Size", [], characters(Integer.to_string(p.size)))
          ] ++ checksum_children(Map.get(p, :checksum, %{}))

        element("Part", [], children)
      end)

    children =
      [
        element("Bucket", [], characters(data.bucket)),
        element("Key", [], characters(data.key)),
        element("UploadId", [], characters(data.upload_id)),
        element("PartNumberMarker", [], characters(Integer.to_string(data.part_number_marker))),
        element(
          "NextPartNumberMarker",
          [],
          characters(Integer.to_string(data.next_part_number_marker || 0))
        ),
        element("MaxParts", [], characters(Integer.to_string(data.max_parts))),
        element("IsTruncated", [], characters(to_string(data.is_truncated))),
        element("Initiator", [], [
          element("ID", [], characters(data.owner_id)),
          element("DisplayName", [], characters(data.owner_display))
        ]),
        element("Owner", [], [
          element("ID", [], characters(data.owner_id)),
          element("DisplayName", [], characters(data.owner_display))
        ]),
        element("StorageClass", [], characters(data.storage_class))
      ] ++ part_elems

    root = element("ListPartsResult", [{"xmlns", XML.namespace()}], children)
    XML.encode(root)
  end

  defp checksum_children(checksum) when is_map(checksum) do
    []
    |> maybe_checksum_field(checksum, "ChecksumCRC32")
    |> maybe_checksum_field(checksum, "ChecksumCRC32C")
    |> maybe_checksum_field(checksum, "ChecksumCRC64NVME")
    |> maybe_checksum_field(checksum, "ChecksumMD5")
    |> maybe_checksum_field(checksum, "ChecksumSHA1")
    |> maybe_checksum_field(checksum, "ChecksumSHA256")
    |> maybe_checksum_field(checksum, "ChecksumSHA512")
    |> maybe_checksum_field(checksum, "ChecksumXXHASH128")
    |> maybe_checksum_field(checksum, "ChecksumXXHASH3")
    |> maybe_checksum_field(checksum, "ChecksumXXHASH64")
  end

  defp maybe_checksum_field(children, checksum, name) do
    case Map.get(checksum, name) do
      value when is_binary(value) and value != "" ->
        children ++ [element(name, [], characters(value))]

      _ ->
        children
    end
  end
end
