defmodule Maxio.S3.RequestParsers.Restore do
  @moduledoc "RestoreObject RestoreRequest XML parser."
  @behaviour Saxy.Handler

  @unset {:__maxio_restore_unset__, []}
  @tiers ~w(Expedited Standard Bulk)

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml | :select_restore}
  def parse(xml) when is_binary(xml) do
    case Saxy.parse_string(xml, __MODULE__, %{stack: [], root: nil, invalid?: false}) do
      {:ok, %{root: {"RestoreRequest", _attrs, children}, invalid?: false}} ->
        build_request(children)

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

  defp build_request(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"Days" => @unset, "Tier" => nil}}, fn
      {"Days", _attrs, children}, {:ok, req} ->
        put_once(req, "Days", positive_int(children))

      {"GlacierJobParameters", _attrs, children}, {:ok, req} ->
        case parse_glacier_job_parameters(children) do
          {:ok, tier} -> {:cont, {:ok, Map.put(req, "Tier", tier)}}
          :error -> {:halt, :error}
        end

      {"Type", _attrs, _children}, _acc ->
        {:halt, :select_restore}

      {"SelectParameters", _attrs, _children}, _acc ->
        {:halt, :select_restore}

      {"OutputLocation", _attrs, _children}, _acc ->
        {:halt, :select_restore}

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, %{"Days" => days} = req} when is_integer(days) ->
        {:ok, req}

      {:ok, _req} ->
        {:error, :malformed_xml}

      :select_restore ->
        {:error, :select_restore}

      :error ->
        {:error, :malformed_xml}
    end
  end

  defp parse_glacier_job_parameters(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, @unset}, fn
      {"Tier", _attrs, children}, {:ok, @unset} ->
        case required_text(children) do
          {:ok, tier} when tier in @tiers -> {:cont, {:ok, tier}}
          _other -> {:halt, :error}
        end

      {"Tier", _attrs, _children}, {:ok, _tier} ->
        {:halt, :error}

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, @unset} -> {:ok, nil}
      {:ok, tier} -> {:ok, tier}
      :error -> :error
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

  defp positive_int(children) do
    with {:ok, value} <- required_text(children),
         {int, ""} when int >= 1 <- Integer.parse(value) do
      {:ok, int}
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
