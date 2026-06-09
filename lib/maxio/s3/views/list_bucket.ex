defmodule Maxio.S3.Views.ListBucket do
  @moduledoc """
  ListObjectsV2 响应 XML（ListBucketResult）。NextContinuationToken 仅截断时出现；
  CommonPrefixes 仅有 delimiter 时出现。encoding-type=url 时对 Key/Prefix/Delimiter/StartAfter/
  CommonPrefixes 做 percent-encode 并发 <EncodingType>url</EncodingType>（对齐 AWS：使含 XML 1.0
  非法字节的 key 可被客户端正确 URL-decode 还原，铁律 5）。
  """
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(map()) :: iodata()
  def render(data) do
    enc = Map.get(data, :encoding_type)

    children =
      [
        element("Name", [], characters(data.name)),
        element("Prefix", [], characters(encode(data.prefix || "", enc))),
        element("KeyCount", [], characters(Integer.to_string(data.key_count))),
        element("MaxKeys", [], characters(Integer.to_string(data.max_keys))),
        element("IsTruncated", [], characters(to_string(data.is_truncated)))
      ]
      |> maybe(encoding_type_value(enc), fn e -> element("EncodingType", [], characters(e)) end)
      |> maybe(data.delimiter, fn d -> element("Delimiter", [], characters(encode(d, enc))) end)
      |> maybe(data.is_truncated && data.next_continuation_token, fn t ->
        element("NextContinuationToken", [], characters(t))
      end)
      |> maybe(data[:start_after], fn s -> element("StartAfter", [], characters(encode(s, enc))) end)

    contents = Enum.map(data.objects, &content_elem(&1, enc))

    common =
      Enum.map(data.common_prefixes, fn cp ->
        element("CommonPrefixes", [], [element("Prefix", [], characters(encode(cp, enc)))])
      end)

    root =
      element("ListBucketResult", [{"xmlns", XML.namespace()}], children ++ contents ++ common)

    XML.encode(root)
  end

  defp content_elem(obj, enc) do
    element("Contents", [], [
      element("Key", [], characters(encode(obj.key, enc))),
      element("LastModified", [], characters(XML.iso8601(obj.last_modified))),
      element("ETag", [], characters(XML.quote_etag(obj.etag))),
      element("Size", [], characters(Integer.to_string(obj.size))),
      element("StorageClass", [], characters("STANDARD"))
    ])
  end

  # encoding-type=url → S3 风格 URL 编码（query 模式：A-Za-z0-9-_.~ 原样，'/' 编为 %2F，空格 %20）。
  # 复用 Canonical.uri_encode/2 的 query 模式（与 SigV4 同一 UriEncode，铁律 5 一致性）。
  defp encode(value, "url") when is_binary(value),
    do: Maxio.Auth.SigV4.Canonical.uri_encode(value, :query)

  defp encode(value, _enc), do: value

  defp encoding_type_value("url"), do: "url"
  defp encoding_type_value(_), do: nil

  defp maybe(children, falsy, _fun) when falsy in [nil, false, ""], do: children
  defp maybe(children, value, fun), do: children ++ [fun.(value)]
end
