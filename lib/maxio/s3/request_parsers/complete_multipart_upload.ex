defmodule Maxio.S3.RequestParsers.CompleteMultipartUpload do
  @moduledoc """
  Strict XML parser for CompleteMultipartUpload request bodies.

  The object bytes never go through this parser; handlers pass only the small
  CompleteMultipartUpload XML body after bounded reads.
  """

  alias Maxio.S3.RequestParsers.XMLTree

  @checksum_fields [
    "ChecksumCRC32",
    "ChecksumCRC32C",
    "ChecksumCRC64NVME",
    "ChecksumMD5",
    "ChecksumSHA1",
    "ChecksumSHA256",
    "ChecksumSHA512",
    "ChecksumXXHASH128",
    "ChecksumXXHASH3",
    "ChecksumXXHASH64"
  ]

  @spec parse(binary()) ::
          {:ok, [%{part_number: pos_integer(), etag: String.t()}]} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    with {:ok, {"CompleteMultipartUpload", _attrs, children}} <- XMLTree.parse(xml),
         {:ok, parts} <- parse_parts(children),
         false <- parts == [] do
      {:ok, parts}
    else
      _other -> {:error, :malformed_xml}
    end
  end

  defp parse_parts(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, []}, fn
      {"Part", _attrs, children}, {:ok, parts} ->
        case parse_part(children) do
          {:ok, part} -> {:cont, {:ok, [part | parts]}}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      :error -> :error
    end
  end

  defp parse_part(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}}, fn child, {:ok, part} ->
      case put_part_field(part, child) do
        {:ok, part} -> {:cont, {:ok, part}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, %{part_number: part_number, etag: etag} = part}
      when is_integer(part_number) and is_binary(etag) ->
        {:ok, part}

      _other ->
        :error
    end
  end

  defp put_part_field(part, {"PartNumber", _attrs, children}) do
    with {:ok, value} <- XMLTree.required_text(children, trim: true),
         {:ok, part_number} <- parse_part_number(value) do
      put_once(part, :part_number, part_number)
    else
      _other -> :error
    end
  end

  defp put_part_field(part, {"ETag", _attrs, children}) do
    with {:ok, etag} <- XMLTree.required_text(children, trim: true) do
      put_once(part, :etag, etag)
    else
      _other -> :error
    end
  end

  defp put_part_field(part, {field, _attrs, children}) do
    if checksum_field?(field) do
      with {:ok, value} <- XMLTree.required_text(children, trim: true) do
        put_once(part, field, value)
      else
        _other -> :error
      end
    else
      :error
    end
  end

  defp checksum_field?(field), do: field in @checksum_fields

  defp put_once(map, key, value) do
    if Map.has_key?(map, key), do: :error, else: {:ok, Map.put(map, key, value)}
  end

  defp parse_part_number(value) do
    case Integer.parse(value) do
      {part_number, ""} when part_number in 1..10_000 -> {:ok, part_number}
      _other -> :error
    end
  end
end
