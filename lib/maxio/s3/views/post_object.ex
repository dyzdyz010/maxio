defmodule Maxio.S3.Views.PostObject do
  @moduledoc "POST Object 201 response XML."
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{
          required(:location) => String.t(),
          required(:bucket) => String.t(),
          required(:key) => String.t(),
          required(:etag) => String.t()
        }) :: iodata()
  def render(%{location: location, bucket: bucket, key: key, etag: etag}) do
    root =
      element(
        "PostResponse",
        [{"xmlns", XML.namespace()}],
        [
          element("Location", [], characters(location)),
          element("Bucket", [], characters(bucket)),
          element("Key", [], characters(key)),
          element("ETag", [], characters(XML.quote_etag(etag)))
        ]
      )

    XML.encode(root)
  end
end
