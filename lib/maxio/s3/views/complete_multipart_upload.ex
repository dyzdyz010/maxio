defmodule Maxio.S3.Views.CompleteMultipartUpload do
  @moduledoc "CompleteMultipartUpload 响应 XML（CompleteMultipartUploadResult）。Location/Bucket/Key/ETag。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{location: String.t(), bucket: String.t(), key: String.t(), etag: String.t()}) ::
          iodata()
  def render(%{location: location, bucket: bucket, key: key, etag: etag}) do
    root =
      element("CompleteMultipartUploadResult", [{"xmlns", XML.namespace()}], [
        element("Location", [], characters(location)),
        element("Bucket", [], characters(bucket)),
        element("Key", [], characters(key)),
        element("ETag", [], characters(XML.quote_etag(etag)))
      ])

    XML.encode(root)
  end
end
