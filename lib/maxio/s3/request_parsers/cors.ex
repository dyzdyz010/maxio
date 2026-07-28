defmodule Maxio.S3.RequestParsers.Cors do
  @moduledoc "PutBucketCors CORSConfiguration XML parser."
  @behaviour Saxy.Handler

  @unset {:__maxio_cors_unset__, []}

  @spec parse(binary()) :: {:ok, [map()]} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case Saxy.parse_string(xml, __MODULE__, %{stack: [], root: nil, invalid?: false}) do
      {:ok, %{root: {"CORSConfiguration", _attrs, children}, invalid?: false}} ->
        build_config(children)

      _other ->
        {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl true
  def handle_event(:start_element, {name, attrs}, state) do
    tag = local(name)
    attrs = Enum.map(attrs, fn {name, value} -> {local(name), value} end)
    {:ok, %{state | stack: [{tag, attrs, []} | state.stack]}}
  end

  @impl true
  def handle_event(:characters, chars, state), do: {:ok, append_child(state, {:text, chars})}

  @impl true
  def handle_event(:end_element, name, %{stack: [{tag, attrs, children} | rest]} = state) do
    if local(name) == tag do
      node = {tag, attrs, Enum.reverse(children)}

      case rest do
        [] ->
          {:ok, %{state | root: node, stack: []}}

        [{parent_tag, parent_attrs, parent_children} | parent_rest] ->
          stack = [{parent_tag, parent_attrs, [node | parent_children]} | parent_rest]
          {:ok, %{state | stack: stack}}
      end
    else
      {:ok, %{state | invalid?: true}}
    end
  end

  def handle_event(:end_element, _name, state), do: {:ok, %{state | invalid?: true}}

  @impl true
  def handle_event(:end_document, _data, state), do: {:ok, state}

  defp append_child(%{stack: []} = state, _child), do: %{state | invalid?: true}

  defp append_child(%{stack: [{tag, attrs, children} | rest]} = state, child) do
    %{state | stack: [{tag, attrs, [child | children]} | rest]}
  end

  defp build_config(children) do
    children = structural_children(children)

    if children != [] and Enum.all?(children, &match?({"CORSRule", _attrs, _children}, &1)) do
      children
      |> Enum.reduce_while({:ok, []}, fn {"CORSRule", _attrs, rule_children}, {:ok, rules} ->
        case parse_rule(rule_children) do
          {:ok, rule} -> {:cont, {:ok, [rule | rules]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, rules} -> {:ok, Enum.reverse(rules)}
        :error -> {:error, :malformed_xml}
      end
    else
      {:error, :malformed_xml}
    end
  end

  defp parse_rule(children) do
    children
    |> structural_children()
    |> Enum.reduce_while(
      {:ok,
       %{
         "id" => @unset,
         "allowed_methods" => [],
         "allowed_origins" => [],
         "allowed_headers" => [],
         "expose_headers" => [],
         "max_age_seconds" => @unset
       }},
      fn
        {"ID", _attrs, children}, {:ok, rule} ->
          put_once(rule, "id", text(children))

        {"AllowedMethod", _attrs, children}, {:ok, rule} ->
          append_required_text(rule, "allowed_methods", children)

        {"AllowedOrigin", _attrs, children}, {:ok, rule} ->
          append_required_text(rule, "allowed_origins", children)

        {"AllowedHeader", _attrs, children}, {:ok, rule} ->
          append_required_text(rule, "allowed_headers", children)

        {"ExposeHeader", _attrs, children}, {:ok, rule} ->
          append_required_text(rule, "expose_headers", children)

        {"MaxAgeSeconds", _attrs, children}, {:ok, rule} ->
          put_once(rule, "max_age_seconds", integer_text(children))

        _other, _acc ->
          {:halt, :error}
      end
    )
    |> case do
      {:ok, rule} -> {:ok, normalize_unset_fields(rule)}
      :error -> :error
    end
  end

  defp append_required_text(rule, key, children) do
    case required_text(children) do
      {:ok, value} -> {:cont, {:ok, Map.update!(rule, key, &(&1 ++ [value]))}}
      :error -> {:halt, :error}
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

  defp normalize_unset_fields(map) do
    Map.new(map, fn
      {key, @unset} -> {key, nil}
      {key, value} -> {key, value}
    end)
  end

  defp integer_text(children) do
    with {:ok, value} <- required_text(children),
         {integer, ""} <- Integer.parse(value) do
      {:ok, integer}
    else
      _other -> :error
    end
  end

  defp required_text(children) do
    case text(children) do
      {:ok, ""} -> :error
      other -> other
    end
  end

  defp text([]), do: {:ok, ""}

  defp text(children) when is_list(children) do
    if Enum.all?(children, &match?({:text, value} when is_binary(value), &1)) do
      {:ok, children |> Enum.map(fn {:text, value} -> value end) |> Enum.join() |> String.trim()}
    else
      :error
    end
  end

  defp structural_children(children) do
    Enum.reject(children, fn
      {:text, value} -> String.trim(value) == ""
      _node -> false
    end)
  end

  defp local({_namespace, name}), do: local(name)

  defp local(name) do
    case String.split(to_string(name), ":") do
      [_namespace, local] -> local
      [local] -> local
    end
  end
end
