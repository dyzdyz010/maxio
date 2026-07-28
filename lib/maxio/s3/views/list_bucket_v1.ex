defmodule Maxio.S3.Views.ListBucketV1 do
  @moduledoc "ListObjects V1 response XML."
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(map()) :: iodata()
  def render(data) do
    enc = Map.get(data, :encoding_type)

    children =
      [
        element("Name", [], characters(data.name)),
        element("Prefix", [], characters(encode(data.prefix || "", enc))),
        element("Marker", [], characters(encode(data.marker || "", enc))),
        element("MaxKeys", [], characters(Integer.to_string(data.max_keys))),
        element("IsTruncated", [], characters(to_string(data.is_truncated)))
      ]
      |> maybe(encoding_type_value(enc), fn e -> element("EncodingType", [], characters(e)) end)
      |> maybe(data.delimiter, fn d -> element("Delimiter", [], characters(encode(d, enc))) end)
      |> maybe(data.next_marker, fn m -> element("NextMarker", [], characters(encode(m, enc))) end)

    contents =
      Enum.map(
        data.objects,
        &content_elem(&1, enc, Map.get(data, :include_restore_status?, false))
      )

    common =
      Enum.map(data.common_prefixes, fn cp ->
        element("CommonPrefixes", [], [element("Prefix", [], characters(encode(cp, enc)))])
      end)

    root =
      element("ListBucketResult", [{"xmlns", XML.namespace()}], children ++ contents ++ common)

    XML.encode(root)
  end

  defp content_elem(obj, enc, include_restore_status?) do
    children =
      [
        element("Key", [], characters(encode(obj.key, enc))),
        element("LastModified", [], characters(XML.iso8601(last_modified(obj)))),
        element("ETag", [], characters(XML.quote_etag(etag(obj)))),
        element("Size", [], characters(Integer.to_string(size(obj)))),
        element("StorageClass", [], characters(storage_class(obj)))
      ]
      |> maybe_restore_status(obj, include_restore_status?)

    element("Contents", [], children)
  end

  defp last_modified(%{last_modified: %DateTime{} = dt}), do: dt
  defp last_modified(_), do: DateTime.utc_now()

  defp etag(%{etag: e}) when is_binary(e), do: e
  defp etag(_), do: ""

  defp size(%{size: s}) when is_integer(s), do: s
  defp size(_), do: 0

  defp storage_class(%{storage_class: s}) when is_binary(s) and s != "", do: s
  defp storage_class(_), do: "STANDARD"

  defp maybe_restore_status(children, _obj, false), do: children

  defp maybe_restore_status(children, %{restore_status: "ongoing"}, true) do
    children ++
      [
        element("RestoreStatus", [], [
          element("IsRestoreInProgress", [], characters("true"))
        ])
      ]
  end

  defp maybe_restore_status(
         children,
         %{restore_status: "restored", restore_expiry: %DateTime{} = dt},
         true
       ) do
    children ++
      [
        element("RestoreStatus", [], [
          element("IsRestoreInProgress", [], characters("false")),
          element("RestoreExpiryDate", [], characters(XML.iso8601(dt)))
        ])
      ]
  end

  defp maybe_restore_status(children, _obj, true), do: children

  defp encode(value, "url") when is_binary(value), do: Maxio.S3.URLEncode.encode(value)
  defp encode(value, _enc), do: value

  defp encoding_type_value("url"), do: "url"
  defp encoding_type_value(_), do: nil

  defp maybe(children, falsy, _fun) when falsy in [nil, false, ""], do: children
  defp maybe(children, value, fun), do: children ++ [fun.(value)]
end
