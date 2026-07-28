defmodule Maxio.S3.RequestParsers.XMLTree do
  @moduledoc false
  @behaviour Saxy.Handler

  @type xml_node :: {String.t(), [{String.t(), String.t()}], [xml_node() | {:text, String.t()}]}

  @spec parse(binary()) :: {:ok, xml_node()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case Saxy.parse_string(xml, __MODULE__, %{stack: [], root: nil, invalid?: false}) do
      {:ok, %{root: root, stack: [], invalid?: false}} when not is_nil(root) ->
        {:ok, root}

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

  @spec structural_children([xml_node() | {:text, String.t()}]) :: [
          xml_node() | {:text, String.t()}
        ]
  def structural_children(children) do
    Enum.reject(children, fn
      {:text, value} -> String.trim(value) == ""
      _node -> false
    end)
  end

  @spec text([xml_node() | {:text, String.t()}], keyword()) :: {:ok, String.t()} | :error
  def text(children, opts \\ []) when is_list(children) do
    if Enum.all?(children, &match?({:text, value} when is_binary(value), &1)) do
      value = children |> Enum.map(fn {:text, value} -> value end) |> Enum.join()
      value = if Keyword.get(opts, :trim, false), do: String.trim(value), else: value
      {:ok, value}
    else
      :error
    end
  end

  @spec required_text([xml_node() | {:text, String.t()}], keyword()) ::
          {:ok, String.t()} | :error
  def required_text(children, opts \\ []) do
    case text(children, opts) do
      {:ok, ""} -> :error
      other -> other
    end
  end

  defp append_child(%{stack: []} = state, _child), do: %{state | invalid?: true}

  defp append_child(%{stack: [{tag, attrs, children} | rest]} = state, child) do
    %{state | stack: [{tag, attrs, [child | children]} | rest]}
  end

  defp local({_namespace, name}), do: local(name)

  defp local(name) do
    case String.split(to_string(name), ":") do
      [_namespace, local] -> local
      [local] -> local
    end
  end
end
