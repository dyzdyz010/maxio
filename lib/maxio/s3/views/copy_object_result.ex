defmodule Maxio.S3.Views.CopyObjectResult do
  @moduledoc "CopyObject 响应 XML（CopyObjectResult）。ETag 含引号，LastModified ISO8601。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{
          required(:etag) => String.t(),
          required(:last_modified) => DateTime.t(),
          optional(:checksum) => map()
        }) ::
          iodata()
  def render(%{etag: etag, last_modified: lm} = attrs) do
    checksum = Map.get(attrs, :checksum, %{})

    root =
      element(
        "CopyObjectResult",
        [{"xmlns", XML.namespace()}],
        [
          element("ETag", [], characters(XML.quote_etag(etag))),
          element("LastModified", [], characters(XML.iso8601(lm)))
        ] ++ checksum_children(checksum)
      )

    XML.encode(root)
  end

  defp checksum_children(checksum) when is_map(checksum) do
    []
    |> maybe_checksum_field(checksum, "ChecksumType")
    |> maybe_checksum_field(checksum, "ChecksumCRC32")
    |> maybe_checksum_field(checksum, "ChecksumCRC32C")
    |> maybe_checksum_field(checksum, "ChecksumCRC64NVME")
    |> maybe_checksum_field(checksum, "ChecksumSHA1")
    |> maybe_checksum_field(checksum, "ChecksumSHA256")
    |> maybe_checksum_field(checksum, "ChecksumSHA512")
    |> maybe_checksum_field(checksum, "ChecksumMD5")
    |> maybe_checksum_field(checksum, "ChecksumXXHASH64")
    |> maybe_checksum_field(checksum, "ChecksumXXHASH3")
    |> maybe_checksum_field(checksum, "ChecksumXXHASH128")
    |> Enum.reverse()
  end

  defp maybe_checksum_field(children, checksum, name) do
    case Map.get(checksum, name) do
      value when is_binary(value) and value != "" ->
        [element(name, [], characters(value)) | children]

      _ ->
        children
    end
  end
end
