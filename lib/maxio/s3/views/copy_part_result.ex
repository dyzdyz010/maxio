defmodule Maxio.S3.Views.CopyPartResult do
  @moduledoc "UploadPartCopy response XML (CopyPartResult)."
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{
          required(:etag) => String.t(),
          required(:last_modified) => DateTime.t(),
          optional(:checksum) => map()
        }) :: iodata()
  def render(%{etag: etag, last_modified: last_modified} = attrs) do
    checksum = Map.get(attrs, :checksum, %{})

    root =
      element(
        "CopyPartResult",
        [{"xmlns", XML.namespace()}],
        [
          element("LastModified", [], characters(XML.iso8601(last_modified))),
          element("ETag", [], characters(XML.quote_etag(etag)))
        ] ++ checksum_children(checksum)
      )

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
