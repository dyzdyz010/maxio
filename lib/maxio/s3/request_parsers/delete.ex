defmodule Maxio.S3.RequestParsers.Delete do
  @moduledoc """
  Strict XML parser for DeleteObjects request bodies.

  Returns `%{quiet: boolean(), objects: [%{key: binary(), version_id: binary() | nil}]}`.
  Conditional delete fields are valid AWS XML shape but are not implemented by
  the current delete pipeline, so the parser reports them explicitly instead of
  silently dropping them.
  """

  alias Maxio.S3.RequestParsers.XMLTree

  @unsupported_conditional_fields ["ETag", "LastModifiedTime", "Size"]

  @spec parse(binary()) ::
          {:ok, %{quiet: boolean(), objects: [%{key: String.t(), version_id: String.t() | nil}]}}
          | {:error, :malformed_xml | :unsupported_conditional_delete}
  def parse(xml) when is_binary(xml) do
    with {:ok, {"Delete", _attrs, children}} <- XMLTree.parse(xml),
         {:ok, %{objects: objects} = parsed} <- parse_delete(children),
         false <- objects == [] do
      {:ok, parsed}
    else
      {:error, reason} when reason in [:malformed_xml, :unsupported_conditional_delete] ->
        {:error, reason}

      _other ->
        {:error, :malformed_xml}
    end
  end

  defp parse_delete(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{quiet: false, quiet_seen?: false, objects: []}}, fn
      {"Object", _attrs, children}, {:ok, acc} ->
        case parse_object(children) do
          {:ok, object} ->
            {:cont, {:ok, %{acc | objects: [object | acc.objects]}}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      {"Quiet", _attrs, children}, {:ok, acc} ->
        case put_quiet(acc, children) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          :error -> {:halt, {:error, :malformed_xml}}
        end

      _other, _acc ->
        {:halt, {:error, :malformed_xml}}
    end)
    |> case do
      {:ok, %{objects: objects} = parsed} ->
        parsed = %{parsed | objects: Enum.reverse(objects)}
        {:ok, Map.delete(parsed, :quiet_seen?)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_quiet(%{quiet_seen?: false} = acc, children) do
    case XMLTree.required_text(children, trim: true) do
      {:ok, "true"} -> {:ok, %{acc | quiet: true, quiet_seen?: true}}
      {:ok, "false"} -> {:ok, %{acc | quiet: false, quiet_seen?: true}}
      _other -> :error
    end
  end

  defp put_quiet(_acc, _children), do: :error

  defp parse_object(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{key: nil, version_id: nil, version_id_seen?: false}}, fn
      child, {:ok, object} ->
        case put_object_field(object, child) do
          {:ok, object} -> {:cont, {:ok, object}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, %{key: key} = object} when is_binary(key) and key != "" ->
        {:ok, Map.delete(object, :version_id_seen?)}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :malformed_xml}
    end
  end

  defp put_object_field(%{key: nil} = object, {"Key", _attrs, children}) do
    case XMLTree.required_text(children) do
      {:ok, key} -> {:ok, %{object | key: key}}
      :error -> {:error, :malformed_xml}
    end
  end

  defp put_object_field(%{key: key}, {"Key", _attrs, _children}) when is_binary(key),
    do: {:error, :malformed_xml}

  defp put_object_field(%{version_id_seen?: false} = object, {"VersionId", _attrs, children}) do
    case XMLTree.text(children, trim: true) do
      {:ok, version_id} ->
        {:ok, %{object | version_id: nilify(version_id), version_id_seen?: true}}

      :error ->
        {:error, :malformed_xml}
    end
  end

  defp put_object_field(%{version_id_seen?: true}, {"VersionId", _attrs, _children}),
    do: {:error, :malformed_xml}

  defp put_object_field(_object, {field, _attrs, children}) do
    if unsupported_conditional_field?(field) do
      case XMLTree.text(children, trim: true) do
        {:ok, _value} -> {:error, :unsupported_conditional_delete}
        :error -> {:error, :malformed_xml}
      end
    else
      {:error, :malformed_xml}
    end
  end

  defp unsupported_conditional_field?(field), do: field in @unsupported_conditional_fields

  defp nilify(""), do: nil
  defp nilify(value), do: value
end
