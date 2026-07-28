defmodule Maxio.S3.RequestParsers.PublicAccessBlock do
  @moduledoc """
  PutPublicAccessBlock XML parser.

  Parses PublicAccessBlockConfiguration with optional boolean children:
  BlockPublicAcls, IgnorePublicAcls, BlockPublicPolicy, RestrictPublicBuckets.
  Missing booleans default to false.
  """

  alias Maxio.S3.PublicAccessBlock
  alias Maxio.S3.RequestParsers.XMLTree

  @keys ~w(BlockPublicAcls IgnorePublicAcls BlockPublicPolicy RestrictPublicBuckets)
  @unset {:__maxio_public_access_block_unset__, []}

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case XMLTree.parse(xml) do
      {:ok, {"PublicAccessBlockConfiguration", _attrs, children}} ->
        parse_root(children)

      _other ->
        {:error, :malformed_xml}
    end
  end

  defp parse_root(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, Map.new(@keys, &{&1, @unset})}, fn
      {key, _attrs, children}, {:ok, config} when key in @keys ->
        put_once(config, key, parse_bool(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, config} ->
        {:ok, Map.merge(PublicAccessBlock.defaults(), normalize_unset_fields(config))}

      :error ->
        {:error, :malformed_xml}
    end
  end

  defp put_once(config, key, {:ok, value}) do
    if Map.fetch!(config, key) == @unset do
      {:cont, {:ok, Map.put(config, key, value)}}
    else
      {:halt, :error}
    end
  end

  defp put_once(_config, _key, :error), do: {:halt, :error}

  defp parse_bool(children) do
    case XMLTree.required_text(children, trim: true) do
      {:ok, value} -> parse_bool_text(value)
      :error -> :error
    end
  end

  defp parse_bool_text(value) do
    case String.downcase(value) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> :error
    end
  end

  defp normalize_unset_fields(config) do
    config
    |> Enum.reject(&match?({_key, @unset}, &1))
    |> Map.new()
  end
end
