defmodule Maxio.S3.Views.CopyObjectResult do
  @moduledoc "CopyObject 响应 XML（CopyObjectResult）。ETag 含引号，LastModified ISO8601。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{etag: String.t(), last_modified: DateTime.t()}) :: iodata()
  def render(%{etag: etag, last_modified: lm}) do
    root =
      element("CopyObjectResult", [{"xmlns", XML.namespace()}], [
        element("LastModified", [], characters(XML.iso8601(lm))),
        element("ETag", [], characters(XML.quote_etag(etag)))
      ])

    XML.encode(root)
  end
end
