defmodule Maxio.S3.Views.ObjectAttributes do
  @moduledoc "GetObjectAttributes response XML."
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(map()) :: iodata()
  def render(data) do
    children =
      []
      |> maybe_etag(data)
      |> maybe_checksum(data)
      |> maybe_object_parts(data)
      |> maybe_object_size(data)
      |> maybe_storage_class(data)
      |> Enum.reverse()

    root = element("GetObjectAttributesResponse", [{"xmlns", XML.namespace()}], children)
    XML.encode(root)
  end

  defp maybe_etag(children, %{attributes: attributes, object: %{etag: etag}})
       when is_binary(etag) do
    if "ETag" in attributes do
      [element("ETag", [], characters(XML.quote_etag(etag))) | children]
    else
      children
    end
  end

  defp maybe_etag(children, _data), do: children

  defp maybe_checksum(children, %{
         attributes: attributes,
         object: %{checksum: checksum}
       })
       when is_map(checksum) do
    if "Checksum" in attributes and map_size(checksum) > 0 do
      checksum_children =
        []
        |> maybe_checksum_field(checksum, "ChecksumCRC32")
        |> maybe_checksum_field(checksum, "ChecksumCRC32C")
        |> maybe_checksum_field(checksum, "ChecksumMD5")
        |> maybe_checksum_field(checksum, "ChecksumSHA1")
        |> maybe_checksum_field(checksum, "ChecksumSHA256")
        |> maybe_checksum_field(checksum, "ChecksumSHA512")
        |> maybe_checksum_field(checksum, "ChecksumCRC64NVME")
        |> maybe_checksum_field(checksum, "ChecksumXXHASH128")
        |> maybe_checksum_field(checksum, "ChecksumXXHASH3")
        |> maybe_checksum_field(checksum, "ChecksumXXHASH64")
        |> maybe_checksum_field(checksum, "ChecksumType")
        |> Enum.reverse()

      if checksum_children == [] do
        children
      else
        [element("Checksum", [], checksum_children) | children]
      end
    else
      children
    end
  end

  defp maybe_checksum(children, _data), do: children

  defp maybe_checksum_field(children, checksum, name) do
    case Map.get(checksum, name) do
      value when is_binary(value) and value != "" ->
        [element(name, [], characters(value)) | children]

      _ ->
        children
    end
  end

  defp maybe_object_parts(children, %{
         attributes: attributes,
         object_parts_paging: paging,
         object: %{object_parts: object_parts}
       })
       when is_map(object_parts) do
    if "ObjectParts" in attributes and object_parts?(object_parts) do
      [element("ObjectParts", [], object_parts_children(object_parts, paging)) | children]
    else
      children
    end
  end

  defp maybe_object_parts(children, _data), do: children

  defp object_parts?(%{"Parts" => parts}) when is_list(parts), do: true
  defp object_parts?(_object_parts), do: false

  defp object_parts_children(object_parts, paging) do
    parts = normalize_parts(Map.get(object_parts, "Parts", []))
    marker = Map.get(paging, :part_number_marker, 0)
    max_parts = Map.get(paging, :max_parts, 1000)

    page_parts =
      parts
      |> Enum.filter(fn part -> part_number(part) > marker end)
      |> Enum.take(max_parts + 1)

    truncated? = length(page_parts) > max_parts
    visible_parts = Enum.take(page_parts, max_parts)
    next_marker = if truncated?, do: part_number(List.last(visible_parts)), else: nil

    []
    |> add_required_field("IsTruncated", if(truncated?, do: "true", else: "false"))
    |> add_required_field("MaxParts", Integer.to_string(max_parts))
    |> maybe_add_integer_field("NextPartNumberMarker", next_marker)
    |> add_required_field("PartNumberMarker", Integer.to_string(marker))
    |> add_part_elements(visible_parts)
    |> add_required_field("PartsCount", Integer.to_string(length(parts)))
    |> Enum.reverse()
  end

  defp normalize_parts(parts) when is_list(parts) do
    parts
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&part_number/1)
  end

  defp normalize_parts(_parts), do: []

  defp add_part_elements(children, parts) do
    Enum.reduce(parts, children, fn part, acc ->
      [element("Part", [], part_children(part)) | acc]
    end)
  end

  defp part_children(part) do
    []
    |> maybe_checksum_field(part, "ChecksumCRC32")
    |> maybe_checksum_field(part, "ChecksumCRC32C")
    |> maybe_checksum_field(part, "ChecksumCRC64NVME")
    |> maybe_checksum_field(part, "ChecksumMD5")
    |> maybe_checksum_field(part, "ChecksumSHA1")
    |> maybe_checksum_field(part, "ChecksumSHA256")
    |> maybe_checksum_field(part, "ChecksumSHA512")
    |> maybe_checksum_field(part, "ChecksumXXHASH128")
    |> maybe_checksum_field(part, "ChecksumXXHASH3")
    |> maybe_checksum_field(part, "ChecksumXXHASH64")
    |> add_required_field("PartNumber", Integer.to_string(part_number(part)))
    |> add_required_field("Size", Integer.to_string(part_size(part)))
    |> Enum.reverse()
  end

  defp add_required_field(children, name, value) do
    [element(name, [], characters(value)) | children]
  end

  defp maybe_add_integer_field(children, _name, nil), do: children

  defp maybe_add_integer_field(children, name, value) when is_integer(value) do
    add_required_field(children, name, Integer.to_string(value))
  end

  defp part_number(%{"PartNumber" => value}), do: integer_value(value)
  defp part_number(%{part_number: value}), do: integer_value(value)
  defp part_number(_part), do: 0

  defp part_size(%{"Size" => value}), do: integer_value(value)
  defp part_size(%{size: value}), do: integer_value(value)
  defp part_size(_part), do: 0

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 0
    end
  end

  defp integer_value(_value), do: 0

  defp maybe_object_size(children, %{attributes: attributes, object: %{size: size}})
       when is_integer(size) do
    if "ObjectSize" in attributes do
      [element("ObjectSize", [], characters(Integer.to_string(size))) | children]
    else
      children
    end
  end

  defp maybe_object_size(children, _data), do: children

  defp maybe_storage_class(children, %{
         attributes: attributes,
         object: %{storage_class: storage_class}
       })
       when is_binary(storage_class) and storage_class not in ["", "STANDARD"] do
    if "StorageClass" in attributes do
      [element("StorageClass", [], characters(storage_class)) | children]
    else
      children
    end
  end

  defp maybe_storage_class(children, _data), do: children
end
