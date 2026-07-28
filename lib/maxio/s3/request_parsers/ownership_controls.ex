defmodule Maxio.S3.RequestParsers.OwnershipControls do
  @moduledoc "PutBucketOwnershipControls XML parser."

  alias Maxio.S3.OwnershipControls
  alias Maxio.S3.RequestParsers.XMLTree

  @values ~w(BucketOwnerEnforced BucketOwnerPreferred ObjectWriter)

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case XMLTree.parse(xml) do
      {:ok, {"OwnershipControls", _attrs, children}} ->
        parse_root(children)

      _other ->
        {:error, :malformed_xml}
    end
  end

  defp parse_root(children) do
    case XMLTree.structural_children(children) do
      [{"Rule", _attrs, children}] ->
        parse_rule(children)

      _other ->
        {:error, :malformed_xml}
    end
  end

  defp parse_rule(children) do
    case XMLTree.structural_children(children) do
      [{"ObjectOwnership", _attrs, children}] ->
        parse_object_ownership(children)

      _other ->
        {:error, :malformed_xml}
    end
  end

  defp parse_object_ownership(children) do
    case XMLTree.required_text(children, trim: true) do
      {:ok, value} when value in @values ->
        if OwnershipControls.valid_value?(value) do
          {:ok, %{"ObjectOwnership" => value}}
        else
          {:error, :malformed_xml}
        end

      _other ->
        {:error, :malformed_xml}
    end
  end
end
