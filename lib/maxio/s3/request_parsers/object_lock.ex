defmodule Maxio.S3.RequestParsers.ObjectLock do
  @moduledoc "PutBucketObjectLockConfiguration ObjectLockConfiguration XML parser."
  @behaviour Saxy.Handler

  alias Maxio.S3.ObjectLock

  @unset {:__maxio_object_lock_unset__, []}

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case Saxy.parse_string(xml, __MODULE__, %{stack: [], root: nil, invalid?: false}) do
      {:ok, %{root: {"ObjectLockConfiguration", _attrs, children}, invalid?: false}} ->
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
  def handle_event(:characters, chars, state) do
    {:ok, append_child(state, {:text, chars})}
  end

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
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"ObjectLockEnabled" => @unset, "Rule" => @unset}}, fn
      {"ObjectLockEnabled", _attrs, children}, {:ok, config} ->
        put_once(config, "ObjectLockEnabled", required_text(children))

      {"Rule", _attrs, children}, {:ok, config} ->
        with {:ok, rule} <- parse_rule(children),
             {:cont, {:ok, config}} <- put_once(config, "Rule", {:ok, rule}) do
          {:cont, {:ok, config}}
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, config} ->
        config = normalize_unset_fields(config)

        case ObjectLock.validate_client_config(config) do
          {:ok, config} -> {:ok, config}
          {:error, :malformed_xml} -> {:error, :malformed_xml}
        end

      :error ->
        {:error, :malformed_xml}
    end
  end

  defp parse_rule(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"DefaultRetention" => @unset}}, fn
      {"DefaultRetention", _attrs, children}, {:ok, rule} ->
        with {:ok, retention} <- parse_default_retention(children),
             {:cont, {:ok, rule}} <- put_once(rule, "DefaultRetention", {:ok, retention}) do
          {:cont, {:ok, rule}}
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> normalize_result()
  end

  defp parse_default_retention(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"Mode" => @unset, "Days" => @unset, "Years" => @unset}}, fn
      {"Mode", _attrs, children}, {:ok, retention} ->
        put_once(retention, "Mode", required_text(children))

      {"Days", _attrs, children}, {:ok, retention} ->
        put_once(retention, "Days", required_text(children))

      {"Years", _attrs, children}, {:ok, retention} ->
        put_once(retention, "Years", required_text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> normalize_result()
  end

  defp normalize_result({:ok, value}), do: {:ok, normalize_unset_fields(value)}
  defp normalize_result(:error), do: :error

  defp normalize_unset_fields(map) do
    Map.new(map, fn
      {key, @unset} -> {key, nil}
      {key, value} -> {key, value}
    end)
  end

  defp put_once(map, key, {:ok, value}) do
    if Map.fetch!(map, key) == @unset do
      {:cont, {:ok, Map.put(map, key, value)}}
    else
      {:halt, :error}
    end
  end

  defp put_once(_map, _key, :error), do: {:halt, :error}

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
