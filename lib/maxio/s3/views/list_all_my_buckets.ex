defmodule Maxio.S3.Views.ListAllMyBuckets do
  @moduledoc "ListBuckets 响应 XML（ListAllMyBucketsResult）。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{owner: %{id: String.t(), display_name: String.t()}, buckets: [map()]}) :: iodata()
  def render(%{owner: owner, buckets: buckets}) do
    bucket_elems =
      Enum.map(buckets, fn b ->
        element("Bucket", [], [
          element("Name", [], characters(b.name)),
          element("CreationDate", [], characters(XML.iso8601(b.creation_date)))
        ])
      end)

    root =
      element("ListAllMyBucketsResult", [{"xmlns", XML.namespace()}], [
        element("Owner", [], [
          element("ID", [], characters(owner.id)),
          element("DisplayName", [], characters(owner.display_name))
        ]),
        element("Buckets", [], bucket_elems)
      ])

    XML.encode(root)
  end
end
