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
      |> maybe(data[:start_after], fn s ->
        element("StartAfter", [], characters(encode(s, enc)))
      end)

    contents = Enum.map(data.objects, &content_elem(&1, enc))

    common =
      Enum.map(data.common_prefixes, fn cp ->
        element("CommonPrefixes", [], [element("Prefix", [], characters(encode(cp, enc)))])
      end)

    root =
      element("ListBucketResult", [{"xmlns", XML.namespace()}], children ++ contents ++ common)

    XML.encode(root)
  end

  # 富字段（LastModified/ETag/Size）缺失时用 S3-valid 兜底，绝不让 nil 把 XML 渲染炸成 500
  # （铁律 3）：drive-walk 列举源在盘上无对应 sidecar meta 时这些字段可能为 nil——此时按
  # AWS 语义给安全默认（LastModified=当前时刻、ETag 空引号、Size=0），返回合法 ListObjectsV2 XML。
  defp content_elem(obj, enc) do
    element("Contents", [], [
      element("Key", [], characters(encode(obj.key, enc))),
      element("LastModified", [], characters(XML.iso8601(last_modified(obj)))),
      element("ETag", [], characters(XML.quote_etag(etag(obj)))),
      element("Size", [], characters(Integer.to_string(size(obj)))),
      element("StorageClass", [], characters("STANDARD"))
    ])
  end

  defp last_modified(%{last_modified: %DateTime{} = dt}), do: dt
  defp last_modified(_), do: DateTime.utc_now()

  defp etag(%{etag: e}) when is_binary(e), do: e
  defp etag(_), do: ""

  defp size(%{size: s}) when is_integer(s), do: s
  defp size(_), do: 0

  # encoding-type=url → MinIO s3URLEncode（保留字面 '/' 与 '*'，空格→'+'，其余字节→%XX 大写）。
  # 用 Maxio.S3.URLEncode（与 SigV4 的 RFC3986 编码不同：S3 list 编码不转义 '/'，故 delimiter /
  # CommonPrefixes 的伪目录语义不被破坏，对齐 AWS/MinIO 线上字节，铁律 5）。
  defp encode(value, "url") when is_binary(value), do: Maxio.S3.URLEncode.encode(value)

  defp encode(value, _enc), do: value

  defp encoding_type_value("url"), do: "url"
  defp encoding_type_value(_), do: nil

  defp maybe(children, falsy, _fun) when falsy in [nil, false, ""], do: children
  defp maybe(children, value, fun), do: children ++ [fun.(value)]
end
