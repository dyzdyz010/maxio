defmodule Maxio.S3.Views.InitiateMultipartUpload do
  @moduledoc "CreateMultipartUpload 响应 XML（InitiateMultipartUploadResult）。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{bucket: String.t(), key: String.t(), upload_id: String.t()}) :: iodata()
  def render(%{bucket: bucket, key: key, upload_id: upload_id}) do
    root =
      element("InitiateMultipartUploadResult", [{"xmlns", XML.namespace()}], [
        element("Bucket", [], characters(bucket)),
        element("Key", [], characters(key)),
        element("UploadId", [], characters(upload_id))
      ])

    XML.encode(root)
  end
end
