defmodule Maxio.S3.RequestParsers.Notification do
  @moduledoc "PutBucketNotificationConfiguration NotificationConfiguration XML parser."
  @behaviour Saxy.Handler

  alias Maxio.S3.Notification

  @unset {:__maxio_notification_unset__, []}

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case Saxy.parse_string(xml, __MODULE__, %{stack: [], root: nil, invalid?: false}) do
      {:ok, %{root: {"NotificationConfiguration", _attrs, children}, invalid?: false}} ->
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
    |> Enum.reduce_while({:ok, Notification.empty()}, fn
      {"TopicConfiguration", _attrs, children}, {:ok, config} ->
        put_destination(config, "TopicConfigurations", "Topic", children)

      {"QueueConfiguration", _attrs, children}, {:ok, config} ->
        put_destination(config, "QueueConfigurations", "Queue", children)

      {"CloudFunctionConfiguration", _attrs, children}, {:ok, config} ->
        put_destination(config, "LambdaFunctionConfigurations", "LambdaFunction", children)

      {"EventBridgeConfiguration", _attrs, []}, {:ok, config} ->
        if is_nil(config["EventBridgeConfiguration"]) do
          {:cont, {:ok, Map.put(config, "EventBridgeConfiguration", %{})}}
        else
          {:halt, {:error, :malformed_xml}}
        end

      _other, _acc ->
        {:halt, {:error, :malformed_xml}}
    end)
    |> case do
      {:ok, config} -> Notification.validate_client_config(config)
      error -> error
    end
    |> case do
      {:ok, config} -> {:ok, config}
      {:error, :malformed_xml} -> {:error, :malformed_xml}
    end
  end

  defp put_destination(config, list_key, destination_key, children) do
    case parse_destination(destination_key, children) do
      {:ok, destination} ->
        config = Map.update!(config, list_key, &(&1 ++ [destination]))
        {:cont, {:ok, config}}

      :error ->
        {:halt, {:error, :malformed_xml}}
    end
  end

  defp parse_destination(destination_key, children) do
    Enum.reduce_while(
      structural_children(children),
      {:ok, %{destination_key => @unset, "Events" => [], "Id" => @unset, "Filter" => @unset}},
      fn
        {"Id", _attrs, children}, {:ok, dest} ->
          put_once(dest, "Id", optional_text(children))

        {^destination_key, _attrs, children}, {:ok, dest} ->
          put_once(dest, destination_key, required_text(children))

        {"CloudFunction", _attrs, children}, {:ok, dest}
        when destination_key == "LambdaFunction" ->
          put_once(dest, destination_key, required_text(children))

        {"Event", _attrs, children}, {:ok, dest} ->
          case required_text(children) do
            {:ok, event} -> {:cont, {:ok, Map.update!(dest, "Events", &(&1 ++ [event]))}}
            :error -> {:halt, :error}
          end

        {"Filter", _attrs, children}, {:ok, dest} ->
          with {:ok, filter} <- parse_filter(children),
               {:cont, {:ok, dest}} <- put_once(dest, "Filter", {:ok, filter}) do
            {:cont, {:ok, dest}}
          else
            _other -> {:halt, :error}
          end

        _other, _acc ->
          {:halt, :error}
      end
    )
    |> case do
      {:ok, dest} ->
        dest = normalize_unset_fields(dest)

        if is_binary(dest[destination_key]) and dest["Events"] != [] and
             Enum.all?(dest["Events"], &Notification.known_event?/1) do
          {:ok, dest}
        else
          :error
        end

      :error ->
        :error
    end
  end

  defp parse_filter(children), do: do_parse_filter(structural_children(children))

  defp do_parse_filter([{"S3Key", _attrs, children}]) do
    rules =
      children
      |> structural_children()
      |> Enum.reduce_while({:ok, []}, fn
        {"FilterRule", _attrs, rule_children}, {:ok, rules} ->
          case parse_filter_rule(rule_children) do
            {:ok, rule} -> {:cont, {:ok, rules ++ [rule]}}
            :error -> {:halt, :error}
          end

        _other, _acc ->
          {:halt, :error}
      end)

    case rules do
      {:ok, rules} -> {:ok, %{"S3Key" => %{"FilterRules" => rules}}}
      :error -> :error
    end
  end

  defp do_parse_filter(_children), do: :error

  defp parse_filter_rule(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"Name" => @unset, "Value" => @unset}}, fn
      {"Name", _attrs, children}, {:ok, rule} ->
        put_once(rule, "Name", required_text(children))

      {"Value", _attrs, children}, {:ok, rule} ->
        put_once(rule, "Value", text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, rule} ->
        rule = normalize_unset_fields(rule)
        validate_filter_rule(rule)

      :error ->
        :error
    end
  end

  defp validate_filter_rule(%{"Name" => name, "Value" => value})
       when name in ["prefix", "suffix"] and is_binary(value) do
    {:ok, %{"Name" => name, "Value" => value}}
  end

  defp validate_filter_rule(_rule), do: :error

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

  defp optional_text(children) do
    case text(children) do
      {:ok, ""} -> {:ok, nil}
      other -> other
    end
  end

  defp text([]), do: {:ok, ""}

  defp text(children) when is_list(children) do
    if Enum.all?(children, &match?({:text, value} when is_binary(value), &1)) do
      {:ok, children |> Enum.map(fn {:text, value} -> value end) |> Enum.join()}
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
