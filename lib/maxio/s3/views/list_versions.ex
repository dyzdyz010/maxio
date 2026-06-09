defmodule Maxio.S3.Views.ListVersions do
  @moduledoc """
  ListObjectVersions 响应 XML（ListVersionsResult）。Version 与 DeleteMarker 交错（按入参顺序，
  调用方已按 key 升序、key 内 newest-first 排好）。delete marker 无 ETag/Size/StorageClass。
  NextKeyMarker/NextVersionIdMarker 仅截断时出现；CommonPrefixes 仅有 delimiter 时。
  encoding-type=url 时对 Key/Prefix/KeyMarker/NextKeyMarker/Delimiter/CommonPrefixes percent-encode
  并发 <EncodingType>url</EncodingType>（对齐 AWS，铁律 5）。owner_id/owner_display 用合成 "maxio"。
  """
  import Saxy.XML
  alias Maxio.S3.XML

  @owner_id "maxio"
  @owner_display "maxio"

  @spec render(map()) :: iodata()
  def render(data) do
    enc = Map.get(data, :encoding_type)

    head =
      [
        element("Name", [], characters(data.name)),
        element("Prefix", [], characters(encode(data.prefix || "", enc))),
        element("KeyMarker", [], characters(encode(data.key_marker || "", enc))),
        element("VersionIdMarker", [], characters(data.version_id_marker || "")),
        element("MaxKeys", [], characters(Integer.to_string(data.max_keys))),
        element("IsTruncated", [], characters(to_string(data.is_truncated)))
      ]
      |> maybe(encoding_type_value(enc), fn e -> element("EncodingType", [], characters(e)) end)
      |> maybe(data.is_truncated && data.next_key_marker, fn t ->
        element("NextKeyMarker", [], characters(encode(t, enc)))
      end)
      |> maybe(data.is_truncated && data.next_version_id_marker, fn t ->
        element("NextVersionIdMarker", [], characters(t))
      end)
      |> maybe(data.delimiter, fn d -> element("Delimiter", [], characters(encode(d, enc))) end)

    entries = Enum.map(data.versions, &version_or_marker(&1, enc))

    common =
      Enum.map(data.common_prefixes, fn cp ->
        element("CommonPrefixes", [], [element("Prefix", [], characters(encode(cp, enc)))])
      end)

    root = element("ListVersionsResult", [{"xmlns", XML.namespace()}], head ++ entries ++ common)
    XML.encode(root)
  end

  # version 行（含 is_delete_marker）→ <Version> 或 <DeleteMarker>。
  defp version_or_marker(%{is_delete_marker: true} = o, enc) do
    element("DeleteMarker", [], [
      element("Key", [], characters(encode(o.key, enc))),
      element("VersionId", [], characters(o.version_id)),
      element("IsLatest", [], characters(to_string(o.is_latest))),
      element("LastModified", [], characters(XML.iso8601(o.updated_at))),
      owner()
    ])
  end

  defp version_or_marker(o, enc) do
    element("Version", [], [
      element("Key", [], characters(encode(o.key, enc))),
      element("VersionId", [], characters(o.version_id)),
      element("IsLatest", [], characters(to_string(o.is_latest))),
      element("LastModified", [], characters(XML.iso8601(o.updated_at))),
      element("ETag", [], characters(XML.quote_etag(o.etag))),
      element("Size", [], characters(Integer.to_string(o.size))),
      element("StorageClass", [], characters(o.storage_class || "STANDARD")),
      owner()
    ])
  end

  defp owner do
    element("Owner", [], [
      element("ID", [], characters(@owner_id)),
      element("DisplayName", [], characters(@owner_display))
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
