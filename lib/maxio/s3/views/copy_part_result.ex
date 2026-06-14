defmodule Maxio.S3.Views.CopyPartResult do
  @moduledoc "UploadPartCopy response XML (CopyPartResult)."
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{etag: String.t(), last_modified: DateTime.t()}) :: iodata()
  def render(%{etag: etag, last_modified: last_modified}) do
    root =
      element("CopyPartResult", [{"xmlns", XML.namespace()}], [
        element("LastModified", [], characters(XML.iso8601(last_modified))),
        element("ETag", [], characters(XML.quote_etag(etag)))
      ])

    XML.encode(root)
  end
end
