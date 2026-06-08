defmodule Maxio.S3.Views.ListBucket do
  @moduledoc "ListObjectsV2 响应 XML（ListBucketResult）。NextContinuationToken 仅截断时出现；CommonPrefixes 仅有 delimiter 时出现。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(map()) :: iodata()
  def render(data) do
    children =
      [
        element("Name", [], characters(data.name)),
        element("Prefix", [], characters(data.prefix || "")),
        element("KeyCount", [], characters(Integer.to_string(data.key_count))),
        element("MaxKeys", [], characters(Integer.to_string(data.max_keys))),
        element("IsTruncated", [], characters(to_string(data.is_truncated)))
      ]
      |> maybe(data.delimiter, fn d -> element("Delimiter", [], characters(d)) end)
      |> maybe(data.is_truncated && data.next_continuation_token, fn t ->
        element("NextContinuationToken", [], characters(t))
      end)
      |> maybe(data[:start_after], fn s -> element("StartAfter", [], characters(s)) end)

    contents = Enum.map(data.objects, &content_elem/1)

    common =
      Enum.map(data.common_prefixes, fn cp ->
        element("CommonPrefixes", [], [element("Prefix", [], characters(cp))])
      end)

    root = element("ListBucketResult", [{"xmlns", XML.namespace()}], children ++ contents ++ common)
    XML.encode(root)
  end

  defp content_elem(obj) do
    element("Contents", [], [
      element("Key", [], characters(obj.key)),
      element("LastModified", [], characters(XML.iso8601(obj.last_modified))),
      element("ETag", [], characters(XML.quote_etag(obj.etag))),
      element("Size", [], characters(Integer.to_string(obj.size))),
      element("StorageClass", [], characters("STANDARD"))
    ])
  end

  defp maybe(children, falsy, _fun) when falsy in [nil, false, ""], do: children
  defp maybe(children, value, fun), do: children ++ [fun.(value)]
end
