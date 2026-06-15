defmodule Maxio.S3.Views.ObjectAttributes do
  @moduledoc "GetObjectAttributes response XML."
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(map()) :: iodata()
  def render(data) do
    children =
      []
      |> maybe_etag(data)
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
