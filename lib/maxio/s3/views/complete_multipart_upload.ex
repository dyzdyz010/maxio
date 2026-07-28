defmodule Maxio.S3.Views.CompleteMultipartUpload do
  @moduledoc "CompleteMultipartUpload response XML."
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{
          required(:location) => String.t(),
          required(:bucket) => String.t(),
          required(:key) => String.t(),
          required(:etag) => String.t(),
          optional(:checksum) => map()
        }) :: iodata()
  def render(%{location: location, bucket: bucket, key: key, etag: etag} = attrs) do
    checksum = Map.get(attrs, :checksum, %{})

    root =
      element(
        "CompleteMultipartUploadResult",
        [{"xmlns", XML.namespace()}],
        [
          element("Location", [], characters(location)),
          element("Bucket", [], characters(bucket)),
          element("Key", [], characters(key)),
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
    |> maybe_checksum_field(checksum, "ChecksumSHA1")
    |> maybe_checksum_field(checksum, "ChecksumSHA256")
    |> maybe_checksum_field(checksum, "ChecksumSHA512")
    |> maybe_checksum_field(checksum, "ChecksumMD5")
    |> maybe_checksum_field(checksum, "ChecksumXXHASH64")
    |> maybe_checksum_field(checksum, "ChecksumXXHASH3")
    |> maybe_checksum_field(checksum, "ChecksumXXHASH128")
    |> maybe_checksum_field(checksum, "ChecksumType")
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
