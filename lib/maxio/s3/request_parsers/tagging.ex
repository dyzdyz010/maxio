defmodule Maxio.S3.RequestParsers.Tagging do
  @moduledoc "PutObjectTagging and PutBucketTagging Tagging XML parser."

  alias Maxio.S3.RequestParsers.XMLTree

  @unset {:__maxio_tagging_unset__, []}

  @spec parse(binary()) :: {:ok, [{String.t(), String.t()}]} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case XMLTree.parse(xml) do
      {:ok, {"Tagging", _attrs, children}} ->
        parse_root(children)

      _other ->
        {:error, :malformed_xml}
    end
  end

  defp parse_root(children) do
    case XMLTree.structural_children(children) do
      [{"TagSet", _attrs, tag_children}] ->
        parse_tag_set(tag_children)

      _other ->
        {:error, :malformed_xml}
    end
  end

  defp parse_tag_set(children) do
    children = XMLTree.structural_children(children)

    if Enum.all?(children, &match?({"Tag", _attrs, _children}, &1)) do
      children
      |> Enum.reduce_while({:ok, []}, fn {"Tag", _attrs, tag_children}, {:ok, tags} ->
        case parse_tag(tag_children) do
          {:ok, tag} -> {:cont, {:ok, tags ++ [tag]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, tags} -> {:ok, tags}
        :error -> {:error, :malformed_xml}
      end
    else
      {:error, :malformed_xml}
    end
  end

  defp parse_tag(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{key: @unset, value: @unset}}, fn
      {"Key", _attrs, children}, {:ok, tag} ->
        put_once(tag, :key, XMLTree.text(children))

      {"Value", _attrs, children}, {:ok, tag} ->
        put_once(tag, :value, XMLTree.text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, %{key: key, value: value}} when key != @unset and value != @unset ->
        {:ok, {key, value}}

      _other ->
        :error
    end
  end

  defp put_once(map, key, {:ok, value}) do
    if Map.fetch!(map, key) == @unset do
      {:cont, {:ok, Map.put(map, key, value)}}
    else
      {:halt, :error}
    end
  end

  defp put_once(_map, _key, :error), do: {:halt, :error}
end
